// The steps src/store/widget-sources.ts built its lookup by before the MoonBit builder took them over, kept to compare
// the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/widget-sources.ts's.
import type { DatabaseSync } from "node:sqlite";
import { insertRows, insertInvalid, checkWidgetSources, WIDGET_SOURCE_POSITIONS_FIRST, WIDGET_SOURCE_POSITIONS_NEXT, WIDGET_SOURCE_POSITIONS_FIRST_FALLBACK, WIDGET_SOURCE_POSITIONS_NEXT_FALLBACK } from "../../../src/store/widget-sources.ts";

export * from "../../../src/store/widget-sources.ts";

type Scope = { last_n: string | null; end_n: string | null; complete: number };

export function widgetSourcesReady(db: DatabaseSync, thread: number): boolean {
  checkWidgetSources(db);
  return (db.prepare("SELECT complete FROM widget_source_scopes WHERE thread=?").get(thread) as { complete: number } | undefined)?.complete === 1;
}
const scopeOf = (db: DatabaseSync, thread: number): Scope | undefined => db.prepare(
  "SELECT CAST(last_n AS TEXT) AS last_n, CAST(end_n AS TEXT) AS end_n, complete FROM widget_source_scopes WHERE thread=?",
).get(thread) as Scope | undefined;
/// Prepare one old thread in bounded batches. Read cold positions before taking the writer; triggers preserve any
/// changes between that read and the primary-key recheck made while committing the batch.
export function widgetSourcesStep(db: DatabaseSync, thread: number, limit = 128): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 128) throw new RangeError("widget source batch must be between 1 and 128");
  if (widgetSourcesReady(db, thread)) return { done: true, visited: 0 };
  if (!scopeOf(db, thread)) {
    db.exec("BEGIN IMMEDIATE");
    try {
      db.prepare(`INSERT INTO widget_source_scopes (thread,last_n,end_n,complete)
        SELECT ?,NULL,(SELECT n FROM entries WHERE thread=? ORDER BY n DESC LIMIT 1),0
        WHERE NOT EXISTS (SELECT 1 FROM widget_source_scopes WHERE thread=?)`).run(thread, thread, thread);
      db.exec("COMMIT");
    } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
  }
  const before = scopeOf(db, thread)!;
  if (before.complete === 1) return { done: true, visited: 0 };
  // A partially upgraded store may lack one of these indexes. Its existing primary-key walk is still bounded per batch.
  const indexes = db.prepare(`SELECT count(*) AS n FROM sqlite_master WHERE type='index'
    AND name IN ('entries_said','entries_letters')`).get() as { n: number };
  const indexed = indexes.n === 2;
  const positions = (before.last_n === null
    ? db.prepare(indexed ? WIDGET_SOURCE_POSITIONS_FIRST : WIDGET_SOURCE_POSITIONS_FIRST_FALLBACK).all(thread, before.end_n, limit)
    : db.prepare(indexed ? WIDGET_SOURCE_POSITIONS_NEXT : WIDGET_SOURCE_POSITIONS_NEXT_FALLBACK).all(thread, before.last_n, before.end_n, limit)) as { n: string }[];
  db.exec("BEGIN IMMEDIATE");
  try {
    const now = scopeOf(db, thread);
    if (!now || now.last_n !== before.last_n || now.end_n !== before.end_n || now.complete !== before.complete) {
      db.exec("COMMIT"); return { done: now?.complete === 1, visited: 0 };
    }
    const message = "SELECT ? AS thread, CAST(? AS INTEGER) AS n";
    const addRows = db.prepare(insertRows(message));
    const addInvalid = db.prepare(insertInvalid(message));
    for (const position of positions) { addRows.run(thread, position.n); addInvalid.run(thread, position.n); }
    const done = positions.length < limit;
    db.prepare("UPDATE widget_source_scopes SET last_n=CAST(? AS INTEGER), complete=? WHERE thread=?")
      .run(positions.at(-1)?.n ?? before.last_n, done ? 1 : 0, thread);
    db.exec("COMMIT");
    return { done, visited: positions.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}