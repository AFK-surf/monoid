// The steps src/store/session-list-index.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/session-list-index.ts's.
import type { DatabaseSync } from "node:sqlite";
import { SESSION_LIST_SEE_POSITION, checkVersion, sessionListReady } from "../../../src/store/session-list-index.ts";

export * from "../../../src/store/session-list-index.ts";

export const SESSION_LIST_FIRST = `SELECT CAST(rowid AS TEXT) AS position FROM sessions
  WHERE rowid <= CAST(? AS INTEGER) ORDER BY rowid LIMIT ?`;
export const SESSION_LIST_NEXT = `SELECT CAST(rowid AS TEXT) AS position FROM sessions
  WHERE rowid > CAST(? AS INTEGER) AND rowid <= CAST(? AS INTEGER) ORDER BY rowid LIMIT ?`;
export const SESSION_LIST_CONNECT = `SELECT s.* FROM session_list_rows i INDEXED BY session_list_connect
  CROSS JOIN sessions s ON s.key = i.session WHERE i.archived = ?1 AND i.connect = ?2
  ORDER BY s.last_active_at DESC, s.rowid ASC`;
export function sessionListStep(db: DatabaseSync, limit = 256): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1) throw new RangeError("session list batch must be positive");
  db.exec("BEGIN IMMEDIATE");
  try {
    const meta = db.prepare(`SELECT version, CAST(last_rowid AS TEXT) AS last_rowid, CAST(end_rowid AS TEXT) AS end_rowid, complete
      FROM session_list_meta WHERE id = 1`).get() as { version: number; last_rowid: string | null; end_rowid: string | null; complete: number } | undefined;
    if (meta === undefined) throw new Error("session list index version marker is missing");
    checkVersion(meta.version);
    if (meta.complete === 1) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const rows = (meta.last_rowid === null
      ? db.prepare(SESSION_LIST_FIRST).all(meta.end_rowid, limit)
      : db.prepare(SESSION_LIST_NEXT).all(meta.last_rowid, meta.end_rowid, limit)) as { position: string }[];
    const put = db.prepare(SESSION_LIST_SEE_POSITION);
    for (const row of rows) put.run(row.position);
    const done = rows.length < limit;
    db.prepare("UPDATE session_list_meta SET last_rowid = CAST(? AS INTEGER), complete = ? WHERE id = 1")
      .run(rows.at(-1)?.position ?? meta.last_rowid, done ? 1 : 0);
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}
// Version 1 lists prepared by older stations may have missed NUL or non-UTF-8 session keys. Search may use the list
// as an exhaustive candidate set only after those rows have been revisited. Existing triggers maintain new changes.
export function auditSessionListStep(db: DatabaseSync, limit = 256): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1) throw new RangeError("session list audit batch must be positive");
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!sessionListReady(db)) { db.exec("COMMIT"); return { done: false, visited: 0 }; }
    db.exec(`CREATE TABLE IF NOT EXISTS search_job_session_audit (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL,
      last_rowid INTEGER, end_rowid INTEGER, complete INTEGER NOT NULL) WITHOUT ROWID;
      INSERT INTO search_job_session_audit (id, version, last_rowid, end_rowid, complete)
        SELECT 1, 1, NULL, (SELECT rowid FROM sessions ORDER BY rowid DESC LIMIT 1), NOT EXISTS (SELECT 1 FROM sessions LIMIT 1)
        WHERE NOT EXISTS (SELECT 1 FROM search_job_session_audit WHERE id = 1)`);
    const meta = db.prepare(`SELECT version, CAST(last_rowid AS TEXT) AS last_rowid, CAST(end_rowid AS TEXT) AS end_rowid, complete
      FROM search_job_session_audit WHERE id = 1`).get() as { version: number; last_rowid: string | null; end_rowid: string | null; complete: number };
    if (meta.version !== 1) throw new Error(`search job session audit version ${meta.version} is incompatible with 1`);
    if (meta.complete === 1) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const rows = (meta.last_rowid === null
      ? db.prepare(SESSION_LIST_FIRST).all(meta.end_rowid, limit)
      : db.prepare(SESSION_LIST_NEXT).all(meta.last_rowid, meta.end_rowid, limit)) as { position: string }[];
    const put = db.prepare(SESSION_LIST_SEE_POSITION);
    for (const row of rows) put.run(row.position);
    const done = rows.length < limit;
    db.prepare("UPDATE search_job_session_audit SET last_rowid = CAST(? AS INTEGER), complete = ? WHERE id = 1")
      .run(rows.at(-1)?.position ?? meta.last_rowid, done ? 1 : 0);
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}