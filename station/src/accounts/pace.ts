// GET /profiles/pace: each account's last PACE_HOURS hours as its Profile overview draws them (client/core-ts
// views/profiles-overview.ts): what its allowance said in each hour, and what its calls spent in each, as dollars at
// list prices by the window they count against (`scope`, as the allowance names its models' windows: Fable's, an
// Antigravity account's "gemini" and "3p"). Read of the two statistics kept at write (store/profile-hours.ts).
import { createHash } from "node:crypto";
import { HOUR_MS, PACE_HOURS, type HourWindow, type QuotaHour, type SpeedQuarter, type SpendHour } from "../store/profile-hours.ts";
import { price } from "../read/usage.ts";

export type PaceQuota = { hour: number; at: number; windows: HourWindow[] };
export type PaceSpend = { hour: number; scope: string; weight: number };
/// What the calls of one model whose time is known took (ms) and wrote in an hour (`at` its index) or a quarter hour, of
/// the accounts shown together: Profile overview's 输出速度 (usage/speed).
export type PaceSpeed = { at: number; model: string; output: number; ms: number };
export type PaceView = {
  nowAt: number; fromHour: number; profiles: Record<string, { quotas: PaceQuota[]; spend: PaceSpend[] }>;
  speedHours: PaceSpeed[]; speedQuarters: PaceSpeed[];
};

export type PaceHourWindowV2 = {
  label?: string;
  scope: string | null;
  usedPercent: number;
  resetsAt: number | null;
  minutes: number | null;
};
export type PaceQuotaV2 = { hour: number; at: number; windows: PaceHourWindowV2[] };
export type PaceProfileV2 = { quotas: PaceQuotaV2[]; spend: PaceSpend[] };
export type PaceViewV2 = {
  rev: string;
  nowAt: number;
  fromHour: number;
  profiles: Record<string, PaceProfileV2>;
  speedHours: PaceSpeed[];
  speedQuarters: PaceSpeed[];
};
export type PaceUnchangedV2 = { unchanged: true; rev: string };
export type PaceDeltaV2 = {
  delta: true;
  base: string;
  rev: string;
  nowAt: number;
  fromHour: number;
  keep: string[];
  profiles: Record<string, PaceProfileV2>;
  speedHours?: PaceSpeed[];
  speedQuarters?: PaceSpeed[];
};
export type PaceResponseV2 = PaceViewV2 | PaceUnchangedV2 | PaceDeltaV2;

export function compactWindow(w: HourWindow): PaceHourWindowV2 {
  const omitLabel =
    w.minutes !== null &&
    ((typeof w.scope === "string" && w.scope.trim() !== "") ||
      (typeof w.label === "string" && !w.label.includes(" · ")));
  return omitLabel
    ? { scope: w.scope, usedPercent: w.usedPercent, resetsAt: w.resetsAt, minutes: w.minutes }
    : { label: w.label, scope: w.scope, usedPercent: w.usedPercent, resetsAt: w.resetsAt, minutes: w.minutes };
}

export function paceViewV2(v1: PaceView, rev: string): PaceViewV2 {
  const profiles: Record<string, PaceProfileV2> = {};
  for (const [id, p] of Object.entries(v1.profiles)) {
    profiles[id] = {
      quotas: p.quotas.map((q) => ({ hour: q.hour, at: q.at, windows: q.windows.map(compactWindow) })),
      spend: p.spend,
    };
  }
  return {
    rev,
    nowAt: v1.nowAt,
    fromHour: v1.fromHour,
    profiles,
    speedHours: v1.speedHours,
    speedQuarters: v1.speedQuarters,
  };
}

function sha16(v: unknown): string {
  return createHash("sha256").update(JSON.stringify(v)).digest("hex").slice(0, 16);
}

export function hashPaceV2(v2: PaceViewV2): { profileHashes: Map<string, string>; speedHoursHash: string; speedQuartersHash: string } {
  const profileHashes = new Map<string, string>();
  for (const [id, p] of Object.entries(v2.profiles)) {
    profileHashes.set(id, sha16(p));
  }
  return {
    profileHashes,
    speedHoursHash: sha16(v2.speedHours),
    speedQuartersHash: sha16(v2.speedQuarters),
  };
}

export function sameQuotaHours(a: readonly QuotaHour[], b: readonly QuotaHour[]): boolean {
  if (a === b) return true;
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    const x = a[i]!;
    const y = b[i]!;
    if (x.profile !== y.profile || x.hour !== y.hour || x.at !== y.at || x.windows.length !== y.windows.length) return false;
    for (let j = 0; j < x.windows.length; j++) {
      const wx = x.windows[j]!;
      const wy = y.windows[j]!;
      if (wx.label !== wy.label || wx.scope !== wy.scope || wx.usedPercent !== wy.usedPercent || wx.resetsAt !== wy.resetsAt || wx.minutes !== wy.minutes) return false;
    }
  }
  return true;
}

export function sameSpendHours(a: readonly SpendHour[], b: readonly SpendHour[]): boolean {
  if (a === b) return true;
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    const x = a[i]!;
    const y = b[i]!;
    if (
      x.hour !== y.hour ||
      x.profile !== y.profile ||
      x.runtime !== y.runtime ||
      x.model !== y.model ||
      x.fast !== y.fast ||
      x.calls !== y.calls ||
      x.input !== y.input ||
      x.cacheRead !== y.cacheRead ||
      x.cacheWrite !== y.cacheWrite ||
      x.cacheWriteLong !== y.cacheWriteLong ||
      x.output !== y.output ||
      (x.genMs ?? 0) !== (y.genMs ?? 0) ||
      (x.genOutput ?? 0) !== (y.genOutput ?? 0)
    ) return false;
  }
  return true;
}

