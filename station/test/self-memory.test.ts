// The station's watch over its own memory (ops/self-memory.ts) and what it stands on: the MoonBit programs it runs
// counted as they start and end (MbProcess.live), one that stops reading its stdin ended (STDIN_MOST), what is idle let
// go at once and nothing under way (Readers.trimIdle), and when the launcher is asked to hand over. Node's memory, the
// programs' and the machine's pressure are the test's; time is a TestClock.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { Effect, Exit, Scope } from "effect";
import { TestClock } from "effect/testing";
import type { Pressure } from "../src/jobs/admit.ts";
import { type NodeMemory, SelfMemoryGovernor, hardRssOf, softLimitOf } from "../src/ops/self-memory.ts";
import { MbProcess, MbReader, mbReaderBinary } from "../src/read/mb-reader.ts";
import { sep } from "node:path";
import { programsIn } from "../src/resources/module.ts";
import { Store, newMessage } from "../src/store/store.ts";
import { readersOf } from "./reference.ts";

const GiB = 1024 ** 3;
const MiB = 1024 ** 2;
const unix = process.platform !== "win32";
const binary = mbReaderBinary();

const scopes: Scope.Closeable[] = [];
after(async () => {
  for (const scope of scopes) await Effect.runPromise(Scope.close(scope, Exit.void)).catch(() => undefined);
});

const ended = (p: MbProcess) => new Promise<number>((resolve) => p.once("exit", resolve));

test("the programs that run are counted from their start to their end", { skip: unix ? false : "no /bin/sleep here" }, async () => {
  const before = MbProcess.live().length;
  const p = new MbProcess("/bin/sleep", ["30"]);
  const live = MbProcess.live().find((l) => l.args[0] === "30");
  assert.ok(live !== undefined, "counted as it starts");
  assert.ok(live.pid > 0);
  assert.equal(live.background, false);
  assert.equal(MbProcess.live().length, before + 1);
  await p.terminate();
  assert.equal(MbProcess.live().length, before, "not counted once it ended");
});

test("a program that stops reading its stdin is ended, not let grow the station's memory", { skip: unix ? false : "no /bin/sleep here" }, async () => {
  // (sleep never reads its stdin: what is written past the pipe's room stays in Node's buffer)
  const p = new MbProcess("/bin/sleep", ["30"], { stdinMost: 1 * MiB });
  const end = ended(p);
  p.postMessage({ small: "x" });
  assert.ok(MbProcess.live().some((l) => l.args[0] === "30"), "a small ask leaves it running");
  p.postMessage({ big: "x".repeat(2 * MiB) });
  assert.equal(await end, 1, "ended by a signal");
  assert.ok(!MbProcess.live().some((l) => l.args[0] === "30"));
  // (what is posted after is dropped, not written to a process gone)
  p.postMessage({ after: true });
});

test("trimming lets idle readers go and never a read under way", { skip: binary === null ? "the MoonBit program is not built here" : false }, async () => {
  const data = mkdtempSync(join(tmpdir(), "self-memory-"));
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const thread = store.openThread("ember", "CHAT", "t", "T", null).id;
  for (let i = 0; i < 50; i++) store.insertMessage({ ...newMessage(thread, String(i + 1), "person", "a@x", `message ${i}`), at: i } as ReturnType<typeof newMessage>);
  const readers = readersOf(data, binary);
  try {
    const before = MbProcess.live().length;
    let trims = 0;
    let done = false;
    const read = readers.read("latestMessages", { thread, limit: 20 }, "en").finally(() => (done = true));
    // Trimmed at every turn while the read is under way: it is answered all the same.
    while (!done) {
      trims += readers.trimIdle();
      await new Promise((resolve) => setImmediate(resolve));
    }
    const said = JSON.parse(await read);
    assert.ok(JSON.stringify(said).includes("message 49"), "the read answered whole");
    assert.equal(trims, 0, "nothing was idle while the read was under way");
    const running = MbProcess.live().length;
    assert.ok(running > before, "the read's reader still runs, idle");
    const gone = MbProcess.live().map((l) => l.pid);
    assert.ok(readers.trimIdle() >= 1, "the idle reader let go");
    assert.equal(readers.trimIdle(), 0, "nothing left to let go");
    // (each trimmed reader ends; asked again, a new one answers)
    const again = JSON.parse(await readers.read("latestMessages", { thread, limit: 5 }, "en"));
    assert.ok(JSON.stringify(again).includes("message 49"));
    assert.ok(MbProcess.live().some((l) => !gone.includes(l.pid)), "a new reader started for the read after");
  } finally {
    readers.close();
    store.close();
    rmSync(data, { recursive: true, force: true });
  }
});

