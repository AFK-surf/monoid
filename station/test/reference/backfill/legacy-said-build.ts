// The steps src/store/legacy-said-build.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/legacy-said-build.ts's.
import type { DatabaseSync } from "node:sqlite";

import { VERSION, BATCH, hasLegacySaid, changed, notSelf, preparing, installLegacySaid, type Entry, meta, limitOf, drain } from "../../../src/store/legacy-said-build.ts";

export * from "../../../src/store/legacy-said-build.ts";

export const LEGACY_SAID_PAGE_STATE = `SELECT m.version,m.scanned,CASE WHEN m.scanned=1 THEN EXISTS (
    SELECT 1 FROM legacy_said_dirty WHERE thread=?1 LIMIT 1 OFFSET 64) ELSE 0 END AS needs_drain
  FROM legacy_said_meta m WHERE m.id=1`;
/// A page needs the completed lookup, or a bounded raw tail while it is being prepared or reconciled.
export function legacySaidPageState(db: DatabaseSync, thread: number): { preparing: boolean; needsDrain: boolean } {
  const row = db.prepare(LEGACY_SAID_PAGE_STATE).get(thread) as { version: number; scanned: number; needs_drain: number } | undefined;
  if (!row || row.version !== VERSION || (row.scanned !== 0 && row.scanned !== 1))
    throw new Error("legacy said lookup metadata is missing or invalid");
  return { preparing: row.scanned === 0, needsDrain: row.needs_drain !== 0 };
}

/// The global source scan is published in one transaction; dirty keys can then be reconciled per chat.
export function legacySaidScanReady(db: DatabaseSync): boolean {
  const row = db.prepare("SELECT version,scanned FROM legacy_said_meta WHERE id=1").get() as { version: number; scanned: number } | undefined;
  if (!row || row.version !== VERSION || (row.scanned !== 0 && row.scanned !== 1))
    throw new Error("legacy said lookup metadata is missing or invalid");
  return row.scanned === 1;
}

export const LEGACY_HAS_UNREAD = `SELECT CASE WHEN ${preparing} THEN EXISTS
    (SELECT 1 FROM entries e WHERE e.thread=?1 AND e.n>?2 AND e.kind='message' AND e.letter IS NULL AND ${notSelf("e")})
  WHEN EXISTS
    (SELECT 1 FROM legacy_said_dirty WHERE thread=?1 AND n>?2)
  THEN EXISTS (SELECT 1 FROM legacy_said s WHERE s.thread=?1 AND s.n>?2 AND ${notSelf("s")})
  ELSE EXISTS (SELECT 1 FROM legacy_said_build s WHERE s.thread=?1 AND s.n>?2 AND ${notSelf("s")}) END AS c`;
/// Prepare at most one bounded key range; the same transaction protects its cursor and staged rows.
export function legacySaidStep(db: DatabaseSync, limit = BATCH): { ready: boolean; visited: number } {
  limitOf(limit);
  installLegacySaid(db);
  db.exec("BEGIN IMMEDIATE");
  try {
    const m = meta(db);
    if (m.version !== VERSION) throw new Error(`legacy said version ${m.version} is incompatible with ${VERSION}`);
    if (m.scanned) { db.exec("COMMIT"); return { ready: true,visited: 0 }; }
    const columns = "CAST(e.thread AS TEXT) thread,CAST(e.n AS TEXT) n,e.kind,e.letter,e.author_kind,e.author";
    const rows: Entry[] = [];
    if (m.end_thread !== null) {
      if (m.cursor_thread !== null) {
        const same = m.cursor_thread === m.end_thread;
        const sql = `SELECT ${columns} FROM entries e WHERE e.thread=CAST(?1 AS INTEGER) AND e.n>CAST(?2 AS INTEGER)
          ${same ? "AND e.n<=CAST(?3 AS INTEGER) ORDER BY e.n LIMIT ?4" : "ORDER BY e.n LIMIT ?3"}`;
        rows.push(...(same ? db.prepare(sql).all(m.cursor_thread,m.cursor_n,m.end_n,limit)
          : db.prepare(sql).all(m.cursor_thread,m.cursor_n,limit)) as Entry[]);
      }
      if (rows.length < limit && m.cursor_thread !== m.end_thread) {
        const sql = `SELECT ${columns} FROM entries e WHERE e.thread<CAST(?1 AS INTEGER)
          ${m.cursor_thread === null ? "" : "AND e.thread>CAST(?2 AS INTEGER)"}
          ORDER BY e.thread,e.n LIMIT ?${m.cursor_thread === null ? 2 : 3}`;
        rows.push(...(m.cursor_thread === null ? db.prepare(sql).all(m.end_thread,limit-rows.length)
          : db.prepare(sql).all(m.end_thread,m.cursor_thread,limit-rows.length)) as Entry[]);
        if (rows.length < limit) rows.push(...db.prepare(`SELECT ${columns} FROM entries e
          WHERE e.thread=CAST(?1 AS INTEGER) AND e.n<=CAST(?2 AS INTEGER) ORDER BY e.n LIMIT ?3`)
          .all(m.end_thread,m.end_n,limit-rows.length) as Entry[]);
      }
    }
    const put = db.prepare(`INSERT INTO legacy_said_build VALUES(CAST(? AS INTEGER),CAST(? AS INTEGER),?,?)
      ON CONFLICT(thread,n) DO UPDATE SET author_kind=excluded.author_kind,author=excluded.author`);
    for (const row of rows) if (row.kind === "message" && row.letter === null) put.run(row.thread,row.n,row.author_kind,row.author);
    const last = rows.at(-1);
    const ready = rows.length < limit;
    db.prepare("UPDATE legacy_said_meta SET scanned=?,cursor_thread=CAST(? AS INTEGER),cursor_n=CAST(? AS INTEGER) WHERE id=1")
      .run(ready ? 1 : 0,last?.thread ?? m.cursor_thread,last?.n ?? m.cursor_n);
    db.exec("COMMIT");
    return { ready,visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

/// The scan's last batch atomically makes the prepared arms of the view visible.
export function publishLegacySaid(db: DatabaseSync): boolean {
  db.exec("BEGIN IMMEDIATE");
  try {
    const m = meta(db);
    if (m.version !== VERSION) throw new Error(`legacy said version ${m.version} is incompatible with ${VERSION}`);
    if (!hasLegacySaid(db)) throw new Error("legacy said metadata has no view");
    db.exec("COMMIT");
    return m.scanned === 1;
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

export function legacySaidDrain(db: DatabaseSync, limit = BATCH): number { return drain(db,limit); }

/// One low-priority transaction: finish the old scan first, then fold changed keys in bounded batches.
export function legacySaidMaintenanceStep(db: DatabaseSync): { done: boolean; visited: number } {
  if (!hasLegacySaid(db)) return { done: true, visited: 0 };
  if (!meta(db).scanned) {
    const result = legacySaidStep(db);
    return { done: false, visited: result.visited };
  }
  const visited = legacySaidDrain(db);
  return { done: visited < BATCH, visited };
}
