// A session's runtime whose process never opens (FB-34: switched back from another account, its start stuck in a call
// that never returned): its start is given up after its deadline, saying so, its conversation kept; a stop (the app's,
// `-stop` in its thread) gives it up at once, said stopped once; what its queue holds runs after either; and the
// process that comes of the stuck start later is ended, never the session's.
import assert from "node:assert/strict";
import { test } from "node:test";
import { sessionKey } from "../src/sessions/hub.ts";
import { type FakeDriver, Rig, message, reply, say, settle, testClock } from "./hub-fakes.ts";

const STOPPED = "已停止当前任务";
const TIMED_OUT = "⚠️ 无法启动 agent：启动超时，回复即可重试";

/// `driver`'s opens held while `on` (each counted in `started` as it is asked, the signal it was given in `signals`), all
/// let go at once by `release`.
function stuckOpens(driver: FakeDriver) {
  const open = driver.open.bind(driver);
  let release!: () => void;
  let gate = new Promise<void>((r) => (release = r));
  let started!: () => void;
  const s = {
    on: false,
    asked: 0,
    signals: [] as (AbortSignal | undefined)[],
    started: Promise.resolve(),
    hold() {
      s.on = true;
      s.started = new Promise<void>((r) => (started = r));
    },
    release() {
      s.on = false;
      release();
      gate = new Promise<void>((r) => (release = r));
    },
  };
  driver.open = async (...args) => {
    if (s.on) {
      s.asked++;
      s.signals.push(args[0].signal);
      started();
      await gate;
    }
    return open(...args);
  };
  return s;
}

/// A rig on a test clock with a session that ran a turn, ended all_done, and was let go (its next turn opens a process
/// again, resuming its conversation).
async function idleSession() {
  const time = testClock();
  await time.adjust(1_700_000_000_000);
  const r = new Rig({ clock: time.clock });
  const stuck = stuckOpens(r.claude);
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const first = r.claude.last();
  await r.call(key, "chat_state", { kind: "all_done", done: "回复了测试消息，没有待办" });
  first.complete();
  await settle();
  await r.hub.evict(key);
  await settle();
  assert.ok(first.disposed, "its process let go");
  assert.equal(r.session(key).runtimeSessionId, first.sessionId);
  return { time, r, stuck, m, key, first };
}

async function phaseOf(r: Rig, key: string) {
  await r.hub.live.idle();
  return (((await r.hub.live.nowOf([key]))[key] ?? []).find((l: any) => l.type === "steps") as any)?.phase ?? null;
}

test("a runtime that never opens is given up after its deadline, said so; its conversation kept, its late process ended, the next message answered", async () => {
  const { time, r, stuck, m, key, first } = await idleSession();
  try {
    stuck.hold();
    await r.accept(reply(m, "9999.1", "again"));
    await stuck.started;
    // (nothing said before its deadline)
    await time.adjust(119_000);
    assert.notEqual(r.chat.lastText(), TIMED_OUT);
    const signal = stuck.signals.at(-1);
    assert.ok(signal !== undefined, "the driver is given the opening's signal");
    assert.equal(signal.aborted, false);
    await time.adjust(1_000);
    await settle();
    assert.equal(r.chat.lastText(), TIMED_OUT);
    assert.equal(signal.aborted, true, "given up for the driver too: one opening again after a failure stops (AgyDriver)");
    assert.equal(r.session(key).running, false);
    assert.equal(await phaseOf(r, key), null, "no longer said to be starting");
    assert.equal(r.session(key).runtimeSessionId, first.sessionId, "its conversation is still the session's");
    const opened = r.claude.count();
    // The stuck start comes back late: its process ended, never the session's.
    stuck.release();
    await settle();
    assert.equal(r.claude.count(), opened + 1);
    assert.ok(r.claude.last().disposed, "the late process ended");
    assert.equal(r.hub.processState(key), "cold");
    // What it is told next runs at once, resuming its conversation.
    await r.accept(reply(m, "9999.2", "world"));
    await settle();
    const now = r.claude.last();
    assert.ok(!now.disposed);
    assert.equal(now.sessionId, first.sessionId);
    assert.ok(now.prompts.at(-1)!.includes("world"), now.prompts.at(-1));
  } finally {
    stuck.release();
    await r.close();
  }
});

