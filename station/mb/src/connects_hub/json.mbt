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
  @jsjson.index_key(@jsjson.raw_text(key))
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
  @jsjson.jval_entries(v)
}

///|
/// What a value is as JavaScript's `String(v)` says it, for the few values these parts turn to words.
pub fn js_text(v : J?) -> String {
  @jsjson.jval_js_str(v)
}

///|
/// Bytes as lowercase hex.
pub fn hex(b : BytesView) -> String {
  @codec.hex_encode(b)
}

///|
/// Hex as bytes (what is not hex read as nothing more).
pub fn unhex(s : String) -> Bytes {
  let out = Buffer()
  let cs = s.to_array()
  let mut i = 0
  while i + 1 < cs.length() {
    match (@codec.hex_digit(cs[i].to_int()), @codec.hex_digit(cs[i + 1].to_int())) {
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
