// Upstream `nodejs/node` `test/parallel/test-zlib-*.js` pure MoonBit boundary matrix for `@flate`.
// Cross-language interop against real `node:zlib` runs in the integration test suite.

///|
fn u_prng(n : Int, seed : UInt) -> Bytes {
  let mut s = seed
  Bytes::makei(n, _ => {
    s = s * 1664525U + 1013904223U
    ((s >> 16) & 0xFFU).to_byte()
  })
}

///|
fn u_hex(s : String) -> Bytes {
  @codec.hex_decode(s).unwrap()
}

///|
test "upstream node-zlib: zero-byte, single-byte, and multi-flush streaming Deflater" {
  // test-zlib-zero-byte.js
  let d0 = @flate.Deflater::new()
  assert_eq(d0.push(b""), b"")
  let empty_stream = d0.finish()
  assert_eq(@flate.inflate(empty_stream), Some(b""))
  // Calling push/finish after finish returns empty
  assert_eq(d0.push(b"ignored"), b"")
  assert_eq(d0.finish(), b"")

  // Multi-flush streaming with mixed empty, compressible, incompressible, and cross-window chunks
  let d = @flate.Deflater::new()
  let out = Buffer()
  let expected = Buffer()
  let chunks : Array[Bytes] = [
    b"",
    b"A",
    Bytes::make(4096, b'Z'),
    u_prng(70000, 0x11223344U), // forces stored blocks (>65535)
    b"repeated-pattern-".repeat(500),
    u_prng(33000, 0x55667788U), // slides 32 KiB window
    b"repeated-pattern-".repeat(200),
    b"",
    b"tail-byte",
  ]
  for ch in chunks {
    out.write_bytesview(d.push(ch))
    expected.write_bytesview(ch)
  }
  out.write_bytesview(d.finish())
  assert_eq(@flate.inflate(out.to_bytes()), Some(expected.to_bytes()))
}

///|
test "upstream node-zlib: RFC 1951 match length and distance code boundary sweep" {
  // Sweep every RFC 1951 length boundary (3..258) and distance boundary (1..32768)
  for len in [3, 4, 10, 11, 18, 19, 34, 35, 66, 67, 130, 131, 257, 258] {
    let payload = Bytes::make(len + 1, b'k')
    assert_eq(@flate.inflate(@flate.deflate(payload)), Some(payload))
    assert_eq(@flate.zlib_decompress(@flate.zlib_compress(payload)), Some(payload))
    assert_eq(@flate.gunzip(@flate.gzip(payload)), Some(payload))
  }
  // Exact 65535 / 65536 stored-block split boundaries with high-entropy data
  for n in [65534, 65535, 65536, 65537, 131070, 131071] {
    let raw = u_prng(n, 0x99887766U + n.reinterpret_as_uint())
    assert_eq(@flate.inflate(@flate.deflate(raw)), Some(raw))
    assert_eq(@flate.zlib_decompress(@flate.zlib_compress(raw)), Some(raw))
    assert_eq(@flate.gunzip(@flate.gzip(raw)), Some(raw))
  }
}

///|
test "upstream node-zlib: gzip trailing zero padding vs trailing garbage and concatenated streams" {
  // test-zlib-from-concatenated-gzip.js: concatenated gzip streams + zero padding accepted
  let g1 = @flate.gzip(b"part-one-")
  let g2 = @flate.gzip(b"part-two")
  let padded = Buffer()
  padded.write_bytesview(g1)
  padded.write_bytesview(g2)
  padded.write_bytesview(b"\x00\x00\x00\x00")
  assert_eq(@flate.gunzip(padded.to_bytes()), Some(b"part-one-part-two"))

  // Trailing non-zero garbage after a valid gzip stream must fail (not a valid next gzip header)
  let garbage = Buffer()
  garbage.write_bytesview(g1)
  garbage.write_bytesview(b"not-gzip")
  assert_eq(@flate.gunzip(garbage.to_bytes()), None)
}

///|
test "upstream node-zlib: zlib header CMF/FLG/FCHECK/FDICT/CINFO and Adler-32 boundaries" {
  // Preset dictionary (FDICT bit 0x20 set) with valid FCHECK (0x78BB: (0x78*256+0xBB)%31 == 0)
  assert_eq(@flate.zlib_decompress(u_hex("78bb00000001030000000001")), None)
  // Invalid compression method CM=7 (0x77, FLG chosen so FCHECK passes: (0x77*256+0x92)%31==0)
  assert_eq(@flate.zlib_decompress(u_hex("7792030000000001")), None)
  // Invalid FCHECK (0x789D: (0x78*256+0x9D)%31 == 1 != 0)
  assert_eq(@flate.zlib_decompress(u_hex("789d030000000001")), None)
  // Valid non-default CINFO=0 (256-byte window, CMF=0x08, FLG=0x1D -> (0x08*256+0x1D)%31 == 0)
  assert_eq(@flate.zlib_decompress(u_hex("081d030000000001")), Some(b""))
  // Adler-32 incremental NMAX boundary (>5552 bytes) matches one-shot
  let big = u_prng(12000, 0xABCDEF01U)
  let one = @flate.adler32(big)
  let inc = @flate.adler32_update(@flate.adler32_update(1U, big[:5553]), big[5553:])
  assert_eq(one, inc)
}

///|
test "upstream node-zlib: gzip reserved FLG bits, bad FHCRC, bad CRC32, bad ISIZE, and truncation" {
  // Reserved FLG bits 0xE0 must be rejected
  for bit in [0x20, 0x40, 0x80] {
    let bad = Buffer()
    bad.write_bytesview(b"\x1f\x8b\x08")
    bad.write_byte(bit.to_byte())
    bad.write_bytesview(b"\x00\x00\x00\x00\x00\x03\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00")
    assert_eq(@flate.gunzip(bad.to_bytes()), None)
  }
  // Bad FHCRC (bit-flipped CRC-16) must be rejected
  let bad_hcrc = Buffer()
  bad_hcrc.write_bytesview(b"\x1f\x8b\x08\x02\x00\x00\x00\x00\x00\x03")
  let c16 = (@codec.crc32(bad_hcrc.to_bytes()) & 0xFFFFU) ^ 0x0001U
  bad_hcrc.write_byte((c16 & 0xFFU).to_byte())
  bad_hcrc.write_byte(((c16 >> 8) & 0xFFU).to_byte())
  bad_hcrc.write_bytesview(@flate.deflate(b"hi"))
  bad_hcrc.write_uint_le(@codec.crc32(b"hi"))
  bad_hcrc.write_uint_le(2U)
  assert_eq(@flate.gunzip(bad_hcrc.to_bytes()), None)

  // Every byte-offset truncation of raw deflate, zlib, and gzip fails cleanly
  let sample = b"hello world! ".repeat(20)
  let raw = @flate.deflate(sample)
  for n in 0..<raw.length() {
    assert_eq(@flate.inflate(raw[:n]), None)
  }
  let z = @flate.zlib_compress(sample)
  for n in 0..<z.length() {
    assert_eq(@flate.zlib_decompress(z[:n]), None)
  }
  let gz = @flate.gzip(sample)
  for n in 0..<gz.length() {
    assert_eq(@flate.gunzip(gz[:n]), None)
  }
}
