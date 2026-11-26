// SHA-256 (FIPS 180-4): what a file unzipped is checked against (a face's files say the hash of each).

///|
let sha_k : FixedArray[UInt] = [
  0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U, 0x923f82a4U,
  0xab1c5ed5U, 0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU,
  0x9bdc06a7U, 0xc19bf174U, 0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU,
  0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU, 0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
  0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU,
  0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U, 0xa2bfe8a1U, 0xa81a664bU,
  0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U, 0x19a4c116U,
  0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
  0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U, 0x90befffaU, 0xa4506cebU, 0xbef9a3f7U,
  0xc67178f2U,
]

///|
fn compress(h : FixedArray[UInt], w : FixedArray[UInt]) -> Unit {
  for t in 16..<64 {
    let x = w[t - 15]
    let s0 = ((x >> 7) | (x << 25)) ^ ((x >> 18) | (x << 14)) ^ (x >> 3)
    let y = w[t - 2]
    let s1 = ((y >> 17) | (y << 15)) ^ ((y >> 19) | (y << 13)) ^ (y >> 10)
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
    let s1 = ((e >> 6) | (e << 26)) ^ ((e >> 11) | (e << 21)) ^ ((e >> 25) | (e << 7))
    let ch = (e & f) ^ ((e ^ 0xFFFFFFFFU) & g)
    let t1 = hh + s1 + ch + sha_k[t] + w[t]
    let s0 = ((a >> 2) | (a << 30)) ^ ((a >> 13) | (a << 19)) ^ ((a >> 22) | (a << 10))
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
/// The SHA-256 of `data`, as 64 lowercase hex digits.
pub fn sha256(data : Bytes) -> String {
  let h : FixedArray[UInt] = [
    0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU, 0x510e527fU, 0x9b05688cU, 0x1f83d9abU,
    0x5be0cd19U,
  ]
  let n = data.length()
  let full = n / 64 * 64
  let w = FixedArray::make(64, 0U)
  let mut at = 0
  while at < full {
    for t in 0..<16 {
      let i = at + t * 4
      w[t] = (data[i].to_uint() << 24) |
        (data[i + 1].to_uint() << 16) |
        (data[i + 2].to_uint() << 8) |
        data[i + 3].to_uint()
    }
    compress(h, w)
    at += 64
  }
  // Remainder + 0x80 + zero padding + 64-bit bit length in 1 or 2 tail blocks (avoids 32-bit `n + 9 + 63` overflow).
  let rem = n - full
  let tail_len = if rem >= 56 { 128 } else { 64 }
  let tail = FixedArray::make(tail_len, b'\x00')
  for i in 0..<rem {
    tail[i] = data[full + i]
  }
  tail[rem] = b'\x80'
  let bits = n.to_int64() * 8L
  for k in 0..<8 {
    tail[tail_len - 1 - k] = ((bits >> (8 * k)) & 0xFFL).to_byte()
  }
  let mut tat = 0
  while tat < tail_len {
    for t in 0..<16 {
      let i = tat + t * 4
      w[t] = (tail[i].to_uint() << 24) |
        (tail[i + 1].to_uint() << 16) |
        (tail[i + 2].to_uint() << 8) |
        tail[i + 3].to_uint()
    }
    compress(h, w)
    tat += 64
  }
  let digits = "0123456789abcdef"
  let sb = StringBuilder(capacity=64)
  for x in h {
    for k in 0..<8 {
      let d = ((x >> (28 - 4 * k)) & 15U).reinterpret_as_int()
      sb.write_char(digits.get_char(d).unwrap())
    }
  }
  sb.to_string()
}
