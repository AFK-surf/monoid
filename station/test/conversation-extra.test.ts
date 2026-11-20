import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { cc } from "../src/sessions/cc.ts";
import { sessionKey } from "../src/sessions/hub.ts";
import { ensureConversationChat, newSession, say as sayIn } from "../src/sessions/lifecycle.ts";
import { relay } from "../src/sessions/relay.ts";
import type { Place, ThreadRef } from "../src/sessions/chat.ts";
import { Store, newMessage } from "../src/store/store.ts";
import { readersOf } from "./reference.ts";
import { CcIndexPreparation, CcSessionsUnavailable } from "./reference/backfill/cc-thread-index.ts";
import { Rig, message, settle } from "./hub-fakes.ts";

function preparedCcThreads(store: Store, thread: number): ReturnType<Store["ccThreads"]> {
  const work = new CcIndexPreparation();
  for (;;) {
    try { return store.ccThreads(thread); }
    catch (error) {
      if (!(error instanceof CcSessionsUnavailable)) throw error;
      for (const session of error.sessions) while (!work.step(store.db, session).done) {}
    }
  }
}

test("Step 6: multi-agent app chat names each Slack-born agent by its birth connect botName, not runtime+model", async () => {
  const r = new Rig();
  try {
    // Give both connects distinct botNames while both run the same runtime & model.
    Object.assign(r.chat, { botName: () => "AlphaBot" });
    Object.assign(r.gptChat, { botName: () => "BetaBot" });
    r.config.connects.find((c) => c.id === "gpt")!.bind = { runtime: "claude", profile: "cc", model: "opus" };
    r.config.connects.find((c) => c.id === "cl")!.bind = { runtime: "claude", profile: "cc", model: "opus" };

    const first = message({ channel: "C1", threadTs: "500.1", ts: "500.1", text: "<@UBOT> start" });
    await r.accept(first, "cl");
    await settle();
    await r.accept({ ...first, ts: "500.2", text: "<@UGPT> join" }, "gpt");
    await settle();

    const k1 = sessionKey("cl", "C1", "500.1");
    const k2 = sessionKey("gpt", "C1", "500.1");
    assert.equal(r.store.conversationOf(k2), k1);
    assert.equal(r.claude.sessions.length, 2);

    // Finish k2's initial turn so it is idle and ready to receive the next message.
    await r.call(k2, "chat_state", { kind: "all_done", done: "answered the initial message in Slack thread C1/500.1" });
    r.claude.sessions[1]!.end({ kind: "completed" });
    await settle();

    // Open the shared conversation app chat (INTERNAL_CONNECT).
    const chat = ensureConversationChat(r.hub, k1, "ada@x.com", null);

    // Agent 1 posts in the app chat; agent 2 receives it in a new turn.
    r.claude.sessions[0]!.reads();
    await r.call(k1, "chat_post", { to: `${chat.channel}/${chat.threadTs}`, text: "hello from alpha" });
    await settle();

    // Agent 2's prompt should name agent 1 as "AlphaBot", not "Claude opus".
    const k2Prompts = r.claude.sessions.flatMap((s) => s.prompts).filter((p) => p.includes("hello from alpha")).join("\n");
    assert.ok(k2Prompts.includes("AlphaBot"), `expected AlphaBot in prompt, got:\n${k2Prompts}`);
    assert.equal(k2Prompts.includes("from=\"Claude opus\""), false, "should not degrade to runtime + model");

    // Finish k2's second turn before testing the app-born agent fallback.
    await r.call(k2, "chat_state", { kind: "all_done", done: "acknowledged AlphaBot's message in the shared app chat" });
    r.claude.sessions[1]!.end({ kind: "completed" });
    await settle();

    // A session born directly in the app (INTERNAL_CONNECT) still falls back to runtime + model.
    const [appKey, appChat] = await newSession(r.hub, { runtime: "claude", createdBy: "ada@x.com" });
    r.store.joinThread(appChat.id, k2, "ember");
    r.store.insertMessage(newMessage(appChat.id, "500.9", "agent", appKey, "from app-born agent"));
    r.store.deliver(appChat.id, Number(r.store.db.prepare("SELECT MAX(n) AS n FROM entries WHERE thread = ?").get(appChat.id)!.n), [k2]);
    r.hub.wakeChat(k2);
    await settle();
    const appPrompt = r.claude.sessions.flatMap((s) => s.prompts).find((p) => p.includes("from app-born agent")) ?? "";
    assert.ok(appPrompt.includes("from=\"Claude"), `expected runtime label fallback for app-born agent, got:\n${appPrompt}`);
  } finally {
    await r.close();
  }
});

