// The agents' door (station/src/tools/http.ts): loopback only. /mcp is the MCP endpoint, /jobs/notify what a job says
// (`stillfail-job notify`), /jobs/screen a job's command asking for the screen (`stillfail-job screen`), /health that
// the station answers, /peer/<station>/<port>/… a web service on another station of the workspace, and the parts' own
// (the station's browser). This is what the door answers a request, as it came off its socket (its method, its URL as
// asked, its headers by their lower-case names, its body whole); the socket is the shell's, or the launcher's fd, and
// keeping it across a handover is the listener's. What it asks: `door.notified` and `door.screened` (a status and a
// body: jobs.ts `notifyEndpoint`, `screenEndpoint`), `door.peers` (whether the mesh is up: null, or a route),
// `door.peer.request` / `door.peer.upgrade` (another station's web service answering, mesh/peer-http.ts), `door.parts`
// (the parts' prefixes, parts.ts `door`) and `door.part.request` / `door.part.upgrade`.

///|
/// A job's words: no more than this is read.
pub let notify_limit : Int = 64 * 1024

///|
/// A command's ask for the screen (`take <pid>`): no more than this.
pub let screen_limit : Int = 64

///|
/// Where programs reach the other stations' web services (`STILLFAIL_PEER_HTTP`), from the door's MCP URL.
pub fn peer_http_base(mcp_url : String) -> String {
  if mcp_url.has_suffix("/mcp") {
    slice(mcp_url, 0, to=mcp_url.length() - 4) + "/peer"
  } else {
    mcp_url
  }
}

///|
/// A /peer/<station>/<port>/<path> request's parts.
pub(all) struct PeerTarget {
  station : String
  given : String
  port : Int
  path : String
}

///|
pub fn PeerTarget::to_jv(self : PeerTarget) -> JV {
  jobj([
    ("station", js(self.station)),
    ("given", js(self.given)),
    ("port", jint(self.port)),
    ("path", js(self.path)),
  ])
}

///|
/// The parts of a /peer/<station>/<port>/<path> URL; None when it is not one.
pub fn peer_target(url : String) -> PeerTarget? {
  if !url.has_prefix("/peer/") {
    return None
  }
  let rest = slice(url, 6)
  let at = index_of(rest, "/")
  if at <= 0 {
    return None
  }
  let given = slice(rest, 0, to=at)
  guard @api_routes.decode_uri_component(given) is Some(station) else {
    return None
  }
  let after = slice(rest, at + 1)
  let mut n = 0
  while n < after.length() &&
        n < 6 &&
        after.unsafe_charcode_at(n) >= '0' &&
        after.unsafe_charcode_at(n) <= '9' {
    n += 1
  }
  // /^[0-9]{1,5}(?=$|[/?])/
  if n == 0 || n > 5 {
    return None
  }
  if n < after.length() {
    let c = after.unsafe_charcode_at(n)
    if c != '/' && c != '?' {
      return None
    }
  }
  let mut port = 0
  for k in 0..<n {
    port = port * 10 + (after.unsafe_charcode_at(k) - '0')
  }
  if port < 1 || port > 65535 {
    return None
  }
  let tail = slice(after, n)
  let path = if tail == "" {
    "/"
  } else if tail.has_prefix("?") {
    "/" + tail
  } else {
    tail
  }
  Some({ station, given, port, path })
}

///|
fn header(headers : Array[(String, String)], name : String) -> String? {
  for h in headers {
    if h.0 == name {
      return Some(h.1)
    }
  }
  None
}

///|
/// Why a /peer request is not taken (None: it is): only programs on this machine, by a loopback name and the door's
/// port, and not a web page.
pub fn not_from_here(
  headers : Array[(String, String)],
  ports : Array[Int],
) -> String? {
  let host = header(headers, "host").unwrap_or("")
  let lowered = lower(host)
  let port = {
    let names = ["127.0.0.1:", "localhost:", "[::1]:"]
    let mut found : Int? = None
    for name in names {
      if lowered.has_prefix(name) {
        let digits = slice(host, name.length())
        let ok = digits.length() >= 1 &&
          digits.length() <= 5 &&
          digits.iter().all(c => c >= '0' && c <= '9')
        if ok {
          found = Some(@api_routes.js_number(digits).to_int())
        }
      }
    }
    found
  }
  let first = match ports.get(0) {
    Some(p) => p.to_string()
    None => "undefined"
  }
  match port {
    Some(p) if ports.contains(p) => ()
    _ =>
      return Some(
        "only programs on this machine reach other stations here, by http://127.0.0.1:\{first}/peer/…",
      )
  }
  let origin = header(headers, "origin")
  let site = header(headers, "sec-fetch-site")
  match origin {
    Some(o) if o != "null" || (site is Some(s) && s != "none") =>
      Some("web pages do not reach other stations through this one")
    _ => None
  }
}

