// The vault's keys and signatures on this machine (vault_service machine.mbt's `p256_new`, `key_of_pem`,
// `ed25519_of_seed`, `rsa_of_jwk`, `key_pem`, `sign`, `sha1`), made of what the shell has (SHA-256, HMAC-SHA256,
// Ed25519's signature, ECDSA's check) and what is here: SHA-1, SHA-512, P-256's arithmetic and ECDSA (RFC 6979's
// nonce, each signature checked by the shell's verifier before it is given), RSA PKCS#1 v1.5, and the keys' DER
// (PKCS#8, SEC1, PKCS#1) and PEM. Keys are held in this process by their handle.
//
// Known and taken (the lead, 2026-11-17): the arithmetic on BigInt is not constant time, so a process of this machine
// that times many signatures could learn a key; the keys are the vault proxy's own CA and leaves, and an SSH key the
// person granted to one command.

///|
fn p54_hex(b : Bytes) -> String {
  @drive.hex(b)
}

///|
fn p54_unhex(s : String) -> Bytes {
  @vault_crypto.unhex(s)
}

///|
fn p54_cat(parts : Array[Bytes]) -> Bytes {
  let out = @buffer.new()
  for p in parts {
    out.write_bytes(p)
  }
  out.to_bytes()
}

///|
fn p54_sub(b : Bytes, from : Int, to : Int) -> Bytes {
  b[from:to].to_owned()
}

// ── hashes ──

