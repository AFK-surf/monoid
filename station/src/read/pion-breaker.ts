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
//   - `isDemoted(mode, currentStamp)` is a pure in-memory O(1) lookup (zero hot-path disk I/O);
//     disk state is loaded incrementally at construction/`configure`, kept fresh asynchronously via
//     an unref'd directory watcher (`fs.watch` with exponential-backoff self-healing on error), and
//     incrementally synced on `recordUnexpectedExit`.
//   - Cross-process persistence uses lock-free `O_APPEND` single-line JSONL records (< 300 B)
//     prefixed and suffixed with `\n` (immune to torn trailing partial lines) and tagged with a
//     boot-unique event ID (`${BOOT_ID}:${seq}`), so concurrent processes never block the main
//     thread (`Atomics.wait`-free), never overwrite each other, and never suffer PID-reuse collisions.
//   - Once a `(mode, stampKey)` demotion is confirmed persisted on disk, further exits stop
//     appending redundant lines; on startup/`configure`, files exceeding `MAX_LOG_BYTES` (64 KiB)
//     are atomically compacted down to demoted records and active sliding-window events.
//   - If disk append fails (ENOSPC / EROFS / unwritable path), uncommitted events stay in memory
//     (`#pendingEvents`) so single-process K=3 demotion still trips, and flush on recovery or `close()`.
// - Trips after `K = 3` unexpected exits within a `N = 5 min` sliding window for the same
//   `(mode, stampKey)`.
import { randomUUID } from "node:crypto";
import {
  type FSWatcher,
  appendFileSync,
  closeSync,
  fstatSync,
  mkdirSync,
  openSync,
  readSync,
  renameSync,
  statSync,
  unlinkSync,
  watch,
  writeFileSync,
} from "node:fs";
import { open } from "node:fs/promises";
import { basename, dirname, resolve } from "node:path";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { type ReaderMode, type ReaderSelectSource, isReaderMode } from "./reader-select.ts";

export const BREAKER_WINDOW_MS = 5 * 60 * 1000;
export const BREAKER_THRESHOLD = 3;
export const MAX_LOG_BYTES = 64 * 1024;

const WATCH_RETRY_INITIAL_MS = 50;
const WATCH_RETRY_MAX_MS = 5_000;

const BOOT_ID = randomUUID();
let eventSeq = 0;

export type BreakerWatchFn = (
  dir: string,
  listener: (eventType: string, filename: string | Buffer | null) => void,
) => FSWatcher;

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
  readonly seenIds: Set<string>;
  demotedAt?: number;
  demotedPersisted: boolean;
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
  readonly ev?: BreakerEvent;
  readonly demotedAt?: number;
};

function parseJsonlChunk(text: string): ParsedLine[] {
  const out: ParsedLine[] = [];
  if (text.length === 0) return out;

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
    const ev =
      typeof o.at === "number" && Number.isFinite(o.at) && typeof o.id === "string" && o.id !== ""
        ? { at: o.at, id: o.id }
        : undefined;
    const demotedAt = typeof o.demotedAt === "number" && Number.isFinite(o.demotedAt) ? o.demotedAt : undefined;
    if (ev !== undefined || demotedAt !== undefined) {
      out.push({ mode: o.mode, stamp, ...(ev !== undefined ? { ev } : {}), ...(demotedAt !== undefined ? { demotedAt } : {}) });
    }
  }
  return out;
}

type DiskEntries = Map<ReaderMode, Map<string, StampRecord>>;

export type PionCircuitBreakerOptions = {
  windowMs?: number;
  threshold?: number;
  stateFile?: string | null;
  watch?: boolean;
  watchFn?: BreakerWatchFn;
};

export class PionCircuitBreaker {
  #windowMs: number;
  #threshold: number;
  #stateFile: string | null;
  #watchEnabled: boolean;
  #watchFn: BreakerWatchFn;
  readonly #entries: DiskEntries = new Map();
  readonly #pendingEvents: PendingAppend[] = [];
  #readOffset = 0;
  #lastDiskSize = 0;
  #watcher: FSWatcher | null = null;
  #cancelWatchRetry: (() => void) | null = null;
  #watchRetryDelayMs = WATCH_RETRY_INITIAL_MS;
  #watcherNeedsCatchup = false;
  #asyncReading = false;
  #asyncDirty = false;
  #closed = false;

