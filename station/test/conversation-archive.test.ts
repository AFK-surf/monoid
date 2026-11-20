import assert from "node:assert/strict";
import { test } from "node:test";
import { archiveBy, autoArchive, ensureConversationChat } from "../src/sessions/lifecycle.ts";
import { AUTO, MANUAL } from "../src/store/rows.ts";
import { ARCHIVE_SESSION_SQL, UNARCHIVE_SESSION_SQL } from "../src/store/store.ts";
import { Rig } from "./hub-fakes.ts";

test("conversation archive: manual, bringBack, cold restore partial failure, and autoArchive (§4 A)", async () => {
  const r = new Rig();
  try {
    const slack = r.store.openThread("slack:T1", "C1", "100.1", "T", "U1");
    r.store.insertSession({
      key: "b1:C1:100.1", connect: "b1", scope: "thread", title: "B1",
      runtime: "claude", profile: "cc", workspace: "/w/1", token: "t1", createdAt: 1000, lastActiveAt: 1000,
    });
    r.store.insertSession({
      key: "b2:C1:100.1", connect: "b2", scope: "thread", title: "B2",
      runtime: "claude", profile: "cc", workspace: "/w/2", token: "t2", createdAt: 2000, lastActiveAt: 2000,
    });
    r.store.joinThread(slack.id, "b1:C1:100.1", "b1");
    r.store.joinThread(slack.id, "b2:C1:100.1", "b2");
    const home = ensureConversationChat(r.hub, "b1:C1:100.1", "ada@example.com", null);

    // Archiving via non-anchor archives BOTH members and hides home chat.
    await archiveBy(r.hub, "b2:C1:100.1", true, AUTO);
    assert.notEqual(r.store.getSession("b1:C1:100.1")?.archivedAt, null);
    assert.notEqual(r.store.getSession("b2:C1:100.1")?.archivedAt, null);
    assert.equal(r.store.getSession("b1:C1:100.1")?.archivedAt, r.store.getSession("b2:C1:100.1")?.archivedAt);
    assert.notEqual(r.store.getThread(home.id)?.hiddenAt, null);

    // New message in Slack thread brings back the ENTIRE conversation and unhides home chat.
    r.store.insertMessage({ thread: slack.id, ts: "100.2", authorKind: "person", author: "U1", text: "wake up" });
    assert.equal(r.store.getSession("b1:C1:100.1")?.archivedAt, null);
    assert.equal(r.store.getSession("b2:C1:100.1")?.archivedAt, null);
    assert.equal(r.store.getThread(home.id)?.hiddenAt, null);

    // Manual archive + partial cold restore failure keeps ENTIRE conversation archived.
    await archiveBy(r.hub, "b1:C1:100.1", true, MANUAL);
    const origRestore = r.hub.cold.restore;
    r.hub.cold.restore = (key: string) => {
      if (key === "b2:C1:100.1") return Promise.reject(new Error("cold disk error"));
      return Promise.resolve();
    };
    await assert.rejects(async () => { await archiveBy(r.hub, "b1:C1:100.1", false, MANUAL); }, /cold disk error/);
    assert.notEqual(r.store.getSession("b1:C1:100.1")?.archivedAt, null);
    assert.notEqual(r.store.getSession("b2:C1:100.1")?.archivedAt, null);
    assert.notEqual(r.store.getThread(home.id)?.hiddenAt, null);

    // Succeeding cold restore unarchives all members.
    r.hub.cold.restore = origRestore;
    await archiveBy(r.hub, "b2:C1:100.1", false, MANUAL);
    assert.equal(r.store.getSession("b1:C1:100.1")?.archivedAt, null);
    assert.equal(r.store.getSession("b2:C1:100.1")?.archivedAt, null);
    assert.equal(r.store.getThread(home.id)?.hiddenAt, null);
  } finally {
    await r.close();
  }
});

