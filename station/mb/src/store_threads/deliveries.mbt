// Letters, deliveries and a viewer's marks (store.ts `// ── letters ──` … `unkeepChat`): a letter kept in a chat's own
// log and handed over, a message handed to sessions (a Router's within its workspace), what a session has yet to read,
// read positions, hidden and muted chats, pins, where a connect's threads run, and the chats kept from archiving.

///|
pub fn Store::insert_letter(self : Store, l : @jsjson.JValue) -> Json raise {
  self.with_(changes => {
    let thread = jnullish(jget(l, "thread"))
    let at = self.now_json()
    let mut n = 0.0
    self.tx(() => {
      n = num(
          match self.one("SELECT MAX(n) AS n FROM letters WHERE thread = ?", [thread]) {
            Some(r) => col(r, "n")
            None => Json::null()
          },
        ) +
        1.0
      ignore(
        self.run("INSERT INTO letters (thread, n, ts, author_kind, author, text, attachments, at, letter) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", [
          thread,
          jnum(n),
          jnullish(jget(l, "ts")),
          jnullish(jget(l, "authorKind")),
          jnullish(jget(l, "author")),
          jnullish(jget(l, "text")),
          json_list(jlist(jget(l, "attachments")), attachment),
          at,
          match jget(l, "letter") {
            Some(v) => jstr(stringify(v))
            None => Json::null()
          },
        ]),
      )
    })
    let row = self.one("SELECT * FROM letters WHERE thread = ? AND n = ?", [thread, jnum(n)]).unwrap()
    let entry = letter_entry_of(row)
    changes.push({ "type": "letters", "id": thread, "letters": [entry] })
    self.bring_back("message", author_kind_of(col(row, "author_kind")), text_of(col(row, "author")).unwrap_or(""), thread, changes)
    jnum(n)
  })
}

///|
fn Store::last_letter_n(self : Store, thread : Json) -> Double raise {
  match self.one("SELECT MAX(n) AS n FROM letters WHERE thread = ?", [thread]) {
    Some(r) => num(col(r, "n"))
    None => 0.0
  }
}

///|
pub fn Store::last_letter(self : Store, thread : Json) -> Json raise {
  jnum(self.last_letter_n(thread))
}

///|
fn strings(v : Json) -> Array[Json] {
  match v {
    Array(xs) => xs
    _ => []
  }
}

///|
pub fn Store::deliver_letter(self : Store, thread : Json, n : Json, sessions : Json) -> Json raise {
  self.with_(changes => {
    let added = []
    for s in strings(sessions) {
      if self.run("INSERT OR IGNORE INTO letter_deliveries (thread, n, session) VALUES (?, ?, ?)", [thread, n, s]) > 0 {
        added.push(s)
        changes.push({ "type": "session", "key": s })
      }
    }
    Json::array(added)
  })
}

///|
pub fn Store::deliver(self : Store, thread : Json, n : Json, sessions : Json, workspace : Json) -> Json raise {
  self.with_(changes => {
    let mut waited : Json? = None
    let insert = (sql : String, args : Array[Json]) => {
      guard self.one(sql, args) is Some(r) else { return false }
      if waited is None {
        waited = Some(col(r, "waited"))
      }
      true
    }
    let settled = () => {
      guard waited is Some(Number(w, ..)) && w < num(n) else { return }
      match
        self.one("SELECT author, ts FROM entries WHERE thread = ? AND n = ? AND kind = 'message' AND author_kind = 'person'", [
          thread, n,
        ]) {
        Some(by) =>
          changes.push({
            "type": "thread",
            "id": thread,
            "entries": [],
            "answered": {
              "n": n,
              "author": col(by, "author"),
              "ts": match col(by, "ts") {
                Null => jstr("")
                t => t
              },
            },
          })
        None => ()
      }
    }
    guard workspace is Object(ws) else {
      let added = []
      for s in strings(sessions) {
        if insert(delivery_insert_if_absent_sql, [thread, n, s]) {
          added.push(s)
          changes.push({ "type": "session", "key": s })
        }
      }
      if !added.is_empty() {
        settled()
      }
      return Json::array(added)
    }
    let expected = ws.get("expected").unwrap_or(Json::null())
    let fallback = ws.get("fallback").unwrap_or(Json::null())
    let added = self.tx(
      () => {
        if self.one("SELECT 1 FROM thread_sessions WHERE thread = ? LIMIT 1", [thread]) is None ||
          self.one(router_workspace_mismatch_sql, [thread, fallback, expected]) is Some(_) {
          raise StoreError("no such chat of the workspace")
        }
        let added = []
        for s in strings(sessions) {
          if insert(delivery_insert_if_member_sql, [thread, n, s, jstr(manual)]) {
            added.push(s)
          }
        }
        added
      },
      try_write=true,
    )
    for s in added {
      changes.push({ "type": "session", "key": s })
    }
    if !added.is_empty() {
      settled()
    }
    Json::array(added)
  })
}

