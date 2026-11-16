// Work in progress: a workspace's sessions with jobs up. Callers must not use this until old up jobs have been copied.
import type { DatabaseSync } from "node:sqlite";

const VERSION = 1;
export const up = (row: string) => `(${row}.state = 'running' OR (${row}.state = 'exited' AND ${row}.port IS NOT NULL))`;
const odd = (session: string, ws: string) => `(typeof(${session}) <> 'text'
  OR instr(CAST(${session} AS BLOB), x'00') > 0 OR ${session} GLOB '*[^ -~]*'
  OR (${ws} IS NOT NULL AND (typeof(${ws}) <> 'text' OR instr(CAST(${ws} AS BLOB), x'00') > 0
    OR ${ws} GLOB '*[^ -~]*')))`;
export const fields = (session: string, ws: string) => `CASE WHEN ${odd(session, ws)} THEN 2 WHEN ${ws} IS NULL THEN 1 ELSE 0 END,
  CASE WHEN ${odd(session, ws)} OR ${ws} IS NULL THEN '' ELSE ${ws} END`;
export const conflict = `ON CONFLICT(session) DO UPDATE SET scope=excluded.scope, ws=excluded.ws
  WHERE scope IS NOT excluded.scope OR ws IS NOT excluded.ws`;
const put = (session: string) => `INSERT INTO workspace_up_sessions(session,scope,ws)
  SELECT x.session, ${fields("x.session", "s.ws")} FROM (SELECT ${session} AS session) x
  LEFT JOIN sessions s ON s.key=x.session
  WHERE EXISTS (SELECT 1 FROM session_up_job_rows u WHERE u.session=x.session) ${conflict};`;
const refreshStaged = `DELETE FROM workspace_up_sessions WHERE session IN (SELECT session FROM workspace_up_session_replaced)
    AND NOT EXISTS (SELECT 1 FROM session_up_job_rows u WHERE u.session=workspace_up_sessions.session);
  INSERT INTO workspace_up_sessions(session,scope,ws)
    SELECT r.session, ${fields("r.session", "s.ws")} FROM workspace_up_session_replaced r
    LEFT JOIN sessions s ON s.key=r.session
    WHERE EXISTS (SELECT 1 FROM session_up_job_rows u WHERE u.session=r.session) ${conflict};`;
const displaced = `SELECT s.key FROM sessions s WHERE (s.key=NEW.key OR s.token=NEW.token OR s.rowid=NEW.rowid)
  AND EXISTS (SELECT 1 FROM workspace_up_sessions p WHERE p.session=s.key)`;
const clearStaged = "DELETE FROM workspace_up_session_replaced WHERE session IS NOT NULL;";

