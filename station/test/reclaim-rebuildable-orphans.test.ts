// Tests for PR A: periodic backfill of unfinished archive packs (with cross-round cursor & check cap),
// idle unarchived rebuildable cleanup (capped by measured count & memoized by last_active_at),
// bounded idle-unarchived store query, and daily Upkeep orphan session room pruning.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, describe, test } from "node:test";
import { ColdRooms } from "../src/sessions/cold.ts";
import {
  ARCHIVE_UPKEEP_EVERY_MS,
  IDLE_REBUILD_LOW_MS,
  IDLE_REBUILD_MS,
  archive,
  cleanIdleRebuildable,
  packUnfinishedArchived,
  relieveArchived,
  relieveIdleRebuildable,
  relieveLowDiskFull,
  runArchiveUpkeepIfDue,
} from "../src/sessions/lifecycle.ts";
import {
  ORPHAN_ROOM_EVERY_MS,
  ORPHAN_ROOM_MS,
  ORPHAN_TRANSCRIPT_MS,
  RELIEVE_FULL_EVERY_MS,
  Upkeep,
  pruneOrphanRooms,
  relieveOrphanTranscripts,
} from "../src/ops/storage.ts";
import { MANUAL, Store } from "../src/store/store.ts";
import { claudeProject } from "./usage-counter-reference.ts";
import { Rig, settle, testClock } from "./hub-fakes.ts";

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

    const wsFail = makeArchived("s-fail", now - 60_000);
    archive(r.hub, "s-fail", true);
    await settle();
    r.store.db.prepare("UPDATE sessions SET archived_at = ? WHERE key = ?").run(now - 60_000, "s-fail");
    assert.ok(!existsSync(join(dirname(wsFail), "cold")), "initial failed pack left no cold mark");

    const wsA = makeArchived("s-a", now - 50_000);
    const wsB = makeArchived("s-b", now - 40_000);
    const wsC = makeArchived("s-c", now - 30_000);

    const wsShared = makeArchived("s-shared", now - 20_000);
    r.store.insertSession({
      key: "s-live-sharer", connect: "cl", runtime: "claude", profile: "cc",
      workspace: wsShared, runtimeSessionId: null, token: "tok-sharer", createdAt: now, lastActiveAt: now,
    });

    const wsJob = makeArchived("s-job", now - 10_000);
    r.store.insertJob({
      id: "j-active", sessionKey: "s-job", name: "dev", command: "sleep 60", cwd: wsJob,
      port: null, token: "jtok-active", state: "running", pgid: 99999, exitCode: null,
      startedAt: now, endedAt: null, restarts: 0, log: join(data, "jobs", "j-active.log"), watch: false,
    });

    const n1 = await packUnfinishedArchived(r.hub, now, 2);
    assert.equal(n1, 2);
    assert.deepEqual(packed, ["s-fail", "s-a"]);
    assert.ok(existsSync(join(dirname(wsFail), "cold")), "failed archive was backfilled");
    assert.ok(existsSync(join(dirname(wsA), "cold")));
    assert.ok(!existsSync(join(dirname(wsB), "cold")), "per-round limit deferred s-b");
    assert.ok(!existsSync(join(dirname(wsC), "cold")), "per-round limit deferred s-c");

    const n2 = await packUnfinishedArchived(r.hub, now, 2);
    assert.equal(n2, 2);
    assert.deepEqual(packed, ["s-fail", "s-a", "s-b", "s-c"]);
    assert.ok(existsSync(join(dirname(wsB), "cold")));
    assert.ok(existsSync(join(dirname(wsC), "cold")));
    assert.ok(!existsSync(join(dirname(wsShared), "cold")), "shared room must not be packed");
    assert.ok(!existsSync(join(dirname(wsJob), "cold")), "room with active job must not be packed");

    await r.close();
  });

  test("cross-round cursor advances past persistently failing head sessions so later sessions still get packed", async () => {
    const packed: string[] = [];
    let coldRooms!: ColdRooms;
    const r = new Rig({
      cold: {
        isCold: (key) => coldRooms.isCold(key),
        restore: (key) => coldRooms.restore(key),
        needsPack: (key) => coldRooms.needsPack(key),
        pack: async (key) => {
          if (key.startsWith("s-stuck")) throw new Error("persistent pack failure");
          await coldRooms.pack(key);
          packed.push(key);
        },
      },
    });
    coldRooms = new ColdRooms(() => r.hub);
    const data = r.hub.config().dataDir;
    const now = r.hub.now();

    const add = (key: string, offsetMs: number) => {
      const ws = join(data, "sessions", "cl", key, "workspace");
      mkdirSync(ws, { recursive: true });
      writeFileSync(join(ws, "f.txt"), key);
      r.store.insertSession({
        key, connect: "cl", runtime: "claude", profile: "cc",
        workspace: ws, runtimeSessionId: null, token: `tok-${key}`, createdAt: now - offsetMs, lastActiveAt: now - offsetMs,
      });
      r.store.setArchived(key, true, MANUAL);
      r.store.db.prepare("UPDATE sessions SET archived_at = ? WHERE key = ?").run(now - offsetMs, key);
      return ws;
    };

    const wsStuck1 = add("s-stuck-1", 40_000);
    const wsStuck2 = add("s-stuck-2", 30_000);
    const wsOk1 = add("s-ok-1", 20_000);
    const wsOk2 = add("s-ok-2", 10_000);

    // Round 1 (limit = 2): attempts s-stuck-1 and s-stuck-2 (both fail inside actor queue), cursor moves past s-stuck-2
    const n1 = await packUnfinishedArchived(r.hub, now, 2);
    assert.equal(n1, 2);
    assert.deepEqual(packed, []);
    assert.ok(!existsSync(join(dirname(wsStuck1), "cold")));
    assert.ok(!existsSync(join(dirname(wsStuck2), "cold")));

    // Round 2 (limit = 2): resumes past s-stuck-2 and packs s-ok-1 and s-ok-2
    const n2 = await packUnfinishedArchived(r.hub, now, 2);
    assert.equal(n2, 2);
    assert.deepEqual(packed, ["s-ok-1", "s-ok-2"]);
    assert.ok(existsSync(join(dirname(wsOk1), "cold")));
    assert.ok(existsSync(join(dirname(wsOk2), "cold")));

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

    // Periodic pass (24h threshold): measures s-tracked (0 freed, git-tracked preserved) and s-25h (freed)
    const measured1 = await cleanIdleRebuildable(r.hub, now, { idleMs: IDLE_REBUILD_MS, limit: 16 });
    assert.equal(measured1, 2);
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

    // Low-disk pass (1h threshold): skips already-measured s-25h & s-tracked; cleans s-23h and s-2h; preserves s-30m
    const relieved = await relieveIdleRebuildable(r.hub, () => 100, 1000, IDLE_REBUILD_LOW_MS);
    assert.equal(relieved, 2);
    assert.ok(!existsSync(join(ws23h, "node_modules")), "23h idle cleaned on low disk");
    assert.ok(!existsSync(join(ws2h, "node_modules")), "2h idle cleaned on low disk");
    assert.ok(existsSync(join(ws30m, "node_modules")), "30m idle preserved even on low disk");
    assert.ok(existsSync(join(wsRunning, "node_modules")), "running session still preserved on low disk");
    assert.ok(existsSync(join(wsJob, "node_modules")), "active-job session still preserved on low disk");
    assert.ok(existsSync(join(wsTracked, "node_modules")), "git-tracked node_modules still preserved on low disk");

    await r.close();
  });

  test("memoizes measured sessions by lastActiveAt across rounds and re-measures after new activity", async () => {
    const measuredKeys: string[] = [];
    let coldRooms!: ColdRooms;
    const r = new Rig({
      cold: {
        isCold: (key) => coldRooms.isCold(key),
        restore: (key) => coldRooms.restore(key),
        pack: (key) => coldRooms.pack(key),
        cleanIdleRebuildable: async (key) => {
          const res = await coldRooms.cleanIdleRebuildable(key);
          if (res !== null) measuredKeys.push(key);
          return res;
        },
      },
    });
    coldRooms = new ColdRooms(() => r.hub);
    const data = r.hub.config().dataDir;
    const now = r.hub.now();
    const HOUR = 3_600_000;

    const ws = join(data, "sessions", "cl", "s-memo", "workspace");
    mkdirSync(ws, { recursive: true });
    writeFileSync(join(ws, "index.ts"), "export {};\n");
    const firstActive = now - 30 * HOUR;
    r.store.insertSession({
      key: "s-memo", connect: "cl", runtime: "claude", profile: "cc",
      workspace: ws, runtimeSessionId: null, token: "tok-memo", createdAt: firstActive, lastActiveAt: firstActive,
    });

    // Round 1: measures s-memo once (0 bytes freed, still counts toward cap and gets memoized)
    assert.equal(await cleanIdleRebuildable(r.hub, now, { idleMs: IDLE_REBUILD_MS, limit: 1 }), 1);
    assert.deepEqual(measuredKeys, ["s-memo"]);

    // Round 2 (same lastActiveAt): skipped — NOT measured again!
    assert.equal(await cleanIdleRebuildable(r.hub, now + HOUR, { idleMs: IDLE_REBUILD_MS, limit: 1 }), 0);
    assert.deepEqual(measuredKeys, ["s-memo"]);

    // Low-disk pass (same lastActiveAt): shares memo — also NOT measured again!
    assert.equal(await relieveIdleRebuildable(r.hub, () => 0, 1000, IDLE_REBUILD_LOW_MS), 0);
    assert.deepEqual(measuredKeys, ["s-memo"]);

    // Session becomes active again (last_active_at updates) and grows node_modules, then idles >24h again
    const secondActive = now + 2 * HOUR;
    r.store.db.prepare("UPDATE sessions SET last_active_at = ? WHERE key = ?").run(secondActive, "s-memo");
    mkdirSync(join(ws, "node_modules", "pkg"), { recursive: true });
    writeFileSync(join(ws, "node_modules", "pkg", "a.js"), "1\n".repeat(50));

    assert.equal(await cleanIdleRebuildable(r.hub, secondActive + 25 * HOUR, { idleMs: IDLE_REBUILD_MS, limit: 1 }), 1);
    assert.deepEqual(measuredKeys, ["s-memo", "s-memo"]);
    assert.ok(!existsSync(join(ws, "node_modules")), "re-measured and cleaned after new activity");

    await r.close();
  });

  test("unrelated active job appearing mid-cleanup with an unfollowed cwd does not abort cleanup or drop remaining rebuildables", async () => {
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

    const wsA = join(data, "sessions", "cl", "s-a-unrel", "workspace");
    mkdirSync(join(wsA, "a", "node_modules", "pkg"), { recursive: true });
    writeFileSync(join(wsA, "a", "node_modules", "pkg", "index.js"), "1\n".repeat(50));
    mkdirSync(join(wsA, "b", "node_modules", "pkg"), { recursive: true });
    writeFileSync(join(wsA, "b", "node_modules", "pkg", "index.js"), "2\n".repeat(50));
    const at = now - 30 * HOUR;
    r.store.insertSession({
      key: "s-a-unrel", connect: "cl", runtime: "claude", profile: "cc",
      workspace: wsA, runtimeSessionId: null, token: "tok-a-unrel", createdAt: at, lastActiveAt: at,
    });

    const unrelatedCwd = fresh("unrelated-job-cwd");
    const origJobsUp = r.store.jobsUp.bind(r.store);
    let jobsUpCalls = 0;
    let injected = false;
    r.store.jobsUp = () => {
      jobsUpCalls++;
      // Call 1 is followInUse, call 2 is cleanableRoom.hasJobs; call 3 is the first loop iteration inside cleanRebuildableIn.
      if (!injected && jobsUpCalls === 3) {
        injected = true;
        r.store.insertJob({
          id: "j-unrel-new", sessionKey: "s-other", name: "other", command: "sleep 60", cwd: unrelatedCwd,
          port: null, token: "jtok-unrel-new", state: "running", pgid: 99991, exitCode: null,
          startedAt: now, endedAt: null, restarts: 0, log: join(data, "jobs", "j-unrel-new.log"), watch: false,
        });
      }
      return origJobsUp();
    };

    const measured = await cleanIdleRebuildable(r.hub, now, { idleMs: IDLE_REBUILD_MS, limit: 16 });
    assert.equal(measured, 1, "unrelated job must not abort cleanup");
    assert.ok(!existsSync(join(wsA, "a", "node_modules")), "first rebuildable cleaned");
    assert.ok(!existsSync(join(wsA, "b", "node_modules")), "second rebuildable cleaned despite unrelated job");
    assert.equal(r.hub.idleMeasured.get("s-a-unrel"), at, "completed session recorded in idleMeasured");

    await r.close();
  });

  test("mid-cleanup interruption by a job on the target session does not poison idleMeasured, and next round finishes cleanup", async () => {
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

    const ws = join(data, "sessions", "cl", "s-interrupt", "workspace");
    const firstDir = join(ws, "a", "node_modules");
    const secondDir = join(ws, "b", "node_modules");
    mkdirSync(join(firstDir, "pkg"), { recursive: true });
    writeFileSync(join(firstDir, "pkg", "index.js"), "1\n".repeat(50));
    mkdirSync(join(secondDir, "pkg"), { recursive: true });
    writeFileSync(join(secondDir, "pkg", "index.js"), "2\n".repeat(50));
    const at = now - 30 * HOUR;
    r.store.insertSession({
      key: "s-interrupt", connect: "cl", runtime: "claude", profile: "cc",
      workspace: ws, runtimeSessionId: null, token: "tok-interrupt", createdAt: at, lastActiveAt: at,
    });

    const origJobsUp = r.store.jobsUp.bind(r.store);
    let injected = false;
    r.store.jobsUp = () => {
      // Once one of the two rebuildable directories is gone, start a job belonging to s-interrupt before the second is removed.
      if (!injected && (!existsSync(firstDir) || !existsSync(secondDir))) {
        injected = true;
        r.store.insertJob({
          id: "j-int", sessionKey: "s-interrupt", name: "build", command: "sleep 60", cwd: ws,
          port: null, token: "jtok-int", state: "running", pgid: 99992, exitCode: null,
          startedAt: now, endedAt: null, restarts: 0, log: join(data, "jobs", "j-int.log"), watch: false,
        });
      }
      return origJobsUp();
    };

    const m1 = await cleanIdleRebuildable(r.hub, now, { idleMs: IDLE_REBUILD_MS, limit: 16 });
    assert.equal(m1, 0, "interrupted cleanup must return null and not count as measured");
    assert.equal(injected, true, "job was injected between the two rebuildable directories");
    const remaining1 = [firstDir, secondDir].filter((d) => existsSync(d));
    assert.equal(remaining1.length, 1, "first directory removed, second preserved when interrupted");
    assert.equal(r.hub.idleMeasured.has("s-interrupt"), false, "interrupted session must not be recorded in idleMeasured");

    // End the job and run another round: the remaining directory is cleaned and the session is now memoized.
    r.store.jobsUp = origJobsUp;
    r.store.db.prepare("UPDATE jobs SET state = 'exited', ended_at = ? WHERE id = ?").run(now + 1000, "j-int");
    const m2 = await cleanIdleRebuildable(r.hub, now + 2000, { idleMs: IDLE_REBUILD_MS, limit: 16 });
    assert.equal(m2, 1, "second round completes cleanup after job ends");
    assert.ok(!existsSync(firstDir) && !existsSync(secondDir), "both rebuildable directories removed");
    assert.equal(r.hub.idleMeasured.get("s-interrupt"), at, "completed session recorded in idleMeasured");

    await r.close();
  });

  test("incomplete walk (duration, or entries with freed > 0) returns null without poisoning idleMeasured; depth cut still completes", async () => {
    const roomReply = new Map<string, { bytes: number; rebuild: [string, number][]; complete: boolean; reason?: string }>();
    let coldRooms!: ColdRooms;
    const r = new Rig({
      cold: {
        isCold: (key) => coldRooms.isCold(key),
        restore: (key) => coldRooms.restore(key),
        pack: (key) => coldRooms.pack(key),
        cleanIdleRebuildable: (key) => coldRooms.cleanIdleRebuildable(key),
      },
    });
    coldRooms = new ColdRooms(() => r.hub, {
      measureRoom: async (dir) => {
        const reply = roomReply.get(dir);
        assert.ok(reply, `no measurement for ${dir}`);
        return reply;
      },
    });
    const data = realpathSync(r.hub.config().dataDir);
    const now = r.hub.now();
    const HOUR = 3_600_000;
    const at = now - 30 * HOUR;

    const add = (key: string, opts: { withRebuild?: boolean; reason: string }) => {
      const ws = join(data, "sessions", "cl", key, "workspace");
      const nm = join(ws, "node_modules");
      if (opts.withRebuild) {
        mkdirSync(join(nm, "pkg"), { recursive: true });
        writeFileSync(join(nm, "pkg", "index.js"), "1\n".repeat(20));
      } else {
        mkdirSync(ws, { recursive: true });
      }
      r.store.insertSession({
        key, connect: "cl", runtime: "claude", profile: "cc",
        workspace: ws, runtimeSessionId: null, token: `tok-${key}`, createdAt: at, lastActiveAt: at,
      });
      roomReply.set(dirname(ws), {
        bytes: opts.withRebuild ? 4096 : 0,
        rebuild: opts.withRebuild ? [[nm, 4096]] : [],
        complete: false,
        reason: opts.reason,
      });
      return { ws, nm };
    };

    const dur = add("s-cut-dur", { withRebuild: true, reason: "duration" });
    const entFreed = add("s-cut-ent-freed", { withRebuild: true, reason: "entries" });
    const entNone = add("s-cut-ent-none", { withRebuild: false, reason: "entries" });
    const dep = add("s-cut-depth", { withRebuild: true, reason: "depth" });

    const measured = await cleanIdleRebuildable(r.hub, now, { idleMs: IDLE_REBUILD_MS, limit: 16 });
    assert.equal(measured, 2, "only entries-with-0-freed and depth-cut count as completed");
    assert.ok(!existsSync(dur.nm), "duration-cut still removed what it found");
    assert.ok(!existsSync(entFreed.nm), "entries-cut still removed what it found");
    assert.ok(!existsSync(dep.nm), "depth-cut removed what it found");
    assert.equal(r.hub.idleMeasured.has("s-cut-dur"), false, "duration-cut must not poison idleMeasured");
    assert.equal(r.hub.idleMeasured.has("s-cut-ent-freed"), false, "entries-cut with freed > 0 must not poison idleMeasured");
    assert.equal(r.hub.idleMeasured.get("s-cut-ent-none"), at, "entries-cut with freed === 0 completes to avoid infinite loop");
    assert.equal(r.hub.idleMeasured.get("s-cut-depth"), at, "depth-cut completes to avoid infinite loop");

    await r.close();
  });
});

