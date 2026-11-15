// Workspace file helpers for automatic cleanup of archived sessions.
import { execFile } from "node:child_process";
import { existsSync, lstatSync, realpathSync } from "node:fs";
import { realpath } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { fileName, samePath, segments, within } from "../ops/paths.ts";
import { walkBounded } from "../ops/walk.ts";

/// Path::starts_with: `path` is `dir` or under it.
export { within };

const canonical = (path: string): string | null => {
  try {
    return realpathSync(path);
  } catch {
    return null;
  }
};

/// Where a session's own directory is: the one its workspace is in when the station made it (sessions/…/workspace),
/// else none (a workspace that is a person's project is not the station's to measure or clean).
export function roomOf(dataDir: string, workspace: string): string | null {
  const sessions = canonical(join(dataDir, "sessions"));
  if (sessions === null) return null;
  return roomIn(sessions, canonical(workspace) ?? (fileName(workspace) === "workspace" ? beside(canonical(dirname(workspace))) : null));
}

/// `roomOf`, its paths followed off this thread.
export async function roomOfSoon(dataDir: string, workspace: string): Promise<string | null> {
  const real = (path: string) => realpath(path).catch(() => null);
  const sessions = await real(join(dataDir, "sessions"));
  if (sessions === null) return null;
  return roomIn(sessions, (await real(workspace)) ?? (fileName(workspace) === "workspace" ? beside(await real(dirname(workspace))) : null));
}

/// A workspace not there (yet, or any more) as it would be in its directory `parent` (followed), if that is there.
const beside = (parent: string | null) => (parent === null ? null : join(parent, "workspace"));

/// The room of the workspace at `path` (followed) under the station's sessions directory (followed).
function roomIn(sessions: string, path: string | null): string | null {
  if (path === null || !within(path, sessions) || samePath(path, sessions)) return null;
  // Only the station layout sessions/<connect>/<session>/workspace, never an arbitrary nested project.
  const relative = segments(path.slice(sessions.length)).filter((p) => p !== "");
  if (relative.length !== 3 || fileName(path) !== "workspace") return null;
  return dirname(path);
}

/// Whether a directory is one a build or an install makes again: node_modules, a Cargo target, a Gradle build and its
/// cache, Next's and Turbo's caches, Python's bytecode.
export function rebuildable(dir: string): boolean {
  const name = fileName(dir);
  if (name === null) return false;
  const beside = (file: string) => existsSync(join(dirname(dir), file));
  switch (name) {
    case "node_modules":
    case ".next":
    case ".turbo":
    case "__pycache__":
      return true;
    case "target":
      return beside("Cargo.toml");
    case ".gradle":
      return beside("settings.gradle") || beside("settings.gradle.kts") || beside("build.gradle") || beside("build.gradle.kts");
    case "build":
      return beside("build.gradle") || beside("build.gradle.kts");
    default:
      return false;
  }
}

/// Even a generated-looking directory may contain tracked source. If Git cannot inspect a repository, keep it.
/// Standalone generated directories (e.g. a screenshot script's node_modules) do not need a Git repository.
export async function safeToRemove(path: string): Promise<boolean> {
  let isDir = false;
  try {
    isDir = lstatSync(path).isDirectory();
  } catch {}
  if (!isDir || !rebuildable(path)) return false;
  const parent = dirname(path);
  let inRepo = false;
  for (let p = parent; ; p = dirname(p)) {
    if (existsSync(join(p, ".git"))) {
      inRepo = true;
      break;
    }
    if (dirname(p) === p) break;
  }
  if (!inRepo) return true;
  return new Promise((resolve) => {
    execFile("git", ["-C", parent, "ls-files", "--", basename(path)], { encoding: "buffer" }, (error, stdout) => {
      resolve(error === null && stdout.length === 0);
    });
  });
}

/// A chat's own directory (its session's workspace and what is beside it).
export type Room = {
  bytes: number;
  /// What can be made again, in it: directories and their sizes.
  rebuild: [string, number][];
};

export const rebuildBytes = (room: Room) => room.rebuild.reduce((sum, [, b]) => sum + b, 0);

/// Counts files once each however many links they have.
class Seen {
  private seen = new Set<string>();
  private total = 0;
  private readonly stopAfter: number | undefined;
  constructor(stopAfter?: number) { this.stopAfter = stopAfter; }
  bytes(meta: import("node:fs").BigIntStats): number {
    if (meta.nlink > 1n) {
      const id = `${meta.dev}:${meta.ino}`;
      if (this.seen.has(id)) return 0;
      this.seen.add(id);
    }
    const bytes = Number(meta.blocks) * 512;
    this.total += bytes;
    if (this.stopAfter !== undefined && this.total > this.stopAfter) throw new Enough(this.total);
    return bytes;
  }
}

