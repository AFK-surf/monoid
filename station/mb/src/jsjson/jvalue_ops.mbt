// `JValue` as the packages make and read it: MoonBit's `Json` to and from it with nothing written and read again, and
// the small makers, readers and changes every package wrote alike. Each is JavaScript's own (`v.k`, `o[k] = v`,
// `{ ...a, ...b }`, `!!v`, `v == null`) where its doc says so; a package whose own differs keeps its own.

///|
/// MoonBit's JSON as JavaScript's value: an object's entries in the map's order.
pub fn JValue::of_json(v : Json) -> JValue {
  match v {
    Null => Null
    True => Bool(true)
    False => Bool(false)
    Number(n, ..) => Num(n)
    String(s) => Str(units(s))
    Array(xs) => Arr(xs.map(JValue::of_json))
    Object(m) => Obj(m.iter().map(kv => (units(kv.0), JValue::of_json(kv.1))).collect())
  }
}

///|
/// The value as MoonBit's JSON, what `@json.parse(stringify(v))` reads: NaN and the infinities as null, an object's
/// keys in JavaScript's order (integer-like ones first) and a repeated key's last value. A string's lone surrogates
/// are kept (`raw_text`, as JSON.parse reads back the `\ud800` JSON.stringify writes), where `@json.parse` refuses
/// that text whole; `of_json` gives the same code units back.
pub fn JValue::to_json(self : JValue) -> Json {
  match self {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Num(n) => if n.is_nan() || n.is_inf() { Json::null() } else { Json::number(n) }
    Str(u) => Json::string(raw_text(u))
    Arr(xs) => Json::array(xs.map(JValue::to_json))
    Obj(fs) => {
      let m : Map[String, Json] = Map([])
      for f in ordered(fs) {
        m[raw_text(f.0)] = f.1.to_json()
      }
      Json::object(m)
    }
  }
}

///|
pub fn JValue::of_string(s : String) -> JValue {
  Str(units(s))
}

///|
pub fn JValue::of_double(d : Double) -> JValue {
  Num(d)
}

///|
pub fn JValue::of_int(i : Int) -> JValue {
  Num(i.to_double())
}

///|
pub fn JValue::of_bool(b : Bool) -> JValue {
  Bool(b)
}

///|
/// An object of these entries, in this order (a repeated key kept twice).
pub fn JValue::of_object(fields : Array[(String, JValue)]) -> JValue {
  Obj(fields.map(f => (units(f.0), f.1)))
}

///|
pub fn JValue::of_array(items : Array[JValue]) -> JValue {
  Arr(items)
}

///|
pub fn JValue::of_strings(items : Array[String]) -> JValue {
  Arr(items.map(JValue::of_string))
}

///|
/// The string, or null.
pub fn JValue::of_opt_string(s : String?) -> JValue {
  match s {
    Some(t) => Str(units(t))
    None => Null
  }
}

///|
/// `v[name]` where `v` is an object: a repeated key's first entry (`JValue::get`).
pub fn jval_at(v : JValue?, name : String) -> JValue? {
  match v {
    Some(Obj(_) as o) => o.get(name)
    _ => None
  }
}

///|
/// `v[i]` where `v` is an array and `i` within it.
pub fn jval_at_i(v : JValue?, i : Int) -> JValue? {
  match v {
    Some(Arr(xs)) => if i >= 0 && i < xs.length() { Some(xs[i]) } else { None }
    _ => None
  }
}

///|
/// A string's text (`text`: a lone surrogate as U+FFFD), none for what is not a string.
pub fn jval_str_of(v : JValue?) -> String? {
  match v {
    Some(Str(u)) => Some(text(u))
    _ => None
  }
}

///|
pub fn jval_num_of(v : JValue?) -> Double? {
  match v {
    Some(Num(d)) => Some(d)
    _ => None
  }
}

///|
pub fn jval_bool_of(v : JValue?) -> Bool? {
  match v {
    Some(Bool(b)) => Some(b)
    _ => None
  }
}

///|
pub fn jval_arr_of(v : JValue?) -> Array[JValue]? {
  match v {
    Some(Arr(xs)) => Some(xs)
    _ => None
  }
}

///|
/// An object's keys as its entries hold them (in their order, a repeated key twice); none for what is not an object.
/// `JValue::keys` is `Object.keys`'s order.
pub fn jval_keys_of(v : JValue) -> Array[String] {
  match v {
    Obj(fs) => fs.map(f => text(f.0))
    _ => []
  }
}

///|
/// `v === true`.
pub fn jval_is_true(v : JValue?) -> Bool {
  v is Some(Bool(true))
}

///|
/// `o[k] = v` on an object: in its place where the key is there, at the end where it is not; what is not an object
/// is given back as it is.
pub fn jval_set(o : JValue, k : String, v : JValue) -> JValue {
  guard o is Obj(fs) else { return o }
  let ku = units(k)
  let out = fs.copy()
  match out.search_by(f => f.0 == ku) {
    Some(i) => out[i] = (ku, v)
    None => out.push((ku, v))
  }
  Obj(out)
}

///|
/// `jval_set`, what is not an object taken as `{}`.
pub fn jval_set_or_new(o : JValue, k : String, v : JValue) -> JValue {
  jval_set(if o is Obj(_) { o } else { Obj([]) }, k, v)
}

