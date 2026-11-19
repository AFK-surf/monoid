// JSON as station/src/browser reads and writes it (`any` in TypeScript): jsjson's values (JSON.parse and JSON.stringify,
// an object's keys in the order they were put), and the few ways the TypeScript reads one: `typeof v === "string"`, a
// field of what may be anything (`v?.k`), `String(v)`, `Number(v)`, `{ ...a, ...b }`.

///|
using @jsjson {type JValue as J}

///|
pub fn js(s : String) -> J {
  Str(@jsjson.units(s))
}

///|
pub fn jn(d : Double) -> J {
  Num(d)
}

///|
pub fn ji(i : Int) -> J {
  Num(i.to_double())
}

///|
pub fn jb(b : Bool) -> J {
  Bool(b)
}

///|
pub fn jo(fields : Array[(String, J)]) -> J {
  Obj(fields.map(f => (@jsjson.units(f.0), f.1)))
}

///|
pub fn ja(items : Array[J]) -> J {
  Arr(items)
}

///|
fn jsa(items : Array[String]) -> J {
  Arr(items.map(js))
}

///|
fn jopt(s : String?) -> J {
  match s {
    Some(t) => js(t)
    None => Null
  }
}

///|
/// `v?.[name]`: undefined (None) where `v` is no object or has none (the last of a name given twice, as JSON.parse
/// keeps it).
pub fn at(v : J?, name : String) -> J? {
  match v {
    Some(Obj(fs)) => {
      let ku = @jsjson.units(name)
      let mut found = None
      for f in fs {
        if f.0 == ku {
          found = Some(f.1)
        }
      }
      found
    }
    _ => None
  }
}

///|
/// `v?.[a]?.[b]…`.
fn at_path(v : J?, path : Array[String]) -> J? {
  let mut cur = v
  for k in path {
    cur = at(cur, k)
  }
  cur
}

///|
fn at_i(v : J?, i : Int) -> J? {
  match v {
    Some(Arr(xs)) => if i >= 0 && i < xs.length() { Some(xs[i]) } else { None }
    _ => None
  }
}

///|
pub fn str_of(v : J?) -> String? {
  match v {
    Some(Str(u)) => Some(@jsjson.text(u))
    _ => None
  }
}

///|
/// `typeof v === "string" ? v : ""`.
fn text(v : J?) -> String {
  str_of(v).unwrap_or("")
}

///|
fn num_of(v : J?) -> Double? {
  match v {
    Some(Num(d)) => Some(d)
    _ => None
  }
}

///|
fn bool_of(v : J?) -> Bool? {
  match v {
    Some(Bool(b)) => Some(b)
    _ => None
  }
}

///|
fn arr(v : J?) -> Array[J] {
  match v {
    Some(Arr(xs)) => xs
    _ => []
  }
}

///|
fn is_arr(v : J?) -> Bool {
  v is Some(Arr(_))
}

///|
/// `v !== null && typeof v === "object"` (an array too).
fn is_object(v : J?) -> Bool {
  v is Some(Obj(_) | Arr(_))
}

///|
/// `v == null`.
fn nullish(v : J?) -> Bool {
  match v {
    None | Some(Null) => true
    _ => false
  }
}

///|
fn truthy(v : J?) -> Bool {
  match v {
    None | Some(Null) | Some(Bool(false)) => false
    Some(Num(n)) => n != 0.0 && !n.is_nan()
    Some(Str(u)) => u.length() > 0
    Some(_) => true
  }
}

///|
/// `v === true`.
fn is_true(v : J?) -> Bool {
  v is Some(Bool(true))
}

///|
/// `String(v)`, `undefined` as "undefined".
pub fn js_str(v : J?) -> String {
  match v {
    None => "undefined"
    Some(Null) => "null"
    Some(Str(u)) => @jsjson.text(u)
    Some(Bool(b)) => if b { "true" } else { "false" }
    Some(Num(_) as n) => num_text(n)
    Some(Arr(xs)) =>
      xs
      .map(x => match x {
        Null => ""
        _ => js_str(Some(x))
      })
      .join(",")
    Some(Obj(_)) => "[object Object]"
  }
}

