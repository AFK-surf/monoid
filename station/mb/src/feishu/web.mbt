// Feishu's OpenAPI over HTTP (station/src/feishu/web.ts): one client per app, with its tenant_access_token got from
// the app's id and secret and taken again before it runs out. Feishu (open.feishu.cn) or Lark (open.larksuite.com), or
// a stand-in for tests ($STILLFAIL_FEISHU_API, one address for both: `Net::stand_in`).
//
// What it asks of the machine is given it (`Net`): HTTP (`fetch`, the shell's on a station: `host_net`), and the
// machine's own time (`now`, `sleep`: the TypeScript's `wall`).

///|
/// A Feishu call Feishu said no to: its code and words (`FeishuError`, message `feishu <what>: <code> <msg>`).
pub(all) suberror ApiError {
  ApiError(String, Double)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for ApiError with output(self, logger) {
  match self {
    ApiError(m, _) => logger.write_string(m)
  }
}

///|
/// The code of a call's refusal, where Feishu said one.
pub fn api_code(e : Error) -> Double? {
  match e {
    ApiError(_, code) => Some(code)
    _ => None
  }
}

///|
fn api_error(what : String, code : Double, msg : String) -> ApiError {
  ApiError("feishu \{what}: \{num_text(code)} \{msg}", code)
}

///|
/// An HTTP request as `fetch` makes it.
pub(all) struct HttpRequest {
  url : String
  verb : String
  headers : Array[(String, String)]
  body : Bytes?
  timeout_ms : Int
}

///|
/// Its answer: the status, the headers (names lowercase), the body.
pub(all) struct HttpResponse {
  status : Int
  headers : Array[(String, String)]
  body : Bytes
}

///|
/// `response.headers.get(name)`: every value of that name joined by ", ", None where there is none.
pub fn HttpResponse::header(self : HttpResponse, name : String) -> String? {
  let lower = @jscase.lower(name)
  let found = self.headers.filter(h => @jscase.lower(h.0) == lower).map(h => h.1)
  if found.is_empty() {
    None
  } else {
    Some(found.join(", "))
  }
}

///|
/// `response.ok`.
pub fn HttpResponse::ok(self : HttpResponse) -> Bool {
  self.status >= 200 && self.status <= 299
}

///|
/// What the Feishu code asks of the machine: HTTP, the machine's own time (`wall.now`, `wall.sleep`), and the stand-in
/// for Feishu's addresses that tests give ($STILLFAIL_FEISHU_API).
pub(all) struct Net {
  fetch : async (HttpRequest) -> HttpResponse
  now : () -> Int64
  sleep : async (Int) -> Unit
  stand_in : String?
}

///|
pub fn open_of(domain : String) -> String {
  if domain == "lark" {
    "https://open.larksuite.com"
  } else {
    "https://open.feishu.cn"
  }
}

///|
/// Where apps are made by a scan (the registration's device flow).
pub fn accounts_of(domain : String) -> String {
  if domain == "lark" {
    "https://accounts.larksuite.com"
  } else {
    "https://accounts.feishu.cn"
  }
}

///|
/// `domainOf`: "lark" for "lark", else "feishu".
pub fn domain_of(v : JV?) -> String {
  if v == Some(Str("lark")) {
    "lark"
  } else {
    "feishu"
  }
}

///|
/// The OpenAPI's address: the stand-in when there is one.
pub fn open_base(net : Net, domain : String) -> String {
  match net.stand_in {
    Some(s) if s != "" => s
    _ => open_of(domain)
  }
}

///|
pub fn accounts_base(net : Net, domain : String) -> String {
  match net.stand_in {
    Some(s) if s != "" => s
    _ => accounts_of(domain)
  }
}

///|
/// Feishu's codes for too many calls: waited out, like Slack's 429.
let limited : Array[Double] = [99991400.0, 11232.0, 230020.0]

///|
let retries : Int = 4

///|
/// A file sent with a call (multipart).
pub(all) struct FilePart {
  field : String
  bytes : Bytes
  name : String
  mime : String
}

///|
/// What a call answers: Feishu's JSON, or a non-JSON answer to an agent's call (only the tool puts it in that session's
/// workspace).
pub(all) enum Answered {
  Data(JV)
  File(Bytes, String, String)
}

///|
pub fn Answered::data(self : Answered) -> JV {
  match self {
    Data(j) => j
    File(_, _, _) => Null
  }
}

// ── URLs ──

///|
/// application/x-www-form-urlencoded's byte serializer (URLSearchParams').
fn form_encode(s : String) -> String {
  let out = StringBuilder::new()
  let hex = "0123456789ABCDEF"
  for b in utf8(s) {
    let c = b.to_int()
    if (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c is ('*' | '-' | '.' | '_') {
      out.write_char(c.unsafe_to_char())
    } else if c == 0x20 {
      out.write_char('+')
    } else {
      out.write_char('%')
      out.write_char(hex.unsafe_charcode_at(c >> 4).unsafe_to_char())
      out.write_char(hex.unsafe_charcode_at(c & 15).unsafe_to_char())
    }
  }
  out.to_string()
}

///|
fn hex_digit(c : Int) -> Int? {
  if c >= '0' && c <= '9' {
    Some(c - '0')
  } else if c >= 'a' && c <= 'f' {
    Some(c - 'a' + 10)
  } else if c >= 'A' && c <= 'F' {
    Some(c - 'A' + 10)
  } else {
    None
  }
}

///|
/// application/x-www-form-urlencoded's parser's percent-decoding of one name or value (`+` a space).
fn form_decode(s : String) -> String {
  let bytes = utf8(s)
  let out = []
  let n = bytes.length()
  let mut i = 0
  while i < n {
    let c = bytes[i].to_int()
    if c == '+' {
      out.push(b' ')
      i += 1
    } else if c == '%' &&
      i + 2 < n &&
      hex_digit(bytes[i + 1].to_int()) is Some(h) &&
      hex_digit(bytes[i + 2].to_int()) is Some(l) {
      out.push((h * 16 + l).to_byte())
      i += 3
    } else {
      out.push(bytes[i])
      i += 1
    }
  }
  utf8_text(Bytes::from_array(out))
}

///|
/// A query as URLSearchParams reads it.
fn form_parse(q : String) -> Array[(String, String)] {
  let out = []
  for part in q.split("&") {
    let p = part.to_string()
    if p == "" {
      continue
    }
    let (name, value) = match p.find("=") {
      Some(i) => (p.unsafe_substring(start=0, end=i), p.unsafe_substring(start=i + 1, end=p.length()))
      None => (p, "")
    }
    out.push((form_decode(name), form_decode(value)))
  }
  out
}

///|
/// `new URL(raw)` with each of `query` set (`url.searchParams.set`), as `href`: the query written again by
/// URLSearchParams once one is set. An address `new URL` refuses is its TypeError.
pub fn url_with(raw : String, query : Array[(String, String)]) -> String raise FeishuError {
  guard @cloud_net.parse_url(raw) is Some(u) else { raise FeishuError("Invalid URL") }
  let href = u.href()
  if query.is_empty() {
    return href
  }
  let list = form_parse(u.query.unwrap_or(""))
  for kv in query {
    let mut found = false
    let kept = []
    for e in list {
      if e.0 == kv.0 {
        if !found {
          kept.push(kv)
          found = true
        }
      } else {
        kept.push(e)
      }
    }
    if !found {
      kept.push(kv)
    }
    list.clear()
    list.append(kept)
  }
  let tail = (match u.query {
      Some(q) => q.length() + 1
      None => 0
    }) +
    (match u.fragment {
      Some(f) => f.length() + 1
      None => 0
    })
  let prefix = href.unsafe_substring(start=0, end=href.length() - tail)
  let serialized = list.map(e => form_encode(e.0) + "=" + form_encode(e.1)).join("&")
  let hash = match u.fragment {
    Some(f) => "#" + f
    None => ""
  }
  prefix + "?" + serialized + hash
}

// ── multipart ──

///|
/// The boundary the program's multipart bodies are written with (undici makes its own at random: what is compared is
/// the parts).
pub let boundary : String = "----formdata-stillfail-feishu-7a31c3b2"

///|
/// undici's escape of a part's name or file name.
fn part_name(s : String) -> String {
  replace_every(replace_every(replace_every(s, "\n", "%0A"), "\r", "%0D"), "\"", "%22")
}

///|
/// undici's `\r?\n|\r` as `\r\n` in a string field's value.
fn crlf(s : String) -> String {
  let out = StringBuilder::new()
  let n = s.length()
  let mut i = 0
  while i < n {
    let c = s.unsafe_charcode_at(i)
    if c == '\r' {
      out.write_string("\r\n")
      i += if i + 1 < n && s.unsafe_charcode_at(i + 1) == '\n' { 2 } else { 1 }
    } else if c == '\n' {
      out.write_string("\r\n")
      i += 1
    } else {
      out.write_char(c.unsafe_to_char())
      i += 1
    }
  }
  out.to_string()
}

///|
/// A FormData's body as undici writes it: each of `body`'s fields (a string as it is, anything else as JSON), then
/// each file.
pub fn multipart(body : JV?, files : Array[FilePart]) -> Bytes {
  let out = []
  let put = (s : String) => for b in utf8(s) {
    out.push(b)
  }
  let fields = match body {
    Some(Obj(_) as o) => jkeys(o).map(k => (k, o.get(k).unwrap()))
    Some(Arr(a)) => a.mapi((i, v) => (i.to_string(), v))
    Some(Str(s)) => {
      let parts = []
      for i in 0..<s.length() {
        parts.push((i.to_string(), Str(s.unsafe_substring(start=i, end=i + 1))))
      }
      parts
    }
    _ => []
  }
  for f in fields {
    let value = match f.1 {
      Str(s) => s
      v => stringify(v)
    }
    put(
      "--\{boundary}\r\nContent-Disposition: form-data; name=\"\{part_name(f.0)}\"\r\n\r\n\{crlf(value)}\r\n",
    )
  }
  for f in files {
    let mime = if f.mime == "" { "application/octet-stream" } else { f.mime }
    put(
      "--\{boundary}\r\nContent-Disposition: form-data; name=\"\{part_name(f.field)}\"; filename=\"\{part_name(f.name)}\"\r\nContent-Type: \{mime}\r\n\r\n",
    )
    for b in f.bytes {
      out.push(b)
    }
    put("\r\n")
  }
  put("--\{boundary}--\r\n")
  Bytes::from_array(out)
}

///|
/// `/^(?:application\/json|[^/;\s]+\/[^;\s]+\+json)(?:\s*;|\s*$)/i`.
pub fn is_json_type(t : String) -> Bool {
  let l = ascii_lower(t)
  let n = l.length()
  let tail_ok = (at : Int) => {
    let mut i = at
    while i < n && is_js_space(l.unsafe_charcode_at(i)) {
      i += 1
    }
    i == n || l.unsafe_charcode_at(i) == ';'
  }
  if starts(l, "application/json") && tail_ok(16) {
    return true
  }
  // [^/;\s]+ \/ [^;\s]+ ending in "+json" (at least one character before it)
  let mut i = 0
  while i < n &&
        !(l.unsafe_charcode_at(i) is ('/' | ';')) &&
        !is_js_space(l.unsafe_charcode_at(i)) {
    i += 1
  }
  if i == 0 || i >= n || l.unsafe_charcode_at(i) != '/' {
    return false
  }
  let from = i + 1
  let mut j = from
  while j < n && l.unsafe_charcode_at(j) != ';' && !is_js_space(l.unsafe_charcode_at(j)) {
    j += 1
  }
  // the subtype's run ends where "+json" does, with something before it
  if j - from < 6 || l.unsafe_substring(start=j - 5, end=j) != "+json" {
    return false
  }
  tail_ok(j)
}

// ── the client ──

///|
priv struct Token {
  value : String
  until : Double
}

///|
pub struct FeishuClient {
  base : String
  app_id : String
  priv app_secret : String
  priv net : Net
  priv mut token : Token?
  priv mut fetching : @effect.Deferred[String]?
}

///|
/// `base` with its trailing slashes off (`/\/+$/`).
fn without_trailing_slashes(s : String) -> String {
  let mut n = s.length()
  while n > 0 && s.unsafe_charcode_at(n - 1) == '/' {
    n -= 1
  }
  s.unsafe_substring(start=0, end=n)
}

///|
pub fn FeishuClient::new(
  net : Net,
  app_id : String,
  app_secret : String,
  domain? : String = "feishu",
  base? : String,
) -> FeishuClient {
  let b = match base {
    Some(b) => b
    None => open_base(net, domain)
  }
  {
    base: without_trailing_slashes(b),
    app_id,
    app_secret,
    net,
    token: None,
    fetching: None,
  }
}

///|
/// The app's tenant_access_token, taken again ten minutes before it runs out (Feishu gives two hours).
pub async fn FeishuClient::tenant_token(self : FeishuClient) -> String {
  match self.token {
    Some(t) if (self.net.now)().to_double() < t.until => return t.value
    _ => ()
  }
  match self.fetching {
    Some(d) => return d.wait()
    None => ()
  }
  let d : @effect.Deferred[String] = @effect.Deferred::new()
  self.fetching = Some(d)
  let got = try {
    let body = self
      .raw(
        "POST",
        "/open-apis/auth/v3/tenant_access_token/internal",
        Some(
          jobj([
            ("app_id", Some(js(self.app_id))),
            ("app_secret", Some(js(self.app_secret))),
          ]),
        ),
        None,
      )
      .data()
    let value = text(jget(Some(body), "tenant_access_token"))
    if value == "" {
      raise FeishuError("feishu gave no tenant_access_token")
    }
    let expire = jnumber(jget(Some(body), "expire")).unwrap_or(7200.0)
    let keep = @cmp.maximum(60.0, expire - 600.0)
    self.token = Some({
      value,
      until: (self.net.now)().to_double() + keep * 1000.0,
    })
    Ok(value)
  } catch {
    e => Err(e)
  }
  self.fetching = None
  match got {
    Ok(v) => {
      ignore(d.succeed(v))
      v
    }
    Err(e) => {
      ignore(d.fail(e))
      raise e
    }
  }
}

///|
/// A call as Feishu answers it: its JSON with code 0, else an ApiError. `body` is JSON (or multipart with `files`);
/// `query` goes in the address. Rate limits are waited out. An agent's call can also take non-JSON answers.
async fn FeishuClient::raw(
  self : FeishuClient,
  verb : String,
  path : String,
  body : JV?,
  token : String?,
  query? : Array[(String, String)] = [],
  files? : Array[FilePart] = [],
  take_file? : Bool = false,
) -> Answered {
  let url = url_with(self.base + path, query)
  let what = "\{verb} \{path}"
  for attempt = 0; ; attempt = attempt + 1 {
    let headers = match token {
      Some(t) => [("authorization", "Bearer \{t}")]
      None => []
    }
    let payload = if files.length() > 0 {
      headers.push(("content-type", "multipart/form-data; boundary=\{boundary}"))
      Some(multipart(body, files))
    } else {
      match body {
        Some(b) if verb != "GET" => {
          headers.push(("content-type", "application/json; charset=utf-8"))
          Some(utf8(stringify(b)))
        }
        _ => None
      }
    }
    let response = (self.net.fetch)({
      url,
      verb,
      headers,
      body: payload,
      timeout_ms: if files.length() > 0 { 300_000 } else { 30_000 },
    })
    let wait_limit = async fn() {
      let said_text = match response.header("x-ogw-ratelimit-reset") {
        Some(s) => s
        None => response.header("retry-after").unwrap_or("1")
      }
      let said = js_number(said_text)
      let seconds = if is_finite(said) && said > 0.0 {
        @cmp.minimum(said, 30.0)
      } else {
        1.0
      }
      (self.net.sleep)((seconds * 1000.0).to_int())
    }
    if response.status == 429 && attempt < retries {
      wait_limit()
      continue
    }
    let content_type = response
      .header("content-type")
      .unwrap_or("application/octet-stream")
    if take_file && !is_json_type(content_type) {
      if !response.ok() {
        raise api_error(what, response.status.to_double(), "HTTP \{response.status}")
      }
      return File(
        response.body,
        content_type,
        response.header("content-disposition").unwrap_or(""),
      )
    }
    let said = utf8_text(response.body, bom=true)
    let data = if said == "" {
      Obj([])
    } else {
      match try_parse(said) {
        Some(d) => d
        None =>
          raise api_error(what, response.status.to_double(), slice_js(said, 0, b=200))
      }
    }
    let code = match jget(Some(data), "code") {
      Some(Num(c)) => c
      _ => if response.ok() { 0.0 } else { response.status.to_double() }
    }
    if limited.contains(code) && attempt < retries {
      wait_limit()
      continue
    }
    if code != 0.0 {
      let msg = match jget(Some(data), "msg") {
        Some(Str(m)) => m
        _ => "HTTP \{response.status}"
      }
      raise api_error(what, code, msg)
    }
    return Data(data)
  }
}

///|
/// An OpenAPI call as the app (its tenant token): Feishu's whole JSON answer, or a file when `take_file` is set.
pub async fn FeishuClient::api(
  self : FeishuClient,
  verb : String,
  path : String,
  body? : JV? = None,
  query? : Array[(String, String)] = [],
  files? : Array[FilePart] = [],
  take_file? : Bool = false,
) -> Answered {
  let token = self.tenant_token()
  self.raw(verb, path, body, Some(token), query~, files~, take_file~) catch {
    // A token Feishu stopped taking (the secret changed, say): once more with a new one.
    ApiError(_, code) as e if code == 99991663.0 || code == 99991661.0 => {
      ignore(e)
      self.token = None
      let again = self.tenant_token()
      self.raw(verb, path, body, Some(again), query~, files~, take_file~)
    }
    e => raise e
  }
}

///|
/// `api(...)`'s JSON (the station's own calls take none but JSON).
pub async fn FeishuClient::call(
  self : FeishuClient,
  verb : String,
  path : String,
  body? : JV? = None,
  query? : Array[(String, String)] = [],
  files? : Array[FilePart] = [],
) -> JV {
  self.api(verb, path, body~, query~, files~).data()
}

///|
/// A message's file or image (`GET /im/v1/messages/:id/resources/:key`): its bytes.
pub async fn FeishuClient::resource(
  self : FeishuClient,
  message_id : String,
  key : String,
  kind : String,
) -> Bytes {
  let url = url_with(
    "\{self.base}/open-apis/im/v1/messages/\{encode_uri_component(message_id)}/resources/\{encode_uri_component(key)}",
    [("type", kind)],
  )
  let token = self.tenant_token()
  let got = (self.net.fetch)({
    url,
    verb: "GET",
    headers: [("authorization", "Bearer \{token}")],
    body: None,
    timeout_ms: 120_000,
  })
  if !got.ok() || starts(got.header("content-type").unwrap_or(""), "application/json") {
    let said = utf8_text(got.body, bom=true)
    let mut msg = "HTTP \{got.status}"
    match try_parse(said) {
      Some(j) =>
        match jget(Some(j), "msg") {
          Some(Str(m)) => msg = "\{js_string(jget(Some(j), "code"))} \{m}"
          _ => ()
        }
      None => ()
    }
    raise FeishuError("feishu resource: \{msg}")
  }
  got.body
}

///|
/// The long connection's address and its pings' interval (`POST /callback/ws/endpoint`).
pub async fn FeishuClient::endpoint(self : FeishuClient) -> (String, Double) {
  let d = self
    .raw(
      "POST",
      "/callback/ws/endpoint",
      Some(
        jobj([
          ("AppID", Some(js(self.app_id))),
          ("AppSecret", Some(js(self.app_secret))),
        ]),
      ),
      None,
    )
    .data()
  let url = match jget(jget(Some(d), "data"), "URL") {
    Some(Str(u)) if u != "" => u
    _ => raise FeishuError("feishu gave no long connection address")
  }
  let ping = match jget(jget(jget(Some(d), "data"), "ClientConfig"), "PingInterval") {
    Some(Num(p)) if p > 0.0 => p
    _ => 120.0
  }
  (url, ping * 1000.0)
}
