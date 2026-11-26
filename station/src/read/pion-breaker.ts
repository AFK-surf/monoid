// Process-attributed default-only crash circuit breaker for Pion reader/builder processes.
//
// Invariants:
// - Completely independent of `readerTelemetry`'s 600s window flush (`reader-telemetry.ts`).
// - Strictly scoped to `source === "default"`: explicit `"pion"` / `"shadow"` from config or env
//   never increments or trips default counters.
// - Per-station instance (no cross-station interference in dual-station tests; default fallback
//   instance exists only for callers without an explicit station `ReaderConfig`).
// - Memory and disk state (`<data>/run/pion-demoted.json`, v2) are isolated by `(mode, stampKey)`:
//   - A late exit of binary A after A->B replacement never clears or modifies B's state.
//   - `isDemoted(mode, currentStamp)` never deletes other stamps' or other modes' records on disk.
//   - Persistence reads and merges existing disk state before atomically renaming a unique temp file,
//     so two overlapping Node processes during `SIGUSR2` handover never clobber each other's demotions
//     or lose sliding-window crash timestamps.
// - Trips after `K = 3` unexpected exits within a `N = 5 min` sliding window for the same
//   `(mode, stampKey)`.
import { mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { type ReaderMode, type ReaderSelectSource, isReaderMode } from "./reader-select.ts";

export const BREAKER_WINDOW_MS = 5 * 60 * 1000;
export const BREAKER_THRESHOLD = 3;

let writeSeq = 0;

export type PionBinaryStamp = {
  readonly path: string;
  readonly dev: number;
  readonly ino: number;
  readonly mtimeMs: number;
  readonly size: number;
};

export type DemotedPionEntry = PionBinaryStamp & {
  readonly demotedAt: number;
};

type StampRecord = {
  readonly stamp: PionBinaryStamp;
  exits: number[];
  demotedAt?: number;
};

export type PionBreakerContext = {
  readonly breaker: PionCircuitBreaker;
  readonly source: "default";
  readonly mode: ReaderMode;
  readonly stamp: PionBinaryStamp;
};

export function pionBinaryStamp(binaryPath: string): PionBinaryStamp | null {
  try {
    const resolved = resolve(binaryPath);
    const st = statSync(resolved); // sync: atomic binary identity check at Pion spawn/selection boundary
    if (!st.isFile()) return null;
    return {
      path: resolved,
      dev: st.dev,
      ino: st.ino,
      mtimeMs: st.mtimeMs,
      size: st.size,
    };
  } catch {
    return null;
  }
}

export function samePionBinaryStamp(a: PionBinaryStamp, b: PionBinaryStamp): boolean {
  return a.path === b.path && a.dev === b.dev && a.ino === b.ino && a.mtimeMs === b.mtimeMs && a.size === b.size;
}

export function pionStampKey(stamp: PionBinaryStamp): string {
  return `${stamp.path}\0${stamp.dev}\0${stamp.ino}\0${stamp.mtimeMs}\0${stamp.size}`;
}

function parseStamp(raw: unknown): PionBinaryStamp | null {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
  const o = raw as Record<string, unknown>;
  if (
    typeof o.path !== "string" ||
    typeof o.dev !== "number" ||
    !Number.isFinite(o.dev) ||
    typeof o.ino !== "number" ||
    !Number.isFinite(o.ino) ||
    typeof o.mtimeMs !== "number" ||
    !Number.isFinite(o.mtimeMs) ||
    typeof o.size !== "number" ||
    !Number.isFinite(o.size)
  ) {
    return null;
  }
  return {
    path: o.path,
    dev: o.dev,
    ino: o.ino,
    mtimeMs: o.mtimeMs,
    size: o.size,
  };
}

function parseRecord(raw: unknown): StampRecord | null {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
  const o = raw as Record<string, unknown>;
  const stamp = parseStamp(o.stamp ?? o);
  if (stamp === null) return null;
  const exits = Array.isArray(o.exits)
    ? o.exits.filter((t): t is number => typeof t === "number" && Number.isFinite(t))
    : [];
  const demotedAt = typeof o.demotedAt === "number" && Number.isFinite(o.demotedAt) ? o.demotedAt : undefined;
  return demotedAt !== undefined ? { stamp, exits, demotedAt } : { stamp, exits };
}

function mergeExits(a: readonly number[], b: readonly number[], cutoff: number): number[] {
  const merged = [...a, ...b].filter((t) => t > cutoff).sort((x, y) => x - y);
  // Deduplicate exact identical timestamps from shared disk/memory state.
  const out: number[] = [];
  for (const t of merged) {
    if (out.length === 0 || out[out.length - 1] !== t) out.push(t);
  }
  return out;
}

type DiskEntries = Map<ReaderMode, Map<string, StampRecord>>;

function readDiskEntries(file: string): DiskEntries {
  const out: DiskEntries = new Map();
  let text: string;
  try {
    text = readFileSync(file, "utf8"); // sync: atomic read-merge of persisted circuit-breaker state
  } catch {
    return out;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return out;
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return out;
  const root = parsed as { v?: unknown; entries?: unknown; demoted?: unknown };
  if (root.v === 2 && root.entries !== null && typeof root.entries === "object" && !Array.isArray(root.entries)) {
    for (const [mode, byStamp] of Object.entries(root.entries as Record<string, unknown>)) {
      if (!isReaderMode(mode) || byStamp === null || typeof byStamp !== "object" || Array.isArray(byStamp)) continue;
      const modeMap = new Map<string, StampRecord>();
      for (const rawRec of Object.values(byStamp as Record<string, unknown>)) {
        const rec = parseRecord(rawRec);
        if (rec !== null) modeMap.set(pionStampKey(rec.stamp), rec);
      }
      if (modeMap.size > 0) out.set(mode, modeMap);
    }
    return out;
  }
  // Backward-compatible read of v1 `{ v: 1, demoted: { mode: entry } }`.
  if (root.v === 1 && root.demoted !== null && typeof root.demoted === "object" && !Array.isArray(root.demoted)) {
    for (const [mode, rawEntry] of Object.entries(root.demoted as Record<string, unknown>)) {
      if (!isReaderMode(mode)) continue;
      const rec = parseRecord(rawEntry);
      if (rec !== null) {
        const modeMap = new Map<string, StampRecord>();
        modeMap.set(pionStampKey(rec.stamp), {
          stamp: rec.stamp,
          exits: rec.exits,
          demotedAt: rec.demotedAt ?? 0,
        });
        out.set(mode, modeMap);
      }
    }
  }
  return out;
}

export class PionCircuitBreaker {
  #windowMs: number;
  #threshold: number;
  #stateFile: string | null;
  readonly #entries: DiskEntries = new Map();

  constructor(options: { windowMs?: number; threshold?: number; stateFile?: string | null } = {}) {
    this.#windowMs = options.windowMs ?? BREAKER_WINDOW_MS;
    this.#threshold = options.threshold ?? BREAKER_THRESHOLD;
    this.#stateFile = options.stateFile ?? null;
    if (this.#stateFile !== null) this.#mergeFromDisk(wall.now());
  }

  /// Bind this breaker to `<data>/run/pion-demoted.json` and load any persisted entries.
  configure(stateFile: string | null): void {
    this.#stateFile = stateFile;
    this.#entries.clear();
    if (stateFile !== null) this.#mergeFromDisk(wall.now());
  }

  #mergeInto(target: DiskEntries, source: DiskEntries, cutoff: number): void {
    for (const [mode, srcMode] of source) {
      let dstMode = target.get(mode);
      if (dstMode === undefined) {
        dstMode = new Map();
        target.set(mode, dstMode);
      }
      for (const [sKey, srcRec] of srcMode) {
        const dstRec = dstMode.get(sKey);
        if (dstRec === undefined) {
          const exits = srcRec.exits.filter((t) => t > cutoff);
          if (srcRec.demotedAt !== undefined || exits.length > 0) {
            dstMode.set(sKey, {
              stamp: srcRec.stamp,
              exits,
              ...(srcRec.demotedAt !== undefined ? { demotedAt: srcRec.demotedAt } : {}),
            });
          }
        } else {
          dstRec.exits = mergeExits(dstRec.exits, srcRec.exits, cutoff);
          if (srcRec.demotedAt !== undefined) {
            dstRec.demotedAt = dstRec.demotedAt !== undefined ? Math.min(dstRec.demotedAt, srcRec.demotedAt) : srcRec.demotedAt;
          }
        }
      }
      if (dstMode.size === 0) target.delete(mode);
    }
  }

  #mergeFromDisk(nowMs: number): void {
    if (this.#stateFile === null) return;
    const disk = readDiskEntries(this.#stateFile);
    this.#mergeInto(this.#entries, disk, nowMs - this.#windowMs);
  }

  #saveMergedToDisk(nowMs: number): void {
    const file = this.#stateFile;
    if (file === null) return;
    const cutoff = nowMs - this.#windowMs;
    // Read-merge-write: preserve any demotions or crash timestamps written concurrently by another process.
    const merged = readDiskEntries(file);
    this.#mergeInto(merged, this.#entries, cutoff);
    // Keep in-memory state in sync with merged disk state.
    this.#mergeInto(this.#entries, merged, cutoff);

    const serializedEntries: Record<string, Record<string, StampRecord>> = {};
    for (const [mode, modeMap] of merged) {
      const obj: Record<string, StampRecord> = {};
      for (const [sKey, rec] of modeMap) {
        const exits = rec.exits.filter((t) => t > cutoff);
        if (rec.demotedAt === undefined && exits.length === 0) continue;
        obj[sKey] = {
          stamp: rec.stamp,
          exits,
          ...(rec.demotedAt !== undefined ? { demotedAt: rec.demotedAt } : {}),
        };
      }
      if (Object.keys(obj).length > 0) serializedEntries[mode] = obj;
    }

    const payload = JSON.stringify({ v: 2, entries: serializedEntries }, null, 2) + "\n";
    const tmp = `${file}.${process.pid}.${++writeSeq}.tmp`;
    try {
      mkdirSync(dirname(file), { recursive: true }); // sync: atomic breaker state persistence across handover
      writeFileSync(tmp, payload, "utf8"); // sync: atomic breaker state persistence across handover
      renameSync(tmp, file); // sync: atomic breaker state persistence across handover
    } catch (error) {
      try {
        rmSync(tmp, { force: true }); // sync: cleanup failed temp breaker state file
      } catch {}
      log.warn("readers", "failed to persist pion circuit breaker state", {
        file,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  /// Record an unexpected exit of a Pion process bound at spawn to `(source, mode, stamp)`.
  /// Only `source === "default"` counts; explicit `"pion"` / `"shadow"` exits are ignored.
  /// Returns `true` if this exit tripped (or reaffirmed) demotion for `(mode, stamp)`.
  recordUnexpectedExit(
    mode: ReaderMode,
    stamp: PionBinaryStamp,
    source: ReaderSelectSource,
    nowMs = wall.now(),
  ): boolean {
    if (source !== "default") return false;
    this.#mergeFromDisk(nowMs);
    const sKey = pionStampKey(stamp);
    let modeMap = this.#entries.get(mode);
    if (modeMap === undefined) {
      modeMap = new Map();
      this.#entries.set(mode, modeMap);
    }
    const cutoff = nowMs - this.#windowMs;
    let rec = modeMap.get(sKey);
    if (rec === undefined) {
      rec = { stamp, exits: [] };
      modeMap.set(sKey, rec);
    }
    rec.exits = rec.exits.filter((t) => t > cutoff);
    rec.exits.push(nowMs);

    let tripped = false;
    if (rec.demotedAt !== undefined) {
      tripped = true;
    } else if (rec.exits.length >= this.#threshold) {
      rec.demotedAt = nowMs;
      tripped = true;
      log.warn("readers", "pion default circuit breaker tripped; demoting mode to mb", {
        mode,
        path: stamp.path,
        exits: this.#threshold,
        windowMs: this.#windowMs,
      });
    }
    // Persist both window exits and demotions so SIGUSR2 handover never resets a crash loop.
    this.#saveMergedToDisk(nowMs);
    return tripped;
  }

  /// Check whether `(mode, currentStamp)` is currently demoted.
  /// Strictly isolated by `(mode, stampKey)`: never deletes other stamps' or modes' records on disk.
  isDemoted(mode: ReaderMode, currentStamp: PionBinaryStamp | null): boolean {
    if (currentStamp === null) return false;
    const sKey = pionStampKey(currentStamp);
    const inMem = this.#entries.get(mode)?.get(sKey);
    if (inMem?.demotedAt !== undefined) return true;
    if (this.#stateFile !== null) {
      this.#mergeFromDisk(wall.now());
      return this.#entries.get(mode)?.get(sKey)?.demotedAt !== undefined;
    }
    return false;
  }

  demotedEntry(mode: ReaderMode, currentStamp?: PionBinaryStamp | null): DemotedPionEntry | null {
    const modeMap = this.#entries.get(mode);
    if (modeMap === undefined) return null;
    if (currentStamp != null) {
      const rec = modeMap.get(pionStampKey(currentStamp));
      return rec?.demotedAt !== undefined ? { ...rec.stamp, demotedAt: rec.demotedAt } : null;
    }
    for (const rec of modeMap.values()) {
      if (rec.demotedAt !== undefined) return { ...rec.stamp, demotedAt: rec.demotedAt };
    }
    return null;
  }

  /// Clear in-memory state and optionally reconfigure (tests only).
  resetForTest(options?: { stateFile?: string | null; windowMs?: number; threshold?: number }): void {
    this.#entries.clear();
    this.#windowMs = options?.windowMs ?? BREAKER_WINDOW_MS;
    this.#threshold = options?.threshold ?? BREAKER_THRESHOLD;
    this.#stateFile = options?.stateFile ?? null;
    if (this.#stateFile !== null) this.#mergeFromDisk(wall.now());
  }
}

/// Fallback breaker used only when no per-station `ReaderConfig` breaker is supplied (e.g. standalone unit tests).
export const pionCircuitBreaker = new PionCircuitBreaker();
