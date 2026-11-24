// The Profile overview's pools (views/profiles-overview.ts, the `profilesOverview` view): the past of each account's
// own hours (an allowance read each hour, a refill between them; what its calls spent between, flat where nothing was
// spent), the pace of the last hours foreseen with the week's, five hours spent and given back, and a station from
// before (no GET /profiles/pace) giving the overview of the allowances alone.
import assert from "node:assert/strict";
import { test } from "node:test";
import { FUTURE_HOURS, PAST_HOURS, _profilesOverviewExactRef, _simulateTotalUnmetForTest, normScope, profilesOverview, speedPool } from "../src/views/profiles-overview.ts";
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

test("five hours spent make the pool go without until they come back, the line its week's, never down to nothing and up again", () => {
  // 60% of the week spent in the last six hours; five hours of its own unused.
  const items = [account("a", [five(0, null), week(60, 150)])];
  const pool = claude(items, paceOf({ a: { spend: Array.from({ length: 6 }, (_, i) => [i, 1] as [number, number]) } }));
  assert.ok(pool.currentBurnPerHour > 6, `${pool.currentBurnPerHour}`);
  assert.equal(pool.exhaustHours, 2);
  assert.ok(pool.starveSpans[0] === 1 && pool.starveSpans[1]! >= 3, `${pool.starveSpans}`);
  // What the week holds: its five hours' worth (12% of it) taken, the rest there while it goes without.
  assert.equal(pool.traj[PAST_HOURS], 40);
  assert.equal(pool.traj[PAST_HOURS + 3], 28, `${pool.traj.slice(PAST_HOURS, PAST_HOURS + 8)}`);
  // Down only, its five hours back or not, till the week refills (150 hours on).
  for (let h = 1; h < 150; h++) assert.ok(pool.traj[PAST_HOURS + h]! <= pool.traj[PAST_HOURS + h - 1]!, `${h}: ${pool.traj.slice(PAST_HOURS, PAST_HOURS + 12)}`);
  assert.ok(pool.traj[PAST_HOURS + 150]! > 90);
  // While it is spent, its hours go without: under the pace it could keep up, whatever it can take.
  assert.ok(pool.hourlyNet[24 + 2]! < 0);
  assert.ok(pool.netPerHour < 0);
  // Its five hours spent now: going without now, the week as it is.
  const spent = claude([account("a", [five(100, 3), week(60, 150)])], paceOf({ a: { spend: Array.from({ length: 6 }, (_, i) => [i, 1] as [number, number]) } }));
  assert.deepEqual([spent.ready, spent.nowPct, spent.exhaustHours], [0, 40, 0]);
  assert.equal(spent.starveSpans[0], 0);
});

test("accounts refilling at different hours, their five hours spent again and again: the line rises only at a week's refill", () => {
  // Four accounts, their weeks refilling 20, 45, 90 and 130 hours on, spent fast in the last six hours (faster than
  // their five hours let them take), each one's five hours read spent and given back again and again in the hours kept.
  const resets = [20, 45, 90, 130];
  const items = resets.map((r, i) => account(`a${i}`, [five(i === 0 ? 100 : 20 * i, 1 + i), week(30 + 10 * i, r)]));
  const said: Record<string, { quotas: [number, J[]][]; spend: [number, number][] }> = {};
  resets.forEach((_, i) => {
    const quotas: [number, J[]][] = [];
    for (let b = 47; b >= 1; b--) quotas.push([b, [five(b % 5 === i % 5 ? 100 : 20 * (4 - (b % 5)), 5 - (b % 5) - b)]]);
    said[`a${i}`] = { quotas, spend: Array.from({ length: 6 }, (_, h) => [h, 5] as [number, number]) };
  });
  const pool = claude(items, paceOf(said));
  assert.deepEqual([pool.ready, pool.total], [3, 4]);
  assert.ok(pool.starveSpans.length > 0 && pool.hourlyNet.slice(24).some((n) => n < 0), `${pool.starveSpans}`);
  for (let h = 1; h <= FUTURE_HOURS; h++) {
    if (resets.includes(h)) continue;
    assert.ok(pool.traj[PAST_HOURS + h]! <= pool.traj[PAST_HOURS + h - 1]!, `up at ${h}: ${pool.traj.slice(PAST_HOURS + h - 3, PAST_HOURS + h + 2)}`);
  }
  for (const r of resets) assert.ok(pool.traj[PAST_HOURS + r]! > pool.traj[PAST_HOURS + r - 1]!, `refilled at ${r}`);
  // And back: five hours read spent never take a week off the line.
  for (let k = PAST_HOURS; k >= 1; k--) assert.ok(back(pool, k - 1) <= back(pool, k), `up ${k - 1} back: ${back(pool, k)} → ${back(pool, k - 1)}`);
});

