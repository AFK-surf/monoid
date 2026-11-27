// Where a workspace's chain moved to its people's own logs (`moved {root}`, station/test/lock-roster4-model.ts D5,
// reading B), the station's state in force is the one the rules work out of the root's log, the logs the statements
// bind and the bodies kept, by this station's clock (cloud/state.ts `locked`): members and roles, each bound log's
// app devices, web devices until their `exp`, stations, settings; admission goes by it; off is a state and a later
// `open` puts it on again; a statement whose body is not here is not in force and is said lacking; without the root's
// log nobody is let in; the chain changing branch to one without `moved` makes the folded chain the state again. Read
// with the chain as it moved (D6, 2026-11-14: what the logs have not said yet of those it named, it still says), and a
// workspace that moved under build 9040's rules (everything said in the logs) reads as it did, but for the web pages
// that move shut out. What reads the chain itself (its seq, head) still reads the chain's.
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { mock, test } from "node:test";
import { LockRefusal, endpointBytes, entryHash, fold, state4, state4Moved } from "../../shared/lock.ts";
import { Cloud, NOT_GIVEN, lockPath, personChainsOf, seenDevicesOf, writeState } from "../src/cloud/state.ts";
import { wall } from "../src/ops/fibers.ts";
import { Effect, Fiber } from "effect";
import { accept } from "../src/mesh/accept.ts";
import type { Admin } from "../src/api/admin.ts";
import { answerBodies, answerPerson, bodiesSyncWith, personSyncWith } from "../src/mesh/person-sync.ts";
import { ALPN, Reader, inLock, inLockBringing, lockHead, lockPartRoute, serve, stillIn } from "../src/mesh/serve.ts";
import { GrantKey } from "./fake-control-plane.ts";
import { Log, WS, WS2, bring, dev, ed, handover, signed, station, viewerOf, world } from "./lock-moved-world.ts";
import { memoryMesh } from "./memory-mesh.ts";

const NOW = 2_000_000;
let clock = NOW;
mock.method(wall, "now", () => clock * 1000);

const as = (sub: string, d: { signer: any; base: any }, role = "member") => ({ viewer: viewerOf(sub, d, role), exp: NOW + 10 * 86400, iat: NOW, sid: "s" });
const roles = (s: any) => [...s.members].map(([sub, m]: [string, any]) => `${sub} ${m.role} ${m.email}`).sort();

test("a chain with moved: the state is the people's logs', its seq and head the chain's", () => {
  clock = NOW;
  const w = world();
  handover(w);
  const c = station(w);
  for (const l of [w.alice, w.bob, w.carol]) bring(c, l);
  const s = c.locked()!.state!;
  assert.deepEqual(roles(s), ["alice owner alice@x", "bob admin bob@x", "carol member carol@x"]);
  assert.deepEqual(new Map(s.persons), new Map([["alice", w.alice.genesis], ["bob", w.bob.genesis], ["carol", w.carol.genesis]]));
  assert.deepEqual([...s.devices.keys()].sort(), [w.alice, w.bob, w.carol].map((l) => l.app.base.hex).sort());
  assert.deepEqual([...s.stations.keys()].sort(), [w.stations[0]!.hex, w.stations[1]!.hex].sort());
  assert.deepEqual([s.origins, s.rp_id], [w.settings.origins, w.settings.rp_id]);
  assert.equal(c.locked()!.waiting, undefined);
  // (the chain's own: what the sync and the cloud's copy read)
  assert.deepEqual(lockHead(c), { seq: 1, hash: entryHash(w.moved), genesis: entryHash(w.first) });
  assert.equal(c.chain()!.state!.moved, w.alice.genesis);
  // What the old chain said is gone from it: its third station, its own list
  assert.equal(c.locked()!.state!.stations.has(w.stations[2]!.hex), false);
});

test("web devices count by this station's clock: in until their exp, out after it", () => {
  clock = NOW;
  const w = world();
  handover(w);
  const web = ed();
  w.carol.add("web", { id: web.hex, label: "browser", exp: NOW + 86400 }, w.carol.app.key, NOW);
  // (one dated ahead of this station's clock by more than ten minutes does not count yet)
  const later = ed();
  w.carol.add("web", { id: later.hex, label: "later", exp: NOW + 7200 + 86400 }, w.carol.app.key, NOW + 7200);
  const c = station(w);
  for (const l of [w.alice, w.bob, w.carol]) bring(c, l);
  const webs = () => [...c.locked()!.state!.devices.values()].filter((d) => d.kind === "web").map((d) => d.id).sort();
  assert.deepEqual(webs(), [web.hex]);
  clock = NOW + 7200 - 600;
  assert.deepEqual(webs(), [web.hex, later.hex].sort());
  clock = NOW + 86400;
  assert.deepEqual(webs(), [later.hex]);
  clock = NOW + 7200 + 86400;
  assert.deepEqual(webs(), []);
  clock = NOW;
});

