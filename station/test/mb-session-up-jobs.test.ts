// The MoonBit builder of the sessions' up jobs (station/mb, src/upjobs) prepares a session's old jobs as
// `sessionUpJobsStep` does, the station-wide lookup's as `workspaceUpJobsStep` and an own chat's first member as
// `jobNameFirstStep`: the same data, batch by batch, give the same answers and the same tables.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { MbProcess, mbReaderBinary } from "../src/read/mb-reader.ts";
import { SessionUpJobsBuilder } from "../src/read/session-up-jobs-builder.ts";
import { WorkspaceUpJobsBuilder } from "../src/read/workspace-up-jobs-builder.ts";
import { jobNameFirstStep } from "../src/store/job-name-first.ts";
import { installSessionUpJobs, sessionUpJobsReady, sessionUpJobsStep } from "../src/store/session-up-jobs.ts";
import { installWorkspaceUpJobs, workspaceUpJobsReady, workspaceUpJobsStep } from "../src/store/workspace-up-jobs.ts";
import { Store } from "../src/store/store.ts";

const binary = mbReaderBinary();

/// A station's database whose jobs are from before their index: 900 of one session's, running, exited with a port
/// (a service) or exited, some gone again; a few of another's; the index installed over them, nothing prepared.
function old() {
  const dir = mkdtempSync(join(tmpdir(), "mb-session-up-jobs-"));
  const path = join(dir, "stillfail.db");
  const store = Store.open(path, join(dir, "archive")), db = store.db;
  for (const row of db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'session_up_job_%'").all() as { name: string }[])
    db.exec(`DROP TRIGGER ${row.name}`);
  db.exec("DROP TABLE session_up_job_rows; DROP TABLE session_up_job_replaced; DROP TABLE session_up_job_scopes; DROP TABLE session_up_job_meta");
  const put = db.prepare(`INSERT INTO jobs(id, token, session_key, state, port, name, command, cwd, started_at, log)
    VALUES (?, ?, ?, ?, ?, '', '', '', ?, '')`);
  for (let i = 0; i < 900; i++) put.run(`long-${i}`, `long-${i}`, "long", i % 3 === 0 ? "exited" : "running", i % 6 === 0 ? 8000 + i : null, i);
  for (let i = 0; i < 5; i++) put.run(`short-${i}`, `short-${i}`, "short", "running", null, i);
  db.exec("DELETE FROM jobs WHERE rowid % 17 = 0");
  installSessionUpJobs(db);
  return { dir, path, store, close: () => { store.close(); rmSync(dir, { recursive: true, force: true }); } };
}

function tables(store: Store): string {
  const all = (sql: string) => JSON.stringify(store.db.prepare(sql).all());
  return [
    all("SELECT session, job_rowid FROM session_up_job_rows ORDER BY session, job_rowid"),
    all("SELECT session, last_rowid, end_rowid, complete FROM session_up_job_scopes ORDER BY session"),
  ].join("\n");
}

test("the MoonBit builder prepares a session's old jobs batch by batch as sessionUpJobsStep does", async () => {
  assert.notEqual(binary, null, "the MoonBit reader is built (station/mb/build.sh, or STILLFAIL_MB_READER)");
  const ts = old(), mb = old();
  const builder = new MbProcess(binary!, ["--builder", "session-up-jobs", "--db", mb.path]);
  try {
    const steps: { session: string; ts: boolean; mb: boolean }[] = [];
    for (const session of ["short", "long", "none"]) {
      for (let i = 0; i < 10; i++) {
        const answered = new Promise<{ done: boolean; error?: string }>((resolve) => builder.once("message", resolve));
        builder.postMessage({ session });
        const ours = await answered;
        assert.equal(ours.error, undefined);
        steps.push({ session, ts: sessionUpJobsStep(ts.store.db, session).done, mb: ours.done });
        if (ours.done) break;
      }
    }
    assert.ok(steps.filter((s) => s.session === "long").length >= 4, JSON.stringify(steps));
    assert.deepEqual(steps.map((s) => s.mb), steps.map((s) => s.ts));
    assert.equal(tables(mb.store), tables(ts.store));
    for (const session of ["short", "long", "none"]) assert.equal(sessionUpJobsReady(mb.store.db, session), true);
    const invalid = new Promise((resolve) => builder.once("message", resolve));
    builder.postMessage({ scope: "all" });
    assert.deepEqual(await invalid, { done: false, error: "invalid session up jobs preparation request" });
  } finally {
    await builder.terminate();
    ts.close(); mb.close();
  }
});

test("the station's session up jobs builder finishes what it is asked", async () => {
  assert.notEqual(binary, null);
  const f = old();
  const builder = new SessionUpJobsBuilder(f.path, {});
  try {
    await builder.ready(["long", "short"]);
    assert.equal(sessionUpJobsReady(f.store.db, "long"), true);
    assert.equal(sessionUpJobsReady(f.store.db, "short"), true);
  } finally {
    await builder.close();
    f.close();
  }
});

/// A station's database whose up jobs are from before the station-wide lookup: running jobs, and more exited services
/// than eight batches (so that a scan by rowid takes every ninth), of sessions in workspaces, at home and of odd keys;
/// the lookup installed over them, nothing copied.
function oldWorkspace() {
  const dir = mkdtempSync(join(tmpdir(), "mb-workspace-up-jobs-"));
  const path = join(dir, "stillfail.db");
  const store = Store.open(path, join(dir, "archive")), db = store.db;
  for (const row of db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'workspace_up_%'").all() as { name: string }[])
    db.exec(`DROP TRIGGER ${row.name}`);
  db.exec("DROP TABLE workspace_up_session_replaced; DROP TABLE workspace_up_sessions; DROP TABLE workspace_up_meta");
  db.exec("DELETE FROM session_up_job_rows; UPDATE session_up_job_meta SET fresh = 0");
  for (const [key, ws] of [["a", "WA"], ["b", "WB"], ["home", null], ["oddé", "WA"]] as const)
    store.insertSession({ key, connect: "ember", runtime: "claude", profile: "cc", workspace: "/w", token: key, createdAt: 1, lastActiveAt: 1, ws });
  const put = db.prepare(`INSERT INTO jobs(id, token, session_key, state, port, name, command, cwd, started_at, log)
    VALUES (?, ?, ?, ?, ?, '', '', '', ?, '')`);
  const sessions = ["a", "b", "home", "oddé", "gone"];
  db.exec("BEGIN");
  for (let i = 0; i < 600; i++) put.run(`run-${i}`, `run-${i}`, sessions[i % 5], "running", null, i);
  for (let i = 0; i < 2500; i++) put.run(`svc-${i}`, `svc-${i}`, sessions[i % 5], "exited", 9000 + (i % 700), i);
  for (let i = 0; i < 300; i++) put.run(`done-${i}`, `done-${i}`, sessions[i % 5], "exited", null, i);
  db.exec("COMMIT");
  installWorkspaceUpJobs(db);
  return { dir, path, store, close: () => { store.close(); rmSync(dir, { recursive: true, force: true }); } };
}

function workspaceTables(store: Store): string {
  const all = (sql: string) => JSON.stringify(store.db.prepare(sql).all());
  return [
    all("SELECT session, job_rowid FROM session_up_job_rows ORDER BY session, job_rowid"),
    all("SELECT session, scope, ws FROM workspace_up_sessions ORDER BY session"),
    all("SELECT version, phase, last_port, last_rowid, running_end, guard_end, guard_last, port_batches, ready FROM workspace_up_meta"),
    all("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'workspace_up_%' ORDER BY name"),
  ].join("\n");
}

test("the MoonBit builder copies the old up jobs into the station-wide lookup batch by batch as workspaceUpJobsStep does", async () => {
  assert.notEqual(binary, null);
  const ts = oldWorkspace(), mb = oldWorkspace();
  const builder = new MbProcess(binary!, ["--builder", "workspace-up-jobs", "--db", mb.path]);
  try {
    const steps: { ts: boolean; mb: boolean }[] = [];
    for (let i = 0; i < 40; i++) {
      // (a job of before goes on meanwhile: one stops, a service comes up behind the cursor)
      if (i === 3) for (const f of [ts, mb]) f.store.db.exec("UPDATE jobs SET state = 'exited', port = 9999 WHERE id = 'done-7'");
      const answered = new Promise<{ done: boolean; error?: string }>((resolve) => builder.once("message", resolve));
      builder.postMessage({ scope: "all" });
      const ours = await answered;
      assert.equal(ours.error, undefined);
      steps.push({ ts: workspaceUpJobsStep(ts.store.db).done, mb: ours.done });
      assert.equal(workspaceTables(mb.store), workspaceTables(ts.store), `batch ${i}`);
      if (ours.done) break;
    }
    assert.ok(steps.length >= 12, JSON.stringify(steps));
    assert.deepEqual(steps.map((s) => s.mb), steps.map((s) => s.ts));
    assert.equal(workspaceUpJobsReady(mb.store.db), true);
  } finally {
    await builder.terminate();
    ts.close(); mb.close();
  }
});

test("the station's workspace up jobs builder finishes what it is asked", async () => {
  assert.notEqual(binary, null);
  const f = oldWorkspace();
  const builder = new WorkspaceUpJobsBuilder(f.path, {});
  try {
    await builder.ready(["all"]);
    assert.equal(workspaceUpJobsReady(f.store.db), true);
  } finally {
    await builder.close();
    f.close();
  }
});

/// A station whose own chats' first members are from before their lookup: a session with jobs up, owning a chat of
/// many members (more than two batches) joined in no order of their keys, one owning none, and the lookup emptied.
function oldMembers() {
  const f = old();
  for (const session of ["long", "short"]) while (!sessionUpJobsStep(f.store.db, session).done);
  const db = f.store.db;
  const thread = f.store.openThread("ember", "CHAT", "many", null, null).id;
  const join_ = db.prepare("INSERT INTO thread_sessions(thread, session, connect, joined_at) VALUES (?, ?, 'ember', ?)");
  db.exec("BEGIN");
  for (let i = 0; i < 150; i++) join_.run(thread, `member-${String(i).padStart(3, "0")}`, (i * 37) % 151 + 10);
  join_.run(thread, "long", 50);
  db.exec("COMMIT");
  db.exec("DELETE FROM job_name_first");
  return { ...f, thread };
}

const membersTable = (store: Store) =>
  JSON.stringify(store.db.prepare("SELECT owner, thread, best, after_session, through_session, restart, ready FROM job_name_first ORDER BY owner").all());

test("the MoonBit builder prepares an own chat's first member batch by batch as jobNameFirstStep does", async () => {
  assert.notEqual(binary, null);
  const ts = oldMembers(), mb = oldMembers();
  const builder = new MbProcess(binary!, ["--builder", "session-up-jobs", "--db", mb.path]);
  try {
    const steps: { owner: string; ts: boolean; mb: boolean }[] = [];
    for (const owner of ["long", "nobody"]) {
      for (let i = 0; i < 10; i++) {
        // (a member who joined first comes in behind the cursor: the scan goes on, its best taken)
        if (owner === "long" && i === 1) for (const f of [ts, mb])
          f.store.db.prepare("INSERT INTO thread_sessions(thread, session, connect, joined_at) VALUES (?, 'aaa-early', 'ember', 1)").run(f.thread);
        const answered = new Promise<{ done: boolean; error?: string }>((resolve) => builder.once("message", resolve));
        builder.postMessage({ session: owner, first: mb.thread });
        const ours = await answered;
        assert.equal(ours.error, undefined);
        steps.push({ owner, ts: jobNameFirstStep(ts.store.db, owner, ts.thread).done, mb: ours.done });
        assert.equal(membersTable(mb.store), membersTable(ts.store), `${owner} batch ${i}`);
        if (ours.done) break;
      }
    }
    assert.ok(steps.filter((s) => s.owner === "long").length >= 3, JSON.stringify(steps));
    assert.deepEqual(steps.map((s) => s.mb), steps.map((s) => s.ts));
    assert.equal((mb.store.db.prepare("SELECT ready FROM job_name_first WHERE owner = 'long'").get() as { ready: number }).ready, 1);
  } finally {
    await builder.terminate();
    ts.close(); mb.close();
  }
});
