// RFC 1950 (zlib), RFC 1951 (DEFLATE), and RFC 1952 (gzip) conformance tests for @flate.

///|
fn c_hex(s : String) -> Bytes {
  @codec.hex_decode(s).unwrap()
}

///|
fn prng_bytes(n : Int, seed : UInt) -> Bytes {
  let mut s = seed
  Bytes::makei(n, _ => {
    s = s * 1664525U + 1013904223U
    ((s >> 16) & 0xFFU).to_byte()
  })
}

///|
test "conformance: empty, 1-byte, all-zero RLE/max-match, and high-entropy stored blocks" {
  // Empty
  assert_eq(@flate.inflate(@flate.deflate(b"")), Some(b""))
  assert_eq(@flate.zlib_decompress(@flate.zlib_compress(b"")), Some(b""))
  assert_eq(@flate.gunzip(@flate.gzip(b"")), Some(b""))
  // Every single 1-byte value 0x00..0xFF
  for b in 0..<256 {
    let one = Bytes::make(1, b.to_byte())
    assert_eq(@flate.inflate(@flate.deflate(one)), Some(one))
    assert_eq(@flate.zlib_decompress(@flate.zlib_compress(one)), Some(one))
    assert_eq(@flate.gunzip(@flate.gzip(one)), Some(one))
  }
  // All-zero large block (triggers RLE distance=1 max match length=258)
  let zeros = Bytes::make(131072, b'\x00')
  let z_def = @flate.deflate(zeros)
  assert_true(z_def.length() < 2000)
  assert_eq(@flate.inflate(z_def), Some(zeros))
  assert_eq(@flate.zlib_decompress(@flate.zlib_compress(zeros)), Some(zeros))
  assert_eq(@flate.gunzip(@flate.gzip(zeros)), Some(zeros))
  // High-entropy incompressible data spanning >2 stored blocks (65535 * 2 + 17)
  let rand_big = prng_bytes(131087, 0xCAFEBABEU)
  let r_def = @flate.deflate(rand_big)
  // Stored blocks overhead: 3 blocks * 5 bytes = 15 bytes (+1 bit-align)
  assert_true(r_def.length() <= rand_big.length() + 20)
  assert_eq(@flate.inflate(r_def), Some(rand_big))
  assert_eq(@flate.zlib_decompress(@flate.zlib_compress(rand_big)), Some(rand_big))
  assert_eq(@flate.gunzip(@flate.gzip(rand_big)), Some(rand_big))
}

///|
test "conformance: exact 32 KiB sliding window boundary backreferences (32767, 32768, 32769)" {
  // Place a 64-byte marker at offset 0, fill with incompressible noise up to dist, repeat marker.
  // At dist=32767 and dist=32768 the marker is still inside the 32 KiB window; at 32769 it is outside.
  let marker = Bytes::makei(64, i => (0x41 + i % 26).to_byte())
  for dist in [32767, 32768, 32769] {
    let buf = Buffer()
    buf.write_bytesview(marker)
    buf.write_bytesview(prng_bytes(dist - 64, 0x13579BDFU + dist.reinterpret_as_uint()))
    buf.write_bytesview(marker)
    let data = buf.to_bytes()
    assert_eq(@flate.inflate(@flate.deflate(data)), Some(data))
    // Also via streaming Deflater split across the window boundary
    let d = @flate.Deflater::new()
    let out = Buffer()
    out.write_bytesview(d.push(data[0:16384]))
    out.write_bytesview(d.push(data[16384:dist]))
    out.write_bytesview(d.push(data[dist:]))
    out.write_bytesview(d.finish())
    assert_eq(@flate.inflate(out.to_bytes()), Some(data))
  }
}

