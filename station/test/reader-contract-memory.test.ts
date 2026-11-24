// Black-box contract tests for `--builder memory` against any reader binary, spoken to over its stdio alone.
//
// By default this runs against the shipped MoonBit `stillfail-reader` (`mbReaderBinary()`), and skips (saying so) where
// it is not built. Set `STILLFAIL_READER_CANDIDATE=/path/to/stillfail-pion` to verify a candidate binary with zero edits
// to this suite: a candidate named but missing or not executable fails every test, never skips.
//
// The protocol (station/mb/src/memory/answer.mbt, station/src/share/memory-mb.ts): a line of JSON an ask `{id, op, …}`,
// answered by one line `{id, …}` or `{id, error}`, one at a time; an empty line is passed over; a line that is no JSON
// object is answered `{id: null, error}`. Content goes as hex both ways (what is no UTF-8 arrives as it is), a shared
// skill's files as base64. Every op of answer.mbt is asked here (`scan`, `decide`, `have`, `hash`, `asides`,
// `alikeKept`, `tags`, `skillRead`, `skillWrite`, `skillConflict`, `isText`, `matches`, `merge3`, `union`, `alike`,
// `conflictPath`), each answer held to the TypeScript it replaced (test/reference/memory-merge.ts,
// test/reference/share-skills.ts) or to the contract's own fixed output. Each test keeps one process and its stdin open
// across all its asks (as `MemoryProgram` does) and ends it only by closing stdin: it must exit 0 with nothing more said.
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import {
  accessSync,
  chmodSync,
  constants as fsConstants,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";
import { after, test } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { BUILTIN_SKILLS, FEEDBACK_SKILL, RETIRED_SKILLS } from "../src/sessions/agent-home.ts";
import type { Rec } from "../src/share/memory.ts";
import { memoryPath, SKIPPED } from "../src/share/memory.ts";
import { alike, conflictPath, decide, isText, matches, merge3, readMemory, stationTag, unionLines } from "./reference/memory-merge.ts";
import { encodeFiles, MAX_SKILL_BYTES, MAX_SKILL_FILES, readSkill, safePath, skillHash, TooLarge, writeConflict, writeSkill } from "./reference/share-skills.ts";

/// The longest any one ask may take before the process is killed and the test fails (a bound, never a wait).
const ASK_TIMEOUT_MS = 30_000;

type Json = any;

/// The binary under test, or why there is none: `fail` for a named candidate that is not there, `skip` for a default
/// reader not built here.
function resolveCandidate(): { binary: string } | { fail: string } | { skip: string } {
  const injected = process.env.STILLFAIL_READER_CANDIDATE?.trim();
  if (injected !== undefined && injected !== "") {
    if (!existsSync(injected)) return { fail: `STILLFAIL_READER_CANDIDATE does not exist: ${injected}` };
    try {
      if (!statSync(injected).isFile()) return { fail: `STILLFAIL_READER_CANDIDATE is not a file: ${injected}` };
      accessSync(injected, fsConstants.X_OK);
    } catch {
      return { fail: `STILLFAIL_READER_CANDIDATE is not executable: ${injected}` };
    }
    return { binary: injected };
  }
  const binary = mbReaderBinary();
  if (binary === null) {
    return { skip: "stillfail-reader is not built here; set STILLFAIL_READER_CANDIDATE or run via `node ../scripts/native.ts run reader -- ...`" };
  }
  return { binary };
}

const RESOLVED = resolveCandidate();
const skip = "skip" in RESOLVED ? RESOLVED.skip : false;
const unixOnly = skip || (process.platform === "win32" && "modes and links are Unix's");

/// The candidate's path; a named candidate that is not there fails the test that asks.
function candidate(): string {
  if ("fail" in RESOLVED) assert.fail(RESOLVED.fail);
  if ("skip" in RESOLVED) assert.fail(RESOLVED.skip);
  return RESOLVED.binary;
}

const dirs: string[] = [];
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});
const fresh = (prefix = "memory-contract-") => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  dirs.push(dir);
  return dir;
};

/// One `--builder memory` process, its stdin kept open: each ask written as a line and answered by the next line it
/// says, in order; any line said with no ask waiting, any non-JSON line, or a line cut short at its end fails it.
class MemoryProcess {
  readonly #child: ChildProcess;
  readonly #waiting: { resolve: (j: Json) => void; reject: (e: Error) => void; timer: NodeJS.Timeout }[] = [];
  #carry = "";
  #stderr = "";
  #broken: Error | null = null;
  readonly #closed: Promise<{ code: number | null; signal: NodeJS.Signals | null }>;
  #next = 0;

