// The station kept on still.fail's relays (mesh/relays.ts) on an endpoint the front kept across a handover: the
// workspaces' own relays put in before it is kept on them, and iroh's public relays, which the process before may have
// turned on, taken off by the first check that finds still.fail's answering. The relays' pings are this test's fetch.
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { Clock, Effect, Fiber, Stream } from "effect";
import { fileRecoverStore, keepRelays, type RecoverState, type RecoverStore } from "../src/mesh/relays.ts";
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

/// keepRelays watching an endpoint whose probes find `now.probe` (or, by relay, `now.through`) and whose relays say
/// `now.status`; `answering` whether the relays answer their ping (`now.pinged`: only those named). `relays` still.fail's
/// (the first homed on). Every 30 s check is `tick()`; `t` the test's time since the start, `recovered` the times it was
/// told unhealthy, `probes` the times it was probed, `through` the relays each was probed through. `o.reach`: when it last
/// took a connection through a relay (`lastRelayReachAt`); `o.store` where its cooldown is kept; `o.start` the clock's
/// time it starts at (a process after another: `ready` once it has started).
function watching(
  t: TestContext,
  now: { probe: Probed; status: { url: string; connected: boolean; access: string; conflict?: boolean }[]; up: boolean; through?: Record<string, Probed>; pinged?: string[] },
  relays: string[] = [OURS],
  o: { reach?: { at: number | null }; store?: RecoverStore; start?: number } = {},
) {
  const recovered: number[] = [];
  const probes: number[] = [];
  const through: string[] = [];
  let at = o.start ?? 0;
  const bare = (u: string) => u.replace(/\/+$/, "");
  const endpoint = {
    home: () => relays[0],
    insertRelay: async () => {},
    removeRelay: async () => {},
    publicRelays: async () => {},
    keep: () => {},
    relayStatus: () => now.status,
    probeRelay: async (url: string) => {
      assert.ok(relays.some((r) => bare(r) === bare(url)), "probed through a relay kept");
      probes.push(at);
      through.push(bare(url));
      const found = now.through?.[bare(url)] ?? now.probe;
      if (found instanceof Error) throw found;
      return found;
    },
  } as unknown as Endpoint;
  const cloud = { data: mkdtempSync(join(tmpdir(), "keep-relays-")), state: null, relays: () => relays, memberships: () => [{ workspace: "w" }], waysSaid: () => ({ relays: [], off: [] }) };
  const fetched = globalThis.fetch;
  globalThis.fetch = (async (url: string) => {
    if (!now.up) throw new Error("unreachable");
    if (now.pinged !== undefined && !now.pinged.some((r) => String(url).startsWith(bare(r)))) throw new Error("unreachable");
    return new Response("pong");
  }) as typeof fetch;
  t.after(() => void (globalThis.fetch = fetched));
  const clock = testClock();
  const plane = { state: cloud, changes: Stream.never } as never;
  const watch = { onUnhealthy: () => void recovered.push(at), ...(o.reach ? { lastRelayReachAt: () => o.reach!.at } : {}), ...(o.store ? { recoverStore: o.store } : {}) };
  let fiber: Fiber.Fiber<unknown, unknown> | null = null;
  const start = () => void (fiber = Effect.runFork(keepRelays(endpoint, undefined, undefined, watch).pipe(Effect.provideService(ControlPlane, plane), Effect.provideService(Clock.Clock, clock.clock))));
  const stop = async () => {
    if (fiber !== null) await Effect.runPromise(Fiber.interrupt(fiber));
    fiber = null;
  };
  t.after(stop);
  const ready = o.start === undefined ? (start(), Promise.resolve()) : clock.adjust(o.start).then(start);
  const tick = async (n = 1) => {
    for (let i = 0; i < n; i++) {
      at += 30_000;
      await clock.adjust(30_000);
      await settle(10);
    }
  };
  return { recovered, probes, through, tick, at: () => at, ready, stop };
}