///|
/// Node's STATUS_CODES.
fn status_text(status : Int) -> String {
  match status {
    100 => "Continue"
    101 => "Switching Protocols"
    102 => "Processing"
    103 => "Early Hints"
    200 => "OK"
    201 => "Created"
    202 => "Accepted"
    203 => "Non-Authoritative Information"
    204 => "No Content"
    205 => "Reset Content"
    206 => "Partial Content"
    207 => "Multi-Status"
    208 => "Already Reported"
    226 => "IM Used"
    300 => "Multiple Choices"
    301 => "Moved Permanently"
    302 => "Found"
    303 => "See Other"
    304 => "Not Modified"
    305 => "Use Proxy"
    307 => "Temporary Redirect"
    308 => "Permanent Redirect"
    400 => "Bad Request"
    401 => "Unauthorized"
    402 => "Payment Required"
    403 => "Forbidden"
    404 => "Not Found"
    405 => "Method Not Allowed"
    406 => "Not Acceptable"
    407 => "Proxy Authentication Required"
    408 => "Request Timeout"
    409 => "Conflict"
    410 => "Gone"
    411 => "Length Required"
    412 => "Precondition Failed"
    413 => "Payload Too Large"
    414 => "URI Too Long"
    415 => "Unsupported Media Type"
    416 => "Range Not Satisfiable"
    417 => "Expectation Failed"
    418 => "I'm a Teapot"
    421 => "Misdirected Request"
    422 => "Unprocessable Entity"
    423 => "Locked"
    424 => "Failed Dependency"
    425 => "Too Early"
    426 => "Upgrade Required"
    428 => "Precondition Required"
    429 => "Too Many Requests"
    431 => "Request Header Fields Too Large"
    451 => "Unavailable For Legal Reasons"
    500 => "Internal Server Error"
    501 => "Not Implemented"
    502 => "Bad Gateway"
    503 => "Service Unavailable"
    504 => "Gateway Timeout"
    505 => "HTTP Version Not Supported"
    506 => "Variant Also Negotiates"
    507 => "Insufficient Storage"
    508 => "Loop Detected"
    509 => "Bandwidth Limit Exceeded"
    510 => "Not Extended"
    511 => "Network Authentication Required"
    _ => ""
  }
}

///|
/// A refusal on a socket that asked to upgrade: the bytes written before it is closed.
pub fn refuse_upgrade(status : Int, text : String) -> Bytes {
  let body = utf8(text)
  let head = "HTTP/1.1 \{status} \{status_text(status)}\r\ncontent-type: text/plain; charset=utf-8\r\ncontent-length: \{body.length()}\r\nconnection: close\r\n\r\n"
  let out = @buffer.new()
  out.write_bytes(utf8(head))
  out.write_bytes(body)
  out.to_bytes()
}

///|
/// A request as it came to the door.
pub(all) struct DoorRequest {
  method : String
  url : String
  /// by their lower-case names, as Node's `req.headers`
  headers : Array[(String, String)]
  body : Bytes
}

///|
/// What the door answered: a status, headers and a body, or the connection destroyed (a route that failed after its
/// head was written).
pub(all) struct DoorAnswer {
  status : Int
  headers : Array[(String, String)]
  body : Bytes
  destroyed : Bool
}

///|
pub(all) enum Upgraded {
  /// The bytes written on the socket before it is closed.
  Refused(Bytes)
  /// Handed to its route.
  Routed
  /// Its route failed: the socket destroyed.
  Destroyed
}

///|
/// The door: the endpoint, what it asks the station, and the ports it is reached on (the entrance's first: known once
/// it listens).
pub struct Door {
  mcp : McpEndpoint
  backend : ToolsBackend
  ports : Array[Int]
}

///|
pub fn Door::new(
  mcp : McpEndpoint,
  backend : ToolsBackend,
  ports : Array[Int],
) -> Door {
  { mcp, backend, ports }
}

///|
/// Where agents reach it: `http://127.0.0.1:<port>/mcp` (the launcher's entrance's port when it has one).
pub fn Door::url(self : Door) -> String {
  "http://127.0.0.1:\{self.ports.get(0).unwrap_or(0)}/mcp"
}

///|
fn asked(r : DoorRequest) -> JV {
  jobj([("method", js(r.method)), ("url", js(r.url))])
}

