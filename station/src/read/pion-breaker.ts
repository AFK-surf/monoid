// Process-attributed default-only crash circuit breaker for Pion reader/builder processes.
//
// Invariants:
// - Completely independent of `readerTelemetry`'s 600s window flush (`reader-telemetry.ts`).
// - Strictly scoped to `source === "default"`: explicit `"pion"` / `"shadow"` from config or env
//   never increments or trips default counters.
// - Per-station instance (no cross-station interference in dual-station tests; default fallback
//   instance exists only for callers without an explicit station `ReaderConfig`).
// - Lock-free single-owner log + immutable demotion marker protocol in `dirname(stateFile)`:
//   1. Single-writer per-instance log (`<base>.p.<pid>.<instanceId>.jsonl`): ONLY the owning
//      instance ever appends to or compacts its own log (zero multi-writer contention, zero
//      cross-process unlink TOCTOU). Appends loop `writeSync` until all bytes are written and
//      prefix every record with `\n` (immune to torn trailing partial lines). When `ownLog`
//      exceeds `MAX_LOG_BYTES` (64 KiB), the owning instance atomically self-compacts it.
//   2. Immutable permanent demotion markers (`<base>.demoted.<hash16>.json`): as soon as any
//      `(mode, stampKey)` reaches `K = 3` exits within `N = 5 min` (locally or merged across peer
//      logs), an atomic temp-rename publishes its permanent marker (never deleted or rotated).
//      Once persisted, further crashes for that `(mode, stampKey)` append zero bytes.
//   3. Dead-peer expired log reaping: only peer logs whose owning PID is dead (`ESRCH`) AND whose
//      `mtimeMs + windowMs < now` are unlinked (after all demotion markers are persisted), plus
//      stale orphan `.tmp.*` files older than 60s.
//   4. Snapshot-consistent directory scans: sync and async reads re-scan up to 4 rounds whenever
//      any file hits `ENOENT` or the sorted breaker filename set changes during the pass, with
//      per-file `(dev, ino, offset)` identity cursors and exponential-backoff self-healing on
//      watch/read errors (up to 60s).
// - Trips after `K = 3` unexpected exits within a `N = 5 min` sliding window for the same
//   `(mode, stampKey)`.
import { createHash, randomUUID } from "node:crypto";
import {
  type FSWatcher,
  closeSync,
  constants as fsConstants,
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
  writeSync,
} from "node:fs";
import { open, readdir, stat } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { type ReaderMode, type ReaderSelectSource, isReaderMode } from "./reader-select.ts";

export const BREAKER_WINDOW_MS = 5 * 60 * 1000;
export const BREAKER_THRESHOLD = 3;
export const MAX_LOG_BYTES = 64 * 1024;

const WATCH_RETRY_INITIAL_MS = 50;
const WATCH_RETRY_MAX_MS = 60_000;
const READ_RETRY_INITIAL_MS = 50;
const READ_RETRY_MAX_MS = 60_000;
const ORPHAN_TMP_AGE_MS = 60_000;

let eventSeq = 0;

export type BreakerWatchFn = (
  dir: string,
  listener: (eventType: string, filename: string | Buffer | null) => void,
) => FSWatcher;

export type BreakerReadFs = {
  readonly openSync?: typeof openSync;
  readonly openAsync?: typeof open;
};

export type BreakerWriteFs = {
  readonly openSync?: typeof openSync;
  readonly writeSync?: typeof writeSync;
  readonly closeSync?: typeof closeSync;
};

export type BreakerPublishFs = {
  readonly renameSync?: typeof renameSync;
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
  readonly demotedAt?: number;
};

type FileCursor = {
  readonly dev: number;
  readonly ino: number;
  readonly offset: number;
};

type ScannedPeerMeta = {
  readonly name: string;
  readonly dev: number;
  readonly ino: number;
  readonly size: number;
  readonly mtimeMs: number;
};