  constructor(options: PionCircuitBreakerOptions = {}) {
    this.#windowMs = options.windowMs ?? BREAKER_WINDOW_MS;
    this.#threshold = options.threshold ?? BREAKER_THRESHOLD;
    this.#stateFile = options.stateFile ?? null;
    this.#watchEnabled = options.watch ?? true;
    this.#watchFn = options.watchFn ?? watch;
    if (this.#stateFile !== null) {
      this.#ensureWatcher();
      this.syncFromDisk();
      this.#maybeCompactOnStartup();
    }
  }

  /// Bind this breaker to `<data>/run/pion-demoted.jsonl`, attach watcher, load existing entries, and compact if oversized.
  configure(stateFile: string | null, options?: { watch?: boolean; watchFn?: BreakerWatchFn }): void {
    this.#closeWatcher();
    this.#stateFile = stateFile;
    if (options?.watch !== undefined) this.#watchEnabled = options.watch;
    if (options?.watchFn !== undefined) this.#watchFn = options.watchFn;
    this.#entries.clear();
    this.#pendingEvents.length = 0;
    this.#readOffset = 0;
    this.#lastDiskSize = 0;
    this.#watchRetryDelayMs = WATCH_RETRY_INITIAL_MS;
    this.#watcherNeedsCatchup = false;
    this.#closed = false;
    if (stateFile !== null) {
      this.#ensureWatcher();
      this.syncFromDisk();
      this.#maybeCompactOnStartup();
    }
  }

  /// Flush any pending in-memory crash events to disk and stop watching (called on station shutdown / handover / test teardown).
  close(): void {
    this.flushPending();
    this.#closed = true;
    this.#closeWatcher();
  }

