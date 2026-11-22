///|
test "a picture's strip let go: on to the one beside it landing far enough on from its speed, or flung from its edge; else back" {
  // (a picture 390 wide: far 78)
  let s = @ui.move_stop_points(0.2)
  assert_eq(strip_step(-77.0 + s, -0.2, 390.0, false), 0)
  assert_eq(strip_step(-79.0 + s, -0.2, 390.0, false), 1)
  assert_eq(strip_step(77.0 - s, 0.2, 390.0, false), 0)
  assert_eq(strip_step(79.0 - s, 0.2, 390.0, false), -1)
  // (flung from its edge: faster than 0.3, past 10)
  assert_eq(strip_step(-20.0, -0.29, 390.0, true), 0)
  assert_eq(strip_step(-20.0, -0.31, 390.0, true), 1)
  assert_eq(strip_step(-20.0, -0.31, 390.0, false), 0)
}

///|
// A picture or film under a chat's bar or composer opened, its going out from under it as far or further than its
// growing (s >= 0.5): its going out finished short of the way's end and the viewer's ground and bars faded in to all of
// it at the end, never left at none (the user's phone, 2026-11-22: a film opened from under the bar, its ground and
// controls gone).
test "the viewer's flight from under the bar: out and grown and what goes with it from none to all, none of the ground while it is still going out" {
  for s in [0.0, 0.1, 0.25, 0.375, 0.5, 0.65, 0.75, 0.9, 1.0] {
    let (_, grown0) = route_handed(0.0, s)
    assert_eq(grown0, 0.0, msg="s \{s}: grown at the thumbnail")
    assert_eq(route_seen(0.0, s), 0.0, msg="s \{s}: seen at the thumbnail")
    assert_eq(route_handed(1.0, s), (1.0, 1.0), msg="s \{s}: at the viewer")
    assert_eq(route_seen(1.0, s), 1.0, msg="s \{s}: seen at the viewer")
    let mut last = (0.0, 0.0, 0.0)
    for k in 0..=20 {
      let q = k.to_double() / 20.0
      let (out, grown) = route_handed(q, s)
      let seen = route_seen(q, s)
      for v in [out, grown, seen] {
        assert_true(v >= 0.0 && v <= 1.0, msg="s \{s}, q \{q}: \{v} outside 0 … 1")
      }
      if k > 0 {
        assert_true(
          out >= last.0 - 1.0e-12 && grown >= last.1 - 1.0e-12 && seen >= last.2 - 1.0e-12,
          msg="s \{s}, q \{q}: \{Repr((out, grown, seen))} after \{Repr(last)}",
        )
      }
      if out < 1.0 {
        assert_eq(seen, 0.0, msg="s \{s}, q \{q}: the ground seen while still going out (\{out})")
      }
      last = (out, grown, seen)
    }
    if s > 0.0 {
      let l = route_out_end(s)
      assert_true(l <= 0.75, msg="s \{s}: out ends at \{l}")
      assert_eq(route_handed(l, s).0, 1.0, msg="s \{s}: not out at \{l}")
    }
  }
}
