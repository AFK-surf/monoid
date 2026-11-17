// A station's terminals from the core (src/terminals.ts): what the calls take, the station's frames read as they come
// in pieces, and control choices while a view opens. The view's stream end to end is the station's tests'
// (station/test/terminals.test.ts) and the app's.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Deferred, Effect, Queue } from "effect";
import { FrameReader, KIND, drainFrames, frame, parseTerminal } from "../src/terminals.ts";
import { HostWire, type StationWire, type TerminalAsk } from "../src/station/wire.ts";
import type { FakeHost } from "../src/testing.ts";
import { call } from "./helpers.ts";
import { base, started } from "./station-fixture.ts";

const station = "w1/s1";

function terminalWire() {
  const opens: { path: string; ask: TerminalAsk; got: { kind: number; value: unknown }[]; ready(): void; state(value: Record<string, unknown>): void; end(): void }[] = [];
  const make = (host: FakeHost): StationWire => {
    const plain = new HostWire(host);
    return {
      request: (s, head, body) => plain.request(s, head, body),
      terminal: (_station, head, ask) => Effect.gen(function* () {
        const ready = Deferred.makeUnsafe<void>();
        const queue = yield* Queue.unbounded<Uint8Array | null>();
        const got: { kind: number; value: unknown }[] = [];
        opens.push({
          path: head.path, ask, got,
          ready: () => { Deferred.doneUnsafe(ready, Effect.void); },
          state: (value) => { Queue.offerUnsafe(queue, frame(KIND.state, Buffer.from(JSON.stringify(value)))); },
          end: () => { Queue.offerUnsafe(queue, null); },
        });
        yield* Deferred.await(ready);
        const reader = new FrameReader();
        return {
          reply: { status: 200, headers: [] as [string, string][], body: { take: Queue.take(queue) }, via: null },
          send: {
            write: (bytes: Uint8Array) => Effect.sync(() => {
              reader.push(bytes);
              for (const f of drainFrames(reader)) got.push({ kind: f.kind, value: JSON.parse(Buffer.from(f.payload).toString()) });
            }),
            finish: () => {},
          },
        };
      }),
    };
  };
  return { opens, make };
}

test("taking control while the terminal opens reaches the station once it answers", async (t) => {
  for (const inband of [true, false]) await t.test(inband ? "in-band control" : "an older station", async () => {
    const wire = terminalWire();
    const { host, core } = await started(base(), 0, wire.make);
    try {
      const ui = core.connect();
      call(core, ui, 1, "terminal.view", { station: "ws/st", terminal: "term-1", view: "v1", cols: 80, rows: 24, control: false });
      await host.settle();
      assert.equal(wire.opens.length, 1);
      assert.equal(wire.opens[0]!.ask.control, false);
      call(core, ui, 2, "terminal.take", { view: "v1" });
      await host.settle();
      wire.opens[0]!.ready();
      wire.opens[0]!.state({ id: "term-1", types: false, cols: 80, rows: 24, inband });
      await host.settle();
      if (inband) {
        assert.equal(wire.opens.length, 1);
        assert.deepEqual(wire.opens[0]!.got, [{ kind: KIND.control, value: { control: true, taken: true, cols: 80, rows: 24 } }]);
        wire.opens[0]!.state({ id: "term-1", types: true, cols: 80, rows: 24, inband });
        await host.settle();
        assert.equal(wire.opens[0]!.got.length, 1, "the choice is not sent again on later states");
        call(core, ui, 3, "terminal.take", { view: "v1", control: false });
        await host.settle();
        assert.deepEqual(wire.opens[0]!.got[1], { kind: KIND.control, value: { control: false, taken: false, cols: 80, rows: 24 } });
        wire.opens[0]!.state({ id: "term-1", types: false, cols: 80, rows: 24, inband });
        await host.settle();
        assert.equal(wire.opens[0]!.got.length, 2, "a live control switch is sent only once too");
        assert.equal(wire.opens.length, 1);
      } else {
        assert.equal(wire.opens.length, 2);
        assert.equal(wire.opens[1]!.path, "/admin/api/terminals/term-1/view");
        assert.deepEqual(wire.opens[1]!.ask, { cols: 80, rows: 24, control: true, taken: true });
        wire.opens[1]!.ready();
        wire.opens[1]!.state({ id: "term-1", types: true, cols: 80, rows: 24 });
        await host.settle();
        assert.equal(wire.opens.length, 2, "the request carried the choice already");
      }
    } finally {
      core.close();
    }
  });
});

