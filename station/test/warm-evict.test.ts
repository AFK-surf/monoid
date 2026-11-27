// Idle sessions' processes let go (hub.ts `evictIdle`, `idleNow`, `evictAllIdle`): taken up by the next station, a
// process keeps the time it had idled (a station updated every 12 to 20 minutes never reached warmMs' 30, 2026-11-15:
// nine idle processes held 5.3 GiB for up to six hours); one of an archived session is ended once its turn is over,
// even with work left in its background (an archived session's 679 MiB `claude -p` and its `bfs /` ran on); and the
// machine under pressure lets every idle one go at once.
import assert from "node:assert/strict";
import { test } from "node:test";
import type { BackgroundTask } from "../src/agents/runtime.ts";
import { runnerId } from "../src/agents/process.ts";
import { type ColdStorage, sessionKey } from "../src/sessions/hub.ts";
import { archive } from "../src/sessions/lifecycle.ts";
import { FakeDriver, Rig, type Setup, message, settle, testClock } from "./hub-fakes.ts";

const MIN = 60_000;

/// A session whose turn ended (it said it is done): its process idle.
async function idleSession(r: Rig, driver = r.claude) {
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  await r.call(key, "chat_state", { kind: "all_done", done: "answered" });
  driver.last().complete();
  await settle();
  return key;
}

/// The station updated: this hub hands over, the next (its own drivers, the same store and clock) takes up.
async function updated(r: Rig): Promise<FakeDriver> {
  await r.hub.handOver();
  await r.hub.shutdown();
  const claude = new FakeDriver("claude");
  r.hub = r.newHub({ chats: (id) => (id === "cl" ? r.chat : undefined), drivers: [claude, new FakeDriver("codex")], internal: false });
  await r.hub.takeUp();
  r.hub.recover();
  await settle();
  return claude;
}

function rig(o: Setup) {
  const time = testClock();
  return { time, r: new Rig({ ...o, clock: time.clock }) };
}

test("handed over every 12 minutes, idle processes within the warm limit still end once idle past warmMs", async () => {
  const { time, r } = rig({ maxWarmClaude: 2, warmMinutes: 30 });
  await idleSession(r);
  await time.adjust(5);
  await idleSession(r);
  const [oldest, newer] = r.claude.sessions.map((s) => s.sessionId);
  let claude = r.claude;
  for (let i = 0; i < 2; i++) {
    await time.adjust(12 * MIN);
    claude = await updated(r);
    assert.ok(claude.sessions.every((s) => !s.disposed), `idle ${12 * (i + 1)} minutes: within warmMs`);
  }
  // 30 minutes idle in all, 6 after the last handover: the oldest is let go then, the other is 5ms shy of warmMs.
  await time.adjust(6 * MIN - 5);
  await settle();
  const by = (id: string) => claude.sessions.find((s) => s.sessionId === id)!;
  assert.ok(by(oldest!).disposed, "the oldest idle one, past warmMs, ended at its deadline");
  assert.ok(!by(newer!).disposed, "5ms shy of warmMs: still warm");
  await time.adjust(5);
  await settle();
  assert.ok(by(newer!).disposed, "the newer idle one ended once it reached warmMs too");
  await r.close();
});

test("taken up beyond the warm limit, excess idle processes end at once without waiting for warmMs", async () => {
  const { time, r } = rig({ maxWarmClaude: 2, warmMinutes: 30 });
  await idleSession(r);
  await time.adjust(5);
  await idleSession(r);
  const [oldest, newer] = r.claude.sessions.map((s) => s.sessionId);
  await time.adjust(10 * MIN);
  await settle();
  assert.ok(r.claude.sessions.every((s) => !s.disposed), "within the limit of two and under warmMs");
  // The next station keeps one warm: the one idle longest is let go as it is taken up.
  r.edit((raw) => void (raw.maxWarmClaude = 1));
  const claude = await updated(r);
  const by = (id: string) => claude.sessions.find((s) => s.sessionId === id)!;
  assert.ok(by(oldest!).disposed, "beyond the limit: ended as it is taken up without waiting for warmMs");
  assert.ok(!by(newer!).disposed);
  await r.close();
});

test("taken up, an idle process is let go at its own deadline, counted from when it went idle", async () => {
  const { time, r } = rig({ maxWarmClaude: 1, warmMinutes: 30 });
  await idleSession(r);
  await time.adjust(20 * MIN);
  const claude = await updated(r);
  assert.ok(!claude.last().disposed, "idle 20 minutes");
  await time.adjust(10 * MIN - 1);
  await settle();
  assert.ok(!claude.last().disposed, "not idle long enough yet");
  await time.adjust(1);
  await settle();
  assert.ok(claude.last().disposed, "30 minutes idle in all: ended, not 30 more after the handover");
  await r.close();
});

test("taken up after a crash with no snapshot, an idle runner keeps the time since its session was last active", async () => {
  const { time, r } = rig({ maxWarmClaude: 1, warmMinutes: 30 });
  const key = await idleSession(r);
  const old = r.claude.last();
  await time.adjust(20 * MIN);
  // Killed (no handover file); its runner keeps the idle process, which the next station finds.
  const claude = new FakeDriver("claude");
  claude.left = { id: old.sessionId, busy: false };
  const first = r.hub;
  r.hub = r.newHub({ chats: (id) => (id === "cl" ? r.chat : undefined), drivers: [claude, new FakeDriver("codex")], internal: false, runners: [runnerId("claude", key)] });
  await first.shutdown();
  await r.hub.takeUp();
  r.hub.recover();
  await settle();
  assert.ok(!claude.last().disposed);
  await time.adjust(10 * MIN);
  await settle();
  assert.ok(claude.last().disposed, "idle since it was last active, 30 minutes ago: ended");
  await r.close();
});

