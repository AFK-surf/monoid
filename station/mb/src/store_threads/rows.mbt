// Rows as rows.ts makes them (`toThread`, `toMembership`, `toSessionThread`, `toEntry`, `toMessage`, `letterEntry`,
// `letterMessage`, `cardOf`, `entryColumns`): the same fields, and those a row does not have left out as JavaScript
// leaves an undefined out of JSON.

///|
let stillfail_surface : String = "chat"

///|
/// rows.ts `ownName`: a surface or connect as it is written now, the station's own chats' names of before its name now.
fn own_name(name : Json) -> Json {
  match name {
    String("ember" | "stillfail") => Json::string(stillfail_surface)
    v => v
  }
}

///|
let station_author : String = "station"

///|
let manual : String = "manual"

///|
let auto : String = "auto"

///|
/// A column as the object property it becomes: left out where the row has no such column.
fn put_col(out : Map[String, Json], key : String, r : Map[String, Json], name : String) -> Unit {
  if r.get(name) is Some(v) {
    out[key] = v
  }
}

///|
/// rows.ts `toThread`.
fn thread_of(r : Map[String, Json]) -> Json {
  let out : Map[String, Json] = Map([])
  for pair in [
    ("id", "id"),
    ("surface", "surface"),
    ("channel", "channel"),
    ("threadTs", "thread_ts"),
    ("title", "title"),
    ("autoTitle", "auto_title"),
    ("createdBy", "created_by"),
    ("createdAt", "created_at"),
    ("home", "home"),
    ("hiddenAt", "hidden_at"),
    ("hiddenBy", "hidden_by"),
    ("shownAt", "shown_at"),
  ] {
    put_col(out, pair.0, r, pair.1)
  }
  Json::object(out)
}

///|
/// rows.ts `toSessionThread`.
fn session_thread_of(r : Map[String, Json]) -> Json {
  let out : Map[String, Json] = { "thread": thread_of(r) }
  put_col(out, "connect", r, "connect")
  Json::object(out)
}

///|
/// rows.ts `toMembership`.
fn membership_of(r : Map[String, Json]) -> Json {
  let out : Map[String, Json] = Map([])
  put_col(out, "thread", r, "thread")
  put_col(out, "session", r, "session")
  put_col(out, "connect", r, "connect")
  put_col(out, "joinedAt", r, "joined_at")
  out["leftAt"] = col(r, "left_at")
  Json::object(out)
}

///|
fn jfield_ok(v : @jsjson.JValue?, ok : (@jsjson.JValue) -> Bool) -> Bool {
  match v {
    None | Some(Null) => true
    Some(x) => ok(x)
  }
}

///|
fn is_u64(v : @jsjson.JValue) -> Bool {
  v is Num(n) && n == n.floor() && n >= 0.0 && !n.is_inf()
}

///|
fn is_u32(v : @jsjson.JValue) -> Bool {
  is_u64(v) && v is Num(n) && n <= 4294967295.0
}

///|
fn is_jstr(v : @jsjson.JValue) -> Bool {
  v is Str(_)
}

///|
/// rows.ts `attachment`: its fields in their order, unknown ones dropped; a wrong one raises.
fn attachment(a : @jsjson.JValue) -> @jsjson.JValue raise {
  guard a is Obj(_) &&
    jget(a, "name") is Some(Str(_) as name) &&
    jget(a, "path") is Some(Str(_) as path) &&
    jget(a, "size") is Some(size) &&
    is_u64(size) else {
    raise StoreError("attachment")
  }
  if !jfield_ok(jget(a, "width"), is_u32) ||
    !jfield_ok(jget(a, "height"), is_u32) ||
    !jfield_ok(jget(a, "thumbhash"), is_jstr) {
    raise StoreError("attachment")
  }
  if !jfield_ok(jget(a, "duration"), is_u64) || !jfield_ok(jget(a, "frames"), is_u32) {
    raise StoreError("attachment")
  }
  let out = [("name", name), ("path", path), ("size", size)]
  for k in ["width", "height", "thumbhash", "duration", "frames"] {
    match jget(a, k) {
      None | Some(Null) => ()
      Some(v) => out.push((k, v))
    }
  }
  jobj(out)
}

///|
/// rows.ts `quote`.
fn quote(q : @jsjson.JValue) -> @jsjson.JValue raise {
  guard q is Obj(_) &&
    jget(q, "author") is Some(Str(_) as author) &&
    jget(q, "text") is Some(Str(_) as text) &&
    jget(q, "comment") is Some(Str(_) as comment) else {
    raise StoreError("quote")
  }
  if !jfield_ok(jget(q, "ts"), is_jstr) ||
    !jfield_ok(jget(q, "role"), is_jstr) ||
    !jfield_ok(jget(q, "file"), is_jstr) {
    raise StoreError("quote")
  }
  let out = [("author", author), ("text", text), ("comment", comment)]
  for k in ["ts", "role", "file"] {
    match jget(q, k) {
      None | Some(Null) => ()
      Some(v) => out.push((k, v))
    }
  }
  jobj(out)
}

