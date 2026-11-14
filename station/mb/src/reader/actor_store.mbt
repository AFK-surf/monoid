// What of the store an actor reads and writes itself, on the station's database (store.ts, method by method: the same
// statements), where Node said where that is (`db`: a store in memory, as a test's, is Node's alone, asked as the rest
// is). What it changed is told Node (`changes`), whose store tells its followers as its own writes do (store.ts `told`).
// What is not here is asked of Node (actor_base.mbt `store`).

///|
fn sql_flag(on : Bool) -> Json {
  Json::number(if on { 1.0 } else { 0.0 })
}

///|
/// rows.ts `saidBefore`: a declared state in the words stations wrote before.
fn said_before(declared : String) -> String {
  match declared {
    "all_done" => "final"
    "need_decision" | "need_help" => "block"
    _ => declared
  }
}

///|
/// rows.ts `ending`: the same in today's.
fn ending_of(declared : String) -> String {
  match declared {
    "final" => "all_done"
    "block" | "need_decision" => "need_help"
    _ => declared
  }
}

///|
fn col(r : Map[String, Json], name : String) -> Json {
  r.get(name).unwrap_or(Json::null())
}

///|
/// rows.ts `toTurnSummary`.
fn turn_summary(r : Map[String, Json]) -> Json {
  let declared = col(r, "declared")
  let about = match (col(r, "about_thread"), col(r, "about_n"), col(r, "about_ts")) {
    (Null, _, _) | (_, Null, _) | (_, _, Null) => Json::null()
    (t, n, ts) => { "thread": t, "seq": n, "ts": ts }
  }
  {
    "kind": col(r, "kind"),
    "outcome": col(r, "outcome"),
    "declared": match declared { String(d) => jstr(said_before(d)); _ => Json::null() },
    "ending": match declared { String(d) => jstr(ending_of(d)); _ => Json::null() },
    "need": col(r, "need"),
    "about": about,
    "waitSeconds": col(r, "wait_seconds"),
    "waitFor": col(r, "wait_for"),
    "waitWatch": match col(r, "wait_watch") { Null => Json::null(); Number(n, ..) => jbool(n == 1.0); _ => Json::null() },
    "detail": col(r, "detail"),
    "startedAt": col(r, "started_at"),
    "endedAt": col(r, "ended_at"),
  }
}

///|
/// What of a session's row an actor reads (store.ts `getSession`, as rows.ts `toSession` says those fields).
fn session_of(r : Map[String, Json]) -> Json {
  {
    "key": col(r, "key"),
    "runtime": col(r, "runtime"),
    "profile": col(r, "profile"),
    "profilePinned": jbool(col(r, "profile_pinned") == Json::number(1.0)),
    "model": col(r, "model"),
    "effort": col(r, "effort"),
    "runtimeSessionId": col(r, "runtime_session_id"),
    "contextBefore": col(r, "context_before"),
    "archivedAt": col(r, "archived_at"),
  }
}

///|
fn Actors::changed_store(self : Actors, changes : Array[Json]) -> Unit {
  if changes.length() > 0 {
    self.say_node({ "changes": Json::array(changes) })
  }
}

///|
fn session_changed(key : String) -> Json {
  { "type": "session", "key": jstr(key) }
}