test("maxWarmClaude is a hard cap: 10 idle sessions immediately evict the 6 oldest, and remaining 4 evict at warmMs", async () => {
  const { time, r } = rig({ maxWarmClaude: 4, warmMinutes: 30 });
  for (let i = 0; i < 10; i++) {
    await idleSession(r);
    await time.adjust(1);
  }
  // Only 10ms elapsed (well under 30 min), yet the 6 oldest must already be evicted.
  assert.deepEqual(
    r.claude.sessions.map((s) => s.disposed),
    [true, true, true, true, true, true, false, false, false, false],
    "oldest 6 evicted immediately, newest 4 kept warm",
  );
  // After 30 minutes idle, the remaining 4 are evicted too.
  await time.adjust(30 * MIN);
  await settle();
  assert.ok(r.claude.sessions.every((s) => s.disposed), "all remaining warm processes evicted once past warmMs");
  await r.close();
});

test("maxWarmClaude: 0 evicts idle processes immediately without waiting for warmMs", async () => {
  const { r } = rig({ maxWarmClaude: 0, warmMinutes: 30 });
  await idleSession(r);
  assert.ok(r.claude.last().disposed, "evicted immediately when maxWarmClaude is 0");
  await r.close();
});

/// Cold storage that only counts what it was asked to pack (hub `cleanArchive`).
function packs(): ColdStorage & { packed: string[] } {
  const packed: string[] = [];
  return { packed, isCold: async () => false, restore: () => {}, pack: (key) => void packed.push(key) };
}

const task: BackgroundTask = { id: "bfs-1", kind: "command", description: "bfs / -name x" };

test("archived while idle with work left in its background, its process is ended and its session packed", async () => {
  const cold = packs();
  const { r } = rig({ cold });
  const key = await idleSession(r);
  const session = r.claude.last();
  session.tasks = [task];
  await archive(r.hub, key, true);
  await r.quiet();
  assert.ok(session.disposed, "ended despite what it has in the background");
  assert.deepEqual(cold.packed, [key], "packed cold");
  assert.equal(r.hub.processState(key), "cold");
  await r.close();
});

test("archived during its turn with work left in its background, its process is ended once the turn ends, then packed", async () => {
  const cold = packs();
  const { r } = rig({ cold });
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const session = r.claude.last();
  session.tasks = [task];
  await archive(r.hub, key, true);
  await r.quiet();
  assert.ok(!session.disposed, "its turn runs on");
  assert.deepEqual(cold.packed, []);
  await r.call(key, "chat_state", { kind: "all_done", done: "answered" });
  session.complete();
  await r.quiet();
  assert.ok(session.disposed, "ended as its turn ended");
  assert.deepEqual(cold.packed, [key]);
  await r.close();
});

test("an idle process that is not archived keeps what it runs in the background through an ordinary eviction", async () => {
  const { r } = rig({});
  const key = await idleSession(r);
  const session = r.claude.last();
  session.tasks = [task];
  await r.hub.evict(key);
  await r.quiet();
  assert.ok(!session.disposed, "its background work goes on");
  await r.close();
});

test("an idle process holding background work survives maxWarmClaude and warmMs, and is evicted once its background work finishes", async () => {
  const { time, r } = rig({ maxWarmClaude: 0, warmMinutes: 30 });
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const session = r.claude.last();
  session.tasks = [task];
  await r.call(key, "chat_state", { kind: "waiting", for: "subagent", seconds: 3600 });
  session.complete();
  await settle();
  assert.ok(!session.disposed, "maxWarmClaude: 0 does not evict a process holding background work");

  // Past warmMs: deadline fires while still holding, so the process stays alive.
  await time.adjust(35 * MIN);
  await settle();
  assert.ok(!session.disposed, "warmMs does not evict while background work is still running");

  // Background work ends while idle: live `tasks: []` prompts the hub to re-evaluate eviction immediately.
  session.tasks = [];
  session.events({ type: "live", event: { kind: "tasks", tasks: [] } });
  await r.quiet();
  assert.ok(session.disposed, "evicted once its background work ended");
  await r.close();
});

test("under the machine's pressure every idle process is let go, whatever the warm limit, and a running turn is not", async () => {
  const { r } = rig({ maxWarmClaude: 4, warmMinutes: 30 });
  await idleSession(r);
  await idleSession(r);
  const busy = message();
  await r.accept(busy);
  await settle();
  const [a, b, running] = r.claude.sessions;
  assert.ok([a, b].every((s) => !s!.disposed), "within the warm limit");
  r.codex.evictIdle = async () => 1;
  assert.equal(await r.hub.evictAllIdle(), 3, "the two idle ones, and what the codex driver keeps idle");
  await r.quiet();
  assert.ok(a!.disposed && b!.disposed);
  assert.ok(!running!.disposed, "its turn goes on");
  await r.close();
});
