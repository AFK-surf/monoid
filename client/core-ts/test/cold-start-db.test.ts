// Cold-start database optimizations:
// - B0: active-first multi-account DB open with sign-in order preserved and close/sign-out race safety
// - B1: core.start DB breakdown trace attributes + read-only-first AccountDb cold open (0 write transactions on steady
//   state, full downgrade/DML repair even when schema_version is unchanged)
import assert from "node:assert/strict";
import { test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { Deferred, Effect, Fiber } from "effect";
import { STORAGE_KEY, type StoredAccount } from "../src/accounts.ts";
import { Core } from "../src/core.ts";
import { Data, dbName } from "../src/data.ts";
import { AccountDb } from "../src/db/account.ts";
import { KEPT } from "../src/db/kept.ts";
import { CHAT_MADE } from "../src/db/schema.ts";
import { HostError, type Sql, type SqlRow, type SqlValue } from "../src/host.ts";
import { NodeSql } from "../src/hosts/node-sql.ts";
import { Signer } from "../src/lock.ts";
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
