// job_ends (station/src/store/job-ends.ts): what opening an old store copies, the bounded copy after it (the session
// backfill's `job-ends`, its batches those of test/reference/backfill/job-ends.ts: mb-legacy-ids.test.ts), and that
// every way a job is written keeps the lookup what the jobs table says.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { buildJobEnds } from "../src/store/legacy-said-builder.ts";
import { Store } from "../src/store/store.ts";
import { BATCH, jobEndsReady, jobEndsStep } from "./reference/backfill/job-ends.ts";

const put = (db: DatabaseSync, id: string | null, over: { state?: string; ended?: number | null; token?: string; session?: string; verb?: string } = {}) =>
  db.prepare(`${over.verb ?? "INSERT"} INTO jobs (id, session_key, name, command, cwd, token, state, started_at, ended_at, log)
    VALUES (?, ?, 'n', 'a long command', '/tmp', ?, ?, 1000, ?, '/tmp/l')`)
    .run(id, over.session ?? "s1", over.token ?? `t-${id}`, over.state ?? "running", over.ended ?? null);

const fill = (db: DatabaseSync, n: number) => {
  db.exec("BEGIN IMMEDIATE");
  for (let i = 0; i < n; i++) put(db, `j${String(i).padStart(4, "0")}`, i % 3 === 0 ? { state: "exited", ended: 2000 + i } : {});
  db.exec("COMMIT");
};

/// A store from before job_ends: its jobs, and none of the lookup.
const dropLookup = (db: DatabaseSync) => db.exec(`DROP TRIGGER job_ends_before_add; DROP TRIGGER job_ends_add;
  DROP TRIGGER job_ends_before_change; DROP TRIGGER job_ends_change; DROP TRIGGER job_ends_drop;
  DROP TABLE job_ends; DROP TABLE job_ends_replaced; DROP TABLE job_ends_meta;`);

function oldStore(path: string, n: number) {
  const store = Store.open(path);
  try { fill(store.db, n); dropLookup(store.db); } finally { store.close(); }
}

const meta = (db: DatabaseSync): Record<string, unknown> =>
  ({ ...db.prepare("SELECT complete, cursor, end_id FROM job_ends_meta WHERE id = 1").get() });
const lookup = (db: DatabaseSync) =>
  db.prepare("SELECT id, state, ended_at FROM job_ends ORDER BY id").all().map((r) => ({ ...r }));
const jobs = (db: DatabaseSync) =>
  db.prepare("SELECT id, state, ended_at FROM jobs WHERE id IS NOT NULL ORDER BY id").all().map((r) => ({ ...r }));
const ends = (db: DatabaseSync) => Object.fromEntries(jobs(db).map((r) => [r.id, { state: r.state, endedAt: r.ended_at }]));
const ids = (db: DatabaseSync) => jobs(db).map((r) => r.id as string).concat("missing");

function withDir(f: (dir: string) => Promise<void> | void) {
  return async () => {
    const dir = mkdtempSync(join(tmpdir(), "job-ends-"));
    try { await f(dir); } finally { rmSync(dir, { recursive: true, force: true }); }
  };
}

test("a store of at most BATCH jobs copies them into job_ends as it opens", withDir((dir) => {
  const path = join(dir, "stillfail.db");
  oldStore(path, BATCH);
  const store = Store.open(path);
  try {
    assert.deepEqual(meta(store.db), { complete: 1, cursor: null, end_id: null });
    assert.equal(lookup(store.db).length, BATCH);
    assert.deepEqual(lookup(store.db), jobs(store.db));
    assert.deepEqual(store.jobsEnds(ids(store.db)), ends(store.db));
  } finally { store.close(); }
}));

