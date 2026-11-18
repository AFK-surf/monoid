// The accounts module of a migration (move/accounts.ts) over the real sharing of logins (share/index.ts) on two
// stations, through the real scheduler and the chats' hand-over (move/station.ts): an own login that can be shared is
// shared as it moves, with the two stations alone, so the station it leaves borrows it under the same profile id and
// the chats still there go on, none stopped; moved back, the share it made is undone (not where a person opened it to a
// third station meanwhile), across a start too; one shared before stays shared; one that cannot be shared moves as it
// is and stops what needs it; a failure after the share was made undoes it, the login here as it was. Stations are
// Rigs (hub-fakes.ts) with their moves and their sharing, over a transport of the test's.
import { counting, type Cost } from "./move-bounded.ts";
import assert from "node:assert/strict";
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { after, afterEach, test } from "node:test";
import { stationLang, tr } from "../src/ops/i18n.ts";
import { Cloud } from "../src/cloud/state.ts";
import { PeerBus, bytesOf, withBytes } from "../src/mesh/bus.ts";
import type { ConfigFile } from "../src/ops/config.ts";
import { Fibers } from "../src/ops/fibers.ts";
import { sizesSoon } from "../src/replica/carry.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { newSession, say } from "../src/sessions/lifecycle.ts";
import { Moves } from "../src/move/station.ts";
import { moveView } from "../src/move/routes.ts";
import { ARRIVE_WAIT_MS } from "../src/move/chats.ts";
import { shareRefusal, Sharing } from "../src/share/index.ts";
import { Rig, message, settle, testClock } from "./hub-fakes.ts";
import { PeerGone } from "../src/mesh/peer.ts";
import { sessionKey } from "../src/sessions/hub.ts";

type Json = any;
const WS = "ws";
const A = "a".repeat(64);
const B = "b".repeat(64);
const C = "c".repeat(64);
/// A Claude Code login of A's own, not shared.
const MAX = { id: "max", name: "Claude Max", runtime: "claude", access: { kind: "subscription" }, home: "homes/max", env: {} };
/// A Kimi Code sign-in: cannot be shared (share/index.ts `shareRefusal`).
const KIMI = { id: "kimi", name: "Kimi", runtime: "claude", access: { kind: "api-provider", provider: "kimi-code", login: true }, home: "homes/kimi", env: {} };

function across(v: Json): Json {
  const bytes = bytesOf(v);
  const copy = JSON.parse(JSON.stringify(v));
  return bytes === null ? copy : withBytes(copy, bytes);
}

type Station = {
  id: string; rig: Rig; bus: PeerBus; moves: Moves; sharing: Sharing; fibers: Fibers;
  /// share.take asked of another station fails (its answer lost on the way).
  failTake: boolean;
  /// share.borrow asked of another station fails (its answer lost on the way).
  failBorrow?: boolean;
  /// What this station says of its shares to others (`share.changed`) does not reach them.
  failChanged: boolean;
  /// What this station asked of others, in order, where kept (`share.borrow` as it is answered, the rest as sent).
  asks?: string[];
  /// Killed (its requests found gone), and the request it is killed as it receives.
  dead?: boolean;
  killAt?: string;
  /// Told as this station tells devices its moves changed (move/station.ts `changed`).
  onMove?: () => void;
  /// The next `move.accounts` this station asks goes unanswered (the other not reached).
  failAccounts: boolean;
  make(): Moves;
};

const open: (() => Promise<void>)[] = [];
const closeAll = async () => {
  for (const c of open.splice(0).reverse()) await c().catch(() => {});
};
// (however a test ends, a throw, a rejection nobody awaited: what it opened is closed, its file does not hang)
afterEach(closeAll);
after(closeAll);

/// A second Claude Code login of A's, of the same runtime: where a chat would be switched to.
const SPARE = { id: "spare", name: "Spare", runtime: "claude", access: { kind: "subscription" }, home: "homes/spare", env: {} };

/// Stations A and B of workspace "ws" (and C, listed but never up, where asked); A has `profiles`, its login's files;
/// `slack`: A has the Slack connect cl (its fake chat `rig.chat`).
function world(profiles: Json[], o: { third?: boolean; slack?: boolean; cUp?: boolean } = {}) {
  const t = testClock();
  const stations = new Map<string, Station>();
  /// The undoing of shares as their logins came home (`onHosted`), awaited by `quiet`.
  const homing = new Set<Promise<void>>();
  const roster = [A, B, ...(o.third ? [C] : [])].map((id) => ({ id, name: id.slice(0, 1).toUpperCase() }));
  const cloudFor = (station: string) => Object.defineProperties(Object.create(Cloud.prototype), Object.getOwnPropertyDescriptors({
    peersCurrent: true,
    lock: null,
    get state() {
      return { station, workspace: WS, workspace_name: WS, peers: roster, revocations: [], joined: [] } as Json;
    },
    listen: () => () => {},
  })) as Cloud;
  const make = (id: string): Station => {
    const rig = new Rig({ place: { workspace: WS, station: id }, workspaces: [WS], fileStore: true, clock: t.clock });
    const st = { id, rig, failTake: false, failChanged: false, failAccounts: false } as unknown as Station;
    rig.raw.connects = o.slack && id === A ? [{ id: "cl", slack: { botName: "Claude bot" }, bind: { runtime: "claude" } }] : [];
    rig.raw.profiles = id === A ? structuredClone(profiles) : [{ id: "bx", runtime: "codex", home: "homes/bx", env: { OPENAI_API_KEY: "k" } }];
    Object.defineProperty(rig, "config", { get: () => hubConfig(rig.raw, rig.dir), configurable: true });
    // (config.json as the sharing changes it, told to who listens: ops/config.ts)
    const listeners = new Set<(raw: Json) => void>();
    const config = {
      raw: () => rig.raw,
      updateSoon: async (f: (raw: Json) => void) => {
        f(rig.raw);
        for (const l of listeners) l(rig.raw);
        return rig.raw;
      },
      listen: (l: (raw: Json) => void) => (listeners.add(l), () => listeners.delete(l)),
    } as unknown as ConfigFile;
    st.sharing = new Sharing({
      data: rig.dir, config, cloud: cloudFor(id),
      ask: async (to, ws, request) => {
        if (st.failTake && request?.method === "share.take") throw new Error("the answer was lost on the way");
        if (st.failBorrow && request?.method === "share.borrow") throw new Error("the answer was lost on the way");
        if (st.failChanged && request?.method === "share.changed") throw new Error("station unreachable");
        const there = stations.get(to);
        if (there === undefined || there.dead === true) throw new Error("station unreachable");
        // (a borrow answered late, after what would go next did: what waits for it is seen to)
        if (request?.method === "share.borrow") await settle();
        const answer = across(await there.sharing.handle(id, across(request), ws ?? WS));
        if (request?.method === "share.borrow") st.asks?.push("share.borrow answered");
        return answer;
      },
      agentHome: () => join(rig.dir, "agent"),
      env: {},
      claudeToken: async (p) => ({ token: `token-of-${p.id}@${id.slice(0, 1)}`, expiresAt: 4_000_000_000_000 }),
      codexRenewRunning: async () => false,
      status: async () => ({ check: { state: "ok" }, quota: null }),
      changed: () => {},
      // (as sessions/agents.ts gives it: a profile gone from here moves its sessions, those not held, onto another)
      profileGone: (pid) => rig.hub.profileGone(pid),
      clock: t.clock,
    });
    st.sharing.start();
    st.bus = new PeerBus({ sleep: async () => {} });
    st.bus.attach(async (to, ws, request) => {
      const there = stations.get(to);
      if (there === undefined || there.dead === true) throw there?.dead === true ? new PeerGone() : new Error("station unreachable");
      if (typeof request?.method === "string" && request.method.startsWith("handover.")) st.asks?.push(request.method);
      // (killed as this request reaches it: the request found gone, and every one after)
      if (there.killAt === request?.method) {
        there.dead = true;
        throw new PeerGone();
      }
      return across(await there.bus.handle(ws ?? WS, id, across(request)));
    });
    st.fibers = new Fibers("move", t.clock);
    st.make = () => {
      const hub = rig.hub;
      const moves = new Moves({
        data: rig.dir, store: rig.store, fibers: st.fibers, here: () => id, home: () => WS, roster: () => roster,
        ask: (s, r) => (st.failAccounts && r?.method === "move.accounts" ? ((st.failAccounts = false), Promise.reject(new Error("the station was not reached"))) : st.bus.ask(s, r)),
        hub: { holdChat: (k, w, n) => hub.holdChat(k, w, n), releaseChat: (k) => hub.releaseChat(k), wakeChat: (k) => hub.wakeChat(k), busy: (k) => hub.busy(k), turnEnded: (k) => hub.turnEnded(k), drained: (c, ch, ts) => hub.drained(c, ch, ts), wsOf: (k) => hub.wsOf(k) },
        connects: null,
        jobs: { up: () => [], stop: async () => {}, start: () => {}, stopNamed: async () => {} },
        profiles: () => rig.raw.profiles,
        // (as move/live.ts gives them)
        moveProfile: (pid, to) => st.sharing.moveProfile(pid, to),
        shareMoves: {
          move: (pid, to, made) => st.sharing.moveProfile(pid, to, undefined, made), unshare: (share, stations) => st.sharing.unshareMoved(share, stations),
          lend: (pid, to) => st.sharing.lendTo(pid, to), unlend: (share, to, made, widened) => st.sharing.unlend(share, to, made, widened),
        },
        // (sized at once, as a move would gather them: no thread of its own in a test)
        sizes: async (keys, sizing) => sizesSoon(rig.dir, join(rig.dir, "stillfail.db"), keys, sizing),
        sessionsIn: (ws, after, limit) => rig.store.sessionPageOfWs(ws === WS ? null : ws, WS, after, limit),
        reposDir: join(rig.dir, "repos"),
        room: async () => ({ free: 1e15 }),
        hasGit: async () => true,
        lackMost: 50,
        hold: () => () => {},
        changed: () => st.onMove?.(),
      });
      st.bus.on("handover.", moves.answers(() => true));
      st.bus.on("move.", moves.answers(() => true));
      return moves;
    };
    st.moves = st.make();
    // (its logins changed: what is stopped for one looked at again, as move/live.ts has it)
    listeners.add(() => st.moves.loginsChanged());
    // (a station heard from again: what is owed to it told now, what waits for what is at it looked at: as move/live.ts
    // has it)
    st.bus.heard((peer) => {
      st.moves.handover.reached(peer);
      st.moves.heard(peer);
    });
    // (as move/live.ts gives it: a login home again, by any route, has the share its trip made undone)
    st.sharing.onHosted = (share, from) => void homing.add(st.moves.shareCameHome(share, from).catch(() => {}));
    stations.set(id, st);
    open.push(async () => {
      await st.moves.close();
      await st.sharing.close();
      await st.fibers.close();
      await rig.close();
    });
    return st;
  };
  make(A);
  make(B);
  if (o.third === true && o.cUp === true) make(C);
  const a = stations.get(A)!;
  const b = stations.get(B)!;
  /// What each station set going is done: its chats' work, the sharing brought in line and written.
  const quiet = async () => {
    for (let i = 0; i < 4; i++) {
      for (const s of stations.values()) {
        await s.moves.handover.settle();
        await s.rig.quiet();
      }
      await Promise.all([...stations.values()].map((s) => s.sharing.reconcile()));
      await Promise.all(homing);
    }
    await Promise.all([...stations.values()].map((s) => s.sharing.stateWritten()));
  };
  /// Station `id` taken out of the workspace: no longer among its stations, each told as the cloud tells them.
  const leave = async (id: string) => {
    roster.splice(roster.findIndex((r) => r.id === id), 1);
    await quiet();
  };
  return { t, a, b, c: stations.get(C), quiet, leave };
}

