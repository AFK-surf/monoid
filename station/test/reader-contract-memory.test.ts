// Black-box contract tests for `--builder memory` against any reader binary, spoken to over its stdio alone.
//
// By default this runs against the shipped MoonBit `stillfail-reader` (`mbReaderBinary()`). Set
// `STILLFAIL_READER_CANDIDATE=/path/to/stillfail-pion` to verify a candidate binary with zero edits to this suite: a
// candidate named but empty, missing or not executable fails every test, never skips. With no candidate named and no
// reader built, the tests skip saying so, except under CI (`CI` set), where they fail.
//
// The protocol (station/mb/src/memory/answer.mbt, station/src/share/memory-mb.ts): a line of JSON an ask `{id, op, …}`,
// answered by one line `{id, …}` or `{id, error}`, in order; an empty line is passed over; a line that is no JSON
// object is answered `{id: null, error}`. Content goes as hex both ways (what is no UTF-8 arrives as it is), a shared
// skill's files as base64. Every op of answer.mbt is asked here (`scan`, `decide`, `have`, `hash`, `asides`,
// `alikeKept`, `tags`, `skillRead`, `skillWrite`, `skillConflict`, `isText`, `matches`, `merge3`, `union`, `alike`,
// `conflictPath`), each answer held to the TypeScript it replaced (test/reference/memory-merge.ts,
// test/reference/share-skills.ts) or to the contract's own fixed output, with the arguments the station sends
// (share/memory.ts, share/index.ts). The station sends asks back to back without waiting (`MemoryProgram.ask`), so asks
// are pipelined here too, written in one write and split across writes, lines past 1 MiB among them. Each test keeps
// one process and its stdin open across all its asks, and ends it only by closing stdin: it must exit 0 having said
// nothing more. Error words are the program's own except a shared skill's refused path, which is the reference's.
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
import { join, resolve, sep } from "node:path";
import { after, test } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { BUILTIN_SKILLS, FEEDBACK_SKILL, RETIRED_SKILLS } from "../src/sessions/agent-home.ts";
import type { Rec } from "../src/share/memory.ts";
import { memoryPath, SKIPPED } from "../src/share/memory.ts";
import { alike, conflictPath, decide, isText, matches, merge3, readMemory, stationTag, unionLines } from "./reference/memory-merge.ts";
import { encodeFiles, MAX_SKILL_BYTES, MAX_SKILL_FILES, readSkill, safePath, skillHash, TooLarge, writeConflict, writeSkill } from "./reference/share-skills.ts";

/// The longest any one ask (or the exit after stdin's end) may take before the process is killed and the test fails: a
/// bound, never a wait.
const ASK_TIMEOUT_MS = 30_000;
const unix = process.platform !== "win32";

type Json = any;

/// The binary under test, or why there is none.
function resolveCandidate(): { binary: string } | { fail: string } | { skip: string } {
  const raw = process.env.STILLFAIL_READER_CANDIDATE;
  if (raw !== undefined) {
    if (raw.trim() === "") return { fail: "STILLFAIL_READER_CANDIDATE is set but empty" };
    // (checked and spawned at the one absolute path: never a PATH lookup, never another working directory's)
    const binary = resolve(raw);
    if (!existsSync(binary)) return { fail: `STILLFAIL_READER_CANDIDATE does not exist: ${binary}` };
    try {
      if (!statSync(binary).isFile()) return { fail: `STILLFAIL_READER_CANDIDATE is not a file: ${binary}` };
      accessSync(binary, fsConstants.X_OK);
    } catch {
      return { fail: `STILLFAIL_READER_CANDIDATE is not executable: ${binary}` };
    }
    return { binary };
  }
  const binary = mbReaderBinary();
  if (binary !== null) return { binary: resolve(binary) };
  const why = "stillfail-reader is not built here; set STILLFAIL_READER_CANDIDATE or run via `node ../scripts/native.ts run reader -- ...`";
  return process.env.CI ? { fail: why } : { skip: why };
}

const RESOLVED = resolveCandidate();
const skip = "skip" in RESOLVED ? RESOLVED.skip : false;

/// The candidate's path; one that is not there fails the test that asks.
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

