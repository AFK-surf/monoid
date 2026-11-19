// JSON as the TypeScript these parts are written from reads and writes it (station/mb's jsjson; the helpers are
// session_chats'), and the ways of it these parts need besides: an object's keys in the order JavaScript gives them
// (integer-like keys first, ascending, as `JSON.stringify` of an object made from a Map says them), and bytes as hex
// where they cross the program's own lines.

///|
using @jsjson {type JValue as J}

///|
using @session_chats {
  at,
  str_of,
  num_of,
  bool_of,
  arr_of,
  js,
  jn,
  ji,
  jb,
  jo,
  ja,
  jsa,
  jopt,
  set_field,
  without,
  spread,
  parse_js,
  type Thrown,
  thrown_message,
  thrown_kind,
  fail_,
}

///|
/// `undefined`, as the wire says it (`{"$u": 1}`).
pub fn is_undefined(v : J) -> Bool {
  @session_chats.is_undefined(v)
}

///|
/// Whether `key` is an array index as JavaScript keeps an object's keys: those come first, ascending.
fn index_key(key : Array[Int]) -> Double? {
  if key.length() == 0 || key.length() > 10 {
    return None
  }
  if key.length() > 1 && key[0] == '0'.to_int() {
    return None
  }
  let mut n = 0.0
  for c in key {
    if c < '0'.to_int() || c > '9'.to_int() {
      return None
    }
    n = n * 10.0 + (c - '0'.to_int()).to_double()
  }
  if n >= 4294967295.0 {
    None
  } else {
    Some(n)
  }
}

///|
/// A value with each object's keys in JavaScript's order.
pub fn js_ordered(v : J) -> J {
  match v {
    Obj(fs) => {
      let ints : Array[(Double, (Array[Int], J))] = []
      let rest : Array[(Array[Int], J)] = []
      for f in fs {
        match index_key(f.0) {
          Some(n) => ints.push((n, (f.0, js_ordered(f.1))))
          None => rest.push((f.0, js_ordered(f.1)))
        }
      }
      if ints.length() == 0 {
        return Obj(rest)
      }
      ints.sort_by((a, b) => a.0.compare(b.0))
      Obj([..ints.map(p => p.1), ..rest])
    }
    Arr(xs) => Arr(xs.map(js_ordered))
    other => other
  }
}

///|
/// `JSON.stringify(v)`.
pub fn js_stringify(v : J) -> String {
  @jsjson.stringify(js_ordered(v))
}

///|
/// An object of entries in their order (`Object.fromEntries`): a key said again keeps its first place, its last value.
pub fn from_entries(entries : Array[(String, J)]) -> J {
  let out : Array[(Array[Int], J)] = []
  for e in entries {
    let k = @jsjson.units(e.0)
    match out.search_by(f => f.0 == k) {
      Some(i) => out[i] = (k, e.1)
      None => out.push((k, e.1))
    }
  }
  Obj(out)
}

///|
/// An object's entries in JavaScript's order (`Object.entries`).
pub fn entries_of(v : J?) -> Array[(String, J)] {
  match v {
    Some(Obj(_) as o) =>
      match js_ordered(o) {
        Obj(fs) => fs.map(f => (@jsjson.text(f.0), f.1))
        _ => []
      }
    _ => []
  }
}

///|
/// `typeof v === "string" && v !== ""`.
pub fn nonempty_str(v : J?) -> String? {
  match str_of(v) {
    Some(s) if s != "" => Some(s)
    _ => None
  }
}

///|
/// `typeof v === "object" && v !== null && !Array.isArray(v)`.
pub fn is_object(v : J?) -> Bool {
  v is Some(Obj(_))
}

///|
/// An object's fields, none where it is no object.
pub fn fields_of(v : J?) -> Array[(String, J)] {
  match v {
    Some(Obj(fs)) => fs.map(f => (@jsjson.text(f.0), f.1))
    _ => []
  }
}

///|
/// What a value is as JavaScript's `String(v)` says it, for the few values these parts turn to words.
pub fn js_text(v : J?) -> String {
  match v {
    None => "undefined"
    Some(Null) => "null"
    Some(Str(u)) => @jsjson.text(u)
    Some(Bool(b)) => if b { "true" } else { "false" }
    Some(Num(d)) => @session_chats.num_text(d)
    Some(Arr(xs)) => xs.map(x => if x is Null { "" } else { js_text(Some(x)) }).join(",")
    Some(Obj(_)) => "[object Object]"
  }
}

///|
/// Bytes as lowercase hex.
pub fn hex(b : BytesView) -> String {
  let digits = "0123456789abcdef"
  let out = StringBuilder()
  for x in b {
    let n = x.to_int()
    out.write_char(digits.get_char(n >> 4).unwrap())
    out.write_char(digits.get_char(n & 15).unwrap())
  }
  out.to_string()
}

///|
fn hex_digit(c : Char) -> Int? {
  if c >= '0' && c <= '9' {
    Some(c.to_int() - '0'.to_int())
  } else if c >= 'a' && c <= 'f' {
    Some(c.to_int() - 'a'.to_int() + 10)
  } else if c >= 'A' && c <= 'F' {
    Some(c.to_int() - 'A'.to_int() + 10)
  } else {
    None
  }
}

///|
/// Hex as bytes (what is not hex read as nothing more).
pub fn unhex(s : String) -> Bytes {
  let out = Buffer()
  let cs = s.to_array()
  let mut i = 0
  while i + 1 < cs.length() {
    match (hex_digit(cs[i]), hex_digit(cs[i + 1])) {
      (Some(a), Some(b)) => out.write_byte((a * 16 + b).to_byte())
      _ => break
    }
    i += 2
  }
  out.to_bytes()
}

///|
/// Whether `s` is `n` lowercase hex digits (`/^[0-9a-f]{n}$/`).
pub fn lower_hex_of(s : String, n : Int) -> Bool {
  if s.length() != n {
    return false
  }
  for c in s {
    if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
      return false
    }
  }
  true
}

///|
/// Text of UTF-8 bytes (`buffer.toString()`: a broken sequence U+FFFD).
pub fn text_of(b : BytesView) -> String {
  @utf8.decode_lossy(b)
}

///|
/// A text's UTF-8.
pub fn utf8(s : String) -> Bytes {
  @jsjson.utf8(s)
}

///|
/// `s.replace(from, to)` with a string: its first `from` only, `to`'s `$$`, `$&`, `` $` `` and `$'` said as JavaScript
/// says them.
pub fn replace_first(s : String, from : String, to : String) -> String {
  let i = @session_chats.index_of(s, from)
  if i < 0 {
    return s
  }
  let before = @session_chats.slice(s, 0, b=i)
  let after = @session_chats.slice(s, i + from.length())
  let out = StringBuilder()
  let cs = to.to_array()
  let mut k = 0
  while k < cs.length() {
    if cs[k] == '$' && k + 1 < cs.length() {
      match cs[k + 1] {
        '$' => { out.write_char('$'); k += 2; continue }
        '&' => { out.write_string(from); k += 2; continue }
        '`' => { out.write_string(before); k += 2; continue }
        '\'' => { out.write_string(after); k += 2; continue }
        _ => ()
      }
    }
    out.write_char(cs[k])
    k += 1
  }
  before + out.to_string() + after
}
