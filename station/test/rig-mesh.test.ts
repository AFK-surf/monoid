// A rig's mesh (rig/main.ts RigMeshLive) as it starts: a bind that fails is tried again after the backoff (mesh.ts
// keptRunning, 1 s doubling to 30 s), and a rig that stops is never bound again. Its endpoint is in memory
// (memory-mesh.ts), its time a test's clock.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { Clock, Effect, Fiber, Layer, Stream } from "effect";
import { Net } from "../src/jobs/load.ts";
import type { Mesh } from "../src/mesh/native.ts";
import { RigMeshLive, RigSide } from "../src/rig/main.ts";
import { ControlPlane, Key, MeshNative, MeshSide, Peers, Previous, StationConfig } from "../src/services.ts";
import { memoryMesh } from "./memory-mesh.ts";
import { settle, testClock } from "./hub-fakes.ts";

/// A rig's mesh started on `clock`, its first `failures` binds refused as a port still held would be.
function rigMesh(t: TestContext, failures: number, clock: Clock.Clock, ended = 0) {
  const original = process.env.STILLFAIL_MESH_BIND_ADDR;
  delete process.env.STILLFAIL_MESH_BIND_ADDR;
  const data = mkdtempSync(join(tmpdir(), "rig-mesh-"));
  t.after(() => {
    if (original !== undefined) process.env.STILLFAIL_MESH_BIND_ADDR = original;
    rmSync(data, { recursive: true, force: true });
  });
  const mesh = memoryMesh();
  let binds = 0;
  let accepting = false;
  let closed = 0;
  let bound = 0;
  // The cloud's state as the rig's mesh reads it: a workspace, no relays, no stations.
  const cloud = { state: { workspace_name: "ws" }, data, relays: () => [], memberships: () => [], peersCurrent: false, listen: () => () => {}, toolCalls: null, removed: () => false };
  const inputs = Layer.mergeAll(
    Layer.succeed(MeshSide)({ net: new Net(), peers: { route: null }, outside: null, forwarded: () => false, runtimes: () => [], device: null }),
    Layer.succeed(Previous)({ pid: null, gone: Promise.resolve(), exited: Promise.resolve() }),
    Layer.succeed(Peers)({ attach: () => {} } as never),
    Layer.succeed(StationConfig)({ raw: () => ({}), listen: () => () => {} } as never),
    Layer.succeed(ControlPlane)({
      state: cloud,
      changes: Stream.never,
      presence: Effect.never,
      spec: () => ({ name: "still.fail cloud", tools: false }),
      credential: () => undefined,
      logs: () => Effect.void,
    } as never),
    Layer.succeed(Key)({ seed: Buffer.alloc(32) } as never),
    Layer.succeed(RigSide)({ current: null }),
    Layer.succeed(MeshNative)({ bind: async (options: Parameters<Mesh["bind"]>[0]) => {
      binds++;
      if (binds <= failures) throw new Error("port is held by the previous rig");
      const endpoint = await mesh.bind(options);
      // Its relay link never up: no real sockets or timers here.
      endpoint.online = () => new Promise<void>(() => {});
      const accept = endpoint.accept.bind(endpoint);
      // The first `ended` endpoints bound give no connection, as one whose driver ended does: `accept` answers null.
      const ends = ++bound <= ended;
      endpoint.accept = () => {
        accepting = true;
        return ends ? Promise.resolve(null) : accept();
      };
      const close = endpoint.close.bind(endpoint);
      endpoint.close = () => {
        closed++;
        return close();
      };
      return endpoint;
    } } as unknown as Mesh),
  );
  const running = Effect.runFork(Effect.scoped(Effect.gen(function* () {
    yield* Layer.build(RigMeshLive.pipe(Layer.provide(inputs)));
    yield* Effect.never;
  })).pipe(Effect.provideService(Clock.Clock, clock)));
  t.after(() => Effect.runPromise(Fiber.interrupt(running)));
  return { running, binds: () => binds, accepting: () => accepting, closed: () => closed };
}

test("a rig's mesh whose first bind fails is bound again after the backoff, and serves", async (t) => {
  const time = testClock();
  const r = rigMesh(t, 1, time.clock);
  await settle();
  assert.equal(r.binds(), 1);
  assert.equal(r.accepting(), false, "the failed bind serves nothing");
  await time.adjust(999);
  await settle();
  assert.equal(r.binds(), 1, "not bound again before the backoff");
  await time.adjust(1);
  await settle();
  assert.equal(r.binds(), 2, "bound again a second after the failure");
  assert.equal(r.accepting(), true, "the rig's mesh takes connections once bound");
});

test("a rig that stops while its mesh waits to be bound again is not bound again", async (t) => {
  const time = testClock();
  const r = rigMesh(t, 2, time.clock);
  await settle();
  assert.equal(r.binds(), 1);
  await time.adjust(1_000);
  await settle();
  assert.equal(r.binds(), 2, "the first backoff's retry is made");
  await Effect.runPromise(Fiber.interrupt(r.running));
  await time.adjust(30_000);
  await settle();
  assert.equal(r.binds(), 2, "the retry is called off with the rig");
  assert.equal(r.accepting(), false);
});

test("a rig's endpoint that gives no more connections is closed and bound again after the backoff", async (t) => {
  const time = testClock();
  const r = rigMesh(t, 0, time.clock, 1);
  await settle();
  assert.equal(r.binds(), 1);
  assert.equal(r.closed(), 1, "the endpoint whose accept ended is let go");
  await time.adjust(999);
  await settle();
  assert.equal(r.binds(), 1, "not bound again before the backoff");
  await time.adjust(1);
  await settle();
  assert.equal(r.binds(), 2, "bound again a second after its accept ended");
  assert.equal(r.closed(), 1, "the endpoint bound again is kept");
  await Effect.runPromise(Fiber.interrupt(r.running));
  await settle();
  await time.adjust(30_000);
  await settle();
  assert.equal(r.binds(), 2, "a rig that stops is not bound again");
});
