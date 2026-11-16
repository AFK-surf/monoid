// A station tells still.fail's cloud the ways it keeps of its workspaces (`ways.put` on its presence socket,
// src/cloud/presence.ts `waysTeller`): as each socket opens and as they change here, each record once a socket, so the
// cloud's `/v1/me` names the relays a browser or a device new to the workspace must take, and an app from before the
// stations kept them goes by them (2026-11-16, Hypershell: still.fail's relays off on its stations, `/v1/me` still said
// none were off and named none of its own). Comma's plane is told none.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Clock, Duration, Effect, Exit, Fiber, Scope, Stream, SubscriptionRef } from "effect";
import { TestClock } from "effect/testing";
import { enroll } from "../src/cli.ts";
import { loadKey } from "../src/cloud/key.ts";
import { makeControlPlane } from "../src/cloud/plane.ts";
import { presence } from "../src/cloud/presence.ts";
import { Cloud } from "../src/cloud/state.ts";
import { addRelay, setWay, waysOf } from "../src/mesh/ways.ts";
import { FakeControlPlane } from "./fake-control-plane.ts";

/// A TestClock whose waits are said as they begin: `asleep(ms)` takes the next one begun (as presence-conflict.test.ts).
function testClock() {
  const scope = Effect.runSync(Scope.make());
  const clock = Effect.runSync(Scope.provide(TestClock.make(), scope));
  const begun: number[] = [];
  let heard: (() => void) | null = null;
  const wrapped: Clock.Clock = {
    ...clock,
    sleep: (d) =>
      Effect.suspend(() => {
        begun.push(Duration.toMillis(d));
        heard?.();
        return clock.sleep(d);
      }),
  };
  let seen = 0;
  const asleep = async (ms: number, what: string) => {
    while (seen === begun.length) await new Promise<void>((r) => (heard = r));
    heard = null;
    assert.equal(begun[seen++], ms, what);
  };
  return { clock: wrapped, asleep, adjust: (ms: number) => Effect.runPromise(clock.adjust(ms)), close: () => Effect.runPromise(Scope.close(scope, Exit.void)) };
}

async function station(t: { after: (f: () => Promise<void>) => void }, provider: "stillfail" | "comma") {
  const fake = new FakeControlPlane({ provider });
  const origin = await fake.start();
  const data = mkdtempSync(join(tmpdir(), "ways-presence-"));
  const quiet = console.log;
  console.log = () => {};
  try {
    await enroll(data, origin, "tok", provider);
  } finally {
    console.log = quiet;
  }
  const state = new Cloud(data);
  const ways = waysOf(state);
  // How many listen to the ways now: none left behind by a socket that ended.
  let listening = 0;
  const listen = ways.listen.bind(ways);
  ways.listen = (f) => {
    listening++;
    const stop = listen(f);
    return () => {
      listening--;
      stop();
    };
  };
  const key = loadKey(data);
  const up = Effect.runSync(SubscriptionRef.make(true));
  const { spec } = makeControlPlane({ state, changes: Stream.never, key, up });
  const every = (_ms: number, _f: () => void) => () => {};
  const time = testClock();
  let fiber: Fiber.Fiber<unknown, unknown> | null = null;
  const start = () => {
    fiber = Effect.runFork(presence({ cloud: { state, changes: Stream.never }, key, up, spec, every }).pipe(Effect.provideService(Clock.Clock, time.clock)));
  };
  // The socket ended and the ways written before the directory goes.
  t.after(async () => {
    if (fiber !== null) await Effect.runPromise(Fiber.interrupt(fiber));
    await ways.written();
    await time.close();
    state.close();
    await fake.close();
    rmSync(data, { recursive: true, force: true });
  });
  const puts = () => fake.heard.filter((f) => f?.type === "ways.put");
  // Once the open socket (the `n`th) answered a request asked after now: all it said before is heard, as a socket keeps
  // its order (what a station says of its ways it says at once, as the socket opens or as they change).
  let asked = 0;
  const heardAll = async (n: number) => {
    await fake.when(() => fake.sockets.length === n);
    const id = `barrier-${++asked}`;
    fake.sockets[n - 1]!.send(JSON.stringify({ type: "tool", id, request: {} }));
    await fake.when(() => fake.heard.some((f) => f?.type === "tool_result" && f.id === id));
  };
  return { fake, state, ways, start, time, heardAll, puts, listening: () => listening };
}

test("a station's ways go to still.fail's cloud as its socket opens and as they change, each once a socket, again on the next socket", async (t) => {
  const s = await station(t, "stillfail");
  const ws = s.state.home()!;
  const me = s.state.state!.station;
  // Kept before the socket opens (restored from ways.json): said as it opens.
  const first = addRelay(s.ways, ws, "https://relay.example", "上海中继 chat");
  s.start();
  await s.heardAll(1);
  assert.deepEqual(s.puts(), [{ type: "ways.put", workspace: ws, relays: ["https://relay.example"], off: [], at: first.at, station: me }]);
  assert.equal(s.listening(), 1, "one socket, one listener");

  // Changed here (an agent's `relays` tool, a device's POST /ways): said at once.
  const off = setWay(s.ways, ws, "ours", false);
  await s.heardAll(1);
  assert.equal(s.puts().length, 2);
  assert.deepEqual(s.puts()[1], { type: "ways.put", workspace: ws, relays: ["https://relay.example"], off: ["ours"], at: off.at, station: me });
  // cloud.json changing (a state frame) says nothing it said already.
  s.fake.push(me);
  await s.heardAll(1);
  assert.equal(s.puts().length, 2, "each record once a socket");

  // The socket ends (the cloud restarting): the next one says the record again, the first's listener gone.
  s.fake.sockets[0]!.close(1012, "restarting");
  await s.time.asleep(1000, "the backoff after the socket ended");
  await s.time.adjust(1000);
  await s.heardAll(2);
  assert.equal(s.puts().length, 3);
  assert.deepEqual(s.puts()[2], s.puts()[1], "the same record on the new socket");
  assert.equal(s.listening(), 1, "the ended socket's listener let go");

  // A change after it: said once, on the new socket.
  const lan = setWay(s.ways, ws, "lan", false);
  await s.heardAll(2);
  assert.deepEqual(s.puts().slice(3), [{ type: "ways.put", workspace: ws, relays: ["https://relay.example"], off: ["ours", "lan"], at: lan.at, station: me }]);
});

test("Comma's plane is told no ways", async (t) => {
  const s = await station(t, "comma");
  addRelay(s.ways, s.state.home()!, "https://relay.example", null);
  s.start();
  await s.heardAll(1);
  setWay(s.ways, s.state.home()!, "lan", false);
  await s.heardAll(1);
  assert.deepEqual(s.puts(), []);
  assert.equal(s.listening(), 0, "nor listens for a change");
});
