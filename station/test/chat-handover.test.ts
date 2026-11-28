// One chat handed from a station to another while both are up (replica/handover.ts), through the migration's modules
// and scheduler (move/): a still.fail chat goes on there on its runtime session, nothing said in it; a Slack thread's
// chat goes on there with its connect where it was, or on a third station; two bots' sessions in one thread move each on
// its own; a job runs on one station at a time; its files go twice, the second pass only what changed; a failure at each
// step leaves the chat working here and nothing of it there; either station stopped in the middle goes on or drops.
// Stations are Rigs (hub-fakes.ts) with their connects (connects/workspace.ts) and their moves (move/station.ts), over a
// transport of the test's (move-world.ts). The rest of the hand-over's tests are chat-handover-back, -moves and -told.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createHash, randomBytes } from "node:crypto";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { sessionKey } from "../src/sessions/hub.ts";
import { say } from "../src/sessions/lifecycle.ts";
import { given, message, reply } from "./hub-fakes.ts";
import { RETRY_MS } from "../src/replica/retire.ts";
import { PeerGone } from "../src/mesh/peer.ts";
import { type Bytes, BYTES, bytesOf } from "../src/mesh/bus.ts";
import { stationLang, tr } from "../src/ops/i18n.ts";
import { hearLines } from "../src/ops/log.ts";
import { WS, A, B, C, world, endTurn, stillfailChat, gitEnv, filesOf, entries, homeThread, startedAgainChangesNothing } from "./move-world.ts";

type Json = any;

test("a chat's rows go a few tables to a request where that station takes them so, one table a request to a station from before; the chat there is the same either way", async () => {
  // (real run, 2026-11-20: a chat of 3 entries held 30 s toward a busy station, a dozen round trips of 2-3 s each)
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const rowsAsked = () => w.heard.filter((h) => h.method === "handover.rows" && h.from === A).length;
  const one = await stillfailChat(a);
  const before = entries(a, one.thread);
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, follow: ["jobs"] });
  await w.quiet();
  assert.deepEqual(out.done, [{ module: "chats", id: one.key }]);
  const batched = rowsAsked();
  assert.ok(batched >= 1 && batched <= 2, `its rows in a request or two: ${batched}`);
  assert.deepEqual(entries(b, homeThread(b, one.key)), before);
  // A station from before: begin says nothing of rows, and each table's page goes alone, as before.
  b.answered = (request, answer) => (request?.method === "handover.begin" && answer !== null && typeof answer === "object" ? (({ rows: _, ...rest }) => rest)(answer) : answer);
  const two = await stillfailChat(a);
  const was = rowsAsked();
  const out2 = await a.moves.scheduler.move(WS, B, { module: "chats", item: two.key, follow: ["jobs"] });
  await w.quiet();
  assert.deepEqual(out2.done, [{ module: "chats", id: two.key }]);
  const alone = rowsAsked() - was;
  assert.ok(alone >= 4 && alone > batched, `a table a request: ${alone} against ${batched}`);
  assert.equal(entries(b, homeThread(b, two.key)).length, entries(a, two.thread).length);
});

test("a still.fail chat handed over goes on there: shown there, out of sight here and said where it went; its next turn takes up its runtime session on the account's copy there; nothing said in it", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  const before = entries(a, thread);
  assert.equal(a.rig.session(key).runtimeSessionId, "claude-1");
  const plan = await a.moves.scheduler.plan(WS, B);
  const item = plan.items.find((x) => x.module === "chats" && x.id === key)!;
  assert.deepEqual(item.needs, [{ module: "accounts", id: "share:sh-cc" }]);
  // (B borrows it already: A's still, here, and usable there, so the chat goes without it)
  const account = plan.items.find((x) => x.id === "share:sh-cc")!;
  assert.equal(account.state, "here", "A hosts it");
  assert.equal(a.moves.modules.find((m) => m.id === "accounts")!.usableThere!(account), true, "B borrows it already");
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key, follow: ["jobs"] });
  await w.quiet();
  assert.deepEqual(out.done, [{ module: "chats", id: key }]);
  // Here: out of sight, said where it went.
  assert.equal(a.rig.store.handedTo(key)?.station, B);
  assert.equal(a.rig.hub.handedOver(key), true);
  assert.equal((await a.moves.scheduler.plan(WS, B)).items.find((x) => x.id === key)!.state, "there");
  // There: shown, its log as it was, its files, its account the copy's.
  const there = homeThread(b, key);
  assert.equal(a.rig.store.handedTo(key)?.there, there);
  assert.deepEqual(entries(b, there), before, "nothing said in it");
  assert.equal(b.rig.session(key).ws, null);
  assert.equal(b.rig.session(key).profile, "ccb");
  assert.ok(existsSync(join(b.rig.session(key).workspace, "notes.md")));
  assert.ok(b.rig.session(key).workspace.startsWith(b.rig.dir));
  // Its next turn there takes up its runtime session, told once where it runs.
  say(b.rig.hub, there, "p@x", "and now?");
  await w.quiet();
  const s = b.rig.claude.last();
  assert.equal(s.options.resume, "claude-1");
  assert.match(s.prompts[0] ?? "", /<chat-moved>This chat was handed here from station A/);
  assert.equal(b.rig.claude.count(), 1);
  assert.equal(a.rig.claude.count(), 1, "nothing more ran here");
});

