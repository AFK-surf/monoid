// A request to the admin API as the station takes it from the mesh, and its answer (station/src/api/request.ts).

///|
/// The device no longer waits for it (only reads use it).
pub struct Signal {
  mut aborted : Bool
}

///|
pub fn Signal::new() -> Signal {
  { aborted: false, }
}

///|
/// The device went: what reads for it stops.
pub fn Signal::abort(self : Signal) -> Unit {
  self.aborted = true
}

///|
pub struct Request {
  verb : String
  /// After /admin/api, without the query.
  path : String
  query : Array[(String, String)]
  /// The query as asked (`?…`, or empty); None where it was not said.
  search : String?
  headers : Array[(String, String)]
  body : Bytes
  /// The member's credential as the station let it in (mesh/credential.ts Viewer).
  viewer : JV
  lang : String
  /// Read in the background (a part of POST /batch).
  background : Bool
  signal : Signal?
}

///|
/// An answer's body: whole, or read a piece at a time (None: its end).
pub(all) enum Body {
  Whole(Bytes)
  Stream(async () -> Bytes?)
  /// A stream its reader may stop before its end (the iterator's `return`).
  Streamed(async () -> Bytes?, async () -> Unit)
}

///|
/// What a reader that stops before the body's end calls (the device gone mid-stream): the request's `signal` aborted,
/// so what reads for it stops, then a `Streamed` body's own stop set going on `spawn`.
pub fn Body::stop_with(self : Body, signal : Signal, spawn : (async () -> Unit) -> Unit) -> () -> Unit {
  match self {
    Whole(_) | Stream(_) => () => signal.abort()
    Streamed(_, stop) =>
      () => {
        signal.abort()
        spawn(stop)
      }
  }
}

///|
pub struct Answer {
  status : Int32
  headers : Map[String, String]
  body : Body
}

///|
/// The body's bytes, a stream read to its end.
pub async fn Answer::bytes(self : Answer) -> Bytes {
  match self.body {
    Whole(b) => b
    Stream(next) | Streamed(next, _) => {
      let out = @buffer.new()
      while next() is Some(chunk) {
        out.write_bytes(chunk)
      }
      out.to_bytes()
    }
  }
}

///|
pub fn Answer::whole(self : Answer) -> Bytes? {
  match self.body {
    Whole(b) => Some(b)
    _ => None
  }
}

///|
pub fn Answer::text(self : Answer) -> String {
  match self.body {
    Whole(b) => utf8_text(b)
    _ => ""
  }
}

///|
pub fn json_headers() -> Map[String, String] {
  { "content-type": "application/json", "cache-control": "no-store" }
}

///|
pub fn json(status : Int32, text : String) -> Answer {
  { status, headers: json_headers(), body: Whole(utf8(text)), }
}

///|
pub fn json_bytes(status : Int32, bytes : Bytes) -> Answer {
  { status, headers: json_headers(), body: Whole(bytes), }
}

///|
pub fn error(status : Int32, message : String) -> Answer {
  json(status, stringify(jobj([("error", js(message))])))
}

///|
/// A value answered as JSON.
pub fn ok(value : JV, status~ : Int32 = 200) -> Answer {
  json(status, stringify(value))
}

