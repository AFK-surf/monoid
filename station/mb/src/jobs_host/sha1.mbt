// SHA-1, for what names a file's contents as Git does (dirsync.ts `blobId`) and a WebSocket's handshake.

///|
fn rotl(x : UInt, n : Int) -> UInt {
  (x << n) | (x >> (32 - n))
}

///|
/// SHA-1 of `data`, its 20 bytes.
pub fn sha1(data : BytesView) -> Bytes {
  let mut h0 : UInt = 0x67452301
  let mut h1 : UInt = 0xEFCDAB89
  let mut h2 : UInt = 0x98BADCFE
  let mut h3 : UInt = 0x10325476
  let mut h4 : UInt = 0xC3D2E1F0
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
  let w = FixedArray::make(80, (0 : UInt))
  for chunk = 0; chunk < total; chunk = chunk + 64 {
    for i in 0..<16 {
      let b = chunk + i * 4
      w[i] = (msg[b].to_uint() << 24) |
        (msg[b + 1].to_uint() << 16) |
        (msg[b + 2].to_uint() << 8) |
        msg[b + 3].to_uint()
    }
    for i in 16..<80 {
      w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
    }
    let mut a = h0
    let mut b = h1
    let mut c = h2
    let mut d = h3
    let mut e = h4
    for i in 0..<80 {
      let (f, k) = if i < 20 {
        ((b & c) | (b.lnot() & d), (0x5A827999 : UInt))
      } else if i < 40 {
        (b ^ c ^ d, (0x6ED9EBA1 : UInt))
      } else if i < 60 {
        ((b & c) | (b & d) | (c & d), (0x8F1BBCDC : UInt))
      } else {
        (b ^ c ^ d, (0xCA62C1D6 : UInt))
      }
      let t = rotl(a, 5) + f + e + k + w[i]
      e = d
      d = c
      c = rotl(b, 30)
      b = a
      a = t
    }
    h0 = h0 + a
    h1 = h1 + b
    h2 = h2 + c
    h3 = h3 + d
    h4 = h4 + e
  }
  let out = FixedArray::make(20, b'\x00')
  for i, h in [h0, h1, h2, h3, h4] {
    for k in 0..<4 {
      out[i * 4 + k] = ((h >> (24 - 8 * k)) & 0xff).to_byte()
    }
  }
  Bytes::from_array(out)
}

///|
pub fn sha1_hex(data : BytesView) -> String {
  @hex.encode(sha1(data))
}

test "sha1" {
  inspect(sha1_hex(b"abc"), content="a9993e364706816aba3e25717850c26c9cd0d89d")
  inspect(sha1_hex(b""), content="da39a3ee5e6b4b0d3255bfef95601890afd80709")
}
