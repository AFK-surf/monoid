///|
fn make_solid(w : Int, h : Int, r : Int, g : Int, b : Int, a : Int) -> @png.Picture {
  let buf = FixedArray::make(w * h * 4, b'\x00')
  for i in 0..<(w * h) {
    buf[i * 4] = r.to_byte()
    buf[i * 4 + 1] = g.to_byte()
    buf[i * 4 + 2] = b.to_byte()
    buf[i * 4 + 3] = a.to_byte()
  }
  @png.Picture::new(w, h, Bytes::from_array(buf[:]))
}

///|
fn rd_be32(d : Bytes, i : Int) -> Int {
  (d[i].to_int() << 24) |
  (d[i + 1].to_int() << 16) |
  (d[i + 2].to_int() << 8) |
  d[i + 3].to_int()
}

///|
fn rd_le16(d : Bytes, i : Int) -> Int {
  d[i].to_int() | (d[i + 1].to_int() << 8)
}

///|
fn rd_le32(d : Bytes, i : Int) -> Int {
  d[i].to_int() |
  (d[i + 1].to_int() << 8) |
  (d[i + 2].to_int() << 16) |
  (d[i + 3].to_int() << 24)
}

///|
test "encode_png and decode_png roundtrip exact pixels" {
  let w = 13
  let h = 9
  let buf = FixedArray::make(w * h * 4, b'\x00')
  for y in 0..<h {
    for x in 0..<w {
      let idx = (y * w + x) * 4
      buf[idx] = ((x * 19 + y * 7) & 255).to_byte()
      buf[idx + 1] = ((x * 5 + y * 23) & 255).to_byte()
      buf[idx + 2] = ((x * 11 + y * 13 + 42) & 255).to_byte()
      buf[idx + 3] = (if (x + y) % 3 == 0 { 128 } else { 255 }).to_byte()
    }
  }
  let orig = @png.Picture::new(w, h, Bytes::from_array(buf[:]))
  let bytes = @png.encode_png(orig)
  assert_eq(bytes[0:8].to_owned(), b"\x89PNG\r\n\x1a\n")
  let decoded = match @png.decode_png(bytes) {
    Ok(p) => p
    Err(e) => fail("decode failed: \{e}")
  }
  assert_eq(decoded.w, w)
  assert_eq(decoded.h, h)
  assert_eq(decoded.bpp, 4)
  for y in 0..<h {
    for x in 0..<w {
      assert_eq(decoded.rgba(x, y), orig.rgba(x, y))
    }
  }
}

///|
test "encode_png multi-block stored zlib (>65535 raw bytes)" {
  // 140 * (1 + 140 * 4) = 78540 bytes > 65535 -> spans 2 stored deflate blocks
  let pic = make_solid(140, 140, 12, 34, 56, 200)
  let bytes = @png.encode_png(pic)
  let decoded = match @png.decode_png(bytes) {
    Ok(p) => p
    Err(e) => fail("decode multi-block failed: \{e}")
  }
  assert_eq(decoded.w, 140)
  assert_eq(decoded.h, 140)
  assert_eq(decoded.rgba(0, 0), (12, 34, 56, 200))
  assert_eq(decoded.rgba(139, 139), (12, 34, 56, 200))
}