///|
/// rows.ts `fromJsonList`: a stored list read with `read`, none when it does not read or one of it is wrong.
fn from_json_list(v : Json, read : (@jsjson.JValue) -> @jsjson.JValue raise) -> Array[@jsjson.JValue] {
  guard parsed(v) is Some(Arr(items)) else { return [] }
  let out = []
  for item in items {
    let one = read(item) catch { _ => return [] }
    out.push(one)
  }
  out
}

///|
/// rows.ts `jsonList`: none for an empty list, else the list as serde writes it.
fn json_list(value : Array[@jsjson.JValue], write : (@jsjson.JValue) -> @jsjson.JValue raise) -> Json raise {
  if value.is_empty() {
    Json::null()
  } else {
    jstr(stringify(Arr(value.map(write))))
  }
}

///|
/// rows.ts `letterOf`.
fn letter_of(v : @jsjson.JValue?) -> @jsjson.JValue? {
  let l = match v {
    Some(Str(s)) => try Some(@jsjson.parse(@jsjson.text(s))) catch { _ => None }
    other => other
  }
  guard l is Some((Obj(_) | Arr(_)) as l) else { return None }
  let way = jtext(jget(l, "way"))
  guard way is Some("in" | "out") && jget(l, "title") is Some(Str(_) as title) else { return None }
  Some(
    jobj([
      ("way", Str(@jsjson.units(way.unwrap()))),
      ("title", title),
      ("link", match jget(l, "link") { Some(Str(_) as s) => s; _ => Null }),
    ]),
  )
}

///|
fn letter_of_column(v : Json) -> @jsjson.JValue? {
  match v {
    String(s) => letter_of(Some(Str(@jsjson.units(s))))
    _ => None
  }
}

///|
/// rows.ts `withChange`.
fn change_of_column(v : Json) -> @jsjson.JValue? {
  guard parsed(v) is Some(c) else { return None }
  guard c is (Obj(_) | Arr(_)) &&
    jget(c, "was") is Some((Obj(_) | Arr(_))) &&
    jget(c, "now") is Some((Obj(_) | Arr(_))) else {
    return None
  }
  Some(c)
}

///|
/// rows.ts `authorKind`.
fn author_kind_of(v : Json) -> String {
  match v {
    String("agent") => "agent"
    String("station" | "ember" | "stillfail") => station_author
    _ => "person"
  }
}

///|
/// rows.ts `toMessage`: a merged row as a MessageRow.
fn message_of(r : Map[String, Json]) -> Json {
  let out : Map[String, Json] = {
    "agentIdentity": match parsed(col(r, "agent_identity")) {
      Some(v) => to_json(v)
      None => Json::null()
    },
  }
  put_col(out, "thread", r, "thread")
  put_col(out, "n", r, "n")
  out["ts"] = match col(r, "ts") {
    Null => jstr("")
    t => t
  }
  out["authorKind"] = jstr(author_kind_of(col(r, "author_kind")))
  put_col(out, "author", r, "author")
  out["text"] = match col(r, "text") {
    Null => jstr("")
    t => t
  }
  out["attachments"] = Json::array(from_json_list(col(r, "attachments"), attachment).map(to_json))
  out["quotes"] = Json::array(from_json_list(col(r, "quotes"), quote).map(to_json))
  put_col(out, "declared", r, "declared")
  put_col(out, "client", r, "client")
  put_col(out, "createdAt", r, "created_at")
  put_col(out, "editedAt", r, "edited_at")
  if letter_of_column(col(r, "letter")) is Some(l) {
    out["letter"] = to_json(l)
  }
  Json::object(out)
}

///|
/// rows.ts `letterMessage`.
fn letter_message_of(r : Map[String, Json]) -> Json {
  let out : Map[String, Json] = { "agentIdentity": Json::null() }
  put_col(out, "thread", r, "thread")
  put_col(out, "n", r, "n")
  put_col(out, "ts", r, "ts")
  out["authorKind"] = jstr(author_kind_of(col(r, "author_kind")))
  put_col(out, "author", r, "author")
  put_col(out, "text", r, "text")
  out["attachments"] = Json::array(from_json_list(col(r, "attachments"), attachment).map(to_json))
  out["quotes"] = Json::array([])
  out["declared"] = Json::null()
  out["client"] = Json::null()
  put_col(out, "createdAt", r, "at")
  out["editedAt"] = Json::null()
  if letter_of_column(col(r, "letter")) is Some(l) {
    out["letter"] = to_json(l)
  }
  out["apart"] = Json::boolean(true)
  Json::object(out)
}

