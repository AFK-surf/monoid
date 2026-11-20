// Chats shared with other workspaces (chat_shares; store.ts `// ── chats shared with other workspaces ──`), read by
// their deadlines' index where it is prepared (store/chat-share-index.ts), else as the table says them.

///|
/// chat-share-index.ts DIRTY_LIMIT, SHARE_CHARS_LIMIT, SHARE_TARGET_LIMIT.
let share_dirty_limit : Int32 = 64

///|
let share_chars_limit : Int32 = 16384

///|
let share_target_limit : Int32 = 16

///|
/// chat-share-index.ts `hasChatShareIndex`: known once a connection.
fn Store::has_chat_share_index(self : Store) -> Bool raise {
  match self.share_index {
    Some(known) => known
    None => {
      let found = self.table("chat_share_index_meta")
      self.share_index = Some(found)
      found
    }
  }
}

///|
/// chat-share-index.ts `shareValues`.
fn share_values(row : Map[String, Json]) -> Array[Json]? {
  guard col(row, "shared") is String(s) && s.length() <= share_chars_limit else {
    return None
  }
  let values = share_to(to_chat_share(row))
  if values.length() > share_target_limit {
    return None
  }
  for t in values {
    let used = num_of(nullish(field(t, "used"))).unwrap_or(0.5)
    if !safe_integer(used) || !safe_integer(used + xshare_idle_ms) {
      return None
    }
  }
  Some(values)
}

///|
/// chat-share-index.ts `snapshot`: `read` in one read of its own where the index can answer, else None.
fn[T] Store::share_snapshot(
  self : Store,
  now : Double,
  read : () -> T raise,
) -> T? raise {
  if !safe_integer(now) ||
    !safe_integer(now - xshare_idle_ms) ||
    !self.has_chat_share_index() {
    return None
  }
  self.reading(() => {
    let prepared = self.one(
      "SELECT 1 FROM chat_share_index_meta WHERE id = 1 AND version = ? AND phase = 1",
      [jnum(1.0)],
    )
    let dirty = self.all(share_dirty, [
      jnum((share_dirty_limit + 1).to_double()),
    ])
    let null_key = self.one(
      "SELECT 1 FROM chat_shares WHERE session IS NULL LIMIT 1",
      [],
    )
    let uncertain = self.one("SELECT 1 FROM chat_share_uncertain LIMIT 1", [])
    if prepared is None ||
      dirty.length() > share_dirty_limit ||
      null_key is Some(_) ||
      uncertain is Some(_) {
      return None
    }
    for d in dirty {
      if self.one("SELECT * FROM chat_shares WHERE session = ?", [
          col(d, "session"),
        ])
        is Some(row) &&
        share_values(row) is None {
        return None
      }
    }
    Some(read())
  })
}

///|
fn Store::live_chat_share_rows(
  self : Store,
  now : Double,
) -> Array[Map[String, Json]]? raise {
  self.share_snapshot(now, () => {
    self.all(share_live_rows, [jnum(now - xshare_idle_ms)])
  })
}

///|
fn Store::due_chat_share_rows(
  self : Store,
  since : Double,
  now : Double,
) -> (Array[Map[String, Json]], Json)? raise {
  if !safe_integer(since) || !safe_integer(since - xshare_idle_ms) {
    return None
  }
  self.share_snapshot(now, () => {
    let rows = self.all(share_due, [
      jnum(since - xshare_idle_ms),
      jnum(now - xshare_idle_ms),
    ])
    let next = match self.one(share_next_time, [jnum(now - xshare_idle_ms)]) {
      Some(r) => jnum(num_of(col(r, "used")).unwrap_or(0.0) + xshare_idle_ms)
      None => Json::null()
    }
    (rows, next)
  })
}

///|
/// chat-share-index.ts OVERLAY.
let share_overlay : String = "SELECT c.* FROM (SELECT session FROM chat_share_dirty UNION SELECT session FROM chat_share_uncertain) k\n  CROSS JOIN chat_shares c ON c.session = k.session"

