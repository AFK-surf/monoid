// JSON read and written as the TypeScript of station/src/rig, src/rigs and src/elevation reads and writes it: a value's
// fields looked up as JavaScript looks them up (a field of anything but an object is undefined), numbers and strings
// said as `String(…)` says them, an object's keys in JavaScript's order (its integer-like keys first, ascending) where
// it is written (JSON.stringify) or walked (Object.values, Object.entries).

///|
pub fn jstr(s : String) -> Json {
  Json::string(s)
}

///|
pub fn jnum(n : Double) -> Json {
  Json::number(n)
}

///|
pub fn jbool(b : Bool) -> Json {
  Json::boolean(b)
}

///|
pub fn jobj(pairs : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for p in pairs {
    m[p.0] = p.1
  }
  Json::object(m)
}

///|
pub fn jarr(xs : Array[Json]) -> Json {
  Json::array(xs)
}

///|
/// `v[k]`: undefined (None) for anything but an object, or where it has no such key.
pub fn get(v : Json?, k : String) -> Json? {
  match v {
    Some(Object(m)) => m.get(k)
    _ => None
  }
}

///|
fn str_at(v : Json?, k : String) -> String? {
  match get(v, k) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn num_at(v : Json?, k : String) -> Double? {
  match get(v, k) {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
fn bool_at(v : Json?, k : String) -> Bool? {
  match get(v, k) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
fn arr_at(v : Json?, k : String) -> Array[Json]? {
  match get(v, k) {
    Some(Array(xs)) => Some(xs)
    _ => None
  }
}

///|
/// `typeof v === "object" && v !== null` (an array too).
fn is_objectish(v : Json?) -> Bool {
  v is Some(Object(_) | Array(_))
}

///|
/// Number.isSafeInteger.
pub fn safe_int(n : Double) -> Bool {
  @jsjson.is_safe_integer(n)
}

///|
fn safe_int_at(v : Json?) -> Bool {
  match v {
    Some(Number(n, ..)) => safe_int(n)
    _ => false
  }
}

///|
/// A number as `String(n)` writes it.
pub fn num_text(n : Double) -> String {
  @cloud_lock.stringify(Json::number(n))
}

///|
/// `String(v)` of a value read from JSON (undefined as "undefined").
pub fn js_string_of(v : Json?) -> String {
  match v {
    None => "undefined"
    Some(Null) => "null"
    Some(True) => "true"
    Some(False) => "false"
    Some(Number(n, ..)) => num_text(n)
    Some(String(s)) => s
    Some(Array(xs)) => {
      let parts = xs.map(x => match x {
        Null => ""
        _ => js_string_of(Some(x))
      })
      parts.join(",")
    }
    Some(Object(_)) => "[object Object]"
  }
}

///|
/// The index an object's key is in JavaScript's order of its keys, where it is one (an array index's form).
fn key_index(k : String) -> Double? {
  @jsjson.index_key(k)
}

///|
/// An object's own keys and values in JavaScript's order (Object.entries).
pub fn js_entries(m : Map[String, Json]) -> Array[(String, Json)] {
  js_order(m.iter().collect())
}

///|
/// Pairs put in the order JavaScript keeps an object's keys in: its integer-like keys first, ascending.
fn[T] js_order(all : Array[(String, T)]) -> Array[(String, T)] {
  let indexed = all.filter(e => key_index(e.0) is Some(_))
  @cloud_lock.stable_sort(indexed, (a, b) => key_index(a.0).unwrap().compare(key_index(b.0).unwrap()))
  indexed + all.filter(e => key_index(e.0) is None)
}

///|
/// A value with every object's keys put in JavaScript's order.
fn js_ordered(v : Json) -> Json {
  match v {
    Object(m) => {
      let out : Map[String, Json] = Map([])
      for e in js_entries(m) {
        out[e.0] = js_ordered(e.1)
      }
      Json::object(out)
    }
    Array(xs) => Json::array(xs.map(js_ordered))
    _ => v
  }
}

///|
/// JSON.stringify(v).
pub fn stringify(v : Json) -> String {
  @cloud_lock.stringify(js_ordered(v))
}

///|
/// JSON.parse(text): None where it is none.
pub fn parse(text : String) -> Json? {
  @cloud_lock.parse(text)
}

///|
/// `{ ...a, ...b }`: b's fields over a's, a's order kept and b's new ones after.
fn spread(a : Json?, b : Json?) -> Json {
  let out : Map[String, Json] = Map([])
  if a is Some(Object(m)) {
    for e in js_entries(m) {
      out[e.0] = e.1
    }
  }
  if b is Some(Object(m)) {
    for e in js_entries(m) {
      out[e.0] = e.1
    }
  }
  Json::object(out)
}

///|
/// Whether a character is in JavaScript's `\s`.
fn js_space(c : Int) -> Bool {
  @jscase.is_space(c)
}

///|
/// String.prototype.trim.
pub fn js_trim(s : String) -> String {
  @jscase.trim(s)
}

///|
/// String.prototype.toLowerCase for what a name or an email has (ASCII, and what MoonBit lowers alike).
pub fn js_lower(s : String) -> String {
  s.to_lower()
}

///|
fn is_hex_text(s : String, n : Int) -> Bool {
  if s.length() != n {
    return false
  }
  for i in 0..<s.length() {
    let c = s.unsafe_charcode_at(i)
    if !((c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66)) {
      return false
    }
  }
  true
}

///|
/// `/^([0-9a-f]{2})+$/`.
fn hex_pairs(s : String) -> Bool {
  s.length() > 0 && s.length() % 2 == 0 && is_hex_text(s, s.length())
}

///|
/// `new Date(ms).toISOString()`.
pub fn iso(ms : Double) -> String {
  @time.format_iso_ms(ms.to_int64())
}

///|
/// A refusal of these parts (rig/grants.ts `Refusal`, rigs/requests.ts `Refused`, mesh/bus.ts `Refused`,
/// elevation.ts `ChangeRefused`): its words, which the station passes on as they are.
pub(all) suberror Refused {
  Refused(String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for Refused with output(self, logger) {
  match self {
    Refused(m) => logger.write_string(m)
  }
}

///|
/// What a part the station gives threw (an Error of its, by its class's name, and its message).
pub(all) suberror Thrown {
  Thrown(String, String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for Thrown with output(self, logger) {
  match self {
    Thrown(_, m) => logger.write_string(m)
  }
}

///|
pub fn error_message(e : Error) -> String {
  match e {
    Refused(m) => m
    Thrown(_, m) => m
    @cloud_lock.Failed(m) => m
    @cloud_lock.Refused(m) => m
    Failure(m) => m
    ChangeRefused(key) => key
    DeviceRefused(_, m) => m
    _ => e.to_string()
  }
}
