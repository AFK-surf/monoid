// Unit and OTel log-export integration tests for `station/src/read/reader-telemetry.ts`.
import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { LogExport, record } from "../src/ops/log-export.ts";
import { type Line, hearLines } from "../src/ops/log.ts";
import { type ProcessInfo, isBackgroundWrapperExecFailure, isBackgroundWrapperStderrLine } from "../src/platform/index.ts";
import { ArchiveMarkBuilder } from "../src/read/archive-mark-builder.ts";
import {
  type LiveProgram,
  MbProcess,
  MbReader,
  resetReaderSelectionStateForTest,
  setMbReaderBinaryOverrideForTest,
} from "../src/read/mb-reader.ts";
import { Readers } from "../src/read/pool.ts";
import {
  DEFAULT_MAX_SAMPLES,
  ReaderTelemetry,
  classifyProgram,
  programsByEngineMode,
  readerTelemetry,
} from "../src/read/reader-telemetry.ts";
import { ProgramRunner } from "../src/replica/runner.ts";
import {
  measured,
  triggerShadowDeadlineForTest,
  waitForShadowDeadlineArmedForTest,
  waitForShadowMeasures,
} from "../src/sessions/footprint.ts";
import { MinuteReader } from "../src/usage/minute-reader.ts";

const KiB = 1024;
const MiB = 1024 * 1024;
const unix = process.platform !== "win32";
const attrsOf = (r: ReturnType<typeof record>) =>
  Object.fromEntries(r.attributes.map((a) => [a.key, Object.values(a.value)[0]]));
const rawAttrsOf = (r: ReturnType<typeof record>) =>
  Object.fromEntries(r.attributes.map((a) => [a.key, a.value]));

function makeFakeExecutable(dir: string, filename: string, jsBody: string): string {
  const scriptPath = join(dir, `${filename}.mjs`);
  writeFileSync(scriptPath, jsBody);
  if (unix) {
    const binPath = join(dir, filename);
    writeFileSync(binPath, `#!/bin/sh\nexec ${JSON.stringify(process.execPath)} ${JSON.stringify(scriptPath)} "$@"\n`);
    chmodSync(binPath, 0o755);
    return binPath;
  }
  const cmdPath = join(dir, `${filename}.cmd`);
  writeFileSync(cmdPath, `@echo off\r\n"${process.execPath}" "${scriptPath}" %*\r\n`);
  return cmdPath;
}

test("classifyProgram classifies Unix/Windows paths, .exe, pion vs mb, and all modes", () => {
  assert.deepEqual(
    classifyProgram("/opt/stillfail/stillfail-pion", ["--builder", "replica-export", "--db", "/tmp/a.db"]),
    { engine: "pion", mode: "replica-export" },
  );
  assert.deepEqual(
    classifyProgram("C:\\Program Files\\stillfail\\stillfail-pion.exe", ["--data", "C:\\data"]),
    { engine: "pion", mode: "data" },
  );
  assert.deepEqual(
    classifyProgram("/srv/bin/stillfail-pion-linux-x64", ["--builder", "usage-counter"]),
    { engine: "pion", mode: "usage-counter" },
  );
  assert.deepEqual(
    classifyProgram("/usr/local/bin/stillfail-reader", ["--serve", "--port", "0"]),
    { engine: "mb", mode: "serve" },
  );
  assert.deepEqual(
    classifyProgram("C:\\stillfail\\stillfail-reader.EXE", ["--sessions", "1", "--data", "C:\\d"]),
    { engine: "mb", mode: "sessions" },
  );
  assert.deepEqual(
    classifyProgram("/usr/local/bin/stillfail-reader", ["--builder", "footprint", "--sep", "/"]),
    { engine: "mb", mode: "footprint" },
  );
  assert.deepEqual(
    classifyProgram("/usr/local/bin/stillfail-reader", ["--builder"]),
    { engine: "mb", mode: "other" },
  );
  assert.deepEqual(
    classifyProgram("/bin/sleep", ["30"]),
    { engine: "mb", mode: "other" },
  );
});

test("ReaderTelemetry computes p50/p95/max/avg, bounds sample memory at 512, and resets on flushWindow", () => {
  const t = new ReaderTelemetry({ nowMs: 1_000 });

  for (let i = 1; i <= 5_000; i++) {
    t.recordCall("pion", "data", i, i % 100 !== 0);
  }
  assert.equal(t.sampleCountForTest("pion", "data"), DEFAULT_MAX_SAMPLES);

  t.recordReady("pion", "data", 120, 40, 80);
  t.recordReady("pion", "data", 200, 60, 140);
  t.recordSpawn("pion", "data");
  t.recordFallback("search");

  const summaries = t.flushWindow(601_000);
  assert.equal(summaries.length, 2);

  const dataSummary = summaries.find((s) => s.engine === "pion" && s.mode === "data")!;
  assert.ok(dataSummary);
  assert.equal(dataSummary.windowSec, 600);
  assert.equal(dataSummary.spawns, 1);
  assert.equal(dataSummary.ops, 5_000);
  assert.equal(dataSummary.errors, 50);
  assert.equal(dataSummary.maxMs, 5_000);
  assert.equal(dataSummary.avgMs, 2_501);
  assert.ok(dataSummary.p50Ms! >= 2_100 && dataSummary.p50Ms! <= 2_900, `p50Ms=${dataSummary.p50Ms}`);
  assert.ok(dataSummary.p95Ms! >= 4_400 && dataSummary.p95Ms! <= 4_950, `p95Ms=${dataSummary.p95Ms}`);
  assert.equal(dataSummary.readyCount, 2);
  assert.equal(dataSummary.readyP50Ms, 120);
  assert.equal(dataSummary.readyMaxMs, 200);
  assert.equal(dataSummary.loadedP50Ms, 40);
  assert.equal(dataSummary.openedP50Ms, 80);
  assert.equal(dataSummary.engineRssKb, undefined);
  assert.equal(dataSummary.enginePeakRssKb, undefined);

  const searchSummary = summaries.find((s) => s.engine === "pion" && s.mode === "search")!;
  assert.ok(searchSummary);
  assert.equal(searchSummary.fallbacks, 1);
  assert.equal(searchSummary.p50Ms, undefined);
  assert.equal(searchSummary.readyP50Ms, undefined);

  assert.deepEqual(t.flushWindow(1_201_000), []);
});

