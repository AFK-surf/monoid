// Adversarial regression tests for iOS 27.0-aligned bottom bar motion:
// 1. Left<->right cross-tab taps never overflow the glass capsule, bound overshoot <= 2.5pt, raise clear tap droplet
//    without lifting the bar, and perform zero layout during flight.
// 2. High-velocity fling to the rightmost tab keeps the pill inside the capsule and holds the lens until landing.
// 3. Continuous 1:1 horizontal drag has no midpoint teleport jump, caps past-edge rubber band at 12pt, and fires ticks.
// 4. Ball position, velocity stretch, and held/tap-lens intensity are strictly FPS-invariant.
// 5. Lens frame is C0-continuous across past-edge drag release (no 1-frame right-edge jump).
// 6. Reduced motion suppresses tap droplet/held lift; glass_solid keeps solid pill uninflated with no lens glass.
// 7. After tap settles, tap_lens has ended and programmatic tab switch triggers no droplet or stale pending key leak.

///|
let ios27_sample_ms : Double = 4.0

///|
let ios27_after_release_ms : Double = 16.0

///|
let ios27_flight_check_ms : Double = 140.0

///|
let ios27_probe_ms : Double = 112.0

///|
let ios27_frame_ms_60 : Double = 1000.0 / 60.0

///|
let ios27_frame_ms_120 : Double = 1000.0 / 120.0

///|
let ios27_frame_ms_24 : Double = 1000.0 / 24.0

///|
let ios27_frame_ms_7 : Double = 1000.0 / 7.0

///|
let ios27_step_ms : Double = 16.0

///|
let ios27_lens_check_ms : Double = 160.0

///|
let ios27_stop_settle_ms : Double = 120.0

///|
let ios27_wall_hold_ms : Double = 220.0

///|
let ios27_interrupt_early_ms : Double = 25.0

///|
let ios27_interrupt_mid_ms : Double = 60.0

///|
let ios27_drag_leg_ms : Double = 40.0

///|
let ios27_brake_active_ms : Double = 300.0

///|
let ios27_fast_flick_step_ms : Double = 10.0

///|
let ios27_fast_flick_steps : Array[Int] = [1, 2, 3, 4]

///|
let ios27_panel_pull_steps : Array[Int] = [1, 2, 3, 4, 5, 6]

///|
let ios27_left_over_steps : Array[Int] = [1, 2, 3, 4, 5, 6]

///|
let ios27_touch_rates_hz : Array[Int] = [60, 120, 240]

///|
let ios27_pause_before_release_ms : Double = 1000.0

///|
let ios27_drag_steps : Array[Int] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]

///|
let ios27_flick_steps : Array[Int] = [1, 2, 3, 4, 5, 6]

///|
test "bar ios27: leftmost <-> rightmost cross-tab taps stay strictly inside capsule with <= 2.5pt overshoot, clear tap droplet, no bar lift, and zero layout" {
  let (t, _) = bar_at_rest()
  let laid = bar_laid_now()
  assert_eq(laid.items.length(), 4)
  // Ensure rightmost tab has no action (k: 1 -> 0) and leftmost ("chats") has action (k: 0 -> 1)
  let (xs_open, y) = bar_places_at()
  // 1. Leftmost (index 0, chats) -> Rightmost (index 3)
  t.tap(xs_open[3], y)
  let t0 = t.time()
  let goal_right = bar.ball_x.to
  let end_right = dmax(bar_rest(), t0 + 1.0)
  let mut max_overshoot_right = 0.0
  let mut peak_tap_lens_right = 0.0
  let mut s = t0
  while s <= end_right {
    let a = bar_ball_at(s)
    let (cx, _, sw, _) = bar_ball_frame(a, bar_laid_now(), false)
    let cap_w = bar_cur_capsule_w(bar_laid_now().w, a.k, a.collapse)
    let left = cx - sw / 2.0
    let right = cx + sw / 2.0
    assert_true(
      left >= 0.0 && right <= cap_w + 0.01,
      msg="L->R at +\{s - t0}ms: pill [\{left}, \{right}] overflowed [0, \{cap_w}]",
    )
    let over = bar.ball_x.at(s).0 - goal_right
    if over > max_overshoot_right {
      max_overshoot_right = over
    }
    let tl = bar.tap_lens_at(s)
    if tl > peak_tap_lens_right {
      peak_tap_lens_right = tl
    }
    assert_true(bar.up.value_at(s).abs() < 0.001, msg="L->R tap must not lift bar: up=\{bar.up.value_at(s)}")
    s = s + ios27_sample_ms
  }
  assert_true(max_overshoot_right <= 2.5, msg="L->R overshoot \{max_overshoot_right}pt > 2.5pt")
  assert_true(peak_tap_lens_right > 0.4, msg="L->R tap_lens peak \{peak_tap_lens_right} <= 0.4")
  // Step animation frames and verify zero relayout during flight
  t.frame()
  t.frame()
  t.tree_frames_from_now()
  t.run_for(ios27_flight_check_ms)
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="L->R flight caused relayout: \{Repr(f)}")
  }
  to_bar_rest(t)
  assert_eq(bar.tap_lens_at(t.time()), 0.0)
  // 2. Rightmost (index 3) -> Leftmost (index 0, chats, k: 0 -> 1)
  let cs_closed = bar_centres(bar_laid_now().w, bar.k_at(t.time()), bar_laid_now().items.length())
  t.tap(cs_closed[0] + 22.0, y)
  let t1 = t.time()
  let goal_left = bar.ball_x.to
  let end_left = dmax(bar_rest(), t1 + 1.0)
  let mut max_overshoot_left = 0.0
  let mut peak_tap_lens_left = 0.0
  let mut u = t1
  while u <= end_left {
    let a = bar_ball_at(u)
    let (cx, _, sw, _) = bar_ball_frame(a, bar_laid_now(), false)
    let cap_w = bar_cur_capsule_w(bar_laid_now().w, a.k, a.collapse)
    let left = cx - sw / 2.0
    let right = cx + sw / 2.0
    assert_true(
      left >= 0.0 && right <= cap_w + 0.01,
      msg="R->L at +\{u - t1}ms: pill [\{left}, \{right}] overflowed [0, \{cap_w}]",
    )
    let over = goal_left - bar.ball_x.at(u).0
    if over > max_overshoot_left {
      max_overshoot_left = over
    }
    let tl = bar.tap_lens_at(u)
    if tl > peak_tap_lens_left {
      peak_tap_lens_left = tl
    }
    assert_true(bar.up.value_at(u).abs() < 0.001, msg="R->L tap must not lift bar: up=\{bar.up.value_at(u)}")
    u = u + ios27_sample_ms
  }
  assert_true(max_overshoot_left <= 2.5, msg="R->L overshoot \{max_overshoot_left}pt > 2.5pt")
  assert_true(peak_tap_lens_left > 0.4, msg="R->L tap_lens peak \{peak_tap_lens_left} <= 0.4")
  t.frame()
  t.frame()
  t.tree_frames_from_now()
  t.run_for(ios27_flight_check_ms)
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="R->L flight caused relayout: \{Repr(f)}")
  }
  to_bar_rest(t)
  assert_eq(bar.tap_lens_at(t.time()), 0.0)
}

