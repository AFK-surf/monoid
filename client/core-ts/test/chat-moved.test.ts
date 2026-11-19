// A chat handed from one station of a workspace to another (station/src/replica/handover.ts) as the core takes it
// (src/views/moved.ts): shown once, where it is now; a link, a page open on it, what was sent to it follow it there.
// `ws/st` (studio, A) and `ws/st2` (mini, B), both answering at the same origin, the wire saying which a request is for.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect } from "effect";
import { linkNow } from "../src/asks.ts";
import { Core } from "../src/core.ts";
import { CoreError } from "../src/error.ts";
import type { HttpRequest } from "../src/host.ts";
import type { StationAddr } from "../src/station/addr.ts";
import { HostWire, type RequestHead, type StationWire } from "../src/station/wire.ts";
import type { FakeHost } from "../src/testing.ts";
import { answers, apply, call, subscribe, v } from "./helpers.ts";
import { base, chatsOf, entry, session, started, stationReplies, status } from "./station-fixture.ts";
import type { Topic } from "../src/protocol.ts";
import { Queue } from "effect";

// deno-lint-ignore no-explicit-any
type J = any;

const AT = "x-test-station";
const A = "ws/st";
const B = "ws/st2";

/// `from`: the station it says it came from (its agent's summary's, as B's are to say it: the report's ask of the station).
type Row = { id: string; thread: number; title: string; at: number; from?: string };
const rowOf = (r: Row) => ({ id: r.id, session: r.id, thread: r.thread, title: r.title, agents: r.from === undefined ? [] : [{ key: r.id, from: r.from }], last: { seq: 1 }, unread: false, mine: true, lastActiveAt: r.at, connect: null, origin: null });

/// The two stations as the test has them: what each lists, what each says went elsewhere (`GET /moved`), whether A is
/// reached, and what each was sent (method and path, with the body).
type World = {
  rows: Record<string, Row[]>;
  moved: Record<string, J[]>;
  off: Set<string>;
  sent: { station: string; method: string; path: string; body: J; headers: [string, string][] }[];
  reply: (station: string, method: string, path: string, body: J) => unknown;
};

function world(): World {
  return { rows: { st: [], st2: [] }, moved: { st: [], st2: [] }, off: new Set(), sent: [], reply: () => undefined };
}

const stationOf = (req: HttpRequest) => req.headers.find(([k]) => k === AT)?.[1] ?? "st";

async function rig(w: World, host?: FakeHost, gate?: (g: { resumes: boolean; marks: boolean }) => void) {
  const wire = (h: FakeHost) => {
    const inner = new HostWire(h);
    return {
      request: (station: StationAddr, head: RequestHead, body: Uint8Array) =>
        w.off.has(station.station) ? Effect.fail(new CoreError("mesh", "unreached")) : inner.request(station, { ...head, headers: [...head.headers, [AT, station.station]] }, body),
    } as StationWire;
  };
  const answer = (x: { host: FakeHost; cloud: { also?: Record<string, unknown> }; gate: { resumes: boolean; marks: boolean } }) => {
    gate?.(x.gate);
    // (as the cloud lists them each time it is asked: A down once it is off)
    Object.defineProperty(x.cloud, "also", { get: () => ({ stations: [{ id: "st", name: "studio", online: !w.off.has("st"), last_seen: null }, { id: "st2", name: "mini", online: true, last_seen: null }] }) });
    stationReplies(x.host, (req: HttpRequest) => {
      const who = stationOf(req);
      const path = req.url.replace("https://stillfail.test/admin/api", "");
      const body = req.body && req.body.length > 0 ? JSON.parse(new TextDecoder().decode(req.body)) : null;
      if (req.method !== "GET" && !path.startsWith("/changed/") && path !== "/batch") w.sent.push({ station: who, method: req.method, path, body, headers: req.headers });
      const said = w.reply(who, req.method, path, body);
      if (said !== undefined) return said;
      if (req.method === "GET" && path.startsWith("/moved?")) {
        const after = new URL(`https://x${path}`).searchParams.get("after") ?? "";
        return { moved: w.moved[who]!.filter((m) => m.session > after) };
      }
      // (each chat's one message, as its row says it goes to 1)
      const entries = /^\/threads\/(\d+)\/entries\?/.exec(path);
      // (B's said on another day, so what a page shows of it by day is B's own)
      if (req.method === "GET" && entries) return { last: 1, entries: [{ ...entry(1, "m1"), thread: Number(entries[1]), ...(who === "st2" ? { at: 3 * 86_400_000 } : {}) }] };
      // (B's agent runs a job there, A's none)
      if (req.method === "GET" && who === "st2" && /^\/sessions\/k1(\?|$)/.test(path)) return { session: session("k1"), threads: [], turns: [], jobs: [{ id: "j-b", name: "web", state: "running", startedAt: 1, session: "k1" }] };
      const of = chatsOf(w.rows[who]!.map(rowOf));
      // (a thread's own summary, as its station lists it)
      // (the marks of some chats as of all: the fixture's are of none)
      if (req.method === "GET" && path.startsWith("/chats?marks=1&")) return of["GET /chats?marks=1"];
      const one = /^\/threads\/(\d+)$/.exec(path);
      if (req.method === "GET" && one) return ((of["GET /threads"] as J[]) ?? []).find((t: J) => t.id === Number(one[1])) ?? status(404, { error: "没有这个会话" });
      const asked = `${req.method} ${path}`;
      return asked in of ? of[asked] : undefined;
    });
  };
  if (host === undefined) {
    const s = await started(base(), 0, wire, answer);
    return { ...s, ui: s.core.connect() };
  }
  // (a core started anew on the same device: its database as the last left it, the stations as they are now)
  void gate;
  const core = await Core.create(host, { clock: host.time.clock, sample: 0, wire: () => wire(host) });
  await host.time.pass(500);
  return { host, core, ui: core.connect(), pushOn: undefined as never };
}

