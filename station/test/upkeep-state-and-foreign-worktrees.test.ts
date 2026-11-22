// Tests for persistent upkeep state (<data>/upkeep-state.json) across restarts and foreign locked worktree pruning.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, test } from "node:test";
import { ARCHIVE_WORKTREE_LOCK_PREFIX } from "../src/sessions/archive.ts";
import { ColdRooms } from "../src/sessions/cold.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { Hub } from "../src/sessions/hub.ts";
import {
  ARCHIVE_UPKEEP_EVERY_MS,
  ARCHIVE_UPKEEP_STARTUP_GRACE_MS,
  IDLE_REBUILD_MS,
  cleanIdleRebuildable,
  runArchiveUpkeepIfDue,
} from "../src/sessions/lifecycle.ts";
import {
  REPO_BRANCHES_EVERY_MS,
  Upkeep,
  pruneRepoWorktrees,
  storageEntry,
} from "../src/ops/storage.ts";
import { UPKEEP_STATE_FILE, patchUpkeepState, readUpkeepState } from "../src/ops/upkeep-state.ts";
import { Store } from "../src/store/store.ts";
import { settle, testClock } from "./hub-fakes.ts";

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `upkeep-fix-${what}-`));
  dirs.push(dir);
  return dir;
};

after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function git(cwd: string, args: string[], envExtra?: Record<string, string>): string {
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
      ...envExtra,
    },
  }).trim();
}

function branchExists(repo: string, name: string): boolean {
  try {
    git(repo, ["show-ref", "--verify", "--quiet", `refs/heads/${name}`]);
    return true;
  } catch {
    return false;
  }
}

