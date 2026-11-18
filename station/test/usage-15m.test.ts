// What the agents spent, added up by quarter hour as it is written (store/usage-15m.ts): the quarters and their totals
// always the calls themselves, whatever writes them (an INSERT, OR REPLACE, OR IGNORE, an upsert, an UPDATE, a DELETE,
// with recursive triggers off and on) and whatever happens to their sessions (a workspace changed, a key changed, a
// session replaced or gone, the home workspace moved); a read of any span in any time zone the calls themselves, for
// each viewer, reading the calls only at a span's partial quarters and a local midnight's; a database from before
// opened without reading its calls, which are taken in afterwards. And what the usage page says beside them: a person
// of a connect moved here, an account moved away, the tasks other stations ran here a day and chat a row, and the
// chats of sessions that moved counted again by the station itself.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { constants, type DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { makeStore, remoteRunsSince, usageGroups } from "./reference/store.ts";
import { configProfiles, usage, usageHistory } from "./reference/usage.ts";
import { Store } from "../src/store/store.ts";
import { installUsage15m, usage15mQuery } from "../src/store/usage-15m.ts";
import { fillUsage15mStep } from "./reference/backfill/usage-retire.ts";
import { drainUsageChats } from "../src/usage/module.ts";
import type { InWorkspace } from "../src/store/rows.ts";

const Q = 900_000;
const DAY = 86_400_000;
const I64_MAX = 9_223_372_036_854_775_807n;
const COLUMNS = "(id, at, session, thread, person, profile, runtime, model, fast, input, cache_read, cache_write, cache_write_long, output, calls)";

/// A small deterministic generator.
function random(seed: number) {
  return (n: number) => { seed = (seed * 48271) % 2147483647; return seed % n; };
}

const session = (store: Store, key: string, ws: string | null) => store.insertSession({ key, connect: "chat", runtime: "claude",
  profile: "cc", workspace: `/w/${key}`, token: key, ws, createdAt: 1, lastActiveAt: 1 } as Parameters<Store["insertSession"]>[0]);

