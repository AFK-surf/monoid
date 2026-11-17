// What a move would send of each chat, known before it starts (move/sizes.ts): sized by the move's own gathering walk,
// kept a line a session against the session as it was, measured again only where that changed; a whole move refused
// before anything is held where what it would add there does not leave the floor free, counting what the other station
// has in place already (a room left there by a retirement); each chat refused the same way by what it lacks there.
import assert from "node:assert/strict";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { type Sized, gatherSoon, sizesSoon } from "../src/replica/carry.ts";
import { FLOOR_MIN } from "../src/replica/handover.ts";
import { moved } from "../src/replica/restore.ts";
import { SIZES_BATCH, Sizes } from "../src/move/sizes.ts";
import { say } from "../src/sessions/lifecycle.ts";
import { WS, A, B, world, endTurn, stillfailChat } from "./move-world.ts";

type Json = any;

const temp = () => mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "move-sizes-"));

for (const n of [30, 3_000]) {
  test(`a plan read of ${n} chats measures each once; read again with nothing changed it looks at no room, after a start too; one changed is measured alone`, async () => {
    const data = temp();
    const asked: string[][] = [];
    const measure = async (keys: string[]): Promise<Sized[]> => {
      asked.push(keys);
      return keys.map((key) => ({ key, room: `/r/${key}`, transcripts: [], bytes: 1_000, files: 1, complete: true }));
    };
    const ids = Array.from({ length: n }, (_, i) => `chat:c-${i}`);
    const read = (s: Sizes, stamp: (id: string) => string) => {
      for (const id of ids) s.seen(id, [{ key: id, stamp: stamp(id) }]);
    };
    const sizes = new Sizes({ data, measure });
    read(sizes, () => "1/");
    await sizes.settled();
    assert.equal(asked.flat().length, n, "each measured once");
    assert.ok(asked.every((b) => b.length <= SIZES_BATCH), "a batch at a time");
    assert.deepEqual(sizes.sum(ids), { bytes: 1_000 * n, known: n, of: n, measuring: 0, atLeast: false });
    // (read again, nothing changed: no room looked at)
    const before = asked.length;
    read(sizes, () => "1/");
    await sizes.settled();
    assert.equal(asked.length, before, "nothing measured again");
    // (a start: the lines read back, nothing measured)
    const again = new Sizes({ data, measure });
    await new Promise<void>((r) => setImmediate(r));
    read(again, () => "1/");
    await again.settled();
    assert.equal(asked.length, before, "nothing measured after a start");
    // (one chat's turn ended since: it alone)
    read(again, (id) => (id === ids[7] ? "2/" : "1/"));
    assert.equal(again.sum(ids).measuring, 1, "said as being measured");
    await again.settled();
    assert.deepEqual(asked.slice(before), [[ids[7]]]);
  });
}

test("a chat's size is what its move would gather, measured again as its turn ends, as it is archived and as a job of it starts or ends", async () => {
  const w = world();
  const a = w.get(A);
  const { key, thread } = await stillfailChat(a);
  writeFileSync(join(a.rig.session(key).workspace, "big.bin"), Buffer.alloc(64 * 1024, 7));
  const plan = async () => {
    await a.moves.scheduler.plan(WS, B);
    await a.moves.sizes.settled();
  };
  await plan();
  const g = await gatherSoon(a.rig.dir, join(a.rig.dir, "stillfail.db"), WS, true, join(a.rig.dir, "scratch-test"), undefined, null, [key]);
  assert.equal(a.moves.sizes.line(key)?.bytes, g.bytes, "the gathering's own bytes");
  assert.ok(g.bytes >= 64 * 1024);
  const times = () => a.sized.filter((k) => k === key).length;
  assert.equal(times(), 1);
  await plan();
  assert.equal(times(), 1, "read again with nothing changed: not measured");
  // Its turn ends.
  await w.t.adjust(1_000);
  say(a.rig.hub, thread, "p@x", "and now?");
  await a.rig.quiet();
  await endTurn(a, key);
  await plan();
  assert.equal(times(), 2, "its turn ended: measured again");
  // A job of it starts, then ends.
  a.rig.store.insertJob({ id: "j1", sessionKey: key, name: "build", command: "make", cwd: a.rig.session(key).workspace, port: null, token: "t1", state: "running", pgid: 1, exitCode: null, startedAt: 1, endedAt: null, restarts: 0, log: "/dev/null", watch: false });
  await plan();
  assert.equal(times(), 3, "a job started: measured again");
  await w.t.adjust(1_000);
  a.rig.store.jobEnded("j1", "exited", 0);
  await plan();
  assert.equal(times(), 4, "its job ended: measured again");
  await plan();
  assert.equal(times(), 4);
  // Archived.
  a.rig.store.setArchived(key, true, "p@x");
  await plan();
  assert.equal(times(), 5, "archived: measured again");
});

