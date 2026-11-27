import assert from "node:assert/strict";
import { test } from "node:test";
import { Deferred, Effect } from "effect";
import { Adb } from "../src/adb.ts";
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
