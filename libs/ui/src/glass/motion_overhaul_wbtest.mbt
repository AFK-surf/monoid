// Adversarial and performance tests for Wave 1 Liquid Glass motion overhaul:
// - DampedDrag: symmetric jelly, release early-exit & relative_trip, letting_go/stilling counting,
//   host handover safety, press interrupting slide, FPS invariance (60/120/24/7/4 fps).
// - Segmented: 7-item relative_trip=true 18% release timing, embedded cold/warm 5-tap 0-glass/0-capture,
//   floating track fixed-background 0 delta glass/blur, laid == 0 motion frames, complementary alpha.
// - Switch (liquid_toggle_node): async 200ms/400ms monotonic zero-rollback, controlled=true sync reject,
//   mid-drag Off recovery, mid-hold disabled cleanup, first over-slop move, finger_only_lens=true mouse drag 0-lens,
//   mouse tap & Space 0-glass, three-layer concentricity, symmetric velocity jelly, controlled=false async failure contract.
// - Slider (liquid_slider_node): continuous drag rounding preserves jelly, external slide_to 0 velocity,
//   90pt wide thumb cap <= 110pt, 38pt standard exact 58pt, reduced_motion/glass_solid mid-drag toggle cleanup.

///|
let frame_ms : Double = 16.0

///|
let two_frames_ms : Double = 32.0

///|
let four_frames_ms : Double = 64.0

///|
let sample_early_ms : Double = 40.0

///|
let sample_mid_ms : Double = 120.0

///|
let sample_late_ms : Double = 220.0

///|
let hold_wait_ms : Double = 200.0

///|
let two_stage_settle_ms : Double = 2.0 * @ui.move_most_ms

///|
test "DampedDrag: symmetric jelly for equal left and right speed" {
  let dd_r = DampedDrag::new(0.5, lo=0.0, hi=1.0, held_scale=1.2)
  let dd_l = DampedDrag::new(0.5, lo=0.0, hi=1.0, held_scale=1.2)
  let host : Ref[@view.View?] = Ref(None)
  let t = @ui.Tester::new(fn(_c) {  }, w=320.0, h=120.0, dark=false, platform=0)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(200.0))).height(Is(Some(40.0))) |> ignore
      dd_r.attach(b)
      dd_l.attach(b)
      host.val = Some(b)
    })
    |> ignore
  })
  t.draw()
  let n = host.val.unwrap()
  // Rightward and leftward drags with identical delta and exact same frame timestamps
  dd_r.press()
  dd_l.press()
  dd_r.update_value(0.55)
  dd_l.update_value(0.45)
  t.frame(ms=frame_ms)
  dd_r.update_value(0.85)
  dd_l.update_value(0.15)
  t.run_for(two_frames_ms)
  let (rsx, rsy) = dd_r.jelly(n, 10.0)
  let (lsx, lsy) = dd_l.jelly(n, 10.0)
  assert_true(rsx > dd_r.scale_x.shown(n) && rsy < dd_r.scale_y.shown(n), msg="rightward jelly must stretch x and flatten y")
  assert_true((rsx - lsx).abs() < 1.0e-6, msg="left/right jelly sx must match: \{lsx} vs \{rsx}")
  assert_true((rsy - lsy).abs() < 1.0e-6, msg="left/right jelly sy must match: \{lsy} vs \{rsy}")
}

