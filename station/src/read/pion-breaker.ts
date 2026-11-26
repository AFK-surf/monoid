// Process-attributed default-only crash circuit breaker for Pion reader/builder processes.
//
// Invariants:
// - Completely independent of `readerTelemetry`'s 600s window flush (`reader-telemetry.ts`).
// - Strictly scoped to `source === "default"`: explicit `"pion"` / `"shadow"` from config or env
//   never increments or trips default counters.
// - Per-station instance (no cross-station interference in dual-station tests; default fallback
//   instance exists only for callers without an explicit station `ReaderConfig`).
// - Memory and disk state (`<data>/run/pion-demoted.jsonl`, lock-free `O_APPEND` JSONL) are
//   isolated by `(mode, stampKey)`:
//   - A late exit of binary A after A->B replacement never clears or modifies B's state.
//   - `isDemoted(mode, currentStamp)` is a pure in-memory O(1) lookup (zero hot-path `readFileSync`);
//     disk state is loaded once at construction/`configure`, kept fresh asynchronously via an unref'd
//     directory watcher (`fs.watch`), and synced on `recordUnexpectedExit`.
//   - Cross-process persistence uses lock-free `O_APPEND` single-line JSONL records (< 300 B) tagged
//     with a boot-unique event ID (`${BOOT_ID}:${seq}`), so concurrent processes never block the main
//     thread (`Atomics.wait`-free), never overwrite each other, and never suffer PID-reuse collisions.
//   - If disk append fails (ENOSPC / EROFS / unwritable path), uncommitted events stay in memory
//     (`#pendingEvents`) so single-process K=3 demotion still trips, and flush cleanly on recovery.
// - Trips after `K = 3` unexpected exits within a `N = 5 min` sliding window for the same
//   `(mode, stampKey)`.
import { randomUUID } from "node:crypto";
import { type FSWatcher, appendFileSync, mkdirSync, readFileSync, statSync, watch } from "node:fs";
import { open } from "node:fs/promises";
import { basename, dirname, resolve } from "node:path";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { type ReaderMode, type ReaderSelectSource, isReaderMode } from "./reader-select.ts";

export const BREAKER_WINDOW_MS = 5 * 60 * 1000;
export const BREAKER_THRESHOLD = 3;

const BOOT_ID = randomUUID();
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

type PendingAppend = {
  readonly mode: ReaderMode;
  readonly stamp: PionBinaryStamp;
  readonly ev: BreakerEvent;
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

type ParsedLine = {
  readonly mode: ReaderMode;
  readonly stamp: PionBinaryStamp;
  readonly events: BreakerEvent[];
  readonly demotedAt?: number;
};

function parseLegacyRecord(raw: unknown): { stamp: PionBinaryStamp; events: BreakerEvent[]; demotedAt?: number } | null {
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
    events = o.exits
      .filter((t): t is number => typeof t === "number" && Number.isFinite(t))
      .map((at, idx) => ({ at, id: `legacy:${idx}:${at}` }));
  }
  const demotedAt = typeof o.demotedAt === "number" && Number.isFinite(o.demotedAt) ? o.demotedAt : undefined;
  return demotedAt !== undefined ? { stamp, events, demotedAt } : { stamp, events };
}

