// Native concurrency limit (`maxConcurrentTurns`) and staggered restart recovery in Actors (`--sessions`) and Hub:
// deterministic tests on TestClock with zero sleeps.
import assert from "node:assert/strict";
import { test } from "node:test";
import { sessionKey } from "../src/sessions/hub.ts";
import { FakeDriver, Rig, reply, say, settle, testClock } from "./hub-fakes.ts";

const opened = (driver: FakeDriver, key: string) => driver.sessions.find((s) => s.options.route === key);
const DONE = "completed task and verified result in test";

test("1. maxConcurrentTurns caps simultaneous turns and drains FIFO without dropping messages", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock, maxConcurrentTurns: 2 });
  const msgs = [1, 2, 3, 4, 5].map((i) => say(`<@UBOT> task ${i}`));
  const keys = msgs.map((m) => sessionKey("cl", "C1", m.threadTs));

  for (const m of msgs) await r.accept(m);
  await settle();

  assert.equal(r.hub.running(), 2);
  assert.equal(r.claude.count(), 2);
  assert.deepEqual(
    new Set(r.claude.sessions.map((s) => s.options.route)),
    new Set([keys[0], keys[1]]),
  );

  // Complete s1 -> s3 wakes in FIFO order
  await r.call(keys[0]!, "chat_state", { kind: "all_done", done: DONE });
  opened(r.claude, keys[0]!)!.complete();
  await settle();
  assert.equal(r.hub.running(), 2);
  assert.equal(r.claude.count(), 3);
  assert.equal(r.claude.sessions[2]!.options.route, keys[2]);
  assert.equal(opened(r.claude, keys[2]!)!.busy(), true);

  // Complete s2 -> s4 wakes
  await r.call(keys[1]!, "chat_state", { kind: "all_done", done: DONE });
  opened(r.claude, keys[1]!)!.complete();
  await settle();
  assert.equal(r.hub.running(), 2);
  assert.equal(r.claude.count(), 4);
  assert.equal(r.claude.sessions[3]!.options.route, keys[3]);

  // Complete s3 -> s5 wakes
  await r.call(keys[2]!, "chat_state", { kind: "all_done", done: DONE });
  opened(r.claude, keys[2]!)!.complete();
  await settle();
  assert.equal(r.hub.running(), 2);
  assert.equal(r.claude.count(), 5);
  assert.equal(r.claude.sessions[4]!.options.route, keys[4]);

  // Complete s4 & s5 -> all 5 finished with zero dropped messages
  for (const idx of [3, 4]) {
    await r.call(keys[idx]!, "chat_state", { kind: "all_done", done: DONE });
    opened(r.claude, keys[idx]!)!.complete();
  }
  await settle();
  assert.equal(r.hub.running(), 0);
  for (let i = 0; i < 5; i++) {
    const s = opened(r.claude, keys[i]!)!;
    assert.equal(s.prompts.length, 1);
    assert.ok(s.prompts[0]!.includes(`task ${i + 1}`), s.prompts[0]);
    assert.equal(r.store.hasPending(keys[i]!), false);
  }
  await r.close();
});

test("2. restart recover() staggers 6 interrupted sessions by lastActiveAt desc under maxConcurrentTurns", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  const msgs = [1, 2, 3, 4, 5, 6].map((i) => say(`<@UBOT> work ${i}`));
  const keys = msgs.map((m) => sessionKey("cl", "C1", m.threadTs));

  for (const m of msgs) {
    await time.adjust(10_000);
    await r.accept(m);
    await settle();
  }
  assert.equal(r.hub.running(), 6);
  // Simulate crash: shut down hub without handover; sessions stay running=1 in SQLite.
  await r.hub.shutdown();

  r.edit((raw) => {
    raw.maxConcurrentTurns = 2;
  });
  const claude2 = new FakeDriver("claude");
  const chats = new Map([["cl", r.chat]]);
  const hub2 = r.newHub({ chats: (id) => chats.get(id), drivers: [claude2, r.codex] });
  r.hub = hub2;

  hub2.recover();
  await settle();

  // Only the 2 most recently active sessions (s6, s5) start immediately
  assert.equal(hub2.running(), 2);
  assert.equal(claude2.count(), 2);
  assert.deepEqual(
    new Set(claude2.sessions.map((s) => s.options.route)),
    new Set([keys[5], keys[4]]),
  );

  // As slots free up, remaining sessions recover in lastActiveAt descending order: s4, s3, s2, s1
  const expectedOrder = [keys[5]!, keys[4]!, keys[3]!, keys[2]!, keys[1]!, keys[0]!];
  for (let i = 0; i < expectedOrder.length; i++) {
    const k = expectedOrder[i]!;
    await r.call(k, "chat_state", { kind: "all_done", done: DONE });
    opened(claude2, k)!.complete();
    await settle();
    const expectedOpened = Math.min(6, i + 3);
    assert.equal(claude2.count(), expectedOpened);
    if (i + 2 < expectedOrder.length) {
      assert.equal(claude2.sessions[i + 2]!.options.route, expectedOrder[i + 2]);
    }
  }
  assert.equal(hub2.running(), 0);
  assert.deepEqual(
    claude2.sessions.slice(2).map((s) => s.options.route),
    expectedOrder.slice(2),
  );
  await r.close();
});