///|
/// A /peer request's refusal before it goes anywhere, or where it goes.
async fn Door::peer_of(
  self : Door,
  r : DoorRequest,
) -> Result[PeerTarget, (Int, String)] {
  match not_from_here(r.headers, self.ports) {
    Some(why) => return Err((403, why))
    None => ()
  }
  guard peer_target(r.url) is Some(target) else {
    return Err(
      (
        404,
        "a web service of another station is /peer/<station name or id>/<port>/<path>",
      ),
    )
  }
  match self.backend.ask("door.peers", []) {
    Null => Err((503, "this station is not on the mesh yet; try again shortly"))
    x if is_undef(x) =>
      Err((503, "this station is not on the mesh yet; try again shortly"))
    _ => Ok(target)
  }
}

///|
/// A part's route for a request (its prefix), or why it is refused; None when the path is no part's.
async fn Door::part_of(self : Door, r : DoorRequest) -> Result[String, String]? {
  let url = r.url
  let prefixes = strings_of(Some(self.backend.ask("door.parts", [])))
  for p in prefixes {
    if url == "/\{p}" || url.has_prefix("/\{p}/") || url.has_prefix("/\{p}?") {
      return Some(
        if not_from_here(r.headers, self.ports) is None {
          Ok(p)
        } else {
          Err("only programs on this machine reach this")
        },
      )
    }
  }
  None
}

///|
fn plain(status : Int, text : String) -> DoorAnswer {
  {
    status,
    headers: [("content-type", "text/plain; charset=utf-8")],
    body: utf8(text),
    destroyed: false,
  }
}

///|
fn sent(status : Int, body : JV?) -> DoorAnswer {
  match body {
    None => { status, headers: [], body: b"", destroyed: false }
    Some(b) =>
      {
        status,
        headers: [("content-type", "application/json")],
        body: utf8(stringify(b)),
        destroyed: false,
      }
  }
}

///|
/// What a route answered (`{status, headers, body: base64}`), as it is written.
fn routed(said : JV) -> DoorAnswer {
  {
    status: jnumber_or(said.get("status"), 200),
    headers: jfields(said.get("headers")).map(h => (h.0, js_string(Some(h.1)))),
    body: @base64.decode(text(said.get("body"))) catch { _ => b"" },
    destroyed: false,
  }
}

///|
fn jnumber_or(v : JV?, d : Int) -> Int {
  match v {
    Some(Num(n)) => n.to_int()
    _ => d
  }
}

///|
let destroyed : DoorAnswer = { status: 0, headers: [], body: b"", destroyed: true }

///|
/// One request.
pub async fn Door::handle(self : Door, r : DoorRequest) -> DoorAnswer {
  // Another station's web service: as long as it streams.
  if r.url == "/peer" || r.url.has_prefix("/peer/") {
    match self.peer_of(r) {
      Err((status, why)) => return plain(status, why)
      Ok(target) =>
        return routed(
          self.backend.ask("door.peer.request", [asked(r), target.to_jv()]),
        ) catch {
          error => {
            self.backend.log(
              "warn",
              "mcp",
              "a request to another station failed",
              jobj([("error", js(message_of(error)))]),
            )
            destroyed
          }
        }
    }
  }
  // A part's (the station's browser): as long as it lasts, as /peer's.
  match self.part_of(r) {
    Some(Err(why)) => return plain(403, why)
    Some(Ok(prefix)) =>
      return routed(self.backend.ask("door.part.request", [asked(r), js(prefix)])) catch {
        error => {
          self.backend.log(
            "warn",
            "mcp",
            "a part's request failed",
            jobj([("error", js(message_of(error)))]),
          )
          destroyed
        }
      }
    None => ()
  }
  let auth = match header(r.headers, "authorization") {
    Some(a) => js(a)
    None => jundef
  }
  try {
    let path = url_pathname(r.url)
    if path == "/health" {
      sent(200, Some(jobj([("ok", jbool(true))])))
    } else if path == "/jobs/notify" && r.method == "POST" {
      if r.body.length() > notify_limit {
        sent(400, Some(jobj([("error", js("length limit exceeded"))])))
      } else {
        let answer = self.backend.ask("door.notified", [
          auth,
          @api_routes.jbytes(r.body),
        ])
        sent(jnumber_or(answer.get("status"), 200), given(field(answer, "body")))
      }
    } else if path == "/jobs/screen" && r.method == "POST" {
      if r.body.length() > screen_limit {
        sent(400, Some(jobj([("error", js("length limit exceeded"))])))
      } else {
        let answer = self.backend.ask("door.screened", [
          auth,
          @api_routes.jbytes(r.body),
        ])
        sent(jnumber_or(answer.get("status"), 200), given(field(answer, "body")))
      }
    } else if path == "/mcp" {
      let reply = self.mcp.handle(
        r.method,
        header(r.headers, "authorization"),
        r.body,
        signal=@api_routes.Signal::new(),
      )
      sent(reply.status, reply.body)
    } else {
      { status: 404, headers: [("content-type", "text/plain")], body: b"", destroyed: false }
    }
  } catch {
    error => {
      self.backend.log(
        "warn",
        "mcp",
        "a request to the agents' door failed",
        jobj([("error", js(message_of(error)))]),
      )
      sent(500, Some(jobj([("error", js(message_of(error)))])))
    }
  }
}

