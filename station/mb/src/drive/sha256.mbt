// SHA-256 (FIPS 180-4), for grants' HMAC and thumbnails' ids.

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
/// The SHA-256 of `data`.
pub fn sha256_bytes(data : Bytes) -> Bytes {
  let h : FixedArray[UInt] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
    0x5be0cd19,
  ]
  let n = data.length()
  let total = (n + 9 + 63) / 64 * 64
  let m = FixedArray::make(total, b'\x00')
  for i = 0; i < n; i = i + 1 {
    m[i] = data[i]
  }
  m[n] = b'\x80'
  let bits = n.to_int64() * 8L
  for i = 0; i < 8; i = i + 1 {
    m[total - 1 - i] = ((bits >> (i * 8)) & 0xFFL).to_byte()
  }
  let w = FixedArray::make(64, 0U)
  let mut off = 0
  while off < total {
    for t = 0; t < 16; t = t + 1 {
      let j = off + t * 4
      w[t] = (m[j].to_uint() << 24) |
        (m[j + 1].to_uint() << 16) |
        (m[j + 2].to_uint() << 8) |
        m[j + 3].to_uint()
    }
    for t = 16; t < 64; t = t + 1 {
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
    for t = 0; t < 64; t = t + 1 {
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
    h[0] = h[0] + a
    h[1] = h[1] + b
    h[2] = h[2] + c
    h[3] = h[3] + d
    h[4] = h[4] + e
    h[5] = h[5] + f
    h[6] = h[6] + g
    h[7] = h[7] + hh
    off += 64
  }
  let out = FixedArray::make(32, b'\x00')
  for i = 0; i < 8; i = i + 1 {
    out[i * 4] = (h[i] >> 24).to_byte()
    out[i * 4 + 1] = ((h[i] >> 16) & 0xFFU).to_byte()
    out[i * 4 + 2] = ((h[i] >> 8) & 0xFFU).to_byte()
    out[i * 4 + 3] = (h[i] & 0xFFU).to_byte()
  }
  Bytes::from_array(out)
}
