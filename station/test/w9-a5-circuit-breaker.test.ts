// Deterministic regression tests for the W9-A5a default-only Pion crash circuit breaker:
// (a) Binary A -> B replacement: late exit of A never demotes B.
// (b) Explicit Pion (config/env) exits never contaminate default counters.
// (c) Early unexpected exits + simulated Node handover reloading `<data>/run/pion-demoted.json` stays demoted.
// (d) Binary stamp change on disk automatically clears demotion and resumes default Pion.
// (e) When no MB binary exists, demoted mode warns and stays safely on Pion without throwing.
// (f) Completely independent of `readerTelemetry`'s 600s window flush.
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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
  const stateFile = join(dir, "run", "pion-demoted.json");
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
  const stateFile = join(dir, "run", "pion-demoted.json");
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
  assert.equal(existsSync(stateFile), false, "explicit exits must never create pion-demoted.json");

  // Default counter still requires full K=3 exits from scratch.
  assert.equal(breaker.recordUnexpectedExit("data", stamp, "default", t0 + 10_000), false);
  assert.equal(breaker.recordUnexpectedExit("data", stamp, "default", t0 + 11_000), false);
  assert.equal(breaker.isDemoted("data", stamp), false);
  assert.equal(breaker.recordUnexpectedExit("data", stamp, "default", t0 + 12_000), true);
  assert.equal(breaker.isDemoted("data", stamp), true);
});

test("(c)+(d)+(f) real MbProcess default crashes trip breaker, survive Node handover reload, stay independent of telemetry flush, and recover on stamp change", { skip: skipPosixStubs }, async () => {
  const dir = freshDir("handover-");
  const stateFile = join(dir, "run", "pion-demoted.json");
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

    assert.equal(existsSync(stateFile), true, "pion-demoted.json must be atomically persisted");
    const persisted = JSON.parse(readFileSync(stateFile, "utf8")) as { v: number; demoted: Record<string, unknown> };
    assert.equal(persisted.v, 1);
    assert.ok(persisted.demoted.packed, "packed mode must be persisted in pion-demoted.json");

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

    // (d) Upgrade binary on disk (different size/mtime) -> demotion automatically clears!
    makeScript(pionBin, "#!/bin/sh\necho upgraded-binary-v2\nexit 0\n");
    const afterUpgrade = resolveReaderSelection("packed", selOpts);
    assert.equal(afterUpgrade.engine, "pion");
    assert.equal(afterUpgrade.selection.fallback, false);
    assert.equal(pionCircuitBreaker.demotedEntry("packed"), null);
  });
});

test("(e) demoted mode with no MB binary logs warn and stays safely on Pion without throwing", { skip: skipPosixStubs }, async () => {
  const dir = freshDir("no-mb-");
  const stateFile = join(dir, "run", "pion-demoted.json");
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
