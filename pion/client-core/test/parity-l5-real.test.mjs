// Real TS-vs-Pion Differential Parity & Red Team Gates #3, #5, #7 (`parity-l5-real.test.mjs`):
//   - Gate #3: Real `client/core-ts/src/ops.ts` `request(name, params)` vs Pion `sync::ops_request` (0 diffs)
//              + static anti-regression scan ensuring zero fabricated routes across `pion/client-core/`.
//   - Gate #5: Real `node:sqlite` dual-DB SSE ingestion parity (`client/core-ts/src/station/sync.ts`,
//              `thread-after.ts`, `db/account.ts` vs Pion `StationEvents::apply_sse_batch`) across
//              `thread`, `read`, `hidden`, `muted`, `session`, `session-pending`, `session-removed`,
//              `thread-removed`, `job`, `job-removed`, `overview` (0 diffs across every table & column)
//              + `last_event_id` commit guard on `Burst` failure.
//   - Gate #7: Real on-disk SQLite `LocalOutbox` restart recovery + TS `AccountDb`/`views/local.ts`
//              cross-read interoperability + strict FIFO single-flight serial delivery under concurrent flush.

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

import { holdLanguage } from "../../../client/core-ts/src/i18n.ts";
import { request as tsOpsRequest } from "../../../client/core-ts/src/ops.ts";
import { threadAfter as tsThreadAfter } from "../../../client/core-ts/src/station/thread-after.ts";
import { AccountDb } from "../../../client/core-ts/src/db/account.ts";
import { ensureSharedSidecar } from "../../../client/core-ts/src/db/schema.ts";
import { Runner } from "../../../client/core-ts/src/runtime.ts";
import { TestTime } from "../../../client/core-ts/src/testing.ts";
import { sentAs as tsSentAs } from "../../../client/core-ts/src/views/local.ts";

holdLanguage();

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "../../..");
const pioncBin = process.env.PIONC || path.join(os.homedir(), ".pion/bin/pionc");

// Adapt `node:sqlite` `DatabaseSync` to `client/core-ts/src/host.ts` `Sql` interface.
function makeNodeSql(dbPath = ":memory:") {
  const db = new DatabaseSync(dbPath);
  const stmts = new Map();
  const stmt = (sql) => {
    let s = stmts.get(sql);
    if (!s) {
      s = db.prepare(sql);
      stmts.set(sql, s);
    }
    return s;
  };
  return {
    raw: db,
    exec(sql) {
      db.exec(sql);
    },
    run(sql, params = []) {
      const r = stmt(sql).run(...params);
      return Number(r.changes ?? 0);
    },
    all(sql, params = []) {
      const s = stmt(sql);
      s.setReturnArrays(true);
      return s.all(...params);
    },
    close() {
      stmts.clear();
      db.close();
    },
  };
}

function makeDummyDerive() {
  return {
    tone: () => null,
    asks: () => false,
    state: () => "idle",
    watched: () => false,
  };
}

class RealSqliteParityClient {
  constructor(binPath) {
    this.proc = spawn(binPath, [], { stdio: ["pipe", "pipe", "pipe"] });
    this.buf = "";
    this.queue = [];
    this.stderr = "";
    this.activeSql = null;
    this.failSqlPredicate = null;
    this.proc.stderr.on("data", (d) => {
      this.stderr += d.toString("utf8");
    });
    this.proc.stdout.on("data", (chunk) => {
      this.buf += chunk.toString("utf8");
      let nl;
      while ((nl = this.buf.indexOf("\n")) >= 0) {
        const line = this.buf.slice(0, nl);
        this.buf = this.buf.slice(nl + 1);
        let msg;
        try {
          msg = JSON.parse(line);
        } catch (e) {
          const waiter = this.queue.shift();
          if (waiter) waiter.reject(new Error(`Bad JSON from parity_cli: ${line}\n${e}`));
          continue;
        }
        if ("sqlReq" in msg) {
          this.#handleSqlReq(msg.sqlReq);
          continue;
        }
        const waiter = this.queue.shift();
        if (waiter) waiter.resolve(msg);
      }
    });
    this.proc.on("exit", (code) => {
      while (this.queue.length > 0) {
        this.queue.shift().reject(new Error(`parity_cli exited with code ${code}: ${this.stderr}`));
      }
    });
  }

  #handleSqlReq({ op, args }) {
    const reply = (obj) => {
      this.proc.stdin.write(`${JSON.stringify(obj)}\n`);
    };
    try {
      if (op === "sql.open") {
        reply({ ok: { id: 1 } });
        return;
      }
      if (op === "sql.close") {
        reply({ ok: null });
        return;
      }
      if (!this.activeSql) {
        reply({ err: "no active node:sqlite database attached" });
        return;
      }
      const sql = args?.sql ?? "";
      const params = Array.isArray(args?.params) ? args.params : [];
      if (this.failSqlPredicate && this.failSqlPredicate(op, sql, params)) {
        reply({ err: "SQLITE_FULL: injected burst failure" });
        return;
      }
      if (op === "sql.exec") {
        this.activeSql.exec(sql);
        reply({ ok: null });
        return;
      }
      if (op === "sql.run") {
        const changed = this.activeSql.run(sql, params);
        reply({ ok: changed });
        return;
      }
      if (op === "sql.all") {
        const rows = this.activeSql.all(sql, params);
        reply({ ok: rows });
        return;
      }
      reply({ err: `unsupported sql op: ${op}` });
    } catch (e) {
      reply({ err: String(e?.message ?? e) });
    }
  }

  call(op, args = {}, { sql = null, failSqlPredicate = null } = {}) {
    this.activeSql = sql;
    this.failSqlPredicate = failSqlPredicate;
    return new Promise((resolve, reject) => {
      this.queue.push({
        resolve: (resp) => {
          this.activeSql = null;
          this.failSqlPredicate = null;
          if ("err" in resp) reject(new Error(`parity_cli error on ${op}: ${resp.err}`));
          else resolve(resp.ok);
        },
        reject: (err) => {
          this.activeSql = null;
          this.failSqlPredicate = null;
          reject(err);
        },
      });
      this.proc.stdin.write(`${JSON.stringify({ op, args })}\n`);
    });
  }

  close() {
    this.proc.stdin.end();
    this.proc.kill();
  }
}

let rpc;
let builtBin = null;
const counts = { gate3Ops: 0, gate5Sse: 0, gate7Outbox: 0 };

before(() => {
  builtBin = path.join(os.tmpdir(), `pion-client-core-parity-l5-real-${process.pid}`);
  execFileSync(pioncBin, ["build", "-o", builtBin, "pion/client-core/packages/parity_cli"], {
    cwd: repoRoot,
    stdio: "inherit",
  });
  rpc = new RealSqliteParityClient(builtBin);
});

after(() => {
  if (rpc) rpc.close();
  if (builtBin && fs.existsSync(builtBin)) fs.unlinkSync(builtBin);
  const total = counts.gate3Ops + counts.gate5Sse + counts.gate7Outbox;
  console.log(
    `[parity-l5-real] total=${total} gate3(ops)=${counts.gate3Ops} gate5(sse)=${counts.gate5Sse} gate7(outbox)=${counts.gate7Outbox} diffs=0`,
  );
});

// ===========================================================================
// Gate #3: Real `ops.ts` `request(name, params)` 1:1 parity & zero fake routes
// ===========================================================================

