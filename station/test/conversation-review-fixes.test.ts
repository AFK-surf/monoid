import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { StatementSync } from "node:sqlite";
import { test } from "node:test";
import { MbProcess, mbReaderBinary } from "../src/read/mb-reader.ts";
import { ensureConversationChat } from "../src/sessions/lifecycle.ts";
import { activeConversationMembers, birthThreadsOf } from "../src/store/conversations.ts";
import { Store } from "../src/store/store.ts";
import { backfillConversationsStep } from "../src/sessions/conversation-backfill.ts";
import { Rig } from "./hub-fakes.ts";
import { readersOf } from "./reference.ts";

const binary = mbReaderBinary();

const counted = { rows: 0, calls: 0, on: false };
const proto = StatementSync.prototype as unknown as Record<string, (...args: unknown[]) => unknown>;
for (const name of ["all", "get", "iterate", "run"]) {
  const original = proto[name]!;
  proto[name] = function (this: unknown, ...args: unknown[]) {
    const out = original.apply(this, args);
    if (counted.on) {
      counted.calls++;
      counted.rows += name === "all" ? (out as unknown[]).length : name === "get" && out !== undefined ? 1 : 0;
    }
    return out;
  };
}

function measure(fn: () => void): { calls: number; rows: number } {
  counted.calls = 0;
  counted.rows = 0;
  counted.on = true;
  try {
    fn();
  } finally {
    counted.on = false;
  }
  return { calls: counted.calls, rows: counted.rows };
}

test("Review #1: joinThread hot path skips transaction and settle for scope=all and non-birth threads", () => {
  const store = Store.open(":memory:");
  try {
    store.insertSession({ key: "single-1", connect: "cl", scope: "all", runtime: "claude", profile: "cc", workspace: "/w/1", token: "t1", createdAt: 100, lastActiveAt: 100 });
    store.insertSession({ key: "cl:C1:10.1", connect: "cl", scope: "thread", runtime: "claude", profile: "cc", workspace: "/w/2", token: "t2", createdAt: 100, lastActiveAt: 100 });
    const t1 = store.openThread("slack:T1", "C1", "10.1", null, "U1");
    const t2 = store.openThread("slack:T1", "C2", "99.9", null, "U1");

    // Works inside an outer transaction (proving no nested BEGIN IMMEDIATE on hot path).
    store.db.exec("BEGIN");
    const m1 = measure(() => { store.joinThread(t1.id, "single-1", "cl"); });
    const m2 = measure(() => { store.joinThread(t2.id, "cl:C1:10.1", "cl"); });
    store.db.exec("COMMIT");

    // Hot path: scope=all does 1 SELECT (scope) + 1 INSERT; non-birth thread does 2 SELECTs + 1 INSERT.
    assert.ok(m1.calls <= 3, `expected <=3 SQL calls for scope=all joinThread, got ${m1.calls}`);
    assert.ok(m2.calls <= 4, `expected <=4 SQL calls for non-birth thread joinThread, got ${m2.calls}`);
  } finally {
    store.close();
  }
});