///|
test "bar ios27: high-velocity fling to rightmost tab stays inside capsule and holds lens until landing" {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  let items = bar_laid_now().items
  // Start from index 1, fling rapidly toward index 3
  t.tap(xs[1], y)
  to_bar_rest(t)
  let cs = bar_centres(bar_laid_now().w, bar.k_at(t.time()), items.length()).map(fn(x) { x + 22.0 })
  let release_x = cs[2] + (cs[3] - cs[2]) * 0.35
  t.drag(cs[1], y, release_x, y, steps=6)
  let let_go = t.time()
  assert_eq(bar.told.unwrap().active, Some(items[3]), msg="fling should land on rightmost tab")
  // Immediately after release, lens stays lifted (delayed until landing)
  assert_true(
    bar.held_at(let_go + ios27_after_release_ms) > 0.5,
    msg="lens collapsed too early after fling release: held=\{bar.held_at(let_go + ios27_after_release_ms)}",
  )
  let end_t = dmax(bar_rest(), let_go + 1.0)
  let mut s = let_go
  while s <= end_t {
    let a = bar_ball_at(s)
    let (cx, _, sw, _) = bar_ball_frame(a, bar_laid_now(), false)
    let cap_w = bar_cur_capsule_w(bar_laid_now().w, a.k, a.collapse)
    let left = cx - sw / 2.0
    let right = cx + sw / 2.0
    assert_true(
      left >= 0.0 && right <= cap_w + 0.01,
      msg="fling at +\{s - let_go}ms: pill [\{left}, \{right}] overflowed [0, \{cap_w}]",
    )
    s = s + ios27_sample_ms
  }
  to_bar_rest(t)
  assert_eq(bar.held_at(t.time()), 0.0)
}

///|
test "bar ios27: continuous horizontal drag has no midpoint jump, caps past-edge rubber band at 12pt, and fires haptic ticks" {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  let laid = bar_laid_now()
  let final_cs = bar_centres(laid.w, bar.k_end(), laid.items.length())
  let before = t.haptics().length()
  t.press_at(xs[0], y)
  t.run_for(bar_hold_ms)
  t.frame()
  // Smoothly drag right across all tab midpoints in 4pt increments
  let mut prev_goal = bar.ball_x.to
  let mut cur_x = xs[0]
  while cur_x <= xs[3] {
    t.move_to(cur_x, y)
    let g = bar.ball_x.to
    assert_true(g >= prev_goal - 0.01, msg="drag goal moved backward: \{prev_goal} -> \{g}")
    assert_true(g - prev_goal <= 15.0, msg="drag midpoint teleport jump: \{prev_goal} -> \{g}")
    prev_goal = g
    cur_x = cur_x + 4.0
  }
  // Drag +60pt past the rightmost tab center: rubber-band must cap at <= 12pt
  t.move_to(xs[3] + 60.0, y)
  let past = bar.ball_x.to - final_cs[3]
  assert_true(past > 6.0 && past <= 12.01, msg="rubber-band offset \{past}pt out of (6, 12.01]")
  let felt = t.haptics()[before:].to_owned()
  assert_true(felt.contains(@ui.TextHandleMove), msg="expected TextHandleMove haptic during drag, got \{Repr(felt)}")
  t.release(xs[3] + 60.0, y)
  to_bar_rest(t)
}

///|
fn ios27_tap_sample(period : Double?) -> (Double, Double, Double, Double) {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  t.tap(xs[3], y)
  let t0 = t.time()
  match period {
    Some(p) => {
      let mut at = t0 + p
      while at < t0 + ios27_probe_ms {
        t.frame_at(at)
        at = at + p
      }
      t.frame_at(t0 + ios27_probe_ms)
    }
    None => t.frame_at(t0 + ios27_probe_ms)
  }
  let a = bar_ball_at(t0 + ios27_probe_ms)
  (a.cx, a.sx, a.sy, a.held)
}

