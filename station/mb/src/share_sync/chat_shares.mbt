// The store's chats shared with other workspaces on the station's database (store/store.ts `chatShare`, `chatShares`,
// `chatShareLapsed`, `lapsedShareWorkspaces`, `usedChatShare`, `lapseChatShares`, `setChatShare`), the same statements
// on the same table, read by their deadlines where store/chat-share-index.ts has prepared them (`liveChatShareRows`,
// `dueChatShareRows`, `lapsedChatShareWorkspaces`) and by the table where it has not.

///|
/// A use is noted at most once a minute (store.ts `USED_NOTE_MS`).
let used_note_ms : Double = 60000.0

///|
let dirty_limit : Int = 64

///|
let share_chars_limit : Int = 16384

///|
let share_target_limit : Int = 16

///|
let clean_sql : String = "NOT EXISTS (SELECT 1 FROM chat_share_dirty d WHERE d.session = t.session)"

///|
fn share_live_sql() -> String {
  "WITH keys AS (\n  SELECT t.session FROM chat_share_targets t INDEXED BY chat_share_target_time WHERE t.used > ?1 AND \{clean_sql}\n  UNION SELECT session FROM chat_share_dirty UNION SELECT session FROM chat_share_uncertain\n)\nSELECT c.* FROM keys k CROSS JOIN chat_shares c ON c.session = k.session ORDER BY c.rowid"
}

///|
fn share_due_sql() -> String {
  "WITH keys AS (\n  SELECT t.session FROM chat_share_targets t INDEXED BY chat_share_target_time WHERE t.used > ?1 AND t.used <= ?2 AND \{clean_sql}\n  UNION SELECT session FROM chat_share_dirty UNION SELECT session FROM chat_share_uncertain\n)\nSELECT c.* FROM keys k CROSS JOIN chat_shares c ON c.session = k.session ORDER BY c.rowid"
}

///|
fn share_next_sql() -> String {
  "SELECT t.used FROM chat_share_targets t INDEXED BY chat_share_target_time\n  WHERE t.used > ? AND \{clean_sql} ORDER BY t.used LIMIT 1"
}

///|
fn share_lapsed_ws_sql() -> String {
  "SELECT 1 FROM chat_share_targets t INDEXED BY chat_share_target_workspace\n  WHERE t.workspace = ? AND t.used <= ? AND \{clean_sql} LIMIT 1"
}

///|
let overlay_sql : String = "SELECT c.* FROM (SELECT session FROM chat_share_dirty UNION SELECT session FROM chat_share_uncertain) k\n  CROSS JOIN chat_shares c ON c.session = k.session"

///|
/// A chat_shares row as stored: every workspace it names, those whose share lapsed too (store/rows.ts `toChatShare`).
pub fn to_chat_share(r : Map[String, Json]) -> Json {
  let at = r.get("at").unwrap_or(jnull())
  let to = match r.get("shared") {
    Some(String(s)) => try js_parse(s) catch { _ => jarr([]) }
    _ => jarr([])
  }
  let list = match to {
    Array(a) =>
      a.filter_map(t => match get(Some(t), "workspace") {
        Some(String(w)) =>
          Some(
            jobj([
              ("workspace", jstr(w)),
              ("name", jstr(match get(Some(t), "name") { None | Some(Null) => w; n => js_string(n) })),
              ("used", match get(Some(t), "used") { Some(Number(_) as u) => u; _ => at }),
            ]),
          )
        _ => None
      })
    _ => []
  }
  jobj([
    ("to", jarr(list)),
    ("write", jbool(r.get("write") is Some(Number(1.0, ..)))),
    ("by", r.get("by").unwrap_or(jnull())),
    ("at", at),
  ])
}

///|
/// Whether a workspace's share is still on at `now`: used within XSHARE_IDLE_MS.
fn share_live(t : Json, now : Double) -> Bool {
  now - js_num(get(Some(t), "used")) < xshare_idle_ms
}

///|
/// A share as it is at `now`: the workspaces it is still on for; None when none.
pub fn live_share(share : Json, now : Double) -> Json? {
  let to = share_to(share).filter(t => share_live(t, now))
  if to.is_empty() {
    return None
  }
  let out : Map[String, Json] = Map([])
  if share is Object(m) {
    for k in js_keys(m) {
      out[k] = m[k]
    }
  }
  out["to"] = jarr(to)
  Some(Json::object(out))
}

