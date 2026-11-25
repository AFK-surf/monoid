// A device a moved workspace's list does not name, end to end on a core whose station is the station's own code
// (station/src/cloud/state.ts `Cloud`; its hello's admission and refusal, mesh/serve.ts `inLockBringing`, `refusalOf`;
// its routes `lockRoute`, `lockPartRoute`): the station gives it nothing but the chain (the cloud's copy) and its
// refusal, which says it is left out and whom to ask (`left`). The device shows what it shows before a move where it
// is not confirmed (able to ask, its try's `pair`), dials those it was told to, and once let in reads the logs and
// bodies as any device of the list (2026-11-14: such a device sat `waiting` for good on real stations).
//
// The world: `ws`, its chain alice's (r1, the owner; bob r2 an admin) then a `moved` to alice's own log, which says
// the settings, bob and station A (and, `named`, s1 a member by the log of s1's app X). This core is s1's: a new app
// or web page (`base`) no log binds.
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Effect } from "effect";
import { entryHash as stationHash } from "../../../shared/lock.ts";
import { Log, dev, ed, signed, viewerOf } from "../../../station/test/lock-moved-world.ts";
import { hooks } from "../src/core/execute.ts";
import { CoreError } from "../src/error.ts";
import { type Entry, Signer } from "../src/lock.ts";
import { pairSession, pakeKeys, pakeStart } from "../src/pair.ts";
import { httpError } from "../src/station/requests.ts";
import { hex } from "../src/util.ts";
import { held, inForceOf, leftIn, needsAppIn, read, refusedAgain, reopenedIn, safeMode, signerKnown } from "../src/views/lock.ts";
import { dialer } from "../src/views/pair.ts";
import { MbLockStation } from "./mb-lock-station.ts";
import { grant, pipe, rig } from "./lock-rig.ts";
import { stationReplies } from "./station-fixture.ts";

const unhex = (h: string) => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
/// The code the trusted devices here show (as typed on the new device).
const CODE = "246810";
/// How long the page `webOnly` puts on the chain runs, in days.
const WEB_DAYS = 10;
type J = any;
/// What a trusted device answers once the code is confirmed (it signs what lets the new one in first), by its base id.
type Approver = { where: (hello: J) => string[]; approve: (hello: J) => J | Promise<J> };

