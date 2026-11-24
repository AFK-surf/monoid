// Workspace file helpers for automatic cleanup of archived sessions.
import { execFile } from "node:child_process";
import { access, constants, lstat, open, realpath, stat } from "node:fs/promises";
import { basename, dirname, join, normalize, sep } from "node:path";
import { log } from "../ops/log.ts";
import { fileName, samePath, segments, within } from "../ops/paths.ts";
import { MbProcess, readerBinary } from "../read/mb-reader.ts";
import { resolveReaderEngine } from "../read/reader-select.ts";

/// Path::starts_with: `path` is `dir` or under it.
export { within };

/// Where a session's own directory is: the one its workspace is in when the station made it (sessions/…/workspace),
/// else none (a workspace that is a person's project is not the station's to measure or clean). Its paths followed off
/// the main thread (the synchronous one of before is the tests', test/footprint-reference.ts `roomOf`).
export async function roomOfSoon(dataDir: string, workspace: string): Promise<string | null> {
  const real = (path: string) => realpath(path).catch(() => null);
  const sessions = await real(join(dataDir, "sessions"));
  if (sessions === null) return null;
  return roomIn(sessions, (await real(workspace)) ?? (fileName(workspace) === "workspace" ? beside(await real(dirname(workspace))) : null));
}

/// A workspace not there (yet, or any more) as it would be in its directory `parent` (followed), if that is there.
export const beside = (parent: string | null) => (parent === null ? null : join(parent, "workspace"));

/// The room of the workspace at `path` (followed) under the station's sessions directory (followed).
export function roomIn(sessions: string, path: string | null): string | null {
  if (path === null || !within(path, sessions) || samePath(path, sessions)) return null;
  // Only the station layout sessions/<connect>/<session>/workspace, never an arbitrary nested project.
  const relative = segments(path.slice(sessions.length)).filter((p) => p !== "");
  if (relative.length !== 3 || fileName(path) !== "workspace") return null;
  return dirname(path);
}

/// What deciding whether a directory is rebuildable asks of the disk: whether a file (or anything) is there, whether a
/// directory is, a file's first bytes (null: none). Asked off the main thread's loop (`rebuildableSoon`), or at once by
/// the tests' references (test/footprint-reference.ts `rebuildableKind`).
export type Probe = { there: string } | { dir: string } | { head: string };
export type Answer = boolean | string | null;
/// How a directory is known to be made again: by its name (and a file beside it), as since the start, or by what is in
/// it or near it (`found`), which inside a checkout counts only where git ignores it (`safeToRemove`; the gathering, carry.mbt, as git lists a checkout).
export type Rebuilt = "named" | "found";
/// How far up a MoonBit manifest is looked for above a `_build` (to the checkout's top, never past it).
const MANIFEST_UP = 8;
/// What Cargo writes in its target directory's CACHEDIR.TAG (the standard's signature, then its own line).
export const CARGO_TAG = ["Signature: 8a477f597d28d172789f06886806bc55", "# This file is a cache directory tag created by cargo."];

export function* decide(dir: string): Generator<Probe, Rebuilt | null, Answer> {
  const name = fileName(dir);
  if (name === null) return null;
  const parent = dirname(dir);
  const beside = function* (...files: string[]): Generator<Probe, boolean, Answer> {
    for (const f of files) if ((yield { there: join(parent, f) }) === true) return true;
    return false;
  };
  switch (name) {
    case "node_modules":
    case ".next":
    case ".turbo":
    case "__pycache__":
      return "named";
    case "target":
      if (yield* beside("Cargo.toml")) return "named";
      break;
    case ".gradle":
      if (yield* beside("settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts")) return "named";
      break;
    case "build":
      if (yield* beside("build.gradle", "build.gradle.kts")) return "named";
      break;
    // Elixir's (beside mix.exs) and MoonBit's (`moon` builds into the module's or the work's `_build`, its packages in
    // `.mooncakes`).
    case "_build":
      if ((yield* beside("mix.exs")) || (yield* moonAbove(parent))) return "found";
      break;
    case "deps":
      if (yield* beside("mix.exs")) return "found";
      break;
    case ".mooncakes":
      if (yield* beside("moon.mod.json", "moon.mod", "moon.work")) return "found";
      break;
  }
  // Of any name: Xcode's derived data (its products and intermediates), and a Cargo target directory elsewhere
  // (CARGO_TARGET_DIR, --target-dir): its CACHEDIR.TAG says Cargo, and Cargo's own files are in it.
  if ((yield { dir: join(dir, "Build", "Products") }) === true && (yield { dir: join(dir, "Build", "Intermediates.noindex") }) === true) return "found";
  const tag = yield { head: join(dir, "CACHEDIR.TAG") };
  if (typeof tag === "string" && CARGO_TAG.every((line) => tag.split(/\r?\n/).includes(line))) {
    if ((yield { there: join(dir, ".rustc_info.json") }) === true) return "found";
    for (const profile of ["debug", "release"]) for (const own of ["deps", ".fingerprint"]) if ((yield { dir: join(dir, profile, own) }) === true) return "found";
  }
  return null;
}

/// Whether a MoonBit manifest (moon.mod.json, moon.mod, moon.work, moon.pkg.json, moon.pkg) is in `from` or above it
/// within its checkout (up to the directory with `.git`, at most MANIFEST_UP up); outside a checkout only in `from`
/// itself.
function* moonAbove(from: string): Generator<Probe, boolean, Answer> {
  let found = false;
  for (let p = from, i = 0; i < MANIFEST_UP; i++) {
    for (const m of ["moon.mod.json", "moon.mod", "moon.work", "moon.pkg.json", "moon.pkg"]) {
      if ((yield { there: join(p, m) }) !== true) continue;
      if (p === from) return true;
      found = true;
    }
    if ((yield { there: join(p, ".git") }) === true) return found;
    const up = dirname(p);
    if (up === p) break;
    p = up;
  }
  return false;
}

