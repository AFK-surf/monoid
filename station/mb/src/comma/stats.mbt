// What Comma keeps of the workspace through a Comma connect (station/src/comma/stats.ts), as a Comma station sends of
// its own, of this station and of the other stations of its workspace (read of them as `outflow.read`, peer.mbt):
// - the Stats index (`stats.index`), source `stillfail`: what the agents spent, by day, chat, person, account and
//   model, and the chats they worked in;
// - the Task index (`task.index`): the chats as Comma lists the Tasks its stations host, which the Router reads and
//   writes in through the connect (`task.read`, `task.say`, surface.mbt), each with what it asks of whom now
//   (`attention`, `waits_for`, `note`) and its link in the app (`url`), and `router: true` when a Comma Router ever
//   wrote in it.
// Both cover the last BUILD_DAYS, are kept per workspace under <data>/comma-indexes, numbered as their rows change,
// and each connection sends Comma what it does not hold yet, a page at a time.
//
// Built as Comma first connects, a minute after the agents' spending was recorded, as a chat moves or someone reads
// one (a minute after too), and every hour (another station's changes reach it so); one build at a time.

///|
/// The days a build takes again: what can still change (a call recorded late, a chat going on).
pub let build_days : Int = 31

///|
let day_ms : Double = 86400000.0

///|
let settle_ms : Int = 60000

///|
/// How long a statement on the statistics' database waits for another process's write (a handover's) before SQLite
/// refuses it.
pub let busy_ms : Int = 5000

///|
let every_ms : Int = 3600000

///|
/// A writer that keeps committing while the old rows are classified can keep dirtying them indefinitely. After several
/// such turns, apply the still-dirty rows with the original predicate instead of never finishing the build.
let active_repair_turns : Int = 4

///|
/// The source the rows are of, as Comma's analysis names it.
pub let source : String = "stillfail"

///|
let sep : String = "\u{0}"

///|
/// Comma keeps at most this many characters of a Task's title, and of its creator.
let max_title : Int = 120

///|
let max_text : Int = 200

///|
/// What one station of the workspace gave: its usage rows (`outflowUsage`'s) and chats (`outflowChats`'), and the
/// people its rows name. `station`: another station's id; None for this one.
pub(all) struct StationRows {
  station : String?
  usage : J
  chats : Array[J]
}

///|
/// What a build reads: this station's rows, and those of each other station of the workspace that answered
/// (`unread`, the ids of those that did not: their rows stay as they were), and whether it is still to be used.
pub(all) struct ReadRows {
  stations : Array[StationRows]
  unread : Array[String]
  valid : (() -> Bool)?
}

///|
/// A build's read: from `from` until `to` (ms).

///|
/// A row as an index keeps it.
pub(all) struct IndexRow {
  key : String
  source : String
  kind : String
  rev : Double
  removed : Bool
  json : String
}

///|
pub fn IndexRow::to_j(self : IndexRow) -> J {
  jobj([
    ("key", jstr(self.key)),
    ("source", jstr(self.source)),
    ("kind", jstr(self.kind)),
    ("rev", Num(self.rev)),
    ("removed", Bool(self.removed)),
    ("json", jstr(self.json)),
  ])
}

///|
/// A chat as the Task index and the Router name it: its thread here, `<thread>@<station>` on another station.
pub fn chat_ref(thread : Double, station : String?) -> String {
  match station {
    None => num_text(thread)
    Some(s) => "\{num_text(thread)}@\{s}"
  }
}

///|
/// The chat a Task index ref names, as chat_ref made it; None for anything else.
pub fn chat_of(ref_ : String) -> (Double, String?)? {
  // /^([0-9]+)(?:@(.+))?$/: `.` takes no line terminator
  let n = ref_.length()
  let mut i = 0
  while i < n && ref_.unsafe_charcode_at(i) >= '0' && ref_.unsafe_charcode_at(i) <= '9' {
    i += 1
  }
  if i == 0 {
    return None
  }
  let digits = ref_.unsafe_substring(start=0, end=i)
  let station = if i == n {
    None
  } else if ref_.unsafe_charcode_at(i) == '@' && i + 1 < n {
    let rest = ref_.unsafe_substring(start=i + 1, end=n)
    for k in 0..<rest.length() {
      if rest.unsafe_charcode_at(k) is (0x0a | 0x0d | 0x2028 | 0x2029) {
        return None
      }
    }
    Some(rest)
  } else {
    return None
  }
  let thread = js_number(digits)
  if thread == thread.floor() && thread <= 9007199254740991.0 && thread > 0.0 {
    Some((thread, station))
  } else {
    None
  }
}

///|
/// Who a person is, as Comma counts them: their email, so one heard in the app and in a chat app adds up to one, else
/// their name, else the station's reference.
fn who(person : J?, ref_ : J) -> J {
  match prop(person, "email") {
    Some(Str(u)) if u.length() > 0 => return Str(u)
    _ => ()
  }
  match prop(person, "name") {
    Some(Str(u)) if u.length() > 0 => return Str(u)
    _ => ()
  }
  ref_
}

///|
/// A string's first `max` characters; None for anything else, or none.
fn cut(value : J?, max : Int) -> String? {
  match value {
    Some(Str(u)) if u.length() > 0 => Some(first_points(utext(u), max))
    _ => None
  }
}

///|
/// A chat's state as a Comma Task's status: at work, waiting for a person, done, archived.
fn status_of(chat : J) -> String {
  if prop(Some(chat), "archived") is Some(Bool(true)) {
    return "archived"
  }
  match str_of(prop(Some(chat), "state")) {
    Some("need_human") => "needs_review"
    Some("all_done") | Some("ended") => "done"
    _ => "in_progress"
  }
}

///|
/// A row's JSON: given fields, undefined left out.
fn row_json(fields : Array[(String, J?)]) -> String {
  stringify(jo(fields))
}

///|
/// `a ?? null`.
fn qn(v : J?) -> J? {
  Some(or_null(nullish(v, None)))
}

