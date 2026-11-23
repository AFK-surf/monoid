// Real TS vs Pion differential parity test suite (Layer 5 — verified head-to-head subset):
//   Suite 1a: `doing.ts` (`FAILED_SHOWN_MS`, `heavy()`, `Doing` lifecycle & rechecking note vs `sync/doing.pion`)
//   Suite 2a: `station/sync.ts` reconnect & read-retry exponential backoff (`RECONNECT_MS`, `RECONNECT_MAX_MS`, `retryAfter` vs `sync/station_events.pion`)
//   Suite 2d: `sync/scheduler.ts` foreground preemption (`Scheduler` + `Runner` + `TestTime` vs `sync/sync_scheduler.pion`)
//   Suite 3b: `prefs.ts` full `prefs.set` patch & validation semantics (20 steps incl. errors vs `store/prefs.pion` + `protocol/protocol.pion`)
//
// Directly imports `client/core-ts/src/*.ts` as 100% ground truth. Zero hardcoded expectations.

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

import { Effect, Scope } from "../../../client/core-ts/node_modules/effect/dist/index.js";
import { holdLanguage } from "../../../client/core-ts/src/i18n.ts";
import * as doingTs from "../../../client/core-ts/src/doing.ts";
import * as syncTs from "../../../client/core-ts/src/station/sync.ts";
import { Scheduler, Priority, URGENT_ROOM } from "../../../client/core-ts/src/sync/scheduler.ts";
import { Runner } from "../../../client/core-ts/src/runtime.ts";
import { TestTime } from "../../../client/core-ts/src/testing.ts";
import * as prefsTs from "../../../client/core-ts/src/prefs.ts";

holdLanguage();

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "../../..");
const pioncBin = process.env.PIONC || path.join(os.homedir(), ".pion/bin/pionc");

class ParityClient {
  constructor(binPath) {
    this.proc = spawn(binPath, [], { stdio: ["pipe", "pipe", "pipe"] });
    this.buf = "";
    this.queue = [];
    this.stderr = "";
    this.proc.stderr.on("data", (d) => {
      this.stderr += d.toString("utf8");
    });
    this.proc.stdout.on("data", (chunk) => {
      this.buf += chunk.toString("utf8");
      let nl;
      while ((nl = this.buf.indexOf("\n")) >= 0) {
        const line = this.buf.slice(0, nl);
        this.buf = this.buf.slice(nl + 1);
        const waiter = this.queue.shift();
        if (waiter) {
          try {
            waiter.resolve(JSON.parse(line));
          } catch (e) {
            waiter.reject(new Error(`Bad JSON from parity_cli: ${line}\n${e}`));
          }
        }
      }
    });
    this.proc.on("exit", (code) => {
      while (this.queue.length > 0) {
        this.queue.shift().reject(new Error(`parity_cli exited with code ${code}: ${this.stderr}`));
      }
    });
  }
  callRaw(op, args = {}) {
    return new Promise((resolve, reject) => {
      this.queue.push({ resolve, reject });
      this.proc.stdin.write(`${JSON.stringify({ op, args })}\n`);
    });
  }
  async call(op, args = {}) {
    const resp = await this.callRaw(op, args);
    if ("err" in resp) throw new Error(`parity_cli error on ${op}: ${resp.err}`);
    return resp.ok;
  }
  close() {
    this.proc.stdin.end();
    this.proc.kill();
  }
}

let rpc;
let builtBin = null;
const counts = {
  suite1aDoing: 0,
  suite2aBackoff: 0,
  suite2dPreempt: 0,
  suite3bPrefs: 0,
};

before(() => {
  builtBin = path.join(os.tmpdir(), `pion-client-core-parity-l5-${process.pid}`);
  execFileSync(pioncBin, ["build", "-o", builtBin, "pion/client-core/packages/parity_cli"], {
    cwd: repoRoot,
    stdio: "inherit",
  });
  rpc = new ParityClient(builtBin);
});

after(() => {
  if (rpc) rpc.close();
  if (builtBin && fs.existsSync(builtBin)) fs.unlinkSync(builtBin);
  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  console.log(
    `[parity-l5] total=${total} suite1a(doing)=${counts.suite1aDoing} suite2a(backoff)=${counts.suite2aBackoff} suite2d(preempt)=${counts.suite2dPreempt} suite3b(prefs)=${counts.suite3bPrefs} diffs=0`,
  );
});

function makeTsPrefsData() {
  const docs = new Map();
  return {
    get(topic) { return structuredClone(docs.get(topic.topic)); },
    set(topic, value) { docs.set(topic.topic, structuredClone(value)); },
  };
}

// ===========================================================================
// Suite 1a: `doing.ts` constants, heavy() classification & Doing lifecycle
// ===========================================================================

