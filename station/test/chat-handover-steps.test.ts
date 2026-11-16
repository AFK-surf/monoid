// The steps of a move that grow with a chat or a repository are told steps (move/told.ts): no request between the two
// stations waits on such work, under mesh/peer.ts's 30 s answer, which a chat of 70k files placed in 50 s failed (the real
// run, 2026-11-16). Its stations are move-world.ts's, each request failed as the mesh fails it when its answer takes
// longer than ANSWER_MS on the test's clock (`answerMs`); the work the station asked does (a placing, a gathering, git,
// a removal) held for HOLD_MS, far past it.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { given } from "./hub-fakes.ts";
import { WS, A, B, ANSWER_MS, type Station, world, stillfailChat, gitEnv, filesOf, retiredCopy } from "./move-world.ts";

type Json = any;

const HOLD_MS = 10 * 60_000;

/// Time on the test's clock moved on `ms`, a beat at a time, each station brought to rest between (what a step tells,
/// and asks again, goes as it would).
async function pass(w: ReturnType<typeof world>, ms: number) {
  for (let t = 0; t < ms; t += 5_000) {
    await w.t.adjust(5_000);
    for (const s of w.stations.values()) await s.rig.quiet();
  }
}

/// A hold of work: `at` once it is reached, let go by `release`.
function hold() {
  const at = Promise.withResolvers<void>();
  const gate = Promise.withResolvers<void>();
  return { at: at.promise, release: () => gate.resolve(), wait: () => (at.resolve(), gate.promise) };
}

/// Of what the stations asked each other, what failed for want of an answer in time.
const late = (w: ReturnType<typeof world>) => w.heard.filter((h) => h.failed?.startsWith("peer request timed out")).map((h) => `${h.method} ${h.from.slice(0, 1)}→${h.to.slice(0, 1)}`);

/// Where chat `key` is in sight: on exactly one station, as its row there says.
function inSightOn(w: ReturnType<typeof world>, key: string): string[] {
  return [...w.stations.values()].filter((s) => s.rig.store.getSession(key) !== null && s.rig.store.handedTo(key) === null && !String(s.rig.store.getSession(key)!.ws ?? "").startsWith("coming:")).map((s) => s.id.slice(0, 1).toUpperCase());
}

for (const which of ["the first placing", "the held placing", "the pruning (its gathering there)"] as const) {
  test(`${which} there held for ten minutes, far past an answer's 30 s: the chat goes all the same, no request waiting on it; how far its files are placed is told meanwhile`, async () => {
    const w = world([A, B], { answerMs: true });
    const a = w.get(A);
    const b = w.get(B);
    const { key } = await stillfailChat(a);
    const h = hold();
    let placings = 0;
    if (which === "the pruning (its gathering there)") b.gathering = () => h.wait();
    else b.placing = async () => void (++placings === (which === "the first placing" ? 1 : 2) && (await h.wait()));
    const turn = a.moves.scheduler.move(WS, B, { module: "chats", item: key });
    await h.at;
    await pass(w, HOLD_MS);
    if (which !== "the pruning (its gathering there)") {
      // (the placing told how far it is: the item's progress in files of its index)
      const state = a.moves.modules.find((m) => m.id === "chats")!.state({ module: "chats", id: key, label: key, needs: [] });
      assert.equal(state.state, "moving");
      assert.equal(state.progress?.unit, "files", "its progress is the placing's");
    }
    h.release();
    const out = await turn;
    await w.quiet();
    assert.equal(out.failed, null, JSON.stringify(out.failed));
    assert.deepEqual(late(w), [], "no request waited past its answer's time");
    assert.deepEqual(inSightOn(w, key), ["B"]);
    assert.ok(w.heard.some((x) => x.method === "move.told" && x.from === B), "the step told it works");
  });
}

