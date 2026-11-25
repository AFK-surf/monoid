// A chat handed from one station to another while both are up, as station/src/store/handover.ts does it: the rows of
// its sessions and of the threads they take part in, read a bounded page at a time on the station it leaves
// (`chat_page`), put in on the one it goes to (`import_rows`, in the store's transaction), hidden until shown, what was
// put in said (`made`) so that a hand-over that fails takes it out again (`drop_import`), and counted. An import's
// context (handover.ts ImportCtx) is JSON, changed in place as the TypeScript changes its object, so the text kept of
// it (`handover_in`) is the station's.

///|
/// handover.ts CHAT_TABLES.
pub let chat_tables : Array[String] = [
  "threads", "sessions", "thread_sessions", "entries", "letters", "turns", "runtime_sessions",
  "closed_cards", "entry_proposals", "proposal_outcomes", "reads", "hidden_chats", "muted_chats", "kept_chats", "dismissed",
  "pins", "opened_chats", "deliveries", "usage", "usage_files", "session_usage",
]

///|
/// handover.ts USAGE_COLUMNS.
let usage_columns : Array[String] = [
  "id", "at", "session", "turn", "thread", "person", "profile", "runtime", "model",
  "subagent", "fast", "input", "cache_read", "cache_write", "cache_write_long", "output",
  "calls", "context", "context_window",
]

///|
/// handover.ts PAGE.
pub let handover_page : Int32 = 500

///|
/// handover.ts `viewers`.
fn viewers_of(table : String) -> String {
  "WITH RECURSIVE viewers(viewer) AS MATERIALIZED (\n" +
  "    SELECT (SELECT viewer FROM \{table} ORDER BY viewer LIMIT 1)\n" +
  "    UNION ALL SELECT (SELECT viewer FROM \{table} WHERE viewer > v.viewer ORDER BY viewer LIMIT 1)\n" +
  "      FROM viewers v WHERE v.viewer IS NOT NULL\n" +
  "  )"
}

///|
fn pair_of(after : Json, a : Json, b : Json) -> (Json, Json) {
  match after {
    Array([x, y, ..]) => (x, y)
    _ => (a, b)
  }
}

///|
fn ints(n : Int32) -> Json {
  jnum(n.to_double())
}

///|
/// handover.ts `chatPage`: a page of `table`'s rows of thread or session `of`, after `after`, at most `limit`.
pub fn chat_page(
  db : @sql.Db,
  table : String,
  of : Json,
  after : Json,
  limit : Int32,
  keys : Array[String],
) -> Array[Json] raise {
  let all = (sql : String, args : Array[Json]) => {
    db.all(sql, args).map(row_json)
  }
  let lim = ints(limit)
  match table {
    "threads" => all("SELECT * FROM threads WHERE id = ?", [of])
    "thread_sessions" =>
      all(
        "SELECT * FROM thread_sessions WHERE thread = ? AND session IN (SELECT value FROM json_each(?))",
        [of, jstr(js(strings(keys)))],
      )
    "entries" | "letters" | "closed_cards" | "entry_proposals" | "proposal_outcomes" =>
      all(
        "SELECT * FROM \{table} WHERE thread = ? AND n > ? ORDER BY n LIMIT ?",
        [of, or_else(after, jnum(-1.0)), lim],
      )
    "reads" | "hidden_chats" | "muted_chats" | "kept_chats" =>
      all(
        "\{viewers_of(table)} SELECT * FROM \{table} WHERE viewer IN (SELECT viewer FROM viewers WHERE viewer IS NOT NULL) AND thread = ? AND viewer > ? ORDER BY viewer LIMIT ?",
        [of, or_else(after, jstr("")), lim],
      )
    "dismissed" => {
      let (v, n) = pair_of(after, jstr(""), jnum(-1.0))
      all(
        "\{viewers_of(table)} SELECT * FROM dismissed WHERE viewer IN (SELECT viewer FROM viewers WHERE viewer IS NOT NULL) AND thread = ? AND (viewer > ? OR (viewer = ? AND n > ?)) ORDER BY viewer, n LIMIT ?",
        [of, v, v, n, lim],
      )
    }
    "sessions" => all("SELECT * FROM sessions WHERE key = ?", [of])
    "turns" => {
      let (at, id) = pair_of(after, jnum(-1.0), jstr(""))
      all(
        "SELECT * FROM turns WHERE session_key = ? AND (started_at > ? OR (started_at = ? AND id > ?)) ORDER BY started_at, id LIMIT ?",
        [of, at, at, id, lim],
      )
    }
    "runtime_sessions" =>
      all(
        "SELECT * FROM runtime_sessions WHERE session_key = ? AND id > ? ORDER BY id LIMIT ?",
        [of, or_else(after, jstr("")), lim],
      )
    "pins" =>
      all(
        "\{viewers_of("pins")} SELECT * FROM pins WHERE viewer IN (SELECT viewer FROM viewers WHERE viewer IS NOT NULL) AND session = ? AND viewer > ? ORDER BY viewer LIMIT ?",
        [of, or_else(after, jstr("")), lim],
      )
    "opened_chats" =>
      all("SELECT * FROM opened_chats WHERE child_station = '' AND child = ?", [
        of,
      ])
    "deliveries" => {
      let (t, n) = pair_of(after, jnum(-1.0), jnum(-1.0))
      all(
        "SELECT * FROM deliveries WHERE session = ? AND delivered_at IS NULL AND (thread > ? OR (thread = ? AND n > ?)) ORDER BY thread, n LIMIT ?",
        [of, t, t, n, lim],
      )
    }
    "usage" => {
      let (at, id) = pair_of(after, jnum(-9007199254740991.0), jstr(""))
      let have = columns_of(db, "usage")
      let cols = usage_columns.filter(c => have.contains(c)).join(", ")
      all(
        "SELECT \{cols} FROM usage INDEXED BY usage_session WHERE session = ? AND (at > ? OR (at = ? AND id > ?)) ORDER BY at, id LIMIT ?",
        [of, at, at, id, lim],
      )
    }
    "usage_files" =>
      all(
        "SELECT * FROM usage_files WHERE session = ? AND path > ? ORDER BY path LIMIT ?",
        [of, or_else(after, jstr("")), lim],
      )
    "session_usage" =>
      all("SELECT * FROM session_usage WHERE session = ?", [of])
    _ => []
  }
}

///|
/// handover.ts `afterOf`: the key a page goes on after, of its last row.
pub fn after_of(table : String, row : Json) -> Json {
  let get = (k : String) => nullish(field(row, k))
  match table {
    "entries" | "letters" | "closed_cards" | "entry_proposals" | "proposal_outcomes" => get("n")
    "reads" | "hidden_chats" | "muted_chats" | "kept_chats" | "pins" =>
      get("viewer")
    "dismissed" => Json::array([get("viewer"), get("n")])
    "turns" => Json::array([get("started_at"), get("id")])
    "runtime_sessions" => get("id")
    "deliveries" => Json::array([get("thread"), get("n")])
    "usage" => Json::array([get("at"), get("id")])
    "usage_files" => get("path")
    _ => Json::null()
  }
}

///|
/// handover.ts `chatThreads`: the threads sessions `keys` take part in, after thread `after`, at most `limit`.
pub fn chat_threads(
  db : @sql.Db,
  keys : Array[String],
  after : Json,
  limit : Int32,
) -> Array[Json] raise {
  let seen : Map[Double, Unit] = Map([])
  let out : Array[Double] = []
  for key in keys {
    for
      r in db.all(
        "SELECT thread FROM thread_sessions WHERE session = ? AND thread > ? ORDER BY thread LIMIT ?",
        [jstr(key), after, ints(limit)],
      ) {
      if num_of(col(r, "thread")) is Some(t) && !seen.contains(t) {
        seen[t] = ()
        out.push(t)
      }
    }
  }
  out.sort()
  let n = if out.length() < limit {
    out.length()
  } else if limit < 0 {
    0
  } else {
    limit
  }
  out[:n].to_array().map(jnum)
}

///|
/// handover.ts `newCtx`.
pub fn new_ctx(c : Json) -> Json {
  let o = obj(c).copy()
  o["threads"] = Json::object(Map([]))
  o["made"] = {
    "sessions": Json::array([]),
    "entries": Json::array([]),
    "letters": Json::array([]),
    "members": Json::array([]),
    "rows": Json::object(Map([])),
  }
  o["counts"] = {
    "sessions": 0,
    "entries": Json::object(Map([])),
    "letters": Json::object(Map([])),
    "rows": Json::object(Map([])),
  }
  Json::object(o)
}

///|
/// node:path `sep`.
let sep : String = "/"