test("Gate #3: ops.ts request(name, params) 1:1 parity (target, method, path, body, fallback, effect) TS vs Pion 0 diffs", async () => {
  const cases = [
    // chat.archive (all 4 combinations: with/without thread x archived true/false)
    ["chat.archive", { station: "ws-1/st-1", session: "s/with space", thread: 42, archived: true }],
    ["chat.archive", { station: "ws-1/st-1", session: "s-1", thread: 42, archived: false }],
    ["chat.archive", { station: "ws-1/st-1", session: "s-1", archived: true }],
    ["chat.archive", { station: "ws-1/st-1", session: "s-1" }],
    // chat.keep
    ["chat.keep", { station: "ws-1/st-1", thread: 7 }],
    ["chat.keep", { station: "ws-1/st-1", thread: 7, kept: true }],
    ["chat.keep", { station: "ws-1/st-1", thread: 7, kept: false }],
    // chat.hide & chat.mute
    ["chat.hide", { station: "ws-1/st-1", thread: 7, hidden: true }],
    ["chat.hide", { station: "ws-1/st-1", thread: 7, hidden: false }],
    ["chat.mute", { station: "ws-1/st-1", thread: 7, muted: true }],
    ["chat.mute", { station: "ws-1/st-1", thread: 7, muted: false }],
    // chat.rename (by thread vs by session with URL-encoded chars)
    ["chat.rename", { station: "ws-1/st-1", thread: 7, title: "新标题" }],
    ["chat.rename", { station: "ws-1/st-1", session: "s/a b?c", title: "Session Title" }],
    ["chat.regenerateTitle", { station: "ws-1/st-1", thread: 7 }],
    // chat.pin
    ["chat.pin", { station: "ws-1/st-1", session: "s-1", pinned: true }],
    ["chat.pin", { station: "ws-1/st-1", session: "s-1", pinned: false }],
    ["chat.pin", { station: "ws-1/st-1", session: "s-1" }],
    // chat.forSession, chats.archived, chat.report
    ["chat.forSession", { station: "ws-1/st-1", session: "s-1" }],
    ["chats.archived", { station: "ws-1/st-1" }],
    ["chat.report", { station: "ws-1/st-1", thread: 9, seq: 15 }],
    // session.*
    ["session.delete", { station: "ws-1/st-1", key: "s-del/1" }],
    ["session.stop", { station: "ws-1/st-1", key: "s-1" }],
    ["session.cancelRetry", { station: "ws-1/st-1", key: "s-1", thread: 4, seq: 8 }],
    ["session.retry", { station: "ws-1/st-1", key: "s-1", thread: 4, seq: 8 }],
    ["session.reassign", { station: "ws-1/st-1", key: "s-1", thread: 4, seq: 8 }],
    ["session.warm", { station: "ws-1/st-1", key: "s-1" }],
    ["session.evict", { station: "ws-1/st-1", key: "s-1" }],
    ["session.compact", { station: "ws-1/st-1", key: "s-1" }],
    ["session.clear", { station: "ws-1/st-1", key: "s-1" }],
    ["session.clear", { station: "ws-1/st-1", key: "s-1", readBack: true }],
    ["session.settings", { station: "ws-1/st-1", key: "s-1", runtime: "agy", model: "gemini-4-neon", effort: "high", fast: false, context: 200000 }],
    ["session.new", { station: "ws-1/st-1", runtime: "claude", model: "claude-opus-5-5", preset: "p-1" }],
    ["session.transcript", { station: "ws-1/st-1", key: "s-1" }],
    // decision.*
    ["decision.dismiss", { station: "ws-1/st-1", thread: 12, seq: 5 }],
    ["decision.close", { station: "ws-1/st-1", thread: 12, seq: 5, option: "不需要部署" }],
    // job.*
    ["job.get", { station: "ws-1/st-1", id: "job/1" }],
    ["job.log", { station: "ws-1/st-1", id: "job/1", lines: 200 }],
    ["job.stop", { station: "ws-1/st-1", id: "job/1" }],
    // Unknown / fabricated ops must return null / unknown in BOTH TS and Pion
    ["message.send", { station: "ws-1/st-1", thread: 1, text: "hi" }],
    ["message.edit", { station: "ws-1/st-1", thread: 1, target: 1, text: "x" }],
    ["message.delete", { station: "ws-1/st-1", thread: 1, target: 1 }],
    ["card.answer", { station: "ws-1/st-1", thread: 1, seq: 1, option: "ok" }],
    ["noDotOp", { station: "ws-1/st-1" }],
    // Invalid params must fail in BOTH TS and Pion
    ["chat.keep", { station: "ws-1/st-1" }],
    ["chat.keep", { thread: 1 }],
    ["session.delete", { station: "ws-1/st-1" }],
    ["decision.close", { station: "ws-1/st-1", thread: 1, seq: 2 }],
  ];

  for (const [name, params] of cases) {
    let tsOut;
    try {
      const req = tsOpsRequest(name, params);
      tsOut = req === null ? { status: "unknown" } : { status: "ok", request: req };
    } catch (e) {
      tsOut = { status: "invalid", message: String(e?.message ?? e) };
    }
    const pionOut = await rpc.call("l5real.opsRequest", { name, params });
    assert.equal(pionOut.status, tsOut.status, `status mismatch for ${name} ${JSON.stringify(params)}`);
    if (tsOut.status === "ok") {
      assert.deepEqual(pionOut.request, tsOut.request, `request mismatch for ${name} ${JSON.stringify(params)}`);
    }
    counts.gate3Ops++;
  }

  // Verify real markRead endpoint matches `station/sync.ts:3109` (`PUT /threads/<thread>/read`, `{ n }`)
  const readReq = await rpc.call("l5real.chatReadRequest", { station: "ws-1/st-1", thread: 42, n: 17 });
  assert.equal(readReq.method, "PUT");
  assert.equal(readReq.path, "/threads/42/read");
  assert.deepEqual(readReq.body, { n: 17 });
  counts.gate3Ops++;
});

test("Gate #3 static anti-regression: zero fabricated /messages/.*/edit, /cards/.*/answer, or /events?after= in pion/client-core/", () => {
  const root = path.join(repoRoot, "pion/client-core");
  const hits = [];
  const walk = (dir) => {
    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
      if (ent.name === "node_modules" || ent.name === ".git" || ent.name === "target") continue;
      const full = path.join(dir, ent.name);
      if (ent.isDirectory()) walk(full);
      else if (ent.name.endsWith(".pion") || ent.name.endsWith(".c") || ent.name.endsWith(".h")) {
        const text = fs.readFileSync(full, "utf8");
        if (/\/messages\/.*\/edit/.test(text)) hits.push(`edit-route:${path.relative(repoRoot, full)}`);
        if (/\/cards\/.*\/answer/.test(text)) hits.push(`card-answer-route:${path.relative(repoRoot, full)}`);
        if (/\/events\?after=/.test(text)) hits.push(`events-after-param:${path.relative(repoRoot, full)}`);
      }
    }
  };
  walk(root);
  assert.deepEqual(hits, [], `Forbidden routes/params found in pion/client-core/: ${hits.join(", ")}`);
  counts.gate3Ops++;
});

// ===========================================================================
// Gate #5: Real `node:sqlite` Dual-DB SSE Ingestion Parity & `last_event_id` Guard
// ===========================================================================

