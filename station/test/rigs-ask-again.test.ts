// A rig's reads asked again once where its process stopped or handed over as they were asked (rigs/module.ts
// `askRig`): a whole station made one that only runs tasks hands over to its rig process just after it is listed so,
// and a read of its record then failed as "no station reached". Only reads are asked again, and only once.
import assert from "node:assert/strict";
import { test } from "node:test";
import { PeerGone, PeerStopped } from "../src/mesh/peer.ts";
import { askRig } from "../src/rigs/module.ts";
import type { Json } from "../src/store/store.ts";

const RIG = "aa".repeat(32);

/// An ask that fails with each of `failures` in turn, then answers what it was asked; what it was asked, in order.
function asking(...failures: Error[]) {
  const asked: string[] = [];
  const ask = async (rig: string, request: Json): Promise<Json> => {
    asked.push(`${rig.slice(0, 4)} ${request.method}`);
    const failure = failures.shift();
    if (failure !== undefined) throw failure;
    return { answered: request.method };
  };
  return { ask, asked };
}

test("a read that meets the rig's process handing over is asked again once and answered", async () => {
  for (const method of ["rig.log", "rig.describe", "rig.proof"]) {
    const { ask, asked } = asking(new PeerStopped());
    assert.deepEqual(await askRig(ask, RIG, { method, workspace: "ws" }), { answered: method });
    assert.deepEqual(asked, [`aaaa ${method}`, `aaaa ${method}`]);
  }
});

test("a read that meets it twice fails with the second, asked no more", async () => {
  const second = new PeerStopped();
  const { ask, asked } = asking(new PeerStopped(), second);
  await assert.rejects(askRig(ask, RIG, { method: "rig.log", workspace: "ws" }), (e) => e === second);
  assert.equal(asked.length, 2);
});

test("what changes the rig is never asked again: the process that stopped may have taken it", async () => {
  for (const method of ["rig.grant", "rig.revoke", "rig.settings", "rig.full", "rig.join", "rig.added", "remote.start"]) {
    const stopped = new PeerStopped();
    const { ask, asked } = asking(stopped);
    await assert.rejects(askRig(ask, RIG, { method, workspace: "ws" }), (e) => e === stopped);
    assert.deepEqual(asked, [`aaaa ${method}`]);
  }
});

test("a read failing otherwise (gone, refused, late) is not asked again", async () => {
  for (const failure of [new PeerGone(), new Error("peer request timed out"), new Error("unknown method")]) {
    const { ask, asked } = asking(failure);
    await assert.rejects(askRig(ask, RIG, { method: "rig.log", workspace: "ws" }), (e) => e === failure);
    assert.equal(asked.length, 1);
  }
});
