// The Profile overview the app's fixture shows (apps/mbui/src/sfapp/settings/fixture_overview.mbt), made by the core's
// own pools (src/views/profiles-overview.ts) of the fixture's accounts (settings/fixture.mbt fx_summary_profiles and
// fx_profiles) and hours made up as a station would keep them: two and a half days of an allowance read each hour and
// the calls of each hour, people working by day (a morning's and an afternoon's peak, the night low), a week refilled
// two days ago, an account whose five hours are spent; and how fast the models wrote, as a station times their calls
// (Opus, Fable and GPT, slower at the day's peaks, none timed in the night's quiet hours; Gemini's never timed).
// `node scripts/overview-fixture.ts` writes it.
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { profilesOverview } from "../src/views/profiles-overview.ts";

// deno-lint-ignore no-explicit-any
type J = any;
const H = 3_600_000;
const WEEK = 10_080;
/// 2026-11-16 14:30 in UTC+8, where the made-up people work.
const NOW = Date.UTC(2026, 10, 16, 6, 30);
const OFFSET = 480;
const KEPT_HOURS = 60;
const OUT = fileURLToPath(new URL("../../../apps/mbui/src/sfapp/settings/fixture_overview.mbt", import.meta.url));

/// The same made-up noise every run.
function noise(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 2 ** 32;
  };
}

/// How busy an hour of the day is (local): two peaks, the night low.
function busy(localHour: number): number {
  const peak = (c: number, w: number) => Math.exp(-(((localHour - c) / w) ** 2));
  return 0.06 + 1.0 * peak(10.5, 1.8) + 1.25 * peak(16, 2.4) + 0.35 * peak(21.5, 1.4);
}
const localHourOf = (ms: number) => ((Math.floor((ms + OFFSET * 60_000) / H) % 24) + 24) % 24;

type Window = { label: string; scope?: string; used: number; resetsIn: number | null; minutes: number; usedBefore?: number };
type Account = { id: string; group: string; plan: string; usable?: boolean; broken?: boolean; windows: Window[]; seed: number; hot?: number };

/// An account's item as the core holds the workspace's (`profilesWhole`), and what its station kept of its hours.
function made(a: Account): { item: J; pace: J } {
  const windows = a.windows.map((w) => ({
    label: w.label, usedPercent: w.used, resetsAt: w.resetsIn === null ? null : NOW + w.resetsIn * H, minutes: w.minutes, ...(w.scope ? { scope: w.scope } : {}),
  }));
  const item = {
    key: a.id, group: a.group, usable: a.usable ?? true, look: a.broken === true, state: a.broken ? { tone: "red", text: "需要登录" } : null,
    profile: { id: a.id, planText: a.plan, checkTone: a.broken ? "red" : "green", quota: a.broken ? { state: "unavailable", windows: [] } : { state: "ok", windows, checkedAt: NOW } },
    members: [{ station: "ws1/st1", profileId: a.id }],
  };
  if (a.broken) return { item, pace: { quotas: [], spend: [] } };
  // Each hour's calls (0 the last): by the hour of the day, some hours more, the last `hot` hours a run of agents.
  const rand = noise(a.seed);
  const raw = Array.from({ length: 200 }, (_, j) => {
    const at = NOW - (j + 0.5) * H;
    const r = rand();
    return busy(localHourOf(at)) * (0.55 + 0.9 * r) * (r > 0.9 ? 2.2 : 1) * (j < (a.hot ?? 0) ? 3.5 : 1);
  });
  // Each long window's percent used each hour back, its calls spread over it so they add up to what it says now.
  const longs = a.windows.filter((w) => w.minutes >= 1440);
  const usedAt = new Map<Window, number[]>();
  for (const w of longs) {
    const cycle = w.minutes / 60;
    const since = w.resetsIn === null ? 84 : cycle - w.resetsIn;
    const inCycle = raw.slice(0, Math.max(1, Math.floor(since)));
    const total = inCycle.reduce((s, x) => s + x, 0);
    const per = total > 0 ? w.used / total : 0;
    const used: number[] = [];
    let u = w.used;
    for (let j = 0; j <= KEPT_HOURS; j++) {
      used.push(Math.max(0, Math.round(u * 10) / 10));
      if (j === Math.floor(since)) u = w.usedBefore ?? 88;
      else u -= per * raw[j]!;
    }
    usedAt.set(w, used);
  }
  const quotas = [];
  for (let j = KEPT_HOURS; j >= 1; j--) {
    const at = NOW - j * H + 7 * 60_000;
    quotas.push({
      hour: Math.floor(at / H), at,
      windows: longs.map((w) => {
        const cycle = w.minutes / 60;
        const since = w.resetsIn === null ? 84 : cycle - w.resetsIn;
        const resetsAt = NOW + (w.resetsIn ?? 84) * H - (j > since ? cycle * H : 0);
        return { label: w.label, scope: w.scope ?? null, usedPercent: usedAt.get(w)![j]!, resetsAt, minutes: w.minutes };
      }),
    });
  }
  const scopes = [...new Set(longs.map((w) => w.scope ?? ""))];
  const spend = [];
  for (let j = 0; j < 192; j++) {
    for (const scope of scopes) {
      // (Fable's part of a Claude account's calls, counted against its own week and the account's)
      const part = scope === "Fable" ? 0.3 : 1;
      const weight = Math.round(raw[j % raw.length]! * 2.4 * part * 1e4) / 1e4;
      if (weight > 0.0005) spend.push({ hour: Math.floor(NOW / H) - j, scope, weight });
    }
  }
  return { item, pace: { quotas, spend } };
}

