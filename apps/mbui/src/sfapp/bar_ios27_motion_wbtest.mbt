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
    let tl = bar.tap_lens.value_at(s)
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
  assert_eq(bar.tap_lens.value_at(t.time()), 0.0)
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
    let tl = bar.tap_lens.value_at(u)
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
  assert_eq(bar.tap_lens.value_at(t.time()), 0.0)
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
fn ios27_tap_sample(period : Double?) -> (Double, Double, Double) {
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
  (a.cx, a.stretch, a.held)
}

///|
test "bar ios27: tap flight cx, stretch, and tap-lens held are strictly FPS-invariant across 60/120/24 fps and single jump" {
  if @ui.test_at_a_rate() {
    return
  }
  let jump = ios27_tap_sample(None)
  let at60 = ios27_tap_sample(Some(ios27_frame_ms_60))
  let at120 = ios27_tap_sample(Some(ios27_frame_ms_120))
  let at24 = ios27_tap_sample(Some(ios27_frame_ms_24))
  assert_eq((at60, at120, at24), (jump, jump, jump))
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
  assert_eq(bar.tap_lens.value_at(t0), 0.0)
  assert_eq(bar.tap_lens.value_at(t0 + ios27_probe_ms), 0.0)
  assert_eq(bar.ball_held.value_at(t0), 0.0)
  assert_eq(bar.ball_held.value_at(t0 + ios27_probe_ms), 0.0)
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
  let saw_lens = ts.drawn_instances().iter().any(fn(inst) { inst[5] == 6.0 && (inst[7] - -64.0).abs() < 0.01 })
  assert_false(saw_lens, msg="glass_solid must not emit clear lens glass instance")
  ts.release(xs2[0], y2)
  to_bar_rest(ts)
  @ui.set_glass_solid(None)
}

///|
test "bar ios27: tap_lens ends at rest and programmatic tab switch triggers no droplet or pending tap leak" {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  // Cross-tab tap 0 -> 3 and settle
  t.tap(xs[3], y)
  to_bar_rest(t)
  let rest_t = t.time()
  assert_true(bar.tap_lens.ends_at() <= rest_t, msg="tap_lens.ends_at() \{bar.tap_lens.ends_at()} > rest_t \{rest_t}")
  // Tap already-active tab (no switch), then programmatically switch back to chats (index 0): must not leak tap_lens
  let cs_closed = bar_centres(bar_laid_now().w, bar.k_at(rest_t), bar_laid_now().items.length())
  t.tap(cs_closed[3] + 22.0, y)
  let before_prog = t.time()
  let ends_before = bar.tap_lens.ends_at()
  assert_true(@sfbase.go_place("chats"))
  t.draw()
  assert_eq(bar.tap_lens.value_at(before_prog + ios27_probe_ms), 0.0)
  assert_true(
    bar.tap_lens.ends_at() <= ends_before,
    msg="programmatic switch triggered tap_lens: ends_at=\{bar.tap_lens.ends_at()} vs before=\{ends_before}",
  )
  to_bar_rest(t)
}