test("what its background work told it, its start timed out, is kept and handed once it runs again (FB-34)", async () => {
  const time = testClock();
  await time.adjust(1_700_000_000_000);
  const r = new Rig({ clock: time.clock, maxWarmClaude: 0, warmMinutes: 0 });
  const stuck = stuckOpens(r.claude);
  try {
    const m = message();
    await r.accept(m);
    await settle();
    const key = sessionKey("cl", "C1", m.threadTs);
    const first = r.claude.last();
    await r.call(key, "chat_state", { kind: "waiting", for: "a job", seconds: 7200 });
    first.complete();
    await settle();
    assert.ok(first.disposed);
    stuck.hold();
    r.hub.notify(key, "a job ended");
    await stuck.started;
    await time.adjust(120_000);
    await settle();
    assert.equal(r.chat.lastText(), TIMED_OUT);
    stuck.release();
    await settle();
    assert.ok(r.claude.last().disposed, "the late process ended");
    const handed = () => r.claude.sessions.flatMap((s) => [...s.prompts, ...s.steers]).filter((p) => p.includes("a job ended")).length;
    assert.equal(handed(), 0, "not handed yet");
    // A person replies: that turn runs, and what the job told it is handed after it, not lost.
    await r.accept(reply(m, "9999.2", "world"));
    await settle();
    const now = r.claude.last();
    assert.ok(now.prompts.at(-1)!.includes("world"));
    await r.call(key, "chat_state", { kind: "all_done", done: "回复了测试消息，没有待办" });
    now.complete();
    await settle();
    assert.equal(handed(), 1, "what the job told it is handed once");
  } finally {
    stuck.release();
    await r.close();
  }
});

for (const how of ["the app", "-stop"] as const) {
  const stop = async (r: Rig, m: ReturnType<typeof message>, key: string) => {
    if (how === "the app") await r.hub.stop(key);
    else await r.accept(reply(m, "9999.5", "-stop"));
  };

  test(`a stop from ${how} gives up at once a start stuck after its wait woke it, said stopped once; the next message runs (FB-34)`, async () => {
    const time = testClock();
    await time.adjust(1_700_000_000_000);
    // (none kept warm: its process let go as its turn ends waiting, as on a station short of room)
    const r = new Rig({ clock: time.clock, maxWarmClaude: 0, warmMinutes: 0 });
    const stuck = stuckOpens(r.claude);
    try {
      const m = message();
      await r.accept(m);
      await settle();
      const key = sessionKey("cl", "C1", m.threadTs);
      const first = r.claude.last();
      await r.call(key, "chat_state", { kind: "waiting", for: "a job", seconds: 7200 });
      first.complete();
      await settle();
      assert.ok(first.disposed, "nothing of its own going: its process let go, the wait the station's");
      stuck.hold();
      r.hub.notify(key, "a job ended");
      await stuck.started;
      const before = r.chat.texts().length;
      const signal = stuck.signals.at(-1);
      assert.ok(signal !== undefined && !signal.aborted, "the driver is given the opening's signal");
      // (no clock moved: given up at once)
      await stop(r, m, key);
      await settle();
      assert.deepEqual(r.chat.texts().slice(before), [STOPPED]);
      assert.equal(signal.aborted, true, "given up for the driver too");
      assert.equal(r.session(key).running, false);
      assert.equal(await phaseOf(r, key), null);
      assert.equal(r.session(key).runtimeSessionId, first.sessionId);
      const opened = r.claude.count();
      stuck.release();
      await settle();
      assert.equal(r.claude.count(), opened + 1);
      assert.ok(r.claude.last().disposed, "the late process ended");
      await r.accept(reply(m, "9999.6", "world"));
      await settle();
      const now = r.claude.last();
      assert.ok(!now.disposed);
      assert.ok(now.prompts.at(-1)!.includes("world"), now.prompts.at(-1));
      assert.ok(!r.chat.texts().includes(TIMED_OUT));
    } finally {
      stuck.release();
      await r.close();
    }
  });

  test(`a stop from ${how} gives up at once a start stuck on a message, said stopped once; the message is not run again`, async () => {
    const { r, stuck, m, key, first } = await idleSession();
    try {
      stuck.hold();
      await r.accept(reply(m, "9999.1", "hello"));
      await stuck.started;
      const before = r.chat.texts().length;
      await stop(r, m, key);
      await settle();
      assert.deepEqual(r.chat.texts().slice(before), [STOPPED]);
      assert.equal(r.session(key).running, false);
      assert.equal(await phaseOf(r, key), null);
      assert.equal(r.session(key).runtimeSessionId, first.sessionId);
      stuck.release();
      await settle();
      assert.ok(r.claude.last().disposed, "the late process ended");
      const opened = r.claude.count();
      // Woken again with nothing new: what was stopped is not taken up again.
      await r.hub.actor(r.session(key)).kick();
      await settle();
      assert.equal(r.claude.count(), opened, "nothing started again");
      assert.equal(stuck.asked, 1);
      await r.accept(reply(m, "9999.6", "world"));
      await settle();
      const now = r.claude.last();
      assert.ok(!now.disposed);
      const prompt = now.prompts.at(-1)!;
      assert.ok(prompt.includes("world"), prompt);
      assert.ok(!prompt.includes("hello"), `the stopped message is not handed again: ${prompt}`);
    } finally {
      stuck.release();
      await r.close();
    }
  });
}

