// Where a runtime's transcripts are, found with node:fs's synchronous calls, as the station found them on its thread
// before it looked for them off it (src/read/transcript.ts `looked`): kept for the tests and the references that are
// synchronous themselves (a reader of before, a worker's locator), answering the station's own `Looking`s, so the two
// find the same. A Codex rollout is walked as it was then: every directory, its links followed, depth first.
import { existsSync, readdirSync, realpathSync, statSync } from "node:fs";
import { join } from "node:path";
import type { RuntimeKind } from "../../src/agents/runtime.ts";
import {
  type Look, type Looking, type TranscriptLocationHints, keptTranscriptHints, rememberCodexRolloutLooking, transcriptDir,
  transcriptInLooking, transcriptPathsLooking, transcriptSourcesLooking,
} from "../../src/read/transcript.ts";

export * from "../../src/read/transcript.ts";

/// A `Looking` answered on this thread.
export function lookedNow<T>(looking: Looking<T>): T {
  for (let step = looking.next(); ; step = looking.next(answerNow(step.value))) if (step.done) return step.value;
}

const isDir = (path: string) => {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
};

function answerNow(look: Look): unknown {
  switch (look.ask) {
    case "there": return existsSync(look.path);
    case "file":
      try {
        return statSync(look.path).isFile();
      } catch {
        return false;
      }
    case "names":
      try {
        return readdirSync(look.path);
      } catch {
        return null;
      }
    case "real":
      try {
        return realpathSync(look.path);
      } catch {
        return null;
      }
    case "rollout": return rolloutUnder(look.path, look.id);
  }
}

function rolloutUnder(dir: string, id: string): string | null {
  // Directory entries already say whether ordinary files are directories: only links and unknown types are stat'ed.
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return null;
  }
  for (const entry of entries) {
    const name = entry.name;
    const path = join(dir, name);
    if (entry.isDirectory() || (!entry.isFile() && isDir(path))) {
      const found = rolloutUnder(path, id);
      if (found !== null) return found;
    } else if (name.startsWith("rollout-") && name.endsWith(`${id}.jsonl`)) {
      return path;
    } else if (name.startsWith("rollout-") && name.endsWith(`${id}.jsonl.zst`)) {
      return path.slice(0, -".zst".length);
    }
  }
  return null;
}

/// archive.rs `storage`: the file, or its `.zst` once put away.
export const storage = (path: string) => (existsSync(path) ? path : `${path}.zst`);

/// transcript_path: where a runtime keeps a session's transcript in a home, if it is there.
export const transcriptPath = (runtime: RuntimeKind, home: string, id: string): string | null =>
  lookedNow(transcriptInLooking(runtime, join(home, transcriptDir(runtime)), id));

export const transcriptPaths = (...args: Parameters<typeof transcriptPathsLooking>) => lookedNow(transcriptPathsLooking(...args));
export const transcriptSources = (...args: Parameters<typeof transcriptSourcesLooking>) => lookedNow(transcriptSourcesLooking(...args));
export const rememberCodexRollout = (home: string, id: string, path: unknown) => lookedNow(rememberCodexRolloutLooking(home, id, path));

/// Used in a locator's worker, whose transcript caches belong to one batch at a time.
export function useTranscriptLocationHints(hints: TranscriptLocationHints): void {
  const { elsewhere, rollouts, saidRollouts } = keptTranscriptHints();
  elsewhere.clear();
  rollouts.clear();
  saidRollouts.clear();
  for (const [key, path] of hints.elsewhere) elsewhere.set(key, path);
  for (const [key, path] of hints.rollouts) rollouts.set(key, path);
  for (const [id, dirs] of hints.said) saidRollouts.set(id, new Map(dirs));
}
