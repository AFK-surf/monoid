// JSON read and written as the TypeScript of station/src/rig, src/rigs and src/elevation reads and writes it: a value's
// fields looked up as JavaScript looks them up (a field of anything but an object is undefined), numbers and strings
// said as `String(…)` says them, an object's keys in JavaScript's order (its integer-like keys first, ascending) where
// it is written (JSON.stringify) or walked (Object.values, Object.entries).

///|
pub using @jsjson {
  json_str as jstr, json_num as jnum, json_bool as jbool, json_obj as jobj, json_arr as jarr, json_at as get,
  is_safe_integer as safe_int, json_js_str as js_string_of,
}

///|
using @jsjson {
  json_str_at as str_at, json_num_at as num_at, json_bool_at as bool_at, json_arr_at as arr_at,
  json_is_objectish as is_objectish, index_key as key_index,
}

///|
pub using @cloud_lock {parse}

///|
pub using @jscase {trim as js_trim}

///|
using @jscase {is_space as js_space}

///|
fn safe_int_at(v : Json?) -> Bool { v is Some(Number(n, ..)) && safe_int(n) }

///|
/// A number as `String(n)` writes it.
pub fn num_text(n : Double) -> String { @cloud_lock.stringify(Json::number(n)) }

///|
/// An object's own keys and values in JavaScript's order (Object.entries).
pub fn js_entries(m : Map[String, Json]) -> Array[(String, Json)] { js_order(m.iter().collect()) }

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
/// String.prototype.toLowerCase for what a name or an email has (ASCII, and what MoonBit lowers alike).
pub fn js_lower(s : String) -> String {
  s.to_lower()
}

///|
fn is_hex_text(s : String, n : Int) -> Bool {
  s.length() == n && s.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
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
