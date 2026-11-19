// Values as JavaScript has them (@jsjson.JV: JSON.parse and JSON.stringify exactly), and what the Feishu code asks
// of them as the TypeScript did (`text(v)`, `v?.a?.b`, `String(v)`, `Number(s)`, `s.trim()`): an object's fields in
// JavaScript's order, a lone surrogate of a string kept (this package's `parse`, unlike @jsjson's `jv_parse`). An
// object's fields are kept in a mutable array: what the TypeScript changed in place, a kept file's maps, is changed in
// place here too (`jput`, `jdelete`).

///|
pub using @jsjson {
  type JV,
  jget,
  js,
  jnum,
  jint,
  jopt,
  jstr,
  jnumber,
  jitems,
  jat,
  jput,
  jdelete,
  jkeys,
  jvalues,
  jv_parse_raw as parse,
  try_parse_raw as try_parse,
  jv_stringify as stringify,
  jv_js_string as js_string,
  is_object as is_record,
  is_finite,
  js_number,
  js_round,
  points,
  num_text,
  trim_js,
}

///|
using @jsjson {index_key}

///|
pub using @jscase {
  is_space as is_js_space,
  trim_end as trim_end_js,
}

///|
/// An object literal of these fields, in JavaScript's order (a field whose value is None, undefined, left out).
pub fn jobj(fields : Array[(String, JV?)]) -> JV {
  let o = JV::Obj([])
  for f in fields {
    match f.1 {
      Some(v) => jput(o, f.0, v)
      None => ()
    }
  }
  o
}

///|
/// `text(v)`: the string it is, else "".
pub fn text(v : JV?) -> String {
  match v {
    Some(Str(s)) => s
    _ => ""
  }
}

///|
/// `v ?? null`: undefined as null.
pub fn or_null(v : JV?) -> JV {
  v.unwrap_or(Null)
}

///|
/// `v ?? fallback`: what is neither undefined nor null, else the fallback.
pub fn nullish(v : JV?, fallback : JV) -> JV {
  match v {
    None | Some(Null) => fallback
    Some(x) => x
  }
}

///|
/// `s.slice(a, b)` by code units, as JavaScript clamps it.
pub fn slice_js(s : String, a : Int, b? : Int = s.length()) -> String {
  @jsjson.js_slice(s, a, end=b)
}

///|
/// `a.split(sep).join(by)` (sep not empty): every occurrence, left to right.
pub fn replace_every(a : String, sep : String, by : String) -> String {
  if sep == "" {
    a
  } else {
    a.replace_all(old=sep, new=by)
  }
}

///|
/// `s.startsWith(p)`.
pub fn starts(s : String, p : String) -> Bool {
  s.has_prefix(p)
}

///|
/// `s.includes(p)`.
pub fn has(s : String, p : String) -> Bool {
  s.contains(p)
}

///|
/// A number as an Int64 the way a whole one is (the harness's).
pub fn whole(d : Double) -> Int64 {
  if d.is_nan() {
    0L
  } else {
    d.to_int64()
  }
}

///|
/// encodeURIComponent: every code unit but `A-Za-z0-9-_.!~*'()` as its UTF-8 percent-encoded (a lone surrogate is a
/// URIError, as JavaScript throws).
pub fn encode_uri_component(s : String) -> String raise FeishuError {
  match @url.encode_uri_component_strict(s) {
    Some(v) => v
    None => raise FeishuError("URI malformed")
  }
}

///|
/// A code point's UTF-8 bytes.
fn utf8_of_point(cp : Int) -> Array[Int] {
  if cp < 0x80 {
    [cp]
  } else if cp < 0x800 {
    [0xc0 | (cp >> 6), 0x80 | (cp & 0x3f)]
  } else if cp < 0x10000 {
    [0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f)]
  } else {
    [
      0xf0 | (cp >> 18),
      0x80 | ((cp >> 12) & 0x3f),
      0x80 | ((cp >> 6) & 0x3f),
      0x80 | (cp & 0x3f),
    ]
  }
}

