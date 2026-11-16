// The statistics of usage kept before the quarters (store/usage-15m.ts), retired once the station before has gone (it
// read and wrote them to its end): their writers stopped in one short write (`stopUsageIndexes`), then their tables
// freed in bounded deletes, each a transaction of its own, by the MoonBit builder (station/mb src/usagefill
// `drop_step`; the TypeScript it is held to is test/reference/backfill/usage-retire.ts).
import type { DatabaseSync } from "node:sqlite";

export const quote = (name: string) => `"${name.replaceAll('"', '""')}"`;

/// The tables retired: the per-call indexes and details (usage_detail*, usage_main_calls), the minute and quarter
/// statistics (usage_minute*, but usage_minute_scope, which keeps where each session's context is; usage_day_quarters,
/// usage_quarters), the minute summaries and their totals (usage_compact*, usage_summary*), the year (usage_history*)
/// and the marker of an emergency stop (usage_retired_detail).
export const RETIRED_TABLES = `(name = 'usage_detail' OR name GLOB 'usage_detail_*' OR name = 'usage_main_calls'
  OR name = 'usage_minute' OR name IN ('usage_minute_all', 'usage_minute_seen', 'usage_minute_sessions')
  OR name IN ('usage_day_quarters', 'usage_quarters') OR name = 'usage_compact' OR name GLOB 'usage_compact_*'
  OR name GLOB 'usage_summary_*' OR name = 'usage_history' OR name GLOB 'usage_history_*' OR name = 'usage_retired_detail')`;
/// Their writers: on `usage`, `sessions` and themselves (those of the bounded contexts are usage-compact.ts's own, of
/// other names, as are the quarters', the totals' and the first call's).
const RETIRED_TRIGGERS = `(name GLOB 'usage_detail_*' OR name GLOB 'usage_daily_detail_*' OR name GLOB 'usage_main_calls_*'
  OR name = 'usage_compactions_add' OR name GLOB 'usage_minute_*' OR name GLOB 'usage_quarters_*'
  OR name GLOB 'usage_compact_*' OR name GLOB 'usage_summary_*' OR name GLOB 'usage_history_*')`;

/// Whether the writers of the old statistics are stopped (none left).
export const usageIndexesStopped = (db: DatabaseSync): boolean =>
  db.prepare(`SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND ${RETIRED_TRIGGERS} LIMIT 1`).get() === undefined;

/// Stop the old statistics' writers, all in one write. Only once the station before has gone: it reads them.
export function stopUsageIndexes(db: DatabaseSync): void {
  if (usageIndexesStopped(db)) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    const triggers = db.prepare(`SELECT name FROM sqlite_master WHERE type = 'trigger' AND ${RETIRED_TRIGGERS}`).all() as { name: string }[];
    for (const { name } of triggers) db.exec(`DROP TRIGGER ${quote(name)}`);
    db.exec("COMMIT");
  } catch (error) { db.exec("ROLLBACK"); throw error; }
}

/// Whether a retired table is still to be freed (by the MoonBit program, `--builder usage-retire`; the steps it took
/// over are test/reference/backfill/usage-retire.ts's).
export const usageIndexesLeft = (db: DatabaseSync): boolean =>
  db.prepare(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND ${RETIRED_TABLES} LIMIT 1`).get() !== undefined;
