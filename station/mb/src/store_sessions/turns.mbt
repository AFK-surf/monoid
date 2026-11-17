// A session's turns (store.ts `// ── turns ──`): begun for someone, what they say they end in, ended, read back; and
// the Slack users a viewer said are them (`// ── identities ──`).

///|
pub fn Store::slack_identities(
  self : Store,
  viewer : Json,
) -> Array[Json] raise {
  self
  .all("SELECT slack_user FROM identities WHERE viewer = ? ORDER BY at", [
    viewer,
  ])
  .map(r => col(r, "slack_user"))
}

///|
pub fn Store::set_slack_identity(
  self : Store,
  viewer : Json,
  user : Json,
  bound : Bool,
) -> Unit raise {
  self.with_changes(changes => {
    if bound {
      ignore(
        self.run(
          "INSERT OR IGNORE INTO identities (viewer, slack_user, at) VALUES (?, ?, ?)",
          [viewer, user, self.now_json()],
        ),
      )
    } else {
      ignore(
        self.run("DELETE FROM identities WHERE viewer = ? AND slack_user = ?", [
          viewer, user,
        ]),
      )
    }
    changes.push({ "type": "identities", "viewer": viewer })
  })
}

///|
pub fn Store::has_turns(self : Store, session : Json) -> Bool raise {
  match
    self.one("SELECT EXISTS (SELECT 1 FROM turns WHERE session_key = ?) AS e", [
      session,
    ]) {
    Some(r) => !is_n(col(r, "e"), 0.0)
    None => false
  }
}

///|
pub fn Store::start_turn(
  self : Store,
  id : Json,
  session : Json,
  kind : Json,
) -> Unit raise {
  self.start_turn_for(id, session, kind, {
    "profile": Json::null(),
    "person": Json::null(),
    "thread": Json::null(),
  })
}

///|
/// Starts a turn for someone (rows.ts TurnFor: `{profile, person, thread}`); one nobody's message started goes on with
/// the work of the one before it.
pub fn Store::start_turn_for(
  self : Store,
  id : Json,
  session : Json,
  kind : Json,
  by : Json,
) -> Unit raise {
  self.with_changes(changes => {
    let before = (column : String) => {
      "(SELECT \{column} FROM turns WHERE session_key = ?2 ORDER BY started_at DESC LIMIT 1)"
    }
    ignore(
      self.run(
        "INSERT INTO turns (id, session_key, kind, started_at, profile, person, thread) VALUES (?1, ?2, ?3, ?4, ?5, COALESCE(?6, \{before("person")}), COALESCE(?7, \{before("thread")}))",
        [
          id,
          session,
          kind,
          self.now_json(),
          nullish(field(by, "profile")),
          nullish(field(by, "person")),
          nullish(field(by, "thread")),
        ],
      ),
    )
    changes.push(session_change(session))
  })
}

///|
pub fn Store::set_wait_for(
  self : Store,
  id : Json,
  what : Json,
  watch : Bool,
) -> Unit raise {
  ignore(
    self.run("UPDATE turns SET wait_for = ?, wait_watch = ? WHERE id = ?", [
      what,
      flag(watch),
      id,
    ]),
  )
}

///|
/// The message a turn's state is about (`[thread, n, ts]`), or none.
pub fn Store::set_about(self : Store, id : Json, about : Json) -> Unit raise {
  let (thread, n, ts) = match about {
    Array([t, n, ts, ..]) => (t, n, ts)
    _ => (Json::null(), Json::null(), Json::null())
  }
  ignore(
    self.run(
      "UPDATE turns SET about_thread = ?, about_n = ?, about_ts = ? WHERE id = ?",
      [thread, n, ts, id],
    ),
  )
}

///|
pub fn Store::told_notes(self : Store, key : Json) -> Json raise {
  match self.one("SELECT told_notes FROM sessions WHERE key = ?", [key]) {
    Some(r) => or_else(col(r, "told_notes"), jnum(0.0))
    None => jnum(0.0)
  }
}

///|
pub fn Store::set_told_notes(self : Store, key : Json, n : Json) -> Unit raise {
  ignore(self.run("UPDATE sessions SET told_notes = ? WHERE key = ?", [n, key]))
}

///|
pub fn Store::set_need(self : Store, id : Json, what : Json) -> Unit raise {
  ignore(self.run("UPDATE turns SET need = ? WHERE id = ?", [what, id]))
}

///|
pub fn Store::declare_turn(
  self : Store,
  id : Json,
  declared : Json,
  wait_seconds : Json,
) -> Unit raise {
  ignore(
    self.run(
      "UPDATE turns SET declared = ?, wait_seconds = ? WHERE id = ? AND ended_at IS NULL",
      [declared, wait_seconds, id],
    ),
  )
}

