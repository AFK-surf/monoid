// A session's running jobs and services waiting to restart (station/src/store/session-up-jobs.ts): the old jobs of a
// session prepared in bounded batches, as `sessionUpJobsStep` does, here for the MoonBit builder.

///|
let version : Int = 1

///|
let up : String = "(j.state = 'running' OR (j.state = 'exited' AND j.port IS NOT NULL))"

///|
let first : String = "SELECT CAST(rowid AS TEXT) AS position FROM jobs INDEXED BY jobs_by_session WHERE session_key = ? AND rowid <= CAST(? AS INTEGER) ORDER BY rowid LIMIT ?"

///|
let next : String = "SELECT CAST(rowid AS TEXT) AS position FROM jobs INDEXED BY jobs_by_session WHERE session_key = ? AND rowid > CAST(? AS INTEGER) AND rowid <= CAST(? AS INTEGER) ORDER BY rowid LIMIT ?"

///|
/// Whether the session's are prepared (all are, on a station that had none running when its index was made).
fn ready(db : @sql.Db, session : String) -> Bool raise {
  let meta = db.all("SELECT version, fresh FROM session_up_job_meta WHERE id = 1", [])
  guard meta is [meta, ..] && meta.get("version") is Some(Number(v, ..)) && v.to_int() == version else {
    let had = match meta {
      [m, ..] => @sql.row_val(m, "version").stringify()
      _ => "missing"
    }
    fail("session up jobs index version \{had} is incompatible with \{version}")
  }
  if meta.get("fresh") is Some(Number(1.0, ..)) {
    return true
  }
  let scope = db.all("SELECT complete FROM session_up_job_scopes WHERE session = ?", [Json::string(session)])
  scope is [s, ..] && s.get("complete") is Some(Number(1.0, ..))
}

///|
/// One batch of at most `limit` of `session`'s old jobs; whether all of its are prepared then.
pub fn step(db : @sql.Db, session : String, limit? : Int = 256) -> Bool raise {
  db.exec("BEGIN IMMEDIATE")
  // (what failed is let go: nothing of a batch is kept but whole)
  errdefer (db.exec("ROLLBACK") catch { _ => () })
  if ready(db, session) {
    db.exec("COMMIT")
    return true
  }
  let s = Json::string(session)
  ignore(
    db.run(
      "INSERT INTO session_up_job_scopes (session, last_rowid, end_rowid, complete) SELECT ?, NULL, (SELECT rowid FROM jobs INDEXED BY jobs_by_session WHERE session_key = ? ORDER BY rowid DESC LIMIT 1), 0 WHERE NOT EXISTS (SELECT 1 FROM session_up_job_scopes WHERE session = ?)",
      [s, s, s],
    ),
  )
  let scope = db.all(
    "SELECT CAST(last_rowid AS TEXT) AS last_rowid, CAST(end_rowid AS TEXT) AS end_rowid FROM session_up_job_scopes WHERE session = ?",
    [s],
  )
  guard scope is [scope, ..] else { fail("session up jobs scope is missing") }
  let last = @sql.row_val(scope, "last_rowid")
  let end = @sql.row_val(scope, "end_rowid")
  let lim = Json::number(limit.to_double())
  let rows = if last is Null { db.all(first, [s, end, lim]) } else { db.all(next, [s, last, end, lim]) }
  let put = "INSERT INTO session_up_job_rows (session, job_rowid) SELECT j.session_key, j.rowid FROM jobs j WHERE j.rowid = CAST(? AS INTEGER) AND \{up} AND NOT EXISTS (SELECT 1 FROM session_up_job_rows i WHERE i.session = j.session_key AND i.job_rowid = j.rowid)"
  for row in rows {
    ignore(db.run(put, [@sql.row_val(row, "position")]))
  }
  let done = rows.length() < limit
  let reached = match rows.last() {
    Some(row) => @sql.row_val(row, "position")
    None => last
  }
  ignore(
    db.run("UPDATE session_up_job_scopes SET last_rowid = CAST(? AS INTEGER), complete = ? WHERE session = ?", [
      reached,
      Json::number(if done { 1.0 } else { 0.0 }),
      s,
    ]),
  )
  db.exec("COMMIT")
  done
}

