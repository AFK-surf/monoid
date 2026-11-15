// Jobs' files held to their bounds (src/jobs/jobs.ts `upkeep`, `collect`): a log cut where it is while its job appends
// to it, and read on across the cut; the files of jobs long over or gone collected; and what a job left running in its
// group when its shell ended made to end (a VM's jobs left orphans of ppid 1, 2026-11-15). Real jobs, as jobs.test.ts.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { appendFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, test } from "node:test";
import { groupAlive, signalGroup } from "../src/ops/group.ts";
import { JOB_FILES_ORPHAN_MS, JOB_LOGS_KEPT_MS, Jobs, tail } from "../src/jobs/jobs.ts";
import { JOB_LOG_CAP } from "../src/ops/storage.ts";
import { Store } from "../src/store/store.ts";
import { WINDOWS } from "../src/platform/index.ts";

const dirs: string[] = [];
const all: Jobs[] = [];
const stores: Store[] = [];
after(async () => {
  for (const j of all) {
    for (const job of j.store.listJobs(null)) if (job.pgid !== null) signalGroup(job.pgid, "SIGKILL");
    await j.shutdown().catch(() => undefined);
  }
  for (const s of stores) {
    try {
      s.close();
    } catch {}
  }
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function rig() {
  const dir = mkdtempSync(join(tmpdir(), "jobs-logs-"));
  dirs.push(dir);
  const store = Store.open(":memory:");
  stores.push(store);
  const told: string[] = [];
  const jobs = new Jobs({ store, data: dir, notify: (_s, text) => void told.push(text), link: () => null });
  all.push(jobs);
  const work = join(dir, "work");
  mkdirSync(work, { recursive: true });
  return { dir, store, jobs, work, told };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
/// What a real process does has no event here: looked at every 5 ms, no deadline.
async function until(check: () => boolean) {
  while (!check()) await sleep(5);
}

function gate(dir: string): { wait: string; open: () => Promise<void> } {
  const path = join(dir, `gate-${Math.random().toString(36).slice(2)}`);
  if (WINDOWS) return { wait: `until [ -e '${path}' ]; do sleep 0.05; done`, open: () => writeFile(path, "go") };
  execFileSync("mkfifo", [path]);
  return { wait: `cat '${path}' >/dev/null`, open: () => writeFile(path, "go") };
}

describe("jobs' files", { concurrency: true }, () => {
  test("a running job's log past its cap is cut where it is, and read on across the cut", async () => {
    const r = rig();
    const g = gate(r.dir);
    const job = await r.jobs.start("s1", "long", `echo first; ${g.wait}; echo after; tail -f /dev/null`, r.work, null, false);
    await until(() => readFileSync(job.log, "utf8").includes("first"));
    // It said a great deal (the test writes it, as its shell would: appending).
    await appendFile(job.log, "pad\n".repeat(JOB_LOG_CAP / 4 + 16));
    const inode = statSync(job.log).ino;
    const { capped } = await r.jobs.upkeep(Date.now());
    assert.equal(capped, 1);
    assert.equal(statSync(job.log).ino, inode, "the same file its shell holds");
    assert.equal(statSync(job.log).size, 0);
    assert.ok(statSync(`${job.log}.1`).size <= JOB_LOG_CAP);
    assert.equal(tail(job.log, 2), "pad\npad", "just cut: what came before is read from what it kept");
    await g.open();
    await until(() => readFileSync(job.log, "utf8") === "after\n");
    assert.equal(tail(job.log, 3), "pad\npad\nafter", "its new lines after those it kept");
    assert.equal(tail(job.log, 1), "after");
    await r.jobs.stop(job.id);
  });

  test("the files of a job long over, and of one the store no longer has, are collected; a running job's stay", async () => {
    const r = rig();
    const done = await r.jobs.start("s1", "done", "echo done", r.work, null, false);
    const g = gate(r.dir);
    const live = await r.jobs.start("s1", "live", g.wait, r.work, null, false);
    await until(() => r.store.getJob(done.id)!.state === "exited");
    const endedAt = r.store.getJob(done.id)!.endedAt!;
    const logs = join(r.dir, "jobs", "logs");
    const exits = join(r.dir, "jobs", "exit");
    const now = endedAt + JOB_LOGS_KEPT_MS + 1;
    // Of jobs the store no longer has: one unchanged long, one written just now.
    writeFileSync(join(logs, "ghost.log"), "x");
    writeFileSync(join(logs, "ghost.log.1"), "x");
    writeFileSync(join(exits, "ghost"), "0");
    for (const f of [join(logs, "ghost.log"), join(logs, "ghost.log.1"), join(exits, "ghost")]) utimesSync(f, (now - JOB_FILES_ORPHAN_MS - 1000) / 1000, (now - JOB_FILES_ORPHAN_MS - 1000) / 1000);
    writeFileSync(join(logs, "fresh.log"), "x");
    utimesSync(join(logs, "fresh.log"), (now - 1000) / 1000, (now - 1000) / 1000);
    // Within its time, an ended job's log stays.
    assert.deepEqual(await r.jobs.collect(endedAt + 1000), []);
    assert.ok(existsSync(done.log));
    const gone = await r.jobs.collect(now);
    assert.deepEqual(gone.sort(), [done.id, "ghost"].sort());
    assert.ok(!existsSync(done.log) && !existsSync(join(logs, "ghost.log")) && !existsSync(join(logs, "ghost.log.1")) && !existsSync(join(exits, "ghost")));
    assert.ok(existsSync(join(logs, "fresh.log")), "a gone job's file written just now stays a while");
    assert.ok(existsSync(live.log), "a running job's log stays");
    assert.equal(tail(done.log, 10), "", "its record stays, its log reads as empty");
    assert.equal(r.store.getJob(done.id)!.state, "exited");
    await g.open();
    await r.jobs.stop(live.id);
  });

  test("what a job left running in its group when its shell ended is made to end, a TERM ignored too", { skip: WINDOWS && "process groups as Unix has them" }, async (t) => {
    const r = rig();
    // Its shell ends at once; what it started ignores SIGTERM (its sleeps too: an ignored signal stays so across exec).
    const job = await r.jobs.start("s1", "leaves", `sh -c "trap '' TERM; echo up; while :; do sleep 1; done" & sleep 0.2; echo left`, r.work, null, false);
    const pgid = job.pgid!;
    // Whatever becomes of it, nothing of it outlives the test.
    t.after(() => signalGroup(pgid, "SIGKILL"));
    await until(() => r.store.getJob(job.id)!.state === "exited");
    // Asked to end, then killed once its stop's grace is over (5 s): given that and as long again, or the test fails.
    const by = Date.now() + 10_000;
    await until(() => !groupAlive(pgid) || Date.now() > by);
    assert.equal(groupAlive(pgid), false, "nothing of its group is left");
  });
});
