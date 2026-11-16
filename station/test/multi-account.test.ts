// Multi-account selection (`sessions.profiles`, `connect.bind.profiles`): a session kept to a chosen subset of accounts
// picks, repicks, fails over and waits for refills strictly within that subset without leaking to unselected accounts;
// a single account behaves as pinned, and null gives the choice back to all eligible accounts.
import assert from "node:assert/strict";
import { test } from "node:test";
import { sessionKey } from "../src/sessions/hub.ts";
import { configure, newSession } from "../src/sessions/lifecycle.ts";
import { Rig, reply, say, settle, testClock } from "./hub-fakes.ts";

const chat = (runtime: "claude" | "codex" = "claude") => ({ runtime, createdBy: "local" });

test("a session kept to a subset of accounts rotates, repicks and fails over only within that subset", async () => {
  const r = new Rig();
  try {
    r.edit((raw) => {
      raw.profiles[0].models = ["opus", "sonnet"];
      raw.profiles.push(
        { ...raw.profiles[0], id: "cc2", name: "second", models: ["opus", "sonnet"] },
        { ...raw.profiles[0], id: "cc3", name: "third", models: ["opus", "sonnet"] },
      );
    });
    // Created with two of the three accounts: unpinned, restricted to [cc, cc2].
    const [key] = newSession(r.hub, { ...chat(), model: "opus", profiles: ["cc", "cc2"] });
    let row = r.session(key);
    assert.equal(row.profilePinned, false);
    assert.deepEqual(row.profiles, ["cc", "cc2"]);
    assert.ok(["cc", "cc2"].includes(row.profile));

    // When the first account hits its allowance, spend moves to the other checked account (never cc3) and keeps [cc, cc2].
    const first = row.profile;
    const other = first === "cc" ? "cc2" : "cc";
    const moved = r.hub.accounts.spend(key, first);
    assert.ok(moved !== null);
    row = r.session(key);
    assert.equal(row.profile, other);
    assert.deepEqual(row.profiles, ["cc", "cc2"]);

    // When both checked accounts are spent, it does NOT leak to cc3 (which is healthy): it stays and waits for their refill.
    assert.equal(r.hub.accounts.spend(key, other), null);
    assert.equal(r.hub.accounts.goesOnWith(r.session(key), "cc3"), false);
    assert.equal(r.hub.accounts.goesOnWith(r.session(key), first), true);
    assert.equal(r.hub.accounts.runOn(key).id, other);
    assert.ok(r.hub.accounts.refillsAt(key) > r.hub.now());

    // Resetting first's allowance allows repick within [cc, cc2] without clearing the subset.
    r.hub.accounts.resetAllowance(first);
    await configure(r.hub, key, { profiles: ["cc", "cc2"], repick: true });
    row = r.session(key);
    assert.equal(row.profile, first);
    assert.deepEqual(row.profiles, ["cc", "cc2"]);

    // Unchecking the active account (keeping [cc2, cc3] when on cc) moves immediately into [cc2, cc3].
    r.hub.accounts.resetAllowance(other);
    await configure(r.hub, key, { profiles: ["cc2", "cc3"] });
    row = r.session(key);
    assert.ok(["cc2", "cc3"].includes(row.profile));
    assert.deepEqual(row.profiles, ["cc2", "cc3"]);

    // Narrowing to one account pins it; null gives the choice back to all accounts (全选).
    await configure(r.hub, key, { profiles: ["cc3"] });
    row = r.session(key);
    assert.deepEqual([row.profile, row.profilePinned, row.profiles], ["cc3", true, ["cc3"]]);

    await configure(r.hub, key, { profiles: null });
    row = r.session(key);
    assert.deepEqual([row.profilePinned, row.profiles], [false, null]);
    assert.equal(r.hub.accounts.goesOnWith(row, "cc"), true);
  } finally {
    await r.close();
  }
});

test("a connect bound to multiple accounts starts its sessions on that subset", async () => {
  const r = new Rig();
  try {
    r.edit((raw) => {
      raw.profiles[0].models = ["opus"];
      raw.profiles.push(
        { ...raw.profiles[0], id: "cc2", name: "second", models: ["opus"] },
        { ...raw.profiles[0], id: "cc3", name: "third", models: ["opus"] },
      );
      delete raw.connects.find((c: any) => c.id === "cl").bind.profile;
      raw.connects.find((c: any) => c.id === "cl").bind.profiles = ["cc2", "cc3"];
    });
    const m = say("<@UBOT> hi");
    await r.accept(m);
    await settle();
    const row = r.session(sessionKey("cl", "C1", m.threadTs));
    assert.equal(row.profilePinned, false);
    assert.deepEqual(row.profiles, ["cc2", "cc3"]);
    assert.ok(["cc2", "cc3"].includes(row.profile));
  } finally {
    await r.close();
  }
});

test("a session left to the station whose runtime has no other account for its model goes on on another runtime's that runs it", async () => {
  const r = new Rig();
  try {
    r.edit((raw) => {
      raw.profiles[0].models = ["gemini-4-argon"];
      raw.profiles[1].models = ["gemini-4-argon"];
    });
    const [key] = newSession(r.hub, { ...chat(), model: "gemini-4-argon" });
    assert.equal(r.session(key).profile, "cc");

    // Its account spent and no other of Claude Code's runs the model: it moves to the Codex account that does.
    const moved = r.hub.accounts.spend(key, "cc");
    assert.ok(moved !== null);
    const row = r.session(key);
    assert.deepEqual([row.runtime, row.profile, row.model, row.profilePinned], ["codex", "cx", "gemini-4-argon", false]);

    // Kept to its accounts it does not cross: spent there, it waits.
    const [kept] = newSession(r.hub, { ...chat(), model: "gemini-4-argon", profiles: ["cc"] });
    assert.equal(r.hub.accounts.spend(kept, "cc"), null);
    assert.equal(r.session(kept).runtime, "claude");
  } finally {
    await r.close();
  }
});

