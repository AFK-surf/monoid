// Threads and who takes part in them (store.ts `// ── threads ──`: getThread … searchChatList), and the reads of a
// thread's people, words and counts they are made of (`#threadPeople`, `firstText`, `#lastSaid`, `#letterCount`,
// `#unreadCount`).

///|
/// What a method gives back as undefined (JavaScript's, which JSON cannot say).
let undefined : Json = { "$undefined": true }

///|
fn opt_row(r : Map[String, Json]?, f : (Map[String, Json]) -> Json) -> Json {
  match r {
    Some(r) => f(r)
    None => Json::null()
  }
}

///|
pub fn Store::get_thread(self : Store, id : Json) -> Json raise {
  opt_row(self.one("SELECT * FROM threads WHERE id = ?", [id]), thread_of)
}

///|
pub fn Store::thread_at(self : Store, surface : Json, channel : Json, thread_ts : Json) -> Json raise {
  let surface = own_name(surface)
  opt_row(self.one("SELECT * FROM threads WHERE surface = ? AND channel = ? AND thread_ts = ?", [surface, channel, thread_ts]), thread_of)
}

///|
pub fn Store::threads_at(self : Store, channel : Json, thread_ts : Json) -> Json raise {
  Json::array(self.all("SELECT * FROM threads WHERE channel = ? AND thread_ts = ? ORDER BY id", [channel, thread_ts]).map(thread_of))
}

///|
pub fn Store::open_thread(self : Store, surface : Json, channel : Json, thread_ts : Json, title : Json, created_by : Json) -> Json raise {
  self.open_thread_of(surface, channel, thread_ts, title, created_by, Json::null())
}

///|
pub fn Store::open_thread_of(
  self : Store,
  surface : Json,
  channel : Json,
  thread_ts : Json,
  title : Json,
  created_by : Json,
  home : Json,
) -> Json raise {
  let surface = own_name(surface)
  ignore(self.run(thread_insert_if_absent_sql, [surface, channel, thread_ts, title, created_by, self.now_json(), home]))
  let thread = self.thread_at(surface, channel, thread_ts)
  if thread is Null {
    let s = (v : Json) => match v {
      String(s) => s
      Null => "null"
      v => v.stringify()
    }
    raise StoreError("thread \{s(surface)} \{s(channel)}/\{s(thread_ts)} not made")
  }
  thread
}

///|
pub fn Store::thread_of_message(self : Store, surface : Json, channel : Json, ts : Json) -> Json raise {
  let surface = own_name(surface)
  match
    self.one(
      "SELECT t.* FROM entries e JOIN threads t ON t.id = e.thread WHERE t.surface = ? AND t.channel = ? AND e.ts = ? LIMIT 1",
      [surface, channel, ts],
    ) {
    Some(r) => thread_of(r)
    None => self.thread_at(surface, channel, ts)
  }
}

