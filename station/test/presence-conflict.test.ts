// Two stations on one key (a copy of a station's data on another machine): still.fail cloud closes each one's presence
// socket as the other's connects (4000 replaced), and before, each connected again within a second and replaced the
// other, the log full of it and `stillfail status` saying all was normal (2026-11-16). Now three sockets replaced in a
// row before they held a heartbeat are another station on this key: said once, presence.json and status say it, and
// it waits a minute before it connects again; a socket that holds a heartbeat ends it (not its open: the other would
// replace it a moment later).
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Clock, Duration, Effect, Exit, Fiber, Scope, Stream, SubscriptionRef } from "effect";
import { TestClock } from "effect/testing";
import { enroll, status } from "../src/cli.ts";
import { loadKey } from "../src/cloud/key.ts";
import { makeControlPlane } from "../src/cloud/plane.ts";
import * as presenceTs from "../src/cloud/presence.ts";
import { Cloud } from "../src/cloud/state.ts";
import { FakeControlPlane } from "./fake-control-plane.ts";

/// (as presence.ts says them; written out so this file reads on the code from before them, where it fails as it should)
const CONFLICT_BACKOFF_MS = 60_000;
const REPLACED_IN_A_ROW = 3;

/// What comes over real sockets has no event here: looked at every 5 ms, no deadline.
const until = async (what: () => boolean) => {
  while (!what()) await new Promise((r) => setTimeout(r, 5));
};

/// A TestClock whose waits are said as they begin: `asleep(ms)` takes the next one begun, failing where it is not of
/// `ms`; `adjust` moves the clock on.
function testClock() {
  const scope = Effect.runSync(Scope.make());
  const clock = Effect.runSync(Scope.provide(TestClock.make(), scope));
  const begun: number[] = [];
  let heard: (() => void) | null = null;
  const wrapped: Clock.Clock = {
    ...clock,
    sleep: (d) =>
      Effect.suspend(() => {
        begun.push(Duration.toMillis(d));
        heard?.();
        return clock.sleep(d);
      }),
  };
  let seen = 0;
  const asleep = async (ms: number, what: string) => {
    while (seen === begun.length) await new Promise<void>((r) => (heard = r));
    heard = null;
    assert.equal(begun[seen++], ms, what);
    for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
  };
  return { clock: wrapped, asleep, adjust: (ms: number) => Effect.runPromise(clock.adjust(ms)), close: () => Effect.runPromise(Scope.close(scope, Exit.void)) };
}

test("a station whose sockets are replaced again and again by another on its key says so, waits a minute, and is normal once a socket holds", async (t) => {
  const fake = new FakeControlPlane({ provider: "stillfail" });
  const origin = await fake.start();
  const data = mkdtempSync(join(tmpdir(), "presence-conflict-"));
  const quiet = console.log;
  console.log = () => {};
  try {
    await enroll(data, origin, "tok", "stillfail");
  } finally {
    console.log = quiet;
  }
  const state = new Cloud(data);
  const key = loadKey(data);
  const up = Effect.runSync(SubscriptionRef.make(true));
  const { spec } = makeControlPlane({ state, changes: Stream.never, key, up });
  // The heartbeats the test gives: one beat of each socket's when it says.
  const beats: (() => void)[] = [];
  const every = (_ms: number, f: () => void) => {
    beats.push(f);
    return () => {};
  };
  const time = testClock();
  const fiber = Effect.runFork(presenceTs.presence({ cloud: { state, changes: Stream.never }, key, up, spec, every }).pipe(Effect.provideService(Clock.Clock, time.clock)));
  t.after(async () => {
    await Effect.runPromise(Fiber.interrupt(fiber));
    await time.close();
    state.close();
    await fake.close();
    rmSync(data, { recursive: true, force: true });
  });
  const presenceJson = () => {
    try {
      return JSON.parse(readFileSync(join(data, "run", "presence.json"), "utf8"));
    } catch {
      return null;
    }
  };
  // Running, as `stillfail status` reads it: station.json naming this process.
  mkdirSync(join(data, "run"), { recursive: true });
  writeFileSync(join(data, "run", "station.json"), JSON.stringify({ pid: process.pid, version: "0.1.2" }));
  const working = () => status(data).split("\n").at(-1)!;

  fake.replacing = true;
  // Replaced once and twice: a station's own sockets do as much (a new one, a handover's).
  await time.asleep(1000, "after the first socket replaced");
  assert.notEqual(presenceJson()?.conflict, true);
  await time.adjust(1000);
  await time.asleep(2000, "after the second");
  assert.notEqual(presenceJson()?.conflict, true);
  await time.adjust(2000);
  // The third in a row: another station uses this key. A minute, not 4 s.
  await time.asleep(CONFLICT_BACKOFF_MS, `after ${REPLACED_IN_A_ROW} replaced in a row: another station on this key`);
  assert.equal(fake.sockets.length, 3);
  // (written off the main thread, in the order said)
  await until(() => presenceJson()?.conflict === true);
  assert.equal(presenceJson()?.online, false);
  assert.match(presenceJson()?.error, /another station is using this station's key/);
  assert.match(working(), /^工作：异常（另一台机器或进程正在用这个 station 的同一份密钥/);
  // Replaced again: a minute again.
  await time.adjust(CONFLICT_BACKOFF_MS);
  await time.asleep(CONFLICT_BACKOFF_MS, "replaced once more while the other runs");
  assert.equal(fake.sockets.length, 4);
  // The other stopped: the next socket opens, and is not taken for normal before it held.
  fake.replacing = false;
  await time.adjust(CONFLICT_BACKOFF_MS);
  await until(() => fake.sockets.length === 5 && presenceJson()?.online === true && beats.length === 5);
  assert.equal(presenceJson()?.conflict, true, "open, but not yet held");
  assert.match(working(), /^工作：异常（另一台机器或进程正在用这个 station 的同一份密钥/);
  // Its first heartbeat answered: normal.
  beats[4]!();
  await until(() => presenceJson()?.conflict !== true);
  assert.equal(presenceJson()?.online, true);
  assert.equal(presenceJson()?.error, null);
  assert.equal(working(), "工作：正常（已连接 Slack，运行 agent 和任务）");
});

test("a station's own sockets replaced, or ones that held, are no conflict", () => {
  const told: boolean[] = [];
  assert.equal(presenceTs.CONFLICT_BACKOFF_MS, CONFLICT_BACKOFF_MS);
  assert.equal(presenceTs.REPLACED_IN_A_ROW, REPLACED_IN_A_ROW);
  const r = new presenceTs.Replaced((c: boolean) => told.push(c));
  // A new socket of its own replacing the one before, twice (a handover): no conflict.
  r.ended(4000, false);
  r.ended(4000, false);
  r.ended(1006, false);
  r.ended(4000, false);
  r.ended(4000, false);
  assert.equal(r.conflict, false);
  // One that held a heartbeat before it was replaced starts the count again.
  r.ended(4000, true);
  r.ended(4000, false);
  r.ended(4000, false);
  assert.equal(r.conflict, false);
  // A socket that broke (no code) neither counts nor starts it again.
  r.ended(null, false);
  r.ended(4000, false);
  assert.equal(r.conflict, true);
  assert.deepEqual(told, [true]);
  // Said once while it lasts.
  r.ended(4000, false);
  assert.deepEqual(told, [true]);
  r.steady();
  assert.equal(r.conflict, false);
  assert.deepEqual(told, [true, false]);
});
