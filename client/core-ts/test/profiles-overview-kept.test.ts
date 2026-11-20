// The Profile overview's pools made again as one station's hours come (views/profiles-overview.ts `poolKept`): a pool
// none of whose accounts changed is the one made before, within the minute, and every pool is what one made anew
// would be. As stations came back on a phone, each one's overview or hours made every pool again, 6-18 times in a row,
// 154-903 ms each (0.1.10103-10130), each pool a week's simulation searched over a dozen times.
import assert from "node:assert/strict";
import { test } from "node:test";
import { profilesOverview } from "../src/views/profiles-overview.ts";

// deno-lint-ignore no-explicit-any
type J = any;
const H = 3_600_000;
const HOUR0 = 500_000;
/// Now: twenty minutes past an hour, the viewer at UTC+8.
const NOW = HOUR0 * H + H / 3;
const OFFSET = 480;
const WEEK = 10_080;

const week = (used: number, resetsInH: number, scope = "") => ({ label: scope === "" ? "每周" : `每周 · ${scope}`, usedPercent: used, resetsAt: NOW + resetsInH * H, minutes: WEEK, ...(scope ? { scope } : {}) });
const five = (used: number, resetsInH: number | null, scope = "") => ({ label: "5 小时", usedPercent: used, resetsAt: resetsInH === null ? null : NOW + resetsInH * H, minutes: 300, ...(scope ? { scope } : {}) });
const account = (id: string, group: string, station: string, windows: J[], planText = "Max 20x") => ({
  key: id, group, usable: true, look: false, state: null,
  profile: { id, planText, checkTone: "green", quota: { state: "ok", windows, checkedAt: NOW } },
  members: [{ station, profileId: id }],
});
/// A station's accounts' hours: read 24 and 12 hours back, and spent an hour at a time for the last two days (`rate`).
const paceOf = (ids: string[], rate: number, windows: (id: string, back: number) => J[]) => ({
  nowAt: NOW,
  profiles: Object.fromEntries(ids.map((id) => [id, {
    quotas: [24, 12].map((back) => ({ hour: HOUR0 - back, at: NOW - back * H, windows: windows(id, back) })),
    spend: Array.from({ length: 48 }, (_, h) => ({ hour: HOUR0 - h, scope: "", weight: rate * (1 + (h % 5)) })),
  }])),
});

/// A workspace's accounts of three pools on three stations: Claude's (and Fable's) on one, Codex's on another, Gemini's
/// on a third; what each station says of their hours.
function workspace() {
  const claude = ["c0", "c1", "c2", "c3"].map((id, i) => account(id, "claude", "ws/one", [five(10 * i, 2), week(30 + 15 * i, 30 + 20 * i), week(40 + 10 * i, 30 + 20 * i, "Fable")], i % 2 === 0 ? "Max 20x" : "Max 5x"));
  const codex = ["x0", "x1", "x2"].map((id, i) => account(id, "chatgpt", "ws/two", [five(20 * i, 3), week(50 + 20 * i, 60 + 30 * i)], "Pro"));
  const gemini = ["g0", "g1"].map((id, i) => account(id, "agy", "ws/three", [week(60 + 10 * i, 90, "gemini"), five(30, 2, "gemini")], "Ultra"));
  const items = [...claude, ...codex, ...gemini];
  const paces: Record<string, J> = {
    "ws/one": paceOf(claude.map((a) => a.key), 0.4, (id, back) => [week(Math.max(0, 30 - back), 60)]),
    "ws/two": paceOf(codex.map((a) => a.key), 0.6, (id, back) => [week(Math.max(0, 50 - back), 90)]),
    "ws/three": paceOf(gemini.map((a) => a.key), 0.3, (id, back) => [week(Math.max(0, 60 - back), 90, "gemini")]),
  };
  return { items, paces };
}

const time = (f: () => unknown): number => {
  const from = performance.now();
  f();
  return performance.now() - from;
};

test("one_stations_hours_coming_make_its_pools_again_alone_and_every_pool_as_one_made_anew", () => {
  const { items, paces } = workspace();
  const pace = (station: string) => paces[station];
  const first = profilesOverview(items, pace, NOW, OFFSET).pools;
  assert.deepEqual(first.map((p) => p.title), ["Claude", "Fable", "Codex", "Gemini"]);
  assert.ok(first.every((p) => p.overPace || p.exhaustHours === null), "(a pool of each kind)");
  // The Codex station's hours come again, more spent: its pool alone made again, a few seconds on.
  const later = NOW + 7_000;
  paces["ws/two"] = paceOf(["x0", "x1", "x2"], 1.4, (id, back) => [week(Math.max(0, 50 - 2 * back), 90)]);
  let kept: J[] = [];
  const keptMs = time(() => (kept = profilesOverview(items, pace, later, OFFSET).pools));
  let fresh: J[] = [];
  const freshMs = time(() => (fresh = profilesOverview(items, pace, later, OFFSET, true).pools));
  for (const [i, p] of kept.entries()) {
    if (p.title === "Codex") assert.notEqual(p, first[i], "Codex made again");
    else assert.equal(p, first[i], `${p.title} the one made before`);
  }
  assert.notDeepEqual(kept[2], first[2], "Codex's hours changed what it says");
  // (made anew a few seconds before or now: the same, as of the minute)
  assert.deepStrictEqual(kept, profilesOverview(items, pace, NOW, OFFSET, true).pools);
  assert.deepStrictEqual(kept, fresh);
  console.log(`one station's hours: every pool made anew ${freshMs.toFixed(1)} ms, its pools alone ${keptMs.toFixed(1)} ms`);
  // An account's row changed (its allowance read anew): its pools made again, the others kept.
  const rows = items.map((a) => (a.key === "g1" ? { ...a, profile: { ...a.profile, quota: { ...a.profile.quota, windows: [week(85, 90, "gemini"), five(30, 2, "gemini")] } } } : a));
  const again = profilesOverview(rows, pace, later, OFFSET).pools;
  assert.deepEqual(again.map((p, i) => p === kept[i]), [true, true, true, false]);
  assert.deepStrictEqual(again, profilesOverview(rows, pace, later, OFFSET, true).pools);
  // The minute turned, or the viewer's offset: every pool made again.
  const turned = profilesOverview(rows, pace, later + 60_000, OFFSET).pools;
  assert.ok(turned.every((p, i) => p !== again[i]));
  assert.deepStrictEqual(turned, profilesOverview(rows, pace, later + 60_000, OFFSET, true).pools);
  assert.ok(profilesOverview(rows, pace, later, 0).pools.every((p, i) => p !== again[i]));
});

