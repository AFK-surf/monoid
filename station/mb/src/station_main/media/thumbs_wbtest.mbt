///|
/// A picture of `w`×`h`: a gradient, with stripes (so that it is no flat colour), clear on its left where `clear`.
fn test_picture(w : Int, h : Int, clear? : Bool = false) -> FixedArray[Byte] {
  let px = FixedArray::make(w * h * 4, b'\x00')
  for y = 0; y < h; y = y + 1 {
    for x = 0; x < w; x = x + 1 {
      let i = (y * w + x) * 4
      px[i] = (x * 255 / w).to_byte()
      px[i + 1] = (y * 255 / h).to_byte()
      px[i + 2] = (if (x / 7 + y / 5) % 2 == 0 { 200 } else { 30 }).to_byte()
      px[i + 3] = if clear && x < w / 3 { b'\x40' } else { b'\xFF' }
    }
  }
  px
}

///|
/// A JPEG with an EXIF block saying orientation `o`, put right after its start.
fn with_orientation(jpeg : Bytes, o : Int) -> Bytes {
  let tiff : Array[Int] = [
    0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, // big-endian, IFD0 at 8
     0x00, 0x01, // one entry
     0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, o, 0x00, 0x00, // Orientation, SHORT, 1
     0x00, 0x00, 0x00, 0x00, // no next IFD
  ]
  let body = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00] + tiff
  let len = body.length() + 2
  let out = @buffer.Buffer()
  out.write_byte(b'\xFF')
  out.write_byte(b'\xD8')
  out.write_byte(b'\xFF')
  out.write_byte(b'\xE1')
  out.write_byte((len >> 8).to_byte())
  out.write_byte((len & 255).to_byte())
  for b in body {
    out.write_byte(b.to_byte())
  }
  out.write_bytes(jpeg[2:].to_owned())
  out.to_bytes()
}

///|
test "EXIF's orientation read and applied: a photo turned as its camera says" {
  let jpeg = @pixels.jpeg(40, 20, test_picture(40, 20))
  assert_eq(exif_orientation(jpeg), 1)
  for o in 1..=8 {
    let turned = with_orientation(jpeg, o)
    assert_eq(exif_orientation(turned), o)
    let img = decode_image(turned).unwrap()
    if o >= 5 {
      assert_eq((img.w, img.h), (20, 40))
    } else {
      assert_eq((img.w, img.h), (40, 20))
    }
  }
  // (each turn takes a pixel where it should: the top-left corner of the source)
  let src : Image = { w: 3, h: 2, px: FixedArray::makei(24, i => (i / 4).to_byte()) }
  let corner = (img : Image, x : Int, y : Int) => img.px[(y * img.w + x) * 4].to_int()
  assert_eq(corner(oriented(src, 2), 2, 0), 0)
  assert_eq(corner(oriented(src, 3), 2, 1), 0)
  assert_eq(corner(oriented(src, 4), 0, 1), 0)
  assert_eq(corner(oriented(src, 5), 0, 0), 0)
  assert_eq(corner(oriented(src, 6), 1, 0), 0)
  assert_eq(corner(oriented(src, 7), 1, 2), 0)
  assert_eq(corner(oriented(src, 8), 0, 2), 0)
}

///|
test "sizes fitted as image's resize_dimensions fits them" {
  assert_eq(fit_within(1440, 1200, 720, 600), (720, 600))
  assert_eq(fit_within(3000, 1000, 720, 600), (720, 240))
  assert_eq(fit_within(1000, 3000, 720, 600), (200, 600))
  assert_eq(fit_within(5000, 1, 100, 100), (100, 1))
}

///|
test "a compressed PNG reads back as it was, and is smaller than one stored" {
  let img : Image = { w: 90, h: 70, px: test_picture(90, 70, clear=true) }
  let made = png_compressed(img)
  let (w, h, px) = @pixels.decode_png(made).unwrap()
  assert_eq((w, h), (90, 70))
  assert_true(px == img.px)
  assert_true(made.length() < @pixels.png(90, 70, img.px).length())
}

