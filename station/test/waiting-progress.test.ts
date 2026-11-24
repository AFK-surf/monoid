import assert from "node:assert/strict";
import { test } from "node:test";
import { chatPost, chatState } from "../src/sessions/conversations.ts";
import { sessionKey } from "../src/sessions/hub.ts";
import { FakeDriver, Rig, message, reply, settle } from "./hub-fakes.ts";

const watchJob = (session: string) => ({
  id: "job_w", sessionKey: session, name: "watch ci", command: "sleep 600", cwd: "/", port: null, token: "tw", state: "running",
  pgid: null, exitCode: null, startedAt: Date.now(), endedAt: null, restarts: 0, log: "/dev/null", watch: true,
});

test("mid-turn waiting timer steers a turn that stays open after chat_state(waiting)", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: Date.now() });
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const session = r.claude.last();

  await r.call(key, "chat_state", { kind: "waiting", seconds: 60, for: "run build" });
  await settle();

  // Turn stays open (e.g. an ACP runtime with a hung background command). Not steered early.
  t.mock.timers.tick(59_000);
  await settle();
  assert.equal(session.steers.length, 0, "does not fire before declared wait");

  t.mock.timers.tick(2_000);
  await settle();
  assert.equal(session.steers.length, 1, "steers waitOver into the open turn once wait runs out");
  assert.ok(session.steers[0]!.includes("waiting on work you started (60 seconds)"), session.steers[0]);
  assert.equal(r.store.lastTurn(key)!.declared, null, "clears waiting after steering so the agent re-declares");

  // Re-declaring waiting while still in the same turn arms a fresh timer.
  await r.call(key, "chat_state", { kind: "waiting", seconds: 30, for: "retry build" });
  t.mock.timers.tick(31_000);
  await settle();
  assert.equal(session.steers.length, 2, "fires again for a second mid-turn waiting declaration");
  assert.ok(session.steers[1]!.includes("waiting on work you started (30 seconds)"), session.steers[1]);

  // Declaring all_done and ending cancels any pending mid-turn wait.
  await r.call(key, "chat_state", { kind: "all_done", done: "build passed" });
  session.complete();
  t.mock.timers.tick(120_000);
  await settle();
  assert.equal(session.steers.length, 2, "no further steer after turn ends");
  await r.close();
});

test("active tool calls inside the same turn slide the mid-turn waiting timer", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: Date.now() });
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const session = r.claude.last();

  await r.call(key, "chat_state", { kind: "waiting", seconds: 60, for: "build" });
  t.mock.timers.tick(40_000);
  await settle();
  // Simulate the background task completing and the model resuming active tool use inside the same turn.
  session.events({ type: "live", event: { kind: "start", id: "tool-2", step: "tool", tool: "Bash" } });
  await settle();

  t.mock.timers.tick(25_000);
  await settle();
  assert.equal(session.steers.length, 0, "does not interrupt active tool work");

  // If the resumed work later stalls for the full wait duration, the fallback still wakes it.
  t.mock.timers.tick(40_000);
  await settle();
  assert.equal(session.steers.length, 1, "still wakes once quiet for the declared duration");
  await r.close();
});

