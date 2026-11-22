// Merged Slack-thread conversations in the client core (slack-thread-merge-design-v3.md §5):
// - resolving non-anchor session links via summary/detail `conv` (warm cache, cold missing from list, archived)
// - multi-agent unchatted page subscribing all agents' session/live and merging their `elsewhere` sorted by time
// - optimistic archive/restore/pin/rename issued with a non-anchor key applying to the conversation's row
// - `pin` incremental events and `@` menu (`refs.search`) matching by `agents[].key`
// - `rows-changed` when a second agent joins: one row patched + one row removed
import assert from "node:assert/strict";
import { test } from "node:test";
import * as refs from "../src/refs.ts";
import { call, subscribe } from "./helpers.ts";
import { base, started, stationLater, stationReplies } from "./station-fixture.ts";
import { overview, rows, sessions, setup, threads, ui, workspace } from "./views-rig.ts";

// deno-lint-ignore no-explicit-any
type J = any;

const ST = "ws/st";

const agentPage = (station: string, session: string) => ({ topic: "chat" as const, station, thread: null, session });
const connect = (id: string, name: string): J => ({ id, kind: "slack", name, mode: "multi-session", requireMention: true, bind: { runtime: "claude" } });
const fullSession = (key: string, patch: J = {}): J => ({
  key, connect: "c1", scope: "thread", title: null, createdBy: null, boundTo: [], creator: null, participants: [], runtime: "claude", profile: "p1",
  profilePinned: false, model: null, effort: null, runtimeSessionId: null, workspace: "/w", running: false, createdAt: 1, lastActiveAt: 1, archivedAt: null,
  process: "cold", turns: 0, pending: 0, firstText: null, lastTurn: null, ...patch,
});
const overviewOf = (connects: J[], profiles: J[]): J => ({
  viewer: { via: "local" }, connects, profiles, processes: [], counts: { sessions: 0, running: 0, warm: 0 }, mesh: null, slackUsers: [], slackTeams: [], slackApps: [], disk: null, logins: [],
});

function mergedRow(anchor: string, other: string, extra: Record<string, unknown> = {}): J {
  return {
    id: anchor,
    session: anchor,
    thread: null,
    title: "Slack 多 agent 讨论",
    unread: false,
    mine: true,
    lastActiveAt: 1000,
    connect: "ember",
    origin: { teamName: "Acme", channel: "C0OPS", channelName: "ops", threadTs: "1.5", surface: "slack:T1" },
    agents: [
      { key: anchor, runtime: "claude", model: "claude-opus-5-5", effort: "high", process: "warm", pending: 0 },
      { key: other, runtime: "codex", model: "gpt-6-astra", effort: "high", process: "warm", pending: 0 },
    ],
    mineOf: [{ id: "a@x.com", email: "a@x.com" }],
    said: null,
    ...extra,
  };
}

test("non-anchor link resolves to anchor row from warm cache (unchatted and chatted)", async () => {
  const t = setup();
  const c1 = { ...connect("ember", "Claude-Ember"), connection: { state: "connected", botUserId: "UB1", workspace: { url: "https://acme.slack.com/", teamId: "T1" } } };
  const c2 = { ...connect("gemini", "Gemini-Monoid"), connection: { state: "connected", botUserId: "UB2", workspace: { url: "https://acme.slack.com/", teamId: "T1" } } };
  t.set(workspace(), { id: "ws", name: "W", role: "owner", stations: [{ id: "a", name: "A", online: true }], members: [] });
  t.set(overview("ws/a"), overviewOf([c1, c2], []));
  t.set(sessions("ws/a"), [
    fullSession("k1", { connect: "ember" }),
    fullSession("k2", { connect: "gemini", conv: "k1" }),
  ]);
  t.set(rows("ws/a"), [mergedRow("k1", "k2")]);
  t.set(threads("ws/a"), []);

  // Opening the non-anchor session key opens the merged multi-agent unchatted page of anchor k1.
  const u = ui();
  t.subscribe(1, agentPage("ws/a", "k2"));
  await t.read(u, 1);
  assert.equal(u.value.title, "Slack 多 agent 讨论");
  assert.deepEqual(u.value.agents.map((a: J) => a.session.key), ["k1", "k2"]);

  // chatRow for non-anchor key resolves to the anchor row too.
  const rowUi = ui();
  t.subscribe(2, { topic: "chatRow", station: "ws/a", session: "k2" });
  await t.read(rowUi, 2);
  assert.equal(rowUi.value?.id, "k1");

  // Once the conversation has a chat thread, boundThread(k2) resolves to that thread.
  t.set(rows("ws/a"), [mergedRow("k1", "k2", { thread: 42 })]);
  assert.equal(t.views.boundThread("ws/a", "k2"), 42);
});