/// `named`: s1 a member by X's log (`noApp`: a log no station was given, so naming no app of s1's). `web`: this core a
/// web page. `waiting`: the station given no root's log. `older`: a station from before its refusal said `apps`.
/// `carried`: s1 a member the chain names with X as an app of theirs, bound to no log, no log of theirs anywhere (the
/// state carries them by the chain alone).
/// `rootLost`: s1 the root's person, its log (x's) the root, every device of it lost; r1 an owner by its admit; this
/// core s1's new app.
/// `webOnly`: s1 a member the chain names with this web page alone (no app, no log of theirs anywhere), put on the chain
/// by alice's app before the move with ten days to run (`WEB_DAYS`): the state carries it by the chain until its `exp`.
async function setUp(o: { named?: boolean; noApp?: boolean; web?: boolean; waiting?: boolean; older?: boolean; personHeld?: boolean; carried?: boolean; unread?: boolean; rootLost?: boolean; webOnly?: boolean } = {}) {
  const g = grant();
  const settings = { origins: ["https://stillfail.test"], rp_id: "stillfail.test", cloud_keys: g.keys };
  const alice = new Log("r1"), bob = new Log("r2"), x = new Log("s1");
  const A = ed().hex, base = ed();
  const root = o.rootLost ? x : alice;
  root.say("open", { ...settings, email: `${root.sub}@x.com` }, "ws");
  if (o.rootLost) x.say("member", { sub: "r1", email: "r1@x.com", lock: alice.genesis, role: "owner" }, "ws");
  root.say("member", { sub: "r2", email: "r2@x.com", lock: bob.genesis, role: "admin" }, "ws");
  root.say("station", { key: A }, "ws");
  if (o.named) alice.say("member", { sub: "s1", email: "s1@x.com", lock: x.genesis, role: "member" }, "ws");
  const app = (l: Log) => ({ id: l.app.base.hex, sub: l.sub, kind: "app", label: `${l.sub}'s app`, sign_key: l.app.signer.id });
  const body = {
    owner: root.sub, ...settings, passkeys: [], stations: [{ key: A, name: "a" }], gateways: [],
    members: [{ sub: "r1", email: "r1@x.com", role: "owner" }, { sub: "r2", email: "r2@x.com", role: "admin" }, ...(o.named || o.carried || o.rootLost || o.webOnly ? [{ sub: "s1", email: "s1@x.com", role: o.rootLost ? "owner" : "member" }] : [])],
    devices: [app(alice), app(bob), ...(o.named || o.carried || o.rootLost ? [app(x)] : [])],
  };
  const first = signed({ v: 1, ws: "ws", seq: 0, prev: null, at: 1000, kind: "genesis", body }, root.app.signer);
  // (`webOnly`: the page approved on the chain at the rig's first moment, FakeHost's start)
  const START = Date.UTC(2026, 9, 6, 9, 0, 0) / 1000;
  const onChain = o.webOnly ? [signed({ v: 1, ws: "ws", seq: 1, prev: stationHash(first), at: START, kind: "device", body: { id: base.hex, sub: "s1", kind: "web", label: "s1's browser", exp: START + WEB_DAYS * 86400 } }, root.app.signer)] : [];
  const before = [first, ...onChain];
  const moved = signed({ v: 1, ws: "ws", seq: before.length, prev: stationHash(before.at(-1)!), at: Math.max(1000, before.at(-1)!.at), kind: "moved", body: { root: root.genesis } }, root.app.signer);
  const r = await rig(() => ({ ws: first as unknown as Entry }), (host) => {
    if (o.web) host.appKeys = false;
  }, [A], [A], undefined, [], { role: o.rootLost ? "owner" : "member", ...(o.unread ? { lock: null } : {}) });
  const clock = () => r.host.nowMs();
  // (the cloud's copy of a person's own lock, for the devices from before: it keeps none of s1's)
  // (`unread`: it keeps s1's, as it does for an app from before, read before any station answered)
  stationReplies(r.host, (req) => (req.url.endsWith("/v1/me/personal-lock") ? (req.method === "GET" ? { entries: o.unread ? x.entries : [] } : { ok: true }) : r.cloud.reply(req)));
  // (`unread`: the cloud's copy not moved yet either, so no read of it holds the chain as it moved)
  r.cloud.chains.set("ws", (o.unread ? before : [...before, moved]) as unknown as Entry[]);
  const inner = r.core.inner;
  // (`rootLost`: an app new on this machine, with no signer yet until it asks to be let in, as a newcomer's)
  if (o.rootLost) {
    await Effect.runPromise(Effect.ignore(inner.host.secureDelete?.(Signer.KEY) ?? Effect.void));
    await Effect.runPromise(Effect.ignore(inner.host.storageDelete(Signer.KEY)));
    signerKnown(inner, null);
  }
  inner.mesh = () => Effect.succeed({ deviceId: () => base.hex, sign: () => ({ publicKey: new Uint8Array(32), signature: new Uint8Array(64) }), link: () => Effect.fail(CoreError.plainly("mesh", "no station link here")) } as never);
  inner.cloudSync.credential = () => Effect.succeed({ credential: "signed-member", issued_at: 1000, expires_at: 4102444800, relay_url: "https://relay.example" });
  // Station A: the station's own code, the chain pinned and moved, the logs and bodies its members' devices gave it.
  const data = mkdtempSync(join(tmpdir(), "lock-left-out-"));
  const c = await MbLockStation.create(data, { origin: "https://stillfail.test", station: A, workspace: "ws", workspace_name: "W", name: "a", relay_url: "", relay_urls: [], grant_keys: g.keys, peers: [{ id: A, name: "a" }], revocations: [] }, clock);
  await c.takeLock(before);
  await c.takeLock([...before, moved], null, true);
  // (as each member's app device brings them, POST /lock/person)
  const bring = async (l: Log) => {
    await c.bring(l, true, "ws");
  };
  for (const l of o.waiting ? [bob] : (o.named && !o.noApp) || o.rootLost ? [alice, bob, x] : [alice, bob]) await bring(l);
  const viewer = viewerOf("s1", { base }, o.rootLost ? "owner" : "member", "ws");
  /// What the station does to each of its asks: `lie`, a device its refusals name to ask in place of those it would.
  /// `down`: (`downs`, `rootLost`'s) its link refused and not dialled again yet: asks fail as a link waiting does, no
  /// hello made, until it is dialled again (`hello()` of the test, or as it comes online).
  const st = { lie: null as string | null, refusals: [] as J[], admitted: 0, asked: [] as string[], down: false, personHeld: o.personHeld === true || o.unread === true, personUntold: o.personHeld === true, lockUnread: o.unread === true, ownUnsaid: false, downs: o.rootLost === true };
  /// The link's hello to A, as the station answers it: null where it lets this device in; else its refusal, told the
  /// core as the mesh wire tells it (station/mesh-wire.ts `refusedFor`).
  const hello = async (): Promise<CoreError | null> => {
    const own = inner.adb.personal().entries("s1");
    const said = { lock: { device: base.hex, proof: viewer.lockDevice.proof, ...(own.length > 0 && !st.ownUnsaid ? { person: own } : {}) } };
    const res = await c.inLockBringing({ viewer, exp: 4102444800, iat: 0, sid: "" }, "member", viewer.device, said, "s1");
    if (!res.ok) {
      const refusal = res.body as J;
      if (st.lie !== null && refusal.left !== undefined) refusal.left = { approvers: [st.lie] };
      if (o.older && refusal.left !== undefined) delete refusal.left.apps;
      // (its own lock not heard of here yet: the refusals before the test's own say nothing of it)
      if (st.personUntold) delete refusal.person;
      st.refusals.push(refusal);
      st.down = st.downs;
      return hooks.lockRefused?.(inner, "ws", A, refusal.lock, refusal) ?? new CoreError("lock_unconfirmed", res.message);
    }
    st.admitted++;
    st.down = false;
    return null;
  };
  // A station tried again (views/lock.ts `refusedAgain`): its link dials it, and once let in the lock is read as a link
  // that opens reads it.
  const cameOnline = inner.stations.cameOnline.bind(inner.stations);
  inner.stations.cameOnline = (address: string) => {
    cameOnline(address);
    if (address === `ws/${A}`) inner.runner.fork(Effect.gen(function* () {
      if ((yield* Effect.promise(() => hello())) === null) yield* Effect.ignore(read(inner, "ws"));
    }));
  };
  const original = inner.stations.requests.call.bind(inner.stations.requests);
  const answer = (addr: { toString(): string }, method: string, path: string, body: unknown, ...rest: unknown[]): Effect.Effect<unknown, CoreError> => Effect.gen(function* () {
    const [ws, id] = addr.toString().split("/");
    if (id !== A || !path.startsWith("/lock")) return yield* (original as (...x: unknown[]) => Effect.Effect<unknown, CoreError>)(addr, method, path, body, ...rest);
    if (ws !== "ws") return yield* Effect.fail(httpError(404, { error: "no route" }));
    // (its person's own lock not read yet: not answered, until the test lets it be)
    if (st.personHeld && method === "GET" && path === "/lock/person") return yield* Effect.fail(new CoreError("station_offline", "not reached"));
    // (`ownUnsaid`: a lock of this device's own never taken by the station)
    if (st.ownUnsaid && method === "POST" && path === "/lock/person") return yield* Effect.fail(new CoreError("station_offline", "not reached"));
    // (the workspace's lock not read of it yet: its links opened first)
    if (st.lockUnread && method === "GET" && (path === "/lock" || path.startsWith("/lock?") || path === "/lock/logs" || path === "/lock/bodies")) return yield* Effect.fail(new CoreError("station_offline", "not reached"));
    // (its link's hello first: a station that refused this device is not dialled again until told to, as the mesh does)
    const waits = hooks.lockWaiting?.(inner, ws, A) ?? null;
    if (waits !== null) return yield* Effect.fail(waits);
    // (`rootLost`: a link refused is down until dialled again, as the mesh's is: its asks fail meanwhile, no hello made)
    if (st.down) return yield* Effect.fail(new CoreError("station_offline", "its link refused, not dialled again yet"));
    st.asked.push(`${method} ${path}`);
    const no = yield* Effect.promise(() => hello());
    if (no !== null) return yield* Effect.fail(no);
    const [p, q] = path.split("?") as [string, string | undefined];
    const text = body === null || body === undefined ? "" : JSON.stringify(body);
    const [status, out] = yield* Effect.promise(() =>
      p === "/lock" ? c.lockRoute(method, q ? [...new URLSearchParams(q)] : [], text, viewer) : c.lockPartRoute(p.slice("/lock/".length), method, text, viewer),
    );
    return status === 200 ? out : yield* Effect.fail(httpError(status, out));
  });
  inner.stations.requests.call = answer as typeof inner.stations.requests.call;
  // The trusted devices it dials: each it knows answers as a device on the lock does (a code, the exchange, what it
  // signs, then `approved`); any other, that it approves nothing here.
  const approvers = new Map<string, Approver>();
  const dialled: string[] = [];
  /// The relays each dial went through, in the order dialled.
  const via: string[][] = [];
  dialer.open = (_inner, id, relays) => Effect.flatMap(Effect.promise(() => pipe()), ([here, there]) => Effect.sync(() => {
    dialled.push(id);
    via.push(relays);
    inner.runner.fork(Effect.gen(function* () {
      const hello = (yield* there.next()) as J;
      const a = approvers.get(id);
      if (a === undefined) return yield* there.send({ t: "no", error: "not_here" });
      const where = a.where(hello);
      // (one that would sign nothing for it shows no code, as views/pair.ts `serveTrusted` answers)
      if (where.length === 0) return yield* there.send({ t: "no", error: "not_here" });
      yield* there.send({ t: "code", workspaces: where });
      const m = (yield* there.next()) as J;
      const p = pakeStart(CODE, pairSession(base.hex, id, where), (b) => b.fill(5));
      const keys = pakeKeys(p, unhex(m.y), "trusted")!;
      yield* there.send({ t: "pake", y: hex(p.share), mac: hex(keys.mine) });
      yield* there.next();
      yield* there.send(yield* Effect.promise(() => Promise.resolve(a.approve(hello))));
    }));
    return here;
  }));
  const run = async <X>(e: Effect.Effect<X, any>): Promise<{ ok?: X; error?: CoreError }> => {
    let out: { ok?: X; error?: CoreError } | null = null;
    inner.runner.fork(Effect.match(e, { onSuccess: (ok) => void (out = { ok }), onFailure: (error) => void (out = { error }) }));
    await r.host.time.passUntil(30_000, () => out !== null);
    assert.ok(out !== null, "no answer");
    await r.host.time.pass(100);
    return out;
  };
  const ask = (name: string, params: Record<string, unknown>) => run(Effect.tryPromise({ try: () => r.ask(name, params), catch: (e) => e as CoreError }));
  // (`unread`: the workspace's lock not read yet, as an app just signed in whose links opened first)
  if (!o.unread) {
    await run(read(inner, "ws"));
    assert.equal(held(inner, "ws")?.entries.at(-1)?.kind, "moved", "the chain held moved");
  }
  const lock = await r.watch({ topic: "lock", workspace: "ws" });
  /// The page as it stands once what was set going settled.
  const page = async () => {
    await r.host.time.pass(2_000);
    return (await lock()) as J;
  };
  const now = () => Math.floor(r.host.nowMs() / 1000);
  /// What a failure says of where it got: the station's refusals and admissions, the page.
  const why = () => `refused ${st.refusals.length}, last left ${JSON.stringify(st.refusals.at(-1)?.left)?.slice(0, 30)} error ${String(st.refusals.at(-1)?.error).slice(0, 80)}; admitted ${st.admitted}; standing ${inner.adb.personal().standing("s1")}`;
  return { why, r, inner, c, st, alice, bob, x, base, A, approvers, dialled, via, run, ask, page, bring, now, hello, moved, settings };
}

