// The steps src/store/page-letter-index.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/page-letter-index.ts's.
import type { DatabaseSync } from "node:sqlite";

import { BATCH, checked, exists, installPageLetterIndex, scope, epochOf } from "../../../src/store/page-letter-index.ts";

export * from "../../../src/store/page-letter-index.ts";

const dirtyOverflow = (db: DatabaseSync, thread: number, token: string) =>
  db.prepare("SELECT 1 FROM page_letter_dirty WHERE thread=? AND token=? LIMIT 1 OFFSET 64").get(thread, token) !== undefined;

/// The metadata, dirty bound and later keyed reads must all be checked in the caller's single read snapshot.
export function pageLetterReady(db: DatabaseSync, thread: number): string | null {
  if (!installPageLetterIndex(db, false)) return null;
  const s = scope(db, thread);
  if (!s || s.epoch !== epochOf(db) || s.complete !== 1 || dirtyOverflow(db, thread, s.token)) return null;
  return s.token;
}

// Each arm is ordered by its integer key. The stale prepared keys skipped by the first arm and all dirty keys in the
// second arm total at most 64 because pageLetterReady checked the same snapshot.
export const PAGE_LETTER_KEYS = `SELECT CAST(p.n AS TEXT) AS n FROM (
    SELECT b.n FROM page_letter_rows b WHERE b.thread=?1 AND b.token=?2 AND b.n<CAST(?3 AS INTEGER)
      AND NOT EXISTS (SELECT 1 FROM page_letter_dirty d WHERE d.thread=b.thread AND d.token=b.token AND d.n=b.n)
    UNION ALL
    SELECT e.n FROM page_letter_dirty d CROSS JOIN entries e ON e.thread=d.thread AND e.n=d.n
      WHERE d.thread=?1 AND d.token=?2 AND d.n<CAST(?3 AS INTEGER) AND e.kind='message' AND e.letter IS NOT NULL
    ORDER BY n DESC LIMIT ?4
  ) p ORDER BY p.n DESC`;

/// The same bounded letter lookup in ascending order, for a Router reading messages after a position.
export const PAGE_LETTER_KEYS_AFTER = `SELECT CAST(p.n AS TEXT) AS n FROM (
    SELECT b.n FROM page_letter_rows b WHERE b.thread=?1 AND b.token=?2 AND b.n>CAST(?3 AS INTEGER)
      AND NOT EXISTS (SELECT 1 FROM page_letter_dirty d WHERE d.thread=b.thread AND d.token=b.token AND d.n=b.n)
    UNION ALL
    SELECT e.n FROM page_letter_dirty d CROSS JOIN entries e ON e.thread=d.thread AND e.n=d.n
      WHERE d.thread=?1 AND d.token=?2 AND d.n>CAST(?3 AS INTEGER) AND e.kind='message' AND e.letter IS NOT NULL
    ORDER BY n LIMIT ?4
  ) p ORDER BY p.n`;

function queueScope(db: DatabaseSync, thread: number, token: string): void {
  db.prepare(`INSERT INTO page_letter_garbage(thread,token) SELECT ?,?
    WHERE NOT EXISTS (SELECT 1 FROM page_letter_garbage WHERE thread=? AND token=?)`).run(thread, token, thread, token);
}