async function settle(host: FakeHost) {
  for (let i = 0; i < 4; i++) {
    await host.settle();
    await host.time.pass(500);
  }
  await host.settle();
}

/// The chat list's rows as [station, id, title].
function listed(values: Map<number, unknown>, id: number): [string, string, string][] {
  return (v(values, id)?.days ?? []).flatMap((d: J) => d.items).map((i: J) => [i.station, i.id, i.title]);
}

const movedTo = (session: string, station: string | null, thread: number | null, there: number | null) => ({ session, station, thread, there });

test("a_chat_moved_to_another_station_is_listed_once_where_it_is_now", async () => {
  const w = world();
  // Both list it in the window before A says it went (B's copy says nothing of where it came from): both shown.
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }, { id: "k2", thread: 8, title: "别的", at: 2000 }];
  w.rows.st2 = [{ id: "k1", thread: 21, title: "在 mini", at: 3000 }];
  const s = await rig(w);
  const values = new Map<number, unknown>();
  subscribe(s.core, s.ui, 1, { topic: "chats", scope: "ws" });
  await settle(s.host);
  apply(s.host, values);
  assert.deepEqual(listed(values, 1).filter(([, id]) => id === "k1"), [[A, "k1", "在 studio"], [B, "k1", "在 mini"]], "two stations' keys, nothing said");
  // A says it went (nothing else: its rows drop by the pointer alone).
  s.pushOn([AT, "st"], "chat-moved", movedTo("k1", "st2", 7, 21));
  await settle(s.host);
  apply(s.host, values);
  assert.deepEqual(listed(values, 1).filter(([, id]) => id === "k1"), [[B, "k1", "在 mini"]], "B's alone");
  assert.ok(listed(values, 1).some(([st, id]) => st === A && id === "k2"), "A's other chats stay");
  // A's list made again with the chat still in it (as it was read before it went): not listed of A.
  s.pushOn([AT, "st"], "chat-changed", { thread: null });
  await settle(s.host);
  apply(s.host, values);
  assert.deepEqual(listed(values, 1).filter(([, id]) => id === "k1"), [[B, "k1", "在 mini"]], "A's not listed again");
  s.core.close();
});

test("one_session_key_on_two_stations_is_two_chats_unless_one_says_it_came_from_the_other", async () => {
  // A platform thread's key is its connect's, each station's own: the same key on two stations, nothing said, is two.
  const w = world();
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 3000 }];
  w.rows.st2 = [{ id: "k1", thread: 21, title: "在 mini", at: 5000 }];
  const s = await rig(w);
  const values = new Map<number, unknown>();
  subscribe(s.core, s.ui, 1, { topic: "chats", scope: "ws" });
  await settle(s.host);
  apply(s.host, values);
  assert.deepEqual(listed(values, 1), [[B, "k1", "在 mini"], [A, "k1", "在 studio"]]);
  s.core.close();
  // B's row says it came from A: once, B's.
  const v2 = world();
  v2.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 3000 }];
  v2.rows.st2 = [{ id: "k1", thread: 21, title: "在 mini", at: 5000, from: "st" }];
  const again = await rig(v2);
  const after = new Map<number, unknown>();
  subscribe(again.core, again.ui, 1, { topic: "chats", scope: "ws" });
  await settle(again.host);
  apply(again.host, after);
  assert.deepEqual(listed(after, 1), [[B, "k1", "在 mini"]]);
  again.core.close();
});

test("what_a_station_handed_elsewhere_is_read_as_its_link_opens", async () => {
  const w = world();
  // A still lists it (it is newer there), but says it went (`GET /moved`): B's is the one.
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }];
  w.rows.st2 = [{ id: "k1", thread: 21, title: "在 mini", at: 3000 }];
  w.moved.st = [{ ...movedTo("k1", "st2", 7, 21), at: 1000 }];
  const s = await rig(w);
  const values = new Map<number, unknown>();
  subscribe(s.core, s.ui, 1, { topic: "chats", scope: "ws" });
  await settle(s.host);
  apply(s.host, values);
  assert.deepEqual(listed(values, 1), [[B, "k1", "在 mini"]]);
  assert.ok(s.host.requests.some((r) => r.url.includes("/admin/api/moved?after=&limit=500") && stationOf(r) === "st"), "asked of A");
  s.core.close();
});

