// What the pictures hold is let go of: an image forgotten takes every frame of a GIF and what was read back of it with
// it (forget_image); pixels read back kept to a budget, those asked for longest ago let go and read again as they were
// (pixels_for); the frames of a GIF not drawn let go past their budget and made again from it, the same bytes
// (trim_gif_frames).

///|
/// The keys of pixels_read, sorted.
fn pixels_keys() -> Array[String] {
  let out = pixels_read.keys().collect()
  out.sort()
  out
}

///|
/// The pixels of `src` at `px` read back: asked for, its decode done by the next frame, asked again.
fn pixels_read_back(t : Tester, src : String, px : Int) -> ImagePixels {
  match pixels_for(src, px, g().frame_no, t.time()) {
    PixelsComing => {
      t.frame()
      pixels_for(src, px, g().frame_no, t.time())
    }
    p => p
  }
}

///|
test "an image forgotten: a GIF's every frame, their decodes and what was read back of them let go with it" {
  let data = many_ways_gif()
  let shown = Ref(false)
  let t = shown_twice("mem:gone", shown)
  add_image("mem:gone", data)
  t.draw()
  let m = moving_images.get("mem:gone").unwrap()
  // shown a whole loop: every frame made and decoded
  run_to_frame(t, m, 0, a_moment_short)
  shown.val = true
  t.draw()
  for k in [1, 2, 3, 4, 5, 0] {
    run_to_frame(t, m, k, 0.0)
  }
  assert_eq(made_of(m), [true, true, true, true, true, true])
  for k in m.keys {
    assert_true(image_data.contains(k), msg=k)
    assert_true(image_cache.contains(k), msg=k)
  }
  assert_true(gif_expanded_bytes.val > 0)
  // what was read back of it and of a frame of it
  assert_true(pixels_read_back(t, "mem:gone", 16) is PixelsRead(_, _, _))
  assert_true(pixels_read_back(t, "mem:gone#2", 16) is PixelsRead(_, _, _))
  assert_eq(pixels_keys().length(), 2)
  shown.val = false
  t.draw()
  forget_image("mem:gone")
  assert_true(!moving_images.contains("mem:gone"))
  assert_true(!image_data.contains("mem:gone"))
  assert_true(!image_cache.contains("mem:gone"))
  for k in m.keys {
    assert_true(!image_data.contains(k), msg=k)
    assert_true(!image_cache.contains(k), msg=k)
  }
  assert_eq(pixels_keys(), [])
  assert_eq(pixels_by_src.length(), 0)
  assert_eq(pixels_bytes.val, 0)
  assert_eq(gif_expanded_bytes.val, 0)
  assert_eq(image_bytes.val, 0.0)
}

///|
test "pixels read back kept to their budget: those asked for longest ago let go, read again the same" {
  let t = Tester::new(fn(_c) {  }, w=200.0, h=200.0)
  let pixels = fn(seed : Int) {
    FixedArray::makei(40 * 30 * 4, fn(i) { ((i * 7 + seed) % 251).to_byte() })
  }
  t.add_pixels("a.png", 40, 30, pixels(1))
  t.add_pixels("b.png", 40, 30, pixels(2))
  t.add_pixels("c.png", 40, 30, pixels(3))
  t.draw()
  let a = pixels_read_back(t, "a.png", 40)
  let one = pixels_bytes.val
  assert_true(a is PixelsRead(40, 30, _), msg="\{one}")
  assert_eq(one, 40 * 30 * 4)
  // room for two
  pixels_budget.val = one * 2
  t.frame()
  assert_true(pixels_read_back(t, "b.png", 40) is PixelsRead(_, _, _))
  t.frame()
  // (a asked for again: b is now the one asked for longest ago)
  assert_true(pixels_for("a.png", 40, g().frame_no, t.time()) == a)
  t.frame()
  let c = pixels_read_back(t, "c.png", 40)
  assert_true(c is PixelsRead(_, _, _))
  assert_eq(pixels_keys().map(fn(k) { k.has_suffix(" b.png") }), [false, false])
  assert_eq(pixels_keys().length(), 2)
  assert_eq(pixels_bytes.val, one * 2)
  assert_eq(pixels_by_src.get("b.png"), None)
  // b asked for again: read back again from its decode, as it was
  t.frame()
  match pixels_for("b.png", 40, g().frame_no, t.time()) {
    PixelsRead(w, h, px) => {
      assert_eq((w, h), (40, 30))
      assert_true(px == pixels(2))
    }
    _ => fail("b: not read again")
  }
  // (and what was asked for longest ago then, a, let go for it)
  assert_eq(pixels_keys().length(), 2)
  assert_true(!pixels_keys().iter().any(fn(k) { k.has_suffix(" a.png") }))
  assert_eq(pixels_bytes.val, one * 2)
}

///|
test "pixels read back in one frame all kept: none of this frame's let go for the budget" {
  let t = Tester::new(fn(_c) {  }, w=200.0, h=200.0)
  t.add_pixels("d.png", 20, 20, FixedArray::make(20 * 20 * 4, b'\x10'))
  t.add_pixels("e.png", 20, 20, FixedArray::make(20 * 20 * 4, b'\x20'))
  t.draw()
  pixels_budget.val = 1
  // (both asked, both decoded by one frame, both read in the frame after)
  ignore(pixels_for("d.png", 20, g().frame_no, t.time()))
  ignore(pixels_for("e.png", 20, g().frame_no, t.time()))
  t.frame()
  assert_true(pixels_for("d.png", 20, g().frame_no, t.time()) is PixelsRead(_, _, _))
  assert_true(pixels_for("e.png", 20, g().frame_no, t.time()) is PixelsRead(_, _, _))
  assert_eq(pixels_keys().length(), 2)
}