export function sameSpeedQuarters(a: readonly SpeedQuarter[], b: readonly SpeedQuarter[]): boolean {
  if (a === b) return true;
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    const x = a[i]!;
    const y = b[i]!;
    if (x.quarter !== y.quarter || x.profile !== y.profile || x.model !== y.model || x.genMs !== y.genMs || x.genOutput !== y.genOutput) return false;
  }
  return true;
}

/// The calls' times of the profiles `shown` keeps, added up by `at` and model, in their order.
function speedOf(rows: { at: number; profile: string; model: string | null; genMs: number; genOutput: number }[], shown: (profile: string) => boolean): PaceSpeed[] {
  const by = new Map<string, PaceSpeed>();
  for (const r of rows) {
    if (!shown(r.profile) || r.model === null || r.model === "" || !(r.genMs > 0)) continue;
    const key = `${r.at}\u0000${r.model}`;
    const was = by.get(key);
    if (was !== undefined) { was.output += r.genOutput; was.ms += r.genMs; }
    else by.set(key, { at: r.at, model: r.model, output: r.genOutput, ms: r.genMs });
  }
  return [...by.values()].sort((a, b) => a.at - b.at || (a.model < b.model ? -1 : a.model > b.model ? 1 : 0));
}

/// What an hour of one model's calls weighs: what they would cost at its list price, or for a model with none, what
/// they would at a middling one (input $1, cache read 0.1×, a cache write 1.25×, output $5 a million).
export function spendWeight(s: SpendHour): number {
  const p = s.model === null ? null : price(s.model);
  const writes = s.cacheWrite * 1.25 + s.cacheWriteLong * 2.0;
  const dollars = p === null
    ? (s.input + s.cacheRead * 0.1 + writes + s.output * 5) / 1e6
    : (s.input * p.input + writes * p.input + s.cacheRead * p.cacheRead + s.output * p.output) / 1e6;
  return Math.max(0, dollars * (s.fast ? 2 : 1));
}

/// The windows an hour of a runtime's model counts against ("" the account's own), by the `scope` the allowance gives
/// them (accounts/agy-quota.ts `groupMeta`): a Fable (Mythos) model's against its own week and the account's; on an
/// Antigravity account a Gemini (or Gemma) model's against "gemini", Argon's its own week too, and every other model
/// (Claude, GPT) against "3p": agy-quota.ts `agyScopeForModel`'s rule, written again here so that this stays free of
/// what that file imports (test/profile-quota-hours.test.ts holds the two to one answer).
export function spendScopes(runtime: string, model: string | null): string[] {
  const raw = (model ?? "").trim().toLowerCase();
  // (the model's bare name: no provider path, no variant in brackets, no version after "@", no vendor prefix)
  const bare = (raw.split("[")[0]?.split("/").pop() ?? "").split("@")[0]!.replace(/^(?:[a-z]+\.)+/, "");
  if (runtime === "claude" && (bare.includes("fable") || bare.includes("mythos"))) return ["Fable", ""];
  if (runtime === "agy") {
    if (bare === "" || bare.startsWith("gemini") || bare.startsWith("gemma")) {
      return bare.includes("argon") ? ["gemini", "Argon"] : ["gemini"];
    }
    return ["3p"];
  }
  return [""];
}

/// The view of what the store read, for the profiles `shown` keeps (the viewer's workspace's).
export function paceView(nowAt: number, read: { quotas: { profile: string; hour: number; at: number; windows: HourWindow[] }[]; spend: SpendHour[]; speed?: SpeedQuarter[] },
  shown: (profile: string) => boolean): PaceView {
  const nowHour = Math.floor(nowAt / HOUR_MS);
  const profiles: PaceView["profiles"] = {};
  const of = (p: string) => (profiles[p] ??= { quotas: [], spend: [] });
  for (const q of read.quotas) if (shown(q.profile)) of(q.profile).quotas.push({ hour: q.hour, at: q.at, windows: q.windows });
  const spent = new Map<string, Map<string, number>>();
  for (const s of read.spend) {
    if (!shown(s.profile)) continue;
    const w = spendWeight(s);
    if (w <= 0) continue;
    const byKey = spent.get(s.profile) ?? new Map<string, number>();
    spent.set(s.profile, byKey);
    for (const scope of spendScopes(s.runtime, s.model)) {
      const key = `${s.hour}\u0000${scope}`;
      byKey.set(key, (byKey.get(key) ?? 0) + w);
    }
  }
  for (const [profile, byKey] of spent) {
    const list = of(profile).spend;
    for (const [key, weight] of byKey) {
      const [hour, scope] = key.split("\u0000") as [string, string];
      list.push({ hour: Number(hour), scope, weight: Math.round(weight * 1e6) / 1e6 });
    }
    list.sort((a, b) => a.hour - b.hour || (a.scope < b.scope ? -1 : a.scope > b.scope ? 1 : 0));
  }
  const speedHours = speedOf(read.spend.map((s) => ({ at: s.hour, profile: s.profile, model: s.model, genMs: s.genMs ?? 0, genOutput: s.genOutput ?? 0 })), shown);
  const speedQuarters = speedOf((read.speed ?? []).map((s) => ({ at: s.quarter, profile: s.profile, model: s.model, genMs: s.genMs, genOutput: s.genOutput })), shown);
  return { nowAt, fromHour: nowHour - PACE_HOURS, profiles, speedHours, speedQuarters };
}