test("admission goes by it: a member's app in; a device taken off its log out at once; a member a removal takes out out", () => {
  clock = NOW;
  const w = world();
  const said = handover(w);
  const c = station(w);
  const phone = dev();
  w.carol.add("device", { key: phone.key.id, id: phone.base.hex, label: "phone", sign_key: phone.signer.id });
  for (const l of [w.alice, w.bob, w.carol]) bring(c, l);
  const carol = as("carol", w.carol.app);
  assert.equal(inLock(c, carol, "member", carol.viewer.device).viewer.role, "member");
  const p = as("carol", phone);
  const inP = inLock(c, p, "member", p.viewer.device);
  assert.equal(inP.viewer.role, "member");
  // carol takes her phone off her own log: out at once
  w.carol.add("device.remove", { key: phone.key.id });
  bring(c, w.carol, false);
  assert.throws(() => stillIn(c, inP, "member", p.viewer.device), LockRefusal);
  // bob (an admin) takes carol out
  w.bob.say("member.remove", { sub: "carol", cancels: [said.carol.h] });
  bring(c, w.bob);
  assert.equal(c.locked()!.state!.members.has("carol"), false);
  assert.throws(() => stillIn(c, carol, "member", carol.viewer.device), LockRefusal);
  // the bob of the old chain's own device is in still, an admin
  const bob = as("bob", w.bob.app, "admin");
  assert.equal(inLock(c, bob, "admin", bob.viewer.device).viewer.role, "admin");
});

test("a member a statement lets in whose log this station never heard: in, with their log brought at the hello", () => {
  clock = NOW;
  const w = world();
  handover(w);
  const dan = new Log("dan");
  w.alice.say("member", { sub: "dan", email: "dan@x", lock: dan.genesis, role: "member" });
  const c = station(w);
  for (const l of [w.alice, w.bob, w.carol]) bring(c, l);
  assert.equal(c.locked()!.state!.members.get("dan")?.role, "member");
  const d = as("dan", dan.app);
  assert.throws(() => inLock(c, d, "member", d.viewer.device), LockRefusal);
  const inD = inLockBringing(c, d, "member", d.viewer.device, { lock: { person: dan.entries } });
  assert.equal(inD.viewer.role, "member");
  assert.ok(personChainsOf(c).heardIn(WS).some(([g]) => g === dan.genesis), "the log a statement binds counts as heard there");
});

test("off is a state: the lock answers as one turned off, nothing let go, and a later open puts it on again", () => {
  clock = NOW;
  const w = world();
  handover(w);
  const c = station(w);
  for (const l of [w.alice, w.bob, w.carol]) bring(c, l);
  w.alice.say("off", {});
  bring(c, w.alice);
  assert.equal(c.locked(), null);
  assert.notEqual(c.chain(), null, "its chain is kept");
  const kept = c.bodies(null).all().size;
  w.alice.say("open", { ...w.settings, email: "alice@x" });
  bring(c, w.alice);
  assert.ok(c.bodies(null).all().size > kept);
  assert.deepEqual(roles(c.locked()!.state!), ["alice owner alice@x", "bob admin bob@x", "carol member carol@x"]);
  // an admin's `off` is no one's: only the root's
  w.bob.say("off", {});
  bring(c, w.bob);
  assert.notEqual(c.locked(), null);
});

test("a body lacking: its statement not in force, said lacking, in force once brought; meanwhile the chain as it moved still says whom it named", () => {
  clock = NOW;
  const w = world();
  const said = handover(w);
  const c = station(w);
  personChainsOf(c).keep(w.alice.genesis, w.alice.entries, WS);
  for (const l of [w.bob, w.carol]) bring(c, l);
  c.takeBodies(null, [...w.alice.bodies.values()].filter((b) => b.kind !== "member" || b.sub !== "carol"));
  // (carol by the chain as it moved, which bound her to no log: her app by its signer there; and what came after her
  // admit in alice's log stands on it, not in force either, `prev`, but the chain's stations are the same two)
  assert.equal(c.locked()!.state!.members.get("carol")?.role, "member");
  assert.equal(c.locked()!.state!.persons.has("carol"), false);
  assert.equal(c.locked()!.state!.devices.get(w.carol.app.base.hex)?.by, "chain");
  assert.equal(c.locked()!.state!.stations.size, 2);
  assert.deepEqual(c.lacking(null), [said.carol.h]);
  const v = as("alice", w.alice.app, "owner");
  assert.deepEqual((lockPartRoute(c, "bodies", "GET", Buffer.alloc(0), v.viewer) as any)[1].lacking, [said.carol.h]);
  c.takeBodies(null, [said.carol.body]);
  assert.equal(c.locked()!.state!.members.get("carol")?.role, "member");
  assert.equal(c.locked()!.state!.persons.get("carol"), w.carol.genesis, "bound by her log once her admit is in force");
  assert.equal(c.locked()!.state!.devices.get(w.carol.app.base.hex)?.by, undefined);
  assert.equal(c.locked()!.state!.stations.size, 2);
  assert.deepEqual(c.lacking(null), []);
});

