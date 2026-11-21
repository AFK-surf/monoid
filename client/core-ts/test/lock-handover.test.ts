// A workspace's chain handed over to its people's own logs by an owner's own app device (views/lock.ts `handOver`,
// src/lock-handover.ts), end to end on a core whose workspace's stations are the station's own code (station/src
// cloud/state.ts `Cloud`, its routes mesh/serve.ts `lockRoute`, `lockPartRoute`: what they take of entries, logs and
// bodies is what a station takes), the chain not moved until the act moves it. Since 2026-11-14 (the lead's: the chain
// as it moved still says what the logs have not, rules/src/lock/state4.mbt `state4_moved`) it says nothing in anyone's
// log and asks nobody: `moved` alone, signed once the stations of the chain say they read it so and every app device
// the chain lets in runs a build that does, and the state in force after it is the chain's list before (held to the
// fourth round's model's `d4Old`, station/test/lock-roster4-model.ts) at the stations and here, every device let in:
// a member with a device that signs and no log of their own, one with only a web page, one whose app device is on the
// chain and not on their log. No station: pending, carried on by calling it again. Refused for anyone but an owner's own
// device with its log pinned; `unknown_call` without the host's flag.
//
// The world: `ws`, its chain this device's genesis (s1 the owner, this device its app; r2 bob an admin, r3 xena a
// member, each with an app device; stations A and B) and each member's `person` binding to their own log. w2, another
// workspace of s1's, lists station D, which takes nothing of `ws`.
import assert from "node:assert/strict";
import { mock, test } from "node:test";
import { Effect } from "effect";
import { type Entry as StationEntry, entryHash as stationHash } from "../../../shared/lock.ts";
import { HAND_OVER_FROM } from "../src/lock-handover.ts";
import { LOGS_ANY_FROM_BUILD, LOGS_BEFORE, MOVED_FROM_BUILD } from "../../../shared/moved-from.ts";
import { type Key, Log, dev, ed, signed } from "../../../station/test/lock-moved-world.ts";
import { d4Diff } from "../../../station/test/lock-roster4-model.ts";
import { key } from "../../../station/test/lock-world-sim.ts";
import type { CoreError } from "../src/error.ts";
import { type Entry, canonical, entryHash, next } from "../src/lock.ts";
import { crypto } from "../src/personal-lock.ts";
import { hex } from "../src/util.ts";
import { ownBuild, setOwnBuild } from "../src/station/oldest.ts";
import { handOver, handOverState, held, inForceOf, lockView, pendingHeld, read } from "../src/views/lock.ts";
import { serveTrusted, tryOne } from "../src/views/pair.ts";
import { pipe } from "./lock-rig.ts";
import { jsonResponse } from "../src/testing.ts";
import { MbLockStation } from "./mb-lock-station.ts";
import { stationLater } from "./station-fixture.ts";
import { type Opts, T0, admitted, asTheChain, d4Core, d4Station, hello, movedAt, onLog, setUp, silent, takeChain } from "./lock-handover-world.ts";


test("an owner, an admin, a member, two stations: moved, nothing said, nobody asked, the chain's list in force at A, B and here, every device let in", async () => {
  const w = await setUp({ early: true });
  const before = w.d4Chain(w.chain);
  const out = await w.hand();
  assert.equal(out.error, undefined, out.error?.message);
  assert.equal(out.ok, null, "handed over");
  silent(w);
  assert.deepEqual(await movedAt(w), [w.gMe, w.gMe]);
  for (const c of Object.values(w.stations)) assert.equal((await c.bodiesAll(null)).size, 0, "no statement, no body");
  // (s1's own app: on its log by its key there, no signer said there yet; the chain's names it with its signer)
  await asTheChain(w, before, [["s1", { base: w.base }, "owner"], ["r2", w.bob.app, "admin"], ["r3", w.xena.app, "member"]]);
  const again = await w.hand();
  assert.equal(again.error, undefined);
  assert.equal(again.ok, null);
  silent(w);
});

test("a member with a device that signs and no log of their own: not waited for, in force by the chain unbound, their device let in", async () => {
  const w = await setUp({ early: true, more: ["notReady"] });
  const before = w.d4Chain(w.chain);
  const out = await w.hand();
  assert.equal(out.error, undefined, out.error?.message);
  silent(w);
  await asTheChain(w, before, [["r4", w.r4.app, "member"]]);
  assert.equal(inForceOf(w.inner, "ws").f.persons.has("r4"), false, "bound to no log");
});

test("a member with only a web page and one with no device: in force by the chain, the page let in until its exp there", async () => {
  const w = await setUp({ early: true, more: ["web", "none"] });
  const before = w.d4Chain(w.chain);
  assert.equal((await w.hand()).error, undefined);
  silent(w);
  await asTheChain(w, before, [["r5", { base: w.WEB5 }, "admin"]]);
  assert.deepEqual([...inForceOf(w.inner, "ws").f.members.keys()].sort(), ["r2", "r3", "r5", "r6", "s1"]);
  w.r.host.advance((10 * DAY + 60) * 1000);
  const page = admitted("r5", { base: w.WEB5 }, "admin");
  assert.equal((await w.stations.A.inLock(page, "admin", page.viewer.device)).ok, false, "out at its exp");
});

test("the owner's own web page on the chain: let in after, nothing said on their log", async () => {
  const w = await setUp({ early: true, myWeb: true });
  assert.equal((await w.hand()).error, undefined);
  silent(w);
  const page = admitted("s1", { base: w.WEB }, "owner");
  const res = await w.stations.A.inLock(page, "owner", page.viewer.device);
  assert.equal(res.ok && res.viewer.role, "owner", "let in by A");
});

test("no station reachable: the moved pending; a station back and handOver again: moved, nobody asked", async () => {
  const w = await setUp({ early: true });
  w.st.silent = true;
  const out = await w.hand();
  assert.equal(out.error, undefined, out.error?.message);
  assert.ok((out.ok as { pending?: unknown } | null)?.pending, `pending: ${JSON.stringify(out.ok)}`);
  assert.deepEqual(await movedAt(w), [null, null], "no moved at a station");
  w.st.silent = false;
  const again = await w.hand();
  assert.equal(again.error, undefined, again.error?.message);
  assert.equal(again.ok, null, `handed over: ${JSON.stringify(again.ok)}`);
  assert.deepEqual(await movedAt(w), [w.gMe, w.gMe]);
  silent(w);
});

test("a member bound to a log with a second app device on the chain and not on that log: not waited for, both in force, the phone let in by the chain's signer", async () => {
  const w = await setUp({ early: true });
  const phone = dev();
  w.after(w.bob.app.signer, "device", { id: phone.base.hex, sub: "r2", kind: "app", label: "bob's phone", sign_key: phone.signer.id });
  await takeChain(w);
  const before = w.d4Chain(w.chain);
  assert.equal((await w.hand()).error, undefined);
  silent(w);
  await asTheChain(w, before, [["r2", phone, "admin"]]);
  assert.deepEqual(d4Core(w.inner).members.get("r2")?.apps, [w.bob.app.signer.id, phone.signer.id].sort(), "both of bob's apps in force here");
  assert.equal((await w.stations.A.locked(null))?.state?.devices.get(phone.base.hex)?.by, "chain", "the phone by the chain as it moved");
});

test("a member bound to a log no station keeps: held back (it would drop their devices), nothing said, nobody asked; once a station keeps it, handed over", async () => {
  const w = await setUp({ early: true, unbrought: ["r2"] });
  const out = await w.hand();
  assert.equal(out.error?.code, "lock_not_ready", out.error?.message);
  assert.equal(out.error?.message, TITLE, "in the page's words of an upgrade not done, nothing named");
  silent(w);
  assert.deepEqual(await movedAt(w), [null, null]);
  await w.stations.B.bring(w.bob, false, "ws");
  const done = await w.hand();
  assert.equal(done.error, undefined, done.error?.message);
  assert.equal((await w.stations.A.chain(null))?.state?.moved, w.gMe);
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(d4Core(w.inner).members.get("r2")?.apps, [w.bob.app.signer.id], "bob's app in force here");
});

