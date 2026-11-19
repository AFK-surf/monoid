// Slack's Web API over HTTP (station/src/slack/web.ts): one client for both, with one rule for 429 (wait what Slack
// says, up to five times). Where Slack is can be changed: tests point it at a stand-in ($STILLFAIL_SLACK_API, or the
// client's `base`). Its HTTP is the program's `Net` (the shell's `fetch` on a station: host_net.mbt), its waits Slack's
// time, which is the machine's.

///|
pub let slack_api : String = "https://slack.com/api"

///|
/// Where Slack's Web API is: $STILLFAIL_SLACK_API (as given), else Slack itself.
pub fn api_base(env : String?) -> String {
  match env {
    Some(e) if e != "" => e
    _ => slack_api
  }
}

///|
/// Form fields, in order.
pub type Params = Array[(String, String)]

///|
/// A file sent with a call (multipart).
pub struct FilePart {
  bytes : Bytes
  name : String
  mime : String
}

///|
/// An HTTP answer as the program is given one: its status, its headers as they came, its body, and whether a redirect
/// was followed to it (the shell's `fetch` does not say: false).
pub struct HttpAnswer {
  status : Int
  headers : Array[(String, String)]
  body : Bytes
  redirected : Bool
}

///|
/// The HTTP a client asks through, and the machine's time: `fetch(method, url, headers, body, timeout_ms)`.
pub struct Net {
  fetch : async (String, String, Array[(String, String)], Bytes?, Int) -> HttpAnswer
  now : () -> Double
  sleep : async (Int) -> Unit
}

///|
/// Slack said no to a call of its app API: the method, its error code, and the details it gave (a manifest's
/// problems, say).
pub(all) suberror SlackApiError {
  SlackApiError(String, String, J?)
}

///|
pub impl Show for SlackApiError with output(self, logger) {
  logger.write_string(message_of(self))
}

///|
/// An error said in words from the catalog: its key, and the words in the station's language.
pub(all) suberror SlackWords {
  SlackWords(String, String)
}

///|
pub impl Show for SlackWords with output(self, logger) {
  logger.write_string(message_of(self))
}

///|
/// A value as a form field: strings as they are, anything else as JSON (blocks, arrays), as Slack takes them.
pub fn field(v : J) -> String {
  match v {
    Str(u) => @jsjson.sanitize_str(u)
    other => stringify(other)
  }
}

///|
let retries : Int = 5

///|
pub struct SlackClient {
  base : String
  timeout_ms : Int
  net : Net
  /// Slack's HTTP Date is rounded down to a second. This is the lower bound on Slack time minus local time.
  mut server_offset_lower : Double?
  /// The scopes each token was last answered with (Slack's `x-oauth-scopes`), as granted now.
  granted : Map[String, Array[String]]
}

///|
pub fn SlackClient::new(net : Net, base? : String = slack_api, timeout_ms? : Int = 30000) -> SlackClient {
  let mut end = base.length()
  while end > 0 && base.unsafe_charcode_at(end - 1) == '/' {
    end -= 1
  }
  { base: base.unsafe_substring(start=0, end~), timeout_ms, net, server_offset_lower: None, granted: {} }
}

///|
/// A header as `Headers.get` reads it: by its name in any case, several joined with ", ".
pub fn header(headers : Array[(String, String)], name : String) -> String? {
  let want = lower(name)
  let found = headers.filter(h => lower(h.0) == want).map(h => h.1)
  if found.length() == 0 {
    None
  } else {
    Some(found.join(", "))
  }
}

///|
/// The body of a form (URLSearchParams): application/x-www-form-urlencoded, as its serializer writes it.
pub fn form_encoded(params : Params) -> String {
  params.map(p => "\{form_part(p.0)}=\{form_part(p.1)}").join("&")
}

///|
fn form_part(s : String) -> String {
  let out = StringBuilder::new()
  let hex = "0123456789ABCDEF"
  for b in @utf8.encode(well_formed(s)) {
    let c = b.to_int()
    if (c >= 'a'.to_int() && c <= 'z'.to_int()) ||
      (c >= 'A'.to_int() && c <= 'Z'.to_int()) ||
      (c >= '0'.to_int() && c <= '9'.to_int()) ||
      c == '*'.to_int() ||
      c == '-'.to_int() ||
      c == '.'.to_int() ||
      c == '_'.to_int() {
      out.write_char(c.unsafe_to_char())
    } else if c == ' '.to_int() {
      out.write_char('+')
    } else {
      out.write_char('%')
      out.write_char(hex.unsafe_charcode_at(c / 16).unsafe_to_char())
      out.write_char(hex.unsafe_charcode_at(c % 16).unsafe_to_char())
    }
  }
  out.to_string()
}