///|
/// A property key as JavaScript makes one of a value (`people[r.person]`).
fn key_text(v : J?) -> String {
  match v {
    None => "undefined"
    Some(v) => js_text(v)
  }
}

///|
/// `[...].join(SEP)`: null and undefined as nothing, the rest as `String(v)`.
fn join_key(parts : Array[J?]) -> String {
  parts
  .map(p => match p {
    None | Some(Null) => ""
    Some(v) => js_text(v)
  })
  .join(sep)
}

///|
/// One station's Stats index rows, by key.
pub fn stats_rows_of(given : StationRows, from_day : String) -> Map[String, (String, String)] {
  let at : Array[J?] = match given.station {
    None => []
    Some(s) => [Some(jstr("@" + s))]
  }
  let station : Array[(String, J?)] = match given.station {
    None => []
    Some(s) => [("station", Some(jstr(s)))]
  }
  let people = nullish(prop(Some(given.usage), "people"), Some(Obj([])))
  let rows : Map[String, (String, String)] = {}
  let usage_rows = arr_of(prop(Some(given.usage), "rows")).unwrap_or([])
  for r in usage_rows {
    let rr = Some(r)
    let day = match prop(rr, "day") {
      Some(Str(u)) => utext(u)
      _ => continue
    }
    guard prop(rr, "session") is Some(Str(session)) else { continue }
    if units_cmp(day, from_day) < 0 {
      continue
    }
    let person = prop(rr, "person")
    let json = row_json(
      [
        ("day", Some(jstr(day))),
        ("session", Some(Str(session))),
        ("thread", qn(prop(rr, "thread"))),
        ("person", Some(who(prop(people, key_text(person)), or_null(nullish(person, None))))),
        ("personRef", qn(person)),
        ("account", qn(prop(rr, "account"))),
        ("runtime", prop(rr, "runtime")),
        ("model", qn(prop(rr, "model"))),
        ("calls", prop(rr, "calls")),
        ("input", prop(rr, "input")),
        ("cacheRead", prop(rr, "cacheRead")),
        ("cacheWrite", prop(rr, "cacheWrite")),
        ("output", prop(rr, "output")),
        ("cost", qn(prop(rr, "cost"))),
      ] +
      station,
    )
    let key = join_key(
      [Some(jstr(source)), Some(jstr("usage"))] +
      at +
      [
        Some(jstr(day)),
        Some(Str(session)),
        Some(or_null(nullish(person, Some(jstr(""))))),
        Some(or_null(nullish(prop(rr, "account"), Some(jstr(""))))),
        prop(rr, "runtime"),
        Some(or_null(nullish(prop(rr, "model"), Some(jstr(""))))),
      ],
    )
    rows[key] = ("usage", json)
  }
  for c in given.chats {
    let cc = Some(c)
    guard prop(cc, "thread") is Some(Num(thread)) else { continue }
    let creator = prop(cc, "creator")
    let json = row_json(
      [
        ("thread", Some(Num(thread))),
        ("surface", nullish(prop(cc, "surface"), Some(jstr("unknown")))),
        ("title", nullish(prop(cc, "title"), Some(jstr("")))),
        ("state", qn(prop(cc, "state"))),
        (
          "creator",
          Some(
            match creator {
              None | Some(Null) => Null
              Some(v) => who(Some(v), or_null(nullish(prop(Some(v), "ref"), None)))
            },
          ),
        ),
        ("createdAt", nullish(prop(cc, "createdAt"), Some(Num(0.0)))),
        ("lastActiveAt", nullish(prop(cc, "lastActiveAt"), Some(Num(0.0)))),
        ("archived", Some(Bool(prop(cc, "archived") is Some(Bool(true))))),
        ("agents", nullish(prop(cc, "agents"), Some(Arr([])))),
      ] +
      station,
    )
    let key = join_key([Some(jstr(source)), Some(jstr("task"))] + at + [Some(Num(thread))])
    rows[key] = ("task", json)
  }
  rows
}

///|
/// What a Task asks of someone, as Comma takes it: Comma's bounds on whom (`waits_for`), its sentence and its link.
let attention_kinds : Array[String] = ["need", "done", "failed"]

///|
let max_waits : Int = 8

///|
let max_note : Int = 300

///|
let max_url : Int = 500

///|
/// /^[^\s@]+@[^\s@]+$/
fn email_like(s : String) -> Bool {
  let n = s.length()
  let mut at = -1
  for i in 0..<n {
    let c = s.unsafe_charcode_at(i)
    if @jscase.is_space(c) {
      return false
    }
    if c == '@' {
      if at >= 0 {
        return false
      }
      at = i
    }
  }
  at > 0 && at < n - 1
}

///|
/// What a chat asks of whom now as a Task index row's fields: none for an archived chat, or a station from before
/// that says nothing; who it is for each a lowercase email, distinct, at most MAX_WAITS.
fn attention_fields(chat : J) -> Array[(String, J?)] {
  let a = prop(Some(chat), "attention")
  if prop(Some(chat), "archived") is Some(Bool(true)) {
    return []
  }
  let kind = match prop(a, "kind") {
    Some(Str(u)) if attention_kinds.contains(utext(u)) => utext(u)
    _ => return []
  }
  let waits : Array[String] = []
  for w in arr_of(prop(a, "waitsFor")).unwrap_or([]) {
    let email = match w {
      Str(u) => @jscase.lower(js_trim(utext(u)))
      _ => ""
    }
    if email_like(email) && email.length() <= max_text && waits.length() < max_waits && !waits.contains(email) {
      waits.push(email)
    }
  }
  let note = match prop(a, "note") {
    Some(Str(u)) => cut(Some(jstr(js_trim(utext(u)))), max_note)
    _ => None
  }
  [
    ("attention", Some(jstr(kind))),
    ("waits_for", if waits.length() > 0 { Some(Arr(waits.map(jstr))) } else { None }),
    ("note", note.map(jstr)),
  ]
}

///|
/// A chat's link in the app, as Comma takes one: https, at most MAX_URL.
fn url_of(url : J?) -> J? {
  match url {
    Some(Str(u)) if utext(u).has_prefix("https://") && u.length() <= max_url => Some(Str(u))
    _ => None
  }
}

