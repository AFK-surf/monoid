// The statistics of usage kept before the quarters (store/usage-15m.ts) retired once the station before has gone
// (store/usage-retire.ts, usage/module.ts `retireAfterPrevious`): their writers stopped in one write as handover ends,
// their tables freed a bounded batch at a time, never brought back; the calls go on being recorded and counted.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, closeSync, constants as fsConstants, mkdtempSync, openSync, rmSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { constants, DatabaseSync } from "node:sqlite";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Effect, Fiber } from "effect";
import { makeStore, usageGroups } from "./reference/store.ts";
import { usageHistory } from "./reference/usage.ts";
import { Store } from "../src/store/store.ts";
import { dropUsageIndexStep, retireUsageIndexes, stopUsageIndexes, usageIndexBatchSql } from "./reference/backfill/usage-retire.ts";
import { retireAfterPrevious } from "../src/usage/module.ts";

const call = (id: string, input: number) => [{ id, at: 1_700_000_000_000, model: "m", subagent: false, fast: false,
  input, cacheRead: 0, cacheWrite: 0, cacheWriteLong: 0, output: 1, calls: 1, context: 100, window: 1000 },
  { turn: null, person: null, thread: null, profile: "cc" }] as const;
const table = (store: Store, name: string) => store.db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(name);
const write = (store: Store, id: string, input: number) => store.recordUsage("/a", { session: "a", offset: 1, model: "m" }, "claude", [call(id, input)] as never);
const session = (store: Store) => store.insertSession({ key: "a", connect: "ember", runtime: "claude", profile: "cc", workspace: "/w", token: "a", ws: "A", createdAt: 1, lastActiveAt: 1 });

/// The statistics a station from before kept, as it left them: a per-call detail (by its primary key), the minute
/// summaries' marker, the year, each still written by its trigger as calls are recorded.
function before(store: Store) {
  store.db.exec(`CREATE TABLE usage_detail (session TEXT NOT NULL, bucket INTEGER NOT NULL, n INTEGER NOT NULL,
      PRIMARY KEY (session, bucket)) WITHOUT ROWID;
    CREATE TABLE usage_detail_lookup (session TEXT PRIMARY KEY) WITHOUT ROWID;
    CREATE TABLE usage_compact_total (scope TEXT PRIMARY KEY, calls INTEGER);
    CREATE TABLE usage_history (scope TEXT NOT NULL, quarter INTEGER NOT NULL, calls INTEGER NOT NULL, PRIMARY KEY (scope, quarter)) WITHOUT ROWID;
    CREATE TRIGGER usage_detail_add AFTER INSERT ON usage BEGIN
      INSERT INTO usage_detail VALUES (NEW.session, NEW.rowid, NEW.calls);
      INSERT OR IGNORE INTO usage_detail_lookup VALUES (NEW.session);
    END;
    CREATE TRIGGER usage_history_add AFTER INSERT ON usage BEGIN
      INSERT INTO usage_history VALUES ('', NEW.at / 900000, NEW.calls) ON CONFLICT DO UPDATE SET calls = calls + excluded.calls;
    END;`);
}
const detailed = (store: Store) => (store.db.prepare("SELECT COALESCE(SUM(n), 0) AS n FROM usage_detail").get() as { n: number }).n;

test("a station with nothing to retire or take in tells no page", async () => {
  const store = Store.open(":memory:");
  const told: unknown[] = [];
  const stop = store.subscribe((change) => { if (change.type === "usage") told.push(change); });
  try {
    await Effect.runPromise(retireAfterPrevious(store, Promise.resolve()));
    assert.deepEqual(told, []);
    assert.ok(table(store, "usage_contexts"), "the contexts are kept from now on");
  } finally { stop(); store.close(); }
});

test("retirement waits for handover, removes the old statistics and keeps recording calls", async () => {
  const store = Store.open(":memory:");
  try {
    session(store);
    before(store);
    write(store, "old", 2);
    let handover!: () => void;
    const fiber = Effect.runFork(retireAfterPrevious(store, new Promise<void>((resolve) => { handover = resolve; })));
    write(store, "during", 3);
    assert.equal(detailed(store), 2, "the station before writes its statistics until it has gone");
    handover();
    await Effect.runPromise(Fiber.join(fiber));
    assert.ok(table(store, "usage_detail"), "in memory no builder frees them");
    assert.equal(store.db.prepare("SELECT 1 FROM sqlite_master WHERE name = 'usage_detail_add'").get(), undefined, "but their writers are stopped");
    retireUsageIndexes(store.db);
    for (const name of ["usage_detail", "usage_detail_lookup", "usage_compact_total", "usage_history", "usage_main_calls"]) assert.equal(table(store, name), undefined, name);
    const triggers = store.db.prepare("SELECT name, sql FROM sqlite_master WHERE type = 'trigger'").all() as { name: string; sql: string }[];
    assert.deepEqual(triggers.filter((t) => /\busage_(detail|history|compact|minute|summary)(?:_\w+)?\b|\busage_main_calls\b/.test(t.sql)
      && !/usage_compact_context|usage_minute_scope/.test(t.sql)).map((t) => t.name), []);
    write(store, "new", 4);
    assert.equal((store.db.prepare("SELECT COUNT(*) AS n FROM usage").get() as { n: number }).n, 3);
    assert.deepEqual(store.usageOfSession("a").map((r) => [r.calls, r.input, r.output]), [[3, 9, 3]]);
    assert.equal(store.lastContexts("a", 5).length, 1);
    assert.deepEqual(usageGroups(makeStore(store.db, "."), 0n, 9_223_372_036_854_775_807n, 0n).map((r) => [r.calls, r.input]), [[3, 9]]);
    assert.deepEqual(usageHistory(makeStore(store.db, "."), 0n, null)!.days.map((r: { calls: number; tokens: number }) => [r.calls, r.tokens]), [[3, 12]]);
  } finally { store.close(); }
});

