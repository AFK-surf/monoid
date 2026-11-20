// Runnable examples and unit tests for the motion library catalog, node-level tools,
// and core motion primitives (ShakeWay, HoldWay, Handoff, PressFeel, Zoom).

///|
let ex_hover_ms : Double = 140.0

///|
let ex_flash_in_ms : Double = 160.0

///|
let ex_flash_hold_ms : Double = 740.0

///|
let ex_flash_out_ms : Double = 800.0

///|
let ex_breathe_res_ms : Double = 1000.0

///|
let ex_spring_mid_ms : Double = 80.0

///|
let ex_spring_settle_ms : Double = 500.0

///|
let ex_shake_done_ms : Double = 320.0

///|
test "catalog: sample_ease, move_duration_ms, and critically damped vs underdamped spring overshoot" {
  // Distance-adaptive Move duration
  let short_ms = @motion.move_duration_ms(40.0)
  let long_ms = @motion.move_duration_ms(600.0)
  assert_true(short_ms < long_ms, msg="short \{short_ms}, long \{long_ms}")
  assert_eq(short_ms, @ui.move_ms(40.0))

  // Ease sampling across [0, 1]
  let out_pts = @motion.sample_ease(Out, 10)
  assert_eq(out_pts.length(), 11)
  assert_eq(out_pts[0], 0.0)
  assert_eq(out_pts[10], 1.0)
  assert_true(out_pts[5] > 0.5, msg="Out midpoint > 0.5: \{out_pts[5]}")

  // Critically damped snappy_damped has no overshoot (max <= 1.001)
  let damped_pts = @motion.sample_spec(@motion.snappy_damped, ex_spring_settle_ms, 50)
  assert_eq(damped_pts.length(), 51)
  let mut damped_max = 0.0
  for v in damped_pts {
    if v > damped_max {
      damped_max = v
    }
  }
  assert_true(damped_max <= 1.001, msg="snappy_damped must not overshoot: max=\{damped_max}")

  // Underdamped tactile_bounce exhibits noticeable overshoot (max > 1.01)
  let bounce_pts = @motion.sample_spec(@motion.tactile_bounce, ex_spring_settle_ms, 50)
  let mut bounce_max = 0.0
  for v in bounce_pts {
    if v > bounce_max {
      bounce_max = v
    }
  }
  assert_true(bounce_max > 1.01, msg="tactile_bounce should overshoot: max=\{bounce_max}")

  // Glass lens spring triplet and symmetric overlay presets
  let (p_sp, sx_sp, sy_sp) = @motion.glass_lens_springs()
  assert_eq(p_sp, @motion.backdrop_press_spring)
  assert_eq(sx_sp, @motion.backdrop_scale_x_spring)
  assert_eq(sy_sp, @motion.backdrop_scale_y_spring)
  assert_eq(@motion.dialog_out_ms, @motion.pop_out_ms)
  assert_eq(@motion.tip_out_ms, @motion.pop_out_ms)
}

///|
test "tools: hover_fade fades in and out, and instant_off drops immediately" {
  let active = @signals.signal(false)
  let instant = @signals.signal(false)
  let seen : Ref[Double] = Ref(0.0)
  let t = @ui.Tester::new(fn(_c) {  })
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      let p = @motion.hover_fade(b, fn() { active.get() }, duration_ms=ex_hover_ms, instant_off=fn() { instant.get() })
      b.alpha(@view.By(fn() {
        let v = p()
        seen.val = v
        v
      }))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(seen.val, 0.0)

  // Fade in
  active.set(true)
  t.run_for(ex_hover_ms / 2.0)
  assert_true(seen.val > 0.0 && seen.val < 1.0, msg="mid fade-in: \{seen.val}")
  t.run_for(ex_hover_ms)
  assert_eq(seen.val, 1.0)

  // Smooth fade out
  active.set(false)
  t.run_for(ex_hover_ms / 2.0)
  assert_true(seen.val > 0.0 && seen.val < 1.0, msg="mid fade-out: \{seen.val}")
  t.run_for(ex_hover_ms)
  assert_eq(seen.val, 0.0)

  // Instant off
  active.set(true)
  t.run_for(ex_hover_ms * 2.0)
  assert_eq(seen.val, 1.0)
  instant.set(true)
  active.set(false)
  t.draw()
  assert_eq(seen.val, 0.0)
}

