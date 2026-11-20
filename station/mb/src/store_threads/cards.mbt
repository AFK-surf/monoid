// Cards: the one a thread waits on, the one a message or a newer card ended, one closed without a message, the message a
// need without a card asks with, a viewer's dismissals, an agent's withdrawal, the login cards closed as a login ends, a
// person's choice that closes a card, and what an agent is told once (store.ts `// ── cards ──`, card-kinds.ts).

///|
/// card-post-index.ts `cardPostsReady`.
fn card_posts_ready(db : @sql.Db, thread : Json) -> Bool raise {
  let meta = one(db, "SELECT version FROM card_post_meta WHERE id=1", [])
  guard meta is Some(m) && is_num(col(m, "version"), 1.0) else {
    let had = match meta {
      Some(m) => col(m, "version").stringify()
      None => "missing"
    }
    raise StoreError("card post index version \{had} is incompatible with 1")
  }
  match
    one(db, "SELECT CAST(last_n AS TEXT) AS last_n,CAST(end_n AS TEXT) AS end_n,phase FROM card_post_scopes WHERE thread=?", [
      thread,
    ]) {
    Some(s) => is_num(col(s, "phase"), 2.0)
    None => false
  }
}

///|
fn n_of(r : Map[String, Json]?) -> Json? {
  match r {
    Some(r) if !(col(r, "n") is Null) => Some(col(r, "n"))
    _ => None
  }
}

///|
/// store.ts `#cardWaits`.
fn Store::card_waits(self : Store, thread : Json, n : Json) -> Bool raise {
  if self.one("SELECT 1 FROM closed_cards WHERE thread = ? AND n = ?", [thread, n]) is Some(_) {
    return false
  }
  if self.one(system_card_at_sql, [thread, n]) is Some(_) {
    return self.one(system_card_kept_sql, [thread, n]) is Some(_)
  }
  self.one(answer_after_sql, [thread, n]) is None
}

///|
/// store.ts `#pendingCardNumber`.
fn Store::pending_card_number(self : Store, thread : Json) -> Json? raise {
  match n_of(self.one(system_card_waiting_sql, [thread])) {
    Some(n) => return Some(n)
    None => ()
  }
  let n = if card_posts_ready(self.db, thread) {
    n_of(self.one(conversation_card_latest_sql, [thread]))
  } else {
    let latest = (column : String) => n_of(
      self.one(
        "SELECT n FROM entries WHERE thread = ? AND kind = 'message' AND \{column} IS NOT NULL AND NOT \{system_card_of_card_sql} ORDER BY n DESC LIMIT 1",
        [thread],
      ),
    )
    let a = latest("card")
    let b = latest("options")
    match (a, b) {
      (Some(x), Some(y)) => Some(if num(x) >= num(y) { x } else { y })
      (Some(x), None) => Some(x)
      (None, y) => y
    }
  }
  guard n is Some(n) else { return None }
  if !self.card_waits(thread, n) {
    return None
  }
  Some(n)
}

///|
/// store.ts `#cardPost`: [post as merged, its card], or null.
fn Store::card_post(self : Store, thread : Json, n : Json) -> Json raise {
  let row = self.one("SELECT card, options FROM entries WHERE thread = ? AND n = ? AND kind = 'message'", [thread, n])
  let card = match row {
    Some(r) => card_of(col(r, "card"), col(r, "options"))
    None => None
  }
  guard card is Some(card) else { return Json::null() }
  match self.one("SELECT * FROM merged WHERE thread = ? AND n = ?", [thread, n]) {
    Some(m) => Json::array([message_of(m), to_json(card)])
    None => Json::null()
  }
}

///|
pub fn Store::pending_card(self : Store, thread : Json) -> Json raise {
  match self.pending_card_number(thread) {
    Some(n) => self.card_post(thread, n)
    None => Json::null()
  }
}

///|
pub fn Store::pending_card_header(self : Store, thread : Json) -> Json raise {
  guard self.pending_card_number(thread) is Some(n) else { return Json::null() }
  let row = self.one("SELECT ts, card, options FROM entries WHERE thread = ? AND n = ? AND kind = 'message'", [thread, n])
  let card = match row {
    Some(r) => card_of(col(r, "card"), col(r, "options"))
    None => None
  }
  guard card is Some(card) && row is Some(r) else { return Json::null() }
  Json::array([
    {
      "n": n,
      "ts": match col(r, "ts") {
        Null => jstr("")
        t => t
      },
    },
    to_json(card),
  ])
}

