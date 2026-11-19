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
  @jsjson.jval_js_num(v)
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
  @jsjson.jval_js_str(Some(v))
}

///|
/// A JSON value as the core's (what the station's words are filled with: ops_platform's `tr`).
fn core_json(v : J) -> Json {
  v.to_json_lossy()
}


///|
/// `Number.isInteger(v)`.
fn is_integer(d : Double) -> Bool {
  @jsjson.is_integer(d)
}

///|
/// `Math.round`: halves up (towards +∞), as JavaScript's.
fn js_round(d : Double) -> Double {
  @jsjson.js_round(d)
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
  @jsjson.js_number(s)
}

///|
/// `String.prototype.trim`'s white space.
fn is_js_space(c : Char) -> Bool {
  @jscase.is_space(c.to_int())
}

///|
fn trim_js(s : String) -> String {
  @jscase.trim(s)
}

///|
fn trim_end_js(s : String) -> String {
  @jscase.trim_end(s)
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
  @jsjson.code_points(s)
}