///|
test "DampedDrag: letting_go & stilling counts, no-lens early exit, host handover, and FPS invariance" {
  // 1. Timer counts: lens-less slide_to schedules 0 letting_go and 0 stilling; held release schedules exactly 1 letting_go; already-at-target schedules 0.
  let dd = DampedDrag::new(0.0, lo=0.0, hi=6.0, held_scale=1.15)
  let host1 : Ref[@view.View?] = Ref(None)
  let host2 : Ref[@view.View?] = Ref(None)
  let show_second = @signals.signal(false)
  let t = @ui.Tester::new(fn(_c) {  }, w=320.0, h=120.0, dark=false, platform=0)
  @ui.set_view_app(fn(root) {
    root.show(fn() { !show_second.get() }, at_once=true, fn(b1) {
      b1.width(Is(Some(100.0))).height(Is(Some(40.0))) |> ignore
      dd.attach(b1)
      host1.val = Some(b1)
    })
    root.show(fn() { show_second.get() }, at_once=true, fn(b2) {
      b2.width(Is(Some(100.0))).height(Is(Some(40.0))) |> ignore
      dd.attach(b2)
      host2.val = Some(b2)
    })
  })
  t.draw()
  let lg0 = dd.letting_go_scheduled
  let st0 = dd.stilling_scheduled
  // Lens-less tap/slide: 0 letting_go, 0 stilling
  dd.slide_to(3.0)
  dd.release()
  assert_eq(dd.letting_go_scheduled - lg0, 0, msg="lens-less slide_to + release must schedule 0 letting_go")
  assert_eq(dd.stilling_scheduled - st0, 0, msg="lens-less slide_to must schedule 0 stilling")
  t.run_for(@ui.move_most_ms)
  t.assert_idle()
  // Held release from 3.0 -> 4.0 with relative_trip=true: exactly 1 letting_go scheduled
  dd.press()
  let lg1 = dd.letting_go_scheduled
  dd.settle_to(4.0, within_frac=0.18, relative_trip=true)
  assert_eq(dd.letting_go_scheduled - lg1, 1, msg="held settle_to over distance must schedule exactly 1 letting_go")
  // Handover to second host while letting_go is pending: must transfer cleanly and never leave press=1 stuck.
  show_second.set(true)
  t.draw()
  t.run_for(two_stage_settle_ms)
  let n2 = host2.val.unwrap()
  assert_true(dd.pressed(n2) < 0.001, msg="host handover must settle press to 0, got \{dd.pressed(n2)}")
  t.assert_idle()
  // Already at target: press + settle_to(same) -> 0 letting_go scheduled
  dd.press()
  let lg2 = dd.letting_go_scheduled
  dd.settle_to(4.0, within_frac=0.18, relative_trip=true)
  assert_eq(dd.letting_go_scheduled - lg2, 0, msg="settle_to already at target must schedule 0 letting_go")
  t.run_for(two_stage_settle_ms)
  t.assert_idle()
  // Small target nudge (<= threshold) while letting_go is pending must reschedule release;
  // repeated same-target slide_to (even with spec) must be idempotent (0 extra timers).
  dd.press()
  let ec0 = dd.value.end_count()
  dd.settle_to(5.0, within_frac=0.18, relative_trip=true)
  let lg_nudge = dd.letting_go_scheduled
  dd.slide_to(5.0005)
  assert_eq(dd.letting_go_scheduled - lg_nudge, 1, msg="small target nudge while letting_go pending must reschedule release")
  let lg_same = dd.letting_go_scheduled
  dd.slide_to(5.0005, spec=@motion.snappy_damped)
  assert_eq(dd.letting_go_scheduled - lg_same, 0, msg="repeated same-target slide_to must be idempotent (0 extra timers)")
  t.run_for(two_stage_settle_ms)
  assert_eq(dd.value.end_count() - ec0, 1, msg="repeated same-target slide_to must emit exactly 1 ended tick")
  assert_true(!dd.value.goes_at(t.time()) && !dd.press.goes_at(t.time()), msg="NodeWays must be at rest after settle")
  t.assert_idle()
  // Live-host handover while press=1 without pending release must drop lens so press never stays stuck.
  let dd_live = DampedDrag::new(0.0, lo=0.0, hi=2.0, held_scale=1.15)
  let live1 : Ref[@view.View?] = Ref(None)
  let live2 : Ref[@view.View?] = Ref(None)
  let t_live = @ui.Tester::new(fn(_c) {  }, w=320.0, h=120.0, dark=false, platform=0)
  @ui.set_view_app(fn(root) {
    root.box(fn(b1) {
      b1.width(Is(Some(80.0))).height(Is(Some(40.0))) |> ignore
      dd_live.attach(b1)
      live1.val = Some(b1)
    })
    |> ignore
    root.box(fn(b2) {
      b2.width(Is(Some(80.0))).height(Is(Some(40.0))) |> ignore
      live2.val = Some(b2)
    })
    |> ignore
  })
  t_live.draw()
  dd_live.press()
  assert_true(dd_live.pressing())
  let lb2 = live2.val.unwrap()
  dd_live.attach(lb2)
  assert_true(!dd_live.pressing(), msg="live-host re-attach must drop active press")
  assert_true(dd_live.pressed(lb2) < 0.001, msg="live-host re-attach must reset pressed to 0")
  t_live.assert_idle()

  // 2. FPS invariance across 60, 120, 24, 7, 4 fps at multiple sample points (exact bitwise equality)
  let sample_at = fn(fps : Int) -> Array[(Double, Double)] {
    let d = DampedDrag::new(0.0, lo=0.0, hi=6.0, held_scale=1.15)
    let vref : Ref[@view.View?] = Ref(None)
    let tf = @ui.Tester::new(fn(_c) {  }, w=320.0, h=120.0, dark=false, platform=0)
    tf.set_frame_period(1000.0 / fps.to_double())
    @ui.set_view_app(fn(root) {
      root.box(fn(b) {
        b.width(Is(Some(100.0))).height(Is(Some(40.0))) |> ignore
        d.attach(b)
        vref.val = Some(b)
      })
      |> ignore
    })
    tf.draw()
    let t0 = tf.time()
    d.press()
    d.settle_to(1.0, within_frac=0.18, relative_trip=true)
    let out : Array[(Double, Double)] = []
    for dt in [sample_early_ms, sample_mid_ms, sample_late_ms] {
      tf.frame_at(t0 + dt)
      let n = vref.val.unwrap()
      out.push((d.value(n), d.pressed(n)))
    }
    tf.run_for(two_stage_settle_ms)
    tf.assert_idle()
    out
  }
  let base = sample_at(60)
  for fps in [120, 24, 7, 4] {
    let got = sample_at(fps)
    for k in 0..<base.length() {
      assert_eq(got[k].0.reinterpret_as_uint64(), base[k].0.reinterpret_as_uint64(), msg="value[\{k}] at \{fps}fps (\{got[k].0}) != 60fps (\{base[k].0})")
      assert_eq(got[k].1.reinterpret_as_uint64(), base[k].1.reinterpret_as_uint64(), msg="pressed[\{k}] at \{fps}fps (\{got[k].1}) != 60fps (\{base[k].1})")
    }
  }
}

