// Per-account configurable concurrency cap (`maxConcurrentSessions`), FIFO overflow queueing,
// automatic slot-release drain, and manual jump-the-queue start.
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Accounts as AccountManager, checkConfig, DEFAULT_NEW_SUBSCRIPTION_MAX_CONCURRENT_SESSIONS } from "../src/accounts/index.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { AccountCapError } from "../src/sessions/accounts.ts";
import { type SlotCoordinator } from "../src/sessions/hub.ts";
import { isSessionCapped, pickProfile } from "../src/sessions/pool.ts";
import { portable } from "../src/share/index.ts";
import { Store } from "../src/store/store.ts";
import { Rig, message, settle, testClock } from "./hub-fakes.ts";

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;

function okQuota(now: number, fivePct: number, weekPct: number, weekResetsInMs = 5 * DAY) {
  return {
    state: "ok",
    checkedAt: now,
    windows: [
      { label: "5 小时", usedPercent: fivePct, resetsAt: now + 3 * HOUR, minutes: 300 },
      { label: "每周", usedPercent: weekPct, resetsAt: now + weekResetsInMs, minutes: 10080 },
    ],
  };
}

test("pool: legacy unlimited accounts keep full urgency; capped accounts cap pace at 1.0 and prefer uncapped over capped without spilling to billed-per-use", () => {
  const now = 1_800_000_000_000;
  const cfg = hubConfig(
    {
      profiles: [
        { id: "legacy", name: "Legacy", runtime: "claude", access: { kind: "subscription" }, home: "h/legacy", models: ["opus"] },
        { id: "capped", name: "Capped", runtime: "claude", access: { kind: "subscription" }, home: "h/capped", models: ["opus"], maxConcurrentSessions: 2 },
        { id: "openrouter", name: "OpenRouter", runtime: "claude", access: { kind: "api-provider", provider: "openrouter", key: "k" }, home: "h/or", models: ["opus"] },
      ],
    },
    "/data",
  );
  const [legacy, capped, openrouter] = cfg.profiles;
  assert.equal(legacy!.maxConcurrentSessions, undefined);
  assert.equal(capped!.maxConcurrentSessions, 2);
  assert.equal(isSessionCapped(legacy!, legacy!.maxConcurrentSessions, 100), false);
  assert.equal(isSessionCapped(capped!, capped!.maxConcurrentSessions, 1), false);
  assert.equal(isSessionCapped(capped!, capped!.maxConcurrentSessions, 2), true);
  assert.equal(isSessionCapped(openrouter!, 1, 10), false);

  // Near-expiry weekly window on capped account has raw pace = 0.8 * 7 / 1 = 5.6,
  // but its pace is capped at 1.0 so it does NOT steal traffic from a legacy account with pace 2.0.
  const healths: Record<string, any> = {
    legacy: { check: { state: "ok" }, quota: okQuota(now, 10, 20, 2.8 * DAY) }, // pace = 0.8 * 7 / 2.8 = 2.0
    capped: { check: { state: "ok" }, quota: okQuota(now, 10, 20, 1.0 * DAY) }, // raw pace = 5.6 -> capped at 1.0
    openrouter: { check: { state: "ok" }, quota: { state: "unsupported", windows: [] } },
  };
  const chosenPace = pickProfile(
    [legacy!, capped!],
    "opus",
    { health: (id) => healths[id], load: () => 0, active: () => 0, lastPicked: () => 0, now: () => now },
    true,
  );
  assert.equal(chosenPace.id, "legacy", "capped account must not steal traffic with pace > 1.0");

  // Warm processes (load=4, active=0) do NOT count toward the cap.
  const chosenWarm = pickProfile(
    [capped!, openrouter!],
    "opus",
    { health: (id) => healths[id], load: (id) => (id === "capped" ? 4 : 0), active: () => 0, lastPicked: () => 0, now: () => now },
    true,
  );
  assert.equal(chosenWarm.id, "capped");

  // When capped account has active >= 2, legacy account is preferred even if legacy has higher load.
  const chosenOverflow = pickProfile(
    [capped!, legacy!],
    "opus",
    {
      health: (id) => healths[id],
      load: (id) => (id === "legacy" ? 10 : 2),
      active: (id) => (id === "legacy" ? 10 : 2),
      lastPicked: () => 0,
      now: () => now,
    },
    true,
  );
  assert.equal(chosenOverflow.id, "legacy");

  // When only capped subscription + billed-per-use remain, pickProfile still ranks capped subscription above billed-per-use.
  const chosenNoBilled = pickProfile(
    [capped!, openrouter!],
    "opus",
    { health: (id) => healths[id], load: () => 2, active: () => 2, lastPicked: () => 0, now: () => now },
    true,
  );
  assert.equal(chosenNoBilled.id, "capped");
});

