// Profiles' checks, quotas and hours, the runtimes' process groups, the background jobs and the widgets' states
// (store.ts `// ── profile checks and quotas ──` to `// ── widget states ──`).

///|
/// profile-hours.ts PACE_HOURS, HOUR_MS.
let pace_hours : Double = 192.0

///|
/// profile-hours.ts SPEED_QUARTER_HOURS.
let speed_quarter_hours : Double = 8.0

///|
let hour_ms : Double = 3600000.0

///|
pub fn Store::profile_status(self : Store) -> Json raise {
  let out = self
    .all("SELECT profile, check_json, quota_json FROM profile_status", [])
    .map(r => {
      (
        js_string(col(r, "profile")),
        (
          {
            "check": parsed(col(r, "check_json")).unwrap_or(Json::null()),
            "quota": parsed(col(r, "quota_json")).unwrap_or(Json::null()),
          } : Json),
      )
    })
  out.sort_by((a, b) => by_bytes(a.0, b.0))
  entries(out)
}

///|
pub fn Store::profile_check(self : Store, id : String) -> Json? raise {
  match self.all("SELECT check_json FROM profile_status WHERE profile = ?", [Json::string(id)]).get(0) {
    Some(row) => parsed(col(row, "check_json"))
    None => None
  }
}

///|
/// store.ts `checkedAt`: `value.checkedAt` where it is an integer.
fn checked_at(v : Json) -> Json {
  match field(v, "checkedAt") {
    Some(Number(n, ..) as at) if n == n.floor() && !n.is_inf() => at
    _ => Json::null()
  }
}

///|
pub fn Store::set_profile_check(
  self : Store,
  profile : Json,
  check : Json,
) -> Unit raise {
  ignore(
    self.run(
      (
        #|INSERT INTO profile_status (profile, check_json, checked_at) VALUES (?, ?, ?)
        #|       ON CONFLICT (profile) DO UPDATE SET check_json = excluded.check_json, checked_at = excluded.checked_at
      ),
      [profile, jstr(js(check)), checked_at(check)],
    ),
  )
}

///|
/// profile-hours.ts `hourWindows`.
fn hour_windows(quota : Json) -> Array[Json] {
  guard quota is Object(q) else { return [] }
  let all = arr(q.get("windows").unwrap_or(Json::null())) +
    arr(q.get("scoped").unwrap_or(Json::null()))
  let num = (v : Json?) => {
    match v {
      Some(Number(n, ..) as x) if !n.is_nan() && !n.is_inf() => x
      _ => Json::null()
    }
  }
  all.filter_map(w => {
    guard w is Object(r) else { return None }
    let used = num(r.get("usedPercent"))
    if used is Null {
      return None
    }
    Some({
      "label": match r.get("label") {
        Some(String(_) as l) => l
        _ => jstr("")
      },
      "scope": match r.get("scope") {
        Some(String(s) as x) if s != "" => x
        _ => Json::null()
      },
      "usedPercent": used,
      "resetsAt": num(r.get("resetsAt")),
      "minutes": num(r.get("minutes")),
    })
  })
}

///|
/// Keeps a profile's quota, and an allowance read as its hour's: the last reading of each hour, those PACE_HOURS before
/// it let go in the same write.
pub fn Store::set_profile_quota(
  self : Store,
  profile : Json,
  quota : Json,
) -> Unit raise {
  let at = checked_at(quota)
  let windows = if quota is Object(q) &&
    q.get("state") is Some(String("ok")) &&
    at is Number(a, ..) &&
    a > 0.0 {
    hour_windows(quota)
  } else {
    []
  }
  fn status() raise {
    ignore(
      self.run(
        (
          #|INSERT INTO profile_status (profile, quota_json, quota_at) VALUES (?, ?, ?)
          #|       ON CONFLICT (profile) DO UPDATE SET quota_json = excluded.quota_json, quota_at = excluded.quota_at
        ),
        [profile, jstr(js(quota)), at],
      ),
    )
  }

  guard windows.length() > 0 && at is Number(a, ..) else {
    status()
    return
  }
  // One commit, not three: each autocommit is an fsync.
  let hour = (a / hour_ms).floor()
  self.tx(() => {
    status()
    ignore(
      self.run(
        (
          #|INSERT INTO profile_quota_hours (profile, hour, windows_json, at) VALUES (?, ?, ?, ?)
          #|       ON CONFLICT (profile, hour) DO UPDATE SET windows_json = excluded.windows_json, at = excluded.at
        ),
        [profile, jnum(hour), jstr(js(Json::array(windows))), at],
      ),
    )
    ignore(
      self.run("DELETE FROM profile_quota_hours WHERE profile = ? AND hour < ?", [
        profile,
        jnum(hour - pace_hours),
      ]),
    )
  })
}