///|
test "DampedDrag: press interrupting a glide resets speed to 0 and returns jelly to rest" {
  let dd = DampedDrag::new(0.0, lo=0.0, hi=1.0, held_scale=1.2)
  let host : Ref[@view.View?] = Ref(None)
  let t = @ui.Tester::new(fn(_c) {  }, w=320.0, h=120.0, dark=false, platform=0)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(200.0))).height(Is(Some(40.0))) |> ignore
      dd.attach(b)
      host.val = Some(b)
    })
    |> ignore
  })
  t.draw()
  let n = host.val.unwrap()
  dd.press()
  dd.update_value(0.1)
  t.frame(ms=frame_ms)
  dd.update_value(0.9)
  t.frame(ms=frame_ms)
  assert_true(dd.velocity(n).abs() > 0.1, msg="must have nonzero velocity mid-glide")
  // Interrupt with stationary press: speed target becomes 0 and decays to rest.
  dd.press()
  assert_eq(dd.speed.target(), 0.0, msg="press must reset speed target to 0")
  t.run_for(two_stage_settle_ms)
  assert_true(dd.velocity(n).abs() < 0.01, msg="speed must settle to 0 while held still, got \{dd.velocity(n)}")
  let (sx, sy) = dd.jelly(n, 10.0)
  assert_true((sx - 1.2).abs() < 0.01 && (sy - 1.2).abs() < 0.01, msg="jelly must return to held_scale at rest: (\{sx}, \{sy})")
  dd.drop_lens()
  t.run_for(two_stage_settle_ms)
  t.assert_idle()
}

///|
test "Segmented 7-item drag 1 step: relative_trip=true drops press at 18% remaining distance, not frame 0" {
  let dd = DampedDrag::new(0.0, lo=0.0, hi=6.0, held_scale=ctrl_seg_held_scale)
  let chosen = @signals.signal(0)
  let host : Ref[@view.View?] = Ref(None)
  let t = @ui.Tester::new(fn(_c) {  }, w=560.0, h=120.0, dark=false, platform=0)
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((20.0, 20.0, 20.0, 20.0))) |> ignore
      let seg = liquid_segmented_node(
        page,
        fn() { ["0", "1", "2", "3", "4", "5", "6"] },
        fn() { chosen.get() },
        fn(i) { chosen.set(i) },
        width=490.0,
        height=32.0,
        drag=dd,
        glass_track=false,
      )
      host.val = Some(seg)
    })
    |> ignore
  })
  t.draw()
  let n = host.val.unwrap()
  // Real gesture drag from "0" -> "1" and release: relative_trip=true drops press near 82% (not frame 0).
  let r0 = t.get(Tab, label="0").rect
  let r1 = t.get(Tab, label="1").rect
  let y = r0.1 + r0.3 / 2.0
  t.press_at(r0.0 + r0.2 / 2.0, y)
  t.run_for(hold_wait_ms + two_frames_ms)
  assert_true(dd.pressing(), msg="holding selected item 0 must lift lens")
  // Drag slightly past half into item 1 so value still has distance to travel on release
  let mid_x = r0.0 + r0.2 / 2.0 + (r1.0 - r0.0) * 0.55
  t.move_to(mid_x, y)
  t.release(mid_x, y)
  assert_eq(chosen.get(), 1, msg="drag release past midpoint must commit item 1")
  assert_true(dd.pressing(), msg="press target must stay 1.0 on frame 0 (not immediately dropped)")
  assert_true(dd.has_pending_release(), msg="letting_go must be scheduled for 18% trip point")
  // Step frame by frame and bracket the exact 18% remaining-trip transition between adjacent frames
  let start_val = dd.value(n)
  let trip = (1.0 - start_val).abs()
  assert_true(trip > 0.1, msg="release must have nontrivial remaining trip, got \{trip}")
  let mut prev_val = start_val
  let mut drop_val = -1.0
  for _ in 0..<60 {
    t.run_for(frame_ms)
    let cur = dd.value(n)
    if !dd.pressing() {
      drop_val = cur
      break
    }
    prev_val = cur
  }
  assert_true((1.0 - prev_val).abs() > 0.18 * trip, msg="frame before release must still have >18% trip remaining: rem=\{(1.0 - prev_val).abs()} vs \{0.18 * trip}")
  assert_true((1.0 - drop_val).abs() <= 0.18 * trip, msg="release frame must be within 18% remaining trip: rem=\{(1.0 - drop_val).abs()} vs \{0.18 * trip}")
  t.run_for(two_stage_settle_ms)
  assert_true(dd.pressed(n) < 0.001, msg="final pressed must be 0.0")
  t.assert_idle()
}