test("cold link to a non-anchor session not in local lists resolves via detail conv to anchor page", async () => {
  const anchorSummary = fullSession("k1", { connect: "ember", title: "锚点会话", archivedAt: null });
  const otherSummary = fullSession("k2", { connect: "gemini", conv: "k1", title: "锚点会话", archivedAt: null });
  const s = await started({
    ...base(),
    "GET /chats?shared=1": [],
    "GET /sessions": [],
    "GET /threads": [],
    "GET /sessions/k2": { session: otherSummary, threads: [], turns: [], jobs: [] },
    "GET /sessions/k1": { session: anchorSummary, threads: [{ id: 77, surface: "ember", channel: "CHAT", threadTs: "77.0", title: "锚点会话", createdAt: 100, sessions: [{ thread: 77, session: "k1", connect: "ember", joinedAt: 100 }, { thread: 77, session: "k2", connect: "gemini", joinedAt: 101 }], last: 1, read: 0, unread: 1, people: [] }], turns: [], jobs: [] },
    "GET /threads/77": { id: 77, surface: "ember", channel: "CHAT", threadTs: "77.0", title: "锚点会话", createdAt: 100, sessions: [{ thread: 77, session: "k1", connect: "ember", joinedAt: 100 }, { thread: 77, session: "k2", connect: "gemini", joinedAt: 101 }], last: 1, read: 0, unread: 1, people: [] },
  }, 0, undefined, (s) => {
    stationReplies(s.host, (req) => {
      const path = req.url.replace("https://stillfail.test/admin/api", "");
      if (req.method === "GET" && path.startsWith("/threads/77/entries")) {
        return { first: 1, last: 1, entries: [{ thread: 77, n: 1, kind: "message", ts: "77.1", authorKind: "person", author: "a@x.com", authorName: "A", text: "你好", attachments: [], quotes: [], at: 100 }], end: true };
      }
      return undefined;
    });
  });
  try {
    await s.host.time.pass(2000, 100);
    const uiId = s.core.connect();
    subscribe(s.core, uiId, 1, { topic: "chat", station: ST, thread: null, session: "k2" });
    await s.host.time.pass(3000, 100);
    const val = s.core.inner.store.value({ topic: "chat", station: ST, thread: null, session: "k2" });
    assert.ok(val && "ok" in val, `expected chat value, got ${JSON.stringify(val)}`);
    assert.equal((val.ok as J).thread?.id, 77);
    assert.deepEqual((val.ok as J).agents.map((a: J) => a.session.key), ["k1", "k2"]);
  } finally {
    s.core.close();
  }
});

test("cold link to an archived non-anchor session resolves to archived anchor conversation", async () => {
  const anchorSummary = fullSession("k1", { connect: "ember", title: "已归档的合并对话", archivedAt: 5000 });
  const otherSummary = fullSession("k2", { connect: "gemini", conv: "k1", title: "已归档的合并对话", archivedAt: 5000 });
  const archivedRow = mergedRow("k1", "k2", { title: "已归档的合并对话", archived: { at: 5000, by: "a@x.com", alone: false } });
  const s = await started({
    ...base(),
    "GET /chats?shared=1": [],
    "GET /chats?archived=1": [archivedRow],
    "GET /sessions": [],
    "GET /threads": [],
    "GET /sessions/k2": { session: otherSummary, threads: [], turns: [], jobs: [] },
    "GET /sessions/k1": { session: anchorSummary, threads: [], turns: [], jobs: [] },
  });
  try {
    await s.host.time.pass(2000, 100);
    // Load archive into local DB as if the archive had been opened before.
    s.core.inner.data.set({ topic: "archivedRows", station: ST }, [archivedRow]);
    const uiId = s.core.connect();
    subscribe(s.core, uiId, 1, { topic: "chat", station: ST, thread: null, session: "k2" });
    await s.host.time.pass(3000, 100);
    const val = s.core.inner.store.value({ topic: "chat", station: ST, thread: null, session: "k2" });
    assert.ok(val && "ok" in val, `expected archived chat value, got ${JSON.stringify(val)}`);
    assert.equal((val.ok as J).archived, true);
    assert.equal((val.ok as J).title, "已归档的合并对话");
    assert.deepEqual((val.ok as J).agents.map((a: J) => a.session.key), ["k1", "k2"]);
  } finally {
    s.core.close();
  }
});

