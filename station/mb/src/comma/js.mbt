// JSON as the TypeScript this is written from reads and writes it (station/mb's jsjson: JSON.parse, JSON.stringify,
// strings as UTF-16 code units, an object's keys in the order they were put), and the few ways the comma code reads a
// value that may be anything (`v?.[key]`, `typeof v === "string"`, `Number.isSafeInteger`, `String(v)`). `undefined`
// is None where a value may be absent.

///|
using @jsjson {type JValue as J}

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
/// An object of the fields given, those None (undefined) left out as JSON.stringify leaves them.
pub fn jo(fields : Array[(String, J?)]) -> J {
  let out = []
  for f in fields {
    match f.1 {
      Some(v) => out.push((@jsjson.units(f.0), v))
      None => ()
    }
  }
  Obj(out)
}

///|
/// An object of the fields given, every one there.
pub fn jobj(fields : Array[(String, J)]) -> J {
  @jsjson.JValue::of_object(fields)
}

///|
/// The text of a string's code units, lone surrogates kept as a JavaScript string keeps them.
pub fn utext(u : Array[Int]) -> String {
  @jsjson.raw_text(u)
}

///|
/// A JavaScript string as a value.
pub fn jstr(s : String) -> J {
  @jsjson.JValue::of_string(s)
}

///|
/// `v?.[key]`: a property of what may be anything; None where it is undefined.
pub fn prop(v : J?, key : String) -> J? {
  match v {
    Some(Obj(entries)) => {
      let k = @jsjson.units(key)
      for e in entries {
        if e.0 == k {
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
          Some(i) if i < u.length() => Some(Str([u[i]]))
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
/// `typeof v === "string"`: its text.
pub fn str_of(v : J?) -> String? {
  match v {
    Some(Str(u)) => Some(utext(u))
    _ => None
  }
}

///|
/// `typeof v === "number"`: its value.
pub fn num_of(v : J?) -> Double? {
  @jsjson.jval_num_of(v)
}

///|
/// `Array.isArray(v)`: its items.
pub fn arr_of(v : J?) -> Array[J]? {
  @jsjson.jval_arr_of(v)
}

///|
/// `v !== null && typeof v === "object"` (an array too).
pub fn is_object(v : J?) -> Bool {
  v is Some(Obj(_) | Arr(_))
}

///|
/// `v ?? null`: undefined as null.
pub fn or_null(v : J?) -> J {
  v.unwrap_or(Null)
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
/// `Number.isSafeInteger(v)`.
pub fn safe_int(v : J?) -> Bool {
  @jsjson.jval_safe_int(v)
}

///|
/// `String(v)`, as code units.
pub fn js_string(v : J) -> Array[Int] {
  @jsjson.js_string(v)
}

///|
/// `String(v)` as text.
pub fn js_text(v : J) -> String {
  utext(@jsjson.js_string(v))
}

///|
/// A number as `String(n)` says it.
pub fn num_text(n : Double) -> String {
  js_text(Num(n))
}

///|
/// Two strings as JavaScript compares them, by their code units: negative, zero or positive.
pub fn units_cmp(a : String, b : String) -> Int {
  @jsjson.js_compare(a, b)
}

///|
/// `s.trim()`.
pub fn js_trim(s : String) -> String {
  @jscase.trim(s)
}

///|
/// The code points of a string as `[...s]` (or `Array.from(s)`) makes them: a lone surrogate one of its own.
pub fn points(s : String) -> Array[String] {
  @jsjson.points(s)
}

///|
/// The first `max` code points of `s` (`[...s].slice(0, max).join("")`).
pub fn first_points(s : String, max : Int) -> String {
  @jsjson.chars(s, max)
}

///|
/// A string as node writes it to UTF-8 (a lone surrogate as U+FFFD).
pub fn utf8_of(s : String) -> Bytes {
  @utf8.encode(@jsjson.text(@jsjson.units(s)))
}

///|
/// Bytes as node reads them as UTF-8 (`Buffer.toString("utf8")`).
pub fn text_of_utf8(b : Bytes) -> String {
  @utf8.decode_lossy(b)
}

///|
/// What JSON.parse makes of `text`.
pub fn parse_json(text : String) -> J raise @jsjson.SyntaxError {
  @jsjson.parse(text)
}

///|
/// JSON.stringify of a value.
pub fn stringify(v : J) -> String {
  @jsjson.stringify(v)
}

///|
/// `Buffer.byteLength(text)`.
pub fn byte_length(text : String) -> Int {
  utf8_of(text).length()
}

///|
/// The value as the moonbitlang JSON SQLite binds and reads (its strings well-formed).
pub fn to_json(v : J) -> Json {
  v.to_json_lossy()
}

///|
/// A moonbitlang JSON value as one of these.
pub fn from_json(v : Json) -> J {
  @jsjson.JValue::of_json(v)
}

///|
/// A text parameter as node binds a string: a lone surrogate as U+FFFD.
pub fn bind_text(s : String) -> Json {
  Json::string(@jsjson.text(@jsjson.units(s)))
}

///|
/// A number parameter.
pub fn bind_num(n : Double) -> Json {
  Json::number(n)
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
/// Hex of bytes, lowercase.
pub fn hex(b : Bytes) -> String {
  @codec.hex_encode(b)
}

///|
/// `createHash("sha256").update(bytes).digest("hex")`.
pub fn sha256_hex(b : Bytes) -> String {
  @memory.sha256_hex(b[:])
}

///|
/// `Number(text)` of a decimal integer as the station writes one (meta's values); NaN for anything else.
pub fn js_number(text : String) -> Double {
  let t = js_trim(text)
  if t == "" {
    return 0.0
  }
  let mut neg = false
  let mut i = 0
  if t.unsafe_charcode_at(0) == '-' || t.unsafe_charcode_at(0) == '+' {
    neg = t.unsafe_charcode_at(0) == '-'
    i = 1
  }
  if i >= t.length() {
    return @double.not_a_number
  }
  let mut v = 0.0
  let mut frac = 0.0
  let mut scale = 1.0
  let mut dot = false
  let mut digits = 0
  while i < t.length() {
    let c = t.unsafe_charcode_at(i)
    if c >= '0' && c <= '9' {
      digits += 1
      if dot {
        scale = scale / 10.0
        frac = frac + (c - '0').to_double() * scale
      } else {
        v = v * 10.0 + (c - '0').to_double()
      }
    } else if c == '.' && !dot {
      dot = true
    } else {
      return @double.not_a_number
    }
    i += 1
  }
  if digits == 0 {
    return @double.not_a_number
  }
  let r = v + frac
  if neg {
    -r
  } else {
    r
  }
}
