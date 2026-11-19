// Values as JavaScript has them (JValue: JSON.parse and JSON.stringify exactly) with their strings as MoonBit's, and
// what JavaScript asks of them: a field, its type, `String(v)`, a whole number, an object put together in JavaScript's
// order of keys. One type for every package that reads JavaScript's values (the admin API's routes, the accounts,
// Feishu): each re-exports what it uses (`pub using @jsjson { type JV, ... }`). Where a name is JValue's too here
// (`parse`, `stringify`, `js_string`) it is `jv_`'s, re-exported under its own name.


///|
/// A JavaScript value as JSON has it.
#derive(Eq)
pub(all) enum JV {
  Null
  Bool(Bool)
  Num(Double)
  Str(String)
  Arr(Array[JV])
  /// keys and values, in JavaScript's order
  Obj(Array[(String, JV)])
}

///|
pub fn JV::of_js(v : JValue) -> JV {
  match v {
    Null => Null
    Bool(b) => Bool(b)
    Num(n) => Num(n)
    Str(u) => Str(text(u))
    Arr(a) => Arr(a.map(JV::of_js))
    Obj(f) => Obj(f.map(p => (text(p.0), JV::of_js(p.1))))
  }
}

///|
pub fn JV::to_js(v : JV) -> JValue {
  match v {
    Null => Null
    Bool(b) => Bool(b)
    Num(n) => Num(n)
    Str(s) => Str(units(s))
    Arr(a) => Arr(a.map(JV::to_js))
    Obj(f) => Obj(f.map(p => (units(p.0), JV::to_js(p.1))))
  }
}

///|
/// `v[k]` of an object.
pub fn JV::get(self : JV, k : String) -> JV? {
  match self {
    Obj(fields) => {
      for f in fields {
        if f.0 == k {
          return Some(f.1)
        }
      }
      None
    }
    _ => None
  }
}

///|
pub fn js(s : String) -> JV {
  Str(s)
}

///|
pub fn jnum(n : Double) -> JV {
  Num(n)
}

///|
pub fn jint(n : Int32) -> JV {
  Num(n.to_double())
}

///|
pub fn jbool(b : Bool) -> JV {
  Bool(b)
}

///|
pub fn jarr(items : Array[JV]) -> JV {
  Arr(items)
}

///|
pub fn jstrs(items : Array[String]) -> JV {
  Arr(items.map(js))
}

///|
pub fn jopt(s : String?) -> JV {
  match s {
    Some(v) => js(v)
    None => Null
  }
}

///|
/// An object of these fields in this order (as a literal writes them: integer-like keys first, as JavaScript does).
pub fn jobj(fields : Array[(String, JV)]) -> JV {
  let mut o = JV::Obj([])
  for f in fields {
    o = jset(o, f.0, f.1)
  }
  o
}

///|
/// A canonical array index (`0`, `12`, not `012`): what JavaScript puts first in an object, ascending.
fn index_key(k : String) -> Double? {
  if k.length() == 0 || k.length() > 10 {
    return None
  }
  if k.length() > 1 && k.unsafe_charcode_at(0) == '0' {
    return None
  }
  let mut n = 0.0
  for i in 0..<k.length() {
    let c = k.unsafe_charcode_at(i)
    if c < '0' || c > '9' {
      return None
    }
    n = n * 10.0 + (c - '0').to_double()
  }
  if n > 4294967294.0 {
    None
  } else {
    Some(n)
  }
}

///|
/// `o[k] = v` (or `{...o, [k]: v}`): in place where it was, else where JavaScript puts a new key.
pub fn jset(o : JV, k : String, v : JV) -> JV {
  let key = k
  let fields = match o {
    Obj(f) => f.copy()
    _ => []
  }
  for i in 0..<fields.length() {
    if fields[i].0 == key {
      fields[i] = (key, v)
      return Obj(fields)
    }
  }
  match index_key(key) {
    Some(n) => {
      let mut at = 0
      while at < fields.length() {
        match index_key(fields[at].0) {
          Some(m) if m < n => at += 1
          _ => break
        }
      }
      fields.insert(at, (key, v))
    }
    None => fields.push((key, v))
  }
  Obj(fields)
}