///|
pub fn Store::pending_card_header_if_ready(self : Store, thread : Json) -> Json raise {
  self.snapshot("pending_card_header", () => {
    if !card_posts_ready(self.db, thread) {
      let indexes = match
        self.one("SELECT COUNT(*) AS n FROM sqlite_master WHERE type='index' AND name IN ('entries_cards','entries_options')", []) {
        Some(r) => col(r, "n")
        None => Json::null()
      }
      if is_num(indexes, 2.0) &&
        self.one("SELECT 1 FROM entries INDEXED BY entries_cards WHERE thread = ? AND card IS NOT NULL LIMIT 1", [thread]) is None &&
        self.one("SELECT 1 FROM entries INDEXED BY entries_options WHERE thread = ? AND options IS NOT NULL LIMIT 1", [thread]) is None {
        return Json::null()
      }
      return undefined
    }
    self.pending_card_header(thread)
  })
}

///|
/// store.ts `#previousCard`.
fn Store::previous_card(self : Store, thread : Json, n : Json) -> Json? raise {
  if card_posts_ready(self.db, thread) {
    return n_of(self.one(conversation_card_before_sql, [thread, n]))
  }
  let before = n_of(self.one(card_before_latest_person_sql, [thread, n]))
  match before {
    None => None
    Some(b) => if self.one(system_card_at_sql, [thread, b]) is Some(_) { None } else { Some(b) }
  }
}

///|
/// store.ts `#cardEndedAfter`.
fn Store::card_ended_after(self : Store, thread : Json, n : Json) -> Bool raise {
  if self.one(system_card_at_sql, [thread, n]) is Some(_) {
    return false
  }
  if self.one(answer_after_sql, [thread, n]) is Some(_) {
    return true
  }
  if card_posts_ready(self.db, thread) {
    return self.one(
        "SELECT 1 FROM card_posts c JOIN entries e ON e.thread = c.thread AND e.n = c.n\n        WHERE c.thread = ?1 AND c.n > ?2 AND NOT \{system_card_of_e_card_sql} LIMIT 1",
        [thread, n],
      )
      is Some(_)
  }
  !is_num(col(self.one(closed_card_after_sql, [thread, n]).unwrap(), "ended"), 0.0)
}

///|
pub fn Store::card_ended_by_message(self : Store, thread : Json, n : Json) -> Json raise {
  if self.one(answer_at_sql, [thread, n]) is None {
    return Json::null()
  }
  guard self.previous_card(thread, n) is Some(asked) else { return Json::null() }
  let earlier = self.one(answer_between_sql, [thread, asked, n])
  let closed = self.one("SELECT 1 FROM closed_cards WHERE thread = ? AND n = ?", [thread, asked])
  if earlier is Some(_) || closed is Some(_) {
    return Json::null()
  }
  let row = self.one("SELECT card, options FROM entries WHERE thread = ? AND n = ?", [thread, asked])
  let card = match row {
    Some(r) => card_of(col(r, "card"), col(r, "options"))
    None => None
  }
  let message = self.one("SELECT * FROM merged WHERE thread = ? AND n = ?", [thread, asked])
  match (card, message) {
    (Some(c), Some(m)) => Json::array([message_of(m), to_json(c)])
    _ => Json::null()
  }
}

///|
pub fn Store::card_replaced_by(self : Store, thread : Json, n : Json) -> Json raise {
  let carded = self.one(
    "SELECT card FROM entries WHERE thread = ? AND n = ? AND kind = 'message' AND (card IS NOT NULL OR options IS NOT NULL)",
    [thread, n],
  )
  if carded is None || self.one(system_card_at_sql, [thread, n]) is Some(_) {
    return Json::null()
  }
  guard self.previous_card(thread, n) is Some(asked) else { return Json::null() }
  let answered = self.one(answer_between_sql, [thread, asked, n])
  let closed = self.one("SELECT 1 FROM closed_cards WHERE thread = ? AND n = ?", [thread, asked])
  if answered is Some(_) || closed is Some(_) {
    return Json::null()
  }
  self.card_post(thread, asked)
}

