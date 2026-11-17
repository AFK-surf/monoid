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
  if c >= 0x30 && c <= 0x39 {
    c - 0x30
  } else if c >= 0x61 && c <= 0x66 {
    c - 0x61 + 10
  } else if c >= 0x41 && c <= 0x46 {
    c - 0x41 + 10
  } else {
    -1
  }
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
  let digits = "0123456789abcdef"
  let out = StringBuilder()
  for x in b {
    let v = x.to_int()
    out.write_char(digits.unsafe_charcode_at(v >> 4).unsafe_to_char())
    out.write_char(digits.unsafe_charcode_at(v & 15).unsafe_to_char())
  }
  out.to_string()
}

///|
fn b64_value(c : Int) -> Int {
  if c >= 0x41 && c <= 0x5a {
    c - 0x41
  } else if c >= 0x61 && c <= 0x7a {
    c - 0x61 + 26
  } else if c >= 0x30 && c <= 0x39 {
    c - 0x30 + 52
  } else if c == 0x2b || c == 0x2d {
    62
  } else if c == 0x2f || c == 0x5f {
    63
  } else {
    -1
  }
}

///|
/// Base64 or base64url as Buffer.from(s, "base64url") reads it: either alphabet, what is neither skipped, ending at
/// "=".
pub fn b64_bytes(s : String) -> Bytes {
  let out = @buffer.new()
  let mut acc = 0
  let mut bits = 0
  for i in 0..<s.length() {
    let c = s.unsafe_charcode_at(i)
    if c == 0x3d {
      break
    }
    let v = b64_value(c)
    if v < 0 {
      continue
    }
    acc = ((acc << 6) | v) & 0xffffff
    bits += 6
    if bits >= 8 {
      bits -= 8
      out.write_byte(((acc >> bits) & 0xff).to_byte())
    }
  }
  out.to_bytes()
}

///|
/// Base64url with no padding (Buffer's toString("base64url")).
pub fn b64url_of(b : BytesView) -> String {
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  let out = StringBuilder()
  let n = b.length()
  let mut i = 0
  while i < n {
    let b0 = b[i].to_int()
    let b1 = if i + 1 < n { b[i + 1].to_int() } else { 0 }
    let b2 = if i + 2 < n { b[i + 2].to_int() } else { 0 }
    let w = (b0 << 16) | (b1 << 8) | b2
    out.write_char(alphabet.unsafe_charcode_at((w >> 18) & 63).unsafe_to_char())
    out.write_char(alphabet.unsafe_charcode_at((w >> 12) & 63).unsafe_to_char())
    if i + 1 < n {
      out.write_char(alphabet.unsafe_charcode_at((w >> 6) & 63).unsafe_to_char())
    }
    if i + 2 < n {
      out.write_char(alphabet.unsafe_charcode_at(w & 63).unsafe_to_char())
    }
    i += 3
  }
  out.to_string()
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

// ── SHA-256 ──────────────────────────────────────────────────────────────────────────────────────────────────────

///|
let sha_k : FixedArray[UInt] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
  0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
  0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
  0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
  0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
  0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
  0xc67178f2,
]

///|
fn rotr(x : UInt, n : Int) -> UInt {
  (x >> n) | (x << (32 - n))
}

///|
/// SHA-256 of `data`.
pub fn sha256(data : BytesView) -> Bytes {
  let h : FixedArray[UInt] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
    0x5be0cd19,
  ]
  let n = data.length()
  let total = (n + 9 + 63) / 64 * 64
  let msg = FixedArray::make(total, b'\x00')
  for i in 0..<n {
    msg[i] = data[i]
  }
  msg[n] = b'\x80'
  let bits = n.to_int64() * 8L
  for i in 0..<8 {
    msg[total - 1 - i] = ((bits >> (8 * i)) & 0xffL).to_byte()
  }
  let w = FixedArray::make(64, (0 : UInt))
  let mut off = 0
  while off < total {
    for t in 0..<16 {
      let j = off + t * 4
      w[t] = (msg[j].to_uint() << 24) |
        (msg[j + 1].to_uint() << 16) |
        (msg[j + 2].to_uint() << 8) |
        msg[j + 3].to_uint()
    }
    for t in 16..<64 {
      let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
      let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
      w[t] = w[t - 16] + s0 + w[t - 7] + s1
    }
    let mut a = h[0]
    let mut b = h[1]
    let mut c = h[2]
    let mut d = h[3]
    let mut e = h[4]
    let mut f = h[5]
    let mut g = h[6]
    let mut hh = h[7]
    for t in 0..<64 {
      let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
      let ch = (e & f) ^ (e.lnot() & g)
      let t1 = hh + s1 + ch + sha_k[t] + w[t]
      let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
      let maj = (a & b) ^ (a & c) ^ (b & c)
      let t2 = s0 + maj
      hh = g
      g = f
      f = e
      e = d + t1
      d = c
      c = b
      b = a
      a = t1 + t2
    }
    h[0] += a
    h[1] += b
    h[2] += c
    h[3] += d
    h[4] += e
    h[5] += f
    h[6] += g
    h[7] += hh
    off += 64
  }
  let out = FixedArray::make(32, b'\x00')
  for i in 0..<8 {
    out[i * 4] = (h[i] >> 24).to_byte()
    out[i * 4 + 1] = (h[i] >> 16).to_byte()
    out[i * 4 + 2] = (h[i] >> 8).to_byte()
    out[i * 4 + 3] = h[i].to_byte()
  }
  Bytes::from_fixedarray(out)
}

///|
/// SHA-256 of a text's UTF-8 (as Node hashes a string), hex (key.ts `sha256hex`).
pub fn sha256_hex(s : String) -> String {
  hex_of(sha256(utf8_of(s)))
}

///|
/// SHA-256 of bytes, hex.
pub fn sha256_hex_bytes(b : BytesView) -> String {
  hex_of(sha256(b))
}
