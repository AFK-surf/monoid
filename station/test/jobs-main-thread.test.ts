// What the station's main thread waits on as it reads a job's log and takes ended jobs away (src/read/jobs.ts `tail`,
// `outputAt`; src/jobs/jobs.ts `shown`, `clearEnded`): nothing of node:fs's synchronous calls (station/AGENTS.md, the main
// thread waits on nothing). Each job_log, a job's end said, a stop from the pages and 清掉已结束的 went through them.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { appendFile, open } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { Jobs, outputAt, shown, tail } from "../src/jobs/jobs.ts";
import { type JobRow, Store } from "../src/store/store.ts";
import { syncCalls } from "./main-thread-sync.ts";

const dirs: string[] = [];
const closing: (() => unknown)[] = [];
after(async () => {
  for (const close of closing) await close();
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function rig() {
  const dir = mkdtempSync(join(tmpdir(), "jobs-main-thread-"));
  dirs.push(dir);
  const store = Store.open(":memory:");
  const jobs = new Jobs({ store, data: dir, notify: () => {}, link: () => null });
  closing.push(() => jobs.shutdown().catch(() => undefined), () => store.close());
  const ended = (id: string, session: string): JobRow => {
    const job: JobRow = { id, sessionKey: session, name: id, command: "true", cwd: dir, port: null, token: id, state: "exited", pgid: null,
      exitCode: 0, startedAt: 1, endedAt: 2, restarts: 0, log: join(dir, "jobs", "logs", `${id}.log`), watch: false };
    store.insertJob(job);
    writeFileSync(job.log, "one\ntwo\nthree\n");
    writeFileSync(jobs.exitFile(id), "0\n");
    return job;
  };
  return { dir, store, jobs, ended };
}

test("a job's log read, its output's time, the job as the pages show it and ended jobs taken away wait on no file", async () => {
  const r = rig();
  const job = r.ended("j1", "s1");
  r.ended("j2", "s1");
  writeFileSync(`${job.log}.1`, "zero\n");
  const calls = await syncCalls(async () => {
    assert.equal(await tail(job.log, 2), "two\nthree");
    assert.equal(await tail(job.log, 4), "zero\none\ntwo\nthree", "read on into what a cut kept");
    assert.equal(await tail(join(r.dir, "none.log"), 4), "");
    assert.equal(typeof (await outputAt(job.log)), "number");
    assert.equal(await outputAt(join(r.dir, "none.log")), null);
    const v = await shown(r.store, r.store.getJob("j1")!);
    assert.equal(v.id, "j1");
    assert.equal(typeof v.outputAt, "number");
    assert.deepEqual((await r.jobs.clearEnded("s1")).sort(), ["j1", "j2"]);
  });
  assert.deepEqual(calls, []);
  assert.equal(await outputAt(job.log), null, "its log taken away with it");
  assert.equal(await tail(job.log, 2), "zero", "what a cut kept stays, as before");
});

test("a log's tail stops at the end it saw first, as the job writes on", async () => {
  const r = rig();
  const job = r.ended("j1", "s1");
  writeFileSync(job.log, "old\n".repeat(16_384));
  const handle = await open(job.log, "r");
  const proto = Object.getPrototypeOf(handle) as { read: (...args: unknown[]) => Promise<{ bytesRead: number }> };
  await handle.close();
  const read = proto.read;
  let appended = false;
  proto.read = async function (this: unknown, ...args: unknown[]) {
    const got = await read.apply(this, args);
    if (got.bytesRead > 0 && !appended) {
      appended = true;
      await appendFile(job.log, "new\n");
    }
    return got;
  };
  try {
    assert.equal(await tail(job.log, 1), "old");
    assert.ok(appended);
  } finally {
    proto.read = read;
  }
  assert.equal(await tail(job.log, 1), "new", "the later line is read the next time");
});
