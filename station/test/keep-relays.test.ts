// The station kept on still.fail's relays (mesh/relays.ts) on an endpoint the front kept across a handover: the
// workspaces' own relays put in before it is kept on them, and iroh's public relays, which the process before may have
// turned on, taken off by the first check that finds still.fail's answering. The relays' pings are this test's fetch.
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { Clock, Effect, Fiber, Stream } from "effect";
import { keepRelays } from "../src/mesh/relays.ts";
import { removeRelay, setWay, waysOf } from "../src/mesh/ways.ts";
import { ControlPlane } from "../src/services.ts";
import type { Endpoint } from "../src/mesh/native.ts";
import { settle, testClock } from "./hub-fakes.ts";

const OURS = "https://relay.still.example/";
const THEIRS = "https://relay.workspace.example";

/// keepRelays run on an endpoint that says what it is asked; `answering` whether still.fail's relays answer a ping.
/// `bound`: what the endpoint was bound with; `off`: the ways the workspace turned off as the cloud kept them.
function keeping(t: TestContext, answering: { now: boolean }, o: { bound?: string[]; off?: string[] } = {}) {
  const asked: string[] = [];
  const endpoint = {
    home: () => null,
    insertRelay: async (url: string) => void asked.push(`insert ${url}`),
    removeRelay: async (url: string) => void asked.push(`remove ${url}`),
    publicRelays: async (on: boolean) => void asked.push(`public ${on}`),
    keep: (urls: string[]) => void asked.push(`keep ${urls.join(" ")}`),
  } as unknown as Endpoint;
  const cloud = {
    data: mkdtempSync(join(tmpdir(), "keep-relays-")),
    state: null,
    relays: () => [OURS],
    memberships: () => [{ workspace: "w" }],
    waysSaid: () => ({ relays: [THEIRS], off: o.off ?? [] }),
  };
  const fetched = globalThis.fetch;
  globalThis.fetch = (async (url: string) => {
    if (!answering.now || !String(url).startsWith(OURS)) throw new Error("unreachable");
    return new Response("pong");
  }) as typeof fetch;
  t.after(() => void (globalThis.fetch = fetched));
  const clock = testClock();
  const plane = { state: cloud, changes: Stream.never } as never;
  const fiber = Effect.runFork(keepRelays(endpoint, undefined, o.bound).pipe(Effect.provideService(ControlPlane, plane), Effect.provideService(Clock.Clock, clock.clock)));
  t.after(() => Effect.runPromise(Fiber.interrupt(fiber)));
  return { asked, clock, cloud };
}

test("a workspace's own relays are put in before the endpoint is kept on them", async (t) => {
  const { asked } = keeping(t, { now: true });
  await settle(10);
  assert.deepEqual(asked.slice(0, 2), [`insert ${THEIRS}`, `keep ${OURS} ${THEIRS}`]);
});

test("iroh's public relays, on from the process before, go at the first check that finds still.fail's answering, once", async (t) => {
  const { asked, clock } = keeping(t, { now: true });
  await settle(10);
  assert.deepEqual(asked.filter((a) => a.startsWith("public")), ["public false"]);
  await clock.adjust(30_000);
  await settle(10);
  await clock.adjust(30_000);
  await settle(10);
  assert.deepEqual(asked.filter((a) => a.startsWith("public")), ["public false"], "not asked again while they stay off");
});

test("none of still.fail's relays answering: iroh's public relays come in once, and go once one answers again", async (t) => {
  const answering = { now: false };
  const { asked, clock } = keeping(t, answering);
  await settle(10);
  assert.deepEqual(asked.filter((a) => a.startsWith("public")), ["public true"]);
  await clock.adjust(30_000);
  await settle(10);
  assert.deepEqual(asked.filter((a) => a.startsWith("public")), ["public true"]);
  answering.now = true;
  await clock.adjust(30_000);
  await settle(10);
  assert.deepEqual(asked.filter((a) => a.startsWith("public")), ["public true", "public false"]);
});