/// The login's files in A's home of `pid`.
function signIn(st: Station, pid: string, files: Record<string, Json>) {
  const home = join(st.rig.dir, "homes", pid);
  mkdirSync(home, { recursive: true });
  for (const [name, v] of Object.entries(files)) writeFileSync(join(home, name), JSON.stringify(v));
}
const CLAUDE_LOGIN = { ".credentials.json": { claudeAiOauth: { accessToken: "x", refreshToken: "r" } }, ".claude.json": { oauthAccount: { emailAddress: "max@x" } } };

/// A still.fail chat of A's on profile `pid`, a turn behind it.
async function chatOn(st: Station, pid: string) {
  const [key, thread] = await newSession(st.rig.hub, { runtime: "claude", profile: pid, createdBy: "p@x" });
  say(st.rig.hub, thread.id, "p@x", "look at the build");
  await endTurn(st, key);
  return { key, thread: thread.id };
}

async function endTurn(st: Station, key: string) {
  await st.rig.quiet();
  await st.rig.call(key, "chat_state", { kind: "final" });
  st.rig.claude.last().complete();
  await st.rig.quiet();
}

/// Chat `key` told `text` takes a turn on it (its process prompted with it), ended as its agent would.
async function takesTurn(st: Station, key: string, thread: number, text: string, why: string): Promise<Json> {
  say(st.rig.hub, thread, "p@x", text);
  await st.rig.quiet();
  const session = st.rig.claude.sessions.find((x) => x.prompts.some((p) => p.includes(text)));
  assert.ok(session !== undefined, why);
  await st.rig.call(key, "chat_state", { kind: "final" });
  session.complete();
  await st.rig.quiet();
  return session;
}

const profile = (st: Station, pid: string) => st.rig.raw.profiles.find((p: Json) => p.id === pid);
/// Profile `pid` of station `st`, there (else the test fails saying so), and its share (else the same).
function present(st: Station, pid: string): Json {
  const p = profile(st, pid);
  assert.ok(p !== undefined, `${st.id.slice(0, 1).toUpperCase()} has a profile ${pid}`);
  return p;
}
function shareOf(st: Station, pid: string): Json {
  const share = present(st, pid).share;
  assert.ok(share !== null && typeof share === "object", `${st.id.slice(0, 1).toUpperCase()}'s ${pid} is shared`);
  return share;
}
const ofShare = (st: Station, share: string) => st.rig.raw.profiles.find((p: Json) => p.share?.id === share);
/// The shares A's moves made (move/accounts.ts, kept on the disk).
const keptShares = (st: Station): string[] => {
  try {
    return JSON.parse(readFileSync(join(st.rig.dir, "move", "accounts-shared.json"), "utf8"));
  } catch {
    return [];
  }
};
/// The logins A's moves lent, by share (move/accounts.ts, kept on the disk: kept.ts `LentLog`'s lines played, each
/// share's record and the items it is lent for).
const lentShares = (st: Station): Record<string, Json> => {
  let text = "";
  try {
    text = readFileSync(join(st.rig.dir, "move", "accounts-lent.log"), "utf8");
  } catch {
    return {};
  }
  const kept = new Map<string, Json>();
  for (const line of text.split("\n")) {
    if (line === "") continue;
    const r = JSON.parse(line);
    if ("v" in r) kept.set(r.k, r.v);
    else kept.delete(r.k);
  }
  const out: Record<string, Json> = {};
  for (const [k, v] of kept) if (k.startsWith("s:")) out[k.slice(2)] = { ...v, for: [] };
  for (const k of kept.keys()) if (k.startsWith("f:")) out[k.slice(2, k.indexOf("\n"))]?.for.push(k.slice(k.indexOf("\n") + 1));
  return out;
};
/// (a list in order; what is no list as it is, for the assertion to say)
const sorted = (xs: unknown) => (Array.isArray(xs) ? [...xs].sort() : xs);

test("an own Claude login of three chats, one chat moved with its needs: the login lent, not moved: hosted here still, borrowed there, shared with the two stations alone; the other two chats go on, none stopped; the chat back alone, it is this station's own again", async () => {
  const { a, b, quiet } = world([MAX]);
  signIn(a, "max", CLAUDE_LOGIN);
  const one = await chatOn(a, "max");
  const two = await chatOn(a, "max");
  const three = await chatOn(a, "max");
  const account = `own:max@${A}`;
  const plan = await a.moves.scheduler.plan(WS, B);
  const item = plan.items.find((x) => x.id === account)!;
  assert.ok(item, JSON.stringify(plan.items.map((x) => x.id)));
  assert.deepEqual(item.wouldStop, [], "the plan says it stops nothing");
  a.asks = [];
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
  await quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  // (the other has its copy, answered, before the chat's hand-over is begun there)
  assert.ok(a.asks.indexOf("share.borrow answered") >= 0 && a.asks.indexOf("share.borrow answered") < a.asks.indexOf("handover.begin"), `borrowed before the hand-over begins: ${JSON.stringify(a.asks.slice(0, 4))}`);
  assert.deepEqual(out.done, [{ module: "chats", id: one.key }], "the chat alone moved");
  // (and the chat takes its first turn there on the login it found lent)
  await takesTurn(b, one.key, b.rig.store.homeChat(one.key)!.id, "there now?", "a turn there on the lent login");
  assert.deepEqual(out.lent, [{ module: "accounts", id: account }], "its login lent for it");
  assert.deepEqual(out.stopped, []);
  assert.deepEqual(a.moves.scheduler.stopped(), []);
  assert.equal(a.rig.hub.chatHeld(two.key), null);
  assert.equal(a.rig.hub.chatHeld(three.key), null);
  assert.equal(a.rig.store.handedTo(one.key)?.station, B, "the chat went");
  // hosted here still, shared with the two stations alone; borrowed there
  const here = present(a, "max");
  const share = here.share.id as string;
  assert.equal(here.share.borrowed, undefined, "hosted here");
  assert.deepEqual(sorted(here.share.allow), sorted([A, B]), "the two stations alone, never every station");
  assert.equal(JSON.parse(readFileSync(join(a.rig.dir, "homes", "max", ".credentials.json"), "utf8")).claudeAiOauth.refreshToken, "r", "its login here, nothing of it left this station");
  assert.equal(ofShare(b, share)?.share.borrowed, true, "B borrows it");
  assert.equal(ofShare(b, share)?.share.host, A);
  assert.equal(existsSync(join(b.rig.dir, "homes", "max", ".credentials.json")), false, "no login there");
  assert.deepEqual(keptShares(a), [], "no host moved, nothing of that kind kept");
  assert.deepEqual(Object.keys(lentShares(a)), [share], "kept as lent for the chat");
  // the chats here go on, nothing said in them
  await takesTurn(a, two.key, two.thread, "and now?", "a turn as ever");
  assert.ok(!a.rig.store.entriesAfter(three.thread, 0).some((e) => /moved|stopped/i.test(e.text ?? "")), "nothing said");
  // the plan and the page: here, usable on B
  const after = await a.moves.scheduler.plan(WS, B);
  const lentItem = after.items.find((x) => x.id === `share:${share}`)!;
  assert.deepEqual([lentItem.state, lentItem.lentTo], ["here", B], "here, usable on B");
  const view = moveView(after, a.moves.modules.map((m) => m.id), a.moves.scheduler.stopped(), { limit: 50 }, null, false, (id) => id.slice(0, 1).toUpperCase());
  const accounts = view.modules.find((m: Json) => m.id === "accounts");
  assert.equal(accounts.items.find((x: Json) => x.id === `share:${share}`)?.lentTo, "B");
  assert.ok(accounts.done < accounts.total, "a login hosted here counts as left here");
  // the chat back alone, the last it was lent for: the lending undone, the login this station's own again
  const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: one.key });
  await quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.equal(present(a, "max").share, undefined, "not shared any more");
  assert.equal(b.rig.raw.profiles.some((p: Json) => p.share?.id === share), false, "B keeps no copy");
  assert.deepEqual(lentShares(a), {}, "nothing kept lent");
});