///|
pub fn Store::delivery_pending(self : Store, thread : Json, n : Json, session : Json) -> Json raise {
  jbool(
    self.one("SELECT 1 FROM deliveries WHERE thread = ? AND n = ? AND session = ? AND delivered_at IS NULL", [thread, n, session])
    is Some(_),
  )
}

///|
pub fn Store::complete_router_write(self : Store, id : Json) -> Json raise {
  self.tx(
    () => {
      let changed = self.run("UPDATE comma_router_once SET pending = 0 WHERE id = ? AND pending = 1", [id])
      if changed > 0 {
        ignore(self.run("DELETE FROM comma_router_once_targets WHERE id = ?", [id]))
      }
      jbool(changed > 0 || self.one("SELECT 1 FROM comma_router_once WHERE id = ? AND pending = 0", [id]) is Some(_))
    },
    try_write=true,
  )
}

///|
fn pending_of(r : Map[String, Json], message : Json) -> Json {
  {
    "message": message,
    "surface": col(r, "surface"),
    "channel": col(r, "channel"),
    "threadTs": col(r, "thread_ts"),
    "connect": col(r, "connect"),
  }
}

///|
fn created_at(p : Json) -> Double {
  match p {
    Object(o) =>
      match o.get("message") {
        Some(Object(m)) => num(m.get("createdAt").unwrap_or(Json::null()))
        _ => 0.0
      }
    _ => 0.0
  }
}

///|
pub fn Store::pending_messages(self : Store, session : Json) -> Json raise {
  let said = self
    .all(
      "SELECT m.*, t.surface, t.channel, t.thread_ts, ts.connect FROM deliveries d\n       JOIN merged m ON m.thread = d.thread AND m.n = d.n JOIN threads t ON t.id = d.thread\n       JOIN thread_sessions ts ON ts.thread = t.id AND ts.session = d.session\n       WHERE d.session = ? AND d.delivered_at IS NULL ORDER BY d.rowid",
      [session],
    )
    .map(r => pending_of(r, message_of(r)))
  let letters = self
    .all(
      "SELECT l.*, t.surface, t.channel, t.thread_ts, ts.connect FROM letter_deliveries d\n       JOIN letters l ON l.thread = d.thread AND l.n = d.n JOIN threads t ON t.id = d.thread\n       JOIN thread_sessions ts ON ts.thread = t.id AND ts.session = d.session\n       WHERE d.session = ? AND d.delivered_at IS NULL ORDER BY d.rowid",
      [session],
    )
    .map(r => pending_of(r, letter_message_of(r)))
  if letters.is_empty() {
    return Json::array(said)
  }
  if said.is_empty() {
    return Json::array(letters)
  }
  let out = []
  let mut i = 0
  let mut j = 0
  while i < said.length() || j < letters.length() {
    if j >= letters.length() || (i < said.length() && created_at(said[i]) <= created_at(letters[j])) {
      out.push(said[i])
      i += 1
    } else {
      out.push(letters[j])
      j += 1
    }
  }
  Json::array(out)
}

///|
pub fn Store::pending_before(self : Store, session : Json, thread : Json, n : Json) -> Json raise {
  Json::array(
    self
    .all(
      "SELECT m.ts FROM deliveries d INDEXED BY deliveries_pending\n      JOIN entries m ON m.thread = d.thread AND m.n = d.n AND m.kind = 'message'\n      JOIN threads t ON t.id = d.thread\n      JOIN thread_sessions ts ON ts.thread = t.id AND ts.session = d.session\n      WHERE d.session = ? AND d.delivered_at IS NULL AND d.thread = ? AND d.n < ? ORDER BY d.rowid",
      [session, thread, n],
    )
    .map(r => match col(r, "ts") {
      Null => jstr("")
      t => t
    }),
  )
}

