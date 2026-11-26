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