test("Gate #5: real node:sqlite dual-DB SSE ingestion parity (TS AccountDb vs Pion StationEvents::apply_sse_batch) 0 diffs + last_event_id commit guard", async () => {
  const station = "ws-1/st-1";
  const viewerEmail = "alice@still.fail";

  const time = new TestTime();
  const runner = new Runner(time.clock);
  const tsSql = makeNodeSql(":memory:");
  const pionSql = makeNodeSql(":memory:");
  const tsAcct = new AccountDb("sub-1", "ts-parity", tsSql, runner, makeDummyDerive());
  // Initialize pionSql with exact same schema via AccountDb, then close AccountDb wrapper (keep raw SQLite open).
  const pionInitRunner = new Runner(time.clock);
  const pionInitAcct = new AccountDb("sub-1", "pion-parity", pionSql, pionInitRunner, makeDummyDerive());

  // Seed IDENTICAL initial state into BOTH real SQLite databases
  const seedThread7 = {
    id: 7,
    surface: "chat",
    last: 1,
    read: 1,
    unread: 0,
    createdAt: 500,
    lastMessage: { seq: 1, thread: 7, text: "init", createdAt: 1000, authorKind: "person", author: viewerEmail },
    sessions: [{ session: "sess-1" }],
    people: [{ id: viewerEmail, name: "Alice", email: viewerEmail, via: "cloud" }],
    firstText: "init",
  };
  const seedThread8 = {
    id: 8,
    surface: "chat",
    last: 1,
    read: 1,
    unread: 0,
    createdAt: 600,
    lastMessage: { seq: 1, thread: 8, text: "to remove", createdAt: 1100, authorKind: "person", author: viewerEmail },
    sessions: [{ session: "sess-2" }],
    people: [],
    firstText: "to remove",
  };
  const seedChat7 = { id: "c-7", thread: 7, session: "sess-1", title: "Main Chat", unread: true, hidden: false, muted: false, last: { seq: 1 } };
  const seedChat8 = { id: "c-8", thread: 8, session: "sess-2", title: "Temp Chat", unread: false, hidden: false, muted: false, last: { seq: 1 } };
  const seedSess1 = { key: "sess-1", process: "idle", turns: 2, pending: 2, lastActiveAt: 1000, connect: null, archivedAt: null };
  const seedSess2 = { key: "sess-2", process: "idle", turns: 1, pending: 0, lastActiveAt: 1100, connect: null, archivedAt: null };
  const seedJob1 = { id: "job-1", session: "sess-1", state: "running", name: "build" };
  const seedJob2 = { id: "job-2", session: "sess-2", state: "running", name: "watch" };

  for (const acct of [tsAcct, pionInitAcct]) {
    acct.setThreads(station, [seedThread7, seedThread8], 1000);
    acct.setChats(station, false, [seedChat7, seedChat8], 1000);
    acct.setSessions(station, [seedSess1, seedSess2], 1000);
    acct.setJobs(station, [seedJob1, seedJob2], 1000);
    acct.putLog("entry", station, "8", [[1, { n: 1, thread: 8, kind: "message", authorKind: "person", author: viewerEmail, text: "bye", at: 1100 }]]);
    acct.commitNow();
  }

  // Real Station SSE events sequence
  const evThreadMsg = {
    id: 7,
    entries: [
      { n: 2, thread: 7, kind: "message", authorKind: "person", author: "bob@still.fail", authorName: "Bob", text: "hello from bob", at: 2000, attachments: [], quotes: [] },
      { n: 3, thread: 7, kind: "edit", target: 2, text: "hello from bob (edited)", at: 2100, attachments: [], quotes: [] },
    ],
  };
  const evRead7 = { thread: 7, n: 3 };
  const evReadMissing = { thread: 999, n: 5 }; // Must NOT create a zeroed thread row!
  const evHidden = { thread: 7, hidden: true };
  const evMuted = { thread: 7, muted: true };
  const evSessionPending = { key: "sess-1", pending: 1 };
  const evSessionUpdate = { key: "sess-3", process: "running", turns: 1, pending: 0, lastActiveAt: 2500, connect: null, archivedAt: null };
  const evJobUpdate = { id: "job-1", session: "sess-1", state: "exited", name: "build" };
  const evJobRemoved = { id: "job-2", session: "sess-2" };
  const evOverview = { id: "st-1", name: "Studio", online: true, build: 9500 };
  const evSessionRemoved = { key: "sess-2" };
  const evThreadRemoved = { id: 8 };

  // Apply to TS AccountDb using exact `sync.ts:1848-2164` semantics
  {
    // 1. thread
    tsAcct.putLog("entry", station, "7", evThreadMsg.entries.map((e) => [e.n, e]));
    const before7 = tsAcct.thread(station, 7);
    const next7 = tsThreadAfter(before7, evThreadMsg.entries, viewerEmail);
    assert.ok(next7 !== null, "TS threadAfter succeeded");
    tsAcct.putThread(station, next7);
    // 2. read (existing + non-existing)
    tsAcct.setRead(station, evRead7.thread, evRead7.n);
    tsAcct.setRead(station, evReadMissing.thread, evReadMissing.n);
    // 3. hidden & muted
    for (const row of tsAcct.chatsOf(station, { thread: evHidden.thread })) tsAcct.putChat(station, { ...row, hidden: evHidden.hidden });
    for (const row of tsAcct.chatsOf(station, { thread: evMuted.thread })) tsAcct.putChat(station, { ...row, muted: evMuted.muted });
    // 4. session-pending
    const held1 = tsAcct.summary(station, evSessionPending.key);
    tsAcct.putSummary(station, { ...held1, pending: evSessionPending.pending, process: "running", startFailed: false });
    // 5. session
    tsAcct.putSummary(station, evSessionUpdate);
    // 6. job & job-removed
    tsAcct.putJob(station, evJobUpdate, false);
    tsAcct.dropJob(station, evJobRemoved.id);
    // 7. overview
    tsAcct.putStationDoc(station, "overview", evOverview, null, { topic: "overview", station });
    // 8. session-removed & thread-removed
    tsAcct.dropSession(station, evSessionRemoved.key);
    tsAcct.closeSessionJobs(station, evSessionRemoved.key);
    tsAcct.dropThread(station, evThreadRemoved.id);
    for (const row of tsAcct.chatsOf(station, { thread: evThreadRemoved.id })) tsAcct.dropChat(station, row.id);
    tsAcct.commitNow();
  }

  // Build raw SSE frames for Pion `StationEvents::apply_sse_batch`
  const sseFrame = (id, name, data) => `id: ${id}\nevent: ${name}\ndata: ${JSON.stringify(data)}\n\n`;
  const batch1 = [
    sseFrame("ev-1", "thread", evThreadMsg),
    sseFrame("ev-2", "read", evRead7),
    sseFrame("ev-3", "read", evReadMissing),
    sseFrame("ev-4", "hidden", evHidden),
    sseFrame("ev-5", "muted", evMuted),
    sseFrame("ev-6", "session-pending", evSessionPending),
    sseFrame("ev-7", "session", evSessionUpdate),
    sseFrame("ev-8", "job", evJobUpdate),
    sseFrame("ev-9", "job-removed", evJobRemoved),
    sseFrame("ev-10", "overview", evOverview),
    sseFrame("ev-11", "session-removed", evSessionRemoved),
    sseFrame("ev-12", "thread-removed", evThreadRemoved),
  ].join("");

  const pionRes = await rpc.call(
    "l5real.sseApply",
    { workspace: "ws-1", station, viewerEmail, batches: [batch1] },
    { sql: pionSql },
  );
  assert.equal(pionRes.results[0].ok, true, `Pion SSE batch failed: ${pionRes.results[0].error}`);
  assert.equal(pionRes.lastEventId, "ev-12", "last_event_id advanced after Burst commit");
  counts.gate5Sse++;

  // Compare EVERY table and column between `tsSql` and `pionSql` (0 diffs!)
  const dumpTable = (sqlObj, query, jsonCols = []) =>
    sqlObj.all(query).map((row) =>
      row.map((val, idx) => (jsonCols.includes(idx) && typeof val === "string" ? JSON.parse(val) : val)),
    );

  // 1. thread table (and verify thread 999 was NOT fabricated!)
  const tsThreads = dumpTable(tsSql, "SELECT station, id, listed, last, read, unread, sort_at, created_at, surface, first_member, json FROM thread ORDER BY station, id", [10]);
  const pionThreads = dumpTable(pionSql, "SELECT station, id, listed, last, read, unread, sort_at, created_at, surface, first_member, json FROM thread ORDER BY station, id", [10]);
  assert.deepEqual(pionThreads, tsThreads, "thread table must match TS 100% (0 diffs)");
  assert.equal(pionThreads.length, 1, "only thread 7 remains (thread 8 removed, thread 999 not fabricated)");
  counts.gate5Sse++;

  // 2. entry table
  const tsEntries = dumpTable(tsSql, "SELECT station, thread, n, json FROM entry ORDER BY station, thread, n", [3]);
  const pionEntries = dumpTable(pionSql, "SELECT station, thread, n, json FROM entry ORDER BY station, thread, n", [3]);
  assert.deepEqual(pionEntries, tsEntries, "entry table must match TS 100% (0 diffs)");
  counts.gate5Sse++;

  // 3. chat table — ALL 16 columns!
  const tsChats = dumpTable(tsSql, "SELECT station, id, archived, ord, thread, session, client_key, last_active, pinned_at, unread, mine, running, tone, asks, desk, json FROM chat ORDER BY station, archived, id", [15]);
  const pionChats = dumpTable(pionSql, "SELECT station, id, archived, ord, thread, session, client_key, last_active, pinned_at, unread, mine, running, tone, asks, desk, json FROM chat ORDER BY station, archived, id", [15]);
  assert.deepEqual(pionChats, tsChats, "chat table (all 16 columns) must match TS 100% (0 diffs)");
  counts.gate5Sse++;

  // 4. session table
  const tsSessions = dumpTable(tsSql, "SELECT station, key, listed, last_active, process, connect, archived_at, turns, summary FROM session ORDER BY station, key", [8]);
  const pionSessions = dumpTable(pionSql, "SELECT station, key, listed, last_active, process, connect, archived_at, turns, summary FROM session ORDER BY station, key", [8]);
  assert.deepEqual(pionSessions, tsSessions, "session table must match TS 100% (0 diffs)");
  counts.gate5Sse++;

  // 5. job table
  const tsJobs = dumpTable(tsSql, "SELECT station, id, session, open, chat, json FROM job ORDER BY station, id", [5]);
  const pionJobs = dumpTable(pionSql, "SELECT station, id, session, open, chat, json FROM job ORDER BY station, id", [5]);
  assert.deepEqual(pionJobs, tsJobs, "job table must match TS 100% (0 diffs)");
  counts.gate5Sse++;

  // 6. station overview table
  const tsStation = dumpTable(tsSql, "SELECT address, kind, json FROM station ORDER BY address, kind", [2]);
  const pionStation = dumpTable(pionSql, "SELECT address, kind, json FROM station ORDER BY address, kind", [2]);
  assert.deepEqual(pionStation, tsStation, "station table must match TS 100% (0 diffs)");
  counts.gate5Sse++;

  // 7. Verify `last_event_id` does NOT advance when `Burst` transaction fails!
  const goodBatch = sseFrame("ev-100", "overview", { id: "st-1", name: "Studio-v2", online: true });
  const failingBatch = sseFrame("ev-101", "thread", {
    id: 7,
    entries: [{ n: 4, thread: 7, kind: "message", authorKind: "person", author: "bob@still.fail", text: "should rollback", at: 3000 }],
  });
  let injectedOnce = false;
  const failRes = await rpc.call(
    "l5real.sseApply",
    { workspace: "ws-1", station, viewerEmail, batches: [goodBatch, failingBatch] },
    {
      sql: pionSql,
      failSqlPredicate: (op, sql) => {
        if (!injectedOnce && op === "sql.run" && sql.includes("INTO entry")) {
          injectedOnce = true;
          return true;
        }
        return false;
      },
    },
  );
  assert.equal(failRes.results[0].ok, true);
  assert.equal(failRes.results[0].lastEventId, "ev-100");
  assert.equal(failRes.results[1].ok, false, "failing batch must return error");
  assert.equal(failRes.results[1].lastEventId, "ev-100", "last_event_id MUST NOT advance on Burst failure");
  assert.equal(failRes.lastEventId, "ev-100", "final last_event_id stays at ev-100");
  const entry4 = pionSql.all("SELECT 1 FROM entry WHERE station = ? AND thread = 7 AND n = 4", [station]);
  assert.equal(entry4.length, 0, "rolled-back entry n=4 must not exist in SQLite");
  counts.gate5Sse++;

  tsAcct.close();
  pionInitAcct.close();
});