test("programsByEngineMode attributes descendant trees without double counting, tracks peak KiB RSS, and omits RSS when table is null", () => {
  const table: ProcessInfo[] = [
    { pid: 1, ppid: 0, pgid: 1, bytes: 300 * MiB, command: "node" },
    { pid: 10, ppid: 1, pgid: 10, bytes: 12 * MiB, command: "stillfail-pion" },
    { pid: 11, ppid: 10, pgid: 10, bytes: 3 * MiB, command: "pion-helper" },
    { pid: 20, ppid: 1, pgid: 20, bytes: 8 * MiB, command: "stillfail-pion" },
    { pid: 30, ppid: 1, pgid: 30, bytes: 45 * MiB, command: "stillfail-reader" },
    { pid: 31, ppid: 30, pgid: 30, bytes: 5 * MiB, command: "mb-child" },
    { pid: 32, ppid: 31, pgid: 30, bytes: 10 * MiB, command: "mb-grandchild" },
    { pid: 99, ppid: 1, pgid: 99, bytes: 500 * MiB, command: "unrelated" },
  ];
  const live: LiveProgram[] = [
    { pid: 10, binary: "/bin/stillfail-pion", args: ["--data", "/d"], background: false, startedAt: 1 },
    { pid: 20, binary: "/bin/stillfail-pion", args: ["--builder", "memory"], background: false, startedAt: 2 },
    { pid: 30, binary: "/bin/stillfail-reader", args: ["--data", "/d"], background: false, startedAt: 3 },
    // Duplicate entry for pid 30 must not double-count RSS.
    { pid: 30, binary: "/bin/stillfail-reader", args: ["--data", "/d"], background: false, startedAt: 3 },
  ];

  const snap = programsByEngineMode(table, live);
  assert.equal(snap.totalBytes, (12 + 3 + 8 + 45 + 5 + 10) * MiB);
  assert.equal(snap.totalCount, 4);
  assert.equal(snap.pionRssBytes, (12 + 3 + 8) * MiB);
  assert.equal(snap.mbRssBytes, (45 + 5 + 10) * MiB);
  assert.equal(snap.pionProcs, 2);
  assert.equal(snap.mbProcs, 2);

  const pionData = snap.byEngineMode.find((e) => e.engine === "pion" && e.mode === "data");
  const pionMem = snap.byEngineMode.find((e) => e.engine === "pion" && e.mode === "memory");
  const mbData = snap.byEngineMode.find((e) => e.engine === "mb" && e.mode === "data");
  assert.deepEqual(pionData, { engine: "pion", mode: "data", liveCount: 1, rssBytes: 15 * MiB });
  assert.deepEqual(pionMem, { engine: "pion", mode: "memory", liveCount: 1, rssBytes: 8 * MiB });
  assert.deepEqual(mbData, { engine: "mb", mode: "data", liveCount: 2, rssBytes: 60 * MiB });

  // table === null preserves liveCount > 0 and omits RSS keys (never emits stringValue: "null" in OTLP).
  const nullSnap = programsByEngineMode(null, live);
  assert.equal(nullSnap.pionRssBytes, null);
  assert.equal(nullSnap.mbRssBytes, null);
  assert.equal(nullSnap.pionProcs, 2);
  assert.equal(nullSnap.mbProcs, 2);
  assert.equal(nullSnap.byEngineMode[0]!.rssBytes, null);

  const nullTel = new ReaderTelemetry({ nowMs: 1_000 });
  nullTel.recordRssSnapshot(null, live, 2_000);
  const nullFlushed = nullTel.flushWindow(61_000);
  assert.equal(nullFlushed.length, 3);
  const exporter = new LogExport();
  const payload = exporter.body(
    nullFlushed.map((s) => ({ ms: 61_000, level: "INFO" as const, at: "readers", message: "engine summary", fields: s })),
    "st-test",
  );
  assert.ok(!payload.includes('"log.engineRssKb"'), "missing engineRssKb must be omitted from OTLP body");
  assert.ok(!payload.includes('"log.enginePeakRssKb"'), "missing enginePeakRssKb must be omitted from OTLP body");
  assert.ok(!payload.includes('"stringValue":"null"'), "OTLP body must never contain stringValue: null");
  for (const s of nullFlushed) {
    assert.ok(s.liveCount > 0);
    assert.equal("engineRssKb" in s, false);
    assert.equal("enginePeakRssKb" in s, false);
  }

  // Peak RSS is preserved even if a later snapshot in the same window has table === null.
  const t = new ReaderTelemetry({ nowMs: 1_000 });
  const spikeTable: ProcessInfo[] = [
    { pid: 10, ppid: 1, pgid: 10, bytes: 42 * MiB, command: "stillfail-pion" },
  ];
  const lowTable: ProcessInfo[] = [
    { pid: 10, ppid: 1, pgid: 10, bytes: 10 * MiB, command: "stillfail-pion" },
  ];
  const oneLive: LiveProgram[] = [
    { pid: 10, binary: "/bin/stillfail-pion", args: ["--builder", "packed"], background: false, startedAt: 1 },
  ];
  t.recordRssSnapshot(spikeTable, oneLive, 2_000);
  t.recordRssSnapshot(null, oneLive, 3_000);
  const flushedPeakOnly = t.flushWindow(61_000);
  assert.equal(flushedPeakOnly.length, 1);
  assert.equal(flushedPeakOnly[0]!.engineRssKb, undefined);
  assert.equal(flushedPeakOnly[0]!.enginePeakRssKb, 42 * KiB);

  t.recordRssSnapshot(lowTable, oneLive, 62_000);
  const flushed2 = t.flushWindow(121_000);
  assert.equal(flushed2[0]!.engineRssKb, 10 * KiB);
  assert.equal(flushed2[0]!.enginePeakRssKb, 10 * KiB);
});

