// The machine as the accounts use it, through the station's parts (backend.mbt): HTTP (`fetch`, as the station's
// `profileFetch` makes a request, its timeout an AbortSignal's), files (node:fs/promises, `writePrivateSoon`), what
// the machine is called, random bytes. A failure comes back as the error Node gave (its class as the kind, its
// `message`, `name` and `code`), so what the TypeScript tells apart (a timeout, a request that got no answer, a
// refusal) is told apart here alike.

///|
/// An answer to a request: its status and its body as text.
pub(all) struct Response {
  status : Int
  text : String
}

///|
pub fn Response::ok(self : Response) -> Bool {
  self.status >= 200 && self.status <= 299
}

///|
/// `response.json()`: its body as JSON, or the SyntaxError JSON.parse throws.
pub fn Response::json(self : Response) -> JV raise Thrown {
  json_parse(self.text)
}

///|
/// `JSON.parse(text)`, its failure as V8 says the common ones.
pub fn json_parse(text : String) -> JV raise Thrown {
  parse(text) catch {
    _ => {
      let message = if trim_js(text) == "" {
        "Unexpected end of JSON input"
      } else {
        // V8's words where what it begins with is no JSON (an HTML page, a plain word): the token and the text,
        // whole up to 20 characters, else its first ten and "..."
        let mut i = 0
        while i < text.length() &&
              (
                text.unsafe_charcode_at(i) == ' '.to_int() ||
                text.unsafe_charcode_at(i) == '\t'.to_int() ||
                text.unsafe_charcode_at(i) == '\n'.to_int() ||
                text.unsafe_charcode_at(i) == '\r'.to_int()
              ) {
          i += 1
        }
        let c = text.unsafe_charcode_at(i)
        let starts = c == '{'.to_int() ||
          c == '['.to_int() ||
          c == '"'.to_int() ||
          c == '-'.to_int() ||
          (c >= '0'.to_int() && c <= '9'.to_int()) ||
          c == 't'.to_int() ||
          c == 'f'.to_int() ||
          c == 'n'.to_int()
        if starts {
          "\"\{chars(text, 30)}\" is not valid JSON"
        } else {
          let token = slice(text, i, b=i + 1)
          let context = if text.length() < 21 {
            "\"\{text}\""
          } else {
            let from = if i > 10 { i - 10 } else { 0 }
            let to = if i + 10 < text.length() { i + 10 } else { text.length() }
            (if from > 0 { "..." } else { "" }) +
            "\"" +
            slice(text, from, b=to) +
            "\"" +
            (if to < text.length() { "..." } else { "" })
          }
          "Unexpected token '\{token}', \{context} is not valid JSON"
        }
      }
      raise Thrown("SyntaxError", jobj([("message", js(message)), ("name", js("SyntaxError"))]))
    }
  }
}

///|
/// What a request is: its method (GET where none), headers in order, body.
pub(all) struct Request {
  url : String
  verb : String?
  headers : Array[(String, String)]
  body : String?
  timeout_ms : Int
}

///|
pub fn headers_jv(h : Array[(String, String)]) -> JV {
  let mut o = JV::Obj([])
  for p in h {
    o = jset(o, p.0, js(p.1))
  }
  o
}

///|
/// The station's parts that the accounts' IO goes through.
pub struct Io {
  b : Backend
}

///|
/// The station's parts as the accounts ask them, through `b` (the station that composes the accounts makes one).
pub fn Io::new(b : Backend) -> Io {
  { b, }
}

///|
/// A request made: its answer, or the failure Node gave (a TimeoutError, a TypeError "fetch failed", a socket's).
pub async fn Io::fetch(self : Io, r : Request) -> Response {
  let fields = [("url", js(r.url))]
  match r.verb {
    Some(v) => fields.push(("method", js(v)))
    None => ()
  }
  fields.push(("headers", headers_jv(r.headers)))
  match r.body {
    Some(b) => fields.push(("body", js(b)))
    None => ()
  }
  fields.push(("timeoutMs", jint(r.timeout_ms)))
  let a = self.b.ask("fetch", [jobj(fields)])
  {
    status: jnumber(a.get("status")).unwrap_or(0.0).to_int(),
    text: jstr(a.get("text")).unwrap_or(""),
  }
}