test("a room past its bound is said at least: what was found so far, not all of it", async () => {
  const w = world();
  const a = w.get(A);
  const { key } = await stillfailChat(a);
  const ws = a.rig.session(key).workspace;
  for (let i = 0; i < 20; i++) writeFileSync(join(ws, `f${i}.txt`), "x".repeat(100));
  const db = join(a.rig.dir, "stillfail.db");
  const [all] = await sizesSoon(a.rig.dir, db, [key], { most: 10_000 });
  const [cut] = await sizesSoon(a.rig.dir, db, [key], { most: 8 });
  assert.equal(all!.complete, true);
  assert.ok(all!.bytes >= 2_000, String(all!.bytes));
  assert.equal(cut!.complete, false);
  assert.ok(cut!.bytes < all!.bytes, `${cut!.bytes} of ${all!.bytes}`);
});

test("a turn reads plans every half second and sizes no room; what changed meanwhile is sized at the next plan read at rest", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key: going } = await stillfailChat(a);
  const { key: other } = await stillfailChat(a);
  await a.moves.scheduler.plan(WS, B);
  await a.moves.sizes.settled();
  const n0 = a.sized.length;
  const kept = () => readFileSync(join(a.rig.dir, "move", "sizes.log"), "utf8");
  const before = kept();
  assert.notEqual(a.moves.sizes.line(going), undefined);
  // (a turn held as the chat's files are placed there)
  const gate = Promise.withResolvers<void>();
  const at = Promise.withResolvers<void>();
  b.placing = async () => {
    at.resolve();
    await gate.promise;
  };
  const turn = a.moves.scheduler.move(WS, B, { module: "chats", item: going });
  await at.promise;
  // (another chat changes meanwhile; plans read every half second, as a page polled would)
  a.rig.store.setArchived(other, true, "p@x");
  for (let i = 0; i < 4; i++) {
    await a.moves.scheduler.plan(WS, B);
    await w.t.adjust(500);
  }
  assert.deepEqual(a.sized.slice(n0), [], "no room sized during the turn");
  b.placing = undefined;
  gate.resolve();
  assert.equal((await turn).failed, null);
  await w.quiet();
  assert.deepEqual(a.sized.slice(n0), [], "nor as it ended");
  assert.equal(kept(), before, "nothing written of its sizes as the chat went");
  // At rest: the chat that changed, alone (the one that left needs none).
  await a.moves.scheduler.plan(WS, B);
  await a.moves.sizes.settled();
  assert.deepEqual(a.sized.slice(n0), [other]);
  assert.equal(a.moves.sizes.line(going), undefined, "the line of the chat that left let go by the pass at rest");
});

test("a chat's trip asks no more of the other than its files need: what it lacks asked first only where all of it might not fit", async () => {
  const asked = async (margin: number) => {
    const s = await full(200 * 1024, margin, true);
    const n0 = s.a.sized.length;
    assert.equal(await s.a.moves.handover.handOver(s.key, B).then(() => null, (e: Error) => e.message), null);
    await s.w.quiet();
    assert.deepEqual(s.a.sized.slice(n0), [], "no room sized");
    assert.deepEqual(s.toB.filter((m) => m === "move.sizes" || m === "move.open" || m === "move.uses"), [], "nothing asked of its size");
    return s.toB.filter((m) => m === "handover.lacking").length;
  };
  const ample = await asked(1024 ** 3);
  const tight = await asked(50 * 1024);
  assert.ok(ample > 0 && tight > ample, `lacking asked ${ample} times with room to spare, ${tight} where it had to be asked first`);
});

