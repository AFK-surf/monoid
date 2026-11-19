// Values as JavaScript has them (@jsjson.JValue: JSON.parse and JSON.stringify exactly), and what the Feishu code asks
// of them as the TypeScript did (`text(v)`, `v?.a?.b`, `String(v)`, `Number(s)`, `s.trim()`): an object's fields in
// JavaScript's order, a lone surrogate of a string kept.

///|
/// A JavaScript value as JSON has it. An object's fields are kept in a mutable array (what the TypeScript changed in
/// place, a kept file's maps, is changed in place here too).
#derive(Eq)
pub(all) enum JV {
  Null
  Bool(Bool)
  Num(Double)
  Str(String)
  Arr(Array[JV])
  /// keys and values, in the order they were put (integer-like keys are put first by `jset` and `jobj`)
  Obj(Array[(String, JV)])
}

///|
fn of_js(v : @jsjson.JValue) -> JV {
  match v {
    Null => Null
    Bool(b) => Bool(b)
    Num(n) => Num(n)
    Str(u) => Str(@jsjson.raw_text(u))
    Arr(a) => Arr(a.map(of_js))
    Obj(f) => Obj(f.map(p => (@jsjson.raw_text(p.0), of_js(p.1))))
  }
}

///|
fn to_js(v : JV) -> @jsjson.JValue {
  match v {
    Null => Null
    Bool(b) => Bool(b)
    Num(n) => Num(n)
    Str(s) => Str(@jsjson.units(s))
    Arr(a) => Arr(a.map(to_js))
    Obj(f) => Obj(f.map(p => (@jsjson.units(p.0), to_js(p.1))))
  }
}

///|
/// JSON.parse(text).
pub fn parse(text : String) -> JV raise @jsjson.SyntaxError {
  of_js(@jsjson.parse(text))
}

///|
/// JSON.parse, None where it throws.
pub fn try_parse(text : String) -> JV? {
  Some(parse(text)) catch {
    _ => None
  }
}

///|
/// JSON.stringify(v).
pub fn stringify(v : JV) -> String {
  @jsjson.stringify(to_js(v))
}

///|
/// What JSON is to the rest of the program (@json.Json: a harness's answer).
pub fn JV::to_json(self : JV) -> Json {
  @json.parse(stringify(self)) catch {
    _ => Json::null()
  }
}

///|
/// `@json.Json` as a JavaScript value (its fields in its order).
pub fn JV::from_json(j : Json) -> JV {
  match j {
    Null => Null
    True => Bool(true)
    False => Bool(false)
    Number(n, ..) => Num(n)
    String(s) => Str(s)
    Array(a) => Arr(a.map(JV::from_json))
    Object(m) => {
      let o = Obj([])
      for k, v in m {
        jput(o, k, JV::from_json(v))
      }
      o
    }
  }
}

///|
/// `v.k` of an object (undefined: None).
pub fn JV::get(self : JV, k : String) -> JV? {
  match self {
    Obj(fields) => {
      for f in fields {
        if f.0 == k {
          return Some(f.1)
        }
      }
      None
    }
    _ => None
  }
}

///|
/// `v?.k`: None where it is not an object or has no such field.
pub fn jget(v : JV?, k : String) -> JV? {
  match v {
    Some(Obj(_) as o) => o.get(k)
    _ => None
  }
}

///|
/// `v?.[i]` of an array.
pub fn jat(v : JV?, i : Int) -> JV? {
  match v {
    Some(Arr(a)) if i >= 0 && i < a.length() => Some(a[i])
    _ => None
  }
}

///|
pub fn js(s : String) -> JV {
  Str(s)
}

///|
pub fn jnum(n : Double) -> JV {
  Num(n)
}

///|
pub fn jint(n : Int) -> JV {
  Num(n.to_double())
}

///|
pub fn jopt(s : String?) -> JV {
  match s {
    Some(v) => Str(v)
    None => Null
  }
}

///|
/// A canonical array index (`0`, `12`, not `012`): what JavaScript puts first in an object, ascending.
fn index_key(k : String) -> Double? {
  if k.length() == 0 || k.length() > 10 {
    return None
  }
  if k.length() > 1 && k.unsafe_charcode_at(0) == '0' {
    return None
  }
  let mut n = 0.0
  for i in 0..<k.length() {
    let c = k.unsafe_charcode_at(i)
    if c < '0' || c > '9' {
      return None
    }
    n = n * 10.0 + (c - '0').to_double()
  }
  if n > 4294967294.0 {
    None
  } else {
    Some(n)
  }
}

