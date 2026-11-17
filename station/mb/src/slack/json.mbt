// JSON as station/src/slack reads and writes it (`any` in TypeScript): jsjson's values (JSON.parse and JSON.stringify,
// an object's keys in the order they were put), and the few ways the TypeScript reads one: `typeof v === "string"`, a
// field of what may be anything (`v?.k`), `String(v)`, `Number(v)`, `[...s].length`.

///|
using @jsjson {type JValue as J}

///|
pub fn js(s : String) -> J {
  Str(@jsjson.units(s))
}

///|
fn jn(d : Double) -> J {
  Num(d)
}

///|
fn ji(i : Int) -> J {
  Num(i.to_double())
}

///|
fn jb(b : Bool) -> J {
  Bool(b)
}

///|
pub fn jo(fields : Array[(String, J)]) -> J {
  Obj(fields.map(f => (@jsjson.units(f.0), f.1)))
}

///|
fn ja(items : Array[J]) -> J {
  Arr(items)
}

///|
fn jsa(items : Array[String]) -> J {
  Arr(items.map(js))
}

///|
fn jopt(s : String?) -> J {
  match s {
    Some(t) => js(t)
    None => Null
  }
}

///|
/// `v?.[name]`: undefined (None) where `v` is no object or has none.
pub fn at(v : J?, name : String) -> J? {
  match v {
    Some(Obj(_) as o) => o.get(name)
    _ => None
  }
}

///|
/// `v?.[a]?.[b]…`.
fn at_path(v : J?, path : Array[String]) -> J? {
  let mut cur = v
  for k in path {
    cur = at(cur, k)
  }
  cur
}

///|
fn at_i(v : J?, i : Int) -> J? {
  match v {
    Some(Arr(xs)) => if i >= 0 && i < xs.length() { Some(xs[i]) } else { None }
    _ => None
  }
}

///|
fn str_of(v : J?) -> String? {
  match v {
    Some(Str(u)) => Some(@jsjson.text(u))
    _ => None
  }
}

///|
/// `typeof v === "string" ? v : ""`.
fn text(v : J?) -> String {
  str_of(v).unwrap_or("")
}

///|
fn arr(v : J?) -> Array[J] {
  match v {
    Some(Arr(xs)) => xs
    _ => []
  }
}

///|
fn is_obj(v : J?) -> Bool {
  v is Some(Obj(_))
}

///|
/// `v == null`.
fn nullish(v : J?) -> Bool {
  match v {
    None | Some(Null) => true
    _ => false
  }
}

///|
fn truthy(v : J?) -> Bool {
  match v {
    None | Some(Null) | Some(Bool(false)) => false
    Some(Num(n)) => n != 0.0 && !n.is_nan()
    Some(Str(u)) => u.length() > 0
    Some(_) => true
  }
}

///|
/// `v === true`.
fn is_true(v : J?) -> Bool {
  v is Some(Bool(true))
}

///|
/// `Object.values(v)` of what `v ?? {}` is (a list's items, a string's letters; none of anything else).
fn values_of(v : J?) -> Array[J] {
  match v {
    Some(Obj(fs)) => fs.map(f => f.1)
    Some(Arr(xs)) => xs
    Some(Str(u)) => u.map(c => Str([c]))
    _ => []
  }
}

///|
/// `String(v)`, `undefined` as "undefined".
fn js_str(v : J?) -> String {
  match v {
    None => "undefined"
    Some(Null) => "null"
    Some(Str(u)) => @jsjson.text(u)
    Some(Bool(b)) => if b { "true" } else { "false" }
    Some(Num(_) as n) => num_text(n)
    Some(Arr(xs)) =>
      xs
      .map(x => match x {
        Null => ""
        _ => js_str(Some(x))
      })
      .join(",")
    Some(Obj(_)) => "[object Object]"
  }
}

///|
/// A number as `String(n)` says it.
fn num_text(n : J) -> String {
  match n {
    Num(d) if d.is_nan() => "NaN"
    Num(d) if d == @double.infinity => "Infinity"
    Num(d) if d == -@double.infinity => "-Infinity"
    _ => @jsjson.stringify(n)
  }
}

///|
/// `Number(v)`.
fn js_num(v : J?) -> Double {
  match v {
    None => @double.not_a_number
    Some(Null) => 0.0
    Some(Bool(b)) => if b { 1.0 } else { 0.0 }
    Some(Num(d)) => d
    Some(Str(u)) => {
      let t = @jscase.trim(@jsjson.text(u))
      if t == "" {
        0.0
      } else {
        @session_chats.js_number(js(t)).unwrap_or(@double.not_a_number)
      }
    }
    Some(Arr(xs)) =>
      match xs {
        [] => 0.0
        [x] => js_num(Some(Str(@jsjson.units(js_str(Some(x))))))
        _ => @double.not_a_number
      }
    Some(Obj(_)) => @double.not_a_number
  }
}

