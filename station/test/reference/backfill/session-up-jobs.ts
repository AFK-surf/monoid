// The steps src/store/session-up-jobs.ts built its lookup by before the MoonBit builder took them over, kept to compare
// the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/session-up-jobs.ts's.
import type { DatabaseSync } from "node:sqlite";
import { see, sessionUpJobsReady } from "../../../src/store/session-up-jobs.ts";

export * from "../../../src/store/session-up-jobs.ts";

export const SESSION_UP_JOBS_END = "SELECT rowid FROM jobs INDEXED BY jobs_by_session WHERE session_key = ? ORDER BY rowid DESC LIMIT 1";
export const SESSION_UP_JOBS_FIRST = `SELECT CAST(rowid AS TEXT) AS position FROM jobs INDEXED BY jobs_by_session
  WHERE session_key = ? AND rowid <= CAST(? AS INTEGER) ORDER BY rowid LIMIT ?`;
export const SESSION_UP_JOBS_NEXT = `SELECT CAST(rowid AS TEXT) AS position FROM jobs INDEXED BY jobs_by_session
  WHERE session_key = ? AND rowid > CAST(? AS INTEGER) AND rowid <= CAST(? AS INTEGER) ORDER BY rowid LIMIT ?`;
export function sessionUpJobsStep(db: DatabaseSync, session: string, limit = 256): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1) throw new RangeError("session up job batch must be positive");
  db.exec("BEGIN IMMEDIATE");
  try {
    if (sessionUpJobsReady(db, session)) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    db.prepare(`INSERT INTO session_up_job_scopes (session, last_rowid, end_rowid, complete)
      SELECT ?, NULL, (${SESSION_UP_JOBS_END}), 0
      WHERE NOT EXISTS (SELECT 1 FROM session_up_job_scopes WHERE session = ?)`).run(session, session, session);
    const scope = db.prepare(`SELECT CAST(last_rowid AS TEXT) AS last_rowid, CAST(end_rowid AS TEXT) AS end_rowid
      FROM session_up_job_scopes WHERE session = ?`).get(session) as { last_rowid: string | null; end_rowid: string | null };
    const rows = (scope.last_rowid === null
      ? db.prepare(SESSION_UP_JOBS_FIRST).all(session, scope.end_rowid, limit)
      : db.prepare(SESSION_UP_JOBS_NEXT).all(session, scope.last_rowid, scope.end_rowid, limit)) as { position: string }[];
    const put = db.prepare(see("CAST(? AS INTEGER)"));
    for (const row of rows) put.run(row.position);
    const done = rows.length < limit;
    db.prepare("UPDATE session_up_job_scopes SET last_rowid = CAST(? AS INTEGER), complete = ? WHERE session = ?")
      .run(rows.at(-1)?.position ?? scope.last_rowid, done ? 1 : 0, session);
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}