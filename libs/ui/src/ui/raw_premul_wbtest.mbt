// White-box tests for MBRAWPRE encoding, bounded SVG parsed-tree cache, redraw pixels_forget,
// context-recovery refresh, tree_image_pixels refresh, and FakeHost decoding / outside-wait hygiene.

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
  let b256 = host_bytes("mem:s1", svg1, 256)
  let b512 = host_bytes("mem:s1", svg1, 512)
  assert_true(is_raw_premul(b256))
  assert_true(is_raw_premul(b512))
  assert_eq(parse_calls.val, 1)
  assert_eq(draw_calls, [256, 512])

  let svg2 = b"<svg xmlns='http://www.w3.org/2000/svg' width='2' height='1' id='2'/>"
  let svg3 = b"<svg xmlns='http://www.w3.org/2000/svg' width='2' height='1' id='3'/>"
  let svg4 = b"<svg xmlns='http://www.w3.org/2000/svg' width='2' height='1' id='4'/>"
  let svg5 = b"<svg xmlns='http://www.w3.org/2000/svg' width='2' height='1' id='5'/>"
  ignore(host_bytes("mem:s2", svg2, 64))
  ignore(host_bytes("mem:s3", svg3, 64))
  ignore(host_bytes("mem:s4", svg4, 64))
  assert_eq(parse_calls.val, 4)
  ignore(host_bytes("mem:s1", svg1, 64))
  assert_eq(parse_calls.val, 4)
  ignore(host_bytes("mem:s5", svg5, 64))
  assert_eq(parse_calls.val, 5)
  assert_eq(vector_parsed_cache.length(), 4)
  assert_false(vector_parsed_cache.contains("mem:s2"))
  assert_true(vector_parsed_cache.contains("mem:s1"))

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
test "redraw_vector_pictures clears cached pixels even for evicted textures and refreshes mounted tree_image_pixels" {
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
  let t = Tester::new(fn(_) { () }, w=100.0, h=100.0)
  let handle : Ref[(() -> ImagePixels?)?] = Ref(None)
  set_view_app(fn(root) {
    root.box(fn(v) { handle.val = Some(tree_image_pixels(v, "mem:svg_tree", 64)) }) |> ignore
  })
  let decode_tick = 50.0
  add_image("mem:svg_tree", svg)
  add_image("mem:svg_evicted", svg)
  t.draw()
  t.run_for(decode_tick)
  let read = handle.val.unwrap()
  match read() {
    Some(PixelsRead(w, h, px)) => {
      assert_eq((w, h), (2, 1))
      assert_eq((px[0], px[1], px[2], px[3]), (b'\xCC', b'\x00', b'\x00', b'\xFF'))
    }
    _ => fail("expected initial tree_image_pixels PixelsRead")
  }
  // Populate pixels_read for mem:svg_evicted, then evict its texture from image_cache
  ignore(pixels_for("mem:svg_evicted", 64, g().frame_no, g().clock))
  t.run_for(decode_tick)
  match pixels_for("mem:svg_evicted", 64, g().frame_no, g().clock) {
    PixelsRead(_, _, px) => assert_eq(px[0], b'\xCC')
    _ => fail("expected initial evicted PixelsRead")
  }
  match image_cache.get("mem:svg_evicted") {
    Some(list) => {
      for e in list {
        h_image_free(e.id)
        image_dropped(e)
      }
      image_cache.remove("mem:svg_evicted")
    }
    None => ()
  }
  assert_true(pixels_read.contains("64 mem:svg_evicted"))

  // Late font arrives: redraw_vector_pictures() must clear evicted pixels_read AND refresh mounted tree_image_pixels
  color_phase.val = 1
  redraw_vector_pictures()
  assert_false(pixels_read.contains("64 mem:svg_evicted"))
  t.run_for(decode_tick)
  match read() {
    Some(PixelsRead(w, h, px)) => {
      assert_eq((w, h), (2, 1))
      assert_eq((px[0], px[1], px[2], px[3]), (b'\x11', b'\xDD', b'\x00', b'\xFF'))
    }
    _ => fail("expected mounted tree_image_pixels to refresh after redraw_vector_pictures")
  }
  set_vector_pictures(fn(_, _) { None })
}