///|
/// node:path `join(to, rest)` (POSIX).
fn path_join(a : String, b : String) -> String {
  @nodepath.join("/", [a, b])
}

///|
/// handover.ts `moved`: a path under the data directory `from` as it is under `to`.
fn moved_path(path : Json, from : String, to : String) -> Json {
  guard path is String(p) else { return path }
  if from == "" || from == to {
    return path
  }
  let f = if from.has_suffix(sep) {
    from.substring(end=from.length() - 1)
  } else {
    from
  }
  if p == f {
    return jstr(to)
  }
  if p.has_prefix(f + sep) || p.has_prefix("\{f}/") {
    jstr(path_join(to, p.substring(start=f.length() + 1)))
  } else {
    path
  }
}

///|
/// handover.ts `connectHere`.
pub fn connect_here(connect : String, connects : Json) -> String {
  if former_own_names.contains(connect) {
    return internal_connect
  }
  match field(connects, connect) {
    Some(to) => js_string(to)
    None => connect
  }
}

///|
/// handover.ts `surfaceHere`.
pub fn surface_here(surface : String, connects : Json) -> String {
  // (the station's own chats, as a station from before the rename names them)
  if former_own_names.contains(surface) {
    return stillfail_surface
  }
  match surface.find(":") {
    None => surface
    Some(at) => {
      let id = surface.substring(start=at + 1)
      match field(connects, id) {
        Some(to) => surface.substring(end=at + 1) + js_string(to)
        None => surface
      }
    }
  }
}

///|
/// handover.ts `columnsOf`.
fn columns_of(db : @sql.Db, table : String) -> Array[String] raise {
  db
  .all("SELECT name FROM pragma_table_info('\{table}')", [])
  .filter_map(r => str_of(col(r, "name")))
}

///|
/// handover.ts `insert`: what it changed and the row's id.
fn insert_row(
  db : @sql.Db,
  table : String,
  row : Map[String, Json],
  or : String,
) -> (Int32, Json) raise {
  let have = columns_of(db, table)
  let cols = []
  for k, _ in row {
    if have.contains(k) {
      cols.push(k)
    }
  }
  let changes = db.run(
    "INSERT\{or} INTO \{table} (\{cols.join(", ")}) VALUES (\{cols.map(_ => "?").join(", ")})",
    cols.map(c => row.get(c).unwrap_or(Json::null())),
  )
  let id = match db.all("SELECT last_insert_rowid() AS id", []) {
    [r, ..] => col(r, "id")
    _ => jnum(0.0)
  }
  (changes, id)
}

///|
/// handover.ts `bump`: a ts's trailing number one more.
fn bump(ts : String) -> String {
  let mut i = ts.length()
  while i > 0 {
    let c = ts.unsafe_charcode_at(i - 1)
    if c >= 48 && c <= 57 {
      i -= 1
    } else {
      break
    }
  }
  if i == ts.length() {
    return ts + "1"
  }
  let digits = ts.substring(start=i)
  // (as a BigInt: every digit kept)
  let out = []
  let mut carry = 1
  for j = digits.length() - 1; j >= 0; j = j - 1 {
    let d = digits.unsafe_charcode_at(j) - 48 + carry
    out.push(d % 10)
    carry = d / 10
  }
  if carry > 0 {
    out.push(carry)
  }
  // (BigInt's text has no leading zeros, then padded to the width it had)
  while out.length() > 1 && out[out.length() - 1] == 0 {
    ignore(out.pop())
  }
  let text = StringBuilder::new()
  for k = out.length() - 1; k >= 0; k = k - 1 {
    text.write_char((out[k] + 48).unsafe_to_char())
  }
  let s = text.to_string()
  let padded = if s.length() < digits.length() {
    String::make(digits.length() - s.length(), '0') + s
  } else {
    s
  }
  ts.substring(end=i) + padded
}

///|
/// `(o[k] ??= init)`.
fn ensure(o : Map[String, Json], k : String, init : Json) -> Json {
  match o.get(k) {
    Some(Null) | None => {
      o[k] = init
      init
    }
    Some(v) => v
  }
}

///|
/// `o[k] = (o[k] ?? 0) + 1`.
fn count_up(o : Map[String, Json], k : String) -> Unit {
  let n = match o.get(k) {
    Some(Number(n, ..)) => n
    _ => 0.0
  }
  o[k] = jnum(n + 1.0)
}

///|
/// What a page touched (handover.ts Touched): sessions, threads, and each mark as its own change says it.
priv struct Touched {
  sessions : Array[String]
  threads : Array[Json]
  marks : Array[Json]
}

///|
fn Touched::session(self : Touched, key : String) -> Unit {
  if !self.sessions.contains(key) {
    self.sessions.push(key)
  }
}

///|
fn Touched::thread(self : Touched, id : Json) -> Unit {
  if !self.threads.contains(id) {
    self.threads.push(id)
  }
}

///|
/// A row's key in a JSON object's keys (`String(v)`).
fn key_of(v : Json) -> String {
  js_string(v)
}

