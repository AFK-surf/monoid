// The store's rows as station/src/store/rows.ts reads them (`toSession`, `toTurnSummary`, `toJob`, …): the same
// fields, the same JavaScript tests of each column, what it leaves out left out.

///|
/// rows.ts STILLFAIL_SURFACE.
let stillfail_surface : String = "chat"

///|
/// rows.ts STILLFAIL_CONNECT.
let internal_connect : String = "chat"

///|
/// rows.ts FORMER_OWN_NAMES.
let former_own_names : Array[String] = ["ember", "stillfail"]

///|
/// rows.ts MANUAL.
let manual : String = "manual"

///|
/// rows.ts XSHARE_IDLE_MS.
let xshare_idle_ms : Double = 21600000.0

///|
/// rows.ts `handedWs`.
fn handed_ws(ws : String) -> String {
  "handed:\{ws}"
}

///|
/// rows.ts `saidBefore`.
fn said_before(declared : String) -> String {
  match declared {
    "all_done" => "final"
    "need_decision" | "need_help" => "block"
    _ => declared
  }
}

///|
/// rows.ts `ending`.
fn ending_of(declared : String) -> String {
  match declared {
    "final" => "all_done"
    "block" | "need_decision" => "need_help"
    _ => declared
  }
}

///|
/// rows.ts `parseProfiles`.
fn parse_profiles(raw : Json, profile : Json, pinned : Bool) -> Json {
  if raw is String(s) && s != "" {
    if (Some(js_parse(s)) catch { _ => None }) is Some(Array(items)) {
      let list = items.filter(x => x is String(p) && p != "")
      if list.length() > 0 {
        return Json::array(list)
      }
    }
  }
  if pinned {
    Json::array([profile])
  } else {
    Json::null()
  }
}

///|
/// `r.x === null || r.x === undefined ? null : r.x !== 0`.
fn opt_bool_col(v : Json) -> Json {
  match v {
    Null => Json::null()
    v => jbool(!is_n(v, 0.0))
  }
}

///|
/// rows.ts `toSession`.
fn to_session(r : Map[String, Json]) -> Json {
  let pinned = is_n(col(r, "profile_pinned"), 1.0)
  let o : Map[String, Json] = Map([])
  o["key"] = col(r, "key")
  o["connect"] = col(r, "connect")
  o["scope"] = jstr(
    if col(r, "scope") is String("all") {
      "all"
    } else {
      "thread"
    },
  )
  o["title"] = col(r, "title")
  o["createdBy"] = col(r, "created_by")
  o["runtime"] = col(r, "runtime")
  o["profile"] = col(r, "profile")
  o["profilePinned"] = jbool(pinned)
  o["profiles"] = parse_profiles(col(r, "profiles"), col(r, "profile"), pinned)
  o["model"] = col(r, "model")
  o["effort"] = col(r, "effort")
  if col(r, "tui") == Json::number(1.0) { o["tui"] = Json::boolean(true) }
  if col(r, "speed") is String(_) {
    o["speed"] = col(r, "speed")
  }
  o["fast"] = opt_bool_col(col(r, "fast"))
  o["afresh"] = opt_bool_col(col(r, "afresh"))
  o["context"] = if col(r, "context") is Number(_, ..) {
    col(r, "context")
  } else {
    Json::null()
  }
  o["contextBefore"] = if col(r, "context_before") is Number(_, ..) {
    col(r, "context_before")
  } else {
    Json::null()
  }
  if col(r, "compactions") is (Number(n, ..) as c) && n > 0.0 {
    o["compactions"] = c
  }
  o["runtimeSessionId"] = col(r, "runtime_session_id")
  o["workspace"] = col(r, "workspace")
  o["cwd"] = col(r, "cwd")
  o["ws"] = col(r, "ws")
  o["token"] = col(r, "token")
  o["running"] = jbool(is_n(col(r, "running"), 1.0))
  o["createdAt"] = col(r, "created_at")
  o["lastActiveAt"] = col(r, "last_active_at")
  o["archivedAt"] = col(r, "archived_at")
  o["archivedBy"] = col(r, "archived_by")
  o["shownAt"] = col(r, "shown_at")
  if col(r, "came_from") is String(from) && from != "" {
    o["from"] = jstr(from)
  }
  Json::object(o)
}

