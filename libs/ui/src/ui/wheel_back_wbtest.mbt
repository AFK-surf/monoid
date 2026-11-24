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

///|
test "Mac trackpad: vertical scroll momentum followed immediately by a right swipe starts a new burst and goes back" {
  let (t, nav) = wheel_back_stack()
  wheel_back_sweep(t, 300.0, 100.0, 0.0, 30.0, 4, phase=1)
  wheel_back_sweep(t, 300.0, 100.0, 0.0, 12.0, 3, phase=3)
  // (no pause: fingers touch down again while momentum is still arriving)
  wheel_back_sweep(t, 300.0, 100.0, -20.0, 0.0, 5, phase=1)
  wheel_back_sweep(t, 300.0, 100.0, -18.0, 0.0, 1, phase=3)
  wheel_back_sweep(t, 300.0, 100.0, -6.0, 0.0, 2, phase=3)
  t.run_for(move_most_ms)
  assert_eq(nav.depth(), 1)
}

///|
test "Mac trackpad: two consecutive right swipes on a 3-page stack without pausing pop both pages" {
  let nav = Nav::new("a")
  nav.push("b")
  nav.push("c")
  nav.settle()
  nav.finger.set(0.0)
  let t = Tester::new(fn(_c) {  }, w=1000.0, h=400.0, platform=0)
  set_view_app(fn(root) {
    nav_view(root, nav, fn(_c, _p) {  }) |> ignore
  })
  t.draw()
  // (first swipe + momentum: pops "c", remaining momentum is Spent while "c" finishes sliding out, with no pause)
  wheel_back_sweep(t, 300.0, 100.0, -20.0, 0.0, 5, phase=1)
  wheel_back_sweep(t, 300.0, 100.0, -18.0, 0.0, 1, phase=3)
  for _ in 0..<25 {
    wheel_back_sweep(t, 300.0, 100.0, -4.0, 0.0, 1, phase=3)
    t.draw()
  }
  assert_eq(nav.depth(), 2)
  // (no pause: second swipe begins right after momentum)
  wheel_back_sweep(t, 300.0, 100.0, -20.0, 0.0, 5, phase=1)
  wheel_back_sweep(t, 300.0, 100.0, -18.0, 0.0, 1, phase=3)
  t.run_for(move_most_ms)
  assert_eq(nav.depth(), 1)
}

///|
test "phase-0 host: decaying momentum releases past back_far before the tail finishes without waiting for stillness" {
  let (t, nav) = wheel_back_stack()
  wheel_back_sweep(t, 300.0, 100.0, -20.0, 0.0, 6)
  assert_true(wheel_back.val.sweep == Back, msg="steady sweep stays in Back")
  let tail : Array[Double] = [-18.0, -16.0, -14.0, -12.0, -10.0, -8.0, -6.0, -4.0, -2.0]
  let mut released_at = -1
  for i in 0..<tail.length() {
    wheel_back_sweep(t, 300.0, 100.0, tail[i], 0.0, 1)
    if wheel_back.val.sweep == Spent && released_at < 0 {
      released_at = i
    }
  }
  assert_true(released_at >= 0 && released_at < tail.length() - 1, msg="released_at=\{released_at}")
  t.run_for(move_most_ms)
  assert_eq(nav.depth(), 1)
}

///|
test "phase-0 host: uneven slow drag below back_far keeps following in Back without premature release" {
  let (t, nav) = wheel_back_stack()
  let steps : Array[Double] = [-20.0, -6.0, -18.0, -5.0, -16.0, -6.0, -14.0, -5.0]
  for dx in steps {
    wheel_back_sweep(t, 300.0, 100.0, dx, 0.0, 1)
    assert_true(wheel_back.val.sweep == Back, msg="stays in Back below back_far")
    assert_true(nav.offset() > 0.0, msg="page keeps following")
  }
  t.run_for(wheel_back_still_ms + move_most_ms * 2.0)
  assert_eq(nav.depth(), 2)
}