/// What a removal of `sub` said in `l`'s log cancels: the statements of it that admitted them (lock-statements.ts
/// `cancelsOf`).
const admitsOf = (l: Log, sub: string) => [...l.bodies].filter(([, b]) => b.kind === "member" && b.sub === sub).map(([h]) => h).sort();

/// Asks counted by what they are, in the order first made.
const summary = (asked: string[]) => [...asked.reduce((m, a) => m.set(a, (m.get(a) ?? 0) + 1), new Map<string, number>())].map(([a, n]) => `${a} ×${n}`).join(", ");

/// Whom the page lists: each member's sub.
const subs = (v: J) => (v.members as J[]).map((m) => m.sub).sort().join(",");

test("a newcomer's first app: not confirmed and able to ask; it dials an owner's device, the code, `member` said, then it is in and reads the list", async () => {
  const w = await setUp();
  const before = await w.page();
  assert.equal(w.st.refusals.at(-1)?.left !== undefined, true, "told left out");
  assert.deepEqual([before.me.confirmed, before.me.waiting], [false, true], "not confirmed, able to ask");
  w.approvers.set(w.alice.app.base.hex, {
    where: () => ["ws"],
    approve: async (hello) => {
      w.alice.say("member", { sub: "s1", email: "s1@x.com", lock: stationHash(hello.log[0]), role: "member" }, "ws");
      await w.bring(w.alice);
      return { t: "approved", workspaces: ["ws"], failed: [] };
    },
  });
  const asked = await w.ask("lock.pair", { workspace: "ws" });
  assert.equal(asked.error, undefined, asked.error?.message);
  const trying = await w.page();
  assert.ok(trying.me.pair !== null, "its try on the page");
  assert.ok(w.dialled.includes(w.alice.app.base.hex), `alice's app dialled (${w.alice.app.base.hex.slice(0, 8)}; dialled ${w.dialled.map((d) => d.slice(0, 8))}; ${w.why()})`);
  assert.equal(w.dialled.includes(w.x.app.base.hex), false, "no one else's");
  const done = await w.ask("lock.pairCode", { workspace: "ws", code: CODE });
  assert.equal(done.error, undefined, done.error?.message);
  const after = await w.page();
  assert.equal(after.me.confirmed, true, `in (${w.why()})`);
  assert.equal(subs(after), "r1,r2,s1", "it reads the list");
});

test("a newcomer approved before a station took its `member` statement (2026-11-14, real stations): tried again as it is, and in once a station takes it", async () => {
  const w = await setUp();
  w.approvers.set(w.alice.app.base.hex, {
    where: () => ["ws"],
    approve: (hello) => {
      w.alice.say("member", { sub: "s1", email: "s1@x.com", lock: stationHash(hello.log[0]), role: "member" }, "ws");
      return { t: "approved", workspaces: ["ws"], failed: [] };
    },
  });
  assert.equal((await w.ask("lock.pair", { workspace: "ws" })).error, undefined);
  const done = await w.ask("lock.pairCode", { workspace: "ws", code: CODE });
  assert.equal(done.error, undefined, done.error?.message);
  assert.equal((await w.page()).me.confirmed, false, "not in while no station took it");
  await w.bring(w.alice);
  await w.r.host.time.pass(10_000);
  const after = await w.page();
  assert.equal(after.me.confirmed, true, `in (${w.why()})`);
  assert.equal(subs(after), "r1,r2,s1");
});

test("a member's new web page: it asks that member's own app, `web` said, in", async () => {
  const w = await setUp({ named: true, web: true });
  const before = await w.page();
  assert.deepEqual(w.st.refusals.at(-1)?.left, { approvers: [w.x.app.base.hex], apps: true }, "told to ask X");
  assert.deepEqual([before.me.confirmed, before.me.waiting], [false, true], "not confirmed, able to ask");
  w.approvers.set(w.x.app.base.hex, {
    where: () => ["ws"],
    approve: async () => {
      w.x.add("web", { id: w.base.hex, label: "Chrome", exp: w.now() + 30 * 86400 }, w.x.app.key, w.now());
      await w.bring(w.x);
      return { t: "approved", workspaces: ["ws"], failed: [] };
    },
  });
  assert.equal((await w.ask("lock.pair", { workspace: "ws" })).error, undefined);
  assert.deepEqual(w.dialled, [w.x.app.base.hex], "X alone dialled");
  const done = await w.ask("lock.pairCode", { workspace: "ws", code: CODE });
  assert.equal(done.error, undefined, done.error?.message);
  const after = await w.page();
  assert.equal(after.me.confirmed, true, `in (${w.why()})`);
  assert.equal(subs(after), "r1,r2,s1");
});

// A web page taken off its person's own log where the chain moved (`web.remove`, 设置 › 安全's 移除) is told so by its
// station's refusal, which carries that log (`person`): it takes it, so its page says it is out and waits, never that
// the station has not heard of its approval yet (2026-11-14, the locks' end to end, round 16).
test("a member's web page taken off their log: refused, told out (its page waits, not confirmed), never 'not heard yet'", async () => {
  const w = await setUp({ named: true, web: true });
  w.x.add("web", { id: w.base.hex, label: "Chrome", exp: w.now() + 30 * 86400 }, w.x.app.key, w.now());
  await w.bring(w.x);
  await w.r.host.time.pass(600_000);
  assert.equal((await w.page()).me.confirmed, true, `in (${w.why()})`);
  w.x.add("web.remove", { id: w.base.hex }, w.x.app.key, w.now());
  await w.bring(w.x);
  const refused = w.st.refusals.length;
  const no = await w.hello();
  assert.ok(no !== null && w.st.refusals.length > refused, "refused");
  assert.notEqual(no!.message, "station 尚未收到此设备的批准，即将重试", "not told its approval was not heard yet");
  const after = await w.page();
  assert.deepEqual([after.me.confirmed, after.me.waiting], [false, true], `out, its page waiting (${w.why()})`);
});

test("a member's web page left out, said on their log meanwhile by their app (carried from the chain, personal-lock.ts `#addWebs`): nothing tells it, and its link's own retry asks its station again (views/lock.ts `waiting`): in, nothing pressed, no app dialled", async () => {
  const w = await setUp({ named: true, web: true });
  const before = await w.page();
  assert.deepEqual([before.me.confirmed, before.me.waiting], [false, true], "out, able to ask");
  w.x.add("web", { id: w.base.hex, label: "Chrome", exp: w.now() + 20 * 86400 }, w.x.app.key, w.now());
  await w.bring(w.x);
  // X's app is there to be dialled, and would approve: nothing asks it.
  w.approvers.set(w.x.app.base.hex, { where: () => ["ws"], approve: () => ({ t: "approved", workspaces: ["ws"], failed: [] }) });
  // (before 2026-11-14 it stayed out while it only waited, ten minutes and for good: the chain's head, which its mark
  // waited for, never moves once the chain moved)
  await w.r.host.time.pass(600_000);
  const after = await w.page();
  assert.ok(w.st.admitted > 0, `its station asked again and let it in (${w.why()})`);
  assert.deepEqual(w.dialled, [], "no app dialled: nothing asked of the person's own");
  assert.deepEqual([after.me.confirmed, after.me.pair ?? null], [true, null], `in, no try on the page (${w.why()})`);
  assert.equal(subs(after), "r1,r2,s1", "it reads the list");
});

