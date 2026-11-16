// What the device's page of what it keeps reads (account.ts cacheUsage, `cache.usage`): each log's characters as
// `log_bytes` keeps them (schema.ts ensureLogBytes), never its rows summed. Held here to what summing the rows says,
// byte for byte, whichever writes them (this core, an older core's INSERT OR REPLACE without the triggers' knowing, an
// update in place) and however they go (a cut, a log forgotten, a chat forgotten, a transcript let go for room, a
// station forgotten); a database from before counted once, as it is first asked, never as it opens; each chat's title
// as its whole record makes it, read of the few fields it is made of.
import assert from "node:assert/strict";
import { test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { Data, dbName } from "../src/data.ts";
import * as format from "../src/format.ts";
import { SqlError, type Sql, type SqlRow, type SqlValue } from "../src/host.ts";
import { NodeSql } from "../src/hosts/node-sql.ts";
import { Runner } from "../src/runtime.ts";
import { FakeHost, flush } from "../src/testing.ts";
import { run } from "./run.ts";

// deno-lint-ignore no-explicit-any
type J = any;

/// A database that notes what is asked of it.
class Noted implements Sql {
  readonly inner: NodeSql;
  statements: string[] = [];
  /// What finds the disk full: a statement it matches fails as SQLite's would.
  full: RegExp | null = null;
  constructor(inner: NodeSql) {
    this.inner = inner;
  }
  #room(sql: string): void {
    if (this.full?.test(sql)) throw new SqlError("database or disk is full", "full");
  }
  exec(sql: string): void {
    this.statements.push(sql);
    this.#room(sql);
    this.inner.exec(sql);
  }
  run(sql: string, params?: readonly SqlValue[]): number {
    this.statements.push(sql);
    this.#room(sql);
    return this.inner.run(sql, params);
  }
  all(sql: string, params?: readonly SqlValue[]): SqlRow[] {
    this.statements.push(sql);
    return this.inner.all(sql, params);
  }
  close(): void {}
}

function fresh() {
  const host = new FakeHost();
  let noted: Noted | null = null;
  host.openDbHook = (name) => {
    if (noted === null) {
      const sql = new NodeSql(new DatabaseSync(":memory:"), true);
      host.sqls.set(name, sql);
      noted = new Noted(sql);
    }
    return noted;
  };
  const runner = new Runner(host.time.clock);
  const owner = () => "s1";
  const open = async () => {
    const d = new Data(host, runner, { owner });
    await run(d.open(["s1"]));
    return d;
  };
  const sql = () => noted!;
  return { host, runner, open, sql };
}

/// What each chat keeps as summing its rows says it, its title as its whole record makes it: cacheUsage as it was before
/// the counts were kept.
function summed(sql: Sql): { station: string; thread: number; title: string | null; sessions: string[]; bytes: number }[] {
  const out = new Map<string, { station: string; thread: number; title: string | null; sessions: string[]; bytes: number }>();
  const of = (station: string, thread: number) => {
    const k = `${station}\0${thread}`;
    if (!out.has(k)) out.set(k, { station, thread, title: null, sessions: [], bytes: 0 });
    return out.get(k)!;
  };
  for (const r of sql.all("SELECT station, thread, sum(length(json)) FROM entry GROUP BY station, thread")) of(r[0] as string, r[1] as number).bytes += Number(r[2]);
  const first = new Map<string, number>();
  for (const r of sql.all("SELECT station, session, thread FROM thread_member ORDER BY station, session, thread")) {
    of(r[0] as string, r[2] as number).sessions.push(r[1] as string);
    if (!first.has(`${r[0]}\0${r[1]}`)) first.set(`${r[0]}\0${r[1]}`, r[2] as number);
  }
  for (const r of sql.all("SELECT station, session, sum(length(json)) FROM transcript GROUP BY station, session")) {
    const thread = first.get(`${r[0]}\0${r[1]}`);
    if (thread !== undefined) of(r[0] as string, thread).bytes += Number(r[2]);
  }
  for (const row of out.values()) {
    const json = sql.all("SELECT json FROM thread WHERE station = ? AND id = ?", [row.station, row.thread])[0]?.[0];
    const view = json === undefined ? null : JSON.parse(json as string);
    row.title = view === null ? null : format.chatTitle(view);
  }
  return [...out.values()].filter((r) => r.bytes > 0).sort((a, b) => a.station.localeCompare(b.station) || a.thread - b.thread);
}