///|
fn Store::lapsed_chat_share_workspaces(
  self : Store,
  workspaces : Array[String],
  now : Double,
) -> Array[String]? raise {
  self.share_snapshot(now, () => {
    let found : Map[String, Unit] = Map([])
    let wanted : Map[String, Unit] = Map([])
    for w in workspaces {
      wanted[w] = ()
    }
    for w, _ in wanted {
      if self.one(share_lapsed_workspace, [jstr(w), jnum(now - xshare_idle_ms)])
        is Some(_) {
        found[w] = ()
      }
    }
    for row in self.all(share_overlay, []) {
      for t in share_to(to_chat_share(row)) {
        if field(t, "workspace") is Some(String(w)) &&
          wanted.contains(w) &&
          !share_live(t, now) {
          found[w] = ()
        }
      }
    }
    let out = []
    for w, _ in found {
      out.push(w)
    }
    out
  })
}

///|
fn Store::now_double(self : Store) -> Double {
  self.now().to_double()
}

///|
/// What a chat (by its session key) is shared with now, if anything.
pub fn Store::chat_share(self : Store, session : Json) -> Json raise {
  match self.one("SELECT * FROM chat_shares WHERE session = ?", [session]) {
    Some(r) => live_share(to_chat_share(r), self.now_double())
    None => Json::null()
  }
}

///|
/// Every chat shared with another workspace now, by its session key (a Map's entries).
pub fn Store::chat_shares(self : Store) -> Json raise {
  let now = self.now_double()
  let indexed = self.live_chat_share_rows(now) catch { _ => None }
  let rows = match indexed {
    Some(rows) => rows
    None => self.all("SELECT * FROM chat_shares", [])
  }
  let out : Map[String, Json] = Map([])
  for r in rows {
    let share = live_share(to_chat_share(r), now)
    if !(share is Null) {
      out[js_string(col(r, "session"))] = share
    }
  }
  let pairs = []
  for k, v in out {
    pairs.push((k, v))
  }
  entries(pairs)
}

///|
pub fn Store::chat_share_lapsed(
  self : Store,
  session : Json,
  workspaces : Json,
) -> Bool raise {
  match self.one("SELECT * FROM chat_shares WHERE session = ?", [session]) {
    None => false
    Some(r) => {
      let now = self.now_double()
      share_to(to_chat_share(r))
      .iter()
      .any(t => {
        (
          workspaces is Null ||
          arr(workspaces).contains(nullish(field(t, "workspace")))
        ) &&
        !share_live(t, now)
      })
    }
  }
}

///|
pub fn Store::lapsed_share_workspaces(
  self : Store,
  workspaces : Json,
) -> Json raise {
  let now = self.now_double()
  if workspaces is Array(ws) {
    let names = ws.filter_map(w => str_of(w))
    let indexed = self.lapsed_chat_share_workspaces(names, now) catch {
      _ => None
    }
    if indexed is Some(found) {
      return strings(found)
    }
  }
  let wanted = match workspaces {
    Array(ws) => Some(ws)
    _ => None
  }
  let out : Map[String, Unit] = Map([])
  for r in self.all("SELECT * FROM chat_shares", []) {
    for t in share_to(to_chat_share(r)) {
      let w = nullish(field(t, "workspace"))
      if !share_live(t, now) && (wanted is None || wanted.unwrap().contains(w)) {
        out[js_string(w)] = ()
      }
    }
  }
  let list = []
  for w, _ in out {
    list.push(w)
  }
  strings(list)
}

///|
/// store.ts USED_NOTE_MS.
let used_note_ms : Double = 60000.0

