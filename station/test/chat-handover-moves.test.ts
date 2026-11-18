// What a migration moves with a chat and in what order (move/): a whole station chat by chat, a failed item stopping only
// what needs it, the other station gone in a turn, a chat arriving stopped, accounts that cannot be borrowed, connects,
// repositories, settings and secrets, moves stopped, the self-update held. Split from chat-handover.test.ts by subject;
// its stations are move-world.ts's.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { newSession, say } from "../src/sessions/lifecycle.ts";
import { Moves } from "../src/move/station.ts";
import { MoveAsks } from "../src/tools/move.ts";
import { plainStore } from "../src/vault/plain.ts";
import { given, message } from "./hub-fakes.ts";
import { PeerGone, PeerStopped } from "../src/mesh/peer.ts";
import { Refused } from "../src/mesh/bus.ts";
import { stationLang, tr } from "../src/ops/i18n.ts";
import { hearLines } from "../src/ops/log.ts";
import { PREVIOUS_LIMIT_MS } from "../src/ops/previous.ts";
import { WS, A, B, C, type Station, world, endTurn, stillfailChat, gitEnv, homeThread, entries, retiredCopy } from "./move-world.ts";

type Json = any;

test("a whole station handed over chat by chat: one whose account cannot go is listed with why, the others go", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const one = await stillfailChat(a);
  const two = await stillfailChat(a);
  const [mine] = await newSession(a.rig.hub, { runtime: "claude", profile: "mine", createdBy: "p@x" });
  const out = await a.moves.scheduler.move(WS, B, { all: true, follow: ["jobs"] });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out.failed));
  assert.ok(out.done.some((d) => d.id === one.key) && out.done.some((d) => d.id === two.key));
  const refused = out.refused.find((r) => r.item.id === mine);
  assert.match(refused?.why ?? "", /(needs account “|需要账号「)mine/);
  assert.match(out.refused.find((r) => r.item.id === "machine:mine")?.why ?? "", /this machine's own login|本机自己的登录/);
  assert.equal(b.rig.store.getSession(mine), null);
  assert.equal(a.rig.hub.handedOver(mine), false, "it works here");
});

test("a failed item stops only what needs it: of three chats and their logins moved whole, the middle chat failing, the other two and the logins go, the failed one is named with its words, its job not started and named as waiting for it; moved back whole, a chat that cannot come back stops only itself", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const one = await stillfailChat(a);
  const mid = await stillfailChat(a);
  const [three] = await newSession(a.rig.hub, { runtime: "codex", profile: "cx", createdBy: "p@x" });
  a.jobs.push({ id: "a-dev", session: mid.key, name: "dev", command: "npm run dev", cwd: a.rig.session(mid.key).workspace, port: 3000, watch: false });
  w.tamper((to, r) => {
    if (to === B && r.method === "handover.begin" && Array.isArray(r.keys) && r.keys.includes(mid.key)) throw new Refused("the middle one refused"); // (as the other station answers a refusal: its words)
    return r;
  });
  const out = await a.moves.scheduler.move(WS, B, { all: true, follow: ["jobs"] });
  await w.quiet();
  const done = out.done.map((d) => `${d.module} ${d.id}`);
  assert.ok(done.includes(`chats ${one.key}`) && done.includes(`chats ${three}`), `the others went: ${JSON.stringify(done)}`);
  assert.ok(out.done.some((d) => d.module === "accounts"), `the logins went: ${JSON.stringify(done)}`);
  assert.deepEqual((out.failures ?? []).map((f) => [f.item.id, /the middle one refused/.test(f.error)]), [[mid.key, true]], "the failed one named, with its words");
  assert.match(out.refused.find((r) => r.item.id === `${mid.key}#dev`)?.why ?? "", /(waits for|在等).*(which did not move|没有迁过去)[:：].*the middle one refused/, "its job not started, waiting for it");
  assert.equal(a.rig.store.handedTo(mid.key), null, "it goes on here");
  // Back whole, the first chat not coming back: the rest come back.
  w.tamper((to, r) => {
    if (to === A && r.method === "handover.begin" && Array.isArray(r.keys) && r.keys.includes(one.key)) throw new Refused("the first one refused");
    return r;
  });
  const there = (await a.moves.scheduler.plan(WS, B)).items.filter((x) => x.state === "there").map((x) => `${x.module} ${x.id}`);
  const back = await a.moves.scheduler.back(WS, B, { all: true });
  await w.quiet();
  // (every item that was there is said of: came back, not brought (why), or failed: none left out by a failure)
  const said = new Set([...back.done, ...back.refused.map((r) => r.item), ...(back.failures ?? []).map((f) => f.item)].map((x) => `${x.module} ${x.id}`));
  assert.deepEqual(there.filter((x) => !said.has(x)), [], `every item there said of: ${JSON.stringify(back)}`);
  assert.deepEqual((back.failures ?? []).map((f) => f.item.id), [one.key], `the failed one named: ${JSON.stringify(back.failures)}`);
  const named = [...back.done, ...back.refused.map((r) => r.item), ...(back.failures ?? []).map((f) => f.item)];
  assert.ok(!named.some((x) => x.id === mid.key), `the one that never went is no item of the move back: ${JSON.stringify(named)}`);
  assert.ok(back.done.some((d) => d.id === three), `the others came back: ${JSON.stringify(back.done)}`);
  assert.equal(a.rig.store.handedTo(three), null);
});