///|
test "Segmented performance: embedded cold+warm continuous 5-tap 0-glass/0-blur/0-laid, floating track under_now cache invariance, drawn complementary alpha" {
  let unique_glass_groups = fn(t : @ui.Tester) -> Int {
    let gs : Array[Int] = []
    for g in t.drawn_glass() {
      if !gs.contains(g.5) {
        gs.push(g.5)
      }
    }
    gs.length()
  }
  let unique_blur_groups = fn(t : @ui.Tester) -> Int {
    let gs : Array[Int] = []
    for inst in t.drawn_instances() {
      if (inst[5] == 5.0 || inst[5] == 6.0) && inst[7].abs() > 0.0 {
        let gid = (-inst[20]).to_int()
        if !gs.contains(gid) {
          gs.push(gid)
        }
      }
    }
    gs.length()
  }
  // 1. Embedded (glass_track=false): cold mount + continuous rapid 5-tap (48ms cadence, mid-motion) + warm lens + continuous 5-tap
  let chosen = @signals.signal(0)
  let t = @ui.Tester::new(fn(_c) {  }, w=420.0, h=120.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((20.0, 20.0, 20.0, 20.0))) |> ignore
      liquid_segmented_node(
        page,
        fn() { ["5", "10", "20", "30", "60"] },
        fn() { chosen.get() },
        fn(i) { chosen.set(i) },
        width=350.0,
        height=32.0,
        glass_track=false,
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  // Cold mount frame
  assert_eq(t.drawn_glass().length(), 0, msg="embedded cold mount must have 0 glass")
  assert_eq(unique_glass_groups(t), 0, msg="embedded cold mount must have 0 capture groups")
  assert_eq(unique_blur_groups(t), 0, msg="embedded cold mount must have 0 blur groups")
  let run_5_taps = fn(tag : String) raise {
    let seq = [("10", 3), ("20", 3), ("30", 3), ("60", 6), ("30", 3)]
    for pair in seq {
      let (lbl, wait_frames) = pair
      let r = t.get(Tab, label=lbl).rect
      t.tap(r.0 + r.2 / 2.0, r.1 + r.3 / 2.0)
      assert_eq(t.drawn_glass().length(), 0, msg="\{tag} commit frame \{lbl} must have 0 glass")
      t.tree_frames_from_now()
      // Continuous mid-motion cadence (never waiting for idle between taps)
      for _ in 0..<wait_frames {
        t.run_for(frame_ms)
        assert_eq(t.drawn_glass().length(), 0, msg="\{tag} rapid frame \{lbl} must have 0 glass")
        assert_eq(unique_glass_groups(t), 0, msg="\{tag} rapid frame \{lbl} must have 0 capture groups")
        assert_eq(unique_blur_groups(t), 0, msg="\{tag} rapid frame \{lbl} must have 0 blur groups")
      }
      for f in t.tree_frames() {
        assert_eq(f.laid, 0, msg="\{tag} rapid motion frame \{lbl} must have laid == 0")
      }
    }
    t.tree_frames_from_now()
    let settle_steps = (@ui.move_most_ms / frame_ms).to_int()
    for _ in 0..<settle_steps {
      t.run_for(frame_ms)
      assert_eq(t.drawn_glass().length(), 0, msg="\{tag} settle frame must have 0 glass")
      assert_eq(unique_glass_groups(t), 0, msg="\{tag} settle frame must have 0 capture groups")
      assert_eq(unique_blur_groups(t), 0, msg="\{tag} settle frame must have 0 blur groups")
    }
    for f in t.tree_frames() {
      assert_eq(f.laid, 0, msg="\{tag} settle motion frame must have laid == 0")
    }
    t.assert_idle()
  }
  run_5_taps("embedded cold")
  // Warm cycle: hold selected "30" to mount lens, inspect drawn complementary alpha mid-lift, then release to idle.
  let r30 = t.get(Tab, label="30").rect
  t.press_at(r30.0 + r30.2 / 2.0, r30.1 + r30.3 / 2.0)
  t.run_for(hold_wait_ms + two_frames_ms)
  let mid_lenses = t.drawn_instances().filter(fn(i) { i[5] == 6.0 })
  assert_eq(mid_lenses.length(), 1, msg="warm hold on selected must mount 1 glass lens")
  // Complementary alpha verified from actual drawn instances (glass lens opacity slot [15] + solid thumb alpha [11] >= 0.90)
  let lens_alpha = mid_lenses[0][15]
  assert_true(lens_alpha >= 0.0 && lens_alpha <= 1.0, msg="glass lens opacity slot [15] must be in [0, 1], got \{lens_alpha}")
  let solid_thumbs = t.drawn_instances().filter(fn(i) { i[5] == 0.0 && i[2] >= r30.2 - 12.0 && i[2] <= r30.2 + 24.0 && i[3] >= 20.0 && i[3] <= 40.0 })
  let max_solid_alpha = solid_thumbs.fold(init=0.0, fn(acc, inst) { if inst[11] > acc { inst[11] } else { acc } })
  assert_true(lens_alpha + max_solid_alpha >= 0.90, msg="drawn complementary alpha must not dip: lens=\{lens_alpha}, solid=\{max_solid_alpha}")
  t.release(r30.0 + r30.2 / 2.0, r30.1 + r30.3 / 2.0)
  t.run_for(two_stage_settle_ms)
  t.assert_idle()
  // Return to "5" at rest so embedded warm runs the exact same 5-tap sequence as embedded cold
  let r5 = t.get(Tab, label="5").rect
  t.tap(r5.0 + r5.2 / 2.0, r5.1 + r5.3 / 2.0)
  t.run_for(two_stage_settle_ms)
  t.assert_idle()
  run_5_taps("embedded warm")

  // 2. Floating track (glass_track=true): continuous rapid 5-tap with fixed background ->
  //    every-frame prefix instances & floating track slots (0..4, 5, 7, 14, 20) stay identical (under_now cache hit)
  let chosen2 = @signals.signal(0)
  let t2 = @ui.Tester::new(fn(_c) {  }, w=420.0, h=120.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((20.0, 20.0, 20.0, 20.0))) |> ignore
      liquid_segmented_node(
        page,
        fn() { ["A", "B", "C", "D", "E"] },
        fn() { chosen2.get() },
        fn(i) { chosen2.set(i) },
        width=350.0,
        height=32.0,
        glass_track=true,
      )
      |> ignore
    })
    |> ignore
  })
  t2.draw()
  let baseline_glass = t2.drawn_glass().length()
  let base_groups = unique_glass_groups(t2)
  let base_blur_groups = unique_blur_groups(t2)
  assert_eq(baseline_glass, 1, msg="floating track rest baseline must be 1 glass (track only)")
  assert_eq(base_blur_groups, 1, msg="floating track rest baseline must have 1 blur group")
  let base_insts = t2.drawn_instances()
  let mut glass_idx = -1
  for idx, inst in base_insts {
    if inst[5] == 6.0 {
      glass_idx = idx
      break
    }
  }
  assert_true(glass_idx >= 0, msg="floating track glass instance must exist at rest")
  let base_prefix = base_insts[0:glass_idx].to_owned()
  let base_track = base_insts[glass_idx]
  let check_floating_frame = fn() raise {
    assert_eq(t2.drawn_glass().length() - baseline_glass, 0, msg="floating track tap must add 0 glass instances")
    assert_eq(unique_glass_groups(t2) - base_groups, 0, msg="floating track tap must add 0 capture groups")
    assert_eq(unique_blur_groups(t2) - base_blur_groups, 0, msg="floating track tap must add 0 blur groups")
    let cur_insts = t2.drawn_instances()
    assert_true(cur_insts.length() > glass_idx, msg="floating track index must stay valid")
    // Verify prefix before floating track is byte-identical so under_now backdrop cache hits 100%
    for p in 0..<base_prefix.length() {
      assert_eq(cur_insts[p], base_prefix[p], msg="background prefix instance \{p} before floating track must stay unchanged")
    }
    let cur_track = cur_insts[glass_idx]
    for slot in [0, 1, 2, 3, 4, 5, 7, 14, 20] {
      assert_eq(cur_track[slot], base_track[slot], msg="floating track slot \{slot} must stay unchanged for under_now cache hit")
    }
  }
  for pair in [("B", 3), ("C", 3), ("D", 3), ("E", 6), ("C", 3)] {
    let (lbl, wait_frames) = pair
    let r = t2.get(Tab, label=lbl).rect
    t2.tap(r.0 + r.2 / 2.0, r.1 + r.3 / 2.0)
    check_floating_frame()
    t2.tree_frames_from_now()
    for _ in 0..<wait_frames {
      t2.run_for(frame_ms)
      check_floating_frame()
    }
    for f in t2.tree_frames() {
      assert_eq(f.laid, 0, msg="floating track rapid motion frame \{lbl} must have laid == 0")
    }
  }
  t2.tree_frames_from_now()
  let settle_steps2 = (@ui.move_most_ms / frame_ms).to_int()
  for _ in 0..<settle_steps2 {
    t2.run_for(frame_ms)
    check_floating_frame()
  }
  for f in t2.tree_frames() {
    assert_eq(f.laid, 0, msg="floating track settle motion frame must have laid == 0")
  }
  t2.assert_idle()
}