test("a_chat_whose_station_went_off_before_it_said_so_is_listed_where_it_came", async () => {
  const w = world();
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }];
  const first = await rig(w);
  const values = new Map<number, unknown>();
  subscribe(first.core, first.ui, 1, { topic: "chats", scope: "ws" });
  await settle(first.host);
  apply(first.host, values);
  assert.deepEqual(listed(values, 1), [[A, "k1", "在 studio"]]);
  first.core.close();
  // A is off before the device heard anything; B lists the chat (its copy), saying it came from A.
  w.off.add("st");
  w.rows.st2 = [{ id: "k1", thread: 21, title: "在 mini", at: 5000, from: "st" }];
  const host = first.host;
  host.takeEmitted();
  const again = await rig(w, host);
  const after = new Map<number, unknown>();
  subscribe(again.core, again.ui, 1, { topic: "chats", scope: "ws" });
  await settle(host);
  apply(host, after);
  assert.deepEqual(listed(after, 1), [[B, "k1", "在 mini"]]);
  again.core.close();
});

test("a_link_to_a_chat_on_the_station_it_left_opens_it_where_it_is", async () => {
  const w = world();
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }];
  const s = await rig(w);
  s.pushOn([AT, "st"], "chat-moved", movedTo("k1", "st2", 7, 21));
  await settle(s.host);
  call(s.core, s.ui, 1, "link.parse", { url: "https://stillfail.test/w/ws/s/st/chats/k1" });
  call(s.core, s.ui, 2, "link.parse", { url: "https://stillfail.test/o/ws/st/k1" });
  await settle(s.host);
  const emitted = s.host.takeEmitted();
  const ok = (id: number): J => (answers(emitted, id) as J)?.ok;
  assert.deepEqual([ok(1)?.station, ok(1)?.chat], ["st2", "k1"]);
  assert.deepEqual([ok(2)?.station, ok(2)?.session], ["st2", "k1"]);
  s.core.close();
});

test("a_link_follows_every_hop_and_refuses_one_that_goes_round", () => {
  const hops: Record<string, string> = { "ws/a": "ws/b", "ws/b": "ws/c" };
  const chatNow = (address: string, by: { session: string } | { thread: number }) => {
    if ("session" in by && by.session !== "k1") return null;
    let at = address;
    while (hops[at] !== undefined) at = hops[at]!;
    return at === address ? null : { station: at, session: "session" in by ? by.session : "k1", thread: 30 };
  };
  const chat = { opens: "chat", workspace: "ws", station: "a", chat: "k1" };
  assert.equal(linkNow(chat, (a) => a, chatNow).station, "c");
  // By its thread there: its thread on the station it is on.
  assert.deepEqual([linkNow({ ...chat, chat: "7" }, (a) => a, chatNow).station, linkNow({ ...chat, chat: "7" }, (a) => a, chatNow).chat], ["c", "30"]);
  // Taken by another station's place (`formerly`) after it moved: followed there too.
  assert.equal(linkNow(chat, (a) => (a === "ws/c" ? "ws/d" : a), chatNow).station, "d");
  // Round: as named.
  const round = (address: string) => ({ station: address === "ws/a" ? "ws/b" : "ws/a", session: "k1", thread: null });
  assert.equal(linkNow(chat, (a) => a, round), chat);
});

/// A chat open on A (its page holding `topic` by A's thread, 7) as A says it went to B (its thread there 21): what it
/// shows before and after, and B's own of the same topic.
async function openAsItMoves(topic: (station: string, thread: number) => Topic, draft?: string) {
  const w = world();
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }];
  // (B has its copy already, as one being put in: older, so A's is the one shown)
  w.rows.st2 = [{ id: "k1", thread: 21, title: "在 mini", at: 3000 }];
  const s = await rig(w);
  subscribe(s.core, s.ui, 1, topic(A, 7));
  if (draft !== undefined) s.core.inner.data.set({ topic: "draft", station: A, chat: "k1" }, { text: draft }, false);
  await settle(s.host);
  const store = s.core.inner.store;
  const before = store.value(topic(A, 7));
  s.pushOn([AT, "st"], "chat-moved", movedTo("k1", "st2", 7, 21));
  // (B's own, as a page there would hold it)
  subscribe(s.core, s.ui, 2, topic(B, 21));
  await settle(s.host);
  return { s, before, after: store.value(topic(A, 7)), there: store.value(topic(B, 21)) };
}

/// A value as the page on A names its thread (B's 21 its 7).
const named = (v: unknown) => {
  const x = JSON.parse(JSON.stringify(v ?? null));
  if (x?.ok?.thread?.id === 21) x.ok.thread.id = 7;
  return JSON.stringify(x);
};

test("a_chat_open_when_it_moves_shows_its_copy_where_it_is_its_thread_as_the_page_names_it", async () => {
  const { s, before, after, there } = await openAsItMoves((station, thread) => ({ topic: "chat", station, thread, session: null }));
  assert.equal((before as J)?.ok?.title, "在 studio");
  assert.equal((after as J)?.ok?.title, "在 mini");
  assert.equal((after as J)?.ok?.thread?.id, 7);
  assert.equal(JSON.stringify(after), named(there));
  s.core.close();
});

