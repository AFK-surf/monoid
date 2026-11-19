// JSON values as JavaScript makes and writes them (@jsjson: JSON.stringify's text, an object's keys in its order),
// with what the TypeScript station does to them: a property read (`v.name`), set in its place or after the rest
// (`{ ...v, name }`), deleted, a string's text.

///|
using @jsjson {type JValue}

///|
type J = JValue

///|
fn js(s : String) -> J {
  Str(s)
}

///|
fn jn(d : Double) -> J {
  Num(d)
}

///|
/// An object of these properties, in this order.
fn jo(pairs : Array[(String, J)]) -> J {
  Obj(pairs)
}

///|
/// An object of these properties, those absent (undefined) left out as JSON.stringify leaves them.
fn jopt(pairs : Array[(String, J?)]) -> J {
  let out = []
  for p in pairs {
    if p.1 is Some(v) {
      out.push((p.0, v))
    }
  }
  Obj(out)
}

///|
fn ja(items : Array[J]) -> J {
  Arr(items)
}

///|
/// The text of a string (its code units as they are).
fn text_of(v : J?) -> String? {
  match v {
    Some(Str(s)) => Some(s)
    _ => None
  }
}

///|
fn str_prop(v : J, name : String) -> String? {
  text_of(v.get(name))
}

///|
fn num_prop(v : J, name : String) -> Double? {
  match v.get(name) {
    Some(Num(d)) => Some(d)
    _ => None
  }
}

///|
/// Whether `v` has `name` (`name in v`).
fn has(v : J, name : String) -> Bool {
  v.get(name) is Some(_)
}

///|
/// `{ ...v, [name]: value }`: an object's property set where it is, or put after the rest (anything but an object
/// spread as none).
fn with_prop(v : J, name : String, value : J) -> J {
  let out = []
  let mut set = false
  if v is Obj(entries) {
    for e in entries {
      if e.0 == name {
        if !set {
          out.push((name, value))
          set = true
        }
      } else {
        out.push(e)
      }
    }
  }
  if !set {
    out.push((name, value))
  }
  Obj(out)
}

///|
/// `{ ...v }` without `name` (`delete copy[name]`).
fn without(v : J, name : String) -> J {
  @jsjson.jval_del(v, name)
}

///|
fn stringify(v : J) -> String {
  @jsjson.stringify(v)
}

///|
/// JSON.parse; none for what is not JSON.
fn parse(text : String) -> J? {
  @jsjson.jval_try_parse(text)
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
/// A number as JavaScript writes it in a template string (`${n}`).
fn num_text(d : Double) -> String {
  @jsjson.stringify(Num(d))
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
/// `a < b` of two strings, as JavaScript compares them: by their UTF-16 code units.
fn js_compare(a : String, b : String) -> Int32 {
  @jsjson.js_compare(a, b)
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
