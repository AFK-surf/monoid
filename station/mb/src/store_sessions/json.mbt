// Values as the TypeScript store reads and writes them: a row's columns (`col`), JavaScript's tests of them
// (`r.x === 1`, `typeof r.x === "string"`), and JSON as JavaScript writes it (JSON.stringify: `js`), so the text a
// statement is given is the station's byte for byte.

///|
using @jsjson {
  json_str as jstr, json_bool as jbool, json_num as jnum, json_field as field,
  jval_of_json as to_js, jval_to_json as of_js, json_strs as strings, json_int64 as jint,
}

///|
fn col(r : Map[String, Json], k : String) -> Json { r.get(k).unwrap_or(Json::null()) }

///|
fn flag(b : Bool) -> Json { Json::number(if b { 1.0 } else { 0.0 }) }

///|
/// store.ts `optFlag`: null or undefined as null, else 1 or 0 by JavaScript's truthiness of a boolean.
fn opt_flag(v : Json?) -> Json {
  match v {
    None | Some(Null) => Json::null()
    Some(v) => flag(truthy(v))
  }
}

///|
fn truthy(v : Json) -> Bool { @jsjson.json_truthy(Some(v)) }

///|
fn str_of(v : Json) -> String? { @jsjson.json_str_of(Some(v)) }

///|
fn num_of(v : Json) -> Double? { @jsjson.json_num_of(Some(v)) }

///|
fn is_n(v : Json, n : Double) -> Bool { v is Number(x, ..) && x == n }

///|
fn nullish(v : Json?) -> Json { v.unwrap_or(Json::null()) }

///|
fn or_else(a : Json, b : Json) -> Json { if a is Null { b } else { a } }

///|
fn arr(v : Json) -> Array[Json] { @jsjson.json_items(Some(v)) }

///|
fn obj(v : Json) -> Map[String, Json] {
  match v {
    Object(o) => o
    _ => Map([])
  }
}

///|
/// What the TypeScript gives back as `undefined` (test/mb-store-sessions.test.ts says it so).
fn undefined() -> Json { { "$undefined": true } }

///|
fn row_json(r : Map[String, Json]) -> Json { Json::object(r) }

// ── JSON as JavaScript writes it ──

///|
fn js(v : Json) -> String { @jsjson.stringify(to_js(v)) }

///|
fn js_parse(text : String) -> Json raise { of_js(@jsjson.parse(text)) }

///|
/// rows.ts `parsed`: undefined (None) when it does not parse.
fn parsed(v : Json) -> Json? {
  match v {
    String(s) => Some(js_parse(s)) catch { _ => None }
    _ => None
  }
}

///|
fn js_string(v : Json) -> String { @jsjson.js_string(to_js(v)) }

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
/// `[...items].sort()` of strings, as JavaScript sorts them (by code units), stably.
fn js_sorted(items : Array[String]) -> Array[String] {
  let out = items.copy()
  out.sort_by(@jsjson.js_compare)
  out
}

///|
/// A Map as test/mb-store-sessions.test.ts writes one: its entries, in order.
fn entries(items : Array[(String, Json)]) -> Json {
  Json::array(items.map(e => Json::array([Json::string(e.0), e.1])))
}
