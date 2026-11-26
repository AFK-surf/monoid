// Deterministic regression tests for the W9-A5a default-only Pion crash circuit breaker:
// (a) Binary A -> B replacement: late exit of A never demotes B.
// (b) Explicit Pion (config/env) exits never contaminate default counters.
// (c) Early unexpected exits + simulated Node handover reloading `<data>/run/pion-demoted.jsonl` stays demoted.
// (d) Binary stamp change on disk automatically clears demotion and resumes default Pion.
// (e) When no MB binary exists, demoted mode warns and stays safely on Pion without throwing.
// (f) Completely independent of `readerTelemetry`'s 600s window flush.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { hearLines, type Line } from "../src/ops/log.ts";
import { platform } from "../src/platform/index.ts";
import {
  MbProcess,
  breakerOfSelection,
  engineOfSelection,
  fallbackModeOf,
  resetReaderSelectionStateForTest,
  resolveReaderSelection,
  setMbReaderBinaryOverrideForTest,
  setPionProbeRunnerForTest,
} from "../src/read/mb-reader.ts";
import {
  BREAKER_THRESHOLD,
  PionCircuitBreaker,
  pionBinaryStamp,
  pionCircuitBreaker,
} from "../src/read/pion-breaker.ts";
import type { DefaultPolicyTable } from "../src/read/reader-select.ts";
import { readerTelemetry } from "../src/read/reader-telemetry.ts";

const tempDirs: string[] = [];
after(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
});

function freshDir(prefix = "w9-a5-breaker-"): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

const skipPosixStubs = platform.os === "windows" ? "POSIX shell stubs are not directly spawnable without shell: true on Windows" : false;

