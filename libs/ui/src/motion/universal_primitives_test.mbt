// Deterministic multi-FPS unit tests for Wave 3A universal motion primitives:
// 1. EdgePull, dismiss_drag_offset, should_dismiss
// 2. SpringFollow2D (no fly-in from origin, velocity capsule stretch, release)
// 3. rolling_chars, rolling_slots_node (zero relayout, directional roll, rolls=false snap)
// 4. glyph_noise, glyph_in, glyph_change, TextMorph (normal + mid-flight set_out continuation)
// 5. hero_seen_of, hero_flight_box (cover/letterbox, start_crop, dy clip preservation, corner zeroing)
// 6. curtain_reveal (NodeWay zero-relayout reveal, auto-unmount at rest, reduced motion)
// 7. SerialQueue (same-source immediate, cross-source staggered with lead, reset)

///|
let up_spring_mid_ms : Double = 50.0

///|
let up_spring_done_ms : Double = 1200.0

///|
let up_roll_early_ms : Double = 40.0

///|
let up_roll_done_ms : Double = 2000.0

///|
let up_curtain_ms : Double = 400.0

///|
let up_curtain_mid_ms : Double = 150.0

///|
let up_curtain_wait_after_ms : Double = 250.0

///|
let up_curtain_wait_out_ms : Double = 150.0

///|
test "pull: EdgePull hyperbolic asymptote, signal notification, and spring-back to idle" {
  let pull = @motion.EdgePull::new(limit=6.0)
  let shown : Ref[(Double, Double, Double)] = Ref((0.0, 0.0, 0.0))
  let t = @ui.Tester::new(fn(_c) {  })
  let node_ref : Ref[@view.View?] = Ref(None)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      node_ref.val = Some(b)
      b.alpha(@view.By(fn() {
        shown.val = pull.shown_on(b)
        1.0
      }))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(pull.taken(), false)
  assert_eq(shown.val, (0.0, 0.0, 0.0))

  // Pull 6.0 -> 6 / (1 + 6/6) = 3.0; pull huge -> approaches 6.0 without exceeding it
  pull.drag(6.0, 40.0, 200.0)
  t.draw()
  assert_eq(pull.taken(), true)
  assert_true((shown.val.0 - 3.0).abs() < 1.0e-9, msg="aside at 6: \{shown.val.0}")
  assert_eq((shown.val.1, shown.val.2), (40.0, 200.0))

  pull.drag(6000.0, 80.0, 200.0)
  t.draw()
  assert_true(shown.val.0 > 5.9 && shown.val.0 < 6.0, msg="asymptote: \{shown.val.0}")
  assert_eq(shown.val.1, 80.0)

  // Negative pull mirrors sign symmetrically
  pull.drag(-6.0, 80.0, 200.0)
  t.draw()
  assert_true((shown.val.0 + 3.0).abs() < 1.0e-9, msg="neg aside: \{shown.val.0}")

  // Release springs back to 0.0 and settles idle
  let v = node_ref.val.unwrap()
  pull.let_go(v)
  assert_eq(pull.taken(), false)
  t.run_for(up_spring_done_ms)
  assert_true(shown.val.0.abs() < 1.0e-6, msg="settled aside: \{shown.val.0}")
  t.assert_idle()
}

///|
test "pull: dismiss_drag_offset and should_dismiss velocity/threshold rules" {
  // Positive direction is 1:1
  assert_eq(@motion.dismiss_drag_offset(85.0, 400.0), 85.0)
  assert_eq(@motion.dismiss_drag_offset(0.0, 400.0), 0.0)
  // Negative direction applies rubber_band when resist_opposite=true
  let opp = @motion.dismiss_drag_offset(-100.0, 400.0)
  assert_eq(opp, @motion.rubber_band(-100.0, 400.0))
  assert_true(opp < 0.0 && opp > -100.0, msg="damped opposite: \{opp}")
  // Unresisted opposite is 1:1
  assert_eq(@motion.dismiss_drag_offset(-100.0, 400.0, resist_opposite=false), -100.0)

  // Offset above threshold with zero velocity dismisses; below stays
  assert_eq(@motion.should_dismiss(120.0, 0.0, 120.0), true)
  assert_eq(@motion.should_dismiss(119.0, 0.0, 120.0), false)
  // High positive velocity dismisses even at small offset
  assert_eq(@motion.should_dismiss(10.0, 600.0, 120.0), true)
  // High negative velocity (flinging back) keeps even past threshold
  assert_eq(@motion.should_dismiss(200.0, -600.0, 120.0), false)
}

