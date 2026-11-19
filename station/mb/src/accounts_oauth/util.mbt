// What the TypeScript these files replace took from JavaScript itself, done as it does: JSON read with `?.` and
// `typeof`, `String(v)`, `JSON.stringify` (by station/jsjson), UTF-16 units and code points, `path.join` (by
// station/nodepath), a form's encoding (URLSearchParams), a query's parameters, base64url as Buffer reads it.

///|
fn sub(s : String, start : Int, end : Int) -> String {
  let a = if start < 0 { 0 } else if start > s.length() { s.length() } else { start }
  let b = if end < a { a } else if end > s.length() { s.length() } else { end }
  s.unsafe_substring(start=a, end=b)
}

///|
fn from(s : String, start : Int) -> String {
  sub(s, start, s.length())
}

///|
/// `s.indexOf(part, start)`: -1 where it is not.
fn index_of(s : String, part : String, start? : Int = 0) -> Int {
  let n = s.length()
  let m = part.length()
  let mut i = if start < 0 { 0 } else { start }
  while i + m <= n {
    let mut j = 0
    while j < m && s.unsafe_charcode_at(i + j) == part.unsafe_charcode_at(j) {
      j += 1
    }
    if j == m {
      return i
    }
    i += 1
  }
  -1
}

///|
fn includes(s : String, part : String) -> Bool {
  index_of(s, part) >= 0
}

///|
/// `s.split(sep)` with a plain separator (an empty one splits each unit).
fn split(s : String, sep : String) -> Array[String] {
  let out = []
  if sep == "" {
    for i in 0..<s.length() {
      out.push(sub(s, i, i + 1))
    }
    return out
  }
  let mut at = 0
  while true {
    let i = index_of(s, sep, start=at)
    if i < 0 {
      out.push(from(s, at))
      break
    }
    out.push(sub(s, at, i))
    at = i + sep.length()
  }
  out
}

///|
/// `s.split(/\r?\n/)`.
fn split_lines(s : String) -> Array[String] {
  split(s, "\n").map(l => if l.has_suffix("\r") { sub(l, 0, l.length() - 1) } else { l })
}

///|
/// The code points of `s` (`[...s]`), each as a string of its units.
fn points(s : String) -> Array[String] {
  let out = []
  let n = s.length()
  let mut i = 0
  while i < n {
    let c = s.unsafe_charcode_at(i)
    if c >= 0xD800 && c <= 0xDBFF && i + 1 < n {
      let d = s.unsafe_charcode_at(i + 1)
      if d >= 0xDC00 && d <= 0xDFFF {
        out.push(sub(s, i, i + 2))
        i += 2
        continue
      }
    }
    out.push(sub(s, i, i + 1))
    i += 1
  }
  out
}

///|
/// The last `most` code points of `s`.
fn last_points(s : String, most : Int) -> String {
  let p = points(s)
  if p.length() <= most {
    return s
  }
  p[p.length() - most:].to_owned().join("")
}

///|
fn is_space(c : Int) -> Bool {
  @jscase.is_space(c)
}

///|
fn trim(s : String) -> String {
  @jscase.trim(s)
}

///|
fn trim_start(s : String) -> String {
  let mut i = 0
  while i < s.length() && is_space(s.unsafe_charcode_at(i)) {
    i += 1
  }
  from(s, i)
}

///|
fn lower(s : String) -> String {
  @jscase.lower(s)
}

///|
/// `s.split(/\s+/)`.
fn split_space(s : String) -> Array[String] {
  let out = []
  let mut word = StringBuilder()
  let mut i = 0
  let mut pending = true
  while i < s.length() {
    let c = s.unsafe_charcode_at(i)
    if is_space(c) {
      // a run of white space is one separator
      out.push(word.to_string())
      word = StringBuilder()
      while i < s.length() && is_space(s.unsafe_charcode_at(i)) {
        i += 1
      }
      pending = true
      continue
    }
    word.write_char(c.unsafe_to_char())
    pending = false
    i += 1
  }
  ignore(pending)
  out.push(word.to_string())
  out
}

///|
fn is_ascii_digit(c : Int) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn is_ascii_alpha(c : Int) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

///|
/// The first unit of `s` upper-cased as `toUpperCase` makes it (for the letters a plan's name is spelt in).
fn upper_first(s : String) -> String {
  if s == "" {
    return ""
  }
  let c = s.unsafe_charcode_at(0)
  let up = if c >= 'a' && c <= 'z' {
    c - 32
  } else if (c >= 0xE0 && c <= 0xFE && c != 0xF7) {
    c - 32
  } else {
    c
  }
  up.unsafe_to_char().to_string() + from(s, 1)
}

// ---- JSON as JavaScript reads it ----