/// What cacheUsage says of each chat, as the call shows it (its title).
const counted = (data: Data) =>
  data.cacheUsage().map(({ view, ...r }) => ({ station: r.station, thread: r.thread, title: view === null ? null : format.chatTitle(view), sessions: r.sessions, bytes: r.bytes }))
    .sort((a, b) => a.station.localeCompare(b.station) || a.thread - b.thread);

/// `log_bytes` against its rows summed, log by log.
function sameAsRows(sql: Sql, label: string): void {
  const kept = sql.all("SELECT tbl, station, id, bytes FROM log_bytes ORDER BY tbl, station, id").map((r) => `${r[0]} ${r[1]} ${r[2]} ${r[3]}`);
  const rows = [
    ...sql.all("SELECT 'entry', station, thread, sum(length(json)) FROM entry GROUP BY station, thread"),
    ...sql.all("SELECT 'transcript', station, session, sum(length(json)) FROM transcript GROUP BY station, session"),
  ].map((r) => `${r[0]} ${r[1]} ${r[2]} ${r[3]}`).sort();
  assert.deepEqual(kept, rows, label);
}

const text = (n: number, c = "x") => c.repeat(n);

test("what_each_chat_keeps_is_counted_as_its_rows_are_written_and_go_byte_for_byte", async () => {
  const { open, sql, runner } = fresh();
  const data = await open();
  data.putThread("w/a", { id: 7, title: "大视频", sessions: [{ session: "k1" }, { session: "k2" }] });
  data.putThread("w/a", { id: 8, autoTitle: "另一个", sessions: [{ session: "k2" }] });
  data.putThread("w/b", { id: 7, surface: "slack", channel: "C1", firstText: "<@U1> 帮我看看 这个", sessions: [{ session: "k1" }] });
  data.putItems("entry", "w/a", "7", [[1, { text: text(100) }], [2, { text: "多字节的字" }]]);
  data.putItems("entry", "w/a", "8", [[1, { text: "other" }]]);
  data.putItems("entry", "w/b", "7", [[1, { text: text(40, "y") }]]);
  data.putItems("transcript", "w/a", "k1", [[0, { a: text(50, "z") }], [1, { a: "b" }]]);
  data.putItems("transcript", "w/a", "k2", [[0, { a: "k2" }]]);
  data.putItems("transcript", "w/b", "k1", [[0, { a: "其他 station" }]]);
  await flush();
  // Counted whole as first asked.
  assert.deepEqual(counted(data), summed(sql()), "first asked");
  sameAsRows(sql(), "first asked");
  const steps: [string, () => void][] = [
    // (put again: INSERT OR REPLACE, which deletes the row it replaces firing no delete trigger)
    ["an entry put again, longer", () => data.putItems("entry", "w/a", "7", [[1, { text: text(300) }]])],
    ["an entry put again, shorter", () => data.putItems("entry", "w/a", "7", [[2, { text: "短" }]])],
    ["new entries", () => data.putItems("entry", "w/a", "7", [[3, { text: "三" }], [4, { text: "四" }]])],
    ["a transcript written anew from before its end: cut there", () => data.putItems("transcript", "w/a", "k1", [[1, { a: text(9) }]], 1)],
    ["entries cut", () => data.putItems("entry", "w/a", "7", [], 2)],
    ["an older core's INSERT OR REPLACE", () => sql().inner.run("INSERT OR REPLACE INTO entry (station, thread, n, json) VALUES ('w/a', 8, 1, ?)", [JSON.stringify({ text: text(77) })])],
    ["an older core's plain insert", () => sql().inner.run("INSERT INTO entry (station, thread, n, json) VALUES ('w/a', 8, 2, ?)", [JSON.stringify({ text: "older" })])],
    ["a row changed in place", () => sql().inner.run("UPDATE transcript SET json = ? WHERE station = 'w/a' AND session = 'k2' AND i = 0", [JSON.stringify({ a: text(123) })])],
    ["a row moved to another log in place", () => sql().inner.run("UPDATE entry SET thread = 9 WHERE station = 'w/a' AND thread = 8 AND n = 2")],
    ["a log forgotten", () => data.forgetLog("entry", "w/b", "7")],
    ["a transcript forgotten", () => data.forgetLog("transcript", "w/a", "k2")],
    ["a transcript let go for room", () => (data as J).of("w/b").evict("w/b", "k1")],
    ["a chat forgotten", () => data.forgetChat("w/a", 7)],
    ["written again after", () => data.putItems("entry", "w/a", "7", [[1, { text: "回来了" }]])],
    ["a station forgotten", () => (data as J).of("w/b").forgetStation("w/b")],
  ];
  for (const [label, step] of steps) {
    step();
    await flush();
    sameAsRows(sql(), label);
    assert.deepEqual(counted(data), summed(sql()), label);
  }
  // Read of what is counted: no row of a log summed.
  sql().statements.length = 0;
  counted(data);
  assert.deepEqual(sql().statements.filter((s) => /\bFROM (entry|transcript)\b/.test(s)), [], "no log's rows read");
  runner.shutdown();
});

