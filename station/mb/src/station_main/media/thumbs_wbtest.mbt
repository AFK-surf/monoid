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

