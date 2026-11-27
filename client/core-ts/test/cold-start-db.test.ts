// Cold-start database optimizations:
// - B0: active-first multi-account DB open with sign-in order preserved and close/sign-out race safety
// - B1: core.start DB breakdown trace attributes + read-only-first AccountDb cold open (0 write transactions on steady
//   state, full downgrade/DML repair even when schema_version is unchanged)
import assert from "node:assert/strict";
import { test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { Deferred, Effect, Fiber } from "effect";
import { Accounts, STORAGE_KEY, type StoredAccount } from "../src/accounts.ts";
import { COMMA_ACCOUNT_KEY, COMMA_PENDING_SIGNOUT_KEY, COMMA_SESSION_KEY, commaAccountProvider } from "../src/comma.ts";
import { Core } from "../src/core.ts";
import { Data, dbName } from "../src/data.ts";
import { AccountDb } from "../src/db/account.ts";
import { KEPT } from "../src/db/kept.ts";
import { CHAT_MADE } from "../src/db/schema.ts";
import { HostError, SqlError, type Sql, type SqlRow, type SqlValue } from "../src/host.ts";
import { NodeSql } from "../src/hosts/node-sql.ts";
import { Signer } from "../src/lock.ts";
import { Runner } from "../src/runtime.ts";
import { FakeHost, jsonResponse } from "../src/testing.ts";
import { parseJson } from "../src/util.ts";
import { chatDerive } from "../src/views/views.ts";
import { answers, apply, call } from "./helpers.ts";
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
  first.inner.data.db("s2")!.setChats("ws2/st2", false, [{ id: "c1", session: "c1", title: "Primary Chat", agents: [], unread: false, lastActiveAt: 1000, thread: 1 }], 1000);
  await run(first.inner.data.written);
  assert.deepEqual(first.inner.data.device.get("choice", "workspaceOwners"), { ws1: "s1", "ws-both": "s1", ws2: "s2" });
  await first.close();

  // Cold start #2: gate s1's DB open behind a Deferred while s2 opens immediately.
  const gateS1 = Deferred.makeUnsafe<void>();
  const s1OpenStarted = Deferred.makeUnsafe<void>();
  const s1OpenFinished = Deferred.makeUnsafe<void>();
  const origOpenDb = host.openDb.bind(host);
  const openOrder: string[] = [];
  host.openDb = (name: string): Effect.Effect<Sql, HostError> =>
    Effect.gen(function* () {
      openOrder.push(name);
      if (name === dbName("s1")) {
        Deferred.doneUnsafe(s1OpenStarted, Effect.void);
        yield* Deferred.await(gateS1);
      }
      const sql = yield* origOpenDb(name);
      if (name === dbName("s1")) Deferred.doneUnsafe(s1OpenFinished, Effect.void);
      return sql;
    });

  const second = await Core.create(host, { sample: 1, reports: true, clock: host.time.clock });
  // Core.create finished without waiting for s1, AND s1 has not even started opening before first chats emit!
  assert.ok(second.inner.data.db("s2") !== undefined, "active account s2 is open immediately");
  assert.equal(second.inner.data.db("s1"), undefined, "non-active account s1 is still deferred");
  assert.equal(second.inner.data.isDeferred("s1"), true);
  assert.equal(second.inner.workspaces.owner("ws2"), "s2");
  // Shared workspace ws-both must NOT provisionally flip to later account s2 while earlier s1 is deferred.
  assert.notEqual(second.inner.workspaces.owner("ws-both"), "s2", "must not provisionally assign shared ws-both to s2");
  assert.equal((second.inner.data.shared({ topic: "workspace", workspace: "ws2" }) as J)?.name, "WS 2");
  assert.equal((second.inner.data.chat("ws2/st2", "c1") as J)?.title, "Primary Chat");
  // Token refresh (`accounts.onChange`) with same account list must NOT prematurely open deferred s1!
  await run(second.inner.data.accounts(["s1", "s2"]));
  assert.equal(second.inner.data.isDeferred("s1"), true, "token refresh must keep s1 deferred");
  assert.equal(second.inner.data.db("s1"), undefined);

  // Subscribing to primary chats emits first chats value and triggers deferred open deterministically.
  const ui = second.connect();
  second.receive(ui, { kind: "subscribe", id: 1, subscribe: { topic: "chats", scope: "ws2", mine: false, watching: false, hidden: false } });
  await Effect.runPromise(Deferred.await(s1OpenStarted));
  Deferred.doneUnsafe(gateS1, Effect.void);
  await Effect.runPromise(Deferred.await(s1OpenFinished));
  await host.settle();
  assert.ok(second.inner.data.db("s1") !== undefined, "deferred account s1 opened in background");
  assert.equal(second.inner.data.hasDeferred(), false);
  // Strict sign-in order preserved even though s2 opened before s1!
  assert.deepEqual(second.inner.data.dbs().map((d) => d.sub), ["s1", "s2"]);
  assert.deepEqual(second.inner.data.mes().map(([sub]) => sub), ["s1", "s2"]);
  assert.equal(second.inner.workspaces.owner("ws-both"), "s1", "sign-in order ownership preserved for shared workspace");
  assert.equal(openOrder.filter((n) => n.startsWith("account-"))[0], dbName("s2"), "s2 opened first");

  // Also verify client.metric accepts `expired` boolean attribute on first_page spans.
  second.receive(ui, {
    kind: "call",
    id: 2,
    call: "client.metric",
    params: { kind: "first_page", duration_ms: 1100, attrs: { in_view_ms: 800, waited: true, expired: true } },
  });
  await host.settle();

  // Advance test clock past START_TOLD_MS + EXPORT_MS so core.start & app.first_page export to /v1/telemetry/traces.
  await host.time.pass(35_000);
  await second.close();
  // Verify core.start span recorded DB breakdown and db_deferred=1, and app.first_page recorded expired=true.
  const startSpans = spans.filter((s) => s.name === "core.start");
  const attrsOf = (sp: J) => Object.fromEntries((sp.attributes ?? []).map((a: J) => [a.key, a.value.intValue ?? a.value.doubleValue ?? a.value.boolValue ?? a.value.stringValue]));
  const deferredSpan = startSpans.map(attrsOf).find((a) => Number(a["stillfail.db_deferred"]) === 1);
  assert.ok(deferredSpan, "core.start span should record stillfail.db_deferred = 1");
  for (const key of ["stillfail.ms.db_device", "stillfail.ms.db_open", "stillfail.ms.db_ensure", "stillfail.ms.db_import"]) {
    assert.ok(key in deferredSpan, `core.start span should include ${key}`);
  }
  const firstPageSpan = spans.filter((s) => s.name === "app.first_page").map(attrsOf).find((a) => a["stillfail.expired"] === true);
  assert.ok(firstPageSpan, "app.first_page span must retain allowlisted stillfail.expired=true attribute");
});

test("B0: close, sign-out all, sign-out deferred/in-flight, and mid-import sign-out races are safe", async () => {
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

  // Case 2: Sign-out of deferred account before deferred open runs calls deleteDb AND onSignedOut(sub, me).
  {
    const { host } = setupTwoAccountHost();
    // Seed s1's DB with cached `me` first so sign-out while unopened still reads `me` and deletes the DB.
    const seed = await Core.create(host, { sample: 0, clock: host.time.clock });
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    seed.inner.cloudSync.recomputeOwners();
    await run(seed.inner.data.written);
    await seed.close();

    const deleted: string[] = [];
    const origDeleteDb = host.deleteDb.bind(host);
    host.deleteDb = (name: string) => {
      deleted.push(name);
      return origDeleteDb(name);
    };
    const core = await Core.create(host, { sample: 0, clock: host.time.clock });
    assert.equal(core.inner.data.isDeferred("s1"), true);
    const signedOut: Array<[string, unknown]> = [];
    const prevOnSignedOut = core.inner.data.onSignedOut;
    core.inner.data.onSignedOut = (sub, me) => {
      signedOut.push([sub, me]);
      return prevOnSignedOut(sub, me);
    };
    await run(core.inner.data.accounts(["s2"]));
    assert.deepEqual(core.inner.data.dbs().map((d) => d.sub), ["s2"]);
    assert.equal(core.inner.data.db("s1"), undefined);
    assert.equal(core.inner.data.isDeferred("s1"), false);
    assert.ok(deleted.includes(dbName("s1")), "signing out deferred account must delete its DB");
    assert.equal(signedOut.length, 1);
    assert.equal(signedOut[0]![0], "s1");
    assert.equal((signedOut[0]![1] as J)?.user?.sub, "s1", "onSignedOut must receive cached me of deferred account");
    await core.close();
  }

  // Case 3: accounts([]) sign-out all during in-flight open must not leak or fall back to unrestricted order.
  {
    const { host } = setupTwoAccountHost();
    host.store("device/choice", { workspaceOwners: { ws1: "s1", ws2: "s2" } });
    const gateS1 = Deferred.makeUnsafe<void>();
    const s1Started = Deferred.makeUnsafe<void>();
    const origOpenDb = host.openDb.bind(host);
    host.openDb = (name: string): Effect.Effect<Sql, HostError> =>
      Effect.gen(function* () {
        if (name === dbName("s1")) {
          Deferred.doneUnsafe(s1Started, Effect.void);
          yield* Deferred.await(gateS1);
        }
        return yield* origOpenDb(name);
      });
    const core = await Core.create(host, { sample: 0, clock: host.time.clock });
    // Trigger deferred open of s1 and block inside openDb.
    const openFiber = Effect.runFork(core.inner.data.openAccount("s1"));
    await Effect.runPromise(Deferred.await(s1Started));
    // Sign out ALL accounts while s1 is in-flight.
    const signOutPromise = run(core.inner.data.accounts([]));
    Deferred.doneUnsafe(gateS1, Effect.void);
    await signOutPromise;
    await Effect.runPromise(Fiber.await(openFiber));
    assert.deepEqual(core.inner.data.dbs(), [], "dbs() must be empty after accounts([])");
    assert.equal(core.inner.data.db("s1"), undefined);
    assert.equal(core.inner.data.db("s2"), undefined);
    assert.equal(core.inner.data.hasDeferred(), false);
    await core.close();
  }

  // Case 4: Mid-onOpened (importFormer) sign-out must NOT close the DB under onOpened's feet.
  {
    const host = new FakeHost();
    const runner = new Runner(host.time.clock);
    const data = new Data(host, runner, { owner: () => null, derive: chatDerive });
    await run(data.loadDevice());
    const inImport = Deferred.makeUnsafe<void>();
    const resumeImport = Deferred.makeUnsafe<void>();
    let readAfterSignOutOk = false;
    data.onOpened = (db) =>
      Effect.gen(function* () {
        Deferred.doneUnsafe(inImport, Effect.void);
        yield* Deferred.await(resumeImport);
        // Must still be open until onOpened finishes (no "DB closed: all").
        db.accountDoc("me");
        readAfterSignOutOk = true;
      });
    const opening = run(data.accounts(["s1"]));
    await Effect.runPromise(Deferred.await(inImport));
    const signingOut = run(data.accounts([]));
    Deferred.doneUnsafe(resumeImport, Effect.void);
    await Promise.all([opening, signingOut]);
    assert.equal(readAfterSignOutOk, true, "onOpened must finish before removed DB is closed");
    assert.equal(data.db("s1"), undefined);
    data.closing();
    runner.shutdown();
    await runner.run(data.device.close());
  }
});

test("B0: on-demand owner(ws) opens deferred account without /v1/me and resumes its sending outbox", async () => {
  const { host } = setupTwoAccountHost();
  // Seed both accounts + a pending `sending` outbox row in s1's DB.
  const seed = await Core.create(host, { sample: 0, clock: host.time.clock });
  seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-both", name: "Both" }] });
  seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-both", name: "Both" }] });
  seed.inner.cloudSync.recomputeOwners();
  seed.inner.data.db("s1")!.setChats("ws1/st1", false, [{ id: "c-s1", title: "S1 Chat", lastActiveAt: 1000, thread: 7 }], 1000);
  seed.inner.data.putLocal("outbox", "ws1/st1", "7", [{
    id: "out-1",
    text: "queued while offline",
    at: 1000,
    state: "sending",
    uploads: [],
  }]);
  await run(seed.inner.data.written);
  await seed.close();

  let meCalls = 0;
  const origFetch = host.fetch.bind(host);
  host.fetch = (req) => {
    if (req.url.endsWith("/v1/me")) meCalls++;
    return origFetch(req);
  };

  const delivered = Deferred.makeUnsafe<[string, number, string]>();
  const core = await Core.create(host, { sample: 0, clock: host.time.clock });
  const origDeliver = core.inner.viewCalls.deliver.bind(core.inner.viewCalls);
  core.inner.viewCalls.deliver = (station, thread, id, ctx, retry, trace) => {
    Deferred.doneUnsafe(delivered, Effect.succeed([station, thread, id]));
    return origDeliver(station, thread, id, ctx, retry, trace);
  };
  assert.equal(core.inner.data.isDeferred("s1"), true);
  // Asking cloudSync.owner("ws-both") must open s1 on demand and return "s1" without calling /v1/me!
  const meCallsBefore = meCalls;
  const owner = await run(core.inner.cloudSync.owner("ws-both"));
  assert.equal(owner, "s1", "on-demand owner lookup must open deferred s1 and return s1");
  assert.equal(meCalls, meCallsBefore, "on-demand owner lookup must resolve from s1's local DB without /v1/me");
  assert.ok(core.inner.data.db("s1") !== undefined);
  // Verify viewCalls.resumeFor(db) resumed s1's sending outbox entry!
  const resumed = await Effect.runPromise(Deferred.await(delivered));
  assert.deepEqual(resumed, ["ws1/st1", 7, "out-1"], "deferred s1 outbox must be resumed after deferred open");
  await core.close();
});

test("B1: Signer.load coalesces legacy plain-file cleanup and retries after storageDelete error", async () => {
  const host = new FakeHost();
  host.appKeys = true;
  const seed = new Uint8Array(32).fill(7);
  await run(host.secureSet!(Signer.KEY, seed, { user: false }));
  let deleteCalls = 0;
  let failNext = true;
  const gateDelete = Deferred.makeUnsafe<void>();
  const deleteStarted = Deferred.makeUnsafe<void>();
  host.storageDelete = () =>
    Effect.gen(function* () {
      deleteCalls++;
      if (deleteCalls === 1) {
        Deferred.doneUnsafe(deleteStarted, Effect.void);
        yield* Deferred.await(gateDelete);
      }
      if (failNext) {
        failNext = false;
        return yield* Effect.fail(new HostError("transient delete failure"));
      }
    });

  // Two concurrent loads must coalesce into a single storageDelete call.
  const [a, b] = await Promise.all([run(Signer.load(host)), run(Signer.load(host))]);
  assert.ok(a && b && a.id === b.id);
  await Effect.runPromise(Deferred.await(deleteStarted));
  assert.equal(deleteCalls, 1, "concurrent Signer.load calls must coalesce legacy cleanup");
  // Let the first cleanup fail -> #cleaned must stay unset so a later load retries!
  Deferred.doneUnsafe(gateDelete, Effect.void);
  await host.settle();
  const c = await run(Signer.load(host));
  assert.ok(c);
  await host.settle();
  assert.equal(deleteCalls, 2, "failed legacy cleanup must retry on next Signer.load");
  // Now that cleanup succeeded, subsequent load must not call storageDelete again.
  await run(Signer.load(host));
  await host.settle();
  assert.equal(deleteCalls, 2, "succeeded legacy cleanup must not repeat");
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

  // P1-3: Dropping a station_part trigger with a stale row in station_part must rebuild station_part on reopen.
  raw.exec("DROP TRIGGER station_part_set");
  raw.prepare("INSERT OR REPLACE INTO station_part (address, part) VALUES ('ws/stale', '{\"running\":99,\"connects\":[],\"slackUsers\":[]}')").run();
  const fourth = new AccountDb("s1", "account-s1", counted, runner, chatDerive);
  assert.equal(fourth.overviewPart("ws/stale"), undefined, "stale station_part row must be rebuilt when trigger was missing");
  assert.equal((fourth.overviewPart("ws/st") as J)?.running, 1, "valid station_part row must be rebuilt from doc");
  fourth.close();
  runner.shutdown();
  raw.close();
});

test("R2 regressions: caller cancel safety, serialized delete/re-sign-in, verified shared-ws writes/drafts, busy credential cleanup, onFirstChats filter, runner-owned signer cleanup", async () => {
  // 1) P0-1: Cancelling caller 1 of openAccount while blocked in IO must NOT abort the open or clear isDeferred prematurely.
  {
    const { host } = setupTwoAccountHost();
    host.store("device/choice", { workspaceOwners: { ws1: "s1", ws2: "s2" } });
    const gateS1 = Deferred.makeUnsafe<void>();
    const s1Started = Deferred.makeUnsafe<void>();
    const origOpenDb = host.openDb.bind(host);
    host.openDb = (name: string): Effect.Effect<Sql, HostError> =>
      Effect.gen(function* () {
        if (name === dbName("s1")) {
          Deferred.doneUnsafe(s1Started, Effect.void);
          yield* Deferred.await(gateS1);
        }
        return yield* origOpenDb(name);
      });
    const core = await Core.create(host, { clock: host.time.clock });
    const f1 = core.inner.runner.fork(core.inner.data.openAccount("s1"));
    await Effect.runPromise(Deferred.await(s1Started));
    const f2 = core.inner.runner.fork(core.inner.data.openAccount("s1"));
    core.inner.runner.interrupt(f1);
    await host.settle();
    assert.equal(core.inner.data.isDeferred("s1"), true, "cancelling caller 1 must not clear isDeferred while IO is in flight");
    Deferred.doneUnsafe(gateS1, Effect.void);
    const db2 = await Effect.runPromise(Fiber.join(f2));
    assert.ok(db2 !== undefined, "caller 2 must receive the live AccountDb once IO completes");
    assert.ok(core.inner.data.db("s1") !== undefined, "s1 must be published in Data");
    assert.equal(core.inner.data.isDeferred("s1"), false);
    await core.close();
  }

  // 2) P0-2: Slow deleteDb on sign-out must complete strictly BEFORE re-sign-in opens the same DB filename.
  {
    const { host } = setupTwoAccountHost();
    const core = await Core.create(host, { clock: host.time.clock });
    const events: string[] = [];
    const delGate = Deferred.makeUnsafe<void>();
    const delStarted = Deferred.makeUnsafe<void>();
    const origDelete = host.deleteDb.bind(host);
    const origOpen = host.openDb.bind(host);
    host.deleteDb = (name: string) =>
      Effect.gen(function* () {
        if (name === dbName("s2")) {
          events.push("delete:start");
          Deferred.doneUnsafe(delStarted, Effect.void);
          yield* Deferred.await(delGate);
        }
        const r = yield* origDelete(name);
        if (name === dbName("s2")) events.push("delete:end");
        return r;
      });
    host.openDb = (name: string) =>
      Effect.gen(function* () {
        if (name === dbName("s2")) events.push("open:start");
        return yield* origOpen(name);
      });
    // Sign out s2 -> blocks in deleteDb.
    const signOutFiber = core.inner.runner.fork(core.inner.data.accounts(["s1"]));
    await Effect.runPromise(Deferred.await(delStarted));
    // Re-sign-in s2 while deleteDb is still running.
    const reSignInFiber = core.inner.runner.fork(core.inner.data.accounts(["s1", "s2"]));
    await host.settle();
    assert.deepEqual(events, ["delete:start"], "re-sign-in openDb must wait until old deleteDb completes");
    Deferred.doneUnsafe(delGate, Effect.void);
    await Effect.runPromise(Fiber.join(signOutFiber));
    await Effect.runPromise(Fiber.join(reSignInFiber));
    assert.deepEqual(events, ["delete:start", "delete:end", "open:start"], "strict delete -> open serialization");
    assert.ok(core.inner.data.db("s2") !== undefined, "re-signed-in s2 DB must be open and intact");
    await core.close();
  }

  // 3) P0-3 & P0-4: Stale workspaceOwners cache pointing shared ws-both to s2 must NOT route owner/draft writes to s2,
  //    and drafts saved while s1 is deferred survive flush and Core restart.
  {
    const { host } = setupTwoAccountHost();
    // Seed s1 & s2 DBs so both list ws-both; then corrupt device/choice cache to claim ws-both -> s2.
    const first = await Core.create(host, { clock: host.time.clock });
    first.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-both", name: "Both" }] });
    first.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-both", name: "Both" }] });
    await run(first.inner.data.written);
    first.inner.data.device.put("choice", "workspaceOwners", { ws1: "s1", ws2: "s2", "ws-both": "s2" });
    await first.close();

    const second = await Core.create(host, { clock: host.time.clock });
    assert.equal(second.inner.data.isDeferred("s1"), true, "s1 starts deferred");
    // owner("ws-both") must verify against earlier deferred s1 and return "s1", NOT stale "s2".
    const verifiedOwner = await run(second.inner.cloudSync.owner("ws-both"));
    assert.equal(verifiedOwner, "s1", "stale cache must never authorize writes to later account s2");

    // Save draft on ws-both/st-shared via draftPut while s1 is deferred (fresh core #3 with accurate cache too).
    await second.close();
    const third = await Core.create(host, { clock: host.time.clock });
    assert.equal(third.inner.data.isDeferred("s1"), true, "s1 starts deferred on restart");
    const ui = third.connect();
    let putRes: J = null;
    const origEmit = third.inner.host.emit.bind(third.inner.host);
    const putDone = Deferred.makeUnsafe<void>();
    third.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 10 && ("ok" in m || "error" in m)) {
        putRes = "ok" in m ? m.ok : m;
        Deferred.doneUnsafe(putDone, Effect.void);
      }
    };
    third.receive(ui, { kind: "call", id: 10, call: "draft.put", params: { station: "ws-both/st1", chat: "new", text: "precious draft", quotes: [], files: [] } });
    await Effect.runPromise(Deferred.await(putDone));
    assert.ok(typeof putRes?.id === "string" && putRes.id.length > 0, `draftPut returns valid id, got: ${JSON.stringify(putRes)}`);
    await host.time.pass(350);
    await run(third.inner.data.written);
    await third.close();

    // Reopen fresh Core #4 and assert draft persisted in s1's SQLite DB!
    const fourth = await Core.create(host, { clock: host.time.clock });
    await run(fourth.inner.cloudSync.ensureVerifiedOwner("ws-both"));
    assert.equal(fourth.inner.composers.readDraft("ws-both/st1", "new").text, "precious draft", "draft must survive restart");
    await fourth.close();
  }

  // 4) P1-1: Sign-out removes stored credentials even when openDb returns busy for deferred account.
  {
    const { host } = setupTwoAccountHost();
    host.store("device/choice", { workspaceOwners: { ws1: "s1", ws2: "s2" }, "credWorkspaces/s1": ["ws-extra"] });
    host.store("credential/s1/ws1", { device: "d1", token: "secret1", issued_at: 1, expires_at: 9999999999 });
    host.store("credential/s1/ws-extra", { device: "d1", token: "secret2", issued_at: 1, expires_at: 9999999999 });
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      name === dbName("s1") ? Effect.fail(new HostError("SQLITE_BUSY")) : origOpen(name);
    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.accounts(["s2"]));
    await host.settle();
    assert.equal(host.stored("credential/s1/ws1"), undefined, "workspaceOwners-indexed credential deleted despite busy DB");
    assert.equal(host.stored("credential/s1/ws-extra"), undefined, "credWorkspaces-indexed credential deleted despite busy DB");
    await core.close();
  }

  // 5) P1-3: Subscribing to a non-active workspace's chats must NOT prematurely trigger deferred DB opening.
  {
    const { host } = setupTwoAccountHost();
    host.store("device/choice", { workspaceOwners: { ws1: "s1", ws2: "s2" } });
    const core = await Core.create(host, { clock: host.time.clock });
    assert.equal(core.inner.data.isDeferred("s1"), true);
    const ui = core.connect();
    // Subscribe to another workspace "ws-other" (not active "ws2").
    core.receive(ui, { kind: "subscribe", id: 1, subscribe: { topic: "chats", scope: "ws-other", filter: "all" } });
    await host.settle();
    assert.equal(core.inner.data.isDeferred("s1"), true, "non-active workspace chats must not prematurely open deferred s1");
    await core.close();
  }

  // 6) P1-5: Signer.load background cleanup bound to Runner is interrupted cleanly when runner shuts down.
  {
    const host = new FakeHost();
    host.appKeys = true;
    const seed = new Uint8Array(32).fill(7);
    const sealedStore = new Map<string, Uint8Array>([["lock-signer", seed]]);
    host.secureGet = (k) => Effect.succeed(sealedStore.get(k) ?? null);
    host.secureSet = (k, v) => Effect.sync(() => void sealedStore.set(k, v));
    host.store("lock-signer", seed);
    const gate = Deferred.makeUnsafe<void>();
    let completed = false;
    host.storageDelete = () =>
      Effect.gen(function* () {
        yield* Deferred.await(gate);
        completed = true;
      });
    const runner = new Runner();
    Signer.bindRunner(host, runner);
    const loaded = await Effect.runPromise(Signer.load(host));
    assert.ok(loaded !== null);
    runner.shutdown();
    Deferred.doneUnsafe(gate, Effect.void);
    await host.settle();
    assert.equal(completed, false, "runner.shutdown() must interrupt pending Signer.load cleanup fiber");
  }
});

