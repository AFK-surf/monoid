// The search's chat section keeps the station's indication of more hits, even when its first page fits here.
import assert from "node:assert/strict";
import { test } from "node:test";
import { CHATS_SHOWN, searchView, stationTopic, type SearchSource } from "../src/views/search.ts";

const topic = { topic: "search", scope: "ws", query: "release" } as const;

for (const more of [true, false]) test(`a station's six chat hits ${more ? "with" : "without"} more keep the right continuation`, () => {
  const hits = Array.from({ length: 6 }, (_, i) => ({ kind: "chat", key: `c:${i}`, chat: `chat${i}`, thread: i, title: `release ${i}`, archived: true }));
  const source: SearchSource = {
    value: (asked) => {
      assert.deepEqual(asked, stationTopic("ws/st", topic));
      assert.equal(asked.limit, hits.length, "the station's first page is shorter than the chat section");
      return { ok: { groups: [{ kind: "chat", hits, more }] } };
    },
    ok: () => ({ members: [] }),
    stations: () => [{ address: "ws/st", name: "studio", emoji: null, icon: null, online: true }],
    foundMessages: () => [],
    whole: (row) => row,
    me: () => null,
    clock: () => ({ now: 0, offsetMin: 0 }),
  };
  const result = searchView(source, { days: [] }, topic);
  assert.ok("ok" in result);
  const shown = result.ok as { items: unknown[]; chatsMore: boolean };
  assert.equal(shown.items.length, hits.length);
  assert.ok(shown.items.length < CHATS_SHOWN);
  assert.equal(shown.chatsMore, more, "Show more follows the station's remaining matches, not only locally hidden rows");
});

test("multi-station chat results are sorted across stations before truncating to CHATS_SHOWN", () => {
  const query = { topic: "search", scope: "ws", query: "admin cli" } as const;
  const st1Hits = Array.from({ length: 8 }, (_, i) => ({
    kind: "chat", key: `c:${i}`, chat: `old-${i}`, thread: i + 1, title: `Admin CLI 旧归档 ${i}`, archived: true, at: 100 + i,
  }));
  const st2Hits = [{
    kind: "chat", key: "c:99", chat: "fresh-st2", thread: 99, title: "实现 Admin API Key、密钥库集成与 Admin CLI",
    text: "实现 Admin API Key、密钥库集成与 Admin CLI", archived: true, at: 9_999,
  }];
  const source: SearchSource = {
    value: (asked) => {
      if (asked.station === "ws/st1") return { ok: { groups: [{ kind: "chat", hits: st1Hits, more: false }] } };
      if (asked.station === "ws/st2") return { ok: { groups: [{ kind: "chat", hits: st2Hits, more: false }] } };
      return undefined;
    },
    ok: () => ({ members: [] }),
    stations: () => [
      { address: "ws/st1", name: "st1", emoji: null, icon: null, online: true },
      { address: "ws/st2", name: "st2", emoji: null, icon: null, online: true },
    ],
    foundMessages: () => [],
    whole: (row) => row,
    me: () => null,
    clock: () => ({ now: 0, offsetMin: 0 }),
  };
  const localChats = {
    days: [{
      items: [{
        id: "active-1", session: "active-1", thread: 50, title: "Admin CLI 活跃对话",
        station: "ws/st1", stationName: "st1", agents: [], last: null, unread: false, mine: true, lastActiveAt: 50,
      }],
    }],
  };
  const result = searchView(source, localChats, query);
  assert.ok("ok" in result);
  const shown = result.ok as { items: { id: string; archived?: boolean; foundText?: string; foundMarks?: unknown[] }[]; chatsMore: boolean };
  assert.equal(shown.items.length, CHATS_SHOWN);
  // Active (non-archived) chat comes first, then station 2's newest archived chat is NOT truncated.
  assert.equal(shown.items[0]!.id, "active-1");
  assert.equal(shown.items[0]!.archived, undefined);
  assert.equal(shown.items[1]!.id, "fresh-st2");
  assert.equal(shown.items[1]!.archived, true);
  // Multi-word foundChat: second word ("cli") is past SEEN_CHARS, so foundText/foundMarks excerpt is provided.
  assert.ok(typeof shown.items[1]!.foundText === "string" && shown.items[1]!.foundText.includes("CLI"));
  assert.ok((shown.items[1]!.foundMarks?.length ?? 0) > 0);
  assert.equal(shown.chatsMore, true);
});
