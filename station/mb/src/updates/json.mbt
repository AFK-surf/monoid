// JSON as the TypeScript of station/src/updates holds it (`@jsjson`: JSON.parse and JSON.stringify's own, an object's
// keys in the order they were set), and the string functions of JavaScript it is written with (by UTF-16 units, as
// MoonBit's strings are).

///|
pub type J = @jsjson.JValue

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
pub fn jo(pairs : Array[(String, J)]) -> J {
  @jsjson.JValue::of_object(pairs)
}

///|
pub fn ja(items : Array[J]) -> J {
  @jsjson.JValue::of_array(items)
}

///|
pub fn jstrs(items : Array[String]) -> J {
  @jsjson.JValue::of_strings(items)
}

///|
/// A string or none as JSON (null where none).
fn jopt(s : String?) -> J {
  @jsjson.JValue::of_opt_string(s)
}

///|
/// `o[k]` where `o` is an object.
pub fn get(o : J?, k : String) -> J? {
  @jsjson.jval_at(o, k)
}

///|
pub fn text(j : J?) -> String? {
  @jsjson.jval_str_of(j)
}

///|
pub fn num(j : J?) -> Double? {
  @jsjson.jval_num_of(j)
}

///|
pub fn keys_of(o : J) -> Array[String] {
  @jsjson.jval_keys_of(o)
}

///|
/// `o[k] = v` on a copy: in its place where `o` has it, else last.
pub fn set(o : J, k : String, v : J) -> J {
  @jsjson.jval_set_or_new(o, k, v)
}

///|
/// `delete o[k]` on a copy.
pub fn del(o : J, k : String) -> J {
  @jsjson.jval_del(o, k)
}

///|
/// `{ ...a, ...b }`.
pub fn spread(a : J, b : J) -> J {
  @jsjson.jval_spread(a, b)
}

///|
pub fn stringify(j : J) -> String {
  @jsjson.stringify(j)
}

///|
pub fn parse(s : String) -> J raise {
  @jsjson.parse(s)
}

///|
/// `JSON.stringify(a) === JSON.stringify(b)`.
pub fn same(a : J, b : J) -> Bool {
  stringify(a) == stringify(b)
}

///|
/// A number as JavaScript's `String(n)` says it.
pub fn num_text(d : Double) -> String {
  stringify(Num(d))
}

///|
fn cu(s : String, i : Int) -> Int {
  s.code_unit_at(i).to_int()
}

///|
/// `s.slice(start, end)` (by UTF-16 units), negative counted from the end, clamped.
pub fn slice(s : String, start : Int, end? : Int) -> String {
  let n = s.length()
  let norm = (i : Int) => if i < 0 { if n + i < 0 { 0 } else { n + i } } else if i > n { n } else { i }
  let a = norm(start)
  let b = norm(end.unwrap_or(n))
  if a >= b {
    ""
  } else {
    s.unsafe_substring(start=a, end=b)
  }
}

///|
/// `s.indexOf(sub)` (-1: none).
pub fn index_of(s : String, sub : String) -> Int {
  match s.find(sub) {
    Some(i) => i
    None => -1
  }
}

///|
/// `s.lastIndexOf(sub)` (-1: none).
pub fn last_index_of(s : String, sub : String) -> Int {
  match s.rev_find(sub) {
    Some(i) => i
    None => -1
  }
}

///|
pub fn includes(s : String, sub : String) -> Bool {
  s.find(sub) is Some(_)
}

///|
pub fn starts_with(s : String, p : String) -> Bool {
  s.length() >= p.length() && slice(s, 0, end=p.length()) == p
}

///|
pub fn ends_with(s : String, p : String) -> Bool {
  s.length() >= p.length() && slice(s, s.length() - p.length()) == p
}

///|
/// `s.split(sep)` by a string (JavaScript's: "" splits into nothing but "", a separator at either end gives "").
pub fn split(s : String, sep : String) -> Array[String] {
  let out = []
  if sep == "" {
    for i in 0..<s.length() {
      out.push(slice(s, i, end=i + 1))
    }
    return out
  }
  let mut at = 0
  while true {
    match s.unsafe_substring(start=at, end=s.length()).find(sep) {
      Some(i) => {
        out.push(slice(s, at, end=at + i))
        at = at + i + sep.length()
      }
      None => {
        out.push(slice(s, at))
        break
      }
    }
  }
  out
}

///|
/// `s.split(re)` by a set of single units (a character class).
pub fn split_units(s : String, is_sep : (Int) -> Bool) -> Array[String] {
  let out = []
  let mut from = 0
  for i in 0..<s.length() {
    if is_sep(cu(s, i)) {
      out.push(slice(s, from, end=i))
      from = i + 1
    }
  }
  out.push(slice(s, from))
  out
}

