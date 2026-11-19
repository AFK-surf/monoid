// What of the station's chats a viewer sees (station/src/api/seen.ts): those of their own workspace; a request naming
// a session, a chat or a job of another is answered as one naming what is not there.

///|
/// What `sessionSeen` and the rest ask of the store.
pub(all) struct SeenStore {
  /// store.sessionWs: none for a session not there, null for the home workspace's.
  session_ws : (String) -> J?
  thread_sessions : (Double) -> Array[String]
  /// store.getJob(id)?.sessionKey: none for a job not there.
  job_session : (String) -> String?
  session_there : (String) -> Bool
  thread_there : (Double) -> Bool
  /// store.handedTo: where a session was handed to (`{station, ws, thread, there}`), none if it was not.
  handed_to : (String) -> J?
}

///|
/// seen.ts `sessionSeen` (one not there: the home workspace's, but another station's task its workspace's).
pub fn session_seen(store : SeenStore, viewer : Viewer, key : String) -> Bool {
  match (store.session_ws)(key) {
    Some(ws) => sees(viewer, ws)
    None =>
      match @readops.remote_ws(key) {
        Some(w) => w == viewer.workspace
        None => sees(viewer, Null)
      }
  }
}

///|
/// seen.ts `threadSeen`.
pub fn thread_seen(store : SeenStore, viewer : Viewer, id : Double) -> Bool {
  let members = (store.thread_sessions)(id)
  if members.length() == 0 {
    sees(viewer, Null)
  } else {
    members.iter().any(m => session_seen(store, viewer, m))
  }
}

///|
/// seen.ts `jobSeen`.
pub fn job_seen(store : SeenStore, viewer : Viewer, id : String) -> Bool {
  match (store.job_session)(id) {
    None => true
    Some(s) => session_seen(store, viewer, s)
  }
}

///|
/// What events.ts `seen` answers, of any of the three.
pub fn seen_of(store : SeenStore, viewer : Viewer, of : Of) -> Bool {
  match of {
    Session(key) => session_seen(store, viewer, key)
    Thread(Num(id)) => thread_seen(store, viewer, id)
    // (a thread named by no number: none of its sessions is one, as a lookup of it finds none)
    Thread(_) => sees(viewer, Null)
    Job(id) => job_seen(store, viewer, id)
    Ws(ws) => sees(viewer, ws)
  }
}

///|
fn hex_value(c : Int32) -> Int32 {
  if c >= '0'.to_int() && c <= '9'.to_int() {
    c - '0'.to_int()
  } else if c >= 'a'.to_int() && c <= 'f'.to_int() {
    c - 'a'.to_int() + 10
  } else if c >= 'A'.to_int() && c <= 'F'.to_int() {
    c - 'A'.to_int() + 10
  } else {
    -1
  }
}

///|
/// request.ts `percentDecode` (a `+` is a space).
pub fn percent_decode(s : String) -> String {
  @url.percent_decode_lossy(s, plus_space=true)
}

///|
/// request.ts `segment`: a path's segment as the routes read a key (a + is a +).
pub fn segment(s : String) -> String {
  percent_decode(s.replace_all(old="+", new="%2B"))
}

///|
/// `^\/*(sessions|threads|jobs)\/+([^/]+)`: what a path names, by its kind.
fn named(path : String) -> (String, String)? {
  let mut i = 0
  let n = path.length()
  while i < n && path.unsafe_charcode_at(i) == '/'.to_int() {
    i += 1
  }
  for kind in ["sessions", "threads", "jobs"] {
    let rest = path.view(start_offset=i)
    if rest.has_prefix(kind + "/") {
      let mut j = i + kind.length()
      while j < n && path.unsafe_charcode_at(j) == '/'.to_int() {
        j += 1
      }
      let mut end = j
      while end < n && path.unsafe_charcode_at(end) != '/'.to_int() {
        end += 1
      }
      if end > j {
        return Some(
          (kind, path.view(start_offset=j, end_offset=end).to_string()),
        )
      }
      return None
    }
  }
  None
}

///|
/// `/^[+-]?\d+$/`, as a safe integer: a thread's number in a path.
fn thread_number(id : String) -> Double? {
  let digits = if id.has_prefix("+") || id.has_prefix("-") {
    id.view(start_offset=1).to_string()
  } else {
    id
  }
  if digits.length() == 0 || !digits.iter().all(c => c >= '0' && c <= '9') {
    return None
  }
  let n = js_number(id)
  if n == n.floor() && n.abs() <= 9007199254740991.0 {
    Some(if n == 0.0 { 0.0 } else { n })
  } else {
    None
  }
}

///|
/// seen.ts `elsewhere`: the 404 a request is answered with when what its path names is of another workspace.
pub fn elsewhere(store : SeenStore, path : String, viewer : Viewer) -> String? {
  guard named(path) is Some((kind, raw)) else { return None }
  let id = segment(raw)
  match kind {
    "sessions" =>
      if (store.session_there)(id) && !session_seen(store, viewer, id) {
        Some("unknown session \{id}")
      } else {
        None
      }
    "threads" =>
      match thread_number(id) {
        Some(n) if (store.thread_there)(n) && !thread_seen(store, viewer, n) =>
          Some("unknown thread \{id}")
        _ => None
      }
    _ => if job_seen(store, viewer, id) { None } else { Some("no job \{id}") }
  }
}

///|
/// seen.ts `went`: where a chat a write's path names was handed to, for a viewer of the workspace it went from.
pub fn went(store : SeenStore, path : String, viewer : Viewer) -> J? {
  guard named(path) is Some((kind, raw)) else { return None }
  let id = segment(raw)
  let keys = match kind {
    "sessions" => [id]
    "threads" =>
      match thread_number(id) {
        Some(n) => (store.thread_sessions)(n)
        None => []
      }
    _ => []
  }
  for key in keys {
    guard (store.handed_to)(key) is Some(h) else { continue }
    guard (store.session_ws)(key) is Some(Str(ws)) &&
      @jsjson.raw_text(ws).has_prefix("handed:") else {
      continue
    }
    if !sees(viewer, h.get("ws").unwrap_or(Null)) {
      continue
    }
    return Some(
      jopt([
        ("session", Some(js(key))),
        ("station", h.get("station")),
        ("thread", h.get("thread")),
        ("there", h.get("there")),
      ]),
    )
  }
  None
}