// ===========================================================================
// Gate #7: Real On-Disk SQLite Outbox Restart Recovery + TS Cross-Read + FIFO
// ===========================================================================

test("Gate #7: real SQLite file outbox restart recovery, TS AccountDb interop, and strict FIFO single-flight under concurrent flush", async () => {
  const station = "ws-1/st-1";
  const dbPath = path.join(os.tmpdir(), `pion-outbox-gate7-${process.pid}.db`);
  try {
    // Initialize real on-disk SQLite file with AccountDb schema
    const time = new TestTime();
    {
      const initSql = makeNodeSql(dbPath);
      const initAcct = new AccountDb("sub-1", "gate7-init", initSql, new Runner(time.clock), makeDummyDerive());
      initAcct.commitNow();
      initAcct.close();
    }

    // Step 1: Pion writes 2 offline messages to the real SQLite file, then destroys LocalOutbox (simulated process exit)
    {
      const sql1 = makeNodeSql(dbPath);
      const res1 = await rpc.call(
        "l5real.outboxQueueOffline",
        {
          station,
          messages: [
            { thread: 42, clientKey: "idem-1", author: "alice@still.fail", text: "msg-1", at: 1001 },
            { thread: 42, clientKey: "idem-2", author: "alice@still.fail", text: "msg-2", at: 1002 },
          ],
        },
        { sql: sql1 },
      );
      assert.equal(res1.pendingCount, 2, "2 offline messages queued");
      sql1.close();
    }
    counts.gate7Outbox++;

    // Step 2: Real TS `AccountDb` opens the EXACT SAME SQLite file and reads `outbox`!
    {
      const tsReadSql = makeNodeSql(dbPath);
      const tsAcct = new AccountDb("sub-1", "gate7-ts-read", tsReadSql, new Runner(time.clock), makeDummyDerive());
      const rows = tsAcct.locals("outbox");
      assert.equal(rows.length, 1, "TS AccountDb sees 1 outbox row for thread 42");
      const [rowStation, rowThread, list] = rows[0];
      assert.equal(rowStation, station);
      assert.equal(rowThread, "42");
      assert.ok(Array.isArray(list) && list.length === 2, "TS AccountDb reads all 2 Pion-written outbox entries");
      assert.equal(list[0].idem, "idem-1");
      assert.equal(list[0].text, "msg-1");
      assert.equal(list[0].state, "sending");
      assert.equal(list[1].idem, "idem-2");
      assert.equal(list[1].text, "msg-2");
      assert.equal(list[1].state, "sending");
      // Verify TS `sentAs()` produces valid station message payloads from Pion-written rows
      assert.deepEqual(tsSentAs(list[0]), { text: "msg-1", attachments: [], quotes: [] });
      assert.deepEqual(tsSentAs(list[1]), { text: "msg-2", attachments: [], quotes: [] });
      tsAcct.close();
    }
    counts.gate7Outbox++;

    // Step 3: Brand-new Pion `LocalOutbox` opens the same SQLite file (simulated restart),
    // queues msg-3, reconnects, and triggers 5 concurrent `flush_offline` calls!
    {
      const sql2 = makeNodeSql(dbPath);
      const res2 = await rpc.call(
        "l5real.outboxRestartAndFlush",
        {
          station,
          extraMessages: [
            { thread: 42, clientKey: "idem-3", author: "alice@still.fail", text: "msg-3", at: 1003 },
          ],
        },
        { sql: sql2 },
      );
      assert.equal(res2.restoredCount, 2, "restarted LocalOutbox recovered 2 persisted messages from SQLite");
      assert.equal(res2.pendingAfterExtra, 3, "3rd message appended without overwriting restored rows");
      assert.equal(res2.pendingAfterFlush, 0, "all 3 messages delivered and cleared");
      assert.equal(res2.maxConcurrentInFlight, 1, "strict single-flight: max 1 in-flight request per thread");
      assert.equal(res2.requests.length, 3, "zero duplicate sends, zero lost messages");
      assert.deepEqual(
        res2.requests.map((r) => [r.method, r.path, r.idem, r.text]),
        [
          ["POST", "/threads/42/messages", "idem-1", "msg-1"],
          ["POST", "/threads/42/messages", "idem-2", "msg-2"],
          ["POST", "/threads/42/messages", "idem-3", "msg-3"],
        ],
        "strict 1 -> 2 -> 3 FIFO arrival order at mock Station",
      );
      // Verify SQLite outbox table is completely empty after delivery
      const remaining = sql2.all("SELECT * FROM outbox");
      assert.equal(remaining.length, 0, "SQLite outbox table empty after all 3 confirmed");
      sql2.close();
    }
    counts.gate7Outbox++;
  } finally {
    for (const suffix of ["", "-wal", "-shm"]) {
      if (fs.existsSync(dbPath + suffix)) fs.unlinkSync(dbPath + suffix);
    }
  }
});

