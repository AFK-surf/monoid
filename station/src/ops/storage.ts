// What the station keeps in its data directory (<data>, ~/.stillfail), each top-level name with its class, and the
// upkeep that holds what grows by itself to its bounds. Every name the station's code joins onto <data> is listed in
// STORAGE_MANIFEST (test/storage-classes.test.ts reads the code and fails on one that is not): a new one says what it is
// and, if it grows, what bounds it.
//
// - authoritative: what lasts or is a person's (the database, the config, transcripts, uploads, homes). Never
//   removed by upkeep.
// - session-bound: goes with its chat or task (an archived chat's workspace, a remote room): its own lifecycle removes it
//   (sessions/lifecycle.ts, jobs/remote.ts), upkeep only when the disk is low.
// - bounded-ephemeral: a log, a cache or a process's state, with a bound in bytes or age and the upkeep that holds it.
//
// What is found on 2026-11-15 grew without bound: remote/sessions to 63 GiB in five days, 3,255 task records in
// remote/incoming (a station of five days), 1.1 GB of runners' output and 1.0 GB of jobs' logs (a VM's, 747 and 860 MB
// the largest each), a stillfail.log of 62 MB never cut. `Upkeep` below holds each to its bound.
//
// The logs other processes write are cut where they are (`rotateInPlace`): launchd and systemd open stillfail.log for
// the launcher, the front and Node with O_APPEND (cloud/src/install.ts; launchd's `R,W,AP` as lsof shows it), and the
// launcher passes it on across every update's execv. Renamed or unlinked, all of them would write on into a file no name
// reaches until the disk is full: so the file is copied and cut to nothing, its inode the same, and every writer's next
// write lands at its new end (an O_APPEND write goes to the end the file has then).
import { Clock } from "effect";
import { type Dirent } from "node:fs";
import { lstat, open, readdir, readFile, realpath, rename, rm, stat, statfs, truncate } from "node:fs/promises";
import { isAbsolute, join, relative, sep } from "node:path";
import { Fibers } from "./fibers.ts";
import { clean, inside, within } from "./paths.ts";
import { walkBounded } from "./walk.ts";
import { log } from "./log.ts";
import { collectWorktreeRegistrations, removeWorktreeRegistrations, unlockWorktrees } from "../sessions/archive.ts";

const MiB = 1024 ** 2;
const HOUR = 3600_000;
const DAY = 24 * HOUR;

export type StorageClass = "authoritative" | "session-bound" | "bounded-ephemeral";

export type StorageEntry = {
  /// The top-level name; `*` stands for any run of characters (`config.json.bak-*`).
  name: string;
  class: StorageClass;
  /// What it is.
  what: string;
  /// Its bound, for a bounded one: in bytes (the whole entry), in age (each item in it), or both.
  maxBytes?: number;
  maxAgeMs?: number;
  /// What holds it to that bound (or removes it with its session).
  reclaim?: string;
};

/// The station's log (stderr and stdout of the launcher, the front and Node, as launchd and systemd append them).
export const STATION_LOG_CAP = 64 * MiB;
/// What the installer of an update says (run/update.log).
export const UPDATE_LOG_CAP = 16 * MiB;
/// A job's log, while it runs and after (jobs/jobs.ts `capLogs`).
export const JOB_LOG_CAP = 64 * MiB;
/// The database's log (the WAL) past which it is written into the database waiting for the readers (`walCheckpoint`).
export const WAL_CAP = 128 * MiB;
/// The thumbnails, all together.
export const THUMBS_CAP = 512 * MiB;
/// How many of config.json's copies of before (`config.json.bak-*`) are kept.
export const CONFIG_BACKUPS_KEPT = 3;
/// A download of Node half done (node/.part-*) older than this is left over.
export const NODE_PART_MS = DAY;
/// A file of a draft of 待派发 started or deleted is put aside (board-files/<person>/.gone, sessions/board-drafts.ts),
/// for the device starting it to still send it, so long.
export const BOARD_FILES_GONE_MS = DAY;
/// An orphaned session directory under `<data>/sessions/<connect>/<room>` with no session row and no active job
/// older than this is removed by Upkeep (well past any new-session or handover-in creation window).
export const ORPHAN_ROOM_MS = DAY;
/// An orphaned Claude or Codex transcript under `<data>` unreferenced by any session row (including archived)
/// older than this is removed by Upkeep.
export const ORPHAN_TRANSCRIPT_MS = 3 * DAY;
/// Per-round caps for orphan cleanup in Upkeep.
export const ORPHAN_ROOM_MAX_PER_ROUND = 32;
export const ORPHAN_TRANSCRIPT_MAX_PER_ROUND = 64;
export const ORPHAN_WALK_MAX_ENTRIES = 10_000;
export const ORPHAN_WALK_MAX_MS = 10_000;
/// How often the upkeep runs, and how long after the station starts it first does.
export const UPKEEP_EVERY_MS = 10 * 60_000;
export const UPKEEP_FIRST_MS = 2 * 60_000;