// A device refused where the chain moved is asked again at its link's own retry (views/lock.ts `waiting`): the chain's
// head never moves there, so the mark of before (asked again once it does) held it back for good, and a device let in
// by a statement it is not given came in only as the person opened the app or pressed (2026-11-14, the locks' end to
// end, round 12: bob's second app, after he was made a member again).
test("a device refused where the chain moved, then let in by what it is not given: asked again at its link's next retry, let in, nobody asked, nothing pressed", async () => {
  const w = await setUp({ named: true, web: true });
  const before = await w.page();
  assert.deepEqual([before.me.confirmed, before.me.waiting], [false, true], "out");
  const asked = w.r.host.secureAsked.length;
  w.x.add("web", { id: w.base.hex, label: "Chrome", exp: w.now() + 20 * 86400 }, w.x.app.key, w.now());
  await w.bring(w.x);
  // (the link's next retry: it dials unless `lockWaiting` holds the station back, as station/mesh-wire.ts does)
  assert.equal(hooks.lockWaiting?.(w.inner, "ws", w.A) ?? null, null, "not held back: asked again at the link's retry");
  assert.equal(await w.hello(), null, `let in (${w.why()})`);
  assert.deepEqual(w.dialled, [], "nothing pressed, no app dialled");
  assert.equal(w.r.host.secureAsked.length, asked, "nobody asked");
});

test("a member's own second app: the personal exchange with their app on the log, then in", async () => {
  const w = await setUp({ named: true });
  const before = await w.page();
  assert.deepEqual([before.me.confirmed, before.me.waiting], [false, true], "not confirmed, able to ask");
  w.approvers.set(w.x.app.base.hex, {
    where: () => ["person:s1"],
    approve: async (hello) => {
      w.x.add("device", { key: hello.personal.key, id: w.base.hex, label: "Pixel", sign_key: hello.sign_key });
      await w.bring(w.x);
      return { t: "approved", workspaces: ["person:s1"], chains: { s1: w.x.entries } };
    },
  });
  assert.equal((await w.ask("lock.pair", { workspace: "ws" })).error, undefined);
  assert.deepEqual(w.dialled, [w.x.app.base.hex], "X alone dialled");
  const done = await w.ask("lock.pairCode", { workspace: "ws", code: CODE });
  assert.equal(done.error, undefined, done.error?.message);
  const after = await w.page();
  assert.equal(after.me.confirmed, true, `in (${w.why()})`);
  assert.equal(subs(after), "r1,r2,s1");
});

// 2026-11-14, the side run of f6cfdf7af1 (N, alice's new app after one was taken off): the stations' refusal came
// before its own lock was read, which named an admin (「…或请其管理员…」), and `lock.pair` then answered "this device
// waits in no workspace". The refusal's own word on the person's log says it (`offOwnLock`), whichever comes first.
test("a member's own second app refused before its own lock was read, and after: its refusal names no admin, and asking joins their log", async () => {
  for (const first of ["refusal", "own lock"] as const) {
    const w = await setUp({ named: true, personHeld: first === "refusal" });
    const personal = w.inner.adb.personal();
    if (first === "refusal") assert.equal(personal.standing("s1"), "none", "its own lock not read yet");
    else await w.run(personal.refresh("s1"));
    // (the refusal that tells it, before its own lock was loaded here: what it tells is not taken then, as
    // personal-lock.ts `heardFrom` takes nothing for a person whose lock it has not loaded yet; a newly signed-in app)
    w.st.personUntold = false;
    const heardFrom = personal.heardFrom.bind(personal);
    if (first === "refusal") personal.heardFrom = () => Effect.void;
    const said = await w.hello();
    personal.heardFrom = heardFrom;
    console.log(`${first} first: standing ${personal.standing("s1")}; refused: ${said?.message}`);
    assert.ok(said !== null, "refused");
    assert.doesNotMatch(said!.message, /管理员|admin/i, `${first} first`);
    w.approvers.set(w.x.app.base.hex, { where: () => ["person:s1"], approve: () => ({ t: "no", error: "not_here" }) });
    w.st.personHeld = false;
    const asked = await w.ask("lock.pair", { workspace: "ws" });
    console.log(`${first} first: lock.pair ${asked.error?.code ?? "ok"}; dialled ${w.dialled.map((d) => d.slice(0, 8)).join(" ")}`);
    assert.equal(asked.error, undefined, `${first} first: ${asked.error?.message}`);
    assert.deepEqual(w.dialled, [w.x.app.base.hex], `${first} first: X alone dialled, its own log's`);
  }
});

// 2026-11-14, main's side run at 00b417fd9b (build 9161), N: each station's first refusal came as its link first
// opened, the workspace's lock not held here yet (no chain to say it moved), while its own lock had been read already
// (a log of its person's it is not on, `outside`), and named an admin; 50 ms later, the lock read, the right words. The
// real order: own lock read, then the refusal, the workspace's lock still unread. The refusal's own `left` says the
// chain moved (a station gives it only there), and with it the person's log this device is not on says it joins that.
test("a new app of a person with a log it is not on, its first refusal before the workspace's lock is held: says to join that log, no admin", async () => {
  const w = await setUp({ named: true, unread: true });
  const personal = w.inner.adb.personal();
  await w.run(personal.refresh("s1"));
  assert.equal(personal.standing("s1"), "outside", "its own lock read (the cloud's copy, no station reached yet): a log of its person's it is not on");
  // (an app just signed in holds no lock of the workspace yet: the rig's core starts holding its genesis, let go here,
  // so the refusal's tail has nothing to go on from, as on N, `heardTail`)
  w.inner.data.put("lock", "ws", {});
  assert.equal(held(w.inner, "ws"), null, "no lock of the workspace held yet (an app just signed in)");
  assert.equal(w.st.refusals.length, 0, "no station reached yet: this is its first refusal");
  const said = await w.hello();
  console.log(`first refusal, lock held ${JSON.stringify(held(w.inner, "ws")?.entries.map((e) => e.kind) ?? null)}, own lock read: ${said?.message}`);
  assert.ok(said !== null, "refused");
  assert.doesNotMatch(said!.message, /管理员|admin/i);
  assert.match(said!.message, /发送批准请求|send/i);
});

test("a station that names a wrong device to ask: nothing let in, the page still able to ask", async () => {
  const w = await setUp();
  const liar = ed().hex;
  w.st.lie = liar;
  hooks.lockRefused?.(w.inner, "ws", w.A, null, { left: { approvers: [liar] } });
  w.approvers.set(w.alice.app.base.hex, { where: () => ["ws"], approve: () => ({ t: "approved", workspaces: ["ws"], failed: [] }) });
  assert.equal((await w.ask("lock.pair", { workspace: "ws" })).error, undefined);
  assert.deepEqual(w.dialled, [liar], "only the device it was told of");
  const after = await w.page();
  assert.deepEqual([after.me.confirmed, after.me.waiting], [false, true], "not in, able to ask");
  assert.equal(w.st.admitted, 0, "never let in");
});

test("a station only waiting for the root's log: as today, nothing listed, nothing to ask", async () => {
  const w = await setUp({ waiting: true });
  const v = await w.page();
  assert.equal(w.st.refusals.some((x) => x.left !== undefined), false, "nobody told left out");
  assert.deepEqual([v.me.confirmed, v.me.waiting, v.me.pair ?? null], [false, false, null]);
  assert.equal(subs(v), "");
});

/// What a web page nobody could approve says (the `lock` topic's `me.needsAppText`, and `lock.pair`'s refusal).
const NEEDS_APP = "此 workspace 的安全模式要求每位成员至少有一台客户端。请安装桌面或手机客户端并登录，由管理员批准后，再用客户端批准此网页版";