  constructor() {
    const child = spawn(candidate(), ["--builder", "memory", "--sep", sep, "--shell-dir", fresh("memory-shell-")], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    this.#child = child;
    child.stdin!.on("error", () => {});
    child.stderr!.on("data", (c: Buffer) => { this.#stderr += c.toString("utf8"); });
    child.stdout!.on("data", (c: Buffer) => this.#heard(c.toString("utf8")));
    this.#closed = new Promise((resolve, reject) => {
      child.on("error", (e) => { this.#break(e); reject(e); });
      child.on("close", (code, signal) => {
        this.#break(new Error(`the memory process ended (code ${code}, signal ${signal}) with an ask unanswered; stderr: ${this.#stderr}`));
        resolve({ code, signal });
      });
    });
    this.#closed.catch(() => {});
  }

  #break(e: Error) {
    this.#broken ??= e;
    for (const w of this.#waiting.splice(0)) {
      clearTimeout(w.timer);
      w.reject(e);
    }
  }

  #heard(text: string) {
    this.#carry += text;
    for (let nl = this.#carry.indexOf("\n"); nl >= 0; nl = this.#carry.indexOf("\n")) {
      const line = this.#carry.slice(0, nl);
      this.#carry = this.#carry.slice(nl + 1);
      let parsed: Json;
      try {
        parsed = JSON.parse(line);
      } catch {
        this.#child.kill("SIGKILL");
        return this.#break(new Error(`stdout said a line that is no JSON: ${JSON.stringify(line)}`));
      }
      const w = this.#waiting.shift();
      if (w === undefined) {
        this.#child.kill("SIGKILL");
        return this.#break(new Error(`stdout said a line with no ask waiting: ${line}`));
      }
      clearTimeout(w.timer);
      w.resolve(parsed);
    }
  }

  /// The answer to one raw line (written with its `\n`), as the process says it.
  raw(line: string): Promise<Json> {
    if (this.#broken !== null) return Promise.reject(this.#broken);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#child.kill("SIGKILL");
        this.#break(new Error(`no answer to ${line.slice(0, 200)} within ${ASK_TIMEOUT_MS} ms; stderr: ${this.#stderr}`));
      }, ASK_TIMEOUT_MS);
      this.#waiting.push({ resolve, reject, timer });
      this.#child.stdin!.write(`${line}\n`);
    });
  }

  /// Writes a line that must be answered by nothing (an empty one): the next ask's answer is then its own.
  silent(line: string) {
    this.#child.stdin!.write(`${line}\n`);
  }

  /// What `op` with `args` is answered, its `id` checked as the one sent and taken off.
  async ask(op: string, args: Record<string, unknown> = {}): Promise<Json> {
    const id = ++this.#next;
    const answer = await this.raw(JSON.stringify({ ...args, id, op }));
    assert.ok(answer !== null && typeof answer === "object" && !Array.isArray(answer), `an object answers ${op}`);
    assert.equal(answer.id, id, `${op}: the id sent comes back`);
    const { id: _, ...rest } = answer;
    return rest;
  }

  /// An ask that must succeed: its answer, with no `error`.
  async ok(op: string, args: Record<string, unknown> = {}): Promise<Json> {
    const answer = await this.ask(op, args);
    assert.equal(answer.error, undefined, `${op} ${JSON.stringify(args).slice(0, 200)}: ${answer.error}`);
    return answer;
  }

  /// An ask that must fail: its error, the only thing said.
  async fails(op: string, args: Record<string, unknown> = {}): Promise<string> {
    const answer = await this.ask(op, args);
    assert.equal(typeof answer.error, "string", `${op} ${JSON.stringify(args).slice(0, 200)} fails, answered ${JSON.stringify(answer)}`);
    assert.deepEqual(Object.keys(answer), ["error"], `${op}: nothing but its error`);
    return answer.error;
  }

  /// Its end by stdin's alone: exit 0, no signal, nothing more said, no line cut short.
  async end(): Promise<void> {
    assert.equal(this.#waiting.length, 0, "no ask left unanswered");
    this.#child.stdin!.end();
    const timer = setTimeout(() => this.#child.kill("SIGKILL"), ASK_TIMEOUT_MS);
    const { code, signal } = await this.#closed;
    clearTimeout(timer);
    assert.equal(signal, null, `ended by a signal; stderr: ${this.#stderr}`);
    assert.equal(code, 0, `exit ${code}; stderr: ${this.#stderr}`);
    assert.equal(this.#carry, "", "nothing cut short on stdout");
  }
}

/// A test's process, ended (stdin's EOF, exit 0) when it is done.
async function withMemory(f: (p: MemoryProcess) => Promise<void>): Promise<void> {
  const p = new MemoryProcess();
  let ok = false;
  try {
    await f(p);
    ok = true;
  } finally {
    if (ok) await p.end();
    else await p.end().catch(() => {});
  }
}

const sha = (b: Buffer | string) => createHash("sha256").update(b).digest("hex");
const hex = (s: string | Buffer) => (typeof s === "string" ? Buffer.from(s, "utf8") : s).toString("hex");
const unhex = (h: string) => Buffer.from(h, "hex");
const b64 = (s: string | Buffer) => Buffer.from(s).toString("base64");

/// The same seeded stream of numbers on every machine.
function rng(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const WORDS = ["", "a", "b", "- x", "- [ccvm] x", "- y", "# h", "---", "  1. one", "* [Studio] s", "中文", "é", "😀", "x\r", "[a] b"];
function randomText(r: () => number, most: number): string {
  const n = Math.floor(r() * most);
  const lines: string[] = [];
  for (let i = 0; i < n; i++) lines.push(WORDS[Math.floor(r() * WORDS.length)]!);
  return lines.join(r() < 0.5 ? "\n" : "\r\n") + (r() < 0.5 ? "\n" : "");
}
function edited(r: () => number, text: string): string {
  const lines = text.split("\n");
  for (let k = 1 + Math.floor(r() * 3); k > 0; k--) {
    const at = Math.floor(r() * (lines.length + 1));
    const what = r();
    if (what < 0.33 && lines.length > 0) lines.splice(Math.min(at, lines.length - 1), 1);
    else if (what < 0.66) lines.splice(at, 0, WORDS[Math.floor(r() * WORDS.length)]!);
    else if (lines.length > 0) lines[Math.min(at, lines.length - 1)] = WORDS[Math.floor(r() * WORDS.length)]!;
  }
  return lines.join("\n");
}

test("text ops: hex in and out (multi-byte UTF-8, bytes that are no UTF-8), each the reference's on one open process", { skip }, async () => {
  await withMemory(async (p) => {
    // isText: UTF-8 with no NUL, byte for byte as the reference says it.
    const bytes: number[][] = [
      [], [0x61], [0x00], [0x61, 0x00, 0x62], [0xe4, 0xb8, 0xad], [0xf0, 0x9f, 0x98, 0x80], [0xef, 0xbb, 0xbf, 0x61],
      [0xed, 0xa0, 0x80], [0xc0, 0xaf], [0xe0, 0x80, 0xaf], [0xe4, 0xb8], [0xc3, 0x41], [0xf4, 0x90, 0x80, 0x80], [0xfe], [0xff], [0x80],
    ];
    const r = rng(7);
    for (let i = 0; i < 60; i++) bytes.push(Array.from({ length: Math.floor(r() * 10) }, () => (r() < 0.5 ? Math.floor(r() * 256) : [0x61, 0x80, 0xbf, 0xc2, 0xe0, 0xed, 0xf0, 0xf4][Math.floor(r() * 8)]!)));
    for (const b of bytes) {
      const buf = Buffer.from(b);
      assert.deepEqual(await p.ok("isText", { bytes: hex(buf) }), { value: isText(buf) }, buf.toString("hex"));
      // Upper-case hex is the same bytes.
      assert.deepEqual(await p.ok("isText", { bytes: hex(buf).toUpperCase() }), { value: isText(buf) }, buf.toString("hex"));
    }

    // matches: the same pairs, ties broken alike.
    const pairs: [string[], string[]][] = [[[], []], [["a"], []], [["a", "b"], ["b", "a"]], [["x", "a", "b", "y"], ["x", "b", "a", "y"]], [["中", "😀"], ["😀", "中"]]];
    for (let i = 0; i < 40; i++) pairs.push([Array.from({ length: Math.floor(r() * 10) }, () => "abc"[Math.floor(r() * 3)]!), Array.from({ length: Math.floor(r() * 10) }, () => "abc"[Math.floor(r() * 3)]!)]);
    for (const [a, b] of pairs) assert.deepEqual(await p.ok("matches", { a, b }), { value: matches(a, b) }, JSON.stringify([a, b]));

    // merge3: no conflict, one side's, both the same (once), conflicting lines (both kept, the newer's first), CRLF,
    // multi-byte text, too far apart (null); each as hex, read back byte for byte.
    const many = (n: number, q: string) => Array.from({ length: n }, (_, i) => `${q}${i}`).join("\n");
    const merges: [string, string, string][] = [
      ["", "", ""], ["a\n", "a\n", "a\n"], ["a\nb\nc\n", "A\nb\nc\n", "a\nb\nC\n"], ["a\nb\nc", "a\nX\nc", "a\nX\nc"],
      ["a\nb\nc", "a\nc", "a\nB\nc"], ["- one\n", "- one\n- mine\n", "- one\n- theirs\n"], ["a\r\nb\r\n", "a\r\nB\r\n", "a\r\nb\r\nc\r\n"],
      ["中\n文\n", "中\n😀\n文\n", "中\n文\né\n"], [many(3001, "b"), many(3001, "w"), "x"],
    ];
    for (let i = 0; i < 60; i++) {
      const base = randomText(r, 10);
      merges.push([base, edited(r, base), edited(r, base)]);
    }
    for (const [base, newer, older] of merges) {
      const want = merge3(base, newer, older);
      const got = await p.ok("merge3", { base: hex(base), newer: hex(newer), older: hex(older) });
      assert.deepEqual(got, { value: want === null ? null : hex(want) }, JSON.stringify([base.slice(0, 40), newer.slice(0, 40), older.slice(0, 40)]));
      // The same version merged with itself is itself.
      assert.deepEqual(await p.ok("merge3", { base: hex(base), newer: hex(newer), older: hex(newer) }), { value: merge3(base, newer, newer) === null ? null : hex(merge3(base, newer, newer)!) });
    }

    // union: each line once, marked with the stations' names as the reference marks them.
    for (const [newer, older] of [["", ""], ["- x\n- y\n", "- [ccvm] x\n- z\n"], ["# 全局记忆\n- 一\n", "# 全局记忆\n- 二\n"], ["a\r\nb\r\n", "a\nb\n"]] as const) {
      for (const [nn, on] of [[null, null], ["ccvm", "Mini 1"], ["中文站", null], ["", "Studio"]] as const) {
        assert.deepEqual(await p.ok("union", { newer: hex(newer), older: hex(older), newerName: nn, olderName: on }), { value: hex(unionLines(newer, older, nn, on)) });
      }
    }

    // alike, tags, conflictPath.
    const fm = (name: string, body: string) => `---\nname: ${name}\ndescription: d\n---\n${body}`;
    for (const [a, b] of [["", ""], [fm("a", "- one\n- two\n"), fm("b", "- one\n- three\n")], [fm("a", "1\n2\n3\n4\n"), fm("a", "1\n2\n5\n6\n")], ["x\n", "y\n"]] as const) {
      assert.deepEqual(await p.ok("alike", { a: hex(a), b: hex(b) }), { value: alike(a, b) });
    }
    const stations = ["ccvm", "Mini 1", "Studio's Mac", "中文 站点", "😀 emoji 😀", "---", "", "x".repeat(60), "a/b\\c:d", "tab\tand\nline"];
    assert.deepEqual(await p.ok("tags", { names: stations }), { tags: stations.map(stationTag) });
    assert.deepEqual(await p.ok("tags", {}), { tags: [] });
    for (const s of stations) {
      for (const path of ["MEMORY.md", "skills/a/SKILL.md", "skills/a/x.tar.gz", "noext", ".dot"]) {
        assert.deepEqual(await p.ok("conflictPath", { path, station: s }), { value: conflictPath(path, s) });
      }
    }
  });
});

const A = "a".repeat(64);
const B = "b".repeat(64);
const NAMES: Record<string, string> = { [A]: "ccvm", [B]: "Mini 1" };
const nameOf = (s: string) => NAMES[s] ?? s.slice(0, 8);

test("decide: the reference's outcome, record and merged content (three-way, conflicts kept, alike once, deleted, binary)", { skip }, async () => {
  await withMemory(async (p) => {
    const both = async (path: string, mine: Rec | undefined, theirs: Rec, contents: Map<string, Buffer>, kept: Map<string, Buffer>) => {
      const blobs = fresh("memory-blobs-");
      for (const [h, b] of kept) writeFileSync(join(blobs, h), b);
      const all = new Map([...kept, ...contents]);
      const want = decide(path, mine, theirs, (h) => all.get(h) ?? null, nameOf);
      const given: Record<string, string> = {};
      for (const [h, b] of contents) given[h] = b.toString("hex");
      const names: Record<string, string> = { [theirs.by]: nameOf(theirs.by), ...(mine ? { [mine.by]: nameOf(mine.by) } : {}) };
      const got = await p.ok("decide", { path, mine: mine ?? null, theirs, names, given, blobs, prevMost: 16 });
      const label = `decide(${path}, ${JSON.stringify(mine)}, ${JSON.stringify(theirs)})`;
      assert.equal(got.kind, want.kind, label);
      if (want.kind === "keep") assert.deepEqual(got, { kind: "keep" }, label);
      if (want.kind === "take") assert.deepEqual(got, { kind: "take", content: all.has(theirs.hash) }, label);
      if (want.kind === "merge") {
        assert.deepEqual(Object.keys(got).sort(), ["beside", "kind", "rec"], label);
        assert.deepEqual(got.rec, want.rec, label);
        const content = all.get(got.rec.hash) ?? readFileSync(join(blobs, got.rec.hash));
        assert.deepEqual(content, want.content, label);
        if (!all.has(got.rec.hash) && process.platform !== "win32") assert.equal(statSync(join(blobs, got.rec.hash)).mode & 0o777, 0o600, label);
        if (want.beside === null) assert.ok(got.beside === null || !memoryPath(got.beside.path), label);
        else assert.deepEqual(got.beside, { path: want.beside.path, rec: want.beside.rec }, label);
      }
      return got;
    };
    const rec = (text: string | null, by: string, at: number, prev: string[] = [], extra: Partial<Rec> = {}): Rec => ({ hash: text === null ? "" : sha(text), at, by, prev, size: text === null ? 0 : Buffer.byteLength(text), mode: 0o644, ...extra });
    const c = (...texts: string[]) => new Map(texts.map((t) => [sha(t), Buffer.from(t)] as [string, Buffer]));
    const base = "- one\n- two\n";
    const mine = "- one\n- two\n- mine\n";
    const theirs = "- zero\n- one\n- two\n";
    // Theirs only; the same content both sides (kept, idempotent); one after the other.
    assert.equal((await both("MEMORY.md", undefined, rec(theirs, B, 2), c(theirs), new Map())).kind, "take");
    await both("MEMORY.md", rec(mine, A, 2), rec(mine, B, 3), new Map(), c(mine));
    // The very same record on both sides: kept as it is.
    assert.equal((await both("MEMORY.md", rec(mine, A, 2), rec(mine, A, 2), new Map(), c(mine))).kind, "keep");
    await both("MEMORY.md", rec(mine, B, 3), rec(mine, A, 2), new Map(), c(mine));
    await both("MEMORY.md", rec(mine, A, 2, [sha(base)]), rec(theirs, B, 3, [sha(mine)]), c(theirs), c(mine));
    // Three-way from one base, without a conflict: both changes in.
    const merged = await both("MEMORY.md", rec(mine, A, 2, [sha(base)]), rec(theirs, B, 3, [sha(base)]), c(theirs), c(mine, base));
    assert.equal(merged.kind, "merge");
    // A conflict on one line: both kept.
    await both("MEMORY.md", rec("- one\n- MINE\n", A, 2, [sha(base)]), rec("- one\n- THEIRS\n", B, 3, [sha(base)]), c("- one\n- THEIRS\n"), c("- one\n- MINE\n", base));
    // A skill both kept apart with no base: alike merged, not alike kept beside (`.conflict-<station>`).
    await both("skills/p/SKILL.md", rec(mine, A, 2), rec(theirs, B, 3), c(theirs), c(mine));
    await both("skills/p/SKILL.md", rec("---\nname: p\n---\nA\nB\n", A, 2), rec("---\nname: p\n---\nC\nD\n", B, 3), c("---\nname: p\n---\nC\nD\n"), c("---\nname: p\n---\nA\nB\n"));
    await both("skills/p/run", rec("x", A, 2), rec("y", B, 3), c("y"), c("x"));
    // MEMORY.md with no base: each line once.
    await both("MEMORY.md", rec(mine, A, 2, [], { origin: true }), rec(theirs, B, 3, [], { origin: true }), c(theirs), c(mine));
    // Ties: the same time, then the station.
    await both("MEMORY.md", rec(mine, A, 3, [sha(base)]), rec(theirs, B, 3, [sha(base)]), c(theirs), c(mine, base));
    // Deleted on one side, edited on the other; deleted on both.
    await both("MEMORY.md", rec(null, A, 5, [sha(base)]), rec(theirs, B, 3, [sha(base)]), c(theirs), new Map());
    await both("MEMORY.md", rec(mine, A, 2, [sha(base)]), rec(null, B, 6, [sha(base)]), new Map(), c(mine));
    // Bytes that are no text: kept beside, never merged by lines, passed through as they are.
    const bin = Buffer.from([0x00, 0x01, 0xff]);
    const bin2 = Buffer.from([0xed, 0xa0, 0x80, 0xc0]);
    const hb = (b: Buffer, by: string, at: number, prev: string[] = []): Rec => ({ hash: sha(b), at, by, prev, size: b.length, mode: 0o644 });
    await both("skills/p/blob", hb(bin, A, 2, [sha(base)]), hb(bin2, B, 3, [sha(base)]), new Map([[sha(bin2), bin2]]), new Map([[sha(bin), bin], [sha(base), Buffer.from(base)]]));
    // A version not here: kept.
    await both("MEMORY.md", rec(mine, A, 2, [sha(base)]), rec(theirs, B, 3, [sha(base)]), new Map(), c(mine));
    // Random histories.
    const r = rng(23);
    for (let i = 0; i < 60; i++) {
      const texts = Array.from({ length: 4 }, () => randomText(r, 8));
      texts[1] = edited(r, texts[0]!);
      texts[2] = edited(r, texts[0]!);
      const pick = () => texts[Math.floor(r() * texts.length)]!;
      const [m, t] = [pick(), pick()];
      const prevOf = () => (r() < 0.6 ? [sha(texts[0]!)] : r() < 0.5 ? [] : [sha(pick())]);
      await both(r() < 0.5 ? "MEMORY.md" : "skills/p/SKILL.md", rec(m, A, 1 + Math.floor(r() * 3), prevOf()), rec(t, B, 1 + Math.floor(r() * 3), prevOf()), c(t), c(m, ...(r() < 0.5 ? [texts[0]!] : [])));
    }

    // alikeKept: two versions by hash, given or kept; null where one is in neither.
    const blobs = fresh("memory-blobs-");
    const a = "---\nname: p\n---\n- one\n- two\n";
    const b = "---\nname: p\n---\n- one\n- three\n";
    writeFileSync(join(blobs, sha(a)), a);
    assert.deepEqual(await p.ok("alikeKept", { blobs, a: sha(a), b: sha(b), given: { [sha(b)]: hex(b) } }), { alike: alike(a, b) });
    assert.deepEqual(await p.ok("alikeKept", { blobs, a: sha(a), b: sha(a) }), { alike: true });
    assert.deepEqual(await p.ok("alikeKept", { blobs, a: sha(a), b: sha(b) }), { alike: null });
    assert.deepEqual(await p.ok("alikeKept", { blobs }), { alike: null });
  });
});

test("files: scan, hash, have and asides read a memory's tree as the reference, what changed kept in blobs/ privately", { skip: unixOnly }, async () => {
  await withMemory(async (p) => {
    const dir = fresh("memory-home-");
    const put = (path: string, text: string | Buffer, mode = 0o644) => {
      mkdirSync(join(dir, path, ".."), { recursive: true });
      writeFileSync(join(dir, path), text);
      chmodSync(join(dir, path), mode);
    };
    put("MEMORY.md", "# 全局记忆\n- 一条。\n");
    utimesSync(join(dir, "MEMORY.md"), 1_700_000_000.4567, 1_700_000_000.4567);
    put("skills/proj/SKILL.md", "---\nname: proj\n---\n- a\n");
    put("skills/proj/run.sh", "#!/bin/sh\n", 0o755);
    put("skills/proj/key", "secret\n", 0o600);
    put("skills/proj/b/c/d.txt", "deep\n");
    put("skills/proj/node_modules/x.js", "x\n");
    put("skills/proj/bin", Buffer.from([0, 1, 2, 255]));
    symlinkSync(join(dir, "skills/proj/b/c/d.txt"), join(dir, "skills/proj/link.txt"));
    put(`skills/${BUILTIN_SKILLS[0]}/SKILL.md`, "built in\n");
    put("skills/__pycache__/SKILL.md", "x\n");
    symlinkSync(join(dir, "skills/proj"), join(dir, "skills/linked"));
    put("skills/中文技能/SKILL.md", "---\nname: 中文技能\n---\n- 中\n");
    put("skills/large/SKILL.md", "---\nname: large\n---\n");
    put("skills/large/big", Buffer.alloc(512 * 1024 + 1, 0x61));

    const want = await readMemory(dir);
    const scan = (blobs: string, kept: Record<string, string>) =>
      p.ok("scan", { dir, blobs, kept, builtin: [...BUILTIN_SKILLS, FEEDBACK_SKILL, ...RETIRED_SKILLS], skipped: [...SKIPPED], fileMost: 512 * 1024, skillMost: 4 * 1024 * 1024, skillFiles: 200 });
    const blobs = fresh("memory-blobs-");
    const got = await scan(blobs, {});
    assert.deepEqual(got.files.map((f: Json) => f.path), [...want.files.keys()]);
    assert.deepEqual(new Set(got.held), want.held);
    for (const f of got.files) {
      const w = want.files.get(f.path)!;
      assert.deepEqual({ hash: f.hash, size: f.size, mode: f.mode, mtime: f.mtime }, { hash: sha(w.bytes), size: w.bytes.length, mode: w.mode, mtime: w.mtime }, f.path);
      assert.deepEqual(readFileSync(join(blobs, f.hash)), w.bytes, f.path);
      assert.equal(statSync(join(blobs, f.hash)).mode & 0o777, 0o600, f.path);
      // `hash` of the file on the disk is its scan's.
      assert.deepEqual(await p.ok("hash", { path: join(dir, f.path) }), { hash: f.hash }, f.path);
    }
    // Scanned again with what is kept named: the same files, nothing kept again.
    const again = fresh("memory-blobs-");
    const kept = Object.fromEntries(got.files.map((f: Json) => [f.path, f.hash]));
    assert.deepEqual((await scan(again, kept)).files, got.files);
    assert.deepEqual(readdirSync(again), []);
    // `have`: what blobs/ holds, in the order asked.
    const hashes = [...got.files.map((f: Json) => f.hash), "0".repeat(64), ""];
    assert.deepEqual(await p.ok("have", { blobs, hashes }), { have: hashes.map((h) => h.length === 64 && existsSync(join(blobs, h))) });
    assert.deepEqual(await p.ok("have", { blobs: again, hashes }), { have: hashes.map(() => false) });
    assert.deepEqual(await p.ok("have", { blobs }), { have: [] });
    // `hash` of what is not there, or is a directory: null.
    assert.deepEqual(await p.ok("hash", { path: join(dir, "missing.md") }), { hash: null });
    assert.deepEqual(await p.ok("hash", { path: join(dir, "skills") }), { hash: null });
    // Raw bytes hashed as they are.
    put("raw.bin", Buffer.from([0xff, 0xfe, 0x00, 0xc0, 0xaf]));
    assert.deepEqual(await p.ok("hash", { path: join(dir, "raw.bin") }), { hash: sha(Buffer.from([0xff, 0xfe, 0x00, 0xc0, 0xaf])) });

    // `asides`: a skill kept apart as `<base>-<tag>`, its front matter naming it so and saying `[<station>]` of that tag.
    const aside = "---\nname: p-ccvm\ndescription: [ccvm] kept apart\n---\nbody line\n";
    const notAside = "---\nname: q-ccvm\ndescription: no tag here\n---\nbody\n";
    const otherTag = "---\nname: r-ccvm\ndescription: [Mini 1] wrong tag\n---\nbody\n";
    const wrongName = "---\nname: other\ndescription: [ccvm] named otherwise\n---\nbody\n";
    for (const t of [aside, notAside, otherTag, wrongName]) writeFileSync(join(blobs, sha(t)), t);
    const asides = await p.ok("asides", {
      blobs,
      skills: [
        { skill: "p-ccvm", hash: sha(aside), author: "Mini 1" },
        { skill: "q-ccvm", hash: sha(notAside), author: "ccvm" },
        { skill: "r-ccvm", hash: sha(otherTag), author: "ccvm" },
        { skill: "other", hash: sha(wrongName), author: "ccvm" },
        { skill: "ccvm", hash: sha(aside), author: "ccvm" },
        { skill: "s-ccvm", hash: "0".repeat(64), author: "ccvm" },
        { skill: "t-ccvm", author: "ccvm" },
        "not a record",
      ],
    });
    assert.deepEqual(asides, { asides: [{ skill: "p-ccvm", base: "p", tag: "ccvm", author: stationTag("Mini 1"), body: "body line\n" }] });
    assert.deepEqual(await p.ok("asides", { blobs }), { asides: [] });
  });
});

/// A tree as it is on the disk: each path's kind and content (a link's target), in order.
function tree(dir: string): string[] {
  const out: string[] = [];
  const walk = (at: string, rel: string) => {
    for (const name of readdirSync(at).sort()) {
      const path = join(at, name);
      const r = rel === "" ? name : `${rel}/${name}`;
      const meta = lstatSync(path);
      if (meta.isSymbolicLink()) out.push(`${r} -> ${readlinkSync(path)}`);
      else if (meta.isDirectory()) {
        out.push(`${r}/`);
        walk(path, r);
      } else out.push(`${r} = ${readFileSync(path).toString("hex")}`);
    }
  };
  walk(dir, "");
  return out;
}

function make(dir: string, files: Record<string, Buffer | string>) {
  mkdirSync(dir, { recursive: true });
  for (const [path, data] of Object.entries(files)) {
    mkdirSync(join(dir, path, ".."), { recursive: true });
    writeFileSync(join(dir, path), data);
  }
}

test("shared skills: base64 read and written as the reference, a path leading out of the skill refused with nothing changed", { skip: unixOnly }, async () => {
  await withMemory(async (p) => {
    const root = fresh("memory-skills-");
    const read = async (dir: string, bytes: boolean) => {
      const answer = await p.ask("skillRead", { dir, maxBytes: MAX_SKILL_BYTES, maxFiles: MAX_SKILL_FILES, bytes });
      return answer.error === undefined ? answer : { failed: true };
    };
    const refRead = (dir: string, bytes: boolean): Json => {
      try {
        const files = readSkill(dir);
        return { hash: skillHash(files), hasSkillMd: files["SKILL.md"] !== undefined, ...(bytes ? { files: encodeFiles(files) } : {}) };
      } catch (e) {
        return e instanceof TooLarge ? { tooLarge: true } : { failed: true };
      }
    };
    const same = async (dir: string, label: string) => {
      for (const bytes of [false, true]) assert.deepEqual(await read(dir, bytes), refRead(dir, bytes), `${label} (bytes: ${bytes})`);
    };
    const skill = join(root, "skill");
    make(skill, {
      "SKILL.md": "# a skill\n",
      "empty.txt": "",
      "bin.dat": Buffer.from([0, 1, 2, 255, 254, 0x80, 0xc0, 0xaf]),
      "a/b/c/deep.md": "deep\n",
      "中文/名字.md": "中文\n",
      "😀/é.md": "x",
      "SKILL.conflict-0123456789ab.md": "kept beside",
    });
    mkdirSync(join(skill, "empty-dir"));
    symlinkSync(join(skill, "SKILL.md"), join(skill, "link.md"));
    await same(skill, "the tree");
    const files = (await read(skill, true)).files;
    // Bytes that are no UTF-8 come back as they were.
    assert.deepEqual(Buffer.from(files["bin.dat"], "base64"), Buffer.from([0, 1, 2, 255, 254, 0x80, 0xc0, 0xaf]));
    make(join(root, "nomd"), { "README.md": "r" });
    await same(join(root, "nomd"), "no SKILL.md");
    mkdirSync(join(root, "none"));
    await same(join(root, "none"), "an empty directory");
    await same(join(root, "gone"), "no directory");
    make(join(root, "201"), Object.fromEntries(Array.from({ length: 201 }, (_, i) => [i === 0 ? "SKILL.md" : `f/${i}.md`, `${i}`])));
    await same(join(root, "201"), "201 files");
    make(join(root, "max1"), { "SKILL.md": "ab", "big.bin": Buffer.alloc(MAX_SKILL_BYTES - 1, 7) });
    await same(join(root, "max1"), "512 KiB and a byte");

    // Written: the same tree as the reference writes, the one before replaced; then read back, the same hash.
    let n = 0;
    const write = async (before: Record<string, string> | null, given: Record<string, string>, label: string) => {
      const at = join(root, `w${n++}`);
      const refDir = join(at, "ref", "skill");
      const mbDir = join(at, "mb", "skill");
      for (const d of [refDir, mbDir]) if (before !== null) make(d, before);
      let refError: string | null = null;
      try {
        writeSkill(refDir, given);
      } catch (e) {
        refError = (e as Error).message;
      }
      const answer = await p.ask("skillWrite", { dir: mbDir, files: given });
      assert.equal(answer.error ?? null, refError, `${label}: refused alike`);
      if (refError === null) {
        assert.deepEqual(answer, { written: true }, label);
        assert.deepEqual(tree(join(at, "mb")), tree(join(at, "ref")), `${label}: the same tree`);
        await same(mbDir, `${label}: read back`);
      } else {
        assert.deepEqual(before === null ? [] : tree(mbDir), before === null ? [] : tree(refDir), `${label}: the skill as it was`);
        assert.deepEqual(readdirSync(join(at, "mb")).filter((x) => x.includes(".tmp-")), [], `${label}: no temporary left`);
      }
    };
    const before = { "SKILL.md": "old", "old/gone.md": "gone", "SKILL.conflict-x.md": "c" };
    await write(before, { "SKILL.md": b64("new\n"), "a/b/c.md": b64("c"), "中文.md": b64("中"), "bin": b64(Buffer.from([0, 255, 0xc0])), "empty": "" }, "a skill replaced");
    await write(null, { "SKILL.md": b64("first") }, "a skill where there was none");
    await write(before, {}, "no files");
    await write(null, { "a": "YQ", "b": "-_8", "c": "Y Q = =" }, "base64 as Node reads it");
    for (const bad of ["../escape", "/abs", "a/../b", "a//b", "./x", "a/", "", "..", "C:\\x", "a\\..\\b"]) {
      await write(before, { "SKILL.md": b64("new"), [bad]: b64("x") }, `the path ${JSON.stringify(bad)} (${safePath(bad) ? "safe" : "refused"} here)`);
    }
    // Nothing written outside the skill by any of them.
    assert.equal(existsSync(join(root, "escape")), false);

    // An edit on an older copy, kept beside the skill as the reference keeps it.
    for (const [peer, content] of [["0123456789abcdef0123", Buffer.from("late\n")], ["ab", Buffer.from([0, 1, 255])], ["中文站点名字很长很长很长很长", Buffer.from("")]] as const) {
      const at = join(root, `c${n++}`);
      make(join(at, "ref"), { "SKILL.md": "s" });
      make(join(at, "mb"), { "SKILL.md": "s" });
      writeConflict(join(at, "ref"), peer, content.toString("base64"));
      assert.deepEqual(await p.ok("skillConflict", { dir: join(at, "mb"), peer, content: content.toString("base64") }), { written: true });
      assert.deepEqual(tree(join(at, "mb")), tree(join(at, "ref")), peer);
    }
  });
});

test("malformed lines, unknown ops and missing fields are answered `{id, error}` and the process goes on", { skip }, async () => {
  await withMemory(async (p) => {
    const tagsOk = async () => assert.deepEqual(await p.ok("tags", { names: ["a b"] }), { tags: ["a-b"] });
    for (const line of ["{not valid json", "[1,2,3]", "42", "\"op\"", "null", "{\"op\": \"tags\""]) {
      assert.deepEqual(await p.raw(line), { id: null, error: "unknown memory op " }, JSON.stringify(line));
      await tagsOk();
    }
    p.silent("");
    await tagsOk();
    // Any JSON id comes back as it was sent.
    for (const id of ["s", 0, 2 ** 40, true, null, [1, "x"], { deep: { x: [1] } }, "中文😀"]) {
      assert.deepEqual(await p.raw(JSON.stringify({ id, op: "tags", names: ["x"] })), { id, tags: ["x"] });
    }
    assert.deepEqual(await p.raw(JSON.stringify({ op: "tags", names: [] })), { id: null, tags: [] });
    assert.deepEqual(await p.raw(JSON.stringify({ id: 9 })), { id: 9, error: "unknown memory op " });
    assert.deepEqual(await p.raw(JSON.stringify({ id: 10, op: 5 })), { id: 10, error: "unknown memory op " });
    assert.equal(await p.fails("nothing"), "unknown memory op nothing");
    assert.equal(await p.fails("Scan"), "unknown memory op Scan");
    await tagsOk();
    const dir = fresh();
    const theirs = { hash: "a".repeat(64), at: 1, by: "b".repeat(64), prev: [], size: 1, mode: 0o644 };
    const missing: [string, Record<string, unknown>, string | null][] = [
      ["scan", {}, "no dir"],
      ["decide", {}, "no record"],
      ["decide", { path: "MEMORY.md", theirs: "x" }, "no record"],
      ["decide", { theirs }, "no path"],
      ["skillRead", {}, "no dir"],
      ["skillWrite", {}, "no dir"],
      ["skillConflict", {}, "no dir"],
      ["skillConflict", { dir }, "no peer"],
      ["skillConflict", { dir, peer: "x" }, "no content"],
      ["isText", {}, "no bytes"],
      ["isText", { bytes: 5 }, "no bytes"],
      ["merge3", { newer: "", older: "" }, "no base"],
      ["merge3", { base: "", older: "" }, "no newer"],
      ["merge3", { base: "", newer: "" }, "no older"],
      ["union", { older: "" }, "no newer"],
      ["union", { newer: "" }, "no older"],
      ["alike", { b: "" }, "no a"],
      ["alike", { a: "" }, "no b"],
      ["conflictPath", { station: "x" }, "no path"],
      ["conflictPath", { path: "MEMORY.md" }, "no station"],
      // Hex that is no hex: refused (its words the program's own).
      ["isText", { bytes: "zz" }, null],
      ["isText", { bytes: "abc" }, null],
      ["merge3", { base: "0g", newer: "", older: "" }, null],
    ];
    for (const [op, args, error] of missing) {
      const said = await p.fails(op, args);
      if (error !== null) assert.equal(said, error, `${op} ${JSON.stringify(args)}`);
      await tagsOk();
    }
    assert.deepEqual(readdirSync(dir), [], "nothing written by a refused ask");
  });
});

test("stdin closed with nothing asked: exit 0, nothing said", { skip }, async () => {
  const child = spawn(candidate(), ["--builder", "memory", "--sep", sep, "--shell-dir", fresh("memory-shell-")], { stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
  let stdout = "";
  let stderr = "";
  child.stdout!.on("data", (c: Buffer) => { stdout += c.toString("utf8"); });
  child.stderr!.on("data", (c: Buffer) => { stderr += c.toString("utf8"); });
  const closed = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve, reject) => {
    const timer = setTimeout(() => { child.kill("SIGKILL"); reject(new Error(`no exit within ${ASK_TIMEOUT_MS} ms`)); }, ASK_TIMEOUT_MS);
    child.on("error", (e) => { clearTimeout(timer); reject(e); });
    child.on("close", (code, signal) => { clearTimeout(timer); resolve({ code, signal }); });
  });
  child.stdin!.end();
  assert.deepEqual(await closed, { code: 0, signal: null }, stderr);
  assert.equal(stdout, "");
});
