// A provider's opaque 400 must not pin what follows (Retry, a message, /compact) to the same loaded Codex thread.
import assert from "node:assert/strict";
import { test } from "node:test";
import { GO_ON_AFTER_FAILED } from "../src/agents/instructions.ts";
import { newSession, say } from "../src/sessions/lifecycle.ts";
import { FakeDriver, Rig, settle } from "./hub-fakes.ts";

async function finish(r: Rig) {
  for (const agent of [...r.codex.sessions, ...r.claude.sessions]) if (agent.busy()) agent.end({ kind: "aborted" });
  await settle();
  await r.quiet();
  await r.close();
}

for (const message of ['{"detail":"Bad Request"}', '{ "detail": "Bad Request" }']) {
  test(`retry resumes the same Codex history in a thread loaded again after ${message}`, async () => {
    const r = new Rig();
    try {
      const [key, thread] = await newSession(r.hub, { runtime: "codex", createdBy: "local" });
      say(r.hub, thread.id, "a@example.com", "do the work");
      await settle();
      const failed = r.codex.last();
      const [, otherThread] = await newSession(r.hub, { runtime: "codex", createdBy: "local" });
      say(r.hub, otherThread.id, "a@example.com", "other work");
      await settle();
      const other = r.codex.last();
      failed.end({ kind: "failed", reason: "model", message });
      await settle();
      const about = r.store.lastTurn(key)!.about!;
      assert.equal(r.codex.count(), 2, "a 400 is not retried automatically");
      assert.equal(failed.disposed, true, "the refused thread is let go of as the turn fails");
      assert.equal(other.disposed, false, "the account's other thread keeps running");
      await r.hub.retryFailed(key, thread.id, about.seq + 1);
      await settle();
      assert.equal(r.codex.count(), 2, "an unrelated notice starts nothing");
      await r.hub.retryFailed(key, thread.id, about.seq);
      await settle();
      const resumed = r.codex.last();
      assert.equal(r.codex.count(), 3);
      assert.equal(other.prompts.length, 1);
      assert.equal(resumed.options.resume, failed.id(), "resume the history, never start afresh");
      assert.equal(r.session(key).runtimeSessionId, failed.id());
      assert.equal(resumed.prompts.length, 1);
      assert.ok(resumed.prompts[0]!.includes(GO_ON_AFTER_FAILED), "continue from the results, not the original command");
      await r.hub.retryFailed(key, thread.id, about.seq);
      await settle();
      assert.equal(r.codex.count(), 3, "a repeated press does not start another turn");
      resumed.end({ kind: "failed", reason: "model", message });
      await settle();
      assert.equal(r.codex.count(), 3, "another refusal still waits for the person");
      assert.equal(resumed.disposed, true);
    } finally {
      await finish(r);
    }
  });
}

test("a person's next message after an opaque Bad Request resumes the same Codex history", async () => {
  const r = new Rig();
  try {
    const [key, thread] = await newSession(r.hub, { runtime: "codex", createdBy: "local" });
    say(r.hub, thread.id, "a@example.com", "do the work");
    await settle();
    const failed = r.codex.last();
    failed.end({ kind: "failed", reason: "model", message: '{"detail":"Bad Request"}' });
    await settle();
    assert.equal(r.codex.count(), 1, "a 400 is not retried automatically");
    say(r.hub, thread.id, "a@example.com", "and now?");
    await settle();
    const resumed = r.codex.last();
    assert.equal(r.codex.count(), 2);
    assert.equal(failed.disposed, true);
    assert.equal(resumed.options.resume, failed.id(), "resume the history, never start afresh");
    assert.equal(r.session(key).runtimeSessionId, failed.id());
    assert.equal(resumed.prompts.length, 1);
    assert.ok(resumed.prompts[0]!.includes("and now?"));
    resumed.end({ kind: "completed" });
    await settle();
    say(r.hub, thread.id, "a@example.com", "once more");
    await settle();
    assert.equal(r.codex.count(), 2, "a thread that answered stays loaded");
    assert.equal(resumed.disposed, false);
    assert.equal(resumed.prompts.length, 2);
  } finally {
    await finish(r);
  }
});