/// A station of one chat whose room holds `bytes` more, B with FLOOR_MIN and `margin` free; with `copy`, B holds a copy of
/// the chat's room at the same place (a retirement's leftover).
async function full(bytes: number, margin: number, copy: boolean) {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const ws = a.rig.session(key).workspace;
  writeFileSync(join(ws, "big.bin"), Buffer.alloc(bytes, 7));
  if (copy) {
    const there = moved(dirname(ws), a.rig.dir, b.rig.dir);
    mkdirSync(dirname(there), { recursive: true });
    cpSync(dirname(ws), there, { recursive: true, preserveTimestamps: true });
  }
  b.free = FLOOR_MIN + margin;
  const toB: string[] = [];
  w.tamper((to, r) => (to === B && typeof r?.method === "string" && toB.push(r.method), r));
  return { w, a, b, key, toB };
}

test("a whole move that would leave less than the floor there is refused before anything is held, in numbers; a room there already is not counted again, and it goes", async () => {
  // (200 KB to send, 50 KB above the floor there)
  const no = await full(200 * 1024, 50 * 1024, false);
  const error = await no.a.moves.scheduler.move(WS, B, { all: true, follow: ["jobs"] }).then(() => null, (e: Error) => e.message);
  await no.w.quiet();
  assert.match(error ?? "", /Moving all \d+ chats would add about 0\.0 GB to B, which has 20\.0 GB free: that would leave less than the 20\.0 GB kept free there\. Free about 0\.0 GB there|全部迁走 \d+ 个对话会在「B」上多占大约 0\.0 GB/);
  assert.ok(no.toB.includes("move.sizes"), "B asked what it has of the rooms");
  assert.ok(!no.toB.some((m) => m.startsWith("handover.") || m.startsWith("share.")), `nothing held or asked to be taken: ${no.toB.join(" ")}`);
  assert.equal(no.a.rig.store.handedTo(no.key), null);
  assert.equal(no.a.rig.hub.handedOver(no.key), false);
  // The same with the room there already: what it adds is what it lacks, and it fits.
  const yes = await full(200 * 1024, 50 * 1024, true);
  const out = await yes.a.moves.scheduler.move(WS, B, { all: true, follow: ["jobs"] }).then((o) => o, (e: Error) => ({ notBegun: e.message, failed: null }));
  await yes.w.quiet();
  assert.equal((out as Json).notBegun, undefined, "not refused: what it lacks there fits");
  assert.equal(out.failed, null, JSON.stringify(out.failed));
  assert.equal(yes.a.rig.store.handedTo(yes.key)?.station, B, JSON.stringify(out));
});

test("one chat goes only where what it lacks there leaves the floor free: refused by its bytes where the other has none of it, taken where a copy of its room is there", async () => {
  const no = await full(200 * 1024, 50 * 1024, false);
  const error = await no.a.moves.handover.handOver(no.key, B).then(() => null, (e: Error) => e.message);
  await no.w.quiet();
  assert.match(error ?? "", /has 20\.0 GB free and this chat needs 0\.0 GB, which would leave less than the 20\.0 GB kept free there|要留出的 20\.0 GB/);
  assert.ok(!no.toB.includes("handover.put"), "nothing of it sent");
  assert.equal(no.a.rig.store.handedTo(no.key), null);
  const yes = await full(200 * 1024, 50 * 1024, true);
  assert.equal(await yes.a.moves.handover.handOver(yes.key, B).then(() => null, (e: Error) => e.message), null);
  await yes.w.quiet();
  assert.equal(yes.a.rig.store.handedTo(yes.key)?.station, B);
});

test("a station that says nothing of its disk or its rooms (one from before) is refused no whole move by a sum", async () => {
  const s = await full(200 * 1024, 50 * 1024, false);
  s.w.tamper((to, r) => {
    if (to === B && r?.method === "move.sizes") throw new Error("no such method");
    return r;
  });
  const out = await s.a.moves.scheduler.move(WS, B, { all: true, follow: ["jobs"] });
  await s.w.quiet();
  // (refused chat by chat instead, by what it lacks there)
  assert.match((out.failures ?? []).map((f) => f.error).join(" "), /kept free there|要留出的/);
});