test("Review #2: birthThreadsOf and activeConversationMembers are O(1) bounded regardless of extra threads", () => {
  function runWith(extraThreads: number) {
    const store = Store.open(":memory:");
    try {
      const birth = store.openThread("slack:T1", "C1", "100.1", "Birth", "U1");
      store.insertSession({ key: "cl:C1:100.1", connect: "cl", scope: "thread", runtime: "claude", profile: "cc", workspace: "/w/1", token: "t1", createdAt: 100, lastActiveAt: 100 });
      store.insertSession({ key: "gpt:C1:100.1", connect: "gpt", scope: "thread", runtime: "codex", profile: "cx", workspace: "/w/2", token: "t2", createdAt: 200, lastActiveAt: 200 });
      store.joinThread(birth.id, "cl:C1:100.1", "cl");
      store.joinThread(birth.id, "gpt:C1:100.1", "gpt");

      store.db.exec("BEGIN");
      for (let i = 0; i < extraThreads; i++) {
        const extra = store.openThread("slack:T1", "C9", `2000.${i}`, null, "U1");
        store.joinThread(extra.id, "cl:C1:100.1", "cl");
      }
      store.db.exec("COMMIT");

      const mBirth = measure(() => {
        const ids = birthThreadsOf(store.db, "cl:C1:100.1");
        assert.deepEqual(ids, [birth.id]);
      });
      const mActive = measure(() => {
        const active = activeConversationMembers(store.db, "cl:C1:100.1", "cl:C1:100.1");
        assert.deepEqual(active.sort(), ["cl:C1:100.1", "gpt:C1:100.1"]);
      });
      return { mBirth, mActive };
    } finally {
      store.close();
    }
  }

  const small = runWith(5);
  const large = runWith(200);
  assert.deepEqual(large.mBirth, small.mBirth, `birthThreadsOf must be O(1): small=${JSON.stringify(small.mBirth)} large=${JSON.stringify(large.mBirth)}`);
  assert.deepEqual(large.mActive, small.mActive, `activeConversationMembers must be O(1): small=${JSON.stringify(small.mActive)} large=${JSON.stringify(large.mActive)}`);
});

test("Review #3: backfill converges via sessions_conv_todo partial index; lone sessions get conv=key", () => {
  const store = Store.open(":memory:");
  try {
    // App session (scope=all) and legacy thread sessions with conv=NULL.
    store.insertSession({ key: "chat:app1", connect: "ember", scope: "all", runtime: "claude", profile: "cc", workspace: "/w/a", token: "ta", createdAt: 100, lastActiveAt: 100 });
    store.insertSession({ key: "cl:C1:1.1", connect: "cl", scope: "thread", runtime: "claude", profile: "cc", workspace: "/w/1", token: "t1", createdAt: 100, lastActiveAt: 100 });
    store.insertSession({ key: "cl:C2:2.2", connect: "cl", scope: "thread", runtime: "claude", profile: "cc", workspace: "/w/2", token: "t2", createdAt: 100, lastActiveAt: 100 });
    store.insertSession({ key: "gpt:C2:2.2", connect: "gpt", scope: "thread", runtime: "codex", profile: "cx", workspace: "/w/3", token: "t3", createdAt: 200, lastActiveAt: 200 });
    const t1 = store.openThread("slack:T1", "C1", "1.1", null, "U1");
    const t2 = store.openThread("slack:T1", "C2", "2.2", null, "U1");
    // Simulate legacy rows inserted before conv existed.
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 100)").run(t1.id, "cl:C1:1.1", "cl");
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 100)").run(t2.id, "cl:C2:2.2", "cl");
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 200)").run(t2.id, "gpt:C2:2.2", "gpt");

    const todoBefore = store.db.prepare("SELECT key FROM sessions INDEXED BY sessions_conv_todo WHERE scope = 'thread' AND conv IS NULL").all();
    assert.equal(todoBefore.length, 3);

    const settled = new Set<number>();
    const step = backfillConversationsStep(store, "", settled);
    assert.equal(step.done, true);

    // Partial index is now completely empty -> zero work on future startups.
    const todoAfter = store.db.prepare("SELECT key FROM sessions INDEXED BY sessions_conv_todo WHERE scope = 'thread' AND conv IS NULL").all();
    assert.equal(todoAfter.length, 0);

    // App session stays conv=NULL; lone thread session has conv=key; pair shares anchor.
    assert.equal(store.getSession("chat:app1")?.conv, undefined);
    assert.equal((store.db.prepare("SELECT conv FROM sessions WHERE key = 'cl:C1:1.1'").get() as { conv: string }).conv, "cl:C1:1.1");
    assert.equal(store.conversationOf("gpt:C2:2.2"), "cl:C2:2.2");

    // sessions_conv_grouped contains ONLY truly grouped non-anchor members (conv != key).
    const grouped = store.db.prepare("SELECT key FROM sessions INDEXED BY sessions_conv_grouped WHERE conv IS NOT NULL AND conv != key").all() as { key: string }[];
    assert.deepEqual(grouped.map((r) => r.key), ["gpt:C2:2.2"]);
  } finally {
    store.close();
  }
});

