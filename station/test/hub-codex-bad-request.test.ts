// A Codex turn refused with nothing but `{"detail":"Bad Request"}` (FB-26): never tried again by itself, and asked to
// go on (重试, a message) it is never sent to the thread as it is loaded, which refuses every turn. Its thread is first
// taken up again from its rollout (its context kept, the account's other threads untouched); refused again, the next
// turn starts afresh, its jobs kept (mb/src/reader/actor_run.mbt `refused_thread`).
import assert from "node:assert/strict";
import { test } from "node:test";
import { GO_ON_AFTER_FAILED } from "../src/agents/instructions.ts";
import { sessionKey } from "../src/sessions/hub.ts";
import { type FakeDriver, Rig, matches, message, reply, settle } from "./hub-fakes.ts";

const untimed = (text: string) => text.replace(/^\[Delivered at [^\n]+\]\n/, "");
const refused = (body = '{"detail":"Bad Request"}') => ({ kind: "failed" as const, reason: "model" as const, message: body });
const opened = (driver: FakeDriver, key: string) => driver.sessions.filter((s) => s.options.route === key);
const AFRESH = "Codex 仍拒绝原上下文（Bad Request），已自动换新上下文";

function watched(r: Rig) {
  const stopped: string[] = [];
  r.hub.setJobs({
    stop: async (id) => {
      stopped.push(id);
      r.store.jobEnded(id, "stopped", null);
      return r.store.getJob(id)!;
    },
  });
  return stopped;
}

const job = (session: string) => ({
  id: "job_ci", sessionKey: session, name: "盯 CI", command: "sleep 600", cwd: "/", port: null, token: "tci", state: "running",
  pgid: null, exitCode: null, startedAt: Date.now(), endedAt: null, restarts: 0, log: "/dev/null", watch: true,
});

test("a bare Bad Request is not tried again by itself; 重试 takes the thread up again, then starts afresh if refused again", async () => {
  const r = new Rig({ maxNudges: 0 });
  const stopped = watched(r);
  const m = message();
  await r.accept(m, "gpt");
  const other = message();
  await r.accept(other, "gpt");
  await settle();
  const key = sessionKey("gpt", "C1", m.threadTs);
  const [first] = opened(r.codex, key);
  const [sibling] = opened(r.codex, sessionKey("gpt", "C1", other.threadTs));
  assert.ok(first && sibling);
  r.store.insertJob(job(key));

  first.end(refused());
  await settle();
  // Not tried again by itself: said, and waits on a person.
  assert.equal(r.codex.count(), 2);
  assert.equal(first.prompts.length, 1);
  assert.equal(first.disposed, false);
  assert.ok(r.gptChat.texts().some((t) => t.includes('{"detail":"Bad Request"}')), r.gptChat.texts().join("\n"));
  const about = r.store.lastTurn(key)!.about!;

  // A press on another notice than the one its turn is about: nothing.
  await r.hub.retryFailed(key, about.thread, about.seq + 1);
  await settle();
  assert.equal(first.disposed, false);
  assert.equal(r.codex.count(), 2);

  // 重试: the thread let go and taken up again from its rollout, the account's other thread untouched.
  await r.hub.retryFailed(key, about.thread, about.seq);
  await settle();
  assert.equal(first.disposed, true, "the refused thread is let go");
  assert.equal(sibling.disposed, false, "the account's other thread goes on");
  assert.equal(first.prompts.length, 1, "never asked again on the thread as it was loaded");
  const reloaded = r.codex.last();
  assert.notEqual(reloaded, first);
  assert.equal(reloaded.options.resume, first.sessionId);
  assert.deepEqual(reloaded.prompts.map(untimed), [GO_ON_AFTER_FAILED]);
  assert.equal(r.session(key).runtimeSessionId, first.sessionId);
  // Pressed again while it runs: no second turn, no second process.
  await r.hub.retryFailed(key, about.thread, about.seq);
  await settle();
  assert.equal(r.codex.count(), 3);
  assert.equal(reloaded.prompts.length, 1);

  // Taken up again and refused again: its history is what is refused. The next 重试 starts afresh, its jobs kept.
  reloaded.end(refused());
  await settle();
  assert.equal(r.codex.count(), 3, "still not tried again by itself");
  const again = r.store.lastTurn(key)!.about!;
  await r.hub.retryFailed(key, again.thread, again.seq);
  await settle();
  assert.equal(reloaded.disposed, true);
  const fresh = r.codex.last();
  assert.notEqual(fresh, reloaded);
  assert.equal(fresh.options.resume, undefined, "a new thread");
  assert.equal(r.session(key).runtimeSessionId, fresh.sessionId);
  assert.notEqual(fresh.sessionId, first.sessionId);
  assert.ok(r.gptChat.texts().some((t) => t.includes(AFRESH)), r.gptChat.texts().join("\n"));
  assert.equal(fresh.prompts.length, 1);
  assert.ok(matches(fresh.prompts[0]!, ["This is a new conversation", `session_history with chat ${key}`, GO_ON_AFTER_FAILED]), fresh.prompts[0]);
  assert.deepEqual(stopped, [], "its jobs are not stopped");
  assert.equal(r.store.getJob("job_ci")!.state, "running");
  assert.equal(sibling.disposed, false);
  await r.close();
});