export const STORAGE_MANIFEST: readonly StorageEntry[] = [
  // The database, its log and its shared memory: the WAL is held to WAL_CAP by `walCheckpoint`.
  { name: "stillfail.db", class: "authoritative", what: "everything lasting (store/store.ts)" },
  { name: "stillfail.db-wal", class: "bounded-ephemeral", what: "the database's log", maxBytes: WAL_CAP, reclaim: "Upkeep walCheckpoint" },
  { name: "stillfail.db-shm", class: "bounded-ephemeral", what: "the database's shared memory index (SQLite's, a few MB)", maxBytes: 64 * MiB, reclaim: "SQLite" },
  { name: "stillfail.log", class: "bounded-ephemeral", what: "the station's log (launchd, systemd)", maxBytes: STATION_LOG_CAP, reclaim: "Upkeep rotateInPlace" },
  { name: "stillfail.log.1", class: "bounded-ephemeral", what: "the station's log before its last cut", maxBytes: STATION_LOG_CAP, reclaim: "Upkeep rotateInPlace" },
  { name: "stillfail.log.1.tmp", class: "bounded-ephemeral", what: "a cut of the log being written", maxBytes: STATION_LOG_CAP, reclaim: "Upkeep rotateInPlace" },
  { name: "config.json", class: "authoritative", what: "the station's settings" },
  { name: "config.json.bak-*", class: "bounded-ephemeral", what: "settings as they were before a change", reclaim: `Upkeep: the newest ${CONFIG_BACKUPS_KEPT} kept` },
  { name: "presence.json", class: "bounded-ephemeral", what: "whether the station is online (older stations)", maxBytes: MiB },
  { name: "model-catalog.json", class: "bounded-ephemeral", what: "the models' catalog as last read", maxBytes: 16 * MiB },
  { name: "repo-index.json", class: "bounded-ephemeral", what: "the repositories found on the machine", maxBytes: 64 * MiB },
  { name: "remote-connects.json", class: "authoritative", what: "connects of other stations (connects/keys.ts)" },
  { name: "comma-tasks.json", class: "authoritative", what: "Comma's tasks" },
  { name: "comma-stats.db", class: "authoritative", what: "Comma's statistics" },
  { name: "comma-stats.db-*", class: "authoritative", what: "Comma's statistics' log and shared memory" },
  { name: "comma-indexes", class: "authoritative", what: "Comma's indexes" },
  { name: "feishu-threads.json", class: "authoritative", what: "Feishu's threads" },
  { name: "feishu-registrations.json", class: "authoritative", what: "Feishu's registrations" },
  { name: "group-threads.json", class: "authoritative", what: "what the group connects heard of their IM servers" },
  { name: "windows.json", class: "authoritative", what: "Windows' install settings" },
  { name: "uninstalled", class: "authoritative", what: "taken away here, its data kept (stillfail uninstall, the app's 卸载本机 Station; an install removes it)" },
  { name: "drive-grant.key", class: "authoritative", what: "the drive's grant key" },
  // Programs and runtimes: replaced as they are updated.
  { name: "app", class: "authoritative", what: "the station's release" },
  { name: "node", class: "authoritative", what: "the station's Node (its half-done downloads, .part-*, held by Upkeep)", maxAgeMs: NODE_PART_MS, reclaim: "Upkeep staleNodeParts" },
  { name: "bin", class: "authoritative", what: "commands installed for the station" },
  { name: "ca", class: "authoritative", what: "certificates the station trusts" },
  { name: "runtimes", class: "authoritative", what: "agent runtimes installed by the station" },
  { name: "screen-tools", class: "authoritative", what: "tools a screen needs (Linux)" },
  { name: "helper", class: "authoritative", what: "still.fail Helper" },
  { name: "browser", class: "authoritative", what: "the station's own Chrome profiles (sign-ins)" },
  { name: "shells", class: "authoritative", what: "the agents' shells' settings" },
  { name: "shell", class: "authoritative", what: "the agents' shell's settings" },
  // What is a person's, or the workspace's.
  { name: "transcripts", class: "authoritative", what: "the agents' transcripts", reclaim: "sessions/lifecycle.ts deleteSession (exclusive), Upkeep pruneOrphanTranscripts" },
  { name: "transcripts-segmented", class: "authoritative", what: "transcripts put away in segments (sessions/cold.ts)" },
  { name: "sessions", class: "session-bound", what: "each chat's workspace", reclaim: "sessions/lifecycle.ts expireArchived, packUnfinishedArchived, cleanIdleRebuildable, relieveIdleRebuildable, relieveArchived; Upkeep pruneOrphanRooms" },
  { name: "archive", class: "authoritative", what: "chats put away (store/archive.ts)" },
  { name: "uploads", class: "authoritative", what: "files sent in chats" },
  { name: "board-files", class: "authoritative", what: "the files of people's drafts of 待派发 (sessions/board-drafts.ts; those of a draft started or deleted, .gone, a day more, held by Upkeep)", maxAgeMs: BOARD_FILES_GONE_MS, reclaim: "Upkeep goneBoardFiles" },
  { name: "homes", class: "authoritative", what: "the runtimes' homes (accounts' sign-ins, their settings)", reclaim: "sessions/lifecycle.ts deleteSession (exclusive transcripts), Upkeep pruneOrphanTranscripts" },
  { name: "repos", class: "session-bound", what: "the repositories' shared clones", reclaim: "sessions/lifecycle.ts relieveRepos (low disk only)" },
  { name: "agent", class: "authoritative", what: "the agents' memory and skills" },
  { name: "share", class: "authoritative", what: "the memory's versions shared between stations" },
  { name: "xshare", class: "authoritative", what: "chats shared with other workspaces" },
  { name: "mesh", class: "authoritative", what: "the station's key and what the cloud said" },
  { name: "vault", class: "authoritative", what: "the vault's state" },
  { name: "logins", class: "authoritative", what: "logins in progress and kept" },
  { name: "replica", class: "authoritative", what: "this station's copies off the machine (replica/)" },
  { name: "replicas", class: "authoritative", what: "other stations' copies kept here (replica/)" },
  { name: "restore", class: "authoritative", what: "a lost station's copy being taken back" },
  { name: "rig", class: "authoritative", what: "a station that only runs tasks: its grants" },
  { name: "move", class: "session-bound", what: "items moving to or from another station (move/)", reclaim: "move/" },
  { name: "drive-transfers", class: "session-bound", what: "the drive's transfers", reclaim: "drive/" },
  { name: "workspace-limits", class: "authoritative", what: "sizes of the workspaces measured" },
  { name: "resources", class: "bounded-ephemeral", what: "resource samples", maxBytes: 64 * MiB },
  { name: "Trash", class: "authoritative", what: "files the drive put in the trash" },
  // Process state and logs.
  { name: "run", class: "bounded-ephemeral", what: "what runs (runners, pids, sockets, the update's log)", reclaim: "Upkeep: runner sweep, update.log cut" },
  { name: "jobs", class: "bounded-ephemeral", what: "jobs' logs and exit files", maxAgeMs: 14 * DAY, reclaim: "jobs/jobs.ts capLogs, collect" },
  { name: "remote", class: "session-bound", what: "other stations' tasks here and tasks started from here", reclaim: "jobs/remote.ts sweep, relieve, budget, expire" },
  { name: "thumbs", class: "bounded-ephemeral", what: "thumbnails of images", maxBytes: THUMBS_CAP, reclaim: "Upkeep capByAge" },
  { name: "transcript-marks", class: "bounded-ephemeral", what: "where transcripts' entries are (read/transcripts.ts)", reclaim: "Upkeep orphanMarks" },
];

