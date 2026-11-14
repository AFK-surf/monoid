// One chat handed from a station to another while both are up (replica/handover.ts), through the migration's modules
// and scheduler (move/): a still.fail chat goes on there on its runtime session, nothing said in it; a Slack thread's
// chat goes on there with its connect where it was, or on a third station; two bots' sessions in one thread move each on
// its own; a job runs on one station at a time; a failure at each step leaves the chat working here and nothing of it
// there; one handed back has what was said there, once, in order; what is said while it is held is delivered once where
// it ends up; a whole station is moved chat by chat, one that cannot listed with why; an account that cannot be
// borrowed moved first stops the chats that need it, until they move or it comes back. Stations are Rigs (hub-fakes.ts)
// with their connects (connects/workspace.ts) and their moves (move/station.ts), over a transport of the test's.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, test } from "node:test";
import { PeerBus, bytesOf, withBytes } from "../src/mesh/bus.ts";
import { WorkspaceConnects } from "../src/connects/workspace.ts";
import { Fibers } from "../src/ops/fibers.ts";
import { gather, place } from "../src/replica/carry-worker.ts";
import { RETRY_MS } from "../src/replica/retire.ts";
import type { CarriedJob } from "../src/replica/carry-worker.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { sessionKey } from "../src/sessions/hub.ts";
import { newSession, say } from "../src/sessions/lifecycle.ts";
import { Moves } from "../src/move/station.ts";
import { Rig, message, reply, testClock } from "./hub-fakes.ts";

type Json = any;
const WS = "ws";
const A = "a".repeat(64);
const B = "b".repeat(64);
const C = "c".repeat(64);

function across(v: Json): Json {
  const bytes = bytesOf(v);
  const copy = JSON.parse(JSON.stringify(v));
  return bytes === null ? copy : withBytes(copy, bytes);
}

type Station = {
  id: string; rig: Rig; bus: PeerBus; connects: WorkspaceConnects; moves: Moves; fibers: Fibers; up: boolean;
  jobs: (CarriedJob & { id: string })[]; started: string[]; free: number; fails: Set<string>; onFail: ((step: string) => void) | null;
  make(): Moves;
};

const open: (() => Promise<void>)[] = [];
afterEach(async () => {
  for (const c of open.splice(0).reverse()) await c().catch(() => {});
});