///|
test "Switch (liquid_toggle_node): async 200ms zero-rollback, controlled reject, Off/disabled, slop, finger_only_lens, 0-glass tap/Space, concentricity" {
  // 1. Async 200ms core write (controlled=false): click -> stays at 1.0 -> 200ms later on.set(true) -> zero rollback
  let on = @signals.signal(false)
  let dd = DampedDrag::new(0.0, lo=0.0, hi=1.0, held_scale=thumb_held_scale)
  let host : Ref[@view.View?] = Ref(None)
  let turns : Array[Bool] = []
  let t = @ui.Tester::new(fn(_c) {  }, w=240.0, h=120.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))) |> ignore
      let sw = liquid_toggle_node(page, fn() { on.get() }, fn(v) { turns.push(v) }, fn() { "AsyncSwitch" }, drag=dd)
      host.val = Some(sw)
    })
    |> ignore
  })
  t.draw()
  let n = host.val.unwrap()
  let r = t.get(Switch, label="AsyncSwitch").rect
  let cx = r.0 + r.2 / 2.0
  let cy = r.1 + r.3 / 2.0
  t.tap(cx, cy)
  assert_eq(turns, [true])
  let mut prev_v = dd.value(n)
  for _ in 0..<12 {
    t.run_for(frame_ms)
    assert_eq(t.drawn_glass().length(), 0, msg="mouse tap on switch must keep 0 glass")
    let cur = dd.value(n)
    assert_true(cur >= prev_v - 1.0e-6, msg="async switch must move monotonically without rollback: \{cur} < \{prev_v}")
    prev_v = cur
  }
  on.set(true)
  t.run_for(@ui.move_most_ms)
  assert_true((dd.value(n) - 1.0).abs() < 0.001)
  t.assert_idle()

  // 2. Pin existing controlled=false async failure behavior (stays at requested until external reset)
  t.tap(cx, cy)
  t.run_for(@ui.move_most_ms)
  assert_true((dd.value(n) - 0.0).abs() < 0.001, msg="controlled=false stays at requested when turn does not update on()")

  // 3. controlled=true sync rejection: fraction stays synced to on() and next drag starts cleanly from 0.0
  let on_c = @signals.signal(false)
  let dd_c = DampedDrag::new(0.0, lo=0.0, hi=1.0, held_scale=thumb_held_scale)
  let disabled_c = @signals.signal(false)
  let t2 = @ui.Tester::new(fn(_c) {  }, w=240.0, h=120.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))) |> ignore
      liquid_toggle_node(
        page,
        fn() { on_c.get() },
        fn(_v) { () }, // sync reject
        fn() { "CtrlSwitch" },
        disabled=fn() { disabled_c.get() },
        controlled=true,
        drag=dd_c,
      )
      |> ignore
    })
    |> ignore
  })
  t2.draw()
  let rc = t2.get(Switch, label="CtrlSwitch").rect
  t2.tap(rc.0 + rc.2 / 2.0, rc.1 + rc.3 / 2.0)
  t2.run_for(@ui.move_most_ms)
  assert_true((dd_c.target() - 0.0).abs() < 0.001, msg="controlled=true reject must remain at 0.0")
  // Mid-drag disabled + Off must still clean up cleanly back to 0.0
  t2.press_at(rc.0 + 10.0, rc.1 + rc.3 / 2.0)
  t2.move_to(rc.0 + 30.0, rc.1 + rc.3 / 2.0)
  t2.run_for(two_frames_ms)
  disabled_c.set(true)
  t2.draw()
  t2.leave()
  t2.run_for(two_stage_settle_ms)
  assert_true((dd_c.target() - 0.0).abs() < 0.001, msg="Off while disabled must still restore 0.0")
  assert_eq(t2.drawn_glass().length(), 0, msg="Off while disabled must drop lens")
  t2.assert_idle()
  // Mid-drag disabled + Up (release) must also drop lens cleanly back to 0.0
  disabled_c.set(false)
  t2.draw()
  t2.press_at(rc.0 + 10.0, rc.1 + rc.3 / 2.0)
  t2.move_to(rc.0 + 30.0, rc.1 + rc.3 / 2.0)
  t2.run_for(two_frames_ms)
  disabled_c.set(true)
  t2.draw()
  t2.release(rc.0 + 30.0, rc.1 + rc.3 / 2.0)
  t2.run_for(two_stage_settle_ms)
  assert_true((dd_c.target() - 0.0).abs() < 0.001, msg="Up while disabled must restore 0.0")
  assert_eq(t2.drawn_glass().length(), 0, msg="Up while disabled must drop lens")
  t2.assert_idle()

  // 4. finger_only_lens=true: mouse drag keeps 0 glass; keyboard Space keeps 0 glass
  let on_f = @signals.signal(false)
  let t3 = @ui.Tester::new(fn(_c) {  }, w=240.0, h=120.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))) |> ignore
      liquid_toggle_node(
        page,
        fn() { on_f.get() },
        fn(v) { on_f.set(v) },
        fn() { "FingerOnly" },
        finger_only_lens=true,
      )
      |> ignore
    })
    |> ignore
  })
  t3.draw()
  let rf = t3.get(Switch, label="FingerOnly").rect
  t3.press_at(rf.0 + 10.0, rf.1 + rf.3 / 2.0)
  t3.move_to(rf.0 + rf.2 - 6.0, rf.1 + rf.3 / 2.0)
  t3.run_for(four_frames_ms)
  assert_eq(t3.drawn_glass().length(), 0, msg="finger_only_lens=true mouse drag must keep 0 glass")
  t3.release(rf.0 + rf.2 - 6.0, rf.1 + rf.3 / 2.0)
  t3.run_for(@ui.move_most_ms)
  assert_true(on_f.get(), msg="mouse drag across must still toggle switch")
  // Keyboard Space -> 0 glass
  t3.key(@ui.key_tab)
  t3.draw()
  t3.key(@ui.key_space)
  t3.run_for(two_frames_ms)
  assert_eq(t3.drawn_glass().length(), 0, msg="Space toggle must keep 0 glass")
  t3.run_for(@ui.move_most_ms)
  assert_true(!on_f.get())
  t3.assert_idle()

  // 5. Real rendered-layer symmetric left/right stretch + 3-layer concentricity + Up-only over-slop direction settle
  let on_s = @signals.signal(false)
  let t4 = @ui.Tester::new(fn(_c) {  }, w=240.0, h=120.0, dark=false, platform=0, pointing=Finger, native=Finger)
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))) |> ignore
      liquid_toggle_node(page, fn() { on_s.get() }, fn(v) { on_s.set(v) }, fn() { "SymSwitch" }) |> ignore
    })
    |> ignore
  })
  t4.draw()
  let rs = t4.get(Switch, label="SymSwitch").rect
  let sy = rs.1 + rs.3 / 2.0
  // Rightward drag
  t4.touch(0, rs.0 + 12.0, sy)
  t4.run_for(frame_ms)
  t4.touch(1, rs.0 + 20.0, sy)
  t4.run_for(frame_ms)
  // Verify 3-layer concentricity (shadow box, solid thumb fill, glass lens) while all are visible mid-lift
  let mid_r_lens = t4.drawn_instances().filter(fn(i) { i[5] == 6.0 })
  assert_eq(mid_r_lens.length(), 1, msg="mid-lift switch drag must draw 1 glass lens")
  let mid_lcx = mid_r_lens[0][0] + mid_r_lens[0][2] / 2.0
  let mid_lcy = mid_r_lens[0][1] + mid_r_lens[0][3] / 2.0
  let mid_r_solids = t4.drawn_instances().filter(fn(i) {
    i[5] == 0.0 &&
    ((i[0] + i[2] / 2.0) - mid_lcx).abs() < 1.0 &&
    ((i[1] + i[3] / 2.0) - mid_lcy).abs() < 1.0 &&
    (i[2] - mid_r_lens[0][2]).abs() < 1.0 &&
    (i[3] - mid_r_lens[0][3]).abs() < 1.0
  })
  let mid_r_shadows = t4.drawn_instances().filter(fn(i) { i[5] == 2.0 })
  assert_eq(mid_r_shadows.length(), 0, msg="iOS 27 thumb_lift_shadow must emit 0 stray outer shadow")
  assert_true(mid_r_solids.length() >= 1, msg="solid thumb must be concentric with glass lens")
  assert_true(
    (mid_r_solids[0][0] - mid_r_lens[0][0]).abs() < 1.0 &&
    (mid_r_solids[0][1] - mid_r_lens[0][1]).abs() < 1.0 &&
    (mid_r_solids[0][2] - mid_r_lens[0][2]).abs() < 1.0 &&
    (mid_r_solids[0][3] - mid_r_lens[0][3]).abs() < 1.0,
    msg="solid thumb and glass lens rects must match concentrically",
  )
  t4.touch(1, rs.0 + 44.0, sy)
  t4.run_for(two_frames_ms)
  let r_lens = t4.drawn_instances().filter(fn(i) { i[5] == 6.0 })
  assert_eq(r_lens.length(), 1, msg="rightward switch drag must draw 1 glass lens")
  let rw = r_lens[0][2]
  let rh = r_lens[0][3]
  t4.touch(2, rs.0 + 44.0, sy)
  t4.run_for(two_stage_settle_ms)
  assert_true(on_s.get())
  // Leftward drag with identical steps: must stretch horizontally (lw > lh), never taller than wide
  t4.touch(0, rs.0 + 44.0, sy)
  t4.run_for(frame_ms)
  t4.touch(1, rs.0 + 36.0, sy)
  t4.run_for(frame_ms)
  t4.touch(1, rs.0 + 12.0, sy)
  t4.run_for(two_frames_ms)
  let l_lens = t4.drawn_instances().filter(fn(i) { i[5] == 6.0 })
  assert_eq(l_lens.length(), 1, msg="leftward switch drag must draw 1 glass lens")
  assert_true((l_lens[0][2] - rw).abs() < 1.5 && (l_lens[0][3] - rh).abs() < 1.5, msg="leftward drag lens (\{l_lens[0][2]}x\{l_lens[0][3]}) must match rightward (\{rw}x\{rh})")
  t4.touch(2, rs.0 + 12.0, sy)
  t4.run_for(two_stage_settle_ms)
  assert_true(!on_s.get())
  // Up-only over-slop drag toward OFF side while OFF: must stay OFF (not invert to ON via !prev)
  t4.press_at(rs.0 + 20.0, sy)
  t4.release(rs.0 + 4.0, sy)
  t4.run_for(two_stage_settle_ms)
  assert_true(!on_s.get(), msg="Up-only drag toward OFF side while OFF must keep switch OFF")
  // Pure vertical Up-only over slop without Moved: must cancel to authority (0 flip)
  t4.press_at(rs.0 + 20.0, sy)
  t4.release(rs.0 + 20.0, sy + 20.0)
  t4.run_for(two_stage_settle_ms)
  assert_true(!on_s.get(), msg="pure vertical Up-only over slop on Switch must keep authority (0 flip)")
  t4.assert_idle()
}