test("a Slack thread's chat handed over with its connect staying here: what comes after goes there, its answer out through this station's connect; then with the connect on a third station", async () => {
  const w = world([A, B, C]);
  const a = w.get(A);
  const b = w.get(B);
  const c = w.get(C);
  const first = message({ text: "<@UBOT> look" });
  await a.connects.receive("cl", { type: "message", message: first });
  const key = sessionKey("cl", first.channel, first.threadTs);
  await endTurn(a, key);
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.equal(a.rig.store.connectThreadStation("cl", first.channel, first.threadTs), B);
  assert.equal(b.rig.session(key).connect, `cl@${A}`);
  const posts = a.rig.chat.posts.length;
  await a.connects.receive("cl", { type: "message", message: reply(first, "1800.1", "and the tests") });
  await w.quiet();
  const there = b.rig.store.threadAt("slack:T1", first.channel, first.threadTs)!;
  assert.deepEqual(b.rig.said(there.id).map((m) => m.text), ["<@UBOT> look", "and the tests"]);
  assert.equal(a.rig.claude.count(), 1, "nothing ran here after");
  b.rig.claude.last().reads();
  await b.rig.call(key, "chat_post", { to: `${first.channel}/${first.threadTs}`, text: "on it" });
  assert.equal(a.rig.chat.lastText(), "on it", "out through A's connect");
  assert.equal(a.rig.chat.posts.length, posts + 1, "nothing else posted in the thread");
  await endTurn(b, key);
  // The connect moves to C: B's chat goes on through it there; C sends what comes to B.
  await a.connects.move("cl", C, WS);
  assert.equal(c.rig.store.connectThreadStation(`cl@${A}`, first.channel, first.threadTs), B);
  // (C runs it now, its own surface)
  const local = new Map([[`cl@${A}`, c.rig.chat]]);
  c.rig.hub = c.rig.newHub({ chats: (x) => local.get(x) ?? c.connects.remote.surface(x) });
  await c.connects.receive(`cl@${A}`, { type: "message", message: reply(first, "1800.2", "still there?") });
  await w.quiet();
  assert.deepEqual(b.rig.said(there.id).map((m) => m.text).at(-1), "still there?");
  await endTurn(b, key);
  // Handed back to A while C is not reached: what C still sends to B goes on to A; C is told once it is up again.
  c.up = false;
  const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  c.up = true;
  assert.equal(c.rig.store.connectThreadStation(`cl@${A}`, first.channel, first.threadTs), B, "not told yet");
  await c.connects.receive(`cl@${A}`, { type: "message", message: reply(first, "1800.3", "back?") });
  await w.quiet();
  assert.equal(c.rig.store.connectThreadStation(`cl@${A}`, first.channel, first.threadTs), A, `told as it was heard from again: ${JSON.stringify({ b: b.moves.handover.outs().map((o) => [o.step, o.to.slice(0, 1), o.routed, o.routes, o.shown, o.error]), a: a.moves.handover.outs().map((o) => [o.step, o.to.slice(0, 1), o.routed, o.routes.length]), c: c.moves.handover.outs().length, runsOn: b.connects.runsOn(`cl@${A}`) })}`);
  const home = a.rig.store.threadAt("slack:T1", first.channel, first.threadTs)!;
  assert.deepEqual(a.rig.said(home.id).map((m) => m.text), ["<@UBOT> look", "and the tests", "on it", "still there?", "back?"], "what was said there, once, in order");
});

test("a Slack thread's chat handed over, its station not reached: what is said in it is answered here by the station's notice, marked as one (so no station takes it for a person's message)", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const first = message({ text: "<@UBOT> look" });
  await a.connects.receive("cl", { type: "message", message: first });
  const key = sessionKey("cl", first.channel, first.threadTs);
  await endTurn(a, key);
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  b.up = false;
  const posts = a.rig.chat.posts.length;
  await a.connects.receive("cl", { type: "message", message: reply(first, "1800.1", "still there?") });
  await w.quiet();
  assert.equal(a.rig.chat.posts.length, posts + 1, "said in the thread");
  assert.match(a.rig.chat.lastText(), /^⚠️ /);
  assert.ok(a.rig.chat.marked.includes(posts), "as the station's notice");
});

test("two bots' sessions in one thread move together as one conversation; both bots' events go there", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const first = message({ text: "<@UBOT> one" });
  await a.connects.receive("cl", { type: "message", message: first });
  await a.connects.receive("gpt", { type: "message", message: first });
  const cl = sessionKey("cl", first.channel, first.threadTs);
  const gpt = sessionKey("gpt", first.channel, first.threadTs);
  await endTurn(a, cl);
  await endTurn(a, gpt, "codex");
  assert.deepEqual(a.moves.handover.together(cl), [cl, gpt].sort());
  assert.deepEqual(a.moves.handover.together(gpt), [cl, gpt].sort());
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: cl });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.equal(a.rig.store.handedTo(cl)?.station, B);
  assert.equal(a.rig.store.handedTo(gpt)?.station, B);
  assert.ok(b.rig.store.getSession(cl) !== null, "cl moved to B");
  assert.ok(b.rig.store.getSession(gpt) !== null, "gpt moved together to B");
  assert.equal(b.rig.store.conversationOf(gpt), b.rig.store.conversationOf(cl));
  await a.connects.receive("gpt", { type: "message", message: reply(first, "1801.1", "<@UGPT> you", { addressed: true }) });
  await a.connects.receive("cl", { type: "message", message: reply(first, "1801.2", "<@UBOT> you", { addressed: true }) });
  await w.quiet();
  assert.equal(a.rig.codex.sessions.flatMap((x) => x.prompts).join("\n").includes("<@UGPT> you"), false, "gpt no longer runs on A");
  assert.equal(b.rig.claude.count(), 1, "cl's there");
  assert.equal(b.rig.codex.count(), 1, "gpt's there too");
  const there = b.rig.store.threadAt("slack:T1", first.channel, first.threadTs)!;
  assert.equal(b.rig.said(there.id).at(-1)?.text, "<@UBOT> you");
});

test("a chat with a running job: stopped as it is held, started there once it is there, at no moment on both", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const cwd = a.rig.session(key).workspace;
  a.jobs.push({ id: "a-dev", session: key, name: "dev", command: "npm run dev", cwd, port: 3000, watch: false });
  const both: [string, number, number][] = [];
  a.onFail = (step) => void both.push([step, a.jobs.length, b.jobs.length]);
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key, follow: ["jobs"] });
  await w.quiet();
  assert.deepEqual(out.done.map((d) => d.module), ["chats", "jobs"]);
  // (running here while its files go a first time, the chat working; stopped as it is held, until it is there)
  const held = both.findIndex(([step]) => step === "held");
  assert.ok(held > 0, JSON.stringify(both));
  assert.ok(both.slice(0, held).every(([, a, b]) => a === 1 && b === 0), `running here only, first: ${JSON.stringify(both)}`);
  assert.ok(both.slice(held + 1).every(([, a, b]) => a === 0 && b === 0), `stopped while it moved: ${JSON.stringify(both)}`);
  assert.equal(a.jobs.length, 0);
  assert.deepEqual(b.jobs.map((j) => [j.session, j.name, j.cwd]), [[key, "dev", b.rig.session(key).workspace]]);
  // The job back alone, its chat still there: stopped there, kept here stopped, waiting for its chat, never started here.
  const alone = await a.moves.scheduler.back(WS, B, { module: "jobs", item: `${key}#dev` });
  assert.deepEqual(alone.stopped, [{ item: { module: "jobs", id: `${key}#dev` }, waitsFor: { module: "chats", id: key } }]);
  assert.equal(b.jobs.length, 0);
  assert.equal(a.jobs.length, 0, "not run here before its chat is here");
  // The chat back as a person asks it (POST /move/back): its job starts here as it is here, once.
  const back = await a.ask("POST", "/move/back", { from: B, module: "chats", item: key });
  assert.equal(back.status, 202);
  await a.moves.scheduler.settle();
  await w.quiet();
  assert.equal(a.moves.scheduler.last(WS)?.failed, null, JSON.stringify(a.moves.scheduler.last(WS)));
  assert.deepEqual(a.jobs.map((j) => j.name), ["dev"]);
  assert.deepEqual(a.started, [`${key}#dev@${a.rig.session(key).workspace}`], "started here once, its chat here");
  assert.equal(a.moves.scheduler.stopped().length, 0);
});

