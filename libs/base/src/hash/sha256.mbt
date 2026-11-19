// SHA-256 (FIPS 180-4) and HMAC-SHA-256 (RFC 2104), of no dependency, on every target: taken a piece at a time
// (`Sha256`, as node:crypto's `createHash("sha256").update(…)`) or at once, with the lowercase hex a digest is
// written in and read back from. What a program on this library hashes it hashes here, never with a copy of its own.

///|
let k256 : FixedArray[UInt] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
  0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
  0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]

///|
/// A SHA-256 taken a piece at a time: `update` with each piece, then `digest` (or `hex`) of all given so far. A
/// digest spends nothing: more may be given after it, and the next digest is of all of it.
pub struct Sha256 {
  priv h : FixedArray[UInt]
  /// The block being filled, `fill` bytes of it.
  priv block : FixedArray[Byte]
  priv mut fill : Int
  /// How many bytes were given in all.
  priv mut total : UInt64
  priv w : FixedArray[UInt]
}

///|
pub fn Sha256::new() -> Sha256 {
  {
    h: [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19],
    block: FixedArray::make(64, b'\x00'),
    fill: 0,
    total: 0UL,
    w: FixedArray::make(64, 0U),
  }
}

///|
fn rotr(x : UInt, n : Int) -> UInt {
  (x >> n) | (x << (32 - n))
}

