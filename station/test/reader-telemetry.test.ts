// Unit and OTel log-export integration tests for `station/src/read/reader-telemetry.ts`.
import assert from "node:assert/strict";
import { test } from "node:test";
import { record } from "../src/ops/log-export.ts";
import { type Line, hearLines } from "../src/ops/log.ts";
import type { ProcessInfo } from "../src/platform/index.ts";
import { type LiveProgram, MbProcess } from "../src/read/mb-reader.ts";
import {
  DEFAULT_MAX_SAMPLES,
  ReaderTelemetry,
  classifyProgram,
  programsByEngineMode,
  readerTelemetry,
} from "../src/read/reader-telemetry.ts";

const MiB = 1024 * 1024;
const attrsOf = (r: ReturnType<typeof record>) =>
  Object.fromEntries(r.attributes.map((a) => [a.key, Object.values(a.value)[0]]));

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

  // Push 5,000 samples (1..5000 ms) into pion/data and verify bounded reservoir + reasonable quantiles.
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

  const searchSummary = summaries.find((s) => s.engine === "pion" && s.mode === "search")!;
  assert.ok(searchSummary);
  assert.equal(searchSummary.fallbacks, 1);
  assert.equal(searchSummary.p50Ms, undefined);
  assert.equal(searchSummary.readyP50Ms, undefined);

  // Subsequent flush with no activity and no live processes produces nothing.
  assert.deepEqual(t.flushWindow(1_201_000), []);
});

test("programsByEngineMode attributes descendant trees without double counting and tracks peak RSS", () => {
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

  // Null process table preserves process counts with zero RSS.
  const nullSnap = programsByEngineMode(null, live);
  assert.equal(nullSnap.pionRssBytes, 0);
  assert.equal(nullSnap.mbRssBytes, 0);
  assert.equal(nullSnap.pionProcs, 2);
  assert.equal(nullSnap.mbProcs, 2);

  // Peak RSS captures transient spike across snapshots in the same window and resets after flush.
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
  t.recordRssSnapshot(lowTable, oneLive, 3_000);
  const flushed1 = t.flushWindow(61_000);
  assert.equal(flushed1.length, 1);
  assert.equal(flushed1[0]!.rssMb, 10);
  assert.equal(flushed1[0]!.peakRssMb, 42);
  assert.equal(flushed1[0]!.liveCount, 1);

  // Next window sees low RSS as peak too (old 42 MB peak was reset).
  t.recordRssSnapshot(lowTable, oneLive, 62_000);
  const flushed2 = t.flushWindow(121_000);
  assert.equal(flushed2[0]!.rssMb, 10);
  assert.equal(flushed2[0]!.peakRssMb, 10);
});

test("MbProcess lifecycle records spawns, stderrLines, and distinguishes terminate vs unexpected exit", async () => {
  readerTelemetry.resetForTest(1_000);
  const stderrLogs: Line[] = [];
  hearLines((l) => {
    if (l.at === "readers" && l.message === "a MoonBit reader said") stderrLogs.push(l);
  });

  try {
    // 1. Intentional terminate(): must NOT count as unexpectedExits.
    const p1 = new MbProcess(process.execPath, ["-e", "setInterval(() => {}, 1000)", "--", "--builder", "telemetry-term"]);
    await p1.terminate();

    // 2. Clean exit(0): must NOT count as unexpectedExits.
    const p2 = new MbProcess(process.execPath, ["-e", "process.exit(0)", "--", "--builder", "telemetry-zero"]);
    await new Promise<void>((resolve) => p2.once("exit", () => resolve()));

    // 3. Unexpected non-zero exit + stderr lines: MUST count stderrLines and unexpectedExits.
    const p3 = new MbProcess(process.execPath, [
      "-e",
      "console.error('boom-1'); console.error('boom-2'); process.exit(2);",
      "--",
      "--builder",
      "telemetry-crash",
    ]);
    await new Promise<void>((resolve) => p3.once("exit", () => resolve()));

    const flushed = readerTelemetry.flushWindow(11_000);

    const term = flushed.find((s) => s.mode === "telemetry-term")!;
    assert.ok(term);
    assert.equal(term.engine, "mb");
    assert.equal(term.spawns, 1);
    assert.equal(term.unexpectedExits, 0);

    const zero = flushed.find((s) => s.mode === "telemetry-zero")!;
    assert.ok(zero);
    assert.equal(zero.spawns, 1);
    assert.equal(zero.unexpectedExits, 0);

    const crash = flushed.find((s) => s.mode === "telemetry-crash")!;
    assert.ok(crash);
    assert.equal(crash.spawns, 1);
    assert.equal(crash.unexpectedExits, 1);
    assert.equal(crash.stderrLines, 2);

    const crashLogs = stderrLogs.filter((l) => l.fields.mode === "telemetry-crash");
    assert.equal(crashLogs.length, 2);
    assert.equal(crashLogs[0]!.fields.engine, "mb");
  } finally {
    hearLines(null);
    readerTelemetry.resetForTest();
  }
});