test("R3 regressions: composer.text verified routing/close/sign-out, sole-caller cancel outbox resume, deferred workspace+feedback sync, durable credential delete queue", async () => {
  // 1) P0-1: composer.text(key="new:ws-both") with stale cache pointing to s2 must verify owner -> write to s1 (never s2),
  //    survive immediate Core.close(), and never leak pending drafts into s2 if s1 signs out.
  {
    const { host } = setupTwoAccountHost();
    const first = await Core.create(host, { clock: host.time.clock });
    first.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-both", name: "Both" }] });
    first.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-both", name: "Both" }] });
    await run(first.inner.data.written);
    // Corrupt cache so ws-both points to later account s2 while s1 is earlier & deferred.
    first.inner.data.device.put("choice", "workspaceOwners", { ws1: "s1", ws2: "s2", "ws-both": "s2" });
    await first.close();

    const second = await Core.create(host, { clock: host.time.clock });
    assert.equal(second.inner.data.isDeferred("s1"), true, "s1 starts deferred");
    const ui = second.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = second.inner.host.emit.bind(second.inner.host);
    second.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 101 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    second.receive(ui, { kind: "call", id: 101, call: "composer.text", params: { key: "new:ws-both", text: "from-composer-verified" } });
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res, `composer.text succeeded: ${JSON.stringify(res)}`);
    await host.time.pass(350);
    await run(second.inner.data.written);
    // Must be in s1's SQLite DB and NEVER in s2's DB.
    assert.equal(second.inner.data.db("s2")!.draft("ws-both", "new"), undefined, "s2 DB must NOT receive shared workspace draft");
    assert.equal((second.inner.data.db("s1")!.draft("ws-both", "new") as J)?.text, "from-composer-verified", "s1 DB holds verified draft");
    await second.close();

    // Restart and confirm draft survives restart.
    const third = await Core.create(host, { clock: host.time.clock });
    await run(third.inner.cloudSync.ensureVerifiedOwner("ws-both"));
    assert.equal(third.inner.composers.readDraft("ws-both", "new").text, "from-composer-verified", "draft survives restart");
    await third.close();

    // Subcase 1b: Accurate cache -> composer.text followed by IMMEDIATE Core.close() (before 300ms debounce) still persists to s1!
    const fourth = await Core.create(host, { clock: host.time.clock });
    assert.equal(fourth.inner.data.isDeferred("s1"), true);
    const ui4 = fourth.connect();
    const ack4 = Deferred.makeUnsafe<J>();
    const origEmit4 = fourth.inner.host.emit.bind(fourth.inner.host);
    fourth.inner.host.emit = (c, m) => {
      origEmit4(c, m);
      if (m.id === 102 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack4, Effect.succeed(m));
    };
    fourth.receive(ui4, { kind: "call", id: 102, call: "composer.text", params: { key: "new:ws-both", text: "close-immediately" } });
    await Effect.runPromise(Deferred.await(ack4));
    await fourth.close();
    const fifth = await Core.create(host, { clock: host.time.clock });
    await run(fifth.inner.cloudSync.ensureVerifiedOwner("ws-both"));
    assert.equal(fifth.inner.composers.readDraft("ws-both", "new").text, "close-immediately", "immediate close persists composer draft");
    await fifth.close();

    // Subcase 1c: Direct buffered pending draft while s1 deferred must NOT flush into s2 if s1 signs out.
    const sixth = await Core.create(host, { clock: host.time.clock });
    assert.equal(sixth.inner.data.isDeferred("s1"), true);
    sixth.inner.data.set({ topic: "draft", station: "ws-both", chat: "new" }, { text: "s1-secret-draft", quotes: [], files: [] }, false);
    await run(sixth.inner.data.accounts(["s2"]));
    sixth.inner.cloudSync.recomputeOwners();
    await run(sixth.inner.data.written);
    assert.equal(sixth.inner.data.db("s2")!.draft("ws-both", "new"), undefined, "signing out s1 must discard its pending draft rather than flushing to s2");
    await sixth.close();
  }

  // 2) P0-2: Cancelling the SOLE on-demand caller of cloudSync.owner(ws1) mid-IO still publishes s1 AND resumes its outbox.
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    seed.inner.cloudSync.recomputeOwners();
    seed.inner.data.db("s1")!.setChats("ws1/st1", false, [{ id: "c-s1", session: "c-s1", title: "S1 Chat", agents: [], unread: false, lastActiveAt: 1000, thread: 7 }], 1000);
    seed.inner.data.putLocal("outbox", "ws1/st1", "7", [{ id: "out-sole-cancel", text: "must deliver", at: 1000, state: "sending", uploads: [] }]);
    await run(seed.inner.data.written);
    await seed.close();

    const gateS1 = Deferred.makeUnsafe<void>();
    const s1Started = Deferred.makeUnsafe<void>();
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      Effect.gen(function* () {
        if (name === dbName("s1")) {
          Deferred.doneUnsafe(s1Started, Effect.void);
          yield* Deferred.await(gateS1);
        }
        return yield* origOpen(name);
      });
    const delivered = Deferred.makeUnsafe<[string, number, string]>();
    const core = await Core.create(host, { clock: host.time.clock });
    const origDeliver = core.inner.viewCalls.deliver.bind(core.inner.viewCalls);
    core.inner.viewCalls.deliver = (station, thread, id, ctx, retry, trace) => {
      Deferred.doneUnsafe(delivered, Effect.succeed([station, thread, id]));
      return origDeliver(station, thread, id, ctx, retry, trace);
    };
    assert.equal(core.inner.data.isDeferred("s1"), true);
    const soleCaller = core.inner.runner.fork(core.inner.cloudSync.owner("ws1"));
    await Effect.runPromise(Deferred.await(s1Started));
    core.inner.runner.interrupt(soleCaller);
    await host.settle();
    // Release disk IO BEFORE the 1200ms fallback deadline: account-owned onPublished must still resume outbox!
    Deferred.doneUnsafe(gateS1, Effect.void);
    const resumed = await Effect.runPromise(Deferred.await(delivered));
    assert.deepEqual(resumed, ["ws1/st1", 7, "out-sole-cancel"], "outbox must resume even when sole on-demand caller was cancelled");
    await core.close();
  }

  // 3) P1-1 / Opus P1-C: Exclusive workspace ws2 on active account #2 (s2) skipped while earlier s1 is deferred
  //    MUST replay GET /v1/workspaces/ws2 and GET /v1/workspaces/ws2/feedback exactly once after s1 opens.
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    seed.inner.cloudSync.recomputeOwners();
    await run(seed.inner.data.written);
    await seed.close();

    let ws2Fetches = 0;
    let ws2FeedbackFetches = 0;
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      if (req.url.endsWith("/v1/workspaces/ws2")) ws2Fetches++;
      if (req.url.endsWith("/v1/workspaces/ws2/feedback")) ws2FeedbackFetches++;
      return origFetch(req);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    assert.equal(core.inner.data.isDeferred("s1"), true);
    // Let s2's initial socket /v1/me finish while s1 is still deferred.
    await host.settle();
    assert.equal(ws2Fetches, 0, "ws2 fetch deferred while earlier s1 is unopened");
    assert.equal(ws2FeedbackFetches, 0, "ws2 feedback deferred while earlier s1 is unopened");
    // Advance past 1200ms fallback so s1 opens -> deferred ws2 syncs must replay once!
    await host.time.pass(1500);
    await host.settle();
    assert.equal(core.inner.data.isDeferred("s1"), false);
    assert.equal(ws2Fetches, 1, "ws2 workspace fetch must replay exactly once after s1 opens");
    assert.equal(ws2FeedbackFetches, 1, "ws2 feedback fetch must replay exactly once after s1 opens");
    assert.equal((core.inner.data.db("s2")!.workspace("ws2") as J)?.name, "WS 2", "s2 DB receives fetched ws2 details");
    await core.close();
  }

  // 4) P1-2 / Opus P2-2: Concurrent startup drain + sign-out failure never clobbers pending deletes, and Core.close()
  //    mid-delete preserves delete intent so next start removes the credential.
  {
    const { host } = setupTwoAccountHost();
    host.store("device/choice", {
      workspaceOwners: { ws1: "s1", ws2: "s2" },
      pendingCredentialDeletes: ["credential/s-old/ws-old"],
    });
    host.store("credential/s-old/ws-old", { device: "d0", token: "old", issued_at: 1, expires_at: 9999999999 });
    host.store("credential/s1/ws1", { device: "d1", token: "s1-tok", issued_at: 1, expires_at: 9999999999 });

    const oldGate = Deferred.makeUnsafe<void>();
    const oldStarted = Deferred.makeUnsafe<void>();
    let failS1 = true;
    const origDel = host.storageDelete.bind(host);
    host.storageDelete = (key: string) =>
      Effect.gen(function* () {
        if (key === "credential/s-old/ws-old") {
          Deferred.doneUnsafe(oldStarted, Effect.void);
          yield* Deferred.await(oldGate);
        }
        if (key === "credential/s1/ws1" && failS1) {
          return yield* Effect.fail(new HostError("transient delete fail"));
        }
        return yield* origDel(key);
      });

    const core = await Core.create(host, { clock: host.time.clock });
    await Effect.runPromise(Deferred.await(oldStarted));
    // Sign out s1 while old drain is paused, and fail s1's delete.
    await run(core.inner.data.accounts(["s2"]));
    await host.settle();
    // Release old drain: it must remove ONLY s-old and NEVER wipe s1's pending delete!
    Deferred.doneUnsafe(oldGate, Effect.void);
    await host.settle();
    const pendingAfter = core.inner.data.device.get("choice", "pendingCredentialDeletes") as string[];
    assert.ok(Array.isArray(pendingAfter) && pendingAfter.includes("credential/s1/ws1"), `s1 delete preserved: ${JSON.stringify(pendingAfter)}`);
    assert.ok(!pendingAfter.includes("credential/s-old/ws-old"), "completed old delete removed");
    await core.close();

    // Subcase 4b: Re-enable delete and restart; also test interrupting a fresh sign-out delete via Core.close().
    failS1 = false;
    const hangS2 = Deferred.makeUnsafe<void>();
    const s2DelStarted = Deferred.makeUnsafe<void>();
    host.store("credential/s2/ws2", { device: "d2", token: "s2-tok", issued_at: 1, expires_at: 9999999999 });
    host.storageDelete = (key: string) =>
      Effect.gen(function* () {
        if (key === "credential/s2/ws2") {
          Deferred.doneUnsafe(s2DelStarted, Effect.void);
          yield* Deferred.await(hangS2);
        }
        return yield* origDel(key);
      });
    const core2 = await Core.create(host, { clock: host.time.clock });
    await host.settle();
    assert.equal(host.stored("credential/s1/ws1"), undefined, "s1 credential drained on restart");
    // Sign out s2, let delete hang in host IO, then immediately close core2!
    await run(core2.inner.data.accounts([]));
    await Effect.runPromise(Deferred.await(s2DelStarted));
    await core2.close();
    Deferred.doneUnsafe(hangS2, Effect.void);
    // Restart core3 with normal storageDelete -> s2's pre-persisted delete intent MUST drain and remove credential/s2/ws2!
    host.storageDelete = origDel;
    const core3 = await Core.create(host, { clock: host.time.clock });
    await host.settle();
    assert.equal(host.stored("credential/s2/ws2"), undefined, "interrupted sign-out delete intent drained on restart");
    await core3.close();
  }
});

test("R4 regressions: composer.text sign-out during debounce or owner-wait never leaks into B, pending-delete credentials are unreadable and survive failed storageSet", async () => {
  // 1) P0 Subcase 1: composer.text accepted for A on shared ws-both -> A signs out within 300ms debounce -> B must NOT receive A's draft.
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-both", name: "Both" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-both", name: "Both" }] });
    seed.inner.cloudSync.recomputeOwners();
    await run(seed.inner.data.written);
    await seed.close();

    const core = await Core.create(host, { clock: host.time.clock });
    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 201 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 201, call: "composer.text", params: { key: "new:ws-both", text: "a-debounced-secret" } });
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res, `composer.text accepted for A: ${JSON.stringify(res)}`);
    // Sign out A within the 300ms debounce window before #soon flushes!
    await run(core.inner.data.accounts(["s2"]));
    core.inner.cloudSync.recomputeOwners();
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s2")!.draft("ws-both", "new"), undefined, "B DB must NEVER receive A's debounced draft after A signs out");
    await core.close();
  }

  // 2) P0 Subcase 2: composer.text awaiting ensureVerifiedOwner(ws-both) while A's openDb is paused -> A signs out -> call cancels and B never gets draft.
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-both", name: "Both" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-both", name: "Both" }] });
    seed.inner.cloudSync.recomputeOwners();
    await run(seed.inner.data.written);
    await seed.close();

    const gateS1 = Deferred.makeUnsafe<void>();
    const s1Started = Deferred.makeUnsafe<void>();
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      Effect.gen(function* () {
        if (name === dbName("s1")) {
          Deferred.doneUnsafe(s1Started, Effect.void);
          yield* Deferred.await(gateS1);
        }
        return yield* origOpen(name);
      });
    const core = await Core.create(host, { clock: host.time.clock });
    assert.equal(core.inner.data.isDeferred("s1"), true);
    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 202 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 202, call: "composer.text", params: { key: "new:ws-both", text: "a-waiting-secret" } });
    await Effect.runPromise(Deferred.await(s1Started));
    // Sign out A while composer.text is waiting in ensureVerifiedOwner!
    const signOut = run(core.inner.data.accounts(["s2"]));
    Deferred.doneUnsafe(gateS1, Effect.void);
    await signOut;
    core.inner.cloudSync.recomputeOwners();
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.equal(res.error?.code, "cancelled", `composer.text must cancel when A signs out mid-wait, got: ${JSON.stringify(res)}`);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s2")!.draft("ws-both", "new"), undefined, "B DB must NEVER receive draft from cancelled mid-wait edit");
    await core.close();
  }

  // 3) P1: Pending-delete credentials are unreadable (no cache hit on stale token), failed storageSet retains
  //    pendingCredentialDeletes, and replacing pending-delete `others` starts from [] without preserving old devices.
  {
    const { host } = setupTwoAccountHost();
    const nowS = Math.floor(host.nowMs() / 1000);
    const key = "credential/s2/ws2";
    const othersKey = `${key}/others`;
    host.store("device/choice", {
      workspaceOwners: { ws1: "s1", ws2: "s2" },
      pendingCredentialDeletes: [key, othersKey],
    });
    host.store(key, { device: "dev-main", credential: "stale-main-tok", issued_at: nowS, expires_at: nowS + 86400, relay_url: "https://relay.test" });
    host.store(othersKey, [{ device: "dev-old", credential: "stale-old-tok", issued_at: nowS, expires_at: nowS + 86400, relay_url: "https://relay.test" }]);

    let credCalls = 0;
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      if (req.url.includes("/credential")) {
        credCalls++;
        return Effect.succeed(jsonResponse(200, { credential: `fresh-tok-${credCalls}`, issued_at: nowS, expires_at: nowS + 86400, relay_url: "https://relay.test" }));
      }
      return origFetch(req);
    };
    const origDel = host.storageDelete.bind(host);
    const origSet = host.storageSet.bind(host);
    // Fail startup deletes so both keys remain pending delete.
    host.storageDelete = (k: string) =>
      k === key || k === othersKey ? Effect.fail(new HostError("delete failed")) : origDel(k);
    // Fail storageSet on primary `key` to verify pendingCredentialDeletes is preserved on write failure.
    let failMainSet = true;
    host.storageSet = (k: string, bytes: Uint8Array) =>
      k === key && failMainSet ? Effect.fail(new HostError("disk full")) : origSet(k, bytes);

    const core = await Core.create(host, { clock: host.time.clock });
    await host.settle();
    // Subcase 3a: Request main credential while `key` is pending delete and storageSet fails -> must fetch fresh AND keep pending delete!
    const cMain = await run(core.inner.cloudSync.credential("ws2", "dev-main", false, "dev-main"));
    assert.equal(cMain.credential, "fresh-tok-1", "must NOT return stale pending-delete main credential");
    assert.equal(credCalls, 1, "provider must be called instead of hitting stale pending-delete cache");
    const pendingAfterFail = core.inner.data.device.get("choice", "pendingCredentialDeletes") as string[];
    assert.ok(Array.isArray(pendingAfterFail) && pendingAfterFail.includes(key), "failed storageSet must preserve pendingCredentialDeletes");

    // Subcase 3b: Request `dev-old` (in pending-delete `othersKey`) -> must NOT hit cache; saving `dev-new` must replace `othersKey` with ONLY `[dev-new]`.
    const cOld = await run(core.inner.cloudSync.credential("ws2", "dev-old", false, "dev-main"));
    assert.equal(cOld.credential, "fresh-tok-2", "must NOT return stale pending-delete others credential");
    assert.equal(credCalls, 2);
    // Reset `othersKey` back to pending delete with `dev-old`, then save `dev-new`: must NOT keep `dev-old`!
    host.store(othersKey, [{ device: "dev-old", credential: "stale-old-tok", issued_at: nowS, expires_at: nowS + 86400, relay_url: "https://relay.test" }]);
    core.inner.data.device.put("choice", "pendingCredentialDeletes", [key, othersKey]);
    const cNew = await run(core.inner.cloudSync.credential("ws2", "dev-new", false, "dev-main"));
    assert.equal(cNew.credential, "fresh-tok-3");
    const storedOthers = JSON.parse(new TextDecoder().decode(host.stored(othersKey)!)) as Array<{ device: string; credential: string }>;
    assert.deepEqual(storedOthers.map((o) => o.device), ["dev-new"], "replacing pending-delete others must drop stale old devices");
    const pendingAfterOthers = core.inner.data.device.get("choice", "pendingCredentialDeletes") as string[];
    assert.ok(Array.isArray(pendingAfterOthers) && !pendingAfterOthers.includes(othersKey), "successful storageSet removes othersKey from pendingCredentialDeletes");
    assert.ok(pendingAfterOthers.includes(key), "unrelated failed key stays in pendingCredentialDeletes");
    failMainSet = false;
    await core.close();
  }
});

test("R5 regressions: unrelated sign-out keeps verified A draft, chat.send cancels on owner sign-out mid-wait, paused credential storageGet rejects after sign-out", async () => {
  // 1) P0-1: A is first & open owning ws1; B is deferred. composer.text("new:ws1") -> sign out UNRELATED B within 300ms -> A's draft MUST persist!
  {
    const { host } = setupTwoAccountHost();
    host.store("device/prefs", { device: { workspace: "ws1" } });
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    seed.inner.cloudSync.recomputeOwners();
    await run(seed.inner.data.written);
    await seed.close();

    const core = await Core.create(host, { clock: host.time.clock });
    assert.ok(core.inner.data.db("s1") !== undefined, "s1 is active and open");
    assert.equal(core.inner.data.isDeferred("s2"), true, "s2 is deferred");
    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 301 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 301, call: "composer.text", params: { key: "new:ws1", text: "keep-a-draft" } });
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res);
    // Sign out UNRELATED deferred account s2 within the 300ms debounce window!
    await run(core.inner.data.accounts(["s1"]));
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal((core.inner.data.db("s1")!.draft("ws1", "new") as J)?.text, "keep-a-draft", "unrelated sign-out must NOT discard A's verified draft");
    await core.close();

    const reopened = await Core.create(host, { clock: host.time.clock });
    assert.equal(reopened.inner.composers.readDraft("ws1", "new").text, "keep-a-draft", "A's draft survives restart after unrelated sign-out");
    await reopened.close();
  }

  // 2) P0-2: chat.send on shared ws-both while A is deferred -> A signs out mid-openDb -> chat.send cancels with 0 deliveries and B outbox stays empty!
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-both", name: "Both" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-both", name: "Both" }] });
    seed.inner.cloudSync.recomputeOwners();
    await run(seed.inner.data.written);
    await seed.close();

    const gateS1 = Deferred.makeUnsafe<void>();
    const s1Started = Deferred.makeUnsafe<void>();
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      Effect.gen(function* () {
        if (name === dbName("s1")) {
          Deferred.doneUnsafe(s1Started, Effect.void);
          yield* Deferred.await(gateS1);
        }
        return yield* origOpen(name);
      });

    const core = await Core.create(host, { clock: host.time.clock });
    assert.equal(core.inner.data.isDeferred("s1"), true);
    let deliverCalls = 0;
    core.inner.viewCalls.deliver = () =>
      Effect.sync(() => {
        deliverCalls++;
        return null;
      });
    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 302 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 302, call: "chat.send", params: { station: "ws-both/st1", thread: 7, text: "a-message-secret" } });
    await Effect.runPromise(Deferred.await(s1Started));
    const signOut = run(core.inner.data.accounts(["s2"]));
    Deferred.doneUnsafe(gateS1, Effect.void);
    await signOut;
    core.inner.cloudSync.recomputeOwners();
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.equal(res.error?.code, "cancelled", `chat.send must cancel when A signs out mid-wait, got: ${JSON.stringify(res)}`);
    await run(core.inner.data.written);
    assert.equal(deliverCalls, 0, "deliver must NOT be invoked after A signs out");
    assert.deepEqual(core.inner.data.db("s2")!.locals("outbox"), [], "B outbox must NOT receive A's message");
    await core.close();
  }

  // 3) P1: In-flight storageGet for A's credential paused while A signs out & deletes key -> resuming storageGet MUST fail, never return deleted credential!
  {
    const { host } = setupTwoAccountHost();
    host.store("device/prefs", { device: { workspace: "ws1" } });
    const nowS = Math.floor(host.nowMs() / 1000);
    const credKey = "credential/s1/ws1";
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    seed.inner.cloudSync.recomputeOwners();
    await run(seed.inner.data.written);
    await seed.close();

    host.store(credKey, { device: "dev-a", credential: "secret-a-deleted", issued_at: nowS, expires_at: nowS + 86400, relay_url: "https://relay.test" });
    const getStarted = Deferred.makeUnsafe<void>();
    const getGate = Deferred.makeUnsafe<void>();
    const origGet = host.storageGet.bind(host);
    host.storageGet = (k: string) =>
      Effect.gen(function* () {
        const val = yield* origGet(k);
        if (k === credKey) {
          Deferred.doneUnsafe(getStarted, Effect.void);
          yield* Deferred.await(getGate);
        }
        return val;
      });

    const core = await Core.create(host, { clock: host.time.clock });
    const credFiber = core.inner.runner.fork(Effect.result(core.inner.cloudSync.credential("ws1", "dev-a", false, "dev-a")));
    await Effect.runPromise(Deferred.await(getStarted));
    // Sign out A completely (host storage key deleted and pendingCredentialDeletes drained).
    await run(core.inner.data.accounts(["s2"]));
    core.inner.cloudSync.accountsChanged();
    await host.settle();
    assert.equal(host.stored(credKey), undefined, "A's credential key already deleted from host storage");
    // Resume paused storageGet carrying the pre-sign-out bytes.
    Deferred.doneUnsafe(getGate, Effect.void);
    const outcome = await Effect.runPromise(Fiber.join(credFiber));
    assert.equal(outcome._tag, "Failure", "in-flight credential read must fail after account sign-out rather than returning deleted token");
    await core.close();
  }
});

test("R6 regressions: 3-account uncached candidateOwners, multi-workspace composer.carry sign-out, post-storageSet sign-out delete preservation, and generation-scoped #asking", async () => {
  // Helper for 3-account host (s1=A, s2=B, s3=C) with active workspace ws-b on B (index 1).
  function setupThreeAccountHost(cHasSharedW: boolean) {
    const host = new FakeHost();
    const expires = host.nowMs() / 1000 + 3600;
    host.store(STORAGE_KEY, [storedAccount("s1", expires), storedAccount("s2", expires), storedAccount("s3", expires)]);
    host.store("device/prefs", { device: { workspace: "ws-b" } });
    const meByToken: Record<string, J> = {
      "Bearer access-s1": { user: { sub: "s1", email: "s1@e" }, workspaces: [{ id: "ws-a", name: "WS A" }], invitations: [], relay_url: "https://relay.test" },
      "Bearer access-s2": { user: { sub: "s2", email: "s2@e" }, workspaces: [{ id: "ws-b", name: "WS B" }, { id: "ws-w", name: "WS W" }], invitations: [], relay_url: "https://relay.test" },
      "Bearer access-s3": {
        user: { sub: "s3", email: "s3@e" },
        workspaces: cHasSharedW ? [{ id: "ws-c", name: "WS C" }, { id: "ws-w", name: "WS W" }] : [{ id: "ws-c", name: "WS C" }],
        invitations: [],
        relay_url: "https://relay.test",
      },
    };
    host.onFetch((req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) return jsonResponse(200, meByToken[auth] ?? { user: {}, workspaces: [] });
      return jsonResponse(200, {});
    });
    return host;
  }

  // 1a) P0-1: A, B, C signed in; only B open; B & C share W; A does not own W; cache missing W ->
  //     composer.text("new:ws-w") awaits A; signing out B mid-wait MUST cancel and NEVER write into C!
  {
    const host = setupThreeAccountHost(true);
    const seed = await Core.create(host, { clock: host.time.clock });
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws-a", name: "WS A" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws-b", name: "WS B" }, { id: "ws-w", name: "WS W" }] });
    seed.inner.data.put("me", "s3", { user: { sub: "s3" }, workspaces: [{ id: "ws-c", name: "WS C" }, { id: "ws-w", name: "WS W" }] });
    await run(seed.inner.data.written);
    // Cache lacks ws-w so public owner("ws-w") starts null while A is deferred.
    seed.inner.data.device.put("choice", "workspaceOwners", { "ws-a": "s1", "ws-b": "s2", "ws-c": "s3" });
    await seed.close();

    const gateA = Deferred.makeUnsafe<void>();
    const aStarted = Deferred.makeUnsafe<void>();
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      Effect.gen(function* () {
        if (name === dbName("s1")) {
          Deferred.doneUnsafe(aStarted, Effect.void);
          yield* Deferred.await(gateA);
        }
        return yield* origOpen(name);
      });

    const core = await Core.create(host, { clock: host.time.clock });
    assert.equal(core.inner.data.isDeferred("s1"), true);
    assert.ok(core.inner.data.db("s2") !== undefined);
    assert.equal(core.inner.data.isDeferred("s3"), true);
    assert.equal(core.inner.workspaces.owner("ws-w"), null);
    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 401 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 401, call: "composer.text", params: { key: "new:ws-w", text: "b-draft-never-c" } });
    await Effect.runPromise(Deferred.await(aStarted));
    // Sign out B while awaiting A!
    const signOutB = run(core.inner.data.accounts(["s1", "s3"]));
    Deferred.doneUnsafe(gateA, Effect.void);
    await signOutB;
    core.inner.cloudSync.recomputeOwners();
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.equal(res.error?.code, "cancelled", `signing out B mid-wait must cancel, got: ${JSON.stringify(res)}`);
    await run(core.inner.data.openAccount("s3"));
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s3")!.draft("ws-w", "new"), undefined, "C DB must NEVER receive B's draft");
    await core.close();
  }

  // 1b) P0-1 converse: C does NOT own W and is after B -> signing out unrelated C mid-wait MUST allow B's draft!
  {
    const host = setupThreeAccountHost(false);
    const seed = await Core.create(host, { clock: host.time.clock });
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws-a", name: "WS A" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws-b", name: "WS B" }, { id: "ws-w", name: "WS W" }] });
    seed.inner.data.put("me", "s3", { user: { sub: "s3" }, workspaces: [{ id: "ws-c", name: "WS C" }] });
    await run(seed.inner.data.written);
    seed.inner.data.device.put("choice", "workspaceOwners", { "ws-a": "s1", "ws-b": "s2", "ws-c": "s3" });
    await seed.close();

    const gateA = Deferred.makeUnsafe<void>();
    const aStarted = Deferred.makeUnsafe<void>();
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      Effect.gen(function* () {
        if (name === dbName("s1")) {
          Deferred.doneUnsafe(aStarted, Effect.void);
          yield* Deferred.await(gateA);
        }
        return yield* origOpen(name);
      });

    const core = await Core.create(host, { clock: host.time.clock });
    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 402 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 402, call: "composer.text", params: { key: "new:ws-w", text: "b-draft-kept" } });
    await Effect.runPromise(Deferred.await(aStarted));
    // Sign out unrelated C (after B) while awaiting A!
    const signOutC = run(core.inner.data.accounts(["s1", "s2"]));
    Deferred.doneUnsafe(gateA, Effect.void);
    await signOutC;
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res, `unrelated C sign-out must NOT cancel B's draft, got: ${JSON.stringify(res)}`);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal((core.inner.data.db("s2")!.draft("ws-w", "new") as J)?.text, "b-draft-kept", "B DB persists draft cleanly");
    await core.close();
  }

  // 2) P0-2: Cross-workspace composer.carry (source ws1 on open A -> target ws2 on deferred B):
  //    signing out A while awaiting B MUST cancel carry and preserve B's existing draft!
  {
    const { host } = setupTwoAccountHost();
    host.store("device/prefs", { device: { workspace: "ws1" } });
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    seed.inner.cloudSync.recomputeOwners();
    seed.inner.data.db("s1")!.putDraft("ws1", "new", { text: "from-a", quotes: [], files: [] });
    seed.inner.data.db("s2")!.putDraft("ws2", "new", { text: "precious-b-draft", quotes: [], files: [] });
    await run(seed.inner.data.written);
    await seed.close();

    const gateB = Deferred.makeUnsafe<void>();
    const bStarted = Deferred.makeUnsafe<void>();
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      Effect.gen(function* () {
        if (name === dbName("s2")) {
          Deferred.doneUnsafe(bStarted, Effect.void);
          yield* Deferred.await(gateB);
        }
        return yield* origOpen(name);
      });

    const core = await Core.create(host, { clock: host.time.clock });
    assert.ok(core.inner.data.db("s1") !== undefined);
    assert.equal(core.inner.data.isDeferred("s2"), true);
    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 403 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 403, call: "composer.carry", params: { key: "new:ws1", to: "new:ws2" } });
    await Effect.runPromise(Deferred.await(bStarted));
    // Sign out A while waiting on target B!
    const signOutA = run(core.inner.data.accounts(["s2"]));
    Deferred.doneUnsafe(gateB, Effect.void);
    await signOutA;
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.equal(res.error?.code, "cancelled", `composer.carry must cancel when source owner A signs out, got: ${JSON.stringify(res)}`);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal((core.inner.data.db("s2")!.draft("ws2", "new") as J)?.text, "precious-b-draft", "B's existing draft must survive cancelled carry");
    await core.close();
  }

  // 3) P1-3: Credential storageSet started before sign-out resolves after sign-out -> MUST NOT clear pendingCredentialDeletes or skip queued delete!
  {
    const { host } = setupTwoAccountHost();
    host.store("device/prefs", { device: { workspace: "ws1" } });
    const nowS = Math.floor(host.nowMs() / 1000);
    const credKey = "credential/s1/ws1";
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    seed.inner.cloudSync.recomputeOwners();
    await run(seed.inner.data.written);
    await seed.close();

    const origFetch = host.fetch.bind(host);
    host.fetch = (req) =>
      req.url.includes("/credential")
        ? Effect.succeed(jsonResponse(200, { credential: "stale-write-tok", issued_at: nowS, expires_at: nowS + 86400, relay_url: "https://relay.test" }))
        : origFetch(req);
    const setStarted = Deferred.makeUnsafe<void>();
    const setGate = Deferred.makeUnsafe<void>();
    const origSet = host.storageSet.bind(host);
    host.storageSet = (k: string, bytes: Uint8Array) =>
      Effect.gen(function* () {
        if (k === credKey) {
          Deferred.doneUnsafe(setStarted, Effect.void);
          yield* Deferred.await(setGate);
        }
        return yield* origSet(k, bytes);
      });

    const core = await Core.create(host, { clock: host.time.clock });
    const credFiber = core.inner.runner.fork(Effect.result(core.inner.cloudSync.credential("ws1", "dev-a", false, "dev-a")));
    await Effect.runPromise(Deferred.await(setStarted));
    // Sign out s1 while storageSet is paused inside keeping lock -> queues delete behind keeping lock!
    await run(core.inner.data.accounts(["s2"]));
    core.inner.cloudSync.accountsChanged();
    // Release old storageSet -> must NOT cancel/skip the queued delete; queued delete must remove credKey!
    Deferred.doneUnsafe(setGate, Effect.void);
    await Effect.runPromise(Fiber.join(credFiber));
    await host.settle();
    assert.equal(host.stored(credKey), undefined, "queued sign-out delete must remove credential written by pre-sign-out storageSet");
    await core.close();
  }

  // 4) P1-4: Re-sign-in while old session's #asking is still in flight MUST NOT coalesce onto old session's credential!
  {
    const { host } = setupTwoAccountHost();
    host.store("device/prefs", { device: { workspace: "ws1" } });
    const nowS = Math.floor(host.nowMs() / 1000);
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    seed.inner.cloudSync.recomputeOwners();
    await run(seed.inner.data.written);
    await seed.close();

    const oldAskStarted = Deferred.makeUnsafe<void>();
    const oldAskGate = Deferred.makeUnsafe<void>();
    let askCount = 0;
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      if (req.url.includes("/credential")) {
        const n = ++askCount;
        return Effect.gen(function* () {
          if (n === 1) {
            Deferred.doneUnsafe(oldAskStarted, Effect.void);
            yield* Deferred.await(oldAskGate);
          }
          return jsonResponse(200, { credential: `tok-session-${n}`, issued_at: nowS, expires_at: nowS + 86400, relay_url: "https://relay.test" });
        });
      }
      return origFetch(req);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    const oldCredFiber = core.inner.runner.fork(Effect.result(core.inner.cloudSync.credential("ws1", "dev-a", false, "dev-a")));
    await Effect.runPromise(Deferred.await(oldAskStarted));
    // Sign out s1 and immediately re-sign-in s1 while old ask #1 is still in flight!
    await run(core.inner.data.accounts(["s2"]));
    await run(core.inner.data.accounts(["s1", "s2"]));
    core.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    core.inner.cloudSync.recomputeOwners();
    // New login session's credential request must issue fresh ask #2 (NEVER join old ask #1)!
    const newCred = await run(core.inner.cloudSync.credential("ws1", "dev-a", false, "dev-a"));
    assert.equal(newCred.credential, "tok-session-2", "re-signed-in session must NOT receive old session's in-flight credential");
    assert.equal(askCount, 2);
    Deferred.doneUnsafe(oldAskGate, Effect.void);
    const oldOutcome = await Effect.runPromise(Fiber.join(oldCredFiber));
    assert.equal(oldOutcome._tag, "Failure", "old session's in-flight credential must fail after sign-out");
    await core.close();
  }
});

