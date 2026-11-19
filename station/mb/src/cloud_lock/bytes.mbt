// The station's lock in MoonBit (station/src/cloud/key.ts, signed.ts, log-keep.ts, lock-bodies.ts, lock.ts, state.ts,
// mesh/person-chains.ts, moved-pin.ts, device-builds.ts, api/moved-from.ts, and the lock's routes of mesh/serve.ts),
// the rules themselves `stillfail/rules` (rules/src) as the TypeScript takes them built to JS: the same answers, the
// same words, the same files. What is bytes as Node has them (its Buffer's lenient hex and base64, UTF-8 with a lone
// surrogate as U+FFFD, JSON.stringify's text) is here, so what is hashed, signed and written is the same byte for byte.

///|
/// Why something is refused (an Error's message in the TypeScript), or a refusal by the lock (`LockRefusal`, the
/// device to be confirmed).
pub(all) suberror Failure {
  Failed(String)
  Refused(String)
}

///|
pub impl Show for Failure with output(self, logger) {
  match self {
    Failed(m) | Refused(m) => logger.write_string(m)
  }
}

///|
/// Its words, as the TypeScript's `(e as Error).message`.
pub fn Failure::message(self : Failure) -> String {
  match self {
    Failed(m) | Refused(m) => m
  }
}

///|
/// The words of anything raised, as the TypeScript's `(e as Error).message` would have them.
fn why_of(e : Error) -> String {
  match e {
    Failure::Failed(m) | Failure::Refused(m) => m
    @lock.Refused(m) | @lock.Refusal(m) => m
    @form.Invalid(m) => m
    _ => e.to_string()
  }
}

// ── bytes as Node has them ─────────────────────────────────────────────────────────────────────────────────────────

///|
/// UTF-8 as Node encodes a string (Buffer.from(s), createHash's update): a lone surrogate as U+FFFD.
pub fn utf8_of(s : String) -> Bytes {
  let out = @buffer.new()
  let n = s.length()
  let mut i = 0
  while i < n {
    let mut c = s.unsafe_charcode_at(i)
    i += 1
    if c >= 0xd800 && c <= 0xdbff && i < n {
      let d = s.unsafe_charcode_at(i)
      if d >= 0xdc00 && d <= 0xdfff {
        c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00)
        i += 1
      } else {
        c = 0xfffd
      }
    } else if c >= 0xd800 && c <= 0xdfff {
      c = 0xfffd
    }
    if c < 0x80 {
      out.write_byte(c.to_byte())
    } else if c < 0x800 {
      out.write_byte((0xc0 | (c >> 6)).to_byte())
      out.write_byte((0x80 | (c & 0x3f)).to_byte())
    } else if c < 0x10000 {
      out.write_byte((0xe0 | (c >> 12)).to_byte())
      out.write_byte((0x80 | ((c >> 6) & 0x3f)).to_byte())
      out.write_byte((0x80 | (c & 0x3f)).to_byte())
    } else {
      out.write_byte((0xf0 | (c >> 18)).to_byte())
      out.write_byte((0x80 | ((c >> 12) & 0x3f)).to_byte())
      out.write_byte((0x80 | ((c >> 6) & 0x3f)).to_byte())
      out.write_byte((0x80 | (c & 0x3f)).to_byte())
    }
  }
  out.to_bytes()
}

///|
fn hex_digit(c : Int) -> Int {
  @codec.hex_digit(c).unwrap_or(-1)
}

///|
/// Hex as Buffer.from(s, "hex") reads it: pairs up to the first that is not hex, an odd last digit dropped.
pub fn hex_bytes(s : String) -> Bytes {
  let out = @buffer.new()
  let mut i = 0
  while i + 1 < s.length() {
    let a = hex_digit(s.unsafe_charcode_at(i))
    let b = hex_digit(s.unsafe_charcode_at(i + 1))
    if a < 0 || b < 0 {
      break
    }
    out.write_byte((a * 16 + b).to_byte())
    i += 2
  }
  out.to_bytes()
}

///|
pub fn hex_of(b : BytesView) -> String {
  @hash.hex_encode(b)
}

///|
/// Base64 or base64url as Buffer.from(s, "base64url") reads it: either alphabet, what is neither skipped, ending at
/// "=".
pub fn b64_bytes(s : String) -> Bytes {
  let digits = StringBuilder()
  let mut n = 0
  for i in 0..<s.length() {
    let c = s.unsafe_charcode_at(i)
    if c == 0x3d {
      break
    }
    if (c >= 0x41 && c <= 0x5a) ||
      (c >= 0x61 && c <= 0x7a) ||
      (c >= 0x30 && c <= 0x39) ||
      c == 0x2b ||
      c == 0x2d ||
      c == 0x2f ||
      c == 0x5f {
      digits.write_char(c.unsafe_to_char())
      n += 1
    }
  }
  let text = digits.to_string()
  // A lone digit past a group of four is six bits: no byte, as Node leaves it.
  let text = if n % 4 == 1 { text.view(end_offset=n - 1).to_string() } else { text }
  @codec.base64_decode(text).unwrap_or(b"")
}

///|
/// Base64url with no padding (Buffer's toString("base64url")).
pub fn b64url_of(b : BytesView) -> String {
  @codec.base64url_encode(b)
}

///|
fn concat(parts : Array[BytesView]) -> Bytes {
  let out = @buffer.new()
  for p in parts {
    out.write_bytesview(p)
  }
  out.to_bytes()
}

///|
/// Whether `s` is 64 lower-case hex digits.
pub fn is_hex32(s : String) -> Bool {
  if s.length() != 64 {
    return false
  }
  for i in 0..<64 {
    let c = s.unsafe_charcode_at(i)
    if !((c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66)) {
      return false
    }
  }
  true
}

// ── SHA-256 (base/hash) ──────────────────────────────────────────────────────────────────────────────────────────

///|
/// SHA-256 of `data`.
pub fn sha256(data : BytesView) -> Bytes {
  @hash.sha256(data)
}

///|
/// SHA-256 of a text's UTF-8 (as Node hashes a string), hex (key.ts `sha256hex`).
pub fn sha256_hex(s : String) -> String {
  @hash.sha256_utf8_hex(s)
}

///|
/// SHA-256 of bytes, hex.
pub fn sha256_hex_bytes(b : BytesView) -> String {
  @hash.sha256_hex(b)
}