describe("Item 1: persistent idleMeasured & lastArchiveUpkeepAt in <data>/upkeep-state.json", () => {
  test("upkeep-state.json is registered in STORAGE_MANIFEST as bounded-ephemeral", () => {
    const entry = storageEntry(UPKEEP_STATE_FILE);
    assert.ok(entry !== undefined);
    assert.equal(entry.class, "bounded-ephemeral");
  });

  test("40 idle sessions: round 1 measures first 16 -> hub rebuild -> round 2 measures next 16; startup grace 60s honors persisted lastArchiveUpkeepAt", async () => {
    const tc = testClock();
    await tc.adjust(1_800_000_000_000);
    const data = fresh("idle-40");
    const dbPath = join(data, "stillfail.db");
    const HOUR = 3_600_000;

    const measuredRound1: string[] = [];
    const measuredRound2: string[] = [];

    const makeHub = (bucket: string[]) => {
      const store = Store.open(dbPath, null, tc.clock);
      const cfg = hubConfig(
        {
          profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }],
          connects: [{ id: "cl", slack: { botName: "Claude bot" }, bind: { runtime: "claude" } }],
        },
        data,
      );
      let coldRooms!: ColdRooms;
      const hub = new Hub({
        config: () => cfg,
        store,
        chats: () => undefined,
        drivers: [],
        mcpUrl: "http://127.0.0.1:0/mcp",
        clock: tc.clock,
        cold: {
          isCold: (key) => coldRooms.isCold(key),
          restore: (key) => coldRooms.restore(key),
          pack: (key) => coldRooms.pack(key),
          needsPack: (key) => coldRooms.needsPack(key),
          cleanIdleRebuildable: async (key) => {
            const res = await coldRooms.cleanIdleRebuildable(key);
            if (res !== null) bucket.push(key);
            return res;
          },
        },
      });
      coldRooms = new ColdRooms(() => hub);
      return {
        hub,
        store,
        close: async () => {
          await hub.shutdown();
          store.close();
        },
      };
    };

    // Seed 40 idle unarchived sessions (>24h idle), ordered s-00 (oldest) .. s-39 (newest).
    const r1 = makeHub(measuredRound1);
    const t0 = r1.hub.now();
    const workspaces: string[] = [];
    for (let i = 0; i < 40; i++) {
      const key = `s-${String(i).padStart(2, "0")}`;
      const ws = join(data, "sessions", "cl", key, "workspace");
      mkdirSync(join(ws, "node_modules", "pkg"), { recursive: true });
      writeFileSync(join(ws, "node_modules", "pkg", "index.js"), "module.exports = 1;\n");
      writeFileSync(join(ws, "src.ts"), `export const n = ${i};\n`);
      const activeAt = t0 - (48 * HOUR) + i * 1_000;
      r1.store.insertSession({
        key, connect: "cl", runtime: "claude", profile: "cc",
        workspace: ws, runtimeSessionId: null, token: `tok-${key}`, createdAt: activeAt, lastActiveAt: activeAt,
      });
      workspaces.push(ws);
    }

    // Startup at t0: skipped within 60s startup grace
    assert.equal(await runArchiveUpkeepIfDue(r1.hub, r1.hub.now()), false, "skipped at startup t0");
    await tc.adjust(ARCHIVE_UPKEEP_STARTUP_GRACE_MS - 1_000);
    assert.equal(await runArchiveUpkeepIfDue(r1.hub, r1.hub.now()), false, "skipped at +59s");

    // At +60s: first round runs and measures s-00..s-15
    await tc.adjust(1_000);
    assert.equal(await runArchiveUpkeepIfDue(r1.hub, r1.hub.now()), true, "runs after 60s startup grace");
    assert.equal(measuredRound1.length, 16);
    assert.deepEqual(
      measuredRound1,
      Array.from({ length: 16 }, (_, i) => `s-${String(i).padStart(2, "0")}`),
    );
    const stateFile = join(data, UPKEEP_STATE_FILE);
    assert.ok(existsSync(stateFile), "upkeep-state.json persisted");
    const saved1 = JSON.parse(readFileSync(stateFile, "utf8"));
    assert.equal(Object.keys(saved1.idleMeasured).length, 16);
    assert.equal(saved1.lastArchiveUpkeepAt, r1.hub.now());
    await r1.close();

    // Advance 10 minutes (simulating process restart 10m after last upkeep) and rebuild a fresh Hub
    await tc.adjust(ARCHIVE_UPKEEP_EVERY_MS);
    const r2 = makeHub(measuredRound2);

    // Immediately at restart (+0s): startup grace prevents burst
    assert.equal(await runArchiveUpkeepIfDue(r2.hub, r2.hub.now()), false, "skipped immediately after restart");

    // At +60s after restart (NOT +10m!): persisted lastArchiveUpkeepAt is >=10m old, so it runs and measures s-16..s-31
    await tc.adjust(ARCHIVE_UPKEEP_STARTUP_GRACE_MS);
    assert.equal(await runArchiveUpkeepIfDue(r2.hub, r2.hub.now()), true, "runs at +60s after restart when >=10m elapsed since last run");
    assert.equal(measuredRound2.length, 16);
    assert.deepEqual(
      measuredRound2,
      Array.from({ length: 16 }, (_, i) => `s-${String(i + 16).padStart(2, "0")}`),
      "round 2 after restart measures the NEXT 16 sessions instead of re-measuring s-00..s-15",
    );
    for (let i = 0; i < 32; i++) {
      assert.ok(!existsSync(join(workspaces[i]!, "node_modules")), `s-${i} cleaned`);
    }
    for (let i = 32; i < 40; i++) {
      assert.ok(existsSync(join(workspaces[i]!, "node_modules")), `s-${i} deferred to next round`);
    }
    await r2.close();
  });

  test("corrupted upkeep-state.json is treated as empty without throwing and overwritten with valid state", async () => {
    const tc = testClock();
    await tc.adjust(1_800_000_000_000);
    const data = fresh("corrupt-state");
    const stateFile = join(data, UPKEEP_STATE_FILE);
    writeFileSync(stateFile, "{not-valid-json");

    const store = Store.open(join(data, "stillfail.db"), null, tc.clock);
    const cfg = hubConfig(
      {
        profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }],
        connects: [{ id: "cl", slack: { botName: "Claude bot" }, bind: { runtime: "claude" } }],
      },
      data,
    );
    let coldRooms!: ColdRooms;
    const hub = new Hub({
      config: () => cfg,
      store,
      chats: () => undefined,
      drivers: [],
      mcpUrl: "http://127.0.0.1:0/mcp",
      clock: tc.clock,
      cold: {
        isCold: (key) => coldRooms.isCold(key),
        restore: (key) => coldRooms.restore(key),
        pack: (key) => coldRooms.pack(key),
        cleanIdleRebuildable: (key) => coldRooms.cleanIdleRebuildable(key),
      },
    });
    coldRooms = new ColdRooms(() => hub);
    const now = hub.now();
    const ws = join(data, "sessions", "cl", "s-corrupt", "workspace");
    mkdirSync(join(ws, "node_modules", "pkg"), { recursive: true });
    writeFileSync(join(ws, "node_modules", "pkg", "index.js"), "1\n");
    store.insertSession({
      key: "s-corrupt", connect: "cl", runtime: "claude", profile: "cc",
      workspace: ws, runtimeSessionId: null, token: "tok-c",
      createdAt: now - 30 * 3_600_000, lastActiveAt: now - 30 * 3_600_000,
    });

    const n = await cleanIdleRebuildable(hub, now, { idleMs: IDLE_REBUILD_MS, limit: 16 });
    assert.equal(n, 1);
    assert.ok(!existsSync(join(ws, "node_modules")));
    const repaired = JSON.parse(readFileSync(stateFile, "utf8"));
    assert.equal(repaired.idleMeasured["s-corrupt"], now - 30 * 3_600_000);
    await hub.shutdown();
    store.close();
  });

  test("concurrent runArchiveUpkeepIfDue and cleanIdleRebuildable after restart wait on single-flight load and measure s-16..s-31", async () => {
    const tc = testClock();
    await tc.adjust(1_800_000_000_000);
    const data = fresh("idle-concurrent");
    const dbPath = join(data, "stillfail.db");
    const HOUR = 3_600_000;

    const measured: string[] = [];
    const store = Store.open(dbPath, null, tc.clock);
    const cfg = hubConfig(
      {
        profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }],
        connects: [{ id: "cl", slack: { botName: "Claude bot" }, bind: { runtime: "claude" } }],
      },
      data,
    );
    const t0 = tc.clock.currentTimeMillisUnsafe();
    const idleMeasured: Record<string, number> = {};
    const workspaces: string[] = [];
    for (let i = 0; i < 40; i++) {
      const key = `s-${String(i).padStart(2, "0")}`;
      const ws = join(data, "sessions", "cl", key, "workspace");
      mkdirSync(join(ws, "node_modules", "pkg"), { recursive: true });
      writeFileSync(join(ws, "node_modules", "pkg", "index.js"), "module.exports = 1;\n");
      const activeAt = t0 - 48 * HOUR + i * 1_000;
      store.insertSession({
        key, connect: "cl", runtime: "claude", profile: "cc",
        workspace: ws, runtimeSessionId: null, token: `tok-${key}`, createdAt: activeAt, lastActiveAt: activeAt,
      });
      if (i < 16) idleMeasured[key] = activeAt;
      workspaces.push(ws);
    }
    const stateFile = join(data, UPKEEP_STATE_FILE);
    writeFileSync(
      stateFile,
      JSON.stringify({
        idleMeasuredVersion: 2,
        idleMeasured,
        lastRepoBranchesAt: null,
        lastOrphanRoomsAt: null,
        lastFullRelieveAt: null,
        lastArchiveUpkeepAt: t0 - ARCHIVE_UPKEEP_EVERY_MS,
      }),
    );

    let readCount = 0;
    let readReleased = false;
    const measuredBeforeRelease: string[] = [];
    let markReadStarted!: () => void;
    const readStarted = new Promise<void>((resolve) => (markReadStarted = resolve));
    let releaseRead!: () => void;
    const readGate = new Promise<void>((resolve) => (releaseRead = resolve));

    let coldRooms!: ColdRooms;
    const hub = new Hub({
      config: () => cfg,
      store,
      chats: () => undefined,
      drivers: [],
      mcpUrl: "http://127.0.0.1:0/mcp",
      clock: tc.clock,
      readUpkeepState: async (dir) => {
        readCount++;
        markReadStarted();
        await readGate;
        return readUpkeepState(dir);
      },
      cold: {
        isCold: (key) => coldRooms.isCold(key),
        restore: (key) => coldRooms.restore(key),
        pack: (key) => coldRooms.pack(key),
        needsPack: (key) => coldRooms.needsPack(key),
        cleanIdleRebuildable: async (key) => {
          if (!readReleased) measuredBeforeRelease.push(key);
          const res = await coldRooms.cleanIdleRebuildable(key);
          if (res !== null) measured.push(key);
          return res;
        },
      },
    });
    coldRooms = new ColdRooms(() => hub);

    // Deterministic race sequence:
    // 1. Start entrypoint A (runArchiveUpkeepIfDue) and confirm readUpkeepState is suspended.
    const pDue = runArchiveUpkeepIfDue(hub, hub.now());
    await readStarted;
    // 2. Start entrypoint B (cleanIdleRebuildable) while A's read is suspended, then drain all non-blocked work via
    //    `settle()` so that unfixed code deterministically measures s-00..s-15 before the read gate opens.
    const pClean = cleanIdleRebuildable(hub, hub.now());
    await settle(20);
    assert.deepEqual(
      measuredBeforeRelease,
      [],
      "entrypoint B must wait for single-flight state load before measuring",
    );
    // 3. Release the read and await both.
    readReleased = true;
    releaseRead();
    const [dueRan, cleanedCount] = await Promise.all([pDue, pClean]);
    assert.equal(readCount, 1, "upkeep-state.json read exactly once");
    assert.equal(dueRan, false, "runArchiveUpkeepIfDue respects 60s startup grace");
    assert.equal(cleanedCount, 16);
    assert.deepEqual(
      measured,
      Array.from({ length: 16 }, (_, i) => `s-${String(i + 16).padStart(2, "0")}`),
      "concurrent cleanIdleRebuildable waited for single-flight state load and measured s-16..s-31",
    );
    for (let i = 16; i < 32; i++) assert.ok(!existsSync(join(workspaces[i]!, "node_modules")), `s-${i} cleaned`);
    for (let i = 32; i < 40; i++) assert.ok(existsSync(join(workspaces[i]!, "node_modules")), `s-${i} untouched`);
    const persisted = JSON.parse(readFileSync(stateFile, "utf8"));
    assert.equal(Object.keys(persisted.idleMeasured).length, 32);

    await hub.shutdown();
    store.close();
  });

  test("legacy upkeep-state.json without idleMeasuredVersion resets idleMeasured while preserving timestamps and upgrades on patch", async () => {
    const data = fresh("legacy-state-upgrade");
    const stateFile = join(data, UPKEEP_STATE_FILE);
    writeFileSync(
      stateFile,
      JSON.stringify({
        idleMeasured: { "s-poisoned-1": 1000, "s-poisoned-2": 2000 },
        lastRepoBranchesAt: 111,
        lastOrphanRoomsAt: 222,
        lastFullRelieveAt: 333,
        lastArchiveUpkeepAt: 444,
      }),
    );

    const state = await readUpkeepState(data);
    assert.deepEqual(state.idleMeasured, {}, "legacy idleMeasured cleared on upgrade");
    assert.equal(state.lastRepoBranchesAt, 111);
    assert.equal(state.lastOrphanRoomsAt, 222);
    assert.equal(state.lastFullRelieveAt, 333);
    assert.equal(state.lastArchiveUpkeepAt, 444);

    const wrote = await patchUpkeepState(data, { lastArchiveUpkeepAt: 444 });
    assert.equal(wrote, true, "legacy state file atomically rewritten with version 2");
    const upgraded = JSON.parse(readFileSync(stateFile, "utf8"));
    assert.equal(upgraded.idleMeasuredVersion, 2);
    assert.deepEqual(upgraded.idleMeasured, {});
    assert.equal(upgraded.lastRepoBranchesAt, 111);
    assert.equal(upgraded.lastOrphanRoomsAt, 222);
    assert.equal(upgraded.lastFullRelieveAt, 333);
    assert.equal(upgraded.lastArchiveUpkeepAt, 444);
  });
});