///|
test "bar ios27: tap flight cx, sx, sy, and tap-lens held are strictly FPS-invariant across 60/120/24/7 fps and single jump" {
  if @ui.test_at_a_rate() {
    return
  }
  let jump = ios27_tap_sample(None)
  let at60 = ios27_tap_sample(Some(ios27_frame_ms_60))
  let at120 = ios27_tap_sample(Some(ios27_frame_ms_120))
  let at24 = ios27_tap_sample(Some(ios27_frame_ms_24))
  let at7 = ios27_tap_sample(Some(ios27_frame_ms_7))
  assert_eq((at60, at120, at24, at7), (jump, jump, jump, jump))
}

///|
test "bar ios27: releasing past-edge rubber-band drag keeps lens frame C0-continuous with <= 0.01pt jump" {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  t.press_at(xs[0], y)
  t.run_for(bar_hold_ms)
  t.frame()
  t.move_to(xs[3] + 60.0, y)
  to_bar_rest(t)
  let laid = bar_laid_now()
  let release_t = t.time()
  let (cx0, _, sw0, _) = bar_ball_frame(bar_ball_at(release_t), laid, true)
  let left0 = cx0 - sw0 / 2.0
  let right0 = cx0 + sw0 / 2.0
  t.touch_at(2, xs[3] + 60.0, y, release_t)
  let (cx1, _, sw1, _) = bar_ball_frame(bar_ball_at(release_t), laid, true)
  let left1 = cx1 - sw1 / 2.0
  let right1 = cx1 + sw1 / 2.0
  assert_true(
    (cx1 - cx0).abs() <= 0.01 && (left1 - left0).abs() <= 0.01 && (right1 - right0).abs() <= 0.01,
    msg="lens frame jumped on release: before=(\{cx0}, [\{left0}, \{right0}]) after=(\{cx1}, [\{left1}, \{right1}])",
  )
  to_bar_rest(t)
}

///|
test "bar ios27: reduced_motion suppresses tap droplet/held lift, and glass_solid keeps pill uninflated with no lens glass" {
  // 1. Reduced motion: cross-tab tap immediately snaps with zero tap_lens and zero ball_held
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  t.set_reduce_motion(true)
  t.draw()
  t.tap(xs[3], y)
  let t0 = t.time()
  assert_eq(bar.tap_lens_at(t0), 0.0)
  assert_eq(bar.tap_lens_at(t0 + ios27_probe_ms), 0.0)
  assert_eq(bar.ball_held_at(t0), 0.0)
  assert_eq(bar.ball_held_at(t0 + ios27_probe_ms), 0.0)
  t.set_reduce_motion(false)
  // 2. glass_solid: solid pill does not inflate on tap or hold, and no clear lens glass instance is emitted
  let (ts, _) = bar_at_rest()
  @ui.set_glass_solid(Some(true))
  ts.draw()
  let (xs2, y2) = bar_places_at()
  ts.press_at(xs2[0], y2)
  ts.run_for(bar_hold_ms)
  ts.frame()
  to_bar_rest(ts)
  let laid = bar_laid_now()
  let a = bar_ball_at(ts.time())
  let iw = bar_item_w(laid.w, a.k, laid.items.length())
  let pw = iw + 2.0 * (tab_edge - pill_inset)
  let (_, _, sw, sh) = bar_ball_frame(a, laid, false, solid=true)
  assert_true(
    (sw - pw).abs() <= 0.01 && (sh - pill_h).abs() <= 0.01,
    msg="glass_solid pill inflated during hold: got (\{sw}, \{sh}), expected (\{pw}, \{pill_h})",
  )
  let saw_lens = ts.drawn_instances().iter().any(fn(inst) { inst[5] == 6.0 && inst[7] <= -63.99 && inst[7] >= -64.5 })
  assert_false(saw_lens, msg="glass_solid must not emit clear lens glass instance")
  // Solid tab bar capsule and action disc both draw hairline control_edge_w borders
  let solid_bordered = ts.drawn_instances().filter(fn(inst) {
    inst.length() > 15 && inst[5] == 0.0 && (inst[6] - @sf.control_edge_w).abs() < 0.01 && inst[15] > 0.05
  })
  assert_true(solid_bordered.length() >= 2, msg="solid tab bar capsule and action disc must draw hairline borders, got \{solid_bordered.length()}")
  ts.release(xs2[0], y2)
  to_bar_rest(ts)
  @ui.set_glass_solid(None)
  // 3. Frosted material: bar uses kind==5 frosted glass, held pill stays uninflated with zero lens glass (no blurry blob over icons)
  new_run()
  let fsrc = fixture("home")
  (fsrc.call)("prefs.set", Json::object({ "glass": Json::string("frosted") }), @sfbase.answer_unread)
  let tf = @ui.Tester::new(fn(c) { view(c, fsrc) }, tree=app_tree(fsrc), w=390.0, h=844.0, platform=2)
  to_bar_rest(tf)
  let rest_glass_n = tf.drawn_glass().length()
  assert_true(rest_glass_n >= 1 && tf.drawn_glass().iter().all(fn(g) { g.4 == 5 }), msg="frosted bar must use kind==5 frosted glass")
  let (xs3, y3) = bar_places_at()
  tf.press_at(xs3[0], y3)
  tf.run_for(bar_hold_ms)
  tf.frame()
  to_bar_rest(tf)
  assert_eq(tf.drawn_glass().length(), rest_glass_n, msg="frosted held bar must not mount an extra lens glass blob over icons")
  assert_true(tf.drawn_glass().iter().all(fn(g) { g.4 == 5 }), msg="frosted held bar must emit zero kind==6 liquid glass")
  tf.release(xs3[0], y3)
  to_bar_rest(tf)
}

