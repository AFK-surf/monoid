// JSON as station/src/browser reads and writes it (`any` in TypeScript): jsjson's values (JSON.parse and JSON.stringify,
// an object's keys in the order they were put), and the few ways the TypeScript reads one: `typeof v === "string"`, a
// field of what may be anything (`v?.k`), `String(v)`, `Number(v)`, `{ ...a, ...b }`.

///|
using @jsjson {type JValue as J}

///|
pub fn js(s : String) -> J {
  @jsjson.JValue::of_string(s)
}

///|
pub fn jn(d : Double) -> J {
  @jsjson.JValue::of_double(d)
}

///|
pub fn ji(i : Int) -> J {
  @jsjson.JValue::of_int(i)
}

///|
pub fn jb(b : Bool) -> J {
  @jsjson.JValue::of_bool(b)
}

///|
pub fn jo(fields : Array[(String, J)]) -> J {
  @jsjson.JValue::of_object(fields)
}

///|
pub fn ja(items : Array[J]) -> J {
  @jsjson.JValue::of_array(items)
}

///|
fn jsa(items : Array[String]) -> J {
  @jsjson.JValue::of_strings(items)
}

///|
fn jopt(s : String?) -> J {
  @jsjson.JValue::of_opt_string(s)
}

///|
/// `v?.[name]`: undefined (None) where `v` is no object or has none (the last of a name given twice, as JSON.parse
/// keeps it).
pub fn at(v : J?, name : String) -> J? {
  @jsjson.jval_at_last(v, name)
}

///|
/// `v?.[a]?.[b]…`.
fn at_path(v : J?, path : Array[String]) -> J? {
  @jsjson.jval_at_path_last(v, path)
}

///|
fn at_i(v : J?, i : Int) -> J? {
  @jsjson.jval_at_i(v, i)
}

///|
pub fn str_of(v : J?) -> String? {
  @jsjson.jval_str_of(v)
}

///|
/// `typeof v === "string" ? v : ""`.
fn text(v : J?) -> String {
  @jsjson.jval_text(v)
}

///|
fn num_of(v : J?) -> Double? {
  @jsjson.jval_num_of(v)
}

///|
fn bool_of(v : J?) -> Bool? {
  @jsjson.jval_bool_of(v)
}

///|
fn arr(v : J?) -> Array[J] {
  @jsjson.jval_arr(v)
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
  @jsjson.jval_nullish(v)
}

///|
fn truthy(v : J?) -> Bool {
  @jsjson.jval_truthy(v)
}

///|
/// `v === true`.
fn is_true(v : J?) -> Bool {
  @jsjson.jval_is_true(v)
}

///|
/// `String(v)`, `undefined` as "undefined".
pub fn js_str(v : J?) -> String {
  @jsjson.jval_js_str(v)
}

///|
/// A number as `String(n)` says it.
pub fn num_text(n : J) -> String {
  match n {
    Num(d) => @jsjson.num_text(d)
    _ => @jsjson.stringify(n)
  }
}

///|
/// A double as `String(n)` says it.
pub fn dnum(d : Double) -> String {
  @jsjson.num_text(d)
}

///|
/// `Number(v)`.
fn js_num(v : J?) -> Double {
  @jsjson.jval_js_num(v)
}

///|
/// `Number.isInteger(v)`.
fn is_integer(v : J?) -> Bool {
  @jsjson.jval_is_integer(v)
}

///|
/// `Number.isSafeInteger(v)`.
fn is_safe_integer(v : J?) -> Bool {
  @jsjson.jval_safe_int(v)
}

///|
/// `o[k] = v` (in its place where it is there, at its end where not); anything but an object stays as it is.
fn put(o : J, k : String, v : J) -> J {
  @jsjson.jval_set(o, k, v)
}

///|
/// `{ ...a, ...b }` of two objects (what is not one spreads nothing).
fn spread(a : J, b : J) -> J {
  @jsjson.jval_spread(a, b)
}

///|
/// `delete o[k]`.
fn drop_key(o : J, k : String) -> J {
  @jsjson.jval_del(o, k)
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
  @jsjson.js_slice(s, a, end?=b)
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
  @jsjson.js_index_of(s, t, from~)
}

///|
/// `s.lastIndexOf(t)`.
fn last_index_of(s : String, t : String) -> Int {
  @jsjson.js_last_index_of(s, t)
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
  @jsjson.utf8(s)
}

///|
/// `Buffer.toString("utf8")`.
pub fn from_utf8(b : Bytes) -> String {
  @jsjson.utf8_text(b)
}

///|
/// A number of milliseconds as a JSON number.
fn jms(d : Double) -> J {
  @jsjson.JValue::of_double(d)
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
