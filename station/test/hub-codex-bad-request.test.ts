// A provider's opaque 400 must not pin every press of Retry to the same loaded Codex thread.
import assert from "node:assert/strict";
import { test } from "node:test";
import { GO_ON_AFTER_FAILED } from "../src/agents/instructions.ts";
import { newSession, say } from "../src/sessions/lifecycle.ts";
import { Rig, settle } from "./hub-fakes.ts";

for (const message of ['{"detail":"Bad Request"}', '{ "detail": "Bad Request" }']) {
  test(`retry reloads the same Codex history after ${message}`, async () => {
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
      await r.hub.retryFailed(key, thread.id, about.seq + 1);
      await settle();
      assert.equal(failed.disposed, false, "an unrelated notice cannot unload a thread");
      await r.hub.retryFailed(key, thread.id, about.seq);
      await settle();
      const resumed = r.codex.last();
      assert.equal(r.codex.count(), 3);
      assert.equal(failed.disposed, true);
      assert.equal(other.disposed, false, "the account's other thread keeps running");
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
    } finally {
      for (const agent of [...r.codex.sessions, ...r.claude.sessions]) if (agent.busy()) agent.end({ kind: "aborted" });
      await settle();
      await r.quiet();
      await r.close();
    }
  });
}

for (const [runtime, message] of [
  ["claude", '{"detail":"Bad Request"}'],
  ["codex", "service unavailable"],
  ["codex", '{"detail":"Unsupported parameter"}'],
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
      const about = r.store.lastTurn(key)!.about!;
      await r.hub.retryFailed(key, thread.id, about.seq);
      await settle();
      assert.equal(agent.disposed, false);
      assert.equal(driver.count(), 1);
      assert.equal(agent.prompts.length, 2);
    } finally {
      for (const agent of [...r.codex.sessions, ...r.claude.sessions]) if (agent.busy()) agent.end({ kind: "aborted" });
      await settle();
      await r.quiet();
      await r.close();
    }
  });
}
