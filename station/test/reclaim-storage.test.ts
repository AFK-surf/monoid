// Reclaiming unneeded worktree registrations, exclusive transcripts, and unreferenced shared clones
// on session deletion, workspace emptying, upkeep, and low disk space.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { describe, test } from "node:test";
import { DISK_LOW_BYTES } from "../src/ops/disk.ts";
import { Upkeep, pruneRepoWorktrees, storageEntry } from "../src/ops/storage.ts";
import { emptyWorkspace, packWorkspace, packed } from "../src/sessions/archive.ts";
import { ColdRooms } from "../src/sessions/cold.ts";
import { REPO_IDLE_MS, archive, deleteSession, relieveRepos } from "../src/sessions/lifecycle.ts";
import { MANUAL, SESSION_PATHS_PAGE, TRANSCRIPT_REFERENCED } from "../src/store/store.ts";
import { UsageCounter } from "../src/usage/counter.ts";
import { keepCounted } from "../src/usage/module.ts";
import { Rig, testClock } from "./hub-fakes.ts";
import { tempDir } from "./temp-dir.ts";
import { claudeProject } from "./usage-counter-reference.ts";

function git(cwd: string, args: string[]): string {
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
    },
  }).trim();
}

function initRepo(dir: string, withBareRemote?: string, remoteUrl?: string): string {
  mkdirSync(dir, { recursive: true });
  git(dir, ["init", "-b", "main"]);
  writeFileSync(join(dir, "README.md"), "hello\n");
  git(dir, ["add", "README.md"]);
  git(dir, ["commit", "-m", "init"]);
  if (withBareRemote !== undefined) {
    mkdirSync(withBareRemote, { recursive: true });
    git(withBareRemote, ["init", "--bare"]);
    git(dir, ["remote", "add", "origin", withBareRemote]);
    git(dir, ["push", "-u", "origin", "main"]);
    if (remoteUrl !== undefined) {
      git(dir, ["remote", "set-url", "origin", remoteUrl]);
    }
  }
  return dir;
}

function setRepoMtime(repo: string, ms: number): void {
  const sec = ms / 1000;
  for (const rel of [".git/HEAD", ".git/FETCH_HEAD", ".git/index", ".git/logs/HEAD"]) {
    const p = join(repo, rel);
    if (existsSync(p)) utimesSync(p, sec, sec);
  }
}