test("a message that waited on a warm whose runtime never opened fails once with it, not again for as long; the next message runs both", async () => {
  const { time, r, stuck, m, key, first } = await idleSession();
  try {
    stuck.hold();
    const warmed = r.hub.warm(key).catch(() => undefined);
    await stuck.started;
    // (said while the warm opens: its kick waits behind it)
    await r.accept(reply(m, "9999.1", "hello"));
    await time.adjust(120_000);
    await settle();
    await warmed;
    assert.equal(r.chat.texts().filter((t) => t === TIMED_OUT).length, 1, "said once");
    assert.equal(stuck.asked, 1, "the kick behind the warm did not wait on another opening");
    assert.equal(r.session(key).running, false);
    stuck.release();
    await settle();
    assert.ok(r.claude.last().disposed, "the late process ended");
    await r.accept(reply(m, "9999.2", "world"));
    await settle();
    const now = r.claude.last();
    assert.ok(!now.disposed);
    assert.equal(now.sessionId, first.sessionId);
    const prompt = now.prompts.at(-1)!;
    assert.ok(prompt.includes("world"), prompt);
    assert.ok(prompt.includes("hello"), `what waited on the warm is handed too: ${prompt}`);
    assert.equal(r.chat.texts().filter((t) => t === TIMED_OUT).length, 1);
  } finally {
    stuck.release();
    await r.close();
  }
});

test("a warm whose runtime never opens, with nothing waiting on it, says nothing; the next message runs", async () => {
  const { time, r, stuck, m, key, first } = await idleSession();
  try {
    stuck.hold();
    const warmed = r.hub.warm(key).catch(() => undefined);
    await stuck.started;
    const before = r.chat.texts().length;
    await time.adjust(120_000);
    await settle();
    await warmed;
    assert.deepEqual(r.chat.texts().slice(before), [], "nothing said of a warm nobody waited on");
    assert.equal(stuck.asked, 1);
    stuck.release();
    await settle();
    assert.ok(r.claude.last().disposed, "the late process ended");
    await r.accept(reply(m, "9999.2", "world"));
    await settle();
    const now = r.claude.last();
    assert.ok(!now.disposed);
    assert.equal(now.sessionId, first.sessionId);
    assert.ok(now.prompts.at(-1)!.includes("world"), now.prompts.at(-1));
    assert.equal(stuck.asked, 1, "opened at once, not held");
  } finally {
    stuck.release();
    await r.close();
  }
});

for (const how of ["the app", "-stop"] as const) {
  const stop = async (r: Rig, m: ReturnType<typeof message>, key: string) => {
    if (how === "the app") await r.hub.stop(key);
    else await r.accept(reply(m, "9999.5", "-stop"));
  };

  test(`a stop from ${how} during stuck warm clears pending messages, says stopped once, and unblocks next reply`, async () => {
    const { r, stuck, m, key, first } = await idleSession();
    try {
      stuck.hold();
      const warmed = r.hub.warm(key).catch(() => undefined);
      await stuck.started;
      const signal = stuck.signals.at(-1);
      assert.ok(signal !== undefined && !signal.aborted, "warm open signal starts active");
      await r.accept(reply(m, "9999.1", "warm-hello"));
      assert.equal(r.store.hasPending(key), true);

      const before = r.chat.texts().length;
      await stop(r, m, key);
      await settle();
      await warmed;

      assert.equal(r.store.hasPending(key), false);
      assert.equal(r.session(key).running, false);
      assert.equal(await phaseOf(r, key), null);
      assert.deepEqual(r.chat.texts().slice(before), [STOPPED]);
      assert.equal(signal.aborted, true, "warm open aborted immediately");

      stuck.release();
      await settle();
      assert.ok(r.claude.last().disposed, "late warmed process disposed");
      const handedHello = r.claude.sessions.flatMap((s) => [...s.prompts, ...s.steers]).some((p) => p.includes("warm-hello"));
      assert.equal(handedHello, false, "cleared message must never reach runtime");

      await r.accept(reply(m, "9999.2", "world"));
      await settle();
      const now = r.claude.last();
      assert.ok(!now.disposed);
      assert.equal(now.sessionId, first.sessionId);
      const prompt = now.prompts.at(-1)!;
      assert.ok(prompt.includes("world"), prompt);
      assert.ok(!prompt.includes("warm-hello"), `cleared message stays out of later turn: ${prompt}`);
    } finally {
      stuck.release();
      await r.close();
    }
  });
}

