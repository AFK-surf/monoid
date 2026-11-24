// Black-box contract tests for `--builder packed` against any reader binary, spoken to over its stdio alone.
//
// By default this runs against the shipped MoonBit `stillfail-reader` (`mbReaderBinary()`), and skips (saying so) where
// it is not built. Set `STILLFAIL_READER_CANDIDATE=/path/to/stillfail-pion` to verify a candidate binary with zero edits
// to this suite: a candidate named but missing or not executable fails every test, never skips.
//
// The protocol (station/mb/src/packed/answer.mbt, station/src/sessions/packed-mb.ts): a line of JSON an ask `{id, op, …}`,
// answered by one line `{id, …}` or `{id, error}`, one at a time, nothing kept between asks; an empty line is passed over;
// a line that is no JSON object is answered `{id: null, error}`. Each test keeps one process and its stdin open across
// all its asks (as `PackedProgram` does), and ends it only by closing stdin: it must exit 0 with nothing more said.
// What it makes is held to the TypeScript it replaced (test/reference/packed.ts, test/reference/workspace-archive.ts).
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import {
  accessSync,
  chmodSync,
  closeSync,
  constants as fsConstants,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, test } from "node:test";
import { constants, zstdCompressSync, zstdDecompressSync } from "node:zlib";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { framesOf, readSegments, SEGMENT, seekTable, segmented, segmentedBytes, unpackedWhole } from "./reference/packed.ts";
import { fileOf, gnuHeader, packTree, padding, tarOfHeaders, unpackArchive } from "./reference/workspace-archive.ts";

/// The longest any one ask may take before the process is killed and the test fails (a bound, never a wait).
const ASK_TIMEOUT_MS = 60_000;

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
const unixOnly = skip || (process.platform === "win32" && "pipes, modes and links are Unix's");

/// The candidate's path; a named candidate that is not there fails the test that asks.
function candidate(): string {
  if ("fail" in RESOLVED) assert.fail(RESOLVED.fail);
  if ("skip" in RESOLVED) assert.fail(RESOLVED.skip);
  return RESOLVED.binary;
}

const dirs: string[] = [];
after(() => {
  for (const d of dirs) {
    if (!existsSync(d)) continue;
    const writable = (p: string) => {
      try {
        const meta = lstatSync(p);
        if (meta.isDirectory() && !meta.isSymbolicLink()) {
          chmodSync(p, 0o755);
          for (const n of readdirSync(p)) writable(join(p, n));
        }
      } catch {}
    };
    writable(d);
    rmSync(d, { recursive: true, force: true });
  }
});
const fresh = (prefix = "packed-contract-") => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  dirs.push(dir);
  return dir;
};

/// One `--builder packed` process, its stdin kept open: each ask written as a line and answered by the next line it
/// says, in order; any line said with no ask waiting, any non-JSON line, or a line cut short at its end fails it.
class PackedProcess {
  readonly #child: ChildProcess;
  readonly #waiting: { resolve: (j: Json) => void; reject: (e: Error) => void; timer: NodeJS.Timeout }[] = [];
  #carry = "";
  #stderr = "";
  #broken: Error | null = null;
  readonly #closed: Promise<{ code: number | null; signal: NodeJS.Signals | null }>;
  #next = 0;