///|
test "tools: flash_way runs in -> hold -> out and holds solid under reduced_motion" {
  let trig = @signals.signal(0)
  let lit : Ref[Double] = Ref(0.0)
  let t = @ui.Tester::new(fn(_c) {  })
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      let flash = @motion.flash_way(
        b,
        fn() { trig.get() },
        in_ms=ex_flash_in_ms,
        hold_ms=ex_flash_hold_ms,
        out_ms=ex_flash_out_ms,
      )
      b.alpha(@view.By(fn() {
        let v = flash()
        lit.val = v
        v
      }))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(lit.val, 0.0)

  // Normal motion: 160ms in -> 740ms hold -> 800ms out
  trig.set(1)
  t.run_for(ex_flash_in_ms / 2.0)
  assert_true(lit.val > 0.0 && lit.val < 1.0, msg="rising at 80ms: \{lit.val}")
  t.run_for(ex_flash_in_ms) // total 240ms -> in hold phase
  assert_eq(lit.val, 1.0)
  t.run_for(ex_flash_hold_ms + ex_flash_out_ms / 2.0) // total 1380ms -> in out phase
  assert_true(lit.val > 0.0 && lit.val < 1.0, msg="fading at 1380ms: \{lit.val}")
  t.run_for(ex_flash_out_ms) // done
  assert_eq(lit.val, 0.0)

  // Reduced motion: instant 1.0 for full 1700ms, then instant 0.0
  let total = ex_flash_in_ms + ex_flash_hold_ms + ex_flash_out_ms
  t.set_reduce_motion(true)
  trig.set(2)
  t.draw()
  assert_eq(lit.val, 1.0)
  t.run_for(total - ex_flash_in_ms)
  assert_eq(lit.val, 1.0)
  t.run_for(ex_flash_in_ms * 2.0)
  assert_eq(lit.val, 0.0)
}

///|
test "tools: breathe_alpha and resident_step (including 10Hz resident clock and reduced_motion)" {
  let still = @signals.signal(false)
  let a_smooth : Ref[Double] = Ref(1.0)
  let a_res : Ref[Double] = Ref(1.0)
  let step_val : Ref[Int] = Ref(0)
  let cyc_val : Ref[Double] = Ref(0.0)
  let t = @ui.Tester::new(fn(_c) {  })
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      let smooth = @motion.breathe_alpha(b, period_ms=1400.0, low=0.5, resident=false, still=fn() { still.get() })
      let res = @motion.breathe_alpha(b, period_ms=ex_breathe_res_ms, low=0.5, resident=true, still=fn() { still.get() })
      b.alpha(@view.By(fn() {
        a_smooth.val = smooth()
        a_res.val = res()
        step_val.val = @motion.resident_step(b, 800.0, 8)
        cyc_val.val = @motion.resident_cycle(b, 800.0)
        a_smooth.val
      }))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(a_res.val, 1.0)
  assert_true(a_smooth.val >= 0.5 && a_smooth.val <= 1.0, msg="initial smooth breathe: \{a_smooth.val}")

  // Advance half a resident period (500ms from 1000ms -> 1500ms): low = 0.5;
  // for 800ms / 8 steps -> (1500 % 800) / 800 * 8 = 700 / 100 = 7.
  t.run_for(ex_breathe_res_ms / 2.0)
  assert_true((a_res.val - 0.5).abs() < 0.01, msg="resident breathe at half period: \{a_res.val}")
  assert_eq(step_val.val, 7)
  assert_true(cyc_val.val > 0.85 && cyc_val.val < 0.9, msg="resident cycle at 1500ms/800ms: \{cyc_val.val}")

  // Still suppresses breathing to 1.0
  still.set(true)
  t.draw()
  assert_eq(a_smooth.val, 1.0)
  assert_eq(a_res.val, 1.0)

  // Reduced motion suppresses both breathing and resident_step
  still.set(false)
  t.set_reduce_motion(true)
  t.draw()
  assert_eq(a_smooth.val, 1.0)
  assert_eq(a_res.val, 1.0)
  assert_eq(step_val.val, 0)
}

