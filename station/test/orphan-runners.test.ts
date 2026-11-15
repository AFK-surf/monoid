// What a station left running that nobody takes up is ended (hub.ts `takeUp`, `endOrphans`, `endOrphan`): a session
// handed over whose chat is gone since, a runner a crash left of a session gone or moved, an app-server none of whose
// sessions had a turn. What is taken up, a person's terminal, and what starts after the runners were looked at are not
// (2026-11-15: a `claude -p` of 109 MB idle 35 hours on a station, nothing ever asking for it again).
import assert from "node:assert/strict";
import { test } from "node:test";
import { runnerId } from "../src/agents/process.ts";
import { RUNNER_LEFT_MS, type RunnerInfo } from "../src/agents/runner.ts";
import { sessionKey } from "../src/sessions/hub.ts";
import { FakeDriver, Rig, message, settle } from "./hub-fakes.ts";

/// A driver that says which runners it holds: those of its sessions not ended.
function owning(kind: "claude" | "codex"): FakeDriver {
  const driver = new FakeDriver(kind);
  driver.ownedRunners = () => new Set(driver.sessions.filter((s) => !s.disposed).map((s) => runnerId(kind, s.options.key)));
  return driver;
}

test("a session handed over whose chat is gone, and runners nobody takes up, are ended; what is taken up is not", async () => {
  const first = new Rig();
  const kept = message();
  const gone = message();
  await first.accept(kept);
  await first.accept(gone);
  await settle();
  const keptKey = sessionKey("cl", "C1", kept.threadTs);
  const goneKey = sessionKey("cl", "C1", gone.threadTs);
  await first.hub.handOver();
  // Deleted (or moved to another station) between the handover and the taking up.
  first.store.deleteSession(goneKey);
  const claude = owning("claude");
  const codex = owning("codex");
  const ended: string[] = [];
  const runners = [runnerId("claude", keptKey), runnerId("claude", goneKey), runnerId("claude", "chat:moved:away"), runnerId("codex", "cc"), "term-1"];
  const hub = first.newHub({ chats: (id) => (id === "cl" ? first.chat : undefined), drivers: [claude, codex], internal: false, runners, endRunner: async (info) => void ended.push(info.id) });
  await hub.takeUp();
  await hub.orphansEnded;
  assert.equal(claude.sessions.length, 1, "the one whose chat is there taken up");
  assert.equal(claude.last().options.key, keptKey);
  assert.deepEqual(ended.sort(), [runnerId("claude", goneKey), runnerId("claude", "chat:moved:away"), runnerId("codex", "cc")].sort());
  await hub.shutdown();
  await first.close();
});

test("a driver that does not say which runners it holds keeps every one of its runtime's", async () => {
  const first = new Rig();
  const ended: string[] = [];
  const runners = [runnerId("claude", "chat:a:b"), runnerId("codex", "cc"), runnerId("dsh", "chat:c:d")];
  const hub = first.newHub({ chats: () => undefined, drivers: [new FakeDriver("claude"), owning("codex")], internal: false, runners, endRunner: async (info) => void ended.push(info.id) });
  await hub.takeUp();
  await hub.orphansEnded;
  assert.deepEqual(ended.sort(), [runnerId("codex", "cc"), runnerId("dsh", "chat:c:d")].sort(), "none of claude's; codex's and those of a runtime with no driver");
  await hub.shutdown();
  await first.close();
});

test("a runner nobody holds found later is ended once it has run a while, only while the drivers hold all that goes on", async () => {
  const first = new Rig();
  const m = message();
  await first.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  await first.hub.handOver();
  const claude = owning("claude");
  const ended: string[] = [];
  const hub = first.newHub({ chats: (id) => (id === "cl" ? first.chat : undefined), drivers: [claude, owning("codex")], internal: false, runners: [runnerId("claude", key)], endRunner: async (info) => void ended.push(info.id) });
  const now = 10 * RUNNER_LEFT_MS;
  const old = (id: string) => ({ id, startedAt: now - RUNNER_LEFT_MS }) as RunnerInfo;
  assert.equal(await hub.endOrphan(old("claude-left"), now), false, "before what the station before left is taken up");
  await hub.takeUp();
  await hub.orphansEnded;
  assert.deepEqual(ended, [], "the one there taken up");
  assert.equal(await hub.endOrphan(old(runnerId("claude", key)), now), false, "taken up: held");
  assert.equal(await hub.endOrphan({ id: "claude-new", startedAt: now - RUNNER_LEFT_MS + 1 } as RunnerInfo, now), false, "just started: its driver may not hold it yet");
  assert.equal(await hub.endOrphan(old("term-2"), now), false, "a person's terminal");
  assert.equal(await hub.endOrphan(old("claude-left"), now), true);
  assert.deepEqual(ended, ["claude-left"]);
  await hub.handOver();
  assert.equal(await hub.endOrphan(old("claude-other"), now), false, "handed over: what it let go is the next station's");
  assert.deepEqual(ended, ["claude-left"]);
  await hub.shutdown();
  await first.close();
});