///|
/// `j?.[k]`.
fn get(j : Json?, k : String) -> Json? {
  match j {
    Some(Object(m)) => m.get(k)
    _ => None
  }
}

///|
fn str_of(j : Json?) -> String? {
  match j {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// A string that is not empty (`typeof v === "string" && v !== ""`).
fn text_of(j : Json?) -> String? {
  match j {
    Some(String(s)) if s != "" => Some(s)
    _ => None
  }
}

///|
fn num_of(j : Json?) -> Double? {
  match j {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
/// `Number.isInteger(v)`.
fn is_integer(j : Json?) -> Bool {
  match j {
    Some(Number(n, ..)) => !n.is_nan() && !n.is_inf() && n.floor() == n
    _ => false
  }
}

///|
/// `v === null || v === undefined`.
fn nullish(j : Json?) -> Bool {
  match j {
    None | Some(Null) => true
    _ => false
  }
}

///|
/// `a ?? b`.
fn either(a : Json?, b : Json?) -> Json? {
  if nullish(a) {
    b
  } else {
    a
  }
}

///|
fn opt(s : String?) -> Json {
  match s {
    Some(t) => Json::string(t)
    None => Json::null()
  }
}

///|
fn jnum(n : Int64) -> Json {
  Json::number(n.to_double())
}

///|
fn jstrings(a : Array[String]) -> Json {
  Json::array(a.map(Json::string))
}

///|
fn strings_of(j : Json?) -> Array[String] {
  match j {
    Some(Array(a)) =>
      a.filter_map(v => match v {
        String(s) => Some(s)
        _ => None
      })
    _ => []
  }
}

///|
/// A number as `String(n)` says it.
fn js_number(n : Double) -> String {
  @jsjson.stringify(@jsjson.JValue::Num(n))
}

///|
/// `String(v)` (`None`: undefined).
fn js_string(j : Json?) -> String {
  match j {
    None => "undefined"
    Some(Null) => "null"
    Some(True) => "true"
    Some(False) => "false"
    Some(Number(n, ..)) => js_number(n)
    Some(String(s)) => s
    Some(Array(a)) =>
      a
      .map(v => match v {
        Null => ""
        v => js_string(Some(v))
      })
      .join(",")
    Some(Object(_)) => "[object Object]"
  }
}

///|
fn to_jvalue(j : Json) -> @jsjson.JValue {
  match j {
    Null => Null
    True => Bool(true)
    False => Bool(false)
    Number(n, ..) => Num(n)
    String(s) => Str(@jsjson.units(s))
    Array(a) => Arr(a.map(to_jvalue))
    Object(m) => {
      // as JavaScript keeps an object's keys: those like array indices first, in their order
      let index : Array[(Array[Int], @jsjson.JValue)] = []
      let rest : Array[(Array[Int], @jsjson.JValue)] = []
      for k, v in m {
        if array_index(k) is Some(_) {
          index.push((@jsjson.units(k), to_jvalue(v)))
        } else {
          rest.push((@jsjson.units(k), to_jvalue(v)))
        }
      }
      index.sort_by((a, b) => array_index(@jsjson.text(a.0))
        .unwrap_or(0L)
        .compare(array_index(@jsjson.text(b.0)).unwrap_or(0L)))
      Obj(index + rest)
    }
  }
}

///|
fn array_index(k : String) -> Int64? {
  if k == "" || k.length() > 10 {
    return None
  }
  if k.length() > 1 && k.unsafe_charcode_at(0) == '0' {
    return None
  }
  let mut n = 0L
  for i in 0..<k.length() {
    let c = k.unsafe_charcode_at(i)
    if !is_ascii_digit(c) {
      return None
    }
    n = n * 10L + (c - '0').to_int64()
  }
  if n >= 4294967295L {
    None
  } else {
    Some(n)
  }
}

///|
/// `JSON.stringify(v)`.
fn stringify(j : Json) -> String {
  @jsjson.stringify(to_jvalue(j))
}

///|
/// `JSON.stringify(v, null, 2)`.
fn stringify_pretty(j : Json) -> String {
  @jsjson.stringify_indent(to_jvalue(j), 2)
}

///|
fn from_jvalue(v : @jsjson.JValue) -> Json {
  match v {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Num(n) => Json::number(n)
    Str(u) => Json::string(@jsjson.text(u))
    Arr(a) => Json::array(a.map(from_jvalue))
    Obj(kv) => {
      let m : Map[String, Json] = Map([])
      for p in kv {
        m[@jsjson.text(p.0)] = from_jvalue(p.1)
      }
      Json::object(m)
    }
  }
}

///|
/// `JSON.parse(text)`, which fails as SyntaxError.
fn parse_json(text : String) -> Json raise JsonError {
  from_jvalue(@jsjson.parse(text)) catch {
    e => raise JsonError(e.to_string())
  }
}

///|
/// What `JSON.parse` failed with.
pub(all) suberror JsonError {
  JsonError(String)
}

///|
pub impl Show for JsonError with output(self, logger) {
  match self {
    JsonError(m) => logger.write_string(m)
  }
}

///|
fn parse_or_none(text : String) -> Json? {
  try Some(parse_json(text)) catch {
    _ => None
  }
}

///|
/// `JSON.stringify(a) === JSON.stringify(b)` (undefined: `None`).
fn same_json(a : Json?, b : Json?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => stringify(x) == stringify(y)
    _ => false
  }
}

// ---- paths ----

///|
/// Node's `path.join` on POSIX.
pub fn join(parts : Array[String]) -> String {
  @nodepath.join("/", parts)
}

// ---- forms, queries, base64url ----

///|
fn utf8_of(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
/// A form as `new URLSearchParams(form).toString()` writes it.
pub fn form_encoded(form : Array[(String, String)]) -> String {
  let keep = (c : Int) => is_ascii_alpha(c) || is_ascii_digit(c) || c == '*' || c == '-' || c == '.' || c == '_'
  let out = StringBuilder()
  for i, p in form {
    if i > 0 {
      out.write_char('&')
    }
    out.write_string(@url.percent_encode(p.0, keep, space_plus=true))
    out.write_char('=')
    out.write_string(@url.percent_encode(p.1, keep, space_plus=true))
  }
  out.to_string()
}

///|
/// A form's piece decoded as URLSearchParams does: `+` a space, `%XX` a byte, the bytes read as UTF-8.
fn form_decoded(s : String) -> String {
  let bytes = Array::new()
  let units = utf8_of(s)
  let n = units.length()
  let mut i = 0
  while i < n {
    let c = units[i].to_int()
    if c == '+' {
      bytes.push(b' ')
    } else if c == '%' && i + 2 < n && @codec.hex_digit(units[i + 1].to_int()) is Some(h) && @codec.hex_digit(units[i + 2].to_int()) is Some(l) {
      bytes.push((h * 16 + l).to_byte())
      i += 3
      continue
    } else {
      bytes.push(units[i])
    }
    i += 1
  }
  @utf8.decode_lossy(Bytes::from_array(bytes))
}

///|
/// A query's parameters in order (`url.searchParams`), its `?` left off.
fn params_of(query : String) -> Array[(String, String)] {
  let out = []
  for piece in split(query, "&") {
    if piece == "" {
      continue
    }
    let at = index_of(piece, "=")
    if at < 0 {
      out.push((form_decoded(piece), ""))
    } else {
      out.push((form_decoded(sub(piece, 0, at)), form_decoded(from(piece, at + 1))))
    }
  }
  out
}

///|
/// `url.searchParams.get(name)`.
fn param(query : String?, name : String) -> String? {
  match query {
    None => None
    Some(q) => {
      for p in params_of(q) {
        if p.0 == name {
          return Some(p.1)
        }
      }
      None
    }
  }
}

///|
/// `Buffer.from(text, "base64url").toString("utf8")`: what is not of base64's alphabets let go, read up to its first `=`.
fn base64url_text(text : String) -> String {
  let bytes = Array::new()
  let mut acc = 0
  let mut bits = 0
  for i in 0..<text.length() {
    let c = text.unsafe_charcode_at(i)
    let v = if c >= 'A' && c <= 'Z' {
      c - 'A'
    } else if c >= 'a' && c <= 'z' {
      c - 'a' + 26
    } else if c >= '0' && c <= '9' {
      c - '0' + 52
    } else if c == '-' || c == '+' {
      62
    } else if c == '_' || c == '/' {
      63
    } else if c == '=' {
      break
    } else {
      continue
    }
    acc = (acc << 6) | v
    bits += 6
    if bits >= 8 {
      bits -= 8
      bytes.push(((acc >> bits) & 255).to_byte())
    }
  }
  @utf8.decode_lossy(Bytes::from_array(bytes))
}

///|
/// The bytes of `s` as UTF-8, in hex (`Buffer.from(s).toString("hex")`).
fn hex_utf8(s : String) -> String {
  @codec.hex_encode(utf8_of(s))
}

///|
/// Strings sorted by their UTF-16 units (`a < b`).
fn sort_units(list : Array[String]) -> Array[String] {
  let out = list.copy()
  out.sort_by((a, b) => {
    let n = if a.length() < b.length() { a.length() } else { b.length() }
    for i in 0..<n {
      let x = a.unsafe_charcode_at(i)
      let y = b.unsafe_charcode_at(i)
      if x != y {
        return x.compare(y)
      }
    }
    a.length().compare(b.length())
  })
  out
}

///|
/// `Math.round(x)`.
fn js_round(x : Double) -> Double {
  (x + 0.5).floor()
}