test("mid-turn waiting timer respects watch jobs, read user messages, and normal turn end", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: Date.now() });

  // 1. Active watch: true keeps mid-turn wait quiet until watch stops.
  {
    const r = new Rig();
    const m = message();
    await r.accept(m);
    await settle();
    const key = sessionKey("cl", "C1", m.threadTs);
    const session = r.claude.last();
    r.store.insertJob(watchJob(key));
    await r.call(key, "chat_state", { kind: "waiting", seconds: 30, for: "watch ci", watch: true });
    t.mock.timers.tick(90_000);
    await settle();
    assert.equal(session.steers.length, 0, "watch: true does not steer while watch job runs");
    r.store.jobEnded("job_w", "stopped", null);
    t.mock.timers.tick(35_000);
    await settle();
    assert.equal(session.steers.length, 1, "steers after watch job ends");
    await r.close();
  }

  // 2. A read user message clears waiting and cancels the mid-turn timer.
  {
    const r = new Rig();
    const m = message();
    await r.accept(m);
    await settle();
    const key = sessionKey("cl", "C1", m.threadTs);
    const session = r.claude.last();
    await r.call(key, "chat_state", { kind: "waiting", seconds: 60, for: "build" });
    await r.accept(reply(m, "9999.1", "status?"));
    await settle();
    session.reads();
    await settle();
    t.mock.timers.tick(120_000);
    await settle();
    assert.equal(session.steers.length, 1, "only the user message was steered, not waitOver");
    await r.close();
  }

  // 3. Normal turn completion cancels mid-turn timer and relies on post-turn wait_ms alone.
  {
    const r = new Rig();
    const m = message();
    await r.accept(m);
    await settle();
    const key = sessionKey("cl", "C1", m.threadTs);
    const session = r.claude.last();
    await r.call(key, "chat_state", { kind: "waiting", seconds: 60, for: "build" });
    session.complete();
    await settle();
    t.mock.timers.tick(61_000);
    await settle();
    assert.equal(session.steers.length, 0, "no mid-turn steer after normal turn completion");
    assert.equal(session.prompts.length, 2, "normal post-turn waitOver starts a new turn");
    await r.close();
  }
});

test("mid-turn waiting timer survives station handover and fires on schedule", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: Date.now() });
  const first = new Rig();
  const m = message();
  await first.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);

  await first.call(key, "chat_state", { kind: "waiting", seconds: 60, for: "run suite" });
  t.mock.timers.tick(25_000);
  await settle();

  const handed = await first.hub.handOver();
  assert.equal(handed.sessions.length, 1);
  assert.equal(handed.sessions[0]!.midWaitingSeconds, 60);
  assert.ok((handed.sessions[0]!.midWaitingMs ?? 0) > 30_000 && (handed.sessions[0]!.midWaitingMs ?? 0) <= 35_000);

  const claude = new FakeDriver("claude");
  const hub = first.newHub({
    chats: (id) => (id === "cl" ? first.chat : undefined),
    drivers: [claude, new FakeDriver("codex")],
    internal: false,
  });
  hub.hold("starting");
  await hub.takeUp();
  hub.release("starting");
  await settle();

  const taken = claude.last();
  t.mock.timers.tick(30_000);
  await settle();
  assert.equal(taken.steers.length, 0, "does not fire before remaining mid-turn wait elapses");

  t.mock.timers.tick(10_000);
  await settle();
  assert.equal(taken.steers.length, 1, "fires remaining mid-turn wait after handover");
  assert.ok(taken.steers[0]!.includes("waiting on work you started (60 seconds)"), taken.steers[0]);

  await chatState(hub, key, { kind: "all_done", done: "recovered after handover" });
  taken.complete();
  await settle();
  await hub.shutdown();
  await first.close();
});

