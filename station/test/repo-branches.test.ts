// Tests for GIT_NO_LAZY_FETCH=1 in repo-branches background inspection (src/ops/repo-branches.ts).
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, test } from "node:test";
import { pruneRepoBranchesIn } from "../src/ops/repo-branches.ts";

const dirs: string[] = [];
function scratch(tag: string): string {
  const dir = mkdtempSync(join(tmpdir(), `repo-branches-${tag}-`));
  dirs.push(dir);
  return dir;
}

after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function git(cwd: string, args: string[], extraEnv?: Record<string, string>): string {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: "Test",
      GIT_AUTHOR_EMAIL: "test@example.com",
      GIT_COMMITTER_NAME: "Test",
      GIT_COMMITTER_EMAIL: "test@example.com",
      GIT_TERMINAL_PROMPT: "0",
      ...extraEnv,
    },
  }).trim();
}

function packFiles(repo: string): string[] {
  const packDir = join(repo, ".git", "objects", "pack");
  if (!existsSync(packDir)) return [];
  return readdirSync(packDir).filter((f) => f.endsWith(".pack")).sort();
}

describe("repo-branches anti-lazy-fetch on promisor partial clones", () => {
  test("pruneRepoBranchesIn does not trigger lazy fetch on missing promisor blobs and conservatively preserves unconfirmed branches", async () => {
    const base = scratch("promisor");
    const origin = join(base, "origin.git");
    const seed = join(base, "seed");
    const clone = join(base, "partial-clone");
    const bundles = join(base, "bundles");

    mkdirSync(origin, { recursive: true });
    git(origin, ["init", "--bare", "-b", "main"]);
    git(origin, ["config", "uploadpack.allowFilter", "true"]);
    git(origin, ["config", "uploadpack.allowAnySHA1InWant", "true"]);

    mkdirSync(seed, { recursive: true });
    git(seed, ["init", "-b", "main"]);
    writeFileSync(join(seed, "a.txt"), "base-v1\n");
    git(seed, ["add", "."]);
    git(seed, ["commit", "-m", "c1"]);

    // Add a second commit with another blob, then a third commit so c2's blob is historical.
    git(seed, ["checkout", "-b", "old-feature"]);
    writeFileSync(join(seed, "feat.txt"), "historical-blob-payload-only-on-origin\n");
    git(seed, ["add", "feat.txt"]);
    git(seed, ["commit", "-m", "feat"]);
    const featTip = git(seed, ["rev-parse", "HEAD"]);

    git(seed, ["checkout", "main"]);
    writeFileSync(join(seed, "a.txt"), "base-v2\n");
    git(seed, ["add", "a.txt"]);
    git(seed, ["commit", "-m", "c2"]);

    git(seed, ["remote", "add", "origin", origin]);
    git(seed, ["push", "-u", "origin", "main"]);
    git(seed, ["push", "origin", "old-feature:refs/keep/old-feature"]);

    // Make a promisor partial clone (--filter=blob:none) of origin.
    git(base, ["clone", "--filter=blob:none", `file://${origin}`, clone]);
    // Fetch only commit/tree of old-feature without blobs, and create a local branch pointing at it.
    git(clone, ["fetch", "--filter=blob:none", "origin", `refs/keep/old-feature:refs/heads/local-promisor-branch`]);
    assert.equal(git(clone, ["rev-parse", "refs/heads/local-promisor-branch"]), featTip);

    const packsBefore = packFiles(clone);
    assert.ok(packsBefore.length > 0);

    // Run pruneRepoBranchesIn with a `now` far in the future so branches are past BRANCH_MIN_AGE_MS & STALE_BRANCH_MS.
    const futureNow = Date.now() + 30 * 24 * 3600_000;
    await pruneRepoBranchesIn(base, "partial-clone", clone, futureNow);

    const packsAfter = packFiles(clone);
    assert.deepEqual(packsAfter, packsBefore, "background inspection must not trigger lazy fetch (0 new pack files)");

    // Because `git bundle create` or `git cherry` cannot materialize the missing promisor blob without lazy fetch,
    // the local branch must be conservatively preserved!
    const stillThere = git(clone, ["branch", "--list", "local-promisor-branch"]);
    assert.ok(stillThere.includes("local-promisor-branch"), "unconfirmed promisor branch must be conservatively preserved");
  });
});