test("R7 regressions: mid-wait workspace membership loss cancels edit (never lands in C), and busy disk DB fallback preserves cached owner (never writes to B)", async () => {
  // 1) P0-1: A, B, C signed in; only B open; B & C share W; cache lacks W. While composer.text("new:ws-w") awaits A,
  //    B's refreshAccount receives /v1/me without W -> call MUST cancel and fallback opening C must NOT get the draft!
  {
    const host = new FakeHost();
    const expires = host.nowMs() / 1000 + 3600;
    host.store(STORAGE_KEY, [storedAccount("s1", expires), storedAccount("s2", expires), storedAccount("s3", expires)]);
    host.store("device/prefs", { device: { workspace: "ws-b" } });
    let bHasW = true;
    host.onFetch((req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1") return jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws-a", name: "WS A" }], invitations: [], relay_url: "https://relay.test" });
        if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: bHasW ? [{ id: "ws-b", name: "WS B" }, { id: "ws-w", name: "WS W" }] : [{ id: "ws-b", name: "WS B" }], invitations: [], relay_url: "https://relay.test" });
        if (auth === "Bearer access-s3") return jsonResponse(200, { user: { sub: "s3" }, workspaces: [{ id: "ws-c", name: "WS C" }, { id: "ws-w", name: "WS W" }], invitations: [], relay_url: "https://relay.test" });
      }
      return jsonResponse(200, {});
    });
    const seed = await Core.create(host, { clock: host.time.clock });
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws-a", name: "WS A" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws-b", name: "WS B" }, { id: "ws-w", name: "WS W" }] });
    seed.inner.data.put("me", "s3", { user: { sub: "s3" }, workspaces: [{ id: "ws-c", name: "WS C" }, { id: "ws-w", name: "WS W" }] });
    await run(seed.inner.data.written);
    seed.inner.data.device.put("choice", "workspaceOwners", { "ws-a": "s1", "ws-b": "s2", "ws-c": "s3" });
    await seed.close();

    const gateA = Deferred.makeUnsafe<void>();
    const aStarted = Deferred.makeUnsafe<void>();
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      Effect.gen(function* () {
        if (name === dbName("s1")) {
          Deferred.doneUnsafe(aStarted, Effect.void);
          yield* Deferred.await(gateA);
        }
        return yield* origOpen(name);
      });

    const core = await Core.create(host, { clock: host.time.clock });
    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 501 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 501, call: "composer.text", params: { key: "new:ws-w", text: "lost-membership-draft" } });
    await Effect.runPromise(Deferred.await(aStarted));
    // B loses membership of ws-w via refreshAccount while A is still opening!
    bHasW = false;
    await run(core.inner.cloudSync.refreshAccount("s2"));
    Deferred.doneUnsafe(gateA, Effect.void);
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.equal(res.error?.code, "cancelled", `composer.text must cancel when B loses ws-w membership mid-wait, got: ${JSON.stringify(res)}`);
    // Trigger fallback to open C and flush timers -> C must NEVER receive B's draft!
    await host.time.pass(1500);
    await host.settle();
    await run(core.inner.data.written);
    assert.ok(core.inner.data.db("s3") !== undefined, "C opened via fallback");
    assert.equal(core.inner.data.db("s3")!.draft("ws-w", "new"), undefined, "C DB must NEVER receive draft after B lost membership");
    await core.close();
  }

  // 2) P0-2: A & B share W with cached owner A; cold start opens B; before /v1/me arrives, on-demand openDb(A)
  //    fails with SQLITE_BUSY -> A publishes empty memory DB with notes[A].kind === "busy" -> composer.text MUST
  //    cancel and NEVER write into B's DB (even after a transient /v1/me failure!), and cached workspaceOwners must
  //    keep W -> A until A's authoritative /v1/me succeeds!
  {
    const { host } = setupTwoAccountHost();
    host.memoryDb = () => new NodeSql(new DatabaseSync(":memory:"));
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-both", name: "Both" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-both", name: "Both" }] });
    seed.inner.cloudSync.recomputeOwners();
    await run(seed.inner.data.written);
    await seed.close();

    // Pause /v1/me for s1 so cloud membership hasn't arrived yet, and fail s1's disk open with SQLITE_BUSY!
    let meStatusS1 = 503;
    const meGateS1 = Deferred.makeUnsafe<void>();
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me") && auth === "Bearer access-s1") {
        return Effect.andThen(
          Deferred.await(meGateS1),
          Effect.suspend(() => (meStatusS1 === 200 ? origFetch(req) : Effect.succeed(jsonResponse(meStatusS1, { error: "unavailable" })))),
        );
      }
      return origFetch(req);
    };
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      name === dbName("s1")
        ? Effect.succeed({
            exec() { throw new Error("SQLITE_BUSY: database is locked"); },
            run() { throw new Error("SQLITE_BUSY: database is locked"); },
            all() { throw new Error("SQLITE_BUSY: database is locked"); },
            close() {},
          })
        : origOpen(name);

    const core = await Core.create(host, { clock: host.time.clock });
    assert.equal(core.inner.data.isDeferred("s1"), true);
    const ui = core.connect();
    const ack1 = Deferred.makeUnsafe<J>();
    const ack2 = Deferred.makeUnsafe<J>();
    const ack3 = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 502 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack1, Effect.succeed(m));
      if (m.id === 503 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack2, Effect.succeed(m));
      if (m.id === 504 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack3, Effect.succeed(m));
    };
    // First edit triggers on-demand open of s1 -> hits busy -> falls back to empty memory DB with notes[s1].kind === "busy".
    core.receive(ui, { kind: "call", id: 502, call: "composer.text", params: { key: "new:ws-both", text: "busy-draft-1" } });
    const res1 = await Effect.runPromise(Deferred.await(ack1));
    assert.equal(core.inner.data.notes.get("s1")?.kind, "busy", "s1 note records busy");
    assert.ok(core.inner.data.db("s1") !== undefined, "s1 fell back to empty memory DB");
    assert.equal(res1.error?.code, "cancelled", `first edit must cancel when s1 disk DB is busy and /v1/me unread, got: ${JSON.stringify(res1)}`);
    // Transient /v1/me failure (503) must STILL keep s1 unverified and block writes into s2!
    Deferred.doneUnsafe(meGateS1, Effect.void);
    await run(core.inner.cloudSync.refreshAccount("s1"));
    core.receive(ui, { kind: "call", id: 503, call: "composer.text", params: { key: "new:ws-both", text: "busy-draft-2" } });
    const res2 = await Effect.runPromise(Deferred.await(ack2));
    assert.equal(res2.error?.code, "cancelled", `edit must still cancel after transient /v1/me failure while s1 is unreadable, got: ${JSON.stringify(res2)}`);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s2")!.draft("ws-both", "new"), undefined, "B DB must NEVER receive ws-both draft while A is busy/unreadable");
    assert.equal((core.inner.data.device.get("choice", "workspaceOwners") as J)?.["ws-both"], "s1", "cached owner must stay A while A is unreadable");
    // Once A's authoritative /v1/me succeeds, ownership resolves to A and edits land in A's memory DB (not B)!
    meStatusS1 = 200;
    await run(core.inner.cloudSync.refreshAccount("s1"));
    assert.equal(core.inner.workspaces.owner("ws-both"), "s1", "authoritative /v1/me restores verified owner A");
    core.receive(ui, { kind: "call", id: 504, call: "composer.text", params: { key: "new:ws-both", text: "verified-a-draft" } });
    const res3 = await Effect.runPromise(Deferred.await(ack3));
    assert.ok("ok" in res3, `edit after authoritative /v1/me must succeed, got: ${JSON.stringify(res3)}`);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s1")!.draft("ws-both", "new")?.text, "verified-a-draft", "draft lands in A's DB once verified");
    assert.equal(core.inner.data.db("s2")!.draft("ws-both", "new"), undefined, "B DB still has no ws-both draft");
    await core.close();
  }
});

test("R8 regressions: carry re-verifies source membership, owner() rejects unverified B, no-DB live /v1/me unblocks B while blocking A writes, and busy recovery replays workspace+feedback sync", async () => {
  // 1) P0-1: A open (ws1 draft), B deferred (ws2 draft). Core.receive composer.carry(ws1 -> ws2) pauses B open,
  //    A loses ws1 via refreshAccount mid-wait, then B opens -> carry MUST cancel and B's existing SQLite draft MUST survive!
  {
    let aHasWs1 = true;
    const { host } = setupTwoAccountHost();
    // Make s1 the active primary account so s1 opens eagerly and s2 stays deferred.
    host.store("device/prefs", { device: { workspace: "ws1" } });
    host.onFetch((req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1") return jsonResponse(200, { user: { sub: "s1" }, workspaces: aHasWs1 ? [{ id: "ws1", name: "WS 1" }] : [], invitations: [], relay_url: "https://relay.test" });
        if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }], invitations: [], relay_url: "https://relay.test" });
      }
      return jsonResponse(200, {});
    });
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    seed.inner.cloudSync.recomputeOwners();
    seed.inner.data.db("s1")!.putDraft("ws1", "new", { text: "source-draft", files: [], quotes: [] });
    seed.inner.data.db("s2")!.putDraft("ws2", "new", { text: "target-original-draft", files: [], quotes: [] });
    await run(seed.inner.data.written);
    await seed.close();

    const gateB = Deferred.makeUnsafe<void>();
    const bStarted = Deferred.makeUnsafe<void>();
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      Effect.gen(function* () {
        if (name === dbName("s2")) {
          Deferred.doneUnsafe(bStarted, Effect.void);
          yield* Deferred.await(gateB);
        }
        return yield* origOpen(name);
      });

    const core = await Core.create(host, { clock: host.time.clock });
    assert.equal(core.inner.data.isDeferred("s2"), true);
    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 601 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 601, call: "composer.carry", params: { key: "new:ws1", to: "new:ws2" } });
    await Effect.runPromise(Deferred.await(bStarted));
    // A loses ws1 membership while B is still opening!
    aHasWs1 = false;
    await run(core.inner.cloudSync.refreshAccount("s1"));
    Deferred.doneUnsafe(gateB, Effect.void);
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.equal(res.error?.code, "cancelled", `composer.carry must cancel when source loses membership mid-wait, got: ${JSON.stringify(res)}`);
    await host.time.pass(400);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s2")!.draft("ws2", "new")?.text, "target-original-draft", "target B draft in SQLite must remain untouched on cancelled carry");
    await core.close();
  }

  // 2) P0-2: A before B, both own W, stale cache points to B; A disk DB is busy and /v1/me returns 503 ->
  //    cloudSync.owner("ws-both") MUST fail rather than returning unverified B!
  {
    const { host } = setupTwoAccountHost();
    host.memoryDb = () => new NodeSql(new DatabaseSync(":memory:"));
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-both", name: "Both" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-both", name: "Both" }] });
    await run(seed.inner.data.written);
    // Stale cache points ws-both -> s2.
    seed.inner.data.device.put("choice", "workspaceOwners", { ws1: "s1", ws2: "s2", "ws-both": "s2" });
    await seed.close();

    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me") && auth === "Bearer access-s1") {
        return Effect.succeed(jsonResponse(503, { error: "unavailable" }));
      }
      return origFetch(req);
    };
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      name === dbName("s1")
        ? Effect.succeed({
            exec() { throw new Error("SQLITE_BUSY: database is locked"); },
            run() { throw new Error("SQLITE_BUSY: database is locked"); },
            all() { throw new Error("SQLITE_BUSY: database is locked"); },
            close() {},
          })
        : origOpen(name);

    const core = await Core.create(host, { clock: host.time.clock });
    const ownerRes = await run(Effect.result(core.inner.cloudSync.owner("ws-both")));
    assert.equal(core.inner.cloudSync.hasEarlierDeferred("s2"), true, "s2 still has earlier unverified account s1");
    assert.equal(ownerRes._tag, "Failure", `cloudSync.owner must NOT return unverified B when A is busy+503, got: ${JSON.stringify(ownerRes)}`);
    await core.close();
  }

  // 3) P1-3: A disk DB fails AND host.memoryDb returns undefined; once A's authoritative /v1/me succeeds (listing
  //    only ws1, not ws2), hasUnverifiedAccounts() clears and editing B's ws2 SUCCEEDS, while editing A's ws1
  //    (whose DB is unavailable) is still rejected!
  {
    const { host } = setupTwoAccountHost();
    host.memoryDb = undefined;
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    seed.inner.cloudSync.recomputeOwners();
    await run(seed.inner.data.written);
    await seed.close();

    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      name === dbName("s1")
        ? Effect.fail(new HostError("disk unavailable"))
        : origOpen(name);

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccount("s1"));
    assert.equal(core.inner.data.db("s1"), undefined, "s1 has no live DB when memoryDb is absent");
    assert.equal(core.inner.data.notes.get("s1")?.kind, "failed", "s1 recorded failed note");
    await run(core.inner.cloudSync.refreshAccount("s1"));
    assert.equal(core.inner.cloudSync.hasUnverifiedAccounts(), false, "authoritative /v1/me clears unverified state even without a DB");
    assert.equal(core.inner.workspaces.owner("ws2"), "s2", "B owns ws2");
    assert.equal(core.inner.workspaces.owner("ws1"), "s1", "A owns ws1 via live /v1/me");

    const ui = core.connect();
    const ackB = Deferred.makeUnsafe<J>();
    const ackA = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 602 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ackB, Effect.succeed(m));
      if (m.id === 603 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ackA, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 602, call: "composer.text", params: { key: "new:ws2", text: "b-exclusive-ok" } });
    const resB = await Effect.runPromise(Deferred.await(ackB));
    assert.ok("ok" in resB, `editing B's exclusive ws2 must succeed once A's /v1/me arrived, got: ${JSON.stringify(resB)}`);
    core.receive(ui, { kind: "call", id: 603, call: "composer.text", params: { key: "new:ws1", text: "a-no-db-reject" } });
    const resA = await Effect.runPromise(Deferred.await(ackA));
    assert.equal(resA.error?.code, "cancelled", `editing A's ws1 must still cancel when A has no live DB, got: ${JSON.stringify(resA)}`);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s2")!.draft("ws2", "new")?.text, "b-exclusive-ok", "B's draft persisted to B's SQLite DB");
    await core.close();
  }

  // 4) P1-4: A leaves #deferred into a busy memory DB (hasDeferred() === false, hasUnverifiedAccounts() === true),
  //    B's initial #account(/v1/me) runs while A is unverified, then A's authoritative /v1/me arrives confirming
  //    ws2 belongs only to B -> BOTH GET /v1/workspaces/ws2 AND GET /v1/workspaces/ws2/feedback MUST replay!
  {
    const { host } = setupTwoAccountHost();
    host.memoryDb = () => new NodeSql(new DatabaseSync(":memory:"));
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    await run(seed.inner.data.written);
    // Clear cached workspaceOwners so ws2 waits for A's authoritative /v1/me.
    seed.inner.data.device.put("choice", "workspaceOwners", { ws1: "s1" });
    await seed.close();

    const meGateS1 = Deferred.makeUnsafe<void>();
    let ws2Gets = 0;
    let ws2FeedbackGets = 0;
    host.onFetch(async (req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1") {
          await Effect.runPromise(Deferred.await(meGateS1));
          return jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }], invitations: [], relay_url: "https://relay.test" });
        }
        if (auth === "Bearer access-s2") {
          return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }], invitations: [], relay_url: "https://relay.test" });
        }
      }
      if (req.url.endsWith("/v1/workspaces/ws2")) {
        ws2Gets++;
        return jsonResponse(200, { id: "ws2", name: "WS 2", stations: [] });
      }
      if (req.url.endsWith("/v1/workspaces/ws2/feedback")) {
        ws2FeedbackGets++;
        return jsonResponse(200, { feedback: [] });
      }
      return jsonResponse(200, {});
    });
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      name === dbName("s1")
        ? Effect.succeed({
            exec() { throw new Error("SQLITE_BUSY: database is locked"); },
            run() { throw new Error("SQLITE_BUSY: database is locked"); },
            all() { throw new Error("SQLITE_BUSY: database is locked"); },
            close() {},
          })
        : origOpen(name);

    const core = await Core.create(host, { clock: host.time.clock });
    // Force A out of #deferred into busy memory DB before B's initial account sync settles.
    await run(core.inner.data.openAccount("s1"));
    assert.equal(core.inner.data.hasDeferred(), false, "no deferred accounts remain");
    assert.equal(core.inner.cloudSync.hasUnverifiedAccounts(), true, "A is busy/unverified");
    await host.settle();
    assert.equal(ws2Gets, 0, "ws2 detail GET deferred while A is busy/unverified");
    assert.equal(ws2FeedbackGets, 0, "ws2 feedback GET deferred while A is busy/unverified");

    // Release A's authoritative /v1/me -> both workspace detail and feedback GET must replay once for B!
    Deferred.doneUnsafe(meGateS1, Effect.void);
    await host.settle();
    await host.time.pass(100);
    assert.equal(core.inner.cloudSync.hasUnverifiedAccounts(), false, "no unverified accounts remain");
    assert.equal(core.inner.workspaces.owner("ws2"), "s2", "B owns ws2");
    assert.equal(ws2Gets, 1, "ws2 detail GET replayed once after busy recovery");
    assert.equal(ws2FeedbackGets, 1, "ws2 feedback GET replayed once after busy recovery");
    await core.close();
  }
});

test("R9 regressions: recovered DB adopts newer live /v1/me, no-DB workspaces subscription stays reactive, and sign-out cleans legacy credentials from live /v1/me", async () => {
  // 1) P0-1: A before B; A's disk DB has stale me without ws-w, B holds ws-w. A fails open without memoryDb,
  //    then authoritative /v1/me gives A ws-w (owner === A). Disk recovers and accounts.migrate reopens A (same gen):
  //    owner MUST stay A (not revert to B), composer.text writes into A's SQLite DB, and persists across restart!
  {
    const { host } = setupTwoAccountHost();
    host.memoryDb = undefined;
    host.onFetch((req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1") return jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
        if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
      }
      return jsonResponse(200, {});
    });
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    // Stale disk me for A does NOT list ws-w yet!
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }] });
    seed.inner.cloudSync.recomputeOwners();
    await run(seed.inner.data.written);
    await seed.close();

    let failA = true;
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      name === dbName("s1") && failA
        ? Effect.fail(new HostError("disk temporarily unavailable"))
        : origOpen(name);

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccount("s1"));
    assert.equal(core.inner.data.db("s1"), undefined);
    await run(core.inner.cloudSync.refreshAccount("s1"));
    assert.equal(core.inner.workspaces.owner("ws-w"), "s1", "live /v1/me establishes owner A");

    // Disk recovers; accounts.migrate updates A's session token without changing login generation, triggering reopen!
    failA = false;
    const nowSec = Math.floor(host.nowMs() / 1000);
    await run(core.inner.accounts.migrate([
      { sub: "s1", email: "s1@example.com", name: "s1", picture: "", access: "access-s1", refresh: "refresh-s1", accessExpires: nowSec + 7200 },
    ]));
    await host.settle();
    await run(core.inner.data.written);
    assert.ok(core.inner.data.db("s1") !== undefined, "A's disk DB reopened");
    assert.equal(core.inner.data.notes.get("s1"), undefined, "A's stale failed note cleared on clean reopen");
    assert.equal(core.inner.workspaces.owner("ws-w"), "s1", "owner MUST remain A after reopening stale disk DB");

    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 701 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 701, call: "composer.text", params: { key: "new:ws-w", text: "belongs-only-to-a" } });
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res, `composer.text must succeed after DB recovery, got: ${JSON.stringify(res)}`);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s1")!.draft("ws-w", "new")?.text, "belongs-only-to-a", "draft landed in A's SQLite DB");
    assert.equal(core.inner.data.db("s2")!.draft("ws-w", "new"), undefined, "B's SQLite DB must stay empty");
    await core.close();

    // Restart fresh Core from disk (no network needed) -> owner is still A and draft belongs only to A!
    host.onFetch(() => jsonResponse(503, {}));
    const core2 = await Core.create(host, { clock: host.time.clock });
    await run(core2.inner.data.openAccounts(["s1", "s2"]));
    assert.equal(core2.inner.workspaces.owner("ws-w"), "s1", "restarted Core still sees owner A from adopted disk me");
    assert.equal(core2.inner.data.db("s1")!.draft("ws-w", "new")?.text, "belongs-only-to-a", "draft persists in A after restart");
    assert.equal(core2.inner.data.db("s2")!.draft("ws-w", "new"), undefined, "B still has no draft after restart");
    await core2.close();
  }

  // 2) P1-2: A has no live DB; live `workspaces` subscription MUST receive updates on full `/v1/me` refresh,
  //    SSE `workspaces` entry rename, and `NOT_BETA` clear!
  {
    let aWorkspaces: Array<{ id: string; name: string }> = [{ id: "aw", name: "AW Original" }];
    let notBeta = false;
    const host = new FakeHost();
    host.memoryDb = undefined;
    const now = Math.floor(host.nowMs() / 1000);
    host.store(STORAGE_KEY, [storedAccount("s1", now + 3600)]);
    host.onFetch((req) => {
      if (req.url.endsWith("/v1/me")) {
        if (notBeta) return jsonResponse(403, { error: "not_beta" });
        return jsonResponse(200, { user: { sub: "s1" }, workspaces: aWorkspaces, invitations: [], relay_url: "https://relay.test" });
      }
      return jsonResponse(200, {});
    });
    host.openDb = () => Effect.fail(new HostError("disk unavailable"));

    const core = await Core.create(host, { clock: host.time.clock });
    assert.equal(core.inner.data.db("s1"), undefined);
    const ui = core.connect();
    const held = new Map<number, unknown>();
    core.receive(ui, { kind: "subscribe", id: 702, subscribe: { topic: "workspaces" } });
    await host.settle();
    apply(host, held);
    assert.ok(Array.isArray(held.get(702)), "initial workspaces value emitted");
    assert.deepEqual((held.get(702) as J)[0].workspaces.map((w: J) => w.id), ["aw"]);

    // Full `/v1/me` adds `extra` -> live subscriber receives [aw, extra]!
    aWorkspaces = [{ id: "aw", name: "AW Original" }, { id: "extra", name: "Extra" }];
    await run(core.inner.cloudSync.refreshAccount("s1"));
    await host.settle();
    apply(host, held);
    assert.deepEqual((held.get(702) as J)[0].workspaces.map((w: J) => w.id), ["aw", "extra"], "workspaces subscription updated on full /v1/me refresh");

    // SSE `workspaces` entry rename -> live subscriber receives updated name!
    host.socketSend("/v1/events", JSON.stringify({ type: "workspaces", entry: { id: "aw", name: "AW Renamed" } }));
    await host.settle();
    apply(host, held);
    assert.equal((held.get(702) as J)[0].workspaces.find((w: J) => w.id === "aw")?.name, "AW Renamed", "workspaces subscription updated on SSE entry rename");

    // `NOT_BETA` clears live me -> live subscriber receives empty workspaces!
    notBeta = true;
    await run(core.inner.cloudSync.refreshAccount("s1"));
    await host.settle();
    apply(host, held);
    assert.deepEqual((held.get(702) as J)[0].workspaces, [], "workspaces subscription cleared on NOT_BETA");
    await core.close();
  }

  // 3) P1-3: B before A, both share ws-w; A has no live DB (memoryDb undefined) and legacy credential exists in
  //    host.storage without credWorkspaces/A index. Signing out A MUST delete A's legacy credential using #liveMe!
  {
    const host = new FakeHost();
    host.memoryDb = undefined;
    const now = Math.floor(host.nowMs() / 1000);
    // B ("s2") is first in sign-in order, A ("s1") is second.
    host.store(STORAGE_KEY, [storedAccount("s2", now + 3600), storedAccount("s1", now + 3600)]);
    host.store("device/prefs", { device: { workspace: "ws2" } });
    host.onFetch((req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
        if (auth === "Bearer access-s1") return jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
      }
      return jsonResponse(200, {});
    });
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      name === dbName("s1")
        ? Effect.fail(new HostError("disk unavailable"))
        : origOpen(name);

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccount("s1"));
    assert.equal(core.inner.data.db("s1"), undefined);
    await run(core.inner.cloudSync.refreshAccount("s1"));
    await run(core.inner.cloudSync.refreshAccount("s2"));
    assert.equal(core.inner.workspaces.owner("ws-w"), "s2", "B owns shared ws-w");

    // Legacy credential stored for A on shared ws-w, with NO credWorkspaces/s1 device index!
    const legacyKey = "credential/s1/ws-w";
    host.store(legacyKey, { token: "legacy-marker", expires_at: now + 3600 });
    assert.ok(host.stored(legacyKey) !== undefined);

    // Sign out A -> must delete legacyKey using A's #liveMe workspaces!
    await run(core.inner.accounts.signOut("s1"));
    await host.settle();
    assert.equal(host.stored(legacyKey), undefined, "A's legacy credential for shared ws-w deleted on sign-out via #liveMe");
    await core.close();
  }
});

test("R10 regressions: SQLITE_FULL on adoptDb statement/COMMIT keeps owner A, read-only carry preserves B draft, and NOT_BETA tombstone blocks stale disk revival", async () => {
  // 1) P0-1a & P0-1b: A's disk DB has stale me without ws-w, B holds ws-w. No-DB authoritative /v1/me assigns ws-w -> A.
  //    Reopen A via accounts.migrate while injecting SQLITE_FULL once on account_doc write AND once on COMMIT:
  //    in both cases owner MUST stay A (even after refreshAccount(B) + recomputeOwners) and B's SQLite stays empty!
  for (const failOn of ["run", "commit"] as const) {
    const { host } = setupTwoAccountHost();
    host.memoryDb = undefined;
    host.onFetch((req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1") return jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
        if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
      }
      return jsonResponse(200, {});
    });
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }] });
    seed.inner.cloudSync.recomputeOwners();
    await run(seed.inner.data.written);
    await seed.close();

    let failA = true;
    let injectOnce = true;
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) => {
      if (name === dbName("s1") && failA) return Effect.fail(new HostError("disk unavailable"));
      return Effect.map(origOpen(name), (raw) => {
        if (name !== dbName("s1")) return raw;
        return {
          exec(sql: string) {
            if (failOn === "commit" && injectOnce && /^\s*COMMIT\b/i.test(sql)) {
              injectOnce = false;
              throw new SqlError("SQLITE_FULL: database or disk is full", "full");
            }
            raw.exec(sql);
          },
          run(sql: string, params?: readonly SqlValue[]) {
            if (failOn === "run" && injectOnce && /account_doc/i.test(sql)) {
              injectOnce = false;
              throw new SqlError("SQLITE_FULL: database or disk is full", "full");
            }
            return raw.run(sql, params);
          },
          all(sql: string, params?: readonly SqlValue[]) {
            return raw.all(sql, params);
          },
          close() {
            raw.close();
          },
        };
      });
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccount("s1"));
    await run(core.inner.cloudSync.refreshAccount("s1"));
    assert.equal(core.inner.workspaces.owner("ws-w"), "s1");

    failA = false;
    const nowSec = Math.floor(host.nowMs() / 1000);
    await run(core.inner.accounts.migrate([
      { sub: "s1", email: "s1@example.com", name: "s1", picture: "", access: "access-s1", refresh: "refresh-s1", accessExpires: nowSec + 7200 },
    ]));
    await host.settle();
    await run(core.inner.data.written);
    // Refresh B and recompute owners after rollback -> owner MUST still be A, never B!
    await run(core.inner.cloudSync.refreshAccount("s2"));
    core.inner.cloudSync.recomputeOwners();
    assert.equal(core.inner.workspaces.owner("ws-w"), "s1", `owner must stay A after SQLITE_FULL on ${failOn}`);

    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 801 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 801, call: "composer.text", params: { key: "new:ws-w", text: `after-full-${failOn}` } });
    await Effect.runPromise(Deferred.await(ack));
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s2")!.draft("ws-w", "new"), undefined, `B SQLite must NEVER receive A draft after SQLITE_FULL on ${failOn}`);
    await core.close();
  }

  // 2) P0-2: A opens read-only (schema_version newer), live /v1/me confirms A owns ws-w; B has writable DB with
  //    source draft on ws2. Core.receive composer.carry(ws2 -> ws-w) MUST fail with cancelled and preserve B's draft!
  {
    const { host } = setupTwoAccountHost();
    host.onFetch((req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1") return jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
        if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }], invitations: [], relay_url: "https://relay.test" });
      }
      return jsonResponse(200, {});
    });
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    seed.inner.data.db("s2")!.putDraft("ws2", "new", { text: "keep-b-source-draft", files: [], quotes: [] });
    await run(seed.inner.data.written);
    // Mark A's DB as created by a newer schema version so it opens read-only!
    host.sqls.get(dbName("s1"))!.exec("PRAGMA user_version = 9999");
    await seed.close();

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccount("s1"));
    assert.equal(core.inner.data.db("s1")?.readOnly, true, "A opened read-only for newer schema");
    await run(core.inner.cloudSync.refreshAccount("s1"));
    assert.equal(core.inner.workspaces.owner("ws-w"), "s1", "live /v1/me assigns ws-w to read-only A");

    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 802 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 802, call: "composer.carry", params: { key: "new:ws2", to: "new:ws-w" } });
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.equal(res.error?.code, "cancelled", `composer.carry into read-only A must cancel, got: ${JSON.stringify(res)}`);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s2")!.draft("ws2", "new")?.text, "keep-b-source-draft", "B source draft must remain intact after cancelled carry to read-only target");
    await core.close();
  }

  // 3) P1-3: NOT_BETA tombstone persists across same-gen disk recovery (and read-only DB), never reviving stale
  //    disk workspaces, and clears cleanly once a subsequent same-gen 200 /v1/me succeeds!
  {
    let mode: "not_beta" | "ok" = "not_beta";
    const host = new FakeHost();
    host.memoryDb = undefined;
    const now = Math.floor(host.nowMs() / 1000);
    host.store(STORAGE_KEY, [storedAccount("s1", now + 3600)]);
    host.onFetch((req) => {
      if (req.url.endsWith("/v1/me")) {
        if (mode === "not_beta") return jsonResponse(403, { error: "not_beta" });
        return jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }], invitations: [], relay_url: "https://relay.test" });
      }
      return jsonResponse(200, {});
    });
    const seed = await Core.create(host, { clock: host.time.clock });
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    await run(seed.inner.data.written);
    await seed.close();

    let failA = true;
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      name === dbName("s1") && failA
        ? Effect.fail(new HostError("disk unavailable"))
        : origOpen(name);

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.cloudSync.refreshAccount("s1"));
    assert.equal(core.inner.workspaces.owner("ws1"), null, "NOT_BETA clears ws1 owner");

    // Reopen disk DB containing stale me in the SAME generation -> owner MUST stay null and stale disk me dropped!
    failA = false;
    await run(core.inner.accounts.migrate([
      { sub: "s1", email: "s1@example.com", name: "s1", picture: "", access: "access-s1", refresh: "refresh-s1", accessExpires: now + 7200 },
    ]));
    await host.settle();
    await run(core.inner.data.written);
    assert.ok(core.inner.data.db("s1") !== undefined, "disk DB reopened");
    assert.equal(core.inner.workspaces.owner("ws1"), null, "stale disk me must NOT revive ws1 while NOT_BETA holds");
    assert.equal(core.inner.data.db("s1")!.accountDoc("me"), undefined, "stale disk me dropped upon writable recovery");

    // Subsequent 200 /v1/me in the same generation lifts NOT_BETA cleanly!
    mode = "ok";
    await run(core.inner.cloudSync.refreshAccount("s1"));
    await run(core.inner.data.written);
    assert.equal(core.inner.workspaces.owner("ws1"), "s1", "later 200 /v1/me lifts NOT_BETA and restores owner");
    await core.close();
  }
});