test("decider: two agents in one conversation resolve deciders independently by card assignee and thread ownership", async () => {
  const data = mkdtempSync(join(tmpdir(), "conv-decider-"));
  try {
    writeFileSync(join(data, "config.json"), JSON.stringify({ connects: [] }));
    const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
    const db = store.db;
    const slack = store.openThread("slack:T1", "C1", "10.1", "Shared", "U1");
    store.insertSession({ key: "cl:C1:10.1", connect: "cl", scope: "thread", runtime: "claude", profile: "cc", workspace: "/w/1", token: "t1", createdAt: 100, lastActiveAt: 100, createdBy: "starter@x.com" });
    store.insertSession({ key: "gpt:C1:10.1", connect: "gpt", scope: "thread", runtime: "codex", profile: "cx", workspace: "/w/2", token: "t2", createdAt: 200, lastActiveAt: 200, createdBy: "starter@x.com" });
    store.joinThread(slack.id, "cl:C1:10.1", "cl");
    store.joinThread(slack.id, "gpt:C1:10.1", "gpt");
    assert.equal(store.conversationOf("gpt:C1:10.1"), "cl:C1:10.1");

    const chat = store.openThreadOf("ember", "CHAT", "cl:C1:10.1", "cl:C1:10.1", "Shared", "starter@x.com");
    store.joinThread(chat.id, "cl:C1:10.1", "ember");
    store.joinThread(chat.id, "gpt:C1:10.1", "ember");

    // Agent 1 asks ada@x.com via an assigned card; Agent 2 answers bo@x.com with need_help.
    store.insertMessage({ ...newMessage(chat.id, "1", "person", "bo@x.com", "check this"), at: 1000 });
    store.insertMessage({
      ...newMessage(chat.id, "2", "agent", "cl:C1:10.1", "approve?"),
      at: 2100,
      card: { type: "options", assignee: "ada@x.com", options: [{ label: "Yes" }] },
    });
    store.insertMessage({ ...newMessage(chat.id, "3", "agent", "gpt:C1:10.1", "need key"), at: 2150 });
    db.prepare("INSERT INTO turns(id,session_key,kind,started_at,ended_at,outcome,declared,need) VALUES (?,?,'input',?,?,?,?,?)")
      .run("turn-1", "cl:C1:10.1", 2000, 2200, "completed", "need_decision", "approve");
    db.prepare("INSERT INTO turns(id,session_key,kind,started_at,ended_at,outcome,declared,need) VALUES (?,?,'input',?,?,?,?,?)")
      .run("turn-2", "gpt:C1:10.1", 2050, 2250, "completed", "need_help", "need key");

    const readers = readersOf(data, mbReaderBinary());
    try {
      // While agent 1's assigned card is pending on the shared thread, decider resolves to the card assignee.
      const n1 = JSON.parse(await readers.read("turnNotices", { key: "cl:C1:10.1", since: 0, ended: null, lang: "en" }, "en", { told: true })) as { notices?: { to: string[] }[] };
      const to1 = (n1.notices ?? (Array.isArray(n1) ? n1 : []))[0]?.to;
      assert.deepEqual(to1, ["ada@x.com"], `card assignee is the decider while card is pending, got ${JSON.stringify(n1)}`);

      // Once that card is withdrawn, agent 2's need_help resolves to the person whose message it answered on the thread.
      store.withdrawCard("cl:C1:10.1", chat.id, "2");
      const n2 = JSON.parse(await readers.read("turnNotices", { key: "gpt:C1:10.1", since: 0, ended: null, lang: "en" }, "en", { told: true })) as { notices?: { to: string[] }[] };
      const to2 = (n2.notices ?? (Array.isArray(n2) ? n2 : []))[0]?.to;
      assert.deepEqual(to2, ["bo@x.com"], `without pending card, person whose message agent 2 answered is decider, got ${JSON.stringify(n2)}`);
    } finally {
      readers.close();
      store.close();
    }
  } finally {
    rmSync(data, { recursive: true, force: true });
  }
});

