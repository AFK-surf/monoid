// JSON as the TypeScript of station/src/updates holds it (`@jsjson`: JSON.parse and JSON.stringify's own, an object's
// keys in the order they were set), and the string functions of JavaScript it is written with (by UTF-16 units, as
// MoonBit's strings are).

///|
pub type J = @jsjson.JValue

///|
pub using @jsjson {
  jval_str as js, jval_num as jn, jval_int as ji, jval_bool as jb, jval_obj as jo, jval_array as ja,
  jval_strs as jstrs, jval_at as get, jval_str_of as text, jval_num_of as num, jval_keys_of as keys_of,
  jval_set_or_new as set, jval_del as del, jval_spread as spread, stringify, parse,
  jval_stringify_num as num_text, js_slice as slice, js_last_index_of as last_index_of, js_includes as includes,
  js_starts as starts_with, js_ends as ends_with, js_split as split, js_replace_all as replace_all,
  js_all_digits as all_digits, jval_safe_int as is_safe_integer, utf8_text, js_round,
}

///|
using @jsjson {jval_opt_str as jopt}

///|
pub using @jscase {trim, trim_end}

///|
pub using @codec {hex_encode as hex, base64_decode_loose as base64_bytes}

///|
/// `JSON.stringify(a) === JSON.stringify(b)`.
pub fn same(a : J, b : J) -> Bool {
  stringify(a) == stringify(b)
}

///|
fn cu(s : String, i : Int) -> Int {
  s.code_unit_at(i).to_int()
}

///|
/// `s.indexOf(sub)` (-1: none).
pub fn index_of(s : String, sub : String) -> Int {
  @jsjson.js_index_of(s, sub)
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
fn is_digit(c : Int) -> Bool {
  c >= 48 && c <= 57
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
    Some(Str(u)) => @utf8.encode(@jsjson.sanitize_str(u))
    _ => b""
  }
}

///|
/// `Math.floor`.
pub fn floor(d : Double) -> Double {
  d.floor()
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
