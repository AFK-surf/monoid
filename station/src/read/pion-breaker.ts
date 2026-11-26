// Process-attributed default-only crash circuit breaker for Pion reader/builder processes.
//
// Invariants:
// - Completely independent of `readerTelemetry`'s 600s window flush (`reader-telemetry.ts`).
// - Strictly scoped to `source === "default"`: explicit `"pion"` / `"shadow"` from config or env
//   never increments or trips default counters.
// - Each spawned process binds `(source, mode, binaryStamp)` at spawn time so a late crash of
//   binary A after A->B replacement never demotes B.
// - Trips after `K = 3` unexpected exits within a `N = 5 min` sliding window for the same
//   `(mode, binaryStamp)`, persisting the demoted stamp atomically to `<data>/run/pion-demoted.json`
//   so Node `SIGUSR2` handovers do not reset crash loops.
// - Automatically clears demotion when the Pion binary's `binaryStamp` on disk changes.
import { mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { type ReaderMode, type ReaderSelectSource, isReaderMode } from "./reader-select.ts";

export const BREAKER_WINDOW_MS = 5 * 60 * 1000;
export const BREAKER_THRESHOLD = 3;

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

export type PionBreakerContext = {
  readonly source: ReaderSelectSource;
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

function stampKey(stamp: PionBinaryStamp): string {
  return `${stamp.path}\0${stamp.dev}\0${stamp.ino}\0${stamp.mtimeMs}\0${stamp.size}`;
}

function parseDemotedEntry(raw: unknown): DemotedPionEntry | null {
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
  const demotedAt = typeof o.demotedAt === "number" && Number.isFinite(o.demotedAt) ? o.demotedAt : 0;
  return {
    path: o.path,
    dev: o.dev,
    ino: o.ino,
    mtimeMs: o.mtimeMs,
    size: o.size,
    demotedAt,
  };
}

export class PionCircuitBreaker {
  #windowMs: number;
  #threshold: number;
  #stateFile: string | null;
  readonly #exits = new Map<string, number[]>();
  readonly #demoted = new Map<ReaderMode, DemotedPionEntry>();

  constructor(options: { windowMs?: number; threshold?: number; stateFile?: string | null } = {}) {
    this.#windowMs = options.windowMs ?? BREAKER_WINDOW_MS;
    this.#threshold = options.threshold ?? BREAKER_THRESHOLD;
    this.#stateFile = options.stateFile ?? null;
    if (this.#stateFile !== null) this.#loadFromDisk();
  }

  /// Bind this breaker to `<data>/run/pion-demoted.json` and load any persisted demotions.
  configure(stateFile: string | null): void {
    this.#stateFile = stateFile;
    this.#demoted.clear();
    if (stateFile !== null) this.#loadFromDisk();
  }

  #loadFromDisk(): void {
    const file = this.#stateFile;
    if (file === null) return;
    let text: string;
    try {
      text = readFileSync(file, "utf8"); // sync: startup load of persisted circuit-breaker demotions
    } catch {
      return;
    }
    try {
      const parsed = JSON.parse(text) as { v?: unknown; demoted?: unknown };
      if (parsed?.v !== 1 || parsed.demoted === null || typeof parsed.demoted !== "object" || Array.isArray(parsed.demoted)) {
        return;
      }
      for (const [mode, entryRaw] of Object.entries(parsed.demoted as Record<string, unknown>)) {
        if (!isReaderMode(mode)) continue;
        const entry = parseDemotedEntry(entryRaw);
        if (entry !== null) this.#demoted.set(mode, entry);
      }
    } catch {}
  }

  #saveToDisk(): void {
    const file = this.#stateFile;
    if (file === null) return;
    const demoted: Record<string, DemotedPionEntry> = {};
    for (const [mode, entry] of this.#demoted) {
      demoted[mode] = entry;
    }
    const payload = JSON.stringify({ v: 1, demoted }, null, 2) + "\n";
    const tmp = `${file}.${process.pid}.tmp`;
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
    const key = `${mode}\0${stampKey(stamp)}`;
    const cutoff = nowMs - this.#windowMs;
    const prev = this.#exits.get(key) ?? [];
    const recent = prev.filter((t) => t > cutoff);
    recent.push(nowMs);
    if (recent.length >= this.#threshold) {
      this.#exits.delete(key);
      const existing = this.#demoted.get(mode);
      if (existing === undefined || !samePionBinaryStamp(existing, stamp)) {
        this.#demoted.set(mode, { ...stamp, demotedAt: nowMs });
        this.#saveToDisk();
        log.warn("readers", "pion default circuit breaker tripped; demoting mode to mb", {
          mode,
          path: stamp.path,
          exits: this.#threshold,
          windowMs: this.#windowMs,
        });
      }
      return true;
    }
    this.#exits.set(key, recent);
    return false;
  }

  /// Check whether `(mode, currentStamp)` is currently demoted.
  /// If a demotion exists for an older stamp of `mode` (binary upgraded/recompiled on disk),
  /// automatically clears the demotion and persists the update.
  isDemoted(mode: ReaderMode, currentStamp: PionBinaryStamp | null): boolean {
    if (currentStamp === null) return false;
    const entry = this.#demoted.get(mode);
    if (entry === undefined) return false;
    if (samePionBinaryStamp(entry, currentStamp)) return true;
    this.#demoted.delete(mode);
    this.#saveToDisk();
    log.info("readers", "pion binary stamp changed; clearing circuit breaker demotion", {
      mode,
      path: currentStamp.path,
    });
    return false;
  }

  demotedEntry(mode: ReaderMode): DemotedPionEntry | null {
    return this.#demoted.get(mode) ?? null;
  }

  /// Clear in-memory state and optionally reconfigure (tests only).
  resetForTest(options?: { stateFile?: string | null; windowMs?: number; threshold?: number }): void {
    this.#exits.clear();
    this.#demoted.clear();
    this.#windowMs = options?.windowMs ?? BREAKER_WINDOW_MS;
    this.#threshold = options?.threshold ?? BREAKER_THRESHOLD;
    this.#stateFile = options?.stateFile ?? null;
    if (this.#stateFile !== null) this.#loadFromDisk();
  }
}

/// Process-wide default-only Pion crash circuit breaker singleton.
export const pionCircuitBreaker = new PionCircuitBreaker();