test("a device approved on the chain just before the moved: worked out in the turn, in force after it", async () => {
  const w = await setUp({ early: true });
  const phone = dev();
  w.after(w.bob.app.signer, "device", { id: phone.base.hex, sub: "r2", kind: "app", label: "bob's phone", sign_key: phone.signer.id });
  await takeChain(w);
  await w.run(read(w.inner, "ws"));
  assert.equal((await w.hand()).error, undefined);
  assert.equal((await w.stations.A.chain(null))?.state?.seq, w.chain.length, "the moved after bob's device");
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(d4Core(w.inner).members.get("r2")?.apps, [w.bob.app.signer.id, phone.signer.id].sort());
});

for (const mine of ["admin", "otherKey", "unpinned"] as const) {
  test(`refused, nobody asked, nothing said: ${mine === "admin" ? "not an owner" : mine === "otherKey" ? "not this person's own device by its signer" : "the person's log not pinned"}`, async () => {
    const w = await setUp({ early: true, mine });
    const out = await w.hand();
    assert.equal(out.error?.code, "forbidden", out.error?.message);
    assert.equal(w.asked(), 0);
    assert.equal(w.inner.adb.personal().entries("s1").filter((e) => e.kind === "ws").length, 0);
    assert.equal((await w.stations.A.chain(null))?.state?.moved, undefined);
  });
}

test("without the host's flag, the device's clock before HAND_OVER_FROM: lock.handOver is no call", async () => {
  const w = await setUp({ flag: false, early: true });
  const out = await w.run(Effect.tryPromise({ try: () => w.r.ask("lock.handOver", { workspace: "ws" }), catch: (e) => e as CoreError }));
  assert.equal(out.error?.code, "unknown_call", out.error?.message);
  assert.equal(w.asked(), 0);
  const on = await setUp({ early: true });
  const ok = await on.run(Effect.tryPromise({ try: () => on.r.ask("lock.handOver", { workspace: "ws" }), catch: (e) => e as CoreError }));
  assert.equal(ok.error, undefined, ok.error?.message);
  assert.equal((await on.stations.A.chain(null))?.state?.moved, on.gMe, "with it: handed over");
});

// An app's own host, which says neither `handOverByTests` nor `handOverAuto` (the hold of 2026-11-14 taken out, what the
// locks' rounds showed a moved workspace doing wrong mended): past HAND_OVER_FROM its chain is handed over by itself as
// the lock is read, nothing said in anyone's log and nobody asked.
test("on a host not made for tests, past HAND_OVER_FROM: handed over by itself as the lock is read, nothing said, nobody asked", async () => {
  const w = await setUp({ flag: false });
  await w.run(read(w.inner, "ws"));
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [w.gMe, w.gMe], "moved, nobody calling lock.handOver");
  assert.deepEqual(w.said(), [], "nothing said");
  assert.equal(w.asked(), 0, "nobody asked");
  assert.equal(handOverState(w.inner, "ws"), null, "moved");
});

// A member the chain named unbound, after the move (what an unbound member can do: the lead, 2026-11-14): their first
// app device with a log of its own asks; an owner's device shows the code and says `member` with that log, in the
// role the state gives them (the chain's), one ask of the owner's; they are bound to that log, and what the chain
// carried of theirs stays (it bound them to none: `carry_of`), their web page too until its exp.
test("a member the chain named with only a web page, after the move: their first app device asks, this owner's device shows the code, they come in bound to its log with the chain's role, their web page still in", async () => {
  const view = [{ sub: "s1", email: "a@x.com", role: "owner" }, { sub: "r2", email: "b@x.com", role: "admin" }, { sub: "r3", email: "c@x.com", role: "member" }, { sub: "r5", email: "e@x.com", role: "admin" }];
  const w = await setUp({ early: true, more: ["web"], view });
  assert.equal((await w.hand()).error, undefined);
  await w.run(read(w.inner, "ws"));
  assert.equal(held(w.inner, "ws")?.entries.at(-1)?.kind, "moved");
  const r5 = new Log("r5");
  for (const c of Object.values(w.stations)) await c.bring(r5, false, "ws");
  const { answer, done } = await w.firstApp("r5", r5);
  assert.deepEqual(answer, { t: "code", workspaces: ["ws"] }, "a code shown");
  assert.equal(done?.error, undefined, done?.error?.message);
  assert.equal(w.asked(), 1, "the owner asked once, for the admit");
  assert.deepEqual(w.said().map((x) => x.what), ["member.remove r5", "member r5 admin"], "said with the role the state gives them");
  await w.run(read(w.inner, "ws"));
  const f = inForceOf(w.inner, "ws").f;
  assert.equal(f.members.get("r5")?.role, "admin", "r5 an admin in force here");
  assert.equal(f.persons.get("r5"), r5.genesis, "bound to the log their app brought");
  const app = admitted("r5", r5.app, "admin");
  const appIn = await w.stations.A.inLock(app, "admin", app.viewer.device);
  assert.equal(appIn.ok && appIn.viewer.role, "admin", "their app let in by A as an admin");
  const page = admitted("r5", { base: w.WEB5 }, "admin");
  const pageIn = await w.stations.A.inLock(page, "admin", page.viewer.device);
  assert.equal(pageIn.ok && pageIn.viewer.role, "admin", "their web page still in");
});

/// The workspace's stations meeting: each given what the other keeps of the chain (as another keeper's, so the fork
/// choice decides), of the person logs and of the bodies.
async function meet(a: MbLockStation, b: MbLockStation) {
  for (const [x, y] of [[a, b], [b, a]] as const) for (const [g, es] of await x.personChainsEvery()) await y.personChainsKeep(g, es, "ws");
  const ka = await a.lockKept(null), kb = await b.lockKept(null);
  await a.keepLock(kb, null, true);
  await b.keepLock(ka, null, true);
  const ba = [...(await a.bodiesAll(null)).values()], bb = [...(await b.bodiesAll(null)).values()];
  await a.takeBodies(null, bb);
  await b.takeBodies(null, ba);
}

