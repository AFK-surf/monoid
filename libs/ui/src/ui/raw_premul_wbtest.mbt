// White-box tests for MBRAWPRE encoding, bounded SVG parsed-tree cache, redraw pixels_forget, and FakeHost decoding.

///|
fn make_raw_premul_bytes(w : Int, h : Int, fill : (Byte, Byte, Byte, Byte)) -> Bytes {
  let px = FixedArray::make(w * h * 4, b'\x00')
  for i in 0..<(w * h) {
    px[i * 4] = fill.0
    px[i * 4 + 1] = fill.1
    px[i * 4 + 2] = fill.2
    px[i * 4 + 3] = fill.3
  }
  raw_premul_of(w, h, px).unwrap()
}

///|
fn make_malformed_raw_premul(w : Int, h : Int, payload_len : Int) -> Bytes {
  let out = FixedArray::make(16 + payload_len, b'\x00')
  out[0] = b'M'
  out[1] = b'B'
  out[2] = b'R'
  out[3] = b'A'
  out[4] = b'W'
  out[5] = b'P'
  out[6] = b'R'
  out[7] = b'E'
  out[8] = (w & 0xFF).to_byte()
  out[9] = ((w >> 8) & 0xFF).to_byte()
  out[10] = ((w >> 16) & 0xFF).to_byte()
  out[11] = ((w >> 24) & 0xFF).to_byte()
  out[12] = (h & 0xFF).to_byte()
  out[13] = ((h >> 8) & 0xFF).to_byte()
  out[14] = ((h >> 16) & 0xFF).to_byte()
  out[15] = ((h >> 24) & 0xFF).to_byte()
  Bytes::from_array(out[:])
}

///|
test "raw_premul_of encodes header and payload and rejects invalid dimensions or short buffers" {
  let px = FixedArray::from_array([
    b'\x80', b'\x40', b'\x20', b'\x80',
    b'\x10', b'\x20', b'\x30', b'\xFF',
  ])
  guard raw_premul_of(2, 1, px) is Some(b) else { fail("expected valid MBRAWPRE") }
  assert_eq(b.length(), 16 + 8)
  assert_true(is_raw_premul(b))
  assert_eq(parse_raw_premul(b), Some((2, 1)))
  assert_eq(b[16], b'\x80')
  assert_eq(b[17], b'\x40')
  assert_eq(b[18], b'\x20')
  assert_eq(b[19], b'\x80')
  assert_eq(b[20], b'\x10')
  assert_eq(b[23], b'\xFF')
  // Reject invalid dims and short buffers
  assert_true(raw_premul_of(0, 1, px) is None)
  assert_true(raw_premul_of(1, 0, px) is None)
  assert_true(raw_premul_of(-2, 1, px) is None)
  assert_true(raw_premul_of(16385, 1, FixedArray::make(16385 * 4, b'\x00')) is None)
  assert_true(raw_premul_of(2, 2, px) is None)
}