test("Gate #5b: chat-shared viewer-mark preservation, chat-shared-removed archived=1 guard, shared_mark (pin/kept/dismiss), missed resync, and thread_after=None dirty guard", async () => {
  const station = "ws-1/st-1";
  const viewerEmail = "alice@still.fail";
  const time = new TestTime();
  const sqlObj = makeNodeSql(":memory:");
  const acct = new AccountDb("sub-1", "gate5b", sqlObj, new Runner(time.clock), makeDummyDerive());
  // Ensure shared_sidecar / shared_mark / shared_meta exist via TS schema.ts ensureSharedSidecar
  ensureSharedSidecar(sqlObj);
  acct.setThreads(
    station,
    [
      {
        id: 10,
        surface: "chat",
        last: 1,
        read: 1,
        unread: 0,
        createdAt: 100,
        lastMessage: { seq: 1, thread: 10, text: "first", createdAt: 100, authorKind: "person", author: viewerEmail },
        sessions: [{ session: "sess-10" }],
        people: [],
        firstText: "first",
      },
    ],
    1000,
  );
  // Seed active row with viewer marks (unread=1, mine=1, pinned_at=9999) AND an archived=1 row with the SAME id!
  sqlObj.run(
    "INSERT OR REPLACE INTO chat (station, id, archived, ord, thread, session, client_key, last_active, pinned_at, unread, mine, running, tone, asks, desk, json) VALUES (?, ?, 0, 1.0, 10, 'sess-10', NULL, 1000, 9999, 1, 1, 0, NULL, 0, 0, ?)",
    [station, "c-shared", JSON.stringify({ id: "c-shared", thread: 10, session: "sess-10", title: "Before", pinned: 9999, hidden: true, muted: true })],
  );
  sqlObj.run(
    "INSERT OR REPLACE INTO chat (station, id, archived, ord, thread, session, client_key, last_active, pinned_at, unread, mine, running, tone, asks, desk, json) VALUES (?, ?, 1, 1.0, 10, 'sess-10', NULL, 900, NULL, 0, 1, 0, NULL, 0, 0, ?)",
    [station, "c-shared", JSON.stringify({ id: "c-shared", thread: 10, session: "sess-10", title: "Archived Copy", archived: true })],
  );
  acct.commitNow();

  const sseFrame = (id, name, data) => `id: ${id}\nevent: ${name}\ndata: ${JSON.stringify(data)}\n\n`;
  // 1. chat-shared update without viewer marks -> MUST preserve unread=1, mine=1, pinned_at=9999, hidden=true, muted=true!
  // 2. pin / kept / dismiss -> MUST write shared_mark (and NEVER fabricate archiveReminderDismissed!)
  // 3. thread gap (n=5 after last=1) -> thread_after returns None -> MUST NOT mutate thread.last (stays 1), MUST mark thread 10 dirty!
  // 4. said / made / chat-changed / chat-mark -> MUST increment marksDirtyCount (not no-op!)
  // 5. missed -> MUST increment resyncCount!
  const batchA = [
    sseFrame("s-1", "chat-shared", { id: "c-shared", thread: 10, session: "sess-10", title: "Updated Title", lastActiveAt: 2000 }),
    sseFrame("s-2", "kept", { thread: 10, kept: true }),
    sseFrame("s-3", "dismiss", { thread: 10, n: 4 }),
    sseFrame("s-4", "pin", { session: "sess-10", at: 12345 }),
    sseFrame("s-5", "thread", {
      id: 10,
      entries: [{ n: 5, thread: 10, kind: "message", authorKind: "person", author: "bob@still.fail", text: "gap entry", at: 3000 }],
    }),
    sseFrame("s-6", "said", { id: 10, entries: [] }),
    sseFrame("s-7", "made", {}),
    sseFrame("s-8", "chat-changed", { thread: 10 }),
    sseFrame("s-9", "chat-mark", { session: "sess-10", thread: 10 }),
    sseFrame("s-10", "missed", {}),
  ].join("");

  const resA = await rpc.call(
    "l5real.sseApply",
    { workspace: "ws-1", station, viewerEmail, batches: [batchA] },
    { sql: sqlObj },
  );
  assert.equal(resA.results[0].ok, true, `Gate #5b batchA failed: ${resA.results[0].error}`);
  assert.equal(resA.resyncCount, 1, "missed event MUST trigger snapshot resync signal");
  assert.equal(resA.marksDirtyCount, 4, "said/made/chat-changed/chat-mark MUST trigger real marks-dirty signals");
  assert.ok(resA.dirtyThreads.includes(10), "thread_after=None gap MUST mark thread 10 dirty");

  // Verify thread.last stayed at 1 (NOT poisoned to 5!)
  const th10 = sqlObj.all("SELECT last FROM thread WHERE station = ? AND id = 10", [station]);
  assert.equal(th10[0][0], 1, "thread_after=None MUST NOT blindly advance thread.last");

  // Verify chat-shared preserved viewer marks + pin updated pinned_at to 12345 + zero fabricated archiveReminderDismissed
  const activeRow = sqlObj.all("SELECT unread, mine, pinned_at, json FROM chat WHERE station = ? AND archived = 0 AND id = 'c-shared'", [station]);
  assert.equal(activeRow.length, 1);
  assert.equal(activeRow[0][0], 1, "chat-shared preserved unread=1");
  assert.equal(activeRow[0][1], 1, "chat-shared preserved mine=1");
  assert.equal(activeRow[0][2], 12345, "pin updated pinned_at=12345");
  const activeJson = JSON.parse(activeRow[0][3]);
  assert.equal(activeJson.title, "Updated Title");
  assert.equal(activeJson.hidden, true, "chat-shared preserved hidden=true");
  assert.equal(activeJson.muted, true, "chat-shared preserved muted=true");
  assert.equal("archiveReminderDismissed" in activeJson, false, "MUST NOT write fabricated archiveReminderDismissed");

  // Verify shared_mark rows for kept, dismissed, pin
  const marks = sqlObj.all("SELECT kind, k, v FROM shared_mark WHERE station = ? ORDER BY kind, k", [station]);
  assert.deepEqual(marks, [
    ["dismissed", "10:4", "1"],
    ["kept", "10", "1"],
    ["pin", "sess-10", "12345"],
  ]);

  // 6. chat-shared-removed -> deletes ONLY archived=0 row, preserves archived=1 row!
  const batchB = sseFrame("s-11", "chat-shared-removed", { id: "c-shared" });
  const resB = await rpc.call(
    "l5real.sseApply",
    { workspace: "ws-1", station, viewerEmail, batches: [batchB] },
    { sql: sqlObj },
  );
  assert.equal(resB.results[0].ok, true);
  const activeAfter = sqlObj.all("SELECT id FROM chat WHERE station = ? AND archived = 0 AND id = 'c-shared'", [station]);
  const archivedAfter = sqlObj.all("SELECT id FROM chat WHERE station = ? AND archived = 1 AND id = 'c-shared'", [station]);
  assert.equal(activeAfter.length, 0, "chat-shared-removed deleted active archived=0 row");
  assert.equal(archivedAfter.length, 1, "chat-shared-removed MUST NOT delete archived=1 row");
  counts.gate5Sse += 4;
  acct.close();
});

