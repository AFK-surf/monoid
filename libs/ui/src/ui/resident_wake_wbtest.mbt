// The resident clock's steps (View::cycle_resident) woken for only while what reads it now is drawn: a mark that turned
// and stopped, still shown, wakes nothing; one turning, laid out nowhere (a page over it), wakes nothing either; one
// turning where it is shown, a frame each step.

///|
/// How long a turn of the marks here takes.
let turn_ms : Double = 800.0

///|
/// A second, frames are counted over.
let second_ms : Double = 1000.0

///|
/// Frames drawn over a second from now (the one at its end, Tester::run_for's, among them: 1, none woken for).
fn frames_in_a_second(t : Tester) -> Int {
  let f0 = t.ctx().frame_no
  t.run_for(second_ms)
  t.ctx().frame_no - f0
}

///|
test "the resident clock: woken for while what reads it now is drawn; not for one that stopped reading it, nor for one laid out nowhere" {
  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0, platform=0)
  let a_turns = @signals.signal(true)
  let b_shown = @signals.signal(true)
  set_view_app(fn(root) {
    // A: shown all along, turning while a_turns
    root.box(fn(a) {
      a
      .width(Is(Some(20.0)))
      .height(Is(Some(20.0)))
      .ground(Is(0xFF0000FFL))
      .alpha(By(fn() { if a_turns.get() { 0.5 + 0.5 * a.cycle_resident(turn_ms) } else { 1.0 } }))
      |> ignore
    })
    |> ignore
    // B: turning all along, laid out nowhere once b_shown is not
    root.box(fn(b) {
      b
      .width(Is(Some(20.0)))
      .height(Is(Some(20.0)))
      .ground(Is(0x00FF00FFL))
      .laid_nowhere(By(fn() { !b_shown.get() }))
      .alpha(By(fn() { 0.5 + 0.5 * b.cycle_resident(turn_ms) }))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.run_for(@view.resident_step_ms * 2.0)
  // both shown, both turning: a frame each step
  assert_true(frames_in_a_second(t) >= 8)
  // A stopped (still shown), B laid out nowhere (still turning): none
  a_turns.set(false)
  b_shown.set(false)
  t.draw()
  t.run_for(@view.resident_step_ms * 2.0)
  assert_eq(frames_in_a_second(t), 1)
  // B shown again: a frame each step again
  b_shown.set(true)
  t.draw()
  assert_true(frames_in_a_second(t) >= 8)
}

///|
test "the resident clock: off-screen offset, clipped out, and zero-alpha readers wake nothing until visible again" {
  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0, platform=0)
  let slide_x = @signals.signal(0.0)
  let clip_y = @signals.signal(0.0)
  let fade = @signals.signal(1.0)
  set_view_app(fn(root) {
    // 1. Slid horizontally off-screen (like a closed tape sidebar panel)
    root.box(fn(panel) {
      panel.offset(By(fn() { (slide_x.get(), 0.0) })) |> ignore
      panel.box(fn(a) {
        a
        .width(Is(Some(20.0)))
        .height(Is(Some(20.0)))
        .ground(Is(0xFF0000FFL))
        .alpha(By(fn() { 0.5 + 0.5 * a.cycle_resident(turn_ms) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // 2. Clipped outside an ancestor clip box (like a scrolled-away list row)
    root.box(fn(viewport) {
      viewport.width(Is(Some(100.0))).height(Is(Some(40.0))).clips(Is(true)) |> ignore
      viewport.box(fn(b) {
        b
        .width(Is(Some(20.0)))
        .height(Is(Some(20.0)))
        .offset(By(fn() { (0.0, clip_y.get()) }))
        .ground(Is(0x00FF00FFL))
        .alpha(By(fn() { 0.5 + 0.5 * b.cycle_resident(turn_ms) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // 3. Zero-alpha ancestor
    root.box(fn(holder) {
      holder.alpha(By(fn() { fade.get() })) |> ignore
      holder.box(fn(c) {
        c
        .width(Is(Some(20.0)))
        .height(Is(Some(20.0)))
        .ground(Is(0x0000FFFFL))
        .alpha(By(fn() { 0.5 + 0.5 * c.cycle_resident(turn_ms) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.run_for(@view.resident_step_ms * 2.0)
  assert_true(frames_in_a_second(t) >= 8)
  // Hide all three off-screen / clipped / transparent: zero extra frames woken
  slide_x.set(-400.0)
  clip_y.set(300.0)
  fade.set(0.0)
  t.draw()
  t.run_for(@view.resident_step_ms * 2.0)
  assert_eq(frames_in_a_second(t), 1)
  // Slide first back on-screen: wakes again immediately
  slide_x.set(0.0)
  t.draw()
  assert_true(frames_in_a_second(t) >= 8)
  slide_x.set(-400.0)
  t.draw()
  t.run_for(@view.resident_step_ms * 2.0)
  assert_eq(frames_in_a_second(t), 1)
  // Scroll second back into clip viewport: wakes again immediately
  clip_y.set(10.0)
  t.draw()
  assert_true(frames_in_a_second(t) >= 8)
  clip_y.set(300.0)
  t.draw()
  t.run_for(@view.resident_step_ms * 2.0)
  assert_eq(frames_in_a_second(t), 1)
  // Restore third's alpha: wakes again immediately
  fade.set(1.0)
  t.draw()
  assert_true(frames_in_a_second(t) >= 8)
}

///|
test "the resident clock: step boundaries stay exact before the next step" {
  let t = Tester::new(fn(_c) {  }, w=200.0, h=100.0, platform=0)
  set_view_app(fn(root) {
    root.box(fn(a) {
      a
      .width(Is(Some(20.0)))
      .height(Is(Some(20.0)))
      .ground(Is(0xFF0000FFL))
      .alpha(By(fn() { 0.5 + 0.5 * a.cycle_resident(turn_ms) }))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let tree = view_tree().unwrap()
  tree.at(99.6)
  assert_eq(tree.resident_next(), 100.0)
  tree.at(100.0)
  assert_eq(tree.resident_next(), 200.0)
}
