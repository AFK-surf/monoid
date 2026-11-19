// Values as JavaScript has them (`JV` is an alias of `JValue`) and what JavaScript asks of them: a field, its type,
// `String(v)`, a whole number, an object put together in JavaScript's order of keys. One type for every package that
// reads JavaScript's values (the admin API's routes, the accounts, Feishu): each re-exports what it uses
// (`pub using @jsjson { type JV, ... }`). Where a name is JValue's too here (`parse`, `stringify`, `js_string`) it is
// `jv_`'s, re-exported under its own name.

///|
/// Sanitize lone surrogates in strings and object keys to U+FFFD (zero-allocation fast path when clean).
pub fn JValue::of_js(v : JValue) -> JValue {
  match v {
    Null | Bool(_) | Num(_) => v
    Str(s) => Str(sanitize_str(s))
    Arr(a) => Arr(a.map(JValue::of_js))
    Obj(f) => Obj(f.map(p => (sanitize_str(p.0), JValue::of_js(p.1))))
  }
}

///|
/// Zero-cost identity (retained for callers that keep lone surrogates).
pub fn JValue::of_js_raw(v : JValue) -> JValue {
  v
}

///|
/// Zero-cost identity (`JV` and `JValue` are the same type).
pub fn JValue::to_js(v : JValue) -> JValue {
  v
}

///|
pub fn js(s : String) -> JV { Str(s) }

///|
pub fn jnum(n : Double) -> JV { Num(n) }

///|
pub fn jint(n : Int32) -> JV { Num(n.to_double()) }

///|
pub fn jbool(b : Bool) -> JV { Bool(b) }

///|
pub fn jarr(items : Array[JV]) -> JV { Arr(items) }

///|
pub fn jstrs(items : Array[String]) -> JV { Arr(items.map(js)) }

///|
pub fn jopt(s : String?) -> JV {
  match s {
    Some(v) => Str(v)
    None => Null
  }
}

///|
/// An object of these fields in this order (as a literal writes them: integer-like keys first, as JavaScript does).
pub fn jobj(fields : Array[(String, JV)]) -> JV {
  let o = JValue::Obj(Array::new(capacity=fields.length()))
  for f in fields {
    o.put(f.0, f.1)
  }
  o
}

///|
/// `o[k] = v` in place (an object's own array): where it was, else where JavaScript puts a new key.
pub fn JValue::put(self : JValue, k : String, v : JValue) -> Unit {
  guard self is Obj(fields) else { return }
  for i in 0..<fields.length() {
    if fields[i].0 == k {
      fields[i] = (k, v)
      return
    }
  }
  match index_key(k) {
    Some(n) => {
      let mut at = 0
      while at < fields.length() {
        match index_key(fields[at].0) {
          Some(m) if m < n => at += 1
          _ => break
        }
      }
      fields.insert(at, (k, v))
    }
    None => fields.push((k, v))
  }
}

///|
/// `delete o[k]` in place.
pub fn JValue::delete(self : JValue, k : String) -> Unit {
  guard self is Obj(fields) else { return }
  for i in 0..<fields.length() {
    if fields[i].0 == k {
      fields.remove(i) |> ignore
      return
    }
  }
}

///|
/// `o[k] = v` in place.
pub fn jput(o : JV, k : String, v : JV) -> Unit { o.put(k, v) }

///|
/// `delete o[k]` in place.
pub fn jdelete(o : JV, k : String) -> Unit { o.delete(k) }

///|
/// `v?.[i]` of an array.
pub fn jat(v : JV?, i : Int) -> JV? { jval_at_i(v, i) }

///|
/// An object's keys as `Object.keys` gives them: integer-like ones first, ascending.
pub fn jkeys(v : JV) -> Array[String] { v.keys() }

///|
/// `Object.values(v)` (of an object, an array, a string; nothing of anything else).
pub fn jvalues(v : JV) -> Array[JV] {
  match v {
    Obj(f) => ordered(f).map(e => e.1)
    Arr(a) => a
    Str(s) => {
      let out = Array::new(capacity=s.length())
      for i in 0..<s.length() {
        out.push(JValue::Str(s.unsafe_substring(start=i, end=i + 1)))
      }
      out
    }
    _ => []
  }
}

///|
/// `o[k] = v` (or `{...o, [k]: v}`): in place where it was, else where JavaScript puts a new key.
pub fn jset(o : JV, k : String, v : JV) -> JV {
  let out = JValue::Obj(match o {
    Obj(f) => f.copy()
    _ => []
  })
  out.put(k, v)
  out
}

///|
/// `delete o[k]`.
pub fn jdel(o : JV, k : String) -> JV { jval_del(o, k) }

///|
/// `{...a, ...b}`: b's fields over a's.
pub fn jspread(a : JV, b : JV) -> JV {
  let out = JValue::Obj(match a {
    Obj(f) => f.copy()
    _ => []
  })
  if b is Obj(fields) {
    for f in fields {
      out.put(f.0, f.1)
    }
  }
  out
}

///|
/// `v[k]`: None where it is not an object or has no such field (JavaScript's undefined).
pub fn jget(v : JV?, k : String) -> JV? { jval_at(v, k) }

///|
/// `k in v` for an object.
pub fn jhas(v : JV, k : String) -> Bool { v is Obj(_) && v.get(k) is Some(_) }

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
pub fn jnumber(v : JV?) -> Double? { jval_num_of(v) }

///|
pub fn is_object(v : JV?) -> Bool { v is Some(Obj(_)) }

