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
  jval_js_num as js_number_of, is_integer, js_round, js_trunc, js_number,
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
      Some(v) => out.push((p.0, v))
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
  let n = s.length()
  let a = if from < 0 { 0 } else if from > n { n } else { from }
  let b = if to < a { a } else if to > n { n } else { to }
  s.unsafe_substring(start=a, end=b)
}

///|
/// `s.length` in UTF-16 units.
fn units_len(s : String) -> Int {
  s.length()
}

///|
/// `Date.parse` of what these parts read, the time zone where the words say none taken as UTC:
/// ISO's `2026-11-06T08:34:52(.123)(Z|±hh:mm)` and `ps`'s `Fri Nov  6 16:34:52 2026`; NaN for anything else.
pub fn date_parse_utc(s : String) -> Double {
  let t = trim_js(s)
  let digits = (from : Int, n : Int) => {
    if from + n > t.length() {
      return None
    }
    let mut v = 0
    for i in from..<(from + n) {
      let c = t.unsafe_get(i).to_int()
      if c < '0'.to_int() || c > '9'.to_int() {
        return None
      }
      v = v * 10 + (c - '0'.to_int())
    }
    Some(v)
  }
  let at = (i : Int) => if i < t.length() { t.unsafe_get(i).to_int() } else { -1 }
  // ISO 8601
  match (digits(0, 4), at(4), digits(5, 2), at(7), digits(8, 2)) {
    (Some(y), 45, Some(mo), 45, Some(d)) => {
      if t.length() == 10 {
        return utc_ms(y, mo, d, 0, 0, 0, 0)
      }
      guard at(10) == 'T'.to_int() else { return @double.not_a_number }
      guard (digits(11, 2), at(13), digits(14, 2)) is (Some(h), 58, Some(mi)) else { return @double.not_a_number }
      let mut i = 16
      let mut sec = 0
      let mut ms = 0
      if at(i) == ':'.to_int() {
        guard digits(i + 1, 2) is Some(se) else { return @double.not_a_number }
        sec = se
        i += 3
        if at(i) == '.'.to_int() {
          let mut j = i + 1
          let mut frac = 0
          let mut n = 0
          while at(j) >= '0'.to_int() && at(j) <= '9'.to_int() {
            if n < 3 {
              frac = frac * 10 + (at(j) - '0'.to_int())
              n += 1
            }
            j += 1
          }
          while n < 3 {
            frac *= 10
            n += 1
          }
          ms = frac
          i = j
        }
      }
      let mut offset = 0
      if at(i) == 'Z'.to_int() {
        i += 1
      } else if at(i) == '+'.to_int() || at(i) == '-'.to_int() {
        let sign = if at(i) == '+'.to_int() { 1 } else { -1 }
        guard (digits(i + 1, 2), at(i + 3), digits(i + 4, 2)) is (Some(oh), 58, Some(om)) else { return @double.not_a_number }
        offset = sign * (oh * 60 + om)
        i += 6
      }
      if i != t.length() {
        return @double.not_a_number
      }
      return utc_ms(y, mo, d, h, mi, sec, ms) - offset.to_double() * 60000.0
    }
    _ => ()
  }
  // `Fri Nov  6 16:34:52 2026`
  let words = split_space(t)
  if words.length() == 5 {
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    match months.search(words[1]) {
      Some(m) => {
        let d = js_number(words[2])
        let y = js_number(words[4])
        let hms = words[3].split(":").map(v => js_number(v.to_string())).collect()
        if hms.length() == 3 && is_integer(d) && is_integer(y) && hms.iter().all(is_integer) {
          return utc_ms(y.to_int(), m + 1, d.to_int(), hms[0].to_int(), hms[1].to_int(), hms[2].to_int(), 0)
        }
      }
      None => ()
    }
  }
  @double.not_a_number
}

///|
fn utc_ms(y : Int, mo : Int, d : Int, h : Int, mi : Int, s : Int, ms : Int) -> Double {
  let days = @time.days_from_civil(y, mo, d)
  days.to_double() * 86400000.0 + (h * 3600000 + mi * 60000 + s * 1000 + ms).to_double()
}
