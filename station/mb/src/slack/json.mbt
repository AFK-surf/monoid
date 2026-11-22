// JSON as station/src/slack reads and writes it (`any` in TypeScript): jsjson's values (JSON.parse and JSON.stringify,
// an object's keys in the order they were put), and the few ways the TypeScript reads one: `typeof v === "string"`, a
// field of what may be anything (`v?.k`), `String(v)`, `Number(v)`, `[...s].length`.

///|
pub using @jsjson {jval_str as js, jval_obj as jo, jval_at as at, stringify}

///|
using @jsjson {
  type JValue as J, jval_num as jn, jval_int as ji, jval_bool as jb, jval_array as ja, jval_strs as jsa,
  jval_opt_str as jopt, jval_at_path as at_path, jval_at_i as at_i, jval_str_of as str_of, jval_text as text,
  jval_arr as arr, jval_is_record as is_obj, jval_nullish as nullish, jval_truthy as truthy,
  jval_is_true as is_true, jval_js_str as js_str, jval_num_text_of as num_text, jval_js_num as js_num,
  code_points as point_count, chars as first_points, jval_set as put, jval_del as drop,
  jval_strings_of as strings, js_uniq as unique,
}

///|
using @jscase {trim, lower}

///|
/// `Object.values(v)` of what `v ?? {}` is (a list's items, a string's letters; none of anything else).
fn values_of(v : J?) -> Array[J] {
  match v {
    Some(Obj(fs)) => fs.map(f => f.1)
    Some(Arr(xs)) => xs
    Some(Str(u)) => Array::makei(u.length(), i => Str(u.unsafe_substring(start=i, end=i + 1)))
    _ => []
  }
}

///|
fn points(s : String) -> Array[Char] { s.to_array() }

///|
fn obj_at(o : J, k : String) -> J {
  match at(Some(o), k) {
    Some(Obj(_) as x) => x
    _ => Obj([])
  }
}

///|
fn with_obj(o : J, k : String, f : (J) -> J) -> J { put(o, k, f(obj_at(o, k))) }

///|
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
fn fail_(message : String) -> Thrown { Thrown("", message) }

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
