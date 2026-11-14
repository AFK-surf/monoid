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
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { afterEach, test } from "node:test";
import { PeerBus, bytesOf, withBytes } from "../src/mesh/bus.ts";
import { WorkspaceConnects } from "../src/connects/workspace.ts";
import { Fibers } from "../src/ops/fibers.ts";
import { gather, place } from "../src/replica/carry-worker.ts";
import type { CarriedJob } from "../src/replica/carry-worker.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { sessionKey } from "../src/sessions/hub.ts";
import { NOTICE_MARK } from "../src/sessions/chat.ts";
import { newSession, say } from "../src/sessions/lifecycle.ts";
import { Moves } from "../src/move/station.ts";
import { moveRoutes, moveView } from "../src/move/routes.ts";
import { MoveAsks } from "../src/tools/move.ts";
import type { Request } from "../src/api/request.ts";
import { plainStore } from "../src/vault/plain.ts";
import { vaultStore } from "../src/vault/store.ts";
import { METHOD, fromPeer } from "../src/sessions/messages.ts";
import { tell } from "../src/replica/copies.ts";
import { Exporter, genDir, nothingTold, ownDir } from "../src/replica/export.ts";
import { readCopy } from "../src/replica/restore.ts";
import { READ, forPeer } from "../src/sessions/others.ts";
import { Rig, given, message, reply, testClock } from "./hub-fakes.ts";
import { Admin } from "../src/api/admin.ts";
import { newCtx } from "../src/store/handover.ts";
import { claudeProject } from "../src/read/transcript.ts";

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
  /// Its API as a device asks it (api/admin.ts): what keeps a keyed write to once.
  admin: Admin;
  /// Moving switched on here (config.json `move`).
  on: boolean;
  /// The chats a plan reads at a time (none: the module's own).
  page?: number;
  /// The holds of its self-update now (updates/holds.ts, its own here); a move of an account that never ends.
  holds: number;
  profileHangs?: boolean;
  /// Called as its config.json is written by a module (a setting taken).
  onUpdate?: () => void;
  /// Its routes of move/routes.ts, as a device asks them.
  ask(method: string, path: string, body: Json, role?: string, query?: [string, string][]): Promise<{ status: number; body: Json }>;
  jobs: (CarriedJob & { id: string })[]; started: string[]; free: number; fails: Set<string>; onFail: ((step: string) => void) | null;
  /// Its own connects' surfaces, by their id here; git run as the station runs it.
  local: Map<string, Json>;
  git: (dir: string, args: string[]) => Promise<string>;
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
    const st = { id, rig, up: true, on: true, holds: 0, jobs: [], started: [], free: 1e15, fails: new Set<string>(), onFail: null } as unknown as Station;
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
    st.local = new Map<string, Json>([["cl", rig.chat], ["gpt", rig.gptChat]]);
    const config = () => {
      const read = hubConfig(rig.raw, rig.dir);
      read.connects.push(...st.connects.remote.connects());
      return read;
    };
    Object.defineProperty(rig, "config", { get: config, configurable: true });
    rig.hub = rig.newHub({ chats: (c) => (rig.raw.connects.some((e: Json) => e.id === c) ? st.local.get(c) : undefined) ?? st.connects.remote.surface(c) });
    st.connects = new WorkspaceConnects({
      data: rig.dir, hub: () => rig.hub, store: rig.store, config: { raw: () => rig.raw, update: (f) => f(rig.raw) }, bus: st.bus,
      here: () => id, home: () => WS, stations: (ws) => (ws === WS ? roster : []), names: () => null,
    });
    st.fibers = new Fibers("move", t.clock);
    st.admin = new Admin({ names: new Map(), read: async () => "{}" } as Json, { store: rig.store, agents: () => ({ hub: rig.hub }) as Json, clock: t.clock });
    st.make = () => {
      const wc = st.connects;
      const hub = rig.hub;
      const moves = new Moves({
        data: rig.dir, store: rig.store, fibers: st.fibers, here: () => id, home: () => WS, roster: () => roster,
        ask: (s, r) => st.bus.ask(s, r),
        hub: { holdChat: (k, w) => hub.holdChat(k, w), releaseChat: (k) => hub.releaseChat(k), wakeChat: (k) => hub.wakeChat(k), busy: (k) => hub.busy(k), turnEnded: (k) => hub.turnEnded(k), drained: (c, ch, ts) => hub.drained(c, ch, ts), wsOf: (k) => hub.wsOf(k) },
        connects: {
          route: (c, ch, ts, to) => wc.route(c, ch, ts, to), describedFor: (c) => wc.describedFor(c), learnOf: (k, s, d) => wc.learnOf(k, s, d), kindOf: (c) => wc.kindOf(c),
          own: () => wc.ownIds(), ownIn: (ws) => wc.ownKinds(ws), runsOn: (c) => wc.runsOn(c), move: (c, to, awaiting) => wc.move(c, to, null, undefined, undefined, awaiting ?? []), movedAway: (ws) => wc.movedAway(ws), arrived: (keys) => wc.arrived(keys),
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
          if (st.profileHangs) return await new Promise<never>(() => {});
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
          place: async (dataDir, index, from, made, aside, placed) => place(dataDir, index, from, made ?? null, aside ?? null, placed ?? null),
        },
        fail: (step) => {
          st.onFail?.(step);
          if (st.fails.delete(step)) throw new Error(`the test failed ${step}`);
        },
        git: st.git,
        config: { raw: () => rig.raw, update: (f) => (st.onUpdate?.(), f(rig.raw)) },
        moveOn: () => st.on,
        planPage: st.page,
        hold: () => {
          st.holds++;
          let gone = false;
          return () => void (gone || ((gone = true), st.holds--));
        },
        keptSends: (threads) => st.admin.keptSends(threads),
        keepSends: (sends) => st.admin.keepSends(sends),
        homeOf: (ws) => join(rig.dir, "agent-homes", ws),
        vault: {
          owners: (ws) => (rig.store.db.prepare("SELECT DISTINCT owner FROM vault_plain WHERE ws = ?").all(ws) as { owner: string }[]).map((r) => r.owner),
          grantOwners: () => [],
          plain: plainStore(rig.store.db),
          vaults: vaultStore(rig.store.db) as Json,
        },
      });
      st.bus.on("handover.", moves.answers(() => true));
      st.bus.on("move.", moves.answers(() => true));
      return moves;
    };
    st.git = async (dir: string, args: string[]) => execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", env: gitEnv(rig.dir), stdio: ["ignore", "pipe", "pipe"] }).trim();
    st.moves = st.make();
    const routes = moveRoutes({
      scheduler: { busy: () => st.moves.scheduler.busy(), last: (ws: string) => st.moves.scheduler.last(ws), plan: (ws: string, to: string) => st.moves.scheduler.plan(ws, to), stopped: () => st.moves.scheduler.stopped(), move: (...a: Parameters<Moves["scheduler"]["move"]>) => st.moves.scheduler.move(...a), back: (...a: Parameters<Moves["scheduler"]["back"]>) => st.moves.scheduler.back(...a), stopTurn: (by: string | null) => st.moves.scheduler.stopTurn(by), stopping: () => st.moves.scheduler.stopping() } as Json,
      order: () => st.moves.modules.map((m) => m.id), home: () => WS, here: () => id, rig: () => false,
      station: (_ws, v) => (roster.some((r) => r.id === v || r.name === v) ? { id: roster.find((r) => r.id === v || r.name === v)!.id, tasks: false } : null),
      refusal: (ws, s, lang) => st.moves.refusal(ws, s, lang),
    });
    st.ask = async (method, path, body, role = "owner", query = []) => {
      const route = routes.find((r) => r.method === method && r.pattern.test(path))!;
      const r: Request = { method, path, query, headers: {}, body: Buffer.from(body === null ? "" : JSON.stringify(body)), viewer: { sub: "o", email: `${role}@x`, name: role, role, workspace: WS, device: "d" } as Json, lang: "en" };
      const a = await route.handle(r, []);
      return { status: a.status, body: JSON.parse(String(a.body)) };
    };
    // (a letter to a chat of another station's, and one there coming here: messages.ts)
    rig.hub.onPeer((station, request) => st.bus.ask(station, request));
    st.bus.on(METHOD, (peer, request, ws) => fromPeer(rig.hub, peer, request, ws ?? null));
    st.bus.on(READ, (peer, request, ws) => forPeer(rig.hub, peer, request, ws ?? null));
    // (a station heard from again: what is owed to it is told now, as move/live.ts has it)
    st.bus.heard((peer) => {
      st.moves.handover.reached(peer);
      st.moves.heard(peer);
    });
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