///|
/// `delete o[k]`.
pub fn jdel(o : JV, k : String) -> JV {
  let key = k
  match o {
    Obj(f) => Obj(f.filter(p => p.0 != key))
    _ => o
  }
}

///|
/// `{...a, ...b}`: b's fields over a's.
pub fn jspread(a : JV, b : JV) -> JV {
  let mut o = match a {
    Obj(_) => a
    _ => Obj([])
  }
  if b is Obj(fields) {
    for f in fields {
      o = jset(o, f.0, f.1)
    }
  }
  o
}

///|
/// `v[k]`: None where it is not an object or has no such field (JavaScript's undefined).
pub fn jget(v : JV?, k : String) -> JV? {
  match v {
    Some(Obj(_) as o) => o.get(k)
    _ => None
  }
}

///|
/// `k in v` for an object.
pub fn jhas(v : JV, k : String) -> Bool {
  v is Obj(_) && v.get(k) is Some(_)
}

///|
/// The string it is, if it is one.
pub fn jstr(v : JV?) -> String? {
  match v {
    Some(Str(u)) => Some(u)
    _ => None
  }
}

///|
/// The number it is, if it is one.
pub fn jnumber(v : JV?) -> Double? {
  match v {
    Some(Num(n)) => Some(n)
    _ => None
  }
}

///|
pub fn is_object(v : JV?) -> Bool {
  v is Some(Obj(_))
}

///|
pub fn is_array(v : JV?) -> Bool {
  v is Some(Arr(_))
}

///|
/// `v !== null && typeof v === "object"` (an array too).
pub fn is_objectish(v : JV?) -> Bool {
  v is Some(Obj(_) | Arr(_))
}

///|
pub fn jitems(v : JV?) -> Array[JV] {
  match v {
    Some(Arr(a)) => a
    _ => []
  }
}

///|
pub fn jfields(v : JV?) -> Array[(String, JV)] {
  match v {
    Some(Obj(f)) => f
    _ => []
  }
}

///|
/// JSON.stringify(v).
pub fn jv_stringify(v : JV) -> String {
  stringify(JV::to_js(v))
}

///|
/// JSON.stringify(v) where v may be undefined (None: undefined, which JSON.stringify gives back as undefined).
pub fn stringify_opt(v : JV?) -> String? {
  match v {
    Some(x) => Some(jv_stringify(x))
    None => None
  }
}

///|
/// JSON.parse(text).
pub fn jv_parse(text : String) -> JV raise SyntaxError {
  JV::of_js(parse(text))
}

///|
/// Number.isInteger.
pub fn is_integer(d : Double) -> Bool {
  !d.is_nan() && !d.is_inf() && d.floor() == d
}

///|
/// Number.isSafeInteger.
pub fn is_safe_integer(d : Double) -> Bool {
  is_integer(d) && d.abs() <= 9007199254740991.0
}

///|
/// A number as JavaScript writes it (`String(n)`).
pub fn num_text(d : Double) -> String {
  if d.is_nan() {
    "NaN"
  } else if d.is_inf() {
    if d > 0.0 {
      "Infinity"
    } else {
      "-Infinity"
    }
  } else {
    jv_stringify(Num(d))
  }
}

///|
/// String(v), as a template literal writes a value.
pub fn jv_js_string(v : JV?) -> String {
  match v {
    None => "undefined"
    Some(Null) => "null"
    Some(Bool(b)) => if b { "true" } else { "false" }
    Some(Num(d)) => num_text(d)
    Some(Str(u)) => u
    Some(Arr(items)) =>
      items
      .map(x => {
        match x {
          Null => ""
          _ => jv_js_string(Some(x))
        }
      })
      .join(",")
    Some(Obj(_)) => "[object Object]"
  }
}

///|
/// admin/mod.rs Input::text: JavaScript's `v ?? ""` as a string, anything else as JSON.
pub fn text_of(v : JV?) -> String {
  match v {
    None | Some(Null) => ""
    Some(Str(u)) => u
    Some(x) => jv_stringify(x)
  }
}