type SyncDiskResult = {
  readonly ownLogReadOk: boolean;
  readonly ownLogSize: number;
  readonly fullScanClean: boolean;
  readonly scannedPeers: readonly ScannedPeerMeta[];
  readonly scannedNowMs: number;
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

export async function pionBinaryStampAsync(binaryPath: string): Promise<PionBinaryStamp | null> {
  try {
    const resolved = resolve(binaryPath);
    const st = await stat(resolved);
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

function demotionHash16(mode: ReaderMode, stamp: PionBinaryStamp): string {
  return createHash("sha256").update(`${mode}\0${pionStampKey(stamp)}`).digest("hex").slice(0, 16);
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

function isDemotedMarkerName(name: string, base: string): boolean {
  return name.startsWith(`${base}.demoted.`) && name.endsWith(".json") && !name.includes(".tmp.");
}

function isPeerLogName(name: string, base: string): boolean {
  return name.startsWith(`${base}.p.`) && name.endsWith(".jsonl") && !name.includes(".tmp.");
}

function isOrphanTmpName(name: string, base: string): boolean {
  return name.startsWith(`${base}.`) && name.includes(".tmp.");
}

function isBreakerFilename(name: string, base: string): boolean {
  return name === base || isDemotedMarkerName(name, base) || isPeerLogName(name, base);
}

function sortedBreakerNames(names: readonly string[], base: string): string[] {
  const markers: string[] = [];
  const peers: string[] = [];
  let hasBase = false;
  for (const name of names) {
    if (name === base) hasBase = true;
    else if (isDemotedMarkerName(name, base)) markers.push(name);
    else if (isPeerLogName(name, base)) peers.push(name);
  }
  markers.sort();
  peers.sort();
  return hasBase ? [...markers, ...peers, base] : [...markers, ...peers];
}

function sameStringArray(a: readonly string[], b: readonly string[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

function parsePeerLogName(name: string, base: string): { pid: number; instId: string } | null {
  if (!isPeerLogName(name, base)) return null;
  const inner = name.slice(`${base}.p.`.length, -".jsonl".length);
  const dot = inner.indexOf(".");
  if (dot <= 0) return null;
  const pid = Number(inner.slice(0, dot));
  const instId = inner.slice(dot + 1);
  if (!Number.isInteger(pid) || pid <= 0 || instId === "") return null;
  return { pid, instId };
}

function pidAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    const code = (err as NodeJS.ErrnoException | null)?.code;
    return code !== "ESRCH";
  }
}

type DiskEntries = Map<ReaderMode, Map<string, StampRecord>>;

export type PionCircuitBreakerOptions = {
  windowMs?: number;
  threshold?: number;
  stateFile?: string | null;
  watch?: boolean;
  watchFn?: BreakerWatchFn;
  readFs?: BreakerReadFs;
  writeFs?: BreakerWriteFs;
  publishFs?: BreakerPublishFs;
  nowFn?: () => number;
};

export class PionCircuitBreaker {
  #windowMs: number;
  #threshold: number;
  #stateFile: string | null;
  #watchEnabled: boolean;
  #watchFn: BreakerWatchFn;
  #openSyncFn: typeof openSync;
  #openAsyncFn: typeof open;
  #writeOpenSyncFn: typeof openSync;
  #writeSyncFn: typeof writeSync;
  #writeCloseSyncFn: typeof closeSync;
  #publishRenameSyncFn: typeof renameSync;
  #nowFn: () => number;
  #instanceId = randomUUID();
  readonly #entries: DiskEntries = new Map();
  readonly #pendingEvents: PendingAppend[] = [];
  readonly #fileCursors = new Map<string, FileCursor>();
  #watcher: FSWatcher | null = null;
  #cancelWatchRetry: (() => void) | null = null;
  #watchRetryDelayMs = WATCH_RETRY_INITIAL_MS;
  #watcherNeedsCatchup = false;
  #cancelReadRetry: (() => void) | null = null;
  #readRetryDelayMs = READ_RETRY_INITIAL_MS;
  #asyncReading = false;
  #asyncDirty = false;
  #bindEpoch = 0;
  #closed = false;
  #closeSynced = false;

  constructor(options: PionCircuitBreakerOptions = {}) {
    this.#windowMs = options.windowMs ?? BREAKER_WINDOW_MS;
    this.#threshold = options.threshold ?? BREAKER_THRESHOLD;
    this.#stateFile = options.stateFile ?? null;
    this.#watchEnabled = options.watch ?? true;
    this.#watchFn = options.watchFn ?? watch;
    this.#openSyncFn = options.readFs?.openSync ?? openSync;
    this.#openAsyncFn = options.readFs?.openAsync ?? open;
    this.#writeOpenSyncFn = options.writeFs?.openSync ?? openSync;
    this.#writeSyncFn = options.writeFs?.writeSync ?? writeSync;
    this.#writeCloseSyncFn = options.writeFs?.closeSync ?? closeSync;
    this.#publishRenameSyncFn = options.publishFs?.renameSync ?? renameSync;
    this.#nowFn = options.nowFn ?? (() => wall.now());
    if (this.#stateFile !== null) {
      this.#ensureWatcher();
      const syncRes = this.#syncFromDiskDetailed();
      this.#reapDeadPeerLogs(syncRes);
    }
  }

  /// Absolute path of this instance's exclusive append-only log file (null if memory-only).
  ownLogPath(): string | null {
    if (this.#stateFile === null) return null;
    return `${this.#stateFile}.p.${process.pid}.${this.#instanceId}.jsonl`;
  }

  /// Bind this breaker to `<data>/run/pion-demoted.jsonl`, attach watcher, load existing entries, and reap dead peers.
  configure(
    stateFile: string | null,
    options?: {
      watch?: boolean;
      watchFn?: BreakerWatchFn;
      readFs?: BreakerReadFs;
      writeFs?: BreakerWriteFs;
      publishFs?: BreakerPublishFs;
      nowFn?: () => number;
    },
  ): void {
    this.#bindEpoch++;
    this.#closeRuntimeHandles();
    this.#stateFile = stateFile;
    this.#instanceId = randomUUID();
    if (options?.watch !== undefined) this.#watchEnabled = options.watch;
    if (options?.watchFn !== undefined) this.#watchFn = options.watchFn;
    if (options?.readFs !== undefined) {
      this.#openSyncFn = options.readFs.openSync ?? openSync;
      this.#openAsyncFn = options.readFs.openAsync ?? open;
    }
    if (options?.writeFs !== undefined) {
      this.#writeOpenSyncFn = options.writeFs.openSync ?? openSync;
      this.#writeSyncFn = options.writeFs.writeSync ?? writeSync;
      this.#writeCloseSyncFn = options.writeFs.closeSync ?? closeSync;
    }
    if (options?.publishFs !== undefined) {
      this.#publishRenameSyncFn = options.publishFs.renameSync ?? renameSync;
    }
    if (options?.nowFn !== undefined) {
      this.#nowFn = options.nowFn;
    }
    this.#entries.clear();
    this.#pendingEvents.length = 0;
    this.#fileCursors.clear();
    this.#watchRetryDelayMs = WATCH_RETRY_INITIAL_MS;
    this.#readRetryDelayMs = READ_RETRY_INITIAL_MS;
    this.#watcherNeedsCatchup = false;
    this.#asyncDirty = false;
    this.#closed = false;
    this.#closeSynced = false;
    if (stateFile !== null) {
      this.#ensureWatcher();
      const syncRes = this.#syncFromDiskDetailed();
      this.#reapDeadPeerLogs(syncRes);
    }
  }

  /// Stop runtime handles immediately, then flush pending events, merge peer logs, and publish demotion markers.
  /// Returns `true` once final flush + clean sync + marker publish all succeed (idempotent thereafter);
  /// returns `false` on transient error so a subsequent `close()` call can retry cleanly.
  close(): boolean {
    this.#bindEpoch++;
    this.#closed = true;
    this.#closeRuntimeHandles();
    if (this.#stateFile === null || this.#closeSynced) return true;
    const flushed = this.flushPending() && this.#pendingEvents.length === 0;
    const syncRes = this.#syncFromDiskDetailed();
    const markersOk = this.#persistDemotionMarkers();
    if (flushed && syncRes.fullScanClean && markersOk) {
      this.#closeSynced = true;
      return true;
    }
    return false;
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

  #closeRuntimeHandles(): void {
    this.#cancelRetryTimer();
    this.#cancelReadRetryTimer();
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
    const epoch = this.#bindEpoch;
    const file = this.#stateFile;
    if (file === null || this.#closed) return;
    const dir = dirname(file);
    const base = basename(file);
    let hadRecoverableError = false;
    let lastNames: string[] = [];

    for (let round = 0; round < 4; round++) {
      if (this.#closed || this.#bindEpoch !== epoch) return;
      let beforeEntries: string[];
      try {
        beforeEntries = await readdir(dir);
      } catch (err) {
        if (this.#closed || this.#bindEpoch !== epoch) return;
        const code = (err as NodeJS.ErrnoException | null)?.code;
        if (code !== "ENOENT") this.#scheduleAsyncReadRetry();
        return;
      }
      if (this.#closed || this.#bindEpoch !== epoch) return;

      const beforeNames = sortedBreakerNames(beforeEntries, base);
      lastNames = beforeNames;
      let sawEnoent = false;

      for (const name of beforeNames) {
        if (this.#closed || this.#bindEpoch !== epoch) return;
        const fullPath = join(dir, name);
        let fh: Awaited<ReturnType<typeof open>> | null = null;
        try {
          fh = await this.#openAsyncFn(fullPath, "r");
          if (this.#closed || this.#bindEpoch !== epoch) return;
          const st = await fh.stat();
          if (this.#closed || this.#bindEpoch !== epoch) return;
          if (!st.isFile()) continue;
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
            if (this.#closed || this.#bindEpoch !== epoch) return;
            if (bytesRead <= 0) break;
            filled += bytesRead;
          }
          if (this.#closed || this.#bindEpoch !== epoch) return;
          const cur = this.#fileCursors.get(name);
          if (cur !== prev && cur !== undefined && (cur.dev !== st.dev || cur.ino !== st.ino)) {
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
          this.#applyParsed(parseJsonlChunk(complete), isDemotedMarkerName(name, base));
        } catch (err) {
          if (this.#closed || this.#bindEpoch !== epoch) return;
          const code = (err as NodeJS.ErrnoException | null)?.code;
          if (code === "ENOENT") sawEnoent = true;
          else hadRecoverableError = true;
        } finally {
          await fh?.close().catch(() => {});
        }
      }

      if (this.#closed || this.#bindEpoch !== epoch) return;
      let afterNames = beforeNames;
      try {
        afterNames = sortedBreakerNames(await readdir(dir), base);
        if (this.#closed || this.#bindEpoch !== epoch) return;
        lastNames = afterNames;
      } catch {}

      if (!sawEnoent && sameStringArray(beforeNames, afterNames)) break;
    }

    if (this.#closed || this.#bindEpoch !== epoch) return;
    if (this.#pendingEvents.length === 0) {
      this.#persistDemotionMarkers();
    }

    if (hadRecoverableError) {
      this.#scheduleAsyncReadRetry();
    } else {
      this.#readRetryDelayMs = READ_RETRY_INITIAL_MS;
      this.#cancelReadRetryTimer();
      const present = new Set(lastNames);
      for (const k of this.#fileCursors.keys()) {
        if (!present.has(k)) this.#fileCursors.delete(k);
      }
    }
  }

  #syncFile(
    dir: string,
    name: string,
    isMarker: boolean,
  ):
    | { kind: "ok"; size: number; dev: number; ino: number; mtimeMs: number }
    | { kind: "enoent" }
    | { kind: "error" } {
    const fullPath = join(dir, name);
    let fd: number | null = null;
    try {
      fd = this.#openSyncFn(fullPath, "r"); // sync: incremental JSONL breaker read at startup or crash boundary
      const st = fstatSync(fd); // sync: stat open breaker fd to check identity and appended bytes
      if (!st.isFile()) return { kind: "error" };
      const meta = { kind: "ok" as const, size: st.size, dev: st.dev, ino: st.ino, mtimeMs: st.mtimeMs };
      const prev = this.#fileCursors.get(name);
      const identityChanged =
        prev === undefined || prev.dev !== st.dev || prev.ino !== st.ino || st.size < prev.offset;
      const startOffset = identityChanged ? 0 : prev.offset;
      const toRead = st.size - startOffset;
      if (toRead <= 0) {
        if (identityChanged) this.#fileCursors.set(name, { dev: st.dev, ino: st.ino, offset: 0 });
        return meta;
      }
      const buf = Buffer.allocUnsafe(toRead);
      let filled = 0;
      while (filled < toRead) {
        const bytesRead = readSync(fd, buf, filled, toRead - filled, startOffset + filled); // sync: read newly appended JSONL bytes
        if (bytesRead <= 0) break;
        filled += bytesRead;
      }
      if (filled <= 0) return meta;
      const slice = buf.subarray(0, filled);
      const lastNewline = slice.lastIndexOf(0x0a);
      if (lastNewline < 0) {
        if (identityChanged) this.#fileCursors.set(name, { dev: st.dev, ino: st.ino, offset: 0 });
        return meta;
      }
      const complete = slice.subarray(0, lastNewline + 1).toString("utf8");
      this.#fileCursors.set(name, { dev: st.dev, ino: st.ino, offset: startOffset + lastNewline + 1 });
      this.#applyParsed(parseJsonlChunk(complete), isMarker);
      return meta;
    } catch (err) {
      const code = (err as NodeJS.ErrnoException | null)?.code;
      return code === "ENOENT" ? { kind: "enoent" } : { kind: "error" };
    } finally {
      if (fd !== null) {
        try {
          closeSync(fd); // sync: close incremental breaker fd
        } catch {}
      }
    }
  }

  #syncFromDiskDetailed(): SyncDiskResult {
    const empty: SyncDiskResult = {
      ownLogReadOk: false,
      ownLogSize: 0,
      fullScanClean: false,
      scannedPeers: [],
      scannedNowMs: this.#nowFn(),
    };
    const file = this.#stateFile;
    if (file === null) return empty;
    const dir = dirname(file);
    const base = basename(file);
    const ownName = `${base}.p.${process.pid}.${this.#instanceId}.jsonl`;
    let lastResult = empty;

    // Re-enumerate up to 4 rounds if any file vanishes (ENOENT), the breaker filename set changes, or any
    // scanned file's (dev, ino, size, mtimeMs) changes during the pass (concurrent peer append).
    for (let round = 0; round < 4; round++) {
      const scanStartMs = this.#nowFn();
      let beforeEntries: string[];
      try {
        beforeEntries = readdirSync(dir); // sync: enumerate breaker markers and peer logs before pass
      } catch {
        return empty;
      }
      const beforeNames = sortedBreakerNames(beforeEntries, base);
      let sawEnoent = false;
      let sawError = false;
      let ownLogReadOk = false;
      let ownLogSize = 0;
      const scannedAll: ScannedPeerMeta[] = [];
      const scannedPeers: ScannedPeerMeta[] = [];

      for (const name of beforeNames) {
        const res = this.#syncFile(dir, name, isDemotedMarkerName(name, base));
        if (res.kind === "enoent") {
          sawEnoent = true;
        } else if (res.kind === "error") {
          sawError = true;
        } else {
          const meta: ScannedPeerMeta = { name, dev: res.dev, ino: res.ino, size: res.size, mtimeMs: res.mtimeMs };
          scannedAll.push(meta);
          if (name === ownName) {
            ownLogReadOk = true;
            ownLogSize = res.size;
          } else if (isPeerLogName(name, base)) {
            scannedPeers.push(meta);
          }
        }
      }

      let afterNames = beforeNames;
      let afterReadOk = true;
      try {
        afterNames = sortedBreakerNames(readdirSync(dir), base); // sync: verify breaker dir set unchanged after pass
      } catch {
        afterReadOk = false;
      }

      const namesStable = !sawEnoent && afterReadOk && sameStringArray(beforeNames, afterNames);
      let filesUnchanged = namesStable && !sawError;
      if (filesUnchanged) {
        for (const m of scannedAll) {
          try {
            const st = statSync(join(dir, m.name)); // sync: verify scanned breaker file unchanged during scan
            if (
              !st.isFile() ||
              st.dev !== m.dev ||
              st.ino !== m.ino ||
              st.size !== m.size ||
              st.mtimeMs !== m.mtimeMs
            ) {
              filesUnchanged = false;
              break;
            }
          } catch {
            filesUnchanged = false;
            break;
          }
        }
      }

      const fullScanClean = filesUnchanged;
      lastResult = {
        ownLogReadOk,
        ownLogSize,
        fullScanClean,
        scannedPeers: fullScanClean ? scannedPeers : [],
        scannedNowMs: scanStartMs,
      };
      if (fullScanClean || (sawError && namesStable)) {
        const present = new Set(afterNames);
        for (const k of this.#fileCursors.keys()) {
          if (!present.has(k)) this.#fileCursors.delete(k);
        }
        break;
      }
    }

    if (this.#pendingEvents.length === 0) {
      this.#persistDemotionMarkers();
    }
    return lastResult;
  }

  /// Synchronously and incrementally absorb newly appended bytes from all breaker files (used at startup and on crash writes, never on `isDemoted`).
  syncFromDisk(): void {
    this.#syncFromDiskDetailed();
  }

  /// Publish permanent, immutable `<base>.demoted.<hash16>.json` markers for every demoted `(mode, stamp)`.
  /// Returns `true` iff every demoted marker is persisted on disk.
  #persistDemotionMarkers(): boolean {
    const file = this.#stateFile;
    if (file === null) return true;
    const dir = dirname(file);
    const base = basename(file);
    let ensuredDir = false;
    let allOk = true;

    for (const [mode, byStamp] of this.#entries) {
      for (const rec of byStamp.values()) {
        if (rec.demotedAt === undefined || rec.demotedPersisted) continue;
        const markerPath = join(dir, `${base}.demoted.${demotionHash16(mode, rec.stamp)}.json`);
        const tmpPath = `${file}.tmp.${process.pid}.${randomUUID()}`;
        const content = `${JSON.stringify({ v: 2, mode, stamp: rec.stamp, demotedAt: rec.demotedAt })}\n`;
        try {
          if (!ensuredDir) {
            mkdirSync(dir, { recursive: true }); // sync: ensure breaker dir exists before publishing demotion marker
            ensuredDir = true;
          }
          writeFileSync(tmpPath, content, "utf8"); // sync: write immutable demotion marker temp file
          this.#publishRenameSyncFn(tmpPath, markerPath); // sync: atomically publish immutable demotion marker
          rec.demotedPersisted = true;
          rec.events.length = 0;
          rec.seenIds.clear();
        } catch (err) {
          allOk = false;
          try {
            unlinkSync(tmpPath); // sync: clean up failed demotion marker temp file
          } catch {}
          log.warn("readers", "failed to publish pion circuit breaker demotion marker", {
            file: markerPath,
            error: err instanceof Error ? err.message : String(err),
          });
        }
      }
    }
    return allOk;
  }

  /// Single-writer self-compaction of THIS instance's own exclusive log when it exceeds `MAX_LOG_BYTES`.
  /// Zero concurrent writers exist for `ownLog`, so atomic temp-rename cannot lose any peer write.
  #compactOwnLogIfNeeded(syncRes: SyncDiskResult): void {
    const ownLog = this.ownLogPath();
    if (
      ownLog === null ||
      this.#closed ||
      !syncRes.fullScanClean ||
      !syncRes.ownLogReadOk ||
      syncRes.ownLogSize <= MAX_LOG_BYTES
    ) {
      return;
    }
    if (!this.#persistDemotionMarkers()) return;

    const idPrefix = `${this.#instanceId}:`;
    const cutoff = syncRes.scannedNowMs - this.#windowMs;
    const keptLines: string[] = [];
    for (const [mode, byStamp] of this.#entries) {
      for (const rec of byStamp.values()) {
        if (rec.demotedAt !== undefined) continue;
        for (const ev of rec.events) {
          if (ev.id.startsWith(idPrefix) && ev.at > cutoff) {
            keptLines.push(JSON.stringify({ v: 2, mode, stamp: rec.stamp, at: ev.at, id: ev.id }));
          }
        }
      }
    }
    const compacted = keptLines.length > 0 ? `${keptLines.join("\n")}\n` : "";
    const tmpPath = `${ownLog}.tmp.${randomUUID()}`;
    try {
      writeFileSync(tmpPath, compacted, "utf8"); // sync: self-compact single-writer breaker log temp file
      renameSync(tmpPath, ownLog); // sync: atomically replace own single-writer breaker log
      this.#fileCursors.delete(basename(ownLog));
    } catch (err) {
      try {
        unlinkSync(tmpPath); // sync: clean up failed own-log compaction temp file
      } catch {}
      log.warn("readers", "failed to self-compact pion circuit breaker log", {
        file: ownLog,
        error: err instanceof Error ? err.message : String(err),
      });
    }
    this.#reapDeadPeerLogs(syncRes);
  }

  /// Reap only the exact peer logs cleanly scanned in `syncRes.scannedPeers` whose owning PID is dead (`ESRCH`)
  /// and whose metadata `(dev, ino, size, mtimeMs)` is unchanged and strictly older than `windowMs`,
  /// plus stale orphan `.tmp.*` files older than 60s. Never deletes own log, live-PID logs, or demotion markers.
  #reapDeadPeerLogs(syncRes: SyncDiskResult): void {
    const file = this.#stateFile;
    if (file === null || this.#closed) return;
    if (!syncRes.fullScanClean || this.#pendingEvents.length > 0 || !this.#persistDemotionMarkers()) return;
    const dir = dirname(file);
    const base = basename(file);
    const now = syncRes.scannedNowMs;

    for (const meta of syncRes.scannedPeers) {
      const parsed = parsePeerLogName(meta.name, base);
      if (parsed === null || parsed.instId === this.#instanceId) continue;
      if (pidAlive(parsed.pid)) continue;
      if (Math.floor(meta.mtimeMs) + this.#windowMs >= now) continue;
      const fullPath = join(dir, meta.name);
      try {
        const st = statSync(fullPath); // sync: verify dead-peer log unchanged since clean scan before reaping
        if (
          st.isFile() &&
          st.dev === meta.dev &&
          st.ino === meta.ino &&
          st.size === meta.size &&
          st.mtimeMs === meta.mtimeMs
        ) {
          unlinkSync(fullPath); // sync: reap verified expired dead-peer breaker log
          this.#fileCursors.delete(meta.name);
        }
      } catch {}
    }

    // Separate best-effort scan for stale orphan `.tmp.*` files older than 60s only.
    try {
      for (const name of readdirSync(dir)) { // sync: scan breaker dir for stale orphan temp files
        if (!isOrphanTmpName(name, base)) continue;
        const fullPath = join(dir, name);
        try {
          const st = statSync(fullPath); // sync: check orphan breaker temp file age
          if (st.isFile() && Math.floor(st.mtimeMs) + ORPHAN_TMP_AGE_MS <= now) {
            unlinkSync(fullPath); // sync: remove stale orphan breaker temp file
          }
        } catch {}
      }
    } catch {}
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

  #applyParsed(lines: readonly ParsedLine[], fromMarker: boolean): void {
    const touched = new Map<string, { mode: ReaderMode; rec: StampRecord }>();
    for (const item of lines) {
      const rec = this.#getOrCreateRecord(item.mode, item.stamp);
      if (rec.demotedPersisted) continue;
      if (item.demotedAt !== undefined) {
        rec.demotedAt = rec.demotedAt !== undefined ? Math.min(rec.demotedAt, item.demotedAt) : item.demotedAt;
        if (fromMarker) {
          rec.demotedPersisted = true;
          rec.events.length = 0;
          rec.seenIds.clear();
        }
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
    }
  }

  /// Flush any pending in-memory crash events to THIS instance's exclusive log via `O_APPEND`, looping `writeSync`
  /// until all bytes are written. Any short write (`<= 0`) or error preserves `#pendingEvents` and returns `false`.
  flushPending(): boolean {
    const ownLog = this.ownLogPath();
    if (ownLog === null || this.#pendingEvents.length === 0) return true;
    // Leading `\n` isolates each record from any torn partial trailing line left by a hard kill.
    const payload = this.#pendingEvents
      .map(
        (p) =>
          `\n${JSON.stringify({
            v: 2,
            mode: p.mode,
            stamp: p.stamp,
            at: p.ev.at,
            id: p.ev.id,
            ...(p.demotedAt !== undefined ? { demotedAt: p.demotedAt } : {}),
          })}\n`,
      )
      .join("");
    const buf = Buffer.from(payload, "utf8");
    let fd: number | null = null;
    try {
      mkdirSync(dirname(ownLog), { recursive: true }); // sync: ensure breaker dir exists before appending own log
      const flags = fsConstants.O_WRONLY | fsConstants.O_CREAT | fsConstants.O_APPEND;
      fd = this.#writeOpenSyncFn(ownLog, flags, 0o666); // sync: single-writer O_APPEND open of exclusive breaker log
      let written = 0;
      while (written < buf.length) {
        const n = this.#writeSyncFn(fd, buf, written, buf.length - written); // sync: full-buffer write loop with short-write guard
        if (typeof n !== "number" || n <= 0) {
          throw new Error(`short write to breaker log: wrote ${written} of ${buf.length} bytes`);
        }
        written += n;
      }
      this.#pendingEvents.length = 0;
      return true;
    } catch (error) {
      log.warn("readers", "failed to persist pion circuit breaker state", {
        file: ownLog,
        error: error instanceof Error ? error.message : String(error),
      });
      return false;
    } finally {
      if (fd !== null) {
        try {
          this.#writeCloseSyncFn(fd); // sync: close exclusive breaker log fd
        } catch {}
      }
    }
  }

  /// Record an unexpected exit of a Pion process bound at spawn to `(source, mode, stamp)`.
  /// Only `source === "default"` counts; explicit `"pion"` / `"shadow"` exits are ignored.
  /// Returns `true` if this exit tripped (or reaffirmed) demotion for `(mode, stamp)`.
  recordUnexpectedExit(
    mode: ReaderMode,
    stamp: PionBinaryStamp,
    source: ReaderSelectSource,
    nowMs = this.#nowFn(),
  ): boolean {
    if (source !== "default") return false;
    if (this.#stateFile !== null) this.syncFromDisk();

    const rec = this.#getOrCreateRecord(mode, stamp);
    if (rec.demotedAt !== undefined && rec.demotedPersisted) {
      if (this.#stateFile !== null && this.#pendingEvents.length > 0 && this.flushPending()) {
        this.#ensureWatcher();
        const syncRes = this.#syncFromDiskDetailed();
        this.#compactOwnLogIfNeeded(syncRes);
      }
      return true;
    }

    let tripped = rec.demotedAt !== undefined;
    if (rec.demotedAt === undefined) {
      const ev: BreakerEvent = { at: nowMs, id: `${this.#instanceId}:${++eventSeq}` };
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
        this.#pendingEvents.push({
          mode,
          stamp,
          ev,
          ...(rec.demotedAt !== undefined ? { demotedAt: rec.demotedAt } : {}),
        });
      }
    }

    if (this.#stateFile !== null) {
      if (this.#pendingEvents.length > 0) {
        if (this.flushPending()) {
          this.#persistDemotionMarkers();
          this.#ensureWatcher();
          const syncRes = this.#syncFromDiskDetailed();
          this.#persistDemotionMarkers();
          this.#compactOwnLogIfNeeded(syncRes);
        }
      } else if (rec.demotedAt !== undefined && !rec.demotedPersisted) {
        this.#persistDemotionMarkers();
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
    this.#bindEpoch++;
    this.#closeRuntimeHandles();
    this.#entries.clear();
    this.#pendingEvents.length = 0;
    this.#fileCursors.clear();
    this.#instanceId = randomUUID();
    this.#watchRetryDelayMs = WATCH_RETRY_INITIAL_MS;
    this.#readRetryDelayMs = READ_RETRY_INITIAL_MS;
    this.#watcherNeedsCatchup = false;
    this.#asyncDirty = false;
    this.#closed = false;
    this.#closeSynced = false;
    this.#windowMs = options?.windowMs ?? BREAKER_WINDOW_MS;
    this.#threshold = options?.threshold ?? BREAKER_THRESHOLD;
    this.#stateFile = options?.stateFile ?? null;
    this.#watchEnabled = options?.watch ?? true;
    this.#watchFn = options?.watchFn ?? watch;
    this.#openSyncFn = options?.readFs?.openSync ?? openSync;
    this.#openAsyncFn = options?.readFs?.openAsync ?? open;
    this.#writeOpenSyncFn = options?.writeFs?.openSync ?? openSync;
    this.#writeSyncFn = options?.writeFs?.writeSync ?? writeSync;
    this.#writeCloseSyncFn = options?.writeFs?.closeSync ?? closeSync;
    this.#publishRenameSyncFn = options?.publishFs?.renameSync ?? renameSync;
    this.#nowFn = options?.nowFn ?? (() => wall.now());
    if (this.#stateFile !== null) {
      this.#ensureWatcher();
      const syncRes = this.#syncFromDiskDetailed();
      this.#reapDeadPeerLogs(syncRes);
    }
  }
}

/// Fallback breaker used only when no per-station `ReaderConfig` breaker is supplied (e.g. standalone unit tests).
export const pionCircuitBreaker = new PionCircuitBreaker();
