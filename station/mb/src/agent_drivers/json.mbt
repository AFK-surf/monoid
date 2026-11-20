// JSON as the drivers make and read it: JavaScript's (`@jsjson`: an object's keys in the order they were set, strings
// in UTF-16 code units), so that what a driver writes (a frame, a request, a process's arguments with JSON in them) is
// the same bytes `JSON.stringify` made of the TypeScript's.

///|
using @jsjson {type JValue}

///|
pub using @jsjson {
  jval_str as s, jval_int as n, jval_num as d, jval_bool as b, jval_obj as obj, jval_array as arr,
  jval_strs as strs, jval_at as get, jval_str_at as str_at, jval_str_of as str_of, jval_num_of as num_of,
  jval_num_at as num_at, jval_bool_at as bool_at, jval_arr_of as arr_of, jval_arr_at as arr_at,
  jval_strings_of as strings_in, jval_entries as entries_of, jval_set as set, jval_del as del,
  stringify as json_text, jval_try_parse as parse_json, jval_safe_int as safe_integer, jval_opt_str as opt_s,
}

///|
/// `v[name] === true`.
pub fn is_true(v : JValue?, name : String) -> Bool {
  bool_at(v, name) == Some(true)
}

///|
/// `{ ...a, ...b }`: what is not an object adds nothing.
pub fn spread(parts : Array[JValue]) -> JValue {
  parts.fold(init=Obj([]), @jsjson.jval_spread)
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
    Str(u) => Some((e.0, @jsjson.sanitize_str(u)))
    _ => None
  })
}
