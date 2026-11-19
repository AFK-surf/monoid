// What the ports of station/src/{ops,platform,resources,search,read} share: JavaScript's string methods as the
// TypeScript used them (UTF-16 code units, `split` keeping empty parts, `slice` with negative ends), numbers as
// `Number(...)` reads them and `String(n)` writes them, and the JSON a case is given and answered in.

///|
using @jsjson {
  js_index_of as index_of, js_last_index_of as last_index_of, js_starts as starts, js_ends as ends,
  js_includes as has, js_split as split_on, js_split_lines as split_lines, js_upper_ascii as upper_ascii,
  js_number, is_integer, is_safe_integer, jval_stringify_num as num_text, js_round, json_field as field,
  json_str_field as str_field, json_num_field as num_field, json_bool_field as bool_field, json_items as arr,
  json_strings_of as strs, json_str as js, json_num_js as jn, json_int as ji, json_bool as jb,
  json_strs as jstrs, json_opt_str as opt_s, json_stringify as js_stringify, jval_of_json as to_jvalue,
}

///|
using @jscase {
  split_by as split_runs, is_white_space as js_space, trim as js_trim, trim_start_white as js_trim_start,
  trim_end_white as js_trim_end, lower,
}

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
/// JavaScript's `toUpperCase` for what these upper (ASCII words, codes): others as they are.
fn upper(s : String) -> String {
  upper_ascii(s)
}

///|
fn ch(c : Int) -> String {
  Int::unsafe_to_char(c).to_string()
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

// ── JSON ─────────────────────────────────────────────────────────────────────────────────────────────────────────

///|
fn str_or(j : Json, name : String, d : String) -> String {
  str_field(j, name).unwrap_or(d)
}

///|
fn int_field(j : Json, name : String, d : Int) -> Int {
  match num_field(j, name) {
    Some(n) => n.to_int()
    None => d
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
fn from_jvalue(v : @jsjson.JValue) -> Json {
  v.to_json()
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
