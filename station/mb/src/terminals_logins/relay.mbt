// station/src/logins/relay.ts: a login's browser came back to a loopback port on the person's device, and their
// client handed the request here (回环回调): it goes to the login command, once, on the port its page named, and only
// when that port is the command's own (lsof: the command or what it started listens there). Nothing is ever sent to
// the callback to try it: a request with a wrong state ends most of these commands (gcloud, aws, Claude Code,
// wrangler). The command's answer (its 登录成功 page) goes back as it was.

///|
/// Why something asked of the logins was not done: the status it is answered with, and its words.
pub suberror Refused {
  Refused(Int, String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for Refused with output(self, logger) {
  match self {
    Refused(_, m) => logger.write_string(m)
  }
}

///|
/// The browser's callback as a client hands it (`body` in base64).
pub(all) struct Callback {
  method_ : String
  path : String
  headers : Array[(String, String)]
  body : String?
}

///|
/// The command's answer (`body` in base64).
pub(all) struct Answered {
  status : Int
  headers : Array[(String, String)]
  body : String
}

///|
pub fn Answered::to_json(self : Answered) -> J {
  jo([
    ("status", ji(self.status)),
    ("headers", jo(self.headers.map(h => (h.0, js(h.1))))),
    ("body", js(self.body)),
  ])
}

///|
/// What the relay asks of the machine.
pub(all) struct RelayIo {
  /// platform `listening(pids, port)`: the addresses those processes listen on there (None: it cannot be told).
  listening : async (Array[Int], Int) -> Array[String]?
  /// The request sent to `host`:`port` (an answer of at most a million bytes taken, its headers' names in lower case and
  /// one said more than once joined with ", "); raises
  /// `SendFailed(code, message)` where it went nowhere or broke.
  send : async (String, Int, String, String, Array[(String, String)], Bytes) -> Answered
}

///|
/// How a request to the command failed (`code`: Node's, as ECONNREFUSED).
pub(all) suberror SendFailed {
  SendFailed(String, String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for SendFailed with output(self, logger) {
  match self {
    SendFailed(code, m) => logger.write_string(if m == "" { code } else { m })
  }
}

///|
/// Headers that are the connection's, not the request's.
let hop : Array[String] = [
  "connection", "keep-alive", "transfer-encoding", "upgrade", "proxy-connection", "proxy-authorization", "te", "trailer",
  "content-length",
]

///|
/// `new URLSearchParams(s).get(name)`.
pub fn form_get(s : String, name : String) -> String? {
  let text = if s.has_prefix("?") { s.unsafe_substring(start=1, end=s.length()) } else { s }
  for part in text.split("&") {
    let p = part.to_string()
    if p == "" {
      continue
    }
    let (k, v) = match p.find("=") {
      Some(i) => (p.unsafe_substring(start=0, end=i), p.unsafe_substring(start=i + 1, end=p.length()))
      None => (p, "")
    }
    if form_decode(k) == name {
      return Some(form_decode(v))
    }
  }
  None
}

///|
/// application/x-www-form-urlencoded's percent-decode of a name or value: `+` a space, `%xx` its byte (one not
/// followed by two hex digits kept), the bytes read as UTF-8.
fn form_decode(s : String) -> String {
  let bytes = @buffer.new()
  let src = utf8_of(s)
  let mut i = 0
  while i < src.length() {
    let c = src[i].to_int()
    if c == '+'.to_int() {
      bytes.write_byte(b' ')
      i += 1
    } else if c == '%'.to_int() &&
      i + 2 < src.length() + 0 &&
      hex_value(src[i + 1].to_int()) >= 0 &&
      hex_value(src[i + 2].to_int()) >= 0 {
      bytes.write_byte((hex_value(src[i + 1].to_int()) * 16 + hex_value(src[i + 2].to_int())).to_byte())
      i += 3
    } else {
      bytes.write_byte(src[i])
      i += 1
    }
  }
  utf8_text(bytes.to_bytes())
}

///|
fn hex_value(c : Int) -> Int {
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
/// The callback's state: in its query (GET), or its form (POST, form_post).
pub fn state_of(callback : Callback) -> String? {
  let query = match callback.path.find("?") {
    Some(at) => callback.path.unsafe_substring(start=at + 1, end=callback.path.length())
    None => ""
  }
  if callback.method_ == "POST" {
    let form = utf8_text(from_base64(callback.body.unwrap_or("")))
    match form_get(form, "state") {
      Some(s) => return Some(s)
      None => return form_get(query, "state")
    }
  }
  form_get(query, "state")
}

///|
/// Whether a callback is the one this login waits for: its method, its path, its state. Raises Refused when not.
pub fn check(run : LoginRun, callback : Callback) -> Unit raise Refused {
  let back = run.loopback
  if !run.active() {
    raise Refused(409, "this login has ended")
  }
  guard back is Some(back) && run.step == Some("loopback") else {
    raise Refused(409, "this login does not wait for a browser to come back")
  }
  if run.relayed {
    raise Refused(409, "this login's callback was relayed already")
  }
  if back.state is None {
    raise Refused(409, "this login's page names no state: its callback is not relayed")
  }
  let method_ = callback.method_.to_upper()
  let wanted = if back.post { "POST" } else { "GET" }
  if method_ != wanted {
    raise Refused(400, "this login's callback is a \{wanted}")
  }
  let path = match callback.path.find("?") {
    Some(at) => callback.path.unsafe_substring(start=0, end=at)
    None => callback.path
  }
  if (if path == "" { "/" } else { path }) != back.path {
    raise Refused(400, "not this login's callback path")
  }
  if state_of(callback) != back.state {
    raise Refused(400, "not this login's state")
  }
}

///|
/// The callback handed to the login command, and its answer. Refused (and nothing sent) when it is not the one the
/// login waits for, or its port is not the command's.
pub async fn relay(run : LoginRun, io : RelayIo, callback : Callback) -> Answered {
  check(run, callback)
  let back = run.loopback.unwrap()
  let pids = run.pids()
  guard (io.listening)(pids, back.port) is Some(addresses) else {
    raise Refused(409, "this machine cannot tell which program listens on the port: the callback is not relayed")
  }
  if addresses.length() == 0 {
    raise Refused(
      409,
      "the login command does not listen on port \{back.port}" +
      (if pids.length() == 0 { " (it has ended)" } else { "" }),
    )
  }
  // Once only, from here: a second callback is refused even while this one is under way.
  check(run, callback)
  run.relayed_now()
  // Where it listens, as lsof saw it: ::1 for one that listens there only (Claude Code, wrangler), else 127.0.0.1.
  let order = if addresses.contains("::1") &&
    !addresses.iter().any(a => a == "127.0.0.1" || a == "*" || a == "0.0.0.0") {
    ["::1", "127.0.0.1"]
  } else {
    ["127.0.0.1", "::1"]
  }
  let headers : Array[(String, String)] = []
  let put = (k : String, v : String) => match headers.search_by(h => h.0 == k) {
    Some(i) => headers[i] = (k, v)
    None => headers.push((k, v))
  }
  for h in callback.headers {
    let k = @jscase.lower(h.0)
    if !hop.contains(k) {
      put(k, h.1)
    }
  }
  let body = match callback.body {
    Some(b) if b != "" => from_base64(b)
    _ => b""
  }
  if body.length() > 0 {
    put("content-length", body.length().to_string())
  }
  put("connection", "close")
  let method_ = callback.method_.to_upper()
  for i, address in order {
    try {
      let answered = (io.send)(address, back.port, method_, callback.path, headers, body)
      // (its headers but the connection's, as Node names them: lower case)
      return { ..answered, headers: answered.headers.filter(h => !hop.contains(@jscase.lower(h.0))) }
    } catch {
      // Only a refused connection tries the other address: the request went nowhere.
      SendFailed(code, message) =>
        if code != "ECONNREFUSED" || i == order.length() - 1 {
          raise Refused(502, "the login command did not answer: \{message}")
        }
      e => raise Refused(502, "the login command did not answer: \{error_message(e)}")
    }
  }
  raise Refused(502, "the login command did not answer")
}