///|
/// `o[k] = v` in place (an object's own array): where it was, else where JavaScript puts a new key.
pub fn jput(o : JV, k : String, v : JV) -> Unit {
  guard o is Obj(fields) else { return }
  for i in 0..<fields.length() {
    if fields[i].0 == k {
      fields[i] = (k, v)
      return
    }
  }
  match index_key(k) {
    Some(n) => {
      let mut at = 0
      while at < fields.length() {
        match index_key(fields[at].0) {
          Some(m) if m < n => at += 1
          _ => break
        }
      }
      fields.insert(at, (k, v))
    }
    None => fields.push((k, v))
  }
}

///|
/// `delete o[k]` in place.
pub fn jdelete(o : JV, k : String) -> Unit {
  guard o is Obj(fields) else { return }
  for i in 0..<fields.length() {
    if fields[i].0 == k {
      fields.remove(i) |> ignore
      return
    }
  }
}

///|
/// An object literal of these fields, in JavaScript's order (a field whose value is None, undefined, left out).
pub fn jobj(fields : Array[(String, JV?)]) -> JV {
  let o = Obj([])
  for f in fields {
    match f.1 {
      Some(v) => jput(o, f.0, v)
      None => ()
    }
  }
  o
}

///|
/// An object's keys as `Object.keys` gives them: integer-like ones first, ascending.
pub fn jkeys(v : JV) -> Array[String] {
  match v {
    Obj(f) => {
      let indexed = f.filter(e => index_key(e.0) is Some(_))
      indexed.sort_by((a, b) => index_key(a.0).unwrap().compare(index_key(b.0).unwrap()))
      (indexed + f.filter(e => index_key(e.0) is None)).map(e => e.0)
    }
    _ => []
  }
}

///|
/// `Object.values(v)` (of an object, an array, a string; nothing of anything else).
pub fn jvalues(v : JV) -> Array[JV] {
  match v {
    Obj(_) => jkeys(v).map(k => v.get(k).unwrap())
    Arr(a) => a
    Str(s) => {
      let out = []
      for i in 0..<s.length() {
        out.push(Str(s.unsafe_substring(start=i, end=i + 1)))
      }
      out
    }
    _ => []
  }
}

///|
/// `text(v)`: the string it is, else "".
pub fn text(v : JV?) -> String {
  match v {
    Some(Str(s)) => s
    _ => ""
  }
}

///|
/// The string it is, if it is one.
pub fn jstr(v : JV?) -> String? {
  match v {
    Some(Str(s)) => Some(s)
    _ => None
  }
}

///|
/// The number it is, if it is one.
pub fn jnumber(v : JV?) -> Double? {
  match v {
    Some(Num(n)) => Some(n)
    _ => None
  }
}

///|
/// `Array.isArray(v) ? v : []`.
pub fn jitems(v : JV?) -> Array[JV] {
  match v {
    Some(Arr(a)) => a
    _ => []
  }
}

///|
/// `v !== null && typeof v === "object" && !Array.isArray(v)`.
pub fn is_record(v : JV?) -> Bool {
  v is Some(Obj(_))
}

///|
/// `v ?? null`: undefined as null.
pub fn or_null(v : JV?) -> JV {
  v.unwrap_or(Null)
}

///|
/// `v ?? fallback`: what is neither undefined nor null, else the fallback.
pub fn nullish(v : JV?, fallback : JV) -> JV {
  match v {
    None | Some(Null) => fallback
    Some(x) => x
  }
}

///|
/// A number as JavaScript writes it (`String(n)`).
pub fn num_text(d : Double) -> String {
  if d.is_nan() {
    "NaN"
  } else if d.is_inf() {
    if d > 0.0 {
      "Infinity"
    } else {
      "-Infinity"
    }
  } else {
    @jsjson.stringify(Num(d))
  }
}

///|
/// `String(v)` of a value (undefined: None).
pub fn js_string(v : JV?) -> String {
  match v {
    None => "undefined"
    Some(Null) => "null"
    Some(Bool(b)) => if b { "true" } else { "false" }
    Some(Num(d)) => num_text(d)
    Some(Str(s)) => s
    Some(Arr(items)) =>
      items
      .map(x => match x {
        Null => ""
        _ => js_string(Some(x))
      })
      .join(",")
    Some(Obj(_)) => "[object Object]"
  }
}

