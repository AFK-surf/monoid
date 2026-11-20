// Raw deflate undone (base/flate's). SHA-256 is base/hash's.

///|
/// The bytes `data` deflated (raw: no zlib or gzip head) from `start`, made whole; `size`: how many they are said to
/// be, a hint. None where it is damaged or ends early.
fn inflate(data : Bytes, start? : Int = 0, size? : Int = 0) -> Bytes? {
  @flate.inflate_at(data, start, size~).map(r => r.0)
}

///|
/// The SHA-256 of `data`, as 64 lowercase hex digits.
fn sha256_hex(data : Bytes) -> String {
  @hash.sha256_hex(data)
}
