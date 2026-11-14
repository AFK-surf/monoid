// The accounts module of a migration (move/accounts.ts) over the real sharing of logins (share/index.ts) on two
// stations, through the real scheduler and the chats' hand-over (move/station.ts): an own login that can be shared is
// shared as it moves, with the two stations alone, so the station it leaves borrows it under the same profile id and
// the chats still there go on, none stopped; moved back, the share it made is undone (not where a person opened it to a
// third station meanwhile), across a start too; one shared before stays shared; one that cannot be shared moves as it
// is and stops what needs it; a failure after the share was made undoes it, the login here as it was. Stations are
// Rigs (hub-fakes.ts) with their moves and their sharing, over a transport of the test's.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, test } from "node:test";
import { Cloud } from "../src/cloud/state.ts";
import { PeerBus, bytesOf, withBytes } from "../src/mesh/bus.ts";
import type { ConfigFile } from "../src/ops/config.ts";
import { Fibers } from "../src/ops/fibers.ts";
import { gather, place } from "../src/replica/carry-worker.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { newSession, say } from "../src/sessions/lifecycle.ts";
import { Moves } from "../src/move/station.ts";
import { moveView } from "../src/move/routes.ts";
import { shareRefusal, Sharing } from "../src/share/index.ts";
import { Rig, message, testClock } from "./hub-fakes.ts";
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
  /// The next `move.accounts` this station asks goes unanswered (the other not reached).
  failAccounts: boolean;
  make(): Moves;
};

const open: (() => Promise<void>)[] = [];
afterEach(async () => {
  for (const c of open.splice(0).reverse()) await c().catch(() => {});
});

/// A second Claude Code login of A's, of the same runtime: where a chat would be switched to.
const SPARE = { id: "spare", name: "Spare", runtime: "claude", access: { kind: "subscription" }, home: "homes/spare", env: {} };

