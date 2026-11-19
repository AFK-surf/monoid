// The MoonBit program opens the station's database as Store.open does (station/mb src/store_schema, reader
// `--builder harness-store-schema`): the same tables, views, indexes and triggers, byte for byte, from a new file and
// from databases of before (the Rust station's version 12, an older 13 with large tables and lookups half there), the
// same rows they start with, and the same rows their triggers keep as the same writes are made on each.
import assert from "node:assert/strict";
import { cpSync, existsSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { liveClock } from "../src/ops/fibers.ts";
import { MbProcess } from "../src/read/mb-reader.ts";
import { mbHarnessBinary } from "./mb-harness.ts";
import { writeCompressed } from "../src/store/archive.ts";
import { installCardOutbox, saveWithCardOutcome } from "../src/store/card-outbox.ts";
import { repairMergedEditLookup } from "../src/store/schema.ts";
import { Store } from "../src/store/store.ts";
import { installCompactUsage } from "../src/store/usage-compact.ts";
import { stopUsageIndexes, usageIndexesLeft } from "../src/store/usage-retire.ts";

const binary = mbHarnessBinary();
const NOW = 1_800_000_000_000;
const clock = { ...liveClock, currentTimeMillisUnsafe: () => NOW };
const root = mkdtempSync(join(tmpdir(), "mb-store-schema-"));
after(() => rmSync(root, { recursive: true, force: true }));
let made = 0;

/// A directory of its own for one database.
function place(name: string): { dir: string; path: string } {
  const dir = join(root, `${name}-${made++}`);
  mkdirSync(dir, { recursive: true });
  return { dir, path: join(dir, "stillfail.db") };
}

/// The program's answer to each ask, on a database of its own.
async function asked(path: string, asks: object[]): Promise<Record<string, unknown>[]> {
  const program = new MbProcess(binary!, ["--builder", "harness-store-schema", "--db", path]);
  try {
    const answers: Record<string, unknown>[] = [];
    for (const ask of asks) {
      const answered = new Promise<Record<string, unknown>>((resolve) => program.once("message", resolve));
      program.postMessage(ask);
      answers.push(await answered);
    }
    return answers;
  } finally {
    await program.terminate();
  }
}

/// What usage/module.ts does as the station opens once the station before has gone.
function retire(db: DatabaseSync): boolean {
  installCompactUsage(db);
  stopUsageIndexes(db);
  return usageIndexesLeft(db);
}

/// The station's opening in TypeScript: Store.open, then the usage module's retirement.
function openTs(path: string, archive: string | null = null): { left: boolean } {
  const store = Store.open(path, archive, clock);
  try {
    return { left: retire(store.db) };
  } finally {
    store.close();
  }
}

/// The same by the MoonBit program.
async function openMb(path: string, archive?: string): Promise<{ left: boolean }> {
  const [opened, compact, stop, left] = await asked(path, [
    archive === undefined ? { op: "open", now: NOW } : { op: "open", now: NOW, archive },
    { op: "compact" }, { op: "stop" }, { op: "left" },
  ]);
  for (const a of [opened, compact, stop, left]) assert.deepEqual(a!.done, true, JSON.stringify(a));
  return { left: left!.left as boolean };
}

const text = (v: unknown) => JSON.stringify(v, (_, x) => (typeof x === "bigint" ? `${x}n` : x));

/// The schema: every table, index, trigger and view, by its definition as written, and the version.
function schemaOf(path: string): string[] {
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    const rows = db.prepare("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").all() as
      { type: string; name: string; tbl_name: string; sql: string | null }[];
    return [
      ...rows.map((r) => `${r.type} ${r.name} on ${r.tbl_name}\n${r.sql ?? "(automatic)"}`),
      `user_version ${(db.prepare("PRAGMA user_version").get() as { user_version: number }).user_version}`,
      `journal_mode ${(db.prepare("PRAGMA journal_mode").get() as { journal_mode: string }).journal_mode}`,
    ];
  } finally {
    db.close();
  }
}

/// The definitions with their white space made one space each, as the comparison the lead asked for reads them.
const normalized = (schema: string[]) => schema.map((s) => s.replace(/\s+/g, " ").trim());

/// Every row of every table (the archive guard's random epoch shown as what it is), and the merged view's.
function rowsOf(path: string): Record<string, string[]> {
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    const out: Record<string, string[]> = {};
    const tables = db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").all() as { name: string }[];
    const views = db.prepare("SELECT name FROM sqlite_master WHERE type = 'view' AND name = 'merged'").all() as { name: string }[];
    for (const { name } of [...tables, ...views]) {
      const statement = db.prepare(`SELECT * FROM "${name}"`);
      statement.setReadBigInts(true);
      const rows = (statement.all() as Record<string, unknown>[]).map((r) => {
        if (name === "archive_last_meta") {
          assert.match(String(r.epoch), /^[0-9a-f]{32}$/);
          r.epoch = "<random epoch>";
        }
        return text(r);
      });
      out[name] = rows.sort();
    }
    return out;
  } finally {
    db.close();
  }
}

/// The two databases alike: schema, byte for byte and as normalized, and every row.
function same(ts: string, mb: string, what: string): void {
  const a = schemaOf(ts), b = schemaOf(mb);
  assert.deepEqual(normalized(b), normalized(a), `${what}: the schema, white space normalized`);
  assert.deepEqual(b, a, `${what}: the schema as written`);
  assert.deepEqual(rowsOf(mb), rowsOf(ts), `${what}: the rows`);
}

/// One database made twice, for each side its own copy of the same file (and its archive).
function twins(name: string, make: (path: string, dir: string) => void): { ts: { dir: string; path: string }; mb: { dir: string; path: string } } {
  const ts = place(`${name}-ts`), mb = place(`${name}-mb`);
  make(ts.path, ts.dir);
  for (const f of ["stillfail.db", "stillfail.db-wal", "stillfail.db-shm"]) {
    if (existsSync(join(ts.dir, f))) cpSync(join(ts.dir, f), join(mb.dir, f));
  }
  if (existsSync(join(ts.dir, "archive"))) cpSync(join(ts.dir, "archive"), join(mb.dir, "archive"), { recursive: true });
  return { ts, mb };
}