///|
test "context recovery updates already-ready ImageEntry dimensions, image_bytes, and multiple tree_image_pixels subscribers" {
  let t = Tester::new(fn(_) { () }, w=100.0, h=100.0)
  let h1 : Ref[(() -> ImagePixels?)?] = Ref(None)
  let h2 : Ref[(() -> ImagePixels?)?] = Ref(None)
  set_view_app(fn(root) {
    root.box(fn(v1) { h1.val = Some(tree_image_pixels(v1, "mem:ctx_rec", 64)) }) |> ignore
    root.box(fn(v2) { h2.val = Some(tree_image_pixels(v2, "mem:ctx_rec", 64)) }) |> ignore
  })
  let decode_tick = 50.0
  add_image("mem:ctx_rec", make_raw_premul_bytes(8, 4, (b'\x64', b'\x32', b'\x10', b'\x80')))
  t.draw()
  t.run_for(decode_tick)
  let read1 = h1.val.unwrap()
  let read2 = h2.val.unwrap()
  guard image_cache.get("mem:ctx_rec") is Some(list) && list.length() == 1 else {
    fail("expected single image entry")
  }
  let e = list[0]
  assert_eq((e.state, e.w, e.h), (1, 8.0, 4.0))
  assert_eq(image_bytes.val, 8.0 * 4.0 * 4.0)
  for r in [read1(), read2()] {
    match r {
      Some(PixelsRead(w, h, px)) => {
        assert_eq((w, h), (8, 4))
        assert_eq(px[0], b'\x64')
      }
      _ => fail("expected initial 8x4 PixelsRead on both subscribers")
    }
  }

  // 1. Simulate GL context loss + recovery with a smaller texture cap (4x2) and new pixel data
  guard fake.val is Some(f) else { fail("no FakeHost") }
  let shrunk = FixedArray::make(4 * 2 * 4, b'\x00')
  for i in 0..<(4 * 2) {
    shrunk[i * 4] = b'\x20'
    shrunk[i * 4 + 1] = b'\x40'
    shrunk[i * 4 + 2] = b'\x60'
    shrunk[i * 4 + 3] = b'\x80'
  }
  f.images[e.id] = { ..f.images[e.id], w: 4, h: 2 }
  f.pixels_of[e.id] = shrunk
  image_decoded(e.id, g().clock)
  t.draw()
  assert_eq((e.state, e.w, e.h), (1, 4.0, 2.0))
  assert_eq(image_bytes.val, 4.0 * 2.0 * 4.0)
  for r in [read1(), read2()] {
    match r {
      Some(PixelsRead(w, h, px)) => {
        assert_eq((w, h), (4, 2))
        assert_eq((px[0], px[1], px[2], px[3]), (b'\x20', b'\x40', b'\x60', b'\x80'))
      }
      _ => fail("expected 4x2 PixelsRead on BOTH subscribers after context recovery")
    }
  }

  // 2. Simulate transient st == 0 notification while ready: preserves image_bytes and ready state
  f.images[e.id].state = 0
  image_decoded(e.id, g().clock)
  assert_eq((e.state, e.w, e.h), (1, 4.0, 2.0))
  assert_eq(image_bytes.val, 4.0 * 2.0 * 4.0)

  // 3. Simulate GL context recovery failure (state == -1): both subscribers update to PixelsFailed
  f.images[e.id].state = -1
  image_decoded(e.id, g().clock)
  t.draw()
  assert_eq((e.state, e.w, e.h), (-1, 0.0, 0.0))
  assert_eq(image_bytes.val, 0.0)
  assert_true(read1() is Some(PixelsFailed))
  assert_true(read2() is Some(PixelsFailed))
  assert_true(pixels_for("mem:ctx_rec", 64, g().frame_no, g().clock) is PixelsFailed)
}