type Waiter = { resolve: (j: Json) => void; reject: (e: Error) => void; timer: NodeJS.Timeout };

/// One `--builder memory` process, its stdin kept open: each ask answered by the next line it says, in order. What the
/// protocol forbids (a line no ask waits for, a line that is no JSON, the process ending before its stdin did, an ask
/// unanswered in time) is kept as its `protocolError`, which fails every ask after it and `end()`, whatever else.
class MemoryProcess {
  readonly #child: ChildProcess;
  readonly #waiting: Waiter[] = [];
  #carry: Buffer = Buffer.alloc(0);
  #stderr = "";
  #protocolError: Error | null = null;
  #ending = false;
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
    child.stdout!.on("data", (c: Buffer) => this.#heard(c));
    this.#closed = new Promise((done) => {
      let ended = false;
      const end = (code: number | null, signal: NodeJS.Signals | null) => {
        if (ended) return;
        ended = true;
        if (!this.#ending) this.#forbid(`the process ended before its stdin did (code ${code}, signal ${signal}); stderr: ${this.#stderr}`);
        this.#rejectAll(new Error(`the process ended (code ${code}, signal ${signal}) with an ask unanswered; stderr: ${this.#stderr}`));
        done({ code, signal });
      };
      child.on("error", (e) => {
        this.#forbid(`the process failed: ${e.message}`);
        // (a process that never started says no close of its own)
        if (child.pid === undefined) end(null, null);
      });
      child.on("close", (code, signal) => end(code, signal));
    });
  }

  #rejectAll(e: Error) {
    for (const w of this.#waiting.splice(0)) {
      clearTimeout(w.timer);
      w.reject(e);
    }
  }

  #forbid(message: string) {
    if (this.#protocolError === null) this.#protocolError = new Error(message);
    this.#rejectAll(this.#protocolError);
    this.#child.kill("SIGKILL");
  }

  /// Lines cut at their `\n` bytes, each decoded whole (a character split between two reads stays one).
  #heard(chunk: Buffer) {
    this.#carry = this.#carry.length === 0 ? chunk : Buffer.concat([this.#carry, chunk]);
    for (let nl = this.#carry.indexOf(0x0a); nl >= 0; nl = this.#carry.indexOf(0x0a)) {
      const line = this.#carry.subarray(0, nl).toString("utf8");
      this.#carry = this.#carry.subarray(nl + 1);
      let parsed: Json;
      try {
        parsed = JSON.parse(line);
      } catch {
        return this.#forbid(`stdout said a line that is no JSON: ${JSON.stringify(line.slice(0, 300))}`);
      }
      const w = this.#waiting.shift();
      if (w === undefined) return this.#forbid(`stdout said a line no ask waits for: ${line.slice(0, 300)}`);
      clearTimeout(w.timer);
      w.resolve(parsed);
    }
  }

  /// The next answer, whatever writes ask for it.
  expect(): Promise<Json> {
    if (this.#protocolError !== null) return Promise.reject(this.#protocolError);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.#forbid(`an ask unanswered within ${ASK_TIMEOUT_MS} ms; stderr: ${this.#stderr}`), ASK_TIMEOUT_MS);
      this.#waiting.push({ resolve, reject, timer });
    });
  }

  /// Bytes written to stdin as they are, once they are handed on.
  write(bytes: string | Buffer): Promise<void> {
    return new Promise((resolve, reject) => this.#child.stdin!.write(bytes, (e) => (e ? reject(e) : resolve())));
  }

  /// The answer to one raw line (written with its `\n`).
  raw(line: string): Promise<Json> {
    const answer = this.expect();
    void this.write(`${line}\n`).catch(() => {});
    return answer;
  }

  /// A fresh id for an ask.
  id(): number {
    return ++this.#next;
  }

  /// What `op` with `args` is answered, its `id` checked as the one sent and taken off.
  async ask(op: string, args: Record<string, unknown> = {}): Promise<Json> {
    const id = this.id();
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

  /// An ask that must fail: its error (words of its own, not empty), the only thing said.
  async fails(op: string, args: Record<string, unknown> = {}): Promise<string> {
    const answer = await this.ask(op, args);
    assert.ok(typeof answer.error === "string" && answer.error.length > 0, `${op} ${JSON.stringify(args).slice(0, 200)} fails, answered ${JSON.stringify(answer).slice(0, 300)}`);
    assert.deepEqual(Object.keys(answer), ["error"], `${op}: nothing but its error`);
    return answer.error;
  }

  /// Its end by stdin's alone: no protocol error before or after, no ask left, exit 0 with no signal, no line cut short.
  /// What this holds: an ask still waiting when the process ends fails, and so does any line the protocol forbids that
  /// was said before it closed. A process that exits 0 by itself just after its last answer cannot be told apart here
  /// from one that saw stdin's end; that it lives on after an answer is held by the asks each test sends after it.
  async end(): Promise<void> {
    this.#ending = true;
    let timer: NodeJS.Timeout | undefined;
    try {
      if (this.#protocolError !== null) throw this.#protocolError;
      assert.equal(this.#waiting.length, 0, "no ask left unanswered");
      this.#child.stdin!.end();
      const { code, signal } = await new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve, reject) => {
        timer = setTimeout(() => reject(new Error(`no exit within ${ASK_TIMEOUT_MS} ms of stdin's end; stderr: ${this.#stderr}`)), ASK_TIMEOUT_MS);
        void this.#closed.then(resolve);
      });
      // (a line said after the last answer, however soon the process exited after it)
      if (this.#protocolError !== null) throw this.#protocolError;
      assert.equal(signal, null, `ended by a signal; stderr: ${this.#stderr}`);
      assert.equal(code, 0, `exit ${code}; stderr: ${this.#stderr}`);
      assert.equal(this.#carry.length, 0, `stdout ended with a line cut short: ${JSON.stringify(this.#carry.toString("utf8").slice(0, 300))}`);
    } finally {
      clearTimeout(timer);
      this.#rejectAll(new Error("the test ended"));
      if (this.#child.exitCode === null && this.#child.signalCode === null) this.#child.kill("SIGKILL");
    }
  }

  /// Ended at once after a failure: killed, its stdin closed, no timer left.
  async kill(): Promise<void> {
    this.#ending = true;
    this.#rejectAll(new Error("the test failed"));
    this.#child.stdin!.destroy();
    this.#child.kill("SIGKILL");
    let timer: NodeJS.Timeout | undefined;
    await new Promise<void>((resolve) => {
      timer = setTimeout(resolve, ASK_TIMEOUT_MS);
      void this.#closed.then(() => resolve());
    });
    clearTimeout(timer);
  }
}

/// A test's process, ended by stdin's EOF once the test is done (the end checked), killed if the test failed first.
async function withMemory(f: (p: MemoryProcess) => Promise<void>): Promise<void> {
  const p = new MemoryProcess();
  let failed = true;
  try {
    await f(p);
    failed = false;
  } finally {
    if (failed) await p.kill();
  }
  await p.end();
}

const sha = (b: Buffer | string) => createHash("sha256").update(b).digest("hex");
const hex = (s: string | Buffer) => (typeof s === "string" ? Buffer.from(s, "utf8") : s).toString("hex");
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
/// Bytes from a seed (every value, so most of them no UTF-8).
const bytesOf = (seed: number, n: number) => {
  const r = rng(seed);
  return Buffer.from(Array.from({ length: n }, () => Math.floor(r() * 256)));
};
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
      // The same version merged with itself is the reference's of it too.
      const same = merge3(base, newer, newer);
      assert.deepEqual(await p.ok("merge3", { base: hex(base), newer: hex(newer), older: hex(newer) }), { value: same === null ? null : hex(same) });
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

test("pipelined asks: sent back to back, several in one write, one split across writes (inside a character)", { skip }, async () => {
  await withMemory(async (p) => {
    const names = ["中文 站点", "😀 emoji 😀", "Studio's Mac", "é"];
    // Sent as the station sends them, none waiting for the one before: each answered by its own id, in order.
    await Promise.all(Array.from({ length: 60 }, (_, i) => {
      const name = `${names[i % names.length]} ${i}`;
      const text = `- ${name}\n`;
      return i % 3 === 0 ? p.ok("tags", { names: [name] }).then((a) => assert.deepEqual(a, { tags: [stationTag(name)] }))
        : i % 3 === 1 ? p.ok("isText", { bytes: hex(text) }).then((a) => assert.deepEqual(a, { value: true }))
        : p.ok("conflictPath", { path: "MEMORY.md", station: name }).then((a) => assert.deepEqual(a, { value: conflictPath("MEMORY.md", name) }));
    }));

    // Several lines in one write, an empty one and one that is no JSON among them: every line answered (the empty one
    // passed over), none left in the buffer.
    const ids = [p.id(), p.id(), p.id()];
    const answers = [p.expect(), p.expect(), p.expect(), p.expect()];
    await p.write([
      JSON.stringify({ id: ids[0], op: "tags", names: ["a b"] }),
      "",
      "{not json",
      JSON.stringify({ id: ids[1], op: "isText", bytes: "00" }),
      JSON.stringify({ id: ids[2], op: "tags", names: ["中文 站点"] }),
      "",
    ].join("\n"));
    const [a, bad, b, c] = await Promise.all(answers);
    assert.deepEqual(a, { id: ids[0], tags: ["a-b"] });
    assert.equal(bad.id, null);
    assert.ok(typeof bad.error === "string" && bad.error.length > 0);
    assert.deepEqual(b, { id: ids[1], value: false });
    assert.deepEqual(c, { id: ids[2], tags: [stationTag("中文 站点")] });

    // One ask written a byte or two at a time, cut inside its multi-byte characters: answered once, whole.
    const id = p.id();
    const name = "中文😀é 站点";
    const line = Buffer.from(`${JSON.stringify({ id, op: "tags", names: [name] })}\n`);
    const answer = p.expect();
    for (let at = 0; at < line.length; at += 2) await p.write(line.subarray(at, Math.min(line.length, at + 2)));
    assert.deepEqual(await answer, { id, tags: [stationTag(name)] });
  });
});

const A = "a".repeat(64);
const B = "b".repeat(64);
const NAMES: Record<string, string> = { [A]: "ccvm", [B]: "Mini 1" };
const nameOf = (s: string) => NAMES[s] ?? s.slice(0, 8);
/// share/memory.ts PREV_MOST, what the station sends.
const PREV_MOST = 16;

test("decide: the reference's outcome, record and merged content (three-way, conflicts kept, alike once, deleted, binary, versions before trimmed)", { skip }, async () => {
  await withMemory(async (p) => {
    const ask = (path: string, mine: Rec | undefined, theirs: Rec, contents: Map<string, Buffer>, blobs: string, prevMost = PREV_MOST) => {
      const given: Record<string, string> = {};
      for (const [h, b] of contents) given[h] = b.toString("hex");
      const names: Record<string, string> = { [theirs.by]: nameOf(theirs.by), ...(mine ? { [mine.by]: nameOf(mine.by) } : {}) };
      return p.ok("decide", { path, mine: mine ?? null, theirs, names, given, blobs, prevMost });
    };
    const both = async (path: string, mine: Rec | undefined, theirs: Rec, contents: Map<string, Buffer>, kept: Map<string, Buffer>) => {
      const blobs = fresh("memory-blobs-");
      for (const [h, b] of kept) writeFileSync(join(blobs, h), b);
      const all = new Map([...kept, ...contents]);
      const want = decide(path, mine, theirs, (h) => all.get(h) ?? null, nameOf);
      const got = await ask(path, mine, theirs, contents, blobs);
      const label = `decide(${path}, ${JSON.stringify(mine)}, ${JSON.stringify(theirs)})`;
      assert.equal(got.kind, want.kind, label);
      if (want.kind === "keep") assert.deepEqual(got, { kind: "keep" }, label);
      if (want.kind === "take") assert.deepEqual(got, { kind: "take", content: all.has(theirs.hash) }, label);
      if (want.kind === "merge") {
        assert.deepEqual(Object.keys(got).sort(), ["beside", "kind", "rec"], label);
        assert.deepEqual(got.rec, want.rec, label);
        const content = all.get(got.rec.hash) ?? readFileSync(join(blobs, got.rec.hash));
        assert.deepEqual(content, want.content, label);
        if (!all.has(got.rec.hash) && unix) assert.equal(statSync(join(blobs, got.rec.hash)).mode & 0o777, 0o600, label);
        if (want.beside === null) assert.ok(got.beside === null || !memoryPath(got.beside.path), label);
        else assert.deepEqual(got.beside, { path: want.beside.path, rec: want.beside.rec }, label);
      }
      return { got, want };
    };
    const rec = (text: string | null, by: string, at: number, prev: string[] = [], extra: Partial<Rec> = {}): Rec => ({ hash: text === null ? "" : sha(text), at, by, prev, size: text === null ? 0 : Buffer.byteLength(text), mode: 0o644, ...extra });
    const c = (...texts: string[]) => new Map(texts.map((t) => [sha(t), Buffer.from(t)] as [string, Buffer]));
    const base = "- one\n- two\n";
    const mine = "- one\n- two\n- mine\n";
    const theirs = "- zero\n- one\n- two\n";
    // Theirs only; the same content both sides; one after the other; the very same record (kept as it is).
    assert.equal((await both("MEMORY.md", undefined, rec(theirs, B, 2), c(theirs), new Map())).got.kind, "take");
    await both("MEMORY.md", rec(mine, A, 2), rec(mine, B, 3), new Map(), c(mine));
    await both("MEMORY.md", rec(mine, B, 3), rec(mine, A, 2), new Map(), c(mine));
    assert.equal((await both("MEMORY.md", rec(mine, A, 2), rec(mine, A, 2), new Map(), c(mine))).got.kind, "keep");
    await both("MEMORY.md", rec(mine, A, 2, [sha(base)]), rec(theirs, B, 3, [sha(mine)]), c(theirs), c(mine));
    // Three-way from one base, without a conflict: both changes in.
    assert.equal((await both("MEMORY.md", rec(mine, A, 2, [sha(base)]), rec(theirs, B, 3, [sha(base)]), c(theirs), c(mine, base))).got.kind, "merge");
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

    // The versions before, trimmed: 1 + 16 on each side past PREV_MOST * 2, the record's `prev` the reference's (its
    // first 32); asked to keep fewer (`prevMost`), the first PREV_MOST * 2 of them as the reference orders them.
    const older = (side: string) => Array.from({ length: PREV_MOST - 1 }, (_, i) => sha(`${side} v${i}`));
    const mineRec = rec(mine, A, 2, [sha(base), ...older("mine")]);
    const theirsRec = rec(theirs, B, 3, [sha(base), ...older("theirs")]);
    const trimmed = await both("MEMORY.md", mineRec, theirsRec, c(theirs), c(mine, base));
    assert.equal(trimmed.got.kind, "merge");
    assert.equal(trimmed.got.rec.prev.length, PREV_MOST * 2);
    for (const most of [1, 2, 5]) {
      const blobs = fresh("memory-blobs-");
      for (const t of [mine, base]) writeFileSync(join(blobs, sha(t)), t);
      const got = await ask("MEMORY.md", mineRec, theirsRec, c(theirs), blobs, most);
      assert.equal(got.kind, "merge");
      const want = trimmed.want as Extract<typeof trimmed.want, { kind: "merge" }>;
      assert.deepEqual(got.rec, { ...want.rec, prev: want.rec.prev.slice(0, most * 2) }, `prevMost ${most}`);
    }

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

const SCAN = { builtin: [...BUILTIN_SKILLS, FEEDBACK_SKILL, ...RETIRED_SKILLS], skipped: [...SKIPPED], fileMost: 512 * 1024, skillMost: 4 * 1024 * 1024, skillFiles: 200 };

test("files: scan, hash, have and asides read a memory's tree as the reference, what changed kept in blobs/ privately", { skip }, async () => {
  await withMemory(async (p) => {
    const dir = fresh("memory-home-");
    const put = (path: string, text: string | Buffer, mode = 0o644) => {
      mkdirSync(join(dir, path, ".."), { recursive: true });
      writeFileSync(join(dir, path), text);
      if (unix) chmodSync(join(dir, path), mode);
    };
    put("MEMORY.md", "# 全局记忆\n- 一条。\n");
    utimesSync(join(dir, "MEMORY.md"), 1_700_000_000.4567, 1_700_000_000.4567);
    put("skills/proj/SKILL.md", "---\nname: proj\n---\n- a\n");
    put("skills/proj/run.sh", "#!/bin/sh\n", 0o755);
    put("skills/proj/key", "secret\n", 0o600);
    put("skills/proj/b/c/d.txt", "deep\n");
    put("skills/proj/node_modules/x.js", "x\n");
    put("skills/proj/bin", Buffer.from([0, 1, 2, 255]));
    put(`skills/${BUILTIN_SKILLS[0]}/SKILL.md`, "built in\n");
    put("skills/__pycache__/SKILL.md", "x\n");
    put("skills/中文技能/SKILL.md", "---\nname: 中文技能\n---\n- 中\n");
    put("skills/large/SKILL.md", "---\nname: large\n---\n");
    put("skills/large/big", Buffer.alloc(512 * 1024 + 1, 0x61));
    if (unix) {
      symlinkSync(join(dir, "skills/proj/b/c/d.txt"), join(dir, "skills/proj/link.txt"));
      symlinkSync(join(dir, "skills/proj"), join(dir, "skills/linked"));
    }

    const want = await readMemory(dir);
    const scan = (blobs: string, kept: Record<string, string>) => p.ok("scan", { dir, blobs, kept, ...SCAN });
    const blobs = fresh("memory-blobs-");
    const got = await scan(blobs, {});
    assert.deepEqual(got.files.map((f: Json) => f.path), [...want.files.keys()]);
    assert.deepEqual(new Set(got.held), want.held);
    for (const f of got.files) {
      const w = want.files.get(f.path)!;
      assert.deepEqual({ hash: f.hash, size: f.size, mode: f.mode, mtime: f.mtime }, { hash: sha(w.bytes), size: w.bytes.length, mode: w.mode, mtime: w.mtime }, f.path);
      assert.deepEqual(readFileSync(join(blobs, f.hash)), w.bytes, f.path);
      if (unix) assert.equal(statSync(join(blobs, f.hash)).mode & 0o777, 0o600, f.path);
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

    // A MEMORY.md of nothing yet: told `empty`, no blob kept; one with a line: not told so, kept; one the station keeps a
    // record of already: told as any other.
    for (const [text, empty] of [["# still.fail memory\n", true], ["\ufeff  # ember memory \n\n", true], ["", true], ["# still.fail memory\n- one\n", false], [Buffer.from([0x23, 0xff]), false]] as [string | Buffer, boolean][]) {
      const home = fresh("memory-home-");
      writeFileSync(join(home, "MEMORY.md"), text);
      const b = fresh("memory-blobs-");
      const first = await p.ok("scan", { dir: home, blobs: b, kept: {}, ...SCAN });
      assert.equal(first.files.length, 1, JSON.stringify(text));
      if (empty) assert.equal(first.files[0].empty, true, JSON.stringify(text));
      else assert.equal("empty" in first.files[0], false, JSON.stringify(text));
      assert.deepEqual(readdirSync(b), empty ? [] : [first.files[0].hash], JSON.stringify(text));
      const known = await p.ok("scan", { dir: home, blobs: b, kept: { "MEMORY.md": "0".repeat(64) }, ...SCAN });
      assert.equal("empty" in known.files[0], false, JSON.stringify(text));
    }
  });
});

/// A tree as it is on the disk: each path's kind and content (a link's target), in order.
function tree(dir: string): string[] {
  if (!existsSync(dir)) return [];
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
      } else out.push(`${r} = ${sha(readFileSync(path))}`);
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

test("shared skills: base64 read and written as the reference, a path leading out of the skill refused with nothing changed", { skip }, async () => {
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
    if (unix) symlinkSync(join(skill, "SKILL.md"), join(skill, "link.md"));
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

    // Written: the same tree as the reference writes, the one before replaced; then read back, the same hash. Refused:
    // the reference's words, the skill and everything beside it (its parent's listing) as they were.
    let n = 0;
    const write = async (before: Record<string, string> | null, given: Record<string, string>, label: string) => {
      const at = join(root, `w${n++}`);
      const refDir = join(at, "ref", "skill");
      const mbDir = join(at, "mb", "skill");
      mkdirSync(join(at, "ref"), { recursive: true });
      mkdirSync(join(at, "mb"), { recursive: true });
      for (const d of [refDir, mbDir]) if (before !== null) make(d, before);
      const parentBefore = tree(join(at, "mb"));
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
        assert.deepEqual(tree(join(at, "mb")), parentBefore, `${label}: the skill and what is beside it as they were`);
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

    // As the station writes an edit (share/index.ts `takeEditNow`): `most` the decoded bytes in all, `check` only
    // checking. Refused or only checked, the skill and what is beside it stay as they were.
    const skillAt = (files: Record<string, string>) => {
      const at = join(root, `e${n++}`);
      make(join(at, "skill"), files);
      return { at, dir: join(at, "skill") };
    };
    const kept = { "SKILL.md": "kept\n", "a.md": "a" };
    const exact = Buffer.alloc(MAX_SKILL_BYTES - 5, 0x61);
    for (const [label, files, most, check, expect] of [
      ["checked only", { "SKILL.md": b64("new\n"), "b.md": b64("b") }, MAX_SKILL_BYTES, true, "written"],
      ["exactly `most` decoded bytes, checked", { "SKILL.md": b64("12345"), "big": b64(exact) }, MAX_SKILL_BYTES, true, "written"],
      ["base64 past `most`, decoded within it", { "big": b64(bytesOf(3, 400 * 1024)) }, 450 * 1024, true, "written"],
      ["a byte past `most`", { "SKILL.md": b64("123456"), "big": b64(exact) }, MAX_SKILL_BYTES, false, "refused"],
      ["a byte past `most`, checked", { "SKILL.md": b64("123456"), "big": b64(exact) }, MAX_SKILL_BYTES, true, "refused"],
      ["a file not given as text", { "SKILL.md": b64("new"), "n": 5 }, MAX_SKILL_BYTES, false, "refused"],
      ["a file given as null", { "SKILL.md": b64("new"), "n": null }, MAX_SKILL_BYTES, false, "refused"],
      ["a path out, checked", { "SKILL.md": b64("new"), "../escape": b64("x") }, MAX_SKILL_BYTES, true, "refused"],
    ] as [string, Record<string, unknown>, number, boolean, "written" | "refused"][]) {
      const { at, dir } = skillAt(kept);
      const was = tree(at);
      const answer = await p.ask("skillWrite", { dir, files, most, ...(check ? { check: true } : {}) });
      if (expect === "written") assert.deepEqual(answer, { written: true }, label);
      else assert.ok(typeof answer.error === "string" && answer.error.length > 0, `${label}: refused, answered ${JSON.stringify(answer).slice(0, 200)}`);
      assert.deepEqual(tree(at), was, `${label}: the skill and what is beside it as they were`);
    }
    // Within `most`, not only checked: written as the reference writes it.
    {
      const { at, dir } = skillAt(kept);
      const given = { "SKILL.md": b64("new\n"), "big": b64(exact.subarray(0, 1000)) };
      assert.deepEqual(await p.ok("skillWrite", { dir, files: given, most: MAX_SKILL_BYTES }), { written: true });
      const ref = join(at, "ref");
      make(ref, kept);
      writeSkill(ref, given);
      assert.deepEqual(tree(dir), tree(ref));
    }

    // Lines past 1 MiB each way: a skill of 800 KB of bytes written (its ask 1.07 MB of base64) and read back whole.
    {
      const big = { "SKILL.md": Buffer.from("---\nname: big\n---\n"), "one.bin": bytesOf(5, 400 * 1024), "two.bin": bytesOf(6, 400 * 1024) };
      const given = Object.fromEntries(Object.entries(big).map(([k, v]) => [k, v.toString("base64")]));
      assert.ok(JSON.stringify(given).length > 1 << 20);
      const at = join(root, `big${n++}`);
      const dir = join(at, "skill");
      mkdirSync(at);
      assert.deepEqual(await p.ok("skillWrite", { dir, files: given }), { written: true });
      const ref = join(at, "ref");
      writeSkill(ref, given);
      assert.deepEqual(tree(dir), tree(ref));
      const back = await p.ok("skillRead", { dir, maxBytes: 2 << 20, maxFiles: MAX_SKILL_FILES, bytes: true });
      assert.ok(JSON.stringify(back).length > 1 << 20);
      assert.deepEqual(back, { hash: skillHash(big), hasSkillMd: true, files: given });
      // Past the station's own limit: too large, as the reference says.
      assert.deepEqual(await p.ok("skillRead", { dir, maxBytes: MAX_SKILL_BYTES, maxFiles: MAX_SKILL_FILES, bytes: true }), { tooLarge: true });
    }

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
    const alive = async () => assert.deepEqual(await p.ok("tags", { names: ["a b"] }), { tags: ["a-b"] });
    const failed = (answer: Json, id: unknown, what: string) => {
      assert.deepEqual(Object.keys(answer).sort(), ["error", "id"], what);
      assert.deepEqual(answer.id, id, what);
      assert.ok(typeof answer.error === "string" && answer.error.length > 0, what);
    };
    for (const line of ["{not valid json", "[1,2,3]", "42", "\"op\"", "null", "{\"op\": \"tags\""]) {
      failed(await p.raw(line), null, JSON.stringify(line));
      await alive();
    }
    await p.write("\n");
    await alive();
    // Any JSON id comes back as it was sent.
    for (const id of ["s", 0, 2 ** 40, true, null, [1, "x"], { deep: { x: [1] } }, "中文😀"]) {
      assert.deepEqual(await p.raw(JSON.stringify({ id, op: "tags", names: ["x"] })), { id, tags: ["x"] });
    }
    assert.deepEqual(await p.raw(JSON.stringify({ op: "tags", names: [] })), { id: null, tags: [] });
    failed(await p.raw(JSON.stringify({ id: 9 })), 9, "no op");
    failed(await p.raw(JSON.stringify({ id: 10, op: 5 })), 10, "an op not a string");
    await p.fails("nothing");
    await p.fails("Scan");
    await alive();

    // Each ask with everything it needs but one field (or that one not of its kind): refused, nothing written.
    const dir = fresh();
    const skill = join(dir, "skill");
    make(skill, { "SKILL.md": "s" });
    const blobs = join(dir, "blobs");
    mkdirSync(blobs);
    const theirs = { hash: "a".repeat(64), at: 1, by: "b".repeat(64), prev: [], size: 1, mode: 0o644 };
    const missing: [string, Record<string, unknown>][] = [
      ["scan", { blobs, kept: {}, ...SCAN }],
      ["decide", { path: "MEMORY.md", blobs, prevMost: PREV_MOST }],
      ["decide", { path: "MEMORY.md", theirs: "x", blobs, prevMost: PREV_MOST }],
      ["decide", { theirs, blobs, prevMost: PREV_MOST }],
      ["hash", {}],
      ["skillRead", { maxBytes: MAX_SKILL_BYTES, maxFiles: MAX_SKILL_FILES }],
      ["skillWrite", { files: { "SKILL.md": b64("x") } }],
      ["skillConflict", { peer: "p", content: b64("x") }],
      ["skillConflict", { dir: skill, content: b64("x") }],
      ["skillConflict", { dir: skill, peer: "p" }],
      ["isText", {}],
      ["isText", { bytes: 5 }],
      ["merge3", { newer: "", older: "" }],
      ["merge3", { base: "", older: "" }],
      ["merge3", { base: "", newer: "" }],
      ["union", { older: "" }],
      ["union", { newer: "" }],
      ["alike", { b: "" }],
      ["alike", { a: "" }],
      ["conflictPath", { station: "x" }],
      ["conflictPath", { path: "MEMORY.md" }],
      // Hex that is no hex.
      ["isText", { bytes: "zz" }],
      ["isText", { bytes: "abc" }],
      ["merge3", { base: "0g", newer: "", older: "" }],
    ];
    const listing = () => tree(dir);
    const before = listing();
    for (const [op, args] of missing) {
      await p.fails(op, args);
      await alive();
    }
    assert.deepEqual(listing(), before, "nothing written by a refused ask");
  });
});

test("stdin closed with nothing asked: exit 0, nothing said", { skip }, async () => {
  await withMemory(async () => {});
});
