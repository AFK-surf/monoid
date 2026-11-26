// Deterministic regression tests for the W9-A5a default-only Pion crash circuit breaker:
// (a) Binary A -> B replacement: late exit of A never demotes B.
// (b) Explicit Pion (config/env) exits never contaminate default counters.
// (c) Early unexpected exits + simulated Node handover reloading `<data>/run/pion-demoted.jsonl` stays demoted.
// (d) Binary stamp change on disk automatically clears demotion and resumes default Pion.
// (e) When no MB binary exists, demoted mode warns and stays safely on Pion without throwing.
// (f) Completely independent of `readerTelemetry`'s 600s window flush.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { Effect } from "effect";
import {
  chmodSync,
  closeSync,
  existsSync,
  fstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  unlinkSync,
  watch,
  writeFileSync,
  writeSync,
} from "node:fs";
import { open } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { hearLines, type Line } from "../src/ops/log.ts";
import { platform } from "../src/platform/index.ts";
import { releasePionCircuitBreaker } from "../src/services.ts";
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
  MAX_LOG_BYTES,
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
  assert.equal(existsSync(join(dir, "run")), false, "explicit exits must never create breaker files");

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

    const ownLog = pionCircuitBreaker.ownLogPath()!;
    assert.equal(existsSync(ownLog), true, "exclusive per-instance breaker log must be persisted via O_APPEND");
    const lines = readFileSync(ownLog, "utf8")
      .split("\n")
      .map((l) => l.trim())
      .filter((l) => l !== "")
      .map((l) => JSON.parse(l) as { v: number; mode: string; id: string });
    assert.equal(lines.length, BREAKER_THRESHOLD);
    assert.ok(lines.every((l) => l.v === 2 && l.mode === "packed" && typeof l.id === "string"));
    assert.ok(
      readdirSync(join(dir, "run")).some((n) => n.startsWith("pion-demoted.jsonl.demoted.") && n.endsWith(".json")),
      "immutable demotion marker must be published when breaker trips",
    );

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
  const b1 = new PionCircuitBreaker({ stateFile: sharedFile, watch: false });
  const b2 = new PionCircuitBreaker({ stateFile: sharedFile, watch: false });
  const t0 = 5_000_000;
  for (let i = 0; i < BREAKER_THRESHOLD; i++) b1.recordUnexpectedExit("packed", stampA, "default", t0 + i * 100);
  for (let i = 0; i < BREAKER_THRESHOLD; i++) b2.recordUnexpectedExit("memory", stampA, "default", t0 + 1_000 + i * 100);
  const bReload = new PionCircuitBreaker({ stateFile: sharedFile, watch: false });
  assert.equal(bReload.isDemoted("packed", stampA), true, "packed demotion must survive concurrent memory demotion");
  assert.equal(bReload.isDemoted("memory", stampA), true, "memory demotion must survive concurrent packed demotion");

  // 2. B is demoted; late exit of A must NEVER clear B's demotion.
  for (let i = 0; i < BREAKER_THRESHOLD; i++) bReload.recordUnexpectedExit("data", stampB, "default", t0 + 2_000 + i * 100);
  assert.equal(bReload.isDemoted("data", stampB), true);
  bReload.recordUnexpectedExit("data", stampA, "default", t0 + 3_000);
  assert.equal(bReload.isDemoted("data", stampB), true, "late exit of binary A must never clear binary B demotion");
  const bReload2 = new PionCircuitBreaker({ stateFile: sharedFile, watch: false });
  assert.equal(bReload2.isDemoted("data", stampB), true);

  // 3. Handover preserves sliding-window crash timestamps: 2 exits before handover + 1 exit after handover = demoted!
  const hFile = join(dir, "handover-count", "pion-demoted.jsonl");
  const h1 = new PionCircuitBreaker({ stateFile: hFile, watch: false });
  assert.equal(h1.recordUnexpectedExit("sessions", stampA, "default", t0), false);
  assert.equal(h1.recordUnexpectedExit("sessions", stampA, "default", t0 + 1_000), false);
  const h2 = new PionCircuitBreaker({ stateFile: hFile, watch: false });
  assert.equal(h2.isDemoted("sessions", stampA), false);
  assert.equal(h2.recordUnexpectedExit("sessions", stampA, "default", t0 + 2_000), true, "3rd crash after handover must trip demotion");
  assert.equal(h2.isDemoted("sessions", stampA), true);

  // 4. Per-station isolation: demoting `packed` on stationA never affects stationB.
  const stA = new PionCircuitBreaker({ stateFile: stationAFile, watch: false });
  const stB = new PionCircuitBreaker({ stateFile: stationBFile, watch: false });
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
  const sameMsLines = readFileSync(sameMsBreaker.ownLogPath()!, "utf8")
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l !== "")
    .map((l) => JSON.parse(l) as { mode: string; at: number; id: string });
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
    const stFootprint = new PionCircuitBreaker({ stateFile: join(dir, "fp", "pion-demoted.jsonl"), watch: false });
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
  const crossParent = join(dir, "cross-mode");
  const crossFile = join(crossParent, "pion-demoted.jsonl");
  writeFileSync(crossParent, "block-dir", "utf8"); // block A's first write (ENOTDIR on parent)
  const instA = new PionCircuitBreaker({ stateFile: crossFile, watch: false });
  assert.equal(instA.recordUnexpectedExit("memory", stamp, "default", 8_500_000), false);
  // Disk becomes writable and peer B records 2 `memory` crashes.
  rmSync(crossParent, { force: true });
  const instB = new PionCircuitBreaker({ stateFile: crossFile, watch: false });
  assert.equal(instB.recordUnexpectedExit("memory", stamp, "default", 8_500_010), false);
  assert.equal(instB.recordUnexpectedExit("memory", stamp, "default", 8_500_020), false);
  assert.equal(instB.isDemoted("memory", stamp), false);
  // Now A records a `packed` crash, which flushes A's pending `memory` event too -> `memory` now has 3 events and MUST demote!
  assert.equal(instA.recordUnexpectedExit("packed", stamp, "default", 8_500_030), false);
  assert.equal(instA.isDemoted("memory", stamp), true, "flushing pending memory event during packed crash must recompute memory demotion");
  const freshCheck = new PionCircuitBreaker({ stateFile: crossFile, watch: false });
  assert.equal(freshCheck.isDemoted("memory", stamp), true, "fresh instance must observe demoted memory after cross-mode flush");

  // 4. Unwritable parent path: 3 crashes still trip in-process demotion; recovery flushes once without double-counting!
  const blockedParent = join(dir, "blocked");
  const blockedFile = join(blockedParent, "pion-demoted.jsonl");
  writeFileSync(blockedParent, "block-dir", "utf8");
  const unwritable = new PionCircuitBreaker({ stateFile: blockedFile, watch: false });
  const t1 = 8_000_000;
  assert.equal(unwritable.recordUnexpectedExit("data", stamp, "default", t1), false);
  assert.equal(unwritable.recordUnexpectedExit("data", stamp, "default", t1 + 10), false);
  assert.equal(unwritable.recordUnexpectedExit("data", stamp, "default", t1 + 20), true, "3rd crash must trip in-memory demotion even when disk append fails");
  assert.equal(unwritable.isDemoted("data", stamp), true);

  const recoverParent = join(dir, "recover");
  const recoverFile = join(recoverParent, "pion-demoted.jsonl");
  writeFileSync(recoverParent, "block-dir", "utf8");
  const recovering = new PionCircuitBreaker({ stateFile: recoverFile, watch: false });
  const t2 = 9_000_000;
  assert.equal(recovering.recordUnexpectedExit("sessions", stamp, "default", t2), false);
  rmSync(recoverParent, { force: true });
  assert.equal(recovering.recordUnexpectedExit("sessions", stamp, "default", t2 + 10), false, "recovering from write failure must not double-count pending events");
  assert.equal(recovering.isDemoted("sessions", stamp), false);
  const recLines = readFileSync(recovering.ownLogPath()!, "utf8")
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l !== "")
    .map((l) => JSON.parse(l) as { mode: string; id: string });
  assert.equal(recLines.length, 2, "exactly 2 unique JSONL events persisted after recovery");
  assert.equal(recovering.recordUnexpectedExit("sessions", stamp, "default", t2 + 20), true);
  assert.equal(recovering.isDemoted("sessions", stamp), true);
});