///|
/// One station's Task index rows, by their chat's ref: what Comma lists of a Task, never its messages.
pub fn task_rows_of(given : StationRows) -> Map[String, (String, String)] {
  let rows : Map[String, (String, String)] = {}
  for c in given.chats {
    let cc = Some(c)
    guard prop(cc, "thread") is Some(Num(thread)) else { continue }
    let ref_ = chat_ref(thread, given.station)
    let agent = match prop(cc, "agents") {
      Some(Arr(items)) => if items.length() > 0 { Some(items[0]) } else { None }
      _ => None
    }
    let creator = prop(cc, "creator")
    let created_by = match creator {
      None | Some(Null) => None
      Some(v) => Some(who(Some(v), or_null(nullish(prop(Some(v), "ref"), None))))
    }
    let json = row_json(
      [
        ("task", Some(jstr(ref_))),
        ("title", Some(jstr(cut(prop(cc, "title"), max_title).unwrap_or("")))),
        ("status", Some(jstr(status_of(c)))),
        ("surface", nullish(prop(cc, "surface"), Some(jstr("unknown")))),
        ("created_by", Some(cut(created_by, max_text).map(jstr).unwrap_or(Null))),
        ("created_at", nullish(prop(cc, "createdAt"), Some(Num(0.0)))),
        ("last_activity_at", nullish(prop(cc, "lastActiveAt"), nullish(prop(cc, "createdAt"), Some(Num(0.0))))),
        ("runtime", Some(cut(prop(agent, "runtime"), 40).map(jstr).unwrap_or(Null))),
        ("model", Some(cut(prop(agent, "model"), 120).map(jstr).unwrap_or(Null))),
        ("station", given.station.map(jstr)),
      ] +
      attention_fields(c) +
      [("url", url_of(prop(cc, "url"))), ("router", if prop(cc, "router") is Some(Bool(true)) { Some(Bool(true)) } else { None })],
    )
    rows[ref_] = ("task", json)
  }
  rows
}

///|
/// Who holds a place in an index: a connection by its name, or a socket by its token.
pub(all) enum Holder {
  Named(String)
  Token(Int)
} derive(Eq, Hash)

///|
/// An index Comma keeps a copy of: rows numbered by `rev` within an `epoch`, a row gone leaving a tombstone until every
/// connection's Comma holds it.
pub struct RevIndex {
  priv db : @sql.Db
  name : String
  priv io : Io
  priv listeners : Map[Int, () -> Unit]
  priv mut next_listener : Int
  /// What each connection's Comma holds: tombstones go once every one holds them.
  priv held_by : Map[Holder, Double]
  priv mut next_token : Int
  priv mut guarded : Bool
  /// Waited on before a sender resets this index (an older sender's turn).
  ready : async () -> Unit
}

///|
pub fn RevIndex::new(db : @sql.Db, name : String, io : Io, ready? : async () -> Unit = async fn() { () }) -> RevIndex raise {
  db.exec(
    "\n      CREATE TABLE IF NOT EXISTS \{name} (key TEXT PRIMARY KEY, source TEXT NOT NULL, kind TEXT NOT NULL, rev INTEGER NOT NULL,\n        json TEXT NOT NULL, removed INTEGER NOT NULL DEFAULT 0);\n      CREATE INDEX IF NOT EXISTS \{name}_rev ON \{name} (rev);",
  )
  { db, name, io, listeners: {}, next_listener: 0, held_by: {}, next_token: 0, guarded: false, ready }
}

///|
/// Install after the old process exits: taking a schema write lock during startup could prevent handover itself.
/// Once installed, the persistent trigger also records tombstones pruned by an older binary after a downgrade.
fn RevIndex::guard_prunes(self : RevIndex) -> Unit raise {
  if self.guarded {
    return
  }
  let name = self.name
  self.db.exec(
    "CREATE TRIGGER IF NOT EXISTS \{name}_pruned AFTER DELETE ON \{name}\n      WHEN OLD.removed = 1 AND OLD.rev > COALESCE((SELECT CAST(value AS INTEGER) FROM meta WHERE key = '\{name}.pruned'), 0)\n      BEGIN\n        INSERT INTO meta (key, value) VALUES ('\{name}.pruned', CAST(OLD.rev AS TEXT))\n          ON CONFLICT (key) DO UPDATE SET value = excluded.value;\n      END;",
  )
  self.guarded = true
}

///|
pub fn RevIndex::epoch(self : RevIndex) -> String raise {
  let epoch = match self.meta("epoch") {
    Some(e) => e
    None => {
      let e = (self.io.random_hex)(16)
      self.set_meta("epoch", e)
      e
    }
  }
  // Earlier senders truncated the NUL-delimited stats keys. A new wire epoch makes Comma rebuild its copy, while an
  // older process still handing over continues to see its own epoch in the shared database. Earlier versions did not
  // keep the prune floor. Reset their copies once, including any already missing a delete.
  if self.name == "stats_index" {
    "\{epoch}.keys1.gc1"
  } else {
    "\{epoch}.gc1"
  }
}

///|
pub fn RevIndex::rev(self : RevIndex) -> Double raise {
  match self.meta("rev") {
    Some(v) => js_number(v)
    None => 0.0
  }
}

///|
pub fn RevIndex::since(self : RevIndex, since : Double, limit : Int, omit_removed_bodies? : Bool = false) -> Array[IndexRow] raise {
  // The built-in wire encoders never use a removed row's old body. Other readers still receive it.
  let body = if omit_removed_bodies {
    "CASE WHEN removed IS NOT 0 THEN '' ELSE json END AS json"
  } else {
    "json"
  }
  self.db
  .all(
    "SELECT CAST(key AS BLOB) AS key, source, kind, rev, removed, \{body} FROM \{self.name} WHERE rev > ? ORDER BY rev LIMIT ?",
    [Json::number(since), Json::number(limit.to_double())],
  )
  .map(r => {
    key: text_of_utf8(col_bytes(r, "key").unwrap_or(b"")),
    source: col_text(r, "source").unwrap_or(""),
    kind: col_text(r, "kind").unwrap_or(""),
    rev: col_num(r, "rev").unwrap_or(0.0),
    removed: col_num(r, "removed") != Some(0.0),
    json: col_json_text(r, "json"),
  })
}