test("3. steer into a running session succeeds when at full capacity", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock, maxConcurrentTurns: 2 });
  const m1 = say("<@UBOT> first");
  const m2 = say("<@UBOT> second");
  const m3 = say("<@UBOT> third");
  const [k1, k2, k3] = [m1, m2, m3].map((m) => sessionKey("cl", "C1", m.threadTs));

  await r.accept(m1);
  await r.accept(m2);
  await r.accept(m3);
  await settle();
  assert.equal(r.hub.running(), 2);
  assert.equal(opened(r.claude, k3!), undefined);

  // Steer into running s1 while at 2/2 capacity
  await r.accept(reply(m1, "9001.000100", "urgent steer"));
  await settle();
  const s1 = opened(r.claude, k1!)!;
  assert.equal(s1.steers.length, 1);
  assert.ok(s1.steers[0]!.includes("urgent steer"), s1.steers[0]);
  assert.equal(r.hub.running(), 2);
  assert.equal(opened(r.claude, k3!), undefined);

  // Completing s1 wakes queued s3
  await r.call(k1!, "chat_state", { kind: "all_done", done: DONE });
  s1.complete();
  await settle();
  assert.equal(r.hub.running(), 2);
  assert.equal(opened(r.claude, k3!)?.busy(), true);

  await r.call(k2!, "chat_state", { kind: "all_done", done: DONE });
  opened(r.claude, k2!)!.complete();
  await r.call(k3!, "chat_state", { kind: "all_done", done: DONE });
  opened(r.claude, k3!)!.complete();
  await settle();
  assert.equal(r.hub.running(), 0);
  await r.close();
});

test("4. re-prompt (nudge) continues slot at full capacity without deadlock", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock, maxConcurrentTurns: 2, maxNudges: 2 });
  const m1 = say("<@UBOT> first");
  const m2 = say("<@UBOT> second");
  const m3 = say("<@UBOT> third");
  const [k1, k2, k3] = [m1, m2, m3].map((m) => sessionKey("cl", "C1", m.threadTs));

  await r.accept(m1);
  await r.accept(m2);
  await r.accept(m3);
  await settle();
  assert.equal(r.hub.running(), 2);
  assert.equal(opened(r.claude, k3!), undefined);

  // s1 completes without declaring state -> triggers nudge on its existing slot
  const s1 = opened(r.claude, k1!)!;
  s1.complete();
  await settle();
  assert.equal(s1.prompts.length, 2, "nudge re-prompt should fire immediately without deadlocking");
  assert.equal(s1.busy(), true);
  assert.equal(r.hub.running(), 2);
  assert.equal(opened(r.claude, k3!), undefined, "queued s3 should not exceed concurrency limit");

  // Once s1 declares all_done and completes, s3 wakes
  await r.call(k1!, "chat_state", { kind: "all_done", done: DONE });
  s1.complete();
  await settle();
  assert.equal(r.hub.running(), 2);
  assert.equal(opened(r.claude, k3!)?.busy(), true);

  await r.call(k2!, "chat_state", { kind: "all_done", done: DONE });
  opened(r.claude, k2!)!.complete();
  await r.call(k3!, "chat_state", { kind: "all_done", done: DONE });
  opened(r.claude, k3!)!.complete();
  await settle();
  assert.equal(r.hub.running(), 0);
  await r.close();
});