///|
/// `delete o[k]` (each entry of that key); what is not an object is given back as it is.
pub fn jval_del(o : JValue, k : String) -> JValue {
  guard o is Obj(fs) else { return o }
  let ku = units(k)
  Obj(fs.filter(f => f.0 != ku))
}

///|
/// `{ ...a, ...b }`: what is not an object adds nothing.
pub fn jval_spread(a : JValue, b : JValue) -> JValue {
  let mut out = if a is Obj(_) { a } else { Obj([]) }
  if b is Obj(fs) {
    for f in fs {
      out = jval_set(out, text(f.0), f.1)
    }
  }
  out
}

///|
/// `!!v`, undefined (none) false.
pub fn jval_truthy(v : JValue?) -> Bool {
  match v {
    None | Some(Null) | Some(Bool(false)) => false
    Some(Num(n)) => n != 0.0 && !n.is_nan()
    Some(Str(u)) => u.length() > 0
    Some(_) => true
  }
}

///|
/// The value as MoonBit's JSON with well-formed strings (`text`: lone surrogates as U+FFFD) and entries in insertion
/// order, numbers kept as given.
pub fn JValue::to_json_lossy(self : JValue) -> Json {
  match self {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Num(n) => Json::number(n)
    Str(u) => Json::string(text(u))
    Arr(xs) => Json::array(xs.map(JValue::to_json_lossy))
    Obj(fs) => {
      let m : Map[String, Json] = Map([])
      for f in fs {
        m[text(f.0)] = f.1.to_json_lossy()
      }
      Json::object(m)
    }
  }
}

///|
/// `JSON.parse(text)`, None where it throws.
pub fn jval_try_parse(text : String) -> JValue? {
  Some(parse(text)) catch {
    _ => None
  }
}

///|
/// `v[name]` where `v` is an object: a repeated key's last entry (as JSON.parse keeps it).
pub fn jval_at_last(v : JValue?, name : String) -> JValue? {
  match v {
    Some(Obj(fs)) => {
      let ku = units(name)
      let mut found = None
      for f in fs {
        if f.0 == ku {
          found = Some(f.1)
        }
      }
      found
    }
    _ => None
  }
}

///|
/// `v?.[a]?.[b]…` (repeated key's first entry, via `jval_at`).
pub fn jval_at_path(v : JValue?, path : Array[String]) -> JValue? {
  let mut cur = v
  for k in path {
    cur = jval_at(cur, k)
  }
  cur
}

///|
/// `v?.[a]?.[b]…` (repeated key's last entry, via `jval_at_last`).
pub fn jval_at_path_last(v : JValue?, path : Array[String]) -> JValue? {
  let mut cur = v
  for k in path {
    cur = jval_at_last(cur, k)
  }
  cur
}

///|
/// `typeof v === "string" ? v : ""` (`text`: a lone surrogate as U+FFFD).
pub fn jval_text(v : JValue?) -> String {
  jval_str_of(v).unwrap_or("")
}

///|
/// The array's items, or `[]` for anything else.
pub fn jval_arr(v : JValue?) -> Array[JValue] {
  jval_arr_of(v).unwrap_or([])
}

///|
/// An object's entries as `(name, value)` pairs (`text` on keys); `[]` for anything else.
pub fn jval_entries(v : JValue?) -> Array[(String, JValue)] {
  match v {
    Some(Obj(fs)) => fs.map(f => (text(f.0), f.1))
    _ => []
  }
}

///|
/// `String(v)`, `None` (undefined) as `"undefined"`, `null` inside an array as `""`.
pub fn jval_js_str(v : JValue?) -> String {
  match v {
    None => "undefined"
    Some(Null) => "null"
    Some(Str(u)) => text(u)
    Some(Bool(b)) => if b { "true" } else { "false" }
    Some(Num(d)) => num_text(d)
    Some(Arr(xs)) =>
      xs
      .map(x => match x {
        Null => ""
        _ => jval_js_str(Some(x))
      })
      .join(",")
    Some(Obj(_)) => "[object Object]"
  }
}

///|
/// `Number(v)` as JavaScript converts a value (`None` -> NaN, `Null` -> 0, `""` / `" "` -> 0, `[null]` -> 0).
pub fn jval_js_num(v : JValue?) -> Double {
  match v {
    None => @double.not_a_number
    Some(Null) => 0.0
    Some(Bool(b)) => if b { 1.0 } else { 0.0 }
    Some(Num(d)) => d
    Some(Str(u)) => js_number(text(u))
    Some(Arr(xs)) =>
      match xs {
        [] => 0.0
        [Null] => 0.0
        [x] => js_number(jval_js_str(Some(x)))
        _ => @double.not_a_number
      }
    Some(Obj(_)) => @double.not_a_number
  }
}

///|
/// `Number.isInteger(v)`.
pub fn jval_is_integer(v : JValue?) -> Bool {
  v is Some(Num(d)) && is_integer(d)
}

///|
/// `Number.isSafeInteger(v)`.
pub fn jval_safe_int(v : JValue?) -> Bool {
  v is Some(Num(d)) && is_safe_integer(d)
}

///|
/// `v == null`, undefined (none) too.
pub fn jval_nullish(v : JValue?) -> Bool {
  v is (None | Some(Null))
}