test("R11 regressions: SQLITE_FULL recovery persists live /v1/me before offline restart, NOT_BETA+503 keeps B editable, and NOT_BETA before sign-out cleans legacy credentials", async () => {
  // 1) P0-1: A's disk DB has stale me without ws-w, B holds ws-w. Live /v1/me assigns ws-w -> A.
  //    On DB recovery, inject SQLITE_FULL once on account_doc write, then allow all subsequent writes.
  //    Write first draft -> close cleanly -> restart offline -> owner MUST stay A and BOTH drafts live only in A!
  {
    const { host } = setupTwoAccountHost();
    host.memoryDb = undefined;
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }] });
    seed.inner.cloudSync.recomputeOwners();
    await run(seed.inner.data.written);
    await seed.close();

    host.onFetch((req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1") return jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
        if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
      }
      return jsonResponse(200, {});
    });

    let failA = true;
    let injectOnce = true;
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) => {
      if (name === dbName("s1") && failA) return Effect.fail(new HostError("disk unavailable"));
      return Effect.map(origOpen(name), (raw) => {
        if (name !== dbName("s1")) return raw;
        return {
          exec(sql: string) { raw.exec(sql); },
          run(sql: string, params?: readonly SqlValue[]) {
            if (injectOnce && /account_doc/i.test(sql)) {
              injectOnce = false;
              throw new SqlError("SQLITE_FULL: database or disk is full", "full");
            }
            return raw.run(sql, params);
          },
          all(sql: string, params?: readonly SqlValue[]) { return raw.all(sql, params); },
          close() { raw.close(); },
        };
      });
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccount("s1"));
    await run(core.inner.cloudSync.refreshAccount("s1"));
    assert.equal(core.inner.workspaces.owner("ws-w"), "s1");

    failA = false;
    const nowSec = Math.floor(host.nowMs() / 1000);
    await run(core.inner.accounts.migrate([
      { sub: "s1", email: "s1@example.com", name: "s1", picture: "", access: "access-s1", refresh: "refresh-s1", accessExpires: nowSec + 7200 },
    ]));
    await host.settle();
    await run(core.inner.data.written);

    const ui = core.connect();
    const ack1 = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 901 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack1, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 901, call: "composer.text", params: { key: "new:ws-w", text: "first-edit-a" } });
    const res1 = await Effect.runPromise(Deferred.await(ack1));
    assert.ok("ok" in res1);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s1")!.draft("ws-w", "new")?.text, "first-edit-a", "first draft landed in A");
    assert.equal(core.inner.data.db("s2")!.draft("ws-w", "new"), undefined, "B has no draft online");
    await core.close();

    // Offline restart with both DBs open -> A's disk DB must now have ws-w, owner stays A, second edit lands ONLY in A!
    host.onFetch(() => jsonResponse(503, {}));
    const core2 = await Core.create(host, { clock: host.time.clock });
    await run(core2.inner.data.openAccounts(["s1", "s2"]));
    assert.equal(core2.inner.workspaces.owner("ws-w"), "s1", "owner MUST stay A after offline restart");
    const ui2 = core2.connect();
    const ack2 = Deferred.makeUnsafe<J>();
    const origEmit2 = core2.inner.host.emit.bind(core2.inner.host);
    core2.inner.host.emit = (c, m) => {
      origEmit2(c, m);
      if (m.id === 902 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack2, Effect.succeed(m));
    };
    core2.receive(ui2, { kind: "call", id: 902, call: "composer.text", params: { key: "new:ws-w", text: "second-edit-offline-a" } });
    const res2 = await Effect.runPromise(Deferred.await(ack2));
    assert.ok("ok" in res2);
    await host.time.pass(350);
    await run(core2.inner.data.written);
    assert.equal(core2.inner.data.db("s1")!.draft("ws-w", "new")?.text, "second-edit-offline-a", "second draft landed in A offline");
    assert.equal(core2.inner.data.db("s2")!.draft("ws-w", "new"), undefined, "B SQLite stays completely empty after offline restart");
    await core2.close();
  }

  // 2) P1-2: A before B without DB; A receives NOT_BETA (403) then 503 on next refresh ->
  //    hasUnverifiedAccounts() MUST stay false and B's exclusive ws2 remains editable!
  {
    let aStatus: 403 | 503 = 403;
    const { host } = setupTwoAccountHost();
    host.memoryDb = undefined;
    host.onFetch((req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1") {
          return aStatus === 403 ? jsonResponse(403, { error: "not_beta" }) : jsonResponse(503, { error: "unavailable" });
        }
        if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }], invitations: [], relay_url: "https://relay.test" });
      }
      return jsonResponse(200, {});
    });
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    await run(seed.inner.data.written);
    await seed.close();

    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      name === dbName("s1") ? Effect.fail(new HostError("disk unavailable")) : origOpen(name);

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccount("s1"));
    await run(core.inner.cloudSync.refreshAccount("s1"));
    assert.equal(core.inner.cloudSync.hasUnverifiedAccounts(), false, "NOT_BETA clears unverified state");

    aStatus = 503;
    await run(core.inner.cloudSync.refreshAccount("s1"));
    assert.equal(core.inner.cloudSync.hasUnverifiedAccounts(), false, "subsequent 503 must NOT re-block B after same-gen NOT_BETA");

    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 903 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 903, call: "composer.text", params: { key: "new:ws2", text: "b-still-editable" } });
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res, `B exclusive ws2 must remain editable after A NOT_BETA+503, got: ${JSON.stringify(res)}`);
    await core.close();
  }

  // 3) P1-3: B before A, both share ws-w; A has no DB, legacy credential at credential/s1/ws-w without index;
  //    A learns ws-w via /v1/me, then receives NOT_BETA, then signs out -> legacy credential MUST still be deleted!
  {
    let aNotBeta = false;
    const host = new FakeHost();
    host.memoryDb = undefined;
    const now = Math.floor(host.nowMs() / 1000);
    host.store(STORAGE_KEY, [storedAccount("s2", now + 3600), storedAccount("s1", now + 3600)]);
    host.store("device/prefs", { device: { workspace: "ws2" } });
    host.onFetch((req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
        if (auth === "Bearer access-s1") {
          return aNotBeta
            ? jsonResponse(403, { error: "not_beta" })
            : jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
        }
      }
      return jsonResponse(200, {});
    });
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      name === dbName("s1") ? Effect.fail(new HostError("disk unavailable")) : origOpen(name);

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccount("s1"));
    await run(core.inner.cloudSync.refreshAccount("s1"));
    await run(core.inner.cloudSync.refreshAccount("s2"));
    assert.equal(core.inner.workspaces.owner("ws-w"), "s2");

    const legacyKey = "credential/s1/ws-w";
    host.store(legacyKey, { token: "legacy-marker", expires_at: now + 3600 });

    // A receives NOT_BETA BEFORE signing out -> ws-w must be preserved into cleanup index!
    aNotBeta = true;
    await run(core.inner.cloudSync.refreshAccount("s1"));
    await run(core.inner.accounts.signOut("s1"));
    await host.settle();
    assert.equal(host.stored(legacyKey), undefined, "A's legacy credential for shared ws-w MUST be deleted even after NOT_BETA preceded sign-out");
    await core.close();
  }
});

test("R12 regressions: close-time COMMIT failure retries/verifies live /v1/me (and rejects if still unpersisted), and writable DB workspace removal preserves legacy credential cleanup", async () => {
  // 1a) P0-1 (transient SQLITE_FULL on close's first COMMIT): A's disk DB has stale me without ws-w, B holds ws-w.
  //     Live /v1/me gives A ws-w; reopen A so adoptDb queues account_doc in an uncommitted tx, then call close() while
  //     injecting SQLITE_FULL ONCE on the close-triggered COMMIT. flushLiveMe() retries + commits cleanly ->
  //     offline restart keeps owner A and draft lands ONLY in A!
  {
    const { host } = setupTwoAccountHost();
    host.memoryDb = undefined;
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }] });
    seed.inner.cloudSync.recomputeOwners();
    await run(seed.inner.data.written);
    await seed.close();

    host.onFetch((req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1") return jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
        if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
      }
      return jsonResponse(200, {});
    });

    let failA = true;
    let armCloseCommitFail = false;
    let failedCloseCommitOnce = false;
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) => {
      if (name === dbName("s1") && failA) return Effect.fail(new HostError("disk unavailable"));
      return Effect.map(origOpen(name), (raw) => {
        if (name !== dbName("s1")) return raw;
        return {
          exec(sql: string) {
            if (armCloseCommitFail && !failedCloseCommitOnce && /^\s*COMMIT\b/i.test(sql)) {
              failedCloseCommitOnce = true;
              throw new SqlError("SQLITE_FULL: database or disk is full", "full");
            }
            raw.exec(sql);
          },
          run(sql: string, params?: readonly SqlValue[]) { return raw.run(sql, params); },
          all(sql: string, params?: readonly SqlValue[]) { return raw.all(sql, params); },
          close() { raw.close(); },
        };
      });
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccount("s1"));
    await run(core.inner.cloudSync.refreshAccount("s1"));
    assert.equal(core.inner.workspaces.owner("ws-w"), "s1");

    // Reopen A synchronously without settling its tx, then fail the close-triggered COMMIT once!
    failA = false;
    armCloseCommitFail = true;
    await run(core.inner.data.openAccount("s1"));
    await core.close();
    assert.equal(failedCloseCommitOnce, true, "close-triggered COMMIT failed once and was retried");

    // Offline restart -> A's disk DB must have ws-w, owner stays A, draft lands ONLY in A!
    host.onFetch(() => jsonResponse(503, {}));
    const core2 = await Core.create(host, { clock: host.time.clock });
    await run(core2.inner.data.openAccounts(["s1", "s2"]));
    assert.equal(core2.inner.workspaces.owner("ws-w"), "s1", "owner MUST stay A after close-time COMMIT failure + retry");
    const ui2 = core2.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit2 = core2.inner.host.emit.bind(core2.inner.host);
    core2.inner.host.emit = (c, m) => {
      origEmit2(c, m);
      if (m.id === 1001 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core2.receive(ui2, { kind: "call", id: 1001, call: "composer.text", params: { key: "new:ws-w", text: "offline-after-close-commit-fail" } });
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res);
    await host.time.pass(350);
    await run(core2.inner.data.written);
    assert.equal(core2.inner.data.db("s1")!.draft("ws-w", "new")?.text, "offline-after-close-commit-fail", "draft landed ONLY in A");
    assert.equal(core2.inner.data.db("s2")!.draft("ws-w", "new"), undefined, "B SQLite stays empty");
    await core2.close();
  }

  // 1b) P0-1 (persistent SQLITE_FULL on close): if even the retry commit cannot persist live /v1/me, Core.close()
  //     MUST reject rather than silently reporting success!
  {
    const { host } = setupTwoAccountHost();
    host.memoryDb = undefined;
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }] });
    await run(seed.inner.data.written);
    await seed.close();

    host.onFetch((req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1") return jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
        if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
      }
      return jsonResponse(200, {});
    });

    let failA = true;
    let alwaysFailCommit = false;
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) => {
      if (name === dbName("s1") && failA) return Effect.fail(new HostError("disk unavailable"));
      return Effect.map(origOpen(name), (raw) => {
        if (name !== dbName("s1")) return raw;
        return {
          exec(sql: string) {
            if (alwaysFailCommit && /^\s*COMMIT\b/i.test(sql)) {
              throw new SqlError("SQLITE_FULL: database or disk is full", "full");
            }
            raw.exec(sql);
          },
          run(sql: string, params?: readonly SqlValue[]) { return raw.run(sql, params); },
          all(sql: string, params?: readonly SqlValue[]) { return raw.all(sql, params); },
          close() { raw.close(); },
        };
      });
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccount("s1"));
    await run(core.inner.cloudSync.refreshAccount("s1"));
    failA = false;
    alwaysFailCommit = true;
    await run(core.inner.data.openAccount("s1"));
    await assert.rejects(() => core.close(), /failed to persist authoritative \/v1\/me on close/);
  }

  // 2) P1-2: B before A, both share ws-w; A's writable SQLite commits me containing ws-w (#liveMe clears), then
  //    A's next 200 /v1/me removes ws-w, then A signs out -> legacy unindexed credential for ws-w MUST be deleted!
  {
    let aHasW = true;
    const host = new FakeHost();
    const now = Math.floor(host.nowMs() / 1000);
    host.store(STORAGE_KEY, [storedAccount("s2", now + 3600), storedAccount("s1", now + 3600)]);
    host.store("device/prefs", { device: { workspace: "ws2" } });
    host.onFetch((req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
        if (auth === "Bearer access-s1") {
          return jsonResponse(200, {
            user: { sub: "s1" },
            workspaces: aHasW ? [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }] : [{ id: "ws1", name: "WS 1" }],
            invitations: [],
            relay_url: "https://relay.test",
          });
        }
      }
      return jsonResponse(200, {});
    });

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s2", "s1"]));
    await run(core.inner.cloudSync.refreshAccount("s2"));
    await run(core.inner.cloudSync.refreshAccount("s1"));
    await run(core.inner.data.written);
    await host.settle();
    assert.equal(core.inner.workspaces.owner("ws-w"), "s2", "B owns shared ws-w");

    const legacyKey = "credential/s1/ws-w";
    host.store(legacyKey, { token: "legacy-marker-writable-db", expires_at: now + 3600 });

    // A's next 200 /v1/me removes ws-w AFTER #liveMe was already cleared into SQLite!
    aHasW = false;
    await run(core.inner.cloudSync.refreshAccount("s1"));
    await run(core.inner.data.written);
    // Now sign out A -> legacy unindexed credential for ws-w MUST still be deleted!
    await run(core.inner.accounts.signOut("s1"));
    await host.settle();
    assert.equal(host.stored(legacyKey), undefined, "A's legacy credential for removed shared ws-w MUST be deleted on sign-out");
    await core.close();
  }
});

test("R13 regressions: DB-less close persists pendingMe across post-close disk recovery, per-account IO error never aborts close/other accounts, and SQLITE_FULL triggers zero unhandled fiber failures", async () => {
  // 1) P0-1: A before B; A's disk DB has stale me without ws-w, B holds ws-w. A fails open (no memoryDb), learns
  //    ws-w via authoritative /v1/me, stays DB-less until Core.close() succeeds. Disk recovers ONLY AFTER close();
  //    offline restart opens both DBs -> owner MUST stay A and draft lands ONLY in A (never B)!
  {
    const { host } = setupTwoAccountHost();
    host.memoryDb = undefined;
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }] });
    seed.inner.cloudSync.recomputeOwners();
    await run(seed.inner.data.written);
    await seed.close();

    host.onFetch((req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1") return jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
        if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
      }
      return jsonResponse(200, {});
    });

    let failA = true;
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      name === dbName("s1") && failA
        ? Effect.fail(new HostError("disk unavailable"))
        : origOpen(name);

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccount("s1"));
    assert.equal(core.inner.data.db("s1"), undefined);
    await run(core.inner.cloudSync.refreshAccount("s1"));
    assert.equal(core.inner.workspaces.owner("ws-w"), "s1");
    // Close while A STILL has no DB!
    await core.close();

    // Disk recovers AFTER close(); restart completely offline!
    failA = false;
    host.onFetch(() => jsonResponse(503, {}));
    const core2 = await Core.create(host, { clock: host.time.clock });
    await run(core2.inner.data.openAccounts(["s1", "s2"]));
    await run(core2.inner.data.written);
    assert.equal(core2.inner.workspaces.owner("ws-w"), "s1", "owner MUST stay A on offline restart after post-close disk recovery");

    const ui2 = core2.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core2.inner.host.emit.bind(core2.inner.host);
    core2.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 1101 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core2.receive(ui2, { kind: "call", id: 1101, call: "composer.text", params: { key: "new:ws-w", text: "post-close-recovery-only-a" } });
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res);
    await host.time.pass(350);
    await run(core2.inner.data.written);
    assert.equal(core2.inner.data.db("s1")!.draft("ws-w", "new")?.text, "post-close-recovery-only-a", "draft landed ONLY in A");
    assert.equal(core2.inner.data.db("s2")!.draft("ws-w", "new"), undefined, "B SQLite stayed empty");
    await core2.close();
  }

  // 2) P1-2: Two accounts (s1, s2) both have pending #liveMe on close; s1's close COMMIT rolls back AND verification
  //    SELECT throws SQLITE_IOERR while s2 is writable. Core.close() MUST NOT throw synchronously, MUST shut down
  //    runner + device storage, MUST still persist s2's pending me to SQLite, and MUST return a rejecting Promise!
  {
    const { host } = setupTwoAccountHost();
    host.memoryDb = undefined;
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    await run(seed.inner.data.written);
    await seed.close();

    host.onFetch((req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1") return jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-a-new", name: "A New" }], invitations: [], relay_url: "https://relay.test" });
        if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-b-new", name: "B New" }], invitations: [], relay_url: "https://relay.test" });
      }
      return jsonResponse(200, {});
    });

    let failOpen = true;
    let failS1OnClose = false;
    let failS2Once = true;
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) => {
      if (failOpen) return Effect.fail(new HostError("disk unavailable"));
      return Effect.map(origOpen(name), (raw) => ({
        exec(sql: string) {
          if (name === dbName("s1") && failS1OnClose && /^\s*COMMIT\b/i.test(sql)) {
            throw new SqlError("SQLITE_FULL: database or disk is full", "full");
          }
          if (name === dbName("s2") && failS2Once && /^\s*COMMIT\b/i.test(sql)) {
            failS2Once = false;
            throw new SqlError("SQLITE_FULL: database or disk is full", "full");
          }
          raw.exec(sql);
        },
        run(sql: string, params?: readonly SqlValue[]) { return raw.run(sql, params); },
        all(sql: string, params?: readonly SqlValue[]) {
          if (name === dbName("s1") && failS1OnClose && /account_doc/i.test(sql)) {
            throw new SqlError("SQLITE_IOERR: disk I/O error", "other");
          }
          return raw.all(sql, params);
        },
        close() { raw.close(); },
      }));
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    await run(core.inner.cloudSync.refreshAccount("s1"));
    await run(core.inner.cloudSync.refreshAccount("s2"));

    failOpen = false;
    failS1OnClose = true;
    await run(core.inner.data.openAccounts(["s1", "s2"]));

    // Must return a Promise (not throw synchronously!), shut down runner, flush s2, and reject with s1's error!
    const closePromise = core.close();
    assert.ok(closePromise instanceof Promise, "Core.close() must return a Promise even on SQLITE_IOERR");
    await assert.rejects(() => closePromise, /failed to persist authoritative \/v1\/me on close: me\/s1/);
    assert.equal(core.inner.runner.closed, true, "runner must be shut down even when flushLiveMe fails");

    // Verify s2's updated me (containing ws-b-new) WAS persisted on disk despite s1's SQLITE_IOERR!
    failS1OnClose = false;
    host.onFetch(() => jsonResponse(503, {}));
    const core2 = await Core.create(host, { clock: host.time.clock });
    await run(core2.inner.data.openAccounts(["s1", "s2"]));
    assert.equal(core2.inner.workspaces.owner("ws-b-new"), "s2", "s2's pending /v1/me was persisted despite s1 IO error");
    assert.equal(core2.inner.workspaces.owner("ws-a-new"), "s1", "s1's pending /v1/me also survived via device pendingMe");
    await core2.close();
  }

  // 3) P2-3: SQLITE_FULL thrown as proper SqlError("full") during adoptDb produces zero unhandled fiber failures!
  {
    const origError = console.error;
    const errors: string[] = [];
    console.error = (...args: unknown[]) => {
      errors.push(args.map(String).join(" "));
      origError(...args);
    };
    try {
      const { host } = setupTwoAccountHost();
      host.memoryDb = undefined;
      const seed = await Core.create(host, { clock: host.time.clock });
      await run(seed.inner.data.openAccounts(["s1", "s2"]));
      seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
      seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
      await run(seed.inner.data.written);
      await seed.close();

      host.onFetch((req) => {
        const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
        if (req.url.endsWith("/v1/me")) {
          if (auth === "Bearer access-s1") return jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
          if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
        }
        return jsonResponse(200, {});
      });

      let failA = true;
      let injectOnce = true;
      const origOpen = host.openDb.bind(host);
      host.openDb = (name: string) => {
        if (name === dbName("s1") && failA) return Effect.fail(new HostError("disk unavailable"));
        return Effect.map(origOpen(name), (raw) => {
          if (name !== dbName("s1")) return raw;
          return {
            exec(sql: string) { raw.exec(sql); },
            run(sql: string, params?: readonly SqlValue[]) {
              if (injectOnce && /account_doc/i.test(sql)) {
                injectOnce = false;
                throw new SqlError("SQLITE_FULL: database or disk is full", "full");
              }
              return raw.run(sql, params);
            },
            all(sql: string, params?: readonly SqlValue[]) { return raw.all(sql, params); },
            close() { raw.close(); },
          };
        });
      };

      const core = await Core.create(host, { clock: host.time.clock });
      await run(core.inner.data.openAccount("s1"));
      await run(core.inner.cloudSync.refreshAccount("s1"));
      failA = false;
      await run(core.inner.data.openAccount("s1"));
      await host.settle();
      await run(core.inner.data.written);
      await core.close();
      assert.equal(errors.some((e) => e.includes("core fiber failed")), false, `expected zero unhandled fiber failures, got: ${errors.join("; ")}`);
    } finally {
      console.error = origError;
    }
  }
});

test("R14 regressions: ephemeral memoryDb keeps pendingMe until disk DB persists, unread device/choice never clobbers pendingMe or leaks to B, and IOERR on SELECT still runs resumeFor with zero unhandled fiber failures", async () => {
  // 1) P0-1: A before B; A's disk DB has stale me without ws-w, B holds ws-w. On busy disk, host provides writable
  //    ephemeral memoryDb(); authoritative /v1/me gives A ws-w -> online owner is A, pendingMe[A] MUST stay saved.
  //    Close cleanly, disk recovers, restart offline -> owner MUST stay A and draft lands ONLY in A (never B)!
  {
    const { host } = setupTwoAccountHost();
    host.memoryDb = () => new NodeSql(new DatabaseSync(":memory:"));
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }] });
    seed.inner.cloudSync.recomputeOwners();
    await run(seed.inner.data.written);
    await seed.close();

    host.onFetch((req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1") return jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
        if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
      }
      return jsonResponse(200, {});
    });

    let busyA = true;
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      name === dbName("s1") && busyA
        ? Effect.succeed({
            exec() { throw new SqlError("SQLITE_BUSY: database is locked", "busy"); },
            run() { throw new SqlError("SQLITE_BUSY: database is locked", "busy"); },
            all() { throw new SqlError("SQLITE_BUSY: database is locked", "busy"); },
            close() {},
          })
        : origOpen(name);

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccount("s1"));
    assert.equal(core.inner.data.notes.get("s1")?.kind, "busy", "s1 fell back to ephemeral memoryDb");
    assert.equal(core.inner.data.isPersistentDb(core.inner.data.db("s1")), false, "memoryDb is ephemeral");
    await run(core.inner.cloudSync.refreshAccount("s1"));
    await run(core.inner.data.written);
    await host.settle();
    assert.equal(core.inner.workspaces.owner("ws-w"), "s1");
    assert.ok((core.inner.data.device.get("choice", "pendingMe") as J)?.s1 !== undefined, "pendingMe[s1] MUST remain saved while on ephemeral memoryDb");
    await core.close();

    // Disk recovers; restart completely offline!
    busyA = false;
    host.onFetch(() => jsonResponse(503, {}));
    const core2 = await Core.create(host, { clock: host.time.clock });
    await run(core2.inner.data.openAccounts(["s1", "s2"]));
    await run(core2.inner.data.written);
    assert.equal(core2.inner.workspaces.owner("ws-w"), "s1", "owner MUST stay A on offline restart after memoryDb run");

    const ui2 = core2.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core2.inner.host.emit.bind(core2.inner.host);
    core2.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 1201 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core2.receive(ui2, { kind: "call", id: 1201, call: "composer.text", params: { key: "new:ws-w", text: "after-memorydb-only-a" } });
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res);
    await host.time.pass(350);
    await run(core2.inner.data.written);
    assert.equal(core2.inner.data.db("s1")!.draft("ws-w", "new")?.text, "after-memorydb-only-a", "draft landed ONLY in A");
    assert.equal(core2.inner.data.db("s2")!.draft("ws-w", "new"), undefined, "B SQLite stayed empty");
    await core2.close();
  }

  // 2) P0-2: Saved pendingMe[A] exists in device/choice. On offline restart, FIRST storageGet("device/choice") fails,
  //    all subsequent reads/writes succeed. Device MUST NOT overwrite device/choice with empty table and MUST reload
  //    pendingMe[A] before allowing writes (so owner resolves to A and draft lands ONLY in A, never B)!
  {
    const { host } = setupTwoAccountHost();
    host.memoryDb = undefined;
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }] });
    await run(seed.inner.data.written);
    await seed.close();

    host.onFetch((req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1") return jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
        if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
      }
      return jsonResponse(200, {});
    });

    let failA = true;
    const origOpen = host.openDb.bind(host);
    host.openDb = (name: string) =>
      name === dbName("s1") && failA ? Effect.fail(new HostError("disk unavailable")) : origOpen(name);

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccount("s1"));
    await run(core.inner.cloudSync.refreshAccount("s1"));
    await core.close();

    // Disk recovers, restart offline, and fail ONLY the first storageGet("device/choice")!
    failA = false;
    host.onFetch(() => jsonResponse(503, {}));
    let failChoiceOnce = true;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) => {
      if (key === "device/choice" && failChoiceOnce) {
        failChoiceOnce = false;
        return Effect.fail(new HostError("transient device/choice read error"));
      }
      return origGet(key);
    };

    const core2 = await Core.create(host, { clock: host.time.clock });
    await run(core2.inner.data.openAccounts(["s1", "s2"]));
    assert.equal(core2.inner.data.device.isUnloaded("choice"), true, "choice marked unloaded on read error");
    assert.equal(core2.inner.workspaces.owner("ws-w"), null, "B must NOT steal ws-w while device/choice is unloaded");

    // First write retries reload("choice") -> hydrates pendingMe[s1] -> adopts into s1 -> lands ONLY in A!
    const ui2 = core2.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core2.inner.host.emit.bind(core2.inner.host);
    core2.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 1202 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core2.receive(ui2, { kind: "call", id: 1202, call: "composer.text", params: { key: "new:ws-w", text: "after-choice-reload-only-a" } });
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res, `write after transient choice reload must succeed into A, got: ${JSON.stringify(res)}`);
    await host.time.pass(350);
    await run(core2.inner.data.written);
    assert.equal(core2.inner.workspaces.owner("ws-w"), "s1", "owner resolved to A after choice reload");
    assert.equal(core2.inner.data.db("s1")!.draft("ws-w", "new")?.text, "after-choice-reload-only-a", "draft landed ONLY in A");
    assert.equal(core2.inner.data.db("s2")!.draft("ws-w", "new"), undefined, "B SQLite stayed empty");
    await core2.close();
  }

  // 3) P1-3: When A holds authoritative #liveMe and disk SELECT on account_doc throws SQLITE_IOERR during publish,
  //    recomputeOwners() MUST NOT throw, viewCalls.resumeFor(A) MUST execute, and ZERO unhandled fiber failures occur!
  {
    const origError = console.error;
    const errors: string[] = [];
    console.error = (...args: unknown[]) => {
      errors.push(args.map(String).join(" "));
      origError(...args);
    };
    try {
      const { host } = setupTwoAccountHost();
      host.memoryDb = undefined;
      const seed = await Core.create(host, { clock: host.time.clock });
      await run(seed.inner.data.openAccounts(["s1", "s2"]));
      seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
      seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
      await run(seed.inner.data.written);
      await seed.close();

      host.onFetch((req) => {
        const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
        if (req.url.endsWith("/v1/me")) {
          if (auth === "Bearer access-s1") return jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
          if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }], invitations: [], relay_url: "https://relay.test" });
        }
        return jsonResponse(200, {});
      });

      let failA = true;
      let ioerrSelect = false;
      const origOpen = host.openDb.bind(host);
      host.openDb = (name: string) => {
        if (name === dbName("s1") && failA) return Effect.fail(new HostError("disk unavailable"));
        return Effect.map(origOpen(name), (raw) => {
          if (name !== dbName("s1")) return raw;
          return {
            exec(sql: string) { raw.exec(sql); },
            run(sql: string, params?: readonly SqlValue[]) { return raw.run(sql, params); },
            all(sql: string, params?: readonly SqlValue[]) {
              if (ioerrSelect && /account_doc/i.test(sql)) {
                throw new SqlError("SQLITE_IOERR: disk I/O error", "other");
              }
              return raw.all(sql, params);
            },
            close() { raw.close(); },
          };
        });
      };

      const core = await Core.create(host, { clock: host.time.clock });
      await run(core.inner.data.openAccount("s1"));
      await run(core.inner.cloudSync.refreshAccount("s1"));
      const resumedSubs: string[] = [];
      const origResume = core.inner.viewCalls.resumeFor.bind(core.inner.viewCalls);
      core.inner.viewCalls.resumeFor = (db) => {
        resumedSubs.push(db.sub);
        origResume(db);
      };

      failA = false;
      ioerrSelect = true;
      await run(core.inner.data.openAccount("s1"));
      assert.ok(resumedSubs.includes("s1"), `viewCalls.resumeFor(s1) MUST execute despite account_doc SELECT SQLITE_IOERR, got: ${JSON.stringify(resumedSubs)}`);
      assert.equal(core.inner.workspaces.owner("ws-w"), "s1", "owner stays A from #liveMe despite SQLITE_IOERR");
      assert.equal(errors.some((e) => e.includes("core fiber failed")), false, `expected zero unhandled fiber failures during IOERR publish, got: ${errors.join("; ")}`);
      ioerrSelect = false;
      await core.close();
    } finally {
      console.error = origError;
    }
  }
});

