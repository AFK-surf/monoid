// Ed25519 signing (RFC 8032), of no dependency: SHA-512 and the curve's arithmetic over GF(2^255 - 19), sixteen limbs
// of 16 bits each, as TweetNaCl does them (its `crypto_sign`, line for line), each limb a Double as in its JavaScript
// port (`nacl-fast.js`, whose `M` is `fmul` here): on js an Int64 is a BigInt made anew at every `+` and `*`, and a
// page took some 20 ms of its CPU to check one signature, seconds for the few hundred of a first read (`Gf`). What
// `Mesh::sign` falls back on where its shell does not sign (a page's; the Rust shell does: `ed25519.sign`), as the
// TypeScript mesh falls back on its own (`sign`). And a signature checked (`ed25519_verify`, TweetNaCl's
// `crypto_sign_open`, its two ladders made one: `double_scalarmult`), held to what the Rust shell's check
// (`crypto.verify`, libcrux's) takes: a key or an `R` whose y is not below the field's prime, or that is x = 0 with its
// sign set, and an `S` not below the group's order, are refused, so both sides say the same of one.

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
/// A field element: sixteen limbs of 16 bits, little first, each an integer held in a Double while worked on. Every
/// value is exact: the most a limb comes to is in `fmul`, sixteen products of two limbs of at most 2^18 each (an
/// `fadd` of `fadd`s, in `padd`) and 38 of those again, under 2^47, where a Double holds every integer to 2^53. So
/// both targets work out the same bits as with Int64 limbs.
type Gf = FixedArray[Double]