///|
test "set_vector_pictures_parsed caches parsed trees up to 4 entries, skips >512KB, and invalidates cleanly" {
  let parse_calls : Ref[Int] = Ref(0)
  let draw_calls : Array[Int] = []
  set_vector_pictures_parsed(fn(data) {
    ignore(data)
    parse_calls.val += 1
    Some(fn(px) {
      draw_calls.push(px)
      Some((2, 1, FixedArray::from_array([
        b'\x80', b'\x00', b'\x00', b'\x80',
        b'\x00', b'\x40', b'\x80', b'\x80',
      ])))
    })
  })
  let t = Tester::new(fn(_) { () }, w=200.0, h=200.0)
  let svg1 = b"<svg xmlns='http://www.w3.org/2000/svg' width='2' height='1'/>"
  // Bucket upgrade 256 -> 512 hits parsed cache (parse called once, draw called twice)
  let b256 = host_bytes("mem:s1", svg1, 256)
  let b512 = host_bytes("mem:s1", svg1, 512)
  assert_true(is_raw_premul(b256))
  assert_true(is_raw_premul(b512))
  assert_eq(parse_calls.val, 1)
  assert_eq(draw_calls, [256, 512])

  // Eviction past 4 entries: insert s2, s3, s4, touch s1, insert s5 -> s2 evicted, s1 kept
  let svg2 = b"<svg xmlns='http://www.w3.org/2000/svg' width='2' height='1' id='2'/>"
  let svg3 = b"<svg xmlns='http://www.w3.org/2000/svg' width='2' height='1' id='3'/>"
  let svg4 = b"<svg xmlns='http://www.w3.org/2000/svg' width='2' height='1' id='4'/>"
  let svg5 = b"<svg xmlns='http://www.w3.org/2000/svg' width='2' height='1' id='5'/>"
  ignore(host_bytes("mem:s2", svg2, 64))
  ignore(host_bytes("mem:s3", svg3, 64))
  ignore(host_bytes("mem:s4", svg4, 64))
  assert_eq(parse_calls.val, 4)
  // Touch s1 so s2 becomes LRU
  ignore(host_bytes("mem:s1", svg1, 64))
  assert_eq(parse_calls.val, 4)
  // Insert s5 -> evicts s2
  ignore(host_bytes("mem:s5", svg5, 64))
  assert_eq(parse_calls.val, 5)
  assert_eq(vector_parsed_cache.length(), 4)
  assert_false(vector_parsed_cache.contains("mem:s2"))
  assert_true(vector_parsed_cache.contains("mem:s1"))

  // Admission cap > 512 KB: never cached
  let big_arr = FixedArray::make(512 * 1024 + 32, b' ')
  big_arr[0] = b'<'
  big_arr[1] = b's'
  big_arr[2] = b'v'
  big_arr[3] = b'g'
  big_arr[4] = b'>'
  let big_svg = Bytes::from_array(big_arr[:])
  ignore(host_bytes("mem:big", big_svg, 64))
  ignore(host_bytes("mem:big", big_svg, 128))
  assert_false(vector_parsed_cache.contains("mem:big"))
  assert_eq(parse_calls.val, 7)

  // Invalidation via forget_image, image_cache_renew, and redraw_vector_pictures
  forget_image("mem:s1")
  assert_false(vector_parsed_cache.contains("mem:s1"))
  image_cache_renew("mem:s3")
  assert_false(vector_parsed_cache.contains("mem:s3"))
  redraw_vector_pictures()
  assert_eq(vector_parsed_cache.length(), 0)
  assert_eq(vector_parsed_order.length(), 0)

  t.draw()
  set_vector_pictures(fn(_, _) { None })
}

///|
test "redraw_vector_pictures clears cached image_pixels so same-bucket readback reflects redrawn SVG" {
  let color_phase : Ref[Int] = Ref(0)
  set_vector_pictures_parsed(fn(_) {
    let phase = color_phase.val
    Some(fn(_) {
      let r = if phase == 0 { b'\xCC' } else { b'\x11' }
      let g = if phase == 0 { b'\x00' } else { b'\xDD' }
      Some((2, 1, FixedArray::from_array([r, g, b'\x00', b'\xFF', r, g, b'\x00', b'\xFF'])))
    })
  })
  let svg = b"<svg xmlns='http://www.w3.org/2000/svg' width='2' height='1'/>"
  let t = Tester::new(
    fn(c) { c.image("mem:svg_px", w=Px(32.0), h=Px(16.0), fade=false) |> ignore },
    w=100.0,
    h=100.0,
  )
  let decode_tick = 50.0
  add_image("mem:svg_px", svg)
  t.draw()
  t.run_for(decode_tick)
  match pixels_for("mem:svg_px", 64, g().frame_no, g().clock) {
    PixelsRead(w, h, px) => {
      assert_eq((w, h), (2, 1))
      assert_eq((px[0], px[1], px[2], px[3]), (b'\xCC', b'\x00', b'\x00', b'\xFF'))
    }
    _ => fail("expected initial PixelsRead")
  }
  // Simulate late CJK font arrival: phase changes and redraw_vector_pictures() runs
  color_phase.val = 1
  redraw_vector_pictures()
  t.run_for(decode_tick)
  match pixels_for("mem:svg_px", 64, g().frame_no, g().clock) {
    PixelsRead(w, h, px) => {
      assert_eq((w, h), (2, 1))
      assert_eq((px[0], px[1], px[2], px[3]), (b'\x11', b'\xDD', b'\x00', b'\xFF'))
    }
    _ => fail("expected updated PixelsRead after redraw_vector_pictures")
  }
  set_vector_pictures(fn(_, _) { None })
}