// Every other topic a chat's page holds by its thread: its copy's on B, the page's own topic all along.
for (const [name, of] of [
  ["its_messages", (station: string, thread: number): Topic => ({ topic: "thread", station, thread })],
  ["its_letters", (station: string, thread: number): Topic => ({ topic: "letters", station, thread })],
  ["what_its_agents_wrote_each_other", (station: string, thread: number): Topic => ({ topic: "chatLetters", station, thread })],
  ["its_things", (station: string, thread: number): Topic => ({ topic: "chatThings", station, thread })],
  ["its_outline", (station: string, thread: number): Topic => ({ topic: "chatOutline", station, thread })],
  ["its_jobs", (station: string, thread: number): Topic => ({ topic: "chatJobs", station, thread, session: null })],
] as const) {
  test(`a_chat_open_when_it_moves_shows_${name}_where_it_is`, async () => {
    const { s, before, after, there } = await openAsItMoves(of);
    assert.notEqual(there, undefined, "B's");
    // (B's differs from A's: so it is B's that is shown)
    assert.notEqual(named(there), named(before), "B's is not A's");
    assert.equal(JSON.stringify(after), named(there));
    s.core.close();
  });
}

test("a_chat_open_when_it_moves_keeps_its_draft_where_it_is", async () => {
  const { s } = await openAsItMoves((station, thread) => ({ topic: "chat", station, thread, session: null }), "写了一半");
  assert.equal((s.core.inner.data.get({ topic: "draft", station: B, chat: "k1" }) as J)?.text, "写了一半");
  assert.equal(s.core.inner.data.get({ topic: "draft", station: A, chat: "k1" }), undefined);
  s.core.close();
});


test("a_message_its_station_says_went_elsewhere_is_sent_there_once_and_never_failed", async () => {
  const w = world();
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }];
  w.reply = (station, method, path) => {
    if (station === "st" && method === "POST" && path === "/threads/7/messages") return status(409, { error: "这个会话已转到另一台 station", moved: movedTo("k1", "st2", 7, 21) });
    if (station === "st2" && method === "POST" && path === "/threads/21/messages") return { n: 4 };
    return undefined;
  };
  const s = await rig(w);
  const values = new Map<number, unknown>();
  subscribe(s.core, s.ui, 1, { topic: "chat", station: A, thread: 7, session: null });
  await settle(s.host);
  const failed: unknown[] = [];
  call(s.core, s.ui, 2, "chat.send", { station: A, thread: 7, text: "接着做", client: "测试端" });
  for (let i = 0; i < 6; i++) {
    await s.host.settle();
    await s.host.time.pass(200);
    for (const [, m] of s.host.takeEmitted()) {
      const msg = m as J;
      if (msg.id === 1) {
        if ("value" in msg) values.set(1, msg.value);
        else if ("delta" in msg) apply(s.host, values);
      }
      if (JSON.stringify(msg).includes('"failed"')) failed.push(msg);
      if (msg.id === 2 && ("ok" in msg || "err" in msg)) values.set(2, msg);
    }
  }
  const posts = w.sent.filter((x) => x.method === "POST" && x.path.endsWith("/messages"));
  assert.deepEqual(posts.map((x) => [x.station, x.path, x.body?.text]), [["st", "/threads/7/messages", "接着做"], ["st2", "/threads/21/messages", "接着做"]]);
  // Sent there as the same message: its key and the app it was sent from as they went to A (B knows it by them).
  const key = (x: { headers: [string, string][] }) => x.headers.find(([k]) => k.toLowerCase() === "idempotency-key")?.[1];
  assert.ok(key(posts[0]!) !== undefined && key(posts[0]!) === key(posts[1]!), "the same idempotency key");
  assert.deepEqual([posts[0]!.body?.client, posts[1]!.body?.client], ["测试端", "测试端"]);
  assert.deepEqual((values.get(2) as J)?.ok, { seq: 4 });
  assert.deepEqual(failed, [], "never shown failed");
  assert.deepEqual(s.core.inner.views.local.outbox(A, 7), []);
  // One message, sent: none left waiting on B's copy, nor another made of it.
  assert.deepEqual(s.core.inner.views.local.outbox(B, 21).filter((m: J) => m.state !== "sent").map((m: J) => [m.text, m.state]), []);
  assert.ok(s.core.inner.views.local.outbox(B, 21).length <= 1);
  s.core.close();
});

test("a_rename_and_a_pin_aimed_at_the_station_it_left_go_where_it_is", async () => {
  const w = world();
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }];
  const refused = status(409, { error: "这个会话已转到另一台 station", moved: movedTo("k1", "st2", 7, 21) });
  w.reply = (station, method, path) => {
    if (station === "st" && (path === "/threads/7/title" || path === "/sessions/k1/pin")) return refused;
    if (station === "st2" && (path === "/threads/21/title" || path === "/sessions/k1/pin")) return { ok: true };
    return undefined;
  };
  const s = await rig(w);
  await settle(s.host);
  call(s.core, s.ui, 1, "chat.rename", { station: A, thread: 7, session: "k1", title: "新名字" });
  await settle(s.host);
  // Now known: the pin goes to B at once.
  call(s.core, s.ui, 2, "chat.pin", { station: A, session: "k1", pinned: true });
  await settle(s.host);
  const emitted = s.host.takeEmitted();
  assert.ok(answers(emitted, 1) && "ok" in answers(emitted, 1)!, JSON.stringify(answers(emitted, 1)));
  assert.ok(answers(emitted, 2) && "ok" in answers(emitted, 2)!, JSON.stringify(answers(emitted, 2)));
  assert.deepEqual(w.sent.filter((x) => x.path.endsWith("/title") || x.path.endsWith("/pin")).map((x) => [x.station, x.method, x.path]), [
    ["st", "PUT", "/threads/7/title"],
    ["st2", "PUT", "/threads/21/title"],
    ["st2", "PUT", "/sessions/k1/pin"],
  ]);
  s.core.close();
});