/// The manifest's entry for a top-level name, if it has one.
export function storageEntry(name: string): StorageEntry | undefined {
  return STORAGE_MANIFEST.find((e) => (e.name.includes("*") ? globRegExp(e.name).test(name) : e.name === name));
}

const globRegExp = (glob: string) => new RegExp(`^${glob.split("*").map((p) => p.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*")}$`);

/// How much of the disk a tree takes (its blocks), off the thread, as ops/walk.ts `walkBounded` walks it (on its root's
/// disk, no link followed); `partial` where the walk was cut short (past `most` entries, or its time).
export async function treeBytes(path: string, most = 1_000_000): Promise<{ bytes: number; entries: number; partial: boolean }> {
  let bytes = 0;
  const walked = await walkBounded(path, (e) => {
    if (e.stats !== null) bytes += used({ blocks: Number(e.stats.blocks), size: Number(e.stats.size) });
  }, { stat: true, maxEntries: most, maxDepth: 256, maxDurationMs: 60_000 });
  return { bytes, entries: walked.visited, partial: walked.truncated };
}

/// What a file takes on the disk: its blocks where the system says them (a runner's output given back is sparse).
const used = (st: { blocks?: number; size: number }) => (typeof st.blocks === "number" && st.blocks >= 0 ? st.blocks * 512 : st.size);

/// How much a cut copies at a time.
const COPY_CHUNK = MiB;

/// A log other processes append to, cut where it is once past `cap`: its last `keep` bytes (at most) copied to
/// `<path>.1` (through `<path>.1.tmp`, renamed over the one before), then the file truncated to nothing, its inode the
/// same. What a writer holding it open with O_APPEND writes next lands at the start; what it wrote between the copy and
/// the cut is copied too as far as it came before the cut. So the log takes at most twice its cap. Whether it was cut.
export async function rotateInPlace(path: string, cap: number, keep = cap): Promise<boolean> {
  let size: number;
  try {
    size = (await stat(path)).size;
  } catch {
    return false;
  }
  if (size <= cap) return false;
  const tmp = `${path}.1.tmp`;
  const from = await open(path, "r");
  try {
    const to = await open(tmp, "w", 0o600);
    try {
      const buf = Buffer.allocUnsafe(COPY_CHUNK);
      let at = Math.max(0, size - keep);
      // To where it is now, then once more to what came while it was copied.
      for (let pass = 0; pass < 2; pass++) {
        while (at < size) {
          const { bytesRead } = await from.read(buf, 0, Math.min(buf.length, size - at), at);
          if (bytesRead <= 0) break;
          await to.write(buf, 0, bytesRead);
          at += bytesRead;
        }
        size = (await from.stat()).size;
      }
    } finally {
      await to.close();
    }
    await rename(tmp, `${path}.1`);
    await truncate(path, 0);
  } catch (error) {
    await rm(tmp, { force: true }).catch(() => undefined);
    throw error;
  } finally {
    await from.close();
  }
  return true;
}