///|
test "bar ios27: tap_lens ends at rest and programmatic tab switch triggers no droplet or pending tap leak" {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  // Cross-tab tap 0 -> 3 and settle
  t.tap(xs[3], y)
  to_bar_rest(t)
  let rest_t = t.time()
  assert_true(bar.tap_lens_ends_at() <= rest_t, msg="tap_lens_ends_at() \{bar.tap_lens_ends_at()} > rest_t \{rest_t}")
  // Tap already-active tab (no switch), then programmatically switch back to chats (index 0): must not leak tap_lens
  let cs_closed = bar_centres(bar_laid_now().w, bar.k_at(rest_t), bar_laid_now().items.length())
  t.tap(cs_closed[3] + 22.0, y)
  let before_prog = t.time()
  let ends_before = bar.tap_lens_ends_at()
  assert_true(@sfbase.go_place("chats"))
  t.draw()
  assert_eq(bar.tap_lens_at(before_prog + ios27_probe_ms), 0.0)
  assert_true(
    bar.tap_lens_ends_at() <= ends_before,
    msg="programmatic switch triggered tap_lens: ends_at=\{bar.tap_lens_ends_at()} vs before=\{ends_before}",
  )
  to_bar_rest(t)
}

///|
test "bar ios27: cross-tab tap 0 -> 3 exhibits biphasic jelly stretch -> landing squish -> exact rest with laid == 0 and role 4 1.16x zoom" {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  t.tap(xs[3], y)
  let t0 = t.time()
  let end_t = dmax(bar_rest(), t0 + 1.0)
  let mut max_sx = 1.0
  let mut min_sy = 1.0
  let mut min_sx = 1.0
  let mut max_sy = 1.0
  let mut stretch_peak_t = t0
  let mut squish_peak_t = t0
  let mut s = t0
  while s <= end_t {
    let a = bar_ball_at(s)
    if a.sx > max_sx {
      max_sx = a.sx
      stretch_peak_t = s
    }
    if a.sy < min_sy {
      min_sy = a.sy
    }
    if a.sx < min_sx {
      min_sx = a.sx
      squish_peak_t = s
    }
    if a.sy > max_sy {
      max_sy = a.sy
    }
    s = s + ios27_sample_ms
  }
  assert_true(max_sx >= 1.10 && min_sy <= 0.86, msg="mid-flight stretch too weak: max_sx=\{max_sx}, min_sy=\{min_sy}")
  assert_true(min_sx <= 0.90 && max_sy >= 1.10, msg="landing squish too weak: min_sx=\{min_sx}, max_sy=\{max_sy}")
  assert_true(squish_peak_t > stretch_peak_t, msg="squish (\{squish_peak_t}) must follow stretch (\{stretch_peak_t})")
  // Verify live Role 4 lens emits zoom > 1.10 during flight and zero relayout across animation
  t.tree_frames_from_now()
  t.run_for(ios27_lens_check_ms)
  let saw_zoomed_lens = t.drawn_instances().iter().any(fn(inst) {
    inst[5] == 6.0 && inst[7] < -64.10 && inst[7] > -64.20
  })
  assert_true(saw_zoomed_lens, msg="mid-flight tap lens must emit Role 4 optical zoom near -64.16")
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="cross-tab tap jelly caused relayout: \{Repr(f)}")
  }
  to_bar_rest(t)
  let rest_a = bar_ball_at(t.time())
  assert_true((rest_a.sx - 1.0).abs() < 0.001 && (rest_a.sy - 1.0).abs() < 0.001, msg="flex not settled: (\{rest_a.sx}, \{rest_a.sy})")
  t.assert_idle()
}

///|
test "bar ios27: slow drag accel/decel jelly and +60pt right-edge wall squish bounce back C0-continuously" {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  t.press_at(xs[0], y)
  t.run_for(bar_hold_ms)
  t.frame()
  // Slow drag 0 -> 2 in 12 steps (~16ms each)
  let mut max_drag_sx = 1.0
  for step in ios27_drag_steps {
    let frac = step.to_double() / 12.0
    let px = xs[0] + (xs[2] - xs[0]) * frac
    t.move_to(px, y)
    let s0 = t.time()
    t.run_for(ios27_step_ms)
    let mut s = s0
    while s <= t.time() {
      let a = bar_ball_at(s)
      if a.sx > max_drag_sx {
        max_drag_sx = a.sx
      }
      s = s + ios27_sample_ms
    }
  }
  assert_true(max_drag_sx > 1.03, msg="slow drag start must stretch horizontally: max_sx=\{max_drag_sx}")
  // Sudden stop while holding finger on tab 2: deceleration triggers reverse squish
  let stop_t0 = t.time()
  t.move_to(xs[2], y)
  t.run_for(ios27_step_ms)
  t.move_to(xs[2], y)
  t.run_for(ios27_stop_settle_ms)
  let mut stop_min_sx = 1.0
  let mut stop_max_sy = 1.0
  let mut s = stop_t0
  while s <= t.time() {
    let a = bar_ball_at(s)
    if a.sx < stop_min_sx {
      stop_min_sx = a.sx
    }
    if a.sy > stop_max_sy {
      stop_max_sy = a.sy
    }
    s = s + ios27_sample_ms
  }
  assert_true(stop_min_sx < 0.99 && stop_max_sy > 1.01, msg="sudden stop must squish: min_sx=\{stop_min_sx}, max_sy=\{stop_max_sy}")
  // Drag +60pt past right edge: clear wall squish (sx <= 0.92, sy >= 1.08)
  t.move_to(xs[3] + 60.0, y)
  t.run_for(ios27_wall_hold_ms)
  let wall_a = bar_ball_at(t.time())
  assert_true(wall_a.sx <= 0.92 && wall_a.sy >= 1.08, msg="past-edge wall squish too weak: sx=\{wall_a.sx}, sy=\{wall_a.sy}")
  // Release C0-continuous
  let rel_t = t.time()
  let before_rel = bar_ball_at(rel_t)
  t.touch_at(2, xs[3] + 60.0, y, rel_t)
  let after_rel = bar_ball_at(rel_t)
  assert_true(
    (after_rel.sx - before_rel.sx).abs() <= 0.001 && (after_rel.sy - before_rel.sy).abs() <= 0.001,
    msg="wall release flex jumped: before=(\{before_rel.sx}, \{before_rel.sy}) after=(\{after_rel.sx}, \{after_rel.sy})",
  )
  to_bar_rest(t)
  let done_a = bar_ball_at(t.time())
  assert_true((done_a.sx - 1.0).abs() < 0.001 && (done_a.sy - 1.0).abs() < 0.001)
}

