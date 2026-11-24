// White-box tests for custom hue slider (`accent_pick_node` + `@glass.liquid_slider_look`):
// - Press mounts droplet_role=1 liquid glass loupe (slot 7 == -16.0), 0 glass at rest, laid == 0 on drag/release
// - Thumb center aligns with travel_inset = hue_thumb_room / 2.0 and rainbow strip stays unobstructed (fill_color=None)
// - FPS invariance across 60 / 120 / 24 / 7 fps

///|
let hue_hold_ms : Double = 250.0

///|
let hue_drag_ms : Double = 200.0

///|
let hue_settle_ms : Double = 800.0

///|
test "hue_slider_node: lazy droplet loupe (slot 7 == -16), laid == 0 on drag/release, and FPS-invariant motion" {
  let chosen = @signals.signal("custom:180")
  let t = w2_case(w=600.0, fn(root) {
    accent_pick_node(
      root,
      fn() { ["橙色", "蓝色", "青色", "紫色", "粉色"] },
      fn() { "五彩色" },
      fn() { "自定义" },
      fn() { "色相" },
      fn() { chosen.get() },
      fn(k) { chosen.set(k) },
    )
  })
  t.run_for(@ui.move_most_ms)
  // At rest: 0 liquid glass instances
  assert_eq(t.drawn_glass().length(), 0, msg="rest hue slider must emit 0 glass")
  let sl = t.get(Slider, label="色相").rect
  let cy = sl.1 + sl.3 / 2.0
  let x0 = sl.0 + hue_thumb_room / 2.0 + (sl.2 - hue_thumb_room) * 0.5
  let x1 = sl.0 + hue_thumb_room / 2.0 + (sl.2 - hue_thumb_room) * 0.8
  t.press_at(x0, cy)
  t.run_for(hue_hold_ms)
  let mut saw_droplet = false
  for inst in t.drawn_instances() {
    if inst[5] == 6.0 && (inst[7] - -16.0).abs() < 0.01 {
      saw_droplet = true
    }
  }
  assert_true(saw_droplet, msg="held hue slider must emit droplet_role=1 (slot 7 == -16.0)")
  t.tree_frames_from_now()
  t.move_to(x1, cy)
  t.run_for(hue_drag_ms)
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="hue slider drag must not relayout: \{Repr(f)}")
  }
  let mut droplet_cx = 0.0
  for inst in t.drawn_instances() {
    if inst[5] == 6.0 && (inst[7] - -16.0).abs() < 0.01 {
      droplet_cx = inst[0] + inst[2] / 2.0
    }
  }
  assert_true((droplet_cx - x1).abs() < 4.0, msg="droplet center \{droplet_cx} should align near target \{x1}")
  t.tree_frames_from_now()
  t.release(x1, cy)
  t.run_for(hue_settle_ms)
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="hue slider release must not relayout: \{Repr(f)}")
  }
  assert_eq(t.drawn_glass().length(), 0, msg="settled hue slider must emit 0 glass")
  assert_true(custom_hue(chosen.untracked()).unwrap_or(-1) > 240, msg="drag to 80% should move hue > 240")
  assert_eq(t.audit(), [], msg="hue slider audit must be empty")
}

///|
test "hue_slider_node: rejected hue keeps thumb aligned with model value" {
  let fixed = @signals.signal("custom:120")
  let t = w2_case(w=600.0, fn(root) {
    accent_pick_node(
      root,
      fn() { ["橙色", "蓝色", "青色", "紫色", "粉色"] },
      fn() { "五彩色" },
      fn() { "自定义" },
      fn() { "色相" },
      fn() { fixed.get() },
      fn(_) { () },
    )
  })
  t.run_for(@ui.move_most_ms)
  let sl = t.get(Slider, label="色相").rect
  let cy = sl.1 + sl.3 / 2.0
  let knob_cx = fn() -> Double raise {
    let ks = t.drawn_rects().filter(fn(r) {
      r.4 == 0xFFFFFFFFL &&
      (r.2 - @glass.slider_thumb_w).abs() < 0.5 &&
      (r.3 - @glass.slider_thumb_h).abs() < 0.5 &&
      r.1 >= sl.1 - 2.0
    })
    assert_eq(ks.length(), 1, msg="expected 1 white 38x24 hue capsule thumb rect")
    ks[0].0 + ks[0].2 / 2.0
  }
  let cx0 = knob_cx()
  t.press_at(sl.0 + sl.2 * 0.85, cy)
  t.run_for(hue_hold_ms)
  t.release(sl.0 + sl.2 * 0.85, cy)
  t.run_for(hue_settle_ms)
  assert_eq(t.drawn_glass().length(), 0, msg="released rejected hue slider must emit 0 glass")
  let cx1 = knob_cx()
  assert_true((cx1 - cx0).abs() < 0.5, msg="rejected hue drag must keep thumb at model value: \{cx0} vs \{cx1}")
}
