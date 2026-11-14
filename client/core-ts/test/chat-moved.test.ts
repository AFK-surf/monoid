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
import { base, chatsOf, entry, started, stationReplies, status } from "./station-fixture.ts";

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
  sent: { station: string; method: string; path: string; body: J }[];
  reply: (station: string, method: string, path: string, body: J) => unknown;
};

function world(): World {
  return { rows: { st: [], st2: [] }, moved: { st: [], st2: [] }, off: new Set(), sent: [], reply: () => undefined };
}

const stationOf = (req: HttpRequest) => req.headers.find(([k]) => k === AT)?.[1] ?? "st";

async function rig(w: World, host?: FakeHost) {
  const wire = (h: FakeHost) => {
    const inner = new HostWire(h);
    return {
      request: (station: StationAddr, head: RequestHead, body: Uint8Array) =>
        w.off.has(station.station) ? Effect.fail(new CoreError("mesh", "unreached")) : inner.request(station, { ...head, headers: [...head.headers, [AT, station.station]] }, body),
    } as StationWire;
  };
  const answer = (x: { host: FakeHost; cloud: { also?: Record<string, unknown> } }) => {
    // (as the cloud lists them each time it is asked: A down once it is off)
    Object.defineProperty(x.cloud, "also", { get: () => ({ stations: [{ id: "st", name: "studio", online: !w.off.has("st"), last_seen: null }, { id: "st2", name: "mini", online: true, last_seen: null }] }) });
    stationReplies(x.host, (req: HttpRequest) => {
      const who = stationOf(req);
      const path = req.url.replace("https://stillfail.test/admin/api", "");
      const body = req.body && req.body.length > 0 ? JSON.parse(new TextDecoder().decode(req.body)) : null;
      if (req.method !== "GET" && !path.startsWith("/changed/") && path !== "/batch") w.sent.push({ station: who, method: req.method, path, body });
      const said = w.reply(who, req.method, path, body);
      if (said !== undefined) return said;
      if (req.method === "GET" && path.startsWith("/moved?")) {
        const after = new URL(`https://x${path}`).searchParams.get("after") ?? "";
        return { moved: w.moved[who]!.filter((m) => m.session > after) };
      }
      // (each chat's one message, as its row says it goes to 1)
      const entries = /^\/threads\/(\d+)\/entries\?/.exec(path);
      if (req.method === "GET" && entries) return { last: 1, entries: [{ ...entry(1, "m1"), thread: Number(entries[1]) }] };
      const of = chatsOf(w.rows[who]!.map(rowOf));
      const asked = `${req.method} ${path}`;
      return asked in of ? of[asked] : undefined;
    });
  };
  if (host === undefined) {
    const s = await started(base(), 0, wire, answer);
    return { ...s, ui: s.core.connect() };
  }
  // (a core started anew on the same device: its database as the last left it, the stations as they are now)
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

test("a_chat_open_when_it_moves_goes_on_where_it_is_with_its_draft", async () => {
  const w = world();
  w.rows.st = [{ id: "k1", thread: 7, title: "在 studio", at: 5000 }];
  // (B has its copy already, as one being put in: older, so A's is the one shown)
  w.rows.st2 = [{ id: "k1", thread: 21, title: "在 mini", at: 3000 }];
  const s = await rig(w);
  const values = new Map<number, unknown>();
  subscribe(s.core, s.ui, 1, { topic: "chat", station: A, thread: 7, session: null });
  s.core.inner.data.set({ topic: "draft", station: A, chat: "k1" }, { text: "写了一半" }, false);
  await settle(s.host);
  apply(s.host, values);
  assert.equal(v(values, 1)?.title, "在 studio");
  // Handed over: A says it went.
  s.pushOn([AT, "st"], "chat-moved", movedTo("k1", "st2", 7, 21));
  await settle(s.host);
  apply(s.host, values);
  // The page goes on, its copy on B shown, its thread as the page names it (what it sends is aimed at B).
  assert.equal(v(values, 1)?.title, "在 mini");
  assert.equal(v(values, 1)?.thread?.id, 7);
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
  call(s.core, s.ui, 2, "chat.send", { station: A, thread: 7, text: "接着做" });
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
