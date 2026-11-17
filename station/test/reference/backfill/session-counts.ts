// The steps src/store/session-counts.ts built its lookup by before the MoonBit builder took them over, kept to compare
// the program with: the station has no step in TypeScript to fall back to. What it still runs is src/store/session-
// counts.ts's.
import type { DatabaseSync } from "node:sqlite";

import { checkVersion, displaced, see } from "../../../src/store/session-counts.ts";

export * from "../../../src/store/session-counts.ts";

export const SESSION_COUNT_FIRST = `SELECT CAST(rowid AS TEXT) AS position, key FROM sessions
  WHERE rowid <= CAST(? AS INTEGER) ORDER BY rowid LIMIT ?`;
export const SESSION_COUNT_NEXT = `SELECT CAST(rowid AS TEXT) AS position, key FROM sessions
  WHERE rowid > CAST(? AS INTEGER) AND rowid <= CAST(? AS INTEGER) ORDER BY rowid LIMIT ?`;
export const SESSION_COUNT_DISPLACED = displaced("?1", "?2", "?3");
/// Advance at most `limit` old rows. The fixed rowid boundary prevents newly allocated rows from extending the scan;
/// triggers count new and changed sessions immediately, including those moved behind or beyond its cursor.
export function sessionCountsStep(db: DatabaseSync, limit = 256): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1) throw new RangeError("session count batch must be positive");
  db.exec("BEGIN IMMEDIATE");
  try {
    const meta = db.prepare(`SELECT version, CAST(last_rowid AS TEXT) AS last_rowid, CAST(end_rowid AS TEXT) AS end_rowid, complete
      FROM session_count_meta WHERE id = 1`).get() as { version: number; last_rowid: string | null; end_rowid: string | null; complete: number } | undefined;
    if (meta === undefined) throw new Error("session count index version marker is missing");
    checkVersion(meta.version);
    if (meta.complete === 1) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const rows = (meta.last_rowid === null
      ? db.prepare(SESSION_COUNT_FIRST).all(meta.end_rowid, limit)
      : db.prepare(SESSION_COUNT_NEXT).all(meta.last_rowid, meta.end_rowid, limit)) as { position: string; key: string }[];
    const put = db.prepare(see("?"));
    for (const row of rows) put.run(row.key);
    const done = rows.length < limit;
    db.prepare("UPDATE session_count_meta SET last_rowid = CAST(? AS INTEGER), complete = ? WHERE id = 1")
      .run(rows.at(-1)?.position ?? meta.last_rowid, done ? 1 : 0);
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) {
    try { db.exec("ROLLBACK"); } catch {}
    throw error;
  }
}
