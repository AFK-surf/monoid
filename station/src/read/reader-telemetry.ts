// In-memory reader/builder engine telemetry for comparing `mb` (MoonBit) vs `pion` (Pion)
// across RSS, latency (P50/P95/Max/Avg), throughput/errors, cold-start (`ready`), and
// stability (unexpected exits, stdin stalls, fallbacks, stderr) in Cloud Logging OTel logs.
//
// Invariants:
// - Zero external dependencies, zero extra subprocesses, zero main-thread sync I/O.
// - Bounded memory per `(engine, mode)` via fixed-capacity deterministic reservoir sampling.
// - Flat scalar fields only; never uses `log-export.ts` `WRITTEN` scrubbed field names.
import { wall } from "../ops/fibers.ts";
import { type ProcessInfo, treeOf } from "../platform/index.ts";
import type { LiveProgram } from "./mb-reader.ts";

export type TelemetryEngine = "pion" | "mb";

export type ProgramIdentity = {
  readonly engine: TelemetryEngine;
  readonly mode: string;
};

export type EngineModeRss = {
  readonly engine: TelemetryEngine;
  readonly mode: string;
  readonly liveCount: number;
  readonly rssBytes: number | null;
};

export type RssBreakdown = {
  readonly byEngineMode: ReadonlyArray<EngineModeRss>;
  readonly totalBytes: number;
  readonly totalCount: number;
  readonly pionRssBytes: number | null;
  readonly mbRssBytes: number | null;
  readonly pionProcs: number;
  readonly mbProcs: number;
};

export type EngineModeSummary = {
  readonly windowSec: number;
  readonly engine: TelemetryEngine;
  readonly mode: string;
  readonly spawns: number;
  readonly unexpectedExits: number;
  readonly stalls: number;
  readonly stderrLines: number;
  readonly fallbacks: number;
  readonly ops: number;
  readonly errors: number;
  readonly p50Ms?: number;
  readonly p95Ms?: number;
  readonly maxMs?: number;
  readonly avgMs?: number;
  readonly readyCount: number;
  readonly readyP50Ms?: number;
  readonly readyMaxMs?: number;
  readonly loadedP50Ms?: number;
  readonly openedP50Ms?: number;
  readonly liveCount: number;
  readonly engineRssKb?: number;
  readonly enginePeakRssKb?: number;
};

const KiB = 1024;
export const DEFAULT_MAX_SAMPLES = 512;

const bytesToKb = (bytes: number | null): number | null => (bytes === null ? null : Math.round(bytes / KiB));

/// Classify a spawned reader/builder binary and args into `(engine, mode)`.
/// Handles both Unix (`/`) and Windows (`\`) paths and optional `.exe` suffix.
export function classifyProgram(binary: string, args: readonly string[]): ProgramIdentity {
  const parts = binary.split(/[\\/]+/);
  let base = "";
  for (let i = parts.length - 1; i >= 0; i--) {
    if (parts[i] !== "") {
      base = parts[i]!;
      break;
    }
  }
  const normalized = base.toLowerCase().endsWith(".exe") ? base.slice(0, -4).toLowerCase() : base.toLowerCase();
  const engine: TelemetryEngine = normalized.startsWith("stillfail-pion") ? "pion" : "mb";

  let mode = "other";
  const builderAt = args.indexOf("--builder");
  if (builderAt >= 0 && builderAt + 1 < args.length && args[builderAt + 1] !== "") {
    mode = args[builderAt + 1]!;
  } else if (args.includes("--serve")) {
    mode = "serve";
  } else if (args.includes("--sessions")) {
    mode = "sessions";
  } else if (args.includes("--data")) {
    mode = "data";
  }

  return { engine, mode };
}

/// Bounded numeric sample collector with exact `count`, `sum`, `max`, and deterministic
/// reservoir sampling (Algorithm R with xorshift32 PRNG) capped at `capacity` entries.
class BoundedSamples {
  readonly #capacity: number;
  #samples: number[] = [];
  #count = 0;
  #sum = 0;
  #max = 0;
  #rng = 0x9e3779b9;

  constructor(capacity: number) {
    this.#capacity = Math.max(1, capacity);
  }

