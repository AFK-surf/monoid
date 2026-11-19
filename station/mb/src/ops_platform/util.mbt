// What the ports of station/src/{ops,platform,resources,search,read} share: JavaScript's string methods as the
// TypeScript used them (UTF-16 code units, `split` keeping empty parts, `slice` with negative ends), numbers as
// `Number(...)` reads them and `String(n)` writes them, and the JSON a case is given and answered in.

///|
/// `s.slice(from, to)` in code units, clamped as JavaScript clamps it.
fn sub(s : String, from : Int, to : Int) -> String {
  let n = s.length()
  let a = if from < 0 { 0 } else if from > n { n } else { from }
  let b = if to < a { a } else if to > n { n } else { to }
  s.unsafe_substring(start=a, end=b)
}


///|
fn cu(s : String, i : Int) -> Int {
  s.unsafe_get(i).to_int()
}

///|
/// `s.indexOf(needle, from)`, -1 where it is not.
fn index_of(s : String, needle : String, from? : Int = 0) -> Int {
  @jsjson.js_index_of(s, needle, from~)
}

///|
/// `s.lastIndexOf(needle)`.
fn last_index_of(s : String, needle : String) -> Int {
  @jsjson.js_last_index_of(s, needle)
}

///|
fn starts(s : String, p : String) -> Bool {
  s.has_prefix(p)
}

///|
fn ends(s : String, p : String) -> Bool {
  s.has_suffix(p)
}

///|
fn has(s : String, p : String) -> Bool {
  s.contains(p)
}

///|
/// `s.split(sep)` with a string separator: every part, empty ones too.
fn split_on(s : String, sep : String) -> Array[String] {
  @jsjson.js_split(s, sep)
}

///|
/// `s.split(f)` where `f` says which code units separate (a one-unit character class, as `/[\\/]/`).
fn split_by(s : String, f : (Int) -> Bool) -> Array[String] {
  let out = []
  let mut at = 0
  for i in 0..<s.length() {
    if f(cu(s, i)) {
      out.push(sub(s, at, i))
      at = i + 1
    }
  }
  out.push(sub(s, at, s.length()))
  out
}

///|
/// `s.split(/f+/)`: runs of what `f` says separate.
fn split_runs(s : String, f : (Int) -> Bool) -> Array[String] {
  @jscase.split_by(s, f)
}

///|
/// `s.split(/\r?\n/)`.
fn split_lines(s : String) -> Array[String] {
  let parts = split_on(s, "\n")
  for i in 0..<(parts.length() - 1) {
    let p = parts[i]
    if ends(p, "\r") {
      parts[i] = sub(p, 0, p.length() - 1)
    }
  }
  parts
}

///|
/// JavaScript's `\s` (White_Space and the line terminators, U+FEFF).
fn js_space(c : Int) -> Bool {
  @jscase.is_white_space(c)
}

///|
/// `s.trim()`.
fn js_trim(s : String) -> String {
  @jscase.trim(s)
}

///|
fn js_trim_start(s : String) -> String {
  @jscase.trim_start_white(s)
}

///|
fn js_trim_end(s : String) -> String {
  @jscase.trim_end_white(s)
}

///|
fn is_digit(c : Int) -> Bool {
  c >= 48 && c <= 57
}

///|
fn is_upper(c : Int) -> Bool {
  c >= 65 && c <= 90
}

///|
fn is_lower(c : Int) -> Bool {
  c >= 97 && c <= 122
}

///|
fn is_alpha(c : Int) -> Bool {
  is_upper(c) || is_lower(c)
}

///|
fn is_alnum(c : Int) -> Bool {
  is_alpha(c) || is_digit(c)
}

///|
/// A regular expression's `\w`.
fn is_word(c : Int) -> Bool {
  is_alnum(c) || c == 95
}

///|
fn all_units(s : String, f : (Int) -> Bool) -> Bool {
  for i in 0..<s.length() {
    if !f(cu(s, i)) {
      return false
    }
  }
  true
}

