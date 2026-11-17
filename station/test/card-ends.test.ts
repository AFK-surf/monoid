// A card that stops waiting changes where its thread's platform shows it (connects/card-ends.ts): the connect's
// surface is told its post, its card and why; a station chat's, or a surface without cards, is not.
import assert from "node:assert/strict";
import { test } from "node:test";
import { type CardEnd, showEnded } from "../src/connects/card-ends.ts";
import type { ChatSurface, ThreadRef } from "../src/sessions/chat.ts";
import { newMessage } from "../src/store/rows.ts";
import { Store } from "../src/store/store.ts";

function rig(surface: string) {
  const store = Store.open(":memory:", null);
  store.insertSession({ key: "a", connect: "ds", runtime: "claude", profile: "cc", workspace: "/w/a", token: "a", createdAt: 1, lastActiveAt: 1 });
  const thread = store.openThread(surface, "C1", "1.1", null, null);
  store.joinThread(thread.id, "a", "ds");
  const told: [ThreadRef, string, string, CardEnd][] = [];
  const chat = { cards: true, cardEnded: async (at: ThreadRef, ts: string, text: string, _card: unknown, end: CardEnd) => void told.push([at, ts, text, end]) } as unknown as ChatSurface;
  const asked: string[] = [];
  const stop = store.subscribe((change) => showEnded(store, (connect) => (asked.push(connect), chat), change));
  return { store, thread, told, asked, stop };
}

test("a card a person's message closed is changed where its connect shows it, as the message reaches its agent", () => {
  const r = rig("slack:T1");
  try {
    r.store.insertMessage({ ...newMessage(r.thread.id, "1.2", "agent", "a", "合并吗？"), card: { type: "options", options: [{ label: "合并" }] } });
    assert.deepEqual(r.told, []);
    const [n] = r.store.insertMessage(newMessage(r.thread.id, "1.3", "person", "U1", "等等"));
    // (a word in the thread not handed to its agent, someone's to someone else not mentioning it, leaves it waiting)
    assert.deepEqual(r.told, []);
    assert.notEqual(r.store.pendingCard(r.thread.id), null);
    r.store.deliver(r.thread.id, n, ["a"]);
    assert.deepEqual(r.told, [[{ channel: "C1", threadTs: "1.1" }, "1.2", "合并吗？", { why: "message", by: "U1", byTs: "1.3" }]]);
    assert.equal(r.store.pendingCard(r.thread.id), null);
    assert.ok(r.asked.every((c) => c === "ds"));
  } finally {
    r.stop();
    r.store.close();
  }
});

test("an unprepared old chat tells its connect at the event, before a later withdrawal", () => {
  const r = rig("slack:T1");
  try {
    r.store.db.prepare("DELETE FROM card_post_scopes WHERE thread=?").run(r.thread.id);
    r.store.insertMessage({ ...newMessage(r.thread.id, "1.2", "agent", "a", "合并吗？"), card: { type: "text" } });
    const [n] = r.store.insertMessage(newMessage(r.thread.id, "1.3", "person", "U1", "等等"));
    r.store.deliver(r.thread.id, n, ["a"]);
    assert.deepEqual(r.told, [[{ channel: "C1", threadTs: "1.1" }, "1.2", "合并吗？", { why: "message", by: "U1", byTs: "1.3" }]]);
    assert.equal(r.store.withdrawCard("a", r.thread.id, "1.2"), true);
    assert.equal(r.told.length, 1, "a later withdrawal does not retell the answer");
  } finally { r.stop(); r.store.close(); }
});

test("a station chat's cards are the app's alone: no surface is asked", () => {
  const r = rig("ember");
  try {
    r.store.insertMessage({ ...newMessage(r.thread.id, "1.2", "agent", "a", "合并吗？"), card: { type: "options", options: [{ label: "合并" }] } });
    r.store.insertMessage(newMessage(r.thread.id, "1.3", "person", "U1", "等等"));
    assert.deepEqual([r.told, r.asked], [[], []]);
  } finally {
    r.stop();
    r.store.close();
  }
});

test("a system card (a login, a vault's secret) waits through what people say, in a platform's thread and in a chat", () => {
  for (const surface of ["slack:T1", "ember"]) {
    const r = rig(surface);
    try {
      r.store.insertMessage({ ...newMessage(r.thread.id, "1.2", "agent", "a", "登录一下"), card: { type: "login", login: "l1" } });
      const [n] = r.store.insertMessage(newMessage(r.thread.id, "1.3", "person", "U1", "稍等我拿手机"));
      r.store.deliver(r.thread.id, n, ["a"]);
      assert.deepEqual(r.told, [], surface);
      assert.equal(r.store.pendingCard(r.thread.id)?.[0].ts, "1.2", surface);
      // (a conversational card after it replaces it not: the login still waits, first)
      r.store.insertMessage({ ...newMessage(r.thread.id, "1.4", "agent", "a", "选一个？"), card: { type: "options", options: [{ label: "A" }] } });
      assert.equal(r.store.pendingCard(r.thread.id)?.[0].ts, "1.2", surface);
      // closed as it is decided (closeLoginCards, a vault's outcome, its withdrawal)
      assert.equal(r.store.withdrawCard("a", r.thread.id, "1.2"), true);
      assert.equal(r.store.pendingCard(r.thread.id)?.[0].ts, "1.4", surface);
    } finally { r.stop(); r.store.close(); }
  }
});

test("a vault's request card is a system card as its card says vault", () => {
  const r = rig("slack:T1");
  try {
    r.store.insertMessage({ ...newMessage(r.thread.id, "1.2", "agent", "a", "要用密钥"), card: { type: "options", options: [], vault: { request: "v1", name: "k", mode: "env", hosts: [] } } });
    const [n] = r.store.insertMessage(newMessage(r.thread.id, "1.3", "person", "U1", "好"));
    r.store.deliver(r.thread.id, n, ["a"]);
    assert.equal(r.store.pendingCard(r.thread.id)?.[0].ts, "1.2");
    assert.equal(r.store.db.prepare("SELECT COUNT(*) AS n FROM pending_system_cards").get()!.n, 1);
  } finally { r.stop(); r.store.close(); }
});