for (const [what, o] of [["a member the list names with no app", { named: true, noApp: true }], ["someone the list does not name", {}]] as const) {
  test(`a web page of ${what}: told to install an app, not offered to ask, and asking is refused with the same words; nothing dialled`, async () => {
    const w = await setUp({ ...o, web: true });
    const v = await w.page();
    assert.equal(w.st.refusals.at(-1)?.left?.apps, false, "the station said no app of s1's");
    assert.deepEqual([v.me.confirmed, v.me.waiting, v.me.pair ?? null, v.me.needsAppText ?? null], [false, false, null, NEEDS_APP]);
    // (the upgrade's warning of before is not said once moved)
    assert.equal(v.appText, undefined);
    const asked = await w.ask("lock.pair", { workspace: "ws" });
    assert.equal(asked.error?.message, NEEDS_APP);
    assert.deepEqual(w.dialled, [], "nobody dialled");
    assert.equal((await w.page()).me.needsAppText, NEEDS_APP);
  });
}

// A member with only a web page, their workspace upgraded by itself (nothing held for them: client/core-ts/AGENTS.md):
// the page is carried by the chain until its `exp`; then it is one nobody can approve there, and says so, as one left
// out from the start does.
test("a web page carried by the chain, its person no app: in until its exp, saying nothing; then told to install an app, not offered to ask, asking refused; nothing dialled", async () => {
  const w = await setUp({ webOnly: true, web: true });
  const v = await w.page();
  assert.deepEqual([v.me.confirmed, v.me.waiting, v.me.needsAppText ?? null, v.appText ?? null], [true, false, null, null], `in, nothing said (${w.why()})`);
  w.r.host.advance((WEB_DAYS * 86400 + 60) * 1000);
  await w.run(Effect.ignore(read(w.inner, "ws")));
  const after = await w.page();
  assert.equal(w.st.refusals.at(-1)?.left?.apps, false, `refused at its exp, the station saying no app of s1's (${w.why()})`);
  assert.deepEqual([after.me.confirmed, after.me.waiting, after.me.pair ?? null, after.me.needsAppText ?? null], [false, false, null, NEEDS_APP]);
  const asked = await w.ask("lock.pair", { workspace: "ws" });
  assert.equal(asked.error?.code, "lock_needs_app");
  assert.equal(asked.error?.message, NEEDS_APP);
  assert.deepEqual(w.dialled, [], "nobody dialled");
});

test("a web page whose person's app the list names: no such words, able to ask (that app)", async () => {
  const w = await setUp({ named: true, web: true });
  const v = await w.page();
  assert.deepEqual([v.me.waiting, v.me.needsAppText ?? null], [true, null]);
});

// What a station from before leaves it to, as every station did until `apps` (the page with no words, able to ask): the
// owners' and admins' apps it dials answer a web page not their person's `not_here`, showing nothing (views/pair.ts
// `movedPlace`, `serveTrusted`), so the page lists them as where a code would show and none ever does.
test("a web page of someone with no app, told by a station from before (no `apps`): as before, able to ask; the owners' apps it dials show it no code, and its try lists them showing none", async () => {
  const w = await setUp({ web: true, older: true });
  const v = await w.page();
  assert.deepEqual([v.me.waiting, v.me.needsAppText ?? null], [true, null], "able to ask, as before");
  const asked = await w.ask("lock.pair", { workspace: "ws" });
  assert.equal(asked.error, undefined, asked.error?.message);
  await w.r.host.time.pass(120_000);
  const after = await w.page();
  assert.deepEqual(new Set(w.dialled), new Set([w.alice.app.base.hex, w.bob.app.base.hex]), "the owners' and admins' apps dialled");
  assert.deepEqual([after.me.confirmed, after.me.pair?.state, (after.me.pair?.approvers as J[]).map((a) => a.showing)], [false, "none", [false, false]]);
});

// A member the chain names with an app of theirs (X) and binds to no log, no log of theirs anywhere: their new app asks
// their own devices and begins no log of its own, the device of theirs that approves it beginning their log in that ask
// (views/pair.ts `carriedUnbound`). Only while the stations' list still names an app of theirs (their refusal's
// `apps`): the chain held, frozen at the move, says nothing of one taken out since and added again, whose new app is
// a newcomer, its own log begun and an owner or admin asked, as before the move (the lead, 2026-11-14: else nobody
// could let them in).
test("a carried member with no log, the list naming an app of theirs: their new app begins no log, brings its key to join theirs, and asks their own app alone", async () => {
  const w = await setUp({ carried: true });
  await w.page();
  assert.equal(w.st.refusals.at(-1)?.left?.apps, true, `told the list names an app of theirs (${w.why()})`);
  const hellos: J[] = [];
  w.approvers.set(w.x.app.base.hex, { where: (hello) => (hellos.push(hello), []), approve: () => ({ t: "no" }) });
  const asked = await w.ask("lock.pair", { workspace: "ws" });
  assert.equal(asked.error, undefined, asked.error?.message);
  await w.page();
  assert.ok(w.dialled.includes(w.x.app.base.hex), `their own app dialled (${w.why()})`);
  assert.equal(w.dialled.includes(w.alice.app.base.hex), false, "no owner's");
  assert.equal(w.inner.adb.personal().standing("s1"), "none", "no log begun here");
  assert.ok(hellos.length > 0 && hellos[0].log === undefined && typeof hellos[0].personal?.key === "string", `its hello brings its key to join theirs, no log (${JSON.stringify(hellos[0])?.slice(0, 200)})`);
});

test("a carried member taken out and added again: their new app, told the list names no app of theirs, begins its log, asks an owner, and is admitted face to face, bound by that admit", async () => {
  const w = await setUp({ carried: true });
  w.alice.say("member.remove", { sub: "s1", cancels: [stationHash(w.moved)] }, "ws");
  await w.bring(w.alice);
  // (its link's next hello, as its own retry dials it: refused again, now told the list names no app of theirs)
  await w.hello();
  await w.page();
  assert.equal((await w.c.locked())!.state!.members.has("s1"), false, "out of the station's list");
  assert.equal(w.st.refusals.at(-1)?.left?.apps, false, `told the list names no app of theirs (${w.why()})`);
  w.approvers.set(w.alice.app.base.hex, {
    // (an owner's app shows a code only for a newcomer whose hello brings their log, views/pair.ts `admitOf`)
    where: (hello) => (Array.isArray(hello.log) && hello.log.length > 0 ? ["ws"] : []),
    approve: async (hello) => {
      w.alice.say("member", { sub: "s1", email: "s1@x.com", lock: stationHash(hello.log[0]), role: "member" }, "ws");
      await w.bring(w.alice);
      return { t: "approved", workspaces: ["ws"], failed: [] };
    },
  });
  const asked = await w.ask("lock.pair", { workspace: "ws" });
  assert.equal(asked.error, undefined, asked.error?.message);
  const trying = await w.page();
  assert.ok(w.dialled.includes(w.alice.app.base.hex), `an owner's app dialled (${w.why()})`);
  assert.equal(trying.me.pair?.state, "code", `a code shown by the owner's app, the hello bringing its log (${JSON.stringify(trying.me.pair)?.slice(0, 200)}; ${w.why()})`);
  const done = await w.ask("lock.pairCode", { workspace: "ws", code: CODE });
  assert.equal(done.error, undefined, done.error?.message);
  const after = await w.page();
  assert.equal(after.me.confirmed, true, `in (${w.why()})`);
  const log = w.inner.adb.personal().root("s1");
  assert.ok(log !== null, "its own log begun");
  assert.equal((await w.c.locked())!.state!.persons.get("s1"), log, "bound at the station by that admit");
});