test("a move asked as the connection to the other station is found gone asks once more, dialed anew: it goes; gone again, the other is said out of reach", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  let gone = 1;
  w.tamper((to, r) => {
    if (to === B && r.method === "move.open" && gone > 0) {
      gone--;
      throw new PeerGone();
    }
    return r;
  });
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key }).then((o) => ({ turn: null as string | null, failed: o.failed }), (e: Error) => ({ turn: e.message, failed: null }));
  await w.quiet();
  assert.deepEqual(out, { turn: null, failed: null }, "asked once more, dialed anew: it went");
  assert.equal(b.rig.session(key).ws, null, "it went");
  gone = 2;
  const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: key }).then(() => null, (e: Error) => e.message);
  assert.match(back ?? "", /cannot be reached now|连不上/, "gone twice: out of reach");
  assert.equal(a.rig.store.handedTo(key)?.station, B, "nothing moved");
});

test("the other station's process handing over to its next as every request of a move's turn is asked (half never taken, half taken with their answers lost): each is asked again once, dialed anew, and the move goes as it would, each entry there once", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  const said = entries(a, thread);
  // (each request of the turn to B met once by its process stopping: by its words, the same asked again passing)
  const met = new Map<string, "never taken" | "answer lost">();
  let turn = false;
  const first = (to: string, r: Json, how: "never taken" | "answer lost") => {
    if (!turn || to !== B) return false;
    const id = JSON.stringify(r);
    if (met.has(id)) return false;
    met.set(id, how);
    return true;
  };
  let n = 0;
  w.tamper((to, r) => {
    if (n % 2 === 0 && first(to, r, "never taken")) {
      n++;
      throw new PeerStopped();
    }
    return r;
  });
  w.lose((to, r) => (n % 2 === 1 && first(to, r, "answer lost") ? (n++, new PeerStopped()) : null));
  turn = true;
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key }).then((o) => ({ turn: null as string | null, failed: o.failed, failures: o.failures ?? [] }), (e: Error) => ({ turn: e.message, failed: null, failures: [] }));
  turn = false;
  await w.quiet();
  assert.deepEqual(out, { turn: null, failed: null, failures: [] }, "every request answered by the next process: it went");
  const kinds = new Set(met.values());
  assert.ok(met.size >= 6 && kinds.has("never taken") && kinds.has("answer lost"), `requests of each kind met the process stopping: ${JSON.stringify([...met].map(([r, how]) => [JSON.parse(r).method, how]))}`);
  assert.equal(a.rig.store.handedTo(key)?.station, B, "handed there");
  assert.equal(b.rig.session(key).ws, null, "it went");
  assert.deepEqual(entries(b, homeThread(b, key)), said, "each entry there once, asked twice or not");
});

test("a station whose process stops as move.open is asked is asked again once, dialed anew, and can be moved to; one that is really gone is said out of reach at once, in the same words as before", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  let stopping = 1;
  const asked: string[] = [];
  w.tamper((to, r) => {
    if (to === B) asked.push(r.method);
    if (to === B && r.method === "move.open" && stopping > 0) {
      stopping--;
      throw new PeerStopped();
    }
    return r;
  });
  assert.equal(await a.moves.refusal(WS, B), null, "answered by the next process");
  assert.deepEqual(asked, ["move.open", "move.open"]);
  asked.length = 0;
  b.up = false;
  assert.equal(await a.moves.refusal(WS, B), tr(stationLang(), "station.move.unreachable", { station: "B" }), "gone: out of reach, in its words");
  assert.deepEqual(asked, [], "not reached: nothing went, asked no more");
  b.up = true;
});

