// Black-box contract tests for SQLite builders (`--builder archive-marks --db <file>`) against
// any reader binary, spoken to over its stdio alone.
//
// By default this runs against the shipped MoonBit `stillfail-reader` (`mbReaderBinary()`). Set
// `STILLFAIL_READER_CANDIDATE=/path/to/stillfail-pion` to verify a candidate binary with zero edits
// to this suite: a candidate named but empty, missing or not executable fails every test, never skips.
// With no candidate named and no reader built, the tests skip locally and fail under CI (`CI` set).
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { accessSync, constants as fsConstants, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";
import { archiveMarksReady, archiveMarksStep, installArchiveMarkIndex } from "./reference/backfill/archive-mark-index.ts";

const ASK_TIMEOUT_MS = 30_000;

type Json = any;

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

function seedArchiveMarksDb() {
  const dir = mkdtempSync(join(tmpdir(), "builder-contract-"));
  dirs.push(dir);
  const path = join(dir, "stillfail.db");
  const store = Store.open(path, join(dir, "archive"));
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
  return { dir, path, store };
}

function snapshotTables(db: DatabaseSync): string {
  const all = (sql: string) => JSON.stringify(db.prepare(sql).all());
  return [
    all("SELECT session, position FROM archive_pin_rows ORDER BY session, position"),
    all("SELECT thread, position FROM archive_keep_rows ORDER BY thread, position"),
    all("SELECT kind, version, last_rowid, end_rowid, complete FROM archive_mark_meta ORDER BY kind"),
    all("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"),
  ].join("\n");
}

type Waiter = { resolve: (j: Json) => void; reject: (e: Error) => void; timer: NodeJS.Timeout };

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
      const line = this.#carry.subarray(0, nl).toString("utf8");
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
      w.resolve(parsed);
    }
  }

  expect(): Promise<Json> {
    if (this.#protocolError !== null) return Promise.reject(this.#protocolError);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.#forbid(`ask unanswered within ${ASK_TIMEOUT_MS} ms; stderr: ${this.#stderr}`), ASK_TIMEOUT_MS);
      this.#waiting.push({ resolve, reject, timer });
    });
  }

  write(bytes: string | Buffer): Promise<void> {
    return new Promise((resolve, reject) => this.#child.stdin!.write(bytes, (e) => (e ? reject(e) : resolve())));
  }

  ask(rawLine: string): Promise<Json> {
    const answer = this.expect();
    void this.write(`${rawLine}\n`).catch(() => {});
    return answer;
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

async function runArchiveMarksBatches(binary: string, dbPath: string): Promise<{ responses: Json[]; timingsMs: number[] }> {
  const proc = new BuilderProcess(binary, ["--builder", "archive-marks", "--db", dbPath]);
  const responses: Json[] = [];
  const timingsMs: number[] = [];
  let failed = true;
  try {
    for (let i = 0; i < 20; i++) {
      const t0 = performance.now();
      const res = await proc.ask(JSON.stringify({ scope: "all" }));
      timingsMs.push(Math.round((performance.now() - t0) * 100) / 100);
      responses.push(res);
      if (res.done === true) break;
    }
    // Idempotent once complete
    const again = await proc.ask(JSON.stringify({ scope: "all" }));
    assert.deepEqual(again, { done: true });
    failed = false;
  } finally {
    if (failed) await proc.kill();
  }
  await proc.end();
  return { responses, timingsMs };
}

test("archive-marks: cloned dual-DB 0-diff parity (candidate vs reference and MoonBit reader when available)", { skip }, async () => {
  const candBin = candidate();
  const refSeed = seedArchiveMarksDb();
  const candSeed = seedArchiveMarksDb();
  const mbBin = mbReaderBinary();
  const mbSeed = mbBin !== null && resolve(mbBin) !== candBin ? seedArchiveMarksDb() : null;

  try {
    // 1. Run TypeScript reference batch by batch
    const refSteps: { done: boolean }[] = [];
    for (let i = 0; i < 20; i++) {
      const r = archiveMarksStep(refSeed.store.db);
      refSteps.push({ done: r.done });
      if (r.done) break;
    }

    // 2. Run candidate binary
    const candRun = await runArchiveMarksBatches(candBin, candSeed.path);
    console.log(`[reader-contract-builders] archive-marks candidate batches=${candRun.responses.length} timingsMs=${JSON.stringify(candRun.timingsMs)}`);

    assert.ok(candRun.responses.length >= 4, `expected >= 4 batches, got ${JSON.stringify(candRun.responses)}`);
    assert.deepEqual(candRun.responses, refSteps, "candidate batch sequence must match TS reference 0-diff");
    assert.equal(snapshotTables(candSeed.store.db), snapshotTables(refSeed.store.db), "candidate tables & sqlite_master must match TS reference 0-diff");
    assert.equal(archiveMarksReady(candSeed.store.db), true);

    // 3. When a distinct MoonBit reader binary is available, verify strict 0-diff against MB too
    if (mbSeed !== null && mbBin !== null) {
      const mbRun = await runArchiveMarksBatches(resolve(mbBin), mbSeed.path);
      console.log(`[reader-contract-builders] archive-marks MB batches=${mbRun.responses.length} timingsMs=${JSON.stringify(mbRun.timingsMs)}`);
      assert.deepEqual(candRun.responses, mbRun.responses, "candidate batch sequence must match MB 0-diff");
      assert.equal(snapshotTables(candSeed.store.db), snapshotTables(mbSeed.store.db), "candidate tables & sqlite_master must match MB 0-diff");
    }
  } finally {
    refSeed.store.close();
    candSeed.store.close();
    mbSeed?.store.close();
  }
});

test("archive-marks: deterministic SQLITE_BUSY returns {done:false} without error, then finishes after lock release", { skip }, async () => {
  const seed = seedArchiveMarksDb();
  const locker = new DatabaseSync(seed.path);
  const proc = new BuilderProcess(candidate(), ["--builder", "archive-marks", "--db", seed.path]);
  let failed = true;
  try {
    locker.exec("BEGIN IMMEDIATE");
    const busyRes = await proc.ask(JSON.stringify({ scope: "all" }));
    assert.deepEqual(busyRes, { done: false }, `expected {done:false} with no error field, got ${JSON.stringify(busyRes)}`);
    assert.deepEqual(Object.keys(busyRes), ["done"]);

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
    assert.equal(archiveMarksReady(seed.store.db), true);
    failed = false;
  } finally {
    try { locker.close(); } catch {}
    if (failed) await proc.kill();
    else await proc.end();
    seed.store.close();
  }
});

test("archive-marks: protocol boundaries (empty line, cancel, bad JSON, invalid scope, incompatible version + zero lock leak)", { skip }, async () => {
  const seed = seedArchiveMarksDb();
  const proc = new BuilderProcess(candidate(), ["--builder", "archive-marks", "--db", seed.path]);
  let failed = true;
  try {
    // Empty line and {"cancel":true} must produce zero stdout lines before the next real ask.
    await proc.write("\n");
    await proc.write(`${JSON.stringify({ cancel: true })}\n`);
    await proc.write(`${JSON.stringify({ cancel: true, scope: "all" })}\n`);

    // Malformed JSON -> invalid preparation request
    const badJson = await proc.ask("{not valid json");
    assert.deepEqual(badJson, { done: false, error: "invalid archive mark preparation request" });

    // Invalid scope -> invalid preparation request
    const badScope = await proc.ask(JSON.stringify({ scope: "other" }));
    assert.deepEqual(badScope, { done: false, error: "invalid archive mark preparation request" });

    // Incompatible version -> error message mentioning version 99 AND zero transaction/lock leak!
    seed.store.db.exec("UPDATE archive_mark_meta SET version = 99 WHERE kind = 'kept'");
    const badVer = await proc.ask(JSON.stringify({ scope: "all" }));
    assert.equal(badVer.done, false);
    assert.equal(typeof badVer.error, "string");
    assert.ok(
      badVer.error.includes("archive mark index version 99 is incompatible with 1"),
      `unexpected incompatible version error: ${JSON.stringify(badVer)}`,
    );

    // Immediately acquire BEGIN IMMEDIATE on an external connection: fails with SQLITE_BUSY if candidate leaked a tx!
    const ext = new DatabaseSync(seed.path);
    try {
      ext.exec("PRAGMA busy_timeout = 0");
      ext.exec("BEGIN IMMEDIATE");
      ext.exec("UPDATE archive_mark_meta SET version = 1 WHERE kind = 'kept'");
      ext.exec("COMMIT");
    } finally {
      ext.close();
    }

    // Builder remains healthy and completes after version is restored.
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
    seed.store.close();
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

test("builders_core static guard: business files never use raw BEGIN IMMEDIATE / BEGIN TRANSACTION", () => {
  const buildersSrcDir = resolve(fileURLToPath(new URL("../../pion/station/packages/builders_core/src", import.meta.url)));
  assert.ok(existsSync(buildersSrcDir), `expected ${buildersSrcDir} to exist`);
  const files = readdirSync(buildersSrcDir).filter((f) => f.endsWith(".pion") && !f.endsWith("_test.pion"));
  assert.ok(files.length > 0, "expected builders_core .pion business files");
  for (const file of files) {
    const content = readFileSync(join(buildersSrcDir, file), "utf8");
    assert.equal(
      /\bBEGIN\s+(IMMEDIATE|TRANSACTION)\b/i.test(content),
      false,
      `${file} must use db.tx(...) instead of raw BEGIN IMMEDIATE/BEGIN TRANSACTION`,
    );
  }
});