describe("Item 1: exact worktree registration removal on deleteSession and emptyWorkspace", () => {
  test("deleteSession removes only the session's own registrations (in <data>/repos and external user repo) and preserves others", async () => {
    const rig = new Rig();
    const externalRoot = tempDir(join(tmpdir(), "ext-repo-"));
    try {
      const internalRepo = initRepo(join(rig.dir, "repos", "internal"));
      const userRepo = initRepo(join(externalRoot, "user-repo"));

      // Another stale worktree registration in userRepo (e.g. external drive gone) — MUST NOT be deleted!
      const externalStaleWt = join(externalRoot, "gone-external-wt");
      git(userRepo, ["worktree", "add", "-b", "ext-stale", externalStaleWt]);
      rmSync(externalStaleWt, { recursive: true, force: true });
      const extStaleAdmin = join(userRepo, ".git", "worktrees", "gone-external-wt");
      assert.ok(existsSync(extStaleAdmin));

      // Session 1 with worktrees in both internalRepo and userRepo, plus a foreign-locked worktree
      const room1 = join(rig.dir, "sessions", "cl", "s1");
      const ws1 = join(room1, "workspace");
      mkdirSync(ws1, { recursive: true });
      git(internalRepo, ["worktree", "add", "-b", "wt-s1-int", join(ws1, "int-wt")]);
      git(userRepo, ["worktree", "add", "-b", "wt-s1-user", join(ws1, "user-wt")]);
      git(internalRepo, ["worktree", "add", "-b", "wt-s1-foreign-lock", join(ws1, "locked-wt")]);
      const foreignLockAdmin = join(internalRepo, ".git", "worktrees", "locked-wt");
      writeFileSync(join(foreignLockAdmin, "locked"), "locked by user on purpose\n");

      rig.store.insertSession({
        key: "s1", connect: "cl", runtime: "claude", profile: "cc",
        workspace: ws1, runtimeSessionId: null, token: "tok-s1", createdAt: 1, lastActiveAt: 1,
      });

      // Session 2 archived & packed (locked by still.fail) — MUST NOT be touched when s1 is deleted
      const room2 = join(rig.dir, "sessions", "cl", "s2");
      const ws2 = join(room2, "workspace");
      mkdirSync(ws2, { recursive: true });
      git(internalRepo, ["worktree", "add", "-b", "wt-s2-archived", join(ws2, "s2-wt")]);
      await packWorkspace(room2);
      const s2Admin = join(internalRepo, ".git", "worktrees", "s2-wt");
      assert.ok(existsSync(join(s2Admin, "locked")));

      await deleteSession(rig.hub, "s1");

      assert.ok(!existsSync(room1), "s1 room removed");
      assert.ok(!existsSync(join(internalRepo, ".git", "worktrees", "int-wt")), "s1 internal worktree registration removed");
      assert.ok(!existsSync(join(userRepo, ".git", "worktrees", "user-wt")), "s1 user repo worktree registration removed");
      assert.ok(existsSync(extStaleAdmin), "unrelated stale registration in user repo MUST NOT be deleted");
      assert.ok(existsSync(foreignLockAdmin), "registration with foreign locked file MUST NOT be deleted");
      assert.ok(existsSync(s2Admin) && existsSync(join(s2Admin, "locked")), "archived session s2 locked registration MUST NOT be deleted");
      // Branches are untouched
      assert.ok(git(internalRepo, ["branch", "--list", "wt-s1-int"]).includes("wt-s1-int"), "branch untouched");
      assert.ok(git(userRepo, ["branch", "--list", "wt-s1-user"]).includes("wt-s1-user"), "user repo branch untouched");
    } finally {
      await rig.close();
    }
  });

  test("emptyWorkspace removes worktree registrations for both unpacked and packed workspaces", async () => {
    const data = tempDir(join(tmpdir(), "empty-wt-"));
    const repo = initRepo(join(data, "repos", "r"));

    // Packed workspace
    const roomPacked = join(data, "sessions", "cl", "packed");
    const wsPacked = join(roomPacked, "workspace");
    mkdirSync(wsPacked, { recursive: true });
    git(repo, ["worktree", "add", "-b", "b-packed", join(wsPacked, "wt-packed")]);
    await packWorkspace(roomPacked);
    assert.ok(existsSync(join(repo, ".git", "worktrees", "wt-packed", "locked")));
    await emptyWorkspace(roomPacked);
    assert.ok(!existsSync(join(repo, ".git", "worktrees", "wt-packed")), "packed worktree registration removed on emptyWorkspace");

    // Unpacked workspace
    const roomLive = join(data, "sessions", "cl", "live");
    const wsLive = join(roomLive, "workspace");
    mkdirSync(wsLive, { recursive: true });
    git(repo, ["worktree", "add", "-b", "b-live", join(wsLive, "wt-live")]);
    await emptyWorkspace(roomLive);
    assert.ok(!existsSync(join(repo, ".git", "worktrees", "wt-live")), "unpacked worktree registration removed on emptyWorkspace");
  });
});

describe("Item 2: Upkeep prunes stale <data>/repos worktree registrations", () => {
  test("Upkeep removes unlocked stale registrations pointing into <data>/sessions and preserves locked, live, external, and symlinked ones", async () => {
    const data = tempDir(join(tmpdir(), "upkeep-wt-"));
    const outside = tempDir(join(tmpdir(), "outside-wt-"));
    mkdirSync(join(data, "sessions", "cl", "live", "workspace"), { recursive: true });
    mkdirSync(join(data, "repos"), { recursive: true });

    const repo = initRepo(join(data, "repos", "r1"));
    const extRepo = initRepo(join(outside, "ext"));
    symlinkSync(extRepo, join(data, "repos", "linked-ext"));

    // 1. Stale registration pointing into <data>/sessions, unlocked -> SHOULD BE REMOVED
    const goneSessWt = join(data, "sessions", "cl", "gone", "workspace", "wt-stale");
    mkdirSync(dirname(goneSessWt), { recursive: true });
    git(repo, ["worktree", "add", "-b", "b-stale", goneSessWt]);
    rmSync(goneSessWt, { recursive: true, force: true });

    // 2. Stale registration pointing into <data>/sessions, LOCKED -> MUST STAY
    const lockedSessWt = join(data, "sessions", "cl", "archived", "workspace", "wt-locked");
    mkdirSync(dirname(lockedSessWt), { recursive: true });
    git(repo, ["worktree", "add", "-b", "b-locked", lockedSessWt]);
    rmSync(lockedSessWt, { recursive: true, force: true });
    writeFileSync(join(repo, ".git", "worktrees", "wt-locked", "locked"), "archived\n");

    // 3. Live registration pointing into <data>/sessions -> MUST STAY
    const liveSessWt = join(data, "sessions", "cl", "live", "workspace", "wt-live");
    git(repo, ["worktree", "add", "-b", "b-live", liveSessWt]);

    // 4. Stale registration pointing OUTSIDE <data>/sessions -> MUST STAY
    const userWt = join(outside, "user-wt");
    git(repo, ["worktree", "add", "-b", "b-user", userWt]);
    rmSync(userWt, { recursive: true, force: true });

    // 5. Stale registration in symlinked repo pointing into <data>/sessions -> MUST STAY (repos entry is a symlink)
    const linkedWt = join(data, "sessions", "cl", "gone2", "workspace", "wt-linked");
    mkdirSync(dirname(linkedWt), { recursive: true });
    git(extRepo, ["worktree", "add", "-b", "b-linked", linkedWt]);
    rmSync(linkedWt, { recursive: true, force: true });

    const upkeep = new Upkeep({ data });
    await upkeep.run();
    await upkeep.close();

    assert.ok(!existsSync(join(repo, ".git", "worktrees", "wt-stale")), "stale unlocked registration under <data>/sessions removed");
    assert.ok(existsSync(join(repo, ".git", "worktrees", "wt-locked")), "locked registration preserved");
    assert.ok(existsSync(join(repo, ".git", "worktrees", "wt-live")), "live registration preserved");
    assert.ok(existsSync(join(repo, ".git", "worktrees", "user-wt")), "external worktree registration preserved");
    assert.ok(existsSync(join(extRepo, ".git", "worktrees", "wt-linked")), "symlinked repo in <data>/repos not touched");
  });
});