///|
/// rows.ts `toEntry`.
fn entry_of_row(r : Map[String, Json]) -> Json {
  let out : Map[String, Json] = Map([])
  if parsed(col(r, "agent_identity")) is Some(v) {
    out["agentIdentity"] = to_json(v)
  }
  put_col(out, "thread", r, "thread")
  put_col(out, "n", r, "n")
  out["kind"] = jstr(if col(r, "kind") == jstr("edit") { "edit" } else { "message" })
  put_col(out, "target", r, "target")
  put_col(out, "ts", r, "ts")
  out["authorKind"] = jstr(author_kind_of(col(r, "author_kind")))
  put_col(out, "author", r, "author")
  put_col(out, "text", r, "text")
  out["attachments"] = Json::array(from_json_list(col(r, "attachments"), attachment).map(to_json))
  out["quotes"] = Json::array(from_json_list(col(r, "quotes"), quote).map(to_json))
  put_col(out, "declared", r, "declared")
  put_col(out, "client", r, "client")
  put_col(out, "profile", r, "profile")
  out["runtime"] = col(r, "runtime")
  if parsed(col(r, "options")) is Some(v) {
    out["options"] = to_json(v)
  }
  if parsed(col(r, "card")) is Some(v) {
    out["card"] = to_json(v)
  }
  put_col(out, "at", r, "at")
  if letter_of_column(col(r, "letter")) is Some(l) {
    out["letter"] = to_json(l)
  }
  if change_of_column(col(r, "change")) is Some(c) {
    out["change"] = to_json(c)
  }
  Json::object(out)
}

///|
/// rows.ts `letterEntry`.
fn letter_entry_of(r : Map[String, Json]) -> Json {
  let out : Map[String, Json] = Map([])
  put_col(out, "thread", r, "thread")
  put_col(out, "n", r, "n")
  out["kind"] = jstr("message")
  out["target"] = Json::null()
  put_col(out, "ts", r, "ts")
  out["authorKind"] = jstr(author_kind_of(col(r, "author_kind")))
  put_col(out, "author", r, "author")
  put_col(out, "text", r, "text")
  out["attachments"] = Json::array(from_json_list(col(r, "attachments"), attachment).map(to_json))
  out["quotes"] = Json::array([])
  out["declared"] = Json::null()
  out["client"] = Json::null()
  out["profile"] = Json::null()
  out["runtime"] = Json::null()
  put_col(out, "at", r, "at")
  if letter_of_column(col(r, "letter")) is Some(l) {
    out["letter"] = to_json(l)
  }
  Json::object(out)
}

///|
/// rows.ts `cardOf`: its own card, else its options as an options card; None (undefined) where neither parses. A card
/// that is JSON's null is `Some(Null)`.
fn card_of(card : Json, options : Json) -> @jsjson.JValue? {
  match parsed(card) {
    Some(own) => Some(own)
    None =>
      match parsed(options) {
        Some(before) => Some(options_card(before))
        None => None
      }
  }
}

///|
/// rows.ts `optionsCard`.
fn options_card(options : @jsjson.JValue) -> @jsjson.JValue {
  jobj([("type", Str(@jsjson.units("options"))), ("options", options)])
}

///|
/// An entry being appended (rows.ts EntryRow): None where the TypeScript's field is undefined.
priv struct Entry {
  mut agent_identity : @jsjson.JValue?
  thread : Json
  mut n : Double
  kind : String
  mut target : Json
  ts : Json
  mut author_kind : String
  mut author : String
  mut text : Json
  mut attachments : Array[@jsjson.JValue]
  mut quotes : Array[@jsjson.JValue]
  declared : Json
  client : Json
  profile : Json
  runtime : Json
  options : @jsjson.JValue?
  mut card : @jsjson.JValue?
  at : Json
  letter : @jsjson.JValue?
  change : @jsjson.JValue?
}

///|
fn opt_stringify(v : @jsjson.JValue?) -> Json {
  match v {
    Some(x) => jstr(stringify(x))
    None => Json::null()
  }
}