test("(i) R5: torn trailing line immunity, fs.watch EMFILE self-healing, O(N) 2000-line cold load + no post-demotion growth, and close() pending flush", { skip: skipPosixStubs }, async () => {
  const dir = freshDir("r5-breaker-");
  const mbBin = makeScript(join(dir, "mb-r5"), "#!/bin/sh\nexit 0\n");
  const pionBin = makeScript(join(dir, "pion-r5"), "#!/bin/sh\nexit 1\n");
  const stamp = pionBinaryStamp(pionBin)!;

  // 1. Torn partial trailing line without `\n`: subsequent O_APPEND records must start on a fresh line so cold-start preserves all 3 exits.
  const tornDir = join(dir, "torn");
  mkdirSync(tornDir, { recursive: true });
  const tornFile = join(tornDir, "pion-demoted.jsonl");
  const tornWriter = new PionCircuitBreaker({ stateFile: tornFile, watch: false });
  writeFileSync(tornWriter.ownLogPath()!, '{"v":2,"mo', "utf8");
  assert.equal(tornWriter.recordUnexpectedExit("packed", stamp, "default", 11_000_000), false);
  assert.equal(tornWriter.recordUnexpectedExit("packed", stamp, "default", 11_000_010), false);
  assert.equal(tornWriter.recordUnexpectedExit("packed", stamp, "default", 11_000_020), true);
  const tornReload = new PionCircuitBreaker({ stateFile: tornFile, watch: false });
  assert.equal(tornReload.isDemoted("packed", stamp), true, "torn trailing fragment must never swallow the first appended record");

  // 2. fs.watch EMFILE on first attach -> automatic backoff retry + catch-up read observes old instance's 3 crashes -> resolveReaderSelection returns "mb".
  const healDir = join(dir, "heal");
  mkdirSync(healDir, { recursive: true });
  const healFile = join(healDir, "pion-demoted.jsonl");
  let watchCalls = 0;
  const flakyWatch: typeof watch = ((targetDir: string, listener: (eventType: string, filename: string | Buffer | null) => void) => {
    watchCalls++;
    if (watchCalls === 1) {
      const err = new Error("EMFILE: too many open files") as NodeJS.ErrnoException;
      err.code = "EMFILE";
      throw err;
    }
    return watch(targetDir, listener);
  }) as typeof watch;
  const oldInst = new PionCircuitBreaker({ stateFile: healFile, watch: false });
  const newInst = new PionCircuitBreaker({ stateFile: healFile, watch: true, watchFn: flakyWatch });
  try {
    assert.equal(watchCalls, 1, "first watch attach should have thrown EMFILE");
    assert.equal(newInst.isDemoted("packed", stamp), false);
    for (let i = 0; i < BREAKER_THRESHOLD; i++) {
      oldInst.recordUnexpectedExit("packed", stamp, "default", 12_000_000 + i * 10);
    }
    const deadline = Date.now() + 2_000;
    while (!newInst.isDemoted("packed", stamp) && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 15));
    }
    assert.ok(watchCalls >= 2, "watcher must retry and re-attach after transient EMFILE");
    assert.equal(newInst.isDemoted("packed", stamp), true, "recovered watcher must catch up and observe demotion");
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

  // 3. O(N) 2,000-line cold start publishes immutable demotion marker + zero post-demotion file growth.
  const totalBreakerBytes = (d: string): number =>
    readdirSync(d)
      .filter((n) => n.startsWith("pion-demoted"))
      .reduce((acc, n) => acc + statSync(join(d, n)).size, 0);

  const bigDir = join(dir, "big");
  mkdirSync(bigDir, { recursive: true });
  const bigFile = join(bigDir, "pion-demoted.jsonl");
  const bulk: string[] = [];
  for (let i = 0; i < 2_000; i++) {
    bulk.push(JSON.stringify({ v: 2, mode: "packed", stamp, at: 13_000_000 + i, id: `bulk:${i}` }));
  }
  writeFileSync(bigFile, `${bulk.join("\n")}\n`, "utf8");
  assert.ok(totalBreakerBytes(bigDir) > MAX_LOG_BYTES, "pre-load fixture must exceed MAX_LOG_BYTES (64 KiB)");

  const bigBreaker = new PionCircuitBreaker({ stateFile: bigFile, watch: false });
  assert.equal(bigBreaker.isDemoted("packed", stamp), true, "demotion must be detected from 2,000-line log");
  assert.ok(
    readdirSync(bigDir).some((n) => n.startsWith("pion-demoted.jsonl.demoted.") && n.endsWith(".json")),
    "immutable demotion marker must be published on cold-start discovery",
  );
  const sizeAfterMarker = totalBreakerBytes(bigDir);
  // Once demoted & persisted, further crashes (e.g. no MB binary fallback) must not grow disk usage.
  for (let i = 0; i < 50; i++) {
    assert.equal(bigBreaker.recordUnexpectedExit("packed", stamp, "default", 13_100_000 + i * 10), true);
  }
  assert.equal(totalBreakerBytes(bigDir), sizeAfterMarker, "already-demoted stamp must not grow pion-demoted files");

  // 4. close() flushes pending in-memory events + demotion marker after disk recovers so a fresh handover instance sees demotion.
  const closeParent = join(dir, "close-flush");
  const closeFile = join(closeParent, "pion-demoted.jsonl");
  writeFileSync(closeParent, "block-dir", "utf8"); // block disk writes
  const failingInst = new PionCircuitBreaker({ stateFile: closeFile, watch: false });
  for (let i = 0; i < BREAKER_THRESHOLD; i++) {
    failingInst.recordUnexpectedExit("data", stamp, "default", 14_000_000 + i * 10);
  }
  assert.equal(failingInst.isDemoted("data", stamp), true);
  rmSync(closeParent, { force: true }); // disk recovers before handover
  failingInst.close();
  const afterClose = new PionCircuitBreaker({ stateFile: closeFile, watch: false });
  assert.equal(afterClose.isDemoted("data", stamp), true, "close() must flush pending events so successor observes demotion");
});