///|
fn any_unit(s : String, f : (Int) -> Bool) -> Bool {
  for i in 0..<s.length() {
    if f(cu(s, i)) {
      return true
    }
  }
  false
}

///|
/// `/^[0-9]+$/`.
fn digits(s : String) -> Bool {
  s != "" && all_units(s, is_digit)
}

///|
/// ASCII lower case, as `toLowerCase` makes what these compare (names, keys).
fn lower(s : String) -> String {
  @jscase.lower(s)
}

///|
fn upper_ascii(s : String) -> String {
  let b = StringBuilder()
  for i in 0..<s.length() {
    let c = cu(s, i)
    b.write_char(Int::unsafe_to_char(if is_lower(c) { c - 32 } else { c }))
  }
  b.to_string()
}

///|
/// JavaScript's `toUpperCase` for what these upper (ASCII words, codes): others as they are.
fn upper(s : String) -> String {
  upper_ascii(s)
}

///|
fn ch(c : Int) -> String {
  Int::unsafe_to_char(c).to_string()
}

///|
/// `Number(s)` for the strings these read (decimal, with white space around it; "" is 0). NaN where it is not one.
fn js_number(s : String) -> Double {
  @jsjson.js_number(s)
}

///|
/// `/^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/`.
fn decimal_literal(t : String) -> Bool {
  let n = t.length()
  let mut i = 0
  if i < n && (cu(t, i) == 43 || cu(t, i) == 45) {
    i += 1
  }
  let int_start = i
  while i < n && is_digit(cu(t, i)) {
    i += 1
  }
  let int_digits = i - int_start
  let mut frac_digits = 0
  if i < n && cu(t, i) == 46 {
    i += 1
    let f = i
    while i < n && is_digit(cu(t, i)) {
      i += 1
    }
    frac_digits = i - f
  }
  if int_digits == 0 && frac_digits == 0 {
    return false
  }
  if i < n && (cu(t, i) == 101 || cu(t, i) == 69) {
    i += 1
    if i < n && (cu(t, i) == 43 || cu(t, i) == 45) {
      i += 1
    }
    let e = i
    while i < n && is_digit(cu(t, i)) {
      i += 1
    }
    if i == e {
      return false
    }
  }
  i == n
}

///|
fn is_integer(d : Double) -> Bool {
  @jsjson.is_integer(d)
}

///|
fn is_safe_integer(d : Double) -> Bool {
  @jsjson.is_safe_integer(d)
}

///|
/// `String(n)` as JavaScript writes a number.
fn num_text(d : Double) -> String {
  @jsjson.stringify(@jsjson.JValue::Num(d))
}

///|
/// `Math.round`.
fn js_round(d : Double) -> Double {
  @jsjson.js_round(d)
}

// ── JSON ─────────────────────────────────────────────────────────────────────────────────────────────────────────

///|
fn field(j : Json, name : String) -> Json? {
  match j {
    Object(m) => m.get(name)
    _ => None
  }
}