///|
test "phase-0 host: light flick crossing back_far during decaying momentum releases on the crossing wheel" {
  let (t, nav) = wheel_back_stack()
  // (finger segment: 4 * 24 = 96 < back_far=120)
  wheel_back_sweep(t, 300.0, 100.0, -24.0, 0.0, 4)
  assert_true(wheel_back.val.sweep == Back)
  // (decaying momentum: -14 brings across to 110 < 120 -> still Back; -12 crosses to 122 >= 120 with speed <= 0.7*peak -> Spent)
  wheel_back_sweep(t, 300.0, 100.0, -14.0, 0.0, 1)
  assert_true(wheel_back.val.sweep == Back, msg="still Back at across=110")
  wheel_back_sweep(t, 300.0, 100.0, -12.0, 0.0, 1)
  assert_true(wheel_back.val.sweep == Spent, msg="released on the wheel crossing back_far")
  // (remaining tail is ignored as Spent)
  wheel_back_sweep(t, 300.0, 100.0, -8.0, 0.0, 3)
  t.run_for(move_most_ms)
  assert_eq(nav.depth(), 1)
}

///|
/// A window with both back (Nav stack "a" -> "b") and forward (a node taking forward while `can_fwd` holds), plus a
/// box at x >= 600 taking wheel directly and an optional modal overlay.
fn wheel_bidir_stack(
  can_fwd : @signals.Signal[Bool],
  fwd_steps : Array[BackStep],
  modal? : @signals.Signal[Bool] = @signals.signal(false),
  on_wheel? : (@view.Wheel) -> Unit = fn(_) {  },
) -> (Tester, Nav[String]) {
  let nav = Nav::new("a")
  nav.push("b")
  nav.settle()
  nav.finger.set(0.0)
  let t = Tester::new(fn(_c) {  }, w=1000.0, h=400.0, platform=0)
  set_view_app(fn(root) {
    root.box(fn(m) {
      m.width(Is(Some(900.0))).height(Is(Some(300.0))) |> ignore
      m.follows_forward(when=fn() { can_fwd.get() }, fn(s) { fwd_steps.push(s) }) |> ignore
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
      m.show(fn() { modal.get() }, fn(o) { o.over(Is(true)).modal(Is(true)) |> ignore })
    })
    |> ignore
  })
  t.draw()
  (t, nav)
}

///|
test "two fingers swept left over a node taking forward: follows across, reverses on right delta, and lets go when still" {
  let can_fwd = @signals.signal(true)
  let steps : Array[BackStep] = []
  let (t, nav) = wheel_bidir_stack(can_fwd, steps)
  wheel_back_sweep(t, 300.0, 100.0, 20.0, 0.0, 3)
  assert_true(wheel_back.val.sweep == Forward, msg="enters Forward on dx > 0")
  assert_eq(nav.offset(), 0.0, msg="back stack untouched")
  // (reverse delta pulls across back)
  wheel_back_sweep(t, 300.0, 100.0, -15.0, 0.0, 1)
  assert_true(wheel_back.val.sweep == Forward, msg="stays in Forward on partial reverse")
  t.run_for(wheel_back_still_ms + move_most_ms)
  assert_true(steps.length() >= 4, msg="Began + Moveds + LetGo: \{steps.length()}")
  match (steps[0], steps[steps.length() - 1]) {
    (Began(x0, _), LetGo(x1, _)) => assert_true((x1 - x0 - 45.0).abs() < 0.01, msg="net across 60 - 15 = 45: \{x1 - x0}")
    _ => fail("expected Began and LetGo")
  }
}

///|
test "two fingers swept left: ignored when nothing takes forward, over a wheel handler, on mouse notches, Shift, or vertical scroll" {
  let can_fwd = @signals.signal(false)
  let steps : Array[BackStep] = []
  let (t, _) = wheel_bidir_stack(can_fwd, steps)
  wheel_back_sweep(t, 300.0, 100.0, 20.0, 0.0, 8)
  t.run_for(wheel_back_still_ms + move_most_ms)
  assert_eq(steps.length(), 0, msg="nothing takes forward")

  let cases : Array[(String, Double, Double, Double, Int)] = [
    ("up and down first", 300.0, 20.0, 30.0, 0),
    ("mouse notches", 300.0, 40.0, 0.0, 4),
    ("Shift held", 300.0, 20.0, 0.0, wheel_mod_shift * 16),
    ("over wheel handler", 700.0, 20.0, 0.0, 0),
  ]
  for case in cases {
    let (what, x, dx, dy, phase) = case
    let ok = @signals.signal(true)
    let got : Array[BackStep] = []
    let received : Array[(Double, Double)] = []
    let (t2, _) = wheel_bidir_stack(ok, got, on_wheel=fn(w) { received.push((w.dx, w.dy)) })
    wheel_back_sweep(t2, x, 100.0, dx, dy, 8, phase~)
    t2.run_for(wheel_back_still_ms + move_most_ms)
    assert_eq(got.length(), 0, msg=what)
    if what == "over wheel handler" {
      assert_eq(received.length(), 8, msg="wheel handler receives all deltas")
    }
  }
}