test("a larger old store opens with job_ends empty, answered by jobs until the session backfill has copied it", withDir(async (dir) => {
  const path = join(dir, "stillfail.db");
  oldStore(path, 200);
  const store = Store.open(path);
  let builder: ReturnType<typeof buildJobEnds> | null = null;
  try {
    const end = (store.db.prepare("SELECT MAX(rowid) AS m FROM jobs").get() as { m: number }).m;
    assert.deepEqual(meta(store.db), { complete: 0, cursor: null, end_id: end });
    assert.deepEqual(lookup(store.db), [], "opening copies none of the jobs");
    assert.equal(jobEndsReady(store.db), false);
    assert.deepEqual(store.jobsEnds(ids(store.db)), ends(store.db));

    assert.deepEqual(jobEndsStep(store.db), { done: false, visited: BATCH }, "one batch at a time");
    assert.equal(lookup(store.db).length, BATCH);
    // Writes meanwhile, to jobs copied and not yet copied, and new ones: the triggers keep them.
    put(store.db, "new1", { state: "exited", ended: 9000 });
    store.db.prepare("UPDATE jobs SET state = 'exited', ended_at = 7000 WHERE id = 'j0001'").run();
    store.db.prepare("UPDATE jobs SET state = 'failed', ended_at = 7100 WHERE id = 'j0150'").run();
    store.db.prepare("DELETE FROM jobs WHERE id = 'j0002' OR id = 'j0160'").run();
    assert.deepEqual(store.jobsEnds(ids(store.db)), ends(store.db));

    const before = meta(store.db);
    const previous = Promise.withResolvers<void>();
    builder = buildJobEnds(store, previous.promise);
    let settled = false;
    void builder.ready.then(() => { settled = true; });
    await Promise.resolve();
    assert.equal(settled, false);
    assert.deepEqual(meta(store.db), before, "nothing is copied while the station before holds the database");
    previous.resolve();
    assert.equal(await builder.ready, true);
    assert.equal(meta(store.db).complete, 1);
    assert.equal(jobEndsReady(store.db), true);
    assert.deepEqual(lookup(store.db), jobs(store.db));
    assert.deepEqual(store.jobsEnds(ids(store.db)), ends(store.db));
    put(store.db, "new2", { state: "failed", ended: 9100 });
    assert.deepEqual(store.jobsEnds(ids(store.db)), ends(store.db));
  } finally {
    await builder?.close();
    store.close();
  }
}));

test("every way a job is written keeps job_ends what jobs says", () => {
  const store = Store.open(":memory:");
  const db = store.db;
  const same = (what: string) => assert.deepEqual(lookup(db), jobs(db), what);
  try {
    put(db, "a"); put(db, "b"); put(db, "c", { session: "s2" }); same("inserted");
    db.prepare("UPDATE jobs SET state = 'exited', ended_at = 5 WHERE id = 'a'").run(); same("state and end changed");
    db.prepare("UPDATE jobs SET ended_at = 6 WHERE id = 'a'").run(); same("end changed");
    db.prepare("UPDATE jobs SET id = 'a2' WHERE id = 'a'").run(); same("id changed");
    db.prepare("UPDATE jobs SET name = 'other', command = 'x' WHERE id = 'b'").run(); same("other columns changed");
    db.prepare("DELETE FROM jobs WHERE id = 'b'").run(); same("deleted");
    put(db, "d", { session: "s2" });
    db.prepare("DELETE FROM jobs WHERE session_key = ?").run("s2"); same("a session's jobs deleted");

    put(db, "e"); put(db, "f", { state: "exited", ended: 1 });
    put(db, "g", { token: "t-e", verb: "INSERT OR REPLACE" }); same("REPLACE by another's token removes it");
    assert.equal(lookup(db).some((r) => r.id === "e"), false);
    put(db, "f", { state: "failed", ended: 2, token: "t-f2", verb: "INSERT OR REPLACE" }); same("REPLACE by id");

    put(db, "f", { token: "t-other", verb: "INSERT OR IGNORE" });
    put(db, "h", { token: "t-g", verb: "INSERT OR IGNORE" }); same("ignored inserts");
    db.prepare("UPDATE jobs SET state = 'exited', ended_at = 3 WHERE id = 'g'").run(); same("a write after ignored ones");
    put(db, "i"); same("an insert after ignored ones");

    put(db, "j");
    db.prepare("UPDATE OR REPLACE jobs SET token = 't-i' WHERE id = 'j'").run(); same("UPDATE OR REPLACE by another's token");
    assert.equal(lookup(db).some((r) => r.id === "i"), false);
    db.prepare("UPDATE OR REPLACE jobs SET id = 'g' WHERE id = 'j'").run(); same("UPDATE OR REPLACE by another's id");

    // (only one that is not running: active_other_jobs keeps a running job by its id)
    put(db, null, { token: "t-null", state: "exited", ended: 1 }); same("a job without an id");
    db.prepare("UPDATE jobs SET state = 'failed', ended_at = 4 WHERE id IS NULL").run(); same("a job without an id changed");
    db.prepare("UPDATE jobs SET id = 'k' WHERE id IS NULL").run(); same("a job given an id");
    db.prepare("UPDATE jobs SET id = NULL WHERE id = 'k'").run(); same("a job's id taken away");
    db.prepare("DELETE FROM jobs WHERE id IS NULL").run(); same("a job without an id deleted");
    assert.equal((db.prepare("SELECT COUNT(*) AS n FROM job_ends_replaced").get() as { n: number }).n, 0);
  } finally { store.close(); }
});
