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
import { ControlPlane } from "../src/services.ts";
import type { Endpoint } from "../src/mesh/native.ts";
import { settle, testClock } from "./hub-fakes.ts";

const OURS = "https://relay.still.example/";
const THEIRS = "https://relay.workspace.example";

/// keepRelays run on an endpoint that says what it is asked; `answering` whether still.fail's relays answer a ping.
function keeping(t: TestContext, answering: { now: boolean }) {
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
    waysSaid: () => ({ relays: [THEIRS], off: [] }),
  };
  const fetched = globalThis.fetch;
  globalThis.fetch = (async (url: string) => {
    if (!answering.now || !String(url).startsWith(OURS)) throw new Error("unreachable");
    return new Response("pong");
  }) as typeof fetch;
  t.after(() => void (globalThis.fetch = fetched));
  const clock = testClock();
  const plane = { state: cloud, changes: Stream.never } as never;
  const fiber = Effect.runFork(keepRelays(endpoint).pipe(Effect.provideService(ControlPlane, plane), Effect.provideService(Clock.Clock, clock.clock)));
  t.after(() => Effect.runPromise(Fiber.interrupt(fiber)));
  return { asked, clock };
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
