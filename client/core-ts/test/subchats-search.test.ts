// Tests for the `chatSubchats` view topic: filtering a parent chat's opened/led sub-chats by title, state, local
// SQLite `said` messages (indexed per sub-chat thread), and remote `stationSearch` hits.
import assert from "node:assert/strict";
import { test } from "node:test";
import { CoreError } from "../src/error.ts";
import { NodeSql } from "../src/hosts/node-sql.ts";
import { holdLanguage } from "../src/i18n.ts";
import { parseTopic, type Topic } from "../src/protocol.ts";
import { sharedPlace } from "../src/station/rows-made.ts";
import { setup } from "./views-rig.ts";

holdLanguage();
// deno-lint-ignore no-explicit-any
type J = any;

const WS = "ws";
const ST = "ws/maple";
const ST2 = "ws/willow";

function makeRow(id: string, thread: number, title: string, extra: Record<string, unknown> = {}): J {
  return {
    id,
    session: id,
    thread,
    title,
    lastActiveAt: 1_700_000_000_000,
    agents: [{ key: id, status: "idle", runtime: "claude" }],
    unread: false,
    ...extra,
  };
}

function seedWorkspace(t: ReturnType<typeof setup>, rows1: J[], rows2: J[] = [], archived1: J[] = []) {
  t.set({ topic: "workspace", workspace: WS }, {
    id: WS,
    name: "Workspace",
    role: "owner",
    stations: [
      { id: "maple", name: "Maple", online: true },
      { id: "willow", name: "Willow", online: true },
    ],
    members: [{ sub: "s1", email: "me@x.com", name: "Tester", role: "owner" }],
  });
  t.set({ topic: "link", station: ST }, { state: "online" });
  t.set({ topic: "link", station: ST2 }, { state: "online" });
  t.data.setChatsAt(ST, rows1, rows1.map(sharedPlace));
  t.data.setChatsAt(ST2, rows2, rows2.map(sharedPlace));
  if (archived1.length > 0) t.set({ topic: "archivedRows", station: ST }, archived1);
  else t.set({ topic: "archivedRows", station: ST }, []);
  t.set({ topic: "archivedRows", station: ST2 }, []);
}

async function subValue(t: ReturnType<typeof setup>, id: number, raw: Record<string, unknown>): Promise<J> {
  const topic = parseTopic(raw);
  assert.ok(topic, `invalid topic: ${JSON.stringify(raw)}`);
  t.host.takeEmitted();
  t.store.subscribe(1, id, topic, false);
  await t.host.time.pass(100);
  const msgs = t.host.takeEmitted().filter(([, m]) => (m as J).id === id);
  const last = msgs.at(-1)?.[1] as J;
  assert.ok(last && "value" in last, `expected value for ${JSON.stringify(raw)}, got ${JSON.stringify(msgs)}`);
  return last.value;
}

test("chatSubchats_empty_query_returns_all_opened_in_priority_order", async () => {
  const t = setup({ all: true });
  try {
    const parent = makeRow("parent", 10, "Parent Chat", {
      opened: [
        { session: "sub-done", title: "Done Sub", led: true },
        { session: "sub-run", title: "Running Sub", led: true },
        { session: "sub-fail", title: "Failed Sub", led: true },
      ],
    });
    const subDone = makeRow("sub-done", 11, "Done Sub");
    const subRun = makeRow("sub-run", 12, "Running Sub", { agents: [{ key: "sub-run", status: "running", runtime: "claude" }] });
    const subFail = makeRow("sub-fail", 13, "Failed Sub", { agents: [{ key: "sub-fail", status: "failed", runtime: "claude" }] });
    seedWorkspace(t, [parent, subDone, subRun, subFail]);

    const v = await subValue(t, 1, { topic: "chatSubchats", station: ST, thread: 10, q: "" });
    assert.equal(v.reading, false);
    assert.deepEqual(v.words, []);
    assert.deepEqual(v.items.map((i: J) => i.session), ["sub-fail", "sub-run", "sub-done"]);
  } finally {
    t.store.runner.shutdown();
  }
});

