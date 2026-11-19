// JSON as station/src/browser reads and writes it (`any` in TypeScript): jsjson's values (JSON.parse and JSON.stringify,
// an object's keys in the order they were put), and the few ways the TypeScript reads one: `typeof v === "string"`, a
// field of what may be anything (`v?.k`), `String(v)`, `Number(v)`, `{ ...a, ...b }`.

///|
pub using @jsjson {
  jval_str as js, jval_num as jn, jval_int as ji, jval_bool as jb, jval_obj as jo, jval_array as ja,
  jval_at_last as at, jval_str_of as str_of, jval_js_str as js_str, jval_num_text_of as num_text,
  num_text as dnum, stringify, jval_quote as quote, utf8, utf8_text as from_utf8,
}

///|
pub using @codec {base64_decode_loose as from_base64url}

///|
using @jsjson {
  type JValue as J, jval_strs as jsa, jval_opt_str as jopt, jval_at_path_last as at_path, jval_at_i as at_i,
  jval_text as text, jval_num_of as num_of, jval_bool_of as bool_of, jval_arr as arr, jval_is_arr as is_arr,
  jval_is_obj as is_object, jval_nullish as nullish, jval_truthy as truthy, jval_is_true as is_true,
  jval_js_num as js_num, jval_is_integer as is_integer, jval_safe_int as is_safe_integer, jval_set as put,
  jval_spread as spread, jval_del as drop_key, stringify_pretty, js_upper_ascii as upper_ascii,
  js_all_digits as all_digits, js_index_of as index_of, js_last_index_of as last_index_of, jval_num as jms,
  jval_str_eq as is_str,
}

///|
using @jscase {lower, trim}

///|
/// An object's own keys, in order (each once: JSON.parse keeps a name given twice where it came first).
fn keys_of(o : J) -> Array[String] {
  let out = []
  match o {
    Obj(fs) =>
      for f in fs {
        let k = @jsjson.sanitize_str(f.0)
        if !out.contains(k) {
          out.push(k)
        }
      }
    _ => ()
  }
  out
}

///|
/// `Object.entries(o)` of a parsed object: its keys in order, each with its last value.
fn entries_of(o : J) -> Array[(String, J)] {
  keys_of(o).map(k => (k, at(Some(o), k).unwrap()))
}

///|
/// What the TypeScript threw: its kind where a caller tells kinds apart, and its message.
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
/// A screen refused as screens/hub.ts refuses one: its status and its words' key.
pub(all) suberror ScreenRefused {
  ScreenRefused(Int, String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for ScreenRefused with output(self, logger) {
  match self {
    ScreenRefused(_, key) => logger.write_string(key)
  }
}

///|
pub fn fail_(message : String) -> Thrown {
  Thrown("Error", message)
}

///|
/// `JSON.parse`, its SyntaxError said as a Thrown.
pub fn parse(t : String) -> J raise Thrown {
  @jsjson.parse(t) catch {
    @jsjson.SyntaxError(m) => raise Thrown("SyntaxError", m)
  }
}

///|
/// An error's message (`(error as Error).message`).
pub fn message_of(e : Error) -> String {
  match e {
    Thrown(_, m) => m
    ScreenRefused(_, k) => k
    Failure(m) => m
    e => e.to_string()
  }
}

///|
/// An error's kind, as the TypeScript's class would be told apart.
pub fn kind_of(e : Error) -> String {
  match e {
    Thrown(k, _) => k
    ScreenRefused(_, _) => "ScreenRefused"
    _ => "Error"
  }
}

///|
fn is_ascii_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn is_ascii_alpha(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

///|
/// `s.slice(a, b)` by UTF-16 code units, clamped as JavaScript clamps it.
fn slice(s : String, a : Int, b? : Int) -> String {
  @jsjson.js_slice(s, a, end?=b)
}

///|
fn imax(a : Int, b : Int) -> Int {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn imin(a : Int, b : Int) -> Int {
  if a < b {
    a
  } else {
    b
  }
}

///|
/// The base64url of `b` (no padding: Buffer's `base64url`).
pub fn base64url(b : Bytes) -> String {
  let t = @base64.encode(b, padding=false)
  t.replace_all(old="+", new="-").replace_all(old="/", new="_")
}

///|
/// What `JSON.parse(t)` makes where it is an object; None where it is not, or `t` is no JSON.
fn parse_obj(t : String) -> J? {
  match (try Some(parse(t)) catch { _ => None }) {
    Some(Obj(_) as o) => Some(o)
    _ => None
  }
}

///|
/// The separator a path goes by: `\` for a Windows path (a drive's `C:`, a share's `\\host`, or one written with `\`
/// alone), `/` otherwise (path.join's on the system it was made on).
pub fn sep_of(path : String) -> String {
  let drive = path.length() >= 2 &&
    is_ascii_alpha(Int::unsafe_to_char(path.unsafe_charcode_at(0))) &&
    path.unsafe_charcode_at(1) == ':'.to_int()
  if path.has_prefix("\\\\") || drive || (path.contains("\\") && !path.contains("/")) {
    "\\"
  } else {
    "/"
  }
}

///|
/// `path.join` of `parts` by the separator the first goes by.
pub fn pjoin(parts : Array[String]) -> String {
  @nodepath.join(sep_of(if parts.length() > 0 { parts[0] } else { "" }), parts)
}

///|
/// `path.dirname` by the separator the path goes by.
pub fn pdirname(path : String) -> String {
  @nodepath.dirname(sep_of(path), path)
}