///|
/// A GET of `url` with these headers, in `ms`.
pub async fn Io::get(
  self : Io,
  url : String,
  headers : Array[(String, String)],
  ms : Int,
) -> Response {
  self.fetch({ url, verb: None, headers, body: None, timeout_ms: ms })
}

///|
/// `readFile(path, "utf8")`.
pub async fn Io::read_file(self : Io, path : String) -> String {
  match self.b.ask("fs.readFile", [js(path)]) {
    Str(s) => s
    other => js_string(Some(other))
  }
}

///|
/// `readFile(path, "utf8")`, None where it throws (`.catch(() => null)`).
pub async fn Io::read_file_or_none(self : Io, path : String) -> String? {
  Some(self.read_file(path)) catch {
    _ => None
  }
}

///|
/// `writePrivateSoon(path, text)` (ops/files.ts): written whole, readable by its owner alone.
pub async fn Io::write_private(self : Io, path : String, text : String) -> Unit {
  ignore(self.b.ask("fs.writePrivate", [js(path), js(text)]))
}

///|
/// `mkdir(path, { recursive: true })`.
pub async fn Io::mkdir(self : Io, path : String) -> Unit {
  ignore(self.b.ask("fs.mkdir", [js(path)]))
}

///|
/// `rm(path, { recursive: true, force: true })`.
pub async fn Io::rm(self : Io, path : String) -> Unit {
  ignore(self.b.ask("fs.rm", [js(path)]))
}

///|
/// `rename(from, to)`.
pub async fn Io::rename(self : Io, from : String, to : String) -> Unit {
  ignore(self.b.ask("fs.rename", [js(from), js(to)]))
}

///|
/// `readdir(path)`.
pub async fn Io::readdir(self : Io, path : String) -> Array[String] {
  jitems(Some(self.b.ask("fs.readdir", [js(path)]))).map(x => js_string(Some(x)))
}

///|
/// `access(path)` resolved: whether it is there.
pub async fn Io::exists(self : Io, path : String) -> Bool {
  self.b.ask("fs.exists", [js(path)]) == Bool(true)
}

///|
/// `stat(path)`: its size and mtimeMs, as the stamp `${size}:${mtimeMs}` the account files are kept by.
pub async fn Io::stamp(self : Io, path : String) -> String {
  js_string(Some(self.b.ask("fs.stamp", [js(path)])))
}

///|
/// `randomBytes(n).toString("hex")`.
pub async fn Io::random_hex(self : Io, n : Int) -> String {
  js_string(Some(self.b.ask("crypto.randomHex", [jint(n)])))
}

///|
/// `randomUUID()`.
pub async fn Io::uuid(self : Io) -> String {
  js_string(Some(self.b.ask("crypto.randomUUID", [])))
}

///|
/// What node:os says of this machine: `{hostname, type, arch, release}`.
pub async fn Io::os(self : Io) -> JV {
  self.b.ask("os.info", [])
}

///|
/// A socket's errors where the other side was not reached (ops/unanswered.ts `UNREACHED`).
let unreached : Array[String] = [
  "ECONNREFUSED", "ECONNRESET", "ECONNABORTED", "ENOTFOUND", "EAI_AGAIN", "ETIMEDOUT",
  "EHOSTUNREACH", "ENETUNREACH", "EPIPE",
]

