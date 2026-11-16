// The steps src/store/usage-retire.ts built its lookup by before the MoonBit builder took them over, kept to compare
// the program with: the station has no step in TypeScript to fall back to. What it still runs is src/store/usage-
// retire.ts's.
import type { DatabaseSync } from "node:sqlite";

import { quote, stopUsageIndexes } from "../../../src/store/usage-retire.ts";

export * from "../../../src/store/usage-retire.ts";

/// Seek the first batch by primary key. Every row deletion also releases its index entries; dropping a populated
/// index or table directly would visit its entire B-tree under one write lock.
export function usageIndexBatchSql(db: DatabaseSync, table: string): string {
  const columns = db.prepare(`PRAGMA table_info(${quote(table)})`).all() as { name: string; pk: number }[];
  const keys = columns.filter((column) => column.pk > 0).sort((a, b) => a.pk - b.pk).map((column) => quote(column.name));
  if (keys.length === 0) keys.push("rowid");
  const tuple = keys.length === 1 ? keys[0] : `(${keys.join(", ")})`;
  return `DELETE FROM ${quote(table)} WHERE ${tuple} IN (SELECT ${keys.join(", ")} FROM ${quote(table)} LIMIT ?)`;
}

/// One bounded delete is one transaction. Only drop a table and its indexes once every row has been removed.
export function dropUsageIndexStep(db: DatabaseSync, batch = 256): boolean {
  const row = db.prepare(`SELECT name FROM sqlite_master WHERE type = 'table' AND
    (name = 'usage_detail' OR name GLOB 'usage_detail_*' OR name = 'usage_main_calls')
    ORDER BY name LIMIT 1`).get() as { name: string } | undefined;
  if (row === undefined) return true;
  const removed = db.prepare(usageIndexBatchSql(db, row.name)).run(batch).changes;
  if (removed === 0) db.exec(`DROP TABLE IF EXISTS ${quote(row.name)}`);
  return false;
}

export function retireUsageIndexes(db: DatabaseSync): void {
  stopUsageIndexes(db);
  while (!dropUsageIndexStep(db)) { /* In-memory databases only; file databases use the background worker. */ }
}
