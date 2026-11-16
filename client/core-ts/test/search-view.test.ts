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