test("a session whose model no other runtime's account runs stays on its runtime when spent", async () => {
  const r = new Rig();
  try {
    r.edit((raw) => {
      raw.profiles[0].models = ["opus"];
      raw.profiles[1].models = ["gpt-6-sol"];
    });
    const [key] = newSession(r.hub, { ...chat(), model: "opus" });
    assert.equal(r.hub.accounts.spend(key, "cc"), null);
    assert.equal(r.session(key).runtime, "claude");
  } finally {
    await r.close();
  }
});

test("before a turn, a session left to the station whose runtime has no account able to run its model goes on on another runtime's that can, without first running into the limit", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  try {
    r.edit((raw) => {
      raw.profiles[0].models = ["gemini-4-argon"];
      raw.profiles[1].models = ["gemini-4-argon"];
      raw.profiles.push({ ...raw.profiles[0], id: "cc2", name: "second" });
      raw.connects.find((c: any) => c.id === "cl").bind = { runtime: "claude", model: "gemini-4-argon" };
    });
    const now = r.hub.now();
    const hour = 60 * 60 * 1000;
    // Claude Code's accounts' five hours used up once `claudeFull` (Codex's, refilling sooner, once `codexFull`).
    let claudeFull = false;
    let codexFull = false;
    const window = (usedPercent: number, resetsAt: number) => ({ label: "5 小时", usedPercent, resetsAt, minutes: 300 });
    r.hub.accounts.setHealth((id) => ({
      account: id,
      check: { state: "ok" },
      quota: { state: "ok", checkedAt: now, windows: [id === "cx" ? window(codexFull ? 100 : 10, now + hour / 2) : window(claudeFull ? 100 : 10, now + hour)] },
    }));
    const moves = () => r.chat.texts().filter((t) => t.startsWith("已切换"));
    // Two sessions on Claude Code, each a turn done: one's process kept warm, the other's ended.
    const started = async (text: string) => {
      const m = say(`<@UBOT> ${text}`);
      await r.accept(m);
      await settle();
      const agent = r.claude.last();
      const key = agent.options.route;
      assert.equal(r.session(key).runtime, "claude");
      await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "done", kind: "all_done", done: "The greeting is answered." });
      agent.complete();
      await settle();
      return { m, agent, key };
    };
    const warm = await started("hi");
    const cold = await started("again");
    await r.hub.evict(cold.key);
    await settle();
    assert.ok(cold.agent.disposed);
    claudeFull = true;

    // The warm one's next message is taken on by Codex before its turn.
    const before = moves().length;
    await r.accept(reply(warm.m, `${Number(warm.m.ts) + 1}.000100`, "<@UBOT> next"));
    await settle();
    assert.equal(warm.agent.prompts.length, 1, "no turn on Claude Code's spent accounts");
    assert.ok(warm.agent.disposed, "its Claude Code process ended");
    assert.deepEqual([r.session(warm.key).runtime, r.session(warm.key).profile, r.session(warm.key).model], ["codex", "cx", "gemini-4-argon"]);
    const onCodex = (key: string) => r.codex.sessions.filter((s) => s.options.route === key);
    assert.equal(onCodex(warm.key).length, 1);
    assert.equal(onCodex(warm.key)[0]!.options.profile.id, "cx");
    assert.equal(onCodex(warm.key)[0]!.prompts.length, 1);
    assert.ok(onCodex(warm.key)[0]!.prompts[0]!.includes("next"), onCodex(warm.key)[0]!.prompts[0]);
    assert.equal(moves().length, before + 1, r.chat.texts().join("\n"));

    // The cold one is opened on Codex at once.
    await r.accept(reply(cold.m, `${Number(cold.m.ts) + 1}.000100`, "<@UBOT> more"));
    await settle();
    assert.equal(cold.agent.prompts.length, 1, "no turn on Claude Code's spent accounts");
    assert.equal(r.claude.sessions.filter((s) => s.options.route === cold.key).length, 1, "no Claude Code process opened again");
    assert.equal(r.session(cold.key).runtime, "codex");
    assert.equal(onCodex(cold.key).length, 1);
    assert.ok(onCodex(cold.key)[0]!.prompts[0]!.includes("more"), onCodex(cold.key)[0]!.prompts[0]);
    assert.equal(moves().length, before + 2, r.chat.texts().join("\n"));

    // Kept to its accounts it does not cross: it waits on them.
    const [kept] = newSession(r.hub, { ...chat(), model: "gemini-4-argon", profiles: ["cc", "cc2"] });
    assert.ok(r.hub.accounts.runOn(kept, false, false, true).runtimes.includes("claude"));
    assert.equal(r.session(kept).runtime, "claude");
    // Asked without `across` (taken over, configured by hand), one left to the station stays on its runtime.
    const [left] = newSession(r.hub, { ...chat(), model: "gemini-4-argon" });
    assert.ok(r.hub.accounts.runOn(left).runtimes.includes("claude"));
    assert.equal(r.session(left).runtime, "claude");
    // It wakes when another runtime's account could take it on: at once while one can, else at its refill; a reset of
    // that account wakes it too.
    assert.equal(r.hub.accounts.refillsAt(left), r.hub.now());
    codexFull = true;
    assert.equal(r.hub.accounts.refillsAt(left), now + hour / 2);
    assert.equal(r.hub.accounts.goesOnWith(r.session(left), "cx"), true);
    assert.equal(r.hub.accounts.goesOnWith(r.session(kept), "cx"), false);
  } finally {
    await r.close();
  }
});
