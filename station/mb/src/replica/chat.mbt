// One chat of a station read from the copy another station keeps of it, to go on with it there while its station does
// not answer (station/src/replica/chat.ts, handoff.ts): the newest generation's batches folded (`Folded`, the fold a
// restore uses), then only that chat taken out of the fold: its thread's row, its last entries of people and agents,
// and its sessions, each part bounded.

///|
/// The most a reading takes, whatever it is asked: entries, bytes of an entry's text, bytes of the whole reading,
/// sessions, files of an entry.
pub let chat_entries_most : Int = 200

///|
pub let chat_text_most : Int = 16384

///|
pub let chat_bytes_most : Int = 1048576

///|
let chat_sessions_most : Int = 20

///|
let chat_files_most : Int = 10

///|
/// Whether a record line can be of use to the reading of chat `id` (its number as the export writes one, `stringify`),
/// seen from its text alone, so the fold takes only what it can need. The export writes a row's record as
/// `{"r":"<table>","row":{…}}` (no spaces), a file's as `{"file":…`, a transcript's as `{"tr":…` or `{"tr_del":…`.
/// A row of `threads` is taken only where its row says `"id":<id>`, one of `entries` or `thread_sessions` only where it
/// says `"thread":<id>`, each as a whole key of the row and its whole value (after `{` or `,`, before `,` or `}`: 7 is
/// not 70, and a text that holds those words holds them with its quotes escaped); every row of `sessions` (the chat's
/// are found by their keys after), every deletion of a row, of a session or of a thread, and every line not known so.
fn chat_takes(line : String, id : String) -> Bool {
  if line.has_prefix("{\"file\":") || line.has_prefix("{\"tr\":") || line.has_prefix("{\"tr_del\":") {
    return false
  }
  guard line.has_prefix("{\"r\":\"") else { return true }
  let rest = line.view(start_offset=6)
  guard rest.find("\"") is Some(end) else { return true }
  match rest.view(end_offset=end).to_string() {
    "threads" => says(line, "\"id\":" + id)
    "entries" | "thread_sessions" => says(line, "\"thread\":" + id)
    "sessions" => true
    _ => false
  }
}

///|
/// Whether `line` holds `pair` (`"key":value`) as a whole key and value of an object.
fn says(line : String, pair : String) -> Bool {
  line.contains("," + pair + ",") || line.contains("{" + pair + ",") || line.contains("," + pair + "}") || line.contains("{" + pair + "}")
}

///|
/// `s` cut to at most `most` bytes of UTF-8 at a character's end, and whether it was cut.
fn cut_to(s : String, most : Int) -> (String, Bool) {
  if utf8_length(s) <= most {
    return (s, false)
  }
  let out = StringBuilder::new()
  let mut bytes = 0
  for c in s {
    let code = c.to_int()
    let b = if code < 0x80 { 1 } else if code < 0x800 { 2 } else if code < 0x10000 { 3 } else { 4 }
    if bytes + b > most {
      break
    }
    out.write_char(c)
    bytes += b
  }
  (out.to_string(), true)
}

///|
fn chat_clamp(v : Int, low : Int, high : Int) -> Int {
  if v < low {
    low
  } else if v > high {
    high
  } else {
    v
  }
}

///|
/// A text column as it is, cut to `most` bytes; null where it is none.
fn chat_text(row : JValue, name : String, most : Int) -> JValue {
  match text_of(get(row, name)) {
    Some(t) => str(cut_to(t, most).0)
    None => Null
  }
}

///|
/// A number column as it is; null where it is none.
fn chat_num(row : JValue, name : String) -> JValue {
  match get(row, name) {
    Some(Num(d)) => Num(d)
    _ => Null
  }
}

///|
/// The most bytes of an entry's attachments read (the names of CHAT_FILES files fit in far fewer).
let chat_attached_most : Int = 65536

