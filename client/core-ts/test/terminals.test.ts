// A station's terminals from the core (src/terminals.ts): what the calls take, the station's frames read as they come
// in pieces, and control choices while a view opens. The view's stream end to end is the station's tests'
// (station/test/terminals.test.ts) and the app's.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Deferred, Effect, Queue } from "effect";
import { FrameReader, KIND, drainFrames, frame, parseTerminal } from "../src/terminals.ts";
import { t as i18n } from "../src/i18n.ts";
import { HostWire, type StationWire, type TerminalAsk } from "../src/station/wire.ts";
import { jsonResponse, type FakeHost } from "../src/testing.ts";
import { call } from "./helpers.ts";
import { base, started, stationLater } from "./station-fixture.ts";

const station = "w1/s1";
const withTerminals = () => ({ ...base(), "GET /terminals": { terminals: [{ id: "term-1", by: "a@x.com", cwd: "/tmp", at: 1, looking: [] }] } });

function terminalWire() {
  const opens: { path: string; ask: TerminalAsk; got: { kind: number; value: unknown }[]; closed: boolean; ready(): void; state(value: Record<string, unknown>): void; out(text: string): void; end(): void }[] = [];
  const make = (host: FakeHost): StationWire => {
    const plain = new HostWire(host);
    return {
      request: (s, head, body) => plain.request(s, head, body),
      terminal: (_station, head, ask) => Effect.gen(function* () {
        const ready = Deferred.makeUnsafe<void>();
        const queue = yield* Queue.unbounded<Uint8Array | null>();
        const got: { kind: number; value: unknown }[] = [];
        const entry = {
          path: head.path, ask, got, closed: false,
          ready: () => { Deferred.doneUnsafe(ready, Effect.void); },
          state: (value: Record<string, unknown>) => { Queue.offerUnsafe(queue, frame(KIND.state, Buffer.from(JSON.stringify(value)))); },
          out: (text: string) => { Queue.offerUnsafe(queue, frame(KIND.out, Buffer.from(text))); },
          end: () => { Queue.offerUnsafe(queue, null); },
        };
        opens.push(entry);
        yield* Effect.addFinalizer(() => Effect.sync(() => { entry.closed = true; }));
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
    const { host, core } = await started(withTerminals(), 0, wire.make);
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
  const { host, core } = await started(withTerminals(), 0, wire.make);
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
    const { host, core } = await started(withTerminals(), 0, wire.make);
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
  const { host, core } = await started(withTerminals(), 0, wire.make);
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
  const { host, core } = await started(withTerminals(), 0, wire.make);
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

test("r14: terminal.view gates on current-authGen confirmation, clamps viewer control, aborts live stream on 403, and fails auth_stale on boundary", async () => {
  const S = "ws/st";

  // Case A: cached local terminals row + pending GET /terminals -> 0 terminalView while pending;
  //         when GET /terminals returns 403 -> phase: "denied" and 0 terminalView overall.
  {
    const wire = terminalWire();
    const { host, core } = await started(withTerminals(), 0, wire.make);
    try {
      const link = core.inner.stations.link(S)!;
      const digest = core.inner.store.authGen.workspaceDigest("ws")!;
      link.memory.deletePrefix("terminals");
      core.inner.data.keepStationMemory(S, "terminals", {
        terminals: [{ id: "term-1", by: "a@x.com", cwd: "/tmp", at: 1, looking: [] }],
        outdated: false,
        authDigest: digest,
        capRev: 0,
      });
      assert.equal(core.inner.stations.isConfirmed("terminals", S), false);
      let releaseGet!: (r: ReturnType<typeof jsonResponse>) => void;
      const getGate = new Promise<ReturnType<typeof jsonResponse>>((resolve) => { releaseGet = resolve; });
      stationLater(host, (req) => (req.method === "GET" && req.url.endsWith("/admin/api/terminals") ? getGate : undefined));

      const ui = core.connect();
      host.takeEmitted();
      call(core, ui, 1, "terminal.view", { station: S, terminal: "term-1", view: "v-a", cols: 80, rows: 24, control: true });
      await host.settle();
      assert.equal(wire.opens.length, 0, "must emit 0 terminalView while GET /terminals is pending");

      releaseGet(jsonResponse(403, { error: "forbidden" }));
      await host.settle();
      assert.equal(wire.opens.length, 0, "must emit 0 terminalView when GET /terminals returns 403");
      const msgs = host.takeEmitted().map(([, m]) => m as { id?: number; value?: { state?: { phase?: string } } });
      assert.ok(msgs.some((m) => m.id === 1 && m.value?.state?.phase === "denied"), `expected phase: denied, got ${JSON.stringify(msgs)}`);
    } finally {
      core.close();
    }
  }

  // Case B: workspace role "viewer" (!mayDrive) -> terminal.view(control:true), take(true), and reconnect all clamp to control:false;
  //         terminal: "new" is immediately denied with 0 terminalView calls.
  {
    const wire = terminalWire();
    const { host, core } = await started(withTerminals(), 0, wire.make, (st) => {
      st.cloud.role = "viewer";
    });
    try {
      const ui = core.connect();
      host.takeEmitted();
      // terminal: "new" denied immediately for viewer with 0 opens
      call(core, ui, 10, "terminal.view", { station: S, terminal: "new", view: "v-new", cols: 80, rows: 24, control: true });
      await host.settle();
      assert.equal(wire.opens.length, 0, "viewer must not open a new terminal");
      const newMsgs = host.takeEmitted().map(([, m]) => m as { id?: number; value?: { state?: { phase?: string } } });
      assert.ok(newMsgs.some((m) => m.id === 10 && m.value?.state?.phase === "denied"), "new terminal for viewer must be denied");

      // Existing term-1 opened with control:true -> clamped to control:false
      call(core, ui, 11, "terminal.view", { station: S, terminal: "term-1", view: "v-ro", cols: 80, rows: 24, control: true, taken: true });
      await host.settle();
      assert.equal(wire.opens.length, 1);
      assert.equal(wire.opens[0]!.ask.control, false, "initial terminalView for viewer must clamp control to false");
      assert.equal(wire.opens[0]!.ask.taken, undefined, "initial terminalView for viewer must strip taken");

      wire.opens[0]!.ready();
      wire.opens[0]!.state({ id: "term-1", types: false, cols: 80, rows: 24, inband: true });
      await host.settle();

      // terminal.take(true) must also clamp to control:false, taken:false
      call(core, ui, 12, "terminal.take", { view: "v-ro", control: true });
      await host.settle();
      assert.deepEqual(wire.opens[0]!.got, [{ kind: KIND.control, value: { control: false, taken: false, cols: 80, rows: 24 } }]);

      // Reconnect must also clamp to control:false
      wire.opens[0]!.end();
      await host.time.pass(500);
      assert.equal(wire.opens.length, 2);
      assert.equal(wire.opens[1]!.ask.control, false, "reconnected terminalView for viewer must clamp control to false");
      assert.equal(wire.opens[1]!.ask.taken, undefined);
    } finally {
      core.close();
    }
  }

  // Case C: mid-session GET /terminals 403 aborts live stream to phase: "denied";
  //         authGen change during reconnect fails with auth_stale and 0 stale-gen terminalView calls.
  {
    const wire = terminalWire();
    const { host, core } = await started(withTerminals(), 0, wire.make);
    try {
      let force403 = false;
      stationLater(host, (req) =>
        force403 && req.method === "GET" && req.url.endsWith("/admin/api/terminals")
          ? Promise.resolve(jsonResponse(403, { error: "forbidden" }))
          : undefined,
      );
      const ui = core.connect();
      call(core, ui, 20, "terminal.view", { station: S, terminal: "term-1", view: "v-mid", cols: 80, rows: 24 });
      await host.settle();
      assert.equal(wire.opens.length, 1);
      wire.opens[0]!.ready();
      wire.opens[0]!.state({ id: "term-1", types: true, cols: 80, rows: 24, inband: true });
      await host.settle();

      // Mid-session 403 aborts live stream immediately to phase: "denied"
      host.takeEmitted();
      force403 = true;
      core.inner.runner.fork(core.inner.stations.readTerminals(S));
      await host.settle();
      const midMsgs = host.takeEmitted().map(([, m]) => m as { id?: number; value?: { state?: { phase?: string } } });
      assert.ok(midMsgs.some((m) => m.id === 20 && m.value?.state?.phase === "denied"), `mid-session 403 must abort live terminal to denied, got ${JSON.stringify(midMsgs)}`);
      assert.equal(wire.opens.length, 1, "must not reopen after mid-session 403");

      // Recover via 200, open another stream, drop it, bump authGen during reconnect -> fails with auth_stale and 0 stale terminalView.
      force403 = false;
      core.inner.runner.fork(core.inner.stations.readTerminals(S));
      await host.settle();
      call(core, ui, 21, "terminal.view", { station: S, terminal: "term-1", view: "v-stale", cols: 80, rows: 24 });
      await host.settle();
      assert.equal(wire.opens.length, 2);
      wire.opens[1]!.ready();
      wire.opens[1]!.state({ id: "term-1", types: true, cols: 80, rows: 24, inband: true });
      await host.settle();

      host.takeEmitted();
      wire.opens[1]!.end();
      await host.settle();
      // Bump workspace authGen while view is in reconnect backoff:
      core.inner.store.authGen.syncWorkspace("ws", "owner:a@x.com:role:changed");
      await host.time.pass(600);
      assert.equal(wire.opens.length, 2, "must not issue a stale-authGen terminalView on reconnect");
      const staleMsgs = host.takeEmitted().map(([, m]) => m as { id?: number; error?: { code?: string } });
      assert.ok(staleMsgs.some((m) => m.id === 21 && m.error?.code === "auth_stale"), `expected auth_stale error on reconnect, got ${JSON.stringify(staleMsgs)}`);
    } finally {
      core.close();
    }
  }
});

test("r15: live terminal aborts immediately on authGen boundary, new-terminal take(false) survives handshake, and denied uses terminal copy", async (t) => {
  const S = "ws/st";

  // P1: live open terminal stream (no socket end) aborts immediately on workspace authGen bump,
  //     closes socket scope, returns auth_stale, and ignores any subsequent frames pushed to old socket.
  await t.test("P1: live open socket aborts immediately on authGen boundary", async () => {
    const wire = terminalWire();
    const { host, core } = await started(withTerminals(), 0, wire.make);
    try {
      const ui = core.connect();
      call(core, ui, 30, "terminal.view", { station: S, terminal: "term-1", view: "v-live", cols: 80, rows: 24 });
      await host.settle();
      assert.equal(wire.opens.length, 1);
      wire.opens[0]!.ready();
      wire.opens[0]!.state({ id: "term-1", types: true, cols: 80, rows: 24, inband: true });
      await host.settle();
      assert.equal(wire.opens[0]!.closed, false, "socket should still be live before auth boundary");

      host.takeEmitted();
      core.inner.store.authGen.syncWorkspace("ws", "owner:a@x.com:role:revoked");
      await host.settle();

      assert.equal(wire.opens[0]!.closed, true, "live socket scope must be closed immediately on authGen boundary");
      assert.equal(wire.opens.length, 1, "must not reopen after authGen boundary");
      const abortMsgs = host.takeEmitted().map(([, m]) => m as { id?: number; kind?: string; error?: { code?: string }; value?: { state?: { phase?: string } } });
      assert.ok(
        abortMsgs.some((m) => m.id === 30 && m.error?.code === "auth_stale"),
        `expected immediate auth_stale error, got ${JSON.stringify(abortMsgs)}`,
      );
      assert.ok(
        !abortMsgs.some((m) => m.id === 30 && m.value?.state?.phase === "denied"),
        `authGen boundary must fail with auth_stale, not emit phase: denied: ${JSON.stringify(abortMsgs)}`,
      );

      // Pushing further frames onto the old socket must emit zero progress messages.
      wire.opens[0]!.out("post-boundary-secret");
      wire.opens[0]!.state({ id: "term-1", types: true, cols: 80, rows: 24, inband: true });
      await host.settle();
      const lateMsgs = host.takeEmitted().map(([, m]) => m as { id?: number });
      assert.deepEqual(
        lateMsgs.filter((m) => m.id === 30),
        [],
        `must emit 0 progress messages after auth_stale abort, got ${JSON.stringify(lateMsgs)}`,
      );
    } finally {
      core.close();
    }
  });

  // P2: terminal: "new" with control: true + take(false) before ready() preserves control: false (inband true & false).
  for (const inband of [true, false]) {
    await t.test(`P2: new-terminal take(false) before ready() is not overwritten (inband=${inband})`, async () => {
      const wire = terminalWire();
      const routes = {
        ...base(),
        "GET /terminals": {
          terminals: [
            { id: "term-1", by: "a@x.com", cwd: "/tmp", at: 1, looking: [] },
            { id: "t-new", by: "a@x.com", cwd: "/work", at: 2, looking: [] },
          ],
        },
      };
      const { host, core } = await started(routes, 0, wire.make);
      try {
        const ui = core.connect();
        call(core, ui, 40, "terminal.view", { station: S, terminal: "new", view: "v-new-ro", cols: 80, rows: 24, control: true, cwd: "/work" });
        await host.settle();
        assert.equal(wire.opens.length, 1);
        assert.equal(wire.opens[0]!.ask.control, true);

        call(core, ui, 41, "terminal.take", { view: "v-new-ro", control: false });
        await host.settle();

        wire.opens[0]!.ready();
        wire.opens[0]!.state({ id: "t-new", types: true, cols: 80, rows: 24, inband });
        await host.settle();

        if (inband) {
          assert.equal(wire.opens.length, 1);
          assert.deepEqual(wire.opens[0]!.got, [{ kind: KIND.control, value: { control: false, taken: false, cols: 80, rows: 24 } }]);
        } else {
          assert.equal(wire.opens.length, 2);
          assert.equal(wire.opens[1]!.path, "/admin/api/terminals/t-new/view");
          assert.deepEqual(wire.opens[1]!.ask, { cols: 80, rows: 24, control: false });
        }
      } finally {
        core.close();
      }
    });
  }

  // P3: denied terminal message uses core-views.terminal.denied (never screen copy).
  await t.test("P3: terminal denied state message uses core-views.terminal.denied", async () => {
    const wire = terminalWire();
    const { host, core } = await started(withTerminals(), 0, wire.make, (st) => {
      st.cloud.role = "viewer";
    });
    try {
      const ui = core.connect();
      host.takeEmitted();
      call(core, ui, 50, "terminal.view", { station: S, terminal: "new", view: "v-denied-msg", cols: 80, rows: 24, control: true });
      await host.settle();
      const msgs = host.takeEmitted().map(([, m]) => m as { id?: number; value?: { state?: { phase?: string; message?: string } } });
      const deniedMsg = msgs.find((m) => m.id === 50 && m.value?.state?.phase === "denied")?.value?.state?.message;
      assert.equal(deniedMsg, i18n("core-views.terminal.denied"));
      assert.ok(deniedMsg && !deniedMsg.includes("屏幕") && !deniedMsg.toLowerCase().includes("screen"), `unexpected screen copy in terminal denied message: ${deniedMsg}`);
    } finally {
      core.close();
    }
  });
});
