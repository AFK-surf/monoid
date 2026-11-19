// SHA-256 against FIPS 180-4's vectors and the padding's edges, taken at once and a piece at a time; HMAC-SHA-256
// against RFC 4231's; a text's UTF-8 as node:crypto takes it; hex both ways. On both targets.

///|
test "sha256 gives FIPS 180-4's digests" {
  assert_eq(@hash.sha256_hex(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  assert_eq(@hash.sha256_hex(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  assert_eq(
    @hash.sha256_hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  )
  assert_eq(
    @hash.sha256_hex(
      b"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
    ),
    "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
  )
  let abc = @hash.sha256(b"abc")
  assert_eq(abc.length(), 32)
  assert_eq(@hash.hex_encode(abc), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

///|
test "sha256 at the padding's edges: one block, two blocks, a block whole and past it" {
  let cases : Array[(Int, String)] = [
    (0, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
    (55, "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"),
    (56, "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"),
    (63, "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34"),
    (64, "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"),
    (65, "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0"),
    (1000, "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"),
  ]
  for one in cases {
    assert_eq(@hash.sha256_hex(Bytes::make(one.0, b'a')), one.1)
  }
}

///|
test "a hash taken a piece at a time is the hash taken at once, whatever the pieces" {
  let data = Bytes::makei(1000, i => ((i * 7 + 3) % 256).to_byte())
  let whole = "1e9bc38cbf860b9ec31918b065f9b52476c549a782e0e7990bed8ce3868d2371"
  assert_eq(@hash.sha256_hex(data), whole)
  for size in [1, 3, 55, 56, 63, 64, 65, 127, 999, 1000] {
    let s = @hash.Sha256::new()
    let mut at = 0
    while at < data.length() {
      let end = if at + size < data.length() { at + size } else { data.length() }
      s.update(data[at:end])
      at = end
    }
    assert_eq(s.hex(), whole)
  }
  // A digest spends nothing: asked half way, the hash goes on.
  let s = @hash.Sha256::new()
  s.update(data[0:500])
  assert_eq(s.hex(), "ba626314ec76f1ea4665d5a74e8f84337ba24465687c64c5e4ef4e43424e49a0")
  s.update(data[500:])
  assert_eq(s.hex(), whole)
  assert_eq(@hash.hex_encode(s.digest()), whole)
  assert_eq(@hash.Sha256::new().hex(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

///|
test "hmac_sha256 gives RFC 4231's" {
  let cases : Array[(Bytes, Bytes, String)] = [
    (b"\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b", b"Hi There", "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"),
    (b"Jefe", b"what do ya want for nothing?", "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"),
    (b"\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa", b"\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd\xdd", "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"),
    (b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19", b"\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd\xcd", "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"),
    (b"\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa", b"Test Using Larger Than Block-Size Key - Hash Key First", "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"),
    (b"\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa", b"This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm.", "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2"),
  ]
  for one in cases {
    assert_eq(@hash.hex_encode(@hash.hmac_sha256(one.0, one.1)), one.2)
  }
}

///|
test "sha256_utf8_hex hashes a text's UTF-8 as node:crypto does, a lone surrogate as U+FFFD" {
  assert_eq(@hash.sha256_utf8_hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  assert_eq(@hash.sha256_utf8_hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  assert_eq(@hash.sha256_utf8_hex("é🚀 中"), "2ea422a2002cfef069bd95dbae76bb659e9416ae0939bc89006cdf69e38cdbe1")
  assert_eq(@hash.sha256_utf8_hex("é🚀 中"), @hash.sha256_hex(@utf8.encode("é🚀 中")))
  let lone = StringBuilder()
  lone.write_char('a')
  lone.write_char((0xD800).unsafe_to_char())
  lone.write_char('b')
  assert_eq(@hash.sha256_utf8_hex(lone.to_string()), "05087813392efc16fe8ff448920c6328e53af865df39419436659d9ffda90f7b")
  let last = StringBuilder()
  last.write_char('x')
  last.write_char((0xDC00).unsafe_to_char())
  assert_eq(@hash.sha256_utf8_hex(last.to_string()), "5f350b94b4920d9b754a97c80041225f8d86f46f57886ec93ba109e432454d6a")
}

///|
test "hex both ways" {
  assert_eq(@hash.hex_encode(b""), "")
  assert_eq(@hash.hex_encode(b"\x00\x0f\xa5\xff"), "000fa5ff")
  assert_eq(@hash.hex_decode("000fa5ff"), Some(b"\x00\x0f\xa5\xff"))
  assert_eq(@hash.hex_decode("000FA5Ff"), Some(b"\x00\x0f\xa5\xff"))
  assert_eq(@hash.hex_decode(""), Some(b""))
  assert_eq(@hash.hex_decode("abc"), None)
  assert_eq(@hash.hex_decode("zz"), None)
  assert_eq(@hash.hex_decode("0g"), None)
  assert_eq(@hash.hex_decode("é0"), None)
  let all = Bytes::makei(256, i => i.to_byte())
  assert_eq(@hash.hex_decode(@hash.hex_encode(all)), Some(all))
}