test("cc: two agents in one conversation sharing a Slack thread deduplicate by thread and only cc picked destinations", async () => {
  const r = new Rig();
  try {
    const first = message({ channel: "C1", threadTs: "600.1", ts: "600.1", text: "<@UBOT> hi" });
    await r.accept(first, "cl");
    await r.accept({ ...first, ts: "600.2", text: "<@UGPT> hi" }, "gpt");
    await settle();

    const k1 = sessionKey("cl", "C1", "600.1");
    const k2 = sessionKey("gpt", "C1", "600.1");
    assert.equal(r.store.conversationOf(k2), k1);
    const slackThread = r.store.threadAt("slack:T1", "C1", "600.1")!;
    const otherThread = r.store.openThread("slack:T1", "C2", "600.9", null, "U1");
    r.store.joinThread(otherThread.id, k2, "gpt");

    const chat = ensureConversationChat(r.hub, k1, "ada@x.com", null);
    const candidates = preparedCcThreads(r.store, chat.id);
    // Shared Slack thread appears once (deduplicated by thread), not twice.
    assert.equal(candidates.filter((c) => c.thread.id === slackThread.id).length, 1);
    assert.equal(candidates.filter((c) => c.thread.id === otherThread.id).length, 1);

    // Only cc to the picked destination (slackThread), not otherThread.
    const postsBefore = r.chat.posts.length + r.gptChat.posts.length;
    await cc(r.hub, chat.id, "Ada", "ada@x.com", "update for C1 only", [], [slackThread.id]);
    const totalNewPosts = (r.chat.posts.length + r.gptChat.posts.length) - postsBefore;
    assert.equal(totalNewPosts, 1, "posted once to the single picked thread");
    assert.equal(r.said(otherThread.id).length, 0, "unpicked thread received nothing");
  } finally {
    await r.close();
  }
});

test("relay: two-agent conversation chat relays using the chat's first member, not necessarily the anchor", async () => {
  const r = new Rig({ link: true });
  try {
    const places: Place[] = [{ id: "C1", name: "general", kind: "channel" }];
    Object.assign(r.chat, {
      places: async () => places,
      begin: async (channel: string) => ({ thread: { channel, threadTs: "700.1" }, ts: "700.1" }),
      permalink: (t: ThreadRef) => `https://acme.slack.com/archives/${t.channel}/p${t.threadTs.replace(".", "")}`,
    });

    const slack = r.store.openThread("slack:T1", "C0", "700.0", "Origin", "U1");
    r.store.insertSession({ key: "anchor:C0:700.0", connect: "cl", scope: "thread", runtime: "claude", profile: "cc", workspace: "/w/a", token: "ta", createdAt: 100, lastActiveAt: 100 });
    r.store.insertSession({ key: "second:C0:700.0", connect: "gpt", scope: "thread", runtime: "codex", profile: "cx", workspace: "/w/b", token: "tb", createdAt: 200, lastActiveAt: 200 });
    r.store.joinThread(slack.id, "anchor:C0:700.0", "cl");
    r.store.joinThread(slack.id, "second:C0:700.0", "gpt");
    assert.equal(r.store.conversationOf("second:C0:700.0"), "anchor:C0:700.0");

    // Home chat where the non-anchor member was joined first.
    const chat = r.store.openThreadOf("ember", "CHAT", "anchor:C0:700.0", "anchor:C0:700.0", "Origin", "ada@x.com");
    r.store.joinThread(chat.id, "second:C0:700.0", "ember");
    r.store.joinThread(chat.id, "anchor:C0:700.0", "ember");
    sayIn(r.hub, chat.id, "ada@x.com", "hi");
    await settle();

    const done = await relay(r.hub, chat, { name: "Ada", email: "ada@x.com" }, { connect: "cl", channel: "C1" }, "");
    assert.equal(done.place, "#general");
    const relayedThread = r.store.threadAt("slack:T1", "C1", "700.1")!;
    const relayedMembers = r.store.threadSessions(relayedThread.id).map((m) => m.session);
    // relay joins the chat's first member (second:C0:700.0), not necessarily the anchor.
    assert.deepEqual(relayedMembers, ["second:C0:700.0"]);
  } finally {
    await r.close();
  }
});
