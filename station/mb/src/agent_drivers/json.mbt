// JSON as the drivers make and read it: JavaScript's (`@jsjson`: an object's keys in the order they were set, strings
// in UTF-16 code units), so that what a driver writes (a frame, a request, a process's arguments with JSON in them) is
// the same bytes `JSON.stringify` made of the TypeScript's.

///|
using @jsjson {type JValue}

///|
/// A string.
pub fn s(text : String) -> JValue {
  JValue::of_string(text)
}

///|
/// A number.
pub fn n(v : Int) -> JValue {
  Num(v.to_double())
}

///|
pub fn d(v : Double) -> JValue {
  Num(v)
}

///|
pub fn b(v : Bool) -> JValue {
  Bool(v)
}

///|
/// An object of these entries, in this order.
pub fn obj(entries : Array[(String, JValue)]) -> JValue {
  JValue::of_object(entries)
}

///|
pub fn arr(items : Array[JValue]) -> JValue {
  Arr(items)
}

///|
pub fn strs(items : Array[String]) -> JValue {
  JValue::of_strings(items)
}

///|
/// `v.name` where `v` is an object.
pub fn get(v : JValue?, name : String) -> JValue? {
  @jsjson.jval_at(v, name)
}

///|
/// `v[name]` where it is a string.
pub fn str_at(v : JValue?, name : String) -> String? {
  str_of(get(v, name))
}

///|
pub fn str_of(v : JValue?) -> String? {
  @jsjson.jval_str_of(v)
}

///|
pub fn num_of(v : JValue?) -> Double? {
  @jsjson.jval_num_of(v)
}

///|
pub fn num_at(v : JValue?, name : String) -> Double? {
  num_of(get(v, name))
}

///|
pub fn bool_at(v : JValue?, name : String) -> Bool? {
  @jsjson.jval_bool_of(get(v, name))
}

///|
/// `v[name] === true`.
pub fn is_true(v : JValue?, name : String) -> Bool {
  bool_at(v, name) == Some(true)
}

///|
pub fn arr_of(v : JValue?) -> Array[JValue]? {
  @jsjson.jval_arr_of(v)
}

///|
pub fn arr_at(v : JValue?, name : String) -> Array[JValue]? {
  arr_of(get(v, name))
}

///|
/// The strings of an array (what is not one left out).
pub fn strings_in(v : JValue?) -> Array[String] {
  match v {
    Some(Arr(a)) => a.filter_map(x => str_of(Some(x)))
    _ => []
  }
}

///|
pub fn entries_of(v : JValue?) -> Array[(String, JValue)] {
  match v {
    Some(Obj(es)) => es.map(e => (@jsjson.text(e.0), e.1))
    _ => []
  }
}

///|
/// `o[name] = v` as JavaScript sets it: in its place where the key is there, at the end where it is not.
pub fn set(o : JValue, name : String, v : JValue) -> JValue {
  @jsjson.jval_set(o, name, v)
}

///|
/// `delete o[name]`.
pub fn del(o : JValue, name : String) -> JValue {
  @jsjson.jval_del(o, name)
}

///|
/// `{ ...a, ...b }`: what is not an object adds nothing.
pub fn spread(parts : Array[JValue]) -> JValue {
  parts.fold(init=Obj([]), @jsjson.jval_spread)
}

///|
/// `JSON.stringify`.
pub fn json_text(v : JValue) -> String {
  @jsjson.stringify(v)
}

///|
/// `JSON.parse`, none for what is not JSON.
pub fn parse_json(text : String) -> JValue? {
  Some(@jsjson.parse(text)) catch {
    _ => None
  }
}

///|
/// A string map as an object, in its keys' order.
pub fn map_json(m : Array[(String, String)]) -> JValue {
  obj(m.map(e => (e.0, s(e.1))))
}

///|
/// An object of strings as an ordered map (what is not a string left out).
pub fn string_entries(v : JValue?) -> Array[(String, String)] {
  entries_of(v).filter_map(e => match e.1 {
    Str(u) => Some((e.0, @jsjson.text(u)))
    _ => None
  })
}

///|
/// `Number.isSafeInteger`.
pub fn safe_integer(v : JValue?) -> Bool {
  v is Some(Num(x)) && @jsjson.is_safe_integer(x)
}

///|
pub fn opt_s(v : String?) -> JValue {
  JValue::of_opt_string(v)
}