const w = (label: string, used: number, resetsIn: number | null, minutes: number, scope?: string, usedBefore?: number): Window => ({ label, used, resetsIn, minutes, ...(scope ? { scope } : {}), ...(usedBefore !== undefined ? { usedBefore } : {}) });

/// fx_summary_profiles' accounts: Claude's five (a week refilled 44 hours ago on two, one spent till its refill, one on
/// its five hours, one to sign in again), ChatGPT's three, two Google accounts.
const SUMMARY: Account[] = [
  { id: "cc", group: "claude", plan: "Max 20x", seed: 11, hot: 3, windows: [w("5 小时", 52, 2, 300), w("每周", 72, 124, WEEK, undefined, 91), w("每周 · Fable", 48, 124, WEEK, "Fable", 86)] },
  { id: "cc2", group: "claude", plan: "Max 20x", seed: 12, windows: [w("5 小时", 64, 3, 300), w("每周", 78, 124, WEEK, undefined, 84), w("每周 · Fable", 55, 124, WEEK, "Fable", 70)] },
  { id: "cc3", group: "claude", plan: "Max 5x", seed: 13, hot: 4, windows: [w("5 小时", 100, 0.7, 300), w("每周", 60, 96, WEEK), w("每周 · Fable", 20, 96, WEEK, "Fable")] },
  { id: "cc4", group: "claude", plan: "Max 20x", seed: 14, usable: false, windows: [w("每周", 100, 48, WEEK), w("每周 · Fable", 0, 48, WEEK, "Fable")] },
  { id: "cc5", group: "claude", plan: "Max 20x", seed: 15, broken: true, usable: false, windows: [] },
  { id: "cx", group: "chatgpt", plan: "Pro 200", seed: 21, windows: [w("5 小时", 18, 3, 300), w("每周", 32, 72, WEEK)] },
  { id: "cx2", group: "chatgpt", plan: "Pro 200", seed: 22, windows: [w("5 小时", 8, 4, 300), w("每周", 16, 14, WEEK)] },
  { id: "cx3", group: "chatgpt", plan: "Plus", seed: 23, usable: false, windows: [w("5 小时", 0, 5, 300), w("每周", 100, 48, WEEK)] },
  { id: "ag1", group: "agy", plan: "AI Ultra", seed: 31, windows: [w("5 小时 · Gemini", 24, 3, 300, "gemini"), w("每周 · Gemini", 32, 72, WEEK, "gemini"), w("每周 · Claude / GPT", 20, 72, WEEK, "3p")] },
  { id: "ag2", group: "agy", plan: "AI Ultra", seed: 32, windows: [w("5 小时 · Gemini", 36, 1, 300, "gemini"), w("每周 · Gemini", 38, 96, WEEK, "gemini"), w("每周 · Claude / GPT", 32, 96, WEEK, "3p")] },
];