///|
test "deform: SpringFollow2D snaps on first engage, stretches in flight, and releases to idle" {
  let follow = @motion.SpringFollow2D::new()
  let target : @signals.Signal[(Double, Double)?] = @signals.signal(None)
  let shape_ref : Ref[@view.GroundShape] = Ref(@view.ground_as_laid)
  let held_ref : Ref[Double] = Ref(0.0)
  let active_ref : Ref[Bool] = Ref(false)
  let t = @ui.Tester::new(fn(_c) {  })
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.reacts(fn() { target.get() }, fn(p) {
        match p {
          Some((x, y)) => follow.chase(b, x, y)
          None => follow.release(b)
        }
      })
      b
      .width(@view.Is(Some(120.0)))
      .height(@view.Is(Some(48.0)))
      .ground_drawn(@view.By(fn() {
        active_ref.val = follow.active(b)
        held_ref.val = follow.held_shown(b)
        let (tx, ty) = target.get().unwrap_or((0.0, 0.0))
        let s = follow.capsule_shape(b, 120.0, 48.0, tx, ty)
        shape_ref.val = s
        s
      }))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(active_ref.val, false)
  assert_eq(held_ref.val, 0.0)

  // First chase snaps immediately to (200, 100) with zero horizontal stretch (never flies in from 0,0)
  target.set(Some((200.0, 100.0)))
  t.draw()
  assert_eq(active_ref.val, true)
  assert_eq(shape_ref.val.dw, 0.0)
  assert_eq(shape_ref.val.dx, 0.0)
  t.run_for(up_spring_done_ms)
  assert_true((held_ref.val - 1.0).abs() < 1.0e-6, msg="held settled: \{held_ref.val}")

  // Subsequent move springs and stretches horizontally while flattening vertically
  target.set(Some((360.0, 100.0)))
  t.run_for(up_spring_mid_ms)
  assert_true(shape_ref.val.dw > 0.0, msg="expected horizontal stretch dw > 0: \{shape_ref.val.dw}")
  assert_true(shape_ref.val.dh < 0.0, msg="expected vertical compression dh < 0: \{shape_ref.val.dh}")

  t.run_for(up_spring_done_ms)
  assert_eq(shape_ref.val.dw, 0.0)
  assert_eq(shape_ref.val.dh, 0.0)

  // Release brings held back to 0 and active to false
  target.set(None)
  t.run_for(up_spring_done_ms)
  assert_eq(active_ref.val, false)
  assert_eq(held_ref.val, 0.0)
  t.assert_idle()
}