// A mark sent to the station a chat just left, before this device is told it went (the station answers it 409 with
// `moved`, as a message: the station agent's, 2026-11-15): made again where it is (core.ts `#call`'s `again`), what was
// laid over its row ending done there and nothing left of it on the station it left; a card dismissed the same.
test("a_mark_answered_moved_is_made_again_where_the_chat_is_its_overlay_done_there_and_a_card_dismissed_too", async () => {
  const w = world();
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }];
  const refused = status(409, { error: "这个会话已转到另一台 station", moved: movedTo("k1", "st2", 7, 21) });
  w.reply = (station, method, path) => {
    if (station === "st" && (path === "/threads/7/hidden" || path === "/threads/7/dismissed")) return refused;
    if (station === "st2" && (path === "/threads/21/hidden" || path === "/threads/21/dismissed")) return { ok: true };
    return undefined;
  };
  const s = await rig(w);
  await settle(s.host);
  call(s.core, s.ui, 1, "chat.hide", { station: A, thread: 7, hidden: true });
  call(s.core, s.ui, 2, "decision.dismiss", { station: A, thread: 7, seq: 3 });
  await settle(s.host);
  const emitted = s.host.takeEmitted();
  assert.ok(answers(emitted, 1) && "ok" in answers(emitted, 1)!, JSON.stringify(answers(emitted, 1)));
  assert.ok(answers(emitted, 2) && "ok" in answers(emitted, 2)!, JSON.stringify(answers(emitted, 2)));
  // (each asked of A once, as it was named there, and made again on B, its thread there)
  // (the two go at once: in either order)
  const asked = w.sent.filter((x) => x.path.endsWith("/hidden") || x.path.endsWith("/dismissed")).map((x) => JSON.stringify([x.station, x.method, x.path, x.body])).sort();
  assert.deepEqual(asked, [
    ["st", "PUT", "/threads/7/dismissed", { n: 3 }],
    ["st", "PUT", "/threads/7/hidden", { hidden: true }],
    ["st2", "PUT", "/threads/21/dismissed", { n: 3 }],
    ["st2", "PUT", "/threads/21/hidden", { hidden: true }],
  ].map((x) => JSON.stringify(x)).sort());
  const local = s.core.inner.views.local;
  // (laid over B's copy, done there; none left over A's)
  assert.equal(local.asChanging(B, { thread: 21, session: "k1", hidden: false }).hidden, true);
  assert.equal(local.asChanging(A, { thread: 7, session: "k1", hidden: false }).hidden, false);
  assert.ok(local.rowsQuiet(A), "nothing changing of A's rows");
  s.core.close();
});

test("a_change_laid_over_a_chat_that_moved_is_laid_over_its_copy_there", async () => {
  const w = world();
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }];
  const s = await rig(w);
  await settle(s.host);
  const local = s.core.inner.views.local;
  // Done here, waiting for A's rows to say so, as it moves.
  const id = local.changing(A, 7, "k1", { title: "新名字" }, null);
  local.changed(id, true, s.core.inner.data.rowsRev(A));
  s.pushOn([AT, "st"], "chat-moved", movedTo("k1", "st2", 7, 21));
  await settle(s.host);
  assert.equal(local.asChanging(B, { thread: 21, session: "k1", title: "在 mini" }).title, "新名字");
  assert.equal(local.asChanging(A, { thread: 7, session: "k1", title: "在 studio" }).title, "在 studio");
  s.core.close();
});

test("an_archive_asked_here_and_not_answered_yet_as_the_chat_moves_is_held_where_it_went_and_its_answer_lands_there", async () => {
  const w = world();
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }];
  const s = await rig(w);
  await settle(s.host);
  const local = s.core.inner.views.local;
  // Archived here, its station not answered yet, as the chat moves.
  const id = local.changing(A, 7, "k1", {}, true);
  s.pushOn([AT, "st"], "chat-moved", movedTo("k1", "st2", 7, 21));
  await settle(s.host);
  assert.equal(local.archivedChanging(B, 21, "k1"), true, "held archived on the station it went to");
  assert.equal(local.archivedChanging(A, 7, "k1"), null, "nothing of it left where it was");
  // Its answer (refused) lands on that record: let go there, the chat as its station has it.
  local.changed(id, false, s.core.inner.data.rowsRev(B));
  assert.equal(local.archivedChanging(B, 21, "k1"), null, "the answer found it there");
  s.core.close();
});