test("the other station killed in the middle of a turn: found gone once and dialed anew in vain, it is asked nothing more in that turn: what is left of the turn fails at once in people's words, the turn ends; started again, it keeps nothing of it", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const first = await stillfailChat(a);
  const second = await stillfailChat(a);
  // (B killed as the first chat's files are to be placed there, in its first pass: every request to it found gone from
  // then on, the one under way too)
  let dead = false;
  const asked: Json[] = [];
  const begun: string[][] = [];
  w.tamper((to, r) => {
    if (to === B && r.method === "handover.begin" && Array.isArray(r.keys) && !dead) begun.push(r.keys);
    if (to === B && r.method === "handover.place") dead = true;
    if (to === B && dead) {
      asked.push(r);
      throw new PeerGone();
    }
    return r;
  });
  const out = await a.moves.scheduler.move(WS, B, { module: "chats" });
  await w.quiet();
  const failures = new Map((out.failures ?? []).map((f) => [f.item.id, f.error]));
  assert.deepEqual([...failures.keys()].sort(), [first.key, second.key].sort(), JSON.stringify(out));
  // (the chat that met it found it gone; the other was never begun there: failed at once, in people's words)
  // (the chat under way as B died: begun there before; the other never begun there once B was dead)
  const under = [first.key, second.key].find((k) => begun.some((keys) => keys.includes(k)));
  const later = [first.key, second.key].find((k) => k !== under);
  assert.ok(under !== undefined && !asked.some((r) => r.method === "handover.begin" && Array.isArray(r.keys) && r.keys.includes(later!)), `one chat asked nothing of B once it was gone: ${JSON.stringify(asked.map((r) => r.method))}`);
  assert.match(failures.get(later!) ?? "", /B does not answer: nothing more is asked of it in this move|「B」没有应答：这次迁移不再向它发出任何请求/, "the station's own words, naming it");
  // (the one under way met its connection gone and was sent again once, B then found gone for the turn: where that
  // was a request of its files (a `put`, handover.ts `carryWords`), said as the other not answering as its files
  // went, `carryUnanswered`; where it was any other step of its hand-over (begin, rows, show), the turn's own words for
  // a station gone, `station.move.gone`)
  assert.ok([tr(stationLang(), "station.move.why.carryUnanswered")].some((w) => (failures.get(under!) ?? "").includes(w)) || /B does not answer: nothing more is asked of it in this move|「B」没有应答：这次迁移不再向它发出任何请求/.test(failures.get(under!) ?? ""), `the one under way: the station's words too: ${failures.get(under!)}`);
  for (const k of [under!, later!]) assert.ok(!/execution may have happened|connection was gone/.test(failures.get(k) ?? ""), `people's words, not the transport's: ${failures.get(k)}`);
  assert.ok(asked.length <= 3, `the request under way found gone, dialed anew once, then nothing more: ${JSON.stringify(asked.map((r) => r.method))}`);
  for (const k of [first.key, second.key]) {
    assert.equal(a.rig.store.handedTo(k), null, "here");
    assert.equal(a.rig.hub.chatHeld(k), null, "goes on here");
  }
  // B up again: told what it keeps of it is dropped; nothing of either chat left there
  dead = false;
  w.tamper(null);
  a.moves.handover.reached(B);
  await w.quiet();
  assert.deepEqual(b.rig.store.liveOf([first.key, second.key]), [], "B shows neither");
  assert.equal(b.moves.handover.comingFrom(first.key) ?? b.moves.handover.comingFrom(second.key), null, "nor keeps either coming");
});

test("arriveStopped, by a person's POST /move and by station_move: a chat whose login is not there goes all the same, arriving there stopped, waiting for it; asked without it, it is refused naming the login", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  a.rig.raw.profiles.push({ id: "solo", runtime: "claude", home: "homes/solo" });
  const chat = async () => {
    const [key, t] = await newSession(a.rig.hub, { runtime: "claude", profile: "solo", createdBy: "p@x" });
    say(a.rig.hub, t.id, "p@x", "hi");
    await endTurn(a, key);
    return key;
  };
  const one = await chat();
  const two = await chat();
  const account = `own:solo@${A}`;
  assert.equal((await a.ask("POST", "/move", { to: B, module: "chats", item: one })).status, 202);
  await a.moves.scheduler.settle();
  await w.quiet();
  assert.match(a.moves.scheduler.last(WS)?.refused.find((r) => r.item.id === one)?.why ?? "", /needs account “solo”|需要账号「solo」/, "without it: refused, naming the login");
  assert.equal((await a.ask("POST", "/move", { to: B, module: "chats", item: one, arriveStopped: true })).status, 202);
  await a.moves.scheduler.settle();
  await w.quiet();
  assert.equal(a.moves.scheduler.last(WS)?.failed, null, JSON.stringify(a.moves.scheduler.last(WS)));
  assert.equal(b.rig.store.getSession(one)?.ws, null, "there");
  assert.deepEqual(b.moves.scheduler.stopped().map((s) => [s.item.id, s.waitsFor.id]), [[one, account]], "stopped there, waiting for its login");
  const asks = new MoveAsks({ data: a.rig.dir, scheduler: a.moves.scheduler, here: () => A, wsOf: () => WS, roster: () => [{ id: A, name: "A" }, { id: B, name: "B" }], cards: { post: async () => null }, notify: () => {}, refusal: (ws, s) => a.moves.refusal(ws, s) });
  const said = await asks.toolIn(WS, null, { action: "move", to: "B", module: "chats", item: two, arriveStopped: true });
  await w.quiet();
  assert.equal(said.outcome.failed, null, JSON.stringify(said));
  assert.ok(b.moves.scheduler.stopped().some((s) => s.item.id === two), "by the tool too");
});

test("what moves nothing is asked first, and what moved for an item that then did not go comes back: a chat in a turn (wait false) is refused before its login moves; a chat refused there has its login, moved for it, brought back in the same turn, said so", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  a.rig.raw.profiles.push({ id: "solo", runtime: "claude", home: "homes/solo" });
  const [key, t] = await newSession(a.rig.hub, { runtime: "claude", profile: "solo", createdBy: "p@x" });
  const account = `own:solo@${A}`;
  const solo = (st: Station) => st.rig.raw.profiles.some((p: Json) => p.id === "solo");
  // In a turn, not to be waited for: refused, its login not moved.
  say(a.rig.hub, t.id, "p@x", "busy now");
  await a.rig.quiet();
  a.moves.wait = false;
  const busy = await a.moves.scheduler.move(WS, B, { module: "chats", item: key, withNeeds: true });
  assert.match(busy.refused.find((r) => r.item.id === key)?.why ?? "", /in a turn now|正在进行一轮/);
  assert.deepEqual(busy.done, [], "nothing moved for it");
  assert.ok(solo(a) && !solo(b), "its login here");
  a.moves.wait = true;
  await endTurn(a, key);
  // Refused there once its login moved for it: the login comes back.
  w.tamper((to, r) => {
    if (to === B && r.method === "handover.begin") throw new Error("not taken there");
    return r;
  });
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key, withNeeds: true });
  await w.quiet();
  assert.deepEqual((out.failures ?? []).map((f) => f.item.id), [key], "the chat failed, named");
  assert.deepEqual(out.returned, [{ module: "accounts", id: account }], "its login brought back, said so");
  assert.deepEqual(out.done, [], "nothing left moved");
  assert.ok(solo(a) && !solo(b), "its login here again");
  assert.equal(a.rig.hub.chatHeld(key), null, "the chat goes on here");
  assert.deepEqual(a.moves.scheduler.stopped(), []);
});

