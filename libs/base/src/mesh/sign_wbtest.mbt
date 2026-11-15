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
