// What the vault's formats are written in, as Node's Buffer reads and writes them (station/src/vault/crypto.ts): hex,
// base64 and base64url, decoded as leniently as `Buffer.from(s, enc)` (a character of neither alphabet skipped, the
// first `=` ends it; hex up to its first pair that is not one), so that what the station took, this takes; and JSON
// written as `JSON.stringify` writes it (keys in their order, strings escaped as JS escapes them).

///|
/// `b` as lower-case hex.
pub fn hex(b : BytesView) -> String {
  @codec.hex_encode(b)
}

///|
/// `Buffer.from(s, "hex")`: its pairs up to the first that is not one (an odd last character left).
pub fn unhex(s : String) -> Bytes {
  let mut n = 0
  while n < s.length() && @codec.hex_digit(s.code_unit_at(n).to_int()) is Some(_) {
    n += 1
  }
  @codec.hex_decode(s.unsafe_substring(start=0, end=n / 2 * 2)).unwrap()
}

///|
/// Whether `s` is exactly `n` bytes' hex, lower-case.
pub fn hex_of_length(s : String, n : Int) -> Bool {
  if s.length() != n * 2 {
    return false
  }
  for i in 0..<s.length() {
    let c = s.code_unit_at(i).to_int()
    if !((c >= 48 && c <= 57) || (c >= 97 && c <= 102)) {
      return false
    }
  }
  true
}

///|
/// `b` as base64url, unpadded (`toString("base64url")`).
pub fn b64url(b : BytesView) -> String {
  @codec.base64url_encode(b)
}

///|
/// `b` as base64, padded (`toString("base64")`).
pub fn b64(b : BytesView) -> String {
  @codec.base64_encode(b)
}

///|
/// `Buffer.from(s, "base64")` or `"base64url"` (Node reads both alphabets either way): what is of neither skipped, the
/// first `=` ending it, a last character alone giving nothing.
pub fn unb64(s : String) -> Bytes {
  let kept = StringBuilder()
  for c in s {
    if c == '=' {
      break
    }
    if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || "+/-_".contains_char(c) {
      kept.write_char(c)
    }
  }
  let kept = kept.to_string()
  // (a lone letter at the end makes no byte)
  let n = kept.length() - (if kept.length() % 4 == 1 { 1 } else { 0 })
  @codec.base64_decode(kept.unsafe_substring(start=0, end=n)).unwrap()
}

///|
/// `s` in UTF-8 (`Buffer.from(s)`: a lone surrogate as U+FFFD).
pub fn utf8(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
/// The text of UTF-8 bytes (`toString("utf8")`: what is not UTF-8 as U+FFFD).
pub fn text_of_bytes(b : BytesView) -> String {
  @utf8.decode_lossy(b)
}

///|
fn unicode_escape(b : StringBuilder, c : Int) -> Unit {
  b.write_string("\\u")
  b.write_string(@codec.hex_encode(Bytes::from_array([(c >> 8).to_byte(), (c & 255).to_byte()])))
}

///|
/// `s` as `JSON.stringify` writes a string.
pub fn quote(b : StringBuilder, s : String) -> Unit {
  b.write_char('"')
  let n = s.length()
  let mut i = 0
  while i < n {
    let c = s.code_unit_at(i).to_int()
    if c == 0x22 {
      b.write_string("\\\"")
    } else if c == 0x5c {
      b.write_string("\\\\")
    } else if c == 0x08 {
      b.write_string("\\b")
    } else if c == 0x0c {
      b.write_string("\\f")
    } else if c == 0x0a {
      b.write_string("\\n")
    } else if c == 0x0d {
      b.write_string("\\r")
    } else if c == 0x09 {
      b.write_string("\\t")
    } else if c < 0x20 {
      unicode_escape(b, c)
    } else if c >= 0xd800 && c <= 0xdbff {
      let d = if i + 1 < n { s.code_unit_at(i + 1).to_int() } else { 0 }
      if d >= 0xdc00 && d <= 0xdfff {
        b.write_char((0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00)).unsafe_to_char())
        i = i + 1
      } else {
        unicode_escape(b, c)
      }
    } else if c >= 0xdc00 && c <= 0xdfff {
      unicode_escape(b, c)
    } else {
      b.write_char(c.unsafe_to_char())
    }
    i = i + 1
  }
  b.write_char('"')
}

///|
/// A number as JS writes it: a whole one below 1e21 without a fraction.
pub fn js_number(n : Double) -> String {
  if n != n {
    "null"
  } else if n == n.floor() && n.abs() < 1.0e21 {
    if n == 0.0 {
      "0"
    } else {
      n.to_int64().to_string()
    }
  } else if n.abs() == @double.infinity {
    "null"
  } else {
    n.to_string()
  }
}

///|
fn write_json(b : StringBuilder, v : Json) -> Unit {
  match v {
    Null => b.write_string("null")
    True => b.write_string("true")
    False => b.write_string("false")
    Number(n, ..) => b.write_string(js_number(n))
    String(s) => quote(b, s)
    Array(xs) => {
      b.write_char('[')
      for i, x in xs {
        if i > 0 {
          b.write_char(',')
        }
        write_json(b, x)
      }
      b.write_char(']')
    }
    Object(m) => {
      b.write_char('{')
      let mut first = true
      for k, x in m {
        if !first {
          b.write_char(',')
        }
        first = false
        quote(b, k)
        b.write_char(':')
        write_json(b, x)
      }
      b.write_char('}')
    }
  }
}

///|
/// `JSON.stringify(v)`: its keys in their order, no space.
pub fn stringify(v : Json) -> String {
  let b = StringBuilder()
  write_json(b, v)
  b.to_string()
}

///|
fn of_js(v : @jsjson.JValue) -> Json {
  match v {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Num(n) => Json::number(n)
    Str(s) => Json::string(@jsjson.raw_text(s))
    Arr(xs) => Json::array(xs.map(of_js))
    Obj(kvs) => {
      let m : Map[String, Json] = Map([])
      for kv in kvs {
        m[@jsjson.raw_text(kv.0)] = of_js(kv.1)
      }
      Json::object(m)
    }
  }
}

///|
/// `JSON.parse(text)`: a lone surrogate kept, a duplicate key's last value in its first place, integer-like keys first.
pub fn parse_js(text : String) -> Json raise {
  of_js(@jsjson.parse(text))
}