test("a chat with a job there moved back: its job stops there first, the chat comes back, then its job starts here, once", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  a.jobs.push({ id: "a-dev", session: key, name: "dev", command: "npm run dev", cwd: a.rig.session(key).workspace, port: 3000, watch: false });
  const moved = await a.ask("POST", "/move", { to: B, module: "chats", item: key });
  assert.equal(moved.status, 202);
  await a.moves.scheduler.settle();
  await w.quiet();
  assert.equal(b.jobs.length, 1);
  const back = await a.ask("POST", "/move/back", { from: B, module: "chats", item: key });
  assert.equal(back.status, 202);
  await a.moves.scheduler.settle();
  await w.quiet();
  const last = a.moves.scheduler.last(WS)!;
  assert.equal(last.failed, null, JSON.stringify(last));
  assert.deepEqual(last.refused, []);
  assert.deepEqual(last.done.map((d) => d.module), ["jobs", "chats"], "its job first, stopped there");
  assert.deepEqual(last.resumed, [{ module: "jobs", id: `${key}#dev` }], "then started here as the chat came");
  assert.equal(b.jobs.length, 0);
  assert.deepEqual(a.jobs.map((j) => [j.session, j.name]), [[key, "dev"]]);
  assert.ok(!a.started.some((s) => s.includes("its chat away")), JSON.stringify(a.started));
  await startedAgainChangesNothing(w, key, "its job back with it");
});

test("a chat's files are told as they go: their total first, then how far, up to all of it", async () => {
  const w = world();
  const a = w.get(A);
  const { key } = await stillfailChat(a);
  const told: { done: number; total: number; unit: string }[] = [];
  await a.moves.handover.handOver(key, B, { progress: (p) => void told.push(p) });
  await w.quiet();
  assert.ok(told.length >= 2, JSON.stringify(told));
  assert.equal(told[0]!.done, 0);
  assert.ok(told[0]!.total > 0);
  assert.deepEqual(told.at(-1), { done: told[0]!.total, total: told[0]!.total, unit: "bytes" });
  assert.ok(told.every((p, i) => i === 0 || p.done >= told[i - 1]!.done), "only forward");
});

test("an archived chat is handed over archived, its workspace's archive with it", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  a.rig.store.setArchived(key, true, "p@x");
  const tarA = join(dirname(a.rig.session(key).workspace), "workspace.tar.zst");
  writeFileSync(tarA, "a workspace as its archive keeps it");
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.notEqual(b.rig.session(key).archivedAt, null);
  assert.equal(b.rig.session(key).archivedBy, "p@x");
  assert.equal(readFileSync(join(dirname(b.rig.session(key).workspace), "workspace.tar.zst"), "utf8"), "a workspace as its archive keeps it");
});

test("a chat working in a checkout of its own: its commits no remote has and its changes not committed are there as here", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const ws = a.rig.session(key).workspace;
  const env = { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@x", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@x", GIT_CONFIG_NOSYSTEM: "1", HOME: a.rig.dir };
  const git = (dir: string, ...args: string[]) => execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", env }).trim();
  git(ws, "init", "-q", "-b", "main");
  writeFileSync(join(ws, "app.ts"), "one\n");
  git(ws, "add", "-A");
  git(ws, "commit", "-q", "-m", "not pushed anywhere");
  writeFileSync(join(ws, "app.ts"), "one\ntwo, not committed\n");
  const head = git(ws, "rev-parse", "HEAD");
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  const there = b.rig.session(key).workspace;
  assert.equal(git(there, "rev-parse", "HEAD"), head);
  assert.equal(git(there, "log", "-1", "--format=%s"), "not pushed anywhere");
  assert.equal(readFileSync(join(there, "app.ts"), "utf8"), "one\ntwo, not committed\n");
  assert.match(git(there, "status", "--porcelain"), /^M app\.ts$/m);
});

test("a file of the chat's room this station cannot read: the chat does not go, said in the station's words naming the file, and goes on here", async () => {
  const w = world();
  const a = w.get(A);
  const { key } = await stillfailChat(a);
  const file = join(a.rig.session(key).workspace, "locked.txt");
  writeFileSync(file, "secret\n");
  chmodSync(file, 0o000);
  try {
    const error = await a.moves.handover.handOver(key, B).then(() => null, (e: Error) => e.message);
    // (the drop's taking out there runs after its answer: waited for before what is left there is looked at)
    await w.quiet();
    assert.match(error ?? "", /读不到 1 个文件（.*locked\.txt）|cannot read 1 of its files \(.*locked\.txt\)/, `the station's words, naming it: ${error}`);
    assert.equal(a.rig.hub.chatHeld(key), null, "goes on here");
    assert.equal(a.rig.store.handedTo(key), null, "nothing of it went");
    assert.deepEqual(w.get(B).moves.handover.ins().filter((i) => i.step !== "dropped").map((i) => i.step), [], "nothing left half there");
  } finally {
    chmodSync(file, 0o644);
  }
});