///|
pub fn Store::pending_count(self : Store, session : Json) -> Json raise {
  col(self.one(pending_count_sql, [session]).unwrap(), "n")
}

///|
fn Store::has_pending_of(self : Store, session : Json) -> Bool raise {
  self.one(has_pending_message_sql, [session]) is Some(_) || self.one(has_pending_letter_sql, [session]) is Some(_)
}

///|
pub fn Store::has_pending(self : Store, session : Json) -> Json raise {
  jbool(self.has_pending_of(session))
}

///|
pub fn Store::has_undelivered(self : Store, session : Json) -> Json raise {
  jbool(
    self.one("SELECT 1 FROM deliveries INDEXED BY deliveries_pending WHERE session = ? AND delivered_at IS NULL LIMIT 1", [session])
    is Some(_) ||
    self.one(
      "SELECT 1 FROM letter_deliveries INDEXED BY letter_deliveries_pending WHERE session = ? AND delivered_at IS NULL LIMIT 1",
      [session],
    )
    is Some(_),
  )
}

///|
fn handed(v : Json) -> (Json, Json, Bool) {
  match v {
    Object(o) =>
      (
        o.get("thread").unwrap_or(Json::null()),
        o.get("n").unwrap_or(Json::null()),
        match o.get("apart") {
          None | Some(Null) | Some(False) | Some(Number(0.0, ..)) => false
          Some(String(s)) => !s.is_empty()
          _ => true
        },
      )
    _ => (Json::null(), Json::null(), false)
  }
}

///|
pub fn Store::mark_delivered(self : Store, session : Json, messages : Json) -> Json raise {
  self.with_(changes => {
    let now = self.now_json()
    let mut marked = 0
    let list = strings(messages)
    for m in list {
      let (thread, n, apart) = handed(m)
      marked += self.run(
        "UPDATE \{if apart { "letter_deliveries" } else { "deliveries" }} SET delivered_at = ? WHERE thread = ? AND n = ? AND session = ? AND delivered_at IS NULL",
        [now, thread, n, session],
      )
    }
    if !list.is_empty() {
      let pending = match
        self.one(
          "SELECT (SELECT COUNT(*) FROM deliveries INDEXED BY deliveries_pending WHERE session = ?1 AND delivered_at IS NULL) + (SELECT COUNT(*) FROM letter_deliveries WHERE session = ?1 AND delivered_at IS NULL) AS n",
          [session],
        ) {
        Some(r) => num(col(r, "n"))
        None => 0.0
      }
      changes.push({ "type": "session", "key": session, "pending": jnum(pending) })
    }
    jint(marked)
  })
}

///|
pub fn Store::mark_undelivered(self : Store, session : Json, messages : Json) -> Json raise {
  self.with_(changes => {
    let list = strings(messages)
    for m in list {
      let (thread, n, apart) = handed(m)
      ignore(
        self.run(
          "UPDATE \{if apart { "letter_deliveries" } else { "deliveries" }} SET delivered_at = NULL WHERE thread = ? AND n = ? AND session = ?",
          [thread, n, session],
        ),
      )
    }
    if !list.is_empty() {
      changes.push({ "type": "session", "key": session })
    }
    undefined
  })
}

///|
pub fn Store::heard_threads(self : Store, session : Json, threads : Json) -> Json raise {
  let unique : Array[Json] = []
  for t in strings(threads) {
    if !unique.contains(t) {
      unique.push(t)
    }
  }
  let out = []
  for t in unique {
    if self.one(heard_in_sql, [session, t]) is Some(_) {
      out.push(t)
    }
  }
  Json::array(out)
}

///|
pub fn Store::sessions_with_pending(self : Store) -> Json raise {
  Json::array(self.all(pending_sessions_sql, []).map(r => col(r, "session")))
}

///|
pub fn Store::returning_sessions_in(self : Store, ws : Json) -> Json raise {
  self.snapshot("returning_workspace", () => {
    let ready = match self.one("SELECT complete FROM workspace_activity_meta WHERE id = 1", []) {
      Some(r) => is_num(col(r, "complete"), 1.0)
      None => raise StoreError("Cannot read properties of undefined (reading 'complete')")
    }
    if !ready {
      return Json::null()
    }
    let rows = []
    for r in self.all(workspace_activity_sql, [ws]) {
      if is_num(col(r, "running"), 1.0) || self.has_pending_of(col(r, "key")) {
        rows.push(r)
      }
    }
    let sorted = stable_sort(rows, (a, b) => {
      let d = num(col(b, "last_active_at")) - num(col(a, "last_active_at"))
      if d > 0.0 {
        1
      } else if d < 0.0 {
        -1
      } else {
        0
      }
    })
    Json::array(sorted.map(session_of))
  })
}