/// The first bytes of a file a probe reads (a CACHEDIR.TAG is a few lines).
export const HEAD_BYTES = 512;
/// How a probe opens a file to read its head: without blocking, so a FIFO with no writer (or a device) opens at once
/// and is refused as not a regular file by its descriptor's stat, never waited on.
export const HEAD_OPEN = constants.O_RDONLY | (constants.O_NONBLOCK ?? 0) | (constants.O_NOCTTY ?? 0);

const answerSoon = async (p: Probe): Promise<Answer> => {
  try {
    if ("there" in p) return await access(p.there).then(() => true, () => false);
    if ("dir" in p) return (await stat(p.dir)).isDirectory();
    const f = await open(p.head, HEAD_OPEN);
    try {
      if (!(await f.stat()).isFile()) return null;
      const buf = Buffer.alloc(HEAD_BYTES);
      return buf.subarray(0, (await f.read(buf, 0, HEAD_BYTES, 0)).bytesRead).toString("utf8");
    } finally {
      await f.close();
    }
  } catch {
    return "head" in p ? null : false;
  }
};

/// How a directory is one a build or an install makes again (null: it is not): node_modules, a Cargo target, a Gradle
/// build and its cache, Next's and Turbo's caches, Python's bytecode by name; Elixir's and MoonBit's builds and
/// dependencies, Xcode's derived data and a Cargo target of any name by what is in or beside them (`found`). Never by a
/// bare name alone: what it is, is seen. Its looks at the disk off the thread (the synchronous one of before, and the
/// gathering's by the listings, are the tests' references: test/footprint-reference.ts).
export async function rebuildableSoon(dir: string): Promise<Rebuilt | null> {
  const g = decide(dir);
  for (let r = g.next(); ; ) {
    if (r.done) return r.value;
    r = g.next(await answerSoon(r.value));
  }
}

/// Even a generated-looking directory may contain tracked source. If Git cannot inspect a repository, keep it. One known
/// by what is in it (`found`) goes, inside a checkout, only where git ignores it: a project may name its own directory
/// so. Standalone generated directories (e.g. a screenshot script's node_modules) do not need a Git repository.
export async function safeToRemove(path: string): Promise<boolean> {
  const isDir = await lstat(path).then((s) => s.isDirectory(), () => false);
  const kind = isDir ? await rebuildableSoon(path) : null;
  if (kind === null) return false;
  const parent = dirname(path);
  let inRepo = false;
  for (let p = parent; ; p = dirname(p)) {
    if (await access(join(p, ".git")).then(() => true, () => false)) {
      inRepo = true;
      break;
    }
    if (dirname(p) === p) break;
  }
  if (!inRepo) return true;
  const git = (args: string[]) => new Promise<{ ok: boolean; out: number }>((resolve) => {
    execFile("git", ["-C", parent, ...args], { encoding: "buffer" }, (error, stdout) => resolve({ ok: error === null, out: stdout.length }));
  });
  const tracked = await git(["ls-files", "--", basename(path)]);
  if (!tracked.ok || tracked.out > 0) return false;
  return kind === "named" || (await git(["check-ignore", "-q", "--", `${basename(path)}/`])).ok;
}

/// A chat's own directory (its session's workspace and what is beside it).
export type Room = {
  bytes: number;
  /// What can be made again, in it: directories and their sizes.
  rebuild: [string, number][];
  complete?: boolean;
  reason?: string;
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

const warnedReaderFallbacks = new Set<string>();

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
    const selection = resolveReaderEngine("footprint", { hasPionBinary: false });
    if (selection.fallback) {
      const dedupKey = `${selection.mode}:${selection.source}:${selection.reason ?? "unknown"}`;
      if (!warnedReaderFallbacks.has(dedupKey)) {
        warnedReaderFallbacks.add(dedupKey);
        log.warn("footprint", "reader engine fallback", {
          mode: selection.mode,
          engine: selection.engine,
          requested: selection.requested,
          source: selection.source,
          reason: selection.reason,
          detail: selection.detail,
        });
      }
    }
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
  const { bytes, rebuild, complete, reason } = await measure(dir, { finding: true, strict: false }, budget);
  return { bytes, rebuild: rebuild ?? [], complete, ...(reason !== undefined ? { reason } : {}) };
}

/// The size of a path, each file once.
export const measured = async (path: string, signal?: AbortSignal, budget: MeasureBudget = MEASURE_ROOM) => (await measure(path, { finding: false, strict: false }, budget, signal)).bytes;

/// Count the whole path when it fits; once it exceeds `limit`, return a lower bound without traversing the rest. A
/// workspace too large or too slow to walk within `budget` (MEASURE_UP_TO) is a lower bound too, `truncated`.
export async function measuredUpTo(
  path: string,
  limit: number,
  signal?: AbortSignal,
  budget: MeasureBudget = MEASURE_UP_TO,
  strict = true,
): Promise<{ bytes: number; complete: boolean; truncated?: true }> {
  const got = await measure(path, { finding: false, strict, stopAfter: limit }, budget, signal);
  if (got.enough) return { bytes: got.bytes, complete: false };
  if (got.complete) return { bytes: got.bytes, complete: true };
  log.info("workspace-size", "workspace walk cut short", { path, bytes: got.bytes, reason: got.reason });
  return { bytes: got.bytes, complete: false, truncated: true };
}
