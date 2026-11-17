// A page of sessions as store.ts `sessionPage` and `sessionPageOfWs` read it (its class SessionPage): their rows
// (given, or read as first asked), the sessions of each one's still.fail home chat, the accounts their runtime
// sessions ran on, each one statement for the page; a session not of the page read alone.

///|
pub struct SessionPage {
  priv store : Store
  /// Its sessions, in order.
  keys : Array[String]
  priv rows : Map[String, Json]
  priv mut rows_read : Bool
  priv mut homes : Array[(String, Array[String])]?
  priv mut ran : Map[String, Array[String]]
  priv mut ran_of : Array[String]?
}

///|
fn SessionPage::new(
  store : Store,
  keys : Array[String],
  rows : Array[Json]?,
  ran : Map[String, Array[String]]?,
) -> SessionPage {
  let page = {
    store,
    keys,
    rows: Map([]),
    rows_read: false,
    homes: None,
    ran: Map([]),
    ran_of: None,
  }
  if rows is Some(rows) {
    page.take(keys, rows)
  }
  if ran is Some(ran) {
    page.ran = ran
    page.ran_of = Some(keys.copy())
  }
  page
}

///|
fn SessionPage::take(
  self : SessionPage,
  keys : Array[String],
  rows : Array[Json],
) -> Unit {
  for k in keys {
    self.rows[k] = Json::null()
  }
  for r in rows {
    self.rows[js_string(nullish(field(r, "key")))] = r
  }
  self.rows_read = true
}

///|
/// Its sessions' rows, in order (those that are).
pub fn SessionPage::rows(self : SessionPage) -> Array[Json] raise {
  let out = []
  for k in self.keys {
    let s = self.session(k)
    if !(s is Null) {
      out.push(s)
    }
  }
  out
}

///|
pub fn SessionPage::session(self : SessionPage, key : String) -> Json raise {
  if !self.rows_read && self.keys.contains(key) {
    self.take(self.keys, self.store.sessions_of(self.keys))
  }
  match self.rows.get(key) {
    Some(r) => r
    None => self.store.get_session(key)
  }
}

///|
fn find_list(
  pairs : Array[(String, Array[String])],
  key : String,
) -> Array[String]? {
  for p in pairs {
    if p.0 == key {
      return Some(p.1)
    }
  }
  None
}

///|
/// The sessions of `key`'s still.fail home chat (None: it is the home of none).
pub fn SessionPage::home_members(
  self : SessionPage,
  key : String,
) -> Array[String]? raise {
  if !self.keys.contains(key) {
    return find_list(self.store.stillfail_homes([key]), key)
  }
  let homes = match self.homes {
    Some(h) => h
    None => {
      let homes = self.store.stillfail_homes(self.keys)
      self.homes = Some(homes)
      let more = []
      for h in homes {
        for k in h.1 {
          if !more.contains(k) &&
            !self.keys.contains(k) &&
            !self.rows.contains(k) {
            more.push(k)
          }
        }
      }
      if more.length() > 0 {
        if !self.rows_read {
          self.take(self.keys, self.store.sessions_of(self.keys))
        }
        let got = self.store.sessions_of(more)
        for k in more {
          self.rows[k] = Json::null()
        }
        for r in got {
          self.rows[js_string(nullish(field(r, "key")))] = r
        }
        if self.ran_of is Some(of) {
          for p in self.store.ran_on_of(more) {
            self.ran[p.0] = p.1
          }
          for k in more {
            if !of.contains(k) {
              of.push(k)
            }
          }
        }
      }
      homes
    }
  }
  find_list(homes, key)
}

///|
/// The accounts `key`'s runtime sessions ran on, in order.
pub fn SessionPage::ran_on(
  self : SessionPage,
  key : String,
) -> Array[String] raise {
  if self.ran_of is None && (self.keys.contains(key) || self.rows.contains(key)) {
    let of = self.keys.copy()
    for k, _ in self.rows {
      if !of.contains(k) {
        of.push(k)
      }
    }
    self.ran_of = Some(of)
    let ran = Map([])
    for p in self.store.ran_on_of(of) {
      ran[p.0] = p.1
    }
    self.ran = ran
  }
  if self.ran_of is Some(of) && of.contains(key) {
    return self.ran.get(key).unwrap_or([])
  }
  find_list(self.store.ran_on_of([key]), key).unwrap_or([])
}

///|
/// A page of sessions `keys` (`rows`: their rows, where the caller has them).
pub fn Store::session_page(
  self : Store,
  keys : Array[String],
  rows : Array[Json]?,
) -> SessionPage {
  SessionPage::new(self, keys, rows, None)
}

///|
/// `sessionsOfWs`'s page (the same keys in the same order) as a page of sessions, read in one statement.
pub fn Store::session_page_of_ws(
  self : Store,
  ws : Json,
  home : Json,
  after : Json,
  limit : Int32,
) -> SessionPage raise {
  let named = if ws is Null { home } else { ws }
  let branch = "SELECT * FROM (SELECT * FROM sessions WHERE COALESCE(ws, '') = ? AND key > ? ORDER BY key LIMIT ?)"
  let home_too = ws is Null && home is String(h) && h != ""
  let ran = "(SELECT json_group_array(profile) FROM (SELECT profile, MIN(id) AS first FROM runtime_sessions WHERE session_key = u.key AND profile IS NOT NULL GROUP BY profile ORDER BY first))"
  let branches = [branch]
  if home_too {
    branches.push(branch)
  }
  branches.push(branch)
  let sql = "SELECT u.*, h.station AS h_station, h.ws AS h_ws, h.thread AS h_thread, h.there AS h_there, h.at AS h_at, \{ran} AS h_ran FROM (\{branches.join(" UNION ALL ")}) u LEFT JOIN handed_over h ON h.session = u.key ORDER BY u.key LIMIT ?"
  let lim = ints(limit)
  let args = [or_else(ws, jstr("")), after, lim]
  if home_too {
    args.push(home)
    args.push(after)
    args.push(lim)
  }
  args.push(jstr(handed_ws(js_string(or_else(named, jstr(""))))))
  args.push(after)
  args.push(lim)
  args.push(lim)
  let rows = []
  let ran_of : Map[String, Array[String]] = Map([])
  for r in self.all(sql, args) {
    let key = js_string(col(r, "key"))
    if !self.in_tx() {
      self.handed[key] = if col(r, "h_station") is Null {
        Json::null()
      } else {
        handed_of(jstr(key), r, "h_")
      }
    }
    ran_of[key] = arr(js_parse(js_string(or_else(col(r, "h_ran"), jstr("[]"))))).map(
      js_string,
    )
    rows.push(to_session(r))
  }
  SessionPage::new(
    self,
    rows.map(r => js_string(nullish(field(r, "key")))),
    Some(rows),
    Some(ran_of),
  )
}
