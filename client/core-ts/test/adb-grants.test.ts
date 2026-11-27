import assert from "node:assert/strict";
import { test } from "node:test";
import { Deferred, Effect } from "effect";
import { Adb, GRANTS_KEY, REVOKED_KEY } from "../src/adb.ts";
import type { Mesh } from "../src/mesh.ts";
import { Runner } from "../src/runtime.ts";
import { Store } from "../src/store.ts";
import { FakeHost } from "../src/testing.ts";
import { personalStub, takeAll } from "./adb-personal-stub.ts";

test("taking back a chat takes back every grant behind its one row", async () => {
  const host = new FakeHost();
  const runner = new Runner(host.time.clock);
  const store = new Store(host, runner);
  const requests: string[] = [];
  const link = {
    ask: (_head: unknown, { adb: ask }: { adb: { op: string; request: string } }) => Effect.sync(() => {
      assert.equal(ask.op, "revoke");
      requests.push(ask.request);
      let sent = false;
      const bytes = new TextEncoder().encode(JSON.stringify({ request: { id: ask.request, status: "ended" } }));
      return { status: 200, body: { take: Effect.sync(() => { if (sent) return null; sent = true; return bytes; }) } };
    }),
  };
  const mesh = { deviceId: () => "phone", link: () => Effect.succeed(link) } as unknown as Mesh;
  const adb = new Adb({ ...personalStub(), host, runner, store, mesh: () => Effect.succeed(mesh), credentials: () => (() => Effect.succeed({} as never)), relays: () => [], lends: () => false });
  takeAll(adb);
  const exp = Math.floor(host.nowMs() / 1000) + 3600;
  const grant = (id: string, chat: string) => ({ id, chat, session: id, reason: "debug", status: "granted", exp, at: 1 });
  try {
    adb.heard("ws/st", grant("p1", "chat-a"));
    adb.heard("ws/st", grant("p2", "chat-a"));
    adb.heard("ws/st", grant("p3", "chat-b"));
    adb.heard("ws/other", grant("p4", "chat-a"));
    // An older cached grant may know its session but not the chat address yet.
    const older = (id: string) => ({ id, session: "older-session", reason: "debug", status: "granted", exp, at: 1 });
    adb.heard("ws/st", older("old1"));
    adb.heard("ws/st", older("old2"));
    assert.equal(adb.grants().length, 4);
    await runner.run(adb.run({ kind: "revoke", station: "ws/st", request: "p2" }));
    assert.deepEqual(requests, ["p1", "p2"]);
    await runner.run(adb.run({ kind: "revoke", station: "ws/st", request: "old1" }));
    assert.deepEqual(requests, ["p1", "p2", "old1", "old2"]);
    assert.deepEqual(adb.grants().map((g) => g.id).sort(), ["p3", "p4"]);
  } finally {
    runner.shutdown();
  }
});

test("a station's refusal keeps the code it gives (the app goes by it), its words the message; none, invalid_params", async () => {
  const host = new FakeHost();
  const runner = new Runner(host.time.clock);
  const store = new Store(host, runner);
  let body: unknown = null;
  const link = {
    ask: () => Effect.sync(() => {
      let sent = false;
      const bytes = new TextEncoder().encode(JSON.stringify(body));
      return { status: 422, body: { take: Effect.sync(() => { if (sent) return null; sent = true; return bytes; }) } };
    }),
  };
  const mesh = { deviceId: () => "phone", link: () => Effect.succeed(link) } as unknown as Mesh;
  const adb = new Adb({ ...personalStub(), host, runner, store, mesh: () => Effect.succeed(mesh), credentials: () => (() => Effect.succeed({} as never)), relays: () => [], lends: () => false });
  takeAll(adb);
  try {
    const failed = () => runner.run(Effect.flip(adb.run({ kind: "revoke", station: "ws/st", request: "p1" })));
    body = { message: "手机不允许 adb 授权", code: "adb_grant_refused" };
    const refused = await failed();
    assert.deepEqual([refused.code, refused.message], ["adb_grant_refused", "手机不允许 adb 授权"]);
    // (a station from before codes, or another failure: no code of its own)
    body = { message: "授权失败：Error: Unknown permission" };
    const other = await failed();
    assert.deepEqual([other.code, other.message], ["invalid_params", "授权失败：Error: Unknown permission"]);
  } finally {
    runner.shutdown();
  }
});

