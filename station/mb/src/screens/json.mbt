// JSON as the TypeScript of station/src/screens/ and src/helper/ makes it (`@jsjson`: JSON.parse and JSON.stringify's
// own): an object's keys in the order they were first set, a spread (`{ ...a, ...b }`) keeping a's places and adding
// b's after, so what goes to still.fail Helper, stillfail-screen or a portal's helper on its wire is the TypeScript's
// byte for byte.

///|
pub using @jsjson {type JValue as J}

///|
fn js(s : String) -> J {
  @jsjson.JValue::of_string(s)
}

///|
fn jn(d : Double) -> J {
  @jsjson.JValue::of_double(d)
}

///|
fn ji(i : Int) -> J {
  @jsjson.JValue::of_int(i)
}

///|
fn jb(b : Bool) -> J {
  @jsjson.JValue::of_bool(b)
}

///|
fn jo(pairs : Array[(String, J)]) -> J {
  @jsjson.JValue::of_object(pairs)
}

///|
fn ja(items : Array[J]) -> J {
  @jsjson.JValue::of_array(items)
}

///|
fn jstrs(items : Array[String]) -> J {
  @jsjson.JValue::of_strings(items)
}

///|
fn jopt_s(v : String?) -> J {
  @jsjson.JValue::of_opt_string(v)
}

///|
/// `o[k]` where `o` is an object.
fn get(o : J?, k : String) -> J? {
  @jsjson.jval_at(o, k)
}

///|
fn text(j : J?) -> String? {
  @jsjson.jval_str_of(j)
}

///|
fn num(j : J?) -> Double? {
  @jsjson.jval_num_of(j)
}

///|
fn arr(j : J?) -> Array[J]? {
  @jsjson.jval_arr_of(j)
}



///|
/// `o[k] = v` on a copy: in its place where `o` has it, else last.
fn set(o : J, k : String, v : J) -> J {
  @jsjson.jval_set_or_new(o, k, v)
}


///|
/// `{ ...a, ...b }`.
fn spread(a : J, b : J) -> J {
  @jsjson.jval_spread(a, b)
}

///|
/// `{ ...a, ...b, ... }` of pairs, those with no value left out (a `...(x ? {k: v} : {})`).
fn jsome(pairs : Array[(String, J?)]) -> J {
  let out = []
  for p in pairs {
    match p.1 {
      Some(v) => out.push((@jsjson.units(p.0), v))
      None => ()
    }
  }
  Obj(out)
}

///|
fn stringify(j : J) -> String {
  @jsjson.stringify(j)
}

///|
fn parse(s : String) -> J raise {
  @jsjson.parse(s)
}

///|
/// `JSON.parse` of a buffer's UTF-8, null when it is not JSON (`try { … } catch {}` left `said` null).
fn parse_or_null(b : BytesView) -> J {
  parse(@utf8.decode_lossy(b)) catch {
    _ => Null
  }
}


///|
/// A number as JavaScript's `String(n)` says it.
fn num_text(d : Double) -> String {
  @jsjson.num_text(d)
}

///|
/// `Number(v)` of a JSON value (none: undefined, NaN).
fn js_number_of(v : J?) -> Double {
  match v {
    None => @double.not_a_number
    Some(Null) => 0.0
    Some(Bool(b)) => if b { 1.0 } else { 0.0 }
    Some(Num(d)) => d
    Some(Str(_) as s) => js_number(text(Some(s)).unwrap_or(""))
    Some(Arr([])) => 0.0
    Some(Arr([x])) => js_number(js_string(x))
    Some(_) => @double.not_a_number
  }
}

///|
/// `Number(v) || 0`.
fn number_or_zero(v : J?) -> Double {
  let d = js_number_of(v)
  if d.is_nan() || d == 0.0 {
    0.0
  } else {
    d
  }
}

///|
/// `String(v)` of a JSON value, as JavaScript says it.
fn js_string(v : J) -> String {
  match v {
    Str(u) => @jsjson.text(u)
    Num(d) => num_text(d)
    Bool(true) => "true"
    Bool(false) => "false"
    Null => "null"
    Arr(xs) => xs.map(x => if x is Null { "" } else { js_string(x) }).join(",")
    Obj(_) => "[object Object]"
  }
}

///|
/// A JSON value as the core's (what the station's words are filled with: ops_platform's `tr`).
fn core_json(v : J) -> Json {
  match v {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Num(d) => Json::number(d)
    Str(u) => Json::string(@jsjson.text(u))
    Arr(xs) => Json::array(xs.map(core_json))
    Obj(ps) => {
      let m : Map[String, Json] = Map::new()
      for p in ps {
        m[@jsjson.text(p.0)] = core_json(p.1)
      }
      Json::object(m)
    }
  }
}


