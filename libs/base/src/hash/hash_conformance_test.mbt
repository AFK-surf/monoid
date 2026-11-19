// FIPS 180-4 (SHA-1, SHA-256) and RFC 4231 (HMAC-SHA-256) conformance tests for @hash.

///|
test "conformance: FIPS 180-4 SHA-256 and SHA-1 1,000,000 'a' vector and block-boundary lengths" {
  // FIPS 180-4 / NIST CAVP long message: 1,000,000 repetitions of 'a'
  let chunk = Bytes::make(1000, b'a')
  let s256 = @hash.Sha256::new()
  let s1 = @hash.Sha1::new()
  for _ in 0..<1000 {
    s256.update(chunk)
    s1.update(chunk)
  }
  assert_eq(s256.hex(), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
  assert_eq(s1.hex(), "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
  // Block boundary lengths around 64 bytes (54, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129)
  // Streaming 1 byte at a time must match one-shot for every boundary length
  for n in [0, 1, 54, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129] {
    let data = Bytes::makei(n, i => ((i * 31 + 17) & 0xFF).to_byte())
    let h256 = @hash.Sha256::new()
    let h1 = @hash.Sha1::new()
    for i in 0..<n {
      h256.update(data[i:i + 1])
      h1.update(data[i:i + 1])
    }
    assert_eq(h256.digest(), @hash.sha256(data))
    assert_eq(h1.digest(), @hash.sha1(data))
  }
}

///|
test "conformance: RFC 4231 HMAC-SHA-256 all test cases including 64-byte and 65-byte key boundary" {
  // RFC 4231 Test Case 5 (20-byte key of 0x0c, data "Test With Truncation"; 128-bit prefix a3b6167473100ee06e0c796c2955552b)
  let key5 = Bytes::make(20, b'\x0c')
  assert_eq(
    @hash.hex_encode(@hash.hmac_sha256(key5, b"Test With Truncation")),
    "a3b6167473100ee06e0c796c2955552bfa6f7c0a6a8aef8b93f860aab0cd20c5",
  )
  // Empty key and empty data (verified against node:crypto createHmac("sha256", "").update("").digest("hex"))
  assert_eq(
    @hash.hex_encode(@hash.hmac_sha256(b"", b"")),
    "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad",
  )
  // Exact 64-byte key (not hashed) vs 65-byte key (hashed first per RFC 2104)
  let k64 = Bytes::make(64, b'\x42')
  let k65 = Bytes::make(65, b'\x42')
  assert_eq(
    @hash.hex_encode(@hash.hmac_sha256(k64, b"boundary")),
    "530d9d42d5a799c52ff13d9b7dd313db2604204d1f327e0385c0db94b7e29ff6",
  )
  assert_eq(
    @hash.hex_encode(@hash.hmac_sha256(k65, b"boundary")),
    "76c506d36076cba6b3ee21d9956fc6fbf3c9d71fe33e2868063af84c08dde198",
  )
  // A key longer than 64 bytes produces the exact same HMAC as its SHA-256 digest used as key
  assert_eq(@hash.hmac_sha256(k65, b"boundary"), @hash.hmac_sha256(@hash.sha256(k65), b"boundary"))
}

///|
test "conformance: sha256_utf8_hex and sha1_utf8_hex surrogate pairs and lone surrogates" {
  // Valid surrogate pair U+1F600 (😀) hashes identically to its 4-byte UTF-8 F0 9F 98 80
  let s = StringBuilder()
  s.write_char((0xD83D).unsafe_to_char())
  s.write_char((0xDE00).unsafe_to_char())
  let pair = s.to_string()
  assert_eq(@hash.sha256_utf8_hex(pair), @hash.sha256_hex(b"\xf0\x9f\x98\x80"))
  assert_eq(@hash.sha1_utf8_hex(pair), @hash.sha1_hex(b"\xf0\x9f\x98\x80"))
  // Reversed surrogate pair (low then high) becomes two U+FFFD (EF BF BD EF BF BD)
  let r = StringBuilder()
  r.write_char((0xDE00).unsafe_to_char())
  r.write_char((0xD83D).unsafe_to_char())
  let rev = r.to_string()
  assert_eq(@hash.sha256_utf8_hex(rev), @hash.sha256_hex(b"\xef\xbf\xbd\xef\xbf\xbd"))
  assert_eq(@hash.sha1_utf8_hex(rev), @hash.sha1_hex(b"\xef\xbf\xbd\xef\xbf\xbd"))
}