test("a login lent stays lent while anything on the other station runs on it: a chat moved by a later turn is kept as one it is lent for, a chat begun there on it keeps it; taken back once nothing there runs on it", async () => {
  const { a, b, quiet } = world([MAX]);
  signIn(a, "max", CLAUDE_LOGIN);
  const one = await chatOn(a, "max");
  const two = await chatOn(a, "max");
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
  await quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  const share = present(a, "max").share.id as string;
  // A later turn: the second chat alone, the login usable there as it is lent: kept as lent for it too.
  const later = await a.moves.scheduler.move(WS, B, { module: "chats", item: two.key });
  await quiet();
  assert.equal(later.failed, null, JSON.stringify(later));
  assert.deepEqual(sorted(lentShares(a)[share]?.for), sorted([`chats ${one.key}`, `chats ${two.key}`]), "lent for both");
  // A chat B begins on the login it borrows (as a connect moved there begins one).
  const [mine, mineThread] = await newSession(b.rig.hub, { runtime: "claude", profile: ofShare(b, share).id, createdBy: "p@x" });
  // The first back: lent still, for the second.
  await a.moves.scheduler.back(WS, B, { module: "chats", item: one.key });
  await quiet();
  assert.equal(ofShare(b, share)?.share.borrowed, true, "B borrows it still: the second chat runs on it there");
  await takesTurn(b, two.key, b.rig.store.homeChat(two.key)!.id, "still there?", "a turn there on the lent login");
  // The second back: lent for nothing of A's, but B's own chat runs on it: kept lent.
  await a.moves.scheduler.back(WS, B, { module: "chats", item: two.key });
  await quiet();
  assert.equal(ofShare(b, share)?.share.borrowed, true, "B borrows it still: its own chat runs on it");
  assert.deepEqual(lentShares(a)[share]?.for, [], "kept lent, for nothing of A's");
  say(b.rig.hub, mineThread.id, "p@x", "hello on the lent login");
  await quiet();
  assert.ok(b.rig.claude.sessions.some((x) => x.prompts.some((p) => p.includes("hello on the lent login"))), "B's chat takes its turn on it");
  // B's chat archived: at the next turn's end, whatever it moved (here nothing: an item not there), nothing there runs
  // on it, and it is taken back.
  b.rig.store.setArchived(mine, true, "p@x");
  await a.moves.scheduler.move(WS, B, { module: "chats", item: "chat:c-none" }).catch(() => {});
  await quiet();
  assert.equal(b.rig.raw.profiles.some((p: Json) => p.share?.id === share), false, "B keeps no copy");
  assert.equal(present(a, "max").share, undefined, "not shared any more");
  assert.deepEqual(lentShares(a), {}, "nothing kept lent");
});

test("a lent login is taken back as its last use on the station it is lent to ends by that station's doing: its chat handed to the lender by its own turn, archived there, or moved to another login there; one told while the lender is down is told as it is heard from", async () => {
  for (const how of ["handed home", "archived", "another login", "lender down"] as const) {
    const { a, b, quiet } = world([MAX]);
    signIn(a, "max", CLAUDE_LOGIN);
    const one = await chatOn(a, "max");
    assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true })).failed, null);
    await quiet();
    const share = present(a, "max").share.id as string;
    // (a chat B begins on the login it borrows; the one it was lent for back: lent still, for B's)
    const [mine] = await newSession(b.rig.hub, { runtime: "claude", profile: ofShare(b, share).id, createdBy: "p@x" });
    await quiet();
    await a.moves.scheduler.back(WS, B, { module: "chats", item: one.key });
    await quiet();
    assert.equal(ofShare(b, share)?.share.borrowed, true, `${how}: lent still, for B's own chat`);
    // Its last use there ends, by B's doing alone.
    if (how === "handed home") assert.equal((await b.moves.scheduler.move(WS, A, { module: "chats", item: mine })).failed, null);
    else if (how === "another login") b.rig.store.setSessionProfile(mine, "bx", false);
    else {
      if (how === "lender down") a.dead = true;
      b.rig.store.setArchived(mine, true, "p@x");
    }
    await quiet();
    if (how === "lender down") {
      assert.equal(ofShare(b, share)?.share.borrowed, true, "not told yet: the lender down");
      a.dead = false;
      // (A heard from again: it asks B something, as a plan does)
      await a.moves.scheduler.plan(WS, B);
      await quiet();
    }
    assert.equal(b.rig.raw.profiles.some((p: Json) => p.share?.id === share), false, `${how}: B keeps no copy`);
    assert.equal(present(a, "max").share, undefined, `${how}: not shared any more`);
    assert.deepEqual(lentShares(a), {}, `${how}: nothing kept lent`);
  }
});

test("what a station kept lent before it kept later turns' chats is mended as it starts: the chats handed to where it is lent that run on it", async () => {
  const { a, quiet } = world([MAX]);
  signIn(a, "max", CLAUDE_LOGIN);
  const one = await chatOn(a, "max");
  const two = await chatOn(a, "max");
  await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
  await quiet();
  await a.moves.scheduler.move(WS, B, { module: "chats", item: two.key });
  await quiet();
  const share = present(a, "max").share.id as string;
  // (as the code before kept it: the second chat's line missing)
  const log = join(a.rig.dir, "move", "accounts-lent.log");
  writeFileSync(log, readFileSync(log, "utf8").split("\n").filter((l) => !l.includes(two.key)).join("\n"));
  assert.deepEqual(lentShares(a)[share]?.for, [`chats ${one.key}`]);
  await a.moves.close();
  a.moves = a.make();
  await a.moves.start();
  // (what the start mends, written: as a turn's end waits for it)
  await a.moves.modules.find((m) => m.id === "accounts")!.left!([]);
  assert.deepEqual(sorted(lentShares(a)[share]?.for), sorted([`chats ${one.key}`, `chats ${two.key}`]), "mended");
});

test("moved back: the login is this station's own again, not shared, the other keeps no profile of it, nothing kept; started again between, the same", async () => {
  for (const restart of [false, true]) {
    const { a, b, quiet } = world([MAX]);
    signIn(a, "max", CLAUDE_LOGIN);
    const one = await chatOn(a, "max");
    await chatOn(a, "max");
    // (the login asked for by name: its host moves, shared as it moves; then the chat)
    await a.moves.scheduler.move(WS, B, { module: "accounts", item: `own:max@${A}` });
    await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key });
    await quiet();
    const share = shareOf(a, "max").id as string;
    if (restart) {
      // (a new accounts module over the same files)
      await a.moves.close();
      a.moves = a.make();
      await a.moves.start();
    }
    const back = await a.moves.scheduler.back(WS, B, { module: "accounts", item: `share:${share}`, withNeeds: true });
    await quiet();
    assert.equal(back.failed, null, JSON.stringify(back));
    assert.deepEqual(back.done, [{ module: "chats", id: one.key }, { module: "accounts", id: `share:${share}` }], `restart ${restart}`);
    const home = present(a, "max");
    assert.equal(home.share, undefined, `not shared (restart ${restart})`);
    assert.equal(JSON.parse(readFileSync(join(a.rig.dir, "homes", "max", ".credentials.json"), "utf8")).claudeAiOauth.refreshToken, "r", "its login here");
    assert.equal(b.rig.raw.profiles.some((p: Json) => p.id === "max" || p.share?.id === share), false, `the other keeps no copy (restart ${restart})`);
    assert.deepEqual(keptShares(a), []);
    const plan = await a.moves.scheduler.plan(WS, B);
    assert.equal(plan.items.find((x) => x.id === `own:max@${A}`)?.state, "here", "its own again, by the id it had");
  }
});

test("moved back after a person opened it to a third station: it stays shared, as they gave it", async () => {
  const { a, b, quiet } = world([MAX], { third: true });
  signIn(a, "max", CLAUDE_LOGIN);
  const one = await chatOn(a, "max");
  await a.moves.scheduler.move(WS, B, { module: "accounts", item: `own:max@${A}` });
  await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key });
  await quiet();
  const share = shareOf(a, "max").id as string;
  assert.deepEqual(sorted(ofShare(b, share)?.share.allow), sorted([A, B]), "no third station gains it from the move");
  assert.ok(ofShare(b, share) !== undefined, "B hosts it");
  await b.sharing.shareProfile(ofShare(b, share)!.id, true, [A, B, C], null, "a person");
  await quiet();
  const back = await a.moves.scheduler.back(WS, B, { module: "accounts", item: `share:${share}`, withNeeds: true });
  await quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  const home = present(a, "max");
  assert.equal(home.share?.id, share, "still shared");
  assert.equal(home.share.borrowed, undefined, "hosted here again");
  assert.deepEqual(sorted(home.share.allow), sorted([A, B, C]));
  assert.equal(ofShare(b, share)?.share.borrowed, true, "B borrows it, as it may");
  assert.deepEqual(keptShares(a), [], "no longer this move's to undo");
});

test("home again by the other's own move (its scheduler, or a person moving it on the accounts page): the share this station's trip made is undone, the login its own again, nothing kept", async () => {
  for (const route of ["scheduler", "accounts page"]) {
    const { a, b, quiet } = world([MAX]);
    signIn(a, "max", CLAUDE_LOGIN);
    const one = await chatOn(a, "max");
    await a.moves.scheduler.move(WS, B, { module: "accounts", item: `own:max@${A}` });
    await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key });
    await quiet();
    const share = shareOf(a, "max").id as string;
    assert.deepEqual(keptShares(a), [share], "made by the trip");
    const there = ofShare(b, share)!;
    if (route === "scheduler") {
      const out = await b.moves.scheduler.move(WS, A, { module: "accounts", item: `share:${share}` });
      assert.equal(out.failed, null, JSON.stringify(out));
      assert.deepEqual(out.done, [{ module: "accounts", id: `share:${share}` }], route);
    } else await b.sharing.moveProfile(there.id, A);
    await quiet();
    const home = present(a, "max");
    assert.equal(home.share, undefined, `not shared once home (${route})`);
    assert.equal(JSON.parse(readFileSync(join(a.rig.dir, "homes", "max", ".credentials.json"), "utf8")).claudeAiOauth.refreshToken, "r", "its login here");
    assert.equal(b.rig.raw.profiles.some((p: Json) => p.id === "max" || p.share?.id === share), false, `the other keeps no copy (${route})`);
    assert.deepEqual(keptShares(a), [], `nothing kept (${route})`);
    assert.equal((await a.moves.scheduler.plan(WS, B)).items.find((x) => x.id === `own:max@${A}`)?.state, "here", "its own again, by the id it had");
  }
});

test("the other station not answering what logins it has as the plan asks: the chat on one refused in words (ask again), nothing of it tried, nothing moved; asked again with the answer, it goes", async () => {
  const { a, b, quiet } = world([MAX]);
  signIn(a, "max", CLAUDE_LOGIN);
  const one = await chatOn(a, "max");
  const account = `own:max@${A}`;
  a.failAccounts = true;
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
  await quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.deepEqual(out.done, []);
  assert.deepEqual(out.refused.map((r) => r.item.id), [one.key], "the chat, nothing else tried");
  assert.match(out.refused[0]!.why, /^(it needs account “[^”]+” there, which cannot go: the other station did not answer whether it has it: ask again|它需要账号「[^」]+」在那边，而那一项迁不了：另一台 station 没有回答它那边有没有这一项：再试一次)$/);
  assert.equal(present(a, "max").share, undefined, "not shared");
  assert.equal(JSON.parse(readFileSync(join(a.rig.dir, "homes", "max", ".credentials.json"), "utf8")).claudeAiOauth.refreshToken, "r", "its login here");
  assert.equal(b.rig.raw.profiles.some((p: Json) => p.id === "max"), false, "nothing of it there");
  assert.equal(a.rig.store.handedTo(one.key), null, "the chat here");
  assert.equal(a.rig.hub.chatHeld(one.key), null, "not stopped");
  assert.deepEqual(keptShares(a), []);
  const again = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
  await quiet();
  assert.equal(again.failed, null, JSON.stringify(again));
  assert.deepEqual(again.done, [{ module: "chats", id: one.key }]);
  assert.deepEqual(again.lent, [{ module: "accounts", id: account }], "its login lent, not moved");
  assert.equal(a.rig.store.handedTo(one.key)?.station, B, "the chat went");
});