test("without the root's log, or its open, nobody is let in, never by the folded chain; the next device that brings them mends it", () => {
  clock = NOW;
  const w = world();
  handover(w);
  const c = station(w);
  bring(c, w.bob);
  assert.equal(c.locked()!.waiting, true);
  assert.equal(c.locked()!.state!.members.size, 0);
  const bob = as("bob", w.bob.app, "admin");
  assert.throws(() => inLock(c, bob, "admin", bob.viewer.device), (e: unknown) => e instanceof LockRefusal && e.message === NOT_GIVEN);
  // no station is the workspace's but by the chain's, and those are asked only for the lock's own (mesh/peer.ts)
  assert.equal(c.waiting(), true);
  // alice's app brings her log and its bodies at its hello
  const a = as("alice", w.alice.app, "owner");
  const inA = inLockBringing(c, a, "owner", a.viewer.device, { lock: { person: w.alice.entries, bodies: [...w.alice.bodies.values()] } });
  assert.equal(inA.viewer.role, "owner");
  assert.equal(c.locked()!.waiting, undefined);
  assert.equal(inLock(c, bob, "admin", bob.viewer.device).viewer.role, "admin");
});

test("while it waits (the root's log not here), a connection let in before is given no bodies and no logs; once it is, it is; no `open` is waited for", () => {
  clock = NOW;
  const w = world();
  const said = handover(w);
  const c = station(w);
  for (const l of [w.bob, w.carol]) bring(c, l);
  // every body of alice's but the open, her log not here: it waits
  c.takeBodies(null, [...w.alice.bodies.values()].filter((b) => b.kind !== "open"));
  assert.equal(c.waiting(), true);
  const v = as("alice", w.alice.app, "owner").viewer;
  const part = (p: string) => (lockPartRoute(c, p, "GET", Buffer.alloc(0), v) as any)[1];
  assert.deepEqual(part("bodies"), { bodies: [], lacking: [] }, "bodies to nobody while it waits");
  assert.deepEqual(part("logs"), { chains: [] }, "logs to nobody while it waits");
  // her log, and so her statements but the open: on by the chain's settings (D6), no `open` waited for
  personChainsOf(c).keep(w.alice.genesis, w.alice.entries, WS);
  c.takeBodies(null, [...w.alice.bodies.values()].filter((b) => b.kind !== "open"));
  assert.equal(c.waiting(), false);
  assert.ok(c.bodies(null).all().size > 0);
  c.takeBodies(null, [said.open.body]);
  assert.equal(c.waiting(), false);
  assert.equal(part("bodies").bodies.length, c.bodies(null).all().size);
  assert.equal(part("logs").chains.length, 3);
});

test("the chain changing branch to one without moved makes the folded chain the state again, and back", () => {
  clock = NOW;
  const w = world();
  handover(w);
  const c = station(w);
  for (const l of [w.alice, w.bob, w.carol]) bring(c, l);
  assert.equal(c.locked()!.state!.stations.size, 2);
  // An entry after the genesis that wins over the `moved` (the owner's removal of a device beats it at their parent):
  // the chain the fork choice gives has no `moved`.
  const removal = signed({ v: 1, ws: WS, seq: 1, prev: entryHash(w.first), at: 1000, kind: "device.remove", body: { id: w.carol.app.base.hex } }, w.alice.app.signer);
  c.takeLock([w.first, removal], null, true);
  assert.deepEqual(c.lockAfter(-1).map(entryHash), [entryHash(w.first), entryHash(removal)], "a removal beats the moved at their parent");
  assert.equal(c.locked()!.state!.moved, undefined);
  assert.equal(c.locked()!.state!.devices.has(w.carol.app.base.hex), false, "the folded chain's state");
  assert.equal(c.locked()!.state!.head, entryHash(removal));
  // and moved again after it: the people's state again
  const again = signed({ v: 1, ws: WS, seq: 2, prev: entryHash(removal), at: 1000, kind: "moved", body: { root: w.alice.genesis } }, w.alice.app.signer);
  c.takeLock([again], null, true);
  assert.equal(c.chain()!.state!.moved, w.alice.genesis);
  assert.equal(c.locked()!.state!.devices.has(w.carol.app.base.hex), true);
  assert.equal(c.locked()!.state!.stations.size, 2);
});