// The root's person, every device lost (apps/mbui/e2e/locks-moved.ts round 24; the lead, 2026-11-14: after a move they
// are a member like any other): their new app begins their log anew (`restart`), an owner takes them out naming the
// root's log, adds them again by the new log and approves the app face to face. The station keeps both logs: the root's
// (the workspace is rooted in it for good) and the new one (theirs, bound by that admit). The app is in, signing, and
// brings its log to the station only for a reason that changed since it last did: never at each read.
test("the root's person's app begun anew, taken out and let in again by an owner: never `replaced`, in, signing, and its log not brought again at each read", async () => {
  const w = await setUp({ rootLost: true });
  await w.page();
  assert.ok(w.st.refusals.length > 0, `refused: the root's log does not name this app (${w.why()})`);
  const pl = w.inner.adb.personal();
  const atRestart = w.st.asked.length;
  const restarted = await w.ask("adb.personalRestart", { sub: "s1" });
  assert.equal(restarted.error, undefined, restarted.error?.message);
  const log = w.inner.adb.personal().root("s1");
  assert.ok(log !== null && log !== w.x.genesis, "its own log begun anew");
  assert.equal(pl.standing("s1"), "member", "on its own log begun anew, never `replaced` (it began it)");
  w.alice.say("member.remove", { sub: "s1", cancels: [w.x.genesis] }, "ws");
  await w.bring(w.alice);
  await w.hello();
  assert.equal((await w.c.locked())!.state!.members.has("s1"), false, "out of the station's list");
  w.approvers.set(w.alice.app.base.hex, {
    where: (hello) => (Array.isArray(hello.log) && hello.log.length > 0 ? ["ws"] : []),
    approve: async (hello) => {
      w.alice.say("member", { sub: "s1", email: "s1@x.com", lock: stationHash(hello.log[0]), role: "owner" }, "ws");
      await w.bring(w.alice);
      return { t: "approved", workspaces: ["ws"], failed: [] };
    },
  });
  await w.page();
  const paired = await w.ask("lock.pair", { workspace: "ws" });
  assert.equal(paired.error, undefined, `${paired.error?.message}: dialled ${w.dialled.map((d) => d.slice(0, 8))}, r1's ${w.alice.app.base.hex.slice(0, 8)} (${w.why()})`);
  const done = await w.ask("lock.pairCode", { workspace: "ws", code: CODE });
  assert.equal(done.error, undefined, done.error?.message);
  const after = await w.page();
  assert.equal(after.me.confirmed, true, `in (${w.why()})`);
  assert.equal((await w.c.locked())!.state!.persons.get("s1"), log, "bound at the station by its new log");
  const kept = new Set((await w.c.personChainsOf("s1")).map(([g]) => g));
  assert.ok(kept.has(w.x.genesis) && kept.has(log!), "the station keeps both: the root's log and the new one");
  // Then what it asks of the station while nothing changes: reads, and no log brought.
  console.log(`asked from the restart to the approval's end: ${summary(w.st.asked.slice(atRestart))}`);
  const from = w.st.asked.length;
  await w.r.host.time.pass(60_000);
  const asked = w.st.asked.slice(from);
  const posts = asked.filter((a) => a === "POST /lock/person").length;
  const reads = asked.filter((a) => a === "GET /lock/person").length;
  console.log(`a minute at rest: ${posts} POST /lock/person, ${reads} GET /lock/person, ${asked.length} asks in all: ${summary(asked)}`);
  assert.equal(posts, 0, `its log brought ${posts} times in a minute at rest (${reads} reads)`);
  assert.equal(pl.standing("s1"), "member", "never `replaced`");
  const page = await w.page();
  assert.equal(page.me.unsigned, undefined, "it signs: its log says its signer, nobody asked more than a newcomer is");
});

// Every other device of a member's lost (2026-11-17): their new app waited for their own devices for good, its page
// naming none of them, nothing on it to do. It names them (a phone, a computer, by their names), dials them through the
// workspace's relays too, and once none answered offers to make it their only trusted device (`lock.restartOwn`); made
// so, it asks nobody and says who is to take them out and add them again (`reboundText`; no approval lets it in while
// the list binds them by their lock of before), and once taken out it asks an owner as a newcomer and is in.
const WS_RELAY = "https://ws-relay.example";
test("every other device of a member's lost: their new app names them, dials them through the workspace's relays, offers 我的其它设备都不在了; made their only trusted device it waits for an admin, taken out it asks an owner and is in", async () => {
  const w = await setUp({ named: true });
  // (a link refused waits for its own retry, as the mesh's does: each ask of the station is no hello of its own)
  w.st.downs = true;
  const phone = dev();
  w.x.add("device", { key: phone.key.id, id: phone.base.hex, label: "still.fail Android · Pixel 9", sign_key: phone.signer.id });
  await w.bring(w.x);
  w.inner.cloudSync.workspaceRelays = (ws: string) => (ws === "ws" ? [WS_RELAY] : []);
  const pl = w.inner.adb.personal();
  await w.run(pl.refresh("s1"));
  assert.equal(pl.standing("s1"), "outside", "a log of theirs it is not on");
  const before = await w.page();
  assert.deepEqual([before.me.confirmed, before.me.waiting, before.me.ownLock], [false, true, true], "waiting, to join their own lock");
  assert.equal(before.me.restartText, undefined, "nothing asked yet: no way out offered before");
  const asked = await w.ask("lock.pair", { workspace: "ws" });
  assert.equal(asked.error, undefined, asked.error?.message);
  const none = await w.page();
  assert.deepEqual(new Set(w.dialled), new Set([w.x.app.base.hex, phone.base.hex]), "both of their devices dialled");
  assert.ok(w.via.length > 0 && w.via.every((r) => r.includes(WS_RELAY)), `through the workspace's relays too: ${JSON.stringify(w.via)}`);
  assert.equal(none.me.pair?.state, "none", `none answered (${JSON.stringify(none.me.pair)})`);
  const listed = (none.me.pair?.approvers ?? []).map((a: J) => `${a.kind} ${a.nameText}`).sort();
  console.log(`listed: ${listed.join("; ")}`);
  assert.deepEqual(listed.map((l: string) => l.split(" ")[0]), ["computer", "phone"], "a computer and a phone");
  assert.ok(listed.some((l: string) => l === "phone Pixel 9"), `the phone by its name: ${listed}`);
  assert.equal(none.me.restartText, "我的其它设备都不在了");
  assert.match(none.me.restartNoteText ?? "", /唯一的受信任设备/);
  const restarted = await w.ask("lock.restartOwn", { workspace: "ws" });
  assert.equal(restarted.error, undefined, restarted.error?.message);
  const log = pl.root("s1");
  assert.ok(log !== null && log !== w.x.genesis, "their lock begun anew here");
  assert.equal(pl.standing("s1"), "member");
  const rebound = await w.page();
  console.log(`made their only trusted device: ${rebound.me.reboundText} (${w.why()})`);
  assert.match(rebound.me.reboundText ?? "", /管理员先将你移出再重新添加/, "a member's: an admin to take them out and add them again");
  assert.deepEqual([rebound.me.confirmed, rebound.me.waiting, rebound.me.pair ?? null, rebound.me.restartText], [false, true, null, undefined], "waiting, nothing to ask");
  const refused = await w.ask("lock.pair", { workspace: "ws" });
  assert.equal(refused.error?.code, "lock_rebound", `asking refused with the same words (${refused.error?.message})`);
  // An owner takes them out: the list binds them by nothing, and the app asks as a newcomer.
  w.alice.say("member.remove", { sub: "s1", cancels: admitsOf(w.alice, "s1") }, "ws");
  await w.bring(w.alice);
  await w.hello();
  const out = await w.page();
  assert.equal(out.me.reboundText, undefined, `nothing to wait for once taken out (${w.why()})`);
  w.approvers.set(w.alice.app.base.hex, {
    where: (hello) => (Array.isArray(hello.log) && hello.log.length > 0 ? ["ws"] : []),
    approve: async (hello) => {
      w.alice.say("member", { sub: "s1", email: "s1@x.com", lock: stationHash(hello.log[0]), role: "member" }, "ws");
      await w.bring(w.alice);
      return { t: "approved", workspaces: ["ws"], failed: [] };
    },
  });
  const paired = await w.ask("lock.pair", { workspace: "ws" });
  assert.equal(paired.error, undefined, paired.error?.message);
  assert.ok(w.dialled.includes(w.alice.app.base.hex), `an owner's app dialled (${w.why()})`);
  const done = await w.ask("lock.pairCode", { workspace: "ws", code: CODE });
  assert.equal(done.error, undefined, done.error?.message);
  const after = await w.page();
  assert.equal(after.me.confirmed, true, `in (${w.why()})`);
  assert.equal((await w.c.locked())!.state!.persons.get("s1"), log, "bound by the lock begun here");
});