test("a drop asked as its placing there is held: answered at once, its files taken out there once the placing ends, by that station itself", async () => {
  const w = world([A, B], { answerMs: true });
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const room = b.rig.dir;
  const h = hold();
  const removal = hold();
  let placings = 0;
  b.placing = async () => void (++placings === 2 && (await h.wait()));
  b.dropping = () => removal.wait();
  const moving = a.moves.handover.handOver(key, B, { wait: true }).then(() => null, (e: Error) => e.message);
  await h.at;
  // (this station started again as it was placed there: the hand-over failed, its drop owed there)
  await a.moves.close();
  a.moves = a.make();
  await a.moves.start();
  assert.notEqual(await moving, null, "it did not go");
  await pass(w, HOLD_MS);
  assert.equal(a.moves.handover.outOf(key)?.dropOwed, false, "the drop was answered, the placing still under way");
  h.release();
  await removal.at;
  await pass(w, HOLD_MS);
  removal.release();
  await w.quiet();
  assert.deepEqual(late(w), [], "no request waited past its answer's time");
  assert.deepEqual(b.moves.handover.ins().map((i) => i.step), ["dropped"]);
  assert.equal(existsSync(join(room, "sessions")) ? Object.keys(filesOf(join(room, "sessions"))).length : 0, 0, "nothing of it there");
  assert.deepEqual(inSightOn(w, key), ["A"]);
});

test("a hand-over begun while an older one of the chat is still placed there (its drop lost): begun at once, the older taken out there after its placing, before the newer places anything; the chat goes", async () => {
  const w = world([A, B], { answerMs: true });
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const h = hold();
  let placings = 0;
  b.placing = async () => void (++placings === 1 && (await h.wait()));
  void a.moves.handover.handOver(key, B, { wait: true }).catch(() => {});
  await h.at;
  // (the older's drop never gets there: this station takes it as answered)
  w.tamper((to, r) => (r.method === "handover.drop" && to === B ? { ...r, id: "lost" } : r));
  await a.moves.close();
  a.moves = a.make();
  await a.moves.start();
  w.tamper(null);
  const turn = a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await pass(w, HOLD_MS);
  h.release();
  const out = await turn;
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out.failed));
  assert.deepEqual(late(w), [], "no request waited past its answer's time");
  assert.deepEqual(b.moves.handover.ins().map((i) => i.step), ["shown"], "the older taken out, its record let go as the newer was shown");
  assert.deepEqual(inSightOn(w, key), ["B"]);
  assert.equal(b.rig.store.getSession(key) !== null && existsSync(join(b.rig.session(key).workspace, "notes.md")), true, "its files there");
});

test("a chat moved back whose hand-over there takes ten minutes (its gathering held): it comes back, the move back waiting on no request's answer", async () => {
  const w = world([A, B], { answerMs: true });
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  const h = hold();
  let gathered = 0;
  b.gathering = async () => void (++gathered === 1 && (await h.wait()));
  const back = a.moves.scheduler.back(WS, B, { module: "chats", item: key });
  await h.at;
  await pass(w, HOLD_MS);
  h.release();
  const out = await back;
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out.failed));
  assert.deepEqual(late(w), [], "no request waited past its answer's time");
  assert.deepEqual(inSightOn(w, key), ["A"]);
});

/// A's chat with a linked worktree of a clone whose remote lacks a commit of it (what a repository's move fetches there
/// from a bundle).
function withWorktree(a: Station, key: string) {
  const ws = a.rig.session(key).workspace;
  const run = (dir: string, ...args: string[]) => execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", env: gitEnv(a.rig.dir), stdio: ["ignore", "pipe", "pipe"] }).trim();
  const bare = join(a.rig.dir, "remote.git");
  execFileSync("git", ["init", "-q", "--bare", "-b", "main", bare], { env: gitEnv(a.rig.dir) });
  const clone = join(a.rig.dir, "repos", "proj");
  mkdirSync(join(a.rig.dir, "repos"), { recursive: true });
  execFileSync("git", ["clone", "-q", bare, clone], { env: gitEnv(a.rig.dir), stdio: "ignore" });
  writeFileSync(join(clone, "a.txt"), "pushed\n");
  run(clone, "add", "-A");
  run(clone, "commit", "-q", "-m", "pushed");
  run(clone, "push", "-q", "origin", "HEAD:main");
  writeFileSync(join(clone, "b.txt"), "not pushed\n");
  run(clone, "add", "-A");
  run(clone, "commit", "-q", "-m", "not pushed");
  run(clone, "worktree", "add", "-q", "-b", "feature", join(ws, "proj"));
  return `repo:${bare}`;
}