///|
pub fn Store::join_thread(self : Store, thread : Json, session : Json, connect : Json) -> Json raise {
  let connect = own_name(connect)
  self.with_(changes => {
    if self.one("SELECT 1 FROM thread_sessions WHERE thread = ? AND session = ? AND left_at IS NULL", [thread, session]) is Some(_) {
      jbool(false)
    } else {
      let now = self.now_json()
      let s_scope = match self.one("SELECT scope FROM sessions WHERE key = ?", [session]) {
        Some(r) => text_of(r.get("scope").unwrap_or(Json::null())).unwrap_or("")
        None => ""
      }
      let sk = text_of(session).unwrap_or("")
      let is_birth_candidate = if s_scope == "thread" {
        match self.one("SELECT channel, thread_ts FROM threads WHERE id = ?", [thread]) {
          Some(t) => {
            let ch = text_of(t.get("channel").unwrap_or(Json::null())).unwrap_or("")
            let ts = text_of(t.get("thread_ts").unwrap_or(Json::null())).unwrap_or("")
            ch != "" && ts != "" && sk.has_suffix(":\{ch}:\{ts}")
          }
          None => false
        }
      } else {
        false
      }
      if !is_birth_candidate {
        let joined = self.run(member_join_if_needed_sql, [thread, session, connect, now]) > 0
        if joined {
          changes.push({ "type": "session", "key": session })
          changes.push({ "type": "thread", "id": thread, "entries": [] })
        }
        jbool(joined)
      } else {
        let mut joined = false
        let mut settled_sessions : Array[String] = []
        let mut settled_threads : Array[Json] = []
        self.tx(() => {
          let is_born = self.one("SELECT 1 FROM thread_sessions WHERE session = ? LIMIT 1", [session]) is None &&
            self.one("SELECT 1 FROM turns WHERE session_key = ? LIMIT 1", [session]) is None &&
            self.one("SELECT 1 FROM chat_shares WHERE session = ? LIMIT 1", [session]) is None
          joined = self.run(member_join_if_needed_sql, [thread, session, connect, now]) > 0
          if joined {
            let born : String? = if is_born { text_of(session) } else { None }
            let (ss, ts) = @sql.settle_conversation_in_tx(self.db, thread, now, born~)
            settled_sessions = ss
            settled_threads = ts
          }
        })
        if joined {
          changes.push({ "type": "session", "key": session })
          changes.push({ "type": "thread", "id": thread, "entries": [] })
          for s in settled_sessions {
            if s != sk {
              changes.push({ "type": "session", "key": jstr(s) })
            }
          }
          for id in settled_threads {
            if id != thread {
              changes.push({ "type": "thread", "id": id, "entries": [] })
            }
          }
        }
        jbool(joined)
      }
    }
  })
}

///|
pub fn Store::leave_thread(self : Store, thread : Json, session : Json) -> Json raise {
  self.with_(changes => {
    let left = self.run("UPDATE thread_sessions SET left_at = ? WHERE thread = ? AND session = ? AND left_at IS NULL", [
        self.now_json(),
        thread,
        session,
      ]) >
      0
    if left {
      changes.push({ "type": "session", "key": session })
    }
    jbool(left)
  })
}

///|
pub fn Store::left_thread(self : Store, session : Json, connect : Json, channel : Json, thread_ts : Json) -> Json raise {
  let connect = own_name(connect)
  jbool(
    self.one(
      "SELECT 1 FROM thread_sessions m JOIN threads t ON t.id = m.thread\n         WHERE m.session = ? AND m.connect = ? AND t.channel = ? AND t.thread_ts = ? AND m.left_at IS NOT NULL LIMIT 1",
      [session, connect, channel, thread_ts],
    )
    is Some(_),
  )
}

///|
fn Store::thread_sessions_json(self : Store, thread : Json) -> Json raise {
  Json::array(self.all("SELECT * FROM thread_sessions WHERE thread = ? ORDER BY joined_at, rowid", [thread]).map(membership_of))
}

///|
pub fn Store::thread_sessions(self : Store, thread : Json) -> Json raise {
  self.thread_sessions_json(thread)
}

///|
/// store.ts `#active`: a read of the active jobs' tables, or what it was before they were made.
fn Store::active(self : Store, sql : String, before : String, params : Array[Json]) -> Array[Map[String, Json]] raise {
  self.all(sql, params) catch {
    e => {
      let m = sql_message(e)
      if !m.contains("no such table: active_watch_jobs") &&
        !m.contains("no such table: active_other_jobs") &&
        !m.contains("no such index: active_other_remote_jobs") {
        raise e
      }
      self.all(before, params)
    }
  }
}

///|
pub fn Store::has_active_watch(self : Store, thread : Json) -> Json raise {
  jbool(!self.active(has_active_watch_sql, has_active_watch_before_upgrade_sql, [thread]).is_empty())
}

///|
pub fn Store::has_session_active_watch(self : Store, session : Json) -> Json raise {
  jbool(!self.active(has_session_active_watch_sql, has_session_active_watch_before_upgrade_sql, [session]).is_empty())
}

///|
pub fn Store::session_thread(self : Store, session : Json, channel : Json, thread_ts : Json) -> Json raise {
  opt_row(
    self.one(
      "SELECT t.*, ts.connect FROM thread_sessions ts JOIN threads t ON t.id = ts.thread WHERE ts.session = ? AND t.channel = ? AND t.thread_ts = ?",
      [session, channel, thread_ts],
    ),
    session_thread_of,
  )
}