///|
pub fn Store::starter(self : Store, key : Json) -> Json raise {
  let by = match self.one("SELECT * FROM sessions WHERE key = ?", [key]) {
    Some(s) if !(col(s, "created_by") is Null) => Some(col(s, "created_by"))
    _ => {
      let parts = self.participants_of(Some(key))
      match parts.search_by(p => Json::string(p.0) == key) {
        Some(i) if parts[i].1.length() > 0 => Some(jstr(parts[i].1[0]))
        _ => None
      }
    }
  }
  match by {
    Some(String(s)) if !s.is_empty() => jstr(@jscase.lower(s))
    _ => Json::null()
  }
}

///|
/// store.ts `participants`: each session's people, earliest first, by session in byte order.
fn Store::participants_of(self : Store, session : Json?) -> Array[(String, Array[String])] raise {
  let sql = "SELECT ts.session, ts.connect, t.id, t.surface FROM thread_sessions ts JOIN threads t ON t.id = ts.thread \{if session is Some(_) { "WHERE ts.session = ?" } else { "" }}"
  let rows = match session {
    Some(s) => self.all(sql, [s])
    None => self.all(sql, [])
  }
  let firsts : Array[(String, Array[(String, Double)])] = []
  for r in rows {
    let key = text_of(col(r, "session")).unwrap_or("")
    let authors = self.all(people_at_sql, [col(r, "id")])
    let refs = match firsts.search_by(f => f.0 == key) {
      Some(i) => firsts[i].1
      None => {
        let refs = []
        firsts.push((key, refs))
        refs
      }
    }
    for a in authors {
      let author = text_of(col(a, "author")).unwrap_or("")
      let at = num(col(a, "at"))
      let reference = if col(r, "surface") == jstr(stillfail_surface) {
        author
      } else {
        "slack:\{js_text(col(r, "connect"))}:\{author}"
      }
      match refs.search_by(x => x.0 == reference) {
        Some(i) => if at < refs[i].1 { refs[i] = (reference, at) }
        None => refs.push((reference, at))
      }
    }
  }
  let by_bytes = (a : String, b : String) => utf8_compare(@jsjson.units(a), @jsjson.units(b))
  let out = []
  for f in stable_sort(firsts, (a, b) => by_bytes(a.0, b.0)) {
    if f.1.is_empty() {
      continue
    }
    let sorted = stable_sort(stable_sort(f.1, (a, b) => by_bytes(a.0, b.0)), (a, b) => {
      let d = a.1 - b.1
      if d > 0.0 {
        1
      } else if d < 0.0 {
        -1
      } else {
        0
      }
    })
    out.push((f.0, sorted.map(x => x.0)))
  }
  out
}

///|
/// Two strings by their UTF-8 bytes (rows.ts `byBytes`), from their UTF-16 code units.
fn utf8_compare(a : Array[Int], b : Array[Int]) -> Int {
  let ea = utf8_of(a)
  let eb = utf8_of(b)
  let n = if ea.length() < eb.length() { ea.length() } else { eb.length() }
  for i in 0..<n {
    if ea[i] != eb[i] {
      return if ea[i] < eb[i] { -1 } else { 1 }
    }
  }
  ea.length() - eb.length()
}

///|
fn utf8_of(units : Array[Int]) -> Array[Int] {
  let b = @jsjson.utf8(@jsjson.raw_text(units))
  Array::makei(b.length(), i => b[i].to_int())
}

///|
pub fn Store::participants(self : Store, session : Json) -> Json raise {
  let out : Map[String, Json] = Map([])
  for p in self.participants_of(if session is Null { None } else { Some(session) }) {
    out[p.0] = Json::array(p.1.map(jstr))
  }
  Json::object(out)
}

// ── reads ──

///|
pub fn Store::read_position(self : Store, viewer : Json, thread : Json) -> Json raise {
  match self.one("SELECT n FROM reads WHERE viewer = ? AND thread = ?", [viewer, thread]) {
    Some(r) if !(col(r, "n") is Null) => col(r, "n")
    _ => jint(0)
  }
}

