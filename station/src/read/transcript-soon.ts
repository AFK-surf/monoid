// Where a runtime's transcripts are (read/transcript.ts, its `Looking`s), found off the station's thread: each question
// answered with node:fs/promises, a Codex rollout by a bounded walk. Apart from read/transcript.ts, which much reads that
// looks for no transcript (a copy's restore in a worker of a small heap among them) and keeps free of the walk's clock
// and the Effect under it.
import { access, readdir, realpath, stat } from "node:fs/promises";
import type { RuntimeKind } from "../agents/runtime.ts";
import { walkBounded } from "../ops/walk.ts";
import { ROLLOUT_DEPTH, ROLLOUT_ENTRIES } from "./machine.ts";
import { type Look, type Looking, rememberCodexRolloutLooking, transcriptPathsLooking, transcriptSourcesLooking } from "./transcript.ts";

/// A `Looking` answered off the station's thread: each question with node:fs/promises, a Codex rollout by a bounded walk
/// (`rolloutUnder`).
export async function looked<T>(looking: Looking<T>): Promise<T> {
  for (let step = looking.next(); ; step = looking.next(await answer(step.value))) if (step.done) return step.value;
}

async function answer(look: Look): Promise<unknown> {
  switch (look.ask) {
    case "there": return access(look.path).then(() => true, () => false);
    case "file": return stat(look.path).then((s) => s.isFile(), () => false);
    case "names": return readdir(look.path).catch(() => null);
    case "real": return realpath(look.path).catch(() => null);
    case "rollout": return rolloutUnder(look.path, look.id);
  }
}

/// The Codex rollout of `id` under `dir` (sessions/<year>/<month>/<day>/rollout-…-<id>.jsonl, or its `.zst` once put
/// away: the path of the `.jsonl` then), walked as every walk of a tree the station does not own is (ops/walk.ts
/// `walkBounded`: bounded by ROLLOUT_DEPTH and ROLLOUT_ENTRIES, yielding as it goes). Links are followed, each real
/// directory gone into once (a home's sessions/ is one, to the shared place), and only a directory or a link is
/// stat'ed: a cold file cache made a stat of every rollout seconds.
async function rolloutUnder(dir: string, id: string): Promise<string | null> {
  let found: string | null = null;
  await walkBounded(dir, (entry) => {
    if (entry.depth === 0 || entry.directory || !entry.name.startsWith("rollout-")) return;
    if (entry.name.endsWith(`${id}.jsonl`)) found = entry.path;
    else if (entry.name.endsWith(`${id}.jsonl.zst`)) found = entry.path.slice(0, -".zst".length);
    else return;
    return "stop";
  }, { followRoot: true, followLinks: true, sameDevice: false, maxDepth: ROLLOUT_DEPTH, maxEntries: ROLLOUT_ENTRIES });
  return found;
}

/// read/transcript.ts `transcriptPathsLooking`, off the station's thread.
export const transcriptPathsSoon = (...args: Parameters<typeof transcriptPathsLooking>): Promise<{ paths: string[]; current: boolean }> => looked(transcriptPathsLooking(...args));

/// read/transcript.ts `transcriptSourcesLooking`, off the station's thread.
export const transcriptSourcesSoon = (...args: Parameters<typeof transcriptSourcesLooking>): Promise<{ paths: { path: string; runtime: RuntimeKind }[]; current: boolean }> => looked(transcriptSourcesLooking(...args));

/// read/transcript.ts `rememberCodexRolloutLooking`, off the station's thread.
export const rememberCodexRolloutSoon = (home: string, id: string, path: unknown): Promise<string | null> => looked(rememberCodexRolloutLooking(home, id, path));