function makeScript(path: string, body: string): string {
  writeFileSync(path, body, "utf8");
  chmodSync(path, 0o755);
  return path;
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

const ALL_BETA_POLICY: DefaultPolicyTable = {
  beta: ["darwin-arm64", "linux-x64", "linux-arm64", "win32-x64"],
  stable: [],
};

test("(a) binary A -> B replacement: late exit of A never demotes B", () => {
  const dir = freshDir("a-to-b-");
  const stateFile = join(dir, "run", "pion-demoted.jsonl");
  const binA = makeScript(join(dir, "pion-a"), "#!/bin/sh\nexit 1\n");
  const binB = makeScript(join(dir, "pion-b"), "#!/bin/sh\necho ok-v2\n");
  const stampA = pionBinaryStamp(binA)!;
  const stampB = pionBinaryStamp(binB)!;
  assert.ok(stampA && stampB);

  const breaker = new PionCircuitBreaker({ stateFile });
  const t0 = 1_000_000;
  // Two crashes on A, then A is replaced by B, then A's 3rd late crash arrives.
  assert.equal(breaker.recordUnexpectedExit("data", stampA, "default", t0), false);
  assert.equal(breaker.recordUnexpectedExit("data", stampA, "default", t0 + 1_000), false);
  assert.equal(breaker.recordUnexpectedExit("data", stampA, "default", t0 + 2_000), true);
  // A is demoted, but B (different stamp) is NOT demoted and clears A's stale demotion!
  assert.equal(breaker.isDemoted("data", stampA), true);
  assert.equal(breaker.isDemoted("data", stampB), false);
  // Even if A crashes again late, B's counter is untouched.
  breaker.recordUnexpectedExit("data", stampB, "default", t0 + 3_000);
  assert.equal(breaker.isDemoted("data", stampB), false);
});

test("(b) explicit config/env Pion exits never contaminate default counters", () => {
  const dir = freshDir("explicit-iso-");
  const stateFile = join(dir, "run", "pion-demoted.jsonl");
  const bin = makeScript(join(dir, "pion"), "#!/bin/sh\nexit 1\n");
  const stamp = pionBinaryStamp(bin)!;

  const breaker = new PionCircuitBreaker({ stateFile });
  const t0 = 2_000_000;
  for (let i = 0; i < BREAKER_THRESHOLD + 5; i++) {
    assert.equal(breaker.recordUnexpectedExit("data", stamp, "config", t0 + i * 100), false);
    assert.equal(breaker.recordUnexpectedExit("data", stamp, "env", t0 + i * 100), false);
    assert.equal(breaker.recordUnexpectedExit("data", stamp, "explicit", t0 + i * 100), false);
  }
  assert.equal(breaker.isDemoted("data", stamp), false);
  assert.equal(existsSync(stateFile), false, "explicit exits must never create pion-demoted.jsonl");

  // Default counter still requires full K=3 exits from scratch.
  assert.equal(breaker.recordUnexpectedExit("data", stamp, "default", t0 + 10_000), false);
  assert.equal(breaker.recordUnexpectedExit("data", stamp, "default", t0 + 11_000), false);
  assert.equal(breaker.isDemoted("data", stamp), false);
  assert.equal(breaker.recordUnexpectedExit("data", stamp, "default", t0 + 12_000), true);
  assert.equal(breaker.isDemoted("data", stamp), true);
});

test("(c)+(d)+(f) real MbProcess default crashes trip breaker, survive Node handover reload, stay independent of telemetry flush, and recover on stamp change", { skip: skipPosixStubs }, async () => {
  const dir = freshDir("handover-");
  const stateFile = join(dir, "run", "pion-demoted.jsonl");
  const mbBin = makeScript(join(dir, "mb"), "#!/bin/sh\nexit 0\n");
  const pionBin = makeScript(join(dir, "pion"), "#!/bin/sh\nexit 1\n");

  await withEnv({
    STILLFAIL_MB_READER: mbBin,
    STILLFAIL_PION_READER: pionBin,
    STILLFAIL_READER_ENGINE: undefined,
    STILLFAIL_READER_PACKED: undefined,
  }, async () => {
    pionCircuitBreaker.configure(stateFile);
    readerTelemetry.resetForTest();
    setPionProbeRunnerForTest(async () => new Set(["footprint", "packed", "memory"]));

    const selOpts = {
      config: { channel: "beta" as const },
      env: {},
      target: "linux-x64",
      defaultTargetsByChannel: ALL_BETA_POLICY,
    };

    // Spawn 3 crashing default-selected Pion processes; flush telemetry between crashes to prove independence.
    for (let i = 0; i < BREAKER_THRESHOLD; i++) {
      const sel = resolveReaderSelection("packed", selOpts);
      assert.equal(sel.engine, "pion");
      assert.equal(sel.selection.source, "default");
      const proc = new MbProcess(sel.primaryBinary, ["--builder", "packed"], {
        engine: engineOfSelection(sel),
        mode: "packed",
        breaker: breakerOfSelection(sel),
      });
      await new Promise<void>((res) => proc.once("exit", () => res()));
      if (i === 1) {
        // 600s telemetry window flush must NOT reset circuit breaker counts!
        readerTelemetry.flushWindow();
      }
    }

    assert.equal(existsSync(stateFile), true, "pion-demoted.jsonl must be persisted via O_APPEND");
    const lines = readFileSync(stateFile, "utf8").trim().split("\n").map((l) => JSON.parse(l) as { v: number; mode: string; id: string });
    assert.equal(lines.length, BREAKER_THRESHOLD);
    assert.ok(lines.every((l) => l.v === 2 && l.mode === "packed" && typeof l.id === "string"));

    // Simulate Node SIGUSR2 handover: fresh in-memory state reloaded from stateFile.
    pionCircuitBreaker.resetForTest({ stateFile });
    const afterHandover = resolveReaderSelection("packed", selOpts);
    assert.equal(afterHandover.engine, "mb");
    assert.equal(afterHandover.primaryBinary, mbBin);
    assert.equal(afterHandover.selection.fallback, true);
    assert.equal(afterHandover.selection.requested, "pion");
    assert.equal(afterHandover.selection.reason, "pion-circuit-breaker");
    assert.equal(fallbackModeOf(afterHandover.selection), "packed");

    // Explicit config override STILL runs Pion even while default is demoted.
    const explicit = resolveReaderSelection("packed", {
      ...selOpts,
      config: { readers: { packed: "pion" }, channel: "beta" },
    });
    assert.equal(explicit.engine, "pion");
    assert.equal(explicit.selection.source, "config");

    // (d) Upgrade binary on disk (different size/mtime) -> new stamp is NOT demoted (without deleting old stamp's record).
    makeScript(pionBin, "#!/bin/sh\necho upgraded-binary-v2\nexit 0\n");
    const afterUpgrade = resolveReaderSelection("packed", selOpts);
    assert.equal(afterUpgrade.engine, "pion");
    assert.equal(afterUpgrade.selection.fallback, false);
    assert.equal(pionCircuitBreaker.isDemoted("packed", pionBinaryStamp(pionBin)!), false);
  });
});

test("(g) R2: explicit shadow crashes never demote default footprint; dual instances read-merge-write without clobbering; late A exit never clears B; handover preserves crash count", { skip: skipPosixStubs }, async () => {
  const dir = freshDir("r2-breaker-");
  const sharedFile = join(dir, "shared", "pion-demoted.jsonl");
  const stationAFile = join(dir, "station-a", "pion-demoted.jsonl");
  const stationBFile = join(dir, "station-b", "pion-demoted.jsonl");
  const mbBin = makeScript(join(dir, "mb"), "#!/bin/sh\nexit 0\n");
  const pionA = makeScript(join(dir, "pion-a"), "#!/bin/sh\nexit 1\n");
  const pionB = makeScript(join(dir, "pion-b"), "#!/bin/sh\necho v2\nexit 1\n");
  const stampA = pionBinaryStamp(pionA)!;
  const stampB = pionBinaryStamp(pionB)!;

  // 1. Overlapping Node processes sharing `sharedFile`: instance 1 demotes `packed`, instance 2 demotes `memory` -> both survive on disk.
  const b1 = new PionCircuitBreaker({ stateFile: sharedFile });
  const b2 = new PionCircuitBreaker({ stateFile: sharedFile });
  const t0 = 5_000_000;
  for (let i = 0; i < BREAKER_THRESHOLD; i++) b1.recordUnexpectedExit("packed", stampA, "default", t0 + i * 100);
  for (let i = 0; i < BREAKER_THRESHOLD; i++) b2.recordUnexpectedExit("memory", stampA, "default", t0 + 1_000 + i * 100);
  const bReload = new PionCircuitBreaker({ stateFile: sharedFile });
  assert.equal(bReload.isDemoted("packed", stampA), true, "packed demotion must survive concurrent memory demotion");
  assert.equal(bReload.isDemoted("memory", stampA), true, "memory demotion must survive concurrent packed demotion");

  // 2. B is demoted; late exit of A must NEVER clear B's demotion.
  for (let i = 0; i < BREAKER_THRESHOLD; i++) bReload.recordUnexpectedExit("data", stampB, "default", t0 + 2_000 + i * 100);
  assert.equal(bReload.isDemoted("data", stampB), true);
  bReload.recordUnexpectedExit("data", stampA, "default", t0 + 3_000);
  assert.equal(bReload.isDemoted("data", stampB), true, "late exit of binary A must never clear binary B demotion");
  const bReload2 = new PionCircuitBreaker({ stateFile: sharedFile });
  assert.equal(bReload2.isDemoted("data", stampB), true);

  // 3. Handover preserves sliding-window crash timestamps: 2 exits before handover + 1 exit after handover = demoted!
  const hFile = join(dir, "handover-count", "pion-demoted.jsonl");
  const h1 = new PionCircuitBreaker({ stateFile: hFile });
  assert.equal(h1.recordUnexpectedExit("sessions", stampA, "default", t0), false);
  assert.equal(h1.recordUnexpectedExit("sessions", stampA, "default", t0 + 1_000), false);
  const h2 = new PionCircuitBreaker({ stateFile: hFile });
  assert.equal(h2.isDemoted("sessions", stampA), false);
  assert.equal(h2.recordUnexpectedExit("sessions", stampA, "default", t0 + 2_000), true, "3rd crash after handover must trip demotion");
  assert.equal(h2.isDemoted("sessions", stampA), true);

  // 4. Per-station isolation: demoting `packed` on stationA never affects stationB.
  const stA = new PionCircuitBreaker({ stateFile: stationAFile });
  const stB = new PionCircuitBreaker({ stateFile: stationBFile });
  for (let i = 0; i < BREAKER_THRESHOLD; i++) stA.recordUnexpectedExit("packed", stampA, "default", t0 + i * 100);
  assert.equal(stA.isDemoted("packed", stampA), true);
  assert.equal(stB.isDemoted("packed", stampA), false);

  // 4b. Same-millisecond crashes (identical `nowMs`) with stateFile must NOT be deduplicated and must trip demotion + persist all 3 lines.
  const sameMsFile = join(dir, "same-ms", "pion-demoted.jsonl");
  const sameMsBreaker = new PionCircuitBreaker({ stateFile: sameMsFile, watch: false });
  const sameMs = 6_000_000;
  assert.equal(sameMsBreaker.recordUnexpectedExit("packed", stampA, "default", sameMs), false);
  assert.equal(sameMsBreaker.recordUnexpectedExit("packed", stampA, "default", sameMs), false);
  assert.equal(sameMsBreaker.recordUnexpectedExit("packed", stampA, "default", sameMs), true, "3 identical-ms crashes must trip demotion");
  assert.equal(sameMsBreaker.isDemoted("packed", stampA), true);
  const sameMsLines = readFileSync(sameMsFile, "utf8").trim().split("\n").map((l) => JSON.parse(l) as { mode: string; at: number; id: string });
  assert.equal(sameMsLines.length, BREAKER_THRESHOLD, "all 3 identical-ms crashes must be appended as distinct JSONL events");
  assert.equal(new Set(sameMsLines.map((l) => l.id)).size, BREAKER_THRESHOLD);
  const sameMsReload = new PionCircuitBreaker({ stateFile: sameMsFile, watch: false });
  assert.equal(sameMsReload.isDemoted("packed", stampA), true);
  assert.equal(sameMsReload.demotedEntry("packed", stampA)?.demotedAt, sameMs);

  // 5. Explicit `shadow` crashes on `footprint` never demote default `footprint`.
  await withEnv({
    STILLFAIL_MB_READER: mbBin,
    STILLFAIL_PION_READER: pionA,
    STILLFAIL_READER_ENGINE: undefined,
    STILLFAIL_READER_FOOTPRINT: undefined,
  }, async () => {
    const stFootprint = new PionCircuitBreaker({ stateFile: join(dir, "fp", "pion-demoted.jsonl") });
    for (let i = 0; i < BREAKER_THRESHOLD + 1; i++) {
      const shadowSel = resolveReaderSelection("footprint", {
        config: { readers: { footprint: "shadow" }, channel: "beta", breaker: stFootprint },
        env: {},
        target: "linux-x64",
        defaultTargetsByChannel: ALL_BETA_POLICY,
      });
      assert.equal(shadowSel.engine, "shadow");
      assert.equal(breakerOfSelection(shadowSel), undefined, "shadow selection must never attach a default breaker");
      const shadowProc = new MbProcess(shadowSel.pionBinary!, ["--builder", "footprint"], {
        engine: "pion",
        mode: "footprint",
        breaker: breakerOfSelection(shadowSel),
      });
      await new Promise<void>((res) => shadowProc.once("exit", () => res()));
    }
    const defaultFp = resolveReaderSelection("footprint", {
      config: { channel: "beta", breaker: stFootprint },
      env: {},
      target: "linux-x64",
      defaultTargetsByChannel: ALL_BETA_POLICY,
    });
    assert.equal(defaultFp.engine, "pion", "explicit shadow crashes must never demote default footprint");
    assert.equal(stFootprint.isDemoted("footprint", stampA), false);
  });
});

test("(h) R4: lock-free O_APPEND JSONL concurrent children (0 main-thread stall), live watcher late demotion, cross-mode pending flush demotion, and unwritable disk recovery", async () => {
  const dir = freshDir("r4-breaker-");
  const sharedFile = join(dir, "concurrent", "pion-demoted.jsonl");
  const mbBin = makeScript(join(dir, "mb-r4"), "#!/bin/sh\nexit 0\n");
  const pionBin = makeScript(join(dir, "pion-shared"), "#!/bin/sh\nexit 1\n");
  const stamp = pionBinaryStamp(pionBin)!;

  // 1. Two real child processes concurrently appending `packed` and `memory` (lock-free O_APPEND, 0 Atomics.wait stall).
  const workerUrl = new URL("../src/read/pion-breaker.ts", import.meta.url).href;
  const runChild = (mode: "packed" | "memory") => new Promise<void>((resolve, reject) => {
    const code = `
      import { PionCircuitBreaker, pionBinaryStamp } from ${JSON.stringify(workerUrl)};
      const b = new PionCircuitBreaker({ stateFile: ${JSON.stringify(sharedFile)}, watch: false });
      const s = pionBinaryStamp(${JSON.stringify(pionBin)});
      const t = 7000000;
      for (let i = 0; i < 3; i++) b.recordUnexpectedExit(${JSON.stringify(mode)}, s, "default", t + i);
      if (!b.isDemoted(${JSON.stringify(mode)}, s)) process.exit(2);
    `;
    const child = spawn(process.execPath, ["--input-type=module", "-e", code], { stdio: "inherit" });
    child.once("error", reject);
    child.once("exit", (c) => (c === 0 ? resolve() : reject(new Error(`child ${mode} exited ${c}`))));
  });
  const tImm = Date.now();
  const immLag = new Promise<number>((res) => setImmediate(() => res(Date.now() - tImm)));
  await Promise.all([runChild("packed"), runChild("memory")]);
  assert.ok((await immLag) < 50, "lock-free O_APPEND must not block main-thread event loop");
  const verified = new PionCircuitBreaker({ stateFile: sharedFile, watch: false });
  assert.equal(verified.isDemoted("packed", stamp), true, "concurrent child packed demotion must survive");
  assert.equal(verified.isDemoted("memory", stamp), true, "concurrent child memory demotion must survive");

  // 2. Live successor instance B (created after 2 crashes) automatically observes old instance A's late 3rd crash via fs.watch!
  const handoverFile = join(dir, "live-handover", "pion-demoted.jsonl");
  const oldInst = new PionCircuitBreaker({ stateFile: handoverFile, watch: false });
  assert.equal(oldInst.recordUnexpectedExit("packed", stamp, "default", 7_500_000), false);
  assert.equal(oldInst.recordUnexpectedExit("packed", stamp, "default", 7_500_010), false);
  const newInst = new PionCircuitBreaker({ stateFile: handoverFile, watch: true });
  try {
    assert.equal(newInst.isDemoted("packed", stamp), false);
    // Old instance records late 3rd crash; newInst must observe it asynchronously without being reconstructed.
    assert.equal(oldInst.recordUnexpectedExit("packed", stamp, "default", 7_500_020), true);
    const deadline = Date.now() + 2_000;
    while (!newInst.isDemoted("packed", stamp) && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 15));
    }
    assert.equal(newInst.isDemoted("packed", stamp), true, "running successor instance must observe late demotion via fs.watch");
    await withEnv({ STILLFAIL_MB_READER: mbBin, STILLFAIL_PION_READER: pionBin }, async () => {
      const sel = resolveReaderSelection("packed", {
        config: { channel: "beta", breaker: newInst },
        env: {},
        target: "linux-x64",
        defaultTargetsByChannel: ALL_BETA_POLICY,
      });
      assert.equal(sel.engine, "mb");
      assert.equal(sel.selection.reason, "pion-circuit-breaker");
    });
  } finally {
    newInst.close();
  }

  // 3. Cross-mode pending flush (Astra P2 #1): A has 1 failed `memory` write + B writes 2 `memory` exits + disk recovers + A writes `packed` -> `memory` MUST trip demotion!
  const crossFile = join(dir, "cross-mode", "pion-demoted.jsonl");
  mkdirSync(crossFile, { recursive: true }); // block A's first write
  const instA = new PionCircuitBreaker({ stateFile: crossFile, watch: false });
  assert.equal(instA.recordUnexpectedExit("memory", stamp, "default", 8_500_000), false);
  // Disk becomes writable and peer B records 2 `memory` crashes.
  rmSync(crossFile, { recursive: true, force: true });
  const instB = new PionCircuitBreaker({ stateFile: crossFile, watch: false });
  assert.equal(instB.recordUnexpectedExit("memory", stamp, "default", 8_500_010), false);
  assert.equal(instB.recordUnexpectedExit("memory", stamp, "default", 8_500_020), false);
  assert.equal(instB.isDemoted("memory", stamp), false);
  // Now A records a `packed` crash, which flushes A's pending `memory` event too -> `memory` now has 3 events and MUST demote!
  assert.equal(instA.recordUnexpectedExit("packed", stamp, "default", 8_500_030), false);
  assert.equal(instA.isDemoted("memory", stamp), true, "flushing pending memory event during packed crash must recompute memory demotion");
  const freshCheck = new PionCircuitBreaker({ stateFile: crossFile, watch: false });
  assert.equal(freshCheck.isDemoted("memory", stamp), true, "fresh instance must observe demoted memory after cross-mode flush");

  // 4. Unwritable path (directory blocking `stateFile`): 3 crashes still trip in-process demotion; recovery flushes once without double-counting!
  const blockedFile = join(dir, "blocked", "pion-demoted.jsonl");
  mkdirSync(blockedFile, { recursive: true });
  const unwritable = new PionCircuitBreaker({ stateFile: blockedFile, watch: false });
  const t1 = 8_000_000;
  assert.equal(unwritable.recordUnexpectedExit("data", stamp, "default", t1), false);
  assert.equal(unwritable.recordUnexpectedExit("data", stamp, "default", t1 + 10), false);
  assert.equal(unwritable.recordUnexpectedExit("data", stamp, "default", t1 + 20), true, "3rd crash must trip in-memory demotion even when disk append fails");
  assert.equal(unwritable.isDemoted("data", stamp), true);

  const recoverFile = join(dir, "recover", "pion-demoted.jsonl");
  mkdirSync(recoverFile, { recursive: true });
  const recovering = new PionCircuitBreaker({ stateFile: recoverFile, watch: false });
  const t2 = 9_000_000;
  assert.equal(recovering.recordUnexpectedExit("sessions", stamp, "default", t2), false);
  rmSync(recoverFile, { recursive: true, force: true });
  assert.equal(recovering.recordUnexpectedExit("sessions", stamp, "default", t2 + 10), false, "recovering from write failure must not double-count pending events");
  assert.equal(recovering.isDemoted("sessions", stamp), false);
  const recLines = readFileSync(recoverFile, "utf8").trim().split("\n").map((l) => JSON.parse(l) as { mode: string; id: string });
  assert.equal(recLines.length, 2, "exactly 2 unique JSONL events persisted after recovery");
  assert.equal(recovering.recordUnexpectedExit("sessions", stamp, "default", t2 + 20), true);
  assert.equal(recovering.isDemoted("sessions", stamp), true);
});