test("stop during stuck warm with nothing pending stays silent and unblocks next reply", async () => {
  const { r, stuck, m, key, first } = await idleSession();
  try {
    stuck.hold();
    const warmed = r.hub.warm(key).catch(() => undefined);
    await stuck.started;
    const before = r.chat.texts().length;
    await r.hub.stop(key);
    await settle();
    await warmed;

    assert.deepEqual(r.chat.texts().slice(before), []);
    assert.equal(r.session(key).running, false);
    assert.equal(r.store.hasPending(key), false);
    assert.equal(await phaseOf(r, key), null);

    stuck.release();
    await settle();
    assert.ok(r.claude.last().disposed);

    await r.accept(reply(m, "9999.2", "world"));
    await settle();
    const now = r.claude.last();
    assert.ok(!now.disposed);
    assert.equal(now.sessionId, first.sessionId);
    assert.ok(now.prompts.at(-1)!.includes("world"), now.prompts.at(-1));
  } finally {
    stuck.release();
    await r.close();
  }
});

test("message arriving right after stop during warm is not swallowed", async () => {
  const { r, stuck, m, key } = await idleSession();
  try {
    stuck.hold();
    const warmed = r.hub.warm(key).catch(() => undefined);
    await stuck.started;
    await r.accept(reply(m, "9999.1", "hello"));
    assert.equal(r.store.hasPending(key), true);

    const before = r.chat.texts().length;
    const stopping = r.hub.stop(key);
    await r.accept(reply(m, "9999.2", "after-stop"));
    stuck.release();
    await Promise.all([warmed, stopping]);
    await settle();

    assert.deepEqual(r.chat.texts().slice(before), [STOPPED]);
    assert.equal(r.store.hasPending(key), false);
    const now = r.claude.last();
    assert.ok(!now.disposed);
    const prompt = now.prompts.at(-1)!;
    assert.ok(prompt.includes("after-stop"), `post-stop message must run: ${prompt}`);
    assert.ok(!prompt.includes("hello"), `pre-stop message must stay cleared: ${prompt}`);
  } finally {
    stuck.release();
    await r.close();
  }
});

test("stop clears a session queued on maxConcurrentTurns without leaking pending messages", async () => {
  const time = testClock();
  await time.adjust(1_700_000_000_000);
  const r = new Rig({ clock: time.clock, maxConcurrentTurns: 1 });
  try {
    const m1 = say("<@UBOT> active");
    const m2 = say("<@UBOT> queued");
    const [k1, k2] = [m1, m2].map((m) => sessionKey("cl", "C1", m.threadTs));
    await r.accept(m1);
    await r.accept(m2);
    await settle();
    assert.equal(r.hub.running(), 1);
    assert.equal(r.claude.count(), 1);
    assert.equal(r.store.hasPending(k2!), true);

    const before = r.chat.texts().length;
    await r.hub.stop(k2!);
    await settle();
    assert.equal(r.store.hasPending(k2!), false);
    assert.equal(r.session(k2!).running, false);
    assert.deepEqual(r.chat.texts().slice(before), [STOPPED]);

    const s1 = r.claude.sessions[0]!;
    await r.call(k1!, "chat_state", { kind: "all_done", done: "完成第一个任务" });
    s1.complete();
    await settle();
    assert.equal(r.claude.count(), 1, "stopped queued session does not open when slot frees");

    await r.accept(reply(m2, "9999.2", "after-queue-stop"));
    await settle();
    assert.equal(r.claude.count(), 2);
    const prompt = r.claude.last().prompts.at(-1)!;
    assert.ok(prompt.includes("after-queue-stop"), prompt);
    assert.ok(!prompt.includes("queued"), prompt);
  } finally {
    await r.close();
  }
});

test("stop after a failed start with no new message or queue hold keeps pending message for retry", async () => {
  const time = testClock();
  await time.adjust(1_700_000_000_000);
  const r = new Rig({ clock: time.clock });
  try {
    r.claude.refuses = "runner refused to start";
    const m = message({ text: "hello" });
    await r.accept(m);
    await settle();
    const key = sessionKey("cl", "C1", m.threadTs);
    assert.equal(r.store.hasPending(key), true);

    const before = r.chat.texts().length;
    await r.hub.stop(key);
    await settle();
    assert.deepEqual(r.chat.texts().slice(before), [], "no stopped notice when keeping failed start for retry");
    assert.equal(r.store.hasPending(key), true, "failed-start message remains pending for retry");

    r.claude.refuses = null;
    await r.accept(reply(m, "9999.2", "world"));
    await settle();
    assert.equal(r.claude.count(), 1);
    const prompt = r.claude.last().prompts.at(-1)!;
    assert.ok(prompt.includes("hello") && prompt.includes("world"), prompt);
  } finally {
    await r.close();
  }
});
