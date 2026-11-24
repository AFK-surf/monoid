// The measure of a directory's size as the station's main thread made it before it was the MoonBit program's
// (src/sessions/footprint.ts, station/mb src/footprint): kept as the reference test/mb-footprint.test.ts holds the
// program to, on the walk it used (src/ops/walk.ts `walkBounded`, `stat`). `now` is the tests' clock for its budget.
import { type BigIntStats, closeSync, existsSync, fstatSync, openSync, readSync, realpathSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { wall } from "../src/ops/fibers.ts";
import { fileName } from "../src/ops/paths.ts";
import { walkBounded } from "../src/ops/walk.ts";
import { type Answer, CARGO_TAG, HEAD_BYTES, HEAD_OPEN, type Probe, type Rebuilt, beside, decide, roomIn } from "../src/sessions/footprint.ts";

const canonical = (path: string): string | null => {
  try {
    return realpathSync(path);
  } catch {
    return null;
  }
};

/// footprint.ts `roomOfSoon` at once, its paths followed on the caller's thread: a session's own directory
/// (sessions/…/workspace's), else none.
export function roomOf(dataDir: string, workspace: string): string | null {
  const sessions = canonical(join(dataDir, "sessions"));
  if (sessions === null) return null;
  return roomIn(sessions, canonical(workspace) ?? (fileName(workspace) === "workspace" ? beside(canonical(dirname(workspace))) : null));
}

// What decides whether a directory is made again, asked at once (footprint.ts asks it off the main thread,
// `rebuildableSoon`): what the program's measure and the gathering of before (test/carry-reference.ts) are held to.
const answerNow = (p: Probe): Answer => {
  try {
    if ("there" in p) return existsSync(p.there);
    // (most directories have neither: no exception thrown for each)
    if ("dir" in p) return statSync(p.dir, { throwIfNoEntry: false })?.isDirectory() === true;
    if (!existsSync(p.head)) return null;
    const fd = openSync(p.head, HEAD_OPEN);
    try {
      if (!fstatSync(fd).isFile()) return null;
      const buf = Buffer.alloc(HEAD_BYTES);
      return buf.subarray(0, readSync(fd, buf, 0, HEAD_BYTES, 0)).toString("utf8");
    } finally {
      closeSync(fd);
    }
  } catch {
    return "head" in p ? null : false;
  }
};

/// The gathering's own decision (carry.mbt `rebuilt_by_name`, the reference of before), from the listings it reads anyway, so that a directory that is none
/// costs it no look at the disk more than main's walk took: `name` a directory's, `beside` the names of the directory it
/// is in. By its name and a file beside it (outside a checkout, MoonBit's manifest beside only).
export function rebuiltByName(name: string, beside: ReadonlySet<string>): Rebuilt | null {
  switch (name) {
    case "node_modules":
    case ".next":
    case ".turbo":
    case "__pycache__":
      return "named";
    case "target":
      return beside.has("Cargo.toml") ? "named" : null;
    case ".gradle":
      return beside.has("settings.gradle") || beside.has("settings.gradle.kts") || beside.has("build.gradle") || beside.has("build.gradle.kts") ? "named" : null;
    case "build":
      return beside.has("build.gradle") || beside.has("build.gradle.kts") ? "named" : null;
    case "_build":
      return beside.has("mix.exs") || beside.has("moon.mod.json") || beside.has("moon.mod") || beside.has("moon.work") || beside.has("moon.pkg.json") || beside.has("moon.pkg") ? "found" : null;
    case "deps":
      return beside.has("mix.exs") ? "found" : null;
    case ".mooncakes":
      return beside.has("moon.mod.json") || beside.has("moon.mod") || beside.has("moon.work") ? "found" : null;
  }
  return null;
}

/// Whether directory `dir`, whose listing is `names`, is made again of any name (Xcode's derived data, a Cargo target):
/// looked at on the disk only where its listing shows the sign (a `Build`, a `CACHEDIR.TAG`), so one without costs
/// nothing. The gathering asks it of what is near its room's top alone (`ANY_NAME_DEPTH`).
export function rebuiltOfAnyName(dir: string, names: readonly string[]): boolean {
  if (names.includes("Build") && answerNow({ dir: join(dir, "Build", "Products") }) === true && answerNow({ dir: join(dir, "Build", "Intermediates.noindex") }) === true) return true;
  if (!names.includes("CACHEDIR.TAG")) return false;
  const tag = answerNow({ head: join(dir, "CACHEDIR.TAG") });
  if (typeof tag !== "string" || !CARGO_TAG.every((line) => tag.split(/\r?\n/).includes(line))) return false;
  if (names.includes(".rustc_info.json")) return true;
  for (const profile of ["debug", "release"]) if (names.includes(profile)) for (const own of ["deps", ".fingerprint"]) if (answerNow({ dir: join(dir, profile, own) }) === true) return true;
  return false;
}

/// How deep under a room's top (its own entries 1) the gathering asks what is made again of any name: those met in
/// real rooms lay at 1 and 2 (`ios-dd`, `exp/t2`); deeper, a walk would pay for the look at every directory.
export const ANY_NAME_DEPTH = 3;

/// Made again by its name alone, as main's walk took it (a file beside looked for only for a `target`, `.gradle` or
/// `build`): what a checkout's listed paths are asked, git saying already what it ignores.
export function rebuildableByName(dir: string): boolean {
  const name = fileName(dir);
  if (name === null) return false;
  if (name !== "target" && name !== ".gradle" && name !== "build") return rebuiltByName(name, new Set()) === "named";
  const at = dirname(dir);
  const files = name === "target" ? ["Cargo.toml"] : name === "build" ? ["build.gradle", "build.gradle.kts"] : ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts"];
  return rebuiltByName(name, new Set(files.filter((f) => answerNow({ there: join(at, f) }) === true))) === "named";
}

/// How a directory is one a build or an install makes again (null: it is not): node_modules, a Cargo target, a Gradle
/// build and its cache, Next's and Turbo's caches, Python's bytecode by name; Elixir's and MoonBit's builds and
/// dependencies, Xcode's derived data and a Cargo target of any name by what is in or beside them (`found`). Never by a
/// bare name alone: what it is, is seen. At once: the station's own is footprint.ts
/// `rebuildableSoon`, off the main thread.
export function rebuildableKind(dir: string): Rebuilt | null {
  const g = decide(dir);
  for (let r = g.next(); ; ) {
    if (r.done) return r.value;
    r = g.next(answerNow(r.value));
  }
}


/// footprint.ts's rule, synchronous (`rebuildableKind`: by name and beside, by what is in or near it): what the
/// program's measure (footprint.mbt `rebuildable`) is held to.
export function rebuildable(dir: string): boolean {
  return rebuildableKind(dir) !== null;
}

/// Counts files once each however many links they have.
class Seen {
  private seen = new Set<string>();
  private total = 0;
  private readonly stopAfter: number | undefined;
  constructor(stopAfter?: number) { this.stopAfter = stopAfter; }
  bytes(meta: BigIntStats): number {
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

export type ReferenceBudget = { maxEntries?: number; maxDurationMs?: number; now?: () => number };
const ROOM = { maxEntries: 500_000, maxDurationMs: 60_000 };
const UP_TO = { maxEntries: 100_000, maxDurationMs: 15_000 };

type Measured = { bytes: number; complete: boolean; reason?: string };

async function measure(path: string, seen: Seen, found: [string, number][] | null, budget: ReferenceBudget, signal?: AbortSignal, strict = false): Promise<Measured> {
  const now = budget.now ?? (() => wall.now());
  const until = now() + (budget.maxDurationMs ?? ROOM.maxDurationMs);
  const most = budget.maxEntries ?? ROOM.maxEntries;
  let visited = 0;
  let bytes = 0;
  let cut: string | undefined;
  const onError = strict ? (_: string, error: NodeJS.ErrnoException) => { if (error.code !== "ENOENT") throw error; } : undefined;
  const walk = async (root: string, finding: boolean): Promise<void> => {
    let dev: bigint | undefined;
    const walked = await walkBounded(root, async (entry) => {
      if (++visited > most) {
        cut ??= "entries";
        return "stop";
      }
      if (entry.depth === 0) dev = entry.stats!.dev;
      // (another file system mounted in it, whatever its name: counted as itself, never looked into nor found; the walk
      // does not go into it)
      if (finding && entry.depth > 0 && entry.directory && entry.stats!.dev === dev) {
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

/// footprint.ts `measureRoom` as it was.
export async function measureRoomReference(dir: string, budget: ReferenceBudget = ROOM): Promise<{ bytes: number; rebuild: [string, number][]; complete: boolean; reason?: string }> {
  const rebuild: [string, number][] = [];
  const got = await measure(dir, new Seen(), rebuild, budget);
  return { ...got, rebuild };
}

/// footprint.ts `measured` as it was.
export const measuredReference = async (path: string, signal?: AbortSignal, budget: ReferenceBudget = ROOM) => (await measure(path, new Seen(), null, budget, signal)).bytes;

/// footprint.ts `measuredUpTo` as it was (`reason` too, which it logged).
export async function measuredUpToReference(path: string, limit: number, signal?: AbortSignal, budget: ReferenceBudget = UP_TO): Promise<{ bytes: number; complete: boolean; truncated?: true; reason?: string }> {
  try {
    const got = await measure(path, new Seen(limit), null, budget, signal, true);
    if (got.complete) return { bytes: got.bytes, complete: true };
    return { bytes: got.bytes, complete: false, truncated: true, reason: got.reason! };
  } catch (error) {
    if (error instanceof Enough) return { bytes: error.bytes, complete: false };
    throw error;
  }
}
