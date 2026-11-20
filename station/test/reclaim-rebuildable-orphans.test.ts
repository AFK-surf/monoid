// Tests for PR A: periodic backfill of unfinished archive packs, idle unarchived rebuildable cleanup,
// bounded idle-unarchived store query, and Upkeep orphan session room / orphan transcript pruning.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, describe, test } from "node:test";
import { ColdRooms } from "../src/sessions/cold.ts";
import {
  IDLE_REBUILD_LOW_MS,
  IDLE_REBUILD_MS,
  archive,
  cleanIdleRebuildable,
  packUnfinishedArchived,
  relieveIdleRebuildable,
} from "../src/sessions/lifecycle.ts";
import {
  ORPHAN_ROOM_MS,
  ORPHAN_TRANSCRIPT_MS,
  pruneOrphanRooms,
  pruneOrphanTranscripts,
} from "../src/ops/storage.ts";
import { MANUAL, Store } from "../src/store/store.ts";
import { claudeProject } from "./usage-counter-reference.ts";
import { Rig, settle } from "./hub-fakes.ts";

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `reclaim-a-${what}-`));
  dirs.push(dir);
  return dir;
};

after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

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

function setMtime(path: string, ms: number): void {
  const sec = ms / 1000;
  utimesSync(path, sec, sec);
}

describe("Item 1: periodic backfill of unfinished archive packing", () => {
  test("retries failed archive pack on next round, enforces per-round limit, and skips shared/job rooms", async () => {
    let failOnce = true;
    const packed: string[] = [];
    let coldRooms!: ColdRooms;
    const r = new Rig({
      cold: {
        isCold: (key) => coldRooms.isCold(key),
        restore: (key) => coldRooms.restore(key),
        holdsMore: (key) => coldRooms.holdsMore(key),
        expire: (key, before) => coldRooms.expire(key, before),
        needsPack: (key) => coldRooms.needsPack(key),
        pack: async (key) => {
          if (key === "s-fail" && failOnce) {
            failOnce = false;
            throw new Error("simulated transient pack failure");
          }
          await coldRooms.pack(key);
          packed.push(key);
        },
      },
    });
    coldRooms = new ColdRooms(() => r.hub);
    const data = r.hub.config().dataDir;
    const now = r.hub.now();

    const makeArchived = (key: string, archivedAt: number) => {
      const ws = join(data, "sessions", "cl", key, "workspace");
      mkdirSync(ws, { recursive: true });
      writeFileSync(join(ws, "note.txt"), `hello ${key}\n`);
      r.store.insertSession({
        key, connect: "cl", runtime: "claude", profile: "cc",
        workspace: ws, runtimeSessionId: null, token: `tok-${key}`, createdAt: archivedAt - 1000, lastActiveAt: archivedAt - 1000,
      });
      r.store.setArchived(key, true, MANUAL);
      r.store.db.prepare("UPDATE sessions SET archived_at = ? WHERE key = ?").run(archivedAt, key);
      return ws;
    };

    // 1. Session whose initial archive() pack fails transiently: lacks `cold` mark after archive()
    const wsFail = makeArchived("s-fail", now - 60_000);
    // Trigger explicit archive (first pack throws), then keep its older archived_at timestamp
    archive(r.hub, "s-fail", true);
    await settle();
    r.store.db.prepare("UPDATE sessions SET archived_at = ? WHERE key = ?").run(now - 60_000, "s-fail");
    assert.ok(!existsSync(join(dirname(wsFail), "cold")), "initial failed pack left no cold mark");

    // 2. Three more unfinished archived sessions to test per-round limit = 2
    const wsA = makeArchived("s-a", now - 50_000);
    const wsB = makeArchived("s-b", now - 40_000);
    const wsC = makeArchived("s-c", now - 30_000);

    // 3. Archived session whose room is shared with a live session -> must NOT be packed
    const wsShared = makeArchived("s-shared", now - 20_000);
    r.store.insertSession({
      key: "s-live-sharer", connect: "cl", runtime: "claude", profile: "cc",
      workspace: wsShared, runtimeSessionId: null, token: "tok-sharer", createdAt: now, lastActiveAt: now,
    });

    // 4. Archived session with an active job in its room -> must NOT be packed
    const wsJob = makeArchived("s-job", now - 10_000);
    r.store.insertJob({
      id: "j-active", sessionKey: "s-job", name: "dev", command: "sleep 60", cwd: wsJob,
      port: null, token: "jtok-active", state: "running", pgid: 99999, exitCode: null,
      startedAt: now, endedAt: null, restarts: 0, log: join(data, "jobs", "j-active.log"), watch: false,
    });

    // Round 1 with limit = 2: packs s-fail and s-a only
    const n1 = await packUnfinishedArchived(r.hub, now, 2);
    assert.equal(n1, 2);
    assert.deepEqual(packed, ["s-fail", "s-a"]);
    assert.ok(existsSync(join(dirname(wsFail), "cold")), "failed archive was backfilled");
    assert.ok(existsSync(join(dirname(wsA), "cold")));
    assert.ok(!existsSync(join(dirname(wsB), "cold")), "per-round limit deferred s-b");
    assert.ok(!existsSync(join(dirname(wsC), "cold")), "per-round limit deferred s-c");

    // Round 2 with limit = 2: packs s-b and s-c; leaves s-shared and s-job untouched
    const n2 = await packUnfinishedArchived(r.hub, now, 2);
    assert.equal(n2, 2);
    assert.deepEqual(packed, ["s-fail", "s-a", "s-b", "s-c"]);
    assert.ok(existsSync(join(dirname(wsB), "cold")));
    assert.ok(existsSync(join(dirname(wsC), "cold")));
    assert.ok(!existsSync(join(dirname(wsShared), "cold")), "shared room must not be packed");
    assert.ok(!existsSync(join(dirname(wsJob), "cold")), "room with active job must not be packed");

    await r.close();
  });
});