///|
/// A string with its lone surrogates made U+FFFD (what a USVString is).
fn well_formed(s : String) -> String {
  @jsjson.sanitize_str(s)
}

///|
/// A form with a file (FormData), as undici writes one: its boundary, and the body.
pub fn multipart(params : Params, file : FilePart, boundary : String) -> Bytes {
  let out = @buffer.new()
  let crlf = (s : String) => {
    // (a value's line breaks, each \r, \n or \r\n, as \r\n)
    let o = StringBuilder::new()
    let n = s.length()
    let mut i = 0
    while i < n {
      let c = s.unsafe_charcode_at(i)
      if c == '\r'.to_int() {
        o.write_string("\r\n")
        if i + 1 < n && s.unsafe_charcode_at(i + 1) == '\n'.to_int() {
          i += 1
        }
      } else if c == '\n'.to_int() {
        o.write_string("\r\n")
      } else {
        o.write_char(c.unsafe_to_char())
      }
      i += 1
    }
    o.to_string()
  }
  let name_of = (s : String) => crlf(well_formed(s))
    .replace_all(old="\n", new="%0A")
    .replace_all(old="\r", new="%0D")
    .replace_all(old="\"", new="%22")
  for p in params {
    out.write_bytes(
      @utf8.encode(
        "--\{boundary}\r\nContent-Disposition: form-data; name=\"\{name_of(p.0)}\"\r\n\r\n\{crlf(well_formed(p.1))}\r\n",
      ),
    )
  }
  out.write_bytes(
    @utf8.encode(
      "--\{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\{name_of(file.name)}\"\r\nContent-Type: \{file.mime}\r\n\r\n",
    ),
  )
  out.write_bytes(file.bytes)
  out.write_bytes(@utf8.encode("\r\n--\{boundary}--\r\n"))
  out.to_bytes()
}

///|
let boundaries : Ref[Int] = { val: 0 }

///|
/// A call as Slack answers it (its status and JSON), after waiting out 429s.
async fn SlackClient::send(
  self : SlackClient,
  meth : String,
  token : String?,
  params : Params,
  file? : FilePart,
) -> (Int, J) {
  let mut attempt = 0
  while true {
    let headers = match token {
      Some(t) => [("authorization", "Bearer \{t}")]
      None => []
    }
    let body = match file {
      Some(f) => {
        boundaries.val += 1
        let boundary = "----formdata-stillfail-\{to_fixed((self.net.now)(), 0)}\{boundaries.val}"
        headers.push(("content-type", "multipart/form-data; boundary=\{boundary}"))
        multipart(params, f, boundary)
      }
      None => {
        headers.push(("content-type", "application/x-www-form-urlencoded;charset=UTF-8"))
        @utf8.encode(form_encoded(params))
      }
    }
    let response = (self.net.fetch)("POST", "\{self.base}/\{meth}", headers, Some(body), self.timeout_ms)
    match header(response.headers, "date") {
      Some(d) =>
        match http_date(d) {
          Some(server) => self.server_offset_lower = Some(server - (self.net.now)())
          None => ()
        }
      None => ()
    }
    match (header(response.headers, "x-oauth-scopes"), token) {
      (Some(scopes), Some(t)) =>
        self.granted[t] = unique(scopes.split(",").map(x => trim(x.to_string())).filter(x => x != "").to_array())
      _ => ()
    }
    if response.status == 429 && attempt < retries {
      let said = header(response.headers, "retry-after").unwrap_or("")
      let seconds = if said != "" && said.iter().all(c => c >= '0' && c <= '9') {
        js_num(Some(js(said)))
      } else {
        1.0
      }
      (self.net.sleep)((seconds * 1000.0).to_int())
      attempt += 1
      continue
    }
    return (response.status, json_body(response.body))
  }
  (0, Null)
}

///|
/// `await response.json()`: the body's JSON (its UTF-8, a byte order mark left out), or the SyntaxError it is not.
fn json_body(body : Bytes) -> J raise Thrown {
  let t = @utf8.decode_lossy(body)
  let t = if t.has_prefix("\u{feff}") { t.unsafe_substring(start=1, end=t.length()) } else { t }
  if trim(t) == "" {
    raise Thrown("SyntaxError", "Unexpected end of JSON input")
  }
  parse(t)
}