test("chatSubchats_matches_title_state_and_local_said_including_archived", async () => {
  const t = setup({ all: true });
  try {
    const parent = makeRow("parent", 10, "Parent Chat", {
      opened: [
        { session: "sub-body", title: "Alpha Worker", led: true },
        { session: "sub-title", title: "Vulkan Shader Fix", led: true },
        { session: "sub-state", title: "CI Watcher", led: true },
        { session: "sub-arch", title: "Old Experiment", led: true },
      ],
    });
    const subBody = makeRow("sub-body", 11, "Alpha Worker");
    const subTitle = makeRow("sub-title", 12, "Vulkan Shader Fix");
    const subState = makeRow("sub-state", 13, "CI Watcher", {
      agents: [{ key: "sub-state", status: "idle", runtime: "claude", need: "Vulkan pipeline check" }],
      last: { seq: 1, text: "Vulkan pipeline verified" },
    });
    const subArch = makeRow("sub-arch", 14, "Old Experiment");
    const unrelated = makeRow("other-chat", 99, "Unrelated Vulkan Chat");
    seedWorkspace(t, [parent, subBody, subTitle, subState, unrelated], [], [subArch]);

    // Seed local SQLite `said` via `putItems` on entry logs
    t.data.putItems("entry", ST, "11", [
      [1, { seq: 1, kind: "message", authorKind: "agent", author: "sub-body", text: "Investigated the vulkan driver crash on Linux", createdAt: 1000 }],
    ]);
    t.data.putItems("entry", ST, "14", [
      [1, { seq: 1, kind: "message", authorKind: "agent", author: "sub-arch", text: "Archived note mentioning VULKAN fallback path", createdAt: 2000 }],
    ]);
    t.data.putItems("entry", ST, "99", [
      [1, { seq: 1, kind: "message", authorKind: "agent", author: "other-chat", text: "Unrelated vulkan message", createdAt: 3000 }],
    ]);

    // Provide empty stationSearch so reading becomes false
    const searchTopic: Topic = { topic: "stationSearch", station: ST, q: "vulkan", kind: "chat,message", limit: 200 };
    const v1 = await subValue(t, 2, { topic: "chatSubchats", station: ST, thread: 10, q: "vulkan" });
    assert.equal(v1.reading, true);
    assert.deepEqual(v1.words, ["vulkan"]);

    // Title hit must come first; unrelated chat must not appear
    const sessions = v1.items.map((i: J) => i.session);
    assert.equal(sessions[0], "sub-title");
    assert.ok(sessions.includes("sub-body"));
    assert.ok(sessions.includes("sub-state"));
    assert.ok(sessions.includes("sub-arch"));
    assert.ok(!sessions.includes("other-chat"));

    const bodyHit = v1.items.find((i: J) => i.session === "sub-body");
    assert.ok(bodyHit.foundText && bodyHit.foundText.toLowerCase().includes("vulkan"));
    assert.ok(Array.isArray(bodyHit.foundMarks) && bodyHit.foundMarks.length > 0);

    const archHit = v1.items.find((i: J) => i.session === "sub-arch");
    assert.equal(archHit.archived, true);
    assert.ok(archHit.foundText && archHit.foundText.toLowerCase().includes("vulkan"));

    // Once stationSearch returns, reading becomes false
    t.set(searchTopic, { groups: [] });
    await t.host.time.pass(100);
    const updates = t.host.takeEmitted();
    assert.ok(updates.length > 0);
  } finally {
    t.store.runner.shutdown();
  }
});

test("chatSubchats_remote_stationSearch_hits_and_error_graceful", async () => {
  const t = setup({ all: true });
  try {
    const parent = makeRow("parent", 10, "Parent Chat", {
      opened: [
        { session: "sub-local", title: "Local Worker", led: true },
        { session: "sub-remote", station: "willow", title: "Remote Worker", led: true },
      ],
    });
    const subLocal = makeRow("sub-local", 11, "Local Worker");
    const subRemote = makeRow("sub-remote", 21, "Remote Worker");
    seedWorkspace(t, [parent, subLocal], [subRemote]);

    t.data.putItems("entry", ST, "11", [
      [1, { seq: 1, kind: "message", authorKind: "agent", author: "sub-local", text: "Found zebra in local db", createdAt: 1000 }],
    ]);

    const topic = parseTopic({ topic: "chatSubchats", station: ST, session: "parent", q: "zebra" })!;
    t.store.subscribe(1, 3, topic, false);
    await t.host.time.pass(100);

    // Confirm searchShownNow recognizes stationSearch watched by chatSubchats
    const st1Search: Topic = { topic: "stationSearch", station: ST, q: "zebra", kind: "chat,message", limit: 200 };
    const st2Search: Topic = { topic: "stationSearch", station: ST2, q: "zebra", kind: "chat,message", limit: 200 };
    assert.equal(t.views.searchShownNow(st1Search), true);
    assert.equal(t.views.searchShownNow(st2Search), true);

    // ST returns 404 (older station), ST2 returns a remote message hit for sub-remote
    t.store.set(st1Search, { err: new CoreError("station", "not found", 404) });
    t.set(st2Search, {
      groups: [
        {
          kind: "message",
          hits: [
            { chat: "sub-remote", thread: 21, seq: 5, text: "Remote station found zebra artifact", at: 2000 },
            { chat: "not-a-subchat", thread: 88, seq: 1, text: "Ignored zebra hit", at: 3000 },
          ],
        },
      ],
    });
    await t.host.time.pass(100);

    const val = (t.store.value(topic) as { ok: J }).ok;
    assert.equal(val.reading, false);
    assert.deepEqual(val.items.map((i: J) => i.session).sort(), ["sub-local", "sub-remote"]);
    const remoteHit = val.items.find((i: J) => i.session === "sub-remote");
    assert.ok(remoteHit.foundText.includes("zebra"));
    assert.ok(remoteHit.foundMarks.length > 0);
  } finally {
    t.store.runner.shutdown();
  }
});