test("OTel log-export preserves all engine summary and memory now telemetry attributes without scrubbing", () => {
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
      { pid: 100, ppid: 1, pgid: 100, bytes: 18 * MiB, command: "stillfail-pion" },
      { pid: 200, ppid: 1, pgid: 200, bytes: 64 * MiB, command: "stillfail-reader" },
    ],
    [
      { pid: 100, binary: "/opt/stillfail-pion", args: ["--builder", "replica-export"], background: true, startedAt: 1 },
      { pid: 200, binary: "/opt/stillfail-reader", args: ["--data", "/d"], background: false, startedAt: 1 },
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
  assert.equal(sAttrs["log.target"], "readers");
  assert.equal(sAttrs["log.engine"], "pion");
  assert.equal(sAttrs["log.mode"], "replica-export");
  assert.equal(sAttrs["log.windowSec"], "600");
  assert.equal(sAttrs["log.spawns"], "1");
  assert.equal(sAttrs["log.unexpectedExits"], "1");
  assert.equal(sAttrs["log.stalls"], "1");
  assert.equal(sAttrs["log.stderrLines"], "1");
  assert.equal(sAttrs["log.fallbacks"], "1");
  assert.equal(sAttrs["log.ops"], "2");
  assert.equal(sAttrs["log.errors"], "1");
  assert.equal(sAttrs["log.p50Ms"], "12");
  assert.equal(sAttrs["log.p95Ms"], "48");
  assert.equal(sAttrs["log.maxMs"], "48");
  assert.equal(sAttrs["log.avgMs"], "30");
  assert.equal(sAttrs["log.readyCount"], "1");
  assert.equal(sAttrs["log.readyP50Ms"], "85");
  assert.equal(sAttrs["log.readyMaxMs"], "85");
  assert.equal(sAttrs["log.loadedP50Ms"], "25");
  assert.equal(sAttrs["log.openedP50Ms"], "60");
  assert.equal(sAttrs["log.liveCount"], "1");
  assert.equal(sAttrs["log.rssMb"], "18");
  assert.equal(sAttrs["log.peakRssMb"], "18");
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
        pionRssMb: Math.round(rss.pionRssBytes / MiB),
        mbRssMb: Math.round(rss.mbRssBytes / MiB),
        pionProcs: rss.pionProcs,
        mbProcs: rss.mbProcs,
      },
    },
    "/Users/alice",
  );
  const mAttrs = attrsOf(memRecord);
  assert.equal(mAttrs["log.target"], "memory");
  assert.equal(mAttrs["log.pionRssMb"], "18");
  assert.equal(mAttrs["log.mbRssMb"], "64");
  assert.equal(mAttrs["log.pionProcs"], "1");
  assert.equal(mAttrs["log.mbProcs"], "1");
});