test("a repository moved whose bundle's fetch there takes ten minutes, then moved back whose clone's removal there does: both go, waiting on no request's answer", async () => {
  const w = world([A, B], { answerMs: true });
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const repo = withWorktree(a, key);
  const fetch = hold();
  b.gitting = async (args) => void (args[0] === "fetch" && args.some((x) => x.includes(join("move", "in", "repos"))) && (await fetch.wait()));
  const moved = a.moves.scheduler.move(WS, B, { module: "repos", item: repo });
  await fetch.at;
  await pass(w, HOLD_MS);
  fetch.release();
  assert.equal((await moved).failed, null, "the repository moved");
  await w.quiet();
  assert.deepEqual(readdirSync(join(b.rig.dir, "repos")).filter((n) => !n.startsWith(".")).length, 1, "its clone there");
  const removal = hold();
  b.removing = () => removal.wait();
  const back = a.moves.scheduler.back(WS, B, { module: "repos", item: repo });
  await removal.at;
  await pass(w, HOLD_MS);
  removal.release();
  assert.equal((await back).failed, null, "the repository back");
  await w.quiet();
  assert.deepEqual(late(w), [], "no request waited past its answer's time");
  assert.deepEqual(readdirSync(join(b.rig.dir, "repos")), [], "its clone there removed");
});

test("what lies there already at other times is hashed a bounded number of bytes a request: each file looked at in a request of its own past that bound, none of them sent, one larger than the bound sent", async () => {
  const w = world([A, B], { answerMs: true });
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const room = a.rig.session(key).workspace;
  const small = ["one.md", "two.md", "three.md"];
  for (const n of small) writeFileSync(join(room, n), `${n} ..`);
  writeFileSync(join(room, "large.md"), "x".repeat(40));
  // (a copy of its room there, every file at another time: what a retirement taken back leaves)
  retiredCopy(a, b, key);
  const there = room.replace(a.rig.dir, b.rig.dir);
  for (const n of readdirSync(there)) utimesSync(join(there, n), new Date(1_000_000), new Date(1_000_000));
  await b.moves.close();
  b.hashMost = 20;
  b.moves = b.make();
  await b.moves.start();
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out.failed));
  const hash = (n: string) => createHash("sha256").update(readFileSync(join(room, n))).digest("hex");
  const put = (n: string) => w.heard.some((h) => h.method === "handover.put" && h.name === hash(n));
  for (const n of small) assert.equal(put(n), false, `${n}: in place there, found by its hash`);
  assert.equal(put("large.md"), true, "one past the bound is sent");
  // (what the bound left of a request asked again alone)
  assert.ok(w.heard.filter((h) => h.method === "handover.lacking").length >= 3, "asked again for what the bound left");
  assert.equal(readFileSync(join(b.rig.session(key).workspace, "large.md"), "utf8"), "x".repeat(40));
});

// ── the station asked replaced, the link lost, the station asking replaced, each as a step works ──

test("the station a chat goes to started again as its placing works: asked again as it says nothing, the new process places it anew, and the chat goes, on exactly one station", async () => {
  const w = world([A, B], { answerMs: true });
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const h = hold();
  let placings = 0;
  // (the process before never ends its placing: it is gone)
  b.placing = async () => void (++placings === 1 && (await h.wait()));
  const turn = a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await h.at;
  await b.moves.close();
  b.moves = b.make();
  await b.moves.start();
  await pass(w, 60_000);
  const out = await turn;
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out.failed));
  assert.ok(placings >= 2, "placed anew by the new process");
  assert.deepEqual(late(w), []);
  assert.deepEqual(inSightOn(w, key), ["B"]);
});