///|
test "a ThumbHash as evanw's: its picture of the same proportions and colour" {
  let w = 100
  let h = 50
  let px = FixedArray::make(w * h * 4, b'\xFF')
  for i = 0; i < w * h; i = i + 1 {
    px[i * 4] = b'\xE0'
    px[i * 4 + 1] = b'\x20'
    px[i * 4 + 2] = b'\x20'
  }
  let hash = rgba_to_thumb_hash(w, h, px)
  let ratio = @pixels.thumbhash_ratio(hash).unwrap()
  // (the ratio its header says is of its luminance's cells: 7 by 4 here)
  assert_true((ratio - 1.75).abs() < 0.01)
  let (tw, th, back) = @pixels.thumbhash(hash).unwrap()
  assert_true(tw > th)
  let mid = (th / 2 * tw + tw / 2) * 4
  assert_true(back[mid].to_int() > 180 && back[mid + 1].to_int() < 80 && back[mid + 2].to_int() < 80)
  // one with clear parts says so (its header's alpha bit)
  let clear = test_picture(60, 60, clear=true)
  let hashed = rgba_to_thumb_hash(60, 60, clear)
  assert_true((hashed[2].to_int() & 0x80) != 0)
}

///|
/// Builds a valid PNG chunk (length, type, body, CRC32).
fn png_chunk(kind : String, body : Bytes) -> Bytes {
  let out = @buffer.Buffer()
  let n = body.length()
  for s in [24, 16, 8, 0] {
    out.write_byte(((n >> s) & 255).to_byte())
  }
  let typed = @buffer.Buffer()
  for i = 0; i < 4; i = i + 1 {
    typed.write_byte(kind[i].to_int().to_byte())
  }
  typed.write_bytes(body)
  let all = typed.to_bytes()
  out.write_bytes(all)
  let crc = @zip.crc32(all).reinterpret_as_int()
  for s in [24, 16, 8, 0] {
    out.write_byte(((crc >> s) & 255).to_byte())
  }
  out.to_bytes()
}

///|
/// Builds a PNG with explicit IHDR fields, optional PLTE/tRNS, and raw scanlines (already containing filter bytes).
fn build_png(
  w : Int,
  h : Int,
  depth : Int,
  ctype : Int,
  raw_scanlines : Bytes,
  plte? : Bytes = b"",
  trns? : Bytes = b"",
) -> Bytes {
  let out = @buffer.Buffer()
  for b in [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
    out.write_byte(b.to_byte())
  }
  let ihdr = @buffer.Buffer()
  for v in [w, h] {
    for s in [24, 16, 8, 0] {
      ihdr.write_byte(((v >> s) & 255).to_byte())
    }
  }
  for b in [depth, ctype, 0, 0, 0] {
    ihdr.write_byte(b.to_byte())
  }
  out.write_bytes(png_chunk("IHDR", ihdr.to_bytes()))
  if plte.length() > 0 {
    out.write_bytes(png_chunk("PLTE", plte))
  }
  if trns.length() > 0 {
    out.write_bytes(png_chunk("tRNS", trns))
  }
  out.write_bytes(png_chunk("IDAT", @flate.zlib_compress(raw_scanlines)))
  out.write_bytes(png_chunk("IEND", b""))
  out.to_bytes()
}