///|
/// Number(s) as JavaScript reads a string (whitespace trimmed, "" is 0, hex/octal/binary, Infinity; else NaN).
pub fn js_number(s : String) -> Double {
  let t = trim_js(s)
  if t == "" {
    return 0.0
  }
  if t == "Infinity" || t == "+Infinity" {
    return @double.infinity
  }
  if t == "-Infinity" {
    return @double.neg_infinity
  }
  if t.length() > 2 && t.unsafe_charcode_at(0) == '0' {
    let base = match t.unsafe_charcode_at(1) {
      'x' | 'X' => 16
      'o' | 'O' => 8
      'b' | 'B' => 2
      _ => 0
    }
    if base > 0 {
      let mut n = 0.0
      for i in 2..<t.length() {
        let c = t.unsafe_charcode_at(i)
        let d = if c >= '0' && c <= '9' {
          c - '0'
        } else if c >= 'a' && c <= 'z' {
          c - 'a' + 10
        } else if c >= 'A' && c <= 'Z' {
          c - 'A' + 10
        } else {
          99
        }
        if d >= base {
          return @double.not_a_number
        }
        n = n * base.to_double() + d.to_double()
      }
      return n
    }
  }
  // a decimal: [+-] digits [. digits] [e [+-] digits]
  let mut i = 0
  if t.unsafe_charcode_at(0) == '+' || t.unsafe_charcode_at(0) == '-' {
    i = 1
  }
  let digits_from = i
  let mut seen = false
  while i < t.length() &&
        t.unsafe_charcode_at(i) >= '0' &&
        t.unsafe_charcode_at(i) <= '9' {
    i += 1
    seen = true
  }
  if i < t.length() && t.unsafe_charcode_at(i) == '.' {
    i += 1
    while i < t.length() &&
          t.unsafe_charcode_at(i) >= '0' &&
          t.unsafe_charcode_at(i) <= '9' {
      i += 1
      seen = true
    }
  }
  if !seen {
    return @double.not_a_number
  }
  if i < t.length() &&
    (t.unsafe_charcode_at(i) == 'e' || t.unsafe_charcode_at(i) == 'E') {
    let mut j = i + 1
    if j < t.length() &&
      (t.unsafe_charcode_at(j) == '+' || t.unsafe_charcode_at(j) == '-') {
      j += 1
    }
    let from = j
    while j < t.length() &&
          t.unsafe_charcode_at(j) >= '0' &&
          t.unsafe_charcode_at(j) <= '9' {
      j += 1
    }
    if j == from {
      return @double.not_a_number
    }
    i = j
  }
  if i != t.length() {
    return @double.not_a_number
  }
  ignore(digits_from)
  // JSON's reader reads the same decimal text exactly (a leading + and a bare `.5` or `5.` aside)
  let mut body = t
  let neg = body.unsafe_charcode_at(0) == '-'
  if body.unsafe_charcode_at(0) == '+' || neg {
    body = body.unsafe_substring(start=1, end=body.length())
  }
  if body.unsafe_charcode_at(0) == '.' {
    body = "0" + body
  }
  body = body.replace_all(old=".e", new=".0e").replace_all(old=".E", new=".0E")
  if body.has_suffix(".") {
    body = body + "0"
  }
  let v = match try_parse(body) {
    Some(Num(n)) => n
    _ => @double.not_a_number
  }
  if neg {
    -v
  } else {
    v
  }
}

///|
/// String.prototype.trim: JavaScript's white space and line terminators off both ends.
pub fn trim_js(s : String) -> String {
  let space = c => {
    c == 0x09 ||
    c == 0x0a ||
    c == 0x0b ||
    c == 0x0c ||
    c == 0x0d ||
    c == 0x20 ||
    c == 0xa0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200a) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202f ||
    c == 0x205f ||
    c == 0x3000 ||
    c == 0xfeff
  }
  let mut a = 0
  let mut b = s.length()
  while a < b && space(s.unsafe_charcode_at(a)) {
    a += 1
  }
  while b > a && space(s.unsafe_charcode_at(b - 1)) {
    b -= 1
  }
  s.unsafe_substring(start=a, end=b)
}

///|
/// `[...s].slice(0, max).join("")`: the first `max` code points (a lone surrogate one of them).
pub fn chars(s : String, max : Int32) -> String {
  let mut i = 0
  let mut n = 0
  while i < s.length() && n < max {
    let c = s.unsafe_charcode_at(i)
    if c >= 0xd800 && c <= 0xdbff && i + 1 < s.length() {
      let d = s.unsafe_charcode_at(i + 1)
      if d >= 0xdc00 && d <= 0xdfff {
        i += 2
        n += 1
        continue
      }
    }
    i += 1
    n += 1
  }
  s.unsafe_substring(start=0, end=i)
}