///|
pub fn Store::set_read(self : Store, viewer : Json, thread : Json, n : Json) -> Json raise {
  self.with_(changes => {
    ignore(
      self.run(
        "INSERT INTO reads (viewer, thread, n, at) VALUES (?, ?, ?, ?)\n         ON CONFLICT (viewer, thread) DO UPDATE SET n = MAX(n, excluded.n), at = excluded.at",
        [viewer, thread, n, self.now_json()],
      ),
    )
    let now = self.read_position(viewer, thread)
    changes.push({ "type": "read", "viewer": viewer, "thread": thread, "n": now })
    now
  })
}

///|
pub fn Store::set_chat_hidden(self : Store, viewer : Json, thread : Json, hidden : Json) -> Json raise {
  self.with_(changes => {
    if hidden is True {
      ignore(self.run("INSERT OR IGNORE INTO hidden_chats (viewer, thread) VALUES (?, ?)", [viewer, thread]))
    } else {
      ignore(self.run("DELETE FROM hidden_chats WHERE viewer = ? AND thread = ?", [viewer, thread]))
    }
    changes.push({ "type": "hidden", "viewer": viewer, "thread": thread, "hidden": hidden })
    undefined
  })
}

///|
pub fn Store::set_chat_muted(self : Store, viewer : Json, thread : Json, muted : Json) -> Json raise {
  self.with_(changes => {
    let email = jstr(@jscase.lower(text_of(viewer).unwrap_or("")))
    if muted is True {
      ignore(self.run("INSERT OR IGNORE INTO muted_chats (viewer, thread) VALUES (?, ?)", [email, thread]))
    } else {
      ignore(self.run("DELETE FROM muted_chats WHERE viewer = ? AND thread = ?", [email, thread]))
    }
    changes.push({ "type": "muted", "viewer": viewer, "thread": thread, "muted": muted })
    undefined
  })
}

// ── pins ──

///|
pub fn Store::pins(self : Store, viewer : Json) -> Json raise {
  let out : Map[String, Json] = Map([])
  for r in self.all("SELECT session, at FROM pins WHERE viewer = ?", [viewer]) {
    out[js_text(col(r, "session"))] = col(r, "at")
  }
  Json::object(out)
}

///|
pub fn Store::pinned_sessions(self : Store) -> Json raise {
  Json::array(self.all("SELECT DISTINCT session FROM pins", []).map(r => col(r, "session")))
}

///|
/// archive-mark-index.ts `archiveMarksReady`.
fn archive_marks_ready(db : @sql.Db) -> Bool raise {
  let rows = db.all(
    "SELECT kind, version, CAST(last_rowid AS TEXT) AS last_rowid,\n    CAST(end_rowid AS TEXT) AS end_rowid, complete FROM archive_mark_meta ORDER BY kind",
    [],
  )
  guard rows.length() == 2 && col(rows[0], "kind") == jstr("kept") && col(rows[1], "kind") == jstr("pins") else {
    raise StoreError("archive mark index version marker is missing")
  }
  for r in rows {
    if !is_num(col(r, "version"), 1.0) {
      raise StoreError("archive mark index version \{col(r, "version").stringify()} is incompatible with 1")
    }
  }
  rows.iter().all(r => is_num(col(r, "complete"), 1.0))
}

///|
/// store.ts `archiveMarks`, asked of the sessions and threads given: whether each is pinned and kept.
pub fn Store::archive_marks(self : Store, sessions : Json, threads : Json) -> Json raise {
  let ready = archive_marks_ready(self.db)
  let pinned : Map[String, Json] = Map([])
  for s in strings(sessions) {
    pinned[js_text(s)] = jbool(!ready || self.one(archive_pin_exists_sql, [s]) is Some(_))
  }
  let kept : Map[String, Json] = Map([])
  for t in strings(threads) {
    kept[js_text(t)] = jbool(!ready || self.one(archive_keep_exists_sql, [t]) is Some(_))
  }
  { "pinned": Json::object(pinned), "kept": Json::object(kept) }
}

