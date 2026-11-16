// Ed25519 signing (RFC 8032), of no dependency: SHA-512 and the curve's arithmetic over GF(2^255 - 19), sixteen limbs
// of 16 bits each, as TweetNaCl does them (its `crypto_sign`, line for line). What `Mesh::sign` falls back on where
// its shell does not sign (a page's; the Rust shell does: `ed25519.sign`), as the TypeScript mesh falls back on its
// own (`sign`). Signing only: nothing here checks a signature.

///|
let sha512_k : FixedArray[UInt64] = [
  0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc, 0x3956c25bf348b538, 0x59f111f1b605d019,
  0x923f82a4af194f9b, 0xab1c5ed5da6d8118, 0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
  0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694, 0xe49b69c19ef14ad2, 0xefbe4786384f25e3,
  0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65, 0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
  0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4, 0xc6e00bf33da88fc2, 0xd5a79147930aa725,
  0x06ca6351e003826f, 0x142929670a0e6e70, 0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
  0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b, 0xa2bfe8a14cf10364, 0xa81a664bbc423001,
  0xc24b8b70d0f89791, 0xc76c51a30654be30, 0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
  0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8, 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb,
  0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3, 0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
  0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b, 0xca273eceea26619c, 0xd186b8c721c0c207,
  0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178, 0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
  0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c, 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a,
  0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
]

///|
fn rotr64(x : UInt64, n : Int) -> UInt64 {
  (x >> n) | (x << (64 - n))
}

///|
/// The SHA-512 digest of `data`: 64 bytes.
fn sha512(data : Bytes) -> Bytes {
  let h : FixedArray[UInt64] = [
    0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1, 0x510e527fade682d1, 0x9b05688c2b3e6c1f,
    0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
  ]
  let n = data.length()
  let total = (n + 17 + 127) / 128 * 128
  let padded = FixedArray::make(total, b'\x00')
  for i in 0..<n {
    padded[i] = data[i]
  }
  padded[n] = b'\x80'
  let bits = n.to_uint64() * 8UL
  for i in 0..<8 {
    padded[total - 1 - i] = (bits >> (8 * i)).to_byte()
  }
  let w = FixedArray::make(80, 0UL)
  for block = 0; block < total; block = block + 128 {
    for t in 0..<16 {
      let mut x = 0UL
      for k in 0..<8 {
        x = (x << 8) | padded[block + 8 * t + k].to_uint64()
      }
      w[t] = x
    }
    for t in 16..<80 {
      let s0 = rotr64(w[t - 15], 1) ^ rotr64(w[t - 15], 8) ^ (w[t - 15] >> 7)
      let s1 = rotr64(w[t - 2], 19) ^ rotr64(w[t - 2], 61) ^ (w[t - 2] >> 6)
      w[t] = w[t - 16] + s0 + w[t - 7] + s1
    }
    let v = h.copy()
    for t in 0..<80 {
      let s1 = rotr64(v[4], 14) ^ rotr64(v[4], 18) ^ rotr64(v[4], 41)
      let ch = (v[4] & v[5]) ^ (v[4].lnot() & v[6])
      let t1 = v[7] + s1 + ch + sha512_k[t] + w[t]
      let s0 = rotr64(v[0], 28) ^ rotr64(v[0], 34) ^ rotr64(v[0], 39)
      let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2])
      let t2 = s0 + maj
      v[7] = v[6]
      v[6] = v[5]
      v[5] = v[4]
      v[4] = v[3] + t1
      v[3] = v[2]
      v[2] = v[1]
      v[1] = v[0]
      v[0] = t1 + t2
    }
    for i in 0..<8 {
      h[i] = h[i] + v[i]
    }
  }
  let out = Array::make(64, b'\x00')
  for i in 0..<8 {
    for k in 0..<8 {
      out[8 * i + k] = (h[i] >> (56 - 8 * k)).to_byte()
    }
  }
  Bytes::from_array(out)
}

///|
/// A field element: sixteen limbs of 16 bits, little first, each as wide as an Int64 holds while worked on.
type Gf = FixedArray[Int64]

///|
fn gf(limbs : Array[Int]) -> Gf {
  let out = FixedArray::make(16, 0L)
  for i, limb in limbs {
    out[i] = limb.to_int64()
  }
  out
}

///|
let gf0 : Gf = gf([])

///|
let gf1 : Gf = gf([1])

///|
let d2 : Gf = gf([
  0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0, 0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc,
  0x2406,
])