test("(e) demoted mode with no MB binary logs warn and stays safely on Pion without throwing", { skip: skipPosixStubs }, async () => {
  const dir = freshDir("no-mb-");
  const stateFile = join(dir, "run", "pion-demoted.jsonl");
  const pionBin = makeScript(join(dir, "pion"), "#!/bin/sh\nexit 0\n");

  const logs: Line[] = [];
  hearLines((l) => logs.push(l));
  try {
    await withEnv({
      STILLFAIL_PION_READER: pionBin,
      STILLFAIL_READER_ENGINE: undefined,
      STILLFAIL_READER_PACKED: undefined,
    }, async () => {
      setMbReaderBinaryOverrideForTest(() => null);
      pionCircuitBreaker.configure(stateFile);
      const stamp = pionBinaryStamp(pionBin)!;
      for (let i = 0; i < BREAKER_THRESHOLD; i++) {
        pionCircuitBreaker.recordUnexpectedExit("packed", stamp, "default", 3_000_000 + i * 100);
      }
      assert.equal(pionCircuitBreaker.isDemoted("packed", stamp), true);

      const resolved = resolveReaderSelection("packed", {
        config: { channel: "beta" },
        env: {},
        target: "linux-x64",
        defaultTargetsByChannel: ALL_BETA_POLICY,
        logAt: "breaker-no-mb",
      });
      assert.equal(resolved.engine, "pion");
      assert.equal(resolved.primaryBinary, pionBin);
      const warns = logs.filter((l) => l.level === "WARN" && l.at === "breaker-no-mb");
      assert.equal(warns.length, 1, "expected deduped warning when demoted with no MB binary");
    });
  } finally {
    hearLines(null);
  }
});