test("a login not shared handed to and fro three times: what each station keeps of a hand-over taken (share/state.json `taken`) goes once its profile is gone from there, never more than the one it holds", async () => {
  const { a, b, quiet } = world([KIMI]);
  signIn(a, "kimi", {});
  const taken = (st: Station) => JSON.parse(readFileSync(join(st.rig.dir, "share", "state.json"), "utf8")).taken ?? {};
  await a.sharing.moveProfile("kimi", B);
  await quiet();
  assert.deepEqual(taken(b), { [`${A}/kimi`]: "kimi" }, "B took it");
  await b.sharing.moveProfile("kimi", A);
  await quiet();
  assert.deepEqual(taken(b), {}, "B's goes with its profile");
  assert.deepEqual(taken(a), { [`${B}/kimi`]: "kimi" }, "A took it");
  await a.sharing.moveProfile("kimi", B);
  await quiet();
  assert.deepEqual(taken(a), {}, "A's goes with its profile");
  assert.deepEqual(taken(b), { [`${A}/kimi`]: "kimi" }, "B took it again: one entry");
  assert.equal(present(b, "kimi").id, "kimi");
});

test("a chat whose login is on no station any more (its profile removed here since) is no item's need: the plan lists no account for it; it goes, alone or with all, the archived one too, nothing refused or failed; there it answers a message as here; back likewise", async () => {
  const { a, b, quiet } = world([MAX, SPARE]);
  signIn(a, "max", CLAUDE_LOGIN);
  const one = await chatOn(a, "max");
  const shelved = await chatOn(a, "max");
  signIn(a, "spare", CLAUDE_LOGIN);
  const unknown = await chatOn(a, "spare");
  // (one whose login no station ever had, its rows naming a profile never known here; one known as it was, then
  // removed: renamed or taken out by a person)
  a.rig.store.db.prepare("UPDATE sessions SET profile = 'ghost', profiles = NULL WHERE key = ?").run(unknown.key);
  a.rig.store.db.prepare("UPDATE runtime_sessions SET profile = 'ghost' WHERE session_key = ?").run(unknown.key);
  a.rig.raw.profiles = a.rig.raw.profiles.filter((p: Json) => p.id !== "spare");
  await a.moves.scheduler.plan(WS, B);
  a.rig.raw.profiles = a.rig.raw.profiles.filter((p: Json) => p.id !== "max");
  a.rig.store.setArchived(shelved.key, true, "auto");
  const plan = await a.moves.scheduler.plan(WS, B);
  assert.deepEqual(plan.items.filter((x) => x.module === "accounts").map((x) => x.id), [], "no account item for a login that is nowhere, known before or not");
  assert.ok(!plan.items.some((x) => x.id === "machine:ghost"), "one never known is no machine's own login either");
  const view = moveView(plan, a.moves.modules.map((m) => m.id), a.moves.scheduler.stopped(), { limit: 50 }, null, false, (id) => id.slice(0, 1).toUpperCase());
  assert.equal(view.modules.find((m: Json) => m.id === "accounts")?.cannot ?? 0, 0, "nothing counted as unable to move");
  // (what a person's word to it does: here, then there, then here again, the same)
  const said = (st: Station, thread: number) => (st.rig.store.db.prepare("SELECT text FROM entries WHERE thread = ? AND author_kind = 'station' ORDER BY n").all(thread) as { text: string }[]).map((r) => r.text);
  const react = async (st: Station, thread: number, text: string) => {
    const before = said(st, thread).length;
    say(st.rig.hub, thread, "p@x", text);
    await quiet();
    // (a turn it began on a process of its own, ended as its agent would: nothing left in a turn to wait for)
    const session = st.rig.claude.sessions.find((x) => x.prompts.some((p) => p.includes(text)));
    if (session !== undefined) {
      await st.rig.call(one.key, "chat_state", { kind: "final" });
      session.complete();
      await quiet();
    }
    assert.equal(st.rig.hub.busy(one.key), false, `${st.id.slice(0, 1)}: in no turn after: ${JSON.stringify(said(st, thread).slice(before))}`);
    return { said: said(st, thread).slice(before).map((x) => x.replace(/[「“][^」”]*[」”]/g, "…")), turn: session !== undefined };
  };
  // (its process from before its login was removed ended, as after a start: what it does is what a chat whose
  // account is missing does)
  await a.rig.hub.holdChat(one.key, "its process ended");
  a.rig.hub.releaseChat(one.key);
  await quiet();
  const here = await react(a, one.thread, "still there?");
  if (process.env.MOVE_SAID === "1") console.log(`SAID ${JSON.stringify(here)}`);
  assert.deepEqual([here.said.length, here.turn], [1, false], `a chat whose account is missing says so once, no turn: ${JSON.stringify(here)}`);
  const out = await a.moves.scheduler.move(WS, B, { all: true });
  await quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.deepEqual(out.refused, [], "nothing refused");
  assert.deepEqual(out.failures ?? [], []);
  for (const k of [one.key, shelved.key, unknown.key]) assert.equal(a.rig.store.handedTo(k)?.station, B, `${k} went`);
  assert.notEqual(b.rig.store.getSession(shelved.key)?.archivedAt ?? null, null, "the archived one archived there");
  const there = await react(b, b.rig.store.homeChat(one.key)!.id, "and now?");
  assert.deepEqual(there, here, "there as here");
  const back = await a.moves.scheduler.back(WS, B, { all: true });
  await quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.deepEqual(back.refused, []);
  for (const k of [one.key, shelved.key, unknown.key]) assert.equal(a.rig.store.handedTo(k), null, `${k} back`);
  assert.deepEqual(await react(a, one.thread, "back?"), here, "back here as before");
});

test("a login that cannot be shared (a Kimi sign-in) moves as it is: gone from here, what needs it here stopped first", async () => {
  const { a, b, quiet } = world([KIMI]);
  assert.notEqual(shareRefusal(KIMI), null);
  signIn(a, "kimi", {});
  const [k1] = await newSession(a.rig.hub, { runtime: "claude", profile: "kimi", createdBy: "p@x" });
  const [k2] = await newSession(a.rig.hub, { runtime: "claude", profile: "kimi", createdBy: "p@x" });
  await quiet();
  const account = `own:kimi@${A}`;
  const plan = await a.moves.scheduler.plan(WS, B);
  const item = plan.items.find((x) => x.id === account)!;
  assert.equal(a.moves.modules.find((m) => m.id === "accounts")!.usableHere!(item), false);
  assert.deepEqual(sorted(item.wouldStop.map((n) => n.id)), sorted([k1, k2]));
  // (each telling of the moves' change read as a device would: one consistent state, and a turn under way says so)
  let ended = false;
  const reads: Promise<string | null>[] = [];
  a.onMove = () => {
    const during = !ended;
    reads.push((async () => {
      const view = moveView(await a.moves.scheduler.plan(WS, B), a.moves.modules.map((m) => m.id), a.moves.scheduler.stopped(), { limit: 50 }, null, false, (id) => id.slice(0, 1).toUpperCase(), a.moves.scheduler.current());
      const kept = new Set(a.moves.scheduler.stopped().map((x) => x.item.id));
      for (const x of view.modules.find((m: Json) => m.id === "chats").items as Json[]) {
        if (x.state === "here" && kept.has(x.id)) return `${x.id} here while kept stopped`;
        if (x.state === "stopped" && a.rig.store.handedTo(x.id) !== null) return `${x.id} stopped while handed away`;
      }
      if (during && a.moves.scheduler.busy() && view.moving === null) return "a turn under way read as nothing moving";
      return null;
    })());
  };
  const out = await a.moves.scheduler.move(WS, B, { module: "accounts", item: account });
  ended = true;
  a.onMove = undefined;
  assert.ok(reads.length > 0, "devices told");
  assert.deepEqual((await Promise.all(reads)).filter((x) => x !== null), [], "every read one consistent state");
  // (the moment the turn's end is told, before anything settles: both rows on the page stopped, waiting for it on B)
  const view = moveView(await a.moves.scheduler.plan(WS, B), a.moves.modules.map((m) => m.id), a.moves.scheduler.stopped(), { limit: 50 }, null, false, (id) => id.slice(0, 1).toUpperCase());
  const rows = view.modules.find((m: Json) => m.id === "chats").items.filter((x: Json) => x.id === k1 || x.id === k2).map((x: Json) => [x.id, x.state, x.waitsFor, x.waitsAt]);
  assert.deepEqual(sorted(rows.map((r: Json[]) => JSON.stringify(r))), sorted([k1, k2].map((k) => JSON.stringify([k, "stopped", `accounts ${account}`, "B"]))), "both rows stopped, waiting for it on B");
  await quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.deepEqual(sorted(out.stopped.map((s) => s.item.id)), sorted([k1, k2]));
  assert.match(a.rig.hub.chatHeld(k1) ?? "", /waits for accounts own:kimi@/);
  assert.equal(profile(a, "kimi"), undefined, "gone from here");
  assert.equal(profile(b, "kimi")?.share, undefined, "the other's own, not shared");
  assert.deepEqual(keptShares(a), []);
  // (there now: moving it stops nothing more, though what needs it here is stopped)
  const there = (await a.moves.scheduler.plan(WS, B)).items.find((x) => x.id === account)!;
  assert.equal(there.state, "there");
  assert.deepEqual(there.wouldStop, [], "there already: a move of it would stop nothing");
});