test("autoArchive only archives conversation when ALL members pass (§4 A)", async () => {
  const r = new Rig();
  try {
    const slack = r.store.openThread("slack:T1", "C1", "200.1", "T", "U1");
    r.store.insertSession({
      key: "b1:C1:200.1", connect: "b1", scope: "thread", title: "B1",
      runtime: "claude", profile: "cc", workspace: "/w/1", token: "t1", createdAt: 1000, lastActiveAt: 1000,
    });
    r.store.insertSession({
      key: "b2:C1:200.1", connect: "b2", scope: "thread", title: "B2",
      runtime: "claude", profile: "cc", workspace: "/w/2", token: "t2", createdAt: 1000, lastActiveAt: 1000,
    });
    r.store.joinThread(slack.id, "b1:C1:200.1", "b1");
    r.store.joinThread(slack.id, "b2:C1:200.1", "b2");
    // Mark b2 as running -> b1 is idle, b2 is busy -> NEITHER should be auto-archived.
    r.store.db.prepare("UPDATE sessions SET running = 1 WHERE key = ?").run("b2:C1:200.1");
    autoArchive(r.hub, 1000 + 30 * 86_400_000);
    assert.equal(r.store.getSession("b1:C1:200.1")?.archivedAt, null);
    assert.equal(r.store.getSession("b2:C1:200.1")?.archivedAt, null);

    // Once b2 is also idle, BOTH are auto-archived together.
    r.store.db.prepare("UPDATE sessions SET running = 0 WHERE key = ?").run("b2:C1:200.1");
    autoArchive(r.hub, 1000 + 30 * 86_400_000);
    assert.notEqual(r.store.getSession("b1:C1:200.1")?.archivedAt, null);
    assert.notEqual(r.store.getSession("b2:C1:200.1")?.archivedAt, null);
  } finally {
    await r.close();
  }
});

test("#setArchived archives a handed session itself and hides anchor home when legacy anchor has conv=NULL", () => {
  const r = new Rig();
  try {
    // 1. Handed session: archiving it directly still updates that session itself (not skipped by OWNED_WS_SQL).
    r.store.insertSession({
      key: "handed:C1:300.1", connect: "b1", scope: "thread", title: "Handed",
      runtime: "claude", profile: "cc", workspace: "/w/h", token: "th", createdAt: 1000, lastActiveAt: 1000,
      ws: "handed:station-b",
    });
    r.store.setArchived("handed:C1:300.1", true, MANUAL);
    assert.notEqual(r.store.getSession("handed:C1:300.1")?.archivedAt, null, "handed session itself must be archived");

    // 2. Legacy data: anchor has conv=NULL, member has conv=anchor. Archiving via member must hide anchor's home chat.
    r.store.insertSession({
      key: "leg1:C1:301.1", connect: "b1", scope: "thread", title: "Leg1",
      runtime: "claude", profile: "cc", workspace: "/w/l1", token: "tl1", createdAt: 1000, lastActiveAt: 1000,
    });
    r.store.insertSession({
      key: "leg2:C1:301.1", connect: "b2", scope: "thread", title: "Leg2",
      runtime: "claude", profile: "cc", workspace: "/w/l2", token: "tl2", createdAt: 2000, lastActiveAt: 2000,
    });
    r.store.db.prepare("UPDATE sessions SET conv = NULL WHERE key = 'leg1:C1:301.1'").run();
    r.store.db.prepare("UPDATE sessions SET conv = 'leg1:C1:301.1' WHERE key = 'leg2:C1:301.1'").run();
    const legHome = r.store.openThreadOf("ember", "CHAT", "leg1:C1:301.1", "Leg1", "ada@x.com", "leg1:C1:301.1");
    r.store.joinThread(legHome.id, "leg1:C1:301.1", "ember");
    r.store.joinThread(legHome.id, "leg2:C1:301.1", "ember");

    r.store.setArchived("leg2:C1:301.1", true, MANUAL);
    assert.notEqual(r.store.getSession("leg1:C1:301.1")?.archivedAt, null);
    assert.notEqual(r.store.getSession("leg2:C1:301.1")?.archivedAt, null);
    assert.notEqual(r.store.getThread(legHome.id)?.hiddenAt, null, "anchor's home chat must be hidden even when anchor.conv is NULL");
  } finally {
    r.close();
  }
});

test("#setArchived EXPLAIN QUERY PLAN uses PK and sessions_conv without SCAN sessions", () => {
  const r = new Rig();
  try {
    for (const [label, sql, params] of [
      ["archive", ARCHIVE_SESSION_SQL, [1000, MANUAL, "s1"]],
      ["unarchive", UNARCHIVE_SESSION_SQL, [1000, "s1"]],
    ] as const) {
      const rows = r.store.db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...params) as { detail: string }[];
      const plan = rows.map((row) => row.detail).join("\n");
      assert.doesNotMatch(plan, /\bSCAN sessions\b/, `${label} must not full-scan sessions:\n${plan}`);
      assert.match(plan, /sqlite_autoindex_sessions_1/, `${label} must use sessions PK:\n${plan}`);
      assert.match(plan, /sessions_conv/, `${label} must use sessions_conv index:\n${plan}`);
    }
  } finally {
    r.close();
  }
});
