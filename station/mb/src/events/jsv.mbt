// JSON values as JavaScript makes and writes them (@jsjson: JSON.stringify's text, an object's keys in its order),
// with what the TypeScript station does to them: a property read (`v.name`), set in its place or after the rest
// (`{ ...v, name }`), deleted, a string's text.

///|
using @jsjson {
  type JValue as J, jval_str as js, jval_num as jn, jval_obj as jo, jval_array as ja,
  jval_str_raw_of as text_of, jval_set_or_new as with_prop, jval_del as without, stringify,
  jval_try_parse as parse, jval_stringify_num as num_text, js_compare,
}

///|
/// An object of these properties, those absent (undefined) left out as JSON.stringify leaves them.
fn jopt(pairs : Array[(String, J?)]) -> J {
  Obj(pairs.filter_map(p => p.1.map(v => (p.0, v))))
}

///|
fn str_prop(v : J, name : String) -> String? {
  text_of(v.get(name))
}

///|
fn num_prop(v : J, name : String) -> Double? {
  @jsjson.jval_num_of(v.get(name))
}

///|
/// Whether `v` has `name` (`name in v`).
fn has(v : J, name : String) -> Bool {
  v.get(name) is Some(_)
}

///|
/// `String(v ?? "")`.
fn string_of(v : J?) -> String {
  match v {
    None | Some(Null) => ""
    Some(v) => @jsjson.js_string(v)
  }
}

///|
/// `v[i]`: none where `v` is no array or too short.
fn at(v : J, i : Int32) -> J? {
  @jsjson.jval_at_i(Some(v), i)
}

///|
/// `{ ...v }`: an object's own properties; a string's or an array's by their indices; nothing of anything else.
fn spread(v : J) -> J {
  match v {
    Obj(_) => v
    Str(s) =>
      Obj(Array::makei(s.length(), i => (i.to_string(), Str(s.unsafe_substring(start=i, end=i + 1)))))
    Arr(items) =>
      Obj(items.mapi((i, item) => (i.to_string(), item)))
    _ => Obj([])
  }
}

///|
/// JavaScript's ToNumber of a value (`Math.min` takes its arguments so).
fn to_number(v : J) -> Double {
  match v {
    Num(n) => n
    Null => 0.0
    Bool(b) => if b { 1.0 } else { 0.0 }
    Str(s) => js_number(s)
    Arr([]) => 0.0
    Arr([one]) => to_number(Str(@jsjson.js_string(one)))
    _ => @double.not_a_number
  }
}

///|
/// Math.min of two numbers: NaN where either is.
fn js_min(a : Double, b : Double) -> Double {
  if a.is_nan() || b.is_nan() {
    @double.not_a_number
  } else if a < b || (a == b && a.signum() < 0.0) {
    a
  } else {
    b
  }
}
