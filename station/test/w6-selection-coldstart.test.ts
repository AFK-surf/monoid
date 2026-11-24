import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  mbReaderBinary,
  pionBinary,
  resetReaderSelectionStateForTest,
  resolveReaderSelection,
  resolveReaderSelectionAsync,
  setPionProbeRunnerForTest,
  warmPionProbeForConfig,
} from "../src/read/mb-reader.ts";
import type { ReaderSelectConfig } from "../src/read/reader-select.ts";
import { inProgram } from "../src/replica/carry.ts";
import { takeBackSoon } from "../src/replica/restore.ts";
import { ProgramRunner } from "../src/replica/runner.ts";
import { Search } from "../src/search/search.ts";
import { LiveLocator } from "../src/sessions/live-locator.ts";
import { Store } from "../src/store/store.ts";
import { UsageCounter } from "../src/usage/counter.ts";

function resolveDual(t: { skip: (msg: string) => void }): { mb: string; pion: string } | null {
  const realMb = mbReaderBinary();
  const explicitPion = process.env.STILLFAIL_PION_READER?.trim();
  const realPion = pionBinary();

  if (realMb === null) {
    if (process.env.CI) assert.fail("stillfail-reader binary is required in CI");
    t.skip("stillfail-reader not built here");
    return null;
  }
  if (explicitPion) {
    assert.ok(realPion !== null, `STILLFAIL_PION_READER is set (${explicitPion}) but resolved to null`);
  } else if (realPion === null) {
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return null;
  }
  assert.notEqual(realpathSync(realMb), realpathSync(realPion), "MB and Pion binaries must be distinct");
  return { mb: realMb, pion: realPion };
}

function makeControlledProbe() {
  let calls = 0;
  let release!: (modes: ReadonlySet<string> | null) => void;
  const started = new Promise<void>((res) => {
    setPionProbeRunnerForTest(async () => {
      calls++;
      res();
      return new Promise<ReadonlySet<string> | null>((r) => {
        release = r;
      });
    });
  });
  return {
    get calls() { return calls; },
    started,
    release: (modes: ReadonlySet<string> | null) => release(modes),
  };
}

test("zero probe on default mb, explicit binary, baseline modes, and restore without ready.json", async (t) => {
  const bins = resolveDual(t);
  if (!bins) return;
  const { mb } = bins;
  resetReaderSelectionStateForTest();
  let probeCalls = 0;
  setPionProbeRunnerForTest(async () => {
    probeCalls++;
    return new Set(["footprint", "packed", "memory", "live-locator"]);
  });
  const dir = mkdtempSync(join(tmpdir(), "w6-zero-probe-"));
  try {
    // 1. Default mb -> 0 probe
    assert.equal(resolveReaderSelection("live-locator", { env: {} }).engine, "mb");
    assert.equal(probeCalls, 0);

    // 2. Explicit binary -> 0 probe
    assert.equal(resolveReaderSelection("live-locator", { binary: mb, config: { readers: { "live-locator": "pion" } }, env: {} }).primaryBinary, mb);
    assert.equal(probeCalls, 0);

    // 3. Baseline modes (footprint/packed/memory) -> 0 probe
    for (const m of ["footprint", "packed", "memory"] as const) {
      assert.equal(resolveReaderSelection(m, { config: { readers: { [m]: "pion" } }, env: {} }).engine, "pion");
    }
    assert.equal(probeCalls, 0);

    // 4. warmPionProbeForConfig with default or baseline-only -> 0 probe
    await warmPionProbeForConfig(undefined, {});
    await warmPionProbeForConfig({ readers: { footprint: "pion", packed: "pion", memory: "pion" } }, {});
    assert.equal(probeCalls, 0);

    // 5. takeBackSoon without ready.json -> returns null with 0 probe
    const res = await takeBackSoon(dir, join(dir, "stillfail.db"), Date.now(), undefined, {
      readers: { readers: { "replica-restore": "pion" } },
    });
    assert.equal(res, null);
    assert.equal(probeCalls, 0);
  } finally {
    rmSync(dir, { recursive: true, force: true });
    resetReaderSelectionStateForTest();
  }
});