///|
/// An entry as the reading gives it, from its columns as the fold's query takes them out (`text` at most `most`
/// characters of it, `long` whether it had more, `attachments` its first chat_attached_most characters): its number,
/// kind, the message an edit is of, who said it, its text cut to `most` bytes (`cut`: it was), when, and the names of
/// the files it attached.
fn chat_entry(r : Map[String, Json], most : Int) -> JValue {
  let (text, cut) = cut_to(field_text(r, "text"), most)
  let names : Array[JValue] = []
  match field_text(r, "attachments") {
    "" | "[]" => ()
    a =>
      match (try { Some(@jsjson.parse(a)) } catch { _ => None }) {
        Some(Arr(items)) =>
          for x in items {
            if names.length() >= chat_files_most {
              break
            }
            match text_of(get(x, "name")) {
              Some(n) => names.push(str(cut_to(n, 300).0))
              None => ()
            }
          }
        _ => ()
      }
  }
  let num = fn(name : String) -> JValue {
    match r.get(name) {
      Some(Number(x, ..)) => Num(x)
      _ => Null
    }
  }
  Obj([
    ("n", num("n")),
    ("kind", str(if field_text(r, "kind") is "" { "message" } else { field_text(r, "kind") })),
    ("target", num("target")),
    ("author_kind", str(field_text(r, "author_kind"))),
    ("author", if r.get("author") is Some(String(a)) { str(cut_to(a, 400).0) } else { Null }),
    ("text", str(text)),
    ("cut", Bool(cut || field_num(r, "long") != 0.0)),
    ("at", num("at")),
    ("files", Arr(names)),
  ])
}

///|
/// The row of a record line.
fn chat_row(line : String) -> JValue raise {
  get(@jsjson.parse(line), "row").unwrap_or(Obj([]))
}

