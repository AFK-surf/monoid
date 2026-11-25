// Tests for A2 (`keepStationMemory` uncached put) and A4 (`mergePace`, v2 delta, structural sharing, reconnect catch-up).
import assert from "node:assert/strict";
import { test } from "node:test";
import { Data } from "../src/data.ts";
import { Runner } from "../src/runtime.ts";
import { mergePace } from "../src/station/sync.ts";
import { FakeHost, flush } from "../src/testing.ts";
import { apply, subscribe, v } from "./helpers.ts";
import { run } from "./run.ts";
import { base, overview, started, stationReplies } from "./station-fixture.ts";

// deno-lint-ignore no-explicit-any
type J = any;

test("keepStationMemory writes to SQLite without stale cache and stationMemory reads latest value", async () => {
  const host = new FakeHost();
  const runner = new Runner(host.time.clock);
  const data = new Data(host, runner, { owner: () => "me" });
  await run(data.open(["me"]));
  const st = "ws/st1";
  // Populate DB and cache via initial write + stationMemory read.
  data.keepStationMemory(st, "profilePace", { nowAt: 100, profiles: { a: { quotas: [], spend: [] } } });
  const first = data.stationMemory(st, "profilePace");
  assert.deepEqual(first, { nowAt: 100, profiles: { a: { quotas: [], spend: [] } } });
  // Update via keepStationMemory (cache=false deletes old cache entry so next read hits SQLite).
  data.keepStationMemory(st, "profilePace", { nowAt: 200, profiles: { a: { quotas: [{ hour: 1, at: 200, windows: [] }], spend: [] } } });
  const second = data.stationMemory(st, "profilePace");
  assert.deepEqual(second, { nowAt: 200, profiles: { a: { quotas: [{ hour: 1, at: 200, windows: [] }], spend: [] } } });
  await flush();
  // A fresh Data instance over the same SQLite DB also reads the latest value.
  const data2 = new Data(host, runner, { owner: () => "me" });
  await run(data2.open(["me"]));
  assert.deepEqual(data2.stationMemory(st, "profilePace"), second);
  runner.shutdown();
});