///|
test "bar ios27: quick flick (100ms release) obeys lensHangTime = 220ms before unlifting" {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  t.press_at(xs[0], y)
  let mut lift_t = -1.0
  for step in ios27_flick_steps {
    let frac = step.to_double() / 6.0
    let px = xs[0] + (xs[2] - xs[0]) * frac
    t.move_to(px, y)
    if lift_t < 0.0 && bar.ball_held_active {
      lift_t = t.time()
    }
    t.run_for(ios27_step_ms)
  }
  assert_true(lift_t >= 0.0, msg="quick flick must start lens lift")
  t.release(xs[2], y)
  // At 180ms after lift started (well after the ~96ms release), lens must still be clearly lifted
  let held_180 = bar.held_at(lift_t + 180.0)
  assert_true(held_180 >= 0.6, msg="quick flick lens vanished before lensHangTime: held@180ms=\{held_180}")
  to_bar_rest(t)
  assert_eq(bar.held_at(t.time()), 0.0)
}

///|
test "bar ios27: rapid repeated taps and mid-flight drag takeover stay exact C0-continuous with zero phantom impulse" {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  // Rapid tap 0 -> 3, interrupted 25ms later (before flex_launch 40ms delay fires!) by tap back to 1
  t.tap(xs[3], y)
  t.run_for(ios27_interrupt_early_ms)
  t.tap(xs[1], y)
  // Interrupted again 60ms later by finger drag takeover: assert exact C0 continuity at same timestamp grab_t
  t.run_for(ios27_interrupt_mid_ms)
  let grab_t = t.time()
  t.touch_at(0, xs[1], y, grab_t)
  let takeover_t = grab_t + ios27_step_ms
  let before_takeover = bar_ball_at(takeover_t)
  t.touch_at(1, xs[1] + 24.0, y, takeover_t)
  let after_takeover = bar_ball_at(takeover_t)
  assert_false(
    after_takeover.cx.is_nan() ||
    after_takeover.sx.is_nan() ||
    after_takeover.sy.is_nan() ||
    after_takeover.held.is_nan(),
  )
  assert_true(
    (after_takeover.held - before_takeover.held).abs() <= 0.000000001,
    msg="takeover held jumped at exact timestamp: \{before_takeover.held} -> \{after_takeover.held}",
  )
  assert_true(
    (after_takeover.sx - before_takeover.sx).abs() <= 0.000000001 &&
    (after_takeover.sy - before_takeover.sy).abs() <= 0.000000001,
    msg="takeover flex jumped at exact timestamp: (\{before_takeover.sx}, \{before_takeover.sy}) -> (\{after_takeover.sx}, \{after_takeover.sy})",
  )
  // Cancelled delayed launch/brake must remain strictly 0 (no phantom impulse later)
  assert_eq(bar.flex_launch.value_at(takeover_t + ios27_probe_ms), 0.0)
  assert_eq(bar.flex_brake.value_at(takeover_t + ios27_probe_ms), 0.0)
  t.run_for(ios27_drag_leg_ms)
  t.move_to(xs[2], y)
  t.run_for(ios27_drag_leg_ms)
  t.release(xs[2], y)
  to_bar_rest(t)
  let end_a = bar_ball_at(t.time())
  assert_false(end_a.cx.is_nan() || end_a.sx.is_nan() || end_a.sy.is_nan())
  assert_true((end_a.sx - 1.0).abs() < 0.001 && (end_a.sy - 1.0).abs() < 0.001, msg="interrupted flex did not settle: (\{end_a.sx}, \{end_a.sy})")
  assert_eq(bar.held_at(t.time()), 0.0)
}

///|
test "bar ios27: re-tapping during active flex_brake transfers residual oscillation into flex_decay without freezing" {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  // Tap 0 -> 3 and advance to +300ms when flex_brake is actively negative
  t.tap(xs[3], y)
  t.run_for(ios27_brake_active_ms)
  let re_t = t.time()
  let before_flex = bar.flex_at(re_t)
  assert_true(before_flex < -0.02, msg="expected active negative brake at +300ms, got \{before_flex}")
  // Immediately tap back to 0: residual must move into flex_decay (C0-continuous, never frozen across new delay)
  let cs_closed = bar_centres(bar_laid_now().w, bar.k_at(re_t), bar_laid_now().items.length())
  t.touch_at(0, cs_closed[0] + 22.0, y, re_t)
  t.touch_at(2, cs_closed[0] + 22.0, y, re_t)
  let after_flex = bar.flex_at(re_t)
  assert_true(
    (after_flex - before_flex).abs() <= 0.000000001,
    msg="re-tap flex jumped: \{before_flex} -> \{after_flex}",
  )
  let d0 = bar.flex_decay.value_at(re_t)
  let d40 = bar.flex_decay.value_at(re_t + 40.0)
  let d140 = bar.flex_decay.value_at(re_t + 140.0)
  assert_true(
    (d40 - d0).abs() > 0.01 && (d140 - d40).abs() > 0.01,
    msg="flex_decay froze during new delay: d0=\{d0}, d40=\{d40}, d140=\{d140}",
  )
  to_bar_rest(t)
  assert_true(bar.flex_at(t.time()).abs() < 0.001)
}