test("a_chat_moved_and_moved_back_is_listed_once_where_it_is", async () => {
  const w = world();
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }];
  w.rows.st2 = [{ id: "k1", thread: 21, title: "在 mini", at: 3000 }];
  const s = await rig(w);
  const values = new Map<number, unknown>();
  subscribe(s.core, s.ui, 1, { topic: "chats", scope: "ws" });
  await settle(s.host);
  s.pushOn([AT, "st"], "chat-moved", movedTo("k1", "st2", 7, 21));
  await settle(s.host);
  apply(s.host, values);
  assert.deepEqual(listed(values, 1), [[B, "k1", "在 mini"]]);
  // Back: B says it went to A (its rows as they were: the pointer drops them), A that it came back.
  s.pushOn([AT, "st2"], "chat-moved", movedTo("k1", "st", 21, 7));
  s.pushOn([AT, "st"], "chat-moved", movedTo("k1", null, null, null));
  await settle(s.host);
  apply(s.host, values);
  assert.deepEqual(listed(values, 1), [[A, "k1", "在 studio"]]);
  s.core.close();
});

test("a_message_a_station_took_as_it_handed_its_chat_over_goes_once", async () => {
  const w = world();
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }];
  // Being handed over, A holds the chat and keeps what is said to it (sessions/hub.ts holdChat): it takes the message.
  w.reply = (station, method, path) => (station === "st" && method === "POST" && path === "/threads/7/messages" ? { n: 4 } : undefined);
  const s = await rig(w);
  subscribe(s.core, s.ui, 1, { topic: "chat", station: A, thread: 7, session: null });
  await settle(s.host);
  call(s.core, s.ui, 2, "chat.send", { station: A, thread: 7, text: "搬家时说的" });
  await settle(s.host);
  s.pushOn([AT, "st"], "chat-moved", movedTo("k1", "st2", 7, 21));
  await settle(s.host);
  const posts = w.sent.filter((x) => x.method === "POST" && x.path.endsWith("/messages"));
  assert.deepEqual(posts.map((x) => x.station), ["st"], "sent once, where it was taken");
  // What waits of it waits on B's copy as taken (its entry comes there), not sent again.
  assert.deepEqual(s.core.inner.views.local.outbox(B, 21).map((m: J) => [m.state, m.seq]), [["sent", 4]]);
  s.core.close();
});

test("a_chat_that_came_back_while_the_device_was_away_is_listed_where_it_is", async () => {
  const w = world();
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }];
  const first = await rig(w);
  first.pushOn([AT, "st"], "chat-moved", movedTo("k1", "st2", 7, 21));
  await settle(first.host);
  assert.deepEqual(first.core.inner.data.chatNow(A, { session: "k1" })?.station, B);
  first.core.close();
  // Away, it went and came back: A lists it again and names it no more as moved (`GET /moved`), B has none.
  const host = first.host;
  host.takeEmitted();
  const again = await rig(w, host);
  const values = new Map<number, unknown>();
  subscribe(again.core, again.ui, 1, { topic: "chats", scope: "ws" });
  await settle(host);
  apply(host, values);
  assert.deepEqual(listed(values, 1), [[A, "k1", "在 studio"]]);
  assert.equal(again.core.inner.data.chatNow(A, { session: "k1" }), null);
  again.core.close();
});

test("a_chat_moved_told_as_a_stream_comes_back_is_taken_as_one_told_live", async () => {
  const w = world();
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }];
  w.rows.st2 = [{ id: "k1", thread: 21, title: "在 mini", at: 3000 }];
  const s = await rig(w, undefined, (g) => {
    g.resumes = true;
    g.marks = true;
  });
  const values = new Map<number, unknown>();
  subscribe(s.core, s.ui, 1, { topic: "chats", scope: "ws" });
  await settle(s.host);
  const onA = (x: { headers?: [string, string][] }) => (x.headers ?? []).some(([k, v]) => k === AT && v === "st");
  const asked = () => s.host.requests.filter((r) => r.url.includes("/admin/api/moved?") && stationOf(r) === "st").length;
  const movedReads = asked();
  // A's stream goes; it comes back going on from where the device was in A's events, telling what it missed first.
  type Stream = { path: string; queue: Queue.Queue<Uint8Array | null>; closed: boolean; headers?: [string, string][] };
  const streams = (s as unknown as { streams: Stream[] }).streams;
  const first = streams.filter((x) => onA(x) && !x.closed).at(-1)!;
  Queue.offerUnsafe(first.queue, null);
  await s.host.time.pass(3_000, 50);
  await settle(s.host);
  const resumed = streams.filter((x) => onA(x) && !x.closed).at(-1)!;
  assert.ok(resumed !== first && resumed.path.includes("since="), "resumed");
  s.pushOn([AT, "st"], "chat-moved", movedTo("k1", "st2", 7, 21));
  await settle(s.host);
  apply(s.host, values);
  assert.deepEqual(listed(values, 1), [[B, "k1", "在 mini"]]);
  assert.equal(s.core.inner.data.chatNow(A, { thread: 7 })?.thread, 21);
  assert.equal(asked(), movedReads, "GET /moved not read again: the resumed stream told it");
  s.core.close();
});

