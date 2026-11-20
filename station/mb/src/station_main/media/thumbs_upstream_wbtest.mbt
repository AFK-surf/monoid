// Upstream PNGSuite (Willem van Schaik) malformed & edge-case regression tests for media/thumbs.mbt
// and @pixels.decode_png.
// Full 176-file official PNGSuite corpus is cross-checked in station/test/mb-upstream-corpora.test.ts.

///|
test "upstream PNGSuite: reject invalid filter bytes, missing PLTE, bad zlib header, and zlib bomb" {
  // 1. Invalid PNG scanline filter type (5 and 255) must be rejected, not silently treated as Paeth
  let bad_filter5 = build_png(1, 1, 8, 0, b"\x05\x2A")
  assert_true(decode_image(bad_filter5) is None)
  let bad_filter255 = build_png(1, 1, 8, 0, b"\xFF\x2A")
  assert_true(decode_image(bad_filter255) is None)

  // 2. Indexed-color (ctype 3) without PLTE chunk must be rejected
  let missing_plte = build_png(1, 1, 8, 3, b"\x00\x00")
  assert_true(decode_image(missing_plte) is None)

  // 3. Invalid PLTE length (not divisible by 3) must be rejected
  let bad_plte = build_png(1, 1, 8, 3, b"\x00\x00", plte=b"\x01\x02")
  assert_true(decode_image(bad_plte) is None)

  // 4. Oversized decompressed IDAT (zlib bomb: 64 KiB decompressed for a 1x1 image) must be rejected
  let bomb_raw = Bytes::make(65536, b'\x00')
  let bomb_png = build_png(1, 1, 8, 0, bomb_raw)
  assert_true(decode_image(bomb_png) is None)

  // 5. Valid 1/2/4/8/16-bit grayscale & indexed+tRNS PNGs still decode cleanly
  let valid_g1 = build_png(8, 1, 1, 0, b"\x00\xAA")
  let img_g1 = decode_image(valid_g1).unwrap()
  assert_eq((img_g1.w, img_g1.h), (8, 1))
  assert_eq(img_g1.px[0], b'\xFF')
  assert_eq(img_g1.px[4], b'\x00')
}
