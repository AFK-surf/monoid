// The Profile overview's pools (views/profiles-overview.ts, the `profilesOverview` view): the past of each account's
// own hours (an allowance read each hour, a refill between them; what its calls spent between, flat where nothing was
// spent), the pace of the last hours foreseen with the week's, five hours spent and given back, and a station from
// before (no GET /profiles/pace) giving the overview of the allowances alone.
import assert from "node:assert/strict";
import { test } from "node:test";
import { FUTURE_HOURS, PAST_HOURS, profilesOverview } from "../src/views/profiles-overview.ts";
import { apply, subscribe, v } from "./helpers.ts";
import { base, overview, started, stationReplies, status } from "./station-fixture.ts";

// deno-lint-ignore no-explicit-any
type J = any;
const H = 3_600_000;
/// Now: half past an hour, the viewer at UTC.
const HOUR0 = 500_000;
const NOW = HOUR0 * H + H / 2;
const WEEK = 10_080;

const week = (used: number, resetsInH: number, scope = "") => ({ label: "每周", usedPercent: used, resetsAt: NOW + resetsInH * H, minutes: WEEK, ...(scope ? { scope } : {}) });
const five = (used: number, resetsInH: number | null) => ({ label: "5 小时", usedPercent: used, resetsAt: resetsInH === null ? null : NOW + resetsInH * H, minutes: 300 });
const account = (id: string, windows: J[], o: J = {}) => ({
  key: id, group: "claude", usable: true, look: false, state: null,
  profile: { id, planText: "Max 20x", checkTone: "green", quota: { state: "ok", windows, checkedAt: NOW } },
  members: [{ station: "ws/st", profileId: id }],
  ...o,
});
/// What a station said of its accounts' hours: each account's allowance by the hours back it was read (`at` that many
/// hours before now) and what it spent by the hours back.
const paceOf = (accounts: Record<string, { quotas?: [number, J[]][]; spend?: [number, number, string?][] }>) => ({
  nowAt: NOW,
  profiles: Object.fromEntries(Object.entries(accounts).map(([id, a]) => [id, {
    quotas: (a.quotas ?? []).map(([back, windows]) => ({ hour: Math.floor((NOW - back * H) / H), at: NOW - back * H, windows })),
    spend: (a.spend ?? []).map(([back, weight, scope]) => ({ hour: HOUR0 - back, scope: scope ?? "", weight })),
  }])),
});
const claude = (items: J[], pace: J) => {
  const pool = profilesOverview(items, (s) => (s === "ws/st" ? pace : undefined), NOW, 0).pools.find((p) => p.title === "Claude");
  assert.ok(pool !== undefined);
  assert.equal(pool.traj.length, PAST_HOURS + 1 + FUTURE_HOURS);
  assert.equal(pool.starveSpans.length % 2, 0);
  assert.equal(pool.hourlyNet.length, 48);
  // (each hour against the pace it could keep up: never over it where it spent nothing)
  assert.ok(pool.hourlyNet.every((n) => n <= pool.sustainablePerHour + 0.05));
  return pool;
};
/// The pool's percent left `k` hours back.
const back = (pool: { traj: number[] }, k: number) => pool.traj[PAST_HOURS - k]!;

test("the hours an allowance was read draw the past as it was, its week's refill a jump up", () => {
  // The week refilled 28 hours ago: read at 95% used two hours before that, at 10% eight hours after, 30% now.
  const items = [account("a", [week(30, 140)])];
  const pace = paceOf({ a: { quotas: [[30, [week(95, -28)]], [20, [week(10, 140)]], [10, [week(25, 140)]]] } });
  const pool = claude(items, pace);
  assert.equal(pool.nowPct, 70);
  assert.equal(back(pool, 0), 70);
  assert.equal(back(pool, 30), 5);
  assert.equal(back(pool, 20), 90);
  assert.equal(back(pool, 10), 75);
  // (just before the refill nearly none, just after nearly all)
  assert.ok(back(pool, 29) < 6 && back(pool, 27) > 95, `${back(pool, 29)} → ${back(pool, 27)}`);
  // Each hour spent as read: none negative across the refill.
  // (its refill no hour spent: none below what was spent at most)
  assert.ok(pool.hourlyNet.slice(0, 24).every((n) => n >= -100));
});

