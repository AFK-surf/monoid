// Tests for PR B: daily local branch cleanup in shared clones (with 14d stale unpushed branch bundling,
// 30d bundle expiry, and process-file classification) and relaxed `relieveRepos` (3d idle, process-file
// untracked tolerance, and pre-reclaim branch cleanup).
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, describe, test } from "node:test";
import { DISK_LOW_BYTES } from "../src/ops/disk.ts";
import {
  BRANCH_MIN_AGE_MS,
  REPO_BRANCHES_EVERY_MS,
  REPO_BUNDLE_MS,
  STALE_BRANCH_MS,
  Upkeep,
  isProcessFile,
  keepAllSharedClonePacks,
  pruneAllRepoBranches,
  pruneExpiredRepoBundles,
  runRepoGit,
  storageEntry,
} from "../src/ops/storage.ts";
import { REPO_IDLE_MS, relieveRepos } from "../src/sessions/lifecycle.ts";
import { Rig, testClock } from "./hub-fakes.ts";

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

const tempDirs: string[] = [];
function makeTemp(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

after(() => {
  for (const d of tempDirs) rmSync(d, { recursive: true, force: true });
});

function git(cwd: string, args: string[], extraEnv: Record<string, string> = {}): string {
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

function isoSec(ms: number): string {
  return `${Math.floor(ms / 1000)} +0000`;
}

function setMtime(path: string, ms: number): void {
  const sec = ms / 1000;
  utimesSync(path, sec, sec);
}

function setRepoMtime(repo: string, ms: number): void {
  for (const rel of [".git/HEAD", ".git/FETCH_HEAD", ".git/index", ".git/logs/HEAD"]) {
    const p = join(repo, rel);
    if (existsSync(p)) setMtime(p, ms);
  }
}

/// Backdates a branch's ref age by removing its reflog and setting the loose ref file's mtime.
function ageBranchRef(repo: string, branch: string, ms: number): void {
  rmSync(join(repo, ".git", "logs", "refs", "heads", branch), { force: true });
  const refFile = join(repo, ".git", "refs", "heads", branch);
  if (existsSync(refFile)) setMtime(refFile, ms);
}

function branchExists(repo: string, branch: string): boolean {
  try {
    git(repo, ["show-ref", "--verify", "--quiet", `refs/heads/${branch}`]);
    return true;
  } catch {
    return false;
  }
}

function initCloneWithRemote(
  cloneDir: string,
  bareDir: string,
  baseTimeMs: number,
  remoteUrl = "https://github.com/example/demo.git",
): string {
  mkdirSync(bareDir, { recursive: true });
  git(bareDir, ["init", "--bare", "-b", "main"]);
  mkdirSync(cloneDir, { recursive: true });
  git(cloneDir, ["init", "-b", "main"]);
  writeFileSync(join(cloneDir, "README.md"), "hello\n");
  git(cloneDir, ["add", "README.md"]);
  git(cloneDir, ["commit", "-m", "init"], {
    GIT_AUTHOR_DATE: isoSec(baseTimeMs - 30 * DAY),
    GIT_COMMITTER_DATE: isoSec(baseTimeMs - 30 * DAY),
  });
  git(cloneDir, ["remote", "add", "origin", bareDir]);
  git(cloneDir, ["push", "-u", "origin", "main"]);
  git(cloneDir, ["remote", "set-head", "origin", "main"]);
  if (remoteUrl !== bareDir) {
    // Keep bareDir pushable during setup; callers that need https URL set it after setup.
  }
  return cloneDir;
}

describe("shared clone packs", () => {
  test("turns off git's automatic maintenance in every worktree and compacts the packs itself", async () => {
    const now = Date.UTC(2026, 10, 26, 12, 0, 0);
    const data = makeTemp("sf-repo-packs-");
    const repo = initCloneWithRemote(join(data, "repos", "demo"), join(data, "remote.git"), now);
    // Past gc.autoPackLimit (50): every fetch leaves a pack like this one.
    for (let i = 0; i < 55; i++) {
      writeFileSync(join(repo, `f${i}.txt`), `${i}\n`);
      git(repo, ["add", `f${i}.txt`]);
      git(repo, ["-c", "gc.auto=0", "-c", "maintenance.auto=false", "commit", "-q", "-m", `c${i}`]);
      git(repo, ["repack", "-q"]);
    }
    const packs = () => readdirSync(join(repo, ".git", "objects", "pack")).filter((f) => f.endsWith(".pack")).length;
    assert.ok(packs() > 50, `set up past the pack limit: ${packs()}`);
    const wt = join(data, "sessions", "chat", "c-1", "workspace", "wt");
    mkdirSync(dirname(wt), { recursive: true });
    git(repo, ["worktree", "add", "-q", "-b", "wt-branch", wt]);

    await keepAllSharedClonePacks(data);

    assert.equal(git(wt, ["config", "maintenance.auto"]), "false", "a worktree's commit starts no background maintenance");
    assert.equal(git(wt, ["config", "gc.auto"]), "0", "nor a background gc");
    assert.ok(packs() <= 2, `the station's gc compacted the packs: ${packs()}`);
  });

  test("a clone whose gc failed or was stopped is tried again only on the daily round", async () => {
    const data = makeTemp("sf-repo-packs-failed-");
    const repo = initCloneWithRemote(join(data, "repos", "demo"), join(data, "remote.git"), Date.UTC(2026, 10, 26));
    // (past the pack limit as git counts it: names alone)
    for (let i = 0; i < 51; i++) writeFileSync(join(repo, ".git", "objects", "pack", `pack-${String(i).padStart(40, "0")}.pack`), "");
    let gcs = 0;
    let gcOk = false;
    const repoGit: typeof runRepoGit = async (dir, args, timeoutMs, background) => {
      if (!(args.includes("gc") && args.includes("--auto"))) return runRepoGit(dir, args, timeoutMs, background);
      gcs++;
      return { ok: gcOk, stdout: "" };
    };
    const failed = new Set<string>();
    await keepAllSharedClonePacks(data, { failed, git: repoGit });
    assert.equal(gcs, 1, "past the pack limit: gc");
    await keepAllSharedClonePacks(data, { failed, git: repoGit });
    assert.equal(gcs, 1, "it failed: not again every round");
    gcOk = true;
    await keepAllSharedClonePacks(data, { daily: true, failed, git: repoGit });
    assert.equal(gcs, 2, "the daily round tries it again");
    await keepAllSharedClonePacks(data, { failed, git: repoGit });
    assert.equal(gcs, 3, "once it succeeded, every round past the pack limit again");
  });

  test("an Upkeep round runs the gc past the pack limit or once a day, and not again for what a gc leaves", async () => {
    const data = makeTemp("sf-repo-packs-upkeep-");
    const baseNow = 1_800_000_000_000;
    const { clock, adjust } = testClock();
    await adjust(baseNow);
    initCloneWithRemote(join(data, "repos", "demo"), join(data, "remote.git"), baseNow);
    let gcs = 0;
    const repoGit: typeof runRepoGit = (dir, args, timeoutMs, background) => {
      if (args.includes("gc") && args.includes("--auto")) gcs++;
      return runRepoGit(dir, args, timeoutMs, background);
    };
    const upkeep = new Upkeep({ data, clock, repoGit });
    try {
      await upkeep.run();
      assert.equal(gcs, 1, "the first round is the day's: git's thresholds checked");
      await adjust(HOUR);
      await upkeep.run();
      assert.equal(gcs, 1, "a round within the day, below the pack limit, runs no gc (unreachable loose objects a gc keeps would have it run every round)");
      await adjust(REPO_BRANCHES_EVERY_MS);
      await upkeep.run();
      assert.equal(gcs, 2, "the next day's round runs it again");
    } finally {
      await upkeep.close();
    }
  });
});

describe("PR B: shared clone local branch cleanup & repo-bundles", () => {
  test("STORAGE_MANIFEST registers repo-bundles (30d bounded-ephemeral) and isProcessFile matches expected paths", () => {
    const entry = storageEntry("repo-bundles");
    assert.ok(entry);
    assert.equal(entry.class, "bounded-ephemeral");
    assert.equal(entry.maxAgeMs, REPO_BUNDLE_MS);
    assert.equal(REPO_IDLE_MS, 3 * DAY);

    for (const p of [
      ".agent/notes.md",
      "scratch/x.md",
      "sub/scratchpad/foo.ts",
      "tmp/a.txt",
      ".tmp/b.json",
      "HANDOFF.md",
      "handoff-2026.txt",
      "NOTES_1.json",
      "REPORT.log",
      "debug/server.log",
      "worklog_final.md",
    ]) {
      assert.equal(isProcessFile(p), true, `expected process file: ${p}`);
    }
    for (const p of [".claude/CLAUDE.md", ".codex/config.toml", "docs/design.md", "src/a.ts", "README.md"]) {
      assert.equal(isProcessFile(p), false, `expected non-process file: ${p}`);
    }
  });

  test("pruneAllRepoBranches deletes a/b/c/d & 15d stale-bundled branches and preserves all protected/recent/diverged branches", async () => {
    const data = makeTemp("sf-branch-clean-data-");
    const remotes = makeTemp("sf-branch-clean-rem-");
    const outside = makeTemp("sf-branch-clean-out-");
    const now = Date.now();

    const bare = join(remotes, "demo.git");
    const repo = initCloneWithRemote(join(data, "repos", "demo"), bare, now);

    // Symlinked external repo in <data>/repos -> MUST NOT be touched
    const extBare = join(remotes, "ext.git");
    const extRepo = initCloneWithRemote(join(outside, "ext-repo"), extBare, now);
    git(extRepo, ["branch", "ext-on-remote", "main"]);
    ageBranchRef(extRepo, "ext-on-remote", now - 2 * DAY);
    symlinkSync(extRepo, join(data, "repos", "linked-ext"));

    // --- Branches that MUST BE DELETED ---

    // (a) Tip already on remote
    git(repo, ["checkout", "-b", "a-on-remote", "main"]);
    writeFileSync(join(repo, "a.txt"), "on remote\n");
    git(repo, ["add", "a.txt"]);
    git(repo, ["commit", "-m", "a"], { GIT_AUTHOR_DATE: isoSec(now - 5 * DAY), GIT_COMMITTER_DATE: isoSec(now - 5 * DAY) });
    git(repo, ["push", "origin", "a-on-remote"]);
    git(repo, ["checkout", "main"]);
    ageBranchRef(repo, "a-on-remote", now - 2 * DAY);

    // (b) Cherry-picked onto origin/main (`git cherry` has no '+')
    git(repo, ["checkout", "-b", "b-cherry", "main"]);
    writeFileSync(join(repo, "cherry.txt"), "cherry content\n");
    git(repo, ["add", "cherry.txt"]);
    git(repo, ["commit", "-m", "cherry patch"], { GIT_AUTHOR_DATE: isoSec(now - 5 * DAY), GIT_COMMITTER_DATE: isoSec(now - 5 * DAY) });
    const cherrySha = git(repo, ["rev-parse", "HEAD"]);
    git(repo, ["checkout", "main"]);
    git(repo, ["cherry-pick", cherrySha]);
    git(repo, ["push", "origin", "main"]);
    ageBranchRef(repo, "b-cherry", now - 2 * DAY);

    // (c) Squash-merged onto origin/main (`merge-tree` equals origin/main^{tree})
    git(repo, ["checkout", "-b", "c-squash", "main"]);
    writeFileSync(join(repo, "sq1.txt"), "part 1\n");
    git(repo, ["add", "sq1.txt"]);
    git(repo, ["commit", "-m", "sq1"], { GIT_AUTHOR_DATE: isoSec(now - 5 * DAY), GIT_COMMITTER_DATE: isoSec(now - 5 * DAY) });
    writeFileSync(join(repo, "sq2.txt"), "part 2\n");
    git(repo, ["add", "sq2.txt"]);
    git(repo, ["commit", "-m", "sq2"], { GIT_AUTHOR_DATE: isoSec(now - 5 * DAY), GIT_COMMITTER_DATE: isoSec(now - 5 * DAY) });
    git(repo, ["checkout", "main"]);
    git(repo, ["merge", "--squash", "c-squash"]);
    git(repo, ["commit", "-m", "squash c"], { GIT_AUTHOR_DATE: isoSec(now - 4 * DAY), GIT_COMMITTER_DATE: isoSec(now - 4 * DAY) });
    git(repo, ["push", "origin", "main"]);
    ageBranchRef(repo, "c-squash", now - 2 * DAY);

    // (d1) Process-files-only branch (scratch/x.md + HANDOFF.md)
    git(repo, ["checkout", "-b", "d-process-only", "main"]);
    mkdirSync(join(repo, "scratch"), { recursive: true });
    writeFileSync(join(repo, "scratch", "x.md"), "scratch\n");
    writeFileSync(join(repo, "HANDOFF.md"), "handoff\n");
    git(repo, ["add", "scratch/x.md", "HANDOFF.md"]);
    git(repo, ["commit", "-m", "process only"], { GIT_AUTHOR_DATE: isoSec(now - 3 * DAY), GIT_COMMITTER_DATE: isoSec(now - 3 * DAY) });
    git(repo, ["checkout", "main"]);
    ageBranchRef(repo, "d-process-only", now - 2 * DAY);

    // (d2) Empty commit branch
    git(repo, ["checkout", "-b", "d-empty", "main"]);
    git(repo, ["commit", "--allow-empty", "-m", "empty"], { GIT_AUTHOR_DATE: isoSec(now - 3 * DAY), GIT_COMMITTER_DATE: isoSec(now - 3 * DAY) });
    git(repo, ["checkout", "main"]);
    ageBranchRef(repo, "d-empty", now - 2 * DAY);

    // (7) 15-day-old unpushed branch without same-named remote -> bundle + verify + delete
    git(repo, ["checkout", "-b", "stale-15d", "main"]);
    writeFileSync(join(repo, "stale.ts"), "export const stale = 15;\n");
    git(repo, ["add", "stale.ts"]);
    git(repo, ["commit", "-m", "stale work"], { GIT_AUTHOR_DATE: isoSec(now - 15 * DAY), GIT_COMMITTER_DATE: isoSec(now - 15 * DAY) });
    const stale15Sha = git(repo, ["rev-parse", "HEAD"]);
    git(repo, ["checkout", "main"]);
    ageBranchRef(repo, "stale-15d", now - 15 * DAY);

    // --- Branches that MUST BE PRESERVED ---

    // Live worktree branch
    const liveWt = join(data, "sessions", "cl", "live", "workspace", "wt-live");
    mkdirSync(dirname(liveWt), { recursive: true });
    git(repo, ["worktree", "add", "-b", "keep-wt-live", liveWt, "main"]);
    ageBranchRef(repo, "keep-wt-live", now - 10 * DAY);

    // Locked worktree whose target dir is already gone
    const lockedWt = join(data, "sessions", "cl", "locked", "workspace", "wt-locked");
    mkdirSync(dirname(lockedWt), { recursive: true });
    git(repo, ["worktree", "add", "-b", "keep-wt-locked", lockedWt, "main"]);
    rmSync(lockedWt, { recursive: true, force: true });
    writeFileSync(join(repo, ".git", "worktrees", "wt-locked", "locked"), "archived\n");
    ageBranchRef(repo, "keep-wt-locked", now - 10 * DAY);

    // Too fresh (<24h) class-a branch (keeps its real fresh reflog at `now`)
    git(repo, ["branch", "keep-fresh-a", "main"]);

    // 13-day-old unpushed branch (< 14d)
    git(repo, ["checkout", "-b", "keep-unpushed-13d", "main"]);
    writeFileSync(join(repo, "recent13.ts"), "export const recent = 13;\n");
    git(repo, ["add", "recent13.ts"]);
    git(repo, ["commit", "-m", "13d work"], { GIT_AUTHOR_DATE: isoSec(now - 13 * DAY), GIT_COMMITTER_DATE: isoSec(now - 13 * DAY) });
    git(repo, ["checkout", "main"]);
    ageBranchRef(repo, "keep-unpushed-13d", now - 13 * DAY);

    // 15-day-old branch where remote has same-named branch with DIFFERENT content
    git(repo, ["checkout", "-b", "keep-diverged-15d", "main"]);
    writeFileSync(join(repo, "div.ts"), "remote version\n");
    git(repo, ["add", "div.ts"]);
    git(repo, ["commit", "-m", "remote div"], { GIT_AUTHOR_DATE: isoSec(now - 16 * DAY), GIT_COMMITTER_DATE: isoSec(now - 16 * DAY) });
    git(repo, ["push", "origin", "keep-diverged-15d"]);
    writeFileSync(join(repo, "div.ts"), "local diverged version\n");
    git(repo, ["add", "div.ts"]);
    git(repo, ["commit", "-m", "local div"], { GIT_AUTHOR_DATE: isoSec(now - 15 * DAY), GIT_COMMITTER_DATE: isoSec(now - 15 * DAY) });
    git(repo, ["checkout", "main"]);
    ageBranchRef(repo, "keep-diverged-15d", now - 15 * DAY);

    // Unpushed branch modifying src/a.ts + HANDOFF.md
    git(repo, ["checkout", "-b", "keep-mixed-src", "main"]);
    mkdirSync(join(repo, "src"), { recursive: true });
    writeFileSync(join(repo, "src", "a.ts"), "export const a = 1;\n");
    writeFileSync(join(repo, "HANDOFF.md"), "handoff\n");
    git(repo, ["add", "src/a.ts", "HANDOFF.md"]);
    git(repo, ["commit", "-m", "mixed"], { GIT_AUTHOR_DATE: isoSec(now - 3 * DAY), GIT_COMMITTER_DATE: isoSec(now - 3 * DAY) });
    git(repo, ["checkout", "main"]);
    ageBranchRef(repo, "keep-mixed-src", now - 2 * DAY);

    // Active clone in progress skips entire pass
    const skipped = await pruneAllRepoBranches(data, now, { clonesActive: () => true });
    assert.deepEqual(skipped, []);
    assert.equal(branchExists(repo, "a-on-remote"), true, "active clone skipped entire pass");

    // Track `git gc --auto` invocations
    let gcCalls = 0;
    const summaries = await pruneAllRepoBranches(data, now, {
      git: (dir, args, timeoutMs) => {
        if (args.includes("gc") && args.includes("--auto")) gcCalls++;
        return runRepoGit(dir, args, timeoutMs);
      },
    });
    assert.equal(summaries.length, 1);
    assert.equal(gcCalls, 0, "branch cleanup runs no gc: the upkeep round's keepAllSharedClonePacks does");
    const s = summaries[0]!;
    // Deleted branches are gone
    for (const gone of ["a-on-remote", "b-cherry", "c-squash", "d-process-only", "d-empty", "stale-15d"]) {
      assert.equal(branchExists(repo, gone), false, `expected deleted: ${gone}`);
    }

    // Protected / preserved branches remain (including main HEAD and symlinked external repo)
    for (const kept of ["main", "keep-wt-live", "keep-wt-locked", "keep-fresh-a", "keep-unpushed-13d", "keep-diverged-15d", "keep-mixed-src"]) {
      assert.equal(branchExists(repo, kept), true, `expected preserved: ${kept}`);
    }
    assert.equal(branchExists(extRepo, "ext-on-remote"), true, "symlinked external repo untouched");

    assert.equal(s.deletedRemote, 1);
    assert.equal(s.deletedCherry, 1);
    assert.equal(s.deletedMerged, 2); // c-squash + d-empty (merge-tree == default tree)
    assert.equal(s.deletedProcessOnly, 1);
    assert.equal(s.deletedStaleBundled, 1);
    assert.ok(s.bundlePath && existsSync(s.bundlePath), "bundle created");

    // Verify bundle, manifest .txt, and round-trip restore of stale-15d SHA
    git(repo, ["bundle", "verify", s.bundlePath!]);
    const txtPath = s.bundlePath!.replace(/\.bundle$/, ".txt");
    assert.ok(existsSync(txtPath), "bundle manifest .txt exists");
    const manifest = readFileSync(txtPath, "utf8");
    assert.ok(manifest.includes(`stale-15d ${stale15Sha}`), `manifest lists branch + sha: ${manifest}`);
    assert.ok(manifest.includes("git fetch "), "manifest includes restore command");
    git(repo, ["fetch", s.bundlePath!, "refs/heads/*:refs/heads/*"]);
    assert.equal(git(repo, ["rev-parse", "refs/heads/stale-15d"]), stale15Sha, "restored exact SHA from bundle");
    // Clean up restored branch for a 2nd pass
    git(repo, ["branch", "-D", "stale-15d"]);
    gcCalls = 0;
    await pruneAllRepoBranches(data, now, {
      git: (dir, args, timeoutMs) => {
        if (args.includes("gc") && args.includes("--auto")) gcCalls++;
        return runRepoGit(dir, args, timeoutMs);
      },
    });
    assert.equal(gcCalls, 0, "branch cleanup runs no gc");
  });

  test("bundle create failure preserves entire stale batch and leaves no partial bundle", async () => {
    const data = makeTemp("sf-bundle-fail-data-");
    const remotes = makeTemp("sf-bundle-fail-rem-");
    const now = 1_800_000_000_000;
    const repo = initCloneWithRemote(join(data, "repos", "bf"), join(remotes, "bf.git"), now);

    git(repo, ["checkout", "-b", "stale-fail", "main"]);
    writeFileSync(join(repo, "f.ts"), "export const f = 1;\n");
    git(repo, ["add", "f.ts"]);
    git(repo, ["commit", "-m", "stale fail"], { GIT_AUTHOR_DATE: isoSec(now - 20 * DAY), GIT_COMMITTER_DATE: isoSec(now - 20 * DAY) });
    git(repo, ["checkout", "main"]);
    ageBranchRef(repo, "stale-fail", now - 20 * DAY);

    const summaries = await pruneAllRepoBranches(data, now, {
      git: async (dir, args, timeoutMs) => {
        if (args[0] === "bundle" && args[1] === "create") {
          writeFileSync(args[2]!, "partial");
          return { ok: false, stdout: "" };
        }
        return runRepoGit(dir, args, timeoutMs);
      },
    });
    assert.equal(summaries[0]!.deletedStaleBundled, 0);
    assert.equal(branchExists(repo, "stale-fail"), true, "stale branch preserved on bundle create failure");
    const bundleDir = join(data, "repo-bundles", "bf");
    const left = existsSync(bundleDir) ? readdirSync(bundleDir) : [];
    assert.deepEqual(left, [], "partial bundle file removed");
  });

  test("Upkeep expires 31d repo-bundles, preserves 29d bundles, and runs repo branch cleanup at most once per day", async () => {
    const data = makeTemp("sf-upkeep-bundles-");
    const remotes = makeTemp("sf-upkeep-bundles-rem-");
    const baseNow = 1_800_000_000_000;
    const { clock, adjust } = testClock();
    await adjust(baseNow);

    const repo = initCloneWithRemote(join(data, "repos", "daily"), join(remotes, "daily.git"), baseNow);
    git(repo, ["branch", "old-a", "main"]);
    ageBranchRef(repo, "old-a", baseNow - 2 * DAY);

    const bDirOld = join(data, "repo-bundles", "gone-clone");
    const bDirFresh = join(data, "repo-bundles", "keep-clone");
    mkdirSync(bDirOld, { recursive: true });
    mkdirSync(bDirFresh, { recursive: true });
    const oldBundle = join(bDirOld, "2026-10-01T00-00-00Z.bundle");
    const oldTxt = join(bDirOld, "2026-10-01T00-00-00Z.txt");
    const freshBundle = join(bDirFresh, "2026-11-01T00-00-00Z.bundle");
    const freshTxt = join(bDirFresh, "2026-11-01T00-00-00Z.txt");
    writeFileSync(oldBundle, "old");
    writeFileSync(oldTxt, "old");
    writeFileSync(freshBundle, "fresh");
    writeFileSync(freshTxt, "fresh");
    setMtime(oldBundle, baseNow - 31 * DAY);
    setMtime(oldTxt, baseNow - 31 * DAY);
    setMtime(freshBundle, baseNow - 29 * DAY);
    setMtime(freshTxt, baseNow - 29 * DAY);

    const upkeep = new Upkeep({ data, clock });
    try {
      await upkeep.run();
      assert.equal(branchExists(repo, "old-a"), false, "1st round pruned old-a");
      assert.ok(!existsSync(oldBundle), "31d bundle deleted");
      assert.ok(!existsSync(oldTxt), "31d manifest deleted");
      assert.ok(!existsSync(bDirOld), "empty bundle subdir removed");
      assert.ok(existsSync(freshBundle), "29d bundle preserved");
      assert.ok(existsSync(freshTxt), "29d manifest preserved");

      // Create another eligible branch and run again 1 hour later -> skipped due to REPO_BRANCHES_EVERY_MS (24h)
      await adjust(HOUR);
      git(repo, ["branch", "second-a", "main"]);
      ageBranchRef(repo, "second-a", baseNow - 2 * DAY);
      await upkeep.run();
      assert.equal(branchExists(repo, "second-a"), true, "2nd round within 24h does not re-run branch cleanup");

      // Advance past 24h -> runs again and deletes second-a
      await adjust(REPO_BRANCHES_EVERY_MS);
      await upkeep.run();
      assert.equal(branchExists(repo, "second-a"), false, "round after 24h prunes second-a");
    } finally {
      await upkeep.close();
    }
  });
});

describe("PR B: relieveRepos relaxation (3d idle, process-file untracked, stale-branch bundling)", () => {
  test("relieveRepos reclaims clones with merged+15d stale branches (bundling first), process-only untracked, and >=3d idle", async () => {
    const baseNow = 1_800_000_000_000;
    const { clock, adjust } = testClock();
    await adjust(baseNow);
    const rig = new Rig({ clock });
    const remotesDir = makeTemp("sf-relieve-b-rem-");
    try {
      const reposDir = join(rig.dir, "repos");
      mkdirSync(reposDir, { recursive: true });
      const idle4d = baseNow - 4 * DAY;
      const idle2d = baseNow - 2 * DAY;

      // 1. Clone with a merged branch + a 15d stale unpushed branch (idle 4d) -> SHOULD BE RECLAIMED (stale bundled first!)
      const mergedAndStale = initCloneWithRemote(join(reposDir, "merged-and-stale"), join(remotesDir, "ms.git"), baseNow);
      git(mergedAndStale, ["checkout", "-b", "stale-15d", "main"]);
      writeFileSync(join(mergedAndStale, "s.ts"), "export const s = 1;\n");
      git(mergedAndStale, ["add", "s.ts"]);
      git(mergedAndStale, ["commit", "-m", "stale 15d"], { GIT_AUTHOR_DATE: isoSec(baseNow - 15 * DAY), GIT_COMMITTER_DATE: isoSec(baseNow - 15 * DAY) });
      const staleSha = git(mergedAndStale, ["rev-parse", "HEAD"]);
      git(mergedAndStale, ["checkout", "main"]);
      ageBranchRef(mergedAndStale, "stale-15d", baseNow - 15 * DAY);
      git(mergedAndStale, ["remote", "set-url", "origin", "https://github.com/example/ms.git"]);
      setRepoMtime(mergedAndStale, idle4d);

      // 2. Clone with a 13d unpushed branch (idle 4d) -> MUST NOT be reclaimed
      const unpushed13d = initCloneWithRemote(join(reposDir, "unpushed-13d"), join(remotesDir, "u13.git"), baseNow);
      git(unpushed13d, ["checkout", "-b", "wip-13d", "main"]);
      writeFileSync(join(unpushed13d, "w.ts"), "export const w = 13;\n");
      git(unpushed13d, ["add", "w.ts"]);
      git(unpushed13d, ["commit", "-m", "wip 13d"], { GIT_AUTHOR_DATE: isoSec(baseNow - 13 * DAY), GIT_COMMITTER_DATE: isoSec(baseNow - 13 * DAY) });
      git(unpushed13d, ["checkout", "main"]);
      ageBranchRef(unpushed13d, "wip-13d", baseNow - 13 * DAY);
      git(unpushed13d, ["remote", "set-url", "origin", "https://github.com/example/u13.git"]);
      setRepoMtime(unpushed13d, idle4d);

      // 3. Clone with untracked scratch/notes.md ONLY (idle 4d) -> SHOULD BE RECLAIMED
      const processUntracked = initCloneWithRemote(join(reposDir, "process-untracked"), join(remotesDir, "pu.git"), baseNow);
      mkdirSync(join(processUntracked, "scratch"), { recursive: true });
      writeFileSync(join(processUntracked, "scratch", "notes.md"), "temp notes\n");
      git(processUntracked, ["remote", "set-url", "origin", "https://github.com/example/pu.git"]);
      setRepoMtime(processUntracked, idle4d);

      // 4. Clone with untracked src/new.ts (idle 4d) -> MUST NOT be reclaimed
      const realUntracked = initCloneWithRemote(join(reposDir, "real-untracked"), join(remotesDir, "ru.git"), baseNow);
      mkdirSync(join(realUntracked, "src"), { recursive: true });
      writeFileSync(join(realUntracked, "src", "new.ts"), "export const n = 1;\n");
      git(realUntracked, ["remote", "set-url", "origin", "https://github.com/example/ru.git"]);
      setRepoMtime(realUntracked, idle4d);

      // 5. Clone idle 2 days (< 3d) -> MUST NOT be reclaimed
      const idle2 = initCloneWithRemote(join(reposDir, "idle-2d"), join(remotesDir, "i2.git"), baseNow);
      git(idle2, ["remote", "set-url", "origin", "https://github.com/example/i2.git"]);
      setRepoMtime(idle2, idle2d);

      // 6. Clone idle 4 days (>= 3d) -> SHOULD BE RECLAIMED
      const idle4 = initCloneWithRemote(join(reposDir, "idle-4d"), join(remotesDir, "i4.git"), baseNow);
      git(idle4, ["remote", "set-url", "origin", "https://github.com/example/i4.git"]);
      setRepoMtime(idle4, idle4d);

      // 7. Clone with an unpushed local tag pointing to a commit not on any remote (idle 4d) -> MUST NOT be reclaimed
      const unpushedTag = initCloneWithRemote(join(reposDir, "unpushed-tag"), join(remotesDir, "utag.git"), baseNow);
      git(unpushedTag, ["checkout", "--detach", "HEAD"]);
      writeFileSync(join(unpushedTag, "tag.ts"), "export const t = 1;\n");
      git(unpushedTag, ["add", "tag.ts"]);
      git(unpushedTag, ["commit", "-m", "tagged commit"], { GIT_AUTHOR_DATE: isoSec(baseNow - 20 * DAY), GIT_COMMITTER_DATE: isoSec(baseNow - 20 * DAY) });
      git(unpushedTag, ["tag", "v0.1-local"]);
      git(unpushedTag, ["checkout", "main"]);
      git(unpushedTag, ["remote", "set-url", "origin", "https://github.com/example/utag.git"]);
      setRepoMtime(unpushedTag, idle4d);

      const removed = await relieveRepos(rig.hub, () => DISK_LOW_BYTES - 1, DISK_LOW_BYTES, { full: true });
      assert.deepEqual(removed.sort(), ["idle-4d", "merged-and-stale", "process-untracked"]);

      assert.ok(!existsSync(mergedAndStale), "merged-and-stale reclaimed");
      assert.ok(!existsSync(processUntracked), "process-untracked reclaimed");
      assert.ok(!existsSync(idle4), "idle-4d reclaimed");
      assert.ok(existsSync(unpushed13d), "unpushed-13d preserved");
      assert.ok(existsSync(realUntracked), "real-untracked preserved");
      assert.ok(existsSync(idle2), "idle-2d preserved");
      assert.ok(existsSync(unpushedTag), "unpushed local tag clone preserved");

      // Stale branch from merged-and-stale was archived into <data>/repo-bundles/merged-and-stale/ before deletion!
      const bDir = join(rig.dir, "repo-bundles", "merged-and-stale");
      assert.ok(existsSync(bDir), "bundle dir created before clone deletion");
      const files = readdirSync(bDir);
      const bundle = files.find((f) => f.endsWith(".bundle"));
      const txt = files.find((f) => f.endsWith(".txt"));
      assert.ok(bundle && txt, `expected .bundle and .txt in ${bDir}, got ${files.join(", ")}`);
      assert.ok(readFileSync(join(bDir, txt!), "utf8").includes(`stale-15d ${staleSha}`));
    } finally {
      await rig.close();
    }
  });
});