test("5. slot returns and wakes queue head on start_turn failure, stop, and suspend", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock, maxConcurrentTurns: 2 });

  // (a) start_turn failure releases slot and wakes queued session
  const m1 = say("<@UBOT> s1");
  const m2 = say("<@UBOT> fail-s2");
  const m3 = say("<@UBOT> s3");
  const [k1, k2, k3] = [m1, m2, m3].map((m) => sessionKey("cl", "C1", m.threadTs));
  r.claude.beforePrompt = (text) => {
    if (text.includes("fail-s2")) throw new Error("boom");
  };
  await r.accept(m1);
  await r.accept(m2);
  await r.accept(m3);
  await settle();
  assert.equal(r.hub.running(), 2);
  assert.equal(opened(r.claude, k1!)?.busy(), true);
  assert.equal(opened(r.claude, k3!)?.busy(), true);

  // (b) stop() releases slot and wakes queued session
  const m4 = say("<@UBOT> s4");
  const k4 = sessionKey("cl", "C1", m4.threadTs);
  await r.accept(m4);
  await settle();
  assert.equal(opened(r.claude, k4), undefined);
  await r.hub.stop(k1!);
  opened(r.claude, k1!)!.end({ kind: "aborted" });
  await settle();
  assert.equal(r.hub.running(), 2);
  assert.equal(opened(r.claude, k4)?.busy(), true);

  // (c) suspend (via holdChat) releases slot and wakes queued session
  const m5 = say("<@UBOT> s5");
  const k5 = sessionKey("cl", "C1", m5.threadTs);
  await r.accept(m5);
  await settle();
  assert.equal(opened(r.claude, k5), undefined);
  await r.hub.holdChat(k3!, "moving");
  await settle();
  assert.equal(r.hub.running(), 2);
  assert.equal(opened(r.claude, k5)?.busy(), true);

  // Clean up remaining
  await r.call(k4, "chat_state", { kind: "all_done", done: DONE });
  opened(r.claude, k4)!.complete();
  await r.call(k5, "chat_state", { kind: "all_done", done: DONE });
  opened(r.claude, k5)!.complete();
  await settle();
  assert.equal(r.hub.running(), 0);
  await r.close();
});

test("6. hot-reloading maxConcurrentTurns (1 -> 3 and 1 -> 0) wakes queued sessions immediately", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock, maxConcurrentTurns: 1 });
  const msgs = [1, 2, 3, 4].map((i) => say(`<@UBOT> hot ${i}`));
  const keys = msgs.map((m) => sessionKey("cl", "C1", m.threadTs));

  for (const m of msgs) await r.accept(m);
  await settle();
  assert.equal(r.hub.running(), 1);
  assert.equal(r.claude.count(), 1);

  // 1 -> 3 wakes s2 and s3 immediately, s4 remains queued
  r.edit((raw) => {
    raw.maxConcurrentTurns = 3;
  });
  r.hub.setMaxConcurrentTurns(3);
  await settle();
  assert.equal(r.hub.running(), 3);
  assert.equal(r.claude.count(), 3);
  assert.deepEqual(
    new Set(r.claude.sessions.map((s) => s.options.route)),
    new Set([keys[0], keys[1], keys[2]]),
  );
  assert.equal(opened(r.claude, keys[3]!), undefined);

  // 3 -> 0 (unlimited) wakes s4 immediately
  r.edit((raw) => {
    raw.maxConcurrentTurns = 0;
  });
  r.hub.setMaxConcurrentTurns(0);
  await settle();
  assert.equal(r.hub.running(), 4);
  assert.equal(r.claude.count(), 4);
  assert.equal(opened(r.claude, keys[3]!)?.busy(), true);
  await r.close();

  // Direct 1 -> 0 hot-reload wakes all queued sessions at once
  const r2 = new Rig({ clock: time.clock, maxConcurrentTurns: 1 });
  const msgs2 = [1, 2, 3].map((i) => say(`<@UBOT> direct ${i}`));
  for (const m of msgs2) await r2.accept(m);
  await settle();
  assert.equal(r2.hub.running(), 1);
  r2.edit((raw) => {
    raw.maxConcurrentTurns = 0;
  });
  r2.hub.setMaxConcurrentTurns(0);
  await settle();
  assert.equal(r2.hub.running(), 3);
  await r2.close();
});

test("7. settled() and handOver() converge cleanly with queued sessions and preserve pending messages", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock, maxConcurrentTurns: 1 });
  const m1 = say("<@UBOT> active");
  const m2 = say("<@UBOT> queued 1");
  const m3 = say("<@UBOT> queued 2");
  const [k1, k2, k3] = [m1, m2, m3].map((m) => sessionKey("cl", "C1", m.threadTs));

  await r.accept(m1);
  await r.accept(m2);
  await r.accept(m3);
  await settle();
  assert.equal(r.hub.running(), 1);
  assert.equal(r.store.hasPending(k2!), true);
  assert.equal(r.store.hasPending(k3!), true);

  const handed = await r.hub.handOver(5_000);
  assert.ok(handed.sessions.some((s) => s.key === k1), "running session snapshotted");
  assert.equal(r.store.hasPending(k2!), true, "queued session 2 keeps pending message in SQLite");
  assert.equal(r.store.hasPending(k3!), true, "queued session 3 keeps pending message in SQLite");
  await r.close();
});

