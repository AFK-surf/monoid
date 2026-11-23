// FlipWay: one way for all that moves at a cause, each its share of it, read at any moment (the user's rules of
// 2026-11-10 for what moves in a list: 9, one whole, its height never back and forth; 10, its speed never stepping).

///|
fn fl_item(dy : Double, vy? : Double = 0.0) -> @flex.FlipItem {
  { off: (0.0, dy, 0.0, 0.0), v: (0.0, vy, 0.0, 0.0) }
}

///|
test "from rest: every item's share the same at every moment, all of it there at its end, as long as a Move as far as the furthest" {
  let w = @flex.FlipWay::new(100.0, [fl_item(60.0), fl_item(30.0), fl_item(-20.0)])
  let ends = w.ends()
  assert_true((ends - 100.0 - @flex.move_ms(60.0)).abs() < 0.001, msg="ends at \{ends}")
  for t in [100.0, 150.0, 200.0, 250.0, 300.0] {
    let a = w.drawn(fl_item(60.0), t).0.1
    let b = w.drawn(fl_item(30.0), t).0.1
    assert_true((a - 2.0 * b).abs() < 1.0e-9, msg="at \{t}: \{a} and \{b} not one share")
  }
  assert_true(w.drawn(fl_item(60.0), ends).0.1.abs() < 1.0e-9, msg="not there at its end")
  // (only ever toward its end: never back)
  let mut was = 60.0
  let mut t = 100.0
  while t <= ends {
    let y = w.drawn(fl_item(60.0), t).0.1
    assert_true(y <= was + 1.0e-9, msg="at \{t}: back from \{was} to \{y}")
    was = y
    t = t + 1.0
  }
}

///|
test "set off again on its way: on from where each was and as fast, no step in place or speed" {
  let first = @flex.FlipWay::new(0.0, [fl_item(60.0)])
  let at = 80.0
  let (y, vy) = first.drawn(fl_item(60.0), at)
  // (another 40 comes in at that moment over what is left: one item, off by what is left plus 40, going as fast)
  let item = fl_item(y.1 + 40.0, vy=vy.1)
  let second = @flex.FlipWay::new(at, [item])
  let (y2, v2) = second.drawn(item, at)
  assert_true((y2.1 - (y.1 + 40.0)).abs() < 1.0e-9, msg="set out from \{y2.1}")
  assert_true((v2.1 - vy.1).abs() < 1.0e-6, msg="set out at \{v2.1}, \{vy.1} as it went")
}

///|
test "a way said by its cause: the share gone is its curve's, there at its length" {
  let w = @flex.FlipWay::new(10.0, [fl_item(50.0)], said=(400.0, fn(x) { x * x }))
  assert_true((w.ends() - 410.0).abs() < 1.0e-9)
  let half = w.drawn(fl_item(50.0), 210.0).0.1
  assert_true((half - 50.0 * 0.75).abs() < 1.0e-6, msg="half way through its length \{half}")
  assert_eq(w.drawn(fl_item(50.0), 410.0).0.1, 0.0)
}

///|
test "nothing off: there at once" {
  let w = @flex.FlipWay::new(5.0, [fl_item(0.0)])
  assert_eq(w.ends(), 5.0)
  assert_eq(w.left(5.0).0, 0.0)
}

///|
test "FlipWay::left caches same now and invalidates on new now" {
  let w = @flex.FlipWay::new(100.0, [fl_item(80.0, vy=-0.2)])
  let ends = w.ends()
  for t in [90.0, 100.0, 140.0, 210.0, ends, ends + 50.0] {
    let r1 = w.left(t)
    let r2 = w.left(t)
    assert_eq(r1, r2, msg="repeat call at \{t} must match cached value")
  }
  let a = w.left(130.0)
  let b = w.left(180.0)
  assert_true(a.0 > b.0, msg="cache must invalidate when now advances: \{a.0} vs \{b.0}")
  let c = w.left(130.0)
  assert_eq(a, c, msg="returning to earlier now recomputes identically")
}

///|
test "move_path matches move_at from rest and boundary values" {
  let dur = 300.0
  assert_eq(@flex.move_path(120.0, -0.5, 0.0, dur), (120.0, -0.5))
  assert_eq(@flex.move_path(120.0, -0.5, -10.0, dur), (120.0, -0.5))
  assert_eq(@flex.move_path(120.0, -0.5, dur, dur), (0.0, 0.0))
  assert_eq(@flex.move_path(120.0, -0.5, dur + 5.0, dur), (0.0, 0.0))
  for t in [15.0, 60.0, 150.0, 240.0, 295.0] {
    let (off, vel) = @flex.move_path(-100.0, 0.0, t, dur)
    let expected = -100.0 * (1.0 - @flex.move_at(t / dur))
    assert_true((off - expected).abs() < 1.0e-11, msg="at \{t}: off=\{off} expected=\{expected}")
    assert_true(vel > 0.0, msg="at \{t}: positive velocity toward 0, got \{vel}")
  }
}