test("a chat held as what it needs moved away says so as its process ends, not that the station is in no workspace", async () => {
  const w = world();
  const a = w.get(A);
  const [key, t] = await newSession(a.rig.hub, { runtime: "claude", profile: "cc", createdBy: "p@x" });
  say(a.rig.hub, t.id, "p@x", "work on it");
  await a.rig.quiet();
  const lines: string[] = [];
  hearLines((l) => void lines.push(l.message));
  try {
    await a.rig.hub.holdChat(key, "stopped: waits for accounts own:solo@A, moved away", () => "waits for its account");
    await a.rig.quiet();
  } finally {
    hearLines(null);
  }
  const ending = lines.filter((m) => m.startsWith("ending the runtime process"));
  assert.deepEqual(ending, ["ending the runtime process: the chat is held: stopped: waits for accounts own:solo@A, moved away"]);
  assert.match(a.rig.store.listTurns(key).at(-1)?.summary.detail ?? "", /the chat is held: stopped: waits for accounts/);
  // (what it waits for is said as a person next speaks in it, never as its turn is cut: move-accounts.test.ts)
  const said = (a.rig.store.db.prepare("SELECT text FROM entries WHERE thread = ? AND author_kind = 'station'").all(t.id) as { text: string }[]).map((r) => r.text);
  assert.ok(!said.some((x) => x.includes("waits for its account")), `nothing said by the stop itself: ${JSON.stringify(said)}`);
});

test("an account that cannot be borrowed moved first: its chats here stop, naming it; a message to one is delivered once after it moved; moved back, the others go on here", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  a.rig.raw.profiles.push({ id: "solo", runtime: "claude", home: "homes/solo" });
  const make = async () => {
    const [key, t] = await newSession(a.rig.hub, { runtime: "claude", profile: "solo", createdBy: "p@x" });
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
  assert.deepEqual(plan.items.find((x) => x.id === one.key)!.waitsFor, { module: "accounts", id: `own:solo@${A}`, label: "solo", at: B }, "what it waits for, and the station that is on");
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
  assert.match(back.refused[0]!.why, new RegExp(one.key.replace(/^chat:/, "")));
});

test("a chat stopped as its account moved away says once what it waits for, as a person speaks in it: nothing before, nothing a second time", async () => {
  const w = world();
  const a = w.get(A);
  a.rig.raw.profiles.push({ id: "solo", runtime: "claude", home: "homes/solo" });
  const [key, t] = await newSession(a.rig.hub, { runtime: "claude", profile: "solo", createdBy: "p@x" });
  say(a.rig.hub, t.id, "p@x", "hi");
  await endTurn(a, key);
  await a.moves.scheduler.move(WS, B, { module: "accounts", item: `own:solo@${A}` });
  await w.quiet();
  assert.equal(a.rig.hub.chatHeld(key), `stopped: waits for accounts own:solo@${A}, moved away`);
  // (the catalog's words, the stations' names whatever they are: move/chats.ts `holdChat`'s notice)
  const shapeOf = (k: string) => tr(stationLang(), k, { here: "\u0000", item: "solo", there: "\u0000" }).replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replaceAll("\u0000", ".+");
  const shape = new RegExp(`^station:⚠️ (${shapeOf("station.move.stoppedChat")}|${shapeOf("station.move.stoppedChatHere")})$`);
  const said = () => entries(a, t.id).filter((e) => e.startsWith("station:"));
  assert.deepEqual(said(), [], "the stop itself says nothing");
  say(a.rig.hub, t.id, "p@x", "are you there?");
  await w.quiet();
  assert.equal(said().length, 1, `said once as a person spoke: ${JSON.stringify(said())}`);
  assert.match(said()[0]!, shape, "what it waits for, in the station's words");
  say(a.rig.hub, t.id, "p@x", "still there?");
  await w.quiet();
  assert.equal(said().length, 1, "not a second time in this stop");
  assert.equal(a.rig.claude.count(), 1, "no turn while stopped");
});

