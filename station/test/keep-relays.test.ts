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