test("many_stations_coming_back_one_after_another_make_each_pool_again_only_as_its_own_hours_come", () => {
  const { items, paces } = workspace();
  const pace = (station: string) => paces[station];
  const stations = Object.keys(paces);
  let keptMs = 0;
  let freshMs = 0;
  let now = NOW;
  // Eighteen times in a row, a second apart, each time one station's hours anew.
  for (let i = 0; i < 18; i++) {
    const at = stations[i % stations.length]!;
    paces[at] = { ...paces[at], profiles: { ...paces[at].profiles } };
    now += 1_000;
    let kept: J[] = [];
    keptMs += time(() => (kept = profilesOverview(items, pace, now, OFFSET).pools));
    let fresh: J[] = [];
    freshMs += time(() => (fresh = profilesOverview(items, pace, now, OFFSET, true).pools));
    assert.deepStrictEqual(kept, fresh);
  }
  console.log(`18 stations' hours in a row: every pool made anew ${freshMs.toFixed(1)} ms, kept ${keptMs.toFixed(1)} ms`);
});

test("pools_kept_read_none_of_their_accounts_hours_and_are_frozen_all_through", () => {
  const { items, paces } = workspace();
  // (the accounts whose hours were made, as what they are made of is read: views/profiles-overview.ts `hoursOf`)
  const of = new Set<string>();
  const counted = (said: J) => ({
    ...said,
    profiles: Object.fromEntries(Object.entries(said.profiles).map(([id, p]) => {
      const { spend, ...rest } = p as J;
      return [id, Object.defineProperty(rest, "spend", { enumerable: true, get: () => (of.add(id), spend) })];
    })),
  });
  for (const s of Object.keys(paces)) paces[s] = counted(paces[s]);
  const pace = (station: string) => paces[station];
  const first = profilesOverview(items, pace, NOW, OFFSET).pools;
  // (each account's hours made once, Claude's for its Fable pool too)
  assert.equal(of.size, items.length);
  const frozen = (v: unknown): boolean => v === null || typeof v !== "object" || (Object.isFrozen(v) && Object.values(v).every(frozen));
  assert.ok(first.every(frozen), "a pool kept is frozen all through");
  of.clear();
  const again = profilesOverview(items, pace, NOW + 5_000, OFFSET).pools;
  assert.deepEqual(again.map((p, i) => p === first[i]), [true, true, true, true]);
  assert.equal(of.size, 0, "no pool made again reads no account's hours");
  // The Codex station's hours come again: its accounts' hours alone read.
  paces["ws/two"] = counted(paceOf(["x0", "x1", "x2"], 1.4, (id, back) => [week(Math.max(0, 50 - 2 * back), 90)]));
  of.clear();
  const later = profilesOverview(items, pace, NOW + 9_000, OFFSET).pools;
  assert.deepEqual([...of].sort(), ["x0", "x1", "x2"]);
  assert.deepEqual(later.map((p, i) => p === first[i]), [true, true, false, true]);
  assert.deepStrictEqual(later, profilesOverview(items, pace, NOW + 9_000, OFFSET, true).pools);
});

test("checkedAt_refills_and_detail_changes_with_unchanged_values_reuse_kept_pools", () => {
  const { items, paces } = workspace();
  const pace = (station: string) => paces[station];
  const first = profilesOverview(items, pace, NOW, OFFSET).pools;
  const touched = items.map((a) => ({
    ...a,
    profile: {
      ...a.profile,
      quota: {
        ...a.profile.quota,
        checkedAt: NOW + 15_000,
        detail: "refreshed",
        windows: a.profile.quota.windows.map((w: J) => ({ ...w, refills: "2 小时后重置" })),
      },
    },
  }));
  const again = profilesOverview(touched, pace, NOW + 15_000, OFFSET).pools;
  assert.deepEqual(again.map((p, i) => p === first[i]), [true, true, true, true]);
  assert.deepStrictEqual(again, profilesOverview(touched, pace, NOW + 15_000, OFFSET, true).pools);
});