///|
/// Ends a turn; one that ends needing a person about a card closed while it ran needs nothing more: it ends final.
pub fn Store::end_turn(
  self : Store,
  id : Json,
  outcome : Json,
  detail : Json,
  declared : Json,
  wait_seconds : Json,
) -> Unit raise {
  self.with_changes(changes => {
    ignore(
      self.run(
        "UPDATE turns SET ended_at = ?, outcome = ?, detail = ?, declared = ?, wait_seconds = ? WHERE id = ?",
        [self.now_json(), outcome, detail, declared, wait_seconds, id],
      ),
    )
    ignore(
      self.run(
        (
          #|UPDATE turns SET declared = 'final', wait_seconds = NULL
          #|         WHERE id = ? AND declared IN ('block', 'need_help', 'need_human', 'need_decision') AND about_n IS NOT NULL
          #|           AND EXISTS (SELECT 1 FROM closed_cards c WHERE c.thread = turns.about_thread AND c.n = turns.about_n)
        ),
        [id],
      ),
    )
    if self.one("SELECT session_key FROM turns WHERE id = ?", [id]) is Some(r) {
      changes.push(session_change(col(r, "session_key")))
    }
  })
}

///|
/// The session's turns a restart cut off: ended as aborted now. How many it ended.
pub fn Store::end_cut_off(self : Store, session : Json) -> Int32 raise {
  self.with_changes(changes => {
    let now = self.now_json()
    let n = self.run(
      (
        #|UPDATE turns SET ended_at = ?2, outcome = 'aborted', detail = 'other: cut off by restart',
        #|           declared = CASE WHEN declared = 'waiting' THEN NULL ELSE declared END,
        #|           wait_seconds = CASE WHEN declared = 'waiting' THEN NULL ELSE wait_seconds END
        #|         WHERE session_key = ?1 AND ended_at IS NULL
      ),
      [session, now],
    )
    if n == 0 {
      return 0
    }
    ignore(
      self.run(
        (
          #|UPDATE turns SET declared = 'final', wait_seconds = NULL
          #|         WHERE session_key = ?1 AND ended_at = ?2 AND detail = 'other: cut off by restart'
          #|           AND declared IN ('block', 'need_help', 'need_human', 'need_decision') AND about_n IS NOT NULL
          #|           AND EXISTS (SELECT 1 FROM closed_cards c WHERE c.thread = turns.about_thread AND c.n = turns.about_n)
        ),
        [session, now],
      ),
    )
    changes.push(session_change(session))
    n
  })
}

///|
/// The session was stopped while it waited: its latest turn, if it ended waiting, recorded as stopped. Whether it was.
pub fn Store::stop_wait(
  self : Store,
  session : Json,
  refill : Bool,
) -> Bool raise {
  self.with_changes(changes => {
    let n = self.run(
      (
        #|UPDATE turns SET outcome = 'aborted', declared = NULL, wait_seconds = NULL, detail = 'other: stopped while waiting'
        #|         WHERE id = (SELECT id FROM turns WHERE session_key = ?1 ORDER BY started_at DESC, rowid DESC LIMIT 1) AND ended_at IS NOT NULL
        #|           AND (declared = 'waiting' OR (?2 AND outcome = 'failed' AND detail LIKE 'rate_limit:%'))
      ),
      [session, flag(refill)],
    )
    if n > 0 {
      changes.push(session_change(session))
    }
    n > 0
  })
}

///|
pub fn Store::forget_wait(self : Store, session : Json) -> Unit raise {
  self.with_changes(changes => {
    let n = self.run(
      (
        #|UPDATE turns SET declared = NULL, wait_seconds = NULL
        #|         WHERE id = (SELECT id FROM turns WHERE session_key = ?1 ORDER BY started_at DESC LIMIT 1) AND declared = 'waiting' AND ended_at IS NOT NULL
        #|           AND outcome <> 'completed'
      ),
      [session],
    )
    if n > 0 {
      changes.push(session_change(session))
    }
  })
}

///|
pub fn Store::latest_turn(self : Store, session : Json) -> Json raise {
  match
    self.one(
      "SELECT * FROM turns WHERE session_key = ? ORDER BY started_at DESC, rowid DESC LIMIT 1",
      [session],
    ) {
    Some(r) => to_turn_row(r)
    None => Json::null()
  }
}

///|
pub fn Store::last_turn(self : Store, session : Json) -> Json raise {
  match
    self.one(
      "SELECT * FROM turns WHERE session_key = ? ORDER BY started_at DESC, rowid DESC LIMIT 1",
      [session],
    ) {
    Some(r) => to_turn_summary(r)
    None => Json::null()
  }
}

///|
pub fn Store::slack_stop(
  self : Store,
  session : Json,
  connect : Json,
  channel : Json,
  thread_ts : Json,
) -> Json raise {
  match
    self.one(
      "SELECT event_ts, turn_id FROM slack_stops WHERE session = ? AND connect = ? AND channel = ? AND thread_ts = ?",
      [session, connect, channel, thread_ts],
    ) {
    Some(r) => { "ts": col(r, "event_ts"), "turn": col(r, "turn_id") }
    None => Json::null()
  }
}