test("with no hour read yet, what the calls spent each hour shapes the week used so far: flat where none was spent", () => {
  // 30% used of a week begun 68 hours ago, all of it spent 6 to 10 hours back.
  const items = [account("a", [week(30, 100)])];
  const pace = paceOf({ a: { spend: [[10, 2], [9, 2], [8, 2], [7, 2], [6, 2]] } });
  const pool = claude(items, pace);
  assert.equal(back(pool, 0), 70);
  assert.equal(back(pool, 4), 70, "no calls since: flat");
  assert.equal(back(pool, 20), 100, "no calls before: flat at full");
  assert.ok(back(pool, 8) > 70 && back(pool, 8) < 100, `falling while spent: ${back(pool, 8)}`);
  // The hours spent in show their pace; the others none.
  // The hours nothing was spent in at the pace it could keep up (above 0); those spent in, under it.
  assert.equal(pool.hourlyNet[23 - 2], Math.round(pool.sustainablePerHour * 10) / 10);
  assert.ok(pool.hourlyNet[23 - 2]! > 0);
  assert.ok(pool.hourlyNet[23 - 8]! < -4, `${pool.hourlyNet.slice(0, 24)}`);
  // With nothing counted either, evenly since the week began.
  const even = claude(items, paceOf({}));
  assert.ok(Math.abs(back(even, 34) - 85) < 1, `${back(even, 34)}`);
});

test("calls of the last hours spending faster raise the pace now and bring the pool's going without nearer", () => {
  const items = [account("a", [week(40, 100)])];
  const steady = claude(items, paceOf({ a: { spend: Array.from({ length: 60 }, (_, i) => [i, 1] as [number, number]) } }));
  const surge = claude(items, paceOf({ a: { spend: Array.from({ length: 60 }, (_, i) => [i, i < 3 ? 10 : 1] as [number, number]) } }));
  assert.ok(surge.currentBurnPerHour > steady.currentBurnPerHour * 2, `${steady.currentBurnPerHour} → ${surge.currentBurnPerHour}`);
  assert.equal(steady.exhaustHours, null, "at the week's pace it lasts till its refill");
  assert.ok(surge.exhaustHours !== null && surge.exhaustHours < 100, `${surge.exhaustHours}`);
  assert.ok(surge.overPace && surge.currentBurnPerHour > surge.sustainablePerHour);
  assert.ok(surge.sustainablePerHour > 0);
  // The next hours foreseen at the last hours' pace, easing to the week's.
  assert.ok(surge.hourlyNet[24]! < surge.hourlyNet[47]!, `${surge.hourlyNet.slice(24)}`);
  assert.ok(surge.netPerHour < 0 && steady.hourlyNet[24]! > surge.hourlyNet[24]!);
});

test("idle now but going without within the week at the week's pace: the pace now said against the week's, never above it", () => {
  // 60% of a week spent over the 48 hours before the last 12, nothing since; 40% left for 100 hours.
  const items = [account("a", [week(60, 100)])];
  const spent = (last: number) => paceOf({ a: { spend: Array.from({ length: 60 }, (_, i) => [i, i < 12 ? last : 1] as [number, number]) } });
  const idle = claude(items, spent(0));
  assert.ok(idle.currentBurnPerHour < 0.05, `${idle.currentBurnPerHour}`);
  assert.ok(idle.exhaustHours !== null && idle.overPace, `${idle.exhaustHours}`);
  // (sustainable − the week's pace, as an hour of it would be over: negative, whatever is spent now under it)
  assert.ok(idle.netPerHour < -0.1, `${idle.netPerHour}`);
  const busier = claude(items, spent(0.5));
  const busiest = claude(items, spent(3));
  assert.ok(busier.netPerHour <= idle.netPerHour && busiest.netPerHour <= busier.netPerHour, `${idle.netPerHour} ${busier.netPerHour} ${busiest.netPerHour}`);
  assert.ok(busiest.netPerHour < idle.netPerHour);
});