///|
/// SHA-512 (FIPS 180-4).
fn p54_sha512(data : Bytes) -> Bytes {
  let k : Array[UInt64] = [
    0x428a2f98d728ae22UL, 0x7137449123ef65cdUL, 0xb5c0fbcfec4d3b2fUL, 0xe9b5dba58189dbbcUL, 0x3956c25bf348b538UL,
    0x59f111f1b605d019UL, 0x923f82a4af194f9bUL, 0xab1c5ed5da6d8118UL, 0xd807aa98a3030242UL, 0x12835b0145706fbeUL,
    0x243185be4ee4b28cUL, 0x550c7dc3d5ffb4e2UL, 0x72be5d74f27b896fUL, 0x80deb1fe3b1696b1UL, 0x9bdc06a725c71235UL,
    0xc19bf174cf692694UL, 0xe49b69c19ef14ad2UL, 0xefbe4786384f25e3UL, 0x0fc19dc68b8cd5b5UL, 0x240ca1cc77ac9c65UL,
    0x2de92c6f592b0275UL, 0x4a7484aa6ea6e483UL, 0x5cb0a9dcbd41fbd4UL, 0x76f988da831153b5UL, 0x983e5152ee66dfabUL,
    0xa831c66d2db43210UL, 0xb00327c898fb213fUL, 0xbf597fc7beef0ee4UL, 0xc6e00bf33da88fc2UL, 0xd5a79147930aa725UL,
    0x06ca6351e003826fUL, 0x142929670a0e6e70UL, 0x27b70a8546d22ffcUL, 0x2e1b21385c26c926UL, 0x4d2c6dfc5ac42aedUL,
    0x53380d139d95b3dfUL, 0x650a73548baf63deUL, 0x766a0abb3c77b2a8UL, 0x81c2c92e47edaee6UL, 0x92722c851482353bUL,
    0xa2bfe8a14cf10364UL, 0xa81a664bbc423001UL, 0xc24b8b70d0f89791UL, 0xc76c51a30654be30UL, 0xd192e819d6ef5218UL,
    0xd69906245565a910UL, 0xf40e35855771202aUL, 0x106aa07032bbd1b8UL, 0x19a4c116b8d2d0c8UL, 0x1e376c085141ab53UL,
    0x2748774cdf8eeb99UL, 0x34b0bcb5e19b48a8UL, 0x391c0cb3c5c95a63UL, 0x4ed8aa4ae3418acbUL, 0x5b9cca4f7763e373UL,
    0x682e6ff3d6b2b8a3UL, 0x748f82ee5defb2fcUL, 0x78a5636f43172f60UL, 0x84c87814a1f0ab72UL, 0x8cc702081a6439ecUL,
    0x90befffa23631e28UL, 0xa4506cebde82bde9UL, 0xbef9a3f7b2c67915UL, 0xc67178f2e372532bUL, 0xca273eceea26619cUL,
    0xd186b8c721c0c207UL, 0xeada7dd6cde0eb1eUL, 0xf57d4f7fee6ed178UL, 0x06f067aa72176fbaUL, 0x0a637dc5a2c898a6UL,
    0x113f9804bef90daeUL, 0x1b710b35131c471bUL, 0x28db77f523047d84UL, 0x32caab7b40c72493UL, 0x3c9ebe0a15c9bebcUL,
    0x431d67c49c100d4cUL, 0x4cc5d4becb3e42b6UL, 0x597f299cfc657e2aUL, 0x5fcb6fab3ad6faecUL, 0x6c44198c4a475817UL,
  ]
  let h = [
    0x6a09e667f3bcc908UL, 0xbb67ae8584caa73bUL, 0x3c6ef372fe94f82bUL, 0xa54ff53a5f1d36f1UL, 0x510e527fade682d1UL,
    0x9b05688c2b3e6c1fUL, 0x1f83d9abfb41bd6bUL, 0x5be0cd19137e2179UL,
  ]
  let ml = data.length()
  let total = (ml + 17 + 127) / 128 * 128
  let m = FixedArray::make(total, b'\x00')
  for i in 0..<ml {
    m[i] = data[i]
  }
  m[ml] = b'\x80'
  let bits = ml.to_uint64() * 8UL
  for i in 0..<8 {
    m[total - 1 - i] = (bits >> (8 * i)).to_byte()
  }
  let rotr = (x : UInt64, n : Int) => (x >> n) | (x << (64 - n))
  let w = FixedArray::make(80, 0UL)
  let mut off = 0
  while off < total {
    for t in 0..<16 {
      let mut v = 0UL
      for j in 0..<8 {
        v = (v << 8) | m[off + 8 * t + j].to_uint64()
      }
      w[t] = v
    }
    for t in 16..<80 {
      let s0 = rotr(w[t - 15], 1) ^ rotr(w[t - 15], 8) ^ (w[t - 15] >> 7)
      let s1 = rotr(w[t - 2], 19) ^ rotr(w[t - 2], 61) ^ (w[t - 2] >> 6)
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
      let s1 = rotr(e, 14) ^ rotr(e, 18) ^ rotr(e, 41)
      let ch = (e & f) ^ (e.lnot() & g)
      let t1 = hh + s1 + ch + k[t] + w[t]
      let s0 = rotr(a, 28) ^ rotr(a, 34) ^ rotr(a, 39)
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
    off += 128
  }
  Bytes::makei(64, i => (h[i / 8] >> (56 - 8 * (i % 8))).to_byte())
}

///|
fn p54_sha256(host : @host.Host, data : Bytes) -> Bytes {
  @vault_crypto.Crypto::of_host(host).sha256(data) catch { _ => b"" }
}

///|
fn p54_hmac256(host : @host.Host, key : Bytes, data : Bytes) -> Bytes {
  match (try { Ok(host.shell_sync("crypto.hmacSha256", { "key": Json::string(p54_hex(key)), "data": Json::string(p54_hex(data)) })) } catch { e => Err(e) }) {
    Ok(String(h)) => p54_unhex(h)
    _ => b""
  }
}

///|
fn p54_hash(host : @host.Host, name : String, data : Bytes) -> Bytes raise {
  match name {
    "sha1" => @hash.sha1(data)
    "sha256" => p54_sha256(host, data)
    "sha512" => p54_sha512(data)
    _ => raise Failure("no hash \{name}")
  }
}

// ── P-256 ──

///|
fn p54_big(b : Bytes) -> @bigint.BigInt {
  @bigint.BigInt::from_octets(b)
}

///|
fn p54_big_hex(s : String) -> @bigint.BigInt {
  @bigint.BigInt::from_string(s, radix=16)
}

///|
fn p54_octets(n : @bigint.BigInt, len : Int) -> Bytes {
  n.to_octets(length=len)
}

///|
/// `a mod m`, never negative.
fn p54_mod(a : @bigint.BigInt, m : @bigint.BigInt) -> @bigint.BigInt {
  let r = a % m
  if r < 0N {
    r + m
  } else {
    r
  }
}

///|
fn p54_inv(a : @bigint.BigInt, m : @bigint.BigInt) -> @bigint.BigInt {
  p54_mod(a, m).pow(m - 2N, modulus=m)
}

///|
let p54_p : @bigint.BigInt = p54_big_hex("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff")

///|
let p54_n : @bigint.BigInt = p54_big_hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")

///|
let p54_b : @bigint.BigInt = p54_big_hex("5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b")

///|
let p54_gx : @bigint.BigInt = p54_big_hex("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296")

///|
let p54_gy : @bigint.BigInt = p54_big_hex("4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")

///|
/// A point in Jacobian coordinates (Z 0: the point at infinity).
priv struct P54Point {
  x : @bigint.BigInt
  y : @bigint.BigInt
  z : @bigint.BigInt
}

///|
fn p54_double(a : P54Point) -> P54Point {
  if a.z == 0N || a.y == 0N {
    return { x: 0N, y: 1N, z: 0N }
  }
  let p = p54_p
  let yy = p54_mod(a.y * a.y, p)
  let s = p54_mod(4N * a.x * yy, p)
  let zz = p54_mod(a.z * a.z, p)
  // (a = -3: M = 3(X - Z²)(X + Z²))
  let m = p54_mod(3N * (a.x - zz) * (a.x + zz), p)
  let x = p54_mod(m * m - 2N * s, p)
  let y = p54_mod(m * (s - x) - 8N * yy * yy, p)
  let z = p54_mod(2N * a.y * a.z, p)
  { x, y, z }
}

///|
fn p54_add(a : P54Point, b : P54Point) -> P54Point {
  if a.z == 0N {
    return b
  }
  if b.z == 0N {
    return a
  }
  let p = p54_p
  let z1z1 = p54_mod(a.z * a.z, p)
  let z2z2 = p54_mod(b.z * b.z, p)
  let u1 = p54_mod(a.x * z2z2, p)
  let u2 = p54_mod(b.x * z1z1, p)
  let s1 = p54_mod(a.y * b.z * z2z2, p)
  let s2 = p54_mod(b.y * a.z * z1z1, p)
  if u1 == u2 {
    if s1 == s2 {
      return p54_double(a)
    }
    return { x: 0N, y: 1N, z: 0N }
  }
  let h = p54_mod(u2 - u1, p)
  let r = p54_mod(s2 - s1, p)
  let hh = p54_mod(h * h, p)
  let hhh = p54_mod(h * hh, p)
  let v = p54_mod(u1 * hh, p)
  let x = p54_mod(r * r - hhh - 2N * v, p)
  let y = p54_mod(r * (v - x) - s1 * hhh, p)
  let z = p54_mod(a.z * b.z * h, p)
  { x, y, z }
}

///|
/// `k`·P (a ladder of doubles and adds over every bit).
fn p54_mul(k : @bigint.BigInt, x : @bigint.BigInt, y : @bigint.BigInt) -> (@bigint.BigInt, @bigint.BigInt)? {
  let mut r0 : P54Point = { x: 0N, y: 1N, z: 0N }
  let mut r1 : P54Point = { x, y, z: 1N }
  let bits = 256
  for i = bits - 1; i >= 0; i = i - 1 {
    if ((k >> i) & 1N) == 1N {
      r0 = p54_add(r0, r1)
      r1 = p54_double(r1)
    } else {
      r1 = p54_add(r0, r1)
      r0 = p54_double(r0)
    }
  }
  if r0.z == 0N {
    return None
  }
  let zi = p54_inv(r0.z, p54_p)
  let zi2 = p54_mod(zi * zi, p54_p)
  Some((p54_mod(r0.x * zi2, p54_p), p54_mod(r0.y * zi2 * zi, p54_p)))
}

///|
/// The public point `04‖x‖y` of the private scalar `d`.
fn p54_p256_public(d : Bytes) -> Bytes raise {
  match p54_mul(p54_big(d), p54_gx, p54_gy) {
    Some((x, y)) => p54_cat([b"\x04", p54_octets(x, 32), p54_octets(y, 32)])
    None => raise Failure("not a P-256 key")
  }
}

///|
/// P-256's ECDH: the x-coordinate of `d`·Q for the peer's uncompressed point Q (checked on the curve).
fn p54_p256_shared(d : Bytes, peer : Bytes) -> Bytes raise {
  if peer.length() != 65 || peer[0] != b'\x04' {
    raise Failure("not an uncompressed P-256 point")
  }
  let x = p54_big(p54_sub(peer, 1, 33))
  let y = p54_big(p54_sub(peer, 33, 65))
  let p = p54_p
  if p54_mod(y * y, p) != p54_mod(x * x * x - 3N * x + p54_b, p) {
    raise Failure("the point is not on P-256")
  }
  match p54_mul(p54_big(d), x, y) {
    Some((sx, _)) => p54_octets(sx, 32)
    None => raise Failure("the shared point is at infinity")
  }
}

///|
/// A new P-256 private scalar (1 ≤ d < n), from the system's random bytes.
fn p54_p256_new_scalar() -> Bytes {
  while true {
    let b = @drive.random_bytes(32)
    let d = p54_big(b)
    if d > 0N && d < p54_n {
      return b
    }
  }
  b""
}

///|
/// RFC 6979's k for `d` and the message's hash `h1` (SHA-256, HMAC by the shell's).
fn p54_rfc6979(host : @host.Host, d : Bytes, h1 : Bytes) -> @bigint.BigInt {
  let q = p54_n
  let bx = p54_cat([d, p54_octets(p54_mod(p54_big(h1), q), 32)])
  let mut v = Bytes::make(32, b'\x01')
  let mut k = Bytes::make(32, b'\x00')
  k = p54_hmac256(host, k, p54_cat([v, b"\x00", bx]))
  v = p54_hmac256(host, k, v)
  k = p54_hmac256(host, k, p54_cat([v, b"\x01", bx]))
  v = p54_hmac256(host, k, v)
  while true {
    v = p54_hmac256(host, k, v)
    let t = p54_big(v)
    if t > 0N && t < q {
      return t
    }
    k = p54_hmac256(host, k, p54_cat([v, b"\x00"]))
    v = p54_hmac256(host, k, v)
  }
  0N
}

///|
/// ECDSA over SHA-256 with `d`: r‖s (32 bytes each), checked by the shell's verifier against `public`.
fn p54_ecdsa_raw(host : @host.Host, d : Bytes, public : Bytes, message : Bytes) -> Bytes raise {
  let h = p54_sha256(host, message)
  let e = p54_big(h)
  let n = p54_n
  let dd = p54_big(d)
  let mut extra = 0
  while true {
    let k = if extra == 0 {
      p54_rfc6979(host, d, h)
    } else {
      p54_big(p54_p256_new_scalar())
    }
    extra += 1
    guard p54_mul(k, p54_gx, p54_gy) is Some((x, _)) else { continue }
    let r = p54_mod(x, n)
    if r == 0N {
      continue
    }
    let s = p54_mod(p54_inv(k, n) * (e + r * dd), n)
    if s == 0N {
      continue
    }
    let sig = p54_cat([p54_octets(r, 32), p54_octets(s, 32)])
    if !@vault_crypto.Crypto::of_host(host).verify("ES256", public, sig, message) {
      raise Failure("a P-256 signature made here did not check")
    }
    return sig
  }
  b""
}

// ── DER ──

///|
fn p54_der_len(n : Int) -> Bytes {
  if n < 128 {
    Bytes::make(1, n.to_byte())
  } else if n < 256 {
    Bytes::from_array([b'\x81', n.to_byte()])
  } else if n < 65536 {
    Bytes::from_array([b'\x82', (n >> 8).to_byte(), n.to_byte()])
  } else {
    Bytes::from_array([b'\x83', (n >> 16).to_byte(), (n >> 8).to_byte(), n.to_byte()])
  }
}

///|
fn p54_tlv(tag : Int, body : Bytes) -> Bytes {
  p54_cat([Bytes::make(1, tag.to_byte()), p54_der_len(body.length()), body])
}

///|
/// A DER INTEGER of the unsigned big-endian `b`.
fn p54_der_uint(b : Bytes) -> Bytes {
  let mut i = 0
  while i < b.length() - 1 && b[i] == b'\x00' {
    i += 1
  }
  let t = p54_sub(b, i, b.length())
  let body = if t.length() > 0 && t[0].to_int() >= 0x80 { p54_cat([b"\x00", t]) } else { t }
  p54_tlv(0x02, if body.length() == 0 { b"\x00" } else { body })
}

///|
fn p54_der_seq(parts : Array[Bytes]) -> Bytes {
  p54_tlv(0x30, p54_cat(parts))
}

///|
let p54_oid_ec : Bytes = b"\x06\x07\x2a\x86\x48\xce\x3d\x02\x01"

///|
let p54_oid_p256 : Bytes = b"\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07"

///|
let p54_oid_ed25519 : Bytes = b"\x06\x03\x2b\x65\x70"

///|
let p54_oid_rsa : Bytes = b"\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01"

///|
/// A DER element read: its tag, its body, and where the next one starts.
fn p54_der_read(b : Bytes, at : Int) -> (Int, Bytes, Int) raise {
  if at + 2 > b.length() {
    raise Failure("DER cut short")
  }
  let tag = b[at].to_int()
  let first = b[at + 1].to_int()
  let mut len = 0
  let mut head = 2
  if first < 128 {
    len = first
  } else {
    let n = first & 0x7f
    if n == 0 || n > 3 || at + 2 + n > b.length() {
      raise Failure("DER length")
    }
    for i in 0..<n {
      len = (len << 8) | b[at + 2 + i].to_int()
    }
    head = 2 + n
  }
  if at + head + len > b.length() {
    raise Failure("DER cut short")
  }
  (tag, p54_sub(b, at + head, at + head + len), at + head + len)
}

///|
/// The elements of a SEQUENCE's body.
fn p54_der_items(body : Bytes) -> Array[(Int, Bytes)] raise {
  let out = []
  let mut at = 0
  while at < body.length() {
    let (tag, v, next) = p54_der_read(body, at)
    out.push((tag, v))
    at = next
  }
  out
}

///|
fn p54_strip(b : Bytes) -> Bytes {
  let mut i = 0
  while i < b.length() - 1 && b[i] == b'\x00' {
    i += 1
  }
  p54_sub(b, i, b.length())
}

///|
/// The bytes of a PEM's base64 between its BEGIN and END lines, and its label.
fn p54_pem_parts(text : String) -> (String, Bytes)? {
  guard text.find("-----BEGIN ") is Some(b) else { return None }
  let after = text[b + 11:].to_owned()
  guard after.find("-----") is Some(e) else { return None }
  let label = after[:e].to_owned()
  let rest = after[e + 5:].to_owned()
  guard rest.find("-----END ") is Some(stop) else { return None }
  let body = StringBuilder::new()
  for c in rest[:stop] {
    if c != '\n' && c != '\r' && c != ' ' && c != '\t' {
      body.write_char(c)
    }
  }
  Some((label, @vault_crypto.unb64(body.to_string())))
}

///|
fn p54_pem(label : String, der : Bytes) -> String {
  let b64 = @drive.base64(der)
  let out = StringBuilder::new()
  out.write_string("-----BEGIN \{label}-----\n")
  let mut i = 0
  while i < b64.length() {
    let j = if i + 64 < b64.length() { i + 64 } else { b64.length() }
    out.write_string(b64[i:j].to_owned())
    out.write_char('\n')
    i = j
  }
  out.write_string("-----END \{label}-----\n")
  out.to_string()
}

// ── the keys held ──

///|
/// A private key held here: P-256's scalar, Ed25519's seed, or RSA's parts (n, e, d, p, q, dp, dq, qi).
priv enum P54Key {
  P256(Bytes)
  Ed(Bytes)
  Rsa(Array[Bytes])
}

///|
let p54_keys : Map[String, P54Key] = Map([])

///|
let p54_next_key : Ref[Int] = Ref(0)

///|
fn p54_key_ref(host : @host.Host, k : P54Key) -> @vault_service.KeyRef raise {
  p54_next_key.val += 1
  let handle = "k\{p54_next_key.val}"
  p54_keys[handle] = k
  match k {
    P256(d) => { handle, kind: "p256", public: [p54_p256_public(d)] }
    Ed(seed) => {
      let said = host.shell_sync("ed25519.sign", { "seed": Json::string(p54_hex(seed)), "message": Json::string("") })
      { handle, kind: "ed25519", public: [p54_unhex(p54_text(Some(said), "publicKey").unwrap_or(""))] }
    }
    Rsa(parts) => { handle, kind: "rsa", public: [p54_strip(parts[1]), p54_strip(parts[0])] }
  }
}

///|
fn p54_key_of(r : @vault_service.KeyRef) -> P54Key raise {
  match p54_keys.get(r.handle) {
    Some(k) => k
    None => raise Failure("no such key here")
  }
}

///|
/// A private key from its PEM: PKCS#8 (P-256, Ed25519, RSA), SEC1 (`EC PRIVATE KEY`), PKCS#1 (`RSA PRIVATE KEY`).
fn p54_key_of_der(label : String, der : Bytes) -> P54Key? raise {
  let (tag, body, _) = p54_der_read(der, 0)
  if tag != 0x30 {
    return None
  }
  let items = p54_der_items(body)
  let sec1 = (seq : Array[(Int, Bytes)]) => match seq.get(1) {
    Some((0x04, d)) if d.length() <= 32 => Some(P256(p54_cat([Bytes::make(32 - d.length(), b'\x00'), d])))
    _ => None
  }
  let pkcs1 = (seq : Array[(Int, Bytes)]) => if seq.length() >= 9 {
    Some(Rsa(seq[1:9].to_array().map(x => p54_strip(x.1))))
  } else {
    None
  }
  match label {
    "EC PRIVATE KEY" => sec1(items)
    "RSA PRIVATE KEY" => pkcs1(items)
    _ => {
      // PKCS#8: version, its algorithm, the key in an OCTET STRING
      guard items.get(1) is Some((0x30, alg)) && items.get(2) is Some((0x04, inner)) else { return None }
      let a = p54_der_items(alg)
      let oid = match a.get(0) {
        Some((_, o)) => p54_tlv(0x06, o)
        None => b""
      }
      if oid == p54_oid_ec {
        let (_, eb, _) = p54_der_read(inner, 0)
        sec1(p54_der_items(eb))
      } else if oid == p54_oid_ed25519 {
        let (_, seed, _) = p54_der_read(inner, 0)
        if seed.length() == 32 { Some(Ed(seed)) } else { None }
      } else if oid == p54_oid_rsa {
        let (_, rb, _) = p54_der_read(inner, 0)
        pkcs1(p54_der_items(rb))
      } else {
        None
      }
    }
  }
}

///|
/// A key's PKCS#8 DER.
fn p54_pkcs8(host : @host.Host, k : P54Key) -> Bytes raise {
  let v0 = p54_der_uint(b"\x00")
  match k {
    P256(d) => {
      let ec = p54_der_seq([p54_der_uint(b"\x01"), p54_tlv(0x04, d), p54_tlv(0xa1, p54_tlv(0x03, p54_cat([b"\x00", p54_p256_public(d)])))])
      p54_der_seq([v0, p54_der_seq([p54_oid_ec, p54_oid_p256]), p54_tlv(0x04, ec)])
    }
    Ed(seed) => {
      ignore(host)
      p54_der_seq([v0, p54_der_seq([p54_oid_ed25519]), p54_tlv(0x04, p54_tlv(0x04, seed))])
    }
    Rsa(parts) => {
      let rsa = p54_der_seq([v0, ..parts.map(p54_der_uint)])
      p54_der_seq([v0, p54_der_seq([p54_oid_rsa, b"\x05\x00"]), p54_tlv(0x04, rsa)])
    }
  }
}

///|
/// DigestInfo's prefix for `hash` (RFC 8017 §9.2).
fn p54_digest_info(hash : String) -> Bytes raise {
  match hash {
    "sha1" => p54_unhex("3021300906052b0e03021a05000414")
    "sha256" => p54_unhex("3031300d060960864801650304020105000420")
    "sha512" => p54_unhex("3051300d060960864801650304020305000440")
    _ => raise Failure("no RSA signature with \{hash}")
  }
}

///|
/// RSA PKCS#1 v1.5 (EMSA-PKCS1-v1_5, then m^d mod n), checked against e.
fn p54_rsa_sign(host : @host.Host, parts : Array[Bytes], hash : String, data : Bytes) -> Bytes raise {
  let n = p54_big(parts[0])
  let e = p54_big(parts[1])
  let d = p54_big(parts[2])
  let k = (n.bit_length() + 7) / 8
  let t = p54_cat([p54_digest_info(hash), p54_hash(host, hash, data)])
  if k < t.length() + 11 {
    raise Failure("the RSA key is too short")
  }
  let em = p54_cat([b"\x00\x01", Bytes::make(k - t.length() - 3, b'\xff'), b"\x00", t])
  let s = p54_big(em).pow(d, modulus=n)
  if s.pow(e, modulus=n) != p54_big(em) {
    raise Failure("an RSA signature made here did not check")
  }
  p54_octets(s, k)
}

///|
/// The key primitives of the vault's machine, as the record its fields are.
fn p54_key_ops(host : @host.Host) -> (
  async () -> @vault_service.KeyRef,
  async (String) -> @vault_service.KeyRef?,
  async (Bytes) -> @vault_service.KeyRef,
  async (Json) -> @vault_service.KeyRef,
  async (@vault_service.KeyRef) -> String,
  async (@vault_service.KeyRef, String, Bytes) -> Bytes,
  async (Bytes) -> Bytes,
) {
  (
    async fn() { p54_key_ref(host, P256(p54_p256_new_scalar())) },
    async fn(text) {
      guard p54_pem_parts(text) is Some((label, der)) else { return None }
      match (try { Ok(p54_key_of_der(label, der)) } catch { e => Err(e) }) {
        Ok(Some(k)) => Some(p54_key_ref(host, k))
        _ => None
      }
    },
    async fn(seed) { p54_key_ref(host, Ed(seed)) },
    async fn(jwk) {
      let part = (k : String) => @vault_crypto.unb64(p54_text(Some(jwk), k).unwrap_or("").replace_all(old="-", new="+").replace_all(old="_", new="/"))
      p54_key_ref(host, Rsa(["n", "e", "d", "p", "q", "dp", "dq", "qi"].map(k => p54_strip(part(k)))))
    },
    async fn(r) { p54_pem("PRIVATE KEY", p54_pkcs8(host, p54_key_of(r))) },
    async fn(r, hash, data) {
      match p54_key_of(r) {
        P256(d) => {
          let raw = p54_ecdsa_raw(host, d, r.public[0], data)
          p54_der_seq([p54_der_uint(p54_sub(raw, 0, 32)), p54_der_uint(p54_sub(raw, 32, 64))])
        }
        Ed(seed) => {
          let said = host.shell_sync("ed25519.sign", { "seed": Json::string(p54_hex(seed)), "message": Json::string(p54_hex(data)) })
          p54_unhex(p54_text(Some(said), "signature").unwrap_or(""))
        }
        Rsa(parts) => p54_rsa_sign(host, parts, hash, data)
      }
    },
    async fn(b) { @hash.sha1(b) },
  )
}