test("Review #5, #6, #7: dangling threads.home fallback, stable unchatted agents order, and archived pagination dedup", { skip: binary === null ? "MoonBit reader not built" : false }, async () => {
  const data = mkdtempSync(join(tmpdir(), "conv-review-list-"));
  try {
    writeFileSync(join(data, "config.json"), JSON.stringify({ connects: [] }));
    const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));

    // #5: Dangling threads.home pointing to a deleted session key.
    store.insertSession({ key: "survivor", connect: "ember", scope: "all", runtime: "claude", profile: "cc", workspace: "/w/s", token: "ts", createdAt: 100, lastActiveAt: 500 });
    const danglingChat = store.openThreadOf("ember", "CHAT", "deleted-anchor", "deleted-anchor", "Dangling", "ada@x.com");
    store.joinThread(danglingChat.id, "survivor", "ember");

    // #6: Unchatted 3-agent conversation where youngest agent has highest last_active_at.
    const t = store.openThread("slack:T1", "C1", "50.1", "Trio", "U1");
    store.insertSession({ key: "a1:C1:50.1", connect: "a1", scope: "thread", runtime: "claude", profile: "cc", workspace: "/w/a1", token: "ta1", createdAt: 100, lastActiveAt: 100 });
    store.insertSession({ key: "a2:C1:50.1", connect: "a2", scope: "thread", runtime: "claude", profile: "cc", workspace: "/w/a2", token: "ta2", createdAt: 200, lastActiveAt: 200 });
    store.insertSession({ key: "a3:C1:50.1", connect: "a3", scope: "thread", runtime: "claude", profile: "cc", workspace: "/w/a3", token: "ta3", createdAt: 300, lastActiveAt: 9999 });
    store.joinThread(t.id, "a1:C1:50.1", "a1");
    store.joinThread(t.id, "a2:C1:50.1", "a2");
    store.joinThread(t.id, "a3:C1:50.1", "a3");
    store.db.prepare("UPDATE sessions SET last_active_at = 9999 WHERE key = 'a3:C1:50.1'").run();

    // #7: Archived pagination cross-page boundary (page size = 1 in reference, and 31 items in MoonBit reader).
    const tArch = store.openThread("slack:T1", "C2", "60.1", "Archived Pair", "U1");
    store.insertSession({ key: "arch1:C2:60.1", connect: "a1", scope: "thread", runtime: "claude", profile: "cc", workspace: "/w/ar1", token: "tar1", createdAt: 100, lastActiveAt: 100 });
    store.insertSession({ key: "arch2:C2:60.1", connect: "a2", scope: "thread", runtime: "claude", profile: "cc", workspace: "/w/ar2", token: "tar2", createdAt: 200, lastActiveAt: 200 });
    store.joinThread(tArch.id, "arch1:C2:60.1", "a1");
    store.joinThread(tArch.id, "arch2:C2:60.1", "a2");
    store.setArchived("arch1:C2:60.1", true, "manual");
    store.db.prepare("UPDATE sessions SET archived_at = 5000 WHERE key IN ('arch1:C2:60.1', 'arch2:C2:60.1')").run();
    // Add 49 newer + 2 older archived single sessions so the archived pair (same archived_at=5000) sits right on
    // the 50-item ARCHIVE_PAGE boundary (without dedup, arch2 would take slot 50 on page 1 and arch1 slot 1 on page 2).
    for (let i = 0; i < 49; i++) {
      const k = `pad-new-${String(i).padStart(2, "0")}`;
      store.insertSession({ key: k, connect: "ember", scope: "all", runtime: "claude", profile: "cc", workspace: `/w/${k}`, token: `t-${k}`, createdAt: 100 + i, lastActiveAt: 100 + i });
      store.setArchived(k, true, "manual");
      store.db.prepare("UPDATE sessions SET archived_at = ? WHERE key = ?").run(6000 + i, k);
    }
    for (let i = 0; i < 2; i++) {
      const k = `pad-old-${String(i).padStart(2, "0")}`;
      store.insertSession({ key: k, connect: "ember", scope: "all", runtime: "claude", profile: "cc", workspace: `/w/${k}`, token: `t-${k}`, createdAt: 50 + i, lastActiveAt: 50 + i });
      store.setArchived(k, true, "manual");
      store.db.prepare("UPDATE sessions SET archived_at = ? WHERE key = ?").run(4000 + i, k);
    }

    const readers = readersOf(data, binary);
    const refReaders = readersOf(data, null);
    try {
      const viewer = { email: "ada@x.com", workspaces: [] };
      const mbList = JSON.parse(await readers.read("chats", { viewer, archived: false }, "en")) as { id: string; agents: { key: string }[] }[];
      const refList = JSON.parse(await refReaders.read("chats", { viewer, archived: false }, "en")) as { id: string; agents: { key: string }[] }[];

      // #5: Dangling home falls back to survivor (agents[0].key) in both MoonBit and TS reference.
      const mbDangling = mbList.find((r) => r.agents.some((a) => a.key === "survivor"))!;
      const refDangling = refList.find((r) => r.agents.some((a) => a.key === "survivor"))!;
      assert.equal(mbDangling.id, "survivor");
      assert.equal(refDangling.id, "survivor");

      // #6: Unchatted agents order is fixed by (created_at, key), not last_active_at.
      const mbTrio = mbList.find((r) => r.id === "a1:C1:50.1")!;
      const refTrio = refList.find((r) => r.id === "a1:C1:50.1")!;
      assert.deepEqual(mbTrio.agents.map((a) => a.key), ["a1:C1:50.1", "a2:C1:50.1", "a3:C1:50.1"]);
      assert.deepEqual(refTrio.agents.map((a) => a.key), ["a1:C1:50.1", "a2:C1:50.1", "a3:C1:50.1"]);

      // #7: Archived pagination across pages never duplicates the 2-agent conversation.
      const p1 = JSON.parse(await readers.read("chats", { viewer, archived: true, page: "" }, "en")) as { rows: { id: string; agents: { key: string }[] }[]; next: string | null };
      assert.ok(p1.next !== null, "expected second page");
      const p2 = JSON.parse(await readers.read("chats", { viewer, archived: true, page: p1.next }, "en")) as { rows: { id: string; agents: { key: string }[] }[]; next: string | null };
      const allIds = [...p1.rows, ...p2.rows].map((r) => r.id);
      assert.equal(allIds.filter((id) => id === "arch1:C2:60.1").length, 1, "archived pair appears exactly once across pages");
      assert.equal(allIds.includes("arch2:C2:60.1"), false, "non-anchor member does not appear as a separate row");
      const pairRow = [...p1.rows, ...p2.rows].find((r) => r.id === "arch1:C2:60.1")!;
      assert.deepEqual(pairRow.agents.map((a) => a.key), ["arch1:C2:60.1", "arch2:C2:60.1"]);

      // #4: Scoped chatMarks / chats reads viewer's pins once, folds to anchor, and filters to scoped rows.
      store.setPin("ada@x.com", "a2:C1:50.1", true);
      store.setPin("ada@x.com", "survivor", true);
      const scopedMarks = JSON.parse(await readers.read("chatMarks", { viewer, scope: { sessions: ["a1:C1:50.1"], threads: [] } }, "en")) as { pins: Record<string, number> };
      assert.ok("a1:C1:50.1" in scopedMarks.pins, `expected folded anchor pin in scoped chatMarks, got ${JSON.stringify(scopedMarks.pins)}`);
      assert.equal("survivor" in scopedMarks.pins, false, "out-of-scope pin must be excluded");

      // Also verify TS reference reader pagination matches MoonBit reader (zero duplicates across pages).
      const rp1 = JSON.parse(await refReaders.read("chats", { viewer, archived: true, page: "" }, "en")) as { rows: { id: string }[]; next: string | null };
      assert.ok(rp1.next !== null, "expected second page in reference reader");
      const rp2 = JSON.parse(await refReaders.read("chats", { viewer, archived: true, page: rp1.next }, "en")) as { rows: { id: string }[]; next: string | null };
      const refAllIds = [...rp1.rows, ...rp2.rows].map((r) => r.id);
      assert.equal(refAllIds.filter((id) => id === "arch1:C2:60.1").length, 1);
      assert.equal(refAllIds.includes("arch2:C2:60.1"), false);
    } finally {
      readers.close();
      refReaders.close();
      store.close();
    }
  } finally {
    rmSync(data, { recursive: true, force: true });
  }
});