test("unchatted multi-agent page subscribes all agents and merges their elsewhere chronologically", async () => {
  const t = setup();
  const mia = { id: "slack:ember:U9", name: "Mia", email: null, via: "slack" };
  const c1 = { ...connect("ember", "Claude-Ember"), connection: { state: "connected", botUserId: "UB1", workspace: { url: "https://acme.slack.com/", teamId: "T1" } } };
  const c2 = { ...connect("gemini", "Gemini-Monoid"), connection: { state: "connected", botUserId: "UB2", workspace: { url: "https://acme.slack.com/", teamId: "T1" } } };
  t.set(workspace(), { id: "ws", name: "W", role: "owner", stations: [{ id: "a", name: "A", online: true }], members: [] });
  t.set(overview("ws/a"), overviewOf([c1, c2], []));
  t.set(sessions("ws/a"), [
    fullSession("k1", { connect: "ember", participants: [mia] }),
    fullSession("k2", { connect: "gemini", conv: "k1", participants: [mia] }),
  ]);
  t.set(rows("ws/a"), [mergedRow("k1", "k2")]);
  t.set(threads("ws/a"), []);

  const call = (tool: string, args: J, at: string, callId: string) => ({ at, kind: "tool_call", tool, text: JSON.stringify(args), callId });
  t.data.putItems("transcript", "ws/a", "k1", [
    [0, { at: "1970-01-01T00:00:01Z", kind: "user", text: '<message via="slack" thread="C0OPS/1.5" from="Mia (U9)" ts="1.5">帮我看下</message>' }],
    [1, call("mcp__stillfail__chat_post", { to: "C0OPS/1.5", text: "Claude 回复" }, "1970-01-01T00:00:03Z", "c1")],
    [2, { at: "1970-01-01T00:00:03Z", kind: "tool_result", text: "posted", ok: true, callId: "c1" }],
  ]);
  t.data.putItems("transcript", "ws/a", "k2", [
    [0, { at: "1970-01-01T00:00:01Z", kind: "user", text: '<message via="slack" thread="C0OPS/1.5" from="Mia (U9)" ts="1.5">帮我看下</message>' }],
    [1, call("mcp__stillfail__chat_post", { to: "C0OPS/1.5", text: "Gemini 回复" }, "1970-01-01T00:00:02Z", "c2")],
    [2, { at: "1970-01-01T00:00:02Z", kind: "tool_result", text: "posted", ok: true, callId: "c2" }],
  ]);

  const u = ui();
  t.subscribe(1, agentPage("ws/a", "k1"));
  await t.read(u, 1);

  // Both agents' session and live topics must be started by #sources.
  const startedKeys = t.router.started.map((x) => `${x.topic}:${x.key ?? ""}`);
  assert.ok(startedKeys.includes("session:k1") && startedKeys.includes("live:k1"), `missing k1 sources: ${startedKeys}`);
  assert.ok(startedKeys.includes("session:k2") && startedKeys.includes("live:k2"), `missing k2 sources: ${startedKeys}`);

  const v = u.value;
  assert.deepEqual(v.agents.map((a: J) => a.session.key), ["k1", "k2"]);
  assert.deepEqual(
    v.elsewhere.map((e: J) => [e.text, e.received ?? false]),
    [
      ["帮我看下", true],
      ["Gemini 回复", false],
      ["Claude 回复", false],
    ],
  );
});