test("taken out first, then every other device lost: their new app, made their only trusted device, asks an owner at once", async () => {
  const w = await setUp({ named: true });
  // (a link refused waits for its own retry, as the mesh's does: each ask of the station is no hello of its own)
  w.st.downs = true;
  w.alice.say("member.remove", { sub: "s1", cancels: admitsOf(w.alice, "s1") }, "ws");
  await w.bring(w.alice);
  const pl = w.inner.adb.personal();
  await w.run(pl.refresh("s1"));
  await w.hello();
  assert.equal(pl.standing("s1"), "outside");
  assert.equal((await w.ask("lock.pair", { workspace: "ws" })).error, undefined);
  const none = await w.page();
  assert.equal(none.me.pair?.state, "none", `their own devices answered nothing (${JSON.stringify(none.me.pair)})`);
  assert.equal(none.me.restartText, "我的其它设备都不在了");
  assert.equal((await w.ask("lock.restartOwn", { workspace: "ws" })).error, undefined);
  const after = await w.page();
  assert.equal(after.me.reboundText, undefined, `nothing to wait for: the list binds them by nothing (${w.why()})`);
  w.approvers.set(w.alice.app.base.hex, {
    where: (hello) => (Array.isArray(hello.log) && hello.log.length > 0 ? ["ws"] : []),
    approve: async (hello) => {
      w.alice.say("member", { sub: "s1", email: "s1@x.com", lock: stationHash(hello.log[0]), role: "member" }, "ws");
      await w.bring(w.alice);
      return { t: "approved", workspaces: ["ws"], failed: [] };
    },
  });
  assert.equal((await w.ask("lock.pair", { workspace: "ws" })).error, undefined);
  assert.ok(w.dialled.includes(w.alice.app.base.hex), `an owner's app dialled (${w.why()})`);
  assert.equal((await w.ask("lock.pairCode", { workspace: "ws", code: CODE })).error, undefined);
  assert.equal((await w.page()).me.confirmed, true, `in (${w.why()})`);
});

test("an owner whose every other device is lost: made their only trusted device, told another owner takes them out, or `stillfail lock reset`", async () => {
  const w = await setUp({ rootLost: true });
  await w.page();
  const pl = w.inner.adb.personal();
  await w.run(pl.refresh("s1"));
  assert.equal(pl.standing("s1"), "outside");
  assert.equal((await w.ask("lock.pair", { workspace: "ws" })).error, undefined);
  const none = await w.page();
  assert.equal(none.me.restartText, "我的其它设备都不在了", `offered (${JSON.stringify(none.me.pair)}; ${w.why()})`);
  assert.equal((await w.ask("lock.restartOwn", { workspace: "ws" })).error, undefined);
  await w.hello();
  const rebound = await w.page();
  assert.match(rebound.me.reboundText ?? "", /另一位 owner.*stillfail lock reset/, `an owner's words (${w.why()})`);
});

// Their lock begun anew on another device (`replaced`): this device said it was confirmed, and its every ask was
// refused in words that sent them to another page (`personal_replaced`). It says what happened and lets them say it was them.
test("their own lock begun anew on another device: not confirmed, told what happened, 是我做的，继续 leaves the lock of before, and it asks to join the new one", async () => {
  // (a lock of theirs begun here before it heard of any, that never reached the stations, which keep the one begun anew
  // on X since)
  const w = await setUp({ named: true, personHeld: true });
  // (a link refused waits for its own retry, as the mesh's does: each ask of the station is no hello of its own)
  w.st.downs = true;
  const pl = w.inner.adb.personal();
  w.st.ownUnsaid = true;
  assert.equal(pl.standing("s1"), "none");
  await w.run(pl.begin("s1", "a lock of their own begun here before"));
  assert.equal(pl.standing("s1"), "member");
  w.st.personHeld = false;
  w.st.personUntold = false;
  // (its link dialled again: the refusal names the lock the station keeps of theirs)
  await w.hello();
  await w.page();
  assert.equal(pl.standing("s1"), "replaced", "the stations keep another of theirs");
  const replaced = await w.page();
  assert.deepEqual([replaced.me.confirmed, replaced.me.waiting], [false, true], "not confirmed");
  assert.equal(replaced.me.replacedTitleText, "你的受信任设备被重新设置过");
  assert.match(replaced.me.replacedNoteText ?? "", /账号可能已经被盗/);
  assert.equal(replaced.me.forgetText, "是我做的，继续");
  assert.equal(replaced.me.pair ?? null, null, "nothing to ask before that");
  const forgot = await w.ask("lock.forgetOwn", { workspace: "ws" });
  assert.equal(forgot.error, undefined, forgot.error?.message);
  assert.equal(pl.standing("s1"), "outside");
  const after = await w.page();
  assert.deepEqual([after.me.forgetText, after.me.ownLock], [undefined, true], "asks to join the new one");
  assert.equal((await w.ask("lock.pair", { workspace: "ws" })).error, undefined);
  assert.ok(w.dialled.includes(w.x.app.base.hex), `their device on it dialled (${w.why()})`);
});

