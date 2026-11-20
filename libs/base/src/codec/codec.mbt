// Base64 (RFC 4648 §4, and §5's URL-safe alphabet), hex and the IEEE CRC-32 (the reflected 0xEDB88320 of zlib,
// gzip, zip and PNG), of no dependency, on every target: what a program on this library encodes, decodes and checks
// with, never a copy of its own.

///|
let std_alphabet : String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

///|
let url_alphabet : String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

///|
fn encode_with(data : BytesView, alphabet : String, pad : Bool) -> String {
  let n = data.length()
  let out = StringBuilder(capacity=(n + 2) / 3 * 4)
  let put = (v : Int) => out.write_char(alphabet.get_char(v & 63).unwrap())
  let mut i = 0
  while i + 3 <= n {
    let v = (data[i].to_int() << 16) | (data[i + 1].to_int() << 8) | data[i + 2].to_int()
    put(v >> 18)
    put(v >> 12)
    put(v >> 6)
    put(v)
    i += 3
  }
  match n - i {
    1 => {
      let v = data[i].to_int() << 16
      put(v >> 18)
      put(v >> 12)
      if pad {
        out.write_string("==")
      }
    }
    2 => {
      let v = (data[i].to_int() << 16) | (data[i + 1].to_int() << 8)
      put(v >> 18)
      put(v >> 12)
      put(v >> 6)
      if pad {
        out.write_char('=')
      }
    }
    _ => ()
  }
  out.to_string()
}

///|
/// `data` in standard Base64 (RFC 4648 §4: `+`, `/`), padded with `=` to a multiple of four: node's
/// `Buffer.toString("base64")`, the browser's `btoa` of the bytes.
pub fn base64_encode(data : BytesView) -> String {
  encode_with(data, std_alphabet, true)
}

///|
/// `data` in URL-safe Base64 (RFC 4648 §5: `-`, `_`) with no padding: node's `Buffer.toString("base64url")`, as
/// JWTs and PKCE write it.
pub fn base64url_encode(data : BytesView) -> String {
  encode_with(data, url_alphabet, false)
}

///|
/// Which alphabets and forms a Base64 decoder takes.
priv struct Taking {
  /// `+` and `/` (62 and 63).
  std : Bool
  /// `-` and `_` (62 and 63).
  url : Bool
  /// ASCII spaces, tabs and line ends, anywhere, left out.
  space : Bool
  /// The `=` padding required to make a multiple of four (else it may be left out, but where given is whole).
  padded : Bool
  /// The bits of the last digit past the last byte must be zero.
  exact : Bool
}

///|
/// What a Base64 digit (a UTF-16 code unit) is worth in the alphabets `taking` takes.
fn sextet(c : Int, taking : Taking) -> Int? {
  if c >= 'A'.to_int() && c <= 'Z'.to_int() {
    Some(c - 'A'.to_int())
  } else if c >= 'a'.to_int() && c <= 'z'.to_int() {
    Some(c - 'a'.to_int() + 26)
  } else if c >= '0'.to_int() && c <= '9'.to_int() {
    Some(c - '0'.to_int() + 52)
  } else if taking.std && c == '+'.to_int() {
    Some(62)
  } else if taking.std && c == '/'.to_int() {
    Some(63)
  } else if taking.url && c == '-'.to_int() {
    Some(62)
  } else if taking.url && c == '_'.to_int() {
    Some(63)
  } else {
    None
  }
}

///|
fn is_space(c : Int) -> Bool {
  c == ' '.to_int() || c == '\t'.to_int() || c == '\n'.to_int() || c == '\r'.to_int() || c == 0x0C
}

///|
fn decode_with(text : String, taking : Taking) -> Bytes? {
  let out = FixedArray::make(text.length() / 4 * 3 + 3, b'\x00')
  let mut len = 0
  // The digits taken so far, and the `=` after them; nothing but `=` (and space) after the first `=`.
  let mut digits = 0
  let mut pads = 0
  let mut acc = 0
  for i in 0..<text.length() {
    let c = text.unsafe_get(i).to_int()
    if taking.space && is_space(c) {
      continue
    }
    if c == '='.to_int() {
      pads += 1
      continue
    }
    if pads > 0 {
      return None
    }
    guard sextet(c, taking) is Some(v) else { return None }
    acc = (acc << 6) | v
    digits += 1
    if digits % 4 == 0 {
      out[len] = ((acc >> 16) & 0xFF).to_byte()
      out[len + 1] = ((acc >> 8) & 0xFF).to_byte()
      out[len + 2] = (acc & 0xFF).to_byte()
      len += 3
      acc = 0
    }
  }
  let rest = digits % 4
  // One digit past a whole group is six bits: no byte.
  if rest == 1 {
    return None
  }
  let need = if rest == 0 { 0 } else { 4 - rest }
  if pads != 0 && pads != need {
    return None
  }
  if taking.padded && pads != need {
    return None
  }
  match rest {
    2 => {
      if taking.exact && (acc & 0xF) != 0 {
        return None
      }
      out[len] = ((acc >> 4) & 0xFF).to_byte()
      len += 1
    }
    3 => {
      if taking.exact && (acc & 0x3) != 0 {
        return None
      }
      out[len] = ((acc >> 10) & 0xFF).to_byte()
      out[len + 1] = ((acc >> 2) & 0xFF).to_byte()
      len += 2
    }
    _ => ()
  }
  Some(Bytes::makei(len, i => out[i]))
}