///|
/// TextEncoder's UTF-8 (`Buffer.from(s)` too): a lone surrogate as U+FFFD.
pub fn utf8(s : String) -> Bytes {
  let out = []
  let mut i = 0
  while i < s.length() {
    let c = s.unsafe_charcode_at(i)
    let mut cp = c
    if c >= 0xd800 && c <= 0xdbff {
      if i + 1 < s.length() &&
        s.unsafe_charcode_at(i + 1) >= 0xdc00 &&
        s.unsafe_charcode_at(i + 1) <= 0xdfff {
        cp = 0x10000 + ((c - 0xd800) << 10) + (s.unsafe_charcode_at(i + 1) - 0xdc00)
        i += 1
      } else {
        cp = 0xfffd
      }
    } else if c >= 0xdc00 && c <= 0xdfff {
      cp = 0xfffd
    }
    i += 1
    for b in utf8_of_point(cp) {
      out.push(b.to_byte())
    }
  }
  Bytes::from_array(out)
}

///|
/// UTF-8 as WHATWG's decoder reads it (TextDecoder, Buffer's toString): each ill-formed sequence's maximal part one
/// U+FFFD. `bom`: a leading byte order mark taken off (TextDecoder's default; Buffer keeps it).
pub fn utf8_text(b : BytesView, bom? : Bool = false) -> String {
  let out = StringBuilder::new()
  let n = b.length()
  let mut i = 0
  if bom && n >= 3 && b[0] == b'\xEF' && b[1] == b'\xBB' && b[2] == b'\xBF' {
    i = 3
  }
  while i < n {
    let c = b[i].to_int()
    if c < 0x80 {
      out.write_char(c.unsafe_to_char())
      i += 1
      continue
    }
    let (need, init, lo, hi) = if c >= 0xc2 && c <= 0xdf {
      (1, c & 0x1f, 0x80, 0xbf)
    } else if c == 0xe0 {
      (2, c & 0x0f, 0xa0, 0xbf)
    } else if c == 0xed {
      (2, c & 0x0f, 0x80, 0x9f)
    } else if c >= 0xe1 && c <= 0xef {
      (2, c & 0x0f, 0x80, 0xbf)
    } else if c == 0xf0 {
      (3, c & 0x07, 0x90, 0xbf)
    } else if c == 0xf4 {
      (3, c & 0x07, 0x80, 0x8f)
    } else if c >= 0xf1 && c <= 0xf3 {
      (3, c & 0x07, 0x80, 0xbf)
    } else {
      (0, 0, 0, 0)
    }
    if need == 0 {
      out.write_char('\u{fffd}')
      i += 1
      continue
    }
    let mut cp = init
    let mut j = i + 1
    let mut ok = true
    let mut first = true
    for _ in 0..<need {
      if j >= n {
        ok = false
        break
      }
      let d = b[j].to_int()
      let (l, h) = if first { (lo, hi) } else { (0x80, 0xbf) }
      if d < l || d > h {
        ok = false
        break
      }
      first = false
      cp = (cp << 6) | (d & 0x3f)
      j += 1
    }
    if ok {
      out.write_char(cp.unsafe_to_char())
    } else {
      out.write_char('\u{fffd}')
    }
    i = j
  }
  out.to_string()
}

///|
/// A Feishu call or step that failed: its words, as the TypeScript's Error said them.
pub(all) suberror FeishuError {
  FeishuError(String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for FeishuError with output(self, logger) {
  match self {
    FeishuError(m) => logger.write_string(m)
  }
}

///|
/// An error's words (`(error as Error).message`).
pub fn error_words(e : Error) -> String {
  match e {
    FeishuError(m) => m
    ApiError(m, _) => m
    @jsjson.SyntaxError(m) => m
    _ => {
      let s = e.to_string()
      s
    }
  }
}
