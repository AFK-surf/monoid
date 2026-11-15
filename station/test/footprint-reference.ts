// The measure of a directory's size as the station's main thread made it before it was the MoonBit program's
// (src/sessions/footprint.ts, station/mb src/footprint): kept as the reference test/mb-footprint.test.ts holds the
// program to, on the walk it used (src/ops/walk.ts `walkBounded`, `stat`). `now` is the tests' clock for its budget.
import type { BigIntStats } from "node:fs";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { wall } from "../src/ops/fibers.ts";
import { fileName } from "../src/ops/paths.ts";
import { walkBounded } from "../src/ops/walk.ts";

/// footprint.ts `rebuildable`, synchronous (what the main thread's walk and test/carry-reference.ts asked).
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
    const walked = await walkBounded(root, async (entry) => {
      if (++visited > most) {
        cut ??= "entries";
        return "stop";
      }
      if (finding && entry.depth > 0 && entry.directory) {
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
