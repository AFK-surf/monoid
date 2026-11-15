// Workspace file helpers for automatic cleanup of archived sessions.
import { execFile } from "node:child_process";
import { realpathSync } from "node:fs";
import { lstat, realpath, stat } from "node:fs/promises";
import { basename, dirname, join, normalize, sep } from "node:path";
import { log } from "../ops/log.ts";
import { fileName, samePath, segments, within } from "../ops/paths.ts";
import { MbProcess, readerBinary } from "../read/mb-reader.ts";

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
/// cache, Next's and Turbo's caches, Python's bytecode. (The measure's own test of it is the program's, footprint.mbt
/// `rebuildable`.)
export async function rebuildable(dir: string): Promise<boolean> {
  const name = fileName(dir);
  if (name === null) return false;
  const beside = (file: string) => there(join(dirname(dir), file));
  switch (name) {
    case "node_modules":
    case ".next":
    case ".turbo":
    case "__pycache__":
      return true;
    case "target":
      return beside("Cargo.toml");
    case ".gradle":
      return (await beside("settings.gradle")) || (await beside("settings.gradle.kts")) || (await beside("build.gradle")) || beside("build.gradle.kts");
    case "build":
      return (await beside("build.gradle")) || beside("build.gradle.kts");
    default:
      return false;
  }
}

/// Whether something is at `path`, its links followed (existsSync), off the station's thread.
const there = (path: string) => stat(path).then(() => true, () => false);

/// Even a generated-looking directory may contain tracked source. If Git cannot inspect a repository, keep it.
/// Standalone generated directories (e.g. a screenshot script's node_modules) do not need a Git repository.
export async function safeToRemove(path: string): Promise<boolean> {
  const isDir = await lstat(path).then((s) => s.isDirectory(), () => false);
  if (!isDir || !(await rebuildable(path))) return false;
  const parent = dirname(path);
  let inRepo = false;
  for (let p = parent; ; p = dirname(p)) {
    if (await there(join(p, ".git"))) {
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

/// How far a measure goes: the most entries it visits and how long it takes, shared by every walk in it (those of the
/// rebuildable directories, `.git` and `uploads` too).
export type MeasureBudget = { maxEntries?: number; maxDurationMs?: number };
/// A workspace's size for its soft limit (measuredUpTo): enough for a warning, never minutes of the disk.
export const MEASURE_UP_TO: Required<MeasureBudget> = { maxEntries: 100_000, maxDurationMs: 15_000 };
/// A room measured for its cleanup (measureRoom, measured): what it finds past this is left for the next time.
export const MEASURE_ROOM: Required<MeasureBudget> = { maxEntries: 500_000, maxDurationMs: 60_000 };

/// What a measure found: its bytes, whether it reached everything (`reason`: why not, the walk's limit that cut it:
/// entries, duration, depth), what it found to make again (with `finding`); `enough`: it stopped as it counted past
/// `stopAfter`.
type Measured = { bytes: number; complete: boolean; reason?: string; rebuild?: [string, number][]; enough?: true };
type Ask = { finding: boolean; strict: boolean; stopAfter?: number };

/// The size of `path` and everything under it, on its file system, by the MoonBit program (`--builder footprint`,
/// station/mb src/footprint), one process a measure under the system's background priority, so none of the walk's
/// entries are the station's thread's or its heap's: links not followed (a link counted as itself), another file
/// system mounted in it not gone into, at most 32 deep, each file once however many names it has, within `budget`
/// (the walks of what it finds sharing it). With `finding`, directories that can be made again are listed (each
/// counted whole, not looked into further for more); never in a `.git` or `uploads`. `strict`: an error of the file
/// system but a path gone fails it (else what cannot be read is passed over). `signal` ends the process at once and
/// fails the measure with its reason. There is no walk in TypeScript to fall back to: the one it replaced is
/// station/test/footprint-reference.ts, which station/test/mb-footprint.test.ts holds the program to.
function measure(path: string, ask: Ask, budget: MeasureBudget, signal?: AbortSignal): Promise<Measured> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(signal.reason);
    const binary = readerBinary();
    const p = new MbProcess(binary, ["--builder", "footprint", "--sep", sep], { background: true });
    let settled = false;
    const done = (f: () => void) => {
      if (settled) return;
      settled = true;
      signal?.removeEventListener("abort", stop);
      f();
    };
    const stop = () => done(() => {
      p.kill();
      reject(signal!.reason);
    });
    signal?.addEventListener("abort", stop, { once: true });
    // (its bytes said `size`: a line that says `bytes` has a body after it, read/mb-reader.ts `Said`)
    p.on("message", ({ size, ...m }: Omit<Measured, "bytes"> & { size: number; error?: string; code?: string }) => done(() => {
      if (m.error === undefined) return resolve({ ...m, bytes: size });
      reject(Object.assign(new Error(m.error), { code: m.code }));
    }));
    p.on("error", (e: Error) => done(() => reject(e)));
    p.on("exit", (code: number) => done(() => reject(new Error(`the measure's program ended saying nothing (${code})`))));
    p.postMessage({
      path, base: normalize(path), ...ask,
      maxEntries: budget.maxEntries ?? MEASURE_ROOM.maxEntries, maxDurationMs: Math.max(0, budget.maxDurationMs ?? MEASURE_ROOM.maxDurationMs),
    });
  });
}

/// Measures one chat's directory again (after something in it was cleaned).
export async function measureRoom(dir: string, budget: MeasureBudget = MEASURE_ROOM): Promise<Room> {
  const { bytes, rebuild } = await measure(dir, { finding: true, strict: false }, budget);
  return { bytes, rebuild: rebuild ?? [] };
}

/// The size of a path, each file once.
export const measured = async (path: string, signal?: AbortSignal, budget: MeasureBudget = MEASURE_ROOM) => (await measure(path, { finding: false, strict: false }, budget, signal)).bytes;

/// Count the whole path when it fits; once it exceeds `limit`, return a lower bound without traversing the rest. A
/// workspace too large or too slow to walk within `budget` (MEASURE_UP_TO) is a lower bound too, `truncated`.
export async function measuredUpTo(path: string, limit: number, signal?: AbortSignal, budget: MeasureBudget = MEASURE_UP_TO): Promise<{ bytes: number; complete: boolean; truncated?: true }> {
  const got = await measure(path, { finding: false, strict: true, stopAfter: limit }, budget, signal);
  if (got.enough) return { bytes: got.bytes, complete: false };
  if (got.complete) return { bytes: got.bytes, complete: true };
  log.info("workspace-size", "workspace walk cut short", { path, bytes: got.bytes, reason: got.reason });
  return { bytes: got.bytes, complete: false, truncated: true };
}