describe("Item 2: daily branch cleanup timestamp survives Upkeep restart", () => {
  test("after branch cleanup runs, a restarted Upkeep skips within 24h and runs again after 24h", async () => {
    const data = fresh("daily-restart");
    const remote = join(fresh("daily-remote"), "origin.git");
    mkdirSync(remote, { recursive: true });
    git(remote, ["init", "--bare", "-b", "main"]);

    const repo = join(data, "repos", "demo");
    mkdirSync(repo, { recursive: true });
    const tc = testClock();
    const t0 = 1_800_000_000_000;
    await tc.adjust(t0);
    const oldSec = Math.floor((t0 - 5 * 24 * 3_600_000) / 1000);
    const oldEnv = { GIT_AUTHOR_DATE: `${oldSec} +0000`, GIT_COMMITTER_DATE: `${oldSec} +0000` };

    git(repo, ["init", "-b", "main"]);
    git(repo, ["remote", "add", "origin", remote]);
    writeFileSync(join(repo, "README.md"), "hi\n");
    git(repo, ["add", "README.md"]);
    git(repo, ["commit", "-m", "init"], oldEnv);
    git(repo, ["push", "-u", "origin", "main"]);

    // Create merged branch b1 (with no reflog, so reflog/mtime check passes cleanly)
    git(repo, ["branch", "b1", "main"]);
    rmSync(join(repo, ".git", "logs", "refs", "heads", "b1"), { force: true });
    const ref1 = join(repo, ".git", "refs", "heads", "b1");
    execFileSync("touch", ["-t", "202001010000", ref1]);

    // First Upkeep instance: runs branch cleanup and persists lastRepoBranchesAt
    const u1 = new Upkeep({ data, clock: tc.clock });
    await u1.run();
    await u1.close();
    assert.ok(!branchExists(repo, "b1"), "round 1 pruned b1");

    // Simulate restart 1 hour later with a new eligible branch b2
    await tc.adjust(3_600_000);
    git(repo, ["branch", "b2", "main"]);
    rmSync(join(repo, ".git", "logs", "refs", "heads", "b2"), { force: true });
    execFileSync("touch", ["-t", "202001010000", join(repo, ".git", "refs", "heads", "b2")]);

    const u2 = new Upkeep({ data, clock: tc.clock });
    await u2.run();
    assert.ok(branchExists(repo, "b2"), "restarted Upkeep skipped branch cleanup within 24h");

    // Advance past 24h from t0: now runs again and prunes b2
    await tc.adjust(REPO_BRANCHES_EVERY_MS);
    await u2.run();
    assert.ok(!branchExists(repo, "b2"), "Upkeep ran branch cleanup again after 24h");
    await u2.close();
  });
});