///|
/// handover.ts `importRows`: a page of `table`'s rows of the copy put in (inside a transaction of the store's).
fn import_page(
  db : @sql.Db,
  ctx : Json,
  table : String,
  rows : Array[Json],
  touched : Touched,
) -> Unit raise {
  let c = obj(ctx)
  let threads = obj(ensure(c, "threads", Json::object(Map([]))))
  let made = obj(nullish(c.get("made")))
  let made_rows = obj(ensure(made, "rows", Json::object(Map([]))))
  let counts = obj(nullish(c.get("counts")))
  let count_rows = obj(ensure(counts, "rows", Json::object(Map([]))))
  let connects = nullish(c.get("connects"))
  let profiles = nullish(c.get("profiles"))
  let from_data = js_string(nullish(c.get("fromData")))
  let to_data = js_string(nullish(c.get("toData")))
  let thread = (was : Json) => threads.get(key_of(was))
  let n_of = (t : Json?, was : Json) => {
    match t {
      None => was
      Some(t) =>
        match field(nullish(field(t, "ns")), key_of(was)) {
          Some(v) => v
          None => was
        }
    }
  }
  let told = (change : Json) => touched.marks.push(change)
  let keep = (key : Json) => {
    let list = ensure(made_rows, table, Json::array([]))
    if list is Array(a) {
      a.push(key)
    }
    count_up(count_rows, table)
    let k = (f : String) => nullish(field(key, f))
    match table {
      "reads" =>
        told({
          "type": "read",
          "viewer": k("viewer"),
          "thread": k("thread"),
          "n": Json::null(),
        })
      "hidden_chats" =>
        told({
          "type": "hidden",
          "viewer": k("viewer"),
          "thread": k("thread"),
          "hidden": true,
        })
      "muted_chats" =>
        told({
          "type": "muted",
          "viewer": k("viewer"),
          "thread": k("thread"),
          "muted": true,
        })
      "kept_chats" =>
        told({
          "type": "dismissed",
          "viewer": k("viewer"),
          "kept": { "thread": k("thread"), "kept": true },
        })
      "dismissed" =>
        told({
          "type": "dismissed",
          "viewer": k("viewer"),
          "card": { "thread": k("thread"), "n": k("n") },
        })
      "pins" =>
        told({
          "type": "pins",
          "viewer": k("viewer"),
          "session": k("session"),
          "at": Json::null(),
        })
      "closed_cards" =>
        told({
          "type": "thread",
          "id": k("thread"),
          "entries": [],
          "closed": k("n"),
        })
      "entry_proposals" | "proposal_outcomes" =>
        told({
          "type": "thread",
          "id": k("thread"),
          "entries": [],
        })
      "turns" | "runtime_sessions" =>
        touched.session(js_string(or_else(k("session_key"), jstr(""))))
      _ => ()
    }
  }
  let map_profile = (r : Map[String, Json]) => {
    if r.get("profile") is Some(String(p)) && field(profiles, p) is Some(to) {
      r["profile"] = to
    }
  }
  for r0 in rows {
    let r = obj(r0).copy()
    let get = (k : String) => r.get(k).unwrap_or(Json::null())
    match table {
      "threads" => {
        let was = num_of(get("id")).unwrap_or(0.0)
        r.remove("id")
        let was_key = key_of(jnum(was))
        if threads.get(was_key) is Some(Object(already)) {
          // Catch-up re-send: preserve existing `ctx.threads[was]` (id, fresh, linear, lettersLinear, ns, ls, preLocked)!
          // Skip if target was already locked before round 1 (`preLocked`), OR if a target member newly locked/changed
          // classification during handover (`cur_locked == 1` and differs from our post-round-1 snapshot).
          let aid = nullish(already.get("id"))
          let pre_locked = already.get("preLocked") is Some(True)
          let is_fresh = already.get("fresh") is Some(True)
          if !pre_locked {
            match db.all("SELECT * FROM threads WHERE id = ?", [aid]) {
              [cur, ..] => {
                let cur_locked = if col(cur, "project_locked") == jnum(1.0) { jnum(1.0) } else { jnum(0.0) }
                let cur_proj = col(cur, "project")
                let cur_tags = match col(cur, "tags") {
                  String(s) if s != "" => jstr(s)
                  _ => Json::null()
                }
                let last_proj = nullish(already.get("lastProject"))
                let last_locked = match already.get("lastLocked") {
                  Some(Number(n, ..)) => jnum(n)
                  _ => jnum(0.0)
                }
                let last_tags = nullish(already.get("lastTags"))
                let target_locked_during_move = cur_locked == jnum(1.0) &&
                  (cur_proj != last_proj || cur_locked != last_locked || cur_tags != last_tags)
                if !target_locked_during_move {
                  let in_locked = if get("project_locked") == jnum(1.0) { jnum(1.0) } else { jnum(0.0) }
                  let in_proj = get("project")
                  let in_tags = match get("tags") {
                    String(s) if s != "" => jstr(s)
                    _ => Json::null()
                  }
                  if in_proj != cur_proj || in_locked != cur_locked || in_tags != cur_tags {
                    if !is_fresh {
                      made_before(ctx, "threads", "id", row_json(cur))
                    }
                    ignore(
                      db.run(
                        "UPDATE threads SET project = ?, project_locked = ?, tags = ? WHERE id = ?",
                        [in_proj, in_locked, in_tags, aid],
                      ),
                    )
                  }
                  already["lastProject"] = in_proj
                  already["lastLocked"] = in_locked
                  already["lastTags"] = in_tags
                }
              }
              _ => ()
            }
          }
          touched.thread(aid)
          continue
        }
        r["surface"] = jstr(surface_here(js_string(get("surface")), connects))
        let at = (ts : Json) => {
          db.all(
            "SELECT id, home FROM threads WHERE surface = ? AND channel = ? AND thread_ts = ?",
            [get("surface"), get("channel"), ts],
          )
        }
        let mut here = match at(get("thread_ts")) {
          [h, ..] => Some(h)
          _ => None
        }
        if here is Some(h) &&
          get("surface") == jstr(stillfail_surface) &&
          col(h, "home") != get("home") {
          let mut ts = js_string(get("thread_ts"))
          while true {
            ts = bump(ts)
            if at(jstr(ts)).length() == 0 {
              break
            }
          }
          r["thread_ts"] = jstr(ts)
          here = None
        }
        let id = match here {
          Some(h) => {
            let hid = col(h, "id")
            let mut pre_locked = false
            let mut last_proj = Json::null()
            let mut last_locked = jnum(0.0)
            let mut last_tags = Json::null()
            // Merge classification columns on an existing thread: `project_locked = 1` wins whole (including NULL tags).
            match db.all("SELECT * FROM threads WHERE id = ?", [hid]) {
              [cur, ..] => {
                let cur_locked = col(cur, "project_locked") == jnum(1.0)
                pre_locked = cur_locked
                let in_locked = get("project_locked") == jnum(1.0)
                let cur_proj = col(cur, "project")
                let in_proj = get("project")
                let cur_tags = match col(cur, "tags") {
                  String(s) if s != "" => jstr(s)
                  _ => Json::null()
                }
                let in_tags = match get("tags") {
                  String(s) if s != "" => jstr(s)
                  _ => Json::null()
                }
                let (next_proj, next_locked, next_tags) = if cur_locked {
                  (cur_proj, jnum(1.0), cur_tags)
                } else if in_locked {
                  (in_proj, jnum(1.0), in_tags)
                } else {
                  let np = if !(cur_proj is Null) { cur_proj } else { in_proj }
                  let nt = if !(cur_tags is Null) { cur_tags } else { in_tags }
                  (np, jnum(0.0), nt)
                }
                if next_proj != cur_proj || next_locked != col(cur, "project_locked") || next_tags != cur_tags {
                  made_before(ctx, "threads", "id", row_json(cur))
                  ignore(
                    db.run(
                      "UPDATE threads SET project = ?, project_locked = ?, tags = ? WHERE id = ?",
                      [next_proj, next_locked, next_tags, hid],
                    ),
                  )
                }
                last_proj = next_proj
                last_locked = next_locked
                last_tags = next_tags
              }
              _ => ()
            }
            (hid, false, pre_locked, last_proj, last_locked, last_tags)
          }
          None => {
            let (_, id) = insert_row(db, "threads", r, "")
            let lp = get("project")
            let ll = if get("project_locked") == jnum(1.0) { jnum(1.0) } else { jnum(0.0) }
            let lt = match get("tags") {
              String(s) if s != "" => jstr(s)
              _ => Json::null()
            }
            (id, true, false, lp, ll, lt)
          }
        }
        let there : Json = {
          "id": id.0,
          "fresh": jbool(id.1),
          "linear": true,
          "lettersLinear": true,
          "preLocked": jbool(id.2),
          "lastProject": id.3,
          "lastLocked": id.4,
          "lastTags": id.5,
          "ns": Json::object(Map([])),
          "ls": Json::object(Map([])),
        }
        threads[was_key] = there
        touched.thread(id.0)
      }
      "sessions" => {
        if get("connect") is String(cn) {
          r["connect"] = jstr(connect_here(cn, connects))
        }
        r["workspace"] = moved_path(get("workspace"), from_data, to_data)
        r["cwd"] = moved_path(get("cwd"), from_data, to_data)
        r["running"] = jnum(0.0)
        r["ws"] = nullish(c.get("ws"))
        let began = match get("began_on") {
          String(b) if b != "" => jstr(b)
          _ => nullish(c.get("from"))
        }
        if c.get("here") is Some(here) && !(here is Null) && began == here {
          r["began_on"] = Json::null()
          r["came_from"] = Json::null()
        } else {
          r["began_on"] = began
          r["came_from"] = nullish(c.get("from"))
        }
        map_profile(r)
        if get("profiles") is String(text) {
          if (Some(js_parse(text)) catch { _ => None }) is Some(Array(list)) {
            r["profiles"] = jstr(
              js(
                Json::array(
                  list.map(p => {
                    match field(profiles, key_of(p)) {
                      Some(to) => to
                      None => p
                    }
                  }),
                ),
              ),
            )
          }
        }
        let before = match
          db.all("SELECT * FROM sessions WHERE key = ?", [get("key")]) {
          [b, ..] => Some(b)
          _ => None
        }
        match before {
          None => ignore(insert_row(db, "sessions", r, ""))
          Some(_) => {
            let have = columns_of(db, "sessions")
            let cols = []
            for k, _ in r {
              if have.contains(k) && k != "key" {
                cols.push(k)
              }
            }
            ignore(
              db.run(
                "UPDATE sessions SET \{cols.map(k => "\{k} = ?").join(", ")} WHERE key = ?",
                cols.map(k => get(k)) + [get("key")],
              ),
            )
          }
        }
        let made_sessions = arr(nullish(made.get("sessions")))
        let key = js_string(get("key"))
        if !made_sessions.iter().any(s => field(s, "key") == Some(get("key"))) {
          if made.get("sessions") is Some(Array(a)) {
            a.push({
              "key": jstr(key),
              "before": match before {
                Some(b) => row_json(b)
                None => Json::null()
              },
            })
          }
        }
        count_up(counts, "sessions")
        touched.session(key)
      }
      "thread_sessions" => {
        let t = thread(get("thread"))
        guard t is Some(t) else { continue }
        let id = nullish(field(t, "id"))
        r["thread"] = id
        if get("connect") is String(cn) {
          r["connect"] = jstr(connect_here(cn, connects))
        }
        if insert_row(db, "thread_sessions", r, " OR IGNORE").0 > 0 {
          if made.get("members") is Some(Array(a)) {
            a.push(Json::array([id, jstr(js_string(get("session")))]))
          }
        }
        count_up(count_rows, "thread_sessions")
        touched.thread(id)
        touched.session(js_string(get("session")))
      }
      "entries" | "letters" => {
        let t = thread(get("thread"))
        guard t is Some(t) else { continue }
        let tt = obj(t)
        let id = nullish(tt.get("id"))
        let was = get("n")
        let map = obj(
          nullish(tt.get(if table == "entries" { "ns" } else { "ls" })),
        )
        let last = match
          db.all("SELECT MAX(n) AS n FROM \{table} WHERE thread = ?", [id]) {
          [x, ..] => num_of(col(x, "n")).unwrap_or(0.0)
          _ => 0.0
        }
        let same = match
          db.all("SELECT ts, author FROM \{table} WHERE thread = ? AND n = ?", [
            id, was,
          ]) {
          [x, ..] => Some(x)
          _ => None
        }
        let count_of = obj(nullish(counts.get(table)))
        count_up(count_of, key_of(nullish(obj(r0).get("thread"))))
        let linear_key = if table == "entries" {
          "linear"
        } else {
          "lettersLinear"
        }
        let linear = tt.get(linear_key) is Some(True)
        if linear &&
          same is Some(s) &&
          col(s, "ts") == get("ts") &&
          col(s, "author") == get("author") {
          continue
        }
        let onward = linear && same is None && num_of(was) == Some(last + 1.0)
        let there = if onward &&
          table == "entries" &&
          !(tt.get("fresh") is Some(True)) &&
          !(get("ts") is Null) {
          match
            db.all("SELECT n FROM entries WHERE thread = ? AND ts = ?", [
              id,
              get("ts"),
            ]) {
            [x, ..] => Some(col(x, "n"))
            _ => None
          }
        } else {
          None
        }
        if there is Some(n) {
          tt["linear"] = jbool(false)
          map[key_of(was)] = n
          continue
        }
        let to = if onward {
          was
        } else {
          if table == "entries" {
            tt["linear"] = jbool(false)
          } else {
            tt["lettersLinear"] = jbool(false)
          }
          let target = if table == "entries" && get("target") is Number(_, ..) {
            Some(n_of(Some(t), get("target")))
          } else {
            None
          }
          let by_ts = if !(get("ts") is Null) {
            match
              db.all("SELECT n FROM \{table} WHERE thread = ? AND ts = ?", [
                id,
                get("ts"),
              ]) {
              [x, ..] => Some(col(x, "n"))
              _ => None
            }
          } else {
            match target {
              None => None
              Some(target) =>
                match
                  db.all(
                    "SELECT n FROM entries WHERE thread = ? AND target = ? AND ts IS NULL AND kind IS ? AND author = ? AND at IS ? AND text IS ? LIMIT 1",
                    [
                      id,
                      target,
                      get("kind"),
                      jstr(js_string(get("author"))),
                      get("at"),
                      get("text"),
                    ],
                  ) {
                  [x, ..] => Some(col(x, "n"))
                  _ => None
                }
            }
          }
          if by_ts is Some(n) {
            map[key_of(was)] = n
            continue
          }
          let next = jnum(last + 1.0)
          map[key_of(was)] = next
          next
        }
        r["thread"] = id
        r["n"] = to
        if table == "entries" && get("target") is Number(_, ..) {
          r["target"] = n_of(Some(t), get("target"))
        }
        if get("attachments") is String(text) && text != "" {
          if (Some(js_parse(text)) catch { _ => None }) is Some(Array(list)) {
            r["attachments"] = jstr(
              js(
                Json::array(
                  list.map(a => {
                    if field(a, "path") is Some(String(_)) {
                      let o = obj(a).copy()
                      o["path"] = moved_path(
                        o.get("path").unwrap(),
                        from_data,
                        to_data,
                      )
                      Json::object(o)
                    } else {
                      a
                    }
                  }),
                ),
              ),
            )
          }
        }
        ignore(insert_row(db, table, r, ""))
        let ranges = arr(nullish(made.get(table)))
        let n = num_of(to).unwrap_or(0.0)
        match ranges.last() {
          Some(Array(end)) if end.length() == 3 &&
            end[0] == id &&
            num_of(end[2]) == Some(n - 1.0) => end[2] = to
          _ =>
            if made.get(table) is Some(Array(a)) {
              a.push(Json::array([id, to, to]))
            }
        }
        touched.thread(id)
      }
      "turns" => {
        let t = thread(get("about_thread"))
        if !(get("about_thread") is Null) {
          match t {
            None => {
              r["about_thread"] = Json::null()
              r["about_n"] = Json::null()
            }
            Some(t) => {
              r["about_n"] = n_of(Some(t), get("about_n"))
              r["about_thread"] = nullish(field(t, "id"))
            }
          }
        }
        if insert_row(db, "turns", r, " OR IGNORE").0 > 0 {
          keep({ "id": get("id"), "session_key": get("session_key") })
        } else {
          count_up(count_rows, "turns")
        }
        touched.session(js_string(get("session_key")))
      }
      "runtime_sessions" => {
        map_profile(r)
        if insert_row(db, "runtime_sessions", r, " OR IGNORE").0 > 0 {
          keep({ "session_key": get("session_key"), "id": get("id") })
        } else {
          ignore(
            db.run(
              "UPDATE runtime_sessions SET profile = COALESCE(?, profile) WHERE session_key = ? AND id = ?",
              [get("profile"), get("session_key"), get("id")],
            ),
          )
          count_up(count_rows, "runtime_sessions")
        }
      }
      "closed_cards" | "entry_proposals" | "proposal_outcomes" | "dismissed" => {
        let t = thread(get("thread"))
        guard t is Some(t) else { continue }
        r["thread"] = nullish(field(t, "id"))
        r["n"] = n_of(Some(t), get("n"))
        if insert_row(db, table, r, " OR IGNORE").0 > 0 {
          keep(
            if table == "dismissed" {
              {
                "viewer": get("viewer"),
                "thread": get("thread"),
                "n": get("n"),
              }
            } else {
              { "thread": get("thread"), "n": get("n") }
            },
          )
        } else {
          if table == "proposal_outcomes" && get("info_synced") == jnum(1.0) && columns_of(db, "proposal_outcomes").contains("info_synced") {
            match db.all("SELECT * FROM proposal_outcomes WHERE thread = ? AND n = ?", [get("thread"), get("n")]) {
              [existing, ..] => {
                if col(existing, "info_synced") == jnum(0.0) &&
                  col(existing, "status") == get("status") &&
                  col(existing, "project") == get("project") {
                  made_before_keys(ctx, "proposal_outcomes", ["thread", "n"], row_json(existing))
                  ignore(
                    db.run(
                      "UPDATE proposal_outcomes SET info_synced = 1 WHERE thread = ? AND n = ? AND info_synced = 0",
                      [get("thread"), get("n")],
                    ),
                  )
                }
              }
              _ => ()
            }
          }
          count_up(count_rows, table)
        }
      }
      "reads" => {
        let t = thread(get("thread"))
        guard t is Some(t) else { continue }
        r["thread"] = nullish(field(t, "id"))
        r["n"] = n_of(Some(t), get("n"))
        if insert_row(db, "reads", r, " OR IGNORE").0 > 0 {
          keep({ "viewer": get("viewer"), "thread": get("thread") })
        } else {
          told({
            "type": "read",
            "viewer": get("viewer"),
            "thread": get("thread"),
            "n": get("n"),
          })
          ignore(
            db.run(
              "UPDATE reads SET n = MAX(n, ?) WHERE viewer = ? AND thread = ?",
              [get("n"), get("viewer"), get("thread")],
            ),
          )
          count_up(count_rows, "reads")
        }
      }
      "hidden_chats" | "muted_chats" | "kept_chats" => {
        let t = thread(get("thread"))
        guard t is Some(t) else { continue }
        r["thread"] = nullish(field(t, "id"))
        if insert_row(db, table, r, " OR IGNORE").0 > 0 {
          keep({ "viewer": get("viewer"), "thread": get("thread") })
        } else {
          count_up(count_rows, table)
        }
      }
      "pins" =>
        if insert_row(db, "pins", r, " OR IGNORE").0 > 0 {
          keep({ "viewer": get("viewer"), "session": get("session") })
        } else {
          count_up(count_rows, "pins")
        }
      "opened_chats" => {
        if get("parent_station") is String("") {
          r["parent_station"] = nullish(c.get("from"))
        }
        if insert_row(db, "opened_chats", r, " OR IGNORE").0 > 0 {
          keep({ "child_station": get("child_station"), "child": get("child") })
        } else {
          count_up(count_rows, "opened_chats")
        }
      }
      "deliveries" => {
        let t = thread(get("thread"))
        guard t is Some(t) else { continue }
        r["thread"] = nullish(field(t, "id"))
        r["n"] = n_of(Some(t), get("n"))
        r["delivered_at"] = Json::null()
        if insert_row(db, "deliveries", r, " OR IGNORE").0 > 0 {
          keep({
            "thread": get("thread"),
            "n": get("n"),
            "session": get("session"),
          })
        } else {
          count_up(count_rows, "deliveries")
        }
        touched.session(js_string(get("session")))
      }
      "usage" => {
        if !(get("thread") is Null) {
          r["thread"] = match thread(get("thread")) {
            Some(t) => nullish(field(t, "id"))
            None => Json::null()
          }
        }
        map_profile(r)
        if put_usage(db, r) {
          let list = ensure(made_rows, "usage", Json::array([]))
          if list is Array(a) {
            a.push({ "id": get("id") })
          }
        }
        count_up(count_rows, "usage")
      }
      "usage_files" => {
        r["path"] = moved_path(get("path"), from_data, to_data)
        match put_usage_file(db, r) {
          Fresh => {
            let list = ensure(made_rows, "usage_files", Json::array([]))
            if list is Array(a) {
              a.push({ "path": get("path") })
            }
          }
          Kept => ()
          Was(was) => made_before(ctx, "usage_files", "path", was)
        }
        count_up(count_rows, "usage_files")
      }
      "session_usage" => {
        let was = match
          db.all("SELECT * FROM session_usage WHERE session = ?", [
            get("session"),
          ]) {
          [x, ..] => Some(x)
          _ => None
        }
        if get("session") is String(_) &&
          get("usage") is String(_) &&
          (match was {
            Some(w) => col(w, "usage") != get("usage")
            None => true
          }) {
          ignore(
            db.run(
              "INSERT INTO session_usage (session, usage) VALUES (?1, ?2) ON CONFLICT (session) DO UPDATE SET usage = excluded.usage",
              [get("session"), get("usage")],
            ),
          )
          match was {
            None => {
              let list = ensure(made_rows, "session_usage", Json::array([]))
              if list is Array(a) {
                a.push({ "session": get("session") })
              }
            }
            Some(w) => made_before(ctx, "session_usage", "session", row_json(w))
          }
        }
        count_up(count_rows, "session_usage")
        touched.session(js_string(get("session")))
      }
      _ => ()
    }
  }
}