///|
pub fn Store::remember_slack_stop(
  self : Store,
  session : Json,
  connect : Json,
  channel : Json,
  thread_ts : Json,
  ts : Json,
  turn : Json,
) -> Unit raise {
  ignore(
    self.run(
      "INSERT INTO slack_stops (session, connect, channel, thread_ts, event_ts, turn_id) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (session, connect, channel, thread_ts) DO UPDATE SET event_ts = excluded.event_ts, turn_id = excluded.turn_id",
      [session, connect, channel, thread_ts, ts, turn],
    ),
  )
}

///|
pub fn Store::list_turns(self : Store, session : Json) -> Array[Json] raise {
  self
  .all("SELECT * FROM turns WHERE session_key = ? ORDER BY started_at", [
    session,
  ])
  .map(to_turn_row)
}

///|
pub fn Store::failed_turns_near(
  self : Store,
  session : Json,
  from : Json,
  to : Json,
  at : Json,
) -> Array[Json] raise {
  self.all(failed_turn_near, [session, from, to, at]).map(to_turn_row)
}

///|
/// The distinct of `keys`, in order (`new Set(keys)`).
fn distinct(keys : Array[String]) -> Array[String] {
  let out = []
  for k in keys {
    if !out.contains(k) {
      out.push(k)
    }
  }
  out
}

///|
/// Latest turns for the named sessions (a Map's entries): a missing session left out.
pub fn Store::last_turns_of(self : Store, keys : Array[String]) -> Json raise {
  let out = []
  for key in distinct(keys) {
    if self.one(last_turn_of_session, [jstr(key)]) is Some(r) {
      out.push(
        (
          key,
          if col(r, "started_at") is Null {
            Json::null()
          } else {
            to_turn_summary(r)
          },
        ),
      )
    }
  }
  entries(out)
}

///|
pub fn Store::waiting_for_people(
  self : Store,
  since : Json,
  limit : Json,
) -> Array[Json] raise {
  self
  .all(waiting_for_people, [since, limit])
  .map(r => {
    "key": col(r, "key"),
    "title": col(r, "title"),
    "need": col(r, "need"),
    "endedAt": col(r, "ended_at"),
  })
}

///|
pub fn Store::work_of(self : Store, key : Json) -> Json raise {
  work_of_row(self.one(work_of_session, [key]))
}

///|
pub fn Store::stats_of(self : Store, keys : Array[String]) -> Json raise {
  let out : Array[(String, Json)] = []
  for key in distinct(keys) {
    if self.one(stats_of, [jstr(key)]) is Some(r) {
      out.push(
        (
          key,
          {
            "pending": col(r, "pending"),
            "lastTurn": if col(r, "started_at") is Null {
              Json::null()
            } else {
              to_turn_summary(r)
            },
          },
        ),
      )
    }
  }
  entries(out)
}

///|
/// Per session (or for one): turn count, how long its ended turns ran, the latest turn, undelivered messages and the
/// first one it heard (a Map's entries, by UTF-8 order).
pub fn Store::session_stats(self : Store, key : Json) -> Json raise {
  let sql = (
      #|SELECT s.key,
      #|         (SELECT COUNT(*) FROM turns t WHERE t.session_key = s.key) AS turns,
      #|         (SELECT COALESCE(SUM(t.ended_at - t.started_at), 0) FROM turns t WHERE t.session_key = s.key AND t.ended_at > t.started_at) AS work_ms,
      #|         ((SELECT COUNT(*) FROM deliveries d WHERE d.session = s.key AND d.delivered_at IS NULL) +
      #|         (SELECT COUNT(*) FROM letter_deliveries d WHERE d.session = s.key AND d.delivered_at IS NULL)) AS pending,
      #|         (SELECT substr(m.text, 1, 300) FROM session_first f JOIN merged m ON m.thread = f.thread AND m.n = f.n WHERE f.session = s.key) AS first_text,
      #|         l.kind, l.outcome, l.declared, l.wait_seconds, l.wait_for, l.wait_watch, l.need, l.about_thread, l.about_n, l.about_ts, l.detail, l.started_at, l.ended_at
      #|       FROM sessions s
      #|       LEFT JOIN turns l ON l.id = (SELECT id FROM turns t2 WHERE t2.session_key = s.key ORDER BY t2.started_at DESC LIMIT 1)
      #|
    ) +
    (if key is Null { "" } else { "WHERE s.key = ?" })
  let rows = if key is Null { self.all(sql, []) } else { self.all(sql, [key]) }
  let out : Array[(String, Json)] = rows.map(r => {
    (
      js_string(col(r, "key")),
      {
        "turns": col(r, "turns"),
        "workMs": col(r, "work_ms"),
        "pending": col(r, "pending"),
        "firstText": col(r, "first_text"),
        "lastTurn": if col(r, "started_at") is Null {
          Json::null()
        } else {
          to_turn_summary(r)
        },
      },
    )
  })
  out.sort_by((a, b) => by_bytes(a.0, b.0))
  entries(out)
}