///|
let base_x : Gf = gf([
  0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c, 0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3,
  0x2169,
])

///|
let base_y : Gf = gf([
  0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
  0x6666,
])

///|
/// The group's order, little first.
let order_l : FixedArray[Int64] = [
  0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0x10,
]

///|
fn set25519(r : Gf, a : Gf) -> Unit {
  for i in 0..<16 {
    r[i] = a[i]
  }
}

///|
fn car25519(o : Gf) -> Unit {
  for i in 0..<16 {
    o[i] = o[i] + (1L << 16)
    let c = o[i] >> 16
    if i < 15 {
      o[i + 1] = o[i + 1] + c - 1L
    } else {
      o[0] = o[0] + 38L * (c - 1L)
    }
    o[i] = o[i] - (c << 16)
  }
}

///|
fn sel25519(p : Gf, q : Gf, b : Int) -> Unit {
  let c = (b - 1).lnot().to_int64()
  for i in 0..<16 {
    let t = c & (p[i] ^ q[i])
    p[i] = p[i] ^ t
    q[i] = q[i] ^ t
  }
}

///|
fn pack25519(o : FixedArray[Byte], n : Gf) -> Unit {
  let m = FixedArray::make(16, 0L)
  let t = n.copy()
  car25519(t)
  car25519(t)
  car25519(t)
  for _ in 0..<2 {
    m[0] = t[0] - 0xffedL
    for i in 1..<15 {
      m[i] = t[i] - 0xffffL - ((m[i - 1] >> 16) & 1L)
      m[i - 1] = m[i - 1] & 0xffffL
    }
    m[15] = t[15] - 0x7fffL - ((m[14] >> 16) & 1L)
    let b = ((m[15] >> 16) & 1L).to_int()
    m[14] = m[14] & 0xffffL
    sel25519(t, m, 1 - b)
  }
  for i in 0..<16 {
    o[2 * i] = (t[i] & 0xffL).to_byte()
    o[2 * i + 1] = (t[i] >> 8).to_byte()
  }
}

///|
fn par25519(a : Gf) -> Int {
  let d = FixedArray::make(32, b'\x00')
  pack25519(d, a)
  d[0].to_int() & 1
}

///|
fn fadd(o : Gf, a : Gf, b : Gf) -> Unit {
  for i in 0..<16 {
    o[i] = a[i] + b[i]
  }
}

///|
fn fsub(o : Gf, a : Gf, b : Gf) -> Unit {
  for i in 0..<16 {
    o[i] = a[i] - b[i]
  }
}

///|
fn fmul(o : Gf, a : Gf, b : Gf) -> Unit {
  let t = FixedArray::make(31, 0L)
  for i in 0..<16 {
    for j in 0..<16 {
      t[i + j] = t[i + j] + a[i] * b[j]
    }
  }
  for i in 0..<15 {
    t[i] = t[i] + 38L * t[i + 16]
  }
  for i in 0..<16 {
    o[i] = t[i]
  }
  car25519(o)
  car25519(o)
}

///|
fn fsq(o : Gf, a : Gf) -> Unit {
  fmul(o, a, a)
}

///|
fn inv25519(o : Gf, i : Gf) -> Unit {
  let c = i.copy()
  for a = 253; a >= 0; a = a - 1 {
    fsq(c, c)
    if a != 2 && a != 4 {
      fmul(c, c, i)
    }
  }
  set25519(o, c)
}

///|
/// A point, extended coordinates (X, Y, Z, T).
type Point = FixedArray[Gf]

///|
fn point() -> Point {
  [gf([]), gf([]), gf([]), gf([])]
}

///|
fn padd(p : Point, q : Point) -> Unit {
  let a = gf([])
  let b = gf([])
  let c = gf([])
  let d = gf([])
  let e = gf([])
  let f = gf([])
  let g = gf([])
  let h = gf([])
  let t = gf([])
  fsub(a, p[1], p[0])
  fsub(t, q[1], q[0])
  fmul(a, a, t)
  fadd(b, p[0], p[1])
  fadd(t, q[0], q[1])
  fmul(b, b, t)
  fmul(c, p[3], q[3])
  fmul(c, c, d2)
  fmul(d, p[2], q[2])
  fadd(d, d, d)
  fsub(e, b, a)
  fsub(f, d, c)
  fadd(g, d, c)
  fadd(h, b, a)
  fmul(p[0], e, f)
  fmul(p[1], h, g)
  fmul(p[2], g, f)
  fmul(p[3], e, h)
}