///|
test "conformance: gzip header flags combinations (FTEXT, FEXTRA, FNAME, FCOMMENT, FHCRC) and concatenated streams" {
  // Build a custom gzip header with chosen flags around a valid deflate payload
  let make_gzip = (payload : Bytes, flg : Int, extra : Bytes, name : Bytes, comment : Bytes, hcrc : Bool) => {
    let hdr = Buffer()
    hdr.write_bytesview(b"\x1f\x8b\x08")
    hdr.write_byte(flg.to_byte())
    hdr.write_bytesview(b"\x00\x00\x00\x00\x00\x03")
    if (flg & 0x04) != 0 {
      hdr.write_byte((extra.length() & 0xFF).to_byte())
      hdr.write_byte(((extra.length() >> 8) & 0xFF).to_byte())
      hdr.write_bytesview(extra)
    }
    if (flg & 0x08) != 0 {
      hdr.write_bytesview(name)
      hdr.write_byte(b'\x00')
    }
    if (flg & 0x10) != 0 {
      hdr.write_bytesview(comment)
      hdr.write_byte(b'\x00')
    }
    if hcrc {
      let c16 = @codec.crc32(hdr.to_bytes()) & 0xFFFFU
      hdr.write_byte((c16 & 0xFFU).to_byte())
      hdr.write_byte(((c16 >> 8) & 0xFFU).to_byte())
    }
    hdr.write_bytesview(@flate.deflate(payload))
    hdr.write_uint_le(@codec.crc32(payload))
    hdr.write_uint_le(payload.length().reinterpret_as_uint())
    hdr.to_bytes()
  }
  // FTEXT alone (0x01)
  assert_eq(@flate.gunzip(make_gzip(b"text", 0x01, b"", b"", b"", false)), Some(b"text"))
  // FEXTRA alone (0x04)
  assert_eq(@flate.gunzip(make_gzip(b"extra", 0x04, b"AB\x02\x00xy", b"", b"", false)), Some(b"extra"))
  // FNAME alone (0x08)
  assert_eq(@flate.gunzip(make_gzip(b"name", 0x08, b"", b"file.txt", b"", false)), Some(b"name"))
  // FCOMMENT alone (0x10)
  assert_eq(@flate.gunzip(make_gzip(b"cmt", 0x10, b"", b"", b"a comment", false)), Some(b"cmt"))
  // FHCRC alone (0x02)
  assert_eq(@flate.gunzip(make_gzip(b"hcrc", 0x02, b"", b"", b"", true)), Some(b"hcrc"))
  // All 5 flags combined (0x1F)
  let all5 = make_gzip(b"all five flags", 0x1F, b"\x01\x02\x03", b"a.bin", b"hello", true)
  assert_eq(@flate.gunzip(all5), Some(b"all five flags"))
  // Concatenated 3 gzip streams (including an empty middle one)
  let g1 = @flate.gzip(b"first-")
  let g2 = @flate.gzip(b"")
  let g3 = make_gzip(b"third", 0x1E, b"ex", b"n", b"c", true)
  let cat = Buffer()
  cat.write_bytesview(g1)
  cat.write_bytesview(g2)
  cat.write_bytesview(g3)
  assert_eq(@flate.gunzip(cat.to_bytes()), Some(b"first-third"))
}

///|
/// Minimal LSB-first bit packer for constructing exact RFC 1951 malformed deflate test vectors.
priv struct BitPack {
  out : Buffer
  mut acc : Int
  mut n : Int
}

///|
fn BitPack::new() -> BitPack {
  { out: Buffer(), acc: 0, n: 0 }
}

///|
fn BitPack::put(self : BitPack, val : Int, bits : Int) -> Unit {
  self.acc = self.acc | (val << self.n)
  self.n += bits
  while self.n >= 8 {
    self.out.write_byte((self.acc & 0xFF).to_byte())
    self.acc = self.acc >> 8
    self.n -= 8
  }
}

///|
fn BitPack::put_huff(self : BitPack, code : Int, bits : Int) -> Unit {
  let mut rev = 0
  for i in 0..<bits {
    rev = (rev << 1) | ((code >> i) & 1)
  }
  self.put(rev, bits)
}

///|
fn BitPack::finish(self : BitPack) -> Bytes {
  if self.n > 0 {
    self.out.write_byte((self.acc & 0xFF).to_byte())
    self.acc = 0
    self.n = 0
  }
  self.out.to_bytes()
}