///|
/// handover.ts `madeBefore`.
fn made_before(ctx : Json, table : String, key : String, was : Json) -> Unit {
  made_before_keys(ctx, table, [key], was)
}

fn made_before_keys(ctx : Json, table : String, keys : Array[String], was : Json) -> Unit {
  let made = obj(nullish(field(ctx, "made")))
  let ours = (rows : Json?) => {
    match rows {
      Some(Array(rows)) =>
        rows.iter().any(x => keys.iter().all(k => field(x, k) == field(was, k)))
      _ => false
    }
  }
  if ours(field(nullish(made.get("rows")), table)) ||
    ours(field(nullish(made.get("before")), table)) {
    return
  }
  let before = obj(ensure(made, "before", Json::object(Map([]))))
  if ensure(before, table, Json::array([])) is Array(a) {
    a.push(was)
  }
}

///|
/// handover.ts `putUsage`: a call put in where none of its id is here; whether this put it in.
pub fn put_usage(db : @sql.Db, r : Map[String, Json]) -> Bool raise {
  guard r.get("id") is Some(String(_) as id) &&
    r.get("session") is Some(String(_)) &&
    r.get("at") is Some(Number(_, ..)) &&
    r.get("runtime") is Some(String(_)) else {
    return false
  }
  if db.all("SELECT 1 FROM usage WHERE id = ?", [id]).length() > 0 {
    return false
  }
  let have = columns_of(db, "usage")
  let cols = usage_columns.filter(c => have.contains(c) && r.contains(c))
  ignore(
    db.run(
      "INSERT INTO usage (\{cols.join(", ")}) SELECT \{cols.map(_ => "?").join(", ")} WHERE NOT EXISTS (SELECT 1 FROM usage WHERE id = ?)",
      cols.map(c => r.get(c).unwrap()) + [id],
    ),
  )
  db.all("SELECT 1 FROM usage WHERE id = ?", [id]).length() > 0
}

