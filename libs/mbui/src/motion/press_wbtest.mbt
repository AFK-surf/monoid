// A way's speed read where it is drawn (Way::motion_on), a ground bent by it (velocity_capsule), a control's feel under
// the hand (press_feel) and a hold that confirms (hold_way): each a function of its causes and the moment it is looked
// at, the same at every rate of frames and in one jump.

///|
/// Moments the tests here look at: a way's middle, past every way they set off, a hand's way (a hover, a press) whole,
/// a step along a spring's way back, how long a hold here is held to be full, past a hold's way back.
let mid_way_ms : Double = 60.0

///|
let past_it_ms : Double = 2000.0

///|
let hand_whole_ms : Double = 300.0

///|
let spring_step_ms : Double = 25.0

///|
let hold_test_ms : Double = 800.0

///|
let recoil_past_ms : Double = 500.0

///|
test "a way's speed in closed form: as its places a moment apart have it, still once it is there" {
  let w = Way::new(0.0)
  w.go(100.0, motion_spring(0.2, bounce=0.12), at=1000.0)
  let checks = [1020.0, 1050.0, 1090.0, 1150.0].map(fn(t) {
    let (_, v) = w.at(t)
    let h = 0.01
    let fd = (w.value_at(t + h) - w.value_at(t - h)) / (2.0 * h) * 1000.0
    (v - fd).abs() <= dmax(1.0, v.abs() * 0.002)
  })
  let (x, v) = w.at(w.end() + 1.0)
  assert_eq((checks, x, v), ([true, true, true, true], 100.0, 0.0))
}