test("a workspace turning still.fail's relays off takes the station off them and keeps it on its own; on again, back on them", async (t) => {
  const { asked, cloud } = keeping(t, { now: true });
  await settle(10);
  const ways = waysOf(cloud as never);
  const from = () => asked.length;
  let at = from();
  setWay(ways, "w", "ours", false);
  await settle(10);
  assert.deepEqual(asked.slice(at), [`remove ${OURS}`, `keep ${THEIRS}`]);
  at = from();
  setWay(ways, "w", "ours", true);
  await settle(10);
  assert.deepEqual(asked.slice(at), [`insert ${OURS}`, `keep ${OURS} ${THEIRS}`]);
  at = from();
  removeRelay(ways, "w", THEIRS);
  await settle(10);
  assert.deepEqual(asked.slice(at), [`remove ${THEIRS}`, `keep ${OURS}`], "its own relay removed: taken off it");
});

test("an endpoint bound with a relay its workspace turned off is taken off it at once", async (t) => {
  const { asked } = keeping(t, { now: true }, { bound: [OURS, THEIRS], off: ["ours"] });
  await settle(10);
  assert.deepEqual(asked.slice(0, 2), [`remove ${OURS}`, `keep ${THEIRS}`]);
});

test("every workspace turned still.fail's relays off: none of its own answering brings in no public relay either", async (t) => {
  const answering = { now: false };
  const { asked, clock } = keeping(t, answering, { off: ["ours"] });
  await settle(10);
  await clock.adjust(30_000);
  await settle(10);
  assert.deepEqual(asked.filter((a) => a.startsWith("public")), ["public false"], "iroh's public relays (n0's) kept off, as still.fail's are");
});

// ── the endpoint's own watch (relays.ts `PROBE`): probed end to end through a relay that answers ──

type Probed = { ok: boolean; stage?: "probe_offline" | "endpoint_failed" } | Error;

/// keepRelays watching an endpoint whose probes find `now.probe` and whose relays say `now.status`; `answering` whether
/// the relays answer their ping. Every 30 s check is `tick()`; `t` the test's time since the start, `recovered` the
/// times it was told unhealthy, `probes` the times it was probed.
function watching(t: TestContext, now: { probe: Probed; status: { url: string; connected: boolean; access: string; conflict?: boolean }[]; up: boolean }) {
  const recovered: number[] = [];
  const probes: number[] = [];
  let at = 0;
  const endpoint = {
    home: () => OURS,
    insertRelay: async () => {},
    removeRelay: async () => {},
    publicRelays: async () => {},
    keep: () => {},
    relayStatus: () => now.status,
    probeRelay: async (url: string) => {
      assert.equal(url, OURS, "probed through the relay that answered");
      probes.push(at);
      if (now.probe instanceof Error) throw now.probe;
      return now.probe;
    },
  } as unknown as Endpoint;
  const cloud = { data: mkdtempSync(join(tmpdir(), "keep-relays-")), state: null, relays: () => [OURS], memberships: () => [{ workspace: "w" }], waysSaid: () => ({ relays: [], off: [] }) };
  const fetched = globalThis.fetch;
  globalThis.fetch = (async () => {
    if (!now.up) throw new Error("unreachable");
    return new Response("pong");
  }) as typeof fetch;
  t.after(() => void (globalThis.fetch = fetched));
  const clock = testClock();
  const plane = { state: cloud, changes: Stream.never } as never;
  const fiber = Effect.runFork(keepRelays(endpoint, undefined, undefined, { onUnhealthy: () => void recovered.push(at) }).pipe(Effect.provideService(ControlPlane, plane), Effect.provideService(Clock.Clock, clock.clock)));
  t.after(() => Effect.runPromise(Fiber.interrupt(fiber)));
  const tick = async (n = 1) => {
    for (let i = 0; i < n; i++) {
      at += 30_000;
      await clock.adjust(30_000);
      await settle(10);
    }
  };
  return { recovered, probes, tick, at: () => at };
}

type Status = { url: string; connected: boolean; access: string; conflict?: boolean }[];
const CONNECTED: Status = [{ url: OURS, connected: true, access: OURS }];
const LOST: Status = [{ url: OURS, connected: false, access: OURS }];
const MIN = 60_000;