/// Where each session's calls are counted, as the quarters keep it: its workspace while it is there; where it was while
/// its calls are kept after it is gone (forgotten once none is left).
class Scopes {
  readonly #gone = new Map<string, string>();
  readonly db: DatabaseSync;
  constructor(db: DatabaseSync) { this.db = db; this.seen(); }
  of(key: string): string {
    const row = this.db.prepare("SELECT ws FROM sessions WHERE key = ?").get(key) as { ws: string | null } | undefined;
    return row !== undefined ? row.ws ?? "" : this.#gone.get(key) ?? "";
  }
  /// After each change: the sessions there now, and those gone that still have calls.
  seen(): void {
    for (const r of this.db.prepare("SELECT key, ws FROM sessions").all() as { key: string; ws: string | null }[]) this.#gone.set(r.key, r.ws ?? "");
    // (calls of a session never there: the home workspace's)
    for (const r of this.db.prepare("SELECT DISTINCT session FROM usage WHERE rollup_counted = 1").all() as { session: string }[])
      if (!this.#gone.has(r.session)) this.#gone.set(r.session, "");
    for (const key of [...this.#gone.keys()]) {
      if (this.db.prepare("SELECT 1 FROM sessions WHERE key = ?").get(key)) continue;
      if (!this.db.prepare("SELECT 1 FROM usage WHERE session = ? AND rollup_counted = 1").get(key)) this.#gone.delete(key);
    }
  }
  /// The home workspace's sessions gone, as setSessionsWs moves them.
  moved(from: string, to: string): void {
    for (const [key, ws] of this.#gone) if (ws === from) this.#gone.set(key, to);
  }
}

type Row = Record<string, number | string | null>;
const calls = (db: DatabaseSync): Row[] => db.prepare("SELECT * FROM usage WHERE rollup_counted = 1").all() as Row[];

/// The quarters and both totals as the calls make them, beside what the database keeps.
function exact(db: DatabaseSync, scopes: Scopes, what: string) {
  const want = new Map<string, number[]>();
  for (const r of calls(db)) {
    const at = Number(r.at);
    const key = JSON.stringify([scopes.of(String(r.session)), Math.floor(at / Q), r.session, r.thread ?? 0, r.person ?? "", r.profile ?? "",
      r.runtime, r.model ?? "", Number(r.fast) !== 0 ? 1 : 0]);
    const v = want.get(key) ?? [0, 0, 0, 0, 0, 0, 0];
    [1, r.calls, r.input, r.cache_read, r.cache_write, r.cache_write_long, r.output].forEach((x, i) => { v[i]! += Number(x); });
    want.set(key, v);
  }
  const have = new Map((db.prepare("SELECT * FROM usage_15m").all() as Row[]).map((r) => [
    JSON.stringify([r.scope, r.quarter, r.session, r.thread, r.person, r.profile, r.runtime, r.model, r.fast]),
    [r.records, r.calls, r.input, r.cache_read, r.cache_write, r.cache_write_long, r.output].map(Number)]));
  const sorted = (m: Map<string, unknown>) => [...m].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  assert.deepEqual(sorted(have), sorted(want), `${what}: the quarters`);
  const quarters = new Map<string, number[]>(), scoped = new Map<string, number[]>();
  for (const [key, v] of want) {
    const [scope, quarter] = JSON.parse(key) as [string, number];
    const tokens = v[2]! + v[3]! + v[4]! + v[5]! + v[6]!;
    for (const [map, at] of [[quarters, `${scope}|${quarter}`], [scoped, scope]] as const) {
      const t = map.get(at) ?? [0, 0];
      t[0]! += v[1]!; t[1]! += tokens;
      map.set(at, t);
    }
  }
  assert.deepEqual(sorted(new Map((db.prepare("SELECT * FROM usage_quarter_totals").all() as Row[]).map((r) => [`${r.scope}|${r.quarter}`, [Number(r.calls), Number(r.tokens)]]))),
    sorted(quarters), `${what}: the quarters' totals`);
  assert.deepEqual(sorted(new Map((db.prepare("SELECT * FROM usage_scope_totals").all() as Row[]).map((r) => [String(r.scope), [Number(r.calls), Number(r.tokens)]]))),
    sorted(scoped), `${what}: the workspaces' totals`);
  assert.equal((db.prepare("SELECT COUNT(*) AS n FROM usage_15m WHERE records <= 0").get() as { n: number }).n, 0, `${what}: no empty quarter left`);
}

for (const recursive of ["OFF", "ON"]) test(`the quarters are the calls through every way of writing them and their sessions (recursive triggers ${recursive})`, () => {
  const store = Store.open(":memory:");
  const db = store.db;
  try {
    db.exec(`PRAGMA recursive_triggers = ${recursive}`);
    for (const [key, ws] of [["s0", "A"], ["s1", null], ["s2", "B"], ["s3", "A"]] as const) session(store, key, ws);
    const scopes = new Scopes(db);
    const next = random(recursive === "ON" ? 11 : 7);
    const keys = ["s0", "s1", "s2", "s3", "s4"], places = [null, "A", "B"];
    const ops = new Map<number, number>();
    for (let step = 0; step < 2_500; step++) {
      const op = next(14);
      const id = `c${next(60)}`, key = keys[next(keys.length)]!;
      const at = next(6) * 400_000 - 900_000 + next(3) - (next(5) === 0 ? DAY : 0);
      const values = [id, at, key, next(3) || null, ["p", null][next(2)], ["cc", null][next(2)], ["claude", "codex"][next(2)], ["m", null][next(2)],
        next(2), next(9), next(9), next(9), next(9), next(9), 1 + next(3)];
      const insert = (verb: string, tail = "") => db.prepare(`${verb} INTO usage ${COLUMNS} VALUES (${values.map(() => "?").join(", ")}) ${tail}`).run(...values as never[]);
      try {
        switch (op) {
          case 0: case 1: insert("INSERT"); break;
          case 2: insert("INSERT OR REPLACE"); break;
          case 3: insert("INSERT OR IGNORE"); break;
          case 4: insert("INSERT", "ON CONFLICT (id) DO UPDATE SET output = MAX(output, excluded.output), input = excluded.input"); break;
          case 5: db.prepare("UPDATE usage SET output = output + 1, input = ? WHERE id = ?").run(next(9), id); break;
          case 6: db.prepare("UPDATE usage SET at = ?, session = ?, fast = 1 - fast WHERE id = ?").run(at, key, id); break;
          case 7: db.prepare("DELETE FROM usage WHERE id = ?").run(id); break;
          case 8: db.prepare(`INSERT OR REPLACE INTO sessions (key, connect, scope, runtime, profile, workspace, token, created_at, last_active_at, ws)
            VALUES (?, 'chat', 'thread', 'claude', 'cc', '/w', ?, 1, 1, ?)`).run(key, `t${next(4)}`, places[next(3)]!); break;
          case 9: store.deleteSession(key); break;
          case 10: db.prepare("UPDATE sessions SET ws = ? WHERE key = ?").run(places[next(3)]!, key); break;
          case 11: db.prepare("UPDATE sessions SET key = ? WHERE key = ?").run(keys[next(keys.length)]!, key); break;
          case 12: {
            const from = places[next(3)]!, to = places[next(3)]!;
            store.setSessionsWs(from, to);
            scopes.moved(from ?? "", to ?? "");
            break;
          }
          case 13: db.exec("DELETE FROM usage WHERE rowid IN (SELECT rowid FROM usage ORDER BY rowid LIMIT 2)"); break;
        }
      } catch (error) {
        if (!/UNIQUE constraint/.test(String(error))) throw error;
      }
      ops.set(op, (ops.get(op) ?? 0) + 1);
      scopes.seen();
      exact(db, scopes, `step ${step}, op ${op}`);
    }
    assert.equal(ops.size, 14, "every way of writing was taken");
    assert.ok((db.prepare("SELECT COUNT(*) AS n FROM usage").get() as { n: number }).n > 10);
  } finally { store.close(); }
});

test("a session gone keeps what it spent in its workspace; the home workspace moved takes them along", () => {
  const store = Store.open(":memory:");
  try {
    session(store, "a", "A");
    session(store, "h", null);
    const of = { turn: null, person: "p", thread: null, profile: "cc" };
    const call = (id: string, at: number) => ({ id, at, model: "m", subagent: true, fast: false, input: 1, cacheRead: 0, cacheWrite: 0,
      cacheWriteLong: 0, output: 1, calls: 1, context: null, window: null });
    store.recordUsage("/a", { session: "a", offset: 1, model: "m" }, "claude", [[call("a1", 10), of]]);
    store.recordUsage("/h", { session: "h", offset: 1, model: "m" }, "claude", [[call("h1", 20), of]]);
    const reader = makeStore(store.db, ".");
    const sessions = (viewer: InWorkspace | null) => usageGroups(reader, 0n, 60_000n, 0n, viewer).map((g) => g.session).sort();
    store.deleteSession("a");
    store.deleteSession("h");
    assert.deepEqual(sessions({ workspace: "A", home: false }), ["a"], "a session gone keeps its workspace");
    assert.deepEqual(sessions({ workspace: "B", home: true }), ["h"], "and the home one's stays the home one's");
    // A late call of a session gone is counted where its calls are.
    store.recordUsage("/a", { session: "a", offset: 2, model: "m" }, "claude", [[call("a2", 30), of]]);
    assert.deepEqual(usageGroups(reader, 0n, 60_000n, 0n, { workspace: "A", home: false }).map((g) => g.calls), [2]);
    // The home workspace becomes B: its sessions gone go with it.
    store.setSessionsWs(null, "B");
    assert.deepEqual(sessions({ workspace: "B", home: false }), ["h"]);
    assert.deepEqual(sessions({ workspace: "C", home: true }), []);
    // A session of that key again: its calls are its workspace's.
    session(store, "a", "C");
    assert.deepEqual(sessions({ workspace: "C", home: false }), ["a"]);
    assert.deepEqual(usageHistory(reader, 0n, { workspace: "C", home: false })!.days.map((d: { calls: number }) => d.calls), [2]);
    assert.deepEqual(usageHistory(reader, 0n, { workspace: "A", home: false })!.days, []);
  } finally { store.close(); }
});

test("a read of any span in any time zone is the calls themselves, for every viewer", () => {
  const store = Store.open(":memory:");
  try {
    const sessions = [["a", "A"], ["b", "B"], ["h", null], ["gone", "A"]] as const;
    for (const [key, ws] of sessions) session(store, key, ws);
    const next = random(3);
    const of = (n: number) => ({ turn: null, person: [null, "p@x", "q@x"][n % 3]!, thread: [null, 1, 2][n % 3]!, profile: [null, "cc"][n % 2]! });
    for (const [key] of sessions) {
      store.recordUsage(`/${key}`, { session: key, offset: 1, model: null }, "claude", Array.from({ length: 150 }, (_, n) => {
        const at = -DAY + next(4 * DAY) + (n % 7 === 0 ? 0 : 0);
        return [{ id: `${key}-${n}`, at: n % 11 === 0 ? Math.floor(at / Q) * Q : at, model: [null, "m", "n"][n % 3]!, subagent: false, fast: n % 4 === 0,
          input: next(100), cacheRead: next(100), cacheWrite: next(100), cacheWriteLong: next(100), output: next(100), calls: 1 + next(3),
          context: null, window: null }, of(n)] as const;
      }) as never);
    }
    const scopes = new Scopes(store.db);
    store.deleteSession("gone");
    scopes.seen();
    const reader = makeStore(store.db, ".");
    const rows = calls(store.db);
    const viewers: (InWorkspace | null)[] = [null, { workspace: "A", home: false }, { workspace: "A", home: true }, { workspace: "B" }, { workspace: "Z", home: false }];
    const q = BigInt(Q), day = BigInt(DAY);
    const spans: [bigint, bigint][] = [[0n, I64_MAX], [-2n * day, I64_MAX], [1n, 2n], [7n, 7n], [q, 2n * q], [q + 1n, 5n * q - 1n],
      [-day + 123n, 2n * day + 456n], [day - 1n, day + 1n], [5n * q + 3n, 5n * q + 9n], [-9_223_372_036_854_775_807n, I64_MAX], [3n * day, day],
      [-day, 3n * day]];
    let checked = 0;
    for (const viewer of viewers) for (const [from, to] of spans) for (const tz of [0, 45, 345, -210, 480, 7, -1, 1440, -1440]) {
      const sees = (scope: string) => viewer === null || scope === viewer.workspace || (scope === "" && viewer.home !== false);
      const want = new Map<string, Row>();
      for (const r of rows) {
        const at = BigInt(Number(r.at));
        if (at < from || at >= to || !sees(scopes.of(String(r.session)))) continue;
        const day = new Date(Number(r.at) + tz * 60_000).toISOString().slice(0, 10);
        const group = { day, session: r.session, thread: r.thread ?? null, person: r.person ?? null, profile: r.profile ?? null,
          runtime: r.runtime, model: r.model ?? null, fast: Number(r.fast) !== 0 };
        const key = JSON.stringify(group);
        const g = want.get(key) ?? { ...group, calls: 0, input: 0, cacheRead: 0, cacheWrite: 0, cacheWriteLong: 0, output: 0 } as unknown as Row;
        g.calls = Number(g.calls) + Number(r.calls); g.input = Number(g.input) + Number(r.input); g.cacheRead = Number(g.cacheRead) + Number(r.cache_read);
        g.cacheWrite = Number(g.cacheWrite) + Number(r.cache_write); g.cacheWriteLong = Number(g.cacheWriteLong) + Number(r.cache_write_long);
        g.output = Number(g.output) + Number(r.output);
        want.set(key, g);
      }
      const order = (a: Row, b: Row) => JSON.stringify(a) < JSON.stringify(b) ? -1 : 1;
      const have = usageGroups(reader, from, to, BigInt(tz), viewer).map((g) => ({ ...g }) as unknown as Row).sort(order);
      assert.deepEqual(have, [...want.values()].sort(order), `${from}..${to} at ${tz} for ${JSON.stringify(viewer)}`);
      if (viewer === null && from > -(2n ** 53n) && to < 2n ** 53n) assert.deepEqual(store.usageGroups(Number(from), Number(to), tz).map((g) => ({ ...g }) as unknown as Row).sort(order), have);
      checked += have.length;
    }
    assert.ok(checked > 1_000, `${checked} groups compared`);
  } finally { store.close(); }
});

test("a read takes calls only at its partial quarters and a local midnight's, of its own workspace's sessions there", () => {
  const store = Store.open(":memory:");
  try {
    for (const [key, ws] of [["a", "A"], ["b", "B"], ["far", "A"]] as const) session(store, key, ws);
    const of = { turn: null, person: "p", thread: null, profile: "cc" };
    const call = (id: string, at: number) => ({ id, at, model: "m", subagent: true, fast: false, input: 1, cacheRead: 0, cacheWrite: 0,
      cacheWriteLong: 0, output: 0, calls: 1, context: null, window: null });
    const record = (key: string, list: [string, number][]) => store.recordUsage(`/${key}`, { session: key, offset: 1, model: "m" }, "claude",
      list.map(([id, at]) => [call(id, at), of]));
    // an edge call at 1_001 and a midnight's call (at UTC+7 minutes, local midnight falls in quarter DAY/Q - 1)
    record("a", [["edge", 1_001], ["midnight", DAY - 5 * 60_000], ["whole", 4 * Q]]);
    const viewer = { workspace: "A", home: false };
    const counted = (from: bigint, to: bigint, tz: bigint) => {
      const q = usage15mQuery(from, to, tz, viewer)!;
      const sql = q.sql.replaceAll("WHERE u.rollup_counted = 1", "WHERE usage_15m_call() AND u.rollup_counted = 1");
      let seen = 0;
      store.db.function("usage_15m_call", () => { seen++; return 1; });
      const groups = store.db.prepare(sql).all(...(q.args as never[])) as { calls: number }[];
      return [groups.reduce((n, g) => n + Number(g.calls), 0), seen];
    };
    const before = [counted(1_001n, 1_002n, 0n), counted(1_000n, BigInt(DAY), 7n), counted(0n, BigInt(DAY), 0n)];
    assert.deepEqual(before, [[1, 1], [3, 2], [3, 0]], "a span of whole quarters reads no call; an edge and a midnight their own");
    // Calls of another workspace in the same quarters, and of the same session outside the edge's bounds, change nothing
    // of what is read.
    record("b", Array.from({ length: 300 }, (_, n) => [`b${n}`, 1_001 + (n % 3)] as [string, number]));
    record("b", Array.from({ length: 300 }, (_, n) => [`bm${n}`, DAY - 5 * 60_000] as [string, number]));
    record("a", Array.from({ length: 300 }, (_, n) => [`early${n}`, 500] as [string, number]));
    record("far", Array.from({ length: 300 }, (_, n) => [`far${n}`, 8 * Q + n] as [string, number]));
    assert.deepEqual(counted(1_001n, 1_002n, 0n), before[0]);
    assert.deepEqual(counted(1_000n, BigInt(DAY), 7n)[1], before[1]![1], "the midnight's quarter of its own sessions only");
    // Whole quarters in a time zone of whole quarters: not a call read.
    store.db.setAuthorizer((action, table) => action === constants.SQLITE_READ && table === "usage" ? constants.SQLITE_DENY : constants.SQLITE_OK);
    try {
      const reader = makeStore(store.db, ".");
      for (const tz of [0n, 45n, 345n, -210n]) assert.ok(usageGroups(reader, 0n, BigInt(DAY), tz, viewer).length > 0);
      assert.ok(usageHistory(reader, 7n, viewer)!.days.length > 0, "the year by its quarters' totals alone");
    } finally { store.db.setAuthorizer(null); }
  } finally { store.close(); }
});

test("a database from before is opened without reading its calls and takes them in afterwards", () => {
  const dir = mkdtempSync(join(tmpdir(), "usage-15m-old-"));
  const path = join(dir, "stillfail.db");
  let store = Store.open(path);
  try {
    assert.deepEqual({ ...store.db.prepare("SELECT since FROM usage_15m_meta").get() }, { since: null }, "a new database counts from its first call");
    session(store, "a", "A");
    const of = { turn: null, person: "p", thread: null, profile: "cc" };
    store.recordUsage("/a", { session: "a", offset: 1, model: "m" }, "claude", Array.from({ length: 40 }, (_, n) => [{ id: `a${n}`, at: n * Q,
      model: "m", subagent: true, fast: false, input: n, cacheRead: 0, cacheWrite: 0, cacheWriteLong: 0, output: 1, calls: 1, context: null,
      window: null }, of]) as never);
    // As a station from before the quarters left it.
    for (const { name } of store.db.prepare("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'usage_15m_%'").all() as { name: string }[])
      store.db.exec(`DROP TRIGGER "${name}"`);
    store.db.exec(`DROP TABLE usage_15m; DROP TABLE usage_quarter_totals; DROP TABLE usage_scope_totals; DROP TABLE usage_15m_meta;
      DROP TABLE usage_15m_replace; ALTER TABLE usage DROP COLUMN rollup_counted;`);
    const read: string[] = [];
    store.db.setAuthorizer((action, table, column) => {
      if (action === constants.SQLITE_READ && table === "usage" && column) read.push(column);
      return constants.SQLITE_OK;
    });
    try { installUsage15m(store.db, 100 * Q); } finally { store.db.setAuthorizer(null); }
    assert.deepEqual([...new Set(read)], ["at"], "only the latest call's time, by its index");
    assert.deepEqual({ ...store.db.prepare("SELECT since FROM usage_15m_meta").get() }, { since: 100 * Q });
    assert.deepEqual({ ...store.db.prepare("SELECT COUNT(*) AS n FROM usage_15m").get() }, { n: 0 }, "no old call taken in as it opens");
    store.close();
    store = Store.open(path);
    assert.deepEqual({ ...store.db.prepare("SELECT since FROM usage_15m_meta").get() }, { since: 100 * Q }, "opened again: the same");
    const reader = makeStore(store.db, dir);
    assert.equal(usage(reader, "en", 0n, I64_MAX, 0n, false, null).since, 100 * Q, "the page says from when every call is counted");
    let steps = 0;
    while (!fillUsage15mStep(store.db, 8)) steps++;
    assert.ok(steps >= 4, `${steps} steps`);
    const page = usage(reader, "en", 0n, I64_MAX, 0n, false, null);
    assert.equal(page.since, 0, "every call counted: from the first");
    assert.equal(page.detailSince, undefined);
    assert.deepEqual({ ...store.db.prepare("SELECT SUM(calls) AS calls, SUM(input) AS input FROM usage_15m").get() }, { calls: 40, input: 780 });
  } finally { store.close(); rmSync(dir, { recursive: true, force: true }); }
});

test("the page names a person of a connect moved here, and an account by the name it moved away with", () => {
  const dir = mkdtempSync(join(tmpdir(), "usage-15m-names-"));
  const store = Store.open(join(dir, "stillfail.db"));
  try {
    writeFileSync(join(dir, "config.json"), JSON.stringify({ profiles: [{ id: "cc", name: "Here", runtime: "claude" }],
      connects: [{ id: "claude-ember", slack: { team: { id: "T1", name: "Team" } } }] }));
    writeFileSync(join(dir, "slack-names.json"), JSON.stringify({ "u:T1:U09L4CPK3BL": { person: { name: "Una", email: "una@x", picture: "https://p/u" } } }));
    mkdirSync(join(dir, "move"));
    writeFileSync(join(dir, "move", "accounts-known.json"), JSON.stringify({ shared: { share: "s1", name: " Team Max " }, cc: { own: "cc@x", name: "Old" },
      codex: { key: "k", name: "Codex Pro", runtime: "codex" }, nameless: { own: "n@x" } }));
    session(store, "s", null);
    const person = "slack:claude-ember@d70ccd2f:U09L4CPK3BL";
    store.recordUsage("/s", { session: "s", offset: 1, model: "m" }, "claude", [[{ id: "c", at: 10, model: "m", subagent: false, fast: false,
      input: 1, cacheRead: 0, cacheWrite: 0, cacheWriteLong: 0, output: 1, calls: 1, context: null, window: null },
    { turn: null, person, thread: null, profile: "shared" }]]);
    const page = usage(makeStore(store.db, dir), "en", 0n, I64_MAX, 0n, false, null);
    assert.deepEqual(page.people[person], { id: person, name: "Una", email: "una@x", via: "slack", picture: "https://p/u" });
    assert.deepEqual(configProfiles(dir), { cc: { name: "Here", runtime: "claude" }, shared: { name: "Team Max", runtime: "claude" },
      codex: { name: "Codex Pro", runtime: "codex" } });
    assert.deepEqual(page.profiles.shared, { name: "Team Max", runtime: "claude" });
  } finally { store.close(); rmSync(dir, { recursive: true, force: true }); }
});

test("the tasks other stations ran here are told a day and chat a row, from their own start until the span's end", () => {
  const store = Store.open(":memory:");
  try {
    const add = store.db.prepare("INSERT INTO remote_runs (job, at, session) VALUES (?, ?, ?)");
    let n = 0;
    for (let i = 0; i < 2_000; i++) add.run(`j${n++}`, 10 + i, "remote:A:s:busy");
    add.run(`j${n++}`, DAY + 5, "remote:A:s:busy");
    add.run(`j${n++}`, 20, "remote:A:s:once");
    add.run(`j${n++}`, DAY - 60_000, "remote:A:s:late");
    add.run(`j${n++}`, DAY + 60_000, "remote:A:s:late");
    add.run(`j${n++}`, 30, "remote:B:s:other");
    const reader = makeStore(store.db, ".");
    const viewer = { workspace: "A", home: false };
    assert.deepEqual(remoteRunsSince(reader, 0n, I64_MAX, 0n, viewer), [
      { at: 20, session: "remote:A:s:once" },
      { at: 2_009, session: "remote:A:s:busy", count: 2_000 },
      { at: DAY - 60_000, session: "remote:A:s:late" },
      { at: DAY + 5, session: "remote:A:s:busy" },
      { at: DAY + 60_000, session: "remote:A:s:late" },
    ]);
    // In a zone where the two of `late` are one day.
    assert.deepEqual(remoteRunsSince(reader, 0n, I64_MAX, 120n, viewer).filter((r) => r.session === "remote:A:s:late"),
      [{ at: DAY + 60_000, session: "remote:A:s:late", count: 2 }]);
    // The page: from `remoteFrom` (else `from`) until `to`.
    const page = (options: { remoteFrom?: bigint }, from: bigint, to: bigint) =>
      usage(reader, "en", from, to, 0n, false, viewer, false, options).remoteRuns as { at: number; session: string; count?: number }[];
    assert.deepEqual(page({}, 15n, 25n), [{ at: 20, session: "remote:A:s:once" }, { at: 24, session: "remote:A:s:busy", count: 10 }]);
    assert.deepEqual(page({ remoteFrom: BigInt(DAY) }, 0n, BigInt(2 * DAY)).map((r) => r.at), [DAY + 5, DAY + 60_000]);
    assert.deepEqual(page({ remoteFrom: 0n }, BigInt(DAY), BigInt(DAY) + 1n), [{ at: 20, session: "remote:A:s:once" },
      { at: 2_009, session: "remote:A:s:busy", count: 2_000 }, { at: DAY - 60_000, session: "remote:A:s:late" }]);
    assert.ok(JSON.stringify(page({}, 0n, I64_MAX)).length < 400, "two thousand tasks of a chat a day are one row");
  } finally { store.close(); }
});

test("the chats of sessions that moved are counted again by the station itself, and the page's chats are whole again", async () => {
  const store = Store.open(":memory:");
  let drain: ReturnType<typeof drainUsageChats> | null = null;
  try {
    for (const [key, ws] of [["a", "A"], ["b", "A"], ["c", null]] as const) session(store, key, ws);
    for (let i = 0; i < 70; i++) {
      const thread = store.openThread("chat", "CHAT", `t${i}`, `Chat ${i}`, null).id;
      store.joinThread(thread, i % 2 === 0 ? "a" : "b", "chat");
      if (i % 5 === 0) store.joinThread(thread, "c", "chat");
    }
    const reader = makeStore(store.db, ".");
    const history = (viewer: InWorkspace) => usageHistory(reader, 0n, viewer) as { chatsIncomplete?: boolean; places: Record<string, number> };
    assert.deepEqual(history({ workspace: "A", home: false }).places, { chat: 70 });
    let handover!: () => void;
    const told: unknown[] = [];
    const stop = store.subscribe((change) => { if (change.type === "usage") told.push(change); });
    drain = drainUsageChats(store, new Promise<void>((resolve) => { handover = resolve; }), 8);
    store.setSessionsWs("A", "B");
    assert.equal(history({ workspace: "B", home: false }).chatsIncomplete, true, "moved: not whole until counted again");
    assert.ok(store.db.prepare("SELECT 1 FROM usage_chat_dirty LIMIT 1").get());
    await drain.drained();
    assert.ok(store.db.prepare("SELECT 1 FROM usage_chat_dirty LIMIT 1").get(), "nothing before the station before has gone");
    handover();
    await new Promise<void>((resolve) => setImmediate(resolve));
    await drain.drained();
    assert.equal(store.db.prepare("SELECT 1 FROM usage_chat_dirty LIMIT 1").get(), undefined);
    assert.equal(history({ workspace: "B", home: false }).chatsIncomplete, undefined);
    assert.deepEqual(history({ workspace: "B", home: false }).places, { chat: 70 });
    assert.deepEqual(history({ workspace: "A", home: false }).places, {});
    assert.deepEqual(told, [{ type: "usage", sessions: [], statisticsOnly: true }], "pages open are told once");
    // Moved again later: counted again at once.
    store.db.prepare("UPDATE sessions SET ws = 'C' WHERE key = 'a'").run();
    store.setSessionsWs("B", "D");
    await new Promise<void>((resolve) => setImmediate(resolve));
    await drain.drained();
    assert.equal(store.db.prepare("SELECT 1 FROM usage_chat_dirty LIMIT 1").get(), undefined);
    assert.deepEqual(history({ workspace: "D", home: false }).places, { chat: 35 });
    assert.deepEqual(history({ workspace: "C", home: true }).places, { chat: 42 }, "a's chats and the home ones, each once");
    stop();
  } finally {
    drain?.stop();
    store.close();
  }
});
