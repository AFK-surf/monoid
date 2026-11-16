import type { DatabaseSync } from "node:sqlite";

// One requested own chat per session with an up job. Its first raw membership is sufficient for a job's name only
// when that membership decodes to the job's active session; the reader checks that condition in its own snapshot.
const VERSION = 1;
export const JOB_NAME_FIRST_PENDING = "job name first member pending: ";

export function installJobNameFirst(db: DatabaseSync): void {
  const installed = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='job_name_first_meta'").get() !== undefined;
  if (installed()) { checkJobNameFirst(db); return; }
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!installed()) db.exec(`
      CREATE TABLE job_name_first_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL) WITHOUT ROWID;
      INSERT INTO job_name_first_meta VALUES(1,${VERSION});
      CREATE TABLE job_name_first(owner TEXT PRIMARY KEY,thread INTEGER NOT NULL UNIQUE,best INTEGER,after_session TEXT,
        through_session TEXT,restart INTEGER NOT NULL DEFAULT 0,ready INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
      CREATE INDEX job_name_first_best ON job_name_first(best);

      -- REPLACE can remove either of these old memberships without firing DELETE triggers in an older connection.
      CREATE TRIGGER job_name_first_before_add BEFORE INSERT ON thread_sessions BEGIN
        UPDATE job_name_first SET ready=0,restart=1 WHERE restart=0 AND best IN (
          SELECT rowid FROM thread_sessions WHERE rowid=NEW.rowid
          UNION SELECT rowid FROM thread_sessions WHERE thread=NEW.thread AND session=NEW.session);
      END;
      CREATE TRIGGER job_name_first_after_add AFTER INSERT ON thread_sessions BEGIN
        UPDATE job_name_first SET best=NEW.rowid WHERE thread=NEW.thread AND restart=0 AND best IS NOT NEW.rowid
          AND (best IS NULL OR (SELECT rowid FROM thread_sessions WHERE rowid IN (best,NEW.rowid)
            ORDER BY joined_at,rowid LIMIT 1)=NEW.rowid);
      END;
      CREATE TRIGGER job_name_first_before_change BEFORE UPDATE ON thread_sessions
      WHEN OLD.thread IS NOT NEW.thread OR OLD.session IS NOT NEW.session OR OLD.joined_at IS NOT NEW.joined_at OR OLD.rowid IS NOT NEW.rowid
      BEGIN
        UPDATE job_name_first SET ready=0,restart=1 WHERE restart=0 AND (best=OLD.rowid OR best IN (
          SELECT rowid FROM thread_sessions WHERE rowid=NEW.rowid
          UNION SELECT rowid FROM thread_sessions WHERE thread=NEW.thread AND session=NEW.session));
      END;
      CREATE TRIGGER job_name_first_after_change AFTER UPDATE ON thread_sessions
      WHEN OLD.thread IS NOT NEW.thread OR OLD.session IS NOT NEW.session OR OLD.joined_at IS NOT NEW.joined_at OR OLD.rowid IS NOT NEW.rowid
      BEGIN
        UPDATE job_name_first SET best=NEW.rowid WHERE thread=NEW.thread AND restart=0 AND best IS NOT NEW.rowid
          AND (best IS NULL OR (SELECT rowid FROM thread_sessions WHERE rowid IN (best,NEW.rowid)
            ORDER BY joined_at,rowid LIMIT 1)=NEW.rowid);
      END;
      CREATE TRIGGER job_name_first_drop BEFORE DELETE ON thread_sessions BEGIN
        UPDATE job_name_first SET ready=0,restart=1 WHERE best=OLD.rowid AND restart=0;
      END;
      -- A session can own at most one tracked chat, so finishing its final up job removes at most one row.
      CREATE TRIGGER job_name_first_job_drop AFTER DELETE ON session_up_job_rows
      WHEN NOT EXISTS (SELECT 1 FROM session_up_job_rows WHERE session=OLD.session LIMIT 1)
      BEGIN DELETE FROM job_name_first WHERE owner=OLD.session; END;
    `);
    else checkJobNameFirst(db);
    db.exec("COMMIT");
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

export function checkJobNameFirst(db: DatabaseSync): void {
  const row = db.prepare("SELECT version FROM job_name_first_meta WHERE id=1").get() as { version: number } | undefined;
  if (!row || row.version !== VERSION) throw new Error(`job name first index version ${row?.version ?? "missing"} is incompatible with ${VERSION}`);
}