/// fx_profiles' two (Willow's Claude and ChatGPT subscriptions), each 81% of its week used, refilled Monday.
const PLAIN: Account[] = [
  { id: "cc", group: "claude", plan: "Ultra", seed: 41, windows: [w("5 小时", 38, 2, 300), w("本周", 81, 34, WEEK)] },
  { id: "cx", group: "chatgpt", plan: "Pro 200", seed: 42, windows: [w("5 小时", 38, 2, 300), w("本周", 81, 34, WEEK)] },
];

/// What the station timed of each model's calls (GET /profiles/pace's speedHours, speedQuarters): by the hour of the day,
/// their speed lower as more is asked, none timed where the hour is quiet.
function speeds(models: [string, number][], seed: number): { speedHours: J[]; speedQuarters: J[] } {
  const rand = noise(seed);
  const at = (start: number, ms: number, base: number) => {
    const load = busy(localHourOf(start + ms / 2));
    if (load < 0.14) return null;
    const output = Math.round(load * (20_000 + 40_000 * rand()) * (ms / H));
    const tps = base * (1.12 - 0.22 * Math.min(1, load) + 0.12 * (rand() - 0.5));
    return { output, ms: Math.round((output / tps) * 1000) };
  };
  const speedHours: J[] = [];
  const speedQuarters: J[] = [];
  for (const [model, base] of models) {
    for (let j = 191; j >= 0; j--) {
      const hour = Math.floor(NOW / H) - j;
      const t = at(hour * H, H, base);
      if (t !== null) speedHours.push({ at: hour, model, ...t });
    }
    for (let j = 31; j >= 0; j--) {
      const quarter = Math.floor(NOW / (H / 4)) - j;
      const t = at(quarter * (H / 4), H / 4, base);
      if (t !== null) speedQuarters.push({ at: quarter, model, ...t });
    }
  }
  const order = (a: J, b: J) => a.at - b.at || (a.model < b.model ? -1 : a.model > b.model ? 1 : 0);
  return { speedHours: speedHours.sort(order), speedQuarters: speedQuarters.sort(order) };
}

function overview(accounts: Account[], models: [string, number][]): string {
  const all = accounts.map(made);
  const pace = { nowAt: NOW, profiles: Object.fromEntries(accounts.map((a, i) => [a.id, all[i]!.pace])), ...speeds(models, 7) };
  return JSON.stringify(profilesOverview(all.map((m) => m.item), (s) => (s === "ws1/st1" ? pace : undefined), NOW, OFFSET));
}

writeFileSync(OUT, `// Generated by client/core-ts/scripts/overview-fixture.ts: do not edit.

///|
/// The Profile overview of fx_summary_profiles' accounts, as the core makes it (\`profilesOverview\`).
let fx_overview_summary : String =
  #|${overview(SUMMARY, [["claude-opus-5-5", 62], ["claude-fable-5-2", 38], ["gpt-6.1-sol", 96]])}

///|
/// The Profile overview of fx_profiles' two subscriptions, as the core makes it.
let fx_overview_plain : String =
  #|${overview(PLAIN, [["claude-opus-5-5", 62], ["gpt-6.1-sol", 96]])}
`);
