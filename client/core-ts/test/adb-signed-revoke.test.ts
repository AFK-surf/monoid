// A grant of a person's phone taken back on another device of theirs, signed (personal-lock.ts `SignedRevoke`): their
// phone ends it as soon as any station of theirs tells it, though the grant's own station never says it ended.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect } from "effect";
import { Adb, type AdbEnv } from "../src/adb.ts";
import { CoreError, HostError } from "../src/error.ts";
import type { Mesh } from "../src/mesh.ts";
import { PersonalLock, revokeHolds } from "../src/personal-lock.ts";
import { Runner } from "../src/runtime.ts";
import { Store } from "../src/store.ts";
import { FakeHost, flush } from "../src/testing.ts";
import { utf8 } from "../src/util.ts";
import type { Entry } from "../src/lock.ts";
import { personalStub } from "./adb-personal-stub.ts";

// deno-lint-ignore no-explicit-any
type J = any;

const SUB = "s1";
const ST1 = "ws/st1";
const ST2 = "ws/st2";

/// A cloud that keeps one chain, as cloud/src/personal-lock.ts does.
function cloud() {
  const kept = { entries: [] as Entry[] };
  return (_sub: string, method: string, _path: string, body: unknown) => Effect.sync(() => {
    if (method === "GET") return { entries: kept.entries };
    const adding = (body as { entries: Entry[] }).entries;
    kept.entries = adding[0]!.seq === 0 ? adding : [...kept.entries.slice(0, adding[0]!.seq), ...adding];
    return { entries: kept.entries };
  }) as Effect.Effect<unknown, CoreError>;
}

/// A device of the person's with a key of its own, each read of what is sealed counted as asking them.
function signer(name: string, host = new FakeHost()) {
  const id = name.charCodeAt(0).toString(16).repeat(32);
  host.appKeys = true;
  host.randomBytes = (b: Uint8Array) => void b.fill(name.charCodeAt(0));
  const sealed = new Map<string, Uint8Array>();
  const asks = { n: 0, refuse: false };
  host.secureSet = (key: string, value: Uint8Array) => Effect.sync(() => void sealed.set(key, value));
  host.secureGet = (key: string, opts: { user: boolean; reason?: string }) => {
    if (opts.user) asks.n++;
    return asks.refuse ? Effect.fail(new HostError("user_cancelled")) : Effect.succeed(sealed.get(key) ?? null);
  };
  host.secureAsk = () => Effect.sync(() => void asks.n++);
  const runner = new Runner(host.time.clock);
  const lock = new PersonalLock({ host, runner, cloud: cloud(), device: () => Effect.succeed(id), label: () => name, changed: () => {}, signKey: () => null });
  return { host, runner, lock, asks };
}

/// A station of the person's as the core sees it: an honest one ends a grant taken back and keeps (and tells) what was
/// signed for it; a liar goes on saying the grant is live and drops what it is brought; one down answers nothing.
type Sim = { mode: "honest" | "liar" | "down"; grants: Map<string, J>; revokes: J[]; asked: J[]; tell?: (signed: J) => void };
const sim = (mode: Sim["mode"]): Sim => ({ mode, grants: new Map(), revokes: [], asked: [] });

function meshOf(stations: Map<string, Sim>): () => Effect.Effect<Mesh, CoreError> {
  const reply = (status: number, body: unknown) => {
    let sent = false;
    const bytes = utf8(JSON.stringify(body));
    return { status, cancel: () => {}, body: { take: Effect.sync(() => (sent ? null : ((sent = true), bytes))) } };
  };
  const link = (addr: string) => ({
    ask: (_head: unknown, { adb: ask }: { adb: J }) => Effect.sync(() => {
      const s = stations.get(addr)!;
      s.asked.push(ask);
      if (ask.op === "grants") return reply(200, { grants: [...s.grants.values()], revokes: s.revokes, signs: true });
      if (ask.op === "revoke" && ask.relay === true) {
        if (s.mode === "honest") {
          s.revokes.push(ask.signed);
          s.tell?.(ask.signed);
        }
        return reply(200, { ok: true });
      }
      if (ask.op === "revoke") {
        const g = s.grants.get(ask.request);
        if (s.mode === "liar") return reply(200, { request: g ?? null });
        if (ask.signed !== undefined) s.revokes.push(ask.signed), s.tell?.(ask.signed);
        s.grants.delete(ask.request);
        return reply(200, { request: g === undefined ? null : { ...g, status: "ended" } });
      }
      return reply(404, { message: "no such op" });
    }),
  });
  const mesh = {
    deviceId: () => "device",
    link: (addr: string) => stations.get(addr)?.mode === "down" ? Effect.fail(new CoreError("mesh", "the station is not reached")) : Effect.succeed(link(addr)),
  } as unknown as Mesh;
  return () => Effect.succeed(mesh);
}

