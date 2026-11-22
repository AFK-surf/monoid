import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { AUTO, MANUAL, STILLFAIL_CONNECT, STILLFAIL_SURFACE, comingWs, handedWs } from "../src/store/rows.ts";
import { Store } from "../src/store/store.ts";
import { backfillConversationsStep } from "../src/sessions/conversation-backfill.ts";

function makeSession(store: Store, key: string, connect: string, createdAt: number, opts: {
  scope?: "thread" | "all";
  ws?: string | null;
} = {}) {
  store.insertSession({
    key,
    connect,
    scope: opts.scope ?? "thread",
    runtime: "claude",
    profile: "cc",
    workspace: `/w/${key}`,
    token: `tok-${key}`,
    createdAt,
    lastActiveAt: createdAt,
    ws: opts.ws ?? null,
  });
}

test("conversationOf, membersOf, and settle via joinThread", () => {
  const store = Store.open(":memory:");
  try {
    const t = store.openThread("slack:T1", "C1", "100.1", "Slack thread", "U1");
    makeSession(store, "bot1:C1:100.1", "bot1", 1000);
    store.joinThread(t.id, "bot1:C1:100.1", "bot1");
    assert.equal(store.conversationOf("bot1:C1:100.1"), "bot1:C1:100.1");
    assert.deepEqual(store.membersOf("bot1:C1:100.1"), ["bot1:C1:100.1"]);

    // Second bot born in same thread: settles into bot1's anchor.
    makeSession(store, "bot2:C1:100.1", "bot2", 2000);
    store.joinThread(t.id, "bot2:C1:100.1", "bot2");
    assert.equal(store.conversationOf("bot1:C1:100.1"), "bot1:C1:100.1");
    assert.equal(store.conversationOf("bot2:C1:100.1"), "bot1:C1:100.1");
    assert.deepEqual(store.membersOf("bot1:C1:100.1").sort(), ["bot1:C1:100.1", "bot2:C1:100.1"]);

    // Connect id with colon (bot:a:b) still matches by endsWith(:channel:threadTs).
    makeSession(store, "bot:a:b:C1:100.1", "bot:a:b", 3000);
    store.joinThread(t.id, "bot:a:b:C1:100.1", "bot:a:b");
    assert.equal(store.conversationOf("bot:a:b:C1:100.1"), "bot1:C1:100.1");

    // scope=all and relayed sessions do not merge.
    makeSession(store, "single:s-1", "single", 500, { scope: "all" });
    store.joinThread(t.id, "single:s-1", "single");
    makeSession(store, "relayed:C2:999.9", "relayed", 500);
    store.joinThread(t.id, "relayed:C2:999.9", "relayed");
    assert.equal(store.conversationOf("single:s-1"), "single:s-1");
    assert.equal(store.conversationOf("relayed:C2:999.9"), "relayed:C2:999.9");

    // Handed / coming replicas are excluded from membersOf and settle.
    makeSession(store, "bot3:C1:100.1", "bot3", 100, { ws: handedWs("ws1") });
    store.joinThread(t.id, "bot3:C1:100.1", "bot3");
    makeSession(store, "bot4:C1:100.1", "bot4", 100, { ws: comingWs("ws1") });
    store.joinThread(t.id, "bot4:C1:100.1", "bot4");
    assert.deepEqual(
      store.membersOf("bot1:C1:100.1").sort(),
      ["bot1:C1:100.1", "bot2:C1:100.1", "bot:a:b:C1:100.1"],
    );
  } finally {
    store.close();
  }
});