test("an account that cannot be borrowed moved, then back: its chats here stopped meanwhile go on here, what was said to them delivered once", async () => {
  const w = world();
  const a = w.get(A);
  a.rig.raw.profiles.push({ id: "solo", runtime: "claude", home: "homes/solo" });
  const [key, t] = await newSession(a.rig.hub, { runtime: "claude", profile: "solo", createdBy: "p@x" });
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
  const [key, t] = await newSession(a.rig.hub, { runtime: "claude", profile: "solo", createdBy: "p@x" });
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
  assert.match(refused.refused[0]?.why ?? "", /(needs repository|需要仓库)/);
  // (a repository moved is copied: still here, so moving it alone stops nothing; nor do the vault, agent home or settings)
  assert.deepEqual(plan.items.find((x) => x.id === repo)!.wouldStop, []);
  for (const m of a.moves.modules.filter((x) => ["repos", "vault", "settings"].includes(x.id))) assert.equal(m.usableHere?.({ module: m.id, id: "x", label: "x", needs: [] }), true, m.id);
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
  assert.ok(existsSync(join(ws, "proj", ".git")), "the worktree's .git stays, never put aside as not named");
  assert.equal(run(join(ws, "proj"), "rev-parse", "HEAD"), head, "the worktree here still git's");
  run(clone, "remote", "add", "origin", bare);
  await a.moves.scheduler.back(WS, B, { module: "repos", item: repo });
  await w.quiet();
  assert.deepEqual(readdirSync(join(b.rig.dir, "repos")), []);
});

test("settings and secrets each moved, then back: both stations as they were", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  await stillfailChat(a);
  a.rig.raw.agentEnv = { FOO: "from A", BAR: "only A has it" };
  b.rig.raw.agentEnv = { FOO: "B's" };
  // (a setting B has of its own, another value: B keeps it, and it cannot move, saying so)
  a.rig.raw.maxNudges = 3;
  b.rig.raw.maxNudges = 5;
  const nudges = (await a.moves.scheduler.plan(WS, B)).items.find((x) => x.id === "setting:maxNudges")!;
  assert.match(nudges.cannot ?? "", /that station has its own maxNudges \(5\), which it keeps|那台 station 有自己的 maxNudges（5）/);
  const pa = plainStore(a.rig.store.db);
  const pb = plainStore(b.rig.store.db);
  pa.put({ ws: WS, id: "tok", owner: "p@x", version: 1, kind: "token", name: "token", fields: { value: "s3cret" }, notes: "", at: 1 } as Json);
  pb.put({ ws: WS, id: "mine", owner: "p@x", version: 1, kind: "token", name: "b's", fields: { value: "b" }, notes: "", at: 1 } as Json);
  const plainB = pb.items(WS, "p@x").map((i) => i.id);
  // (B, taking a setting, holds its self-update while it does)
  const holding: number[] = [];
  b.onUpdate = () => void holding.push(b.holds);
  const out = await a.moves.scheduler.move(WS, B, { module: "settings", item: "setting:agentEnv" });
  await a.moves.scheduler.move(WS, B, { module: "vault", item: `vault:p@x@${WS}` });
  assert.equal(out.failed, null, JSON.stringify(out));
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
  for (const id of ["setting:agentEnv", `vault:p@x@${WS}`]) assert.equal(again.items.find((x) => x.id === id)?.state, "there", id);
  for (const [module, item] of [["settings", "setting:agentEnv"], ["vault", `vault:p@x@${WS}`]] as const) {
    const back = await a.moves.scheduler.back(WS, B, { module, item });
    assert.equal(back.failed, null, `${module}: ${JSON.stringify(back)}`);
  }
  assert.deepEqual(b.rig.raw.agentEnv, { FOO: "B's" });
  assert.deepEqual(pb.items(WS, "p@x").map((i) => i.id), plainB, "B lets go of what this move put there, and only that");
});