for (const wins of ["bob", "this device"] as const) {
  test(`two owners hand over at once, each at a station the other's does not reach, then the stations meet: one moved stands (${wins}'s, by the fork choice), one chain and one state in force everywhere, the list the chain had`, async () => {
    const w = await setUp({ early: true, bobOwner: true });
    const [a, b] = [w.stations.A, w.stations.B];
    const phone = dev();
    const head = w.chain.at(-1)!;
    const on = (parent: Entry, by: Key, kind: string, body: unknown): Entry => signed(next("ws", { seq: parent.seq, hash: entryHash(parent), genesis: entryHash(w.chain[0]!) }, Math.max(parent.at, w.now()), kind, body) as Omit<StationEntry, "sig">, by) as unknown as Entry;
    const xenas = on(head, w.xena.app.signer, "device", { id: phone.base.hex, sub: "r3", kind: "app", label: "xena's phone", sign_key: phone.signer.id });
    onLog(w.xena, phone, "xena's phone");
    for (const c of [a, b]) await c.bring(w.xena, false, "ws");
    for (const c of [a, b]) await c.deviceBuildsSaw(phone.base.hex, 0, Math.floor(w.r.host.nowMs() / 1000));
    if (wins === "bob") await a.takeLock([...w.chain, xenas]);
    // bob's app hands over at B, which this device does not reach: its `moved` alone
    w.st.down.add("B");
    const bobsAt = wins === "this device" ? on(xenas, w.bob.app.signer, "moved", { root: w.bob.genesis }) : on(head, w.bob.app.signer, "moved", { root: w.bob.genesis });
    await b.takeLock([...w.chain, ...(wins === "this device" ? [xenas] : []), bobsAt]);
    assert.equal((await b.chain(null))?.state?.moved, w.bob.genesis, "B moved to bob's log");
    const out = await w.hand();
    assert.equal(out.error, undefined, out.error?.message);
    assert.equal(out.ok, null, `handed over at A: ${JSON.stringify(out.ok)}`);
    assert.equal((await a.chain(null))?.state?.moved, w.gMe, "A moved to s1's log");
    await meet(a, b);
    w.st.down.clear();
    for (let n = 0; n < 3; n++) {
      await w.run(read(w.inner, "ws"));
      await w.run(w.inner.adb.personal().refresh("s1"));
    }
    const root = wins === "bob" ? w.bob.genesis : w.gMe;
    const list = w.d4Chain([...w.chain, xenas]);
    const nowS = Math.floor(w.r.host.nowMs() / 1000);
    // (rooted in bob's log, s1 is an owner by the chain as it moved, bound to their log as it bound them; rooted in
    // s1's, bob too)
    for (const [n, c] of [["A", a], ["B", b]] as const) {
      assert.equal((await c.chain(null))?.state?.moved, root, `${n} goes by ${wins}'s moved`);
      assert.deepEqual(d4Diff(list, await d4Station(c, root, nowS)), [], `${n}'s state in force is the list the chain had`);
    }
    assert.equal(stationHash((await a.lockAfter(-1)).at(-1)!), stationHash((await b.lockAfter(-1)).at(-1)!), "one chain: the same head at both");
    assert.equal(inForceOf(w.inner, "ws").root, root);
    for (const [sub, d, role] of [["s1", { base: w.base }, "owner"], ["r2", w.bob.app, "owner"], ["r3", w.xena.app, "member"]] as const) {
      const x = admitted(sub, d, role);
      for (const c of [a, b]) {
        const res = await c.inLock(x, role, x.viewer.device);
        assert.equal(res.ok && res.viewer.role, role, `${sub}'s device let in`);
      }
    }
    const mine = async (c: MbLockStation) => (await c.lockKept(null)).filter((e) => e.kind === "moved" && e.sig.key === w.signer.id).length;
    assert.deepEqual([await mine(a), await mine(b)], [1, 1], "this device's moved signed once");
    assert.ok(!pendingHeld(w.inner, "ws").some((x) => x.entry.kind === "moved"), "no moved pending here");
    silent(w);
    if (wins === "bob") {
      const off = await w.run(Effect.tryPromise({ try: () => w.r.ask("lock.disable", { workspace: "ws" }), catch: (e) => e as CoreError }));
      assert.equal(off.error?.code, "lock_root_only", off.error?.message);
      // (turning it on again is the root's person's alone too: refused before anyone is asked, nothing said on this
      // person's own log, where an `open` counts for nothing)
      const own = w.inner.adb.personal().entries("s1").length;
      const asked = w.asked();
      const on = await w.run(Effect.tryPromise({ try: () => w.r.ask("lock.open", { workspace: "ws" }), catch: (e) => e as CoreError }));
      assert.equal(on.error?.code, "lock_root_only", on.error?.message);
      assert.deepEqual([w.inner.adb.personal().entries("s1").length, w.asked()], [own, asked], "nothing said, nobody asked");
    }
  });
}

// Handed over by itself (views/lock.ts `handsOver`, `movedBySelf`): nobody calls `lock.handOver` and nobody is asked;
// the `moved` is signed with no key in hand as the lock is held, once nothing holds it back. On every host from
// HAND_OVER_FROM (the device's clock here past it, no `handOverAuto`): what holds a workspace back is what uses it.
const DAY = 86400;

// No app device but the one that moves the chain holds a handover back (the user, 2026-11-14: a phone of his own he no
// longer used held his workspace for seven days, nothing saying why; 「用户要是有个设备离线不用了要等 7 天？」): one on a
// build under MOVED_FROM_BUILD, or never seen, is told to update by a station of the moved workspace as it next asks
// (station/src/mesh/serve.ts `movedTooOld`). Nor does a member with only a web page, nor how many members there are.
/// A member's app device asking every station of `ws` with the build `build` (the station's own code: admitted by its
/// lock, its build kept by its id there, serve.ts `sawBuild`).
const asks = async (w: Awaited<ReturnType<typeof setUp>>, sub: string, d: { base: Key }, role: string, build: string) => {
  for (const c of Object.values(w.stations)) {
    const a = admitted(sub, d, role);
    const res = await c.inLock(a, role, a.viewer.device);
    if (!res.ok) throw new Error(res.message);
    await c.sawBuild(res.viewer, build);
  }
};
const OLD = MOVED_FROM_BUILD - 1;

test("on: the genesis's person's device hands over by itself as the lock is read, nobody asked, the chain's list in force", async () => {
  const w = await setUp();
  const before = w.d4Chain(w.chain);
  await w.run(read(w.inner, "ws"));
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [w.gMe, w.gMe], "moved, nobody calling lock.handOver");
  silent(w);
  assert.equal(handOverState(w.inner, "ws"), null, "moved");
  await asTheChain(w, before, [["r2", w.bob.app, "admin"]]);
});

test("an app device seen on a build under MOVED_FROM_BUILD today: not waited for, moved by itself; that device is told to update at the workspace's stations, and is in once it has", async () => {
  const w = await setUp({ builds: { r2: `0.1.${OLD}` } });
  assert.equal(handOverState(w.inner, "ws"), null, "nothing holds it back");
  assert.equal(lockView(w.inner, "ws").upgrade, undefined, "no line");
  await w.run(read(w.inner, "ws"));
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [w.gMe, w.gMe], "moved, the device on the old build not waited for");
  for (const c of Object.values(w.stations)) {
    assert.equal(await c.movedTooOld("ws", OLD), true, "told to update there");
    assert.equal(await c.movedTooOld("ws", MOVED_FROM_BUILD), false, "in once it has");
  }
  silent(w);
});

// The device that moves the chain is held to the build it says to the stations (views/lock.ts `heldBack`; the lead,
// 2026-11-14): on a release under MOVED_FROM_BUILD it moves nothing, as a
// station of a moved workspace would tell it to update the moment it did (serve.ts `movedTooOld`). Every other app
// device of the chain on an able build here, so this device's own build is all that holds it.
test("this device on a release under MOVED_FROM_BUILD, every other device able: nothing moved, lock.handOver waits; on MOVED_FROM_BUILD: moved by itself", async () => {
  const was = ownBuild();
  try {
    setOwnBuild(`0.1.${OLD}`);
    const w = await setUp();
    assert.deepEqual(handOverState(w.inner, "ws"), { held: ["own build"] });
    assert.equal(lockView(w.inner, "ws").upgrade, undefined, "no line");
    await w.run(read(w.inner, "ws"));
    await w.run(read(w.inner, "ws"));
    assert.deepEqual(await movedAt(w), [null, null], "nothing moved");
    const call = await w.hand();
    assert.equal(call.error?.code, "lock_not_ready", "lock.handOver answered as a handover waiting, by tests too");
    setOwnBuild(`0.1.${MOVED_FROM_BUILD}`);
    await w.run(read(w.inner, "ws"));
    await w.run(read(w.inner, "ws"));
    assert.deepEqual(await movedAt(w), [w.gMe, w.gMe], "moved");
    silent(w);
  } finally {
    setOwnBuild(was);
  }
});

test("an app device no station has seen (one not used any more): not waited for, moved at once; it comes back on a build under MOVED_FROM_BUILD: told to update there", async () => {
  const w = await setUp({ builds: { r3: null } });
  assert.equal(handOverState(w.inner, "ws"), null, "nothing holds it back");
  await w.run(read(w.inner, "ws"));
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [w.gMe, w.gMe], "moved with no day waited");
  for (const c of Object.values(w.stations)) {
    assert.equal(await c.movedTooOld("ws", OLD), true, "too old for the moved workspace");
    assert.equal(await c.movedTooOld("ws", MOVED_FROM_BUILD), false);
  }
  silent(w);
});

test("a web page that is the only device not able (it said no build): not waited for, moved", async () => {
  const w = await setUp({ myWeb: true });
  for (const c of Object.values(w.stations)) await c.deviceBuildsSaw(w.WEB.hex, null, Math.floor(w.r.host.nowMs() / 1000));
  await w.run(read(w.inner, "ws"));
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [w.gMe, w.gMe], "moved");
});

test("a station of another workspace of theirs that says nothing of builds: not waited for (nothing is written in their log), moved", async () => {
  const w = await setUp({ dOld: true });
  await w.run(read(w.inner, "ws"));
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [w.gMe, w.gMe], "moved");
  silent(w);
});