///|
/// What a row's shares are when JavaScript reads them exactly (chat-share-index.ts `shareValues`): None where they are
/// too long, too many, or their times past 2^53.
fn share_values(row : Map[String, Json]) -> Array[Json]? {
  guard row.get("shared") is Some(String(s)) && s.length() <= share_chars_limit else { return None }
  let values = share_to(to_chat_share(row))
  if values.length() <= share_target_limit &&
    values.iter().all(t => {
      let used = js_num(get(Some(t), "used"))
      safe_int(used) && safe_int(used + xshare_idle_ms)
    }) {
    Some(values)
  } else {
    None
  }
}

///|
/// The store's chat shares on `db`, `now` its clock; `told` given what changed (store.ts `#with`'s changes), and
/// `thread_home` / `threads` what a thread is of.
pub struct SqlChatShares {
  db : @sql.Db
  now : () -> Double
  listeners : Array[(Int, (Json) -> Unit)]
  mut next : Int
  mut presence : Bool?
}

///|
pub fn SqlChatShares::new(db : @sql.Db, now : () -> Double) -> SqlChatShares {
  { db, now, listeners: [], next: 0, presence: None }
}

///|
fn SqlChatShares::one(self : SqlChatShares, session : String) -> Map[String, Json]? raise {
  self.db.all("SELECT * FROM chat_shares WHERE session = ?", [jstr(session)]).get(0)
}

///|
fn SqlChatShares::rows(self : SqlChatShares) -> Array[Map[String, Json]] raise {
  self.db.all("SELECT * FROM chat_shares", [])
}

///|
fn SqlChatShares::tell(self : SqlChatShares, changes : Array[Json]) -> Unit {
  for c in changes {
    for l in self.listeners.copy() {
      (l.1)(c)
    }
  }
}

///|
/// The threads a session takes part in (store.ts `sessionThreads`), latest first.
fn SqlChatShares::threads(self : SqlChatShares, session : String) -> Array[String] raise {
  self.db
  .all(
    "SELECT t.id FROM thread_sessions ts JOIN threads t ON t.id = ts.thread WHERE ts.session = ? ORDER BY ts.joined_at DESC, ts.rowid DESC LIMIT ?",
    [jstr(session), jnum(-1.0)],
  )
  .map(r => js_string(r.get("id")))
}

///|
/// Whether the deadlines' lookup is there (chat-share-index.ts `hasChatShareIndex`), its answer kept till refreshed.
pub fn SqlChatShares::has_index(self : SqlChatShares) -> Bool raise {
  match self.presence {
    Some(p) => p
    None => {
      let found = self.db.all(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'chat_share_index_meta'",
        [],
      ).length() >
        0
      self.presence = Some(found)
      found
    }
  }
}

///|
/// The lookup looked for again (another connection prepared it).
pub fn SqlChatShares::refresh_index(self : SqlChatShares) -> Bool raise {
  self.presence = None
  self.has_index()
}

///|
/// Whether the lookup is prepared and nothing is waiting for it (chat-share-index.ts `chatShareIndexReady`).
pub fn SqlChatShares::index_ready(self : SqlChatShares) -> Bool raise {
  self.has_index() &&
  self.db.all(
    "SELECT 1 FROM chat_share_index_meta WHERE id = 1 AND version = ? AND phase = 1\n    AND NOT EXISTS (SELECT 1 FROM chat_share_dirty LIMIT 1)",
    [jnum(1.0)],
  ).length() >
  0
}

