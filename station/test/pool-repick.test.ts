// 2026-11-16: repick chose an unreachable shared account with stale headroom, then runOn moved the chat back to its
// spent account 10 ms later. Both choices must prefer an account that signs in when none can run the model now.
import assert from "node:assert/strict";
import { test } from "node:test";
import { configure } from "../src/sessions/lifecycle.ts";
import { Rig, message, settle, testClock } from "./hub-fakes.ts";

test("repicking a spent model does not send it to an unreachable account and back", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  try {
    const m = message();
    await r.accept(m);
    await settle();
    const agent = r.claude.last();
    const key = agent.options.route;
    await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "done", kind: "all_done", done: "The requested change is checked." });
    agent.complete();
    await settle();
    r.edit((raw) => {
      raw.profiles[0].models = ["opus", "sonnet"];
      raw.profiles.push({ ...raw.profiles[0], id: "cc2", name: "shared account" });
    });
    const now = time.clock.currentTimeMillisUnsafe();
    const week = 7 * 24 * 60 * 60 * 1000;
    const window = (usedPercent: number) => ({ label: "每周", usedPercent, resetsAt: now + week, minutes: 10080 });
    let reachable = false;
    r.hub.accounts.setHealth((id) => ({
      account: id,
      check: { state: id === "cc2" && !reachable ? "failed" : "ok" },
      quota: {
        state: "ok", checkedAt: now,
        windows: [window(id === "cc" ? 84 : 35)],
        scoped: [{ ...window(id === "cc" ? 100 : 22), scope: "Opus", label: "每周 · Opus" }],
      },
    }));
    const claude = r.config.profiles.filter((p) => p.runtime === "claude");
    r.hub.accounts.repick(key);
    assert.equal(r.session(key).profile, "cc", "no intermediate move to the unreachable account");
    assert.equal(r.hub.accounts.pick(claude, "opus", true).id, "cc", "new chats use the same fallback");
    const posts = r.chat.posts.length;
    await configure(r.hub, key, { repick: true });
    await settle();
    assert.equal(r.session(key).profile, "cc");
    assert.equal(r.hub.accounts.runOn(key).id, "cc");
    assert.equal(r.chat.posts.length, posts, "no misleading account-switch notice");
    assert.equal(r.claude.last(), agent, "the process is kept");
    // Its station answers again: the shared account's remaining model allowance can now take the chat.
    reachable = true;
    await configure(r.hub, key, { repick: true });
    await settle();
    assert.equal(r.session(key).profile, "cc2");
    assert.equal(r.hub.accounts.runOn(key).id, "cc2");
    // An explicit choice still keeps a chat to its chosen account, even when that account cannot sign in.
    await configure(r.hub, key, { profile: "cc2" });
    reachable = false;
    assert.equal(r.hub.accounts.runOn(key).id, "cc2");
    assert.ok(r.session(key).profilePinned);
  } finally {
    await r.close();
  }
});