test("the other station not answering what repositories or settings it has as the plan asks: none of them goes, nor the chat that needs its repository, each refused in words (ask again), nothing tried; asked again with the answer, they go", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
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
  run(clone, "worktree", "add", "-q", "-b", "feature", join(ws, "proj"));
  a.rig.raw.agentEnv = { FOO: "from A" };
  b.rig.raw.agentEnv = { BAR: "B's" };
  const repo = `repo:${bare}`;
  // (B not reached for each question once: what it has is not guessed)
  const unanswered = new Set<string>();
  const handle = b.bus.handle.bind(b.bus);
  b.bus.handle = ((ws: string, peer: string, request: Json) => (unanswered.delete(request?.method) ? Promise.reject(new Error("the station was not reached")) : handle(ws, peer, request))) as typeof b.bus.handle;
  const words = /(the other station did not answer whether it has it: ask again|另一台 station 没有回答它那边有没有这一项：再试一次)$/;
  for (const m of ["move.repo.have", "move.setting.values"]) unanswered.add(m);
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key, withNeeds: true });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.deepEqual(out.done, []);
  assert.deepEqual(out.refused.map((r) => r.item.id), [key], "the chat, nothing of it tried");
  assert.ok(out.refused[0]!.why.startsWith(tr(stationLang(), "station.move.sched.needCannot", { need: tr(stationLang(), "station.move.called", { what: tr(stationLang(), "station.move.module.repos"), label: "proj" }), why: "" })), out.refused[0]!.why);
  assert.match(out.refused[0]!.why, words);
  for (const m of ["move.repo.have", "move.setting.values"]) unanswered.add(m);
  const plain = await a.moves.scheduler.move(WS, B, { module: "settings", item: "setting:agentEnv" });
  assert.deepEqual(plain.done, []);
  assert.match(plain.refused.find((r) => r.item.id === "setting:agentEnv")?.why ?? "", words, "the setting");
  assert.equal(a.rig.store.handedTo(key), null, "the chat here");
  assert.deepEqual(existsSync(join(b.rig.dir, "repos")) ? readdirSync(join(b.rig.dir, "repos")) : [], [], "no clone there");
  assert.deepEqual(b.rig.raw.agentEnv, { BAR: "B's" }, "B's settings as they were");
  const again = await a.moves.scheduler.move(WS, B, { module: "chats", item: key, withNeeds: true });
  await w.quiet();
  assert.equal(again.failed, null, JSON.stringify(again));
  assert.deepEqual(again.done.map((d) => d.id), [repo, key]);
  const setting = await a.moves.scheduler.move(WS, B, { module: "settings", item: "setting:agentEnv" });
  assert.deepEqual(setting.done.map((d) => d.id), ["setting:agentEnv"]);
  assert.deepEqual(b.rig.raw.agentEnv, { BAR: "B's", FOO: "from A" });
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
  const [key, t] = await newSession(a.rig.hub, { runtime: "claude", profile: "cc", createdBy: "p@x" });
  say(a.rig.hub, t.id, "p@x", "busy now");
  await a.rig.quiet();
  assert.equal(a.rig.hub.busy(key), true);
  a.moves.wait = false;
  const out = await given(a.moves.scheduler.move(WS, B, { module: "chats", item: key }), "refused at once, its turn not waited for");
  assert.match(out.refused.find((r) => r.item.id === key)?.why ?? "", /in a turn now|正在进行一轮/, "refused before anything moves");
  assert.equal(a.rig.hub.chatHeld(key), null, "not held");
  assert.equal(a.rig.store.handedTo(key), null);
});

test("a chat sent ahead of its account (arriveStopped) arrives stopped there, and goes on there as the account comes", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  a.rig.raw.profiles.push({ id: "solo", runtime: "claude", home: "homes/solo" });
  const [key, t] = await newSession(a.rig.hub, { runtime: "claude", profile: "solo", createdBy: "p@x" });
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

test("a chat stopped for its account whose hand-over fails in the first pass of its files stays stopped: nothing lets it go that it did not hold", async () => {
  const w = world();
  const a = w.get(A);
  a.rig.raw.profiles.push({ id: "solo", runtime: "claude", home: "homes/solo" });
  const [key, t] = await newSession(a.rig.hub, { runtime: "claude", profile: "solo", createdBy: "p@x" });
  say(a.rig.hub, t.id, "p@x", "hi");
  await endTurn(a, key);
  const out = await a.moves.scheduler.move(WS, B, { module: "accounts", item: `own:solo@${A}` });
  assert.deepEqual(out.stopped.map((s) => s.item.id), [key]);
  assert.notEqual(a.rig.hub.chatHeld(key), null);
  a.fails.add("files");
  const moved = await a.moves.scheduler.move(WS, B, { module: "chats", item: key, arriveStopped: true });
  await w.quiet();
  assert.ok((moved.failed?.error ?? "").includes(tr(stationLang(), "station.move.why.failedHere")) && !(moved.failed?.error ?? "").includes("the test failed"), `in the station's words, the cause the log's alone: ${moved.failed?.error}`);
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
    const [key] = await newSession(a.rig.hub, { runtime: "claude", profile: "cc", createdBy: "p@x" });
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

/// Station `st`'s next process (a launcher's hand-over): another Moves on its data directory, begun, the process before it
/// gone as `previous` says.
function nextProcess(st: Station, previous: Promise<void>) {
  const next = st.make(previous);
  return { next, started: next.start() };
}

/// Where chat `key` is in sight: the stations whose own row of it is live.
const inSight = (w: ReturnType<typeof world>, key: string) => [...w.stations.values()].filter((s) => s.rig.store.liveOf([key]).length > 0).map((s) => s.id.slice(0, 1));

test("a station handing over to its next process as one of its chats is handed to another station: the next process acts on it only once the one before is gone; the chat in sight on exactly one station", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  // (the next process begins as the hand-over has its counts there, between `rows` and `gone`)
  let gone!: () => void;
  const previous = new Promise<void>((r) => (gone = r));
  let next = null as ReturnType<typeof nextProcess> | null;
  a.onFail = (step) => {
    if (step === "counts" && next === null) next = nextProcess(a, previous);
  };
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  a.onFail = null;
  assert.ok(next !== null, "the next process began during the hand-over");
  // The process before stops and is gone; the next goes on.
  await a.moves.close();
  gone();
  await next!.started;
  a.moves = next!.next;
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out.failed));
  assert.deepEqual(inSight(w, key), ["b"], "in sight on B alone");
  assert.equal(a.rig.store.handedTo(key)?.station, B, "A says it is on B");
  assert.equal(b.rig.store.handedTo(key), null);
});

