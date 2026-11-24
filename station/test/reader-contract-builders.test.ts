// Black-box contract tests for SQLite builders (`--builder archive-marks --db <file>`) against
// any reader binary, spoken to over its stdio alone.
//
// By default this runs against the shipped MoonBit `stillfail-reader` (`mbReaderBinary()`). Set
// `STILLFAIL_READER_CANDIDATE=/path/to/stillfail-pion` to verify a candidate binary with zero edits
// to this suite: a candidate named but empty, missing or not executable fails every test, never skips.
// Set `STILLFAIL_REQUIRE_DUAL_READER=1` (used in CI `verify-linux`) to require BOTH a real MoonBit
// `stillfail-reader` and a distinct candidate binary, failing loudly if either is missing or identical.
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import {
  accessSync,
  constants as fsConstants,
  copyFileSync,
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";
import { archiveMarksReady, archiveMarksStep, installArchiveMarkIndex } from "./reference/backfill/archive-mark-index.ts";

const ASK_TIMEOUT_MS = 30_000;

// Sole known wire difference between MoonBit `fail(...)` and Pion `StepError::App(...)`:
// MoonBit's `Failure::to_string()` prepends its compiler source location prefix
// (`src/marks/marks.mbt:46:12-46:101@station FAILED: `). Strip ONLY that exact prefix before
// strict `assert.deepStrictEqual` on the full response object.
const MB_FAIL_PREFIX = /^\S+:\d+:\d+-\d+:\d+@\S+ FAILED: /;

type Json = any;

function normalizeErrorResponse(res: Json): Json {
  if (res !== null && typeof res === "object" && typeof res.error === "string") {
    return { ...res, error: res.error.replace(MB_FAIL_PREFIX, "") };
  }
  return res;
}

function resolveCandidate(): { binary: string } | { fail: string } | { skip: string } {
  const raw = process.env.STILLFAIL_READER_CANDIDATE;
  if (raw !== undefined) {
    if (raw.trim() === "") return { fail: "STILLFAIL_READER_CANDIDATE is set but empty" };
    const binary = resolve(raw);
    if (!existsSync(binary)) return { fail: `STILLFAIL_READER_CANDIDATE does not exist: ${binary}` };
    try {
      if (!statSync(binary).isFile()) return { fail: `STILLFAIL_READER_CANDIDATE is not a file: ${binary}` };
      if (process.platform !== "win32") accessSync(binary, fsConstants.X_OK);
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

function candidate(): string {
  if ("fail" in RESOLVED) assert.fail(RESOLVED.fail);
  if ("skip" in RESOLVED) assert.fail(RESOLVED.skip);
  return RESOLVED.binary;
}

const dirs: string[] = [];
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

/// Create one canonical seeded DB file, checkpoint and close it cleanly, then clone it byte-for-byte.
function createSeedSnapshot(): { dir: string; seedPath: string } {
  const dir = mkdtempSync(join(tmpdir(), "builder-contract-"));
  dirs.push(dir);
  const seedPath = join(dir, "seed.db");
  const store = Store.open(seedPath, join(dir, "archive"));
  try {
    const db = store.db;
    for (const row of db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND (name LIKE 'archive_pin_%' OR name LIKE 'archive_keep_%')").all() as { name: string }[]) {
      db.exec(`DROP TRIGGER ${row.name}`);
    }
    db.exec("DROP TABLE archive_pin_rows; DROP TABLE archive_keep_rows; DROP TABLE archive_pin_replaced; DROP TABLE archive_keep_replaced; DROP TABLE archive_mark_meta");
    const pin = db.prepare("INSERT INTO pins(viewer, session, at) VALUES (?, ?, ?)");
    for (let i = 0; i < 600; i++) pin.run(`person${i % 7}`, `session-${i % 211}`, i);
    db.exec("DELETE FROM pins WHERE rowid % 13 = 0");
    const keep = db.prepare("INSERT INTO kept_chats(viewer, thread) VALUES (?, ?)");
    for (let i = 0; i < 300; i++) keep.run(`person${i % 5}`, i * 3);
    installArchiveMarkIndex(db);
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  } finally {
    store.close();
  }
  return { dir, seedPath };
}

function cloneSeedDb(dir: string, seedPath: string, label: string): { path: string; db: DatabaseSync } {
  const path = join(dir, `${label}.db`);
  copyFileSync(seedPath, path);
  const db = new DatabaseSync(path);
  return { path, db };
}

function snapshotBatchState(db: DatabaseSync): string {
  const all = (sql: string) => JSON.stringify(db.prepare(sql).all());
  return [
    `meta=${all("SELECT kind, version, last_rowid, end_rowid, complete FROM archive_mark_meta ORDER BY kind")}`,
    `pin_rows=${all("SELECT session, position FROM archive_pin_rows ORDER BY session, position")}`,
    `keep_rows=${all("SELECT thread, position FROM archive_keep_rows ORDER BY thread, position")}`,
    `pins=${all("SELECT rowid, viewer, session, at FROM pins ORDER BY rowid")}`,
    `kept_chats=${all("SELECT rowid, viewer, thread FROM kept_chats ORDER BY rowid")}`,
    `pin_replaced=${all("SELECT position, value FROM archive_pin_replaced ORDER BY position")}`,
    `keep_replaced=${all("SELECT position, value FROM archive_keep_replaced ORDER BY position")}`,
  ].join("\n");
}

function snapshotSqliteMaster(db: DatabaseSync): string {
  return JSON.stringify(db.prepare("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").all());
}

type Waiter = { resolve: (r: { json: Json; rawLine: Buffer }) => void; reject: (e: Error) => void; timer: NodeJS.Timeout };

class BuilderProcess {
  readonly #child: ChildProcess;
  readonly #waiting: Waiter[] = [];
  #carry: Buffer = Buffer.alloc(0);
  #stderr = "";
  #protocolError: Error | null = null;
  #ending = false;
  readonly #closed: Promise<{ code: number | null; signal: NodeJS.Signals | null }>;

  constructor(binary: string, args: string[]) {
    const child = spawn(binary, args, { stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
    this.#child = child;
    child.stdin!.on("error", () => {});
    child.stderr!.on("data", (c: Buffer) => { this.#stderr += c.toString("utf8"); });
    child.stdout!.on("data", (c: Buffer) => this.#heard(c));
    this.#closed = new Promise((done) => {
      let ended = false;
      const end = (code: number | null, signal: NodeJS.Signals | null) => {
        if (ended) return;
        ended = true;
        if (!this.#ending) this.#forbid(`builder exited before stdin EOF (code ${code}, signal ${signal}); stderr: ${this.#stderr}`);
        this.#rejectAll(new Error(`builder exited (code ${code}, signal ${signal}) with pending ask; stderr: ${this.#stderr}`));
        done({ code, signal });
      };
      child.on("error", (e) => {
        this.#forbid(`builder spawn error: ${e.message}`);
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

  #forbid(msg: string) {
    if (this.#protocolError === null) this.#protocolError = new Error(msg);
    this.#rejectAll(this.#protocolError);
    this.#child.kill("SIGKILL");
  }

  #heard(chunk: Buffer) {
    this.#carry = this.#carry.length === 0 ? chunk : Buffer.concat([this.#carry, chunk]);
    for (let nl = this.#carry.indexOf(0x0a); nl >= 0; nl = this.#carry.indexOf(0x0a)) {
      const rawLine = Buffer.from(this.#carry.subarray(0, nl));
      const line = rawLine.toString("utf8");
      this.#carry = this.#carry.subarray(nl + 1);
      let parsed: Json;
      try {
        parsed = JSON.parse(line);
      } catch {
        return this.#forbid(`stdout emitted non-JSON line: ${JSON.stringify(line.slice(0, 300))}`);
      }
      const w = this.#waiting.shift();
      if (w === undefined) return this.#forbid(`stdout emitted unsolicited line: ${line.slice(0, 300)}`);
      clearTimeout(w.timer);
      w.resolve({ json: parsed, rawLine });
    }
  }

  expectRaw(): Promise<{ json: Json; rawLine: Buffer }> {
    if (this.#protocolError !== null) return Promise.reject(this.#protocolError);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.#forbid(`ask unanswered within ${ASK_TIMEOUT_MS} ms; stderr: ${this.#stderr}`), ASK_TIMEOUT_MS);
      this.#waiting.push({ resolve, reject, timer });
    });
  }

  write(bytes: string | Buffer): Promise<void> {
    return new Promise((resolve, reject) => this.#child.stdin!.write(bytes, (e) => (e ? reject(e) : resolve())));
  }

  async askRaw(rawLine: string, eol = "\n"): Promise<{ json: Json; rawLine: Buffer }> {
    const answer = this.expectRaw();
    void this.write(`${rawLine}${eol}`).catch(() => {});
    return answer;
  }

  async ask(rawLine: string, eol = "\n"): Promise<Json> {
    return (await this.askRaw(rawLine, eol)).json;
  }

  async end(): Promise<void> {
    this.#ending = true;
    let timer: NodeJS.Timeout | undefined;
    try {
      if (this.#protocolError !== null) throw this.#protocolError;
      assert.equal(this.#waiting.length, 0, "no ask left unanswered");
      this.#child.stdin!.end();
      const { code, signal } = await new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve, reject) => {
        timer = setTimeout(() => reject(new Error(`no exit within ${ASK_TIMEOUT_MS} ms after stdin EOF; stderr: ${this.#stderr}`)), ASK_TIMEOUT_MS);
        void this.#closed.then(resolve);
      });
      if (this.#protocolError !== null) throw this.#protocolError;
      assert.equal(signal, null, `ended by signal ${signal}; stderr: ${this.#stderr}`);
      assert.equal(code, 0, `exit ${code}; stderr: ${this.#stderr}`);
      assert.equal(this.#carry.length, 0, `truncated trailing stdout: ${this.#carry.toString("utf8")}`);
    } finally {
      clearTimeout(timer);
      this.#rejectAll(new Error("test ended"));
      if (this.#child.exitCode === null && this.#child.signalCode === null) this.#child.kill("SIGKILL");
    }
  }

  async kill(): Promise<void> {
    this.#ending = true;
    this.#rejectAll(new Error("test failed"));
    this.#child.stdin!.destroy();
    this.#child.kill("SIGKILL");
    await this.#closed;
  }
}

test("archive-marks: cloned single-seed per-batch 0-diff parity (TS reference + candidate + MoonBit reader)", { skip }, async () => {
  const candBin = candidate();
  const mbBinRaw = mbReaderBinary();
  const requireDual = process.env.STILLFAIL_REQUIRE_DUAL_READER === "1";

  let mbBin: string | null = null;
  if (mbBinRaw !== null) {
    const candReal = realpathSync(candBin);
    const mbReal = realpathSync(mbBinRaw);
    if (mbReal !== candReal) {
      mbBin = resolve(mbBinRaw);
    } else if (requireDual) {
      assert.fail(`STILLFAIL_REQUIRE_DUAL_READER=1 requires distinct MB and candidate binaries, but both resolved to ${candReal}`);
    }
  } else if (requireDual) {
    assert.fail("STILLFAIL_REQUIRE_DUAL_READER=1 requires MoonBit reader binary (mbReaderBinary() returned null)");
  }

  const { dir, seedPath } = createSeedSnapshot();
  const refCopy = cloneSeedDb(dir, seedPath, "ref");
  const candCopy = cloneSeedDb(dir, seedPath, "cand");
  const mbCopy = mbBin !== null ? cloneSeedDb(dir, seedPath, "mb") : null;

  const candProc = new BuilderProcess(candBin, ["--builder", "archive-marks", "--db", candCopy.path]);
  const mbProc = mbBin !== null && mbCopy !== null
    ? new BuilderProcess(mbBin, ["--builder", "archive-marks", "--db", mbCopy.path])
    : null;

  let failed = true;
  const candTimingsMs: number[] = [];
  const mbTimingsMs: number[] = [];
  const candResponses: Json[] = [];
  const mbResponses: Json[] = [];

  try {
    let done = false;
    for (let batch = 1; batch <= 20; batch++) {
      const refRes = { done: archiveMarksStep(refCopy.db).done };

      const t0 = performance.now();
      const candRes = await candProc.ask(JSON.stringify({ scope: "all" }));
      candTimingsMs.push(Math.round((performance.now() - t0) * 100) / 100);
      candResponses.push(candRes);

      assert.deepStrictEqual(candRes, refRes, `batch ${batch}: candidate response vs TS reference`);
      assert.equal(
        snapshotBatchState(candCopy.db),
        snapshotBatchState(refCopy.db),
        `batch ${batch}: candidate DB tables/cursors must match TS reference 0-diff`,
      );

      if (mbProc !== null && mbCopy !== null) {
        const m0 = performance.now();
        const mbRes = await mbProc.ask(JSON.stringify({ scope: "all" }));
        mbTimingsMs.push(Math.round((performance.now() - m0) * 100) / 100);
        mbResponses.push(mbRes);

        assert.deepStrictEqual(candRes, mbRes, `batch ${batch}: candidate response vs MB`);
        assert.equal(
          snapshotBatchState(candCopy.db),
          snapshotBatchState(mbCopy.db),
          `batch ${batch}: candidate DB tables/cursors must match MB 0-diff`,
        );
      }

      if (refRes.done) {
        done = true;
        break;
      }
    }

    assert.equal(done, true, "archive-marks must reach done=true");
    assert.ok(candResponses.length >= 4, `expected >= 4 batches, got ${candResponses.length}`);
    assert.equal(archiveMarksReady(candCopy.db), true);
    assert.equal(snapshotSqliteMaster(candCopy.db), snapshotSqliteMaster(refCopy.db), "final sqlite_master vs TS reference");

    // Idempotency once complete
    assert.deepStrictEqual(await candProc.ask(JSON.stringify({ scope: "all" })), { done: true });
    if (mbProc !== null && mbCopy !== null) {
      assert.deepStrictEqual(await mbProc.ask(JSON.stringify({ scope: "all" })), { done: true });
      assert.equal(snapshotSqliteMaster(candCopy.db), snapshotSqliteMaster(mbCopy.db), "final sqlite_master vs MB");
    }

    console.log(`[reader-contract-builders] archive-marks candidate batches=${candResponses.length} timingsMs=${JSON.stringify(candTimingsMs)}`);
    if (mbProc !== null) {
      console.log(`[reader-contract-builders] archive-marks MB batches=${mbResponses.length} timingsMs=${JSON.stringify(mbTimingsMs)}`);
    }
    failed = false;
  } finally {
    // Independent teardown: never let one child's exit error skip ending the other child or closing DBs.
    let teardownError: unknown = null;
    try {
      const results = await Promise.allSettled([
        failed ? candProc.kill() : candProc.end(),
        mbProc !== null ? (failed ? mbProc.kill() : mbProc.end()) : Promise.resolve(),
      ]);
      for (const r of results) {
        if (r.status === "rejected" && teardownError === null) {
          teardownError = r.reason;
        }
      }
    } finally {
      refCopy.db.close();
      candCopy.db.close();
      mbCopy?.db.close();
    }
    if (!failed && teardownError !== null) {
      throw teardownError;
    }
  }
});

test("archive-marks: deterministic SQLITE_BUSY returns {done:false} without error, then finishes after lock release", { skip }, async () => {
  const { dir, seedPath } = createSeedSnapshot();
  const copy = cloneSeedDb(dir, seedPath, "busy");
  const locker = new DatabaseSync(copy.path);
  const proc = new BuilderProcess(candidate(), ["--builder", "archive-marks", "--db", copy.path]);
  let failed = true;
  try {
    locker.exec("BEGIN IMMEDIATE");
    const busyRes = await proc.ask(JSON.stringify({ scope: "all" }));
    assert.deepStrictEqual(busyRes, { done: false }, `expected {done:false} with no error field, got ${JSON.stringify(busyRes)}`);
    assert.deepStrictEqual(Object.keys(busyRes), ["done"]);

    locker.exec("ROLLBACK");
    locker.close();

    let done = false;
    for (let i = 0; i < 20; i++) {
      const res = await proc.ask(JSON.stringify({ scope: "all" }));
      assert.equal(res.error, undefined, `unexpected error after lock release: ${JSON.stringify(res)}`);
      if (res.done === true) {
        done = true;
        break;
      }
    }
    assert.equal(done, true, "builder must complete after write lock is released");
    assert.equal(archiveMarksReady(copy.db), true);
    failed = false;
  } finally {
    try { locker.close(); } catch {}
    if (failed) await proc.kill();
    else await proc.end();
    copy.db.close();
  }
});

test("archive-marks: protocol boundaries (empty line, cancel, duplicate keys, CRLF, U+2028 escape, app error 'is locked', zero lock leak)", { skip }, async () => {
  const { dir, seedPath } = createSeedSnapshot();
  const copy = cloneSeedDb(dir, seedPath, "proto");
  const proc = new BuilderProcess(candidate(), ["--builder", "archive-marks", "--db", copy.path]);
  let failed = true;
  try {
    // 1. Empty line and strict boolean {"cancel":true} produce zero stdout lines.
    await proc.write("\n");
    await proc.write(`${JSON.stringify({ cancel: true })}\n`);
    await proc.write(`${JSON.stringify({ cancel: true, scope: "all" })}\n`);

    // 2. Non-boolean {"cancel":"true"} is NOT treated as cancel; returns invalid preparation request.
    assert.deepStrictEqual(
      await proc.ask(JSON.stringify({ cancel: "true" })),
      { done: false, error: "invalid archive mark preparation request" },
    );

    // 3. Malformed JSON, invalid scope, and duplicate key last-wins ({"scope":"all","scope":"x"}).
    assert.deepStrictEqual(
      await proc.ask("{not valid json"),
      { done: false, error: "invalid archive mark preparation request" },
    );
    assert.deepStrictEqual(
      await proc.ask(JSON.stringify({ scope: "other" })),
      { done: false, error: "invalid archive mark preparation request" },
    );
    assert.deepStrictEqual(
      await proc.ask('{"scope":"all","scope":"x"}'),
      { done: false, error: "invalid archive mark preparation request" },
    );

    // 4. Incompatible numeric version -> strict deep-equal (after stripping MB fail() location prefix) + zero lock leak.
    copy.db.exec("UPDATE archive_mark_meta SET version = 99 WHERE kind = 'kept'");
    const badVer = await proc.ask(JSON.stringify({ scope: "all" }));
    assert.deepStrictEqual(
      normalizeErrorResponse(badVer),
      { done: false, error: "archive mark index version 99 is incompatible with 1" },
    );

    // 5. P1-1: Application error containing "is locked" MUST return error (NEVER misclassified as SQLITE_BUSY {done:false}).
    copy.db.exec("UPDATE archive_mark_meta SET version = 'is locked' WHERE kind = 'kept'");
    const lockedVer = await proc.ask(JSON.stringify({ scope: "all" }));
    assert.deepStrictEqual(
      normalizeErrorResponse(lockedVer),
      { done: false, error: 'archive mark index version "is locked" is incompatible with 1' },
    );

    // 6. P2-12: Error text containing U+2028 must be escaped as literal `\u2028` on stdout wire bytes.
    copy.db.exec("UPDATE archive_mark_meta SET version = 'bad' || char(8232) || 'ver' WHERE kind = 'kept'");
    const u2028Res = await proc.askRaw(JSON.stringify({ scope: "all" }));
    assert.equal(
      u2028Res.rawLine.includes(Buffer.from([0xe2, 0x80, 0xa8])),
      false,
      "raw UTF-8 U+2028 must not appear unescaped on stdout wire",
    );
    assert.equal(
      u2028Res.rawLine.toString("utf8").includes("\\u2028"),
      true,
      `expected \\u2028 escape on stdout wire, got: ${u2028Res.rawLine.toString("utf8")}`,
    );
    assert.deepStrictEqual(
      normalizeErrorResponse(u2028Res.json),
      { done: false, error: 'archive mark index version "bad\u2028ver" is incompatible with 1' },
    );

    // 7. Zero lock leak check: external connection with busy_timeout=0 immediately acquires BEGIN IMMEDIATE.
    const ext = new DatabaseSync(copy.path);
    try {
      ext.exec("PRAGMA busy_timeout = 0");
      ext.exec("BEGIN IMMEDIATE");
      ext.exec("UPDATE archive_mark_meta SET version = 1 WHERE kind = 'kept'");
      ext.exec("COMMIT");
    } finally {
      ext.close();
    }

    // 8. P2-12: CRLF (`\r\n`) line ending is accepted and builder completes cleanly.
    const crlfRes = await proc.ask(JSON.stringify({ scope: "all" }), "\r\n");
    assert.deepStrictEqual(crlfRes, { done: false });

    let done = false;
    for (let i = 0; i < 20; i++) {
      const res = await proc.ask(JSON.stringify({ scope: "all" }));
      assert.equal(res.error, undefined);
      if (res.done === true) {
        done = true;
        break;
      }
    }
    assert.equal(done, true);
    failed = false;
  } finally {
    if (failed) await proc.kill();
    else await proc.end();
    copy.db.close();
  }
});

test("archive-marks: missing DB path exits non-zero immediately without creating file or emitting JSON", { skip }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "builder-missing-"));
  dirs.push(dir);
  const missing = join(dir, "does-not-exist.db");

  const result = await new Promise<{ code: number | null; signal: NodeJS.Signals | null; stdout: string; stderr: string }>((resolveExit, reject) => {
    const child = spawn(candidate(), ["--builder", "archive-marks", "--db", missing], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    let stdout = "";
    let stderr = "";
    child.stdout!.on("data", (d: Buffer) => { stdout += d.toString("utf8"); });
    child.stderr!.on("data", (d: Buffer) => { stderr += d.toString("utf8"); });
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error("missing-DB builder hung instead of exiting immediately"));
    }, 10_000);
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      resolveExit({ code, signal, stdout, stderr });
    });
  });

  assert.equal(result.signal, null);
  assert.notEqual(result.code, 0, `expected non-zero exit for missing DB, got 0; stderr=${result.stderr}`);
  assert.equal(result.stdout.trim(), "", `expected no stdout JSON on open failure, got ${JSON.stringify(result.stdout)}`);
  assert.equal(existsSync(missing), false, "attach must never create a missing DB file");
});

type SqlToken =
  | { kind: "word"; upper: string }
  | { kind: "semi" }
  | { kind: "other" };

function unescapePionString(raw: string): string {
  let out = "";
  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i]!;
    if (ch === "\\" && i + 1 < raw.length) {
      const next = raw[i + 1]!;
      if (next === "n") out += "\n";
      else if (next === "r") out += "\r";
      else if (next === "t") out += "\t";
      else out += next;
      i++;
    } else {
      out += ch;
    }
  }
  return out;
}

function isSqlIdentStart(code: number): boolean {
  return (
    (code >= 65 && code <= 90) ||
    (code >= 97 && code <= 122) ||
    code === 95 ||
    (code >= 0x80 && code !== 0xfeff)
  );
}

function isSqlIdentPart(code: number): boolean {
  return isSqlIdentStart(code) || (code >= 48 && code <= 57) || code === 36; // digits and '$'
}

/// Single-pass character-level SQLite lexer:
/// - Skips ASCII whitespace and UTF-8 BOM (U+FEFF), matching SQLite's tokenizer.
/// - Single-quoted strings ('...' with '' escapes) and quoted identifiers ("...", `...`, [...])
///   never interpret `--` or `/*` inside quotes as comments.
/// - Line comments (`--...\n`) and block comments (`/*...*/`) are skipped outside quotes.
/// - Unquoted identifiers follow SQLite identifier rules (including `$` and non-ASCII continuations,
///   so `use$case` is one identifier rather than splitting out `CASE`).
function tokenizeSql(sql: string): SqlToken[] {
  const tokens: SqlToken[] = [];
  let i = 0;
  const n = sql.length;
  while (i < n) {
    const ch = sql[i]!;
    const code = sql.charCodeAt(i);
    if (
      ch === " " ||
      ch === "\t" ||
      ch === "\r" ||
      ch === "\n" ||
      ch === "\f" ||
      ch === "\v" ||
      code === 0xfeff
    ) {
      i++;
      continue;
    }
    if (ch === "-" && i + 1 < n && sql[i + 1] === "-") {
      i += 2;
      while (i < n && sql[i] !== "\n") i++;
      continue;
    }
    if (ch === "/" && i + 1 < n && sql[i + 1] === "*") {
      i += 2;
      while (i + 1 < n && !(sql[i] === "*" && sql[i + 1] === "/")) i++;
      i = Math.min(i + 2, n);
      continue;
    }
    if (ch === "'" || ch === '"' || ch === "`") {
      const quote = ch;
      i++;
      while (i < n) {
        if (sql[i] === quote) {
          if (i + 1 < n && sql[i + 1] === quote) {
            i += 2;
            continue;
          }
          i++;
          break;
        }
        i++;
      }
      tokens.push({ kind: "other" });
      continue;
    }
    if (ch === "[") {
      i++;
      while (i < n && sql[i] !== "]") i++;
      if (i < n) i++;
      tokens.push({ kind: "other" });
      continue;
    }
    if (ch === ";") {
      tokens.push({ kind: "semi" });
      i++;
      continue;
    }
    if (isSqlIdentStart(code)) {
      const start = i;
      i++;
      while (i < n && isSqlIdentPart(sql.charCodeAt(i))) {
        i++;
      }
      tokens.push({ kind: "word", upper: sql.slice(start, i).toUpperCase() });
      continue;
    }
    tokens.push({ kind: "other" });
    i++;
  }
  return tokens;
}

/// Static guard for `builders_core/src/` business files:
/// Uses a single-pass SQLite lexer (`tokenizeSql`) and closes `CREATE [TEMP|TEMPORARY] TRIGGER ... BEGIN ... END`
/// bodies strictly on a statement-boundary `END` (immediately after `;` or `BEGIN`), so column identifiers like
/// `NEW.end` / `NEW.use$case` and `CASE ... END` expressions never falsely close or break the trigger scan, while
/// rejecting any non-trigger statement whose leading SQL keyword is `BEGIN`, `COMMIT`, `END`, `SAVEPOINT`,
/// `RELEASE`, or `ROLLBACK` (allowing only `builder_loop.pion`'s leak-guard `ROLLBACK`).
function findRawTxControlViolations(filename: string, source: string): string[] {
  const violations: string[] = [];
  const forbiddenHeads = new Set(["BEGIN", "COMMIT", "END", "SAVEPOINT", "RELEASE", "ROLLBACK"]);
  const lines = source.split("\n");
  for (let idx = 0; idx < lines.length; idx++) {
    const line = lines[idx]!;
    const trimmed = line.trim();
    if (trimmed.startsWith("//")) continue;
    const litRe = /"((?:\\.|[^"\\])*)"/g;
    let m: RegExpExecArray | null;
    while ((m = litRe.exec(line)) !== null) {
      const literal = m[1]!;
      const tokens = tokenizeSql(unescapePionString(literal));
      let atStmtStart = true;
      let inTriggerHeader = false;
      let inTriggerBody = false;
      let atTriggerStmtStart = false;

      for (let t = 0; t < tokens.length; t++) {
        const tok = tokens[t]!;
        if (inTriggerBody) {
          if (tok.kind === "semi") {
            atTriggerStmtStart = true;
          } else if (atTriggerStmtStart && tok.kind === "word" && tok.upper === "END") {
            inTriggerBody = false;
            atTriggerStmtStart = false;
            atStmtStart = false;
          } else {
            atTriggerStmtStart = false;
          }
          continue;
        }
        if (inTriggerHeader) {
          if (tok.kind === "word" && tok.upper === "BEGIN") {
            inTriggerHeader = false;
            inTriggerBody = true;
            atTriggerStmtStart = true;
          } else if (tok.kind === "semi") {
            inTriggerHeader = false;
            atStmtStart = true;
          }
          continue;
        }
        if (tok.kind === "semi") {
          atStmtStart = true;
          continue;
        }
        if (!atStmtStart) continue;
        atStmtStart = false;
        if (tok.kind !== "word") continue;

        if (tok.upper === "CREATE") {
          const t1 = tokens[t + 1];
          const t2 = tokens[t + 2];
          if (
            (t1?.kind === "word" && t1.upper === "TRIGGER") ||
            (t1?.kind === "word" &&
              (t1.upper === "TEMP" || t1.upper === "TEMPORARY") &&
              t2?.kind === "word" &&
              t2.upper === "TRIGGER")
          ) {
            inTriggerHeader = true;
          }
          continue;
        }

        if (!forbiddenHeads.has(tok.upper)) continue;
        if (filename === "builder_loop.pion" && tok.upper === "ROLLBACK") continue;
        violations.push(`${filename}:${idx + 1}: forbidden raw transaction SQL "${tok.upper}" in literal "${literal}"`);
      }
    }
  }
  return violations;
}

test("builders_core static guard: rejects raw transaction SQL and passes on real business files", () => {
  // Positive cases (must be caught):
  assert.ok(findRawTxControlViolations("foo.pion", 'let _ = db.exec("BEGIN")').length > 0, "bare BEGIN caught");
  assert.ok(findRawTxControlViolations("foo.pion", 'let _ = db.exec("BEGIN IMMEDIATE")').length > 0, "BEGIN IMMEDIATE caught");
  assert.ok(findRawTxControlViolations("foo.pion", 'let _ = db.exec("BEGIN DEFERRED")').length > 0, "BEGIN DEFERRED caught");
  assert.ok(findRawTxControlViolations("foo.pion", 'let _ = db.exec("BEGIN EXCLUSIVE")').length > 0, "BEGIN EXCLUSIVE caught");
  assert.ok(findRawTxControlViolations("foo.pion", 'let _ = db.exec("BEGIN TRANSACTION")').length > 0, "BEGIN TRANSACTION caught");
  assert.ok(findRawTxControlViolations("foo.pion", 'let _ = db.exec("COMMIT")').length > 0, "COMMIT caught");
  assert.ok(findRawTxControlViolations("foo.pion", 'let _ = db.exec("END")').length > 0, "END caught");
  assert.ok(findRawTxControlViolations("foo.pion", 'let _ = db.exec("END TRANSACTION")').length > 0, "END TRANSACTION caught");
  assert.ok(findRawTxControlViolations("foo.pion", 'let _ = db.exec("SAVEPOINT sp1")').length > 0, "SAVEPOINT caught");
  assert.ok(findRawTxControlViolations("foo.pion", 'let _ = db.exec("RELEASE s")').length > 0, "RELEASE s caught");
  assert.ok(findRawTxControlViolations("foo.pion", 'let _ = db.exec("RELEASE SAVEPOINT sp1")').length > 0, "RELEASE SAVEPOINT caught");
  assert.ok(findRawTxControlViolations("foo.pion", 'let _ = db.exec("ROLLBACK")').length > 0, "ROLLBACK in business file caught");
  assert.ok(
    findRawTxControlViolations("foo.pion", 'let _ = db.exec("\uFEFFBEGIN IMMEDIATE")').length > 0,
    "UTF-8 BOM before initial BEGIN IMMEDIATE must be caught",
  );
  assert.ok(
    findRawTxControlViolations("foo.pion", 'let _ = db.exec("SELECT 1; \uFEFFBEGIN IMMEDIATE")').length > 0,
    "UTF-8 BOM after semicolon before BEGIN IMMEDIATE must be caught",
  );
  assert.ok(
    findRawTxControlViolations("foo.pion", 'let _ = db.exec("SELECT \'--\'; BEGIN IMMEDIATE")').length > 0,
    "BEGIN IMMEDIATE after '--' string literal must be caught",
  );
  assert.ok(
    findRawTxControlViolations("foo.pion", 'let _ = db.exec("CREATE TRIGGER t AFTER INSERT ON x BEGIN SELECT 1; END; BEGIN IMMEDIATE")').length > 0,
    "BEGIN IMMEDIATE after CREATE TRIGGER must still be caught",
  );
  assert.ok(
    findRawTxControlViolations(
      "foo.pion",
      'let _ = db.exec("CREATE TRIGGER t AFTER INSERT ON x BEGIN SELECT CASE WHEN 1 THEN 2 ELSE 3 END; END; BEGIN IMMEDIATE")',
    ).length > 0,
    "BEGIN IMMEDIATE after CREATE TRIGGER with nested CASE...END must be caught",
  );
  assert.ok(
    findRawTxControlViolations(
      "foo.pion",
      'let _ = db.exec("CREATE TRIGGER t AFTER INSERT ON x BEGIN SELECT NEW.use$case; END; BEGIN IMMEDIATE")',
    ).length > 0,
    "BEGIN IMMEDIATE after CREATE TRIGGER referencing use$case identifier must be caught",
  );
  // Negative cases (must produce 0 false positives):
  assert.equal(findRawTxControlViolations("foo.pion", 'let _ = db.all("SELECT \'begin\'", [])').length, 0, "SELECT 'begin' allowed");
  assert.equal(
    findRawTxControlViolations("foo.pion", 'let _ = db.exec("CREATE TRIGGER t AFTER INSERT ON x BEGIN SELECT 1; END")').length,
    0,
    "CREATE TRIGGER ... BEGIN ... END allowed",
  );
  assert.equal(
    findRawTxControlViolations(
      "foo.pion",
      'let _ = db.exec("CREATE TRIGGER t AFTER INSERT ON x BEGIN SELECT CASE WHEN 1 THEN 2 ELSE 3 END; END")',
    ).length,
    0,
    "CREATE TRIGGER with nested CASE...END allowed",
  );
  assert.equal(
    findRawTxControlViolations(
      "foo.pion",
      'let _ = db.exec("CREATE TRIGGER t AFTER INSERT ON x BEGIN SELECT NEW.end; END")',
    ).length,
    0,
    "CREATE TRIGGER referencing NEW.end column identifier allowed",
  );
  assert.equal(
    findRawTxControlViolations("builder_loop.pion", 'let _ = db.exec("ROLLBACK")').length,
    0,
    "builder_loop.pion leak-guard ROLLBACK allowed",
  );

  // Check real business files in pion/station/packages/builders_core/src/.
  const buildersSrcDir = resolve(fileURLToPath(new URL("../../pion/station/packages/builders_core/src", import.meta.url)));
  assert.ok(existsSync(buildersSrcDir), `expected ${buildersSrcDir} to exist`);
  const files = readdirSync(buildersSrcDir).filter((f) => f.endsWith(".pion") && !f.endsWith("_test.pion"));
  assert.ok(files.length > 0, "expected builders_core .pion business files");
  const allViolations: string[] = [];
  for (const file of files) {
    const content = readFileSync(join(buildersSrcDir, file), "utf8");
    allViolations.push(...findRawTxControlViolations(file, content));
  }
  assert.deepStrictEqual(allViolations, [], `raw transaction SQL found in builders_core:\n${allViolations.join("\n")}`);
});