///|
pub fn Store::session_thread_by_id(self : Store, session : Json, thread : Json) -> Json raise {
  opt_row(self.one(session_thread_by_id_sql, [thread, session]), session_thread_of)
}

///|
pub fn Store::session_home_thread(self : Store, session : Json) -> Json raise {
  let anchor = match text_of(session) {
    Some(k) => jstr(@sql.conversation_of(self.db, k))
    None => session
  }
  opt_row(self.one(session_home_thread_sql, [anchor, session]), session_thread_of)
}

///|
/// cc-thread-index.ts `checkCcIndex`.
fn check_cc_index(db : @sql.Db) -> Unit raise {
  let row = one(db, "SELECT version FROM cc_index_meta WHERE id=1", [])
  guard row is Some(r) && is_num(col(r, "version"), 1.0) else {
    let had = match row {
      Some(r) => col(r, "version").stringify()
      None => "missing"
    }
    raise StoreError("copy destination index version \{had} is incompatible with 1")
  }
}

///|
/// cc-thread-index.ts `ccSessionReady`.
fn cc_session_ready(db : @sql.Db, session : Json) -> Bool raise {
  check_cc_index(db)
  let scope = one(db, "SELECT complete FROM cc_sessions WHERE session=?", [session])
  if !(scope is Some(s) && is_num(col(s, "complete"), 1.0)) ||
    one(db, "SELECT 1 FROM cc_session_dirty WHERE session=? LIMIT 1", [session]) is Some(_) {
    return false
  }
  let dispatch = one(
    db,
    "SELECT COUNT(*) AS n, MAX(EXISTS\n    (SELECT 1 FROM cc_session_rows r WHERE r.session=?1 AND r.thread=d.thread)) AS affects\n    FROM (SELECT thread FROM cc_order_dispatch ORDER BY thread LIMIT 65) d",
    [session],
  ).unwrap()
  if is_num(col(dispatch, "affects"), 1.0) {
    return false
  }
  if num(col(dispatch, "n")) <= 64.0 {
    return true
  }
  let rows = one(
    db,
    "SELECT COUNT(*) AS n, MAX(EXISTS\n    (SELECT 1 FROM cc_order_dispatch d WHERE d.thread=r.thread)) AS affects\n    FROM (SELECT thread FROM cc_session_rows WHERE session=?1 ORDER BY thread LIMIT 65) r",
    [session],
  ).unwrap()
  num(col(rows, "n")) <= 64.0 && !is_num(col(rows, "affects"), 1.0)
}

///|
/// store.ts `ccThreads` (cc-thread-index.ts `indexedCcThreads`).
pub fn Store::cc_threads(self : Store, thread : Json) -> Json raise {
  let rows = self.snapshot("cc_threads_read", () => {
    let sessions = self.all("SELECT session FROM thread_sessions WHERE thread=? ORDER BY session", [thread])
    let missing = []
    for s in sessions {
      if !cc_session_ready(self.db, col(s, "session")) {
        missing.push(text_of(col(s, "session")).unwrap_or(""))
      }
    }
    if !missing.is_empty() {
      raise CcSessionsUnavailable(missing)
    }
    let candidates : Array[(String, Json)] = []
    for s in sessions {
      for row in self.all(cc_session_keys_sql, [col(s, "session")]) {
        let key = text_of(col(row, "thread")).unwrap_or("")
        if !candidates.iter().any(c => c.0 == key) {
          candidates.push((key, col(s, "session")))
        }
      }
    }
    if candidates.is_empty() {
      return []
    }
    let pairs = Json::array(candidates.map(c => Json::array([jstr(c.0), c.1])))
    self.all(cc_indexed_threads_sql, [jstr(pairs.stringify())])
  })
  Json::array(rows.map(session_thread_of))
}

