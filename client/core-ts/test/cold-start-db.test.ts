// Cold-start database optimizations:
// - B0: active-first multi-account DB open with sign-in order preserved and close/sign-out race safety
// - B1: core.start DB breakdown trace attributes + read-only-first AccountDb cold open (0 write transactions on steady
//   state, full downgrade/DML repair even when schema_version is unchanged)
import assert from "node:assert/strict";
import { test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { Deferred, Effect } from "effect";
import { STORAGE_KEY, type StoredAccount } from "../src/accounts.ts";
import { Core } from "../src/core.ts";
import { Data, dbName } from "../src/data.ts";
import { AccountDb } from "../src/db/account.ts";
import { KEPT } from "../src/db/kept.ts";
import { CHAT_MADE } from "../src/db/schema.ts";
import { type HostError, type Sql, type SqlRow, type SqlValue } from "../src/host.ts";
import { NodeSql } from "../src/hosts/node-sql.ts";
import { Runner } from "../src/runtime.ts";
import { FakeHost, jsonResponse } from "../src/testing.ts";
import { chatDerive } from "../src/views/views.ts";
import { run } from "./run.ts";

// deno-lint-ignore no-explicit-any
type J = any;

class CountingSql implements Sql {
  readonly inner: NodeSql;
  readonly execs: string[] = [];
  readonly runs: string[] = [];
  readonly reads: string[] = [];

  constructor(inner: NodeSql) {
    this.inner = inner;
  }

  exec(sql: string): void {
    this.execs.push(sql);
    this.inner.exec(sql);
  }

  run(sql: string, params?: readonly SqlValue[]): number {
    this.runs.push(sql);
    return this.inner.run(sql, params);
  }

  all(sql: string, params?: readonly SqlValue[]): SqlRow[] {
    this.reads.push(sql);
    return this.inner.all(sql, params);
  }

  close(): void {}

  beginImmediates(): number {
    return this.execs.filter((s) => /\bBEGIN\s+IMMEDIATE\b/i.test(s)).length;
  }

  ddlOrWrites(): string[] {
    return [
      ...this.execs.filter((s) => /\b(BEGIN|COMMIT|CREATE|ALTER|DROP|INSERT|UPDATE|DELETE)\b/i.test(s)),
      ...this.runs,
    ];
  }

  reset(): void {
    this.execs.length = 0;
    this.runs.length = 0;
    this.reads.length = 0;
  }
}

const storedAccount = (sub: string, expires: number): StoredAccount => ({
  sub,
  email: `${sub}@example.com`,
  name: sub,
  picture: "",
  access: `access-${sub}`,
  refresh: `refresh-${sub}`,
  access_expires: expires,
});

function setupTwoAccountHost() {
  const host = new FakeHost();
  const expires = host.nowMs() / 1000 + 3600;
  host.store(STORAGE_KEY, [storedAccount("s1", expires), storedAccount("s2", expires)]);
  // Persisted active workspace belongs to the 2nd signed-in account ("s2").
  host.store("device/prefs", { device: { workspace: "ws2" } });
  const meByToken: Record<string, J> = {
    "Bearer access-s1": {
      user: { sub: "s1", email: "s1@example.com" },
      workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-both", name: "Both" }],
      invitations: [],
      relay_url: "https://relay.test",
    },
    "Bearer access-s2": {
      user: { sub: "s2", email: "s2@example.com" },
      workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-both", name: "Both" }],
      invitations: [],
      relay_url: "https://relay.test",
    },
  };
  const wsById: Record<string, J> = {
    ws1: { id: "ws1", name: "WS 1", members: [], stations: [{ id: "st1", name: "Station 1", online: true }] },
    ws2: { id: "ws2", name: "WS 2", members: [], stations: [{ id: "st2", name: "Station 2", online: true }] },
    "ws-both": { id: "ws-both", name: "Both", members: [], stations: [] },
  };
  const spans: J[] = [];
  host.onFetch((req) => {
    const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
    if (req.url.endsWith("/v1/me")) return jsonResponse(200, meByToken[auth] ?? { user: {}, workspaces: [] });
    if (req.url.includes("/v1/workspaces/")) {
      const id = decodeURIComponent(req.url.split("/v1/workspaces/")[1]!.split("/")[0]!);
      return jsonResponse(200, wsById[id] ?? { id, name: id, members: [], stations: [] });
    }
    if (req.url.endsWith("/traces") && req.body) {
      const parsed = JSON.parse(new TextDecoder().decode(req.body));
      for (const rs of parsed.resourceSpans ?? []) {
        for (const ss of rs.scopeSpans ?? []) {
          for (const sp of ss.spans ?? []) spans.push(sp);
        }
      }
      return jsonResponse(200, {});
    }
    return jsonResponse(200, {});
  });
  return { host, spans };
}

test("B0: multi-account active-first open answers primary account immediately and preserves sign-in order", async () => {
  const { host, spans } = setupTwoAccountHost();

  // Cold start #1: no workspaceOwners cache yet -> opens both accounts synchronously and caches owners.
  const first = await Core.create(host, { sample: 1, reports: true, clock: host.time.clock });
  // Seed cached me + workspace + chat in each account's DB so cold start #2 reads them offline.
  first.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-both", name: "Both" }] });
  first.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-both", name: "Both" }] });
  first.inner.cloudSync.recomputeOwners();
  first.inner.data.set({ topic: "workspace", workspace: "ws2" }, { id: "ws2", name: "WS 2", members: [], stations: [{ id: "st2", name: "Station 2", online: true }] });
  first.inner.data.db("s2")!.setChats("ws2/st2", false, [{ id: "c1", title: "Primary Chat", lastActiveAt: 1000, thread: 1 }], 1000);
  await run(first.inner.data.written);
  assert.deepEqual(first.inner.data.device.get("choice", "workspaceOwners"), { ws1: "s1", "ws-both": "s1", ws2: "s2" });
  await first.close();

  // Cold start #2: gate s1's DB open behind a Deferred while s2 opens immediately.
  const gateS1 = Deferred.makeUnsafe<void>();
  const origOpenDb = host.openDb.bind(host);
  const openOrder: string[] = [];
  host.openDb = (name: string): Effect.Effect<Sql, HostError> =>
    Effect.gen(function* () {
      openOrder.push(name);
      if (name === dbName("s1")) yield* Deferred.await(gateS1);
      return yield* origOpenDb(name);
    });

  const second = await Core.create(host, { sample: 1, reports: true, clock: host.time.clock });
  // Core.create finished without waiting for s1!
  assert.ok(second.inner.data.db("s2") !== undefined, "active account s2 is open immediately");
  assert.equal(second.inner.data.db("s1"), undefined, "non-active account s1 is still deferred");
  assert.equal(second.inner.data.isDeferred("s1"), true);
  assert.equal(second.inner.workspaces.owner("ws2"), "s2");
  assert.equal((second.inner.data.shared({ topic: "workspace", workspace: "ws2" }) as J)?.name, "WS 2");
  assert.equal((second.inner.data.chat("ws2/st2", "c1") as J)?.title, "Primary Chat");

  // Release s1's DB open and let the deferred background fiber complete.
  Deferred.doneUnsafe(gateS1, Effect.void);
  for (let i = 0; i < 20 && second.inner.data.db("s1") === undefined; i++) {
    await host.settle();
  }
  assert.ok(second.inner.data.db("s1") !== undefined, "deferred account s1 opened in background");
  assert.equal(second.inner.data.hasDeferred(), false);
  // Strict sign-in order preserved even though s2 opened before s1!
  assert.deepEqual(second.inner.data.dbs().map((d) => d.sub), ["s1", "s2"]);
  assert.deepEqual(second.inner.data.mes().map(([sub]) => sub), ["s1", "s2"]);
  assert.equal(second.inner.workspaces.owner("ws-both"), "s1", "sign-in order ownership preserved for shared workspace");
  assert.equal(openOrder.filter((n) => n.startsWith("account-"))[0], dbName("s2"), "s2 opened first");

  // Advance test clock past START_TOLD_MS + EXPORT_MS so core.start ends and exports to /v1/telemetry/traces.
  await host.time.pass(35_000);
  await second.close();
  // Verify core.start span recorded DB breakdown and db_deferred=1.
  const startSpans = spans.filter((s) => s.name === "core.start");
  const attrsOf = (sp: J) => Object.fromEntries((sp.attributes ?? []).map((a: J) => [a.key, a.value.intValue ?? a.value.doubleValue ?? a.value.boolValue ?? a.value.stringValue]));
  const deferredSpan = startSpans.map(attrsOf).find((a) => Number(a["stillfail.db_deferred"]) === 1);
  assert.ok(deferredSpan, "core.start span should record stillfail.db_deferred = 1");
  for (const key of ["stillfail.ms.db_device", "stillfail.ms.db_open", "stillfail.ms.db_ensure", "stillfail.ms.db_import"]) {
    assert.ok(key in deferredSpan, `core.start span should include ${key}`);
  }
});

test("B0: close and sign-out races while deferred account is still pending are safe", async () => {
  // Case 1: Core.close() while deferred account is blocked in openDb.
  {
    const { host } = setupTwoAccountHost();
    host.store("device/choice", { workspaceOwners: { ws1: "s1", ws2: "s2" } });
    const gateS1 = Deferred.makeUnsafe<void>();
    const origOpenDb = host.openDb.bind(host);
    host.openDb = (name: string): Effect.Effect<Sql, HostError> =>
      Effect.gen(function* () {
        if (name === dbName("s1")) yield* Deferred.await(gateS1);
        return yield* origOpenDb(name);
      });
    const core = await Core.create(host, { sample: 0, clock: host.time.clock });
    assert.equal(core.inner.data.db("s1"), undefined);
    await core.close();
    Deferred.doneUnsafe(gateS1, Effect.void);
    await host.settle();
    assert.equal(core.inner.data.db("s1"), undefined, "closed core must not register deferred db after close");
  }

  // Case 2: Sign-out of deferred account before deferred open runs.
  {
    const { host } = setupTwoAccountHost();
    host.store("device/choice", { workspaceOwners: { ws1: "s1", ws2: "s2" } });
    const openedNames: string[] = [];
    const gateS1 = Deferred.makeUnsafe<void>();
    const origOpenDb = host.openDb.bind(host);
    host.openDb = (name: string): Effect.Effect<Sql, HostError> =>
      Effect.gen(function* () {
        openedNames.push(name);
        if (name === dbName("s1")) yield* Deferred.await(gateS1);
        return yield* origOpenDb(name);
      });
    const core = await Core.create(host, { sample: 0, clock: host.time.clock });
    // Sign out s1 immediately before deferred open finishes.
    await run(core.inner.data.accounts(["s2"]));
    Deferred.doneUnsafe(gateS1, Effect.void);
    await host.settle();
    assert.deepEqual(core.inner.data.dbs().map((d) => d.sub), ["s2"]);
    assert.equal(core.inner.data.db("s1"), undefined);
    await core.close();
  }
});

test("B1: steady-state AccountDb cold open performs zero write transactions while initializing all state and repairing downgrade mutations", async () => {
  const raw = new DatabaseSync(":memory:");
  const nodeSql = new NodeSql(raw, true);
  const counted = new CountingSql(nodeSql);
  const host = new FakeHost();
  const runner = new Runner(host.time.clock);

  // First open: creates schema and seeds representative data across tables.
  const first = new AccountDb("s1", "account-s1", counted, runner, chatDerive);
  first.putStationDoc("ws/st", "overview", { counts: { running: 1 }, connects: [], slackUsers: [], profiles: [{ id: "p1", name: "P1" }] }, 1000, null);
  first.setChats("ws/st", false, [{ id: "c1", title: "Hello", lastActiveAt: 1000, thread: 1, agents: [{ key: "a1", process: "idle" }] }], 1000);
  first.putMoved("ws/st", "sess-old", { station: "ws/st2", thread: 1, there: 2, at: 1000 });
  first.putLog("entry", "ws/st", "1", [[1, { kind: "message", authorKind: "person", text: "needle word", at: 1000 }]], null, false);
  first.putLog("transcript", "ws/st", "a1", [[0, { type: "text", text: "hi" }]], null, false);
  first.setDetail("ws/st", "a1", { key: "a1", extra: "detail" });
  first.evict("ws/st", "a1");
  first.kept.made(KEPT.listRow, { key: () => "k1", make: (_o, r) => ({ state: null, whole: r, sent: r }) });
  const chatRow = first.chat("ws/st", "c1");
  first.kept.keep(KEPT.listRow, ["ws/st", "c1"], chatRow, "k1", { state: null, whole: chatRow, sent: chatRow });
  await run(first.written);
  first.close();

  // Second open (steady state): MUST execute 0 BEGIN IMMEDIATE and 0 writes/DDL!
  counted.reset();
  const second = new AccountDb("s1", "account-s1", counted, runner, chatDerive);
  assert.equal(counted.beginImmediates(), 0, `expected 0 BEGIN IMMEDIATE on steady-state open, got: ${JSON.stringify(counted.execs)}`);
  assert.deepEqual(counted.ddlOrWrites(), [], `expected 0 DDL/write statements on steady-state open, got: ${JSON.stringify(counted.ddlOrWrites())}`);
  // Verify all in-memory states are properly initialized.
  assert.deepEqual(second.moved("ws/st", "sess-old"), { station: "ws/st2", thread: 1, there: 2, at: 1000 });
  assert.equal(second.evicted("transcript", "ws/st", "a1"), true);
  assert.equal(second.evicted("entry", "ws/st", "1"), false);
  assert.equal((second.overviewPart("ws/st") as J)?.running, 1);
  assert.equal((second.detail("ws/st", "a1") as J)?.extra, "detail");
  assert.equal(second.findSaid(["ws/st"], ["needle"], 10).length, 1);
  second.kept.made(KEPT.listRow, { key: () => "k1", make: (_o, r) => ({ state: null, whole: r, sent: r }) });
  assert.equal(second.kept.keeps(KEPT.listRow), true);
  assert.ok(second.kept.one(KEPT.listRow, ["ws/st", "c1"], "k1") !== undefined);
  second.close();

  // Simulate older-core downgrade mutations WITHOUT touching PRAGMA schema_version:
  // 1) meta['kept chat_row'] changed to an older version
  // 2) chat row updated with made = NULL
  // 3) log_use has kind='entry', evicted=1
  const schemaBefore = raw.prepare("PRAGMA schema_version").get() as { schema_version: number };
  raw.prepare("UPDATE meta SET value = '1' WHERE key = 'kept chat_row'").run();
  raw.prepare("UPDATE chat SET made = NULL, state = NULL WHERE station = 'ws/st' AND id = 'c1'").run();
  raw.prepare("INSERT OR REPLACE INTO log_use (kind, station, id, opened, evicted) VALUES ('entry', 'ws/st', '1', 1000, 1)").run();
  const schemaAfter = raw.prepare("PRAGMA schema_version").get() as { schema_version: number };
  assert.equal(schemaAfter.schema_version, schemaBefore.schema_version, "downgrade simulation must not change schema_version");

  counted.reset();
  const third = new AccountDb("s1", "account-s1", counted, runner, chatDerive);
  // 1) kept chat_row cleared and meta restored
  assert.equal(raw.prepare("SELECT value FROM meta WHERE key = 'kept chat_row'").get()?.value, String(KEPT.listRow.making));
  assert.equal(raw.prepare("SELECT count(*) AS n FROM chat_row").get()?.n, 0, "stale chat_row rows must be cleared");
  // 2) unmade chat row detected and backfilled
  assert.equal(third.chatColumnsMade?.rows, 1);
  assert.equal(raw.prepare("SELECT made FROM chat WHERE station = 'ws/st' AND id = 'c1'").get()?.made, CHAT_MADE);
  // 3) evicted entry log_use reset to 0 while transcript eviction stays
  assert.equal(third.evicted("entry", "ws/st", "1"), false);
  assert.equal(raw.prepare("SELECT evicted FROM log_use WHERE kind = 'entry' AND station = 'ws/st' AND id = '1'").get()?.evicted, 0);
  assert.equal(third.evicted("transcript", "ws/st", "a1"), true);
  third.close();
  runner.shutdown();
  raw.close();
});
