// Stop maintaining the per-call usage indexes after the previous station has exited. A durable marker makes the
// change atomic for readers and prevents a later startup from rebuilding them. Free their pages in bounded batches.
import type { DatabaseSync } from "node:sqlite";

export const quote = (name: string) => `"${name.replaceAll('"', '""')}"`;
export const retiredUsage = (db: DatabaseSync): boolean => db.prepare(
  "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'usage_retired_detail'",
).get() !== undefined;

export function stopUsageIndexes(db: DatabaseSync): void {
  if (retiredUsage(db)) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!retiredUsage(db)) {
      const triggers = db.prepare(`SELECT name FROM sqlite_master WHERE type = 'trigger' AND
        (name GLOB 'usage_detail_*' OR name GLOB 'usage_daily_detail_*' OR name GLOB 'usage_main_calls_*'
          OR name = 'usage_compactions_add')`).all() as { name: string }[];
      for (const { name } of triggers) db.exec(`DROP TRIGGER ${quote(name)}`);
      db.exec("CREATE TABLE usage_retired_detail (id INTEGER PRIMARY KEY CHECK (id = 1)); INSERT INTO usage_retired_detail VALUES (1)");
    }
    db.exec("COMMIT");
  } catch (error) { db.exec("ROLLBACK"); throw error; }
}

const LEFT = `SELECT name FROM sqlite_master WHERE type = 'table' AND
    (name = 'usage_detail' OR name GLOB 'usage_detail_*' OR name = 'usage_main_calls')
    ORDER BY name LIMIT 1`;

/// Whether a retired per-call index is still to be freed (by the MoonBit program, `--builder usage-retire`).
export const usageIndexesLeft = (db: DatabaseSync): boolean => db.prepare(LEFT).get() !== undefined;