test("the link between the two lost as a chat's placing works, then open again: what was told meanwhile lost, the step asked again as the link opens; the chat on exactly one station", async () => {
  for (const outage of [10_000, 60_000]) {
    const w = world([A, B], { answerMs: true });
    const a = w.get(A);
    const b = w.get(B);
    const { key } = await stillfailChat(a);
    const h = hold();
    let placings = 0;
    b.placing = async () => void (++placings === 1 && (await h.wait()));
    const turn = a.moves.scheduler.move(WS, B, { module: "chats", item: key });
    await h.at;
    b.up = false;
    await pass(w, outage);
    b.up = true;
    await pass(w, 30_000);
    h.release();
    const out = await turn;
    await w.quiet();
    const on = inSightOn(w, key);
    assert.equal(on.length, 1, `${outage} ms: on one station, ${on}`);
    // (a silence the step was asked again within went on; one where that ask found the other gone is a failure, the
    // chat here)
    if (outage < 15_000) assert.equal(out.failed, null, JSON.stringify(out.failed));
    assert.deepEqual(on, out.failed === null ? ["B"] : ["A"], `${outage} ms`);
    if (out.failed !== null) assert.deepEqual(b.moves.handover.ins().map((i) => i.step), ["dropped"], "dropped there");
  }
});

test("the station a chat leaves started again as its placing there works: the hand-over fails as such a start fails it, the drop answered, the chat here alone", async () => {
  const w = world([A, B], { answerMs: true });
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const h = hold();
  let placings = 0;
  b.placing = async () => void (++placings === 1 && (await h.wait()));
  const moving = a.moves.handover.handOver(key, B, { wait: true }).then(() => null, (e: Error) => e.message);
  await h.at;
  await a.moves.close();
  a.moves = a.make();
  await a.moves.start();
  assert.notEqual(await moving, null);
  await pass(w, 60_000);
  h.release();
  await w.quiet();
  assert.deepEqual(late(w), []);
  assert.equal(a.moves.handover.outOf(key)?.dropOwed, false);
  assert.deepEqual(b.moves.handover.ins().map((i) => i.step), ["dropped"]);
  assert.deepEqual(inSightOn(w, key), ["A"]);
});

test("a turn stopped while the chat's placing there works ten minutes: the chat is here again at once, the step there let go; that station takes out what it placed once its placing ends, nothing of it left", async () => {
  const w = world([A, B], { answerMs: true });
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const h = hold();
  let placings = 0;
  b.placing = async () => void (++placings === 1 && (await h.wait()));
  const turn = a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await h.at;
  assert.equal(a.moves.scheduler.stopTurn("o@x"), true, "a turn under way stopped");
  // (no time passes: the stop waits for nothing that grows with the chat)
  const out = await given(turn, "the turn ended as it was stopped, the placing there still under way");
  assert.notEqual(out.failed, null, "the chat did not go");
  assert.deepEqual(inSightOn(w, key), ["A"], "here again");
  assert.equal(a.rig.hub.chatHeld(key), null, "it goes on here");
  assert.equal(a.moves.handover.outOf(key)?.dropOwed, false, "its drop answered there");
  h.release();
  await w.quiet();
  assert.deepEqual(late(w), []);
  assert.deepEqual(b.moves.handover.ins().map((i) => i.step), ["dropped"]);
  assert.equal(existsSync(join(b.rig.dir, "sessions")) ? Object.keys(filesOf(join(b.rig.dir, "sessions"))).length : 0, 0, "nothing of it there");
});

// ── the rule for every request ──

/// What bounds each request a move asks of another station (the audit of 2026-11-16): a told step's answers start or
/// read a step; the others' work is bounded by what they are given. A request not here is new: say what bounds it.
const BOUNDED: Record<string, string> = {
  "handover.begin": "small; an older hand-over's drop only marked (its files a step of that station's own)",
  "handover.lacking": "at most lackMost hashes, a stat a path, and HASH_MOST bytes read",
  "handover.put": "one file streamed, or a pack of at most PACK_MAX_FILES files and PACK_MAX_BYTES (one larger alone) streamed in zstd, each piece within the mesh's idle time",
  "handover.place": "a told step",
  "handover.rows": "500 rows a page",
  "handover.prune": "a told step",
  "handover.counts": "in memory",
  "handover.show": "the chat's rows' workspace said and a few records ended",
  "handover.drop": "marked, its rows out by their ranges; its files a step of that station's own",
  "handover.still": "memory",
  "handover.held": "memory",
  "move.told": "memory",
  "move.open": "a statfs",
  "move.accounts": "the profiles",
  "move.chats.live": "a page of keys",
  "move.arrived": "the stopped set",
  "move.back": "a told step for a chat; an account's or a connect's move",
  "move.repo.have": "the repository cache's clones",
  "move.repo.make": "answered at once, its end told (move.repo.made)",
  "move.repo.made": "memory",
  "move.repo.bundle": "its bytes streamed, then a told step",
  "move.repo.drop": "a told step",
  "move.sizes": "a batch of capped walks",
  "move.uses": "an index",
  "move.unused": "the lent logins",
  "move.job.start": "one job",
  "move.job.stop": "one job",
  "move.vault.put": "a page of rows",
  "move.setting.values": "config.json",
  "move.setting.take": "config.json",
  "move.setting.drop": "config.json",
};

