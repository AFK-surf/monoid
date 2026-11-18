// An account's last hours, as its Profile overview draws them (GET /profiles/pace): what its allowance said in each hour
// (`profile_quota_hours`, the last reading of the hour, written with it: store.ts setProfileQuota, which holds PACE_HOURS
// and cuts them where it writes: no sweep) and what its calls spent in each, by model (usage_15m's quarters added up by
// hour, store/usage-15m.ts: the one statistic of `usage`). A read takes the PACE_HOURS asked alone.
import type { DatabaseSync } from "node:sqlite";

/// How many hours back an account's are kept and read (8 days: a week's window and the day before it).
export const PACE_HOURS = 192;
export const HOUR_MS = 3_600_000;

const QUOTA_SCHEMA = `
CREATE TABLE IF NOT EXISTS profile_quota_hours (
  profile TEXT NOT NULL,
  hour INTEGER NOT NULL,
  windows_json TEXT NOT NULL,
  at INTEGER NOT NULL,
  PRIMARY KEY (profile, hour)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS profile_quota_hours_hour ON profile_quota_hours (hour);
`;

/// Installs the allowances' hours (the calls' are usage_15m's, store/usage-15m.ts).
export function installProfileHours(db: DatabaseSync): void {
  db.exec(QUOTA_SCHEMA);
}

/// What a profile's calls of one model spent in one hour, added up.
export type SpendHour = {
  hour: number; profile: string; runtime: string; model: string | null; fast: boolean; calls: number; input: number; cacheRead: number;
  cacheWrite: number; cacheWriteLong: number; output: number; genMs?: number; genOutput?: number;
};

/// What a profile's calls of one model whose time is known took (ms) and wrote in one quarter hour (usage/speed).
export type SpeedQuarter = { quarter: number; profile: string; model: string; genMs: number; genOutput: number };

/// How many hours back the quarters of the calls' times are read (Profile overview's 输出速度 over 6 hours, each point
/// the hour before it).
export const SPEED_QUARTER_HOURS = 8;

/// The hours kept from `?` on, by their hour's index alone (store.ts profileHours; profile-hours-bounded.test.ts).
export const QUOTA_HOURS_READ = `SELECT profile, hour, at, windows_json FROM profile_quota_hours INDEXED BY profile_quota_hours_hour
  WHERE hour >= ? ORDER BY profile, hour`;
/// The calls' spending by hour, account and model, from usage_15m (the one statistic of `usage`, AGENTS.md) by its
/// quarters' index from the quarter `?` on: a read of those PACE_HOURS' quarters alone, however many are older.
export const SPEND_HOURS_READ = `SELECT (CASE WHEN quarter >= 0 THEN quarter / 4 ELSE (quarter - 3) / 4 END) AS hour,
    profile, runtime, model, fast,
    SUM(calls) AS calls, SUM(input) AS input, SUM(cache_read) AS cache_read,
    SUM(cache_write) AS cache_write, SUM(cache_write_long) AS cache_write_long, SUM(output) AS output,
    SUM(gen_ms) AS gen_ms, SUM(gen_output) AS gen_output
  FROM usage_15m INDEXED BY usage_15m_quarter
  WHERE quarter >= ? AND profile <> '' AND calls > 0
  GROUP BY 1, 2, 3, 4, 5
  ORDER BY profile, hour`;
/// The calls' times by quarter, account and model from the quarter `?` on, by the same index: the last
/// SPEED_QUARTER_HOURS' quarters alone.
export const SPEED_QUARTERS_READ = `SELECT quarter, profile, model, SUM(gen_ms) AS gen_ms, SUM(gen_output) AS gen_output
  FROM usage_15m INDEXED BY usage_15m_quarter
  WHERE quarter >= ? AND profile <> '' AND model <> '' AND gen_ms > 0
  GROUP BY 1, 2, 3
  ORDER BY quarter, profile, model`;

/// One window of an allowance as an hour keeps it.
export type HourWindow = { label: string; scope: string | null; usedPercent: number; resetsAt: number | null; minutes: number | null };

/// What an allowance's windows (its own and its models', `scoped`) an hour keeps of them.
export function hourWindows(quota: unknown): HourWindow[] {
  if (typeof quota !== "object" || quota === null) return [];
  const q = quota as Record<string, unknown>;
  const all = [...(Array.isArray(q.windows) ? q.windows : []), ...(Array.isArray(q.scoped) ? q.scoped : [])];
  const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : null);
  return all.flatMap((w) => {
    if (typeof w !== "object" || w === null) return [];
    const r = w as Record<string, unknown>;
    const used = num(r.usedPercent);
    if (used === null) return [];
    return [{
      label: typeof r.label === "string" ? r.label : "",
      scope: typeof r.scope === "string" && r.scope !== "" ? r.scope : null,
      usedPercent: used,
      resetsAt: num(r.resetsAt),
      minutes: num(r.minutes),
    }];
  });
}
