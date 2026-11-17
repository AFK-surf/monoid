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
fn utf8_bytes(s : String) -> Array[Int32] {
  let out = []
  let n = s.length()
  let mut i = 0
  while i < n {
    let mut c = s.unsafe_charcode_at(i)
    i += 1
    if c >= 0xd800 &&
      c <= 0xdbff &&
      i < n &&
      s.unsafe_charcode_at(i) >= 0xdc00 &&
      s.unsafe_charcode_at(i) <= 0xdfff {
      c = 0x10000 + ((c - 0xd800) << 10) + (s.unsafe_charcode_at(i) - 0xdc00)
      i += 1
    } else if c >= 0xd800 && c <= 0xdfff {
      c = 0xfffd
    }
    if c < 0x80 {
      out.push(c)
    } else if c < 0x800 {
      out.push(0xc0 | (c >> 6))
      out.push(0x80 | (c & 0x3f))
    } else if c < 0x10000 {
      out.push(0xe0 | (c >> 12))
      out.push(0x80 | ((c >> 6) & 0x3f))
      out.push(0x80 | (c & 0x3f))
    } else {
      out.push(0xf0 | (c >> 18))
      out.push(0x80 | ((c >> 12) & 0x3f))
      out.push(0x80 | ((c >> 6) & 0x3f))
      out.push(0x80 | (c & 0x3f))
    }
  }
  out
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
/// UTF-8 decoded as TextDecoder decodes it (a sequence that is not one is U+FFFD, a maximal part of one at a time).
fn utf8_text(bytes : Array[Int32]) -> String {
  let out = StringBuilder::new()
  let n = bytes.length()
  let mut i = 0
  while i < n {
    let b = bytes[i]
    if b < 0x80 {
      out.write_char(b.unsafe_to_char())
      i += 1
      continue
    }
    let (need, low, high, first) = if b >= 0xc2 && b <= 0xdf {
      (1, 0x80, 0xbf, b & 0x1f)
    } else if b == 0xe0 {
      (2, 0xa0, 0xbf, b & 0x0f)
    } else if b == 0xed {
      (2, 0x80, 0x9f, b & 0x0f)
    } else if b >= 0xe1 && b <= 0xef {
      (2, 0x80, 0xbf, b & 0x0f)
    } else if b == 0xf0 {
      (3, 0x90, 0xbf, b & 0x07)
    } else if b == 0xf4 {
      (3, 0x80, 0x8f, b & 0x07)
    } else if b >= 0xf1 && b <= 0xf3 {
      (3, 0x80, 0xbf, b & 0x07)
    } else {
      (0, 0, 0, 0)
    }
    i += 1
    if need == 0 {
      out.write_char('\u{fffd}')
      continue
    }
    let mut cp = first
    let mut ok = true
    for k in 0..<need {
      let (lo, hi) = if k == 0 { (low, high) } else { (0x80, 0xbf) }
      if i < n && bytes[i] >= lo && bytes[i] <= hi {
        cp = (cp << 6) | (bytes[i] & 0x3f)
        i += 1
      } else {
        ok = false
        break
      }
    }
    out.write_char(if ok { cp.unsafe_to_char() } else { '\u{fffd}' })
  }
  out.to_string()
}

///|
/// request.ts `percentDecode` (a `+` is a space).
pub fn percent_decode(s : String) -> String {
  let bytes = utf8_bytes(s)
  let out = []
  let mut i = 0
  while i < bytes.length() {
    if bytes[i] == 0x25 &&
      i + 2 < bytes.length() + 0 &&
      hex_value(bytes[i + 1]) >= 0 &&
      hex_value(bytes[i + 2]) >= 0 {
      out.push(hex_value(bytes[i + 1]) * 16 + hex_value(bytes[i + 2]))
      i += 3
    } else {
      out.push(if bytes[i] == 0x2b { 0x20 } else { bytes[i] })
      i += 1
    }
  }
  utf8_text(out)
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