/// A station's stream goes and comes back (going on from where the device was where `resumes`): what it shows asked
/// again (sync.ts #catchUpShown).
async function streamAgain(s: { host: FakeHost }, station: string) {
  type Stream = { path: string; queue: Queue.Queue<Uint8Array | null>; closed: boolean; headers?: [string, string][] };
  const streams = (s as unknown as { streams: Stream[] }).streams;
  const of = (x: Stream) => (x.headers ?? []).some(([k, v]) => k === AT && v === station);
  const first = streams.filter((x) => of(x) && !x.closed).at(-1)!;
  Queue.offerUnsafe(first.queue, null);
  await s.host.time.pass(3_000, 50);
  await settle(s.host);
  assert.ok(streams.filter((x) => of(x) && !x.closed).at(-1) !== first, "its stream back");
}

/// What went out of subscription `id` from now until the core is at rest, each message as JSON.
async function sentOf(host: FakeHost, id: number): Promise<string[]> {
  const out: string[] = [];
  for (let i = 0; i < 5; i++) {
    await host.settle();
    await host.time.pass(500);
    for (const [, m] of host.takeEmitted()) if ((m as J).id === id) out.push(JSON.stringify(m));
  }
  return out;
}

/// B's copy's thread (21) as B has it while the chat is not on it: none (`404`).
const goneOnB = (gone: () => boolean) => (station: string, method: string, path: string) => (gone() && station === "st2" && /^\/threads\/21(\/|\?|$)/.test(path) ? status(404, { error: "没有这个会话" }) : undefined);
const askedOfB = (host: FakeHost, from: number) => host.requests.slice(from).filter((r) => stationOf(r) === "st2" && r.url.includes("/threads/21/entries"));

test("a_chat_there_back_and_there_again_shows_its_messages_there_with_no_not_there_and_is_not_asked_of_a_station_that_said_it_went", async () => {
  const w = world();
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }];
  w.rows.st2 = [{ id: "k1", thread: 21, title: "在 mini", at: 3000 }];
  let gone = false;
  w.reply = goneOnB(() => gone);
  const s = await rig(w, undefined, (g) => {
    g.resumes = true;
    g.marks = true;
  });
  const page: Topic = { topic: "thread", station: A, thread: 7 };
  subscribe(s.core, s.ui, 1, page);
  await settle(s.host);
  s.pushOn([AT, "st"], "chat-moved", movedTo("k1", "st2", 7, 21));
  await settle(s.host);
  assert.equal(s.core.inner.data.chatNow(A, { thread: 7 })?.thread, 21);
  assert.ok(JSON.stringify(s.core.inner.store.value(page)).includes("m1"), "B's messages");
  // Back: B says it went to A, A that it came back; B has none of it now.
  gone = true;
  s.pushOn([AT, "st2"], "chat-moved", movedTo("k1", "st", 21, 7));
  s.pushOn([AT, "st"], "chat-moved", movedTo("k1", null, null, null));
  await settle(s.host);
  assert.equal(s.core.inner.data.chatNow(A, { thread: 7 }), null);
  // B's stream goes and comes back: what was shown of the chat there is asked where it is (A), never of B.
  const before = s.host.requests.length;
  await streamAgain(s, "st2");
  assert.deepEqual(askedOfB(s.host, before).map((r) => r.url), [], "not asked of the station that said it went");
  // There again: from the first value the page's topic shows its messages, never that the chat is not there.
  gone = false;
  s.host.takeEmitted();
  s.pushOn([AT, "st"], "chat-moved", movedTo("k1", "st2", 7, 21));
  s.pushOn([AT, "st2"], "chat-moved", movedTo("k1", null, null, null));
  const sent = await sentOf(s.host, 1);
  assert.deepEqual(sent.filter((m) => m.includes("http_404")), [], "never not there");
  const now = s.core.inner.store.value(page) as J;
  assert.ok(now !== undefined && "ok" in now && JSON.stringify(now).includes("m1"), JSON.stringify(now));
  s.core.close();
});

test("a_chat_whose_row_on_another_station_says_it_came_lets_go_of_a_not_there_kept_of_it_there", async () => {
  // B names the chat in nothing (no row, nothing said went: a station that never had it, or whose copy was retired),
  // and a page opened on its thread there (a notice of B's) was answered that it has none (kept: sync.ts #threadGone).
  const w = world();
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }];
  let gone = true;
  w.reply = goneOnB(() => gone);
  const s = await rig(w, undefined, (g) => {
    g.marks = true;
  });
  const page: Topic = { topic: "thread", station: A, thread: 7 };
  subscribe(s.core, s.ui, 1, page);
  subscribe(s.core, s.ui, 2, { topic: "thread", station: B, thread: 21 });
  await settle(s.host);
  assert.equal((s.core.inner.store.value({ topic: "thread", station: B, thread: 21 }) as J)?.err?.code, "http_404", "B said it has none");
  assert.equal(s.core.inner.data.chatNow(A, { thread: 7 }), null);
  // The chat comes to B, as B shows it (station store/store.ts showChat): its session and its rows changed, its row
  // saying it came from A; neither station says it moved.
  gone = false;
  const row = { id: "k1", thread: 21, title: "在 mini", at: 6000, from: "st" };
  w.rows.st2 = [row];
  s.host.takeEmitted();
  const of = chatsOf([rowOf(row)]);
  s.pushOn([AT, "st2"], "session", (of["GET /sessions"] as J[])[0]);
  s.pushOn([AT, "st2"], "chat-shared", (of["GET /chats?shared=1"] as J[])[0]);
  s.pushOn([AT, "st2"], "chat-changed", { thread: 21 });
  const sent = await sentOf(s.host, 1);
  const data = s.core.inner.data;
  assert.equal(data.chatNow(A, { thread: 7 })?.thread, 21, `on B, by its row's from: B's rows ${JSON.stringify(data.chatsOf(B, { thread: 21 }))}`);
  // The page's topic shows B's messages, never that the chat is not there.
  assert.deepEqual(sent.filter((m) => m.includes("http_404")), [], "never not there");
  const now = s.core.inner.store.value(page) as J;
  assert.ok(now !== undefined && "ok" in now && JSON.stringify(now).includes("m1"), JSON.stringify(now));
  s.core.close();
});

