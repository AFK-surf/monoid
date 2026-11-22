import assert from "node:assert/strict";
import { test } from "node:test";
import { ensureConversationChat } from "../src/sessions/lifecycle.ts";
import { Rig } from "./hub-fakes.ts";

test("homeChat, sessionHomeThread, and idempotent ensureConversationChat (§3.3)", async () => {
  const r = new Rig();
  try {
    const slack = r.store.openThread("slack:T1", "C1", "100.1", "Slack topic", "U1");
    r.store.insertSession({
      key: "bot1:C1:100.1", connect: "bot1", scope: "thread", title: "Anchor Title",
      runtime: "claude", profile: "cc", workspace: "/w/1", token: "t1", createdAt: 1000, lastActiveAt: 1000,
    });
    r.store.insertSession({
      key: "bot2:C1:100.1", connect: "bot2", scope: "thread", title: "Second Title",
      runtime: "claude", profile: "cc", workspace: "/w/2", token: "t2", createdAt: 2000, lastActiveAt: 2000,
    });
    r.store.joinThread(slack.id, "bot1:C1:100.1", "bot1");
    r.store.joinThread(slack.id, "bot2:C1:100.1", "bot2");

    // Calling via non-anchor member creates one home chat anchored on bot1, with anchor's title and both members.
    const c1 = ensureConversationChat(r.hub, "bot2:C1:100.1", "ada@example.com", null);
    assert.equal(c1.home, "bot1:C1:100.1");
    assert.equal(c1.title, "Anchor Title");
    assert.deepEqual(r.store.threadSessions(c1.id).map((m) => m.session).sort(), ["bot1:C1:100.1", "bot2:C1:100.1"]);

    // Repeated calls via either member return the exact same chat.
    const c2 = ensureConversationChat(r.hub, "bot1:C1:100.1", "ada@example.com", "Ignored");
    const c3 = ensureConversationChat(r.hub, "bot2:C1:100.1", "ada@example.com", "Ignored2");
    assert.equal(c2.id, c1.id);
    assert.equal(c3.id, c1.id);

    // homeChat and sessionHomeThread resolve to the same chat for both members.
    assert.equal(r.store.homeChat("bot1:C1:100.1")?.id, c1.id);
    assert.equal(r.store.homeChat("bot2:C1:100.1")?.id, c1.id);
    assert.equal(r.store.sessionHomeThread("bot1:C1:100.1")?.thread.id, c1.id);
    assert.equal(r.store.sessionHomeThread("bot2:C1:100.1")?.thread.id, c1.id);

    // Left member is excluded from newly created chat; if all left, requesting session is added.
    const slack2 = r.store.openThread("slack:T1", "C1", "200.1", "Slack2", "U1");
    r.store.insertSession({
      key: "a:C1:200.1", connect: "a", scope: "thread", title: "A",
      runtime: "claude", profile: "cc", workspace: "/w/a", token: "ta", createdAt: 1000, lastActiveAt: 1000,
    });
    r.store.insertSession({
      key: "b:C1:200.1", connect: "b", scope: "thread", title: "B",
      runtime: "claude", profile: "cc", workspace: "/w/b", token: "tb", createdAt: 2000, lastActiveAt: 2000,
    });
    r.store.joinThread(slack2.id, "a:C1:200.1", "a");
    r.store.joinThread(slack2.id, "b:C1:200.1", "b");
    r.store.leaveThread(slack2.id, "b:C1:200.1");

    const chat2 = ensureConversationChat(r.hub, "a:C1:200.1", "ada@example.com", null);
    assert.deepEqual(r.store.threadSessions(chat2.id).map((m) => m.session), ["a:C1:200.1"]);
    // b left so b is not a member of chat2 -> sessionHomeThread(b) is null, while homeChat(b) still returns chat2.
    assert.equal(r.store.homeChat("b:C1:200.1")?.id, chat2.id);
    assert.equal(r.store.sessionHomeThread("b:C1:200.1"), null);

    // All members left -> requesting session is added so chat is never empty.
    const slack3 = r.store.openThread("slack:T1", "C1", "300.1", "Slack3", "U1");
    r.store.insertSession({
      key: "x:C1:300.1", connect: "x", scope: "thread", title: "X",
      runtime: "claude", profile: "cc", workspace: "/w/x", token: "tx", createdAt: 1000, lastActiveAt: 1000,
    });
    r.store.insertSession({
      key: "y:C1:300.1", connect: "y", scope: "thread", title: "Y",
      runtime: "claude", profile: "cc", workspace: "/w/y", token: "ty", createdAt: 2000, lastActiveAt: 2000,
    });
    r.store.joinThread(slack3.id, "x:C1:300.1", "x");
    r.store.joinThread(slack3.id, "y:C1:300.1", "y");
    r.store.leaveThread(slack3.id, "x:C1:300.1");
    r.store.leaveThread(slack3.id, "y:C1:300.1");

    const chat3 = ensureConversationChat(r.hub, "y:C1:300.1", "ada@example.com", null);
    assert.equal(chat3.home, "x:C1:300.1");
    assert.deepEqual(r.store.threadSessions(chat3.id).map((m) => m.session), ["y:C1:300.1"]);
  } finally {
    await r.close();
  }
});