const gitEnv = (home: string) => ({ ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@x", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@x", GIT_CONFIG_NOSYSTEM: "1", HOME: home });

/// The files under `dir`, by their path in it, with their bytes (what a room holds).
function filesOf(dir: string): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (at: string) => {
    for (const name of readdirSync(at)) {
      const path = join(at, name);
      if (statSync(path).isDirectory()) walk(path);
      else out[path.slice(dir.length + 1)] = readFileSync(path, "utf8");
    }
  };
  walk(dir);
  return out;
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
  assert.equal(c.rig.store.connectThreadStation(`cl@${A}`, first.channel, first.threadTs), A, `told as it was heard from again: ${JSON.stringify({ b: b.moves.handover.outs().map((o) => [o.step, o.to.slice(0, 1), o.routed, o.routes, o.shown, o.error]), a: a.moves.handover.outs().map((o) => [o.step, o.to.slice(0, 1), o.routed, o.routes.length]), c: c.moves.handover.outs().length, runsOn: b.connects.runsOn(`cl@${A}`) })}`);
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
  // back: stopped there, started here
  await a.moves.scheduler.back(WS, B, { module: "jobs", item: `${key}#dev` });
  assert.equal(b.jobs.length, 0);
  assert.deepEqual(a.jobs.map((j) => j.name), ["dev"]);
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
    // (a failure in the first pass of its files never held it: its agent's process goes on, so the turn is in it)
    assert.equal(a.rig.claude.count(), how === "unreached" || how === "full" || how === "hash" ? 1 : 2, `${how}: a turn here`);
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
    if (step === "held") say(a.rig.hub, thread, "p@x", "while it moves");
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
  // (started again: what the account was known by is kept, so the chat still names it)
  await a.moves.close();
  a.moves = a.make();
  await a.moves.start();
  const plan = await a.moves.scheduler.plan(WS, B);
  assert.equal(plan.items.find((x) => x.id === one.key)!.state, "stopped");
  assert.deepEqual(plan.items.find((x) => x.id === one.key)!.waitsFor, { module: "accounts", id: `own:solo@${A}` });
  assert.ok(plan.items.find((x) => x.id === one.key)!.needs.some((n) => n.id === `own:solo@${A}`), "named as it was known, not as this machine's own");
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

test("an account that cannot be borrowed and its chat, both moved: the chat comes back first, stopped here waiting for it, then the account, and it goes on here; what was said to it meanwhile is delivered once", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  a.rig.raw.profiles.push({ id: "solo", runtime: "claude", home: "homes/solo" });
  const [key, t] = newSession(a.rig.hub, { runtime: "claude", profile: "solo", createdBy: "p@x" });
  say(a.rig.hub, t.id, "p@x", "hi");
  await endTurn(a, key);
  const account = `own:solo@${A}`;
  const there = await a.moves.scheduler.move(WS, B, { module: "chats", item: key, withNeeds: true });
  await w.quiet();
  assert.equal(there.failed, null, JSON.stringify(there));
  assert.deepEqual(there.done.map((d) => d.module), ["accounts", "chats"]);
  // the chat first: it comes back stopped, waiting for its account
  const chat = await a.moves.scheduler.back(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(chat.failed, null, JSON.stringify(chat));
  assert.deepEqual(chat.stopped, [{ item: { module: "chats", id: key }, waitsFor: { module: "accounts", id: account } }]);
  assert.equal(a.rig.store.handedTo(key), null, "here again");
  assert.match(a.rig.hub.chatHeld(key) ?? "", /waits for accounts/);
  const turns = a.rig.claude.count();
  say(a.rig.hub, t.id, "p@x", "while it waits here");
  await w.quiet();
  assert.equal(a.rig.claude.count(), turns, "no turn while stopped");
  // then its account: it goes on here
  const back = await a.moves.scheduler.back(WS, B, { module: "accounts", item: account });
  await w.quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.deepEqual(back.resumed, [{ module: "chats", id: key }]);
  assert.equal(a.rig.hub.chatHeld(key), null);
  const prompts = a.rig.claude.sessions.flatMap((s) => s.prompts).join("\n");
  assert.equal(prompts.split("while it waits here").length - 1, 1, prompts);
  void b;
});

test("a chat of a connect that is not routed (one session for all): the connect first, its chat stopped here; the chat then, going on there; back: the chat stopped here, then the connect, and it goes on here", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  a.rig.raw.connects.push({ id: "team", mode: "single-session", requireMention: false, bind: { runtime: "claude" } });
  a.local.set("team", a.rig.teamChat);
  b.local.set(`team@${A}`, b.rig.teamChat);
  await a.connects.receive("team", { type: "message", message: message({ text: "hello team" }) });
  await a.rig.quiet();
  const key = a.rig.store.binding("team")!;
  await endTurn(a, key);
  const plan = await a.moves.scheduler.plan(WS, B);
  assert.ok(plan.items.find((x) => x.id === key)!.needs.some((n) => n.module === "connects" && n.id === `team@${A}`), "it needs its connect");
  assert.equal(plan.items.find((x) => x.id === key)!.cannot, undefined);
  const connect = await a.moves.scheduler.move(WS, B, { module: "connects", item: `team@${A}` });
  await w.quiet();
  assert.deepEqual(connect.stopped.map((x) => x.item.id), [key]);
  // what is said to it while it is on its way is kept there, no new session made for it, and delivered once it is there
  await b.connects.receive(`team@${A}`, { type: "message", message: message({ text: "while on its way" }) });
  await w.quiet();
  assert.deepEqual(b.rig.store.listSessions().map((x) => x.key), [], "no session of its own there");
  const moved = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(moved.failed, null, JSON.stringify(moved));
  assert.equal(b.rig.store.binding(`team@${A}`), key);
  {
    const prompts = b.rig.claude.sessions.flatMap((x) => [...x.prompts, ...x.steers]).join("\n");
    assert.equal(prompts.split("while on its way").length - 1, 1, prompts);
  }
  await b.connects.receive(`team@${A}`, { type: "message", message: message({ text: "there now?" }) });
  await w.quiet();
  // (said as the turn the kept message began goes on: a steer of it)
  assert.ok(b.rig.claude.sessions.flatMap((x) => [...x.prompts, ...x.steers]).join("\n").includes("there now?"));
  await endTurn(b, key);
  // back: the chat, stopped here; then the connect
  const chat = await a.moves.scheduler.back(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(chat.failed, null, JSON.stringify(chat));
  assert.deepEqual(chat.stopped.map((x) => x.waitsFor), [{ module: "connects", id: `team@${A}` }]);
  const back = await a.moves.scheduler.back(WS, B, { module: "connects", item: `team@${A}` });
  await w.quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.deepEqual(back.resumed.map((x) => x.id), [key]);
  await a.connects.receive("team", { type: "message", message: message({ text: "home?" }) });
  await w.quiet();
  const heard = a.rig.claude.sessions.flatMap((x) => [...x.prompts, ...x.steers]).join("\n");
  assert.ok(heard.includes("home?"), JSON.stringify({ held: a.rig.hub.chatHeld(key), binding: a.rig.store.binding("team"), row: a.rig.store.getSession(key), connects: a.rig.raw.connects.map((c: Json) => c.id), heard }));
});