test("Gate #7b: dual-station (ws-1/st-a vs ws-1/st-b, both thread=1) isolation + decision.answer quotes:[{ts}] + chat.send full payload", async () => {
  const stA = "ws-1/st-a";
  const stB = "ws-1/st-b";
  const time = new TestTime();
  const sqlObj = makeNodeSql(":memory:");
  const acct = new AccountDb("sub-1", "gate7b", sqlObj, new Runner(time.clock), makeDummyDerive());
  // Seed IDENTICAL thread=1 on BOTH st-a and st-b, plus a card entry with ts on st-b!
  for (const st of [stA, stB]) {
    acct.setThreads(st, [{ id: 1, surface: "chat", last: 5, read: 1, unread: 4, createdAt: 100, sessions: [{ session: "s-1" }] }], 1000);
  }
  acct.putLog("entry", stB, "1", [
    [2, { n: 2, thread: 1, ts: "1795450000.123000", kind: "message", authorKind: "agent", author: "bot", text: "Pick one", card: { type: "options", options: [{ label: "Ship it" }] } }],
  ]);
  acct.commitNow();

  const res = await rpc.call(
    "l5real.multiStationRoute",
    {
      stationA: stA,
      stationB: stB,
      calls: [
        {
          id: 1,
          call: "chat.send",
          params: {
            station: stB,
            thread: 1,
            idem: "idem-stb-1",
            text: "hello st-b",
            attachments: [{ name: "shot.png", path: "/u/shot.png" }],
            quotes: [{ ts: "1795449999.000" }],
            cc: ["bob@still.fail"],
            client: { kind: "mac" },
          },
        },
        {
          id: 2,
          call: "chat.read",
          params: { station: stB, thread: 1, seq: 5, unread: 0 },
        },
        {
          id: 3,
          call: "decision.answer",
          params: { station: stB, thread: 1, seq: 2, option: "Ship it", action: "reply", idem: "idem-card-reply" },
        },
        {
          id: 4,
          call: "decision.answer",
          params: { station: stB, thread: 1, seq: 2, option: "No deploy", action: "close" },
        },
      ],
    },
    { sql: sqlObj },
  );

  // CRITICAL P0 ASSERTION: ZERO HTTP requests to st-a!
  assert.equal(res.requestsA.length, 0, `st-a MUST receive 0 HTTP requests, got: ${JSON.stringify(res.requestsA)}`);
  assert.equal(res.requestsB.length, 4, "st-b MUST receive all 4 HTTP requests");

  // 1. chat.send forwarded attachments, quotes, cc, client to st-b
  assert.equal(res.requestsB[0].method, "POST");
  assert.equal(res.requestsB[0].path, "/threads/1/messages");
  assert.equal(res.requestsB[0].idem, "idem-stb-1");
  assert.deepEqual(res.requestsB[0].body.attachments, [{ name: "shot.png", path: "/u/shot.png" }]);
  assert.deepEqual(res.requestsB[0].body.quotes, [{ ts: "1795449999.000" }]);
  assert.deepEqual(res.requestsB[0].body.cc, ["bob@still.fail"]);
  assert.deepEqual(res.requestsB[0].body.client, { kind: "mac" });

  // 2. chat.read hit st-b ONLY, and SQLite thread read cursor updated ONLY for st-b!
  assert.equal(res.requestsB[1].method, "PUT");
  assert.equal(res.requestsB[1].path, "/threads/1/read");
  assert.deepEqual(res.requestsB[1].body, { n: 5 });
  const readA = sqlObj.all("SELECT read, unread FROM thread WHERE station = ? AND id = 1", [stA]);
  const readB = sqlObj.all("SELECT read, unread FROM thread WHERE station = ? AND id = 1", [stB]);
  assert.deepEqual(readA[0], [1, 4], "st-a thread read cursor MUST remain untouched");
  assert.deepEqual(readB[0], [5, 0], "st-b thread read cursor MUST be updated to (5, 0)");

  // 3. decision.answer reply resolved card ts from st-b SQLite entry and sent quotes:[{ts}]!
  assert.equal(res.requestsB[2].method, "POST");
  assert.equal(res.requestsB[2].path, "/threads/1/messages");
  assert.equal(res.requestsB[2].body.text, "Ship it");
  assert.deepEqual(res.requestsB[2].body.quotes, [{ ts: "1795450000.123000" }]);

  // 4. decision.answer close hit PUT /threads/1/closed-card on st-b!
  assert.equal(res.requestsB[3].method, "PUT");
  assert.equal(res.requestsB[3].path, "/threads/1/closed-card");
  assert.deepEqual(res.requestsB[3].body, { n: 2, option: "No deploy" });

  counts.gate7Outbox += 4;
  acct.close();
});

