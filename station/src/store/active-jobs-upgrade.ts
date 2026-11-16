// Older stores may have a large running queue. Prepare the two existing active-job lookups without exposing a
// partial table to older readers, and keep them current while jobs change. Each batch holds the writer for at most
// 64 job keys; before publication callers still answer from jobs itself.
import type { DatabaseSync } from "node:sqlite";

export const VERSION = 1;
export const exists = (db: DatabaseSync, type: string, name: string) =>
  db.prepare("SELECT 1 FROM sqlite_master WHERE type = ? AND name = ?").get(type, name) !== undefined;
export const active = (row: string) => `${row}.state = 'running'`;
export const conflict = (other: boolean) => `SELECT j.session_key AS session, j.id AS job FROM (
  SELECT rowid AS position FROM jobs WHERE id = NEW.id
  UNION SELECT rowid FROM jobs WHERE token = NEW.token
  UNION SELECT rowid FROM jobs WHERE rowid = NEW.rowid
) p CROSS JOIN jobs j ON j.rowid = p.position WHERE ${active("j")} AND j.id IS NOT NULL
  ${other ? "AND j.rowid IS NOT OLD.rowid" : ""}`;
export const changed = `OLD.rowid IS NOT NEW.rowid OR OLD.id IS NOT NEW.id OR OLD.token IS NOT NEW.token
  OR OLD.session_key IS NOT NEW.session_key OR OLD.state IS NOT NEW.state OR OLD.watch IS NOT NEW.watch
  OR EXISTS (SELECT 1 FROM active_job_upgrade_replaced)`;
export const stage = (other: boolean) => `DELETE FROM active_job_upgrade_replaced WHERE session IS NOT NULL;
  INSERT INTO active_job_upgrade_replaced (session, job) ${conflict(other)};`;

export function statements(watches: boolean, others: boolean) {
  const see = (rowid: string) => `${watches ? `
    INSERT INTO active_job_watch_build (job, session, token)
      SELECT j.id, j.session_key, j.token FROM jobs j WHERE j.rowid = ${rowid} AND j.state = 'running' AND j.watch <> 0
        AND (j.id IS NOT NULL OR (SELECT complete FROM active_job_upgrade WHERE id = 1) = 1)
        AND NOT EXISTS (SELECT 1 FROM active_job_watch_build w WHERE w.job = j.id);` : ""}${others ? `
    INSERT INTO active_job_other_build (session, job)
      SELECT j.session_key, j.id FROM jobs j WHERE j.rowid = ${rowid} AND j.state = 'running' AND j.watch = 0
        AND (j.id IS NOT NULL OR (SELECT complete FROM active_job_upgrade WHERE id = 1) = 1)
        AND NOT EXISTS (SELECT 1 FROM active_job_other_build a WHERE a.session = j.session_key AND a.job = j.id);` : ""}`;
  const reconcile = `${watches ? `
    DELETE FROM active_job_watch_build WHERE job IN (SELECT job FROM active_job_upgrade_replaced)
      AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.id = active_job_watch_build.job AND j.state = 'running'
        AND j.watch <> 0 AND j.session_key = active_job_watch_build.session AND j.token = active_job_watch_build.token);
    INSERT INTO active_job_watch_build (job, session, token)
      SELECT j.id, j.session_key, j.token FROM active_job_upgrade_replaced r CROSS JOIN jobs j ON j.id = r.job
      WHERE j.state = 'running' AND j.watch <> 0 AND NOT EXISTS (SELECT 1 FROM active_job_watch_build w WHERE w.job = j.id);` : ""}${others ? `
    DELETE FROM active_job_other_build WHERE (session, job) IN (SELECT session, job FROM active_job_upgrade_replaced)
      AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.id = active_job_other_build.job AND j.state = 'running'
        AND j.watch = 0 AND j.session_key = active_job_other_build.session);
    INSERT INTO active_job_other_build (session, job)
      SELECT j.session_key, j.id FROM active_job_upgrade_replaced r CROSS JOIN jobs j ON j.id = r.job
      WHERE j.state = 'running' AND j.watch = 0
        AND NOT EXISTS (SELECT 1 FROM active_job_other_build a WHERE a.session = j.session_key AND a.job = j.id);` : ""}
    DELETE FROM active_job_upgrade_replaced WHERE session IS NOT NULL;`;
  const drop = `${watches ? "DELETE FROM active_job_watch_build WHERE job = OLD.id;" : ""}
    ${others ? "DELETE FROM active_job_other_build WHERE session = OLD.session_key AND job = OLD.id;" : ""}`;
  return { see, reconcile, drop };
}

export const ACTIVE_JOB_NULL_ID = "SELECT 1 FROM jobs INDEXED BY sqlite_autoindex_jobs_1 WHERE id IS NULL AND state = 'running' LIMIT 1";
type Meta = { version: number; complete: number; watches: number; others: number; cursor: string | null; end_rowid: string | null; schema_version: number };
export function meta(db: DatabaseSync): Meta | null {
  if (!exists(db, "table", "active_job_upgrade")) return null;
  const row = db.prepare(`SELECT version, complete, watches, others, CAST(cursor AS TEXT) AS cursor,
    CAST(end_rowid AS TEXT) AS end_rowid, schema_version FROM active_job_upgrade WHERE id = 1`).get() as Meta | undefined;
  if (row?.version !== VERSION) throw new Error(`active job upgrade version ${row?.version ?? "missing"} is incompatible with ${VERSION}`);
  return row;
}

export function activeJobUpgradeReady(db: DatabaseSync): boolean {
  const ready = exists(db, "table", "active_watch_jobs") && exists(db, "table", "active_other_jobs");
  return ready && (exists(db, "index", "active_other_remote_jobs") || activeRemoteJobsReady(db));
}

function activeRemoteJobsReady(db: DatabaseSync): boolean {
  if (!exists(db, "table", "active_remote_job_meta")) return false;
  const row = db.prepare("SELECT version, complete FROM active_remote_job_meta WHERE id = 1").get() as
    { version: number; complete: number } | undefined;
  return row?.version === VERSION && row.complete === 1;
}

export function activeRemoteJobsAvailable(db: DatabaseSync): boolean {
  return activeRemoteJobsReady(db);
}

export const REMOTE_QUEUE_PREPARED = `SELECT * FROM (
  SELECT j.id, j.session_key, j.started_at, j.queued, j.screen, j.small, j.rowid AS queue_rowid FROM active_watch_jobs w
    CROSS JOIN jobs j ON j.id = w.job WHERE w.job >= 'remote_' AND w.job < 'remote\`'
  UNION ALL
  SELECT j.id, j.session_key, j.started_at, j.queued, j.screen, j.small, j.rowid AS queue_rowid FROM active_remote_job_rows a
    CROSS JOIN jobs j ON j.id = a.job WHERE a.job >= 'remote_' AND a.job < 'remote\`'
) ORDER BY started_at DESC, queue_rowid`;