///|
/// JavaScript's white space and line terminators (`String.prototype.trim`, a regular expression's `\s`).
pub fn is_js_space(c : Int) -> Bool {
  c == 0x09 ||
  c == 0x0a ||
  c == 0x0b ||
  c == 0x0c ||
  c == 0x0d ||
  c == 0x20 ||
  c == 0xa0 ||
  c == 0x1680 ||
  (c >= 0x2000 && c <= 0x200a) ||
  c == 0x2028 ||
  c == 0x2029 ||
  c == 0x202f ||
  c == 0x205f ||
  c == 0x3000 ||
  c == 0xfeff
}

///|
/// `s.trim()`.
pub fn trim_js(s : String) -> String {
  let mut a = 0
  let mut b = s.length()
  while a < b && is_js_space(s.unsafe_charcode_at(a)) {
    a += 1
  }
  while b > a && is_js_space(s.unsafe_charcode_at(b - 1)) {
    b -= 1
  }
  s.unsafe_substring(start=a, end=b)
}

///|
/// `s.trimEnd()`.
pub fn trim_end_js(s : String) -> String {
  let mut b = s.length()
  while b > 0 && is_js_space(s.unsafe_charcode_at(b - 1)) {
    b -= 1
  }
  s.unsafe_substring(start=0, end=b)
}

///|
/// `s.slice(a, b)` by code units, as JavaScript clamps it.
pub fn slice_js(s : String, a : Int, b? : Int = s.length()) -> String {
  let n = s.length()
  let from = if a < 0 { @cmp.maximum(0, n + a) } else { @cmp.minimum(a, n) }
  let to = if b < 0 { @cmp.maximum(0, n + b) } else { @cmp.minimum(b, n) }
  if to <= from {
    ""
  } else {
    s.unsafe_substring(start=from, end=to)
  }
}

///|
/// `a.split(sep).join(by)` (sep not empty): every occurrence, left to right.
pub fn replace_every(a : String, sep : String, by : String) -> String {
  if sep == "" {
    return a
  }
  let out = StringBuilder::new()
  let mut i = 0
  let n = a.length()
  let m = sep.length()
  while i < n {
    if i + m <= n && a.unsafe_substring(start=i, end=i + m) == sep {
      out.write_string(by)
      i += m
    } else {
      out.write_char(a.unsafe_charcode_at(i).unsafe_to_char())
      i += 1
    }
  }
  out.to_string()
}

///|
/// `s.startsWith(p)`.
pub fn starts(s : String, p : String) -> Bool {
  s.length() >= p.length() && s.unsafe_substring(start=0, end=p.length()) == p
}

///|
/// `s.includes(p)`.
pub fn has(s : String, p : String) -> Bool {
  if p == "" {
    return true
  }
  let n = s.length()
  let m = p.length()
  let mut i = 0
  while i + m <= n {
    if s.unsafe_substring(start=i, end=i + m) == p {
      return true
    }
    i += 1
  }
  false
}

///|
/// `[...s]`: its code points, each a string (a lone surrogate one of them).
pub fn points(s : String) -> Array[String] {
  let out = []
  let mut i = 0
  while i < s.length() {
    let c = s.unsafe_charcode_at(i)
    let w = if c >= 0xd800 && c <= 0xdbff && i + 1 < s.length() {
      let d = s.unsafe_charcode_at(i + 1)
      if d >= 0xdc00 && d <= 0xdfff {
        2
      } else {
        1
      }
    } else {
      1
    }
    out.push(s.unsafe_substring(start=i, end=i + w))
    i += w
  }
  out
}