test("a failure at each step before it went: the chat works here afterwards and nothing of it is there", async () => {
  for (const how of ["unreached", "full", "hash", "import", "counts", "a-restart"] as const) {
    const w = world();
    const a = w.get(A);
    const b = w.get(B);
    const { key, thread } = await stillfailChat(a);
    if (how === "unreached") b.up = false;
    if (how === "full") b.free = 1;
    if (how === "hash") w.tamper((to, r) => (r.method === "handover.put" && to === B ? { ...r, name: "0".repeat(64) } : r));
    if (how === "import") b.fails.add("import");
    if (how === "counts") a.fails.add("counts");
    if (how === "a-restart") a.onFail = (step) => {
      if (step !== "rows") return;
      a.onFail = null;
      void a.moves.close();
      throw new Error("the station stopped");
    };
    const error = await a.moves.handover.handOver(key, B).then(() => null, (e: Error) => e.message);
    if (how === "a-restart") {
      // (started again: what was under way did not go, and is undone there)
      a.moves = a.make();
      await a.moves.start();
    }
    b.up = true;
    await w.quiet();
    assert.notEqual(error, null, `${how}: refused`);
    if (how === "full") assert.match(error!, /free some room there|腾出空间/);
    if (how !== "a-restart") assert.match(error!, /goes on here|在这里继续/, how);
    // (stopped as it went, and started again: each says what to do next, in the station's words)
    if (how === "a-restart") {
      assert.match(error!, /once this station is up again[^]*then hand it over again|重新运行后[^]*之后再迁移一次/, how);
      assert.match(a.moves.handover.outOf(key)?.error ?? "", /Hand it over again \(station_move|需要时再迁移一次（station_move/, how);
    }
    assert.equal(a.rig.store.handedTo(key), null, how);
    assert.equal(a.rig.hub.handedOver(key), false, `${how}: not held here`);
    assert.equal(b.rig.store.getSession(key), null, `${how}: nothing of it there`);
    assert.equal(b.rig.store.listSessions().length, 0, how);
    // it works here: a message is taken in a turn
    say(a.rig.hub, thread, "p@x", "still here?");
    await w.quiet();
    // (a failure in the first pass of its files never held it: its agent's process goes on, so the turn is in it)
    assert.equal(a.rig.claude.count(), how === "unreached" || how === "full" || how === "hash" ? 1 : 2, `${how}: a turn here`);
    assert.ok(a.rig.claude.last().prompts.join("\n").includes("still here?"), how);
    await startedAgainChangesNothing(w, key, `failed: ${how}`);
  }
});

test("a chat goes only where it leaves the floor free there: the larger of 20 GiB and a tenth of that disk, said in numbers", async () => {
  const GiB = 1024 ** 3;
  // (its disk's size, its free bytes: refused or not; one that does not say its size keeps FLOOR_MIN)
  for (const [total, free, goes] of [[undefined, 19 * GiB, false], [undefined, 21 * GiB, true], [400 * GiB, 39 * GiB, false], [400 * GiB, 41 * GiB, true], [100 * GiB, 21 * GiB, true]] as const) {
    const w = world();
    const a = w.get(A);
    const b = w.get(B);
    const { key } = await stillfailChat(a);
    b.free = free;
    if (total !== undefined) b.total = total;
    const error = await a.moves.handover.handOver(key, B).then(() => null, (e: Error) => e.message);
    await w.quiet();
    const at = `${total ?? "-"} / ${free}`;
    if (goes) {
      assert.equal(error, null, at);
      assert.equal(a.rig.store.handedTo(key)?.station, B, at);
      continue;
    }
    assert.match(error ?? "", new RegExp(`has ${(free / GiB).toFixed(1)} GB free and this chat needs 0\\.0 GB, which would leave less than the ${Math.max(20, (total ?? 0) / GiB / 10).toFixed(1)} GB kept free there: free some room there|只剩 ${(free / GiB).toFixed(1)} GB.*要留出的 ${Math.max(20, (total ?? 0) / GiB / 10).toFixed(1)} GB`), at);
    assert.equal(a.rig.store.handedTo(key), null, at);
    assert.equal(b.rig.store.getSession(key), null, at);
  }
});

test("the station it goes to running out of room as a chat's files arrive refuses in numbers, drops what it took itself and keeps no record coming; the chat goes on here", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  for (let n = 0; n < 6; n++) writeFileSync(join(a.rig.session(key).workspace, `f${n}.txt`), `file ${n}\n`);
  // (B's disk full at its third file: the write fails as a full disk fails it; A's own drop never reaching B, so that
  // what B keeps is B's own doing)
  w.tamper((to, r) => {
    if (to === B && r.method === "handover.drop") throw new Error("station unreachable");
    return r;
  });
  let puts = 0;
  b.onFail = (step) => {
    if (step === "put" && ++puts === 3) throw Object.assign(new Error("ENOSPC: no space left on device, write"), { code: "ENOSPC" });
  };
  const error = await a.moves.handover.handOver(key, B).then(() => null, (e: Error) => e.message);
  await w.quiet();
  assert.match(error ?? "", /ran out of room as this chat's files arrived \(ENOSPC; .* free there now\)|磁盘满了（ENOSPC/, `B's own words: ${error}`);
  assert.equal(a.rig.store.handedTo(key), null, "it goes on here");
  assert.deepEqual(b.moves.handover.ins().filter((i) => i.step === "coming").map((i) => i.id), [], "no record coming on B");
  assert.equal(existsSync(join(b.rig.dir, "handover", "in", a.moves.handover.outOf(key)!.id)), false, "nothing B took of it kept");
});

test("a chat's failed carry asks its drop of the other even where the turn found that station gone a moment before", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  // (the files' requests found gone twice: the turn says B gone; the drop that follows is asked all the same)
  const toB: string[] = [];
  w.tamper((to, r) => {
    if (to === B) toB.push(r.method);
    if (to === B && r.method === "handover.lacking") throw new PeerGone();
    return r;
  });
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.notEqual(out.failed, null);
  assert.ok(toB.includes("handover.drop"), `the drop asked: ${toB.join(" ")}`);
  assert.deepEqual(b.moves.handover.ins().filter((i) => i.step === "coming").map((i) => i.id), [], "nothing left coming on B");
});

test("a hand-over coming here whose sender failed and never told its drop is dropped as this station starts, asked of the sender", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  // (the carry fails at its placing, and the drop never reaches B)
  b.fails.add("import");
  w.tamper((to, r) => {
    if (to === B && r.method === "handover.drop") throw new Error("station unreachable");
    return r;
  });
  assert.notEqual(await a.moves.handover.handOver(key, B).then(() => null, (e: Error) => e.message), null);
  await w.quiet();
  assert.equal(b.moves.handover.ins().filter((i) => i.step === "coming").length, 1, "B still holds it coming");
  // (B started again: it asks A, which says that hand-over failed)
  w.tamper((_to, r) => r);
  await b.moves.close();
  b.moves = b.make();
  await b.moves.start();
  await w.quiet();
  assert.deepEqual(b.moves.handover.ins().filter((i) => i.step === "coming").map((i) => i.id), [], "dropped as B started");
});

test("the station it goes to started again in the middle goes on from where it stood", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  a.onFail = (step) => {
    if (step !== "rows") return;
    a.onFail = null;
    void b.moves.close();
    b.moves = b.make();
  };
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.equal(b.rig.session(key).ws, null);
});

test("a chat's files go a first time while it works, then only what changed since while it is held: its pause does not grow with its room", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const room = a.rig.session(key).workspace;
  for (let i = 0; i < 40; i++) writeFileSync(join(room, `f${i}.txt`), `file ${i} `.repeat(200));
  const seen: { step: string; held: string | null; sent: number }[] = [];
  a.onFail = (step) => {
    const o = a.moves.handover.outOf(key);
    if (step === "held") writeFileSync(join(room, "f3.txt"), "changed while it was going");
    if (step === "files" || step === "held") seen.push({ step, held: a.rig.hub.chatHeld(key), sent: o?.sentBytes ?? 0 });
  };
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.deepEqual(seen.map((x) => [x.step, x.held !== null]), [["files", false], ["held", true], ["files", true]], "its files went first while it was not held");
  const o = a.moves.handover.outOf(key)!;
  assert.ok(seen[1]!.sent > 40 * 1000, "the room went in the first pass");
  assert.equal(o.sentBytes! - seen[1]!.sent, "changed while it was going".length, "held, only what changed since went");
  assert.equal(readFileSync(join(b.rig.session(key).workspace, "f3.txt"), "utf8"), "changed while it was going");
});

/// What an Antigravity CLI keeps of its conversations in profile `profile`'s home under data directory `data`
/// (replica/carry.ts `cliKept`).
const agyCli = (data: string, profile: string) => join(data, "homes", profile, "agy", ".gemini", "antigravity-cli");
const putFile = (path: string, text: string) => {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text);
};

/// A chat of A's with a past Antigravity CLI conversation on account cc (B knows it as ccb, a login lent): its database
/// with a -wal and its brain as the CLI was running, and another conversation of cc's beside it on both stations.
async function agyChat(a: ReturnType<ReturnType<typeof world>["get"]>, b: ReturnType<ReturnType<typeof world>["get"]>) {
  const { key } = await stillfailChat(a);
  const id = "agy-conv-1";
  a.rig.store.ranIn(key, id, "cc");
  a.rig.store.db.prepare("UPDATE runtime_sessions SET runtime = 'agy' WHERE session_key = ? AND id = ?").run(key, id);
  const cli = agyCli(a.rig.dir, "cc");
  putFile(join(cli, "conversations", `${id}.db`), "the database as the CLI ran");
  putFile(join(cli, "conversations", `${id}.db-wal`), "pages not yet in the database");
  putFile(join(cli, "brain", id, "scratch.txt"), "deleted before it went");
  putFile(join(cli, "brain", id, "plan.md"), "plan");
  for (const st of [a, b]) for (const p of ["cc", "ccb"]) putFile(join(agyCli(st.rig.dir, p), "conversations", "other.db-wal"), `another conversation's, ${p}`);
  // Held after its first pass: its CLI ended, its -wal checkpointed into the database and gone, a file of its brain too.
  a.onFail = (step) => {
    if (step !== "held") return;
    writeFileSync(join(cli, "conversations", `${id}.db`), "the database with its -wal checkpointed in");
    rmSync(join(cli, "conversations", `${id}.db-wal`));
    rmSync(join(cli, "brain", id, "scratch.txt"));
  };
  return { key, id };
}

test("an Antigravity CLI conversation whose -wal its first pass sent and which was checkpointed and gone by the second: none of it is left there beside the newer database, nor a file of its brain gone since; another conversation's -wal stays", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, id } = await agyChat(a, b);
  let first: string[] = [];
  const there = agyCli(b.rig.dir, "cc");
  b.placed = () => {
    if (first.length === 0) first = readdirSync(join(there, "conversations")).sort();
  };
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.deepEqual(first, [`${id}.db`, `${id}.db-wal`, "other.db-wal"], "its first pass placed the -wal as it was");
  assert.equal(readFileSync(join(there, "conversations", `${id}.db`), "utf8"), "the database with its -wal checkpointed in");
  assert.deepEqual(readdirSync(join(there, "conversations")).sort(), [`${id}.db`, "other.db-wal"], "the -wal its second pass did not name is gone");
  assert.deepEqual(readdirSync(join(there, "brain", id)), ["plan.md"], "and the file of its brain gone there");
  for (const p of ["cc", "ccb"]) assert.equal(readFileSync(join(agyCli(b.rig.dir, p), "conversations", "other.db-wal"), "utf8"), `another conversation's, ${p}`);
});