test("one shared before with every station: the other only borrowing it, it is here still and usable there; moved, the other hosts it and this one borrows it, nothing stopped; back, this one hosts it again, shared as it was", async () => {
  const { a, b, quiet } = world([MAX]);
  signIn(a, "max", CLAUDE_LOGIN);
  await a.sharing.shareProfile("max", true, null);
  await quiet();
  const share = shareOf(a, "max").id as string;
  const account = `share:${share}`;
  const one = await chatOn(a, "max");
  const two = await chatOn(a, "max");
  const accounts = a.moves.modules.find((m) => m.id === "accounts")!;
  // (B borrows it: the login is A's still, lost with A; what needs it may go there all the same)
  const plan = await a.moves.scheduler.plan(WS, B);
  const item = plan.items.find((x) => x.id === account)!;
  assert.equal(item.state, "here", "not there: B only borrows it");
  assert.equal(accounts.usableThere!(item), true, "usable there");
  assert.deepEqual(item.wouldStop, [], "borrowed here once it moved");
  // a move back asked of B anyway: refused, saying where the login is
  await assert.rejects(b.bus.handle(WS, A, { method: "move.back", module: "accounts", id: account, to: A }), /only borrows it, its login is on A \(the station asking\)/);
  const out = await a.moves.scheduler.move(WS, B, { module: "accounts", item: account });
  await quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.deepEqual(out.done, [{ module: "accounts", id: account }]);
  assert.deepEqual(a.moves.scheduler.stopped(), []);
  assert.equal(a.rig.hub.chatHeld(one.key), null);
  assert.equal(a.rig.hub.chatHeld(two.key), null);
  assert.equal(shareOf(a, "max").borrowed, true, "A borrows it");
  assert.equal(shareOf(a, "max").host, B);
  assert.equal(ofShare(b, share)?.share.borrowed, undefined, "B hosts it");
  assert.equal(ofShare(b, share)?.share.allow, null, "every station, as a person had it");
  assert.equal((await a.moves.scheduler.plan(WS, B)).items.find((x) => x.id === account)?.state, "there");
  assert.deepEqual(keptShares(a), [], "not made by the move");
  await takesTurn(a, two.key, two.thread, "and now?", "a turn as ever");
  const back = await a.moves.scheduler.back(WS, B, { module: "accounts", item: account });
  await quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.deepEqual(shareOf(a, "max"), { id: share, allow: null }, "A hosts it again, still shared");
  assert.equal(ofShare(b, share)?.share.borrowed, true, "B borrows it again");
  const after = (await a.moves.scheduler.plan(WS, B)).items.find((x) => x.id === account)!;
  assert.equal(after.state, "here");
  assert.equal(accounts.usableThere!(after), true);
});

test("a chat on a login the other station hosts and this one borrows: it goes, nothing of the login moves; back likewise", async () => {
  const { a, b, quiet } = world([MAX]);
  signIn(a, "max", CLAUDE_LOGIN);
  await a.sharing.shareProfile("max", true, null);
  await quiet();
  const share = shareOf(a, "max").id as string;
  const account = `share:${share}`;
  const one = await chatOn(a, "max");
  await a.moves.scheduler.move(WS, B, { module: "accounts", item: account });
  await quiet();
  assert.equal(shareOf(a, "max").borrowed, true, "A borrows it");
  const accounts = a.moves.modules.find((m) => m.id === "accounts")!;
  const plan = await a.moves.scheduler.plan(WS, B);
  const item = plan.items.find((x) => x.id === account)!;
  assert.equal(item.state, "there", "B hosts it");
  assert.equal(accounts.usableThere!(item), true, "usable there: B hosts it");
  const hosted = structuredClone(ofShare(b, share));
  const borrowed = structuredClone(present(a, "max"));
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
  await quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.deepEqual(out.done, [{ module: "chats", id: one.key }], "the chat alone");
  assert.deepEqual(out.refused, []);
  assert.equal(a.rig.store.handedTo(one.key)?.station, B, "the chat went");
  assert.deepEqual(present(a, "max"), borrowed, "A borrows it as it did");
  assert.deepEqual(ofShare(b, share), hosted, "B hosts it as it did");
  assert.deepEqual(keptShares(a), []);
  const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: one.key, withNeeds: true });
  await quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.deepEqual(back.done, [{ module: "chats", id: one.key }], "the chat alone");
  assert.equal(a.rig.store.handedTo(one.key), null, "the chat home");
  assert.deepEqual(present(a, "max"), borrowed, "A borrows it still");
  assert.deepEqual(ofShare(b, share), hosted, "B hosts it still");
  assert.equal(a.rig.hub.chatHeld(one.key), null, "not stopped: its login is usable here");
});

test("one shared before with stations the other is not among: it moves as a shared one, and back it stays shared with them, the other keeping nothing", async () => {
  const { a, b, quiet } = world([MAX], { third: true });
  signIn(a, "max", CLAUDE_LOGIN);
  await a.sharing.shareProfile("max", true, [A, C]);
  await quiet();
  const share = shareOf(a, "max").id as string;
  const one = await chatOn(a, "max");
  const two = await chatOn(a, "max");
  // (the login asked for by name, its host moving, then a chat on it)
  const out = await a.moves.scheduler.move(WS, B, { module: "accounts", item: `share:${share}` });
  await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key });
  await quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.deepEqual(out.done, [{ module: "accounts", id: `share:${share}` }]);
  assert.deepEqual(a.moves.scheduler.stopped(), []);
  assert.equal(shareOf(a, "max").borrowed, true, "borrowed here");
  assert.deepEqual(sorted(ofShare(b, share)?.share.allow), sorted([A, C]), "who may use it as a person had it");
  assert.deepEqual(keptShares(a), [], "not made by the move");
  // (no word of A's reaches B meanwhile: B keeps no copy by itself, not waiting to be told it is not for it)
  a.failChanged = true;
  const back = await a.moves.scheduler.back(WS, B, { module: "accounts", item: `share:${share}`, withNeeds: true });
  await quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.deepEqual(shareOf(a, "max"), { id: share, allow: [A, C] }, "still shared, hosted here");
  assert.equal(ofShare(b, share), undefined, "the other, not allowed, keeps no copy");
  a.failChanged = false;
});

test("moveProfile asked to share first a login that cannot be shared: moved as it is, nothing shared, shareFirst never told", async () => {
  const { a, b } = world([KIMI]);
  signIn(a, "kimi", {});
  const told: string[] = [];
  const out = await a.sharing.moveProfile("kimi", B, "en", async (share) => void told.push(share));
  assert.deepEqual(told, []);
  assert.equal(out.share, undefined);
  assert.equal(profile(a, "kimi"), undefined, "gone from here");
  assert.equal(present(b, "kimi").share, undefined, "the other's own, not shared");
});

test("one shared before with stations the other is not among, its chat moved with what it needs: lent by adding the other, this station its host; the chat back, the other taken off again, the share as a person had it", async () => {
  const { a, b, quiet } = world([MAX], { third: true });
  signIn(a, "max", CLAUDE_LOGIN);
  await a.sharing.shareProfile("max", true, [A, C]);
  await quiet();
  const share = shareOf(a, "max").id as string;
  const one = await chatOn(a, "max");
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
  await quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.deepEqual(out.done, [{ module: "chats", id: one.key }]);
  assert.deepEqual(out.lent, [{ module: "accounts", id: `share:${share}` }]);
  assert.equal(shareOf(a, "max").borrowed, undefined, "hosted here");
  assert.deepEqual(sorted(shareOf(a, "max").allow), sorted([A, B, C]), "the other added, those a person gave it to kept");
  assert.equal(ofShare(b, share)?.share.borrowed, true, "B borrows it");
  const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: one.key });
  await quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.deepEqual(shareOf(a, "max"), { id: share, allow: [A, C] }, "as a person had it");
  assert.equal(ofShare(b, share), undefined, "the other, taken off, keeps no copy");
  assert.deepEqual(lentShares(a), {});
});

test("a chat moved to C with its login that can be shared, and back alone; or still there; then C taken out of the workspace: the login is this station's own, here and usable, C's leaving takes nothing of it", async () => {
  for (const back of [true, false]) {
    const { a, c, quiet, leave } = world([MAX], { third: true, cUp: true });
    signIn(a, "max", CLAUDE_LOGIN);
    const one = await chatOn(a, "max");
    const two = await chatOn(a, "max");
    const out = await a.moves.scheduler.move(WS, C, { module: "chats", item: one.key, withNeeds: true });
    await quiet();
    assert.equal(out.failed, null, JSON.stringify(out));
    assert.deepEqual(out.lent, [{ module: "accounts", id: `own:max@${A}` }], "lent, not moved");
    if (back) {
      assert.equal((await a.moves.scheduler.back(WS, C, { module: "chats", item: one.key })).failed, null);
      await quiet();
    }
    void c;
    await leave(C);
    const home = present(a, "max");
    assert.equal(home.share?.borrowed, undefined, `hosted here (back ${back})`);
    if (back) assert.equal(home.share, undefined, "the lending undone as the chat came back");
    assert.equal(JSON.parse(readFileSync(join(a.rig.dir, "homes", "max", ".credentials.json"), "utf8")).claudeAiOauth.refreshToken, "r", `its login here (back ${back})`);
    await takesTurn(a, two.key, two.thread, "still here?", `it works (back ${back})`);
  }
});

/// A login of C's own (`MAX`), shared by C with `allow` (null: every station): its share, borrowed by the stations
/// it is shared with; the chat of A's on it, a turn behind it.
async function sharedByC(w: ReturnType<typeof world>, allow: string[] | null) {
  const c = w.c!;
  c.rig.raw.profiles.push(structuredClone(MAX));
  signIn(c, "max", CLAUDE_LOGIN);
  await c.sharing.shareProfile("max", true, allow);
  await w.quiet();
  const share = shareOf(c, "max").id as string;
  const pid = ofShare(w.a, share)?.id as string;
  assert.equal(ofShare(w.a, share)?.share.borrowed, true, "A borrows C's login");
  const one = await chatOn(w.a, pid);
  return { share, pid, one, account: `share:${share}` };
}

