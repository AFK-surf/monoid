// Ed25519 and SHA-512 (sign.mbt) against RFC 8032's and FIPS 180-4's vectors, on both targets.

///|
fn unhex(text : String) -> Bytes {
  let out : Array[Byte] = []
  let digit = (c : Char) => if c >= 'a' { c.to_int() - 'a'.to_int() + 10 } else { c.to_int() - '0'.to_int() }
  let chars = text.to_array()
  for i = 0; i + 1 < chars.length(); i = i + 2 {
    out.push((digit(chars[i]) * 16 + digit(chars[i + 1])).to_byte())
  }
  Bytes::from_array(out)
}

///|
test "sha512 gives FIPS 180-4's digests, at the padding's edges too" {
  let cases : Array[(Bytes, String)] = [
    (
      b"",
      "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e",
    ),
    (
      b"abc",
      "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
    ),
    (
      Bytes::make(111, b'a'),
      "fa9121c7b32b9e01733d034cfc78cbf67f926c7ed83e82200ef86818196921760b4beff48404df811b953828274461673c68d04e297b0eb7b2b4d60fc6b566a2",
    ),
    (
      Bytes::make(112, b'a'),
      "c01d080efd492776a1c43bd23dd99d0a2e626d481e16782e75d54c2503b5dc32bd05f0f1ba33e568b88fd2d970929b719ecbb152f58f130a407c8830604b70ca",
    ),
    (
      Bytes::make(128, b'a'),
      "b73d1929aa615934e61a871596b3f3b33359f42b8175602e89f7e06e5f658a243667807ed300314b95cacdd579f3e33abdfbe351909519a846d465c59582f321",
    ),
  ]
  for one in cases {
    assert_eq(hex_of(sha512(one.0)), one.1)
  }
}

///|
/// RFC 8032 §7.1, tests 1, 2 and 3: seed, message, public key, signature.
let rfc8032 : Array[(String, String, String, String)] = [
  (
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", "", "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
  ),
  (
    "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb", "72", "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
    "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
  ),
  (
    "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7", "af82", "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
    "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a",
  ),
]

///|
test "ed25519_sign gives RFC 8032's public keys and signatures" {
  for one in rfc8032 {
    let (public_key, signature) = ed25519_sign(unhex(one.0), unhex(one.1))
    assert_eq((hex_of(public_key), hex_of(signature)), (one.2, one.3))
  }
}

///|
/// `bytes` with the bit `bit` of its byte `at` turned over.
fn flipped(bytes : Bytes, at : Int, bit : Int) -> Bytes {
  let out = bytes.to_array()
  out[at] = (out[at].to_int() ^ (1 << bit)).to_byte()
  Bytes::from_array(out)
}

///|
test "ed25519_verify takes RFC 8032's signatures, and none of them with a bit of the key, the message or the signature turned over" {
  for one in rfc8032 {
    let (key, message, signature) = (unhex(one.2), unhex(one.1), unhex(one.3))
    assert_true(ed25519_verify(key, message, signature))
    for at in [0, 7, 31, 32, 45, 63] {
      assert_false(ed25519_verify(key, message, flipped(signature, at, at % 8)))
    }
    for at in [0, 13, 31] {
      assert_false(ed25519_verify(flipped(key, at, (at + 3) % 8), message, signature))
    }
    if message.length() > 0 {
      assert_false(ed25519_verify(key, flipped(message, 0, 0), signature))
    }
    assert_false(ed25519_verify(key, b"\x00" + message, signature))
    // Another's key, or the message another vector signed.
    assert_false(ed25519_verify(unhex(rfc8032[(rfc8032.search(one).unwrap() + 1) % 3].2), message, signature))
  }
}

///|
test "ed25519_verify takes what ed25519_sign signs, for keys and messages drawn, and nothing else of them" {
  // (a fixed draw: the same keys and messages every run)
  let mut state = 0x2545F4914F6CDD1DUL
  let draw = (n : Int) => {
    let out : Array[Byte] = []
    for _ in 0..<n {
      state = state ^ (state << 13)
      state = state ^ (state >> 7)
      state = state ^ (state << 17)
      out.push((state >> 24).to_byte())
    }
    Bytes::from_array(out)
  }
  for round in 0..<8 {
    let seed = draw(32)
    let message = draw(round * 37)
    let (key, signature) = ed25519_sign(seed, message)
    assert_true(ed25519_verify(key, message, signature))
    let at = (draw(1)[0].to_int() * 64) / 256
    assert_false(ed25519_verify(key, message, flipped(signature, at, round % 8)))
    let (other, _) = ed25519_sign(draw(32), b"")
    assert_false(ed25519_verify(other, message, signature))
    if message.length() > 0 {
      assert_false(ed25519_verify(key, flipped(message, message.length() - 1, round % 8), signature))
    }
  }
}