  constructor() {
    const child = spawn(candidate(), ["--builder", "packed", "--shell-dir", fresh("packed-shell-")], {
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
        this.#break(new Error(`the packed process ended (code ${code}, signal ${signal}) with an ask unanswered; stderr: ${this.#stderr}`));
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

/// A test's process, ended (stdin's EOF, exit 0) when it is done, killed if it failed first.
async function withPacked(f: (p: PackedProcess) => Promise<void>): Promise<void> {
  const p = new PackedProcess();
  let ok = false;
  try {
    await f(p);
    ok = true;
  } finally {
    if (ok) await p.end();
    else await p.end().catch(() => {});
  }
}

const sha = (b: Buffer) => createHash("sha256").update(b).digest("hex");
const framesFile = (path: string) => {
  const file = openSync(path, "r");
  try {
    return framesOf(file);
  } finally {
    closeSync(file);
  }
};

/// Lines from a seed: UTF-8 of every width, bytes that are no UTF-8 (no line ends in them), JSON; one longer than a
/// segment where `long`.
function linesOf(seed: number, bytes: number, long = false): Buffer {
  let a = seed >>> 0;
  const r = () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), a | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const parts: Buffer[] = [];
  let n = 0;
  for (let i = 0; n < bytes; i++) {
    const kind = r();
    const length = Math.floor(r() * 300_000);
    const part = long && i === 3
      ? Buffer.alloc(SEGMENT + 333, 0x4c)
      : kind < 0.3
        ? Buffer.from("é中😀".repeat(Math.ceil(length / 9)).slice(0, Math.ceil(length / 3)))
        : kind < 0.5
          ? Buffer.from(Array.from({ length: Math.min(length, 4096) }, (_, k) => (k * 131 + i) % 256).filter((b) => b !== 0x0a))
          : Buffer.from(JSON.stringify({ i, said: "y".repeat(length) }));
    parts.push(part, Buffer.from("\n"));
    n += part.length + 1;
  }
  return Buffer.concat(parts).subarray(0, bytes);
}

/// What a put-away transcript holds read by the reference: whole, and in pages across its segments' ends.
function readByReference(path: string): Buffer {
  const whole = unpackedWhole(path);
  for (const [from, end] of [[0, whole.length], [Math.floor(whole.length / 3), Math.floor(whole.length / 3) + 1000], [Math.max(0, whole.length - 7), whole.length]] as const) {
    const pieces: Buffer[] = [];
    assert.ok(readSegments(path, from, end, (p) => (pieces.push(Buffer.from(p)), true)), `${path}: a table`);
    assert.deepEqual(Buffer.concat(pieces), whole.subarray(from, end), `${from}..${end}`);
  }
  return whole;
}

test("one process answers many asks in order, each with its own id, nothing kept from one to the next", { skip }, async () => {
  await withPacked(async (p) => {
    const lists: { packed: number; size: number }[][] = [[], [{ packed: 9, size: 0 }], [{ packed: 0xffffffff, size: 0 }, { packed: 1, size: 0xfffffffe }]];
    for (let i = 1; i < 30; i++) lists.push(Array.from({ length: i % 7 }, (_, k) => ({ packed: (i * 7919 + k * 104729) % 2 ** 32, size: (i * k * 15485863) % 2 ** 32 })));
    for (const frames of lists) {
      assert.deepEqual(await p.ok("table", { frames: frames.map((f) => [f.packed, f.size]) }), { table: seekTable(frames).toString("hex") });
    }
    // No frames given: the empty table.
    assert.deepEqual(await p.ok("table"), { table: seekTable([]).toString("hex") });
    // Any JSON id comes back as it was sent.
    for (const id of ["a-string", 0, -1, 2 ** 40, 1.5, true, null, [1, "x"], { nested: { deep: [1] } }, "中文😀"]) {
      assert.deepEqual(await p.raw(JSON.stringify({ id, op: "table", frames: [] })), { id, table: seekTable([]).toString("hex") });
    }

    const dir = fresh();
    const at = (name: string, bytes: Buffer) => (writeFileSync(join(dir, name), bytes), join(dir, name));
    const made = segmentedBytes(linesOf(1, SEGMENT + 999));
    const table = seekTable([{ packed: 5, size: 3 }]);
    const files = [
      at("segmented.zst", made),
      at("whole.zst", zstdCompressSync(Buffer.from("no table\n"))),
      at("empty.zst", Buffer.alloc(0)),
      at("short.zst", table.subarray(0, 16)),
      at("table-only.zst", seekTable([])),
      at("off-by-one.zst", Buffer.concat([Buffer.alloc(4), table])),
      at("adds-up.zst", Buffer.concat([Buffer.alloc(5), table])),
      at("cut.zst", made.subarray(0, made.length - 1)),
      at("reserved.zst", (() => { const t = Buffer.from(table); t[t.length - 5] = 0x01; return Buffer.concat([Buffer.alloc(5), t]); })()),
    ];
    // Asked in turn, again in another order: each answer is its file's alone.
    for (const order of [files, [...files].reverse()]) {
      for (const path of order) {
        const theirs = framesFile(path);
        assert.deepEqual(await p.ok("frames", { path }), { frames: theirs === null ? null : theirs.map((f) => [f.at, f.packed, f.from, f.size]) }, path);
        assert.deepEqual(await p.ok("segmented", { path }), { segmented: segmented(path) }, path);
      }
    }
    // A file not there: `segmented` false, `frames` an error; the next ask answered as ever.
    assert.deepEqual(await p.ok("segmented", { path: join(dir, "none.zst") }), { segmented: false });
    await p.fails("frames", { path: join(dir, "none.zst") });
    assert.deepEqual(await p.ok("table", { frames: [[1, 2]] }), { table: seekTable([{ packed: 1, size: 2 }]).toString("hex") });
  });
});

test("transcripts: put away in the reference's segments, checked, written back byte for byte, a damaged one refused", { skip }, async () => {
  await withPacked(async (p) => {
    const dir = fresh();
    const line = (n: number) => Buffer.concat([Buffer.alloc(n - 1, 0x7a), Buffer.from("\n")]);
    const cases: [string, Buffer][] = [
      ["empty", Buffer.alloc(0)],
      ["one byte", Buffer.from("x")],
      ["multi-byte UTF-8 and bytes that are no UTF-8", Buffer.concat([Buffer.from("中文 é 😀\n"), Buffer.from([0xff, 0xfe, 0x80, 0xc0, 0x0a, 0x00, 0x01])])],
      ["exactly a segment, no line end", Buffer.alloc(SEGMENT, 0x61)],
      ["a line end at the segment's last byte, more after", Buffer.concat([line(SEGMENT), Buffer.from("tail")])],
      ["several segments, one line longer than a segment", linesOf(7, SEGMENT * 2 + 777, true)],
    ];
    for (const [what, content] of cases) {
      const path = join(dir, "t.jsonl");
      const temp = join(dir, "t.jsonl.zst.writing");
      writeFileSync(path, content);
      assert.deepEqual(await p.ok("pack", { path, temp }), {}, what);
      // The transcript is left as it was (the station renames and removes); the temporary in the reference's segments.
      assert.deepEqual(readFileSync(path), content, what);
      const reference = join(dir, "reference.zst");
      writeFileSync(reference, segmentedBytes(content));
      const mine = framesFile(temp);
      assert.ok(mine !== null, `${what}: a table`);
      assert.deepEqual(mine.map((f) => [f.from, f.size]), framesFile(reference)!.map((f) => [f.from, f.size]), `${what}: cut where the reference cuts`);
      assert.ok(segmented(temp), what);
      assert.equal(sha(readByReference(temp)), sha(content), `${what}: the reference reads it as it was`);
      // The program reads its own and the reference's alike.
      for (const file of [temp, reference]) {
        assert.deepEqual(await p.ok("frames", { path: file }), { frames: framesFile(file)!.map((f) => [f.at, f.packed, f.from, f.size]) }, what);
        assert.deepEqual(await p.ok("segmented", { path: file }), { segmented: true }, what);
        assert.deepEqual(await p.ok("check", { path: file }), {}, what);
        const out = join(dir, "restored.jsonl");
        assert.deepEqual(await p.ok("restore", { source: file, temp: out }), {}, what);
        assert.equal(sha(readFileSync(out)), sha(content), `${what}: written back whole`);
        rmSync(out);
        // In segments already: not put away again, nothing written.
        const again = join(dir, "again.zst");
        assert.deepEqual(await p.ok("segment", { path, source: file, temp: again }), { segmented: false }, what);
        assert.equal(existsSync(again), false, what);
      }
      rmSync(temp);
      rmSync(path);
    }
  });
});

test("transcripts of before (one frame, several, a segment stored as it is) are put away again; a cut or damaged one never taken as whole", { skip }, async () => {
  await withPacked(async (p) => {
    const dir = fresh();
    const content = linesOf(3, SEGMENT + 54321);
    const half = content.length >> 1;
    const stored = (() => {
      const text = Buffer.from(`${"z".repeat(1023)}\n`.repeat(64));
      const head = Buffer.alloc(13);
      head.writeUInt32LE(0xfd2fb528, 0);
      head[4] = 0xe0;
      head.writeBigUInt64LE(BigInt(text.length), 5);
      const word = (text.length << 3) | 1;
      const frame = Buffer.concat([head, Buffer.from([word & 0xff, (word >> 8) & 0xff, (word >> 16) & 0xff]), text]);
      return { text, file: Buffer.concat([frame, seekTable([{ packed: frame.length, size: text.length }])]) };
    })();
    const olds: [string, Buffer, Buffer][] = [
      ["one frame, no table", zstdCompressSync(content), content],
      ["one frame with a checksum", zstdCompressSync(content, { params: { [constants.ZSTD_c_checksumFlag]: 1 } }), content],
      ["two frames, no table", Buffer.concat([zstdCompressSync(content.subarray(0, half)), zstdCompressSync(content.subarray(half))]), content],
      ["a segment stored as it is", stored.file, stored.text],
    ];
    for (const [what, file, holds] of olds) {
      const source = join(dir, "old.zst");
      const temp = join(dir, "old.zst.writing");
      writeFileSync(source, file);
      assert.deepEqual(await p.ok("segmented", { path: source }), { segmented: segmented(source) }, what);
      assert.deepEqual(await p.ok("segment", { path: join(dir, "old.jsonl"), source, temp }), { segmented: true }, what);
      assert.deepEqual(readFileSync(source), file, `${what}: the source left as it was`);
      assert.ok(segmented(temp), what);
      assert.equal(sha(readByReference(temp)), sha(holds), what);
      const reference = join(dir, "reference.zst");
      writeFileSync(reference, segmentedBytes(holds));
      assert.deepEqual(framesFile(temp)!.map((f) => [f.from, f.size]), framesFile(reference)!.map((f) => [f.from, f.size]), what);
      const out = join(dir, "restored");
      assert.deepEqual(await p.ok("restore", { source, temp: out }), {}, what);
      assert.equal(sha(readFileSync(out)), sha(holds), what);
      rmSync(out);
      rmSync(temp);
    }

    // Damaged: a byte short, a byte changed inside a compressed frame (its table still adding up), not zstd at all.
    const whole = segmentedBytes(content);
    writeFileSync(join(dir, "w.zst"), whole);
    const flipped = Buffer.from(whole);
    const first = framesFile(join(dir, "w.zst"))![0]!;
    flipped[first.at + Math.floor(first.packed / 2)]! ^= 0xff;
    const one = zstdCompressSync(Buffer.from("the only copy of this history\n"), { params: { [constants.ZSTD_c_checksumFlag]: 1 } });
    const damaged: [string, Buffer][] = [
      ["the table's last byte cut", whole.subarray(0, whole.length - 1)],
      ["a byte changed in its first segment", flipped],
      ["a frame's checksum's last byte cut", Buffer.concat([one.subarray(0, one.length - 1), seekTable([{ packed: one.length - 1, size: 30 }])])],
      ["one frame without a table, cut", one.subarray(0, one.length - 1)],
      ["not zstd", Buffer.from("broken transcript\n")],
    ];
    for (const [what, file] of damaged) {
      const source = join(dir, "bad.zst");
      writeFileSync(source, file);
      assert.throws(() => unpackedWhole(source), `${what} (the reference)`);
      await p.fails("check", { path: source });
      await p.fails("restore", { source, temp: join(dir, "bad.restoring") });
      // (one in segments, its table adding up, is not looked into again, as the reference's `segmented` says)
      if (segmented(source)) assert.deepEqual(await p.ok("segment", { path: source, source, temp: join(dir, "bad.writing") }), { segmented: false }, what);
      else await p.fails("segment", { path: source, source, temp: join(dir, "bad.writing") });
      assert.deepEqual(readFileSync(source), file, `${what}: left as it was`);
      // And the next ask is answered as ever.
      assert.deepEqual(await p.ok("segmented", { path: join(dir, "w.zst") }), { segmented: true }, what);
    }
    // A transcript not there is no transcript to put away.
    await p.fails("pack", { path: join(dir, "none.jsonl"), temp: join(dir, "none.writing") });
    await p.fails("check", { path: join(dir, "none.zst") });
    await p.fails("restore", { source: join(dir, "none.zst"), temp: join(dir, "none.restoring") });
  });
});

// ── workspaces (`workspace.pack`, `workspace.unpack`, `workspace.file`) ──

/// Everything under `dir` as a line each: its kind, mode and contents (a file's hash and mtime, a link's target).
function manifest(dir: string, rel = ""): string[] {
  const out: string[] = [];
  for (const name of readdirSync(join(dir, rel)).sort()) {
    const path = join(dir, rel, name);
    const r = rel === "" ? name : `${rel}/${name}`;
    const meta = lstatSync(path);
    if (meta.isSymbolicLink()) out.push(`${r} link ${readlinkSync(path)}`);
    else if (meta.isDirectory()) {
      out.push(`${r} dir ${(meta.mode & 0o7777).toString(8)}`);
      out.push(...manifest(dir, r));
    } else out.push(`${r} file ${(meta.mode & 0o7777).toString(8)} ${meta.size} ${sha(readFileSync(path)).slice(0, 16)} ${Math.floor(meta.mtimeMs / 1000)}`);
  }
  return out;
}

const put = (path: string, bytes: string | Buffer) => {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, bytes);
};
const UPLOAD = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 1, 2, 3, 0xff]);
const DEEP = `${"长路径-".repeat(12)}/${"名字".repeat(30)}.md`;