///|
test "tools: indicator_rect settles silently on first non-None and animates with zero relayout" {
  let target : @signals.Signal[(Double, Double, Double, Double)?] = @signals.signal(None)
  let drawn_rect : Ref[(Double, Double, Double, Double)?] = Ref(None)
  let t = @ui.Tester::new(fn(_c) {  })
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      let rect = @motion.indicator_rect(b, fn() { target.get() }, spec=@motion.snappy_damped)
      b.ground_drawn(@view.By(fn() {
        let r = rect()
        drawn_rect.val = r
        match r {
          Some((x, y, w, h)) => { dx: x, dy: y, dw: w, dh: h, corners: None }
          None => @view.ground_as_laid
        }
      }))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(drawn_rect.val, None)

  // First non-None settles immediately (epistemic silence)
  target.set(Some((10.0, 20.0, 80.0, 32.0)))
  t.draw()
  assert_eq(drawn_rect.val, Some((10.0, 20.0, 80.0, 32.0)))

  // Subsequent change animates smoothly with zero layout recomputes during motion
  target.set(Some((110.0, 20.0, 100.0, 32.0)))
  t.draw()
  t.tree_frames_from_now()
  t.run_for(ex_spring_mid_ms)
  assert_true(
    t.tree_frames().iter().all(fn(f) { f.laid == 0 }),
    msg="indicator_rect must not trigger relayout during animation",
  )
  guard drawn_rect.val is Some((mx, _, mw, _)) else { fail("expected rect mid-motion") }
  assert_true(mx > 10.0 && mx < 110.0, msg="mid x: \{mx}")
  assert_true(mw > 80.0 && mw < 100.0, msg="mid w: \{mw}")

  t.run_for(ex_spring_settle_ms * 2.0)
  assert_eq(drawn_rect.val, Some((110.0, 20.0, 100.0, 32.0)))
}

///|
test "tools: overlay_presence releases modal_live on the first frame of exit" {
  let open = @signals.signal(true)
  let live_now : Ref[Bool] = Ref(true)
  let alpha_now : Ref[Double] = Ref(0.0)
  let t = @ui.Tester::new(fn(_c) {  })
  @ui.set_view_app(fn(root) {
    root.show(leave=@motion.dialog_out_ms, fn() { open.get() }, fn(s) {
      let (look, modal_live) = @motion.overlay_presence(s, enter=@motion.dialog_in, exit=@motion.dialog_out)
      s
      .modal(@view.By(fn() {
        let m = modal_live()
        live_now.val = m
        m
      }))
      .alpha(@view.By(fn() {
        let a = look().alpha
        alpha_now.val = a
        a
      }))
      .words(@view.Is("弹窗"))
      |> ignore
    })
  })
  t.draw()
  assert_eq(live_now.val, true)
  t.run_for(@motion.dialog_ms + 20.0)
  assert_eq(alpha_now.val, 1.0)
  assert_eq(live_now.val, true)

  // First frame of exit: modal_live drops immediately while exit animation is still fading
  open.set(false)
  t.draw()
  assert_eq(live_now.val, false)
  t.run_for(@motion.dialog_out_ms * 0.8)
  assert_eq(live_now.val, false)
  assert_true(alpha_now.val > 0.0 && alpha_now.val < 1.0, msg="fading out: \{alpha_now.val}")
  t.run_for(@motion.dialog_out_ms)
  assert_eq(t.find("弹窗"), None)
}

///|
test "tools: cover_indicator blends between indices with zero relayout and updates live on resize" {
  let chosen = @signals.signal(0)
  let cell_w = @signals.signal(80.0)
  let drawn : Ref[(Double, Double, Double, Double)?] = Ref(None)
  let t = @ui.Tester::new(fn(_c) {  })
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      let rect = @motion.cover_indicator(
        b,
        fn() { chosen.get() },
        fn(k) {
          let w = cell_w.get()
          if k >= 0 && k < 3 {
            Some((k.to_double() * w, 0.0, w, 32.0))
          } else {
            None
          }
        },
      )
      b.ground_drawn(@view.By(fn() {
        let r = rect()
        drawn.val = r
        match r {
          Some((x, y, w, h)) => { dx: x, dy: y, dw: w, dh: h, corners: None }
          None => @view.ground_as_laid
        }
      }))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(drawn.val, Some((0.0, 0.0, 80.0, 32.0)))

  // Switching index animates with zero relayout
  chosen.set(2)
  t.draw()
  t.tree_frames_from_now()
  t.run_for(ex_spring_mid_ms)
  assert_true(
    t.tree_frames().iter().all(fn(f) { f.laid == 0 }),
    msg="cover_indicator must not trigger relayout during animation",
  )
  guard drawn.val is Some((mx, _, mw, _)) else { fail("expected rect mid-motion") }
  assert_true(mx > 0.0 && mx < 160.0, msg="mid x: \{mx}")
  assert_eq(mw, 80.0)

  t.run_for(ex_spring_settle_ms * 2.0)
  assert_eq(drawn.val, Some((160.0, 0.0, 80.0, 32.0)))

  // Live resize updates immediately with zero lag
  cell_w.set(100.0)
  t.draw()
  assert_eq(drawn.val, Some((200.0, 0.0, 100.0, 32.0)))
}