test("only the latest control choice made while opening is sent, at the latest size", async () => {
  const wire = terminalWire();
  const { host, core } = await started(base(), 0, wire.make);
  try {
    const ui = core.connect();
    call(core, ui, 1, "terminal.view", { station: "ws/st", terminal: "term-1", view: "v1", cols: 80, rows: 24 });
    await host.settle();
    call(core, ui, 2, "terminal.take", { view: "v1" });
    call(core, ui, 3, "terminal.resize", { view: "v1", cols: 100, rows: 30 });
    call(core, ui, 4, "terminal.take", { view: "v1", control: false });
    await host.settle();
    wire.opens[0]!.ready();
    wire.opens[0]!.state({ id: "term-1", types: true, cols: 80, rows: 24, inband: true });
    await host.settle();
    assert.equal(wire.opens.length, 1);
    assert.deepEqual(wire.opens[0]!.got, [{ kind: KIND.control, value: { control: false, taken: false, cols: 100, rows: 30 } }]);
  } finally {
    core.close();
  }
});

test("taking a new terminal before its first state waits for its id instead of opening another", async (t) => {
  for (const inband of [true, false]) for (const answered of [false, true]) await t.test(`${inband ? "in-band control" : "an older station"}, ${answered ? "after" : "before"} the response head`, async () => {
    const wire = terminalWire();
    const { host, core } = await started(base(), 0, wire.make);
    try {
      const ui = core.connect();
      call(core, ui, 1, "terminal.view", { station: "ws/st", terminal: "new", view: "v1", cols: 80, rows: 24, cwd: "/work" });
      await host.settle();
      if (answered) {
        wire.opens[0]!.ready();
        await host.settle();
      }
      call(core, ui, 2, "terminal.take", { view: "v1" });
      await host.settle();
      assert.equal(wire.opens.length, 1, "a control press cannot open a second new terminal");
      if (!answered) wire.opens[0]!.ready();
      wire.opens[0]!.state({ id: "term-1", types: true, cols: 80, rows: 24, inband });
      await host.settle();
      if (inband) {
        assert.equal(wire.opens.length, 1);
        assert.deepEqual(wire.opens[0]!.got, [{ kind: KIND.control, value: { control: true, taken: true, cols: 80, rows: 24 } }]);
      } else {
        assert.equal(wire.opens.length, 2);
        assert.equal(wire.opens[1]!.path, "/admin/api/terminals/term-1/view");
        assert.deepEqual(wire.opens[1]!.ask, { cols: 80, rows: 24, control: true, taken: true });
      }
    } finally {
      core.close();
    }
  });
});

test("looking only chosen while a terminal reconnects is sent when the stream returns", async () => {
  const wire = terminalWire();
  const { host, core } = await started(base(), 0, wire.make);
  try {
    const ui = core.connect();
    call(core, ui, 1, "terminal.view", { station: "ws/st", terminal: "term-1", view: "v1", cols: 80, rows: 24 });
    await host.settle();
    wire.opens[0]!.ready();
    wire.opens[0]!.state({ id: "term-1", types: true, cols: 80, rows: 24, inband: true });
    await host.settle();
    assert.deepEqual(wire.opens[0]!.got, [], "an ordinary open sends no extra control frame");
    wire.opens[0]!.end();
    await host.time.pass(500);
    assert.equal(wire.opens.length, 2);
    call(core, ui, 2, "terminal.take", { view: "v1", control: false });
    await host.settle();
    wire.opens[1]!.ready();
    wire.opens[1]!.state({ id: "term-1", types: true, cols: 80, rows: 24, inband: true });
    await host.settle();
    assert.equal(wire.opens.length, 2);
    assert.deepEqual(wire.opens[1]!.got, [{ kind: KIND.control, value: { control: false, taken: false, cols: 80, rows: 24 } }]);
  } finally {
    core.close();
  }
});