test("a late whole read does not bring back a grant already taken back", async () => {
  const host = new FakeHost();
  const runner = new Runner(host.time.clock);
  const store = new Store(host, runner);
  let started!: () => void;
  const asked = new Promise<void>((resolve) => { started = resolve; });
  let answer!: (value: unknown) => void;
  const waiting = new Promise<unknown>((resolve) => { answer = resolve; });
  const link = { ask: () => Effect.promise(() => { started(); return waiting; }) };
  const mesh = { deviceId: () => "phone", link: () => Effect.succeed(link) } as unknown as Mesh;
  const adb = new Adb({ ...personalStub(), host, runner, store, mesh: () => Effect.succeed(mesh), credentials: () => (() => Effect.succeed({} as never)), relays: () => [], lends: () => false });
  takeAll(adb);
  const grant = { id: "p1", chat: "chat-a", session: "s1", reason: "debug", status: "granted", exp: Math.floor(host.nowMs() / 1000) + 3600, at: 1 };
  try {
    adb.heard("ws/st", grant);
    const read = runner.run(adb.readGrants("ws/st"));
    await asked;
    adb.heard("ws/st", { ...grant, status: "ended" });
    let sent = false;
    const bytes = new TextEncoder().encode(JSON.stringify({ grants: [grant] }));
    answer({ status: 200, body: { take: Effect.sync(() => { if (sent) return null; sent = true; return bytes; }) } });
    await read;
    assert.deepEqual(adb.grants(), []);
  } finally {
    runner.shutdown();
  }
});

test("a request waiting asks this device to be approved first only where it is off its person's own lock, not where there is none yet", async () => {
  const host = new FakeHost();
  const runner = new Runner(host.time.clock);
  const store = new Store(host, runner);
  const mesh = { deviceId: () => "phone", link: () => Effect.never } as unknown as Mesh;
  let standing: "none" | "member" | "outside" | "replaced" = "none";
  const stub = personalStub();
  const personal = { ...stub.personal, standing: () => standing } as unknown as typeof stub.personal;
  const adb = new Adb({ ...stub, personal, host, runner, store, mesh: () => Effect.succeed(mesh), credentials: () => (() => Effect.succeed({} as never)), relays: () => [], lends: () => false });
  try {
    adb.heard("ws/st", { id: "p1", chat: "chat-a", session: "s1", reason: "debug", status: "pending", at: 1 });
    const joins = () => adb.grants().map((g) => g.join ?? false);
    // No lock yet: allowing it begins the lock (PersonalLock.signGrant), no step before it.
    assert.deepEqual(joins(), [false]);
    standing = "outside";
    assert.deepEqual(joins(), [true]);
    standing = "replaced";
    assert.deepEqual(joins(), [true]);
    standing = "member";
    assert.deepEqual(joins(), [false]);
  } finally {
    runner.shutdown();
  }
});

