// The part of WHATWG's URL a Comma connect's address goes through (`new URL(server)`, `new URL("/v1/connect", base)`,
// `url.protocol = …`, `url.searchParams.set`, `url.host`, `url.toString()`), as node's URL makes it for the schemes a
// connect is made of: the special ones (http, https, ws, wss, ftp, file) with an authority. A host of other than ASCII
// letters is refused here where node would give its punycode (no Comma server has one).

///|
priv struct Url {
  scheme : String
  username : String
  password : String
  host : String
  port : Int?
  path : String
  query : String?
  /// A scheme not special, with no authority (`mailto:x`): its path opaque.
  opaque : Bool
}

///|
fn default_port(scheme : String) -> Int? {
  match scheme {
    "http" | "ws" => Some(80)
    "https" | "wss" => Some(443)
    "ftp" => Some(21)
    _ => None
  }
}

///|
fn is_special(scheme : String) -> Bool {
  scheme is ("http" | "https" | "ws" | "wss" | "ftp" | "file")
}

///|
fn ascii_lower(s : String) -> String {
  let out = StringBuilder::new()
  for i in 0..<s.length() {
    let c = s.unsafe_charcode_at(i)
    out.write_char((if c >= 'A' && c <= 'Z' { c + 32 } else { c }).unsafe_to_char())
  }
  out.to_string()
}

///|
fn userinfo_keep(v : Int) -> Bool {
  v > 0x20 &&
  v < 0x7f &&
  !(v is ('"' | '#' | '<' | '>' | '?' | '`' | '{' | '}' | '/' | ':' | ';' | '=' | '@' | '[' | '\\' | ']' | '^' | '|'))
}

///|
fn path_keep(v : Int) -> Bool {
  v > 0x20 && v < 0x7f && !(v is ('"' | '#' | '<' | '>' | '?' | '`' | '{' | '}'))
}

///|
fn query_keep(special : Bool) -> (Int) -> Bool {
  v => v > 0x20 && v < 0x7f && !(v is ('"' | '#' | '<' | '>')) && !(special && v == '\'')
}

///|
/// application/x-www-form-urlencoded's byte set (URLSearchParams).
fn form_keep(v : Int) -> Bool {
  (v >= 'a' && v <= 'z') || (v >= 'A' && v <= 'Z') || (v >= '0' && v <= '9') || v is ('*' | '-' | '.' | '_')
}

///|
/// An IPv4 address's part as the host parser reads one (0x hex, 0 octal); None where it is not a number.
fn ipv4_number(s : String) -> Double? {
  if s == "" {
    return None
  }
  let (digits, radix) = if s.length() >= 2 && s.unsafe_charcode_at(0) == '0' && s.unsafe_charcode_at(1) is ('x' | 'X') {
    (s.unsafe_substring(start=2, end=s.length()), 16)
  } else if s.length() >= 2 && s.unsafe_charcode_at(0) == '0' {
    (s.unsafe_substring(start=1, end=s.length()), 8)
  } else {
    (s, 10)
  }
  if digits == "" {
    return Some(0.0)
  }
  let mut v = 0.0
  for i in 0..<digits.length() {
    let c = digits.unsafe_charcode_at(i)
    let d = if c >= '0' && c <= '9' {
      c - '0'
    } else if c >= 'a' && c <= 'f' {
      c - 'a' + 10
    } else if c >= 'A' && c <= 'F' {
      c - 'A' + 10
    } else {
      99
    }
    if d >= radix {
      return None
    }
    v = v * radix.to_double() + d.to_double()
  }
  Some(v)
}