///|
test "bar ios27: 40ms ultra-fast flick continues lifting to >= 0.75 during lensHangTime before smoothly unlifting" {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  t.press_at(xs[0], y)
  let mut lift_t = -1.0
  for step in ios27_fast_flick_steps {
    let frac = step.to_double() / 4.0
    let px = xs[0] + (xs[2] - xs[0]) * frac
    t.move_to(px, y)
    if lift_t < 0.0 && bar.ball_held_active {
      lift_t = t.time()
    }
    t.run_for(ios27_fast_flick_step_ms)
  }
  assert_true(lift_t >= 0.0, msg="40ms flick must trigger lift")
  let release_t = t.time()
  t.release(xs[2], y)
  let held_at_rel = bar.held_at(release_t)
  let held_at_180 = bar.held_at(lift_t + 180.0)
  assert_true(
    held_at_180 > held_at_rel + 0.20 && held_at_180 >= 0.75,
    msg="40ms flick stalled instead of finishing lift: rel=\{held_at_rel}, @180ms=\{held_at_180}",
  )
  to_bar_rest(t)
  assert_eq(bar.held_at(t.time()), 0.0)
}

///|
fn ios27_drag_peaks_at_hz(hz : Int) -> (Double, Double) {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  let t_press = t.time()
  t.touch_at(0, xs[0], y, t_press)
  let dt = 1000.0 / hz.to_double()
  let dur_ms = 650.0
  let total_steps = (dur_ms / dt).round().to_int()
  let mut cur_t = t_press
  let mut max_sx = 1.0
  for i in 1..<=total_steps {
    cur_t = t_press + i.to_double() * dt
    let frac = i.to_double() / total_steps.to_double()
    let px = xs[0] + (xs[3] - xs[0]) * frac
    t.touch_at(1, px, y, cur_t)
    let a = bar_ball_at(cur_t)
    if a.sx > max_sx {
      max_sx = a.sx
    }
  }
  // Sudden stop while holding finger at xs[3]
  let stop_t0 = cur_t
  t.touch_at(1, xs[3], y, stop_t0 + dt)
  t.touch_at(1, xs[3], y, stop_t0 + 2.0 * dt)
  let mut max_sy = 1.0
  let mut s = stop_t0
  while s <= stop_t0 + 240.0 {
    let a = bar_ball_at(s)
    if a.sy > max_sy {
      max_sy = a.sy
    }
    s = s + ios27_sample_ms
  }
  t.touch_at(2, xs[3], y, stop_t0 + 250.0)
  (max_sx, max_sy)
}

///|
test "bar ios27: slow drag stretch and sudden-stop squish are invariant across 60Hz / 120Hz / 240Hz touch sampling" {
  if @ui.test_at_a_rate() {
    return
  }
  let res : Array[(Double, Double)] = []
  for hz in ios27_touch_rates_hz {
    res.push(ios27_drag_peaks_at_hz(hz))
  }
  let (sx60, sy60) = res[0]
  let (sx120, sy120) = res[1]
  let (sx240, sy240) = res[2]
  assert_true(sx60 > 1.03 && sy60 > 1.03, msg="60Hz drag flex too weak: sx=\{sx60}, sy=\{sy60}")
  assert_true(
    (sx120 - sx60).abs() <= 0.012 && (sx240 - sx60).abs() <= 0.012,
    msg="drag stretch varied across touch Hz: 60=\{sx60}, 120=\{sx120}, 240=\{sx240}",
  )
  assert_true(
    (sy120 - sy60).abs() <= 0.025 && (sy240 - sy60).abs() <= 0.025,
    msg="stop squish varied across touch Hz: 60=\{sy60}, 120=\{sy120}, 240=\{sy240}",
  )
}

///|
test "bar ios27: pausing 1000ms after drag decays residual velocity so gentle release triggers no brake squish" {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  t.press_at(xs[0], y)
  // Drag out to xs[2] and back to xs[0] so high drag velocity is recorded without changing the active tab's notch
  for step in ios27_drag_steps {
    let frac = step.to_double() / 12.0
    let px = xs[0] + (xs[2] - xs[0]) * frac
    t.move_to(px, y)
    t.run_for(ios27_step_ms)
  }
  for step in ios27_drag_steps {
    let frac = step.to_double() / 12.0
    let px = xs[2] + (xs[0] - xs[2]) * frac
    t.move_to(px, y)
    t.run_for(ios27_step_ms)
  }
  // Hold still for 1000ms at xs[0] before releasing gently (zero fling velocity, dist ~= 0)
  t.run_for(ios27_pause_before_release_ms)
  let rel_t = t.time()
  t.touch_at(2, xs[0], y, rel_t)
  // Decayed drag_last_vx must be ~0 -> no delayed brake impulse scheduled on flex_brake
  let mut min_brake = 0.0
  let mut s = rel_t
  while s <= rel_t + 300.0 {
    let b = bar.flex_brake.value_at(s)
    if b < min_brake {
      min_brake = b
    }
    s = s + ios27_sample_ms
  }
  assert_true(min_brake > -0.01, msg="paused gentle release triggered unwanted flex_brake: min=\{min_brake}")
  to_bar_rest(t)
}

