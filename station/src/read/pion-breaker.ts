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
//   - `isDemoted(mode, currentStamp)` is a pure in-memory lookup (zero hot-path `readFileSync`);
//     disk state is loaded on construction/`configure` and refreshed on `recordUnexpectedExit`.
//   - `recordUnexpectedExit` serializes cross-process read-merge-write through a short-lived
//     atomic lock directory (`${file}.lock`, with dead-PID / 5s stale takeover and bounded wait),
//     tracking per-event IDs so same-millisecond crashes are never deduplicated or double-counted.
//   - If disk persistence fails (ENOSPC / EROFS / unwritable path), uncommitted events remain in
//     memory so single-process K=3 demotion still trips, and flush cleanly once disk recovers.
// - Trips after `K = 3` unexpected exits within a `N = 5 min` sliding window for the same
//   `(mode, stampKey)`.
import { mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { type ReaderMode, type ReaderSelectSource, isReaderMode } from "./reader-select.ts";

export const BREAKER_WINDOW_MS = 5 * 60 * 1000;
export const BREAKER_THRESHOLD = 3;
const LOCK_STALE_MS = 5_000;
const LOCK_WAIT_MS = 2_000;
const LOCK_SLEEP_BUF = new Int32Array(new SharedArrayBuffer(4));

let writeSeq = 0;
let eventSeq = 0;

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

type BreakerEvent = {
  readonly at: number;
  readonly id: string;
};

type StampRecord = {
  readonly stamp: PionBinaryStamp;
  events: BreakerEvent[];
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
  let events: BreakerEvent[] = [];
  if (Array.isArray(o.events)) {
    events = o.events
      .filter((e): e is Record<string, unknown> => e !== null && typeof e === "object" && !Array.isArray(e))
      .filter((e) => typeof e.at === "number" && Number.isFinite(e.at) && typeof e.id === "string" && e.id !== "")
      .map((e) => ({ at: e.at as number, id: e.id as string }));
  } else if (Array.isArray(o.exits)) {
    // Backward compatibility with v2 records storing numeric `exits` only.
    events = o.exits
      .filter((t): t is number => typeof t === "number" && Number.isFinite(t))
      .map((at, idx) => ({ at, id: `legacy:${idx}:${at}` }));
  }
  const demotedAt = typeof o.demotedAt === "number" && Number.isFinite(o.demotedAt) ? o.demotedAt : undefined;
  return demotedAt !== undefined ? { stamp, events, demotedAt } : { stamp, events };
}

type DiskEntries = Map<ReaderMode, Map<string, StampRecord>>;

/// Preserve any `demotedAt` timestamps from `source` into `target` without re-merging `events` arrays.
function preserveDemotions(target: DiskEntries, source: DiskEntries): void {
  for (const [mode, srcMode] of source) {
    for (const [sKey, srcRec] of srcMode) {
      if (srcRec.demotedAt === undefined) continue;
      let dstMode = target.get(mode);
      if (dstMode === undefined) {
        dstMode = new Map();
        target.set(mode, dstMode);
      }
      const dstRec = dstMode.get(sKey);
      if (dstRec === undefined) {
        dstMode.set(sKey, { stamp: srcRec.stamp, events: [], demotedAt: srcRec.demotedAt });
      } else {
        dstRec.demotedAt = dstRec.demotedAt !== undefined
          ? Math.min(dstRec.demotedAt, srcRec.demotedAt)
          : srcRec.demotedAt;
      }
    }
  }
}

/// Short-lived cross-process lock directory (`${file}.lock`) used ONLY on the crash persistence path
/// (`recordUnexpectedExit`), with dead-PID / 5s stale takeover and bounded wait so a wedged lock never stalls Node.
function acquireFileLock(file: string): (() => void) | null {
  const lock = `${file}.lock`;
  try {
    mkdirSync(dirname(lock), { recursive: true }); // sync: crash-only cross-process breaker lock parent dir
  } catch {
    return null;
  }
  const deadline = wall.now() + LOCK_WAIT_MS;
  while (wall.now() < deadline) {
    try {
      mkdirSync(lock); // sync: crash-only cross-process atomic lockdir acquisition
      try {
        writeFileSync(join(lock, "pid"), String(process.pid), "utf8"); // sync: record lock holder pid for stale detection
      } catch {
        // Non-fatal: lockdir mtime still bounds staleness.
      }
      return () => {
        try {
          rmSync(lock, { recursive: true, force: true }); // sync: release crash-only cross-process breaker lockdir
        } catch {}
      };
    } catch (error) {
      const code = (error as NodeJS.ErrnoException | null)?.code;
      if (code !== "EEXIST") return null;
      let pid = 0;
      try {
        pid = Number(readFileSync(join(lock, "pid"), "utf8").trim()); // sync: check lock holder pid liveness
      } catch {}
      let alive = pid > 0 && Number.isInteger(pid);
      if (alive) {
        try {
          process.kill(pid, 0);
        } catch (killErr) {
          const kCode = (killErr as NodeJS.ErrnoException | null)?.code;
          if (kCode !== "EPERM") alive = false;
        }
      }
      let stale = false;
      try {
        stale = wall.now() - statSync(lock).mtimeMs > LOCK_STALE_MS; // sync: detect stale breaker lockdir
      } catch {}
      if ((!alive && pid > 0) || stale) {
        try {
          rmSync(lock, { recursive: true, force: true }); // sync: reclaim dead/stale breaker lockdir
        } catch {}
        continue;
      }
      Atomics.wait(LOCK_SLEEP_BUF, 0, 0, 10);
    }
  }
  return null;
}

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
          events: rec.events,
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
  readonly #pendingEvents: Map<ReaderMode, Map<string, { stamp: PionBinaryStamp; events: BreakerEvent[] }>> = new Map();

  constructor(options: { windowMs?: number; threshold?: number; stateFile?: string | null } = {}) {
    this.#windowMs = options.windowMs ?? BREAKER_WINDOW_MS;
    this.#threshold = options.threshold ?? BREAKER_THRESHOLD;
    this.#stateFile = options.stateFile ?? null;
    if (this.#stateFile !== null) this.#reloadFromDisk();
  }

  /// Bind this breaker to `<data>/run/pion-demoted.json` and load any persisted entries once.
  configure(stateFile: string | null): void {
    this.#stateFile = stateFile;
    this.#entries.clear();
    this.#pendingEvents.clear();
    if (stateFile !== null) this.#reloadFromDisk();
  }

  #replaceEntries(next: DiskEntries): void {
    this.#entries.clear();
    for (const [mode, modeMap] of next) this.#entries.set(mode, modeMap);
  }

  #reloadFromDisk(): void {
    if (this.#stateFile === null) return;
    const disk = readDiskEntries(this.#stateFile);
    preserveDemotions(disk, this.#entries);
    this.#replaceEntries(disk);
  }

  #writeEntriesToDisk(entries: DiskEntries, cutoff: number): boolean {
    const file = this.#stateFile;
    if (file === null) return false;
    const serializedEntries: Record<string, Record<string, { stamp: PionBinaryStamp; events: BreakerEvent[]; exits: number[]; demotedAt?: number }>> = {};
    for (const [mode, modeMap] of entries) {
      const obj: Record<string, { stamp: PionBinaryStamp; events: BreakerEvent[]; exits: number[]; demotedAt?: number }> = {};
      for (const [sKey, rec] of modeMap) {
        const events = rec.events.filter((e) => e.at > cutoff);
        if (rec.demotedAt === undefined && events.length === 0) continue;
        obj[sKey] = {
          stamp: rec.stamp,
          events,
          exits: events.map((e) => e.at),
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
      return true;
    } catch (error) {
      try {
        rmSync(tmp, { force: true }); // sync: cleanup failed temp breaker state file
      } catch {}
      log.warn("readers", "failed to persist pion circuit breaker state", {
        file,
        error: error instanceof Error ? error.message : String(error),
      });
      return false;
    }
  }

  #mergePendingInto(target: DiskEntries, cutoff: number): void {
    for (const [mode, byStamp] of this.#pendingEvents) {
      let modeMap = target.get(mode);
      if (modeMap === undefined) {
        modeMap = new Map();
        target.set(mode, modeMap);
      }
      for (const [sKey, pending] of byStamp) {
        pending.events = pending.events.filter((e) => e.at > cutoff);
        if (pending.events.length === 0) {
          byStamp.delete(sKey);
          continue;
        }
        let rec = modeMap.get(sKey);
        if (rec === undefined) {
          rec = { stamp: pending.stamp, events: [] };
          modeMap.set(sKey, rec);
        }
        rec.events = rec.events.filter((e) => e.at > cutoff);
        const seenIds = new Set(rec.events.map((e) => e.id));
        for (const ev of pending.events) {
          if (!seenIds.has(ev.id)) {
            rec.events.push(ev);
            seenIds.add(ev.id);
          }
        }
      }
      if (byStamp.size === 0) this.#pendingEvents.delete(mode);
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
    const sKey = pionStampKey(stamp);
    const cutoff = nowMs - this.#windowMs;
    const ev: BreakerEvent = { at: nowMs, id: `${process.pid}:${++eventSeq}` };

    if (this.#stateFile === null) {
      let modeMap = this.#entries.get(mode);
      if (modeMap === undefined) {
        modeMap = new Map();
        this.#entries.set(mode, modeMap);
      }
      let rec = modeMap.get(sKey);
      if (rec === undefined) {
        rec = { stamp, events: [] };
        modeMap.set(sKey, rec);
      }
      rec.events = rec.events.filter((e) => e.at > cutoff);
      rec.events.push(ev);
      if (rec.demotedAt !== undefined) return true;
      if (rec.events.length >= this.#threshold) {
        rec.demotedAt = nowMs;
        log.warn("readers", "pion default circuit breaker tripped; demoting mode to mb", {
          mode,
          path: stamp.path,
          exits: this.#threshold,
          windowMs: this.#windowMs,
        });
        return true;
      }
      return false;
    }

    // Track uncommitted event until atomic write succeeds so ENOSPC / EROFS never loses single-process
    // crash counts and disk recovery flushes each event at most once (deduplicated strictly by event id).
    let pendingMode = this.#pendingEvents.get(mode);
    if (pendingMode === undefined) {
      pendingMode = new Map();
      this.#pendingEvents.set(mode, pendingMode);
    }
    let pendingRec = pendingMode.get(sKey);
    if (pendingRec === undefined) {
      pendingRec = { stamp, events: [] };
      pendingMode.set(sKey, pendingRec);
    }
    pendingRec.events.push(ev);

    const release = acquireFileLock(this.#stateFile);
    try {
      const target = readDiskEntries(this.#stateFile);
      preserveDemotions(target, this.#entries);
      this.#mergePendingInto(target, cutoff);

      const rec = target.get(mode)?.get(sKey);
      let tripped = false;
      if (rec !== undefined) {
        rec.events = rec.events.filter((e) => e.at > cutoff);
        if (rec.demotedAt !== undefined) {
          tripped = true;
        } else if (rec.events.length >= this.#threshold) {
          rec.demotedAt = nowMs;
          tripped = true;
          log.warn("readers", "pion default circuit breaker tripped; demoting mode to mb", {
            mode,
            path: stamp.path,
            exits: this.#threshold,
            windowMs: this.#windowMs,
          });
        }
      }
      const persisted = this.#writeEntriesToDisk(target, cutoff);
      if (persisted) {
        this.#pendingEvents.clear();
      }
      // Always update in-memory state so ENOSPC / read-only disk still trips in-process demotion.
      this.#replaceEntries(target);
      return tripped;
    } finally {
      release?.();
    }
  }

  /// Check whether `(mode, currentStamp)` is currently demoted.
  /// Pure in-memory lookup (zero hot-path disk I/O); disk state is loaded at startup/`configure`
  /// and refreshed on `recordUnexpectedExit`.
  isDemoted(mode: ReaderMode, currentStamp: PionBinaryStamp | null): boolean {
    if (currentStamp === null) return false;
    return this.#entries.get(mode)?.get(pionStampKey(currentStamp))?.demotedAt !== undefined;
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
    this.#pendingEvents.clear();
    this.#windowMs = options?.windowMs ?? BREAKER_WINDOW_MS;
    this.#threshold = options?.threshold ?? BREAKER_THRESHOLD;
    this.#stateFile = options?.stateFile ?? null;
    if (this.#stateFile !== null) this.#reloadFromDisk();
  }
}

/// Fallback breaker used only when no per-station `ReaderConfig` breaker is supplied (e.g. standalone unit tests).
export const pionCircuitBreaker = new PionCircuitBreaker();