test("r15: ADB grants are owner-bound and isolated across workspace owner switch, in-flight readGrants, and decide", async () => {
  const host = new FakeHost();
  const runner = new Runner(host.time.clock);
  const store = new Store(host, runner);
  let owner = "acct-a";
  let decideCalls = 0;
  const readGate = Deferred.makeUnsafe<void>();
  const releaseRead = () => Deferred.doneUnsafe(readGate, Effect.void);
  const exp = Math.floor(host.nowMs() / 1000) + 3600;
  const link = {
    ask: (_head: unknown, { adb: ask }: { adb: { op: string; request?: string } }) =>
      ask.op === "grants"
        ? Effect.map(Deferred.await(readGate), () => {
            let sent = false;
            const bytes = new TextEncoder().encode(
              JSON.stringify({
                signs: true,
                grants: [{ id: "g-acct-a-late", chat: "chat-a", session: "s1", reason: "debug", status: "granted", exp, at: 2 }],
              }),
            );
            return { status: 200, body: { take: Effect.sync(() => { if (sent) return null; sent = true; return bytes; }) } };
          })
        : Effect.sync(() => {
            decideCalls++;
            let sent = false;
            const bytes = new TextEncoder().encode(JSON.stringify({ request: { id: ask.request, status: "granted", exp, at: 3 } }));
            return { status: 200, body: { take: Effect.sync(() => { if (sent) return null; sent = true; return bytes; }) } };
          }),
  };
  const mesh = { deviceId: () => "phone", link: () => Effect.succeed(link) } as unknown as Mesh;
  const stub = personalStub();
  let bumpDuringSign = false;
  const personal = {
    ...stub.personal,
    signGrant: () =>
      Effect.sync(() => {
        if (bumpDuringSign) {
          bumpDuringSign = false;
          owner = "acct-b";
          store.authGen.bumpWorkspace("ws");
        }
        return { body: {}, sig: {} };
      }),
  } as unknown as typeof stub.personal;
  const adb = new Adb({
    ...stub,
    personal,
    subOf: () => owner,
    subs: () => [{ sub: owner, email: `${owner}@x` }],
    host,
    runner,
    store,
    mesh: () => Effect.succeed(mesh),
    credentials: () => (() => Effect.succeed({} as never)),
    relays: () => [],
    lends: () => false,
  });
  takeAll(adb);
  try {
    // Seed grant under acct-a
    const genA = store.authGen.workspaceAuthGen("ws");
    adb.heard("ws/st", { id: "g-acct-a", chat: "chat-a", session: "s1", reason: "debug", status: "granted", exp, at: 1 }, genA, "acct-a");
    assert.deepEqual(adb.grants().map((g) => g.id), ["g-acct-a"]);

    // Start readGrants while owner is acct-a
    const readP = runner.run(adb.readGrants("ws/st"));
    await host.time.pass(10);
    // Switch workspace owner to acct-b and advance workspaceAuthGen while readGrants is in-flight
    owner = "acct-b";
    store.authGen.bumpWorkspace("ws");
    // Old acct-a cache must be pruned immediately on boundary
    assert.deepEqual(adb.grants(), [], "owner switch must immediately clear old owner's ADB grants");
    // Stale heard with old genA or old owner must be dropped
    adb.heard("ws/st", { id: "g-stale-event", chat: "chat-a", session: "s1", reason: "debug", status: "granted", exp, at: 4 }, genA, "acct-a");
    assert.deepEqual(adb.grants(), [], "stale-gen heard must be dropped");
    // Late readGrants response arrives -> must be discarded
    releaseRead();
    await readP;
    assert.deepEqual(adb.grants(), [], "late readGrants response from old owner/gen must never repopulate grants()");

    // In-flight decide: owner switches during #signed -> fails with auth_stale and issues 0 askAt("decide")
    owner = "acct-a";
    store.authGen.bumpWorkspace("ws");
    const genA2 = store.authGen.workspaceAuthGen("ws");
    adb.heard("ws/st", { id: "req-d1", chat: "chat-a", session: "s1", reason: "debug", status: "pending", at: 5 }, genA2, "acct-a");
    bumpDuringSign = true;
    await assert.rejects(
      () => runner.run(adb.run({ kind: "decide", station: "ws/st", request: "req-d1", scope: "hour" })),
      (e: { code?: string }) => e?.code === "auth_stale",
    );
    assert.equal(decideCalls, 0, "stale decide must issue 0 askAt calls");
    assert.deepEqual(adb.grants(), [], "grants under new owner acct-b must stay empty");
  } finally {
    runner.shutdown();
  }
});