/// The same writes on a database, each kind of row the kept tables follow: sessions, chats and their members,
/// messages, edits, cards and letters, deliveries, turns, jobs, calls, tasks of other stations, bindings and marks,
/// decisions, and their replacements and removals; the per-chat lookups asked for first, as a reader asks them.
function writes(path: string): void {
  const db = new DatabaseSync(path);
  try {
    const run = (sql: string, ...args: (string | number | null)[]) => db.prepare(sql).run(...args);
    const has = (name: string) => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(name) !== undefined;
    for (let s = 0; s < 6; s++) {
      run(`INSERT INTO sessions (key, connect, scope, runtime, profile, workspace, token, created_at, last_active_at, ws, created_by, model)
        VALUES (?, ?, 'chat', 'claude', 'p', '/w', ?, ?, ?, ?, 'alice', 'm')`, `w-s${s}`, `c${s % 2}`, `w-t${s}`, 1000 + s, 2000 + s, s % 3 === 0 ? null : `ws${s % 2}`);
    }
    for (let t = 0; t < 4; t++) {
      run("INSERT INTO threads (surface, channel, thread_ts, created_at, home) VALUES (?, ?, ?, ?, ?)",
        t % 2 ? "ember" : "slack:T1", `wch${t}`, `wts${t}`, 3000 + t, t % 2 ? `w-s${t}` : null);
    }
    const threads = (db.prepare("SELECT id FROM threads WHERE channel LIKE 'wch%' ORDER BY id").all() as { id: number }[]).map((r) => r.id);
    // the requested lookups' scopes, as the readers ask them
    for (const thread of threads.slice(0, 2)) {
      for (const [table, sql] of [
        ["widget_source_scopes", "INSERT OR IGNORE INTO widget_source_scopes VALUES (?, NULL, NULL, 1)"],
        ["card_post_scopes", "INSERT OR IGNORE INTO card_post_scopes VALUES (?, NULL, NULL, 2)"],
        ["legacy_people_time_scopes", "INSERT OR IGNORE INTO legacy_people_time_scopes VALUES (?, NULL, NULL, 1)"],
        ["legacy_closed_scopes", "INSERT OR IGNORE INTO legacy_closed_scopes VALUES (?, NULL, NULL, 1)"],
        ["post_blocks_coverage", "INSERT OR IGNORE INTO post_blocks_coverage VALUES (?, NULL, 1)"],
      ] as const) if (has(table)) run(sql, thread);
    }
    for (const session of ["w-s1", "w-s2"]) {
      if (has("cc_sessions")) run("INSERT OR IGNORE INTO cc_sessions VALUES (?, NULL, NULL, 1)", session);
      if (has("latest_thread_scopes")) run("INSERT OR IGNORE INTO latest_thread_scopes VALUES (?, NULL, NULL, 1)", session);
      if (has("session_chat_scopes")) run("INSERT OR IGNORE INTO session_chat_scopes VALUES (?, NULL, NULL, 1)", session);
    }
    for (const [i, thread] of threads.entries()) {
      run("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, 'c0', ?)", thread, `w-s${i}`, 4000 + i);
      run("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, 'c1', ?)", thread, `w-s${(i + 1) % 6}`, 4100 + i);
    }
    const options = JSON.stringify([{ label: " Yes " }, { label: "No" }]);
    const login = JSON.stringify({ type: "login", login: "github", text: "sign in" });
    const vault = JSON.stringify({ type: "text", vault: { name: "k" } });
    const attachments = JSON.stringify([{ name: "a.png", path: "/w/a.png", size: 3 }, { name: "b", path: "/w/b.html", size: 1 }]);
    for (const [i, thread] of threads.entries()) {
      const e = (n: number, kind: string, author_kind: string, author: string, extra: Record<string, string | number | null> = {}) => {
        const cols = { thread, n, kind, author_kind, author, at: 5000 + n * 10 + i, ts: `m${thread}.${n}`, text: `said ${n}`, ...extra };
        run(`INSERT INTO entries (${Object.keys(cols).join(", ")}) VALUES (${Object.keys(cols).map(() => "?").join(", ")})`, ...Object.values(cols));
      };
      e(1, "message", "person", "alice");
      e(2, "message", "agent", `w-s${i}`, { options, card: JSON.stringify({ type: "options", options: JSON.parse(options) }) });
      e(3, "message", "agent", `w-s${i}`, { card: login });
      e(4, "message", "person", "bob", { text: " Yes " });
      e(5, "message", "agent", `w-s${i}`, { card: vault, attachments });
      e(6, "edit", "agent", `w-s${i}`, { target: 5, attachments: JSON.stringify([{ name: "c", path: "/w/b.html", size: 2 }]) });
      e(7, "message", "agent", "other", { letter: JSON.stringify({ way: "in", title: "x", link: null }) });
      e(8, "message", "person", "alice", { text: "No" });
      run("INSERT INTO deliveries (thread, n, session, delivered_at) VALUES (?, 1, ?, NULL)", thread, `w-s${i}`);
      run("INSERT INTO deliveries (thread, n, session, delivered_at) VALUES (?, 4, ?, 7000)", thread, `w-s${i}`);
      run("INSERT INTO deliveries (thread, n, session, delivered_at) VALUES (?, 8, ?, NULL)", thread, `w-s${(i + 1) % 6}`);
      run("INSERT INTO closed_cards (thread, n, viewer, at) VALUES (?, 3, 'bob', 7100)", thread);
      if (has("letter_deliveries")) run("INSERT INTO letters VALUES (?, 1, 'l1', 'agent', 'x', 'hi', NULL, 7200, '{}')", thread);
      if (has("letter_deliveries")) run("INSERT INTO letter_deliveries VALUES (?, 1, ?, NULL)", thread, `w-s${i}`);
    }
    // replacements and removals: by ts, by key, a delete; an edit that changes the latest files
    run("INSERT OR REPLACE INTO entries (thread, n, kind, author_kind, author, at, ts, text) VALUES (?, 9, 'message', 'person', 'carol', 9000, ?, 'again')", threads[0]!, `m${threads[0]}.4`);
    run("INSERT OR IGNORE INTO entries (thread, n, kind, author_kind, author, at, ts, text) VALUES (?, 1, 'message', 'person', 'dave', 9001, 'x', 'ignored')", threads[1]!);
    run("UPDATE entries SET text = 'changed', at = 9100 WHERE thread = ? AND n = 2", threads[1]!);
    run("UPDATE entries SET attachments = ? WHERE thread = ? AND n = 6", attachments, threads[0]!);
    run("DELETE FROM entries WHERE thread = ? AND n = 7", threads[2]!);
    run("UPDATE deliveries SET delivered_at = 9200 WHERE session = 'w-s0'");
    run("DELETE FROM deliveries WHERE thread = ? AND n = 8", threads[3]!);
    run("UPDATE thread_sessions SET joined_at = 9300 WHERE thread = ? AND session = 'w-s1'", threads[1]!);
    run("DELETE FROM thread_sessions WHERE thread = ? AND session = 'w-s3'", threads[3]!);
    run("UPDATE threads SET hidden_at = 9400, hidden_by = 'manual' WHERE id = ?", threads[2]!);
    // turns: a wait, a rate limit, one moved and one gone
    const turn = (id: string, session: string, started: number, ended: number | null, declared: string | null, outcome: string | null, detail: string | null, wait: number | null) =>
      run("INSERT INTO turns (id, session_key, kind, started_at, ended_at, declared, outcome, detail, wait_seconds) VALUES (?, ?, 'turn', ?, ?, ?, ?, ?, ?)", id, session, started, ended, declared, outcome, detail, wait);
    turn("t1", "w-s1", 100, 200, "waiting", "ended", null, 60);
    turn("t2", "w-s2", 110, 300, null, "failed", "rate_limit: soon", null);
    turn("t3", "w-s2", 120, null, null, null, null, null);
    turn("t4", "w-s4", 130, 330, "waiting", "ended", null, null);
    run("UPDATE turns SET ended_at = 400, declared = 'all_done' WHERE id = 't3'");
    run("UPDATE turns SET session_key = 'w-s5' WHERE id = 't4'");
    run("DELETE FROM turns WHERE id = 't1'");
    run("UPDATE sessions SET running = 1 WHERE key = 'w-s4'");
    run("UPDATE sessions SET ws = 'ws9' WHERE key = 'w-s2'");
    run("UPDATE sessions SET archived_at = 9500, archived_by = 'manual' WHERE key = 'w-s5'");
    run(`INSERT OR REPLACE INTO sessions (key, connect, scope, runtime, profile, workspace, token, created_at, last_active_at, ws)
      VALUES ('w-s6', 'c0', 'chat', 'codex', 'p', '/w', 'w-t1', 1, 2, 'ws1')`);
    run("DELETE FROM sessions WHERE key = 'w-s3'");
    // jobs: watches, others, a service, a remote task, a token replaced
    const job = (id: string, session: string, state: string, watch: number, port: number | null, token: string) =>
      run(`INSERT INTO jobs (id, session_key, name, command, cwd, port, token, state, started_at, log, watch)
        VALUES (?, ?, 'j', 'c', '/', ?, ?, ?, ?, 'l', ?)`, id, session, port, token, state, 100 + id.length, watch);
    job("j1", "w-s0", "running", 1, null, "wk1");
    job("j2", "w-s0", "running", 0, null, "wk2");
    job("j3", "w-s1", "running", 0, 8080, "wk3");
    job("remote_1", "remote:wsx:st:s1", "running", 0, null, "wk4");
    job("j5", "w-s2", "exited", 0, 9090, "wk5");
    run("UPDATE jobs SET state = 'exited' WHERE id = 'j2'");
    run("UPDATE jobs SET watch = 1 WHERE id = 'j3'");
    run(`INSERT OR REPLACE INTO jobs (id, session_key, name, command, cwd, token, state, started_at, log, watch)
      VALUES ('j6', 'w-s4', 'j', 'c', '/', 'wk1', 'running', 7, 'l', 0)`);
    run("DELETE FROM jobs WHERE id = 'remote_1'");
    // calls: main and subagent, compactions, grown, moved, replaced and gone
    const call = (id: string, session: string, at: number, context: number | null, subagent = 0) =>
      run(`INSERT INTO usage (id, at, session, thread, person, profile, runtime, model, subagent, input, cache_read, cache_write, cache_write_long, output, calls, context)
        VALUES (?, ?, ?, ?, 'alice', 'p', 'claude', 'opus', ?, 10, 20, 30, 40, 50, 1, ?)`, id, at, session, threads[0]!, subagent, context);
    call("u1", "w-s0", NOW - 1000, 90_000);
    call("u2", "w-s0", NOW - 900, 10_000);
    call("u3", "w-s0", NOW - 800, 12_000, 1);
    call("u4", "w-s1", NOW + 5_000_000, null);
    run("UPDATE usage SET output = 500 WHERE id = 'u2'");
    run("UPDATE usage SET at = ? WHERE id = 'u4'", NOW - 100_000_000);
    run(`INSERT OR REPLACE INTO usage (id, at, session, runtime, input, cache_read, cache_write, cache_write_long, output)
      VALUES ('u1', ?, 'w-s1', 'codex', 1, 1, 1, 1, 1)`, NOW - 700);
    run("DELETE FROM usage WHERE id = 'u3'");
    // tasks other stations' chats ran here, bindings, marks, decisions, a workspace's archive policy
    run("INSERT INTO remote_runs VALUES ('r1', 10, 'remote:wa:st:s1')");
    run("INSERT INTO remote_runs VALUES ('r2', 20, 'remote:wb:st:s2')");
    run("INSERT OR REPLACE INTO remote_runs VALUES ('r1', 30, 'remote:wa:st:s1')");
    run("DELETE FROM remote_runs WHERE job = 'r2'");
    run("INSERT INTO bindings VALUES ('cx', 'w-s0')");
    run("INSERT OR REPLACE INTO bindings VALUES ('cx', 'w-s1')");
    run("INSERT INTO pins VALUES ('alice', 'w-s0', 1)");
    run("INSERT INTO kept_chats VALUES ('alice', ?)", threads[0]!);
    run("DELETE FROM pins WHERE viewer = 'alice'");
    run("INSERT INTO decision_checks (session, created_at, result) VALUES ('w-s0', 1, 'ok')");
    run("INSERT INTO archive_policy (at, policy, author, summary, ws) VALUES (1, '{}', 'a', 's', 'ws1')");
    run("DELETE FROM threads WHERE id = ?", threads[3]!);
  } finally {
    db.close();
  }
}