test("mergePace handles unchanged, profile-level delta reference reuse, base mismatch refetch, old station structural sharing, and nowAt-only noop", () => {
  const pA = { quotas: [{ hour: 10, at: 1000, windows: [] }], spend: [{ hour: 10, scope: "", weight: 1 }] };
  const pB = { quotas: [{ hour: 10, at: 1000, windows: [] }], spend: [{ hour: 10, scope: "", weight: 2 }] };
  const speedHours = [{ at: 10, model: "claude-opus-5-5", output: 100, ms: 1000 }];
  const speedQuarters = [{ at: 40, model: "claude-opus-5-5", output: 100, ms: 1000 }];
  const prev = { nowAt: 1000, fromHour: 1, profiles: { a: pA, b: pB }, speedHours, speedQuarters };

  // 1. unchanged
  const rUnch = mergePace(prev, { unchanged: true, rev: "e1:s1:1" }, "e1:s1:1");
  assert.equal(rUnch.kind, "unchanged");
  if (rUnch.kind === "unchanged") {
    assert.equal(rUnch.value, prev);
    assert.equal(rUnch.rev, "e1:s1:1");
  }

  // 2. profile-level delta reuses exact reference for kept profile and drops removed profile
  const pB2 = { quotas: [{ hour: 11, at: 2000, windows: [] }], spend: [{ hour: 11, scope: "", weight: 5 }] };
  const rDelta = mergePace(prev, {
    delta: true,
    base: "e1:s1:1",
    rev: "e1:s1:2",
    nowAt: 2000,
    fromHour: 1,
    keep: ["a"],
    profiles: { b: pB2 },
  }, "e1:s1:1");
  assert.equal(rDelta.kind, "merged");
  if (rDelta.kind === "merged") {
    assert.equal(rDelta.changed, true);
    assert.equal(rDelta.rev, "e1:s1:2");
    const val = rDelta.value as J;
    assert.equal(val.profiles.a, pA, "kept profile reuses exact reference");
    assert.equal(val.profiles.b, pB2);
    assert.equal(val.speedHours, speedHours, "omitted speedHours reuses reference");
    assert.equal(val.speedQuarters, speedQuarters, "omitted speedQuarters reuses reference");
  }

  // 3. delta with only nowAt changed -> changed: false
  const rDeltaNowOnly = mergePace(prev, {
    delta: true,
    base: "e1:s1:1",
    rev: "e1:s1:2",
    nowAt: 9999,
    fromHour: 1,
    keep: ["a", "b"],
    profiles: {},
  }, "e1:s1:1");
  assert.equal(rDeltaNowOnly.kind, "merged");
  if (rDeltaNowOnly.kind === "merged") {
    assert.equal(rDeltaNowOnly.changed, false);
    assert.equal(rDeltaNowOnly.value, prev);
    assert.equal(rDeltaNowOnly.rev, "e1:s1:2");
  }

  // 4. base mismatch or missing keep ID -> refetch
  assert.deepEqual(mergePace(prev, { delta: true, base: "e1:s1:999", rev: "e1:s1:1000", keep: ["a"], profiles: {} }, "e1:s1:1"), { kind: "refetch" });
  assert.deepEqual(mergePace(prev, { delta: true, base: "e1:s1:1", rev: "e1:s1:2", keep: ["missing"], profiles: {} }, "e1:s1:1"), { kind: "refetch" });

  // 5. Malformed v2 responses: mismatched/empty unchanged rev, missing/empty/same-as-base delta rev, or full response missing profiles trigger refetch
  assert.deepEqual(mergePace(prev, { unchanged: true, rev: "e1:s1:2" }, "e1:s1:1"), { kind: "refetch" });
  assert.deepEqual(mergePace(prev, { unchanged: true, rev: "e1:s1:1" }, null), { kind: "refetch" });
  assert.deepEqual(mergePace(prev, { unchanged: true, rev: "" }, ""), { kind: "refetch" });
  assert.deepEqual(mergePace(prev, { delta: true, base: "e1:s1:1", keep: ["a"], profiles: {} }, "e1:s1:1"), { kind: "refetch" });
  assert.deepEqual(mergePace(prev, { delta: true, base: "e1:s1:1", rev: "", keep: ["a"], profiles: {} }, "e1:s1:1"), { kind: "refetch" });
  assert.deepEqual(mergePace(prev, { delta: true, base: "e1:s1:1", rev: "e1:s1:1", keep: [], profiles: {} }, "e1:s1:1"), { kind: "refetch" });
  assert.deepEqual(mergePace(prev, { rev: "e1:s1:2", nowAt: 2000, fromHour: 1, speedHours: [], speedQuarters: [] }, "e1:s1:1"), { kind: "refetch" });
  const emptyRevFull = mergePace(undefined, { rev: "", nowAt: 1000, fromHour: 1, profiles: {} }, null);
  assert.equal(emptyRevFull.kind, "merged");
  if (emptyRevFull.kind === "merged") assert.equal(emptyRevFull.rev, null, "empty rev string is not kept as a v2 token");

  // 6. Full response from old station (no rev): structural sharing per profile + nowAt-only noop
  const oldSame = mergePace(prev, {
    nowAt: 5000,
    fromHour: 1,
    profiles: {
      a: { quotas: [{ hour: 10, at: 1000, windows: [] }], spend: [{ hour: 10, scope: "", weight: 1 }] },
      b: { quotas: [{ hour: 10, at: 1000, windows: [] }], spend: [{ hour: 10, scope: "", weight: 2 }] },
    },
    speedHours: [{ at: 10, model: "claude-opus-5-5", output: 100, ms: 1000 }],
    speedQuarters: [{ at: 40, model: "claude-opus-5-5", output: 100, ms: 1000 }],
  }, null);
  assert.equal(oldSame.kind, "merged");
  if (oldSame.kind === "merged") {
    assert.equal(oldSame.changed, false, "nowAt-only full response reports changed=false");
    assert.equal(oldSame.value, prev);
  }

  const oldPartial = mergePace(prev, {
    nowAt: 5000,
    fromHour: 1,
    profiles: {
      a: { quotas: [{ hour: 10, at: 1000, windows: [] }], spend: [{ hour: 10, scope: "", weight: 1 }] },
      b: { quotas: [{ hour: 10, at: 1000, windows: [] }], spend: [{ hour: 10, scope: "", weight: 9 }] },
    },
    speedHours: [{ at: 10, model: "claude-opus-5-5", output: 100, ms: 1000 }],
    speedQuarters: [{ at: 40, model: "claude-opus-5-5", output: 100, ms: 1000 }],
  }, null);
  assert.equal(oldPartial.kind, "merged");
  if (oldPartial.kind === "merged") {
    assert.equal(oldPartial.changed, true);
    const val = oldPartial.value as J;
    assert.equal(val.profiles.a, pA, "unchanged profile reused by reference");
    assert.equal(val.profiles.b.quotas, pB.quotas, "unchanged quotas reused by reference");
    assert.equal(val.speedHours, speedHours);
    assert.equal(val.speedQuarters, speedQuarters);
  }
});