///|
test "FakeHost public path decodes valid and downscaled MBRAWPRE and fails malformed vectors with zero leaked outside waits" {
  let cur_src : Ref[String] = Ref("mem:ok")
  let t = Tester::new(
    fn(c) { c.image(cur_src.val, w=Px(32.0), h=Px(16.0), fade=false) |> ignore },
    w=100.0,
    h=100.0,
  )
  let decode_tick = 50.0
  // 1. Valid unscaled MBRAWPRE through public add_image + draw + run_for
  add_image("mem:ok", make_raw_premul_bytes(4, 2, (b'\x64', b'\x32', b'\x10', b'\x80')))
  t.draw()
  t.run_for(decode_tick)
  assert_eq(t.pending().length(), 0)
  assert_eq(t.failed_images().length(), 0)
  match pixels_for("mem:ok", 64, g().frame_no, g().clock) {
    PixelsRead(w, h, px) => {
      assert_eq((w, h), (4, 2))
      assert_eq((px[0], px[1], px[2], px[3]), (b'\x64', b'\x32', b'\x10', b'\x80'))
    }
    _ => fail("expected valid MBRAWPRE PixelsRead")
  }

  // 2. Valid downscaled MBRAWPRE (80x4 = 1296 bytes <= 4096 FakeHost bar; requested at 64px bucket -> 64x3, ow=80, oh=4)
  cur_src.val = "mem:big"
  add_image("mem:big", make_raw_premul_bytes(80, 4, (b'\x40', b'\x20', b'\x10', b'\x80')))
  t.draw()
  t.run_for(decode_tick)
  assert_eq(t.pending().length(), 0)
  assert_eq(t.failed_images().length(), 0)
  match pixels_for("mem:big", 64, g().frame_no, g().clock) {
    PixelsRead(w, h, px) => {
      assert_eq((w, h), (64, 3))
      assert_eq((px[0], px[1], px[2], px[3]), (b'\x40', b'\x20', b'\x10', b'\x80'))
    }
    _ => fail("expected downscaled MBRAWPRE PixelsRead")
  }

  // 3. Does not record text_lacks even when a text_table is active
  guard fake.val is Some(f) else { fail("no FakeHost") }
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
  let id_tt = f.image_load_bytes(make_raw_premul_bytes(2, 1, (b'\x10', b'\x20', b'\x30', b'\x40')), 64)
  assert_eq(tbl.missing.length(), 0)
  f.image_free(id_tt)
  assert_false(f.pixels_of.contains(id_tt))
  text_table.val = prev_table

  // 4. All 7 malformed MBRAWPRE vectors through public path (auto_finish):
  //    each finishes strictly once with ok=false (state == -1), failed_images contains id,
  //    pending() == 0, and awaited() == 0 (zero leaked outside wait tickets).
  let malformed : Array[Bytes] = [
    b"MBRAWPRE\x01\x00\x00",
    make_malformed_raw_premul(2, 2, 12),
    make_malformed_raw_premul(0, 2, 0),
    make_malformed_raw_premul(2, 0, 0),
    make_malformed_raw_premul(16385, 1, 0),
    make_malformed_raw_premul(65536, 65536, 0),
    make_malformed_raw_premul(1, 1, 5),
  ]
  for i in 0..<malformed.length() {
    let key = "mem:bad_\{i}"
    cur_src.val = key
    add_image(key, malformed[i])
    t.draw()
    t.run_for(decode_tick)
    guard image_cache.get(key) is Some(list) && list.length() == 1 else {
      fail("expected cache entry after draw for malformed vector \{i}")
    }
    let id = list[0].id
    let fin_count = t.finished_order().filter(fn(p) { p == (1, id) }).length()
    assert_eq(fin_count, 1, msg="expected exactly 1 finish notification for malformed vector \{i}")
    assert_eq(list[0].state, -1, msg="expected state == -1 for malformed vector \{i}")
    assert_true(t.failed_images().contains(id), msg="expected failed_images to contain \{id} for vector \{i}")
    assert_eq(t.pending().length(), 0, msg="expected empty pending for malformed vector \{i}")
    assert_eq(t.awaited().length(), 0, msg="leaked outside wait in awaited() for malformed vector \{i}")
  }

  // 5. Explicit manual finish (finish=false): malformed MBRAWPRE starts pending, then finish_all() fails it once and clears awaited().
  let t2 = Tester::new(
    fn(c) { c.image("mem:bad_manual", w=Px(32.0), h=Px(16.0), fade=false) |> ignore },
    w=100.0,
    h=100.0,
    finish=false,
  )
  add_image("mem:bad_manual", malformed[0])
  t2.draw()
  guard image_cache.get("mem:bad_manual") is Some(mlist) && mlist.length() == 1 else {
    fail("expected cache entry for manual malformed vector")
  }
  let mid = mlist[0].id
  assert_true(t2.pending().contains((1, mid)), msg="expected pending (1, \{mid}) before finish_all")
  assert_true(t2.awaited().length() > 0, msg="expected outside wait before finish_all")
  t2.finish_all()
  t2.draw()
  assert_eq(t2.finished_order().filter(fn(p) { p == (1, mid) }).length(), 1)
  assert_eq(mlist[0].state, -1)
  assert_true(t2.failed_images().contains(mid))
  assert_eq(t2.pending().length(), 0)
  assert_eq(t2.awaited().length(), 0)

  // 6. Explicit single-id finish(1, id) with default ok=true (called twice):
  //    Tester::finish enforces fail_images so malformed MBRAWPRE finishes strictly once as -1 and clears awaited().
  let t3 = Tester::new(
    fn(c) { c.image("mem:bad_single", w=Px(32.0), h=Px(16.0), fade=false) |> ignore },
    w=100.0,
    h=100.0,
    finish=false,
  )
  add_image("mem:bad_single", malformed[1])
  t3.draw()
  guard image_cache.get("mem:bad_single") is Some(slist) && slist.length() == 1 else {
    fail("expected cache entry for single-id manual malformed vector")
  }
  let sid = slist[0].id
  assert_true(t3.pending().contains((1, sid)), msg="expected pending (1, \{sid}) before finish(1, id)")
  assert_true(t3.awaited().length() > 0, msg="expected outside wait before finish(1, id)")
  t3.finish(1, sid)
  t3.finish(1, sid)
  t3.draw()
  assert_eq(t3.finished_order().filter(fn(p) { p == (1, sid) }).length(), 1)
  assert_eq(slist[0].state, -1)
  assert_true(t3.failed_images().contains(sid))
  assert_eq(t3.pending().length(), 0)
  assert_eq(t3.awaited().length(), 0)
}