test("warm idle processes on a capped account do NOT cause false queueing", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  try {
    r.edit((raw) => {
      raw.profiles[0].access = { kind: "subscription" };
      raw.profiles[0].maxConcurrentSessions = 2;
    });
    // Start 4 sessions and finish their turns so all 4 stay warm (idle, not running).
    for (let i = 1; i <= 4; i++) {
      const th = `${i * 1000}.1`;
      const m = message({ ts: `${i}.0`, threadTs: th, text: `hello ${i}` });
      await r.accept(m);
      await settle();
      const agent = r.claude.last();
      await r.call(agent.options.route, "chat_post", { to: `C1/${th}`, text: `ok ${i}`, kind: "all_done", done: `completed warm test ${i} and replied in thread` });
      agent.complete();
      await settle();
    }
    assert.equal(r.claude.sessions.length, 4);

    // 5th session arrives while 4 warm (0 running) processes exist: must start immediately!
    const m5 = message({ ts: "5.0", threadTs: "5000.1", text: "hello 5" });
    await r.accept(m5);
    await settle();
    assert.equal(r.claude.sessions.length, 5, "5th session must start when only warm idle processes exist");
    const lastPost = r.chat.posts.at(-1)?.[1] ?? "";
    assert.ok(!lastPost.includes("已进入排队"), `unexpected queued notice: ${lastPost}`);
  } finally {
    await r.close();
  }
});

test("overflow routes to legacy account when available; when only capped account remains, FIFO queues, drains one-by-one without duplicate notices, and never spills to billed-per-use", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  try {
    r.edit((raw) => {
      raw.profiles[0].name = "新订阅号A";
      raw.profiles[0].access = { kind: "subscription" };
      raw.profiles[0].maxConcurrentSessions = 2;
      raw.profiles[0].models = ["opus"];
      raw.profiles.push({
        id: "openrouter",
        name: "OpenRouter",
        runtime: "claude",
        access: { kind: "api-provider", provider: "openrouter", key: "sk-or-test" },
        home: "homes/or",
        models: ["opus"],
      });
    });

    // Start sessions 1 and 2 (filling cap 2/2).
    const s1m = message({ ts: "1.0", threadTs: "1000.1", text: "task 1" });
    await r.accept(s1m);
    await settle();
    const a1 = r.claude.sessions[0]!;
    const k1 = a1.options.route;

    const s2m = message({ ts: "2.0", threadTs: "2000.1", text: "task 2" });
    await r.accept(s2m);
    await settle();
    const a2 = r.claude.sessions[1]!;
    const k2 = a2.options.route;

    // Session 1 and 2 are running on cc; existing running sessions continue unaffected on next turn check (except = key).
    assert.equal(r.hub.accounts.runOn(k1).id, "cc");
    assert.equal(r.hub.accounts.runOn(k2).id, "cc");

    // Sessions 3 and 4 arrive while 2/2 running: both must queue (not start, not spill to OpenRouter).
    const s3m = message({ ts: "3.0", threadTs: "3000.1", text: "task 3" });
    await r.accept(s3m);
    await settle();
    const s4m = message({ ts: "4.0", threadTs: "4000.1", text: "task 4" });
    await r.accept(s4m);
    await settle();

    assert.equal(r.claude.sessions.length, 2, "sessions 3 and 4 must not start while 2/2 are running");
    const t3Posts = r.chat.posts.filter(([t]) => t.threadTs === "3000.1");
    const t4Posts = r.chat.posts.filter(([t]) => t.threadTs === "4000.1");
    assert.equal(t3Posts.length, 1);
    assert.equal(t4Posts.length, 1);
    assert.ok(t3Posts[0]![1].includes("新订阅号A") && t3Posts[0]![1].includes("2/2"), t3Posts[0]![1]);
    assert.ok(t4Posts[0]![1].includes("新订阅号A") && t4Posts[0]![1].includes("2/2"), t4Posts[0]![1]);

    // Pending messages are preserved and repeated kicks do not re-enter or duplicate notices.
    const k3 = r.store.listSessions().find((s) => s.key.endsWith("3000.1"))!.key;
    const k4 = r.store.listSessions().find((s) => s.key.endsWith("4000.1"))!.key;
    assert.equal(r.store.hasPending(k3), true);
    assert.equal(r.store.hasPending(k4), true);
    assert.equal(r.session(k3).profile, "cc", "must not switch to billed-per-use OpenRouter");
    await r.hub.actor(r.session(k3)).kick();
    await settle();
    assert.equal(r.chat.posts.filter(([t]) => t.threadTs === "3000.1").length, 1, "repeated kick must not duplicate notice");

    // Session 1 finishes -> ONLY session 3 dequeues and starts (FIFO); session 4 stays queued with NO duplicate notice!
    await r.call(k1, "chat_post", { to: "C1/1000.1", text: "done 1", kind: "all_done", done: "completed task 1 and posted result" });
    a1.complete();
    await settle();

    assert.equal(r.claude.sessions.length, 3, "only session 3 should dequeue when 1 slot frees");
    const a3 = r.claude.sessions[2]!;
    assert.equal(a3.options.route, k3, "FIFO: session 3 must dequeue before session 4");
    assert.ok(a3.prompts[0]!.includes("task 3"));
    assert.equal(r.store.hasPending(k4), true, "session 4 must remain queued");
    assert.equal(r.chat.posts.filter(([t]) => t.threadTs === "4000.1").length, 1, "session 4 must NOT receive a duplicate notice");

    // Session 2 finishes -> session 4 now dequeues and starts!
    await r.call(k2, "chat_post", { to: "C1/2000.1", text: "done 2", kind: "all_done", done: "completed task 2 and posted result" });
    a2.complete();
    await settle();

    assert.equal(r.claude.sessions.length, 4, "session 4 must dequeue when 2nd slot frees");
    const a4 = r.claude.sessions[3]!;
    assert.equal(a4.options.route, k4);
    assert.ok(a4.prompts[0]!.includes("task 4"));
  } finally {
    await r.close();
  }
});