///|
pub fn Store::closed_card(self : Store, thread : Json, n : Json) -> Json raise {
  let by = self.one("SELECT viewer FROM closed_cards WHERE thread = ? AND n = ?", [thread, n])
  guard by is Some(by) else { return Json::null() }
  if self.card_ended_after(thread, n) {
    return Json::null()
  }
  match self.card_post(thread, n) {
    Array(found) => Json::array([..found, col(by, "viewer")])
    _ => Json::null()
  }
}

///|
pub fn Store::asking_message(self : Store, thread : Json, about : Json, during : Json) -> Json raise {
  let (from, to) = match during {
    Array([a, b, ..]) => (a, b)
    _ => (Json::null(), Json::null())
  }
  let n = if !(about is Null) {
    Some(about)
  } else {
    let first = n_of(
      self.one(
        if self.legacy_agent {
          @readops.legacy_asked_during_sql
        } else {
          @readops.asked_during_sql
        },
        [thread, from, to],
      ),
    )
    match first {
      Some(n) => Some(n)
      None => if self.legacy_agent { None } else { n_of(self.one(asked_latest_sql, [thread, to])) }
    }
  }
  guard n is Some(n) else { return Json::null() }
  let answered = self.one(answer_after_sql, [thread, n]) is Some(_)
  let carded = self.one("SELECT 1 FROM entries WHERE thread = ? AND n = ? AND (card IS NOT NULL OR options IS NOT NULL)", [thread, n])
    is Some(_)
  if answered || carded {
    return Json::null()
  }
  let messages = self.messages_before_rows(thread, jnum(num(n) + 1.0), jint(3))
  guard messages.pop() is Some(Object(m) as last) else { return Json::null() }
  if m.get("n").map(num) == Some(num(n)) && m.get("authorKind") == Some(jstr("agent")) {
    Json::array([last, Json::array(messages)])
  } else {
    Json::null()
  }
}

///|
pub fn Store::card_closed_since(self : Store, thread : Json, since : Json) -> Json raise {
  jbool(self.one("SELECT 1 FROM closed_cards WHERE thread = ? AND at >= ? LIMIT 1", [thread, since]) is Some(_))
}

///|
pub fn Store::dismissed(self : Store, viewer : Json) -> Json raise {
  let out : Array[Json] = []
  for r in self.all("SELECT thread, n FROM dismissed WHERE viewer = ?", [viewer]) {
    let key = jstr("\{js_text(col(r, "thread"))}:\{js_text(col(r, "n"))}")
    if !out.contains(key) {
      out.push(key)
    }
  }
  Json::array(out)
}

///|
pub fn Store::dismiss(self : Store, viewer : Json, thread : Json, n : Json) -> Json raise {
  self.with_(changes => {
    ignore(self.run("INSERT OR IGNORE INTO dismissed (viewer, thread, n, at) VALUES (?, ?, ?, ?)", [viewer, thread, n, self.now_json()]))
    changes.push({ "type": "dismissed", "viewer": viewer, "card": { "thread": thread, "n": n } })
    undefined
  })
}

///|
pub fn Store::withdraw_card(self : Store, agent : Json, thread : Json, ts : Json) -> Json raise {
  self.with_(changes => {
    guard
      self.one(
        "SELECT n FROM entries WHERE thread = ? AND ts = ? AND kind = 'message' AND author_kind = 'agent' AND author = ? AND (card IS NOT NULL OR options IS NOT NULL)",
        [thread, ts, agent],
      )
      is Some(r) else {
      return jbool(false)
    }
    let closed = self.run("INSERT OR IGNORE INTO closed_cards (thread, n, viewer, at) VALUES (?, ?, ?, ?)", [
        thread,
        col(r, "n"),
        agent,
        self.now_json(),
      ]) >
      0
    let change : Map[String, Json] = { "type": jstr("thread"), "id": thread, "entries": Json::array([]) }
    if closed {
      change["closed"] = col(r, "n")
    }
    changes.push(Json::object(change))
    jbool(true)
  })
}

