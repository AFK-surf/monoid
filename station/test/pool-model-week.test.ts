// A model's own week under a Claude subscription's (Fable's, quota.ts `claudeScoped`) weighs on the pool for that model.
// 2026-11-14: a Fable chat ran out on one account and was moved to another whose Fable week the allowance showed used up
// (its account's own week had room), which failed at once and moved it again: two notices for one turn.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Rig, testClock } from "./hub-fakes.ts";

test("an account whose model's own week is used up is passed over for that model, not for others", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  try {
    r.edit((raw) => {
      raw.profiles[0].models = ["claude-fable-5-2", "sonnet"];
      raw.profiles.push({ ...raw.profiles[0], id: "cc2", name: "second" });
    });
    const now = time.clock.currentTimeMillisUnsafe();
    const week = 7 * 24 * 60 * 60 * 1000;
    const window = (usedPercent: number) => ({ label: "每周", usedPercent, resetsAt: now + week / 2, minutes: 10080 });
    const fable = { label: "每周 · Fable", usedPercent: 100, resetsAt: now + week / 2, minutes: 10080, scope: "Fable" };
    // The first has more of its account's week left, so the pool would take it, but its Fable week is used up.
    r.hub.accounts.setHealth((id) =>
      id === "cc"
        ? { account: "a1", quota: { state: "ok", windows: [window(10)], scoped: [fable], detail: null, checkedAt: now } }
        : { account: "a2", quota: { state: "ok", windows: [window(60)], scoped: [{ ...fable, usedPercent: 20 }], detail: null, checkedAt: now } },
    );
    const claude = r.config.profiles.filter((p) => p.runtime === "claude");
    assert.equal(r.hub.accounts.pick(claude, "claude-fable-5-2", true).id, "cc2");
    assert.equal(r.hub.accounts.pick(claude, "sonnet", true).id, "cc");
  } finally {
    await r.close();
  }
});