// A workspace of any size is upgraded (the owner, 2026-11-14: a moved workspace does for every person what an unmoved
// one does): a device keeps every log its stations give (views/lock.ts `keepLogs`; of before at most 256, measured
// 2026-11-15: of 300 members 42 listed with no device, the owner's `handOver` refused `lock_not_ready` for good), and a
// chain binding more than LOGS_BEFORE logs is handed over once every station it names says `heads` (a core of before
// keeps no more, and stations of this build tell it to update there, serve.ts `movedFloor`).
/// The chain moved as an owner's device moves it (`moved` signed by this device's signer), taken by every station.
const movedByStations = async (w: Awaited<ReturnType<typeof setUp>>) => {
  w.after(w.signer, "moved", { root: w.gMe });
  for (const c of Object.values(w.stations)) await c.takeLock([...w.chain], null, true);
  await w.run(read(w.inner, "ws"));
  assert.equal(held(w.inner, "ws")?.entries.at(-1)?.kind, "moved", "the chain held moved");
};
/// The devices station `c`'s state names that the state here does not (by id), and those here it does not.
const devicesApart = async (w: Awaited<ReturnType<typeof setUp>>, c: MbLockStation) => {
  const here = inForceOf(w.inner, "ws").f.devices, there = (await c.locked(null))!.state!.devices;
  return { missing: [...there.keys()].filter((id) => !here.has(id)).length, extra: [...here.keys()].filter((id) => !there.has(id)).length };
};
/// This device's build (`0.1.<n>`) while `f` runs.
const onBuild = async <X>(n: number, f: () => Promise<X>): Promise<X> => {
  const was = ownBuild();
  setOwnBuild(`0.1.${n}`);
  try {
    return await f();
  } finally {
    setOwnBuild(was);
  }
};

test("a moved workspace of 300 members, each bound to a log of their own with a phone on it alone: the state here is each station's, device for device", async () => {
  const w = await setUp({ crowd: 297, crowdPhones: true, early: true });
  assert.ok(new Set((await w.stations.A.chain(null))!.state!.persons.values()).size > LOGS_BEFORE, "more logs bound than a device of before kept");
  await movedByStations(w);
  for (const c of [w.stations.A, w.stations.B]) assert.deepEqual(await devicesApart(w, c), { missing: 0, extra: 0 }, "every device of the station's state here, and no other");
  const now = Math.floor(w.r.host.nowMs() / 1000);
  assert.deepEqual(d4Diff(await d4Station(w.stations.A, w.gMe, now), d4Core(w.inner)), [], "the state here is A's (the model's D4)");
  assert.equal(((w.inner.data.record("lockLogs", "ws") as { logs?: unknown[] } | null)?.logs ?? []).length, 299, "every member's log but this device's own person's kept");
});

test("an owner's device hands a chain binding 300 logs over by itself, on a build from LOGS_ANY_FROM_BUILD; under it (a release's): held, nothing said", async () => {
  await onBuild(LOGS_ANY_FROM_BUILD - 1, async () => {
    const w = await setUp({ crowd: 297 });
    assert.deepEqual(handOverState(w.inner, "ws"), { held: ["own build"] }, "a release under LOGS_ANY_FROM_BUILD: held");
    assert.deepEqual(await movedAt(w), [null, null]);
  });
  await onBuild(LOGS_ANY_FROM_BUILD, async () => {
    const w = await setUp({ crowd: 297 });
    const before = w.d4Chain(w.chain);
    await w.run(read(w.inner, "ws"));
    await w.run(read(w.inner, "ws"));
    assert.deepEqual(await movedAt(w), [w.gMe, w.gMe], "moved at A and B, nobody calling lock.handOver");
    silent(w);
    await asTheChain(w, before, []);
  });
});

test("a chain binding 300 logs, one station not saying `heads`: waited for and named as one not serving `carried` is; it says it: moved", async () => {
  await onBuild(LOGS_ANY_FROM_BUILD, async () => {
    const w = await setUp({ crowd: 297, noHeads: ["B"] });
    assert.deepEqual(handOverState(w.inner, "ws"), { stations: [w.B] });
    const lines = texts(lockView(w.inner, "ws").upgrade);
    assert.equal(lines.length, 1);
    assert.match(lines[0]!, /^等待 station studio 2：请将它更新到最新版本并保持在线/);
    await w.run(read(w.inner, "ws"));
    assert.deepEqual(await movedAt(w), [null, null], "nothing moved");
    assert.equal((await w.hand()).error?.code, "lock_stations_not_ready", "lock.handOver says so");
    w.st.noHeads.clear();
    await w.run(read(w.inner, "ws"));
    await w.run(read(w.inner, "ws"));
    assert.deepEqual(await movedAt(w), [w.gMe, w.gMe], "moved once B says it");
    silent(w);
  });
});

test("a chain of 20 members, one station not saying `heads`: handed over at once, nothing waited for", async () => {
  const w = await setUp({ crowd: 17, noHeads: ["B"] });
  assert.equal(handOverState(w.inner, "ws"), null, "nothing holds it back");
  await w.run(read(w.inner, "ws"));
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [w.gMe, w.gMe], "moved");
  silent(w);
});

// What a read of a moved workspace asks (the brief of 2026-11-15: each read asked each station for every log and every
// body whole, 66 KB at 50 members, 1.3 MB at 1000, nothing changed): by their heads, then only what changed.
/// The lock's reads of the logs and bodies asked since `from`, a line each: `<station> <method> <path> <body sent>`.
const readsOf = (w: Awaited<ReturnType<typeof setUp>>, from: number) =>
  w.st.asked.slice(from).filter((a) => /^\/lock\/(logs|bodies|heads|given)$/.test(a.path) && !(a.method === "POST" && a.path === "/lock/bodies")).map((a) => `${a.at.slice(-1)} ${a.method} ${a.path}${a.method === "POST" ? ` ${a.body}` : ""}`).sort();