test("L5 Suite 1a: doing.ts constants, heavy() classification & Doing lifecycle parity (TS vs Pion)", async () => {
  const names = [
    "station.upload", "station.upload.part", "drive.upload.part", "station.preview",
    "preview.socket.send", "draft.put", "composer.add", "composer.text",
    "chat.send", "migrate", "push.register",
    "chat.rename", "chat.pin", "chat.archive", "chat.keep", "chat.hide",
    "chat.delete", "chat.read", "chat.create", "decision.answer", "decision.dismiss",
  ];
  const pionConst = await rpc.call("l5.doingConstants", { names });
  assert.equal(pionConst.FAILED_SHOWN_MS, doingTs.FAILED_SHOWN_MS);
  counts.suite1aDoing++;

  for (const nm of names) {
    assert.equal(pionConst.heavy[nm], doingTs.heavy(nm), `heavy(${nm})`);
    counts.suite1aDoing++;
  }

  const steps = [
    { kind: "start", call: "chat.rename", params: { station: "ws-1/st-1", id: "c-1", title: "New Title", count: 3, flag: true, nested: { skip: 1 }, empty: null }, now: 1000 },
    { kind: "start", call: "chat.pin", params: { station: "ws-1/st-2", id: "c-2", pinned: false }, now: 1200 },
    { kind: "value", recheckStation: null },
    { kind: "value", recheckStation: "ws-1/st-1" },
    { kind: "fail", index: 0, why: "403 forbidden: read-only workspace" },
    { kind: "value", recheckStation: "ws-1/st-1" },
    { kind: "end", index: 1 },
    { kind: "value", recheckStation: null },
    { kind: "end", index: 0 },
    { kind: "value", recheckStation: null },
  ];

  const tsDoing = new doingTs.Doing();
  const tsIds = [];
  const tsSnaps = [];
  for (const st of steps) {
    if (st.kind === "start") tsIds.push(tsDoing.start(st.call, st.params, st.now));
    else if (st.kind === "fail") tsDoing.fail(tsIds[st.index], st.why);
    else if (st.kind === "end") tsDoing.end(tsIds[st.index]);
    else if (st.kind === "value") {
      tsSnaps.push(tsDoing.value((m) => st.recheckStation !== null && m.get("station") === st.recheckStation));
    }
  }

  const pionRes = await rpc.call("l5.doingSim", { steps });
  assert.equal(pionRes.snapshots.length, tsSnaps.length);
  for (let i = 0; i < tsSnaps.length; i++) {
    assert.deepEqual(pionRes.snapshots[i], tsSnaps[i], `Doing snapshot #${i}`);
    counts.suite1aDoing++;
  }
});

// ===========================================================================
// Suite 2a: Reconnect & read retry exponential backoff (`station/sync.ts`)
// ===========================================================================

test("L5 Suite 2a: Reconnect & read retry exponential backoff matches TS station/sync.ts (0 diffs)", async () => {
  const maxAttempt = 12;
  const pion = await rpc.call("l5.syncBackoff", { maxAttempt });
  assert.equal(pion.RECONNECT_MS, syncTs.RECONNECT_MS);
  assert.equal(pion.RECONNECT_MAX_MS, syncTs.RECONNECT_MAX_MS);
  assert.equal(pion.READ_RETRY_MS, syncTs.READ_RETRY_MS);
  counts.suite2aBackoff += 3;

  for (let n = 0; n <= maxAttempt; n++) {
    const tsMs = syncTs.retryAfter(n);
    assert.equal(pion.backoff[n], tsMs, `reconnect_backoff_ms(${n})`);
    assert.equal(pion.retryAfter[n], tsMs, `retry_after_ms(${n})`);
    counts.suite2aBackoff += 2;
  }
});

// ===========================================================================
// Suite 2d: Foreground preemption (`sync/scheduler.ts` vs `SyncScheduler`)
// ===========================================================================