///|
/// What `put_usage_file` did: put it in anew, found it as far or further, or moved it on from the row it was.
priv enum PutFile {
  Fresh
  Kept
  Was(Json)
}

///|
/// handover.ts `putUsageFile`: how far a transcript was read, never back from further than it was read here.
fn put_usage_file(db : @sql.Db, r : Map[String, Json]) -> PutFile raise {
  guard r.get("path") is Some(String(_) as path) &&
    r.get("offset") is Some(Number(offset, ..)) else {
    return Kept
  }
  let was = match db.all("SELECT * FROM usage_files WHERE path = ?", [path]) {
    [x, ..] => Some(x)
    _ => None
  }
  match was {
    Some(w) if num_of(col(w, "offset")).unwrap_or(0.0) >= offset => Kept
    None => {
      ignore(insert_row(db, "usage_files", r, ""))
      Fresh
    }
    Some(w) => {
      let have = columns_of(db, "usage_files")
      let cols = []
      for k, _ in r {
        if have.contains(k) && k != "path" {
          cols.push(k)
        }
      }
      ignore(
        db.run(
          "UPDATE usage_files SET \{cols.map(k => "\{k} = ?").join(", ")} WHERE path = ?",
          cols.map(k => r.get(k).unwrap()) + [path],
        ),
      )
      Was(row_json(w))
    }
  }
}

///|
/// handover.ts `dropImport`: what a hand-over that failed put in, taken out (in the store's transaction), but the
/// sessions put in anew, said back.
fn drop_import_rows(db : @sql.Db, ctx : Json) -> Array[String] raise {
  let made = nullish(field(ctx, "made"))
  for r in arr(nullish(field(made, "entries"))) {
    let x = arr(r)
    ignore(
      db.run("DELETE FROM entries WHERE thread = ? AND n BETWEEN ? AND ?", [
        x[0],
        x[1],
        x[2],
      ]),
    )
  }
  for r in arr(nullish(field(made, "letters"))) {
    let x = arr(r)
    ignore(
      db.run("DELETE FROM letters WHERE thread = ? AND n BETWEEN ? AND ?", [
        x[0],
        x[1],
        x[2],
      ]),
    )
  }
  for table, keys in obj(nullish(field(made, "rows"))) {
    for key in arr(keys) {
      let cols = []
      for k, _ in obj(key) {
        cols.push(k)
      }
      ignore(
        db.run(
          "DELETE FROM \{table} WHERE \{cols.map(c => "\{c} = ?").join(" AND ")}",
          cols.map(c => nullish(field(key, c))),
        ),
      )
    }
  }
  for m in arr(nullish(field(made, "members"))) {
    let x = arr(m)
    ignore(
      db.run("DELETE FROM thread_sessions WHERE thread = ? AND session = ?", [
        x[0],
        x[1],
      ]),
    )
  }
  for table, rows in obj(nullish(field(made, "before"))) {
    for row in arr(rows) {
      let have = columns_of(db, table)
      if table == "threads" &&
        have.contains("project") &&
        have.contains("project_locked") &&
        have.contains("tags") {
        let rid = nullish(field(row, "id"))
        let mut meta : Map[String, Json]? = None
        for _, v in obj(nullish(field(ctx, "threads"))) {
          if v is Object(o) && nullish(o.get("id")) == rid {
            meta = Some(o)
            break
          }
        }
        match (db.all("SELECT * FROM threads WHERE id = ?", [rid]), meta) {
          ([cur, ..], Some(m)) => {
            let cur_proj = col(cur, "project")
            let cur_locked = if col(cur, "project_locked") == jnum(1.0) { jnum(1.0) } else { jnum(0.0) }
            let cur_tags = match col(cur, "tags") {
              String(s) if s != "" => jstr(s)
              _ => Json::null()
            }
            let last_proj = nullish(m.get("lastProject"))
            let last_locked = match m.get("lastLocked") {
              Some(Number(n, ..)) => jnum(n)
              _ => jnum(0.0)
            }
            let last_tags = nullish(m.get("lastTags"))
            if cur_proj == last_proj && cur_locked == last_locked && cur_tags == last_tags {
              ignore(
                db.run(
                  "UPDATE threads SET project = ?, project_locked = ?, tags = ? WHERE id = ?",
                  [
                    nullish(field(row, "project")),
                    match field(row, "project_locked") {
                      Some(Number(n, ..)) => jnum(n)
                      _ => jnum(0.0)
                    },
                    nullish(field(row, "tags")),
                    rid,
                  ],
                ),
              )
            }
            continue
          }
          _ => ()
        }
      }
      let cols = []
      for k, _ in obj(row) {
        if have.contains(k) {
          cols.push(k)
        }
      }
      ignore(
        db.run(
          "INSERT OR REPLACE INTO \{table} (\{cols.join(", ")}) VALUES (\{cols.map(_ => "?").join(", ")})",
          cols.map(c => nullish(field(row, c))),
        ),
      )
    }
  }
  for s in arr(nullish(field(made, "sessions"))) {
    let before = nullish(field(s, "before"))
    if before is Null {
      continue
    }
    let have = columns_of(db, "sessions")
    let cols = []
    for k, _ in obj(before) {
      if have.contains(k) && k != "key" {
        cols.push(k)
      }
    }
    ignore(
      db.run(
        "UPDATE sessions SET \{cols.map(c => "\{c} = ?").join(", ")} WHERE key = ?",
        cols.map(c => nullish(field(before, c))) + [nullish(field(s, "key"))],
      ),
    )
  }
  arr(nullish(field(made, "sessions")))
  .filter(s => nullish(field(s, "before")) is Null)
  .map(s => js_string(nullish(field(s, "key"))))
}

