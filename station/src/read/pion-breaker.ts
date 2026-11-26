// Process-attributed default-only crash circuit breaker for Pion reader/builder processes.
//
// Invariants:
// - Completely independent of `readerTelemetry`'s 600s window flush (`reader-telemetry.ts`).
// - Strictly scoped to `source === "default"`: explicit `"pion"` / `"shadow"` from config or env
//   never increments or trips default counters.
// - Per-station instance (no cross-station interference in dual-station tests; default fallback
//   instance exists only for callers without an explicit station `ReaderConfig`).
// - Lock-free CRDT segmented rotation + settled snapshot protocol in `dirname(stateFile)`:
//   1. Active append-only log (`<base>`, e.g. `pion-demoted.jsonl`): writers only ever `O_APPEND`
//      newline-isolated JSONL lines (`\n${JSON}\n`); compaction NEVER overwrites `<base>`.
//   2. Rotated read-only segments (`<base>.old.<rotatedAtMs>.<uuid>`): when a full read succeeds
//      and `<base>` exceeds `MAX_LOG_BYTES` (64 KiB) at startup or runtime, `<base>` is renamed to
//      a unique `.old.*` segment so in-flight writers finish on the old inode while new writers
//      append to a fresh `<base>` with zero lost writes.
//   3. Immutable compacted snapshots (`<base>.snap.<nowMs>.<uuid>`): once `.old.*` segments have
//      settled (`max(rotatedAtMs, mtimeMs) + compactSettleMs <= now`), a full byte-0 re-read of
//      all settled `.old.*` + existing `.snap.*` publishes a new `.snap.*` via atomic temp-rename
//      (aborted with zero deletions if any input read fails) and unlinks superseded inputs only
//      after verifying `(dev, ino, size, mtimeMs)` unchanged.
// - Per-file identity cursors (`(dev, ino, offset)`) detect inode replacement even when the new
//   file is larger than the old offset; `isDemoted(mode, currentStamp)` stays a pure in-memory O(1)
//   lookup, kept fresh by `fs.watch` + self-healing exponential-backoff retries on watch/read errors.
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
  readdirSync,
  readSync,
  renameSync,
  statSync,
  unlinkSync,
  watch,
  writeFileSync,
} from "node:fs";
import { open, readdir } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { type ReaderMode, type ReaderSelectSource, isReaderMode } from "./reader-select.ts";

export const BREAKER_WINDOW_MS = 5 * 60 * 1000;
export const BREAKER_THRESHOLD = 3;
export const MAX_LOG_BYTES = 64 * 1024;
export const DEFAULT_COMPACT_SETTLE_MS = 5_000;

const WATCH_RETRY_INITIAL_MS = 50;
const WATCH_RETRY_MAX_MS = 60_000;
const READ_RETRY_INITIAL_MS = 50;
const READ_RETRY_MAX_MS = 60_000;

const BOOT_ID = randomUUID();
let eventSeq = 0;

export type BreakerWatchFn = (
  dir: string,
  listener: (eventType: string, filename: string | Buffer | null) => void,
) => FSWatcher;

export type BreakerReadFs = {
  readonly openSync?: typeof openSync;
  readonly openAsync?: typeof open;
};

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

type FileCursor = {
  readonly dev: number;
  readonly ino: number;
  readonly offset: number;
};