///|
/// A host of a special URL: lowercased, an IPv4 address in its four parts; None where it is refused.
fn special_host(raw : String) -> String? {
  if raw == "" {
    return None
  }
  if raw.unsafe_charcode_at(0) == '[' {
    if raw.unsafe_charcode_at(raw.length() - 1) != ']' {
      return None
    }
    return Some(ascii_lower(raw))
  }
  // percent-decoded
  let bytes = []
  let mut i = 0
  let enc = utf8_of(raw)
  while i < enc.length() {
    let b = enc[i].to_int()
    if b == '%' && i + 2 < enc.length() {
      let h = ipv4_number("0x" + enc[i + 1:i + 3].to_bytes().to_array().map(x => x.to_int().unsafe_to_char().to_string()).join(""))
      match h {
        Some(v) if enc[i + 1].to_int() != 'x' && enc[i + 1].to_int() != 'X' => {
          bytes.push(v.to_int().to_byte())
          i += 3
          continue
        }
        _ => ()
      }
    }
    bytes.push(enc[i])
    i += 1
  }
  let host = ascii_lower(text_of_utf8(Bytes::from_array(FixedArray::makei(bytes.length(), k => bytes[k]))))
  for k in 0..<host.length() {
    let c = host.unsafe_charcode_at(k)
    if c >= 0x80 {
      return None
    }
    if c <= 0x20 ||
      c == 0x7f ||
      c is ('#' | '%' | '/' | ':' | '<' | '>' | '?' | '@' | '[' | '\\' | ']' | '^' | '|') {
      return None
    }
  }
  // An IPv4 address where its last part is a number.
  let parts = host.split(".").map(p => p.to_string()).collect()
  let parts = if parts.length() > 1 && parts[parts.length() - 1] == "" {
    parts[0:parts.length() - 1].to_array()
  } else {
    parts
  }
  let last = parts[parts.length() - 1]
  let numeric = last != "" &&
    (
      ipv4_number(last) is Some(_) ||
      last.iter().all(c => c >= '0' && c <= '9')
    )
  if !numeric {
    return Some(host)
  }
  if parts.length() > 4 {
    return None
  }
  let nums = []
  for p in parts {
    match ipv4_number(p) {
      Some(v) => nums.push(v)
      None => return None
    }
  }
  for k in 0..<(nums.length() - 1) {
    if nums[k] > 255.0 {
      return None
    }
  }
  let room = 256.0.pow((5 - nums.length()).to_double())
  if nums[nums.length() - 1] >= room {
    return None
  }
  let mut v = nums[nums.length() - 1]
  for k in 0..<(nums.length() - 1) {
    v = v + nums[k] * 256.0.pow((3 - k).to_double())
  }
  let a = []
  let mut n = v
  for _ in 0..<4 {
    let d = n - (n / 256.0).floor() * 256.0
    a.push(d.to_int().to_string())
    n = (n / 256.0).floor()
  }
  Some("\{a[3]}.\{a[2]}.\{a[1]}.\{a[0]}")
}