test("r16: ADB rejects legacy unowned GRANTS_KEY array, never falls back to subs()[0], prunes same-owner boundary, and gates #revoke after signRevokes", async () => {
  const host = new FakeHost();
  const exp = Math.floor(host.nowMs() / 1000) + 3600;
  // 1. Pre-populate legacy unowned array in GRANTS_KEY -> must NOT be claimed by current account on startup
  host.store(GRANTS_KEY, {
    "ws/st": [{ id: "legacy-unowned", chat: "c1", session: "s1", reason: "debug", status: "granted", exp, at: 1 }],
  });
  host.appKeys = true;
  const runner = new Runner(host.time.clock);
  const store = new Store(host, runner);
  let owner: string | null = "acct-a";
  let revokeAskCount = 0;
  let bumpInSignRevokes = false;
  const link = {
    ask: (_head: unknown, { adb: ask }: { adb: { op: string; request?: string } }) =>
      Effect.sync(() => {
        if (ask.op === "revoke") revokeAskCount++;
        let sent = false;
        const body =
          ask.op === "grants"
            ? { signs: true, grants: [{ id: "g-fresh", chat: "c2", session: "s2", reason: "debug", status: "granted", exp, at: 2 }] }
            : { request: { id: ask.request, status: "ended" } };
        const bytes = new TextEncoder().encode(JSON.stringify(body));
        return { status: 200, body: { take: Effect.sync(() => { if (sent) return null; sent = true; return bytes; }) } };
      }),
  };
  const mesh = { deviceId: () => "phone", link: () => Effect.succeed(link) } as unknown as Mesh;
  const stub = personalStub();
  const personal = {
    ...stub.personal,
    signRevokes: () =>
      Effect.sync(() => {
        if (bumpInSignRevokes) {
          bumpInSignRevokes = false;
          store.authGen.bumpWorkspace("ws");
        }
        return [{ body: { station: "ws/st", request: "g-rev", exp }, sig: { key: "k", alg: "Ed25519", sig: "s" } }];
      }),
  } as unknown as typeof stub.personal;
  const adb = new Adb({
    ...stub,
    personal,
    subOf: () => owner,
    subs: () => [{ sub: "acct-a", email: "a@x" }],
    stationsOf: () => ["ws/st", "ws/relay"],
    host,
    runner,
    store,
    mesh: () => Effect.succeed(mesh),
    credentials: () => (() => Effect.succeed({} as never)),
    relays: () => [],
    lends: () => false,
  });
  takeAll(adb);
  try {
    await host.time.pass(50);
    assert.deepEqual(adb.grants(), [], "legacy unowned GRANTS_KEY array must be ignored on startup");

    // 2. Same-owner boundary prunes old-gen cached grant immediately and auto-refreshes via readGrants
    const gen1 = store.authGen.workspaceAuthGen("ws");
    adb.heard("ws/st", { id: "g-same-owner", chat: "c1", session: "s1", reason: "debug", status: "granted", exp, at: 1 }, gen1, "acct-a");
    assert.deepEqual(adb.grants().map((g) => g.id), ["g-same-owner"]);
    store.authGen.bumpWorkspace("ws");
    await host.time.pass(20);
    assert.equal(adb.grants().some((g) => g.id === "g-same-owner"), false, "same-owner workspaceAuthGen bump must immediately prune old-gen cached grants");
    assert.deepEqual(adb.grants().map((g) => g.id), ["g-fresh"], "same-owner boundary auto-refreshes grants under new gen");

    // 3. subOf("ws") becomes null while subs() still has acct-a -> never falls back to subs()[0]
    owner = null;
    store.authGen.bumpWorkspace("ws");
    assert.deepEqual(adb.grants(), [], "null workspace owner must never fall back to subs()[0]");

    // 4. #revoke: bumpWorkspace during signRevokes -> auth_stale, 0 #revoked mutations, 0 primary/relay askAt
    owner = "acct-a";
    store.authGen.bumpWorkspace("ws");
    const genRev = store.authGen.workspaceAuthGen("ws");
    adb.heard("ws/st", { id: "g-rev", chat: "c3", session: "s3", reason: "debug", status: "granted", exp, at: 3 }, genRev, "acct-a");
    revokeAskCount = 0;
    host.storage.delete(REVOKED_KEY);
    bumpInSignRevokes = true;
    await assert.rejects(
      () => runner.run(adb.run({ kind: "revoke", station: "ws/st", request: "g-rev" })),
      (e: { code?: string }) => e?.code === "auth_stale",
    );
    assert.equal(revokeAskCount, 0, "stale #revoke must issue 0 primary/relay revoke askAt calls");
    assert.equal(host.storage.has(REVOKED_KEY), false, "stale #revoke must not persist adb-revoked");
  } finally {
    runner.shutdown();
  }
});

