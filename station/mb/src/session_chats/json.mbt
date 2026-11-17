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
  Str(@jsjson.units(s))
}

///|
pub fn jn(d : Double) -> J {
  Num(d)
}

///|
pub fn ji(i : Int) -> J {
  Num(i.to_double())
}

///|
pub fn jb(b : Bool) -> J {
  Bool(b)
}

///|
pub fn jo(fields : Array[(String, J)]) -> J {
  Obj(fields.map(f => (@jsjson.units(f.0), f.1)))
}

///|
pub fn ja(items : Array[J]) -> J {
  Arr(items)
}

///|
pub fn jsa(items : Array[String]) -> J {
  Arr(items.map(js))
}

///|
pub fn jopt(s : String?) -> J {
  match s {
    Some(t) => js(t)
    None => Null
  }
}

///|
/// `v[name]`, undefined (None) where `v` is no object or has none.
pub fn at(v : J?, name : String) -> J? {
  match v {
    Some(Obj(_) as o) => o.get(name)
    _ => None
  }
}

///|
pub fn at_i(v : J?, i : Int) -> J? {
  match v {
    Some(Arr(xs)) => if i >= 0 && i < xs.length() { Some(xs[i]) } else { None }
    _ => None
  }
}

///|
/// The value when it is a string.
pub fn str_of(v : J?) -> String? {
  match v {
    Some(Str(u)) => Some(@jsjson.text(u))
    _ => None
  }
}

///|
pub fn num_of(v : J?) -> Double? {
  match v {
    Some(Num(d)) => Some(d)
    _ => None
  }
}

///|
pub fn bool_of(v : J?) -> Bool? {
  match v {
    Some(Bool(b)) => Some(b)
    _ => None
  }
}

///|
pub fn arr_of(v : J?) -> Array[J]? {
  match v {
    Some(Arr(xs)) => Some(xs)
    _ => None
  }
}

///|
pub fn is_null(v : J?) -> Bool {
  v is Some(Null)
}

///|
/// `v == null` (undefined or null).
pub fn nullish(v : J?) -> Bool {
  match v {
    None | Some(Null) => true
    _ => false
  }
}

///|
pub fn is_obj(v : J?) -> Bool {
  v is Some(Obj(_))
}

///|
/// An object's own keys, as `Object.keys` gives them (the order jsjson keeps: integer-like ones first).
pub fn keys_of(v : J?) -> Array[String] {
  match v {
    Some(Obj(fs)) => fs.map(f => @jsjson.text(f.0))
    _ => []
  }
}

///|
/// An object's field set (or added at its end), as `o[k] = v` does.
pub fn set_field(o : J, k : String, v : J) -> J {
  match o {
    Obj(fs) => {
      let ku = @jsjson.units(k)
      let out = fs.copy()
      match out.search_by(f => f.0 == ku) {
        Some(i) => out[i] = (ku, v)
        None => out.push((ku, v))
      }
      Obj(out)
    }
    other => other
  }
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
  let mut out = match a {
    Obj(_) => a
    _ => Obj([])
  }
  match b {
    Obj(fs) => for f in fs { out = set_field(out, @jsjson.text(f.0), f.1) }
    _ => ()
  }
  out
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
  let out = []
  for c in s {
    out.push(c.to_string())
  }
  out
}

///|
pub fn char_count(s : String) -> Int {
  let mut n = 0
  for _ in s {
    n += 1
  }
  n
}

///|
/// `Array.from(s).slice(0, n).join("")`.
pub fn first_chars(s : String, n : Int) -> String {
  let out = StringBuilder::new()
  let mut i = 0
  for c in s {
    if i >= n {
      break
    }
    out.write_char(c)
    i += 1
  }
  out.to_string()
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
  try Some(@jsjson.parse(text)) catch {
    _ => None
  }
}

///|
/// Whether JavaScript takes a value for true (`!!v`).
pub fn truthy(v : J?) -> Bool {
  match v {
    None | Some(Null) | Some(Bool(false)) => false
    Some(Num(n)) => n != 0.0 && !n.is_nan()
    Some(Str(u)) => u.length() > 0
    Some(_) => true
  }
}

///|
/// What stands for `undefined` in what is said to the station.
pub fn undefined_j() -> J {
  jo([("$u", ji(1))])
}
