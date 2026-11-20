// FB-39: auth_retry short-circuiting on dead profiles, skipping passive turns, and concurrency gating on auth_retry & spend failover.
import assert from "node:assert/strict";
import { test } from "node:test";
import { sessionKey } from "../src/sessions/hub.ts";
import { configure } from "../src/sessions/lifecycle.ts";
import { Rig, message, settle, testClock } from "./hub-fakes.ts";

test("auth_retry short-circuits when recheck confirms profile is login/failed and no healthy fallback exists", async () => {
  const r = new Rig();
  let state: "ok" | "login" | "failed" = "ok";
  let rechecks = 0;
  r.hub.accounts.setHealth((id) => (id === "cc" ? { check: { state, detail: "", models: null, checkedAt: 0 } } : {}));
  r.hub.accounts.setRecheck(async (id) => {
    if (id === "cc") {
      rechecks++;
      state = "login";
    }
  });
  const m = message();
  await r.accept(m);
  await settle();
  assert.equal(r.claude.count(), 1);
  r.claude.last().end({ kind: "failed", reason: "auth", message: "OAuth token revoked" });
  await settle();
  assert.equal(rechecks, 1, "recheck ran once");
  assert.equal(r.claude.count(), 1, "no second process opened when profile is confirmed dead with no fallback");
  assert.ok(r.chat.texts().some((t) => t.includes("OAuth token revoked") || t.includes("⚠️")), "failure notice posted");
  await r.close();
});

test("auth_retry short-circuits when session is pinned to a dead profile even if another healthy profile exists", async () => {
  const r = new Rig();
  r.edit((raw) => {
    raw.profiles[0].models = ["opus"];
    raw.profiles.push({ id: "cc2", runtime: "claude", home: "homes/cc2", models: ["opus"] });
  });
  const states: Record<string, "ok" | "login"> = { cc: "ok", cc2: "ok" };
  r.hub.accounts.setHealth((id) => ({ check: { state: states[id] ?? "ok", detail: "", models: null, checkedAt: 0 } }));
  r.hub.accounts.setRecheck(async (id) => {
    if (id === "cc") states.cc = "login";
  });
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  await configure(r.hub, key, { profile: "cc" });
  await settle();
  assert.equal(r.claude.count(), 1);
  r.claude.last().end({ kind: "failed", reason: "auth", message: "token expired" });
  await settle();
  assert.equal(r.claude.count(), 1, "pinned session does not spawn a second process on a confirmed dead profile");
  await r.close();
});

test("auth_retry still switches to a healthy fallback when unpinned and recheck marks failed profile as login", async () => {
  const r = new Rig();
  r.edit((raw) => {
    raw.profiles.push({ id: "cc2", runtime: "claude", home: "homes/cc2" });
  });
  const states: Record<string, "ok" | "login"> = { cc: "ok", cc2: "ok" };
  r.hub.accounts.setHealth((id) => ({ check: { state: states[id] ?? "ok", detail: "", models: null, checkedAt: 0 } }));
  r.hub.accounts.setRecheck(async (id) => {
    if (id === "cc") states.cc = "login";
  });
  const m = message();
  await r.accept(m);
  await settle();
  assert.equal(r.claude.count(), 1);
  r.claude.last().end({ kind: "failed", reason: "auth", message: "token expired" });
  await settle();
  assert.equal(r.claude.count(), 2, "unpinned session reopens on healthy fallback");
  const key = sessionKey("cl", "C1", m.threadTs);
  assert.equal(r.store.getSession(key)?.profile, "cc2");
  await r.close();
});

test("passive turns (nudge, title, refill) do not trigger automatic auth_retry", async () => {
  const r = new Rig({ maxNudges: 2 });
  // Even when profile health is ok (would normally allow auth_retry), a passive nudge turn must not auto-retry.
  r.hub.accounts.setHealth(() => ({ check: { state: "ok", detail: "", models: null, checkedAt: 0 } }));
  const m = message();
  await r.accept(m);
  await settle();
  // End first turn without declaring a state -> triggers passive "nudge" turn.
  r.claude.last().end({ kind: "completed" });
  await settle();
  assert.equal(r.claude.last().prompts.length, 2, "nudge turn started");
  const countBefore = r.claude.count();
  r.claude.last().end({ kind: "failed", reason: "auth", message: "401 unauthorized" });
  await settle();
  assert.equal(r.claude.count(), countBefore, "passive nudge turn did not reopen for auth_retry");
  assert.ok(r.chat.texts().some((t) => t.includes("401 unauthorized") || t.includes("⚠️")), "failure notice posted");
  await r.close();
});

