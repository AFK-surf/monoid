// The archive's decisions: the checks recorded, each session's latest, a workspace's policy and what a review found
// or suggested for a thread (store.ts `decisionsVersion` … `archiveSuggested`), with the older stores' lookups as the
// store reads them while they are prepared.

///|
fn decision_of(r : Map[String, Json]) -> Json {
  {
    "id": col(r, "id"),
    "session": col(r, "session"),
    "at": col(r, "created_at"),
    "detail": match parsed(col(r, "result")) {
      Some(v) => to_json(v)
      None => Json::null()
    },
  }
}

///|
pub fn Store::decisions_version(self : Store) -> Json {
  jint(self.decisions)
}

///|
pub fn Store::recent_decisions(self : Store) -> Json raise {
  Json::array(self.all("SELECT id, session, created_at, result FROM decision_checks ORDER BY id DESC LIMIT 30", []).map(decision_of))
}

///|
pub fn Store::record_decision(self : Store, session : Json, result : @jsjson.JValue) -> Json raise {
  self.with_(changes => {
    ignore(self.run("INSERT INTO decision_checks(session, created_at, result) VALUES (?, ?, ?)", [
      session,
      self.now_json(),
      jstr(stringify(result)),
    ]))
    changes.push({ "type": "decisionChecks" })
    self.decisions += 1
    undefined
  })
}

///|
fn Store::use_decision_session(self : Store, lookup : String) -> Unit {
  self.legacy_decision_session = if lookup == "native" { None } else { Some(lookup) }
  self.decision_session_index_was_missing = false
}

///|
/// store.ts `#decisionSessionLookup`.
fn Store::decision_session_lookup(self : Store, verify_native? : Bool = false) -> String raise {
  if !self.decision_session_index_was_missing && !verify_native {
    guard self.legacy_decision_session is Some(legacy) else { return "native" }
    let table = match legacy {
      "shared" => "legacy_decision_time_meta"
      "repair" => "legacy_decision_session_repair_meta"
      _ => "legacy_decision_session_meta"
    }
    let found = try {
      let state = self.one(
        "SELECT complete, CASE WHEN complete=0 THEN EXISTS (\n          SELECT 1 FROM sqlite_master WHERE type='index' AND name='decision_checks_session') ELSE 0 END AS native\n          FROM \{table} WHERE id=1",
        [],
      )
      if state is Some(s) && is_num(col(s, "complete"), 1.0) {
        Some(legacy)
      } else if state is Some(s) && is_num(col(s, "native"), 1.0) {
        self.use_decision_session("native")
        Some("native")
      } else {
        let current = self.decision_session_lookup(verify_native=true)
        if current != "pending" {
          self.use_decision_session(current)
        }
        Some(current)
      }
    } catch {
      e => {
        if !sql_message(e).contains("no such table: \{table}") {
          raise e
        }
        self.decision_session_index_was_missing = true
        None
      }
    }
    if found is Some(f) {
      return f
    }
  }
  let indexes = self
    .one(
      "SELECT\n      EXISTS(SELECT 1 FROM sqlite_master WHERE type='index' AND name='decision_checks_session') AS native,\n      EXISTS(SELECT 1 FROM sqlite_master WHERE type='index' AND name='legacy_decision_time_by_session') AS shared,\n      EXISTS(SELECT 1 FROM sqlite_master WHERE type='index' AND name='legacy_decision_session_by_session') AS separate,\n      EXISTS(SELECT 1 FROM sqlite_master WHERE type='index' AND name='legacy_decision_session_repair_by_session') AS repair",
      [],
    )
    .unwrap()
  if is_num(col(indexes, "native"), 1.0) {
    return "native"
  }
  for kt in [
    ("shared", "legacy_decision_time_meta"),
    ("separate", "legacy_decision_session_meta"),
    ("repair", "legacy_decision_session_repair_meta"),
  ] {
    let (kind, table) = kt
    if !is_num(col(indexes, kind), 1.0) {
      continue
    }
    let complete = try self.one("SELECT complete FROM \{table} WHERE id=1", []) catch {
      e => {
        if !sql_message(e).contains("no such table: \{table}") {
          raise e
        }
        None
      }
    }
    if complete is Some(c) && is_num(col(c, "complete"), 1.0) {
      return kind
    }
  }
  "pending"
}