describe("Item 3: deleteSession deletes exclusive transcripts, preserves shared/user transcripts and usage spend", () => {
  test("TRANSCRIPT_REFERENCED uses indexes and matches archived sessions too", async () => {
    const rig = new Rig();
    try {
      const insert = (key: string, runtime: string, id: string) => {
        rig.store.insertSession({
          key, connect: "cl", runtime, profile: runtime === "claude" ? "cc" : "cx",
          workspace: rig.dir, runtimeSessionId: id, token: key, createdAt: 1, lastActiveAt: 1,
        });
      };
      insert("s1", "claude", "shared-id");
      rig.store.ranIn("s1", "shared-id", "cc");
      insert("s2", "claude", "shared-id");
      rig.store.ranIn("s2", "shared-id", "cc");
      rig.store.setArchived("s2", true, MANUAL);

      const plan = (rig.store.db.prepare(`EXPLAIN QUERY PLAN ${TRANSCRIPT_REFERENCED}`).all("shared-id", "claude", "s1") as { detail: string }[])
        .map((step) => step.detail);
      assert.ok(plan.some((step) => step.includes("SEARCH r USING INDEX runtime_sessions_by_id")), plan.join(" | "));
      assert.ok(plan.some((step) => step.includes("SEARCH s USING INDEX sessions_by_runtime_id")), plan.join(" | "));

      assert.equal(rig.store.transcriptReferenced("claude", "shared-id", "s1"), true, "archived session still references transcript");
      assert.equal(rig.store.transcriptReferenced("codex", "shared-id", "s1"), false, "different runtime does not reference it");
      rig.store.deleteSession("s2");
      assert.equal(rig.store.transcriptReferenced("claude", "shared-id", "s1"), false, "no other session references it after s2 is deleted");
    } finally {
      await rig.close();
    }
  });

  test("deleteSession removes exclusive transcripts (.jsonl, .zst, Claude subagents) and preserves archived-shared and external profile home transcripts", async () => {
    let rig!: Rig;
    const cold = new ColdRooms(() => rig.hub);
    rig = new Rig({ cold });
    const userHome = tempDir(join(tmpdir(), "user-profile-home-"));
    try {
      // Add a user profile whose home is OUTSIDE <data>
      rig.config.profiles.push({
        ...rig.config.profiles[0]!, id: "user-cc", name: "User CC", home: userHome,
      });

      const mkWs = (k: string) => {
        const ws = join(rig.dir, "sessions", "cl", k, "workspace");
        mkdirSync(ws, { recursive: true });
        return ws;
      };

      // 1. Exclusive session with raw .jsonl + Claude subagent .jsonl + packed .zst
      const ws1 = mkWs("exclusive");
      rig.store.insertSession({
        key: "exclusive", connect: "cl", runtime: "claude", profile: "cc",
        workspace: ws1, runtimeSessionId: "ex-1", token: "tok-ex", createdAt: 1, lastActiveAt: 1,
      });
      rig.store.ranIn("exclusive", "ex-1", "cc");
      const exDir = join(rig.config.profiles[0]!.home, "projects", "p1");
      mkdirSync(join(exDir, "ex-1", "subagents"), { recursive: true });
      mkdirSync(join(exDir, "ex-1", "tool-results"), { recursive: true });
      const exMain = join(exDir, "ex-1.jsonl");
      const exSub = join(exDir, "ex-1", "subagents", "sub1.jsonl");
      const exSubPacked = packed(join(exDir, "ex-1", "subagents", "sub2.jsonl"));
      const exToolResult = join(exDir, "ex-1", "tool-results", "x.txt");
      writeFileSync(exMain, '{"type":"user","message":{"content":"hi"}}\n');
      writeFileSync(exSub, '{"type":"user","message":{"content":"sub"}}\n');
      writeFileSync(exSubPacked, "zst-bytes");
      writeFileSync(exToolResult, "tool result output\n");

      // 2. Shared transcript with another ARCHIVED session -> MUST NOT be deleted
      const ws2a = mkWs("shared-a");
      const ws2b = mkWs("shared-b");
      rig.store.insertSession({
        key: "shared-a", connect: "cl", runtime: "claude", profile: "cc",
        workspace: ws2a, runtimeSessionId: "sh-1", token: "tok-sha", createdAt: 1, lastActiveAt: 1,
      });
      rig.store.ranIn("shared-a", "sh-1", "cc");
      rig.store.insertSession({
        key: "shared-b", connect: "cl", runtime: "claude", profile: "cc",
        workspace: ws2b, runtimeSessionId: "sh-1", token: "tok-shb", createdAt: 1, lastActiveAt: 1,
      });
      rig.store.ranIn("shared-b", "sh-1", "cc");
      rig.store.setArchived("shared-b", true, MANUAL);
      const shMain = join(exDir, "sh-1.jsonl");
      writeFileSync(shMain, '{"type":"user","message":{"content":"shared"}}\n');

      // 3. Transcript in user's own profile home OUTSIDE <data> -> MUST NOT be deleted
      const ws3 = mkWs("user-prof");
      rig.store.insertSession({
        key: "user-prof", connect: "cl", runtime: "claude", profile: "user-cc",
        workspace: ws3, runtimeSessionId: "user-1", token: "tok-u", createdAt: 1, lastActiveAt: 1,
      });
      rig.store.ranIn("user-prof", "user-1", "user-cc");
      const userTranscript = join(userHome, "projects", "u", "user-1.jsonl");
      mkdirSync(dirname(userTranscript), { recursive: true });
      writeFileSync(userTranscript, '{"type":"user","message":{"content":"mine"}}\n');

      await deleteSession(rig.hub, "exclusive");
      assert.ok(!existsSync(exMain), "exclusive main transcript deleted");
      assert.ok(!existsSync(exSub), "exclusive Claude subagent transcript deleted");
      assert.ok(!existsSync(exSubPacked), "exclusive packed .zst transcript deleted");
      assert.ok(!existsSync(exToolResult), "exclusive Claude tool-results file deleted");
      assert.ok(!existsSync(join(exDir, "ex-1")), "exclusive Claude session directory removed recursively");

      await deleteSession(rig.hub, "shared-a");
      assert.ok(existsSync(shMain), "transcript shared with archived session MUST NOT be deleted");

      await deleteSession(rig.hub, "user-prof");
      assert.ok(existsSync(userTranscript), "transcript in external user profile home MUST NOT be deleted");
    } finally {
      await rig.close();
    }
  });

  test("deleteSession flushes unread usage tail before deleting transcript and keeps workspace spend", async () => {
    const time = testClock();
    const at = Date.parse("2026-11-19T10:00:00.000Z");
    await time.adjust(at);
    const rig = new Rig({ clock: time.clock });
    const counter = new UsageCounter({
      store: rig.store,
      config: () => ({ dataDir: rig.dir, profiles: rig.config.profiles }),
      clock: time.clock,
    });
    const unsub = keepCounted(rig.store, rig.hub.live, counter);
    try {
      // Prime the counter's install timestamp (as start() does on a real station).
      await counter.read();
      await time.adjust(1_000);
      const ws = join(rig.dir, "sessions", "cl", "u1", "workspace");
      mkdirSync(ws, { recursive: true });
      rig.store.insertSession({
        key: "u1", connect: "cl", runtime: "claude", profile: "cc",
        workspace: ws, runtimeSessionId: "usage-tail-1", token: "tok-u1", createdAt: rig.store.now(), lastActiveAt: rig.store.now(),
      });
      rig.store.ranIn("u1", "usage-tail-1", "cc");
      rig.store.startTurn("t1", "u1", "input");
      const tPath = join(rig.dir, "transcripts", "claude", claudeProject(ws), "usage-tail-1.jsonl");
      mkdirSync(dirname(tPath), { recursive: true });
      writeFileSync(tPath, JSON.stringify({
        type: "assistant",
        timestamp: new Date(rig.store.now()).toISOString(),
        isSidechain: false,
        message: {
          id: "msg_tail_1",
          model: "claude-sonnet-4-5-20250929",
          usage: { input_tokens: 1200, output_tokens: 300 },
        },
      }) + "\n");

      // Note: the tail has NOT been read by counter yet!
      await deleteSession(rig.hub, "u1");
      assert.ok(!existsSync(tPath), "exclusive transcript deleted after flush");

      const rows = rig.store.db.prepare("SELECT input, output FROM usage WHERE session = ?").all("u1") as { input: number; output: number }[];
      assert.equal(rows.length, 1, "unread usage tail was flushed before transcript deletion");
      assert.equal(rows[0]!.input, 1200);
      assert.equal(rows[0]!.output, 300);
    } finally {
      unsub();
      await counter.stop();
      await rig.close();
    }
  });
});

