// A git command past its deadline ended whole, on real processes and signals, so it runs beside the checks
// (`pnpm test:side`): `git gc` starts `repack` and `pack-objects`, which a kill of git alone leaves running.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { runRepoGit } from "../src/ops/repo-branches.ts";

const alive = (pid: number): boolean => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

test("git past its deadline is ended with what it started, and its end is heard", async () => {
  const dir = mkdtempSync(join(tmpdir(), "repo-git-deadline-"));
  try {
    execFileSync("git", ["init", "-q", dir]);
    const pidFile = join(dir, "child.pid");
    // (an alias runs a shell under git, as gc runs repack: a grandchild holding git's stdout)
    const started = Date.now();
    const r = await runRepoGit(dir, ["-c", `alias.slow=!sh -c 'echo $$ > "${pidFile}"; exec sleep 60'`, "slow"], 300, true);
    const took = Date.now() - started;
    assert.equal(r.ok, false);
    assert.ok(took < 5_000, `heard to end soon after its deadline, not when the grandchild would have: ${took} ms`);
    // (the shell may not have written its pid by the deadline on a loaded machine; the grandchild, reparented once git
    // is gone, may take a moment to be reaped)
    const until = Date.now() + 5_000;
    while (!existsSync(pidFile) && Date.now() < until) await new Promise((r) => setTimeout(r, 50));
    assert.ok(existsSync(pidFile), "the alias's shell ran (else nothing here was tested)");
    const pid = Number.parseInt(readFileSync(pidFile, "utf8").trim(), 10);
    while (alive(pid) && Date.now() < until) await new Promise((r) => setTimeout(r, 50));
    assert.equal(alive(pid), false, "the grandchild ended with git");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