///|
/// What the profiles' allowances said and their calls spent in each of the PACE_HOURS hours up to `now_hour`.
pub fn Store::profile_hours(self : Store, now_hour : Double) -> Json raise {
  let from = now_hour - pace_hours
  let quotas : Array[Json] = self
    .all(quota_hours_read, [jnum(from)])
    .map(r => {
      "profile": col(r, "profile"),
      "hour": col(r, "hour"),
      "at": col(r, "at"),
      "windows": parsed(col(r, "windows_json")).unwrap_or(Json::array([]))
      |> or_else(Json::array([])),
    })
  let spend : Array[Json] = self
    .all(spend_hours_read, [jnum(from * 4.0)])
    .map(r => {
      "hour": col(r, "hour"),
      "profile": col(r, "profile"),
      "runtime": col(r, "runtime"),
      "model": if col(r, "model") is String("") {
        Json::null()
      } else {
        col(r, "model")
      },
      "fast": jbool(is_n(col(r, "fast"), 1.0)),
      "calls": col(r, "calls"),
      "input": col(r, "input"),
      "cacheRead": col(r, "cache_read"),
      "cacheWrite": col(r, "cache_write"),
      "cacheWriteLong": col(r, "cache_write_long"),
      "output": col(r, "output"),
      "genMs": col(r, "gen_ms"),
      "genOutput": col(r, "gen_output"),
    })
  let speed : Array[Json] = self
    .all(speed_quarters_read, [jnum((now_hour - speed_quarter_hours) * 4.0)])
    .map(r => {
      "quarter": col(r, "quarter"),
      "profile": col(r, "profile"),
      "model": col(r, "model"),
      "genMs": col(r, "gen_ms"),
      "genOutput": col(r, "gen_output"),
    })
  { "quotas": Json::array(quotas), "spend": Json::array(spend), "speed": Json::array(speed) }
}

///|
pub fn Store::forget_profile_hours(self : Store, profile : Json) -> Unit raise {
  ignore(
    self.run("DELETE FROM profile_quota_hours WHERE profile = ?", [profile]),
  )
}

// ── runtime process groups ──

///|
pub fn Store::record_process(
  self : Store,
  pgid : Json,
  started_at : Json,
  runtime : Json,
  label : Json,
) -> Unit raise {
  self.with_changes(changes => {
    ignore(
      self.run(
        "INSERT OR REPLACE INTO processes (pgid, started_at, runtime, label) VALUES (?, ?, ?, ?)",
        [pgid, started_at, runtime, label],
      ),
    )
    changes.push({ "type": "processes" })
  })
}

///|
pub fn Store::forget_process(self : Store, pgid : Json) -> Unit raise {
  self.with_changes(changes => {
    if self.run("DELETE FROM processes WHERE pgid = ?", [pgid]) > 0 {
      changes.push({ "type": "processes" })
    }
  })
}

///|
fn process_row(r : Map[String, Json]) -> Json {
  {
    "pgid": col(r, "pgid"),
    "startedAt": col(r, "started_at"),
    "runtime": col(r, "runtime"),
    "label": col(r, "label"),
  }
}

///|
pub fn Store::list_processes(self : Store) -> Array[Json] raise {
  self.all("SELECT * FROM processes", []).map(process_row)
}

///|
pub fn Store::process_by_group(self : Store, pgid : Json) -> Json raise {
  match self.one(process_by_group, [pgid]) {
    Some(r) => process_row(r)
    None => Json::null()
  }
}

// ── background jobs ──

///|
/// store.ts REMOTE_RUNS_MS.
let remote_runs_ms : Double = 7776000000.0

///|
/// store.ts JOB_NOTICES.
let job_notices : Int32 = 50

///|
pub fn Store::note_remote_run(
  self : Store,
  job : Json,
  session : Json,
  at : Double,
) -> Unit raise {
  self.tx(() => {
    ignore(
      self.run(
        "INSERT OR IGNORE INTO remote_runs (job, at, session) VALUES (?, ?, ?)",
        [job, jnum(at), session],
      ),
    )
    let indexed = match
      self.one("SELECT done FROM remote_run_progress WHERE id = 1", []) {
      Some(r) => is_n(col(r, "done"), 1.0)
      None =>
        raise store_error(
          "Cannot read properties of undefined (reading 'done')",
        )
    }
    ignore(
      self.run(
        if indexed {
          delete_expired_remote_runs
        } else {
          "DELETE FROM remote_runs WHERE at < ?"
        },
        [jnum(at - remote_runs_ms)],
      ),
    )
  })
}