///|
test "rolling: rolling_slots_node rolls changed slot with zero relayout and snaps when rolls=false" {
  assert_eq(@motion.rolling_chars("98%"), ['9', '8', '%'])
  let text = @signals.signal("98")
  let dir = @signals.signal(0.0)
  let allow_roll = @signals.signal(true)
  let t = @ui.Tester::new(fn(_c) {  }, w=300.0, h=200.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.lines_up(@view.Is(Some(Start))) |> ignore
      @motion.rolling_slots_node(
        b,
        fn() { text.get() },
        fn() { dir.get() },
        fn() { @ui.text_style(tabular=true) },
        fn() { 0xFF111111L },
        rolls=fn() { allow_roll.get() },
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let rest = t.words().map(fn(w) { (w.0, w.1, w.2) })
  let tens_9 = rest.filter(fn(w) { w.0 == "9" })[0]
  let ones_8 = rest.filter(fn(w) { w.0 == "8" })[0]

  // Increment 98 -> 99: ones slot rolls up from below, tens slot stays still, zero relayout during roll
  dir.set(1.0)
  text.set("99")
  t.frame()
  t.tree_frames_from_now()
  t.run_for(up_roll_early_ms)
  assert_true(
    t.tree_frames().iter().all(fn(f) { f.laid == 0 }),
    msg="rolling_slots_node must not trigger Flex relayout during roll",
  )
  let mid = t.words().map(fn(w) { (w.0, w.1, w.2) })
  let new_9 = mid.filter(fn(w) { w.0 == "9" && w.1 == ones_8.1 })
  let old_8 = mid.filter(fn(w) { w.0 == "8" })
  assert_true(mid.contains(tens_9), msg="unchanged tens slot stayed put")
  assert_true(new_9.length() == 1 && new_9[0].2 > ones_8.2, msg="new digit rolls in from below")
  assert_true(old_8.length() == 1 && old_8[0].2 < ones_8.2, msg="old digit rolls out above")

  t.run_for(up_roll_done_ms)
  let settled = t.words().map(fn(w) { w.0 })
  assert_eq(settled, ["9", "9"])
  t.assert_idle()

  // With rolls=false, change snaps immediately with no outgoing ghost
  allow_roll.set(false)
  dir.set(-1.0)
  text.set("97")
  t.frame()
  let snapped = t.words().map(fn(w) { (w.0, w.1, w.2) })
  assert_eq(snapped.map(fn(w) { w.0 }), ["9", "7"])
  assert_true(snapped.contains(("7", ones_8.1, ones_8.2)), msg="snapped directly to rest position")
  t.assert_idle()
}

///|
test "text_morph: glyph_in, glyph_change non-overlap, and TextMorph normal + mid-flight set_out" {
  // Deterministic glyph_noise in [0, 1]
  let n0 = @motion.glyph_noise(3, 42)
  assert_eq(n0, @motion.glyph_noise(3, 42))
  assert_true(n0 >= 0.0 && n0 <= 1.0, msg="noise bounds: \{n0}")

  // glyph_in: hidden before start, settled at end
  let g_before = @motion.glyph_in(-10.0, 100.0, 0, 7)
  assert_eq(g_before.alpha, 0.0)
  let g_done = @motion.glyph_in(1000.0, 100.0, 0, 7)
  assert_eq((g_done.alpha, g_done.dy), (1.0, 0.0))

  // glyph_change: outgoing and incoming never overlap (at every ms, at least one has alpha == 0)
  for step in 0..<=40 {
    let ms = step.to_double() * 12.0
    let out_l = @motion.glyph_change(ms, 40.0, 2, 13, false)
    let in_l = @motion.glyph_change(ms, 40.0, 2, 13, true)
    assert_true(
      out_l.alpha == 0.0 || in_l.alpha == 0.0,
      msg="glyph_change overlapped at ms=\{ms}: out=\{out_l.alpha}, in=\{in_l.alpha}",
    )
  }

  // TextMorph width and glyph placement + mid-flight interruption continuity
  let was_cells = [(5.0, 10.0), (15.0, 10.0), (25.0, 10.0)]
  let now_cells = [(6.0, 12.0), (20.0, 16.0)]
  assert_eq(@motion.TextMorph::cells_width(was_cells), 30.0)
  assert_eq(@motion.TextMorph::cells_width(now_cells), 28.0)
  assert_eq(@motion.TextMorph::cells_width([]), 0.0)

  let m1 = @motion.TextMorph::new(was_cells, now_cells, 3, 99)
  assert_eq(m1.across(0.0, 100.0), 30.0)
  assert_eq(m1.across(1.0, 100.0), 28.0)
  assert_eq(m1.across(0.5, 20.0), 20.0) // clamped to visible=20

  // Capture mid-flight state at k=0.5 and interrupt into a 3rd text
  let mid_w = m1.across(0.5, 100.0)
  let set_out = now_cells.mapi(fn(i, _) { m1.place(0.5, i, true) })
  let third_cells = [(4.0, 8.0), (12.0, 8.0), (20.0, 8.0)]
  let m2 = @motion.TextMorph::new(now_cells, third_cells, 3, 99, from=mid_w, set_out~)
  // At k=0 of m2, outgoing glyph positions match m1's incoming positions at k=0.5 continuously
  assert_eq(m2.across(0.0, 100.0), mid_w)
  for i in 0..<now_cells.length() {
    let (dx_prev, sx_prev) = set_out[i]
    let (dx_next, sx_next) = m2.place(0.0, i, false)
    assert_true((dx_next - dx_prev).abs() < 1.0e-9, msg="dx continuity at \{i}: \{dx_next} vs \{dx_prev}")
    assert_true((sx_next - sx_prev).abs() < 1.0e-9, msg="sx continuity at \{i}: \{sx_next} vs \{sx_prev}")
  }

  // TextMorph::look composes place (dx, sx) with glyph_change
  let at : @ui.GlyphAt = { index: 1, x: 15.0, y: 0.0, h: 16.0, top: 0.0, foot: 16.0, line: 0, cx: 15.0 }
  let look = m1.look(1.0, 1.0, at, true)
  assert_eq((look.alpha, look.dx, look.sx), (1.0, 0.0, 1.0))
}

///|
test "hero_flight: cover vs letterbox, start_crop, dy clip preservation, and corner zeroing" {
  // hero_seen_of clamps to stage, or returns rect when disjoint
  assert_eq(@motion.hero_seen_of((-20.0, 10.0, 100.0, 50.0), 400.0, 300.0), (0.0, 10.0, 80.0, 50.0))
  assert_eq(@motion.hero_seen_of((500.0, 10.0, 100.0, 50.0), 400.0, 300.0), (500.0, 10.0, 100.0, 50.0))

  let thumb : @motion.HeroThumb = {
    x: 20.0,
    y: 40.0,
    w: 100.0,
    h: 100.0,
    seen: Some((20.0, 50.0, 100.0, 90.0)), // top clipped by 10px, bottom unclipped
    corners: (12.0, 12.0, 8.0, 8.0),
    letterbox: false,
    start_crop: false,
  }
  let target = (0.0, 50.0, 400.0, 200.0) // 2:1 landscape

  // Degenerate target returns None
  assert_eq(@motion.hero_flight_box(thumb, 0.0, (0.0, 0.0, 0.0, 100.0), 0.5, 400.0, 300.0), None)

  // Cover mode at p=0: 2:1 picture covering 100x100 thumb -> 200x100 centered at x=-30
  let cover0 = @motion.hero_flight_box(thumb, 0.0, target, 0.0, 400.0, 300.0).unwrap()
  assert_eq(cover0.picture, (-30.0, 40.0, 200.0, 100.0))
  assert_eq(cover0.corners, (12.0, 12.0, 8.0, 8.0))
  assert_eq(cover0.cut, (20.0, 50.0, 100.0, 90.0))

  // At p=1: lands on target, cut opens to whole stage, corners reach (0, 0, 0, 0)
  let cover1 = @motion.hero_flight_box(thumb, 0.0, target, 1.0, 400.0, 300.0).unwrap()
  assert_eq(cover1.picture, target)
  assert_eq(cover1.box, target)
  assert_eq(cover1.cut, (0.0, 0.0, 400.0, 300.0))
  assert_eq(cover1.corners, (0.0, 0.0, 0.0, 0.0))

  // Letterbox + start_crop: 2:1 picture fits inside 100x100 -> 100x50 anchored at (20, 40)
  let lb_thumb = { ..thumb, letterbox: true, start_crop: true }
  let lb0 = @motion.hero_flight_box(lb_thumb, 0.0, target, 0.0, 400.0, 300.0).unwrap()
  assert_eq(lb0.picture, (20.0, 40.0, 100.0, 50.0))

  // With dy = -20: clipped top edge stays at y=50, unclipped bottom edge moves up by -20 (from 140 to 120)
  let lifted0 = @motion.hero_flight_box(thumb, -20.0, target, 0.0, 400.0, 300.0).unwrap()
  assert_eq(lifted0.cut, (20.0, 50.0, 100.0, 70.0))
  assert_eq(lifted0.box, (20.0, 20.0, 100.0, 100.0))
}

///|
test "reveal: curtain_reveal sweeps with zero Flex relayout, unmounts at rest, and respects reduced_motion" {
  let active = @signals.signal(false)
  let t = @ui.Tester::new(fn(_c) {  }, w=200.0, h=120.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.width(@view.Is(Some(200.0))).height(@view.Is(Some(120.0))) |> ignore
      @motion.curtain_reveal(
        b,
        fn() { active.get() },
        fn() { 0xFFEEEEEE_L },
        duration_ms=up_curtain_ms,
        wait_after_ms=up_curtain_wait_after_ms,
        wait_out_ms=up_curtain_wait_out_ms,
        steps=6,
      )
    })
    |> ignore
  })
  t.draw()
  let rest_rects = t.drawn_rects().length()

  // Activate reveal: strips appear and animate with zero Flex relayout
  active.set(true)
  t.frame()
  assert_true(t.drawn_rects().length() > rest_rects, msg="curtain strips should render while active")
  t.tree_frames_from_now()
  t.run_for(up_curtain_mid_ms)
  assert_true(
    t.tree_frames().iter().all(fn(f) { f.laid == 0 }),
    msg="curtain_reveal must not trigger Flex relayout during sweep",
  )

  // Complete reveal: strips unmount and tree returns to idle
  t.run_for(up_curtain_ms)
  assert_eq(t.drawn_rects().length(), rest_rects)
  t.assert_idle()

  // Under reduced motion, activating snaps immediately with no curtain strips left active
  active.set(false)
  t.draw()
  t.set_reduce_motion(true)
  active.set(true)
  t.draw()
  assert_eq(t.drawn_rects().length(), rest_rects)
  t.assert_idle()
}

///|
test "choreography: SerialQueue schedules same-source immediately and staggers cross-source with lead" {
  let q = @motion.SerialQueue::new()
  // First arrival starts immediately
  assert_eq(q.next_at("a", 100.0, lead=40.0), 100.0)
  q.commit("a", 300.0)

  // Same source runs immediately even while previous item is still active
  assert_eq(q.next_at("a", 120.0, lead=40.0), 120.0)
  q.commit("a", 250.0) // tail_end remains max(300.0, 250.0) = 300.0

  // Different source queues behind tail_end - lead = 300.0 - 40.0 = 260.0
  assert_eq(q.next_at("b", 150.0, lead=40.0), 260.0)
  q.commit("b", 460.0)

  // Arrival past tail_end - lead starts immediately at now
  assert_eq(q.next_at("c", 500.0, lead=40.0), 500.0)

  // Reset clears tail_end and last_source
  q.reset()
  assert_eq(q.next_at("b", 10.0, lead=40.0), 10.0)
}