///|
test "a GIF's frames let go once not drawn past their budget, its first kept; shown again, made again the same bytes" {
  let data = many_ways_gif()
  let eager = gif_frames(data).unwrap()
  let shown = Ref(false)
  let t = shown_twice("mem:trim", shown)
  add_image("mem:trim", data)
  t.draw()
  let m = moving_images.get("mem:trim").unwrap()
  run_to_frame(t, m, 0, a_moment_short)
  shown.val = true
  t.draw()
  for k in [1, 2, 3, 4, 5, 0] {
    run_to_frame(t, m, k, 0.0)
    holds_frame(t, "mem:trim", eager, k)
  }
  assert_eq(made_of(m), [true, true, true, true, true, true])
  assert_true(m.decoder is None)
  let expanded = gif_expanded_bytes.val
  let mut summed = 0
  for k in 1..<m.keys.length() {
    summed = summed + image_data[m.keys[k]].length()
  }
  assert_eq(expanded, summed)
  // under its budget: kept, though not drawn
  shown.val = false
  t.draw()
  t.frame()
  g().trim_images()
  assert_eq(gif_expanded_bytes.val, expanded)
  assert_eq(made_of(m), [true, true, true, true, true, true])
  // past it: every frame past its first let go of, its first kept
  gif_frames_budget.val = expanded - 1
  t.frame()
  g().trim_images()
  assert_eq(gif_expanded_bytes.val, 0)
  assert_eq(made_of(m), [true, false, false, false, false, false])
  assert_eq(m.unmade, 5)
  assert_true(m.decoder is None)
  for k in 1..<m.keys.length() {
    assert_true(!image_data.contains(m.keys[k]), msg=m.keys[k])
    assert_true(!image_cache.contains(m.keys[k]), msg=m.keys[k])
  }
  assert_true(image_data.contains(m.keys[0]))
  assert_true(image_data.contains("mem:trim"))
  // shown again mid-loop: its decoder made again, each frame the bytes of all decoded at once
  gif_frames_budget.val = gif_frames_budget_most
  run_to_frame(t, m, 3, a_moment_short)
  shown.val = true
  t.draw()
  assert_true(m.decoder is Some(_))
  t.run_for(a_moment_on)
  holds_frame(t, "mem:trim", eager, 3)
  for k in [4, 5, 0, 1, 2, 3] {
    run_to_frame(t, m, k, 0.0)
    holds_frame(t, "mem:trim", eager, k)
  }
  assert_eq(made_of(m), [true, true, true, true, true, true])
  assert_eq(gif_expanded_bytes.val, expanded)
}

///|
test "a GIF drawn this frame keeps its frames past the budget" {
  let data = many_ways_gif()
  let shown = Ref(true)
  let t = shown_twice("mem:held", shown)
  add_image("mem:held", data)
  t.draw()
  let m = moving_images.get("mem:held").unwrap()
  for k in [1, 2] {
    run_to_frame(t, m, k, 0.0)
  }
  let expanded = gif_expanded_bytes.val
  assert_true(expanded > 0)
  gif_frames_budget.val = 0
  // (drawn in the frame trimmed after)
  t.draw()
  g().trim_images()
  assert_eq(gif_expanded_bytes.val, expanded)
  assert_true(m.made[1] && m.made[2])
}

///|
test "a GIF's key handed over again as a still: every frame of the GIF let go of, the key drawn as the still" {
  let data = many_ways_gif()
  let shown = Ref(false)
  let t = shown_twice("mem:again", shown)
  add_image("mem:again", data)
  t.draw()
  let m = moving_images.get("mem:again").unwrap()
  run_to_frame(t, m, 0, a_moment_short)
  shown.val = true
  t.draw()
  for k in [1, 2, 3, 4, 5, 0] {
    run_to_frame(t, m, k, 0.0)
  }
  assert_eq(made_of(m), [true, true, true, true, true, true])
  assert_true(pixels_read_back(t, "mem:again#2", 16) is PixelsRead(_, _, _))
  assert_true(gif_expanded_bytes.val > 0)
  // handed over again: a still
  let still = b"\x89PNG not really"
  add_image("mem:again", still)
  assert_true(!moving_images.contains("mem:again"))
  for k in m.keys {
    assert_true(!image_data.contains(k), msg=k)
    assert_true(!image_cache.contains(k), msg=k)
  }
  assert_true(!pixels_keys().iter().any(fn(k) { k.contains("mem:again#") }), msg=pixels_keys().join(","))
  assert_eq(pixels_by_src.get("mem:again#2"), None)
  assert_eq(gif_expanded_bytes.val, 0)
  assert_eq(image_data.get("mem:again"), Some(still))
  // drawn as the still from then on, no frame of the GIF
  t.run_for(away)
  assert_eq(frames_drawn(t, "mem:again", m.keys.length()), [-1, -1])
}