///|
/// What connection `host`'s Comma holds now; tombstones every one holds go.
pub fn RevIndex::held(self : RevIndex, host : Holder, through : Double) -> Unit raise {
  self.guard_prunes()
  self.held_by[host] = through
  let mut through_all = @double.infinity
  for _, v in self.held_by {
    if v.is_nan() || v < through_all {
      through_all = v
    }
  }
  // The trigger records the highest tombstone actually removed in the same statement's transaction, including deletes
  // from older processes. Avoid a separate search of all acknowledged rows when there is nothing to delete.
  self.db.run("DELETE FROM \{self.name} WHERE removed = 1 AND rev <= ?", [Json::number(through_all)]) |> ignore
}

///|
/// A socket is a distinct reader even when it is replacing a previous socket of the same connect.
pub fn RevIndex::following(self : RevIndex) -> Holder raise {
  self.guard_prunes()
  self.next_token += 1
  let token = Token(self.next_token)
  self.held_by[token] = 0.0
  token
}

///|
pub fn RevIndex::observed(self : RevIndex, token : Holder, through : Double) -> Unit {
  if self.held_by.contains(token) {
    self.held_by[token] = through
  }
}

///|
/// Greatest revision of a tombstone already pruned; it survives disconnected senders and process restarts.
pub fn RevIndex::pruned(self : RevIndex) -> Double raise {
  match self.meta("pruned") {
    Some(v) => js_number(v)
    None => 0.0
  }
}

///|
/// Capture the floor, revision and page rows in one snapshot; callers encode only after the snapshot is released.
pub fn[T] RevIndex::snapshot(self : RevIndex, read : () -> T raise) -> T raise {
  self.db.exec("SAVEPOINT comma_index_page")
  let result = try {
    Ok(read())
  } catch {
    e => Err(e)
  }
  self.db.exec("RELEASE comma_index_page")
  match result {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
/// A connection gone: what it held no longer keeps tombstones.
pub fn RevIndex::gone(self : RevIndex, host : Holder) -> Unit {
  self.held_by.remove(host)
}

///|
/// `changed` told after each transaction that changed the index; what it answers stops it.
pub fn RevIndex::listen(self : RevIndex, changed : () -> Unit) -> () -> Unit {
  self.next_listener += 1
  let id = self.next_listener
  self.listeners[id] = changed
  () => self.listeners.remove(id)
}

///|
/// The rows `given`, written where they changed; a row not given is tombstoned where `drop` says. Inside the caller's
/// transaction; how many rows changed.
pub fn RevIndex::write(
  self : RevIndex,
  given : Map[String, (String, String)],
  drop : (J) -> Bool raise,
  candidates? : (() -> Array[Kept] raise)? = None,
) -> Int raise {
  let mut rev = self.rev()
  let mut changed = 0
  let get = "SELECT json, removed FROM \{self.name} WHERE key = ?"
  let put = "INSERT INTO \{self.name} (key, source, kind, rev, json, removed) VALUES (?, ?, ?, ?, ?, 0) ON CONFLICT (key) DO UPDATE SET rev = excluded.rev, json = excluded.json, removed = 0"
  for key, row in given {
    let had = self.db.all(get, [bind_text(key)])
    if had.length() > 0 &&
      col_num(had[0], "removed") == Some(0.0) &&
      col_text(had[0], "json") == Some(row.1) {
      continue
    }
    rev = rev + 1.0
    self.db.run(put, [bind_text(key), Json::string(source), bind_text(row.0), Json::number(rev), bind_text(row.1)])
    |> ignore
    changed += 1
  }
  // Node's SQLite text reader stops at NUL. Compare and update using the actual stored UTF-8 bytes instead.
  let keys : Set[String] = Set::new()
  for key, _ in given {
    keys.add(hex(utf8_of(key)))
  }
  let kept = match candidates {
    Some(f) => f()
    None =>
      self.db
      .all("SELECT CAST(key AS BLOB) AS key, json FROM \{self.name} WHERE removed = 0", [])
      .map(r => { key: col_bytes(r, "key").unwrap_or(b""), json: col_json_text(r, "json") })
  }
  let tombstone = "UPDATE \{self.name} SET removed = 1, rev = ? WHERE key = CAST(? AS TEXT)"
  for k in kept {
    if keys.contains(hex(k.key)) || !drop(parse_json(k.json)) {
      continue
    }
    rev = rev + 1.0
    self.db.run(tombstone, [Json::number(rev), bind_bytes(k.key)]) |> ignore
    changed += 1
  }
  if changed > 0 {
    self.set_meta("rev", num_text(rev))
  }
  changed
}

///|
/// Tells those listening, after the transaction that changed it.
pub fn RevIndex::changed(self : RevIndex) -> Unit {
  let now = []
  for _, l in self.listeners {
    now.push(l)
  }
  for l in now {
    l()
  }
}

///|
fn RevIndex::meta(self : RevIndex, key : String) -> String? raise {
  let rows = self.db.all("SELECT value FROM meta WHERE key = ?", [bind_text("\{self.name}.\{key}")])
  if rows.length() == 0 {
    None
  } else {
    match rows[0].get("value") {
      Some(Number(n, ..)) => Some(num_text(n))
      _ => col_text(rows[0], "value")
    }
  }
}

///|
fn RevIndex::set_meta(self : RevIndex, key : String, value : String) -> Unit raise {
  self.db.run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", [
    bind_text("\{self.name}.\{key}"),
    bind_text(value),
  ])
  |> ignore
}

///|
/// The UTC day of `ms` (ms since the epoch) as `new Date(ms).toISOString().slice(0, 10)` says it.
pub fn iso_day(ms : Double) -> String {
  @time.format_iso_ms(ms.floor().to_int64()).view(end_offset=10).to_string()
}