test("a new database: the same schema and the same first rows", { skip: binary === null && "the tests' MoonBit program (stillfail-reader-harness) is not built" }, async () => {
  const ts = place("new-ts"), mb = place("new-mb");
  const a = openTs(ts.path), b = await openMb(mb.path);
  assert.deepEqual(b, a);
  same(ts.path, mb.path, "a new database");
  // opened again: nothing changes on either side
  openTs(ts.path);
  await openMb(mb.path);
  same(ts.path, mb.path, "a new database opened again");
  // what the triggers keep, as the same writes are made on each
  writes(ts.path);
  writes(mb.path);
  same(ts.path, mb.path, "a new database after the same writes");
});

/// A database of the Rust station (version 12): the tables of then, without the columns that came after, with chats it
/// archived to files (one file lost), calls from before the statistics, many messages, decisions, closed cards and
/// archive policies, and the tables only the Rust station used.
function rust12(path: string, dir: string): void {
  const db = new DatabaseSync(path);
  try {
    db.exec(`
      CREATE TABLE sessions (key TEXT PRIMARY KEY, connect TEXT NOT NULL, scope TEXT NOT NULL, title TEXT, created_by TEXT,
        runtime TEXT NOT NULL, profile TEXT NOT NULL, profile_pinned INTEGER NOT NULL DEFAULT 0, model TEXT, effort TEXT,
        runtime_session_id TEXT, workspace TEXT NOT NULL, token TEXT NOT NULL UNIQUE, running INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL, last_active_at INTEGER NOT NULL, archived_at INTEGER);
      CREATE TABLE threads (id INTEGER PRIMARY KEY AUTOINCREMENT, surface TEXT NOT NULL, channel TEXT NOT NULL,
        thread_ts TEXT NOT NULL, title TEXT, created_by TEXT, created_at INTEGER NOT NULL, archived_at INTEGER,
        UNIQUE (surface, channel, thread_ts));
      CREATE TABLE thread_sessions (thread INTEGER NOT NULL, session TEXT NOT NULL, connect TEXT NOT NULL,
        joined_at INTEGER NOT NULL, PRIMARY KEY (thread, session));
      CREATE TABLE entries (thread INTEGER NOT NULL, n INTEGER NOT NULL, kind TEXT NOT NULL, target INTEGER, ts TEXT,
        author_kind TEXT NOT NULL, author TEXT NOT NULL, text TEXT, attachments TEXT, quotes TEXT, declared TEXT,
        at INTEGER NOT NULL, PRIMARY KEY (thread, n));
      CREATE INDEX entries_target ON entries (thread, target);
      CREATE TABLE turns (id TEXT PRIMARY KEY, session_key TEXT NOT NULL, kind TEXT NOT NULL, started_at INTEGER NOT NULL,
        ended_at INTEGER, outcome TEXT, detail TEXT, declared TEXT);
      CREATE TABLE jobs (id TEXT PRIMARY KEY, session_key TEXT NOT NULL, name TEXT NOT NULL, command TEXT NOT NULL,
        cwd TEXT NOT NULL, port INTEGER, token TEXT NOT NULL UNIQUE, state TEXT NOT NULL, pgid INTEGER, exit_code INTEGER,
        started_at INTEGER NOT NULL, ended_at INTEGER, restarts INTEGER NOT NULL DEFAULT 0, log TEXT NOT NULL);
      CREATE TABLE usage (id TEXT PRIMARY KEY, at INTEGER NOT NULL, session TEXT NOT NULL, turn TEXT, thread INTEGER,
        person TEXT, profile TEXT, runtime TEXT NOT NULL, model TEXT, subagent INTEGER NOT NULL DEFAULT 0,
        fast INTEGER NOT NULL DEFAULT 0, input INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
        cache_write_long INTEGER NOT NULL, output INTEGER NOT NULL);
      CREATE TABLE runtime_sessions (session_key TEXT NOT NULL, id TEXT NOT NULL, profile TEXT, at INTEGER NOT NULL,
        PRIMARY KEY (session_key, id));
      CREATE TABLE opened_chats (child_station TEXT NOT NULL, child TEXT NOT NULL, parent_station TEXT NOT NULL,
        parent TEXT NOT NULL, key TEXT NOT NULL, title TEXT, link TEXT, state TEXT, created_at INTEGER NOT NULL,
        PRIMARY KEY (child_station, child));
      CREATE TABLE archive_policy (id INTEGER PRIMARY KEY, at INTEGER NOT NULL, policy TEXT NOT NULL, author TEXT NOT NULL,
        summary TEXT NOT NULL);
      CREATE TABLE items (id TEXT PRIMARY KEY, body TEXT);
      CREATE INDEX threads_archived ON threads (archived_at);
      -- (a decision statistic of an archived chat: an opening of this station's that stopped before it was brought up)
      CREATE TABLE card_outcomes (thread INTEGER NOT NULL, n INTEGER NOT NULL, author TEXT NOT NULL, labels TEXT NOT NULL,
        answered INTEGER NOT NULL, said INTEGER NOT NULL, PRIMARY KEY (thread, n)) WITHOUT ROWID;
      INSERT INTO card_outcomes VALUES (10, 1, 's10', '["A"]', 0, 0);
      PRAGMA user_version = 12;
    `);
    const run = (sql: string, ...args: (string | number | null)[]) => db.prepare(sql).run(...args);
    for (let s = 0; s < 70; s++) {
      run(`INSERT INTO sessions (key, connect, scope, runtime, profile, workspace, token, created_at, last_active_at, archived_at, created_by, model, effort)
        VALUES (?, 'c', 'chat', 'claude', 'p', '/w', ?, ?, ?, ?, 'alice', 'opus', 'high')`, `s${s}`, `t${s}`, s, s + 1, s % 9 === 0 ? 50 : null);
      run("INSERT INTO runtime_sessions VALUES (?, ?, 'p', ?)", `s${s}`, `r${s}`, s);
    }
    for (let t = 1; t <= 12; t++) {
      run("INSERT INTO threads (id, surface, channel, thread_ts, created_at, archived_at) VALUES (?, ?, ?, ?, ?, ?)",
        t, t % 2 ? "ember" : "slack:T1", `ch${t}`, `ts${t}`, t, t >= 10 ? 99 : null);
      run("INSERT INTO thread_sessions VALUES (?, ?, 'c', ?)", t, `s${t}`, t);
      if (t % 3 === 0) run("INSERT INTO thread_sessions VALUES (?, ?, 'c', ?)", t, `s${t + 20}`, t + 1);
    }
    // many messages: the lookups are prepared, not indexed, on a store this large
    for (let t = 1; t <= 9; t++) {
      for (let n = 1; n <= 12; n++) {
        const agent = n % 2 === 0;
        run("INSERT INTO entries (thread, n, kind, target, ts, author_kind, author, text, attachments, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          t, n, n === 11 ? "edit" : "message", n === 11 ? 10 : null, `e${t}.${n}`, agent ? "agent" : "person",
          n === 6 || n === 8 ? `stranger${t}` : agent ? `s${t}` : "alice",
          n === 6 ? `来自 [chat ${t}](https://x/${t})：hello` : n === 8 ? `From <https://y/${t}|other ${t}>:\nbody` : `text ${n}`,
          n === 4 ? JSON.stringify([{ name: "a", path: "/a", size: 1 }]) : null, 100 * t + n);
      }
    }
    for (let i = 0; i < 70; i++) {
      run("INSERT INTO usage (id, at, session, runtime, model, input, cache_read, cache_write, cache_write_long, output, thread) VALUES (?, ?, ?, 'claude', 'opus', 1, 2, 3, 4, 5, 1)",
        `ru${i}`, NOW - 10_000_000 + i * 1000, `s${i % 5}`);
    }
    run("INSERT INTO usage (id, at, session, runtime, input, cache_read, cache_write, cache_write_long, output) VALUES ('ahead', ?, 's1', 'claude', 1, 1, 1, 1, 1)", NOW + 3_600_000);
    for (let i = 0; i < 66; i++) {
      run("INSERT INTO jobs (id, session_key, name, command, cwd, token, state, started_at, log) VALUES (?, ?, 'j', 'c', '/', ?, ?, ?, 'l')",
        `rj${i}`, `s${i % 4}`, `k${i}`, i < 3 ? "running" : "exited", i);
      run("INSERT INTO archive_policy (id, at, policy, author, summary) VALUES (?, ?, '{}', 'a', 's')", i + 1, i);
    }
    run("INSERT INTO opened_chats VALUES ('', 's1', '', 's2', 'k', 'title', NULL, NULL, 1)");
    run("INSERT INTO items VALUES ('i', 'b')");
  } finally {
    db.close();
  }
  // the chats the Rust station archived to files: 10 with old option cards and a person's answer, 11 with a letter
  // and a change, 12's file lost with its disk
  const line = (v: Record<string, unknown>) => JSON.stringify(v);
  writeCompressed(join(dir, "archive", "threads", "10.jsonl.zst"), [
    line({ thread: 10, n: 1, kind: "message", target: null, ts: "a1", authorKind: "person", author: "alice", text: "hi", attachments: [], quotes: [], declared: null, at: 1 }),
    line({ thread: 10, n: 2, kind: "message", target: null, ts: "a2", authorKind: "agent", author: "s10", text: "pick", attachments: [{ name: "f", path: "/f", size: 9, width: 2, height: 3, extra: 1 }], quotes: [], declared: null, options: [{ label: "A" }, { label: " B " }], at: 2 }),
    line({ thread: 10, n: 3, kind: "message", target: null, ts: "a3", authorKind: "person", author: "bob", text: " B ", attachments: [], quotes: [{ author: "s10", text: "pick", comment: "c", ts: "a2" }], declared: null, client: "web", at: 3 }),
    line({ thread: 10, n: 4, kind: "edit", target: 2, ts: null, authorKind: "agent", author: "s10", text: "picked", attachments: [], quotes: [], declared: null, at: 4 }),
  ].join("\n") + "\n");
  writeCompressed(join(dir, "archive", "threads", "11.jsonl.zst"), [
    line({ agentIdentity: { name: "bot" }, thread: 11, n: 1, kind: "message", target: null, ts: "b1", authorKind: "stillfail", author: "station", text: "notice", attachments: [], quotes: [], declared: "x", profile: "p", runtime: "codex", card: { type: "login", login: "gh" }, at: 5, letter: { way: "out", title: "t", link: "l" }, change: { was: { a: 1 }, now: { a: 2 } } }),
    line({ thread: 11, n: 2, kind: "message", target: null, ts: "b2", authorKind: "person", author: "carol", text: "ok", attachments: [], quotes: [], declared: null, at: 6, letter: "{\"way\":\"in\",\"title\":\"q\"}" }),
  ].join("\r\n"));
}