test("r17: delayed cold-start GRANTS_KEY discards stale grants across boundary, and same-owner global boundary auto-refreshes", async () => {
  const host = new FakeHost();
  const exp = Math.floor(host.nowMs() / 1000) + 3600;
  host.store(GRANTS_KEY, {
    "ws/st": {
      sub: "acct-a",
      grants: [{ id: "g-persisted-stale", chat: "c1", session: "s1", reason: "debug", status: "granted", exp, at: 1 }],
    },
  });
  const loadGate = Deferred.makeUnsafe<void>();
  const origStorageGet = host.storageGet.bind(host);
  let gatedOnce = true;
  host.storageGet = (key) => {
    if (gatedOnce && key === GRANTS_KEY) {
      gatedOnce = false;
      return Effect.flatMap(Deferred.await(loadGate), () => origStorageGet(key));
    }
    return origStorageGet(key);
  };
  const runner = new Runner(host.time.clock);
  const store = new Store(host, runner);
  store.authGen.syncAccounts(["acct-a"]);
  let serverGrantId = "g-confirmed-1";
  let grantsReads = 0;
  let allowRead = false;
  const readGate = Deferred.makeUnsafe<void>();
  const link = {
    ask: (_head: unknown, { adb: ask }: { adb: { op: string } }) => {
      if (ask.op === "grants") {
        grantsReads++;
        const reply = () => {
          let sent = false;
          const bytes = new TextEncoder().encode(
            JSON.stringify({
              signs: true,
              grants: [{ id: serverGrantId, chat: "c2", session: "s2", reason: "debug", status: "granted", exp, at: 2 }],
            }),
          );
          return { status: 200, body: { take: Effect.sync(() => { if (sent) return null; sent = true; return bytes; }) } };
        };
        return allowRead ? Effect.sync(reply) : Effect.map(Deferred.await(readGate), reply);
      }
      return Effect.fail(new Error("unexpected"));
    },
  };
  const mesh = { deviceId: () => "phone", link: () => Effect.succeed(link) } as unknown as Mesh;
  const stub = personalStub();
  const adb = new Adb({
    ...stub,
    subOf: () => "acct-a",
    subs: () => [{ sub: "acct-a", email: "a@x" }],
    host,
    runner,
    store,
    mesh: () => Effect.succeed(mesh),
    credentials: () => (() => Effect.succeed({} as never)),
    relays: () => [],
    lends: () => false,
  });
  takeAll(adb);
  try {
    // 1. Astra P1: cross same-owner workspace boundary BEFORE delayed storageGet("adb.grants") resolves
    store.authGen.bumpWorkspace("ws");
    Deferred.doneUnsafe(loadGate, Effect.void);
    await host.time.pass(50);
    // Persisted stale grant must NOT be resurrected; automatic refresh is waiting on readGate
    assert.deepEqual(adb.grants(), [], "delayed GRANTS_KEY crossing boundary must never resurrect g-persisted-stale");
    assert.ok(grantsReads >= 1, "crossing boundary during cold-start load must trigger fresh readGrants");

    // Release fresh readGrants -> now new-gen grant appears
    allowRead = true;
    Deferred.doneUnsafe(readGate, Effect.void);
    await host.time.pass(50);
    assert.deepEqual(adb.grants().map((g) => g.id), ["g-confirmed-1"]);

    // 2. Opus P1: adding a 2nd account triggers global boundary -> same-owner station auto-refreshes without manual readGrants!
    serverGrantId = "g-confirmed-after-global";
    const readsBeforeGlobal = grantsReads;
    store.authGen.syncAccounts(["acct-a", "acct-b"]);
    await host.time.pass(50);
    assert.ok(grantsReads > readsBeforeGlobal, "same-owner global boundary must automatically trigger readGrants");
    assert.deepEqual(
      adb.grants().map((g) => g.id),
      ["g-confirmed-after-global"],
      "same-owner global boundary must automatically recover grants without manual intervention",
    );
  } finally {
    runner.shutdown();
  }
});