test("long silent waiting chains remind the agent to post progress, throttle reminders, and reset on chat_post or settlement", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: Date.now() });
  const r = new Rig();
  const m = message();
  const to = `C1/${m.threadTs}`;
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const session = r.claude.last();

  // Turn 1: agent posts initial plan and waits.
  await chatPost(r.hub, key, { to, text: "Starting run 1." });
  await r.call(key, "chat_state", { kind: "waiting", seconds: 300, for: "run 1" });
  session.complete();
  await settle();

  // T+4m: job finishes, under 10m threshold -> no progress reminder.
  t.mock.timers.tick(4 * 60_000);
  await r.hub.notify(key, "Remote task run-1 ended");
  await settle();
  assert.equal(session.prompts.length, 2);
  assert.ok(!session.prompts[1]!.includes("You have not posted in the chat"), session.prompts[1]);

  // Turn 2: stays silent and enters waiting again.
  await r.call(key, "chat_state", { kind: "waiting", seconds: 300, for: "run 2" });
  session.complete();
  await settle();

  // T+8m: still under 10m threshold -> no reminder.
  t.mock.timers.tick(4 * 60_000);
  await r.hub.notify(key, "Remote task run-2 ended");
  await settle();
  assert.equal(session.prompts.length, 3);
  assert.ok(!session.prompts[2]!.includes("You have not posted in the chat"), session.prompts[2]);

  // Turn 3: still silent, enters waiting again.
  await r.call(key, "chat_state", { kind: "waiting", seconds: 300, for: "run 3" });
  session.complete();
  await settle();

  // T+11m: past 10m threshold -> job wakeup includes progress reminder.
  t.mock.timers.tick(3 * 60_000);
  await r.hub.notify(key, "Remote task run-3 ended");
  await settle();
  assert.equal(session.prompts.length, 4);
  assert.ok(session.prompts[3]!.includes("You have not posted in the chat for 11 minutes."), session.prompts[3]);
  assert.ok(session.prompts[3]!.includes("chat_post"), session.prompts[3]);

  // Turn 4: ignores reminder and waits 60s -> waitOver at T+12m is throttled (no back-to-back nag).
  await r.call(key, "chat_state", { kind: "waiting", seconds: 60, for: "probe 4" });
  session.complete();
  await settle();
  t.mock.timers.tick(61_000);
  await settle();
  assert.equal(session.prompts.length, 5);
  assert.ok(session.prompts[4]!.includes("waiting on work you started (60 seconds)"), session.prompts[4]);
  assert.ok(!session.prompts[4]!.includes("You have not posted in the chat"), session.prompts[4]);

  // Turn 5: still silent for another 11m -> next waitOver reminds again.
  await r.call(key, "chat_state", { kind: "waiting", seconds: 660, for: "run 5" });
  session.complete();
  await settle();
  t.mock.timers.tick(661_000);
  await settle();
  assert.equal(session.prompts.length, 6);
  assert.ok(session.prompts[5]!.includes("You have not posted in the chat for 23 minutes."), session.prompts[5]);

  // Turn 6: agent posts progress update -> silence timer resets.
  await chatPost(r.hub, key, { to, text: "Progress update: run 5 complete, starting run 6." });
  await r.call(key, "chat_state", { kind: "waiting", seconds: 300, for: "run 6" });
  session.complete();
  await settle();

  // T+4m after post (before 300s wait expires) -> job wakeup has no reminder.
  t.mock.timers.tick(4 * 60_000);
  await r.hub.notify(key, "Remote task run-6 ended");
  await settle();
  assert.equal(session.prompts.length, 7);
  assert.ok(!session.prompts[6]!.includes("You have not posted in the chat"), session.prompts[6]);

  // Turn 7 settles all_done -> silence chain clears, so a much later notice does not remind.
  await r.call(key, "chat_state", { kind: "all_done", done: "all runs complete" });
  session.complete();
  await settle();
  t.mock.timers.tick(20 * 60_000);
  await r.hub.notify(key, "Unrelated later notice");
  await settle();
  assert.equal(session.prompts.length, 8);
  assert.ok(!session.prompts[7]!.includes("You have not posted in the chat"), session.prompts[7]);

  // Turn 8 enters a standing watch (watch: true) -> long watch does not accumulate silent waiting reminders.
  r.store.insertJob(watchJob(key));
  await r.call(key, "chat_state", { kind: "waiting", seconds: 300, for: "watch ci", watch: true });
  session.complete();
  await settle();
  t.mock.timers.tick(20 * 60_000);
  await r.hub.notify(key, "Watch alert");
  await settle();
  assert.equal(session.prompts.length, 9);
  assert.ok(!session.prompts[8]!.includes("You have not posted in the chat"), session.prompts[8]);
  await r.close();
});

test("mid-turn waiting timer also carries the silent progress reminder after 10 minutes", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: Date.now() });
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const session = r.claude.last();

  await r.call(key, "chat_state", { kind: "waiting", seconds: 600, for: "long build" });
  t.mock.timers.tick(601_000);
  await settle();
  assert.equal(session.steers.length, 1);
  assert.ok(session.steers[0]!.includes("waiting on work you started (600 seconds)"), session.steers[0]);
  assert.ok(session.steers[0]!.includes("You have not posted in the chat for 10 minutes."), session.steers[0]);
  await r.close();
});