test("an endpoint failing its probes is not recovered in its first two minutes, then once, then after 10, 20, 40 and 60 minutes; well after its cooldown, 10 again", async (t) => {
  const now = { probe: { ok: false, stage: "endpoint_failed" } as Probed, status: LOST, up: true };
  const w = watching(t, now);
  await settle(10);
  await w.tick(3);
  assert.deepEqual(w.probes, [0, 30_000, 60_000, 90_000], "probed at every check while its relays say it is on none");
  assert.deepEqual(w.recovered, [], "three failures, but within the first two minutes");
  await w.tick(1);
  assert.deepEqual(w.recovered, [2 * MIN]);
  // (failing on: the next only once each cooldown is over, each twice the last, to an hour)
  await w.tick((2 * MIN + 10 * MIN + 20 * MIN + 40 * MIN + 60 * MIN + 60 * MIN - 2 * MIN) / 30_000);
  assert.deepEqual(w.recovered, [2 * MIN, 12 * MIN, 32 * MIN, 72 * MIN, 132 * MIN, 192 * MIN]);
  // Well again: once its cooldown (an hour) is over, the next recovery is 10 minutes' cooldown again.
  now.probe = { ok: true };
  now.status = CONNECTED;
  await w.tick(4 * 120); // (four hours: probed every 4 checks while well)
  now.probe = { ok: false, stage: "endpoint_failed" };
  now.status = LOST;
  const from = w.at();
  await w.tick(3);
  assert.deepEqual(w.recovered.slice(6), [from + 90_000], "three failures after its cooldown: recovered at once");
  await w.tick(10 * MIN / 30_000);
  assert.deepEqual(w.recovered.slice(6), [from + 90_000, from + 90_000 + 10 * MIN], "its cooldown back to 10 minutes");
});

test("a probe that cannot get on the relay (the network's, not the endpoint's) never recovers it", async (t) => {
  const now = { probe: { ok: false, stage: "probe_offline" } as Probed, status: LOST, up: true };
  const w = watching(t, now);
  await settle(10);
  await w.tick(60);
  assert.equal(w.probes.length, 61, "probed at every check while its relays say it is on none");
  assert.deepEqual(w.recovered, []);
});

test("no relay answering its ping: not probed, and its failures so far forgotten", async (t) => {
  const now = { probe: { ok: true } as Probed, status: CONNECTED, up: true };
  const w = watching(t, now);
  await settle(10);
  await w.tick(5); // (past its first two minutes)
  now.probe = { ok: false, stage: "endpoint_failed" };
  now.status = LOST;
  await w.tick(2);
  now.up = false;
  const probed = w.probes.length;
  await w.tick(10);
  assert.equal(w.probes.length, probed, "not probed while no relay answers");
  now.up = true;
  await w.tick(2);
  assert.deepEqual(w.recovered, [], "two failures after the relays answer again: the two before forgotten");
  await w.tick(1);
  assert.deepEqual(w.recovered, [w.at()], "the third");
});

test("a front or an addon from before, with no probe, is never recovered and not probed again", async (t) => {
  const now = { probe: new Error("no operation probeRelay") as Probed, status: LOST, up: true };
  const w = watching(t, now);
  await settle(10);
  await w.tick(20);
  assert.deepEqual(w.probes, [0], "asked once");
  assert.deepEqual(w.recovered, []);
});

test("a well endpoint is probed every fourth check; one its relays say is on none or held off for another of its key, every check", async (t) => {
  const now = { probe: { ok: true } as Probed, status: CONNECTED, up: true };
  const w = watching(t, now);
  await settle(10);
  await w.tick(8);
  assert.deepEqual(w.probes, [90_000, 210_000], "the 4th and 8th checks");
  now.status = [{ url: OURS, connected: true, access: OURS, conflict: true }];
  await w.tick(2);
  assert.deepEqual(w.probes.slice(2), [270_000, 300_000], "held off for another endpoint of its key: every check");
  now.status = LOST;
  await w.tick(2);
  assert.deepEqual(w.probes.slice(4), [330_000, 360_000], "on no relay: every check");
  assert.deepEqual(w.recovered, []);
});