///|
/// `f` with `args` done here, where it is one of these: what it gives; None, asked of Node.
fn Actors::local_store(self : Actors, f : String, args : Array[Json]) -> Json? raise {
  guard self.db is Some(db) else { return None }
  let arg = (i : Int) => if i < args.length() { args[i] } else { Json::null() }
  let key = match arg(0) {
    String(s) => s
    _ => ""
  }
  match f {
    "getSession" =>
      match db.all("SELECT key, runtime, profile, profile_pinned, model, effort, runtime_session_id, context_before, archived_at FROM sessions WHERE key = ?", [arg(0)]) {
        [r, ..] => Some(session_of(r))
        _ => Some(Json::null())
      }
    "lastTurn" =>
      match db.all("SELECT * FROM turns WHERE session_key = ? ORDER BY started_at DESC, rowid DESC LIMIT 1", [arg(0)]) {
        [r, ..] => Some(turn_summary(r))
        _ => Some(Json::null())
      }
    "slackStop" =>
      match db.all("SELECT event_ts, turn_id FROM slack_stops WHERE session = ? AND connect = ? AND channel = ? AND thread_ts = ?", [arg(0), arg(1), arg(2), arg(3)]) {
        [r, ..] => Some({ "ts": col(r, "event_ts"), "turn": col(r, "turn_id") })
        _ => Some(Json::null())
      }
    "leftThread" =>
      Some(
        jbool(
          db.all(
            "SELECT 1 FROM thread_sessions m JOIN threads t ON t.id = m.thread WHERE m.session = ? AND m.connect = ? AND t.channel = ? AND t.thread_ts = ? AND m.left_at IS NOT NULL LIMIT 1",
            [arg(0), arg(1), arg(2), arg(3)],
          ).length() > 0,
        ),
      )
    "hasPending" =>
      Some(
        jbool(
          db.all(
            "SELECT 1 FROM deliveries d INDEXED BY deliveries_pending JOIN entries m ON m.thread = d.thread AND m.n = d.n AND m.kind = 'message' JOIN threads t ON t.id = d.thread JOIN thread_sessions ts ON ts.thread = t.id AND ts.session = d.session WHERE d.session = ? AND d.delivered_at IS NULL LIMIT 1",
            [arg(0)],
          ).length() > 0 ||
          db.all(
            "SELECT 1 FROM letter_deliveries d INDEXED BY letter_deliveries_pending JOIN letters l ON l.thread = d.thread AND l.n = d.n JOIN threads t ON t.id = d.thread JOIN thread_sessions ts ON ts.thread = t.id AND ts.session = d.session WHERE d.session = ? AND d.delivered_at IS NULL LIMIT 1",
            [arg(0)],
          ).length() > 0,
        ),
      )
    "notify" => {
      self.changed_store([session_changed(key)])
      Some(Json::null())
    }
    "setRunning" => {
      ignore(db.run("UPDATE sessions SET running = ?1, last_active_at = ?2 WHERE key = ?3", [sql_flag(truthy(arg(1))), jnum(self.now), arg(0)]))
      self.changed_store([session_changed(key)])
      Some(Json::null())
    }
    "setSessionContextBefore" => {
      ignore(db.run("UPDATE sessions SET context_before = ?1 WHERE key = ?2", [arg(1), arg(0)]))
      self.changed_store([session_changed(key)])
      Some(Json::null())
    }
    "setRuntimeSessionId" => {
      ignore(db.run("UPDATE sessions SET runtime_session_id = ?1 WHERE key = ?2", [arg(1), arg(0)]))
      self.changed_store([session_changed(key), { "type": "conversation", "key": jstr(key) }])
      Some(Json::null())
    }
    "rememberSlackStop" => {
      ignore(
        db.run(
          "INSERT INTO slack_stops (session, connect, channel, thread_ts, event_ts, turn_id) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (session, connect, channel, thread_ts) DO UPDATE SET event_ts = excluded.event_ts, turn_id = excluded.turn_id",
          [arg(0), arg(1), arg(2), arg(3), arg(4), arg(5)],
        ),
      )
      Some(Json::null())
    }
    "startTurnFor" => {
      let by = arg(3)
      let before = (c : String) => "(SELECT \{c} FROM turns WHERE session_key = ?2 ORDER BY started_at DESC LIMIT 1)"
      ignore(
        db.run(
          "INSERT INTO turns (id, session_key, kind, started_at, profile, person, thread) VALUES (?1, ?2, ?3, ?4, ?5, COALESCE(?6, \{before("person")}), COALESCE(?7, \{before("thread")}))",
          [arg(0), arg(1), arg(2), jnum(self.now), by.value("profile").unwrap_or(Json::null()), by.value("person").unwrap_or(Json::null()), by.value("thread").unwrap_or(Json::null())],
        ),
      )
      self.changed_store([session_changed(match arg(1) { String(s) => s; _ => "" })])
      Some(Json::null())
    }
    "setWaitFor" => {
      ignore(db.run("UPDATE turns SET wait_for = ?, wait_watch = ? WHERE id = ?", [arg(1), sql_flag(truthy(arg(2))), arg(0)]))
      Some(Json::null())
    }
    "setAbout" => {
      let (t, n, ts) = match arg(1) {
        Array([t, n, ts]) => (t, n, ts)
        _ => (Json::null(), Json::null(), Json::null())
      }
      ignore(db.run("UPDATE turns SET about_thread = ?, about_n = ?, about_ts = ? WHERE id = ?", [t, n, ts, arg(0)]))
      Some(Json::null())
    }
    "setNeed" => {
      ignore(db.run("UPDATE turns SET need = ? WHERE id = ?", [arg(1), arg(0)]))
      Some(Json::null())
    }
    "declareTurn" => {
      ignore(db.run("UPDATE turns SET declared = ?, wait_seconds = ? WHERE id = ? AND ended_at IS NULL", [arg(1), arg(2), arg(0)]))
      Some(Json::null())
    }
    "endTurn" => {
      db.exec("BEGIN IMMEDIATE")
      let session = (fn() raise {
        ignore(db.run("UPDATE turns SET ended_at = ?, outcome = ?, detail = ?, declared = ?, wait_seconds = ? WHERE id = ?", [jnum(self.now), arg(1), arg(2), arg(3), arg(4), arg(0)]))
        ignore(
          db.run(
            "UPDATE turns SET declared = 'final', wait_seconds = NULL WHERE id = ? AND declared IN ('block', 'need_help', 'need_human', 'need_decision') AND about_n IS NOT NULL AND EXISTS (SELECT 1 FROM closed_cards c WHERE c.thread = turns.about_thread AND c.n = turns.about_n)",
            [arg(0)],
          ),
        )
        match db.all("SELECT session_key FROM turns WHERE id = ?", [arg(0)]) {
          [r, ..] => str_of(r.get("session_key"))
          _ => None
        }
      })() catch {
        e => {
          db.exec("ROLLBACK") catch { _ => () }
          raise e
        }
      }
      db.exec("COMMIT")
      if session is Some(s) {
        self.changed_store([session_changed(s)])
      }
      Some(Json::null())
    }
    "stopWait" => {
      let n = db.run(
        "UPDATE turns SET outcome = 'aborted', declared = NULL, wait_seconds = NULL, detail = 'other: stopped while waiting' WHERE id = (SELECT id FROM turns WHERE session_key = ?1 ORDER BY started_at DESC, rowid DESC LIMIT 1) AND ended_at IS NOT NULL AND (declared = 'waiting' OR (?2 AND outcome = 'failed' AND detail LIKE 'rate_limit:%'))",
        [arg(0), sql_flag(truthy(arg(1)))],
      )
      if n > 0 {
        self.changed_store([session_changed(key)])
      }
      Some(jbool(n > 0))
    }
    "forgetWait" => {
      let n = db.run(
        "UPDATE turns SET declared = NULL, wait_seconds = NULL WHERE id = (SELECT id FROM turns WHERE session_key = ?1 ORDER BY started_at DESC LIMIT 1) AND declared = 'waiting' AND ended_at IS NOT NULL AND outcome <> 'completed'",
        [arg(0)],
      )
      if n > 0 {
        self.changed_store([session_changed(key)])
      }
      Some(Json::null())
    }
    _ => None
  }
}