test("auth_retry and spend failover respect maxConcurrentTurns when slots are over capacity", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock, maxConcurrentTurns: 2 });
  r.edit((raw) => {
    raw.profiles.push({ id: "cc2", runtime: "claude", home: "homes/cc2" });
  });
  r.hub.accounts.setHealth(() => ({ check: { state: "ok", detail: "", models: null, checkedAt: 0 } }));
  // Start 2 concurrent turns (filling cap=2).
  const m1 = message({ ts: "1.1", threadTs: "1.1" });
  const m2 = message({ ts: "2.1", threadTs: "2.1" });
  await r.accept(m1);
  await r.accept(m2);
  await settle();
  assert.equal(r.claude.count(), 2);
  const s1 = r.claude.sessions[0]!;
  const s2 = r.claude.sessions[1]!;

  // Lower cap to 1 while 2 turns are active (active_turn_slots = 2 > max = 1).
  r.edit((raw) => void (raw.maxConcurrentTurns = 1));
  r.hub.setMaxConcurrentTurns(1);
  await settle();

  // Turn 1 hits rate_limit and moves to cc2: must queue instead of bypassing cap=1!
  s1.end({ kind: "failed", reason: "rate_limit", message: "You've hit your limit" });
  await settle();
  assert.equal(r.claude.count(), 2, "spend failover queued while active slots exceed maxConcurrentTurns=1");

  // Finish turn 2: slot frees up, queued spend failover wakes and starts!
  const k2 = sessionKey("cl", "C1", m2.threadTs);
  await r.call(k2, "chat_state", { kind: "all_done", done: "answered the question" });
  s2.complete();
  await settle();
  assert.equal(r.claude.count(), 3, "queued spend failover started once slot became available");

  // Now raise cap to 2, start turn 3 alongside turn 1's retry, then lower cap to 1 and trigger auth_retry.
  r.edit((raw) => void (raw.maxConcurrentTurns = 2));
  r.hub.setMaxConcurrentTurns(2);
  await settle();
  const m3 = message({ ts: "3.1", threadTs: "3.1" });
  await r.accept(m3);
  await settle();
  assert.equal(r.claude.count(), 4);
  const s1Retry = r.claude.sessions[2]!;
  const s3 = r.claude.sessions[3]!;

  r.edit((raw) => void (raw.maxConcurrentTurns = 1));
  r.hub.setMaxConcurrentTurns(1);
  await settle();

  s1Retry.end({ kind: "failed", reason: "auth", message: "token expired" });
  await settle();
  assert.equal(r.claude.count(), 4, "auth_retry queued while active slots exceed maxConcurrentTurns=1");

  const k3 = sessionKey("cl", "C1", m3.threadTs);
  await r.call(k3, "chat_state", { kind: "all_done", done: "answered the question" });
  s3.complete();
  await settle();
  assert.equal(r.claude.count(), 5, "queued auth_retry started once slot became available");
  await r.close();
});

test("queued_retry is cleared when a new user turn begins so it never re-fires on later release", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock, maxConcurrentTurns: 2 });
  r.hub.accounts.setHealth(() => ({ check: { state: "ok", detail: "", models: null, checkedAt: 0 } }));
  const m1 = message({ ts: "10.1", threadTs: "10.1" });
  const m2 = message({ ts: "20.1", threadTs: "20.1" });
  await r.accept(m1);
  await r.accept(m2);
  await settle();
  assert.equal(r.claude.count(), 2);
  const s1 = r.claude.sessions[0]!;
  const s2 = r.claude.sessions[1]!;

  // Lower cap to 1 while 2 turns run, then fail s1 with auth so auth_retry is queued.
  r.edit((raw) => void (raw.maxConcurrentTurns = 1));
  r.hub.setMaxConcurrentTurns(1);
  await settle();
  s1.end({ kind: "failed", reason: "auth", message: "token expired" });
  await settle();
  assert.equal(r.claude.count(), 2, "auth_retry queued while cap=1 is saturated");

  // Raise cap to 2 and send a new user message to session 1: supersedes queued_retry via begin_turn.
  r.hub.hold("drain");
  r.edit((raw) => void (raw.maxConcurrentTurns = 2));
  r.hub.setMaxConcurrentTurns(2);
  await r.accept({ ...m1, ts: "10.2", text: "<@UBOT> fresh user prompt" });
  await settle();
  r.hub.release("drain");
  await settle();
  assert.equal(r.claude.count(), 3, "new user message opened session 1");
  const s1New = r.claude.sessions[2]!;
  assert.ok(s1New.prompts[0]!.includes("fresh user prompt"), "new user prompt ran instead of stale auth_retry");

  // Complete s1New and trigger another hold/release cycle: stale queued_retry must not fire.
  const k1 = sessionKey("cl", "C1", m1.threadTs);
  await r.call(k1, "chat_state", { kind: "all_done", done: "answered the fresh prompt" });
  s1New.complete();
  await settle();
  r.hub.hold("drain");
  r.hub.release("drain");
  await settle();
  assert.equal(r.claude.count(), 3, "no stale queued_retry fired on subsequent release");
  assert.equal(s1New.prompts.length, 1, "no extra prompt sent to session 1");

  const k2 = sessionKey("cl", "C1", m2.threadTs);
  await r.call(k2, "chat_state", { kind: "all_done", done: "finished second session" });
  s2.complete();
  await settle();
  await r.close();
});