///|
/// Latest local instant a Slack timestamp can name, using a response already received (no extra request). None if
/// Slack has not supplied a Date header.
pub fn SlackClient::local_time_upper(self : SlackClient, ts : String) -> Double? {
  match self.server_offset_lower {
    None => None
    Some(o) => Some(js_num(Some(js(ts))) * 1000.0 - o)
  }
}

///|
/// Whether `token` was granted `scope`, as Slack said with its last answer to it; false before any.
pub fn SlackClient::has_scope(self : SlackClient, token : String, scope : String) -> Bool {
  match self.granted.get(token) {
    Some(s) => s.contains(scope)
    None => false
  }
}

///|
/// A Web API call as the bot (or app-level token): its answer, or an error `slack <method>: <error>`.
pub async fn SlackClient::api(self : SlackClient, meth : String, params : Params, token : String) -> J {
  let (_, body) = self.send(meth, Some(token), params)
  if !is_true(at(Some(body), "ok")) {
    let code = match at(Some(body), "error") {
      None => "undefined"
      Some(Str(u)) => @jsjson.sanitize_str(u)
      Some(e) => stringify(e)
    }
    raise fail_("slack \{meth}: \{code}")
  }
  body
}

///|
/// A call of the app API (manifests, configuration tokens, installs), with a token or none: its answer, or a
/// SlackApiError.
pub async fn SlackClient::app(
  self : SlackClient,
  meth : String,
  token : String?,
  params : Params,
  file? : FilePart,
) -> J {
  let (status, data) = match file {
    Some(f) => self.send(meth, token, params, file=f)
    None => self.send(meth, token, params)
  }
  if !is_true(at(Some(data), "ok")) {
    let code = match at(Some(data), "error") {
      Some(Str(u)) => @jsjson.sanitize_str(u)
      None | Some(Null) => "HTTP \{status}"
      Some(e) => stringify(e)
    }
    let details = match at(Some(data), "errors") {
      None | Some(Null) => None
      Some(e) => Some(e)
    }
    raise SlackApiError(meth, code, details)
  }
  data
}

///|
/// A shared file's bytes from Slack (its url_private), with the bot's token: only to Slack's own hosts (or the
/// stand-in it is pointed at), never to an address elsewhere. Without files:read Slack answers its sign-in page instead.
pub async fn SlackClient::download(self : SlackClient, url : String, name : String, token : String) -> Bytes {
  let to = match @cloud_net.parse_url(url) {
    Some(u) => u
    None => raise fail_("not an address: \{url}")
  }
  let host = to.hostname()
  let slack = to.scheme == "https" &&
    (host == "slack.com" || host.has_suffix(".slack.com") || host.has_suffix(".slack-edge.com"))
  let base_origin = match @cloud_net.parse_url(self.base) {
    Some(b) => b.origin()
    None => raise fail_("Invalid URL")
  }
  if !slack && to.origin() != base_origin {
    raise fail_("not a Slack address: \{to.origin()}")
  }
  let got = (self.net.fetch)("GET", to.href(), [("authorization", "Bearer \{token}")], None, 120000)
  if got.status < 200 || got.status > 299 {
    raise fail_("HTTP \{got.status}")
  }
  let kind = header(got.headers, "content-type").unwrap_or("")
  let lname = lower(name)
  let html_name = lname.has_suffix(".html") || lname.has_suffix(".htm")
  if kind.has_prefix("text/html") && (got.redirected || !html_name) {
    raise fail_(
      "Slack answered with its sign-in page: the app lacks files:read (turn on 读写文件 in its permissions)",
    )
  }
  got.body
}

///|
/// A file's bytes to the address Slack gave for them (files.getUploadURLExternal).
pub async fn SlackClient::upload(self : SlackClient, url : String, bytes : Bytes, name : String) -> Unit {
  let sent = (self.net.fetch)("POST", url, [], Some(bytes), 300000)
  if sent.status < 200 || sent.status > 299 {
    let reason = reason_phrase(sent.status)
    let more = if reason == "" { "" } else { " \{reason}" }
    raise fail_("slack upload of \{name}: HTTP \{sent.status}\{more}")
  }
}

///|
/// The reason phrase an HTTP status goes with (Node's STATUS_CODES, what a server says by default: the shell's `fetch`
/// gives none of its own).
fn reason_phrase(status : Int) -> String {
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
/// `Date.parse` of an HTTP date (IMF-fixdate, `Tue, 17 Nov 2026 04:22:23 GMT`): its milliseconds, None where it is
/// not one.
pub fn http_date(s : String) -> Double? {
  @jsjson.js_parse_http_date(s)
}
