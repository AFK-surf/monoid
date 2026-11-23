///|
test "a sheet let go without detents closes landing past its line, or flicked down however short" {
  let flick = @ui.flung_away
  let stop = @ui.move_stop_points(0.3)
  // (its line 80 down)
  assert_false(@motion.sheet_drag_closes(70.0, 0.0, 80.0))
  assert_true(@motion.sheet_drag_closes(90.0, 0.0, 80.0))
  assert_false(@motion.sheet_drag_closes(79.0 - stop, 0.3, 80.0))
  assert_true(@motion.sheet_drag_closes(81.0 - stop, 0.3, 80.0))
  assert_false(@motion.sheet_drag_closes(10.0, flick - 0.01, 80.0))
  assert_true(@motion.sheet_drag_closes(10.0, flick, 80.0))
}

///|
test "a sheet let go with detents goes to the one nearest where it lands, or a flick's way, or closes" {
  let flick = @ui.flung_away
  let stop = @ui.move_stop_points(0.3)
  // (detents 55% and 94% of a window 1000 tall, closing under 30%)
  let shares = [0.55, 0.94]
  let goes = fn(at, v) { @motion.sheet_goes_to(shares, at, v, 1000.0, 0.3) }
  assert_eq(goes(310.0 + stop, 0.3), Some(0.55))
  assert_eq(goes(290.0 + stop, 0.3), None)
  assert_eq(goes(400.0, flick - 0.01), Some(0.55))
  assert_eq(goes(400.0, flick), None)
  assert_eq(goes(800.0, flick), Some(0.55))
  assert_eq(goes(600.0, -flick), Some(0.94))
  assert_eq(goes(980.0, -flick), Some(0.94))
  assert_eq(goes(760.0, -(flick - 0.01)), Some(0.94))
  assert_eq(goes(740.0, 0.0), Some(0.55))
  assert_eq(goes(900.0, 0.0), Some(0.94))
}

///|
test "a thing a finger moves is drawn longer by its speed, either way, and lower by a fifth of that, each to its most" {
  assert_eq(@motion.speed_stretch(0.0), (0.0, 0.0))
  assert_eq(@motion.speed_stretch(10.0), (16.0, 3.2))
  assert_eq(@motion.speed_stretch(-10.0), (16.0, 3.2))
  // (at most 36 longer, and so at most 6 lower)
  assert_eq(@motion.speed_stretch(25.0), (36.0, 6.0))
  assert_eq(@motion.speed_stretch(-100.0), (36.0, 6.0))
  // (lower reaches its most, 6, at 30 longer: v 18.75)
  assert_eq(@motion.speed_stretch(18.75), (30.0, 6.0))
}
