// JSON as the TypeScript this is written from reads and writes it (station/mb's jsjson: JSON.parse, JSON.stringify,
// strings as UTF-16 code units, an object's keys in the order they were put), and the few ways the comma code reads a
// value that may be anything (`v?.[key]`, `typeof v === "string"`, `Number.isSafeInteger`, `String(v)`). `undefined`
// is None where a value may be absent.

///|
using @jsjson {type JValue as J}

///|
pub using @jsjson {
  jval_str as js, jval_num as jn, jval_int as ji, jval_obj as jobj, raw_text as utext,
  jval_str_raw_of as str_of, jval_num_of as num_of, jval_arr_of as arr_of, jval_is_obj as is_object,
  jval_or_null as or_null, jval_safe_int as safe_int, js_string, jval_js_str_raw as js_text,
  js_compare as units_cmp, points, chars as first_points, parse as parse_json, stringify,
  js_utf8_len as byte_length, jval_to_json_lossy as to_json, jval_of_json as from_json, json_num as bind_num,
}

///|
pub using @jsjson {jval_str as jstr}

///|
pub using @jscase {trim as js_trim}

///|
pub using @utf8 {decode_lossy as text_of_utf8}

///|
pub using @codec {hex_encode as hex}

///|
/// What the TypeScript threw: its kind where a caller tells kinds apart (`instanceof MessageWriteBusy`; "" for a
/// plain Error) and its message as it says it.
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
/// A plain Error of `message`.
pub fn fail_(message : String) -> Thrown {
  Thrown("", message)
}

///|
/// What an error says, as `(error as Error).message` reads it.
pub fn message_of(e : Error) -> String {
  match e {
    Thrown(_, m) => m
    Failure(m) => m
    @wire.ShellError(m) => m
    @jsjson.SyntaxError(m) => m
    e => e.to_string()
  }
}

///|
/// Of which kind an error is, as a caller tells them apart ("" for a plain Error).
pub fn kind_of(e : Error) -> String {
  match e {
    Thrown(k, _) => k
    _ => ""
  }
}

///|
/// An object of the fields given, those None (undefined) left out as JSON.stringify leaves them.
pub fn jo(fields : Array[(String, J?)]) -> J {
  let out = []
  for f in fields {
    match f.1 {
      Some(v) => out.push((f.0, v))
      None => ()
    }
  }
  Obj(out)
}

///|
/// `v?.[key]`: a property of what may be anything; None where it is undefined.
pub fn prop(v : J?, key : String) -> J? {
  match v {
    Some(Obj(entries)) => {
      for e in entries {
        if e.0 == key {
          return Some(e.1)
        }
      }
      None
    }
    Some(Arr(items)) =>
      if key == "length" {
        Some(Num(items.length().to_double()))
      } else {
        match index_key(key) {
          Some(i) if i < items.length() => Some(items[i])
          _ => None
        }
      }
    Some(Str(u)) =>
      if key == "length" {
        Some(Num(u.length().to_double()))
      } else {
        match index_key(key) {
          Some(i) if i < u.length() => Some(Str(u.unsafe_substring(start=i, end=i + 1)))
          _ => None
        }
      }
    _ => None
  }
}

///|
/// An array index's number, as a property key names one.
fn index_key(key : String) -> Int? {
  if key.length() == 0 || key.length() > 9 || (key.length() > 1 && key.unsafe_charcode_at(0) == '0') {
    return None
  }
  let mut v = 0
  for i in 0..<key.length() {
    let c = key.unsafe_charcode_at(i)
    if c < '0' || c > '9' {
      return None
    }
    v = v * 10 + (c - '0')
  }
  Some(v)
}

///|
/// `a ?? b`: a where it is neither null nor undefined.
pub fn nullish(a : J?, b : J?) -> J? {
  match a {
    Some(Null) | None => b
    v => v
  }
}

///|
/// A number as `String(n)` says it.
pub fn num_text(n : Double) -> String {
  js_text(Num(n))
}

///|
/// A string as node writes it to UTF-8 (a lone surrogate as U+FFFD).
pub fn utf8_of(s : String) -> Bytes {
  @utf8.encode(@jsjson.sanitize_str(s))
}

///|
/// A text parameter as node binds a string: a lone surrogate as U+FFFD.
pub fn bind_text(s : String) -> Json {
  Json::string(@jsjson.sanitize_str(s))
}

///|
/// An integer column's value (a number SQLite gave).
pub fn col_num(row : Map[String, Json], name : String) -> Double? {
  match row.get(name) {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
/// A text column as node reads it: its text up to a NUL, which node's reader stops at.
pub fn col_text(row : Map[String, Json], name : String) -> String? {
  match row.get(name) {
    Some(String(s)) =>
      match s.find("\u{0}") {
        Some(i) => Some(s.unsafe_substring(start=0, end=i))
        None => Some(s)
      }
    _ => None
  }
}

///|
/// A blob column's bytes.
pub fn col_bytes(row : Map[String, Json], name : String) -> Bytes? {
  match row.get(name) {
    Some(Array(items)) =>
      Some(
        Bytes::from_array(
          FixedArray::makei(items.length(), i => match items[i] {
            Number(b, ..) => b.to_int().to_byte()
            _ => b'\x00'
          }),
        ),
      )
    _ => None
  }
}

///|
/// A blob parameter.
pub fn bind_bytes(b : Bytes) -> Json {
  Json::array(b.to_array().map(x => Json::number(x.to_int().to_double())))
}

///|
/// A column read as `JSON.parse(row.json)` reads it: text as text, a blob as `String(uint8array)` (its bytes joined by
/// commas), a number as its digits.
pub fn col_json_text(row : Map[String, Json], name : String) -> String {
  match row.get(name) {
    Some(Array(items)) =>
      items
      .map(x => match x {
        Number(b, ..) => b.to_int().to_string()
        _ => "0"
      })
      .join(",")
    Some(Number(n, ..)) => num_text(n)
    Some(Null) | None => "null"
    _ => col_text(row, name).unwrap_or("")
  }
}

///|
/// `createHash("sha256").update(bytes).digest("hex")`.
pub fn sha256_hex(b : Bytes) -> String {
  @memory.sha256_hex(b[:])
}

///|
/// `Number(text)` of a decimal integer as the station writes one (meta's values); NaN for anything else.
pub fn js_number(text : String) -> Double {
  @jsjson.js_number(text)
}