///|
/// The Stats index and the Task index of a workspace, built from what its stations give.
pub struct CommaStats {
  priv db : @sql.Db
  stats : RevIndex
  tasks : RevIndex
  priv io : Io
  priv runtime : @effect.Runtime
  priv mut building : @effect.Deferred[Unit]?
  priv mut again : Bool
  priv mut stops : Array[() -> Unit]?
  priv mut closed : Bool
  priv mut stop_retry : (() -> Unit)?
  priv read : async (Double, Double) -> ReadRows
  priv changes : (() -> Unit) -> () -> Unit
}

///|
/// `changes`: tells when the agents spent or a chat moved, until the function it answers is called. `busy`: how long a
/// statement waits for another's write before it is refused (`busy_ms`).
pub fn CommaStats::new(
  path : String,
  read : async (Double, Double) -> ReadRows,
  changes : (() -> Unit) -> () -> Unit,
  io : Io,
  runtime : @effect.Runtime,
  ready? : async () -> Unit = async fn() { () },
  busy? : Int = busy_ms,
) -> CommaStats raise {
  // Shared with the process serving as a new one starts beside it (a handover): another's write waited for, as the
  // store's is, not refused at once.
  let db = (io.open_db)(path, busy)
  db.exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
  let stats = RevIndex::new(db, "stats_index", io, ready~)
  let tasks = RevIndex::new(db, "task_index", io, ready~)
  db.exec("CREATE TABLE IF NOT EXISTS said (key TEXT PRIMARY KEY, n INTEGER NOT NULL, at INTEGER NOT NULL)")
  {
    db,
    stats,
    tasks,
    io,
    runtime,
    building: None,
    again: false,
    stops: None,
    closed: false,
    stop_retry: None,
    read,
    changes,
  }
}

///|
/// The message the Router's write `key` made here, if it made one: asked again, it is the same one.
pub fn CommaStats::said(self : CommaStats, key : String) -> Double? raise {
  let rows = self.db.all("SELECT n FROM said WHERE key = ?", [bind_text(key)])
  if rows.length() == 0 {
    None
  } else {
    match rows[0].get("n") {
      Some(Null) | None => None
      Some(Number(n, ..)) => Some(n)
      Some(_) => Some(@double.not_a_number)
    }
  }
}

///|
/// A Task's current title, if it is in the index (None: undefined). A removed Task has no title for the Router.
pub fn CommaStats::task_title(self : CommaStats, ref_ : String) -> J? raise {
  let rows = self.db.all(
    "SELECT CAST(key AS BLOB) AS key, json FROM task_index WHERE key = ? AND rev > 0 AND removed = 0",
    [bind_text(ref_)],
  )
  if rows.length() == 0 {
    return Some(jstr(""))
  }
  // The binding of an unpaired surrogate becomes U+FFFD; the ordered reader compared the decoded key to ref.
  if text_of_utf8(col_bytes(rows[0], "key").unwrap_or(b"")) != ref_ {
    return Some(jstr(""))
  }
  prop(Some(parse_json(col_json_text(rows[0], "json"))), "title")
}

///|
/// Remembers what `key` made, for BUILD_DAYS (a write asked again later than that is not one Comma retries).
pub fn CommaStats::remember(self : CommaStats, key : String, n : Double) -> Unit raise {
  let now = (self.io.now)()
  self.db.run("INSERT INTO said (key, n, at) VALUES (?, ?, ?) ON CONFLICT (key) DO NOTHING", [
    bind_text(key),
    Json::number(n),
    Json::number(now),
  ])
  |> ignore
  self.db.run("DELETE FROM said WHERE at < ?", [Json::number(now - build_days.to_double() * day_ms)]) |> ignore
}

///|
/// The directories the indexes are kept in (`at`'s and `in_workspace`'s), made once before either.
pub async fn CommaStats::make_dirs(io : Io, data : String) -> Unit {
  (io.mkdir)(data, None)
  (io.mkdir)(io.join([data, "comma-indexes"]), Some(448))
}

///|
pub fn CommaStats::at(
  data : String,
  read : async (Double, Double) -> ReadRows,
  changes : (() -> Unit) -> () -> Unit,
  io : Io,
  runtime : @effect.Runtime,
  ready? : async () -> Unit = async fn() { () },
  busy? : Int = busy_ms,
) -> CommaStats raise {
  CommaStats::new(io.join([data, "comma-stats.db"]), read, changes, io, runtime, ready~, busy~)
}

///|
/// The file a workspace's index is kept in: its whole string (lone surrogates too) as UTF-16LE, hashed.
pub fn workspace_db_name(workspace : String) -> String {
  let bytes = @jsjson.utf16le(@jsjson.units(workspace))
  sha256_hex(Bytes::from_array(FixedArray::makei(bytes.length(), i => bytes[i].to_byte())))
}

///|
/// A workspace's index is never taken from the old, unscoped index: its owner is not known after a home change.
pub fn CommaStats::in_workspace(
  data : String,
  workspace : String,
  read : async (Double, Double) -> ReadRows,
  changes : (() -> Unit) -> () -> Unit,
  io : Io,
  runtime : @effect.Runtime,
) -> CommaStats raise {
  let dir = io.join([data, "comma-indexes"])
  CommaStats::new(io.join([dir, "\{workspace_db_name(workspace)}.db"]), read, changes, io, runtime)
}

///|
/// Once Comma is connected first: builds now, a minute after a change, and every hour, until close.
pub fn CommaStats::start(self : CommaStats) -> Unit {
  if self.closed || self.stops is Some(_) {
    return
  }
  let settle : Ref[(() -> Unit)?] = Ref(None)
  let stop_changes = (self.changes)(() => {
    if settle.val is Some(_) {
      return
    }
    settle.val = Some(
      (self.io.after)(settle_ms, () => {
        settle.val = None
        self.build()
      }),
    )
  })
  let hourly : Ref[() -> Unit] = Ref(() => ())
  fn tick() {
    self.build()
    hourly.val = (self.io.after)(every_ms, tick)
  }

  hourly.val = (self.io.after)(every_ms, tick)
  self.stops = Some([
    stop_changes,
    () => match settle.val {
      Some(f) => f()
      None => ()
    },
    () => (hourly.val)(),
  ])
  self.build()
}

