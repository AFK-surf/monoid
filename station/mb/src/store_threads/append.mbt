// Appending an entry and what it brings back into lists (store.ts `#append`, `#insertEntry`, `#lastKnown`,
// `#bringBack`, `#setArchived`, `#setThreadHidden`, `#outOfLists`, `manuallyArchived`).

///|
let leaders_returning : String = "RETURNING (SELECT json_group_array(parent) FROM opened_chats WHERE child_station = '' AND child = sessions.key AND parent_station = '' AND led = 1) AS leaders"

///|
/// store.ts `#lastKnown`.
fn Store::last_known(self : Store, thread : Json) -> Double raise {
  match self.one(last_known_sql, [thread]) {
    Some(r) => num(col(r, "n"))
    None => 0.0
  }
}

///|
/// store.ts `#insertEntry`.
fn Store::insert_entry(self : Store, e : Entry) -> Unit raise {
  ignore(
    self.run(
      "INSERT INTO entries (thread, n, kind, target, ts, author_kind, author, text, attachments, quotes, declared, client, profile, runtime, options, card, at, agent_identity, letter, change) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      e.columns(),
    ),
  )
}

///|
/// store.ts `#append`: the entry as the thread's next; `before` runs under the write lock, `inserted` after the entry
/// has its number, `committed` once it is committed. What it tells: the entry as a read gives it, and what it brought
/// back.
fn Store::append(
  self : Store,
  entry : Entry,
  changes : Array[Json],
  before? : (() -> Unit raise)? = None,
  try_write? : Bool = before is Some(_),
  committed? : (() -> Unit raise)? = None,
  inserted? : ((Double) -> Unit raise)? = None,
) -> Unit raise {
  if entry.kind == "message" && entry.author_kind == "agent" && entry.agent_identity is None {
    match
      self.one(
        "SELECT s.model, s.effort, CASE WHEN r.session_key IS NULL THEN s.runtime ELSE COALESCE(r.runtime, s.original_runtime, s.runtime) END AS runtime FROM sessions s LEFT JOIN runtime_sessions r ON r.session_key = s.key AND r.id = s.runtime_session_id WHERE s.key = ?",
        [jstr(entry.author)],
      ) {
      Some(r) =>
        entry.agent_identity = Some(
          jobj([("model", of_json(col(r, "model"))), ("effort", of_json(col(r, "effort"))), ("runtime", of_json(col(r, "runtime")))]),
        )
      None => ()
    }
  }
  self.tx(
    () => {
      if before is Some(f) {
        f()
      }
      let n = match self.one("SELECT MAX(n) AS n FROM entries WHERE thread = ?", [entry.thread]) {
        Some(r) if !(col(r, "n") is Null) => num(col(r, "n"))
        _ => self.last_known(entry.thread)
      }
      entry.n = n + 1.0
      self.insert_entry(entry)
      if inserted is Some(f) {
        f(entry.n)
      }
    },
    try_write~,
  )
  if committed is Some(f) {
    f()
  }
  changes.push({ "type": "thread", "id": entry.thread, "entries": [entry.stored()] })
  self.bring_back(entry.kind, entry.author_kind, entry.author, entry.thread, changes)
}

///|
/// store.ts `#outOfLists`.
fn Store::out_of_lists(self : Store, thread : Json) -> Bool raise {
  guard self.one("SELECT hidden_at FROM threads WHERE id = ?", [thread]) is Some(r) else { return false }
  if !(col(r, "hidden_at") is Null) {
    return true
  }
  let shown = self.one(
      "SELECT 1 FROM thread_sessions ts JOIN sessions s ON s.key = ts.session WHERE ts.thread = ? AND s.archived_at IS NULL LIMIT 1",
      [thread],
    )
    is Some(_)
  !shown
}