///|
fn str_field(j : Json, name : String) -> String? {
  match field(j, name) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn str_or(j : Json, name : String, d : String) -> String {
  str_field(j, name).unwrap_or(d)
}

///|
fn num_field(j : Json, name : String) -> Double? {
  match field(j, name) {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
fn int_field(j : Json, name : String, d : Int) -> Int {
  match num_field(j, name) {
    Some(n) => n.to_int()
    None => d
  }
}

///|
fn bool_field(j : Json, name : String) -> Bool {
  match field(j, name) {
    Some(True) => true
    _ => false
  }
}

///|
fn strs(j : Json?) -> Array[String] {
  match j {
    Some(Array(a)) =>
      a.filter_map(v => match v {
        String(s) => Some(s)
        _ => None
      })
    _ => []
  }
}

///|
fn nums(j : Json?) -> Array[Double] {
  match j {
    Some(Array(a)) =>
      a.filter_map(v => match v {
        Number(n, ..) => Some(n)
        _ => None
      })
    _ => []
  }
}

///|
fn js(s : String) -> Json {
  Json::string(s)
}

///|
fn jn(n : Double) -> Json {
  // (as JSON.stringify writes NaN and the infinities)
  if n.is_nan() || n.is_inf() {
    Json::null()
  } else {
    Json::number(n)
  }
}

///|
fn ji(n : Int) -> Json {
  Json::number(n.to_double())
}

///|
fn arr(j : Json?) -> Array[Json] {
  match j {
    Some(Array(a)) => a
    _ => []
  }
}

///|
fn jb(b : Bool) -> Json {
  Json::boolean(b)
}

///|
fn jstrs(a : Array[String]) -> Json {
  Json::array(a.map(Json::string))
}

///|
fn opt_s(s : String?) -> Json {
  match s {
    Some(t) => Json::string(t)
    None => Json::null()
  }
}

///|
fn opt_n(n : Double?) -> Json {
  match n {
    Some(t) => jn(t)
    None => Json::null()
  }
}

///|
/// A map of strings as the case gives it (an environment), its keys in their order.
fn env_of(j : Json?) -> Array[(String, String)] {
  match j {
    Some(Object(m)) => {
      let out = []
      for k, v in m {
        match v {
          String(s) => out.push((k, s))
          _ => ()
        }
      }
      out
    }
    _ => []
  }
}

///|
fn env_get(env : Array[(String, String)], k : String) -> String? {
  for p in env {
    if p.0 == k {
      return Some(p.1)
    }
  }
  None
}

///|
fn env_json(env : Array[(String, String)]) -> Json {
  let m = Map([])
  for p in env {
    m[p.0] = Json::string(p.1)
  }
  Json::object(m)
}

///|
/// `env[k] || undefined`: set and not empty.
fn env_truthy(env : Array[(String, String)], k : String) -> String? {
  match env_get(env, k) {
    Some(v) if v != "" => Some(v)
    _ => None
  }
}

///|
fn env_set(env : Array[(String, String)], k : String, v : String) -> Unit {
  for i in 0..<env.length() {
    if env[i].0 == k {
      env[i] = (k, v)
      return
    }
  }
  env.push((k, v))
}

///|
/// JSON as JavaScript writes it (`JSON.stringify`), from the JSON a case holds.
fn js_stringify(j : Json) -> String {
  @jsjson.stringify(to_jvalue(j))
}

///|
fn to_jvalue(j : Json) -> @jsjson.JValue {
  @jsjson.JValue::of_json(j)
}

///|
fn from_jvalue(v : @jsjson.JValue) -> Json {
  match v {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Num(n) => Json::number(n)
    Str(s) => Json::string(@jsjson.raw_text(s))
    Arr(a) => Json::array(a.map(from_jvalue))
    Obj(kv) => {
      let m = Map([])
      for p in kv {
        m[@jsjson.raw_text(p.0)] = from_jvalue(p.1)
      }
      Json::object(m)
    }
  }
}

///|
/// `JSON.parse` as JavaScript reads it; None where it does not.
fn js_parse(text : String) -> Json? {
  try Some(from_jvalue(@jsjson.parse(text))) catch {
    _ => None
  }
}

///|
/// A stable sort (Array.prototype.sort is stable).
fn[T] stable_sort(items : Array[T], cmp : (T, T) -> Int) -> Array[T] {
  if items.length() <= 1 {
    return items.copy()
  }
  let mid = items.length() / 2
  let a = stable_sort(items[0:mid].to_owned(), cmp)
  let b = stable_sort(items[mid:].to_owned(), cmp)
  let out = []
  let mut i = 0
  let mut k = 0
  while i < a.length() && k < b.length() {
    if cmp(b[k], a[i]) < 0 {
      out.push(b[k])
      k += 1
    } else {
      out.push(a[i])
      i += 1
    }
  }
  while i < a.length() {
    out.push(a[i])
    i += 1
  }
  while k < b.length() {
    out.push(b[k])
    k += 1
  }
  out
}

///|
/// An error's words: a Failure's message as it was said.
fn err_text(e : Error) -> String {
  match e {
    Failure(m) => m
    _ => e.to_string()
  }
}