test("five hours spent take the pool to nothing until they come back, its week still holding", () => {
  // 60% of the week spent in the last six hours; five hours of its own unused.
  const items = [account("a", [five(0, null), week(60, 150)])];
  const pool = claude(items, paceOf({ a: { spend: Array.from({ length: 6 }, (_, i) => [i, 1] as [number, number]) } }));
  assert.ok(pool.currentBurnPerHour > 6, `${pool.currentBurnPerHour}`);
  assert.equal(pool.exhaustHours, 2);
  assert.equal(pool.traj[PAST_HOURS + 3], 0);
  assert.ok(pool.starveSpans[0] === 1 && pool.starveSpans[1]! >= 3, `${pool.starveSpans}`);
  // Its five hours back: the pool comes back with what the week has left.
  assert.ok(pool.traj[PAST_HOURS + 5]! > 10, `${pool.traj.slice(PAST_HOURS, PAST_HOURS + 8)}`);
  // While it is spent, its hours go without: under the pace it could keep up, whatever it can take.
  assert.ok(pool.hourlyNet[24 + 2]! < 0);
  assert.ok(pool.netPerHour < 0);
});

test("the pools of a workspace's accounts: each model's, its accounts ready of all, one in trouble leaving its share", () => {
  const items = [
    account("a", [five(10, 2), week(20, 100), week(50, 100, "Fable")]),
    account("b", [five(100, 1), week(30, 60)], { profile: { id: "b", planText: "Max 5x", checkTone: "green", quota: { state: "ok", windows: [five(100, 1), week(30, 60)], checkedAt: NOW } } }),
    account("c", [], { look: true, state: { tone: "red", text: "需要登录" }, profile: { id: "c", planText: "Max 20x", checkTone: "red", quota: { state: "unavailable", windows: [] } } }),
    { ...account("g", [{ label: "每周 · Gemini", usedPercent: 40, resetsAt: NOW + 50 * H, minutes: WEEK, scope: "Gemini" }]), group: "agy" },
  ];
  const { pools } = profilesOverview(items, () => undefined, NOW, 480);
  assert.deepEqual(pools.map((p) => [p.title, p.ready, p.total]), [["Claude", 1, 3], ["Fable", 1, 2], ["Gemini", 1, 1]]);
  const claudePool = pools[0]!;
  // a (20 of 25 shares) usable now, b (5) on its five hours: 80 × 80% = 64.
  assert.equal(claudePool.nowPct, 64);
});

test("the overview is of the stations' hours as they come, and of the allowances alone where a station has none to give", async () => {
  const profile = (now: number) => ({
    id: "p1", name: "p1@x.com", email: "p1@x.com", runtime: "claude", runtimes: ["claude"], access: { kind: "subscription", key: "" }, home: "/h",
    homeExists: true, model: null, models: [], env: [], usedBy: [], loginCommand: "", planText: "Max 20x",
    check: { state: "ok", detail: "", checkedAt: 1 },
    quota: { state: "ok", windows: [{ label: "每周", usedPercent: 40, resetsAt: now + 100 * H, minutes: WEEK }], detail: null, checkedAt: now },
  });
  for (const old of [false, true]) {
    let asked = 0;
    const { host, core } = await started(base(), 0, undefined, (s) => stationReplies(s.host, (req) => {
      const now = s.host.nowMs();
      if (req.url.endsWith("/admin/api/overview")) return { ...overview, profiles: [profile(now)] };
      if (!req.url.endsWith("/admin/api/profiles/pace")) return undefined;
      asked++;
      return old ? status(404, { error: "no route GET /profiles/pace" }) : { nowAt: now, fromHour: 0, profiles: { p1: { quotas: [], spend: [{ hour: Math.floor(now / H) - 2, scope: "", weight: 3 }] } } };
    }));
    const ui = core.connect();
    const values = new Map();
    subscribe(core, ui, 1, { topic: "profilesOverview", scope: "ws" });
    subscribe(core, ui, 2, { topic: "profiles", scope: "ws" });
    await host.settle();
    apply(host, values);
    const pools = v(values, 1)?.pools as J[] | undefined;
    assert.ok(Array.isArray(pools), `a value${old ? " from a station from before" : ""}`);
    assert.equal(pools[0].title, "Claude");
    assert.equal(pools[0].nowPct, 60);
    assert.equal(pools[0].traj.length, PAST_HOURS + 1 + FUTURE_HOURS);
    // What the calls spent two hours back shows there; a station from before, the week so far spread evenly.
    const hn = pools[0].hourlyNet as number[];
    if (old) assert.equal(hn[22], hn[10]);
    else assert.ok(hn[22]! < hn[10]!, `${hn.slice(0, 24)}`);
    // The list the overview stands beside is as it was: no hours in its rows.
    assert.equal(JSON.stringify(v(values, 2).items).includes("traj"), false);
    assert.ok(asked >= 1, "asked while the overview is shown");
    core.close();
  }
});