test("manual jump-the-queue via retryFailed and via direct user reply bypasses queue and concurrency cap", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  try {
    r.edit((raw) => {
      raw.profiles[0].name = "新订阅号B";
      raw.profiles[0].access = { kind: "subscription" };
      raw.profiles[0].maxConcurrentSessions = 2;
    });

    // Fill 2/2 slots.
    await r.accept(message({ ts: "1.0", threadTs: "1000.1", text: "s1" }));
    await settle();
    await r.accept(message({ ts: "2.0", threadTs: "2000.1", text: "s2" }));
    await settle();

    // Queue sessions 3, 4, 5.
    await r.accept(message({ ts: "3.0", threadTs: "3000.1", text: "s3 original" }));
    await settle();
    await r.accept(message({ ts: "4.0", threadTs: "4000.1", text: "s4 original" }));
    await settle();
    await r.accept(message({ ts: "5.0", threadTs: "5000.1", text: "s5 original" }));
    await settle();
    assert.equal(r.claude.sessions.length, 2);

    const k3 = r.store.listSessions().find((s) => s.key.endsWith("3000.1"))!.key;
    const k4 = r.store.listSessions().find((s) => s.key.endsWith("4000.1"))!.key;
    const k5 = r.store.listSessions().find((s) => s.key.endsWith("5000.1"))!.key;

    // Path A: User taps Retry on session 4 (jumping ahead of session 3 even while 2/2 are running!).
    const last4 = r.store.lastTurn(k4);
    assert.equal(last4?.outcome, "failed");
    assert.equal(last4?.detail, "other: session_cap");
    assert.ok(last4?.about, "queued turn must have about bound to notice");
    await r.hub.retryFailed(k4, last4.about.thread, last4.about.seq);
    await settle();

    assert.equal(r.claude.sessions.length, 3, "session 4 must jump the queue and start immediately");
    const a4 = r.claude.sessions[2]!;
    assert.equal(a4.options.route, k4);
    assert.ok(a4.prompts[0]!.includes("s4 original"), "original pending message must be delivered");
    assert.equal(r.store.hasPending(k3), true, "session 3 must remain queued");

    // Path B: User replies directly to queued session 5 -> jumps the queue and delivers original + new reply!
    await r.accept(message({ ts: "5.1", threadTs: "5000.1", text: "s5 force start" }));
    await settle();

    assert.equal(r.claude.sessions.length, 4, "session 5 must jump the queue on direct reply");
    const a5 = r.claude.sessions[3]!;
    assert.equal(a5.options.route, k5);
    assert.ok(a5.prompts[0]!.includes("s5 original") && a5.prompts[0]!.includes("s5 force start"), a5.prompts[0]);
    assert.equal(r.store.hasPending(k3), true, "session 3 must still remain queued");
  } finally {
    await r.close();
  }
});

test("raising or clearing maxConcurrentSessions auto-drains queued sessions", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  try {
    r.edit((raw) => {
      raw.profiles[0].access = { kind: "subscription" };
      raw.profiles[0].maxConcurrentSessions = 1;
    });

    await r.accept(message({ ts: "1.0", threadTs: "1000.1", text: "s1" }));
    await settle();
    await r.accept(message({ ts: "2.0", threadTs: "2000.1", text: "s2" }));
    await settle();
    await r.accept(message({ ts: "3.0", threadTs: "3000.1", text: "s3" }));
    await settle();
    assert.equal(r.claude.sessions.length, 1);

    // Raise cap from 1 -> 2 and notify drainCapQueue -> only session 2 starts!
    r.edit((raw) => {
      raw.profiles[0].maxConcurrentSessions = 2;
    });
    r.hub.drainCapQueue();
    await settle();
    assert.equal(r.claude.sessions.length, 2, "raising cap 1->2 should drain 1 queued session");

    // Clear cap (unlimited) -> session 3 starts immediately!
    r.edit((raw) => {
      delete raw.profiles[0].maxConcurrentSessions;
    });
    r.hub.drainCapQueue();
    await settle();
    assert.equal(r.claude.sessions.length, 3, "clearing cap should drain remaining queued session");
  } finally {
    await r.close();
  }
});