///|
pub fn CommaStats::close(self : CommaStats) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  match self.stop_retry {
    Some(f) => f()
    None => ()
  }
  for stop in self.stops.unwrap_or([]) {
    stop()
  }
  self.stops = None
  self.db.close()
}

///|
/// A build, after the one under way when there is one.
pub fn CommaStats::build(self : CommaStats) -> Unit {
  if self.closed {
    return
  }
  if self.building is Some(_) {
    self.again = true
    return
  }
  let now = (self.io.now)()
  let from = now - build_days.to_double() * day_ms
  let done : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.building = Some(done)
  ignore(
    self.runtime.fork_daemon("comma stats build", on_error=e => {
        self.io.info("the statistics were not read this time", [("error", Some(jstr(message_of(e))))])
        self.building = None
        ignore(done.succeed(()))
      }, async fn() {
      (async fn() {
        let got = (self.read)(from, now)
        self.apply_build(got.stations, got.unread, from, got.valid)
      })() catch {
        e => self.io.info("the statistics were not read this time", [("error", Some(jstr(message_of(e))))])
      }
      self.building = None
      ignore(done.succeed(()))
      if self.again && !self.closed {
        self.again = false
        self.build()
      }
    }),
  )
}

///|
/// Settles once the build under way (tests).
pub async fn CommaStats::settled(self : CommaStats) -> Unit {
  while self.building is Some(d) {
    d.wait() catch {
      _ => ()
    }
  }
}

///|
/// Prepared only as a build needs it. Each batch commits and yields so a first build on an old database does not
/// parse its whole history in one turn; another station's older writer is followed by the index's triggers.
async fn CommaStats::apply_build(
  self : CommaStats,
  stations : Array[StationRows],
  unread : Array[String],
  from : Double,
  valid : (() -> Bool)?,
) -> Unit {
  let valid = valid.unwrap_or(() => true)
  let mut installed = false
  let mut retry_ms = 25
  let mut version : Double? = None
  let mut active_turns = 0
  while !self.closed && valid() {
    let attempt = try {
      if !installed {
        install_stats_age(self.db)
        installed = true
      }
      let ready = stats_age_ready(self.db, max_dirty=Some(0)) || stats_age_step(self.db).1
      // Apply as soon as a batch has caught up. Yielding here would let a steady older writer dirty one row on every
      // turn and keep the build waiting even though each batch had finished all of its work.
      let mut dirty_limit : Int? = Some(0)
      if !ready && stats_age_ready(self.db, max_dirty=None) {
        let current = match self.db.all("PRAGMA data_version", []) {
          [row, ..] => col_num(row, "data_version").unwrap_or(0.0)
          _ => 0.0
        }
        active_turns = match version {
          Some(v) if current != v => active_turns + 1
          _ => 0
        }
        version = Some(current)
        // Unchanged old rows still use the index; a sustained writer's remaining dirty rows are read as before.
        if active_turns >= active_repair_turns {
          dirty_limit = None
        }
      } else if !ready {
        version = None
        active_turns = 0
      }
      // A read can become obsolete while the age index is prepared over several turns.
      if !valid() {
        return
      }
      if (ready || dirty_limit is None) &&
        self.apply_(stations, unread, from, true, dirty_limit) is Some(_) {
        return
      }
      Ok(())
    } catch {
      e => Err(e)
    }
    match attempt {
      Ok(_) => {
        retry_ms = 25
        (self.io.turn)()
      }
      Err(e) => {
        if !@sql.busy(e) {
          raise e
        }
        // A previous station can still have the database locked during handover. Retrying the finite work after a
        // backoff keeps that lock from making this build silently disappear.
        let woke : @effect.Deferred[Unit] = @effect.Deferred::new()
        let finish = () => {
          self.stop_retry = None
          ignore(woke.succeed(()))
        }
        let stop = (self.io.after)(retry_ms, finish)
        self.stop_retry = Some(() => {
          stop()
          finish()
        })
        woke.wait()
        retry_ms = if retry_ms * 2 < 2000 { retry_ms * 2 } else { 2000 }
      }
    }
  }
}

///|
/// The stations' rows from the day of `from` on, written where they changed. A usage row of those days no longer given
/// is tombstoned, and so is a chat no longer among them, but not one of a station not read this time. How many rows of
/// each index changed.
pub fn CommaStats::apply(self : CommaStats, stations : Array[StationRows], unread : Array[String], from : Double) -> (Int, Int) raise {
  self.apply_(stations, unread, from, false, Some(0)).unwrap()
}

///|
fn CommaStats::apply_(
  self : CommaStats,
  stations : Array[StationRows],
  unread : Array[String],
  from : Double,
  indexed : Bool,
  dirty_limit : Int?,
) -> (Int, Int)? raise {
  let from_day = iso_day((from / day_ms).floor() * day_ms)
  let stats : Map[String, (String, String)] = {}
  let tasks : Map[String, (String, String)] = {}
  for s in stations {
    for key, row in stats_rows_of(s, from_day) {
      stats[key] = row
    }
    for key, row in task_rows_of(s) {
      tasks[key] = row
    }
  }
  let read = fn(row : J) raise { match prop(Some(row), "station") {
    Some(Null) | None => !unread.contains("")
    Some(Str(u)) => !unread.contains(utext(u))
    Some(_) => true
  } }
  // (the write taken first: begun deferred, its read then write was refused at once while the process beside it wrote)
  self.db.exec("BEGIN IMMEDIATE")
  let changed = try {
    // Recheck in this transaction's snapshot. If preparation is no longer usable, classify again without writing a
    // partial build; any dirty rows allowed here are included and checked by the original predicate.
    if indexed && !stats_age_ready(self.db, max_dirty=dirty_limit) {
      self.db.exec("ROLLBACK")
      return None
    }
    let db = self.db
    let s = self.stats.write(
      stats,
      row => match prop(Some(row), "day") {
        None => false
        Some(day) => js_ge(day, from_day) && read(row)
      },
      candidates=if indexed {
        Some(fn() raise { stats_age_candidates(db, from_day) })
      } else {
        None
      },
    )
    let t = self.tasks.write(tasks, read)
    self.db.exec("COMMIT")
    (s, t)
  } catch {
    e => {
      self.db.exec("ROLLBACK")
      raise e
    }
  }
  if changed.0 > 0 {
    self.stats.changed()
  }
  if changed.1 > 0 {
    self.tasks.changed()
  }
  Some(changed)
}