fn parse_thread_links_j(v : Json) -> Json? {
  match v {
    String(s) if s != "" =>
      match (try { Some(@json.parse(s)) } catch { _ => None }) {
        Some(Object(m)) => {
          let out : Map[String, Json] = Map([])
          match m.get("web") {
            Some(String(w)) if w != "" => out["web"] = Json::string(w)
            _ => ()
          }
          match m.get("app") {
            Some(String(a)) if a != "" => out["app"] = Json::string(a)
            _ => ()
          }
          if out.is_empty() { None } else { Some(Json::object(out)) }
        }
        _ => None
      }
    _ => None
  }
}

///|
/// rows.ts `toThread`.
fn to_thread(r : Map[String, Json]) -> Json {
  let out : Map[String, Json] = {
    "id": col(r, "id"),
    "surface": col(r, "surface"),
    "channel": col(r, "channel"),
    "threadTs": col(r, "thread_ts"),
    "title": col(r, "title"),
    "autoTitle": col(r, "auto_title"),
    "createdBy": col(r, "created_by"),
    "createdAt": col(r, "created_at"),
    "home": col(r, "home"),
    "hiddenAt": col(r, "hidden_at"),
    "hiddenBy": col(r, "hidden_by"),
    "shownAt": col(r, "shown_at"),
  }
  match parse_thread_links_j(col(r, "links")) {
    Some(l) => out["links"] = l
    None => ()
  }
  Json::object(out)
}

///|
/// rows.ts `toSessionThread`.
fn to_session_thread(r : Map[String, Json]) -> Json {
  { "thread": to_thread(r), "connect": col(r, "connect") }
}

///|
/// rows.ts `toTurnSummary`.
fn to_turn_summary(r : Map[String, Json]) -> Json {
  let declared = col(r, "declared")
  let about = match
    (col(r, "about_thread"), col(r, "about_n"), col(r, "about_ts")) {
    (Null, _, _) | (_, Null, _) | (_, _, Null) => Json::null()
    (t, n, ts) => { "thread": t, "seq": n, "ts": ts }
  }
  {
    "kind": col(r, "kind"),
    "outcome": col(r, "outcome"),
    "declared": match declared {
      Null => Json::null()
      String(d) => jstr(said_before(d))
      d => d
    },
    "ending": match declared {
      Null => Json::null()
      String(d) => jstr(ending_of(d))
      d => d
    },
    "need": col(r, "need"),
    "about": about,
    "waitSeconds": col(r, "wait_seconds"),
    "waitFor": col(r, "wait_for"),
    "waitWatch": match col(r, "wait_watch") {
      Null => Json::null()
      v => jbool(is_n(v, 1.0))
    },
    "detail": col(r, "detail"),
    "startedAt": col(r, "started_at"),
    "endedAt": col(r, "ended_at"),
  }
}

///|
/// rows.ts TurnRow.
fn to_turn_row(r : Map[String, Json]) -> Json {
  { "id": col(r, "id"), "summary": to_turn_summary(r) }
}