///|
test "conformance: malformed and adversarial deflate/zlib/gzip streams return None without panic" {
  // 1. Out-of-range length symbols 286 and 287 in fixed Huffman block (RFC 1951 §3.2.6)
  for sym in [286, 287] {
    let bp = BitPack::new()
    bp.put(1, 1) // BFINAL=1
    bp.put(1, 2) // BTYPE=fixed
    bp.put_huff(0xC0 + (sym - 280), 8) // invalid length symbol 286 or 287
    bp.put_huff(0, 7) // EOB
    assert_eq(@flate.inflate(bp.finish()), None)
  }
  // 2. Out-of-range distance codes 30 and 31 in fixed Huffman block
  for dist_code in [30, 31] {
    let bp = BitPack::new()
    bp.put(1, 1) // BFINAL=1
    bp.put(1, 2) // BTYPE=fixed
    bp.put_huff(0x30 + 0x61, 8) // literal 'a'
    bp.put_huff(1, 7) // length=3 (sym 257)
    bp.put_huff(dist_code, 5) // invalid distance code 30 or 31
    bp.put_huff(0, 7) // EOB
    assert_eq(@flate.inflate(bp.finish()), None)
  }
  // 3. Distance exceeding current output length (1 literal then dist=2)
  {
    let bp = BitPack::new()
    bp.put(1, 1)
    bp.put(1, 2)
    bp.put_huff(0x30 + 0x61, 8) // literal 'a'
    bp.put_huff(1, 7) // length=3 (sym 257)
    bp.put_huff(1, 5) // dist code 1 => distance 2 > out.len(1)
    bp.put_huff(0, 7)
    assert_eq(@flate.inflate(bp.finish()), None)
  }
  // 4. Dynamic block with HLIT > 286 (nlen = 257 + 30 = 287)
  {
    let bp = BitPack::new()
    bp.put(1, 1)
    bp.put(2, 2)
    bp.put(30, 5) // HLIT=30 -> 287 > 286
    bp.put(0, 5)
    bp.put(0, 4)
    assert_eq(@flate.inflate(bp.finish()), None)
  }
  // 5. Dynamic block with HDIST > 30 (ndist = 1 + 30 = 31)
  {
    let bp = BitPack::new()
    bp.put(1, 1)
    bp.put(2, 2)
    bp.put(0, 5)
    bp.put(30, 5) // HDIST=30 -> 31 > 30
    bp.put(0, 4)
    assert_eq(@flate.inflate(bp.finish()), None)
  }
  // 6. Dynamic block with code 16 (repeat previous) at index 0
  {
    let bp = BitPack::new()
    bp.put(1, 1)
    bp.put(2, 2)
    bp.put(0, 5) // HLIT=257
    bp.put(0, 5) // HDIST=1
    bp.put(0, 4) // HCLEN=4 (clen_order: 16, 17, 18, 0)
    bp.put(1, 3) // clen[16]=1
    bp.put(0, 3)
    bp.put(0, 3)
    bp.put(0, 3)
    bp.put(0, 8) // decode sym 16 at i=0
    assert_eq(@flate.inflate(bp.finish()), None)
  }
  // 7. Dynamic block with missing EOB (symbol 256 has length 0)
  {
    let bp = BitPack::new()
    bp.put(1, 1)
    bp.put(2, 2)
    bp.put(0, 5) // HLIT=257
    bp.put(0, 5) // HDIST=1
    bp.put(0, 4) // HCLEN=4 (16, 17, 18, 0)
    bp.put(0, 3) // clen[16]=0
    bp.put(0, 3) // clen[17]=0
    bp.put(1, 3) // clen[18]=1 (code 0 => repeat 0 for 11..138)
    bp.put(0, 3) // clen[0]=0
    bp.put(0, 1)
    bp.put(127, 7) // 138 zeros
    bp.put(0, 1)
    bp.put(109, 7) // 120 zeros -> total 258 zeros, lens[256] == 0
    assert_eq(@flate.inflate(bp.finish()), None)
  }
  // 8. Truncated stored block header and body
  assert_eq(@flate.inflate(c_hex("01")), None)
  assert_eq(@flate.inflate(c_hex("010500")), None)
  assert_eq(@flate.inflate(c_hex("010500faff")), None)
  assert_eq(@flate.inflate(c_hex("010500faff616263")), None)
  // 9. Zlib bad CMF/FLG, bad CINFO (>7), bad FCHECK, truncated trailer
  assert_eq(@flate.zlib_decompress(c_hex("78")), None)
  assert_eq(@flate.zlib_decompress(c_hex("8899030000000001")), None) // CINFO=8 (>7)
  assert_eq(@flate.zlib_decompress(c_hex("789c0300000000")), None) // 3-byte trailer
  assert_eq(@flate.zlib_decompress(c_hex("789c030000000002")), None) // wrong adler32 (should be 1)
  // 10. Gzip truncated FEXTRA, truncated FCOMMENT, truncated FHCRC, wrong ISIZE, wrong CRC32
  assert_eq(@flate.gunzip(c_hex("1f8b0804000000000003")), None) // FEXTRA without XLEN
  assert_eq(@flate.gunzip(c_hex("1f8b0804000000000003ff004142")), None) // FEXTRA XLEN=255 > remaining
  assert_eq(@flate.gunzip(c_hex("1f8b0810000000000003616263")), None) // FCOMMENT without NUL
  assert_eq(@flate.gunzip(c_hex("1f8b080200000000000300")), None) // FHCRC 1 byte
  assert_eq(@flate.gunzip(c_hex("1f8b080000000000000303000000000001000000")), None) // empty payload but ISIZE=1
  assert_eq(@flate.gunzip(c_hex("1f8b080000000000000303000100000000000000")), None) // empty payload but CRC32=1
  // 11. Truncating a valid gzip at every single byte offset must return None
  let valid_gz = @flate.gzip(b"the quick brown fox")
  for n in 0..<valid_gz.length() {
    assert_eq(@flate.gunzip(valid_gz[:n]), None)
  }
  let valid_z = @flate.zlib_compress(b"the quick brown fox")
  for n in 0..<valid_z.length() {
    assert_eq(@flate.zlib_decompress(valid_z[:n]), None)
  }
}
