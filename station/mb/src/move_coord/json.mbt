// JSON as the TypeScript of station/src/move/ holds it (`@jsjson`: JSON.parse and JSON.stringify's own): an object's
// keys in the order they were first set, a spread's (`{ ...a, ...b }`) keeping a's places and adding b's after, so
// what is written to disk and said on the wire is that TypeScript's byte for byte.

///|
pub using @jsjson {
  type JValue as J, jval_str as js, jval_num as jn, jval_int as ji, jval_bool as jb, jval_obj as jo,
  jval_array as ja, jval_strs as jstrs, jval_at as get, jval_str_of as text, jval_num_of as num,
  jval_is_true as is_true, jval_arr_of as arr, jval_is_record as is_map, jval_keys_of as keys_of,
  jval_set_or_new as set, jval_del as del, jval_spread as spread, stringify, parse, jval_same_opt as same,
  jval_stringify_num as num_text, js_slice_to as slice_to,
}

///|
pub fn jl(i : Int64) -> J {
  Num(i.to_double())
}

///|
/// Present: neither absent nor null (`v != null`).
pub fn present(j : J?) -> Bool {
  !@jsjson.jval_nullish(j)
}

///|
pub fn has_key(o : J, k : String) -> Bool {
  let u = k
  match o {
    Obj(ps) => ps.iter().any(p => p.0 == u)
    _ => false
  }
}

///|
/// `o[k] = v` where `v` is something, a copy.
pub fn set_opt(o : J, k : String, v : J?) -> J {
  match v {
    Some(x) => set(o, k, x)
    None => o
  }
}

///|
/// `s.slice(start)`.
pub fn slice_from(s : String, start : Int) -> String {
  if start >= s.length() {
    ""
  } else if start <= 0 {
    s
  } else {
    s.unsafe_substring(start~, end=s.length())
  }
}

///|
/// `s.slice(start, end)`, `end` past its end clamped.
pub fn slice(s : String, start : Int, end : Int) -> String {
  let e = if end > s.length() { s.length() } else { end }
  if start >= e {
    ""
  } else {
    s.unsafe_substring(start~, end=e)
  }
}

///|
/// `s.indexOf(sub)` (-1: none).
pub fn index_of(s : String, sub : String) -> Int {
  match s.find(sub) {
    Some(i) => i
    None => -1
  }
}

///|
/// `s.lastIndexOf(sub)` (-1: none).
pub fn last_index_of(s : String, sub : String) -> Int {
  match s.rev_find(sub) {
    Some(i) => i
    None => -1
  }
}
