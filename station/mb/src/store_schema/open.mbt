// Opening the station's database (station/src/store/store.ts `Store.open`): the connection's settings, the schema
// version checked, every table, view, index and trigger made or brought up in the order the TypeScript station makes
// them, a database of the Rust station's version 12 brought up, and the version written.

///|
/// How much of the database the connection keeps in memory, in KiB (store.ts CACHE_KIB).
let cache_kib : Int = 32 * 1024

///|
/// How long the log may grow, in pages, before the connection writes it into the database itself (WAL_PAGES).
let wal_pages : Int = 10_000

///|
/// How much of the log's file is kept once written into the database (WAL_KEEP_BYTES).
let wal_keep_bytes : Int = 64 << 20

///|
/// The connection's settings as Store.open makes them: WAL, a commit waiting for the log's write only, its own cache,
/// the log written into the database by the readers' checkpoints (here only past WAL_PAGES) and cut back to
/// WAL_KEEP_BYTES.
pub fn settle_connection(db : @sql.Db) -> Unit raise {
  db.exec("PRAGMA busy_timeout = 5000; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
  db.exec("PRAGMA cache_size = -\{cache_kib}; PRAGMA wal_autocheckpoint = \{wal_pages};")
  db.exec("PRAGMA journal_size_limit = \{wal_keep_bytes};")
}

///|
/// Opens the store's database on `db` (a connection to `path`): settings, version, schema, the upgrade from 12, as
/// Store.open does. `now`: the store's clock (ms); `archive`: where archived threads are (`<path's dir>/archive` where
/// None).
pub fn open(db : @sql.Db, host : @host.Host, path : String, now : Int64, archive? : String) -> Unit raise {
  settle_connection(db)
  let mut from = schema_version
  let mut has_tables = false
  if some_row(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sessions'") {
    has_tables = true
    from = num(first_row(db, "PRAGMA user_version"), "user_version").map(v => v.to_int()).unwrap_or(0)
    if from != schema_version && from != 12 {
      refuse(
        "\{path} has schema version \{from}; this station uses \{schema_version}. Move its data by hand, or move it aside.",
      )
    }
  }
  db.exec(schema)
  install_decision_time_index(db, share_session=true)
  install_decision_session_index(db)
  install_people_since_index(db)
  install_closed_cards_index(db)
  add_edit_index(db)
  add_archive_columns(db)
  add_runtime_session_runtime(db)
  add_thread_indexes(db)
  add_letter_column(db)
  add_client_column(db)
  add_auto_title_columns(db)
  add_thread_links_column(db)
  add_watch_column(db)
  install_active_watches(db)
  install_other_active_jobs(db)
  install_remote_queue_index(db)
  add_queue_columns(db)
  add_size_column(db)
  add_small_job_column(db)
  add_wait_watch_column(db)
  add_workspace_columns(db)
  add_conv_column(db)
  install_archive_policy_index(db)
  add_opener_title(db)
  add_led_column(db)
  add_left_column(db)
  add_project_columns(db)
  add_usage_columns(db)
  install_usage_span(db)
  add_usage_totals(db)
  if !has_compact_usage(db) {
    add_usage_compactions(db)
  }
  install_usage_compactions(db)
  install_usage_15m(db, now)
  install_usage_15m_gen(db)
  install_profile_hours(db)
  install_incremental_usage_totals(db)
  install_usage_counter(db, now)
  install_remote_runs(db)
  add_list_state(db)
  add_letters(db)
  install_post_blocks(db)
  install_workspace_activity(db)
  install_recover_waits(db)
  install_session_counts(db)
  install_session_list_index(db)
  install_session_bindings_index(db)
  install_archive_mark_index(db)
  install_session_up_jobs(db)
  install_workspace_up_jobs(db)
  install_job_name_first(db)
  add_card_outcomes(db)
  install_usage_chat_stats(db)
  add_session_turns(db)
  add_session_work(db, now)
  add_pending_cards(db)
  add_pending_system_cards(db)
  add_tell_indexes(db)
  install_said_state(db)
  ignore(install_archive_last(db))
  install_widget_sources(db)
  install_cc_index(db)
  install_session_chat_index(db)
  install_latest_thread_index(db)
  install_card_posts(db)
  rename_own_chats(db)
  let archive = match archive {
    Some(a) => a
    None => joined_path(dirname(path), "archive")
  }
  // Chats published as snapshots (gone with public sharing): what a station from before kept of them.
  remove_path(host, joined_path(dirname(archive), "published"), recursive=true)
  if from == 12 {
    upgrade_from_12(db, host, archive)
  }
  // Written only where it changes: a database already at this version is opened without taking the write lock, which
  // another process (the station before, its backfills) may hold past the busy timeout.
  if !has_tables || from != schema_version {
    db.exec("PRAGMA user_version = \{schema_version}")
  }
}

///|
/// A path's directory (node:path `dirname` of a path with `/` or, on Windows, `\`).
fn dirname(path : String) -> String {
  @nodepath.dirname("\\", path)
}

///|
fn joined_path(dir : String, name : String) -> String {
  if dir.has_suffix("/") || dir.has_suffix("\\") {
    dir + name
  } else {
    dir + "/" + name
  }
}

///|
/// A file or directory taken away, none being there no failure (`rmSync(…, { force: true })`).
fn remove_path(host : @host.Host, path : String, recursive? : Bool = false) -> Unit {
  ignore(
    (try {
      host.shell_sync("fs.remove", { "path": Json::string(path), "recursive": Json::boolean(recursive) })
    } catch {
      _ => Json::null()
    }),
  )
}

///|
/// A thread's archive file as the Rust station wrote it (archive.ts `threadFile`).
fn thread_file(archive : String, thread : String) -> String {
  joined_path(joined_path(archive, "threads"), "\{thread}.jsonl.zst")
}

///|
/// A JavaScript number as `String(n)` writes an integer (the archive file's name, an error's words).
fn integer_text(v : Json) -> String {
  match v {
    Number(_, repr=Some(text)) => text
    Number(n, ..) => if n == n.floor() && n.abs() < 1.0e21 { n.to_int64().to_string() } else { n.to_string() }
    String(s) => s
    _ => "null"
  }
}

///|
/// A thread's archive file's entries (archive.ts `readArchive`): none where it is not there.
fn read_archive(host : @host.Host, path : String) -> Array[@jsjson.JValue] raise {
  let hex = match host.shell_sync("fs.bytes", { "path": Json::string(path), "zstd": true }) {
    String(h) => h
    _ => return []
  }
  let text = @utf8.decode_lossy(@hex.decode(hex)).to_array()
  let out = []
  let mut start = 0
  for i = 0; i <= text.length(); i = i + 1 {
    if i < text.length() && text[i] != '\n' {
      continue
    }
    let end = if i > start && text[i - 1] == '\r' { i - 1 } else { i }
    if end > start {
      out.push(@jsjson.parse(String::from_array(text[start:end])))
    }
    start = i + 1
  }
  out
}

///|
/// What a JavaScript value reads as in a template (`${v}`), for an error's words.
fn js_text(v : @jsjson.JValue?) -> String {
  @jsjson.jval_js_str(v)
}

///|
/// A value as SQLite is given it by node:sqlite (a number, a string, null).
fn bound(v : @jsjson.JValue?) -> Json {
  match v {
    Some(Num(n)) => Json::number(n)
    Some(Str(s)) => Json::string(@jsjson.sanitize_str(s))
    Some(Bool(b)) => Json::boolean(b)
    _ => Json::null()
  }
}

///|
/// `v ?? null`, then as bound.
fn or_null(v : @jsjson.JValue?) -> Json {
  bound(v)
}

///|
fn is_str(v : @jsjson.JValue?) -> Bool {
  v is Some(Str(_))
}

///|
fn is_u64(v : @jsjson.JValue?) -> Bool {
  match v {
    Some(Num(n)) => !n.is_nan() && !n.is_inf() && n == n.floor() && n >= 0.0
    _ => false
  }
}

///|
fn is_u32(v : @jsjson.JValue?) -> Bool {
  is_u64(v) && (match v {
    Some(Num(n)) => n <= 4294967295.0
    _ => false
  })
}

///|
fn absent(v : @jsjson.JValue?) -> Bool {
  v is None || v is Some(Null)
}

///|
/// rows.ts `attachment`: its fields in their order, unknown ones dropped, a wrong one failing.
fn attachment(a : @jsjson.JValue) -> @jsjson.JValue raise {
  guard a is Obj(_) else { refuse("attachment") }
  if !is_str(a.get("name")) || !is_str(a.get("path")) || !is_u64(a.get("size")) {
    refuse("attachment")
  }
  let opt = (k : String, ok : (@jsjson.JValue?) -> Bool) => absent(a.get(k)) || ok(a.get(k))
  if !opt("width", is_u32) || !opt("height", is_u32) || !opt("thumbhash", is_str) {
    refuse("attachment")
  }
  if !opt("duration", is_u64) || !opt("frames", is_u32) {
    refuse("attachment")
  }
  let out = [
    ("name", a.get("name").unwrap()),
    ("path", a.get("path").unwrap()),
    ("size", a.get("size").unwrap()),
  ]
  for k in ["width", "height", "thumbhash", "duration", "frames"] {
    if !absent(a.get(k)) {
      out.push((k, a.get(k).unwrap()))
    }
  }
  Obj(out)
}

///|
/// rows.ts `quote`.
fn quote(q : @jsjson.JValue) -> @jsjson.JValue raise {
  guard q is Obj(_) else { refuse("quote") }
  if !is_str(q.get("author")) || !is_str(q.get("text")) || !is_str(q.get("comment")) {
    refuse("quote")
  }
  let opt = (k : String) => absent(q.get(k)) || is_str(q.get(k))
  if !opt("ts") || !opt("role") || !opt("file") {
    refuse("quote")
  }
  let out = [
    ("author", q.get("author").unwrap()),
    ("text", q.get("text").unwrap()),
    ("comment", q.get("comment").unwrap()),
  ]
  for k in ["ts", "role", "file"] {
    if !absent(q.get(k)) {
      out.push((k, q.get(k).unwrap()))
    }
  }
  Obj(out)
}

///|
/// rows.ts `jsonList` of a list read as serde reads it (`(e.list ?? []).map(read)`): none for an empty one.
fn json_list(v : @jsjson.JValue?, read : (@jsjson.JValue) -> @jsjson.JValue raise) -> Json raise {
  let items = match v {
    None | Some(Null) => []
    Some(Arr(items)) => items
    Some(_) => refuse("\{js_text(v)}.map is not a function")
  }
  if items.length() == 0 {
    return Json::null()
  }
  let out = []
  for i in items {
    out.push(read(i))
  }
  Json::string(@jsjson.stringify(Arr(out)))
}

///|
/// `JSON.stringify` of what is there (undefined and null: none).
fn stringified(v : @jsjson.JValue?) -> Json {
  match v {
    None | Some(Null) => Json::null()
    Some(x) => Json::string(@jsjson.stringify(x))
  }
}

///|
/// rows.ts `letterOf` of an archived entry's letter, as its column keeps it.
fn letter_column(v : @jsjson.JValue?) -> Json {
  let l = match v {
    Some(Str(s)) => (try Some(@jsjson.parse(@jsjson.sanitize_str(s))) catch { _ => None })
    other => other
  }
  guard l is Some(Obj(_) as letter) else { return Json::null() }
  let way = match letter.get("way") {
    Some(Str(w)) if @jsjson.sanitize_str(w) == "in" || @jsjson.sanitize_str(w) == "out" => Some(@jsjson.JValue::Str(w))
    _ => None
  }
  guard way is Some(way) && letter.get("title") is Some(Str(_) as title) else { return Json::null() }
  let link = match letter.get("link") {
    Some(Str(_) as s) => s
    _ => Null
  }
  Json::string(@jsjson.stringify(Obj([("way", way), ("title", title), ("link", link)])))
}

///|
/// rows.ts `withChange` of an archived entry's change, as its column keeps it.
fn change_column(v : @jsjson.JValue?) -> Json {
  let c = match v {
    Some(Str(s)) => (try Some(@jsjson.parse(@jsjson.sanitize_str(s))) catch { _ => None })
    other => other
  }
  match c {
    Some(Obj(_) as change) =>
      if change.get("was") is Some(Obj(_)) && change.get("now") is Some(Obj(_)) {
        Json::string(@jsjson.stringify(change))
      } else {
        Json::null()
      }
    _ => Json::null()
  }
}

///|
/// An archived entry's columns, as `#insertEntry` writes `entryColumns(archivedEntry(line))`.
fn archived_columns(e : @jsjson.JValue) -> Array[Json] raise {
  let kind = match e.get("kind") {
    Some(Str(k)) if @jsjson.sanitize_str(k) == "message" || @jsjson.sanitize_str(k) == "edit" => @jsjson.sanitize_str(k)
    other => refuse("unknown entry kind \{js_text(other)}")
  }
  let author_kind = match e.get("authorKind") {
    Some(Str(k)) =>
      match @jsjson.sanitize_str(k) {
        "agent" => "agent"
        "station" | "ember" | "stillfail" => "station"
        "person" => "person"
        s => refuse("unknown author kind \{s}")
      }
    other => refuse("unknown author kind \{js_text(other)}")
  }
  [
    bound(e.get("thread")),
    bound(e.get("n")),
    Json::string(kind),
    or_null(e.get("target")),
    or_null(e.get("ts")),
    Json::string(author_kind),
    bound(e.get("author")),
    or_null(e.get("text")),
    json_list(e.get("attachments"), attachment),
    json_list(e.get("quotes"), quote),
    or_null(e.get("declared")),
    or_null(e.get("client")),
    or_null(e.get("profile")),
    or_null(e.get("runtime")),
    stringified(e.get("options")),
    stringified(e.get("card")),
    bound(e.get("at")),
    stringified(e.get("agentIdentity")),
    letter_column(e.get("letter")),
    change_column(e.get("change")),
  ]
}

///|
/// A database of the Rust station's version 12 brought up (store.ts `#upgradeFrom12`): every chat it archived to a
/// file brought back in, its entries written without rebuilding the decision statistics of before, the file then
/// taken away; what only the Rust station used dropped.
fn upgrade_from_12(db : @sql.Db, host : @host.Host, archive : String) -> Unit raise {
  for r in db.all("SELECT id FROM threads WHERE archived_at IS NOT NULL ORDER BY id", []) {
    let thread = r.get("id").unwrap_or(Json::null())
    let file = thread_file(archive, integer_text(thread))
    let entries = read_archive(host, file)
    let mut old_cards = false
    let mut last_person : Double? = None
    for e in entries {
      let message = e.get("kind") is Some(Str(k)) && @jsjson.sanitize_str(k) == "message"
      let author = match e.get("authorKind") {
        Some(Str(k)) => @jsjson.sanitize_str(k)
        _ => ""
      }
      if message && author == "agent" {
        let card = match e.get("card") {
          Some(Null) | None =>
            match e.get("options") {
              Some(Arr(_) as options) =>
                Some(@jsjson.JValue::Obj([("type", @jsjson.JValue::Str("options")), ("options", options)]))
              _ => None
            }
          other => other
        }
        if card is Some(c) &&
          c.get("type") is Some(Str(t)) &&
          @jsjson.sanitize_str(t) == "options" &&
          c.get("options") is Some(Arr(_)) {
          old_cards = true
        }
      }
      if message && author == "person" {
        if e.get("n") is Some(Num(n)) {
          last_person = Some(
            match last_person {
              Some(p) => if p > n { p } else { n }
              None => n
            },
          )
        }
      }
    }
    let rows = entries.map(archived_columns)
    immediate(db, () => {
      let may_answer = match last_person {
        Some(p) =>
          some_row(db, "SELECT 1 FROM card_outcomes WHERE thread = ? AND n < ? LIMIT 1", params=[thread, Json::number(p)])
        None => false
      }
      let outcomes = if old_cards || may_answer {
        db
        .all(
          "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND name IN\n          ('card_outcomes_asked', 'card_outcomes_answered') ORDER BY name",
          [],
        )
        .filter(t => if t.get("name") == Some(Json::string("card_outcomes_asked")) { old_cards } else { may_answer })
      } else {
        []
      }
      if old_cards {
        db.exec("DROP TRIGGER IF EXISTS card_outcomes_asked")
      }
      if may_answer {
        db.exec("DROP TRIGGER IF EXISTS card_outcomes_answered")
      }
      for columns in rows {
        ignore(
          db.run(
            "INSERT INTO entries (thread, n, kind, target, ts, author_kind, author, text, attachments, quotes, declared, client, profile, runtime, options, card, at, agent_identity, letter, change) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            columns,
          ),
        )
      }
      if entries.length() == 0 || old_cards || may_answer {
        db.exec("CREATE TABLE IF NOT EXISTS card_outcomes_incomplete (id INTEGER PRIMARY KEY)")
      }
      for t in outcomes {
        if t.get("sql") is Some(String(sql)) {
          db.exec(sql)
        }
      }
      ignore(db.run("UPDATE threads SET archived_at = NULL WHERE id = ?", [thread]))
    })
    remove_path(host, file)
  }
  db.exec("DROP INDEX IF EXISTS threads_archived; DROP TABLE IF EXISTS items;")
}

///|
/// What stations wrote for the station's own chats' surface and connect before the rename (rows.ts FORMER_OWN_NAMES).
let former_own_names : Array[String] = ["ember", "stillfail"]

///|
/// The tables that name a session's connect as they are written (schema.ts CONNECT_TABLES).
let connect_tables : Array[String] = [
  "sessions", "thread_sessions", "bindings", "connect_threads", "relayed_to", "slack_stops",
]

///|
/// schema.ts `renameOwnChats`: the station's own chats as their names are now, what stations wrote before the rename
/// written over once as the database opens, and what was made of it then made again.
fn rename_own_chats(db : @sql.Db) -> Unit raise {
  let former = former_own_names.map(n => "'\{n}'").join(",")
  let stale = (name : String) => {
    let sql = match db.all("SELECT sql FROM sqlite_master WHERE name = ?", [Json::string(name)]) {
      [row, ..] => match row.get("sql") { Some(String(s)) => Some(s); _ => None }
      _ => None
    }
    match sql {
      Some(s) => former_own_names.iter().any(n => s.contains("'\{n}'"))
      None => false
    }
  }
  let surfaces = some_row(db, "SELECT 1 FROM threads WHERE surface IN (\{former}) LIMIT 1")
  let tables = connect_tables.filter(t => exists(db, "table", t))
  let connects = tables.filter(t => some_row(db, "SELECT 1 FROM \{t} WHERE connect IN (\{former}) LIMIT 1"))
  let order = stale("cc_session_order")
  let answered = stale("pending_cards_answered")
  if !surfaces && connects.length() == 0 && !order && !answered {
    return
  }
  immediate(db, () => {
    if order {
      db.exec(
        "DROP INDEX cc_session_order; CREATE INDEX cc_session_order ON cc_session_rows(session,last_at DESC,created_at DESC,thread DESC)\n        WHERE surface != '\{stillfail_surface}';",
      )
    }
    if answered {
      db.exec(
        "DROP TRIGGER pending_cards_answered; CREATE TRIGGER pending_cards_answered AFTER INSERT ON entries\nWHEN NEW.kind = 'message' AND NEW.author_kind = 'person' AND (SELECT surface FROM threads WHERE id = NEW.thread) = '\{stillfail_surface}' BEGIN\n  DELETE FROM pending_cards WHERE thread = NEW.thread AND n < NEW.n;\nEND;",
      )
    }
    db.exec("UPDATE OR IGNORE threads SET surface = '\{stillfail_surface}' WHERE surface IN (\{former})")
    for t in tables {
      db.exec("UPDATE OR IGNORE \{t} SET connect = '\{stillfail_surface}' WHERE connect IN (\{former})")
    }
  })
}