/// Stations of workspace "ws" (each its own Rig, its connects and its moves); A has the Slack connects cl and gpt.
function world(ids: string[] = [A, B]) {
  const t = testClock();
  const stations = new Map<string, Station>();
  const roster = ids.map((id) => ({ id, name: id.slice(0, 1).toUpperCase() }));
  /// A request on its way, changed (a test's: a hash refused).
  let tamper: ((to: string, request: Json) => Json) | null = null;
  const make = (id: string): Station => {
    const rig = new Rig({ place: { workspace: WS, station: id }, workspaces: [WS], fileStore: true, clock: t.clock });
    const st = { id, rig, up: true, jobs: [], started: [], free: 1e15, fails: new Set<string>(), onFail: null } as unknown as Station;
    st.bus = new PeerBus({ sleep: async () => {} });
    st.bus.attach(async (to, ws, request) => {
      const there = stations.get(to);
      if (there === undefined || !there.up || !st.up) throw new Error("station unreachable");
      const sent = tamper === null ? request : tamper(to, request);
      return across(await there.bus.handle(ws ?? WS, id, across(sent)));
    });
    const tag = id.slice(0, 1);
    rig.raw.profiles = id === A
      ? [{ id: "cc", runtime: "claude", home: "homes/cc", share: { id: "sh-cc" } }, { id: "cx", runtime: "codex", home: "homes/cx", env: { OPENAI_API_KEY: "k" } }, { id: "mine", runtime: "claude", home: "homes/mine", machine: true }]
      : [{ id: `cc${tag}`, runtime: "claude", home: `homes/cc${tag}`, share: { id: "sh-cc", borrowed: true, host: A } }, { id: `cx${tag}`, runtime: "codex", home: `homes/cx${tag}`, env: { OPENAI_API_KEY: "k" } }];
    if (id !== A) rig.raw.connects = [];
    else rig.raw.connects = rig.raw.connects.filter((c: Json) => c.id !== "team");
    const config = () => {
      const read = hubConfig(rig.raw, rig.dir);
      read.connects.push(...st.connects.remote.connects());
      return read;
    };
    Object.defineProperty(rig, "config", { get: config, configurable: true });
    const local = new Map([["cl", rig.chat], ["gpt", rig.gptChat]]);
    rig.hub = rig.newHub({ chats: (c) => (rig.raw.connects.some((e: Json) => e.id === c) ? local.get(c) : undefined) ?? st.connects.remote.surface(c) });
    st.connects = new WorkspaceConnects({
      data: rig.dir, hub: () => rig.hub, store: rig.store, config: { raw: () => rig.raw, update: (f) => f(rig.raw) }, bus: st.bus,
      here: () => id, home: () => WS, stations: (ws) => (ws === WS ? roster : []), names: () => null,
    });
    st.fibers = new Fibers("move", t.clock);
    st.make = () => {
      const wc = st.connects;
      const hub = rig.hub;
      const moves = new Moves({
        data: rig.dir, store: rig.store, fibers: st.fibers, here: () => id, home: () => WS, roster: () => roster,
        ask: (s, r) => st.bus.ask(s, r),
        hub: { holdChat: (k, w) => hub.holdChat(k, w), releaseChat: (k) => hub.releaseChat(k), wakeChat: (k) => hub.wakeChat(k), busy: (k) => hub.busy(k), turnEnded: (k) => hub.turnEnded(k), drained: (c, ch, ts) => hub.drained(c, ch, ts), wsOf: (k) => hub.wsOf(k) },
        connects: {
          route: (c, ch, ts, to) => wc.route(c, ch, ts, to), describedFor: (c) => wc.describedFor(c), learnOf: (k, s, d) => wc.learnOf(k, s, d), kindOf: (c) => wc.kindOf(c),
          own: () => wc.ownIds(), ownIn: (ws) => wc.ownKinds(ws), runsOn: (c) => wc.runsOn(c), move: (c, to) => wc.move(c, to, null),
        },
        jobs: {
          up: (keys, ws) => st.jobs.filter((j) => (keys === null ? ws === undefined || hub.ofWorkspace(j.session, ws) : keys.includes(j.session))),
          stop: async (jid) => void (st.jobs = st.jobs.filter((j) => j.id !== jid)),
          start: (j) => {
            st.jobs.push({ ...j, id: `${tag}-job-${st.started.length}` });
            st.started.push(`${j.session}#${j.name}@${j.cwd}`);
          },
          stopNamed: async (s, n) => void (st.jobs = st.jobs.filter((j) => !(j.session === s && j.name === n))),
        },
        profiles: () => rig.raw.profiles,
        moveProfile: async (pid, to) => {
          const p = rig.raw.profiles.find((x: Json) => x.id === pid);
          const there = stations.get(to)!;
          there.rig.raw.profiles.push(structuredClone(p));
          rig.raw.profiles = rig.raw.profiles.filter((x: Json) => x.id !== pid);
          return { id: pid };
        },
        sessionsIn: (ws, after, limit) => rig.store.sessionsOfWs(ws === WS ? null : ws, WS, after, limit),
        reposDir: join(rig.dir, "repos"),
        room: async () => ({ free: st.free }),
        hasGit: async () => true,
        lackMost: 50,
        work: {
          gather: async (dataDir, db, ws, home, scratch, _signal, agent, keys) => gather(dataDir, db, ws, home, scratch, agent ?? null, keys ?? null),
          place: async (dataDir, index, from, made) => place(dataDir, index, from, made ?? null),
        },
        fail: (step) => {
          st.onFail?.(step);
          if (st.fails.delete(step)) throw new Error(`the test failed ${step}`);
        },
      });
      st.bus.on("handover.", moves.answers(() => true));
      st.bus.on("move.", moves.answers(() => true));
      return moves;
    };
    st.moves = st.make();
    stations.set(id, st);
    open.push(async () => {
      await st.moves.close();
      await st.fibers.close();
      await rig.close();
    });
    return st;
  };
  for (const id of ids) make(id);
  const quiet = async () => {
    for (let i = 0; i < 3; i++) for (const s of stations.values()) {
      await s.moves.handover.settle();
      await s.rig.quiet();
    }
  };
  return { t, stations, get: (id: string) => stations.get(id)!, quiet, tamper: (f: typeof tamper) => void (tamper = f) };
}

/// The running turn of a station's session ended with a state, as its agent would.
async function endTurn(st: Station, key: string, driver: "claude" | "codex" = "claude") {
  await st.rig.quiet();
  await st.rig.call(key, "chat_state", { kind: "final" });
  st.rig[driver].last().complete();
  await st.rig.quiet();
}

/// A still.fail chat of A's with a turn behind it (its runtime session `claude-1` on account cc) and a file of its own.
async function stillfailChat(st: Station) {
  const [key, thread] = newSession(st.rig.hub, { runtime: "claude", profile: "cc", createdBy: "p@x" });
  say(st.rig.hub, thread.id, "p@x", "look at the build");
  await st.rig.quiet();
  await endTurn(st, key);
  const ws = st.rig.session(key).workspace;
  mkdirSync(ws, { recursive: true });
  writeFileSync(join(ws, "notes.md"), "what I was doing");
  return { key, thread: thread.id };
}

