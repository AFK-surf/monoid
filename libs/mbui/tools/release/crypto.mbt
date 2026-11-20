// Pure MoonBit SHA-256, SHA-512, Base64, Hex, RFC 8032 Ed25519 sign/verify, and PKCS#8 PEM.

///|
let sha256_k : FixedArray[UInt] = [
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
fn rotr32(x : UInt, k : Int) -> UInt {
  (x >> k) | (x << (32 - k))
}

///|
fn sha256_bytes(data : Bytes) -> Bytes {
  let h : FixedArray[UInt] = [
    0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU, 0x510e527fU, 0x9b05688cU, 0x1f83d9abU,
    0x5be0cd19U,
  ]
  let n = data.length()
  let from = n / 64 * 64
  let total = (n + 9 + 63) / 64 * 64
  let tail = FixedArray::make(total - from, b'\x00')
  for i in from..<n {
    tail[i - from] = data[i]
  }
  tail[n - from] = b'\x80'
  let bits = n.to_int64() * 8L
  for k in 0..<8 {
    tail[tail.length() - 1 - k] = ((bits >> (8 * k)) & 0xFFL).to_byte()
  }
  let w = FixedArray::make(64, 0U)
  let byte_at = fn(i : Int) -> UInt {
    if i < from {
      data[i].to_uint()
    } else {
      tail[i - from].to_uint()
    }
  }
  let mut at = 0
  while at < total {
    for t in 0..<16 {
      let i = at + t * 4
      w[t] = (byte_at(i) << 24) |
        (byte_at(i + 1) << 16) |
        (byte_at(i + 2) << 8) |
        byte_at(i + 3)
    }
    for t in 16..<64 {
      let s0 = rotr32(w[t - 15], 7) ^ rotr32(w[t - 15], 18) ^ (w[t - 15] >> 3)
      let s1 = rotr32(w[t - 2], 17) ^ rotr32(w[t - 2], 19) ^ (w[t - 2] >> 10)
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
      let s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
      let ch = (e & f) ^ ((e ^ 0xFFFFFFFFU) & g)
      let t1 = hh + s1 + ch + sha256_k[t] + w[t]
      let s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
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
    at += 64
  }
  Bytes::makei(32, fn(i) { ((h[i / 4] >> (24 - 8 * (i % 4))) & 0xFFU).to_byte() })
}

///|
fn sha256_hex(data : Bytes) -> String {
  hex_encode(sha256_bytes(data))
}

///|
let sha512_k : FixedArray[UInt64] = [
  0x428a2f98d728ae22UL, 0x7137449123ef65cdUL, 0xb5c0fbcfec4d3b2fUL, 0xe9b5dba58189dbbcUL,
  0x3956c25bf348b538UL, 0x59f111f1b605d019UL, 0x923f82a4af194f9bUL, 0xab1c5ed5da6d8118UL,
  0xd807aa98a3030242UL, 0x12835b0145706fbeUL, 0x243185be4ee4b28cUL, 0x550c7dc3d5ffb4e2UL,
  0x72be5d74f27b896fUL, 0x80deb1fe3b1696b1UL, 0x9bdc06a725c71235UL, 0xc19bf174cf692694UL,
  0xe49b69c19ef14ad2UL, 0xefbe4786384f25e3UL, 0x0fc19dc68b8cd5b5UL, 0x240ca1cc77ac9c65UL,
  0x2de92c6f592b0275UL, 0x4a7484aa6ea6e483UL, 0x5cb0a9dcbd41fbd4UL, 0x76f988da831153b5UL,
  0x983e5152ee66dfabUL, 0xa831c66d2db43210UL, 0xb00327c898fb213fUL, 0xbf597fc7beef0ee4UL,
  0xc6e00bf33da88fc2UL, 0xd5a79147930aa725UL, 0x06ca6351e003826fUL, 0x142929670a0e6e70UL,
  0x27b70a8546d22ffcUL, 0x2e1b21385c26c926UL, 0x4d2c6dfc5ac42aedUL, 0x53380d139d95b3dfUL,
  0x650a73548baf63deUL, 0x766a0abb3c77b2a8UL, 0x81c2c92e47edaee6UL, 0x92722c851482353bUL,
  0xa2bfe8a14cf10364UL, 0xa81a664bbc423001UL, 0xc24b8b70d0f89791UL, 0xc76c51a30654be30UL,
  0xd192e819d6ef5218UL, 0xd69906245565a910UL, 0xf40e35855771202aUL, 0x106aa07032bbd1b8UL,
  0x19a4c116b8d2d0c8UL, 0x1e376c085141ab53UL, 0x2748774cdf8eeb99UL, 0x34b0bcb5e19b48a8UL,
  0x391c0cb3c5c95a63UL, 0x4ed8aa4ae3418acbUL, 0x5b9cca4f7763e373UL, 0x682e6ff3d6b2b8a3UL,
  0x748f82ee5defb2fcUL, 0x78a5636f43172f60UL, 0x84c87814a1f0ab72UL, 0x8cc702081a6439ecUL,
  0x90befffa23631e28UL, 0xa4506cebde82bde9UL, 0xbef9a3f7b2c67915UL, 0xc67178f2e372532bUL,
  0xca273eceea26619cUL, 0xd186b8c721c0c207UL, 0xeada7dd6cde0eb1eUL, 0xf57d4f7fee6ed178UL,
  0x06f067aa72176fbaUL, 0x0a637dc5a2c898a6UL, 0x113f9804bef90daeUL, 0x1b710b35131c471bUL,
  0x28db77f523047d84UL, 0x32caab7b40c72493UL, 0x3c9ebe0a15c9bebcUL, 0x431d67c49c100d4cUL,
  0x4cc5d4becb3e42b6UL, 0x597f299cfc657e2aUL, 0x5fcb6fab3ad6faecUL, 0x6c44198c4a475817UL,
]

///|
fn rotr64(x : UInt64, n : Int) -> UInt64 {
  (x >> n) | (x << (64 - n))
}

///|
fn sha512(data : Bytes) -> Bytes {
  let h : FixedArray[UInt64] = [
    0x6a09e667f3bcc908UL, 0xbb67ae8584caa73bUL, 0x3c6ef372fe94f82bUL, 0xa54ff53a5f1d36f1UL,
    0x510e527fade682d1UL, 0x9b05688c2b3e6c1fUL, 0x1f83d9abfb41bd6bUL, 0x5be0cd19137e2179UL,
  ]
  let n = data.length()
  let from = n / 128 * 128
  let total = (n + 17 + 127) / 128 * 128
  let tail = FixedArray::make(total - from, b'\x00')
  for i in from..<n {
    tail[i - from] = data[i]
  }
  tail[n - from] = b'\x80'
  let bits = n.to_uint64() * 8UL
  for k in 0..<8 {
    tail[tail.length() - 1 - k] = ((bits >> (8 * k)) & 0xFFUL).to_byte()
  }
  let w = FixedArray::make(80, 0UL)
  let byte_at = fn(i : Int) -> UInt64 {
    if i < from {
      data[i].to_uint64()
    } else {
      tail[i - from].to_uint64()
    }
  }
  let mut at = 0
  while at < total {
    for t in 0..<16 {
      let i = at + t * 8
      w[t] = (byte_at(i) << 56) |
        (byte_at(i + 1) << 48) |
        (byte_at(i + 2) << 40) |
        (byte_at(i + 3) << 32) |
        (byte_at(i + 4) << 24) |
        (byte_at(i + 5) << 16) |
        (byte_at(i + 6) << 8) |
        byte_at(i + 7)
    }
    for t in 16..<80 {
      let s0 = rotr64(w[t - 15], 1) ^ rotr64(w[t - 15], 8) ^ (w[t - 15] >> 7)
      let s1 = rotr64(w[t - 2], 19) ^ rotr64(w[t - 2], 61) ^ (w[t - 2] >> 6)
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
    for t in 0..<80 {
      let s1 = rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)
      let ch = (e & f) ^ ((e ^ 0xFFFFFFFFFFFFFFFFUL) & g)
      let t1 = hh + s1 + ch + sha512_k[t] + w[t]
      let s0 = rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)
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
    at += 128
  }
  Bytes::makei(64, fn(i) { ((h[i / 8] >> (56 - 8 * (i % 8))) & 0xFFUL).to_byte() })
}

///|
let hex_chars : Array[Char] = "0123456789abcdef".to_array()

///|
fn hex_encode(b : Bytes) -> String {
  let sb = StringBuilder(capacity=b.length() * 2)
  for i in 0..<b.length() {
    let v = b[i].to_int()
    sb.write_char(hex_chars[v >> 4])
    sb.write_char(hex_chars[v & 15])
  }
  sb.to_string()
}

///|
fn hex_decode_exact(s : String) -> Bytes? {
  let clean = s.trim().to_owned()
  if clean.length() % 2 != 0 {
    return None
  }
  let n = clean.length() / 2
  let out = FixedArray::make(n, b'\x00')
  let digit = fn(c : Int) -> Int {
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
  for i in 0..<n {
    let hi = digit(clean.unsafe_get(2 * i).to_int())
    let lo = digit(clean.unsafe_get(2 * i + 1).to_int())
    if hi < 0 || lo < 0 {
      return None
    }
    out[i] = ((hi << 4) | lo).to_byte()
  }
  Some(Bytes::makei(n, fn(i) { out[i] }))
}

///|
let b64_chars : Array[Char] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".to_array()

///|
fn base64_encode(b : Bytes) -> String {
  let sb = StringBuilder(capacity=(b.length() + 2) / 3 * 4)
  let n = b.length()
  let mut i = 0
  while i < n {
    let b0 = b[i].to_int()
    let b1 = if i + 1 < n { b[i + 1].to_int() } else { 0 }
    let b2 = if i + 2 < n { b[i + 2].to_int() } else { 0 }
    sb.write_char(b64_chars[b0 >> 2])
    sb.write_char(b64_chars[((b0 & 3) << 4) | (b1 >> 4)])
    sb.write_char(if i + 1 < n { b64_chars[((b1 & 15) << 2) | (b2 >> 6)] } else { '=' })
    sb.write_char(if i + 2 < n { b64_chars[b2 & 63] } else { '=' })
    i += 3
  }
  sb.to_string()
}

///|
fn base64_decode_exact(s : String) -> Bytes? {
  let out = FixedArray::make(s.length() / 4 * 3 + 3, b'\x00')
  let mut n = 0
  let mut acc = 0
  let mut bits = 0
  for i in 0..<s.length() {
    let c = s.unsafe_get(i).to_int()
    if c == 61 || c == 32 || c == 10 || c == 13 || c == 9 {
      continue
    }
    let v = if c >= 65 && c <= 90 {
      c - 65
    } else if c >= 97 && c <= 122 {
      c - 97 + 26
    } else if c >= 48 && c <= 57 {
      c - 48 + 52
    } else if c == 43 {
      62
    } else if c == 47 {
      63
    } else {
      return None
    }
    acc = ((acc << 6) | v) & 0xFFFFFF
    bits += 6
    if bits >= 8 {
      bits -= 8
      out[n] = ((acc >> bits) & 0xFF).to_byte()
      n += 1
    }
  }
  Some(Bytes::makei(n, fn(i) { out[i] }))
}

///|
fn key_id(public_key : Bytes) -> String {
  let h = sha256_hex(public_key)
  h.exact_view(start=0, end=16).to_owned()
}

// ---- RFC 8032 Ed25519 ----

///|
priv struct EdPoint {
  x : @bigint.BigInt
  y : @bigint.BigInt
  z : @bigint.BigInt
  t : @bigint.BigInt
}

///|
fn ed_p() -> @bigint.BigInt {
  (@bigint.BigInt::from_int(1) << 255) - @bigint.BigInt::from_int(19)
}

///|
fn ed_l() -> @bigint.BigInt {
  (1N << 252) + 27742317777372353535851937790883648493N
}

///|
fn ed_d() -> @bigint.BigInt {
  37095705934669439343138083508754565189542113879843219016388785533085940283555N
}

///|
fn ed_sqrt_m1() -> @bigint.BigInt {
  19681161376707505956807079304988542015446066515923890162744021073123829784752N
}

///|
fn ed_base() -> EdPoint {
  let p = ed_p()
  let bx = 15112221349535400772501151409588531511454012693041857206046113283949847762202N
  let by = 46316835694926478169428394003475163141307993866256225615783033603165251855960N
  { x: bx, y: by, z: 1N, t: bx * by % p }
}

///|
fn ed_mod(a : @bigint.BigInt, m : @bigint.BigInt) -> @bigint.BigInt {
  let r = a % m
  if r < @bigint.BigInt::from_int(0) {
    r + m
  } else {
    r
  }
}

///|
fn ed_pow(
  base : @bigint.BigInt,
  exp : @bigint.BigInt,
  m : @bigint.BigInt,
) -> @bigint.BigInt {
  let zero = @bigint.BigInt::from_int(0)
  let one = @bigint.BigInt::from_int(1)
  let mut r = one
  let mut b = ed_mod(base, m)
  let mut e = exp
  while e > zero {
    if (e & one) != zero {
      r = r * b % m
    }
    b = b * b % m
    e = e >> 1
  }
  r
}

///|
fn ed_le_to_bigint(b : Bytes, start : Int, len : Int) -> @bigint.BigInt {
  let mut v = @bigint.BigInt::from_int(0)
  let mut i = len - 1
  while i >= 0 {
    v = (v << 8) + @bigint.BigInt::from_int(b[start + i].to_int())
    i -= 1
  }
  v
}

///|
fn ed_bigint_to_le32(v : @bigint.BigInt) -> Bytes {
  let mask = @bigint.BigInt::from_int(0xFF)
  let out = FixedArray::make(32, b'\x00')
  let mut cur = v
  for i in 0..<32 {
    out[i] = (cur & mask).to_int().to_byte()
    cur = cur >> 8
  }
  Bytes::makei(32, fn(i) { out[i] })
}

///|
fn ed_add(
  a : EdPoint,
  b : EdPoint,
  p : @bigint.BigInt,
  d2 : @bigint.BigInt,
) -> EdPoint {
  let aa = ed_mod((a.y - a.x) * (b.y - b.x), p)
  let bb = ed_mod((a.y + a.x) * (b.y + b.x), p)
  let cc = ed_mod(a.t * d2 % p * b.t, p)
  let dd = ed_mod(a.z * @bigint.BigInt::from_int(2) * b.z, p)
  let e = ed_mod(bb - aa, p)
  let f = ed_mod(dd - cc, p)
  let g = ed_mod(dd + cc, p)
  let h = ed_mod(bb + aa, p)
  {
    x: e * f % p,
    y: g * h % p,
    z: f * g % p,
    t: e * h % p,
  }
}

///|
fn ed_mul(
  pt : EdPoint,
  scalar : @bigint.BigInt,
  p : @bigint.BigInt,
  d2 : @bigint.BigInt,
) -> EdPoint {
  let zero = @bigint.BigInt::from_int(0)
  let one = @bigint.BigInt::from_int(1)
  let mut acc : EdPoint = { x: zero, y: one, z: one, t: zero }
  let mut cur = pt
  let mut k = scalar
  while k > zero {
    if (k & one) != zero {
      acc = ed_add(acc, cur, p, d2)
    }
    cur = ed_add(cur, cur, p, d2)
    k = k >> 1
  }
  acc
}

///|
fn ed_encode_point(pt : EdPoint, p : @bigint.BigInt) -> Bytes {
  let zinv = ed_pow(pt.z, p - @bigint.BigInt::from_int(2), p)
  let x = ed_mod(pt.x * zinv, p)
  let y = ed_mod(pt.y * zinv, p)
  let mask = @bigint.BigInt::from_int(0xFF)
  let out = FixedArray::make(32, b'\x00')
  let mut cur = y
  for i in 0..<32 {
    out[i] = (cur & mask).to_int().to_byte()
    cur = cur >> 8
  }
  if (x & @bigint.BigInt::from_int(1)) != @bigint.BigInt::from_int(0) {
    out[31] = (out[31].to_int() | 0x80).to_byte()
  }
  Bytes::makei(32, fn(i) { out[i] })
}

///|
fn ed_decode_point(
  b : Bytes,
  start : Int,
  p : @bigint.BigInt,
  d : @bigint.BigInt,
) -> EdPoint? {
  let sign = (b[start + 31].to_int() >> 7) & 1
  let mut y = @bigint.BigInt::from_int(b[start + 31].to_int() & 0x7F)
  let mut i = 30
  while i >= 0 {
    y = (y << 8) + @bigint.BigInt::from_int(b[start + i].to_int())
    i -= 1
  }
  if y >= p {
    return None
  }
  let zero = @bigint.BigInt::from_int(0)
  let one = @bigint.BigInt::from_int(1)
  let y2 = y * y % p
  let u = ed_mod(y2 - one, p)
  let v = ed_mod(d * y2 + one, p)
  let v3 = v * v % p * v % p
  let v7 = v3 * v3 % p * v % p
  let exp = (p - @bigint.BigInt::from_int(5)) >> 3
  let mut x = u * v3 % p * ed_pow(u * v7 % p, exp, p) % p
  let check = v * (x * x % p) % p
  if check != u {
    if check == ed_mod(-u, p) {
      x = x * ed_sqrt_m1() % p
    } else {
      return None
    }
  }
  if x == zero && sign == 1 {
    return None
  }
  let x_odd = (x & one) != zero
  if (x_odd && sign == 0) || (!x_odd && sign == 1) {
    x = ed_mod(p - x, p)
  }
  Some({ x, y, z: one, t: x * y % p })
}

///|
fn ed_point_eq(a : EdPoint, b : EdPoint, p : @bigint.BigInt) -> Bool {
  ed_mod(a.x * b.z - b.x * a.z, p) == @bigint.BigInt::from_int(0) &&
  ed_mod(a.y * b.z - b.y * a.z, p) == @bigint.BigInt::from_int(0)
}

///|
fn ed_clamp_scalar(h : Bytes) -> @bigint.BigInt {
  let clamped = FixedArray::make(32, b'\x00')
  for i in 0..<32 {
    clamped[i] = h[i]
  }
  clamped[0] = (clamped[0].to_int() & 248).to_byte()
  clamped[31] = ((clamped[31].to_int() & 127) | 64).to_byte()
  ed_le_to_bigint(Bytes::makei(32, fn(i) { clamped[i] }), 0, 32)
}

///|
fn ed25519_public_key(seed : Bytes) -> Bytes {
  let p = ed_p()
  let d2 = ed_d() * @bigint.BigInt::from_int(2) % p
  let h = sha512(seed)
  let s = ed_clamp_scalar(h)
  ed_encode_point(ed_mul(ed_base(), s, p, d2), p)
}

///|
fn ed25519_sign(seed : Bytes, message : Bytes) -> Bytes {
  let p = ed_p()
  let l = ed_l()
  let d2 = ed_d() * @bigint.BigInt::from_int(2) % p
  let h = sha512(seed)
  let s = ed_clamp_scalar(h)
  let pk = ed_encode_point(ed_mul(ed_base(), s, p, d2), p)
  let r_in = Bytes::makei(32 + message.length(), fn(i) {
    if i < 32 {
      h[32 + i]
    } else {
      message[i - 32]
    }
  })
  let r = ed_le_to_bigint(sha512(r_in), 0, 64) % l
  let r_enc = ed_encode_point(ed_mul(ed_base(), r, p, d2), p)
  let k_in = Bytes::makei(64 + message.length(), fn(i) {
    if i < 32 {
      r_enc[i]
    } else if i < 64 {
      pk[i - 32]
    } else {
      message[i - 64]
    }
  })
  let k = ed_le_to_bigint(sha512(k_in), 0, 64) % l
  let sig_s = ed_bigint_to_le32((r + k * s) % l)
  Bytes::makei(64, fn(i) { if i < 32 { r_enc[i] } else { sig_s[i - 32] } })
}

///|
fn ed25519_verify(public_key : Bytes, message : Bytes, signature : Bytes) -> Bool {
  if public_key.length() != 32 || signature.length() != 64 {
    return false
  }
  let p = ed_p()
  let l = ed_l()
  let d = ed_d()
  let d2 = d * @bigint.BigInt::from_int(2) % p
  let a = match ed_decode_point(public_key, 0, p, d) {
    Some(pt) => pt
    None => return false
  }
  let r = match ed_decode_point(signature, 0, p, d) {
    Some(pt) => pt
    None => return false
  }
  let s = ed_le_to_bigint(signature, 32, 32)
  if s >= l {
    return false
  }
  let k_in = Bytes::makei(64 + message.length(), fn(i) {
    if i < 32 {
      signature[i]
    } else if i < 64 {
      public_key[i - 32]
    } else {
      message[i - 64]
    }
  })
  let h = ed_le_to_bigint(sha512(k_in), 0, 64) % l
  let lhs = ed_mul(ed_base(), s, p, d2)
  let rhs = ed_add(r, ed_mul(a, h, p, d2), p, d2)
  ed_point_eq(lhs, rhs, p)
}

// ---- PKCS#8 PEM for Ed25519 (RFC 8410) ----

///|
let pkcs8_ed25519_prefix : FixedArray[Byte] = [
  b'\x30', b'\x2e', b'\x02', b'\x01', b'\x00', b'\x30', b'\x05', b'\x06',
  b'\x03', b'\x2b', b'\x65', b'\x70', b'\x04', b'\x22', b'\x04', b'\x20',
]

///|
fn encode_pkcs8_pem(seed : Bytes) -> String {
  let der = Bytes::makei(48, fn(i) {
    if i < 16 {
      pkcs8_ed25519_prefix[i]
    } else {
      seed[i - 16]
    }
  })
  "-----BEGIN PRIVATE KEY-----\n" +
  base64_encode(der) +
  "\n-----END PRIVATE KEY-----\n"
}

///|
fn decode_private_key(text : String) -> Result[Bytes, String] {
  let trimmed = text.trim().to_owned()
  if trimmed.contains("-----BEGIN PRIVATE KEY-----") {
    let sb = StringBuilder()
    for line in trimmed.split("\n") {
      let l = line.trim().to_owned()
      if l == "" || l.has_prefix("-----") {
        continue
      }
      sb.write_string(l)
    }
    let der = match base64_decode_exact(sb.to_string()) {
      Some(b) => b
      None => return Err("private key PEM is not valid base64")
    }
    if der.length() < 48 {
      return Err("PKCS#8 Ed25519 key is too short")
    }
    // Check standard 16-byte prefix (v1 PKCS#8 Ed25519)
    let mut matches_v1 = true
    for i in 0..<16 {
      if der[i] != pkcs8_ed25519_prefix[i] {
        matches_v1 = false
        break
      }
    }
    if matches_v1 {
      return Ok(Bytes::makei(32, fn(i) { der[16 + i] }))
    }
    // Also support PKCS#8 v2 (which includes public key after seed): find OID 06 03 2b 65 70 + 04 22 04 20
    let needle : FixedArray[Byte] = [
      b'\x06', b'\x03', b'\x2b', b'\x65', b'\x70', b'\x04', b'\x22', b'\x04',
      b'\x20',
    ]
    for i in 0..<(der.length() - 9 - 32 + 1) {
      let mut ok = true
      for j in 0..<9 {
        if der[i + j] != needle[j] {
          ok = false
          break
        }
      }
      if ok {
        return Ok(Bytes::makei(32, fn(k) { der[i + 9 + k] }))
      }
    }
    return Err("PEM is not an Ed25519 PKCS#8 private key")
  }
  match base64_decode_exact(trimmed) {
    Some(raw) if raw.length() == 32 => Ok(raw)
    _ => Err("private key must be an Ed25519 PKCS#8 PEM or 32-byte base64 seed")
  }
}