test("how many more accounts of its plan a pool needs to keep up: none where it does, and with so many more in it, it does", () => {
  const spend = (f: (i: number) => number, hours = 60): [number, number][] => Array.from({ length: hours }, (_, i) => [i, f(i)] as [number, number]);
  // With `n` more of its plan in it, each full, its week begun now (and its five hours unused where it has them).
  const more = (items: J[], n: number, short: boolean) => [
    ...items,
    ...Array.from({ length: n }, (_, j) => account(`more${j}`, short ? [five(0, null), week(0, 168)] : [week(0, 168)])),
  ];
  const cases: [string, J[], J, boolean][] = [
    ["spending faster in the last hours", [account("a", [week(40, 100)])], paceOf({ a: { spend: spend((i) => (i < 3 ? 10 : 1)) } }), false],
    ["idle now, going without within the week at the week's pace", [account("a", [week(60, 100)])], paceOf({ a: { spend: spend((i) => (i < 12 ? 0 : 1)) } }), false],
    ["its five hours taking it faster than they come back", [account("a", [five(0, null), week(60, 150)])], paceOf({ a: { spend: spend(() => 1, 6) } }), true],
    ["its week spent long ago, nothing spent since", [account("a", [week(100, 100)])], paceOf({ a: { spend: spend((i) => (i < 30 ? 0 : 2), 68) } }), false],
    ["two accounts, both spent fast", [account("a", [week(70, 120)]), account("b", [week(50, 40)])], paceOf({ a: { spend: spend(() => 1.5) }, b: { spend: spend(() => 1.5) } }), false],
    // Six, half spent and refilling three days on, a run of agents in the last three hours: what it asks of the week
    // on leans to the week's pace, never the run's of every hour.
    ["six, a burst of the last hours, a day without before the refills", [
      ...[0, 1, 2].map((i) => account(`s${i}`, [week(100, 82 + i)])),
      account("t0", [week(80, 160)]), account("t1", [week(85, 160)]), account("t2", [week(85, 160)]),
    ], paceOf(Object.fromEntries(["s0", "s1", "s2", "t0", "t1", "t2"].map((k) => [k, { spend: spend((i) => (i < 3 ? 3 : 0.4)) }]))), false],
  ];
  const steady = claude([account("a", [week(10, 100)])], paceOf({ a: { spend: spend(() => 1) } }));
  assert.equal(steady.overPace, false);
  assert.equal(steady.neededAccounts, null, "keeping up: none more");
  for (const [name, items, pace, short] of cases) {
    const pool = claude(items, pace);
    assert.ok(pool.overPace, `${name}: over its pace`);
    if (pool.exhaustHours === null) {
      // (over its pace now, never going without in the week: none more said)
      assert.equal(pool.neededAccounts, null, `${name}: goes without in no hour`);
      continue;
    }
    const needed = pool.neededAccounts ?? 0;
    assert.ok(needed >= 1, `${name}: ${pool.neededAccounts}`);
    // With so many more it needs none more (what it still goes without, a percent of it at most over the week, is no
    // account more); with one fewer it still does (the fewest: a burst of the last hours is not asked of every hour
    // on, 13 said where 1 would do).
    const after = claude(more(items, needed, short), pace);
    assert.equal(after.neededAccounts, null, `${name}, ${needed} more: ${after.starveSpans}`);
    const fewer = claude(more(items, needed - 1, short), pace);
    assert.ok(fewer.exhaustHours !== null && fewer.neededAccounts !== null, `${name}, ${needed - 1} more: keeps up`);
  }
});