test("chatSubchats_archived_stateText_only_hit_emits_foundText", async () => {
  const t = setup({ all: true });
  try {
    const parent = makeRow("parent", 10, "Parent Chat", {
      opened: [{ session: "sub-arch", title: "Legacy Cleanup", led: true }],
    });
    const subArch = makeRow("sub-arch", 11, "Legacy Cleanup", {
      agents: [{ key: "sub-arch", status: "idle", runtime: "claude", lastTurn: { endedAt: 1000, ending: "need_help", need: "确认旧缓存目录清理方案" } }],
    });
    seedWorkspace(t, [parent], [], [subArch]);

    const topic = parseTopic({ topic: "chatSubchats", station: ST, session: "parent", q: "旧缓存目录" })!;
    t.store.subscribe(1, 4, topic, false);
    await t.host.time.pass(100);

    const val = (t.store.value(topic) as { ok: J }).ok;
    assert.equal(val.items.length, 1);
    assert.equal(val.items[0].session, "sub-arch");
    assert.equal(val.items[0].archived, true);
    assert.ok(val.items[0].foundText && val.items[0].foundText.includes("旧缓存目录"), `expected foundText for archived stateText-only hit, got ${JSON.stringify(val.items[0])}`);
    assert.ok(Array.isArray(val.items[0].foundMarks) && val.items[0].foundMarks.length > 0);
  } finally {
    t.store.runner.shutdown();
  }
});

test("chatSubchats_findSaidInThreads_constant_work_at_3x_unrelated_chats", async () => {
  const measure = (unrelatedCount: number) => {
    const t = setup({ all: true });
    try {
      const parent = makeRow("parent", 10, "Parent", {
        opened: [{ session: "sub-1", title: "Sub 1", led: true }],
      });
      const sub1 = makeRow("sub-1", 11, "Sub 1");
      const others: J[] = [];
      for (let i = 0; i < unrelatedCount; i++) {
        others.push(makeRow(`u-${i}`, 100 + i, `Unrelated ${i}`));
      }
      seedWorkspace(t, [parent, sub1, ...others]);
      t.data.putItems("entry", ST, "11", [
        [1, { seq: 1, kind: "message", authorKind: "agent", author: "sub-1", text: "target needle token here", createdAt: 1000 }],
      ]);
      for (let i = 0; i < unrelatedCount; i++) {
        t.data.putItems("entry", ST, String(100 + i), [
          [1, { seq: 1, kind: "message", authorKind: "agent", author: `u-${i}`, text: `noise needle payload ${"x".repeat(200)} ${i}`, createdAt: 1000 + i }],
        ]);
      }
      let readBytes = 0;
      const proto = NodeSql.prototype;
      const origAll = proto.all;
      proto.all = function (sql: string, params: readonly unknown[] = []) {
        const rows = origAll.call(this, sql, params as never);
        for (const r of rows) for (const v of r) if (typeof v === "string") readBytes += Buffer.byteLength(v);
        return rows;
      };
      try {
        const hits = t.data.findSaidInThreads([{ station: ST, thread: 11 }], ["needle"]);
        assert.equal(hits.size, 1);
        assert.equal(hits.get(`${ST}\u000111`)?.seq, 1);
      } finally {
        proto.all = origAll;
      }
      return readBytes;
    } finally {
      t.store.runner.shutdown();
    }
  };
  const r1 = measure(20);
  const r3 = measure(60);
  assert.equal(r3, r1, `expected constant read bytes across 3x unrelated chats, got ${r1} vs ${r3}`);
});
