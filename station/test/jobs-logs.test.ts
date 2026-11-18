// Jobs' files held to their bounds (src/jobs/jobs.ts `upkeep`, `collect`): a log cut where it is while its job appends
// to it, and read on across the cut; the files of jobs long over or gone collected; and what a job left running in its
// group when its shell ended made to end (a VM's jobs left orphans of ppid 1, 2026-11-15). Real jobs, as jobs.test.ts.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { appendFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, test } from "node:test";
import { groupAlive, signalGroup } from "../src/ops/group.ts";
import { COLLECT_YIELD_EVERY, JOB_FILES_ORPHAN_MS, JOB_LOGS_KEPT_MS, Jobs, WRAPPER, tail } from "../src/jobs/jobs.ts";
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
async function until(check: () => boolean | Promise<boolean>) {
  while (!(await check())) await sleep(5);
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
    assert.equal(await tail(job.log, 2), "pad\npad", "just cut: what came before is read from what it kept");
    await g.open();
    await until(() => readFileSync(job.log, "utf8") === "after\n");
    assert.equal(await tail(job.log, 3), "pad\npad\nafter", "its new lines after those it kept");
    assert.equal(await tail(job.log, 1), "after");
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
    // (and what its shell was writing aside when it was killed)
    writeFileSync(join(exits, "ghost.tmp"), "");
    for (const f of [join(logs, "ghost.log"), join(logs, "ghost.log.1"), join(exits, "ghost"), join(exits, "ghost.tmp")]) utimesSync(f, (now - JOB_FILES_ORPHAN_MS - 1000) / 1000, (now - JOB_FILES_ORPHAN_MS - 1000) / 1000);
    writeFileSync(join(logs, "fresh.log"), "x");
    utimesSync(join(logs, "fresh.log"), (now - 1000) / 1000, (now - 1000) / 1000);
    // Within its time, an ended job's log stays.
    assert.deepEqual(await r.jobs.collect(endedAt + 1000), []);
    assert.ok(existsSync(done.log));
    const gone = await r.jobs.collect(now);
    assert.deepEqual(gone.sort(), [done.id, "ghost"].sort());
    assert.ok(!existsSync(done.log) && !existsSync(join(logs, "ghost.log")) && !existsSync(join(logs, "ghost.log.1")) && !existsSync(join(exits, "ghost")));
    assert.ok(!existsSync(join(exits, "ghost.tmp")));
    assert.ok(existsSync(join(logs, "fresh.log")), "a gone job's file written just now stays a while");
    assert.ok(existsSync(live.log), "a running job's log stays");
    assert.equal(await tail(done.log, 10), "", "its record stays, its log reads as empty");
    assert.equal(r.store.getJob(done.id)!.state, "exited");
    await g.open();
    await r.jobs.stop(live.id);
  });

  test("collecting goes through many kept jobs' files giving the loop back as it goes, and reads no job up", async () => {
    // (1,043 reads of the store in one turn of the loop held a station's main thread 4.5 s, 2026-11-18)
    const r = rig();
    const logs = join(r.dir, "jobs", "logs");
    const exits = join(r.dir, "jobs", "exit");
    mkdirSync(logs, { recursive: true });
    mkdirSync(exits, { recursive: true });
    const T = 1_000_000_000_000;
    const row = (id: string, state: string, endedAt: number | null) => ({
      id, sessionKey: "s1", name: id, command: "true", cwd: r.work, port: null, token: `t-${id}`, state, pgid: null, exitCode: state === "running" ? null : 0,
      startedAt: T - 1000, endedAt, restarts: 0, log: join(logs, `${id}.log`), watch: false,
    });
    const N = 1000;
    for (let i = 0; i < N; i++) {
      r.store.insertJob(row(`kept${i}`, "exited", T));
      writeFileSync(join(logs, `kept${i}.log`), "x");
      writeFileSync(join(exits, `kept${i}`), "0");
    }
    r.store.insertJob(row("up", "running", null));
    writeFileSync(join(logs, "up.log"), "x");
    writeFileSync(join(logs, "up.log.1"), "x");
    const read: string[] = [];
    const getJob = r.store.getJob.bind(r.store);
    r.store.getJob = (id: string) => (read.push(id), getJob(id));
    // what else the loop has to do while it collects: each turn it is given back, the reads since the last counted
    let last = 0;
    let most = 0;
    let turns = 0;
    let collecting = true;
    const other = () => {
      most = Math.max(most, read.length - last);
      last = read.length;
      turns++;
      if (collecting) setImmediate(other);
    };
    setImmediate(other);
    const gone = await r.jobs.collect(T + 1000);
    collecting = false;
    most = Math.max(most, read.length - last);
    assert.deepEqual(gone, [], "all within their time");
    assert.ok(!read.includes("up"), "a job up is not read");
    assert.equal(read.length, N, "each kept job read once, for its log and its exit file both");
    assert.ok(most <= COLLECT_YIELD_EVERY, `${most} reads in one turn of the loop`);
    assert.ok(turns >= N / COLLECT_YIELD_EVERY, `the loop given back ${turns} times`);
  });

  test("a job's exit code is there whole or not at all: written aside, then moved into place", { skip: WINDOWS && "the wrapper's sh and mv" }, () => {
    // A watch on jobs/exit hears the file as it is made: on Linux one made empty by `>` and written after was read as
    // no code (a job an earlier station started, CI 2026-11-17). Here mv says what it found as it moved it.
    const dir = mkdtempSync(join(tmpdir(), "jobs-exit-"));
    dirs.push(dir);
    const bin = join(dir, "bin"), exit = join(dir, "exit"), seen = join(dir, "seen");
    mkdirSync(bin);
    writeFileSync(join(bin, "mv"), `#!/bin/sh
[ -e "$3" ] && echo "there before" >> '${seen}'
echo "aside: $(cat "$2")" >> '${seen}'
exec /bin/mv "$@"
`, { mode: 0o755 });
    const run = spawnSync("/bin/sh", ["-c", WRAPPER, "job", "exit 7", exit], { env: { ...process.env, PATH: `${bin}:${process.env.PATH}` } });
    assert.equal(run.status, 7);
    assert.equal(readFileSync(seen, "utf8"), "aside: 7\n", "not there until moved, and whole as it was");
    assert.equal(readFileSync(exit, "utf8"), "7");
    assert.ok(!existsSync(`${exit}.tmp`));
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