function parseJsonlChunk(text: string): ParsedLine[] {
  const out: ParsedLine[] = [];
  const trimmed = text.trim();
  if (trimmed === "") return out;

  // Backward-compatible parse of legacy single-object JSON files (v1 `demoted` or v2 `entries`).
  if (trimmed.startsWith("{") && !trimmed.includes("\n{")) {
    try {
      const parsed = JSON.parse(trimmed) as { v?: unknown; entries?: unknown; demoted?: unknown; mode?: unknown };
      if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed) && parsed.mode === undefined) {
        if (parsed.v === 2 && parsed.entries !== null && typeof parsed.entries === "object" && !Array.isArray(parsed.entries)) {
          for (const [mode, byStamp] of Object.entries(parsed.entries as Record<string, unknown>)) {
            if (!isReaderMode(mode) || byStamp === null || typeof byStamp !== "object" || Array.isArray(byStamp)) continue;
            for (const rawRec of Object.values(byStamp as Record<string, unknown>)) {
              const rec = parseLegacyRecord(rawRec);
              if (rec !== null) out.push({ mode, ...rec });
            }
          }
          return out;
        }
        if (parsed.v === 1 && parsed.demoted !== null && typeof parsed.demoted === "object" && !Array.isArray(parsed.demoted)) {
          for (const [mode, rawEntry] of Object.entries(parsed.demoted as Record<string, unknown>)) {
            if (!isReaderMode(mode)) continue;
            const rec = parseLegacyRecord(rawEntry);
            if (rec !== null) out.push({ mode, stamp: rec.stamp, events: rec.events, demotedAt: rec.demotedAt ?? 0 });
          }
          return out;
        }
      }
    } catch {
      // Fall through to line-by-line JSONL parsing.
    }
  }

  for (const rawLine of text.split("\n")) {
    const line = rawLine.trim();
    if (line === "") continue;
    let obj: unknown;
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    if (obj === null || typeof obj !== "object" || Array.isArray(obj)) continue;
    const o = obj as Record<string, unknown>;
    if (typeof o.mode !== "string" || !isReaderMode(o.mode)) continue;
    const stamp = parseStamp(o.stamp);
    if (stamp === null) continue;
    const events: BreakerEvent[] = [];
    if (typeof o.at === "number" && Number.isFinite(o.at) && typeof o.id === "string" && o.id !== "") {
      events.push({ at: o.at, id: o.id });
    }
    const demotedAt = typeof o.demotedAt === "number" && Number.isFinite(o.demotedAt) ? o.demotedAt : undefined;
    if (events.length > 0 || demotedAt !== undefined) {
      out.push(demotedAt !== undefined ? { mode: o.mode, stamp, events, demotedAt } : { mode: o.mode, stamp, events });
    }
  }
  return out;
}

type DiskEntries = Map<ReaderMode, Map<string, StampRecord>>;

export class PionCircuitBreaker {
  #windowMs: number;
  #threshold: number;
  #stateFile: string | null;
  #watchEnabled: boolean;
  readonly #entries: DiskEntries = new Map();
  readonly #pendingEvents: PendingAppend[] = [];
  #readOffset = 0;
  #watcher: FSWatcher | null = null;
  #asyncReading = false;
  #asyncDirty = false;
  #closed = false;

  constructor(options: { windowMs?: number; threshold?: number; stateFile?: string | null; watch?: boolean } = {}) {
    this.#windowMs = options.windowMs ?? BREAKER_WINDOW_MS;
    this.#threshold = options.threshold ?? BREAKER_THRESHOLD;
    this.#stateFile = options.stateFile ?? null;
    this.#watchEnabled = options.watch ?? true;
    if (this.#stateFile !== null) {
      this.syncFromDisk();
      this.#ensureWatcher();
    }
  }

  /// Bind this breaker to `<data>/run/pion-demoted.jsonl`, load existing entries, and start watching for peer appends.
  configure(stateFile: string | null, options?: { watch?: boolean }): void {
    this.#closeWatcher();
    this.#stateFile = stateFile;
    if (options?.watch !== undefined) this.#watchEnabled = options.watch;
    this.#entries.clear();
    this.#pendingEvents.length = 0;
    this.#readOffset = 0;
    this.#closed = false;
    if (stateFile !== null) {
      this.syncFromDisk();
      this.#ensureWatcher();
    }
  }

  /// Stop watching the state file (called on station shutdown / test teardown).
  close(): void {
    this.#closed = true;
    this.#closeWatcher();
  }

