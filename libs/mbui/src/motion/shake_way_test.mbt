// A shake (shake_way.mbt): where it is at a moment a function of when it was set off and that moment alone, 0 at both
// ends, none with motion reduced, set off again from a new cause's moment; drawn by a node, the clock followed only
// while it goes.

///|
let shake_from : Double = 1000.0

///|
/// The moments a shake set off at 1000 is looked at: its start, a swing in, its middle, its end, well past it.
let shake_looks : Array[Double] = [0.0, 35.0, 140.0, 280.0, 500.0]

///|
test "a shake's offset at a moment is the same whatever moments were asked before it, 0 where it sets out and ends" {
  let looked = fn(between : Double) {
    let way = @motion.ShakeWay::new()
    way.shake(at=shake_from)
    shake_looks.map(fn(dt) {
      // (moments asked between, as frames at a rate would: none when `between` is 0)
      if between > 0.0 {
        let mut t = shake_from
        while t < shake_from + dt {
          way.offset_at(t, reduced_motion=false) |> ignore
          t = t + between
        }
      }
      way.offset_at(shake_from + dt, reduced_motion=false)
    })
  }
  let jump = looked(0.0)
  for between in [1000.0 / 60.0, 1000.0 / 120.0, 1000.0 / 24.0, 1000.0 / 7.0] {
    assert_eq(looked(between), jump, msg="frames every \{between} ms")
  }
  // (4 × (1 - 1/8) × sin(2π · 3/8) at 35 ms; at 140, halfway, sin(3π) is 0 within a rounding)
  assert_eq(jump[0], 0.0)
  assert_true((jump[1] - 3.5 * @dmath.sin(0.75 * @math.PI)).abs() < 1.0e-9, msg="35 ms: \{jump[1]}")
  assert_true(jump[2].abs() < 1.0e-9, msg="140 ms: \{jump[2]}")
  assert_eq((jump[3], jump[4]), (0.0, 0.0))
  let way = @motion.ShakeWay::new()
  way.shake(at=shake_from)
  assert_eq(
    [-1.0, 0.0, 279.0, 280.0].map(fn(dt) { way.active_at(shake_from + dt, reduced_motion=false) }),
    [false, true, true, false],
  )
}

///|
test "a shake never set off, or with motion reduced, does not go" {
  let way = @motion.ShakeWay::new()
  assert_eq(way.active_at(shake_from, reduced_motion=false), false)
  assert_eq(way.offset_at(shake_from, reduced_motion=false), 0.0)
  way.shake(at=shake_from)
  assert_eq(
    shake_looks.map(fn(dt) {
      (way.active_at(shake_from + dt, reduced_motion=true), way.offset_at(shake_from + dt, reduced_motion=true))
    }),
    shake_looks.map(fn(_) { (false, 0.0) }),
  )
}

///|
test "a shake set off again while it goes sets out from the new moment" {
  let way = @motion.ShakeWay::new(amplitude=6.0, duration_ms=300.0, cycles=2.0)
  let fresh = @motion.ShakeWay::new(amplitude=6.0, duration_ms=300.0, cycles=2.0)
  way.shake(at=shake_from)
  let again = shake_from + 120.0
  way.shake(at=again)
  fresh.shake(at=again)
  assert_eq(way.offset_at(again, reduced_motion=false), 0.0)
  assert_eq(
    [10.0, 75.0, 200.0, 299.0, 300.0].map(fn(dt) { way.offset_at(again + dt, reduced_motion=false) }),
    [10.0, 75.0, 200.0, 299.0, 300.0].map(fn(dt) { fresh.offset_at(again + dt, reduced_motion=false) }),
  )
  // (going till 300 ms after the second, not the first)
  assert_eq(
    (way.active_at(shake_from + 300.0, reduced_motion=false), way.active_at(again + 300.0, reduced_motion=false)),
    (true, false),
  )
}

///|
test "a node shaken as it is pressed: drawn off by the shake at the moment drawn, back and at rest at its end" {
  let t = @ui.Tester::new(fn(_c) {  }, w=200.0, h=200.0)
  t.check_looks(false)
  let way = @motion.ShakeWay::new()
  let node : Ref[@view.View?] = Ref(None)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      node.val = Some(b)
      b
      .width(Is(Some(80.0)))
      .height(Is(Some(40.0)))
      .ground(Is(0x336699FFL))
      .says(Is(Some(@view.said(Button, label="Send"))))
      .on_press(fn() { way.shake(at=b.cause_at()) })
      .offset(
        By(fn() {
          (way.offset_at(b.drawn_while(fn(at) { way.active_at(at, reduced_motion=false) }), reduced_motion=false), 0.0)
        }),
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let tree = @ui.view_tree().unwrap()
  let id = node.val.unwrap().id()
  let x = fn() { tree.drawn_of(id).unwrap().x }
  let still = x()
  t.tap(40.0, 20.0)
  t.run_for(shake_looks[1])
  let mid = x()
  let said = way.offset_at(t.time(), reduced_motion=false)
  t.run_for(way.duration_ms)
  assert_eq(still, 0.0)
  assert_true(said.abs() > 0.5 && (mid - said).abs() < 1.0e-9, msg="mid-way \{mid}, the shake there \{said}")
  assert_eq((x(), t.at_rest()), (0.0, true))
}