describe("Item 3: foreign locked worktree cleanup in pruneRepoWorktrees", () => {
  test("prunes foreign archived-workspace locked registration with missing target; preserves local locked, user-locked, existing foreign target, and symlinked repo", async () => {
    const data = fresh("wt-data");
    const external = fresh("wt-ext");
    mkdirSync(join(data, "sessions"), { recursive: true });
    mkdirSync(join(data, "repos"), { recursive: true });

    const repo = join(data, "repos", "main-repo");
    mkdirSync(join(repo, ".git", "worktrees"), { recursive: true });

    const addWt = (name: string, gitdir: string, locked?: string) => {
      const dir = join(repo, ".git", "worktrees", name);
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, "gitdir"), `${gitdir}\n`);
      if (locked !== undefined) writeFileSync(join(dir, "locked"), locked);
      return dir;
    };

    // 1. Foreign locked registration (station prefix, both locked room & gitdir outside local <data>/sessions, target missing) -> MUST PRUNE
    const foreignGone = addWt(
      "wt-foreign-gone",
      "/Users/other-machine/.stillfail/sessions/chat/c-111/workspace/repo/.git",
      `${ARCHIVE_WORKTREE_LOCK_PREFIX}/Users/other-machine/.stillfail/sessions/chat/c-111\n`,
    );

    // 2. Local <data>/sessions locked registration (target missing, e.g. archived/packed) -> MUST KEEP
    const localRoom = join(data, "sessions", "chat", "c-local");
    const localLocked = addWt(
      "wt-local-locked",
      join(localRoom, "workspace", "repo", ".git"),
      `${ARCHIVE_WORKTREE_LOCK_PREFIX}${localRoom}\n`,
    );

    // 3. Non-station-prefix locked registration (user-locked, foreign missing target) -> MUST KEEP
    const userLocked = addWt(
      "wt-user-locked",
      "/Users/other-machine/dev/my-wt/.git",
      "kept by hand\n",
    );

    // 4. Foreign locked registration whose gitdir target STILL EXISTS -> MUST KEEP
    const existingTargetDir = join(external, "still-here", "workspace", "repo");
    mkdirSync(existingTargetDir, { recursive: true });
    const existingTargetGit = join(existingTargetDir, ".git");
    writeFileSync(existingTargetGit, "gitdir: /dummy\n");
    const foreignExists = addWt(
      "wt-foreign-exists",
      existingTargetGit,
      `${ARCHIVE_WORKTREE_LOCK_PREFIX}${join(external, "still-here")}\n`,
    );

    // 5. Symlinked external repo with a foreign locked missing worktree -> MUST KEEP (symlinked repos untouched)
    const extRepo = join(external, "ext-repo");
    const extWt = join(extRepo, ".git", "worktrees", "wt-ext-foreign");
    mkdirSync(extWt, { recursive: true });
    writeFileSync(join(extWt, "gitdir"), "/Users/other-machine/.stillfail/sessions/chat/c-222/workspace/r/.git\n");
    writeFileSync(join(extWt, "locked"), `${ARCHIVE_WORKTREE_LOCK_PREFIX}/Users/other-machine/.stillfail/sessions/chat/c-222\n`);
    symlinkSync(extRepo, join(data, "repos", "linked-repo"));

    const gone = await pruneRepoWorktrees(data);
    assert.deepEqual(gone, ["main-repo/wt-foreign-gone"]);
    assert.ok(!existsSync(foreignGone), "foreign locked missing registration pruned");
    assert.ok(existsSync(localLocked), "local locked registration preserved");
    assert.ok(existsSync(userLocked), "non-station-prefix locked registration preserved");
    assert.ok(existsSync(foreignExists), "foreign locked registration with existing target preserved");
    assert.ok(existsSync(extWt), "symlinked external repo worktree preserved");
  });
});
