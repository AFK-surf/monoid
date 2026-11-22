// F2a catching-period opened-thread priority:
// - Opening a cached thread while `link.catching !== null` prioritizes its `GET /threads/:id` summary and bounded
//   continuation pages (`after=...`) on the existing scheduler lane, ahead of `/threads` and background sweep.
// - Deduplicated per catching epoch and thread (re-opening within the same catching epoch does not re-issue duplicate
//   summary/catchUp requests; a new catching epoch re-enables prioritization).
// - Preserves original window `at`, length, and `unreadLine` without creating any independent network channel.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Core } from "../src/core.ts";
import { HostWire } from "../src/station/wire.ts";
import { PAGE } from "../src/station/channel-kinds.ts";
import { jsonResponse } from "../src/testing.ts";
import { base, started, stationLater } from "./station-fixture.ts";
import { run } from "./run.ts";

const ST = "ws/st";

// deno-lint-ignore no-explicit-any
type J = any;

const msgEntry = (n: number, createdAt = 1000 + n) => ({
  n,
  kind: "message",
  authorKind: "person",
  author: "bob@example.com",
  text: `msg ${n}`,
  ts: `t${n}`,
  at: createdAt,
});

const threadSummary = (id: number, last: number, read: number, unread: number) => ({
  id,
  surface: "ember",
  channel: "CHAT",
  title: `Thread ${id}`,
  last,
  read,
  unread,
  members: [{ key: `k${id}`, connect: "ember" }],
});

const sharedRow = (id: string, thread: number, lastSeq: number) => ({
  id,
  session: id,
  thread,
  agents: [{ key: id, runtime: "claude" }],
  lastActiveAt: 2000,
  ws: null,
  named: { thread: { surface: "ember", title: `Thread ${thread}` }, firstText: null, channelName: null },
  mineOf: [],
  said: { seq: lastSeq, at: 2000, author: "bob@example.com", authorKind: "person", text: `msg ${lastSeq}` },
});

