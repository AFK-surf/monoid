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

test("repick and runOn move off a quota-unavailable subscription to healthy subscriptions and never move crowded onto unavailable", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  try {
    const m = message();
    await r.accept(m);
    await settle();
    const agent = r.claude.last();
    const key = agent.options.route;
    await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "done", kind: "all_done", done: "Initial turn finished." });
    agent.complete();
    await settle();
    r.edit((raw) => {
      raw.profiles[0].models = ["opus"];
      raw.profiles.push(
        { ...raw.profiles[0], id: "cc2", name: "Claude 2" },
        { ...raw.profiles[0], id: "cc3", name: "Claude 3" },
      );
    });
    const now = time.clock.currentTimeMillisUnsafe();
    const hour = 60 * 60 * 1000;
    const okQuota = (five: number, seven: number) => ({
      state: "ok",
      checkedAt: now,
      windows: [
        { label: "5 小时", usedPercent: five, resetsAt: now + 3 * hour, minutes: 300 },
        { label: "每周", usedPercent: seven, resetsAt: now + 5 * 24 * hour, minutes: 10080 },
      ],
    });
    const unavailableQuota = { state: "unavailable", checkedAt: now, windows: [], detail: "Claude 登录续期请求失败，请稍后重试" };
    let healths: Record<string, any> = {
      cc: { check: { state: "ok" }, quota: unavailableQuota },
      cc2: { check: { state: "ok" }, quota: okQuota(80, 50) },
      cc3: { check: { state: "ok" }, quota: okQuota(79, 50) },
    };
    r.hub.accounts.setHealth((id) => healths[id] ?? {});
    // repick must pick healthy cc2/cc3 rather than staying on unavailable cc.
    await configure(r.hub, key, { profile: null, repick: true });
    await settle();
    assert.ok(["cc2", "cc3"].includes(r.session(key).profile), `expected cc2 or cc3, got ${r.session(key).profile}`);

    // Pin to cc, then unpin so session is back on unavailable cc without cheapToLeave.
    await configure(r.hub, key, { profile: "cc" });
    await settle();
    assert.equal(r.session(key).profile, "cc");
    // Pinned stays on cc.
    assert.equal(r.hub.accounts.runOn(key).id, "cc");
    // Unpin by clearing profilePinned directly through store to test runOn directly.
    r.store.setSessionProfile(key, "cc", false, null);
    // Holding stays on cc.
    assert.equal(r.hub.accounts.runOn(key, true).id, "cc");
    // Not holding and not pinned: leaves unavailable cc immediately without cheapToLeave.
    const switched = r.hub.accounts.runOn(key, false);
    assert.ok(["cc2", "cc3"].includes(switched.id), `expected cc2 or cc3, got ${switched.id}`);

    // Healthy crowded account (cc2 at 85% 5h) must never move onto unavailable cc even when cheapToLeave would allow it.
    r.store.setSessionProfile(key, "cc2", false, null);
    healths = {
      cc: { check: { state: "ok" }, quota: unavailableQuota },
      cc2: { check: { state: "ok" }, quota: okQuota(85, 20) },
      cc3: { check: { state: "ok" }, quota: okQuota(100, 100) },
    };
    assert.equal(r.hub.accounts.runOn(key, false).id, "cc2");
  } finally {
    await r.close();
  }
});

test("auth failure triggers recheck to failed and auth_retry switches to a healthy subscription to finish the turn", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  try {
    r.edit((raw) => {
      raw.profiles[0].models = ["opus"];
      raw.profiles.push({ ...raw.profiles[0], id: "cc2", name: "Claude 2" });
    });
    let ccCheck = "ok";
    const rechecked: string[] = [];
    r.hub.accounts.setHealth((id) => ({
      check: { state: id === "cc" ? ccCheck : "ok" },
      quota: id === "cc" ? { state: "unavailable", windows: [], detail: "Claude 登录续期请求失败，请稍后重试" } : { state: "ok", windows: [{ label: "5 小时", usedPercent: 20, resetsAt: null }] },
    }));
    r.hub.accounts.setRecheck(async (id) => {
      rechecked.push(id);
      if (id === "cc") ccCheck = "failed";
    });
    const m = message();
    // Start session pinned to cc initially, then unpin before failing so auth_retry can switch.
    await r.accept(m);
    await settle();
    const first = r.claude.last();
    const key = first.options.route;
    // Force session onto cc if pick chose cc2, then start a turn on cc.
    if (first.options.profile.id !== "cc") {
      await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "init", kind: "all_done", done: "Initial turn finished on cc2." });
      first.complete();
      await settle();
      r.store.setSessionProfile(key, "cc", false, null);
      // Temporarily make cc2 spent so runOn stays on cc for this turn, then restore cc2 before auth failure.
      let cc2Spent = true;
      r.hub.accounts.setHealth((id) => ({
        check: { state: id === "cc" ? ccCheck : "ok" },
        quota: id === "cc"
          ? { state: "unavailable", windows: [], detail: "Claude 登录续期请求失败，请稍后重试" }
          : { state: "ok", windows: [{ label: "5 小时", usedPercent: cc2Spent ? 100 : 20, resetsAt: null }] },
      }));
      await r.accept({ ...m, ts: "1.2", text: "second" });
      await settle();
      cc2Spent = false;
    }
    const failing = r.claude.last();
    assert.equal(failing.options.profile.id, "cc");
    failing.end({ kind: "failed", reason: "auth", message: "Failed to authenticate. API Error: 401" });
    await settle();
    assert.deepEqual(rechecked, ["cc"]);
    const recovered = r.claude.last();
    assert.equal(recovered.options.profile.id, "cc2");
    await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "recovered", kind: "all_done", done: "Finished on cc2." });
    recovered.complete();
    await settle();
    assert.equal(r.session(key).profile, "cc2");
  } finally {
    await r.close();
  }
});
