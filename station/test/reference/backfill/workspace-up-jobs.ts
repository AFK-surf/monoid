// The steps src/store/workspace-up-jobs.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/workspace-up-jobs.ts's.
import type { DatabaseSync } from "node:sqlite";
import { up, fields, conflict, workspaceUpJobsReady } from "../../../src/store/workspace-up-jobs.ts";

export * from "../../../src/store/workspace-up-jobs.ts";

const PORT_BATCHES_PER_GUARD = 8;
/// Candidate jobs for one workspace; unusual identities remain for the reader's JavaScript visibility check.
export const WORKSPACE_UP_JOBS = `WITH wanted AS (
  SELECT session FROM workspace_up_sessions INDEXED BY workspace_up_sessions_scope WHERE scope=0 AND ws=?1
  UNION ALL SELECT session FROM workspace_up_sessions INDEXED BY workspace_up_sessions_scope WHERE scope=1 AND ws='' AND ?2
  UNION ALL SELECT session FROM workspace_up_sessions INDEXED BY workspace_up_sessions_scope WHERE scope=2 AND ws=''
) SELECT j.* FROM wanted w CROSS JOIN session_up_job_rows u ON u.session=w.session
  CROSS JOIN jobs j ON j.rowid=u.job_rowid
  ORDER BY j.started_at DESC, (j.state <> 'running'), j.port, j.rowid`;
// The equal-port seek must include rowid: a tuple comparison here starts at the port and rereads all its earlier jobs.
export const WORKSPACE_UP_SAME_PORT = `SELECT j.rowid,j.port FROM jobs j INDEXED BY jobs_up
  WHERE j.state=? AND j.port=(SELECT last_port FROM workspace_up_meta WHERE id=1)
    AND j.rowid>(SELECT last_rowid FROM workspace_up_meta WHERE id=1) ORDER BY j.rowid LIMIT ?`;
export const WORKSPACE_UP_LATER_PORTS = `SELECT j.rowid,j.port FROM jobs j INDEXED BY jobs_up
  WHERE j.state=? AND j.port>(SELECT last_port FROM workspace_up_meta WHERE id=1) ORDER BY j.port,j.rowid LIMIT ?`;
// Use the state/rowid index to reach a fixed end even if jobs are added while the copy runs. Keep the cursor in SQLite
// so neither 64-bit rowids nor unusual port values pass through JavaScript numbers or strings.
export const WORKSPACE_UP_OLD_ROWIDS = (cursor: "last_rowid" | "guard_last", end: "running_end" | "guard_end", first: boolean) =>
  `SELECT j.rowid,NULL FROM jobs j INDEXED BY jobs_state WHERE j.state=?
    AND j.rowid<=(SELECT ${end} FROM workspace_up_meta WHERE id=1)
    ${first ? "" : `AND j.rowid>(SELECT ${cursor} FROM workspace_up_meta WHERE id=1)`} ORDER BY j.rowid LIMIT ?`;
/// Copy old up jobs in batches. Exited services normally use jobs_up; every eighth batch yields to a state/rowid scan
/// so a stream of new services cannot keep the copy open. That second scan may also read old inactive jobs.
export function workspaceUpJobsStep(db: DatabaseSync, limit = 256): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1) throw new RangeError("workspace up job batch must be positive");
  db.exec("BEGIN IMMEDIATE");
  try {
    if (workspaceUpJobsReady(db)) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const cursor = db.prepare(`SELECT phase,port_batches,last_rowid IS NULL AS first,guard_last IS NULL AS guard_first
      FROM workspace_up_meta WHERE id=1`).get() as { phase: number; port_batches: number; first: number; guard_first: number };
    const guard = cursor.phase === 1 && cursor.port_batches >= PORT_BATCHES_PER_GUARD;
    db.exec("CREATE TEMP TABLE IF NOT EXISTS workspace_up_batch(job_rowid INTEGER PRIMARY KEY,port); DELETE FROM workspace_up_batch;");
    if (cursor.phase === 0) {
      db.prepare(`INSERT INTO workspace_up_batch ${WORKSPACE_UP_OLD_ROWIDS("last_rowid", "running_end", !!cursor.first)}`)
        .run("running", limit);
    } else if (guard) {
      db.prepare(`INSERT INTO workspace_up_batch ${WORKSPACE_UP_OLD_ROWIDS("guard_last", "guard_end", !!cursor.guard_first)}`)
        .run("exited", limit);
    } else if (cursor.first) {
      db.prepare(`INSERT INTO workspace_up_batch SELECT j.rowid,j.port FROM jobs j INDEXED BY jobs_up
        WHERE j.state='exited' AND j.port IS NOT NULL ORDER BY j.port,j.rowid LIMIT ?`).run(limit);
    } else {
      db.prepare(`INSERT INTO workspace_up_batch ${WORKSPACE_UP_SAME_PORT}`).run("exited",limit);
      const same = (db.prepare("SELECT COUNT(*) AS n FROM workspace_up_batch").get() as { n: number }).n;
      if (same < limit) db.prepare(`INSERT INTO workspace_up_batch ${WORKSPACE_UP_LATER_PORTS}`).run("exited",limit-same);
    }
    const count = (db.prepare("SELECT COUNT(*) AS n FROM workspace_up_batch").get() as { n: number }).n;
    db.exec(`INSERT INTO session_up_job_rows(session,job_rowid)
      SELECT j.session_key,j.rowid FROM workspace_up_batch b CROSS JOIN jobs j ON j.rowid=b.job_rowid
      WHERE ${up("j")} AND NOT EXISTS (SELECT 1 FROM session_up_job_rows u WHERE u.session=j.session_key AND u.job_rowid=j.rowid);
      INSERT INTO workspace_up_sessions(session,scope,ws)
      SELECT DISTINCT j.session_key, ${fields("j.session_key", "s.ws")} FROM workspace_up_batch b
        CROSS JOIN jobs j ON j.rowid=b.job_rowid LEFT JOIN sessions s ON s.key=j.session_key
      WHERE ${up("j")} ${conflict};`);
    const done = cursor.phase === 1 && count < limit;
    if (count < limit) db.prepare("UPDATE workspace_up_meta SET phase=?,last_port=NULL,last_rowid=NULL,ready=? WHERE id=1")
      .run(cursor.phase + 1, done ? 1 : 0);
    else if (cursor.phase === 0) db.exec(`UPDATE workspace_up_meta SET
      last_rowid=(SELECT MAX(job_rowid) FROM workspace_up_batch) WHERE id=1`);
    else if (guard) db.exec(`UPDATE workspace_up_meta SET port_batches=0,
      guard_last=(SELECT MAX(job_rowid) FROM workspace_up_batch) WHERE id=1`);
    else db.exec(`UPDATE workspace_up_meta SET port_batches=port_batches+1,
      last_port=(SELECT port FROM workspace_up_batch ORDER BY port DESC,job_rowid DESC LIMIT 1),
      last_rowid=(SELECT job_rowid FROM workspace_up_batch ORDER BY port DESC,job_rowid DESC LIMIT 1) WHERE id=1`);
    if (done) db.exec("DROP TRIGGER workspace_up_copy_moved");
    db.exec("COMMIT");
    return { done, visited: count };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}