///|
/// `s.split(a).join(b)`.
pub fn replace_all(s : String, a : String, b : String) -> String {
  split(s, a).join(b)
}

///|
/// `s.trim()`.
pub fn trim(s : String) -> String {
  @jscase.trim(s)
}

///|
/// `s.trimEnd()`.
pub fn trim_end(s : String) -> String {
  let mut e = s.length()
  while e > 0 && @jscase.is_space(cu(s, e - 1)) {
    e -= 1
  }
  slice(s, 0, end=e)
}

///|
fn is_digit(c : Int) -> Bool {
  c >= 48 && c <= 57
}

///|
/// `/^[0-9]+$/`.
pub fn all_digits(s : String) -> Bool {
  if s == "" {
    return false
  }
  for i in 0..<s.length() {
    if !is_digit(cu(s, i)) {
      return false
    }
  }
  true
}

///|
/// `/^[0-9a-f]{64}$/`.
pub fn is_sha(s : String) -> Bool {
  if s.length() != 64 {
    return false
  }
  for i in 0..<64 {
    let c = cu(s, i)
    if !(is_digit(c) || (c >= 97 && c <= 102)) {
      return false
    }
  }
  true
}

///|
/// JavaScript's `Number.isSafeInteger`.
pub fn is_safe_integer(j : J?) -> Bool {
  j is Some(Num(d)) && @jsjson.is_safe_integer(d)
}

///|
/// Lowercase hex of bytes.
pub fn hex(b : Bytes) -> String {
  @codec.hex_encode(b)
}

///|
fn hex_value(c : Int) -> Int {
  @codec.hex_digit(c).unwrap_or(-1)
}

///|
/// Bytes of hex (Node's `Buffer.from(hex, "hex")`: stops at the first pair that is not hex).
pub fn unhex(s : String) -> Bytes {
  let out = Buffer()
  let mut i = 0
  while i + 1 < s.length() {
    let a = hex_value(cu(s, i))
    let b = hex_value(cu(s, i + 1))
    if a < 0 || b < 0 {
      break
    }
    out.write_byte((a * 16 + b).to_byte())
    i += 2
  }
  out.to_bytes()
}

///|
/// Bytes of base64 as Node's `Buffer.from(s, "base64")` takes them: what is not of its alphabet (either one's, the URL's
/// too) skipped, stopping at `=`.
pub fn base64_bytes(s : String) -> Bytes {
  let digits = StringBuilder()
  let mut n = 0
  for i in 0..<s.length() {
    let c = cu(s, i)
    if c == 61 {
      break
    }
    if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c is (43 | 45 | 47 | 95) {
      digits.write_char(c.unsafe_to_char())
      n += 1
    }
  }
  let text = digits.to_string()
  // A lone digit past a group of four is six bits: no byte, as Node leaves it.
  let text = if n % 4 == 1 { text.view(end_offset=n - 1).to_string() } else { text }
  @codec.base64_decode(text).unwrap_or(b"")
}

///|
pub fn base64_of(b : Bytes) -> String {
  @base64.encode(b)
}

///|
/// Bytes as JSON the way the test and the world carry them: `{"$bytes": base64}`.
pub fn jbytes(b : Bytes) -> J {
  jo([("$bytes", js(base64_of(b)))])
}

///|
/// Bytes from `{"$bytes"}` (or a string's UTF-8).
pub fn bytes_of(j : J?) -> Bytes {
  match j {
    Some(Obj(_)) =>
      match text(get(j, "$bytes")) {
        Some(b) => base64_bytes(b)
        None => b""
      }
    Some(Str(u)) => @utf8.encode(@jsjson.text(u))
    _ => b""
  }
}

///|
/// UTF-8 decoded as Node's `toString("utf8")` does (what is not UTF-8 replaced).
pub fn utf8_text(b : Bytes) -> String {
  @jsjson.utf8_text(b)
}

///|
/// `Math.floor`.
pub fn floor(d : Double) -> Double {
  d.floor()
}

///|
/// `Math.round` (halves up).
pub fn js_round(d : Double) -> Double {
  (d + 0.5).floor()
}

///|
/// JavaScript's `Number(text)` of a decimal the caller already matched (`/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/`).
pub fn decimal(text : String) -> Double {
  @string.parse_double(text) catch {
    _ =>
      if starts_with(text, "+") {
        @string.parse_double(slice(text, 1)) catch {
          _ => @double.not_a_number
        }
      } else {
        @double.not_a_number
      }
  }
}
