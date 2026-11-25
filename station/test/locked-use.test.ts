// Locked use of a Mac (screens/locked-use.ts): who may have its locked screen unlocked (the owner's chat, message and
// stations; never a workspace's admins), the switch's expiry, and the leases: the Helper's `lockuse.begin` connection
// opened for the first and held until the last ends (released, idle, at its term or cap), the Helper's refusals told,
// its closing ending them all. Time is the test's own.
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { test } from "node:test";
import {
  type Asker,
  CAP_MS,
  type Gate,
  type LockLine,
  Leases,
  SWITCH_MS,
  TERM_MS,
  UnlockRefused,
  askerOf,
  mayUnlock,
  maySwitch,
  refusedText,
  switchOn,
  switchedOn,
} from "../src/screens/locked-use.ts";

const OWNER = "sub-owner";
const bound: Gate = { enabled: true, status: { locked: true, installed: true, bound: true, uid: 501, binding: { sub: OWNER, stations: ["st-trusted"] } } };
const own: Asker = { kind: "local", chat: "stillfail", createdBySub: OWNER, senderSub: OWNER, openedBy: null };

test("the owner's own still.fail chat, on the owner's message, may have it unlocked", () => {
  assert.deepEqual(mayUnlock("computer", own, bound), { ok: true });
  assert.deepEqual(mayUnlock("task", own, bound), { ok: true });
  assert.deepEqual(mayUnlock("job", own, bound), { ok: true });
});

test("off, not installed, not bound: refused, whoever asks", () => {
  assert.deepEqual(mayUnlock("computer", own, { ...bound, enabled: false }), { ok: false, why: "off" });
  assert.deepEqual(mayUnlock("computer", own, { enabled: true, status: null }), { ok: false, why: "not-installed" });
  assert.deepEqual(mayUnlock("computer", own, { enabled: true, status: { locked: true, installed: false, bound: false } }), { ok: false, why: "not-installed" });
  assert.deepEqual(mayUnlock("computer", own, { enabled: true, status: { locked: true, installed: true, bound: false } }), { ok: false, why: "not-bound" });
  assert.deepEqual(mayUnlock("other", own, bound), { ok: false, why: "source" });
});

test("another's chat, another's message, Slack and the like, a chat opened by an unbound station: refused", () => {
  assert.deepEqual(mayUnlock("computer", { ...own, createdBySub: "sub-admin" }, bound), { ok: false, why: "creator" });
  assert.deepEqual(mayUnlock("computer", { ...own, createdBySub: null }, bound), { ok: false, why: "creator" });
  assert.deepEqual(mayUnlock("computer", { ...own, senderSub: "sub-member" }, bound), { ok: false, why: "sender" });
  assert.deepEqual(mayUnlock("computer", { ...own, senderSub: null }, bound), { ok: false, why: "sender" });
  for (const chat of ["slack", "feishu", "comma", "group", "other"] as const) assert.deepEqual(mayUnlock("computer", { ...own, chat }, bound), { ok: false, why: "chat" });
  assert.deepEqual(mayUnlock("computer", { ...own, openedBy: "st-other" }, bound), { ok: false, why: "opener" });
  assert.deepEqual(mayUnlock("computer", { ...own, openedBy: "st-trusted" }, bound), { ok: true });
});

test("a remote task needs its station bound and the owner as its requester", () => {
  assert.deepEqual(mayUnlock("task", { kind: "remote", station: "st-trusted", requesterSub: OWNER }, bound), { ok: true });
  assert.deepEqual(mayUnlock("task", { kind: "remote", station: "st-other", requesterSub: OWNER }, bound), { ok: false, why: "station" });
  assert.deepEqual(mayUnlock("task", { kind: "remote", station: "st-trusted", requesterSub: "sub-admin" }, bound), { ok: false, why: "requester" });
  assert.deepEqual(mayUnlock("task", { kind: "remote", station: "st-trusted", requesterSub: null }, bound), { ok: false, why: "requester" });
});

test("a session's asker from its key and row", () => {
  assert.deepEqual(askerOf("remote:x:st-trusted:k", { connect: null, createdBySub: OWNER, senderSub: OWNER, openedBy: null }), { kind: "remote", station: "st-trusted", requesterSub: null });
  assert.deepEqual(askerOf("chat:c-1", { connect: "chat", createdBySub: OWNER, senderSub: OWNER, openedBy: null }), own);
  assert.equal((askerOf("slack:T:C:1", { connect: "slack-1", createdBySub: OWNER, senderSub: OWNER, openedBy: null }) as { chat: string }).chat, "other");
});

test("the switch: only the bound account changes it; on for 24 h, then off", () => {
  assert.equal(maySwitch(bound.status, OWNER), true);
  assert.equal(maySwitch(bound.status, "sub-admin"), false);
  assert.equal(maySwitch(bound.status, null), false);
  assert.equal(maySwitch({ locked: false, installed: true, bound: false }, OWNER), false);
  const kept = switchedOn(1_000);
  assert.equal(kept.until, 1_000 + SWITCH_MS);
  assert.equal(switchOn(kept, 1_000 + SWITCH_MS - 1), true);
  assert.equal(switchOn(kept, 1_000 + SWITCH_MS), false);
  assert.equal(switchOn(undefined, 0), false);
  assert.equal(switchOn(true, 0), false);
  assert.equal(switchOn({ until: "later" }, 0), false);
});

test("every refusal says to ask the owner", () => {
  for (const why of ["off", "not-installed", "not-bound", "source", "chat", "creator", "sender", "opener", "station", "requester"] as const)
    assert.match(refusedText(why), /locked.*Ask its owner/s);
});

