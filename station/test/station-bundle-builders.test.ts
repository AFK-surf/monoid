import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";
import { test } from "node:test";
import { platform } from "../src/platform/index.ts";
import { MbProcess } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";
import { LiveLocator } from "../src/sessions/live-locator.ts";
import { installSigninSaveIndex } from "../src/vault/signin-save-index.ts";
import { keyPart, sandboxName } from "../src/agents/sandbox-name.ts";
import { installLegacySaid } from "../src/store/legacy-said-build.ts";
import { installLegacyAgent } from "../src/store/legacy-agent-build.ts";
import { installPeopleSinceIndex } from "../src/store/legacy-people-since.ts";
import { installWorkspaceUpJobs } from "../src/store/workspace-up-jobs.ts";

// The release's main.js loads and answers: a module importing createRequire as the bundle's banner did declared it
// twice, and every station updated to 0.1.7119 kept its old one (the new one exited with 1 before it was ready).
test("the station in a release starts", { skip: !process.env.STATION_BUNDLE }, () => {
  const data = mkdtempSync(join(tmpdir(), "station-bundle-main-"));
  try {
    const run = spawnSync(process.execPath, [join(process.env.STATION_BUNDLE!, "main.js"), "status", "--data", data], { encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
  } finally { rmSync(data, { recursive: true, force: true }); }
});

/// The release's MoonBit program, beside its main.js.
const program = () => join(process.env.STATION_BUNDLE!, platform.exe("stillfail-reader"));

test("a release's live locator finds a transcript", { skip: !process.env.STATION_BUNDLE }, async () => {
  const data = mkdtempSync(join(tmpdir(), "station-bundle-live-"));
  const store = Store.open(join(data, "stillfail.db"));
  const locator = new LiveLocator(data, (key) => store.getSession(key), () => [],
    (at) => new MbProcess(program(), ["--builder", "live-locator", "--db", join(at, "stillfail.db"), "--data", at, "--sep", sep]));
  try {
    store.insertSession({ key: "one", connect: "ember", runtime: "claude", profile: "cc", workspace: "/w",
      token: "one", createdAt: 1, lastActiveAt: 1, ws: "mine" });
    store.setRuntimeSessionId("one", "current");
    const directory = join(data, "transcripts", "claude", "-w");
    const path = join(directory, "current.jsonl");
    mkdirSync(directory, { recursive: true });
    writeFileSync(path, "");
    assert.deepEqual(await locator.locate("one"), { runtime: "claude", paths: [{ path, runtime: "claude" }], current: true });
  } finally {
    await locator.close();
    store.close();
    rmSync(data, { recursive: true, force: true });
  }
});

// The mac-build job calls this on the release it just laid out; the regular test suite has no release directory.
test("the builders of a station release's program start and process a batch", { skip: !process.env.STATION_BUNDLE }, async () => {
  const directory = mkdtempSync(join(tmpdir(), "station-bundle-builders-"));
  const path = join(directory, "station.db");
  const store = Store.open(path);
  try {
    store.db.exec(`CREATE TABLE signin_asks (id TEXT PRIMARY KEY, session TEXT NOT NULL, owner TEXT NOT NULL, status TEXT NOT NULL, body TEXT NOT NULL);
      CREATE INDEX signin_asks_by_session ON signin_asks (session, status);`);
    installSigninSaveIndex(store.db);
    const thread = store.openThread("ember", "CHAT", "old", null, null).id;
    store.joinThread(thread, "old-cc", "ember");
    store.db.prepare("INSERT INTO entries(thread,n,kind,author_kind,author,ts,at) VALUES (?,1,'message','agent','s','post',1)").run(thread);
    const saidThread = store.openThread("ember", "CHAT", "old-said", null, null).id;
    const put = store.db.prepare("INSERT INTO entries(thread,n,kind,author_kind,author,ts,at) VALUES (?,?,'message',?,?,?,?)");
    put.run(saidThread, 1, "agent", "s", "first", 1);
    for (let n = 2; n <= 70; n++) put.run(saidThread, n, "person", "p", `m${n}`, n);
    store.db.exec("DROP INDEX entries_people_since");
    installPeopleSinceIndex(store.db);
    store.db.prepare("UPDATE thread_state SET said_other_known=0 WHERE thread=?").run(saidThread);
    const turn = store.db.prepare("INSERT INTO turns(id,session_key,kind,started_at) VALUES (?,'old-turn','input',?)");
    for (let n = 0; n < 70; n++) turn.run(`old-${n}`, n);
    store.db.prepare("DELETE FROM session_turns WHERE session='old-turn'").run();
    store.db.exec("UPDATE post_blocks_meta SET fresh = 0; DELETE FROM post_blocks");
    store.insertSession({ key: "old-count", connect: "ember", runtime: "claude", profile: "cc", workspace: "/w",
      token: "old-count", createdAt: 1, lastActiveAt: 1, ws: "mine" });
    store.db.prepare("INSERT INTO turns(id,session_key,kind,started_at,ended_at,outcome,declared) VALUES ('old-wait','old-count','user',0,1,'completed','waiting')").run();
    store.db.exec("DELETE FROM session_recover_waits; UPDATE session_recover_wait_meta SET cursor=NULL,complete=0 WHERE id=1");
    store.db.exec("DELETE FROM session_count_seen; UPDATE session_count_meta SET last_rowid=NULL, end_rowid=(SELECT max(rowid) FROM sessions), complete=0");
    store.db.exec("DELETE FROM session_list_rows; UPDATE session_list_meta SET last_rowid=NULL, end_rowid=(SELECT max(rowid) FROM sessions), complete=0");
    store.db.exec("INSERT INTO bindings(connect,session_key) VALUES('old-binding','old-count'); DELETE FROM session_binding_rows; UPDATE session_binding_meta SET last_rowid=NULL, end_rowid=(SELECT max(rowid) FROM bindings), complete=0");
    store.db.exec("INSERT INTO pins(viewer,session,at) VALUES('old-viewer','old-count',1); DELETE FROM archive_pin_rows; UPDATE archive_mark_meta SET last_rowid=NULL, end_rowid=(SELECT max(rowid) FROM pins), complete=0 WHERE kind='pins'");
    store.insertJob({ id: "old-job", sessionKey: "old-count", name: "old-job", command: "true", cwd: "/", port: null,
      token: "old-job", state: "running", pgid: 12345, exitCode: null, startedAt: 1, endedAt: null, restarts: 0, log: "/dev/null", watch: false });
    store.db.exec("DELETE FROM session_up_job_rows; UPDATE session_up_job_meta SET fresh=0");
    for (const row of store.db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'workspace_up_%'").all() as { name: string }[])
      store.db.exec(`DROP TRIGGER ${row.name}`);
    store.db.exec("DROP TABLE workspace_up_session_replaced; DROP TABLE workspace_up_sessions; DROP TABLE workspace_up_meta");
    installWorkspaceUpJobs(store.db);
    store.db.prepare("INSERT INTO chat_shares(session,shared,write,by,at) VALUES (?,?,0,'a',1)")
      .run("old-share", JSON.stringify([{ workspace: "other", name: "Other", used: 1 }]));
    store.db.prepare("UPDATE entries SET attachments=? WHERE thread=? AND n=1")
      .run(JSON.stringify([{ path: "/w/bundle.html", name: "bundle.html" }]), thread);
    store.db.prepare("UPDATE entries SET card=? WHERE thread=? AND n=1").run('{"type":"text"}', thread);
    store.db.prepare("DELETE FROM widget_source_rows WHERE thread=?").run(thread);
    store.db.prepare("DELETE FROM widget_source_scopes WHERE thread=?").run(thread);
    store.db.prepare("DELETE FROM card_posts WHERE thread=?").run(thread);
    store.db.prepare("DELETE FROM card_post_scopes WHERE thread=?").run(thread);
    installLegacySaid(store.db);
    installLegacyAgent(store.db);
    for (const [builder, message] of [
      ["session-backfill", {}],
      ["session-backfill", { kind: "recovery" }],
      ["session-backfill", { kind: "sandbox" }],
      ["session-backfill", { kind: "directory" }],
      ["session-backfill", { kind: "chat-share" }],
      ["session-backfill", { kind: "process-jobs" }],
      ["session-backfill", { kind: "legacy-said" }],
      ["session-backfill", { kind: "legacy-agent" }],
      ["session-counts", {}],
      ["post-blocks", { thread, after: 0 }],
      ["said", { thread: saidThread }],
      ["turn-counts", { session: "old-turn" }],
      ["recent-chat", { scope: JSON.stringify([null, null]) }],
      ["search-scope", { scope: "all" }],
      ["session-list", { scope: "all" }],
      ["session-bindings", { scope: "all" }],
      ["session-up-jobs", { session: "old-count" }],
      ["session-up-jobs", { session: "old-count", first: thread }],
      ["workspace-up-jobs", { scope: "all" }],
      ["widget-sources", { thread }],
      ["cc-index", { session: "old-cc" }],
      ["card-posts", { thread }],
      ["people-since", { thread: saidThread, people: true }],
      ["archive-marks", { scope: "all" }],
      ["outflow-chats", { scope: "H" }],
      ["signin-save", "s"],
    ] as const) {
      const builderProcess = new MbProcess(program(), ["--builder", builder, "--db", path]);
      try {
        let done = false;
        for (let batch = 0; batch < 10 && !done; batch++) {
          const result = new Promise<{ done: boolean; error?: string }>((resolve, reject) => {
            const heard = (answer: { done: boolean; error?: string; take?: boolean; give?: boolean }) => {
              // (a builder that takes the backfill permit itself, as it is about to write: given it)
              if (answer.take === true) return void builderProcess.postMessage({ permit: true });
              if (answer.give === true) return;
              builderProcess.off("message", heard);
              resolve(answer);
            };
            builderProcess.on("message", heard);
            builderProcess.once("exit", (code) => reject(new Error(`${builder} ended (${code})`)));
          });
          builderProcess.postMessage(message);
          const answer = await result;
          assert.equal(answer.error, undefined, builder);
          done = answer.done;
        }
        assert.equal(done, true, builder);
      } finally { await builderProcess.terminate(); }
    }
    assert.deepEqual(store.postAfter("s", thread, 0), { n: 1, ts: "post" });
    assert.equal(store.db.prepare("SELECT said_other_n FROM thread_state WHERE thread=?").get(saidThread)?.said_other_n, 1);
    assert.equal(store.db.prepare("SELECT n FROM session_turns WHERE session='old-turn'").get()?.n, 70);
    assert.deepEqual(store.recoveryWaits()?.map(({ row }) => row.key), ["old-count"]);
    assert.equal(store.db.prepare("SELECT name FROM sandbox_name_rows WHERE session=?").get("old-count")?.name, sandboxName(keyPart("old-count")));
    assert.equal(store.db.prepare("SELECT root FROM session_dir_rows WHERE session=?").get("old-count")?.root, "/w");
    assert.equal(store.db.prepare("SELECT workspace FROM chat_share_targets WHERE session=?").get("old-share")?.workspace, "other");
    assert.equal(store.db.prepare("SELECT job FROM process_job_rows WHERE job=?").get("old-job")?.job, "old-job");
    assert.equal(store.db.prepare("SELECT scanned FROM legacy_said_meta WHERE id=1").get()?.scanned, 1);
    assert.equal(store.db.prepare("SELECT scanned FROM legacy_agent_meta WHERE id=1").get()?.scanned, 1);
    assert.deepEqual(store.sessionCounts(), [{ connect: "ember", ws: "mine", n: 1 }]);
    assert.equal(store.db.prepare("SELECT session FROM session_list_rows WHERE ws='mine'").get()?.session, "old-count");
    assert.equal(store.db.prepare("SELECT connect FROM session_binding_rows WHERE session='old-count'").get()?.connect, "old-binding");
    assert.equal(store.db.prepare("SELECT session FROM archive_pin_rows WHERE session='old-count'").get()?.session, "old-count");
    assert.deepEqual(store.upJobIds("old-count"), ["old-job"]);
    assert.equal(store.db.prepare("SELECT name FROM widget_source_rows WHERE thread=? AND path='/w/bundle.html'").get(thread)?.name, "bundle.html");
    assert.equal(store.db.prepare("SELECT complete FROM cc_sessions WHERE session='old-cc'").get()?.complete, 1);
    assert.equal(store.db.prepare("SELECT n FROM card_posts WHERE thread=?").get(thread)?.n, 1);
    assert.equal(store.db.prepare("SELECT complete FROM legacy_people_time_scopes WHERE thread=?").get(saidThread)?.complete, 1);
  } finally { store.close(); rmSync(directory, { recursive: true, force: true }); }
});