///|
/// A number as `String(n)` says it.
pub fn num_text(n : J) -> String {
  match n {
    Num(d) if d.is_nan() => "NaN"
    Num(d) if d == @double.infinity => "Infinity"
    Num(d) if d == -@double.infinity => "-Infinity"
    _ => @jsjson.stringify(n)
  }
}

///|
/// A double as `String(n)` says it.
pub fn dnum(d : Double) -> String {
  num_text(Num(d))
}

///|
/// `Number(v)`.
fn js_num(v : J?) -> Double {
  match v {
    None => @double.not_a_number
    Some(Null) => 0.0
    Some(Bool(b)) => if b { 1.0 } else { 0.0 }
    Some(Num(d)) => d
    Some(Str(u)) => {
      let t = @jscase.trim(@jsjson.text(u))
      if t == "" {
        0.0
      } else {
        @session_chats.js_number(js(t)).unwrap_or(@double.not_a_number)
      }
    }
    Some(Arr(xs)) =>
      match xs {
        [] => 0.0
        [x] => js_num(Some(Str(@jsjson.units(js_str(Some(x))))))
        _ => @double.not_a_number
      }
    Some(Obj(_)) => @double.not_a_number
  }
}

///|
/// `Number.isInteger(v)`.
fn is_integer(v : J?) -> Bool {
  match v {
    Some(Num(d)) => !d.is_nan() && !d.is_inf() && d.floor() == d
    _ => false
  }
}

///|
/// `Number.isSafeInteger(v)`.
fn is_safe_integer(v : J?) -> Bool {
  match v {
    Some(Num(d)) => is_integer(v) && d.abs() <= 9007199254740991.0
    _ => false
  }
}

///|
/// `o[k] = v` (in its place where it is there, at its end where not); anything but an object stays as it is.
fn put(o : J, k : String, v : J) -> J {
  match o {
    Obj(fs) => {
      let ku = @jsjson.units(k)
      let out = fs.copy()
      match out.search_by(f => f.0 == ku) {
        Some(i) => out[i] = (ku, v)
        None => out.push((ku, v))
      }
      Obj(out)
    }
    other => other
  }
}

///|
/// `{ ...a, ...b }` of two objects (what is not one spreads nothing).
fn spread(a : J, b : J) -> J {
  let mut out = match a {
    Obj(_) => a
    _ => Obj([])
  }
  match b {
    Obj(fs) => for f in fs {
      out = put(out, @jsjson.text(f.0), f.1)
    }
    _ => ()
  }
  out
}

///|
/// `delete o[k]`.
fn drop_key(o : J, k : String) -> J {
  match o {
    Obj(fs) => {
      let ku = @jsjson.units(k)
      Obj(fs.filter(f => f.0 != ku))
    }
    other => other
  }
}

///|
/// An object's own keys, in order (each once: JSON.parse keeps a name given twice where it came first).
fn keys_of(o : J) -> Array[String] {
  let out = []
  match o {
    Obj(fs) =>
      for f in fs {
        let k = @jsjson.text(f.0)
        if !out.contains(k) {
          out.push(k)
        }
      }
    _ => ()
  }
  out
}

///|
/// `Object.entries(o)` of a parsed object: its keys in order, each with its last value.
fn entries_of(o : J) -> Array[(String, J)] {
  keys_of(o).map(k => (k, at(Some(o), k).unwrap()))
}

///|
pub fn stringify(v : J) -> String {
  @jsjson.stringify(v)
}

///|
/// `JSON.stringify(v, null, 2)`.
fn stringify_pretty(v : J) -> String {
  @jsjson.stringify_indent(v, 2)
}

