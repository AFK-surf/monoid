///|
test "motion_probe: check_smooth_fade passes smooth curve and rejects hard cut" {
  let smooth : Array[(Double, Double)] = [
    (0.0, 1.0),
    (16.0, 0.85),
    (32.0, 0.65),
    (48.0, 0.42),
    (64.0, 0.22),
    (80.0, 0.08),
    (96.0, 0.0),
  ]
  assert_true(check_smooth_fade(smooth, from=1.0, to=0.0) is Ok(_))

  let hard_cut : Array[(Double, Double)] = [(0.0, 1.0), (16.0, 0.0), (32.0, 0.0)]
  assert_true(check_smooth_fade(hard_cut, from=1.0, to=0.0) is Err(_))

  let instant_zero : Array[(Double, Double)] = [(0.0, 0.0), (16.0, 0.0), (32.0, 0.0)]
  assert_true(check_smooth_fade(instant_zero, from=1.0, to=0.0) is Err(_))
}

///|
test "motion_probe: check_no_stall passes responsive start and rejects dead stall" {
  let responsive : Array[(Double, Double)] = [
    (0.0, 400.0),
    (16.0, 400.0),
    (32.0, 400.0),
    (48.0, 396.0),
    (64.0, 380.0),
  ]
  assert_true(check_no_stall(responsive, delay_ms=40.0, start_window_ms=40.0, min_delta=1.5) is Ok(_))

  let stalled : Array[(Double, Double)] = [
    (0.0, 400.0),
    (16.0, 400.0),
    (32.0, 400.0),
    (48.0, 400.0),
    (64.0, 400.0),
    (80.0, 400.0),
    (96.0, 380.0),
  ]
  assert_true(check_no_stall(stalled, delay_ms=40.0, start_window_ms=40.0, min_delta=1.5) is Err(_))
}

///|
test "motion_probe: check_rect_continuity passes smooth morph and rejects frame-0 height collapse" {
  let start = (100.0, 300.0, 600.0, 140.0)
  let smooth : Array[(Double, (Double, Double, Double, Double))] = [
    (0.0, (100.0, 300.0, 600.0, 140.0)),
    (16.0, (100.0, 340.0, 600.0, 130.0)),
    (32.0, (100.0, 385.0, 600.0, 118.0)),
    (48.0, (100.0, 430.0, 600.0, 105.0)),
  ]
  assert_true(check_rect_continuity(smooth, start_rect=start) is Ok(_))

  // Top-cut / height collapse on frame 0: height suddenly drops from 140 to 56.
  let collapsed : Array[(Double, (Double, Double, Double, Double))] = [
    (0.0, (100.0, 384.0, 600.0, 56.0)),
    (16.0, (100.0, 410.0, 600.0, 56.0)),
  ]
  assert_true(check_rect_continuity(collapsed, start_rect=start) is Err(_))

  // Mid-flight jump > 60pt in one frame.
  let jumped : Array[(Double, (Double, Double, Double, Double))] = [
    (0.0, (100.0, 300.0, 600.0, 140.0)),
    (16.0, (100.0, 420.0, 600.0, 140.0)),
  ]
  assert_true(check_rect_continuity(jumped, start_rect=start) is Err(_))
}

///|
test "motion_probe: Tester::sample_frames advances cleanly and records timestamps" {
  let t = Tester::tree(fn(root) { root.width(Is(Some(100.0))).height(Is(Some(40.0))) |> ignore })
  t.draw()
  let t0 = t.time()
  let samples = t.sample_frames(48.0, step=16.0, fn(tt, elapsed) { (elapsed, tt.time() - t0) })
  assert_eq(samples.length(), 4)
  assert_eq(samples[0].0, 0.0)
  assert_eq(samples[3].0, 48.0)
  assert_true((samples[3].1.1 - 48.0).abs() < 1.0e-6)
}