///|
/// Encodes raw pixel bytes (`stride` bytes/row, `bpp` bytes/pixel) with a fixed PNG row filter `f` (0..4).
fn encode_rows_with_filter(w : Int, h : Int, bpp : Int, pixels : FixedArray[Byte], f : Int) -> Bytes {
  let stride = w * bpp
  let out = FixedArray::make((stride + 1) * h, b'\x00')
  for y = 0; y < h; y = y + 1 {
    let row_off = y * (stride + 1)
    out[row_off] = f.to_byte()
    for x = 0; x < stride; x = x + 1 {
      let cur = pixels[y * stride + x].to_int()
      let left = if x >= bpp { pixels[y * stride + x - bpp].to_int() } else { 0 }
      let up = if y > 0 { pixels[(y - 1) * stride + x].to_int() } else { 0 }
      let ul = if y > 0 && x >= bpp { pixels[(y - 1) * stride + x - bpp].to_int() } else { 0 }
      out[row_off + 1 + x] = filtered_byte(f, cur, left, up, ul).to_byte()
    }
  }
  Bytes::from_array(out)
}

///|
test "PNG conformance: color types (Grayscale, RGB, Palette+tRNS, GrayAlpha, RGBA)" {
  // 1. Grayscale (ctype 0, 8-bit): 2x2
  let gray_px : FixedArray[Byte] = [b'\x00', b'\x55', b'\xAA', b'\xFF']
  let gray_png = build_png(2, 2, 8, 0, encode_rows_with_filter(2, 2, 1, gray_px, 0))
  let g_img = decode_image(gray_png).unwrap()
  assert_eq((g_img.w, g_img.h), (2, 2))
  for i = 0; i < 4; i = i + 1 {
    assert_eq(g_img.px[i * 4], gray_px[i])
    assert_eq(g_img.px[i * 4 + 1], gray_px[i])
    assert_eq(g_img.px[i * 4 + 2], gray_px[i])
    assert_eq(g_img.px[i * 4 + 3], b'\xFF')
  }

  // 2. RGB (ctype 2, 8-bit): 2x2
  let rgb_px : FixedArray[Byte] = [
    b'\xFF', b'\x00', b'\x00', b'\x00', b'\xFF', b'\x00',
    b'\x00', b'\x00', b'\xFF', b'\x12', b'\x34', b'\x56',
  ]
  let rgb_png = build_png(2, 2, 8, 2, encode_rows_with_filter(2, 2, 3, rgb_px, 0))
  let rgb_img = decode_image(rgb_png).unwrap()
  assert_eq((rgb_img.w, rgb_img.h), (2, 2))
  assert_eq((rgb_img.px[0], rgb_img.px[1], rgb_img.px[2], rgb_img.px[3]), (b'\xFF', b'\x00', b'\x00', b'\xFF'))
  assert_eq((rgb_img.px[12], rgb_img.px[13], rgb_img.px[14], rgb_img.px[15]), (b'\x12', b'\x34', b'\x56', b'\xFF'))

  // 3. Indexed/Palette (ctype 3, 8-bit) with PLTE + tRNS: 2x1
  let plte = b"\xC8\x0A\x14\x05\x64\xFA"
  let trns = b"\x80\xFF"
  let idx_px : FixedArray[Byte] = [b'\x00', b'\x01']
  let pal_png = build_png(2, 1, 8, 3, encode_rows_with_filter(2, 1, 1, idx_px, 0), plte~, trns~)
  let pal_img = decode_image(pal_png).unwrap()
  assert_eq((pal_img.w, pal_img.h), (2, 1))
  assert_eq((pal_img.px[0], pal_img.px[1], pal_img.px[2], pal_img.px[3]), (b'\xC8', b'\x0A', b'\x14', b'\x80'))
  assert_eq((pal_img.px[4], pal_img.px[5], pal_img.px[6], pal_img.px[7]), (b'\x05', b'\x64', b'\xFA', b'\xFF'))

  // 4. Grayscale+Alpha (ctype 4, 8-bit): 2x1
  let ga_px : FixedArray[Byte] = [b'\x40', b'\x80', b'\xC0', b'\xFF']
  let ga_png = build_png(2, 1, 8, 4, encode_rows_with_filter(2, 1, 2, ga_px, 0))
  let ga_img = decode_image(ga_png).unwrap()
  assert_eq((ga_img.px[0], ga_img.px[1], ga_img.px[2], ga_img.px[3]), (b'\x40', b'\x40', b'\x40', b'\x80'))
  assert_eq((ga_img.px[4], ga_img.px[5], ga_img.px[6], ga_img.px[7]), (b'\xC0', b'\xC0', b'\xC0', b'\xFF'))

  // 5. RGBA (ctype 6, 8-bit): 8x6 with transparency
  let rgba_px = test_picture(8, 6, clear=true)
  let rgba_png = build_png(8, 6, 8, 6, encode_rows_with_filter(8, 6, 4, rgba_px, 0))
  let rgba_img = decode_image(rgba_png).unwrap()
  assert_eq((rgba_img.w, rgba_img.h), (8, 6))
  assert_true(rgba_img.px == rgba_px)
}

