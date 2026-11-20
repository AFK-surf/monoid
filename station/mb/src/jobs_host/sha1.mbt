// SHA-1, for what names a file's contents as Git does (dirsync.ts `blobId`) and a WebSocket's handshake: base/hash's.

///|
/// SHA-1 of `data`, its 20 bytes.
pub fn sha1(data : BytesView) -> Bytes {
  @hash.sha1(data)
}

///|
pub fn sha1_hex(data : BytesView) -> String {
  @hash.sha1_hex(data)
}

test "sha1" {
  inspect(sha1_hex(b"abc"), content="a9993e364706816aba3e25717850c26c9cd0d89d")
  inspect(sha1_hex(b""), content="da39a3ee5e6b4b0d3255bfef95601890afd80709")
}