describe("Item 3: orphan session rooms in Upkeep", () => {
  test("prunes >24h orphan rooms with worktree registrations while preserving session-backed, <24h, active-job, and outside-<data> dirs", async () => {
    const data = fresh("item3-rooms");
    const external = fresh("item3-ext");
    const store = Store.open(join(data, "stillfail.db"));
    const now = 1_800_000_000_000;
    const HOUR = 3_600_000;

    const repo = join(data, "repos", "demo");
    mkdirSync(repo, { recursive: true });
    git(repo, ["init", "-b", "main"]);
    writeFileSync(join(repo, "README.md"), "hi\n");
    git(repo, ["add", "README.md"]);
    git(repo, ["commit", "-m", "init"]);

    const oldOrphanRoom = join(data, "sessions", "cl", "orphan-old");
    const oldOrphanWs = join(oldOrphanRoom, "workspace");
    mkdirSync(oldOrphanWs, { recursive: true });
    git(repo, ["worktree", "add", "-b", "b-orphan", join(oldOrphanWs, "wt-orphan")]);
    setMtime(oldOrphanWs, now - 25 * HOUR);
    setMtime(oldOrphanRoom, now - 25 * HOUR);

    const freshOrphanRoom = join(data, "sessions", "cl", "orphan-fresh");
    mkdirSync(join(freshOrphanRoom, "workspace"), { recursive: true });
    setMtime(join(freshOrphanRoom, "workspace"), now - 23 * HOUR);
    setMtime(freshOrphanRoom, now - 23 * HOUR);

    const liveRoom = join(data, "sessions", "cl", "live-room");
    const liveWs = join(liveRoom, "workspace");
    mkdirSync(liveWs, { recursive: true });
    setMtime(liveWs, now - 48 * HOUR);
    setMtime(liveRoom, now - 48 * HOUR);
    store.insertSession({
      key: "s-live", connect: "cl", runtime: "claude", profile: "cc",
      workspace: liveWs, runtimeSessionId: null, token: "tok-live", createdAt: now - 48 * HOUR, lastActiveAt: now - 48 * HOUR,
    });

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

  test("Upkeep runs pruneOrphanRooms on first round, skips within 24h, and runs again after ORPHAN_ROOM_EVERY_MS", async () => {
    const data = fresh("item3-cadence");
    const store = Store.open(join(data, "stillfail.db"));
    const tc = testClock();
    await tc.adjust(1_800_000_000_000);
    const t0 = tc.clock.currentTimeMillisUnsafe();
    const HOUR = 3_600_000;

    const r1 = join(data, "sessions", "cl", "orphan-1");
    mkdirSync(join(r1, "workspace"), { recursive: true });
    setMtime(join(r1, "workspace"), t0 - 25 * HOUR);
    setMtime(r1, t0 - 25 * HOUR);

    const upkeep = new Upkeep({ data, clock: tc.clock, orphans: store });
    await upkeep.run();
    assert.ok(!existsSync(r1), "first round pruned orphan-1");

    // Create another >24h orphan room 1h later: Upkeep skips within ORPHAN_ROOM_EVERY_MS
    await tc.adjust(HOUR);
    const t1 = tc.clock.currentTimeMillisUnsafe();
    const r2 = join(data, "sessions", "cl", "orphan-2");
    mkdirSync(join(r2, "workspace"), { recursive: true });
    setMtime(join(r2, "workspace"), t1 - 25 * HOUR);
    setMtime(r2, t1 - 25 * HOUR);
    await upkeep.run();
    assert.ok(existsSync(r2), "skipped within 24h cadence");

    // Advance past ORPHAN_ROOM_EVERY_MS: Upkeep runs orphan room scan again
    await tc.adjust(ORPHAN_ROOM_EVERY_MS);
    await upkeep.run();
    assert.ok(!existsSync(r2), "pruned once 24h cadence elapsed");

    await upkeep.close();
    store.close();
  });
});

describe("Item 4: low-disk orphan UUID transcripts & full low-disk pass with 30m cooldown", () => {
  test("relieveOrphanTranscripts deletes only >7d unreferenced UUID transcripts & companion/standalone UUID dirs under <data>, preserving memory/, non-UUIDs, <7d, fresh child in UUID dir, archived refs, and outside-<data>", async () => {
    const data = fresh("item4-tx");
    const external = fresh("item4-tx-ext");
    const store = Store.open(join(data, "stillfail.db"));
    const now = 1_800_000_000_000;
    const DAY = 24 * 3_600_000;

    const uArchived = "11111111-1111-4111-8111-111111111111";
    const uOrphanOld = "22222222-2222-4222-8222-222222222222";
    const uOrphanNew = "33333333-3333-4333-8333-333333333333";
    const uStandaloneOld = "44444444-4444-4444-8444-444444444444";
    const uStandaloneFreshChild = "55555555-5555-4555-8555-555555555555";
    const uCodexOld = "66666666-6666-4666-8666-666666666666";
    const uCodexNew = "77777777-7777-4777-8777-777777777777";
    const uExternal = "88888888-8888-4888-8888-888888888888";

    const wsArch = join(data, "sessions", "cl", "s-arch", "workspace");
    mkdirSync(wsArch, { recursive: true });
    store.insertSession({
      key: "s-arch", connect: "cl", runtime: "claude", profile: "cc",
      workspace: wsArch, runtimeSessionId: uArchived, token: "tok-arch", createdAt: now - 10 * DAY, lastActiveAt: now - 10 * DAY,
    });
    store.ranIn("s-arch", uArchived, "cc");
    store.setArchived("s-arch", true, MANUAL);

    const proj = claudeProject(wsArch);
    const claudeDir = join(data, "transcripts", "claude", proj);
    mkdirSync(claudeDir, { recursive: true });

    // 1. projects/<proj>/memory/ with 8-day-old file -> MUST NEVER delete
    const memoryDir = join(claudeDir, "memory");
    mkdirSync(memoryDir, { recursive: true });
    const memoryFile = join(memoryDir, "MEMORY.md");
    writeFileSync(memoryFile, "# agent memory\n");
    setMtime(memoryFile, now - 8 * DAY);
    setMtime(memoryDir, now - 8 * DAY);

    // 2. Non-UUID .jsonl files (8d old) -> MUST NEVER delete
    const nonUuidFile = join(claudeDir, "notes.jsonl");
    const agentFile = join(claudeDir, "agent-a1b2c3.jsonl");
    writeFileSync(nonUuidFile, "{}\n");
    writeFileSync(agentFile, "{}\n");
    setMtime(nonUuidFile, now - 8 * DAY);
    setMtime(agentFile, now - 8 * DAY);

    // 3. 8d unreferenced UUID .jsonl + <uuid>/tool-results/x.txt -> MUST delete
    const oldUuidFile = join(claudeDir, `${uOrphanOld}.jsonl`);
    const oldUuidDir = join(claudeDir, uOrphanOld);
    mkdirSync(join(oldUuidDir, "tool-results"), { recursive: true });
    writeFileSync(oldUuidFile, "{}\n");
    writeFileSync(join(oldUuidDir, "tool-results", "x.txt"), "out\n");
    setMtime(oldUuidFile, now - 8 * DAY);
    setMtime(join(oldUuidDir, "tool-results", "x.txt"), now - 8 * DAY);
    setMtime(join(oldUuidDir, "tool-results"), now - 8 * DAY);
    setMtime(oldUuidDir, now - 8 * DAY);

    // 4. 6d unreferenced UUID .jsonl -> MUST keep (<7d)
    const newUuidFile = join(claudeDir, `${uOrphanNew}.jsonl`);
    writeFileSync(newUuidFile, "{}\n");
    setMtime(newUuidFile, now - 6 * DAY);

    // 5. 8d UUID referenced by archived session -> MUST keep
    const archUuidFile = join(claudeDir, `${uArchived}.jsonl`);
    writeFileSync(archUuidFile, "{}\n");
    setMtime(archUuidFile, now - 8 * DAY);

    // 6. Standalone 8d <uuid>/ with no main file -> MUST delete
    const standaloneOldDir = join(claudeDir, uStandaloneOld);
    mkdirSync(join(standaloneOldDir, "tool-results"), { recursive: true });
    writeFileSync(join(standaloneOldDir, "tool-results", "old.txt"), "old\n");
    setMtime(join(standaloneOldDir, "tool-results", "old.txt"), now - 8 * DAY);
    setMtime(join(standaloneOldDir, "tool-results"), now - 8 * DAY);
    setMtime(standaloneOldDir, now - 8 * DAY);

    // 7. Standalone <uuid>/ whose dir mtime is 8d old, but contains a 1d-old file -> MUST keep
    const standaloneFreshDir = join(claudeDir, uStandaloneFreshChild);
    mkdirSync(join(standaloneFreshDir, "tool-results"), { recursive: true });
    const freshChild = join(standaloneFreshDir, "tool-results", "recent.txt");
    writeFileSync(freshChild, "recent\n");
    setMtime(freshChild, now - 1 * DAY);
    setMtime(standaloneFreshDir, now - 8 * DAY);

    // 8. Codex rollouts (8d old -> delete, 6d old -> keep)
    const codexDir = join(data, "homes", "cx", "sessions", "2026", "11", "10");
    mkdirSync(codexDir, { recursive: true });
    const oldCodex = join(codexDir, `rollout-2026-11-10T00-00-00-${uCodexOld}.jsonl`);
    const newCodex = join(codexDir, `rollout-2026-11-14T00-00-00-${uCodexNew}.jsonl`);
    writeFileSync(oldCodex, "{}\n");
    writeFileSync(newCodex, "{}\n");
    setMtime(oldCodex, now - 8 * DAY);
    setMtime(newCodex, now - 6 * DAY);

    // 9. Outside <data> via symlink in <data>/homes -> MUST keep
    const extProfile = join(external, "user-home");
    mkdirSync(join(extProfile, "projects", proj), { recursive: true });
    const extFile = join(extProfile, "projects", proj, `${uExternal}.jsonl`);
    writeFileSync(extFile, "{}\n");
    setMtime(extFile, now - 8 * DAY);
    symlinkSync(extProfile, join(data, "homes", "ext-link"));

    // Not below low disk -> nothing deleted
    const none = await relieveOrphanTranscripts(data, now, store, () => 2000, 1000, { minAgeMs: ORPHAN_TRANSCRIPT_MS });
    assert.deepEqual(none, []);
    assert.ok(existsSync(oldUuidFile), "untouched when disk is not below low");

    // Below low disk (full=true): deletes all eligible even if free() rises above low mid-pass
    let calls = 0;
    const gone = await relieveOrphanTranscripts(
      data,
      now,
      store,
      () => (++calls === 1 ? 100 : 5000),
      1000,
      { minAgeMs: ORPHAN_TRANSCRIPT_MS, full: true },
    );
    assert.ok(!existsSync(oldUuidFile), "8d orphan UUID .jsonl deleted");
    assert.ok(!existsSync(oldUuidDir), "8d orphan companion <uuid>/ deleted");
    assert.ok(!existsSync(standaloneOldDir), "8d standalone <uuid>/ deleted");
    assert.ok(!existsSync(oldCodex), "8d orphan Codex rollout deleted");
    assert.ok(existsSync(memoryFile), "projects/<proj>/memory/ preserved");
    assert.ok(existsSync(nonUuidFile), "non-UUID .jsonl preserved");
    assert.ok(existsSync(agentFile), "agent-xxxx.jsonl preserved");
    assert.ok(existsSync(newUuidFile), "6d orphan UUID .jsonl preserved");
    assert.ok(existsSync(archUuidFile), "archived-session-referenced UUID preserved");
    assert.ok(existsSync(freshChild), "standalone <uuid>/ with 1d child preserved");
    assert.ok(existsSync(newCodex), "6d orphan Codex rollout preserved");
    assert.ok(existsSync(extFile), "outside-<data> transcript preserved");
    assert.ok(gone.length >= 3);

    store.close();
  });

  test("relieveLowDiskFull runs all steps without stopping early when free rises above low, and respects 30m RELIEVE_FULL_EVERY_MS cooldown", async () => {
    const tc = testClock();
    await tc.adjust(1_800_000_000_000);
    let coldRooms!: ColdRooms;
    const r = new Rig({
      clock: tc.clock,
      cold: {
        isCold: (key) => coldRooms.isCold(key),
        restore: (key) => coldRooms.restore(key),
        pack: (key) => coldRooms.pack(key),
        holdsMore: (key) => coldRooms.holdsMore(key),
        expire: (key, before) => coldRooms.expire(key, before),
        cleanIdleRebuildable: (key) => coldRooms.cleanIdleRebuildable(key),
      },
    });
    coldRooms = new ColdRooms(() => r.hub);
    const data = r.hub.config().dataDir;
    const now = r.hub.now();
    const HOUR = 3_600_000;
    const MIN = 60_000;

    // Two 2h-idle unarchived sessions: even when free() rises above low after the first, full pass cleans BOTH!
    const makeIdle = (key: string) => {
      const ws = join(data, "sessions", "cl", key, "workspace");
      mkdirSync(join(ws, "node_modules", "pkg"), { recursive: true });
      writeFileSync(join(ws, "node_modules", "pkg", "a.js"), "1\n".repeat(50));
      r.store.insertSession({
        key, connect: "cl", runtime: "claude", profile: "cc",
        workspace: ws, runtimeSessionId: null, token: `tok-${key}`, createdAt: now - 2 * HOUR, lastActiveAt: now - 2 * HOUR,
      });
      return ws;
    };
    const ws1 = makeIdle("s-full-1");
    const ws2 = makeIdle("s-full-2");

    let freeCalls = 0;
    const ran1 = await relieveLowDiskFull(r.hub, () => (++freeCalls === 1 ? 100 : 10_000), 1000);
    assert.equal(ran1, true);
    assert.ok(!existsSync(join(ws1, "node_modules")), "full pass cleaned s-full-1");
    assert.ok(!existsSync(join(ws2, "node_modules")), "full pass did not stop early when free rose above low");

    // Create a 3rd eligible session and trigger 29 minutes later -> skipped due to RELIEVE_FULL_EVERY_MS (30m)
    await tc.adjust(29 * MIN);
    const ws3 = makeIdle("s-full-3");
    const ran29 = await relieveLowDiskFull(r.hub, () => 100, 1000);
    assert.equal(ran29, false, "within 30m cooldown, full pass does nothing");
    assert.ok(existsSync(join(ws3, "node_modules")), "s-full-3 untouched at 29m");

    // Advance 2 more minutes (total 31m >= RELIEVE_FULL_EVERY_MS) -> runs again and cleans s-full-3
    await tc.adjust(2 * MIN);
    const ran31 = await relieveLowDiskFull(r.hub, () => 100, 1000);
    assert.equal(ran31, true, "after 31m, full pass runs again");
    assert.ok(!existsSync(join(ws3, "node_modules")), "s-full-3 cleaned at 31m");

    // Non-full relieveArchived still stops early when free >= low
    const ranAbove = await relieveArchived(r.hub, () => 5000, 1000);
    assert.equal(ranAbove, undefined);

    await r.close();
  });

  test("relieveLowDiskFull isolates step 2 errors: steps 3 and 4 still run and 30m cooldown is recorded", async () => {
    const tc = testClock();
    await tc.adjust(1_800_000_000_000);
    const r = new Rig({
      clock: tc.clock,
      cold: {
        isCold: async () => false,
        restore: () => undefined,
        pack: async () => {},
        holdsMore: async () => true,
        expire: async () => {},
        cleanIdleRebuildable: async () => 0,
      },
    });
    const data = r.hub.config().dataDir;
    const now = r.hub.now();
    const DAY = 24 * 3_600_000;
    const MIN = 60_000;

    // Make step 2 (relieveArchived) throw synchronously before finishing
    const origLastArchived = r.store.lastArchivedSession.bind(r.store);
    r.store.lastArchivedSession = () => {
      throw new Error("simulated step 2 failure");
    };

    // Step 3 target: an 8-day-old orphan UUID Claude transcript
    const uOrphan = "11111111-1111-4111-8111-111111111111";
    const txDir = join(data, "transcripts", "claude", "proj-step2-err");
    mkdirSync(txDir, { recursive: true });
    const orphanTx = join(txDir, `${uOrphan}.jsonl`);
    writeFileSync(orphanTx, "{}\n");
    setMtime(orphanTx, now - 8 * DAY);

    // Step 4 target: an unreferenced 20-day-old clean shared clone under <data>/repos
    const repoDir = join(data, "repos", "old-shared-clone");
    mkdirSync(join(repoDir, ".git"), { recursive: true });
    writeFileSync(join(repoDir, ".git", "HEAD"), "ref: refs/heads/main\n");
    setMtime(join(repoDir, ".git", "HEAD"), now - 20 * DAY);

    const ran = await relieveLowDiskFull(r.hub, () => 100, 1000, {
      git: async (_dir, args) => {
        if (args[0] === "remote" && args.length === 1) return { ok: true, stdout: "origin\n" };
        if (args[0] === "remote" && args[1] === "get-url") return { ok: true, stdout: "https://github.com/org/repo.git\n" };
        if (args[0] === "rev-list") return { ok: true, stdout: "0\n" };
        return { ok: true, stdout: "" };
      },
    });
    assert.equal(ran, true);
    assert.ok(!existsSync(orphanTx), "step 3 (orphan transcripts) ran despite step 2 throwing");
    assert.ok(!existsSync(repoDir), "step 4 (shared clones) ran despite step 2 throwing");

    // Restore step 2 and verify 30m cooldown was still recorded
    r.store.lastArchivedSession = origLastArchived;
    await tc.adjust(10 * MIN);
    const ranAgain = await relieveLowDiskFull(r.hub, () => 100, 1000);
    assert.equal(ranAgain, false, "cooldown recorded even when step 2 threw");

    await r.close();
  });

  test("relieveOrphanTranscripts full mode reclaims more than 64 eligible transcripts across projects (no 64 cap)", async () => {
    const data = mkdtempSync(join(tmpdir(), "sf-orphan-tx-full-"));
    const store = Store.open(join(data, "stillfail.db"));
    const now = 1_800_000_000_000;
    const DAY = 24 * 3_600_000;

    try {
      // Create 75 eligible 8-day-old orphan UUID transcripts spread across 3 project directories
      const created: string[] = [];
      for (let i = 0; i < 75; i++) {
        const projDir = join(data, "transcripts", "claude", `proj-${i % 3}`);
        mkdirSync(projDir, { recursive: true });
        const hex = i.toString(16).padStart(12, "0");
        const uuid = `22222222-2222-4222-8222-${hex}`;
        const f = join(projDir, `${uuid}.jsonl`);
        writeFileSync(f, "{}\n");
        setMtime(f, now - 8 * DAY);
        created.push(f);
      }

      const gone = await relieveOrphanTranscripts(data, now, store, () => 100, 1000, { full: true });
      assert.equal(gone.length, 75, "full mode reclaims all 75 eligible transcripts (> 64)");
      for (const f of created) {
        assert.ok(!existsSync(f), `${f} removed`);
      }
    } finally {
      store.close();
      rmSync(data, { recursive: true, force: true });
    }
  });

  test("runArchiveUpkeepIfDue enforces ARCHIVE_UPKEEP_EVERY_MS (10m): skips startup, runs once across 3x1s triggers, runs again after 10m", async () => {
    const tc = testClock();
    await tc.adjust(1_800_000_000_000);
    let needsPackCalls = 0;
    let cleanIdleCalls = 0;
    const r = new Rig({
      clock: tc.clock,
      cold: {
        isCold: async () => false,
        restore: () => undefined,
        pack: async () => {},
        needsPack: async () => {
          needsPackCalls++;
          return false;
        },
        cleanIdleRebuildable: async () => {
          cleanIdleCalls++;
          return null;
        },
      },
    });
    const data = r.hub.config().dataDir;
    const now = r.hub.now();
    const DAY = 24 * 3_600_000;

    // One archived session + one >24h idle unarchived session so each upkeep round invokes both callbacks.
    const wsArch = join(data, "sessions", "cl", "s-cadence-arch", "workspace");
    const wsIdle = join(data, "sessions", "cl", "s-cadence-idle", "workspace");
    mkdirSync(wsArch, { recursive: true });
    mkdirSync(wsIdle, { recursive: true });
    r.store.insertSession({
      key: "s-cadence-arch", connect: "cl", runtime: "claude", profile: "cc",
      workspace: wsArch, runtimeSessionId: null, token: "tok-ca", createdAt: now - 2 * DAY, lastActiveAt: now - 2 * DAY,
    });
    r.store.setArchived("s-cadence-arch", true, MANUAL);
    r.store.db.prepare("UPDATE sessions SET archived_at = ? WHERE key = ?").run(now - 2 * DAY, "s-cadence-arch");
    r.store.insertSession({
      key: "s-cadence-idle", connect: "cl", runtime: "claude", profile: "cc",
      workspace: wsIdle, runtimeSessionId: null, token: "tok-ci", createdAt: now - 2 * DAY, lastActiveAt: now - 2 * DAY,
    });

    // At startup (t = 0): lastArchiveUpkeepAt was initialized to startup time -> skipped
    assert.equal(await runArchiveUpkeepIfDue(r.hub, r.hub.now()), false, "skipped immediately at startup");
    assert.equal(needsPackCalls, 0);
    assert.equal(cleanIdleCalls, 0);

    // Advance 10 minutes, then trigger 3 times 1 second apart -> runs only once
    await tc.adjust(ARCHIVE_UPKEEP_EVERY_MS);
    assert.equal(await runArchiveUpkeepIfDue(r.hub, r.hub.now()), true, "runs on 1st trigger at +10m");
    await tc.adjust(1_000);
    assert.equal(await runArchiveUpkeepIfDue(r.hub, r.hub.now()), false, "2nd trigger +1s skipped");
    await tc.adjust(1_000);
    assert.equal(await runArchiveUpkeepIfDue(r.hub, r.hub.now()), false, "3rd trigger +2s skipped");
    assert.equal(needsPackCalls, 1, "packUnfinishedArchived ran once across 3x1s triggers");
    assert.equal(cleanIdleCalls, 1, "cleanIdleRebuildable ran once across 3x1s triggers");

    // Advance another 10 minutes -> runs a 2nd time
    await tc.adjust(ARCHIVE_UPKEEP_EVERY_MS);
    assert.equal(await runArchiveUpkeepIfDue(r.hub, r.hub.now()), true, "runs a 2nd time after another 10m");
    assert.equal(needsPackCalls, 2);
    assert.equal(cleanIdleCalls, 2);

    await r.close();
  });
});