test("a login a third station hosts and shares with both, a chat of this station's on it: no item of a move between the two (neither's to move); the chat goes alone, with its needs or with all, nothing refused or failed, and works there on the other's borrowed copy; back with all likewise, the login C's throughout", async () => {
  for (const how of ["withNeeds", "all"] as const) {
    const w = world([], { third: true, cUp: true });
    const { a, b, c, quiet } = w;
    const { share, one, account } = await sharedByC(w, null);
    assert.equal(ofShare(b, share)?.share.borrowed, true, "B borrows it too");
    const plan = await a.moves.scheduler.plan(WS, B);
    assert.deepEqual(plan.items.filter((x) => x.module === "accounts").map((x) => x.id), [], `no item for C's login (${how})`);
    assert.deepEqual(plan.items.find((x) => x.id === one.key)?.needs.map((n) => n.id), [account], "the chat still names it as its need");
    const hosted = structuredClone(shareOf(c!, "max"));
    const out = how === "all" ? await a.moves.scheduler.move(WS, B, { all: true }) : await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
    await quiet();
    assert.equal(out.failed, null, `${how}: ${JSON.stringify(out)}`);
    assert.deepEqual(out.refused, [], `${how}: nothing refused`);
    assert.ok(out.done.some((d) => d.id === one.key), `${how}: the chat went`);
    assert.ok(!out.done.some((d) => d.module === "accounts"), `${how}: no login moved`);
    assert.equal(a.rig.store.handedTo(one.key)?.station, B);
    assert.deepEqual(b.moves.scheduler.stopped(), [], "nothing stopped there");
    await takesTurn(b, one.key, b.rig.store.homeChat(one.key)!.id, "there?", `${how}: it works there on B's borrowed copy`);
    assert.deepEqual(shareOf(c!, "max"), hosted, "C hosts it as it did");
    assert.equal(ofShare(a, share)?.share.borrowed, true, "A borrows it still");
    assert.equal(ofShare(b, share)?.share.borrowed, true, "B borrows it still");
    const back = await a.moves.scheduler.back(WS, B, { all: true });
    await quiet();
    assert.equal(back.failed, null, `${how}: ${JSON.stringify(back)}`);
    assert.deepEqual(back.refused, []);
    assert.equal(a.rig.store.handedTo(one.key), null, "the chat home");
    assert.equal(a.rig.hub.chatHeld(one.key), null, "not stopped: its login is usable here");
    assert.deepEqual(shareOf(c!, "max"), hosted, "C hosts it as it did, back too");
    assert.equal(ofShare(a, share)?.share.borrowed, true);
    assert.equal(ofShare(b, share)?.share.borrowed, true);
    await takesTurn(a, one.key, one.thread, "home?", `${how}: it works here again`);
    await closeAll();
  }
});

test("a login a third station hosts and shares with this one but not the other: the plan says it cannot move, as it is the third's; a whole move refuses it and the chat on it, failing nothing; the chat moved arriving stopped waits there, and goes on as the third shares the login with that station too", async () => {
  const w = world([], { third: true, cUp: true });
  const { a, b, c, quiet } = w;
  const { share, one, account } = await sharedByC(w, [A, C]);
  assert.equal(ofShare(b, share), undefined, "B has no copy");
  const moveBorrowed = tr(stationLang(), "station.share.moveBorrowed");
  const plan = await a.moves.scheduler.plan(WS, B);
  const item = plan.items.find((x) => x.id === account);
  assert.equal(item?.cannot, moveBorrowed, "it cannot move, in words");
  const accounts = a.moves.modules.find((m) => m.id === "accounts")!;
  assert.equal(accounts.usableThere!(item!), false);
  assert.equal(accounts.canLend!(item!), false, "not this station's to lend");
  const all = await a.moves.scheduler.move(WS, B, { all: true });
  await quiet();
  assert.equal(all.failed, null, JSON.stringify(all));
  assert.deepEqual(all.failures ?? [], []);
  assert.deepEqual(all.refused.find((r) => r.item.id === account)?.why, moveBorrowed, "the login refused in its words");
  assert.ok(all.refused.some((r) => r.item.id === one.key && r.why.includes(moveBorrowed)), `the chat refused, naming why: ${JSON.stringify(all.refused)}`);
  assert.equal(a.rig.store.handedTo(one.key), null, "the chat here");
  assert.equal(a.rig.hub.chatHeld(one.key), null, "and going on");
  const alone = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
  assert.equal(alone.failed, null);
  assert.ok(alone.refused.some((r) => r.item.id === one.key && r.why.includes(moveBorrowed)), "with its needs: refused the same");
  const stopped = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, arriveStopped: true });
  await quiet();
  assert.equal(stopped.failed, null, JSON.stringify(stopped));
  assert.deepEqual(stopped.done, [{ module: "chats", id: one.key }]);
  assert.equal(a.rig.store.handedTo(one.key)?.station, B);
  assert.deepEqual(b.moves.scheduler.stopped().map((s) => [s.item.id, s.waitsFor.id]), [[one.key, account]], "there, stopped, waiting for the login");
  // C shares it with B too: B borrows it, the chat there goes on
  await c!.sharing.shareProfile("max", true, [A, B, C]);
  await quiet();
  assert.equal(ofShare(b, share)?.share.borrowed, true, "B borrows it now");
  assert.deepEqual(b.moves.scheduler.stopped(), [], "no longer stopped there");
  await takesTurn(b, one.key, b.rig.store.homeChat(one.key)!.id, "there now?", "it works there");
});

test("the other station killed in the first pass of a chat moved with its login that can be shared: the turn ends at once, the login hosted and usable here, nothing owed but telling it; started again, it keeps no copy", async () => {
  const { a, b, quiet } = world([MAX]);
  signIn(a, "max", CLAUDE_LOGIN);
  const one = await chatOn(a, "max");
  const two = await chatOn(a, "max");
  b.killAt = "handover.place";
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
  await quiet();
  assert.deepEqual((out.failures ?? []).map((f) => f.item.id), [one.key], JSON.stringify(out));
  assert.equal(out.lent, undefined, "nothing said lent: the lending was taken back in the same turn");
  assert.equal(present(a, "max").share, undefined, "the lending undone: this station's own, as it was");
  assert.equal(JSON.parse(readFileSync(join(a.rig.dir, "homes", "max", ".credentials.json"), "utf8")).claudeAiOauth.refreshToken, "r", "its login here");
  assert.deepEqual(lentShares(a), {}, "nothing kept lent");
  assert.equal(a.rig.store.handedTo(one.key), null, "the chat here");
  await takesTurn(a, two.key, two.thread, "still here?", "it works");
  // started again: told, it keeps no copy
  b.dead = false;
  b.killAt = undefined;
  await quiet();
  assert.equal(b.rig.raw.profiles.some((p: Json) => p.share?.host === A), false, "B keeps no copy");
});

test("share.borrow failing after the share was made: the share undone, the login here as it was and working, nothing kept, nothing stopped, the other told nothing", async () => {
  const { a, b, quiet } = world([MAX]);
  signIn(a, "max", CLAUDE_LOGIN);
  const one = await chatOn(a, "max");
  const two = await chatOn(a, "max");
  a.failBorrow = true;
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
  await quiet();
  assert.equal(out.failed?.item.id, `own:max@${A}`);
  // (the transport's error as it came: logged, said in the station's words)
  assert.equal(out.failed!.error, tr(stationLang(), "station.move.why.failedHere"));
  assert.deepEqual(present(a, "max"), MAX, "not shared, as it was");
  assert.equal(JSON.parse(readFileSync(join(a.rig.dir, "homes", "max", ".credentials.json"), "utf8")).claudeAiOauth.refreshToken, "r", "its login here");
  assert.deepEqual(keptShares(a), []);
  assert.deepEqual(lentShares(a), {}, "nothing kept lent");
  assert.deepEqual(a.moves.scheduler.stopped(), []);
  assert.equal(a.rig.hub.chatHeld(one.key), null);
  assert.equal(a.rig.hub.chatHeld(two.key), null);
  assert.equal(a.rig.store.handedTo(one.key), null, "the chat stayed");
  assert.deepEqual(b.rig.raw.profiles.map((p: Json) => p.id), ["bx"], "the other has nothing of it");
  await takesTurn(a, two.key, two.thread, "still here?", "it works");
  // and lent once it can be: as the first test has it
  a.failBorrow = false;
  const again = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
  await quiet();
  assert.equal(again.failed, null, JSON.stringify(again));
  assert.equal(shareOf(a, "max").borrowed, undefined, "hosted here");
  assert.equal(a.rig.store.handedTo(one.key)?.station, B);
});

test("a login asked for by name, share.take failing after the share made for its move: the share undone, the login here as it was, nothing kept, the other told nothing; asked again, its host moves", async () => {
  const { a, b, quiet } = world([MAX]);
  signIn(a, "max", CLAUDE_LOGIN);
  const one = await chatOn(a, "max");
  const account = `own:max@${A}`;
  a.failTake = true;
  const out = await a.moves.scheduler.move(WS, B, { module: "accounts", item: account });
  await quiet();
  assert.equal(out.failed?.item.id, account, JSON.stringify(out));
  assert.equal(out.failed!.error, tr(stationLang(), "station.move.why.failedHere"));
  assert.deepEqual(present(a, "max"), MAX, "not shared, as it was");
  assert.equal(JSON.parse(readFileSync(join(a.rig.dir, "homes", "max", ".credentials.json"), "utf8")).claudeAiOauth.refreshToken, "r", "its login here");
  assert.deepEqual(keptShares(a), [], "no share kept as made by a move");
  assert.deepEqual(b.rig.raw.profiles.map((p: Json) => p.id), ["bx"], "the other has nothing of it");
  assert.equal(a.rig.hub.chatHeld(one.key), null, "its chat goes on");
  a.failTake = false;
  const again = await a.moves.scheduler.move(WS, B, { module: "accounts", item: account });
  await quiet();
  assert.equal(again.failed, null, JSON.stringify(again));
  assert.equal(shareOf(a, "max").borrowed, true, "its host moved: borrowed here");
});