function adbOf(host: FakeHost, runner: Runner, stations: Map<string, Sim>, personal: AdbEnv["personal"]) {
  const stub = personalStub();
  return new Adb({
    ...stub, personal, subOf: () => SUB, subs: () => [{ sub: SUB, email: "p@x" }], host, runner, store: new Store(host, runner),
    mesh: meshOf(stations), credentials: () => (() => Effect.succeed({} as never)), relays: () => [], lends: () => false,
    stationsOf: () => [...stations.keys()],
  });
}

/// The person's laptop (on their lock, signing) and phone (pinned the same lock, lending), and two stations of theirs.
async function world(st1: Sim["mode"] = "liar") {
  const laptop = signer("b");
  const stations = new Map([[ST1, sim(st1)], [ST2, sim("honest")]]);
  const now = Math.floor(laptop.host.nowMs() / 1000);
  const exp = now + 3600;
  // (the lock begun on the laptop by its first signature: the grant the phone lends for)
  const grantBody = { station: ST1, request: "p1", session: "sess", chat: "chat-a", scope: "hour" as const, exp };
  const signed = await laptop.runner.run(laptop.lock.signGrant(SUB, grantBody, "why"));
  const grant = { id: "p1", session: "sess", chat: "chat-a", scope: "hour", reason: "debug", status: "granted", exp, at: 1, signed };
  stations.get(ST1)!.grants.set("p1", grant);
  const laptopAdb = adbOf(laptop.host, laptop.runner, stations, laptop.lock);
  laptopAdb.heard(ST1, grant);
  const phoneHost = new FakeHost();
  const phoneRunner = new Runner(phoneHost.time.clock);
  // (both hosts' clocks start at the same fixed moment)
  assert.equal(phoneHost.nowMs(), laptop.host.nowMs());
  const phonePersonal = { ...personalStub().personal, chain: () => laptop.lock.chain(SUB) } as unknown as AdbEnv["personal"];
  const phone = adbOf(phoneHost, phoneRunner, stations, phonePersonal);
  // (its stream from the honest station: what it tells of, the phone hears)
  stations.get(ST2)!.tell = (s) => phone.heardRevoke(ST2, s);
  phone.heard(ST1, grant);
  return { laptop, laptopAdb, phone, phoneHost, phoneRunner, phonePersonal, stations, grant, exp, now };
}

/// The relays forked as the call answered, run.
const relayed = (_w: Awaited<ReturnType<typeof world>>) => Effect.promise(() => flush());

test("a taking back holds only as signed for it, by a key on the lock, in its time, for this person, under its own tag", async () => {
  const a = signer("a");
  const b = signer("c");
  try {
    const now = Math.floor(a.host.nowMs() / 1000);
    const body = { station: ST1, request: "p1", exp: now + 3600 };
    // (the lock begun by a first signature)
    await a.runner.run(a.lock.signGrant(SUB, { ...body, session: "s", chat: "c", scope: "hour" }, "why"));
    const asked = a.asks.n;
    const [signed] = await a.runner.run(a.lock.signRevokes(SUB, [body], "why"));
    assert.equal(a.asks.n, asked + 1, "asked once");
    assert.deepEqual(await a.runner.run(a.lock.signRevokes(SUB, [], "why")), [], "nothing to sign: nobody asked");
    assert.equal(a.asks.n, asked + 1);
    const two = await a.runner.run(a.lock.signRevokes(SUB, [body, { ...body, request: "p2" }], "why"));
    assert.equal(two.length, 2);
    assert.equal(a.asks.n, asked + 2, "two grants of one chat: asked once");
    const { devices } = a.lock.chain(SUB)!;
    const holds = (s: unknown, sub = SUB, at = now) => revokeHolds(s, sub, devices, at);
    assert.deepEqual(holds(signed), { v: 1, sub: SUB, ...body });
    const tampered = (over: Record<string, unknown>) => ({ ...signed!, body: { ...signed!.body, ...over } });
    assert.equal(holds(tampered({ request: "p2" })), null, "another request");
    assert.equal(holds(tampered({ station: "ws/other" })), null, "another station");
    assert.equal(holds(tampered({ sub: "s2" })), null, "another person's, said");
    assert.equal(holds(signed, "s2"), null, "another person's, asked");
    assert.equal(holds(tampered({ exp: now + 7200 })), null, "its end moved");
    assert.equal(holds(signed, SUB, now + 3600), null, "past its time");
    assert.equal(holds({ body: signed!.body }), null, "no signature");
    assert.equal(holds(null), null);
    // A key off the lock (another lock's device, or one taken off it).
    await b.runner.run(b.lock.signGrant(SUB, { ...body, session: "s", chat: "c", scope: "hour" }, "why"));
    const [stranger] = await b.runner.run(b.lock.signRevokes(SUB, [body], "why"));
    assert.equal(holds(stranger), null, "a key off the lock");
    assert.equal(revokeHolds(signed, SUB, new Map(), now), null, "its key taken off the lock");
    // A grant's signature over the same body is not a taking back's (and the other way round).
    const asGrant = await a.runner.run(a.lock.signGrant(SUB, body as never, "why"));
    assert.deepEqual(asGrant.body, signed!.body, "the same body");
    assert.equal(holds(asGrant), null, "signed under the grant's tag");
  } finally {
    a.runner.shutdown();
    b.runner.shutdown();
  }
});