test("billed-per-use upgrading back to a capped subscription respects !capped && !crowded", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  try {
    r.edit((raw) => {
      raw.profiles[0].id = "or";
      raw.profiles[0].name = "OpenRouter";
      raw.profiles[0].access = { kind: "api-provider", provider: "openrouter", key: "k" };
      raw.profiles[0].models = ["opus"];
      raw.profiles.push({
        id: "sub-new",
        name: "New Sub",
        runtime: "claude",
        access: { kind: "subscription" },
        home: "homes/sub-new",
        models: ["opus"],
        maxConcurrentSessions: 1,
      });
    });
    const now = time.clock.currentTimeMillisUnsafe();
    let subCrowded = false;
    r.hub.accounts.setHealth((id) => ({
      check: { state: "ok" },
      quota: id === "sub-new" ? okQuota(now, subCrowded ? 85 : 20, 20) : { state: "unsupported", windows: [] },
    }));

    // Start 1 session on sub-new (fills cap 1/1).
    await r.accept(message({ ts: "1.0", threadTs: "1000.1", text: "on sub" }));
    await settle();
    const k1 = r.claude.sessions[0]!.options.route;
    assert.equal(r.session(k1).profile, "sub-new");

    // Create a 2nd session currently on OpenRouter.
    const k2 = "s-on-or";
    r.store.insertSession({ key: k2, connect: "chat", runtime: "claude", profile: "or", workspace: "/tmp", model: "opus", token: "tok-k2", createdAt: now, lastActiveAt: now });
    // sub-new is at cap 1/1 -> must NOT upgrade onto sub-new.
    assert.equal(r.hub.accounts.runOn(k2).id, "or");

    // Complete session 1 so active=0, but mark sub-new crowded (5h >= 80%) -> still must NOT upgrade onto capped sub-new.
    await r.call(k1, "chat_post", { to: "C1/1000.1", text: "done", kind: "all_done", done: "completed sub-new task and posted result" });
    r.claude.sessions[0]!.complete();
    await settle();
    subCrowded = true;
    assert.equal(r.hub.accounts.runOn(k2).id, "or");

    // Once sub-new is both uncapped AND uncrowded -> upgrades cleanly!
    subCrowded = false;
    assert.equal(r.hub.accounts.runOn(k2).id, "sub-new");
  } finally {
    await r.close();
  }
});

test("spend failover queues when only capped subscription remains and supports manual retryFailed start", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  try {
    r.edit((raw) => {
      raw.profiles[0].id = "sub1";
      raw.profiles[0].name = "Sub 1";
      raw.profiles[0].access = { kind: "subscription" };
      raw.profiles[0].models = ["opus"];
      raw.profiles.push({
        id: "sub2",
        name: "Sub 2",
        runtime: "claude",
        access: { kind: "subscription" },
        home: "homes/sub2",
        models: ["opus"],
        maxConcurrentSessions: 1,
      });
    });

    // Session A runs on sub1; Session B runs on sub2 (filling sub2's cap 1/1).
    await r.accept(message({ ts: "1.0", threadTs: "6000.1", text: "A" }));
    await settle();
    const aA = r.claude.sessions[0]!;
    const kA = aA.options.route;

    await r.accept(message({ ts: "2.0", threadTs: "7000.1", text: "B" }));
    await settle();
    const aB = r.claude.sessions[1]!;
    const kB = aB.options.route;
    assert.notEqual(r.session(kA).profile, r.session(kB).profile);
    const [onSub1Agent, onSub1Key] = r.session(kA).profile === "sub1" ? [aA, kA] : [aB, kB];
    const onSub1Thread = r.session(kA).profile === "sub1" ? "6000.1" : "7000.1";

    // Session on sub1 hits rate_limit -> spend sees only capped sub2 -> queues with notice!
    onSub1Agent.end({ kind: "failed", reason: "rate_limit", message: "rate limit reached: try again later" });
    await settle();

    const notices = r.chat.posts.filter(([t]) => t.threadTs === onSub1Thread);
    assert.equal(notices.length, 1);
    assert.ok(notices[0]![1].includes("Sub 2") && notices[0]![1].includes("1/1"), notices[0]![1]);
    const last = r.store.lastTurn(onSub1Key);
    assert.equal(last?.detail, "other: session_cap");
    assert.ok(last?.about);

    // User taps Retry -> jumps queue, bypasses cap, and starts on sub2!
    const beforeCount = r.claude.sessions.length;
    await r.hub.retryFailed(onSub1Key, last.about.thread, last.about.seq);
    await settle();
    assert.equal(r.claude.sessions.length, beforeCount + 1);
    assert.equal(r.session(onSub1Key).profile, "sub2");
  } finally {
    await r.close();
  }
});

