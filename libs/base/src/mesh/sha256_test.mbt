// SHA-256 as a program on this library calls it.

///|
test "sha256 is a program's own to call: FIPS 180-4's digest of abc" {
  let digest = @mesh.sha256(b"abc")
  assert_eq(digest.length(), 32)
  assert_true(
    digest ==
    b"\xba\x78\x16\xbf\x8f\x01\xcf\xea\x41\x41\x40\xde\x5d\xae\x22\x23\xb0\x03\x61\xa3\x96\x17\x7a\x9c\xb4\x10\xff\x61\xf2\x00\x15\xad",
  )
}
