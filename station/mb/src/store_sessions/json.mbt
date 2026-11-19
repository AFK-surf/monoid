// Values as the TypeScript store reads and writes them: a row's columns (`col`), JavaScript's tests of them
// (`r.x === 1`, `typeof r.x === "string"`), and JSON as JavaScript writes it (JSON.stringify: `js`), so the text a
// statement is given is the station's byte for byte.

///|
fn col(r : Map[String, Json], k : String) -> Json {
  r.get(k).unwrap_or(Json::null())
}

///|
fn jstr(s : String) -> Json {
  Json::string(s)
}

///|
fn jbool(b : Bool) -> Json {
  Json::boolean(b)
}

///|
/// An integer as a statement's value, exactly.
fn jint(n : Int64) -> Json {
  if n > 9007199254740991L || n < -9007199254740991L {
    Json::number(n.to_double(), repr=n.to_string())
  } else {
    Json::number(n.to_double())
  }
}

///|
fn jnum(d : Double) -> Json {
  Json::number(d)
}

///|
fn flag(b : Bool) -> Json {
  Json::number(if b { 1.0 } else { 0.0 })
}

///|
/// store.ts `optFlag`: null or undefined as null, else 1 or 0 by JavaScript's truthiness of a boolean.
fn opt_flag(v : Json?) -> Json {
  match v {
    None | Some(Null) => Json::null()
    Some(v) => flag(truthy(v))
  }
}

///|
/// JavaScript's truthiness.
fn truthy(v : Json) -> Bool {
  match v {
    Null | False => false
    True => true
    Number(n, ..) => !(n == 0.0 || n.is_nan())
    String(s) => s != ""
    _ => true
  }
}

///|
fn str_of(v : Json) -> String? {
  match v {
    String(s) => Some(s)
    _ => None
  }
}

///|
fn num_of(v : Json) -> Double? {
  match v {
    Number(n, ..) => Some(n)
    _ => None
  }
}

///|
/// `v === n`.
fn is_n(v : Json, n : Double) -> Bool {
  v is Number(x, ..) && x == n
}

///|
/// `v ?? null` of an object's field (undefined when not there).
fn nullish(v : Json?) -> Json {
  match v {
    Some(v) => v
    None => Json::null()
  }
}

///|
/// `a ?? b`.
fn or_else(a : Json, b : Json) -> Json {
  if a is Null {
    b
  } else {
    a
  }
}

///|
fn opt_str(s : String?) -> Json {
  match s {
    Some(v) => Json::string(v)
    None => Json::null()
  }
}

///|
fn arr(v : Json) -> Array[Json] {
  match v {
    Array(a) => a
    _ => []
  }
}

///|
fn obj(v : Json) -> Map[String, Json] {
  match v {
    Object(o) => o
    _ => Map([])
  }
}

///|
/// A field of an object: undefined (None) where it has none.
fn field(v : Json, k : String) -> Json? {
  match v {
    Object(o) => o.get(k)
    _ => None
  }
}

///|
/// What the TypeScript gives back as `undefined` (test/mb-store-sessions.test.ts says it so).
fn undefined() -> Json {
  { "$undefined": true }
}

///|
/// A row as an object.
fn row_json(r : Map[String, Json]) -> Json {
  Json::object(r)
}

// ── JSON as JavaScript writes it ──

///|
fn to_js(v : Json) -> @jsjson.JValue {
  @jsjson.JValue::of_json(v)
}

///|
fn of_js(v : @jsjson.JValue) -> Json {
  match v {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Num(n) => Json::number(n)
    Str(s) => Json::string(@jsjson.raw_text(s))
    Arr(a) => Json::array(a.map(of_js))
    Obj(entries) => {
      let o : Map[String, Json] = Map([])
      // (JSON.parse's order: an integer-like key first, ascending)
      let keys = @jsjson.JValue::Obj(entries).keys()
      for k in keys {
        let key = @jsjson.raw_text(k)
        for e in entries {
          if e.0 == k {
            o[key] = of_js(e.1)
          }
        }
      }
      Json::object(o)
    }
  }
}

///|
/// JSON.stringify.
fn js(v : Json) -> String {
  @jsjson.stringify(to_js(v))
}

///|
/// JSON.parse (raising as it throws).
fn js_parse(text : String) -> Json raise {
  of_js(@jsjson.parse(text))
}

///|
/// rows.ts `parsed`: undefined (None) when it does not parse.
fn parsed(v : Json) -> Json? {
  match v {
    String(s) => Some(js_parse(s)) catch { _ => None }
    _ => None
  }
}

///|
/// `String(v)`.
fn js_string(v : Json) -> String {
  @jsjson.raw_text(@jsjson.js_string(to_js(v)))
}

///|
/// Rust's ordering of strings (rows.ts `byBytes`): by their UTF-8 bytes.
fn by_bytes(a : String, b : String) -> Int32 {
  let x = @utf8.encode(a)
  let y = @utf8.encode(b)
  let n = if x.length() < y.length() { x.length() } else { y.length() }
  for i in 0..<n {
    if x[i] != y[i] {
      return if x[i] < y[i] { -1 } else { 1 }
    }
  }
  x.length() - y.length()
}

///|
/// JavaScript's `<` of two strings: by their UTF-16 code units.
fn js_less(a : String, b : String) -> Bool {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = a.unsafe_charcode_at(i)
    let y = b.unsafe_charcode_at(i)
    if x != y {
      return x < y
    }
  }
  a.length() < b.length()
}

///|
/// `[...items].sort()` of strings, as JavaScript sorts them (by code units), stably.
fn js_sorted(items : Array[String]) -> Array[String] {
  let out = items.copy()
  out.sort_by((a, b) => {
    if js_less(a, b) {
      -1
    } else if js_less(b, a) {
      1
    } else {
      0
    }
  })
  out
}

///|
/// A JSON array of strings.
fn strings(items : Array[String]) -> Json {
  Json::array(items.map(Json::string(_)))
}

///|
/// A Map as test/mb-store-sessions.test.ts writes one: its entries, in order.
fn entries(items : Array[(String, Json)]) -> Json {
  Json::array(items.map(e => Json::array([Json::string(e.0), e.1])))
}