test("optimistic archive, restore, pin, and rename via non-anchor key apply to the anchor row", async () => {
  const row = mergedRow("k1", "k2");
  const s = await started({
    ...base(),
    "GET /chats?shared=1": [row],
    "GET /sessions": [
      fullSession("k1", { connect: "ember" }),
      fullSession("k2", { connect: "gemini", conv: "k1" }),
    ],
    "GET /threads": [],
  });
  // Hold write requests so we can observe the optimistic state before the station replies.
  const pending: (() => void)[] = [];
  stationLater(s.host, (req) => {
    if (req.method === "POST" || req.method === "PUT" || req.method === "PATCH") {
      return new Promise((resolve) => {
        pending.push(() => resolve({ status: 200, headers: [["content-type", "application/json"]], body: new TextEncoder().encode("{}") }));
      });
    }
    return undefined;
  });
  try {
    await s.host.time.pass(2000, 100);
    const uiId = s.core.connect();
    subscribe(s.core, uiId, 1, { topic: "chats", scope: "ws" });
    await s.host.time.pass(500, 100);
    const items = () => {
      const v = s.core.inner.store.value({ topic: "chats", scope: "ws" });
      return v && "ok" in v ? ((v.ok as J).days as J[]).flatMap((d) => d.items as J[]) : [];
    };
    assert.equal(items().length, 1);
    assert.equal(items()[0].id, "k1");

    // Optimistic pin via non-anchor k2.
    call(s.core, uiId, 10, "chat.pin", { station: ST, session: "k2", pinned: true });
    await s.host.time.pass(200, 100);
    assert.equal(items()[0].pinned, true, "optimistic pin via non-anchor key should pin anchor row");

    // Optimistic rename via non-anchor k2.
    call(s.core, uiId, 11, "chat.rename", { station: ST, session: "k2", title: "新标题" });
    await s.host.time.pass(200, 100);
    assert.equal(items()[0].title, "新标题", "optimistic rename via non-anchor key should rename anchor row");

    // Optimistic archive via non-anchor k2 hides anchor row immediately.
    call(s.core, uiId, 12, "chat.archive", { station: ST, session: "k2", archived: true });
    await s.host.time.pass(200, 100);
    assert.equal(items().length, 0, "optimistic archive via non-anchor key should hide anchor row");

    // Optimistic restore via non-anchor k2 brings anchor row back immediately.
    call(s.core, uiId, 13, "chat.archive", { station: ST, session: "k2", archived: false });
    await s.host.time.pass(200, 100);
    assert.equal(items().length, 1, "optimistic restore via non-anchor key should restore anchor row");
    assert.equal(items()[0].id, "k1");

    while (pending.length > 0) pending.shift()!();
    await s.host.time.pass(500, 100);
  } finally {
    s.core.close();
  }
});

test("optimistic archive of session B's own unchatted row does not hide another chat X where B is a member", async () => {
  const rowB = mergedRow("kB", "kB", {
    id: "kB",
    session: "kB",
    thread: null,
    title: "B 自己的无 chat 行",
    agents: [{ key: "kB", runtime: "codex", model: "gpt-6-astra", effort: "high", process: "warm", pending: 0 }],
  });
  const chatX = mergedRow("kA", "kB", {
    id: "kA",
    session: "kA",
    thread: 88,
    title: "普通多 agent chat X",
    lastActiveAt: 2000,
    agents: [
      { key: "kA", runtime: "claude", model: "claude-opus-5-5", effort: "high", process: "warm", pending: 0 },
      { key: "kB", runtime: "codex", model: "gpt-6-astra", effort: "high", process: "warm", pending: 0 },
    ],
  });
  const s = await started({
    ...base(),
    "GET /chats?shared=1": [chatX, rowB],
    "GET /sessions": [
      fullSession("kA", { connect: "ember" }),
      fullSession("kB", { connect: "gemini" }),
    ],
    "GET /threads": [],
  });
  const pending: (() => void)[] = [];
  stationLater(s.host, (req) => {
    if (req.method === "POST" || req.method === "PUT" || req.method === "PATCH") {
      return new Promise((resolve) => {
        pending.push(() => resolve({ status: 200, headers: [["content-type", "application/json"]], body: new TextEncoder().encode("{}") }));
      });
    }
    return undefined;
  });
  try {
    await s.host.time.pass(2000, 100);
    const uiId = s.core.connect();
    subscribe(s.core, uiId, 1, { topic: "chats", scope: "ws" });
    await s.host.time.pass(500, 100);
    const ids = () => {
      const v = s.core.inner.store.value({ topic: "chats", scope: "ws" });
      return v && "ok" in v ? ((v.ok as J).days as J[]).flatMap((d) => (d.items as J[]).map((i) => i.id)) : [];
    };
    assert.deepEqual(ids(), ["kA", "kB"]);

    // Archiving B's own unchatted row must hide kB without hiding chat X (kA).
    call(s.core, uiId, 20, "chat.archive", { station: ST, session: "kB", archived: true });
    await s.host.time.pass(200, 100);
    assert.deepEqual(ids(), ["kA"], "archiving B's own row must not hide chat X where B is a member");

    while (pending.length > 0) pending.shift()!();
    await s.host.time.pass(500, 100);
  } finally {
    s.core.close();
  }
});