test("R15 regressions: reloaded stale pendingMe never overwrites fresher SQLite /v1/me, sign-out during choice reload cancels edit, and choice reload drains queued credential deletes", async () => {
  // 1) P0-1: A before B; stale disk pendingMe[A] has only [ws1], B holds ws-w. Initial device/choice read fails.
  //    A receives fresher /v1/me [ws1, ws-w] and commits to A's SQLite. Then composer.text("new:ws-w") triggers
  //    choice reload -> stale pendingMe[A] MUST be pruned (NOT overwrite A's SQLite!) and draft lands ONLY in A!
  {
    const { host } = setupTwoAccountHost();
    host.store("device/choice", {
      pendingMe: { s1: { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }], invitations: [], relay_url: "https://relay.test" } },
    });
    host.onFetch((req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1") return jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
        if (auth === "Bearer access-s2") return jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" });
      }
      return jsonResponse(200, {});
    });
    let failChoiceOnce = true;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) => {
      if (key === "device/choice" && failChoiceOnce) {
        failChoiceOnce = false;
        return Effect.fail(new HostError("transient choice read fail"));
      }
      return origGet(key);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    await run(core.inner.cloudSync.refreshAccount("s1"));
    await run(core.inner.cloudSync.refreshAccount("s2"));
    await run(core.inner.data.written);
    await host.settle();
    assert.equal((core.inner.data.db("s1")!.accountDoc("me") as J)?.workspaces?.length, 2, "A SQLite has [ws1, ws-w]");

    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 1301 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 1301, call: "composer.text", params: { key: "new:ws-w", text: "must-stay-in-a" } });
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res, `edit must succeed in A, got: ${JSON.stringify(res)}`);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal((core.inner.data.db("s1")!.accountDoc("me") as J)?.workspaces?.length, 2, "stale pendingMe must NOT revert A SQLite to [ws1]");
    assert.equal(core.inner.workspaces.owner("ws-w"), "s1");
    assert.equal(core.inner.data.db("s1")!.draft("ws-w", "new")?.text, "must-stay-in-a", "draft landed ONLY in A");
    assert.equal(core.inner.data.db("s2")!.draft("ws-w", "new"), undefined, "B SQLite stayed empty");
    await core.close();
  }

  // 2) P0-2: A & B both hold ws-w (A's DB lists ws-w). Initial device/choice read fails. composer.text("new:ws-w")
  //    pauses during the second storageGet("device/choice"); A signs out while paused; resume -> edit MUST cancel
  //    and B's SQLite MUST remain untouched!
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }] });
    await run(seed.inner.data.written);
    await seed.close();

    let choiceGets = 0;
    const reloadStarted = Deferred.makeUnsafe<void>();
    const reloadGate = Deferred.makeUnsafe<void>();
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) => {
      if (key === "device/choice") {
        choiceGets++;
        if (choiceGets === 1) return Effect.fail(new HostError("initial choice read fail"));
        if (choiceGets === 2) {
          Deferred.doneUnsafe(reloadStarted, Effect.void);
          return Effect.andThen(Deferred.await(reloadGate), origGet(key));
        }
      }
      return origGet(key);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    assert.equal(core.inner.data.device.isUnloaded("choice"), true);

    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 1302 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 1302, call: "composer.text", params: { key: "new:ws-w", text: "signed-out-during-choice-reload" } });
    await Effect.runPromise(Deferred.await(reloadStarted));
    // Sign out A while device/choice reload is paused!
    await run(core.inner.accounts.signOut("s1"));
    Deferred.doneUnsafe(reloadGate, Effect.void);
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.equal(res.error?.code, "cancelled", `composer.text MUST cancel when A signs out during choice reload, got: ${JSON.stringify(res)}`);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s2")!.draft("ws-w", "new"), undefined, "B SQLite MUST stay empty after A signed out during choice reload");
    await core.close();
  }

  // 3) P1-3: Queued pendingCredentialDeletes exists in device/choice with matching credential in host.storage.
  //    Initial device/choice read fails; later an edit triggers choice reload -> queued credential MUST be deleted
  //    and dequeued in this same run without restarting!
  {
    const { host } = setupTwoAccountHost();
    const staleKey = "credential/s-old/ws-old";
    host.store(staleKey, { token: "stale-secret", expires_at: Math.floor(host.nowMs() / 1000) + 3600 });
    host.store("device/choice", { pendingCredentialDeletes: [staleKey], workspaceOwners: { ws1: "s1", ws2: "s2" } });
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    await run(seed.inner.data.written);
    await seed.close();
    // Re-seed staleKey + queue after seed Core drained it during seed startup.
    host.store(staleKey, { token: "stale-secret", expires_at: Math.floor(host.nowMs() / 1000) + 3600 });
    host.store("device/choice", { pendingCredentialDeletes: [staleKey], workspaceOwners: { ws1: "s1", ws2: "s2" } });

    let failChoiceOnce = true;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) => {
      if (key === "device/choice" && failChoiceOnce) {
        failChoiceOnce = false;
        return Effect.fail(new HostError("initial choice read fail"));
      }
      return origGet(key);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    assert.equal(core.inner.data.device.isUnloaded("choice"), true);
    assert.ok(host.stored(staleKey) !== undefined, "stale credential still present before choice reload");

    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 1303 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 1303, call: "composer.text", params: { key: "new:ws1", text: "trigger-reload" } });
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res);
    await host.settle();
    assert.equal(core.inner.data.device.isUnloaded("choice"), false, "choice reloaded");
    assert.equal(host.stored(staleKey), undefined, "queued credential MUST be deleted in the same run upon choice reload");
    assert.equal(core.inner.data.device.get("choice", "pendingCredentialDeletes"), undefined, "pendingCredentialDeletes queue emptied in the same run");
    await core.close();
  }

  // 4) Close reconciliation: stale disk pendingMe[A]=[ws1] + initial device/choice read fail + A receives fresher
  //    /v1/me [ws1, ws-w] and commits to persistent SQLite + NO writes made before close:
  //    (a) if device/choice stays unreadable at close, Core.close() MUST reject;
  //    (b) if device/choice recovers by close, Core.close() strips stale pendingMe[A] so offline restart keeps A owning ws-w.
  for (const choiceRecoversOnClose of [false, true]) {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }] });
    await run(seed.inner.data.written);
    seed.inner.data.device.put("choice", "pendingMe", {
      s1: { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] },
    });
    await seed.close();

    let failChoice = true;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) => {
      if (key === "device/choice" && failChoice) {
        return Effect.fail(new HostError("choice storage unavailable"));
      }
      return origGet(key);
    };
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me") && auth === "Bearer access-s1") {
        return Effect.succeed(
          jsonResponse(200, {
            user: { sub: "s1" },
            workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }],
            invitations: [],
            relay_url: "https://relay.test",
          }),
        );
      }
      return origFetch(req);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    await run(core.inner.cloudSync.refreshAccount("s1"));
    await run(core.inner.data.written);
    assert.equal((core.inner.data.db("s1")!.accountDoc("me") as J)?.workspaces?.length, 2);
    assert.equal(core.inner.data.device.isUnloaded("choice"), true);

    if (choiceRecoversOnClose) {
      failChoice = false;
      await core.close();
      // Restart offline with device/choice readable: A's SQLite MUST NOT revert to stale [ws1]!
      host.fetch = (req) =>
        req.url.endsWith("/v1/me")
          ? Effect.succeed(jsonResponse(503, { error: "offline" }))
          : origFetch(req);
      const restarted = await Core.create(host, { clock: host.time.clock });
      await run(restarted.inner.data.openAccounts(["s1", "s2"]));
      assert.equal((restarted.inner.data.db("s1")!.accountDoc("me") as J)?.workspaces?.length, 2, "stale pendingMe was cleared on close");
      assert.equal(restarted.inner.workspaces.owner("ws-w"), "s1", "A still owns ws-w after offline restart");
      await restarted.close();
    } else {
      await assert.rejects(
        () => core.close(),
        /device\/choice/,
        "Core.close() MUST reject when stale disk pendingMe cannot be cleared because device/choice stays unreadable",
      );
    }
  }
});

test("R16 regressions: single-flight device/choice reload, unloaded sign-out credential cleanup, and unrelated sign-out during choice reload", async () => {
  // 1) P0-1: Initial device/choice read fails (stale pendingMe[A] = [ws1]). A receives 200 [ws1, ws-w] and commits to
  //    SQLite, then a subsequent refresh returns 503. Two concurrent cloudSync.owner("ws-w") calls trigger choice
  //    reload simultaneously -> single-flight reload + #persistedMeGen ensures BOTH return "s1", A's SQLite keeps
  //    [ws1, ws-w], and composer.text("new:ws-w") lands ONLY in A (B stays empty)!
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }] });
    await run(seed.inner.data.written);
    seed.inner.data.device.put("choice", "pendingMe", {
      s1: { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] },
    });
    await seed.close();

    let choiceGets = 0;
    const reloadStarted = Deferred.makeUnsafe<void>();
    const reloadGate = Deferred.makeUnsafe<void>();
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) => {
      if (key === "device/choice") {
        choiceGets++;
        if (choiceGets === 1) return Effect.fail(new HostError("initial choice read fail"));
        if (choiceGets === 2) {
          Deferred.doneUnsafe(reloadStarted, Effect.void);
          return Effect.andThen(Deferred.await(reloadGate), origGet(key));
        }
      }
      return origGet(key);
    };

    let s1MeCalls = 0;
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me") && auth === "Bearer access-s1") {
        s1MeCalls++;
        if (s1MeCalls === 1) {
          return Effect.succeed(
            jsonResponse(200, {
              user: { sub: "s1" },
              workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }],
              invitations: [],
              relay_url: "https://relay.test",
            }),
          );
        }
        return Effect.succeed(jsonResponse(503, { error: "transient outage" }));
      }
      return origFetch(req);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    assert.equal(core.inner.data.device.isUnloaded("choice"), true);
    // 1st refresh: 200 -> persists [ws1, ws-w] to A's SQLite.
    await run(core.inner.cloudSync.refreshAccount("s1"));
    await run(core.inner.data.written);
    assert.equal((core.inner.data.db("s1")!.accountDoc("me") as J)?.workspaces?.length, 2);
    // 2nd refresh: 503 -> overwrites this.mes.get("s1") with error.
    await run(core.inner.cloudSync.refreshAccount("s1"));

    // Fire TWO concurrent owner("ws-w") calls while device/choice is unloaded.
    const p1 = run(core.inner.cloudSync.owner("ws-w"));
    await Effect.runPromise(Deferred.await(reloadStarted));
    const p2 = run(core.inner.cloudSync.owner("ws-w"));
    Deferred.doneUnsafe(reloadGate, Effect.void);
    const [o1, o2] = await Promise.all([p1, p2]);
    assert.equal(choiceGets, 2, "concurrent reloads must coalesce into a single storageGet");
    assert.equal(o1, "s1", "first concurrent owner() must return A");
    assert.equal(o2, "s1", "second concurrent owner() must also return A");
    assert.equal((core.inner.data.db("s1")!.accountDoc("me") as J)?.workspaces?.length, 2, "A SQLite must keep [ws1, ws-w]");

    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 1401 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 1401, call: "composer.text", params: { key: "new:ws-w", text: "concurrent-reload-stays-in-a" } });
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res, `composer.text should succeed into A, got: ${JSON.stringify(res)}`);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s1")!.draft("ws-w", "new")?.text, "concurrent-reload-stays-in-a");
    assert.equal(core.inner.data.db("s2")!.draft("ws-w", "new"), undefined, "B SQLite MUST stay empty");
    await core.close();
  }

  // 2) P1-2: A's SQLite no longer lists "ws-past", host storage still holds credential/s1/ws-past.
  //    Initial device/choice read fails -> A signs out -> later choice reload (triggered by B's edit OR Core.close())
  //    MUST collect and delete credential/s1/ws-past whether "ws-past" lived in credWorkspaces/s1 or pendingMe[s1].
  for (const mode of ["credWorkspaces-midrun", "pendingMe-midrun", "pendingMe-close"] as const) {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    await run(seed.inner.data.written);
    await seed.close();

    const pastCred = "credential/s1/ws-past";
    host.store(pastCred, { token: "old-past-token", expires_at: Math.floor(host.nowMs() / 1000) + 3600 });
    if (mode === "credWorkspaces-midrun") {
      host.store("device/choice", { "credWorkspaces/s1": ["ws-past"], workspaceOwners: { ws1: "s1", ws2: "s2" } });
    } else {
      host.store("device/choice", {
        pendingMe: { s1: { user: { sub: "s1" }, workspaces: [{ id: "ws-past", name: "Past" }] } },
        workspaceOwners: { ws1: "s1", ws2: "s2" },
      });
    }

    let failChoiceOnce = true;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) => {
      if (key === "device/choice" && failChoiceOnce) {
        failChoiceOnce = false;
        return Effect.fail(new HostError("initial choice read fail"));
      }
      return origGet(key);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    assert.equal(core.inner.data.device.isUnloaded("choice"), true);
    await run(core.inner.accounts.signOut("s1"));
    assert.ok(host.stored(pastCred) !== undefined, `${mode}: credential still exists before choice reloads`);

    if (mode === "pendingMe-close") {
      await core.close();
      assert.equal(host.stored(pastCred), undefined, "pendingMe-close: close reload MUST delete historical credential");
    } else {
      const ui = core.connect();
      const ack = Deferred.makeUnsafe<J>();
      const origEmit = core.inner.host.emit.bind(core.inner.host);
      core.inner.host.emit = (c, m) => {
        origEmit(c, m);
        if (m.id === 1402 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
      };
      core.receive(ui, { kind: "call", id: 1402, call: "composer.text", params: { key: "new:ws2", text: "b-triggers-reload" } });
      const res = await Effect.runPromise(Deferred.await(ack));
      assert.ok("ok" in res);
      await host.settle();
      assert.equal(host.stored(pastCred), undefined, `${mode}: historical credential MUST be deleted once choice reloads`);
      assert.equal(core.inner.data.device.get("choice", "pendingCredentialDeletes"), undefined, `${mode}: queue drained`);
      await core.close();
    }
  }

  // 3) P1-3: A is 1st and exclusively holds ws1; B is 2nd and never holds ws1. Initial device/choice read fails.
  //    composer.text("new:ws1") pauses during choice reload; unrelated B signs out while paused; resume ->
  //    call MUST succeed and draft MUST land in A's SQLite!
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    await run(seed.inner.data.written);
    await seed.close();

    let choiceGets = 0;
    const reloadStarted = Deferred.makeUnsafe<void>();
    const reloadGate = Deferred.makeUnsafe<void>();
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) => {
      if (key === "device/choice") {
        choiceGets++;
        if (choiceGets === 1) return Effect.fail(new HostError("initial choice read fail"));
        if (choiceGets === 2) {
          Deferred.doneUnsafe(reloadStarted, Effect.void);
          return Effect.andThen(Deferred.await(reloadGate), origGet(key));
        }
      }
      return origGet(key);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    assert.equal(core.inner.data.device.isUnloaded("choice"), true);

    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 1403 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 1403, call: "composer.text", params: { key: "new:ws1", text: "unrelated-b-signout-ok" } });
    await Effect.runPromise(Deferred.await(reloadStarted));
    // Sign out unrelated lower-priority account B while choice reload is paused!
    await run(core.inner.accounts.signOut("s2"));
    Deferred.doneUnsafe(reloadGate, Effect.void);
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res, `unrelated B sign-out must NOT cancel A's edit to ws1, got: ${JSON.stringify(res)}`);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s1")!.draft("ws1", "new")?.text, "unrelated-b-signout-ok", "draft MUST land in A's SQLite");
    await core.close();
  }
});

test("R17 regressions: pre-merge disk owner sign-out, caller-independent single-flight reload, re-login pendingMe cleanup, and cross-process orphan cleanup", async () => {
  // 1) P0-1: A before B, neither SQLite lists ws-w; disk pendingMe[B] and workspaceOwners[ws-w] both point to B.
  //    Initial choice read fails; composer.text("new:ws-w") pauses during choice reload; during pause A receives
  //    /v1/me listing ws-w AND B signs out -> resume MUST cancel and A's SQLite MUST remain empty!
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    await run(seed.inner.data.written);
    seed.inner.data.device.put("choice", "workspaceOwners", { ws1: "s1", ws2: "s2", "ws-w": "s2" });
    seed.inner.data.device.put("choice", "pendingMe", {
      s2: { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }] },
    });
    await seed.close();

    let choiceGets = 0;
    const reloadStarted = Deferred.makeUnsafe<void>();
    const reloadGate = Deferred.makeUnsafe<void>();
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) => {
      if (key === "device/choice") {
        choiceGets++;
        if (choiceGets === 1) return Effect.fail(new HostError("initial choice read fail"));
        if (choiceGets === 2) {
          Deferred.doneUnsafe(reloadStarted, Effect.void);
          return Effect.andThen(Deferred.await(reloadGate), origGet(key));
        }
      }
      return origGet(key);
    };
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me") && auth === "Bearer access-s1") {
        return Effect.succeed(
          jsonResponse(200, {
            user: { sub: "s1" },
            workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }],
            invitations: [],
            relay_url: "https://relay.test",
          }),
        );
      }
      return origFetch(req);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    assert.equal(core.inner.data.device.isUnloaded("choice"), true);

    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 1501 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 1501, call: "composer.text", params: { key: "new:ws-w", text: "must-not-jump-to-a" } });
    await Effect.runPromise(Deferred.await(reloadStarted));
    // During reload pause: A gains ws-w via /v1/me, and disk owner B signs out!
    await run(core.inner.cloudSync.refreshAccount("s1"));
    await run(core.inner.accounts.signOut("s2"));
    Deferred.doneUnsafe(reloadGate, Effect.void);
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.equal(res.error?.code, "cancelled", `edit for disk-owned ws-w MUST cancel when B signs out, got: ${JSON.stringify(res)}`);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s1")!.draft("ws-w", "new"), undefined, "A SQLite MUST stay empty");
    await core.close();
  }

  // 2) P1-2: First caller owner("ws1") initiates choice reload and is interrupted; independent composer.text("new:ws1")
  //    waiting on the same single-flight reload MUST still succeed once storage resolves!
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    await run(seed.inner.data.written);
    await seed.close();

    let choiceGets = 0;
    const reloadStarted = Deferred.makeUnsafe<void>();
    const reloadGate = Deferred.makeUnsafe<void>();
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) => {
      if (key === "device/choice") {
        choiceGets++;
        if (choiceGets === 1) return Effect.fail(new HostError("initial choice read fail"));
        if (choiceGets === 2) {
          Deferred.doneUnsafe(reloadStarted, Effect.void);
          return Effect.andThen(Deferred.await(reloadGate), origGet(key));
        }
      }
      return origGet(key);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));

    const firstFiber = core.inner.runner.fork(core.inner.cloudSync.owner("ws1"));
    await Effect.runPromise(Deferred.await(reloadStarted));

    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 1502 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 1502, call: "composer.text", params: { key: "new:ws1", text: "survives-first-waiter-cancel" } });
    await host.settle();
    // Interrupt ONLY the first waiter fiber!
    await run(Fiber.interrupt(firstFiber));
    Deferred.doneUnsafe(reloadGate, Effect.void);
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res, `second caller must survive first waiter interrupt, got: ${JSON.stringify(res)}`);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s1")!.draft("ws1", "new")?.text, "survives-first-waiter-cancel");
    await core.close();
  }

  // 3) P1-3: ws-past exists ONLY in disk pendingMe[A]. Choice initial read fails; A signs out, then signs BACK IN
  //    without an available DB and receives new /v1/me [ws1] (overwriting merged pendingMe[A]). B's edit triggers
  //    choice reload -> credential/s1/ws-past MUST still be deleted from pre-merge disk snapshot!
  {
    const { host } = setupTwoAccountHost();
    host.memoryDb = undefined;
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    await run(seed.inner.data.written);
    await seed.close();

    const pastCred = "credential/s1/ws-past";
    host.store(pastCred, { token: "stale-past-secret", expires_at: Math.floor(host.nowMs() / 1000) + 3600 });
    host.store("device/choice", {
      pendingMe: { s1: { user: { sub: "s1" }, workspaces: [{ id: "ws-past", name: "Past" }] } },
      workspaceOwners: { ws1: "s1", ws2: "s2" },
    });

    let failChoiceOnce = true;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) => {
      if (key === "device/choice" && failChoiceOnce) {
        failChoiceOnce = false;
        return Effect.fail(new HostError("initial choice read fail"));
      }
      return origGet(key);
    };
    const origOpen = host.openDb.bind(host);
    let blockS1Db = false;
    host.openDb = (name: string) =>
      blockS1Db && name === dbName("s1") ? Effect.fail(new HostError("disk unavailable")) : origOpen(name);
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me") && auth === "Bearer access-s1-relogin") {
        return Effect.succeed(
          jsonResponse(200, {
            user: { sub: "s1" },
            workspaces: [{ id: "ws1", name: "WS 1" }],
            invitations: [],
            relay_url: "https://relay.test",
          }),
        );
      }
      return origFetch(req);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    await run(core.inner.accounts.signOut("s1"));
    // Re-login A with unavailable DB, and receive new /v1/me [ws1] into pendingMe[s1].
    blockS1Db = true;
    await run(
      core.inner.accounts.migrate([
        {
          sub: "s1",
          email: "s1@test",
          name: "S1",
          access: "access-s1-relogin",
          refresh: "refresh-s1-relogin",
          accessExpires: Math.floor(host.nowMs() / 1000) + 3600,
        },
      ]),
    );
    await run(core.inner.cloudSync.refreshAccount("s1"));
    assert.equal(core.inner.data.device.isUnloaded("choice"), true);

    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 1503 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 1503, call: "composer.text", params: { key: "new:ws2", text: "trigger-reload-after-relogin" } });
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res);
    await host.settle();
    assert.equal(host.stored(pastCred), undefined, "old generation credential/s1/ws-past MUST be deleted despite re-login pendingMe overwrite");
    assert.equal(core.inner.data.device.get("choice", "pendingCredentialDeletes"), undefined);
    await core.close();
  }

  // 4) P1-4: A signs out while choice stays unreadable through Core.close() (close rejects as designed).
  //    Storage recovers and a fresh Core starts with only B signed in -> startup MUST collect & delete orphaned
  //    credential/s1/ws-past before pruning pendingMe[s1]!
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    await run(seed.inner.data.written);
    await seed.close();

    const pastCred = "credential/s1/ws-past";
    host.store(pastCred, { token: "orphan-past-secret", expires_at: Math.floor(host.nowMs() / 1000) + 3600 });
    host.store("device/choice", {
      pendingMe: { s1: { user: { sub: "s1" }, workspaces: [{ id: "ws-past", name: "Past" }] } },
      workspaceOwners: { ws1: "s1", ws2: "s2" },
    });

    let failChoice = true;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) =>
      key === "device/choice" && failChoice ? Effect.fail(new HostError("choice storage unavailable")) : origGet(key);

    const core1 = await Core.create(host, { clock: host.time.clock });
    await run(core1.inner.data.openAccounts(["s1", "s2"]));
    await run(core1.inner.accounts.signOut("s1"));
    await assert.rejects(() => core1.close(), /device\/choice/);
    assert.ok(host.stored(pastCred) !== undefined, "credential still exists after failed close");

    // Recover storage and start fresh Core (accounts list has only s2 now).
    failChoice = false;
    const core2 = await Core.create(host, { clock: host.time.clock });
    await host.settle();
    await core2.close();
    assert.equal(host.stored(pastCred), undefined, "fresh Core MUST collect and delete orphaned credential/s1/ws-past");
    const choiceAfter = host.stored("device/choice") as J | undefined;
    assert.equal(choiceAfter?.pendingMe, undefined, "orphaned pendingMe pruned");
    assert.equal(choiceAfter?.pendingCredentialDeletes, undefined, "delete queue drained");
  }
});

test("R18 regressions: accounts load fail preserves creds/pendingMe, runner-owned choice recovery on sole-waiter cancel, disk-owner membership loss, secondary member sign-out, and cross-process relogin epoch", async () => {
  // 1) P0-1: storageGet("accounts") fails once at startup while choice loads normally -> MUST NOT delete credentials
  //    or prune pendingMe[A]; subsequent normal offline restart MUST keep A owning ws-w and keep both credentials!
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }] });
    await run(seed.inner.data.written);
    seed.inner.data.device.put("choice", "pendingMe", {
      s1: { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }] },
    });
    seed.inner.data.device.put("choice", "credWorkspaces/s1", ["ws1", "ws-w"]);
    seed.inner.data.device.put("choice", "credWorkspaces/s2", ["ws2"]);
    await seed.close();

    const credA = "credential/s1/ws1";
    const credB = "credential/s2/ws2";
    host.store(credA, { token: "a-tok", expires_at: Math.floor(host.nowMs() / 1000) + 3600 });
    host.store(credB, { token: "b-tok", expires_at: Math.floor(host.nowMs() / 1000) + 3600 });

    let failAccounts = true;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) =>
      key === STORAGE_KEY && failAccounts ? Effect.fail(new HostError("accounts read failed")) : origGet(key);

    const core1 = await Core.create(host, { clock: host.time.clock });
    await host.settle();
    assert.equal(core1.inner.accounts.isUnloaded(), true);
    assert.ok(host.stored(credA) !== undefined, "credA MUST NOT be deleted when accounts failed to load");
    assert.ok(host.stored(credB) !== undefined, "credB MUST NOT be deleted when accounts failed to load");
    assert.ok((core1.inner.data.device.get("choice", "pendingMe") as J)?.s1 !== undefined, "pendingMe[s1] preserved");
    await core1.close();

    // Next normal offline start: A's pendingMe hydrates, A owns ws-w, draft lands in A (not B), both creds intact!
    failAccounts = false;
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) =>
      req.url.endsWith("/v1/me") ? Effect.succeed(jsonResponse(503, { error: "offline" })) : origFetch(req);
    const core2 = await Core.create(host, { clock: host.time.clock });
    await run(core2.inner.data.openAccounts(["s1", "s2"]));
    assert.equal(core2.inner.workspaces.owner("ws-w"), "s1", "A still owns ws-w after accounts-read-failure restart");
    assert.ok(host.stored(credA) !== undefined, "credA still present");
    assert.ok(host.stored(credB) !== undefined, "credB still present");

    const ui = core2.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core2.inner.host.emit.bind(core2.inner.host);
    core2.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 1601 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core2.receive(ui, { kind: "call", id: 1601, call: "composer.text", params: { key: "new:ws-w", text: "must-stay-in-a-after-acct-err" } });
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res);
    await host.time.pass(350);
    await run(core2.inner.data.written);
    assert.equal(core2.inner.data.db("s1")!.draft("ws-w", "new")?.text, "must-stay-in-a-after-acct-err");
    assert.equal(core2.inner.data.db("s2")!.draft("ws-w", "new"), undefined, "B SQLite stayed empty");
    await core2.close();
  }

  // 2) P0-2: Sole waiter owner("ws-w") pauses choice reload and is interrupted BEFORE storage resolves.
  //    Runner-owned reload MUST still run #onChoiceLoaded() (hydrate pendingMe[A], recompute owners, drain deletes),
  //    so subsequent B 503 + composer.text("new:ws-w") writes ONLY to A (not B) and deletes queued cred!
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }] });
    await run(seed.inner.data.written);
    await seed.close();

    const staleCred = "credential/s-old/ws-old";
    host.store(staleCred, { token: "stale", expires_at: Math.floor(host.nowMs() / 1000) + 3600 });
    host.store("device/choice", {
      pendingMe: { s1: { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }] } },
      pendingCredentialDeletes: [staleCred],
      workspaceOwners: { ws1: "s1", ws2: "s2", "ws-w": "s1" },
    });

    let choiceGets = 0;
    const reloadStarted = Deferred.makeUnsafe<void>();
    const reloadGate = Deferred.makeUnsafe<void>();
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) => {
      if (key === "device/choice") {
        choiceGets++;
        if (choiceGets === 1) return Effect.fail(new HostError("initial choice read fail"));
        if (choiceGets === 2) {
          Deferred.doneUnsafe(reloadStarted, Effect.void);
          return Effect.andThen(Deferred.await(reloadGate), origGet(key));
        }
      }
      return origGet(key);
    };
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) =>
      req.url.endsWith("/v1/me") ? Effect.succeed(jsonResponse(503, { error: "offline" })) : origFetch(req);

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    const soleFiber = core.inner.runner.fork(core.inner.cloudSync.owner("ws-w"));
    await Effect.runPromise(Deferred.await(reloadStarted));
    // Interrupt the ONLY waiter BEFORE releasing storage!
    await run(Fiber.interrupt(soleFiber));
    Deferred.doneUnsafe(reloadGate, Effect.void);
    await host.settle();

    assert.equal(core.inner.data.device.isUnloaded("choice"), false, "choice loaded by runner");
    assert.equal(host.stored(staleCred), undefined, "pendingCredentialDeletes drained even after sole waiter cancelled");
    // B refresh hits 503 and recomputes owners -> A MUST still own ws-w!
    await run(core.inner.cloudSync.refreshAccount("s2"));
    assert.equal(core.inner.workspaces.owner("ws-w"), "s1", "A hydrated as owner of ws-w even after sole waiter cancelled");

    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 1602 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 1602, call: "composer.text", params: { key: "new:ws-w", text: "sole-waiter-cancel-still-a" } });
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s1")!.draft("ws-w", "new")?.text, "sole-waiter-cancel-still-a");
    assert.equal(core.inner.data.db("s2")!.draft("ws-w", "new"), undefined, "B SQLite stayed empty");
    await core.close();
  }

  // 3) P0-3: Neither SQLite lists ws-w; disk workspaceOwners[ws-w] & pendingMe[B] both point to B.
  //    During choice reload pause, A gets 200 [ws1, ws-w] and B gets 200 [ws2] (B loses ws-w WITHOUT signing out!).
  //    Original edit MUST cancel and A's SQLite MUST remain empty!
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    await run(seed.inner.data.written);
    seed.inner.data.device.put("choice", "workspaceOwners", { ws1: "s1", ws2: "s2", "ws-w": "s2" });
    seed.inner.data.device.put("choice", "pendingMe", {
      s2: { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }] },
    });
    await seed.close();

    let choiceGets = 0;
    const reloadStarted = Deferred.makeUnsafe<void>();
    const reloadGate = Deferred.makeUnsafe<void>();
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) => {
      if (key === "device/choice") {
        choiceGets++;
        if (choiceGets === 1) return Effect.fail(new HostError("initial choice read fail"));
        if (choiceGets === 2) {
          Deferred.doneUnsafe(reloadStarted, Effect.void);
          return Effect.andThen(Deferred.await(reloadGate), origGet(key));
        }
      }
      return origGet(key);
    };
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me") && auth === "Bearer access-s1") {
        return Effect.succeed(jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }], invitations: [], relay_url: "https://relay.test" }));
      }
      if (req.url.endsWith("/v1/me") && auth === "Bearer access-s2") {
        return Effect.succeed(jsonResponse(200, { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }], invitations: [], relay_url: "https://relay.test" }));
      }
      return origFetch(req);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 1603 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 1603, call: "composer.text", params: { key: "new:ws-w", text: "disk-owner-lost-membership" } });
    await Effect.runPromise(Deferred.await(reloadStarted));
    // Both stay signed in: A gains ws-w, B loses ws-w!
    await run(core.inner.cloudSync.refreshAccount("s1"));
    await run(core.inner.cloudSync.refreshAccount("s2"));
    Deferred.doneUnsafe(reloadGate, Effect.void);
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.equal(res.error?.code, "cancelled", `disk-owner B losing membership MUST cancel edit, got: ${JSON.stringify(res)}`);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s1")!.draft("ws-w", "new"), undefined, "A SQLite stayed empty");
    await core.close();
  }

  // 4) P1-4: A is 1st and holds ws-w in SQLite + disk workspaceOwners[ws-w] = A; B's pendingMe ALSO lists ws-w.
  //    During choice reload pause, ONLY secondary member B signs out -> A remains owner and edit MUST succeed into A!
  {
    const { host } = setupTwoAccountHost();
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) =>
      req.url.endsWith("/v1/me") ? Effect.succeed(jsonResponse(503, { error: "offline" })) : origFetch(req);
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    await run(seed.inner.data.written);
    seed.inner.data.device.put("choice", "workspaceOwners", { ws1: "s1", ws2: "s2", "ws-w": "s1" });
    seed.inner.data.device.put("choice", "pendingMe", {
      s2: { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }] },
    });
    await seed.close();

    let choiceGets = 0;
    const reloadStarted = Deferred.makeUnsafe<void>();
    const reloadGate = Deferred.makeUnsafe<void>();
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) => {
      if (key === "device/choice") {
        choiceGets++;
        if (choiceGets === 1) return Effect.fail(new HostError("initial choice read fail"));
        if (choiceGets === 2) {
          Deferred.doneUnsafe(reloadStarted, Effect.void);
          return Effect.andThen(Deferred.await(reloadGate), origGet(key));
        }
      }
      return origGet(key);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    assert.equal(
      ((core.inner.data.db("s1")!.accountDoc("me") as J)?.workspaces ?? []).some((w: J) => w.id === "ws-w"),
      true,
      "s1 SQLite holds ws-w before edit",
    );
    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 1604 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 1604, call: "composer.text", params: { key: "new:ws-w", text: "secondary-b-signout-ok" } });
    await Effect.runPromise(Deferred.await(reloadStarted));
    await run(core.inner.accounts.signOut("s2"));
    Deferred.doneUnsafe(reloadGate, Effect.void);
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res, `signing out secondary member B must NOT cancel primary owner A's edit, got: ${JSON.stringify(res)}`);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s1")!.draft("ws-w", "new")?.text, "secondary-b-signout-ok");
    await core.close();
  }

  // 5) P1-5: Choice stays unreadable through sign-out -> re-login of A -> failed Core.close().
  //    New-epoch A SQLite has ONLY [ws1]; disk choice still holds old-epoch pendingMe[A] = [ws-past] and
  //    host storage holds credential/s1/ws-past. Storage recovers and a fresh Core starts offline ->
  //    A's SQLite MUST stay [ws1] (never reverted to [ws-past]), owner("ws-past") is null, and cred deleted!
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws-past", name: "Past" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    await run(seed.inner.data.written);
    await seed.close();

    const pastCred = "credential/s1/ws-past";
    host.store(pastCred, { token: "old-epoch-secret", expires_at: Math.floor(host.nowMs() / 1000) + 3600 });
    host.store("device/choice", {
      pendingMe: { s1: { user: { sub: "s1" }, workspaces: [{ id: "ws-past", name: "Past" }] } },
      workspaceOwners: { "ws-past": "s1", ws2: "s2" },
    });

    let failChoice = true;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) =>
      key === "device/choice" && failChoice ? Effect.fail(new HostError("choice unavailable")) : origGet(key);
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me") && auth === "Bearer access-s1-epoch1") {
        return Effect.succeed(jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }], invitations: [], relay_url: "https://relay.test" }));
      }
      return origFetch(req);
    };

    const core1 = await Core.create(host, { clock: host.time.clock });
    await run(core1.inner.data.openAccounts(["s1", "s2"]));
    await run(core1.inner.accounts.signOut("s1"));
    await run(
      core1.inner.accounts.migrate([
        {
          sub: "s1",
          email: "s1@test",
          name: "S1",
          access: "access-s1-epoch1",
          refresh: "refresh-s1-epoch1",
          accessExpires: Math.floor(host.nowMs() / 1000) + 3600,
        },
      ]),
    );
    await run(core1.inner.data.openAccount("s1"));
    await run(core1.inner.cloudSync.refreshAccount("s1"));
    await run(core1.inner.data.written);
    assert.deepEqual(
      ((core1.inner.data.db("s1")!.accountDoc("me") as J)?.workspaces ?? []).map((w: J) => w.id),
      ["ws1"],
      "new-epoch SQLite holds only [ws1]",
    );
    assert.ok(core1.inner.accounts.sessionId("s1").length > 0, "re-logged-in account received a unique persistent session ID");
    await assert.rejects(() => core1.close(), /device\/choice/);

    // Recover storage and start fresh Core OFFLINE!
    failChoice = false;
    host.fetch = (req) =>
      req.url.endsWith("/v1/me") ? Effect.succeed(jsonResponse(503, { error: "offline" })) : origFetch(req);
    const core2 = await Core.create(host, { clock: host.time.clock });
    await run(core2.inner.data.openAccounts(["s1", "s2"]));
    await host.settle();
    assert.deepEqual(
      ((core2.inner.data.db("s1")!.accountDoc("me") as J)?.workspaces ?? []).map((w: J) => w.id),
      ["ws1"],
      "fresh offline Core MUST NOT revert new-epoch SQLite back to old-epoch [ws-past]",
    );
    assert.equal(core2.inner.workspaces.owner("ws-past"), null, "ws-past is no longer owned by A");
    assert.equal(host.stored(pastCred), undefined, "old-epoch credential/s1/ws-past MUST be deleted");
    await core2.close();
  }
});