///|
test "FakeHost decodes valid and downscaled MBRAWPRE, cleans pixels_of on free, and rejects malformed vectors" {
  let t = Tester::new(fn(_) { () }, w=100.0, h=100.0)
  t.draw()
  guard fake.val is Some(f) else { fail("no FakeHost") }
  // 1. Valid unscaled MBRAWPRE with asymmetric premultiplied pixels
  let valid = make_raw_premul_bytes(4, 2, (b'\x64', b'\x32', b'\x10', b'\x80'))
  let id1 = f.image_load_bytes(valid, 64)
  let info = FixedArray::make(4, 0.0)
  // State starts at 0 (decoding), ready on next frame
  assert_eq(f.image_info(id1, info), 0)
  f.images[id1].state = 1
  assert_eq(f.image_info(id1, info), 1)
  assert_eq((info[0], info[1], info[2], info[3]), (4.0, 2.0, 4.0, 2.0))
  let out1 = FixedArray::make(4 * 2 * 4, b'\x00')
  assert_true(f.image_pixels(id1, out1))
  assert_eq((out1[0], out1[1], out1[2], out1[3]), (b'\x64', b'\x32', b'\x10', b'\x80'))
  f.image_free(id1)
  assert_false(f.pixels_of.contains(id1))

  // 2. Valid downscaled MBRAWPRE (8x4 with max_px=4 -> 4x2, ow=8, oh=4)
  let big = make_raw_premul_bytes(8, 4, (b'\x40', b'\x20', b'\x10', b'\x80'))
  let id2 = f.image_load_bytes(big, 4)
  f.images[id2].state = 1
  assert_eq(f.image_info(id2, info), 1)
  assert_eq((info[0], info[1], info[2], info[3]), (4.0, 2.0, 8.0, 4.0))
  let out2 = FixedArray::make(4 * 2 * 4, b'\x00')
  assert_true(f.image_pixels(id2, out2))
  assert_eq((out2[0], out2[1], out2[2], out2[3]), (b'\x40', b'\x20', b'\x10', b'\x80'))
  f.image_free(id2)
  assert_false(f.pixels_of.contains(id2))

  // 3. Does not record text_lacks even when a text_table is active
  let prev_table = text_table.val
  let tbl : TextTable = {
    metrics: Map([]),
    shapes: Map([]),
    keys: Map([]),
    glyphs: Map([]),
    missing: [],
    answers: Map([]),
  }
  text_table.val = Some(tbl)
  let id_tt = f.image_load_bytes(valid, 64)
  assert_eq(tbl.missing.length(), 0)
  f.image_free(id_tt)
  text_table.val = prev_table

  // 4. All malformed MBRAWPRE vectors fail immediately with state == -1
  let malformed : Array[Bytes] = [
    b"MBRAWPRE\x01\x00\x00", // truncated header (11 bytes)
    make_malformed_raw_premul(2, 2, 12), // truncated pixel payload (needs 16)
    make_malformed_raw_premul(0, 2, 0), // 0 width
    make_malformed_raw_premul(2, 0, 0), // 0 height
    make_malformed_raw_premul(16385, 1, 0), // > 16384
    make_malformed_raw_premul(65536, 65536, 0), // uint32 overflow (65536*65536*4 wraps to 0)
    make_malformed_raw_premul(1, 1, 5), // trailing byte (needs 4, has 5)
  ]
  for bad in malformed {
    let bid = f.image_load_bytes(bad, 64)
    assert_eq(f.image_info(bid, info), -1)
    f.image_free(bid)
  }
}
