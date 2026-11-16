// The MoonBit builder of the usage retirement (station/mb, src/usagefill) frees the statistics of before the quarters
// as `dropUsageIndexStep` does and takes the calls from before the quarters in as `fillUsage15mStep` does: the same
// answers and tables, step by step, with calls recorded meanwhile.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { MbProcess, mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";
import { installCompactUsage } from "../src/store/usage-compact.ts";
import { dropUsageIndexStep, fillUsage15mStep, stopUsageIndexes } from "./reference/backfill/usage-retire.ts";
import type { UsageCall, UsageFor } from "../src/store/usage.ts";

const binary = mbReaderBinary();
const HOUR = 3_600_000;
const of: UsageFor = { turn: null, person: "p", thread: null, profile: "cc" };
const call = (id: string, at: number, input: number): UsageCall => ({ id, at, model: "m", subagent: false, fast: false,
  input, cacheRead: 0, cacheWrite: 0, cacheWriteLong: 0, output: 1, calls: 1, context: 100, window: 1000 });

/// A station from before the quarters: its calls in two workspaces not counted in them yet (as `installUsage15m` leaves
/// a database with calls, `since` its opening), and the statistics of before still there, full, their writers stopped.
function old() {
  const dir = mkdtempSync(join(tmpdir(), "mb-usage-retire-"));
  const path = join(dir, "stillfail.db");
  const store = Store.open(path, join(dir, "archive"));
  for (const [key, ws] of [["a", "A"], ["h", null]] as const) store.insertSession({ key, connect: "ember", runtime: "claude", profile: "cc", workspace: `/w/${key}`, token: key, ws, createdAt: 0, lastActiveAt: 0 });
  const record = (key: string, calls: UsageCall[]) => store.recordUsage(`/${key}`, { session: key, offset: calls.length, model: "m" }, "claude", calls.map((c) => [c, of]));
  record("a", Array.from({ length: 300 }, (_, i) => call(`a${i}`, i * HOUR / 3, i + 1)));
  record("h", Array.from({ length: 200 }, (_, i) => call(`h${i}`, i * HOUR / 2 + 60_000, 1_000 + i)));
  store.db.exec(`UPDATE usage SET rollup_counted = 0; UPDATE usage_15m_meta SET since = ${120 * HOUR}`);
  installCompactUsage(store.db);
  // the statistics of before (one keyed by two columns, one by a rowid), full, and a writer of theirs
  store.db.exec(`CREATE TABLE usage_detail_x (k TEXT, n INTEGER, PRIMARY KEY (k, n)) WITHOUT ROWID;
    CREATE TABLE usage_history (scope TEXT NOT NULL, quarter INTEGER NOT NULL, calls INTEGER, tokens INTEGER, PRIMARY KEY (scope, quarter)) WITHOUT ROWID;
    CREATE TABLE usage_compact_since (id INTEGER PRIMARY KEY, since INTEGER);
    CREATE TABLE usage_summary_changes (seq INTEGER PRIMARY KEY, scope TEXT);
    CREATE TABLE usage_minute_all (id INTEGER PRIMARY KEY, done INTEGER);
    CREATE TRIGGER usage_history_add AFTER INSERT ON usage BEGIN
      INSERT INTO usage_history VALUES ('', NEW.at / 900000, 1, 1) ON CONFLICT DO UPDATE SET calls = calls + 1;
    END;`);
  for (let i = 0; i < 600; i++) store.db.prepare("INSERT INTO usage_detail_x VALUES (?, ?)").run(`k${i % 7}`, i);
  for (let i = 0; i < 300; i++) store.db.prepare("INSERT INTO usage_summary_changes (scope) VALUES (?)").run(`s${i}`);
  store.db.exec("INSERT INTO usage_compact_since VALUES (1, 5); INSERT INTO usage_minute_all VALUES (1, 1)");
  stopUsageIndexes(store.db);
  return { dir, path, store, record, close: () => { store.close(); rmSync(dir, { recursive: true, force: true }); } };
}

/// Every usage table's rows (the counter's wall-clock times aside), a line each, sorted.
function tables(store: Store): string[] {
  const db = store.db;
  const names = (db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'usage%' AND name <> 'usage_counter' ORDER BY name").all() as { name: string }[]).map((r) => r.name);
  return [...names.map((n) => `table ${n}`), ...names.flatMap((name) => (db.prepare(`SELECT * FROM "${name}"`).all() as object[]).map((r) => `${name} ${JSON.stringify(r)}`))].sort();
}

/// The lines only one side has, none when the same.
function same(ours: string[], theirs: string[], what: string) {
  const a = new Set(ours), b = new Set(theirs);
  assert.deepEqual({ ours: ours.filter((r) => !b.has(r)).slice(0, 5), theirs: theirs.filter((r) => !a.has(r)).slice(0, 5) }, { ours: [], theirs: [] }, what);
}

test("the MoonBit builder frees the old usage statistics and takes in the old calls as the TypeScript does", async () => {
  assert.notEqual(binary, null, "the MoonBit reader is built (station/mb/build.sh, or STILLFAIL_MB_READER)");
  const ts = old(), mb = old();
  const builder = new MbProcess(binary!, ["--builder", "usage-retire", "--db", mb.path]);
  const ask = (message: object) => {
    const answered = new Promise<{ done: boolean; error?: string }>((resolve) => builder.once("message", resolve));
    builder.postMessage(message);
    return answered;
  };
  try {
    let n = 0;
    for (let done = false; !done && n < 40; n++) {
      const ours = await ask({ drop: true });
      assert.equal(ours.error, undefined);
      done = dropUsageIndexStep(ts.store.db);
      assert.equal(ours.done, done, `drop ${n}`);
      same(tables(mb.store), tables(ts.store), `drop ${n}`);
    }
    assert.ok(n >= 7, `${n} drops`);
    for (const name of ["usage_detail_x", "usage_history", "usage_compact_since", "usage_summary_changes", "usage_minute_all"])
      assert.equal(mb.store.db.prepare("SELECT 1 FROM sqlite_master WHERE name = ?").get(name), undefined, name);
    assert.notEqual(mb.store.db.prepare("SELECT 1 FROM sqlite_master WHERE name = 'usage_minute_scope'").get(), undefined, "the contexts' pointers stay");
    n = 0;
    for (let done = false; !done && n < 60; n++) {
      if (n === 2) for (const f of [ts, mb]) f.record("a", [call("during", 130 * HOUR, 7), call("old-late", HOUR / 7, 9)]);
      const ours = await ask({});
      assert.equal(ours.error, undefined);
      done = fillUsage15mStep(ts.store.db);
      assert.equal(ours.done, done, `fill ${n}`);
      same(tables(mb.store), tables(ts.store), `fill ${n}`);
    }
    assert.ok(n >= 2, `${n} fills`);
    assert.deepEqual({ ...mb.store.db.prepare("SELECT since FROM usage_15m_meta").get() }, { since: null });
    assert.deepEqual({ ...mb.store.db.prepare("SELECT COUNT(*) AS n FROM usage WHERE rollup_counted = 0").get() }, { n: 0 });
    assert.deepEqual({ ...mb.store.db.prepare("SELECT SUM(calls) AS calls, SUM(input) AS input FROM usage_15m").get() },
      { ...mb.store.db.prepare("SELECT SUM(calls) AS calls, SUM(input) AS input FROM usage").get() });
  } finally {
    await builder.terminate();
    ts.close(); mb.close();
  }
});