///|
/// `Number.isInteger(v)`.
fn is_integer(d : Double) -> Bool {
  @jsjson.is_integer(d)
}

///|
/// `Math.round`: halves up (towards +∞), as JavaScript's.
fn js_round(d : Double) -> Double {
  if d.is_nan() || d.is_inf() {
    return d
  }
  let f = (d + 0.5).floor()
  // (0.49999999999999994 + 0.5 is 1 in doubles: JavaScript's gives 0)
  if f - d > 0.5 {
    f - 1.0
  } else if f == 0.0 && d < 0.0 {
    -0.0
  } else {
    f
  }
}

///|
/// `Math.trunc`.
fn js_trunc(d : Double) -> Double {
  if d < 0.0 {
    -(-d).floor()
  } else {
    d.floor()
  }
}

///|
/// `Number(s)` of a string as JavaScript reads one: white space round it, empty 0, hex after `0x`, NaN for what is no
/// number.
fn js_number(s : String) -> Double {
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
  if t.has_prefix("0x") || t.has_prefix("0X") {
    return hex_number(t.unsafe_substring(start=2, end=t.length()))
  }
  let negative = t.has_prefix("-")
  let body = if t.has_prefix("+") || negative {
    t.unsafe_substring(start=1, end=t.length())
  } else {
    t
  }
  let mut digits = false
  let mut dot = false
  let mut e = false
  let mut after_e = true
  let mut prev = ' '
  for c in body {
    if c >= '0' && c <= '9' {
      digits = true
      after_e = true
    } else if c == '.' && !dot && !e {
      dot = true
    } else if (c == 'e' || c == 'E') && digits && !e {
      e = true
      after_e = false
    } else if (c == '-' || c == '+') && (prev == 'e' || prev == 'E') {
      ()
    } else {
      return @double.not_a_number
    }
    prev = c
  }
  if !digits || !after_e {
    return @double.not_a_number
  }
  let v = @string.parse_double(body) catch { _ => return @double.not_a_number }
  if negative {
    -v
  } else {
    v
  }
}

///|
fn hex_number(t : String) -> Double {
  if t == "" {
    return @double.not_a_number
  }
  let mut v = 0.0
  for c in t {
    let d = if c >= '0' && c <= '9' {
      c.to_int() - '0'.to_int()
    } else if c >= 'a' && c <= 'f' {
      c.to_int() - 'a'.to_int() + 10
    } else if c >= 'A' && c <= 'F' {
      c.to_int() - 'A'.to_int() + 10
    } else {
      return @double.not_a_number
    }
    v = v * 16.0 + d.to_double()
  }
  v
}

///|
/// `String.prototype.trim`'s white space.
fn is_js_space(c : Char) -> Bool {
  let u = c.to_int()
  u == 0x20 ||
  (u >= 0x09 && u <= 0x0d) ||
  u == 0xa0 ||
  u == 0x1680 ||
  (u >= 0x2000 && u <= 0x200a) ||
  u == 0x2028 ||
  u == 0x2029 ||
  u == 0x202f ||
  u == 0x205f ||
  u == 0x3000 ||
  u == 0xfeff
}

///|
fn trim_js(s : String) -> String {
  let cs = s.to_array()
  let mut a = 0
  let mut b = cs.length()
  while a < b && is_js_space(cs[a]) {
    a += 1
  }
  while b > a && is_js_space(cs[b - 1]) {
    b -= 1
  }
  String::from_array(cs[a:b])
}

///|
fn trim_end_js(s : String) -> String {
  let cs = s.to_array()
  let mut b = cs.length()
  while b > 0 && is_js_space(cs[b - 1]) {
    b -= 1
  }
  String::from_array(cs[0:b])
}

///|
/// `s.slice(0, n)` in UTF-16 units, as JavaScript cuts a string (a pair cut in half keeps its first half).
fn slice_units(s : String, from : Int, to : Int) -> String {
  let u = @jsjson.units(s)
  let n = u.length()
  let a = if from < 0 { 0 } else if from > n { n } else { from }
  let b = if to < a { a } else if to > n { n } else { to }
  @jsjson.raw_text(u[a:b].to_array())
}

///|
/// `s.length` in UTF-16 units.
fn units_len(s : String) -> Int {
  @jsjson.units(s).length()
}

///|
/// `Array.from(s).length`: its code points.
fn points_len(s : String) -> Int {
  let mut n = 0
  for _ in s {
    n += 1
  }
  n
}
