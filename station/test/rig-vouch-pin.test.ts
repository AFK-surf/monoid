// A rig (a station that only runs tasks) that joined its workspace before safe mode was turned on pins no lock and was
// named none: the control plane's frames alone never give it one (presence.ts `syncLock`), so it stayed out of safe
// mode for good, and no station sent it a task (FB-45). Its person checking its code in the app names the workspace
// lock's entry in what they sign (rig-form.ts `AddBody` `lock`): the rig takes it only from a key on its person's own
// lock (its one root of trust: the add itself, or `pin` where the add is the workspace lock's), names it to pin as
// `enroll --lock` does, asks the control plane for it at once and pins the chain that holds it, the moved one too. A
// lock pinned or named already is never replaced from here.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mock, test } from "node:test";
import { type AddBody, type Kind, signedBytes } from "../../client/core-ts/src/rig-form.ts";
import { entryHash } from "../../shared/lock.ts";
import { applyState, pendingAsks, pendingLock, planeTeller } from "../src/cloud/presence.ts";
import { Cloud, pendingLockPath, writeState } from "../src/cloud/state.ts";
import { PeerBus } from "../src/mesh/bus.ts";
import { wall } from "../src/ops/fibers.ts";
import { Rig } from "../src/rig/module.ts";
import { WS, type Key, ed, world } from "./lock-moved-world.ts";

const NOW = 2_000_000;
mock.method(wall, "now", () => NOW * 1000);
const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest();
const says = <B>(kind: Kind, body: B, by: Key) => ({ body, sig: { key: by.id, sig: by.sign(Buffer.from(signedBytes(kind, body, sha256))) } });

/// alice's rig, joined before the workspace's safe mode (no lock pinned, none named), the plane holding the lock (its
/// head said in a frame), on the peer bus as a station asks it; what it sends the plane.
function setUp(pinned: unknown[] | null = null) {
  const w = world();
  const rig = ed();
  const data = mkdtempSync(join(tmpdir(), "rig-vouch-"));
  writeState(data, {
    origin: "https://app.still.fail", station: rig.hex, workspace: WS, workspace_name: "Team", name: "build-box", relay_url: "", relay_urls: [],
    grant_keys: { keys: [] }, peers: w.stations.map((s) => ({ id: s.hex })), revocations: [],
    rig: { owner: "alice", owner_email: "alice@x", owner_name: "alice", person: w.alice.genesis },
  });
  const cloud = new Cloud(data, false);
  if (pinned !== null) cloud.takeLock(pinned as never);
  cloud.planeLockSeq = 0;
  const sent: any[] = [];
  const { tell } = planeTeller(cloud, (f) => void sent.push(f), () => true);
  cloud.listen(() => tell());
  const bus = new PeerBus({ sleep: async () => {} });
  const made = new Rig({ data, cloud, bus, busy: () => false, stop: () => {}, running: () => [] });
  const body = (lock: string | null): AddBody => ({ v: 1, sub: "alice", ws: WS, rig: rig.hex, at: NOW, ...(lock !== null ? { lock } : {}) });
  const added = (request: Record<string, unknown>) => bus.handle(WS, w.stations[0]!.hex, { method: "rig.added", ...request });
  return { w, rig, data, cloud, sent, made, body, added, close: () => made.close() };
}

test("checked by its person on their own lock: the rig names the workspace's lock, asks the plane for it at once and pins it (FB-45)", async () => {
  const t = setUp();
  try {
    const lock = entryHash(t.w.first);
    assert.equal(pendingLock(t.data), null);
    assert.deepEqual(pendingAsks(t.cloud, new Set()), [], "nothing named: nothing asked");
    // `how === "person"`: the add signed by a key on alice's own lock, her lock with it.
    assert.deepEqual(await t.added({ signed: says("add", t.body(lock), t.w.alice.app.key), chain: t.w.alice.entries }), { ok: true });
    assert.equal(pendingLock(t.data), lock, "named, as `enroll --lock` names one");
    assert.deepEqual(t.sent.filter((f) => f.type === "lock.get"), [{ type: "lock.get", after: -1 }], "asked for once, at once");
    assert.deepEqual(t.made.grants.proof(WS)?.body.lock, lock, "the add kept to show the stations");
    // The plane brings it: pinned, nothing named any more.
    applyState(t.cloud, JSON.stringify({ type: "lock", entries: [t.w.first] }));
    assert.equal(t.cloud.chain(null)?.state?.genesis, lock);
    assert.ok(t.cloud.locked() !== null, "in safe mode");
  } finally {
    await t.close();
  }
});