///|
/// `JSON.stringify(s)` of a string.
pub fn quote(s : String) -> String {
  stringify(js(s))
}

///|
/// What the TypeScript threw: its kind where a caller tells kinds apart, and its message.
pub(all) suberror Thrown {
  Thrown(String, String)
}

///|
pub impl Show for Thrown with output(self, logger) {
  match self {
    Thrown(_, m) => logger.write_string(m)
  }
}

///|
/// A screen refused as screens/hub.ts refuses one: its status and its words' key.
pub(all) suberror ScreenRefused {
  ScreenRefused(Int, String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for ScreenRefused with output(self, logger) {
  match self {
    ScreenRefused(_, key) => logger.write_string(key)
  }
}

///|
pub fn fail_(message : String) -> Thrown {
  Thrown("Error", message)
}

///|
/// `JSON.parse`, its SyntaxError said as a Thrown.
pub fn parse(t : String) -> J raise Thrown {
  @jsjson.parse(t) catch {
    @jsjson.SyntaxError(m) => raise Thrown("SyntaxError", m)
  }
}

///|
/// An error's message (`(error as Error).message`).
pub fn message_of(e : Error) -> String {
  match e {
    Thrown(_, m) => m
    ScreenRefused(_, k) => k
    Failure(m) => m
    e => e.to_string()
  }
}

///|
/// An error's kind, as the TypeScript's class would be told apart.
pub fn kind_of(e : Error) -> String {
  match e {
    Thrown(k, _) => k
    ScreenRefused(_, _) => "ScreenRefused"
    _ => "Error"
  }
}

///|
fn lower(s : String) -> String {
  @jscase.lower(s)
}

///|
fn trim(s : String) -> String {
  @jscase.trim(s)
}

///|
/// `s.toUpperCase()` of ASCII letters (what the key names here hold).
fn upper_ascii(s : String) -> String {
  let sb = StringBuilder::new()
  for c in s {
    if c >= 'a' && c <= 'z' {
      sb.write_char(Int::unsafe_to_char(c.to_int() - 32))
    } else {
      sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
fn is_ascii_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn is_ascii_alpha(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

///|
/// Whether every one of `s`'s letters is a digit (and there is one).
fn all_digits(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for c in s {
    if !is_ascii_digit(c) {
      return false
    }
  }
  true
}

///|
/// `s.slice(a, b)` by UTF-16 code units, clamped as JavaScript clamps it.
fn slice(s : String, a : Int, b? : Int) -> String {
  let n = s.length()
  let lo = if a < 0 { imax(0, n + a) } else { imin(a, n) }
  let hi = match b {
    None => n
    Some(e) => if e < 0 { imax(0, n + e) } else { imin(e, n) }
  }
  if hi <= lo {
    ""
  } else {
    s.unsafe_substring(start=lo, end=hi)
  }
}

///|
fn imax(a : Int, b : Int) -> Int {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn imin(a : Int, b : Int) -> Int {
  if a < b {
    a
  } else {
    b
  }
}

///|
/// `s.indexOf(t, from)`: -1 where it is not there.
fn index_of(s : String, t : String, from? : Int = 0) -> Int {
  let n = s.length()
  let m = t.length()
  let mut i = if from < 0 { 0 } else { from }
  while i + m <= n {
    let mut ok = true
    for j in 0..<m {
      if s.code_unit_at(i + j) != t.code_unit_at(j) {
        ok = false
        break
      }
    }
    if ok {
      return i
    }
    i += 1
  }
  -1
}

///|
/// `s.lastIndexOf(t)`.
fn last_index_of(s : String, t : String) -> Int {
  let n = s.length()
  let m = t.length()
  let mut i = n - m
  while i >= 0 {
    let mut ok = true
    for j in 0..<m {
      if s.code_unit_at(i + j) != t.code_unit_at(j) {
        ok = false
        break
      }
    }
    if ok {
      return i
    }
    i -= 1
  }
  -1
}

///|
/// The base64url of `b` (no padding: Buffer's `base64url`).
pub fn base64url(b : Bytes) -> String {
  let t = @base64.encode(b, padding=false)
  t.replace_all(old="+", new="-").replace_all(old="/", new="_")
}

///|
/// `Buffer.from(s, "base64url")` (either alphabet, padding or not; what is no letter of it skipped, as Node does).
pub fn from_base64url(s : String) -> Bytes {
  let vals = []
  for c in s {
    let v = if c >= 'A' && c <= 'Z' {
      c.to_int() - 'A'.to_int()
    } else if c >= 'a' && c <= 'z' {
      c.to_int() - 'a'.to_int() + 26
    } else if c >= '0' && c <= '9' {
      c.to_int() - '0'.to_int() + 52
    } else if c == '-' || c == '+' {
      62
    } else if c == '_' || c == '/' {
      63
    } else if c == '=' {
      break
    } else {
      -1
    }
    if v >= 0 {
      vals.push(v)
    }
  }
  let out = @buffer.new()
  let mut i = 0
  while i + 4 <= vals.length() {
    let n = (vals[i] << 18) | (vals[i + 1] << 12) | (vals[i + 2] << 6) | vals[i + 3]
    out.write_byte((n >> 16).to_byte())
    out.write_byte(((n >> 8) & 0xff).to_byte())
    out.write_byte((n & 0xff).to_byte())
    i += 4
  }
  let left = vals.length() - i
  if left == 2 {
    let n = (vals[i] << 18) | (vals[i + 1] << 12)
    out.write_byte((n >> 16).to_byte())
  } else if left == 3 {
    let n = (vals[i] << 18) | (vals[i + 1] << 12) | (vals[i + 2] << 6)
    out.write_byte((n >> 16).to_byte())
    out.write_byte(((n >> 8) & 0xff).to_byte())
  }
  out.to_bytes()
}

///|
/// UTF-8 bytes of `s` (a lone surrogate as U+FFFD, as Buffer.from does).
pub fn utf8(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
/// `Buffer.toString("utf8")`.
pub fn from_utf8(b : Bytes) -> String {
  @utf8.decode_lossy(b)
}

///|
/// A number of milliseconds as a JSON number.
fn jms(d : Double) -> J {
  Num(d)
}

///|
/// `v === s` of a string.
fn is_str(v : J?, s : String) -> Bool {
  match v {
    Some(Str(u)) => @jsjson.text(u) == s
    _ => false
  }
}

///|
/// What `JSON.parse(t)` makes where it is an object; None where it is not, or `t` is no JSON.
fn parse_obj(t : String) -> J? {
  match (try Some(parse(t)) catch { _ => None }) {
    Some(Obj(_) as o) => Some(o)
    _ => None
  }
}

///|
/// The separator a path goes by: `\` for a Windows path (a drive's `C:`, a share's `\\host`, or one written with `\`
/// alone), `/` otherwise (path.join's on the system it was made on).
pub fn sep_of(path : String) -> String {
  let drive = path.length() >= 2 &&
    is_ascii_alpha(Int::unsafe_to_char(path.unsafe_charcode_at(0))) &&
    path.unsafe_charcode_at(1) == ':'.to_int()
  if path.has_prefix("\\\\") || drive || (path.contains("\\") && !path.contains("/")) {
    "\\"
  } else {
    "/"
  }
}

///|
/// `path.join` of `parts` by the separator the first goes by.
pub fn pjoin(parts : Array[String]) -> String {
  @nodepath.join(sep_of(if parts.length() > 0 { parts[0] } else { "" }), parts)
}

///|
/// `path.dirname` by the separator the path goes by.
pub fn pdirname(path : String) -> String {
  @nodepath.dirname(sep_of(path), path)
}