/// Scan at most 64 source keys or reconcile at most 64 changes in one transaction. A handover resumes its scope.
export function pageLetterStep(db: DatabaseSync, thread: number, limit = BATCH): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > BATCH) throw new RangeError("page letter batch must be 1–64");
  if (!installPageLetterIndex(db)) return { done: false, visited: 0 };
  db.exec("BEGIN IMMEDIATE");
  try {
    const epoch = epochOf(db);
    let s = scope(db, thread);
    if (!s || s.epoch !== epoch) {
      if (s) { queueScope(db, thread, s.token); db.prepare("DELETE FROM page_letter_scopes WHERE thread=?").run(thread); }
      db.prepare(`INSERT INTO page_letter_scopes(thread,token,epoch,cursor_n,end_n,complete)
        VALUES(?,lower(hex(randomblob(16))),?,NULL,(SELECT n FROM entries WHERE thread=? ORDER BY n DESC LIMIT 1),0)`)
        .run(thread, epoch, thread);
      s = scope(db, thread)!;
    }
    if (s.complete === 0) {
      const indexed = !!exists(db, "index", "entries_letters");
      const sql = `SELECT CAST(e.n AS TEXT) AS n,e.kind,e.letter FROM entries e ${indexed ? "INDEXED BY entries_letters" : ""}
        WHERE e.thread=?1 AND e.n<=CAST(?2 AS INTEGER) ${s.cursor_n === null ? "" : "AND e.n>CAST(?3 AS INTEGER)"}
        ${indexed ? "AND e.letter IS NOT NULL" : ""} ORDER BY e.n LIMIT ?${s.cursor_n === null ? 3 : 4}`;
      const rows = (s.cursor_n === null ? db.prepare(sql).all(thread, s.end_n, limit)
        : db.prepare(sql).all(thread, s.end_n, s.cursor_n, limit)) as { n: string; kind: string; letter: string | null }[];
      const put = db.prepare(`INSERT INTO page_letter_rows(thread,token,n) VALUES(?,?,CAST(? AS INTEGER))
        ON CONFLICT(thread,token,n) DO NOTHING`);
      for (const row of rows) if (row.kind === "message" && row.letter !== null) put.run(thread, s.token, row.n);
      db.prepare("UPDATE page_letter_scopes SET cursor_n=CAST(? AS INTEGER),complete=? WHERE thread=? AND token=?")
        .run(rows.at(-1)?.n ?? s.cursor_n, rows.length < limit ? 1 : 0, thread, s.token);
      const done = rows.length < limit && !dirtyOverflow(db, thread, s.token);
      db.exec("COMMIT");
      return { done, visited: rows.length };
    }
    const keys = db.prepare(`SELECT CAST(d.n AS TEXT) AS n FROM page_letter_dirty d
      WHERE d.thread=? AND d.token=? ORDER BY d.n LIMIT ?`).all(thread, s.token, limit) as { n: string }[];
    const drop = db.prepare("DELETE FROM page_letter_rows WHERE thread=? AND token=? AND n=CAST(? AS INTEGER)");
    const put = db.prepare(`INSERT INTO page_letter_rows(thread,token,n) SELECT e.thread,?,e.n FROM entries e
      WHERE e.thread=? AND e.n=CAST(? AS INTEGER) AND e.kind='message' AND e.letter IS NOT NULL`);
    const done = db.prepare("DELETE FROM page_letter_dirty WHERE thread=? AND token=? AND n=CAST(? AS INTEGER)");
    for (const key of keys) { drop.run(thread, s.token, key.n); put.run(s.token, thread, key.n); done.run(thread, s.token, key.n); }
    const ready = !dirtyOverflow(db, thread, s.token);
    db.exec("COMMIT");
    return { done: ready, visited: keys.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

export function pageLetterGcStep(db: DatabaseSync, limit = BATCH): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > BATCH) throw new RangeError("page letter batch must be 1–64");
  if (!installPageLetterIndex(db)) return { done: true, visited: 0 };
  db.exec("BEGIN IMMEDIATE");
  try {
    const stale = db.prepare(`SELECT thread,token FROM page_letter_scopes WHERE epoch<? ORDER BY epoch,thread LIMIT 1`)
      .get(epochOf(db)) as { thread: number; token: string } | undefined;
    if (stale) {
      queueScope(db, stale.thread, stale.token);
      db.prepare("DELETE FROM page_letter_scopes WHERE thread=? AND token=?").run(stale.thread, stale.token);
    }
    const garbage = db.prepare("SELECT thread,token FROM page_letter_garbage ORDER BY thread,token LIMIT 1").get() as
      { thread: number; token: string } | undefined;
    if (!garbage) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const remove = (table: "page_letter_rows" | "page_letter_dirty", count: number) => Number(db.prepare(`DELETE FROM ${table}
      WHERE thread=?1 AND token=?2 AND n IN (SELECT n FROM ${table} WHERE thread=?1 AND token=?2 ORDER BY n LIMIT ?3)`)
      .run(garbage.thread, garbage.token, count).changes);
    const rows = remove("page_letter_rows", limit);
    const dirty = rows < limit ? remove("page_letter_dirty", limit - rows) : 0;
    if (rows + dirty < limit) db.prepare("DELETE FROM page_letter_garbage WHERE thread=? AND token=?")
      .run(garbage.thread, garbage.token);
    const remaining = db.prepare("SELECT 1 FROM page_letter_garbage LIMIT 1").get() !== undefined
      || db.prepare("SELECT 1 FROM page_letter_scopes WHERE epoch<? ORDER BY epoch,thread LIMIT 1").get(epochOf(db)) !== undefined;
    db.exec("COMMIT");
    return { done: !remaining, visited: rows + dirty };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}