///|
/// A message matching "no such index|table: [main.]NAME" at its end, NAME one of `names`.
fn missing_object(message : String, kinds : Array[String], names : Array[String]) -> Bool {
  for kind in kinds {
    for name in names {
      for prefix in ["", "main."] {
        if message.has_suffix("no such \{kind}: \{prefix}\{name}") {
          return true
        }
      }
    }
  }
  false
}

///|
/// store.ts `#smallRecentDecisionScope`.
fn Store::small_recent_decision_scope(self : Store, since : Json, workspace : Json) -> Array[Json]? raise {
  let time_index = match
    self.one(
      "SELECT name FROM sqlite_master WHERE type='index'\n      AND name IN ('decision_checks_lately','decision_checks_at') ORDER BY name='decision_checks_lately' DESC LIMIT 1",
      [],
    ) {
    Some(r) => text_of(col(r, "name"))
    None => None
  }
  let source = match time_index {
    Some("decision_checks_lately") => Some(small_decision_scope_native_sql)
    Some("decision_checks_at") => Some(small_decision_scope_old_sql)
    _ =>
      if self.legacy_decision_time &&
        self.one("SELECT complete FROM legacy_decision_time_meta WHERE id=1", []) is Some(c) &&
        is_num(col(c, "complete"), 1.0) {
        Some(small_decision_scope_prepared_sql)
      } else {
        None
      }
  }
  guard source is Some(sql) else { return None }
  let rows = self.all(sql, [since, workspace]) catch {
    e => {
      let m = sql_message(e)
      if !missing_object(m, ["index", "table"], [
          "decision_checks_lately", "decision_checks_at", "legacy_decision_time", "legacy_decision_time_at",
        ]) {
        raise e
      }
      return None
    }
  }
  if rows.length() > 0 && num(col(rows[0], "n")) > 64.0 {
    return None
  }
  Some(rows.filter(r => !(col(r, "id") is Null)).map(decision_of))
}

///|
fn Store::recent_last_decision(self : Store, session : Json) -> Json raise {
  let recent = self.one(recent_last_decision_sql, [session])
  if recent is Some(r) && is_num(col(r, "found"), 1.0) {
    return match parsed(col(r, "result")) {
      Some(v) => to_json(v)
      None => Json::null()
    }
  }
  if recent is Some(r) && num(col(r, "n")) < 64.0 {
    return Json::null()
  }
  raise DecisionSessionsUnavailable
}

///|
pub fn Store::last_decision(self : Store, session : Json) -> Json raise {
  let lookup = self.decision_session_lookup()
  if lookup == "pending" {
    return self.recent_last_decision(session)
  }
  let sql = match lookup {
    "native" => "SELECT result FROM decision_checks INDEXED BY decision_checks_session WHERE session = ? ORDER BY id DESC LIMIT 1"
    "shared" => legacy_last_decision_shared_sql
    "repair" => legacy_last_decision_repair_sql
    _ => legacy_last_decision_separate_sql
  }
  let row = self.one(sql, [session]) catch {
    e => {
      let m = sql_message(e)
      if !missing_object(m, ["index", "table"], [
          "decision_checks_session", "legacy_decision_time", "legacy_decision_time_meta", "legacy_decision_time_by_session",
          "legacy_decision_session", "legacy_decision_session_meta", "legacy_decision_session_by_session", "legacy_decision_time_repair",
          "legacy_decision_time_repair_meta", "legacy_decision_time_repair_by_session", "legacy_decision_session_repair",
          "legacy_decision_session_repair_meta", "legacy_decision_session_repair_by_session",
        ]) {
        raise e
      }
      if !self.decision_session_index_was_missing {
        self.decision_session_index_was_missing = true
        return self.last_decision(session)
      }
      return self.recent_last_decision(session)
    }
  }
  if self.decision_session_index_was_missing {
    self.use_decision_session(lookup)
  }
  match row {
    Some(r) =>
      match parsed(col(r, "result")) {
        Some(v) => to_json(v)
        None => Json::null()
      }
    None => Json::null()
  }
}