///|
test "resize downsampling and upsampling preserve solid color and average halves" {
  let solid = make_solid(64, 64, 80, 160, 240, 255)
  let down = solid.resize(16, 16)
  assert_eq(down.w, 16)
  assert_eq(down.h, 16)
  assert_eq(down.rgba(0, 0), (80, 160, 240, 255))
  assert_eq(down.rgba(15, 15), (80, 160, 240, 255))

  let up = down.resize(48, 32)
  assert_eq(up.w, 48)
  assert_eq(up.h, 32)
  assert_eq(up.rgba(0, 0), (80, 160, 240, 255))
  assert_eq(up.rgba(47, 31), (80, 160, 240, 255))

  // 4x4 left half red (200,0,0,255), right half blue (0,0,200,255) -> 1x1 averages to (100,0,100,255)
  let buf = FixedArray::make(4 * 4 * 4, b'\x00')
  for y in 0..<4 {
    for x in 0..<4 {
      let i = (y * 4 + x) * 4
      if x < 2 {
        buf[i] = b'\xc8'
        buf[i + 3] = b'\xff'
      } else {
        buf[i + 2] = b'\xc8'
        buf[i + 3] = b'\xff'
      }
    }
  }
  let split = @png.Picture::new(4, 4, Bytes::from_array(buf[:]))
  let avg = split.resize(1, 1)
  assert_eq(avg.rgba(0, 0), (100, 0, 100, 255))

  // Empty boundary
  let empty = solid.resize(0, 16)
  assert_eq(empty.w, 0)
  assert_eq(empty.h, 0)
}

///|
test "encode_ico header, directory entries, offsets and embedded PNGs" {
  let base = make_solid(64, 64, 220, 90, 40, 255)
  let sizes = [base.resize(16, 16), base.resize(32, 32), base.resize(256, 256)]
  let ico = @png.encode_ico(sizes)
  // ICONDIR
  assert_eq(rd_le16(ico, 0), 0)
  assert_eq(rd_le16(ico, 2), 1)
  assert_eq(rd_le16(ico, 4), 3)
  let expected_dims = [16, 32, 0] // 256 encoded as 0 in ICO directory
  let mut prev_end = 6 + 3 * 16
  for i in 0..<3 {
    let entry = 6 + i * 16
    assert_eq(ico[entry].to_int(), expected_dims[i])
    assert_eq(ico[entry + 1].to_int(), expected_dims[i])
    assert_eq(rd_le16(ico, entry + 4), 1)
    assert_eq(rd_le16(ico, entry + 6), 32)
    let len = rd_le32(ico, entry + 8)
    let off = rd_le32(ico, entry + 12)
    assert_eq(off, prev_end)
    assert_true(off + len <= ico.length())
    let payload = ico[off:off + len].to_owned()
    assert_eq(payload[0:8].to_owned(), b"\x89PNG\r\n\x1a\n")
    let decoded = match @png.decode_png(payload) {
      Ok(p) => p
      Err(e) => fail("ico entry \{i} png decode failed: \{e}")
    }
    let want = if i == 0 { 16 } else if i == 1 { 32 } else { 256 }
    assert_eq(decoded.w, want)
    assert_eq(decoded.h, want)
    assert_eq(decoded.rgba(0, 0), (220, 90, 40, 255))
    prev_end = off + len
  }
  assert_eq(prev_end, ico.length())
}

///|
test "encode_icns header, OSTypes and embedded PNG chunks" {
  let base = make_solid(32, 32, 30, 120, 210, 255)
  let icns = @png.encode_icns(base)
  assert_eq(icns[0:4].to_owned(), b"icns")
  let total_len = rd_be32(icns, 4)
  assert_eq(total_len, icns.length())
  let expected : Array[(Bytes, Int)] = [
    (b"icp4", 16),
    (b"icp5", 32),
    (b"icp6", 64),
    (b"ic07", 128),
    (b"ic08", 256),
    (b"ic09", 512),
    (b"ic10", 1024),
    (b"ic11", 32),
    (b"ic12", 64),
    (b"ic13", 256),
    (b"ic14", 512),
  ]
  let mut off = 8
  for item in expected {
    let tag = icns[off:off + 4].to_owned()
    let chunk_len = rd_be32(icns, off + 4)
    assert_eq(tag, item.0)
    assert_true(chunk_len > 8)
    let payload = icns[off + 8:off + chunk_len].to_owned()
    assert_eq(payload[0:8].to_owned(), b"\x89PNG\r\n\x1a\n")
    // Verify IHDR width/height directly
    assert_eq(rd_be32(payload, 16), item.1)
    assert_eq(rd_be32(payload, 20), item.1)
    off += chunk_len
  }
  assert_eq(off, icns.length())
}