test("(j) R6: multi-instance concurrent demotion, inode identity cursors, EIO read safety, EMFILE async read self-healing, and long-lived sparse self-compaction", { skip: skipPosixStubs }, async () => {
  const dir = freshDir("r6-breaker-");
  const mbBin = makeScript(join(dir, "mb-r6"), "#!/bin/sh\nexit 0\n");
  const pionBin = makeScript(join(dir, "pion-r6"), "#!/bin/sh\nexit 1\n");
  const stamp = pionBinaryStamp(pionBin)!;
  const totalBreakerBytes = (d: string): number =>
    readdirSync(d)
      .filter((n) => n.startsWith("pion-demoted"))
      .reduce((acc, n) => acc + statSync(join(d, n)).size, 0);

  // 1. Concurrent old + successor instances with separate exclusive logs never lose the 3rd exit and publish immutable marker.
  const rotDir2 = join(dir, "rot-concurrent");
  mkdirSync(rotDir2, { recursive: true });
  const rotFile2 = join(rotDir2, "pion-demoted.jsonl");
  const tRot = Date.now();
  const oldInst1 = new PionCircuitBreaker({ stateFile: rotFile2, watch: false });
  oldInst1.recordUnexpectedExit("packed", stamp, "default", tRot - 2_000);
  oldInst1.recordUnexpectedExit("packed", stamp, "default", tRot - 1_000);
  const succInst1 = new PionCircuitBreaker({ stateFile: rotFile2, watch: true });
  try {
    assert.equal(succInst1.isDemoted("packed", stamp), false);
    assert.equal(oldInst1.recordUnexpectedExit("packed", stamp, "default", tRot), true, "3rd exit must trip demotion");
    const deadline = Date.now() + 2_000;
    while (!succInst1.isDemoted("packed", stamp) && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 20));
    }
    assert.equal(succInst1.isDemoted("packed", stamp), true, "running successor must observe 3rd exit across exclusive peer logs");
    const freshAfterRot = new PionCircuitBreaker({ stateFile: rotFile2, watch: false });
    assert.equal(freshAfterRot.isDemoted("packed", stamp), true, "fresh cold instance must observe demotion");
    await withEnv({ STILLFAIL_MB_READER: mbBin, STILLFAIL_PION_READER: pionBin }, async () => {
      for (const b of [succInst1, freshAfterRot]) {
        const sel = resolveReaderSelection("packed", {
          config: { channel: "beta", breaker: b },
          env: {},
          target: "linux-x64",
          defaultTargetsByChannel: ALL_BETA_POLICY,
        });
        assert.equal(sel.engine, "mb");
        assert.equal(sel.selection.reason, "pion-circuit-breaker");
      }
    });
  } finally {
    oldInst1.close();
    succInst1.close();
  }

  // 2. Replaced file with larger size & different inode must re-read from byte 0 (Astra P1 #2).
  const inoDir = join(dir, "inode-replace");
  mkdirSync(inoDir, { recursive: true });
  const inoFile = join(inoDir, "pion-demoted.jsonl");
  const seedInoLines = [
    JSON.stringify({ v: 2, mode: "memory", stamp, at: 15_000_000, id: "ino:1" }),
    JSON.stringify({ v: 2, mode: "memory", stamp, at: 15_000_010, id: "ino:2" }),
  ];
  writeFileSync(inoFile, `${seedInoLines.join("\n")}\n`, "utf8");
  const oldSize = statSync(inoFile).size;
  assert.ok(oldSize > 200 && oldSize < 800, `expected initial file ~384B (got ${oldSize} B)`);
  const syncIno = new PionCircuitBreaker({ stateFile: inoFile, watch: false });
  const watchIno = new PionCircuitBreaker({ stateFile: inoFile, watch: true });
  try {
    // Atomically replace inoFile with a NEW inode > 1950 B whose first < oldSize bytes hold `packed` demotion!
    const tmpReplace = join(inoDir, "replace-new-inode.tmp");
    const demotedHead = JSON.stringify({ v: 2, mode: "packed", stamp, demotedAt: 15_000_100 });
    assert.ok(Buffer.byteLength(demotedHead, "utf8") < oldSize, "demotion line must sit strictly before old cursor offset");
    const tailPad: string[] = [demotedHead];
    for (let i = 0; i < 12; i++) {
      tailPad.push(JSON.stringify({ v: 2, mode: "sessions", stamp, at: 15_000_200 + i * 400_000, id: `tail:${i}` }));
    }
    writeFileSync(tmpReplace, `${tailPad.join("\n")}\n`, "utf8");
    assert.ok(statSync(tmpReplace).size > 1_950, "replacement inode must be > 1950 B (larger than old offset)");
    renameSync(tmpReplace, inoFile);

    // Sync path must detect inode change and re-read from offset 0.
    syncIno.syncFromDisk();
    assert.equal(syncIno.isDemoted("packed", stamp), true, "syncFromDisk must detect new inode even when larger than old offset");

    // Async watcher path must also detect inode change and re-read from offset 0.
    const aDeadline = Date.now() + 2_000;
    while (!watchIno.isDemoted("packed", stamp) && Date.now() < aDeadline) {
      await new Promise((r) => setTimeout(r, 15));
    }
    assert.equal(watchIno.isDemoted("packed", stamp), true, "async watcher must detect new inode and re-read from byte 0");
    await withEnv({ STILLFAIL_MB_READER: mbBin, STILLFAIL_PION_READER: pionBin }, async () => {
      for (const b of [syncIno, watchIno]) {
        const sel = resolveReaderSelection("packed", {
          config: { channel: "beta", breaker: b },
          env: {},
          target: "linux-x64",
          defaultTargetsByChannel: ALL_BETA_POLICY,
        });
        assert.equal(sel.engine, "mb");
        assert.equal(sel.selection.reason, "pion-circuit-breaker");
      }
    });
  } finally {
    syncIno.close();
    watchIno.close();
  }

  // 3. First sync read throwing EIO must leave >95 KiB log untouched (no wipe/empty compaction); recovery sees demotion.
  const eioDir = join(dir, "eio-abort");
  mkdirSync(eioDir, { recursive: true });
  const eioFile = join(eioDir, "pion-demoted.jsonl");
  const eioLines: string[] = [];
  for (let i = 0; i < 600; i++) {
    eioLines.push(JSON.stringify({ v: 2, mode: "packed", stamp, at: 16_000_000 + i, id: `eio:${i}` }));
  }
  writeFileSync(eioFile, `${eioLines.join("\n")}\n`, "utf8");
  const origBytes = statSync(eioFile).size;
  assert.ok(origBytes > 95 * 1024, `expected >95 KiB fixture (got ${origBytes} B)`);

  let eioSyncCalls = 0;
  const eioOpenSync: typeof openSync = ((...args: Parameters<typeof openSync>) => {
    eioSyncCalls++;
    if (eioSyncCalls === 1) {
      const err = new Error("EIO: i/o error") as NodeJS.ErrnoException;
      err.code = "EIO";
      throw err;
    }
    return openSync(...args);
  }) as typeof openSync;
  const eioBreaker = new PionCircuitBreaker({
    stateFile: eioFile,
    watch: false,
    readFs: { openSync: eioOpenSync },
  });
  assert.equal(eioSyncCalls, 1, "first openSync should have injected EIO");
  assert.equal(statSync(eioFile).size, origBytes, "EIO on initial read must NEVER wipe or shrink the original log");
  eioBreaker.syncFromDisk();
  assert.equal(eioBreaker.isDemoted("packed", stamp), true, "demotion must survive transient EIO on startup");
  eioBreaker.close();

  // 4. Last watch notification hitting EMFILE on async open self-heals via backoff retry without a 4th exit.
  const emfileDir = join(dir, "emfile-async-read");
  mkdirSync(emfileDir, { recursive: true });
  const emfileFile = join(emfileDir, "pion-demoted.jsonl");
  const emfileOld = new PionCircuitBreaker({ stateFile: emfileFile, watch: false });
  emfileOld.recordUnexpectedExit("packed", stamp, "default", 17_000_000);
  emfileOld.recordUnexpectedExit("packed", stamp, "default", 17_000_010);

  let asyncOpenCalls = 0;
  const flakyOpenAsync: typeof open = (async (...args: Parameters<typeof open>) => {
    asyncOpenCalls++;
    if (asyncOpenCalls === 1) {
      const err = new Error("EMFILE: too many open files") as NodeJS.ErrnoException;
      err.code = "EMFILE";
      throw err;
    }
    return open(...args);
  }) as typeof open;
  const emfileSucc = new PionCircuitBreaker({
    stateFile: emfileFile,
    watch: true,
    readFs: { openAsync: flakyOpenAsync },
  });
  try {
    assert.equal(emfileSucc.isDemoted("packed", stamp), false);
    assert.equal(emfileOld.recordUnexpectedExit("packed", stamp, "default", 17_000_020), true);
    const deadline = Date.now() + 2_000;
    while (!emfileSucc.isDemoted("packed", stamp) && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 15));
    }
    assert.ok(asyncOpenCalls >= 2, "async reader must retry after transient EMFILE");
    assert.equal(emfileSucc.isDemoted("packed", stamp), true, "running instance must self-heal after async open EMFILE without 4th exit");
    await withEnv({ STILLFAIL_MB_READER: mbBin, STILLFAIL_PION_READER: pionBin }, async () => {
      const sel = resolveReaderSelection("packed", {
        config: { channel: "beta", breaker: emfileSucc },
        env: {},
        target: "linux-x64",
        defaultTargetsByChannel: ALL_BETA_POLICY,
      });
      assert.equal(sel.engine, "mb");
      assert.equal(sel.selection.reason, "pion-circuit-breaker");
    });
  } finally {
    emfileOld.close();
    emfileSucc.close();
  }

  // 5. Long-lived runtime sparse crashes (1 every 6 minutes, never demoting) self-compact ownLog < MAX_LOG_BYTES.
  const sparseDir = join(dir, "sparse-runtime");
  mkdirSync(sparseDir, { recursive: true });
  const sparseFile = join(sparseDir, "pion-demoted.jsonl");
  const tSparseStart = Date.now();
  let sparseNow = tSparseStart;
  const sparseBreaker = new PionCircuitBreaker({ stateFile: sparseFile, watch: false, nowFn: () => sparseNow });
  try {
    for (let i = 0; i < 450; i++) {
      sparseNow = tSparseStart + i * 6 * 60_000;
      assert.equal(
        sparseBreaker.recordUnexpectedExit("data", stamp, "default", sparseNow),
        false,
        "sparse 6-min crashes must never trip 5-min breaker",
      );
    }
    assert.equal(sparseBreaker.isDemoted("data", stamp), false);
    const sparseBytes = totalBreakerBytes(sparseDir);
    assert.ok(sparseBytes < MAX_LOG_BYTES, `long-lived sparse crashes must self-compact < 64 KiB (got ${sparseBytes} B)`);
  } finally {
    sparseBreaker.close();
  }
});