test("such a hand-over failing after its prune there: what was there before of the conversation is put back as it was, another conversation's -wal untouched", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, id } = await agyChat(a, b);
  // (B kept the conversation from an earlier trip: its -wal and its brain as they were then)
  const there = agyCli(b.rig.dir, "cc");
  putFile(join(there, "conversations", `${id}.db-wal`), "an earlier trip's");
  putFile(join(there, "brain", id, "scratch.txt"), "an earlier trip's");
  a.fails.add("counts");
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.notEqual(out.failed, null, "it failed");
  assert.equal(readFileSync(join(there, "conversations", `${id}.db-wal`), "utf8"), "an earlier trip's", "put back");
  assert.equal(readFileSync(join(there, "brain", id, "scratch.txt"), "utf8"), "an earlier trip's", "put back");
  assert.ok(!existsSync(join(there, "conversations", `${id}.db`)), "what it placed where nothing was taken out");
  assert.ok(!existsSync(join(there, "brain", id, "plan.md")), "what it placed where nothing was taken out");
  for (const p of ["cc", "ccb"]) assert.equal(readFileSync(join(agyCli(b.rig.dir, p), "conversations", "other.db-wal"), "utf8"), `another conversation's, ${p}`);
});

test("a failure in the first pass of its files: the chat was never held, works here, and nothing of it is there", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  a.fails.add("files");
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.ok((out.failed?.error ?? "").includes(tr(stationLang(), "station.move.why.failedHere")) && !(out.failed?.error ?? "").includes("the test failed"), `in the station's words, the cause the log's alone: ${out.failed?.error}`);
  assert.equal(a.rig.hub.chatHeld(key), null);
  assert.equal(b.rig.store.getSession(key), null);
  say(a.rig.hub, thread, "p@x", "still here?");
  await w.quiet();
  // (never held, its agent's process went on: the turn is in it)
  assert.equal(a.rig.claude.count(), 1);
  assert.ok(a.rig.claude.last().prompts.join("\n").includes("still here?"), "it works here");
});

test("the other station not answering as a chat's files go, or their carrying failing otherwise: said in the station's words (what happened, what to do), the cause in the log alone; the chat goes on here", async () => {
  for (const [how, thrown, key] of [
    ["no answer", "the other station answered nothing", "carryUnanswered"],
    ["its connection gone", "the other station's connection was gone: the request got no answer from it (asked again, it is dialed anew)", "carryUnanswered"],
    // (no answer in time is the turn's own reading of it: the station gone for the turn, move/station.ts `#ask`, said
    // for the files as the other not answering as they went)
    ["no answer in time", "peer request timed out; execution may have happened — query the same task key", "carryUnanswered"],
    ["something else", "EIO: i/o error, read", "carryFailed"],
  ] as const) {
    const w = world();
    const a = w.get(A);
    const b = w.get(B);
    const { key: chat, thread } = await stillfailChat(a);
    // (every file's request there fails as the transport would have it: no answer is sent again once, and is the
    // station gone the second time)
    let puts = 0;
    w.tamper((to, r) => {
      if (to === B && r.method === "handover.put" && ++puts >= 1) throw new Error(thrown);
      return r;
    });
    const lines: string[] = [];
    hearLines((l) => void lines.push(`${l.message} ${JSON.stringify(l.fields ?? {})}`));
    let out: Awaited<ReturnType<typeof a.moves.scheduler.move>> | undefined;
    try {
      out = await a.moves.scheduler.move(WS, B, { module: "chats", item: chat });
      await w.quiet();
    } finally {
      hearLines(null);
      w.tamper(null);
    }
    const said = out?.failed?.error ?? "";
    assert.ok(puts >= 1, `${how}: its files' requests went (${puts})`);
    assert.ok(said.includes(tr(stationLang(), `station.move.why.${key}`)), `${how}: in the station's words: ${said}`);
    assert.ok(!said.includes(thrown), `${how}: the cause not said to people: ${said}`);
    // (the files' failure logs its cause; the station found gone, the turn's own log line its cause)
    const logged = how === "no answer in time" || how === "no answer" ? "a station found gone in a turn" : "could not be carried";
    assert.ok(lines.some((l) => l.includes(logged) && l.includes(thrown.slice(0, 20))), `${how}: the cause in the log: ${lines.filter((l) => l.includes(logged)).join(" | ")}`);
    assert.equal(a.rig.hub.chatHeld(chat), null, `${how}: not held`);
    assert.equal(b.rig.store.getSession(chat), null, `${how}: nothing of it there`);
    say(a.rig.hub, thread, "p@x", "still here?");
    await w.quiet();
    assert.ok(a.rig.claude.last().prompts.join("\n").includes("still here?"), `${how}: it works here`);
  }
});