/// Of the files in `dir` whose names start with `prefix`, all but the `kept` newest removed (by their mtime): the names
/// removed.
export async function keepNewest(dir: string, prefix: string, kept: number): Promise<string[]> {
  const names = (await readdir(dir).catch(() => [] as string[])).filter((n) => n.startsWith(prefix));
  const dated = await Promise.all(names.map(async (n) => ({ n, at: (await stat(join(dir, n)).catch(() => null))?.mtimeMs ?? 0 })));
  dated.sort((a, b) => b.at - a.at);
  const gone = dated.slice(kept).map((d) => d.n);
  for (const n of gone) await rm(join(dir, n), { recursive: true, force: true }).catch(() => undefined);
  return gone;
}

/// What in `dir` starts with `prefix` and has not changed for `maxAgeMs` before `now`, removed: the names removed.
export async function removeStale(dir: string, prefix: string, maxAgeMs: number, now: number): Promise<string[]> {
  const gone: string[] = [];
  for (const n of await readdir(dir).catch(() => [] as string[])) {
    if (!n.startsWith(prefix)) continue;
    const st = await lstat(join(dir, n)).catch(() => null);
    if (st === null || now - st.mtimeMs < maxAgeMs) continue;
    await rm(join(dir, n), { recursive: true, force: true }).catch(() => undefined);
    gone.push(n);
  }
  return gone;
}

/// The files of drafts of 待派发 started or deleted (`dir` is board-files: <person>/.gone/<draft>/<file>,
/// sessions/board-drafts.ts) put aside `maxAgeMs` or longer before `now`, removed, and a draft's folder left empty: the
/// files removed, as <person>/<draft>/<file>. What a person's next carry would drop, held to its bound though they never
/// come back.
export async function goneBoardFiles(dir: string, maxAgeMs: number, now: number): Promise<string[]> {
  const gone: string[] = [];
  for (const person of await readdir(dir).catch(() => [] as string[])) {
    const aside = join(dir, person, ".gone");
    for (const draft of await readdir(aside).catch(() => [] as string[])) {
      const files = await readdir(join(aside, draft)).catch(() => null);
      if (files === null) continue;
      let left = files.length;
      for (const f of files) {
        const st = await lstat(join(aside, draft, f)).catch(() => null);
        if (st === null || now - st.mtimeMs < maxAgeMs) continue;
        await rm(join(aside, draft, f), { recursive: true, force: true }).catch(() => undefined);
        gone.push(`${person}/${draft}/${f}`);
        left--;
      }
      if (left === 0) await rm(join(aside, draft), { recursive: true, force: true }).catch(() => undefined);
    }
  }
  return gone.sort();
}

/// The files of `dir` (not its directories) taken down to `maxBytes` together, the longest unchanged first: a cache
/// whose items are made again when asked for (thumbs/). The bytes freed.
export async function capByAge(dir: string, maxBytes: number): Promise<number> {
  let names: Dirent[];
  try {
    names = await readdir(dir, { withFileTypes: true });
  } catch {
    return 0;
  }
  const files: { path: string; bytes: number; at: number }[] = [];
  for (const d of names) {
    if (!d.isFile()) continue;
    const path = join(dir, d.name);
    const st = await lstat(path).catch(() => null);
    if (st !== null) files.push({ path, bytes: used(st), at: st.mtimeMs });
  }
  let total = files.reduce((n, f) => n + f.bytes, 0);
  if (total <= maxBytes) return 0;
  files.sort((a, b) => a.at - b.at);
  let freed = 0;
  for (const f of files) {
    if (total <= maxBytes) break;
    await rm(f.path, { force: true }).catch(() => undefined);
    total -= f.bytes;
    freed += f.bytes;
  }
  return freed;
}

/// The readings kept of transcripts (transcript-marks/, read/transcripts.ts) whose transcript is gone, removed; and those
/// that do not read. The names removed.
export async function orphanMarks(dir: string): Promise<string[]> {
  const gone: string[] = [];
  for (const n of await readdir(dir).catch(() => [] as string[])) {
    if (!n.endsWith(".json")) continue;
    const file = join(dir, n);
    let path: unknown;
    try {
      path = JSON.parse(await readFile(file, "utf8"))?.state?.path;
    } catch {
      path = null;
    }
    const there = typeof path === "string" && (await stat(path).then(() => true, () => false));
    if (there) continue;
    await rm(file, { force: true }).catch(() => undefined);
    gone.push(n);
  }
  return gone;
}