test("a hand-back is a mirror by difference: what changed there is sent, what went there is removed here, nothing else sent", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const room = a.rig.session(key).workspace;
  writeFileSync(join(room, "stays.txt"), "the same both ways");
  writeFileSync(join(room, "goes.txt"), "deleted there");
  writeFileSync(join(room, "edited.txt"), "before");
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  const there = b.rig.session(key).workspace;
  writeFileSync(join(there, "edited.txt"), "after, edited there");
  utimesSync(join(there, "edited.txt"), 1_700_000_000, 1_700_000_000);
  rmSync(join(there, "goes.txt"));
  writeFileSync(join(there, "added.txt"), "added there");
  // (a file of the chat's here outside its room, which the lists there do not name: no prune touches it)
  const transcript = join(a.rig.dir, "transcripts", "claude", claudeProject(room)!, "claude-1.jsonl");
  mkdirSync(join(transcript, ".."), { recursive: true });
  writeFileSync(transcript, '{"type":"user"}\n');
  const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.deepEqual(filesOf(room), filesOf(there), "the room here is the one there");
  assert.ok(existsSync(transcript), "what is outside its room stays");
  const out = b.moves.handover.outs()[0]!;
  assert.equal(out.sentBytes, Buffer.byteLength("after, edited there") + Buffer.byteLength("added there"), "only what changed was sent");
});

test("entries with no ts on a hand-back are neither doubled nor lost", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  const t = a.rig.store.getThread(thread)!;
  const first = a.rig.store.entriesAfter(thread, 0).find((e) => e.kind === "message" && e.ts !== null)!;
  a.rig.store.editMessage(t.surface, t.channel, t.threadTs, first.ts!, "edited here");
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  const tb = b.rig.store.getThread(homeThread(b, key))!;
  b.rig.store.editMessage(tb.surface, tb.channel, tb.threadTs, first.ts!, "edited there");
  await a.moves.scheduler.back(WS, B, { module: "chats", item: key });
  await w.quiet();
  const edits = a.rig.store.entriesAfter(thread, 0).filter((e) => e.kind === "edit").map((e) => e.text);
  assert.deepEqual(edits, ["edited here", "edited there"]);
  assert.deepEqual(entries(a, thread), entries(b, tb.id));
});

test("a hand-back keeps by number what its log here already has: a letter written there under a ts the log has (another machine's clock) is put in, not taken for that one", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  const letter = (st: Station, t: number, text: string) => st.rig.store.insertLetter({ thread: t, ts: "1700000000.000100", authorKind: "agent", author: key, text, letter: { way: "out", title: "another chat", link: null } });
  const letters = (st: Station, t: number) => (st.rig.store.db.prepare("SELECT n, ts, text FROM letters WHERE thread = ? ORDER BY n").all(t) as { n: number; ts: string; text: string }[]).map((r) => `${r.n} ${r.ts} ${r.text}`);
  letter(a, thread, "written here");
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  const there = homeThread(b, key);
  letter(b, there, "written there");
  assert.equal((await a.moves.scheduler.back(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  assert.deepEqual(letters(a, thread), ["1 1700000000.000100 written here", "2 1700000000.000100 written there"]);
  assert.deepEqual(letters(a, thread), letters(b, there));
});

test("two still.fail chats of the same ts, one here and one there: handed over, each stays its own", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  const [other, ot] = newSession(b.rig.hub, { runtime: "claude", profile: "ccb", createdBy: "q@x" });
  say(b.rig.hub, ot.id, "q@x", "b's own chat");
  await endTurn(b, other);
  // (the same ts as A's chat: each station mints its own)
  b.rig.store.db.prepare("UPDATE threads SET thread_ts = ?, channel = ? WHERE id = ?").run(a.rig.store.getThread(thread)!.threadTs, a.rig.store.getThread(thread)!.channel, ot.id);
  const before = entries(b, ot.id);
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  const moved = homeThread(b, key);
  assert.notEqual(moved, ot.id, "a thread of its own");
  assert.deepEqual(entries(b, ot.id), before, "b's own chat untouched");
  assert.deepEqual(entries(b, moved), entries(a, thread));
});

test("a letter to a chat that moved, from a chat still here, reaches it there; reading it from here reads it there", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const mover = await stillfailChat(a);
  await a.moves.scheduler.move(WS, B, { module: "chats", item: mover.key });
  await w.quiet();
  const said = await a.rig.call(key, "session_send", { to: mover.key, text: "where are you now?" });
  await w.quiet();
  assert.match(said, /Sent to/);
  assert.ok(b.rig.claude.sessions.flatMap((s) => s.prompts).join("\n").includes("where are you now?"), "delivered there");
});