/// A chat of A's with files enough in its room for several of them to be sent, by key and thread.
async function roomyChat(a: ReturnType<ReturnType<typeof world>["get"]>) {
  const { key, thread } = await stillfailChat(a);
  const room = a.rig.session(key).workspace;
  for (let i = 0; i < 4; i++) writeFileSync(join(room, `part-${i}.md`), `part ${i} of what it was doing\n`.repeat(50 + i));
  return { key, thread };
}

test("a file's request that meets the other station's connection gone (no answer) is sent again once from its start, dialed anew: the chat goes, each file taken there once, none sent before it sent again", async () => {
  // (a pack a file, so that each file is a request of its own: a pack of several is the next test's)
  const w = world(undefined, { packMost: { files: 1 } });
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await roomyChat(a);
  const tried: string[] = [];
  const taken: string[] = [];
  w.tamper((to, r) => {
    if (to !== B || r.method !== "handover.put") return r;
    tried.push(String(r.name));
    if (tried.length === 2) throw new Error("the other station answered nothing");
    taken.push(String(r.name));
    return r;
  });
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  w.tamper(null);
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.equal(a.rig.store.handedTo(key)?.station, B, "it went");
  assert.notEqual(b.rig.store.getSession(key), null, "it is there");
  assert.ok(tried.length >= 3, `its files' requests: ${tried.length}`);
  assert.equal(tried.length, taken.length + 1, `one request more than taken, the one that met no answer: tried ${JSON.stringify(tried.map((h) => h.slice(0, 8)))}, taken ${JSON.stringify(taken.map((h) => h.slice(0, 8)))}`);
  assert.equal(tried[2], tried[1], "the file that met no answer sent again, next");
  // (each of the room's own files taken there once: the session's list and the index are sent with each pass by
  // design, the held one too, so they are not counted here)
  const room = a.rig.session(key).workspace;
  const roomFiles = readdirSync(room).filter((n) => statSync(join(room, n)).isFile()).map((n) => createHash("sha256").update(readFileSync(join(room, n))).digest("hex"));
  for (const h of roomFiles) assert.equal(taken.filter((t) => t === h).length, 1, `the room's file ${h.slice(0, 8)} taken there once: ${JSON.stringify(taken.map((t) => t.slice(0, 8)))}`);
  assert.ok(roomFiles.includes(tried[1]!), "the file that met no answer is one of the room's");
  assert.equal(taken.filter((h) => h === tried[0]).length, 1, "the one taken before it not sent again");
});

test("a pack of several files whose request meets the other station's connection gone halfway is sent again of only what it lacks then: those it took before are not sent again, none is missing", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const room = a.rig.session(key).workspace;
  // (bytes that do not compress, so that the pack's stream comes a file at a time)
  for (let i = 0; i < 6; i++) writeFileSync(join(room, `part-${i}.bin`), randomBytes(300 * 1024));
  const hashed = (dir: string) => (existsSync(dir) ? readdirSync(dir, { recursive: true }).map(String).filter((n) => /(^|\/)[0-9a-f]{64}$/.test(n)).map((n) => n.slice(-64)) : []);
  const inDir = join(b.rig.dir, "replica", "handover", "in");
  const packs: { count: number; there: string[] }[] = [];
  w.tamper((to, r) => {
    if (to !== B || r.method !== "handover.put" || r.pack !== "zstd") return r;
    packs.push({ count: Number(r.count), there: hashed(inDir) });
    if (packs.length !== 1) return r;
    // (its connection gone once a megabyte of it went: what came before is taken there, the rest never comes)
    const bytes = bytesOf(r)!;
    async function* cut(): Bytes {
      let went = 0;
      for await (const piece of bytes) {
        if (went >= 1024 * 1024) throw new Error("the other station answered nothing");
        went += piece.length;
        yield piece;
      }
    }
    return { ...r, [BYTES]: cut() };
  });
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  w.tamper(null);
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.equal(a.rig.store.handedTo(key)?.station, B, "it went");
  assert.ok(packs[0]!.count >= 6, `the room's files went in one pack: ${JSON.stringify(packs)}`);
  const took = packs[1]!.there.filter((h) => !packs[0]!.there.includes(h));
  assert.ok(took.length >= 2, `the pack cut halfway took some of its files there first: ${took.length}`);
  assert.equal(packs[1]!.count, packs[0]!.count - took.length, `sent again: only what it lacked then (${packs[1]!.count} of ${packs[0]!.count}, ${took.length} there)`);
  for (const n of readdirSync(room).filter((n) => n.endsWith(".bin"))) assert.deepEqual(readFileSync(join(b.rig.session(key).workspace, n)), readFileSync(join(room, n)), `${n} there as it is here`);
});

test("a request with no bytes that meets the other station's connection gone is sent again once, dialed anew; the station's second in the turn makes it gone, and the hand-over fails in the station's words, nothing held, nothing left there", async () => {
  // (once: a page of its rows)
  {
    const w = world();
    const a = w.get(A);
    const { key } = await stillfailChat(a);
    let rows = 0;
    w.tamper((to, r) => {
      if (to === B && r.method === "handover.rows" && ++rows === 1) throw new Error("the other station answered nothing");
      return r;
    });
    const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
    await w.quiet();
    w.tamper(null);
    assert.equal(out.failed, null, JSON.stringify(out));
    assert.equal(a.rig.store.handedTo(key)?.station, B, "it went");
    assert.ok(rows >= 2, "the page asked again");
  }
  // (twice in the turn, a file and then the file again: gone)
  {
    const w = world(undefined, { packMost: { files: 1 } });
    const a = w.get(A);
    const b = w.get(B);
    const { key, thread } = await roomyChat(a);
    let puts = 0;
    w.tamper((to, r) => {
      if (to === B && r.method === "handover.put" && (++puts === 2 || puts === 3)) throw new Error("the other station answered nothing");
      return r;
    });
    const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
    await w.quiet();
    w.tamper(null);
    assert.equal(puts, 3, "the file sent once more, no more");
    assert.ok((out.failed?.error ?? "").includes(tr(stationLang(), "station.move.why.carryUnanswered")), `in the station's words: ${out.failed?.error}`);
    assert.equal(a.rig.hub.chatHeld(key), null, "not held");
    assert.equal(a.rig.store.handedTo(key), null, "it stayed");
    assert.equal(b.rig.store.getSession(key), null, "nothing of it there");
    say(a.rig.hub, thread, "p@x", "still here?");
    await w.quiet();
    assert.ok(a.rig.claude.last().prompts.join("\n").includes("still here?"), "it works here");
  }
  // (once a turn, not once a file: a file sent again and taken, then a later, other file meeting no answer: gone)
  {
    const w = world(undefined, { packMost: { files: 1 } });
    const a = w.get(A);
    const b = w.get(B);
    const { key } = await roomyChat(a);
    const tried: string[] = [];
    w.tamper((to, r) => {
      if (to !== B || r.method !== "handover.put") return r;
      tried.push(String(r.name));
      if (tried.length === 2 || tried.length === 5) throw new Error("the other station answered nothing");
      return r;
    });
    const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
    await w.quiet();
    w.tamper(null);
    assert.equal(tried.length, 5, `no request after the second no-answer of the turn: ${tried.length}`);
    assert.equal(tried[2], tried[1], "the first sent again");
    assert.notEqual(tried[4], tried[1], "the second no-answer is another file's");
    assert.ok((out.failed?.error ?? "").includes(tr(stationLang(), "station.move.why.carryUnanswered")), `in the station's words: ${out.failed?.error}`);
    assert.equal(a.rig.hub.chatHeld(key), null, "not held");
    assert.equal(a.rig.store.handedTo(key), null, "it stayed");
    assert.equal(b.rig.store.getSession(key), null, "nothing of it there");
  }
});

