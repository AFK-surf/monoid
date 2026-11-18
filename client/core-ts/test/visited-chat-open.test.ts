// A chat opened again whose station went on while the device was away (read on another device, the app closed): what
// the device holds of it ends short of its latest. A page or more short, its latest page is read in one read and the
// chat opens there, what is between coming after, its highest first, without the chat being made again for it; less
// than a page short, it opens at once on what is held and what came after joins it in one read; its station down, it
// opens at once on what is held, saying the chat goes on after it (topics.ts #opening, #thread).
import assert from "node:assert/strict";
import { test } from "node:test";
import { Core } from "../src/core.ts";
import { HostError } from "../src/error.ts";
import type { HttpResponse } from "../src/host-of.ts";
import { HostWire } from "../src/station/wire.ts";
import { jsonResponse } from "../src/testing.ts";
import { work } from "../src/work.ts";
import { apply, call, subscribe, v } from "./helpers.ts";
import { run } from "./run.ts";
import { base, entries, started, stationLater, threadView } from "./station-fixture.ts";

const ST = "ws/st";

/// A device that read entries `held` of chat 7 and was then told its station's summary of it (`summary`); a core
/// started again on it, its station answering `?after=` a page at most and `from..to` as asked, `hold` deciding which
/// reads wait to be let go.
async function visited(held: [number, number], summary: { last: number; read: number; unread: number }, opts: { down?: boolean; goesDown?: boolean; hold?: (q: URLSearchParams) => boolean } = {}) {
  const answers = base();
  answers["GET /threads"] = [threadView(7, held[1])];
  answers["GET /threads/7/entries?limit=50"] = { last: held[1], entries: entries(held[0], held[1]) };
  const state = { setup: true, down: false, hang: false };
  const asked: string[] = [];
  const waiting: (() => void)[] = [];
  const s = await started(answers, 0, undefined, (f) => {
    stationLater(f.host, (req) => {
      if (state.down && req.url.includes("/admin/api")) return Promise.reject(new HostError("连不上"));
      if (!req.url.includes("/threads/7/entries?")) return undefined;
      if (state.setup) return undefined;
      if (state.hang) return new Promise<HttpResponse>(() => {});
      const q = new URL(req.url).searchParams;
      asked.push(new URL(req.url).search.slice(1));
      const last = summary.last;
      const answer = (): HttpResponse => {
        if (q.has("after")) {
          const after = Number(q.get("after"));
          const limit = Number(q.get("limit") ?? 50);
          return jsonResponse(200, { last, entries: after >= last ? [] : entries(after + 1, Math.min(last, after + limit)) });
        }
        if (q.has("from")) return jsonResponse(200, { last, entries: entries(Number(q.get("from")), Math.min(last, Number(q.get("to")))) });
        return jsonResponse(200, { last, entries: entries(Math.max(1, last - 49), last) });
      };
      if (opts.hold?.(q)) return new Promise((resolve) => waiting.push(() => resolve(answer())));
      return Promise.resolve(answer());
    });
  });
  await s.host.time.pass(1000, 50);
  const span = s.core.inner.data.logSpan("entry", ST, "7");
  assert.deepEqual([span?.min, span?.max], held);
  // Told the chat went on, nothing of it read since: so the device holds it as the app closes.
  state.setup = false;
  answers["GET /threads"] = [threadView(7, summary.last, summary.read, summary.unread)];
  s.core.inner.data.putThread(ST, threadView(7, summary.last, summary.read, summary.unread));
  await run(s.core.inner.data.written);
  s.core.close();
  await s.host.settle();
  if (opts.goesDown) {
    // (not reached, not yet found down: its stream's try and the chat's reads hang)
    state.hang = true;
    s.gate.stream = "hang";
  }
  if (opts.down) {
    state.down = true;
    s.gate.stream = "fail";
  }
  const core = await Core.create(s.host, { clock: s.host.time.clock, sample: 0, wire: () => new HostWire(s.host) });
  if (opts.down) {
    await s.host.time.pass(60_000, 1000);
    assert.equal((core.inner.stations.link(ST)?.state as { state: string }).state, "offline");
  }
  s.host.takeEmitted();
  asked.length = 0;
  const ui = core.connect();
  const values = new Map();
  call(core, ui, 9, "chat.window", { station: ST, thread: 7, rows: 20 });
  const open = () => {
    subscribe(core, ui, 1, { topic: "chat", station: ST, thread: 7, session: null });
    subscribe(core, ui, 2, { topic: "thread", station: ST, thread: 7 });
  };
  const shown = () => {
    apply(s.host, values);
    return { chat: v(values, 1), thread: v(values, 2) };
  };
  /// Lets the reads held go, one at a time, each answered before the next is let go; those it brings after too.
  const release = async () => {
    while (waiting.length > 0) {
      waiting.shift()!();
      await s.host.time.pass(200, 10);
    }
  };
  /// Its station found down from now on: nothing of it answers.
  const goDown = () => {
    state.hang = false;
    state.down = true;
    s.gate.stream = "fail";
  };
  return { ...s, core, asked, open, shown, release, waiting, goDown };
}