test("asks written faster than the reader reads are all answered, in order, its queue of stdin bounded", { skip: binary === null ? "the MoonBit program is not built here" : false }, async () => {
  const data = mkdtempSync(join(tmpdir(), "self-memory-stdin-"));
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const thread = store.openThread("ember", "CHAT", "t", "T", null).id;
  store.insertMessage({ ...newMessage(thread, "1", "person", "a@x", "only"), at: 1 } as ReturnType<typeof newMessage>);
  const reader = new MbReader(binary!, data);
  try {
    // Some 48 MiB written at once, three times the program's own queue (host.c STDIN_MOST): read_input waits for
    // room, the rest waits in the pipe and here, and nothing is lost or ends.
    const n = 400;
    const pad = "p".repeat(120 * 1024);
    const answered: number[] = [];
    const all = new Promise<void>((resolve, reject) => {
      reader.on("message", (a: { id?: number; error?: string }) => {
        if (typeof a.id !== "number") return;
        if (a.error !== undefined) return reject(new Error(a.error));
        answered.push(a.id);
        if (answered.length === n) resolve();
      });
      reader.on("exit", (code: number) => reject(new Error(`the reader ended (${code})`)));
    });
    for (let id = 0; id < n; id++) reader.postMessage({ id, op: "latestMessages", args: { thread, limit: 1, pad }, lang: "en", names: [], processes: [], clientKeys: [] });
    await all;
    assert.deepEqual(answered, [...Array(n).keys()]);
    assert.ok(MbProcess.live().some((l) => l.args.includes(data) && l.args.includes(sep)), "still running");
  } finally {
    await reader.terminate();
    store.close();
    rmSync(data, { recursive: true, force: true });
  }
});

test("the programs' memory is theirs and all under them, once each", () => {
  const table = [
    { pid: 1, ppid: 0, pgid: 1, bytes: 9 * GiB, command: "node" },
    { pid: 10, ppid: 1, pgid: 10, bytes: 100 * MiB, command: "stillfail-reader" },
    { pid: 11, ppid: 10, pgid: 10, bytes: 50 * MiB, command: "helper" },
    { pid: 20, ppid: 1, pgid: 20, bytes: 200 * MiB, command: "stillfail-reader" },
    { pid: 30, ppid: 1, pgid: 30, bytes: 7 * GiB, command: "cargo" },
  ];
  assert.deepEqual(programsIn(table, [10, 20, 10]), { bytes: 350 * MiB, count: 3 });
  assert.deepEqual(programsIn(table, [99]), { bytes: 0, count: 1 });
  assert.deepEqual(programsIn(null, [10]), { bytes: 0, count: 1 });
});

test("the limits follow the machine's memory, within their bounds", () => {
  assert.equal(softLimitOf(4 * GiB), 2 * GiB);
  assert.equal(softLimitOf(16 * GiB), Math.floor(16 * GiB * 0.2));
  assert.equal(softLimitOf(128 * GiB), 6 * GiB);
  assert.equal(hardRssOf(8 * GiB), 3 * GiB);
  assert.equal(hardRssOf(16 * GiB), Math.floor(16 * GiB * 0.3));
  assert.equal(hardRssOf(128 * GiB), 8 * GiB);
});

