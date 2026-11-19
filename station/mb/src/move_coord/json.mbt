// JSON as the TypeScript of station/src/move/ holds it (`@jsjson`: JSON.parse and JSON.stringify's own): an object's
// keys in the order they were first set, a spread's (`{ ...a, ...b }`) keeping a's places and adding b's after, so
// what is written to disk and said on the wire is that TypeScript's byte for byte.

///|
pub using @jsjson {type JValue as J}

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
pub fn jl(i : Int64) -> J {
  Num(i.to_double())
}

///|
pub fn jb(b : Bool) -> J {
  @jsjson.JValue::of_bool(b)
}

///|
pub fn jo(pairs : Array[(String, J)]) -> J {
  @jsjson.JValue::of_object(pairs)
}

///|
pub fn ja(items : Array[J]) -> J {
  @jsjson.JValue::of_array(items)
}

///|
pub fn jstrs(items : Array[String]) -> J {
  @jsjson.JValue::of_strings(items)
}

///|
/// `o[k]` where `o` is an object.
pub fn get(o : J?, k : String) -> J? {
  @jsjson.jval_at(o, k)
}

///|
pub fn text(j : J?) -> String? {
  @jsjson.jval_str_of(j)
}

///|
pub fn num(j : J?) -> Double? {
  @jsjson.jval_num_of(j)
}

///|
pub fn is_true(j : J?) -> Bool {
  @jsjson.jval_is_true(j)
}

///|
pub fn arr(j : J?) -> Array[J]? {
  @jsjson.jval_arr_of(j)
}

///|
/// `v !== null && typeof v === "object" && !Array.isArray(v)`.
pub fn is_map(j : J?) -> Bool {
  j is Some(Obj(_))
}

///|
/// Present: neither absent nor null (`v != null`).
pub fn present(j : J?) -> Bool {
  match j {
    None | Some(Null) => false
    _ => true
  }
}

///|
pub fn keys_of(o : J) -> Array[String] {
  @jsjson.jval_keys_of(o)
}

///|
pub fn has_key(o : J, k : String) -> Bool {
  let u = @jsjson.units(k)
  match o {
    Obj(ps) => ps.iter().any(p => p.0 == u)
    _ => false
  }
}

///|
/// `o[k] = v` on a copy: in its place where `o` has it, else last.
pub fn set(o : J, k : String, v : J) -> J {
  @jsjson.jval_set_or_new(o, k, v)
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
/// `delete o[k]` on a copy.
pub fn del(o : J, k : String) -> J {
  @jsjson.jval_del(o, k)
}

///|
/// `{ ...a, ...b }`.
pub fn spread(a : J, b : J) -> J {
  @jsjson.jval_spread(a, b)
}

///|
pub fn stringify(j : J) -> String {
  @jsjson.stringify(j)
}

///|
pub fn parse(s : String) -> J raise {
  @jsjson.parse(s)
}

///|
/// `JSON.stringify(a) === JSON.stringify(b)`.
pub fn same(a : J?, b : J?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => stringify(x) == stringify(y)
    _ => false
  }
}

///|
/// A number as JavaScript's `String(n)` says it (what words are filled with).
pub fn num_text(d : Double) -> String {
  stringify(Num(d))
}

///|
/// `s.slice(0, n)` (by UTF-16 units, as JavaScript's).
pub fn slice_to(s : String, n : Int) -> String {
  if s.length() <= n {
    s
  } else {
    s.unsafe_substring(start=0, end=n)
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