///|
fn cswap(p : Point, q : Point, b : Int) -> Unit {
  for i in 0..<4 {
    sel25519(p[i], q[i], b)
  }
}

///|
fn pack_point(r : FixedArray[Byte], p : Point) -> Unit {
  let tx = gf([])
  let ty = gf([])
  let zi = gf([])
  inv25519(zi, p[2])
  fmul(tx, p[0], zi)
  fmul(ty, p[1], zi)
  pack25519(r, ty)
  r[31] = (r[31].to_int() ^ (par25519(tx) << 7)).to_byte()
}

///|
fn scalarmult(p : Point, q : Point, s : FixedArray[Byte]) -> Unit {
  set25519(p[0], gf0)
  set25519(p[1], gf1)
  set25519(p[2], gf1)
  set25519(p[3], gf0)
  for i = 255; i >= 0; i = i - 1 {
    let b = (s[i / 8].to_int() >> (i & 7)) & 1
    cswap(p, q, b)
    padd(q, p)
    padd(p, p)
    cswap(p, q, b)
  }
}

///|
fn scalarbase(p : Point, s : FixedArray[Byte]) -> Unit {
  let q = point()
  set25519(q[0], base_x)
  set25519(q[1], base_y)
  set25519(q[2], gf1)
  fmul(q[3], base_x, base_y)
  scalarmult(p, q, s)
}

///|
fn mod_l(r : FixedArray[Byte], x : FixedArray[Int64]) -> Unit {
  for i = 63; i >= 32; i = i - 1 {
    let mut carry = 0L
    let mut j = i - 32
    while j < i - 12 {
      x[j] = x[j] + carry - 16L * x[i] * order_l[j - (i - 32)]
      carry = (x[j] + 128L) >> 8
      x[j] = x[j] - (carry << 8)
      j += 1
    }
    x[j] = x[j] + carry
    x[i] = 0L
  }
  let mut carry = 0L
  for j in 0..<32 {
    x[j] = x[j] + carry - (x[31] >> 4) * order_l[j]
    carry = x[j] >> 8
    x[j] = x[j] & 255L
  }
  for j in 0..<32 {
    x[j] = x[j] - carry * order_l[j]
  }
  for i in 0..<32 {
    x[i + 1] = x[i + 1] + (x[i] >> 8)
    r[i] = (x[i] & 255L).to_byte()
  }
}

///|
fn reduce(r : FixedArray[Byte]) -> Unit {
  let x = FixedArray::make(64, 0L)
  for i in 0..<64 {
    x[i] = r[i].to_int64()
  }
  for i in 0..<64 {
    r[i] = b'\x00'
  }
  mod_l(r, x)
}

///|
fn fixed(bytes : Bytes) -> FixedArray[Byte] {
  let out = FixedArray::make(bytes.length(), b'\x00')
  for i in 0..<bytes.length() {
    out[i] = bytes[i]
  }
  out
}

///|
fn joined_bytes(parts : Array[FixedArray[Byte]]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
/// `message` signed with the Ed25519 key whose seed is `seed` (32 bytes), and that key's public half: (public key,
/// 32 bytes; signature, 64 bytes), as RFC 8032 has them.
pub fn ed25519_sign(seed : Bytes, message : Bytes) -> (Bytes, Bytes) {
  let d = fixed(sha512(seed))
  d[0] = (d[0].to_int() & 248).to_byte()
  d[31] = ((d[31].to_int() & 127) | 64).to_byte()
  let p = point()
  scalarbase(p, d)
  let pk = FixedArray::make(32, b'\x00')
  pack_point(pk, p)
  let m = fixed(message)
  let upper = FixedArray::make(32, b'\x00')
  for i in 0..<32 {
    upper[i] = d[32 + i]
  }
  let r = fixed(sha512(joined_bytes([upper, m])))
  reduce(r)
  let rp = point()
  scalarbase(rp, r)
  let sig_r = FixedArray::make(32, b'\x00')
  pack_point(sig_r, rp)
  let h = fixed(sha512(joined_bytes([sig_r, pk, m])))
  reduce(h)
  let x = FixedArray::make(64, 0L)
  for i in 0..<32 {
    x[i] = r[i].to_int64()
  }
  for i in 0..<32 {
    for j in 0..<32 {
      x[i + j] = x[i + j] + h[i].to_int64() * d[j].to_int64()
    }
  }
  let s = FixedArray::make(32, b'\x00')
  mod_l(s, x)
  (joined_bytes([pk]), joined_bytes([sig_r, s]))
}