///|
/// The chat `thread` of the copy whose generation is in `dir` (its `head.json` and `log/`), the batches folded in a
/// database of its own at `work` (gone after): what the copy is (`origin`, `workspace`, `gen`, its station's `name`,
/// `made`, `to`), the thread's row (`thread`; null where the copy holds no such chat), its last `most_entries` entries of
/// people and agents oldest first, each text cut to `most_text` bytes (`entries`; `earlier`: how many of them before
/// those are left out), and its sessions (`sessions`). The whole is at most `most_bytes`: older entries are left out
/// first.
pub fn read_chat(host : @host.Host, sep : String, dir : String, work : String, thread : Double, most_entries : Int, most_text : Int, most_bytes : Int) -> JValue raise {
  let files = { host, sep }
  guard as_head(read_json(files, files.join([dir, "head.json"]))) is Some(head) else {
    fail("no copy here, or one of a newer station's")
  }
  let entries_most = chat_clamp(most_entries, 1, chat_entries_most)
  let text_most = chat_clamp(most_text, 16, chat_text_most)
  let bytes_most = chat_clamp(most_bytes, 65536, chat_bytes_most)
  files.remove(work) catch {
    _ => ()
  }
  let folded = Folded::new(host, work)
  let said = stringify(Num(thread))
  let read = fn() -> JValue raise {
    for b in strings_of(get(head, "batches")) {
      for line in batch_lines(files, files.join([dir, "log", b])) {
        if chat_takes(line, said) {
          folded.apply(line)
        }
      }
    }
    let db = folded.db
    let id = Json::number(thread)
    let copy : Array[(String, JValue)] = [
      ("origin", get(head, "origin").unwrap_or(Null)),
      ("workspace", get(head, "workspace").unwrap_or(Null)),
      ("gen", get(head, "gen").unwrap_or(Null)),
      ("name", get(head, "name").unwrap_or(str(""))),
      ("made", get(head, "made").unwrap_or(Num(0.0))),
      ("to", get(head, "to").unwrap_or(Num(0.0))),
    ]
    let found = db.all("SELECT line FROM rows WHERE thread = ?1 AND tbl = ?2 LIMIT 1", [id, ni(order_of("threads"))])
    guard found is [t, ..] else {
      return Obj(copy + [("thread", Null), ("entries", Arr([])), ("earlier", Num(0.0)), ("sessions", Arr([]))])
    }
    let row = chat_row(field_text(t, "line"))
    let shown : JValue = Obj([
      ("id", chat_num(row, "id")),
      ("title", chat_text(row, "title", 1000)),
      ("auto_title", chat_text(row, "auto_title", 1000)),
      ("created_by", chat_text(row, "created_by", 400)),
      ("created_at", chat_num(row, "created_at")),
      ("archived_at", chat_num(row, "archived_at")),
    ])
    // Its sessions: those its thread_sessions name, those still in the chat first, then the newest to join (the last
    // said first among those that joined at once), each as its sessions row says (by the fold's index of sessions).
    let sessions : Array[JValue] = []
    let members = db.all(
      "SELECT line FROM rows WHERE thread = ?1 AND tbl = ?2 ORDER BY json_extract(line, '$.row.left_at') IS NOT NULL, json_extract(line, '$.row.joined_at') DESC, seq DESC LIMIT ?3",
      [id, ni(order_of("thread_sessions")), ni(chat_sessions_most)],
    )
    for m in members {
      let member = chat_row(field_text(m, "line"))
      guard text_of(get(member, "session")) is Some(key) else { continue }
      let s = match db.all("SELECT line FROM rows WHERE session = ?1 AND tbl = ?2 LIMIT 1", [Json::string(key), ni(order_of("sessions"))]) {
        [r, ..] => chat_row(field_text(r, "line"))
        _ => Obj([])
      }
      sessions.push(
        Obj([
          ("key", str(cut_to(key, 200).0)),
          ("runtime", chat_text(s, "runtime", 40)),
          ("model", chat_text(s, "model", 200)),
          ("effort", chat_text(s, "effort", 40)),
          ("title", chat_text(s, "title", 1000)),
          ("cwd", chat_text(s, "cwd", 2000)),
          ("workspace", chat_text(s, "workspace", 2000)),
          ("archived_at", chat_num(s, "archived_at")),
          ("left_at", chat_num(member, "left_at")),
        ]),
      )
    }
    // Its last entries of people and agents (a station's notices left out), newest first, by its log's numbers: each
    // one's columns alone, its text and attachments cut in the query, so a long one is never read whole.
    let people = "json_extract(line, '$.row.author_kind') IN ('person', 'agent')"
    let count = match db.all("SELECT COUNT(*) AS n FROM rows WHERE thread = ?1 AND tbl = ?2 AND \{people}", [id, ni(order_of("entries"))]) {
      [r, ..] => field_num(r, "n")
      _ => 0.0
    }
    let columns = "json_extract(line, '$.row.n') AS n, json_extract(line, '$.row.kind') AS kind, json_extract(line, '$.row.target') AS target, json_extract(line, '$.row.author_kind') AS author_kind, substr(json_extract(line, '$.row.author'), 1, 400) AS author, substr(json_extract(line, '$.row.text'), 1, ?4) AS text, length(json_extract(line, '$.row.text')) > ?4 AS long, json_extract(line, '$.row.at') AS at, substr(json_extract(line, '$.row.attachments'), 1, ?5) AS attachments"
    let newest = db.all("SELECT \{columns} FROM rows WHERE thread = ?1 AND tbl = ?2 AND \{people} ORDER BY json_extract(line, '$.row.n') DESC LIMIT ?3", [
      id,
      ni(order_of("entries")),
      ni(entries_most),
      ni(text_most),
      ni(chat_attached_most),
    ])
    let rest : Array[(String, JValue)] = [("thread", shown), ("sessions", Arr(sessions))]
    let mut size = utf8_length(stringify(Obj(copy + rest))) + 64
    let kept : Array[JValue] = []
    for r in newest {
      let e = chat_entry(r, text_most)
      let b = utf8_length(stringify(e)) + 1
      if size + b > bytes_most {
        break
      }
      kept.push(e)
      size += b
    }
    kept.rev_in_place()
    let earlier = count - kept.length().to_double()
    Obj(copy + [("thread", shown), ("entries", Arr(kept)), ("earlier", Num(if earlier > 0.0 { earlier } else { 0.0 })), ("sessions", Arr(sessions))])
  }
  let out = read() catch {
    e => {
      folded.close()
      files.remove(work) catch {
        _ => ()
      }
      raise e
    }
  }
  folded.close()
  files.remove(work) catch {
    _ => ()
  }
  out
}
