// Cold storage of archived sessions' files (the Rust station's hub.rs: archive_room, clean_rebuildable, pack_archive,
// archive_history_files, restore_archive, archive_has_jobs, archive_is_cold): once an archived session is idle, what a
// build makes again is removed from its own directory, and the rest of its workspace and the transcripts its runtime
// keeps in station storage are packed (archive.ts); they are restored before its runtime starts again, or when it is
// shown again. The hub calls it (ColdStorage) from the session's queue, so no turn starts halfway through.
import { access, readdir, realpath, stat, unlink, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { log } from "../ops/log.ts";
import { platform } from "../platform/index.ts";
import { wall } from "../ops/fibers.ts";
import { realOutside } from "../ops/places.ts";
import { homesFirst, sessionPlaces } from "../read/transcript.ts";
import { transcriptPathsSoon } from "../read/transcript-soon.ts";
import * as archive from "./archive.ts";
import { runtimeNamed } from "./config.ts";
import { MEASURE_UP_TO, measureRoom, measuredUpTo, roomOfSoon, safeToRemove, within } from "./footprint.ts";
import type { PackedProgram } from "./packed-mb.ts";
import type { ReaderSelectConfig } from "../read/reader-select.ts";
import type { ColdStorage, Hub } from "./hub.ts";
import type { Located } from "./live.ts";
import type { RuntimeKind } from "../agents/runtime.ts";
import type { SessionRow } from "../store/rows.ts";

/// Links followed off the station's thread, never into a folder macOS protects (a session continued there, a job's
/// directory: ops/places.ts). Each path is kept for 15 minutes so repeated archive rounds do not follow the same
/// folders again; one followed already is not followed again by a second asker meanwhile.
const followed = new Map<string, { at: number; real: string | null }>();
const following = new Map<string, Promise<string | null>>();
const FOLLOWED_MS = 15 * 60_000;
const canonical = (path: string): Promise<string | null> => {
  const kept = followed.get(path);
  if (kept !== undefined && wall.now() - kept.at < FOLLOWED_MS) return Promise.resolve(kept.real);
  const going = following.get(path);
  if (going) return going;
  const follow = realOutside(path)
    .then(
      (real) => {
        followed.delete(path);
        followed.set(path, { at: wall.now(), real });
        if (followed.size > 1024) followed.delete(followed.keys().next().value!);
        return real;
      },
      // (a link changed as it was followed: not kept, so it is still taken to be in use, and followed again next time)
      () => null,
    )
    .finally(() => following.delete(path));
  following.set(path, follow);
  return follow;
};

/// `path` as last followed, whatever its age (`archiveRoom` is asked again before each piece packed, so it follows
/// nothing itself: its work follows first, `followInUse`); undefined when it never was, and it is followed in the
/// background for the next ask.
const followedNow = (path: string): string | null | undefined => {
  const kept = followed.get(path);
  if (kept === undefined || wall.now() - kept.at >= FOLLOWED_MS) void canonical(path);
  return kept?.real;
};

/// Whether `path`, followed, is in `dir`; one not followed yet is taken to be (its work waits for the next round).
const inRoom = (path: string, dir: string): boolean => {
  const real = followedNow(path);
  return real === undefined || (real !== null && within(real, dir));
};

/// Each session's own directory as last found (`roomOfSoon`, off the thread): `archiveRoom` is asked again before each
/// step of packing one, and followed its paths on the station's thread at every ask. Every work that asks it finds it
/// first (`findRoom`), so it is never followed here: a workspace not found (moved meanwhile) has no room, and the work
/// stops.
const rooms = new Map<string, string | null>();
const keptRoom = (workspace: string): string | null => rooms.get(workspace) ?? null;
async function findRoom(dataDir: string, workspace: string): Promise<void> {
  const room = await roomOfSoon(dataDir, workspace);
  rooms.delete(workspace);
  rooms.set(workspace, room);
  if (rooms.size > 1024) rooms.delete(rooms.keys().next().value!);
}

/// Whether `path` is there, asked off the station's thread.
const there = (path: string): Promise<boolean> => access(path).then(() => true, () => false);

/// Workspaces larger than this after cleaning rebuildable directories are left unpacked on archive (marked `cold` so
/// expiry and low-disk reclamation still apply, and transcripts are still packed).
export const MAX_PACK_WORKSPACE_BYTES = 2 * 1024 ** 3;

/// How long an archived workspace whose packing a Windows lock refused (`EPERM`, `EBUSY`, `EACCES` past
/// `renameRetrying`'s wait: a shared app-server still in it, a scanner) is left before the backfill tries it again, by
/// how many times it was refused: one held for good is not compressed again every round. Refused once more than these
/// (or with the next try too near `archivedWorkspaceMs`), it is marked `cold` unpacked, like one too large, so it is still
/// emptied in time and on a low disk.
export const WORKSPACE_BUSY_BACKOFF_MS = [10 * 60_000, 30 * 60_000, 2 * 3600_000, 6 * 3600_000] as const;

/// How long before `archivedWorkspaceMs` a wait must end for the backfill still to reach it: a few of its rounds
/// (`ARCHIVE_UPKEEP_EVERY_MS`, 10 min, and its cursor's backlog). One that would end later is marked `cold` at once.
export const BUSY_RETRY_EXPIRY_MARGIN_MS = 30 * 60_000;

export class ColdRooms implements ColdStorage {
  /// The hub it works for (made after it).
  private readonly hub: () => Hub;
  private readonly measure: typeof measureRoom;
  private readonly maxPackWorkspaceBytes: number;
  private readonly readers: (() => ReaderSelectConfig) | undefined;
  private readonly packed: PackedProgram | undefined;
  private readonly packing = new Map<string, Set<AbortController>>();
  private readonly packWorkspace: typeof archive.packWorkspaceIf;
  /// Archived sessions whose workspace a lock kept from being packed: not asked again (`needsPack`) until `until`.
  private readonly busyRetry = new Map<string, { until: number; attempts: number }>();

  constructor(hub: () => Hub, opts?: { measureRoom?: typeof measureRoom; maxPackWorkspaceBytes?: number; readers?: () => ReaderSelectConfig; packed?: PackedProgram; packWorkspace?: typeof archive.packWorkspaceIf }) {
    this.hub = hub;
    this.packWorkspace = opts?.packWorkspace ?? archive.packWorkspaceIf;
    this.readers = opts?.readers;
    this.packed = opts?.packed;
    this.measure = opts?.measureRoom ?? ((dir, budget) => measureRoom(dir, budget, this.readers));
    this.maxPackWorkspaceBytes = opts?.maxPackWorkspaceBytes ?? MAX_PACK_WORKSPACE_BYTES;
  }

  cancelPack(key: string): void {
    this.busyRetry.delete(key);
    const active = this.packing.get(key);
    if (!active) return;
    for (const ac of active) ac.abort();
  }

  private dataDir() {
    return this.hub().config().dataDir;
  }

  /// Its session's own directory found off the thread, and the directories of what is in use followed, for
  /// `archiveRoom` to ask again and again.
  private async findRoom(key: string): Promise<void> {
    const row = this.hub().store.getSession(key);
    if (row) await findRoom(this.dataDir(), row.workspace);
    await this.followInUse();
  }

  /// The directories of the sessions in use and the active jobs, followed (off the thread) for `archiveRoom`.
  private async followInUse(): Promise<void> {
    const store = this.hub().store;
    const paths = new Set<string>();
    for (const s of store.sessionsInUse()) for (const path of [s.workspace, s.cwd ?? s.workspace]) paths.add(path);
    try {
      for (const job of store.jobsUp()) paths.add(job.cwd);
    } catch {}
    await Promise.all([...paths].map(canonical));
  }

  /// A session's own directory, while nothing needs it: archived when `requireArchived` is true (else unarchived),
  /// not running, and no other in-use session or active job using its directory.
  private cleanableRoom(key: string, requireArchived: boolean): string | null {
    const hub = this.hub();
    const row = hub.store.getSession(key);
    if (!row) return null;
    const dir = keptRoom(row.workspace);
    const archivedMatch = requireArchived ? row.archivedAt !== null : row.archivedAt === null;
    if (dir === null || !archivedMatch || row.running || hub.processState(key) === "running") return null;
    // The sessions in use alone (by their indexes): this is asked again and again as a session is packed.
    const shared = hub.store
      .sessionsInUse()
      .some(
        (s) =>
          s.key !== key &&
          [s.workspace, s.cwd ?? s.workspace].some((path) => inRoom(path, dir)),
      );
    if (shared || this.hasJobs(key, dir)) return null;
    return dir;
  }

  /// An archived session's own directory, while nothing needs it: not back in the lists or at work, and no other
  /// session or active job (running, or a service waiting to restart) using it.
  archiveRoom(key: string): string | null {
    return this.cleanableRoom(key, true);
  }

  /// Whether an archived session still lacks its `cold` mark and is eligible to be packed now.
  async needsPack(key: string): Promise<boolean> {
    const busy = this.busyRetry.get(key);
    if (busy !== undefined && wall.now() < busy.until) return false;
    await this.findRoom(key);
    const dir = this.archiveRoom(key);
    return dir !== null && !(await there(join(dir, "cold")));
  }

  private async followActiveJobs(): Promise<void> {
    let jobs;
    try {
      jobs = this.hub().store.jobsUp();
    } catch {
      return;
    }
    const now = wall.now();
    const paths = new Set<string>();
    for (const job of jobs) {
      const kept = followed.get(job.cwd);
      if (kept === undefined || now - kept.at >= FOLLOWED_MS) paths.add(job.cwd);
    }
    if (paths.size > 0) await Promise.all([...paths].map(canonical));
  }

  private hasJobs(key: string, dir: string): boolean {
    let jobs;
    try {
      // Those active (running, or a service waiting to start again), by their index: not every job ever run.
      jobs = this.hub().store.jobsUp();
    } catch {
      return true;
    }
    return jobs.some((job) => job.sessionKey === key || inRoom(job.cwd, dir));
  }

  private async cleanRebuildableIn(
    key: string,
    requireArchived: boolean,
  ): Promise<{ freed: number; complete: boolean; remaining: number; walkComplete: boolean } | null> {
    await this.findRoom(key);
    const dir = this.cleanableRoom(key, requireArchived);
    if (dir === null) return null;
    const room = await this.measure(dir);
    let freed = 0;
    let interrupted = false;
    for (const [path, bytes] of room.rebuild) {
      await this.followActiveJobs();
      // Restoring/activating a chat updates the store before its next message reaches the actor queue.
      const row = this.hub().store.getSession(key);
      const stillOk = row !== null && (requireArchived ? row.archivedAt !== null : row.archivedAt === null)
        && !row.running && this.hub().processState(key) !== "running";
      if (!stillOk || this.hasJobs(key, dir)) {
        interrupted = true;
        break;
      }
      if (!(await safeToRemove(path))) continue;
      try {
        await archive.removeTree(path);
        freed += bytes;
      } catch (error) {
        log.warn("hub", "not removed", { path, error: (error as Error).message });
      }
    }
    if (freed > 0) {
      log.info(
        "hub",
        requireArchived ? "rebuildable files of an archived session cleaned" : "rebuildable files of an idle session cleaned",
        { session: key, freed },
      );
    }
    const walkComplete = room.complete !== false;
    const incompleteWalk = !walkComplete && (room.reason === "duration" || (room.reason === "entries" && freed > 0));
    return { freed, complete: !interrupted && !incompleteWalk, remaining: Math.max(0, room.bytes - freed), walkComplete };
  }

  /// Removes what a build or an install makes again (node_modules, a Cargo target, …; footprint.ts `rebuildableSoon`) from
  /// an archived session's own directory: it may come back, and is built again then. Left as it is while the session is
  /// back in the lists or at work, or a session/job still uses its directory. Returns removed allocated file bytes.
  async cleanRebuildable(key: string): Promise<number> {
    return (await this.cleanRebuildableIn(key, true))?.freed ?? 0;
  }

  /// Removes rebuildable build/install directories from an idle unarchived session's own directory without packing,
  /// marking cold, or touching transcripts. Returns removed bytes (>= 0) when the scan and cleanup completed, or null
  /// when skipped before measuring (running / shared / active job), interrupted mid-cleanup, or cut short by an
  /// incomplete walk.
  async cleanIdleRebuildable(key: string): Promise<number | null> {
    const res = await this.cleanRebuildableIn(key, false);
    return res !== null && res.complete ? res.freed : null;
  }

  /// The files of an archived session's transcripts that cold storage puts away, nothing of it on the station's thread.
  /// Runtime-owned files outside station storage are never removed. A shared runtime session is left hot while another
  /// chat can still use it. The main transcript and Claude's subagent files are compressed together. The transcripts are
  /// found where the live view finds them (live.ts `locateAsync`, the MoonBit program's), their directories followed and
  /// Claude's subagent files listed off it; where there is no locator (a test's hub), as its history finds them
  /// (`historyFound`).
  async historyFilesSoon(key: string, packing: boolean): Promise<string[]> {
    const hub = this.hub();
    const row = hub.store.getSession(key);
    if (!row) throw new Error(`unknown session ${key}`);
    const sources = hub.store.runtimeSessionSources(key);
    if (sources.length === 0) return [];
    if (packing && sources.some((source) => hub.store.transcriptInUse(source.runtime, source.id, key))) return [];
    const locate = hub.live.locateAsync;
    const located = locate !== null ? await locate(key, new AbortController().signal) : await this.historyFound(row, sources);
    if (located === null) return [];
    const root = await realpath(hub.config().dataDir);
    const files: string[] = [];
    for (const each of located.paths) {
      const [path, runtime] = typeof each === "string" ? [each, located.runtime] : [each.path, each.runtime];
      // (its directory gone since it was located: nothing of it to find, the others still are)
      const parent = await realpath(dirname(path)).catch((error: NodeJS.ErrnoException) => {
        if (error.code === "ENOENT") return null;
        throw error;
      });
      if (parent === null || !within(parent, root)) continue;
      files.push(join(parent, basename(path)));
      if (runtime === "claude") await archive.jsonlFilesSoon(join(parent, basename(path, ".jsonl")), files);
    }
    return files;
  }

  /// Where a session's transcripts are where no locator finds them (a test's hub): each of the runtime sessions it ran in
  /// (sessions/afresh.ts) found as its history finds it, off the station's thread.
  async historyFound(row: SessionRow, sources: readonly { id: string; runtime: string; profile: string | null }[]): Promise<Located> {
    const { dataDir, profiles } = this.hub().config();
    const paths: { path: string; runtime: RuntimeKind }[] = [];
    for (const each of sources) {
      const runtime = runtimeNamed(each.runtime);
      if (!runtime) continue;
      const path = (await transcriptPathsSoon(runtime, dataDir, homesFirst(profiles, each.profile), [each.id], sessionPlaces(row))).paths[0];
      if (path !== undefined) paths.push({ path, runtime });
    }
    return paths.length === 0 ? null : { runtime: paths[0]!.runtime, paths };
  }

  /// Whether an archived session's directory or transcripts are put away: asked before each of its processes opens, so
  /// off the station's thread, its transcripts found where the live view finds them (live.ts `locateAsync`, a worker's).
  async isCold(key: string): Promise<boolean> {
    const hub = this.hub();
    const row = hub.store.getSession(key);
    const room = row ? await roomOfSoon(this.dataDir(), row.workspace) : null;
    if (room !== null && ((await there(join(room, "cold"))) || (await there(archive.workspaceArchive(room))) || (await there(join(room, "workspace-locks.json")))))
      return true;
    let paths: string[];
    try {
      const locate = hub.live.locateAsync;
      paths = locate !== null
        ? ((await locate(key, new AbortController().signal))?.paths ?? []).map((p) => (typeof p === "string" ? p : p.path))
        : await this.historyFilesSoon(key, false);
    } catch {
      return false;
    }
    for (const path of paths) if (!(await there(path)) && (await there(archive.packed(path)))) return true;
    return false;
  }

  async restore(key: string, opts?: { onlyIfUnarchived?: boolean }): Promise<void> {
    this.cancelPack(key);
    const row = this.hub().store.getSession(key);
    if (!row) throw new Error(`unknown session ${key}`);
    const room = await roomOfSoon(this.dataDir(), row.workspace);
    if (room === null) return;
    await archive.withLock(room, async () => {
      if (opts?.onlyIfUnarchived === true && this.hub().store.getSession(key)?.archivedAt !== null) return;
      await archive.restoreWorkspace(room, { program: this.packed });
      // Restoration must work even after the store has already brought this chat back.
      for (const path of await this.historyFilesSoon(key, false)) await archive.restoreFile(path, { program: this.packed });
      await unlink(join(room, "cold")).catch(() => undefined);
    });
  }

  /// Archived long enough (expireArchived, lifecycle.ts): its workspace keeps only the files sent in its chat
  /// (archive.ts `emptyWorkspace`); its history and transcripts stay. Left as it is while it is shown again or at work,
  /// or something else still uses its directory; one restored (no `cold` mark) is no longer archived.
  /// `before`: only if it was archived by then (one shown and archived again since is archived anew).
  async expire(key: string, before: number): Promise<void> {
    const due = () => {
      const at = this.hub().store.getSession(key)?.archivedAt ?? null;
      return at !== null && at <= before && this.archiveRoom(key) !== null;
    };
    await this.findRoom(key);
    const room = due() ? this.archiveRoom(key) : null;
    if (room === null) return;
    await archive.withLock(room, async () => {
      if (!due() || !(await there(join(room, "cold"))) || !(await archive.holdsMore(room))) return;
      await archive.emptyWorkspace(room, { program: this.packed });
      log.info("hub", "workspace of a long-archived session emptied", { session: key });
    });
  }

  /// Whether an archived session's directory holds more than its chat's files. Asked of every archived session in turn
  /// (lifecycle.ts expireArchived, relieveArchived): its paths followed off the main thread, where on a station short of
  /// memory (2026-11-02) they held every device for seconds at a time, 47 s in six hours.
  async holdsMore(key: string): Promise<boolean> {
    const row = this.hub().store.getSession(key);
    const room = row ? await roomOfSoon(this.dataDir(), row.workspace) : null;
    return room !== null && (await access(join(room, "cold")).then(() => true, () => false)) && (await archive.holdsMore(room));
  }

  async pack(key: string): Promise<void> {
    const ac = new AbortController();
    let active = this.packing.get(key);
    if (!active) this.packing.set(key, (active = new Set()));
    active.add(ac);
    try {
      await this.findRoom(key);
      if (ac.signal.aborted) return;
      const room = this.archiveRoom(key);
      if (room === null) return;
      const ready = () => !ac.signal.aborted && this.archiveRoom(key) !== null;
      await archive.withLock(room, async () => {
        if (!ready()) return;
        await this.stopStrays(key, join(room, "workspace"));
        if (!ready()) return;
        const clean = await this.cleanRebuildableIn(key, true);
        if (clean === null || !ready()) return;
        let shouldPackWorkspace = false;
        if (clean.remaining > this.maxPackWorkspaceBytes) {
          log.info("hub", "archived workspace too large to compress; left unpacked", {
            session: key,
            bytes: clean.remaining,
            limit: this.maxPackWorkspaceBytes,
          });
        } else if (!clean.walkComplete) {
          if (clean.freed === 0) {
            log.info("hub", "archived workspace too large to compress; left unpacked", {
              session: key,
              bytes: clean.remaining,
              limit: this.maxPackWorkspaceBytes,
              incomplete: true,
            });
          } else {
            let check: { bytes: number; complete: boolean } | null;
            try {
              check = await measuredUpTo(join(room, "workspace"), this.maxPackWorkspaceBytes, ac.signal, MEASURE_UP_TO, false, this.readers);
            } catch (error) {
              if (ac.signal.aborted) return;
              log.warn("hub", "re-measuring archived workspace failed; leaving unpacked", {
                session: key,
                error: (error as Error).message,
              });
              check = { bytes: clean.remaining, complete: false };
            }
            if (!ready()) return;
            if (check.complete && check.bytes <= this.maxPackWorkspaceBytes) {
              shouldPackWorkspace = true;
            } else {
              log.info("hub", "archived workspace too large to compress; left unpacked", {
                session: key,
                bytes: check.bytes,
                limit: this.maxPackWorkspaceBytes,
                incomplete: !check.complete,
              });
            }
          }
        } else {
          shouldPackWorkspace = true;
        }
        // Marked `cold` only once all is done: a pack cut short (aborted, or its workspace held by a lock for now) is
        // backfilled (`packUnfinishedArchived`, which asks `needsPack`).
        let workspaceDeferred = false;
        if (shouldPackWorkspace) {
          try {
            await this.packWorkspace(room, ready, { signal: ac.signal, readers: this.readers });
          } catch (error) {
            if (ac.signal.aborted || !ready()) return;
            const code = (error as NodeJS.ErrnoException)?.code;
            if (code === "EPERM" || code === "EBUSY" || code === "EACCES") {
              // A lock refused the workspace's rename aside (it is left whole where it was) or the removal of its old
              // tree (packed, that tree removed on the next try); its transcripts will still be packed.
              const attempts = this.busyRetry.get(key)?.attempts ?? 0;
              const delay = WORKSPACE_BUSY_BACKOFF_MS[attempts];
              const afterMs = this.hub().config().archivedWorkspaceMs;
              const archivedAt = this.hub().store.getSession(key)?.archivedAt ?? null;
              const inTime = afterMs <= 0 || archivedAt === null || (delay !== undefined && wall.now() + delay + BUSY_RETRY_EXPIRY_MARGIN_MS < archivedAt + afterMs);
              if (delay !== undefined && inTime) {
                this.busyRetry.set(key, { until: wall.now() + delay, attempts: attempts + 1 });
                workspaceDeferred = true;
                log.warn("hub", "archived workspace busy; left unpacked for backfill", { session: key, retryInMs: delay, error: (error as Error).message });
              } else {
                log.warn("hub", "archived workspace stayed busy; marked cold unpacked", { session: key, attempts: attempts + 1, error: (error as Error).message });
              }
            } else {
              // Tried again every round it would be compressed again whole (up to 2 GiB) and fail the same (a full
              // disk, a file it cannot read): left as one too large is, emptied in time.
              log.warn("hub", "archived workspace could not be packed; marked cold unpacked", { session: key, error: (error as Error).message });
            }
          }
        }
        if (!ready()) return;
        await this.packHistory(key, ready);
        if (!ready() || workspaceDeferred) return;
        this.busyRetry.delete(key);
        await writeFile(join(room, "cold"), "workspace and history may be compressed\n");
      });
    } finally {
      active.delete(ac);
      if (active.size === 0) this.packing.delete(key);
    }
  }

  /// What still runs in an archived session's workspace, its agent's and its jobs' processes gone: what they left
  /// behind running on its own (an adb server its `adb` started, a daemon), stopped even after the workspace is removed.
  private async stopStrays(key: string, workspace: string): Promise<void> {
    if (platform.os === "windows") return;
    let pids: number[];
    try {
      const { stdout } = await promisify(execFile)("ps", ["-U", String(process.getuid?.() ?? ""), "-o", "pid="]);
      pids = stdout.split("\n").map((l) => Number(l.trim())).filter((p) => Number.isSafeInteger(p) && p > 1 && p !== process.pid);
    } catch {
      return;
    }
    const real = await realpath(workspace).catch(() => workspace);
    let stopped = 0;
    for (const [pid, cwd] of await platform.cwds(pids).catch(() => new Map<number, string>())) {
      if (cwd !== real && cwd !== workspace && !within(cwd, real) && !within(cwd, workspace)) continue;
      try {
        process.kill(pid, "SIGTERM");
        stopped++;
      } catch {}
    }
    if (stopped > 0) log.info("hub", "what was left running in an archived session's workspace stopped", { session: key, n: stopped });
  }

  /// Packs an archived session's transcripts in place (its room locked, `ready` while it may), then lets go of the
  /// Rust station's copy of them (`archive/transcripts/<key>.jsonl.zst`, which nothing reads) once they all are: the
  /// copy's size, 0 without one.
  private async packHistory(key: string, ready: () => boolean): Promise<number> {
    const files = await this.historyFilesSoon(key, true);
    // (asked before each piece of each file is packed: what is in memory and the store alone, no transcript looked for
    // again, which the files found already are)
    const hub = this.hub();
    const sources = hub.store.runtimeSessionSources(key);
    const unused = () => !sources.some((source) => hub.store.transcriptInUse(source.runtime, source.id, key));
    for (const path of files) {
      await archive.packFileIf(path, () => ready() && unused(), { program: this.packed });
    }
    if (files.length === 0) return 0;
    for (const path of files) if ((await there(path)) || !(await there(archive.packed(path)))) return 0;
    const copy = legacyCopy(this.hub().store.archiveDir(), key);
    const size = await stat(copy).then((s) => s.size, () => undefined);
    if (size === undefined) return 0;
    await unlink(copy);
    return size;
  }

  /// What the Rust station's archiving left (2026-09 and early 10): each archived session's transcript copied into
  /// `archive/transcripts/`, its own left as it was, so both were on the disk (1.4 GB on a station). Each such session's
  /// transcripts are packed now as archiving packs them, and the copy let go; nothing makes copies any more, so this
  /// comes to an end. Its workspace is left as it is: only the transcripts are touched. A copy whose session is back
  /// in the lists or at work stays until its session is archived again.
  async finishLegacyCopies(): Promise<void> {
    const dir = join(this.hub().store.archiveDir(), "transcripts");
    let names: string[];
    try {
      names = await readdir(dir);
    } catch {
      return;
    }
    let freed = 0;
    let done = 0;
    for (const name of names) {
      if (!name.endsWith(LEGACY)) continue;
      const key = name.slice(0, -LEGACY.length);
      await this.findRoom(key);
      const room = this.archiveRoom(key);
      if (room === null) continue;
      const ready = () => this.archiveRoom(key) !== null;
      try {
        await archive.withLock(room, async () => {
          if (!ready()) return;
          const size = await this.packHistory(key, ready);
          freed += size;
          if (size > 0) done++;
        });
      } catch (error) {
        log.warn("hub", "an archived session's transcripts not packed", { session: key, error: (error as Error).message });
      }
    }
    if (done > 0) log.info("hub", "the Rust station's transcript copies let go, the transcripts packed", { sessions: done, freed });
  }

  /// Transcripts put away before they were in segments (read/packed.ts), each read whole for every page of its history
  /// (150 MB for one): put away again in segments, one after another. Once every one is, said so on disk (SEGMENTED),
  /// and none looked for again: each station start went through every archived session's
  /// transcripts again, finding them on the station's thread (a Codex one by its sessions' tree), 1.2 s held at a time
  /// on a station short of memory (2026-11-03), every 10 min that evening.
  async segmentHistories(): Promise<void> {
    const said = join(this.dataDir(), SEGMENTED);
    if (await access(said).then(() => true, () => false)) return;
    let done = 0;
    let failed = false;
    const store = this.hub().store;
    // Do not load every session before yielding. The upper bound also keeps newly archived sessions from extending
    // this sweep; archives made now are already put away in segments.
    const through = store.lastArchivedSession();
    let after: typeof through = null;
    while (through !== null) {
      const page = store.archivedSessions(after, through);
      if (page.length === 0) break;
      for (const row of page) {
        let files: string[] = [];
        try {
          files = await this.historyFilesSoon(row.key, false);
        } catch {}
        for (const path of files) {
          try {
            if (await archive.segmentFile(path, { program: this.packed })) done++;
          } catch (error) {
            failed = true;
            log.warn("hub", "a put-away transcript not put in segments", { session: row.key, error: (error as Error).message });
          }
        }
        // Between sessions, including one whose files could not be found, the station's other work.
        await new Promise<void>((resolve) => setImmediate(resolve));
      }
      after = page[page.length - 1]!;
    }
    if (done > 0) log.info("hub", "put-away transcripts put in segments", { n: done });
    if (!failed) await writeFile(said, "").catch(() => undefined);
  }
}

/// Said in the station's data once every transcript put away is in segments (`segmentHistories`).
const SEGMENTED = "transcripts-segmented";

/// The Rust station's copy of an archived session's transcript.
const LEGACY = ".jsonl.zst";
const legacyCopy = (archiveDir: string, key: string) => join(archiveDir, "transcripts", `${key}${LEGACY}`);
