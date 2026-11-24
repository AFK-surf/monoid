import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  MbProcess,
  mbReaderBinary,
  pionBinary,
  probePionSupportedModes,
  resetReaderSelectionStateForTest,
  resolveReaderSelection,
  resolveReaderSelectionAsync,
  setPionProbeRunnerForTest,
  warmPionProbeForConfig,
} from "../src/read/mb-reader.ts";
import { READER_MODES, type ReaderSelectConfig } from "../src/read/reader-select.ts";
import { inProgram, previewSoon, sizesSoon } from "../src/replica/carry.ts";
import { readyFile, takeBackSoon } from "../src/replica/restore.ts";
import { ProgramRunner } from "../src/replica/runner.ts";
import { Search } from "../src/search/search.ts";
import { LiveLocator } from "../src/sessions/live-locator.ts";
import { Store } from "../src/store/store.ts";
import { UsageCounter } from "../src/usage/counter.ts";
import { MbUsageCounter } from "../src/usage/counter-mb.ts";

function resolveDual(t: { skip: (msg: string) => void }): { mb: string; pion: string } | null {
  const realMb = mbReaderBinary();
  const explicitPion = process.env.STILLFAIL_PION_READER?.trim();
  const requireDual = process.env.STILLFAIL_REQUIRE_DUAL_READER === "1";
  const realPion = pionBinary();

  if (realMb === null) {
    if (process.env.CI || requireDual) assert.fail("stillfail-reader binary is required in CI");
    t.skip("stillfail-reader not built here");
    return null;
  }
  if (explicitPion || requireDual) {
    assert.ok(realPion !== null, `STILLFAIL_PION_READER is required (${explicitPion ?? "unset"}) but resolved to null`);
  } else if (realPion === null) {
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return null;
  }
  assert.notEqual(realpathSync(realMb), realpathSync(realPion), "MB and Pion binaries must be distinct");
  return { mb: realMb, pion: realPion };
}

function makeRecordingWrapper(dir: string, name: string, realBin: string, logFile: string): string {
  const wrapper = join(dir, name);
  const sh = [
    "#!/bin/sh",
    `printf '%s %s\\n' "$$" "$*" >> ${JSON.stringify(logFile)}`,
    `exec ${JSON.stringify(realBin)} "$@"`,
    "",
  ].join("\n");
  writeFileSync(wrapper, sh, "utf8");
  chmodSync(wrapper, 0o755);
  return wrapper;
}

function readSpawns(logFile: string): string[] {
  if (!existsSync(logFile)) return [];
  return readFileSync(logFile, "utf8").split("\n").map((s) => s.trim()).filter(Boolean);
}