///|
/// ops/unanswered.ts `unanswered`: a request that got no answer at all.
pub fn unanswered(e : Error) -> Bool {
  match e {
    Thrown(kind, said) => {
      let name = jstr(said.get("name")).unwrap_or(kind)
      name == "TimeoutError" ||
      (
        kind == "TypeError" &&
        js_string(said.get("message")) == "fetch failed"
      ) ||
      unreached.contains(js_string(said.get("code")))
    }
    _ => false
  }
}

///|
/// URLSearchParams' form encoding of one value (application/x-www-form-urlencoded).
pub fn form_encode(s : String) -> String {
  @url.percent_encode(
    s,
    c => (c >= 'a'.to_int() && c <= 'z'.to_int()) ||
      (c >= 'A'.to_int() && c <= 'Z'.to_int()) ||
      (c >= '0'.to_int() && c <= '9'.to_int()) ||
      c == '*'.to_int() ||
      c == '-'.to_int() ||
      c == '.'.to_int() ||
      c == '_'.to_int(),
    space_plus=true,
  )
}

///|
/// console.ts `postForm`: an OAuth form posted, its status and its JSON (null for none).
pub async fn Io::post_form(
  self : Io,
  url : String,
  form : Array[(String, String)],
  headers : Array[(String, String)],
) -> (Int, JV) {
  let all = [
    ("content-type", "application/x-www-form-urlencoded"),
    ("accept", "application/json"),
  ]
  for h in headers {
    let mut put = false
    for i, a in all {
      if a.0 == h.0 {
        all[i] = h
        put = true
      }
    }
    if !put {
      all.push(h)
    }
  }
  let body = form.map(p => form_encode(p.0) + "=" + form_encode(p.1)).join("&")
  let response = self.fetch({
    url,
    verb: Some("POST"),
    headers: all,
    body: Some(body),
    timeout_ms: 20_000,
  })
  let parsed = try_parse(response.text).unwrap_or(Null)
  (response.status, parsed)
}

///|
/// Lowercase hex as bytes.
pub fn hex_bytes(hex : String) -> Bytes {
  let n = hex.length() / 2
  let out = FixedArray::make(n, b'\x00')
  let digit = (c : Int) => if c >= '0'.to_int() && c <= '9'.to_int() {
    c - '0'.to_int()
  } else if c >= 'a'.to_int() && c <= 'f'.to_int() {
    c - 'a'.to_int() + 10
  } else if c >= 'A'.to_int() && c <= 'F'.to_int() {
    c - 'A'.to_int() + 10
  } else {
    0
  }
  for i in 0..<n {
    let hi = digit(hex.unsafe_charcode_at(2 * i))
    let lo = digit(hex.unsafe_charcode_at(2 * i + 1))
    out[i] = (hi * 16 + lo).to_byte()
  }
  Bytes::from_fixedarray(out)
}

///|
/// Buffer's `toString("base64")` with `+/` made `-_` and the padding taken off (base64url).
pub fn base64url(b : Bytes) -> String {
  let s = @base64.encode(b)
  let out = StringBuilder::new()
  for c in s {
    match c {
      '+' => out.write_char('-')
      '/' => out.write_char('_')
      '=' => ()
      x => out.write_char(x)
    }
  }
  out.to_string()
}

///|
/// Buffer.from(text, "base64url") read as UTF-8 (what is not of the alphabet left out, as Node does).
pub fn base64url_text(text : String) -> String {
  let clean = StringBuilder::new()
  for c in text {
    match c {
      '-' => clean.write_char('+')
      '_' => clean.write_char('/')
      'A'..='Z' | 'a'..='z' | '0'..='9' | '+' | '/' => clean.write_char(c)
      _ => ()
    }
  }
  let mut s = clean.to_string()
  // a lone character past whole groups of four says nothing (Node drops it)
  if s.length() % 4 == 1 {
    s = slice(s, 0, b=s.length() - 1)
  }
  while s.length() % 4 != 0 {
    s = s + "="
  }
  utf8_text(@base64.decode(s)) catch {
    _ => ""
  }
}