/// A `RecoverStore` in memory: `saved` each state it was given.
function memoryStore(kept: RecoverState | null = null) {
  const saved: (RecoverState | null)[] = [];
  const store: RecoverStore & { kept: RecoverState | null; saved: typeof saved } = {
    kept,
    saved,
    load: async () => store.kept,
    save: async (state) => {
      saved.push(state);
      store.kept = state;
    },
  };
  return store;
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

// ── more than one relay: a failure counts once a second relay corroborates it ──

const A = "https://relay.still.example";
const B = "https://b.still.example";
const C = "https://c.still.example";
const D = "https://d.still.example";
const E = "https://e.still.example";
const FAILED: Probed = { ok: false, stage: "endpoint_failed" };
const OFFLINE: Probed = { ok: false, stage: "probe_offline" };

test("a probe failing through one relay but answered through another never recovers it, and clears the failures so far", async (t) => {
  const now = { probe: { ok: true } as Probed, status: CONNECTED, up: true, through: {} as Record<string, Probed> };
  const w = watching(t, now, [OURS, B, C]);
  await settle(10);
  await w.tick(5); // (past its first two minutes)
  now.status = LOST;
  now.through = { [A]: FAILED, [B]: FAILED, [C]: FAILED };
  await w.tick(2);
  assert.deepEqual(w.recovered, [], "two failures, each through two relays");
  now.through = { [A]: FAILED, [B]: { ok: true } };
  const from = w.through.length;
  await w.tick(20);
  assert.deepEqual(w.through.slice(from, from + 4), [A, B, A, B], "the one homed on, then the next that answers");
  assert.deepEqual(w.recovered, [], "reached through another relay: never the endpoint's");
  now.through = { [A]: FAILED, [B]: FAILED, [C]: FAILED };
  await w.tick(2);
  assert.deepEqual(w.recovered, [], "the two failures before were cleared");
  await w.tick(1);
  assert.deepEqual(w.recovered, [w.at()]);
});

test("the first relay letting no probe on (over its quota), the next two failing: recovered as through one", async (t) => {
  const now = { probe: FAILED, status: LOST, up: true, through: { [A]: OFFLINE } as Record<string, Probed> };
  const w = watching(t, now, [OURS, B, C]);
  await settle(10);
  await w.tick(3);
  assert.deepEqual(w.through.slice(0, 3), [A, B, C], "past the one it could not get on, to two that answer");
  assert.deepEqual(w.recovered, [], "three failures, but within the first two minutes");
  await w.tick(1);
  assert.deepEqual(w.recovered, [2 * MIN]);
});

test("the first relay letting no probe on, the next reaching the endpoint: its failures cleared", async (t) => {
  const now = { probe: { ok: true } as Probed, status: CONNECTED, up: true, through: {} as Record<string, Probed> };
  const w = watching(t, now, [OURS, B, C]);
  await settle(10);
  await w.tick(5);
  now.status = LOST;
  now.through = { [A]: OFFLINE, [B]: FAILED, [C]: FAILED };
  await w.tick(2);
  assert.deepEqual(w.recovered, []);
  now.through = { [A]: OFFLINE, [B]: { ok: true } };
  await w.tick(1);
  now.through = { [A]: OFFLINE, [B]: FAILED, [C]: FAILED };
  await w.tick(2);
  assert.deepEqual(w.recovered, [], "the two failures before were cleared");
  await w.tick(1);
  assert.deepEqual(w.recovered, [w.at()]);
});

test("three relays failing in one check count once, on the same timeline", async (t) => {
  const now = { probe: FAILED, status: LOST, up: true };
  const w = watching(t, now, [OURS, B, C, D]);
  await settle(10);
  await w.tick(3);
  assert.deepEqual(w.probes, [0, 0, 0, 30_000, 30_000, 30_000, 60_000, 60_000, 60_000, 90_000, 90_000, 90_000], "three probes a check");
  assert.deepEqual(w.through.slice(0, 4), [A, B, C, D], "three relays agreeing: no fourth that check, the next starts at it");
  assert.deepEqual(w.recovered, []);
  await w.tick(1);
  assert.deepEqual(w.recovered, [2 * MIN]);
});

test("two relays failing in one check while a third reaches the endpoint: cleared in that check, never counted", async (t) => {
  const now = { probe: { ok: true } as Probed, status: LOST, up: true, through: { [A]: FAILED, [B]: FAILED } as Record<string, Probed> };
  const w = watching(t, now, [OURS, B, C]);
  await settle(10);
  assert.deepEqual(w.through, [A, B, C], "the third asked in the same check");
  assert.deepEqual(w.probes, [0, 0, 0]);
  await w.tick(60);
  assert.deepEqual(w.recovered, []);
});

test("only two relays, both failing: counted, as no other was left to ask", async (t) => {
  const now = { probe: FAILED, status: LOST, up: true };
  const w = watching(t, now, [OURS, B]);
  await settle(10);
  await w.tick(3);
  assert.deepEqual(w.probes, [0, 0, 30_000, 30_000, 60_000, 60_000, 90_000, 90_000]);
  assert.deepEqual(w.recovered, []);
  await w.tick(1);
  assert.deepEqual(w.recovered, [2 * MIN]);
});

test("two relays staying bad while a third reaches the endpoint: asked next, failures cleared, never recovered", async (t) => {
  const now = { probe: { ok: true } as Probed, status: LOST, up: true, through: { [A]: FAILED, [B]: FAILED } as Record<string, Probed> };
  const w = watching(t, now, [OURS, B, C, D]);
  await settle(10);
  await w.tick(60);
  assert.deepEqual(w.through.slice(0, 6), [A, B, C, A, B, C], "the two bad, then the third, which clears them");
  assert.ok(!w.through.includes(D));
  assert.deepEqual(w.recovered, []);
});

test("a relay the endpoint is connected to is asked before those it is not", async (t) => {
  const status: Status = [{ url: A, connected: false, access: A }, { url: B, connected: false, access: B }, { url: C, connected: true, access: C }];
  const now = { probe: { ok: true } as Probed, status, up: true, through: { [A]: FAILED, [B]: FAILED } as Record<string, Probed> };
  const w = watching(t, now, [OURS, B, C]);
  await settle(10);
  await w.tick(60);
  assert.ok(w.through.length > 0);
  assert.ok(w.through.every((r) => r === C), "only the connected one, which answers");
  assert.deepEqual(w.recovered, []);
});

test("two relays failing across checks, the others letting no probe on: still counted and recovered", async (t) => {
  const now = { probe: OFFLINE, status: LOST, up: true, through: { [A]: FAILED, [D]: FAILED } as Record<string, Probed> };
  const w = watching(t, now, [OURS, B, C, D, E]);
  await settle(10);
  await w.tick(3);
  assert.deepEqual(w.recovered, [], "within the first two minutes");
  await w.tick(1);
  assert.deepEqual(w.recovered, [2 * MIN]);
});

test("one relay failing while the next three let no probe on, more left unasked: not counted, the next check asks the one left", async (t) => {
  const now = { probe: OFFLINE, status: LOST, up: true, through: { [A]: FAILED } as Record<string, Probed> };
  const w = watching(t, now, [OURS, B, C, D, E]);
  await settle(10);
  await w.tick(60);
  assert.deepEqual(w.through.slice(0, 4), [A, B, C, D], "four probes a check at most");
  assert.deepEqual(w.through.slice(4, 8), [B, C, D, E], "the one that failed last, the one unasked now asked");
  assert.equal(w.probes.length, 61 * 4);
  assert.deepEqual(w.recovered, []);
});

test("one relay failing while no other answers its ping: counted, as with one relay", async (t) => {
  const now = { probe: FAILED, status: LOST, up: true, pinged: [OURS] };
  const w = watching(t, now, [OURS, B, C]);
  await settle(10);
  await w.tick(3);
  assert.deepEqual(w.probes, [0, 30_000, 60_000, 90_000]);
  assert.deepEqual(w.recovered, []);
  await w.tick(1);
  assert.deepEqual(w.recovered, [2 * MIN]);
});

// ── reached through a relay lately (`recentReachMs`) ──

test("a connection taken through a relay lately: not probed, never recovered; a minute without one, probed and recovered again", async (t) => {
  const reach = { at: null as number | null };
  const now = { probe: FAILED, status: LOST, up: true };
  const w = watching(t, now, [OURS], { reach });
  await settle(10);
  await w.tick(4); // (past its first two minutes)
  // A device reaches it through a relay at every check, though every probe would fail (a slow relay).
  const from = w.probes.length;
  for (let i = 0; i < 20; i++) {
    reach.at = w.at();
    await w.tick(1);
  }
  assert.equal(w.probes.length, from + 0, "not probed while it is reached through a relay");
  // (recovered once already at two minutes, from the four failures before)
  assert.deepEqual(w.recovered, [2 * MIN]);
  // No more connections: the last, 30 s before the last check, a minute before the next.
  await w.tick(1);
  assert.equal(w.probes.length, from + 1, "reached a minute ago: probed");
  await w.tick(20);
  assert.equal(w.recovered.length, 2, "an endpoint really stuck is still recovered");
});

test("a connection taken through a relay clears the probes' failures so far", async (t) => {
  const reach = { at: null as number | null };
  const now = { probe: { ok: true } as Probed, status: CONNECTED, up: true };
  const w = watching(t, now, [OURS], { reach });
  await settle(10);
  await w.tick(5); // (past its first two minutes)
  now.probe = FAILED;
  now.status = LOST;
  await w.tick(2);
  reach.at = w.at();
  await w.tick(1); // (skipped: the two failures forgotten)
  const probed = w.probes.length;
  await w.tick(2);
  assert.equal(w.probes.length, probed + 2);
  assert.deepEqual(w.recovered, [], "two failures after the connection: the two before forgotten");
  await w.tick(1);
  assert.deepEqual(w.recovered, [w.at()], "the third");
});

test("a LAN or direct connection is not a relay's: the watch goes on (FB-38)", async (t) => {
  // (`lastRelayReachAt` is moved only by a connection whose path is a relay's: mesh.ts, rig/main.ts; none here)
  const reach = { at: null as number | null };
  const now = { probe: FAILED, status: LOST, up: true };
  const w = watching(t, now, [OURS], { reach });
  await settle(10);
  await w.tick(4);
  assert.deepEqual(w.recovered, [2 * MIN]);
});

// ── the cooldown kept across processes (`recoverStore`) ──

test("the cooldown outlives the process: the next one keeps it past its first two minutes, then doubles it, and a well probe after it clears it", async (t) => {
  const store = memoryStore();
  const now = { probe: FAILED, status: LOST, up: true };
  const first = watching(t, now, [OURS], { store });
  await settle(10);
  await first.tick(4);
  assert.deepEqual(first.recovered, [2 * MIN]);
  assert.deepEqual(store.saved, [{ lastRecoverAt: 2 * MIN, cooldown: 10 * MIN }], "kept before it is told");
  await first.stop();
  // The front restarted: the next process, half a minute later, failing on.
  const next = watching(t, now, [OURS], { store, start: 2 * MIN + 30_000 });
  await next.ready;
  await settle(10);
  await next.tick(9); // (7 minutes: past its own first two, within the 10 minutes' cooldown)
  assert.deepEqual(next.recovered, [], "within the cooldown kept from the process before");
  await next.tick((12 * MIN - next.at()) / 30_000);
  assert.deepEqual(next.recovered, [12 * MIN], "once it is over");
  assert.deepEqual(store.kept, { lastRecoverAt: 12 * MIN, cooldown: 20 * MIN }, "doubled, and kept");
  // Well again, past the cooldown: nothing kept.
  now.probe = { ok: true };
  await next.tick(20 * MIN / 30_000);
  assert.deepEqual(store.kept, null);
  assert.equal(store.saved.at(-1), null);
});

test("a connection through a relay past the cooldown clears what is kept", async (t) => {
  const store = memoryStore({ lastRecoverAt: 0, cooldown: 20 * MIN });
  const reach = { at: null as number | null };
  const now = { probe: FAILED, status: LOST, up: true };
  const w = watching(t, now, [OURS], { store, reach, start: 5 * MIN });
  await w.ready;
  await settle(10);
  reach.at = w.at();
  await w.tick(1);
  assert.deepEqual(store.kept, { lastRecoverAt: 0, cooldown: 20 * MIN }, "within its cooldown: kept");
  // (reached at every check until its cooldown is over, at 20 minutes)
  while (w.at() < 20 * MIN) {
    reach.at = w.at();
    await w.tick(1);
  }
  assert.equal(store.kept, null, "past its cooldown: cleared");
  assert.deepEqual(store.saved, [null]);
  assert.deepEqual(w.recovered, []);
});

test("a kept cooldown long over, or from the future, is not kept; one out of bounds is held to them", async (t) => {
  const now = { probe: FAILED, status: LOST, up: true };
  // (long over: more than twice the longest cooldown ago)
  const old = watching(t, now, [OURS], { store: memoryStore({ lastRecoverAt: 0, cooldown: 60 * MIN }), start: 121 * MIN });
  await old.ready;
  await settle(10);
  await old.tick(4);
  assert.deepEqual(old.recovered, [121 * MIN + 2 * MIN]);
  await old.stop();
  // (from the future: a clock that went back)
  const ahead = watching(t, now, [OURS], { store: memoryStore({ lastRecoverAt: 10 * MIN, cooldown: 10 * MIN }) });
  await settle(10);
  await ahead.tick(4);
  assert.deepEqual(ahead.recovered, [2 * MIN]);
  await ahead.stop();
  // (a cooldown of a day: held to the longest, an hour)
  const long = watching(t, now, [OURS], { store: memoryStore({ lastRecoverAt: 0, cooldown: 24 * 60 * MIN }), start: MIN });
  await long.ready;
  await settle(10);
  await long.tick((61 * MIN - MIN) / 30_000);
  assert.deepEqual(long.recovered, [60 * MIN]);
});

test("the cooldown's file: written whole, read back, removed; one unreadable is none", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "relay-recover-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const path = join(dir, "run", "relay-probe-recover.json");
  const store = fileRecoverStore(path);
  assert.equal(await store.load(), null, "none yet");
  await store.save({ lastRecoverAt: 123, cooldown: 600_000 });
  assert.deepEqual(await store.load(), { lastRecoverAt: 123, cooldown: 600_000 });
  await store.save(null);
  assert.equal(existsSync(path), false);
  await store.save(null);
  assert.equal(await store.load(), null, "removed twice: still none");
  writeFileSync(path, "{not json");
  assert.equal(await store.load(), null, "broken: none");
  writeFileSync(path, JSON.stringify({ lastRecoverAt: "soon", cooldown: 1 }));
  assert.equal(await store.load(), null, "not numbers: none");
});