///|
/// Number(s) as JavaScript reads a string (white space trimmed, "" is 0, hex/octal/binary, Infinity; else NaN).
pub fn js_number(s : String) -> Double {
  let t = trim_js(s)
  if t == "" {
    return 0.0
  }
  if t == "Infinity" || t == "+Infinity" {
    return @double.infinity
  }
  if t == "-Infinity" {
    return @double.neg_infinity
  }
  if t.length() > 2 && t.unsafe_charcode_at(0) == '0' {
    let base = match t.unsafe_charcode_at(1) {
      'x' | 'X' => 16
      'o' | 'O' => 8
      'b' | 'B' => 2
      _ => 0
    }
    if base > 0 {
      let mut n = 0.0
      for i in 2..<t.length() {
        let c = t.unsafe_charcode_at(i)
        let d = if c >= '0' && c <= '9' {
          c - '0'
        } else if c >= 'a' && c <= 'z' {
          c - 'a' + 10
        } else if c >= 'A' && c <= 'Z' {
          c - 'A' + 10
        } else {
          99
        }
        if d >= base {
          return @double.not_a_number
        }
        n = n * base.to_double() + d.to_double()
      }
      return n
    }
  }
  // a decimal: [+-] digits [. digits] [e [+-] digits]
  let mut i = 0
  if t.unsafe_charcode_at(0) == '+' || t.unsafe_charcode_at(0) == '-' {
    i = 1
  }
  let mut seen = false
  while i < t.length() &&
        t.unsafe_charcode_at(i) >= '0' &&
        t.unsafe_charcode_at(i) <= '9' {
    i += 1
    seen = true
  }
  if i < t.length() && t.unsafe_charcode_at(i) == '.' {
    i += 1
    while i < t.length() &&
          t.unsafe_charcode_at(i) >= '0' &&
          t.unsafe_charcode_at(i) <= '9' {
      i += 1
      seen = true
    }
  }
  if !seen {
    return @double.not_a_number
  }
  if i < t.length() &&
    (t.unsafe_charcode_at(i) == 'e' || t.unsafe_charcode_at(i) == 'E') {
    let mut j = i + 1
    if j < t.length() &&
      (t.unsafe_charcode_at(j) == '+' || t.unsafe_charcode_at(j) == '-') {
      j += 1
    }
    let from = j
    while j < t.length() &&
          t.unsafe_charcode_at(j) >= '0' &&
          t.unsafe_charcode_at(j) <= '9' {
      j += 1
    }
    if j == from {
      return @double.not_a_number
    }
    i = j
  }
  if i != t.length() {
    return @double.not_a_number
  }
  // JSON's reader reads the same decimal text exactly (a leading + and a bare `.5` or `5.` aside)
  let mut body = t
  let neg = body.unsafe_charcode_at(0) == '-'
  if body.unsafe_charcode_at(0) == '+' || neg {
    body = body.unsafe_substring(start=1, end=body.length())
  }
  if body.unsafe_charcode_at(0) == '.' {
    body = "0" + body
  }
  body = body.replace_all(old=".e", new=".0e").replace_all(old=".E", new=".0E")
  if body.has_suffix(".") {
    body = body + "0"
  }
  // (leading zeros JSON refuses: "007" is 7)
  let mut z = 0
  while z + 1 < body.length() &&
        body.unsafe_charcode_at(z) == '0' &&
        body.unsafe_charcode_at(z + 1) >= '0' &&
        body.unsafe_charcode_at(z + 1) <= '9' {
    z += 1
  }
  body = body.unsafe_substring(start=z, end=body.length())
  let v = match try_parse(body) {
    Some(Num(n)) => n
    _ => @double.not_a_number
  }
  if neg {
    -v
  } else {
    v
  }
}

///|
/// Number.isFinite.
pub fn is_finite(d : Double) -> Bool {
  !d.is_nan() && !d.is_inf()
}

///|
/// Math.round: half way up, toward +∞.
pub fn js_round(d : Double) -> Double {
  if !is_finite(d) {
    return d
  }
  let f = d.floor()
  if d - f >= 0.5 {
    f + 1.0
  } else {
    f
  }
}

///|
/// A number as an Int64 the way a whole one is (the harness's).
pub fn whole(d : Double) -> Int64 {
  if d.is_nan() {
    0L
  } else {
    d.to_int64()
  }
}

///|
/// encodeURIComponent: every code unit but `A-Za-z0-9-_.!~*'()` as its UTF-8 percent-encoded (a lone surrogate is a
/// URIError, as JavaScript throws).
pub fn encode_uri_component(s : String) -> String raise FeishuError {
  let out = StringBuilder::new()
  let hex = "0123456789ABCDEF"
  let mut i = 0
  while i < s.length() {
    let c = s.unsafe_charcode_at(i)
    if (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c is ('-' | '_' | '.' | '!' | '~' | '*' | '\'' | '(' | ')') {
      out.write_char(c.unsafe_to_char())
      i += 1
      continue
    }
    let mut cp = c
    if c >= 0xd800 && c <= 0xdbff {
      if i + 1 < s.length() &&
        s.unsafe_charcode_at(i + 1) >= 0xdc00 &&
        s.unsafe_charcode_at(i + 1) <= 0xdfff {
        cp = 0x10000 + ((c - 0xd800) << 10) + (s.unsafe_charcode_at(i + 1) - 0xdc00)
        i += 1
      } else {
        raise FeishuError("URI malformed")
      }
    } else if c >= 0xdc00 && c <= 0xdfff {
      raise FeishuError("URI malformed")
    }
    i += 1
    for b in utf8_of_point(cp) {
      out.write_char('%')
      out.write_char(hex.unsafe_charcode_at(b >> 4).unsafe_to_char())
      out.write_char(hex.unsafe_charcode_at(b & 15).unsafe_to_char())
    }
  }
  out.to_string()
}

///|
/// A code point's UTF-8 bytes.
fn utf8_of_point(cp : Int) -> Array[Int] {
  if cp < 0x80 {
    [cp]
  } else if cp < 0x800 {
    [0xc0 | (cp >> 6), 0x80 | (cp & 0x3f)]
  } else if cp < 0x10000 {
    [0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f)]
  } else {
    [
      0xf0 | (cp >> 18),
      0x80 | ((cp >> 12) & 0x3f),
      0x80 | ((cp >> 6) & 0x3f),
      0x80 | (cp & 0x3f),
    ]
  }
}

