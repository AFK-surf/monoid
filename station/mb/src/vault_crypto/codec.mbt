// What the vault's formats are written in, as Node's Buffer reads and writes them (station/src/vault/crypto.ts): hex,
// base64 and base64url, decoded as leniently as `Buffer.from(s, enc)` (a character of neither alphabet skipped, the
// first `=` ends it; hex up to its first pair that is not one), so that what the station took, this takes; and JSON
// written as `JSON.stringify` writes it (keys in their order, strings escaped as JS escapes them).

///|
let hex_digits : String = "0123456789abcdef"

///|
let b64_std : String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

///|
let b64_url : String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

///|
/// `b` as lower-case hex.
pub fn hex(b : BytesView) -> String {
  let s = StringBuilder()
  for x in b {
    s.write_char(hex_digits.code_unit_at(x.to_int() >> 4).to_int().unsafe_to_char())
    s.write_char(hex_digits.code_unit_at(x.to_int() & 15).to_int().unsafe_to_char())
  }
  s.to_string()
}

///|
fn hex_value(c : Int) -> Int {
  if c >= 48 && c <= 57 {
    c - 48
  } else if c >= 97 && c <= 102 {
    c - 87
  } else if c >= 65 && c <= 70 {
    c - 55
  } else {
    -1
  }
}

///|
/// `Buffer.from(s, "hex")`: its pairs up to the first that is not one (an odd last character left).
pub fn unhex(s : String) -> Bytes {
  let out : Array[Byte] = []
  let mut i = 0
  while i + 1 < s.length() {
    let hi = hex_value(s.code_unit_at(i).to_int())
    let lo = hex_value(s.code_unit_at(i + 1).to_int())
    if hi < 0 || lo < 0 {
      break
    }
    out.push((hi * 16 + lo).to_byte())
    i = i + 2
  }
  Bytes::from_array(out)
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
fn encode64(b : BytesView, alphabet : String, pad : Bool) -> String {
  let s = StringBuilder()
  let n = b.length()
  let mut i = 0
  while i < n {
    let b0 = b[i].to_int()
    let b1 = if i + 1 < n { b[i + 1].to_int() } else { 0 }
    let b2 = if i + 2 < n { b[i + 2].to_int() } else { 0 }
    let v = (b0 << 16) | (b1 << 8) | b2
    let chars = if i + 2 < n { 4 } else if i + 1 < n { 3 } else { 2 }
    for k in 0..<4 {
      if k < chars {
        s.write_char(alphabet.code_unit_at((v >> (18 - 6 * k)) & 63).to_int().unsafe_to_char())
      } else if pad {
        s.write_char('=')
      }
    }
    i = i + 3
  }
  s.to_string()
}

///|
/// `b` as base64url, unpadded (`toString("base64url")`).
pub fn b64url(b : BytesView) -> String {
  encode64(b, b64_url, false)
}

///|
/// `b` as base64, padded (`toString("base64")`).
pub fn b64(b : BytesView) -> String {
  encode64(b, b64_std, true)
}

///|
fn b64_value(c : Int) -> Int {
  if c >= 65 && c <= 90 {
    c - 65
  } else if c >= 97 && c <= 122 {
    c - 71
  } else if c >= 48 && c <= 57 {
    c + 4
  } else if c == 43 || c == 45 {
    62
  } else if c == 47 || c == 95 {
    63
  } else {
    -1
  }
}

///|
/// `Buffer.from(s, "base64")` or `"base64url"` (Node reads both alphabets either way): what is of neither skipped, the
/// first `=` ending it, a last character alone giving nothing.
pub fn unb64(s : String) -> Bytes {
  let out : Array[Byte] = []
  let mut acc = 0
  let mut n = 0
  for i in 0..<s.length() {
    let c = s.code_unit_at(i).to_int()
    if c == 61 {
      break
    }
    let v = b64_value(c)
    if v < 0 {
      continue
    }
    acc = ((acc << 6) | v) & 0xffffff
    n = n + 6
    if n >= 8 {
      n = n - 8
      out.push(((acc >> n) & 255).to_byte())
    }
  }
  Bytes::from_array(out)
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
  for k in 0..<4 {
    b.write_char(hex_digits.code_unit_at((c >> (12 - 4 * k)) & 15).to_int().unsafe_to_char())
  }
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