test("pin incremental event uses anchor key and @ menu matches rows by agents[].key", async () => {
  const row = mergedRow("k1", "k2");
  const s = await started({
    ...base(),
    "GET /chats?shared=1": [row],
    "GET /sessions": [
      fullSession("k1", { connect: "ember" }),
      fullSession("k2", { connect: "gemini", conv: "k1" }),
    ],
    "GET /threads": [],
  });
  try {
    await s.host.time.pass(2000, 100);
    // Incremental pin event carries the conversation anchor key (k1) and updates the merged row.
    s.push("pin", { session: "k1", at: 9999 });
    await s.host.time.pass(500, 100);
    const stored = s.core.inner.data.chat(ST, "k1") as J;
    assert.equal(stored?.pinned, 9999, "pin event for anchor key should update merged row");

    // Unpin clears it.
    s.push("pin", { session: "k1", at: null });
    await s.host.time.pass(500, 100);
    const unpinned = s.core.inner.data.chat(ST, "k1") as J;
    assert.equal(unpinned?.pinned, null, "unpin event for anchor key should clear pin on merged row");

    // @ menu (refs.search): opened ranking & exclude match by agents[].key.
    const chatsView = {
      days: [{
        items: [
          { id: "other", session: "other", station: ST, title: "另一个", lastActiveAt: 5000, agents: [{ key: "other", agentText: "Opus" }] },
          { id: "k1", session: "k1", station: ST, title: "合并对话", lastActiveAt: 1000, agents: [{ key: "k1", agentText: "Opus" }, { key: "k2", agentText: "Astra" }] },
        ],
      }],
    };
    const ranked = refs.search(chatsView, "", ST, null, 10, [[ST, "k2"]]);
    assert.equal(ranked.items[0].id, "k1", "recently opened by non-anchor key k2 should rank anchor row k1 first");

    const excluded = refs.search(chatsView, "", ST, "k2", 10, []);
    assert.deepEqual(excluded.items.map((i: J) => i.id), ["other"], "exclude by non-anchor key k2 should exclude anchor row k1");
  } finally {
    s.core.close();
  }
});

test("rows-changed: second agent birth patches anchor row and removes its old standalone row", async () => {
  const row1 = mergedRow("k1", "k2", { agents: [{ key: "k1", runtime: "claude", model: "claude-opus-5-5", effort: "high", process: "warm", pending: 0 }] });
  const row2 = mergedRow("k2", "k2", { id: "k2", session: "k2", agents: [{ key: "k2", runtime: "codex", model: "gpt-6-astra", effort: "high", process: "warm", pending: 0 }] });
  const s = await started({
    ...base(),
    "GET /chats?shared=1": [row1, row2],
    "GET /sessions": [fullSession("k1", { connect: "ember" }), fullSession("k2", { connect: "gemini" })],
    "GET /threads": [],
  });
  try {
    await s.host.time.pass(2000, 100);
    assert.ok(s.core.inner.data.chat(ST, "k1"));
    assert.ok(s.core.inner.data.chat(ST, "k2"));

    // Second agent merges into k1: station emits one chat-shared patch for k1 + one chat-shared-removed for k2.
    s.push("chat-shared", mergedRow("k1", "k2", { lastActiveAt: 2000 }));
    s.push("chat-shared-removed", { id: "k2" });
    await s.host.time.pass(500, 100);

    const anchor = s.core.inner.data.chat(ST, "k1") as J;
    assert.ok(anchor, "anchor row k1 should remain");
    assert.deepEqual(anchor.agents.map((a: J) => a.key), ["k1", "k2"]);
    assert.equal(s.core.inner.data.chat(ST, "k2"), undefined, "standalone row k2 should be removed");
  } finally {
    s.core.close();
  }
});