///|
/// rows.ts JobRow, as JSON.
pub fn Store::insert_job(self : Store, job : Json) -> Unit raise {
  let get = (k : String) => nullish(field(job, k))
  self.with_changes(changes => {
    ignore(
      self.run(
        "INSERT INTO jobs (id, session_key, name, command, cwd, port, token, state, pgid, exit_code, started_at, ended_at, restarts, log, watch, queued, screen, size, small) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [
          get("id"),
          get("sessionKey"),
          get("name"),
          get("command"),
          get("cwd"),
          get("port"),
          get("token"),
          get("state"),
          get("pgid"),
          get("exitCode"),
          get("startedAt"),
          get("endedAt"),
          get("restarts"),
          get("log"),
          flag(truthy(get("watch"))),
          flag(get("queued") is True),
          flag(get("screen") is True),
          match field(job, "sandbox") {
            Some(s) => jstr(js(s))
            None => Json::null()
          },
          flag(get("small") is True),
        ],
      ),
    )
    changes.push(session_change(get("sessionKey")))
    changes.push({ "type": "job", "id": get("id") })
  })
}

///|
pub fn Store::job_started(
  self : Store,
  id : Json,
  pgid : Json,
  restarted : Bool,
) -> Unit raise {
  self.job_update(
    id,
    "UPDATE jobs SET state = 'running', pgid = ?1, exit_code = NULL, ended_at = NULL, restarts = restarts + ?2, started_at = CASE WHEN ?2 = 0 AND COALESCE(queued, 0) <> 0 THEN ?4 ELSE started_at END, queued = 0 WHERE id = ?3",
    [pgid, flag(restarted), id, self.now_json()],
  )
}

///|
pub fn Store::job_ended(
  self : Store,
  id : Json,
  state : Json,
  exit_code : Json,
) -> Unit raise {
  self.job_update(
    id,
    "UPDATE jobs SET state = ?1, exit_code = ?2, ended_at = ?3, pgid = NULL, queued = 0 WHERE id = ?4",
    [state, exit_code, self.now_json(), id],
  )
}

///|
fn Store::job_update(
  self : Store,
  id : Json,
  sql : String,
  args : Array[Json],
) -> Unit raise {
  self.with_changes(changes => {
    ignore(self.run(sql, args))
    self.job_changed(id, changes)
  })
}

///|
fn Store::job_changed(
  self : Store,
  id : Json,
  changes : Array[Json],
) -> Unit raise {
  if self.one("SELECT session_key FROM jobs WHERE id = ?", [id]) is Some(r) {
    changes.push(session_change(col(r, "session_key")))
    changes.push({ "type": "job", "id": id })
  }
}

///|
pub fn Store::get_job(self : Store, id : Json) -> Json raise {
  match self.one("SELECT * FROM jobs WHERE id = ?", [id]) {
    Some(r) => to_job(r)
    None => Json::null()
  }
}

///|
pub fn Store::job_by_token(self : Store, token : Json) -> Json raise {
  match self.one("SELECT * FROM jobs WHERE token = ?", [token]) {
    Some(r) => to_job(r)
    None => Json::null()
  }
}

///|
pub fn Store::jobs_up(self : Store) -> Array[Json] raise {
  self.all(jobs_up, []).map(to_job)
}

///|
/// What `jobs_up` gives of a job for its directory: its session's key and cwd (`""` for none).
fn place_of_job(r : Map[String, Json]) -> (String, String) {
  (str_of(col(r, "session_key")).unwrap_or(""), str_of(col(r, "cwd")).unwrap_or(""))
}

///|
/// The jobs of `jobs_up`, each its session's key and cwd only.
pub fn Store::jobs_up_places(self : Store) -> Array[(String, String)] raise {
  self.all(jobs_up_places, []).map(place_of_job)
}