test("a database of the Rust station (version 12): brought up the same", { skip: binary === null && "the tests' MoonBit program (stillfail-reader-harness) is not built" }, async () => {
  const { ts, mb } = twins("rust12", rust12);
  const a = openTs(ts.path), b = await openMb(mb.path);
  assert.deepEqual(b, a);
  // the archived chats are back in on both sides, their files taken away
  for (const side of [ts, mb]) {
    assert.equal(existsSync(join(side.dir, "archive", "threads", "10.jsonl.zst")), false);
    assert.equal(existsSync(join(side.dir, "archive", "threads", "11.jsonl.zst")), false);
  }
  same(ts.path, mb.path, "version 12 brought up");
  writes(ts.path);
  writes(mb.path);
  same(ts.path, mb.path, "version 12 brought up, after the same writes");
});

/// What a station from before had already of what came after it (`older13`): the lists' state with its said guard and
/// no said index (so the said lookup is prepared, and the state's writers made anew over it), the decisions' time index
/// (so their session lookup is prepared apart), the decision statistics, the first call, the main calls' compactions, the
/// archive guard, the widgets' sources, the waits to take up (from before their expiries) and the sessions' totals (with
/// their writer of before, which names no columns).
const PARTLY = ["thread_state", "thread_people", "session_first", "said_state_guard", "card_outcomes", "usage_span",
  "usage_main_calls", "usage_compaction_events", "usage_compaction_backfill", "usage_compactions", "archive_last_meta",
  "archive_last_guard", "widget_source_meta", "widget_source_scopes", "widget_source_rows", "widget_source_invalid",
  "widget_source_changed", "session_recover_waits", "session_recover_turn_stage", "session_recover_session_stage",
  "session_recover_wait_meta", "decision_checks_lately", "usage_totals"];