describe("Item 2: clean rebuildable directories of idle unarchived sessions", () => {
  test("idleUnarchivedSessions query is indexed by sessions_live and bounded", () => {
    const dbDir = fresh("db");
    const store = Store.open(join(dbDir, "stillfail.db"));
    const now = 1_800_000_000_000;
    for (let i = 0; i < 10; i++) {
      store.insertSession({
        key: `s-${i}`, connect: "cl", runtime: "claude", profile: "cc",
        workspace: join(dbDir, `ws-${i}`), runtimeSessionId: null, token: `tok-${i}`,
        createdAt: now - (20 - i) * 3_600_000, lastActiveAt: now - (20 - i) * 3_600_000,
      });
    }
    const plan = store.db
      .prepare(
        "EXPLAIN QUERY PLAN SELECT key, workspace, last_active_at FROM sessions INDEXED BY sessions_live WHERE archived_at IS NULL AND running = 0 AND last_active_at <= ? ORDER BY last_active_at ASC, key ASC LIMIT ?",
      )
      .all(now, 4) as { detail: string }[];
    assert.ok(plan.some((p) => p.detail.includes("sessions_live")), `expected sessions_live index, got ${JSON.stringify(plan)}`);

    const p1 = store.idleUnarchivedSessions(null, now, 4);
    assert.equal(p1.length, 4);
    assert.deepEqual(p1.map((s) => s.key), ["s-0", "s-1", "s-2", "s-3"]);
    const p2 = store.idleUnarchivedSessions({ lastActiveAt: p1[3]!.lastActiveAt, key: p1[3]!.key }, now, 4);
    assert.equal(p2.length, 4);
    assert.deepEqual(p2.map((s) => s.key), ["s-4", "s-5", "s-6", "s-7"]);
    store.close();
  });

  test("cleans 25h idle node_modules while preserving source, untracked files, 23h idle, running, active job, and git-tracked node_modules; low disk uses 1h threshold", async () => {
    let coldRooms!: ColdRooms;
    const r = new Rig({
      cold: {
        isCold: (key) => coldRooms.isCold(key),
        restore: (key) => coldRooms.restore(key),
        pack: (key) => coldRooms.pack(key),
        cleanIdleRebuildable: (key) => coldRooms.cleanIdleRebuildable(key),
      },
    });
    coldRooms = new ColdRooms(() => r.hub);
    const data = r.hub.config().dataDir;
    const now = r.hub.now();
    const HOUR = 3_600_000;

    const makeIdle = (key: string, idleHours: number, opts?: { running?: boolean; withJob?: boolean; gitTracked?: boolean }) => {
      const ws = join(data, "sessions", "cl", key, "workspace");
      mkdirSync(join(ws, "node_modules", "pkg"), { recursive: true });
      writeFileSync(join(ws, "node_modules", "pkg", "index.js"), "module.exports = 1;\n".repeat(100));
      writeFileSync(join(ws, "src.ts"), "export const x = 1;\n");
      writeFileSync(join(ws, "untracked-note.txt"), "keep me\n");
      if (opts?.gitTracked) {
        git(ws, ["init", "-b", "main"]);
        git(ws, ["add", "src.ts", "node_modules/pkg/index.js"]);
        git(ws, ["commit", "-m", "track node_modules"]);
      }
      const at = now - idleHours * HOUR;
      r.store.insertSession({
        key, connect: "cl", runtime: "claude", profile: "cc",
        workspace: ws, runtimeSessionId: null, token: `tok-${key}`, createdAt: at, lastActiveAt: at,
      });
      if (opts?.running) r.store.setRunning(key, true);
      if (opts?.withJob) {
        r.store.insertJob({
          id: `j-${key}`, sessionKey: key, name: "bg", command: "sleep 60", cwd: ws,
          port: null, token: `jtok-${key}`, state: "running", pgid: 99998, exitCode: null,
          startedAt: now, endedAt: null, restarts: 0, log: join(data, "jobs", `j-${key}.log`), watch: false,
        });
      }
      return ws;
    };

    const ws25h = makeIdle("s-25h", 25);
    const ws23h = makeIdle("s-23h", 23);
    const wsRunning = makeIdle("s-running", 30, { running: true });
    const wsJob = makeIdle("s-job", 30, { withJob: true });
    const wsTracked = makeIdle("s-tracked", 30, { gitTracked: true });
    const ws2h = makeIdle("s-2h", 2);
    const ws30m = makeIdle("s-30m", 0.5);

    // Periodic pass (24h threshold): only s-25h cleaned
    const cleaned = await cleanIdleRebuildable(r.hub, now, { idleMs: IDLE_REBUILD_MS, limit: 16 });
    assert.equal(cleaned, 1);
    assert.ok(!existsSync(join(ws25h, "node_modules")), "25h idle node_modules removed");
    assert.ok(existsSync(join(ws25h, "src.ts")), "source file preserved");
    assert.ok(existsSync(join(ws25h, "untracked-note.txt")), "untracked file preserved");
    assert.ok(!existsSync(join(dirname(ws25h), "cold")), "no cold mark written");
    assert.ok(existsSync(join(ws23h, "node_modules")), "23h idle preserved");
    assert.ok(existsSync(join(wsRunning, "node_modules")), "running session preserved");
    assert.ok(existsSync(join(wsJob, "node_modules")), "session with active job preserved");
    assert.ok(existsSync(join(wsTracked, "node_modules")), "git-tracked node_modules preserved");
    assert.ok(existsSync(join(ws2h, "node_modules")), "2h idle preserved on normal pass");
    assert.ok(existsSync(join(ws30m, "node_modules")), "30m idle preserved");

    // Low-disk pass (1h threshold): cleans s-23h (oldest) and s-2h, preserves s-30m
    let fakeFree = 100;
    const relieved = await relieveIdleRebuildable(
      r.hub,
      () => fakeFree,
      1000,
      IDLE_REBUILD_LOW_MS,
    );
    assert.equal(relieved, 2);
    assert.ok(!existsSync(join(ws23h, "node_modules")), "23h idle cleaned on low disk");
    assert.ok(!existsSync(join(ws2h, "node_modules")), "2h idle cleaned on low disk");
    assert.ok(existsSync(join(ws30m, "node_modules")), "30m idle preserved even on low disk");
    assert.ok(existsSync(join(wsRunning, "node_modules")), "running session still preserved on low disk");
    assert.ok(existsSync(join(wsJob, "node_modules")), "active-job session still preserved on low disk");
    assert.ok(existsSync(join(wsTracked, "node_modules")), "git-tracked node_modules still preserved on low disk");

    await r.close();
  });
});