///|
/// `new URL(input)`: None where it throws (Invalid URL).
fn parse_url(input : String) -> Url? {
  // leading and trailing C0 controls and spaces, and every tab and newline, taken out
  let mut start = 0
  let mut end = input.length()
  while start < end && input.unsafe_charcode_at(start) <= 0x20 {
    start += 1
  }
  while end > start && input.unsafe_charcode_at(end - 1) <= 0x20 {
    end -= 1
  }
  let s = input
    .unsafe_substring(start~, end~)
    .iter()
    .filter(c => !(c is ('\t' | '\n' | '\r')))
    .collect()
  let s = String::from_array(s)
  // scheme
  if s.length() == 0 {
    return None
  }
  let c0 = s.unsafe_charcode_at(0)
  if !((c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z')) {
    return None
  }
  let mut i = 1
  while i < s.length() {
    let c = s.unsafe_charcode_at(i)
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c is ('+' | '-' | '.') {
      i += 1
    } else {
      break
    }
  }
  if i >= s.length() || s.unsafe_charcode_at(i) != ':' {
    return None
  }
  let scheme = ascii_lower(s.unsafe_substring(start=0, end=i))
  let rest = s.unsafe_substring(start=i + 1, end=s.length())
  let special = is_special(scheme)
  let slash = (c : Int) => c == '/' || (special && c == '\\')
  // the authority, after its slashes
  let mut j = 0
  if special {
    while j < rest.length() && slash(rest.unsafe_charcode_at(j)) {
      j += 1
    }
    if scheme == "file" {
      // file://host/path, or a path: its host empty where it is none or localhost
      let two = rest.length() >= 2 && slash(rest.unsafe_charcode_at(0)) && slash(rest.unsafe_charcode_at(1))
      let (host, after) = if two {
        let mut e = 2
        while e < rest.length() && !(slash(rest.unsafe_charcode_at(e)) || rest.unsafe_charcode_at(e) is ('?' | '#')) {
          e += 1
        }
        let raw = rest.unsafe_substring(start=2, end=e)
        let h = if raw == "" {
          ""
        } else {
          match special_host(raw) {
            Some("localhost") => ""
            Some(h) => h
            None => return None
          }
        }
        (h, rest.unsafe_substring(start=e, end=rest.length()))
      } else {
        ("", rest.unsafe_substring(start=j, end=rest.length()))
      }
      let after = if two { after } else if j > 0 { "/" + after } else { after }
      let (path_part, query) = match after.find("?") {
        Some(q) => (after.unsafe_substring(start=0, end=q), Some(after.unsafe_substring(start=q + 1, end=after.length())))
        None => (after, None)
      }
      let path_part = match path_part.find("#") {
        Some(h) => path_part.unsafe_substring(start=0, end=h)
        None => path_part
      }
      let p = String::from_array(path_part.iter().map(c => if c == '\\' { '/' } else { c }).collect())
      let p = if p.has_prefix("/") { p } else { "/" + p }
      return Some({
        scheme,
        username: "",
        password: "",
        host,
        port: None,
        path: @url.percent_encode(p, path_keep_pct),
        query: query.map(q => @url.percent_encode(q, query_keep_pct(true))),
        opaque: false,
      })
    }
  } else if rest.length() >= 2 && rest.unsafe_charcode_at(0) == '/' && rest.unsafe_charcode_at(1) == '/' {
    j = 2
  } else {
    // an opaque path (or a path with no authority): what a connect is never made of
    let (path, query) = match rest.find("?") {
      Some(q) => (rest.unsafe_substring(start=0, end=q), Some(rest.unsafe_substring(start=q + 1, end=rest.length())))
      None => (rest, None)
    }
    let path = match path.find("#") {
      Some(h) => path.unsafe_substring(start=0, end=h)
      None => path
    }
    return Some({ scheme, username: "", password: "", host: "", port: None, path, query, opaque: true })
  }
  let mut k = j
  while k < rest.length() {
    let c = rest.unsafe_charcode_at(k)
    if slash(c) || c == '?' || c == '#' {
      break
    }
    k += 1
  }
  let authority = rest.unsafe_substring(start=j, end=k)
  let after = rest.unsafe_substring(start=k, end=rest.length())
  let (userinfo, hostport) = match authority.rev_find("@") {
    Some(at) => (Some(authority.unsafe_substring(start=0, end=at)), authority.unsafe_substring(start=at + 1, end=authority.length()))
    None => (None, authority)
  }
  let (username, password) = match userinfo {
    None => ("", "")
    Some(u) =>
      match u.find(":") {
        Some(c) =>
          (
            @url.percent_encode(u.unsafe_substring(start=0, end=c), userinfo_keep_pct),
            @url.percent_encode(u.unsafe_substring(start=c + 1, end=u.length()), userinfo_keep_pct),
          )
        None => (@url.percent_encode(u, userinfo_keep_pct), "")
      }
  }
  // host and port: a colon outside brackets
  let mut colon = -1
  let mut inside = false
  for p in 0..<hostport.length() {
    let c = hostport.unsafe_charcode_at(p)
    if c == '[' {
      inside = true
    } else if c == ']' {
      inside = false
    } else if c == ':' && !inside {
      colon = p
      break
    }
  }
  let (raw_host, raw_port) = if colon >= 0 {
    (hostport.unsafe_substring(start=0, end=colon), Some(hostport.unsafe_substring(start=colon + 1, end=hostport.length())))
  } else {
    (hostport, None)
  }
  let host = if special {
    match special_host(raw_host) {
      Some(h) => h
      None => return None
    }
  } else {
    @url.percent_encode(raw_host, c => c > 0x20 && c < 0x7f && !(c is ('#' | '/' | '<' | '>' | '?' | '@' | '[' | '\\' | ']' | '^' | '|')))
  }
  let port = match raw_port {
    None | Some("") => None
    Some(p) => {
      let mut v = 0
      for q in 0..<p.length() {
        let c = p.unsafe_charcode_at(q)
        if c < '0' || c > '9' {
          return None
        }
        v = v * 10 + (c - '0')
        if v > 65535 {
          return None
        }
      }
      if default_port(scheme) == Some(v) {
        None
      } else {
        Some(v)
      }
    }
  }
  // the path and the query
  let (path_part, query) = match after.find("?") {
    Some(q) => (after.unsafe_substring(start=0, end=q), Some(after.unsafe_substring(start=q + 1, end=after.length())))
    None => (after, None)
  }
  let path_part = match path_part.find("#") {
    Some(h) => path_part.unsafe_substring(start=0, end=h)
    None => path_part
  }
  let query = query.map(q => match q.find("#") {
    Some(h) => q.unsafe_substring(start=0, end=h)
    None => q
  })
  let path = if special {
    let p = String::from_array(path_part.iter().map(c => if c == '\\' { '/' } else { c }).collect())
    if p == "" {
      "/"
    } else {
      @url.percent_encode(p, path_keep_pct)
    }
  } else {
    @url.percent_encode(path_part, path_keep_pct)
  }
  Some({
    scheme,
    username,
    password,
    host,
    port,
    path,
    query: query.map(q => @url.percent_encode(q, query_keep_pct(special))),
    opaque: false,
  })
}

///|
/// A percent sign stays as it is: what was percent-encoded already is not encoded again.
fn userinfo_keep_pct(v : Int) -> Bool {
  v == '%' || userinfo_keep(v)
}

///|
fn path_keep_pct(v : Int) -> Bool {
  v == '%' || path_keep(v)
}

///|
fn query_keep_pct(special : Bool) -> (Int) -> Bool {
  let keep = query_keep(special)
  v => v == '%' || keep(v)
}

///|
/// `url.host`: its host, and its port where it is not the scheme's own.
fn Url::host_port(self : Url) -> String {
  match self.port {
    Some(p) => "\{self.host}:\{p}"
    None => self.host
  }
}

///|
fn Url::to_string(self : Url) -> String {
  if self.opaque {
    return "\{self.scheme}:\{self.path}" +
      (match self.query {
        Some(q) => "?" + q
        None => ""
      })
  }
  let creds = if self.username != "" || self.password != "" {
    self.username + (if self.password != "" { ":" + self.password } else { "" }) + "@"
  } else {
    ""
  }
  "\{self.scheme}://\{creds}\{self.host_port()}\{self.path}" +
  (match self.query {
    Some(q) => "?" + q
    None => ""
  })
}

///|
/// `url.protocol = scheme + ":"`, as the setter takes it (a special scheme for a special one only).
fn Url::with_scheme(self : Url, scheme : String) -> Url {
  if is_special(self.scheme) != is_special(scheme) || self.opaque {
    return self
  }
  if self.scheme == "file" && self.host == "" {
    return self
  }
  let port = match self.port {
    Some(p) if default_port(scheme) == Some(p) => None
    p => p
  }
  { ..self, scheme, port }
}

///|
/// The line Comma's still.fail plugin shows, `comma <server> <token>`, as its server (an https or http origin, also when
/// the line names the socket's `wss://` or `ws://`) and token; None when it is not one.
pub fn comma_line(line : String) -> (String, String)? {
  let words = @jscase.split_by(js_trim(line), @jscase.is_space)
  if words.length() != 3 || words[0] != "comma" {
    return None
  }
  let server = words[1]
  let token = words[2]
  let url = match parse_url(server) {
    Some(u) => u
    None => return None
  }
  // Comma shows its connector's address, which may be the socket's (`wss://…`, as its production does): kept as the
  // https one, which the connection is made of either way.
  let scheme = match url.scheme {
    "https" | "wss" => "https:"
    "http" | "ws" => "http:"
    _ => return None
  }
  if token.length() < 8 || token.length() > 512 {
    return None
  }
  for i in 0..<token.length() {
    let c = token.unsafe_charcode_at(i)
    if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-') {
      return None
    }
  }
  Some(("\{scheme}//\{url.host_port()}", token))
}