/// Removes stale, unlocked git worktree registrations in `<data>/repos/*/.git/worktrees/*`
/// whose literal `gitdir` target lies under `<data>/sessions` and no longer exists.
export async function pruneRepoWorktrees(data: string): Promise<string[]> {
  const realRepos = await realpath(join(data, "repos")).catch(() => null);
  if (realRepos === null) return [];
  const rawSessions = clean(join(data, "sessions"));
  const realSessions = await realpath(join(data, "sessions")).catch(() => null);
  const gone: string[] = [];
  for (const repoName of await readdir(realRepos).catch(() => [] as string[])) {
    if (repoName.startsWith(".")) continue;
    const repoPath = join(realRepos, repoName);
    const repoSt = await lstat(repoPath).catch(() => null);
    if (repoSt === null || !repoSt.isDirectory() || repoSt.isSymbolicLink()) continue;
    const wtRoot = join(repoPath, ".git", "worktrees");
    const wtRootSt = await lstat(wtRoot).catch(() => null);
    if (wtRootSt === null || !wtRootSt.isDirectory() || wtRootSt.isSymbolicLink()) continue;
    for (const wtName of await readdir(wtRoot).catch(() => [] as string[])) {
      const adminDir = join(wtRoot, wtName);
      const adminSt = await lstat(adminDir).catch(() => null);
      if (adminSt === null || !adminSt.isDirectory() || adminSt.isSymbolicLink()) continue;
      if (await lstat(join(adminDir, "locked")).then(() => true, () => false)) continue;
      const rawTarget = (await readFile(join(adminDir, "gitdir"), "utf8").catch(() => "")).trim();
      if (rawTarget === "" || !isAbsolute(rawTarget)) continue;
      const target = clean(rawTarget);
      const underSessions = inside(target, rawSessions) || (realSessions !== null && inside(target, realSessions));
      if (!underSessions) continue;
      if (await lstat(target).then(() => true, () => false)) continue;
      const removed = await rm(adminDir, { recursive: true, force: true }).then(() => true, () => false);
      if (removed) gone.push(`${repoName}/${wtName}`);
    }
  }
  return gone;
}

/// How the disk of `path` stands: free for the station, and its whole size.
export async function diskOf(path: string): Promise<{ free: number; total: number }> {
  const st = await statfs(path);
  return { free: st.bavail * st.bsize, total: st.blocks * st.bsize };
}

export type OrphanStore = {
  sessionPathsPage(afterKey: string, limit?: number): { key: string; workspace: string; cwd: string | null; archivedAt: number | null }[];
  jobsUp(): { cwd: string }[];
  transcriptReferenced(runtime: string, id: string, except: string): boolean;
};

/// Whether any incoming handover (`<data>/replica/handover/in/*.json`) is currently in the `coming` state
/// (files may already be placed under `<data>/sessions` before rows are inserted).
async function hasIncomingHandover(data: string): Promise<boolean> {
  const inDir = join(data, "replica", "handover", "in");
  for (const name of await readdir(inDir).catch(() => [] as string[])) {
    if (!name.endsWith(".json")) continue;
    try {
      const parsed = JSON.parse(await readFile(join(inDir, name), "utf8"));
      if (parsed?.step === "coming") return true;
    } catch {
      return true;
    }
  }
  return false;
}