/// Install writers without scanning the old jobs. An incomplete index must never be used to answer a read.
export function installWorkspaceUpJobs(db: DatabaseSync): void {
  const installed = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='workspace_up_meta'").get() !== undefined;
  if (installed()) { workspaceUpJobsReady(db); return; }
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!installed()) {
      db.exec(`
      CREATE TABLE workspace_up_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,phase INTEGER NOT NULL,
        last_port,last_rowid INTEGER,running_end INTEGER,guard_end INTEGER,guard_last INTEGER,port_batches INTEGER NOT NULL,
        ready INTEGER NOT NULL) WITHOUT ROWID;
      INSERT INTO workspace_up_meta SELECT 1,${VERSION},0,NULL,NULL,
        (SELECT rowid FROM jobs INDEXED BY jobs_state WHERE state='running' ORDER BY rowid DESC LIMIT 1),
        (SELECT rowid FROM jobs INDEXED BY jobs_state WHERE state='exited' ORDER BY rowid DESC LIMIT 1),NULL,0,
        (SELECT fresh FROM session_up_job_meta WHERE id=1)=1 AND NOT EXISTS (SELECT 1 FROM session_up_job_rows LIMIT 1);
      CREATE TABLE workspace_up_sessions(session TEXT PRIMARY KEY,scope INTEGER NOT NULL,ws TEXT NOT NULL) WITHOUT ROWID;
      CREATE INDEX workspace_up_sessions_scope ON workspace_up_sessions(scope,ws,session);
      CREATE TABLE workspace_up_session_replaced(session TEXT PRIMARY KEY) WITHOUT ROWID;

      CREATE TRIGGER workspace_up_row_add AFTER INSERT ON session_up_job_rows
      WHEN NOT EXISTS (SELECT 1 FROM workspace_up_sessions WHERE session=NEW.session)
      BEGIN ${put("NEW.session")} END;
      CREATE TRIGGER workspace_up_row_drop AFTER DELETE ON session_up_job_rows
      WHEN NOT EXISTS (SELECT 1 FROM session_up_job_rows WHERE session=OLD.session)
      BEGIN DELETE FROM workspace_up_sessions WHERE session=OLD.session; END;
      CREATE TRIGGER workspace_up_before_session_add BEFORE INSERT ON sessions
      WHEN EXISTS (SELECT 1 FROM workspace_up_session_replaced) OR EXISTS (${displaced})
      BEGIN ${clearStaged} INSERT OR IGNORE INTO workspace_up_session_replaced ${displaced}; END;
      CREATE TRIGGER workspace_up_after_session_add AFTER INSERT ON sessions
      BEGIN ${refreshStaged} ${put("NEW.key")} ${clearStaged} END;
      -- A workspace-only change cannot displace another session; the after trigger can refresh it directly.
      CREATE TRIGGER workspace_up_before_session_change BEFORE UPDATE ON sessions
      WHEN OLD.rowid IS NOT NEW.rowid OR OLD.key IS NOT NEW.key OR OLD.token IS NOT NEW.token
      BEGIN ${clearStaged}
        INSERT OR IGNORE INTO workspace_up_session_replaced SELECT OLD.key
          WHERE EXISTS (SELECT 1 FROM workspace_up_sessions WHERE session=OLD.key);
        INSERT OR IGNORE INTO workspace_up_session_replaced ${displaced};
      END;
      CREATE TRIGGER workspace_up_after_session_change AFTER UPDATE ON sessions
      WHEN OLD.rowid IS NOT NEW.rowid OR OLD.key IS NOT NEW.key OR OLD.token IS NOT NEW.token OR OLD.ws IS NOT NEW.ws
      BEGIN ${refreshStaged} ${put("NEW.key")} ${clearStaged} END;
      CREATE TRIGGER workspace_up_after_session_drop AFTER DELETE ON sessions
      WHEN EXISTS (SELECT 1 FROM workspace_up_sessions WHERE session=OLD.key)
      BEGIN ${put("OLD.key")} END;

      `);
      // During the copy an up job can move behind the cursor without changing whether it is up. Once the copy is
      // complete, the regular writers already follow every job, so this trigger has no remaining work to do.
      if (!workspaceUpJobsReady(db)) db.exec(`CREATE TRIGGER workspace_up_copy_moved AFTER UPDATE OF state,port ON jobs
        WHEN ${up("NEW")}
        BEGIN INSERT INTO session_up_job_rows(session,job_rowid)
          SELECT NEW.session_key,NEW.rowid WHERE NOT EXISTS
            (SELECT 1 FROM session_up_job_rows WHERE session=NEW.session_key AND job_rowid=NEW.rowid); END;`);
    } else workspaceUpJobsReady(db);
    db.exec("COMMIT");
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

export function workspaceUpJobsReady(db: DatabaseSync): boolean {
  const meta = db.prepare("SELECT version,ready FROM workspace_up_meta WHERE id=1").get() as { version: number; ready: number } | undefined;
  if (!meta || meta.version !== VERSION) throw new Error(`workspace up jobs index version ${meta?.version ?? "missing"} is incompatible with ${VERSION}`);
  return meta.ready === 1;
}