test("the hours on spread over the accounts as the station's pool spreads them: weeks holding plenty go without for no account's five hours", () => {
  // Four, refilling at 20, 60, 130 and 90 hours: drained one after another, the last weeks left were one account's,
  // held to its five hours, and the pool went without at 14 and 18 hours on with 12% of it left, one account more said.
  const items = ([[70, 20], [80, 60], [100, 130], [40, 90]] as const).map(([used, r], i) => account(`a${i}`, [five(0, null), week(used, r)]));
  const pool = claude(items, paceOf(Object.fromEntries(items.map((a) => [a.key, { spend: Array.from({ length: 60 }, (_, h) => [h, 1] as [number, number]) }]))));
  assert.deepEqual([pool.starveSpans, pool.exhaustHours, pool.neededAccounts], [[], null, null]);
});

test("the pools of a workspace's accounts: each model's, its accounts ready of all, one in trouble leaving its share", () => {
  const items = [
    account("a", [five(10, 2), week(20, 100), week(50, 100, "Fable")]),
    account("b", [five(100, 1), week(30, 60)], { profile: { id: "b", planText: "Max 5x", checkTone: "green", quota: { state: "ok", windows: [five(100, 1), week(30, 60)], checkedAt: NOW } } }),
    account("c", [], { look: true, state: { tone: "red", text: "需要登录" }, profile: { id: "c", planText: "Max 20x", checkTone: "red", quota: { state: "unavailable", windows: [] } } }),
    { ...account("g", [{ label: "每周 · Gemini", usedPercent: 40, resetsAt: NOW + 50 * H, minutes: WEEK, scope: "gemini" }, { label: "每周 · Claude / GPT", usedPercent: 10, resetsAt: NOW + 50 * H, minutes: WEEK, scope: "3p" }]), group: "agy" },
  ];
  const { pools } = profilesOverview(items, () => undefined, NOW, 480);
  assert.deepEqual(pools.map((p) => [p.title, p.ready, p.total]), [["Claude", 1, 3], ["Fable", 1, 2], ["Gemini", 1, 1]]);
  const claudePool = pools[0]!;
  // a (20 of 25 shares, 80% of its week left) usable now, b (5, 70%) not till its five hours come back: what their weeks
  // hold, 64 + 14.
  assert.equal(claudePool.nowPct, 78);
});

