// What a hand-over costs on a station that keeps the records of many chats' trips (replica/handover.ts): a chat handed
// over and brought home looks only at the records of its own sessions (`#outsOf`, `#insOf`, what is coming and what is
// owed), never at all those a station keeps. A whole move back showed each chat slower by the chats already back (4 to
// 79 ms a chat over 2,384, drill 31): each arrival walked every record, and every ended one against every other.
import assert from "node:assert/strict";
import { counting, type Cost } from "./move-bounded.ts";
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { A, B, WS, stillfailChat, world } from "./move-world.ts";

type Json = any;
type Looked = Record<string, number>;
/// What was looked at since `before`, by what looked.
const since = (now: Looked, before: Looked): Looked => Object.fromEntries(Object.entries(now).map(([k, n]) => [k, n - (before[k] ?? 0)]).filter(([, n]) => n !== 0));
const sum = (l: Looked) => Object.values(l).reduce((a, b) => a + b, 0);
/// What A's hand-over of a fresh chat to B and back (its second trip) looks at of A's records, A keeping besides the
/// records of `n` other chats' trips there and back (each ended where it left, half as a station from before left
/// them, and shown where it came home), as chats moved about leave them.
async function lookedWith(n: number): Promise<{ start: number; there: Looked; back: Looked; kept: { outs: number; ins: number }; jobs: { read: number; trip: Cost; idle: Cost; alone: { read: number; cost: Cost } } }> {
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
      // (half the trips' records kept as a station from before kept them, cut at gone: a start judges each by whether
      // its chat came back, `#cameBack`)
      if (side === "out" && i % 2 === 1) {
        delete copy.v;
        delete copy.ended;
        copy.step = "gone";
      }
      writeFileSync(join(records, side, `${copy.id}.json`), JSON.stringify(copy));
    }
  }
  // (and as many other chats' jobs up here, kept here as their chats were held, and moved with them: the jobs' log as
  // a station that moved them keeps it)
  const job = (session: string) => ({ session, name: "dev", command: "npm run dev", cwd: join(a.rig.dir, "sessions", session, "workspace"), port: null, watch: false });
  for (let i = 0; i < n; i++) a.jobs.push({ ...job(`up-${i}`), id: `A-up-${i}` } as Json);
  mkdirSync(join(a.rig.dir, "move"), { recursive: true });
  writeFileSync(join(a.rig.dir, "move", "jobs.log"), Array.from({ length: n }, (_, i) => `${JSON.stringify({ k: `kept-${i}#dev`, v: { kept: job(`kept-${i}`) } })}\n${JSON.stringify({ k: `moved-${i}#dev`, v: { moved: job(`moved-${i}`), to: B } })}\n`).join(""));
  await a.moves.close();
  a.moves = a.make();
  await a.moves.start();
  await w.quiet();
  // (a start looks at each record once, what is done for each chat by its own records: as many again as there are)
  const start = sum(a.moves.handover.looked());
  const kept = { outs: a.moves.handover.outs().length, ins: a.moves.handover.ins().length };
  // A fresh chat there and back, then again, counted: its arrival home has its trip before to end and trim.
  const { key: fresh } = await stillfailChat(a);
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: fresh })).failed, null);
  await w.quiet();
  assert.equal((await a.moves.scheduler.back(WS, B, { module: "chats", item: fresh })).failed, null);
  await w.quiet();
  // (its job up: held with it, kept, moved and brought back by the jobs' part; what a plan reads, once a turn, apart)
  a.jobs.push({ ...job(fresh), id: "A-fresh" } as Json);
  const sched = a.moves.scheduler;
  const plan = sched.plan;
  let planRead = 0;
  sched.plan = async (...args: Parameters<typeof plan>) => {
    const was = a.jobsRead;
    try {
      return await plan.apply(sched, args);
    } finally {
      planRead += a.jobsRead - was;
    }
  };
  const plans = [sched, w.get(B).moves.scheduler];
  const trip = counting(join(a.rig.dir, "move"), plans);
  // (the rooms sized on either station meanwhile: none, a turn's plan starting no sizing, move/sizes.ts)
  const sized0 = [a.sized.length, w.get(B).sized.length];
  const read0 = a.jobsRead;
  const plan0 = planRead;
  const before = a.moves.handover.looked();
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: fresh })).failed, null);
  await w.quiet();
  const mid = a.moves.handover.looked();
  const there = since(mid, before);
  assert.equal((await a.moves.scheduler.back(WS, B, { module: "chats", item: fresh })).failed, null);
  await w.quiet();
  const back = since(a.moves.handover.looked(), mid);
  assert.equal(a.rig.store.handedTo(fresh), null, "home again");
  const jobsRead = a.jobsRead - read0 - (planRead - plan0);
  const tripCost = trip.stop();
  assert.deepEqual([...a.sized.slice(sized0[0]!), ...w.get(B).sized.slice(sized0[1]!)], [], "a chat's trip there and back sizes no room");
  // A chat with no job there and back: nothing of the jobs written.
  const { key: idle } = await stillfailChat(a);
  const idleTrip = counting(join(a.rig.dir, "move"), plans);
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: idle })).failed, null);
  await w.quiet();
  assert.equal((await a.moves.scheduler.back(WS, B, { module: "chats", item: idle })).failed, null);
  await w.quiet();
  const idleCost = idleTrip.stop();
  // A job moved by itself, its chat there already (its job started here again meanwhile): its session's jobs read.
  const { key: lone } = await stillfailChat(a);
  a.jobs.push({ ...job(lone), id: "A-lone" } as Json);
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: lone })).failed, null);
  await w.quiet();
  a.moves.jobs.startKept([lone]);
  await w.quiet();
  const aloneRead0 = a.jobsRead;
  const alonePlan0 = planRead;
  const alone = counting(join(a.rig.dir, "move"), plans);
  // (asked of the jobs' part itself: a plan lists a job up here only while its chat is here, the job of a chat away
  // being one kept here, so a job up here of a chat there is moved by the module as the scheduler would move it)
  await a.moves.jobs.move({ module: "jobs", id: `${lone}#dev`, label: "dev", needs: [{ module: "chats", id: lone }] }, B);
  await w.quiet();
  const aloneCost = alone.stop();
  const aloneRead = a.jobsRead - aloneRead0 - (planRead - alonePlan0);
  sched.plan = plan;
  return { start, there, back, kept, jobs: { read: jobsRead, trip: tripCost, idle: idleCost, alone: { read: aloneRead, cost: aloneCost } } };
}

