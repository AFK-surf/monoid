// What this package reads and makes of JSON as the TypeScript it is moved from does: a value's `String()`, a field
// that is undefined (absent) or null, JavaScript's `trim`, its counting of characters (code points) and its JSON text.

///|
/// `String(value)` as args.ts `jsString` has it: a string as it is, null as "null", anything else its JSON.
pub fn js_string(value : Json) -> String {
  match value {
    String(s) => s
    Null => "null"
    _ => js_json(value)
  }
}

///|
/// JSON.stringify of a value read from JSON (a number as JavaScript writes it).
pub fn js_json(value : Json) -> String {
  match value {
    Number(n, ..) => js_number_text(n)
    Array(items) => "[" + items.map(js_json).join(",") + "]"
    Object(map) => {
      let parts = []
      for k, v in map {
        parts.push(Json::string(k).stringify() + ":" + js_json(v))
      }
      "{" + parts.join(",") + "}"
    }
    _ => value.stringify()
  }
}

///|
/// A number as JavaScript writes it (`String(n)`): integers without a point, NaN and the infinities by name.
pub fn js_number_text(n : Double) -> String {
  if n.is_nan() {
    return "NaN"
  }
  if n.is_inf() {
    return if n > 0.0 { "Infinity" } else { "-Infinity" }
  }
  if n == n.floor() && n.abs() < 1.0e21 {
    if n == 0.0 {
      return "0"
    }
    return n.to_int64().to_string()
  }
  Json::number(n).stringify()
}

///|
/// A field of an object, None where it is not there (undefined).
pub fn field(o : Json, name : String) -> Json? {
  match o {
    Object(map) => map.get(name)
    _ => None
  }
}

///|
/// A string field, None where it is not a string.
pub fn str_of(o : Json, name : String) -> String? {
  match field(o, name) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// A number field, None where it is not a number.
pub fn num_of(o : Json, name : String) -> Double? {
  match field(o, name) {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
/// A field that is a string or null (`string | null`, undefined as null).
pub fn text_or_null(o : Json, name : String) -> String? {
  str_of(o, name)
}

///|
/// Whether a field is `true`.
pub fn is_true(o : Json, name : String) -> Bool {
  field(o, name) is Some(True)
}

///|
/// Whether a value is a JSON object (not an array, not null).
pub fn is_object(v : Json) -> Bool {
  v is Object(_)
}

///|
/// The items of an array, none for anything else.
pub fn items(v : Json?) -> Array[Json] {
  match v {
    Some(Array(a)) => a
    _ => []
  }
}

///|
/// JavaScript's `trim`.
pub fn trim(s : String) -> String {
  @jscase.trim(s)
}

///|
/// How many characters (code points) a string has, as `Array.from(s).length`.
pub fn chars(s : String) -> Int {
  let mut n = 0
  for _ in s {
    n += 1
  }
  n
}

///|
/// Its first `n` characters (code points), as `Array.from(s).slice(0, n).join("")`.
pub fn take(s : String, n : Int) -> String {
  let b = StringBuilder()
  let mut i = 0
  for c in s {
    if i >= n {
      break
    }
    b.write_char(c)
    i += 1
  }
  b.to_string()
}

///|
/// `s.slice(from, to)` by UTF-16 units.
pub fn slice(s : String, from : Int, to? : Int = s.length()) -> String {
  let len = s.length()
  let a = if from < 0 { @cmp.maximum(len + from, 0) } else { @cmp.minimum(from, len) }
  let b = if to < 0 { @cmp.maximum(len + to, 0) } else { @cmp.minimum(to, len) }
  if a >= b {
    ""
  } else {
    s.unsafe_substring(start=a, end=b)
  }
}

///|
/// `s.indexOf(what, from)` by UTF-16 units (-1: none).
pub fn index_of(s : String, what : String, from? : Int = 0) -> Int {
  let n = s.length()
  let m = what.length()
  let mut i = @cmp.maximum(from, 0)
  while i + m <= n {
    let mut j = 0
    while j < m && u(s, i + j) == u(what, j) {
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
/// `s.split(sep)` (a non-empty separator).
pub fn split(s : String, sep : String) -> Array[String] {
  let out = []
  let mut at = 0
  while true {
    let i = index_of(s, sep, from=at)
    if i < 0 {
      out.push(slice(s, at))
      break
    }
    out.push(slice(s, at, to=i))
    at = i + sep.length()
  }
  out
}

///|
/// `s.replaceAll(what, with)` (a non-empty `what`).
pub fn replace_all(s : String, what : String, with_ : String) -> String {
  split(s, what).join(with_)
}

///|
/// A string or null as JSON.
pub fn opt_str(s : String?) -> Json {
  match s {
    Some(t) => Json::string(t)
    None => Json::null()
  }
}

///|
/// A number as JSON.
pub fn num(n : Double) -> Json {
  Json::number(n)
}

///|
/// An Int as JSON.
pub fn int(n : Int) -> Json {
  Json::number(n.to_double())
}

///|
/// `a === b` for two JSON values read alike (deep for what JSON compares by value: used of strings, numbers, null).
pub fn same(a : Json?, b : Json?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => x == y
    _ => false
  }
}

///|
/// The UTF-16 unit at `i`, as an Int.
pub fn u(s : String, i : Int) -> Int {
  s.code_unit_at(i).to_int()
}
