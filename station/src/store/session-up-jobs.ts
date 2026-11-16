// A session's running jobs and services waiting to restart. Old jobs are prepared a session at a time, in batches;
// the writers follow changes made by either station while the previous process hands over.
import type { DatabaseSync } from "node:sqlite";

const VERSION = 1;
export const SESSION_UP_JOB = "SELECT 1 FROM session_up_job_rows WHERE session = ? LIMIT 1";
export const SESSION_UP_JOBS = `SELECT j.id FROM session_up_job_rows i
  CROSS JOIN jobs j ON j.rowid = i.job_rowid WHERE i.session = ? ORDER BY j.started_at DESC`;

const up = (name: string) => `(${name}.state = 'running' OR (${name}.state = 'exited' AND ${name}.port IS NOT NULL))`;
const changed = `OLD.rowid IS NOT NEW.rowid OR OLD.id IS NOT NEW.id OR OLD.token IS NOT NEW.token
  OR OLD.session_key IS NOT NEW.session_key OR ${up("OLD")} IS NOT ${up("NEW")}
  OR EXISTS (SELECT 1 FROM session_up_job_replaced)`;
const displaced = (id: string, token: string, rowid: string) => `SELECT j.rowid, j.session_key FROM jobs j WHERE j.id = ${id}
  UNION SELECT j.rowid, j.session_key FROM jobs j WHERE j.token = ${token}
  UNION SELECT j.rowid, j.session_key FROM jobs j WHERE j.rowid = ${rowid}`;
export const SESSION_UP_JOBS_DISPLACED = displaced("?1", "?2", "?3");
const conflict = (id: string, token: string, rowid: string) =>
  `SELECT 1 FROM jobs WHERE id = ${id} OR token = ${token} OR rowid = ${rowid}`;
export const SESSION_UP_JOBS_CONFLICT = conflict("?1", "?2", "?3");
const stage = (old: boolean) => `DELETE FROM session_up_job_replaced;
  INSERT INTO session_up_job_replaced (job_rowid, session) ${displaced("NEW.id", "NEW.token", "NEW.rowid")}
    ${old ? "UNION SELECT OLD.rowid, OLD.session_key" : ""};`;
export const see = (rowid: string) => `INSERT INTO session_up_job_rows (session, job_rowid)
  SELECT j.session_key, j.rowid FROM jobs j WHERE j.rowid = ${rowid} AND ${up("j")}
    AND NOT EXISTS (SELECT 1 FROM session_up_job_rows i WHERE i.session = j.session_key AND i.job_rowid = j.rowid);`;
const reconcile = `DELETE FROM session_up_job_rows WHERE (session, job_rowid) IN
    (SELECT session, job_rowid FROM session_up_job_replaced)
    AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.rowid = session_up_job_rows.job_rowid
      AND j.session_key = session_up_job_rows.session AND ${up("j")});
  INSERT INTO session_up_job_rows (session, job_rowid)
    SELECT j.session_key, j.rowid FROM session_up_job_replaced r CROSS JOIN jobs j ON j.rowid = r.job_rowid
    WHERE ${up("j")} AND NOT EXISTS (SELECT 1 FROM session_up_job_rows i
      WHERE i.session = j.session_key AND i.job_rowid = j.rowid);
  DELETE FROM session_up_job_replaced;`;

export function installSessionUpJobs(db: DatabaseSync): void {
  const installed = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_up_job_meta'").get() !== undefined;
  if (installed()) { sessionUpJobsReady(db, ""); return; }
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!installed()) db.exec(`
      CREATE TABLE session_up_job_meta (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL, fresh INTEGER NOT NULL) WITHOUT ROWID;
      INSERT INTO session_up_job_meta SELECT 1, ${VERSION},
        NOT EXISTS (SELECT 1 FROM jobs INDEXED BY jobs_state WHERE state = 'running')
        AND NOT EXISTS (SELECT 1 FROM jobs INDEXED BY jobs_up WHERE state = 'exited' AND port IS NOT NULL);
      CREATE TABLE session_up_job_scopes (session TEXT PRIMARY KEY, last_rowid INTEGER, end_rowid INTEGER, complete INTEGER NOT NULL) WITHOUT ROWID;
      CREATE TABLE session_up_job_rows (session TEXT NOT NULL, job_rowid INTEGER NOT NULL, PRIMARY KEY (session, job_rowid)) WITHOUT ROWID;
      CREATE TABLE session_up_job_replaced (job_rowid INTEGER PRIMARY KEY, session TEXT NOT NULL);
      CREATE TRIGGER session_up_job_before_add BEFORE INSERT ON jobs
        WHEN EXISTS (SELECT 1 FROM session_up_job_replaced)
          OR EXISTS (${conflict("NEW.id", "NEW.token", "NEW.rowid")})
        BEGIN ${stage(false)} END;
      CREATE TRIGGER session_up_job_add AFTER INSERT ON jobs
        WHEN ${up("NEW")} OR EXISTS (SELECT 1 FROM session_up_job_replaced)
        BEGIN ${reconcile} ${see("NEW.rowid")} END;
      CREATE TRIGGER session_up_job_before_change BEFORE UPDATE ON jobs
        WHEN ${changed}
        BEGIN ${stage(true)} END;
      CREATE TRIGGER session_up_job_change AFTER UPDATE ON jobs
        WHEN ${changed}
        BEGIN ${reconcile} ${see("NEW.rowid")} END;
      CREATE TRIGGER session_up_job_drop AFTER DELETE ON jobs WHEN ${up("OLD")} BEGIN
        DELETE FROM session_up_job_rows WHERE session = OLD.session_key AND job_rowid = OLD.rowid;
      END;
    `);
    else sessionUpJobsReady(db, "");
    db.exec("COMMIT");
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

export function sessionUpJobsReady(db: DatabaseSync, session: string): boolean {
  const meta = db.prepare("SELECT version, fresh FROM session_up_job_meta WHERE id = 1").get() as { version: number; fresh: number } | undefined;
  if (meta === undefined || meta.version !== VERSION) throw new Error(`session up jobs index version ${meta?.version ?? "missing"} is incompatible with ${VERSION}`);
  if (meta.fresh === 1) return true;
  return (db.prepare("SELECT complete FROM session_up_job_scopes WHERE session = ?").get(session) as { complete: number } | undefined)?.complete === 1;
}
