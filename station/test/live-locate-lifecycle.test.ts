import assert from "node:assert/strict";
import { appendFileSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { ChainTail } from "./reference/tail.ts";
import { LiveHub, type LiveMessage, type Located } from "../src/sessions/live.ts";
import { given, settle, testClock } from "./hub-fakes.ts";

const line = (text: string, id: string) => `${JSON.stringify({ type: "assistant", timestamp: "2026-09-26T00:00:00Z", message: { id, content: [{ type: "text", text }] } })}\n`;
const deferred = () => {
  let resolve!: (at: Located) => void;
  const promise = new Promise<Located>((done) => { resolve = done; });
  return { promise, resolve };
};
/// A fake's calls as they come, each waited for by its number: the hub asks from the sessions' program, so how many
/// turns of the loop a call takes to arrive is the machine's (station/AGENTS.md, `settle`).
const calls = <T>() => {
  const got: T[] = [];
  const waiting = new Map<number, (t: T) => void>();
  return {
    got,
    push(t: T) { got.push(t); waiting.get(got.length - 1)?.(t); },
    nth: (n: number): Promise<T> => n < got.length ? Promise.resolve(got[n]!) : new Promise((done) => waiting.set(n, done)),
  };
};
const aborted = (signal: AbortSignal) => new Promise<void>((done) => {
  if (signal.aborted) done(); else signal.addEventListener("abort", () => done(), { once: true });
});

test("subscribers share a pending location and get the transcript before events and the turn ending", async () => {
  const dir = mkdtempSync(join(tmpdir(), "live-locate-lifecycle-")), path = join(dir, "t.jsonl");
  writeFileSync(path, line("one", "m1"));
  const hub = new LiveHub(() => { throw new Error("synchronous location"); });
  const pending = deferred();
  const asked = calls<null>();
  hub.locateAsync = () => { asked.push(null); return pending.promise; };
  const first: LiveMessage[] = [], second: LiveMessage[] = [];
  try {
    hub.subscribe("s", 0, null, (m) => first.push(m));
    hub.subscribe("s", 0, null, (m) => second.push(m));
    hub.event("s", { kind: "start", id: "x", step: "text" });
    appendFileSync(path, line("two", "m2"));
    hub.turnEnded("s");
    await given(asked.nth(0), "the shared location is asked for");
    await settle();
    assert.equal(asked.got.length, 1);
    assert.deepEqual(first, []);
    pending.resolve({ runtime: "claude", paths: [path], current: true });
    await settle();
    await hub.idle();
    for (const got of [first, second]) {
      const timeline = got.find((m): m is Extract<LiveMessage, { type: "timeline" }> => m.type === "timeline")!;
      assert.deepEqual(timeline.entries.map((e) => e.text), ["one", "two"]);
      assert.ok(got.findIndex((m) => m.type === "timeline") < got.findIndex((m) => m.type === "clear"));
      assert.ok(got.findIndex((m) => m.type === "step") < got.findIndex((m) => m.type === "clear"));
    }
  } finally { await hub.close(); rmSync(dir, { recursive: true, force: true }); }
});

test("unsubscribing during location preserves handover state, while deleting a session discards it", async () => {
  const dir = mkdtempSync(join(tmpdir(), "live-locate-lifecycle-")), path = join(dir, "t.jsonl");
  writeFileSync(path, line("one", "m1"));
  const tail = new ChainTail("claude", [path], null, false);
  tail.read();
  const states = tail.snapshot();
  const hub = new LiveHub(() => { throw new Error("synchronous location"); });
  const requests = calls<{ signal: AbortSignal; pending: ReturnType<typeof deferred> }>();
  hub.locateAsync = (_key, signal) => {
    const pending = deferred();
    requests.push({ signal, pending });
    return pending.promise; // Deliberately finish even if cancelled, as an already delivered response can.
  };
  let stateReads = 0;
  hub.history = { state: async () => { stateReads++; return null; }, page: async () => ({ start: 0, end: 0, entries: [] }) };
  try {
    const abandoned: LiveMessage[] = [];
    const first = hub.subscribe("s", 1, null, (m) => abandoned.push(m));
    const one = await given(requests.nth(0), "the first watch asks for the location");
    hub.takeTails([{ key: "s", states }]);
    hub.unsubscribe("s", first);
    await given(aborted(one.signal), "unsubscribing calls off the location");
    assert.deepEqual((await hub.carried()).tails, [{ key: "s", states }]);
    const joined: LiveMessage[] = [];
    hub.subscribe("s", 1, null, (m) => joined.push(m));
    const two = await given(requests.nth(1), "the next watch asks for the location again");
    one.pending.resolve({ runtime: "claude", paths: [path], current: true });
    two.pending.resolve({ runtime: "claude", paths: [path], current: true });
    await settle();
    await hub.idle();
    assert.deepEqual(abandoned, []);
    assert.equal(stateReads, 0, "the next watch resumes the carried reading");
    assert.equal(joined[0]?.type, "timeline");
    hub.forget("s");
    assert.deepEqual((await hub.carried()).tails, []);

    hub.subscribe("gone", 0, null, () => {});
    const three = await given(requests.nth(2), "a watch of the session to be deleted asks for its location");
    hub.takeTails([{ key: "gone", states }]);
    hub.forget("gone");
    await given(aborted(three.signal), "deleting the session calls off its location");
    three.pending.resolve({ runtime: "claude", paths: [path], current: true });
    await settle();
    await hub.idle();
    assert.deepEqual((await hub.carried()).tails, [], "a late answer cannot restore a deleted session's state");
  } finally { await hub.close(); rmSync(dir, { recursive: true, force: true }); }
});

test("a newly written transcript is announced even when its location takes longer than the read timer", async () => {
  for (const withReader of [false, true]) {
    const dir = mkdtempSync(join(tmpdir(), "live-locate-lifecycle-")), path = join(dir, "t.jsonl");
    const time = testClock();
    const hub = new LiveHub(() => { throw new Error("synchronous location"); }, time.clock);
    const requests = calls<ReturnType<typeof deferred>>();
    hub.locateAsync = () => { const pending = deferred(); requests.push(pending); return pending.promise; };
    if (withReader) hub.history = { state: async () => null, page: async () => ({ start: 0, end: 0, entries: [] }) };
    const got: LiveMessage[] = [];
    try {
      hub.subscribe("s", 0, null, (m) => got.push(m));
      (await given(requests.nth(0), "the watch asks for the location")).resolve(null);
      await settle();
      assert.equal(got.some((m) => m.type === "timeline"), false);
      writeFileSync(path, line("one", "m1"));
      hub.event("s", { kind: "start", id: "x", step: "text" });
      hub.event("s", { kind: "end", id: "x" });
      const again = await given(requests.nth(1), `the turn's end asks for the location again with reader=${withReader}`);
      await time.adjust(40);
      await settle();
      again.resolve({ runtime: "claude", paths: [path], current: true });
      await settle();
      await hub.idle();
      await time.adjust(40);
      await settle();
      await hub.idle();
      const timeline = got.find((m): m is Extract<LiveMessage, { type: "timeline" }> => m.type === "timeline");
      assert.ok(timeline, `the new transcript is announced with reader=${withReader}`);
      assert.equal(timeline.start, 1);
    } finally { await hub.close(); rmSync(dir, { recursive: true, force: true }); }
  }
});