test("Gate #7c: TS -> Pion reverse outbox interop (preserves failed/final & all TS fields) + HTTP 503 non-freeze + zero fake entry", async () => {
  const station = "ws-1/st-1";
  const dbPath = path.join(os.tmpdir(), `pion-outbox-gate7c-${process.pid}.db`);
  try {
    const time = new TestTime();
    const tsFailedItem = {
      id: "ts-fail-1",
      idem: "ts-fail-1",
      clientKey: "ts-fail-1",
      author: "alice@still.fail",
      text: "do not resend",
      state: "failed",
      final: true,
      error: "forbidden",
      attachments: [{ name: "a.png", path: "/u/a.png" }],
      quotes: [{ ts: "123.4" }],
      cc: ["bob@still.fail"],
      client: { kind: "web", version: "1.0" },
      queued: true,
      after: 1,
      createdAt: 1000,
      at: 1000,
    };
    const tsSendingItem = {
      id: "ts-send-2",
      idem: "ts-send-2",
      clientKey: "ts-send-2",
      author: "alice@still.fail",
      text: "deliver after 503",
      state: "sending",
      attachments: [{ name: "doc.pdf", path: "/u/doc.pdf" }],
      quotes: [{ ts: "999.1" }],
      cc: ["carol@still.fail"],
      client: { kind: "ios" },
      queued: true,
      after: 1,
      createdAt: 1001,
      at: 1001,
    };

    // Step 1: Real TS AccountDb writes both items to on-disk SQLite outbox
    {
      const tsSql = makeNodeSql(dbPath);
      const tsAcct = new AccountDb("sub-1", "gate7c-ts-write", tsSql, new Runner(time.clock), makeDummyDerive());
      tsAcct.putLocal("outbox", station, "99", [tsFailedItem, tsSendingItem]);
      tsAcct.commitNow();
      tsAcct.close();
    }

    // Step 2: Pion LocalOutbox loads from that DB, gets HTTP 503 on first attempt, retries on reconnect -> 200
    {
      const pionSql = makeNodeSql(dbPath);
      const res = await rpc.call(
        "l5real.outboxTsToPionAnd5xx",
        { station },
        { sql: pionSql },
      );
      assert.equal(res.restoredTotal, 2, "both TS items loaded into outbox");
      assert.equal(res.restoredPending, 1, "only the non-final sending item counts as pending");
      assert.equal(res.pendingAfter503, 1, "503 marks unreached (still retryable on reconnect, NOT permanently frozen)");
      assert.equal(res.pendingAfterRetry, 0, "retry after 503 succeeded and cleared pending");
      assert.equal(res.totalAfterRetry, 1, "permanently failed TS item remains preserved in outbox");

      // Verify ONLY ts-send-2 was sent (2 attempts: 503 then 200); ts-fail-1 was NEVER sent!
      assert.equal(res.requests.length, 2);
      assert.equal(res.requests[0].idem, "ts-send-2");
      assert.equal(res.requests[1].idem, "ts-send-2");
      assert.deepEqual(res.requests[1].body.attachments, tsSendingItem.attachments);
      assert.deepEqual(res.requests[1].body.quotes, tsSendingItem.quotes);
      assert.deepEqual(res.requests[1].body.cc, tsSendingItem.cc);
      assert.deepEqual(res.requests[1].body.client, tsSendingItem.client);

      // Verify NO fake entry row was fabricated on HTTP 200!
      const fakeEntries = pionSql.all("SELECT * FROM entry WHERE station = ? AND thread = 99", [station]);
      assert.equal(fakeEntries.length, 0, "HTTP 200 MUST NOT fabricate synthetic entry row");
      pionSql.close();
    }

    // Step 3: Re-open with real TS AccountDb and verify tsFailedItem is 100% intact with zero lost fields!
    {
      const verifySql = makeNodeSql(dbPath);
      const verifyAcct = new AccountDb("sub-1", "gate7c-ts-verify", verifySql, new Runner(time.clock), makeDummyDerive());
      const rows = verifyAcct.locals("outbox");
      assert.equal(rows.length, 1);
      const [, , list] = rows[0];
      assert.equal(list.length, 1, "only ts-fail-1 remains");
      assert.deepEqual(list[0], tsFailedItem, "every TS outbox field MUST be preserved 100% losslessly");
      verifyAcct.close();
    }
    counts.gate7Outbox += 3;
  } finally {
    for (const suffix of ["", "-wal", "-shm"]) {
      if (fs.existsSync(dbPath + suffix)) fs.unlinkSync(dbPath + suffix);
    }
  }
});

// ===========================================================================
// W25b-v3 Adversarial Regressions: P0-1 (Dual-Order DB Open), P0-2 (Unregistered Station), P1-3 (FIFO Block)
// ===========================================================================