test("a linked worktree with commits no remote has: its repository moves first, then the chat only adds its worktree; back, the clone made there is removed", async () => {
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
  writeFileSync(join(ws, "proj", "a.txt"), "pushed\nnot pushed\nnot committed\n");
  const head = run(join(ws, "proj"), "rev-parse", "HEAD");
  const plan = await a.moves.scheduler.plan(WS, B);
  const repo = `repo:${bare}`;
  assert.ok(plan.items.find((x) => x.id === key)!.needs.some((n) => n.module === "repos" && n.id === repo), "the chat needs its repository");
  const refused = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  assert.match(refused.refused[0]?.why ?? "", /needs repos/);
  // (a repository moved is copied: still here, so moving it alone stops nothing; nor do the vault, agent home or settings)
  assert.deepEqual(plan.items.find((x) => x.id === repo)!.wouldStop, []);
  for (const m of a.moves.modules.filter((x) => ["repos", "vault", "agent-home", "settings"].includes(x.id))) assert.equal(m.usableHere?.({ module: m.id, id: "x", label: "x", needs: [] }), true, m.id);
  const alone = await a.moves.scheduler.move(WS, B, { module: "repos", item: repo });
  assert.deepEqual(alone.stopped, []);
  assert.equal(a.rig.hub.chatHeld(key), null, "the chat goes on here");
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key, withNeeds: true });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.deepEqual(out.done.map((d) => d.module), ["chats"]);
  const there = join(b.rig.session(key).workspace, "proj");
  assert.equal(run(there, "rev-parse", "HEAD"), head);
  assert.equal(run(there, "log", "-1", "--format=%s"), "not pushed anywhere");
  assert.equal(readFileSync(join(there, "a.txt"), "utf8"), "pushed\nnot pushed\nnot committed\n");
  assert.match(run(there, "status", "--porcelain"), /^M a\.txt$/m, "unstaged as it was");
  // back: the chat, then the clone made there removed. Its repository here lost its remote meanwhile, so this
  // station's gathering lists the worktree's `.git` (it is not one to be made again from a remote), which the lists
  // sent never name: it stays, and the worktree with it.
  run(clone, "remote", "remove", "origin");
  assert.equal((await a.moves.scheduler.back(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  assert.equal(run(join(ws, "proj"), "rev-parse", "HEAD"), head, "the worktree here still git's");
  run(clone, "remote", "add", "origin", bare);
  await a.moves.scheduler.back(WS, B, { module: "repos", item: repo });
  await w.quiet();
  assert.deepEqual(readdirSync(join(b.rig.dir, "repos")), []);
});

test("agent home, settings and secrets each moved, then back: both stations as they were", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  await stillfailChat(a);
  const homeA = join(a.rig.dir, "agent-homes", WS);
  const homeB = join(b.rig.dir, "agent-homes", WS);
  mkdirSync(join(homeA, "skills", "deploy"), { recursive: true });
  writeFileSync(join(homeA, "MEMORY.md"), "A remembers this");
  writeFileSync(join(homeA, "skills", "deploy", "SKILL.md"), "how A deploys");
  mkdirSync(join(homeB, "skills", "own"), { recursive: true });
  writeFileSync(join(homeB, "MEMORY.md"), "B's own memory");
  writeFileSync(join(homeB, "skills", "own", "SKILL.md"), "B's own skill");
  const beforeA = filesOf(homeA);
  const beforeB = filesOf(homeB);
  a.rig.raw.agentEnv = { FOO: "from A", BAR: "only A has it" };
  b.rig.raw.agentEnv = { FOO: "B's" };
  // (a setting B has of its own, another value: B keeps it, and it cannot move, saying so)
  a.rig.raw.maxNudges = 3;
  b.rig.raw.maxNudges = 5;
  const nudges = (await a.moves.scheduler.plan(WS, B)).items.find((x) => x.id === "setting:maxNudges")!;
  assert.match(nudges.cannot ?? "", /that station has its own maxNudges \(5\), which it keeps/);
  const pa = plainStore(a.rig.store.db);
  const pb = plainStore(b.rig.store.db);
  pa.put({ ws: WS, id: "tok", owner: "p@x", version: 1, kind: "token", name: "token", fields: { value: "s3cret" }, notes: "", at: 1 } as Json);
  pb.put({ ws: WS, id: "mine", owner: "p@x", version: 1, kind: "token", name: "b's", fields: { value: "b" }, notes: "", at: 1 } as Json);
  const plainB = pb.items(WS, "p@x").map((i) => i.id);
  // (B, taking a setting, holds its self-update while it does)
  const holding: number[] = [];
  b.onUpdate = () => void holding.push(b.holds);
  const out = await a.moves.scheduler.move(WS, B, { module: "agent-home", item: `home:${WS}` });
  await a.moves.scheduler.move(WS, B, { module: "settings", item: "setting:agentEnv" });
  await a.moves.scheduler.move(WS, B, { module: "vault", item: `vault:p@x@${WS}` });
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.equal(readFileSync(join(homeB, "skills", "deploy", "SKILL.md"), "utf8"), "how A deploys");
  assert.match(readFileSync(join(homeB, "MEMORY.md"), "utf8"), /B's own memory[\s\S]*A remembers this/);
  assert.deepEqual(b.rig.raw.agentEnv, { FOO: "B's", BAR: "only A has it" }, "what B lacked taken, its own kept");
  assert.equal(b.rig.raw.maxNudges, 5);
  assert.ok(holding.length > 0 && holding.every((n) => n > 0), `held while it took the setting: ${holding}`);
  b.onUpdate = undefined;
  assert.deepEqual(pb.items(WS, "p@x").map((i) => i.id).sort(), ["mine", "tok"]);
  // (both stations made again on the same data: each still says where it stands, and back is offered)
  await a.moves.close();
  a.moves = a.make();
  await b.moves.close();
  b.moves = b.make();
  await a.moves.start();
  await b.moves.start();
  const again = await a.moves.scheduler.plan(WS, B);
  for (const id of [`home:${WS}`, "setting:agentEnv", `vault:p@x@${WS}`]) assert.equal(again.items.find((x) => x.id === id)?.state, "there", id);
  for (const [module, item] of [["agent-home", `home:${WS}`], ["settings", "setting:agentEnv"], ["vault", `vault:p@x@${WS}`]] as const) {
    const back = await a.moves.scheduler.back(WS, B, { module, item });
    assert.equal(back.failed, null, `${module}: ${JSON.stringify(back)}`);
  }
  assert.deepEqual(filesOf(homeB), beforeB, "B's agent home as it was");
  assert.deepEqual(filesOf(homeA), beforeA, "A's untouched");
  assert.deepEqual(b.rig.raw.agentEnv, { FOO: "B's" });
  assert.deepEqual(pb.items(WS, "p@x").map((i) => i.id), plainB, "B lets go of what this move put there, and only that");
});

test("the rows put in tell what they are, marks and reads among them, as the copies' export reads them", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  a.rig.store.setRead("p@x", thread, 2);
  a.rig.store.setPin("p@x", key, true);
  const told = nothingTold();
  const off = b.rig.store.subscribe((c) => void tell(told, c));
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  off();
  const there = homeThread(b, key);
  assert.ok(told.marks.some((m) => m.table === "reads" && m.key.thread === there && m.key.viewer === "p@x"), JSON.stringify(told.marks));
  assert.ok(told.marks.some((m) => m.table === "pins" && m.key.session === key));
  assert.ok(told.sessions.includes(key));
  assert.ok(told.threads.includes(there));
});

test("what the app's page reads of a move: the modules in order with their needs, done of total, each item as it stands", async () => {
  const w = world();
  const a = w.get(A);
  const { key } = await stillfailChat(a);
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  const view = moveView(await a.moves.scheduler.plan(WS, B), a.moves.modules.map((m) => m.id), a.moves.scheduler.stopped(), { limit: 10 });
  assert.deepEqual(view.modules.map((m: Json) => m.id), ["accounts", "chats", "jobs", "connects", "repos", "vault", "agent-home", "settings"]);
  const chats = view.modules.find((m: Json) => m.id === "chats");
  assert.deepEqual(chats.needs, ["accounts", "connects", "repos", "vault"]);
  assert.equal(chats.done, 1);
  assert.deepEqual(chats.items.find((x: Json) => x.id === key), { id: key, label: a.rig.session(key).title ?? key, state: "there", needs: ["accounts share:sh-cc"] });
  assert.equal(view.moving, null);
});

test("a chat's row says the station it came from: none where it began, the one before where it went on, none again back where it began", async () => {
  const w = world([A, B, C]);
  const a = w.get(A);
  const b = w.get(B);
  const c = w.get(C);
  const { key } = await stillfailChat(a);
  assert.equal(a.rig.session(key).from, undefined, "it began here");
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(b.rig.session(key).from, A);
  const on = await b.moves.scheduler.move(WS, C, { module: "chats", item: key });
  await w.quiet();
  assert.equal(on.failed, null, JSON.stringify(on));
  assert.equal(c.rig.session(key).from, B, "the station before");
  assert.equal(b.rig.store.handedTo(key)?.station, C, "and B says where it went");
  const home = await c.moves.scheduler.move(WS, A, { module: "chats", item: key });
  await w.quiet();
  assert.equal(home.failed, null, JSON.stringify(home));
  assert.equal(a.rig.session(key).from, undefined, "back where it began: none");
  assert.equal(a.rig.store.handedTo(key), null);
});