///|
/// rows.ts `toJob`.
fn to_job(r : Map[String, Json]) -> Json raise {
  let o : Map[String, Json] = Map([])
  o["id"] = col(r, "id")
  o["sessionKey"] = col(r, "session_key")
  o["name"] = col(r, "name")
  o["command"] = col(r, "command")
  o["cwd"] = col(r, "cwd")
  o["port"] = col(r, "port")
  o["token"] = col(r, "token")
  o["state"] = col(r, "state")
  o["pgid"] = col(r, "pgid")
  o["exitCode"] = col(r, "exit_code")
  o["startedAt"] = col(r, "started_at")
  o["endedAt"] = col(r, "ended_at")
  o["restarts"] = col(r, "restarts")
  o["log"] = col(r, "log")
  o["watch"] = jbool(!is_n(col(r, "watch"), 0.0))
  if is_n(col(r, "queued"), 1.0) {
    o["queued"] = jbool(true)
  }
  if is_n(col(r, "screen"), 1.0) {
    o["screen"] = jbool(true)
  }
  if is_n(col(r, "small"), 1.0) {
    o["small"] = jbool(true)
  }
  if col(r, "size") is String(size) && size.has_prefix("{") {
    o["sandbox"] = js_parse(size)
  }
  Json::object(o)
}

///|
/// rows.ts `toOpened`.
fn to_opened(r : Map[String, Json]) -> Json {
  {
    "childStation": col(r, "child_station"),
    "child": col(r, "child"),
    "parentStation": col(r, "parent_station"),
    "parent": col(r, "parent"),
    "key": col(r, "key"),
    "title": col(r, "title"),
    "link": col(r, "link"),
    "state": col(r, "state"),
    "createdAt": col(r, "created_at"),
    "openerTitle": col(r, "opener_title"),
    "led": match col(r, "led") {
      Null => Json::null()
      Number(n, ..) => jbool(n == 1.0)
      String(s) => jbool(s.trim().to_string() == "1")
      True => jbool(true)
      _ => jbool(false)
    },
  }
}

///|
/// rows.ts `toChatShare`: every workspace it names, those whose share lapsed too.
fn to_chat_share(r : Map[String, Json]) -> Json {
  let to = match col(r, "shared") {
    String(s) => js_parse(s) catch { _ => Json::array([]) }
    v => js_parse(js_string(v)) catch { _ => Json::array([]) }
  }
  let list : Array[Json] = match to {
    Array(items) =>
      items
      .filter(t => field(t, "workspace") is Some(String(_)))
      .map(t => {
        let ws = field(t, "workspace").unwrap()
        let name = match field(t, "name") {
          None | Some(Null) => ws
          Some(n) => n
        }
        {
          "workspace": ws,
          "name": jstr(js_string(name)),
          "used": match field(t, "used") {
            Some(Number(_, ..) as u) => u
            _ => col(r, "at")
          },
        }
      })
    _ => []
  }
  {
    "to": Json::array(list),
    "write": jbool(is_n(col(r, "write"), 1.0)),
    "by": col(r, "by"),
    "at": col(r, "at"),
  }
}

///|
/// rows.ts `shareLive`.
fn share_live(t : Json, now : Double) -> Bool {
  match field(t, "used") {
    Some(Number(used, ..)) => now - used < xshare_idle_ms
    _ => false
  }
}

///|
fn share_to(share : Json) -> Array[Json] {
  arr(nullish(field(share, "to")))
}

///|
/// rows.ts `liveShare`.
fn live_share(share : Json, now : Double) -> Json {
  let to = share_to(share).filter(t => share_live(t, now))
  if to.length() == 0 {
    return Json::null()
  }
  let o = obj(share).copy()
  o["to"] = Json::array(to)
  Json::object(o)
}

///|
/// A chat handed from here (rows.ts HandedChat), of a `handed_over` row (`p`: its columns' prefix).
fn handed_of(session : Json, r : Map[String, Json], p : String) -> Json {
  {
    "session": session,
    "station": col(r, p + "station"),
    "ws": col(r, p + "ws"),
    "thread": col(r, p + "thread"),
    "there": col(r, p + "there"),
    "at": col(r, p + "at"),
  }
}

///|
/// store.ts `workOfRow`.
fn work_of_row(r : Map[String, Json]?) -> Json {
  match r {
    None => undefined()
    Some(r) =>
      {
        "pending": jbool(!is_n(col(r, "pending"), 0.0)),
        "lastTurn": if col(r, "started_at") is Null {
          Json::null()
        } else {
          to_turn_summary(r)
        },
      }
  }
}