test("a cancelled terminal view does not deliver its pending control choice", async () => {
  const wire = terminalWire();
  const { host, core } = await started(base(), 0, wire.make);
  try {
    const ui = core.connect();
    call(core, ui, 1, "terminal.view", { station: "ws/st", terminal: "term-1", view: "v1", cols: 80, rows: 24, control: false });
    await host.settle();
    call(core, ui, 2, "terminal.take", { view: "v1" });
    await host.settle();
    core.receive(ui, { kind: "cancel", id: 1, cancel: true });
    await host.settle();
    wire.opens[0]!.ready();
    wire.opens[0]!.state({ id: "term-1", types: false, cols: 80, rows: 24, inband: true });
    await host.settle();
    assert.equal(wire.opens.length, 1);
    assert.deepEqual(wire.opens[0]!.got, []);
  } finally {
    core.close();
  }
});

test("a view asks its size, whether it types and takes it, where a new one opens", () => {
  const v = parseTerminal("terminal.view", { station, terminal: "new", view: "v1", cols: 80, rows: 24, taken: true, chat: "c1" });
  assert.deepEqual(v, { kind: "view", station, terminal: "new", view: "v1", ask: { cols: 80, rows: 24, control: true, taken: true, chat: "c1" } });
  assert.deepEqual(parseTerminal("terminal.view", { station, terminal: "term-1", view: "v1", cols: 80, rows: 24, control: false })?.kind, "view");
  assert.throws(() => parseTerminal("terminal.view", { station, terminal: "new", view: "v1", cols: 0, rows: 24 }));
  assert.throws(() => parseTerminal("terminal.view", { station, terminal: "new", view: "v1", cols: 80, rows: 9999 }));
  assert.equal(parseTerminal("terminal.end", { terminal: "term-1" }), null, "an operation's (ops.ts), not a view's");
});

test("what is typed comes as text or as bytes beside the call", () => {
  const typed = parseTerminal("terminal.input", { view: "v1", text: "ls\r" });
  assert.deepEqual(typed?.kind === "input" ? Buffer.from(typed.data).toString() : null, "ls\r");
  const bytes = parseTerminal("terminal.input", { view: "v1" }, new Uint8Array([0x1b, 0x5b, 0x41]));
  assert.deepEqual(bytes?.kind === "input" ? [...bytes.data] : null, [0x1b, 0x5b, 0x41]);
  assert.throws(() => parseTerminal("terminal.input", { view: "v1" }));
  assert.deepEqual(parseTerminal("terminal.resize", { view: "v1", cols: 100, rows: 30 }), { kind: "resize", view: "v1", cols: 100, rows: 30 });
  assert.deepEqual(parseTerminal("terminal.take", { view: "v1" }), { kind: "take", view: "v1" });
  assert.deepEqual(parseTerminal("terminal.take", { view: "v1", control: false }), { kind: "take", view: "v1", control: false });
});

test("the station's frames are read whole however their bytes come", () => {
  const all = Buffer.concat([frame(KIND.screen, Buffer.from("\x1b[Hscreen")), frame(KIND.out, Buffer.from("more")), frame(KIND.state, Buffer.from('{"types":true}'))]);
  const reader = new FrameReader();
  const got: string[] = [];
  // a byte at a time: every frame cut anywhere
  for (const b of all) {
    reader.push(Uint8Array.of(b));
    for (let f = reader.next(); f !== null; f = reader.next()) got.push(`${f.kind}:${Buffer.from(f.payload).toString()}`);
  }
  assert.deepEqual(got, [`${KIND.screen}:\x1b[Hscreen`, `${KIND.out}:more`, `${KIND.state}:{"types":true}`]);
});

test("drainFrames coalesces consecutive out frames while preserving screen and state boundaries", () => {
  const reader = new FrameReader();
  reader.push(
    Buffer.concat([
      frame(KIND.out, Buffer.from("one ")),
      frame(KIND.out, Buffer.from("two ")),
      frame(KIND.out, Buffer.from("three")),
      frame(KIND.state, Buffer.from('{"types":true,"inband":true}')),
      frame(KIND.out, Buffer.from("after-1 ")),
      frame(KIND.out, Buffer.from("after-2")),
    ]),
  );
  const drained = drainFrames(reader).map((f) => `${f.kind}:${Buffer.from(f.payload).toString()}`);
  assert.deepEqual(drained, [
    `${KIND.out}:one two three`,
    `${KIND.state}:{"types":true,"inband":true}`,
    `${KIND.out}:after-1 after-2`,
  ]);
});