test("warmPionProbeForConfig probes once when an implemented non-baseline non-restore mode requests pion", async (t) => {
  if (!resolveDual(t)) return;
  resetReaderSelectionStateForTest();
  let probeCalls = 0;
  setPionProbeRunnerForTest(async () => {
    probeCalls++;
    return new Set(["footprint", "packed", "memory", "live-locator"]);
  });
  try {
    await warmPionProbeForConfig({ readers: { "live-locator": "pion" } }, {});
    assert.equal(probeCalls, 1);
    const sel = resolveReaderSelection("live-locator", { config: { readers: { "live-locator": "pion" } }, env: {} });
    assert.equal(sel.engine, "pion");
    assert.equal(probeCalls, 1, "cached after warm");
  } finally {
    resetReaderSelectionStateForTest();
  }
});

test("hot-reload + direct construction of LiveLocator hits Pion on first spawn while waiting on pending probe, and never late-spawns after close", async (t) => {
  const bins = resolveDual(t);
  if (!bins) return;
  const { pion } = bins;
  resetReaderSelectionStateForTest();
  const dir = mkdtempSync(join(tmpdir(), "w6-cold-locator-"));
  const store = Store.open(join(dir, "stillfail.db"));
  store.insertSession({
    key: "k1", connect: "ember", runtime: "agy", profile: "p1", workspace: dir, token: "t", createdAt: 1, lastActiveAt: 1, ws: "mine",
  });
  let cfg: ReaderSelectConfig = { readers: { "live-locator": "mb" } };
  const locator = new LiveLocator(dir, (k) => store.getSession(k), () => [], undefined, undefined, () => cfg);
  try {
    const ctrl = makeControlledProbe();
    // Hot-reload to pion before first lookup
    cfg = { readers: { "live-locator": "pion" } };
    const p = locator.locate("k1");
    await ctrl.started;
    assert.equal(ctrl.calls, 1);
    assert.equal(locator.running, false, "must await pending probe rather than eagerly spawning MB");
    ctrl.release(new Set(["footprint", "packed", "memory", "live-locator"]));
    assert.equal(await p, null);
    assert.equal(locator.running, true);
    assert.equal(resolveReaderSelection("live-locator", { config: cfg }).primaryBinary, pion);

    // Now test close() while probe is pending: must NOT late-spawn after probe resolves!
    await locator.close();
    resetReaderSelectionStateForTest();
    const ctrl2 = makeControlledProbe();
    const loc2 = new LiveLocator(dir, (k) => store.getSession(k), () => [], undefined, undefined, () => cfg);
    const p2 = loc2.locate("k1");
    await ctrl2.started;
    const closeP = loc2.close();
    await assert.rejects(p2, /cancelled/);
    ctrl2.release(new Set(["footprint", "packed", "memory", "live-locator"]));
    await closeP;
    assert.equal(loc2.running, false, "must not late-spawn after close()");
  } finally {
    await locator.close();
    store.close();
    rmSync(dir, { recursive: true, force: true });
    resetReaderSelectionStateForTest();
  }
});

test("resolveReaderSelectionAsync: two concurrent callers share pending probe; aborting A rejects immediately with 'called off' without cancelling probe for B", async (t) => {
  const bins = resolveDual(t);
  if (!bins) return;
  const { pion } = bins;
  resetReaderSelectionStateForTest();
  try {
    const ctrl = makeControlledProbe();
    const acA = new AbortController();
    const acB = new AbortController();
    const opts = { config: { readers: { "live-locator": "pion" } }, env: {} };

    const pA = resolveReaderSelectionAsync("live-locator", opts, acA.signal);
    const pB = resolveReaderSelectionAsync("live-locator", opts, acB.signal);
    await ctrl.started;
    assert.equal(ctrl.calls, 1, "shared single-flight probe");

    // Abort A before probe releases -> A rejects immediately with "called off"
    acA.abort();
    await assert.rejects(pA, /called off/);

    // Release probe -> B succeeds with Pion!
    ctrl.release(new Set(["footprint", "packed", "memory", "live-locator"]));
    const resB = await pB;
    assert.equal(resB.engine, "pion");
    assert.equal(resB.primaryBinary, pion);
  } finally {
    resetReaderSelectionStateForTest();
  }
});

