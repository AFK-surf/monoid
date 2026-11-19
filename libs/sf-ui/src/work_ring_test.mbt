// What is at work steps round: a step every 100 ms, the same again after eight; nothing drawn between the steps.

///|
fn ring_tester(f : (@ui.Ctx) -> Unit) -> @ui.Tester {
  @ui.Tester::new(fn(c) { f(c) }, w=100.0, h=100.0)
}

///|
test "work ring and segments: a step every 100 ms, back where they were after eight" {
  for draw in [
    fn(c : @ui.Ctx) { @sf.work_ring(c, 10.0, 0xF2B01EFFL) |> ignore },
    fn(c : @ui.Ctx) { @sf.segments(c, 24.0, 1.5, 0xF57E4DFFL, 0xFFFFFFFFL) |> ignore },
  ] {
    let t = ring_tester(draw)
    t.draw()
    let at = t.drawlist()
    // between two steps, the same
    t.run_for(@sf.work_step_ms / 2.0)
    assert_eq(t.drawlist(), at)
    t.run_for(@sf.work_step_ms / 2.0)
    assert_true(t.drawlist() != at)
    t.run_for(7.0 * @sf.work_step_ms)
    assert_eq(t.drawlist(), at)
  }
}

///|
/// The shapes' bands drawn now (instances of kind 11): each its turn (radians, 0 … 2π), the point it turns about, its
/// rect and its colour as drawn.
fn ring_bands(t : @ui.Tester) -> Array[(Double, Double, Double, (Double, Double, Double, Double), Int64)] {
  let byte = fn(v : Double) { (v * 255.0 + 0.5).to_int64() & 0xFFL }
  let pi2 = 2.0 * 3.141592653589793
  t
  .drawn_instances()
  .filter(fn(a) { a[5] == 11.0 })
  .map(fn(a) {
    let r = a[32] - (a[32] / pi2).floor() * pi2
    let color = (byte(a[8]) << 24) | (byte(a[9]) << 16) | (byte(a[10]) << 8) | byte(a[11])
    (r, a[33], a[34], (a[0], a[1], a[2], a[3]), color)
  })
}

///|
/// The middle of the track's bands (`track`: its colour): the ring's, what it turns about.
fn track_middle(bands : Array[(Double, Double, Double, (Double, Double, Double, Double), Int64)], track : Int64) -> (Double, Double) {
  let mut x0 = 1.0e9
  let mut y0 = 1.0e9
  let mut x1 = -1.0e9
  let mut y1 = -1.0e9
  for b in bands {
    if b.4 == track {
      let (x, y, w, h) = b.3
      x0 = x0.min(x)
      y0 = y0.min(y)
      x1 = x1.max(x + w)
      y1 = y1.max(y + h)
    }
  }
  ((x0 + x1) / 2.0, (y0 + y1) / 2.0)
}

///|
test "at work's ring: its arc turned an eighth of a turn every 100 ms about the ring's middle, none between, back after eight" {
  let ink = 0xE08A00FFL
  let track = @sf.alpha(ink, 0.22)
  let t = ring_tester(fn(c) { @sf.work_ring(c, 10.0, ink, box=12.0) |> ignore })
  t.draw()
  let pi = 3.141592653589793
  // (from whichever step the resident clock is at as it starts)
  let start = ring_bands(t)[0].0
  for k in 0..=8 {
    let bands = ring_bands(t)
    assert_true(bands.iter().any(fn(b) { b.4 == ink }), msg="step \{k}: its arc")
    assert_true(bands.iter().any(fn(b) { b.4 == track }), msg="step \{k}: its track")
    let (mx, my) = track_middle(bands, track)
    let want = start + (k % 8).to_double() * pi / 4.0
    let want = want - (want / (2.0 * pi)).floor() * 2.0 * pi
    for b in bands {
      assert_true((b.0 - want).abs() < 1.0e-9 || (b.0 - want).abs() > 2.0 * pi - 1.0e-9, msg="step \{k}: turned \{b.0}, not \{want}")
      if b.0 != 0.0 {
        assert_true((b.1 - mx).abs() < 1.0e-6 && (b.2 - my).abs() < 1.0e-6, msg="step \{k}: about \{b.1},\{b.2}, not the ring's \{mx},\{my}")
      }
    }
    // (half a step on: nothing drawn anew)
    let at = t.drawlist()
    t.run_for(@sf.work_step_ms / 2.0)
    assert_eq(t.drawlist(), at, msg="step \{k}, half a step on")
    t.run_for(@sf.work_step_ms / 2.0)
  }
}

///|
test "at work's ring with motion reduced: held at its first step, nothing woken for it" {
  let t = @ui.Tester::new(fn(c) { @sf.work_ring(c, 10.0, 0xE08A00FFL) |> ignore }, w=100.0, h=100.0, env=[("MBUI_REDUCE_MOTION", "1")])
  t.draw()
  let at = t.drawlist()
  assert_eq(t.wanted_after(), @double.infinity, msg=t.wanted_why())
  t.run_for(3.0 * @sf.work_step_ms)
  assert_eq(t.drawlist(), at)
  assert_true(ring_bands(t).iter().all(fn(b) { b.0 == 0.0 }))
}