///|
fn Store::session_threads_rows(self : Store, session : String, limit : Int) -> Array[Map[String, Json]] raise {
  self.all(
    "SELECT t.*, ts.connect FROM thread_sessions ts JOIN threads t ON t.id = ts.thread WHERE ts.session = ? ORDER BY ts.joined_at DESC, ts.rowid DESC LIMIT ?",
    [jstr(session), jint(limit)],
  )
}

///|
pub fn Store::session_threads(self : Store, session : Json, limit : Json) -> Json raise {
  let rows = self.all(
    "SELECT t.*, ts.connect FROM thread_sessions ts JOIN threads t ON t.id = ts.thread WHERE ts.session = ? ORDER BY ts.joined_at DESC, ts.rowid DESC LIMIT ?",
    [session, if limit is Null { jint(-1) } else { limit }],
  )
  Json::array(rows.map(session_thread_of))
}

///|
/// store.ts `recentThreadRows`: (rows, more, unprepared).
fn Store::recent_thread_rows(self : Store, session : Json, limit : Int) -> (Array[Map[String, Json]], Bool, Bool) raise {
  let joined = self.all(recent_joined_threads_sql, [session, jint(limit + 1)])
  if joined.length() <= limit {
    return (self.all(few_session_threads_sql, [session, jint(limit)]), false, false)
  }
  let attempt = self.one(latest_thread_attempt_sql, [session]).unwrap()
  let ready = is_num(col(attempt, "_latest_version"), 1.0) && is_num(col(attempt, "_latest_ready"), 1.0)
  let heard = if ready { self.all(latest_threads_indexed_sql, [session, jint(limit)]) } else { [] }
  let home_anchor = match text_of(session) {
    Some(k) => jstr(@sql.conversation_of(self.db, k))
    None => session
  }
  let home = self.one(session_home_thread_sql, [home_anchor, session])
  let half = (limit + 1) / 2
  let order : Array[Map[String, Json]] = []
  if home is Some(h) {
    order.push(h)
  }
  order.push_iter(heard.iter().take(half))
  order.push_iter(joined.iter().take(half))
  order.push_iter(heard.iter().drop(half))
  order.push_iter(joined.iter().drop(half))
  let seen : Array[Json] = []
  let rows = []
  for r in order {
    if rows.length() == limit {
      break
    }
    if seen.contains(col(r, "id")) {
      continue
    }
    seen.push(col(r, "id"))
    rows.push(r)
  }
  (rows, true, !ready)
}

///|
pub fn Store::recent_session_threads(self : Store, session : Json, limit : Json) -> Json raise {
  let (rows, more, unprepared) = self.recent_thread_rows(session, if limit is Null { 20 } else { num(limit).to_int() })
  if unprepared {
    self.requested.push({ "latestThread": session })
  }
  { "threads": Json::array(rows.map(session_thread_of)), "more": jbool(more) }
}

///|
pub fn Store::latest_thread_if_ready(self : Store, session : Json) -> Json raise {
  let attempt = self.one(latest_thread_attempt_sql, [session]).unwrap()
  if !is_num(col(attempt, "_latest_version"), 1.0) {
    let had = match col(attempt, "_latest_version") {
      Null => "missing"
      v => v.stringify()
    }
    raise StoreError("latest thread index version \{had} is incompatible with 1")
  }
  if !is_num(col(attempt, "_latest_ready"), 1.0) && num(col(attempt, "_latest_members")) > 1.0 {
    return undefined
  }
  if col(attempt, "id") is Null {
    Json::null()
  } else {
    session_thread_of(attempt)
  }
}

///|
pub fn Store::latest_thread(self : Store, session : Json) -> Json raise {
  let ready = self.latest_thread_if_ready(session)
  if ready != undefined {
    return ready
  }
  self.requested.push({ "latestThread": session })
  opt_row(
    self.one(
      "SELECT t.*, ts.connect FROM thread_sessions ts JOIN threads t ON t.id = ts.thread\n       WHERE ts.session = ?\n       ORDER BY (SELECT d.rowid FROM deliveries d INDEXED BY deliveries_session\n                 WHERE d.session = ts.session AND d.thread = ts.thread ORDER BY d.rowid DESC LIMIT 1) DESC,\n                ts.joined_at DESC, ts.rowid DESC LIMIT 1",
      [session],
    ),
    session_thread_of,
  )
}

