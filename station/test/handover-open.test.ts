import assert from "node:assert/strict";
import { test } from "node:test";
import { RESUME_AFTER_RESTART } from "../src/agents/instructions.ts";
import type { OpenOptions, RuntimeEvent } from "../src/agents/runtime.ts";
import { chatState } from "../src/sessions/conversations.ts";
import { sessionKey } from "../src/sessions/hub.ts";
import { FakeDriver, type FakeSession, Rig, message, settle } from "./hub-fakes.ts";

function deferred<T = void>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function hookOpen(driver: FakeDriver) {
  const orig = driver.open.bind(driver);
  const state = {
    block: true,
    opened: deferred<OpenOptions>(),
    abortedReasons: [] as string[],
    onAbort: undefined as ((reason: string) => void) | undefined,
  };
  driver.open = async (options: OpenOptions, events: (event: RuntimeEvent) => void): Promise<FakeSession> => {
    if (!state.block) return orig(options, events);
    state.opened.resolve(options);
    return await new Promise<FakeSession>((_resolve, reject) => {
      const fail = () => {
        const reason = typeof options.signal?.reason === "string" ? options.signal.reason : "aborted";
        state.abortedReasons.push(reason);
        state.onAbort?.(reason);
        reject(new Error(`open aborted: ${reason}`));
      };
      if (options.signal?.aborted) return fail();
      options.signal?.addEventListener("abort", fail, { once: true });
    });
  };
  return state;
}

test("handover aborts in-flight user-message open before beforeFreeze and delivers cleanly on next station", async () => {
  const first = new Rig();
  const hooked = hookOpen(first.claude);
  const order: string[] = [];
  hooked.onAbort = (reason) => order.push(`abort:${reason}`);

  const m = message({ text: "hello across restart" });
  await first.accept(m);
  const key = sessionKey("cl", "C1", m.threadTs);

  await hooked.opened.promise;
  assert.equal(first.hub.actors.get(key)!.isOpening(), true, "actor is opening its runtime");

  const handed = await first.hub.handOver(30_000, async () => {
    order.push("beforeFreeze");
  });

  assert.deepEqual(order, ["abort:handover", "beforeFreeze"], "aborts in-flight open before closing MCP door");
  assert.deepEqual(hooked.abortedReasons, ["handover"]);
  assert.equal(first.chat.posts.length, 0, "no failure notice posted on handover open abort");
  assert.equal(first.store.hasPending(key), true, "user message stays pending for the next station");
  assert.equal(first.store.getSession(key)!.running, false, "pending user message does not set running");
  assert.equal(handed.sessions.length, 0, "cold session with no live agent is not snapshotted");

  const nextDriver = new FakeDriver("claude");
  const hub = first.newHub({
    chats: (id) => (id === "cl" ? first.chat : undefined),
    drivers: [nextDriver, new FakeDriver("codex")],
    internal: false,
  });
  hub.hold("starting");
  await hub.takeUp();
  hub.recover();
  hub.release("starting");
  await settle();

  assert.equal(nextDriver.count(), 1, "next station opens a fresh runtime");
  const resumed = nextDriver.last();
  assert.equal(resumed.prompts.length, 1);
  assert.ok(resumed.prompts[0]!.includes("hello across restart"), resumed.prompts[0]);
  assert.ok(!resumed.prompts[0]!.includes(RESUME_AFTER_RESTART), "delivers pending message directly without restart wrapper");

  await hub.shutdown();
  await first.close();
});

