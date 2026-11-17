// What the TypeScript this package is written from leans on of JavaScript itself: `String.prototype.trim`'s
// whitespace, `Number(string)`, `String(number)`, `Math.round`, `>>> 0` and `JSON.stringify`, so what is worked out
// here is the same to the code unit.

///|
/// Whether `c` (a UTF-16 code unit) is what `String.prototype.trim` takes off: WhiteSpace and LineTerminator.
pub fn js_space(c : Int) -> Bool {
  match c {
    0x09 | 0x0a | 0x0b | 0x0c | 0x0d | 0x20 | 0xa0 | 0x1680 | 0x2028 | 0x2029 | 0x202f | 0x205f | 0x3000 | 0xfeff =>
      true
    _ => c >= 0x2000 && c <= 0x200a
  }
}

///|
/// `s.trim()`.
pub fn js_trim(s : String) -> String {
  let mut from = 0
  let mut to = s.length()
  while from < to && js_space(s.code_unit_at(from).to_int()) {
    from += 1
  }
  while to > from && js_space(s.code_unit_at(to - 1).to_int()) {
    to -= 1
  }
  s.clamped_view(start=from, end=to).to_owned()
}

///|
fn is_digit(c : Int) -> Bool {
  c >= 0x30 && c <= 0x39
}

///|
fn digit_of(c : Int, radix : Int) -> Int? {
  let d = if is_digit(c) {
    c - 0x30
  } else if c >= 0x61 && c <= 0x7a {
    c - 0x61 + 10
  } else if c >= 0x41 && c <= 0x5a {
    c - 0x41 + 10
  } else {
    return None
  }
  if d < radix {
    Some(d)
  } else {
    None
  }
}

///|
/// `Number(s)` of a string (NaN where it is no number).
pub fn js_number(s : String) -> Double {
  let t = js_trim(s)
  let n = t.length()
  if n == 0 {
    return 0.0
  }
  let at = (i : Int) => t.code_unit_at(i).to_int()
  // 0x, 0o, 0b: no sign before them
  if n > 2 && at(0) == 0x30 {
    let radix = match at(1) {
      0x78 | 0x58 => 16
      0x6f | 0x4f => 8
      0x62 | 0x42 => 2
      _ => 0
    }
    if radix > 0 {
      let mut v = 0.0
      for i in 2..<n {
        match digit_of(at(i), radix) {
          Some(d) => v = v * radix.to_double() + d.to_double()
          None => return @double.not_a_number
        }
      }
      return v
    }
  }
  let mut i = 0
  let mut negative = false
  if at(0) == 0x2b || at(0) == 0x2d {
    negative = at(0) == 0x2d
    i = 1
  }
  let rest = t.clamped_view(start=i).to_owned()
  if rest == "Infinity" {
    return if negative { @double.neg_infinity } else { @double.infinity }
  }
  // StrUnsignedDecimalLiteral: digits [. digits?] | . digits, then [eE][+-]digits
  let int_from = i
  while i < n && is_digit(at(i)) {
    i += 1
  }
  let int_digits = i - int_from
  let mut frac_digits = 0
  let mut frac_from = i
  if i < n && at(i) == 0x2e {
    i += 1
    frac_from = i
    while i < n && is_digit(at(i)) {
      i += 1
    }
    frac_digits = i - frac_from
  }
  if int_digits == 0 && frac_digits == 0 {
    return @double.not_a_number
  }
  let mut exp = ""
  if i < n && (at(i) == 0x65 || at(i) == 0x45) {
    let e_from = i + 1
    i += 1
    if i < n && (at(i) == 0x2b || at(i) == 0x2d) {
      i += 1
    }
    let d_from = i
    while i < n && is_digit(at(i)) {
      i += 1
    }
    if i == d_from {
      return @double.not_a_number
    }
    exp = "e" + t.clamped_view(start=e_from, end=i).to_owned()
  }
  if i != n {
    return @double.not_a_number
  }
  let int_part = if int_digits == 0 {
    "0"
  } else {
    t.clamped_view(start=int_from, end=int_from + int_digits).to_owned()
  }
  let frac_part = if frac_digits == 0 {
    "0"
  } else {
    t.clamped_view(start=frac_from, end=frac_from + frac_digits).to_owned()
  }
  let v = @string.parse_double(int_part + "." + frac_part + exp) catch {
    _ => return @double.not_a_number
  }
  if negative {
    -v
  } else {
    v
  }
}

///|
/// `Number.isInteger(n)`.
pub fn js_is_integer(n : Double) -> Bool {
  !n.is_nan() && n != @double.infinity && n != @double.neg_infinity && n.floor() == n
}

///|
/// `Math.round(n)`: halves up, towards +∞.
pub fn js_round(n : Double) -> Double {
  if n.is_nan() || n == @double.infinity || n == @double.neg_infinity {
    return n
  }
  (n + 0.5).floor()
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
  if n.is_nan() {
    "NaN"
  } else if n == @double.infinity {
    "Infinity"
  } else if n == @double.neg_infinity {
    "-Infinity"
  } else {
    @jsjson.stringify(Num(n))
  }
}

///|
/// A value as JavaScript holds it (`JSON.parse` of its text): keys in its order, as `JSON.stringify` writes them.
pub fn jvalue(v : Json) -> @jsjson.JValue {
  match v {
    Null => Null
    True => Bool(true)
    False => Bool(false)
    Number(n, ..) => Num(n)
    String(s) => Str(@jsjson.units(s))
    Array(xs) => Arr(xs.map(jvalue))
    Object(m) => {
      let out : Array[(Array[Int], @jsjson.JValue)] = []
      for k, x in m {
        out.push((@jsjson.units(k), jvalue(x)))
      }
      Obj(out)
    }
  }
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
    Some(Number(n, ..)) if !n.is_nan() && n != @double.infinity && n != @double.neg_infinity => Some(n)
    _ => None
  }
}