///|
/// The login cards of a login closed for everyone as it ends; the sessions whose cards they were.
pub fn Store::close_login_cards(self : Store, login : Json) -> Json raise {
  self.with_(changes => {
    let l = text_of(login).unwrap_or("")
    let pattern = jstr("%\"login\":\{stringify(Str(l))}%")
    let rows = if !self.legacy_login_cards {
      self.all(login_cards_sql, [pattern])
    } else {
      let native = exists(self.db, "index", "entries_login_cards")
      let keyed = l.length() >= 1 &&
        l.length() <= 40 &&
        l.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
      let read = (use_native : Bool) => if keyed {
        self.all(if use_native { legacy_login_cards_native_sql } else { legacy_login_cards_sql }, [jstr(l.to_lower()), pattern])
      } else {
        self.all(if use_native { login_cards_sql } else { legacy_login_cards_fallback_sql }, [pattern])
      }
      read(native) catch {
        e => {
          if !native || !sql_message(e).contains("no such index: entries_login_cards") {
            raise e
          }
          read(false)
        }
      }
    }
    for r in rows {
      ignore(
        self.run("INSERT OR IGNORE INTO closed_cards (thread, n, viewer, at) VALUES (?, ?, ?, ?)", [
          col(r, "thread"),
          col(r, "n"),
          col(r, "author"),
          self.now_json(),
        ]),
      )
      changes.push({ "type": "thread", "id": col(r, "thread"), "entries": [], "closed": col(r, "n") })
    }
    let authors : Array[Json] = []
    for r in rows {
      if !authors.contains(col(r, "author")) {
        authors.push(col(r, "author"))
      }
    }
    Json::array(authors)
  })
}

///|
/// i18n `station.card.chosen` in the request's language.
fn chosen_words(lang : String, option : String) -> String {
  if lang == "en" {
    "Chose “\{option}”"
  } else {
    "用户选择了「\{option}」"
  }
}

///|
pub fn Store::close_card(self : Store, viewer : Json, thread : Json, n : Json, option : Json, lang : Json) -> Json raise {
  self.with_(changes => {
    let mut closed : (Json, Bool)? = None
    let done = self.tx(() => {
      guard self.one("SELECT author, ts, at, card, options FROM entries WHERE thread = ? AND n = ? AND kind = 'message'", [thread, n])
        is Some(offered) else {
        return false
      }
      guard card_of(col(offered, "card"), col(offered, "options")) is Some(card) else { return false }
      let choices = match card {
        Obj(_) =>
          match jget(card, "options") {
            Some(Arr(xs)) => xs
            _ => []
          }
        _ => []
      }
      let option_text = text_of(option)
      let closes = choices.iter().any(o => o is Obj(_) &&
        jtext(jget(o, "label")) is Some(label) &&
        Some(@jscase.trim(label)) == option_text &&
        jtext(jget(o, "action")) == Some("close"))
      if card is Null || jtext(jget(card, "type")) != Some("options") || !closes {
        return false
      }
      if self.one("SELECT 1 FROM closed_cards WHERE thread = ? AND n = ?", [thread, n]) is Some(_) {
        return true
      }
      if self.card_ended_after(thread, n) {
        return false
      }
      ignore(self.run("INSERT INTO closed_cards (thread, n, viewer, at) VALUES (?, ?, ?, ?)", [thread, n, viewer, self.now_json()]))
      ignore(
        self.run("INSERT OR REPLACE INTO card_choices (thread, n, session, ts, viewer, option, at) VALUES (?, ?, ?, ?, ?, ?, ?)", [
          thread,
          n,
          col(offered, "author"),
          col(offered, "ts"),
          viewer,
          option,
          self.now_json(),
        ]),
      )
      let chosen = jstr(chosen_words(text_of(lang).unwrap_or("zh"), js_text(option)))
      let changed = self.run(
        "UPDATE turns SET declared = 'final', need = ?5, wait_seconds = NULL\n           WHERE id = (SELECT id FROM turns WHERE session_key = ?1 ORDER BY started_at DESC LIMIT 1)\n             AND declared IN ('block', 'need_help', 'need_human', 'need_decision') AND ended_at IS NOT NULL\n             AND ((about_thread = ?2 AND about_n = ?3) OR (about_n IS NULL AND thread = ?2 AND started_at <= ?4))",
        [col(offered, "author"), thread, n, col(offered, "at"), chosen],
      )
      ignore(
        self.run(
          "UPDATE turns SET need = ?4\n           WHERE id = (SELECT id FROM turns WHERE session_key = ?1 ORDER BY started_at DESC LIMIT 1)\n             AND ended_at IS NULL AND about_thread = ?2 AND about_n = ?3",
          [col(offered, "author"), thread, n, chosen],
        ),
      )
      closed = Some((col(offered, "author"), changed > 0))
      true
    })
    if closed is Some((agent, changed)) {
      if changed {
        changes.push({ "type": "session", "key": agent })
      }
      changes.push({ "type": "thread", "id": thread, "entries": [], "closed": n })
    }
    jbool(done)
  })
}

