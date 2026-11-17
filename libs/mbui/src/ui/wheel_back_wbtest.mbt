// A trackpad's two fingers swept right over a page whose stack takes its back (wheel_back.mbt): back as a finger from
// the edge goes back, let go once the wheel is still, or as the host says the momentum begins; never by what scrolls
// up and down, a mouse's notches, a key held, or over what takes the wheel itself.

///|
/// A stack of "a" and "b", "b" at rest in a page 900 wide (its back the stack's), and, beside it from x 600, a box that
/// takes the wheel whatever it does (a picture, a remote screen).
fn wheel_back_stack(on_wheel? : (@view.Wheel) -> Unit = fn(_) {  }) -> (Tester, Nav[String]) {
  let nav = Nav::new("a")
  nav.push("b")
  nav.settle()
  nav.finger.set(0.0)
  let t = Tester::new(fn(_c) {  }, w=1000.0, h=400.0, platform=0)
  set_view_app(fn(root) {
    root.box(fn(m) {
      m.width(Is(Some(900.0))).height(Is(Some(300.0))) |> ignore
      nav.backs_over(m, nav.pages[1].serial, 20.0, fn() {  })
      m.box(fn(p) {
        p
        .over(Is(true))
        .offset(Is((600.0, 0.0)))
        .width(Is(Some(200.0)))
        .height(Is(Some(200.0)))
        .on_wheel(on_wheel)
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  (t, nav)
}

///|
/// The wheel at (x, y) as a host gives it, `steps` of it each (`dx`, `dy`) with `phase`, a frame of input apart, said at
/// its own moment.
fn wheel_back_sweep(t : Tester, x : Double, y : Double, dx : Double, dy : Double, steps : Int, phase? : Int = 0) -> Unit {
  for _ in 0..<steps {
    let at = t.fake.time + input_step_ms
    t.advance(input_step_ms)
    t.fake.event_at = at
    finger_wheel(x, y, dx, dy, phase)
    t.fake.event_at = -1.0
  }
}

///|
test "two fingers swept right over a page: it follows them, and still, it goes back past back_far; short of it, it stays" {
  for case in [(20.0, 10, 1), (10.0, 6, 2)] {
    let (by, steps, depth) = case
    let (t, nav) = wheel_back_stack()
    wheel_back_sweep(t, 300.0, 100.0, -by, 0.0, steps)
    let followed = nav.offset()
    t.run_for(wheel_back_still_ms + move_most_ms * 2.0)
    // (as far across as the wheel went, less its slop's first steps, of 900)
    assert_true(followed > 0.0, msg="followed \{followed}")
    assert_eq(nav.depth(), depth, msg="\{by * steps.to_double()} across")
  }
}

///|
test "a Mac's trackpad: let go as its momentum begins, as fast as the fingers went: flung back from short of back_far" {
  let (t, nav) = wheel_back_stack()
  // (100 across in five of a frame's steps, short of back_far, then its momentum)
  wheel_back_sweep(t, 300.0, 100.0, -20.0, 0.0, 5, phase=1)
  wheel_back_sweep(t, 300.0, 100.0, -18.0, 0.0, 1, phase=3)
  // (its momentum's after it, taken by nothing: the page gone back is not scrolled by it)
  wheel_back_sweep(t, 300.0, 100.0, -6.0, 0.0, 3, phase=3)
  t.run_for(move_most_ms)
  assert_eq(nav.depth(), 1)
  // (the same fingers on a page, which says no momentum: let go once still, at rest by then, short of back_far)
  let (t, nav) = wheel_back_stack()
  wheel_back_sweep(t, 300.0, 100.0, -20.0, 0.0, 5)
  t.run_for(wheel_back_still_ms + move_most_ms * 2.0)
  assert_eq(nav.depth(), 2)
}

///|
test "up and down, a mouse's notches, a key held, or over what takes the wheel: never back" {
  let cases : Array[(String, Double, Double, Double, Int)] = [
    ("up and down first", 300.0, -20.0, 30.0, 0),
    ("a mouse's notches", 300.0, -40.0, 0.0, 4),
    ("⇧ held", 300.0, -20.0, 0.0, wheel_mod_shift * 16),
    ("over what takes the wheel", 700.0, -20.0, 0.0, 0),
  ]
  for case in cases {
    let (what, x, dx, dy, phase) = case
    let (t, nav) = wheel_back_stack()
    wheel_back_sweep(t, x, 100.0, dx, dy, 10, phase~)
    assert_eq(nav.offset(), 0.0, msg=what)
    t.run_for(wheel_back_still_ms + move_most_ms)
    assert_eq(nav.depth(), 2, msg=what)
  }
}

///|
test "a burst of the wheel up and down, still, then two fingers swept right: the new burst is a swipe back" {
  let (t, nav) = wheel_back_stack()
  wheel_back_sweep(t, 300.0, 100.0, 0.0, 30.0, 5)
  t.advance(wheel_back_still_ms)
  wheel_back_sweep(t, 300.0, 100.0, -20.0, 0.0, 10)
  t.run_for(wheel_back_still_ms + move_most_ms)
  assert_eq(nav.depth(), 1)
}

///|
test "a wheel handler over a page that takes back gets both original deltas before the swipe can claim them" {
  let received : Array[(Double, Double)] = []
  let (t, nav) = wheel_back_stack(on_wheel=fn(w) { received.push((w.dx, w.dy)) })
  wheel_back_sweep(t, 700.0, 100.0, -40.0, 10.0, 5)
  assert_eq(received, Array::make(5, (-40.0, 10.0)))
  assert_eq(nav.offset(), 0.0)
  t.run_for(wheel_back_still_ms + move_most_ms)
  assert_eq(nav.depth(), 2)
}