/// Enough of a workspace was counted to know it exceeds its limit; more work is not needed for a warning.
class Enough {
  readonly bytes: number;
  constructor(bytes: number) { this.bytes = bytes; }
}

/// How far a measure goes: the walk's limits (ops/walk.ts), shared by the walks of the rebuildable directories in it.
export type MeasureBudget = { maxEntries?: number; maxDurationMs?: number; now?: () => number };
/// A workspace's size for its soft limit (measuredUpTo): enough for a warning, never minutes of the disk.
export const MEASURE_UP_TO: Required<Pick<MeasureBudget, "maxEntries" | "maxDurationMs">> = { maxEntries: 100_000, maxDurationMs: 15_000 };
/// A room measured for its cleanup (measureRoom, measured): what it finds past this is left for the next time.
export const MEASURE_ROOM: Required<Pick<MeasureBudget, "maxEntries" | "maxDurationMs">> = { maxEntries: 500_000, maxDurationMs: 60_000 };

/// What a measure found, and whether it reached everything (not cut short by its budget).
type Measured = { bytes: number; complete: boolean; reason?: string };

/// The size of `path` and everything under it, on its file system (ops/walk.ts walkBounded: links not followed, another
/// file system mounted in it not gone into, within `budget`). With `found`, directories that can be made again are listed
/// there (each counted whole, not looked into further for more); never in a `.git` or `uploads`.
async function measure(path: string, seen: Seen, found: [string, number][] | null, budget: MeasureBudget, signal?: AbortSignal, strict = false): Promise<Measured> {
  const now = budget.now ?? (() => wall.now());
  const until = now() + (budget.maxDurationMs ?? MEASURE_ROOM.maxDurationMs);
  const most = budget.maxEntries ?? MEASURE_ROOM.maxEntries;
  let visited = 0;
  let bytes = 0;
  let cut: string | undefined;
  const onError = strict ? (_: string, error: NodeJS.ErrnoException) => { if (error.code !== "ENOENT") throw error; } : undefined;
  const walk = async (root: string, finding: boolean): Promise<void> => {
    const walked = await walkBounded(root, async (entry) => {
      // (counted here, not by each walk: the walks of the rebuildable directories in it share the budget)
      if (++visited > most) {
        cut ??= "entries";
        return "stop";
      }
      if (finding && entry.depth > 0 && entry.directory) {
        // Never discover cleanup candidates in repository metadata or historical attachments.
        if (entry.name === ".git" || entry.name === "uploads") {
          await walk(entry.path, false);
          return cut !== undefined ? "stop" : "skip";
        }
        if (rebuildable(entry.path)) {
          const before = bytes;
          await walk(entry.path, false);
          found!.push([entry.path, bytes - before]);
          return cut !== undefined ? "stop" : "skip";
        }
      }
      bytes += seen.bytes(entry.stats!);
    }, { stat: true, maxEntries: Number.POSITIVE_INFINITY, maxDurationMs: Math.max(0, until - now()), now, signal, onError });
    if (walked.reason !== undefined && walked.reason !== "stopped") cut ??= walked.reason;
  };
  await walk(path, found !== null);
  signal?.throwIfAborted();
  return cut === undefined ? { bytes, complete: true } : { bytes, complete: false, reason: cut };
}

/// Measures one chat's directory again (after something in it was cleaned).
export async function measureRoom(dir: string, budget: MeasureBudget = MEASURE_ROOM): Promise<Room> {
  const rebuild: [string, number][] = [];
  const { bytes } = await measure(dir, new Seen(), rebuild, budget);
  return { bytes, rebuild };
}

/// The size of a path, each file once.
export const measured = async (path: string, signal?: AbortSignal, budget: MeasureBudget = MEASURE_ROOM) => (await measure(path, new Seen(), null, budget, signal)).bytes;

/// Count the whole path when it fits; once it exceeds `limit`, return a lower bound without traversing the rest. A
/// workspace too large or too slow to walk within `budget` (MEASURE_UP_TO) is a lower bound too, `truncated`.
export async function measuredUpTo(path: string, limit: number, signal?: AbortSignal, budget: MeasureBudget = MEASURE_UP_TO): Promise<{ bytes: number; complete: boolean; truncated?: true }> {
  try {
    const got = await measure(path, new Seen(limit), null, budget, signal, true);
    if (got.complete) return { bytes: got.bytes, complete: true };
    log.info("workspace-size", "workspace walk cut short", { path, bytes: got.bytes, reason: got.reason });
    return { bytes: got.bytes, complete: false, truncated: true };
  } catch (error) {
    if (error instanceof Enough) return { bytes: error.bytes, complete: false };
    throw error;
  }
}