///|
/// A read of the lookup in one snapshot, None where it cannot answer for the table (chat-share-index.ts `snapshot`).
fn[T] SqlChatShares::snapshot(self : SqlChatShares, now : Double, read : () -> T raise) -> T? raise {
  if !safe_int(now) || !safe_int(now - xshare_idle_ms) || !self.has_index() {
    return None
  }
  let db = self.db
  db.exec("BEGIN")
  try {
    let prepared = db.all("SELECT 1 FROM chat_share_index_meta WHERE id = 1 AND version = ? AND phase = 1", [jnum(1.0)])
    let dirty = db.all("SELECT session FROM chat_share_dirty ORDER BY session LIMIT ?", [jnum((dirty_limit + 1).to_double())])
    let null_key = db.all("SELECT 1 FROM chat_shares WHERE session IS NULL LIMIT 1", [])
    let uncertain = db.all("SELECT 1 FROM chat_share_uncertain LIMIT 1", [])
    if prepared.is_empty() || dirty.length() > dirty_limit || !null_key.is_empty() || !uncertain.is_empty() {
      db.exec("COMMIT")
      return None
    }
    for d in dirty {
      let row = db.all("SELECT * FROM chat_shares WHERE session = ?", [d.get("session").unwrap_or(jnull())]).get(0)
      if row is Some(r) && share_values(r) is None {
        db.exec("COMMIT")
        return None
      }
    }
    let result = read()
    db.exec("COMMIT")
    Some(result)
  } catch {
    e => {
      db.exec("ROLLBACK") catch {
        _ => ()
      }
      raise e
    }
  }
}