test("a station that drops a taking back lends the phone no longer: another station of theirs tells it, and a phone started anew does not lend again", async () => {
  const w = await world();
  try {
    assert.deepEqual(w.phone.wanted(), [ST1]);
    await w.laptop.runner.run(w.laptopAdb.run({ kind: "revoke", station: ST1, request: "p1" }));
    await w.laptop.runner.run(relayed(w));
    // The liar was asked with the signature, and goes on saying the grant is live.
    const st1 = w.stations.get(ST1)!;
    assert.ok(st1.asked.some((a) => a.op === "revoke" && a.request === "p1" && a.signed?.body?.request === "p1" && a.relay === undefined));
    assert.equal(st1.grants.get("p1").status, "granted");
    // The honest one kept it and told the phone, which stops lending at once.
    assert.equal(w.stations.get(ST2)!.revokes.length, 1);
    assert.deepEqual(w.phone.wanted(), []);
    assert.deepEqual(w.phone.grants(), [], "not shown as live either");
    // The liar read again says it live: still not lent.
    await w.phoneRunner.run(w.phone.readGrants(ST1));
    assert.deepEqual(w.phone.wanted(), []);
    // Started anew (what it took back kept on the device), the liar read first: not lent.
    const again = adbOf(w.phoneHost, w.phoneRunner, w.stations, w.phonePersonal);
    await flush();
    again.heard(ST1, w.grant);
    await w.phoneRunner.run(again.readGrants(ST1));
    assert.deepEqual(again.wanted(), []);
    // On the laptop, the row is gone though the liar says it live.
    assert.deepEqual(w.laptopAdb.grants(), []);
  } finally {
    w.laptop.runner.shutdown();
    w.phoneRunner.shutdown();
  }
});

test("a phone away as the grant was taken back hears of it from any station of theirs as it reads it again", async () => {
  const w = await world();
  try {
    w.stations.get(ST2)!.tell = undefined;
    await w.laptop.runner.run(w.laptopAdb.run({ kind: "revoke", station: ST1, request: "p1" }));
    await w.laptop.runner.run(relayed(w));
    assert.deepEqual(w.phone.wanted(), [ST1], "not told: still lent");
    await w.phoneRunner.run(w.phone.readGrants(ST2));
    assert.deepEqual(w.phone.wanted(), []);
  } finally {
    w.laptop.runner.shutdown();
    w.phoneRunner.shutdown();
  }
});

test("its own station out of reach, a grant is taken back where another station of theirs keeps what was signed; none, it fails", async () => {
  const w = await world("down");
  try {
    await w.laptop.runner.run(w.laptopAdb.run({ kind: "revoke", station: ST1, request: "p1" }));
    assert.equal(w.stations.get(ST2)!.revokes.length, 1);
    assert.deepEqual(w.phone.wanted(), []);
  } finally {
    w.laptop.runner.shutdown();
    w.phoneRunner.shutdown();
  }
  const v = await world("down");
  try {
    v.stations.get(ST2)!.mode = "down";
    const r = await v.laptop.runner.run(Effect.result(v.laptopAdb.run({ kind: "revoke", station: ST1, request: "p1" })));
    assert.equal(r._tag, "Failure");
  } finally {
    v.laptop.runner.shutdown();
    v.phoneRunner.shutdown();
  }
});

test("what a station makes up is not a taking back: unsigned, signed by a key off the lock, or a grant's signature", async () => {
  const w = await world();
  const other = signer("z");
  try {
    const body = { station: ST1, request: "p1", exp: w.exp };
    w.phone.heardRevoke(ST2, { body: { v: 1, sub: SUB, ...body } });
    w.phone.heardRevoke(ST2, { body: { v: 1, sub: SUB, ...body }, sig: { key: "ed25519:00", sig: "00" } });
    await other.runner.run(other.lock.signGrant(SUB, { ...body, session: "s", chat: "c", scope: "hour" }, "why"));
    const [forged] = await other.runner.run(other.lock.signRevokes(SUB, [body], "why"));
    w.phone.heardRevoke(ST2, forged);
    const asGrant = await w.laptop.runner.run(w.laptop.lock.signGrant(SUB, body as never, "why"));
    w.phone.heardRevoke(ST2, asGrant);
    // (the lock changing does not make any of them hold)
    w.phone.touched();
    assert.deepEqual(w.phone.wanted(), [ST1]);
    await w.phoneRunner.run(w.phone.readGrants(ST1));
    assert.deepEqual(w.phone.wanted(), [ST1]);
  } finally {
    other.runner.shutdown();
    w.laptop.runner.shutdown();
    w.phoneRunner.shutdown();
  }
});