/// A database of an older 13: opened by this station, then what came after taken away as a station from before never
/// had it (the statistics, the kept states, the lookups, the columns' triggers), over many rows of each kind; `partly`:
/// with what PARTLY names kept.
function older13(path: string, partly = false): void {
  Store.open(path, null, clock).close();
  const db = new DatabaseSync(path);
  try {
    const run = (sql: string, ...args: (string | number | null)[]) => db.prepare(sql).run(...args);
    db.exec("BEGIN");
    for (let s = 0; s < 80; s++) {
      run(`INSERT INTO sessions (key, connect, scope, runtime, profile, workspace, token, created_at, last_active_at, ws, running)
        VALUES (?, 'c', 'chat', 'claude', 'p', '/w', ?, ?, ?, ?, ?)`, `o${s}`, `ot${s}`, s, s, s % 2 ? "wsA" : null, s % 7 === 0 ? 1 : 0);
      run("INSERT INTO bindings VALUES (?, ?)", `b${s}`, `o${s}`);
      run("INSERT INTO pins VALUES ('alice', ?, ?)", `o${s}`, s);
      run("INSERT INTO decision_checks (session, created_at, result) VALUES (?, ?, 'r')", `o${s % 9}`, s);
      run("INSERT INTO archive_policy (at, policy, author, summary, ws) VALUES (?, '{}', 'a', 's', ?)", s, s % 3 ? "wsA" : null);
      run("INSERT INTO turns (id, session_key, kind, started_at, ended_at, declared) VALUES (?, ?, 'turn', ?, ?, ?)", `tt${s}`, `o${s % 10}`, s, s + 5, s % 4 ? null : "waiting");
      run("INSERT INTO jobs (id, session_key, name, command, cwd, token, state, started_at, log, watch, port) VALUES (?, ?, 'j', 'c', '/', ?, 'running', ?, 'l', ?, ?)",
        s % 11 === 0 ? `remote_${s}` : `jj${s}`, `o${s % 6}`, `jt${s}`, s, s % 2, s % 5 === 0 ? 3000 + s : null);
      run("INSERT INTO remote_runs VALUES (?, ?, ?)", `rr${s}`, s, `remote:w${s % 3}:st:x`);
      run("INSERT INTO usage (id, at, session, runtime, model, input, cache_read, cache_write, cache_write_long, output, calls) VALUES (?, ?, ?, 'claude', 'opus', 1, 1, 1, 1, 1, 1)",
        `ou${s}`, NOW - s * 1000, `o${s % 4}`);
    }
    for (let t = 1; t <= 8; t++) {
      run("INSERT INTO threads (surface, channel, thread_ts, created_at) VALUES ('ember', ?, ?, ?)", `oc${t}`, `ot${t}`, t);
      run("INSERT INTO kept_chats VALUES ('alice', ?)", t);
      for (let n = 1; n <= 10; n++) {
        run("INSERT INTO entries (thread, n, kind, ts, author_kind, author, text, at, options) VALUES (?, ?, 'message', ?, ?, ?, 'x', ?, ?)",
          t, n, `o${t}.${n}`, n % 2 ? "person" : "agent", n % 2 ? "alice" : `o${t}`, t * 100 + n, n === 4 ? "[{\"label\":\"x\"}]" : null);
        run("INSERT INTO closed_cards VALUES (?, ?, 'v', ?)", t, n, n);
      }
      run("INSERT INTO deliveries VALUES (?, 1, ?, NULL)", t, `o${t}`);
    }
    db.exec("COMMIT");
    // what a station from before did not have
    const drop = (type: string, where: string) => {
      for (const { name } of db.prepare(`SELECT name FROM sqlite_master WHERE type = '${type}' AND (${where})`).all() as { name: string }[]) {
        if (!partly || !PARTLY.includes(name)) db.exec(`DROP ${type.toUpperCase()} "${name}"`);
      }
    };
    if (partly) db.exec("DROP INDEX entries_said");
    drop("trigger", "1");
    drop("view", "1");
    drop("index", `name IN ('entries_edits', 'entries_said', 'entries_agent_at', 'entries_login_cards', 'entries_people_since',
      'closed_cards_thread_at', 'decision_checks_lately', 'decision_checks_session', 'archive_policy_by_ws', 'sessions_efforts',
      'entries_letters', 'active_other_remote_jobs')`);
    drop("table", `name IN ('usage_15m', 'usage_quarter_totals', 'usage_scope_totals', 'usage_15m_meta', 'usage_15m_replace',
      'usage_totals', 'usage_compactions', 'usage_main_calls', 'usage_compaction_events', 'usage_compaction_backfill', 'usage_span',
      'usage_contexts', 'usage_minute_scope', 'card_outcomes', 'thread_state', 'thread_people', 'session_first', 'said_state_guard',
      'letters', 'letter_deliveries', 'session_turns', 'session_turns_guard', 'session_work', 'session_work_from', 'pending_cards',
      'pending_cards_from', 'pending_system_cards', 'active_watch_jobs', 'active_other_jobs', 'active_other_replaced',
      'remote_run_progress', 'remote_run_lookup', 'remote_run_by_time', 'remote_run_by_job', 'remote_run_counts', 'remote_run_total',
      'usage_chat_stats', 'usage_chat_members', 'usage_chat_cards', 'usage_chat_dirty', 'usage_chat_dirty_scope', 'usage_chat_scopes',
      'usage_chat_totals', 'usage_chat_progress', 'post_blocks', 'post_blocks_replaced', 'post_blocks_meta', 'post_blocks_coverage',
      'workspace_activity', 'workspace_activity_replaced', 'workspace_activity_meta', 'session_recover_waits',
      'session_recover_turn_stage', 'session_recover_session_stage', 'session_recover_wait_meta', 'session_awake_deadlines',
      'session_awake_wait_meta', 'session_count_meta', 'session_count_seen', 'session_count_replaced', 'session_count_totals',
      'session_count_groups', 'session_list_meta', 'session_list_rows', 'session_list_replaced', 'session_binding_meta',
      'session_binding_rows', 'session_binding_replaced', 'archive_mark_meta', 'archive_pin_rows', 'archive_keep_rows',
      'archive_pin_replaced', 'archive_keep_replaced', 'session_up_job_meta', 'session_up_job_scopes', 'session_up_job_rows',
      'session_up_job_replaced', 'workspace_up_meta', 'workspace_up_sessions', 'workspace_up_session_replaced', 'job_name_first_meta',
      'job_name_first', 'archive_last_meta', 'archive_last_guard', 'widget_source_meta', 'widget_source_scopes',
      'widget_source_rows', 'widget_source_invalid', 'widget_source_changed', 'cc_index_meta', 'cc_sessions', 'cc_session_rows',
      'cc_session_dirty', 'cc_order_dispatch', 'cc_order_turn', 'session_chat_meta', 'session_chat_scopes', 'session_chat_rows',
      'latest_thread_meta', 'latest_thread_scopes', 'latest_thread_rows', 'latest_thread_members', 'latest_thread_changed',
      'latest_thread_updating', 'latest_thread_change_ids', 'card_post_meta', 'card_post_scopes', 'card_posts', 'card_post_changed',
      'usage_counter')`);
    db.exec("ALTER TABLE usage DROP COLUMN rollup_counted");
    if (partly) {
      // the waits to take up from before their expiries
      db.exec(`CREATE TABLE recover_old AS SELECT session FROM session_recover_waits; DROP TABLE session_recover_waits;
        CREATE TABLE session_recover_waits (session TEXT PRIMARY KEY) WITHOUT ROWID;
        INSERT INTO session_recover_waits SELECT session FROM recover_old; DROP TABLE recover_old;
        CREATE TRIGGER usage_totals_add AFTER INSERT ON usage BEGIN
          INSERT  INTO usage_totals
            VALUES (NEW.session, NEW.runtime, COALESCE(NEW.model, ''), NEW.fast, NEW.calls, NEW.input, NEW.cache_read, NEW.cache_write, NEW.cache_write_long, NEW.output)
          ON CONFLICT (session, runtime, model, fast) DO UPDATE SET calls = calls + excluded.calls;
        END;`);
    } else db.exec("CREATE TABLE usage_compact_since (id INTEGER PRIMARY KEY)");
    // the minute statistics of before, still written by their triggers until the station before has gone
    db.exec(`CREATE TABLE usage_minute (session TEXT, at INTEGER);
      CREATE TRIGGER usage_minute_add AFTER INSERT ON usage BEGIN INSERT INTO usage_minute VALUES (NEW.session, NEW.at); END;
      CREATE TRIGGER usage_summary_x AFTER DELETE ON usage BEGIN DELETE FROM usage_minute WHERE session = OLD.session; END;`);
  } finally {
    db.close();
  }
}