///|
/// The store's chat shares as the sharing reads and writes them.
pub fn SqlChatShares::store(self : SqlChatShares) -> ChatStore {
  {
    chat_share: session => match self.one(session) {
      Some(r) => live_share(to_chat_share(r), (self.now)())
      None => None
    },
    chat_shares: () => {
      let now = (self.now)()
      let indexed = try self.snapshot(now, () => self.db.all(share_live_sql(), [jnum(now - xshare_idle_ms)])) catch {
        _ => None
      }
      let rows = match indexed {
        Some(r) => r
        None => self.rows()
      }
      let out : Array[(String, Json)] = []
      for r in rows {
        guard live_share(to_chat_share(r), now) is Some(share) else { continue }
        let session = js_string(r.get("session"))
        match out.search_by(e => e.0 == session) {
          Some(i) => out[i] = (session, share)
          None => out.push((session, share))
        }
      }
      out
    },
    chat_share_lapsed: (session, workspaces) => {
      guard self.one(session) is Some(r) else { return false }
      let now = (self.now)()
      share_to(to_chat_share(r)).iter().any(t => (match workspaces {
          None => true
          Some(ws) => ws.contains(to_ws(t))
        }) &&
        !share_live(t, now))
    },
    lapsed_share_workspaces: workspaces => {
      let now = (self.now)()
      if workspaces is Some(wanted) {
        let indexed = try self.snapshot(now, () => {
          let found : Array[String] = []
          let unique : Array[String] = []
          for w in wanted {
            if !unique.contains(w) {
              unique.push(w)
            }
          }
          for w in unique {
            if self.db.all(share_lapsed_ws_sql(), [jstr(w), jnum(now - xshare_idle_ms)]).length() > 0 && !found.contains(w) {
              found.push(w)
            }
          }
          for row in self.db.all(overlay_sql, []) {
            for t in share_to(to_chat_share(row)) {
              if unique.contains(to_ws(t)) && !share_live(t, now) && !found.contains(to_ws(t)) {
                found.push(to_ws(t))
              }
            }
          }
          found
        }) catch {
          _ => None
        }
        if indexed is Some(found) {
          return found
        }
      }
      let out : Array[String] = []
      for r in self.rows() {
        for t in share_to(to_chat_share(r)) {
          let w = to_ws(t)
          if !share_live(t, now) && (workspaces is None || workspaces.unwrap().contains(w)) && !out.contains(w) {
            out.push(w)
          }
        }
      }
      out
    },
    used_chat_share: (session, workspaces) => {
      guard self.one(session) is Some(r) else { return }
      let now = (self.now)()
      let share = to_chat_share(r)
      let due = share_to(share).iter().any(t => workspaces.contains(to_ws(t)) &&
        share_live(t, now) &&
        now - js_num(get(Some(t), "used")) >= used_note_ms)
      if !due {
        return
      }
      let to = share_to(share).map(t => if workspaces.contains(to_ws(t)) && share_live(t, now) {
        jobj([("workspace", get(Some(t), "workspace").unwrap_or(jnull())), ("name", get(Some(t), "name").unwrap_or(jnull())), ("used", jnum(now))])
      } else {
        t
      })
      ignore(self.db.run("UPDATE chat_shares SET shared = ? WHERE session = ?", [jstr(js_stringify(jarr(to))), jstr(session)]))
    },
    lapse_chat_shares: since => {
      let now = (self.now)()
      let indexed = if safe_int(since) && safe_int(since - xshare_idle_ms) {
        try self.snapshot(now, () => {
          let rows = self.db.all(share_due_sql(), [jnum(since - xshare_idle_ms), jnum(now - xshare_idle_ms)])
          let earliest = self.db.all(share_next_sql(), [jnum(now - xshare_idle_ms)]).get(0)
          (rows, match earliest { Some(e) => Some(js_num(e.get("used")) + xshare_idle_ms); None => None })
        }) catch {
          _ => None
        }
      } else {
        None
      }
      let mut next : Double? = match indexed {
        Some((_, n)) => n
        None => None
      }
      let changes : Array[Json] = []
      let rows = match indexed {
        Some((r, _)) => r
        None => self.rows()
      }
      for r in rows {
        let share = to_chat_share(r)
        let ends = share_to(share).map(t => js_num(get(Some(t), "used")) + xshare_idle_ms)
        let session = js_string(r.get("session"))
        if ends.iter().any(end => end > since && end <= now) {
          for t in self.threads(session) {
            changes.push(jobj([("type", jstr("thread")), ("id", jstr(t)), ("entries", jarr([]))]))
          }
          let live = share_to(share)
            .filter(t => share_live(t, now))
            .map(t => jobj([("workspace", get(Some(t), "workspace").unwrap_or(jnull())), ("name", get(Some(t), "name").unwrap_or(jnull()))]))
          changes.push(jobj([("type", jstr("session")), ("key", jstr(session))]))
          changes.push(
            jobj([
              ("type", jstr("chatMark")),
              ("thread", jnull()),
              ("session", jstr(session)),
              ("share", jobj([("to", jarr(live)), ("write", get(Some(share), "write").unwrap_or(jnull()))])),
            ]),
          )
        }
        for end in ends {
          if end > now && (next is None || end < next.unwrap()) {
            next = Some(end)
          }
        }
      }
      self.tell(changes)
      next
    },
    set_chat_share: (session, to, write, by) => {
      let changes : Array[Json] = []
      if to.is_empty() {
        ignore(self.db.run("DELETE FROM chat_shares WHERE session = ?", [jstr(session)]))
      } else {
        let now = (self.now)()
        ignore(
          self.db.run(
            "INSERT INTO chat_shares (session, shared, write, by, at) VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT (session) DO UPDATE SET shared = ?2, write = ?3, by = ?4, at = ?5",
            [
              jstr(session),
              jstr(js_stringify(jarr(to.map(t => jobj([("workspace", jstr(t.0)), ("name", jstr(t.1)), ("used", jnum(now))]))))),
              jnum(if write { 1.0 } else { 0.0 }),
              jstr(by),
              jnum(now),
            ],
          ),
        )
      }
      for t in self.threads(session) {
        changes.push(jobj([("type", jstr("thread")), ("id", jstr(t)), ("entries", jarr([]))]))
      }
      changes.push(jobj([("type", jstr("session")), ("key", jstr(session))]))
      changes.push(
        jobj([
          ("type", jstr("chatMark")),
          ("thread", jnull()),
          ("session", jstr(session)),
          ("share", jobj([("to", jarr(to.map(t => jobj([("workspace", jstr(t.0)), ("name", jstr(t.1))])))), ("write", jbool(write))])),
        ]),
      )
      self.tell(changes)
    },
    subscribe: f => {
      let id = self.next
      self.next += 1
      self.listeners.push((id, f))
      () => {
        match self.listeners.search_by(l => l.0 == id) {
          Some(i) => ignore(self.listeners.remove(i))
          None => ()
        }
      }
    },
    thread_home: id => match self.db.all("SELECT home FROM threads WHERE id = ?", [jstr(id)]).get(0) {
      Some(r) =>
        match r.get("home") {
          Some(String(h)) => Some(h)
          _ => None
        }
      None => None
    },
  }
}