test("r18: overlapping same-owner boundaries coalesce refresh and never drop the final readGrants", async () => {
  const host = new FakeHost();
  const exp = Math.floor(host.nowMs() / 1000) + 3600;
  const runner = new Runner(host.time.clock);
  const store = new Store(host, runner);
  store.authGen.syncAccounts(["acct-a"]);
  const gate1 = Deferred.makeUnsafe<void>();
  const gate2 = Deferred.makeUnsafe<void>();
  let callNum = 0;
  const link = {
    ask: (_head: unknown, { adb: ask }: { adb: { op: string } }) => {
      if (ask.op !== "grants") return Effect.fail(new Error("unexpected"));
      const n = ++callNum;
      const gate = n === 1 ? gate1 : gate2;
      const id = n === 1 ? "g-from-stale-first-refresh" : "g-from-second-refresh";
      return Effect.map(Deferred.await(gate), () => {
        let sent = false;
        const bytes = new TextEncoder().encode(
          JSON.stringify({
            signs: true,
            grants: [{ id, chat: "c1", session: "s1", reason: "debug", status: "granted", exp, at: n }],
          }),
        );
        return { status: 200, body: { take: Effect.sync(() => { if (sent) return null; sent = true; return bytes; }) } };
      });
    },
  };
  const mesh = { deviceId: () => "phone", link: () => Effect.succeed(link) } as unknown as Mesh;
  const stub = personalStub();
  const adb = new Adb({
    ...stub,
    subOf: () => "acct-a",
    subs: () => [{ sub: "acct-a", email: "a@x" }],
    host,
    runner,
    store,
    mesh: () => Effect.succeed(mesh),
    credentials: () => (() => Effect.succeed({} as never)),
    relays: () => [],
    lends: () => false,
  });
  takeAll(adb);
  try {
    const gen0 = store.authGen.workspaceAuthGen("ws");
    adb.heard("ws/st", { id: "g-init", chat: "c1", session: "s1", reason: "debug", status: "granted", exp, at: 0 }, gen0, "acct-a");
    assert.deepEqual(adb.grants().map((g) => g.id), ["g-init"]);

    // Boundary 1: prunes g-init and starts refresh #1 (blocked on gate1)
    store.authGen.bumpWorkspace("ws");
    await host.time.pass(20);
    assert.deepEqual(adb.grants(), [], "boundary 1 must immediately hide old-gen grant");
    assert.equal(callNum, 1, "boundary 1 must start refresh #1");

    // Boundary 2 arrives WHILE refresh #1 is STILL in-flight!
    store.authGen.syncAccounts(["acct-a", "acct-b"]);
    await host.time.pass(20);
    // Release refresh #1 (now stale -> discarded) and refresh #2 (fresh -> populates grants!)
    Deferred.doneUnsafe(gate1, Effect.void);
    await host.time.pass(20);
    assert.equal(callNum, 2, "overlapping boundary 2 must coalesce and trigger refresh #2 once refresh #1 completes");
    assert.deepEqual(adb.grants(), [], "stale refresh #1 response must be discarded");
    Deferred.doneUnsafe(gate2, Effect.void);
    await host.time.pass(20);
    assert.deepEqual(
      adb.grants().map((g) => g.id),
      ["g-from-second-refresh"],
      "coalesced refresh #2 must automatically recover grants under latest gen without manual readGrants",
    );
  } finally {
    runner.shutdown();
  }
});