///|
fn gf(limbs : Array[Int]) -> Gf {
  // (written out, not `FixedArray::make`: on js that is an array made with holes, read some 15% slower here)
  let out : Gf = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
  for i, limb in limbs {
    out[i] = limb.to_double()
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
  // (an arithmetic shift by 16 is a division by 2^16 rounded down: exact on a Double)
  for i in 0..<16 {
    o[i] = o[i] + 65536.0
    let c = (o[i] / 65536.0).floor()
    if i < 15 {
      o[i + 1] = o[i + 1] + c - 1.0
    } else {
      o[0] = o[0] + 38.0 * (c - 1.0)
    }
    o[i] = o[i] - c * 65536.0
  }
}

///|
/// `p` and `q` swapped where `b` is 1, left where it is 0, with no branch on `b`: TweetNaCl's mask, as arithmetic.
fn sel25519(p : Gf, q : Gf, b : Int) -> Unit {
  let k = b.to_double()
  for i in 0..<16 {
    let t = k * (q[i] - p[i])
    p[i] = p[i] + t
    q[i] = q[i] - t
  }
}

///|
/// As `sel25519`, of limbs carried into an Int each (`pack25519`'s).
fn sel_ints(p : FixedArray[Int], q : FixedArray[Int], b : Int) -> Unit {
  let c = (b - 1).lnot()
  for i in 0..<16 {
    let t = c & (p[i] ^ q[i])
    p[i] = p[i] ^ t
    q[i] = q[i] ^ t
  }
}

///|
fn pack25519(o : FixedArray[Byte], n : Gf) -> Unit {
  let c = n.copy()
  car25519(c)
  car25519(c)
  car25519(c)
  // (carried three times, each limb is under 2^16 but the first, a little over at most: an Int holds them)
  let t = FixedArray::make(16, 0)
  for i in 0..<16 {
    t[i] = c[i].to_int()
  }
  let m = FixedArray::make(16, 0)
  for _ in 0..<2 {
    m[0] = t[0] - 0xffed
    for i in 1..<15 {
      m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1)
      m[i - 1] = m[i - 1] & 0xffff
    }
    m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
    let b = (m[15] >> 16) & 1
    m[14] = m[14] & 0xffff
    sel_ints(t, m, 1 - b)
  }
  for i in 0..<16 {
    o[2 * i] = (t[i] & 0xff).to_byte()
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
/// `a` times `b` into `o` (which may be either), carried twice: TweetNaCl's `M` of its JavaScript port, the product's
/// 31 columns held in locals rather than an array, which on js is some five times as fast as the loops it stands for
/// (each limb of the product `a[i] * b[j]` summed into column `i + j`, the columns past 15 folded back times 38).
fn fmul(o : Gf, a : Gf, b : Gf) -> Unit {
  let b0 = b[0]
  let b1 = b[1]
  let b2 = b[2]
  let b3 = b[3]
  let b4 = b[4]
  let b5 = b[5]
  let b6 = b[6]
  let b7 = b[7]
  let b8 = b[8]
  let b9 = b[9]
  let b10 = b[10]
  let b11 = b[11]
  let b12 = b[12]
  let b13 = b[13]
  let b14 = b[14]
  let b15 = b[15]
  let mut t0 = 0.0
  let mut t1 = 0.0
  let mut t2 = 0.0
  let mut t3 = 0.0
  let mut t4 = 0.0
  let mut t5 = 0.0
  let mut t6 = 0.0
  let mut t7 = 0.0
  let mut t8 = 0.0
  let mut t9 = 0.0
  let mut t10 = 0.0
  let mut t11 = 0.0
  let mut t12 = 0.0
  let mut t13 = 0.0
  let mut t14 = 0.0
  let mut t15 = 0.0
  let mut t16 = 0.0
  let mut t17 = 0.0
  let mut t18 = 0.0
  let mut t19 = 0.0
  let mut t20 = 0.0
  let mut t21 = 0.0
  let mut t22 = 0.0
  let mut t23 = 0.0
  let mut t24 = 0.0
  let mut t25 = 0.0
  let mut t26 = 0.0
  let mut t27 = 0.0
  let mut t28 = 0.0
  let mut t29 = 0.0
  let mut t30 = 0.0
  let mut v = a[0]
  t0 = t0 + v * b0
  t1 = t1 + v * b1
  t2 = t2 + v * b2
  t3 = t3 + v * b3
  t4 = t4 + v * b4
  t5 = t5 + v * b5
  t6 = t6 + v * b6
  t7 = t7 + v * b7
  t8 = t8 + v * b8
  t9 = t9 + v * b9
  t10 = t10 + v * b10
  t11 = t11 + v * b11
  t12 = t12 + v * b12
  t13 = t13 + v * b13
  t14 = t14 + v * b14
  t15 = t15 + v * b15
  v = a[1]
  t1 = t1 + v * b0
  t2 = t2 + v * b1
  t3 = t3 + v * b2
  t4 = t4 + v * b3
  t5 = t5 + v * b4
  t6 = t6 + v * b5
  t7 = t7 + v * b6
  t8 = t8 + v * b7
  t9 = t9 + v * b8
  t10 = t10 + v * b9
  t11 = t11 + v * b10
  t12 = t12 + v * b11
  t13 = t13 + v * b12
  t14 = t14 + v * b13
  t15 = t15 + v * b14
  t16 = t16 + v * b15
  v = a[2]
  t2 = t2 + v * b0
  t3 = t3 + v * b1
  t4 = t4 + v * b2
  t5 = t5 + v * b3
  t6 = t6 + v * b4
  t7 = t7 + v * b5
  t8 = t8 + v * b6
  t9 = t9 + v * b7
  t10 = t10 + v * b8
  t11 = t11 + v * b9
  t12 = t12 + v * b10
  t13 = t13 + v * b11
  t14 = t14 + v * b12
  t15 = t15 + v * b13
  t16 = t16 + v * b14
  t17 = t17 + v * b15
  v = a[3]
  t3 = t3 + v * b0
  t4 = t4 + v * b1
  t5 = t5 + v * b2
  t6 = t6 + v * b3
  t7 = t7 + v * b4
  t8 = t8 + v * b5
  t9 = t9 + v * b6
  t10 = t10 + v * b7
  t11 = t11 + v * b8
  t12 = t12 + v * b9
  t13 = t13 + v * b10
  t14 = t14 + v * b11
  t15 = t15 + v * b12
  t16 = t16 + v * b13
  t17 = t17 + v * b14
  t18 = t18 + v * b15
  v = a[4]
  t4 = t4 + v * b0
  t5 = t5 + v * b1
  t6 = t6 + v * b2
  t7 = t7 + v * b3
  t8 = t8 + v * b4
  t9 = t9 + v * b5
  t10 = t10 + v * b6
  t11 = t11 + v * b7
  t12 = t12 + v * b8
  t13 = t13 + v * b9
  t14 = t14 + v * b10
  t15 = t15 + v * b11
  t16 = t16 + v * b12
  t17 = t17 + v * b13
  t18 = t18 + v * b14
  t19 = t19 + v * b15
  v = a[5]
  t5 = t5 + v * b0
  t6 = t6 + v * b1
  t7 = t7 + v * b2
  t8 = t8 + v * b3
  t9 = t9 + v * b4
  t10 = t10 + v * b5
  t11 = t11 + v * b6
  t12 = t12 + v * b7
  t13 = t13 + v * b8
  t14 = t14 + v * b9
  t15 = t15 + v * b10
  t16 = t16 + v * b11
  t17 = t17 + v * b12
  t18 = t18 + v * b13
  t19 = t19 + v * b14
  t20 = t20 + v * b15
  v = a[6]
  t6 = t6 + v * b0
  t7 = t7 + v * b1
  t8 = t8 + v * b2
  t9 = t9 + v * b3
  t10 = t10 + v * b4
  t11 = t11 + v * b5
  t12 = t12 + v * b6
  t13 = t13 + v * b7
  t14 = t14 + v * b8
  t15 = t15 + v * b9
  t16 = t16 + v * b10
  t17 = t17 + v * b11
  t18 = t18 + v * b12
  t19 = t19 + v * b13
  t20 = t20 + v * b14
  t21 = t21 + v * b15
  v = a[7]
  t7 = t7 + v * b0
  t8 = t8 + v * b1
  t9 = t9 + v * b2
  t10 = t10 + v * b3
  t11 = t11 + v * b4
  t12 = t12 + v * b5
  t13 = t13 + v * b6
  t14 = t14 + v * b7
  t15 = t15 + v * b8
  t16 = t16 + v * b9
  t17 = t17 + v * b10
  t18 = t18 + v * b11
  t19 = t19 + v * b12
  t20 = t20 + v * b13
  t21 = t21 + v * b14
  t22 = t22 + v * b15
  v = a[8]
  t8 = t8 + v * b0
  t9 = t9 + v * b1
  t10 = t10 + v * b2
  t11 = t11 + v * b3
  t12 = t12 + v * b4
  t13 = t13 + v * b5
  t14 = t14 + v * b6
  t15 = t15 + v * b7
  t16 = t16 + v * b8
  t17 = t17 + v * b9
  t18 = t18 + v * b10
  t19 = t19 + v * b11
  t20 = t20 + v * b12
  t21 = t21 + v * b13
  t22 = t22 + v * b14
  t23 = t23 + v * b15
  v = a[9]
  t9 = t9 + v * b0
  t10 = t10 + v * b1
  t11 = t11 + v * b2
  t12 = t12 + v * b3
  t13 = t13 + v * b4
  t14 = t14 + v * b5
  t15 = t15 + v * b6
  t16 = t16 + v * b7
  t17 = t17 + v * b8
  t18 = t18 + v * b9
  t19 = t19 + v * b10
  t20 = t20 + v * b11
  t21 = t21 + v * b12
  t22 = t22 + v * b13
  t23 = t23 + v * b14
  t24 = t24 + v * b15
  v = a[10]
  t10 = t10 + v * b0
  t11 = t11 + v * b1
  t12 = t12 + v * b2
  t13 = t13 + v * b3
  t14 = t14 + v * b4
  t15 = t15 + v * b5
  t16 = t16 + v * b6
  t17 = t17 + v * b7
  t18 = t18 + v * b8
  t19 = t19 + v * b9
  t20 = t20 + v * b10
  t21 = t21 + v * b11
  t22 = t22 + v * b12
  t23 = t23 + v * b13
  t24 = t24 + v * b14
  t25 = t25 + v * b15
  v = a[11]
  t11 = t11 + v * b0
  t12 = t12 + v * b1
  t13 = t13 + v * b2
  t14 = t14 + v * b3
  t15 = t15 + v * b4
  t16 = t16 + v * b5
  t17 = t17 + v * b6
  t18 = t18 + v * b7
  t19 = t19 + v * b8
  t20 = t20 + v * b9
  t21 = t21 + v * b10
  t22 = t22 + v * b11
  t23 = t23 + v * b12
  t24 = t24 + v * b13
  t25 = t25 + v * b14
  t26 = t26 + v * b15
  v = a[12]
  t12 = t12 + v * b0
  t13 = t13 + v * b1
  t14 = t14 + v * b2
  t15 = t15 + v * b3
  t16 = t16 + v * b4
  t17 = t17 + v * b5
  t18 = t18 + v * b6
  t19 = t19 + v * b7
  t20 = t20 + v * b8
  t21 = t21 + v * b9
  t22 = t22 + v * b10
  t23 = t23 + v * b11
  t24 = t24 + v * b12
  t25 = t25 + v * b13
  t26 = t26 + v * b14
  t27 = t27 + v * b15
  v = a[13]
  t13 = t13 + v * b0
  t14 = t14 + v * b1
  t15 = t15 + v * b2
  t16 = t16 + v * b3
  t17 = t17 + v * b4
  t18 = t18 + v * b5
  t19 = t19 + v * b6
  t20 = t20 + v * b7
  t21 = t21 + v * b8
  t22 = t22 + v * b9
  t23 = t23 + v * b10
  t24 = t24 + v * b11
  t25 = t25 + v * b12
  t26 = t26 + v * b13
  t27 = t27 + v * b14
  t28 = t28 + v * b15
  v = a[14]
  t14 = t14 + v * b0
  t15 = t15 + v * b1
  t16 = t16 + v * b2
  t17 = t17 + v * b3
  t18 = t18 + v * b4
  t19 = t19 + v * b5
  t20 = t20 + v * b6
  t21 = t21 + v * b7
  t22 = t22 + v * b8
  t23 = t23 + v * b9
  t24 = t24 + v * b10
  t25 = t25 + v * b11
  t26 = t26 + v * b12
  t27 = t27 + v * b13
  t28 = t28 + v * b14
  t29 = t29 + v * b15
  v = a[15]
  t15 = t15 + v * b0
  t16 = t16 + v * b1
  t17 = t17 + v * b2
  t18 = t18 + v * b3
  t19 = t19 + v * b4
  t20 = t20 + v * b5
  t21 = t21 + v * b6
  t22 = t22 + v * b7
  t23 = t23 + v * b8
  t24 = t24 + v * b9
  t25 = t25 + v * b10
  t26 = t26 + v * b11
  t27 = t27 + v * b12
  t28 = t28 + v * b13
  t29 = t29 + v * b14
  t30 = t30 + v * b15
  t0 = t0 + 38.0 * t16
  t1 = t1 + 38.0 * t17
  t2 = t2 + 38.0 * t18
  t3 = t3 + 38.0 * t19
  t4 = t4 + 38.0 * t20
  t5 = t5 + 38.0 * t21
  t6 = t6 + 38.0 * t22
  t7 = t7 + 38.0 * t23
  t8 = t8 + 38.0 * t24
  t9 = t9 + 38.0 * t25
  t10 = t10 + 38.0 * t26
  t11 = t11 + 38.0 * t27
  t12 = t12 + 38.0 * t28
  t13 = t13 + 38.0 * t29
  t14 = t14 + 38.0 * t30
  // (car25519 twice, unrolled)
  let mut c = 1.0
  v = t0 + c + 65535.0
  c = (v / 65536.0).floor()
  t0 = v - c * 65536.0
  v = t1 + c + 65535.0
  c = (v / 65536.0).floor()
  t1 = v - c * 65536.0
  v = t2 + c + 65535.0
  c = (v / 65536.0).floor()
  t2 = v - c * 65536.0
  v = t3 + c + 65535.0
  c = (v / 65536.0).floor()
  t3 = v - c * 65536.0
  v = t4 + c + 65535.0
  c = (v / 65536.0).floor()
  t4 = v - c * 65536.0
  v = t5 + c + 65535.0
  c = (v / 65536.0).floor()
  t5 = v - c * 65536.0
  v = t6 + c + 65535.0
  c = (v / 65536.0).floor()
  t6 = v - c * 65536.0
  v = t7 + c + 65535.0
  c = (v / 65536.0).floor()
  t7 = v - c * 65536.0
  v = t8 + c + 65535.0
  c = (v / 65536.0).floor()
  t8 = v - c * 65536.0
  v = t9 + c + 65535.0
  c = (v / 65536.0).floor()
  t9 = v - c * 65536.0
  v = t10 + c + 65535.0
  c = (v / 65536.0).floor()
  t10 = v - c * 65536.0
  v = t11 + c + 65535.0
  c = (v / 65536.0).floor()
  t11 = v - c * 65536.0
  v = t12 + c + 65535.0
  c = (v / 65536.0).floor()
  t12 = v - c * 65536.0
  v = t13 + c + 65535.0
  c = (v / 65536.0).floor()
  t13 = v - c * 65536.0
  v = t14 + c + 65535.0
  c = (v / 65536.0).floor()
  t14 = v - c * 65536.0
  v = t15 + c + 65535.0
  c = (v / 65536.0).floor()
  t15 = v - c * 65536.0
  t0 = t0 + 38.0 * (c - 1.0)
  c = 1.0
  v = t0 + c + 65535.0
  c = (v / 65536.0).floor()
  t0 = v - c * 65536.0
  v = t1 + c + 65535.0
  c = (v / 65536.0).floor()
  t1 = v - c * 65536.0
  v = t2 + c + 65535.0
  c = (v / 65536.0).floor()
  t2 = v - c * 65536.0
  v = t3 + c + 65535.0
  c = (v / 65536.0).floor()
  t3 = v - c * 65536.0
  v = t4 + c + 65535.0
  c = (v / 65536.0).floor()
  t4 = v - c * 65536.0
  v = t5 + c + 65535.0
  c = (v / 65536.0).floor()
  t5 = v - c * 65536.0
  v = t6 + c + 65535.0
  c = (v / 65536.0).floor()
  t6 = v - c * 65536.0
  v = t7 + c + 65535.0
  c = (v / 65536.0).floor()
  t7 = v - c * 65536.0
  v = t8 + c + 65535.0
  c = (v / 65536.0).floor()
  t8 = v - c * 65536.0
  v = t9 + c + 65535.0
  c = (v / 65536.0).floor()
  t9 = v - c * 65536.0
  v = t10 + c + 65535.0
  c = (v / 65536.0).floor()
  t10 = v - c * 65536.0
  v = t11 + c + 65535.0
  c = (v / 65536.0).floor()
  t11 = v - c * 65536.0
  v = t12 + c + 65535.0
  c = (v / 65536.0).floor()
  t12 = v - c * 65536.0
  v = t13 + c + 65535.0
  c = (v / 65536.0).floor()
  t13 = v - c * 65536.0
  v = t14 + c + 65535.0
  c = (v / 65536.0).floor()
  t14 = v - c * 65536.0
  v = t15 + c + 65535.0
  c = (v / 65536.0).floor()
  t15 = v - c * 65536.0
  t0 = t0 + 38.0 * (c - 1.0)
  o[0] = t0
  o[1] = t1
  o[2] = t2
  o[3] = t3
  o[4] = t4
  o[5] = t5
  o[6] = t6
  o[7] = t7
  o[8] = t8
  o[9] = t9
  o[10] = t10
  o[11] = t11
  o[12] = t12
  o[13] = t13
  o[14] = t14
  o[15] = t15
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
  base_point(q)
  scalarmult(p, q, s)
}

///|
/// The group's base point, into `q`.
fn base_point(q : Point) -> Unit {
  set25519(q[0], base_x)
  set25519(q[1], base_y)
  set25519(q[2], gf1)
  fmul(q[3], base_x, base_y)
}

///|
/// [h]q + [s]B into `p`, at once (Straus's: one doubling a bit of both, and at most one addition, of q, B or the
/// two summed), where `scalarmult` and `scalarbase` take two ladders of an addition and a doubling a bit each: half
/// the work. Not constant-time, so only for what is public (a signature checked, never one made).
fn double_scalarmult(p : Point, q : Point, h : FixedArray[Byte], s : FixedArray[Byte]) -> Unit {
  set25519(p[0], gf0)
  set25519(p[1], gf1)
  set25519(p[2], gf1)
  set25519(p[3], gf0)
  let b = point()
  base_point(b)
  let qb = point()
  for i in 0..<4 {
    set25519(qb[i], q[i])
  }
  padd(qb, b)
  for i = 255; i >= 0; i = i - 1 {
    padd(p, p)
    let hb = (h[i / 8].to_int() >> (i & 7)) & 1
    let sb = (s[i / 8].to_int() >> (i & 7)) & 1
    if hb == 1 && sb == 1 {
      padd(p, qb)
    } else if hb == 1 {
      padd(p, q)
    } else if sb == 1 {
      padd(p, b)
    }
  }
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

///|
let gf_d : Gf = gf([
  0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070, 0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee,
  0x5203,
])

///|
/// The square root of -1.
let gf_i : Gf = gf([
  0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43, 0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480,
  0x2b83,
])

///|
fn unpack25519(o : Gf, n : FixedArray[Byte]) -> Unit {
  for i in 0..<16 {
    o[i] = (n[2 * i].to_int() + (n[2 * i + 1].to_int() << 8)).to_double()
  }
  o[15] = (o[15].to_int() & 0x7fff).to_double()
}

///|
fn neq25519(a : Gf, b : Gf) -> Bool {
  let c = FixedArray::make(32, b'\x00')
  let d = FixedArray::make(32, b'\x00')
  pack25519(c, a)
  pack25519(d, b)
  c != d
}

///|
fn pow2523(o : Gf, i : Gf) -> Unit {
  let c = i.copy()
  for a = 250; a >= 0; a = a - 1 {
    fsq(c, c)
    if a != 1 {
      fmul(c, c, i)
    }
  }
  set25519(o, c)
}

///|
/// Whether the 32 bytes at `at` of `n`, little first and the top bit left out, are below 2^255 - 19: a y written
/// once only.
fn canonical_y(n : FixedArray[Byte], at : Int) -> Bool {
  // (2^255 - 19 is ed ff .. ff 7f: at or above it only where every byte above the lowest is all ones)
  guard (n[at + 31].to_int() & 0x7f) == 0x7f else { return true }
  for i in 1..<31 {
    guard n[at + i] == b'\xff' else { return true }
  }
  n[at].to_int() < 0xed
}

///|
/// The point `p` (a public key) negated, into `r`: false where it is none of the curve's, or is not written once
/// only (`canonical_y`, and x = 0 with its sign set).
fn unpackneg(r : Point, p : FixedArray[Byte]) -> Bool {
  guard canonical_y(p, 0) else { return false }
  let t = gf([])
  let chk = gf([])
  let num = gf([])
  let den = gf([])
  let den2 = gf([])
  let den4 = gf([])
  let den6 = gf([])
  set25519(r[2], gf1)
  unpack25519(r[1], p)
  fsq(num, r[1])
  fmul(den, num, gf_d)
  fsub(num, num, r[2])
  fadd(den, r[2], den)
  fsq(den2, den)
  fsq(den4, den2)
  fmul(den6, den4, den2)
  fmul(t, den6, num)
  fmul(t, t, den)
  pow2523(t, t)
  fmul(t, t, num)
  fmul(t, t, den)
  fmul(t, t, den)
  fmul(r[0], t, den)
  fsq(chk, r[0])
  fmul(chk, chk, den)
  if neq25519(chk, num) {
    fmul(r[0], r[0], gf_i)
  }
  fsq(chk, r[0])
  fmul(chk, chk, den)
  if neq25519(chk, num) {
    return false
  }
  let sign = p[31].to_int() >> 7
  if sign == 1 && !neq25519(r[0], gf0) {
    return false
  }
  if par25519(r[0]) == sign {
    fsub(r[0], gf0, r[0])
  }
  fmul(r[3], r[0], r[1])
  true
}

///|
/// Whether the 32 bytes at `at` of `n`, little first, are below the group's order.
fn below_order(n : FixedArray[Byte], at : Int) -> Bool {
  for i = 31; i >= 0; i = i - 1 {
    let b = n[at + i].to_int64()
    if b != order_l[i] {
      return b < order_l[i]
    }
  }
  false
}

///|
/// Whether `signature` (64 bytes) is `public_key`'s (32 bytes) over `message`, as RFC 8032 has it: what is not of
/// those lengths, or not a point or a scalar written once only, is no signature. Never fails; the same on every
/// target, and with what the Rust shell's `crypto.verify` says of it.
pub fn ed25519_verify(public_key : Bytes, message : Bytes, signature : Bytes) -> Bool {
  guard public_key.length() == 32 && signature.length() == 64 else { return false }
  let pk = fixed(public_key)
  let sm = fixed(signature)
  guard canonical_y(sm, 0) && below_order(sm, 32) else { return false }
  let q = point()
  guard unpackneg(q, pk) else { return false }
  let sig_r = FixedArray::make(32, b'\x00')
  let s = FixedArray::make(32, b'\x00')
  for i in 0..<32 {
    sig_r[i] = sm[i]
    s[i] = sm[32 + i]
  }
  let h = fixed(sha512(joined_bytes([sig_r, pk, fixed(message)])))
  reduce(h)
  let p = point()
  double_scalarmult(p, q, h, s)
  let t = FixedArray::make(32, b'\x00')
  pack_point(t, p)
  t == sig_r
}
