// Black-box contract tests for `--builder packed` against any reader binary, spoken to over its stdio alone.
//
// By default this runs against the shipped MoonBit `stillfail-reader` (`mbReaderBinary()`). Set
// `STILLFAIL_READER_CANDIDATE=/path/to/stillfail-pion` to verify a candidate binary with zero edits to this suite: a
// candidate named but empty, missing or not executable fails every test, never skips. With no candidate named and no
// reader built, the tests skip saying so, except under CI (`CI` set), where they fail.
//
// The protocol (station/mb/src/packed/answer.mbt, station/src/sessions/packed-mb.ts): a line of JSON an ask `{id, op, …}`,
// answered by one line `{id, …}` or `{id, error}`, in order, nothing kept between asks; an empty line is passed over; a
// line that is no JSON object is answered `{id: null, error}`. The station sends asks back to back without waiting
// (`PackedProgram.ask`), so asks are pipelined here too, written in one write and split across writes. Each test keeps
// one process and its stdin open across all its asks, and ends it only by closing stdin: it must exit 0 having said
// nothing more (a line said after the last answer fails the test however fast the process exits). What it makes is held
// to the TypeScript it replaced (test/reference/packed.ts, test/reference/workspace-archive.ts). Error words are the
// program's own (no caller reads them): only that an ask failed, and that the process goes on, is held.
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import {
  accessSync,
  chmodSync,
  closeSync,
  constants as fsConstants,
  existsSync,
  linkSync,
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
import { dirname, join, relative, resolve, sep } from "node:path";
import { after, test } from "node:test";
import { constants, zstdCompressSync, zstdDecompressSync } from "node:zlib";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { framesOf, readSegments, SEGMENT, seekTable, segmented, segmentedBytes, unpackedWhole } from "./reference/packed.ts";
import { fileOf, gnuHeader, packTree, padding, tarOfHeaders, unpackArchive } from "./reference/workspace-archive.ts";

/// The longest any one ask (or the exit after stdin's end) may take before the process is killed and the test fails: a
/// bound, never a wait.
const ASK_TIMEOUT_MS = 60_000;
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
  for (const d of dirs) {
    if (!existsSync(d)) continue;
    const writable = (p: string) => {
      try {
        const meta = lstatSync(p);
        if (meta.isDirectory()) {
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

type Waiter = { resolve: (j: Json) => void; reject: (e: Error) => void; timer: NodeJS.Timeout };

/// One `--builder packed` process, its stdin kept open: each ask answered by the next line it says, in order. What the
/// protocol forbids (a line no ask waits for, a line that is no JSON, the process ending before its stdin did, an ask
/// unanswered in time) is kept as its `protocolError`, which fails every ask after it and `end()`, whatever else.
class PackedProcess {
  readonly #child: ChildProcess;
  readonly #waiting: Waiter[] = [];
  #carry: Buffer = Buffer.alloc(0);
  #stderr = "";
  #protocolError: Error | null = null;
  #ending = false;
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
async function withPacked(f: (p: PackedProcess) => Promise<void>): Promise<void> {
  const p = new PackedProcess();
  let failed = true;
  try {
    await f(p);
    failed = false;
  } finally {
    if (failed) await p.kill();
  }
  await p.end();
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

const tableHex = (frames: { packed: number; size: number }[]) => seekTable(frames).toString("hex");

test("one process answers many asks in order, each with its own id, nothing kept from one to the next", { skip }, async () => {
  await withPacked(async (p) => {
    const lists: { packed: number; size: number }[][] = [[], [{ packed: 9, size: 0 }], [{ packed: 0xffffffff, size: 0 }, { packed: 1, size: 0xfffffffe }]];
    for (let i = 1; i < 30; i++) lists.push(Array.from({ length: i % 7 }, (_, k) => ({ packed: (i * 7919 + k * 104729) % 2 ** 32, size: (i * k * 15485863) % 2 ** 32 })));
    for (const frames of lists) {
      assert.deepEqual(await p.ok("table", { frames: frames.map((f) => [f.packed, f.size]) }), { table: tableHex(frames) });
    }
    // No frames given: the empty table.
    assert.deepEqual(await p.ok("table"), { table: tableHex([]) });
    // Any JSON id comes back as it was sent.
    for (const id of ["a-string", 0, -1, 2 ** 40, 1.5, true, null, [1, "x"], { nested: { deep: [1] } }, "中文😀"]) {
      assert.deepEqual(await p.raw(JSON.stringify({ id, op: "table", frames: [] })), { id, table: tableHex([]) });
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
    assert.deepEqual(await p.ok("table", { frames: [[1, 2]] }), { table: tableHex([{ packed: 1, size: 2 }]) });
  });
});

test("pipelined asks: sent back to back, several in one write, one split across writes (inside a character), lines past 1 MiB", { skip }, async () => {
  await withPacked(async (p) => {
    const dir = fresh();
    const named = join(dir, "中文 😀 é.zst");
    writeFileSync(named, segmentedBytes(Buffer.from("一行\n")));
    const plain = join(dir, "plain.zst");
    writeFileSync(plain, zstdCompressSync(Buffer.from("no table\n")));

    // Sent as the station sends them, none waiting for the one before: each answered by its own id, in order.
    const asks = Array.from({ length: 40 }, (_, i) =>
      i % 3 === 0 ? p.ok("table", { frames: [[i, i + 1]] }).then((a) => assert.deepEqual(a, { table: tableHex([{ packed: i, size: i + 1 }]) }))
      : i % 3 === 1 ? p.ok("segmented", { path: i % 2 ? named : plain }).then((a) => assert.deepEqual(a, { segmented: i % 2 === 1 }))
      : p.ok("frames", { path: named }).then((a) => assert.deepEqual(a, { frames: framesFile(named)!.map((f) => [f.at, f.packed, f.from, f.size]) })));
    await Promise.all(asks);

    // Several lines in one write, an empty one and one that is no JSON among them: every line answered (the empty one
    // passed over), none left in the buffer.
    const ids = [p.id(), p.id(), p.id()];
    const answers = [p.expect(), p.expect(), p.expect(), p.expect()];
    await p.write([
      JSON.stringify({ id: ids[0], op: "table", frames: [[7, 8]] }),
      "",
      "{not json",
      JSON.stringify({ id: ids[1], op: "segmented", path: named }),
      JSON.stringify({ id: ids[2], op: "table" }),
      "",
    ].join("\n"));
    const [a, bad, b, c] = await Promise.all(answers);
    assert.deepEqual(a, { id: ids[0], table: tableHex([{ packed: 7, size: 8 }]) });
    assert.equal(bad.id, null);
    assert.ok(typeof bad.error === "string" && bad.error.length > 0);
    assert.deepEqual(b, { id: ids[1], segmented: true });
    assert.deepEqual(c, { id: ids[2], table: tableHex([]) });

    // One ask written a few bytes at a time, cut inside its path's multi-byte characters: answered once, whole.
    const id = p.id();
    const line = Buffer.from(`${JSON.stringify({ id, op: "segmented", path: named })}\n`);
    const answer = p.expect();
    for (let at = 0; at < line.length; at += 3) await p.write(line.subarray(at, Math.min(line.length, at + 3)));
    assert.deepEqual(await answer, { id, segmented: true });

    // A line past 1 MiB each way: 100 000 frames asked, their table (1.6 MB of hex) answered byte for byte.
    const many = Array.from({ length: 100_000 }, (_, i) => ({ packed: (i * 2654435761) % 2 ** 32, size: (i * 40503) % 2 ** 32 }));
    const ask = JSON.stringify({ frames: many.map((f) => [f.packed, f.size]) });
    assert.ok(ask.length > 1 << 20, `the ask is ${ask.length} bytes`);
    const big = await p.ok("table", { frames: many.map((f) => [f.packed, f.size]) });
    assert.ok(big.table.length > 1 << 20);
    assert.equal(big.table, tableHex(many));
    // And the next small ask after it.
    assert.deepEqual(await p.ok("table", { frames: [[1, 1]] }), { table: tableHex([{ packed: 1, size: 1 }]) });
  });
});

test("transcripts: put away in the reference's segments, checked, written back byte for byte", { skip }, async () => {
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

/// Everything under `dir` as a line each: its kind, mode and contents (a file's hash and mtime, its hard links' count
/// where `links`, a link's target).
function manifest(dir: string, links = true, rel = ""): string[] {
  const out: string[] = [];
  for (const name of readdirSync(join(dir, rel)).sort()) {
    const path = join(dir, rel, name);
    const r = rel === "" ? name : `${rel}/${name}`;
    const meta = lstatSync(path);
    if (meta.isSymbolicLink()) out.push(`${r} link ${readlinkSync(path)}`);
    else if (meta.isDirectory()) {
      out.push(`${r} dir ${unix ? (meta.mode & 0o7777).toString(8) : ""}`);
      out.push(...manifest(dir, links, r));
    } else out.push(`${r} file ${unix ? (meta.mode & 0o7777).toString(8) : ""} ${meta.size} ${sha(readFileSync(path)).slice(0, 16)} ${Math.floor(meta.mtimeMs / 1000)}${links ? ` ${meta.nlink}` : ""}`);
  }
  return out;
}

const put = (path: string, bytes: string | Buffer) => {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, bytes);
};
const UPLOAD = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 1, 2, 3, 0xff]);
const DEEP = `${"长路径-".repeat(12)}/${"名字".repeat(30)}.md`;

test("workspaces: packed into the reference's tar, unpacked (whole, only uploads) and a file read as the reference does", { skip }, async () => {
  await withPacked(async (p) => {
    const dir = fresh();
    const ws = join(dir, "workspace");
    put(join(ws, "project/src/main.rs"), "fn main() {}\n");
    put(join(ws, "script.sh"), "#!/bin/sh\ntrue\n");
    if (unix) chmodSync(join(ws, "script.sh"), 0o751);
    put(join(ws, "uploads/截图 1.png"), UPLOAD);
    put(join(ws, "uploads/notes.txt"), "a note\n");
    put(join(ws, DEEP), "deep and long");
    put(join(ws, "empty"), "");
    mkdirSync(join(ws, "an/empty/dir"), { recursive: true });
    mkdirSync(join(ws, "uploads/empty-upload-dir"), { recursive: true });
    put(join(ws, "random.bin"), Buffer.from(Array.from({ length: 1 << 20 }, (_, i) => (i * 2654435761) >>> 24)));
    // A hard link inside the workspace: packed (by the shell and the reference alike) as two files of the same bytes.
    put(join(ws, "a"), "hard linked");
    linkSync(join(ws, "a"), join(ws, "b"));
    if (unix) {
      symlinkSync("project/src/main.rs", join(ws, "relative-link"));
      symlinkSync(`${"远处/".repeat(30)}target`, join(ws, "long-link"));
      symlinkSync("/nonexistent/absolute", join(ws, "dangling"));
      // (a link among the uploads, which unpacking only the uploads leaves out, as the reference does)
      symlinkSync("notes.txt", join(ws, "uploads/link-to-notes"));
    }
    const before = manifest(ws);
    const beforeFiles = manifest(ws, false);

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
      assert.deepEqual(manifest(out, false), beforeFiles, archive);
      assert.deepEqual(readFileSync(join(out, "b")), readFileSync(join(out, "a")), archive);
      const byReference = fresh("packed-unpack-ref-");
      assert.deepEqual(await unpackArchive(archive, byReference), new Map());
      assert.deepEqual(manifest(out), manifest(byReference), archive);
      // Only its uploads' files and directories (a `prefix` of null as none given).
      const uploads = fresh("packed-uploads-");
      assert.deepEqual(await p.ok("workspace.unpack", { path: archive, dest: uploads, prefix: "uploads" }), { refused: [] });
      const uploadsRef = fresh("packed-uploads-ref-");
      await unpackArchive(archive, uploadsRef, "uploads");
      assert.deepEqual(manifest(uploads), manifest(uploadsRef), archive);
      assert.deepEqual(readdirSync(uploads), ["uploads"]);
      assert.equal(existsSync(join(uploads, "uploads/link-to-notes")), false, `${archive}: no link among only the uploads`);
      const nullPrefix = fresh("packed-null-prefix-");
      assert.deepEqual(await p.ok("workspace.unpack", { path: archive, dest: nullPrefix, prefix: null }), { refused: [] });
      assert.deepEqual(manifest(nullPrefix), manifest(out), archive);
    }

    // A file by its path's components, as the reference finds it; none for a directory, a link or what is not there.
    for (const wanted of [["uploads", "截图 1.png"], ["uploads", "notes.txt"], DEEP.split("/"), ["empty"], ["random.bin"], ["a"], ["b"], ["uploads"], ["an", "empty"], ["relative-link"], ["missing"], ["uploads", "missing"], []]) {
      const out = join(dir, "file.out");
      rmSync(out, { force: true });
      const want = await fileOf(mine, wanted);
      assert.deepEqual(await p.ok("workspace.file", { path: mine, wanted, out }), { found: want !== null }, JSON.stringify(wanted));
      if (want !== null) assert.deepEqual(readFileSync(out), want, JSON.stringify(wanted));
    }
  });
});

test("workspaces: an archive cut short, with bytes after it or not zstd is refused, as by the reference", { skip }, async () => {
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
  });
});

test("workspaces: an archive leading out of its destination writes nothing outside it, refused or passed over as by the reference", { skip }, async () => {
  await withPacked(async (p) => {
    const outside = fresh("packed-outside-");
    // A real file outside, which no hard link may reach (its link count and bytes stay).
    const secret = join(outside, "secret");
    writeFileSync(secret, "outside");
    const meta = (size: number) => ({ mode: 0o100644, uid: 0, gid: 0, mtime: 1_600_000_000, size });
    const entry = (name: string, kind: string, bytes = Buffer.alloc(0), link?: string) => [
      gnuHeader(Buffer.from(name), kind, meta(bytes.length), link === undefined ? undefined : Buffer.from(link)),
      bytes,
      padding(bytes.length),
    ];
    const cases: [string, (room: string) => Buffer[], boolean][] = [
      ["`..` components passed over", () => [...entry("../escaped", "0", Buffer.from("no")), ...entry("a/../../escaped2", "0", Buffer.from("no")), ...entry("ok", "0", Buffer.from("yes"))], true],
      // (a name rooted at `/` with no drive, on every machine; the outside directory's own absolute name only where it
      // starts with `/`, not Windows' drive)
      ["an absolute name, made inside", () => [...entry("/rooted-contract/x", "0", Buffer.from("in")), ...(unix ? entry(`${outside}/abs-escaped`, "0", Buffer.from("no")) : [])], true],
      ["a hard link up to a file that is there", (room) => entry("h", "1", Buffer.alloc(0), relative(join(room, "dest"), secret).split(sep).join("/")), true],
      ["a hard link by an absolute path to a file that is there", () => entry("h", "1", Buffer.alloc(0), secret), true],
      ["a hard link inside", () => [...entry("first", "0", Buffer.from("same")), ...entry("second", "1", Buffer.alloc(0), "first")], true],
      ["a device", () => entry("tty", "3"), true],
      ["through an absolute link out", () => [...entry("out", "2", Buffer.alloc(0), outside), ...entry("out/escaped", "0", Buffer.from("no"))], unix],
      ["through a relative link up", () => [...entry("up", "2", Buffer.alloc(0), ".."), ...entry("up/escaped", "0", Buffer.from("no"))], unix],
      ["through a relative link two up", () => [...entry("d/", "5"), ...entry("d/up", "2", Buffer.alloc(0), "../.."), ...entry("d/up/escaped", "0", Buffer.from("no"))], unix],
    ];
    for (const [what, blocks, runs] of cases) {
      if (!runs) continue;
      const room = fresh("packed-escape-");
      const bad = join(room, "escape.tar.zst");
      await tarOfHeaders(bad, blocks(room));
      const dest = join(room, "dest");
      const reference = join(room, "by-reference");
      mkdirSync(dest);
      mkdirSync(reference);
      // Whatever the reference does, the program does: refuses, or makes the same tree.
      const refused = await unpackArchive(bad, reference).then(() => false, () => true);
      if (refused) await p.fails("workspace.unpack", { path: bad, dest });
      else {
        assert.deepEqual(await p.ok("workspace.unpack", { path: bad, dest }), { refused: [] }, what);
        assert.deepEqual(manifest(dest), manifest(reference), what);
      }
      for (const name of ["escaped", "escaped2"]) {
        assert.equal(existsSync(join(room, name)), false, `${what}: nothing written beside the destination`);
        assert.equal(existsSync(join(dirname(room), name)), false, `${what}: nothing written above it`);
      }
      assert.deepEqual(readdirSync(outside), ["secret"], `${what}: nothing written outside`);
      assert.equal(statSync(secret).nlink, 1, `${what}: no hard link to the file outside`);
      assert.equal(readFileSync(secret, "utf8"), "outside", what);
      if (what === "an absolute name, made inside") {
        assert.equal(refused, false);
        assert.equal(readFileSync(join(dest, "rooted-contract/x"), "utf8"), "in");
        if (unix) assert.equal(readFileSync(join(dest, ...outside.split("/").filter((s) => s !== ""), "abs-escaped"), "utf8"), "no");
      }
      if (what === "a hard link inside") assert.equal(statSync(join(dest, "first")).ino, statSync(join(dest, "second")).ino);
      if (what === "`..` components passed over") assert.equal(refused, false);
      if (what === "a device" || what.startsWith("through")) assert.equal(refused, true, what);
    }
  });
});

test("malformed lines, unknown ops and missing fields are answered `{id, error}` and the process goes on", { skip }, async () => {
  await withPacked(async (p) => {
    const alive = async () => assert.deepEqual(await p.ok("table", { frames: [[3, 4]] }), { table: tableHex([{ packed: 3, size: 4 }]) });
    const failed = (answer: Json, id: unknown, what: string) => {
      assert.deepEqual(Object.keys(answer).sort(), ["error", "id"], what);
      assert.deepEqual(answer.id, id, what);
      assert.ok(typeof answer.error === "string" && answer.error.length > 0, what);
    };
    // Lines that are no JSON object: id null.
    for (const line of ["{not valid json", "[1,2,3]", "42", "\"op\"", "null", "{\"op\": \"table\"", "\u0000"]) {
      failed(await p.raw(line), null, JSON.stringify(line));
      await alive();
    }
    // An empty line is passed over: the next answer is the next ask's.
    await p.write("\n");
    await alive();
    // No op, an op not a string, an op unknown: the id kept.
    failed(await p.raw(JSON.stringify({ id: 7 })), 7, "no op");
    failed(await p.raw(JSON.stringify({ id: "x", op: 5 })), "x", "an op not a string");
    failed(await p.raw(JSON.stringify({ id: "y", op: ["pack"] })), "y", "an op not a string");
    await p.fails("nope");
    await p.fails("");
    // No id: answered with a null one.
    assert.deepEqual(await p.raw(JSON.stringify({ op: "table" })), { id: null, table: tableHex([]) });
    await alive();

    // Each ask with everything it needs but one field (or that one given as no string): refused, nothing written.
    const dir = fresh();
    const transcript = join(dir, "t.jsonl");
    writeFileSync(transcript, "a line\n");
    const putAway = join(dir, "put-away.zst");
    writeFileSync(putAway, segmentedBytes(Buffer.from("a line\n")));
    const old = join(dir, "old.zst");
    writeFileSync(old, zstdCompressSync(Buffer.from("a line\n")));
    const ws = join(dir, "ws");
    put(join(ws, "f"), "f");
    const archive = join(dir, "ws.tar.zst");
    assert.deepEqual(await p.ok("workspace.pack", { dir: ws, out: archive }), {});
    const dest = join(dir, "dest");
    mkdirSync(dest);
    const listing = () => readdirSync(dir).sort();
    const before = listing();
    const missing: [string, Record<string, unknown>][] = [
      ["pack", { temp: join(dir, "t.writing") }],
      ["pack", { path: transcript }],
      ["pack", { path: 5, temp: join(dir, "t.writing") }],
      ["check", {}],
      ["segment", { path: old, temp: join(dir, "s.writing") }],
      ["segment", { path: old, source: old }],
      ["restore", { temp: join(dir, "r.restoring") }],
      ["restore", { source: putAway }],
      ["segmented", {}],
      ["frames", {}],
      ["frames", { path: null }],
      ["table", { frames: [[1]] }],
      ["table", { frames: [["1", 2]] }],
      ["table", { frames: [5] }],
      ["workspace.pack", { out: join(dir, "p.tar.zst") }],
      ["workspace.pack", { dir: ws }],
      ["workspace.unpack", { dest }],
      ["workspace.unpack", { path: archive }],
      ["workspace.unpack", { path: archive, dest, prefix: 5 }],
      ["workspace.unpack", { path: archive, dest, prefix: ["uploads"] }],
      ["workspace.file", { wanted: ["f"], out: join(dir, "o") }],
      ["workspace.file", { path: archive, out: join(dir, "o") }],
      ["workspace.file", { path: archive, wanted: ["f"] }],
      ["workspace.file", { path: archive, wanted: ["f", 1], out: join(dir, "o") }],
      ["workspace.file", { path: archive, wanted: "f", out: join(dir, "o") }],
    ];
    for (const [op, args] of missing) {
      await p.fails(op, args);
      await alive();
    }
    assert.deepEqual(listing(), before, "nothing written by a refused ask");
    assert.deepEqual(readdirSync(dest), []);
  });
});

test("stdin closed with nothing asked: exit 0, nothing said", { skip }, async () => {
  await withPacked(async () => {});
});

test("protocol edge parity: CRLF framing, lone UTF-16 surrogates, lossy UTF-8 raw bytes, and >16 MiB lines", { skip }, async () => {
  // 1. Raw stdio byte-level check: `\r\n` is not skipped as empty, lone surrogates never invoke shell
  //    (neither raw nor U+FFFD-replaced paths created), valid surrogate pairs succeed, and raw invalid
  //    UTF-8 byte 0xff in `id` is decoded lossily to valid UTF-8 U+FFFD (`ef bf bd`) on stdout.
  const dir = fresh("packed-edge-");
  const transcript = join(dir, "t.jsonl");
  writeFileSync(transcript, "line\n");
  const surrogatePrefix = join(dir, "surrogate-out");
  const escapedPrefix = surrogatePrefix.replaceAll("\\", "\\\\");

  const stdinPayload = Buffer.concat([
    Buffer.from("\r\n"),
    Buffer.from("\n"),
    Buffer.from(`{"id":1,"op":"pack","path":${JSON.stringify(transcript)},"temp":"${escapedPrefix}\\ud800"}\n`),
    Buffer.from(`{"id":2,"op":"pack","path":${JSON.stringify(transcript)},"temp":"${escapedPrefix}\\udc00"}\n`),
    Buffer.from(`{"id":3,"op":"pack","path":${JSON.stringify(transcript)},"temp":"${escapedPrefix}\\ud800\\u0041"}\n`),
    Buffer.from(`{"id":"\\ud83d\\ude00","op":"table","frames":[[5,6]]}\n`),
    Buffer.concat([Buffer.from('{"id":"bad-'), Buffer.from([0xff]), Buffer.from('","op":"table","frames":[]}\n')]),
  ]);

  const rawResult = await new Promise<{ code: number | null; stdout: Buffer; stderr: string }>((resolvePromise, rejectPromise) => {
    const child = spawn(candidate(), ["--builder", "packed", "--shell-dir", fresh("packed-edge-shell-")], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    const outChunks: Buffer[] = [];
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      rejectPromise(new Error(`raw edge parity timed out after ${ASK_TIMEOUT_MS} ms; stderr: ${stderr}`));
    }, ASK_TIMEOUT_MS);
    child.stdout!.on("data", (c: Buffer) => outChunks.push(c));
    child.stderr!.on("data", (c: Buffer) => { stderr += c.toString("utf8"); });
    child.on("error", (e) => { clearTimeout(timer); rejectPromise(e); });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolvePromise({ code, stdout: Buffer.concat(outChunks), stderr });
    });
    child.stdin!.end(stdinPayload);
  });

  assert.equal(rawResult.code, 0, `edge parity process exited ${rawResult.code}; stderr: ${rawResult.stderr}`);
  assert.equal(rawResult.stdout.includes(0xff), false, "stdout raw bytes must never contain raw 0xff");
  assert.ok(rawResult.stdout.includes(Buffer.from([0xef, 0xbf, 0xbd])), "stdout raw bytes must contain valid UTF-8 U+FFFD (ef bf bd)");

  const outLines = rawResult.stdout.toString("utf8").replace(/\n$/, "").split("\n");
  assert.equal(outLines.length, 6, `expected 6 answers (CRLF + 3 lone surrogates + 1 valid pair + 1 lossy utf8), got ${outLines.length}`);
  for (let i = 0; i < 4; i++) {
    const ans = JSON.parse(outLines[i]!);
    assert.deepEqual(Object.keys(ans).sort(), ["error", "id"], `line ${i}`);
    assert.equal(ans.id, null, `line ${i} id`);
    assert.ok(typeof ans.error === "string" && ans.error.length > 0, `line ${i} error`);
  }
  assert.deepEqual(JSON.parse(outLines[4]!), {
    id: "😀",
    table: tableHex([{ packed: 5, size: 6 }]),
  });
  assert.deepEqual(JSON.parse(outLines[5]!), {
    id: "bad-\uFFFD",
    table: tableHex([]),
  });
  assert.equal(existsSync(`${surrogatePrefix}\uFFFD`), false, "U+FFFD-replaced lone surrogate path must not be created");
  assert.equal(existsSync(`${surrogatePrefix}\uFFFDA`), false, "U+FFFD-replaced high+non-low path must not be created");
  assert.deepEqual(readdirSync(dir), ["t.jsonl"], "no files written by rejected lone surrogate asks");

  // 2. Valid request line >16 MiB (past host_shim's 16 MiB LineReader cap) must succeed without truncation or hang.
  await withPacked(async (p) => {
    const pad = "x".repeat(16 * 1024 * 1024 + 64);
    const big = await p.ok("table", { frames: [[1, 2]], pad });
    assert.deepEqual(big, { table: tableHex([{ packed: 1, size: 2 }]) });
  });
});