test("R19 regressions: unloaded accounts sign-in merge, determinate owner binding, stale refresh guard, comma unloaded account, normal relogin cred retention, and 3-core cross-process relogin", async () => {
  // 1) P0-1: Disk holds [s1, s2]; initial accounts storageGet fails -> passwordSignIn(s3) reloads & merges [s1, s2, s3],
  //    clears isUnloaded(), and allows s3 edits! (And while accounts storage stays unreadable, sign-in fails cleanly without wiping disk.)
  {
    const { host } = setupTwoAccountHost();
    let failAccounts = true;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) =>
      key === STORAGE_KEY && failAccounts ? Effect.fail(new HostError("accounts unavailable")) : origGet(key);
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      if (req.url.endsWith("/v1/auth/password")) {
        return Effect.succeed(
          jsonResponse(200, {
            access_token: "access-s3",
            refresh_token: "refresh-s3",
            subject: "s3",
            email: "s3@test",
            name: "S3",
            expires_at: Math.floor(host.nowMs() / 1000) + 3600,
          }),
        );
      }
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me") && auth === "Bearer access-s3") {
        return Effect.succeed(
          jsonResponse(200, {
            user: { sub: "s3" },
            workspaces: [{ id: "ws3", name: "WS 3" }],
            invitations: [],
            relay_url: "https://relay.test",
          }),
        );
      }
      return origFetch(req);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    assert.equal(core.inner.accounts.isUnloaded(), true);
    // While still unreadable, passwordSignIn MUST fail without clobbering disk [s1, s2].
    await assert.rejects(() => run(core.inner.accounts.passwordSignIn("s3@test", "pw", "dev")));
    const diskBefore = JSON.parse(new TextDecoder().decode(host.stored(STORAGE_KEY)!)) as StoredAccount[];
    assert.deepEqual(diskBefore.map((a) => a.sub), ["s1", "s2"], "failed reload MUST preserve disk [s1, s2]");

    // Recover storage -> passwordSignIn(s3) reloads [s1, s2], merges s3 -> [s1, s2, s3], clears unloaded, s3 edit works!
    failAccounts = false;
    await run(core.inner.accounts.passwordSignIn("s3@test", "pw", "dev"));
    await host.settle();
    assert.equal(core.inner.accounts.isUnloaded(), false, "isUnloaded cleared after merge");
    const diskAfter = JSON.parse(new TextDecoder().decode(host.stored(STORAGE_KEY)!)) as StoredAccount[];
    assert.deepEqual(diskAfter.map((a) => a.sub), ["s1", "s2", "s3"], "disk holds merged [s1, s2, s3]");
    await run(core.inner.data.openAccounts(["s1", "s2", "s3"]));
    await run(core.inner.cloudSync.refreshAccount("s3"));

    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 1701 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 1701, call: "composer.text", params: { key: "new:ws3", text: "s3-draft-ok" } });
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.ok("ok" in res, `s3 edit must succeed after accounts recovery, got: ${JSON.stringify(res)}`);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s3")!.draft("ws3", "new")?.text, "s3-draft-ok");
    await core.close();
  }

  // 2) P0-2: Both s1 and s2 DBs open at startup; ONLY s2 holds ws-w (and disk workspaceOwners[ws-w] = s2).
  //    composer.text("new:ws-w") pauses during choice reload; earlier s1 receives 200 listing ws-w while s2 keeps ws-w
  //    (nobody signs out). Resume -> MUST cancel rather than silently jumping to s1!
  {
    const { host } = setupTwoAccountHost();
    const origFetch = host.fetch.bind(host);
    let s1GainsW = false;
    host.fetch = (req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me") && auth === "Bearer access-s1") {
        return Effect.succeed(
          jsonResponse(200, {
            user: { sub: "s1" },
            workspaces: s1GainsW ? [{ id: "ws1", name: "WS 1" }, { id: "ws-w", name: "Shared W" }] : [{ id: "ws1", name: "WS 1" }],
            invitations: [],
            relay_url: "https://relay.test",
          }),
        );
      }
      if (req.url.endsWith("/v1/me") && auth === "Bearer access-s2") {
        return Effect.succeed(
          jsonResponse(200, {
            user: { sub: "s2" },
            workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }],
            invitations: [],
            relay_url: "https://relay.test",
          }),
        );
      }
      return origFetch(req);
    };

    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-w", name: "Shared W" }] });
    await run(seed.inner.data.written);
    seed.inner.data.device.put("choice", "workspaceOwners", { ws1: "s1", ws2: "s2", "ws-w": "s2" });
    await seed.close();

    let choiceGets = 0;
    const reloadStarted = Deferred.makeUnsafe<void>();
    const reloadGate = Deferred.makeUnsafe<void>();
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) => {
      if (key === "device/choice") {
        choiceGets++;
        if (choiceGets === 1) return Effect.fail(new HostError("initial choice fail"));
        if (choiceGets === 2) {
          Deferred.doneUnsafe(reloadStarted, Effect.void);
          return Effect.andThen(Deferred.await(reloadGate), origGet(key));
        }
      }
      return origGet(key);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    const ui = core.connect();
    const ack = Deferred.makeUnsafe<J>();
    const origEmit = core.inner.host.emit.bind(core.inner.host);
    core.inner.host.emit = (c, m) => {
      origEmit(c, m);
      if (m.id === 1702 && ("ok" in m || "error" in m)) Deferred.doneUnsafe(ack, Effect.succeed(m));
    };
    core.receive(ui, { kind: "call", id: 1702, call: "composer.text", params: { key: "new:ws-w", text: "must-not-jump-to-earlier-a" } });
    await Effect.runPromise(Deferred.await(reloadStarted));
    s1GainsW = true;
    await run(core.inner.cloudSync.refreshAccount("s1"));
    Deferred.doneUnsafe(reloadGate, Effect.void);
    const res = await Effect.runPromise(Deferred.await(ack));
    assert.equal(res.error?.code, "cancelled", `determinate B edit MUST cancel when earlier A newly gains ws-w, got: ${JSON.stringify(res)}`);
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal(core.inner.data.db("s1")!.draft("ws-w", "new"), undefined, "A SQLite stayed empty");
    await core.close();
  }

  // 3) P0-3: Pause session-1 refresh; sign out & passwordSignIn into session-2; release old refresh with 200 or 401 ->
  //    MUST neither revert token/session to session-1 nor wipe session-2!
  for (const status of [200, 401] as const) {
    const { host } = setupTwoAccountHost();
    const expired = host.nowMs() / 1000 - 10;
    host.store(STORAGE_KEY, [{ ...storedAccount("s1", expired), session: "SES_OLD" }]);

    const refreshStarted = Deferred.makeUnsafe<void>();
    const refreshGate = Deferred.makeUnsafe<void>();
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      if (req.url.endsWith("/v1/auth/refresh")) {
        Deferred.doneUnsafe(refreshStarted, Effect.void);
        return Effect.andThen(
          Deferred.await(refreshGate),
          Effect.succeed(
            status === 200
              ? jsonResponse(200, {
                  access_token: "stale-rotated-access",
                  refresh_token: "stale-rotated-refresh",
                  subject: "s1",
                  email: "s1@example.com",
                  name: "Old",
                  expires_at: Math.floor(host.nowMs() / 1000) + 3600,
                })
              : jsonResponse(401, { error: "expired" }),
          ),
        );
      }
      if (req.url.endsWith("/v1/auth/password")) {
        return Effect.succeed(
          jsonResponse(200, {
            access_token: "fresh-s2-access",
            refresh_token: "fresh-s2-refresh",
            subject: "s1",
            email: "s1@example.com",
            name: "New",
            expires_at: Math.floor(host.nowMs() / 1000) + 3600,
          }),
        );
      }
      return origFetch(req);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    const oldRefreshPromise = run(Effect.result(core.inner.accounts.accessToken("s1")));
    await Effect.runPromise(Deferred.await(refreshStarted));

    await run(core.inner.accounts.signOut("s1"));
    await run(core.inner.accounts.passwordSignIn("s1@example.com", "pw", "dev"));
    const newSession = core.inner.accounts.sessionId("s1");
    assert.ok(newSession.length > 0 && newSession !== "SES_OLD");

    Deferred.doneUnsafe(refreshGate, Effect.void);
    await oldRefreshPromise;
    await host.settle();

    const disk = JSON.parse(new TextDecoder().decode(host.stored(STORAGE_KEY)!)) as StoredAccount[];
    assert.equal(disk.length, 1, `status ${status}: session-2 account MUST remain signed in`);
    assert.equal(disk[0]!.session, newSession, `status ${status}: session-2 ID preserved`);
    assert.equal(disk[0]!.refresh, "fresh-s2-refresh", `status ${status}: session-2 refresh token preserved`);
    await core.close();
  }

  // 4) P0-4: Comma account initial storageGet fails + server /v1/comma/stations/me returns 503 ->
  //    MUST preserve comma/account, A's credential, and pendingMe[A] across start + close!
  {
    const host = new FakeHost();
    const commaOrigin = "https://comma.test";
    const credKey = "credential/u-comma/ws-c";
    host.store(COMMA_ACCOUNT_KEY, { sub: "u-comma", email: "c@test", name: "C", picture: "" });
    host.store(credKey, { token: "comma-cred", expires_at: Math.floor(host.nowMs() / 1000) + 3600 });
    host.store("device/choice", {
      "credWorkspaces/u-comma": ["ws-c"],
      pendingMe: { "u-comma": { user: { sub: "u-comma" }, workspaces: [{ id: "ws-c", name: "WS C" }] } },
    });
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) =>
      key === COMMA_ACCOUNT_KEY ? Effect.fail(new HostError("comma account read fail")) : origGet(key);
    host.onFetch((req) => {
      if (req.url.startsWith(`${commaOrigin}/v1/comma/stations/me`)) return jsonResponse(503, { error: "unavailable" });
      return jsonResponse(200, {});
    });

    const core = await Core.create(host, {
      clock: host.time.clock,
      account: commaAccountProvider({ origin: commaOrigin, bearer: () => Promise.resolve("tok") }),
    });
    await host.settle();
    assert.equal(core.inner.accounts.isUnloaded(), true, "CommaAccounts reports unloaded on read fail + 503");
    await core.close();
    assert.ok(host.stored(COMMA_ACCOUNT_KEY) !== undefined, "comma/account preserved");
    assert.ok(host.stored(credKey) !== undefined, "Comma credential MUST NOT be deleted as orphan");
    const choiceAfter = JSON.parse(new TextDecoder().decode(host.stored("device/choice")!)) as J;
    assert.ok(choiceAfter?.pendingMe?.["u-comma"] !== undefined, "Comma pendingMe MUST NOT be pruned");
  }

  // 5) P1-5: Normal storage throughout: A signs out, re-logs in via passwordSignIn, claims a new credential, closes
  //    normally -> next OFFLINE startup MUST retain the newly claimed credential (not delete it as stale session)!
  {
    const { host } = setupTwoAccountHost();
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      if (req.url.endsWith("/v1/auth/password")) {
        return Effect.succeed(
          jsonResponse(200, {
            access_token: "access-s1-new",
            refresh_token: "refresh-s1-new",
            subject: "s1",
            email: "s1@example.com",
            name: "S1",
            expires_at: Math.floor(host.nowMs() / 1000) + 3600,
          }),
        );
      }
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me") && auth === "Bearer access-s1-new") {
        return Effect.succeed(
          jsonResponse(200, {
            user: { sub: "s1" },
            workspaces: [{ id: "ws1", name: "WS 1" }],
            invitations: [],
            relay_url: "https://relay.test",
          }),
        );
      }
      if (req.url.endsWith("/v1/workspaces/ws1/credential")) {
        return Effect.succeed(
          jsonResponse(200, {
            credential: "fresh-relogin-cred",
            issued_at: Math.floor(host.nowMs() / 1000),
            expires_at: Math.floor(host.nowMs() / 1000) + 3600,
            relay_url: "https://relay.test",
          }),
        );
      }
      return origFetch(req);
    };

    const core1 = await Core.create(host, { clock: host.time.clock });
    await run(core1.inner.data.openAccounts(["s1", "s2"]));
    await run(core1.inner.accounts.signOut("s1"));
    await run(core1.inner.accounts.passwordSignIn("s1@example.com", "pw", "dev"));
    await host.settle();
    await run(core1.inner.data.openAccount("s1"));
    await run(core1.inner.cloudSync.refreshAccount("s1"));
    const cred1 = await run(core1.inner.cloudSync.credential("ws1", "dev-1", false, null));
    assert.equal(cred1.credential, "fresh-relogin-cred");
    await core1.close();

    assert.ok(host.stored("credential/s1/ws1") !== undefined, "new credential saved on close");
    // Next OFFLINE start MUST retain the newly claimed credential!
    host.fetch = (req) =>
      req.url.endsWith("/v1/me") || req.url.endsWith("/credential")
        ? Effect.succeed(jsonResponse(503, { error: "offline" }))
        : origFetch(req);
    const core2 = await Core.create(host, { clock: host.time.clock });
    await host.settle();
    assert.ok(host.stored("credential/s1/ws1") !== undefined, "fresh relogin credential MUST NOT be deleted on next offline start");
    const cred2 = await run(core2.inner.cloudSync.credential("ws1", "dev-1", false, null));
    assert.equal(cred2.credential, "fresh-relogin-cred", "offline credential read succeeds");
    await core2.close();
  }

  // 6) P1-6: Core 1 (choice unreadable) signs out A -> close rejects; Core 2 (choice still unreadable) re-logs in A
  //    (gets unique persistent ULID session), writes [ws1] to SQLite -> close rejects; Core 3 (storage recovers,
  //    OFFLINE) -> A's SQLite MUST keep [ws1] (never revert to old [ws-past]) and delete credential/s1/ws-past!
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws-past", name: "Past" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    await run(seed.inner.data.written);
    await seed.close();

    const pastCred = "credential/s1/ws-past";
    host.store(pastCred, { token: "old-3core-secret", expires_at: Math.floor(host.nowMs() / 1000) + 3600 });
    host.store("device/choice", {
      pendingMe: { s1: { user: { sub: "s1" }, workspaces: [{ id: "ws-past", name: "Past" }] } },
      workspaceOwners: { "ws-past": "s1", ws2: "s2" },
    });

    let failChoice = true;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key: string) =>
      key === "device/choice" && failChoice ? Effect.fail(new HostError("choice unavailable")) : origGet(key);
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      if (req.url.endsWith("/v1/auth/password")) {
        return Effect.succeed(
          jsonResponse(200, {
            access_token: "access-s1-core2",
            refresh_token: "refresh-s1-core2",
            subject: "s1",
            email: "s1@example.com",
            name: "S1",
            expires_at: Math.floor(host.nowMs() / 1000) + 3600,
          }),
        );
      }
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me") && auth === "Bearer access-s1-core2") {
        return Effect.succeed(
          jsonResponse(200, {
            user: { sub: "s1" },
            workspaces: [{ id: "ws1", name: "WS 1" }],
            invitations: [],
            relay_url: "https://relay.test",
          }),
        );
      }
      return origFetch(req);
    };

    // Core 1: sign out A while choice is unreadable -> close rejects.
    const core1 = await Core.create(host, { clock: host.time.clock });
    await run(core1.inner.data.openAccounts(["s1", "s2"]));
    await run(core1.inner.accounts.signOut("s1"));
    await assert.rejects(() => core1.close(), /device\/choice/);

    // Core 2: choice STILL unreadable -> re-login A in a brand-new Core instance -> persist [ws1] -> close rejects.
    const core2 = await Core.create(host, { clock: host.time.clock });
    await run(core2.inner.accounts.passwordSignIn("s1@example.com", "pw", "dev"));
    await host.settle();
    await run(core2.inner.data.openAccount("s1"));
    await run(core2.inner.cloudSync.refreshAccount("s1"));
    await run(core2.inner.data.written);
    assert.ok(core2.inner.accounts.sessionId("s1").length > 0, "Core 2 assigned unique session ID");
    assert.deepEqual(
      ((core2.inner.data.db("s1")!.accountDoc("me") as J)?.workspaces ?? []).map((w: J) => w.id),
      ["ws1"],
    );
    await assert.rejects(() => core2.close(), /device\/choice/);

    // Core 3: storage recovers, OFFLINE -> A's SQLite MUST keep [ws1] and delete old credential/s1/ws-past!
    failChoice = false;
    host.fetch = (req) =>
      req.url.endsWith("/v1/me") ? Effect.succeed(jsonResponse(503, { error: "offline" })) : origFetch(req);
    const core3 = await Core.create(host, { clock: host.time.clock });
    await run(core3.inner.data.openAccounts(["s1", "s2"]));
    await host.settle();
    assert.deepEqual(
      ((core3.inner.data.db("s1")!.accountDoc("me") as J)?.workspaces ?? []).map((w: J) => w.id),
      ["ws1"],
      "Core 3 MUST NOT revert Core 2 SQLite back to Core 1 [ws-past]",
    );
    assert.equal(core3.inner.workspaces.owner("ws-past"), null);
    assert.equal(host.stored(pastCred), undefined, "Core 3 MUST delete old-session credential/s1/ws-past");
    await core3.close();
  }
});