test("a_database_from_before_the_counts_is_counted_once_as_it_is_first_asked_and_never_as_it_opens", async () => {
  const { open, sql, runner } = fresh();
  let data = await open();
  for (const st of ["w/a", "w/b", "w/c"]) {
    data.putThread(st, { id: 1, title: `t ${st}`, sessions: [{ session: "k" }] });
    data.putItems("entry", st, "1", Array.from({ length: 20 }, (_, i) => [i + 1, { text: text(i * 10) }]));
    data.putItems("transcript", st, "k", Array.from({ length: 5 }, (_, i) => [i, { a: text(i * 50) }]));
  }
  await flush();
  await run(data.written);
  // A core from before: no counts, no triggers; it goes on writing.
  const raw = sql().inner;
  for (const r of raw.all("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'log_bytes_%'")) raw.exec(`DROP TRIGGER ${r[0]}`);
  raw.exec("DROP TABLE log_bytes; DROP TABLE log_bytes_done");
  raw.run("INSERT OR REPLACE INTO entry (station, thread, n, json) VALUES ('w/a', 1, 1, ?)", [JSON.stringify({ text: text(999) })]);
  raw.run("DELETE FROM transcript WHERE station = 'w/b'");
  // Opened by this core: the triggers made again, nothing counted.
  sql().statements.length = 0;
  data = await open();
  assert.deepEqual(sql().statements.filter((s) => /length\(json\)\)|\bFROM (entry|transcript)\b/.test(s) && !/CREATE TRIGGER/.test(s)), [], "nothing of the logs read as it opens");
  assert.equal(raw.all("SELECT count(*) FROM log_bytes")[0]![0], 0);
  // First asked: counted a station at a time (what is written meanwhile counted by the triggers).
  assert.equal(data.countLogs(), true);
  data.putItems("entry", "w/c", "1", [[99, { text: "between the steps" }]]);
  while (data.countLogs());
  await flush();
  sameAsRows(sql(), "counted");
  assert.deepEqual(counted(data), summed(sql()));
  // A core started anew on it: read of what is counted.
  await run(data.written);
  data = await open();
  sql().statements.length = 0;
  const read = counted(data);
  assert.deepEqual(sql().statements.filter((s) => /\bFROM (entry|transcript)\b/.test(s)), [], "counted already: no log's rows read");
  assert.deepEqual(read, summed(sql()));
  // A trigger another core put in its place (or took away): every count let go, counted anew as first asked.
  raw.exec("DROP TRIGGER log_bytes_entry_put");
  raw.run("INSERT INTO entry (station, thread, n, json) VALUES ('w/b', 1, 500, ?)", [JSON.stringify({ text: "uncounted" })]);
  data = await open();
  assert.equal(raw.all("SELECT count(*) FROM log_bytes_done")[0]![0], 0);
  assert.deepEqual(counted(data), summed(sql()));
  sameAsRows(sql(), "counted anew");
  runner.shutdown();
});

test("each_chat_is_called_as_its_whole_record_calls_it_read_of_its_titles_fields_in_one_statement", async () => {
  const { open, sql, runner } = fresh();
  const data = await open();
  const records: J[] = [
    { id: 1, title: "人起的名字", autoTitle: "agent 起的" },
    { id: 2, title: "   ", autoTitle: "agent 起的" },
    { id: 3, surface: "chat", channel: "CHAT", firstText: "不用它" },
    { id: 4, surface: "slack", channel: "C0OPS", firstText: "<@U123> \n\n  第一  行 \n第二行", channelName: "ops" },
    { id: 5, surface: "slack", channel: "C0OPS", channelName: "ops" },
    { id: 6, surface: "feishu:x", channel: "oc_abc", channelName: "飞书群" },
    { id: 7, surface: "slack", channel: "D0DM" },
    { id: 8, surface: "slack", channel: "C0OPS", title: 42, autoTitle: { not: "text" }, firstText: ["no"] },
    { id: 9, sessions: [{ session: "k9" }], extra: text(5000) },
  ];
  for (const r of records) data.putThread("w/a", r);
  for (const r of [...records, { id: 10 }]) data.putItems("entry", "w/a", String(r.id), [[1, { text: "x" }]]);
  await flush();
  const before = sql().statements.length;
  assert.deepEqual(counted(data), summed(sql()));
  const titled = sql().statements.slice(before).filter((s) => /\bFROM json_each\(\?\) AS k JOIN thread\b/.test(s));
  assert.equal(titled.length, 1, "one statement for every chat's title");
  assert.deepEqual(counted(data).map((r) => r.title), [...records.map((r) => format.chatTitle(r)), null]);
  runner.shutdown();
});

