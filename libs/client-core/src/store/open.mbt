// A chat opened: its first view made of what the device holds, reading by what it shows and writing nothing. Three
// statements whatever the account holds: the entries of its window (`entry`, by its key), the trees of their words
// (`md_kept`, one statement for the page: `MdStore::preload`), and when the chat was last opened (`log_use`, by its
// key). That it was opened now is pending in the store, written with what showing it noted (`MdStore::flush_turn`).

///|
/// How many entries back from its end a chat's window is read at most, for `rows` messages: what the thread holds
/// of edits and letters between them counted too (topics.ts reads `WINDOW`, three pages, at most).
pub fn window_read_most(rows : Int) -> Int {
  rows * 3
}

///|
let sql_window_end : String = "SELECT n, json FROM entry WHERE station = ? AND thread = ? ORDER BY n DESC LIMIT ?"

///|
let sql_window_at : String = "SELECT n, json FROM entry WHERE station = ? AND thread = ? AND n BETWEEN ? AND ? ORDER BY n"

///|
/// What a chat's page shows first, made of what the device holds.
#derive(Debug)
pub(all) struct ChatOpenView {
  station : String
  thread : Int
  /// The entries of its window, in order.
  entries : Array[Entry]
  /// The trees of their words kept (an entry's `md_key` of its `md_words`), as JSON.
  trees : Map[String, String]
  /// The keys of words no tree is kept for, nor an older reading's: to be read, then `MdStore::put_prepared`.
  unread : Array[String]
  /// When it was opened before this, if ever.
  last_opened : Int64?
}

///|
/// Opens `thread` of the store's station: `rows` messages at its end, or at `at` (an unread message, a place it was
/// left at) a screen's context each side. Read at `now`, which is noted as when it was opened, pending.
pub fn open_chat(
  store : MdStore,
  thread : Int,
  rows? : Int = 30,
  at? : Int,
  now~ : Int64,
) -> ChatOpenView raise @shell.ShellError {
  let station = Json::string(store.station)
  let id = Json::number(thread.to_double())
  let read = match at {
    Some(a) =>
      store.db.all(sql_window_at, params=[
        station,
        id,
        Json::number((a - rows).to_double()),
        Json::number((a + rows - 1).to_double()),
      ])
    None => {
      let back = store.db.all(sql_window_end, params=[
        station,
        id,
        Json::number(window_read_most(rows).to_double()),
      ])
      back.rev()
    }
  }
  let all : Array[Entry] = []
  for r in read {
    let json : Json = @json.parse(@sql.col_text(r, 1)) catch {
      _ => Json::null()
    }
    all.push(Entry::of_json(@sql.col_int(r, 0), json))
  }
  let (from, to) = first_shown_window(all, rows, at?)
  let entries = all[from:to].to_owned()
  // The trees of the page, in one statement; each text's key worked out once.
  let keyed : Map[String, String] = Map([])
  for e in entries {
    if e.md_words() is Some(text) && !keyed.contains(text) {
      keyed.set(text, md_key(text))
    }
  }
  let keys = keyed.values().collect()
  store.preload(keys)
  let trees : Map[String, String] = Map([])
  let unread : Array[String] = []
  for key in keys {
    match store.get(key, now) {
      Some(json) => trees.set(key, json)
      None =>
        match store.older_kept(key) {
          Some(old) =>
            match store.get(old, now) {
              Some(json) => trees.set(key, json)
              None => unread.push(key)
            }
          None => unread.push(key)
        }
    }
  }
  let last_opened = store.last_opened("entry", thread.to_string())
  store.note_opened("entry", thread.to_string(), now)
  { station: store.station, thread, entries, trees, unread, last_opened }
}
