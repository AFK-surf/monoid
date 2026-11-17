// JSON as the drivers make and read it: JavaScript's (`@jsjson`: an object's keys in the order they were set, strings
// in UTF-16 code units), so that what a driver writes (a frame, a request, a process's arguments with JSON in them) is
// the same bytes `JSON.stringify` made of the TypeScript's.

///|
using @jsjson {type JValue}

///|
/// A string.
pub fn s(text : String) -> JValue {
  Str(@jsjson.units(text))
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
  Obj(entries.map(e => (@jsjson.units(e.0), e.1)))
}

///|
pub fn arr(items : Array[JValue]) -> JValue {
  Arr(items)
}

///|
pub fn strs(items : Array[String]) -> JValue {
  Arr(items.map(s))
}

///|
/// `v.name` where `v` is an object.
pub fn get(v : JValue?, name : String) -> JValue? {
  match v {
    Some(o) => o.get(name)
    None => None
  }
}

///|
/// `v[name]` where it is a string.
pub fn str_at(v : JValue?, name : String) -> String? {
  match get(v, name) {
    Some(Str(u)) => Some(@jsjson.text(u))
    _ => None
  }
}

///|
pub fn str_of(v : JValue?) -> String? {
  match v {
    Some(Str(u)) => Some(@jsjson.text(u))
    _ => None
  }
}

///|
pub fn num_of(v : JValue?) -> Double? {
  match v {
    Some(Num(x)) => Some(x)
    _ => None
  }
}

///|
pub fn num_at(v : JValue?, name : String) -> Double? {
  num_of(get(v, name))
}

///|
pub fn bool_at(v : JValue?, name : String) -> Bool? {
  match get(v, name) {
    Some(Bool(x)) => Some(x)
    _ => None
  }
}

///|
/// `v[name] === true`.
pub fn is_true(v : JValue?, name : String) -> Bool {
  bool_at(v, name) == Some(true)
}

///|
pub fn arr_of(v : JValue?) -> Array[JValue]? {
  match v {
    Some(Arr(a)) => Some(a)
    _ => None
  }
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
  guard o is Obj(es) else { return o }
  let key = @jsjson.units(name)
  let out = es.copy()
  for i, e in out {
    if e.0 == key {
      out[i] = (key, v)
      return Obj(out)
    }
  }
  out.push((key, v))
  Obj(out)
}

///|
/// `delete o[name]`.
pub fn del(o : JValue, name : String) -> JValue {
  guard o is Obj(es) else { return o }
  let key = @jsjson.units(name)
  Obj(es.filter(e => e.0 != key))
}

///|
/// `{ ...a, ...b }`: what is not an object adds nothing.
pub fn spread(parts : Array[JValue]) -> JValue {
  let mut out : JValue = Obj([])
  for p in parts {
    if p is Obj(es) {
      for e in es {
        out = set(out, @jsjson.text(e.0), e.1)
      }
    }
  }
  out
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
  match v {
    Some(Num(x)) =>
      x == x.floor() && x.abs() <= 9007199254740991.0
    _ => false
  }
}

///|
pub fn opt_s(v : String?) -> JValue {
  match v {
    Some(t) => s(t)
    None => Null
  }
}