test("R20 regressions: pendingMe-excluded owner binding, session-bound refresh (same & cross instance), logout race, unloaded signOut cleanup, in-place relogin cred guard, and Comma 3-core relogin", async () => {
  // 1) P0-1: A's DB is busy & choice is unloaded, disk pendingMe[A]=[aw] explicitly excludes W while pendingMe[B]=[bw,w]
  //    and cached owner[w]=B. Pausing composer.text("new:w") reload, letting A receive a 200 listing W -> MUST cancel!
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "aw", name: "AW" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "bw", name: "BW" }, { id: "ws1", name: "W" }] });
    seed.inner.data.device.put("choice", "pendingMe", {
      s1: { user: { sub: "s1" }, workspaces: [{ id: "aw", name: "AW" }] },
      s2: { user: { sub: "s2" }, workspaces: [{ id: "bw", name: "BW" }, { id: "ws1", name: "W" }] },
    });
    seed.inner.data.device.put("choice", "workspaceOwners", { aw: "s1", bw: "s2", ws1: "s2" });
    await seed.close();

    let failChoice = true;
    let pauseChoice = false;
    let choiceGateResolve: (() => void) | null = null;
    const choiceGate = new Promise<void>((r) => { choiceGateResolve = r; });
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key) => {
      if (key === "device/choice") {
        if (failChoice) return Effect.fail(new HostError("choice io fail"));
        if (pauseChoice) {
          pauseChoice = false;
          return Effect.flatMap(Effect.promise(() => choiceGate), () => origGet(key));
        }
      }
      return origGet(key);
    };
    let s1Busy = true;
    const origOpen = host.openDb.bind(host);
    host.openDb = (name) =>
      name === dbName("s1") && s1Busy
        ? Effect.succeed({
            exec() { throw new SqlError("SQLITE_BUSY: database is locked", "busy"); },
            run() { throw new SqlError("SQLITE_BUSY: database is locked", "busy"); },
            all() { throw new SqlError("SQLITE_BUSY: database is locked", "busy"); },
            close() {},
          })
        : origOpen(name);
    let s1ListsW = false;
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1" && s1ListsW) {
          return Effect.succeed(jsonResponse(200, {
            user: { sub: "s1" },
            workspaces: [{ id: "aw", name: "AW" }, { id: "ws1", name: "W" }],
            invitations: [],
            relay_url: "https://relay.test",
          }));
        }
        return Effect.succeed(jsonResponse(503, { error: "offline" }));
      }
      return origFetch(req);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    assert.equal(core.inner.data.device.isUnloaded("choice"), true);
    assert.equal(core.inner.data.notes.get("s1")?.kind, "busy");

    // Pause choice reload during composer.text("new:ws1").
    failChoice = false;
    pauseChoice = true;
    const ui = core.connect();
    call(core, ui, 1, "composer.text", { key: "new:ws1", text: "draft-must-cancel" });
    await host.settle();

    // Recover s1 DB & deliver a brand-new 200 /v1/me adding ws1 to s1 while reload is paused.
    s1Busy = false;
    s1ListsW = true;
    await run(core.inner.data.openAccount("s1"));
    await run(core.inner.cloudSync.refreshAccount("s1"));
    choiceGateResolve!();
    await host.settle();
    const emitted = host.takeEmitted() as [number, unknown][];
    const ans = answers(emitted as never, 1);
    assert.equal((ans?.error as { code?: string } | undefined)?.code, "cancelled", "MUST cancel when A was excluded by same-session pendingMe and only gained W mid-wait");
    assert.equal(core.inner.data.db("s1")!.draft("ws1", "new"), undefined, "draft MUST NOT land in A");
    assert.equal(core.inner.data.db("s2")!.draft("ws1", "new"), undefined, "draft MUST NOT land in B");
    await core.close();
  }

  // 2a) P0-2a (same instance): pause old accessToken(A) at storageGet("accounts"), sign out & re-login A,
  //     then release -> old refresh MUST fail signed_out and NEVER use new login's refresh token!
  {
    const host = new FakeHost();
    const expiredAt = Math.floor(host.nowMs() / 1000) - 10;
    host.store("accounts", [{
      sub: "s1",
      email: "s1@example.com",
      name: "S1",
      picture: "",
      access: "old-access",
      refresh: "old-refresh",
      access_expires: expiredAt,
      session: "01OLD000000000000000000000",
    }]);
    let pauseFirstGet = false;
    let getGateResolve: (() => void) | null = null;
    const getGate = new Promise<void>((r) => { getGateResolve = r; });
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key) => {
      if (key === "accounts" && pauseFirstGet) {
        pauseFirstGet = false;
        return Effect.flatMap(Effect.promise(() => getGate), () => origGet(key));
      }
      return origGet(key);
    };
    const refreshAuths: string[] = [];
    host.onFetch((req) => {
      if (req.url.endsWith("/v1/auth/logout")) return jsonResponse(200, {});
      if (req.url.endsWith("/v1/auth/password")) {
        return jsonResponse(200, {
          access_token: "new-access",
          refresh_token: "new-refresh",
          subject: "s1",
          email: "s1@example.com",
          name: "S1",
          expires_at: Math.floor(host.nowMs() / 1000) + 3600,
        });
      }
      if (req.url.endsWith("/v1/me")) return jsonResponse(200, { user: {} });
      if (req.url.endsWith("/v1/auth/refresh")) {
        refreshAuths.push(req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "");
        return jsonResponse(200, {
          access_token: "should-not-happen",
          refresh_token: "should-not-happen-r",
          subject: "s1",
          email: "s1@example.com",
          expires_at: Math.floor(host.nowMs() / 1000) + 3600,
        });
      }
      return jsonResponse(404, {});
    });

    const accounts = await run(Accounts.load(host));
    pauseFirstGet = true;
    const oldTokenP = run(Effect.result(accounts.accessToken("s1")));
    await host.settle();
    await run(accounts.signOut("s1"));
    await run(accounts.passwordSignIn("s1@example.com", "pw", "dev"));
    const newSession = accounts.sessionId("s1");
    getGateResolve!();
    const res = await oldTokenP;
    assert.equal(res._tag, "Failure", "old accessToken MUST fail after sign-out + re-login");
    assert.equal(res.failure.code, "signed_out");
    assert.deepEqual(refreshAuths, [], "old refresh MUST NOT send /v1/auth/refresh with new session's refresh token");
    assert.equal(accounts.sessionId("s1"), newSession);
  }

  // 2b) P0-2b (cross instance shared host): Instance 1's old refresh is in flight; Instance 2 signs out & re-logs in.
  //     Both 200 and 401 on Instance 1 MUST preserve Instance 2's persisted login on shared host storage!
  for (const status of [200, 401] as const) {
    const host = new FakeHost();
    const expiredAt = Math.floor(host.nowMs() / 1000) - 10;
    host.store("accounts", [{
      sub: "s1",
      email: "s1@example.com",
      name: "S1",
      picture: "",
      access: "old-access",
      refresh: "old-refresh",
      access_expires: expiredAt,
      session: "01OLD000000000000000000000",
    }]);
    let releaseRefresh: (() => void) | null = null;
    const refreshGate = new Promise<void>((r) => { releaseRefresh = r; });
    host.fetch = (req) => {
      if (req.url.endsWith("/v1/auth/logout")) return Effect.succeed(jsonResponse(200, {}));
      if (req.url.endsWith("/v1/auth/password")) {
        return Effect.succeed(jsonResponse(200, {
          access_token: "inst2-access",
          refresh_token: "inst2-refresh",
          subject: "s1",
          email: "s1@example.com",
          name: "S1",
          expires_at: Math.floor(host.nowMs() / 1000) + 3600,
        }));
      }
      if (req.url.endsWith("/v1/me")) return Effect.succeed(jsonResponse(200, { user: {} }));
      if (req.url.endsWith("/v1/auth/refresh")) {
        return Effect.map(Effect.promise(() => refreshGate), () =>
          status === 200
            ? jsonResponse(200, {
                access_token: "stale-refreshed-access",
                refresh_token: "stale-refreshed-refresh",
                subject: "s1",
                email: "s1@example.com",
                expires_at: Math.floor(host.nowMs() / 1000) + 3600,
              })
            : jsonResponse(401, { error: "invalid_session" }),
        );
      }
      return Effect.succeed(jsonResponse(404, {}));
    };

    const inst1 = await run(Accounts.load(host));
    const inst2 = await run(Accounts.load(host));
    const inst1Refresh = run(Effect.result(inst1.accessToken("s1")));
    await host.settle();

    // Instance 2 signs out & re-logs in A on shared storage.
    await run(inst2.signOut("s1"));
    await run(inst2.passwordSignIn("s1@example.com", "pw", "dev"));
    const inst2Session = inst2.sessionId("s1");
    assert.ok(inst2Session.length > 0 && inst2Session !== "01OLD000000000000000000000");

    // Release Instance 1's stale refresh response (200 or 401).
    releaseRefresh!();
    const res = await inst1Refresh;
    assert.equal(res._tag, "Failure", `cross-instance stale refresh (${status}) MUST fail signed_out`);
    assert.equal(res.failure.code, "signed_out");
    const disk = parseJson(host.stored("accounts")) as Array<{ sub: string; session?: string; refresh: string }>;
    assert.equal(disk.length, 1, `shared storage MUST keep Instance 2 login after stale refresh ${status}`);
    assert.equal(disk[0]!.session, inst2Session);
    assert.equal(disk[0]!.refresh, "inst2-refresh");
  }

  // 3) P0-3: Pause A's /v1/auth/logout, re-login A in same instance, then release logout -> MUST keep new login!
  {
    const host = new FakeHost();
    host.store("accounts", [{
      sub: "s1",
      email: "s1@example.com",
      name: "S1",
      picture: "",
      access: "old-access",
      refresh: "old-refresh",
      access_expires: Math.floor(host.nowMs() / 1000) + 3600,
      session: "01OLD000000000000000000000",
    }]);
    let releaseLogout: (() => void) | null = null;
    const logoutGate = new Promise<void>((r) => { releaseLogout = r; });
    host.fetch = (req) => {
      if (req.url.endsWith("/v1/auth/logout")) {
        return Effect.map(Effect.promise(() => logoutGate), () => jsonResponse(200, {}));
      }
      if (req.url.endsWith("/v1/auth/password")) {
        return Effect.succeed(jsonResponse(200, {
          access_token: "new-access",
          refresh_token: "new-refresh",
          subject: "s1",
          email: "s1@example.com",
          name: "S1",
          expires_at: Math.floor(host.nowMs() / 1000) + 3600,
        }));
      }
      if (req.url.endsWith("/v1/me")) return Effect.succeed(jsonResponse(200, { user: {} }));
      return Effect.succeed(jsonResponse(404, {}));
    };

    const accounts = await run(Accounts.load(host));
    const signOutP = run(accounts.signOut("s1"));
    await host.settle();
    await run(accounts.passwordSignIn("s1@example.com", "pw", "dev"));
    const newSession = accounts.sessionId("s1");
    assert.notEqual(newSession, "01OLD000000000000000000000");

    releaseLogout!();
    await signOutP;
    assert.equal(accounts.list().length, 1, "stale logout MUST NOT delete newly logged-in session");
    assert.equal(accounts.sessionId("s1"), newSession);
    const disk = parseJson(host.stored("accounts")) as Array<{ sub: string; session?: string }>;
    assert.equal(disk.length, 1);
    assert.equal(disk[0]!.session, newSession);
  }

  // 4) P1-4: Startup accounts storageGet fails -> storage recovers -> signOut(A) MUST POST /logout AND deleteDb(A)!
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.db("s1")!.putDraft("ws1", "new", { text: "secret-draft", files: [] });
    await seed.close();

    let failAccountsOnce = true;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key) => {
      if (key === "accounts" && failAccountsOnce) {
        failAccountsOnce = false;
        return Effect.fail(new HostError("accounts io fail"));
      }
      return origGet(key);
    };
    let logoutCalls = 0;
    let deleteDbCalls = 0;
    const origDeleteDb = host.deleteDb!.bind(host);
    host.deleteDb = (name) => {
      if (name === dbName("s1")) deleteDbCalls++;
      return origDeleteDb(name);
    };
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      if (req.url.endsWith("/v1/auth/logout")) {
        logoutCalls++;
        return Effect.succeed(jsonResponse(200, {}));
      }
      if (req.url.endsWith("/v1/auth/password")) {
        return Effect.succeed(jsonResponse(200, {
          access_token: "s1-new-access",
          refresh_token: "s1-new-refresh",
          subject: "s1",
          email: "s1@example.com",
          name: "S1",
          expires_at: Math.floor(host.nowMs() / 1000) + 3600,
        }));
      }
      return origFetch(req);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    assert.equal(core.inner.accounts.isUnloaded(), true);
    await run(core.inner.accounts.signOut("s1"));
    await host.settle();
    assert.equal(logoutCalls, 1, "signOut after unloaded accounts MUST POST /v1/auth/logout");
    assert.equal(deleteDbCalls, 1, "signOut after unloaded accounts MUST delete A's local DB");
    await run(core.inner.accounts.passwordSignIn("s1@example.com", "pw", "dev"));
    await host.settle();
    await run(core.inner.data.openAccount("s1"));
    assert.equal(core.inner.data.db("s1")!.draft("ws1", "new"), undefined, "re-login after signOut MUST NOT read old draft");
    await core.close();
  }

  // 5) P1-5: In-place re-login of same sub while credential ask is paused -> old ask MUST fail and NOT persist!
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }] });
    await seed.close();

    let releaseOldCred: (() => void) | null = null;
    const credGate = new Promise<void>((r) => { releaseOldCred = r; });
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      if (req.url.endsWith("/v1/auth/password")) {
        return Effect.succeed(jsonResponse(200, {
          access_token: "s1-inplace-access",
          refresh_token: "s1-inplace-refresh",
          subject: "s1",
          email: "s1@example.com",
          name: "S1",
          expires_at: Math.floor(host.nowMs() / 1000) + 3600,
        }));
      }
      if (req.url.endsWith("/v1/workspaces/ws1/credential")) {
        return Effect.map(Effect.promise(() => credGate), () =>
          jsonResponse(200, {
            credential: "stale-session-cred",
            issued_at: Math.floor(host.nowMs() / 1000),
            expires_at: Math.floor(host.nowMs() / 1000) + 3600,
            relay_url: "https://relay.test",
          }),
        );
      }
      if (req.url.endsWith("/v1/me")) {
        return Effect.succeed(jsonResponse(200, {
          user: { sub: "s1" },
          workspaces: [{ id: "ws1", name: "WS 1" }],
          invitations: [],
          relay_url: "https://relay.test",
        }));
      }
      return origFetch(req);
    };

    const core1 = await Core.create(host, { clock: host.time.clock });
    await run(core1.inner.data.openAccounts(["s1", "s2"]));
    const oldCredP = run(Effect.result(core1.inner.cloudSync.credential("ws1", "dev-1", false, null)));
    await host.settle();

    // Direct in-place re-login of s1 (NO signOut!).
    await run(core1.inner.accounts.passwordSignIn("s1@example.com", "pw", "dev"));
    await host.settle();
    const newSid = core1.inner.accounts.sessionId("s1");
    assert.ok(newSid.length > 0);

    // Release old credential ask.
    releaseOldCred!();
    const res = await oldCredP;
    assert.equal(res._tag, "Failure", "stale credential ask after in-place re-login MUST fail");
    assert.equal(res.failure.code, "signed_out");
    assert.equal(host.stored("credential/s1/ws1"), undefined, "stale credential MUST NOT be persisted under new session");
    await core1.close();

    // Offline restart MUST NOT hit any stale credential!
    host.fetch = (req) =>
      req.url.endsWith("/v1/me") || req.url.endsWith("/credential")
        ? Effect.succeed(jsonResponse(503, { error: "offline" }))
        : origFetch(req);
    const core2 = await Core.create(host, { clock: host.time.clock });
    await host.settle();
    assert.equal(host.stored("credential/s1/ws1"), undefined);
    await core2.close();
  }

  // 6) P1-6: Comma cross-Core re-login while device/choice is continuously unreadable -> Core 3 offline MUST keep
  //    [aw] in SQLite and delete stale credential/A/past!
  {
    const host = new FakeHost();
    const ORIGIN = "https://comma.test";
    const pastCred = "credential/usr_1/past";
    host.store(COMMA_ACCOUNT_KEY, { sub: "usr_1", email: "a@x.com", name: "Ada", picture: "" });
    host.store(pastCred, { device: "dev-1", credential: "past-comma-cred", issued_at: 1, expires_at: 9999999999, relay_url: "https://relay.comma.test" });

    let mode: "seed" | "relogin" | "offline" = "seed";
    let failChoice = false;
    const origGet = host.storageGet.bind(host);
    const origSet = host.storageSet.bind(host);
    host.storageGet = (key) =>
      key === "device/choice" && failChoice ? Effect.fail(new HostError("choice unreadable")) : origGet(key);
    host.storageSet = (key, bytes) =>
      key === "device/choice" && failChoice ? Effect.fail(new HostError("choice unwritable")) : origSet(key, bytes);

    host.onFetch((req) => {
      if (req.url === `${ORIGIN}/v1/comma/stations/me`) {
        if (mode === "offline") return jsonResponse(503, { error: "offline" });
        const workspaces = mode === "relogin"
          ? [{ id: "aw", name: "AW", role: "owner" }]
          : [{ id: "past", name: "Past", role: "owner" }];
        return jsonResponse(200, {
          user: { id: "usr_1", email: "a@x.com", name: "Ada" },
          workspaces,
          relay_urls: ["https://relay.comma.test"],
        });
      }
      return jsonResponse(503, { error: "offline" });
    });
    const makeComma = () => commaAccountProvider({ origin: ORIGIN, bearer: async () => "tok" });

    // Seed device/choice with pendingMe[usr_1]=[past] and credWorkspaces/usr_1=[past].
    const seed = await Core.create(host, { clock: host.time.clock, account: makeComma() });
    seed.inner.data.device.put("choice", "pendingMe", {
      usr_1: { user: { id: "usr_1", email: "a@x.com", name: "Ada", picture: "" }, workspaces: [{ id: "past", name: "Past", role: "owner" }], invitations: [], relay_urls: ["https://relay.comma.test"], relay_url: "https://relay.comma.test" },
    });
    seed.inner.data.device.put("choice", "credWorkspaces/usr_1", ["past"]);
    seed.inner.data.device.put("choice", "workspaceOwners", { past: "usr_1" });
    await seed.close();

    // Core 1: choice unreadable -> signOut usr_1 -> close rejects.
    failChoice = true;
    mode = "offline";
    const core1 = await Core.create(host, { clock: host.time.clock, account: makeComma() });
    await run(core1.inner.accounts.signOut("usr_1"));
    await assert.rejects(() => core1.close(), /device\/choice/);

    // Core 2: choice STILL unreadable -> Comma identifies usr_1 with [aw] -> persists [aw] to SQLite -> close rejects.
    mode = "relogin";
    const core2 = await Core.create(host, { clock: host.time.clock, account: makeComma() });
    for (let i = 0; i < 40 && core2.inner.accounts.list().length === 0; i++) await host.settle();
    await run(core2.inner.data.openAccount("usr_1"));
    await run(core2.inner.cloudSync.refreshAccount("usr_1"));
    await run(core2.inner.data.written);
    assert.ok(core2.inner.accounts.sessionId("usr_1").length > 0, "Comma Core 2 assigned persistent session ULID");
    assert.deepEqual(
      ((core2.inner.data.db("usr_1")!.accountDoc("me") as J)?.workspaces ?? []).map((w: J) => w.id),
      ["aw"],
    );
    await assert.rejects(() => core2.close(), /device\/choice/);

    // Core 3: storage recovers, OFFLINE -> SQLite MUST keep [aw], owner("past") === null, pastCred deleted!
    failChoice = false;
    mode = "offline";
    const core3 = await Core.create(host, { clock: host.time.clock, account: makeComma() });
    await run(core3.inner.data.openAccount("usr_1"));
    await host.settle();
    assert.deepEqual(
      ((core3.inner.data.db("usr_1")!.accountDoc("me") as J)?.workspaces ?? []).map((w: J) => w.id),
      ["aw"],
      "Comma Core 3 MUST NOT revert Core 2 SQLite back to [past]",
    );
    assert.equal(core3.inner.workspaces.owner("past"), null);
    assert.equal(host.stored(pastCred), undefined, "Comma Core 3 MUST delete stale credential/usr_1/past");
    await core3.close();
  }
});

test("R21 regressions: cross-instance serialized accounts merge/CAS, read-error abort, deferred liveMe owner binding, in-place /v1/me session guard, legacy cred verify barrier, Comma session read-error & 401 DB cleanup", async () => {
  // 1a) P0-1a: Cross-instance paused storageSet on old refresh (200 & 401) serialized behind shared host lock;
  //     Instance 2 sign-out + re-login MUST win cleanly without ever being rolled back or wiped.
  for (const status of [200, 401] as const) {
    const host = new FakeHost();
    host.store("accounts", [{
      sub: "s1",
      email: "s1@example.com",
      name: "S1",
      picture: "",
      access: "old-access",
      refresh: "old-refresh",
      access_expires: Math.floor(host.nowMs() / 1000) - 10,
      session: "01OLD000000000000000000000",
    }]);
    let pauseFirstSet = true;
    let firstSetEntered = false;
    let releaseFirstSet: (() => void) | null = null;
    const setGate = new Promise<void>((r) => { releaseFirstSet = r; });
    const origSet = host.storageSet.bind(host);
    host.storageSet = (key, bytes) => {
      if (key === "accounts" && pauseFirstSet) {
        pauseFirstSet = false;
        firstSetEntered = true;
        return Effect.flatMap(Effect.promise(() => setGate), () => origSet(key, bytes));
      }
      return origSet(key, bytes);
    };
    host.onFetch((req) => {
      if (req.url.endsWith("/v1/auth/logout")) return jsonResponse(200, {});
      if (req.url.endsWith("/v1/auth/password")) {
        return jsonResponse(200, {
          access_token: "inst2-access",
          refresh_token: "inst2-refresh",
          subject: "s1",
          email: "s1@example.com",
          name: "S1",
          expires_at: Math.floor(host.nowMs() / 1000) + 3600,
        });
      }
      if (req.url.endsWith("/v1/me")) return jsonResponse(200, { user: {} });
      if (req.url.endsWith("/v1/auth/refresh")) {
        return status === 200
          ? jsonResponse(200, {
              access_token: "stale-200-access",
              refresh_token: "stale-200-refresh",
              subject: "s1",
              email: "s1@example.com",
              expires_at: Math.floor(host.nowMs() / 1000) + 3600,
            })
          : jsonResponse(401, { error: "invalid_session" });
      }
      return jsonResponse(404, {});
    });

    const inst1 = await run(Accounts.load(host));
    const inst2 = await run(Accounts.load(host));
    const p1 = run(Effect.result(inst1.accessToken("s1")));
    for (let i = 0; i < 20 && !firstSetEntered; i++) await host.settle();
    assert.equal(firstSetEntered, true, "inst1 entered storageSet");

    // Start inst2 sign-out + re-login concurrently while inst1 holds the shared host lock.
    const p2 = (async () => {
      await run(inst2.signOut("s1"));
      await run(inst2.passwordSignIn("s1@example.com", "pw", "dev"));
      return inst2.sessionId("s1");
    })();
    await host.settle();
    releaseFirstSet!();
    const [, inst2Sid] = await Promise.all([p1, p2]);
    const disk = parseJson(host.stored("accounts")) as Array<{ sub: string; session?: string; refresh: string }>;
    assert.equal(disk.length, 1, `shared disk MUST keep inst2 login (${status})`);
    assert.equal(disk[0]!.session, inst2Sid);
    assert.equal(disk[0]!.refresh, "inst2-refresh");
  }

  // 1b) P0-1b: Two instances starting from [A] sign in B and C sequentially -> shared disk MUST preserve [A, B, C]!
  {
    const host = new FakeHost();
    host.store("accounts", [{
      sub: "a", email: "a@example.com", name: "A", picture: "", access: "aa", refresh: "ra",
      access_expires: Math.floor(host.nowMs() / 1000) + 3600, session: "01A00000000000000000000000",
    }]);
    host.onFetch((req) => {
      if (req.url.endsWith("/v1/auth/password")) {
        const body = parseJson(req.body!) as { email: string };
        const sub = body.email.split("@")[0]!;
        return jsonResponse(200, {
          access_token: `acc-${sub}`, refresh_token: `ref-${sub}`, subject: sub,
          email: body.email, name: sub.toUpperCase(), expires_at: Math.floor(host.nowMs() / 1000) + 3600,
        });
      }
      if (req.url.endsWith("/v1/me")) return jsonResponse(200, { user: {} });
      return jsonResponse(404, {});
    });
    const inst1 = await run(Accounts.load(host));
    const inst2 = await run(Accounts.load(host));
    await run(inst2.passwordSignIn("b@example.com", "pw", "dev"));
    await run(inst1.passwordSignIn("c@example.com", "pw", "dev"));
    const disk = parseJson(host.stored("accounts")) as Array<{ sub: string }>;
    assert.deepEqual(disk.map((x) => x.sub), ["a", "b", "c"], "sequential sign-ins across instances MUST merge by sub");
  }

  // 2) P0-2: Pre-commit storageGet("accounts") fails once after Instance 2 re-logged in -> stale refresh 200 AND
  //    stale explicit logout MUST fail retryably without touching disk!
  for (const op of ["refresh200", "logout"] as const) {
    const host = new FakeHost();
    host.store("accounts", [{
      sub: "s1", email: "s1@example.com", name: "S1", picture: "", access: "old-a", refresh: "old-r",
      access_expires: op === "refresh200" ? Math.floor(host.nowMs() / 1000) - 10 : Math.floor(host.nowMs() / 1000) + 3600,
      session: "01OLD000000000000000000000",
    }]);
    let failNextAccountsGet = false;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key) => {
      if (key === "accounts" && failNextAccountsGet) {
        failNextAccountsGet = false;
        return Effect.fail(new HostError("transient accounts get fail"));
      }
      return origGet(key);
    };
    let releaseNet: (() => void) | null = null;
    const netGate = new Promise<void>((r) => { releaseNet = r; });
    let pausedFirstLogout = false;
    host.fetch = (req) => {
      if (req.url.endsWith("/v1/auth/logout")) {
        if (op === "logout" && !pausedFirstLogout) {
          pausedFirstLogout = true;
          return Effect.map(Effect.promise(() => netGate), () => jsonResponse(200, {}));
        }
        return Effect.succeed(jsonResponse(200, {}));
      }
      if (req.url.endsWith("/v1/auth/refresh")) {
        return Effect.map(Effect.promise(() => netGate), () =>
          jsonResponse(200, {
            access_token: "stale-200", refresh_token: "stale-200-r", subject: "s1",
            email: "s1@example.com", expires_at: Math.floor(host.nowMs() / 1000) + 3600,
          }),
        );
      }
      if (req.url.endsWith("/v1/auth/password")) {
        return Effect.succeed(jsonResponse(200, {
          access_token: "inst2-a", refresh_token: "inst2-r", subject: "s1",
          email: "s1@example.com", name: "S1", expires_at: Math.floor(host.nowMs() / 1000) + 3600,
        }));
      }
      if (req.url.endsWith("/v1/me")) return Effect.succeed(jsonResponse(200, { user: {} }));
      return Effect.succeed(jsonResponse(404, {}));
    };

    const inst1 = await run(Accounts.load(host));
    const inst2 = await run(Accounts.load(host));
    const p1 = op === "refresh200"
      ? run(Effect.result(inst1.accessToken("s1")))
      : run(Effect.result(inst1.signOut("s1")));
    await host.settle();
    await run(inst2.signOut("s1"));
    await run(inst2.passwordSignIn("s1@example.com", "pw", "dev"));
    const inst2Sid = inst2.sessionId("s1");

    // Fail the single pre-commit storageGet("accounts") right before releasing inst1's network response!
    failNextAccountsGet = true;
    releaseNet!();
    const res = await p1;
    assert.equal(res._tag, "Failure", `${op} MUST abort with retryable error on pre-commit storageGet failure`);
    const disk = parseJson(host.stored("accounts")) as Array<{ sub: string; session?: string; refresh: string }>;
    assert.equal(disk.length, 1, `disk MUST remain untouched after ${op} read failure`);
    assert.equal(disk[0]!.session, inst2Sid);
    assert.equal(disk[0]!.refresh, "inst2-r");
  }

  // 3) P0-3: choice loaded, A deferred, B holds W; A already got 200 /v1/me excluding W -> composer.text("new:ws1")
  //    pauses A openDb -> A gets second 200 adding W -> MUST cancel (neither A nor B gets draft)!
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "aw", name: "AW" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws1", name: "W" }] });
    seed.inner.data.device.put("choice", "workspaceOwners", { aw: "s1", ws2: "s2", ws1: "s2" });
    await seed.close();

    let s1ListsW = false;
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1") {
          return Effect.succeed(jsonResponse(200, {
            user: { sub: "s1" },
            workspaces: s1ListsW ? [{ id: "aw", name: "AW" }, { id: "ws1", name: "W" }] : [{ id: "aw", name: "AW" }],
            invitations: [],
            relay_url: "https://relay.test",
          }));
        }
        return Effect.succeed(jsonResponse(503, { error: "offline" }));
      }
      return origFetch(req);
    };
    let pauseOpenS1 = false;
    let releaseOpenS1: (() => void) | null = null;
    const openS1Gate = new Promise<void>((r) => { releaseOpenS1 = r; });
    const origOpen = host.openDb.bind(host);
    host.openDb = (name) => {
      if (name === dbName("s1") && pauseOpenS1) {
        pauseOpenS1 = false;
        return Effect.flatMap(Effect.promise(() => openS1Gate), () => origOpen(name));
      }
      return origOpen(name);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    assert.equal(core.inner.data.isDeferred("s1"), true, "s1 starts deferred while active ws1 belongs to s2");
    // Complete A's first 200 /v1/me excluding ws1 while A is still deferred!
    await run(core.inner.cloudSync.refreshAccount("s1"));
    assert.equal(core.inner.data.isDeferred("s1"), true);
    assert.equal(core.inner.workspaces.owner("ws1"), "s2");

    // Start composer.text("new:ws1") and pause opening A's DB.
    pauseOpenS1 = true;
    const ui = core.connect();
    call(core, ui, 1, "composer.text", { key: "new:ws1", text: "must-cancel-liveMe" });
    await host.settle();

    // While waiting for A's DB to open, A receives a second 200 /v1/me that newly adds ws1!
    s1ListsW = true;
    await run(core.inner.cloudSync.refreshAccount("s1"));
    releaseOpenS1!();
    await host.settle();
    const ans = answers(host.takeEmitted() as never, 1);
    assert.equal((ans?.error as { code?: string } | undefined)?.code, "cancelled", "MUST cancel when deferred A's liveMe already excluded W before wait");
    assert.equal(core.inner.data.db("s1")!.draft("ws1", "new"), undefined);
    assert.equal(core.inner.data.db("s2")!.draft("ws1", "new"), undefined);
    await core.close();
  }

  // 4) P0-4: In-place re-login of A MUST drop late /v1/me from old session (never flipping ws1 from B to A)!
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "aw", name: "AW" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws1", name: "W" }] });
    await seed.close();

    let releaseOldMe: (() => void) | null = null;
    const oldMeGate = new Promise<void>((r) => { releaseOldMe = r; });
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/auth/password")) {
        return Effect.succeed(jsonResponse(200, {
          access_token: "access-s1-v2", refresh_token: "refresh-s1-v2", subject: "s1",
          email: "s1@example.com", name: "S1", expires_at: Math.floor(host.nowMs() / 1000) + 3600,
        }));
      }
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1") {
          return Effect.map(Effect.promise(() => oldMeGate), () =>
            jsonResponse(200, {
              user: { sub: "s1" },
              workspaces: [{ id: "aw", name: "AW" }, { id: "ws1", name: "W" }],
              invitations: [],
              relay_url: "https://relay.test",
            }),
          );
        }
        if (auth === "Bearer access-s1-v2") {
          return Effect.succeed(jsonResponse(200, {
            user: { sub: "s1" },
            workspaces: [{ id: "aw", name: "AW" }],
            invitations: [],
            relay_url: "https://relay.test",
          }));
        }
        return Effect.succeed(jsonResponse(503, { error: "offline" }));
      }
      return origFetch(req);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    assert.equal(core.inner.workspaces.owner("ws1"), "s2");
    const oldMeP = run(core.inner.cloudSync.refreshAccount("s1"));
    await host.settle();

    // Direct in-place re-login of s1 -> new session refreshes /v1/me without ws1.
    await run(core.inner.accounts.passwordSignIn("s1@example.com", "pw", "dev"));
    await host.settle();
    await run(core.inner.cloudSync.refreshAccount("s1"));
    assert.equal(core.inner.workspaces.owner("ws1"), "s2");

    // Release stale old-session /v1/me (which listed ws1) -> MUST be ignored!
    releaseOldMe!();
    await oldMeP;
    await host.settle();
    assert.equal(core.inner.workspaces.owner("ws1"), "s2", "stale old-session /v1/me MUST NOT flip ws1 owner from B to A");
    const ui = core.connect();
    call(core, ui, 2, "composer.text", { key: "new:ws1", text: "belongs-to-b" });
    await host.settle();
    await host.time.pass(350);
    await run(core.inner.data.written);
    assert.equal((core.inner.data.db("s2")!.draft("ws1", "new") as J)?.text, "belongs-to-b");
    assert.equal(core.inner.data.db("s1")!.draft("ws1", "new"), undefined);
    await core.close();
  }

  // 5) P1-1: Legacy no-session credential + failed first cleanup read after in-place re-login MUST block cache hit!
  {
    const { host } = setupTwoAccountHost();
    const credKey = "credential/s1/ws1";
    const nowSec = Math.floor(host.nowMs() / 1000);
    host.store(credKey, { device: "dev-1", credential: "legacy-old-cred", issued_at: nowSec, expires_at: nowSec + 3600, relay_url: "https://relay.test" });
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    seed.inner.data.device.put("choice", "credWorkspaces/s1", ["ws1"]);
    await seed.close();

    let failFirstCredGet = false;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key) => {
      if (key === credKey && failFirstCredGet) {
        failFirstCredGet = false;
        return Effect.fail(new HostError("transient cred read fail"));
      }
      return origGet(key);
    };
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      if (req.url.endsWith("/v1/auth/password")) {
        return Effect.succeed(jsonResponse(200, {
          access_token: "s1-new-a", refresh_token: "s1-new-r", subject: "s1",
          email: "s1@example.com", name: "S1", expires_at: nowSec + 3600,
        }));
      }
      if (req.url.endsWith("/v1/workspaces/ws1/credential")) {
        return Effect.succeed(jsonResponse(503, { error: "offline" }));
      }
      return origFetch(req);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    failFirstCredGet = true;
    await run(core.inner.accounts.passwordSignIn("s1@example.com", "pw", "dev"));
    await host.settle();

    // Cleanup's first storageGet failed -> key MUST stay blocked by pendingCredentialDeletes!
    const credRes = await run(Effect.result(core.inner.cloudSync.credential("ws1", "dev-1", false, null)));
    assert.equal(credRes._tag, "Failure", "new session MUST NOT hit unverified legacy credential after failed cleanup read");
    await core.close();
  }

  // 6) P1-2: Comma `comma/session` read fails at startup AND during identify 200 -> MUST stay unloaded & keep session + cred!
  {
    const host = new FakeHost();
    const ORIGIN = "https://comma.test";
    const credKey = "credential/usr_1/ws1";
    const sid = "01KEEPCOMMA000000000000000";
    host.store(COMMA_ACCOUNT_KEY, { sub: "usr_1", email: "a@x.com", name: "Ada", picture: "" });
    host.store(COMMA_SESSION_KEY, { sub: "usr_1", session: sid });
    host.store(credKey, { device: "dev-1", session: sid, credential: "valid-comma-cred", issued_at: 1, expires_at: 9999999999, relay_url: "https://relay.comma.test" });

    const seed = await Core.create(host, { clock: host.time.clock, account: commaAccountProvider({ origin: ORIGIN, bearer: async () => "tok" }) });
    seed.inner.data.device.put("choice", "credWorkspaces/usr_1", ["ws1"]);
    seed.inner.data.device.put("choice", "accountSessions", { usr_1: sid });
    await seed.close();

    let failSessionReads = true;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key) => {
      if (key === COMMA_SESSION_KEY && failSessionReads) {
        return Effect.fail(new HostError("comma session io fail"));
      }
      return origGet(key);
    };
    host.onFetch((req) => {
      if (req.url === `${ORIGIN}/v1/comma/stations/me`) {
        return jsonResponse(200, {
          user: { id: "usr_1", email: "a@x.com", name: "Ada" },
          workspaces: [{ id: "ws1", name: "WS1", role: "owner" }],
          relay_urls: ["https://relay.comma.test"],
        });
      }
      return jsonResponse(503, {});
    });

    const core = await Core.create(host, { clock: host.time.clock, account: commaAccountProvider({ origin: ORIGIN, bearer: async () => "tok" }) });
    await host.settle();
    assert.equal(core.inner.accounts.isUnloaded(), true, "MUST remain unloaded when comma/session read fails");
    assert.deepEqual(parseJson(host.stored(COMMA_SESSION_KEY)!), { sub: "usr_1", session: sid }, "comma/session MUST NOT be deleted");
    assert.ok(host.stored(credKey) !== undefined, "valid Comma credential MUST NOT be deleted");
    await core.close();
  }

  // 7) P1-3: Comma `comma/account` fails first read -> identify returns 401 -> MUST recover sub & deleteDb(A) so re-login sees no old draft!
  {
    const host = new FakeHost();
    const ORIGIN = "https://comma.test";
    host.store(COMMA_ACCOUNT_KEY, { sub: "usr_1", email: "a@x.com", name: "Ada", picture: "" });
    let commaStatus: 200 | 401 = 200;
    host.onFetch((req) => {
      if (req.url === `${ORIGIN}/v1/comma/stations/me`) {
        return commaStatus === 200
          ? jsonResponse(200, { user: { id: "usr_1", email: "a@x.com", name: "Ada" }, workspaces: [{ id: "ws1", name: "WS1", role: "owner" }], relay_urls: ["https://relay.comma.test"] })
          : jsonResponse(401, { error: "unauthorized" });
      }
      return jsonResponse(503, {});
    });
    const makeComma = () => commaAccountProvider({ origin: ORIGIN, bearer: async () => "tok" });

    // Core 1: store a draft in usr_1's SQLite DB and close.
    const core1 = await Core.create(host, { clock: host.time.clock, account: makeComma() });
    await host.settle();
    await run(core1.inner.data.openAccount("usr_1"));
    core1.inner.data.db("usr_1")!.putDraft("ws1", "new", { text: "comma-secret-draft", files: [] });
    await core1.close();

    // Core 2: fail ONLY the first comma/account read; identify gets 401 -> MUST deleteDb(usr_1)!
    let failFirstCommaAccountGet = true;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key) => {
      if (key === COMMA_ACCOUNT_KEY && failFirstCommaAccountGet) {
        failFirstCommaAccountGet = false;
        return Effect.fail(new HostError("first comma/account read fail"));
      }
      return origGet(key);
    };
    let deleteDbCalls = 0;
    const origDeleteDb = host.deleteDb!.bind(host);
    host.deleteDb = (name) => {
      if (name === dbName("usr_1")) deleteDbCalls++;
      return origDeleteDb(name);
    };
    commaStatus = 401;
    const core2 = await Core.create(host, { clock: host.time.clock, account: makeComma() });
    for (let i = 0; i < 40 && deleteDbCalls === 0; i++) await host.settle();
    assert.equal(deleteDbCalls, 1, "Comma 401 after initial comma/account read failure MUST delete usr_1's DB");
    assert.equal(host.stored(COMMA_ACCOUNT_KEY), undefined);
    await core2.close();

    // Core 3: re-login usr_1 -> MUST NOT see old draft!
    commaStatus = 200;
    const core3 = await Core.create(host, { clock: host.time.clock, account: makeComma() });
    for (let i = 0; i < 40 && core3.inner.accounts.list().length === 0; i++) await host.settle();
    await run(core3.inner.data.openAccount("usr_1"));
    assert.equal(core3.inner.data.db("usr_1")!.draft("ws1", "new"), undefined, "re-logged-in Comma account MUST NOT read old draft");
    await core3.close();
  }
});

