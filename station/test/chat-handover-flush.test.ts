// What a chat handed over took is written out to the drive once a placing (replica/handover.ts `#place`, sending.ts
// `flushOnce`), not a file at a time: once each placing, however many files came, before the sender is told it is
// placed; a flush that fails fails the hand-over; one still coming as its machine starts again is dropped there, what
// it took maybe never on the drive. Its stations are move-world.ts's.
import assert from "node:assert/strict";
import { existsSync, writeFileSync } from "node:fs";
import { join, sep } from "node:path";
import { test } from "node:test";
import { say } from "../src/sessions/lifecycle.ts";
import { flushesOnce } from "../src/replica/sending.ts";
import { WS, A, B, world, stillfailChat, filesOf } from "./move-world.ts";

type Json = any;
/// Time on the test's clock moved on `ms`, a beat at a time, each station brought to rest between.
async function pass(w: ReturnType<typeof world>, ms: number) {
  for (let t = 0; t < ms; t += 5_000) {
    await w.t.adjust(5_000);
    for (const s of w.stations.values()) await s.rig.quiet();
  }
}

const skip = flushesOnce ? false : "no flush of a file system at once on this machine: each file is flushed as it is taken";

test("a hand-over's placings flush once each, before each is told placed, as many files as it has", { skip }, async () => {
  for (const n of [30, 60]) {
    const w = world();
    const a = w.get(A);
    const b = w.get(B);
    const { key } = await stillfailChat(a);
    const room = a.rig.session(key).workspace;
    for (let k = 0; k < n; k++) writeFileSync(join(room, `f${k}.md`), `file ${k} of ${n}`);
    const roomThere = room.replace(a.rig.dir, b.rig.dir);
    // (each flush, and each placing's end as it is told to the sender, in the order they came)
    const order: string[] = [];
    let puts = 0;
    w.tamper((to, r) => {
      if (to === B && r.method === "handover.put") puts++;
      if (to === A && r.method === "move.told" && r.ended === true && String(r.told).startsWith("place:")) order.push(`told ${String(r.told).split(":")[2]}`);
      return r;
    });
    b.flushing = async (dir) => {
      assert.ok(dir.includes(`${sep}replica${sep}handover${sep}in${sep}`), dir);
      // (after its files are placed)
      assert.ok(existsSync(join(roomThere, `f${n - 1}.md`)), "flushed after the files are placed");
      order.push("flush");
    };
    const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
    await w.quiet();
    assert.equal(out.failed, null, JSON.stringify(out));
    // (its room's files a pack a batch of what is asked (`lackMost`, 50 here), with its list and the index: a request a
    // file before packs)
    assert.ok(puts >= 1 && puts < n / 5, `${n}: its files sent in packs (${puts} requests)`);
    assert.deepEqual(order, ["flush", "told first", "flush", "told held"], `${n} files: one flush a placing, each before it is told`);
  }
});

test("a flush that fails fails the hand-over: the chat goes on here and nothing of it is there", { skip }, async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  writeFileSync(join(a.rig.session(key).workspace, "more.md"), "sent");
  let flushes = 0;
  b.flushing = async () => {
    flushes++;
    throw new Error("the test's flush failed");
  };
  const error = await a.moves.handover.handOver(key, B).then(() => null, (e: Error) => e.message);
  await w.quiet();
  assert.equal(flushes, 1, "the first placing's");
  assert.notEqual(error, null, "refused");
  assert.match(error!, /goes on here|在这里继续/);
  assert.equal(a.rig.store.handedTo(key), null);
  assert.equal(a.rig.hub.handedOver(key), false, "not held here");
  assert.equal(b.rig.store.getSession(key), null, "nothing of it there");
  assert.deepEqual(b.moves.handover.ins().filter((i: Json) => i.step !== "dropped").map((i: Json) => i.step), [], "nothing left half there");
  say(a.rig.hub, thread, "p@x", "still here?");
  await w.quiet();
  assert.ok(a.rig.claude.last().prompts.join("\n").includes("still here?"), "a turn here");
});

test("a hand-over still coming as the machine it goes to started again is dropped there, before it answers anything: the sender's turn fails in words, the chat goes on here, and handed over again it arrives whole", { skip }, async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const room = a.rig.session(key).workspace;
  for (let k = 0; k < 5; k++) writeFileSync(join(room, `f${k}.md`), `file ${k}`);
  const roomThere = room.replace(a.rig.dir, b.rig.dir);
  // (its first placing's files placed there and not yet flushed: the machine stops there)
  const at = Promise.withResolvers<void>();
  b.flushing = () => (at.resolve(), new Promise<void>(() => {}));
  const turn = a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  // (a turn that ends first never reached it)
  await Promise.race([at.promise, turn.then((o) => assert.fail(`the turn ended before the first placing's flush: ${JSON.stringify(o.failed)}`))]);
  assert.ok(existsSync(join(roomThere, "f4.md")), "placed there, not flushed");
  const id = b.moves.handover.ins()[0]!.id;
  // (B's machine started again: another boot, an hour on)
  await b.moves.close();
  b.flushing = undefined;
  b.boot = 3_600_000;
  b.moves = b.make();
  await b.moves.start();
  await pass(w, 60_000);
  const out = await turn;
  await w.quiet();
  assert.match(out.failed?.error ?? "", /dropped there|在那边已经撤回/, JSON.stringify(out.failed));
  assert.deepEqual(b.moves.handover.ins().map((i: Json) => [i.id, i.step]), [[id, "dropped"]], "dropped there");
  assert.equal(existsSync(join(b.rig.dir, "replica", "handover", "in", id)), false, "nothing of what it took left there");
  assert.equal(existsSync(roomThere), false, "its room there taken out");
  assert.equal(b.rig.store.getSession(key), null, "no row of it there");
  assert.equal(a.rig.store.handedTo(key), null, "it goes on here");
  assert.equal(a.rig.hub.handedOver(key), false, "not held here");
  // (handed over again: it arrives whole)
  const again = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(again.failed, null, JSON.stringify(again.failed));
  assert.deepEqual(filesOf(roomThere), filesOf(room), "its room whole there");
  assert.equal(a.rig.store.handedTo(key)?.station, B);
});
