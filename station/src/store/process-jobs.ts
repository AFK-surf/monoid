// Jobs without a process group include waiting remote tasks. Keep only running groups here, so a memory or resources
// check need not read that queue. Old jobs are brought forward in small batches and older writers maintain the keys.
import type { DatabaseSync, StatementSync } from "node:sqlite";

export const VERSION = 1;
export const EXISTS = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'process_job_meta'";
const statements = new WeakMap<DatabaseSync, Map<string, StatementSync>>();
export const presence = new WeakMap<DatabaseSync, boolean>();
function statement(db: DatabaseSync, sql: string): StatementSync {
  let cached = statements.get(db);
  if (cached === undefined) { cached = new Map(); statements.set(db, cached); }
  let result = cached.get(sql);
  if (result === undefined) { result = db.prepare(sql); cached.set(sql, result); }
  return result;
}

export const active = (row: string) => `(${row}.state = 'running' AND ${row}.pgid IS NOT NULL)`;
export const changed = `OLD.rowid IS NOT NEW.rowid OR OLD.id IS NOT NEW.id OR OLD.token IS NOT NEW.token
  OR ${active("OLD")} IS NOT ${active("NEW")} OR EXISTS (SELECT 1 FROM process_job_replaced)`;
// Seek each unique identity before testing the state. Putting the OR and the state in one WHERE lets SQLite choose
// jobs_up(state) instead, rereading the entire running queue on each insert.
export const conflict = (id: string, token: string, rowid: string) => `SELECT j.id FROM (
  SELECT rowid AS position FROM jobs WHERE id = ${id}
  UNION SELECT rowid FROM jobs WHERE token = ${token}
  UNION SELECT rowid FROM jobs WHERE rowid = ${rowid}
) p CROSS JOIN jobs j ON j.rowid = p.position WHERE ${active("j")} AND j.id IS NOT NULL`;
export const conflicts = conflict("NEW.id", "NEW.token", "NEW.rowid");
export const stage = (old: boolean) => `DELETE FROM process_job_replaced WHERE job IS NOT NULL;
  INSERT INTO process_job_replaced (job) ${conflicts}
    ${old ? `UNION SELECT OLD.id WHERE OLD.id IS NOT NULL AND ${active("OLD")}` : ""};`;
export const see = (rowid: string) => `INSERT INTO process_job_rows (job)
  SELECT j.id FROM jobs j WHERE j.rowid = ${rowid} AND j.id IS NOT NULL AND ${active("j")}
    AND NOT EXISTS (SELECT 1 FROM process_job_rows p WHERE p.job = j.id);`;
export const reconcile = `DELETE FROM process_job_rows WHERE job IN (SELECT job FROM process_job_replaced)
    AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.id = process_job_rows.job AND ${active("j")});
  INSERT INTO process_job_rows (job)
    SELECT j.id FROM process_job_replaced p CROSS JOIN jobs j ON j.id = p.job
    WHERE ${active("j")} AND NOT EXISTS (SELECT 1 FROM process_job_rows r WHERE r.job = j.id);
  DELETE FROM process_job_replaced WHERE job IS NOT NULL;`;

export const PROCESS_JOBS = `SELECT j.id, j.session_key, j.name, j.port, j.pgid FROM process_job_rows p
  CROSS JOIN jobs j ON j.id = p.job WHERE j.state = 'running' AND j.pgid IS NOT NULL
  ORDER BY j.started_at DESC, j.port, j.rowid`;
export const PROCESS_JOB_NULL_ID = "SELECT 1 FROM jobs WHERE id IS NULL AND state = 'running' AND pgid IS NOT NULL LIMIT 1";

export type ProcessJob = { id: string; sessionKey: string; name: string; port: number | null; pgid: number };

export function hasProcessJobs(db: DatabaseSync): boolean {
  const known = presence.get(db);
  if (known !== undefined) return known;
  const found = statement(db, EXISTS).get() !== undefined;
  presence.set(db, found);
  return found;
}

/// The worker may install the lookup on its own connection.
export function refreshProcessJobs(db: DatabaseSync): boolean {
  presence.delete(db);
  return hasProcessJobs(db);
}

export function processJobsReady(db: DatabaseSync): boolean {
  if (!hasProcessJobs(db)) return false;
  const meta = statement(db, "SELECT version, complete FROM process_job_meta WHERE id = 1").get() as
    { version: number; complete: number } | undefined;
  if (meta?.version !== VERSION) throw new Error(`process job index version ${meta?.version ?? "missing"} is incompatible with ${VERSION}`);
  return meta.complete === 1;
}

/// Read readiness, compatibility and rows in one snapshot; until ready keep the old immediate answer.
export function processJobs(db: DatabaseSync): ProcessJob[] | null {
  if (!hasProcessJobs(db)) return null;
  db.exec("BEGIN");
  try {
    if (!processJobsReady(db) || statement(db, PROCESS_JOB_NULL_ID).get() !== undefined) { db.exec("COMMIT"); return null; }
    const rows = statement(db, PROCESS_JOBS).all() as { id: string; session_key: string; name: string; port: number | null; pgid: number }[];
    db.exec("COMMIT");
    return rows.map((r) => ({ id: r.id, sessionKey: r.session_key, name: r.name, port: r.port, pgid: r.pgid }));
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}
