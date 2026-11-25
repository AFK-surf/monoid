// Other stations' rooms here held to their budget (src/jobs/remote.ts `budget`): remote/sessions grew to 63 GiB of a
// station in five days (2026-11-15) as it was only made room in once the disk was under 20 GiB. Over its budget, the
// mirrors not in use go first and then the rooms unused the longest; a room a task runs in, or one used within the hour,
// stays. And tasks long over let go of (`expire`): 3,255 records of a session's tasks were never swept.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, test } from "node:test";
import { hearLines, type Line } from "../src/ops/log.ts";
import { timeFiles } from "../src/ops/file-waits.ts";
import { killGroups } from "./kill-groups.ts";
import { Jobs } from "../src/jobs/jobs.ts";
import { ROOM_RECENT_MS, Remote, TASKS_KEPT_MS, hash, latestIn, remoteBudget } from "../src/jobs/remote.ts";
import { Store } from "../src/store/store.ts";

const dirs: string[] = [];
const cleanup: (() => Promise<void> | void)[] = [];
after(async () => {
  for (const c of cleanup.reverse()) await c();
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function station() {
  const dir = mkdtempSync(join(tmpdir(), "remote-budget-"));
  dirs.push(dir);
  const store = Store.open(":memory:");
  const jobs = new Jobs({ store, data: dir, notify: () => {}, link: () => null });
  const remote = new Remote({ data: dir, store, jobs, notify: () => {}, version: "0.1.1" });
  cleanup.push(async () => {
    await remote.close();
    await jobs.shutdown();
    await killGroups(store.listJobs(null).map((job) => job.pgid));
    store.close();
  });
  return { dir, store, jobs, remote };
}

const MiB = 1024 ** 2;

/// A source session's room here, last used at `seen`, with `bytes` of work in it.
function room(r: ReturnType<typeof station>, session: string, seen: number, bytes: number): string {
  const dir = r.remote.room("ws", "peer-a", session);
  mkdirSync(join(dir, "work"), { recursive: true });
  writeFileSync(join(dir, "session.json"), JSON.stringify({ workspace: "ws", station: "peer-a", session, seen }));
  writeFileSync(join(dir, "work", "made"), Buffer.alloc(bytes, 1));
  return dir;
}

describe("remote's budget", { concurrency: true }, () => {
  test("over its budget, mirrors unused go, then the rooms unused the longest; one a task runs in, and one used lately, stay", async () => {
    const r = station();
    const now = Date.now();
    const old = room(r, "old", now - 3 * 24 * 3600_000, MiB);
    // A mirror in it, unused for two days.
    mkdirSync(join(old, "mirrors"), { recursive: true });
    mkdirSync(join(old, "work", "big"), { recursive: true });
    writeFileSync(join(old, "work", "big", "f"), Buffer.alloc(3 * MiB, 1));
    writeFileSync(join(old, "mirrors", "big.json"), "{}");
    writeFileSync(join(old, "mirrors-used.json"), JSON.stringify({ big: now - 2 * 24 * 3600_000 }));
    const older = room(r, "older", now - 5 * 24 * 3600_000, 2 * MiB);
    const recent = room(r, "recent", now - ROOM_RECENT_MS / 2, 2 * MiB);
    // A task of "older"'s runs here.
    const task = hash(["ws", "peer-a", "older", "k"]);
    mkdirSync(join(r.remote.root, "incoming", task), { recursive: true });
    writeFileSync(join(r.remote.root, "incoming", task, "task.json"), JSON.stringify({ workspace: "ws", station: "peer-a", session: "older", key: "k", layout: "session", spec: { command: "x" } }));
    const running = await r.jobs.startId("remote:ws:peer-a:older", "k", "tail -f /dev/null", join(older, "work"), null, false, `remote_${task}`);

    const lines: Line[] = [];
    hearLines((line) => void lines.push(line));
    const freed = await r.remote.budget(now, 4.5 * MiB).finally(() => hearLines(null));
    assert.deepEqual(
      lines.filter((l) => l.message === "remote mirror removed" && l.fields.mirror === "big").map((l) => l.fields.why),
      ["over budget"],
      "the log says why: not a low disk",
    );
    assert.ok(freed >= 4 * MiB, `freed ${freed}`);
    assert.ok(!existsSync(join(old, "work", "big")), "the mirror unused went first");
    assert.ok(!existsSync(old), "then the room unused the longest with nothing running");
    assert.ok(existsSync(join(older, "work", "made")), "a room a task runs in stays");
    assert.ok(existsSync(join(recent, "work", "made")), "a room used within the hour stays");
    assert.equal(await r.remote.budget(now, 4.5 * MiB), 0, "within its budget: nothing");
    await r.jobs.stop(running.id);
  });

  test("its budget: 15% of the disk, however large; 32 GiB with its size not known", () => {
    assert.equal(remoteBudget(100 * 1024 ** 3), Math.floor(15 * 1024 ** 3));
    assert.equal(remoteBudget(1000 * 1024 ** 3), 150 * 1024 ** 3);
    assert.equal(remoteBudget(null), 32 * 1024 ** 3);
  });

  test("tasks long over are let go of: done here, and started from here and told their end", async () => {
    const r = station();
    const now = Date.now();
    const incoming = join(r.remote.root, "incoming");
    const outgoing = join(r.remote.root, "outgoing");
    const task = (key: string) => {
      const name = hash(["ws", "peer-a", "s", key]);
      mkdirSync(join(incoming, name), { recursive: true });
      writeFileSync(join(incoming, name, "task.json"), JSON.stringify({ workspace: "ws", station: "peer-a", session: "s", key, layout: "session", spec: { command: "x" } }));
      return name;
    };
    const longAgo = (now - TASKS_KEPT_MS - 60_000) / 1000;
    // One the store no longer has, unchanged long; one ended lately; one running.
    const gone = task("gone");
    utimesSync(join(incoming, gone, "task.json"), longAgo, longAgo);
    utimesSync(join(incoming, gone), longAgo, longAgo);
    const lately = task("lately");
    await r.jobs.startId("remote:ws:peer-a:s", "lately", "true", r.dir, null, false, `remote_${lately}`);
    const live = task("live");
    const running = await r.jobs.startId("remote:ws:peer-a:s", "live", "tail -f /dev/null", r.dir, null, false, `remote_${live}`);
    while (r.store.getJob(`remote_${lately}`)!.state === "running") await new Promise((res) => setTimeout(res, 5));
    // Started from here: told its end long ago; not told yet; told lately.
    const record = (name: string, delivered: boolean, at: number) => {
      writeFileSync(join(outgoing, name), JSON.stringify({ workspace: "ws", session: "s", station: "peer-a", key: name, delivered }));
      utimesSync(join(outgoing, name), at, at);
    };
    record("told.json", true, longAgo);
    record("untold.json", false, longAgo);
    record("fresh.json", true, now / 1000);

    assert.equal(await r.remote.expire(now), 2);
    assert.deepEqual([gone, lately, live].map((n) => existsSync(join(incoming, n))), [false, true, true]);
    assert.deepEqual(["told.json", "untold.json", "fresh.json"].map((n) => existsSync(join(outgoing, n))), [false, true, true]);
    // A week after it ended, the one that ended goes too.
    assert.equal(await r.remote.expire(r.store.getJob(`remote_${lately}`)!.endedAt! + TASKS_KEPT_MS + 1), 2);
    assert.equal(existsSync(join(incoming, lately)), false);
    assert.equal(existsSync(join(incoming, live)), true, "a running task's stays");
    await r.jobs.stop(running.id);
  });

  test("expire batches store lookups across more than 500 incoming directories via jobsEnds", async () => {
    const r = station();
    const now = Date.now();
    const incoming = join(r.remote.root, "incoming");
    mkdirSync(incoming, { recursive: true });
    const N = 550;
    const expiredAt = now - TASKS_KEPT_MS - 60_000;
    const keptAt = now - 60_000;
    for (let i = 0; i < N; i++) {
      const name = `task${i}`;
      mkdirSync(join(incoming, name), { recursive: true });
      writeFileSync(join(incoming, name, "task.json"), "{}");
      r.store.insertJob({
        id: `remote_${name}`, sessionKey: "remote:ws:peer-a:s", name, command: "true", cwd: r.dir,
        port: null, token: `t-${i}`, state: "exited", pgid: null, exitCode: 0,
        startedAt: expiredAt - 1000, endedAt: i < 10 ? expiredAt : keptAt,
        restarts: 0, log: join(r.dir, `${name}.log`), watch: false,
      });
    }
    let getJobCalls = 0;
    const batchSizes: number[] = [];
    const origGetJob = r.store.getJob.bind(r.store);
    const origJobsEnds = r.store.jobsEnds.bind(r.store);
    r.store.getJob = (id: string) => {
      getJobCalls++;
      return origGetJob(id);
    };
    r.store.jobsEnds = (ids: readonly string[]) => {
      batchSizes.push(ids.length);
      return origJobsEnds(ids);
    };
    const gone = await r.remote.expire(now);
    assert.equal(gone, 10);
    assert.equal(getJobCalls, 0, "expire uses jobsEnds rather than per-directory getJob");
    assert.deepEqual(batchSizes.sort((a, b) => b - a), [500, 50]);
    for (let i = 0; i < 10; i++) assert.equal(existsSync(join(incoming, `task${i}`)), false);
    for (let i = 10; i < N; i++) assert.equal(existsSync(join(incoming, `task${i}`)), true);
  });

  test("when a tree last changed is not looked for past its bound, nor on another disk", async () => {
    const dir = mkdtempSync(join(tmpdir(), "latest-"));
    dirs.push(dir);
    mkdirSync(join(dir, "a"));
    for (let i = 0; i < 5; i++) writeFileSync(join(dir, "a", `f${i}`), "x");
    utimesSync(join(dir, "a", "f3"), 2_000_000_000, 2_000_000_000);
    assert.equal(await latestIn(dir), 2_000_000_000_000);
    assert.equal(await latestIn(dir, 3), Infinity, "past its bound: kept");
  });
});

// On its own (not beside the tests above): the station's synchronous file calls are counted while it runs.
test("over its budget, a room a task runs in is kept with nothing read on the station's thread: the tasks' records are the program's", async () => {
  const r = station();
  const now = Date.now();
  // Over its budget only by rooms that stay: one a task runs in, unused for days; one used within the hour.
  const busy = room(r, "busy", now - 5 * 24 * 3600_000, 2 * MiB);
  const recent = room(r, "recent", now - ROOM_RECENT_MS / 2, 2 * MiB);
  const task = hash(["ws", "peer-a", "busy", "k"]);
  mkdirSync(join(r.remote.root, "incoming", task), { recursive: true });
  writeFileSync(join(r.remote.root, "incoming", task, "task.json"), JSON.stringify({ workspace: "ws", station: "peer-a", session: "busy", key: "k", layout: "session", spec: { command: "x" } }));
  const running = await r.jobs.startId("remote:ws:peer-a:busy", "k", "tail -f /dev/null", join(busy, "work"), null, false, `remote_${task}`);
  const files = timeFiles();
  try {
    files.take();
    assert.equal(await r.remote.budget(now, MiB), 0, "nothing of them goes");
    assert.equal(files.take().calls, 0, "no synchronous file call: the running task's record is read off the thread");
  } finally {
    files.stop();
  }
  assert.ok(existsSync(join(busy, "work", "made")), "the room a task runs in stays");
  assert.ok(existsSync(join(recent, "work", "made")), "the room used within the hour stays");
  await r.jobs.stop(running.id);
});