///|
/// A box 40 by 40 whose alpha reads `way` through Way::motion_on, what it read kept and how often it was worked out.
fn motion_box(way : Way, read : Ref[(Double, Double)], worked : Ref[Int]) -> (@ui.Tester, @view.View) {
  let t = @ui.Tester::new(fn(_c) {  }, w=200.0, h=200.0)
  t.check_looks(false)
  let node : Ref[@view.View?] = Ref(None)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      node.val = Some(b)
      b
      .width(Is(Some(40.0)))
      .height(Is(Some(40.0)))
      .ground(Is(0x3366CCFFL))
      .alpha(
        By(fn() {
          worked.val += 1
          read.val = way.motion_on(b)
          1.0
        }),
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  (t, node.val.unwrap())
}

///|
test "a way read with its speed by a binding: its place and speed at the moment drawn; at rest, its end and none, the clock not followed" {
  let way = Way::new(0.0)
  let read = Ref((0.0, 0.0))
  let worked = Ref(0)
  let (t, b) = motion_box(way, read, worked)
  // (at rest from the start: worked out once, the frames after drawn without it)
  let rest_first = read.val
  let worked_rest = worked.val
  t.frame_at(t.time() + 100.0)
  t.frame_at(t.time() + 100.0)
  let worked_still = worked.val - worked_rest
  let tree = @ui.view_tree().unwrap()
  let t0 = t.time()
  tree.event(t0, fn() { way.go(1.0, motion_spring(0.2, bounce=0.12), at=b.cause_at()) })
  t.run_for(mid_way_ms)
  let mid = read.val
  let want = way.at(t0 + 60.0)
  t.run_for(past_it_ms)
  let end = read.val
  let worked_end = worked.val
  t.frame_at(t.time() + 100.0)
  assert_eq(
    (rest_first, worked_still, mid == want, mid.1 > 0.0, end, worked.val - worked_end),
    ((0.0, 0.0), 0, true, true, (1.0, 0.0), 0),
  )
}

///|
test "a way's speed with motion reduced: there at once, still" {
  let t = @ui.Tester::new(fn(_c) {  }, w=200.0, h=200.0)
  t.set_reduce_motion(true)
  let way = Way::new(0.0)
  way.go(1.0, motion_spring(0.2), at=t.time())
  assert_eq((way.goes_at(t.time()), way.at(t.time())), (false, (1.0, 0.0)))
  t.set_reduce_motion(false)
}

///|
test "a ground bent by its speed: as laid out when still; longer along its way and thinner across, never past its most, a capsule" {
  let still = [
    velocity_capsule(40.0, 20.0, 0.0, 0.0),
    velocity_capsule(0.0, 20.0, 300.0, 0.0),
    velocity_capsule(40.0, 20.0, 300.0, 0.0, most=0.0),
  ]
  let slow = velocity_capsule(20.0, 20.0, 500.0, 0.0)
  let fast = velocity_capsule(20.0, 20.0, 5000.0, 0.0)
  let wild = velocity_capsule(20.0, 20.0, -1.0e9, 0.0)
  let up = velocity_capsule(20.0, 20.0, 0.0, -2000.0)
  let r_of = fn(g : @view.GroundShape) {
    match g.corners {
      Some((a, b, c, d)) => a == b && b == c && c == d && (a - dmin(20.0 + g.dw, 20.0 + g.dh) / 2.0).abs() < 1.0e-12
      None => false
    }
  }
  assert_eq(
    (
      still.all(fn(g) { g == @view.ground_as_laid }),
      slow.dw > 0.0 && slow.dh < 0.0 && fast.dw > slow.dw,
      wild.dw < 20.0 * 0.28 && wild.dw > 20.0 * 0.27,
      slow.dx == -slow.dw / 2.0 && slow.dy == -slow.dh / 2.0,
      up.dh > 0.0 && up.dw < 0.0,
      [slow, fast, wild, up].all(r_of),
    ),
    (true, true, true, true, true, true),
  )
}

///|
/// A control 100 by 40 at the window's top left with a press_feel (its look reads it: what it read kept, as drawn).
fn feel_box(
  seen : Ref[(Double, Double, Double)],
  live? : () -> Bool = fn() { true },
) -> (@ui.Tester, @view.View) {
  let t = @ui.Tester::new(fn(_c) {  }, w=300.0, h=300.0)
  t.check_looks(false)
  let node : Ref[@view.View?] = Ref(None)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      node.val = Some(b)
      b.width(Is(Some(100.0))).height(Is(Some(40.0))).on_press(fn() {  }) |> ignore
      let f = press_feel(b, live~, size=(100.0, 40.0))
      b
      .ground(
        By(fn() {
          seen.val = (f.hovered_on(b), f.pressed_on(b), f.scale_on(b))
          0x3366CCFFL
        }),
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  (t, node.val.unwrap())
}

///|
test "a control's feel: at rest and under the pointer alone drawn as it is laid out; pressed it sinks by points, let go it springs back past its rest and comes to it exactly" {
  @ui.set_pointing(Some(Mouse))
  let seen = Ref((0.0, 0.0, 0.0))
  let (t, _) = feel_box(seen)
  let rest = seen.val
  t.move_to(50.0, 20.0)
  t.run_for(hand_whole_ms)
  let hovered = seen.val
  t.press_at(50.0, 20.0)
  t.run_for(hand_whole_ms)
  let pressed = seen.val
  t.release(50.0, 20.0)
  // (sprung past its rest a little as it comes back: drawn a little bigger for a moment)
  let mut over = false
  for _ in 0..<12 {
    t.run_for(spring_step_ms)
    if seen.val.2 > 1.0 {
      over = true
    }
  }
  t.run_for(past_it_ms)
  let back = seen.val
  @ui.set_pointing(None)
  assert_eq(
    (rest, hovered, pressed.1, (pressed.2 - (1.0 - 1.5 / 100.0)).abs() < 1.0e-9, over, back),
    ((0.0, 0.0, 1.0), (1.0, 0.0, 1.0), 1.0, true, true, (1.0, 0.0, 1.0)),
  )
}

///|
test "a control's feel while it takes no hand: neither lit nor sunk" {
  @ui.set_pointing(Some(Mouse))
  let seen = Ref((0.0, 0.0, 0.0))
  let (t, _) = feel_box(seen, live=fn() { false })
  t.move_to(50.0, 20.0)
  t.press_at(50.0, 20.0)
  t.run_for(hand_whole_ms)
  let held = seen.val
  t.release(50.0, 20.0)
  t.run_for(hand_whole_ms)
  @ui.set_pointing(None)
  assert_eq((held, seen.val), ((0.0, 0.0, 1.0), (0.0, 0.0, 1.0)))
}

///|
/// A control 100 by 40 holding a hold_way of `ms`, how far it has come as drawn kept, how often it was full counted.
fn hold_box(ms : Double, seen : Ref[Double], full : Ref[Int]) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=300.0, h=300.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(100.0))).height(Is(Some(40.0))).on_press(fn() {  }) |> ignore
      let h = hold_way(b, ms, fn() { full.val += 1 })
      b
      .ground(
        By(fn() {
          seen.val = h.progress_on(b)
          0x3366CCFFL
        }),
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "a hold that confirms: its progress a line in time from its press, full and done once at its length, as long with motion reduced; let go once full, none at once" {
  let run = fn(reduced : Bool) {
    let seen = Ref(0.0)
    let full = Ref(0)
    let t = hold_box(hold_test_ms, seen, full)
    t.set_reduce_motion(reduced)
    t.press_at(50.0, 20.0)
    t.run_for(hold_test_ms / 2.0)
    let half = seen.val
    let done_half = full.val
    t.run_for(hold_test_ms / 2.0)
    let at_end = (seen.val, full.val)
    t.run_for(recoil_past_ms)
    let after = (seen.val, full.val)
    t.release(50.0, 20.0)
    t.run_for(mid_way_ms)
    let let_go = seen.val
    t.run_for(recoil_past_ms)
    t.set_reduce_motion(false)
    ((half - 0.5).abs() < 1.0e-9, done_half, at_end, after, let_go, seen.val, full.val)
  }
  assert_eq(run(false), (true, 0, (1.0, 1), (1.0, 1), 0.0, 0.0, 1))
  assert_eq(run(true), (true, 0, (1.0, 1), (1.0, 1), 0.0, 0.0, 1))
}

///|
test "a hold let go short of full: never done, back to none from where it was; held again, on from there" {
  let seen = Ref(0.0)
  let full = Ref(0)
  let t = hold_box(hold_test_ms, seen, full)
  t.press_at(50.0, 20.0)
  t.run_for(hold_test_ms / 4.0)
  let quarter = seen.val
  t.release(50.0, 20.0)
  t.run_for(mid_way_ms)
  let going_back = seen.val
  t.run_for(recoil_past_ms)
  let back = seen.val
  t.press_at(50.0, 20.0)
  t.run_for(hold_test_ms / 2.0)
  let again = seen.val
  t.run_for(hold_test_ms / 2.0)
  assert_eq(
    (
      (quarter - 0.25).abs() < 1.0e-9,
      going_back < quarter && going_back > 0.0,
      back,
      (again - 0.5).abs() < 1.0e-9,
      seen.val,
      full.val,
    ),
    (true, true, 0.0, true, 1.0, 1),
  )
}

///|
test "a control tapped, down and up at one moment: back at rest at once, nothing of its press left due" {
  @ui.set_pointing(Some(Finger))
  let seen = Ref((0.0, 0.0, 0.0))
  let (t, _) = feel_box(seen)
  t.tap(50.0, 20.0)
  let due = t.next_wake()
  t.assert_idle()
  @ui.set_pointing(None)
  assert_eq((due is None, seen.val), (true, (0.0, 0.0, 1.0)))
}

///|
/// A control 100 by 40, 20 down, in a list 200 tall that scrolls (600 under it), its press's look as drawn kept in
/// `seen` (how far pressed, how big its node is drawn); a finger's.
fn scrolled_feel(seen : Ref[(Double, Double)]) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=320.0, h=200.0, platform=2)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(v) {
      v.height(Is(Some(200.0))) |> ignore
      v.scrolls(@view.Scroll::list(), fn(s) {
        s.box(fn(gap) { gap.height(Is(Some(20.0))) |> ignore }) |> ignore
        s.box(fn(b) {
          b.width(Is(Some(100.0))).height(Is(Some(40.0))).on_press(fn() {  }) |> ignore
          let f = press_feel(b, size=(100.0, 40.0))
          b
          .ground(
            By(fn() {
              seen.val = (f.pressed_on(b), f.scale_on(b))
              0x3366CCFFL
            }),
          )
          |> ignore
        })
        |> ignore
        s.box(fn(tall) { tall.height(Is(Some(600.0))) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "a finger's press in what scrolls: sunk once it has stayed; a tap quicker than that, or one going on to scroll, never sunk, at rest after" {
  @ui.set_pointing(Some(Finger))
  // (held: nothing as it is down, sunk once it has stayed)
  let seen = Ref((0.0, 0.0))
  let t = scrolled_feel(seen)
  t.touch(0, 50.0, 40.0)
  t.draw()
  t.run_for(@ui.tap_indication_ms / 2.0)
  let held_early = seen.val
  t.run_for(@ui.tap_indication_ms / 2.0 + hand_whole_ms)
  let held = seen.val
  t.touch(2, 50.0, 40.0)
  t.draw()
  t.run_for(past_it_ms)
  // (a quick tap: never sunk, at rest once let go)
  let t = scrolled_feel(seen)
  t.touch(0, 50.0, 40.0)
  t.draw()
  t.run_for(@ui.tap_indication_ms / 2.0)
  let before = seen.val
  t.touch(2, 50.0, 40.0)
  t.draw()
  let mut sunk = false
  for _ in 0..<6 {
    t.run_for(spring_step_ms / 2.5)
    if seen.val.1 < 1.0 {
      sunk = true
    }
  }
  t.run_for(past_it_ms)
  t.assert_idle()
  let after = seen.val
  // (going on to scroll: never sunk, at any move or as it ends)
  let t = scrolled_feel(seen)
  t.touch(0, 50.0, 40.0)
  t.draw()
  let mut moved_sunk = false
  for i in 1..=10 {
    t.advance(@ui.input_step_ms)
    t.touch(1, 50.0, 40.0 - i.to_double() * 6.0)
    t.draw()
    if seen.val.1 != 1.0 {
      moved_sunk = true
    }
  }
  t.touch(2, 50.0, -20.0)
  t.draw()
  t.run_for(past_it_ms)
  @ui.set_pointing(None)
  assert_eq(
    (held_early, held.0, held.1 < 1.0, before, sunk, after, moved_sunk, seen.val.1),
    ((0.0, 1.0), 1.0, true, (0.0, 1.0), false, (0.0, 1.0), false, 1.0),
  )
}