///|
/// Comma's address for its connector socket: `server` (https or http) as a WebSocket address, with who dials and the
/// still.fail workspace the connect is of (Comma takes one connect of a workspace in a Group: its usage counted once).
pub fn connect_url(server : String, name : String, workspace : String?, os : String, arch : String) -> String raise {
  // server.replace(/\/+$/, "") + "/"
  let mut end = server.length()
  while end > 0 && server.unsafe_charcode_at(end - 1) == '/' {
    end -= 1
  }
  let base = match parse_url(server.unsafe_substring(start=0, end~) + "/") {
    Some(b) if !b.opaque => b
    _ => raise Thrown("TypeError", "Invalid URL")
  }
  let url = { ..base, path: "/v1/connect", query: None }
  let url = url.with_scheme(if url.scheme == "http" { "ws" } else { "wss" })
  let params = [("name", name)]
  match workspace {
    Some(w) => params.push(("stillfail_workspace", w))
    None => ()
  }
  params.push(("os", os))
  params.push(("arch", arch))
  let query = params
    .map(p => @url.percent_encode(p.0, form_keep, space_plus=true) + "=" + @url.percent_encode(p.1, form_keep, space_plus=true))
    .join("&")
  { ..url, query: Some(query) }.to_string()
}

///|
/// A token as the pages are shown it.
pub fn mask_token(s : String) -> String {
  if s.length() <= 4 {
    if s == "" {
      ""
    } else {
      "••••"
    }
  } else {
    "••••" + s.unsafe_substring(start=s.length() - 4, end=s.length())
  }
}