test("a_chat_whose_row_comes_before_its_summary_says_it_came_is_taken_as_come_the_same", async () => {
  // As the case before, the other way round: B's row first (its session's summary and its thread, nothing saying
  // where it came from), then its summary saying so. Both end the same: the chat on B by its thread there.
  const w = world();
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }];
  const s = await rig(w, undefined, (g) => {
    g.marks = true;
  });
  const page: Topic = { topic: "thread", station: A, thread: 7 };
  subscribe(s.core, s.ui, 1, page);
  await settle(s.host);
  const row = { id: "k1", thread: 21, title: "在 mini", at: 6000, from: "st" };
  w.rows.st2 = [{ ...row, from: undefined }];
  const first = chatsOf([rowOf({ ...row, from: undefined })]);
  s.pushOn([AT, "st2"], "session", (first["GET /sessions"] as J[])[0]);
  s.pushOn([AT, "st2"], "chat-shared", (first["GET /chats?shared=1"] as J[])[0]);
  s.pushOn([AT, "st2"], "chat-changed", { thread: 21 });
  await settle(s.host);
  const data = s.core.inner.data;
  assert.equal(data.chatsOf(B, { thread: 21 }).length, 1, "B's row first");
  assert.equal(data.chatNow(A, { thread: 7 }), null, `not yet: nothing says it came (B's rows ${JSON.stringify(data.chatsOf(B, { thread: 21 }))})`);
  w.rows.st2 = [row];
  s.pushOn([AT, "st2"], "session", (chatsOf([rowOf(row)])["GET /sessions"] as J[])[0]);
  await settle(s.host);
  assert.deepEqual(data.chatNow(A, { thread: 7 }), { station: B, session: "k1", thread: 21 }, `B's rows ${JSON.stringify(data.chatsOf(B, { thread: 21 }))}, A's said ${JSON.stringify(data.moved(A, "k1"))}`);
  const now = s.core.inner.store.value(page) as J;
  assert.ok(now !== undefined && "ok" in now && JSON.stringify(now).includes("m1"), JSON.stringify(now));
  s.core.close();
});

test("a_not_there_read_before_the_station_it_left_said_so_goes_as_it_says_the_chat_came_back", async () => {
  // Back on A, B's stream away as it went: A said it came back, B nothing yet, so B is asked of its thread (it was
  // shown) and has none (kept). B's stream back tells it went; then it comes to B again, B saying so (`chat-moved`, no
  // station: station/src/store/store.ts showChat).
  const w = world();
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }];
  w.rows.st2 = [{ id: "k1", thread: 21, title: "在 mini", at: 3000 }];
  let gone = false;
  w.reply = goneOnB(() => gone);
  const s = await rig(w, undefined, (g) => {
    g.resumes = true;
    g.marks = true;
  });
  const page: Topic = { topic: "thread", station: A, thread: 7 };
  subscribe(s.core, s.ui, 1, page);
  await settle(s.host);
  s.pushOn([AT, "st"], "chat-moved", movedTo("k1", "st2", 7, 21));
  await settle(s.host);
  gone = true;
  s.pushOn([AT, "st"], "chat-moved", movedTo("k1", null, null, null));
  await settle(s.host);
  const before = s.host.requests.length;
  await streamAgain(s, "st2");
  assert.ok(askedOfB(s.host, before).length > 0, "asked of B, which had said nothing");
  s.pushOn([AT, "st2"], "chat-moved", movedTo("k1", "st", 21, 7));
  await settle(s.host);
  gone = false;
  s.host.takeEmitted();
  s.pushOn([AT, "st"], "chat-moved", movedTo("k1", "st2", 7, 21));
  s.pushOn([AT, "st2"], "chat-moved", movedTo("k1", null, null, null));
  const sent = await sentOf(s.host, 1);
  assert.equal(s.core.inner.data.chatNow(A, { thread: 7 })?.thread, 21, "on B again");
  assert.deepEqual(sent.filter((m) => m.includes("http_404")), [], "never not there");
  const now = s.core.inner.store.value(page) as J;
  assert.ok(now !== undefined && "ok" in now && JSON.stringify(now).includes("m1"), JSON.stringify(now));
  s.core.close();
});
