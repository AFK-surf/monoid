import { Effect } from "effect";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { outflowUsage } from "./reference/outflow.ts";
import { makeStore } from "./reference/store.ts";
import { usageHistory } from "./reference/usage.ts";
import { Store } from "../src/store/store.ts";
import { installCompactUsage } from "../src/store/usage-compact.ts";
import { installUsage15m } from "../src/store/usage-15m.ts";
import { fillUsage15mStep as fillUsageStep } from "./reference/backfill/usage-retire.ts";
import type { UsageCall, UsageFor } from "../src/store/usage.ts";
import { retireAfterPrevious } from "../src/usage/module.ts";

const HOUR = 3_600_000;
const of: UsageFor = { turn: null, person: "p", thread: null, profile: "cc" };
const call = (id: string, at: number, input: number, output = 1): UsageCall => ({ id, at, model: "m", subagent: false, fast: false,
  input, cacheRead: 0, cacheWrite: 0, cacheWriteLong: 0, output, calls: 1, context: 100, window: 1000 });

function session(store: Store, key: string, ws: string | null) {
  store.insertSession({ key, connect: "ember", runtime: "claude", profile: "cc", workspace: `/w/${key}`, token: key, ws, createdAt: 0, lastActiveAt: 0 });
}
function record(store: Store, key: string, calls: UsageCall[]) {
  store.recordUsage(`/${key}`, { session: key, offset: calls.length, model: "m" }, "claude", calls.map((c) => [c, of]));
}

/// The quarters taken away, as on a station from before them, its calls not counted in them yet (rollup_counted = 0),
/// then installed as such a station's store opens them at `now`.
function fromBefore(store: Store, now: number) {
  for (const { name } of store.db.prepare("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'usage_15m_%'").all() as { name: string }[])
    store.db.exec(`DROP TRIGGER "${name}"`);
  store.db.exec(`DROP TABLE usage_15m; DROP TABLE usage_quarter_totals; DROP TABLE usage_scope_totals; DROP TABLE usage_15m_meta;
    DROP TABLE usage_15m_replace; UPDATE usage SET rollup_counted = 0;`);
  installUsage15m(store.db, now);
}

/// A station from before the quarters, `hours` of calls in two workspaces, its contexts kept, and a call since.
function oldStation(hours = 200) {
  const store = Store.open(":memory:");
  session(store, "a", "A");
  session(store, "h", null);
  record(store, "a", Array.from({ length: hours }, (_, i) => call(`a${i}`, i * HOUR, i + 1)));
  record(store, "h", Array.from({ length: hours / 2 }, (_, i) => call(`h${i}`, i * 2 * HOUR + 60_000, 1_000 + i)));
  const now = hours * HOUR;
  fromBefore(store, now);
  installCompactUsage(store.db);
  record(store, "a", [call("after", now + HOUR, 5)]);
  return store;
}

const fill = (store: Store) => { let steps = 0; while (!fillUsageStep(store.db, 16)) steps++; return steps; };

/// By UTC day, from the calls themselves.
function truth(store: Store, ws?: string | null) {
  const rows = store.db.prepare(`SELECT strftime('%Y-%m-%d', u.at / 1000, 'unixepoch') AS day, SUM(u.calls) AS calls,
    SUM(u.input + u.output) AS tokens FROM usage u JOIN sessions s ON s.key = u.session ${ws === undefined ? "" : ws === null ? "WHERE s.ws IS NULL" : "WHERE s.ws = ?"}
    GROUP BY 1 ORDER BY 1`).all(...(typeof ws === "string" ? [ws] : [])) as { day: string; calls: number; tokens: number }[];
  return rows.map((r) => [r.day, r.calls, r.tokens]);
}
const year = (store: Store) => usageHistory(makeStore(store.db, "."), 0n, null) as { since?: number; tokens: number; days: { day: string; calls: number; tokens: number }[] };
const yearDays = (store: Store) => year(store).days.map((d) => [d.day, d.calls, d.tokens]);
/// What GET /v1/usage answers for workspace A, by day.
function detail(store: Store, from: number, to: number) {
  const days = new Map<string, [number, number]>();
  const read = outflowUsage(makeStore(store.db, "."), "en", from, to, 0, { workspace: "A", home: false }) as { rows: { day: string; calls: number; input: number; output: number }[] };
  for (const r of read.rows) {
    const d = days.get(r.day) ?? [0, 0];
    days.set(r.day, [d[0] + Number(r.calls), d[1] + Number(r.input) + Number(r.output)]);
  }
  return [...days].sort(([a], [b]) => (a < b ? -1 : 1)).map(([day, [calls, tokens]]) => [day, calls, tokens]);
}

test("a station from before the quarters gets its old days back, on the page and through outflow", () => {
  const store = oldStation();
  try {
    assert.equal(year(store).since, 200 * HOUR);
    assert.deepEqual(detail(store, 0, 201 * HOUR + 1), [["1970-01-09", 1, 6]], "only the call after the quarters began");
    assert.ok(fill(store) > 3, "in batches");
    assert.equal(year(store).since, undefined, "every call is known now");
    assert.deepEqual(yearDays(store), truth(store));
    assert.equal((store.db.prepare("SELECT SUM(tokens) AS n FROM usage_scope_totals").get() as { n: number }).n, (truth(store) as [string, number, number][]).reduce((n, d) => n + d[2], 0));
    assert.deepEqual(detail(store, 0, 201 * HOUR + 1), truth(store, "A"));
    assert.equal(fillUsageStep(store.db), true, "nothing left, and nothing done");
  } finally { store.close(); }
});