describe("Item 3: orphan session rooms and orphan transcripts in Upkeep", () => {
  test("prunes >24h orphan rooms with worktree registrations while preserving session-backed, <24h, active-job, and outside-<data> dirs", async () => {
    const data = fresh("item3-rooms");
    const external = fresh("item3-ext");
    const store = Store.open(join(data, "stillfail.db"));
    const now = 1_800_000_000_000;
    const HOUR = 3_600_000;

    // Shared repo with a worktree inside the orphan room
    const repo = join(data, "repos", "demo");
    mkdirSync(repo, { recursive: true });
    git(repo, ["init", "-b", "main"]);
    writeFileSync(join(repo, "README.md"), "hi\n");
    git(repo, ["add", "README.md"]);
    git(repo, ["commit", "-m", "init"]);

    // 1. Old orphan room (25h) with linked git worktree
    const oldOrphanRoom = join(data, "sessions", "cl", "orphan-old");
    const oldOrphanWs = join(oldOrphanRoom, "workspace");
    mkdirSync(oldOrphanWs, { recursive: true });
    git(repo, ["worktree", "add", "-b", "b-orphan", join(oldOrphanWs, "wt-orphan")]);
    setMtime(oldOrphanWs, now - 25 * HOUR);
    setMtime(oldOrphanRoom, now - 25 * HOUR);

    // 2. Fresh orphan room (23h) -> must be preserved
    const freshOrphanRoom = join(data, "sessions", "cl", "orphan-fresh");
    mkdirSync(join(freshOrphanRoom, "workspace"), { recursive: true });
    setMtime(join(freshOrphanRoom, "workspace"), now - 23 * HOUR);
    setMtime(freshOrphanRoom, now - 23 * HOUR);

    // 3. Old room backed by a session row -> must be preserved
    const liveRoom = join(data, "sessions", "cl", "live-room");
    const liveWs = join(liveRoom, "workspace");
    mkdirSync(liveWs, { recursive: true });
    setMtime(liveWs, now - 48 * HOUR);
    setMtime(liveRoom, now - 48 * HOUR);
    store.insertSession({
      key: "s-live", connect: "cl", runtime: "claude", profile: "cc",
      workspace: liveWs, runtimeSessionId: null, token: "tok-live", createdAt: now - 48 * HOUR, lastActiveAt: now - 48 * HOUR,
    });

    // 4. Old orphan room with an active job -> must be preserved
    const jobRoom = join(data, "sessions", "cl", "job-room");
    const jobWs = join(jobRoom, "workspace");
    mkdirSync(jobWs, { recursive: true });
    setMtime(jobWs, now - 48 * HOUR);
    setMtime(jobRoom, now - 48 * HOUR);
    store.insertJob({
      id: "j-orphan", sessionKey: "s-live", name: "job", command: "sleep 60", cwd: jobWs,
      port: null, token: "jtok-orphan", state: "running", pgid: 99997, exitCode: null,
      startedAt: now, endedAt: null, restarts: 0, log: join(data, "jobs", "j-orphan.log"), watch: false,
    });

    // 5. Symlink in <data>/sessions pointing outside <data> -> must NOT be followed or deleted
    const extTarget = join(external, "outside-dir");
    mkdirSync(join(extTarget, "room", "workspace"), { recursive: true });
    writeFileSync(join(extTarget, "room", "workspace", "keep.txt"), "keep\n");
    setMtime(join(extTarget, "room"), now - 48 * HOUR);
    symlinkSync(extTarget, join(data, "sessions", "ext-link"));

    const gone = await pruneOrphanRooms(data, now, store, { minAgeMs: ORPHAN_ROOM_MS });
    assert.deepEqual(gone, ["cl/orphan-old"]);
    assert.ok(!existsSync(oldOrphanRoom), "25h orphan room removed");
    assert.ok(!existsSync(join(repo, ".git", "worktrees", "wt-orphan")), "orphan room worktree registration removed");
    assert.ok(existsSync(freshOrphanRoom), "23h orphan room preserved");
    assert.ok(existsSync(liveRoom), "session-backed room preserved");
    assert.ok(existsSync(jobRoom), "active-job room preserved");
    assert.ok(existsSync(join(extTarget, "room", "workspace", "keep.txt")), "outside-<data> symlink target preserved");

    store.close();
  });

  test("prunes >3d unreferenced Claude and Codex transcripts under <data> while preserving referenced (incl. archived), <3d, and outside-<data> files", async () => {
    const data = fresh("item3-transcripts");
    const external = fresh("item3-tx-ext");
    const store = Store.open(join(data, "stillfail.db"));
    const now = 1_800_000_000_000;
    const DAY = 24 * 3_600_000;

    // Session referencing claude "ref-archived-id" (ARCHIVED) and codex UUID
    const refCodexId = "11111111-1111-4111-8111-111111111111";
    const orphanCodexOld = "22222222-2222-4222-8222-222222222222";
    const orphanCodexNew = "33333333-3333-4333-8333-333333333333";

    const wsArch = join(data, "sessions", "cl", "s-arch", "workspace");
    mkdirSync(wsArch, { recursive: true });
    store.insertSession({
      key: "s-arch", connect: "cl", runtime: "claude", profile: "cc",
      workspace: wsArch, runtimeSessionId: "ref-archived-id", token: "tok-arch", createdAt: now - 10 * DAY, lastActiveAt: now - 10 * DAY,
    });
    store.ranIn("s-arch", "ref-archived-id", "cc");
    store.setArchived("s-arch", true, MANUAL);
    store.db.prepare("UPDATE sessions SET archived_at = ? WHERE key = ?").run(now - 5 * DAY, "s-arch");

    store.insertSession({
      key: "s-codex", connect: "cl", runtime: "codex", profile: "cx",
      workspace: wsArch, runtimeSessionId: refCodexId, token: "tok-cx", createdAt: now - 10 * DAY, lastActiveAt: now - 10 * DAY,
    });
    store.ranIn("s-codex", refCodexId, "cx");

    const proj = claudeProject(wsArch);
    const claudeTxDir = join(data, "transcripts", "claude", proj);
    mkdirSync(claudeTxDir, { recursive: true });

    // 1. Referenced by archived session (4d old) -> MUST keep
    const refClaude = join(claudeTxDir, "ref-archived-id.jsonl");
    writeFileSync(refClaude, "{}\n");
    setMtime(refClaude, now - 4 * DAY);

    // 2. Orphan Claude (2d old) -> MUST keep
    const newOrphanClaude = join(claudeTxDir, "orphan-2d.jsonl");
    writeFileSync(newOrphanClaude, "{}\n");
    setMtime(newOrphanClaude, now - 2 * DAY);

    // 3. Orphan Claude (4d old) + companion <id>/tool-results/ dir -> MUST delete
    const oldOrphanClaude = join(claudeTxDir, "orphan-4d.jsonl");
    const oldOrphanClaudeDir = join(claudeTxDir, "orphan-4d");
    mkdirSync(join(oldOrphanClaudeDir, "tool-results"), { recursive: true });
    writeFileSync(oldOrphanClaude, "{}\n");
    writeFileSync(join(oldOrphanClaudeDir, "tool-results", "a.txt"), "out\n");
    setMtime(oldOrphanClaude, now - 4 * DAY);
    setMtime(oldOrphanClaudeDir, now - 4 * DAY);

    // 4. Orphan Claude .zst under <data>/homes/cc/projects/<proj>/ (4d old) -> MUST delete
    const homeClaudeDir = join(data, "homes", "cc", "projects", proj);
    mkdirSync(homeClaudeDir, { recursive: true });
    const homeOrphanZst = join(homeClaudeDir, "orphan-home-4d.jsonl.zst");
    writeFileSync(homeOrphanZst, "zst");
    setMtime(homeOrphanZst, now - 4 * DAY);

    // 5. Codex rollouts under <data>/homes/cx/sessions/2026/11/16/
    const codexDir = join(data, "homes", "cx", "sessions", "2026", "11", "16");
    mkdirSync(codexDir, { recursive: true });
    const refCodexFile = join(codexDir, `rollout-2026-11-16T00-00-00-${refCodexId}.jsonl`);
    const oldCodexFile = join(codexDir, `rollout-2026-11-16T00-00-00-${orphanCodexOld}.jsonl`);
    const newCodexFile = join(codexDir, `rollout-2026-11-18T00-00-00-${orphanCodexNew}.jsonl`);
    writeFileSync(refCodexFile, "{}\n");
    writeFileSync(oldCodexFile, "{}\n");
    writeFileSync(newCodexFile, "{}\n");
    setMtime(refCodexFile, now - 4 * DAY);
    setMtime(oldCodexFile, now - 4 * DAY);
    setMtime(newCodexFile, now - 2 * DAY);

    // 6. Symlink inside <data>/homes pointing outside <data> -> MUST keep
    const extProfile = join(external, "user-profile");
    mkdirSync(join(extProfile, "projects", proj), { recursive: true });
    const extTx = join(extProfile, "projects", proj, "user-4d.jsonl");
    writeFileSync(extTx, "{}\n");
    setMtime(extTx, now - 4 * DAY);
    symlinkSync(extProfile, join(data, "homes", "ext-link"));

    // 7. Other runtime under <data>/transcripts/gemini -> untouched
    const otherDir = join(data, "transcripts", "gemini");
    mkdirSync(otherDir, { recursive: true });
    const otherFile = join(otherDir, "old.jsonl");
    writeFileSync(otherFile, "{}\n");
    setMtime(otherFile, now - 10 * DAY);

    const gone = await pruneOrphanTranscripts(data, now, store, { minAgeMs: ORPHAN_TRANSCRIPT_MS });
    assert.ok(!existsSync(oldOrphanClaude), "4d orphan Claude transcript deleted");
    assert.ok(!existsSync(oldOrphanClaudeDir), "4d orphan Claude companion dir deleted");
    assert.ok(!existsSync(homeOrphanZst), "4d orphan Claude .zst in <data>/homes deleted");
    assert.ok(!existsSync(oldCodexFile), "4d orphan Codex rollout deleted");
    assert.ok(existsSync(refClaude), "archived-session-referenced Claude transcript preserved");
    assert.ok(existsSync(newOrphanClaude), "2d orphan Claude transcript preserved");
    assert.ok(existsSync(refCodexFile), "referenced Codex rollout preserved");
    assert.ok(existsSync(newCodexFile), "2d orphan Codex rollout preserved");
    assert.ok(existsSync(extTx), "outside-<data> transcript preserved");
    assert.ok(existsSync(otherFile), "other runtime transcript preserved");
    assert.ok(gone.length >= 3, `expected at least 3 removed items, got ${JSON.stringify(gone)}`);

    store.close();
  });
});