///|
fn decision_scoped_with_session(legacy : Bool, without_time : Bool, session : String) -> String {
  match (session, without_time, legacy) {
    ("shared", true, _) => decision_scoped_shared_no_time_sql
    ("shared", _, true) => decision_scoped_shared_legacy_sql
    ("shared", _, _) => decision_scoped_shared_native_sql
    ("separate", true, _) => decision_scoped_separate_no_time_sql
    ("separate", _, true) => decision_scoped_separate_legacy_sql
    ("separate", _, _) => decision_scoped_separate_native_sql
    (_, true, _) => decision_scoped_repair_no_time_sql
    (_, _, true) => decision_scoped_repair_legacy_sql
    _ => decision_scoped_repair_native_sql
  }
}

///|
/// store.ts `latestDecisionsSince`: `viewer` absent (Null) or {workspace, home?}.
pub fn Store::latest_decisions_since(self : Store, since : Json, viewer : Json) -> Json raise {
  let given = viewer is Object(_)
  let field = (k : String) => match viewer {
    Object(o) => o.get(k)
    _ => None
  }
  let workspace = field("workspace").unwrap_or(Json::null())
  let not_home = given && field("home") == Some(Json::boolean(false))
  let lookup = if not_home { self.decision_session_lookup() } else { "native" }
  let session_names = [
    "decision_checks_session", "legacy_decision_time_by_session", "legacy_decision_session", "legacy_decision_session_meta",
    "legacy_decision_session_by_session", "legacy_decision_session_repair", "legacy_decision_session_repair_meta",
    "legacy_decision_session_repair_by_session",
  ]
  let is_missing_session = (m : String) => missing_object(m, ["index", "table"], session_names)
  let missing_session = () => {
    self.decision_session_index_was_missing = true
    let current = self.decision_session_lookup(verify_native=true)
    if current != "pending" && current != lookup {
      return self.latest_decisions_since(since, viewer)
    }
    match self.small_recent_decision_scope(since, workspace) {
      Some(small) => Json::array(small)
      None => raise DecisionSessionsUnavailable
    }
  }
  if not_home && lookup == "pending" {
    return match self.small_recent_decision_scope(since, workspace) {
      Some(small) => Json::array(small)
      None => raise DecisionSessionsUnavailable
    }
  }
  let session_lookup = lookup == "shared" || lookup == "separate" || lookup == "repair"
  let home_flag = jint(if field("home") == Some(Json::boolean(false)) { 0 } else { 1 })
  let rows = try {
    if !given {
      self.all(if self.legacy_decision_time { legacy_latest_decisions_sql } else { latest_decisions_sql }, [since])
    } else if !not_home {
      self.all(
        if self.legacy_decision_time {
          legacy_latest_decisions_scoped_fallback_sql
        } else {
          @readops.latest_decisions_scoped_fallback
        },
        [since, workspace, jint(1)],
      )
    } else {
      self.all(
        if session_lookup {
          decision_scoped_with_session(self.legacy_decision_time, false, lookup)
        } else if self.legacy_decision_time {
          legacy_latest_decisions_scoped_sql
        } else {
          @readops.latest_decisions_scoped
        },
        [since, workspace, jint(0)],
      )
    }
  } catch {
    e => {
      let m = sql_message(e)
      if !missing_object(m, ["index"], [
          "sessions_by_connect", "decision_checks_session", "decision_checks_lately", "legacy_decision_time_at", "legacy_decision_time_by_session",
          "legacy_decision_session_by_session", "legacy_decision_session_repair_by_session",
        ]) &&
        !missing_object(m, ["table"], [
          "legacy_decision_time", "legacy_decision_time_meta", "legacy_decision_session", "legacy_decision_session_meta",
          "legacy_decision_session_repair", "legacy_decision_session_repair_meta",
        ]) {
        raise e
      }
      if not_home && is_missing_session(m) {
        return missing_session()
      }
      let fallback = () => if !given {
        self.all(latest_decisions_sql, [since])
      } else {
        self.all(@readops.latest_decisions_scoped_fallback, [since, workspace, home_flag])
      }
      if not_home &&
        (
          missing_object(m, ["index"], ["decision_checks_lately", "legacy_decision_time_at"]) ||
          missing_object(m, ["table"], ["legacy_decision_time", "legacy_decision_time_meta"])
        ) {
        try {
          self.all(
            if session_lookup {
              decision_scoped_with_session(false, true, lookup)
            } else {
              latest_decisions_scoped_no_time_sql
            },
            [since, workspace, jint(0)],
          )
        } catch {
          retry => {
            let rm = sql_message(retry)
            if is_missing_session(rm) {
              return missing_session()
            }
            if !missing_object(rm, ["index", "table"], ["sessions_by_connect", "legacy_decision_time", "legacy_decision_time_meta"]) {
              raise retry
            }
            fallback()
          }
        }
      } else {
        fallback()
      }
    }
  }
  if not_home && lookup != "pending" && self.decision_session_index_was_missing {
    self.use_decision_session(lookup)
  }
  Json::array(rows.map(decision_of))
}

