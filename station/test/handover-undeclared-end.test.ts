import assert from "node:assert/strict";
import { test } from "node:test";
import { NUDGE } from "../src/agents/instructions.ts";
import { chatState } from "../src/sessions/conversations.ts";
import { sessionKey } from "../src/sessions/hub.ts";
import { FakeDriver, Rig, message, reply, settle, testClock } from "./hub-fakes.ts";

test("undeclared turn end during drain hold survives handover and nudges on release without flashing warm", async () => {
  const first = new Rig();
  const m = message();
  await first.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const old = first.claude.last();

  first.hub.hold("drain");
  old.complete();
  await settle();

  assert.equal(old.prompts.length, 1, "does not nudge while held");
  assert.equal(first.hub.processState(key), "running", "stays running while deferred end waits on hold");
  assert.equal(first.store.getSession(key)!.running, true, "store running stays true during handover window");

  const handed = await first.hub.handOver();
  assert.equal(handed.sessions.length, 1, "session with deferred end is handed over");
  assert.ok(handed.sessions[0]!.deferredEnd != null, "snapshot carries deferredEnd");

  const claude = new FakeDriver("claude");
  const hub = first.newHub({
    chats: (id) => (id === "cl" ? first.chat : undefined),
    drivers: [claude, new FakeDriver("codex")],
    internal: false,
  });
  hub.hold("starting");
  await hub.takeUp();
  assert.equal(hub.processState(key), "running", "stays running after adopt while still held");

  hub.release("starting");
  await settle();

  const taken = claude.last();
  assert.equal(taken.sessionId, old.sessionId);
  assert.equal(taken.prompts.length, 1, "nudges after release");
  assert.ok(taken.prompts[0]!.includes(NUDGE), taken.prompts[0]);

  await chatState(hub, key, { kind: "all_done", done: "finished after handover nudge" });
  taken.complete();
  await settle();
  assert.equal(hub.processState(key), "warm");
  assert.equal(first.store.getSession(key)!.running, false);

  await hub.shutdown();
  await first.close();
});

test("undeclared turn end during starting hold nudges on release", async () => {
  const first = new Rig();
  const m = message();
  await first.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const old = first.claude.last();
  await first.hub.handOver();

  const claude = new FakeDriver("claude");
  const hub = first.newHub({
    chats: (id) => (id === "cl" ? first.chat : undefined),
    drivers: [claude, new FakeDriver("codex")],
    internal: false,
  });
  hub.hold("starting");
  await hub.takeUp();

  const taken = claude.last();
  assert.equal(taken.sessionId, old.sessionId);
  taken.complete();
  await settle();
  assert.equal(taken.prompts.length, 0, "does not nudge while starting hold is active");
  assert.equal(hub.processState(key), "running", "stays running during starting hold");

  hub.release("starting");
  await settle();
  assert.equal(taken.prompts.length, 1, "nudges once starting hold is released");
  assert.ok(taken.prompts[0]!.includes(NUDGE), taken.prompts[0]);

  await hub.shutdown();
  await first.close();
});

test("user message or stop before release cancels deferred nudge", async () => {
  // Case 1: user message arrives while held; release pumps the message instead of nudging.
  {
    const r = new Rig();
    const m = message();
    await r.accept(m);
    await settle();
    const key = sessionKey("cl", "C1", m.threadTs);
    const session = r.claude.last();

    r.hub.hold("drain");
    session.complete();
    await settle();
    assert.equal(r.hub.processState(key), "running");

    await r.accept(reply(m, "9999.1", "follow-up before release"));
    await settle();
    r.hub.release("drain");
    await settle();

    assert.equal(session.prompts.length, 2, "pumps the new user message");
    assert.ok(session.prompts[1]!.includes("follow-up before release"), session.prompts[1]);
    assert.ok(!session.prompts[1]!.includes(NUDGE), "does not send a stale nudge");
    await r.close();
  }

  // Case 2: stop() while held clears deferred_end and warm so release does not nudge.
  {
    const r = new Rig();
    const m = message();
    await r.accept(m);
    await settle();
    const key = sessionKey("cl", "C1", m.threadTs);
    const session = r.claude.last();

    r.hub.hold("drain");
    session.complete();
    await settle();
    assert.equal(r.hub.processState(key), "running");

    await r.hub.stop(key);
    await settle();
    assert.equal(r.hub.processState(key), "warm", "stop clears warm and deferred end");
    assert.equal(r.store.getSession(key)!.running, false, "stop clears store running");

    r.hub.release("drain");
    await settle();
    assert.equal(session.prompts.length, 1, "release does not nudge after stop");
    await r.close();
  }
});

test("warm keeps processState running between undeclared turn end and nudge begin_turn without leaking", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const session = r.claude.last();
  const actor = r.hub.actors.get(key)!;

  const observed: string[] = [];
  const origMirrored = actor.mirrored.bind(actor);
  actor.mirrored = (state) => {
    origMirrored(state);
    observed.push(r.hub.processState(key));
  };

  session.complete();
  await settle();

  assert.equal(session.prompts.length, 2, "nudged once");
  assert.ok(session.prompts[1]!.includes(NUDGE));
  assert.ok(observed.length > 0, "observed mirror updates during undeclared end -> nudge");
  assert.ok(
    observed.every((s) => s === "running"),
    `processState must stay running during nudge transition, saw: ${JSON.stringify(observed)}`,
  );

  // Exhaust maxNudges (default is 2; we already nudged once above).
  session.complete();
  await settle();
  assert.equal(session.prompts.length, 3, "nudged second time");
  session.complete();
  await settle();
  assert.equal(session.prompts.length, 3, "gave up after maxNudges");
  assert.equal(r.hub.processState(key), "warm", "warm does not leak after give_up");
  assert.equal(r.store.getSession(key)!.running, false);
  assert.notEqual(actor.idleMs(time.clock.currentTimeMillisUnsafe()), null, "idleMs available after give_up");

  // Also check normal all_done clears warm cleanly.
  await r.accept(reply(m, "9999.2", "next task"));
  await settle();
  await r.call(key, "chat_state", { kind: "all_done", done: "done cleanly" });
  session.complete();
  await settle();
  assert.equal(r.hub.processState(key), "warm", "returns to warm after normal all_done");
  assert.notEqual(actor.idleMs(time.clock.currentTimeMillisUnsafe()), null, "idleMs available after all_done");

  await r.close();
});

test("actor.declare returns false when turn ended or actor closed, and chat_state throws instead of claiming Recorded", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const session = r.claude.last();
  const actor = r.hub.actors.get(key)!;

  await r.call(key, "chat_state", { kind: "all_done", done: "initial done" });
  session.complete();
  await settle();

  // No active turn: declare must return false and chat_state must throw.
  assert.equal(await actor.declare({ kind: "all_done" }), false, "declare returns false with no active turn");
  await assert.rejects(
    () => r.call(key, "chat_state", { kind: "all_done", done: "late state" }),
    /the turn ended before its state was recorded; its state was not recorded/,
  );

  // Closed actor: declare must also return false.
  actor.close();
  assert.equal(await actor.declare({ kind: "waiting", seconds: 60 }), false, "declare returns false on closed actor");

  await r.close();
});