///|
/// `v >= text` as JavaScript compares a value of any kind with a string: strings by their code units, an object or an
/// array as the string it makes, anything else as numbers (a date's string is NaN as a number: never).
fn js_ge(v : J, text : String) -> Bool {
  match v {
    Str(u) => units_cmp(utext(u), text) >= 0
    Obj(_) | Arr(_) => units_cmp(js_text(v), text) >= 0
    Null => 0.0 >= js_number(text)
    Bool(b) => (if b { 1.0 } else { 0.0 }) >= js_number(text)
    Num(n) => n >= js_number(text)
  }
}

// ── the pages a connection sends ───────────────────────────────────────────────────────────────────────────────────

///|
/// What Comma holds of an index.
pub(all) struct Held {
  epoch : String?
  through : Double
}

///|
/// A `stats.index` or `task.index` page.
pub(all) struct Page {
  epoch : String
  reset : Bool
  since : Double
  through : Double
  rows : Array[J]
}

///|
pub fn Page::to_j(self : Page) -> J {
  jobj([
    ("epoch", jstr(self.epoch)),
    ("reset", Bool(self.reset)),
    ("since", Num(self.since)),
    ("through", Num(self.through)),
    ("rows", Arr(self.rows)),
  ])
}

///|
/// Comma's bounds on a page: rows, and bytes of its rows as JSON.
pub let page_rows : Int = 200

///|
pub let page_bytes : Int = 61440

///|
/// How rows go on the wire: the Stats index's, the Task index's, or another's.
pub(all) enum Wire {
  StatsWire
  TaskWire
  OtherWire((IndexRow) -> J?)
}

///|
fn Wire::encode(self : Wire, row : IndexRow) -> J? {
  match self {
    StatsWire => stats_wire(row)
    TaskWire => task_wire(row)
    OtherWire(f) => f(row)
  }
}

///|
fn Wire::built_in(self : Wire) -> Bool {
  self is (StatsWire | TaskWire)
}

///|
/// The page that only asks what Comma holds: applying it changes nothing.
pub fn probe_page(index : RevIndex) -> Page raise {
  let rev = index.rev()
  { epoch: index.epoch(), reset: false, since: rev, through: rev, rows: [] }
}

///|
/// A Stats index row as `stats.index` carries it.
pub fn stats_wire(row : IndexRow) -> J? {
  // Keys are opaque to Comma; PostgreSQL text cannot contain NUL and its key is limited to 512 bytes.
  let key = "sf1:\{sha256_hex(utf8_of(row.key))}"
  if row.removed {
    return Some(
      jobj([
        ("key", jstr(key)),
        ("source", jstr(row.source)),
        ("kind", jstr(row.kind)),
        ("rev", Num(row.rev)),
        ("removed", Bool(true)),
      ]),
    )
  }
  let parsed = try {
    Some(parse_json(row.json))
  } catch {
    _ => None
  }
  parsed.map(r => jobj([
    ("key", jstr(key)),
    ("source", jstr(row.source)),
    ("kind", jstr(row.kind)),
    ("rev", Num(row.rev)),
    ("row", r),
  ]))
}

///|
/// A Task index row as `task.index` carries it: the Task's facts, never its messages; what it asks of whom only when
/// it asks something, its agent's one sentence of it, its link when there is one, and `router` only when a Comma
/// Router wrote in it (a station from before says nothing: absent is not known to be false).
pub fn task_wire(row : IndexRow) -> J? {
  if row.removed {
    return Some(jobj([("thread", jstr(row.key)), ("rev", Num(row.rev)), ("removed", Bool(true))]))
  }
  let t = try {
    parse_json(row.json)
  } catch {
    _ => return None
  }
  // (null's fields are a TypeError, caught as a parse failure is)
  if t is Null {
    return None
  }
  let tt = Some(t)
  let attention = prop(tt, "attention") is Some(Str(_))
  Some(
    jo([
      ("thread", Some(jstr(row.key))),
      ("rev", Some(Num(row.rev))),
      ("task", prop(tt, "task")),
      ("title", prop(tt, "title")),
      ("status", prop(tt, "status")),
      ("created_by", prop(tt, "created_by")),
      ("created_at", prop(tt, "created_at")),
      ("last_activity_at", prop(tt, "last_activity_at")),
      ("runtime", prop(tt, "runtime")),
      ("model", prop(tt, "model")),
      ("labels", Some(Arr([]))),
      ("attention", if attention { prop(tt, "attention") } else { None }),
      (
        "waits_for",
        match prop(tt, "waits_for") {
          Some(Arr(items)) if attention && items.length() > 0 => Some(Arr(items))
          _ => None
        },
      ),
      (
        "note",
        match prop(tt, "note") {
          Some(Str(u)) if attention => Some(Str(u))
          _ => None
        },
      ),
      (
        "url",
        match prop(tt, "url") {
          Some(Str(u)) => Some(Str(u))
          _ => None
        },
      ),
      ("router", if prop(tt, "router") is Some(Bool(true)) { Some(Bool(true)) } else { None }),
    ]),
  )
}

///|
/// The next page to send after Comma answered `held`; None once it holds all of the index.
pub fn next_page(
  index : RevIndex,
  held : Held,
  wire? : Wire = StatsWire,
  reset_if? : ((Double, Double, String) -> Bool)? = None,
) -> Page? raise {
  read_next_page(index, held, wire, reset_if, page_rows).page
}