///|
/// handover.ts `dropEmptyThreads`: the threads put in anew left with no session, gone with what is of them.
fn drop_empty_threads(db : @sql.Db, ctx : Json) -> Array[Json] raise {
  let gone = []
  for _, t in obj(nullish(field(ctx, "threads"))) {
    let id = nullish(field(t, "id"))
    if !(field(t, "fresh") is Some(True)) ||
      db
      .all("SELECT 1 FROM thread_sessions WHERE thread = ? LIMIT 1", [id])
      .length() >
      0 {
      continue
    }
    for table in ["entries", "letters", "closed_cards", "entry_proposals", "proposal_outcomes", "deliveries"] {
      ignore(db.run("DELETE FROM \{table} WHERE thread = ?", [id]))
    }
    ignore(db.run("DELETE FROM threads WHERE id = ?", [id]))
    gone.push(id)
  }
  gone
}

///|
/// handover.ts `handedWithUsage`.
pub fn handed_with_usage(
  db : @sql.Db,
  station : Json,
  after : Json,
  limit : Int32,
) -> Array[Json] raise {
  db
  .all(
    (
      #|SELECT h.session, h.ws, h.thread, h.there FROM handed_over h WHERE h.session > ? AND h.station = ?
      #|    AND (EXISTS (SELECT 1 FROM usage u INDEXED BY usage_session WHERE u.session = h.session LIMIT 1)
      #|      OR EXISTS (SELECT 1 FROM session_usage su WHERE su.session = h.session LIMIT 1))
      #|    ORDER BY h.session LIMIT ?
    ),
    [after, station, ints(limit)],
  )
  .map(row_json)
}

///|
/// handover.ts `handedStations`.
pub fn handed_stations(db : @sql.Db) -> Array[Json] raise {
  db
  .all("SELECT DISTINCT station FROM handed_over", [])
  .map(r => col(r, "station"))
}

///|
/// handover.ts `threadRefs`.
pub fn thread_refs(
  db : @sql.Db,
  session : Json,
  ids : Array[Json],
) -> Array[Json] raise {
  let out : Array[Json] = []
  let seen = []
  for id in ids {
    if seen.contains(id) {
      continue
    }
    seen.push(id)
    let t = match
      db.all(
        "SELECT id, surface, channel, thread_ts, home FROM threads WHERE id = ?",
        [id],
      ) {
      [x, ..] => x
      _ => continue
    }
    let m = match
      db.all(
        "SELECT connect FROM thread_sessions WHERE thread = ? AND session = ?",
        [id, session],
      ) {
      [x, ..] => col(x, "connect")
      _ => Json::null()
    }
    out.push({
      "id": id,
      "surface": jstr(js_string(col(t, "surface"))),
      "channel": jstr(js_string(col(t, "channel"))),
      "threadTs": jstr(js_string(col(t, "thread_ts"))),
      "home": col(t, "home"),
      "connect": m,
    })
  }
  out
}

///|
/// handover.ts `threadOfRef`.
pub fn thread_of_ref(
  db : @sql.Db,
  session : Json,
  ref_ : Json,
  connects : Json,
) -> Json raise {
  let get = (k : String) => nullish(field(ref_, k))
  let at = db.all(
    "SELECT id FROM threads WHERE surface = ? AND channel = ? AND thread_ts = ?",
    [
      jstr(surface_here(js_string(get("surface")), connects)),
      get("channel"),
      get("threadTs"),
    ],
  )
  if at is [a, ..] &&
    (
      get("surface") != jstr(stillfail_surface) ||
      db
      .all("SELECT 1 FROM thread_sessions WHERE thread = ? AND session = ?", [
        col(a, "id"),
        session,
      ])
      .length() >
      0
    ) {
    return col(a, "id")
  }
  match
    db.all(
      "SELECT t.id FROM thread_sessions m JOIN threads t ON t.id = m.thread WHERE m.session = ? AND t.channel = ? AND t.thread_ts = ? LIMIT 1",
      [session, get("channel"), get("threadTs")],
    ) {
    [o, ..] => col(o, "id")
    _ => Json::null()
  }
}

///|
/// handover.ts `hasUsage`.
pub fn has_usage(db : @sql.Db, session : Json) -> Bool raise {
  db
  .all(
    "SELECT 1 FROM usage INDEXED BY usage_session WHERE session = ? LIMIT 1",
    [session],
  )
  .length() >
  0
}

///|
/// handover.ts `importHandedUsage`: a page of a handed chat's calls and transcripts' places, put in (`in_tx`: in the
/// caller's transaction, else one of its own).
pub fn import_handed_usage(db : @sql.Db, a : Json, in_tx : Bool) -> Json raise {
  let get = (k : String) => nullish(field(a, k))
  let mut added = 0
  let mut files = 0
  let session = get("session")
  let from_data = js_string(get("fromData"))
  let to_data = js_string(get("toData"))
  let run = () => {
    for r0 in arr(get("usage")) {
      if field(r0, "session") != Some(session) {
        continue
      }
      let r = obj(r0).copy()
      if !(nullish(r.get("thread")) is Null) {
        r["thread"] = nullish(
          field(get("threads"), key_of(nullish(r.get("thread")))),
        )
      }
      if r.get("profile") is Some(String(p)) &&
        field(get("profiles"), p) is Some(to) {
        r["profile"] = to
      }
      if put_usage(db, r) {
        added += 1
      }
    }
    for f0 in arr(get("files")) {
      if field(f0, "session") != Some(session) {
        continue
      }
      let f = obj(f0).copy()
      f["path"] = moved_path(nullish(f.get("path")), from_data, to_data)
      if !(put_usage_file(db, f) is Kept) {
        files += 1
      }
    }
  }
  if in_tx {
    run()
  } else {
    db.exec("BEGIN IMMEDIATE")
    errdefer (db.exec("ROLLBACK") catch { _ => () })
    run()
    db.exec("COMMIT")
  }
  { "added": ints(added), "files": ints(files) }
}

// ── the store's hand-overs ──

///|
pub fn Store::chat_threads(
  self : Store,
  keys : Array[String],
  after : Json,
  limit : Int32,
) -> Array[Json] raise {
  chat_threads(self.db, keys, after, limit)
}

///|
pub fn Store::chat_page(
  self : Store,
  table : String,
  of : Json,
  after : Json,
  limit : Int32,
  keys : Array[String],
) -> Array[Json] raise {
  chat_page(self.db, table, of, after, limit, keys)
}

///|
/// store.ts `readPosition`.
fn Store::read_position(
  self : Store,
  viewer : Json,
  thread : Json,
) -> Json raise {
  match
    self.one("SELECT n FROM reads WHERE viewer = ? AND thread = ?", [
      viewer, thread,
    ]) {
    Some(r) => or_else(col(r, "n"), jnum(0.0))
    None => jnum(0.0)
  }
}

///|
/// A page of another station's chat's rows put in, one transaction (`id`: the hand-over's, whose ctx is kept with
/// the rows). `ctx` is changed as it says what was put in.
pub fn Store::import_rows(
  self : Store,
  ctx : Json,
  table : String,
  rows : Array[Json],
  id : Json?,
) -> Unit raise {
  self.with_changes(changes => {
    let touched = { sessions: [], threads: [], marks: [], }
    self.tx(() => {
      import_page(self.db, ctx, table, rows, touched)
      if id is Some(id) {
        ignore(
          self.run(
            "INSERT INTO handover_in (id, ctx) VALUES (?1, ?2) ON CONFLICT (id) DO UPDATE SET ctx = ?2",
            [id, jstr(js(ctx))],
          ),
        )
      }
    })
    for key in touched.sessions {
      self.ws_of.remove(key)
    }
    for key in touched.sessions {
      changes.push(session_change(jstr(key)))
    }
    for id in touched.threads {
      changes.push(thread_change(id))
    }
    for c in touched.marks {
      if field(c, "type") is Some(String("read")) && field(c, "n") is Some(Null) {
        obj(c)["n"] = self.read_position(
          nullish(field(c, "viewer")),
          nullish(field(c, "thread")),
        )
      }
      changes.push(c)
    }
    if touched.sessions.length() > 0 {
      self.session_workspace_changed()
    }
  })
}

