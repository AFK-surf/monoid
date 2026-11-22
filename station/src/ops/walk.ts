// A walk of a directory tree with hard limits, for every walk of the station's over a tree it does not own (a chat's
// workspace, the home, a directory mirrored to another station): a workspace can hold a million files of a build, a
// network share or a disk image mounted inside it, or links that lead back up, and an unbounded walk of one kept the
// station's thread and the disk busy for minutes. So a walk:
//
// - stays on its root's file system (`sameDevice`, on by default): a directory whose `dev` is not its root's is listed
//   but not gone into (a FUSE or NFS mount, a DMG, an external disk), told in `crossed`;
// - never follows a symbolic link (one is listed as itself), unless asked to (`followLinks`, for a tree whose folders
//   are linked in by design, as ~/.agents/skills): then each link is stat'ed once to what it names, and a directory
//   whose (dev, ino) the walk went into already is listed but not gone into again, so a link back up ends there;
// - stops at `maxEntries` entries, below `maxDepth` and after `maxDurationMs` (the wall's clock, or the caller's
//   `now`), and as `signal` aborts, saying so in `truncated` and `reason`: what was found so far is the caller's to
//   use as a lower bound, never a walk that does not end;
// - yields the event loop every `yieldEvery` entries (setImmediate), so what waits on the station's thread is not held
//   behind it.
//
// It goes breadth first, roots in their order, the nearest the top first (the search shows those first).
import type { BigIntStats, Dirent } from "node:fs";
import { lstat, readdir, stat } from "node:fs/promises";
import { basename, join } from "node:path";
import { wall } from "./fibers.ts";

export const WALK_MAX_ENTRIES = 50_000;
export const WALK_MAX_DEPTH = 32;
export const WALK_MAX_DURATION_MS = 15_000;
export const WALK_YIELD_EVERY = 256;

/// An entry as the walk reaches it: a root (depth 0) or what a directory listed.
export type WalkEntry = {
  path: string;
  /// Relative to its root, `/`-separated ("" for the root).
  rel: string;
  name: string;
  /// 0 for a root, 1 for what it lists, …
  depth: number;
  /// What it is, by its listing (a root's by its lstat).
  directory: boolean;
  symlink: boolean;
  file: boolean;
  /// Its lstat (bigint), where the walk was asked to stat every entry (`stat`); else none.
  stats: BigIntStats | null;
  /// The root it is under.
  root: string;
};

/// What a visit says of an entry: nothing (go on, into it where it is a directory), "skip" (not into it), "stop" (the
/// walk ends here, `reason` "stopped").
export type Visit = void | "skip" | "stop";

export type WalkOptions = {
  /// Not into a directory on another file system than its root's (default true).
  sameDevice?: boolean;
  maxEntries?: number;
  maxDepth?: number;
  maxDurationMs?: number;
  yieldEvery?: number;
  signal?: AbortSignal;
  /// The clock the duration is measured by (default the wall's).
  now?: () => number;
  /// Every entry lstat'ed (bigint) and given as `stats` (else only directories, where `sameDevice` asks).
  stat?: boolean;
  /// A root that is a symbolic link followed to what it names (default false: a link, listed as itself).
  followRoot?: boolean;
  /// Every symbolic link followed to what it names (default false), each real directory gone into once: an entry that
  /// is a link says `symlink`, and `directory` or `file` by its target (neither where its target is not there). Only a
  /// link is stat'ed for it, and a directory lstat'ed for its (dev, ino); a file is known by its listing.
  followLinks?: boolean;
  /// An error of the file system (`op`: what failed), ignored unless this throws, which ends the walk with it.
  onError?: (path: string, error: NodeJS.ErrnoException, op: "lstat" | "readdir" | "stat") => void;
  /// A directory not gone into for being on another file system.
  onCrossed?: (entry: WalkEntry) => void;
};

export type WalkResult = {
  /// Whether it ended before it reached everything under its roots (on its own file systems).
  truncated: boolean;
  /// Why: too many entries, too long, aborted, a visit's "stop", or (only) deeper than `maxDepth`.
  reason?: "entries" | "duration" | "aborted" | "stopped" | "depth";
  /// The entries visited, roots too.
  visited: number;
  /// Directories not gone into for being on another file system.
  crossed: number;
};

type Pending = { path: string; rel: string; depth: number; root: string; dev: bigint };

export const yieldLoop = () => new Promise<void>((resolve) => setImmediate(resolve));