/// Removes orphaned session directories `<data>/sessions/<connect>/<room>` that have no session row's workspace inside,
/// no active job's cwd inside, and are older than `minAgeMs` (default ORPHAN_ROOM_MS = 24h). Cleans any linked git
/// worktree registrations before removing the room. Only real directories are traversed (no symlinks followed).
export async function pruneOrphanRooms(
  data: string,
  now: number,
  store: OrphanStore,
  options?: { minAgeMs?: number; limit?: number; maxDurationMs?: number },
): Promise<string[]> {
  const minAgeMs = options?.minAgeMs ?? ORPHAN_ROOM_MS;
  const limit = options?.limit ?? ORPHAN_ROOM_MAX_PER_ROUND;
  const maxDurationMs = options?.maxDurationMs ?? ORPHAN_WALK_MAX_MS;
  if (limit <= 0) return [];
  if (await hasIncomingHandover(data)) return [];
  const rawSessions = clean(join(data, "sessions"));
  const realSessions = await realpath(rawSessions).catch(() => null);
  if (realSessions === null) return [];

  const refs = new Set<string>();
  const addRef = async (p: string | null | undefined) => {
    if (!p) return;
    refs.add(clean(p));
    const r = await realpath(p).catch(() => null);
    if (r !== null) refs.add(r);
  };
  try {
    let afterKey = "";
    for (;;) {
      const page = store.sessionPathsPage(afterKey);
      for (const s of page) await addRef(s.workspace);
      if (page.length === 0) break;
      afterKey = page[page.length - 1]!.key;
      await new Promise<void>((resolve) => setImmediate(resolve));
    }
    for (const job of store.jobsUp()) await addRef(job.cwd);
  } catch {
    return [];
  }

  const deadline = Date.now() + maxDurationMs;
  const gone: string[] = [];
  for (const connect of await readdir(realSessions).catch(() => [] as string[])) {
    if (gone.length >= limit || Date.now() >= deadline) break;
    if (connect.startsWith(".")) continue;
    const connectPath = join(realSessions, connect);
    const connectSt = await lstat(connectPath).catch(() => null);
    if (connectSt === null || !connectSt.isDirectory() || connectSt.isSymbolicLink()) continue;
    for (const room of await readdir(connectPath).catch(() => [] as string[])) {
      if (gone.length >= limit || Date.now() >= deadline) break;
      if (room.startsWith(".")) continue;
      const roomPath = join(connectPath, room);
      const rawRoomPath = join(rawSessions, connect, room);
      const roomSt = await lstat(roomPath).catch(() => null);
      if (roomSt === null || !roomSt.isDirectory() || roomSt.isSymbolicLink()) continue;
      const wsSt = await lstat(join(roomPath, "workspace")).catch(() => null);
      const mtimeMs = Math.max(roomSt.mtimeMs, wsSt?.mtimeMs ?? 0);
      if (now - mtimeMs < minAgeMs) continue;
      let referenced = false;
      for (const ref of refs) {
        if (within(ref, roomPath) || within(ref, rawRoomPath)) {
          referenced = true;
          break;
        }
      }
      if (referenced) continue;
      const worktrees = await collectWorktreeRegistrations(roomPath).catch(() => []);
      await unlockWorktrees(roomPath).catch(() => undefined);
      const removed = await rm(roomPath, { recursive: true, force: true }).then(() => true, () => false);
      if (removed) {
        if (worktrees.length > 0) await removeWorktreeRegistrations(worktrees, [roomPath, rawRoomPath]).catch(() => undefined);
        gone.push(`${connect}/${room}`);
      }
    }
  }
  return gone;
}

const CODEX_ROLLOUT_RE = /(?:^|-)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl(?:\.zst)?$/i;

function claudeTranscriptId(fileName: string): string | null {
  const base = fileName.endsWith(".zst") ? fileName.slice(0, -4) : fileName;
  if (!base.endsWith(".jsonl")) return null;
  const stem = base.slice(0, -6);
  return stem.length > 0 && !stem.includes("/") && !stem.includes("\\") ? stem : null;
}

function codexTranscriptId(fileName: string): string | null {
  const m = CODEX_ROLLOUT_RE.exec(fileName);
  return m ? m[1]! : null;
}

const otherRuntimesLogged = new Set<string>();