///|
/// session-chat-index.ts `checkSessionChatIndex`.
fn check_session_chat_index(db : @sql.Db) -> Unit raise {
  let row = one(db, "SELECT version FROM session_chat_meta WHERE id=1", [])
  guard row is Some(r) && is_num(col(r, "version"), 1.0) else {
    let had = match row {
      Some(r) => col(r, "version").stringify()
      None => "missing"
    }
    raise StoreError("session chat index version \{had} is incompatible with 1")
  }
}

///|
/// session-chat-index.ts `indexedSessionChat`.
fn Store::indexed_session_chat(self : Store, session : Json) -> Map[String, Json]? raise {
  self.snapshot("session_chat_read", () => {
    check_session_chat_index(self.db)
    let small = self.one(session_chat_small_sql, [session]).unwrap()
    if num(col(small, "_member_count")) < 2.0 {
      return if col(small, "id") is Null { None } else { Some(small) }
    }
    check_session_chat_index(self.db)
    let scope = self.one("SELECT complete FROM session_chat_scopes WHERE session=?", [session])
    let ready = scope is Some(s) && is_num(col(s, "complete"), 1.0) && cc_session_ready(self.db, session)
    if !ready {
      raise SessionChatUnavailable
    }
    self.one(session_chat_indexed_sql, [session])
  })
}

///|
pub fn Store::session_chat(self : Store, session : Json) -> Json raise {
  let small = self.one(session_chat_small_sql, [session]).unwrap()
  if !is_num(col(small, "_session_chat_version"), 1.0) {
    let had = match col(small, "_session_chat_version") {
      Null => "missing"
      v => v.stringify()
    }
    raise StoreError("session chat index version \{had} is incompatible with 1")
  }
  let r = if num(col(small, "_member_count")) < 2.0 {
    if col(small, "id") is Null {
      None
    } else {
      Some(small)
    }
  } else {
    self.indexed_session_chat(session) catch {
      SessionChatUnavailable => {
        self.requested.push({ "sessionChat": session })
        self.one(
          "SELECT t.* FROM thread_sessions m JOIN threads t ON t.id = m.thread WHERE m.session = ?\n           ORDER BY (SELECT e.at FROM entries e WHERE e.thread = t.id ORDER BY e.n DESC LIMIT 1) DESC, t.created_at DESC, t.id DESC LIMIT 1",
          [session],
        )
      }
      e => raise e
    }
  }
  guard r is Some(r) else { return Json::null() }
  let thread = thread_of(r)
  {
    "thread": thread,
    "firstText": if col(r, "surface") == jstr(stillfail_surface) {
      Json::null()
    } else {
      self.first_text(col(r, "id"))
    },
  }
}

///|
/// store.ts `firstText`.
pub fn Store::first_text(self : Store, thread : Json) -> Json raise {
  match
    self.one(
      "SELECT substr(m.text, 1, 300) AS t FROM thread_state s JOIN merged m ON m.thread = s.thread AND m.n = s.person_n WHERE s.thread = ?",
      [thread],
    ) {
    Some(r) => col(r, "t")
    None => Json::null()
  }
}

///|
/// store.ts `#lastSaid`.
fn Store::last_said(self : Store, thread : Json) -> Json raise {
  opt_row(
    self.one("SELECT m.* FROM thread_state t JOIN merged m ON m.thread = t.thread AND m.n = t.said_n WHERE t.thread = ?", [
      thread,
    ]),
    message_of,
  )
}

///|
/// store.ts `#letterCount`.
fn Store::letter_count(self : Store, thread : Json) -> Double raise {
  let apart = self.last_letter_n(thread)
  let kept = match self.one("SELECT letters FROM thread_state WHERE thread = ?", [thread]) {
    Some(r) if !(col(r, "letters") is Null) => num(col(r, "letters"))
    _ => 0.0
  }
  apart + kept
}

