// JSON as the TypeScript of station/src/screens/ and src/helper/ makes it (`@jsjson`: JSON.parse and JSON.stringify's
// own): an object's keys in the order they were first set, a spread (`{ ...a, ...b }`) keeping a's places and adding
// b's after, so what goes to still.fail Helper, stillfail-screen or a portal's helper on its wire is the TypeScript's
// byte for byte.

///|
pub using @jsjson {type JValue as J}

///|
using @jsjson {
  jval_str as js, jval_num as jn, jval_int as ji, jval_bool as jb, jval_obj as jo, jval_array as ja,
  jval_strs as jstrs, jval_opt_str as jopt_s, jval_at as get, jval_str_of as text, jval_num_of as num,
  jval_arr_of as arr, jval_set_or_new as set, jval_spread as spread, stringify, parse, num_text,
  jval_js_num as js_number_of, jval_to_json_lossy as core_json, is_integer, js_round, js_trunc, js_number,
  code_points as points_len,
}

///|
using @jscase {trim as trim_js, trim_end as trim_end_js}

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
/// `JSON.parse` of a buffer's UTF-8, null when it is not JSON (`try { … } catch {}` left `said` null).
fn parse_or_null(b : BytesView) -> J {
  parse(@utf8.decode_lossy(b)) catch {
    _ => Null
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
  @jsjson.jval_js_str(Some(v))
}

///|
/// `String.prototype.trim`'s white space.
fn is_js_space(c : Char) -> Bool {
  @jscase.is_space(c.to_int())
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