test("(k) R7+R8: cross-peer immutable demotion marker + dead-peer reaping, short-write guard (writeSync < buf.length), and cold-start directory-set change re-scan", { skip: skipPosixStubs }, async () => {
  const dir = freshDir("r8-breaker-");
  const mbBin = makeScript(join(dir, "mb-r8"), "#!/bin/sh\nexit 0\n");
  const pionBin = makeScript(join(dir, "pion-r8"), "#!/bin/sh\nexit 1\n");
  const stamp = pionBinaryStamp(pionBin)!;

  // 1. Cross-peer 3-exit demotion publishes immutable `.demoted.*.json` marker + reaps dead-PID expired peer log:
  const crossDir = join(dir, "cross-peer");
  mkdirSync(crossDir, { recursive: true });
  const crossFile = join(crossDir, "pion-demoted.jsonl");
  const now = Date.now();
  const t3 = now - 5_000;
  // Dead PID (99999999) peer log holding 2 exits at t3-298.5s & t3-298s, with expired mtime (> 5 min ago).
  const deadPeerLog = join(crossDir, "pion-demoted.jsonl.p.99999999.dead-peer-uuid.jsonl");
  writeFileSync(
    deadPeerLog,
    `${JSON.stringify({ v: 2, mode: "packed", stamp, at: t3 - 298_500, id: "dead:1" })}\n` +
      `${JSON.stringify({ v: 2, mode: "packed", stamp, at: t3 - 298_000, id: "dead:2" })}\n`,
    "utf8",
  );
  // Set mtime > 6 min ago so dead-peer reaper will unlink it AFTER persisting the immutable marker.
  const oldMtime = new Date(now - 6 * 60_000);
  const { utimesSync } = await import("node:fs");
  utimesSync(deadPeerLog, oldMtime, oldMtime);

  // Live peer log holds the 3rd exit at t3.
  const livePeerLog = join(crossDir, `pion-demoted.jsonl.p.${process.pid}.live-peer-uuid.jsonl`);
  writeFileSync(livePeerLog, `${JSON.stringify({ v: 2, mode: "packed", stamp, at: t3, id: "live:3" })}\n`, "utf8");

  const merger = new PionCircuitBreaker({ stateFile: crossFile, watch: false });
  assert.equal(merger.isDemoted("packed", stamp), true, "cross-peer 3rd exit must trip demotion");
  assert.equal(existsSync(deadPeerLog), false, "expired dead-PID peer log must be reaped after immutable marker is published");
  assert.equal(existsSync(livePeerLog), true, "live-PID peer log must never be unlinked");
  const markers = readdirSync(crossDir).filter((n) => n.startsWith("pion-demoted.jsonl.demoted.") && n.endsWith(".json"));
  assert.equal(markers.length, 1, "immutable demotion marker must be published");
  merger.close();

  // Even after removing livePeerLog too, immutable marker alone keeps cold-start demoted -> "mb"!
  unlinkSync(livePeerLog);
  const coldAfterMarker = new PionCircuitBreaker({ stateFile: crossFile, watch: false });
  assert.equal(coldAfterMarker.isDemoted("packed", stamp), true, "immutable marker must survive peer log cleanup");
  await withEnv({ STILLFAIL_MB_READER: mbBin, STILLFAIL_PION_READER: pionBin }, async () => {
    const sel = resolveReaderSelection("packed", {
      config: { channel: "beta", breaker: coldAfterMarker },
      env: {},
      target: "linux-x64",
      defaultTargetsByChannel: ALL_BETA_POLICY,
    });
    assert.equal(sel.engine, "mb");
    assert.equal(sel.selection.reason, "pion-circuit-breaker");
  });
  coldAfterMarker.close();

  // 2. Short write protection (Astra R7 P1 #4): writeSync writes only 126 bytes then returns 0 -> flushPending returns false,
  // preserves #pendingEvents, and after recovery writes the complete record so cold-start selects "mb".
  const swDir = join(dir, "short-write");
  mkdirSync(swDir, { recursive: true });
  const swFile = join(swDir, "pion-demoted.jsonl");
  const tSw = Date.now();
  let swCalls = 0;
  let injectShortWrite = false;
  const swBreaker = new PionCircuitBreaker({
    stateFile: swFile,
    watch: false,
    writeFs: {
      openSync,
      closeSync,
      writeSync: ((fd: number, buf: Buffer, offset?: number, length?: number) => {
        if (injectShortWrite) {
          swCalls++;
          if (swCalls === 1) {
            const partialLen = Math.min(126, length ?? buf.length);
            return writeSync(fd, buf, offset ?? 0, partialLen);
          }
          if (swCalls === 2) return 0; // simulate short write stall -> must abort & preserve #pendingEvents!
        }
        return writeSync(fd, buf, offset ?? 0, length ?? buf.length);
      }) as typeof writeSync,
    },
  });
  assert.equal(swBreaker.recordUnexpectedExit("packed", stamp, "default", tSw - 20), false);
  assert.equal(swBreaker.recordUnexpectedExit("packed", stamp, "default", tSw - 10), false);
  injectShortWrite = true;
  assert.equal(swBreaker.recordUnexpectedExit("packed", stamp, "default", tSw), true, "3rd exit trips in-memory demotion");
  assert.equal(swCalls, 2, "short-write loop should have retried once and aborted on 0-byte return");
  // Before recovery, cold-start does NOT yet see demotion (3rd record was torn/unflushed).
  const coldBeforeRecovery = new PionCircuitBreaker({ stateFile: swFile, watch: false });
  assert.equal(coldBeforeRecovery.isDemoted("packed", stamp), false);
  coldBeforeRecovery.close();
  // Recovery: flushPending() (or close()) writes the full preserved pending event + publishes immutable marker!
  injectShortWrite = false;
  swBreaker.close();
  const coldAfterShortWriteRecovery = new PionCircuitBreaker({ stateFile: swFile, watch: false });
  assert.equal(coldAfterShortWriteRecovery.isDemoted("packed", stamp), true, "preserved pending 3rd exit must flush on recovery");
  await withEnv({ STILLFAIL_MB_READER: mbBin, STILLFAIL_PION_READER: pionBin }, async () => {
    const sel = resolveReaderSelection("packed", {
      config: { channel: "beta", breaker: coldAfterShortWriteRecovery },
      env: {},
      target: "linux-x64",
      defaultTargetsByChannel: ALL_BETA_POLICY,
    });
    assert.equal(sel.engine, "mb");
    assert.equal(sel.selection.reason, "pion-circuit-breaker");
  });
  coldAfterShortWriteRecovery.close();

  // 3. Cold-start (watch: false) directory-set change re-scan (Astra R7 P1 #3):
  // While cold-start opens an existing peer log, another process creates a brand-new immutable `.demoted.*.json` marker
  // (changing `afterNames !== beforeNames`); cold-start must detect the new file and re-scan so first selection returns "mb"!
  const rescanDir = join(dir, "cold-dir-rescan");
  mkdirSync(rescanDir, { recursive: true });
  const rescanFile = join(rescanDir, "pion-demoted.jsonl");
  const initialPeerLog = join(rescanDir, `pion-demoted.jsonl.p.${process.pid}.initial-peer.jsonl`);
  writeFileSync(initialPeerLog, `${JSON.stringify({ v: 2, mode: "packed", stamp, at: Date.now() - 1_000, id: "rs:1" })}\n`, "utf8");
  const concurrentMarker = join(rescanDir, "pion-demoted.jsonl.demoted.0123456789abcdef.json");
  const markerPayload = `${JSON.stringify({ v: 2, mode: "packed", stamp, demotedAt: Date.now() })}\n`;

  let injectedMarker = false;
  const rescanCold = new PionCircuitBreaker({
    stateFile: rescanFile,
    watch: false,
    readFs: {
      openSync: ((...args: Parameters<typeof openSync>) => {
        const target = String(args[0]);
        if (!injectedMarker && target === initialPeerLog) {
          injectedMarker = true;
          writeFileSync(concurrentMarker, markerPayload, "utf8");
        }
        return openSync(...args);
      }) as typeof openSync,
    },
  });
  assert.equal(injectedMarker, true, "cold-start openSync must have triggered concurrent marker creation");
  assert.equal(rescanCold.isDemoted("packed", stamp), true, "cold-start must detect directory-set change and re-scan new marker");
  await withEnv({ STILLFAIL_MB_READER: mbBin, STILLFAIL_PION_READER: pionBin }, async () => {
    const sel = resolveReaderSelection("packed", {
      config: { channel: "beta", breaker: rescanCold },
      env: {},
      target: "linux-x64",
      defaultTargetsByChannel: ALL_BETA_POLICY,
    });
    assert.equal(sel.engine, "mb");
    assert.equal(sel.selection.reason, "pion-circuit-breaker");
  });
  rescanCold.close();
});