class Clock {
  t = 0;
  #due: { at: number; f: () => void; live: boolean }[] = [];
  now() {
    return this.t;
  }
  later(ms: number, f: () => void) {
    const x = { at: this.t + ms, f, live: true };
    this.#due.push(x);
    return () => void (x.live = false);
  }
  advance(ms: number) {
    const end = this.t + ms;
    for (;;) {
      const next = this.#due.filter((x) => x.live && x.at <= end).sort((a, b) => a.at - b.at)[0];
      if (next === undefined) break;
      this.t = next.at;
      next.live = false;
      next.f();
    }
    this.t = end;
  }
}

/// A connection that, as a socket does, gives its data once something reads it.
class FakeLine extends EventEmitter implements LockLine {
  destroyed = false;
  #pending: string[] = [];
  setEncoding() {
    return this;
  }
  answer(a: unknown) {
    this.#pending.push(`${JSON.stringify(a)}\n`);
    this.#flow();
  }
  override on(event: string, listener: (...args: any[]) => void) {
    super.on(event, listener);
    if (event === "data") this.#flow();
    return this;
  }
  #flow() {
    if (this.listenerCount("data") === 0) return;
    for (const chunk of this.#pending.splice(0)) this.emit("data", chunk);
  }
  destroy() {
    if (this.destroyed) return;
    this.destroyed = true;
    this.emit("close");
  }
}

/// A Helper whose `lockuse.begin` answers what the test says (ok by default).
function helper(answer: unknown = { ok: true }) {
  const lines: { op: Record<string, unknown>; line: FakeLine }[] = [];
  return {
    lines,
    async connect(op: Record<string, unknown>) {
      const line = new FakeLine();
      lines.push({ op, line });
      line.answer(answer);
      return line;
    },
  };
}

test("the first lease opens lockuse.begin and holds it; the last to end closes it", async () => {
  const h = helper();
  const clock = new Clock();
  const leases = new Leases({ helper: h, clock });
  let told = 0;
  leases.onChange(() => told++);
  await Promise.all([leases.take("a", "agent: Chat A", null), leases.take("b", "agent: Chat B", null)]);
  assert.equal(h.lines.length, 1);
  assert.equal(h.lines[0]!.op.op, "lockuse.begin");
  assert.equal(h.lines[0]!.op.reason, "agent: Chat A");
  assert.equal(leases.held(), true);
  assert.equal(told, 1);
  leases.release("a");
  assert.equal(h.lines[0]!.line.destroyed, false);
  leases.release("b");
  assert.equal(h.lines[0]!.line.destroyed, true);
  assert.equal(leases.held(), false);
  assert.equal(told, 2);
  // (taken again: a new begin, through the Helper's checks anew)
  await leases.take("c", "agent: Chat C", null);
  assert.equal(h.lines.length, 2);
});

test("a lease ends when idle, used again it lives on", async () => {
  const h = helper();
  const clock = new Clock();
  const leases = new Leases({ helper: h, clock });
  await leases.take("v", "view", 60_000);
  clock.advance(59_999);
  leases.touch("v");
  clock.advance(59_999);
  assert.equal(leases.holds("v"), true);
  clock.advance(1);
  assert.equal(leases.holds("v"), false);
  assert.equal(h.lines[0]!.line.destroyed, true);
});

test("a lease ends at its term unless used, and at its cap however used", async () => {
  const clock = new Clock();
  const leases = new Leases({ helper: helper(), clock });
  await leases.take("t", "task", null);
  clock.advance(TERM_MS - 1);
  assert.equal(leases.holds("t"), true);
  clock.advance(1);
  assert.equal(leases.holds("t"), false);

  await leases.take("t", "task", null);
  const start = clock.t;
  while (clock.t - start < CAP_MS - TERM_MS / 2) {
    clock.advance(TERM_MS / 2);
    leases.touch("t");
  }
  assert.equal(leases.holds("t"), true);
  clock.advance(start + CAP_MS - clock.t - 1);
  assert.equal(leases.holds("t"), true);
  clock.advance(1);
  assert.equal(leases.holds("t"), false);
});

test("the Helper's refusal is told with what to do; nothing is held", async () => {
  const h = helper({ error: "someone used it", code: "cooldown" });
  const leases = new Leases({ helper: h, clock: new Clock() });
  await assert.rejects(leases.take("a", "x", null), (e: unknown) => e instanceof UnlockRefused && e.code === "cooldown" && /wait a minute/.test(e.message));
  assert.equal(leases.held(), false);
  assert.equal(h.lines[0]!.line.destroyed, true);
  const suppressed = new Leases({ helper: helper({ error: "input", code: "suppressed" }), clock: new Clock() });
  await assert.rejects(suppressed.take("a", "x", null), /unlocks it by hand/);
});

test("the Helper closing the connection ends every lease", async () => {
  const h = helper();
  const leases = new Leases({ helper: h, clock: new Clock() });
  let told = 0;
  leases.onChange(() => told++);
  await leases.take("a", "x", null);
  await leases.take("b", "x", null);
  h.lines[0]!.line.destroy();
  assert.equal(leases.held(), false);
  assert.equal(told, 2);
});

test("a Helper that cannot be reached refuses as failed", async () => {
  const leases = new Leases({ helper: { connect: () => Promise.reject(new Error("no socket")) }, clock: new Clock() });
  await assert.rejects(leases.take("a", "x", null), (e: unknown) => e instanceof UnlockRefused && e.code === "failed" && /no socket/.test(e.message));
});