test("R22 regressions: dual-Core WakingHost lock, corrupt accounts startup, bound Comma pending-signout (B safe & deleteDb barrier), Comma unloaded refresh recovery, SQLITE_IOERR legacy cred guard, later-member sign-out tolerance, and 401 read-error propagation", async () => {
  // 1) P0-1: Two real Core.create(host) instances (each wrapped in its own WakingHost) sharing one FakeHost.
  //    Pause Core 1 refresh at storageSet("accounts") while Core 2 re-logs in -> Core 2's SID MUST survive (200 & 401)!
  for (const status of [200, 401] as const) {
    const host = new FakeHost();
    host.store("accounts", [{
      sub: "s1", email: "s1@example.com", name: "S1", picture: "", access: "old-a", refresh: "old-r",
      access_expires: Math.floor(host.nowMs() / 1000) - 10, session: "01OLD000000000000000000000",
    }]);
    let pauseFirstSet = false;
    let enteredSet = false;
    let releaseSet: (() => void) | null = null;
    const setGate = new Promise<void>((r) => { releaseSet = r; });
    const origSet = host.storageSet.bind(host);
    host.storageSet = (key, bytes) => {
      if (key === "accounts" && pauseFirstSet) {
        pauseFirstSet = false;
        enteredSet = true;
        return Effect.flatMap(Effect.promise(() => setGate), () => origSet(key, bytes));
      }
      return origSet(key, bytes);
    };
    host.onFetch((req) => {
      if (req.url.endsWith("/v1/auth/password")) {
        return jsonResponse(200, {
          access_token: "core2-a", refresh_token: "core2-r", subject: "s1",
          email: "s1@example.com", name: "S1", expires_at: Math.floor(host.nowMs() / 1000) + 3600,
        });
      }
      if (req.url.endsWith("/v1/auth/refresh")) {
        return status === 200
          ? jsonResponse(200, {
              access_token: "stale-200-a", refresh_token: "stale-200-r", subject: "s1",
              email: "s1@example.com", expires_at: Math.floor(host.nowMs() / 1000) + 3600,
            })
          : jsonResponse(401, { error: "invalid_session" });
      }
      if (req.url.endsWith("/v1/me")) return jsonResponse(503, { error: "offline" });
      return jsonResponse(404, {});
    });

    const core1 = await Core.create(host, { clock: host.time.clock });
    const core2 = await Core.create(host, { clock: host.time.clock });
    pauseFirstSet = true;
    const p1 = run(Effect.result(core1.inner.accounts.accessToken("s1")));
    for (let i = 0; i < 30 && !enteredSet; i++) await host.settle();
    assert.equal(enteredSet, true, "Core 1 entered accounts storageSet");

    // Core 2 does in-place re-login while Core 1 holds the shared rootHost lock!
    const p2 = run(core2.inner.accounts.passwordSignIn("s1@example.com", "pw", "dev")).then(() => core2.inner.accounts.sessionId("s1"));
    await host.settle();
    releaseSet!();
    const [, core2Sid] = await Promise.all([p1, p2]);
    const disk = parseJson(host.stored("accounts")) as Array<{ sub: string; session?: string; refresh: string }>;
    assert.equal(disk.length, 1, `two Cores sharing FakeHost MUST serialize commits (${status})`);
    assert.equal(disk[0]!.session, core2Sid);
    assert.equal(disk[0]!.refresh, "core2-r");
    await core1.close();
    await core2.close();
  }

  // 2) P0-2: Corrupt/truncated JSON on initial storageGet("accounts") MUST set isUnloaded() === true and preserve creds + pendingMe!
  {
    const { host } = setupTwoAccountHost();
    const credKey = "credential/s1/ws1";
    host.store(credKey, { device: "dev-1", credential: "keep-me", issued_at: 1, expires_at: 9999999999, relay_url: "https://relay.test" });
    const seed = await Core.create(host, { clock: host.time.clock });
    seed.inner.data.device.put("choice", "pendingMe", { s1: { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] } });
    seed.inner.data.device.put("choice", "credWorkspaces/s1", ["ws1"]);
    await seed.close();

    let corruptOnce = true;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key) => {
      if (key === "accounts" && corruptOnce) {
        corruptOnce = false;
        return Effect.succeed(new TextEncoder().encode('[{"sub":"s1"'));
      }
      return origGet(key);
    };
    const core = await Core.create(host, { clock: host.time.clock });
    await host.settle();
    assert.equal(core.inner.accounts.isUnloaded(), true, "corrupt non-null accounts JSON MUST set isUnloaded() === true");
    assert.ok(host.stored(credKey) !== undefined, "credential MUST NOT be deleted as orphan on corrupt accounts read");
    const choice = parseJson(host.stored("device/choice")) as J;
    assert.ok(choice?.pendingMe?.s1 !== undefined, "pendingMe[s1] MUST NOT be pruned on corrupt accounts read");
    await core.close();
  }

  // 3) P0-3: Comma A 401 -> pending-signout marker; A's DB deleted but deleting marker keeps failing; B logs in & saves draft;
  //    restart MUST NOT delete B's DB or B's draft!
  {
    const host = new FakeHost();
    const ORIGIN = "https://comma.test";
    host.store(COMMA_ACCOUNT_KEY, { sub: "usr_a", email: "a@x.com", name: "A", picture: "" });
    let activeUser: "a" | "b" | "401" = "a";
    host.onFetch((req) => {
      if (req.url === `${ORIGIN}/v1/comma/stations/me`) {
        if (activeUser === "401") return jsonResponse(401, { error: "unauthorized" });
        const id = activeUser === "a" ? "usr_a" : "usr_b";
        return jsonResponse(200, {
          user: { id, email: `${id}@x.com`, name: id.toUpperCase() },
          workspaces: [{ id: `ws_${activeUser}`, name: id, role: "owner" }],
          relay_urls: ["https://relay.comma.test"],
        });
      }
      return jsonResponse(503, {});
    });
    const makeComma = () => commaAccountProvider({ origin: ORIGIN, bearer: async () => "tok" });

    // Seed A DB with draft.
    const c1 = await Core.create(host, { clock: host.time.clock, account: makeComma() });
    await host.settle();
    await run(c1.inner.data.openAccount("usr_a"));
    c1.inner.data.db("usr_a")!.putDraft("ws_a", "new", { text: "a-draft", files: [] });
    await c1.close();

    // Core 2: comma/account unreadable throughout + 401 -> leaves pending-signout marker.
    let failAccGet = true;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key) => (key === COMMA_ACCOUNT_KEY && failAccGet ? Effect.fail(new HostError("acc io fail")) : origGet(key));
    activeUser = "401";
    const c2 = await Core.create(host, { clock: host.time.clock, account: makeComma() });
    await host.settle();
    assert.ok(host.stored(COMMA_PENDING_SIGNOUT_KEY) !== undefined, "401 with unreadable comma/account left pending marker");
    await c2.close();

    // Core 3: storageGet recovers, A's DB gets deleted, BUT deleting pending-signout marker keeps failing! B logs in & writes draft.
    failAccGet = false;
    const origDel = host.storageDelete.bind(host);
    host.storageDelete = (key) => (key === COMMA_PENDING_SIGNOUT_KEY ? Effect.fail(new HostError("marker delete stuck")) : origDel(key));
    activeUser = "b";
    const c3 = await Core.create(host, { clock: host.time.clock, account: makeComma() });
    for (let i = 0; i < 40 && c3.inner.accounts.list()[0]?.sub !== "usr_b"; i++) await host.settle();
    assert.equal(c3.inner.accounts.list()[0]?.sub, "usr_b");
    await run(c3.inner.data.openAccount("usr_b"));
    c3.inner.data.db("usr_b")!.putDraft("ws_b", "new", { text: "b-must-survive", files: [] });
    await c3.close();

    // Core 4: restart with marker still present -> MUST NOT call deleteDb(usr_b) and B's draft MUST survive!
    let deletedB = 0;
    const origDelDb = host.deleteDb!.bind(host);
    host.deleteDb = (name) => {
      if (name === dbName("usr_b")) deletedB++;
      return origDelDb(name);
    };
    const c4 = await Core.create(host, { clock: host.time.clock, account: makeComma() });
    await host.settle();
    assert.equal(deletedB, 0, "A's stuck pending-signout marker MUST NEVER delete B's DB");
    assert.equal(c4.inner.accounts.list()[0]?.sub, "usr_b");
    await run(c4.inner.data.openAccount("usr_b"));
    assert.equal((c4.inner.data.db("usr_b")!.draft("ws_b", "new") as J)?.text, "b-must-survive");
    await c4.close();
  }

  // 4) P1-4: Pending sign-out barrier: ① unreadable marker on offline start blocks opening A; ② failed deleteDb(A)
  //    followed by identify 200 MUST keep marker & refuse opening A until deleteDb(A) actually succeeds!
  {
    const host = new FakeHost();
    const ORIGIN = "https://comma.test";
    host.store(COMMA_ACCOUNT_KEY, { sub: "usr_a", email: "a@x.com", name: "A", picture: "" });
    let status: 200 | 401 | 503 = 200;
    host.onFetch((req) => {
      if (req.url === `${ORIGIN}/v1/comma/stations/me`) {
        if (status === 401) return jsonResponse(401, { error: "unauthorized" });
        if (status === 503) return jsonResponse(503, { error: "offline" });
        return jsonResponse(200, { user: { id: "usr_a", email: "a@x.com", name: "A" }, workspaces: [{ id: "ws_a", name: "A", role: "owner" }], relay_urls: ["https://relay.comma.test"] });
      }
      return jsonResponse(503, {});
    });
    const makeComma = () => commaAccountProvider({ origin: ORIGIN, bearer: async () => "tok" });

    const c1 = await Core.create(host, { clock: host.time.clock, account: makeComma() });
    await host.settle();
    await run(c1.inner.data.openAccount("usr_a"));
    c1.inner.data.db("usr_a")!.putDraft("ws_a", "new", { text: "stale-a-draft", files: [] });
    await c1.close();

    // Generate real 401 pending-signout marker.
    let failAcc = true;
    let failMarkerRead = false;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key) => {
      if (key === COMMA_ACCOUNT_KEY && failAcc) return Effect.fail(new HostError("acc unreadable"));
      if (key === COMMA_PENDING_SIGNOUT_KEY && failMarkerRead) {
        failMarkerRead = false;
        return Effect.fail(new HostError("marker read fail"));
      }
      return origGet(key);
    };
    status = 401;
    const c2 = await Core.create(host, { clock: host.time.clock, account: makeComma() });
    await host.settle();
    await c2.close();

    // ① Offline restart with one marker read failure -> A MUST NOT be listed as logged-in!
    failAcc = false;
    failMarkerRead = true;
    status = 503;
    const c3 = await Core.create(host, { clock: host.time.clock, account: makeComma() });
    await host.settle();
    assert.deepEqual(c3.inner.accounts.list(), [], "unreadable pending-signout marker MUST block listing A");
    assert.equal(c3.inner.accounts.isUnloaded(), true);
    await c3.close();

    // ② deleteDb(A) fails twice (startup + identify 200) -> marker MUST stay & A MUST stay blocked!
    let failDeleteDbCount = 2;
    const origDelDb = host.deleteDb!.bind(host);
    host.deleteDb = (name) => {
      if (name === dbName("usr_a") && failDeleteDbCount > 0) {
        failDeleteDbCount--;
        return Effect.fail(new HostError("deleteDb busy"));
      }
      return origDelDb(name);
    };
    status = 200;
    const c4 = await Core.create(host, { clock: host.time.clock, account: makeComma() });
    await host.settle();
    assert.deepEqual(c4.inner.accounts.list(), [], "failed deleteDb(A) MUST block identify 200 from reopening A");
    assert.ok(host.stored(COMMA_PENDING_SIGNOUT_KEY) !== undefined, "marker MUST remain while deleteDb(A) fails");
    await c4.close();

    // Once deleteDb(A) succeeds, restart deletes old A DB FIRST and re-logged-in A sees NO old draft!
    const c5 = await Core.create(host, { clock: host.time.clock, account: makeComma() });
    for (let i = 0; i < 40 && c5.inner.accounts.list().length === 0; i++) await host.settle();
    await run(c5.inner.data.openAccount("usr_a"));
    assert.equal(c5.inner.data.db("usr_a")!.draft("ws_a", "new"), undefined, "old A draft MUST be gone after deleteDb succeeds");
    await c5.close();
  }

  // 5) P1-5: Comma comma/session read fails twice (startup + first identify) -> storage recovers -> refreshAccount(A)
  //    MUST clear isUnloaded() and unblock workspace writes!
  {
    const host = new FakeHost();
    const ORIGIN = "https://comma.test";
    const sid = "01RECOVERCOMMA000000000000";
    host.store(COMMA_ACCOUNT_KEY, { sub: "usr_1", email: "a@x.com", name: "Ada", picture: "" });
    host.store(COMMA_SESSION_KEY, { sub: "usr_1", session: sid });
    host.onFetch((req) => {
      if (req.url === `${ORIGIN}/v1/comma/stations/me`) {
        return jsonResponse(200, { user: { id: "usr_1", email: "a@x.com", name: "Ada" }, workspaces: [{ id: "ws1", name: "WS1", role: "owner" }], relay_urls: ["https://relay.comma.test"] });
      }
      return jsonResponse(503, {});
    });
    let failSession = true;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key) => {
      if (key === COMMA_SESSION_KEY && failSession) {
        return Effect.fail(new HostError("session io fail"));
      }
      return origGet(key);
    };

    const core = await Core.create(host, { clock: host.time.clock, account: commaAccountProvider({ origin: ORIGIN, bearer: async () => "tok" }) });
    await host.settle();
    assert.equal(core.inner.accounts.isUnloaded(), true);

    // Storage has now recovered; explicit refreshAccount("usr_1") MUST clear isUnloaded() and allow writes!
    failSession = false;
    await run(core.inner.cloudSync.refreshAccount("usr_1"));
    await host.settle();
    assert.equal(core.inner.accounts.isUnloaded(), false, "same-sub refreshAccount MUST recover unloaded Comma session");
    assert.equal(core.inner.accounts.sessionId("usr_1"), sid);
    await run(core.inner.cloudSync.ensureVerifiedOwners(["ws1"]));
    await core.close();
  }

  // 6) P1-6: SQLITE_IOERR reading account_doc/me during in-place re-login MUST still block legacy no-session credential!
  {
    const { host } = setupTwoAccountHost();
    const credKey = "credential/s1/ws1";
    const nowSec = Math.floor(host.nowMs() / 1000);
    host.store(credKey, { device: "dev-1", credential: "legacy-ioerr-cred", issued_at: nowSec, expires_at: nowSec + 3600, relay_url: "https://relay.test" });
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    await seed.close();

    let throwMeIoErr = false;
    const origOpen = host.openDb.bind(host);
    host.openDb = (name) =>
      Effect.map(origOpen(name), (sql) =>
        name !== dbName("s1")
          ? sql
          : {
              ...sql,
              exec: (s) => sql.exec(s),
              run: (s, p) => sql.run(s, p),
              close: () => sql.close(),
              all: (s, p) => {
                if (throwMeIoErr && s.includes("account_doc")) {
                  throwMeIoErr = false;
                  throw new SqlError("SQLITE_IOERR: disk I/O error", "other");
                }
                return sql.all(s, p);
              },
            },
      );
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      if (req.url.endsWith("/v1/auth/password")) {
        return Effect.succeed(jsonResponse(200, {
          access_token: "s1-v2-a", refresh_token: "s1-v2-r", subject: "s1",
          email: "s1@example.com", name: "S1", expires_at: nowSec + 3600,
        }));
      }
      if (req.url.endsWith("/v1/workspaces/ws1/credential")) return Effect.succeed(jsonResponse(503, { error: "offline" }));
      return origFetch(req);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    // Clear credWorkspaces so SQLite account_doc/me is the ONLY source of ws1!
    core.inner.data.device.put("choice", "credWorkspaces/s1", undefined);
    core.inner.data.device.put("choice", "workspaceOwners", undefined);
    throwMeIoErr = true;
    await run(core.inner.accounts.passwordSignIn("s1@example.com", "pw", "dev"));
    await host.settle();

    // New session MUST NOT hit legacy no-session credential even though SQLite read threw IOERR!
    const credRes = await run(Effect.result(core.inner.cloudSync.credential("ws1", "dev-1", false, null)));
    assert.equal(credRes._tag, "Failure", "SQLITE_IOERR during session replacement MUST block legacy no-session credential hit");
    await core.close();
  }

  // 7) P1-7: A (first, deferred) already has same-session live /v1/me listing W; B (later, open) also has W.
  //    Pause A openDb during composer.text("new:W"), sign out B -> edit MUST SUCCEED and write draft to A!
  {
    const { host } = setupTwoAccountHost();
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "W" }] });
    seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws1", name: "W" }] });
    seed.inner.data.device.put("choice", "workspaceOwners", { ws2: "s2", ws1: "s2" });
    await seed.close();

    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/me")) {
        if (auth === "Bearer access-s1") {
          return Effect.succeed(jsonResponse(200, { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "W" }], invitations: [], relay_url: "https://relay.test" }));
        }
        return Effect.succeed(jsonResponse(503, { error: "offline" }));
      }
      if (req.url.endsWith("/v1/auth/logout")) return Effect.succeed(jsonResponse(200, {}));
      return origFetch(req);
    };
    let pauseOpenS1 = false;
    let releaseOpenS1: (() => void) | null = null;
    const openS1Gate = new Promise<void>((r) => { releaseOpenS1 = r; });
    const origOpen = host.openDb.bind(host);
    host.openDb = (name) => {
      if (name === dbName("s1") && pauseOpenS1) {
        pauseOpenS1 = false;
        return Effect.flatMap(Effect.promise(() => openS1Gate), () => origOpen(name));
      }
      return origOpen(name);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    assert.equal(core.inner.data.isDeferred("s1"), true);
    await run(core.inner.cloudSync.refreshAccount("s1"));
    assert.equal(core.inner.data.isDeferred("s1"), true);

    pauseOpenS1 = true;
    const ui = core.connect();
    call(core, ui, 7, "composer.text", { key: "new:ws1", text: "a-keeps-after-b-signout" });
    await host.settle();

    // Sign out later shared member B while A's DB open is paused!
    await run(core.inner.accounts.signOut("s2"));
    releaseOpenS1!();
    await host.settle();
    await host.time.pass(350);
    await run(core.inner.data.written);
    const ans = answers(host.takeEmitted() as never, 7);
    assert.ok(ans && "ok" in ans, `edit owned by A MUST succeed when later member B signs out, got: ${JSON.stringify(ans)}`);
    assert.equal((core.inner.data.db("s1")!.draft("ws1", "new") as J)?.text, "a-keeps-after-b-signout");
    await core.close();
  }

  // 8) P1-8: 401 refresh with pre-commit storageGet("accounts") failure MUST propagate retryable error (NOT signed_out)!
  {
    const host = new FakeHost();
    host.store("accounts", [{
      sub: "s1", email: "s1@example.com", name: "S1", picture: "", access: "old-a", refresh: "old-r",
      access_expires: Math.floor(host.nowMs() / 1000) - 10, session: "01S10000000000000000000000",
    }]);
    let getCalls = 0;
    const origGet = host.storageGet.bind(host);
    host.storageGet = (key) => {
      if (key === "accounts") {
        getCalls++;
        // Call 1 = load, Call 2 = #adoptStored, Call 3 = pre-commit #forgetIfMatches -> fail!
        if (getCalls === 3) return Effect.fail(new HostError("verify read io fail"));
      }
      return origGet(key);
    };
    host.onFetch((req) => (req.url.endsWith("/v1/auth/refresh") ? jsonResponse(401, { error: "invalid_session" }) : jsonResponse(404, {})));
    const accounts = await run(Accounts.load(host));
    const res = await run(Effect.result(accounts.accessToken("s1")));
    assert.equal(res._tag, "Failure");
    assert.notEqual(res.failure.code, "signed_out", "unverified 401 MUST propagate retryable storage error instead of signed_out");
    assert.equal(accounts.list().length, 1, "account MUST remain in memory");
    assert.equal((parseJson(host.stored("accounts")) as unknown[]).length, 1, "account MUST remain on disk");
  }
});

test("R24 regression: in-place re-login with persistent IOERR or unloaded device/choice does not cause cloud socket reconnect storm", async () => {
  // 1) Persistent SQLITE_IOERR on account_doc/me during & after in-place re-login with active /v1/events socket:
  //    socket MUST reconnect exactly once for the new session (no tight reconnect + /v1/me loop),
  //    legacy no-session credential MUST stay blocked until IOERR clears, and recovery MUST NOT tear down the new socket.
  {
    const { host } = setupTwoAccountHost();
    const credKey = "credential/s1/ws1";
    const nowSec = Math.floor(host.nowMs() / 1000);
    host.store(credKey, { device: "dev-1", credential: "legacy-storm-cred", issued_at: nowSec, expires_at: nowSec + 3600, relay_url: "https://relay.test" });
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    await seed.close();

    let throwMeIoErr = false;
    const origOpen = host.openDb.bind(host);
    host.openDb = (name) =>
      Effect.map(origOpen(name), (sql) =>
        name !== dbName("s1")
          ? sql
          : {
              ...sql,
              exec: (s) => sql.exec(s),
              run: (s, p) => sql.run(s, p),
              close: () => sql.close(),
              all: (s, p) => {
                if (throwMeIoErr && s.includes("account_doc")) {
                  throw new SqlError("SQLITE_IOERR: persistent disk I/O error", "other");
                }
                return sql.all(s, p);
              },
            },
      );

    let meCallsS1 = 0;
    const s1WsCount = () => host.sockets.filter((s) => s.url.includes("/v1/events") && (s.protocols.includes("stillfail-token.access-s1") || s.protocols.includes("stillfail-token.s1-v2-a"))).length;
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/auth/password")) {
        return Effect.succeed(jsonResponse(200, {
          access_token: "s1-v2-a", refresh_token: "s1-v2-r", subject: "s1",
          email: "s1@example.com", name: "S1", expires_at: nowSec + 3600,
        }));
      }
      if (req.url.endsWith("/v1/me") && (auth === "Bearer access-s1" || auth === "Bearer s1-v2-a")) {
        meCallsS1++;
        return Effect.succeed(jsonResponse(200, {
          user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }], invitations: [], relay_url: "https://relay.test",
        }));
      }
      if (req.url.endsWith("/v1/workspaces/ws1/credential")) return Effect.succeed(jsonResponse(503, { error: "offline" }));
      return origFetch(req);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    await host.settle();
    const wsBefore = s1WsCount();
    const meBefore = meCallsS1;
    assert.ok(wsBefore >= 1, "initial s1 cloud socket opened");

    core.inner.data.device.put("choice", "credWorkspaces/s1", undefined);
    core.inner.data.device.put("choice", "workspaceOwners", undefined);
    throwMeIoErr = true;
    await run(core.inner.accounts.passwordSignIn("s1@example.com", "pw", "dev"));
    await host.settle();
    const wsAfterSignIn = s1WsCount();
    const meAfterSignIn = meCallsS1;
    // 1 socket reconnect for the new session; 2 /v1/me calls (1 profile fetch inside passwordSignIn + 1 initial sync on the new socket).
    assert.equal(wsAfterSignIn, wsBefore + 1, "socket MUST reconnect exactly once for new session (no reconnect storm)");
    assert.equal(meAfterSignIn, meBefore + 2, "/v1/me MUST run only for passwordSignIn profile fetch + new socket open");
    await host.time.pass(5000);
    await host.settle();
    assert.equal(s1WsCount(), wsAfterSignIn, "persistent IOERR MUST NOT trigger further socket reconnects");
    assert.equal(meCallsS1, meAfterSignIn, "persistent IOERR MUST NOT trigger further /v1/me calls");

    const credRes = await run(Effect.result(core.inner.cloudSync.credential("ws1", "dev-1", false, null)));
    assert.equal(credRes._tag, "Failure", "legacy no-session credential MUST remain blocked while IOERR persists");

    // Once IOERR clears and /v1/me runs again, cleanup finishes WITHOUT restarting the healthy new-session socket.
    throwMeIoErr = false;
    await run(core.inner.cloudSync.refreshAccount("s1"));
    await host.settle();
    assert.equal(s1WsCount(), wsBefore + 1, "cleanup recovery MUST NOT tear down healthy new-session socket");
    assert.equal(host.stored(credKey), undefined, "legacy credential deleted once IOERR cleared");
    await core.close();
  }

  // 2) Permanently unloaded device/choice during in-place re-login with active /v1/events socket:
  //    socket MUST reconnect exactly once (no reconnect storm) and /v1/me MUST NOT loop.
  {
    const { host } = setupTwoAccountHost();
    const nowSec = Math.floor(host.nowMs() / 1000);
    const seed = await Core.create(host, { clock: host.time.clock });
    await run(seed.inner.data.openAccounts(["s1", "s2"]));
    seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
    await seed.close();

    const origGet = host.storageGet.bind(host);
    let failChoice = true;
    host.storageGet = (key) => (key === "device/choice" && failChoice ? Effect.fail(new HostError("choice io fail")) : origGet(key));

    let meCallsS1 = 0;
    const s1WsCount = () => host.sockets.filter((s) => s.url.includes("/v1/events") && (s.protocols.includes("stillfail-token.access-s1") || s.protocols.includes("stillfail-token.s1-v2-a"))).length;
    const origFetch = host.fetch.bind(host);
    host.fetch = (req) => {
      const auth = req.headers.find(([k]) => k.toLowerCase() === "authorization")?.[1] ?? "";
      if (req.url.endsWith("/v1/auth/password")) {
        return Effect.succeed(jsonResponse(200, {
          access_token: "s1-v2-a", refresh_token: "s1-v2-r", subject: "s1",
          email: "s1@example.com", name: "S1", expires_at: nowSec + 3600,
        }));
      }
      if (req.url.endsWith("/v1/me") && (auth === "Bearer access-s1" || auth === "Bearer s1-v2-a")) {
        meCallsS1++;
        return Effect.succeed(jsonResponse(200, {
          user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }], invitations: [], relay_url: "https://relay.test",
        }));
      }
      return origFetch(req);
    };

    const core = await Core.create(host, { clock: host.time.clock });
    await run(core.inner.data.openAccounts(["s1", "s2"]));
    assert.equal(core.inner.data.device.isUnloaded("choice"), true);
    await host.settle();
    const wsBefore = s1WsCount();
    const meBefore = meCallsS1;
    assert.ok(wsBefore >= 1, "initial s1 cloud socket opened");

    await run(core.inner.accounts.passwordSignIn("s1@example.com", "pw", "dev"));
    await host.settle();
    const wsAfterSignIn = s1WsCount();
    const meAfterSignIn = meCallsS1;
    assert.equal(wsAfterSignIn, wsBefore + 1, "unloaded device/choice MUST reconnect socket exactly once");
    assert.equal(meAfterSignIn, meBefore + 2, "unloaded device/choice MUST run /v1/me only for passwordSignIn + new socket open");
    await host.time.pass(5000);
    await host.settle();
    assert.equal(s1WsCount(), wsAfterSignIn, "unloaded device/choice MUST NOT trigger socket reconnect storm");
    assert.equal(meCallsS1, meAfterSignIn, "unloaded device/choice MUST NOT trigger /v1/me loop");

    failChoice = false;
    await core.close();
  }
});

test("workspaces topic exposes authoritative ownedWorkspaces and invalidates on recomputeOwners change", async () => {
  const { host } = setupTwoAccountHost();
  // Stay offline so seeded DB rows stay intact and recovery is purely driven by local DB open + recomputeOwners.
  host.fetch = () => Effect.fail(new HostError("offline"));
  const seed = await Core.create(host, { clock: host.time.clock });
  await run(seed.inner.data.openAccounts(["s1", "s2"]));
  seed.inner.data.put("me", "s1", { user: { sub: "s1" }, workspaces: [{ id: "ws1", name: "WS 1" }] });
  seed.inner.data.put("me", "s2", { user: { sub: "s2" }, workspaces: [{ id: "ws2", name: "WS 2" }, { id: "ws-unowned", name: "Unowned" }] });
  await run(seed.inner.data.written);
  await seed.close();
  // Persist only ws2 -> s2 (so s2 is primary and s1 starts deferred, while ws-unowned has no trusted persisted owner yet).
  host.store("device/choice", { workspace: "ws2", workspaceOwners: { ws2: "s2" } });

  const core = await Core.create(host, { clock: host.time.clock });
  assert.equal(core.inner.data.isDeferred("s1"), true, "s1 starts deferred on cold start");
  const ui = core.connect();
  const held = new Map<number, unknown>();
  core.receive(ui, { kind: "subscribe", id: 77, subscribe: { topic: "workspaces" } });
  await host.settle();
  apply(host, held);
  const initial = held.get(77) as Array<{ account: { sub: string }; ownedWorkspaces?: string[] }> | undefined;
  assert.ok(Array.isArray(initial), "initial workspaces snapshot must be pushed");
  const initS1 = initial.find((r) => r.account.sub === "s1");
  const initS2 = initial.find((r) => r.account.sub === "s2");
  assert.deepEqual(initS1?.ownedWorkspaces, [], "deferred s1 must expose empty ownedWorkspaces");
  assert.deepEqual(initS2?.ownedWorkspaces, ["ws2"], "s2 must expose persisted ws2 but NOT unverified ws-unowned");

  // Open s1 DB -> recomputeOwners updates owners and automatically invalidates { topic: "workspaces" }.
  await run(core.inner.data.openAccounts(["s1", "s2"]));
  await host.settle();
  apply(host, held);
  const updated = held.get(77) as Array<{ account: { sub: string }; ownedWorkspaces?: string[] }> | undefined;
  assert.ok(Array.isArray(updated), "recomputeOwners owner change must invalidate and re-push workspaces topic");
  const s1Row = updated.find((r) => r.account.sub === "s1");
  const s2Row = updated.find((r) => r.account.sub === "s2");
  assert.ok(s1Row?.ownedWorkspaces?.includes("ws1"), "s1 must own ws1 after DB recovery");
  assert.ok(s2Row?.ownedWorkspaces?.includes("ws2"), "s2 must own ws2 after s1 DB recovery");
  assert.ok(s2Row?.ownedWorkspaces?.includes("ws-unowned"), "s2 must own ws-unowned after s1 DB recovery");
  await core.close();
});