test("(l) R9: EIO read skips dead-peer reap, marker publish failure aborts ownLog compaction & dead-peer reap, and bindEpoch isolates configure(A)->configure(B)", { skip: skipPosixStubs }, async () => {
  const dir = freshDir("r9-breaker-");
  const pionBin = makeScript(join(dir, "pion-r9"), "#!/bin/sh\nexit 1\n");
  const stamp = pionBinaryStamp(pionBin)!;
  const { utimesSync } = await import("node:fs");
  const now = Date.now();
  const oldMtime = new Date(now - 6 * 60_000);

  // 1. EIO during initial scan must NOT reap dead-PID expired peer logs (fullScanClean === false).
  const eioDir = join(dir, "eio-no-reap");
  mkdirSync(eioDir, { recursive: true });
  const eioFile = join(eioDir, "pion-demoted.jsonl");
  const deadLog1 = join(eioDir, "pion-demoted.jsonl.p.99999998.dead-eio.jsonl");
  writeFileSync(
    deadLog1,
    `${JSON.stringify({ v: 2, mode: "packed", stamp, at: now - 303_500, id: "de:1" })}\n` +
      `${JSON.stringify({ v: 2, mode: "packed", stamp, at: now - 303_000, id: "de:2" })}\n`,
    "utf8",
  );
  utimesSync(deadLog1, oldMtime, oldMtime);
  const eioReader = new PionCircuitBreaker({
    stateFile: eioFile,
    watch: false,
    readFs: {
      openSync: (() => {
        const err = new Error("EIO: read error") as NodeJS.ErrnoException;
        err.code = "EIO";
        throw err;
      }) as typeof openSync,
    },
  });
  assert.equal(existsSync(deadLog1), true, "dead-peer log must NOT be reaped when scan encountered EIO");
  eioReader.close();

  // 2. Marker publish failure with fullScanClean === true (writable 0o755 dir, zero blocking directories,
  // pure publishFs.renameSync ENOSPC injection) aborts BOTH dead-peer reaping AND ownLog self-compaction!
  const failMarkerRename: typeof renameSync = ((src: Parameters<typeof renameSync>[0], dst: Parameters<typeof renameSync>[1]) => {
    if (String(dst).includes(".demoted.")) {
      const err = new Error("ENOSPC: no space left on device") as NodeJS.ErrnoException;
      err.code = "ENOSPC";
      throw err;
    }
    return renameSync(src, dst);
  }) as typeof renameSync;

  const roDir = join(dir, "ro-marker-fail");
  mkdirSync(roDir, { recursive: true });
  const roFile = join(roDir, "pion-demoted.jsonl");
  const deadLog2 = join(roDir, "pion-demoted.jsonl.p.99999997.dead-ro.jsonl");
  writeFileSync(
    deadLog2,
    `${JSON.stringify({ v: 2, mode: "packed", stamp, at: now - 303_500, id: "dro:1" })}\n` +
      `${JSON.stringify({ v: 2, mode: "packed", stamp, at: now - 303_000, id: "dro:2" })}\n` +
      `${JSON.stringify({ v: 2, mode: "packed", stamp, at: now - 302_500, id: "dro:3" })}\n`,
    "utf8",
  );
  utimesSync(deadLog2, oldMtime, oldMtime);
  const roBreaker = new PionCircuitBreaker({ stateFile: roFile, watch: false, publishFs: { renameSync: failMarkerRename } });
  assert.equal(roBreaker.isDemoted("packed", stamp), true);
  assert.equal(existsSync(deadLog2), true, "dead-peer log must NOT be reaped when fullScanClean===true but marker renameSync fails");
  roBreaker.close();

  // Also verify ownLog self-compaction aborts when fullScanClean===true but marker renameSync fails:
  const roOwnDir = join(dir, "ro-own-compact");
  mkdirSync(roOwnDir, { recursive: true });
  const roOwnFile = join(roOwnDir, "pion-demoted.jsonl");
  const ownInst = new PionCircuitBreaker({ stateFile: roOwnFile, watch: false, publishFs: { renameSync: failMarkerRename } });
  const ownLog = ownInst.ownLogPath()!;
  const pad: string[] = [];
  for (let i = 0; i < 420; i++) {
    pad.push(JSON.stringify({ v: 2, mode: "memory", stamp, at: 1_000_000 + i * 400_000, id: `ro-pad:${i}` }));
  }
  pad.push(JSON.stringify({ v: 2, mode: "packed", stamp, at: now - 2_000, id: "ro-own:1" }));
  pad.push(JSON.stringify({ v: 2, mode: "packed", stamp, at: now - 1_000, id: "ro-own:2" }));
  writeFileSync(ownLog, `${pad.join("\n")}\n`, "utf8");
  const preSize = statSync(ownLog).size;
  assert.ok(preSize > MAX_LOG_BYTES);
  assert.equal(ownInst.recordUnexpectedExit("packed", stamp, "default", now), true);
  assert.ok(statSync(ownLog).size >= preSize, "ownLog must NOT be compacted/emptied when fullScanClean===true but marker renameSync fails");
  ownInst.close();

  // 2b. Peer log EIO during recordUnexpectedExit must abort ownLog self-compaction (fullScanClean === false, Astra R9 P1 #1):
  const peerEioDir = join(dir, "peer-eio-no-compact");
  mkdirSync(peerEioDir, { recursive: true });
  const peerEioFile = join(peerEioDir, "pion-demoted.jsonl");
  const badPeerLog = join(peerEioDir, "pion-demoted.jsonl.p.99999996.bad-peer.jsonl");
  writeFileSync(badPeerLog, `${JSON.stringify({ v: 2, mode: "data", stamp, at: now - 1_000, id: "bp:1" })}\n`, "utf8");
  const peerEioInst = new PionCircuitBreaker({
    stateFile: peerEioFile,
    watch: false,
    readFs: {
      openSync: ((...args: Parameters<typeof openSync>) => {
        if (String(args[0]) === badPeerLog) {
          const err = new Error("EIO: peer log unreadable") as NodeJS.ErrnoException;
          err.code = "EIO";
          throw err;
        }
        return openSync(...args);
      }) as typeof openSync,
    },
  });
  const peerEioOwnLog = peerEioInst.ownLogPath()!;
  const pad2: string[] = [];
  for (let i = 0; i < 420; i++) {
    pad2.push(JSON.stringify({ v: 2, mode: "memory", stamp, at: 1_000_000 + i * 400_000, id: `pe-pad:${i}` }));
  }
  writeFileSync(peerEioOwnLog, `${pad2.join("\n")}\n`, "utf8");
  const prePeerEioSize = statSync(peerEioOwnLog).size;
  assert.ok(prePeerEioSize > MAX_LOG_BYTES);
  assert.equal(peerEioInst.recordUnexpectedExit("data", stamp, "default", now), false);
  assert.ok(statSync(peerEioOwnLog).size >= prePeerEioSize, "ownLog must NOT self-compact when a peer log read hit EIO");
  peerEioInst.close();

  // 3. In-flight async read from directory A paused on openAsync must NOT pollute directory B after configure(B).
  const dirA = join(dir, "epoch-a");
  const dirB = join(dir, "epoch-b");
  mkdirSync(dirA, { recursive: true });
  mkdirSync(dirB, { recursive: true });
  const fileA = join(dirA, "pion-demoted.jsonl");
  const fileB = join(dirB, "pion-demoted.jsonl");

  let releaseOpenA!: () => void;
  let openAHit!: () => void;
  const openAGate = new Promise<void>((res) => {
    releaseOpenA = res;
  });
  const openAHitPromise = new Promise<void>((res) => {
    openAHit = res;
  });
  let pausedA = false;

  const epochBreaker = new PionCircuitBreaker({
    stateFile: fileA,
    watch: true,
    readFs: {
      openAsync: (async (...args: Parameters<typeof open>) => {
        const p = String(args[0]);
        if (!pausedA && p.startsWith(dirA)) {
          pausedA = true;
          openAHit();
          await openAGate;
        }
        return open(...args);
      }) as typeof open,
    },
  });
  try {
    // Trigger watch event in dirA with a demoted record.
    writeFileSync(fileA, `${JSON.stringify({ v: 2, mode: "packed", stamp, demotedAt: now })}\n`, "utf8");
    await Promise.race([openAHitPromise, new Promise((_, rej) => setTimeout(() => rej(new Error("openA never hit")), 2_000))]);
    // Rebind to clean dirB while dirA's openAsync is suspended!
    epochBreaker.configure(fileB, { watch: false });
    releaseOpenA();
    await new Promise((r) => setTimeout(r, 50));
    assert.equal(epochBreaker.isDemoted("packed", stamp), false, "stale dirA async read must NOT pollute dirB state");
    assert.equal(
      readdirSync(dirB).filter((n) => n.startsWith("pion-demoted.jsonl.demoted.")).length,
      0,
      "stale dirA async read must NOT publish demotion marker into dirB",
    );
  } finally {
    releaseOpenA();
    epochBreaker.close();
  }

  // 4. R11 P1 regression (Astra R10 counterexample): dead peer log has exit #1 with mtime = T0 - windowMs + 10ms;
  // two live peer logs start empty, and during round 0 (after last file is opened, before post-scan stat check)
  // exits #2 & #3 are appended to the live peers while clock advances +30ms past dead peer's expiry ->
  // full-input metadata check detects the concurrent appends, re-scans round 1, publishes permanent marker, and cold-start selects "mb"!
  const r11Dir = join(dir, "r11-scan-consistency");
  mkdirSync(r11Dir, { recursive: true });
  const r11File = join(r11Dir, "pion-demoted.jsonl");
  const mbBin = makeScript(join(dir, "mb-r11"), "#!/bin/sh\nexit 0\n");
  const windowMs = 300_000;
  const t0 = now;
  let fakeNow = t0;
  const deadBoundary = join(r11Dir, "pion-demoted.jsonl.p.99999995.dead-boundary.jsonl");
  const livePeerA = join(r11Dir, `pion-demoted.jsonl.p.${process.pid}.peer-a.jsonl`);
  const livePeerB = join(r11Dir, `pion-demoted.jsonl.p.${process.pid}.peer-b.jsonl`);
  writeFileSync(
    deadBoundary,
    `${JSON.stringify({ v: 2, mode: "packed", stamp, at: t0 - 299_990, id: "r11:1" })}\n`,
    "utf8",
  );
  const boundaryMtime = new Date(t0 - windowMs + 10);
  utimesSync(deadBoundary, boundaryMtime, boundaryMtime);
  writeFileSync(livePeerA, "", "utf8");
  writeFileSync(livePeerB, "", "utf8");

  let r11Round0Opens = 0;
  let injectedConcurrentAppends = false;
  const r11Breaker = new PionCircuitBreaker({
    stateFile: r11File,
    windowMs,
    watch: false,
    nowFn: () => fakeNow,
    readFs: {
      openSync: ((...args: Parameters<typeof openSync>) => {
        const fd = openSync(...args);
        r11Round0Opens++;
        // Round 0 opens 3 files: deadBoundary, livePeerA, livePeerB (sorted). On the 3rd open, append exits #2 and #3 and advance clock +30ms!
        if (!injectedConcurrentAppends && r11Round0Opens === 3) {
          injectedConcurrentAppends = true;
          writeFileSync(livePeerA, `${JSON.stringify({ v: 2, mode: "packed", stamp, at: t0 - 1_000, id: "r11:2" })}\n`, "utf8");
          writeFileSync(livePeerB, `${JSON.stringify({ v: 2, mode: "packed", stamp, at: t0, id: "r11:3" })}\n`, "utf8");
          fakeNow = t0 + 30;
        }
        return fd;
      }) as typeof openSync,
    },
  });
  assert.equal(injectedConcurrentAppends, true);
  assert.ok(r11Round0Opens >= 6, `must detect concurrent peer appends and re-scan round 1 (opens=${r11Round0Opens})`);
  assert.equal(r11Breaker.isDemoted("packed", stamp), true, "re-scan must merge all 3 exits and trip demotion");
  assert.ok(
    readdirSync(r11Dir).some((n) => n.startsWith("pion-demoted.jsonl.demoted.") && n.endsWith(".json")),
    "permanent demotion marker must be published after re-scan",
  );
  r11Breaker.close();

  const coldR11 = new PionCircuitBreaker({ stateFile: r11File, windowMs, watch: false, nowFn: () => t0 + 60_000 });
  assert.equal(coldR11.isDemoted("packed", stamp), true, "cold-start must observe published marker");
  await withEnv({ STILLFAIL_MB_READER: mbBin, STILLFAIL_PION_READER: pionBin }, async () => {
    const sel = resolveReaderSelection("packed", {
      config: { channel: "beta", breaker: coldR11 },
      env: {},
      target: "linux-x64",
      defaultTargetsByChannel: ALL_BETA_POLICY,
    });
    assert.equal(sel.engine, "mb");
    assert.equal(sel.selection.reason, "pion-circuit-breaker");
  });
  coldR11.close();

  // 5. R12 P1 #1 regression (self-compaction cutoff uses syncRes.scannedNowMs, never wall.now() or other-mode maxEventAt):
  // ownLog has packed exit #1 at T - 299_990ms plus >64 KiB expired padding; clock advances to T + 30ms before compaction
  // while two peers receive packed exits #2 & #3 at T -> self-compaction MUST keep packed exit #1 (using scannedNowMs = T),
  // so cold-start merges all 3 and selects "mb"!
  const r12ADir = join(dir, "r12-compact-cutoff");
  mkdirSync(r12ADir, { recursive: true });
  const r12AFile = join(r12ADir, "pion-demoted.jsonl");
  const t12A = now;
  let clock12A = t12A;
  const peer12A1 = join(r12ADir, `pion-demoted.jsonl.p.${process.pid}.r12a-p1.jsonl`);
  const peer12A2 = join(r12ADir, `pion-demoted.jsonl.p.${process.pid}.r12a-p2.jsonl`);
  writeFileSync(peer12A1, "", "utf8");
  writeFileSync(peer12A2, "", "utf8");

  const inst12A = new PionCircuitBreaker({
    stateFile: r12AFile,
    windowMs,
    watch: false,
    nowFn: () => clock12A,
  });
  // Record packed exit #1 at T - 299_990ms via inst12A (so it belongs to inst12A's ownLog with inst12A's instanceId prefix).
  assert.equal(inst12A.recordUnexpectedExit("packed", stamp, "default", t12A - 299_990), false);
  // Pad ownLog past MAX_LOG_BYTES with expired memory events so the next recordUnexpectedExit triggers self-compaction.
  const own12A = inst12A.ownLogPath()!;
  const pad12A: string[] = [readFileSync(own12A, "utf8").trimEnd()];
  for (let i = 0; i < 420; i++) {
    pad12A.push(JSON.stringify({ v: 2, mode: "memory", stamp, at: 1_000_000 + i * 400_000, id: `r12a-pad:${i}` }));
  }
  writeFileSync(own12A, `${pad12A.join("\n")}\n`, "utf8");
  assert.ok(statSync(own12A).size > MAX_LOG_BYTES);

  // Trigger a `data` exit at T + 30ms while scannedNowMs is pinned at T (clock12A = t12A during scan):
  // If cutoff used maxEventAt (T + 30ms) instead of scannedNowMs (T), packed exit #1 (T - 299_990ms) would be pruned!
  assert.equal(inst12A.recordUnexpectedExit("data", stamp, "default", t12A + 30), false);
  // Assert BEFORE inst12A.close() that compacted ownLog still contains packed exit #1 AND cold12A selects "mb"
  // (so inst12A.close() cannot mask an ownLog compaction pruning regression).
  assert.ok(statSync(own12A).size < MAX_LOG_BYTES, "ownLog should have been self-compacted below 64 KiB");
  const compactedOwnText = readFileSync(own12A, "utf8");
  assert.ok(
    compactedOwnText.includes(`"mode":"packed"`) && compactedOwnText.includes(`"at":${t12A - 299_990}`),
    "compacted ownLog must preserve packed exit #1 relative to scannedNowMs=T before close()",
  );
  // Now write packed exits #2 & #3 to the two peer logs at T, and verify cold-start BEFORE inst12A.close()!
  clock12A = t12A + 30;
  writeFileSync(peer12A1, `${JSON.stringify({ v: 2, mode: "packed", stamp, at: t12A, id: "r12a:2" })}\n`, "utf8");
  writeFileSync(peer12A2, `${JSON.stringify({ v: 2, mode: "packed", stamp, at: t12A, id: "r12a:3" })}\n`, "utf8");

  const cold12A = new PionCircuitBreaker({ stateFile: r12AFile, windowMs, watch: false, nowFn: () => t12A + 60_000 });
  assert.equal(cold12A.isDemoted("packed", stamp), true, "cold-start before inst12A.close() must merge exit #1 from compacted ownLog");
  await withEnv({ STILLFAIL_MB_READER: mbBin, STILLFAIL_PION_READER: pionBin }, async () => {
    const sel = resolveReaderSelection("packed", {
      config: { channel: "beta", breaker: cold12A },
      env: {},
      target: "linux-x64",
      defaultTargetsByChannel: ALL_BETA_POLICY,
    });
    assert.equal(sel.engine, "mb");
    assert.equal(sel.selection.reason, "pion-circuit-breaker");
  });
  cold12A.close();
  inst12A.close();

  // 6. R12+R13 P1 #2 regression (reap dead-peer log FIRST, then A.close() & B.close() flush pending exits #2 & #3,
  // with B's first close() hitting transient EMFILE on A's log -> returns false -> second close() returns true and publishes marker!):
  const r12BDir = join(dir, "r12-close-merge-after-reap");
  mkdirSync(r12BDir, { recursive: true });
  const r12BFile = join(r12BDir, "pion-demoted.jsonl");
  const t12B = now;
  const dead12B = join(r12BDir, "pion-demoted.jsonl.p.99999994.dead-r12b.jsonl");
  writeFileSync(
    dead12B,
    `${JSON.stringify({ v: 2, mode: "packed", stamp, at: t12B - 299_990, id: "r12b:1" })}\n`,
    "utf8",
  );
  const dead12BMtime = new Date(t12B - 299_990);
  utimesSync(dead12B, dead12BMtime, dead12BMtime);

  let blockWrites12B = true;
  const enospcWriteFs = {
    openSync,
    closeSync,
    writeSync: ((...args: Parameters<typeof writeSync>) => {
      if (blockWrites12B) {
        const err = new Error("ENOSPC: no space left on device") as NodeJS.ErrnoException;
        err.code = "ENOSPC";
        throw err;
      }
      return writeSync(...args);
    }) as typeof writeSync,
  };

  const instA12B = new PionCircuitBreaker({ stateFile: r12BFile, windowMs, watch: false, nowFn: () => t12B, writeFs: enospcWriteFs });
  const aOwnLogPath = instA12B.ownLogPath()!;
  let armBCloseEmfile = false;
  let injectedBCloseEmfile = false;
  const instB12B = new PionCircuitBreaker({
    stateFile: r12BFile,
    windowMs,
    watch: false,
    nowFn: () => t12B,
    writeFs: enospcWriteFs,
    readFs: {
      openSync: ((...args: Parameters<typeof openSync>) => {
        if (armBCloseEmfile && !injectedBCloseEmfile && String(args[0]) === aOwnLogPath) {
          injectedBCloseEmfile = true;
          const err = new Error("EMFILE: too many open files") as NodeJS.ErrnoException;
          err.code = "EMFILE";
          throw err;
        }
        return openSync(...args);
      }) as typeof openSync,
    },
  });
  // Both A and B have exit #1 in memory; now each hits ENOSPC recording exits #2 and #3 at T.
  assert.equal(instA12B.recordUnexpectedExit("packed", stamp, "default", t12B), false);
  assert.equal(instB12B.recordUnexpectedExit("packed", stamp, "default", t12B), false);

  // At T + 30ms, instance C scans cleanly and reaps the expired dead peer log!
  const instC12B = new PionCircuitBreaker({ stateFile: r12BFile, windowMs, watch: false, nowFn: () => t12B + 30 });
  assert.equal(existsSync(dead12B), false, "instance C must have reaped expired dead peer log at T + 30ms");
  instC12B.close();

  // Now ENOSPC clears and A.close() succeeds; B is released through the production Effect.scoped +
  // releasePionCircuitBreaker callback while its 1st close() hits transient EMFILE reading A's log ->
  // releasePionCircuitBreaker automatically retries within that single scope release, merges A's exit #2
  // with in-memory exit #1 & #3, and publishes the permanent demotion marker!
  blockWrites12B = false;
  assert.equal(instA12B.close(), true);
  armBCloseEmfile = true;
  let releaseSucceeded = false;
  await Effect.runPromise(
    Effect.scoped(
      Effect.acquireRelease(
        Effect.succeed(instB12B),
        (b) =>
          Effect.map(releasePionCircuitBreaker(b, { retryDelayMs: 5 }), (ok) => {
            releaseSucceeded = ok;
          }),
      ),
    ),
  );
  assert.equal(injectedBCloseEmfile, true, "1st close() inside scope release must have hit transient EMFILE");
  assert.equal(releaseSucceeded, true, "single production scope release must retry and succeed once EMFILE clears");
  assert.equal(instB12B.close(), true, "subsequent close() calls remain idempotent no-ops returning true");

  // Minimal direct unit check for close() === false on transient EMFILE and bounded retry exhaustion:
  const r14UnitDir = join(dir, "r14-close-false-unit");
  mkdirSync(r14UnitDir, { recursive: true });
  const r14UnitFile = join(r14UnitDir, "pion-demoted.jsonl");
  const r14Peer = new PionCircuitBreaker({ stateFile: r14UnitFile, windowMs, watch: false, nowFn: () => t12B });
  const r14PeerLog = r14Peer.ownLogPath()!;
  r14Peer.recordUnexpectedExit("packed", stamp, "default", t12B);
  r14Peer.close();
  let r14BlockOpen = true;
  const r14Direct = new PionCircuitBreaker({
    stateFile: r14UnitFile,
    windowMs,
    watch: false,
    nowFn: () => t12B,
    readFs: {
      openSync: ((...args: Parameters<typeof openSync>) => {
        if (r14BlockOpen && String(args[0]) === r14PeerLog) {
          const err = new Error("EMFILE: too many open files") as NodeJS.ErrnoException;
          err.code = "EMFILE";
          throw err;
        }
        return openSync(...args);
      }) as typeof openSync,
    },
  });
  assert.equal(r14Direct.close(), false, "direct close() must return false while peer log hits EMFILE");
  assert.equal(
    await Effect.runPromise(releasePionCircuitBreaker(r14Direct, { maxAttempts: 2, retryDelayMs: 2 })),
    false,
    "releasePionCircuitBreaker must return false when retries are exhausted",
  );
  r14BlockOpen = false;
  assert.equal(
    await Effect.runPromise(releasePionCircuitBreaker(r14Direct, { maxAttempts: 2, retryDelayMs: 2 })),
    true,
    "releasePionCircuitBreaker must return true once transient EMFILE clears",
  );

  assert.ok(
    readdirSync(r12BDir).some((n) => n.startsWith("pion-demoted.jsonl.demoted.") && n.endsWith(".json")),
    "B.close() must merge A's flushed exit with in-memory exit #1 & #3 and publish permanent demotion marker",
  );
  const cold12B = new PionCircuitBreaker({ stateFile: r12BFile, windowMs, watch: false, nowFn: () => t12B + 60_000 });
  assert.equal(cold12B.isDemoted("packed", stamp), true, "cold-start must observe permanent marker after A.close() & B.close()");
  await withEnv({ STILLFAIL_MB_READER: mbBin, STILLFAIL_PION_READER: pionBin }, async () => {
    const sel = resolveReaderSelection("packed", {
      config: { channel: "beta", breaker: cold12B },
      env: {},
      target: "linux-x64",
      defaultTargetsByChannel: ALL_BETA_POLICY,
    });
    assert.equal(sel.engine, "mb");
    assert.equal(sel.selection.reason, "pion-circuit-breaker");
  });
  cold12B.close();
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