///|
/// store.ts `#threadPeople` (and the function `threadPeople` recentConnectPeople reads by).
fn Store::thread_people(self : Store, thread : Json, surface : Json) -> Array[String] raise {
  let connect = match self.one("SELECT MIN(connect) AS c FROM thread_sessions WHERE thread = ?", [thread]) {
    Some(r) => text_of(col(r, "c"))
    None => None
  }
  let authors = self.all("SELECT author FROM thread_people WHERE thread = ? ORDER BY first_n", [thread]).map(r => text_of(col(r, "author")).unwrap_or(""))
  if surface == jstr(stillfail_surface) {
    return authors
  }
  match connect {
    None => []
    Some(c) => authors.map(a => "slack:\{c}:\{a}")
  }
}

///|
fn Store::slack_identities(self : Store, viewer : Json) -> Array[Json] raise {
  self.all("SELECT slack_user FROM identities WHERE viewer = ? ORDER BY at", [viewer]).map(r => col(r, "slack_user"))
}

///|
/// store.ts `#unreadCount`.
fn Store::unread_count_at(self : Store, viewer : Json, thread : Json, read : Json) -> Json raise {
  let t = self.one("SELECT * FROM threads WHERE id = ?", [thread])
  let slack = match t {
    Some(t) => col(t, "surface") != jstr(stillfail_surface)
    None => true
  }
  let selves = [viewer]
  if slack {
    selves.push_iter(self.slack_identities(viewer).iter())
  }
  let sql = if self.legacy_said {
    legacy_unread_sql
  } else {
    "SELECT COUNT(*) AS c FROM entries WHERE thread = ? AND n > ? AND kind = 'message'\n       AND NOT (author_kind = 'person' AND author IN (SELECT value FROM json_each(?))) AND NOT \{letter_sql_sql}"
  }
  col(self.one(sql, [thread, read, jstr(Json::array(selves).stringify())]).unwrap(), "c")
}

///|
pub fn Store::list_threads(self : Store, viewer : Json, session : Json, thread : Json, unread : Json) -> Json raise {
  let base = "SELECT t.*, COALESCE(r.n, 0) AS read_n FROM threads t LEFT JOIN reads r ON r.thread = t.id AND r.viewer = ?1"
  let rows = if !(thread is Null) {
    self.all("\{base} WHERE t.id = ?2", [viewer, thread])
  } else if !(session is Null) {
    self.all("\{base} WHERE t.id IN (SELECT thread FROM thread_sessions WHERE session = ?2)", [viewer, session])
  } else {
    self.all(base, [viewer])
  }
  let summaries = []
  for r in rows {
    let id = col(r, "id")
    let read = col(r, "read_n")
    let last_message = self.last_said(id)
    summaries.push((
      ({
        "sessions": self.thread_sessions_json(id),
        "last": self.last_entry(id),
        "lastMessage": last_message,
        "read": read,
        "unread": if unread == jstr("none") { jint(0) } else { self.unread_count_at(viewer, id, read) },
        "people": Json::array(self.thread_people(id, col(r, "surface")).map(jstr)),
        "firstText": self.first_text(id),
        "letters": jnum(self.letter_count(id)),
        "lettersLast": jnum(self.last_letter_n(id)),
        "thread": thread_of(r),
      } : Json),
      match last_message {
        Object(m) => num(m.get("createdAt").unwrap_or(jint(0)))
        _ => 0.0
      },
      num(col(r, "created_at")),
      num(id),
    ))
  }
  let sorted = stable_sort(summaries, (a, b) => {
    let d = b.1 - a.1
    let d = if d != 0.0 && !d.is_nan() { d } else { b.2 - a.2 }
    let d = if d != 0.0 && !d.is_nan() { d } else { b.3 - a.3 }
    if d > 0.0 {
      1
    } else if d < 0.0 {
      -1
    } else {
      0
    }
  })
  Json::array(sorted.map(s => s.0))
}