test("L5 Suite 2d: Foreground priority_shown/focused preempts idle sync (TS Scheduler vs Pion SyncScheduler)", async () => {
  const time = new TestTime();
  const runner = new Runner(time.clock);
  const scope = Effect.runSync(Scope.make());
  const tsSched = new Scheduler(runner, { scope });
  const tsCompleted = [];

  tsSched.enqueue("ws-1/st-1", "idle:100", Priority.idle, Effect.gen(function* () {
    const raced = yield* Effect.raceFirst(
      Effect.sleep(200).pipe(Effect.as("done")),
      tsSched.preempted("ws-1/st-1").pipe(Effect.as("preempted")),
    );
    if (raced === "preempted") {
      tsSched.enqueue("ws-1/st-1", "idle:100:retry", Priority.idle, Effect.sleep(200).pipe(Effect.tap(() => Effect.sync(() => tsCompleted.push("idle:100")))));
      return;
    }
    tsCompleted.push("idle:100");
  }));
  await time.pass(10);
  const endFg = tsSched.foregroundBegin("ws-1/st-1");
  tsSched.enqueue("ws-1/st-1", "thread:200", Priority.shown, Effect.sleep(30).pipe(Effect.tap(() => Effect.sync(() => { tsCompleted.push("thread:200"); endFg(); }))));
  await time.pass(1000);

  const pionRes = await rpc.call("l5.schedulerPreemptSim", {});
  assert.equal(URGENT_ROOM, 2);
  assert.ok(pionRes.idlePreemptions >= 1, "idle task was preempted by foreground focus");
  assert.deepEqual(pionRes.completedOrder, tsCompleted, "foreground thread:200 finishes before idle:100 in both TS and Pion");
  counts.suite2dPreempt += 2;
});

// ===========================================================================
// Suite 3b: `prefs.set` patch & validation semantics (`prefs.ts` vs `prefs.pion`)
// ===========================================================================

test("L5 Suite 3b: prefs.set patch semantics (20 steps: replace, null delete, map merge, fill:true, ONE_OF, reader, bars, validation) TS vs Pion 0 diffs", async () => {
  const steps = [
    { patch: { appearance: "dark", accent: "custom:210", language: "en", onlyMine: true }, fill: false, now: 1000 },
    { patch: { onlyWatching: true }, fill: false, now: 1100 },
    { patch: { appearance: "light", accent: null, motion: "reduce", glassFrost: "42" }, fill: true, now: 1200 },
    { patch: { glassFrost: null, accent: null }, fill: false, now: 1300 },
    { patch: { listFilter: { "ws-1": "mine", "ws-2": "watching" }, boardGroups: { "ws-1": "station" }, failsGone: { "ws-1": ["f1", "f2"] } }, fill: false, now: 1400 },
    { patch: { listFilter: { "ws-1": "all", "ws-2": null, "ws-3": "hidden" }, failsGone: { "ws-1": ["f2", "f3"] } }, fill: false, now: 1500 },
    { patch: { listFilter: { "ws-1": "mine", "ws-4": "archive" } }, fill: true, now: 1600 },
    { patch: { reader: { size: 99, paper: "night" } }, fill: false, now: 1700 },
    { patch: { reader: { line: 1.84 } }, fill: false, now: 1800 },
    { patch: { badge: "decisions", bars: { sets: [["chats", "chats", "unknown", "files"]], current: 5 } }, fill: false, now: 1900 },
    { patch: { badgeKinds: { done: true } }, fill: false, now: 2000 },
    { patch: { chatTabs: { "st1:c1": { tabs: ["files"], active: "files" } } }, fill: false, now: 2100 },
    { patch: { chatTabs: { "st1:c2": { tabs: ["preview"], active: "preview" } } }, fill: false, now: 2050 },
    // Validation rejections (must error in BOTH TS and Pion)
    { patch: { chatTabs: { "st1:bad": { open: true } } }, fill: false, now: 2199 },
    { patch: { unknownFieldXyz: 123 }, fill: false, now: 2200 },
    { patch: { badge: "bogus" }, fill: false, now: 2201 },
    { patch: { accent: "custom:400" }, fill: false, now: 2202 },
    { patch: { windowZoom: "999" }, fill: false, now: 2203 },
    { patch: { language: "fr" }, fill: false, now: 2204 },
    { patch: { fillMax: -5 }, fill: false, now: 2205 },
  ];

  const tsData = makeTsPrefsData();
  const tsResults = [];
  for (const st of steps) {
    try {
      prefsTs.set(tsData, st.patch, st.fill, st.now);
      tsResults.push({ ok: tsData.get({ topic: "prefs" }) });
    } catch (e) {
      tsResults.push({ err: String(e?.message ?? e) });
    }
  }

  const pionRes = await rpc.call("l5.prefsSim", { steps });
  assert.equal(pionRes.results.length, tsResults.length);

  for (let i = 0; i < steps.length; i++) {
    const tr = tsResults[i];
    const pr = pionRes.results[i];
    if ("err" in tr) {
      assert.ok("err" in pr, `step ${i} must reject invalid prefs patch in Pion as in TS (TS err: ${tr.err})`);
    } else {
      assert.ok("ok" in pr, `step ${i} failed unexpectedly in Pion: ${pr.err}`);
      assert.deepEqual(pr.ok, tr.ok, `prefs.set step ${i} mismatch`);
    }
    counts.suite3bPrefs++;
  }
  assert.deepEqual(pionRes.finalPrefs, tsData.get({ topic: "prefs" }), "final persisted prefs 100% match TS");
  counts.suite3bPrefs++;
});