///|
pub fn Store::import_ctx(self : Store, id : Json) -> Json raise {
  match self.one("SELECT ctx FROM handover_in WHERE id = ?", [id]) {
    None => Json::null()
    Some(r) => js_parse(js_string(col(r, "ctx")))
  }
}

///|
pub fn Store::forget_import(self : Store, id : Json) -> Unit raise {
  ignore(self.run("DELETE FROM handover_in WHERE id = ?", [id]))
}

///|
/// What a hand-over that failed put in (`ctx`), taken out.
pub fn Store::drop_import(self : Store, ctx : Json) -> Unit raise {
  let fresh = self.with_changes(changes => {
    let fresh = self.tx(() => drop_import_rows(self.db, ctx))
    for s in arr(nullish(field(nullish(field(ctx, "made")), "sessions"))) {
      let key = js_string(nullish(field(s, "key")))
      self.ws_of.remove(key)
      changes.push(session_change(jstr(key)))
    }
    fresh
  })
  for key in fresh {
    self.delete_session(key)
  }
  self.with_changes(changes => {
    for id in self.tx(() => drop_empty_threads(self.db, ctx)) {
      changes.push({ "type": "threadRemoved", "id": id })
    }
  })
  self.session_workspace_changed()
}

///|
/// Sessions `keys` put in from another station shown: of workspace `ws` (null: the home one) from now on.
pub fn Store::show_chat(
  self : Store,
  keys : Array[String],
  ws : Json,
) -> Unit raise {
  self.with_changes(changes => {
    let settled_sessions : Array[String] = []
    let settled_threads : Array[Json] = []
    self.tx(() => {
      for key in keys {
        ignore(
          self.run("UPDATE sessions SET ws = ? WHERE key = ?", [ws, jstr(key)]),
        )
        if self.run("DELETE FROM handed_over WHERE session = ?", [jstr(key)]) >
          0 {
          changes.push({
            "type": "moved",
            "key": jstr(key),
            "station": Json::null(),
            "ws": ws,
            "thread": Json::null(),
            "there": Json::null(),
          })
        }
      }
      let birth_ids : Array[Json] = []
      for key in keys {
        for tid in @sql.birth_threads_of(self.db, key) {
          if !birth_ids.contains(tid) {
            birth_ids.push(tid)
          }
        }
      }
      let now = self.now_json()
      for tid in birth_ids {
        let (ss, ts) = @sql.settle_conversation_in_tx(self.db, tid, now)
        for s in ss {
          if !settled_sessions.contains(s) {
            settled_sessions.push(s)
          }
        }
        for id in ts {
          if !settled_threads.contains(id) {
            settled_threads.push(id)
          }
        }
      }
    })
    for key in keys {
      self.ws_of.remove(key)
      self.handed.remove(key)
      changes.push(session_change(jstr(key)))
      for t in self.session_threads(jstr(key)) {
        changes.push(thread_change(thread_id_of(t)))
      }
    }
    for s in settled_sessions {
      if !keys.contains(s) {
        changes.push(session_change(jstr(s)))
      }
    }
    for id in settled_threads {
      changes.push(thread_change(id))
    }
    self.session_workspace_changed()
  })
}

///|
fn handed_away(ws : Json) -> Bool {
  ws is String(w) && w.has_prefix(handed_ws(""))
}

///|
/// Sessions `keys` said gone to `station` whose hand-over did not go after all: in sight here as they were.
pub fn Store::not_gone(
  self : Store,
  keys : Array[String],
  station : Json,
) -> Array[String] raise {
  let back = []
  self.with_changes(changes => {
    self.tx(() => {
      for key in keys {
        let row = self.one("SELECT ws FROM sessions WHERE key = ?", [jstr(key)])
        guard row is Some(row) else { continue }
        if handed_away(col(row, "ws")) {
          continue
        }
        if self.run(
            "DELETE FROM handed_over WHERE session = ? AND station = ?",
            [jstr(key), station],
          ) ==
          0 {
          continue
        }
        back.push(key)
        changes.push({
          "type": "moved",
          "key": jstr(key),
          "station": Json::null(),
          "ws": col(row, "ws"),
          "thread": Json::null(),
          "there": Json::null(),
        })
      }
    })
    for key in back {
      self.handed.remove(key)
      self.ws_of.remove(key)
      changes.push(session_change(jstr(key)))
    }
    if back.length() > 0 {
      self.session_workspace_changed()
    }
  })
  back
}

///|
/// Sessions `keys` went to `station`: where each went kept, with its chat's thread here and there.
pub fn Store::gone_to(
  self : Store,
  keys : Array[String],
  station : Json,
  threads : Json,
) -> Unit raise {
  self.with_changes(_ => {
    self.tx(() => {
      for key in keys {
        let row = self.one("SELECT ws FROM sessions WHERE key = ?", [jstr(key)])
        guard row is Some(row) else { continue }
        let ws = col(row, "ws")
        if handed_away(ws) {
          continue
        }
        let t = match field(threads, key) {
          Some(t) => t
          None => { "thread": Json::null(), "there": Json::null() }
        }
        ignore(
          self.run(
            "INSERT INTO handed_over (session, station, ws, thread, there, at) VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT (session) DO UPDATE SET station = ?2, ws = ?3, thread = ?4, there = ?5, at = ?6",
            [
              jstr(key),
              station,
              ws,
              nullish(field(t, "thread")),
              nullish(field(t, "there")),
              self.now_json(),
            ],
          ),
        )
      }
    })
    for key in keys {
      self.handed.remove(key)
    }
  })
}

///|
/// Sessions `keys`, gone, shown where they went: out of sight here (`home` names the home one's), devices told.
pub fn Store::shown_there(
  self : Store,
  keys : Array[String],
  home : Json,
) -> Unit raise {
  self.with_changes(changes => {
    self.tx(() => {
      for key in keys {
        let row = self.one("SELECT ws FROM sessions WHERE key = ?", [jstr(key)])
        let h = self.one("SELECT * FROM handed_over WHERE session = ?", [
          jstr(key),
        ])
        guard row is Some(row) && h is Some(h) else { continue }
        let ws = col(row, "ws")
        if handed_away(ws) {
          continue
        }
        let named = js_string(or_else(or_else(ws, home), jstr("")))
        ignore(
          self.run(
            "UPDATE sessions SET ws = ?, came_from = NULL WHERE key = ?",
            [jstr(handed_ws(named)), jstr(key)],
          ),
        )
        changes.push({
          "type": "moved",
          "key": jstr(key),
          "station": col(h, "station"),
          "ws": ws,
          "thread": col(h, "thread"),
          "there": col(h, "there"),
        })
      }
    })
    for key in keys {
      self.ws_of.remove(key)
      self.handed.remove(key)
      changes.push(session_change(jstr(key)))
    }
    self.session_workspace_changed()
  })
}

///|
/// What sessions `keys` had yet to be handed here went with them.
pub fn Store::delivered_there(self : Store, keys : Array[String]) -> Unit raise {
  self.tx(() => {
    for key in keys {
      ignore(
        self.run(
          "UPDATE deliveries SET delivered_at = ?2 WHERE session = ?1 AND delivered_at IS NULL",
          [jstr(key), self.now_json()],
        ),
      )
    }
  })
}

///|
/// Of sessions `keys`, those this station has in sight.
pub fn Store::live_of(self : Store, keys : Array[String]) -> Array[Json] raise {
  if keys.length() == 0 {
    return []
  }
  self
  .all(
    (
      #|SELECT key FROM sessions WHERE key IN (SELECT value FROM json_each(?1))
      #|      AND (ws IS NULL OR (ws NOT LIKE 'handed:%' AND ws NOT LIKE 'coming:%' AND ws NOT LIKE 'retired:%'))
    ),
    [jstr(js(strings(keys)))],
  )
  .map(r => jstr(js_string(col(r, "key"))))
}

///|
/// Where session `key` was handed (null: it was not, or came back): kept in memory once read.
pub fn Store::handed_to(self : Store, key : String) -> Json raise {
  if self.handed.get(key) is Some(h) {
    return h
  }
  let h = match
    self.one("SELECT * FROM handed_over WHERE session = ?", [jstr(key)]) {
    None => Json::null()
    Some(r) => handed_of(jstr(key), r, "")
  }
  if !self.in_tx() {
    self.handed[key] = h
  }
  h
}

