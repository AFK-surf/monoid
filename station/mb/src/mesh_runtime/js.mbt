// What the TypeScript this package is written from leans on of JavaScript itself: `String.prototype.trim`'s
// whitespace, `Number(string)`, `String(number)`, `Math.round`, `>>> 0` and `JSON.stringify`, so what is worked out
// here is the same to the code unit.

///|
/// Whether `c` (a UTF-16 code unit) is what `String.prototype.trim` takes off: WhiteSpace and LineTerminator.
pub fn js_space(c : Int) -> Bool {
  @jscase.is_space(c)
}

///|
/// `s.trim()`.
pub fn js_trim(s : String) -> String {
  @jscase.trim(s)
}

///|
fn is_digit(c : Int) -> Bool {
  c >= 0x30 && c <= 0x39
}

///|
/// `Number(s)` of a string (NaN where it is no number).
pub fn js_number(s : String) -> Double {
  @jsjson.js_number(s)
}

///|
/// `Number.isInteger(n)`.
pub fn js_is_integer(n : Double) -> Bool {
  @jsjson.is_integer(n)
}

///|
/// `Math.round(n)`: halves up, towards +∞.
pub fn js_round(n : Double) -> Double {
  @jsjson.js_round(n)
}

///|
/// `n >>> 0`: ToUint32, as a Double.
pub fn to_uint32(n : Double) -> Double {
  if n.is_nan() || n == @double.infinity || n == @double.neg_infinity {
    return 0.0
  }
  let t = n.trunc()
  let m = 4294967296.0
  let r = t - (t / m).floor() * m
  if r == m {
    0.0
  } else {
    r
  }
}

///|
/// `String(n)`.
pub fn js_num(n : Double) -> String {
  @jsjson.num_text(n)
}

///|
/// A value as JavaScript holds it (`JSON.parse` of its text): keys in its order, as `JSON.stringify` writes them.
pub fn jvalue(v : Json) -> @jsjson.JValue {
  @jsjson.JValue::of_json(v)
}

///|
/// `JSON.stringify(v)` of a value read from JSON. (An object's integer-like keys first, as JavaScript keeps them.)
pub fn js_stringify(v : Json) -> String {
  let text = @jsjson.stringify(jvalue(v))
  // through JavaScript's own reading, so its keys' order is its
  @jsjson.stringify(@jsjson.parse(text)) catch {
    _ => text
  }
}

///|
/// `JSON.stringify(s)` of a string.
pub fn js_quote(s : String) -> String {
  @jsjson.stringify(Str(@jsjson.units(s)))
}

///|
fn jnum(n : Double) -> Json {
  Json::number(n)
}

///|
fn jstr(s : String) -> Json {
  Json::string(s)
}

///|
fn jobj(fields : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for f in fields {
    m[f.0] = f.1
  }
  Json::object(m)
}

///|
fn field(v : Json, k : String) -> Json? {
  match v {
    Object(m) => m.get(k)
    _ => None
  }
}

///|
fn num_of(v : Json?) -> Double? {
  match v {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
fn str_of(v : Json?) -> String? {
  match v {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// A finite number (`typeof v === "number" && Number.isFinite(v)`).
fn finite(v : Json?) -> Double? {
  match v {
    Some(Number(n, ..)) if @jsjson.is_finite(n) => Some(n)
    _ => None
  }
}