describe("Item 4: low-disk reclamation of unreferenced shared clones", () => {
  test("STORAGE_MANIFEST lists repos as session-bound with low-disk reclaim", () => {
    const entry = storageEntry("repos");
    assert.ok(entry);
    assert.equal(entry.class, "session-bound");
    assert.ok(entry.reclaim && entry.reclaim.includes("relieveRepos"), `reclaim: ${entry.reclaim}`);
  });

  test("SESSION_PATHS_PAGE uses primary key index", async () => {
    const rig = new Rig();
    try {
      const plan = (rig.store.db.prepare(`EXPLAIN QUERY PLAN ${SESSION_PATHS_PAGE}`).all("", 200) as { detail: string }[])
        .map((step) => step.detail);
      assert.ok(plan.some((step) => step.includes("USING INDEX") || step.includes("USING PRIMARY KEY")), plan.join(" | "));
    } finally {
      await rig.close();
    }
  });

  test("relieveRepos reclaims only eligible old clones (oldest first, stops at low mark) and preserves all counterexamples", async () => {
    const baseNow = 1_800_000_000_000;
    const { clock, adjust } = testClock();
    await adjust(baseNow);
    const rig = new Rig({ clock });
    const remotesDir = tempDir(join(tmpdir(), "remotes-"));
    const outsideDir = tempDir(join(tmpdir(), "outside-clone-"));
    try {
      const reposDir = join(rig.dir, "repos");
      mkdirSync(reposDir, { recursive: true });
      const oldMs = baseNow - REPO_IDLE_MS - 10 * 24 * 3_600_000;
      const olderMs = baseNow - REPO_IDLE_MS - 20 * 24 * 3_600_000;
      const freshMs = baseNow - REPO_IDLE_MS + 3_600_000;

      // Eligible #1 (oldest) — SHOULD BE DELETED FIRST
      const eligibleOldest = initRepo(join(reposDir, "eligible-oldest"), join(remotesDir, "e1.git"), "https://github.com/example/e1.git");
      setRepoMtime(eligibleOldest, olderMs);

      // Eligible #2 (second oldest) — SHOULD BE DELETED ONLY IF STILL BELOW LOW
      const eligibleSecond = initRepo(join(reposDir, "eligible-second"), join(remotesDir, "e2.git"), "https://github.com/example/e2.git");
      setRepoMtime(eligibleSecond, oldMs);

      // Counterexample A: unpushed commit on branch
      const unpushed = initRepo(join(reposDir, "unpushed"), join(remotesDir, "unpushed.git"), "https://github.com/example/unpushed.git");
      writeFileSync(join(unpushed, "local.txt"), "unpushed\n");
      git(unpushed, ["add", "local.txt"]);
      git(unpushed, ["commit", "-m", "local only"]);
      setRepoMtime(unpushed, olderMs);

      // Counterexample A2: unpushed commit on detached HEAD
      const detachedUnpushed = initRepo(join(reposDir, "detached-unpushed"), join(remotesDir, "detached.git"), "https://github.com/example/detached.git");
      git(detachedUnpushed, ["checkout", "--detach", "HEAD"]);
      writeFileSync(join(detachedUnpushed, "detached.txt"), "detached commit\n");
      git(detachedUnpushed, ["add", "detached.txt"]);
      git(detachedUnpushed, ["commit", "-m", "detached only"]);
      setRepoMtime(detachedUnpushed, olderMs);

      // Counterexample B: refs/stash
      const stashed = initRepo(join(reposDir, "stashed"), join(remotesDir, "stashed.git"), "https://github.com/example/stashed.git");
      writeFileSync(join(stashed, "README.md"), "dirty\n");
      git(stashed, ["stash", "push", "-m", "wip"]);
      setRepoMtime(stashed, olderMs);

      // Counterexample C: untracked file (including when repo sets status.showUntrackedFiles=no)
      const untracked = initRepo(join(reposDir, "untracked"), join(remotesDir, "untracked.git"), "https://github.com/example/untracked.git");
      git(untracked, ["config", "status.showUntrackedFiles", "no"]);
      writeFileSync(join(untracked, "untracked.txt"), "hello\n");
      setRepoMtime(untracked, olderMs);

      // Counterexample D: no remote
      const noRemote = initRepo(join(reposDir, "no-remote"));
      setRepoMtime(noRemote, olderMs);

      // Counterexample D2: local path remote & file: remote (not recoverable from elsewhere)
      const localPathRemote = initRepo(join(reposDir, "local-path-remote"), join(remotesDir, "local.git"));
      setRepoMtime(localPathRemote, olderMs);
      const fileUrlRemote = initRepo(join(reposDir, "file-url-remote"), join(remotesDir, "fileurl.git"), `file://${join(remotesDir, "fileurl.git")}`);
      setRepoMtime(fileUrlRemote, olderMs);

      // Counterexample E: locked worktree (archived session)
      const lockedWtRepo = initRepo(join(reposDir, "locked-wt"), join(remotesDir, "locked-wt.git"), "https://github.com/example/locked-wt.git");
      const archWtPath = join(rig.dir, "sessions", "cl", "arch", "workspace", "wt");
      mkdirSync(dirname(archWtPath), { recursive: true });
      git(lockedWtRepo, ["worktree", "add", "-b", "b-arch", archWtPath]);
      rmSync(archWtPath, { recursive: true, force: true });
      writeFileSync(join(lockedWtRepo, ".git", "worktrees", "wt", "locked"), "archived\n");
      setRepoMtime(lockedWtRepo, olderMs);

      // Counterexample F: referenced by a preset (in joined workspace)
      const presetRepo = initRepo(join(reposDir, "preset-repo"), join(remotesDir, "preset.git"), "https://github.com/example/preset.git");
      const joinedHome = join(rig.config.agentHome, "workspaces", "ws-joined");
      mkdirSync(joinedHome, { recursive: true });
      writeFileSync(join(joinedHome, "presets.json"), JSON.stringify({
        presets: [{ id: "p1", name: "P1", dirs: [{ path: join(presetRepo, "sub"), repo: null }], instructions: "" }],
        gone: [],
      }));
      setRepoMtime(presetRepo, olderMs);

      // Counterexample F2: referenced only by an unarchived session's .stillfail-preset.json copy (preset deleted, cwd null)
      const presetCopyRepo = initRepo(join(reposDir, "preset-copy-repo"), join(remotesDir, "pcopy.git"), "https://github.com/example/pcopy.git");
      const liveCopyWs = join(rig.dir, "sessions", "cl", "s-preset-copy", "workspace");
      mkdirSync(liveCopyWs, { recursive: true });
      writeFileSync(join(liveCopyWs, ".stillfail-preset.json"), JSON.stringify({
        id: "old-preset", name: "Deleted Preset", dirs: [{ path: presetCopyRepo, repo: null }], instructions: "",
      }));
      rig.store.insertSession({
        key: "s-preset-copy", connect: "cl", runtime: "claude", profile: "cc",
        workspace: liveCopyWs, cwd: null, runtimeSessionId: null, token: "tok-pcopy", createdAt: 1, lastActiveAt: 1,
      });
      setRepoMtime(presetCopyRepo, olderMs);

      // Counterexample G: referenced by an archived session's cwd
      const sessionRepo = initRepo(join(reposDir, "session-repo"), join(remotesDir, "session.git"), "https://github.com/example/session.git");
      rig.store.insertSession({
        key: "s-using-repo", connect: "cl", runtime: "claude", profile: "cc",
        workspace: join(rig.dir, "sessions", "cl", "s-using-repo", "workspace"),
        cwd: sessionRepo, runtimeSessionId: null, token: "tok-sr", createdAt: 1, lastActiveAt: 1,
      });
      rig.store.setArchived("s-using-repo", true, MANUAL);
      setRepoMtime(sessionRepo, olderMs);

      // Counterexample H: referenced by an unfinished job's cwd
      const jobRepo = initRepo(join(reposDir, "job-repo"), join(remotesDir, "job.git"), "https://github.com/example/job.git");
      rig.store.insertJob({
        id: "job-1", sessionKey: "s-using-repo", name: "build", command: "sleep 1",
        cwd: jobRepo, port: null, token: "tok-job-1", state: "running", pgid: null,
        exitCode: null, startedAt: 1, endedAt: null, restarts: 0,
        log: join(rig.dir, "jobs", "job-1.log"), watch: false,
      });
      setRepoMtime(jobRepo, olderMs);

      // Counterexample I: listed in move/repos.json
      const moveRepo = initRepo(join(reposDir, "move-repo"), join(remotesDir, "move.git"), "https://github.com/example/move.git");
      mkdirSync(join(rig.dir, "move"), { recursive: true });
      writeFileSync(join(rig.dir, "move", "repos.json"), JSON.stringify({
        "https://example.com/move.git": { dir: moveRepo, made: true },
      }));
      setRepoMtime(moveRepo, olderMs);

      // Counterexample J: recently touched (< 14 days)
      const freshRepo = initRepo(join(reposDir, "fresh-repo"), join(remotesDir, "fresh.git"), "https://github.com/example/fresh.git");
      setRepoMtime(freshRepo, freshMs);

      // Counterexample K: symlink pointing outside <data>
      const externalTarget = initRepo(join(outsideDir, "real-ext"), join(remotesDir, "ext.git"), "https://github.com/example/ext.git");
      setRepoMtime(externalTarget, olderMs);
      symlinkSync(externalTarget, join(reposDir, "symlink-ext"));

      // Counterexample L: .cloning-* temp dir
      const cloningDir = initRepo(join(reposDir, ".cloning-abc"), join(remotesDir, "cloning.git"), "https://github.com/example/cloning.git");
      setRepoMtime(cloningDir, olderMs);

      // First call: free() is below low for 1 deletion, then >= low -> should delete ONLY eligible-oldest!
      let freeVal = DISK_LOW_BYTES - 1;
      const gone1 = await relieveRepos(rig.hub, () => {
        const cur = freeVal;
        if (!existsSync(eligibleOldest)) freeVal = DISK_LOW_BYTES;
        return cur;
      }, DISK_LOW_BYTES);
      assert.deepEqual(gone1, ["eligible-oldest"]);
      assert.ok(!existsSync(eligibleOldest), "oldest eligible clone deleted");
      assert.ok(existsSync(eligibleSecond), "stopped once free >= low");

      // Second call: still below low -> deletes eligible-second, and NONE of the counterexamples!
      const gone2 = await relieveRepos(rig.hub, () => DISK_LOW_BYTES - 1, DISK_LOW_BYTES);
      assert.deepEqual(gone2, ["eligible-second"]);
      assert.ok(!existsSync(eligibleSecond));
      // Check .cloning-abc before starting a new clone (Clones.#sweep cleans unfinished .cloning-* on first clone start).
      assert.ok(existsSync(cloningDir), "relieveRepos MUST NOT delete .cloning-* temp dir");

      // Counterexample M: git command failure / timeout treats eligible clone as ineligible
      const gitFailRepo = initRepo(join(reposDir, "git-fail-repo"), join(remotesDir, "git-fail.git"), "https://github.com/example/git-fail.git");
      setRepoMtime(gitFailRepo, olderMs);
      const goneFail = await relieveRepos(rig.hub, () => DISK_LOW_BYTES - 1, DISK_LOW_BYTES, {
        git: async () => ({ ok: false, stdout: "" }),
      });
      assert.deepEqual(goneFail, []);
      assert.ok(existsSync(gitFailRepo), "clone preserved when git check fails or times out");

      // Counterexample M2: corrupted presets.json aborts the whole round (deletes nothing)
      const corruptPresetsPath = join(rig.config.agentHome, "presets.json");
      writeFileSync(corruptPresetsPath, "{not valid json");
      const goneCorruptPresets = await relieveRepos(rig.hub, () => DISK_LOW_BYTES - 1, DISK_LOW_BYTES);
      assert.deepEqual(goneCorruptPresets, []);
      assert.ok(existsSync(gitFailRepo), "corrupted presets.json aborts entire round");
      rmSync(corruptPresetsPath, { force: true });

      // Counterexample M3: repo touched during git checks is skipped on re-check before rm
      const touchedDuringGit = initRepo(join(reposDir, "touched-during-git"), join(remotesDir, "touched.git"), "https://github.com/example/touched.git");
      setRepoMtime(touchedDuringGit, olderMs);
      const goneTouched = await relieveRepos(rig.hub, () => DISK_LOW_BYTES - 1, DISK_LOW_BYTES, {
        git: async (dir, args) => {
          if (dir !== realpathSync(touchedDuringGit)) return { ok: false, stdout: "" };
          if (args.includes("status")) {
            setRepoMtime(touchedDuringGit, baseNow);
          }
          return {
            ok: true,
            stdout: args[0] === "remote" && args.length === 1 ? "origin\n"
              : args[0] === "remote" ? "https://github.com/example/touched.git\n"
              : args[0] === "rev-list" ? "0\n"
              : "",
          };
        },
      });
      assert.ok(!goneTouched.includes("touched-during-git"), "repo touched during git checks is skipped");
      assert.ok(existsSync(touchedDuringGit), "repo touched during git checks MUST NOT be deleted");

      // Counterexample N: active clone in progress prevents reclamation
      const activeRepo = initRepo(join(reposDir, "while-cloning"), join(remotesDir, "while-cloning.git"), "https://github.com/example/while-cloning.git");
      setRepoMtime(activeRepo, olderMs);
      // Force active state via custom Clones run that never finishes during relieveRepos
      let releaseClone!: () => void;
      const origRun = (rig.hub.clones as any).run;
      (rig.hub.clones as any).run = () => ({ done: new Promise((r) => { releaseClone = () => r({ ok: false, stderr: "cancelled" }); }), kill: () => releaseClone() });
      const started = await rig.hub.clones.start(null, "owner/in-progress", "test@example.com");
      assert.equal(started.state, "cloning");
      const goneWhileCloning = await relieveRepos(rig.hub, () => DISK_LOW_BYTES - 1, DISK_LOW_BYTES);
      assert.deepEqual(goneWhileCloning, []);
      assert.ok(existsSync(activeRepo), "clone preserved while another clone is in progress");
      if (started.state === "cloning") rig.hub.clones.drop(null, started.id);
      (rig.hub.clones as any).run = origRun;

      for (const kept of [
        unpushed, detachedUnpushed, stashed, untracked, noRemote, localPathRemote, fileUrlRemote, lockedWtRepo, presetRepo, presetCopyRepo,
        sessionRepo, jobRepo, moveRepo, freshRepo, join(reposDir, "symlink-ext"), externalTarget, touchedDuringGit, activeRepo,
      ]) {
        assert.ok(existsSync(kept), `MUST NOT be deleted: ${kept}`);
      }
    } finally {
      await rig.close();
    }
  });
});