///|
test "ed25519_verify refuses what is not of a key's and a signature's lengths, an S past the group's order, and a point not written once only" {
  let one = rfc8032[0]
  let (key, message, signature) = (unhex(one.2), unhex(one.1), unhex(one.3))
  assert_false(ed25519_verify(key[0:31].to_owned(), message, signature))
  assert_false(ed25519_verify(key + b"\x00", message, signature))
  assert_false(ed25519_verify(key, message, signature[0:63].to_owned()))
  assert_false(ed25519_verify(key, message, signature + b"\x00"))
  assert_false(ed25519_verify(b"", b"", b""))
  // S + L: the same point (TweetNaCl alone takes it), refused as RFC 8032 and the Rust shell's check have it.
  let s = signature.to_array()
  let mut carry = 0
  for i in 0..<32 {
    let sum = s[32 + i].to_int() + order_l[i].to_int() + carry
    s[32 + i] = (sum & 255).to_byte()
    carry = sum >> 8
  }
  assert_eq(carry, 0)
  assert_false(ed25519_verify(key, message, Bytes::from_array(s)))
  // The key that is the group's identity (y = 1): R = B, S = 1 is its signature of anything, written once only;
  // written as y = p + 1, or with x = 0's sign set, it is none.
  let base = unhex("58" + "66".repeat(31))
  let s1 = unhex("01" + "00".repeat(31))
  assert_true(ed25519_verify(unhex("01" + "00".repeat(31)), message, base + s1))
  assert_false(ed25519_verify(unhex("ee" + "ff".repeat(30) + "7f"), message, base + s1))
  assert_false(ed25519_verify(unhex("01" + "00".repeat(30) + "80"), message, base + s1))
  // R the identity and S = 0, under that key: a signature written once only, none with R written as y = p + 1.
  let s0 = Bytes::make(32, b'\x00')
  assert_true(ed25519_verify(unhex("01" + "00".repeat(31)), message, unhex("01" + "00".repeat(31)) + s0))
  assert_false(ed25519_verify(unhex("01" + "00".repeat(31)), message, unhex("ee" + "ff".repeat(30) + "7f") + s0))
}

///|
test "ed25519_verify refuses a y at or past the field's prime, an S at or past the group's order, and x = 0 with its sign set, in a key and in R alike" {
  let one = rfc8032[0]
  let (key, message, signature) = (unhex(one.2), unhex(one.1), unhex(one.3))
  let (sig_r, sig_s) = (signature[0:32].to_owned(), signature[32:64].to_owned())
  // y = p (ed ff .. ff 7f), y = p + 18 (ff .. ff 7f), and each with its sign bit set.
  let prime = unhex("ed" + "ff".repeat(30) + "7f")
  let top = unhex("ff".repeat(31) + "7f")
  for y in [prime, top, flipped(prime, 31, 7), flipped(top, 31, 7)] {
    assert_false(ed25519_verify(y, message, signature))
    assert_false(ed25519_verify(key, message, y + sig_s))
  }
  // S = L, S = 2^256 - 1, and S with its top bit set: none below the order.
  let order = Bytes::from_array(Array::makei(32, i => order_l[i].to_byte()))
  for s in [order, Bytes::make(32, b'\xff'), flipped(sig_s, 31, 7)] {
    assert_false(ed25519_verify(key, message, sig_r + s))
  }
  // y = p - 1 is x = 0 too: written with its sign set it is none, under the identity's signature as under any.
  let base = unhex("58" + "66".repeat(31))
  let s1 = unhex("01" + "00".repeat(31))
  assert_false(ed25519_verify(unhex("ec" + "ff".repeat(30) + "ff"), message, base + s1))
  assert_false(ed25519_verify(key, message, unhex("ec" + "ff".repeat(30) + "ff") + sig_s))
  // (and the signature itself still checks: nothing above was refused for another reason)
  assert_true(ed25519_verify(key, message, signature))
}

///|
test "ed25519_verify refuses every one bit turned over of the key, the message and the signature" {
  let one = rfc8032[1]
  let (key, message, signature) = (unhex(one.2), unhex(one.1), unhex(one.3))
  let mut taken = 0
  for at in 0..<64 {
    for bit in 0..<8 {
      if ed25519_verify(key, message, flipped(signature, at, bit)) {
        taken += 1
      }
    }
  }
  for at in 0..<32 {
    for bit in 0..<8 {
      if ed25519_verify(flipped(key, at, bit), message, signature) {
        taken += 1
      }
    }
  }
  for bit in 0..<8 {
    if ed25519_verify(key, flipped(message, 0, bit), signature) {
      taken += 1
    }
  }
  assert_eq(taken, 0)
  assert_true(ed25519_verify(key, message, signature))
}