/// Removes orphaned Claude (`projects/<proj>/<id>.jsonl(.zst)` + `<id>/`) and Codex (`-<uuid>.jsonl(.zst)`)
/// transcripts whose realpath is under `<data>` (`<data>/transcripts` and `<data>/homes/*`), unreferenced by any
/// session row (including archived) in `runtime_sessions`/`sessions`, and older than `minAgeMs` (default 3 days).
/// Other runtimes are left untouched and counted once in `log.info` on the first round.
export async function pruneOrphanTranscripts(
  data: string,
  now: number,
  store: OrphanStore,
  options?: { minAgeMs?: number; limit?: number; maxEntries?: number; maxDurationMs?: number; logOtherOnce?: boolean },
): Promise<string[]> {
  const minAgeMs = options?.minAgeMs ?? ORPHAN_TRANSCRIPT_MS;
  const limit = options?.limit ?? ORPHAN_TRANSCRIPT_MAX_PER_ROUND;
  const maxEntries = options?.maxEntries ?? ORPHAN_WALK_MAX_ENTRIES;
  const maxDurationMs = options?.maxDurationMs ?? ORPHAN_WALK_MAX_MS;
  if (limit <= 0) return [];
  const realData = await realpath(data).catch(() => null);
  if (realData === null) return [];

  const deadline = Date.now() + maxDurationMs;
  const gone: string[] = [];
  const otherCounts: Record<string, number> = {};
  const shouldLogOther = (options?.logOtherOnce ?? true) && !otherRuntimesLogged.has(realData);

  const claudeRoots: string[] = [];
  const codexRoots: string[] = [];
  const otherRoots: [string, string][] = [];

  const transcriptsDir = join(realData, "transcripts");
  for (const name of await readdir(transcriptsDir).catch(() => [] as string[])) {
    if (name.startsWith(".")) continue;
    const p = join(transcriptsDir, name);
    const st = await lstat(p).catch(() => null);
    if (st === null || !st.isDirectory() || st.isSymbolicLink()) continue;
    if (name === "claude") claudeRoots.push(p);
    else if (name === "codex") codexRoots.push(p);
    else if (shouldLogOther) otherRoots.push([name, p]);
  }

  const homesDir = join(realData, "homes");
  for (const homeName of await readdir(homesDir).catch(() => [] as string[])) {
    if (homeName.startsWith(".")) continue;
    const homePath = join(homesDir, homeName);
    const homeSt = await lstat(homePath).catch(() => null);
    if (homeSt === null || !homeSt.isDirectory() || homeSt.isSymbolicLink()) continue;
    const realHome = await realpath(homePath).catch(() => null);
    if (realHome === null || !inside(realHome, realData)) continue;
    const proj = join(realHome, "projects");
    const projSt = await lstat(proj).catch(() => null);
    if (projSt !== null && projSt.isDirectory() && !projSt.isSymbolicLink()) claudeRoots.push(proj);
    const sess = join(realHome, "sessions");
    const sessSt = await lstat(sess).catch(() => null);
    if (sessSt !== null && sessSt.isDirectory() && !sessSt.isSymbolicLink()) codexRoots.push(sess);
  }

  const safeInsideData = async (p: string): Promise<boolean> => {
    const st = await lstat(p).catch(() => null);
    if (st === null || st.isSymbolicLink()) return false;
    const r = await realpath(p).catch(() => null);
    return r !== null && inside(r, realData);
  };

  // 1. Claude roots: <root>/<proj>/<id>.jsonl(.zst) and companion <root>/<proj>/<id>/
  for (const root of claudeRoots) {
    if (gone.length >= limit || Date.now() >= deadline) break;
    const candidates: { path: string; id: string; isDir: boolean; mtimeMs: number }[] = [];
    await walkBounded(
      root,
      (e) => {
        if (e.depth !== 2 || e.stats === null || e.symlink) return;
        const name = e.name;
        const mtimeMs = Number(e.stats.mtimeMs);
        if (e.file) {
          const id = claudeTranscriptId(name);
          if (id !== null) candidates.push({ path: e.path, id, isDir: false, mtimeMs });
        } else if (e.directory && !name.startsWith(".")) {
          candidates.push({ path: e.path, id: name, isDir: true, mtimeMs });
        }
      },
      { maxDepth: 2, maxEntries, maxDurationMs: Math.max(100, deadline - Date.now()), stat: true },
    );
    for (const c of candidates) {
      if (gone.length >= limit || Date.now() >= deadline) break;
      if (now - c.mtimeMs < minAgeMs) continue;
      let referenced = true;
      try {
        referenced = store.transcriptReferenced("claude", c.id, "");
      } catch {
        return gone;
      }
      if (referenced) continue;
      if (!(await safeInsideData(c.path))) continue;
      const removed = await rm(c.path, { recursive: c.isDir, force: true }).then(() => true, () => false);
      if (removed) {
        gone.push(relative(realData, c.path));
        if (!c.isDir) {
          const compDir = join(c.path.slice(0, c.path.lastIndexOf(sep)), c.id);
          const compSt = await lstat(compDir).catch(() => null);
          if (compSt !== null && compSt.isDirectory() && !compSt.isSymbolicLink() && now - compSt.mtimeMs >= minAgeMs && (await safeInsideData(compDir))) {
            await rm(compDir, { recursive: true, force: true }).catch(() => undefined);
          }
        }
      }
    }
  }

  // 2. Codex roots: <root>/.../*-<uuid>.jsonl(.zst)
  for (const root of codexRoots) {
    if (gone.length >= limit || Date.now() >= deadline) break;
    const candidates: { path: string; id: string; mtimeMs: number }[] = [];
    await walkBounded(
      root,
      (e) => {
        if (!e.file || e.stats === null || e.symlink) return;
        const id = codexTranscriptId(e.name);
        if (id !== null) candidates.push({ path: e.path, id, mtimeMs: Number(e.stats.mtimeMs) });
      },
      { maxDepth: 6, maxEntries, maxDurationMs: Math.max(100, deadline - Date.now()), stat: true },
    );
    for (const c of candidates) {
      if (gone.length >= limit || Date.now() >= deadline) break;
      if (now - c.mtimeMs < minAgeMs) continue;
      let referenced = true;
      try {
        referenced = store.transcriptReferenced("codex", c.id, "");
      } catch {
        return gone;
      }
      if (referenced) continue;
      if (!(await safeInsideData(c.path))) continue;
      const removed = await rm(c.path, { force: true }).then(() => true, () => false);
      if (removed) gone.push(relative(realData, c.path));
    }
  }

  // 3. Other runtimes: untouched, log count once on first round.
  if (shouldLogOther) {
    otherRuntimesLogged.add(realData);
    for (const [runtime, root] of otherRoots) {
      let count = 0;
      await walkBounded(
        root,
        (e) => {
          if (e.file) count++;
        },
        { maxDepth: 6, maxEntries: 2_000, maxDurationMs: 2_000 },
      );
      if (count > 0) otherCounts[runtime] = count;
    }
    if (Object.keys(otherCounts).length > 0) {
      log.info("upkeep", "skipped orphan transcript check for other runtimes", { counts: otherCounts });
    }
  }

  return gone;
}