test("an older 13 with large tables: its lookups prepared, its statistics and states installed the same", { skip: binary === null && "the tests' MoonBit program (stillfail-reader-harness) is not built" }, async () => {
  const { ts, mb } = twins("older13", (path) => older13(path));
  const a = openTs(ts.path), b = await openMb(mb.path);
  assert.deepEqual(b, a);
  same(ts.path, mb.path, "an older 13 brought up");
  writes(ts.path);
  writes(mb.path);
  same(ts.path, mb.path, "an older 13 brought up, after the same writes");
});

/// An older store whose prepared lookups, and the merged view over them, were there already: opened again once a
/// station made the native edit index, the view goes back to it; that index taken away again by a station from before,
/// the writer repairs the view onto the prepared lookup the same.
test("an older 13 with part of what came after: its said lookup prepared and the rest made over what is there the same", { skip: binary === null && "the tests' MoonBit program (stillfail-reader-harness) is not built" }, async () => {
  const { ts, mb } = twins("partly", (path) => older13(path, true));
  const a = openTs(ts.path), b = await openMb(mb.path);
  assert.deepEqual(b, a);
  same(ts.path, mb.path, "an older 13 with part of what came after");
  writes(ts.path);
  writes(mb.path);
  same(ts.path, mb.path, "an older 13 with part of what came after, after the same writes");
});