///|
test "tools: flash_way_keyed clears on key reuse and fades out by total_ms" {
  let key = @signals.signal("m1")
  let target : @signals.Signal[(String, Double)] = @signals.signal(("", -1.0))
  let lit : Ref[Double] = Ref(0.0)
  let t = @ui.Tester::new(fn(_c) {  })
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      let way = @motion.flash_way_keyed(b, fn() { key.get() }, fn() { target.get() })
      b.alpha(@view.By(fn() {
        let v = way.shown_on(b)
        lit.val = v
        v
      }))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(lit.val, 0.0)

  let at = t.time()
  target.set(("m1", at))
  t.run_for(ex_flash_in_ms / 2.0)
  assert_true(lit.val > 0.0 && lit.val < 1.0, msg="rising: \{lit.val}")
  t.run_for(ex_flash_in_ms)
  assert_eq(lit.val, 1.0)

  // Key change (row recycled) clears immediately
  key.set("m2")
  t.draw()
  assert_eq(lit.val, 0.0)

  // Target m2 runs full cycle and settles at 0.0
  let at2 = t.time()
  target.set(("m2", at2))
  t.run_for(ex_flash_in_ms + ex_flash_in_ms / 4.0)
  assert_eq(lit.val, 1.0)
  t.run_for(ex_flash_hold_ms + ex_flash_out_ms)
  assert_eq(lit.val, 0.0)
  t.assert_idle()
}

///|
test "tools: hover_fade_keyed snaps immediately on key change without animation" {
  let key = @signals.signal("a")
  let selected = @signals.signal("")
  let seen : Ref[Double] = Ref(0.0)
  let t = @ui.Tester::new(fn(_c) {  })
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      let p = @motion.hover_fade_keyed(
        b,
        fn() { key.get() },
        fn() { selected.get() == key.get() },
        duration_ms=ex_hover_ms,
      )
      b.alpha(@view.By(fn() {
        let v = p()
        seen.val = v
        v
      }))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(seen.val, 0.0)

  // Same key: fades smoothly when selected becomes "a"
  selected.set("a")
  t.run_for(ex_hover_ms / 2.0)
  assert_true(seen.val > 0.0 && seen.val < 1.0, msg="mid fade: \{seen.val}")

  // Key changes to unselected row "b": snaps to 0.0 immediately
  key.set("b")
  t.draw()
  assert_eq(seen.val, 0.0)
  t.assert_idle()

  // Key changes back to selected row "a": snaps to 1.0 immediately
  key.set("a")
  t.draw()
  assert_eq(seen.val, 1.0)
  t.assert_idle()
}

///|
test "examples: ShakeWay, HoldWay, Handoff, PressFeel, and Zoom" {
  // 1. ShakeWay + shakes_while steadiness
  let shake = @motion.ShakeWay::new()
  let fired = @signals.signal(false)
  let t = @ui.Tester::new(fn(_c) {  })
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      let _ = shake.shakes(b)
      let feel = @motion.press_feel(b)
      let hold = @motion.hold_way(b, 300.0, fn() { fired.set(true) })
      b
      .width(@view.Is(Some(100.0)))
      .height(@view.Is(Some(44.0)))
      .alpha(@view.By(fn() { 0.8 + 0.2 * feel.hovered_on(b) + 0.0 * hold.progress_on(b) }))
      .words(@view.Is("抖动"))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  shake.shake(at=t.time())
  t.run_for(ex_shake_done_ms)
  assert_eq(shake.active_at(t.time()), false)

  // 2. Handoff between two parts
  let group = @motion.Handoff::new(within=300.0)
  let p1 = group.part(fn(_) { 1.0 })
  let p2 = group.part(fn(_) { 1.0 })
  assert_eq(p1.came(0.0, @motion.snappy_damped), None)
  assert_eq(p1.is_last(), true)
  p1.left(50.0)
  assert_eq(p2.other_near(100.0), true)

  // 3. Zoom fit and double-tap zoom
  let z = @motion.Zoom::new()
  z.boxed(400.0, 300.0, at=0.0)
  z.natural(800.0, 600.0, at=0.0)
  assert_eq(z.sized(), true)
  z.double_tap(200.0, 150.0, at=100.0)
  assert_true(z.zoomed_at(1000.0), msg="double_tap zooms in")
}