/// What the upkeep is given of the station's parts (each optional: a station that only runs tasks has no transcripts).
export type UpkeepParts = {
  data: string;
  clock?: Clock.Clock;
  /// Runners left by processes gone (agents/runner.ts `sweepRunners`).
  runners?: (now: number) => Promise<unknown>;
  /// Jobs' logs held to their cap, and those of jobs long over or gone collected (jobs/jobs.ts).
  jobs?: (now: number) => Promise<unknown>;
  /// Other stations' tasks: their rooms held to their budget, their records long over removed (jobs/remote.ts).
  remote?: (now: number, disk: { free: number; total: number } | null) => Promise<unknown>;
  /// The database's log written into it waiting for the readers (read/pool.ts `checkpointHard`).
  checkpoint?: () => Promise<unknown>;
  /// Store queries for pruning orphan session rooms and orphan transcripts under `<data>`.
  orphans?: OrphanStore;
};

/// The station's own files held to their bounds (the manifest's `reclaim`): every UPKEEP_EVERY_MS (`timer: a sample
/// of this machine`: its disk tells nothing as it fills), the first UPKEEP_FIRST_MS after it starts.
export class Upkeep {
  readonly #parts: UpkeepParts;
  readonly #time: Fibers;
  #running: Promise<void> | null = null;

  constructor(parts: UpkeepParts) {
    this.#parts = parts;
    this.#time = new Fibers("upkeep", parts.clock);
  }

  start(): void {
    const again = () => {
      this.#time.after(UPKEEP_EVERY_MS, async () => { // timer: a sample of this machine (its disk)
        await this.run();
        again();
      });
    };
    this.#time.after(UPKEEP_FIRST_MS, async () => { // timer: a sample of this machine (its disk)
      await this.run();
      again();
    });
  }

  /// One round of it; one at a time.
  run(): Promise<void> {
    this.#running ??= this.#round().finally(() => (this.#running = null));
    return this.#running;
  }

  /// What is made again when asked for, let go of sooner: the disk is getting full (ops/disk.ts `diskTier`).
  async renewables(now: number): Promise<void> {
    const { data } = this.#parts;
    await this.#step("thumbs", () => capByAge(join(data, "thumbs"), THUMBS_CAP / 4));
    await this.#step("node parts", () => removeStale(join(data, "node"), ".part-", HOUR, now));
    await this.#step("config backups", () => keepNewest(data, "config.json.bak-", CONFIG_BACKUPS_KEPT));
    await this.#step("transcript marks", () => orphanMarks(join(data, "transcript-marks")));
  }

  async #round(): Promise<void> {
    const { data, runners, jobs, remote, checkpoint } = this.#parts;
    const now = this.#time.now();
    await this.#step("station log", () => rotateInPlace(join(data, "stillfail.log"), STATION_LOG_CAP));
    await this.#step("update log", () => rotateInPlace(join(data, "run", "update.log"), UPDATE_LOG_CAP));
    if (runners) await this.#step("runners", () => runners(now));
    if (jobs) await this.#step("jobs", () => jobs(now));
    if (remote) {
      const disk = await diskOf(data).catch(() => null);
      await this.#step("remote", () => remote(now, disk));
    }
    if (checkpoint) await this.#step("database log", () => walCheckpoint(join(data, "stillfail.db-wal"), checkpoint));
    await this.#step("thumbs", () => capByAge(join(data, "thumbs"), THUMBS_CAP));
    await this.#step("node parts", () => removeStale(join(data, "node"), ".part-", NODE_PART_MS, now));
    await this.#step("config backups", () => keepNewest(data, "config.json.bak-", CONFIG_BACKUPS_KEPT));
    await this.#step("transcript marks", () => orphanMarks(join(data, "transcript-marks")));
    await this.#step("board files", () => goneBoardFiles(join(data, "board-files"), BOARD_FILES_GONE_MS, now));
    await this.#step("repo worktrees", () => pruneRepoWorktrees(data));
    if (this.#parts.orphans) {
      const store = this.#parts.orphans;
      await this.#step("orphan session rooms", () => pruneOrphanRooms(data, now, store));
      await this.#step("orphan transcripts", () => pruneOrphanTranscripts(data, now, store));
    }
  }

  async #step(what: string, f: () => Promise<unknown>): Promise<void> {
    try {
      const did = await f();
      if (did === true || (Array.isArray(did) && did.length > 0) || (typeof did === "number" && did > 0)) log.info("upkeep", "held to its bound", { what, did: Array.isArray(did) ? did.length : did });
    } catch (error) {
      log.warn("upkeep", "not held to its bound", { what, error: (error as Error).message });
    }
  }

  close(): Promise<void> {
    return this.#time.close();
  }
}

/// The database's log past WAL_CAP (a long read held its passive checkpoints back): written into the database once,
/// waiting a while for the readers (`checkpoint`), and said. Whether it was.
export async function walCheckpoint(wal: string, checkpoint: () => Promise<unknown>): Promise<boolean> {
  const before = (await stat(wal).catch(() => null))?.size ?? 0;
  if (before <= WAL_CAP) return false;
  const result = await checkpoint();
  const after = (await stat(wal).catch(() => null))?.size ?? 0;
  log.warn("upkeep", "the database's log grew past its bound: written into the database", { before, after, result: JSON.stringify(result) });
  return true;
}