/// How long each piece of work is held in a round: twice an answer's time, so that any request waiting on it fails (a
/// round holds dozens of them, one after another).
const ROUND_HOLD_MS = 2 * ANSWER_MS;

/// A whole round with every piece of work of the stations held ROUND_HOLD_MS: a chat of `n` files with a worktree,
/// moved with its repository, a hand-over that failed and was dropped, the chat moved, back, the repository back.
/// Each request's own work counted: the held work begun while it was open, by method, the most of one request.
async function round(n: number) {
  const w = world([A, B], { answerMs: true });
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const room = a.rig.session(key).workspace;
  for (let i = 0; i < n; i++) writeFileSync(join(room, `f${i}.md`), `file ${i}`);
  const repo = withWorktree(a, key);
  /// The requests to each station open now, and the work begun inside each.
  const open = new Map<Station, Set<{ method: string; work: number }>>();
  const most: Record<string, number> = {};
  for (const s of [a, b]) {
    open.set(s, new Set());
    const handle = s.bus.handle.bind(s.bus);
    s.bus.handle = ((ws: string, peer: string, request: Json) => {
      const it = { method: String(request?.method ?? ""), work: 0 };
      open.get(s)!.add(it);
      const done = () => {
        open.get(s)!.delete(it);
        most[it.method] = Math.max(most[it.method] ?? 0, it.work);
      };
      return handle(ws, peer, request).finally(done);
    }) as typeof s.bus.handle;
  }
  const held = async (s: Station) => {
    for (const it of open.get(s)!) it.work++;
    await w.get(s.id).fibers.sleep(ROUND_HOLD_MS);
  };
  for (const s of [a, b]) {
    s.placing = () => held(s);
    s.gathering = () => held(s);
    // (git's work that grows with a repository: a fetch, a clone, a worktree made; not a remote's url read)
    s.gitting = async (args) => void (["fetch", "clone", "worktree"].includes(args[0] ?? "") && (await held(s)));
    s.dropping = () => held(s);
    s.removing = () => held(s);
  }
  // (time goes by itself meanwhile, a beat at a time, until the round ends)
  let over = false;
  const clock = (async () => {
    while (!over) await pass(w, 5_000);
  })();
  try {
    assert.equal((await a.moves.scheduler.move(WS, B, { module: "repos", item: repo })).failed, null, "the repository moved");
    a.fails.add("counts");
    assert.notEqual((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null, "a hand-over failed");
    const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
    assert.equal(out.failed, null, JSON.stringify(out.failed));
    assert.equal((await a.moves.scheduler.back(WS, B, { module: "chats", item: key })).failed, null, "the chat back");
    assert.equal((await a.moves.scheduler.back(WS, B, { module: "repos", item: repo })).failed, null, "the repository back");
  } finally {
    over = true;
    await clock;
  }
  await w.quiet();
  assert.deepEqual(late(w), [], `${n} files: every request answered in its time`);
  const asked = [...new Set(w.heard.map((h) => h.method))].sort();
  for (const m of asked) assert.ok(m in BOUNDED, `${m}: a request of a move not in the table; say what bounds its answer`);
  assert.deepEqual(inSightOn(w, key), ["A"]);
  return { asked, most };
}

test("every request a move asks is answered in its time with all the work of the station asked held twice that time, and the work begun inside any one request is the same for a chat of 10 files as for one of 100", async () => {
  const small = await round(10);
  const large = await round(100);
  assert.deepEqual(large.asked, small.asked, "the same requests");
  assert.deepEqual(large.most, small.most, "the most work begun inside one request, by method, the same");
  for (const [m, n] of Object.entries(large.most)) assert.ok(n <= 1, `${m}: ${n} pieces of work begun inside one request`);
});