///|
pub fn Store::used_chat_share(
  self : Store,
  session : Json,
  workspaces : Array[Json],
) -> Unit raise {
  let r = self.one("SELECT * FROM chat_shares WHERE session = ?", [session])
  guard r is Some(r) else { return }
  let now = self.now_double()
  let share = to_chat_share(r)
  let used = (t : Json) => num_of(nullish(field(t, "used"))).unwrap_or(0.0)
  if !share_to(share)
    .iter()
    .any(t => {
      workspaces.contains(nullish(field(t, "workspace"))) &&
      share_live(t, now) &&
      now - used(t) >= used_note_ms
    }) {
    return
  }
  let to = share_to(share).map(t => {
    if workspaces.contains(nullish(field(t, "workspace"))) && share_live(t, now) {
      let o = obj(t).copy()
      o["used"] = jnum(now)
      Json::object(o)
    } else {
      t
    }
  })
  ignore(
    self.run("UPDATE chat_shares SET shared = ? WHERE session = ?", [
      jstr(js(Json::array(to))),
      session,
    ]),
  )
}

///|
/// The chats whose share with a workspace lapsed after `since` and by now: their views change. When the next one
/// lapses, null when none will.
pub fn Store::lapse_chat_shares(self : Store, since : Double) -> Json raise {
  let now = self.now_double()
  let indexed = self.due_chat_share_rows(since, now) catch { _ => None }
  let mut next = match indexed {
    Some((_, n)) => n
    None => Json::null()
  }
  self.with_changes(changes => {
    let rows = match indexed {
      Some((rows, _)) => rows
      None => self.all("SELECT * FROM chat_shares", [])
    }
    for r in rows {
      let ends = share_to(to_chat_share(r)).map(t => {
        num_of(nullish(field(t, "used"))).unwrap_or(0.0) + xshare_idle_ms
      })
      if ends.iter().any(end => end > since && end <= now) {
        for t in self.session_threads(col(r, "session")) {
          changes.push(thread_change(thread_id_of(t)))
        }
        let share = to_chat_share(r)
        let live : Array[Json] = share_to(share)
          .filter(t => share_live(t, now))
          .map(t => {
            "workspace": nullish(field(t, "workspace")),
            "name": nullish(field(t, "name")),
          })
        changes.push(session_change(col(r, "session")))
        changes.push({
          "type": "chatMark",
          "thread": Json::null(),
          "session": col(r, "session"),
          "share": {
            "to": Json::array(live),
            "write": nullish(field(share, "write")),
          },
        })
      }
      for end in ends {
        if end > now && (next is Null || end < num_of(next).unwrap_or(0.0)) {
          next = jnum(end)
        }
      }
    }
  })
  next
}

///|
/// Shares a chat with other workspaces (`to`: `{workspace, name}` each), or (none) no longer.
pub fn Store::set_chat_share(
  self : Store,
  session : Json,
  to : Array[Json],
  write : Bool,
  by : Json,
) -> Unit raise {
  self.with_changes(changes => {
    if to.length() == 0 {
      ignore(self.run("DELETE FROM chat_shares WHERE session = ?", [session]))
    } else {
      let now = self.now_json()
      let shared : Array[Json] = to.map(t => {
        "workspace": nullish(field(t, "workspace")),
        "name": nullish(field(t, "name")),
        "used": now,
      })
      ignore(
        self.run(
          "INSERT INTO chat_shares (session, shared, write, by, at) VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT (session) DO UPDATE SET shared = ?2, write = ?3, by = ?4, at = ?5",
          [session, jstr(js(Json::array(shared))), flag(write), by, now],
        ),
      )
    }
    for t in self.session_threads(session) {
      changes.push(thread_change(thread_id_of(t)))
    }
    changes.push(session_change(session))
    changes.push({
      "type": "chatMark",
      "thread": Json::null(),
      "session": session,
      "share": {
        "to": Json::array(
          to.map(t => {
            "workspace": nullish(field(t, "workspace")),
            "name": nullish(field(t, "name")),
          }),
        ),
        "write": jbool(write),
      },
    })
  })
}