/// Requests and bytes answered of a read since `from` (every /lock route), printed.
const weighed = (w: Awaited<ReturnType<typeof setUp>>, from: number, n: number, what: string) => {
  const asked = w.st.asked.slice(from).filter((a) => a.path.startsWith("/lock"));
  const by = new Map<string, { n: number; got: number }>();
  for (const a of asked) {
    const k = `${a.method} ${a.path.split("?")[0]}`;
    const x = by.get(k) ?? { n: 0, got: 0 };
    x.n++, x.got += a.got ?? 0;
    by.set(k, x);
  }
  console.log(`READ N=${n} ${what}: ${asked.length} requests ${asked.reduce((t, a) => t + (a.got ?? 0), 0)} B [${[...by].map(([k, x]) => `${k} x${x.n} ${x.got} B`).join(", ")}]`);
};
for (const n of [50, 300]) {
  test(`a moved workspace of ${n} members read: nothing changed, nothing asked; one log grown, that log alone of each station; a statement, its body and its signer's log; a station from before, whole`, async () => {
    const w = await setUp({ crowd: n - 3, early: true, bobOwner: true });
    await movedByStations(w);
    await w.run(read(w.inner, "ws"));
    // (each step weighed and checked, what was wrong said at the end: so a run on code of before weighs them all)
    const wrong: string[] = [];
    const check = (got: unknown, want: unknown, what: string) => {
      if (JSON.stringify(got) !== JSON.stringify(want)) wrong.push(`${what}: ${JSON.stringify(got).slice(0, 400)}`);
    };
    let from = w.st.asked.length;
    await w.run(read(w.inner, "ws"));
    weighed(w, from, n, "nothing changed");
    check(readsOf(w, from), ["A GET /lock/heads", "B GET /lock/heads"], "nothing changed: the heads alone");
    // one member's log grows (a phone put on it), brought to A and B
    const m = w.crowd[3]!;
    onLog(m, dev(), `${m.sub}'s phone`);
    await takeChain(w, [m]);
    from = w.st.asked.length;
    await w.run(read(w.inner, "ws"));
    weighed(w, from, n, "one log grown");
    const asks = (logs: string[], bodies: string[]) => JSON.stringify({ logs, bodies });
    check(readsOf(w, from), ["A GET /lock/heads", `A POST /lock/given ${asks([m.genesis], [])}`, "B GET /lock/heads", `B POST /lock/given ${asks([m.genesis], [])}`], "that log alone, of each");
    check((await devicesApart(w, w.stations.A)).missing, 0, "the phone in force here");
    // one statement: bob, an owner, takes xena out
    const movedEntry = held(w.inner, "ws")!.entries.at(-1)!;
    const said = w.bob.say("member.remove", { sub: "r3", cancels: [stationHash(movedEntry as unknown as StationEntry)] }, "ws");
    for (const c of Object.values(w.stations)) await c.bring(w.bob, true, "ws");
    from = w.st.asked.length;
    await w.run(read(w.inner, "ws"));
    weighed(w, from, n, "one statement");
    check(readsOf(w, from), ["A GET /lock/heads", `A POST /lock/given ${asks([w.bob.genesis], [said.h])}`, "B GET /lock/heads", `B POST /lock/given ${asks([w.bob.genesis], [said.h])}`], "its body and its signer's log");
    check(inForceOf(w.inner, "ws").f.members.has("r3"), false, "xena out here");
    // nothing changed again, a body held: a read hashes it once as kept here, the next hashes no body again (the
    // rules' body_hash_js hashes a body's canonical text by the crypto it is given, `sha256Hex`: counted by what it
    // hashes, a statement's body)
    await w.run(read(w.inner, "ws"));
    const hashed = { bodies: 0 };
    const original = crypto.sha256Hex;
    const sha = mock.method(crypto, "sha256Hex", (text: string) => {
      try {
        const v = JSON.parse(text);
        if (v !== null && typeof v === "object" && "salt" in v && "kind" in v && !("sig" in v)) hashed.bodies++;
      } catch {
        // (not JSON: not a body)
      }
      return original(text);
    });
    from = w.st.asked.length;
    await w.run(read(w.inner, "ws"));
    sha.mock.restore();
    weighed(w, from, n, "nothing changed, a body held");
    check(readsOf(w, from), ["A GET /lock/heads", "B GET /lock/heads"], "nothing changed again: the heads alone");
    console.log(`READ N=${n} bodies hashed in a read with nothing changed: ${hashed.bodies}`);
    check(hashed.bodies, 0, "no body hashed again");
    // B from before: read whole there
    w.st.noHeads.add("B");
    from = w.st.asked.length;
    await w.run(read(w.inner, "ws"));
    weighed(w, from, n, "B from before");
    check(readsOf(w, from), ["A GET /lock/heads", "B GET /lock/bodies", "B GET /lock/logs"], "B whole");
    assert.deepEqual(wrong, []);
  });
}
// A member with only a web page holds nothing back (the owner, 2026-11-13: 「开了安全模式那就需要 app」, web pages not
// waited for; 2026-11-14: 无感迁移): their page is carried by the chain as it moved until its `exp` (rules `carry_of`),
// nothing said to anyone before or after, and nothing on the owner's page.
test("a member with only a web page: handed over by itself, nobody asked, nothing said to anyone; the page let in by the chain until its exp, then out at both stations, told it names no app of theirs", async () => {
  const w = await setUp({ more: ["web"] });
  assert.equal(handOverState(w.inner, "ws"), null, "nothing holds it back");
  const before = w.d4Chain(w.chain);
  const v = lockView(w.inner, "ws") as Record<string, any>;
  assert.equal(v.upgrade, undefined, "no line");
  assert.deepEqual([v.appText, ...v.members.map((m: Record<string, unknown>) => m.appText)].filter((x) => x !== undefined), [], "nothing said of the member before");
  await w.run(read(w.inner, "ws"));
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [w.gMe, w.gMe], "moved");
  silent(w);
  await asTheChain(w, before, [["r5", { base: w.WEB5 }, "admin"]]);
  w.r.host.advance((10 * DAY + 60) * 1000);
  for (const [n, c] of Object.entries(w.stations)) {
    const was = await hello(c, "r5", w.WEB5, "admin");
    assert.equal(was.in, false, `out at its exp at ${n}`);
    assert.equal(was.left?.apps, false, `${n} tells the page the list names no app of r5's (so it asks nobody: views/lock.ts \`needsAppIn\`)`);
  }
});

// What the move leaves a member with only a web page to do, once that page ran out (the owner, 2026-11-14: 「开了安全模式那
// 就需要 app」): their first app comes in as a newcomer's, an owner's device showing the code (the owner's one ask), and
// approves their page on their own log (their one ask, an entry of their log: personal-lock.ts `web`), which lets it in
// again at both stations. Nothing else is asked of anyone.
test("a member with only a web page, moved by itself, the page run out: their first app comes in by the owner's one ask, then approves the page by theirs, and it is in again at both stations", async () => {
  const view = [{ sub: "s1", email: "a@x.com", role: "owner" }, { sub: "r2", email: "b@x.com", role: "admin" }, { sub: "r3", email: "c@x.com", role: "member" }, { sub: "r5", email: "e@x.com", role: "admin" }];
  const w = await setUp({ more: ["web"], view });
  await w.run(read(w.inner, "ws"));
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [w.gMe, w.gMe], "moved by itself");
  silent(w);
  w.r.host.advance((10 * DAY + 60) * 1000);
  for (const c of Object.values(w.stations)) assert.equal((await hello(c, "r5", w.WEB5, "admin")).left?.apps, false, "run out, nobody to approve it there");
  const r5 = new Log("r5");
  for (const c of Object.values(w.stations)) await c.bring(r5, false, "ws");
  const { answer, done } = await w.firstApp("r5", r5);
  assert.deepEqual(answer, { t: "code", workspaces: ["ws"] }, "a code shown on the owner's device");
  assert.equal(done?.error, undefined, done?.error?.message);
  assert.equal(w.asked(), 1, "the owner asked once");
  const app = admitted("r5", r5.app, "admin");
  const appRes = await w.stations.A.inLock(app, "admin", app.viewer.device);
  assert.equal(appRes.ok && appRes.viewer.role, "admin", "their app in");
  const theirs = r5.entries.length;
  const at = Math.floor(w.r.host.nowMs() / 1000);
  r5.add("web", { id: w.WEB5.hex, label: "r5's browser", exp: at + 10 * DAY }, r5.app.key, at);
  assert.equal(r5.entries.length - theirs, 1, "their one ask: one entry on their log");
  for (const [n, c] of Object.entries(w.stations)) {
    await c.bring(r5, false, "ws");
    assert.equal((await hello(c, "r5", w.WEB5, "admin")).in, true, `the page in again at ${n}`);
  }
  assert.equal(w.asked(), 1, "nothing more asked of the owner");
});

test("the switch off (the device's clock before HAND_OVER_FROM): nothing moved", async () => {
  const w = await setUp({ early: true });
  assert.equal(handOverState(w.inner, "ws"), null, "not this device's to hand over by itself");
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [null, null]);
});

test("another owner's device: not before 14 days from the genesis, then by itself", async () => {
  const w = await setUp({ mine: "second", genesisAt: T0 - 13 * DAY });
  assert.equal(handOverState(w.inner, "ws"), null, "the first owner's yet");
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [null, null], "nothing before 14 days");
  w.r.host.advance((DAY + 60) * 1000);
  assert.deepEqual(handOverState(w.inner, "ws"), { moving: true });
  await w.run(read(w.inner, "ws"));
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [w.gMe, w.gMe], "moved to s1's log");
  silent(w);
});

test("another owner's device at once where the genesis's person is no owner any more", async () => {
  const w = await setUp({ mine: "second", genesisAt: T0 - DAY, firstLowered: true });
  await w.run(read(w.inner, "ws"));
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [w.gMe, w.gMe]);
});

test("a workspace of 100 members and 3 stations handed over by itself: nothing said, the chain's list in force at each station and here", async () => {
  const w = await setUp({ crowd: 100, third: true });
  const before = w.d4Chain(w.chain);
  await w.run(read(w.inner, "ws"));
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [w.gMe, w.gMe, w.gMe], "moved at A, B and C");
  silent(w);
  await asTheChain(w, before, []);
});