test("narrowed home-chat row id: multi-member conversation uses anchor even when anchor left birth thread; non-conversation home chat keeps agents[0]", { skip: binary === null ? "MoonBit reader not built" : false }, async () => {
  const r = new Rig();
  try {
    writeFileSync(join(r.dir, "config.json"), JSON.stringify({ connects: [] }));
    const { store, hub } = r;

    // Case 1: Multi-member conversation chat -> ensureConversationChat joins anchor first, row id = anchor.
    const t1 = store.openThread("slack:T1", "C1", "80.1", "Pair", "U1");
    store.insertSession({ key: "a1:C1:80.1", connect: "a1", scope: "thread", title: "A1", runtime: "claude", profile: "cc", workspace: "/w/a1", token: "ta1", createdAt: 100, lastActiveAt: 100 });
    store.insertSession({ key: "b1:C1:80.1", connect: "b1", scope: "thread", title: "B1", runtime: "codex", profile: "cx", workspace: "/w/b1", token: "tb1", createdAt: 200, lastActiveAt: 200 });
    store.joinThread(t1.id, "a1:C1:80.1", "a1");
    store.joinThread(t1.id, "b1:C1:80.1", "b1");
    ensureConversationChat(hub, "b1:C1:80.1", "ada@x.com", null);

    // Case 2: Multi-member conversation where anchor left birth thread -> home chat only has B2, row id is still A2.
    const t2 = store.openThread("slack:T1", "C2", "81.1", "LeftAnchor", "U1");
    store.insertSession({ key: "a2:C2:81.1", connect: "a2", scope: "thread", title: "A2", runtime: "claude", profile: "cc", workspace: "/w/a2", token: "ta2", createdAt: 100, lastActiveAt: 100 });
    store.insertSession({ key: "b2:C2:81.1", connect: "b2", scope: "thread", title: "B2", runtime: "codex", profile: "cx", workspace: "/w/b2", token: "tb2", createdAt: 200, lastActiveAt: 200 });
    store.joinThread(t2.id, "a2:C2:81.1", "a2");
    store.joinThread(t2.id, "b2:C2:81.1", "b2");
    store.leaveThread(t2.id, "a2:C2:81.1");
    ensureConversationChat(hub, "b2:C2:81.1", "ada@x.com", null);

    // Case 3: Non-conversation home chat where home != agents[0] (e.g. job/origin chat) -> row id keeps agents[0].
    store.insertSession({ key: "single-home", connect: "ember", scope: "all", title: "Home", runtime: "claude", profile: "cc", workspace: "/w/sh", token: "tsh", createdAt: 100, lastActiveAt: 100 });
    store.insertSession({ key: "peer-first", connect: "ember", scope: "all", title: "Peer", runtime: "claude", profile: "cc", workspace: "/w/pf", token: "tpf", createdAt: 200, lastActiveAt: 200 });
    const legacyHome = store.openThreadOf("ember", "CHAT", "legacy-home-ts", "Legacy", "ada@x.com", "single-home");
    store.joinThread(legacyHome.id, "peer-first", "ember");
    store.joinThread(legacyHome.id, "single-home", "ember");

    const readers = readersOf(r.dir, binary);
    const refReaders = readersOf(r.dir, null);
    try {
      const viewer = { email: "ada@x.com", workspaces: [] };
      const mbList = JSON.parse(await readers.read("chats", { viewer, archived: false }, "en")) as { id: string; agents: { key: string }[] }[];
      const refList = JSON.parse(await refReaders.read("chats", { viewer, archived: false }, "en")) as { id: string; agents: { key: string }[] }[];

      for (const [label, list] of [["mb", mbList], ["ref", refList]] as const) {
        const pair = list.find((row) => row.agents.some((a) => a.key === "b1:C1:80.1"))!;
        assert.equal(pair.id, "a1:C1:80.1", `${label}: multi-member conversation chat row id must be anchor`);
        assert.deepEqual(pair.agents.map((a) => a.key), ["a1:C1:80.1", "b1:C1:80.1"], `${label}: anchor joined first`);

        const leftAnchor = list.find((row) => row.agents.some((a) => a.key === "b2:C2:81.1"))!;
        assert.equal(leftAnchor.id, "a2:C2:81.1", `${label}: row id must stay anchor even when anchor left birth thread`);
        assert.deepEqual(leftAnchor.agents.map((a) => a.key), ["b2:C2:81.1"], `${label}: only active member B2 is in home chat`);

        const legacy = list.find((row) => row.agents.some((a) => a.key === "peer-first"))!;
        assert.equal(legacy.id, "peer-first", `${label}: non-conversation home chat must keep agents[0].key as row id`);
      }
    } finally {
      readers.close();
      refReaders.close();
    }
  } finally {
    await r.close();
  }
});