test("the old statistics stop being written even when their cleanup program cannot start", async () => {
  const dir = mkdtempSync(join(tmpdir(), "usage-retire-missing-worker-"));
  const store = Store.open(join(dir, "station.db"));
  try {
    session(store);
    before(store);
    write(store, "before", 2);
    let handover!: () => void;
    const fiber = Effect.runFork(retireAfterPrevious(store, new Promise<void>((resolve) => { handover = resolve; }),
      join(tmpdir(), "no-such-usage-program")));
    write(store, "during", 3);
    assert.equal(detailed(store), 2, "the previous station can use them until handover");
    handover();
    await Effect.runPromise(Fiber.join(fiber));
    assert.ok(table(store, "usage_contexts"), "the contexts are kept even when cleanup cannot start");
    assert.ok(table(store, "usage_detail"), "the failed program did not delete the old rows");
    write(store, "after", 4);
    assert.equal(detailed(store), 2, "new calls no longer write the old statistics");
    assert.deepEqual(store.usageOfSession("a").map((r) => [r.calls, r.input]), [[3, 9]]);
    assert.deepEqual(usageHistory(makeStore(store.db, dir), 0n, null)!.days.map((r: { calls: number; tokens: number }) => [r.calls, r.tokens]), [[3, 12]]);
  } finally { store.close(); rmSync(dir, { recursive: true, force: true }); }
});

test("stopping the old writers yields to another database writer and retries", async () => {
  const dir = mkdtempSync(join(tmpdir(), "usage-retire-busy-"));
  const path = join(dir, "station.db");
  const store = Store.open(path);
  const blocker = new DatabaseSync(path);
  try {
    session(store);
    before(store);
    write(store, "before", 2);
    const timeout = (store.db.prepare("PRAGMA busy_timeout").get() as { timeout: number }).timeout;
    let attempts = 0;
    store.db.setAuthorizer((action, operation) => {
      if (action === constants.SQLITE_TRANSACTION && operation === "BEGIN") attempts++;
      return constants.SQLITE_OK;
    });
    blocker.exec("BEGIN IMMEDIATE");
    const fiber = Effect.runFork(retireAfterPrevious(store, Promise.resolve(), join(tmpdir(), "no-such-usage-program")));
    await new Promise<void>((resolve) => setImmediate(resolve));
    assert.ok(attempts > 0, "the stop tried while the other connection held the lock");
    assert.ok(store.db.prepare("SELECT 1 FROM sqlite_master WHERE name = 'usage_detail_add'").get());
    assert.equal((store.db.prepare("PRAGMA busy_timeout").get() as { timeout: number }).timeout, timeout);
    blocker.exec("COMMIT");
    await Effect.runPromise(Fiber.join(fiber));
    store.db.setAuthorizer(null);
    assert.equal(store.db.prepare("SELECT 1 FROM sqlite_master WHERE name = 'usage_detail_add'").get(), undefined, "stopping is retried after the lock is released");
    write(store, "after", 3);
    assert.deepEqual(store.usageOfSession("a").map((r) => [r.calls, r.input]), [[2, 5]]);
  } finally { store.db.setAuthorizer(null); blocker.close(); store.close(); rmSync(dir, { recursive: true, force: true }); }
});

test("a failed context installation still stops the old writers", async () => {
  const store = Store.open(":memory:");
  try {
    session(store);
    before(store);
    write(store, "before", 2);
    store.db.setAuthorizer((action, name) =>
      action === constants.SQLITE_CREATE_TABLE && name === "usage_contexts" ? constants.SQLITE_DENY : constants.SQLITE_OK);
    await Effect.runPromise(retireAfterPrevious(store, Promise.resolve()));
    store.db.setAuthorizer(null);
    assert.equal(table(store, "usage_contexts"), undefined);
    assert.equal(store.db.prepare("SELECT 1 FROM sqlite_master WHERE name = 'usage_detail_add'").get(), undefined, "the old writers are stopped");
    write(store, "after", 3);
    assert.equal((store.db.prepare("SELECT COUNT(*) AS n FROM usage").get() as { n: number }).n, 2);
    assert.deepEqual(store.usageOfSession("a").map((r) => [r.calls, r.input]), [[2, 5]]);
  } finally { store.db.setAuthorizer(null); store.close(); }
});