// The `moved` waits for every station the chain names to have said to this device that it serves `bodies`, `logs`,
// `builds` and `carried` (the lead's decisions, 2026-11-14): one whose rules do not know `moved`, or that reads a moved
// chain otherwise, would let in by another state.
test("a station that does not say it serves what a moved chain is: nothing moved, handOverState names it, lock.handOver says so; it says so: moved", async () => {
  const w = await setUp({ old: ["B"] });
  assert.deepEqual(handOverState(w.inner, "ws"), { stations: [w.B] });
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [null, null], "nothing moved");
  const call = await w.hand();
  assert.equal(call.error?.code, "lock_stations_not_ready", "lock.handOver refuses so");
  assert.match(call.error?.message ?? "", /studio 2/);
  w.st.old.clear();
  await w.run(read(w.inner, "ws"));
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [w.gMe, w.gMe], "moved");
  silent(w);
});

test("a station that serves bodies, logs and builds and says nothing of carried: waited for and named; it says so: moved", async () => {
  const w = await setUp({ noCarried: ["B"] });
  assert.deepEqual(handOverState(w.inner, "ws"), { stations: [w.B] });
  const lines = texts(lockView(w.inner, "ws").upgrade);
  assert.equal(lines.length, 1);
  assert.match(lines[0]!, /^等待 station studio 2：请将它更新到最新版本并保持在线/);
  w.st.noCarried.clear();
  await w.run(read(w.inner, "ws"));
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [w.gMe, w.gMe], "moved");
});

test("a station whose GET /lock was never answered: the moved waits for it, moved once it is; one that said so before and is asleep now holds nothing up", async () => {
  const w = await setUp({ lockDown: ["B"] });
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(handOverState(w.inner, "ws"), { stations: [w.B] }, "B never said it");
  assert.equal((await w.stations.A.chain(null))?.state?.moved, undefined, "nothing moved");
  w.st.lockDown.clear();
  await w.run(read(w.inner, "ws"));
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [w.gMe, w.gMe], "moved once B said so");
  const v = await setUp({ early: true });
  v.st.down.add("B");
  assert.deepEqual(handOverState(v.inner, "ws"), null, "the switch off here: not by itself");
  assert.equal((await v.hand()).error, undefined, "B said so before");
  await v.run(read(v.inner, "ws"));
  assert.equal((await v.stations.A.chain(null))?.state?.moved, v.gMe, "moved at A, B asleep");
});

test("a station waited for taken out of the chain: no longer waited for, moved", async () => {
  const w = await setUp({ lockDown: ["B"] });
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(handOverState(w.inner, "ws"), { stations: [w.B] });
  w.after(w.signer, "station.remove", { key: w.B });
  await takeChain(w);
  await w.run(read(w.inner, "ws"));
  await w.run(read(w.inner, "ws"));
  assert.equal((await w.stations.A.chain(null))?.state?.moved, w.gMe, "moved at A");
  assert.equal(inForceOf(w.inner, "ws").f.stations.has(w.B), false, "B not in the state in force");
});

test("the app closed while the moved waited for a station: moved as it starts again and reads its lock, nobody asked", async () => {
  const w = await setUp({ lockDown: ["B"] });
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [null, null], "nothing moved yet");
  w.st.lockDown.clear();
  await w.restart();
  await w.run(read(w.inner, "ws"));
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await movedAt(w), [w.gMe, w.gMe], "moved as the core started again read its lock");
  silent(w);
});

// What the pages say of a handover (the owner, 2026-11-14: to people it is 「安全模式的升级」): the owner's device says
// which stations it waits for (the `lock` topic's `upgrade`), a sentence each, and the refusals say the same; never a
// member, a device or a button (nothing waits for a person, nothing asks); a pending `moved` is one row of its own; after
// the move, off and on again are the root's person's alone.
const TITLE = "安全模式有一项升级尚未完成";
/// The sentences of the `lock` topic's `upgrade`, a line each.
const texts = (u: unknown): string[] => ((u as { lines?: { text: string }[] } | undefined)?.lines ?? []).map((l) => l.text);

test("words: a station from before named, the refusal the same; a member not on a log, a device on the chain alone: no line", async () => {
  const v = await setUp({ old: ["B"] });
  const lines = texts(lockView(v.inner, "ws").upgrade);
  assert.equal(lines.length, 1);
  assert.match(lines[0]!, /^等待 station studio 2：请将它更新到最新版本并保持在线；已不再使用的话，请在它的页面上选择「从 workspace 移除」$/);
  const call = await v.hand();
  assert.equal(call.error?.code, "lock_stations_not_ready");
  assert.equal(call.error?.message, lines[0], "the refusal says the line");
  const w = await setUp({ more: ["notReady"], early: true });
  assert.equal(lockView(w.inner, "ws").upgrade, undefined, "the switch off: nothing shown");
  const u = await setUp({ more: ["notReady"], flag: false });
  assert.equal(lockView(u.inner, "ws").upgrade, undefined, "nothing waited for, no button: nothing shown");
});

// A station line says whether this person may update that station from here, as its own page offers its update (an
// owner or admin of its workspace, it online, its software updatable and newer, or its update failed; by its overview as
// the device last holds it), and how its update goes while it does (the owner, 2026-11-14: the page says what the
// upgrade waits for, and updates a station with one press).
const overviewOf = (w: Awaited<ReturnType<typeof setUp>>, station: string, own: Record<string, unknown> | null) =>
  w.inner.data.set({ topic: "overview", station } as never, own === null ? {} : { updates: [{ id: "station", name: "still.fail station", installed: true, ...own }] });

test("words: a station waited for, by its overview: updatable and newer, an owner's press; an admin's too; up to date, failed, a member, offline as the cloud says: as its own page offers", async () => {
  const w = await setUp({ old: ["B"] });
  const at = `ws/${w.B}`;
  const line = () => (lockView(w.inner, "ws").upgrade?.lines as Record<string, unknown>[])[0];
  assert.deepEqual(line(), { text: texts(lockView(w.inner, "ws").upgrade)[0], of: "station", station: at }, "nothing held of its overview: no press");
  overviewOf(w, at, { updatable: true, newer: true, version: "0.1.9000", latest: "0.1.9100" });
  assert.equal(line()?.canUpdate, true, "updatable and newer, this person an owner");
  overviewOf(w, at, { updatable: true, newer: false });
  assert.equal(line()?.canUpdate, undefined, "nothing newer: no press, as its page offers none");
  overviewOf(w, at, { updatable: true, state: "failed", message: "x" });
  assert.equal(line()?.canUpdate, true, "its update failed: pressed again, as its page's 重试");
  overviewOf(w, at, { updatable: false, newer: true });
  assert.equal(line()?.canUpdate, undefined, "not updatable from the pages");
  overviewOf(w, at, { state: "updating", percent: 41.6 });
  assert.deepEqual([line()?.updating, line()?.percent, line()?.canUpdate], [true, 42, undefined], "under way: how much of it, no press");
  overviewOf(w, at, { state: "updating" });
  assert.deepEqual([line()?.updating, line()?.percent], [true, undefined], "under way, how much not said");
  overviewOf(w, at, { updatable: true, newer: true });
  for (const [role, can] of [["admin", true], ["member", undefined]] as const) {
    w.inner.data.set({ topic: "workspace", workspace: "ws" } as never, { ...(w.inner.data.shared({ topic: "workspace", workspace: "ws" } as never) as object), role });
    assert.equal(line()?.canUpdate, can, `the workspace's ${role}`);
  }
  const stations = (w.inner.data.shared({ topic: "workspace", workspace: "ws" } as never) as { stations: Record<string, unknown>[] }).stations;
  w.inner.data.set({ topic: "workspace", workspace: "ws" } as never, { ...(w.inner.data.shared({ topic: "workspace", workspace: "ws" } as never) as object), role: "owner", stations: stations.map((s) => (s.id === w.B ? { ...s, online: false } : s)) });
  assert.equal(line()?.canUpdate, undefined, "offline: no press, as its page shows its software only online");
});