/// Walks `roots` (one, or several in order), telling `visit` each entry, bounded as WalkOptions say.
export async function walkBounded(roots: string | readonly string[], visit: (entry: WalkEntry) => Visit | Promise<Visit>, options: WalkOptions = {}): Promise<WalkResult> {
  const now = options.now ?? (() => wall.now());
  const sameDevice = options.sameDevice ?? true;
  const maxEntries = options.maxEntries ?? WALK_MAX_ENTRIES;
  const maxDepth = options.maxDepth ?? WALK_MAX_DEPTH;
  const yieldEvery = Math.max(1, options.yieldEvery ?? WALK_YIELD_EVERY);
  const until = now() + (options.maxDurationMs ?? WALK_MAX_DURATION_MS);
  const signal = options.signal;
  const followLinks = options.followLinks ?? false;
  /// The directories gone into, by `dev:ino`, where links are followed.
  const into = new Set<string>();
  /// Whether a directory (its stats) is gone into for the first time, where links are followed (always otherwise).
  const first = (s: BigIntStats | null) => {
    if (!followLinks || s === null) return true;
    const key = `${s.dev}:${s.ino}`;
    if (into.has(key)) return false;
    into.add(key);
    return true;
  };
  const failed = (path: string, error: unknown, op: "lstat" | "readdir" | "stat") => options.onError?.(path, error as NodeJS.ErrnoException, op);
  let visited = 0;
  let crossed = 0;
  let deeper = false;
  const ended = (reason: NonNullable<WalkResult["reason"]>): WalkResult => ({ truncated: true, reason, visited, crossed });
  /// Why the walk must end before the next entry, if it must.
  const limit = (): WalkResult["reason"] | null => {
    if (signal?.aborted) return "aborted";
    if (visited >= maxEntries) return "entries";
    if (now() > until) return "duration";
    return null;
  };
  const tell = async (entry: WalkEntry): Promise<Visit> => {
    visited++;
    const said = await visit(entry);
    if (visited % yieldEvery === 0) await yieldLoop();
    return said;
  };

  const queue: Pending[] = [];
  let head = 0;
  for (const root of typeof roots === "string" ? [roots] : roots) {
    const why = limit();
    if (why) return ended(why);
    let meta: BigIntStats;
    try {
      meta = await lstat(root, { bigint: true });
      if (meta.isSymbolicLink() && options.followRoot) meta = await stat(root, { bigint: true });
    } catch (error) {
      failed(root, error, "lstat");
      continue;
    }
    const entry: WalkEntry = {
      path: root, rel: "", name: basename(root), depth: 0, directory: meta.isDirectory(), symlink: meta.isSymbolicLink(), file: meta.isFile(),
      stats: options.stat ? meta : null, root,
    };
    const said = await tell(entry);
    if (said === "stop") return ended("stopped");
    if (said !== "skip" && entry.directory && first(meta)) queue.push({ path: root, rel: "", depth: 0, root, dev: meta.dev });
  }

  while (head < queue.length) {
    const dir = queue[head]!;
    queue[head++] = undefined as unknown as Pending;
    const why = limit();
    if (why) return ended(why);
    let listed: Dirent[];
    try {
      listed = await readdir(dir.path, { withFileTypes: true });
    } catch (error) {
      failed(dir.path, error, "readdir");
      continue;
    }
    for (const d of listed) {
      const why = limit();
      if (why) return ended(why);
      const path = join(dir.path, d.name);
      const depth = dir.depth + 1;
      let stats: BigIntStats | null = null;
      if (options.stat || ((sameDevice || followLinks) && d.isDirectory())) {
        try {
          stats = await lstat(path, { bigint: true });
        } catch (error) {
          failed(path, error, "lstat");
          continue;
        }
      }
      const symlink = stats !== null ? stats.isSymbolicLink() : d.isSymbolicLink();
      // What a link names, where links are followed (null: it names nothing there).
      let target: BigIntStats | null = stats;
      if (followLinks && symlink) {
        try {
          target = await stat(path, { bigint: true });
        } catch (error) {
          failed(path, error, "stat");
          target = null;
        }
      }
      const followed = followLinks && symlink;
      const directory = followed ? target?.isDirectory() === true : stats !== null ? stats.isDirectory() : d.isDirectory();
      const entry: WalkEntry = {
        path, rel: dir.rel === "" ? d.name : `${dir.rel}/${d.name}`, name: d.name, depth, directory,
        symlink, file: followed ? target?.isFile() === true : stats !== null ? stats.isFile() : d.isFile(),
        stats: options.stat ? stats : null, root: dir.root,
      };
      const said = await tell(entry);
      if (said === "stop") return ended("stopped");
      if (said === "skip" || !directory) continue;
      if (sameDevice && target !== null && target.dev !== dir.dev) {
        crossed++;
        options.onCrossed?.(entry);
        continue;
      }
      if (depth >= maxDepth) {
        deeper = true;
        continue;
      }
      if (!first(target)) continue;
      queue.push({ path, rel: entry.rel, depth, root: dir.root, dev: dir.dev });
    }
  }
  return deeper ? ended("depth") : { truncated: false, visited, crossed };
}