test("workspaces: packed into the reference's tar, unpacked (whole, only uploads) and a file read as the reference does", { skip: unixOnly }, async () => {
  await withPacked(async (p) => {
    const dir = fresh();
    const ws = join(dir, "workspace");
    put(join(ws, "project/src/main.rs"), "fn main() {}\n");
    put(join(ws, "script.sh"), "#!/bin/sh\ntrue\n");
    chmodSync(join(ws, "script.sh"), 0o751);
    put(join(ws, "uploads/截图 1.png"), UPLOAD);
    put(join(ws, "uploads/notes.txt"), "a note\n");
    put(join(ws, DEEP), "deep and long");
    put(join(ws, "empty"), "");
    mkdirSync(join(ws, "an/empty/dir"), { recursive: true });
    mkdirSync(join(ws, "uploads/empty-upload-dir"), { recursive: true });
    put(join(ws, "random.bin"), Buffer.from(Array.from({ length: 1 << 20 }, (_, i) => (i * 2654435761) >>> 24)));
    symlinkSync("project/src/main.rs", join(ws, "relative-link"));
    symlinkSync(`${"远处/".repeat(30)}target`, join(ws, "long-link"));
    symlinkSync("/nonexistent/absolute", join(ws, "dangling"));
    const before = manifest(ws);

    const theirs = join(dir, "reference.tar.zst");
    await packTree(ws, theirs);
    const mine = join(dir, "workspace.tar.zst");
    assert.deepEqual(await p.ok("workspace.pack", { dir: ws, out: mine }), {});
    assert.deepEqual(manifest(ws), before, "the workspace is left as it was (the station removes it)");
    assert.deepEqual(zstdDecompressSync(readFileSync(mine)), zstdDecompressSync(readFileSync(theirs)), "the same tar, byte for byte");
    // Packed twice, the same tar again.
    const twice = join(dir, "twice.tar.zst");
    assert.deepEqual(await p.ok("workspace.pack", { dir: ws, out: twice }), {});
    assert.deepEqual(zstdDecompressSync(readFileSync(twice)), zstdDecompressSync(readFileSync(mine)));

    // Each archive unpacked whole by the program, and by the reference: the tree as it was, no link refused.
    for (const archive of [mine, theirs]) {
      const out = fresh("packed-unpack-");
      assert.deepEqual(await p.ok("workspace.unpack", { path: archive, dest: out }), { refused: [] });
      assert.deepEqual(manifest(out), before, archive);
      const byReference = fresh("packed-unpack-ref-");
      assert.deepEqual(await unpackArchive(archive, byReference), new Map());
      assert.deepEqual(manifest(out), manifest(byReference), archive);
      // Only its uploads (a `prefix` of null as none given).
      const uploads = fresh("packed-uploads-");
      assert.deepEqual(await p.ok("workspace.unpack", { path: archive, dest: uploads, prefix: "uploads" }), { refused: [] });
      const uploadsRef = fresh("packed-uploads-ref-");
      await unpackArchive(archive, uploadsRef, "uploads");
      assert.deepEqual(manifest(uploads), manifest(uploadsRef), archive);
      assert.deepEqual(readdirSync(uploads), ["uploads"]);
      const nullPrefix = fresh("packed-null-prefix-");
      assert.deepEqual(await p.ok("workspace.unpack", { path: archive, dest: nullPrefix, prefix: null }), { refused: [] });
      assert.deepEqual(manifest(nullPrefix), before, archive);
    }

    // A file by its path's components, as the reference finds it; none for a directory, a link or what is not there.
    for (const wanted of [["uploads", "截图 1.png"], ["uploads", "notes.txt"], DEEP.split("/"), ["empty"], ["random.bin"], ["uploads"], ["an", "empty"], ["relative-link"], ["missing"], ["uploads", "missing"], []]) {
      const out = join(dir, "file.out");
      rmSync(out, { force: true });
      const want = await fileOf(mine, wanted);
      assert.deepEqual(await p.ok("workspace.file", { path: mine, wanted, out }), { found: want !== null }, JSON.stringify(wanted));
      if (want !== null) assert.deepEqual(readFileSync(out), want, JSON.stringify(wanted));
    }
  });
});