test("the decisions' session lookup whose index went: prepared anew beside it, then emptied first, the same", { skip: binary === null && "the tests' MoonBit program (stillfail-reader-harness) is not built" }, async () => {
  const { ts, mb } = twins("decisions", (path) => older13(path, true));
  openTs(ts.path);
  await openMb(mb.path);
  for (const index of ["legacy_decision_session_by_session", "legacy_decision_session_repair_by_session"]) {
    for (const side of [ts, mb]) {
      const db = new DatabaseSync(side.path);
      try {
        db.exec(`DROP INDEX ${index}`);
      } finally {
        db.close();
      }
    }
    openTs(ts.path);
    await openMb(mb.path);
    same(ts.path, mb.path, `${index} taken away`);
  }
});

test("an older store's prepared lookups kept, and the merged view repaired the same", { skip: binary === null && "the tests' MoonBit program (stillfail-reader-harness) is not built" }, async () => {
  const { ts, mb } = twins("prepared", (path, dir) => {
    rust12(path, dir);
    Store.open(path, null, clock).close();
    const db = new DatabaseSync(path);
    try {
      // the native edit index a station made since
      db.exec("CREATE INDEX entries_edits ON entries (thread, target, n) WHERE target IS NOT NULL");
    } finally {
      db.close();
    }
  });
  openTs(ts.path);
  await openMb(mb.path);
  same(ts.path, mb.path, "opened again");
  for (const side of [ts, mb]) {
    const db = new DatabaseSync(side.path);
    try {
      db.exec("DROP INDEX entries_edits");
    } finally {
      db.close();
    }
  }
  {
    const db = new DatabaseSync(ts.path);
    try {
      repairMergedEditLookup(db);
    } finally {
      db.close();
    }
  }
  const [repaired] = await asked(mb.path, [{ op: "repair" }]);
  assert.deepEqual(repaired, { done: true });
  same(ts.path, mb.path, "the merged view repaired");
});