describe("Item 5: deleteSession never removes directories outside <data>/sessions", () => {
  test("workspace outside <data>/sessions or symlink pointing outside is preserved on deleteSession", async () => {
    const rig = new Rig();
    const userDir = tempDir(join(tmpdir(), "user-project-"));
    const userFile = join(userDir, "important.txt");
    writeFileSync(userFile, "do not delete\n");
    try {
      // Direct external workspace (e.g. continued machine session)
      rig.store.insertSession({
        key: "ext-ws", connect: "cl", runtime: "claude", profile: "cc",
        workspace: userDir, runtimeSessionId: null, token: "tok-ext", createdAt: 1, lastActiveAt: 1,
      });
      await deleteSession(rig.hub, "ext-ws");
      assert.equal(rig.store.getSession("ext-ws"), null, "session row deleted");
      assert.ok(existsSync(userFile), "external workspace directory MUST NOT be deleted");

      // Symlink inside <data>/sessions pointing to external directory
      const linkParent = join(rig.dir, "sessions", "cl", "sym-ws");
      mkdirSync(linkParent, { recursive: true });
      const symWs = join(linkParent, "workspace");
      symlinkSync(userDir, symWs);
      rig.store.insertSession({
        key: "sym-ws", connect: "cl", runtime: "claude", profile: "cc",
        workspace: symWs, runtimeSessionId: null, token: "tok-sym", createdAt: 1, lastActiveAt: 1,
      });
      await deleteSession(rig.hub, "sym-ws");
      assert.equal(rig.store.getSession("sym-ws"), null, "symlink session row deleted");
      assert.ok(existsSync(userFile), "target of symlinked workspace outside <data>/sessions MUST NOT be deleted");
    } finally {
      await rig.close();
    }
  });
});