test("workspaces: an archive cut short, with bytes after it, not zstd, or leading out of its destination is refused as by the reference", { skip: unixOnly }, async () => {
  await withPacked(async (p) => {
    const dir = fresh();
    const ws = join(dir, "workspace");
    put(join(ws, "uploads/a.txt"), "attachment");
    put(join(ws, "source.rs"), "work");
    const archive = join(dir, "good.tar.zst");
    assert.deepEqual(await p.ok("workspace.pack", { dir: ws, out: archive }), {});
    const whole = readFileSync(archive);
    for (const [what, bytes] of [
      ["its checksum's last byte cut", whole.subarray(0, whole.length - 1)],
      ["half of it", whole.subarray(0, whole.length >> 1)],
      ["a frame header only", whole.subarray(0, 6)],
      ["bytes after it", Buffer.concat([whole, Buffer.from("xx")])],
      ["not zstd", Buffer.from("broken archive")],
    ] as const) {
      const bad = join(dir, "bad.tar.zst");
      writeFileSync(bad, bytes);
      await assert.rejects(fileOf(bad, ["uploads", "a.txt"]), `${what} (the reference)`);
      await p.fails("workspace.file", { path: bad, wanted: ["uploads", "a.txt"], out: join(dir, "bad.out") });
      await p.fails("workspace.unpack", { path: bad, dest: fresh("packed-bad-") });
      await p.fails("workspace.unpack", { path: bad, dest: fresh("packed-bad-"), prefix: "uploads" });
      assert.deepEqual(readFileSync(bad), bytes, `${what}: the archive kept`);
      // And the next ask is answered as ever.
      assert.deepEqual(await p.ok("workspace.file", { path: archive, wanted: ["source.rs"], out: join(dir, "good.out") }), { found: true }, what);
      assert.equal(readFileSync(join(dir, "good.out"), "utf8"), "work");
    }
    await p.fails("workspace.unpack", { path: join(dir, "none.tar.zst"), dest: fresh("packed-none-") });
    await p.fails("workspace.file", { path: join(dir, "none.tar.zst"), wanted: ["a"], out: join(dir, "none.out") });

    // Leading out: `..` passed over, a link made first then written through, a hard link up, a device.
    const outside = fresh("packed-outside-");
    const meta = (size: number) => ({ mode: 0o100644, uid: 0, gid: 0, mtime: 1_600_000_000, size });
    const entry = (name: string, kind: string, bytes = Buffer.alloc(0), link?: string) => [
      gnuHeader(Buffer.from(name), kind, meta(bytes.length), link === undefined ? undefined : Buffer.from(link)),
      bytes,
      padding(bytes.length),
    ];
    const cases: [string, Buffer[], boolean][] = [
      ["`..` passed over", [...entry("../escaped", "0", Buffer.from("no")), ...entry("a/../../escaped2", "0", Buffer.from("no")), ...entry("ok", "0", Buffer.from("yes"))], false],
      ["through a link out", [...entry("out", "2", Buffer.alloc(0), outside), ...entry("out/escaped", "0", Buffer.from("no"))], true],
      ["a hard link up", entry("h", "1", Buffer.alloc(0), "../escaped"), true],
      ["a device", entry("tty", "3"), true],
    ];
    for (const [what, blocks, refused] of cases) {
      const room = fresh("packed-escape-");
      const bad = join(room, "escape.tar.zst");
      await tarOfHeaders(bad, blocks);
      const dest = join(room, "dest");
      const reference = join(room, "by-reference");
      mkdirSync(dest);
      mkdirSync(reference);
      if (refused) {
        await assert.rejects(unpackArchive(bad, reference), `${what} (the reference)`);
        await p.fails("workspace.unpack", { path: bad, dest });
      } else {
        await unpackArchive(bad, reference);
        assert.deepEqual(await p.ok("workspace.unpack", { path: bad, dest }), { refused: [] }, what);
        assert.deepEqual(manifest(dest), manifest(reference), what);
      }
      for (const name of ["escaped", "escaped2"]) {
        assert.equal(existsSync(join(room, name)), false, `${what}: nothing written outside`);
        assert.equal(existsSync(join(outside, name)), false, `${what}: nothing written through the link`);
      }
      assert.deepEqual(readdirSync(outside), [], what);
    }
  });
});