  #cancelRetryTimer(): void {
    if (this.#cancelWatchRetry !== null) {
      this.#cancelWatchRetry();
      this.#cancelWatchRetry = null;
    }
  }

  #closeWatcher(): void {
    this.#cancelRetryTimer();
    if (this.#watcher !== null) {
      try {
        this.#watcher.close();
      } catch {}
      this.#watcher = null;
    }
  }

  #scheduleWatchRetry(): void {
    if (this.#closed || !this.#watchEnabled || this.#stateFile === null || this.#watcher !== null) return;
    if (this.#cancelWatchRetry !== null) return;
    const delay = this.#watchRetryDelayMs;
    this.#watchRetryDelayMs = Math.min(this.#watchRetryDelayMs * 2, WATCH_RETRY_MAX_MS);
    // timer: failure retry with exponential backoff when fs.watch setup or runtime fails
    this.#cancelWatchRetry = wall.after(delay, () => {
      this.#cancelWatchRetry = null;
      this.#ensureWatcher();
    });
  }

  #ensureWatcher(): void {
    if (this.#closed || !this.#watchEnabled || this.#stateFile === null || this.#watcher !== null) return;
    const file = this.#stateFile;
    const dir = dirname(file);
    const targetName = basename(file);
    try {
      const watcher = this.#watchFn(dir, (_eventType, filename) => {
        if (this.#closed) return;
        if (filename && filename.toString() !== targetName) return;
        this.#scheduleAsyncRead();
      });
      watcher.on("error", () => {
        if (this.#watcher === watcher) {
          try {
            watcher.close();
          } catch {}
          this.#watcher = null;
          this.#watcherNeedsCatchup = true;
          this.#scheduleWatchRetry();
        }
      });
      watcher.unref();
      this.#watcher = watcher;
      this.#watchRetryDelayMs = WATCH_RETRY_INITIAL_MS;
      this.#cancelRetryTimer();
      if (this.#watcherNeedsCatchup) {
        this.#watcherNeedsCatchup = false;
        this.#scheduleAsyncRead();
      }
    } catch {
      this.#watcherNeedsCatchup = true;
      this.#scheduleWatchRetry();
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
      this.#lastDiskSize = st.size;
      // Snapshot local offset before awaiting fh.read so a synchronous syncFromDisk() during the await
      // cannot cause this.#readOffset to be incremented twice and skip newly appended lines.
      const truncated = st.size < this.#readOffset;
      const startOffset = truncated ? 0 : this.#readOffset;
      const toRead = st.size - startOffset;
      if (toRead <= 0) return;
      const buf = Buffer.allocUnsafe(toRead);
      let filled = 0;
      while (filled < toRead) {
        const { bytesRead } = await fh.read(buf, filled, toRead - filled, startOffset + filled);
        if (bytesRead <= 0) break;
        filled += bytesRead;
      }
      if (filled <= 0) return;
      const slice = buf.subarray(0, filled);
      const lastNewline = slice.lastIndexOf(0x0a);
      if (lastNewline < 0) return;
      const complete = slice.subarray(0, lastNewline + 1).toString("utf8");
      const nextOffset = startOffset + lastNewline + 1;
      this.#readOffset = truncated ? nextOffset : Math.max(this.#readOffset, nextOffset);
      this.#applyParsed(parseJsonlChunk(complete));
    } catch {
      // File may not exist yet or be temporarily unreadable.
    } finally {
      await fh?.close().catch(() => {});
    }
  }

  /// Synchronously and incrementally absorb newly appended bytes from `stateFile` (used at startup and on crash writes, never on `isDemoted`).
  syncFromDisk(): void {
    const file = this.#stateFile;
    if (file === null) return;
    let fd: number | null = null;
    try {
      fd = openSync(file, "r"); // sync: incremental JSONL breaker read at startup or crash boundary
      const st = fstatSync(fd); // sync: stat open breaker fd to detect truncation or appended bytes
      if (!st.isFile()) return;
      this.#lastDiskSize = st.size;
      if (st.size < this.#readOffset) this.#readOffset = 0;
      const toRead = st.size - this.#readOffset;
      if (toRead <= 0) return;
      const buf = Buffer.allocUnsafe(toRead);
      let filled = 0;
      while (filled < toRead) {
        const bytesRead = readSync(fd, buf, filled, toRead - filled, this.#readOffset + filled); // sync: read only newly appended JSONL bytes
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
      return;
    } finally {
      if (fd !== null) {
        try {
          closeSync(fd); // sync: close incremental breaker fd
        } catch {}
      }
    }
  }

  #maybeCompactOnStartup(): void {
    const file = this.#stateFile;
    if (file === null || this.#lastDiskSize <= MAX_LOG_BYTES) return;
    const cutoff = wall.now() - this.#windowMs;
    const lines: string[] = [];
    for (const [mode, byStamp] of this.#entries) {
      for (const rec of byStamp.values()) {
        if (rec.demotedAt !== undefined) {
          lines.push(JSON.stringify({ v: 2, mode, stamp: rec.stamp, demotedAt: rec.demotedAt }));
        } else {
          for (const ev of rec.events) {
            if (ev.at > cutoff) {
              lines.push(JSON.stringify({ v: 2, mode, stamp: rec.stamp, at: ev.at, id: ev.id }));
            }
          }
        }
      }
    }
    const compacted = lines.length > 0 ? `${lines.join("\n")}\n` : "";
    const tmp = `${file}.tmp.${process.pid}.${randomUUID()}`;
    try {
      writeFileSync(tmp, compacted, "utf8"); // sync: atomic compaction of oversized breaker log on startup
      renameSync(tmp, file); // sync: atomically replace oversized breaker log with bounded snapshot
      const newSize = Buffer.byteLength(compacted, "utf8");
      this.#readOffset = newSize;
      this.#lastDiskSize = newSize;
    } catch (error) {
      try {
        unlinkSync(tmp); // sync: clean up failed breaker compaction temp file
      } catch {}
      log.warn("readers", "failed to compact pion circuit breaker state", {
        file,
        error: error instanceof Error ? error.message : String(error),
      });
    }
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
      rec = { stamp, events: [], seenIds: new Set(), demotedPersisted: false };
      modeMap.set(sKey, rec);
    }
    return rec;
  }

  #hasPendingFor(mode: ReaderMode, stamp: PionBinaryStamp): boolean {
    if (this.#pendingEvents.length === 0) return false;
    const targetKey = pionStampKey(stamp);
    return this.#pendingEvents.some((p) => p.mode === mode && pionStampKey(p.stamp) === targetKey);
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
    const touched = new Map<string, { mode: ReaderMode; rec: StampRecord }>();
    for (const item of lines) {
      const rec = this.#getOrCreateRecord(item.mode, item.stamp);
      if (rec.demotedPersisted) continue;
      if (item.demotedAt !== undefined) {
        rec.demotedAt = rec.demotedAt !== undefined ? Math.min(rec.demotedAt, item.demotedAt) : item.demotedAt;
        rec.demotedPersisted = true;
        rec.events.length = 0;
        rec.seenIds.clear();
        continue;
      }
      if (item.ev !== undefined && !rec.seenIds.has(item.ev.id)) {
        rec.seenIds.add(item.ev.id);
        rec.events.push(item.ev);
        touched.set(`${item.mode}\0${pionStampKey(item.stamp)}`, { mode: item.mode, rec });
      }
    }
    for (const { mode, rec } of touched.values()) {
      if (rec.demotedPersisted) continue;
      this.#recomputeDemotion(mode, rec, false);
      if (rec.demotedAt !== undefined && !this.#hasPendingFor(mode, rec.stamp)) {
        rec.demotedPersisted = true;
        rec.events.length = 0;
        rec.seenIds.clear();
      }
    }
  }

  /// Flush any pending in-memory crash events to `stateFile` via lock-free `O_APPEND`.
  /// Never throws; logs a warning and preserves `#pendingEvents` on disk failure.
  flushPending(): boolean {
    const file = this.#stateFile;
    if (file === null || this.#pendingEvents.length === 0) return true;
    // Leading `\n` isolates each record from any torn partial trailing line left by a hard kill.
    const payload = this.#pendingEvents
      .map((p) => `\n${JSON.stringify({ v: 2, mode: p.mode, stamp: p.stamp, at: p.ev.at, id: p.ev.id })}\n`)
      .join("");
    try {
      mkdirSync(dirname(file), { recursive: true }); // sync: ensure breaker JSONL parent dir on flush
      appendFileSync(file, payload, "utf8"); // sync: lock-free O_APPEND single-line JSONL persistence
      this.#pendingEvents.length = 0;
      for (const byStamp of this.#entries.values()) {
        for (const rec of byStamp.values()) {
          if (rec.demotedAt !== undefined) {
            rec.demotedPersisted = true;
            rec.events.length = 0;
            rec.seenIds.clear();
          }
        }
      }
      return true;
    } catch (error) {
      log.warn("readers", "failed to persist pion circuit breaker state", {
        file,
        error: error instanceof Error ? error.message : String(error),
      });
      return false;
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

    const rec = this.#getOrCreateRecord(mode, stamp);
    if (rec.demotedAt !== undefined && rec.demotedPersisted) {
      if (this.#stateFile !== null && this.#pendingEvents.length > 0 && this.flushPending()) {
        this.#ensureWatcher();
        this.syncFromDisk();
      }
      return true;
    }

    let tripped = rec.demotedAt !== undefined;
    if (rec.demotedAt === undefined) {
      const ev: BreakerEvent = { at: nowMs, id: `${BOOT_ID}:${++eventSeq}` };
      const cutoff = nowMs - this.#windowMs;
      if (rec.events.length > 0) {
        const kept: BreakerEvent[] = [];
        for (const existing of rec.events) {
          if (existing.at > cutoff) kept.push(existing);
          else rec.seenIds.delete(existing.id);
        }
        rec.events = kept;
      }
      rec.events.push(ev);
      rec.seenIds.add(ev.id);
      tripped = this.#recomputeDemotion(mode, rec, true);
      if (this.#stateFile !== null) {
        this.#pendingEvents.push({ mode, stamp, ev });
      }
    }

    if (this.#stateFile !== null && this.#pendingEvents.length > 0) {
      if (this.flushPending()) {
        this.#ensureWatcher();
        // Absorb our own lines and any concurrent peer appends (recomputing demotion for every touched mode).
        this.syncFromDisk();
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
  resetForTest(options?: PionCircuitBreakerOptions): void {
    this.#closeWatcher();
    this.#entries.clear();
    this.#pendingEvents.length = 0;
    this.#readOffset = 0;
    this.#lastDiskSize = 0;
    this.#watchRetryDelayMs = WATCH_RETRY_INITIAL_MS;
    this.#watcherNeedsCatchup = false;
    this.#closed = false;
    this.#windowMs = options?.windowMs ?? BREAKER_WINDOW_MS;
    this.#threshold = options?.threshold ?? BREAKER_THRESHOLD;
    this.#stateFile = options?.stateFile ?? null;
    this.#watchEnabled = options?.watch ?? true;
    this.#watchFn = options?.watchFn ?? watch;
    if (this.#stateFile !== null) {
      this.#ensureWatcher();
      this.syncFromDisk();
      this.#maybeCompactOnStartup();
    }
  }
}

/// Fallback breaker used only when no per-station `ReaderConfig` breaker is supplied (e.g. standalone unit tests).
export const pionCircuitBreaker = new PionCircuitBreaker();