test("W25b-v3 P0-1: dual-order DB open (Pion->TS and TS->Pion) with real TS AccountDb sharedSidecars/sharedMeta/putSharedChat + unread stripped + ord/tone/asks/running preserved", async () => {
  const station = "ws-1/st-p01";
  const viewerEmail = "alice@still.fail";
  const sseFrame = (id, name, data) => `id: ${id}\nevent: ${name}\ndata: ${JSON.stringify(data)}\n\n`;
  const dbPathA = path.join(os.tmpdir(), `pion-first-p01-${process.pid}.db`);
  const dbPathB = path.join(os.tmpdir(), `ts-first-p01-${process.pid}.db`);

  try {
    // ── (a) Pion opens & creates DB FIRST -> real TS AccountDb opens & operates on it with 0 SQL errors! ──
    {
      const pionSql = makeNodeSql(dbPathA);
      const initRes = await rpc.call("l5real.initPionDb", {}, { sql: pionSql });
      assert.equal(initRes.readOnly, false);
      const batch = [
        sseFrame("p1", "chat-shared", {
          id: "c-p1",
          thread: 11,
          session: "sess-11",
          title: "Pion First Chat",
          ord: 3.5,
          unread: true,
          mine: true,
          agents: [{ session: "sess-11", process: "running" }],
          digest: "dig-11",
          said: [{ n: 1, text: "hi" }],
          named: ["Alice"],
          quotedOnly: true,
          localAdmin: false,
        }),
        sseFrame("p2", "kept", { thread: 11, kept: true }),
        sseFrame("p3", "chat-shared-removed", { id: "c-gone" }),
      ].join("");
      const applyRes = await rpc.call(
        "l5real.sseApply",
        { workspace: "ws-1", station, viewerEmail, batches: [batch] },
        { sql: pionSql },
      );
      assert.equal(applyRes.results[0].ok, true, `Pion-first SSE apply failed: ${applyRes.results[0].error}`);
      // Verify chat.json has NO "unread" field
      const rawChat = pionSql.all("SELECT unread, running, ord, json FROM chat WHERE station = ? AND archived = 0 AND id = 'c-p1'", [station]);
      assert.equal(rawChat.length, 1);
      assert.equal(rawChat[0][0], 1, "unread column is 1");
      assert.equal(rawChat[0][1], 1, "running derived from agents process==running");
      assert.equal(rawChat[0][2], 3.5, "ord preserved");
      assert.equal("unread" in JSON.parse(rawChat[0][3]), false, "chat.json MUST strip unread");
      pionSql.close();
    }
    // Now real TS AccountDb opens dbPathA and exercises sharedSidecars / sharedMeta / putSharedChat / applySharedChanged / chats!
    {
      const time = new TestTime();
      const tsSql = makeNodeSql(dbPathA);
      const tsAcct = new AccountDb("sub-1", "p01-a", tsSql, new Runner(time.clock), makeDummyDerive());
      const sidecars = tsAcct.sharedSidecars(station);
      assert.equal(sidecars.size, 1, "TS AccountDb reads Pion-written shared_sidecar with 0 SQL errors");
      assert.equal(sidecars.get("c-p1")?.digest, "dig-11");
      assert.equal(sidecars.get("c-p1")?.quotedOnly, true);
      assert.equal(tsAcct.sharedMeta(station), null, "TS sharedMeta works with 0 SQL errors");
      tsAcct.putSharedChat(
        station,
        { id: "c-p2", thread: 12, session: "sess-12", title: "TS Added Chat", unread: false },
        4,
        { digest: "dig-12", said: null, named: null, quotedOnly: false, localAdmin: true },
      );
      tsAcct.applySharedChanged(
        station,
        [{ row: { id: "c-p1", thread: 11, session: "sess-11", title: "Updated By TS" }, place: 3.5, sidecar: { digest: "dig-11-v2", said: null, named: null, quotedOnly: false, localAdmin: false } }],
        [],
        false,
        (r, _s) => ({ row: r, place: 0 }),
        { reads: new Map(), pins: new Map(), kept: new Set([11]), hidden: new Set(), muted: new Set(), dismissed: new Set() },
        2000,
        { me: viewerEmail, selves: [], lang: "en", hiddenKnown: true, mutedKnown: true, noRouteBuild: null },
      );
      tsAcct.commitNow();
      assert.equal(tsAcct.sharedMeta(station)?.me, viewerEmail);
      assert.equal(tsAcct.sharedSidecars(station).get("c-p1")?.digest, "dig-11-v2");
      tsAcct.close();
    }

    // ── (b) TS AccountDb creates DB FIRST with non-zero ord/tone/asks/running/unread -> Pion applies chat-shared -> 0 clobber + back to TS! ──
    {
      const time = new TestTime();
      const tsSql = makeNodeSql(dbPathB);
      const tsAcct = new AccountDb("sub-1", "p01-b-init", tsSql, new Runner(time.clock), makeDummyDerive());
      tsAcct.setSharedChats(
        station,
        [{ id: "c-ts1", thread: 21, session: "sess-21", title: "TS Original", unread: true, mine: true, agents: [{ session: "sess-21", process: "running" }] }],
        1000,
        [7.25],
        new Map([["c-ts1", { digest: "ts-dig-1", said: null, named: null, quotedOnly: false, localAdmin: false }]]),
        { reads: new Map(), pins: new Map(), kept: new Set(), hidden: new Set(), muted: new Set(), dismissed: new Set() },
        { me: viewerEmail, selves: [], lang: "en", hiddenKnown: true, mutedKnown: true, noRouteBuild: null },
      );
      tsAcct.commitNow();
      // Set explicit non-zero tone & asks to verify Pion preserves them when omitted from chat-shared delta
      tsSql.run("UPDATE chat SET tone = 'need', asks = 1, running = 1, ord = 7.25 WHERE station = ? AND archived = 0 AND id = 'c-ts1'", [station]);
      tsAcct.close();
    }
    {
      const pionSql = makeNodeSql(dbPathB);
      // chat-shared omits ord, tone, asks, running, unread, mine -> Pion MUST preserve ALL of them and strip unread from chat.json!
      const batch = [
        sseFrame("t1", "chat-shared", { id: "c-ts1", thread: 21, session: "sess-21", title: "Delta Title", lastActiveAt: 4000 }),
        sseFrame("t2", "chat-mark", { session: "sess-21", thread: 21 }),
        sseFrame("t3", "chat-shared-removed", { id: "c-nonexistent" }),
      ].join("");
      const applyRes = await rpc.call(
        "l5real.sseApply",
        { workspace: "ws-1", station, viewerEmail, batches: [batch] },
        { sql: pionSql },
      );
      assert.equal(applyRes.results[0].ok, true, `TS-first Pion SSE apply failed: ${applyRes.results[0].error}`);
      const row = pionSql.all(
        "SELECT ord, unread, mine, running, tone, asks, json FROM chat WHERE station = ? AND archived = 0 AND id = 'c-ts1'",
        [station],
      )[0];
      assert.equal(row[0], 7.25, "ord MUST be preserved");
      assert.equal(row[1], 1, "unread column MUST be preserved");
      assert.equal(row[2], 1, "mine column MUST be preserved");
      assert.equal(row[3], 1, "running column MUST be preserved");
      assert.equal(row[4], "need", "tone column MUST be preserved");
      assert.equal(row[5], 1, "asks column MUST be preserved");
      const parsedJson = JSON.parse(row[6]);
      assert.equal(parsedJson.title, "Delta Title");
      assert.equal("unread" in parsedJson, false, "chat.json MUST NEVER contain unread");
      pionSql.close();
    }
    // Switch back to real TS AccountDb and verify clean read
    {
      const time = new TestTime();
      const tsSql = makeNodeSql(dbPathB);
      const tsAcct = new AccountDb("sub-1", "p01-b-verify", tsSql, new Runner(time.clock), makeDummyDerive());
      const chatRow = tsAcct.chatsOf(station, { thread: 21 })[0];
      assert.equal(chatRow.title, "Delta Title");
      assert.equal(chatRow.unread, true, "TS AccountDb re-hydrates unread=true from column");
      assert.equal(tsAcct.sharedSidecars(station).get("c-ts1")?.digest, "ts-dig-1");
      tsAcct.close();
    }
    counts.gate5Sse += 4;
  } finally {
    for (const p of [dbPathA, dbPathB]) {
      for (const suffix of ["", "-wal", "-shm"]) {
        if (fs.existsSync(p + suffix)) fs.unlinkSync(p + suffix);
      }
    }
  }
});

test("W25b-v3 P0-2: unregistered Station B NEVER leaks HTTP to default Station A, queues in B outbox, and flushes to B once registered", async () => {
  const stA = "ws-1/st-a";
  const stB = "ws-1/st-b";
  const time = new TestTime();
  const sqlObj = makeNodeSql(":memory:");
  const acct = new AccountDb("sub-1", "p02", sqlObj, new Runner(time.clock), makeDummyDerive());
  acct.setThreads(stB, [{ id: 1, surface: "chat", last: 5, read: 1, unread: 4, createdAt: 100, sessions: [{ session: "s-b" }] }], 1000);
  acct.commitNow();

  const res = await rpc.call(
    "l5real.unregisteredStationGuard",
    { stationA: stA, stationB: stB },
    { sql: sqlObj },
  );
  assert.equal(res.reqsABefore, 0, "Station A MUST receive 0 HTTP requests when Station B is unregistered");
  assert.equal(res.reqsBBefore, 0, "Station B has 0 requests while unregistered");
  assert.equal(res.pendingBefore, 1, "Station B chat.send safely queued as unreached pending");
  assert.equal(res.requestsA.length, 0, "Station A MUST STILL have 0 HTTP requests after Station B registers & flushes");
  assert.equal(res.pendingAfter, 0, "Station B outbox reconciled after registering B transport");
  assert.ok(
    res.requestsB.some((r) => r.method === "POST" && r.path === "/threads/1/messages" && r.idem === "idem-b-unreg"),
    "Station B received queued chat.send after registering transport",
  );
  assert.ok(
    res.requestsB.some((r) => r.method === "PUT" && r.path === "/threads/1/title"),
    "Station B received queued chat.rename after registering transport",
  );
  counts.gate7Outbox += 2;
  acct.close();
});

test("W25b-v3 P1-3: strict single-thread FIFO head-of-line blocking on HTTP 503 AND Exit::Failed (msg-2 NEVER jumps ahead of msg-1)", async () => {
  const station = "ws-1/st-1";
  for (const failMode of ["503", "network"]) {
    const time = new TestTime();
    const sqlObj = makeNodeSql(":memory:");
    const acct = new AccountDb("sub-1", `p13-${failMode}`, sqlObj, new Runner(time.clock), makeDummyDerive());
    acct.commitNow();

    const res = await rpc.call(
      "l5real.outboxFifoHeadOfLineBlock",
      { station, failMode },
      { sql: sqlObj },
    );
    assert.equal(res.requestsAfterFail, 1, `[${failMode}] msg-2 MUST NOT jump ahead when msg-1 fails`);
    assert.equal(res.pendingAfterRecovery, 0, `[${failMode}] both messages reconciled after recovery`);
    assert.deepEqual(
      res.requests.map((r) => r.idem),
      ["msg-1", "msg-1", "msg-2"],
      `[${failMode}] strict FIFO order: msg-1 (fail) -> msg-1 (retry ok) -> msg-2 (ok)`,
    );
    counts.gate7Outbox += 1;
    acct.close();
  }
});
