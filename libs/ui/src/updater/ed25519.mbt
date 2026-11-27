// Pure MoonBit SHA-512 (FIPS 180-4) and RFC 8032 Ed25519 signature verification.

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
/// SHA-512 digest of `data` (64 bytes).
pub fn sha512(data : Bytes) -> Bytes {
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
  Bytes::makei(64, fn(i : Int) { ((h[i / 8] >> (56 - 8 * (i % 8))) & 0xFFUL).to_byte() })
}

///|
/// First 16 lowercase hex digits of SHA-256(public_key).
pub fn key_id(public_key : Bytes) -> String {
  let h = @zip.sha256(public_key)
  h.exact_view(start=0, end=16).to_owned()
}

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
fn ed_add(a : EdPoint, b : EdPoint, p : @bigint.BigInt, d2 : @bigint.BigInt) -> EdPoint {
  let aa = ed_mod((a.y - a.x) * (b.y - b.x), p)
  let bb = ed_mod((a.y + a.x) * (b.y + b.x), p)
  let cc = ed_mod(a.t * d2 % p * b.t, p)
  let dd = ed_mod(a.z * @bigint.BigInt::from_int(2) * b.z, p)
  let e = ed_mod(bb - aa, p)
  let f = ed_mod(dd - cc, p)
  let g = ed_mod(dd + cc, p)
  let h = ed_mod(bb + aa, p)
  {
    x: ed_mod(e * f, p),
    y: ed_mod(g * h, p),
    z: ed_mod(f * g, p),
    t: ed_mod(e * h, p),
  }
}

///|
fn ed_mul(pt : EdPoint, scalar : @bigint.BigInt, p : @bigint.BigInt, d2 : @bigint.BigInt) -> EdPoint {
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
fn ed_point_eq(a : EdPoint, b : EdPoint, p : @bigint.BigInt) -> Bool {
  ed_mod(a.x * b.z - b.x * a.z, p) == @bigint.BigInt::from_int(0) &&
  ed_mod(a.y * b.z - b.y * a.z, p) == @bigint.BigInt::from_int(0)
}

///|
fn ed_decode_point(b : Bytes, start : Int, p : @bigint.BigInt, d : @bigint.BigInt) -> EdPoint? {
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
/// Verify an RFC 8032 Ed25519 signature (`public_key`: 32 bytes, `signature`: 64 bytes).
pub fn verify_ed25519(public_key : Bytes, message : Bytes, signature : Bytes) -> Bool {
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
  let buf = FixedArray::make(64 + message.length(), b'\x00')
  for i in 0..<32 {
    buf[i] = signature[i]
    buf[32 + i] = public_key[i]
  }
  for i in 0..<message.length() {
    buf[64 + i] = message[i]
  }
  let digest = sha512(Bytes::from_array(buf))
  let h = ed_le_to_bigint(digest, 0, 64) % l
  let lhs = ed_mul(ed_base(), s, p, d2)
  let rhs = ed_add(r, ed_mul(a, h, p, d2), p, d2)
  ed_point_eq(lhs, rhs, p)
}