const entries = (st: Station, thread: number) => st.rig.store.entriesAfter(thread, 0).map((e) => `${e.authorKind}:${e.text ?? ""}`);
const homeThread = (st: Station, key: string) => st.rig.store.homeChat(key)?.id ?? st.rig.store.sessionThreads(key)[0]!.thread.id;

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
  assert.equal(plan.items.find((x) => x.id === "share:sh-cc")!.state, "there", "B borrows it already");
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
  await w.t.adjust(RETRY_MS);
  await w.quiet();
  assert.equal(c.rig.store.connectThreadStation(`cl@${A}`, first.channel, first.threadTs), A, "told as it was tried again");
  const home = a.rig.store.threadAt("slack:T1", first.channel, first.threadTs)!;
  assert.deepEqual(a.rig.said(home.id).map((m) => m.text), ["<@UBOT> look", "and the tests", "on it", "still there?", "back?"], "what was said there, once, in order");
});

test("two bots' sessions in one thread: one handed over, the other stays; each bot's events go to its own", async () => {
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
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: cl });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.equal(a.rig.store.handedTo(cl)?.station, B);
  assert.equal(a.rig.store.handedTo(gpt), null);
  assert.equal(b.rig.store.getSession(gpt), null, "the other bot's stays");
  await a.connects.receive("gpt", { type: "message", message: reply(first, "1801.1", "<@UGPT> you", { addressed: true }) });
  await a.connects.receive("cl", { type: "message", message: reply(first, "1801.2", "<@UBOT> you", { addressed: true }) });
  await w.quiet();
  assert.ok(a.rig.codex.sessions.flatMap((x) => x.prompts).join("\n").includes("<@UGPT> you"), "gpt's goes on here");
  assert.equal(b.rig.claude.count(), 1, "cl's there");
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
  const both: number[] = [];
  a.onFail = () => void both.push(a.jobs.length + b.jobs.length);
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key, follow: ["jobs"] });
  await w.quiet();
  assert.deepEqual(out.done.map((d) => d.module), ["chats", "jobs"]);
  assert.ok(both.every((n) => n === 0), `stopped while it moved: ${both}`);
  assert.equal(a.jobs.length, 0);
  assert.deepEqual(b.jobs.map((j) => [j.session, j.name, j.cwd]), [[key, "dev", b.rig.session(key).workspace]]);
  // back: stopped there, started here
  await a.moves.scheduler.back(WS, B, { module: "jobs", item: `${key}#dev` });
  assert.equal(b.jobs.length, 0);
  assert.deepEqual(a.jobs.map((j) => j.name), ["dev"]);
});

test("an archived chat is handed over archived", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  a.rig.store.setArchived(key, true, "p@x");
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.notEqual(b.rig.session(key).archivedAt, null);
  assert.equal(b.rig.session(key).archivedBy, "p@x");
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
    if (how === "full") assert.match(error!, /free some room there/);
    if (how !== "a-restart") assert.match(error!, /goes on here/, how);
    assert.equal(a.rig.store.handedTo(key), null, how);
    assert.equal(a.rig.hub.handedOver(key), false, `${how}: not held here`);
    assert.equal(b.rig.store.getSession(key), null, `${how}: nothing of it there`);
    assert.equal(b.rig.store.listSessions().length, 0, how);
    // it works here: a message is taken in a turn
    say(a.rig.hub, thread, "p@x", "still here?");
    await w.quiet();
    assert.equal(a.rig.claude.count(), 2, `${how}: a turn here`);
    assert.ok(a.rig.claude.last().prompts.join("\n").includes("still here?"), how);
  }
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

test("handed over, then back: what was said there is in its log here once, in order; it goes on here", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  const there = homeThread(b, key);
  say(b.rig.hub, there, "p@x", "said there");
  await w.quiet();
  await b.rig.call(key, "chat_post", { to: `CHAT/${b.rig.store.getThread(there)!.threadTs}`, text: "answered there" });
  await endTurn(b, key);
  const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.equal(a.rig.store.handedTo(key), null);
  assert.equal(b.rig.store.handedTo(key)?.station, A);
  assert.deepEqual(entries(a, thread), entries(b, there), "the same log, once");
  assert.ok(entries(a, thread).includes("person:said there"));
  assert.equal(entries(a, thread).filter((e) => e === "person:said there").length, 1);
  assert.equal(a.rig.session(key).ws, null);
  assert.equal(a.rig.session(key).profile, "cc");
  say(a.rig.hub, thread, "p@x", "home again");
  await w.quiet();
  assert.equal(a.rig.claude.last().options.resume, "claude-1");
});

