import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Store } from "../src/store/store.ts";
import { giveBackfill, releaseStoppedBackfill, takeBackfill } from "../src/store/backfill.ts";
import { MinuteReader } from "../src/usage/minute-reader.ts";
import { previousExited } from "../src/ops/previous.ts";

test("the station marks its writes as pending until they finish, including failures", () => {
  const store = Store.open(":memory:");
  try {
    const buffer = (store as any).backfillPriority;
    assert.ok(buffer instanceof SharedArrayBuffer);
    const priority = new Int32Array(buffer);
    store.db.exec("CREATE TABLE foreground_probe (value INTEGER)");
    store.db.function("priority_seen", () => Atomics.load(priority, 0));
    store.db.prepare("INSERT INTO foreground_probe VALUES (priority_seen())").run();
    store.db.exec("INSERT INTO foreground_probe VALUES (priority_seen())");
    assert.deepEqual(store.db.prepare("SELECT value FROM foreground_probe").all().map((r: any) => r.value), [1, 1]);
    assert.equal(Atomics.load(priority, 0), 0);
    store.db.exec("CREATE UNIQUE INDEX foreground_once ON foreground_probe (value) WHERE value = 2");
    store.db.prepare("INSERT INTO foreground_probe VALUES (2)").run();
    assert.throws(() => store.db.prepare("INSERT INTO foreground_probe VALUES (2)").run());
    assert.equal(Atomics.load(priority, 0), 0);
  } finally { store.close(); }
});

test("a read-only coverage check does not wait for the previous process", async () => {
  const dir = mkdtempSync(join(tmpdir(), "backfill-coverage-"));
  const path = join(dir, "stillfail.db"), store = Store.open(path);
  // (the chats not filled: the checker, not the readers' knowing all is complete, answers)
  store.db.exec("UPDATE usage_chat_progress SET done = 0");
  let finish!: () => void;
  const previousGone = new Promise<void>((resolve) => { finish = resolve; });
  const reader = new MinuteReader(path, { previousGone });
  try {
    await assert.rejects(reader.readyChats(null), /historical chat and card statistics are unavailable/, "answered before handover ends");
    finish();

    let finishOther!: () => void;
    const otherHandover = new Promise<void>((resolve) => { finishOther = resolve; });
    const stopping = new MinuteReader(path, { previousGone: otherHandover });
    const waiting = assert.rejects(stopping.readyChats(null), /station stopping/);
    await stopping.close();
    await waiting;
    finishOther();
    await Promise.resolve();
    assert.equal(stopping.running, false, "a stopped station starts no checker when handover later ends");
  } finally {
    await reader.close();
    store.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("only the stopped worker's backfill permit is released", () => {
  const priority = new Int32Array(new SharedArrayBuffer(8));
  assert.equal(takeBackfill(priority, 1), true);
  assert.equal(takeBackfill(priority, 2), false);
  releaseStoppedBackfill(priority.buffer as SharedArrayBuffer, 2);
  assert.equal(takeBackfill(priority, 2), false);
  releaseStoppedBackfill(priority.buffer as SharedArrayBuffer, 1);
  assert.equal(takeBackfill(priority, 2), true);
  giveBackfill(priority, 2);
  Atomics.store(priority, 0, 1);
  assert.equal(takeBackfill(priority, 1), false, "a queued foreground write takes priority");
});

test("backfills wait for the old process even after session takeover times out", async () => {
  let alive = true;
  let wake!: () => void;
  const exited = previousExited({ pid: 123, gone: Promise.resolve() }, () => alive, () => new Promise<void>((resolve) => { wake = resolve; }));
  await Promise.resolve();
  assert.equal(typeof wake, "function", "the old process is still checked after takeover is allowed");
  alive = false;
  wake();
  await exited;
});