test("reading a chat that moved, from a chat still here, reads it there: chat_read and session_history", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const mover = await stillfailChat(a);
  await a.moves.scheduler.move(WS, B, { module: "chats", item: mover.key });
  await w.quiet();
  const there = homeThread(b, mover.key);
  say(b.rig.hub, there, "p@x", "said only there");
  await w.quiet();
  const read = await a.rig.call(key, "chat_read", { chat: mover.key });
  assert.match(read, /Read from station/);
  assert.ok(read.includes("said only there"), read);
  const history = await a.rig.call(key, "session_history", { chat: mover.key }).catch((e: Error) => e.message);
  assert.match(history, new RegExp(`station ${B}|Read from station`), history);
});

test("the copies' export on the station a chat went to carries it in its next pass: its rows, marks and reads", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  a.rig.store.setRead("p@x", thread, 2);
  a.rig.store.setPin("q@x", key, true);
  a.rig.store.setChatHidden("r@x", thread, true);
  const e = new Exporter({ db: join(b.rig.dir, "stillfail.db"), replica: join(b.rig.dir, "replica-copy"), dataDir: b.rig.dir, origin: B, now: () => 1_000 });
  e.setPlaces({ home: WS, workspaces: [{ workspace: WS, name: "B" }] });
  let p = e.pass(nothingTold());
  while (p.more) p = e.pass(nothingTold());
  const told = nothingTold();
  const off = b.rig.store.subscribe((c) => void tell(told, c));
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  off();
  p = e.pass(told);
  while (p.more) p = e.pass(nothingTold());
  const head = p.heads[WS] ?? e.heads()[WS]!;
  const { folded } = readCopy(genDir(ownDir(join(b.rig.dir, "replica-copy")), WS, head.gen));
  e.close();
  const there = homeThread(b, key);
  assert.ok(folded.table("sessions").some((r) => r.key === key), "its session");
  assert.equal(folded.table("entries").filter((r) => r.thread === there).length, b.rig.store.entriesAfter(there, 0).length, "its log");
  assert.ok(folded.table("reads").some((r) => r.viewer === "p@x" && r.thread === there), "a read");
  assert.ok(folded.table("pins").some((r) => r.viewer === "q@x" && r.session === key), "a pin");
  assert.ok(folded.table("hidden_chats").some((r) => r.viewer === "r@x" && r.thread === there), "a hidden mark");
});

test("a repository the other station had already stays there as its move is taken back", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const ws = a.rig.session(key).workspace;
  const env = gitEnv(a.rig.dir);
  const run = (dir: string, ...args: string[]) => execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", env, stdio: ["ignore", "pipe", "pipe"] }).trim();
  const bare = join(a.rig.dir, "remote.git");
  execFileSync("git", ["init", "-q", "--bare", "-b", "main", bare], { env });
  mkdirSync(join(a.rig.dir, "repos"), { recursive: true });
  execFileSync("git", ["clone", "-q", bare, join(a.rig.dir, "repos", "proj")], { env, stdio: "ignore" });
  const clone = join(a.rig.dir, "repos", "proj");
  writeFileSync(join(clone, "a.txt"), "x\n");
  run(clone, "add", "-A");
  run(clone, "commit", "-q", "-m", "x");
  run(clone, "push", "-q", "origin", "HEAD:main");
  run(clone, "worktree", "add", "-q", "-b", "f", join(ws, "proj"));
  // B has a clone of it already, of its own
  mkdirSync(join(b.rig.dir, "repos"), { recursive: true });
  execFileSync("git", ["clone", "-q", bare, join(b.rig.dir, "repos", "mine")], { env, stdio: "ignore" });
  const repo = `repo:${bare}`;
  await a.moves.scheduler.move(WS, B, { module: "repos", item: repo });
  await a.moves.scheduler.back(WS, B, { module: "repos", item: repo });
  assert.deepEqual(readdirSync(join(b.rig.dir, "repos")), ["mine"], "the one it had stays");
});

test("a chat in a turn, asked to move with wait false, is refused and goes on here", async () => {
  const w = world();
  const a = w.get(A);
  const [key, t] = newSession(a.rig.hub, { runtime: "claude", profile: "cc", createdBy: "p@x" });
  say(a.rig.hub, t.id, "p@x", "busy now");
  await a.rig.quiet();
  assert.equal(a.rig.hub.busy(key), true);
  a.moves.wait = false;
  const out = await given(a.moves.scheduler.move(WS, B, { module: "chats", item: key }), "refused at once, its turn not waited for");
  assert.match(out.failed?.error ?? "", /in a turn now/);
  assert.equal(a.rig.hub.chatHeld(key), null, "not held");
  assert.equal(a.rig.store.handedTo(key), null);
});

test("a chat sent ahead of its account (arriveStopped) arrives stopped there, and goes on there as the account comes", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  a.rig.raw.profiles.push({ id: "solo", runtime: "claude", home: "homes/solo" });
  const [key, t] = newSession(a.rig.hub, { runtime: "claude", profile: "solo", createdBy: "p@x" });
  say(a.rig.hub, t.id, "p@x", "hi");
  await endTurn(a, key);
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key, arriveStopped: true });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.match(b.rig.hub.chatHeld(key) ?? "", /waits for accounts own:solo@/);
  say(b.rig.hub, homeThread(b, key), "p@x", "waiting there");
  await w.quiet();
  assert.equal(b.rig.claude.count(), 0, "no turn there yet");
  await a.moves.scheduler.move(WS, B, { module: "accounts", item: `own:solo@${A}` });
  await w.quiet();
  assert.equal(b.rig.hub.chatHeld(key), null, "it goes on as its account came");
  const prompts = b.rig.claude.sessions.flatMap((x) => x.prompts).join("\n");
  assert.equal(prompts.split("waiting there").length - 1, 1, prompts);
});

test("a station's notice that comes back through another bot's connect wakes nothing and brings no chat back; that bot's ordinary message is taken", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  // B runs a bot of its own (gpt) in the same channel; A's cl bot is told to B as A's connect hears its first event
  b.rig.raw.connects = [{ id: "gpt", bind: { runtime: "codex" } }];
  b.rig.raw.profiles.push({ id: "cxb2", runtime: "codex", home: "homes/cxb2" });
  const first = message({ text: "<@UGPT> hello", user: "U1" });
  await b.connects.receive("gpt", { type: "message", message: first });
  const key = sessionKey("gpt", first.channel, first.threadTs);
  await endTurn(b, key, "codex");
  b.rig.store.setArchived(key, true, "auto");
  await a.connects.receive("cl", { type: "message", message: message({ text: "<@UBOT> elsewhere" }) });
  await w.quiet();
  assert.ok(b.rig.hub.toldBots.get(A)?.has("UBOT"), "told, not asked");
  const prompts = () => b.rig.codex.sessions.flatMap((s) => s.prompts).join("\n");
  // A's notice, as Slack hands it to B's bot: no person's message
  await b.connects.receive("gpt", { type: "message", message: reply(first, "1900.1", `⚠️ the chat stopped${NOTICE_MARK}`, { user: "UBOT" }) });
  await w.quiet();
  assert.ok(!prompts().includes("the chat stopped"), "woke nothing");
  assert.equal(b.rig.session(key).archivedBy, "auto", "still archived");
  // A's agent's own answer through its bot is a message as any other bot's
  await b.connects.receive("gpt", { type: "message", message: reply(first, "1900.2", "<@UGPT> what do you think?", { user: "UBOT", addressed: true }) });
  await w.quiet();
  assert.ok(prompts().includes("what do you think?"), "taken");
});