///|
test "bar ios27: pulling multi-bar panel up from past-edge drag releases flex_wall cleanly" {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  t.press_at(xs[0], y)
  t.run_for(bar_hold_ms)
  t.frame()
  t.move_to(xs[3] + 60.0, y)
  t.run_for(ios27_wall_hold_ms)
  assert_true(bar.flex_wall.target() < -0.05, msg="expected negative wall flex before panel pull")
  // Pull straight up to engage multi-bar panel (`m.holds = true`)
  for step in ios27_panel_pull_steps {
    let py = y - 64.0 * step.to_double() / 6.0
    t.move_to(xs[3] + 60.0, py)
    t.run_for(ios27_step_ms)
  }
  assert_true(bar.holds, msg="panel pull must engage m.holds")
  assert_eq(bar.flex_wall.target(), 0.0, msg="panel pull must release flex_wall target back to 0.0")
  t.release(xs[3] + 60.0, y - 64.0)
  to_bar_rest(t)
  assert_true(bar.flex_wall.value_at(t.time()).abs() < 0.001)
}

///|
fn assert_tab0_concentric_at_rest(t : @ui.Tester, label : String) -> Unit raise {
  let laid = bar_laid_now()
  let rest_a = bar_ball_at(t.time())
  assert_true(
    bar.flex_at(t.time()).abs() < 0.001,
    msg="\{label}: flex_at did not settle to 0: \{bar.flex_at(t.time())}",
  )
  assert_true(
    (rest_a.sx - 1.0).abs() < 0.001 && (rest_a.sy - 1.0).abs() < 0.001,
    msg="\{label}: rest scale not (1, 1): (\{rest_a.sx}, \{rest_a.sy})",
  )
  assert_eq(bar.held_at(t.time()), 0.0)
  let (cx, _, sw, sh) = bar_ball_frame(rest_a, laid, false)
  let left = cx - sw / 2.0
  let top = (bar_track - sh) / 2.0
  let r_inner = dmin(sw, sh) / 2.0
  assert_true(
    (left - pill_inset).abs() <= 0.01,
    msg="\{label}: left inset \{left} != \{pill_inset}",
  )
  assert_true(
    (top - pill_inset).abs() <= 0.01,
    msg="\{label}: top inset \{top} != \{pill_inset}",
  )
  assert_true(
    (r_inner - (rad - pill_inset)).abs() <= 0.01,
    msg="\{label}: inner radius \{r_inner} != \{rad - pill_inset}",
  )
}

///|
test "bar ios27: dragging left past capsule edge (px < 0) keeps lens active, releases C0-continuously, and settles strictly concentric" {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  let laid = bar_laid_now()
  let final_cs = bar_centres(laid.w, bar.k_end(), laid.items.length())
  t.press_at(xs[0], y)
  t.run_for(bar_hold_ms)
  t.frame()
  let target_x = xs[0] - 46.0
  for step in ios27_left_over_steps {
    let frac = step.to_double() / 6.0
    let x = xs[0] + (target_x - xs[0]) * frac
    t.move_to(x, y)
    t.run_for(ios27_step_ms)
  }
  assert_true(bar.drag is Some(_), msg="px < 0 left drag must keep bar.drag as Some(_)")
  assert_true(bar.ball_held_active, msg="px < 0 left drag must keep ball_held_active == true")
  let past = final_cs[0] - bar.ball_x.to
  assert_true(past > 6.0 && past <= 12.01, msg="left rubber-band offset \{past}pt out of (6, 12.01]")
  assert_true(bar.flex_wall.target() < -0.05, msg="expected negative wall flex at px < 0, got \{bar.flex_wall.target()}")
  t.run_for(ios27_wall_hold_ms)
  let rel_t = t.time()
  let (cx0, _, sw0, _) = bar_ball_frame(bar_ball_at(rel_t), laid, true)
  let left0 = cx0 - sw0 / 2.0
  let right0 = cx0 + sw0 / 2.0
  t.touch_at(2, target_x, y, rel_t)
  assert_eq(bar.flex_wall.target(), 0.0, msg="release from px < 0 must reset flex_wall target to 0.0")
  let (cx1, _, sw1, _) = bar_ball_frame(bar_ball_at(rel_t), laid, true)
  let left1 = cx1 - sw1 / 2.0
  let right1 = cx1 + sw1 / 2.0
  assert_true(
    (cx1 - cx0).abs() <= 0.01 && (left1 - left0).abs() <= 0.01 && (right1 - right0).abs() <= 0.01,
    msg="left-edge release lens jumped: before=(\{cx0}, [\{left0}, \{right0}]) after=(\{cx1}, [\{left1}, \{right1}])",
  )
  to_bar_rest(t)
  assert_tab0_concentric_at_rest(t, "left-drag release")
  t.assert_idle()
}

///|
test "bar ios27: px < 0 left drag interrupted by touch cancel (Off) or page push resets flex_wall and settles strictly concentric" {
  // 1. System touch cancel (Off, kind == 3) while dragged past left edge (px < 0)
  let (t1, _) = bar_at_rest()
  let (xs1, y1) = bar_places_at()
  t1.press_at(xs1[0], y1)
  t1.run_for(bar_hold_ms)
  t1.frame()
  let target_x1 = xs1[0] - 46.0
  for step in ios27_left_over_steps {
    let frac = step.to_double() / 6.0
    t1.move_to(xs1[0] + (target_x1 - xs1[0]) * frac, y1)
    t1.run_for(ios27_step_ms)
  }
  assert_true(bar.flex_wall.target() < -0.05, msg="cancel case: expected negative wall flex")
  t1.touch_at(3, target_x1, y1, t1.time())
  assert_true(bar.drag is None, msg="cancel case: bar.drag must reset to None")
  assert_eq(bar.flex_wall.target(), 0.0, msg="cancel case: flex_wall target must reset to 0.0")
  to_bar_rest(t1)
  assert_tab0_concentric_at_rest(t1, "left-drag cancel")
  t1.assert_idle()
  // 2. Mid-drag page push hiding the bar, then popping back to Home
  let (t2, _) = bar_at_rest()
  let (xs2, y2) = bar_places_at()
  t2.press_at(xs2[0], y2)
  t2.run_for(bar_hold_ms)
  t2.frame()
  let target_x2 = xs2[0] - 46.0
  for step in ios27_left_over_steps {
    let frac = step.to_double() / 6.0
    t2.move_to(xs2[0] + (target_x2 - xs2[0]) * frac, y2)
    t2.run_for(ios27_step_ms)
  }
  assert_true(bar.flex_wall.target() < -0.05, msg="push case: expected negative wall flex")
  app.nav.push(Settings)
  t2.draw()
  assert_true(bar.drag is None, msg="push case: bar.drag must reset to None when hidden")
  assert_eq(bar.flex_wall.target(), 0.0, msg="push case: flex_wall target must reset to 0.0 when hidden")
  t2.run_for(@ui.move_most_ms)
  app.nav.pop() |> ignore
  t2.draw()
  to_bar_rest(t2)
  assert_tab0_concentric_at_rest(t2, "left-drag push-pop")
  t2.assert_idle()
}

