// The steps the usage retirement takes before the MoonBit builder took them over (station/mb src/usagefill, run by
// src/usage/module.ts `retireAfterPrevious`), kept to compare the program with and for databases in memory: the
// station has no step in TypeScript to fall back to. What it still runs is src/store/usage-retire.ts's and
// src/store/usage-15m.ts's.
import type { DatabaseSync } from "node:sqlite";
import { QUARTER_MS, hasUsage15m, usage15mSince } from "../../../src/store/usage-15m.ts";
import { RETIRED_TABLES, quote, stopUsageIndexes, usageIndexesStopped } from "../../../src/store/usage-retire.ts";

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

/// One bounded delete is one transaction (station/mb src/usagefill `drop_step`). Only drop a table and its indexes once
/// every row has been removed. True when none is left; none taken while their writers still run (they are stopped
/// first: then nothing is left to do now, and a later start takes them).
export function dropUsageIndexStep(db: DatabaseSync, batch = 256): boolean {
  if (!usageIndexesStopped(db)) return true;
  const row = db.prepare(`SELECT name FROM sqlite_master WHERE type = 'table' AND ${RETIRED_TABLES} ORDER BY name LIMIT 1`)
    .get() as { name: string } | undefined;
  if (row === undefined) return true;
  const removed = db.prepare(usageIndexBatchSql(db, row.name)).run(batch).changes;
  if (removed === 0) db.exec(`DROP TABLE IF EXISTS ${quote(row.name)}`);
  return false;
}

/// All of it at once, the writers stopped first: for a database in memory, which no builder opens.
export function retireUsageIndexes(db: DatabaseSync): void {
  stopUsageIndexes(db);
  while (!dropUsageIndexStep(db)) { /* each step a transaction of its own */ }
}

const FILL_BATCH = 256;

/// One step of taking in the calls from before the quarters were installed (rollup_counted = 0), newest first: at
/// least `batch` calls, or those left, and whole quarters, in one transaction with the `since` it moves back to, so a
/// read always knows which days are complete and a stopped fill goes on from there. True when none is left. A call
/// written meanwhile counts by the triggers either way, so none is missed or counted twice. What station/mb
/// src/usagefill `fill_step`, which the station runs, is held to.
export function fillUsage15mStep(db: DatabaseSync, batch = FILL_BATCH): boolean {
  if (!hasUsage15m(db)) return true;
  db.exec("BEGIN IMMEDIATE");
  try {
    const since = usage15mSince(db);
    if (since === null) { db.exec("COMMIT"); return true; }
    const before = Math.ceil(since / QUARTER_MS) * QUARTER_MS;
    const next = (db.prepare("SELECT at FROM usage INDEXED BY usage_at WHERE at < ? ORDER BY at DESC LIMIT 1 OFFSET ?").get(before, batch - 1)
      ?? db.prepare("SELECT at FROM usage INDEXED BY usage_at WHERE at < ? ORDER BY at LIMIT 1").get(before)) as { at: number } | undefined;
    if (next === undefined) {
      db.prepare("UPDATE usage_15m_meta SET since = NULL WHERE id = 1").run();
      db.exec("COMMIT");
      return true;
    }
    const from = Math.floor(next.at / QUARTER_MS) * QUARTER_MS;
    db.prepare("UPDATE usage INDEXED BY usage_at SET rollup_counted = 1 WHERE at >= ? AND at < ? AND rollup_counted = 0").run(from, before);
    db.prepare("UPDATE usage_15m_meta SET since = ? WHERE id = 1").run(Math.min(since, from));
    db.exec("COMMIT");
    return false;
  } catch (error) { db.exec("ROLLBACK"); throw error; }
}