///|
test "Slider (liquid_slider_node): 90pt wide thumb cap <= 110pt at high velocity, 38pt standard 58pt, external slide_to 0 velocity, mid-drag disabled Up/Off & solid/reduced cleanup" {
  // 1. 90pt wide thumb cap <= 110pt under multi-frame high-speed drag with real nonzero velocity
  let val = @signals.signal(0.0)
  let sl_disabled = @signals.signal(false)
  let dd = DampedDrag::new(0.0, lo=0.0, hi=100.0, held_scale=slider_thumb_held_scale)
  let host : Ref[@view.View?] = Ref(None)
  let t = @ui.Tester::new(fn(_c) {  }, w=420.0, h=120.0, dark=false, platform=0)
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))) |> ignore
      let sl = liquid_slider_node(
        page,
        fn() { val.get() },
        fn(v) { val.set(v) },
        fn() { "WideSlider" },
        disabled=fn() { sl_disabled.get() },
        least=0.0,
        most=100.0,
        thumb_w_px=90.0,
        drag=dd,
      )
      host.val = Some(sl)
    })
    |> ignore
  })
  t.draw()
  let n = host.val.unwrap()
  let r = t.get(Slider, label="WideSlider").rect
  let sy = r.1 + r.3 / 2.0
  t.press_at(r.0 + 45.0, sy)
  t.run_for(sample_mid_ms)
  // Two spaced moves to generate real nonzero velocity
  t.move_to(r.0 + 120.0, sy)
  t.frame(ms=frame_ms)
  t.move_to(r.0 + r.2 - 20.0, sy)
  t.run_for(two_frames_ms)
  assert_true(dd.velocity(n).abs() > 1.0, msg="fast slider drag must have nonzero velocity, got \{dd.velocity(n)}")
  let lenses = t.drawn_instances().filter(fn(i) { i[5] == 6.0 })
  assert_eq(lenses.length(), 1, msg="slider drag must draw 1 glass lens")
  assert_true(lenses[0][2] <= 110.01, msg="90pt slider lens width must be capped <= 110pt, got \{lenses[0][2]}")
  // Under reduced_motion=true (#8879): lens stays visible while held, release settles cleanly to 0 glass + idle.
  t.set_reduce_motion(true)
  t.draw()
  assert_eq(t.drawn_glass().length(), 1, msg="reduced_motion keeps lens while held")
  t.release(r.0 + r.2 - 20.0, sy)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.drawn_glass().length(), 0, msg="reduced_motion release must settle to 0 glass")
  t.assert_idle()
  t.set_reduce_motion(false)
  // Toggle glass_solid mid-drag -> release -> restore -> immediate first-frame 0 glass and idle
  t.press_at(r.0 + 45.0, sy)
  t.run_for(sample_mid_ms)
  assert_eq(t.drawn_glass().length(), 1)
  @ui.set_glass_solid(Some(true))
  t.draw()
  t.release(r.0 + 45.0, sy)
  @ui.set_glass_solid(None)
  t.draw()
  assert_eq(t.drawn_glass().length(), 0, msg="restoring glass_solid immediately after release must stay 0 glass on frame 0")
  t.run_for(@ui.move_most_ms)
  t.assert_idle()

  // Mid-drag disabled -> Up and Off through real headless/slider -> re-enable -> external value.set works & 0 glass
  for use_off in [false, true] {
    val.set(20.0)
    t.run_for(@ui.move_most_ms)
    t.press_at(r.0 + 80.0, sy)
    t.move_to(r.0 + 220.0, sy)
    t.run_for(two_frames_ms)
    sl_disabled.set(true)
    t.draw()
    if use_off {
      t.leave()
    } else {
      t.release(r.0 + 220.0, sy)
    }
    t.run_for(two_stage_settle_ms)
    assert_eq(t.drawn_glass().length(), 0, msg="slider disabled mid-drag (off=\{use_off}) must drop lens")
    t.assert_idle()
    sl_disabled.set(false)
    t.draw()
    val.set(75.0)
    t.run_for(@ui.move_most_ms)
    assert_true((dd.value(n) - 75.0).abs() < 0.5, msg="re-enabled slider must accept external value after disabled mid-drag (off=\{use_off}), got \{dd.value(n)}")
    t.assert_idle()
  }

  // External value change uses slide_to -> 0 velocity
  val.set(20.0)
  t.run_for(two_frames_ms)
  assert_true(dd.velocity(n).abs() < 1.0e-6, msg="external slider value change must inject 0 velocity")
  t.run_for(@ui.move_most_ms)
  t.assert_idle()

  // 2. Standard 38pt thumb held at rest reaches exact 58pt
  let val2 = @signals.signal(50.0)
  let t2 = @ui.Tester::new(fn(_c) {  }, w=320.0, h=120.0, dark=false, platform=0)
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))) |> ignore
      liquid_slider_node(page, fn() { val2.get() }, fn(v) { val2.set(v) }, fn() { "StdSlider" }, thumb_w_px=38.0)
      |> ignore
    })
    |> ignore
  })
  t2.draw()
  let r2 = t2.get(Slider, label="StdSlider").rect
  t2.press_at(r2.0 + r2.2 / 2.0, r2.1 + r2.3 / 2.0)
  t2.run_for(@ui.move_most_ms)
  let lenses2 = t2.drawn_instances().filter(fn(i) { i[5] == 6.0 })
  assert_eq(lenses2.length(), 1)
  assert_true((lenses2[0][2] - 58.0).abs() < 0.5, msg="38pt standard slider held width must be ~58pt, got \{lenses2[0][2]}")
  t2.release(r2.0 + r2.2 / 2.0, r2.1 + r2.3 / 2.0)
  t2.run_for(two_stage_settle_ms)
  t2.assert_idle()

  // 3. Controlled continuous slider contract via real headless/slider:
  //    (a) caller synchronously rounds 54 -> 50 => visual & a11y both settle at 50;
  //    (b) direct track tap (Down without Moved -> Up) lands on tapped target value.
  let val3 = @signals.signal(0.0)
  let dd3 = DampedDrag::new(0.0, lo=0.0, hi=100.0, held_scale=slider_thumb_held_scale)
  let host3 : Ref[@view.View?] = Ref(None)
  let t3 = @ui.Tester::new(fn(_c) {  }, w=360.0, h=120.0, dark=false, platform=0)
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))) |> ignore
      let sl = liquid_slider_node(
        page,
        fn() { val3.get() },
        fn(v) { val3.set((v / 10.0).round() * 10.0) },
        fn() { "RoundedSlider" },
        least=0.0,
        most=100.0,
        drag=dd3,
      )
      host3.val = Some(sl)
    })
    |> ignore
  })
  t3.draw()
  let n3 = host3.val.unwrap()
  let r3 = t3.get(Slider, label="RoundedSlider").rect
  let y3 = r3.1 + r3.3 / 2.0
  // (a) Drag to ~54% -> caller rounds to 50 -> release settles visual & a11y to 50
  t3.press_at(r3.0 + 20.0, y3)
  t3.move_to(r3.0 + r3.2 * 0.54, y3)
  t3.run_for(two_frames_ms)
  t3.release(r3.0 + r3.2 * 0.54, y3)
  t3.run_for(two_stage_settle_ms)
  assert_eq(val3.get(), 50.0, msg="caller must round 54 to 50")
  assert_true((dd3.value(n3) - 50.0).abs() < 0.5, msg="controlled slider visual must settle to rounded 50, got \{dd3.value(n3)}")
  assert_eq(t3.get(Slider, label="RoundedSlider").range, Some((0.0, 50.0, 100.0)))
  // (b) Direct track tap at ~80% (Down without Moved -> Up) -> lands on 80
  t3.tap(r3.0 + r3.2 * 0.80, y3)
  t3.run_for(two_stage_settle_ms)
  assert_eq(val3.get(), 80.0, msg="direct track tap must commit 80")
  assert_true((dd3.value(n3) - 80.0).abs() < 0.5, msg="direct track tap visual must settle to 80, got \{dd3.value(n3)}")
  t3.assert_idle()
}