///|
/// A socket that asked to upgrade: another station's service's WebSocket, or a part's; nothing else upgrades.
pub async fn Door::upgrade(self : Door, r : DoorRequest) -> Upgraded {
  match self.part_of(r) {
    Some(Err(why)) => return Refused(refuse_upgrade(403, why))
    Some(Ok(prefix)) => {
      self.backend.tell("door.part.upgrade", [asked(r), js(prefix)]) catch {
        error => {
          self.backend.log(
            "warn",
            "mcp",
            "a part's WebSocket failed",
            jobj([("error", js(message_of(error)))]),
          )
          return Destroyed
        }
      }
      return Routed
    }
    None => ()
  }
  if !r.url.has_prefix("/peer/") {
    return Refused(refuse_upgrade(404, ""))
  }
  match self.peer_of(r) {
    Err((status, why)) => Refused(refuse_upgrade(status, why))
    Ok(target) => {
      self.backend.tell("door.peer.upgrade", [asked(r), target.to_jv()]) catch {
        error => {
          self.backend.log(
            "warn",
            "mcp",
            "a WebSocket to another station failed",
            jobj([("error", js(message_of(error)))]),
          )
          return Destroyed
        }
      }
      Routed
    }
  }
}

///|
/// `new URL(url, "http://agents").pathname`, for the request targets a door is asked.
pub fn url_pathname(url : String) -> String {
  // (tabs and newlines are taken out, the controls and spaces around it trimmed)
  let cleaned = StringBuilder::new()
  for c in url {
    if c != '\t' && c != '\n' && c != '\r' {
      cleaned.write_char(c)
    }
  }
  let mut s = cleaned.to_string()
  let mut a = 0
  let mut b = s.length()
  while a < b && s.unsafe_charcode_at(a) <= 0x20 {
    a += 1
  }
  while b > a && s.unsafe_charcode_at(b - 1) <= 0x20 {
    b -= 1
  }
  s = slice(s, a, to=b)
  // an absolute URL of a special scheme, or one with an authority: its path after the host
  let lowered = lower(s)
  let schemes = ["http:", "https:", "ws:", "wss:", "ftp:"]
  let mut rest = s
  for sc in schemes {
    if lowered.has_prefix(sc) {
      rest = slice(s, sc.length())
      break
    }
  }
  rest = replace_all(rest, "\\", "/")
  if rest.has_prefix("//") {
    let after = slice(rest, 2)
    let mut i = 0
    while i < after.length() {
      let c = after.unsafe_charcode_at(i)
      if c == '/' || c == '?' || c == '#' {
        break
      }
      i += 1
    }
    rest = slice(after, i)
  } else if rest.length() != s.length() && !rest.has_prefix("/") {
    // `http:mcp` is `http://mcp/`
    let mut i = 0
    while i < rest.length() {
      let c = rest.unsafe_charcode_at(i)
      if c == '/' || c == '?' || c == '#' {
        break
      }
      i += 1
    }
    rest = slice(rest, i)
  }
  let q = {
    let mut i = 0
    while i < rest.length() {
      let c = rest.unsafe_charcode_at(i)
      if c == '?' || c == '#' {
        break
      }
      i += 1
    }
    i
  }
  let path = slice(rest, 0, to=q)
  let path = if path.has_prefix("/") { path } else { "/" + path }
  let segments = split(slice(path, 1), "/")
  let out : Array[String] = []
  let n = segments.length()
  for i, seg in segments {
    let l = lower(seg)
    let last = i == n - 1
    if l == ".." || l == ".%2e" || l == "%2e." || l == "%2e%2e" {
      ignore(out.pop())
      if last {
        out.push("")
      }
    } else if l == "." || l == "%2e" {
      if last {
        out.push("")
      }
    } else {
      out.push(encode_path_segment(seg))
    }
  }
  "/" + out.join("/")
}

///|
/// A path's segment with what the path percent-encode set holds encoded (UTF-8, upper-case hex).
fn encode_path_segment(seg : String) -> String {
  @url.percent_encode(seg, n => n > 0x20 &&
    n < 0x7F &&
    n != '"' &&
    n != '#' &&
    n != '<' &&
    n != '>' &&
    n != '?' &&
    n != '`' &&
    n != '{' &&
    n != '}')
}