test("settle: one home chat vs two home chats, re-mention adds to hidden home chat", () => {
  const store = Store.open(":memory:");
  try {
    const t = store.openThread("slack:T1", "C1", "200.1", "T", "U1");
    makeSession(store, "bot1:C1:200.1", "bot1", 1000);
    makeSession(store, "bot2:C1:200.1", "bot2", 2000);
    // Simulate pre-upgrade state: both already in thread_sessions, conv=NULL, bot2 has home chat.
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 1000)").run(t.id, "bot1:C1:200.1", "bot1");
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 2000)").run(t.id, "bot2:C1:200.1", "bot2");
    const home2 = store.openThreadOf(STILLFAIL_SURFACE, "CHAT", "200.99", "Home2", "U1", "bot2:C1:200.1");
    store.joinThread(home2.id, "bot2:C1:200.1", STILLFAIL_CONNECT);

    // Settle merges bot1 into bot2 (the one with a home chat) and adds bot1 to home2.
    store.settleConversation(t.id);
    assert.equal(store.conversationOf("bot1:C1:200.1"), "bot2:C1:200.1");
    assert.equal(store.conversationOf("bot2:C1:200.1"), "bot2:C1:200.1");
    assert.ok(store.threadSessions(home2.id).some((m) => m.session === "bot1:C1:200.1"));

    // Two home chats never merge with each other.
    const t2 = store.openThread("slack:T1", "C1", "201.1", "T2", "U1");
    makeSession(store, "a:C1:201.1", "a", 1000);
    makeSession(store, "b:C1:201.1", "b", 2000);
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 1000)").run(t2.id, "a:C1:201.1", "a");
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 2000)").run(t2.id, "b:C1:201.1", "b");
    const ha = store.openThreadOf(STILLFAIL_SURFACE, "CHAT", "201.98", "Ha", "U1", "a:C1:201.1");
    const hb = store.openThreadOf(STILLFAIL_SURFACE, "CHAT", "201.99", "Hb", "U1", "b:C1:201.1");
    store.joinThread(ha.id, "a:C1:201.1", STILLFAIL_CONNECT);
    store.joinThread(hb.id, "b:C1:201.1", STILLFAIL_CONNECT);
    store.settleConversation(t2.id);
    assert.equal(store.conversationOf("a:C1:201.1"), "a:C1:201.1");
    assert.equal(store.conversationOf("b:C1:201.1"), "b:C1:201.1");

    // Left member re-mentioned joins hidden home chat.
    const t3 = store.openThread("slack:T1", "C1", "202.1", "T3", "U1");
    makeSession(store, "x:C1:202.1", "x", 1000);
    makeSession(store, "y:C1:202.1", "y", 2000);
    store.joinThread(t3.id, "x:C1:202.1", "x");
    store.joinThread(t3.id, "y:C1:202.1", "y");
    store.leaveThread(t3.id, "y:C1:202.1");
    const hx = store.openThreadOf(STILLFAIL_SURFACE, "CHAT", "202.99", "Hx", "U1", "x:C1:202.1");
    store.joinThread(hx.id, "x:C1:202.1", STILLFAIL_CONNECT);
    store.db.prepare("UPDATE threads SET hidden_at = 5000, hidden_by = 'auto' WHERE id = ?").run(hx.id);
    assert.equal(store.threadSessions(hx.id).some((m) => m.session === "y:C1:202.1"), false);
    // Re-mention y -> joinThread clears left_at and settles -> y added to hx even though hx is hidden.
    store.joinThread(t3.id, "y:C1:202.1", "y");
    assert.equal(store.threadSessions(hx.id).some((m) => m.session === "y:C1:202.1"), true);
  } finally {
    store.close();
  }
});