test("the add signed by the workspace's lock: pinned only by a `pin` of the person's own lock; a forged one refused, none of the plane's taken (FB-45)", async () => {
  const t = setUp();
  try {
    const lock = entryHash(t.w.first);
    // `how === "lock"`: the add signed with alice's app's key on the workspace's lock, which the rig does not judge;
    // alone it names nothing to pin.
    const signed = says("add", t.body(lock), t.w.alice.app.signer);
    assert.deepEqual(await t.added({ signed }), { ok: true });
    assert.equal(pendingLock(t.data), null, "the workspace lock's key is not the rig's to trust");
    assert.equal(t.sent.length, 0);
    // A `pin` by a key on no lock of alice's, or naming another rig: refused, nothing named.
    const stranger = ed();
    await assert.rejects(t.added({ signed, pin: says("add", t.body(lock), stranger), chain: t.w.alice.entries }), /not on this rig's person's own lock/);
    await assert.rejects(t.added({ signed, pin: says("add", { ...t.body(lock), rig: "dd".repeat(32) }, t.w.alice.app.key), chain: t.w.alice.entries }), /another rig or workspace/);
    // Another person's lock brought as alice's: refused.
    await assert.rejects(t.added({ signed, pin: says("add", t.body(lock), t.w.bob.app.key), chain: t.w.bob.entries }), /not the one this rig's person pinned/);
    assert.equal(pendingLock(t.data), null);
    // The plane's chain brought meanwhile: not taken (nothing named to pin).
    applyState(t.cloud, JSON.stringify({ type: "lock", entries: [t.w.first] }));
    assert.equal(t.cloud.chain(null), null);
    // Her own lock's `pin`: named and asked for.
    assert.deepEqual(await t.added({ signed, pin: says("add", t.body(lock), t.w.alice.app.key), chain: t.w.alice.entries }), { ok: true });
    assert.equal(pendingLock(t.data), lock);
    assert.deepEqual(t.sent.filter((f) => f.type === "lock.get"), [{ type: "lock.get", after: -1 }]);
    applyState(t.cloud, JSON.stringify({ type: "lock", entries: [t.w.first] }));
    assert.equal(t.cloud.chain(null)?.state?.genesis, lock);
  } finally {
    await t.close();
  }
});

test("a moved workspace's lock: named by its genesis, the moved chain pinned, the rig waiting for its state as one enrolled with it (FB-45)", async () => {
  const t = setUp();
  try {
    const lock = entryHash(t.w.first);
    await t.added({ signed: says("add", t.body(lock), t.w.alice.app.key), chain: t.w.alice.entries });
    assert.equal(pendingLock(t.data), lock);
    applyState(t.cloud, JSON.stringify({ type: "lock", entries: [t.w.first, t.w.moved] }));
    assert.equal(t.cloud.chain(null)?.state?.head, entryHash(t.w.moved), "the moved chain pinned");
    assert.equal(t.cloud.waiting(null), true, "waiting for the logs and bodies, as rig-moved.test.ts goes on");
  } finally {
    await t.close();
  }
});

test("a lock pinned or named already is never replaced by an add, nor one named by a statement that names none (FB-45)", async () => {
  {
    // Pinned: another workspace chain's hash named, nothing written.
    const t = setUp();
    try {
      t.cloud.takeLock([t.w.first]);
      const other = world();
      await t.added({ signed: says("add", t.body(entryHash(other.first)), t.w.alice.app.key), chain: t.w.alice.entries });
      assert.equal(existsSync(pendingLockPath(t.data)), false);
      assert.equal(t.cloud.chain(null)?.state?.genesis, entryHash(t.w.first));
    } finally {
      await t.close();
    }
  }
  {
    // Named (`enroll --lock`): kept as it was.
    const t = setUp();
    try {
      const named = entryHash(t.w.first);
      writeFileSync(pendingLockPath(t.data), JSON.stringify({ hash: named }));
      await t.added({ signed: says("add", t.body(entryHash(world().first)), t.w.alice.app.key), chain: t.w.alice.entries });
      assert.equal(JSON.parse(readFileSync(pendingLockPath(t.data), "utf8")).hash, named);
    } finally {
      await t.close();
    }
  }
  {
    // An add from before (no `lock`): kept to show, nothing named.
    const t = setUp();
    try {
      assert.deepEqual(await t.added({ signed: says("add", t.body(null), t.w.alice.app.key), chain: t.w.alice.entries }), { ok: true });
      assert.equal(pendingLock(t.data), null);
      assert.ok(t.made.grants.proof(WS) !== null);
    } finally {
      await t.close();
    }
  }
});