test("a chat handed over and brought home looks at the records of its own sessions: as many at 30 other chats' trips kept as at 300; a start, at each record once", async (t) => {
  const few = await lookedWith(30);
  const many = await lookedWith(300);
  t.diagnostic(`looked at, by what looked: with 30 kept ${JSON.stringify(few)}; with 300 ${JSON.stringify(many)}`);
  assert.ok(many.kept.outs > 300 && many.kept.ins > 300, `the records kept: ${JSON.stringify(many.kept)}`);
  assert.ok(sum(few.there) > 0 && sum(few.back) > 0, `counted: ${JSON.stringify(few)}`);
  // (a start looks at its records as many times more as there are records more, twice that at most: not their square)
  const records = (many.kept.outs + many.kept.ins) / (few.kept.outs + few.kept.ins);
  assert.ok(many.start / few.start < 2 * records, `a start's looking grows as the records do (${records.toFixed(1)} times), not as their square: ${few.start} at 30, ${many.start} at 300`);
  // (the jobs' part: what one chat's trip reads of the jobs, of the stores by table, and writes under move/ by file,
  // the same with 30 and 300 other chats' jobs up, kept and moved; a chat with none writes nothing of them)
  assert.deepEqual(many.jobs, few.jobs, `the jobs' part with 30: ${JSON.stringify(few.jobs)}, with 300: ${JSON.stringify(many.jobs)}`);
  assert.ok(few.jobs.alone.read > 0, `a job moved by itself reads its session's: ${JSON.stringify(few.jobs.alone)}`);
  assert.ok(few.jobs.read > 0 && (few.jobs.trip.bytes["jobs.log"] ?? 0) > 0, `the chat's own job counted: ${JSON.stringify(few.jobs)}`);
  assert.equal(few.jobs.idle.bytes["jobs.log"], undefined, `a chat with no job writes nothing of the jobs: ${JSON.stringify(few.jobs.idle)}`);
  assert.deepEqual({ there: many.there, back: many.back }, { there: few.there, back: few.back }, `looked at with 30 kept: ${JSON.stringify(few)}, with 300: ${JSON.stringify(many)}`);
});

test("the jobs kept and moved, as a station from before kept them in one file, are taken in a line each and kept so across starts; a line cut short as the station stopped is left out", async () => {
  const w = world();
  const a = w.get(A);
  const { key } = await stillfailChat(a);
  const job = (name: string) => ({ session: key, name, command: "npm run dev", cwd: join(a.rig.dir, "sessions", "s", "workspace"), port: null, watch: false });
  const dir = join(a.rig.dir, "move");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "jobs.json"), JSON.stringify({ kept: [job("kept")], moved: [{ job: job("moved"), to: B }] }));
  const states = async () => Object.fromEntries((await a.moves.scheduler.plan(WS, B)).items.filter((x) => x.module === "jobs").map((x) => [x.id, x.state]));
  const again = async () => {
    await a.moves.close();
    a.moves = a.make();
    await a.moves.start();
    await w.quiet();
  };
  await again();
  const want = { [`${key}#kept`]: "stopped", [`${key}#moved`]: "there" };
  assert.deepEqual(await states(), want, "taken in from the file of before");
  assert.deepEqual(readdirSync(dir).filter((f) => f.startsWith("jobs.")), ["jobs.log"], "its lines written, the file of before let go");
  // (a line cut short as the station stopped: left out, what was before it kept)
  writeFileSync(join(dir, "jobs.log"), `${readFileSync(join(dir, "jobs.log"), "utf8")}{"k":"${key}#kept"`);
  await again();
  assert.deepEqual(await states(), want, "across a start, a line cut short left out");
  // (and what changes after it starts a line of its own: the kept job started here again, so across a start)
  a.moves.jobs.startKept([key]);
  await w.quiet();
  await again();
  assert.equal((await states())[`${key}#kept`], "here", "a change after a line cut short kept across a start");
});
