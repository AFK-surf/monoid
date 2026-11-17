// The files of runners gone (src/agents/runner.ts `sweepRunners`): a runner removes its own only when it ends well, and a
// chat's runner has an id of its own each time, so what a killed or crashed one left stayed for good (1.1 GB of output
// on a station, 2026-11-15). Those of a runner alive stay, whatever their age.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, readdirSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { RUNNER_LEFT_MS, liveRunner, runnersDir, sweepRunners, type RunnerInfo } from "../src/agents/runner.ts";
import { wall } from "../src/ops/fibers.ts";
import { tempDir } from "./temp-dir.ts";

/// A pid no process has now: one that ran and ended.
const deadPid = () => spawnSync(process.execPath, ["-e", ""]).pid!;

function info(id: string, runner: number, startedAt: number): RunnerInfo {
  return { id, runner, pid: runner, pgid: runner, startedAt, program: "claude", args: [], socket: `/nowhere/${id}.sock` };
}

test("a runner's files go once it is gone; those of one alive, and those just written, stay", async () => {
  const data = tempDir(join(tmpdir(), "rs-"));
  const dir = runnersDir(data);
  mkdirSync(dir, { recursive: true });
  const now = wall.now();
  const files = (id: string) => ["json", "out", "err", "sock"].map((e) => join(dir, `${id}.${e}`));
  // Gone (killed with its agent: nothing removed its files).
  for (const f of files("claude-chat_a-1")) writeFileSync(f, "x");
  writeFileSync(join(dir, "claude-chat_a-1.json"), JSON.stringify(info("claude-chat_a-1", deadPid(), now - 60_000)));
  // Alive: this process stands for its runner.
  for (const f of files("codex-p")) writeFileSync(f, "x");
  writeFileSync(join(dir, "codex-p.json"), JSON.stringify(info("codex-p", process.pid, now)));
  for (const f of files("codex-p")) utimesSync(f, 1, 1);
  // A pid reused: alive, but started after its runner said it had (a year before).
  writeFileSync(join(dir, "claude-chat_b-2.json"), JSON.stringify(info("claude-chat_b-2", process.pid, now - 365 * 24 * 3600_000)));
  // Output with no info file: left over once old; one being started (just made) stays.
  writeFileSync(join(dir, "claude-chat_c-3.out"), "x");
  utimesSync(join(dir, "claude-chat_c-3.out"), (now - RUNNER_LEFT_MS - 1000) / 1000, (now - RUNNER_LEFT_MS - 1000) / 1000);
  writeFileSync(join(dir, "claude-chat_d-4.out"), "x");
  writeFileSync(join(dir, "claude-chat_d-4.err"), "x");
  // A half-written info file, old.
  writeFileSync(join(dir, "claude-chat_e-5.json.tmp"), "{");
  utimesSync(join(dir, "claude-chat_e-5.json.tmp"), 1, 1);

  const gone = await sweepRunners(data, now);
  assert.deepEqual(gone.sort(), ["claude-chat_a-1", "claude-chat_b-2", "claude-chat_c-3", "claude-chat_e-5.json"].sort());
  assert.deepEqual(readdirSync(dir).sort(), ["claude-chat_d-4.err", "claude-chat_d-4.out", "codex-p.err", "codex-p.json", "codex-p.out", "codex-p.sock"]);
  assert.deepEqual(await sweepRunners(data, now), [], "nothing more");
});

test("a runner alive is told from a pid reused", async () => {
  const now = wall.now();
  assert.equal(await liveRunner(info("x", process.pid, now)), true);
  assert.equal(await liveRunner(info("x", deadPid(), now)), false);
  assert.equal(await liveRunner(info("x", process.pid, now - 365 * 24 * 3600_000)), false, "this process started long after that");
});