///|
pub fn Store::jobs_up_of(self : Store, keys : Array[Json]) -> Array[Json] raise {
  let out = []
  for k in keys {
    for id in self.up_job_ids(k, false) {
      let job = self.get_job(id)
      if !(job is Null) {
        out.push(job)
      }
    }
  }
  let started = (j : Json) => {
    num_of(nullish(field(j, "startedAt"))).unwrap_or(0.0)
  }
  // (stably, the latest first)
  let order = Array::makei(out.length(), i => i)
  order.sort_by((a, b) => {
    let c = started(out[b]).compare(started(out[a]))
    if c != 0 {
      c
    } else {
      a.compare(b)
    }
  })
  order.map(i => out[i])
}

///|
pub fn Store::live_sessions_on(
  self : Store,
  pid : Json,
  most : Json,
) -> Array[Json] raise {
  self.all(live_on_profile, [pid, most]).map(r => col(r, "key"))
}

///|
pub fn Store::jobs_mark_of(self : Store, keys : Array[Json]) -> Json raise {
  let out = []
  if keys.length() == 0 {
    return entries(out)
  }
  for x in self.all(last_jobs_of, [jstr(js(Json::array(keys)))]) {
    let end = match col(x, "e") {
      Null => col(x, "state")
      e => e
    }
    let k = js_string(col(x, "k"))
    let v = jstr("\{js_string(col(x, "r"))}/\{js_string(end)}")
    let mut at = -1
    for i, e in out {
      if e.0 == k {
        at = i
      }
    }
    if at < 0 {
      out.push((k, v))
    } else {
      out[at] = (k, v)
    }
  }
  entries(out)
}

///|
pub fn Store::job_at_port(self : Store, port : Json) -> Json raise {
  match self.one(job_at_port, [port]) {
    Some(r) =>
      { "id": col(r, "id"), "name": col(r, "name"), "port": col(r, "port") }
    None => Json::null()
  }
}

///|
pub fn Store::list_jobs(self : Store, session : Json) -> Array[Json] raise {
  (match session {
    Null => self.all("SELECT * FROM jobs ORDER BY started_at DESC", [])
    s => self.all(session_jobs, [s])
  }).map(to_job)
}

///|
pub fn Store::jobs_running(self : Store) -> Array[Json] raise {
  self.all(jobs_running, []).map(to_job)
}

///|
/// store.ts `#active`: an active-job lookup, or the one from before where its table or index is not there yet.
fn Store::active(
  self : Store,
  sql : String,
  before : String,
  args : Array[Json],
) -> Array[Map[String, Json]] raise {
  self.all(sql, args) catch {
    @wire.ShellError(message) as e => {
      if !message.contains("no such table: active_watch_jobs") &&
        !message.contains("no such table: active_other_jobs") &&
        !message.contains("no such index: active_other_remote_jobs") {
        raise e
      }
      if sql == remote_queue_jobs &&
        message.contains("no such index: active_other_remote_jobs") &&
        self.active_remote_jobs_available() {
        return self.all(remote_queue_prepared, args)
      }
      self.all(before, args)
    }
    e => raise e
  }
}

///|
/// active-jobs-upgrade.ts `activeRemoteJobsAvailable`.
fn Store::active_remote_jobs_available(self : Store) -> Bool raise {
  if !self.table("active_remote_job_meta") {
    return false
  }
  match
    self.one(
      "SELECT version, complete FROM active_remote_job_meta WHERE id = 1",
      [],
    ) {
    Some(r) => is_n(col(r, "version"), 1.0) && is_n(col(r, "complete"), 1.0)
    None => false
  }
}

///|
pub fn Store::remote_queue_jobs(self : Store) -> Array[Json] raise {
  self
  .active(remote_queue_jobs, remote_queue_before_upgrade, [])
  .map(r => {
    let o : Map[String, Json] = Map([])
    o["id"] = col(r, "id")
    o["sessionKey"] = col(r, "session_key")
    o["startedAt"] = col(r, "started_at")
    if is_n(col(r, "queued"), 1.0) {
      o["queued"] = jbool(true)
    }
    if is_n(col(r, "screen"), 1.0) {
      o["screen"] = jbool(true)
    }
    if is_n(col(r, "small"), 1.0) {
      o["small"] = jbool(true)
    }
    Json::object(o)
  })
}

///|
pub fn Store::awake_jobs(self : Store) -> Array[Json] raise {
  self
  .active(awake_jobs, awake_jobs_before_upgrade, [])
  .map(r => {
    "sessionKey": col(r, "session_key"),
    "startedAt": col(r, "started_at"),
  })
}

///|
pub fn Store::running_jobs_at_least(
  self : Store,
  session : Json,
  limit : Double,
) -> Bool raise {
  limit <= 0.0 ||
  self
  .active(running_limit, running_limit_before_upgrade, [
    session,
    jnum(limit - 1.0),
  ])
  .length() !=
  0
}