///|
test "PNG conformance: all 5 row filters (None, Sub, Up, Average, Paeth) round-trip identically" {
  let w = 17
  let h = 13
  let px = test_picture(w, h, clear=true)
  for f in 0..=4 {
    let png = build_png(w, h, 8, 6, encode_rows_with_filter(w, h, 4, px, f))
    let img = decode_image(png).unwrap()
    assert_eq((img.w, img.h), (w, h))
    assert_true(img.px == px)
  }
}

///|
test "thumbnail resizing: oversized opaque -> JPEG, oversized transparent -> PNG, aspect preserved" {
  // Opaque 1000x500 -> resized to 720x360 JPEG
  let opaque_img : Image = { w: 1000, h: 500, px: test_picture(1000, 500, clear=false) }
  let (ext_j, mime_j, bytes_j) = made_small(opaque_img, 10_000_000.0).unwrap()
  assert_eq(ext_j, "jpg")
  assert_eq(mime_j, "image/jpeg")
  let decoded_j = decode_image(bytes_j).unwrap()
  assert_eq((decoded_j.w, decoded_j.h), (720, 360))

  // Transparent 900x900 -> resized to 600x600 PNG
  let clear_img : Image = { w: 900, h: 900, px: test_picture(900, 900, clear=true) }
  let (ext_p, mime_p, bytes_p) = made_small(clear_img, 10_000_000.0).unwrap()
  assert_eq(ext_p, "png")
  assert_eq(mime_p, "image/png")
  let decoded_p = decode_image(bytes_p).unwrap()
  assert_eq((decoded_p.w, decoded_p.h), (600, 600))
}

///|
/// A JPEG with a little-endian ("II") EXIF block saying orientation `o`.
fn with_orientation_le(jpeg : Bytes, o : Int) -> Bytes {
  let tiff : Array[Int] = [
    0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, // little-endian, IFD0 at 8
    0x01, 0x00, // one entry
    0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, o, 0x00, 0x00, 0x00, // Orientation, SHORT, 1
    0x00, 0x00, 0x00, 0x00, // no next IFD
  ]
  let body = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00] + tiff
  let len = body.length() + 2
  let out = @buffer.Buffer()
  out.write_byte(b'\xFF')
  out.write_byte(b'\xD8')
  out.write_byte(b'\xFF')
  out.write_byte(b'\xE1')
  out.write_byte((len >> 8).to_byte())
  out.write_byte((len & 255).to_byte())
  for b in body {
    out.write_byte(b.to_byte())
  }
  out.write_bytes(jpeg[2:].to_owned())
  out.to_bytes()
}

///|
test "JPEG + EXIF conformance: little-endian and big-endian orientations 1..8" {
  let jpeg = @pixels.jpeg(32, 16, test_picture(32, 16))
  for o in 1..=8 {
    let le = with_orientation_le(jpeg, o)
    assert_eq(exif_orientation(le), o)
    let img = decode_image(le).unwrap()
    if o >= 5 {
      assert_eq((img.w, img.h), (16, 32))
    } else {
      assert_eq((img.w, img.h), (32, 16))
    }
  }
}