test("a message a device sent here under its key, asked again there after the chat moved, is in the log there once", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  const viewer = { sub: "p", email: "p@x", name: "P", role: "member", workspace: WS, device: "d" };
  const send = (st: Station, id: number, text: string, once: string) =>
    st.admin.handle({ method: "POST", path: `/threads/${id}/messages`, query: [], headers: { "idempotency-key": once }, body: Buffer.from(JSON.stringify({ text })), viewer, lang: "en" });
  // Sent here, its answer lost on the way: the device asks again, by then of the station the chat went to.
  const first = await send(a, thread, "only once", "k1");
  assert.equal(first.status, 200);
  await endTurn(a, key);
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  const there = homeThread(b, key);
  const again = await send(b, there, "only once", "k1");
  assert.equal(again.status, 200);
  assert.deepEqual(JSON.parse(String(again.body)), JSON.parse(String(first.body)), "answered as it was here");
  assert.equal(entries(b, there).filter((e) => e === "person:only once").length, 1, entries(b, there).join("\n"));
  assert.equal(b.rig.claude.count(), 0, "nothing started there by it");
  // Another key there is another message.
  assert.equal((await send(b, there, "a new one", "k2")).status, 200);
  await w.quiet();
  assert.equal(entries(b, there).filter((e) => e === "person:a new one").length, 1);
});

test("a person moves a chat with POST /move and back with POST /move/back: a member is refused, a second while one runs is 409, GET /move shows it there with the last outcome", async () => {
  const w = world();
  const a = w.get(A);
  const { key } = await stillfailChat(a);
  const member = await a.ask("POST", "/move", { to: B, module: "chats", item: key }, "member");
  assert.equal(member.status, 403);
  assert.match(member.body.error, /owner or admin/);
  const first = await a.ask("POST", "/move", { to: B, module: "chats", item: key });
  assert.deepEqual(first, { status: 202, body: { started: true } });
  const second = await a.ask("POST", "/move", { to: B, module: "chats", item: key });
  assert.equal(second.status, 409);
  assert.match(second.body.error, /Another move is under way/);
  await a.moves.scheduler.settle();
  await w.quiet();
  assert.equal(a.rig.store.handedTo(key)?.station, B);
  const view = await a.ask("GET", "/move", null, "member", [["to", B]]);
  assert.equal(view.status, 200);
  assert.equal(view.body.modules.find((m: Json) => m.id === "chats").items.find((x: Json) => x.id === key).state, "there");
  assert.deepEqual({ ...view.body.last, at: 0 }, { at: 0, by: "owner@x", how: "move", station: B, done: [`chats ${key}`], refused: [], stopped: [], resumed: [], failed: null });
  const back = await a.ask("POST", "/move/back", { from: B, module: "chats", item: key });
  assert.equal(back.status, 202);
  await a.moves.scheduler.settle();
  await w.quiet();
  assert.equal(a.rig.store.handedTo(key), null);
  assert.equal(a.rig.hub.handedOver(key), false);
  const after = await a.ask("GET", "/move", null, "owner", [["to", B]]);
  assert.equal(after.body.last.how, "back");
  assert.deepEqual(after.body.last.done, [`chats ${key}`]);
});

test("moving switched off here refuses POST /move, POST /move/back and station_move, holding nothing; on here and off there refuses before the chat is held", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const asks = new MoveAsks({ data: a.rig.dir, scheduler: a.moves.scheduler, here: () => A, wsOf: () => WS, roster: () => [{ id: A, name: "A" }, { id: B, name: "B" }], cards: { post: async () => null }, notify: () => {}, refusal: (ws, s) => a.moves.refusal(ws, s) });
  const held: string[] = [];
  const hold = a.rig.hub.holdChat.bind(a.rig.hub);
  a.rig.hub.holdChat = ((k: string, why: string) => (held.push(k), hold(k, why))) as typeof a.rig.hub.holdChat;
  a.on = false;
  const off = /not open on this station yet|这台 station 还没开放/;
  const moved = await a.ask("POST", "/move", { to: B, module: "chats", item: key });
  assert.equal(moved.status, 409);
  assert.match(moved.body.error, off);
  const backed = await a.ask("POST", "/move/back", { from: B, module: "chats", item: key });
  assert.equal(backed.status, 409);
  assert.match(backed.body.error, off);
  await assert.rejects(asks.toolIn(WS, key, { action: "move", to: "B", module: "chats", item: key }), off);
  await assert.rejects(asks.toolIn(WS, key, { action: "back", to: "B", module: "chats", item: key }), off);
  await assert.rejects(asks.toolIn(WS, key, { action: "move", to: "B", all: true }), off);
  // (and the scheduler itself, as a card's confirmation reaches it)
  await assert.rejects(a.moves.scheduler.move(WS, B, { module: "chats", item: key }), off);
  // Read-only, the plan still answers.
  assert.equal((await a.ask("GET", "/move", null, "owner", [["to", B]])).status, 200);
  // On here, off there: refused naming that station, before anything is held or sent.
  a.on = true;
  b.on = false;
  const there = await a.ask("POST", "/move", { to: B, module: "chats", item: key });
  assert.equal(there.status, 409);
  assert.match(there.body.error, /not open on station “B” yet/);
  const offThere = /not open on station “B” yet|station「B」还没开放/;
  await assert.rejects(a.moves.scheduler.move(WS, B, { module: "chats", item: key }), offThere);
  // (a station that asks it directly is refused by it too)
  await assert.rejects(a.bus.ask(B, { method: "handover.begin", keys: [key], ws: WS, id: "x" }), offThere);
  await w.quiet();
  assert.deepEqual(held, [], "never held");
  assert.equal(a.rig.hub.chatHeld(key), null);
  assert.equal(a.rig.store.handedTo(key), null);
  assert.equal(b.rig.store.getSession(key), null, "nothing of it there");
  assert.match(a.moves.scheduler.last(WS)!.failed!.error, offThere);
});

/// The files of a room, by name, with their words.
const roomOf = (dir: string) => Object.fromEntries(readdirSync(dir).filter((n) => statSync(join(dir, n)).isFile()).sort().map((n) => [n, readFileSync(join(dir, n), "utf8")]));

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