test("a workspace that moved under build 9040's rules, everything said in its people's logs: the same state as those rules gave, but for a web page of the chain's that move shut out", () => {
  clock = NOW;
  const w = world();
  const said = handover(w);
  // after that move: alice takes carol out by her admit alone, makes bob a member (removal, admit) and takes station s1
  // out by its statement alone, each naming what was in force then (none names the `moved`)
  w.alice.say("member.remove", { sub: "carol", cancels: [said.carol.h] });
  w.alice.say("member.remove", { sub: "bob", cancels: [said.bob.h] });
  w.alice.say("member", { sub: "bob", email: "bob@x", lock: w.bob.genesis, role: "member" });
  w.alice.say("station.remove", { key: w.stations[1]!.hex, cancels: [said.s1.h] });
  const chains = [w.alice, w.bob, w.carol].map((l) => l.entries);
  const bodies = [w.alice, w.bob, w.carol].flatMap((l) => [...l.bodies.values()]);
  const said4 = (s: any) => ({ members: [...s.members].sort(), persons: [...s.persons].sort(), devices: [...s.devices.keys()].sort(), stations: [...s.stations.keys()].sort(), settings: [s.origins, s.rp_id] });
  const old = state4(WS, w.alice.genesis, chains, bodies, NOW);
  const now = state4Moved(WS, [w.first, w.moved], chains, bodies, NOW);
  assert.equal(old.on, "on");
  assert.equal(now.on, "on");
  assert.deepEqual(said4(now.state), said4(old.state), "the same state: carol out, bob a member, s1 out");
  assert.equal(now.state.members.has("carol"), false);
  // the chain had a web page of bob's the old move shut out (another member's, not said again by his app): in now,
  // until its exp there
  const page = { id: ed().hex, sub: "bob", kind: "web", label: "bob's browser", exp: NOW + 86400 };
  const g = signed({ ...w.first, body: { ...w.first.body, devices: [...(w.first.body as any).devices, page] } } as any, w.alice.app.signer);
  const moved = signed({ v: 1, ws: WS, seq: 1, prev: entryHash(g), at: 1000, kind: "moved", body: { root: w.alice.genesis } }, w.alice.app.signer);
  const paged = state4Moved(WS, [g, moved], chains, bodies, NOW);
  assert.deepEqual([...paged.state.devices.keys()].sort(), [...old.state.devices.keys(), page.id].sort());
  assert.equal(paged.state.devices.get(page.id)?.by, "chain");
  assert.equal(state4Moved(WS, [g, moved], chains, bodies, NOW + 86400).state.devices.has(page.id), false, "out at its exp");
  // and a member the chain names with only a web page (no app, no log of theirs: nothing holds a move back for them, the
  // owner's 2026-11-14): in by the chain, their page too until its exp, then still a member with no device
  const dora = { id: ed().hex, sub: "dora", kind: "web", label: "dora's browser", exp: NOW + 86400 };
  const gd = signed({ ...w.first, body: { ...w.first.body, members: [...(w.first.body as any).members, { sub: "dora", email: "dora@x", role: "member" }], devices: [...(w.first.body as any).devices, dora] } } as any, w.alice.app.signer);
  const movedD = signed({ v: 1, ws: WS, seq: 1, prev: entryHash(gd), at: 1000, kind: "moved", body: { root: w.alice.genesis } }, w.alice.app.signer);
  const doraIn = state4Moved(WS, [gd, movedD], chains, bodies, NOW).state;
  assert.equal(doraIn.members.get("dora")?.role, "member", "the web-only member in by the chain");
  assert.equal(doraIn.devices.get(dora.id)?.by, "chain", "their page carried");
  const doraLater = state4Moved(WS, [gd, movedD], chains, bodies, NOW + 86400).state;
  assert.equal(doraLater.devices.has(dora.id), false, "their page out at its exp");
  assert.equal(doraLater.members.has("dora"), true, "still a member, with no device in");
});