type SyncDiskResult = {
  readonly activeReadOk: boolean;
  readonly activeSize: number;
  readonly hasOldSegments: boolean;
  readonly snapCount: number;
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

function classifyBreakerNames(names: readonly string[], base: string): { snaps: string[]; olds: string[]; active: string | null } {
  const snapPrefix = `${base}.snap.`;
  const oldPrefix = `${base}.old.`;
  const snaps: string[] = [];
  const olds: string[] = [];
  let active: string | null = null;
  for (const name of names) {
    if (name === base) active = name;
    else if (name.startsWith(snapPrefix)) snaps.push(name);
    else if (name.startsWith(oldPrefix)) olds.push(name);
  }
  snaps.sort();
  olds.sort();
  return { snaps, olds, active };
}

function isBreakerFilename(filename: string, base: string): boolean {
  return filename === base || filename.startsWith(`${base}.old.`) || filename.startsWith(`${base}.snap.`);
}

function parseOldRotatedAt(name: string, base: string): number {
  const rest = name.slice(`${base}.old.`.length);
  const dot = rest.indexOf(".");
  const raw = dot >= 0 ? rest.slice(0, dot) : rest;
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : 0;
}

type DiskEntries = Map<ReaderMode, Map<string, StampRecord>>;

export type PionCircuitBreakerOptions = {
  windowMs?: number;
  threshold?: number;
  stateFile?: string | null;
  watch?: boolean;
  watchFn?: BreakerWatchFn;
  compactSettleMs?: number;
  readFs?: BreakerReadFs;
};

export class PionCircuitBreaker {
  #windowMs: number;
  #threshold: number;
  #stateFile: string | null;
  #watchEnabled: boolean;
  #watchFn: BreakerWatchFn;
  #compactSettleMs: number;
  #openSyncFn: typeof openSync;
  #openAsyncFn: typeof open;
  readonly #entries: DiskEntries = new Map();
  readonly #pendingEvents: PendingAppend[] = [];
  readonly #fileCursors = new Map<string, FileCursor>();
  #watcher: FSWatcher | null = null;
  #cancelWatchRetry: (() => void) | null = null;
  #watchRetryDelayMs = WATCH_RETRY_INITIAL_MS;
  #watcherNeedsCatchup = false;
  #cancelReadRetry: (() => void) | null = null;
  #readRetryDelayMs = READ_RETRY_INITIAL_MS;
  #cancelReapTimer: (() => void) | null = null;
  #asyncReading = false;
  #asyncDirty = false;
  #closed = false;

  constructor(options: PionCircuitBreakerOptions = {}) {
    this.#windowMs = options.windowMs ?? BREAKER_WINDOW_MS;
    this.#threshold = options.threshold ?? BREAKER_THRESHOLD;
    this.#stateFile = options.stateFile ?? null;
    this.#watchEnabled = options.watch ?? true;
    this.#watchFn = options.watchFn ?? watch;
    this.#compactSettleMs = options.compactSettleMs ?? DEFAULT_COMPACT_SETTLE_MS;
    this.#openSyncFn = options.readFs?.openSync ?? openSync;
    this.#openAsyncFn = options.readFs?.openAsync ?? open;
    if (this.#stateFile !== null) {
      this.#ensureWatcher();
      const syncRes = this.#syncFromDiskDetailed();
      this.#maybeRotateAndScheduleReap(syncRes);
    }
  }

  /// Bind this breaker to `<data>/run/pion-demoted.jsonl`, attach watcher, load existing entries, and rotate/compact if needed.
  configure(
    stateFile: string | null,
    options?: { watch?: boolean; watchFn?: BreakerWatchFn; compactSettleMs?: number; readFs?: BreakerReadFs },
  ): void {
    this.#closeRuntimeHandles();
    this.#stateFile = stateFile;
    if (options?.watch !== undefined) this.#watchEnabled = options.watch;
    if (options?.watchFn !== undefined) this.#watchFn = options.watchFn;
    if (options?.compactSettleMs !== undefined) this.#compactSettleMs = options.compactSettleMs;
    if (options?.readFs !== undefined) {
      this.#openSyncFn = options.readFs.openSync ?? openSync;
      this.#openAsyncFn = options.readFs.openAsync ?? open;
    }
    this.#entries.clear();
    this.#pendingEvents.length = 0;
    this.#fileCursors.clear();
    this.#watchRetryDelayMs = WATCH_RETRY_INITIAL_MS;
    this.#readRetryDelayMs = READ_RETRY_INITIAL_MS;
    this.#watcherNeedsCatchup = false;
    this.#closed = false;
    if (stateFile !== null) {
      this.#ensureWatcher();
      const syncRes = this.#syncFromDiskDetailed();
      this.#maybeRotateAndScheduleReap(syncRes);
    }
  }

  /// Flush any pending in-memory crash events to disk and stop watching/timers (called on station shutdown / handover / test teardown).
  close(): void {
    this.flushPending();
    this.#closed = true;
    this.#closeRuntimeHandles();
  }

  #cancelRetryTimer(): void {
    if (this.#cancelWatchRetry !== null) {
      this.#cancelWatchRetry();
      this.#cancelWatchRetry = null;
    }
  }

  #cancelReadRetryTimer(): void {
    if (this.#cancelReadRetry !== null) {
      this.#cancelReadRetry();
      this.#cancelReadRetry = null;
    }
  }

  #cancelReap(): void {
    if (this.#cancelReapTimer !== null) {
      this.#cancelReapTimer();
      this.#cancelReapTimer = null;
    }
  }

  #closeRuntimeHandles(): void {
    this.#cancelRetryTimer();
    this.#cancelReadRetryTimer();
    this.#cancelReap();
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

  #scheduleAsyncReadRetry(): void {
    if (this.#closed || this.#stateFile === null) return;
    if (this.#cancelReadRetry !== null) return;
    const delay = this.#readRetryDelayMs;
    this.#readRetryDelayMs = Math.min(this.#readRetryDelayMs * 2, READ_RETRY_MAX_MS);
    // timer: failure retry with exponential backoff when async breaker read hits transient error
    this.#cancelReadRetry = wall.after(delay, () => {
      this.#cancelReadRetry = null;
      this.#scheduleAsyncRead();
    });
  }

  #scheduleReap(delayMs: number): void {
    if (this.#closed || this.#stateFile === null) return;
    this.#cancelReap();
    // timer: wait for rotated breaker segment writers to settle before snapshotting
    this.#cancelReapTimer = wall.after(Math.max(0, delayMs), () => {
      this.#cancelReapTimer = null;
      this.#reapSettledSegments();
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
        if (filename && !isBreakerFilename(filename.toString(), targetName)) return;
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
    const dir = dirname(file);
    const base = basename(file);
    let dirEntries: string[];
    try {
      dirEntries = await readdir(dir);
    } catch (err) {
      const code = (err as NodeJS.ErrnoException | null)?.code;
      if (code !== "ENOENT") this.#scheduleAsyncReadRetry();
      return;
    }
    if (this.#closed) return;

    const { snaps, olds, active } = classifyBreakerNames(dirEntries, base);
    const ordered = [...snaps, ...olds, ...(active !== null ? [active] : [])];
    const present = new Set(ordered);
    let hadRecoverableError = false;

    for (const name of ordered) {
      if (this.#closed) return;
      const fullPath = join(dir, name);
      let fh: Awaited<ReturnType<typeof open>> | null = null;
      try {
        fh = await this.#openAsyncFn(fullPath, "r");
        const st = await fh.stat();
        if (!st.isFile()) continue;
        // Snapshot identity and offset before awaiting fh.read so a synchronous syncFromDisk() during the await
        // cannot corrupt the cursor or advance past a newly replaced inode.
        const prev = this.#fileCursors.get(name);
        const identityChanged =
          prev === undefined || prev.dev !== st.dev || prev.ino !== st.ino || st.size < prev.offset;
        const startOffset = identityChanged ? 0 : prev.offset;
        const toRead = st.size - startOffset;
        if (toRead <= 0) {
          if (identityChanged) {
            const cur = this.#fileCursors.get(name);
            if (cur === prev) this.#fileCursors.set(name, { dev: st.dev, ino: st.ino, offset: 0 });
          }
          continue;
        }
        const buf = Buffer.allocUnsafe(toRead);
        let filled = 0;
        while (filled < toRead) {
          const { bytesRead } = await fh.read(buf, filled, toRead - filled, startOffset + filled);
          if (bytesRead <= 0) break;
          filled += bytesRead;
        }
        if (this.#closed) return;
        const cur = this.#fileCursors.get(name);
        if (cur !== prev && cur !== undefined && (cur.dev !== st.dev || cur.ino !== st.ino)) {
          // A synchronous read switched this filename to a newer inode while fh.read was suspended; discard stale async result and reschedule.
          this.#asyncDirty = true;
          continue;
        }
        if (filled <= 0) continue;
        const slice = buf.subarray(0, filled);
        const lastNewline = slice.lastIndexOf(0x0a);
        if (lastNewline < 0) {
          if (cur === undefined || cur.dev !== st.dev || cur.ino !== st.ino) {
            this.#fileCursors.set(name, { dev: st.dev, ino: st.ino, offset: 0 });
          }
          continue;
        }
        const complete = slice.subarray(0, lastNewline + 1).toString("utf8");
        const nextOffset = startOffset + lastNewline + 1;
        const mergedOffset =
          cur !== undefined && cur.dev === st.dev && cur.ino === st.ino ? Math.max(cur.offset, nextOffset) : nextOffset;
        this.#fileCursors.set(name, { dev: st.dev, ino: st.ino, offset: mergedOffset });
        this.#applyParsed(parseJsonlChunk(complete));
      } catch (err) {
        const code = (err as NodeJS.ErrnoException | null)?.code;
        if (code !== "ENOENT") hadRecoverableError = true;
      } finally {
        await fh?.close().catch(() => {});
      }
    }

    if (hadRecoverableError) {
      this.#scheduleAsyncReadRetry();
    } else {
      this.#readRetryDelayMs = READ_RETRY_INITIAL_MS;
      this.#cancelReadRetryTimer();
      for (const k of this.#fileCursors.keys()) {
        if (!present.has(k)) this.#fileCursors.delete(k);
      }
    }
  }

  #syncFile(dir: string, name: string): { size: number } | null {
    const fullPath = join(dir, name);
    let fd: number | null = null;
    try {
      fd = this.#openSyncFn(fullPath, "r"); // sync: incremental JSONL breaker segment read at startup or crash boundary
      const st = fstatSync(fd); // sync: stat open breaker segment fd to check identity and appended bytes
      if (!st.isFile()) return null;
      const prev = this.#fileCursors.get(name);
      const identityChanged =
        prev === undefined || prev.dev !== st.dev || prev.ino !== st.ino || st.size < prev.offset;
      const startOffset = identityChanged ? 0 : prev.offset;
      const toRead = st.size - startOffset;
      if (toRead <= 0) {
        if (identityChanged) this.#fileCursors.set(name, { dev: st.dev, ino: st.ino, offset: 0 });
        return { size: st.size };
      }
      const buf = Buffer.allocUnsafe(toRead);
      let filled = 0;
      while (filled < toRead) {
        const bytesRead = readSync(fd, buf, filled, toRead - filled, startOffset + filled); // sync: read newly appended JSONL bytes
        if (bytesRead <= 0) break;
        filled += bytesRead;
      }
      if (filled <= 0) return { size: st.size };
      const slice = buf.subarray(0, filled);
      const lastNewline = slice.lastIndexOf(0x0a);
      if (lastNewline < 0) {
        if (identityChanged) this.#fileCursors.set(name, { dev: st.dev, ino: st.ino, offset: 0 });
        return { size: st.size };
      }
      const complete = slice.subarray(0, lastNewline + 1).toString("utf8");
      this.#fileCursors.set(name, { dev: st.dev, ino: st.ino, offset: startOffset + lastNewline + 1 });
      this.#applyParsed(parseJsonlChunk(complete));
      return { size: st.size };
    } catch {
      return null;
    } finally {
      if (fd !== null) {
        try {
          closeSync(fd); // sync: close incremental breaker segment fd
        } catch {}
      }
    }
  }

  #syncFromDiskDetailed(): SyncDiskResult {
    const empty: SyncDiskResult = { activeReadOk: false, activeSize: 0, hasOldSegments: false, snapCount: 0 };
    const file = this.#stateFile;
    if (file === null) return empty;
    const dir = dirname(file);
    const base = basename(file);
    let dirEntries: string[];
    try {
      dirEntries = readdirSync(dir); // sync: enumerate breaker snapshots, rotated segments, and active log
    } catch {
      return empty;
    }
    const { snaps, olds, active } = classifyBreakerNames(dirEntries, base);
    const ordered = [...snaps, ...olds, ...(active !== null ? [active] : [])];
    const present = new Set(ordered);
    for (const k of this.#fileCursors.keys()) {
      if (!present.has(k)) this.#fileCursors.delete(k);
    }

    for (const name of snaps) this.#syncFile(dir, name);
    for (const name of olds) this.#syncFile(dir, name);
    let activeReadOk = false;
    let activeSize = 0;
    if (active !== null) {
      const res = this.#syncFile(dir, active);
      if (res !== null) {
        activeReadOk = true;
        activeSize = res.size;
      }
    }
    return {
      activeReadOk,
      activeSize,
      hasOldSegments: olds.length > 0,
      snapCount: snaps.length,
    };
  }

  /// Synchronously and incrementally absorb newly appended bytes from all breaker files (used at startup and on crash writes, never on `isDemoted`).
  syncFromDisk(): void {
    this.#syncFromDiskDetailed();
  }

  #maybeRotateAndScheduleReap(syncRes: SyncDiskResult): void {
    const file = this.#stateFile;
    if (file === null || this.#closed) return;
    let rotated = false;
    if (syncRes.activeReadOk && syncRes.activeSize > MAX_LOG_BYTES) {
      const rotatedPath = `${file}.old.${wall.now()}.${randomUUID()}`;
      try {
        renameSync(file, rotatedPath); // sync: lock-free rotation of oversized active breaker log to read-only segment
        this.#fileCursors.delete(basename(file));
        rotated = true;
      } catch (err) {
        const code = (err as NodeJS.ErrnoException | null)?.code;
        if (code !== "ENOENT") {
          log.warn("readers", "failed to rotate oversized pion circuit breaker log", {
            file,
            error: err instanceof Error ? err.message : String(err),
          });
        }
      }
    }
    if (rotated || syncRes.hasOldSegments || syncRes.snapCount > 1) {
      this.#reapSettledSegments();
    }
  }

  #reapSettledSegments(): void {
    const file = this.#stateFile;
    if (file === null || this.#closed) return;
    const dir = dirname(file);
    const base = basename(file);
    let dirEntries: string[];
    try {
      dirEntries = readdirSync(dir); // sync: scan breaker dir for settled segments and snapshots
    } catch {
      return;
    }
    const { snaps, olds } = classifyBreakerNames(dirEntries, base);
    const now = wall.now();
    const settledOlds: string[] = [];
    let unsettledMinWaitMs = Infinity;

    for (const oldName of olds) {
      const rotatedAtMs = parseOldRotatedAt(oldName, base);
      let st;
      try {
        st = statSync(join(dir, oldName)); // sync: check mtime of rotated breaker segment for settle window
      } catch (err) {
        const code = (err as NodeJS.ErrnoException | null)?.code;
        if (code === "ENOENT") continue;
        return;
      }
      if (!st.isFile()) continue;
      const settleAt = Math.max(rotatedAtMs, st.mtimeMs) + this.#compactSettleMs;
      if (settleAt <= now) {
        settledOlds.push(oldName);
      } else {
        unsettledMinWaitMs = Math.min(unsettledMinWaitMs, Math.max(1, Math.ceil(settleAt - now)));
      }
    }

    if (unsettledMinWaitMs < Infinity) {
      this.#scheduleReap(unsettledMinWaitMs);
    }

    if (settledOlds.length === 0 && snaps.length <= 1) return;

    type InputMeta = {
      readonly name: string;
      readonly fullPath: string;
      readonly isOld: boolean;
      readonly dev: number;
      readonly ino: number;
      readonly size: number;
      readonly mtimeMs: number;
    };
    const inputList = [
      ...snaps.map((name) => ({ name, isOld: false })),
      ...settledOlds.map((name) => ({ name, isOld: true })),
    ];
    const readMetas: InputMeta[] = [];
    const allParsed: ParsedLine[] = [];

    // Full byte-0 re-read of every input segment/snapshot. Any non-ENOENT error aborts compaction with zero deletions.
    for (const { name, isOld } of inputList) {
      const fullPath = join(dir, name);
      let fd: number | null = null;
      try {
        fd = this.#openSyncFn(fullPath, "r"); // sync: full byte-0 read of settled breaker segment for compaction
        const st = fstatSync(fd); // sync: record segment identity and metadata before compaction read
        if (!st.isFile()) continue;
        const buf = Buffer.allocUnsafe(st.size);
        let filled = 0;
        while (filled < st.size) {
          const bytesRead = readSync(fd, buf, filled, st.size - filled, filled); // sync: read full settled breaker segment
          if (bytesRead <= 0) break;
          filled += bytesRead;
        }
        const text = buf.subarray(0, filled).toString("utf8");
        for (const item of parseJsonlChunk(text)) allParsed.push(item);
        readMetas.push({ name, fullPath, isOld, dev: st.dev, ino: st.ino, size: st.size, mtimeMs: st.mtimeMs });
      } catch (err) {
        const code = (err as NodeJS.ErrnoException | null)?.code;
        if (code === "ENOENT") continue;
        log.warn("readers", "aborting pion circuit breaker compaction due to read failure", {
          file: fullPath,
          error: err instanceof Error ? err.message : String(err),
        });
        return;
      } finally {
        if (fd !== null) {
          try {
            closeSync(fd); // sync: close compacted breaker segment fd
          } catch {}
        }
      }
    }

    if (readMetas.length === 0) return;

    // Ensure in-memory state absorbs everything we just read from settled segments.
    this.#applyParsed(allParsed);

    // Aggregate purely from `allParsed` in a local temporary map so snapshot content is self-contained.
    const agg: DiskEntries = new Map();
    const touched = new Map<string, { mode: ReaderMode; rec: StampRecord }>();
    let maxEventAt = 0;
    for (const item of allParsed) {
      const sKey = pionStampKey(item.stamp);
      let modeMap = agg.get(item.mode);
      if (modeMap === undefined) {
        modeMap = new Map();
        agg.set(item.mode, modeMap);
      }
      let rec = modeMap.get(sKey);
      if (rec === undefined) {
        rec = { stamp: item.stamp, events: [], seenIds: new Set(), demotedPersisted: false };
        modeMap.set(sKey, rec);
      }
      if (item.demotedAt !== undefined) {
        rec.demotedAt = rec.demotedAt !== undefined ? Math.min(rec.demotedAt, item.demotedAt) : item.demotedAt;
        rec.events.length = 0;
        rec.seenIds.clear();
        continue;
      }
      if (rec.demotedAt === undefined && item.ev !== undefined && !rec.seenIds.has(item.ev.id)) {
        rec.seenIds.add(item.ev.id);
        rec.events.push(item.ev);
        if (item.ev.at > maxEventAt) maxEventAt = item.ev.at;
        touched.set(`${item.mode}\0${sKey}`, { mode: item.mode, rec });
      }
    }
    for (const { mode, rec } of touched.values()) {
      this.#recomputeDemotion(mode, rec, false);
    }

    const cutoff = Math.max(wall.now(), maxEventAt) - this.#windowMs;
    const outLines: string[] = [];
    for (const [mode, byStamp] of agg) {
      for (const rec of byStamp.values()) {
        if (rec.demotedAt !== undefined) {
          outLines.push(JSON.stringify({ v: 2, mode, stamp: rec.stamp, demotedAt: rec.demotedAt }));
        } else {
          for (const ev of rec.events) {
            if (ev.at > cutoff) {
              outLines.push(JSON.stringify({ v: 2, mode, stamp: rec.stamp, at: ev.at, id: ev.id }));
            }
          }
        }
      }
    }

    if (outLines.length > 0) {
      const snapContent = `${outLines.join("\n")}\n`;
      const tmpPath = `${file}.tmp.${process.pid}.${randomUUID()}`;
      const snapName = `${base}.snap.${wall.now()}.${randomUUID()}`;
      const snapPath = join(dir, snapName);
      try {
        writeFileSync(tmpPath, snapContent, "utf8"); // sync: write compacted breaker snapshot temp file
        renameSync(tmpPath, snapPath); // sync: publish immutable lock-free breaker snapshot
      } catch (err) {
        try {
          unlinkSync(tmpPath); // sync: clean up failed breaker snapshot temp file
        } catch {}
        log.warn("readers", "failed to publish pion circuit breaker snapshot", {
          file: snapPath,
          error: err instanceof Error ? err.message : String(err),
        });
        return;
      }
    }

    for (const meta of readMetas) {
      try {
        if (meta.isOld) {
          const curSt = statSync(meta.fullPath); // sync: verify rotated breaker segment unchanged before unlink
          if (
            curSt.dev !== meta.dev ||
            curSt.ino !== meta.ino ||
            curSt.size !== meta.size ||
            curSt.mtimeMs !== meta.mtimeMs
          ) {
            continue;
          }
        }
        unlinkSync(meta.fullPath); // sync: remove superseded breaker segment/snapshot after snapshot published
        this.#fileCursors.delete(meta.name);
      } catch (err) {
        const code = (err as NodeJS.ErrnoException | null)?.code;
        if (code === "ENOENT") this.#fileCursors.delete(meta.name);
      }
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
        const syncRes = this.#syncFromDiskDetailed();
        this.#maybeRotateAndScheduleReap(syncRes);
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
        // Absorb our own lines and any concurrent peer appends, then rotate if active log exceeded MAX_LOG_BYTES.
        const syncRes = this.#syncFromDiskDetailed();
        this.#maybeRotateAndScheduleReap(syncRes);
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
    this.#closeRuntimeHandles();
    this.#entries.clear();
    this.#pendingEvents.length = 0;
    this.#fileCursors.clear();
    this.#watchRetryDelayMs = WATCH_RETRY_INITIAL_MS;
    this.#readRetryDelayMs = READ_RETRY_INITIAL_MS;
    this.#watcherNeedsCatchup = false;
    this.#closed = false;
    this.#windowMs = options?.windowMs ?? BREAKER_WINDOW_MS;
    this.#threshold = options?.threshold ?? BREAKER_THRESHOLD;
    this.#stateFile = options?.stateFile ?? null;
    this.#watchEnabled = options?.watch ?? true;
    this.#watchFn = options?.watchFn ?? watch;
    this.#compactSettleMs = options?.compactSettleMs ?? DEFAULT_COMPACT_SETTLE_MS;
    this.#openSyncFn = options?.readFs?.openSync ?? openSync;
    this.#openAsyncFn = options?.readFs?.openAsync ?? open;
    if (this.#stateFile !== null) {
      this.#ensureWatcher();
      const syncRes = this.#syncFromDiskDetailed();
      this.#maybeRotateAndScheduleReap(syncRes);
    }
  }
}

/// Fallback breaker used only when no per-station `ReaderConfig` breaker is supplied (e.g. standalone unit tests).
export const pionCircuitBreaker = new PionCircuitBreaker();