test("/compact after an opaque Bad Request compacts a thread loaded again, and the next message keeps it", async () => {
  const r = new Rig();
  try {
    const [key, thread] = await newSession(r.hub, { runtime: "codex", createdBy: "local" });
    say(r.hub, thread.id, "a@example.com", "do the work");
    await settle();
    const failed = r.codex.last();
    failed.end({ kind: "failed", reason: "model", message: '{"detail":"Bad Request"}' });
    await settle();
    assert.equal(await r.hub.compact(key), null);
    await settle();
    const resumed = r.codex.last();
    assert.equal(r.codex.count(), 2);
    assert.equal(failed.compactions, 0, "never compacted on the refused thread");
    assert.equal(resumed.compactions, 1);
    assert.equal(resumed.options.resume, failed.id());
    resumed.complete();
    await settle();
    say(r.hub, thread.id, "a@example.com", "go on");
    await settle();
    assert.equal(r.codex.count(), 2, "the thread compacted is not let go of again");
    assert.equal(resumed.disposed, false);
    assert.equal(resumed.prompts.length, 1);
  } finally {
    await finish(r);
  }
});

// A station from before this kept the refused thread loaded: the next one takes it up and lets go of it before its use.
test("a Codex thread taken up after an opaque Bad Request is loaded again before its next use", async () => {
  const first = new Rig();
  const codex = new FakeDriver("codex");
  let hub: ReturnType<Rig["newHub"]> | null = null;
  try {
    const [key, thread] = await newSession(first.hub, { runtime: "codex", createdBy: "local" });
    say(first.hub, thread.id, "a@example.com", "do the work");
    await settle();
    const old = first.codex.last();
    await first.call(key, "chat_state", { kind: "all_done", done: "the work was done and checked" });
    old.complete();
    await settle();
    assert.equal(old.disposed, false);
    // (as a station from before ended a turn so refused, its thread left loaded)
    first.store.startTurn("refused", key, "input");
    first.store.endTurn("refused", "failed", 'model: {"detail":"Bad Request"}', null, null);
    await first.hub.handOver();
    hub = first.newHub({ chats: () => undefined, drivers: [new FakeDriver("claude"), codex], internal: false });
    await hub.takeUp();
    hub.recover();
    await settle();
    const taken = codex.last();
    assert.equal(taken.id(), old.id(), "the thread is taken up as it was");
    say(hub, thread.id, "a@example.com", "and now?");
    await settle();
    const resumed = codex.last();
    assert.equal(taken.disposed, true, "let go of before its next use");
    assert.notEqual(resumed, taken);
    assert.equal(resumed.options.resume, old.id(), "resume the history, never start afresh");
    assert.ok(resumed.prompts[0]!.includes("and now?"));
    resumed.complete();
    await settle();
    say(hub, thread.id, "a@example.com", "once more");
    await settle();
    assert.equal(codex.last(), resumed, "checked once: the thread loaded again stays");
  } finally {
    for (const agent of [...codex.sessions, ...first.codex.sessions]) if (agent.busy()) agent.end({ kind: "aborted" });
    await settle();
    await hub?.shutdown();
    await first.close();
  }
});

for (const [runtime, message] of [
  ["claude", '{"detail":"Bad Request"}'],
  ["codex", "service unavailable"],
  ["codex", '{"detail":"Unsupported parameter"}'],
  ["codex", '{"detail":"Bad Request","code":"invalid_prompt"}'],
] as const) {
  test(`${runtime}'s other failure keeps its ordinary retry: ${message}`, async () => {
    const r = new Rig();
    try {
      const [key, thread] = await newSession(r.hub, { runtime, createdBy: "local" });
      say(r.hub, thread.id, "a@example.com", "do the work");
      await settle();
      const driver = runtime === "codex" ? r.codex : r.claude;
      const agent = driver.last();
      agent.end({ kind: "failed", reason: "model", message });
      await settle();
      assert.equal(agent.disposed, false);
      const about = r.store.lastTurn(key)!.about!;
      await r.hub.retryFailed(key, thread.id, about.seq);
      await settle();
      assert.equal(agent.disposed, false);
      assert.equal(driver.count(), 1);
      assert.equal(agent.prompts.length, 2);
    } finally {
      await finish(r);
    }
  });
}