test("a message sent while the chat is held is delivered once, there", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  a.onFail = (step) => {
    if (step === "files") say(a.rig.hub, thread, "p@x", "while it moves");
  };
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(a.rig.claude.count(), 1, "not taken here");
  const prompts = b.rig.claude.sessions.flatMap((s) => s.prompts).join("\n");
  assert.equal(prompts.split("while it moves").length - 1, 1, prompts);
});

test("a whole station handed over chat by chat: one whose account cannot go is listed with why, the others go", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const one = await stillfailChat(a);
  const two = await stillfailChat(a);
  const [mine] = newSession(a.rig.hub, { runtime: "claude", profile: "mine", createdBy: "p@x" });
  const out = await a.moves.scheduler.move(WS, B, { all: true, follow: ["jobs"] });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out.failed));
  assert.ok(out.done.some((d) => d.id === one.key) && out.done.some((d) => d.id === two.key));
  const refused = out.refused.find((r) => r.item.id === mine);
  assert.match(refused?.why ?? "", /needs accounts machine:mine/);
  assert.match(out.refused.find((r) => r.item.id === "machine:mine")?.why ?? "", /this machine's own login/);
  assert.equal(b.rig.store.getSession(mine), null);
  assert.equal(a.rig.hub.handedOver(mine), false, "it works here");
});

test("an account that cannot be borrowed moved first: its chats here stop, naming it; a message to one is delivered once after it moved; moved back, the others go on here", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  a.rig.raw.profiles.push({ id: "solo", runtime: "claude", home: "homes/solo" });
  const make = async () => {
    const [key, t] = newSession(a.rig.hub, { runtime: "claude", profile: "solo", createdBy: "p@x" });
    say(a.rig.hub, t.id, "p@x", "hi");
    await endTurn(a, key);
    return { key, thread: t.id };
  };
  const one = await make();
  const two = await make();
  const out = await a.moves.scheduler.move(WS, B, { module: "accounts", item: `own:solo@${A}` });
  assert.deepEqual(out.stopped.map((s) => s.item.id).sort(), [one.key, two.key].sort());
  const plan = await a.moves.scheduler.plan(WS, B);
  assert.equal(plan.items.find((x) => x.id === one.key)!.state, "stopped");
  assert.deepEqual(plan.items.find((x) => x.id === one.key)!.waitsFor, { module: "accounts", id: `own:solo@${A}` });
  // a message to one waits, and is delivered once, there
  say(a.rig.hub, one.thread, "p@x", "for one");
  await w.quiet();
  assert.equal(a.rig.claude.count(), 2, "stopped: no turn");
  const moved = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key });
  await w.quiet();
  assert.equal(moved.failed, null, JSON.stringify(moved));
  const prompts = b.rig.claude.sessions.flatMap((s) => s.prompts).join("\n");
  assert.equal(prompts.split("for one").length - 1, 1, prompts);
  // its account cannot go back while a chat there needs it: said, naming it
  const back = await a.moves.scheduler.back(WS, B, { module: "accounts", item: `own:solo@${A}` });
  assert.deepEqual(back.refused.map((r) => r.item.id), [`own:solo@${A}`]);
  assert.match(back.refused[0]!.why, new RegExp(`chats ${one.key}`));
});

test("an account that cannot be borrowed moved, then back: its chats here stopped meanwhile go on here, what was said to them delivered once", async () => {
  const w = world();
  const a = w.get(A);
  a.rig.raw.profiles.push({ id: "solo", runtime: "claude", home: "homes/solo" });
  const [key, t] = newSession(a.rig.hub, { runtime: "claude", profile: "solo", createdBy: "p@x" });
  say(a.rig.hub, t.id, "p@x", "hi");
  await endTurn(a, key);
  await a.moves.scheduler.move(WS, B, { module: "accounts", item: `own:solo@${A}` });
  assert.equal(a.rig.hub.chatHeld(key), `stopped: waits for accounts own:solo@${A}, moved away`);
  say(a.rig.hub, t.id, "p@x", "while it is away");
  await w.quiet();
  assert.equal(a.rig.claude.count(), 1, "no turn while stopped");
  const back = await a.moves.scheduler.back(WS, B, { module: "accounts", item: `own:solo@${A}` });
  await w.quiet();
  assert.deepEqual(back.resumed, [{ module: "chats", id: key }]);
  assert.equal(a.rig.hub.chatHeld(key), null);
  const prompts = a.rig.claude.sessions.flatMap((s) => s.prompts).join("\n");
  assert.equal(prompts.split("while it is away").length - 1, 1, prompts);
});
