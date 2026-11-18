// GET /profiles/pace: each account's last PACE_HOURS hours as its Profile overview draws them (client/core-ts
// views/profiles-overview.ts): what its allowance said in each hour, and what its calls spent in each, as dollars at
// list prices by the window they count against (`scope`, as the allowance names its models' windows: Fable's, an
// Antigravity account's "gemini" and "3p"). Read of the two statistics kept at write (store/profile-hours.ts).
import { HOUR_MS, PACE_HOURS, type HourWindow, type SpeedQuarter, type SpendHour } from "../store/profile-hours.ts";
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