test("a failure in the first pass of its files: the chat was never held, works here, and nothing of it is there", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  a.fails.add("files");
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.match(out.failed?.error ?? "", /the test failed files/);
  assert.equal(a.rig.hub.chatHeld(key), null);
  assert.equal(b.rig.store.getSession(key), null);
  say(a.rig.hub, thread, "p@x", "still here?");
  await w.quiet();
  // (never held, its agent's process went on: the turn is in it)
  assert.equal(a.rig.claude.count(), 1);
  assert.ok(a.rig.claude.last().prompts.join("\n").includes("still here?"), "it works here");
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

/// An edit of message `target` with no ts, as the store writes one (store.ts #editMessage).
function edit(st: Station, thread: number, target: number, text: string) {
  const n = ((st.rig.store.db.prepare("SELECT MAX(n) AS n FROM entries WHERE thread = ?").get(thread) as { n: number }).n ?? 0) + 1;
  st.rig.store.db.prepare("INSERT INTO entries (thread, n, kind, target, ts, author_kind, author, text, at) VALUES (?, ?, 'edit', ?, NULL, 'person', 'p@x', ?, ?)").run(thread, n, target, text, 1_000 + n);
}
const edits = (st: Station, thread: number) => (st.rig.store.db.prepare("SELECT text FROM entries WHERE thread = ? AND kind = 'edit' ORDER BY n").all(thread) as { text: string }[]).map((r) => r.text);

test("a chat handed forth, back and forth again, its log with entries of no ts (edits), something said on each side between: every entry once on both", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  const n = (st: Station, t: number, text: string) => (st.rig.store.db.prepare("SELECT n FROM entries WHERE thread = ? AND text = ? AND kind = 'message'").get(t, text) as { n: number }).n;
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  const there = homeThread(b, key);
  assert.equal((await a.moves.scheduler.back(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  // (its copy there left with something of its own since: the logs are not one any more, so they are matched by ts)
  b.rig.store.db.prepare("INSERT INTO entries (thread, n, kind, ts, author_kind, author, text, at) VALUES (?, ?, 'message', '9999.000001', 'person', 'p@x', 'late there', 1)")
    .run(there, ((b.rig.store.db.prepare("SELECT MAX(n) AS n FROM entries WHERE thread = ?").get(there) as { n: number }).n ?? 0) + 1);
  say(a.rig.hub, thread, "p@x", "said here");
  await w.quiet();
  await endTurn(a, key);
  edit(a, thread, n(a, thread, "said here"), "edited here");
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  say(b.rig.hub, there, "p@x", "said there");
  await w.quiet();
  await endTurn(b, key);
  edit(b, there, n(b, there, "said there"), "edited there");
  assert.equal((await a.moves.scheduler.back(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  for (const [st, t] of [[a, thread], [b, there]] as const) {
    assert.deepEqual(edits(st, t), ["edited here", "edited there"], `edits on ${st.id.slice(0, 1)}`);
    const said = entries(st, t);
    for (const x of ["person:look at the build", "person:said here", "person:said there", "person:late there"]) assert.equal(said.filter((e) => e === x).length, 1, `${x} on ${st.id.slice(0, 1)}: ${said.join(" | ")}`);
  }
});

/// B holding a retired copy of A's chat as the switched-off retirement left it (ws `retired:<ws>`, its threads put in
/// with B's own ids, its files in place, their times kept): what A's rows and room were then.
function retiredCopy(a: Station, b: Station, key: string) {
  const ctx = newCtx({ from: A, here: B, fromData: a.rig.dir, toData: b.rig.dir, connects: {}, profiles: { cc: "ccb" }, ws: `retired:${WS}` });
  b.rig.store.importRows(ctx, "sessions", a.rig.store.chatPage("sessions", key, null, 500, [key]));
  for (const t of a.rig.store.chatThreads([key], 0, 200)) {
    for (const table of ["threads", "thread_sessions", "entries", "letters"] as const) b.rig.store.importRows(ctx, table, a.rig.store.chatPage(table, t, null, 500, [key]));
  }
  const from = a.rig.session(key).workspace;
  const to = b.rig.session(key).workspace;
  mkdirSync(to, { recursive: true });
  for (const n of readdirSync(from)) {
    if (!statSync(join(from, n)).isFile()) continue;
    writeFileSync(join(to, n), readFileSync(join(from, n)));
    const st = statSync(join(from, n));
    utimesSync(join(to, n), st.atime, st.mtime);
  }
}

test("a station holding a retired copy of the chat (older log, same thread keys, its files in place): handed over, shown once with the whole log, no entry twice, its files A's; a failed hand-over leaves the copy as it was", async () => {
  for (const failing of [true, false]) {
    const w = world();
    const a = w.get(A);
    const b = w.get(B);
    const { key, thread } = await stillfailChat(a);
    const room = a.rig.session(key).workspace;
    writeFileSync(join(room, "kept.md"), "the same on both");
    writeFileSync(join(room, "gone.md"), "removed here since");
    retiredCopy(a, b, key);
    const copy = b.rig.store.getSession(key)!;
    assert.equal(copy.ws, `retired:${WS}`);
    const there = homeThread(b, key);
    const copied = entries(b, there);
    // Since: more said here, a file changed, one removed.
    say(a.rig.hub, thread, "p@x", "after the retirement");
    await w.quiet();
    await endTurn(a, key);
    writeFileSync(join(room, "notes.md"), "what I am doing now");
    rmSync(join(room, "gone.md"));
    const roomThere = b.rig.session(key).workspace;
    const filesBefore = roomOf(roomThere);
    if (failing) a.fails.add("counts");
    const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
    await w.quiet();
    if (failing) {
      assert.match(out.failed?.error ?? "", /the test failed counts/);
      assert.equal(b.rig.store.getSession(key)!.ws, `retired:${WS}`, "the copy as it was");
      assert.deepEqual(entries(b, there), copied);
      assert.deepEqual(roomOf(roomThere), filesBefore, "its files as they were");
      assert.equal(a.rig.store.handedTo(key), null);
      continue;
    }
    assert.equal(out.failed, null, JSON.stringify(out));
    assert.equal(homeThread(b, key), there, "the same thread");
    assert.equal(b.rig.session(key).ws, null, "shown");
    assert.deepEqual(entries(b, there), entries(a, thread), "the whole log, once");
    assert.deepEqual(roomOf(b.rig.session(key).workspace), roomOf(room), "its files A's");
    const o = a.moves.handover.outOf(key)!;
    assert.equal(o.sentBytes, "what I am doing now".length, "what was in place not sent again");
  }
});

test("a chat stopped for its account whose hand-over fails in the first pass of its files stays stopped: nothing lets it go that it did not hold", async () => {
  const w = world();
  const a = w.get(A);
  a.rig.raw.profiles.push({ id: "solo", runtime: "claude", home: "homes/solo" });
  const [key, t] = newSession(a.rig.hub, { runtime: "claude", profile: "solo", createdBy: "p@x" });
  say(a.rig.hub, t.id, "p@x", "hi");
  await endTurn(a, key);
  const out = await a.moves.scheduler.move(WS, B, { module: "accounts", item: `own:solo@${A}` });
  assert.deepEqual(out.stopped.map((s) => s.item.id), [key]);
  assert.notEqual(a.rig.hub.chatHeld(key), null);
  a.fails.add("files");
  const moved = await a.moves.scheduler.move(WS, B, { module: "chats", item: key, arriveStopped: true });
  await w.quiet();
  assert.match(moved.failed?.error ?? "", /the test failed files/);
  assert.notEqual(a.rig.hub.chatHeld(key), null, "still stopped, waiting for its account");
  const turns = a.rig.claude.count();
  say(a.rig.hub, t.id, "p@x", "while it waits");
  await w.quiet();
  assert.equal(a.rig.claude.count(), turns, "no turn here");
  assert.deepEqual(a.moves.scheduler.stopped().map((x) => x.item.id), [key], "still waiting for its account");
});

test("a whole module moved goes through every chat, a page at a time: 12 chats with pages of 5 all go, the total 12 throughout", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  a.page = 5;
  await a.moves.close();
  a.moves = a.make();
  const keys: string[] = [];
  for (let i = 0; i < 12; i++) {
    const [key] = newSession(a.rig.hub, { runtime: "claude", profile: "cc", createdBy: "p@x" });
    keys.push(key);
  }
  const chats = (p: Awaited<ReturnType<Moves["scheduler"]["plan"]>>) => p.items.filter((x) => x.module === "chats");
  assert.equal(chats(await a.moves.scheduler.plan(WS, B)).length, 12);
  const totals: number[] = [];
  a.onFail = (step) => void (step === "held" && a.moves.scheduler.plan(WS, B).then((p) => void totals.push(chats(p).length)));
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", all: true });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.deepEqual(out.done.filter((d) => d.module === "chats").map((d) => d.id).sort(), [...keys].sort());
  assert.ok(totals.length === 12 && totals.every((n) => n === 12), `the total said as each went: ${totals}`);
  assert.equal(chats(await a.moves.scheduler.plan(WS, B)).filter((x) => x.state === "there").length, 12);
  for (const k of keys) assert.notEqual(b.rig.store.getSession(k), null);
});

test("a move holds each station's self-update while it goes, on both ends, and lets go after, also after a failure", async () => {
  for (const failing of [false, true]) {
    const w = world();
    const a = w.get(A);
    const b = w.get(B);
    const { key } = await stillfailChat(a);
    const during: [number, number][] = [];
    a.onFail = (step) => void ((step === "held" || step === "rows") && during.push([a.holds, b.holds]));
    if (failing) a.fails.add("counts");
    const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
    await w.quiet();
    assert.equal(out.failed === null, !failing, JSON.stringify(out));
    assert.ok(during.length > 0 && during.every(([x, y]) => x > 0 && y > 0), `held on both ends while it went: ${JSON.stringify(during)}`);
    assert.deepEqual([a.holds, b.holds], [0, 0], failing ? "let go after the failure" : "let go after");
  }
});

test("the station stopped in the middle of a turn: started again, what waited for an item that never left goes on, and the turn's outcome says the station restarted", async () => {
  const w = world();
  const a = w.get(A);
  a.rig.raw.profiles.push({ id: "solo", runtime: "claude", home: "homes/solo" });
  const [key, t] = newSession(a.rig.hub, { runtime: "claude", profile: "solo", createdBy: "p@x" });
  say(a.rig.hub, t.id, "p@x", "hi");
  await endTurn(a, key);
  a.profileHangs = true;
  void a.moves.scheduler.move(WS, B, { module: "accounts", item: `own:solo@${A}` });
  await w.quiet();
  assert.deepEqual(a.moves.scheduler.stopped().map((x) => x.item.id), [key], "stopped as its account began to move");
  // (the process stops here: its account never left)
  await a.moves.close();
  a.profileHangs = false;
  a.rig.hub.releaseChat(key);
  a.moves = a.make();
  await a.moves.start();
  await w.quiet();
  assert.deepEqual(a.moves.scheduler.stopped(), [], "its account is here: it goes on");
  assert.equal(a.rig.hub.chatHeld(key), null);
  const last = a.moves.scheduler.last(WS)!;
  assert.equal(last.how, "move");
  assert.match(last.failed?.error ?? "", /restarted during the move|迁移进行中这台 station 重启了/);
  say(a.rig.hub, t.id, "p@x", "still here");
  await w.quiet();
  assert.ok(a.rig.claude.last().prompts.join("\n").includes("still here"), "it works here");
});

test("the tell that an item came is lost: the station it came from heard again, what waited there for it goes on", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  a.rig.raw.profiles.push({ id: "solo", runtime: "claude", home: "homes/solo" });
  const [key, t] = newSession(a.rig.hub, { runtime: "claude", profile: "solo", createdBy: "p@x" });
  say(a.rig.hub, t.id, "p@x", "hi");
  await endTurn(a, key);
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key, arriveStopped: true });
  await w.quiet();
  assert.match(b.rig.hub.chatHeld(key) ?? "", /waits for accounts own:solo@/);
  w.tamper((to, r) => {
    if (r.method === "move.arrived") throw new Error("lost on the way");
    return r;
  });
  await a.moves.scheduler.move(WS, B, { module: "accounts", item: `own:solo@${A}` });
  await w.quiet();
  assert.notEqual(b.rig.hub.chatHeld(key), null, "the tell lost: still waiting");
  w.tamper(null);
  // (the connection opened again: B hears from A)
  await a.bus.ask(B, { method: "move.open", workspace: WS });
  await w.quiet();
  assert.equal(b.rig.hub.chatHeld(key), null, "it goes on there");
  assert.deepEqual(b.moves.scheduler.stopped(), []);
});

/// Three chats of A's, by key.
async function threeChats(a: Station): Promise<string[]> {
  const keys: string[] = [];
  for (let i = 0; i < 3; i++) keys.push((await stillfailChat(a)).key);
  return keys.sort();
}

test("a move stopped as a chat's files go a first time: that chat goes on here, those before it are there, those after it here; who stopped it is said", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const keys = await threeChats(a);
  const seen: Json[] = [];
  a.onFail = (step) => {
    const o = a.moves.handover.outOf(keys[1]!);
    if (step !== "files" || o === null || o.held !== false) return;
    a.onFail = null;
    void a.ask("POST", "/move/stop", {}).then((r) => seen.push(r));
  };
  const started = await a.ask("POST", "/move", { to: B, module: "chats", all: true });
  assert.equal(started.status, 202);
  await a.moves.scheduler.settle();
  await w.quiet();
  assert.deepEqual(seen, [{ status: 200, body: { ok: true } }]);
  const [first, second, third] = keys as [string, string, string];
  assert.equal(a.rig.store.handedTo(first)?.station, B, "the one before it went");
  assert.equal(a.rig.store.handedTo(second), null, "the one under way goes on here");
  assert.equal(a.rig.hub.chatHeld(second), null);
  assert.equal(b.rig.store.getSession(second), null, "nothing of it there");
  assert.equal(a.rig.store.handedTo(third), null, "the one after it stays here");
  const view = await a.ask("GET", "/move", null, "owner", [["to", B]]);
  assert.equal(view.body.last.stoppedBy, "owner@x");
  assert.deepEqual(view.body.last.done, [`chats ${first}`]);
  assert.equal(view.body.moving, null);
  assert.equal((await a.ask("POST", "/move/stop", {})).status, 409, "none under way now");
});

test("a move stopped once a chat went: that chat completes there, nothing after it moves", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const keys = await threeChats(a);
  let stopping: boolean | null = null;
  a.onFail = (step) => {
    if (step !== "gone") return;
    a.onFail = null;
    a.moves.scheduler.stopTurn("owner@x");
    stopping = a.moves.scheduler.stopping();
  };
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", all: true });
  await w.quiet();
  assert.equal(stopping, true);
  const [first, second, third] = keys as [string, string, string];
  assert.deepEqual(out.done.map((d) => d.id), [first]);
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.equal(b.rig.session(first).ws, null, "it completed there");
  assert.equal(a.rig.store.handedTo(second), null);
  assert.equal(a.rig.store.handedTo(third), null);
  assert.equal(a.moves.scheduler.last(WS)!.stoppedBy, "owner@x");
  assert.equal(a.moves.scheduler.stopping(), false, "said no more once the turn ended");
});