test("what_goes_before_a_database_from_before_is_counted_and_what_comes_while_it_is_counted_are_counted_right", async () => {
  const { open, sql, runner } = fresh();
  let data = await open();
  for (const st of ["w/a", "w/dead", "w/gone"]) {
    data.putThread(st, { id: 1, title: `t ${st}`, sessions: [{ session: "k" }] });
    data.putItems("entry", st, "1", Array.from({ length: 10 }, (_, i) => [i + 1, { text: text(i * 30) }]));
    data.putItems("transcript", st, "k", [[0, { a: text(400) }]]);
  }
  await flush();
  await run(data.written);
  // A core from before wrote it: no counts, no triggers.
  const raw = sql().inner;
  for (const r of raw.all("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'log_bytes_%'")) raw.exec(`DROP TRIGGER ${r[0]}`);
  raw.exec("DROP TABLE log_bytes; DROP TABLE log_bytes_done");
  data = await open();
  // Before it is first counted, every log of two stations goes: a chat forgotten, a station forgotten.
  data.forgetChat("w/dead", 1);
  (data as J).of("w/gone").forgetStation("w/gone");
  await flush();
  assert.equal(raw.all("SELECT count(*) FROM log_bytes")[0]![0], 0, "nothing counted of what was not counted");
  // Counted a step at a time; a station first written meanwhile, and one counted already written again.
  assert.equal(data.countLogs(), true);
  data.putItems("entry", "w/new", "3", [[1, { text: "第一次" }]]);
  data.putItems("entry", "w/a", "1", [[1, { text: text(900) }]]);
  while (data.countLogs());
  await flush();
  sameAsRows(sql(), "counted");
  // Written again after: from nothing.
  data.putItems("entry", "w/dead", "1", [[1, { text: text(5000) }]]);
  data.putItems("entry", "w/gone", "1", [[1, { text: "回来" }]]);
  data.putItems("entry", "w/new", "3", [[2, { text: "第二次" }]]);
  await flush();
  sameAsRows(sql(), "written after");
  assert.deepEqual(counted(data), summed(sql()));
  runner.shutdown();
});

test("a_database_from_before_counted_with_the_disk_full_is_read_of_its_rows_and_its_counting_ends", async () => {
  const { open, sql, runner } = fresh();
  let data = await open();
  for (const st of ["w/a", "w/b"]) {
    data.putThread(st, { id: 1, title: `t ${st}`, sessions: [{ session: "k" }] });
    data.putItems("entry", st, "1", Array.from({ length: 5 }, (_, i) => [i + 1, { text: text(i * 40) }]));
    data.putItems("transcript", st, "k", [[0, { a: text(300) }]]);
  }
  await flush();
  await run(data.written);
  const raw = sql().inner;
  const before = () => {
    for (const r of raw.all("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'log_bytes_%'")) raw.exec(`DROP TRIGGER ${r[0]}`);
    raw.exec("DROP TABLE log_bytes; DROP TABLE log_bytes_done");
  };
  // (a step that went round more than every station and table could ask would never end)
  const steps = () => {
    let n = 0;
    while (data.countLogs()) assert.ok(++n < 20, "counting ends");
    return n;
  };
  // No room for a count as it is written: no step goes on, and each chat is read of its rows.
  before();
  data = await open();
  sql().full = /^INSERT INTO log_bytes\b/;
  assert.equal(steps(), 0);
  assert.deepEqual(counted(data), summed(sql()));
  await flush();
  // Every step written, no room as they are committed: none of it is counted, and each chat is still read of its rows.
  sql().full = null;
  before();
  data = await open();
  assert.ok(steps() > 0);
  sql().full = /^COMMIT\b/;
  await flush();
  assert.equal(raw.all("SELECT count(*) FROM log_bytes_done")[0]![0], 0, "nothing committed");
  assert.equal(steps(), 0);
  assert.deepEqual(counted(data), summed(sql()));
  // Room again: counted, and read of the counts.
  sql().full = null;
  data.putItems("entry", "w/a", "1", [[9, { text: "又有空间" }]]);
  await flush();
  assert.ok(steps() > 0);
  await flush();
  sameAsRows(sql(), "counted with room again");
  assert.deepEqual(counted(data), summed(sql()));
  runner.shutdown();
});