///|
/// store.ts `#cardChoice`.
fn Store::card_choice(self : Store, r : Map[String, Json]) -> Json raise {
  let t = self.one("SELECT channel, thread_ts FROM threads WHERE id = ?", [col(r, "thread")])
  let post = self.one("SELECT text FROM entries WHERE thread = ? AND n = ? AND kind = 'message'", [col(r, "thread"), col(r, "n")])
  {
    "thread": col(r, "thread"),
    "n": col(r, "n"),
    "ts": col(r, "ts"),
    "where": match t {
      Some(t) => Json::array([col(t, "channel"), col(t, "thread_ts")])
      None => Json::null()
    },
    "question": match post {
      Some(p) => col(p, "text")
      None => Json::null()
    },
    "by": col(r, "viewer"),
    "option": col(r, "option"),
    "at": col(r, "at"),
  }
}

///|
pub fn Store::untold_card_choices(self : Store, session : Json, limit : Json) -> Json raise {
  let rows = self.all(
    "SELECT thread, n, ts, viewer, option, at FROM card_choices INDEXED BY card_choices_untold WHERE session = ? AND told_at IS NULL ORDER BY at LIMIT ?",
    [session, if limit is Null { jint(20) } else { limit }],
  )
  Json::array(rows.map(r => self.card_choice(r)))
}

///|
pub fn Store::set_moved_notes(self : Store, notes : Json) -> Json raise {
  let list = strings(notes)
  if list.is_empty() {
    return undefined
  }
  let field = (n : Json, k : String) => match n {
    Object(o) => o.get(k).unwrap_or(Json::null())
    _ => Json::null()
  }
  self.tx(() => for n in list {
    ignore(
      self.run(
        "INSERT OR IGNORE INTO moved_notes (session, text, told_at) SELECT ?, ?, NULL WHERE EXISTS (SELECT 1 FROM sessions WHERE key = ?)",
        [field(n, "session"), field(n, "text"), field(n, "session")],
      ),
    )
  })
  let keys = Json::array(list.map(n => field(n, "session")))
  for r in self.all("SELECT session FROM moved_notes WHERE told_at IS NULL AND session IN (SELECT value FROM json_each(?))", [
    jstr(keys.stringify()),
  ]) {
    self.moved_untold[js_text(col(r, "session"))] = true
  }
  undefined
}

///|
pub fn Store::untold_moved_note(self : Store, session : Json) -> Json raise {
  if !self.moved_untold.contains(js_text(session)) {
    return Json::null()
  }
  match self.one("SELECT text FROM moved_notes WHERE session = ? AND told_at IS NULL", [session]) {
    Some(r) => col(r, "text")
    None => Json::null()
  }
}

///|
pub fn Store::mark_moved_note_told(self : Store, session : Json) -> Json raise {
  let key = js_text(session)
  if !self.moved_untold.contains(key) {
    return undefined
  }
  self.moved_untold.remove(key)
  ignore(self.run("UPDATE moved_notes SET told_at = ? WHERE session = ? AND told_at IS NULL", [self.now_json(), session]))
  undefined
}

///|
pub fn Store::mark_card_choices_told(self : Store, session : Json, told : Json) -> Json raise {
  let now = self.now_json()
  for t in strings(told) {
    let (thread, n, _) = handed(t)
    ignore(self.run("UPDATE card_choices SET told_at = ? WHERE thread = ? AND n = ? AND session = ? AND told_at IS NULL", [now, thread, n, session]))
  }
  undefined
}

///|
pub fn Store::card_choices(self : Store, thread : Json, ns : Json) -> Json raise {
  let out : Map[String, Json] = Map([])
  for n in strings(ns) {
    if self.one("SELECT thread, n, ts, viewer, option, at FROM card_choices WHERE thread = ? AND n = ?", [thread, n]) is Some(r) {
      out[js_text(n)] = self.card_choice(r)
    }
  }
  Json::object(out)
}