test("a chat that went as its station stopped, before its rows here said so: started again, it is handed here and shown there once", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  const before = entries(a, thread);
  a.onFail = (step) => {
    if (step !== "gone") return;
    a.onFail = null;
    void a.moves.close();
  };
  a.fails.add("gone");
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key }).catch(() => {});
  await w.quiet();
  assert.equal(a.rig.store.handedTo(key), null, "its rows here do not say so yet");
  a.moves = a.make();
  await a.moves.start();
  await w.quiet();
  assert.equal(a.rig.store.handedTo(key)?.station, B);
  assert.equal(a.rig.hub.handedOver(key), true);
  assert.equal(a.rig.hub.chatHeld(key), null, "let go");
  const there = homeThread(b, key);
  assert.equal(b.rig.session(key).ws, null, "shown there");
  assert.deepEqual(entries(b, there), before, "once");
  assert.equal(a.moves.handover.outOf(key)!.step, "done");
});

test("the station it goes to stopped between a page of rows put in and its hand-over's file saved: dropped, nothing of that page is left", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  b.onFail = (step) => {
    if (step !== "imported") return;
    b.onFail = null;
    b.up = false;
  };
  b.fails.add("imported");
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  assert.notEqual(out.failed, null);
  // (B comes up again: a new process, what it reads of the hand-over its files and its database)
  await b.moves.close();
  b.moves = b.make();
  b.up = true;
  await b.moves.start();
  a.moves.handover.reached(B);
  await w.quiet();
  assert.equal(b.rig.store.getSession(key), null, "the page put in is taken out");
  assert.equal(a.rig.hub.chatHeld(key), null);
});

test("the station it leaves stopped while the chat is held and its files are being placed there: the drop it then sends waits for the placing and leaves nothing of that hand-over there, and the chat goes on here", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  const room = a.rig.session(key).workspace;
  writeFileSync(join(room, "first.md"), "sent while it works");
  const roomThere = room.replace(a.rig.dir, b.rig.dir);
  // The held pass's placing there takes long; this station stops meanwhile.
  let placings = 0;
  let release: () => void = () => {};
  let reached: () => void = () => {};
  const atHeld = new Promise<void>((r) => (reached = r));
  b.placing = async () => {
    if (++placings !== 2) return;
    reached();
    await new Promise<void>((r) => (release = r));
  };
  a.onFail = (step) => {
    if (step !== "held") return;
    a.onFail = null;
    mkdirSync(join(room, "made", "in", "the", "hold"), { recursive: true });
    writeFileSync(join(room, "made", "in", "the", "hold", "late.md"), "written as it was held");
  };
  // (what ended first, of the held pass's placing and the drop)
  const order: string[] = [];
  b.placed = () => void (placings === 2 && order.push("placed"));
  const moving = a.moves.handover.handOver(key, B, { wait: true }).then(() => null, (e: Error) => e.message);
  await atHeld;
  assert.ok(existsSync(join(roomThere, "first.md")), "the first pass placed there");
  const id = b.moves.handover.ins()[0]!.id;
  await a.moves.close();
  a.moves = a.make();
  // (the drop answered as it is asked; what it takes out there, once that station gets to it)
  b.dropping = async () => void order.push("dropped");
  const started = a.moves.start();
  // (the drop is there, waiting or not, before the placing goes on)
  await a.rig.quiet();
  await b.rig.quiet();
  release();
  await started;
  assert.notEqual(await moving, null, "it did not go");
  await w.quiet();
  assert.deepEqual(order, ["placed", "dropped"], "the drop's taking out waited for the placing under way");
  // What of it comes after its drop (a late page of rows, a show) is refused, and puts nothing in.
  const late = (request: Json) => a.bus.ask(B, { ...request, workspace: WS, origin: A, id });
  const why = (p: Promise<unknown>) => p.then(() => "taken", (e: Error) => e.message);
  assert.match(await why(late({ method: "handover.rows", table: "sessions", rows: a.rig.store.chatPage("sessions", key, null, 500, [key]) })), /dropped there|在那边已经撤回/);
  assert.match(await why(late({ method: "handover.show", sends: [] })), /dropped there|在那边已经撤回/);
  assert.deepEqual(b.moves.handover.ins().map((i) => i.step), ["dropped"]);
  assert.equal(b.rig.store.getSession(key), null, "no row of it there");
  assert.equal(existsSync(roomThere), false, `nothing of its room there: ${existsSync(roomThere) ? JSON.stringify(filesOf(roomThere)) : ""}`);
  assert.equal(a.rig.store.handedTo(key), null);
  assert.equal(a.rig.hub.chatHeld(key), null, "it goes on here");
  say(a.rig.hub, thread, "p@x", "still here?");
  await w.quiet();
  assert.ok(a.rig.claude.sessions.flatMap((x) => x.prompts).join("\n").includes("still here?"));
  await startedAgainChangesNothing(w, key, "dropped as it was placed");
});