// The station-wide lookup of the sessions with jobs up (station/src/store/workspace-up-jobs.ts): its old up jobs copied
// in bounded batches after a handover, as `workspaceUpJobsStep` does.

///|
let workspace_version : Int = 1

///|
let port_batches_per_guard : Int = 8

///|
/// workspace-up-jobs.ts `fields(j.session_key, s.ws)`: a session's scope and workspace, an unusual one kept apart.
let workspace_fields : String = {
  let odd = "(typeof(j.session_key) <> 'text' OR instr(CAST(j.session_key AS BLOB), x'00') > 0 OR j.session_key GLOB '*[^ -~]*' OR (s.ws IS NOT NULL AND (typeof(s.ws) <> 'text' OR instr(CAST(s.ws AS BLOB), x'00') > 0 OR s.ws GLOB '*[^ -~]*')))"
  "CASE WHEN \{odd} THEN 2 WHEN s.ws IS NULL THEN 1 ELSE 0 END, CASE WHEN \{odd} OR s.ws IS NULL THEN '' ELSE s.ws END"
}

///|
/// workspace-up-jobs.ts WORKSPACE_UP_OLD_ROWIDS: old jobs of a state by rowid, up to a fixed end.
fn old_rowids(cursor : String, end : String, first : Bool) -> String {
  let after = if first { "" } else { " AND j.rowid>(SELECT \{cursor} FROM workspace_up_meta WHERE id=1)" }
  "SELECT j.rowid,NULL FROM jobs j INDEXED BY jobs_state WHERE j.state=? AND j.rowid<=(SELECT \{end} FROM workspace_up_meta WHERE id=1)\{after} ORDER BY j.rowid LIMIT ?"
}

///|
fn count_batch(db : @sql.Db) -> Int raise {
  match db.all("SELECT COUNT(*) AS n FROM workspace_up_batch", []) {
    [r, ..] =>
      match r.get("n") {
        Some(Number(n, ..)) => n.to_int()
        _ => 0
      }
    _ => 0
  }
}

