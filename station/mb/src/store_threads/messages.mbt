// Messages: what lists show of them and what is unread (store.ts `lastMessage` … `unreadForArchive`), recording one
// and a platform's edit of it (`insertMessage`, `editMessage`, `editMessageIfReady`), and the reads of a thread's
// entries (`lastEntry` … `messagesBefore`).

///|
let i64_max : Json = Json::number(9223372036854775807.0, repr="9223372036854775807")

///|
pub fn Store::last_message(self : Store, thread : Json) -> Json raise {
  opt_row(self.one(if self.legacy_said { legacy_last_message_sql } else { last_message_sql }, [thread]), message_of)
}

///|
/// archive-last.ts `installArchiveLast(db, false)`: whether it is in place.
fn Store::archive_last_installed(self : Store) -> Bool raise {
  let schema = schema_version(self.db)
  if self.archive_last_schema == Some(schema) {
    return true
  }
  if !exists(self.db, "table", "archive_last_meta") || !exists(self.db, "table", "archive_last_guard") {
    return false
  }
  guard self.one("SELECT version FROM archive_last_meta WHERE id=1", []) is Some(v) else { return false }
  if !is_num(col(v, "version"), 1.0) {
    raise StoreError("archive last metadata has an unsupported version")
  }
  for name in ["archive_last_insert", "archive_last_update", "archive_last_delete", "archive_last_thread_delete"] {
    guard sql_of(self.db, "trigger", name) is Some(sql) && sql.contains("archive_last_v1") else { return false }
  }
  self.archive_last_schema = Some(schema)
  true
}

///|
/// store.ts `lastMessageAtForArchive` (archive-last.ts `archiveLastRead`).
pub fn Store::last_message_at_for_archive(self : Store, thread : Json) -> Json raise {
  let unknown : Json = { "known": false, "at": Json::null() }
  if !self.archive_last_installed() {
    return unknown
  }
  let version = self.archive_last_schema
  self.snapshot("archive_last_read", () => {
    let answer = () => {
      guard self.one("SELECT version FROM archive_last_meta WHERE id=1", []) is Some(meta) else {
        self.archive_last_schema = None
        return unknown
      }
      if Some(schema_version(self.db)) != version {
        return unknown
      }
      if !is_num(col(meta, "version"), 1.0) {
        raise StoreError("archive last version \{col(meta, "version").stringify()} is incompatible")
      }
      guard self.one(archive_last_first_sql, [thread]) is Some(first) else { return { "known": true, "at": Json::null() } }
      if !(col(first, "at") is Null) {
        return { "known": true, "at": col(first, "at") }
      }
      if self.one(archive_last_guard_sql, [thread]) is Some(cached) {
        return { "known": true, "at": col(cached, "at") }
      }
      let tail = self.one(archive_last_tail_sql, [thread]).unwrap()
      if !(col(tail, "at") is Null) || num(col(tail, "count")) < 65.0 {
        return { "known": true, "at": col(tail, "at") }
      }
      unknown
    }
    answer() catch {
      e => {
        let m = sql_message(e)
        if m.contains("no such table: archive_last_meta") || m.contains("no such table: archive_last_guard") {
          self.archive_last_schema = None
          unknown
        } else {
          raise e
        }
      }
    }
  })
}

///|
pub fn Store::message_count(self : Store, thread : Json) -> Json raise {
  self.unread_count_at(jstr(""), thread, jint(-1))
}

///|
/// said-state.ts `saidBoundary`: (known, other).
fn said_boundary(state : Map[String, Json]?, latest : Map[String, Json]) -> (Bool, Json) {
  if col(latest, "author_kind") != jstr("person") {
    return (true, col(latest, "n"))
  }
  match state {
    Some(s) if col(s, "said_n") == col(latest, "n") && is_num(col(s, "said_other_known"), 1.0) =>
      return (true, col(s, "said_other_n"))
    _ => ()
  }
  match state {
    Some(s) if is_num(col(s, "guard_ready"), 1.0) && col(s, "guard_author") == col(latest, "author") =>
      return (true, col(s, "guard_other_n"))
    _ => ()
  }
  (false, Json::null())
}

