// JSON as JavaScript reads and writes it (JSON.parse, JSON.stringify), through station/jsjson: what the TypeScript
// writes to a file and what it is answered are the same text here.

///|
fn jvalue_of(v : Json) -> @jsjson.JValue {
  @jsjson.JValue::of_json(v)
}

///|
/// JSON.stringify(v).
pub fn stringify(v : Json) -> String {
  @jsjson.stringify(jvalue_of(v))
}

///|
/// JSON.stringify(v, null, 2).
pub fn stringify_pretty(v : Json) -> String {
  @jsjson.stringify_indent(jvalue_of(v), 2)
}

///|
/// JSON.parse(text): None where it is none.
pub fn parse(text : String) -> Json? {
  @jsjson.jval_try_parse(text).map(v => v.to_json())
}

///|
/// A stable sort in place (as JavaScript's Array.prototype.sort).
pub fn[T] stable_sort(xs : Array[T], cmp : (T, T) -> Int) -> Unit {
  let n = xs.length()
  if n < 2 {
    return
  }
  let tmp = xs.copy()
  let mut width = 1
  let mut src = xs
  let mut dst = tmp
  while width < n {
    let mut lo = 0
    while lo < n {
      let mid = if lo + width < n { lo + width } else { n }
      let hi = if lo + 2 * width < n { lo + 2 * width } else { n }
      let mut i = lo
      let mut j = mid
      let mut k = lo
      while k < hi {
        if i < mid && (j >= hi || cmp(src[i], src[j]) <= 0) {
          dst[k] = src[i]
          i += 1
        } else {
          dst[k] = src[j]
          j += 1
        }
        k += 1
      }
      lo += 2 * width
    }
    let t = src
    src = dst
    dst = t
    width *= 2
  }
  if !physical_equal(src, xs) {
    for i in 0..<n {
      xs[i] = src[i]
    }
  }
}

// ── reading a JSON value as the TypeScript does ─────────────────────────────────────────────────────────────────

///|
fn field(v : Json?, k : String) -> Json? {
  match v {
    Some(Object(m)) => m.get(k)
    _ => None
  }
}

///|
fn get(v : Json, k : String) -> Json? {
  match v {
    Object(m) => m.get(k)
    _ => None
  }
}

///|
fn text_at(v : Json, k : String) -> String? {
  match get(v, k) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn num_at(v : Json, k : String) -> Double? {
  match get(v, k) {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
fn array_at(v : Json, k : String) -> Array[Json]? {
  match get(v, k) {
    Some(Array(xs)) => Some(xs)
    _ => None
  }
}

///|
fn jstr(s : String) -> Json {
  Json::string(s)
}

///|
fn jnum(n : Double) -> Json {
  Json::number(n)
}

///|
fn jobj(pairs : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for p in pairs {
    m[p.0] = p.1
  }
  Json::object(m)
}

///|
fn jarr(xs : Array[Json]) -> Json {
  Json::array(xs)
}

///|
fn jstrs(xs : Array[String]) -> Json {
  Json::array(xs.map(x => Json::string(x)))
}

///|
fn opt_str_json(s : String?) -> Json {
  match s {
    Some(x) => Json::string(x)
    None => Json::null()
  }
}

///|
/// Whether a number is a safe integer (Number.isSafeInteger).
fn safe_int(n : Double) -> Bool {
  @jsjson.is_safe_integer(n)
}

///|
/// The object's own keys and values, as `Object.entries`.
fn entries_of_obj(v : Json?) -> Array[(String, Json)] {
  match v {
    Some(Object(m)) => m.iter().collect()
    _ => []
  }
}
