// The runners a test's station left, read as a test looks at them between its steps (synchronously, in an `until`):
// the station itself reads them off its thread (src/agents/runner.ts `liveRunners`).
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { runnersDir, type RunnerInfo } from "../src/agents/runner.ts";

/// The info files of runners under `data`, those whose runner is alive.
export function existingRunners(data: string): RunnerInfo[] {
  const dir = runnersDir(data);
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .flatMap((f) => {
      try {
        const info = JSON.parse(readFileSync(join(dir, f), "utf8")) as RunnerInfo;
        process.kill(info.runner, 0);
        return [info];
      } catch {
        return [];
      }
    });
}