function rig(o: { launcher: boolean }) {
  const scope = Effect.runSync(Scope.make());
  scopes.push(scope);
  const clock = Effect.runSync(Scope.provide(TestClock.make(), scope));
  const state = { node: { rss: 500 * MiB, heapUsed: 200 * MiB, external: 0, arrayBuffers: 0 } as NodeMemory, children: 300 * MiB, pressure: "normal" as Pressure | null };
  const calls = { trims: 0, handovers: 0, asked: 0 };
  const governor = new SelfMemoryGovernor({
    clock,
    totalBytes: 32 * GiB,
    startedAt: clock.currentTimeMillisUnsafe(),
    memory: () => state.node,
    children: async () => ({ bytes: state.children, count: 4 }),
    pressure: async () => state.pressure,
    trimIdle: () => (calls.trims++, 2),
    handover: async () => {
      calls.asked++;
      return o.launcher ? async () => void calls.handovers++ : null;
    },
    softBytes: 4 * GiB,
    hardRssBytes: 6 * GiB,
    hardHeapBytes: 2.5 * GiB,
  });
  const at = (ms: number) => Effect.runPromise(clock.adjust(`${ms} millis`));
  return { governor, state, calls, at };
}

test("a station within its limits does nothing", async () => {
  const r = rig({ launcher: true });
  for (let i = 0; i < 5; i++) assert.deepEqual(await r.governor.sample(), { trimmed: null, handover: null });
  assert.deepEqual(r.calls, { trims: 0, handovers: 0, asked: 0 });
});

test("over the soft limit or under the machine's pressure, what is idle is let go, at most once a minute", async () => {
  const r = rig({ launcher: true });
  // The whole (Node's and its programs') past the soft limit, Node's own well within its hard one.
  r.state.node = { ...r.state.node, rss: 3 * GiB };
  r.state.children = 1.5 * GiB;
  assert.deepEqual(await r.governor.sample(), { trimmed: 2, handover: null });
  await r.at(30_000);
  assert.deepEqual(await r.governor.sample(), { trimmed: null, handover: null }, "not again within the minute");
  await r.at(30_000);
  assert.deepEqual(await r.governor.sample(), { trimmed: 2, handover: null });
  // Within its limits, but the machine under pressure.
  r.state.node = { ...r.state.node, rss: 500 * MiB };
  r.state.children = 0;
  r.state.pressure = "high";
  await r.at(60_000);
  assert.deepEqual(await r.governor.sample(), { trimmed: 2, handover: null });
  assert.equal(r.calls.asked, 0, "never a handover for the soft limit");
});

test("one moment over the hard limit is no leak: nothing is handed over", async () => {
  const r = rig({ launcher: true });
  await r.at(20 * 60_000);
  for (let i = 0; i < 6; i++) {
    // (a transfer's or a pack's moment: over every other sample)
    r.state.node = { ...r.state.node, rss: i % 2 === 0 ? 7 * GiB : 1 * GiB };
    const v = await r.governor.sample();
    assert.equal(v.handover, null);
    await r.at(30_000);
  }
  assert.equal(r.calls.asked, 0);
});

test("held over the hard limit after the start's grace, the launcher is asked to hand over, once", async () => {
  const r = rig({ launcher: true });
  r.state.node = { ...r.state.node, heapUsed: 3 * GiB };
  // Within the first ten minutes: not yet, however long it is held.
  for (let i = 0; i < 4; i++) {
    assert.equal((await r.governor.sample()).handover, null);
    await r.at(30_000);
  }
  await r.at(10 * 60_000);
  assert.equal((await r.governor.sample()).handover, "asked", "held three samples and past the grace");
  assert.equal(r.calls.handovers, 1);
  for (let i = 0; i < 6; i++) {
    await r.at(30_000);
    assert.equal((await r.governor.sample()).handover, null, "asked once");
  }
  assert.equal(r.calls.handovers, 1);
});

test("with no launcher it is only said and what is idle let go: the process never ends itself", async () => {
  const r = rig({ launcher: false });
  const exit = process.exit;
  let exited = false;
  process.exit = ((() => { exited = true; }) as unknown) as typeof process.exit;
  try {
    r.state.node = { ...r.state.node, rss: 7 * GiB };
    await r.at(11 * 60_000);
    assert.equal((await r.governor.sample()).handover, null);
    await r.at(30_000);
    assert.equal((await r.governor.sample()).handover, null);
    await r.at(30_000);
    const v = await r.governor.sample();
    assert.equal(v.handover, "none");
    assert.ok(v.trimmed !== null && v.trimmed > 0);
    assert.equal(r.calls.handovers, 0);
    assert.equal(exited, false);
  } finally {
    process.exit = exit;
  }
});