  get count(): number { return this.#count; }
  get sampleCount(): number { return this.#samples.length; }

  add(value: number): void {
    const v = Number.isFinite(value) && value > 0 ? value : 0;
    this.#count++;
    this.#sum += v;
    if (this.#count === 1 || v > this.#max) this.#max = v;
    if (this.#samples.length < this.#capacity) {
      this.#samples.push(v);
      return;
    }
    // Deterministic xorshift32 for reproducible reservoir sampling in tests and production.
    let x = this.#rng | 0;
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    this.#rng = x === 0 ? 0x9e3779b9 : x;
    const j = (this.#rng >>> 0) % this.#count;
    if (j < this.#capacity) this.#samples[j] = v;
  }

  stats(): { p50: number; p95: number; max: number; avg: number } | null {
    if (this.#count === 0) return null;
    const sorted = this.#samples.slice().sort((a, b) => a - b);
    const at = (q: number): number => {
      if (sorted.length === 0) return 0;
      const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil(q * sorted.length) - 1));
      return sorted[idx]!;
    };
    return {
      p50: Math.round(at(0.5)),
      p95: Math.round(at(0.95)),
      max: Math.round(this.#max),
      avg: Math.round(this.#sum / this.#count),
    };
  }

  reset(): void {
    this.#samples = [];
    this.#count = 0;
    this.#sum = 0;
    this.#max = 0;
    this.#rng = 0x9e3779b9;
  }
}

type Bucket = {
  readonly engine: TelemetryEngine;
  readonly mode: string;
  spawns: number;
  unexpectedExits: number;
  stalls: number;
  stderrLines: number;
  fallbacks: number;
  ops: number;
  errors: number;
  readonly latency: BoundedSamples;
  readyCount: number;
  readonly readyTotal: BoundedSamples;
  readonly readyLoaded: BoundedSamples;
  readonly readyOpened: BoundedSamples;
  liveCount: number;
  rssBytes: number | null;
  peakRssBytes: number | null;
};

/// Compute RSS breakdown across `(engine, mode)` and top-level `pion` vs `mb` totals
/// from a process table snapshot, reusing a single `treeOf(table)` pass so each process
/// and its descendants are counted at most once (matching `resources/module.ts` `programsIn`).
/// When `table === null` and `live.length > 0`, RSS values are `null` (unavailable) rather than `0`.
export function programsByEngineMode(
  table: readonly ProcessInfo[] | null,
  live: readonly LiveProgram[],
): RssBreakdown {
  if (live.length === 0) {
    return EMPTY_RSS;
  }
  const tree = table !== null ? treeOf(table) : null;
  const seen = new Set<number>();
  const grouped = new Map<string, { engine: TelemetryEngine; mode: string; liveCount: number; rssBytes: number | null }>();
  let totalBytes = 0;
  let pionRssBytes: number | null = tree !== null ? 0 : null;
  let mbRssBytes: number | null = tree !== null ? 0 : null;
  let pionProcs = 0;
  let mbProcs = 0;

  for (const prog of live) {
    const id = prog.engine !== undefined && prog.mode !== undefined
      ? { engine: prog.engine, mode: prog.mode }
      : classifyProgram(prog.binary, prog.args);
    const key = `${id.engine}:${id.mode}`;
    let entry = grouped.get(key);
    if (entry === undefined) {
      entry = { engine: id.engine, mode: id.mode, liveCount: 0, rssBytes: tree !== null ? 0 : null };
      grouped.set(key, entry);
    }
    entry.liveCount++;
    if (id.engine === "pion") pionProcs++;
    else mbProcs++;

    if (tree !== null) {
      let bytes = 0;
      for (const queue = [prog.pid]; queue.length > 0; ) {
        const pid = queue.pop()!;
        if (seen.has(pid)) continue;
        seen.add(pid);
        bytes += tree.byPid.get(pid)?.bytes ?? 0;
        const kids = tree.children.get(pid);
        if (kids !== undefined) queue.push(...kids);
      }
      totalBytes += bytes;
      entry.rssBytes = (entry.rssBytes ?? 0) + bytes;
      if (id.engine === "pion") pionRssBytes = (pionRssBytes ?? 0) + bytes;
      else mbRssBytes = (mbRssBytes ?? 0) + bytes;
    }
  }

  return {
    byEngineMode: [...grouped.values()],
    totalBytes,
    totalCount: live.length,
    pionRssBytes,
    mbRssBytes,
    pionProcs,
    mbProcs,
  };
}

const EMPTY_RSS: RssBreakdown = {
  byEngineMode: [],
  totalBytes: 0,
  totalCount: 0,
  pionRssBytes: 0,
  mbRssBytes: 0,
  pionProcs: 0,
  mbProcs: 0,
};

export class ReaderTelemetry {
  readonly #maxSamples: number;
  readonly #buckets = new Map<string, Bucket>();
  #windowStartMs: number;
  #lastRss: RssBreakdown = EMPTY_RSS;
  #lastRssAt = 0;

  constructor(options: { maxSamples?: number; nowMs?: number } = {}) {
    this.#maxSamples = options.maxSamples ?? DEFAULT_MAX_SAMPLES;
    this.#windowStartMs = options.nowMs ?? wall.now();
  }

  #bucket(engine: TelemetryEngine, mode: string): Bucket {
    const key = `${engine}:${mode}`;
    let b = this.#buckets.get(key);
    if (b === undefined) {
      b = {
        engine,
        mode,
        spawns: 0,
        unexpectedExits: 0,
        stalls: 0,
        stderrLines: 0,
        fallbacks: 0,
        ops: 0,
        errors: 0,
        latency: new BoundedSamples(this.#maxSamples),
        readyCount: 0,
        readyTotal: new BoundedSamples(this.#maxSamples),
        readyLoaded: new BoundedSamples(this.#maxSamples),
        readyOpened: new BoundedSamples(this.#maxSamples),
        liveCount: 0,
        rssBytes: null,
        peakRssBytes: null,
      };
      this.#buckets.set(key, b);
    }
    return b;
  }

  recordSpawn(engine: TelemetryEngine, mode: string): void {
    this.#bucket(engine, mode).spawns++;
  }

  recordUnexpectedExit(engine: TelemetryEngine, mode: string): void {
    this.#bucket(engine, mode).unexpectedExits++;
  }

  recordStall(engine: TelemetryEngine, mode: string): void {
    this.#bucket(engine, mode).stalls++;
  }

  recordStderr(engine: TelemetryEngine, mode: string): void {
    this.#bucket(engine, mode).stderrLines++;
  }

  /// Record a fallback from requested `pion` back to `mb` when an MB process is actually spawned.
  recordFallback(mode: string): void {
    this.#bucket("pion", mode).fallbacks++;
  }

  recordReady(engine: TelemetryEngine, mode: string, wallMs: number, loadedMs?: number, openedMs?: number): void {
    const b = this.#bucket(engine, mode);
    b.readyCount++;
    b.readyTotal.add(wallMs);
    if (loadedMs !== undefined && Number.isFinite(loadedMs)) b.readyLoaded.add(loadedMs);
    if (openedMs !== undefined && Number.isFinite(openedMs)) b.readyOpened.add(openedMs);
  }

  recordCall(engine: TelemetryEngine, mode: string, ms: number, ok: boolean): void {
    const b = this.#bucket(engine, mode);
    b.ops++;
    if (!ok) b.errors++;
    b.latency.add(ms);
  }

  recordRssSnapshot(
    table: readonly ProcessInfo[] | null,
    live: readonly LiveProgram[],
    nowMs = wall.now(),
  ): RssBreakdown {
    const breakdown = programsByEngineMode(table, live);
    for (const b of this.#buckets.values()) {
      b.liveCount = 0;
      b.rssBytes = table !== null || live.length === 0 ? 0 : null;
    }
    for (const item of breakdown.byEngineMode) {
      const b = this.#bucket(item.engine, item.mode);
      b.liveCount = item.liveCount;
      b.rssBytes = item.rssBytes;
      if (item.rssBytes !== null) {
        if (b.peakRssBytes === null || item.rssBytes > b.peakRssBytes) {
          b.peakRssBytes = item.rssBytes;
        }
      }
    }
    this.#lastRss = breakdown;
    this.#lastRssAt = nowMs;
    return breakdown;
  }

  lastRss(): RssBreakdown {
    return this.#lastRss;
  }

  lastRssAgeMs(nowMs = wall.now()): number {
    if (this.#lastRssAt === 0) return Number.POSITIVE_INFINITY;
    return Math.max(0, nowMs - this.#lastRssAt);
  }

  /// Inspect current sample buffer length for a `(engine, mode)` bucket (tests only).
  sampleCountForTest(engine: TelemetryEngine, mode: string): number {
    return this.#buckets.get(`${engine}:${mode}`)?.latency.sampleCount ?? 0;
  }

  /// Flush all active `(engine, mode)` summaries for the completed window and reset
  /// window counters (preserving `liveCount` and `rssBytes` for still-running processes).
  flushWindow(nowMs = wall.now()): EngineModeSummary[] {
    const windowSec = Math.max(0, Math.round((nowMs - this.#windowStartMs) / 1000));
    this.#windowStartMs = nowMs;
    const out: EngineModeSummary[] = [];

    for (const [key, b] of this.#buckets) {
      const active =
        b.spawns > 0 ||
        b.ops > 0 ||
        b.errors > 0 ||
        b.fallbacks > 0 ||
        b.unexpectedExits > 0 ||
        b.stalls > 0 ||
        b.stderrLines > 0 ||
        b.readyCount > 0 ||
        b.liveCount > 0 ||
        (b.peakRssBytes !== null && b.peakRssBytes > 0);

      if (active) {
        const lat = b.latency.stats();
        const readyTotal = b.readyTotal.stats();
        const readyLoaded = b.readyLoaded.stats();
        const readyOpened = b.readyOpened.stats();
        const peakBytes =
          b.peakRssBytes !== null && b.rssBytes !== null ? Math.max(b.peakRssBytes, b.rssBytes)
            : b.peakRssBytes ?? b.rssBytes;
        const rssKb = bytesToKb(b.rssBytes);
        const peakKb = bytesToKb(peakBytes);

        out.push({
          windowSec,
          engine: b.engine,
          mode: b.mode,
          spawns: b.spawns,
          unexpectedExits: b.unexpectedExits,
          stalls: b.stalls,
          stderrLines: b.stderrLines,
          fallbacks: b.fallbacks,
          ops: b.ops,
          errors: b.errors,
          ...(lat !== null ? { p50Ms: lat.p50, p95Ms: lat.p95, maxMs: lat.max, avgMs: lat.avg } : {}),
          readyCount: b.readyCount,
          ...(readyTotal !== null ? { readyP50Ms: readyTotal.p50, readyMaxMs: readyTotal.max } : {}),
          ...(readyLoaded !== null ? { loadedP50Ms: readyLoaded.p50 } : {}),
          ...(readyOpened !== null ? { openedP50Ms: readyOpened.p50 } : {}),
          liveCount: b.liveCount,
          ...(rssKb !== null ? { engineRssKb: rssKb } : {}),
          ...(peakKb !== null ? { enginePeakRssKb: peakKb } : {}),
        });
      }

      // Reset window counters; keep live process snapshot until the next RSS sample.
      b.spawns = 0;
      b.unexpectedExits = 0;
      b.stalls = 0;
      b.stderrLines = 0;
      b.fallbacks = 0;
      b.ops = 0;
      b.errors = 0;
      b.latency.reset();
      b.readyCount = 0;
      b.readyTotal.reset();
      b.readyLoaded.reset();
      b.readyOpened.reset();
      b.peakRssBytes = null;

      if (b.liveCount === 0) {
        this.#buckets.delete(key);
      }
    }

    return out;
  }

  resetForTest(nowMs = wall.now()): void {
    this.#buckets.clear();
    this.#windowStartMs = nowMs;
    this.#lastRss = EMPTY_RSS;
    this.#lastRssAt = 0;
  }
}

/// Process-wide reader telemetry singleton used by `MbProcess`, `Readers`, builders, and `main.ts`.
export const readerTelemetry = new ReaderTelemetry();