test("settle: archive state convergence and share boundary", () => {
  const store = Store.open(":memory:");
  try {
    // Manual archived member does not merge with live member; joins after manual restore.
    const t1 = store.openThread("slack:T1", "C1", "300.1", "T1", "U1");
    makeSession(store, "m1:C1:300.1", "m1", 1000);
    makeSession(store, "m2:C1:300.1", "m2", 2000);
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 1000)").run(t1.id, "m1:C1:300.1", "m1");
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 2000)").run(t1.id, "m2:C1:300.1", "m2");
    store.db.prepare("UPDATE sessions SET archived_at = 5000, archived_by = ? WHERE key = ?").run(MANUAL, "m1:C1:300.1");
    store.settleConversation(t1.id);
    assert.equal(store.conversationOf("m1:C1:300.1"), "m1:C1:300.1");
    assert.equal(store.conversationOf("m2:C1:300.1"), "m2:C1:300.1");
    // Manual restore of m1 triggers settle -> merges with m2!
    store.setArchived("m1:C1:300.1", false, MANUAL);
    assert.equal(store.conversationOf("m1:C1:300.1"), "m1:C1:300.1");
    assert.equal(store.conversationOf("m2:C1:300.1"), "m1:C1:300.1");

    // Auto archived member merges with live member and is restored.
    const t2 = store.openThread("slack:T1", "C1", "301.1", "T2", "U1");
    makeSession(store, "a1:C1:301.1", "a1", 1000);
    makeSession(store, "a2:C1:301.1", "a2", 2000);
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 1000)").run(t2.id, "a1:C1:301.1", "a1");
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 2000)").run(t2.id, "a2:C1:301.1", "a2");
    store.db.prepare("UPDATE sessions SET archived_at = 5000, archived_by = ? WHERE key = ?").run(AUTO, "a1:C1:301.1");
    store.settleConversation(t2.id);
    assert.equal(store.conversationOf("a2:C1:301.1"), "a1:C1:301.1");
    assert.equal(store.getSession("a1:C1:301.1")?.archivedAt, null);

    // All auto-archived: merges with max archived_at.
    const t3 = store.openThread("slack:T1", "C1", "302.1", "T3", "U1");
    makeSession(store, "b1:C1:302.1", "b1", 1000);
    makeSession(store, "b2:C1:302.1", "b2", 2000);
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 1000)").run(t3.id, "b1:C1:302.1", "b1");
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 2000)").run(t3.id, "b2:C1:302.1", "b2");
    store.db.prepare("UPDATE sessions SET archived_at = 4000, archived_by = ? WHERE key = ?").run(AUTO, "b1:C1:302.1");
    store.db.prepare("UPDATE sessions SET archived_at = 7000, archived_by = ? WHERE key = ?").run(AUTO, "b2:C1:302.1");
    store.settleConversation(t3.id);
    assert.equal(store.conversationOf("b2:C1:302.1"), "b1:C1:302.1");
    assert.equal(store.getSession("b1:C1:302.1")?.archivedAt, 7000);
    assert.equal(store.getSession("b2:C1:302.1")?.archivedAt, 7000);

    // Share boundary: existing session does not merge into shared group; newly born session does.
    const t4 = store.openThread("slack:T1", "C1", "303.1", "T4", "U1");
    makeSession(store, "s1:C1:303.1", "s1", 1000);
    makeSession(store, "s2:C1:303.1", "s2", 2000);
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 1000)").run(t4.id, "s1:C1:303.1", "s1");
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 2000)").run(t4.id, "s2:C1:303.1", "s2");
    store.db.prepare("INSERT INTO chat_shares (session, shared, write, by, at) VALUES (?, '[]', 0, 'u', 1000)").run("s1:C1:303.1");
    store.settleConversation(t4.id);
    assert.equal(store.conversationOf("s2:C1:303.1"), "s2:C1:303.1");
    // Newly born s3 merges into shared s1.
    makeSession(store, "s3:C1:303.1", "s3", 3000);
    store.joinThread(t4.id, "s3:C1:303.1", "s3");
    assert.equal(store.conversationOf("s3:C1:303.1"), "s1:C1:303.1");
  } finally {
    store.close();
  }
});

test("deleteSession re-anchors conversation and updates threads.home", () => {
  const store = Store.open(":memory:");
  try {
    const t = store.openThread("slack:T1", "C1", "400.1", "T", "U1");
    makeSession(store, "b1:C1:400.1", "b1", 1000);
    makeSession(store, "b2:C1:400.1", "b2", 2000);
    makeSession(store, "b3:C1:400.1", "b3", 3000);
    store.joinThread(t.id, "b1:C1:400.1", "b1");
    store.joinThread(t.id, "b2:C1:400.1", "b2");
    store.joinThread(t.id, "b3:C1:400.1", "b3");
    const home = store.openThreadOf(STILLFAIL_SURFACE, "CHAT", "400.99", "H", "U1", "b1:C1:400.1");
    store.joinThread(home.id, "b1:C1:400.1", STILLFAIL_CONNECT);
    store.joinThread(home.id, "b2:C1:400.1", STILLFAIL_CONNECT);
    store.joinThread(home.id, "b3:C1:400.1", STILLFAIL_CONNECT);

    store.deleteSession("b1:C1:400.1");
    assert.equal(store.conversationOf("b2:C1:400.1"), "b2:C1:400.1");
    assert.equal(store.conversationOf("b3:C1:400.1"), "b2:C1:400.1");
    assert.equal(store.getThread(home.id)?.home, "b2:C1:400.1");
  } finally {
    store.close();
  }
});