test("8. strict O(1) wake skips held queue head without waking later queued sessions", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock, maxConcurrentTurns: 1 });
  const formatCalls: string[] = [];
  r.hub.pendingDeliveries = async (key) => {
    formatCalls.push(key);
    return r.store.pendingMessages(key);
  };
  const msgs = [1, 2, 3, 4, 5].map((i) => say(`<@UBOT> o1-task ${i}`));
  const keys = msgs.map((m) => sessionKey("cl", "C1", m.threadTs));

  for (const m of msgs) await r.accept(m);
  await settle();
  assert.equal(r.hub.running(), 1);
  assert.equal(opened(r.claude, keys[0]!)?.busy(), true);

  // Hold queue head s2, then reset formatCalls to observe exactly which queued sessions get woken.
  await r.hub.holdChat(keys[1]!, "moving");
  await settle();
  formatCalls.length = 0;

  // Complete s1 -> skips held s2 and wakes ONLY s3; s4 and s5 must NOT be woken/formatted.
  await r.call(keys[0]!, "chat_state", { kind: "all_done", done: DONE });
  opened(r.claude, keys[0]!)!.complete();
  await settle();
  assert.equal(r.hub.running(), 1);
  assert.equal(opened(r.claude, keys[1]!), undefined, "held s2 must stay cold");
  assert.equal(opened(r.claude, keys[2]!)?.busy(), true, "s3 must immediately take the slot");
  assert.equal(opened(r.claude, keys[3]!), undefined, "s4 must stay queued");
  assert.equal(opened(r.claude, keys[4]!), undefined, "s5 must stay queued");
  assert.equal(formatCalls.includes(keys[3]!), false, `s4 must not be woken when s1 ends; formatCalls=${JSON.stringify(formatCalls)}`);
  assert.equal(formatCalls.includes(keys[4]!), false, `s5 must not be woken when s1 ends; formatCalls=${JSON.stringify(formatCalls)}`);

  // Complete s3 -> wakes ONLY s4; s5 still untouched.
  formatCalls.length = 0;
  await r.call(keys[2]!, "chat_state", { kind: "all_done", done: DONE });
  opened(r.claude, keys[2]!)!.complete();
  await settle();
  assert.equal(r.hub.running(), 1);
  assert.equal(opened(r.claude, keys[3]!)?.busy(), true);
  assert.equal(formatCalls.includes(keys[4]!), false, `s5 must not be woken when s3 ends; formatCalls=${JSON.stringify(formatCalls)}`);

  // Complete s4 -> wakes s5.
  await r.call(keys[3]!, "chat_state", { kind: "all_done", done: DONE });
  opened(r.claude, keys[3]!)!.complete();
  await settle();
  assert.equal(r.hub.running(), 1);
  assert.equal(opened(r.claude, keys[4]!)?.busy(), true);

  await r.call(keys[4]!, "chat_state", { kind: "all_done", done: DONE });
  opened(r.claude, keys[4]!)!.complete();
  await settle();
  assert.equal(r.hub.running(), 0);
  await r.close();
});

test("9. hub.hold and hub.release do not starve queued sessions and stay bounded by maxConcurrentTurns", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock, maxConcurrentTurns: 2 });
  const msgs = [1, 2, 3, 4, 5].map((i) => say(`<@UBOT> hold-task ${i}`));
  const keys = msgs.map((m) => sessionKey("cl", "C1", m.threadTs));

  for (const m of msgs) await r.accept(m);
  await settle();
  assert.equal(r.hub.running(), 2);

  // Hold turns (e.g. drain/handover) while 2 are running and 3 are queued.
  r.hub.hold("drain");
  await r.call(keys[0]!, "chat_state", { kind: "all_done", done: DONE });
  opened(r.claude, keys[0]!)!.complete();
  await r.call(keys[1]!, "chat_state", { kind: "all_done", done: DONE });
  opened(r.claude, keys[1]!)!.complete();
  await settle();
  assert.equal(r.hub.running(), 0, "no queued session may start while hub is held");
  assert.equal(r.claude.count(), 2);

  // Release hold: queued sessions wake without starving and stay capped at maxConcurrentTurns=2.
  r.hub.release("drain");
  await settle();
  assert.equal(r.hub.running(), 2);
  assert.equal(r.claude.count(), 4);

  // Completing one running session wakes the 5th session.
  const runningNow = r.claude.sessions.filter((s) => s.busy()).map((s) => s.options.route as string);
  assert.equal(runningNow.length, 2);
  await r.call(runningNow[0]!, "chat_state", { kind: "all_done", done: DONE });
  opened(r.claude, runningNow[0]!)!.complete();
  await settle();
  assert.equal(r.hub.running(), 2);
  assert.equal(r.claude.count(), 5);

  for (const s of r.claude.sessions.filter((x) => x.busy())) {
    await r.call(s.options.route as string, "chat_state", { kind: "all_done", done: DONE });
    s.complete();
  }
  await settle();
  assert.equal(r.hub.running(), 0);
  for (const k of keys) {
    assert.equal(r.store.hasPending(k), false);
  }
  await r.close();
});