///|
priv struct PageRead {
  page : Page?
  limit : Int
  taken : Int
  byte_limited : Bool
  row_limited : Bool
}

///|
/// One snapshot per page, with an optional lower row limit for a sender that has recently seen large wire rows.
fn read_next_page(
  index : RevIndex,
  held : Held,
  wire : Wire,
  reset_if : ((Double, Double, String) -> Bool)?,
  requested_rows : Int,
) -> PageRead raise {
  // A different connection can prune between reads. The floor, revision and rows must describe the same database
  // snapshot; release it before parsing and encoding the bodies, so those operations do not hold a SQLite read lock.
  let (epoch, rev, reset, since, limit, changed) = index.snapshot(fn() raise {
    let epoch = index.epoch()
    let rev = index.rev()
    // A restored or damaged database may have a floor ahead of its current revision; never restart a reset forever.
    let pruned = index.pruned()
    let floor = if pruned.is_nan() || rev.is_nan() {
      @double.not_a_number
    } else if pruned < rev {
      pruned
    } else {
      rev
    }
    let forced = match reset_if {
      Some(f) => f(floor, rev, epoch)
      None => false
    }
    let reset = held.epoch != Some(epoch) || forced
    let since = if reset { 0.0 } else { held.through }
    let mut limit = if reset { page_rows } else { requested_rows }
    let omit_removed = wire.built_in()
    let mut changed = if !reset && since >= rev {
      None
    } else {
      Some(index.since(since, limit + 1, omit_removed_bodies=omit_removed))
    }
    // Do not introduce an earlier boundary within equal revisions: the receiver acknowledges only a revision. Fall back
    // in this same snapshot to the original page size when the adaptive boundary would split one.
    match changed {
      Some(c) if limit < page_rows && c.length() > limit && c[limit - 1].rev == c[limit].rev => {
        limit = page_rows
        changed = Some(index.since(since, limit + 1, omit_removed_bodies=omit_removed))
      }
      _ => ()
    }
    (epoch, rev, reset, since, limit, changed)
  })
  guard changed is Some(changed) else {
    return { page: None, limit, taken: 0, byte_limited: false, row_limited: false }
  }
  let rows = []
  let mut bytes = 2
  let mut taken = 0
  let mut last = since
  let mut byte_limited = false
  let upto = if changed.length() < limit { changed.length() } else { limit }
  for i in 0..<upto {
    let row = changed[i]
    let sent = wire.encode(row)
    let size = match sent {
      None => 0
      Some(s) => byte_length(stringify(s)) + 1
    }
    if rows.length() > 0 && bytes + size > page_bytes {
      byte_limited = true
      break
    }
    match sent {
      Some(s) => rows.push(s)
      None => ()
    }
    bytes += size
    taken += 1
    last = row.rev
  }
  // A page short of the end brings Comma to its last row; the last page to the index's rev, past pruned tombstones.
  let through = if taken < changed.length() { last } else { rev }
  {
    page: Some({ epoch, reset, since, through, rows }),
    limit,
    taken,
    byte_limited,
    row_limited: !byte_limited && taken == limit && changed.length() > limit,
  }
}

///|
/// One socket following an index. A reset clears the receiver only on its first page; while it is paging, the socket
/// holds its acknowledged position so another sender cannot prune a tombstone it still needs.
pub struct IndexSync {
  priv index : RevIndex
  priv wire : Wire
  priv token : Holder
  priv mut resetting : Bool
  priv mut reset_floor : Double
  priv mut page_rows_ : Int
}

///|
pub fn IndexSync::new(index : RevIndex, wire? : Wire = StatsWire) -> IndexSync raise {
  {
    index,
    wire,
    token: index.following(),
    resetting: false,
    reset_floor: 0.0,
    page_rows_: page_rows,
  }
}

///|
pub fn IndexSync::next(self : IndexSync, held : Held) -> Page? raise {
  let index = self.index
  index.observed(self.token, if held.epoch == Some(index.epoch()) { held.through } else { 0.0 })
  let floor = Ref(0.0)
  let reset_if = (seen : Double, rev : Double, epoch : String) => {
    floor.val = seen
    held.epoch == Some(epoch) &&
    (held.through > rev || (held.through < seen && (!self.resetting || seen > self.reset_floor)))
  }
  let mut result = read_next_page(index, held, self.wire, Some(reset_if), self.page_rows_)
  if self.wire.built_in() && result.limit < page_rows && result.row_limited {
    // Small rows have arrived. Discard the tentative page and read a complete page in a new snapshot, so the receiver
    // does not pay an extra page wait and no rows from different snapshots are combined.
    result = read_next_page(index, held, self.wire, Some(reset_if), page_rows)
  }
  let page = result.page
  if self.wire.built_in() {
    // Learn from wire size, not stored JSON size: a large Task body can make a small wire row.
    if result.byte_limited {
      let n = 2 * (result.taken + 1)
      self.page_rows_ = if n < 8 { 8 } else if n > page_rows { page_rows } else { n }
    } else {
      self.page_rows_ = page_rows
    }
  }
  match page {
    Some(p) if p.reset => {
      self.resetting = true
      self.reset_floor = floor.val
      index.observed(self.token, 0.0)
    }
    None => {
      self.resetting = false
      index.held(self.token, held.through)
    }
    _ => ()
  }
  page
}

///|
pub fn IndexSync::close(self : IndexSync) -> Unit {
  self.index.gone(self.token)
}

///|
/// Comma's answer to a page, or None when it is not one.
pub fn held_from(result : J?) -> Held? {
  guard result is Some(Obj(_) | Arr(_)) else { return None }
  let epoch = match prop(result, "epoch") {
    None | Some(Null) => None
    Some(Str(u)) => Some(utext(u))
    Some(_) => return None
  }
  let through = match prop(result, "through") {
    Some(Num(n)) if n >= 0.0 => n
    _ => 0.0
  }
  Some({ epoch, through })
}