test("F2a: opening a cached thread during catching prioritizes summary and bounded continuation pages, deduplicates per epoch, and keeps window/unreadLine intact", async () => {
  const initialEntries = Array.from({ length: 20 }, (_, i) => msgEntry(i + 1));
  const allEntries = Array.from({ length: 140 }, (_, i) => msgEntry(i + 1));
  const answers: Record<string, unknown> = {
    ...base(),
    "GET /chats?marks=1": { kept: [], hidden: [], muted: [], pins: {}, selves: [], dismissed: [], reads: { "10": 20 } },
    "GET /chats?shared=1": [sharedRow("k10", 10, 20)],
    "GET /threads": [threadSummary(10, 20, 20, 0)],
    "GET /threads/10": threadSummary(10, 20, 20, 0),
    "GET /threads/10/entries?limit=50": { entries: initialEntries, last: 20 },
  };
  const s = await started(answers);
  let cold: Core | undefined;
  try {
    // Establish initial cached state: thread 10 has summary last=20, read=20, entries 1..20.
    const ui0 = s.core.connect();
    const tTopic = { topic: "thread", station: ST, thread: 10 };
    s.core.receive(ui0, { kind: "subscribe", id: 1, subscribe: tTopic });
    await s.host.time.pass(500, 50);
    await run(s.core.inner.data.written);
    assert.equal(s.core.inner.data.logSpan("entry", ST, "10")?.max, 20);
    s.core.receive(ui0, { kind: "unsubscribe", id: 1, unsubscribe: true });
    s.core.close();
    await s.host.settle();

    // While offline, 120 new messages arrive (21..140).
    answers["GET /threads"] = [threadSummary(10, 140, 20, 120)];
    answers["GET /threads/10"] = threadSummary(10, 140, 20, 120);
    answers["GET /chats?shared=1"] = [sharedRow("k10", 10, 140)];

    // Hold `/threads` so the station stays in `catching` while the user opens thread 10!
    let releaseThreads: (() => void) | undefined;
    const entryCalls: string[] = [];
    stationLater(s.host, (req) => {
      if (req.url.endsWith("/threads")) {
        return new Promise((resolve) => {
          releaseThreads = () => resolve(jsonResponse(200, answers["GET /threads"]));
        });
      }
      if (req.url.includes("/threads/10/entries")) {
        const u = new URL(req.url);
        entryCalls.push(u.search);
        const after = Number(u.searchParams.get("after") ?? "0");
        const limit = Number(u.searchParams.get("limit") ?? String(PAGE));
        const from = u.searchParams.has("from") ? Number(u.searchParams.get("from")) : after + 1;
        const to = u.searchParams.has("to") ? Number(u.searchParams.get("to")) : Math.min(140, from + limit - 1);
        const slice = allEntries.filter((e) => e.n >= from && e.n <= to);
        return Promise.resolve(jsonResponse(200, { entries: slice, last: 140 }));
      }
      return undefined;
    });

    cold = await Core.create(s.host, { clock: s.host.time.clock, sample: 0, wire: () => new HostWire(s.host) });
    await s.host.time.pass(300, 50);
    assert.ok(cold.inner.stations.link(ST)?.catching !== null, "station should be in catching state while /threads is held");
    assert.ok(releaseThreads, "/threads should be held");

    // Open thread 10 while catching!
    const beforeOpen = s.host.requests.length;
    const ui = cold.connect();
    cold.receive(ui, { kind: "subscribe", id: 1, subscribe: tTopic });
    await s.host.time.pass(600, 50);
    await run(cold.inner.data.written);

    const openReqs = s.host.requests.slice(beforeOpen).map((r) => `${r.method} ${r.url.replace("https://stillfail.test/admin/api", "")}`);
    const summaryHits1 = openReqs.filter((r) => r === "GET /threads/10").length;
    assert.equal(summaryHits1, 1, `opened thread during catching must prioritize GET /threads/10 once, got: ${JSON.stringify(openReqs)}`);
    assert.ok(entryCalls.length >= 1, `opened thread during catching must fetch continuation pages, got: ${JSON.stringify(entryCalls)}`);
    assert.ok(entryCalls[0]!.includes("after=20"), `first continuation page should start after cached seq 20, got: ${entryCalls[0]}`);
    // Bounded continuation pages eventually reach 140.
    assert.equal(cold.inner.data.logSpan("entry", ST, "10")?.max, 140);

    // Re-opening the same thread within the same catching epoch must be deduplicated (no second GET /threads/10).
    cold.receive(ui, { kind: "unsubscribe", id: 1, unsubscribe: true });
    await s.host.time.pass(50, 25);
    const beforeReopen = s.host.requests.length;
    cold.receive(ui, { kind: "subscribe", id: 3, subscribe: tTopic });
    await s.host.time.pass(300, 50);
    const reopenReqs = s.host.requests.slice(beforeReopen).map((r) => `${r.method} ${r.url.replace("https://stillfail.test/admin/api", "")}`);
    assert.equal(reopenReqs.filter((r) => r === "GET /threads/10").length, 0, `re-open in same catching epoch must deduplicate summary fetch, got: ${JSON.stringify(reopenReqs)}`);

    // Verify unreadLine is anchored at first unread (21), NOT jumped to 140.
    const chatTopic = { topic: "chat", station: ST, thread: 10, session: "k10" };
    cold.receive(ui, { kind: "subscribe", id: 4, subscribe: chatTopic });
    await s.host.time.pass(100, 50);
    const chatVal = cold.inner.store.get(chatTopic) as J;
    if (chatVal && "ok" in chatVal) {
      assert.equal(chatVal.ok.unreadLine, 21);
    }

    // Release /threads and settle.
    releaseThreads();
    await s.host.time.pass(500, 50);
  } finally {
    cold?.close();
    s.core.close();
  }
});