///|
test "malformed PNG/JPEG corpus: truncated, bad chunk, bad CRC, illegal dimensions/depth return None without panic or OOM" {
  let valid_png = png_compressed({ w: 8, h: 8, px: test_picture(8, 8) })
  // Truncated PNGs at various prefixes
  for cut in [0, 1, 4, 8, 12, 16, 25, 33, valid_png.length() / 2, valid_png.length() - 1] {
    assert_true(decode_image(valid_png[0:cut].to_owned()) is None)
  }

  // Bad CRC on IHDR (flip 1 bit in IHDR CRC byte at offset 8 + 4 + 4 + 13 = 29)
  let bad_ihdr_crc = FixedArray::makei(valid_png.length(), i => if i == 29 { (valid_png[i].to_int() ^ 0x01).to_byte() } else { valid_png[i] })
  assert_true(decode_image(Bytes::from_array(bad_ihdr_crc)) is None)

  // Bad CRC on IDAT (flip 1 bit right before IEND chunk, which is last 12 bytes)
  let idat_crc_pos = valid_png.length() - 13
  let bad_idat_crc = FixedArray::makei(valid_png.length(), i => if i == idat_crc_pos { (valid_png[i].to_int() ^ 0x80).to_byte() } else { valid_png[i] })
  assert_true(decode_image(Bytes::from_array(bad_idat_crc)) is None)

  // Bad chunk length (exceeds buffer / negative)
  let bad_len = b"\x89PNG\r\n\x1a\n\x7f\xff\xff\xffIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00"
  assert_true(decode_image(bad_len) is None)
  let neg_len = b"\x89PNG\r\n\x1a\n\xff\xff\xff\xffIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00"
  assert_true(decode_image(neg_len) is None)

  // Illegal PNG dimensions: 0x10, 10x0, 65535x65535 (int overflow / OOM bomb!)
  assert_true(decode_image(build_png(0, 10, 8, 6, b"\x00")) is None)
  assert_true(decode_image(build_png(10, 0, 8, 6, b"\x00")) is None)
  assert_true(decode_image(build_png(65535, 65535, 8, 6, b"\x00\x00\x00\x00\x00")) is None)

  // Illegal PNG bit depths (0 -> division by zero in 8/depth, 3, 32 -> per=0 div by zero)
  assert_true(decode_image(build_png(2, 2, 0, 0, b"\x00\x00\x00\x00\x00\x00")) is None)
  assert_true(decode_image(build_png(2, 2, 3, 0, b"\x00\x00\x00\x00\x00\x00")) is None)
  assert_true(decode_image(build_png(2, 2, 32, 0, b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00")) is None)

  // Illegal PNG color type
  assert_true(decode_image(build_png(2, 2, 8, 7, b"\x00\x00\x00\x00\x00\x00")) is None)

  // Truncated and malformed JPEGs
  let valid_jpg = @pixels.jpeg(16, 16, test_picture(16, 16))
  for cut in [0, 1, 2, 3, 4, 10, 20, valid_jpg.length() / 4, valid_jpg.length() / 2] {
    assert_true(decode_image(valid_jpg[0:cut].to_owned()) is None)
  }
  // JPEG with 0x0 dimensions in SOF0
  let zero_jpg = b"\xff\xd8\xff\xc0\x00\x0b\x08\x00\x00\x00\x10\x01\x01\x11\x00\xff\xd9"
  assert_true(decode_image(zero_jpg) is None)
  // JPEG with 65535x65535 dimensions in SOF0 (OOM bomb!)
  let bomb_jpg = b"\xff\xd8\xff\xc0\x00\x0b\x08\xff\xff\xff\xff\x01\x01\x11\x00\xff\xd9"
  assert_true(decode_image(bomb_jpg) is None)
  // Random garbage bytes
  assert_true(decode_image(b"not an image at all") is None)
  assert_true(decode_image(b"\xff\xd8\xff\xe1\x00\x04\x00\x00") is None)
}