///|
/// Array.prototype.sort: stable, by `cmp`.
fn[T] stable_sort(xs : Array[T], cmp : (T, T) -> Int) -> Array[T] {
  let out = xs.copy()
  // insertion into a merge sort, stable
  fn merge(a : Array[T], cmp : (T, T) -> Int) -> Array[T] {
    if a.length() <= 1 {
      return a
    }
    let mid = a.length() / 2
    let l = merge(a[0:mid].to_owned(), cmp)
    let r = merge(a[mid:].to_owned(), cmp)
    let res = []
    let mut i = 0
    let mut j = 0
    while i < l.length() || j < r.length() {
      if j >= r.length() || (i < l.length() && cmp(l[i], r[j]) <= 0) {
        res.push(l[i])
        i += 1
      } else {
        res.push(r[j])
        j += 1
      }
    }
    res
  }
  merge(out, cmp)
}

///|
pub fn Store::recent_connect_people(self : Store, connect : Json, limit : Json) -> Json raise {
  let c = text_of(connect).unwrap_or("")
  let prefix = "slack:\{c}:"
  Json::array(
    self
    .all(@readops.recent_connect_threads, [limit, connect])
    .map(r => {
      let people = []
      for person in self.thread_people(col(r, "id"), col(r, "surface")) {
        if person.has_prefix(prefix) {
          people.push(jstr(person.unsafe_substring(start=prefix.length(), end=person.length())))
        }
      }
      ({ "thread": col(r, "id"), "people": Json::array(people) } : Json)
    }),
  )
}

///|
pub fn Store::recent_chat_list(self : Store, ws : Json, home : Json, limit : Json) -> Json raise {
  let (ids, total) = if is_num(limit, 0.0) {
    ([], jint(0))
  } else {
    let rows = self.all(recent_chat_list_sql, [ws, home, limit])
    (rows.map(r => col(r, "id")), if rows.is_empty() { jint(0) } else { col(rows[0], "total") })
  }
  let threads = []
  let keys : Array[Json] = []
  for id in ids {
    guard self.one("SELECT * FROM threads WHERE id = ?", [id]) is Some(t) else { continue }
    let members = self.all("SELECT * FROM thread_sessions WHERE thread = ? ORDER BY joined_at, rowid", [id])
    for m in members {
      if !keys.contains(col(m, "session")) {
        keys.push(col(m, "session"))
      }
    }
    let unnamed = col(t, "title") is Null && col(t, "auto_title") is Null
    threads.push(({
      "thread": thread_of(t),
      "sessions": Json::array(members.map(membership_of)),
      "lastMessage": self.last_said(id),
      "firstText": if unnamed { self.first_text(id) } else { Json::null() },
    } : Json))
  }
  let sessions = []
  for key in keys {
    if self.one("SELECT * FROM sessions WHERE key = ?", [key]) is Some(r) {
      let out : Map[String, Json] = Map([])
      put_col(out, "key", r, "key")
      put_col(out, "title", r, "title")
      put_col(out, "archivedAt", r, "archived_at")
      out["ws"] = col(r, "ws")
      out["runtime"] = col(r, "runtime")
      out["model"] = col(r, "model")
      out["effort"] = col(r, "effort")
      out["running"] = match col(r, "running") {
        Number(n, ..) => Json::boolean(n != 0.0)
        True => Json::boolean(true)
        _ => Json::boolean(false)
      }
      out["createdBy"] = col(r, "created_by")
      sessions.push(Json::object(out))
    }
  }
  { "threads": Json::array(threads), "sessions": Json::array(sessions), "total": total }
}

///|
/// A value joined into a string as JavaScript's join and template do.
fn js_text(v : Json) -> String {
  match v {
    String(s) => s
    Null => ""
    True => "true"
    False => "false"
    Number(n, ..) =>
      if n == n.floor() && n.abs() < 1.0e21 {
        n.to_int64().to_string()
      } else {
        @jsjson.stringify(Num(n))
      }
    v => v.stringify()
  }
}