test("moved workspace turned off then re-opened: newcomer verifies off locally (clearing stale left from offline stations too, vault not stuck syncing), keeps safeMode/vault consistent on reopen, and completes off->open->off->open", async () => {
  const w = await setUp();
  // Record station A's refusal against the held moved head (as happens on a real refused mesh link) plus a second
  // station B that will be offline when safe mode is turned off.
  await w.hello();
  const vaults = await w.r.watch({ topic: "vaults", workspace: "ws" });
  const OFFLINE_B = "bb".repeat(32);
  hooks.lockRefused?.(w.inner, "ws", OFFLINE_B, null, { left: { approvers: [w.alice.app.base.hex] } });
  const whileOn = await w.page();
  assert.deepEqual([whileOn.locked, whileOn.me.confirmed, whileOn.me.waiting], [true, false, true], `waiting while on (${w.why()})`);
  assert.notEqual(leftIn(w.inner, "ws"), null, "left refusal recorded while on");

  // Root turns safe mode off: station A admits newcomer while B stays offline. Trigger via real link reconnect
  // (`cameOnline`, no manual `refusedAgain`: `waiting()` returns null for moved stations so link retries go through).
  w.alice.say("off", {}, "ws");
  await w.bring(w.alice);
  assert.equal(await w.c.locked(), null, "station sees safe mode off");
  w.inner.stations.cameOnline(`ws/${w.A}`);
  const whileOff = await w.page();
  assert.equal(inForceOf(w.inner, "ws").said, "off", `newcomer verified signed off (${w.why()})`);
  assert.equal(leftIn(w.inner, "ws"), null, "newly verified off clears stale left from both A and offline station B");
  assert.equal(reopenedIn(w.inner, "ws"), false, "not falsely reopened by offline station B's pre-off left");
  assert.equal(safeMode(w.inner, "ws"), false, "safeMode agrees with lockView while off");
  assert.deepEqual([whileOff.locked, whileOff.me.waiting], [false, false], `shows off (${w.why()})`);
  const vOff = (await vaults()) as J;
  assert.equal(vOff.locked, false, "vault agrees safe mode is off");
  assert.equal(vOff.stateText ?? null, null, "vault is not stuck syncing members while off");

  // Root re-opens safe mode: newcomer still has cached `off`, stations refuse with `left`, and lockView + safeMode +
  // vault all agree it is locked/waiting for approval.
  w.alice.say("open", { ...w.settings, email: "r1@x.com" }, "ws");
  await w.bring(w.alice);
  assert.notEqual(await w.c.locked(), null, "station sees safe mode on again");
  await w.hello();
  hooks.lockRefused?.(w.inner, "ws", OFFLINE_B, null, { left: { approvers: [w.alice.app.base.hex] } });
  assert.notEqual(leftIn(w.inner, "ws"), null, "station refused with left after reopen");
  assert.equal(reopenedIn(w.inner, "ws"), true, "reopenedIn is true");
  assert.equal(safeMode(w.inner, "ws"), true, "safeMode agrees workspace is reopened");
  const reopened = await w.page();
  assert.deepEqual([reopened.locked, reopened.me.confirmed, reopened.me.waiting], [true, false, true], `re-entered waiting after reopen (${w.why()})`);
  const vReopened = (await vaults()) as J;
  assert.equal(vReopened.locked, true, "vault shows locked while reopened");
  assert.equal(vReopened.canSign, false, "vault does not fall back to personal signing while reopened");

  // Second off (`off` -> `open` -> `off` cycle): root head advances, so real link reconnect on A clears offline B's `left` too.
  w.alice.say("off", {}, "ws");
  await w.bring(w.alice);
  w.inner.stations.cameOnline(`ws/${w.A}`);
  await w.page();
  assert.equal(leftIn(w.inner, "ws"), null, "second off clears offline B's left because root log head advanced");
  assert.equal(reopenedIn(w.inner, "ws"), false, "not reopened after second off");

  // Re-open once more, dial owner from the reopened `left` hint, get approved, and pull the new `open` + roster.
  w.alice.say("open", { ...w.settings, email: "r1@x.com" }, "ws");
  await w.bring(w.alice);
  await w.hello();
  assert.equal(reopenedIn(w.inner, "ws"), true, "reopened again");
  w.approvers.set(w.alice.app.base.hex, {
    where: (hello) => (Array.isArray(hello.log) && hello.log.length > 0 ? ["ws"] : []),
    approve: async (hello) => {
      w.alice.say("member", { sub: "s1", email: "s1@x.com", lock: stationHash(hello.log[0]), role: "member" }, "ws");
      await w.bring(w.alice);
      return { t: "approved", workspaces: ["ws"], failed: [] };
    },
  });
  const paired = await w.ask("lock.pair", { workspace: "ws" });
  assert.equal(paired.error, undefined, paired.error?.message);
  assert.ok(w.dialled.includes(w.alice.app.base.hex), `owner dialled after reopen (${w.why()})`);
  const done = await w.ask("lock.pairCode", { workspace: "ws", code: CODE });
  assert.equal(done.error, undefined, done.error?.message);
  const joined = await w.page();
  assert.equal(inForceOf(w.inner, "ws").said, "on", `pulled new open after approval (${w.why()})`);
  assert.equal(leftIn(w.inner, "ws"), null, "left cleared after approval");
  assert.deepEqual([joined.locked, joined.me.confirmed, joined.me.waiting], [true, true, false], `confirmed after reopen approval (${w.why()})`);
});

test("clearing a station's left refusal also clears its leftApps without short-circuiting so web needsAppIn does not keep stale apps:false", async () => {
  const w = await setUp({ web: true, unread: true });
  w.alice.say("off", {}, "ws");
  await w.bring(w.alice);
  w.st.lockUnread = false;
  w.st.personHeld = false;
  await w.run(read(w.inner, "ws"));
  assert.equal(inForceOf(w.inner, "ws").said, "off", "baseline off cached");
  const B = "bb".repeat(32);
  // Station A recorded `apps: false`, station B recorded `left` with no `apps` field.
  hooks.lockRefused?.(w.inner, "ws", w.A, null, { left: { approvers: [w.alice.app.base.hex], apps: false } });
  hooks.lockRefused?.(w.inner, "ws", B, null, { left: { approvers: [w.alice.app.base.hex] } });
  assert.equal(needsAppIn(w.inner, "ws"), true, "web needs app while A holds apps:false");
  // Station A admits the web device on the same cached `off` head (per-station clear path, not `newlyOff`), while B stays refused.
  refusedAgain(w.inner, "ws");
  await w.run(read(w.inner, "ws"));
  assert.notEqual(leftIn(w.inner, "ws"), null, "B's left still stands");
  assert.equal(needsAppIn(w.inner, "ws"), false, "A's stale apps:false was cleared along with A's left");
});

test("newcomer joining while moved workspace is already off sees off immediately and never stalls in vault syncing", async () => {
  const w = await setUp({ unread: true });
  w.alice.say("off", {}, "ws");
  await w.bring(w.alice);
  assert.equal(await w.c.locked(), null, "station is off");
  w.st.lockUnread = false;
  w.st.personHeld = false;
  await w.run(read(w.inner, "ws"));
  const page = await w.page();
  const vaults = await w.r.watch({ topic: "vaults", workspace: "ws" });
  assert.equal(inForceOf(w.inner, "ws").said, "off", `verified signed off on first read (${w.why()})`);
  assert.deepEqual([page.locked, page.me.waiting], [false, false]);
  const vJoinOff = (await vaults()) as J;
  assert.equal(vJoinOff.locked, false, "vault sees safe mode off on first read");
  assert.equal(vJoinOff.stateText ?? null, null, "vault not stuck syncing");
});

test("trusted device answering `no {error: 'off'}` shows cautious station-check wording and triggers one deduplicated reread", async () => {
  const w = await setUp();
  const SECOND_APP = "cc".repeat(32);
  hooks.lockRefused?.(w.inner, "ws", w.A, null, { left: { approvers: [w.alice.app.base.hex, SECOND_APP] } });
  const before = await w.page();
  assert.deepEqual([before.locked, before.me.waiting], [true, true]);
  // Two trusted devices answer `off` while station has not yet caught up (still refuses).
  let sentOff = 0;
  const origOpen = dialer.open;
  dialer.open = (_inner, id, relays) => Effect.flatMap(Effect.promise(() => pipe()), ([here, there]) => Effect.sync(() => {
    w.dialled.push(id);
    w.via.push(relays);
    w.inner.runner.fork(Effect.gen(function* () {
      yield* there.next();
      sentOff++;
      yield* there.send({ t: "no", error: "off" });
    }));
    return here;
  }));
  try {
    const askedBefore = w.st.asked.length;
    const paired = await w.ask("lock.pair", { workspace: "ws" });
    assert.equal(paired.error, undefined, paired.error?.message);
    await w.r.host.time.pass(2_000);
    const after = await w.page();
    assert.equal(sentOff, 2, "both trusted devices replied off");
    assert.equal(after.me.pair?.state, "failed", `shows failed instead of none (${JSON.stringify(after.me.pair)})`);
    assert.match(after.me.pair?.error ?? "", /对方设备显示安全模式已关闭/, `cautious off message (${JSON.stringify(after.me.pair)})`);
    assert.ok(w.st.asked.length > askedBefore, "triggered a station reread after peer reported off");
    // Does not trust the peer's word alone: without a signed `off` from the station, still locked.
    assert.equal(after.locked, true, "never disables safe mode on an unsigned peer message");
  } finally {
    dialer.open = origOpen;
  }
});
