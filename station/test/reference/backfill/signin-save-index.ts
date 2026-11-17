// The steps src/vault/signin-save-index.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/vault/signin-save-index.ts's.
import type { DatabaseSync } from "node:sqlite";


export * from "../../../src/vault/signin-save-index.ts";

/// Visits no more than `limit` old sign-ins for this session; writes behind the cursor are covered by the triggers.
export function stepSigninSaveIndex(db: DatabaseSync, session: string, limit = 64): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1) throw new RangeError("sign-in index batch must be positive");
  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare("INSERT INTO signin_save_progress (session, status, row, done) SELECT ?, NULL, NULL, 0 WHERE NOT EXISTS (SELECT 1 FROM signin_save_progress WHERE session = ?)").run(session, session);
    const get = db.prepare("SELECT status, row, done FROM signin_save_progress WHERE session = ?");
    get.setReadBigInts(true);
    const state = get.get(session) as { status: string | null; row: bigint | null; done: bigint };
    if (state.done === 1n) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const select = (sql: string, ...args: (string | number | bigint | null)[]) => {
      const query = db.prepare(sql); query.setReadBigInts(true);
      return query.all(...args) as { status: string; row: bigint }[];
    };
    let rows: { status: string; row: bigint }[];
    if (state.status === null) {
      rows = select("SELECT status, rowid AS row FROM signin_asks INDEXED BY signin_asks_by_session WHERE session = ?1 ORDER BY status, rowid LIMIT ?2", session, limit);
    } else {
      // SQLite cannot seek the rowid part of a tuple comparison here: it would walk every earlier row with this
      // status. Seek the remaining rowids of that status first, then seek the next statuses if the batch has room.
      rows = select("SELECT status, rowid AS row FROM signin_asks INDEXED BY signin_asks_by_session WHERE session = ?1 AND status = ?3 AND rowid > ?4 ORDER BY status, rowid LIMIT ?2", session, limit, state.status, state.row);
      if (rows.length < limit) rows.push(...select("SELECT status, rowid AS row FROM signin_asks INDEXED BY signin_asks_by_session WHERE session = ?1 AND status > ?3 ORDER BY status, rowid LIMIT ?2", session, limit - rows.length, state.status));
    }
    const remember = db.prepare(`INSERT INTO signin_save_lookup (ask, session, save)
      SELECT id, session, json_extract(body, '$.save') FROM signin_asks WHERE rowid = ?1 AND json_type(body, '$.save') = 'text'
      AND NOT EXISTS (SELECT 1 FROM signin_save_lookup l WHERE l.ask = signin_asks.id)`);
    for (const row of rows) remember.run(row.row);
    const last = rows.at(-1), done = rows.length < limit;
    db.prepare("UPDATE signin_save_progress SET status = ?, row = ?, done = ? WHERE session = ?")
      .run(last?.status ?? state.status, last?.row ?? state.row, done ? 1 : 0, session);
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) { db.exec("ROLLBACK"); throw error; }
}