///|
pub fn Store::running_job_sessions(
  self : Store,
  sessions : Array[Json],
) -> Array[Json] raise {
  if sessions.length() == 0 {
    return []
  }
  let out = []
  for
    r in self.active(
      running_job_sessions,
      running_job_sessions_before_upgrade,
      [jstr(js(Json::array(sessions)))],
    ) {
    let s = col(r, "session")
    if !out.contains(s) {
      out.push(s)
    }
  }
  out
}

///|
pub fn Store::running_wait_job_ids(
  self : Store,
  session : Json,
) -> Array[Json] raise {
  self
  .active(running_wait_jobs, running_wait_jobs_before_upgrade, [session])
  .map(r => col(r, "id"))
}

///|
/// session-up-jobs.ts `sessionUpJobsReady`.
fn Store::session_up_jobs_ready(self : Store, session : Json) -> Bool raise {
  let meta = self.one(
    "SELECT version, fresh FROM session_up_job_meta WHERE id = 1",
    [],
  )
  match meta {
    Some(m) if is_n(col(m, "version"), 1.0) => {
      if is_n(col(m, "fresh"), 1.0) {
        return true
      }
      match
        self.one(
          "SELECT complete FROM session_up_job_scopes WHERE session = ?",
          [session],
        ) {
        Some(r) => is_n(col(r, "complete"), 1.0)
        None => false
      }
    }
    Some(m) =>
      raise store_error(
        "session up jobs index version \{js_string(col(m, "version"))} is incompatible with 1",
      )
    None =>
      raise store_error(
        "session up jobs index version missing is incompatible with 1",
      )
  }
}

///|
pub fn Store::up_job_ids(
  self : Store,
  session : Json,
  old : Bool,
) -> Array[Json] raise {
  let sql = if !old && self.session_up_jobs_ready(session) {
    session_up_jobs
  } else {
    up_jobs_of_session
  }
  self.active(sql, up_jobs_before_upgrade, [session]).map(r => col(r, "id"))
}

///|
pub fn Store::session_has_up_job(self : Store, session : Json) -> Json raise {
  if self.session_up_jobs_ready(session) {
    jbool(self.one(session_up_job, [session]) is Some(_))
  } else {
    Json::null()
  }
}

///|
pub fn Store::running_jobs(self : Store) -> Json raise {
  let r = self.one(
    "SELECT COALESCE(SUM(substr(id, 1, 7) = 'remote_'), 0) AS remote, COALESCE(SUM(substr(id, 1, 7) <> 'remote_' AND port IS NOT NULL), 0) AS services, COUNT(*) AS n FROM jobs WHERE state = 'running' AND COALESCE(queued, 0) = 0",
    [],
  )
  let num = (k : String) => {
    match r {
      Some(r) => num_of(js_number(col(r, k))).unwrap_or(0.0)
      None => 0.0
    }
  }
  let remote = num("remote")
  let services = num("services")
  {
    "remote": jnum(remote),
    "services": jnum(services),
    "jobs": jnum(num("n") - remote - services),
  }
}

///|
pub fn Store::add_job_notice(
  self : Store,
  id : Json,
  text : Json,
) -> Unit raise {
  self.with_changes(changes => {
    ignore(
      self.run("INSERT INTO job_notices (job_id, at, text) VALUES (?, ?, ?)", [
        id,
        self.now_json(),
        text,
      ]),
    )
    ignore(
      self.run(
        "DELETE FROM job_notices WHERE job_id = ?1 AND rowid NOT IN (SELECT rowid FROM job_notices WHERE job_id = ?1 ORDER BY at DESC, rowid DESC LIMIT ?2)",
        [id, ints(job_notices)],
      ),
    )
    self.job_changed(id, changes)
  })
}

///|
/// A session's jobs that are over, taken off its record with what they said: their ids and logs.
pub fn Store::clear_ended_jobs(
  self : Store,
  session : Json,
) -> Array[Json] raise {
  self.with_changes(changes => {
    let gone = self.tx(() => {
      let gone = self
        .all(
          "SELECT id, log FROM jobs WHERE session_key = ? AND (state IN ('stopped', 'failed') OR (state = 'exited' AND port IS NULL))",
          [session],
        )
        .map(r => Json::array([col(r, "id"), col(r, "log")]))
      for g in gone {
        let id = arr(g)[0]
        ignore(self.run("DELETE FROM job_notices WHERE job_id = ?", [id]))
        ignore(self.run("DELETE FROM jobs WHERE id = ?", [id]))
      }
      gone
    })
    if gone.length() > 0 {
      changes.push(session_change(session))
      for g in gone {
        changes.push({
          "type": "jobRemoved",
          "id": arr(g)[0],
          "session": session,
        })
      }
    }
    gone
  })
}