test("retirement deletes at most one primary-key batch before releasing its write lock", () => {
  const store = Store.open(":memory:");
  try {
    session(store);
    before(store);
    for (let i = 0; i < 300; i++) {
      const [value, owner] = call(`call-${i}`, 1);
      store.recordUsage("/a", { session: "a", offset: i, model: "m" }, "claude",
        [[{ ...value, at: value.at + i * 60_000 }, owner]] as never);
    }
    assert.equal(dropUsageIndexStep(store.db), true, "nothing is freed while its writers run");
    assert.ok(table(store, "usage_detail"));
    stopUsageIndexes(store.db);
    // (the empty one before it by name goes first)
    while (table(store, "usage_compact_total")) dropUsageIndexStep(store.db);
    const count = () => (store.db.prepare("SELECT COUNT(*) AS n FROM usage_detail").get() as { n: number }).n;
    assert.equal(count(), 300);
    const plan = store.db.prepare(`EXPLAIN QUERY PLAN ${usageIndexBatchSql(store.db, "usage_detail")}`).all(256) as { detail: string }[];
    assert.ok(plan.some((row) => /SEARCH usage_detail USING PRIMARY KEY/.test(row.detail)), JSON.stringify(plan));
    assert.equal(dropUsageIndexStep(store.db), false);
    assert.equal(count(), 300 - 256);
    assert.ok(table(store, "usage_detail"), "the table remains until its rows are deleted");
    while (table(store, "usage_detail")) dropUsageIndexStep(store.db);
    assert.equal(table(store, "usage_detail"), undefined);
    write(store, "after", 3);
    assert.equal((store.db.prepare("SELECT COUNT(*) AS n FROM usage").get() as { n: number }).n, 301);
  } finally { store.close(); }
});

test("an interrupted retirement resumes and reopening does not restore the old statistics", async () => {
  const dir = mkdtempSync(join(tmpdir(), "usage-retire-"));
  const path = join(dir, "station.db");
  let store = Store.open(path);
  try {
    session(store);
    before(store);
    write(store, "old", 2);
    stopUsageIndexes(store.db);
    assert.ok(table(store, "usage_detail"));
    write(store, "after-stop", 4);
    store.close();
    store = Store.open(path);
    await Effect.runPromise(retireAfterPrevious(store, Promise.resolve()));
    for (const name of ["usage_detail", "usage_detail_lookup", "usage_history", "usage_main_calls"]) assert.equal(table(store, name), undefined, name);
    store.close();
    store = Store.open(path);
    write(store, "after-reopen", 5);
    for (const name of ["usage_detail", "usage_main_calls", "usage_history", "usage_minute", "usage_compact"]) assert.equal(table(store, name), undefined, name);
    assert.deepEqual(store.usageOfSession("a").map((r) => [r.calls, r.input]), [[3, 11]]);
  } finally { store.close(); rmSync(dir, { recursive: true, force: true }); }
});

test("interrupting retirement terminates its cleanup program before shutdown finishes", { skip: process.platform === "win32" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "usage-retire-interrupt-"));
  const store = Store.open(join(dir, "station.db"));
  const fifo = join(dir, "child.fifo");
  const script = join(dir, "stub-retire.sh");
  execFileSync("mkfifo", [fifo]);
  // Synchronize startup via a FIFO (deterministic on both Linux and macOS, no FSEvents timing gap) and exec sleep so
  // the recorded PID is the exact process that terminate() must signal and reap, ignoring stdin EOF.
  writeFileSync(script, `#!/bin/sh\necho $$ > ${JSON.stringify(fifo)}\nexec sleep 60\n`);
  chmodSync(script, 0o755);
  let childPid = 0;
  let readDone = false;
  try {
    const started = readFile(fifo, "utf8").then((text) => {
      readDone = true;
      const pid = Number(text.trim());
      assert.ok(Number.isInteger(pid) && pid > 1, `unexpected stub pid: ${JSON.stringify(text)}`);
      return pid;
    });
    const fiber = Effect.runFork(retireAfterPrevious(store, Promise.resolve(), script));
    // Fail fast if the fiber settles before the stub ever writes its PID.
    const joined = Effect.runPromise(Fiber.join(fiber)).then((done) => {
      throw new Error(`retireAfterPrevious settled before stub started (done=${String(done)})`);
    });
    // Suppress unhandled rejection when `started` wins and `fiber` is interrupted below.
    joined.catch(() => {});
    childPid = await Promise.race([started, joined]);
    // Child is alive right before interruption.
    assert.doesNotThrow(() => process.kill(childPid, 0));
    await Effect.runPromise(Fiber.interrupt(fiber));
    // Interruption must have terminated and reaped the child before resolving.
    assert.throws(() => process.kill(childPid, 0), { code: "ESRCH" });
  } finally {
    if (!readDone) {
      // Unblock a pending FIFO open(O_RDONLY) if the stub failed before opening the write end.
      try { closeSync(openSync(fifo, fsConstants.O_WRONLY | fsConstants.O_NONBLOCK)); } catch {}
    }
    if (childPid > 1) {
      try { process.kill(childPid, "SIGKILL"); } catch {}
    }
    store.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