test("malformed lines, unknown ops and missing fields are answered `{id, error}` and the process goes on", { skip }, async () => {
  await withPacked(async (p) => {
    const tableOk = async () => assert.deepEqual(await p.ok("table", { frames: [[3, 4]] }), { table: seekTable([{ packed: 3, size: 4 }]).toString("hex") });
    // Lines that are no JSON object: id null.
    for (const line of ["{not valid json", "[1,2,3]", "42", "\"op\"", "null", "{\"op\": \"table\"", "\u0000"]) {
      assert.deepEqual(await p.raw(line), { id: null, error: "no such ask" }, JSON.stringify(line));
      await tableOk();
    }
    // An empty line is passed over: the next answer is the next ask's.
    p.silent("");
    await tableOk();
    // No op, an op not a string, an op unknown: the id kept.
    assert.deepEqual(await p.raw(JSON.stringify({ id: 7 })), { id: 7, error: "no such ask" });
    assert.deepEqual(await p.raw(JSON.stringify({ op: "table" })), { id: null, table: seekTable([]).toString("hex") });
    assert.equal(await p.fails("nope"), "no such ask");
    assert.equal(await p.fails(""), "no such ask");
    assert.deepEqual(await p.raw(JSON.stringify({ id: "x", op: 5 })), { id: "x", error: "no such ask" });
    assert.deepEqual(await p.raw(JSON.stringify({ id: "y", op: ["pack"] })), { id: "y", error: "no such ask" });
    await tableOk();
    // Each op missing what it needs (or given it as no string), said by name; `a` a transcript put away, so that what
    // is read of a source before its temporary is asked for reads.
    const dir = fresh();
    writeFileSync(join(dir, "a"), segmentedBytes(Buffer.from("a line\n")));
    const missing: [string, Record<string, unknown>, string][] = [
      ["pack", {}, "no path"],
      ["pack", { path: join(dir, "a") }, "no temp"],
      ["pack", { path: 5, temp: join(dir, "t") }, "no path"],
      ["check", {}, "no path"],
      ["segment", {}, "no source"],
      ["restore", {}, "no source"],
      ["restore", { source: join(dir, "a") }, "no temp"],
      ["segmented", {}, "no path"],
      ["frames", {}, "no path"],
      ["frames", { path: null }, "no path"],
      ["table", { frames: [[1]] }, "bad frame"],
      ["table", { frames: [["1", 2]] }, "bad frame"],
      ["table", { frames: [5] }, "bad frame"],
      ["workspace.pack", {}, "no dir"],
      ["workspace.pack", { dir }, "no out"],
      ["workspace.unpack", {}, "no path"],
      ["workspace.unpack", { path: join(dir, "a") }, "no dest"],
      ["workspace.unpack", { path: join(dir, "a"), dest: dir, prefix: 5 }, "no prefix"],
      ["workspace.unpack", { path: join(dir, "a"), dest: dir, prefix: ["uploads"] }, "no prefix"],
      ["workspace.file", { path: join(dir, "a"), out: join(dir, "o") }, "no wanted"],
      ["workspace.file", { path: join(dir, "a"), wanted: ["a", 1], out: join(dir, "o") }, "no wanted"],
      ["workspace.file", { path: join(dir, "a"), wanted: "a", out: join(dir, "o") }, "no wanted"],
      ["workspace.file", { wanted: ["a"], out: join(dir, "o") }, "no path"],
      ["workspace.file", { path: join(dir, "a"), wanted: ["a"] }, "no out"],
    ];
    for (const [op, args, error] of missing) {
      assert.equal(await p.fails(op, args), error, `${op} ${JSON.stringify(args)}`);
      await tableOk();
    }
    // Nothing was made by any of them.
    assert.deepEqual(readdirSync(dir), ["a"]);
  });
});

test("stdin closed with nothing asked: exit 0, nothing said", { skip }, async () => {
  const child = spawn(candidate(), ["--builder", "packed", "--shell-dir", fresh("packed-shell-")], { stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
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