test("accounts: madeOfLogin defaults maxConcurrentSessions=8, putProfile sets/clears/validates/allows machine, checkConfig & portable() preserve it", async () => {
  const dir = mkdtempSync(join(tmpdir(), "cap-acct-"));
  const time = testClock();
  writeFileSync(join(dir, "config.json"), JSON.stringify({ profiles: [], connects: [] }));
  const store = Store.open(":memory:", null, time.clock);
  const config = new ConfigFile(dir);
  config.check = checkConfig;
  const accounts = new AccountManager({
    data: dir,
    store,
    config,
    clock: time.clock,
    machine: null,
    checkOnStart: false,
    check: async () => ({ state: "ok", detail: "ok", models: ["opus"], checkedAt: time.clock.currentTimeMillisUnsafe() }),
    quota: null,
  });
  const viewer = { id: "u1", email: "owner@example.com", name: "Owner", role: "owner", home: true, workspace: "w1" } as any;
  try {
    assert.equal(DEFAULT_NEW_SUBSCRIPTION_MAX_CONCURRENT_SESSIONS, 8);

    // madeOfLogin writes maxConcurrentSessions: 8 automatically.
    const loginHome = join(dir, "homes", "login-1");
    mkdirSync(loginHome, { recursive: true });
    writeFileSync(join(loginHome, ".credentials.json"), "{}");
    await (accounts as any).madeOfLogin(
      "login-1",
      { runtime: "claude", home: loginHome, by: viewer, created: null, error: null },
      "sub-auto",
      join(dir, "homes", "sub-auto"),
      null,
      false,
      "new@example.com",
      "zh",
      () => false,
    );
    const rawAuto = config.raw().profiles.find((p: any) => p.id === "sub-auto");
    assert.equal(rawAuto?.maxConcurrentSessions, 8);
    assert.equal(rawAuto?.newAccountProtection, true);
    const viewAuto = accounts.profilesView(viewer).find((p: any) => p.id === "sub-auto") as any;
    assert.equal(viewAuto?.maxConcurrentSessions, 8);
    assert.equal(viewAuto?.newAccountProtection, true);

    // putProfile edits other fields -> preserves maxConcurrentSessions: 8 and newAccountProtection: true.
    await accounts.putProfile("sub-auto", { name: "Renamed" }, viewer);
    assert.equal(config.raw().profiles.find((p: any) => p.id === "sub-auto")?.maxConcurrentSessions, 8);
    assert.equal(config.raw().profiles.find((p: any) => p.id === "sub-auto")?.newAccountProtection, true);

    // putProfile sets custom cap -> updates to 3 and exits new-account protection.
    await accounts.putProfile("sub-auto", { maxConcurrentSessions: 3 }, viewer);
    assert.equal(config.raw().profiles.find((p: any) => p.id === "sub-auto")?.maxConcurrentSessions, 3);
    assert.equal(config.raw().profiles.find((p: any) => p.id === "sub-auto")?.newAccountProtection, undefined);
    assert.equal((accounts.profilesView(viewer).find((p: any) => p.id === "sub-auto") as any)?.newAccountProtection, undefined);

    // putProfile rejects invalid values (negative, float, string).
    await assert.rejects(() => accounts.putProfile("sub-auto", { maxConcurrentSessions: -1 }, viewer), /positive integer or null/);
    await assert.rejects(() => accounts.putProfile("sub-auto", { maxConcurrentSessions: 2.5 }, viewer), /positive integer or null/);
    await assert.rejects(() => accounts.putProfile("sub-auto", { maxConcurrentSessions: "4" }, viewer), /positive integer or null/);

    // putProfile clears cap with null or 0 (and one-click disable clears both).
    await accounts.putProfile("sub-auto", { maxConcurrentSessions: 0 }, viewer);
    assert.equal(config.raw().profiles.find((p: any) => p.id === "sub-auto")?.maxConcurrentSessions, undefined);
    assert.equal(accounts.profilesView(viewer).find((p: any) => p.id === "sub-auto")?.maxConcurrentSessions, undefined);
    await accounts.putProfile("sub-auto", { maxConcurrentSessions: 5 }, viewer);
    await accounts.putProfile("sub-auto", { maxConcurrentSessions: null, newAccountProtection: false }, viewer);
    assert.equal(config.raw().profiles.find((p: any) => p.id === "sub-auto")?.maxConcurrentSessions, undefined);
    assert.equal(config.raw().profiles.find((p: any) => p.id === "sub-auto")?.newAccountProtection, undefined);

    // machine profile also allows editing maxConcurrentSessions.
    await config.updateSoon((raw) => {
      raw.profiles.push({ id: "machine-claude", name: "Machine", runtime: "claude", access: { kind: "subscription" }, home: "homes/machine-claude", env: {}, machine: true });
    });
    await accounts.putProfile("machine-claude", { maxConcurrentSessions: 6 }, viewer);
    assert.equal(config.raw().profiles.find((p: any) => p.id === "machine-claude")?.maxConcurrentSessions, 6);

    // checkConfig validates non-negative integer and boolean newAccountProtection.
    assert.doesNotThrow(() => checkConfig({ profiles: [{ id: "p1", runtime: "claude", access: { kind: "subscription" }, home: "h/p1", maxConcurrentSessions: 0, newAccountProtection: false }] }, dir));
    assert.throws(() => checkConfig({ profiles: [{ id: "p1", runtime: "claude", access: { kind: "subscription" }, home: "h/p1", maxConcurrentSessions: -1 }] }, dir), /non-negative integer/);
    assert.throws(() => checkConfig({ profiles: [{ id: "p1", runtime: "claude", access: { kind: "subscription" }, home: "h/p1", maxConcurrentSessions: 1.5 }] }, dir), /non-negative integer/);
    assert.throws(() => checkConfig({ profiles: [{ id: "p1", runtime: "claude", access: { kind: "subscription" }, home: "h/p1", newAccountProtection: "yes" }] }, dir), /boolean/);

    // portable() preserves maxConcurrentSessions and newAccountProtection.
    const port = portable({ id: "p1", home: "h/p1", name: "N", maxConcurrentSessions: 4, newAccountProtection: true });
    assert.equal(port.maxConcurrentSessions, 4);
    assert.equal(port.newAccountProtection, true);

    // Direct runOn throws AccountCapError with structured fields including protection.
    assert.throws(() => {
      throw new AccountCapError("Sub", "sub1", 2, 2, true);
    }, (e: any) => e instanceof AccountCapError && e.sessionCap === true && e.active === 2 && e.cap === 2 && e.protection === true);
  } finally {
    await accounts.close();
    store.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("cross-station concurrency cap via Hub SlotCoordinator: enforces global cap across host and borrower, queues and drains on remote release, falls back on host rejection, and supports forceCap", async () => {
  const time = testClock();
  const hostRig = new Rig({ clock: time.clock });
  const borrowerRig = new Rig({ clock: time.clock });
  try {
    hostRig.edit((raw) => {
      raw.profiles[0].id = "sub-host";
      raw.profiles[0].name = "共享订阅A";
      raw.profiles[0].access = { kind: "subscription" };
      raw.profiles[0].maxConcurrentSessions = 2;
      raw.profiles[0].newAccountProtection = true;
      raw.profiles[0].models = ["opus"];
    });
    borrowerRig.edit((raw) => {
      raw.profiles[0].id = "sub-borrowed";
      raw.profiles[0].name = "共享订阅A";
      raw.profiles[0].access = { kind: "subscription" };
      raw.profiles[0].maxConcurrentSessions = 2;
      raw.profiles[0].newAccountProtection = true;
      raw.profiles[0].models = ["opus"];
      raw.profiles[0].share = { id: "sh-sub", borrowed: true, host: "host-a" };
    });

    // In-memory coordinator mirroring Host <-> Borrower slot ledger.
    const remoteSlots = new Set<string>();
    const syncDrain = (prevBorrowerOther: number) => {
      const nextBorrowerOther = hostRig.hub.localActiveForAccount(hostRig.hub.accounts.accountKeyOf("sub-host"));
      if (nextBorrowerOther < prevBorrowerOther) borrowerRig.hub.drainCapQueue();
    };
    let lastHostLocal = 0;
    const hostCoord: SlotCoordinator = {
      remoteActive: (id) => (id === "sub-host" ? remoteSlots.size : 0),
      needsRemoteSlot: () => false,
      claimBorrowedSlot: async () => ({ ok: true }),
      adoptBorrowedSlot: () => {},
      hasBorrowedSlot: () => false,
      releaseBorrowedSlot: () => {},
      localActiveChanged: () => {
        const prev = lastHostLocal;
        lastHostLocal = hostRig.hub.localActiveForAccount(hostRig.hub.accounts.accountKeyOf("sub-host"));
        syncDrain(prev);
      },
    };
    const borrowerCoord: SlotCoordinator = {
      remoteActive: (id) => (id === "sub-borrowed" ? lastHostLocal : 0),
      needsRemoteSlot: (p) => p.id === "sub-borrowed",
      claimBorrowedSlot: async (_p, session, force) => {
        const localOnHost = hostRig.hub.localActiveForAccount(hostRig.hub.accounts.accountKeyOf("sub-host"));
        lastHostLocal = localOnHost;
        if (remoteSlots.has(session)) return { ok: true };
        const total = localOnHost + remoteSlots.size;
        if (!force && total >= 2) {
          return { ok: false, capped: true, active: total, cap: 2, protection: true };
        }
        remoteSlots.add(session);
        return { ok: true };
      },
      adoptBorrowedSlot: (_p, session) => { remoteSlots.add(session); },
      hasBorrowedSlot: (session) => remoteSlots.has(session),
      releaseBorrowedSlot: (session) => {
        if (remoteSlots.delete(session)) hostRig.hub.drainCapQueue();
      },
      localActiveChanged: () => {},
    };
    hostRig.hub.setSlotCoordinator(hostCoord);
    borrowerRig.hub.setSlotCoordinator(borrowerCoord);

    // 1. Host starts 1 session, Borrower starts 1 session -> global 2/2 reached!
    await hostRig.accept(message({ ts: "1.0", threadTs: "1000.1", text: "host 1" }));
    await settle();
    assert.equal(hostRig.claude.sessions.length, 1);

    await borrowerRig.accept(message({ ts: "2.0", threadTs: "2000.1", text: "borrower 1" }));
    await settle();
    assert.equal(borrowerRig.claude.sessions.length, 1);
    assert.equal(remoteSlots.size, 1);

    // 2. Both Borrower's 2nd session AND Host's 2nd session must queue at 2/2!
    await borrowerRig.accept(message({ ts: "3.0", threadTs: "3000.1", text: "borrower 2" }));
    await settle();
    assert.equal(borrowerRig.claude.sessions.length, 1, "borrower 2nd session must queue at global 2/2");
    const bNotice = borrowerRig.chat.posts.filter(([t]) => t.threadTs === "3000.1")[0]?.[1] ?? "";
    assert.ok(bNotice.includes("共享订阅A") && bNotice.includes("2/2"), bNotice);

    await hostRig.accept(message({ ts: "4.0", threadTs: "4000.1", text: "host 2" }));
    await settle();
    assert.equal(hostRig.claude.sessions.length, 1, "host 2nd session must also queue when borrower holds 1 slot");

    // 3. Host's 1st session finishes -> wakes borrower's queued session (and/or host's queued session);
    // once borrower's 1st session finishes too, both queued sessions have run without exceeding cap 2!
    const h1 = hostRig.claude.sessions[0]!;
    await hostRig.call(h1.options.route, "chat_post", { to: "C1/1000.1", text: "done h1", kind: "all_done", done: "finished host 1" });
    h1.complete();
    await settle();
    assert.equal(hostRig.claude.sessions.length + borrowerRig.claude.sessions.length, 3, "exactly one queued session wakes when one global slot opens");

    const b1 = borrowerRig.claude.sessions[0]!;
    await borrowerRig.call(b1.options.route, "chat_post", { to: "C1/2000.1", text: "done b1", kind: "all_done", done: "finished borrower 1" });
    b1.complete();
    await settle();
    assert.equal(hostRig.claude.sessions.length, 2, "host queued session ran once slot freed");
    assert.equal(borrowerRig.claude.sessions.length, 2, "borrower queued session ran once slot freed");

    // 4. Manual jump-the-queue on borrower bypasses global cap with force=true and still registers slot.
    await borrowerRig.accept(message({ ts: "5.0", threadTs: "5000.1", text: "borrower 3" }));
    await settle();
    assert.equal(borrowerRig.claude.sessions.length, 2, "borrower 3 queued at global 2/2");
    await borrowerRig.accept(message({ ts: "5.1", threadTs: "5000.1", text: "force now" }));
    await settle();
    assert.equal(borrowerRig.claude.sessions.length, 3, "manual reply jump-the-queue starts immediately with force=true");
  } finally {
    await hostRig.close();
    await borrowerRig.close();
  }
});

test("cross-station TOCTOU fallback: when host rejects borrowed profile claim as capped, borrower falls back to another uncapped profile without queueing", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  try {
    r.edit((raw) => {
      raw.profiles[0].id = "borrowed-full";
      raw.profiles[0].name = "满载共享号";
      raw.profiles[0].access = { kind: "subscription" };
      raw.profiles[0].maxConcurrentSessions = 2;
      raw.profiles[0].models = ["opus"];
      raw.profiles[0].share = { id: "sh-full", borrowed: true, host: "host-x" };
      raw.profiles.push({
        id: "local-free",
        name: "本地空闲号",
        runtime: "claude",
        access: { kind: "subscription" },
        home: "homes/local-free",
        models: ["opus"],
      });
    });

    // Simulate stale remoteActive=0 so synchronous runOn initially picks borrowed-full,
    // then host rejects claimBorrowedSlot with capped=true (2/2).
    let otherActive = 0;
    let claims = 0;
    r.hub.setSlotCoordinator({
      remoteActive: (id) => (id === "borrowed-full" ? otherActive : 0),
      needsRemoteSlot: (p) => p.id === "borrowed-full",
      claimBorrowedSlot: async () => {
        claims++;
        otherActive = 2;
        return { ok: false, capped: true, active: 2, cap: 2, protection: false };
      },
      adoptBorrowedSlot: () => {},
      hasBorrowedSlot: () => false,
      releaseBorrowedSlot: () => {},
      localActiveChanged: () => {},
    });

    // Pin initial session preference to borrowed-full (non-pinned) by starting with it in pool:
    // give borrowed-full higher urgency so pickProfile chooses it first.
    const now = time.clock.currentTimeMillisUnsafe();
    r.hub.accounts.setHealth((id) => ({
      check: { state: "ok" },
      quota: id === "borrowed-full" ? okQuota(now, 5, 5, 5 * DAY) : okQuota(now, 70, 70, 5 * DAY),
    }));

    await r.accept(message({ ts: "1.0", threadTs: "8000.1", text: "fallback test" }));
    await settle();
    assert.equal(claims, 1, "host was probed once for borrowed-full");
    assert.equal(r.claude.sessions.length, 1, "session started immediately on local-free after host rejected borrowed-full");
    const k = r.claude.sessions[0]!.options.route;
    assert.equal(r.session(k).profile, "local-free");
    const posts = r.chat.posts.filter(([t]) => t.threadTs === "8000.1");
    assert.equal(posts.some(([, text]) => text.includes("已进入排队")), false, "no cap pause notice posted when uncapped fallback succeeded");
    assert.equal(posts.some(([, text]) => text.includes("已切换账号")), true, "normal account switch notice posted after fallback");
  } finally {
    await r.close();
  }
});

test("cross-station concurrency: the hub tells the coordinator only when what a session counts against changes, and counts without store reads", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  try {
    r.edit((raw) => {
      raw.profiles[0].id = "sub-one";
      raw.profiles[0].access = { kind: "subscription" };
      raw.profiles[0].maxConcurrentSessions = 5;
      raw.profiles[0].models = ["opus"];
      raw.profiles.push({ id: "sub-two", name: "Two", runtime: "claude", access: { kind: "subscription" }, home: "homes/sub-two", models: ["opus"], maxConcurrentSessions: 5 });
    });
    const one = r.hub.accounts.accountKeyOf("sub-one");
    const two = r.hub.accounts.accountKeyOf("sub-two");
    const told: string[][] = [];
    r.hub.setSlotCoordinator({
      remoteActive: () => 0,
      needsRemoteSlot: () => false,
      claimBorrowedSlot: async () => ({ ok: true }),
      adoptBorrowedSlot: () => {},
      hasBorrowedSlot: () => false,
      releaseBorrowedSlot: () => {},
      localActiveChanged: (keys) => { told.push(keys === undefined ? ["*"] : [...keys].sort()); },
    });
    const store = r.hub.store as unknown as { getSession: (key: string) => unknown };
    const getSession = store.getSession.bind(store);
    let reads = 0;
    store.getSession = (key) => (reads++, getSession(key));

    // Two at work and one whose turn ended. Resolve each session by its thread rather than
    // r.claude.sessions insertion order, since each session's actor opens its runtime on its own, in any order.
    for (const n of [1, 2, 3]) await r.accept(message({ ts: `${n}.0`, threadTs: `${n}00.1`, text: `start ${n}` }));
    await settle();
    assert.equal(r.claude.sessions.length, 3);
    const sessionFor = (threadTs: string) => {
      const s = r.claude.sessions.find((x) => (x.options.route as string).endsWith(`:${threadTs}`));
      assert.ok(s, `expected session for thread ${threadTs}, got ${r.claude.sessions.map((x) => x.options.route).join(", ")}`);
      return s;
    };
    const a1 = sessionFor("100.1");
    const a2 = sessionFor("200.1");
    const a3 = sessionFor("300.1");
    const [s1, s2, s3] = [a1, a2, a3].map((s) => s.options.route as string);
    for (const k of [s1, s2, s3]) r.hub.store.setSessionProfile(k!, "sub-one", true);
    await settle();
    await r.call(s3!, "chat_post", { to: "C1/300.1", text: "done", kind: "all_done", done: "finished 3" });
    told.length = 0;
    a3.complete();
    await settle();
    assert.ok(told.some((k) => k.includes(one)), "the turn that ended told its account");
    const active = r.hub.localActiveForAccount(one);
    assert.equal(active, 2, `two at work counted, saw ${active}`);

    // Writes to idle sessions' rows (usage repriced, a title, a heartbeat) tell nothing and read nothing for slots.
    told.length = 0;
    for (let i = 0; i < 100; i++) r.hub.store.setSessionUsage(s3!, { costUsd: i });
    await settle();
    assert.deepEqual(told as string[][], [], "an idle session's writes move no count");

    // Counting reads no session row.
    reads = 0;
    for (let i = 0; i < 50; i++) assert.equal(r.hub.localActiveForAccount(one), active);
    assert.equal(reads, 0, "running sessions' profiles are kept, not read");

    // A running session moved to another account tells both.
    told.length = 0;
    r.hub.store.setSessionProfile(s2!, "sub-two", true);
    assert.deepEqual(told as string[][], [[one, two].sort()]);
    assert.equal(r.hub.localActiveForAccount(two), 1);
    assert.equal(r.hub.localActiveForAccount(one), active - 1);

    // Its turn ending tells its account.
    told.length = 0;
    await r.call(s1!, "chat_post", { to: "C1/100.1", text: "done", kind: "all_done", done: "finished 1" });
    a1.complete();
    await settle();
    assert.ok(told.length > 0 && told.every((k) => k.length === 1), `told per account: ${JSON.stringify(told)}`);
  } finally {
    await r.close();
  }
});