///|
pub fn Store::unread_for_archive(self : Store, viewer : Json, thread : Json) -> Json raise {
  self.snapshot("archive_unread", () => {
    let read = num(self.read_position(viewer, thread))
    let (known, latest) = if self.legacy_said {
      legacy_said_read_head(self.db, thread)
    } else {
      (true, self.one(@readops.said_latest_sql, [thread]))
    }
    if !known {
      return Json::null()
    }
    guard latest is Some(latest) else { return jbool(false) }
    if num(col(latest, "n")) <= read {
      return jbool(false)
    }
    if col(latest, "author_kind") != jstr("person") || col(latest, "author") != viewer {
      return jbool(true)
    }
    let (bknown, other) = said_boundary(self.one(@readops.said_state_sql, [thread]), latest)
    if bknown {
      return jbool(!(other is Null) && num(other) > read)
    }
    if self.legacy_said && self.one(@readops.legacy_said_needs_drain_sql, [thread]) is Some(_) {
      let near = self.one(@readops.legacy_said_boundary_tail_sql, [thread, col(latest, "n"), col(latest, "author")]).unwrap()
      let nknown = !(col(near, "n") is Null) || num(col(near, "count")) < 65.0
      return if nknown {
        jbool(!(col(near, "n") is Null) && num(col(near, "n")) > read)
      } else {
        Json::null()
      }
    }
    let previous = self.all(if self.legacy_said { @readops.legacy_said_scan_sql } else { @readops.said_scan_sql }, [
      thread,
      col(latest, "n"),
      jint(64),
    ])
    if previous.iter().any(p => num(col(p, "n")) > read && (col(p, "author_kind") != jstr("person") || col(p, "author") != viewer)) {
      return jbool(true)
    }
    if previous.length() < 64 || num(col(previous[previous.length() - 1], "n")) <= read {
      return jbool(false)
    }
    Json::null()
  })
}

///|
fn jlist(v : @jsjson.JValue?) -> Array[@jsjson.JValue] raise {
  match v {
    None | Some(Null) => []
    Some(Arr(xs)) => xs
    Some(_) => raise StoreError("value.map is not a function")
  }
}

///|
fn jnullish(v : @jsjson.JValue?) -> Json {
  match v {
    None | Some(Null) => Json::null()
    Some(x) => to_json(x)
  }
}

///|
/// store.ts `insertMessage`: [n, fresh]; `before` and `inserted` run under the write lock.
pub fn Store::insert_message(
  self : Store,
  m : @jsjson.JValue,
  before? : (() -> Unit raise)? = None,
  inserted? : ((Double) -> Unit raise)? = None,
) -> Json raise {
  self.with_(changes => {
    let thread = jnullish(jget(m, "thread"))
    let ts = jnullish(jget(m, "ts"))
    let existing = self.message_number_at(thread, ts)
    if !(existing is Null) {
      return Json::array([existing, jbool(false)])
    }
    let card = match jget(m, "card") {
      None | Some(Null) => None
      Some(c) => Some(c)
    }
    let options = match jget(m, "options") {
      None | Some(Null) => None
      Some(o) => Some(o)
    }
    let kept_options = match options {
      Some(o) => Some(o)
      None =>
        match card {
          Some(Obj(_) as c) if jtext(jget(c, "type")) == Some("options") => jget(c, "options")
          _ => None
        }
    }
    let kept_card = match card {
      Some(c) => Some(c)
      None => options.map(options_card)
    }
    let entry : Entry = {
      agent_identity: jget(m, "agentIdentity"),
      thread,
      n: 0.0,
      kind: "message",
      target: Json::null(),
      ts,
      author_kind: jtext(jget(m, "authorKind")).unwrap_or(""),
      author: jtext(jget(m, "author")).unwrap_or(""),
      text: jnullish(jget(m, "text")),
      attachments: jlist(jget(m, "attachments")),
      quotes: jlist(jget(m, "quotes")),
      declared: jnullish(jget(m, "declared")),
      client: jnullish(jget(m, "client")),
      profile: jnullish(jget(m, "profile")),
      runtime: jnullish(jget(m, "runtime")),
      options: kept_options,
      card: kept_card,
      at: match jget(m, "at") {
        None | Some(Null) => self.now_json()
        Some(a) => to_json(a)
      },
      letter: jget(m, "letter"),
      change: jget(m, "change"),
    }
    self.append(entry, changes, before~, try_write=before is Some(_), inserted~)
    Json::array([jnum(entry.n), jbool(true)])
  })
}

///|
fn values_of(v : Json) -> Array[@jsjson.JValue] {
  match v {
    Array(xs) => xs.map(of_json)
    _ => []
  }
}

///|
fn Store::edit(self : Store, surface : Json, channel : Json, thread_ts : Json, ts : Json, text : Json, bounded : Bool) -> Json raise {
  let surface = own_name(surface)
  self.with_(changes => {
    let thread = self.thread_at(surface, channel, thread_ts)
    guard thread is Object(t) else { return Json::null() }
    let id = t.get("id").unwrap_or(Json::null())
    let message = if bounded { self.message_at_if_ready(id, ts) } else { self.message_at(id, ts) }
    if message == undefined {
      return undefined
    }
    guard message is Object(msg) else { return Json::null() }
    let field = (k : String) => msg.get(k).unwrap_or(Json::null())
    if field("text") == text {
      return Json::null()
    }
    let entry : Entry = {
      agent_identity: None,
      thread: field("thread"),
      n: 0.0,
      kind: "edit",
      target: field("n"),
      ts: Json::null(),
      author_kind: text_of(field("authorKind")).unwrap_or(""),
      author: text_of(field("author")).unwrap_or(""),
      text,
      attachments: values_of(field("attachments")),
      quotes: values_of(field("quotes")),
      declared: Json::null(),
      client: Json::null(),
      profile: Json::null(),
      runtime: Json::null(),
      options: None,
      card: None,
      at: self.now_json(),
      letter: None,
      change: None,
    }
    self.append(entry, changes)
    field("thread")
  })
}