test("many jobs running at open: the active lookups left to their preparation the same", { skip: binary === null && "the tests' MoonBit program (stillfail-reader-harness) is not built" }, async () => {
  const { ts, mb } = twins("busy", (path) => {
    const db = new DatabaseSync(path);
    try {
      db.exec(`CREATE TABLE sessions (key TEXT PRIMARY KEY, connect TEXT NOT NULL, scope TEXT NOT NULL, title TEXT,
        created_by TEXT, runtime TEXT NOT NULL, profile TEXT NOT NULL, profile_pinned INTEGER NOT NULL DEFAULT 0, model TEXT,
        effort TEXT, runtime_session_id TEXT, workspace TEXT NOT NULL, token TEXT NOT NULL UNIQUE,
        running INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, last_active_at INTEGER NOT NULL, archived_at INTEGER);
        CREATE TABLE jobs (id TEXT PRIMARY KEY, session_key TEXT NOT NULL, name TEXT NOT NULL, command TEXT NOT NULL,
        cwd TEXT NOT NULL, port INTEGER, token TEXT NOT NULL UNIQUE, state TEXT NOT NULL, pgid INTEGER, exit_code INTEGER,
        started_at INTEGER NOT NULL, ended_at INTEGER, restarts INTEGER NOT NULL DEFAULT 0, log TEXT NOT NULL,
        watch INTEGER NOT NULL DEFAULT 0);
        PRAGMA user_version = 13;`);
      const add = db.prepare("INSERT INTO jobs (id, session_key, name, command, cwd, token, state, started_at, log, watch, port) VALUES (?, ?, 'j', 'c', '/', ?, 'running', ?, 'l', ?, ?)");
      for (let i = 0; i < 70; i++) add.run(`b${i}`, `s${i % 3}`, `bt${i}`, i, i % 2, i % 10 === 0 ? 4000 + i : null);
    } finally {
      db.close();
    }
  });
  openTs(ts.path);
  await openMb(mb.path);
  same(ts.path, mb.path, "many jobs running");
});

test("a database of another version is refused the same, and nothing is made in it", { skip: binary === null && "the tests' MoonBit program (stillfail-reader-harness) is not built" }, async () => {
  const { ts, mb } = twins("refused", (path) => {
    const db = new DatabaseSync(path);
    try {
      db.exec("CREATE TABLE sessions (key TEXT PRIMARY KEY); PRAGMA user_version = 11;");
    } finally {
      db.close();
    }
  });
  const refusal = (() => {
    try {
      Store.open(ts.path, null, clock).close();
      return null;
    } catch (e) {
      return (e as Error).message.replace(ts.path, "<path>");
    }
  })();
  assert.match(refusal ?? "", /has schema version 11; this station uses 13/);
  const [answer] = await asked(mb.path, [{ op: "open", now: NOW }]);
  assert.equal(String(answer!.error).replace(mb.path, "<path>"), refusal);
  same(ts.path, mb.path, "refused");
});

test("the card outcomes' queue made, and one from before a rig's card widened, the same", { skip: binary === null && "the tests' MoonBit program (stillfail-reader-harness) is not built" }, async () => {
  const { ts, mb } = twins("outbox", (path) => {
    Store.open(path, null, clock).close();
    const db = new DatabaseSync(path);
    try {
      db.exec(`CREATE TABLE card_outbox_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,next_id INTEGER NOT NULL) WITHOUT ROWID;
        INSERT INTO card_outbox_meta VALUES(1,1,3);
        CREATE TABLE card_outbox(thread INTEGER NOT NULL,ts TEXT NOT NULL,id INTEGER NOT NULL,agent TEXT NOT NULL,
          field TEXT NOT NULL CHECK(field IN ('adb','signin','vault')),close_card INTEGER NOT NULL CHECK(close_card IN (0,1)),
          outcome TEXT NOT NULL,PRIMARY KEY(thread,ts,id)) WITHOUT ROWID;
        INSERT INTO card_outbox VALUES (1, 'a', 2, 's', 'vault', 1, '{}');
        CREATE TABLE card_outbox_head(id INTEGER PRIMARY KEY,thread INTEGER NOT NULL,ts TEXT NOT NULL);`);
    } finally {
      db.close();
    }
  });
  {
    const db = new DatabaseSync(ts.path);
    try {
      saveWithCardOutcome(db, { thread: 1, ts: "a", agent: "s", field: "rig", close: true, outcome: {} }, () => {});
      db.exec("DELETE FROM card_outbox WHERE field = 'rig'; DELETE FROM card_outbox_head; UPDATE card_outbox_meta SET next_id = 3");
    } finally {
      db.close();
    }
  }
  const [widened] = await asked(mb.path, [{ op: "outbox", rig: true }]);
  assert.deepEqual(widened, { done: true });
  same(ts.path, mb.path, "a queue from before widened");
  const fresh = twins("outbox-new", (path) => Store.open(path, null, clock).close());
  {
    const db = new DatabaseSync(fresh.ts.path);
    try {
      installCardOutbox(db);
    } finally {
      db.close();
    }
  }
  const [installed] = await asked(fresh.mb.path, [{ op: "outbox" }]);
  assert.deepEqual(installed, { done: true });
  same(fresh.ts.path, fresh.mb.path, "a new queue");
});
