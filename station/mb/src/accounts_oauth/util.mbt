// What the TypeScript these files replace took from JavaScript itself, done as it does: JSON read with `?.` and
// `typeof`, `String(v)`, `JSON.stringify` (by station/jsjson), UTF-16 units and code points, `path.join` (by
// station/nodepath), a form's encoding (URLSearchParams), a query's parameters, base64url as Buffer reads it.

///|
using @jsjson {
  js_includes as includes, js_split as split, js_split_lines as split_lines, points, json_at as get,
  json_str_of as str_of, json_num_of as num_of, json_nullish as nullish, json_opt_str as opt,
  json_int64 as jnum, json_strs as jstrings, json_strings_of as strings_of, jval_stringify_num as js_number,
  json_js_str as js_string, json_stringify as stringify, json_stringify_pretty as stringify_pretty,
  json_same_opt as same_json, js_round,
}

///|
using @jscase {is_space, trim, trim_start, lower}

///|
fn utf8_of(s : String) -> Bytes {
  @utf8.encode(s)
}

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
  @jsjson.js_index_of(s, part, from=start)
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
/// `s.split(/\s+/)`.
fn split_space(s : String) -> Array[String] {
  @jscase.split_by(s, @jscase.is_space)
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
/// A string that is not empty (`typeof v === "string" && v !== ""`).
fn text_of(j : Json?) -> String? {
  match j {
    Some(String(s)) if s != "" => Some(s)
    _ => None
  }
}

///|
/// `Number.isInteger(v)`.
fn is_integer(j : Json?) -> Bool {
  j is Some(Number(n, ..)) && @jsjson.is_integer(n)
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
/// `JSON.parse(text)`, which fails as SyntaxError.
fn parse_json(text : String) -> Json raise JsonError {
  @jsjson.parse(text).to_json_lossy() catch {
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

// ---- paths ----

///|
/// Node's `path.join` on POSIX.
pub fn join(parts : Array[String]) -> String {
  @nodepath.join("/", parts)
}

// ---- forms, queries, base64url ----

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
  @url.percent_decode_lossy(s, plus_space=true)
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
  @utf8.decode_lossy(@codec.base64_decode_loose(text))
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
  out.sort_by((a, b) => @jsjson.js_compare(a, b))
  out
}