test("client sends v=2 with sinceRev, falls back on base mismatch, and catches up profilePace on reconnect", async () => {
  const H = 3_600_000;
  const WEEK = 10_080;
  const seenUrls: string[] = [];
  let mode: "full1" | "unchanged" | "badDelta" | "full2" = "full1";
  const profile = (now: number) => ({
    id: "p1", name: "p1@x.com", email: "p1@x.com", runtime: "claude", runtimes: ["claude"], access: { kind: "subscription", key: "" }, home: "/h",
    homeExists: true, model: null, models: [], env: [], usedBy: [], loginCommand: "", planText: "Max 20x",
    check: { state: "ok", detail: "", checkedAt: 1 },
    quota: { state: "ok", windows: [{ label: "每周", usedPercent: 40, resetsAt: now + 100 * H, minutes: WEEK }], detail: null, checkedAt: now },
  });
  const { host, core, end } = await started(base(), 0, undefined, (s) => stationReplies(s.host, (req) => {
    const now = s.host.nowMs();
    const u = new URL(req.url);
    if (u.pathname.endsWith("/admin/api/overview")) return { ...overview, profiles: [profile(now)] };
    if (!u.pathname.endsWith("/admin/api/profiles/pace")) return undefined;
    seenUrls.push(u.pathname + u.search);
    const sinceRev = u.searchParams.get("sinceRev");
    if (mode === "full1") {
      return { rev: "e1:s1:1", nowAt: now, fromHour: 0, profiles: { p1: { quotas: [], spend: [{ hour: Math.floor(now / H) - 2, scope: "", weight: 3 }] } }, speedHours: [], speedQuarters: [] };
    }
    if (mode === "unchanged") {
      return { unchanged: true, rev: "e1:s1:1" };
    }
    if (mode === "badDelta" && sinceRev !== null) {
      return { delta: true, base: "wrong:rev:0", rev: "e1:s1:2", nowAt: now, fromHour: 0, keep: ["p1"], profiles: {} };
    }
    return { rev: "e1:s1:2", nowAt: now, fromHour: 0, profiles: { p1: { quotas: [], spend: [{ hour: Math.floor(now / H) - 2, scope: "", weight: 9 }] } }, speedHours: [], speedQuarters: [] };
  }));
  const ui = core.connect();
  const values = new Map();
  subscribe(core, ui, 1, { topic: "profilesOverview", scope: "ws" });
  await host.settle();
  apply(host, values);
  assert.ok(Array.isArray(v(values, 1)?.pools));
  assert.equal(seenUrls.at(-1), "/admin/api/profiles/pace?v=2");

  // Trigger reconnect catch-up while profilesOverview is open: should send sinceRev=e1:s1:1 and get unchanged.
  mode = "unchanged";
  end();
  await host.time.pass(2_500, 50);
  await host.settle();
  assert.ok(seenUrls.some((u) => u === "/admin/api/profiles/pace?v=2&sinceRev=e1%3As1%3A1"), `expected sinceRev request, got ${seenUrls.join(", ")}`);

  // Trigger reconnect with base mismatch delta -> should automatically refetch without sinceRev once.
  const beforeMismatch = seenUrls.length;
  mode = "badDelta";
  end();
  await host.time.pass(4_000, 50);
  await host.settle();
  const afterMismatch = seenUrls.slice(beforeMismatch);
  assert.ok(afterMismatch.includes("/admin/api/profiles/pace?v=2&sinceRev=e1%3As1%3A1"), `got ${afterMismatch.join(", ")}`);
  assert.ok(afterMismatch.includes("/admin/api/profiles/pace?v=2"), `expected fallback full refetch, got ${afterMismatch.join(", ")}`);
  core.close();
});