///|
/// One batch of the old up jobs copied into the station-wide lookup (`workspaceUpJobsStep`); whether it is complete.
/// The running jobs first, by rowid to their end; then the exited services by port, every eighth batch a scan by rowid
/// instead so that a stream of new services cannot keep the copy open. The cursor stays in SQLite.
pub fn workspace_step(db : @sql.Db, limit? : Int = 256) -> Bool raise {
  guard limit >= 1 else { fail("workspace up job batch must be positive") }
  db.exec("BEGIN IMMEDIATE")
  errdefer (db.exec("ROLLBACK") catch { _ => () })
  let meta = db.all("SELECT version, ready FROM workspace_up_meta WHERE id = 1", [])
  guard meta is [meta, ..] && meta.get("version") is Some(Number(v, ..)) && v.to_int() == workspace_version else {
    let had = match meta {
      [m, ..] => @sql.row_val(m, "version").stringify()
      _ => "missing"
    }
    fail("workspace up jobs index version \{had} is incompatible with \{workspace_version}")
  }
  if meta.get("ready") is Some(Number(1.0, ..)) {
    db.exec("COMMIT")
    return true
  }
  let cursor = match
    db.all(
      "SELECT phase, port_batches, last_rowid IS NULL AS first, guard_last IS NULL AS guard_first FROM workspace_up_meta WHERE id=1",
      [],
    ) {
    [c, ..] => c
    _ => fail("workspace up jobs index has no cursor")
  }
  let int = (name : String) => match cursor.get(name) {
    Some(Number(n, ..)) => n.to_int()
    _ => 0
  }
  let phase = int("phase")
  let guard_scan = phase == 1 && int("port_batches") >= port_batches_per_guard
  let lim = Json::number(limit.to_double())
  db.exec("CREATE TEMP TABLE IF NOT EXISTS workspace_up_batch(job_rowid INTEGER PRIMARY KEY,port); DELETE FROM workspace_up_batch;")
  if phase == 0 {
    ignore(
      db.run("INSERT INTO workspace_up_batch \{old_rowids("last_rowid", "running_end", int("first") == 1)}", [
        Json::string("running"),
        lim,
      ]),
    )
  } else if guard_scan {
    ignore(
      db.run("INSERT INTO workspace_up_batch \{old_rowids("guard_last", "guard_end", int("guard_first") == 1)}", [
        Json::string("exited"),
        lim,
      ]),
    )
  } else if int("first") == 1 {
    ignore(
      db.run(
        "INSERT INTO workspace_up_batch SELECT j.rowid,j.port FROM jobs j INDEXED BY jobs_up WHERE j.state='exited' AND j.port IS NOT NULL ORDER BY j.port,j.rowid LIMIT ?",
        [lim],
      ),
    )
  } else {
    // (the same port by rowid first: a tuple's comparison would start at the port and read its earlier jobs again)
    ignore(
      db.run(
        "INSERT INTO workspace_up_batch SELECT j.rowid,j.port FROM jobs j INDEXED BY jobs_up WHERE j.state=? AND j.port=(SELECT last_port FROM workspace_up_meta WHERE id=1) AND j.rowid>(SELECT last_rowid FROM workspace_up_meta WHERE id=1) ORDER BY j.rowid LIMIT ?",
        [Json::string("exited"), lim],
      ),
    )
    let same = count_batch(db)
    if same < limit {
      ignore(
        db.run(
          "INSERT INTO workspace_up_batch SELECT j.rowid,j.port FROM jobs j INDEXED BY jobs_up WHERE j.state=? AND j.port>(SELECT last_port FROM workspace_up_meta WHERE id=1) ORDER BY j.port,j.rowid LIMIT ?",
          [Json::string("exited"), Json::number((limit - same).to_double())],
        ),
      )
    }
  }
  let count = count_batch(db)
  db.exec(
    "INSERT INTO session_up_job_rows(session,job_rowid) SELECT j.session_key,j.rowid FROM workspace_up_batch b CROSS JOIN jobs j ON j.rowid=b.job_rowid WHERE \{up} AND NOT EXISTS (SELECT 1 FROM session_up_job_rows u WHERE u.session=j.session_key AND u.job_rowid=j.rowid); INSERT INTO workspace_up_sessions(session,scope,ws) SELECT DISTINCT j.session_key, \{workspace_fields} FROM workspace_up_batch b CROSS JOIN jobs j ON j.rowid=b.job_rowid LEFT JOIN sessions s ON s.key=j.session_key WHERE \{up} ON CONFLICT(session) DO UPDATE SET scope=excluded.scope, ws=excluded.ws WHERE scope IS NOT excluded.scope OR ws IS NOT excluded.ws;",
  )
  let done = phase == 1 && count < limit
  if count < limit {
    ignore(
      db.run("UPDATE workspace_up_meta SET phase=?,last_port=NULL,last_rowid=NULL,ready=? WHERE id=1", [
        Json::number((phase + 1).to_double()),
        Json::number(if done { 1.0 } else { 0.0 }),
      ]),
    )
  } else if phase == 0 {
    db.exec("UPDATE workspace_up_meta SET last_rowid=(SELECT MAX(job_rowid) FROM workspace_up_batch) WHERE id=1")
  } else if guard_scan {
    db.exec(
      "UPDATE workspace_up_meta SET port_batches=0, guard_last=(SELECT MAX(job_rowid) FROM workspace_up_batch) WHERE id=1",
    )
  } else {
    db.exec(
      "UPDATE workspace_up_meta SET port_batches=port_batches+1, last_port=(SELECT port FROM workspace_up_batch ORDER BY port DESC,job_rowid DESC LIMIT 1), last_rowid=(SELECT job_rowid FROM workspace_up_batch ORDER BY port DESC,job_rowid DESC LIMIT 1) WHERE id=1",
    )
  }
  if done {
    db.exec("DROP TRIGGER workspace_up_copy_moved")
  }
  db.exec("COMMIT")
  done
}

// A requested own chat's first member for its job's name (station/src/store/job-name-first.ts), prepared in bounded
// batches as `jobNameFirstStep` does.

///|
let job_name_first_version : Int = 1