const seqs = (chat: { messages: { seq: number }[] } | undefined) => chat?.messages.map((m) => m.seq) ?? [];

test("a_chat_opened_a_page_or_more_behind_reads_its_latest_page_once_and_opens_there_what_is_between_coming_after_unshown", async () => {
  // Held 1..20, its station at 200, all read elsewhere. What is between (21..150) waits to be let go.
  const r = await visited([1, 20], { last: 200, read: 200, unread: 0 }, { hold: () => true });
  try {
    r.open();
    await r.host.time.pass(1000, 10);
    assert.equal(r.shown().chat, undefined, "not opened on what is held, a page after a page to come after it");
    assert.deepEqual(r.asked, ["from=151&to=200"], "its latest page in one read, nothing asked after 20");
    // Its latest page come: open there.
    r.waiting.shift()!();
    await r.host.time.pass(200, 10);
    const opened = r.shown();
    assert.equal(seqs(opened.chat).at(-1), 200);
    assert.ok(opened.chat.messages.length <= 50, `opened on ${opened.chat.messages.length}`);
    assert.ok(opened.thread.first >= 151 && opened.thread.end === true, JSON.stringify([opened.thread.first, opened.thread.end]));
    // What is between: its highest first, nothing of the chat shown sent again for it. (Its page is made again as its
    // log changes, a log being read whole as one: once for each page come, its value found the same.)
    const chats = work.chats;
    await r.release();
    await r.host.time.pass(1000, 10);
    assert.deepEqual(r.asked, ["from=151&to=200", "from=101&to=150", "from=51&to=100", "from=21&to=50"]);
    assert.equal(r.core.inner.data.logCount("entry", ST, "7", 1, 200), 200);
    const sent = r.host.takeEmitted().filter(([, m]) => (m as { id?: number }).id === 1);
    assert.deepEqual(sent, [], "the chat shown sent nothing for what came before its window");
    assert.ok(work.chats - chats <= 3, `made again ${work.chats - chats} times`);
  } finally {
    r.core.close();
  }
});

test("a_chat_opened_less_than_a_page_behind_opens_at_once_on_what_is_held_and_what_came_after_joins_it_in_one_read", async () => {
  const r = await visited([1, 100], { last: 110, read: 110, unread: 0 }, { hold: () => true });
  try {
    r.open();
    await r.host.settle();
    assert.equal(seqs(r.shown().chat).at(-1), 100, "at once, on what is held");
    await r.release();
    await r.host.time.pass(1000, 10);
    assert.deepEqual(r.asked, ["after=100&limit=50"]);
    assert.equal(seqs(r.shown().chat).at(-1), 110);
  } finally {
    r.core.close();
  }
});

test("a_chat_opened_a_page_or_more_behind_while_its_station_is_down_opens_at_once_on_what_is_held_and_goes_on_after_it", async () => {
  for (const [read, unread] of [[200, 0], [195, 5]]) {
    const r = await visited([1, 20], { last: 200, read, unread }, { down: true });
    try {
      r.open();
      await r.host.settle();
      const { chat, thread } = r.shown();
      assert.deepEqual(seqs(chat), entries(1, 20).map((e) => e.n), `unread ${unread}: what is held, at once`);
      assert.equal(chat.newer, true, `unread ${unread}: the chat goes on after it`);
      assert.equal(thread.end, false);
    } finally {
      r.core.close();
    }
  }
});

test("a_chat_waiting_on_its_latest_page_opens_on_what_is_held_once_its_station_is_found_down", async () => {
  // Its station not reached as the app opens, not yet found down: the chat waits on its latest page; found down (a
  // while later, nothing else changing), it opens on what is held as it would have, opened then.
  const r = await visited([1, 20], { last: 200, read: 200, unread: 0 }, { goesDown: true });
  try {
    r.open();
    await r.host.time.pass(1000, 50);
    assert.notEqual((r.core.inner.stations.link(ST)?.state as { state: string }).state, "offline");
    assert.equal(r.shown().chat, undefined, "not found down yet: it waits on its latest page");
    r.goDown();
    for (let waited = 0; (r.core.inner.stations.link(ST)?.state as { state: string }).state !== "offline" && waited < 120_000; waited += 1000) await r.host.time.pass(1000, 250);
    await r.host.time.pass(500, 50);
    const { chat, thread } = r.shown();
    assert.deepEqual(seqs(chat), entries(1, 20).map((e) => e.n), "found down: what is held");
    assert.equal(chat.newer, true);
    assert.equal(thread.end, false);
  } finally {
    r.core.close();
  }
});