test("words: a handover's moved pending is one row, 完成安全模式的升级", async () => {
  const w = await setUp({ early: true });
  w.st.silent = true;
  const out = await w.hand();
  assert.ok((out.ok as { pending?: unknown } | null)?.pending, JSON.stringify(out.ok));
  const rows = lockView(w.inner, "ws").pending as { text: string }[];
  assert.equal(rows.length, 1, JSON.stringify(rows));
  assert.match(rows[0]!.text, /^完成安全模式的升级：已记下，等 .+ 上线后生效$/);
});

test("words: moved and turned off by the root's person: the page offers turning it on again, which asks and is pending in its own words", async () => {
  const w = await setUp({ early: true });
  assert.equal((await w.hand()).error, undefined);
  await w.run(read(w.inner, "ws"));
  assert.equal(lockView(w.inner, "ws").rootText, undefined, "the root's person: none");
  const off = await w.run(Effect.tryPromise({ try: () => w.r.ask("lock.disable", { workspace: "ws" }), catch: (e) => e as CoreError }));
  assert.equal(off.error, undefined, off.error?.message);
  await w.run(read(w.inner, "ws"));
  const page = lockView(w.inner, "ws");
  assert.equal(inForceOf(w.inner, "ws").said, "off");
  // (off, the root's log having said no `open`: the settings are still the chain's as it moved, which turning it on
  // again says; found by the moved workspace's round on real stations, 2026-11-14: an `open` with no keys made every
  // credential after it unknown)
  assert.deepEqual(inForceOf(w.inner, "ws").settings, { origins: ["https://stillfail.test"], rp_id: "stillfail.test", cloud_keys: w.g.keys }, "the chain's settings while off");
  assert.deepEqual({ locked: page.locked, notice: page.notice, onAgainText: page.onAgainText, members: (page.members as unknown[]).length, stations: (page.stations as { protected: boolean }[]).filter((s) => s.protected).length }, { locked: false, notice: true, onAgainText: "重新开启安全模式", members: 3, stations: 2 }, "what the topic says of a moved workspace that is off");
  w.st.silent = true;
  const on = await w.run(Effect.tryPromise({ try: () => w.r.ask("lock.open", { workspace: "ws" }), catch: (e) => e as CoreError }));
  assert.equal(on.error, undefined, on.error?.message);
  assert.equal(w.r.host.secureAsked.at(-1)?.reason, "重新开启安全模式");
  const rows = (lockView(w.inner, "ws").pending as { text: string }[]).map((x) => x.text);
  assert.ok(rows.some((x) => /^重新开启安全模式：已记下，等 .+ 上线后生效$/.test(x)), JSON.stringify(rows));
});

// This device let in by its person's own lock, which does not say the signer it keeps (one from before signers were
// said there), the workspace's lock naming another: no approval here makes it sign (views/pair.ts `waitingIn` asks it in
// no workspace), so the page offers none (`unsigned`), but says why and the press that says its signer on that lock.
test("words: on its person's own lock without its signer said there: why it does not sign and 验证 (lock.confirmSigner), no approval offered; said, gone", async () => {
  const w = await setUp({ early: true, mine: "otherKey" });
  const page = lockView(w.inner, "ws");
  assert.deepEqual([page.signs, page.me.unsigned ?? false, page.me.pair ?? null, page.me.stateText ?? null, page.me.confirmText ?? null], [false, false, null, "此设备需完成一次验证后才能成为受信任设备", "验证"]);
  const said = await w.run(Effect.tryPromise({ try: () => w.r.ask("lock.confirmSigner", { workspace: "ws" }), catch: (e) => e as CoreError }));
  assert.equal(said.error, undefined, said.error?.message);
  assert.equal(w.asked(), 1, "the person asked once");
  const after = lockView(w.inner, "ws");
  assert.deepEqual([after.me.unsigned ?? false, after.me.stateText ?? null, after.me.confirmText ?? null], [false, null, null], "said: nothing more to say");
});

// A device the chain as it moved carries, not on its person's log, taken off by its person's own device after the move
// (the owner, 2026-11-14: a lost device can be taken off): one ask, put on their log under a key thrown away and taken
// off by it (personal-lock.ts `removeCarried`), then out at every station and here.
test("a carried app device of this device's person taken off after the move: one ask, out at A, B and here, nothing of it in force", async () => {
  const w = await setUp({ early: true });
  const phone = dev();
  w.after(w.signer, "device", { id: phone.base.hex, sub: "s1", kind: "app", label: "s1's phone", sign_key: phone.signer.id });
  await takeChain(w);
  await w.run(read(w.inner, "ws"));
  assert.equal((await w.hand()).error, undefined);
  await w.run(read(w.inner, "ws"));
  assert.equal(inForceOf(w.inner, "ws").f.devices.get(phone.base.hex)?.by, "chain", "carried");
  const out = await w.run(Effect.tryPromise({ try: () => w.r.ask("lock.removeDevice", { workspace: "ws", device: phone.base.hex }), catch: (e) => e as CoreError }));
  assert.equal(out.error, undefined, out.error?.message);
  assert.equal(w.asked(), 1, "one ask");
  const log = w.inner.adb.personal().entries("s1");
  assert.deepEqual(log.slice(-2).map((e) => e.kind), ["device", "device.remove"], "put on and taken off their log");
  for (const c of Object.values(w.stations)) await c.takeLock([...w.chain]);
  await w.run(read(w.inner, "ws"));
  assert.equal(inForceOf(w.inner, "ws").f.devices.has(phone.base.hex), false, "out here");
  for (const [n, c] of Object.entries(w.stations)) {
    assert.equal((await c.locked(null))?.state?.devices.has(phone.base.hex), false, `out at ${n}`);
    const p = admitted("s1", phone, "owner");
    assert.equal((await c.inLock(p, "owner", p.viewer.device)).ok, false, `refused by ${n}`);
  }
});

// A member the chain bound to no log, this device theirs (the lead, 2026-11-14: a carried member with no log of their
// own does for themselves what they did before the move): what they do on their own lock with one ask binds them to it in
// that same ask (`bind`, proved by this device's signer the chain names, views/lock.ts `bindsFor`, personal-lock.ts
// `#addBinds`), and so does a change of the list they make (`sayMoved`). s0 moves the chain; s1 is its second owner.
async function unboundMoved(o: Opts = {}) {
  const w = await setUp({ early: true, mine: "second", unbound: true, ...o });
  const phone = w.s1Phone;
  if (o.noLog !== true) {
    w.after(w.first.app.signer, "moved", { root: w.first.genesis });
    for (const c of Object.values(w.stations)) await c.takeLock([...w.chain], null, true);
  }
  await w.run(read(w.inner, "ws"));
  const f = inForceOf(w.inner, "ws").f;
  assert.equal(f.persons.has("s1"), false, "s1 bound to no log");
  assert.equal(f.devices.get(w.base.hex)?.by, "chain", "this device carried");
  return { w, phone };
}
const boundAt = async (w: Awaited<ReturnType<typeof setUp>>) => [
  inForceOf(w.inner, "ws").f.persons.get("s1"),
  ...(await Promise.all(Object.values(w.stations).map(async (c) => (await c.locked())!.state!.persons.get("s1")))),
];

test("an unbound member takes off a carried phone of theirs: one ask, bound to their own log in it, the phone out here and at both stations", async () => {
  const { w, phone } = await unboundMoved();
  const out = await w.run(Effect.tryPromise({ try: () => w.r.ask("lock.removeDevice", { workspace: "ws", device: phone.base.hex }), catch: (e) => e as CoreError }));
  assert.equal(out.error, undefined, out.error?.message);
  assert.equal(w.asked(), 1, "one ask");
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await boundAt(w), [w.gMe, w.gMe, w.gMe], "bound to their log, here and at A and B");
  assert.equal(inForceOf(w.inner, "ws").f.devices.has(phone.base.hex), false, "the phone out");
  for (const c of Object.values(w.stations)) assert.equal((await c.locked())!.state!.devices.has(phone.base.hex), false, "out at the stations");
  assert.ok(inForceOf(w.inner, "ws").f.devices.has(w.base.hex), "this device still in");
});