///|
test "Mac trackpad: left swipe releases immediately on momentum (phase 3), and back-then-forward works without pausing" {
  let can_fwd = @signals.signal(true)
  let steps : Array[BackStep] = []
  let (t, nav) = wheel_bidir_stack(can_fwd, steps)
  // (swipe right to go back + momentum)
  wheel_back_sweep(t, 300.0, 100.0, -20.0, 0.0, 5, phase=1)
  wheel_back_sweep(t, 300.0, 100.0, -18.0, 0.0, 1, phase=3)
  wheel_back_sweep(t, 300.0, 100.0, -6.0, 0.0, 2, phase=3)
  // (immediately swipe left with no pause: kind 1 after kind 3 starts a new burst -> Forward)
  wheel_back_sweep(t, 300.0, 100.0, 20.0, 0.0, 5, phase=1)
  assert_true(wheel_back.val.sweep == Forward, msg="new burst enters Forward immediately")
  wheel_back_sweep(t, 300.0, 100.0, 18.0, 0.0, 1, phase=3)
  assert_true(wheel_back.val.sweep == Spent, msg="momentum releases Forward to Spent")
  let count_at_release = steps.length()
  wheel_back_sweep(t, 300.0, 100.0, 6.0, 0.0, 3, phase=3)
  assert_eq(steps.length(), count_at_release, msg="remaining momentum ignored in Spent")
  t.run_for(move_most_ms)
  assert_eq(nav.depth(), 1, msg="back committed")
  assert_true(steps[steps.length() - 1] is LetGo(_, _), msg="forward committed on momentum")
}

///|
test "phase-0 host: decaying forward momentum releases past back_far without waiting for stillness" {
  let can_fwd = @signals.signal(true)
  let steps : Array[BackStep] = []
  let (t, _) = wheel_bidir_stack(can_fwd, steps)
  wheel_back_sweep(t, 300.0, 100.0, 20.0, 0.0, 6)
  assert_true(wheel_back.val.sweep == Forward, msg="steady sweep stays in Forward")
  let tail : Array[Double] = [18.0, 16.0, 14.0, 12.0, 10.0, 8.0, 6.0, 4.0, 2.0]
  let mut released_at = -1
  for i in 0..<tail.length() {
    wheel_back_sweep(t, 300.0, 100.0, tail[i], 0.0, 1)
    if wheel_back.val.sweep == Spent && released_at < 0 {
      released_at = i
    }
  }
  assert_true(released_at >= 0 && released_at < tail.length() - 1, msg="released_at=\{released_at}")
  assert_true(steps[steps.length() - 1] is LetGo(_, _), msg="forward LetGo delivered on early release")
}

///|
test "modal overlay blocks forward swipe and calls off an active forward swipe" {
  let can_fwd = @signals.signal(true)
  let modal = @signals.signal(true)
  let steps : Array[BackStep] = []
  let (t, _) = wheel_bidir_stack(can_fwd, steps, modal~)
  wheel_back_sweep(t, 300.0, 100.0, 20.0, 0.0, 5)
  assert_eq(steps.length(), 0, msg="modal blocks new forward swipe")
  modal.set(false)
  t.draw()
  t.advance(wheel_back_still_ms)
  wheel_back_sweep(t, 300.0, 100.0, 20.0, 0.0, 3)
  assert_true(wheel_back.val.sweep == Forward)
  modal.set(true)
  t.draw()
  assert_true(steps[steps.length() - 1] == CalledOff, msg="modal cancels active forward swipe")
}