test("two processes of one station deciding one hand-over at once (the next not waiting for the one before): whichever decides first, the chat is in sight on exactly one station, never said gone where it failed", async () => {
  const w = world();
  const a = w.get(A);
  const { key } = await stillfailChat(a);
  // (the next process begins as the hand-over has its counts there, not waiting for this one (as a gate given up
  // would); this one, about to decide, waits for it to have begun: it decides first)
  let next = null as ReturnType<typeof nextProcess> | null;
  a.onFail = (step) => {
    if (step === "counts" && next === null) next = nextProcess(a, Promise.resolve());
    if (step === "decide" && next !== null) return next.started;
  };
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key }).then((o) => o, (e: Error) => ({ failed: { error: e.message } }));
  a.onFail = null;
  await next!.started;
  await a.moves.close();
  a.moves = next!.next;
  await w.quiet();
  const seen = inSight(w, key);
  assert.equal(seen.length, 1, `in sight on exactly one station: ${JSON.stringify(seen)} (${JSON.stringify(out.failed)})`);
  const handed = a.rig.store.handedTo(key);
  assert.equal(handed === null, seen[0] === "a", "said gone from A exactly where it is on B");
});

/// A hand-over record of A's of chat `key` to B as a process writes it (handover.ts `Out`).
function outRecord(st: Station, key: string, o: { id: string; step: string; at: number; shown?: boolean; ended?: boolean; v?: number }) {
  const path = join(st.rig.dir, "replica", "handover", "out", `${o.id}.json`);
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, JSON.stringify({
    id: o.id, keys: [key], to: B, toName: "B", ws: WS, at: o.at, step: o.step, error: o.step === "failed" ? "the station restarted midway" : null, jobs: [], dropOwed: false,
    sent: {}, counts: null, there: {}, routes: [], routed: 0, shown: o.shown ?? false, done: 0, total: 0, held: true, ...(o.v === undefined ? { v: 2 } : o.v === 1 ? {} : { v: o.v }), ...(o.ended ? { ended: true } : {}),
  }));
}

test("a chat this station says went to another where its hand-over failed and the other does not hold it (the real run's, 2026-11-15) is in sight here again as this station starts, once; one the other holds is completed", async () => {
  for (const there of [false, true]) {
    const w = world();
    const a = w.get(A);
    const b = w.get(B);
    const { key } = await stillfailChat(a);
    // A as Office-VM-1 was left: its record failed, its handed_over row naming B, B holding nothing of it in sight
    outRecord(a, key, { id: "mwhsykk6-x-bbbbbbbb-1", step: "failed", at: 1000 });
    a.rig.store.goneTo([key], B, { [key]: { thread: null, there: null } });
    if (there) {
      // (B holds it after all: a chat of that key in sight there)
      retiredCopy(a, b, key, null);
    }
    assert.equal(a.rig.store.handedTo(key)?.station, B);
    a.moves = a.make();
    await a.moves.start();
    await w.quiet();
    if (!there) {
      assert.equal(a.rig.store.handedTo(key), null, "no longer said to be on B");
      assert.deepEqual(inSight(w, key), ["a"], "in sight here, once");
    } else {
      assert.equal(a.rig.store.handedTo(key)?.station, B, "it went");
      assert.deepEqual(inSight(w, key), ["b"], "in sight there alone");
    }
  }
});

test("a failed hand-over of a chat that went later by another is left as it is: the chat stays where it went", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  // (older than the move after it: its chat's latest record is that one's)
  outRecord(a, key, { id: "old-failed-bbbbbbbb-1", step: "failed", at: -1 });
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(out.failed, null);
  a.moves = a.make();
  await a.moves.start();
  await w.quiet();
  assert.equal(a.rig.store.handedTo(key)?.station, B, "still said to be on B");
  assert.deepEqual(inSight(w, key), ["b"], "in sight on B alone");
  assert.equal(JSON.parse(readFileSync(join(a.rig.dir, "replica", "handover", "out", "old-failed-bbbbbbbb-1.json"), "utf8")).step, "failed", "the old record as it was");
});

test("a failed hand-over record that is from before (v1), was shown there, or is over is not mended: its chat stays said to be where it went", async () => {
  const w = world();
  const a = w.get(A);
  const keys: string[] = [];
  for (const [n, o] of [["v1", { v: 1 }], ["shown", { shown: true }], ["ended", { ended: true }]] as const) {
    const { key } = await stillfailChat(a);
    outRecord(a, key, { id: `${n}-failed-bbbbbbbb-1`, step: "failed", at: 1000, ...o });
    a.rig.store.goneTo([key], B, { [key]: { thread: null, there: null } });
    keys.push(key);
  }
  a.moves = a.make();
  await a.moves.start();
  await w.quiet();
  for (const key of keys) assert.equal(a.rig.store.handedTo(key)?.station, B, `${key}: still said to be on B`);
});

test("a move turn asked while the station process before this one is still there waits for it; past PREVIOUS_LIMIT_MS it is refused in words to ask again, and so is another station's request; once that process is gone, it goes", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  let gone!: () => void;
  const previous = new Promise<void>((r) => (gone = r));
  a.moves = a.make(previous);
  const turn = a.moves.scheduler.move(WS, B, { module: "chats", item: key }).then((o) => ({ o, e: null as Error | null }), (e: Error) => ({ o: null, e }));
  const peer = b.bus.ask(A, { method: "move.chats.live", keys: [key] }).then(() => null, (e: Error) => e);
  await w.quiet();
  await w.t.adjust(PREVIOUS_LIMIT_MS);
  const words = tr(stationLang(), "station.move.previousStill");
  const refused = await given(turn, "the turn answered past the limit");
  assert.equal(refused.e?.message, words, "the turn refused in words");
  assert.equal((await given(peer, "the other station answered"))?.message, words, "the other station's request refused in words");
  assert.equal(a.rig.store.handedTo(key), null, "nothing moved");
  gone();
  await a.moves.start();
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out.failed));
  assert.equal(a.rig.store.handedTo(key)?.station, B, "gone, it went");
});