///|
/// The batch's first member, by when it joined.
let batch_best : String = "(SELECT rowid FROM thread_sessions WHERE rowid IN (SELECT member FROM job_name_first_batch) ORDER BY joined_at,rowid LIMIT 1)"

///|
/// One batch of `thread`'s members for `owner`'s job's name (`jobNameFirstStep`); whether it is prepared then. The
/// cursor and the rowids stay in SQLite: an old key may hold a NUL, invalid UTF-8 or a blob, a rowid 64 bits.
pub fn job_name_first_step(db : @sql.Db, owner : String, thread : Int64, limit? : Int = 64) -> Bool raise {
  guard limit >= 1 && limit <= 128 else { fail("invalid job name first batch") }
  db.exec("BEGIN IMMEDIATE")
  errdefer (db.exec("ROLLBACK") catch { _ => () })
  let meta = db.all("SELECT version FROM job_name_first_meta WHERE id=1", [])
  guard meta is [meta, ..] && meta.get("version") is Some(Number(v, ..)) && v.to_int() == job_name_first_version else {
    let had = match meta {
      [m, ..] => @sql.row_val(m, "version").stringify()
      _ => "missing"
    }
    fail("job name first index version \{had} is incompatible with \{job_name_first_version}")
  }
  let o = Json::string(owner)
  let t = Json::number(thread.to_double())
  ignore(
    db.run(
      "INSERT OR IGNORE INTO job_name_first(owner,thread,through_session) SELECT ?1,?2,(SELECT session FROM thread_sessions WHERE thread=?2 ORDER BY session DESC LIMIT 1) WHERE EXISTS (SELECT 1 FROM session_up_job_rows WHERE session=?1 LIMIT 1)",
      [o, t],
    ),
  )
  let current = db.all("SELECT thread=?2 AS same, ready FROM job_name_first WHERE owner=?1", [o, t])
  guard current is [c, ..] && c.get("same") is Some(Number(1.0, ..)) && !(c.get("ready") is Some(Number(1.0, ..))) else {
    db.exec("COMMIT")
    return true
  }
  ignore(
    db.run(
      "UPDATE job_name_first SET restart=0,ready=0,best=NULL,after_session=NULL, through_session=(SELECT session FROM thread_sessions WHERE thread=?2 ORDER BY session DESC LIMIT 1) WHERE owner=?1 AND thread=?2 AND restart=1",
      [o, t],
    ),
  )
  let first = match db.all("SELECT after_session IS NULL AS first FROM job_name_first WHERE owner=?", [o]) {
    [r, ..] => r.get("first") is Some(Number(1.0, ..))
    _ => true
  }
  let after = if first { "" } else { " AND session > (SELECT after_session FROM job_name_first WHERE owner=?2)" }
  db.exec("CREATE TEMP TABLE IF NOT EXISTS job_name_first_batch(member INTEGER PRIMARY KEY); DELETE FROM job_name_first_batch;")
  let count = db.run(
    "INSERT INTO job_name_first_batch SELECT rowid FROM thread_sessions WHERE thread=?1 AND session <= (SELECT through_session FROM job_name_first WHERE owner=?2)\{after} ORDER BY session LIMIT ?3",
    [t, o, Json::number(limit.to_double())],
  )
  if count > 0 {
    ignore(
      db.run(
        "UPDATE job_name_first SET best=\{batch_best} WHERE owner=?1 AND best IS NOT \{batch_best} AND (best IS NULL OR (SELECT rowid FROM thread_sessions WHERE rowid IN (best,\{batch_best}) ORDER BY joined_at,rowid LIMIT 1)=\{batch_best})",
        [o],
      ),
    )
    // (the batch is in the members' order: its last the one of the greatest session)
    ignore(
      db.run(
        "UPDATE job_name_first SET after_session=(SELECT session FROM thread_sessions WHERE rowid IN (SELECT member FROM job_name_first_batch) ORDER BY session DESC LIMIT 1) WHERE owner=?1",
        [o],
      ),
    )
  }
  let done = count < limit
  if done {
    ignore(db.run("UPDATE job_name_first SET ready=1 WHERE owner=?", [o]))
  }
  db.exec("COMMIT")
  done
}