///|
test "bar ios27: cross-tab drag from tab 1 past left edge (px < 0), return inside capsule, and multi-bar panel pull all settle strictly concentric" {
  // 1. Start on tab 1 (xs[1]), drag left past capsule edge (px < 0), then release back to tab 0 (flex_brake + flex_wall)
  let (t1, _) = bar_at_rest()
  let (xs1, y1) = bar_places_at()
  t1.tap(xs1[1], y1)
  to_bar_rest(t1)
  let cs1 = bar_centres(bar_laid_now().w, bar.k_at(t1.time()), bar_laid_now().items.length()).map(fn(x) { x + 22.0 })
  t1.press_at(cs1[1], y1)
  t1.run_for(bar_hold_ms)
  t1.frame()
  let target_x1 = xs1[0] - 46.0
  for step in ios27_left_over_steps {
    let frac = step.to_double() / 6.0
    t1.move_to(cs1[1] + (target_x1 - cs1[1]) * frac, y1)
    t1.run_for(ios27_step_ms)
  }
  assert_true(bar.drag is Some(_), msg="cross-tab left drag: bar.drag must stay Some(_)")
  assert_true(bar.ball_held_active, msg="cross-tab left drag: ball_held_active must stay true")
  assert_true(bar.flex_wall.target() < -0.05, msg="cross-tab left drag: expected negative flex_wall")
  t1.release(target_x1, y1)
  assert_eq(bar.flex_wall.target(), 0.0, msg="cross-tab left drag release: flex_wall target must reset to 0.0")
  to_bar_rest(t1)
  assert_eq(bar.told.unwrap().active, Some("chats"))
  assert_tab0_concentric_at_rest(t1, "cross-tab left-drag release")
  t1.assert_idle()
  // 2. Drag past left edge (px < 0) then slide back inside capsule without releasing (over_edge <= 0 branch)
  let (t2, _) = bar_at_rest()
  let (xs2, y2) = bar_places_at()
  t2.press_at(xs2[0], y2)
  t2.run_for(bar_hold_ms)
  t2.frame()
  let target_x2 = xs2[0] - 46.0
  for step in ios27_left_over_steps {
    let frac = step.to_double() / 6.0
    t2.move_to(xs2[0] + (target_x2 - xs2[0]) * frac, y2)
    t2.run_for(ios27_step_ms)
  }
  assert_true(bar.flex_wall.target() < -0.05, msg="return-inside case: expected negative flex_wall at px < 0")
  for step in ios27_left_over_steps {
    let frac = step.to_double() / 6.0
    t2.move_to(target_x2 + (xs2[0] - target_x2) * frac, y2)
    t2.run_for(ios27_step_ms)
  }
  assert_true(bar.ball_held_active, msg="return-inside case: ball_held_active must stay true")
  assert_eq(bar.flex_wall.target(), 0.0, msg="return-inside case: flex_wall target must reset to 0.0")
  t2.run_for(ios27_stop_settle_ms)
  t2.release(xs2[0], y2)
  to_bar_rest(t2)
  assert_tab0_concentric_at_rest(t2, "left-drag return inside")
  t2.assert_idle()
  // 3. Multi-bar pull up from px < 0 left drag (m.holds branch releases flex_wall), then close panel & settle
  let (t3, _) = bar_at_rest()
  let (xs3, y3) = bar_places_at()
  t3.press_at(xs3[0], y3)
  t3.run_for(bar_hold_ms)
  t3.frame()
  let target_x3 = xs3[0] - 46.0
  for step in ios27_left_over_steps {
    let frac = step.to_double() / 6.0
    t3.move_to(xs3[0] + (target_x3 - xs3[0]) * frac, y3)
    t3.run_for(ios27_step_ms)
  }
  assert_true(bar.flex_wall.target() < -0.05, msg="panel-pull case: expected negative flex_wall at px < 0")
  for step in ios27_panel_pull_steps {
    let py = y3 - 64.0 * step.to_double() / 6.0
    t3.move_to(target_x3, py)
    t3.run_for(ios27_step_ms)
  }
  assert_true(bar.holds, msg="panel-pull case: pulling up must engage m.holds")
  assert_eq(bar.flex_wall.target(), 0.0, msg="panel-pull case: m.holds must release flex_wall target to 0.0")
  t3.release(target_x3, y3 - 64.0)
  to_bar_rest(t3)
  if bar.mode.get() {
    t3.tap(100.0, 200.0)
    to_bar_rest(t3)
  }
  assert_tab0_concentric_at_rest(t3, "left-drag panel pull")
  t3.assert_idle()
}