test("a chat said gone whose show was never answered, left so by two processes of one station (the drill's 9m: the one before wrote `gone` last): where it went dropped the hand-over, it is in sight here again, once; where it holds it and only the show's answer was lost, it is completed, never taken back", async () => {
  for (const dropped of [true, false]) {
    const w = world();
    const a = w.get(A);
    const b = w.get(B);
    const { key } = await stillfailChat(a);
    // (its show not answered: never taken there, or taken and its answer lost)
    let shows = 0;
    w.tamper((to, r) => {
      if (to === B && r.method === "handover.show" && dropped && shows++ === 0) throw new Error("station unreachable");
      return r;
    });
    w.lose((to, r) => (to === B && r.method === "handover.show" && !dropped && shows++ === 0 ? new Error("station unreachable") : null));
    const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
    await w.quiet();
    const o = a.moves.handover.outs()[0]!;
    assert.equal(o.step, "gone", `${dropped}: said gone, ${JSON.stringify(out.failed)}`);
    assert.equal(o.shown, false, "not shown");
    w.tamper(null);
    w.lose(null);
    if (dropped) {
      // (dropped there, as the next process had it dropped)
      await a.bus.ask(B, { method: "handover.drop", workspace: WS, origin: A, id: o.id });
      assert.deepEqual(inSight(w, key), ["a"], "only A's row, said gone");
    } else assert.deepEqual(inSight(w, key), ["a", "b"], "shown there, its answer lost");
    // A started again (the next process, the one before gone)
    await a.moves.close();
    a.moves = a.make();
    await a.moves.start();
    await w.quiet();
    if (dropped) {
      assert.deepEqual(inSight(w, key), ["a"], "in sight on A, once");
      assert.equal(a.rig.store.handedTo(key), null, "no longer said to be on B");
      const after = a.moves.handover.outs().find((x) => x.id === o.id)!;
      assert.equal(after.step, "failed", "the record over as a failure");
      assert.equal(after.ended, true);
    } else {
      assert.deepEqual(inSight(w, key), ["b"], "in sight on B alone: completed, not taken back");
      assert.equal(a.rig.store.handedTo(key)?.station, B);
    }
  }
});

test("a chat that only ran before on a login of this machine's own (which cannot go) is no need of it: planned here with no `cannot`, saying what it leaves; moved with its needs, it goes on the login it runs on, its turns there taking up its runtime session; moved back, the past login's runtime session is here as it was; one running on such a login now still cannot go", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  // (it ran on `mine`, this machine's own, before; it runs on `cc`, shared, now)
  a.rig.store.ranIn(key, "run-mine", "mine");
  const [onMine] = await newSession(a.rig.hub, { runtime: "claude", profile: "mine", createdBy: "p@x" });
  const plan = await a.moves.scheduler.plan(WS, B);
  const item = plan.items.find((x) => x.module === "chats" && x.id === key)!;
  assert.equal(item.cannot, undefined, `no cannot: ${item.cannot}`);
  assert.ok(!item.needs.some((n) => n.id === "machine:mine"), `no need of the past login: ${JSON.stringify(item.needs)}`);
  assert.match(item.leaves ?? "", /mine/, "says what it leaves");
  const now = plan.items.find((x) => x.module === "chats" && x.id === onMine)!;
  assert.ok(now.needs.some((n) => n.id === "machine:mine"), "one running on it now still needs it");
  // Moved with its needs: it goes, nothing of the past login moved.
  const asked: string[] = [];
  w.tamper((to, r) => (to === B && asked.push(JSON.stringify(r)), r));
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key, withNeeds: true });
  await w.quiet();
  w.tamper(null);
  assert.equal(out.failed, null, JSON.stringify(out.failed));
  assert.ok(!out.done.some((d) => d.id === "machine:mine"), "the past login not moved");
  assert.ok(!asked.some((r) => r.includes("move.accounts") && r.includes("mine")), "the past login asked of B as no account");
  assert.equal(b.rig.session(key).ws, null, "it went");
  // A turn there: on its current login, its runtime session taken up.
  say(b.rig.hub, homeThread(b, key), "p@x", "and there?");
  await w.quiet();
  assert.equal(b.rig.claude.last().options.resume, "claude-1", "its runtime session on its current login taken up");
  await endTurn(b, key);
  // Back: the past login's runtime session here as it was.
  const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(back.failed, null, JSON.stringify(back.failed));
  const rows = a.rig.store.db.prepare("SELECT id, profile FROM runtime_sessions WHERE session_key = ? ORDER BY id").all(key) as { id: string; profile: string }[];
  assert.ok(rows.some((r) => r.id === "run-mine" && r.profile === "mine"), `the past login's runtime session kept here: ${JSON.stringify(rows)}`);
});