///|
pub fn Store::archive_policy(self : Store, ws : Json) -> Json raise {
  guard self.one(if self.legacy_archive_policy { legacy_archive_policy_sql } else { archive_policy_sql }, [ws]) is Some(r) else {
    return Json::null()
  }
  guard parsed(col(r, "policy")) is Some(policy) else { return Json::null() }
  match policy {
    Null | Bool(false) | Num(0.0) => return Json::null()
    Num(n) if n.is_nan() => return Json::null()
    Str(s) if s.is_empty() => return Json::null()
    _ => ()
  }
  {
    "policy": to_json(policy),
    "change": {
      "id": col(r, "id"),
      "at": col(r, "at"),
      "by": match parsed(col(r, "author")) {
        Some(v) => to_json(v)
        None => Json::null()
      },
      "summary": col(r, "summary"),
    },
  }
}

///|
pub fn Store::set_archive_policy(self : Store, policy : @jsjson.JValue, author : @jsjson.JValue, summary : Json, ws : Json) -> Json raise {
  self.with_(changes => {
    ignore(self.run("INSERT INTO archive_policy(at, policy, author, summary, ws) VALUES (?, ?, ?, ?, ?)", [
      self.now_json(),
      jstr(stringify(policy)),
      jstr(stringify(author)),
      summary,
      ws,
    ]))
    changes.push({ "type": "decisionChecks" })
    self.decisions += 1
    undefined
  })
}

///|
pub fn Store::set_archive_verdict(self : Store, session : Json, thread : Json, version : Json, verdict : @jsjson.JValue) -> Json raise {
  self.with_(changes => {
    ignore(
      self.run(
        "INSERT INTO archive_verdicts(thread, version, at, verdict) VALUES (?, ?, ?, ?) ON CONFLICT(thread) DO UPDATE SET version = excluded.version, at = excluded.at, verdict = excluded.verdict",
        [thread, version, self.now_json(), jstr(stringify(verdict))],
      ),
    )
    changes.push({ "type": "session", "key": session })
    changes.push({ "type": "chatMark", "thread": thread, "session": session, "archive": { "verdict": to_json(verdict) } })
    undefined
  })
}

///|
pub fn Store::suggest_archive(self : Store, session : Json, thread : Json, version : Json) -> Json raise {
  self.with_(changes => {
    ignore(
      self.run(
        "INSERT INTO archive_suggestions(thread, version, at) VALUES (?, ?, ?) ON CONFLICT(thread) DO UPDATE SET version = excluded.version, at = excluded.at",
        [thread, version, self.now_json()],
      ),
    )
    changes.push({ "type": "session", "key": session })
    changes.push({ "type": "chatMark", "thread": thread, "session": session, "archive": { "suggested": version } })
    undefined
  })
}

///|
pub fn Store::clear_archive_suggestion(self : Store, session : Json, thread : Json) -> Json raise {
  self.with_(changes => {
    if self.run("DELETE FROM archive_suggestions WHERE thread = ?", [thread]) > 0 {
      changes.push({ "type": "session", "key": session })
      changes.push({ "type": "chatMark", "thread": thread, "session": session, "archive": { "suggested": Json::null() } })
    }
    undefined
  })
}

///|
pub fn Store::archive_suggested(self : Store, thread : Json) -> Json raise {
  let version = try {
    match self.one("SELECT version FROM archive_suggestions WHERE thread = ?", [thread]) {
      Some(r) => col(r, "version")
      None => Json::null()
    }
  } catch {
    _ => Json::null()
  }
  jbool(!(version is Null) && version == self.last_entry(thread))
}
