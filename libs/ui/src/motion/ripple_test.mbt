// A press's ripple (ripple.mbt) as Android's RippleDrawable draws it under Compose's `clickable`, at declared moments.

///|
fn ripple_near(a : Double, b : Double) -> Bool {
  (a - b).abs() <= 1.0e-6
}

///|
/// A 200 × 50 box at the window's corner that ripples as it is pressed (by a finger, unless `pointing` says), on a
/// ground of its own where `ground` is said.
fn ripple_tester(pointing? : @ui.Pointing = Finger, ground? : Int64 = 0L) -> @ui.Tester {
  @ui.Tester::new(
    fn(c) {
      let id = c.id("row")
      c.box(w=Px(200.0), h=Px(50.0), bg=ground, id~, fn() { @motion.ripple(c, id, 0.0) }) |> ignore
    },
    pointing~,
  )
}

///|
/// The veil a pointer's press lays over the 200 × 50 box (its ink, its alpha as drawn), if one is drawn.
fn pointer_veil_drawn(t : @ui.Tester) -> Int64? {
  t
  .drawn_rects()
  .iter()
  .find_first(fn(r) { r.2 == 200.0 && r.3 == 50.0 && (r.4 & 0xFFFFFF00L) == 0L && (r.4 & 0xFFL) > 0L })
  .map(fn(r) { r.4 })
}

///|
/// Its disc's reach at full progress: 2.3 times the box's half diagonal and 10 more.
fn ripple_most() -> Double {
  2.3 * ((200.0 * 200.0 + 50.0 * 50.0).sqrt() / 2.0 + 10.0)
}

///|
test "a press ripples from the finger to the box's middle, held at its middle; let go, it fades out" {
  let t = ripple_tester()
  t.press_at(20.0, 25.0)
  // as the finger goes down, nothing yet (its radius none)
  assert_eq(t.drawn_shadows().length(), 0)
  // its way in over: in the middle, half its reach, faded by a sixth ((.5 − .4) / .6 of .1 black)
  t.run_for(@motion.ripple_enter_ms)
  let s = t.drawn_shadows()
  assert_eq(s.length(), 1)
  let (x, y, w, h, corner, _, colour) = s[0]
  assert_true(ripple_near(x + w / 2.0, 100.0) && ripple_near(y + h / 2.0, 25.0))
  assert_true(ripple_near(w, ripple_most()) && ripple_near(corner, ripple_most() / 2.0))
  assert_eq(colour, 0x00000016L)
  // held: it stays so
  t.run_for(@motion.ripple_enter_ms)
  assert_eq(t.drawn_shadows()[0].6, 0x00000016L)
  // let go: gone by its way out's end
  t.release(20.0, 25.0)
  t.run_for(@motion.ripple_exit_ms)
  assert_eq(t.drawn_shadows().length(), 0)
  t.assert_idle()
}

///|
test "a tap however short is shown whole: its way in, then out" {
  let t = ripple_tester()
  t.tap(180.0, 10.0)
  // half way out (its way in whole first, from the tap's frame or the one after it that says it): in the middle, its
  // progress (its reach's share) near .75, faded by (p − .4) / .6 of .1 black
  t.run_for(@motion.ripple_enter_ms + @motion.ripple_exit_ms / 2.0)
  let s = t.drawn_shadows()
  assert_eq(s.length(), 1)
  let (x, y, w, _, _, _, colour) = s[0]
  assert_true(ripple_near(x + w / 2.0, 100.0) && ripple_near(y + w / 2.0, 25.0))
  let p = w / 2.0 / ripple_most()
  let want_p = 0.5 + 0.5 * @ui.Leave.at(0.5)
  assert_true(p > want_p - 0.08 && p <= want_p + 0.02, msg="progress \{p} (want ~\{want_p})")
  assert_eq(colour & 0xFFL, (26.0 * (1.0 - (p - 0.4) / 0.6)).round().to_int64())
  t.run_for(@motion.ripple_exit_ms)
  assert_eq(t.drawn_shadows().length(), 0)
  t.assert_idle()
}

///|
test "a pointer's press draws no disc: its ink over the whole box evenly, in from the press, out once let go; a click however short shown whole" {
  let t = ripple_tester(pointing=Mouse)
  let whole = @motion.pointer_veil(@motion.ripple_ink)
  // held: in over pointer_enter_ms, then there whole while held
  t.press_at(20.0, 25.0)
  t.run_for(@motion.pointer_enter_ms)
  assert_eq((t.drawn_shadows().length(), pointer_veil_drawn(t)), (0, Some(whole)))
  t.run_for(@motion.pointer_enter_ms)
  assert_eq(pointer_veil_drawn(t), Some(whole))
  // let go: gone by its way out's end
  t.release(20.0, 25.0)
  t.run_for(@motion.pointer_exit_ms / 2.0)
  let half = pointer_veil_drawn(t)
  assert_true(half is Some(c) && (c & 0xFFL) < (whole & 0xFFL), msg="on its way out: \{Repr(half)}")
  t.run_for(@motion.pointer_exit_ms / 2.0)
  assert_eq(pointer_veil_drawn(t), None)
  t.assert_idle()
  // a click let go in its own frame: its way in whole first, then out, gone after pointer_tap_ms
  t.tap(180.0, 10.0)
  t.run_for(@motion.pointer_enter_ms)
  assert_eq((t.drawn_shadows().length(), pointer_veil_drawn(t)), (0, Some(whole)))
  t.run_for(@motion.pointer_exit_ms)
  assert_eq(pointer_veil_drawn(t), None)
  t.assert_idle()
}

///|
test "a pointer's press sinks a box on a ground of its own by pointer_sink, not a row lying in a list or a card" {
  for ground in [0xFFFFFFFFL, 0L] {
    let t = ripple_tester(pointing=Mouse, ground~)
    t.press_at(20.0, 25.0)
    t.run_for(@motion.pointer_enter_ms)
    let held = t.look_of("row").map(fn(l) { l.0 }).unwrap_or(1.0)
    t.release(20.0, 25.0)
    t.run_for(@motion.pointer_tap_ms)
    let after = t.look_of("row").map(fn(l) { l.0 }).unwrap_or(1.0)
    let sunk = if ground == 0L { 1.0 } else { 1.0 - @motion.pointer_sink(200.0, 50.0) }
    assert_true((held - sunk).abs() < 1.0e-9 && (after - 1.0).abs() < 1.0e-9, msg="ground \{ground}: \{held}, \{after}")
    t.assert_idle()
  }
}