///|
/// `[...s].length`.
pub fn code_points(s : String) -> Int32 {
  let mut i = 0
  let mut n = 0
  while i < s.length() {
    let c = s.unsafe_charcode_at(i)
    if c >= 0xd800 && c <= 0xdbff && i + 1 < s.length() {
      let d = s.unsafe_charcode_at(i + 1)
      if d >= 0xdc00 && d <= 0xdfff {
        i += 2
        n += 1
        continue
      }
    }
    i += 1
    n += 1
  }
  n
}

///|
/// The string's code points, each as a string (`[...s]`).
pub fn points(s : String) -> Array[String] {
  let out = []
  let mut i = 0
  while i < s.length() {
    let c = s.unsafe_charcode_at(i)
    let w = if c >= 0xd800 && c <= 0xdbff && i + 1 < s.length() {
      let d = s.unsafe_charcode_at(i + 1)
      if d >= 0xdc00 && d <= 0xdfff {
        2
      } else {
        1
      }
    } else {
      1
    }
    out.push(s.unsafe_substring(start=i, end=i + w))
    i += w
  }
  out
}

///|
/// Its UTF-8 bytes (a lone surrogate as U+FFFD, as Buffer.from does).
pub fn utf8(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
/// Bytes as UTF-8, lossily (Buffer's toString("utf8")).
pub fn utf8_text(b : Bytes) -> String {
  @utf8.decode_lossy(b)
}

///|
/// JSON.parse, None where it throws.
pub fn try_parse(text : String) -> JV? {
  Some(jv_parse(text)) catch {
    _ => None
  }
}

///|
/// JavaScript's order of two strings (`<`, by their UTF-16 code units).
pub fn js_compare(a : String, b : String) -> Int32 {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = a.unsafe_charcode_at(i)
    let y = b.unsafe_charcode_at(i)
    if x != y {
      return x - y
    }
  }
  a.length() - b.length()
}


///|
/// JavaScript's undefined where a value is passed on (an argument, an answer): what the station's parts are asked and
/// answer by, between the program and the TypeScript it stands for.
pub let jundef : JV = Obj([("$undef", Num(1.0))])

///|
pub fn is_undef(v : JV) -> Bool {
  v is Obj([(k, Num(_))]) && k == "$undef"
}

///|
/// The value as an option: None for undefined.
pub fn defined(v : JV) -> JV? {
  if is_undef(v) {
    None
  } else {
    Some(v)
  }
}

///|
/// The object without the fields that are undefined (as JSON leaves them out).
pub fn JV::filter_undef(self : JV) -> JV {
  match self {
    Obj(f) => Obj(f.filter(p => !is_undef(p.1)))
    _ => self
  }
}

///|
/// `@json.Json` as a JavaScript value: an object's fields in its order, integer-like keys first (as JavaScript puts
/// them).
pub fn JV::of_json(j : Json) -> JV {
  match j {
    Null => Null
    True => Bool(true)
    False => Bool(false)
    Number(n, ..) => Num(n)
    String(s) => Str(s)
    Array(a) => Arr(a.map(JV::of_json))
    Object(m) => {
      let mut o = JV::Obj([])
      for k, v in m {
        o = jset(o, k, JV::of_json(v))
      }
      o
    }
  }
}

///|
/// What JSON is to the rest of the program (`@json.Json`), as JSON.stringify writes it: a number that is not finite
/// is null.
pub fn JV::to_json(self : JV) -> Json {
  match self {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Num(n) => if n.is_nan() || n.is_inf() { Json::null() } else { Json::number(n) }
    Str(s) => Json::string(s)
    Arr(a) => Json::array(a.map(JV::to_json))
    Obj(fields) => {
      let m : Map[String, Json] = {}
      for f in fields {
        m[f.0] = f.1.to_json()
      }
      Json::object(m)
    }
  }
}

///|
/// JSON.stringify(v, null, 2).
pub fn jv_stringify_pretty(v : JV) -> String {
  stringify_pretty(JV::to_js(v))
}