///|
pub fn is_array(v : JV?) -> Bool { v is Some(Arr(_)) }

///|
/// `v !== null && typeof v === "object"` (an array too).
pub fn is_objectish(v : JV?) -> Bool { v is Some(Obj(_) | Arr(_)) }

///|
pub fn jitems(v : JV?) -> Array[JV] { jval_arr(v) }

///|
pub fn jfields(v : JV?) -> Array[(String, JV)] {
  match v {
    Some(Obj(f)) => f
    _ => []
  }
}

///|
/// JSON.stringify(v).
pub fn jv_stringify(v : JV) -> String { stringify(v) }

///|
/// JSON.stringify(v) where v may be undefined (None: undefined, which JSON.stringify gives back as undefined).
pub fn stringify_opt(v : JV?) -> String? {
  match v {
    Some(x) => Some(stringify(x))
    None => None
  }
}

///|
/// JSON.parse(text).
pub fn jv_parse(text : String) -> JV raise SyntaxError { JValue::of_js(parse(text)) }

///|
/// JSON.parse(text), keeping lone surrogates in strings and keys.
pub fn jv_parse_raw(text : String) -> JV raise SyntaxError { parse(text) }

///|
/// JSON.parse(text) keeping lone surrogates, None where it throws.
pub fn try_parse_raw(text : String) -> JV? { jval_try_parse(text) }

///|
/// Number.isFinite.
pub fn is_finite(d : Double) -> Bool {
  !d.is_nan() && !d.is_inf()
}

///|
/// Math.round: half way up toward +∞, `-0.5 <= d < 0` to `-0.0`, NaN and infinities unchanged.
pub fn js_round(d : Double) -> Double {
  if !is_finite(d) {
    return d
  }
  if d >= -0.5 && d < 0.0 {
    return -0.0
  }
  let f = d.floor()
  if d - f >= 0.5 {
    f + 1.0
  } else {
    f
  }
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
  // (leading zeros JSON refuses: "007" is 7)
  let mut z = 0
  while z + 1 < body.length() &&
        body.unsafe_charcode_at(z) == '0' &&
        body.unsafe_charcode_at(z + 1) >= '0' &&
        body.unsafe_charcode_at(z + 1) <= '9' {
    z += 1
  }
  body = body.unsafe_substring(start=z, end=body.length())
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
/// Whether a UTF-16 code unit is JavaScript whitespace or a line terminator.
pub fn is_js_space(c : Int) -> Bool {
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

///|
/// String.prototype.trim: JavaScript's white space and line terminators off both ends.
pub fn trim_js(s : String) -> String {
  let mut a = 0
  let mut b = s.length()
  while a < b && is_js_space(s.unsafe_charcode_at(a)) {
    a += 1
  }
  while b > a && is_js_space(s.unsafe_charcode_at(b - 1)) {
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
  @utf8.encode(sanitize_str(s))
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
pub fn JValue::filter_undef(self : JValue) -> JValue {
  match self {
    Obj(f) => Obj(f.filter(p => !is_undef(p.1)))
    _ => self
  }
}

///|
/// JSON.stringify(v, null, 2).
pub fn jv_stringify_pretty(v : JV) -> String { stringify_pretty(v) }

///|
/// `s.slice(start, end)` by UTF-16 code units, negative indices from the end, clamped as JavaScript clamps them.
pub fn js_slice(s : String, start : Int, end? : Int) -> String {
  let n = s.length()
  let norm = (i : Int) => if i < 0 {
    if n + i < 0 { 0 } else { n + i }
  } else if i > n {
    n
  } else {
    i
  }
  let a = norm(start)
  let b = norm(end.unwrap_or(n))
  if b <= a {
    ""
  } else {
    s.unsafe_substring(start=a, end=b)
  }
}

///|
/// `s.indexOf(needle, from)` by UTF-16 code units, -1 where it is not found.
pub fn js_index_of(s : String, needle : String, from? : Int = 0) -> Int {
  let n = s.length()
  let m = needle.length()
  let start = if from < 0 { 0 } else { from }
  if m == 0 {
    return if start > n { n } else { start }
  }
  let mut i = start
  while i + m <= n {
    let mut k = 0
    while k < m && s.unsafe_charcode_at(i + k) == needle.unsafe_charcode_at(k) {
      k += 1
    }
    if k == m {
      return i
    }
    i += 1
  }
  -1
}

///|
/// `s.lastIndexOf(needle)` by UTF-16 code units, -1 where it is not found.
pub fn js_last_index_of(s : String, needle : String) -> Int {
  let n = s.length()
  let m = needle.length()
  if m > n {
    return -1
  }
  let mut i = n - m
  while i >= 0 {
    let mut k = 0
    while k < m && s.unsafe_charcode_at(i + k) == needle.unsafe_charcode_at(k) {
      k += 1
    }
    if k == m {
      return i
    }
    i -= 1
  }
  -1
}

///|
/// `s.split(sep)` with a plain string separator: empty parts kept, empty separator splits each UTF-16 code unit.
pub fn js_split(s : String, sep : String) -> Array[String] {
  let out = []
  if sep == "" {
    for i in 0..<s.length() {
      out.push(s.unsafe_substring(start=i, end=i + 1))
    }
    return out
  }
  let mut at = 0
  while true {
    let i = js_index_of(s, sep, from=at)
    if i < 0 {
      out.push(s.unsafe_substring(start=at, end=s.length()))
      break
    }
    out.push(s.unsafe_substring(start=at, end=i))
    at = i + sep.length()
  }
  out
}
