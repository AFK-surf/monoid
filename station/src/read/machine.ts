// Sessions this machine's own Claude Code and Codex keep (run in a terminal, in ~/.claude and ~/.codex): where they are,
// and what the station itself still looks up of them. Listing them and reading one (GET /machine-sessions, GET
// /machine-sessions/:runtime/:id) is the MoonBit readers' (mb/src/readops/machine.mbt); the TypeScript they replaced
// is test/reference/machine.ts. What is here runs on the station's thread, so it never reads the disk synchronously:
// a transcript's path is found by a walk that yields (ops/walk.ts).
import { opendir, stat } from "node:fs/promises";
import { basename, join } from "node:path";
import { walkBounded } from "../ops/walk.ts";

export type Runtime = "claude" | "codex";

/// Where the machine's runtimes keep their sessions (MachineRoots): Claude Code's projects/, Codex's sessions/.
export type Roots = { claude: string; codex: string };

/// MachineRoots::of the station's environment: $HOME/.claude/projects, and $CODEX_HOME (else $HOME/.codex)/sessions.
export function roots(): Roots {
  const home = process.env.HOME ?? ".";
  const codex = process.env.CODEX_HOME ? process.env.CODEX_HOME : join(home, ".codex");
  return { claude: join(home, ".claude", "projects"), codex: join(codex, "sessions") };
}

/// A session of the machine's, as the pages list it (MachineSession; `path` is not written).
export type MachineSession = {
  runtime: Runtime; id: string; cwd: string; title: string | null; first: string | null; model: string | null;
  updatedAt: number; size: number; session: string | null; path: string;
};

/// Path::extension: after the last dot of the name, unless that dot starts it.
export function extension(name: string): string | null {
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1) : null;
}

/// How far a walk of Codex's rollouts goes: Codex keeps them at sessions/<year>/<month>/<day>/, a year's of daily use a
/// few thousand files; a directory under it that is a disk or share mounted there, a link (to the home, say) or a tree a
/// million entries deep is not walked (ops/walk.ts says why).
export const ROLLOUT_DEPTH = 8;
export const ROLLOUT_ENTRIES = 100_000;

/// rollout_of: a rollout file of a thread: rollout-<time>-<id>.jsonl, or rollout-<time>-<id>_<more>.jsonl.
export function rolloutOf(path: string, id: string): boolean {
  const name = basename(path);
  return name.endsWith(`-${id}.jsonl`) || name.includes(`-${id}_`);
}

/// Where the machine keeps the transcript of its session `id` of `runtime`, found as the readers' `find` finds it
/// (test/reference/machine.ts), off the station's thread: Claude Code's in the first project directory, in the file
/// system's order, holding <id>.jsonl; Codex's the latest written of the thread's rollouts, walked as ops/walk.ts walks,
/// bounded by ROLLOUT_DEPTH and ROLLOUT_ENTRIES. Only the files' names and stats are read, not their records: a session
/// the station went on with was read whole when it did, and a transcript is only added to. None where there is none.
export async function transcriptOf(r: Roots, runtime: Runtime, id: string): Promise<string | null> {
  if (id === "" || !/^[A-Za-z0-9-]+$/.test(id)) return null;
  if (runtime === "claude") {
    let dir;
    try {
      dir = await opendir(r.claude);
    } catch {
      return null;
    }
    let left = ROLLOUT_ENTRIES;
    try {
      for await (const d of dir) {
        if (left-- <= 0) break;
        const path = join(r.claude, d.name, `${id}.jsonl`);
        if (await isFile(path)) return path;
      }
    } catch {
      // An entry that does not read ends it, as the readers' `read_dir` stops there.
    }
    return null;
  }
  const mine: string[] = [];
  await walkBounded(
    r.codex,
    (e) => {
      if (e.file && e.depth > 0 && e.name.startsWith("rollout-") && extension(e.name) === "jsonl" && rolloutOf(e.path, id)) mine.push(e.path);
    },
    { maxDepth: ROLLOUT_DEPTH, maxEntries: ROLLOUT_ENTRIES, followRoot: true },
  );
  let latest: [number, string] | null = null;
  for (const path of mine) {
    const at = await writtenAt(path);
    if (at !== null && (latest === null || at > latest[0])) latest = [at, path];
  }
  return latest?.[1] ?? null;
}

async function isFile(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isFile();
  } catch {
    return false;
  }
}

/// When a file was last written (ms), where it is one.
async function writtenAt(path: string): Promise<number | null> {
  try {
    const meta = await stat(path, { bigint: true });
    return meta.isFile() ? Number(meta.mtimeNs / 1_000_000n) : null;
  } catch {
    return null;
  }
}