test("Gemini: the allowance's own scope and a station's spending by it, of this release or before, draw what was spent and its refills", () => {
  const gemini = (used: number, resetsInH: number, shortUsed: number) => [
    { label: "每周 · Gemini", usedPercent: used, resetsAt: NOW + resetsInH * H, minutes: WEEK, scope: "gemini" },
    { label: "5 小时 · Gemini", usedPercent: shortUsed, resetsAt: NOW + 2 * H, minutes: 300, scope: "gemini" },
    { label: "每周 · Claude / GPT", usedPercent: 5, resetsAt: NOW + resetsInH * H, minutes: WEEK, scope: "3p" },
  ];
  const plan = [[100, 96, 30], [58, 143, 20], [52, 120, 10], [45, 60, 0], [100, 100, 100]] as const;
  const items = plan.map(([used, r, short], i) => ({ ...account(`g${i}`, gemini(used, r, short)), group: "agy", profile: { id: `g${i}`, planText: "Pro", checkTone: "green", quota: { state: "ok", windows: gemini(used, r, short), checkedAt: NOW } } }));
  const paceSaid = (scope: string) => paceOf(Object.fromEntries(plan.map(([used, r], i) => [`g${i}`, {
    // (read 24 and 12 hours back, the week lower by what was spent since: two an hour)
    quotas: [[24, gemini(used - 24, r, 0)], [12, gemini(used - 12, r, 0)]] as [number, J[]][],
    spend: Array.from({ length: 24 }, (_, h) => [h, 1, scope] as [number, number, string]),
  }])));
  const pools = (pace: J) => profilesOverview(items, (s) => (s === "ws/st" ? pace : undefined), NOW, 0).pools;
  const now = pools(paceSaid("gemini"));
  const before = pools(paceSaid("Gemini"));
  assert.deepEqual(now.map((p) => p.title), ["Gemini"], "Claude / GPT of an Antigravity account in no other pool");
  const g = now[0]!;
  assert.deepEqual(before[0], g, "a station from before says it as \"Gemini\"");
  // Ready: the three with week and five hours left; what their weeks hold, a fifth each: (42 + 48 + 55) / 5.
  assert.deepEqual([g.ready, g.total, g.nowPct], [3, 5, 29]);
  // The past as read: each week 24 points lower a day back, 12 half a day back.
  assert.deepEqual([back(g, 24), back(g, 12), back(g, 0)], [53, 41, 29]);
  assert.ok(g.hourlyNet.slice(0, 24).some((n) => n < g.sustainablePerHour), "the hours spent in show");
  // Its weeks refill where they say: 60, 96, 100 (four days on), 120 and 143 hours (six days on).
  for (const r of [60, 96, 100, 120, 143]) assert.ok(g.traj[PAST_HOURS + r]! > g.traj[PAST_HOURS + r - 1]!, `refill at ${r}: ${g.traj.slice(PAST_HOURS + r - 2, PAST_HOURS + r + 2)}`);
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
      if (!new URL(req.url).pathname.endsWith("/admin/api/profiles/pace")) return undefined;
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

test("each pool's models' speed: what their timed calls wrote over the time they took, in sliding windows, of every station", () => {
  const Q = H / 4;
  const q0 = Math.floor(NOW / Q);
  // Two stations: Opus and Fable on one, Opus and GPT on another; an hour back and now.
  const one = { nowAt: NOW, profiles: {}, speedHours: [
    { at: HOUR0 - 1, model: "claude-opus-5-5", output: 6000, ms: 100_000 },
    { at: HOUR0, model: "claude-opus-5-5", output: 3000, ms: 50_000 },
    { at: HOUR0, model: "claude-fable-5-2[1m]", output: 1000, ms: 50_000 },
  ], speedQuarters: [{ at: q0, model: "claude-opus-5-5", output: 3000, ms: 50_000 }, { at: q0, model: "claude-fable-5-2[1m]", output: 1000, ms: 50_000 }] };
  const two = { nowAt: NOW, profiles: {}, speedHours: [
    { at: HOUR0, model: "anthropic/claude-opus-5-5", output: 6000, ms: 50_000 },
    { at: HOUR0, model: "gpt-6.1-sol", output: 2000, ms: 20_000 },
    { at: HOUR0, model: "some-other-model", output: 2000, ms: 20_000 },
  ], speedQuarters: [{ at: q0 - 4, model: "anthropic/claude-opus-5-5", output: 6000, ms: 50_000 }] };
  const items = [
    account("a", [week(10, 100), five(0, null)], { members: [{ station: "ws/one", profileId: "a" }, { station: "ws/two", profileId: "a" }] }),
    account("f", [week(10, 100, "Fable"), week(10, 100), five(0, null)], { members: [{ station: "ws/one", profileId: "f" }] }),
    account("c", [week(10, 100), five(0, null)], { group: "chatgpt", members: [{ station: "ws/two", profileId: "c" }] }),
  ];
  const pools = profilesOverview(items, (s) => (s === "ws/one" ? one : s === "ws/two" ? two : undefined), NOW, 0).pools;
  const of = (title: string) => pools.find((p) => p.title === title)?.speed;
  const opus = of("Claude")!;
  // The 3 hours to an hour back (6000 over 100 s), and to now: both stations' with the hour before (15000 over 200 s).
  assert.deepEqual(opus.hours.slice(-2), [60, 75]);
  assert.equal(opus.hours.length, 24);
  assert.equal(opus.hours[0], -1, "nothing timed then");
  // The last 6 hours a quarter apart, each of the hour before: four quarters back (6000 over 50 s) in the four windows
  // that hold it, and now's alone (3000 over 50 s).
  assert.equal(opus.quarters.length, 24);
  assert.deepEqual(opus.quarters.slice(-6), [-1, 120, 120, 120, 120, 60]);
  assert.equal(opus.days.length, 28);
  assert.equal(opus.days.at(-1), 75);
  assert.deepEqual(of("Fable")!.hours.at(-1), 20);
  assert.deepEqual(of("Codex")!.hours.at(-1), 100);
  assert.equal(of("Gemini"), undefined);
  assert.deepEqual(["claude-sonnet-5-5", "claude-mythos-5", "gemini-4-hydrogen-high", "gpt-6-luna", "o4-mini", "grok-5"].map(speedPool), ["Claude", "Fable", "Gemini", "Codex", "Codex", null]);

  // Speed object and full pool reference stability when called again with unchanged inputs.
  const pools2 = profilesOverview(items, (s) => (s === "ws/one" ? one : s === "ws/two" ? two : undefined), NOW, 0).pools;
  for (let i = 0; i < pools.length; i++) {
    assert.equal(pools2[i], pools[i], `pool ${pools[i]!.title} keeps identical frozen reference`);
  }
});

test("normScope preserves Fable suffix fallback and merged simulateTotalUnmet matches unmerged reference across edge cases and 200 random scenarios", () => {
  assert.equal(normScope("", "Weekly · Fable"), "Fable");
  assert.equal(normScope("", "每周 · Fable"), "Fable");
  assert.equal(normScope("gemini", ""), "gemini");
  assert.equal(normScope("3p", ""), "3p");
  assert.equal(normScope("Fable", ""), "Fable");
  assert.equal(normScope("Argon", ""), "Argon");

  // Astra counterexample: share=100, left=0, unitShare=1, k=6, demand=7, slack=1.
  {
    const demand = new Float64Array(FUTURE_HOURS + 1);
    demand[1] = 7;
    const start = [{ share: 100, left: 0, resetIn: 168, cycle: 168, lockedTill: 0, short: null }];
    const scale = 100 / (100 + 6 * 1);
    const merged = _simulateTotalUnmetForTest(start, 6, 1, 168, null, demand, scale, 1, false);
    const exact = _simulateTotalUnmetForTest(start, 6, 1, 168, null, demand, scale, 1, true);
    assert.equal(merged, exact);
  }

  // Exact slack boundary, k=0, k=999, short-cycle resets.
  for (const k of [0, 1, 2, 6, 50, 999]) {
    const demand = new Float64Array(FUTURE_HOURS + 1);
    for (let h = 1; h <= FUTURE_HOURS; h++) demand[h] = h % 7 === 0 ? 15 : 2;
    const start = [
      { share: 60, left: 10, resetIn: 40, cycle: 168, lockedTill: 0, short: { used: 50, resetIn: 2, hours: 5, ofLong: 12 } },
      { share: 40, left: 30, resetIn: 100, cycle: 168, lockedTill: 3, short: { used: 0, resetIn: null, hours: 5, ofLong: 12 } },
    ];
    const scale = 100 / (100 + k * 25);
    const merged = _simulateTotalUnmetForTest(start, k, 25, 168, { hours: 5, ofLong: 12 }, demand, scale, 1, false);
    const exact = _simulateTotalUnmetForTest(start, k, 25, 168, { hours: 5, ofLong: 12 }, demand, scale, 1, true);
    assert.equal(merged, exact, `k=${k}`);
  }

  // 200 deterministic PRNG stress scenarios comparing profilesOverview vs _profilesOverviewExactRef.
  let seed = 0x51a7c0de;
  const rand = () => {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return seed / 0x100000000;
  };
  for (let s = 0; s < 200; s++) {
    const nAcc = 1 + Math.floor(rand() * 5);
    const items: J[] = [];
    const accountsPace: Record<string, { quotas?: [number, J[]][]; spend?: [number, number, string?][] }> = {};
    for (let a = 0; a < nAcc; a++) {
      const id = `a${a}`;
      const used = Math.floor(rand() * 100);
      const resetIn = 1 + Math.floor(rand() * 167);
      const hasShort = rand() > 0.25;
      const ws: J[] = [week(used, resetIn)];
      if (hasShort) ws.push(five(Math.floor(rand() * 100), rand() > 0.3 ? 1 + Math.floor(rand() * 5) : null));
      const plan = rand() < 0.33 ? "Max 20x" : rand() < 0.66 ? "Max 5x" : "Pro";
      items.push(account(id, ws, { profile: { id, planText: plan, checkTone: "green", quota: { state: "ok", windows: ws, checkedAt: NOW } } }));
      const rate = 0.5 + rand() * 35;
      accountsPace[id] = {
        spend: Array.from({ length: 24 }, (_, h) => [h, rate * (0.2 + rand() * 2)] as [number, number]),
      };
    }
    const pace = paceOf(accountsPace);
    const opt = profilesOverview(items, (st) => (st === "ws/st" ? pace : undefined), NOW, 0, true).pools;
    const ref = _profilesOverviewExactRef(items, (st) => (st === "ws/st" ? pace : undefined), NOW, 0).pools;
    assert.equal(opt.length, ref.length);
    for (let i = 0; i < opt.length; i++) {
      assert.equal(opt[i]!.neededAccounts, ref[i]!.neededAccounts, `scenario ${s} pool ${opt[i]!.title} neededAccounts`);
      assert.deepEqual(opt[i]!.traj, ref[i]!.traj, `scenario ${s} pool ${opt[i]!.title} traj`);
    }
  }

  // Exact short-window floating-point rounding regression (2 healthy Claude Pro accounts, no history, UTC, now=500000.5h).
  {
    const nowBoundary = 500_000.5 * H;
    const mk = (id: string, wUsed: number, wResetH: number, sUsed: number, sResetH: number) =>
      account(
        id,
        [
          { label: "每周", scope: "", usedPercent: wUsed, resetsAt: nowBoundary + wResetH * H, minutes: 10_080, mark: "W" },
          { label: "5 小时", scope: "", usedPercent: sUsed, resetsAt: nowBoundary + sResetH * H, minutes: 300, mark: "5H" },
        ],
        {
          profile: {
            id,
            planText: "Pro",
            checkTone: "green",
            quota: {
              state: "ok",
              checkedAt: nowBoundary,
              windows: [
                { label: "每周", scope: "", usedPercent: wUsed, resetsAt: nowBoundary + wResetH * H, minutes: 10_080, mark: "W" },
                { label: "5 小时", scope: "", usedPercent: sUsed, resetsAt: nowBoundary + sResetH * H, minutes: 300, mark: "5H" },
              ],
            },
          },
        },
      );
    const items = [mk("a", 99, 94, 57, 3), mk("b", 55, 162, 52, 1)];
    const claude = profilesOverview(items, () => undefined, nowBoundary, 0, true).pools.find((p) => p.title === "Claude");
    assert.ok(claude);
    assert.deepEqual([claude.traj[55], claude.traj[56], claude.traj[59]], [10, 10, 4]);
  }
});