test("handover aborts in-flight non-input turn open and marks session running for next station recover", async () => {
  const first = new Rig();
  const hooked = hookOpen(first.claude);
  hooked.block = false;

  const m = message({ text: "initial task" });
  await first.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  await chatState(first.hub, key, { kind: "all_done", done: "initial done" });
  first.claude.last().complete();
  await settle();

  // Evict so recover() must call node.open.
  await first.hub.actors.get(key)!.evict(true);
  await settle();
  assert.equal(first.hub.processState(key), "cold");

  hooked.block = true;
  first.store.setRunning(key, true);
  void first.hub.actors.get(key)!.recover();
  await hooked.opened.promise;

  const handed = await first.hub.handOver();
  assert.deepEqual(hooked.abortedReasons, ["handover"]);
  assert.equal(first.chat.posts.length, 0, "no failure notice posted");
  assert.equal(first.store.hasPending(key), false);
  assert.equal(first.store.getSession(key)!.running, true, "non-input aborted turn is kept running for recover");
  assert.equal(handed.sessions.length, 0);

  const nextDriver = new FakeDriver("claude");
  const hub = first.newHub({
    chats: (id) => (id === "cl" ? first.chat : undefined),
    drivers: [nextDriver, new FakeDriver("codex")],
    internal: false,
  });
  hub.hold("starting");
  await hub.takeUp();
  hub.recover();
  hub.release("starting");
  await settle();

  assert.equal(nextDriver.count(), 1, "next station resumes the aborted non-input turn");
  assert.equal(nextDriver.last().prompts.length, 1);
  assert.ok(nextDriver.last().prompts[0]!.includes(RESUME_AFTER_RESTART), nextDriver.last().prompts[0]);

  await hub.shutdown();
  await first.close();
});

test("handover aborts in-flight warm open without marking session running", async () => {
  const first = new Rig();
  const hooked = hookOpen(first.claude);
  hooked.block = false;

  const m = message({ text: "seed session" });
  await first.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  await chatState(first.hub, key, { kind: "all_done", done: "seed turn finished cleanly" });
  first.claude.last().complete();
  await settle();
  await first.hub.actors.get(key)!.evict(true);
  await settle();

  hooked.block = true;
  void first.hub.actors.get(key)!.warm();
  await hooked.opened.promise;

  const handed = await first.hub.handOver();
  assert.deepEqual(hooked.abortedReasons, ["handover"]);
  assert.equal(first.store.getSession(key)!.running, false, "warm abort must not mark session running");
  assert.equal(handed.sessions.length, 0);

  const nextDriver = new FakeDriver("claude");
  const hub = first.newHub({
    chats: (id) => (id === "cl" ? first.chat : undefined),
    drivers: [nextDriver, new FakeDriver("codex")],
    internal: false,
  });
  hub.hold("starting");
  await hub.takeUp();
  hub.recover();
  hub.release("starting");
  await settle();

  assert.equal(nextDriver.count(), 0, "next station does not spuriously recover an aborted warm");

  await hub.shutdown();
  await first.close();
});

test("handover drains actor work enqueued during beforeFreeze into the handover snapshot", async () => {
  const first = new Rig();
  const m = message({ text: "finish during door close" });
  await first.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);

  const handed = await first.hub.handOver(30_000, async () => {
    await chatState(first.hub, key, { kind: "all_done", done: "recorded while door closing" });
  });

  assert.equal(handed.sessions.length, 1);
  assert.equal(handed.sessions[0]!.turn?.declared, "all_done");
  assert.equal(first.store.latestTurn(key)!.summary.declared, "final");

  await first.close();
});

test("handover rollback after beforeFreeze error restores opens and resumes aborted non-input turns", async () => {
  const first = new Rig();
  const hooked = hookOpen(first.claude);
  hooked.block = false;

  const m = message({ text: "seed rollback" });
  await first.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  await chatState(first.hub, key, { kind: "all_done", done: "seed turn finished cleanly" });
  first.claude.last().complete();
  await settle();
  await first.hub.actors.get(key)!.evict(true);
  await settle();

  hooked.block = true;
  first.store.setRunning(key, true);
  void first.hub.actors.get(key)!.recover();
  await hooked.opened.promise;

  const beforeCount = first.claude.count();
  await assert.rejects(
    () =>
      first.hub.handOver(30_000, async () => {
        hooked.block = false;
        throw new Error("door close failed");
      }),
    /door close failed/,
  );

  await settle();
  assert.equal(first.claude.count(), beforeCount + 1, "aborted recover turn resumes after handover rollback");
  assert.ok(first.claude.last().prompts[0]!.includes(RESUME_AFTER_RESTART), first.claude.last().prompts[0]);

  await first.close();
});