test("startup repair converges mixed archive states and showChat settles", () => {
  const dir = mkdtempSync(join(tmpdir(), "conv-repair-"));
  const dbPath = join(dir, "stillfail.db");
  try {
    const s1 = Store.open(dbPath, join(dir, "archive"));
    const t = s1.openThread("slack:T1", "C1", "500.1", "T", "U1");
    makeSession(s1, "r1:C1:500.1", "r1", 1000);
    makeSession(s1, "r2:C1:500.1", "r2", 2000);
    makeSession(s1, "r3:C1:500.1", "r3", 3000);
    s1.joinThread(t.id, "r1:C1:500.1", "r1");
    s1.joinThread(t.id, "r2:C1:500.1", "r2");
    s1.joinThread(t.id, "r3:C1:500.1", "r3");
    const home = s1.openThreadOf(STILLFAIL_SURFACE, "CHAT", "500.99", "H", "U1", "r1:C1:500.1");
    s1.joinThread(home.id, "r1:C1:500.1", STILLFAIL_CONNECT);
    s1.joinThread(home.id, "r2:C1:500.1", STILLFAIL_CONNECT);
    s1.joinThread(home.id, "r3:C1:500.1", STILLFAIL_CONNECT);
    // Simulate downgrade: r1 manually archived, r2 auto-archived, r3 live, home hidden.
    s1.db.prepare("UPDATE sessions SET archived_at = 5000, archived_by = ? WHERE key = ?").run(MANUAL, "r1:C1:500.1");
    s1.db.prepare("UPDATE sessions SET archived_at = 6000, archived_by = ? WHERE key = ?").run(AUTO, "r2:C1:500.1");
    s1.db.prepare("UPDATE threads SET hidden_at = 5000, hidden_by = ? WHERE id = ?").run(MANUAL, home.id);
    s1.close();

    // Reopen triggers startup repair: r1 detaches (conv=NULL), r2 restored & becomes new anchor with r3, home unhidden & re-homed to r2.
    const s2 = Store.open(dbPath, join(dir, "archive"));
    try {
      assert.equal(s2.conversationOf("r1:C1:500.1"), "r1:C1:500.1");
      assert.equal(s2.getSession("r1:C1:500.1")?.archivedBy, MANUAL);
      assert.equal(s2.conversationOf("r2:C1:500.1"), "r2:C1:500.1");
      assert.equal(s2.conversationOf("r3:C1:500.1"), "r2:C1:500.1");
      assert.equal(s2.getSession("r2:C1:500.1")?.archivedAt, null);
      assert.equal(s2.getThread(home.id)?.home, "r2:C1:500.1");
      assert.equal(s2.getThread(home.id)?.hiddenAt, null);

      // showChat settles newly activated coming session.
      makeSession(s2, "r4:C1:500.1", "r4", 4000, { ws: comingWs("ws1") });
      s2.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 4000)").run(t.id, "r4:C1:500.1", "r4");
      assert.equal(s2.conversationOf("r4:C1:500.1"), "r4:C1:500.1");
      s2.showChat(["r4:C1:500.1"], null);
      assert.equal(s2.conversationOf("r4:C1:500.1"), "r2:C1:500.1");
    } finally {
      s2.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("sessions_conv index bounds membersOf and backfill queries", () => {
  const store = Store.open(":memory:");
  try {
    const planMembers = (store.db.prepare(
      "EXPLAIN QUERY PLAN SELECT key FROM sessions WHERE conv = ?1 UNION SELECT key FROM sessions WHERE key = ?1",
    ).all("a") as { detail: string }[]).map((r) => r.detail).join(" | ");
    assert.match(planMembers, /sessions_conv/);
    assert.doesNotMatch(planMembers, /SCAN sessions/);

    const planRepair = (store.db.prepare(
      "EXPLAIN QUERY PLAN SELECT key, conv FROM sessions INDEXED BY sessions_conv WHERE conv IS NOT NULL",
    ).all() as { detail: string }[]).map((r) => r.detail).join(" | ");
    assert.match(planRepair, /sessions_conv/);

    // Backfill settles ungrouped scope=thread sessions using sessions_conv.
    const t = store.openThread("slack:T1", "C1", "600.1", "T", "U1");
    makeSession(store, "bf1:C1:600.1", "bf1", 1000);
    makeSession(store, "bf2:C1:600.1", "bf2", 2000);
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 1000)").run(t.id, "bf1:C1:600.1", "bf1");
    store.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, 2000)").run(t.id, "bf2:C1:600.1", "bf2");
    assert.equal(store.conversationOf("bf2:C1:600.1"), "bf2:C1:600.1");
    const settled = new Set<number>();
    const step = backfillConversationsStep(store, "", settled, 32);
    assert.equal(step.done, true);
    assert.equal(store.conversationOf("bf2:C1:600.1"), "bf1:C1:600.1");
  } finally {
    store.close();
  }
});