test("arbitrary filename STILLFAIL_PION_READER is classified as pion on MbProcess and programsByEngineMode", async () => {
  const dir = mkdtempSync(join(tmpdir(), "pion-custom-bin-"));
  const prevPion = process.env.STILLFAIL_PION_READER;
  readerTelemetry.resetForTest(1_000);
  resetReaderSelectionStateForTest();
  try {
    const customBin = makeFakeExecutable(dir, "my-custom-engine-bin", "setInterval(() => {}, 1000);");
    process.env.STILLFAIL_PION_READER = customBin;
    const p = new MbProcess(customBin, ["--builder", "custom-test"]);
    try {
      assert.equal(p.engine, "pion");
      assert.equal(p.mode, "custom-test");
      const liveEntry = MbProcess.live().find((l) => l.mode === "custom-test");
      assert.ok(liveEntry);
      assert.equal(liveEntry.engine, "pion");

      const breakdown = programsByEngineMode(
        [{ pid: liveEntry.pid, ppid: process.pid, pgid: liveEntry.pid, bytes: 15 * MiB, command: "node" }],
        [liveEntry],
      );
      assert.equal(breakdown.pionProcs, 1);
      assert.equal(breakdown.mbProcs, 0);
      assert.equal(breakdown.pionRssBytes, 15 * MiB);
      assert.equal(breakdown.byEngineMode[0]!.engine, "pion");
    } finally {
      await p.terminate();
    }
  } finally {
    if (prevPion === undefined) delete process.env.STILLFAIL_PION_READER;
    else process.env.STILLFAIL_PION_READER = prevPion;
    resetReaderSelectionStateForTest();
    readerTelemetry.resetForTest();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("MbProcess lifecycle records spawns, stderrLines, STDIN_MOST stall without unexpectedExits, and ignores ENOENT spawn failures", async () => {
  readerTelemetry.resetForTest(1_000);
  const stderrLogs: Line[] = [];
  hearLines((l) => {
    if (l.at === "readers" && l.message === "a MoonBit reader said") stderrLogs.push(l);
  });

  try {
    // 1. Intentional terminate() after actual spawn: spawns=1, unexpectedExits=0.
    const p1 = new MbProcess(process.execPath, [
      "-e",
      "process.stdout.write('{\"ok\":true}\\n'); setInterval(() => {}, 1000)",
      "--",
      "--builder",
      "telemetry-term",
    ]);
    await new Promise<void>((resolve) => p1.once("message", () => resolve()));
    await p1.terminate();

    // 2. Clean exit(0): spawns=1, unexpectedExits=0.
    const p2 = new MbProcess(process.execPath, ["-e", "process.exit(0)", "--", "--builder", "telemetry-zero"]);
    await new Promise<void>((resolve) => p2.once("exit", () => resolve()));

    // 3. Unexpected non-zero exit + stderr lines: spawns=1, unexpectedExits=1, stderrLines=2.
    const p3 = new MbProcess(process.execPath, [
      "-e",
      "console.error('boom-1'); console.error('boom-2'); process.exit(2);",
      "--",
      "--builder",
      "telemetry-crash",
    ]);
    await new Promise<void>((resolve) => p3.once("exit", () => resolve()));

    // 4. STDIN_MOST stall: stalls=1, unexpectedExits=0.
    const p4 = new MbProcess(
      process.execPath,
      ["-e", "process.stdin.pause(); process.stdout.write('{\"ok\":true}\\n'); setInterval(() => {}, 1000);", "--", "--builder", "telemetry-stall"],
      { stdinMost: 64 * KiB },
    );
    await new Promise<void>((resolve) => p4.once("message", () => resolve()));
    const stallExited = new Promise<void>((resolve) => p4.once("exit", () => resolve()));
    p4.postLine("x".repeat(256 * KiB));
    await stallExited;

    // 5. ENOENT missing executable: must NOT record spawn, fallback, or unexpectedExit.
    const p5 = new MbProcess(
      "/nonexistent/stillfail-missing-binary-xyz",
      ["--builder", "telemetry-enoent"],
      { fallbackMode: "telemetry-enoent" },
    );
    await new Promise<void>((resolve) => {
      let errors = 0;
      p5.once("error", () => { errors++; });
      p5.once("exit", () => { assert.equal(errors, 1); resolve(); });
    });

    const flushed = readerTelemetry.flushWindow(11_000);

    const term = flushed.find((s) => s.mode === "telemetry-term")!;
    assert.equal(term.engine, "mb");
    assert.equal(term.spawns, 1);
    assert.equal(term.unexpectedExits, 0);

    const zero = flushed.find((s) => s.mode === "telemetry-zero")!;
    assert.equal(zero.spawns, 1);
    assert.equal(zero.unexpectedExits, 0);

    const crash = flushed.find((s) => s.mode === "telemetry-crash")!;
    assert.equal(crash.spawns, 1);
    assert.equal(crash.unexpectedExits, 1);
    assert.equal(crash.stderrLines, 2);

    const stall = flushed.find((s) => s.mode === "telemetry-stall")!;
    assert.equal(stall.spawns, 1);
    assert.equal(stall.stalls, 1);
    assert.equal(stall.unexpectedExits, 0);

    assert.equal(
      flushed.find((s) => s.mode === "telemetry-enoent"),
      undefined,
      "ENOENT failed spawn must not emit spawns, fallbacks, or unexpectedExits",
    );

    const crashLogs = stderrLogs.filter((l) => l.fields.mode === "telemetry-crash");
    assert.equal(crashLogs.length, 2);
    assert.equal(crashLogs[0]!.fields.engine, "mb");
  } finally {
    hearLines(null);
    readerTelemetry.resetForTest();
  }
});

test("ReaderPool counts fallback once across multiple pumps, ignores abort/close in errors, and tolerates malformed ready:null", async () => {
  const dir = mkdtempSync(join(tmpdir(), "pool-telemetry-"));
  const prevPion = process.env.STILLFAIL_PION_READER;
  const prevData = process.env.STILLFAIL_READER_DATA;
  readerTelemetry.resetForTest(1_000);
  resetReaderSelectionStateForTest();

  let onHangSignal: (() => void) | null = null;
  const nextHangSignal = () => new Promise<void>((resolve) => { onHangSignal = resolve; });
  hearLines((l) => {
    if (l.at === "readers" && l.message === "a MoonBit reader said" && l.fields.line === "HANG_RECEIVED") {
      const wake = onHangSignal;
      onHangSignal = null;
      wake?.();
    }
  });

  try {
    // Event-driven fake MB reader: emits malformed `{"ready":null}`, replies to normal reads,
    // and signals stderr `HANG_RECEIVED` when holding a hang read (zero setTimeout sleeps).
    const fakeMb = makeFakeExecutable(
      dir,
      "stillfail-reader",
      `import { createInterface } from "node:readline";
process.stdout.write(JSON.stringify({ ready: null }) + "\\n");
createInterface({ input: process.stdin }).on("line", (line) => {
  const msg = JSON.parse(line);
  if (msg.args?.hang) {
    process.stderr.write("HANG_RECEIVED\\n");
    return;
  }
  process.stdout.write(JSON.stringify({ id: msg.id, text: JSON.stringify({ ok: msg.op }) }) + "\\n");
});`,
    );
    process.env.STILLFAIL_PION_READER = join(dir, "does-not-exist-pion");
    process.env.STILLFAIL_READER_DATA = "pion";
    setMbReaderBinaryOverrideForTest(() => fakeMb);

    const pool = new Readers(dir, 1);
    try {
      // Multiple reads pump the same single fallback-spawned worker -> fallbacks stays 1.
      assert.equal(await pool.read("thread", {}, "en"), JSON.stringify({ ok: "thread" }));
      assert.equal(await pool.read("chats", {}, "en"), JSON.stringify({ ok: "chats" }));
      assert.equal(await pool.read("summary", {}, "en"), JSON.stringify({ ok: "summary" }));

      // Client abort on an in-flight read must NOT increment errors.
      const hang1Arrived = nextHangSignal();
      const ac = new AbortController();
      const hanging = pool.read("job", { hang: true }, "en", { signal: ac.signal });
      await hang1Arrived;
      ac.abort();
      await assert.rejects(hanging, /read cancelled/);

      // Station close() while a second read is in flight must NOT increment errors.
      const hang2Arrived = nextHangSignal();
      const closingRead = pool.read("job", { hang: true }, "en");
      await hang2Arrived;
      pool.close();
      await assert.rejects(closingRead);
    } finally {
      pool.close();
    }

    const flushed = readerTelemetry.flushWindow(61_000);
    const pionData = flushed.find((s) => s.engine === "pion" && s.mode === "data");
    const mbData = flushed.find((s) => s.engine === "mb" && s.mode === "data");
    assert.ok(pionData, "fallback counter recorded under pion/data");
    assert.ok(mbData, "actual MB worker traffic recorded under mb/data");
    assert.equal(pionData.fallbacks, 2);
    assert.equal(mbData.spawns, 2);
    assert.equal(mbData.ops, 3);
    assert.equal(mbData.errors, 0, "aborted and closed reads must not pollute errors");
    assert.ok(mbData.readyCount >= 1, "malformed ready:null handled without throwing");
    assert.equal(mbData.loadedP50Ms, undefined);
    assert.equal(mbData.openedP50Ms, undefined);
  } finally {
    hearLines(null);
    if (prevPion === undefined) delete process.env.STILLFAIL_PION_READER;
    else process.env.STILLFAIL_PION_READER = prevPion;
    if (prevData === undefined) delete process.env.STILLFAIL_READER_DATA;
    else process.env.STILLFAIL_READER_DATA = prevData;
    resetReaderSelectionStateForTest();
    readerTelemetry.resetForTest();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("non-pool builder (ArchiveMarkBuilder) records fallback once on real MB spawn", async () => {
  const dir = mkdtempSync(join(tmpdir(), "archive-mark-fallback-"));
  const prevPion = process.env.STILLFAIL_PION_READER;
  const prevMode = process.env.STILLFAIL_READER_ARCHIVE_MARKS;
  readerTelemetry.resetForTest(1_000);
  resetReaderSelectionStateForTest();
  try {
    const fakeMb = makeFakeExecutable(
      dir,
      "stillfail-reader",
      `import { createInterface } from "node:readline";
createInterface({ input: process.stdin }).on("line", () => {
  process.stdout.write(JSON.stringify({ done: true }) + "\\n");
});`,
    );
    setMbReaderBinaryOverrideForTest(() => fakeMb);
    process.env.STILLFAIL_PION_READER = join(dir, "missing-pion");
    process.env.STILLFAIL_READER_ARCHIVE_MARKS = "pion";

    const builder = new ArchiveMarkBuilder(join(dir, "stillfail.db"));
    try {
      await builder.readyIndex();
    } finally {
      await builder.close();
    }

    const flushed = readerTelemetry.flushWindow(61_000);
    const pionFallback = flushed.find((s) => s.engine === "pion" && s.mode === "archive-marks");
    const mbWork = flushed.find((s) => s.engine === "mb" && s.mode === "archive-marks");
    assert.ok(pionFallback);
    assert.ok(mbWork);
    assert.equal(pionFallback.fallbacks, 1);
    assert.equal(mbWork.spawns, 1);
    assert.equal(mbWork.ops, 1);
    assert.equal(mbWork.errors, 0);
  } finally {
    if (prevPion === undefined) delete process.env.STILLFAIL_PION_READER;
    else process.env.STILLFAIL_PION_READER = prevPion;
    if (prevMode === undefined) delete process.env.STILLFAIL_READER_ARCHIVE_MARKS;
    else process.env.STILLFAIL_READER_ARCHIVE_MARKS = prevMode;
    resetReaderSelectionStateForTest();
    readerTelemetry.resetForTest();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("footprint shadow internal deadline timeout records ops=1, errors=1 once without polling or sleep", async () => {
  const dir = mkdtempSync(join(tmpdir(), "footprint-shadow-tel-"));
  const prevPion = process.env.STILLFAIL_PION_READER;
  const prevFoot = process.env.STILLFAIL_READER_FOOTPRINT;
  readerTelemetry.resetForTest(1_000);
  resetReaderSelectionStateForTest();

  try {
    const fakeMb = makeFakeExecutable(
      dir,
      "stillfail-reader",
      `import { createInterface } from "node:readline";
createInterface({ input: process.stdin }).once("line", () => {
  process.stdout.write(JSON.stringify({ size: 123, complete: true }) + "\\n");
  process.exit(0);
});`,
    );
    const hangingPion = makeFakeExecutable(
      dir,
      "custom-shadow-pion",
      "process.stdin.resume(); setInterval(() => {}, 1000);",
    );
    setMbReaderBinaryOverrideForTest(() => fakeMb);
    process.env.STILLFAIL_PION_READER = hangingPion;
    process.env.STILLFAIL_READER_FOOTPRINT = "shadow";

    const deadlineArmed = waitForShadowDeadlineArmedForTest();
    const bytes = await measured(dir, undefined, { maxDurationMs: 60_000 });
    assert.equal(bytes, 123);

    await deadlineArmed;
    assert.equal(triggerShadowDeadlineForTest(), true);
    await waitForShadowMeasures();

    const flushed = readerTelemetry.flushWindow(61_000);
    const mbFoot = flushed.find((s) => s.engine === "mb" && s.mode === "footprint")!;
    const pionFoot = flushed.find((s) => s.engine === "pion" && s.mode === "footprint")!;
    assert.ok(mbFoot);
    assert.ok(pionFoot);
    assert.equal(mbFoot.ops, 1);
    assert.equal(mbFoot.errors, 0);
    assert.equal(pionFoot.ops, 1);
    assert.equal(pionFoot.errors, 1);
  } finally {
    if (prevPion === undefined) delete process.env.STILLFAIL_PION_READER;
    else process.env.STILLFAIL_PION_READER = prevPion;
    if (prevFoot === undefined) delete process.env.STILLFAIL_READER_FOOTPRINT;
    else process.env.STILLFAIL_READER_FOOTPRINT = prevFoot;
    resetReaderSelectionStateForTest();
    readerTelemetry.resetForTest();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("ProgramRunner records in-flight pass() reply arriving during close() while skipping close ack", async () => {
  const dir = mkdtempSync(join(tmpdir(), "runner-close-tel-"));
  readerTelemetry.resetForTest(1_000);
  try {
    const fakeExport = makeFakeExecutable(
      dir,
      "stillfail-pion",
      `import { createInterface } from "node:readline";
let passId = null;
createInterface({ input: process.stdin }).on("line", (line) => {
  const req = JSON.parse(line);
  if (req.type === "pass") {
    passId = req.id;
    return;
  }
  if (req.type === "close") {
    if (passId !== null) {
      process.stdout.write(JSON.stringify({ id: passId, answer: { heads: {}, more: false, wrote: 1, read: 2, empty: false } }) + "\\n");
    }
    process.stdout.write(JSON.stringify({ id: req.id, answer: null }) + "\\n");
    process.exit(0);
  }
});`,
    );
    const runner = new ProgramRunner(
      { db: join(dir, "stillfail.db"), replica: join(dir, "replica"), dataDir: dir, origin: "st1" },
      () => new MbProcess(fakeExport, ["--builder", "replica-export"]),
    );
    const passPromise = runner.pass({ sessions: [], threads: [], removedSessions: [], removedThreads: [], marks: [] });
    await runner.close();
    const res = await passPromise;
    assert.equal(res.wrote, 1);

    const flushed = readerTelemetry.flushWindow(61_000);
    const exp = flushed.find((s) => s.engine === "pion" && s.mode === "replica-export")!;
    assert.ok(exp);
    assert.equal(exp.ops, 1, "in-flight pass() counted, close ack skipped");
    assert.equal(exp.errors, 0);
  } finally {
    readerTelemetry.resetForTest();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("MinuteReader (usage-check) error response records ops=1, errors=1", async () => {
  const dir = mkdtempSync(join(tmpdir(), "minute-reader-tel-"));
  readerTelemetry.resetForTest(1_000);
  try {
    const fakeCheck = makeFakeExecutable(
      dir,
      "stillfail-pion",
      `import { createInterface } from "node:readline";
createInterface({ input: process.stdin }).on("line", (line) => {
  const req = JSON.parse(line);
  process.stdout.write(JSON.stringify({ id: req.id, error: "simulated usage-check failure" }) + "\\n");
});`,
    );
    const reader = new MinuteReader(join(dir, "stillfail.db"), {}, fakeCheck);
    try {
      await assert.rejects(reader.readyRemote(), /simulated usage-check failure/);
    } finally {
      await reader.close();
    }

    const flushed = readerTelemetry.flushWindow(61_000);
    const check = flushed.find((s) => s.engine === "pion" && s.mode === "usage-check")!;
    assert.ok(check);
    assert.equal(check.ops, 1);
    assert.equal(check.errors, 1);
  } finally {
    readerTelemetry.resetForTest();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("OTel log-export preserves all updated telemetry fields without scrubbing and emits stable intValue types", () => {
  const t = new ReaderTelemetry({ nowMs: 1_000 });
  t.recordSpawn("pion", "replica-export");
  t.recordUnexpectedExit("pion", "replica-export");
  t.recordStall("pion", "replica-export");
  t.recordStderr("pion", "replica-export");
  t.recordFallback("replica-export");
  t.recordReady("pion", "replica-export", 85, 25, 60);
  t.recordCall("pion", "replica-export", 12, true);
  t.recordCall("pion", "replica-export", 48, false);
  const rss = t.recordRssSnapshot(
    [
      { pid: 100, ppid: 1, pgid: 100, bytes: 18 * MiB + 512 * KiB, command: "stillfail-pion" },
      { pid: 200, ppid: 1, pgid: 200, bytes: 64 * MiB, command: "stillfail-reader" },
    ],
    [
      { pid: 100, binary: "/opt/stillfail-pion", args: ["--builder", "replica-export"], background: true, startedAt: 1, engine: "pion", mode: "replica-export" },
      { pid: 200, binary: "/opt/stillfail-reader", args: ["--data", "/d"], background: false, startedAt: 1, engine: "mb", mode: "data" },
    ],
    10_000,
  );
  const [summary] = t.flushWindow(601_000).filter((s) => s.engine === "pion");
  assert.ok(summary);

  const summaryRecord = record(
    { ms: 601_000, level: "INFO", at: "readers", message: "engine summary", fields: summary },
    "/Users/alice",
  );
  const sAttrs = attrsOf(summaryRecord);
  const sRaw = rawAttrsOf(summaryRecord);
  assert.equal(sAttrs["log.target"], "readers");
  assert.equal(sAttrs["log.engine"], "pion");
  assert.equal(sAttrs["log.mode"], "replica-export");
  assert.equal(sAttrs["log.engineRssKb"], String(18 * KiB + 512));
  assert.equal(sAttrs["log.enginePeakRssKb"], String(18 * KiB + 512));

  const intKeys = [
    "log.windowSec", "log.spawns", "log.unexpectedExits", "log.stalls", "log.stderrLines",
    "log.fallbacks", "log.ops", "log.errors", "log.p50Ms", "log.p95Ms", "log.maxMs", "log.avgMs",
    "log.readyCount", "log.readyP50Ms", "log.readyMaxMs", "log.loadedP50Ms", "log.openedP50Ms",
    "log.liveCount", "log.engineRssKb", "log.enginePeakRssKb",
  ];
  for (const key of intKeys) {
    assert.ok("intValue" in sRaw[key]!, `${key} must be OTLP intValue, got ${JSON.stringify(sRaw[key])}`);
  }
  for (const [k, v] of Object.entries(sAttrs)) {
    assert.notEqual(v, "…", `attribute ${k} must not be scrubbed`);
  }

  const memRecord = record(
    {
      ms: 601_000,
      level: "INFO",
      at: "memory",
      message: "now",
      fields: {
        rssMb: 210,
        pionRssMb: Math.round(rss.pionRssBytes! / MiB),
        mbRssMb: Math.round(rss.mbRssBytes! / MiB),
        pionProcs: rss.pionProcs,
        mbProcs: rss.mbProcs,
      },
    },
    "/Users/alice",
  );
  const mAttrs = attrsOf(memRecord);
  const mRaw = rawAttrsOf(memRecord);
  assert.equal(mAttrs["log.target"], "memory");
  assert.equal(mAttrs["log.pionRssMb"], "19");
  assert.equal(mAttrs["log.mbRssMb"], "64");
  assert.equal(mAttrs["log.pionProcs"], "1");
  assert.equal(mAttrs["log.mbProcs"], "1");
  for (const key of ["log.pionRssMb", "log.mbRssMb", "log.pionProcs", "log.mbProcs"]) {
    assert.ok("intValue" in mRaw[key]!, `${key} must be OTLP intValue`);
  }
});

test("isBackgroundWrapperExecFailure distinguishes taskpolicy/nice/ionice exec failures from reader exit codes", () => {
  assert.equal(
    isBackgroundWrapperExecFailure("/usr/sbin/taskpolicy", 66, null, ["taskpolicy: posix_spawn: No such file or directory"]),
    true,
  );
  assert.equal(
    isBackgroundWrapperExecFailure("/usr/sbin/taskpolicy", 66, null, ["reader exited cleanly with custom code 66"]),
    false,
  );
  assert.equal(
    isBackgroundWrapperExecFailure("/usr/bin/nice", 127, null, ["nice: '/missing/bin': No such file or directory"]),
    true,
  );
  assert.equal(
    isBackgroundWrapperExecFailure("/usr/bin/nice", 126, null, ["/usr/bin/nice: '/bad/bin': Permission denied"]),
    true,
  );
  assert.equal(
    isBackgroundWrapperExecFailure("/usr/bin/nice", 127, null, ["reader internal error"]),
    false,
  );
  assert.equal(
    isBackgroundWrapperExecFailure("/usr/bin/ionice", 1, null, ["ionice: failed to execute /bad/bin: No such file or directory"]),
    true,
  );
  assert.equal(
    isBackgroundWrapperExecFailure("/usr/bin/ionice", 127, null, ["nice: '/bad/bin': No such file or directory"]),
    true,
  );
  assert.equal(
    isBackgroundWrapperExecFailure("/usr/bin/ionice", 66, null, ["ionice: failed to execute /bad/bin"]),
    false,
  );
  assert.equal(
    isBackgroundWrapperExecFailure("/usr/sbin/taskpolicy", 0, null, ["taskpolicy: posix_spawn: No such file or directory"]),
    false,
  );
  assert.equal(
    isBackgroundWrapperExecFailure("/usr/sbin/taskpolicy", null, "SIGKILL", ["taskpolicy: posix_spawn: No such file or directory"]),
    false,
  );
  assert.equal(
    isBackgroundWrapperExecFailure("/usr/local/bin/stillfail-reader", 127, null, ["nice: nope"]),
    false,
  );
  assert.equal(isBackgroundWrapperStderrLine("/usr/sbin/taskpolicy", "taskpolicy: posix_spawn: No such file or directory"), true);
  assert.equal(isBackgroundWrapperStderrLine("/usr/bin/nice", "nice: '/bad/bin': No such file or directory"), true);
  assert.equal(isBackgroundWrapperStderrLine("/usr/bin/ionice", "ionice: failed to execute /bad/bin: Permission denied"), true);
  assert.equal(isBackgroundWrapperStderrLine("/usr/sbin/taskpolicy", "reader warning: something else"), false);
});

test("background wrapper exec failure (bad shebang) stays uncredited even across a mid-flight flushWindow(), while real exit 66/127 still counts", { skip: unix ? false : "Unix background wrappers only" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "bg-wrapper-exec-fail-"));
  const prevPion = process.env.STILLFAIL_PION_READER;
  const prevFoot = process.env.STILLFAIL_READER_FOOTPRINT;
  readerTelemetry.resetForTest(1_000);
  resetReaderSelectionStateForTest();

  try {
    // 1. Executable with non-existent shebang interpreter via measured() (background: true) + missing Pion fallback.
    // Flush once mid-flight right after the wrapper diagnostic stderr line arrives (before `close` settles),
    // and again after `measured()` rejects: across both windows combined, spawns/fallbacks/stderrLines/unexpectedExits
    // must all remain 0 and no `pion/footprint` bucket may be emitted.
    const badShebang = join(dir, "stillfail-reader");
    writeFileSync(badShebang, "#!/nonexistent/interp\n");
    chmodSync(badShebang, 0o755);
    setMbReaderBinaryOverrideForTest(() => badShebang);
    process.env.STILLFAIL_PION_READER = join(dir, "missing-pion");
    process.env.STILLFAIL_READER_FOOTPRINT = "pion";

    let midFlightFlushed = false;
    let window1: ReturnType<typeof readerTelemetry.flushWindow> = [];
    hearLines((entry) => {
      if (!midFlightFlushed && entry.at === "readers" && entry.message === "a MoonBit reader said") {
        midFlightFlushed = true;
        window1 = readerTelemetry.flushWindow(31_000);
      }
    });

    await assert.rejects(measured(dir, undefined, { maxDurationMs: 5_000 }));
    hearLines(null);
    assert.equal(midFlightFlushed, true, "expected mid-flight flushWindow() to run after wrapper diagnostic stderr line");

    const window2 = readerTelemetry.flushWindow(61_000);
    const combined = [...window1, ...window2];
    const mbFoot = combined.filter((s) => s.engine === "mb" && s.mode === "footprint");
    const sum = (items: typeof mbFoot, key: "ops" | "errors" | "spawns" | "unexpectedExits" | "stderrLines" | "fallbacks") =>
      items.reduce((acc, item) => acc + item[key], 0);
    assert.equal(sum(mbFoot, "ops"), 1);
    assert.equal(sum(mbFoot, "errors"), 1);
    assert.equal(sum(mbFoot, "spawns"), 0);
    assert.equal(sum(mbFoot, "unexpectedExits"), 0);
    assert.equal(sum(mbFoot, "stderrLines"), 0);
    assert.equal(sum(mbFoot, "fallbacks"), 0);
    assert.deepEqual(
      combined.filter((s) => s.engine === "pion" && s.mode === "footprint"),
      [],
      "no pion/footprint fallback bucket emitted in either window",
    );

    // 2. Contrast control: real runnable script under background: true exiting with 66 and 127 MUST still count.
    for (const exitCode of [66, 127] as const) {
      const mode = `bg-exit-${exitCode}`;
      const realScript = makeFakeExecutable(dir, `exit-${exitCode}`, `process.exit(${exitCode});`);
      const p = new MbProcess(realScript, ["--builder", mode], { background: true });
      await new Promise<void>((resolve) => p.once("exit", () => resolve()));
      const flushed = readerTelemetry.flushWindow(121_000 + exitCode);
      const bucket = flushed.find((s) => s.engine === "mb" && s.mode === mode);
      assert.ok(bucket, `bucket for exit ${exitCode} present`);
      assert.equal(bucket.spawns, 1, `real exit ${exitCode} keeps spawns=1`);
      assert.equal(bucket.unexpectedExits, 1, `real exit ${exitCode} keeps unexpectedExits=1`);
    }

    // 3. Real runnable script under background: true that writes a wrapper-like stderr line followed by a normal
    // stderr line (no stdout) and exits with 66/127 MUST commit its spawn and still record unexpectedExits=1.
    const wrapperLikeLine = process.platform === "darwin"
      ? "taskpolicy: posix_spawn: simulated child message"
      : "nice: simulated child message";
    const wrapperExitCode = process.platform === "darwin" ? 66 : 127;
    const mixedStderrScript = makeFakeExecutable(
      dir,
      "mixed-stderr-exit",
      `process.stderr.write(${JSON.stringify(`${wrapperLikeLine}\nnormal target stderr\n`)});
process.exit(${wrapperExitCode});`,
    );
    const mixed = new MbProcess(mixedStderrScript, ["--builder", "bg-mixed-stderr"], { background: true });
    await new Promise<void>((resolve) => mixed.once("exit", () => resolve()));
    const flushedMixed = readerTelemetry.flushWindow(181_000);
    const mixedBucket = flushedMixed.find((s) => s.engine === "mb" && s.mode === "bg-mixed-stderr");
    assert.ok(mixedBucket, "bg-mixed-stderr bucket present");
    assert.equal(mixedBucket.spawns, 1);
    assert.equal(mixedBucket.stderrLines, 2);
    assert.equal(mixedBucket.unexpectedExits, 1);
  } finally {
    hearLines(null);
    if (prevPion === undefined) delete process.env.STILLFAIL_PION_READER;
    else process.env.STILLFAIL_PION_READER = prevPion;
    if (prevFoot === undefined) delete process.env.STILLFAIL_READER_FOOTPRINT;
    else process.env.STILLFAIL_READER_FOOTPRINT = prevFoot;
    resetReaderSelectionStateForTest();
    readerTelemetry.resetForTest();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("direct MbReader captures ready handshake once without pool", async () => {
  const dir = mkdtempSync(join(tmpdir(), "mb-reader-direct-"));
  readerTelemetry.resetForTest(1_000);
  try {
    const fakeReader = makeFakeExecutable(
      dir,
      "stillfail-pion",
      `process.stdout.write(JSON.stringify({ ready: { loadedMs: 11, openedMs: 22 } }) + "\\n");
setInterval(() => {}, 1000);`,
    );
    const r = new MbReader(fakeReader, dir, { engine: "pion" });
    try {
      await new Promise<void>((resolve) => r.once("message", () => resolve()));
    } finally {
      await r.terminate();
    }
    const [summary] = readerTelemetry.flushWindow(61_000);
    assert.ok(summary);
    assert.equal(summary.engine, "pion");
    assert.equal(summary.mode, "data");
    assert.equal(summary.readyCount, 1);
    assert.equal(summary.loadedP50Ms, 11);
    assert.equal(summary.openedP50Ms, 22);
  } finally {
    readerTelemetry.resetForTest();
    rmSync(dir, { recursive: true, force: true });
  }
});