test("a hand-over that fails after the other station made its linked worktree again (the drop coming, or this station stopped): nothing of it is left there, git's registration and the branch it made with it, the repository as it was; handed over again, git makes it again", async () => {
  for (const how of ["drop", "stopped"] as const) {
    const w = world();
    const a = w.get(A);
    const b = w.get(B);
    const { key } = await stillfailChat(a);
    const ws = a.rig.session(key).workspace;
    const run = (dir: string, ...args: string[]) => execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", env: gitEnv(a.rig.dir), stdio: ["ignore", "pipe", "pipe"] }).trim();
    const bare = join(a.rig.dir, "remote.git");
    execFileSync("git", ["init", "-q", "--bare", "-b", "main", bare], { env: gitEnv(a.rig.dir) });
    const repos = join(a.rig.dir, "repos");
    mkdirSync(repos, { recursive: true });
    execFileSync("git", ["clone", "-q", bare, join(repos, "proj")], { env: gitEnv(a.rig.dir), stdio: "ignore" });
    const clone = join(repos, "proj");
    writeFileSync(join(clone, "a.txt"), "pushed\n");
    run(clone, "add", "-A");
    run(clone, "commit", "-q", "-m", "pushed");
    run(clone, "push", "-q", "origin", "HEAD:main");
    run(clone, "worktree", "add", "-q", "-b", "feature", join(ws, "proj"));
    writeFileSync(join(ws, "proj", "a.txt"), "pushed\nnot pushed\n");
    run(join(ws, "proj"), "commit", "-q", "-am", "not pushed anywhere");
    const head = run(join(ws, "proj"), "rev-parse", "HEAD");
    assert.equal((await a.moves.scheduler.move(WS, B, { module: "repos", item: `repo:${bare}` })).failed, null);
    await w.quiet();
    const repoThere = join(b.rig.dir, "repos", readdirSync(join(b.rig.dir, "repos"))[0]!);
    const refsBefore = run(repoThere, "for-each-ref", "--format=%(refname) %(objectname)");
    const listBefore = run(repoThere, "worktree", "list", "--porcelain");
    const roomThere = ws.replace(a.rig.dir, b.rig.dir);
    // It fails once the other made the worktree: counted wrong (its drop comes), or this station stops as it is told.
    if (how === "drop") a.fails.add("counts");
    else a.onFail = (step) => {
      if (step !== "rows") return;
      a.onFail = null;
      assert.ok(existsSync(join(roomThere, "proj", ".git")), "made there before it stops");
      void a.moves.close();
      throw new Error("the station stopped");
    };
    const failed = await a.moves.handover.handOver(key, B, { wait: true }).then(() => null, (e: Error) => e.message);
    assert.notEqual(failed, null, how);
    if (how === "stopped") {
      a.moves = a.make();
      await a.moves.start();
    }
    await w.quiet();
    assert.equal(existsSync(roomThere), false, `${how}: nothing of its room there`);
    assert.doesNotMatch(run(repoThere, "worktree", "list", "--porcelain"), new RegExp(roomThere.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")), `${how}: git names no worktree of it there`);
    assert.equal(run(repoThere, "worktree", "list", "--porcelain"), listBefore, `${how}: the repository's worktrees as they were`);
    assert.equal(run(repoThere, "for-each-ref", "--format=%(refname) %(objectname)"), refsBefore, `${how}: its branches and refs as they were`);
    assert.equal(a.rig.hub.chatHeld(key), null, `${how}: it goes on here`);
    // Handed over again: git makes its worktree again there, refusing nothing.
    const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
    await w.quiet();
    assert.equal(out.failed, null, `${how}: ${JSON.stringify(out)}`);
    assert.equal(run(join(b.rig.session(key).workspace, "proj"), "rev-parse", "HEAD"), head, `${how}: git's worktree there`);
    await startedAgainChangesNothing(w, key, `worktree: ${how}`);
  }
});

test("a hand-over given up whose drop has not reached the other station yet, then the chat handed over again: the newer one drops the older there first, so the older's drop, coming late, takes nothing the newer counted", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const room = a.rig.session(key).workspace;
  writeFileSync(join(room, "kept.md"), "placed by the first, counted by the second");
  // The first: the other not reached once the chat is held (its first pass placed there), its drop owed.
  a.onFail = (step) => {
    if (step !== "held") return;
    a.onFail = null;
    b.up = false;
  };
  const first = await a.moves.handover.handOver(key, B, { wait: true }).then(() => null, (e: Error) => e.message);
  assert.notEqual(first, null);
  assert.equal(a.moves.handover.outs().find((o) => o.step === "failed")?.dropOwed, true, "its drop owed");
  b.up = true;
  // The second, before the first's drop is tried again.
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  const roomThere = b.rig.session(key).workspace;
  assert.deepEqual(filesOf(roomThere), filesOf(room), "its room there");
  // The first's drop, at last.
  await w.t.adjust(RETRY_MS * 4);
  await w.quiet();
  assert.equal(a.moves.handover.outs().some((o) => o.dropOwed), false, "the first's drop answered");
  assert.ok(existsSync(join(roomThere, "kept.md")), "what the second counted there still");
  assert.deepEqual(filesOf(roomThere), filesOf(room), "its room there still, whole");
  assert.equal(b.rig.session(key).ws, null, "shown there");
});

test("a Slack thread with unfetched deferred_files carries them across handover so the target station can list and fetch them, and a failed handover rolls them back cleanly", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const payload = Buffer.from("deferred-handover-bytes");
  a.rig.chat.download = async () => payload;
  const first = message({
    text: "<@UBOT> check this file later",
    files: [{ id: "F-HANDOVER-1", name: "report.txt", size: payload.length, url: "https://files.slack.com/F-HANDOVER-1" }],
  });
  await a.connects.receive("cl", { type: "message", message: first });
  const key = sessionKey("cl", first.channel, first.threadTs);
  await endTurn(a, key);
  const srcThread = a.rig.store.threadAt("slack:T1", first.channel, first.threadTs)!;
  assert.equal(srcThread.hasDeferred, true, "source thread marks has_deferred");
  assert.equal(a.rig.store.deferredFilesById(srcThread.id, "F-HANDOVER-1").length, 1);

  // First try fails at counts: target station must drop deferred_files cleanly.
  a.fails.add("counts");
  const failed = await a.moves.handover.handOver(key, B, { wait: true }).then(() => null, (e: Error) => e.message);
  assert.notEqual(failed, null);
  await w.quiet();
  assert.equal(b.rig.store.threadAt("slack:T1", first.channel, first.threadTs), null, "rolled back fresh thread on target");
  assert.equal((b.rig.store.db.prepare("SELECT COUNT(*) AS n FROM deferred_files").get() as { n: number }).n, 0, "no deferred_files leaked on rollback");

  // Second try succeeds: target station gets deferred_files + has_deferred = 1, lists and fetches via A's connect.
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  const dstThread = b.rig.store.threadAt("slack:T1", first.channel, first.threadTs)!;
  assert.equal(dstThread.hasDeferred, true, "target thread preserves has_deferred");
  assert.equal(b.rig.store.deferredFilesById(dstThread.id, "F-HANDOVER-1").length, 1, "target preserves deferred_files row");

  const listed = await b.rig.call(key, "chat_history", { to: `${first.channel}/${first.threadTs}` });
  assert.match(listed, /F-HANDOVER-1/, "chat_history on target lists unfetched file");
  const fetched = await b.rig.call(key, "chat_history", { to: `${first.channel}/${first.threadTs}`, fetch: ["F-HANDOVER-1"] });
  assert.match(fetched, /report\.txt/, "target fetched deferred file via source station connect");
  const dstThreadAfter = b.rig.store.threadAt("slack:T1", first.channel, first.threadTs)!;
  assert.equal(dstThreadAfter.hasDeferred, undefined, "has_deferred cleared after fetch on target");
});