async function withEnv<T>(overrides: Record<string, string | undefined>, fn: () => Promise<T>): Promise<T> {
  const saved = new Map<string, string | undefined>();
  for (const [k, v] of Object.entries(overrides)) {
    saved.set(k, process.env[k]);
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  resetReaderSelectionStateForTest();
  try {
    return await fn();
  } finally {
    for (const [k, v] of saved) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    resetReaderSelectionStateForTest();
  }
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

test("hot-reload + direct construction of LiveLocator actually spawns Pion wrapper on first spawn, and never late-spawns after close", async (t) => {
  const bins = resolveDual(t);
  if (!bins) return;
  const { mb, pion } = bins;
  const dir = mkdtempSync(join(tmpdir(), "w6-cold-locator-"));
  const mbLog = join(dir, "mb.log");
  const pionLog = join(dir, "pion.log");
  const mbWrap = makeRecordingWrapper(dir, "mb-wrap.sh", mb, mbLog);
  const pionWrap = makeRecordingWrapper(dir, "pion-wrap.sh", pion, pionLog);

  await withEnv({ STILLFAIL_MB_READER: mbWrap, STILLFAIL_PION_READER: pionWrap }, async () => {
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
      assert.equal(readSpawns(mbLog).length, 0, "must NOT spawn MB while probe is pending");
      ctrl.release(new Set(["footprint", "packed", "memory", "live-locator"]));
      assert.equal(await p, null);
      assert.equal(locator.running, true);
      assert.equal(
        readSpawns(pionLog).filter((l) => l.includes("--builder live-locator")).length,
        1,
        "first spawn must actually exec Pion wrapper",
      );
      assert.equal(readSpawns(mbLog).length, 0, "MB wrapper must remain unused");

      // Now test close() while probe is pending: await probe resolution + setImmediate and assert 0 late spawns!
      await locator.close();
      resetReaderSelectionStateForTest();
      const pionLog2 = join(dir, "pion2.log");
      const pionWrap2 = makeRecordingWrapper(dir, "pion-wrap2.sh", pion, pionLog2);
      process.env.STILLFAIL_PION_READER = pionWrap2;
      const ctrl2 = makeControlledProbe();
      const loc2 = new LiveLocator(dir, (k) => store.getSession(k), () => [], undefined, undefined, () => cfg);
      const p2 = loc2.locate("k1");
      await ctrl2.started;
      const closeP = loc2.close();
      await assert.rejects(p2, /cancelled/);
      ctrl2.release(new Set(["footprint", "packed", "memory", "live-locator"]));
      await closeP;
      await probePionSupportedModes(pionWrap2);
      await new Promise((r) => setImmediate(r));
      assert.equal(loc2.running, false, "must not late-spawn after close()");
      assert.equal(readSpawns(pionLog2).filter((l) => l.includes("--builder live-locator")).length, 0, "0 late --builder spawns after close()");
    } finally {
      await locator.close();
      store.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

test("Pion-only cold start (no MB binary on disk) succeeds via resolveReaderSelectionAsync and LiveLocator without throwing missing-MB", async (t) => {
  const bins = resolveDual(t);
  if (!bins) return;
  const { pion } = bins;
  const dir = mkdtempSync(join(tmpdir(), "w6-pion-only-"));
  const pionLog = join(dir, "pion-only.log");
  const pionWrap = makeRecordingWrapper(dir, "pion-wrap.sh", pion, pionLog);
  const missingMb = join(dir, "does-not-exist-stillfail-reader");

  await withEnv({ STILLFAIL_MB_READER: missingMb, STILLFAIL_PION_READER: pionWrap }, async () => {
    const store = Store.open(join(dir, "stillfail.db"));
    store.insertSession({
      key: "k-only", connect: "ember", runtime: "agy", profile: "p1", workspace: dir, token: "t", createdAt: 1, lastActiveAt: 1, ws: "mine",
    });
    const cfg: ReaderSelectConfig = { readers: { "live-locator": "pion" } };
    const locator = new LiveLocator(dir, (k) => store.getSession(k), () => [], undefined, undefined, () => cfg);
    try {
      assert.equal(mbReaderBinary(), null, "MB binary must be absent for Pion-only test");
      // 1. Direct resolveReaderSelectionAsync succeeds on cold probe without MB binary
      const sel = await resolveReaderSelectionAsync("live-locator", { config: cfg, env: {} });
      assert.equal(sel.engine, "pion");
      assert.equal(sel.primaryBinary, pionWrap);

      // 2. Cold LiveLocator (reset cache so probe is pending again) succeeds and spawns Pion wrapper!
      resetReaderSelectionStateForTest();
      assert.equal(await locator.locate("k-only"), null);
      assert.equal(
        readSpawns(pionLog).filter((l) => l.includes("--builder live-locator")).length,
        1,
        "Pion-only LiveLocator must spawn Pion wrapper directly",
      );
    } finally {
      await locator.close();
      store.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

test("resolveReaderSelectionAsync & carry: two concurrent callers share pending probe; aborting A rejects immediately with 'called off' while B actually spawns child; post-probe spawn failure rejects cleanly", async (t) => {
  const bins = resolveDual(t);
  if (!bins) return;
  const { mb, pion } = bins;
  const dir = mkdtempSync(join(tmpdir(), "w6-carry-async-"));
  const dbPath = join(dir, "stillfail.db");
  const store = Store.open(dbPath);
  const mbLog = join(dir, "mb.log");
  const pionLog = join(dir, "pion.log");
  const mbWrap = makeRecordingWrapper(dir, "mb-wrap.sh", mb, mbLog);
  const pionWrap = makeRecordingWrapper(dir, "pion-wrap.sh", pion, pionLog);

  await withEnv({ STILLFAIL_MB_READER: mbWrap, STILLFAIL_PION_READER: pionWrap }, async () => {
    try {
      // 1. resolveReaderSelectionAsync shared probe + abort A without cancelling B
      const ctrl = makeControlledProbe();
      const acA = new AbortController();
      const acB = new AbortController();
      const opts = { config: { readers: { "live-locator": "pion" } }, env: {} };

      const pA = resolveReaderSelectionAsync("live-locator", opts, acA.signal);
      const pB = resolveReaderSelectionAsync("live-locator", opts, acB.signal);
      await ctrl.started;
      assert.equal(ctrl.calls, 1, "shared single-flight probe");

      acA.abort();
      await assert.rejects(pA, /called off/);

      ctrl.release(new Set(["footprint", "packed", "memory", "live-locator"]));
      const resB = await pB;
      assert.equal(resB.engine, "pion");
      assert.equal(resB.primaryBinary, pionWrap);

      // 2. Two concurrent `carry` (`previewSoon`) calls sharing a pending probe:
      //    Temporarily mark `replica-carry` implemented inside test (restored in finally) to exercise
      //    real pending-probe -> abort A -> B spawns real binary without changing production 30/40 table!
      resetReaderSelectionStateForTest();
      const origImpl = READER_MODES["replica-carry"].pionImplemented;
      (READER_MODES["replica-carry"] as { pionImplemented: boolean }).pionImplemented = true;
      try {
        const ctrlCarry = makeControlledProbe();
        const acCarryA = new AbortController();
        const carryCfg: ReaderSelectConfig = { readers: { "replica-carry": "pion" } };
        const carryA = inProgram<{ chats: number }>({ op: "preview", dataDir: dir, db: dbPath, ws: "w", home: true }, acCarryA.signal, undefined, carryCfg);
        const carryB = previewSoon(dir, dbPath, "w", true, carryCfg);
        await ctrlCarry.started;
        assert.equal(ctrlCarry.calls, 1, "two carry calls share one probe");

        acCarryA.abort();
        await assert.rejects(carryA, /called off/);

        // Release probe without replica-carry -> B falls back to MB wrapper and actually executes preview!
        ctrlCarry.release(new Set(["footprint", "packed", "memory", "live-locator"]));
        const preview = await carryB;
        assert.equal(preview.chats, 0);
        assert.equal(
          readSpawns(mbLog).filter((l) => l.includes("--builder replica-carry")).length,
          1,
          "only carry B (not aborted A) should spawn --builder replica-carry",
        );

        // 3. Post-probe spawn/postMessage failure in carry rejects cleanly (never hangs!)
        resetReaderSelectionStateForTest();
        const ctrlErr = makeControlledProbe();
        const origPost = MbProcess.prototype.postMessage;
        MbProcess.prototype.postMessage = () => {
          throw new Error("simulated postMessage boom");
        };
        try {
          const failingCarry = inProgram({ op: "preview", dataDir: dir, db: dbPath, ws: "w", home: true }, undefined, undefined, carryCfg);
          await ctrlErr.started;
          ctrlErr.release(new Set(["footprint", "packed", "memory", "live-locator"]));
          await assert.rejects(failingCarry, /simulated postMessage boom/);
        } finally {
          MbProcess.prototype.postMessage = origPost;
        }
      } finally {
        (READER_MODES["replica-carry"] as { pionImplemented: boolean }).pionImplemented = origImpl;
      }
    } finally {
      store.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

test("failed probe enters cooldown with reason pion-probe-failed and unsupported mode falls back to mb cleanly", async (t) => {
  const bins = resolveDual(t);
  if (!bins) return;
  const { mb } = bins;
  resetReaderSelectionStateForTest();
  try {
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

    const resCool = resolveReaderSelection("live-locator", {
      config: { readers: { "live-locator": "pion" } },
      env: {},
    });
    assert.equal(resCool.engine, "mb");
    assert.equal(resCool.selection.reason, "pion-probe-failed");
    assert.equal(failCalls, 1);

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

test("all 6 production DI entrypoints actually spawn recorded wrappers + cold restore settings.raw() shape + dual-station isolation", async (t) => {
  const bins = resolveDual(t);
  if (!bins) return;
  const { mb, pion } = bins;
  const dir = mkdtempSync(join(tmpdir(), "w6-di-wiring-"));
  const dbPath = join(dir, "stillfail.db");
  const store = Store.open(dbPath);
  const mbLog = join(dir, "mb.log");
  const pionLog = join(dir, "pion.log");
  const mbWrap = makeRecordingWrapper(dir, "mb-wrap.sh", mb, mbLog);
  const pionWrap = makeRecordingWrapper(dir, "pion-wrap.sh", pion, pionLog);

  await withEnv({ STILLFAIL_MB_READER: mbWrap, STILLFAIL_PION_READER: pionWrap }, async () => {
    try {
      // 1. UsageCounter explicit mb: null must preserve missing-binary error
      assert.throws(
        () => new UsageCounter({ store, config: () => ({ dataDir: dir, profiles: [] }), mb: null }),
        /MoonBit reader/,
      );
      // 2. MbUsageCounter actually spawns `--builder usage-counter` via readers getter
      const mbCounter = new MbUsageCounter(undefined, dbPath, {
        readers: () => ({ readers: { "usage-counter": "mb" } }),
      });
      const ucAns = await mbCounter.read({
        only: [],
        started: Date.now(),
        last: 0,
        dataDir: dir,
        homes: [],
        hints: { elsewhere: [], rollouts: [], said: [] },
      });
      assert.equal(ucAns.added, 0);
      await mbCounter.close();
      assert.ok(
        readSpawns(mbLog).some((l) => l.includes("--builder usage-counter")),
        "MbUsageCounter must spawn recorded wrapper with --builder usage-counter",
      );

      // 3. Search actually spawns `--builder search` via readers getter
      const search = new Search({ data: dir, backfill: { readers: () => ({ readers: { search: "mb" } }) } });
      await search.query("nonexistent-token-xyz", { workspace: "W", home: true, scopes: ["write"] }, { kinds: ["message"] });
      await search.stop();
      assert.ok(
        readSpawns(mbLog).some((l) => l.includes("--builder search")),
        "Search must spawn recorded wrapper with --builder search",
      );

      // 4. ProgramRunner actually spawns `--builder replica-export` via readers getter
      const runner = new ProgramRunner({
        db: dbPath,
        replica: join(dir, "replica"),
        dataDir: dir,
        origin: "st1",
        readers: () => ({ readers: { "replica-export": "mb" } }),
      });
      const srcs = await runner.sources([]);
      assert.deepEqual(srcs, {});
      await runner.close();
      assert.ok(
        readSpawns(mbLog).some((l) => l.includes("--builder replica-export")),
        "ProgramRunner must spawn recorded wrapper with --builder replica-export",
      );

      // 5. carry (`sizesSoon`, `previewSoon`, explicit null, pre-aborted) actually spawns `--builder replica-carry`
      await assert.rejects(
        () => inProgram({ op: "preview", dataDir: dir, db: dbPath, ws: "w", home: true }, undefined, null),
        /stillfail-reader/,
      );
      const ac = new AbortController();
      ac.abort();
      await assert.rejects(
        () => inProgram({ op: "preview", dataDir: dir, db: dbPath, ws: "w", home: true }, ac.signal),
        /called off/,
      );
      const sized = await sizesSoon(dir, dbPath, [], { most: 10 }, () => ({ readers: { "replica-carry": "mb" } }));
      assert.deepEqual(sized, []);
      assert.ok(
        readSpawns(mbLog).some((l) => l.includes("--builder replica-carry")),
        "sizesSoon must spawn recorded wrapper with --builder replica-carry",
      );

      // 6. Cold restore (`takeBackSoon`) with real `ready.json` and exact `main.ts:236` `{ readers: rawSettings.readers }` shape!
      const restoreData = join(dir, "restore-station");
      mkdirSync(join(restoreData, "restore"), { recursive: true });
      writeFileSync(
        readyFile(restoreData),
        JSON.stringify({ origin: "lost-1", workspace: "w", gen: "g1", name: "lost", from: "peer" }),
      );
      const rawSettings = { readers: { "replica-restore": "pion" } };
      // Temporarily verify that `{ readers: rawSettings.readers }` is read as `config.readers["replica-restore"]`
      // (and since replica-restore is still pionImplemented:false in W6-0, it falls back to MB wrapper and spawns `--builder replica-restore`).
      const restoreSel = resolveReaderSelection("replica-restore", { config: { readers: rawSettings.readers }, env: {} });
      assert.equal(restoreSel.selection.requested, "pion", "main.ts shape { readers: settings.raw()?.readers } must propagate requested=pion");
      assert.equal(restoreSel.selection.source, "config");
      await takeBackSoon(restoreData, join(restoreData, "stillfail.db"), Date.now(), undefined, {
        readers: { readers: rawSettings.readers },
      }).catch(() => {});
      assert.ok(
        readSpawns(mbLog).some((l) => l.includes("--builder replica-restore")),
        "takeBackSoon with ready.json must actually spawn --builder replica-restore",
      );

      // 7. Two stations with distinct per-station readers configs remain completely isolated (zero globals)
      const cfgA: ReaderSelectConfig = { readers: { "live-locator": "mb" } };
      const cfgB: ReaderSelectConfig = { readers: { "live-locator": "pion" } };
      const selA = await resolveReaderSelectionAsync("live-locator", { config: cfgA, env: {} });
      const selB = await resolveReaderSelectionAsync("live-locator", { config: cfgB, env: {} });
      assert.equal(selA.engine, "mb");
      assert.equal(selA.primaryBinary, mbWrap);
      assert.equal(selB.engine, "pion");
      assert.equal(selB.primaryBinary, pionWrap);
    } finally {
      store.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