///|
/// TextEncoder's UTF-8 (`Buffer.from(s)` too): a lone surrogate as U+FFFD.
pub fn utf8(s : String) -> Bytes {
  let out = []
  let mut i = 0
  while i < s.length() {
    let c = s.unsafe_charcode_at(i)
    let mut cp = c
    if c >= 0xd800 && c <= 0xdbff {
      if i + 1 < s.length() &&
        s.unsafe_charcode_at(i + 1) >= 0xdc00 &&
        s.unsafe_charcode_at(i + 1) <= 0xdfff {
        cp = 0x10000 + ((c - 0xd800) << 10) + (s.unsafe_charcode_at(i + 1) - 0xdc00)
        i += 1
      } else {
        cp = 0xfffd
      }
    } else if c >= 0xdc00 && c <= 0xdfff {
      cp = 0xfffd
    }
    i += 1
    for b in utf8_of_point(cp) {
      out.push(b.to_byte())
    }
  }
  Bytes::from_array(out)
}

///|
/// UTF-8 as WHATWG's decoder reads it (TextDecoder, Buffer's toString): each ill-formed sequence's maximal part one
/// U+FFFD. `bom`: a leading byte order mark taken off (TextDecoder's default; Buffer keeps it).
pub fn utf8_text(b : BytesView, bom? : Bool = false) -> String {
  let out = StringBuilder::new()
  let n = b.length()
  let mut i = 0
  if bom && n >= 3 && b[0] == b'\xEF' && b[1] == b'\xBB' && b[2] == b'\xBF' {
    i = 3
  }
  while i < n {
    let c = b[i].to_int()
    if c < 0x80 {
      out.write_char(c.unsafe_to_char())
      i += 1
      continue
    }
    let (need, init, lo, hi) = if c >= 0xc2 && c <= 0xdf {
      (1, c & 0x1f, 0x80, 0xbf)
    } else if c == 0xe0 {
      (2, c & 0x0f, 0xa0, 0xbf)
    } else if c == 0xed {
      (2, c & 0x0f, 0x80, 0x9f)
    } else if c >= 0xe1 && c <= 0xef {
      (2, c & 0x0f, 0x80, 0xbf)
    } else if c == 0xf0 {
      (3, c & 0x07, 0x90, 0xbf)
    } else if c == 0xf4 {
      (3, c & 0x07, 0x80, 0x8f)
    } else if c >= 0xf1 && c <= 0xf3 {
      (3, c & 0x07, 0x80, 0xbf)
    } else {
      (0, 0, 0, 0)
    }
    if need == 0 {
      out.write_char('\u{fffd}')
      i += 1
      continue
    }
    let mut cp = init
    let mut j = i + 1
    let mut ok = true
    let mut first = true
    for _ in 0..<need {
      if j >= n {
        ok = false
        break
      }
      let d = b[j].to_int()
      let (l, h) = if first { (lo, hi) } else { (0x80, 0xbf) }
      if d < l || d > h {
        ok = false
        break
      }
      first = false
      cp = (cp << 6) | (d & 0x3f)
      j += 1
    }
    if ok {
      out.write_char(cp.unsafe_to_char())
    } else {
      out.write_char('\u{fffd}')
    }
    i = j
  }
  out.to_string()
}

///|
/// A Feishu call or step that failed: its words, as the TypeScript's Error said them.
pub(all) suberror FeishuError {
  FeishuError(String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for FeishuError with output(self, logger) {
  match self {
    FeishuError(m) => logger.write_string(m)
  }
}

///|
/// An error's words (`(error as Error).message`).
pub fn error_words(e : Error) -> String {
  match e {
    FeishuError(m) => m
    ApiError(m, _) => m
    @jsjson.SyntaxError(m) => m
    _ => {
      let s = e.to_string()
      s
    }
  }
}