for (const [name, login, allow] of [["a login that cannot be shared (a Kimi sign-in)", KIMI, null], ["a login shared with stations this one is not among", MAX, [C]]] as const) {
  test(`${name}, moved away by the scheduler while another of its runtime is here: the chats that need it are stopped, stay on it, nothing said in them; back, they go on on it`, async () => {
    const { a, b, quiet } = world([login, SPARE], { third: true, slack: true });
    signIn(a, login.id, login === MAX ? CLAUDE_LOGIN : {});
    signIn(a, "spare", CLAUDE_LOGIN);
    if (allow !== null) {
      await a.sharing.shareProfile(login.id, true, [...allow]);
      await quiet();
    }
    const [k1, t1] = await newSession(a.rig.hub, { runtime: "claude", profile: login.id, createdBy: "p@x" });
    const first = message({ text: "<@UBOT> look" });
    await a.rig.accept(first, "cl");
    const k2 = sessionKey("cl", first.channel, first.threadTs);
    await a.rig.quiet();
    a.rig.store.setSessionProfile(k2, login.id, false);
    await a.rig.call(k2, "chat_state", { kind: "final" });
    a.rig.claude.last().complete();
    await quiet();
    const account = allow === null ? `own:${login.id}@${A}` : `share:${shareOf(a, login.id).id}`;
    const plan = await a.moves.scheduler.plan(WS, B);
    const item = plan.items.find((x) => x.id === account)!;
    assert.ok(item, JSON.stringify(plan.items.map((x) => x.id)));
    assert.equal(a.moves.modules.find((m) => m.id === "accounts")!.usableHere!(item), false, "not to be had here once it went");
    assert.deepEqual(sorted(item.wouldStop.map((n) => n.id)), sorted([k1, k2]));
    const posts = a.rig.chat.posts.length;
    const said = (t: number) => a.rig.store.entriesAfter(t, 0).length;
    const slackThread = a.rig.thread(first.channel, first.threadTs).id;
    const before = [said(t1.id), said(slackThread)];
    const out = await a.moves.scheduler.move(WS, B, { module: "accounts", item: account });
    await quiet();
    assert.equal(out.failed, null, JSON.stringify(out));
    assert.deepEqual(sorted(out.stopped.map((s) => s.item.id)), sorted([k1, k2]));
    assert.equal(profile(a, login.id), undefined, "gone from here");
    for (const k of [k1, k2]) {
      assert.match(a.rig.hub.chatHeld(k) ?? "", new RegExp(`waits for accounts ${account}`));
      assert.equal(a.rig.session(k).profile, login.id, `${k} stays on it, not switched to another`);
    }
    assert.equal(a.rig.chat.posts.length, posts, "nothing posted in the Slack thread");
    assert.deepEqual([said(t1.id), said(slackThread)], before, "nothing said in either chat");
    const back = await a.moves.scheduler.back(WS, B, { module: "accounts", item: account });
    await quiet();
    assert.equal(back.failed, null, JSON.stringify(back));
    assert.deepEqual(sorted(back.resumed.map((n) => n.id)), sorted([k1, k2]));
    assert.ok(profile(a, login.id) !== undefined, "here again under its id");
    assert.equal(a.rig.hub.chatHeld(k1), null);
    assert.equal(a.rig.chat.posts.length, posts, "still nothing posted");
    const session = await takesTurn(a, k1, t1.id, "and now?", "it goes on");
    assert.equal(session.options.profile.id, login.id, "on it");
    assert.equal(a.rig.session(k1).profile, login.id);
  });
}

test("a chat stopped by a move says so once, as a person speaks in it, never by itself: what it waits for and where, the two ways out, what was said kept and handed when it goes on; no turn starts meanwhile; brought back alone while its login stays there, it says so where it arrived", async () => {
  const { a, b, quiet } = world([KIMI]);
  signIn(a, "kimi", {});
  const one = await chatOn(a, "kimi");
  const account = `own:kimi@${A}`;
  // (what the station said in a chat, and what was handed to its agents)
  const stationSaid = (st: Station, thread: number) => (st.rig.store.db.prepare("SELECT text FROM entries WHERE thread = ? AND author_kind = 'station' ORDER BY n").all(thread) as { text: string }[]).map((r) => r.text);
  const handed = (st: Station) => st.rig.claude.sessions.flatMap((s) => s.prompts).join("\n");
  const said0 = stationSaid(a, one.thread).length;
  // Its login moved away: the chat stopped here, nothing said by that.
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "accounts", item: account })).failed, null);
  await quiet();
  assert.notEqual(a.rig.hub.chatHeld(one.key), null, "stopped");
  assert.equal(stationSaid(a, one.thread).length, said0, "nobody spoke: nothing said");
  // (the station's own hold let go of meanwhile wakes every chat: this one, nobody having spoken, says nothing by that)
  a.rig.hub.hold("drain");
  a.rig.hub.release("drain");
  await quiet();
  assert.equal(stationSaid(a, one.thread).length, said0, "woken with nobody having spoken: nothing said");
  // A person speaks twice: said once, in the station's words; no turn starts.
  const before = handed(a);
  say(a.rig.hub, one.thread, "p@x", "are you there?");
  await quiet();
  say(a.rig.hub, one.thread, "p@x", "and now?");
  await quiet();
  const told = stationSaid(a, one.thread).slice(said0);
  assert.equal(told.length, 1, `said once: ${JSON.stringify(told)}`);
  assert.match(told[0]!, /Kimi/, "names what it waits for");
  assert.match(told[0]!, /「A」/, "names where it is stopped");
  assert.match(told[0]!, /「B」/, "names where that is");
  assert.match(told[0]!, /station_move/, "says how to go on");
  assert.equal(handed(a), before, "no turn meanwhile, nothing handed: its notice wakes no agent");
  // Its login back: it goes on, given both.
  assert.equal((await a.moves.scheduler.back(WS, B, { module: "accounts", item: account })).failed, null);
  await quiet();
  const now = handed(a).slice(before.length);
  assert.ok(now.includes("are you there?") && now.includes("and now?"), `both handed once it goes on: ${now}`);
  assert.equal(stationSaid(a, one.thread).length, said0 + 1, "not said again");
  await endTurn(a, one.key);
  // There with its login, then back alone, its login staying there: it arrives stopped, and says so as it is spoken to.
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true })).failed, null);
  await quiet();
  const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: one.key });
  await quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.deepEqual(back.stopped.map((s) => s.item.id), [one.key], "arrived stopped, waiting for its login there");
  const here = handed(a);
  const said1 = stationSaid(a, one.thread).length;
  say(a.rig.hub, one.thread, "p@x", "back here?");
  await quiet();
  const told2 = stationSaid(a, one.thread).slice(said1);
  assert.equal(told2.length, 1, `said once where it arrived: ${JSON.stringify(told2)}`);
  assert.match(told2[0]!, /「B」/, "names where its login is");
  assert.equal(handed(a), here, "no turn starts while it waits");
  void b;
});

test("a login that cannot be shared moved alone: the chat on it stopped stays stopped though the other station is heard from before the login has left, and is so after: waiting for it there", async () => {
  const { a, quiet } = world([KIMI]);
  signIn(a, "kimi", {});
  const one = await chatOn(a, "kimi");
  const account = `own:kimi@${A}`;
  // (the other station heard from right as the chat is held for its login's leaving, the login still here: what is
  // stopped settled then, as a request of B's heard then settles it, move/station.ts `heard`)
  const hold = a.rig.hub.holdChat.bind(a.rig.hub);
  let settled: unknown[] | null = null;
  a.rig.hub.holdChat = async (k: string, why: string, notice?: () => string) => {
    await hold(k, why, notice);
    if (k === one.key && settled === null) settled = await a.moves.scheduler.settleStopped(B);
  };
  const out = await a.moves.scheduler.move(WS, B, { module: "accounts", item: account });
  await quiet();
  a.rig.hub.holdChat = hold;
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.deepEqual(settled, [], "nothing let go while its login was leaving");
  assert.deepEqual(a.moves.scheduler.stopped().map((x) => [x.item.module, x.item.id, x.waitsFor.module, x.waitsFor.id, (x.waitsFor as Json).at]), [["chats", one.key, "accounts", account, B]], "stopped, waiting for its login there");
  assert.notEqual(a.rig.hub.chatHeld(one.key), null, "held");
});

test("a chat stopped by a move and archived by hand: a person's word to it is refused as it is today, nothing said by the stop and the archive as it was", async () => {
  const { a, quiet } = world([KIMI]);
  signIn(a, "kimi", {});
  const one = await chatOn(a, "kimi");
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "accounts", item: `own:kimi@${A}` })).failed, null);
  await quiet();
  a.rig.store.setArchived(one.key, true, "manual");
  const archived = a.rig.store.getSession(one.key)!.archivedAt;
  const stationSaid = () => (a.rig.store.db.prepare("SELECT COUNT(*) AS n FROM entries WHERE thread = ? AND author_kind = 'station'").get(one.thread) as { n: number }).n;
  const said = stationSaid();
  assert.throws(() => say(a.rig.hub, one.thread, "p@x", "still?"), /手动归档|archived/, "refused, as a chat archived by hand refuses a message");
  await quiet();
  assert.equal(a.rig.store.getSession(one.key)!.archivedAt, archived, "still archived");
  assert.equal(stationSaid(), said, "nothing said");
});

test("a chat stopped here for its login, then moved itself, then back alone while its login stays there: held as it arrives (its stop anew, waiting for the login where it is now), says so once as it is spoken to, starts no turn; the login back lets it go", async () => {
  const { a, b, quiet } = world([KIMI]);
  signIn(a, "kimi", {});
  const one = await chatOn(a, "kimi");
  const account = `own:kimi@${A}`;
  const handed = (st: Station) => st.rig.claude.sessions.flatMap((s) => s.prompts).join("\n");
  const stationSaid = (st: Station, thread: number) => (st.rig.store.db.prepare("SELECT COUNT(*) AS n FROM entries WHERE thread = ? AND author_kind = 'station'").get(thread) as { n: number }).n;
  // Its login away: stopped here.
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "accounts", item: account })).failed, null);
  await quiet();
  assert.deepEqual(a.moves.scheduler.stopped().map((s) => s.item.id), [one.key]);
  // It follows its login there, by the hand-over itself (as any route other than this station's own turn takes it):
  // no longer stopped here.
  await a.moves.handover.handOver(one.key, B, { wait: true });
  await quiet();
  assert.deepEqual(a.moves.scheduler.stopped(), [], "nothing of it kept stopped here once it went");
  // (as a station from before this left it: its entry kept, nothing held)
  await a.moves.scheduler.noteStopped({ module: "chats", id: one.key }, { module: "accounts", id: account }, WS, false);
  // Back alone, its login staying there: held as it arrives, waiting for the login where it is now.
  const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: one.key });
  await quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.match(a.rig.hub.chatHeld(one.key) ?? "", /^stopped: waits for accounts/, "held");
  assert.deepEqual(a.moves.scheduler.stopped().map((s) => [s.item.id, (s.waitsFor as { at?: string }).at]), [[one.key, B]], "kept stopped, waiting for the login on B");
  // (the move page has its row at once: stopped, waiting for the login, which is on B)
  const view = moveView(await a.moves.scheduler.plan(WS, B), a.moves.modules.map((m) => m.id), a.moves.scheduler.stopped(), { limit: 50 }, null, false, (id) => id.slice(0, 1).toUpperCase());
  const row = view.modules.find((m: Json) => m.id === "chats").items.find((x: Json) => x.id === one.key);
  assert.deepEqual(row === undefined ? null : [row.state, row.waitsFor, row.waitsAt], ["stopped", `accounts ${account}`, "B"], "its row on the move page");
  const before = handed(a);
  const said = stationSaid(a, one.thread);
  say(a.rig.hub, one.thread, "p@x", "back here?");
  await quiet();
  assert.equal(stationSaid(a, one.thread), said + 1, "said once");
  assert.equal(handed(a), before, "no turn");
  // The login back: it goes on, handed what was said.
  assert.equal((await a.moves.scheduler.back(WS, B, { module: "accounts", item: account })).failed, null);
  await quiet();
  assert.ok(handed(a).slice(before.length).includes("back here?"), "handed once it goes on");
  void b;
});

