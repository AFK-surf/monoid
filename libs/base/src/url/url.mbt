// Percent-encoding of a text's UTF-8 (RFC 3986 §2.1), as ECMA-262 has it: `encodeURIComponent`, `encodeURI` and
// `decodeURIComponent` byte for byte, with uppercase hex; and an encoder keeping what its caller says (a form's
// `+` for a space among them). Of no dependency but the base's hex digits, on every target: what a program on this
// library writes a URL's parts with, never a copy of its own.

///|
let upper_digits : String = "0123456789ABCDEF"

///|
/// What `encodeURIComponent` leaves as it is: letters, digits and `- _ . ! ~ * ' ( )`.
fn unreserved(b : Int) -> Bool {
  (b >= 'a' && b <= 'z') ||
  (b >= 'A' && b <= 'Z') ||
  (b >= '0' && b <= '9') ||
  b == '-' ||
  b == '_' ||
  b == '.' ||
  b == '!' ||
  b == '~' ||
  b == '*' ||
  b == '\'' ||
  b == '(' ||
  b == ')'
}

///|
/// What `encodeURI` leaves as it is: the unreserved, the reserved `; , / ? : @ & = + $` and `#`.
fn uri_kept(b : Int) -> Bool {
  unreserved(b) ||
  b == ';' ||
  b == ',' ||
  b == '/' ||
  b == '?' ||
  b == ':' ||
  b == '@' ||
  b == '&' ||
  b == '=' ||
  b == '+' ||
  b == '$' ||
  b == '#'
}

///|
/// `s`'s UTF-8 written out: an ASCII byte `keep` takes as it is, a space as `+` where `space_plus`, every other byte
/// as `%XX`. A lone surrogate is U+FFFD (as `TextEncoder` takes it), or `None` where `strict` (as ECMA-262's
/// `URIError`).
fn encode_with(s : String, keep : (Int) -> Bool, space_plus : Bool, strict : Bool) -> String? {
  let out = StringBuilder(capacity=s.length())
  let byte = (b : Int) => if space_plus && b == ' ' {
    out.write_char('+')
  } else if b < 0x80 && keep(b) {
    out.write_char(b.unsafe_to_char())
  } else {
    out.write_char('%')
    out.write_char(upper_digits.get_char(b >> 4).unwrap())
    out.write_char(upper_digits.get_char(b & 0xF).unwrap())
  }
  let n = s.length()
  let mut i = 0
  while i < n {
    let u = s.unsafe_get(i).to_int()
    i += 1
    let cp = if u >= 0xD800 && u <= 0xDBFF && i < n {
      let lo = s.unsafe_get(i).to_int()
      if lo >= 0xDC00 && lo <= 0xDFFF {
        i += 1
        0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
      } else {
        -1
      }
    } else if u >= 0xD800 && u <= 0xDFFF {
      -1
    } else {
      u
    }
    let cp = if cp >= 0 {
      cp
    } else if strict {
      return None
    } else {
      0xFFFD
    }
    if cp < 0x80 {
      byte(cp)
    } else if cp < 0x800 {
      byte(0xC0 | (cp >> 6))
      byte(0x80 | (cp & 0x3F))
    } else if cp < 0x10000 {
      byte(0xE0 | (cp >> 12))
      byte(0x80 | ((cp >> 6) & 0x3F))
      byte(0x80 | (cp & 0x3F))
    } else {
      byte(0xF0 | (cp >> 18))
      byte(0x80 | ((cp >> 12) & 0x3F))
      byte(0x80 | ((cp >> 6) & 0x3F))
      byte(0x80 | (cp & 0x3F))
    }
  }
  Some(out.to_string())
}

///|
/// ECMA-262's `encodeURIComponent`, but that a lone surrogate is written as U+FFFD (`%EF%BF%BD`) where it throws.
pub fn encode_uri_component(s : String) -> String {
  encode_with(s, unreserved, false, false).unwrap()
}

///|
/// ECMA-262's `encodeURIComponent`: `None` where it throws `URIError` (a lone surrogate).
pub fn encode_uri_component_strict(s : String) -> String? {
  encode_with(s, unreserved, false, true)
}

///|
/// ECMA-262's `encodeURI`, but that a lone surrogate is written as U+FFFD (`%EF%BF%BD`) where it throws.
pub fn encode_uri(s : String) -> String {
  encode_with(s, uri_kept, false, false).unwrap()
}

///|
/// `s`'s UTF-8 with each ASCII byte `keep` takes (given as a number, 0 to 127) left as it is and every other byte
/// written `%XX` in uppercase hex; where `space_plus`, a space is `+` (an HTML form's
/// `application/x-www-form-urlencoded`) whatever `keep` says of it. A lone surrogate is U+FFFD. A byte past ASCII is
/// always encoded, whatever `keep` says.
pub fn percent_encode(s : String, keep : (Int) -> Bool, space_plus? : Bool = false) -> String {
  encode_with(s, keep, space_plus, false).unwrap()
}