test("a message after a bare Bad Request goes on in the thread taken up again, and afresh where that is refused too", async () => {
  const r = new Rig({ maxNudges: 0 });
  const stopped = watched(r);
  const m = message();
  await r.accept(m, "gpt");
  await settle();
  const key = sessionKey("gpt", "C1", m.threadTs);
  const first = r.codex.last();
  r.store.insertJob(job(key));
  // (its spacing aside, the same body)
  first.end(refused('{ "detail": "Bad Request" }'));
  await settle();
  assert.equal(first.prompts.length, 1);

  await r.accept(reply(m, "9999.1", "继续", { addressed: true }), "gpt");
  await settle();
  assert.equal(first.disposed, true);
  assert.equal(first.prompts.length, 1);
  const reloaded = r.codex.last();
  assert.equal(reloaded.options.resume, first.sessionId);
  assert.equal(reloaded.prompts.length, 1);
  assert.ok(reloaded.prompts[0]!.includes("继续"), reloaded.prompts[0]);

  // The thread taken up again works: refused later, it is taken up again first, not started afresh.
  reloaded.end({ kind: "completed" });
  await settle();
  await r.accept(reply(m, "9999.2", "下一步", { addressed: true }), "gpt");
  await settle();
  assert.equal(r.codex.last(), reloaded);
  assert.equal(reloaded.prompts.length, 2);
  reloaded.end(refused());
  await settle();
  await r.accept(reply(m, "9999.3", "继续吧", { addressed: true }), "gpt");
  await settle();
  assert.equal(reloaded.disposed, true);
  const back = r.codex.last();
  assert.notEqual(back, reloaded);
  assert.equal(back.options.resume, first.sessionId, "taken up again, its context kept");
  assert.equal(r.session(key).runtimeSessionId, first.sessionId);
  assert.ok(back.prompts[0]!.includes("继续吧"));
  assert.ok(!r.gptChat.texts().some((t) => t.includes(AFRESH)));

  // Refused again as soon as it is taken up again: the next message starts afresh, its jobs kept.
  back.end(refused());
  await settle();
  await r.accept(reply(m, "9999.4", "再试一次", { addressed: true }), "gpt");
  await settle();
  assert.equal(back.disposed, true);
  const fresh = r.codex.last();
  assert.notEqual(fresh, back);
  assert.equal(fresh.options.resume, undefined);
  assert.equal(r.session(key).runtimeSessionId, fresh.sessionId);
  assert.ok(r.gptChat.texts().some((t) => t.includes(AFRESH)));
  assert.ok(matches(fresh.prompts[0]!, ["This is a new conversation", `session_history with chat ${key}`, "再试一次"]), fresh.prompts[0]);
  assert.deepEqual(stopped, []);
  assert.equal(r.store.getJob("job_ci")!.state, "running");
  await r.close();
});

test("other failures are tried again on the thread as it is: Claude's Bad Request, a Bad Request that says more, a named detail", async () => {
  for (const [runtime, body] of [
    ["claude", '{"detail":"Bad Request"}'],
    ["codex", "service unavailable"],
    ["codex", '{"detail":"Unsupported parameter"}'],
    ["codex", '{"detail":"Bad Request","code":"invalid_thread"}'],
  ] as const) {
    const r = new Rig({ maxNudges: 0 });
    const m = message();
    const connect = runtime === "claude" ? "cl" : "gpt";
    const driver = runtime === "claude" ? r.claude : r.codex;
    await r.accept(m, connect);
    await settle();
    const key = sessionKey(connect, "C1", m.threadTs);
    const agent = driver.last();
    for (let pass = 0; pass < 3; pass++) {
      agent.end(refused(body));
      await settle();
      const about = r.store.lastTurn(key)!.about!;
      await r.hub.retryFailed(key, about.thread, about.seq);
      await settle();
    }
    assert.equal(driver.count(), 1, `${runtime} ${body}: one process`);
    assert.equal(agent.disposed, false, `${runtime} ${body}`);
    assert.deepEqual(agent.prompts.slice(1).map(untimed), [GO_ON_AFTER_FAILED, GO_ON_AFTER_FAILED, GO_ON_AFTER_FAILED]);
    assert.equal(r.session(key).runtimeSessionId, agent.sessionId);
    assert.ok(!(runtime === "claude" ? r.chat : r.gptChat).texts().some((t) => t.includes(AFRESH)));
    await r.close();
  }
});