/// Stations A and B of workspace "ws" (and C, listed but never up, where asked); A has `profiles`, its login's files;
/// `slack`: A has the Slack connect cl (its fake chat `rig.chat`).
function world(profiles: Json[], o: { third?: boolean; slack?: boolean } = {}) {
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
    const st = { id, rig, failTake: false, failAccounts: false } as unknown as Station;
    rig.raw.connects = o.slack && id === A ? [{ id: "cl", slack: { botName: "Claude bot" }, bind: { runtime: "claude" } }] : [];
    rig.raw.profiles = id === A ? structuredClone(profiles) : [{ id: "bx", runtime: "codex", home: "homes/bx", env: { OPENAI_API_KEY: "k" } }];
    Object.defineProperty(rig, "config", { get: () => hubConfig(rig.raw, rig.dir), configurable: true });
    // (config.json as the sharing changes it, told to who listens: ops/config.ts)
    const listeners = new Set<(raw: Json) => void>();
    const config = {
      raw: () => rig.raw,
      update: (f: (raw: Json) => void) => {
        f(rig.raw);
        for (const l of listeners) l(rig.raw);
      },
      listen: (l: (raw: Json) => void) => (listeners.add(l), () => listeners.delete(l)),
    } as unknown as ConfigFile;
    st.sharing = new Sharing({
      data: rig.dir, config, cloud: cloudFor(id),
      ask: async (to, ws, request) => {
        if (st.failTake && request?.method === "share.take") throw new Error("the answer was lost on the way");
        const there = stations.get(to);
        if (there === undefined) throw new Error("station unreachable");
        return across(await there.sharing.handle(id, across(request), ws ?? WS));
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
      if (there === undefined) throw new Error("station unreachable");
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
        shareMoves: { move: (pid, to, made) => st.sharing.moveProfile(pid, to, undefined, made), unshare: (share, stations) => st.sharing.unshareMoved(share, stations) },
        sessionsIn: (ws, after, limit) => rig.store.sessionPageOfWs(ws === WS ? null : ws, WS, after, limit),
        reposDir: join(rig.dir, "repos"),
        room: async () => ({ free: 1e15 }),
        hasGit: async () => true,
        lackMost: 50,
        work: {
          gather: async (dataDir, db, ws, home, scratch, _signal, agent, keys) => gather(dataDir, db, ws, home, scratch, agent ?? null, keys ?? null),
          place: async (dataDir, index, from, made, aside, placed, projects) => place(dataDir, index, from, made ?? null, aside ?? null, placed ?? null, projects ?? false),
        },
        hold: () => () => {},
      });
      st.bus.on("handover.", moves.answers(() => true));
      st.bus.on("move.", moves.answers(() => true));
      return moves;
    };
    st.moves = st.make();
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
  return { t, a, b, quiet };
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
  const [key, thread] = newSession(st.rig.hub, { runtime: "claude", profile: pid, createdBy: "p@x" });
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
/// (a list in order; what is no list as it is, for the assertion to say)
const sorted = (xs: unknown) => (Array.isArray(xs) ? [...xs].sort() : xs);

test("an own Claude login of three chats, one chat moved with its needs: the login hosted there, borrowed here under the same id, allowed to the two stations alone; the other two chats go on, none stopped", async () => {
  const { a, b, quiet } = world([MAX]);
  signIn(a, "max", CLAUDE_LOGIN);
  const one = await chatOn(a, "max");
  const two = await chatOn(a, "max");
  const three = await chatOn(a, "max");
  const account = `own:max@${A}`;
  const plan = await a.moves.scheduler.plan(WS, B);
  const item = plan.items.find((x) => x.id === account)!;
  assert.ok(item, JSON.stringify(plan.items.map((x) => x.id)));
  assert.equal(a.moves.modules.find((m) => m.id === "accounts")!.usableHere!(item), true, "borrowed here once it moved");
  assert.deepEqual(item.wouldStop, [], "the plan says it stops nothing");
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
  await quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.deepEqual(out.done, [{ module: "accounts", id: account }, { module: "chats", id: one.key }]);
  assert.deepEqual(out.stopped, []);
  assert.deepEqual(a.moves.scheduler.last(WS)!.stopped, []);
  assert.deepEqual(a.moves.scheduler.stopped(), []);
  assert.equal(a.rig.hub.chatHeld(two.key), null);
  assert.equal(a.rig.hub.chatHeld(three.key), null);
  assert.equal(a.rig.store.handedTo(one.key)?.station, B, "the chat went");
  // hosted there, its id kept, allowed to the two stations alone
  const here = present(a, "max");
  const share = here.share.id as string;
  assert.deepEqual(here.share, { id: share, borrowed: true, host: B, email: "max@x", workspaces: [WS] }, "borrowed here under the same profile id");
  const hosted = ofShare(b, share);
  assert.ok(hosted !== undefined, "B has it");
  assert.equal(hosted.id, "max", "its id kept there");
  assert.equal(hosted.share.borrowed, undefined);
  assert.deepEqual(sorted(hosted.share.allow), sorted([A, B]), "the two stations alone, never every station");
  assert.equal(JSON.parse(readFileSync(join(b.rig.dir, "homes", "max", ".credentials.json"), "utf8")).claudeAiOauth.refreshToken, "r");
  assert.equal(existsSync(join(a.rig.dir, "homes", "max", ".credentials.json")), false, "one station alone holds the login");
  assert.equal((await a.sharing.lendClaude(here)).token, `token-of-max@b`, "lent here by its host");
  assert.deepEqual(keptShares(a), [share], "kept as made by this move");
  // the chats here go on, nothing said in them
  await takesTurn(a, two.key, two.thread, "and now?", "a turn as ever");
  assert.ok(!a.rig.store.entriesAfter(three.thread, 0).some((e) => /moved|stopped/i.test(e.text ?? "")), "nothing said");
  // known by its share now, on either station, there
  const after = await a.moves.scheduler.plan(WS, B);
  assert.equal(after.items.find((x) => x.id === `share:${share}`)?.state, "there");
  assert.equal(after.items.some((x) => x.id === account), false);
  assert.ok(after.items.find((x) => x.id === two.key)!.needs.some((n) => n.id === `share:${share}`));
  assert.ok((await b.moves.scheduler.plan(WS, A)).items.some((x) => x.id === `share:${share}`));
});

test("moved back: the login is this station's own again, not shared, the other keeps no profile of it, nothing kept; started again between, the same", async () => {
  for (const restart of [false, true]) {
    const { a, b, quiet } = world([MAX]);
    signIn(a, "max", CLAUDE_LOGIN);
    const one = await chatOn(a, "max");
    await chatOn(a, "max");
    await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
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
  await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
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
    await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
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
  assert.match(out.refused[0]!.why, /^it needs accounts own:max@a{64} \(.+\) there, which cannot go: the other station did not answer what it has of it \(the station was not reached\): ask again$/);
  assert.equal(present(a, "max").share, undefined, "not shared");
  assert.equal(JSON.parse(readFileSync(join(a.rig.dir, "homes", "max", ".credentials.json"), "utf8")).claudeAiOauth.refreshToken, "r", "its login here");
  assert.equal(b.rig.raw.profiles.some((p: Json) => p.id === "max"), false, "nothing of it there");
  assert.equal(a.rig.store.handedTo(one.key), null, "the chat here");
  assert.equal(a.rig.hub.chatHeld(one.key), null, "not stopped");
  assert.deepEqual(keptShares(a), []);
  const again = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
  await quiet();
  assert.equal(again.failed, null, JSON.stringify(again));
  assert.deepEqual(again.done, [{ module: "accounts", id: account }, { module: "chats", id: one.key }]);
  assert.equal(a.rig.store.handedTo(one.key)?.station, B, "the chat went");
});

test("a login that cannot be shared (a Kimi sign-in) moves as it is: gone from here, what needs it here stopped first", async () => {
  const { a, b, quiet } = world([KIMI]);
  assert.notEqual(shareRefusal(KIMI), null);
  signIn(a, "kimi", {});
  const [k1] = newSession(a.rig.hub, { runtime: "claude", profile: "kimi", createdBy: "p@x" });
  const [k2] = newSession(a.rig.hub, { runtime: "claude", profile: "kimi", createdBy: "p@x" });
  await quiet();
  const account = `own:kimi@${A}`;
  const plan = await a.moves.scheduler.plan(WS, B);
  const item = plan.items.find((x) => x.id === account)!;
  assert.equal(a.moves.modules.find((m) => m.id === "accounts")!.usableHere!(item), false);
  assert.deepEqual(sorted(item.wouldStop.map((n) => n.id)), sorted([k1, k2]));
  const out = await a.moves.scheduler.move(WS, B, { module: "accounts", item: account });
  await quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.deepEqual(sorted(out.stopped.map((s) => s.item.id)), sorted([k1, k2]));
  assert.match(a.rig.hub.chatHeld(k1) ?? "", /waits for accounts own:kimi@/);
  assert.equal(profile(a, "kimi"), undefined, "gone from here");
  assert.equal(profile(b, "kimi")?.share, undefined, "the other's own, not shared");
  assert.deepEqual(keptShares(a), []);
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
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
  await quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.deepEqual(out.done, [{ module: "accounts", id: `share:${share}` }, { module: "chats", id: one.key }]);
  assert.deepEqual(a.moves.scheduler.stopped(), []);
  assert.equal(a.rig.hub.chatHeld(two.key), null);
  assert.equal(shareOf(a, "max").borrowed, true, "borrowed here");
  assert.deepEqual(sorted(ofShare(b, share)?.share.allow), sorted([A, C]), "who may use it as a person had it");
  assert.deepEqual(keptShares(a), [], "not made by the move");
  const back = await a.moves.scheduler.back(WS, B, { module: "accounts", item: `share:${share}`, withNeeds: true });
  await quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.deepEqual(shareOf(a, "max"), { id: share, allow: [A, C] }, "still shared, hosted here");
  assert.equal(ofShare(b, share), undefined, "the other, not allowed, keeps no copy");
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

test("share.take failing after the share was made: the share undone, the login here as it was and working, nothing kept, nothing stopped, the other told nothing", async () => {
  const { a, b, quiet } = world([MAX]);
  signIn(a, "max", CLAUDE_LOGIN);
  const one = await chatOn(a, "max");
  const two = await chatOn(a, "max");
  a.failTake = true;
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
  await quiet();
  assert.equal(out.failed?.item.id, `own:max@${A}`);
  assert.match(out.failed!.error, /lost on the way/);
  assert.deepEqual(present(a, "max"), MAX, "not shared, as it was");
  assert.equal(JSON.parse(readFileSync(join(a.rig.dir, "homes", "max", ".credentials.json"), "utf8")).claudeAiOauth.refreshToken, "r", "its login here");
  assert.deepEqual(keptShares(a), []);
  assert.deepEqual(a.moves.scheduler.stopped(), []);
  assert.equal(a.rig.hub.chatHeld(one.key), null);
  assert.equal(a.rig.hub.chatHeld(two.key), null);
  assert.equal(a.rig.store.handedTo(one.key), null, "the chat stayed");
  assert.deepEqual(b.rig.raw.profiles.map((p: Json) => p.id), ["bx"], "the other has nothing of it");
  await takesTurn(a, two.key, two.thread, "still here?", "it works");
  // and moved once it can be: as the first test has it
  a.failTake = false;
  const again = await a.moves.scheduler.move(WS, B, { module: "chats", item: one.key, withNeeds: true });
  await quiet();
  assert.equal(again.failed, null, JSON.stringify(again));
  assert.equal(shareOf(a, "max").borrowed, true);
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
    const [k1, t1] = newSession(a.rig.hub, { runtime: "claude", profile: login.id, createdBy: "p@x" });
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
  const stationSaid = (st: Station, thread: number) => (st.rig.store.db.prepare("SELECT text FROM entries WHERE thread = ? AND author_kind = 'ember' ORDER BY n").all(thread) as { text: string }[]).map((r) => r.text);
  const handed = (st: Station) => st.rig.claude.sessions.flatMap((s) => s.prompts).join("\n");
  const said0 = stationSaid(a, one.thread).length;
  // Its login moved away: the chat stopped here, nothing said by that.
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "accounts", item: account })).failed, null);
  await quiet();
  assert.notEqual(a.rig.hub.chatHeld(one.key), null, "stopped");
  assert.equal(stationSaid(a, one.thread).length, said0, "nobody spoke: nothing said");
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

test("a chat stopped by a move and archived by hand: a person's word to it is refused as it is today, nothing said by the stop and the archive as it was", async () => {
  const { a, quiet } = world([KIMI]);
  signIn(a, "kimi", {});
  const one = await chatOn(a, "kimi");
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "accounts", item: `own:kimi@${A}` })).failed, null);
  await quiet();
  a.rig.store.setArchived(one.key, true, "manual");
  const archived = a.rig.store.getSession(one.key)!.archivedAt;
  const stationSaid = () => (a.rig.store.db.prepare("SELECT COUNT(*) AS n FROM entries WHERE thread = ? AND author_kind = 'ember'").get(one.thread) as { n: number }).n;
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
  const stationSaid = (st: Station, thread: number) => (st.rig.store.db.prepare("SELECT COUNT(*) AS n FROM entries WHERE thread = ? AND author_kind = 'ember'").get(thread) as { n: number }).n;
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
  const said = (a.rig.store.db.prepare("SELECT COUNT(*) AS n FROM entries WHERE thread = ? AND author_kind = 'ember'").get(two.thread) as { n: number }).n;
  say(a.rig.hub, two.thread, "p@x", "and me?");
  await quiet();
  assert.equal((a.rig.store.db.prepare("SELECT COUNT(*) AS n FROM entries WHERE thread = ? AND author_kind = 'ember'").get(two.thread) as { n: number }).n, said + 1, "says so when spoken to");
});