///|
/// What a request is refused, and with which status (request.ts `Refused`); a chat handed to another station
/// (routes/hub.ts `Moved`: 409 with where it went).
pub(all) suberror Refused {
  Refused(Int32, String)
  Moved(String, JV)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for Refused with output(self, logger) {
  match self {
    Refused(_, m) => logger.write_string(m)
    Moved(m, _) => logger.write_string(m)
  }
}

///|
/// Its status and message where it is a Refused (one of the routes' or one a part threw).
pub fn refused_of(e : Error) -> (Int32, String)? {
  match e {
    Refused(status, message) => Some((status, message))
    Moved(message, _) => Some((409, message))
    Thrown("Refused" | "HttpError" | "Moved", said) =>
      Some((status_of(said), js_string(jget(Some(said), "message"))))
    _ => None
  }
}

///|
/// Where it is a Moved (the routes' or a part's), its message and where.
pub fn moved_of(e : Error) -> (String, JV)? {
  match e {
    Moved(message, moved) => Some((message, moved))
    Thrown("Moved", said) =>
      Some(
        (
          js_string(jget(Some(said), "message")),
          said.get("moved").unwrap_or(Null),
        ),
      )
    _ => None
  }
}

///|
/// The language a core asks in: its `stillfail-lang`; Chinese for a core from before languages.
pub fn lang_of_core(headers : Array[(String, String)]) -> String {
  match header_of(headers, "stillfail-lang") {
    Some(v) => lang_of(v)
    None => "zh"
  }
}

///|
/// Chinese for Chinese, English for any other; Chinese when nothing is said.
pub fn lang_of(locale : String) -> String {
  let l = trim_js(locale).to_lower()
  if l == "" || l.has_prefix("zh") {
    "zh"
  } else {
    "en"
  }
}

///|
/// The first header of that name, any case (`Object.entries(headers).find(([k]) => k.toLowerCase() === name)`).
pub fn header_of(headers : Array[(String, String)], name : String) -> String? {
  for h in headers {
    if h.0.to_lower() == name {
      return Some(h.1)
    }
  }
  None
}

///|
/// `r.headers[name]` exactly.
pub fn header_exact(
  headers : Array[(String, String)],
  name : String,
) -> String? {
  let mut found = None
  for h in headers {
    if h.0 == name {
      found = Some(h.1)
    }
  }
  found
}

///|
/// admin/mod.rs `percent_decode`: `%xx` a byte, `+` a space, the rest as it is; then UTF-8, lossily.
pub fn percent_decode(s : String) -> String {
  @url.percent_decode_lossy(s, plus_space=true)
}

///|
/// admin/mod.rs `query_pairs`.
pub fn query_pairs(query : String) -> Array[(String, String)] {
  let out = []
  for p in query.split("&") {
    let p = p.to_string()
    if p == "" {
      continue
    }
    match p.find("=") {
      Some(at) =>
        out.push(
          (
            percent_decode(p.unsafe_substring(start=0, end=at)),
            percent_decode(p.unsafe_substring(start=at + 1, end=p.length())),
          ),
        )
      None => out.push((percent_decode(p), ""))
    }
  }
  out
}

///|
/// The first value of a name.
pub fn Request::param(self : Request, name : String) -> String? {
  for q in self.query {
    if q.0 == name {
      return Some(q.1)
    }
  }
  None
}

///|
/// Every value of a name, in order.
pub fn Request::params(self : Request, name : String) -> Array[String] {
  self.query.filter(q => q.0 == name).map(q => q.1)
}

///|
/// A path segment as the pages send it (a + is a +).
pub fn segment(s : String) -> String {
  percent_decode(s.replace_all(old="+", new="%2B"))
}

///|
/// The request's body as UTF-8.
pub fn Request::text(self : Request) -> String {
  utf8_text(self.body)
}

///|
/// A field of the viewer.
pub fn Request::who(self : Request, name : String) -> JV? {
  jget(Some(self.viewer), name)
}

///|
/// A string field of the viewer ("" where it is not one).
pub fn Request::who_str(self : Request, name : String) -> String {
  jstr(self.who(name)).unwrap_or("")
}

///|
pub fn Request::email(self : Request) -> String {
  self.who_str("email")
}

///|
/// `r.viewer.workspace || null`.
pub fn Request::ws_or_null(self : Request) -> JV {
  match self.who("workspace") {
    Some(Str(u)) if u.length() > 0 => Str(u)
    _ => Null
  }
}

///|
/// A request's JSON object (`read_json`): nothing is `{}`, as is anything not an object; more than a megabyte refused.
pub fn input(r : Request) -> JV raise Refused {
  if r.body.length() > 1000000 {
    raise Refused(413, "request too large")
  }
  if r.body.length() == 0 {
    return Obj([])
  }
  let value = parse(r.text()) catch { _ => raise Refused(400, "invalid JSON") }
  match value {
    Obj(_) => value
    _ => Obj([])
  }
}

///|
/// `JSON.parse(r.body.toString("utf8") || "{}")`: None where it does not read.
pub fn body_or_empty(r : Request) -> JV? {
  let t = r.text()
  try_parse(if t == "" { "{}" } else { t })
}

///|
/// `JSON.parse(r.body.toString("utf8"))`.
pub fn body_json(r : Request) -> JV? {
  try_parse(r.text())
}
