// How a person's agents are asked for progress, carried by their own devices (src/views/progress.ts) to every station of
// every workspace of theirs, over the station's own route (station/src/api/routes/progress.ts).
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect } from "effect";
import type { Inner } from "../src/core.ts";
import { parseCall } from "../src/core/calls.ts";
import { handlers } from "../src/core/execute.ts";
import { CoreError } from "../src/error.ts";
import { type ProgressPrefs, newerProgress, progressOf } from "../src/progress-prefs.ts";
import { computed } from "../src/reactive.ts";
import { type ProgressViews, install } from "../src/views/progress.ts";

const clock = { now: 1_000 };

/// A station of `ws`: what it keeps of each person; one from before has no route, one refuses a read-only member's.
type Rig = { address: string; kept: Map<string, ProgressPrefs>; before?: boolean; readOnly?: boolean };
const rig = (address: string, more: Partial<Rig> = {}): Rig => ({ address, kept: new Map(), ...more });

function device(rigs: Rig[], owners: Record<string, string>) {
  const records = new Map<string, unknown>();
  const up = new Set(rigs.map((s) => s.address));
  const queue: Effect.Effect<unknown, unknown>[] = [];
  const asked: string[] = [];
  const also: { read: (a: string) => Effect.Effect<void, CoreError>; event: (a: string, n: string, d: unknown) => void; resumed: (a: string) => Effect.Effect<void, CoreError> }[] = [];
  const inner = {
    provider: { kind: "stillfail" },
    data: {
      record: (t: string, k: string) => records.get(`${t}:${k}`),
      put: (t: string, k: string, v: unknown) => void records.set(`${t}:${k}`, v),
      shared: (topic: { workspace: string }) => ({ stations: rigs.filter((s) => s.address.startsWith(`${topic.workspace}/`)).map((s) => ({ id: s.address.split("/")[1] })) }),
    },
    stations: {
      also,
      link: (a: string) => ({ addr: { toString: () => a } }),
      reachable: (a: string) => up.has(a),
      requests: {
        call: (addr: { toString(): string }, method: string, path: string, body: { progress: unknown } | null) =>
          Effect.suspend((): Effect.Effect<{ progress: ProgressPrefs | null }, CoreError> => {
            const s = rigs.find((x) => x.address === addr.toString())!;
            const sub = owners[s.address.split("/")[0]!]!;
            asked.push(`${method} ${s.address}`);
            assert.equal(path, "/progress");
            if (!up.has(s.address)) return Effect.fail(new CoreError("offline", "not reached"));
            if (s.before) return Effect.fail(new CoreError("http_404", "no route GET /progress", 404));
            if (method === "GET") return Effect.succeed({ progress: s.kept.get(sub) ?? null });
            if (s.readOnly) return Effect.fail(new CoreError("http_403", "read-only", 403));
            const given = progressOf(body!.progress);
            const was = s.kept.get(sub);
            s.kept.set(sub, was ? newerProgress(was, given) : given);
            return Effect.succeed({ progress: s.kept.get(sub)! });
          }),
      },
    },
    scheduler: { enqueue: (_l: string, _k: string, _p: number, e: Effect.Effect<unknown, unknown>) => void queue.push(e) },
    workspaces: { owner: (ws: string) => owners[ws] ?? null, owned: () => Object.entries(owners) },
    accounts: { list: () => [] },
    host: { nowMs: () => clock.now++ },
  } as unknown as Inner;
  const views: ProgressViews = install(inner);
  (inner as { progress: ProgressViews }).progress = views;
  const settle = async () => {
    while (queue.length > 0) await Effect.runPromise(Effect.ignore(queue.shift()!));
  };
  return {
    asked,
    up,
    shown: (ws: string) => (({ minutes, strength }) => ({ minutes, strength }))(views.shown(ws)),
    read: async (s: Rig) => (await Effect.runPromise(also[0]!.read(s.address)), await settle()),
    resumed: async (s: Rig) => (up.add(s.address), await Effect.runPromise(also[0]!.resumed(s.address)), await settle()),
    tell: async (s: Rig) => (also[0]!.event(s.address, "progress", { workspace: s.address.split("/")[0] }), await settle()),
    set: async (workspace: string, params: object) => {
      const done = await Effect.runPromise(Effect.result(handlers.progress!(inner, parseCall("progress.set", { workspace, ...params }), (() => {}) as never, ["c", 1] as never, null as never)));
      await settle();
      return done._tag;
    },
  };
}

test("a change reaches every station of every workspace the same account reaches, and their other devices", async () => {
  const [a, b, c, other] = [rig("w1/a"), rig("w1/b"), rig("w2/c"), rig("w3/d")];
  const mine = device([a, b, c, other], { w1: "me", w2: "me", w3: "else" });
  assert.deepEqual(mine.shown("w1"), { minutes: 10, strength: "require" });
  // (what shows it follows it: read once, changed below)
  const seen = computed(() => mine.shown("w2").minutes);
  assert.equal(seen.get(), 10);
  mine.up.delete("w1/b");
  assert.equal(await mine.set("w1", { minutes: 30 }), "Success");
  assert.equal(await mine.set("w1", { strength: "remind" }), "Success");
  assert.equal(seen.get(), 30);
  for (const ws of ["w1", "w2"]) assert.deepEqual(mine.shown(ws), { minutes: 30, strength: "remind" });
  assert.deepEqual(mine.shown("w3"), { minutes: 10, strength: "require" });
  for (const s of [a, c]) assert.deepEqual([s.kept.get("me")?.minutes, s.kept.get("me")?.strength], [30, "remind"]);
  assert.deepEqual([b.kept.size, other.kept.size], [0, 0]);
  // (the one away is brought it as its stream comes back, once)
  await mine.resumed(b);
  assert.equal(b.kept.get("me")?.minutes, 30);
  const at = mine.asked.length;
  await mine.resumed(b);
  assert.equal(mine.asked.length, at);

  const phone = device([a, b, c, other], { w1: "me", w2: "me" });
  await phone.read(c);
  assert.deepEqual(phone.shown("w1"), { minutes: 30, strength: "remind" });
  await phone.set("w2", { minutes: 5 });
  await mine.tell(a);
  assert.deepEqual(mine.shown("w2"), { minutes: 5, strength: "remind" });
});

test("the last change wins, though its device had not heard of the others", async () => {
  const a = rig("w1/a");
  const phone = device([a], { w1: "me" });
  for (const minutes of [20, 30, 60]) await phone.set("w1", { minutes });
  const laptop = device([a], { w1: "me" });
  laptop.up.delete("w1/a");
  await laptop.set("w1", { minutes: 5 });
  await laptop.resumed(a);
  assert.equal(laptop.shown("w1").minutes, 5);
  await phone.tell(a);
  assert.equal(phone.shown("w1").minutes, 5);
});

test("a station from before and a read-only member's are owed nothing; what is not offered is refused", async () => {
  const [old, view] = [rig("w1/a", { before: true }), rig("w1/b", { readOnly: true })];
  const d = device([old, view], { w1: "me" });
  assert.equal(await d.set("w1", { minutes: 0 }), "Failure");
  assert.equal(await d.set("w1", { strength: "loud" }), "Failure");
  await d.set("w1", { minutes: 20 });
  assert.deepEqual(d.shown("w1"), { minutes: 20, strength: "require" });
  const at = d.asked.length;
  for (const s of [old, view]) await d.resumed(s);
  assert.equal(d.asked.length, at);
});
