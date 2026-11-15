// What a hand-over costs on a station that keeps the records of many chats' trips (replica/handover.ts): a chat handed
// over and brought home looks only at the records of its own sessions (`#outsOf`, `#insOf`, what is coming and what is
// owed), never at all those a station keeps. A whole move back showed each chat slower by the chats already back (4 to
// 79 ms a chat over 2,384, drill 31): each arrival walked every record, and every ended one against every other.
import assert from "node:assert/strict";
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { A, B, WS, stillfailChat, world } from "./move-world.ts";

type Json = any;

/// What A's hand-over of a fresh chat to B and back looks at of A's records, A keeping besides the records of `n` other
/// chats' trips there and back (each ended where it left, and shown where it came home), as a chat moved about leaves
/// them.
async function lookedWith(n: number): Promise<{ start: number; there: number; back: number; kept: { outs: number; ins: number } }> {
  const w = world();
  const a = w.get(A);
  const { key } = await stillfailChat(a);
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  assert.equal((await a.moves.scheduler.back(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  // (the records that trip left here, copied as other chats' trips)
  const records = join(a.rig.dir, "replica", "handover");
  for (const side of ["out", "in"]) {
    const [file] = readdirSync(join(records, side)).filter((f) => f.endsWith(".json"));
    assert.ok(file !== undefined, `a record of the trip ${side}`);
    const text = readFileSync(join(records, side, file), "utf8");
    const was = JSON.parse(text) as Json;
    for (let i = 0; i < n; i++) {
      const copy = JSON.parse(text.split(JSON.stringify(key).slice(1, -1)).join(`other-${i}`)) as Json;
      copy.id = `${String(was.id).slice(0, 40)}-n${i}`;
      writeFileSync(join(records, side, `${copy.id}.json`), JSON.stringify(copy));
    }
  }
  await a.moves.close();
  a.moves = a.make();
  await a.moves.start();
  await w.quiet();
  // (a start looks at each record once, what is done for each chat by its own records: as many again as there are)
  const start = a.moves.handover.looked();
  const kept = { outs: a.moves.handover.outs().length, ins: a.moves.handover.ins().length };
  // A fresh chat there and back.
  const { key: fresh } = await stillfailChat(a);
  const before = a.moves.handover.looked();
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: fresh })).failed, null);
  await w.quiet();
  const there = a.moves.handover.looked() - before;
  assert.equal((await a.moves.scheduler.back(WS, B, { module: "chats", item: fresh })).failed, null);
  await w.quiet();
  const back = a.moves.handover.looked() - before - there;
  assert.equal(a.rig.store.handedTo(fresh), null, "home again");
  return { start, there, back, kept };
}

test("a chat handed over and brought home looks at the records of its own sessions: as many at 30 other chats' trips kept as at 300; a start, at each record once", async () => {
  const few = await lookedWith(30);
  const many = await lookedWith(300);
  assert.ok(many.kept.outs > 300 && many.kept.ins > 300, `the records kept: ${JSON.stringify(many.kept)}`);
  assert.ok(few.there > 0 && few.back > 0, `counted: ${JSON.stringify(few)}`);
  assert.ok(many.start < 20 * few.start, `a start's looking grows as the records do, not as their square: ${few.start} at 30, ${many.start} at 300`);
  assert.deepEqual({ there: many.there, back: many.back }, { there: few.there, back: few.back }, `looked at with 30 kept: ${JSON.stringify(few)}, with 300: ${JSON.stringify(many)}`);
});
