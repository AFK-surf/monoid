///|
test "Spec::Moved turned back keeps start position and velocity and brakes across multiple frames" {
  let cases : Array[(String, Spec, Double, Double, Double)] = [
    ("moved(points=300)", moved(points=300.0), 0.5, 0.0, 1.5),
    ("moved(over=278) normalized", moved(over=278.0), 0.35, 1.0, -1.8),
  ]
  for c in cases {
    let (name, spec, from, to, v) = c
    let dur = spec.duration(from, to, v)
    let (x0, v0) = spec.value_at(0.0, dur, from, to, v)
    assert_true(
      (x0 - from).abs() < 1.0e-9,
      msg="\{name}: t=0 position \{x0} != \{from}",
    )
    assert_true(
      (v0 - v).abs() < 1.0e-9,
      msg="\{name}: t=0 velocity \{v0} != \{v}",
    )
    // Must not brake to zero within a single 60fps frame (16ms).
    let (_, v16) = spec.value_at(16.0, dur, from, to, v)
    assert_true(
      v16 * v > 0.0,
      msg="\{name}: stopped dead within 16ms (v16=\{v16}, v=\{v})",
    )
    let (xe, ve) = spec.value_at(dur, dur, from, to, v)
    assert_eq(xe, to)
    assert_eq(ve, 0.0)
  }
}

///|
test "Spec::Moved forward and from-rest match moved_ms and move_path exactly" {
  let cases : Array[(Double, Double, Double, Double, Double)] = [
    (300.0, -1.0, 0.0, 1.0, 0.0),
    (300.0, -1.0, 0.2, 1.0, 1.2),
    (1.0, 278.0, 0.0, 1.0, 0.0),
    (1.0, 278.0, 0.4, 1.0, 1.5),
    (1.0, -1.0, 20.0, 200.0, 0.0),
    (1.0, -1.0, 20.0, 200.0, 120.0),
  ]
  for c in cases {
    let (per, over, from, to, v) = c
    let spec = Moved(per, over, 0.0)
    let expected_dur = moved_ms(per, over, from, to)
    let dur = spec.duration(from, to, v)
    assert_eq(dur, expected_dur)
    for t in [0.0, 16.0, 50.0, 120.0, expected_dur] {
      let (got_x, got_v) = spec.value_at(t, dur, from, to, v)
      if t >= @ui.gone_ms(dur) {
        assert_eq(got_x, to)
        assert_eq(got_v, 0.0)
      } else {
        let (x, xv) = @ui.move_path(from - to, v / 1000.0, t, expected_dur)
        assert_eq(got_x, to + x)
        assert_eq(got_v, xv * 1000.0)
      }
    }
  }
}

///|
test "Spec::Moved mid-way reversal passes Tester motion smoothness" {
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=200.0)
  t.check_looks(false)
  let way = NodeWay::new(0.0)
  let node : Ref[@view.View?] = Ref(None)
  @ui.set_view_app(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(b) {
      node.val = Some(b)
      b
      .width(By(fn() { Some(80.0 + way.shown(b) * 278.0) }))
      .height(Is(Some(40.0)))
      .ground(Is(0xFF3366FFL))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let tree = @ui.view_tree().unwrap()
  let b = node.val.unwrap()
  let spec = moved(over=278.0)
  let t0 = t.time()
  tree.event(t0, fn() { way.go(b, 1.0, spec) })
  let mid = @ui.move_ms(278.0) / 2.0
  t.run_for(mid)
  let t1 = t.time()
  tree.event(t1, fn() { way.go(b, 0.0, spec) })
  let back_ms = way.ends_at() - t1
  t.run_for(back_ms)
  assert_true((way.value_at(t.time()) - 0.0).abs() < 1.0e-6)
}