///|
pub fn Store::edit_message(self : Store, surface : Json, channel : Json, thread_ts : Json, ts : Json, text : Json) -> Json raise {
  let r = self.edit(surface, channel, thread_ts, ts, text, false)
  if r == undefined {
    Json::null()
  } else {
    r
  }
}

///|
pub fn Store::edit_message_if_ready(self : Store, surface : Json, channel : Json, thread_ts : Json, ts : Json, text : Json) -> Json raise {
  self.edit(surface, channel, thread_ts, ts, text, true)
}

// ── entries ──

///|
pub fn Store::last_entry(self : Store, thread : Json) -> Json raise {
  match self.one("SELECT MAX(n) AS n FROM entries WHERE thread = ?", [thread]) {
    Some(r) if !(col(r, "n") is Null) => col(r, "n")
    _ => jint(0)
  }
}

///|
pub fn Store::entries_before(self : Store, thread : Json, n : Json, limit : Json) -> Json raise {
  let before = if n is Null { i64_max } else { n }
  let rows = self.all("SELECT * FROM entries WHERE thread = ? AND n < ? ORDER BY n DESC LIMIT ?", [thread, before, limit])
  rows.rev_in_place()
  Json::array(rows.map(entry_of_row))
}

///|
pub fn Store::entries_between(self : Store, thread : Json, from : Json, to : Json) -> Json raise {
  Json::array(self.all("SELECT * FROM entries WHERE thread = ? AND n >= ? AND n <= ? ORDER BY n", [thread, from, to]).map(entry_of_row))
}

///|
fn is_safe_integer(v : Json) -> Bool {
  v is Number(n, ..) && @jsjson.is_safe_integer(n)
}

///|
pub fn Store::message_page_entries(self : Store, thread : Json, numbers : Json) -> Json raise {
  guard numbers is Array(ns) && !ns.is_empty() else { return Json::array([]) }
  let first = ns[0]
  let mut consecutive = is_safe_integer(first)
  if consecutive {
    for i, n in ns {
      if !is_safe_integer(n) || num(n) != num(first) + i.to_double() {
        consecutive = false
        break
      }
    }
  }
  if consecutive {
    return self.entries_between(thread, first, ns[ns.length() - 1])
  }
  Json::array(self.all(message_page_entries_sql, [thread, jstr(stringify(of_json(numbers)))]).map(entry_of_row))
}

///|
pub fn Store::message_at(self : Store, thread : Json, ts : Json) -> Json raise {
  opt_row(self.one("SELECT * FROM merged WHERE thread = ? AND ts = ?", [thread, ts]), message_of)
}

///|
pub fn Store::message_at_if_ready(self : Store, thread : Json, ts : Json) -> Json raise {
  self.snapshot("bounded_message_at", () => {
    if legacy_merged_read_ready(self.db) {
      return self.message_at(thread, ts)
    }
    guard self.one("SELECT CAST(n AS TEXT) AS n FROM entries WHERE thread = ? AND ts = ? AND kind = 'message'", [thread, ts])
      is Some(found) else {
      return Json::null()
    }
    if legacy_merged_needs_repair(self.db) {
      return undefined
    }
    let n = text_of(col(found, "n")).unwrap_or("")
    guard bounded_edit_key(self.db, thread, n) is Ok(edit) else { return undefined }
    opt_row(self.one(last_message_with_edit_sql, [thread, jstr(n), jopt(edit)]), message_of)
  })
}

///|
pub fn Store::message_number_at(self : Store, thread : Json, ts : Json) -> Json raise {
  match self.one("SELECT n FROM entries WHERE thread = ? AND ts = ? AND kind = 'message'", [thread, ts]) {
    Some(r) => col(r, "n")
    None => Json::null()
  }
}

///|
pub fn Store::card_at(self : Store, thread : Json, ts : Json) -> Json raise {
  match self.one("SELECT card FROM entries WHERE thread = ? AND ts = ? AND kind = 'message'", [thread, ts]) {
    Some(r) =>
      match parsed(col(r, "card")) {
        Some(c) => to_json(c)
        None => Json::null()
      }
    None => Json::null()
  }
}

///|
pub fn Store::messages_before(self : Store, thread : Json, n : Json, limit : Json) -> Json raise {
  Json::array(self.messages_before_rows(thread, n, limit))
}

///|
fn Store::messages_before_rows(self : Store, thread : Json, n : Json, limit : Json) -> Array[Json] raise {
  let before = if n is Null { i64_max } else { n }
  let rows = self.all(if self.legacy_said { legacy_messages_before_sql } else { messages_before_sql }, [thread, before, limit])
  let out = rows.map(message_of)
  out.rev_in_place()
  out
}