test("failed probe enters cooldown with reason pion-probe-failed and unsupported mode falls back to mb cleanly", async (t) => {
  const bins = resolveDual(t);
  if (!bins) return;
  const { mb } = bins;
  resetReaderSelectionStateForTest();
  try {
    // 1. Failed probe -> cooldown -> mb with reason pion-probe-failed
    let failCalls = 0;
    setPionProbeRunnerForTest(async () => {
      failCalls++;
      return null;
    });
    const resFail = await resolveReaderSelectionAsync("live-locator", {
      config: { readers: { "live-locator": "pion" } },
      env: {},
    });
    assert.equal(resFail.engine, "mb");
    assert.equal(resFail.primaryBinary, mb);
    assert.equal(resFail.selection.reason, "pion-probe-failed");
    assert.equal(failCalls, 1);

    // Subsequent call during cooldown does not re-probe
    const resCool = resolveReaderSelection("live-locator", {
      config: { readers: { "live-locator": "pion" } },
      env: {},
    });
    assert.equal(resCool.engine, "mb");
    assert.equal(resCool.selection.reason, "pion-probe-failed");
    assert.equal(failCalls, 1);

    // 2. Old binary missing live-locator in modes -> pion-binary-unsupported-mode
    resetReaderSelectionStateForTest();
    setPionProbeRunnerForTest(async () => new Set(["footprint", "packed", "memory"]));
    const resOld = await resolveReaderSelectionAsync("live-locator", {
      config: { readers: { "live-locator": "pion" } },
      env: {},
    });
    assert.equal(resOld.engine, "mb");
    assert.equal(resOld.selection.reason, "pion-binary-unsupported-mode");
  } finally {
    resetReaderSelectionStateForTest();
  }
});

test("DI wiring: UsageCounter explicit mb:null throws, direct Search/UsageCounter/ProgramRunner/carry accept readers getter cleanly", async (t) => {
  if (!resolveDual(t)) return;
  resetReaderSelectionStateForTest();
  const dir = mkdtempSync(join(tmpdir(), "w6-di-wiring-"));
  const dbPath = join(dir, "stillfail.db");
  const store = Store.open(dbPath);
  try {
    // UsageCounter explicit mb: null must preserve missing-binary error
    assert.throws(
      () => new UsageCounter({ store, config: () => ({ dataDir: dir, profiles: [] }), mb: null }),
      /MoonBit reader/,
    );
    // UsageCounter without mb accepts readers getter
    const uc = new UsageCounter({
      store,
      config: () => ({ dataDir: dir, profiles: [] }),
      readers: () => ({ readers: { "usage-counter": "mb" } }),
    });
    await uc.stop();

    // carry inProgram explicit null rejects with original error
    await assert.rejects(
      () => inProgram({ op: "preview", dataDir: dir, db: dbPath, ws: "w", home: true }, undefined, null),
      /stillfail-reader/,
    );

    // carry inProgram pre-aborted signal rejects with called off
    const ac = new AbortController();
    ac.abort();
    await assert.rejects(
      () => inProgram({ op: "preview", dataDir: dir, db: dbPath, ws: "w", home: true }, ac.signal),
      /called off/,
    );

    // Direct Search & ProgramRunner accept readers getter cleanly
    const search = new Search({ data: dir, backfill: { readers: () => ({ readers: { search: "mb" } }) } });
    await search.stop();

    const runner = new ProgramRunner({
      db: dbPath,
      replica: join(dir, "replica"),
      dataDir: dir,
      origin: "st1",
      readers: () => ({ readers: { "replica-export": "mb" } }),
    });
    await runner.close();

    // Two stations with distinct per-station readers configs remain completely isolated (zero globals)
    const cfgA: ReaderSelectConfig = { readers: { "live-locator": "mb" } };
    const cfgB: ReaderSelectConfig = { readers: { "live-locator": "pion" } };
    setPionProbeRunnerForTest(async () => new Set(["footprint", "packed", "memory", "live-locator"]));
    const selA = await resolveReaderSelectionAsync("live-locator", { config: cfgA, env: {} });
    const selB = await resolveReaderSelectionAsync("live-locator", { config: cfgB, env: {} });
    assert.equal(selA.engine, "mb");
    assert.equal(selB.engine, "pion");
  } finally {
    store.close();
    rmSync(dir, { recursive: true, force: true });
    resetReaderSelectionStateForTest();
  }
});
