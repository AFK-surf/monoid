// Monotonic publication sequence for progress settings (`progress.set` / `settingsView.progressSeq`)
// and monotonic edit revision for profile flow (`profile.flow.edit` / `ProfileFlowView.rev`).
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect } from "effect";
import type { Inner } from "../src/core.ts";
import { parseCall } from "../src/core/calls.ts";
import { handlers } from "../src/core/execute.ts";
import { CoreError } from "../src/error.ts";
import { ProfileFlows } from "../src/forms.ts";
import { holdLanguage } from "../src/i18n.ts";
import { type ProgressPrefs, newerProgress, progressOf } from "../src/progress-prefs.ts";
import { type Store } from "../src/store.ts";
import { type ProgressViews, install } from "../src/views/progress.ts";
type Topic = Parameters<Store["value"]>[0];
import { settingsView } from "../src/views/settings.ts";

holdLanguage();

type Rig = { address: string; kept: Map<string, ProgressPrefs> };

function makeProgressHarness(rigs: Rig[], owners: Record<string, string>) {
  let clockNow = 10_000;
  const records = new Map<string, unknown>();
  const queue: Effect.Effect<unknown, unknown>[] = [];
  const also: { read: (a: string) => Effect.Effect<void, CoreError>; event: (a: string, n: string, d: unknown) => void; resumed: (a: string) => Effect.Effect<void, CoreError> }[] = [];
  const inner = {
    provider: { kind: "stillfail" },
    data: {
      record: (t: string, k: string) => records.get(`${t}:${k}`),
      put: (t: string, k: string, v: unknown) => void records.set(`${t}:${k}`, v),
      shared: (topic: { workspace: string }) => ({
        stations: rigs.filter((s) => s.address.startsWith(`${topic.workspace}/`)).map((s) => ({ id: s.address.split("/")[1] })),
      }),
    },
    stations: {
      also,
      link: (a: string) => ({ addr: { toString: () => a } }),
      reachable: () => true,
      requests: {
        call: (addr: { toString(): string }, method: string, _path: string, body: { progress: unknown } | null) =>
          Effect.suspend((): Effect.Effect<{ progress: ProgressPrefs | null }, CoreError> => {
            const s = rigs.find((x) => x.address === addr.toString())!;
            const sub = owners[s.address.split("/")[0]!]!;
            if (method === "GET") return Effect.succeed({ progress: s.kept.get(sub) ?? null });
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
    host: { nowMs: () => clockNow++ },
  } as unknown as Inner;
  const views: ProgressViews = install(inner);
  (inner as { progress: ProgressViews }).progress = views;
  const settle = async () => {
    while (queue.length > 0) await Effect.runPromise(Effect.ignore(queue.shift()!));
  };
  return {
    views,
    read: async (s: Rig) => {
      await Effect.runPromise(also[0]!.read(s.address));
      await settle();
    },
    set: async (workspace: string, params: object) => {
      const done = await Effect.runPromise(
        handlers.progress!(inner, parseCall("progress.set", { workspace, ...params }), (() => {}) as never, ["c", 1] as never, null as never),
      );
      await settle();
      return done as { ok: boolean; seq: number };
    },
  };
}

test("progress.set returns strictly monotonic seq, no-op returns current seq, and settingsView carries progressSeq", async () => {
  const s1: Rig = { address: "ws1/st1", kept: new Map() };
  const h = makeProgressHarness([s1], { ws1: "u1" });
  assert.equal(h.views.shown("ws1").seq, 1);
  assert.equal(settingsView(h.views.shown("ws1"), []).progressSeq, 1);

  const r1 = await h.set("ws1", { minutes: 20 });
  assert.deepEqual(r1, { ok: true, seq: 2 });
  assert.equal(settingsView(h.views.shown("ws1"), []).progressSeq, 2);

  // No-op write returns the current seq without incrementing.
  const rNoop = await h.set("ws1", { minutes: 20 });
  assert.deepEqual(rNoop, { ok: true, seq: 2 });
  assert.equal(settingsView(h.views.shown("ws1"), []).progressSeq, 2);

  const r2 = await h.set("ws1", { strength: "remind" });
  assert.deepEqual(r2, { ok: true, seq: 3 });
  assert.equal(settingsView(h.views.shown("ws1"), []).progressSeq, 3);
});

test("multi-device same-rev tie-break via newerProgress advances progressSeq monotonically", async () => {
  const s1: Rig = { address: "ws1/st1", kept: new Map() };
  const h = makeProgressHarness([s1], { ws1: "u1" });
  // Seed station with rev=50000, at=100, minutes=10.
  s1.kept.set("u1", progressOf({ minutes: 10, strength: "require", rev: 50_000, at: 100 }));
  await h.read(s1);
  const seqAfterFirst = h.views.shown("ws1").seq;
  assert.equal(seqAfterFirst, 2);
  assert.equal(h.views.shown("ws1").minutes, 10);

  // Another device wins a same-rev (50000) tie-break with a later `at` (200) and minutes=60.
  s1.kept.set("u1", progressOf({ minutes: 60, strength: "remind", rev: 50_000, at: 200 }));
  await h.read(s1);
  const afterTieBreak = h.views.shown("ws1");
  assert.equal(afterTieBreak.minutes, 60);
  assert.equal(afterTieBreak.strength, "remind");
  assert.equal(afterTieBreak.seq, seqAfterFirst + 1);
  assert.equal(settingsView(afterTieBreak, []).progressSeq, seqAfterFirst + 1);
});

test("ProfileFlows.change returns monotonic rev on edit and profileView exposes rev", () => {
  const overview = {
    updates: [{ id: "claude" }, { id: "codex" }],
    apiProviders: [{ id: "custom" }, { id: "moonshotai" }],
    consoleSignIn: false,
    profileServices: [],
  };
  let invalidated = 0;
  const store = {
    value: (t: Topic) => {
      if (t.topic === "overview") return { ok: overview };
      if (t.topic === "workspace") return { ok: { role: "owner" } };
      return undefined;
    },
    invalidate: () => {
      invalidated += 1;
    },
  } as unknown as Store;
  const flows = new ProfileFlows(store);
  const topic: Topic = { topic: "profileFlow", station: "ws1/st1", form: "f1" };

  flows.change(topic, 1, "open", {});
  const v0 = flows.value(topic);
  assert.equal(v0.rev, 1);

  const e1 = flows.change(topic, 1, "edit", { provider: "custom" });
  assert.deepEqual(e1, { rev: 2 });
  assert.equal(flows.value(topic).rev, 2);

  const e2 = flows.change(topic, 1, "edit", { protocol: "responses" });
  assert.deepEqual(e2, { rev: 3 });
  assert.equal(flows.value(topic).rev, 3);
  assert.equal(flows.value(topic).protocol, "responses");

  const e3 = flows.change(topic, 1, "edit", { protocol: "chat_completions" });
  assert.deepEqual(e3, { rev: 4 });
  assert.equal(flows.value(topic).rev, 4);
  assert.ok(invalidated >= 4);
});
