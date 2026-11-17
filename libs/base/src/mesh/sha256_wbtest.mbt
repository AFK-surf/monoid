// SHA-256 against FIPS 180-4's vectors and digests at the padding's edges (55, 56 and 64 bytes: one block, two
// blocks, a block whole), on both targets.

///|
test "sha256 gives FIPS 180-4's digests, at the padding's edges too" {
  let cases : Array[(Bytes, String)] = [
    (b"", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
    (b"abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
    (Bytes::make(55, b'a'), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"),
    (Bytes::make(56, b'a'), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"),
    (Bytes::make(64, b'a'), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"),
    (
      b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
    ),
    (
      b"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
      "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
    ),
    (Bytes::make(1000, b'a'), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"),
  ]
  for one in cases {
    assert_eq(hex_of(sha256(one.0)), one.1)
  }
}

///|
/// `bytes` in lowercase hex.
fn hex_of(bytes : Bytes) -> String {
  let digits = "0123456789abcdef"
  let out = StringBuilder()
  for b in bytes {
    out.write_char(digits.get_char(b.to_int() / 16).unwrap())
    out.write_char(digits.get_char(b.to_int() % 16).unwrap())
  }
  out.to_string()
}