///|
pub fn Store::handed_chats(
  self : Store,
  after : Json,
  limit : Json,
) -> Array[Json] raise {
  self
  .all("SELECT * FROM handed_over WHERE session > ? ORDER BY session LIMIT ?", [
    after, limit,
  ])
  .map(r => handed_of(col(r, "session"), r, ""))
}

///|
pub fn Store::set_moved_note(
  self : Store,
  session : String,
  text : Json,
) -> Unit raise {
  ignore(
    self.run(
      "INSERT INTO moved_notes (session, text, told_at) VALUES (?1, ?2, NULL) ON CONFLICT (session) DO UPDATE SET text = ?2, told_at = NULL",
      [jstr(session), text],
    ),
  )
  self.moved_untold[session] = ()
}

///|
pub fn Store::sessions_of_connect(
  self : Store,
  id : Json,
  limit : Json,
  after : Json,
) -> Array[Json] raise {
  self
  .all(
    "SELECT key FROM sessions WHERE connect = ? AND key > ? ORDER BY key LIMIT ?",
    [id, after, limit],
  )
  .map(r => col(r, "key"))
}

///|
/// The sessions of workspace `ws` (null: the home one's) after `after`, at most `limit`, handed ones with them.
pub fn Store::sessions_of_ws(
  self : Store,
  ws : Json,
  home : Json,
  after : Json,
  limit : Int32,
) -> Array[Json] raise {
  let named = if ws is Null { home } else { ws }
  let page = "SELECT key FROM sessions WHERE COALESCE(ws, '') = ? AND key > ? ORDER BY key LIMIT ?"
  let own = self.all(page, [or_else(ws, jstr("")), after, ints(limit)])
  let named_ = if ws is Null && home is String(h) && h != "" {
    self.all(page, [home, after, ints(limit)])
  } else {
    []
  }
  let handed = self.all(page, [
    jstr(handed_ws(js_string(or_else(named, jstr(""))))),
    after,
    ints(limit),
  ])
  let keys = []
  for r in own + named_ + handed {
    let k = js_string(col(r, "key"))
    if !keys.contains(k) {
      keys.push(k)
    }
  }
  let sorted = js_sorted(keys)
  let n = if sorted.length() < limit {
    sorted.length()
  } else if limit < 0 {
    0
  } else {
    limit
  }
  strings(sorted[:n].to_array()) |> arr
}

///|
/// Of sessions `keys`: those that are the home of a still.fail chat, with that chat's sessions.
pub fn Store::stillfail_homes(
  self : Store,
  keys : Array[String],
) -> Array[(String, Array[String])] raise {
  let out : Array[(String, Array[String])] = []
  if keys.length() == 0 {
    return out
  }
  let first : Map[String, Json] = Map([])
  let sql =
    "SELECT kind, id, k, surface, member FROM (\n" +
    "  SELECT 0 AS kind, t.id AS id, j.value AS k, t.surface AS surface, m.session AS member, m.joined_at AS j, m.rowid AS r\n" +
    "    FROM json_each(?1) j\n" +
    "    JOIN sessions s ON s.key = j.value\n" +
    "    JOIN threads t INDEXED BY threads_home ON t.home = COALESCE(NULLIF(s.conv, ''), s.key)\n" +
    "    LEFT JOIN thread_sessions m ON m.thread = t.id\n" +
    "  UNION ALL\n" +
    "  SELECT 1 AS kind, 0 AS id, j.value AS k, ?3 AS surface, p.key AS member, 0 AS j, 0 AS r\n" +
    "    FROM json_each(?1) j\n" +
    "    JOIN sessions s ON s.key = j.value\n" +
    "    JOIN sessions p INDEXED BY sessions_conv_grouped\n" +
    "      ON p.conv IS NOT NULL AND p.conv != p.key\n" +
    "     AND p.conv = COALESCE(NULLIF(s.conv, ''), s.key)\n" +
    "     AND (p.ws IS NULL OR (p.ws NOT LIKE 'handed:%' AND p.ws NOT LIKE 'coming:%'))\n" +
    "  UNION ALL\n" +
    "  SELECT 1 AS kind, 0 AS id, s.key AS k, ?3 AS surface, s.conv AS member, 0 AS j, 0 AS r\n" +
    "    FROM sessions s\n" +
    "    WHERE s.key IN (SELECT value FROM json_each(?1))\n" +
    "      AND s.conv IS NOT NULL AND s.conv != '' AND s.conv != s.key\n" +
    ") ORDER BY kind, id, j, r LIMIT ?2"
  for
    r in self.all(
      sql,
      [jstr(js(strings(keys))), ints(keys.length() * 64), jstr(stillfail_surface)],
    ) {
    let home = js_string(col(r, "k"))
    if col(r, "kind") == Json::number(0.0) {
      if !first.contains(home) {
        first[home] = col(r, "id")
      }
      if first.get(home) != Some(col(r, "id")) ||
        col(r, "surface") != jstr(stillfail_surface) {
        continue
      }
    }
    let mut at = -1
    for i, e in out {
      if e.0 == home {
        at = i
      }
    }
    if at < 0 {
      out.push((home, []))
      at = out.length() - 1
    }
    if col(r, "member") is String(s) && !out[at].1.contains(s) {
      out[at].1.push(s)
    }
  }
  out
}

///|
/// The accounts sessions `keys`' runtime sessions ran on, each session's in order, in one statement.
pub fn Store::ran_on_of(
  self : Store,
  keys : Array[String],
) -> Array[(String, Array[String])] raise {
  let out : Array[(String, Array[String])] = []
  if keys.length() == 0 {
    return out
  }
  for
    r in self.all(
      "SELECT session_key, profile, MIN(id) AS first FROM runtime_sessions WHERE session_key IN (SELECT value FROM json_each(?)) AND profile IS NOT NULL GROUP BY session_key, profile ORDER BY session_key, first LIMIT ?",
      [jstr(js(strings(keys))), ints(keys.length() * 64)],
    ) {
    let key = js_string(col(r, "session_key"))
    let mut at = -1
    for i, e in out {
      if e.0 == key {
        at = i
      }
    }
    if at < 0 {
      out.push((key, []))
      at = out.length() - 1
    }
    out[at].1.push(js_string(col(r, "profile")))
  }
  out
}

///|
pub fn Store::drop_connect_thread_station(
  self : Store,
  connect : Json,
  channel : Json,
  thread_ts : Json,
) -> Unit raise {
  ignore(
    self.run(
      "DELETE FROM connect_threads WHERE connect = ? AND channel = ? AND thread_ts = ?",
      [connect, channel, thread_ts],
    ),
  )
}

// ── single-session bindings ──

///|
pub fn Store::binding(self : Store, connect : Json) -> Json raise {
  match
    self.one("SELECT session_key FROM bindings WHERE connect = ?", [connect]) {
    Some(r) => col(r, "session_key")
    None => Json::null()
  }
}

///|
/// Binds a connect to a session, or unbinds it (null).
pub fn Store::set_binding(
  self : Store,
  connect : Json,
  session : Json,
) -> Unit raise {
  self.with_changes(changes => {
    let before = self.binding(connect)
    if session is Null {
      ignore(self.run("DELETE FROM bindings WHERE connect = ?", [connect]))
    } else {
      ignore(
        self.run(
          "INSERT OR REPLACE INTO bindings (connect, session_key) VALUES (?, ?)",
          [connect, session],
        ),
      )
    }
    let keys = []
    for k in [before, session] {
      if k is String(s) && !keys.contains(s) {
        keys.push(s)
      }
    }
    keys.sort_by(by_bytes)
    for key in keys {
      changes.push(session_change(jstr(key)))
    }
  })
}

///|
/// Connects bound to each session (by session key, in UTF-8 order).
pub fn Store::list_bindings(self : Store) -> Json raise {
  let out : Array[(String, Array[Json])] = []
  for r in self.all("SELECT connect, session_key FROM bindings", []) {
    let key = js_string(col(r, "session_key"))
    let mut at = -1
    for i, e in out {
      if e.0 == key {
        at = i
      }
    }
    if at < 0 {
      out.push((key, []))
      at = out.length() - 1
    }
    out[at].1.push(col(r, "connect"))
  }
  out.sort_by((a, b) => by_bytes(a.0, b.0))
  entries(out.map(e => (e.0, Json::array(e.1))))
}

///|
pub fn Store::prepared_session_bound(self : Store, key : Json) -> Bool raise {
  self.one(session_bindings_exists, [key]) is Some(_)
}
