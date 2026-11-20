///|
test "Choreography: forward staggered tracks, track_delay, ends_at and duration" {
  let ch = @motion.Choreography::new([
    { name: "bar_out", forward: @motion.tween(110.0, ease=Leave), backward: @motion.tween(110.0, ease=Out) },
    { name: "bar_in", forward: @motion.tween(140.0, ease=Out, delay=40.0), backward: @motion.tween(100.0, ease=Out) },
    { name: "scene_out", forward: @motion.tween(160.0, ease=Leave), backward: @motion.tween(140.0, ease=Out) },
  ])
  assert_eq(ch.track_delay("bar_out"), 0.0)
  assert_eq(ch.track_delay("bar_in"), 40.0)
  assert_eq(ch.track_delay("missing"), 0.0)
  assert_eq(ch.ends_at(), -1.0)
  assert_eq(ch.duration(), 180.0)

  ch.start(100.0)
  assert_eq(ch.ends_at(), 280.0)
  assert_eq(ch.duration(), 180.0)
  assert_true(ch.value_at("bar_out", 120.0) > 0.0 && ch.value_at("bar_out", 120.0) < 1.0)
  assert_eq(ch.value_at("bar_in", 120.0), 0.0)
  assert_true(ch.value_at("scene_out", 120.0) > 0.0 && ch.value_at("scene_out", 120.0) < 1.0)
  assert_eq(ch.value_at("bar_out", 210.0), 1.0)
  assert_true(ch.value_at("bar_in", 210.0) > 0.0 && ch.value_at("bar_in", 210.0) < 1.0)
  assert_true(ch.value_at("scene_out", 210.0) > 0.0 && ch.value_at("scene_out", 210.0) < 1.0)
  assert_eq(ch.value_at("bar_in", 280.0), 1.0)
  assert_eq(ch.value_at("scene_out", 280.0), 1.0)
}

///|
test "Choreography: mid-way reverse is continuous with zero jump" {
  let ch = @motion.Choreography::new([
    { name: "scene_out", forward: @motion.tween(160.0, ease=Leave), backward: @motion.tween(140.0, ease=Out) },
    { name: "choices_out", forward: @motion.tween(100.0, ease=Leave), backward: @motion.tween(100.0, ease=Out) },
  ])
  ch.start(0.0)
  let scene_mid = ch.value_at("scene_out", 64.0)
  let choices_mid = ch.value_at("choices_out", 64.0)
  assert_true(scene_mid > 0.05 && scene_mid < 0.95)
  assert_true(choices_mid > 0.05 && choices_mid < 0.95)

  ch.reverse(64.0)
  assert_true((ch.value_at("scene_out", 64.0) - scene_mid).abs() < 1.0e-6)
  assert_true((ch.value_at("choices_out", 64.0) - choices_mid).abs() < 1.0e-6)
  let scene_back = ch.value_at("scene_out", 134.0)
  assert_true(scene_back > 0.0 && scene_back < scene_mid)
  assert_eq(ch.value_at("scene_out", 204.0), 0.0)
  assert_eq(ch.value_at("choices_out", 164.0), 0.0)
}

///|
test "Choreography: reduced_motion snaps immediately" {
  let t = @ui.Tester::tree(fn(_) { () })
  t.set_reduce_motion(true)
  let ch = @motion.Choreography::new([
    { name: "scene_out", forward: @motion.tween(160.0, ease=Leave), backward: @motion.tween(140.0, ease=Out) },
  ])
  ch.start(50.0)
  assert_eq(ch.ends_at(), -1.0)
  assert_eq(ch.value_at("scene_out", 50.0), 1.0)
  ch.reverse(60.0)
  assert_eq(ch.ends_at(), -1.0)
  assert_eq(ch.value_at("scene_out", 60.0), 0.0)
}

///|
test "Choreography: arm and node disposal cleanup without leaking" {
  let show = @signals.signal(true)
  let ch = @motion.Choreography::new([
    { name: "fade", forward: @motion.tween(120.0, ease=Leave), backward: @motion.tween(100.0, ease=Out) },
  ])
  let seen_active : Ref[Bool] = Ref(false)
  let seen_prog : Ref[Double] = Ref(0.0)
  let t = @ui.Tester::tree(fn(root) {
    root.show(fn() { show.get() }, at_once=true, fn(box) {
      box
      .width(Is(Some(100.0)))
      .height(Is(Some(40.0)))
      .alpha(By(fn() {
        seen_active.val = ch.active(box)
        let p = ch.progress(box, "fade")
        seen_prog.val = p
        1.0 - p
      }))
      |> ignore
      ch.start(box.cause_at())
      ch.arm(box)
      ch.arm(box)
    })
  })
  let half_ms = 60.0
  let full_ms = 120.0
  t.draw()
  assert_true(seen_active.val)
  t.run_for(half_ms)
  assert_true(seen_prog.val > 0.05 && seen_prog.val < 0.95)
  show.set(false)
  t.draw()
  t.run_for(full_ms)
  t.assert_idle()
}