test("one heard before the lock is read here is checked once it is", async () => {
  const w = await world();
  let chain: ReturnType<PersonalLock["chain"]> = null;
  const personal = { ...w.phonePersonal, chain: () => chain } as unknown as AdbEnv["personal"];
  const phone = adbOf(w.phoneHost, w.phoneRunner, w.stations, personal);
  try {
    const [signed] = await w.laptop.runner.run(w.laptop.lock.signRevokes(SUB, [{ station: ST1, request: "p1", exp: w.exp }], "why"));
    phone.heard(ST1, w.grant);
    phone.heardRevoke(ST2, signed);
    chain = w.laptop.lock.chain(SUB);
    assert.deepEqual(phone.wanted(), [ST1], "unchecked: nothing taken back yet");
    phone.touched();
    assert.deepEqual(phone.wanted(), []);
  } finally {
    w.laptop.runner.shutdown();
    w.phoneRunner.shutdown();
  }
});

test("the person turning the prompt down takes nothing back; a request waiting is taken back with nobody asked", async () => {
  const w = await world();
  try {
    w.laptop.asks.refuse = true;
    const r = await w.laptop.runner.run(Effect.result(w.laptopAdb.run({ kind: "revoke", station: ST1, request: "p1" })));
    assert.equal(r._tag, "Failure");
    if (r._tag === "Failure") assert.equal(r.failure.code, "user_cancelled");
    assert.deepEqual(w.laptopAdb.grants().map((g) => g.id), ["p1"], "still shown, not taken back here");
    assert.equal(w.stations.get(ST1)!.asked.filter((a) => a.op === "revoke").length, 0, "nothing unsigned sent");
    assert.equal(w.stations.get(ST2)!.asked.length, 0);
    // A request waiting: no signature, nobody asked.
    w.laptop.asks.refuse = false;
    const asked = w.laptop.asks.n;
    w.stations.get(ST1)!.mode = "honest";
    w.laptopAdb.heard(ST1, { id: "q1", session: "s2", chat: "chat-b", reason: "debug", status: "pending", at: 2 });
    await w.laptop.runner.run(w.laptopAdb.run({ kind: "revoke", station: ST1, request: "q1" }));
    assert.equal(w.laptop.asks.n, asked);
    const sent = w.stations.get(ST1)!.asked.filter((a) => a.op === "revoke");
    assert.deepEqual(sent.map((a) => [a.request, a.signed]), [["q1", undefined]]);
    assert.equal(w.stations.get(ST2)!.asked.length, 0);
  } finally {
    w.laptop.runner.shutdown();
    w.phoneRunner.shutdown();
  }
});

test("a station that says a grant ends sooner than signed has no taking back signed that ends before the grant does", async () => {
  const w = await world();
  try {
    const signs: { exp: number }[] = [];
    const lock = w.laptop.lock;
    const signRevokes = lock.signRevokes.bind(lock);
    lock.signRevokes = ((sub, bodies, reason, station) => {
      for (const b of bodies) signs.push({ exp: b.exp });
      return signRevokes(sub, bodies, reason, station);
    }) as typeof lock.signRevokes;
    // Signed for an hour, said to end in five seconds: the signed end holds.
    w.laptopAdb.heard(ST1, { ...w.grant, exp: w.now + 5 });
    await w.laptop.runner.run(w.laptopAdb.run({ kind: "revoke", station: ST1, request: "p1" }));
    assert.deepEqual(signs, [{ exp: w.exp }]);
    // Its signature stripped (or forged), said to end in five seconds: the longest a grant lasts.
    w.laptopAdb.heard(ST1, { ...w.grant, id: "p2", chat: "chat-b", exp: w.now + 5, signed: undefined });
    w.laptopAdb.heard(ST1, { ...w.grant, id: "p3", chat: "chat-c", exp: w.now + 5, signed: { ...w.grant.signed, sig: { ...w.grant.signed.sig, sig: "00" } } });
    await w.laptop.runner.run(w.laptopAdb.run({ kind: "revoke", station: ST1, request: "p2" }));
    await w.laptop.runner.run(w.laptopAdb.run({ kind: "revoke", station: ST1, request: "p3" }));
    assert.equal(signs.length, 3);
    for (const s of signs.slice(1)) assert.ok(s.exp >= w.now + 30 * 86400, `${s.exp}`);
  } finally {
    w.laptop.runner.shutdown();
    w.phoneRunner.shutdown();
  }
});