test("an unbound member takes off their web page the chain carries: one ask, bound in it, the page out", async () => {
  const { w } = await unboundMoved({ myWeb: true });
  assert.equal(inForceOf(w.inner, "ws").f.devices.get(w.WEB.hex)?.by, "chain");
  const out = await w.run(Effect.tryPromise({ try: () => w.r.ask("lock.removeDevice", { workspace: "ws", device: w.WEB.hex }), catch: (e) => e as CoreError }));
  assert.equal(out.error, undefined, out.error?.message);
  assert.equal(w.asked(), 1, "one ask");
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await boundAt(w), [w.gMe, w.gMe, w.gMe]);
  assert.equal(inForceOf(w.inner, "ws").f.devices.has(w.WEB.hex), false, "the page out");
});

test("an unbound owner takes a member out: one ask, bound in it, the member out by their statement", async () => {
  const { w } = await unboundMoved();
  // (the cloud's part of the call, past the lock: it takes the removal)
  stationLater(w.r.host, (req) => (req.method === "DELETE" && new URL(req.url).pathname === "/v1/workspaces/ws/members/r3" ? Promise.resolve(jsonResponse(200, {})) : undefined));
  const out = await w.run(Effect.tryPromise({ try: () => w.r.ask("workspace.removeMember", { account: "s1", workspace: "ws", member: "r3" }), catch: (e) => e as CoreError }));
  assert.equal(out.error, undefined, out.error?.message);
  assert.equal(w.asked(), 1, "one ask");
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await boundAt(w), [w.gMe, w.gMe, w.gMe]);
  assert.equal(inForceOf(w.inner, "ws").f.members.has("r3"), false, "r3 out");
  for (const c of Object.values(w.stations)) assert.equal((await c.locked())!.state!.members.has("r3"), false, "out at the stations");
});

// A member the chain bound to no log who has no log of their own at all, at their app's first read of the moved chain
// (the lead, 2026-11-14). Whom it stands for: a member with another app on the chain that never said the key of a lock
// of one's own (a stale laptop, or one that seals nothing), while which their app in hand begins none (views/lock.ts
// `ownLockOnce`'s `waiting`) and which holds no move back; and an app not opened since before own logs, which no move
// waits for. An app of today that is let in alone begins its person's log by itself before any
// move (`ownLockOnce`), so this is not that one. What they do for themselves on their own devices begins their log in
// that act's one ask, as views/pair.ts `ownLogFor` begins a newcomer's, binds them to it (`bind`) and then does it
// (personal-lock.ts `seedFor`): nobody else involved, nothing asked more than before the move. (locks-moved.ts round
// 23 holds the first of them on real stations.)
async function noLog(o: Opts = {}) {
  const { w, phone } = await unboundMoved({ noLog: true, ...o });
  assert.equal(w.inner.adb.personal().standing("s1"), "none", "no log of their own");
  return { w, phone, before: w.asked(), reasons: () => w.r.host.secureAsked.map((a) => a.reason) };
}
/// After the act: s1 bound to the log just begun here and at both stations, that log this device's.
const begunAndBound = async (w: Awaited<ReturnType<typeof setUp>>) => {
  const log = w.inner.adb.personal().root("s1");
  assert.ok(log !== null, "their log begun");
  assert.equal(w.inner.adb.personal().standing("s1"), "member", "this device on it");
  await w.run(read(w.inner, "ws"));
  assert.deepEqual(await boundAt(w), [log, log, log], "bound to it here and at A and B");
  return log!;
};

test("no log at all: taking off a carried phone of theirs begins their log in the one ask, binds them to it, and takes the phone off here and at both stations", async () => {
  const { w, phone, before, reasons } = await noLog();
  const out = await w.run(Effect.tryPromise({ try: () => w.r.ask("lock.removeDevice", { workspace: "ws", device: phone.base.hex }), catch: (e) => e as CoreError }));
  assert.equal(out.error, undefined, out.error?.message);
  assert.equal(w.asked() - before, 1, `one ask (${JSON.stringify(reasons().slice(before))})`);
  await begunAndBound(w);
  assert.equal(inForceOf(w.inner, "ws").f.devices.has(phone.base.hex), false, "the phone out");
  for (const c of Object.values(w.stations)) assert.equal((await c.locked())!.state!.devices.has(phone.base.hex), false, "out at the stations");
  assert.ok(inForceOf(w.inner, "ws").f.devices.has(w.base.hex), "this device still in");
});

test("no log at all: approving their own web page face to face begins their log in the one ask, binds them, and lets the page in at both stations", async () => {
  const { w, before, reasons } = await noLog();
  const page = ed();
  const prompts = await w.r.watch({ topic: "lockPrompts" });
  const [trusted, conn] = await pipe();
  w.inner.runner.fork(serveTrusted(w.inner, page.hex, w.base.hex, trusted));
  const first = await w.run(Effect.andThen(conn.send({ t: "hello", v: 1, workspaces: [{ ws: "ws", credential: w.g.credential("ws", page.hex, "s1") }], kind: "web", label: "Chrome", sign_key: null }), conn.next()));
  assert.deepEqual(first.ok, { t: "code", workspaces: ["ws"] }, "a code shown here, by their own device");
  const code = ((await prompts()).pairing as { device: string; code: string }[]).find((p) => p.device === page.hex)!.code;
  const done = await w.run(tryOne(w.inner, { id: w.base.hex, d: conn, workspaces: ["ws"] }, page.hex, code));
  assert.equal(done.error, undefined, done.error?.message);
  assert.equal(w.asked() - before, 1, `one ask (${JSON.stringify(reasons().slice(before))})`);
  await begunAndBound(w);
  for (const c of Object.values(w.stations)) assert.equal((await c.locked())!.state!.devices.get(page.hex)?.kind, "web", "the page in at the stations");
});

test("no log at all: approving their own new app face to face (it asks to join their lock) begins their log in the one ask, binds them, and puts it on: in at both stations by its signer", async () => {
  const { w, before, reasons } = await noLog();
  const k = key(7011), id = key(7111).hex, SIGNS = `ed25519:${"13".repeat(32)}`;
  const prompts = await w.r.watch({ topic: "lockPrompts" });
  const [trusted, conn] = await pipe();
  w.inner.runner.fork(serveTrusted(w.inner, id, w.base.hex, trusted));
  const first = await w.run(Effect.andThen(conn.send({ t: "hello", v: 1, workspaces: [{ ws: "ws", credential: w.g.credential("ws", id, "s1") }], kind: "app", label: "Pixel", sign_key: SIGNS, personal: { subs: ["s1"], key: k.id } }), conn.next()));
  assert.deepEqual(first.ok, { t: "code", workspaces: ["person:s1"] }, "a code shown here, by their own device");
  const code = ((await prompts()).pairing as { device: string; code: string }[]).find((p) => p.device === id)!.code;
  const done = await w.run(tryOne(w.inner, { id: w.base.hex, d: conn, workspaces: ["person:s1"] }, id, code));
  assert.equal(done.error, undefined, done.error?.message);
  assert.equal(w.asked() - before, 1, `one ask (${JSON.stringify(reasons().slice(before))})`);
  await begunAndBound(w);
  assert.ok(w.inner.adb.personal().entries("s1").some((e) => e.kind === "device" && (e.body as { id: string }).id === id), "on their log");
  for (const c of Object.values(w.stations)) assert.equal((await c.locked())!.state!.devices.get(id)?.sign_key, SIGNS, "in at the stations by its signer");
});

test("no log at all: taking off their web page the chain carries begins their log in the one ask, binds them, and takes the page off", async () => {
  const { w, before, reasons } = await noLog({ myWeb: true });
  assert.equal(inForceOf(w.inner, "ws").f.devices.get(w.WEB.hex)?.by, "chain");
  const out = await w.run(Effect.tryPromise({ try: () => w.r.ask("lock.removeDevice", { workspace: "ws", device: w.WEB.hex }), catch: (e) => e as CoreError }));
  assert.equal(out.error, undefined, out.error?.message);
  assert.equal(w.asked() - before, 1, `one ask (${JSON.stringify(reasons().slice(before))})`);
  await begunAndBound(w);
  for (const c of Object.values(w.stations)) assert.equal((await c.locked())!.state!.devices.has(w.WEB.hex), false, "the page out at the stations");
});