///|
/// The byte `%XX` at `at` in `s` writes; -1 where there is none (no `%`, too short, not hex).
fn escaped_at(s : String, at : Int) -> Int {
  if at + 3 > s.length() {
    return -1
  }
  if s.unsafe_get(at).to_int() != '%' {
    return -1
  }
  match (@codec.hex_digit(s.unsafe_get(at + 1).to_int()), @codec.hex_digit(s.unsafe_get(at + 2).to_int())) {
    (Some(hi), Some(lo)) => (hi << 4) | lo
    _ => -1
  }
}

///|
/// ECMA-262's `decodeURIComponent`: each `%XX` read as UTF-8 (the code units between left as they are, a lone
/// surrogate among them too); `None` where it throws `URIError`: a `%` without two hex digits after it, a byte that
/// begins no UTF-8 sequence, a sequence cut short or not continued by `%XX`, written longer than it needs, or of a
/// surrogate or past U+10FFFF.
pub fn decode_uri_component(s : String) -> String? {
  let out = StringBuilder(capacity=s.length())
  let n = s.length()
  let mut i = 0
  while i < n {
    let u = s.unsafe_get(i).to_int()
    if u != '%' {
      out.write_char(u.unsafe_to_char())
      i += 1
      continue
    }
    let b = escaped_at(s, i)
    if b < 0 {
      return None
    }
    i += 3
    if b < 0x80 {
      out.write_char(b.unsafe_to_char())
      continue
    }
    let (more, least, first) = if (b & 0xE0) == 0xC0 {
      (1, 0x80, b & 0x1F)
    } else if (b & 0xF0) == 0xE0 {
      (2, 0x800, b & 0x0F)
    } else if (b & 0xF8) == 0xF0 {
      (3, 0x10000, b & 0x07)
    } else {
      return None
    }
    let mut cp = first
    for _ in 0..<more {
      let c = escaped_at(s, i)
      if c < 0 || (c & 0xC0) != 0x80 {
        return None
      }
      cp = (cp << 6) | (c & 0x3F)
      i += 3
    }
    if cp < least || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) {
      return None
    }
    out.write_char(cp.unsafe_to_char())
  }
  Some(out.to_string())
}

///|
/// Percent-decoding of `s` as `URLSearchParams` / `application/x-www-form-urlencoded` (when `plus_space` is true) or
/// lossy percent-decode: `%XX` (two hex digits) decoded as a byte, `+` as a space where `plus_space`, any other `%`
/// kept as it is, lone surrogates replaced with U+FFFD, and the resulting bytes decoded as UTF-8 lossily.
pub fn percent_decode_lossy(s : String, plus_space? : Bool = false) -> String {
  let out = Buffer()
  let n = s.length()
  let mut i = 0
  while i < n {
    let u = s.unsafe_get(i).to_int()
    if u == '%' &&
      i + 2 < n &&
      @codec.hex_digit(s.unsafe_get(i + 1).to_int()) is Some(hi) &&
      @codec.hex_digit(s.unsafe_get(i + 2).to_int()) is Some(lo) {
      out.write_byte(((hi << 4) | lo).to_byte())
      i += 3
      continue
    }
    if plus_space && u == '+' {
      out.write_byte(b' ')
      i += 1
      continue
    }
    i += 1
    let cp = if u >= 0xD800 && u <= 0xDBFF && i < n {
      let lo = s.unsafe_get(i).to_int()
      if lo >= 0xDC00 && lo <= 0xDFFF {
        i += 1
        0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
      } else {
        0xFFFD
      }
    } else if u >= 0xD800 && u <= 0xDFFF {
      0xFFFD
    } else {
      u
    }
    if cp < 0x80 {
      out.write_byte(cp.to_byte())
    } else if cp < 0x800 {
      out.write_byte((0xC0 | (cp >> 6)).to_byte())
      out.write_byte((0x80 | (cp & 0x3F)).to_byte())
    } else if cp < 0x10000 {
      out.write_byte((0xE0 | (cp >> 12)).to_byte())
      out.write_byte((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      out.write_byte((0x80 | (cp & 0x3F)).to_byte())
    } else {
      out.write_byte((0xF0 | (cp >> 18)).to_byte())
      out.write_byte((0x80 | ((cp >> 12) & 0x3F)).to_byte())
      out.write_byte((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      out.write_byte((0x80 | (cp & 0x3F)).to_byte())
    }
  }
  @utf8.decode_lossy(out.to_bytes())
}