///|
pub fn Store::search_chat_list(self : Store, ws : Json, home : Json, limit : Json, query : Json, filter? : Json = Json::null()) -> Json raise {
  if is_num(limit, 0.0) {
    return { "threads": [], "sessions": [], "total": 0 }
  }
  let q = text_of(query).unwrap_or("")
  let fget = (k : String) => match filter { Object(o) => o.get(k); _ => None }
  let filter_model = match fget("model") { Some(String(s)) if s != "" => Some(@jscase.lower(s)); _ => None }
  let filter_creator = match fget("createdBy") { Some(String(s)) if s != "" => Some(@jscase.lower(s)); _ => None }
  let filter_archived = match fget("archived") { Some(True) => Some(true); Some(False) => Some(false); _ => None }
  let threads = []
  let sessions : Array[(String, Json)] = []
  let mut total = 0
  for row in self.all(search_chat_list_sql, [ws, home]) {
    let id = col(row, "id")
    let members = match col(row, "members") {
      String(s) =>
        match (try @json.parse(s) catch { _ => Json::array([]) }) {
          Array(ms) => ms
          _ => []
        }
      _ => []
    }
    let field_of = (m : Json, k : String) => match m {
      Object(o) => o.get(k).unwrap_or(Json::null())
      _ => Json::null()
    }
    if filter_archived is Some(want_archived) {
      let hidden = !(col(row, "hidden_at") is Null)
      let home_archived = match col(row, "home") {
        String(h) => members.iter().any(m => js_text(field_of(m, "session")) == h && !(field_of(m, "archivedAt") is Null))
        _ => false
      }
      if (hidden || home_archived) != want_archived {
        continue
      }
    }
    if filter_model is Some(want_model) {
      if !members.iter().any(m => @jscase.lower(js_text(field_of(m, "model"))).contains(want_model)) {
        continue
      }
    }
    if filter_creator is Some(want_creator) {
      let tc = @jscase.lower(js_text(col(row, "created_by")))
      let matches_creator = (tc != "" && tc.contains(want_creator)) ||
        members.iter().any(m => {
          let c = @jscase.lower(js_text(field_of(m, "createdBy")))
          c != "" && c.contains(want_creator)
        })
      if !matches_creator {
        continue
      }
    }
    let mut first_text = Json::null()
    if q != "" {
      first_text = col(row, "first_text")
      let titles = [col(row, "title"), col(row, "auto_title"), first_text, ..members.map(m => field_of(m, "title"))].filter(t => !(t is Null))
      let said_text = col(row, "said_text")
      let haystack = @jscase.lower(
        titles.map(js_text).join(" ") +
        " " +
        (if said_text is Null { "" } else { js_text(said_text) }) +
        " " +
        members.map(m => js_text(field_of(m, "session"))).join(" "),
      )
      if !haystack.contains(q) {
        continue
      }
    }
    total += 1
    if threads.length().to_double() < num(limit) {
      if q == "" && col(row, "title") is Null && col(row, "auto_title") is Null {
        first_text = col(row, "first_text")
      }
      for m in members {
        if !(field_of(m, "present") is (Number(0.0, ..) | Null | False)) {
          let key = js_text(field_of(m, "session"))
          let running = match field_of(m, "running") {
            Number(n, ..) => Json::boolean(n != 0.0)
            True => Json::boolean(true)
            _ => Json::boolean(false)
          }
          let value : Json = {
            "key": field_of(m, "session"),
            "title": field_of(m, "title"),
            "archivedAt": field_of(m, "archivedAt"),
            "ws": field_of(m, "ws"),
            "runtime": match field_of(m, "runtime") { String(s) => Json::string(s); _ => Json::string("") },
            "model": field_of(m, "model"),
            "effort": field_of(m, "effort"),
            "running": running,
            "createdBy": field_of(m, "createdBy"),
          }
          match sessions.search_by(s => s.0 == key) {
            Some(i) => sessions[i] = (key, value)
            None => sessions.push((key, value))
          }
        }
      }
      threads.push(({
        "thread": thread_of(row),
        "sessions": Json::array(
          members.map(m => ({
            "thread": id,
            "session": field_of(m, "session"),
            "connect": field_of(m, "connect"),
            "joinedAt": field_of(m, "joinedAt"),
          } : Json)),
        ),
        "lastMessage": self.last_said(id),
        "firstText": first_text,
      } : Json))
    }
  }
  { "threads": Json::array(threads), "sessions": Json::array(sessions.map(s => s.1)), "total": jint(total) }
}