test("each batch leaves the days it reached complete", () => {
  const store = oldStation();
  try {
    const since = () => year(store).since!;
    let before = since();
    assert.equal(fillUsageStep(store.db, 16), false);
    assert.ok(since() < before && since() % 900_000 === 0, "the cursor is on a whole quarter");
    before = since();
    const known = truth(store).filter(([day]) => `${day}` > new Date(before).toISOString().slice(0, 10));
    assert.deepEqual(yearDays(store).filter(([day]) => `${day}` > new Date(before).toISOString().slice(0, 10)), known);
    // A stopped fill goes on from where it was: a fresh step, no state but `since`.
    fill(store);
    assert.deepEqual(yearDays(store), truth(store));
    assert.deepEqual(detail(store, 0, 201 * HOUR + 1), truth(store, "A"));
  } finally { store.close(); }
});

test("calls written while the fill goes on are counted once, wherever it has reached", () => {
  const store = oldStation();
  try {
    assert.equal(fillUsageStep(store.db, 16), false);
    const reached = year(store).since!;
    // Not yet reached: a late call, a response grown, a call removed. Already reached: the same.
    record(store, "a", [call("late-old", 3 * HOUR + 5, 7), call("a10", 10 * HOUR, 11, 50)]);
    store.db.prepare("DELETE FROM usage WHERE id = 'a20'").run();
    record(store, "a", [call("late-new", reached + 5, 9), call("a199", 199 * HOUR, 200, 60)]);
    store.db.prepare("DELETE FROM usage WHERE id = 'a198'").run();
    fill(store);
    assert.deepEqual(yearDays(store), truth(store));
    assert.deepEqual(detail(store, 0, 201 * HOUR + 1), truth(store, "A"));
    record(store, "a", [call("after-all", 2 * HOUR, 3)]);
    store.db.prepare("DELETE FROM usage WHERE id = 'h4'").run();
    assert.deepEqual(yearDays(store), truth(store));
    assert.deepEqual(detail(store, 0, 201 * HOUR + 1), truth(store, "A"));
  } finally { store.close(); }
});

test("a viewer sees only their workspace's old calls", () => {
  const store = oldStation();
  try {
    fill(store);
    const days = (workspace: string, home: boolean) => (usageHistory(makeStore(store.db, "."), 0n, { workspace, home }) as ReturnType<typeof year>).days.map((d) => [d.day, d.calls, d.tokens]);
    assert.deepEqual(days("A", false), truth(store, "A"));
    const read = outflowUsage(makeStore(store.db, "."), "en", 0, 201 * HOUR + 1, 0, { workspace: "A", home: false }) as { rows: { session: string }[] };
    assert.deepEqual([...new Set(read.rows.map((r) => r.session))], ["a"]);
  } finally { store.close(); }
});

test("a failed batch leaves everything as it was", () => {
  const store = oldStation();
  try {
    const was = [year(store).since, yearDays(store), store.db.prepare("SELECT COUNT(*) AS n FROM usage WHERE rollup_counted = 1").get()];
    store.db.exec("CREATE TRIGGER fail_fill BEFORE INSERT ON usage_15m BEGIN SELECT RAISE(ABORT, 'no room'); END");
    assert.throws(() => fillUsageStep(store.db, 16), /no room/);
    store.db.exec("DROP TRIGGER fail_fill");
    assert.deepEqual([year(store).since, yearDays(store), store.db.prepare("SELECT COUNT(*) AS n FROM usage WHERE rollup_counted = 1").get()], was);
    fill(store);
    assert.deepEqual(yearDays(store), truth(store));
  } finally { store.close(); }
});

test("a session keeps its context as its old calls are taken in", () => {
  const store = oldStation();
  try {
    const context = () => store.db.prepare("SELECT context_uncertain, context_runtime, context_model FROM usage_minute_scope WHERE session = 'a'").get();
    const was = context();
    assert.notEqual(was, undefined);
    assert.equal(store.lastContexts("a", 5).length, 1);
    fill(store);
    assert.deepEqual(context(), was);
    assert.equal(store.lastContexts("a", 5).length, 1);
  } finally { store.close(); }
});

test("the station's worker fills a file's old calls after handover and tells open pages", async () => {
  const dir = mkdtempSync(join(tmpdir(), "usage-fill-worker-"));
  const store = Store.open(join(dir, "stillfail.db"));
  try {
    session(store, "a", "A");
    record(store, "a", Array.from({ length: 600 }, (_, i) => call(`a${i}`, i * HOUR, i + 1)));
    fromBefore(store, 600 * HOUR);
    let told = 0;
    const off = store.subscribe((change) => { if (change.type === "usage" && change.statisticsOnly) told++; });
    await Effect.runPromise(retireAfterPrevious(store, Promise.resolve()));
    off();
    assert.ok(told >= 1, "told as the fill ended");
    assert.equal(year(store).since, undefined);
    assert.deepEqual(yearDays(store), truth(store));
    assert.deepEqual(detail(store, 0, 600 * HOUR), truth(store, "A"));
    // On a later start there is nothing to do.
    await Effect.runPromise(retireAfterPrevious(store, Promise.resolve()));
    assert.deepEqual(yearDays(store), truth(store));
  } finally { store.close(); rmSync(dir, { recursive: true, force: true }); }
});
