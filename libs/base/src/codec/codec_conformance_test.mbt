// RFC 4648 (Base64 / Base64URL / Base16) and IEEE 802.3 CRC-32 conformance tests for @codec.

///|
test "conformance: RFC 4648 §10 Base64, Base64URL, and Base16 official vectors" {
  // RFC 4648 §10 Base64 vectors
  let b64_vecs : Array[(Bytes, String, String)] = [
    (b"", "", ""),
    (b"f", "Zg==", "66"),
    (b"fo", "Zm8=", "666F"),
    (b"foo", "Zm9v", "666F6F"),
    (b"foob", "Zm9vYg==", "666F6F62"),
    (b"fooba", "Zm9vYmE=", "666F6F6261"),
    (b"foobar", "Zm9vYmFy", "666F6F626172"),
  ]
  for v in b64_vecs {
    let (raw, b64, hex_up) = v
    assert_eq(@codec.base64_encode(raw), b64)
    assert_eq(@codec.base64_decode_strict(b64), Some(raw))
    assert_eq(@codec.base64_decode(b64), Some(raw))
    assert_eq(@codec.hex_encode_upper(raw), hex_up)
    assert_eq(@codec.hex_decode(hex_up), Some(raw))
    assert_eq(@codec.hex_decode(hex_up.to_lower()), Some(raw))
  }
}

///|
test "conformance: RFC 4648 §3.5 canonical non-zero trailing pad bits rejected by strict decoder" {
  // For 1 byte (2 base64 chars + "=="): bottom 4 bits of char 2 must be 0.
  // "Zg==" is 'f' (0x66 = 011001 100000); 'g' = 32 (100000). Changing low 4 bits: 'h'=33..'v'=47
  assert_eq(@codec.base64_decode_strict("Zg=="), Some(b"f"))
  for bad in ["Zh==", "Zi==", "Zj==", "Zv=="] {
    assert_eq(@codec.base64_decode_strict(bad), None)
    // Lenient decoder ignores non-canonical pad bits (Node Buffer.from compatibility)
    assert_eq(@codec.base64_decode(bad), Some(b"f"))
  }
  // For 2 bytes (3 base64 chars + "="): bottom 2 bits of char 3 must be 0.
  // "Zm8=" is "fo" (0x66 0x6f); '8' = 60 (111100). '9'=61, '+'=62, '/'=63 have non-zero low 2 bits.
  assert_eq(@codec.base64_decode_strict("Zm8="), Some(b"fo"))
  for bad in ["Zm9=", "Zm+=", "Zm/="] {
    assert_eq(@codec.base64_decode_strict(bad), None)
    assert_eq(@codec.base64_decode(bad), Some(b"fo"))
  }
}

///|
test "conformance: Base64 / Base64URL padding, whitespace, and invalid character matrix" {
  // Strict rejects missing padding, extra padding, embedded padding, whitespace, URL-safe chars, and length % 4 == 1
  for bad in [
    "Zg", "Zm8", "Zm9vYg", "Zm9vYmE",
    "=", "==", "===", "====", "Zg=", "Zg===", "Zm8==", "Zm9v=", "Zm9v==",
    "Z", "Zm9vZ", "Zg==Zm9v", "Zg= =",
    " Zg==", "Zg== ", "Zg\n==", "Zg\r\n==", "Zg\t==", "Zg\u{0c}==",
    "-_8=", "Zm9v-w==", "Zm9v_w==",
    "Zm9*", "Zm9\u{00}", "Zm9\u{7f}",
  ] {
    assert_eq(@codec.base64_decode_strict(bad), None)
  }
  // URL-safe decoder accepts padded or unpadded `-_` but rejects `+/`, whitespace, bad padding, and rest==1
  assert_eq(@codec.base64url_decode("-_8"), Some(b"\xfb\xff"))
  assert_eq(@codec.base64url_decode("-_8="), Some(b"\xfb\xff"))
  assert_eq(@codec.base64url_decode("-w"), Some(b"\xfb"))
  assert_eq(@codec.base64url_decode("-w=="), Some(b"\xfb"))
  for bad in ["+/8=", "+/8", "-_8==", "-w=", " -_8", "-_8\n", "A", "AAAA=", "-_8=A"] {
    assert_eq(@codec.base64url_decode(bad), None)
  }
  // Lenient decoder accepts ASCII whitespace (SP, HT, LF, FF, CR), optional padding, and mixed alphabets
  assert_eq(@codec.base64_decode("\t\r\n\u{0c} Zg== "), Some(b"f"))
  assert_eq(@codec.base64_decode("Zm9v\r\nYmFy"), Some(b"foobar"))
  assert_eq(@codec.base64_decode("+-/_"), Some(b"\xfb\xef\xff"))
  // Loose decoder matches Node Buffer.from(s, "base64") stopping at first '=' and skipping garbage
  assert_eq(@codec.base64_decode_loose("Zg==garbage"), b"f")
  assert_eq(@codec.base64_decode_loose("Z!g@"), b"f")
  assert_eq(@codec.base64_decode_loose("===="), b"")
}

///|
test "conformance: IEEE CRC-32 check value, known vectors, and incremental update invariance" {
  // Standard IEEE 802.3 CRC-32 check value for ASCII "123456789"
  assert_eq(@codec.crc32(b"123456789"), 0xCBF43926U)
  assert_eq(@codec.crc32(b""), 0x00000000U)
  // All-zero buffers of various lengths (verified against zlib.crc32)
  assert_eq(@codec.crc32(Bytes::make(1, b'\x00')), 0xD202EF8DU)
  assert_eq(@codec.crc32(Bytes::make(32, b'\x00')), 0x190A55ADU)
  assert_eq(@codec.crc32(Bytes::make(32, b'\xff')), 0xFF6CAB0BU)
  // Incremental 0x00..0x1f (RFC 3720 / zlib test vector)
  let seq32 = Bytes::makei(32, i => i.to_byte())
  assert_eq(@codec.crc32(seq32), 0x91267E8AU)
  // Incremental equivalence across all split points of "123456789"
  let check_bytes = b"123456789"
  for split in 0..=check_bytes.length() {
    let c1 = @codec.crc32(check_bytes[:split])
    let c2 = @codec.crc32_update(c1, check_bytes[split:])
    assert_eq(c2, 0xCBF43926U)
  }
  // Empty updates anywhere are identity
  assert_eq(@codec.crc32_update(@codec.crc32_update(0U, b""), check_bytes), 0xCBF43926U)
}