///|
/// One block (`block`, whole) into `h`.
fn compress(h : FixedArray[UInt], block : FixedArray[Byte], w : FixedArray[UInt]) -> Unit {
  for t in 0..<16 {
    let at = 4 * t
    w[t] = (block[at].to_uint() << 24) |
      (block[at + 1].to_uint() << 16) |
      (block[at + 2].to_uint() << 8) |
      block[at + 3].to_uint()
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
    let t1 = hh + s1 + ch + k256[t] + w[t]
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
  h[0] = h[0] + a
  h[1] = h[1] + b
  h[2] = h[2] + c
  h[3] = h[3] + d
  h[4] = h[4] + e
  h[5] = h[5] + f
  h[6] = h[6] + g
  h[7] = h[7] + hh
}

///|
/// One byte more.
fn Sha256::byte(self : Sha256, b : Byte) -> Unit {
  self.block[self.fill] = b
  self.fill += 1
  self.total += 1UL
  if self.fill == 64 {
    compress(self.h, self.block, self.w)
    self.fill = 0
  }
}

///|
/// `data`, after what was given before.
pub fn Sha256::update(self : Sha256, data : BytesView) -> Unit {
  for b in data {
    self.byte(b)
  }
}

///|
/// The digest of all given so far: 32 bytes.
pub fn Sha256::digest(self : Sha256) -> Bytes {
  // (on copies: the hash goes on as it was)
  let h = FixedArray::make(8, 0U)
  for i in 0..<8 {
    h[i] = self.h[i]
  }
  let block = FixedArray::make(64, b'\x00')
  for i in 0..<self.fill {
    block[i] = self.block[i]
  }
  let w = FixedArray::make(64, 0U)
  // A 1 bit, zeros to 56 bytes past a block, the length in bits as 8 bytes big-endian.
  let mut fill = self.fill
  block[fill] = b'\x80'
  fill += 1
  if fill > 56 {
    for i in fill..<64 {
      block[i] = b'\x00'
    }
    compress(h, block, w)
    fill = 0
  }
  for i in fill..<56 {
    block[i] = b'\x00'
  }
  let bits = self.total * 8UL
  for i in 0..<8 {
    block[56 + i] = (bits >> (56 - 8 * i)).to_byte()
  }
  compress(h, block, w)
  Bytes::makei(32, i => (h[i / 4] >> (24 - 8 * (i % 4))).to_byte())
}

///|
/// The digest of all given so far, in lowercase hex.
pub fn Sha256::hex(self : Sha256) -> String {
  hex_encode(self.digest())
}

///|
/// The SHA-256 digest of `data`: 32 bytes.
pub fn sha256(data : BytesView) -> Bytes {
  let s = Sha256::new()
  s.update(data)
  s.digest()
}

///|
/// The SHA-256 digest of `data`, in lowercase hex (node:crypto's `digest("hex")`).
pub fn sha256_hex(data : BytesView) -> String {
  hex_encode(sha256(data))
}

///|
/// The SHA-256 digest of `text`'s UTF-8, in lowercase hex: as node:crypto hashes a string, a lone surrogate taken for
/// U+FFFD (EF BF BD).
pub fn sha256_utf8_hex(text : String) -> String {
  let s = Sha256::new()
  utf8_each(text, b => s.byte(b))
  s.hex()
}

///|
/// Each byte of `text`'s UTF-8 in turn, a lone surrogate taken for U+FFFD (EF BF BD) as node:crypto takes it, where
/// `@utf8.encode` would abort.
fn utf8_each(text : String, put : (Byte) -> Unit) -> Unit {
  for c in text {
    let n = c.to_int()
    let n = if n >= 0xD800 && n <= 0xDFFF { 0xFFFD } else { n }
    if n < 0x80 {
      put(n.to_byte())
    } else if n < 0x800 {
      put((0xC0 | (n >> 6)).to_byte())
      put((0x80 | (n & 0x3F)).to_byte())
    } else if n < 0x10000 {
      put((0xE0 | (n >> 12)).to_byte())
      put((0x80 | ((n >> 6) & 0x3F)).to_byte())
      put((0x80 | (n & 0x3F)).to_byte())
    } else {
      put((0xF0 | (n >> 18)).to_byte())
      put((0x80 | ((n >> 12) & 0x3F)).to_byte())
      put((0x80 | ((n >> 6) & 0x3F)).to_byte())
      put((0x80 | (n & 0x3F)).to_byte())
    }
  }
}

///|
/// HMAC-SHA-256 (RFC 2104) of `data` under `key`: 32 bytes.
pub fn hmac_sha256(key : BytesView, data : BytesView) -> Bytes {
  let k = if key.length() > 64 { sha256(key)[:] } else { key }
  let pad = (by : Int) => Bytes::makei(64, i => ((if i < k.length() { k[i].to_int() } else { 0 }) ^ by).to_byte())
  let inner = Sha256::new()
  inner.update(pad(0x36))
  inner.update(data)
  let outer = Sha256::new()
  outer.update(pad(0x5c))
  outer.update(inner.digest())
  outer.digest()
}

///|
/// `data` in lowercase hex.
pub fn hex_encode(data : BytesView) -> String {
  let digits = "0123456789abcdef"
  let out = StringBuilder(capacity=data.length() * 2)
  for b in data {
    out.write_char(digits.get_char(b.to_int() >> 4).unwrap())
    out.write_char(digits.get_char(b.to_int() & 0xF).unwrap())
  }
  out.to_string()
}

///|
/// The bytes `text` writes in hex, of either case; `None` where its length is odd or it has anything but hex digits.
pub fn hex_decode(text : String) -> Bytes? {
  if text.length() % 2 != 0 {
    return None
  }
  let out = FixedArray::make(text.length() / 2, b'\x00')
  for i in 0..<out.length() {
    match (nibble(text.unsafe_get(2 * i).to_int()), nibble(text.unsafe_get(2 * i + 1).to_int())) {
      (Some(hi), Some(lo)) => out[i] = ((hi << 4) | lo).to_byte()
      _ => return None
    }
  }
  Some(Bytes::makei(out.length(), i => out[i]))
}

///|
/// What a hex digit (a UTF-16 code unit) is worth.
fn nibble(c : Int) -> Int? {
  if c >= '0' && c <= '9' {
    Some(c - '0')
  } else if c >= 'a' && c <= 'f' {
    Some(c - 'a' + 10)
  } else if c >= 'A' && c <= 'F' {
    Some(c - 'A' + 10)
  } else {
    None
  }
}