test("waiting moved station: grantKeys uses pinned chain cloud_keys, serve returns lock_station waiting without lock head or seenDevices write, and real client hello (person only) admits", async (t) => {
  clock = NOW;
  const grant = new GrantKey("k-chain");
  const fakePlaneGrant = new GrantKey("k-plane-fake");
  const w = world();
  w.first = signed({ ...w.first, body: { ...(w.first.body as any), cloud_keys: { keys: [grant.jwk] } } } as any, w.alice.app.signer);
  w.moved = signed({ v: 1, ws: WS, seq: 1, prev: entryHash(w.first), at: 1000, kind: "moved", body: { root: w.alice.genesis } }, w.alice.app.signer);
  w.settings = { origins: ["https://app.still.fail"], rp_id: "app.still.fail", cloud_keys: { keys: [grant.jwk] } } as any;
  handover(w);

  const c = station(w);
  // Overwrite control-plane grant_keys with a fake key to prove waiting never trusts the control plane.
  writeState(c.data, {
    origin: "https://app.still.fail", station: w.stations[0]!.hex, workspace: w.ws, workspace_name: "Team", name: "s0", relay_url: "", relay_urls: [],
    grant_keys: { keys: [fakePlaneGrant.jwk] }, peers: w.stations.map((s, j) => ({ id: s.hex, name: `s${j}` })), revocations: [],
  });
  c.reload();
  t.after(() => c.close());

  assert.equal(c.waiting(), true);
  assert.deepEqual(c.grantKeys(), { keys: [grant.jwk] }, "waiting station uses pinned chain cloud_keys, not null or control plane");

  const mesh = memoryMesh();
  const bind = () => mesh.bind({ secretKey: randomBytes(32), alpns: [ALPN], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  const [at, device] = await Promise.all([bind(), bind()]);
  const timers: { ms: number; fire: () => void }[] = [];
  t.mock.method(wall, "after", (ms: number, fire: () => void) => {
    timers.push({ ms, fire });
    return () => {};
  });
  const running = Effect.runFork(Effect.scoped(accept(at, { serve: (conn) => serve({ cloud: c, admin: undefined as unknown as Admin, up: () => true }, conn), closing: "station stopping" })));
  t.after(async () => {
    await Effect.runPromise(Fiber.interrupt(running));
    await Promise.all([at.close(), device.close()]);
  });

  const dial = async (hello: Record<string, unknown>, waitClose = false) => {
    const conn = await device.connect({ id: at.id(), ips: [`127.0.0.1:${at.sockets()[0]!.split(":").at(-1)}`] }, ALPN);
    const stream = await conn.openBi();
    await stream.write(Buffer.from(JSON.stringify(hello) + "\n"));
    const reply = await new Reader(stream).line();
    let closedWhy: string | null = null;
    if (waitClose) {
      while (timers.length > 0) timers.shift()!.fire();
      closedWhy = await conn.closed();
    } else {
      conn.close(0, "done");
    }
    return { reply, closedWhy };
  };
  const credOf = (g: GrantKey, sub: string, role: string, ws = WS) =>
    g.credential({ typ: "stillfail-member+jwt" }, { iss: "stillfail-cloud", sub, email: `${sub}@x`, name: sub, ws, role, device: device.id(), sid: "s", iat: NOW, exp: NOW + 3600 });
  const proofOf = (d: { base: { hex: string; sign: (b: Buffer) => string } }, ws = WS) => ({
    device: d.base.hex,
    proof: d.base.sign(endpointBytes(ws, device.id())),
  });

  // 1. Connecting without root log returns lock_station why=waiting, omits lock head, closes with reason "lock_station", and does not write seenDevices.
  const { reply: refused, closedWhy } = await dial({ credential: credOf(grant, "alice", "owner"), protocol: 2, lock: { ...proofOf(w.alice.app), kind: "app", label: "Alice Mac" } }, true);
  assert.equal(refused.code, "lock_station");
  assert.equal(refused.why, "waiting");
  assert.equal(refused.error, NOT_GIVEN);
  assert.equal("lock" in refused, false, "waiting refusal must not expose lock head");
  assert.match(String(closedWhy ?? ""), /lock_station/, `close reason should be lock_station, got ${closedWhy}`);
  assert.equal(seenDevicesOf(c).of(WS, NOW, "alice", true).length, 0, "waiting refusal must not pollute seenDevices");

  // 2. Unauthenticated / bad-credential hello carrying valid lock.person + lock.bodies must not exit waiting or pollute personChains/bodies.
  const chainsBefore = personChainsOf(c).every().length;
  const bodiesBefore = c.bodies(null).all().size;
  const { reply: fakeRefused } = await dial({
    credential: credOf(fakePlaneGrant, "alice", "owner"),
    protocol: 2,
    lock: { ...proofOf(w.alice.app), person: w.alice.entries, bodies: [...w.alice.bodies.values()] },
  });
  assert.equal(fakeRefused.code, undefined);
  assert.match(String(fakeRefused.error ?? ""), /unknown credential key/i);
  assert.equal(c.waiting(), true, "unauthenticated hello must not exit waiting");
  assert.equal(personChainsOf(c).every().length, chainsBefore, "unauthenticated hello must not persist person chains");
  assert.equal(c.bodies(null).all().size, bodiesBefore, "unauthenticated hello must not persist bodies");
  assert.equal(seenDevicesOf(c).of(WS, NOW, "alice", true).length, 0);

  // 3. Non-root member bringing only their own person log still gets lock_station waiting.
  const { reply: bobRefused } = await dial({
    credential: credOf(grant, "bob", "admin"),
    protocol: 2,
    lock: { ...proofOf(w.bob.app), person: w.bob.entries },
  });
  assert.equal(bobRefused.code, "lock_station");
  assert.equal(bobRefused.why, "waiting");
  assert.equal(c.waiting(), true);
  assert.equal(seenDevicesOf(c).of(WS, NOW, "alice", true).length, 0);

  // 4. Real client hello shape (only device+proof+person, no bodies) from root owner exits waiting via inLockBringing and admits.
  const { reply: admitted } = await dial({
    credential: credOf(grant, "alice", "owner"),
    protocol: 2,
    lock: { ...proofOf(w.alice.app), kind: "app", label: "Alice Mac", person: w.alice.entries },
  });
  assert.equal(admitted.ok, true);
  assert.equal(c.waiting(), false);
  assert.equal(seenDevicesOf(c).of(WS, NOW, "alice", true).length, 1, "admitted connection after exiting waiting records seenDevices");

  // 5. After peer sync brings bodies, non-root member (bob) connects normally.
  c.takeBodies(null, [...w.alice.bodies.values()]);
  bring(c, w.bob);
  const { reply: bobOk } = await dial({
    credential: credOf(grant, "bob", "admin"),
    protocol: 2,
    lock: { ...proofOf(w.bob.app), person: w.bob.entries },
  });
  assert.equal(bobOk.ok, true);
});

test("exiting waiting re-verifies rotated cloud_keys before setting verified/seenDevices and leaks zero lock details even when device admission would fail", async (t) => {
  clock = NOW;
  const oldGrant = new GrantKey("k-old");
  const newGrant = new GrantKey("k-new");
  const w = world();
  w.first = signed({ ...w.first, body: { ...(w.first.body as any), cloud_keys: { keys: [oldGrant.jwk] } } } as any, w.alice.app.signer);
  w.moved = signed({ v: 1, ws: WS, seq: 1, prev: entryHash(w.first), at: 1000, kind: "moved", body: { root: w.alice.genesis } }, w.alice.app.signer);
  w.settings = { origins: ["https://app.still.fail"], rp_id: "app.still.fail", cloud_keys: { keys: [newGrant.jwk] } } as any;
  handover(w);

  const c = station(w);
  t.after(() => c.close());
  const mesh = memoryMesh();
  const bind = () => mesh.bind({ secretKey: randomBytes(32), alpns: [ALPN], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  const [at, device] = await Promise.all([bind(), bind()]);
  t.after(async () => {
    await Promise.all([at.close(), device.close()]);
  });
  void (async () => {
    for (;;) {
      const conn = await at.accept();
      if (!conn) return;
      void serve({ cloud: c, admin: undefined as unknown as Admin, up: () => true }, conn).catch(() => {});
    }
  })();

  const dial = async (g: GrantKey, lock: Record<string, unknown>) => {
    const conn = await device.connect({ id: at.id(), ips: [`127.0.0.1:${at.sockets()[0]!.split(":").at(-1)}`] }, ALPN);
    const stream = await conn.openBi();
    const credential = g.credential({ typ: "stillfail-member+jwt" }, { iss: "stillfail-cloud", sub: "alice", email: "alice@x", name: "alice", ws: WS, role: "owner", device: device.id(), sid: "s", iat: NOW, exp: NOW + 3600 });
    await stream.write(Buffer.from(JSON.stringify({ credential, protocol: 2, lock }) + "\n"));
    const reply = await new Reader(stream).line();
    conn.close(0, "done");
    return reply;
  };
  const unapprovedDev = dev();
  const unapprovedProof = { device: unapprovedDev.base.hex, proof: unapprovedDev.base.sign(endpointBytes(WS, device.id())) };

  // Old key with an UNAPPROVED device brings root log + rotated `open` body:
  // station exits waiting to newGrant, immediately re-verifies credential BEFORE verified/seenDevices/inLockBringing,
  // and returns ONLY a plain credential error with ZERO lock metadata (no code, lock, person, entries, left, out).
  const oldReply = await dial(oldGrant, { ...unapprovedProof, kind: "app", label: "Rogue", person: w.alice.entries, bodies: [...w.alice.bodies.values()] });
  assert.notEqual(oldReply.ok, true, "old key must not be admitted once open rotated cloud_keys");
  assert.match(String(oldReply.error ?? ""), /unknown credential key/i);
  assert.equal(oldReply.code, undefined, "refusal must not be lock_unconfirmed");
  assert.equal(oldReply.lock, undefined, "refusal must not leak lock head");
  assert.equal(oldReply.person, undefined, "refusal must not leak person chains");
  assert.equal(oldReply.entries, undefined, "refusal must not leak workspace entries");
  assert.equal(oldReply.left, undefined, "refusal must not leak approvers");
  assert.equal(oldReply.out, undefined, "refusal must not leak removal chain");
  assert.equal(c.waiting(), false);
  assert.equal(seenDevicesOf(c).of(WS, NOW, "alice", true).length, 0, "rejected old key must not write seenDevices");

  // Reconnecting with newGrant on Alice's approved device succeeds.
  const aliceProof = { device: w.alice.app.base.hex, proof: w.alice.app.base.sign(endpointBytes(WS, device.id())) };
  const newReply = await dial(newGrant, { ...aliceProof, kind: "app", label: "Alice Mac", person: w.alice.entries });
  assert.equal(newReply.ok, true);
});

test("waiting station with rotated cloud_keys recovers via peer personSyncWith/bodiesSyncWith and admits production new-key hellos", async (t) => {
  clock = NOW;
  const oldGrant = new GrantKey("k-old");
  const newGrant = new GrantKey("k-new");
  const w = world();
  w.first = signed({ ...w.first, body: { ...(w.first.body as any), cloud_keys: { keys: [oldGrant.jwk] } } } as any, w.alice.app.signer);
  w.moved = signed({ v: 1, ws: WS, seq: 1, prev: entryHash(w.first), at: 1000, kind: "moved", body: { root: w.alice.genesis } }, w.alice.app.signer);
  w.settings = { origins: ["https://app.still.fail"], rp_id: "app.still.fail", cloud_keys: { keys: [newGrant.jwk] } } as any;
  handover(w);
  const newSt = ed();
  w.alice.say("station", { key: newSt.hex });

  // Existing protected peer station has full logs + bodies (including rotated open + newSt).
  const peer = station(w);
  for (const l of [w.alice, w.bob, w.carol]) bring(peer, l);
  t.after(() => peer.close());

  // Newly added station downloads moved lock.json and starts waiting with old moved-time keys.
  const fresh = station(w);
  writeState(fresh.data, {
    origin: "https://app.still.fail", station: newSt.hex, workspace: WS, workspace_name: "Team", name: "new-s", relay_url: "", relay_urls: [],
    grant_keys: { keys: [newGrant.jwk] }, peers: [], revocations: [],
  });
  fresh.reload();
  t.after(() => fresh.close());
  assert.equal(fresh.waiting(), true);

  // Sync over peer RPC (`personSyncWith` + `bodiesSyncWith`) using station identity `newSt.hex` (no member credentials).
  const call = async (_to: string, ws: string | null, req: any) => {
    const id = ws ?? WS;
    if (String(req?.method ?? "").startsWith("lock.person.")) return answerPerson(personChainsOf(peer), req, id);
    return answerBodies(peer, req, id, newSt.hex);
  };
  await personSyncWith(personChainsOf(fresh), call, w.stations[0]!.hex, WS);
  await bodiesSyncWith(fresh, call, w.stations[0]!.hex, WS);
  assert.equal(fresh.waiting(), false, "peer sync brings fresh station out of waiting");

  const mesh = memoryMesh();
  const bind = () => mesh.bind({ secretKey: randomBytes(32), alpns: [ALPN], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  const [at, device] = await Promise.all([bind(), bind()]);
  t.after(async () => {
    await Promise.all([at.close(), device.close()]);
  });
  void (async () => {
    for (;;) {
      const conn = await at.accept();
      if (!conn) return;
      void serve({ cloud: fresh, admin: undefined as unknown as Admin, up: () => true }, conn).catch(() => {});
    }
  })();

  // Both root owner and non-root member connect using ONLY newGrant and production hello shape (no `bodies`).
  for (const [sub, role, log] of [["alice", "owner", w.alice], ["bob", "admin", w.bob]] as const) {
    const conn = await device.connect({ id: at.id(), ips: [`127.0.0.1:${at.sockets()[0]!.split(":").at(-1)}`] }, ALPN);
    const stream = await conn.openBi();
    const credential = newGrant.credential({ typ: "stillfail-member+jwt" }, { iss: "stillfail-cloud", sub, email: `${sub}@x`, name: sub, ws: WS, role, device: device.id(), sid: "s", iat: NOW, exp: NOW + 3600 });
    const proof = { device: log.app.base.hex, proof: log.app.base.sign(endpointBytes(WS, device.id())) };
    await stream.write(Buffer.from(JSON.stringify({ credential, protocol: 2, lock: { ...proof, kind: "app", label: sub, person: log.entries } }) + "\n"));
    const reply = await new Reader(stream).line();
    conn.close(0, "done");
    assert.equal(reply.ok, true, `${sub} with newGrant production hello should connect after peer sync`);
  }
});

test("joined workspace leaving waiting into effective off while home is locked is refused on initial hello and mid-renewal (leftOut=home)", async (t) => {
  clock = NOW;
  const grant = new GrantKey("k-joined");
  const wHome = world(WS);
  wHome.first = signed({ ...wHome.first, body: { ...(wHome.first.body as any), cloud_keys: { keys: [grant.jwk] } } } as any, wHome.alice.app.signer);
  wHome.moved = signed({ v: 1, ws: WS, seq: 1, prev: entryHash(wHome.first), at: 1000, kind: "moved", body: { root: wHome.alice.genesis } }, wHome.alice.app.signer);
  wHome.settings = { origins: ["https://app.still.fail"], rp_id: "app.still.fail", cloud_keys: { keys: [grant.jwk] } } as any;
  handover(wHome);

  const wJoined = world(WS2);
  wJoined.first = signed({ ...wJoined.first, body: { ...(wJoined.first.body as any), cloud_keys: { keys: [grant.jwk] } } } as any, wJoined.alice.app.signer);
  wJoined.moved = signed({ v: 1, ws: WS2, seq: 1, prev: entryHash(wJoined.first), at: 1000, kind: "moved", body: { root: wJoined.alice.genesis } }, wJoined.alice.app.signer);
  wJoined.settings = { origins: ["https://app.still.fail"], rp_id: "app.still.fail", cloud_keys: { keys: [grant.jwk] } } as any;
  handover(wJoined);
  wJoined.alice.say("off", {}, WS2);

  const makeStation = () => {
    const c = station(wHome);
    for (const l of [wHome.alice, wHome.bob, wHome.carol]) bring(c, l, true, WS);
    writeState(c.data, {
      origin: "https://app.still.fail", station: wHome.stations[0]!.hex, workspace: WS, workspace_name: "Home", name: "s0", relay_url: "", relay_urls: [],
      grant_keys: { keys: [grant.jwk] }, peers: [], revocations: [],
      joined: [{ workspace: WS2, workspace_name: "Joined", name: "s0", peers: [], revocations: [] }],
    });
    c.reload();
    c.takeLock([wJoined.first], WS2);
    c.takeLock([wJoined.first, wJoined.moved], WS2, true);
    t.after(() => c.close());
    assert.equal(c.waiting(null), false, "home is locked and active");
    assert.equal(c.waiting(WS2), true, "joined starts waiting");
    return c;
  };

  const credFor = (devId: string, ws: string, sub: string, role: string) =>
    grant.credential({ typ: "stillfail-member+jwt" }, { iss: "stillfail-cloud", sub, email: `${sub}@x`, name: sub, ws, role, device: devId, sid: "s", iat: NOW, exp: NOW + 3600 });

  // 1. Initial hello on joined workspace bringing root log + off body: resolves joined to off -> leftOut === "home" -> refused!
  {
    const c1 = makeStation();
    const mesh = memoryMesh();
    const bind = () => mesh.bind({ secretKey: randomBytes(32), alpns: [ALPN], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
    const [at, device] = await Promise.all([bind(), bind()]);
    t.after(async () => {
      await Promise.all([at.close(), device.close()]);
    });
    void (async () => {
      for (;;) {
        const conn = await at.accept();
        if (!conn) return;
        void serve({ cloud: c1, admin: undefined as unknown as Admin, up: () => true }, conn).catch(() => {});
      }
    })();
    const proofJoined = { device: wJoined.alice.app.base.hex, proof: wJoined.alice.app.base.sign(endpointBytes(WS2, device.id())) };
    const conn1 = await device.connect({ id: at.id(), ips: [`127.0.0.1:${at.sockets()[0]!.split(":").at(-1)}`] }, ALPN);
    const s1 = await conn1.openBi();
    await s1.write(Buffer.from(JSON.stringify({
      credential: credFor(device.id(), WS2, "alice", "owner"),
      protocol: 2,
      lock: { ...proofJoined, person: wJoined.alice.entries, bodies: [...wJoined.alice.bodies.values()] },
    }) + "\n"));
    const r1 = await new Reader(s1).line();
    conn1.close(0, "done");
    assert.notEqual(r1.ok, true, "initial hello must be refused when joined resolves to off under locked home");
    assert.equal(r1.code, "lock_station");
    assert.equal(r1.why, "home");
    assert.equal(c1.leftOut(WS2), "home");
  }

  // 2. Separate fresh waiting fixture: transition joined from waiting -> off (leftOut === "home") DURING renewal!
  {
    const c2 = makeStation();
    const mesh = memoryMesh();
    const bind = () => mesh.bind({ secretKey: randomBytes(32), alpns: [ALPN], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
    const [at, device] = await Promise.all([bind(), bind()]);
    t.after(async () => {
      await Promise.all([at.close(), device.close()]);
    });
    void (async () => {
      for (;;) {
        const conn = await at.accept();
        if (!conn) return;
        void serve({ cloud: c2, admin: undefined as unknown as Admin, up: () => true }, conn).catch(() => {});
      }
    })();
    const proofHome = { device: wHome.alice.app.base.hex, proof: wHome.alice.app.base.sign(endpointBytes(WS, device.id())) };
    const proofJoined = { device: wJoined.alice.app.base.hex, proof: wJoined.alice.app.base.sign(endpointBytes(WS2, device.id())) };
    const conn2 = await device.connect({ id: at.id(), ips: [`127.0.0.1:${at.sockets()[0]!.split(":").at(-1)}`] }, ALPN);
    const s2 = await conn2.openBi();
    const reader2 = new Reader(s2);
    await s2.write(Buffer.from(JSON.stringify({ credential: credFor(device.id(), WS, "alice", "owner"), protocol: 2, lock: proofHome }) + "\n"));
    assert.equal((await reader2.line()).ok, true);
    assert.equal(c2.waiting(WS2), true, "WS2 is still waiting right before renewal triggers transition");
    await s2.write(Buffer.from(JSON.stringify({
      credential: credFor(device.id(), WS2, "alice", "owner"),
      protocol: 2,
      lock: { ...proofJoined, person: wJoined.alice.entries, bodies: [...wJoined.alice.bodies.values()] },
    }) + "\n"));
    const r2 = await reader2.line();
    assert.notEqual(r2.ok, true, "renewal transitioning joined from waiting to leftOut=home must be refused");
    assert.equal(c2.leftOut(WS2), "home");
    // Original home connection remains alive and keeps its workspace/role after refused renewal.
    await s2.write(Buffer.from(JSON.stringify({ credential: credFor(device.id(), WS, "alice", "owner"), protocol: 2, lock: proofHome }) + "\n"));
    assert.equal((await reader2.line()).ok, true, "original home connection stays intact after refused renewal");
    conn2.close(0, "done");
  }
});

test("broken lock.json keeps grantKeys null and refuses serve admission", async (t) => {
  clock = NOW;
  const grant = new GrantKey("k1");
  const w = world();
  const c = station(w);
  writeState(c.data, {
    origin: "https://app.still.fail", station: w.stations[0]!.hex, workspace: w.ws, workspace_name: "Team", name: "s0", relay_url: "", relay_urls: [],
    grant_keys: { keys: [grant.jwk] }, peers: [], revocations: [],
  });
  writeFileSync(lockPath(c.data), "{broken json");
  c.close();
  const broken = new Cloud(c.data, false);
  t.after(() => broken.close());

  assert.equal(broken.grantKeys(), null, "broken lock.json returns null grantKeys");
  const mesh = memoryMesh();
  const bind = () => mesh.bind({ secretKey: randomBytes(32), alpns: [ALPN], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  const [at, device] = await Promise.all([bind(), bind()]);
  t.after(async () => {
    await Promise.all([at.close(), device.close()]);
  });
  void (async () => {
    for (;;) {
      const conn = await at.accept();
      if (!conn) return;
      void serve({ cloud: broken, admin: undefined as unknown as Admin, up: () => true }, conn).catch(() => {});
    }
  })();
  const conn = await device.connect({ id: at.id(), ips: [`127.0.0.1:${at.sockets()[0]!.split(":").at(-1)}`] }, ALPN);
  const stream = await conn.openBi();
  const credential = grant.credential({ typ: "stillfail-member+jwt" }, { iss: "stillfail-cloud", sub: "alice", email: "alice@x", name: "alice", ws: WS, role: "owner", device: device.id(), sid: "s", iat: NOW, exp: NOW + 3600 });
  await stream.write(Buffer.from(JSON.stringify({ credential, protocol: 2 }) + "\n"));
  const reply = await new Reader(stream).line();
  conn.close(0, "done");
  assert.notEqual(reply.ok, true);
  assert.match(String(reply.error ?? ""), /unknown credential key/i);
});