///|
/// rows.ts `entryColumns`: the columns of the entries' INSERT, in store.ts `#insertEntry`'s order.
fn Entry::columns(self : Entry) -> Array[Json] raise {
  [
    self.thread,
    jnum(self.n),
    jstr(self.kind),
    self.target,
    self.ts,
    jstr(self.author_kind),
    jstr(self.author),
    self.text,
    json_list(self.attachments, attachment),
    json_list(self.quotes, quote),
    self.declared,
    self.client,
    self.profile,
    self.runtime,
    opt_stringify(self.options),
    opt_stringify(self.card),
    self.at,
    opt_stringify(self.agent_identity),
    opt_stringify(self.letter),
    opt_stringify(self.change),
  ]
}

///|
/// rows.ts `stored`: the entry as a read of it gives it once stored.
fn Entry::stored(self : Entry) -> Json raise {
  let c = self.columns()
  let names = [
    "thread", "n", "kind", "target", "ts", "author_kind", "author", "text", "attachments",
    "quotes", "declared", "client", "profile", "runtime", "options", "card", "at", "agent_identity",
    "letter", "change",
  ]
  let r : Map[String, Json] = Map([])
  for i, name in names {
    r[name] = c[i]
  }
  entry_of_row(r)
}

///|
/// rows.ts `parseProfiles`.
fn parse_profiles(raw : Json, profile : Json, pinned : Bool) -> Json {
  if raw is String(s) && !s.is_empty() {
    match (try Some(@jsjson.parse(s)) catch { _ => None }) {
      Some(Arr(items)) => {
        let list = items.filter_map(x => match x {
          Str(u) if !u.is_empty() => Some(jstr(@jsjson.text(u)))
          _ => None
        })
        if !list.is_empty() {
          return Json::array(list)
        }
      }
      _ => ()
    }
  }
  if pinned {
    Json::array([profile])
  } else {
    Json::null()
  }
}

///|
fn flag_or_null(v : Json?) -> Json {
  match v {
    None | Some(Null) => Json::null()
    Some(x) => jbool(!is_num(x, 0.0))
  }
}

///|
/// rows.ts `toSession`.
fn session_of(r : Map[String, Json]) -> Json {
  let pinned = is_num(col(r, "profile_pinned"), 1.0)
  let out : Map[String, Json] = Map([])
  put_col(out, "key", r, "key")
  put_col(out, "connect", r, "connect")
  out["scope"] = jstr(if col(r, "scope") == jstr("all") { "all" } else { "thread" })
  put_col(out, "title", r, "title")
  put_col(out, "createdBy", r, "created_by")
  put_col(out, "runtime", r, "runtime")
  put_col(out, "profile", r, "profile")
  out["profilePinned"] = jbool(pinned)
  out["profiles"] = parse_profiles(col(r, "profiles"), col(r, "profile"), pinned)
  put_col(out, "model", r, "model")
  put_col(out, "effort", r, "effort")
  if col(r, "tui") == Json::number(1.0) { out["tui"] = Json::boolean(true) }
  if col(r, "speed") is String(_) {
    out["speed"] = col(r, "speed")
  }
  out["fast"] = flag_or_null(r.get("fast"))
  out["afresh"] = flag_or_null(r.get("afresh"))
  out["context"] = if col(r, "context") is Number(_, ..) { col(r, "context") } else { Json::null() }
  out["contextBefore"] = if col(r, "context_before") is Number(_, ..) { col(r, "context_before") } else { Json::null() }
  put_col(out, "runtimeSessionId", r, "runtime_session_id")
  put_col(out, "workspace", r, "workspace")
  out["cwd"] = col(r, "cwd")
  out["ws"] = col(r, "ws")
  put_col(out, "token", r, "token")
  out["running"] = jbool(is_num(col(r, "running"), 1.0))
  put_col(out, "createdAt", r, "created_at")
  put_col(out, "lastActiveAt", r, "last_active_at")
  put_col(out, "archivedAt", r, "archived_at")
  put_col(out, "archivedBy", r, "archived_by")
  put_col(out, "shownAt", r, "shown_at")
  if col(r, "came_from") is String(s) && !s.is_empty() {
    out["from"] = col(r, "came_from")
  }
  Json::object(out)
}

///|
/// rows.ts `toEntry`: a row of the entries' table as an entry (what the admin API tells of a message it wrote).
pub fn entry_of(row : Json) -> Json {
  match row {
    Object(r) => entry_of_row(r)
    _ => Json::null()
  }
}

///|
/// rows.ts `cardOfEntry`: an entry's card, else its options as an options card; None where it has neither.
pub fn card_of_entry(e : Json) -> Json? {
  match e {
    Object(m) =>
      match m.get("card") {
        Some(c) if !(c is Null) => Some(c)
        _ =>
          match m.get("options") {
            Some(o) => Some(to_json(options_card(of_json(o))))
            None => None
          }
      }
    _ => None
  }
}
