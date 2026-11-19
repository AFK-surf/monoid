// SHA-1 (FIPS 180-4, RFC 3174), taken a piece at a time (`Sha1`) or at once, as `Sha256` beside it. Broken for
// signatures and anything a forger may choose: here for what a protocol or format names it in (WebSocket's accept key,
// Git's object names, a peer's digest to compare), never to make a new check of trust with.

///|
/// A SHA-1 taken a piece at a time: `update` with each piece, then `digest` (or `hex`) of all given so far. A digest
/// spends nothing: more may be given after it, and the next digest is of all of it.
pub struct Sha1 {
  priv h : FixedArray[UInt]
  /// The block being filled, `fill` bytes of it.
  priv block : FixedArray[Byte]
  priv mut fill : Int
  /// How many bytes were given in all.
  priv mut total : UInt64
  priv w : FixedArray[UInt]
}

///|
pub fn Sha1::new() -> Sha1 {
  {
    h: [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0],
    block: FixedArray::make(64, b'\x00'),
    fill: 0,
    total: 0UL,
    w: FixedArray::make(80, 0U),
  }
}

///|
fn rotl(x : UInt, n : Int) -> UInt {
  (x << n) | (x >> (32 - n))
}

///|
/// One block (`block`, whole) into `h`.
fn compress1(h : FixedArray[UInt], block : FixedArray[Byte], w : FixedArray[UInt]) -> Unit {
  for t in 0..<16 {
    let at = 4 * t
    w[t] = (block[at].to_uint() << 24) |
      (block[at + 1].to_uint() << 16) |
      (block[at + 2].to_uint() << 8) |
      block[at + 3].to_uint()
  }
  for t in 16..<80 {
    w[t] = rotl(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1)
  }
  let mut a = h[0]
  let mut b = h[1]
  let mut c = h[2]
  let mut d = h[3]
  let mut e = h[4]
  for t in 0..<80 {
    let (f, k) = if t < 20 {
      ((b & c) | (b.lnot() & d), 0x5A827999U)
    } else if t < 40 {
      (b ^ c ^ d, 0x6ED9EBA1U)
    } else if t < 60 {
      ((b & c) | (b & d) | (c & d), 0x8F1BBCDCU)
    } else {
      (b ^ c ^ d, 0xCA62C1D6U)
    }
    let temp = rotl(a, 5) + f + e + k + w[t]
    e = d
    d = c
    c = rotl(b, 30)
    b = a
    a = temp
  }
  h[0] = h[0] + a
  h[1] = h[1] + b
  h[2] = h[2] + c
  h[3] = h[3] + d
  h[4] = h[4] + e
}

///|
/// One byte more.
fn Sha1::byte(self : Sha1, b : Byte) -> Unit {
  self.block[self.fill] = b
  self.fill += 1
  self.total += 1UL
  if self.fill == 64 {
    compress1(self.h, self.block, self.w)
    self.fill = 0
  }
}

///|
/// `data`, after what was given before.
pub fn Sha1::update(self : Sha1, data : BytesView) -> Unit {
  for b in data {
    self.byte(b)
  }
}

///|
/// The digest of all given so far: 20 bytes.
pub fn Sha1::digest(self : Sha1) -> Bytes {
  // (on copies: the hash goes on as it was)
  let h = FixedArray::make(5, 0U)
  for i in 0..<5 {
    h[i] = self.h[i]
  }
  let block = FixedArray::make(64, b'\x00')
  for i in 0..<self.fill {
    block[i] = self.block[i]
  }
  let w = FixedArray::make(80, 0U)
  // A 1 bit, zeros to 56 bytes past a block, the length in bits as 8 bytes big-endian.
  let mut fill = self.fill
  block[fill] = b'\x80'
  fill += 1
  if fill > 56 {
    for i in fill..<64 {
      block[i] = b'\x00'
    }
    compress1(h, block, w)
    fill = 0
  }
  for i in fill..<56 {
    block[i] = b'\x00'
  }
  let bits = self.total * 8UL
  for i in 0..<8 {
    block[56 + i] = (bits >> (56 - 8 * i)).to_byte()
  }
  compress1(h, block, w)
  Bytes::makei(20, i => (h[i / 4] >> (24 - 8 * (i % 4))).to_byte())
}

///|
/// The digest of all given so far, in lowercase hex.
pub fn Sha1::hex(self : Sha1) -> String {
  hex_encode(self.digest())
}

///|
/// The SHA-1 digest of `data`: 20 bytes.
pub fn sha1(data : BytesView) -> Bytes {
  let s = Sha1::new()
  s.update(data)
  s.digest()
}

///|
/// The SHA-1 digest of `data`, in lowercase hex (node:crypto's `digest("hex")`).
pub fn sha1_hex(data : BytesView) -> String {
  hex_encode(sha1(data))
}

///|
/// The SHA-1 digest of `text`'s UTF-8, in lowercase hex: as node:crypto hashes a string, a lone surrogate taken for
/// U+FFFD (EF BF BD).
pub fn sha1_utf8_hex(text : String) -> String {
  let s = Sha1::new()
  utf8_each(text, b => s.byte(b))
  s.hex()
}