test("MoonBit conversation-backfill builder settles legacy thread pairs and lone sessions end-to-end", { skip: binary === null ? "MoonBit reader not built" : false }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "mb-conv-backfill-"));
  const dbPath = join(dir, "stillfail.db");
  const store = Store.open(dbPath, join(dir, "archive"));
  const builder = new MbProcess(binary!, ["--builder", "session-backfill", "--db", dbPath]);
  try {
    store.insertSession({ key: "chat:app1", connect: "ember", scope: "all", runtime: "claude", profile: "cc", workspace: "/w/a", token: "ta", createdAt: 100, lastActiveAt: 100 });
    store.insertSession({ key: "cl:C1:1.1", connect: "cl", scope: "thread", runtime: "claude", profile: "cc", workspace: "/w/1", token: "t1", createdAt: 100, lastActiveAt: 100 });
    store.insertSession({ key: "cl:C2:2.2", connect: "cl", scope: "thread", runtime: "claude", profile: "cc", workspace: "/w/2", token: "t2", createdAt: 100, lastActiveAt: 100 });
    store.insertSession({ key: "gpt:C2:2.2", connect: "gpt", scope: "thread", runtime: "codex", profile: "cx", workspace: "/w/3", token: "t3", createdAt: 200, lastActiveAt: 200 });
    const t1 = store.openThread("slack:T1", "C1", "1.1", null, "U1");
    const t2 = store.openThread("slack:T1", "C2", "2.2", null, "U1");
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 100)").run(t1.id, "cl:C1:1.1", "cl");
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 100)").run(t2.id, "cl:C2:2.2", "cl");
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 200)").run(t2.id, "gpt:C2:2.2", "gpt");

    const answered = new Promise<{ done: boolean; error?: string }>((resolve) => builder.once("message", resolve));
    builder.postMessage({ kind: "conversation-backfill" });
    const res = await answered;
    assert.equal(res.error, undefined);
    assert.equal(res.done, true);

    const todoAfter = store.db.prepare("SELECT key FROM sessions INDEXED BY sessions_conv_todo WHERE scope = 'thread' AND conv IS NULL").all();
    assert.equal(todoAfter.length, 0);
    assert.equal(store.getSession("chat:app1")?.conv, undefined);
    assert.equal((store.db.prepare("SELECT conv FROM sessions WHERE key = 'cl:C1:1.1'").get() as { conv: string }).conv, "cl:C1:1.1");
    assert.equal(store.conversationOf("gpt:C2:2.2"), "cl:C2:2.2");
  } finally {
    await builder.terminate();
    store.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