///|
/// A string's code points (`[...s]`).
fn points(s : String) -> Array[Char] {
  let out = []
  for c in s {
    out.push(c)
  }
  out
}

///|
fn point_count(s : String) -> Int {
  let mut n = 0
  for _ in s {
    n += 1
  }
  n
}

///|
/// `[...s].slice(0, n).join("")`.
fn first_points(s : String, n : Int) -> String {
  let out = StringBuilder::new()
  let mut i = 0
  for c in s {
    if i >= n {
      break
    }
    out.write_char(c)
    i += 1
  }
  out.to_string()
}

///|
fn trim(s : String) -> String {
  @jscase.trim(s)
}

///|
fn lower(s : String) -> String {
  @jscase.lower(s)
}

///|
/// `o[k] = v` (in its place where it is there, at its end where not); anything but an object stays as it is.
fn put(o : J, k : String, v : J) -> J {
  match o {
    Obj(fs) => {
      let ku = @jsjson.units(k)
      let out = fs.copy()
      match out.search_by(f => f.0 == ku) {
        Some(i) => out[i] = (ku, v)
        None => out.push((ku, v))
      }
      Obj(out)
    }
    other => other
  }
}

///|
/// `delete o[k]`.
fn drop(o : J, k : String) -> J {
  match o {
    Obj(fs) => {
      let ku = @jsjson.units(k)
      Obj(fs.filter(f => f.0 != ku))
    }
    other => other
  }
}

///|
/// The object at `k` of `o`, an empty one where it is none (apps.ts `object`).
fn obj_at(o : J, k : String) -> J {
  match at(Some(o), k) {
    Some(Obj(_) as x) => x
    _ => Obj([])
  }
}

///|
/// `o[k]` changed by `f` of the object there (made an empty one where none is: apps.ts `object`), `o` made again with it.
fn with_obj(o : J, k : String, f : (J) -> J) -> J {
  put(o, k, f(obj_at(o, k)))
}

///|
/// The strings of a list (apps.ts `strings`).
fn strings(v : J?) -> Array[String] {
  arr(v).filter_map(x => str_of(Some(x)))
}

///|
/// `[...new Set(values)]`.
fn unique(values : Array[String]) -> Array[String] {
  let out = []
  for v in values {
    if !out.contains(v) {
      out.push(v)
    }
  }
  out
}

///|
pub fn stringify(v : J) -> String {
  @jsjson.stringify(v)
}

///|
/// `JSON.parse`, its SyntaxError said as a Thrown.
fn parse(t : String) -> J raise Thrown {
  @jsjson.parse(t) catch {
    @jsjson.SyntaxError(m) => raise Thrown("SyntaxError", m)
  }
}

///|
/// What the TypeScript threw: its kind where a caller tells kinds apart (`SlackApiError`, `SlackWords`) and its message.
pub(all) suberror Thrown {
  Thrown(String, String)
}

///|
pub impl Show for Thrown with output(self, logger) {
  match self {
    Thrown(_, m) => logger.write_string(m)
  }
}

///|
fn fail_(message : String) -> Thrown {
  Thrown("", message)
}

///|
/// An error's message (`(error as Error).message`).
pub fn message_of(e : Error) -> String {
  match e {
    Thrown(_, m) => m
    SlackApiError(m, c, d) =>
      match d {
        Some(x) => "\{m}: \{c} \{stringify(x)}"
        None => "\{m}: \{c}"
      }
    SlackWords(_, m) => m
    @session_chats.Thrown(_, m) => m
    Failure(m) => m
    e => e.to_string()
  }
}

///|
/// `s.replace(/&/g, "&amp;")…`: words written into mrkdwn as they are.
fn escape(s : String) -> String {
  s.replace_all(old="&", new="&amp;").replace_all(old="<", new="&lt;").replace_all(old=">", new="&gt;")
}

///|
/// `x.toFixed(digits)` of a non-negative x below 1e21: the nearest of x·10^digits (the larger of two as near).
fn to_fixed(x : Double, digits : Int) -> String {
  let mut scale = 1.0
  for _ in 0..<digits {
    scale = scale * 10.0
  }
  let n = (x * scale).round()
  let whole = (n / scale).floor()
  let frac = (n - whole * scale).to_int64()
  let w = whole.to_int64().to_string()
  if digits == 0 {
    return w
  }
  let f = frac.to_string()
  let pad = StringBuilder::new()
  for _ in 0..<(digits - f.length()) {
    pad.write_char('0')
  }
  "\{w}.\{pad.to_string()}\{f}"
}