///|
pub fn Store::job_notices(
  self : Store,
  id : Json,
  limit : Json,
) -> Array[Json] raise {
  self
  .all(
    "SELECT at, text FROM job_notices WHERE job_id = ? ORDER BY at DESC, rowid DESC LIMIT ?",
    [id, limit],
  )
  .map(r => { "at": col(r, "at"), "text": col(r, "text") })
}

// ── widget states ──

///|
pub fn Store::put_widget_state(
  self : Store,
  session : Json,
  path : Json,
  state : Json,
  model : Json,
) -> Unit raise {
  ignore(
    self.run(
      (
        #|INSERT INTO widget_states (session, path, state, model, updated_at) VALUES (?, ?, ?, ?, ?)
        #|       ON CONFLICT (session, path) DO UPDATE SET state = excluded.state, model = excluded.model, updated_at = excluded.updated_at,
        #|         told_at = CASE WHEN widget_states.model IS excluded.model THEN widget_states.told_at END
      ),
      [session, path, state, model, self.now_json()],
    ),
  )
}

///|
pub fn Store::widget_state(
  self : Store,
  session : Json,
  path : Json,
) -> Json raise {
  match
    self.one("SELECT state FROM widget_states WHERE session = ? AND path = ?", [
      session, path,
    ]) {
    Some(r) => col(r, "state")
    None => Json::null()
  }
}

///|
/// The widget sources of a session's threads are still being prepared (widget-sources.ts WidgetSourcesUnavailable).
fn widget_sources_unavailable(threads : Array[Json]) -> StoreError {
  StoreError("widget sources are still being prepared", {
    "threads": Json::array(threads),
  })
}

///|
/// The last part of a path, split at either slash.
fn base_name(path : String) -> String {
  @nodepath.basename("\\", path)
}

///|
/// The session's widget models it has not been told, with where each widget was posted.
pub fn Store::untold_widget_models(
  self : Store,
  session : Json,
) -> Array[Json] raise {
  self.savepoint("widget_source_read", () => {
    let untold = self.all(
      "SELECT path, model FROM widget_states WHERE session = ? AND model IS NOT NULL AND told_at IS NULL ORDER BY updated_at, rowid",
      [session],
    )
    if untold.length() == 0 {
      return []
    }
    match self.one("SELECT version FROM widget_source_meta WHERE id=1", []) {
      Some(m) if is_n(col(m, "version"), 1.0) => ()
      Some(m) =>
        raise store_error(
          "widget source index version \{js_string(col(m, "version"))} is incompatible with 1",
        )
      None =>
        raise store_error(
          "widget source index version missing is incompatible with 1",
        )
    }
    let missing = self
      .all(widget_source_missing, [session])
      .map(r => col(r, "thread"))
    if missing.length() != 0 {
      raise widget_sources_unavailable(missing)
    }
    let unusual = self.one(widget_source_unusual, [session]) is Some(_)
    untold.map(u => {
      let path = col(u, "path")
      let model = col(u, "model")
      let found = self.one(
        if unusual {
          widget_source_original
        } else {
          widget_source
        },
        [session, path],
      )
      let base = base_name(js_string(path))
      match found {
        None =>
          {
            "path": path,
            "name": jstr(base),
            "thread": Json::null(),
            "model": model,
          }
        Some(f) => {
          let name = if col(f, "name") is String(n) && n != "" {
            col(f, "name")
          } else {
            jstr(base)
          }
          {
            "path": path,
            "name": name,
            "thread": Json::array([col(f, "channel"), col(f, "thread_ts")]),
            "model": model,
          }
        }
      }
    })
  })
}

///|
/// The agent was told these (`[path, model]` each): each marked told unless its model changed since.
pub fn Store::mark_widget_models_told(
  self : Store,
  session : Json,
  told : Array[Json],
) -> Unit raise {
  let now = self.now_json()
  for t in told {
    let x = arr(t)
    ignore(
      self.run(
        "UPDATE widget_states SET told_at = ? WHERE session = ? AND path = ? AND model = ?",
        [now, session, x[0], x[1]],
      ),
    )
  }
}