///|
/// The bytes `text` writes in Base64, read as leniently as node's `Buffer.from(text, "base64")` short of its
/// silence: either alphabet (`+/` or `-_`), ASCII space anywhere left out, the `=` padding optional (but, where
/// given, only at the end and making a multiple of four), the bits past the last byte not looked at. `None` where it
/// has anything else, or a lone digit past a group of four. What a JWT, a PKCE verifier or a key file is read with.
pub fn base64_decode(text : String) -> Bytes? {
  decode_with(text, { std: true, url: true, space: true, padded: false, exact: false })
}

///|
/// The bytes `text` writes in standard Base64 strictly (RFC 4648 §4, its canonical form): `+/` alone, padded to a
/// multiple of four, no space, the bits past the last byte zero; `None` otherwise.
pub fn base64_decode_strict(text : String) -> Bytes? {
  decode_with(text, { std: true, url: false, space: false, padded: true, exact: true })
}

///|
/// The bytes `text` writes in URL-safe Base64 (RFC 4648 §5: `-_` alone), padded or not (where padded, whole); no
/// space. `None` otherwise.
pub fn base64url_decode(text : String) -> Bytes? {
  decode_with(text, { std: false, url: true, space: false, padded: false, exact: false })
}

///|
/// The bytes `text` writes in Base64 as Node's `Buffer.from(text, "base64")` / `"base64url"` reads it: either
/// alphabet (`+/` or `-_`), any other character skipped, stopped at the first `=`, and a lone trailing digit ignored.
pub fn base64_decode_loose(text : String) -> Bytes {
  let kept = StringBuilder()
  for c in text {
    if c == '=' {
      break
    }
    if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || "+/-_".contains_char(c) {
      kept.write_char(c)
    }
  }
  let kept = kept.to_string()
  let n = kept.length() - (if kept.length() % 4 == 1 { 1 } else { 0 })
  base64_decode(kept.unsafe_substring(start=0, end=n)).unwrap()
}

///|
fn hex_with(data : BytesView, digits : String) -> String {
  let out = StringBuilder(capacity=data.length() * 2)
  for b in data {
    out.write_char(digits.get_char(b.to_int() >> 4).unwrap())
    out.write_char(digits.get_char(b.to_int() & 0xF).unwrap())
  }
  out.to_string()
}

///|
/// `data` in lowercase hex.
pub fn hex_encode(data : BytesView) -> String {
  hex_with(data, "0123456789abcdef")
}

///|
/// `data` in uppercase hex.
pub fn hex_encode_upper(data : BytesView) -> String {
  hex_with(data, "0123456789ABCDEF")
}

///|
/// What a hex digit of either case (a UTF-16 code unit, or a byte) is worth, 0 to 15; `None` for anything else.
pub fn hex_digit(c : Int) -> Int? {
  if c >= '0'.to_int() && c <= '9'.to_int() {
    Some(c - '0'.to_int())
  } else if c >= 'a'.to_int() && c <= 'f'.to_int() {
    Some(c - 'a'.to_int() + 10)
  } else if c >= 'A'.to_int() && c <= 'F'.to_int() {
    Some(c - 'A'.to_int() + 10)
  } else {
    None
  }
}

///|
/// The bytes `text` writes in hex, of either case; `None` where its length is odd or it has anything but hex digits.
pub fn hex_decode(text : String) -> Bytes? {
  if text.length() % 2 != 0 {
    return None
  }
  let out = FixedArray::make(text.length() / 2, b'\x00')
  for i in 0..<out.length() {
    match (hex_digit(text.unsafe_get(2 * i).to_int()), hex_digit(text.unsafe_get(2 * i + 1).to_int())) {
      (Some(hi), Some(lo)) => out[i] = ((hi << 4) | lo).to_byte()
      _ => return None
    }
  }
  Some(Bytes::makei(out.length(), i => out[i]))
}

///|
/// The CRC-32 of each byte value, reflected, polynomial 0xEDB88320.
let crc_table : FixedArray[UInt] = {
  let table = FixedArray::make(256, 0U)
  for n in 0..<256 {
    let mut c = n.reinterpret_as_uint()
    for _ in 0..<8 {
      c = if (c & 1U) != 0U { 0xEDB88320U ^ (c >> 1) } else { c >> 1 }
    }
    table[n] = c
  }
  table
}

///|
/// The CRC-32 of what gave `crc` followed by `data`: start from 0 (the CRC-32 of nothing) and give each piece in
/// turn, as zlib's `crc32(crc, buf, len)`; the result is the CRC-32 of them all at once.
pub fn crc32_update(crc : UInt, data : BytesView) -> UInt {
  let mut c = crc ^ 0xFFFFFFFFU
  for b in data {
    c = crc_table[((c ^ b.to_uint()) & 0xFFU).reinterpret_as_int()] ^ (c >> 8)
  }
  c ^ 0xFFFFFFFFU
}

///|
/// The IEEE CRC-32 of `data` (zlib's, gzip's, zip's and PNG's).
pub fn crc32(data : BytesView) -> UInt {
  crc32_update(0U, data)
}