///|
/// store.ts `manuallyArchived`.
fn Store::manually_archived(self : Store, thread : Json) -> Bool raise {
  guard self.one("SELECT hidden_by FROM threads WHERE id = ?", [thread]) is Some(r) else { return false }
  if !self.out_of_lists(thread) {
    return false
  }
  if col(r, "hidden_by") == jstr(manual) {
    return true
  }
  self.one(
    "SELECT 1 FROM thread_sessions ts JOIN sessions s ON s.key = ts.session WHERE ts.thread = ? AND s.archived_by = ? LIMIT 1",
    [thread, jstr(manual)],
  )
  is Some(_)
}

///|
/// store.ts `#setArchived(key, false, by, changes)`: shown again (what bringing back does).
fn Store::set_unarchived(self : Store, key : String, by : String, changes : Array[Json]) -> Unit raise {
  let leaders : Array[Json] = []
  let mut targets : Array[String] = [key]
  self.tx(() => {
    let anchor = @sql.conversation_of(self.db, key)
    let members = @sql.members_of(self.db, anchor)
    targets = if members.is_empty() { [key] } else { members }
    if !targets.contains(key) {
      targets.push(key)
    }
    for m in targets {
      let row = self.one(
        "UPDATE sessions SET archived_at = NULL, archived_by = NULL, shown_at = COALESCE(?, shown_at) WHERE key = ? \{leaders_returning}",
        [if by == manual { self.now_json() } else { Json::null() }, jstr(m)],
      )
      match row {
        None => ()
        Some(r) => {
          let text = match col(r, "leaders") {
            String(s) => s
            Null => "[]"
            v => v.stringify()
          }
          match (try @json.parse(text) catch { _ => Json::array([]) }) {
            Array(xs) =>
              for p in xs {
                if !leaders.contains(p) {
                  leaders.push(p)
                }
              }
            _ => ()
          }
        }
      }
    }
    ignore(self.run("UPDATE threads SET hidden_at = ?, hidden_by = ? WHERE home = ?", [Json::null(), Json::null(), jstr(anchor)]))
  })
  let touched_threads : Array[Json] = []
  for m in targets {
    for t in self.session_threads_rows(m, -1) {
      let id = col(t, "id")
      if !touched_threads.contains(id) {
        touched_threads.push(id)
      }
    }
  }
  for id in touched_threads {
    changes.push({ "type": "thread", "id": id, "entries": [] })
  }
  for m in targets {
    changes.push({ "type": "session", "key": jstr(m) })
  }
  for parent in leaders {
    changes.push({ "type": "session", "key": parent })
  }
}

///|
/// store.ts `#setThreadHidden(thread, false, by, changes)`.
fn Store::set_thread_shown(self : Store, thread : Json, by : String, changes : Array[Json]) -> Unit raise {
  let shown = if by == manual { self.now_json() } else { Json::null() }
  ignore(
    self.run("UPDATE threads SET hidden_at = NULL, hidden_by = NULL, shown_at = COALESCE(?, shown_at) WHERE id = ?", [
      shown, thread,
    ]),
  )
  changes.push({ "type": "thread", "id": thread, "entries": [] })
}

///|
/// store.ts `#bringBack`: something new said brings its chat, and the sessions the station archived that hear it or
/// said it, back into lists; what was archived by hand stays so.
fn Store::bring_back(
  self : Store,
  kind : String,
  author_kind : String,
  author : String,
  thread_id : Json,
  changes : Array[Json],
) -> Unit raise {
  if kind != "message" || author_kind == station_author {
    return
  }
  guard self.one("SELECT * FROM threads WHERE id = ?", [thread_id]) is Some(thread) else { return }
  if self.manually_archived(col(thread, "id")) {
    return
  }
  let archived = self.all(
    "SELECT key FROM sessions WHERE archived_at IS NOT NULL AND archived_by IS NOT ?1 AND (key IN (SELECT session FROM thread_sessions WHERE thread = ?2) OR key = ?3)",
    [jstr(manual), thread_id, if author_kind == "agent" { jstr(author) } else { Json::null() }],
  )
  for r in archived {
    if col(r, "key") is String(key) {
      self.set_unarchived(key, auto, changes)
    }
  }
  if !(col(thread, "hidden_at") is Null) && col(thread, "home") is Null {
    self.set_thread_shown(col(thread, "id"), auto, changes)
  }
}