///|
pub fn Store::set_pin(self : Store, viewer : Json, session : Json, pinned : Json) -> Json raise {
  self.with_(changes => {
    if pinned is True {
      ignore(self.run("INSERT OR IGNORE INTO pins (viewer, session, at) VALUES (?, ?, ?)", [viewer, session, self.now_json()]))
    } else {
      ignore(self.run("DELETE FROM pins WHERE viewer = ? AND session = ?", [viewer, session]))
    }
    let at = if pinned is True {
      match self.one("SELECT at FROM pins WHERE viewer = ? AND session = ?", [viewer, session]) {
        Some(r) => col(r, "at")
        None => Json::null()
      }
    } else {
      Json::null()
    }
    changes.push({ "type": "pins", "viewer": viewer, "session": session, "at": at })
    undefined
  })
}

///|
pub fn Store::relayed_to(self : Store, connect : Json) -> Json raise {
  let out : Map[String, Json] = Map([])
  for r in self.all("SELECT channel, at FROM relayed_to WHERE connect = ?", [connect]) {
    out[js_text(col(r, "channel"))] = col(r, "at")
  }
  Json::object(out)
}

///|
pub fn Store::note_relayed(self : Store, connect : Json, channel : Json) -> Json raise {
  ignore(
    self.run("INSERT INTO relayed_to (connect, channel, at) VALUES (?1, ?2, ?3) ON CONFLICT (connect, channel) DO UPDATE SET at = ?3", [
      connect,
      channel,
      self.now_json(),
    ]),
  )
  undefined
}

///|
pub fn Store::connect_thread_station(self : Store, connect : Json, channel : Json, thread_ts : Json) -> Json raise {
  match self.one("SELECT station FROM connect_threads WHERE connect = ? AND channel = ? AND thread_ts = ?", [connect, channel, thread_ts]) {
    Some(r) => col(r, "station")
    None => Json::null()
  }
}

///|
pub fn Store::set_connect_thread_station(self : Store, connect : Json, channel : Json, thread_ts : Json, station : Json) -> Json raise {
  ignore(
    self.run(
      "INSERT INTO connect_threads (connect, channel, thread_ts, station) VALUES (?1, ?2, ?3, ?4) ON CONFLICT (connect, channel, thread_ts) DO UPDATE SET station = ?4",
      [connect, channel, thread_ts, station],
    ),
  )
  undefined
}

///|
pub fn Store::connect_threads(self : Store, connect : Json) -> Json raise {
  Json::array(
    self
    .all("SELECT channel, thread_ts, station FROM connect_threads WHERE connect = ?", [connect])
    .map(r => ({ "channel": col(r, "channel"), "threadTs": col(r, "thread_ts"), "station": col(r, "station") } : Json)),
  )
}

///|
pub fn Store::drop_connect_threads(self : Store, connect : Json) -> Json raise {
  ignore(self.run("DELETE FROM connect_threads WHERE connect = ?", [connect]))
  undefined
}

///|
pub fn Store::connect_local_threads(self : Store, connect : Json) -> Json raise {
  Json::array(
    self
    .all("SELECT DISTINCT t.channel, t.thread_ts FROM thread_sessions s JOIN threads t ON t.id = s.thread WHERE s.connect = ?", [connect])
    .map(r => ({ "channel": col(r, "channel"), "threadTs": col(r, "thread_ts") } : Json)),
  )
}

///|
pub fn Store::kept_chats(self : Store, viewer : Json) -> Json raise {
  let rows = if viewer is Null {
    self.all("SELECT DISTINCT thread FROM kept_chats", [])
  } else {
    self.all("SELECT thread FROM kept_chats WHERE viewer = ?1", [viewer])
  }
  let out : Array[Json] = []
  for r in rows {
    if !out.contains(col(r, "thread")) {
      out.push(col(r, "thread"))
    }
  }
  Json::array(out)
}

///|
pub fn Store::keep_chat(self : Store, viewer : Json, thread : Json) -> Json raise {
  self.with_(changes => {
    ignore(self.run("INSERT OR IGNORE INTO kept_chats (viewer, thread) VALUES (?, ?)", [viewer, thread]))
    changes.push({ "type": "dismissed", "viewer": viewer, "kept": { "thread": thread, "kept": true } })
    undefined
  })
}

///|
pub fn Store::unkeep_chat(self : Store, viewer : Json, thread : Json) -> Json raise {
  self.with_(changes => {
    ignore(self.run("DELETE FROM kept_chats WHERE viewer = ? AND thread = ?", [viewer, thread]))
    changes.push({ "type": "dismissed", "viewer": viewer, "kept": { "thread": thread, "kept": false } })
    undefined
  })
}
