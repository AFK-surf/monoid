// JSON as the TypeScript it is written from reads and writes it (station/mb's jsjson: JSON.parse, JSON.stringify, an
// object's keys in the order they were put), and the few ways of reading a value the station's code goes by
// (`typeof v === "string"`, `Array.isArray`, a field of what may be anything).

///|
using @jsjson {type JValue as J}

///|
/// What the TypeScript threw: its message as it says it (`new Error(message)`), and of what kind where a caller tells
/// kinds apart (`instanceof Refused`, `PlaceRefused` with its code, `MessageWriteBusy`...); "" for a plain Error.
pub(all) suberror Thrown {
  Thrown(String, String)
}

///|
pub impl Show for Thrown with output(self, logger) {
  match self {
    Thrown(_, m) => logger.write_string(m)
  }
}

///|
/// A plain Error of `message`.
pub fn fail_(message : String) -> Thrown {
  Thrown("", message)
}

///|
pub fn thrown_message(e : Error) -> String {
  match e {
    Thrown(_, m) => m
    Failure(m) => m
    e => e.to_string()
  }
}

///|
pub fn thrown_kind(e : Error) -> String {
  match e {
    Thrown(k, _) => k
    _ => ""
  }
}

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
pub fn jb(b : Bool) -> J {
  @jsjson.JValue::of_bool(b)
}

///|
pub fn jo(fields : Array[(String, J)]) -> J {
  @jsjson.JValue::of_object(fields)
}

///|
pub fn ja(items : Array[J]) -> J {
  @jsjson.JValue::of_array(items)
}

///|
pub fn jsa(items : Array[String]) -> J {
  @jsjson.JValue::of_strings(items)
}

///|
pub fn jopt(s : String?) -> J {
  @jsjson.JValue::of_opt_string(s)
}

///|
/// `v[name]`, undefined (None) where `v` is no object or has none.
pub fn at(v : J?, name : String) -> J? {
  @jsjson.jval_at(v, name)
}

///|
pub fn at_i(v : J?, i : Int) -> J? {
  @jsjson.jval_at_i(v, i)
}

///|
/// The value when it is a string.
pub fn str_of(v : J?) -> String? {
  @jsjson.jval_str_of(v)
}

///|
pub fn num_of(v : J?) -> Double? {
  @jsjson.jval_num_of(v)
}

///|
pub fn bool_of(v : J?) -> Bool? {
  @jsjson.jval_bool_of(v)
}

///|
pub fn arr_of(v : J?) -> Array[J]? {
  @jsjson.jval_arr_of(v)
}

///|
pub fn is_null(v : J?) -> Bool {
  v is Some(Null)
}

///|
/// `v == null` (undefined or null).
pub fn nullish(v : J?) -> Bool {
  @jsjson.jval_nullish(v)
}

///|
pub fn is_obj(v : J?) -> Bool {
  v is Some(Obj(_))
}

///|
/// An object's own keys, as `Object.keys` gives them (the order jsjson keeps: integer-like ones first).
pub fn keys_of(v : J?) -> Array[String] {
  match v {
    Some(o) => @jsjson.jval_keys_of(o)
    None => []
  }
}

///|
/// An object's field set (or added at its end), as `o[k] = v` does.
pub fn set_field(o : J, k : String, v : J) -> J {
  @jsjson.jval_set(o, k, v)
}

///|
/// An object without field `k` (`delete o[k]`, or a destructuring leaving it out).
pub fn without(o : J, ks : Array[String]) -> J {
  match o {
    Obj(fs) => {
      let us = ks.map(@jsjson.units)
      Obj(fs.filter(f => !us.contains(f.0)))
    }
    other => other
  }
}

///|
/// `{ ...a, ...b }`.
pub fn spread(a : J, b : J) -> J {
  @jsjson.jval_spread(a, b)
}

///|
pub fn stringify(v : J) -> String {
  @jsjson.stringify(v)
}

///|
/// `JSON.stringify(s)` of a string.
pub fn quoted(s : String) -> String {
  @jsjson.stringify(js(s))
}

///|
/// The value parsed, or a thrown SyntaxError's message.
pub fn parse_js(text : String) -> J raise Thrown {
  @jsjson.parse(text) catch {
    @jsjson.SyntaxError(m) => raise Thrown("SyntaxError", m)
  }
}

///|
/// A string's code points (`Array.from(s)`).
pub fn chars(s : String) -> Array[String] {
  @jsjson.points(s)
}

///|
pub fn char_count(s : String) -> Int {
  @jsjson.code_points(s)
}

///|
/// `Array.from(s).slice(0, n).join("")`.
pub fn first_chars(s : String, n : Int) -> String {
  @jsjson.chars(s, n)
}

///|
/// What `String(n)` says of a number that is a safe integer or any double (JavaScript's).
pub fn num_text(d : Double) -> String {
  @jsjson.stringify(Num(d))
}

///|
/// `a === b` for what JSON gives (an object or a list: the same where they hold the same, as the copies here are).
pub fn jeq(a : J, b : J) -> Bool {
  match (a, b) {
    (Null, Null) => true
    (Bool(x), Bool(y)) => x == y
    (Num(x), Num(y)) => x == y
    (Str(x), Str(y)) => x == y
    (Arr(xs), Arr(ys)) => xs.length() == ys.length() && xs.iter().zip(ys.iter()).all(p => jeq(p.0, p.1))
    (Obj(xs), Obj(ys)) =>
      xs.length() == ys.length() && xs.iter().zip(ys.iter()).all(p => p.0.0 == p.1.0 && jeq(p.0.1, p.1.1))
    _ => false
  }
}

///|
/// `xs.includes(v)`.
pub fn jincludes(xs : Array[J], v : J) -> Bool {
  xs.iter().any(x => jeq(x, v))
}

///|
/// The value parsed, None where it does not parse.
pub fn parse_opt(text : String) -> J? {
  @jsjson.jval_try_parse(text)
}

///|
/// Whether JavaScript takes a value for true (`!!v`).
pub fn truthy(v : J?) -> Bool {
  @jsjson.jval_truthy(v)
}

///|
/// What stands for `undefined` in what is said to the station.
pub fn undefined_j() -> J {
  jo([("$u", ji(1))])
}