test("a chat moved with its login that cannot be shared in one turn, then brought back alone by a move back asked here: the moment that turn ends its row says stopped, waiting for the login on the other, handed to nowhere", async () => {
  for (const how of ["shown", "word lost", "never told again"]) {
  const lost = how !== "shown";
  const { t, a, b, quiet } = world([KIMI]);
  signIn(a, "kimi", {});
  const one = await chatOn(a, "kimi");
  const account = `own:kimi@${A}`;
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
  await quiet();
  assert.deepEqual(out.done, [{ module: "accounts", id: account }, { module: "chats", id: one.key }], JSON.stringify(out));
  assert.equal(a.rig.store.handedTo(one.key)?.station, B, "handed to B");
  const row = async () => {
    const view = moveView(await a.moves.scheduler.plan(WS, B), a.moves.modules.map((m) => m.id), a.moves.scheduler.stopped(), { limit: 50 }, null, false, (id) => id.slice(0, 1).toUpperCase());
    const r = view.modules.find((m: Json) => m.id === "chats").items.find((x: Json) => x.id === one.key);
    return r === undefined ? null : [r.state, r.waitsFor ?? r.waits, r.waitsAt];
  };
  // (the page read while it is on B, as a device had it: its pages read and kept as `handedTo` keeps them)
  assert.equal((await row())?.[0], "there", "there while on B");
  // (a person's word to it on B while it is handed back is caught up after it is shown here)
  const held = Promise.withResolvers<void>();
  const hold = b.rig.hub.holdChat.bind(b.rig.hub);
  b.rig.hub.holdChat = async (k: string, why: string, notice?: () => string) => {
    await hold(k, why, notice);
    if (k === one.key && why.startsWith("moving")) {
      const thread = b.rig.store.homeChat(one.key)!.id;
      say(b.rig.hub, thread, "p@x", "said while it went back");
      held.resolve();
    }
  };
  // (lost: B's first word to A that the chat is there to show is lost on the way, as on a connection that drops)
  const ask = b.bus.ask.bind(b.bus);
  let losing = lost;
  const lostIt = Promise.withResolvers<void>();
  let cut = false;
  b.bus.ask = ((s: string, r: Json) => (cut ? Promise.reject(new Error("station unreachable")) : losing && r?.method === "handover.show" ? ((losing = false), lostIt.resolve(), Promise.reject(new Error("the answer was lost on the way"))) : ask(s, r))) as typeof b.bus.ask;
  let ended = false;
  const backing = a.moves.scheduler.back(WS, B, { module: "chats", item: one.key }).finally(() => (ended = true));
  if (lost) {
    // (B went on, its word lost, to tell it again by its retry: the turn here does not end, the chat moving, till then)
    await lostIt.promise;
    await settle();
    assert.equal(ended, false, "the turn does not end before the chat it brings is shown here");
    assert.deepEqual(await row(), ["moving", "station", "B"], "moving till it is shown here: waiting for B to go on with it");
    if (how === "never told again") {
      // (B gone from then on: the move back waits no longer than its bound, and says the chat is on its way)
      cut = true;
      await t.adjust(ARRIVE_WAIT_MS);
      await settle();
      assert.equal(ended, true, "the move back ended within its bound");
      const back = await backing;
      assert.match((back.failures ?? [])[0]?.error ?? "", /on its way here from B, which does not answer|正在从「B」迁回这里/, JSON.stringify(back));
      assert.deepEqual(await row(), ["moving", "station", "B"], "still on its way, waiting for B");
      continue;
    }
    b.moves.handover.reached(A);
  }
  const back = await backing;
  if (!lost) await held.promise;
  // (the moment the turn's end is told, nothing waited for after)
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.equal(a.rig.store.handedTo(one.key), null, `handed to nowhere: it is here (${how})`);
  assert.deepEqual(await row(), ["stopped", `accounts ${account}`, "B"], `its row: stopped, waiting for the login on B (lost ${lost})`);
  await quiet();
  assert.deepEqual(await row(), ["stopped", `accounts ${account}`, "B"], "and so after");
  assert.match(a.rig.hub.chatHeld(one.key) ?? "", /^stopped: waits for accounts/, "held");
  // (moved again, by the row's own move with what it needs, its login there: it goes, and is stopped here no more)
  const again = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
  await quiet();
  assert.equal(again.failed, null, JSON.stringify(again));
  assert.equal(a.rig.store.handedTo(one.key)?.station, B, `handed to B (${how})`);
  assert.deepEqual(a.moves.scheduler.stopped().filter((s) => s.item.id === one.key), [], `nothing kept stopped of it here (${how})`);
  assert.deepEqual(await row(), ["there", undefined, undefined], `its row: there (${how})`);
  }
});

test("two chats on one login that cannot be shared, moved with what they need, one going and one failing: the login stays there for the one that went, which works there; the failed one stays here stopped waiting for it and says so when spoken to; nothing brought back", async () => {
  const { a, b, quiet } = world([KIMI]);
  signIn(a, "kimi", {});
  const one = await chatOn(a, "kimi");
  const two = await chatOn(a, "kimi");
  const account = `own:kimi@${A}`;
  const handle = b.bus.handle.bind(b.bus);
  b.bus.handle = ((ws: string, peer: string, request: Json) => request?.method === "handover.begin" && Array.isArray(request.keys) && request.keys.includes(two.key) ? Promise.reject(new Error("not taken there")) : handle(ws, peer, request)) as typeof b.bus.handle;
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", withNeeds: true });
  await quiet();
  assert.deepEqual((out.failures ?? []).map((f) => f.item.id), [two.key], "the failed one named");
  assert.deepEqual(out.returned ?? [], [], "nothing brought back: the one that went needs it");
  assert.ok(out.done.some((d) => d.id === one.key) && out.done.some((d) => d.id === account), JSON.stringify(out.done));
  assert.ok(b.rig.raw.profiles.some((p: Json) => p.id === "kimi") && !a.rig.raw.profiles.some((p: Json) => p.id === "kimi"), "the login there");
  assert.equal(b.rig.store.getSession(one.key)?.ws, null, "the one that went is there");
  assert.equal(b.rig.hub.chatHeld(one.key), null, "and works there");
  assert.match(a.rig.hub.chatHeld(two.key) ?? "", /^stopped: /, "the failed one stopped here, waiting for its login");
  const said = (a.rig.store.db.prepare("SELECT COUNT(*) AS n FROM entries WHERE thread = ? AND author_kind = 'station'").get(two.thread) as { n: number }).n;
  say(a.rig.hub, two.thread, "p@x", "and me?");
  await quiet();
  assert.equal((a.rig.store.db.prepare("SELECT COUNT(*) AS n FROM entries WHERE thread = ? AND author_kind = 'station'").get(two.thread) as { n: number }).n, said + 1, "says so when spoken to");
});

/// What one chat's trip costs on A (move/bounded.ts: bytes written under move/ by file, rows read by table, what is
/// stopped looked at), A keeping besides `n` other items of the same kind (`others`, written as A keeps them before A's
/// moves start again over them).
async function tripWith(n: number, kind: "lent" | "stopped"): Promise<Cost & { stopped: number }> {
  const { a, b, quiet } = world([kind === "lent" ? MAX : KIMI]);
  const pid = kind === "lent" ? "max" : "kimi";
  signIn(a, pid, kind === "lent" ? CLAUDE_LOGIN : {});
  // (the lent login's first chat; the other kind's one chat alone on its login: moving that login with it stops nothing)
  const one = kind === "lent" ? await chatOn(a, pid) : null;
  const two = await chatOn(a, pid);
  const account = `own:${pid}@${A}`;
  const log = join(a.rig.dir, "move", kind === "lent" ? "accounts-lent.log" : "stopped.log");
  mkdirSync(join(a.rig.dir, "move"), { recursive: true });
  if (kind === "lent") {
    // (its login lent for a chat moved with what it needs, then for `n` other chats there: the lines kept so)
    assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: one!.key, withNeeds: true })).failed, null);
    await quiet();
    const share = shareOf(a, pid).id as string;
    appendFileSync(log, Array.from({ length: n }, (_, i) => `${JSON.stringify({ k: `f:${share}\nchats other-${i}`, v: share })}\n`).join(""));
  } else {
    // (n other chats stopped here, waiting for another login at B, as the chats of one login moved away wait)
    appendFileSync(log, Array.from({ length: n }, (_, i) => `${JSON.stringify({ k: `chats other-${i}`, v: { item: { module: "chats", id: `other-${i}` }, waitsFor: { module: "accounts", id: `own:other@${A}`, at: B }, ws: WS } })}\n`).join(""));
  }
  await a.moves.close();
  a.moves = a.make();
  await a.moves.start();
  await quiet();
  const looked0 = a.moves.scheduler.stoppedLooked();
  const trip = counting(join(a.rig.dir, "move"), [a.moves.scheduler, b.moves.scheduler]);
  if (kind === "lent") {
    // The chat it was lent for back (taken off what the login is lent for, the login still lent for the others).
    const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: one!.key });
    await quiet();
    assert.equal(back.failed, null, JSON.stringify(back));
    void two;
  } else {
    // A chat there with its login, back alone: it arrives stopped, waiting for its login there; the login back: it goes on.
    const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: two.key, withNeeds: true });
    await quiet();
    assert.deepEqual([out.failed, out.refused], [null, []], JSON.stringify(out));
    const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: two.key });
    await quiet();
    assert.deepEqual(back.stopped.map((x) => x.item.id), [two.key], "arrived stopped");
    assert.equal((await a.moves.scheduler.back(WS, B, { module: "accounts", item: account })).failed, null);
    await quiet();
    assert.equal(a.rig.hub.chatHeld(two.key), null, "it goes on");
  }
  const cost = trip.stop();
  return { ...cost, stopped: a.moves.scheduler.stoppedLooked() - looked0 };
}

for (const kind of ["lent", "stopped"] as const) {
  test(`a chat's trip ${kind === "lent" ? "on a login lent for it" : "that arrives stopped and goes on"} writes and reads the same with 30 and 300 others ${kind === "lent" ? "it is lent for" : "stopped"}: what is kept of them is a line each, found by the item`, async () => {
    const few = await tripWith(30, kind);
    const many = await tripWith(300, kind);
    assert.ok((few.bytes[kind === "lent" ? "accounts-lent.log" : "stopped.log"] ?? 0) > 0, `its own written: ${JSON.stringify(few)}`);
    assert.deepEqual(many, few, `with 30: ${JSON.stringify(few)}, with 300: ${JSON.stringify(many)}`);
  });
}