  #closeWatcher(): void {
    if (this.#watcher !== null) {
      try {
        this.#watcher.close();
      } catch {}
      this.#watcher = null;
    }
  }

  #ensureWatcher(): void {
    if (this.#closed || !this.#watchEnabled || this.#stateFile === null || this.#watcher !== null) return;
    const file = this.#stateFile;
    const dir = dirname(file);
    const targetName = basename(file);
    try {
      const watcher = watch(dir, (_eventType, filename) => {
        if (this.#closed) return;
        if (filename && filename.toString() !== targetName) return;
        this.#scheduleAsyncRead();
      });
      watcher.on("error", () => {
        if (this.#watcher === watcher) this.#closeWatcher();
      });
      watcher.unref();
      this.#watcher = watcher;
    } catch {
      // Directory may not exist yet; retried on first successful append.
    }
  }

  #scheduleAsyncRead(): void {
    if (this.#closed || this.#stateFile === null) return;
    if (this.#asyncReading) {
      this.#asyncDirty = true;
      return;
    }
    this.#asyncReading = true;
    void this.#readAppendedAsync().finally(() => {
      this.#asyncReading = false;
      if (this.#asyncDirty && !this.#closed) {
        this.#asyncDirty = false;
        this.#scheduleAsyncRead();
      }
    });
  }

  async #readAppendedAsync(): Promise<void> {
    const file = this.#stateFile;
    if (file === null || this.#closed) return;
    let fh: Awaited<ReturnType<typeof open>> | null = null;
    try {
      fh = await open(file, "r");
      const st = await fh.stat();
      if (!st.isFile()) return;
      if (st.size < this.#readOffset) this.#readOffset = 0;
      const toRead = st.size - this.#readOffset;
      if (toRead <= 0) return;
      const buf = Buffer.allocUnsafe(toRead);
      let filled = 0;
      while (filled < toRead) {
        const { bytesRead } = await fh.read(buf, filled, toRead - filled, this.#readOffset + filled);
        if (bytesRead <= 0) break;
        filled += bytesRead;
      }
      if (filled <= 0) return;
      const slice = buf.subarray(0, filled);
      const lastNewline = slice.lastIndexOf(0x0a);
      if (lastNewline < 0) return;
      const complete = slice.subarray(0, lastNewline + 1).toString("utf8");
      this.#readOffset += lastNewline + 1;
      this.#applyParsed(parseJsonlChunk(complete));
    } catch {
      // File may not exist yet or be temporarily unreadable.
    } finally {
      await fh?.close().catch(() => {});
    }
  }

  /// Synchronously absorb any new records appended to `stateFile` (used at startup and on crash writes, never on `isDemoted`).
  syncFromDisk(): void {
    const file = this.#stateFile;
    if (file === null) return;
    let raw: Buffer;
    try {
      raw = readFileSync(file); // sync: load persisted JSONL breaker log at startup or crash boundary
    } catch {
      return;
    }
    if (raw.length < this.#readOffset) this.#readOffset = 0;
    if (raw.length === this.#readOffset) return;
    const slice = raw.subarray(this.#readOffset);
    const lastNewline = slice.lastIndexOf(0x0a);
    let text: string;
    if (lastNewline >= 0) {
      text = slice.subarray(0, lastNewline + 1).toString("utf8");
      this.#readOffset += lastNewline + 1;
    } else {
      // Support legacy single-JSON files without a trailing newline on initial full read.
      if (this.#readOffset !== 0) return;
      text = slice.toString("utf8");
      this.#readOffset = raw.length;
    }
    this.#applyParsed(parseJsonlChunk(text));
  }

  #getOrCreateRecord(mode: ReaderMode, stamp: PionBinaryStamp): StampRecord {
    const sKey = pionStampKey(stamp);
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
    return rec;
  }

  #recomputeDemotion(mode: ReaderMode, rec: StampRecord, logOnTrip: boolean): boolean {
    if (rec.demotedAt !== undefined) return true;
    if (rec.events.length < this.#threshold) return false;
    rec.events.sort((a, b) => a.at - b.at);
    for (let i = this.#threshold - 1; i < rec.events.length; i++) {
      if (rec.events[i]!.at - rec.events[i - this.#threshold + 1]!.at < this.#windowMs) {
        rec.demotedAt = rec.events[i]!.at;
        if (logOnTrip) {
          log.warn("readers", "pion default circuit breaker tripped; demoting mode to mb", {
            mode,
            path: rec.stamp.path,
            exits: this.#threshold,
            windowMs: this.#windowMs,
          });
        }
        return true;
      }
    }
    return false;
  }

  #applyParsed(lines: readonly ParsedLine[]): void {
    for (const item of lines) {
      const rec = this.#getOrCreateRecord(item.mode, item.stamp);
      if (item.demotedAt !== undefined) {
        rec.demotedAt = rec.demotedAt !== undefined ? Math.min(rec.demotedAt, item.demotedAt) : item.demotedAt;
      }
      if (item.events.length > 0) {
        const seen = new Set(rec.events.map((e) => e.id));
        for (const ev of item.events) {
          if (!seen.has(ev.id)) {
            rec.events.push(ev);
            seen.add(ev.id);
          }
        }
      }
      this.#recomputeDemotion(item.mode, rec, false);
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
    if (this.#stateFile !== null) this.syncFromDisk();

    const ev: BreakerEvent = { at: nowMs, id: `${BOOT_ID}:${++eventSeq}` };
    const rec = this.#getOrCreateRecord(mode, stamp);
    const cutoff = nowMs - this.#windowMs;
    rec.events = rec.events.filter((e) => e.at > cutoff);
    rec.events.push(ev);
    const tripped = this.#recomputeDemotion(mode, rec, true);

    if (this.#stateFile !== null) {
      this.#pendingEvents.push({ mode, stamp, ev });
      const file = this.#stateFile;
      const payload = this.#pendingEvents
        .map((p) => JSON.stringify({ v: 2, mode: p.mode, stamp: p.stamp, at: p.ev.at, id: p.ev.id }) + "\n")
        .join("");
      try {
        mkdirSync(dirname(file), { recursive: true }); // sync: ensure breaker JSONL parent dir on crash
        appendFileSync(file, payload, "utf8"); // sync: lock-free O_APPEND single-line JSONL persistence on crash
        this.#pendingEvents.length = 0;
        this.#ensureWatcher();
        // Absorb our own lines and any concurrent peer appends (recomputing demotion for every touched mode).
        this.syncFromDisk();
      } catch (error) {
        log.warn("readers", "failed to persist pion circuit breaker state", {
          file,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }
    return tripped || this.isDemoted(mode, stamp);
  }

  /// Check whether `(mode, currentStamp)` is currently demoted.
  /// Pure in-memory O(1) lookup (zero hot-path disk I/O); disk state is loaded at startup/`configure`,
  /// kept fresh asynchronously by `fs.watch`, and synced on `recordUnexpectedExit`.
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
  resetForTest(options?: { stateFile?: string | null; windowMs?: number; threshold?: number; watch?: boolean }): void {
    this.#closeWatcher();
    this.#entries.clear();
    this.#pendingEvents.length = 0;
    this.#readOffset = 0;
    this.#closed = false;
    this.#windowMs = options?.windowMs ?? BREAKER_WINDOW_MS;
    this.#threshold = options?.threshold ?? BREAKER_THRESHOLD;
    this.#stateFile = options?.stateFile ?? null;
    this.#watchEnabled = options?.watch ?? true;
    if (this.#stateFile !== null) {
      this.syncFromDisk();
      this.#ensureWatcher();
    }
  }
}

/// Fallback breaker used only when no per-station `ReaderConfig` breaker is supplied (e.g. standalone unit tests).
export const pionCircuitBreaker = new PionCircuitBreaker();
