// Tests for `drawer_node` (iOS 26 floating liquid-glass side drawer) and upgraded `glass_sheet()`:
// Leading/Trailing layout, open/close, slow drag snap-back, threshold & fling dismiss, rubber-band clamp (<= 16pt),
// Escape / scrim outside tap / takes_back dismissal, MBUI_GLASS=solid degradation, zero t.audit() warnings,
// and 60/120/24/7 fps invariance.

///|
let drawer_settle_ms : Double = @ui.move_most_ms * 2.0

///|
fn drawer_test_harness(
  side : DrawerSide,
  dark? : Bool = false,
  solid? : Bool = false,
  scrim? : Bool = true,
) -> (@ui.Tester, @signals.Signal[Bool], Ref[Int]) {
  let open = @signals.signal(false)
  let closes = Ref(0)
  let t = @ui.Tester::new(fn(_c) {  }, w=900.0, h=640.0, dark~, platform=0)
  set_dark(Some(dark))
  @ui.set_glass_solid(if solid { Some(true) } else { None })
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).ground(By(fn() { theme().p.bg })) |> ignore
        page.box(fn(w) {
          w.margin(Is((24.0, 24.0, 24.0, 24.0))).words(Is("Workspace Body")).ink(By(fn() { theme().p.text })) |> ignore
        })
        |> ignore
        drawer_node(
          page,
          fn() { open.get() },
          fn() { "侧边抽屉" },
          fn() {
            closes.val += 1
            open.set(false)
          },
          fn(body) {
            body.padding(Is((16.0, 16.0, 16.0, 16.0))).gap(Is(12.0)) |> ignore
            body.box(fn(h) { h.words(Is("抽屉标题")).ink(By(fn() { theme().p.text })) |> ignore }) |> ignore
            button_node(body, fn() { "关闭抽屉" }, fn() { open.set(false) }) |> ignore
          },
          spec={ ..DrawerSpec::default(), side, scrim },
        )
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  (t, open, closes)
}

///|
test "glass_sheet emits calibrated high-density iOS 27 liquid glass in light and dark" {
  for dark in [false, true] {
    let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0, dark~, platform=0)
    set_dark(Some(dark))
    @ui.set_view_app(fn(root) { root.box(fn(_) {  }) |> ignore }, theme=ui_theme_now)
    t.draw()
    let g = glass_sheet()
    assert_eq(
      (g.liquid, g.blur, g.tint, g.saturation, g.rim, g.bezel, g.refraction, g.chroma, g.merge, g.adaptive),
      (
        true,
        12.0,
        if dark { 0x202020CCL } else { 0xFDFCFDCCL },
        1.0,
        0.6,
        20.0,
        24.0,
        0.0,
        0.0,
        false,
      ),
    )
  }
  set_dark(None)
}

///|
test "drawer_node Leading & Trailing layout, single-layer liquid glass, solid degradation, and zero audit faults" {
  for side in [Leading, Trailing] {
    for dark in [false, true] {
      for solid in [false, true] {
        let (t, open, _) = drawer_test_harness(side, dark~, solid~)
        open.set(true)
        t.run_for(drawer_settle_ms)
        let dlg = t.query(Dialog)
        assert_true(dlg is Some(_), msg="drawer dialog missing")
        let (x, y, w, h) = dlg.unwrap().rect
        let expected_x = match side {
          Leading => 10.0
          Trailing => 900.0 - 300.0 - 10.0
        }
        assert_true((x - expected_x).abs() < 1.0, msg="side=\{Repr(side)} x=\{x} expected=\{expected_x}")
        assert_true((y - 10.0).abs() < 1.0, msg="y=\{y}")
        assert_true((w - 300.0).abs() < 1.0, msg="w=\{w}")
        assert_true((h - 620.0).abs() < 1.0, msg="h=\{h}")
        let glass = t.drawn_glass()
        let expected_glass = if solid { 0 } else { 1 }
        let liquid_count = glass.filter(fn(g) { g.4 == 6 }).length()
        let shadows = outside_shadows(t)
        let expected_shadows = if solid { [] } else { [glass_overlay_shadow()] }
        let audits = t.audit()
        @ui.set_glass_solid(None)
        assert_eq(
          (side, dark, solid, glass.length(), liquid_count, shadows, audits),
          (side, dark, solid, expected_glass, expected_glass, expected_shadows, []),
        )
      }
    }
  }
  set_dark(None)
}

///|
test "drawer_node Escape, scrim outside tap, and takes_back all dismiss cleanly" {
  // 1. Escape
  let (t1, open1, closes1) = drawer_test_harness(Leading)
  open1.set(true)
  t1.run_for(drawer_settle_ms)
  t1.key(@ui.key_escape)
  t1.run_for(drawer_settle_ms)
  assert_eq((open1.untracked(), closes1.val, t1.query(Dialog) is None), (false, 1, true))

  // 2. Outside scrim press (x = 700 on Leading drawer [10, 310])
  let (t2, open2, closes2) = drawer_test_harness(Leading)
  open2.set(true)
  t2.run_for(drawer_settle_ms)
  t2.tap(700.0, 320.0)
  t2.run_for(drawer_settle_ms)
  assert_eq((open2.untracked(), closes2.val, t2.query(Dialog) is None), (false, 1, true))

  // 3. System back (takes_back)
  let (t3, open3, closes3) = drawer_test_harness(Trailing)
  open3.set(true)
  t3.run_for(drawer_settle_ms)
  t3.back()
  t3.run_for(drawer_settle_ms)
  assert_eq((open3.untracked(), closes3.val, t3.query(Dialog) is None), (false, 1, true))
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "drawer_node horizontal drag: rubber-band clamp <= 16pt, slow drag snap-back, threshold & fling dismiss" {
  let (t, open, closes) = drawer_test_harness(Leading)
  open.set(true)
  t.run_for(drawer_settle_ms)
  let rest_x = t.query(Dialog).unwrap().rect.0
  assert_true((rest_x - 10.0).abs() < 1.0)

  // Over-pull toward open edge (rightward on Leading): rubber-band clamped strictly <= 16pt
  t.press_at(160.0, 320.0)
  t.hold_move(360.0, 320.0)
  let pulled_x = t.query(Dialog).unwrap().rect.0
  assert_true(pulled_x > rest_x + 4.0 && pulled_x < rest_x + 16.0, msg="rubber pull x=\{pulled_x}")
  t.advance(@ui.input_step_ms * 6.0)
  t.release(360.0, 320.0)
  t.run_for(drawer_settle_ms)
  assert_true(open.untracked(), msg="rubber over-pull must stay open")
  assert_true((t.query(Dialog).unwrap().rect.0 - rest_x).abs() < 1.0)

  // Slow drag below 32% threshold (~60pt < 96pt) pauses and snaps back open
  t.press_at(200.0, 320.0)
  for frac in [0.25, 0.5, 0.75, 1.0] {
    t.hold_move(200.0 - 60.0 * frac, 320.0)
  }
  let mid_x = t.query(Dialog).unwrap().rect.0
  assert_true((mid_x - (rest_x - 60.0)).abs() < 2.0, msg="1:1 drag mid_x=\{mid_x}")
  t.advance(@ui.input_step_ms * 6.0)
  t.release(140.0, 320.0)
  t.run_for(drawer_settle_ms)
  assert_true(open.untracked(), msg="below-threshold drag must snap back open")
  assert_true((t.query(Dialog).unwrap().rect.0 - rest_x).abs() < 1.0)

  // Drag past 32% threshold (140pt > 96pt) commits close
  t.press_at(220.0, 320.0)
  for frac in [0.25, 0.5, 0.75, 1.0] {
    t.hold_move(220.0 - 140.0 * frac, 320.0)
  }
  t.advance(@ui.input_step_ms * 6.0)
  t.release(80.0, 320.0)
  t.run_for(drawer_settle_ms)
  assert_eq((open.untracked(), closes.val, t.query(Dialog) is None), (false, 1, true))

  // Reopen and fast fling toward closing edge (< 32% distance but > 0.45 pt/ms) commits close
  open.set(true)
  t.run_for(drawer_settle_ms)
  t.press_at(200.0, 320.0)
  t.hold_move(175.0, 320.0)
  t.hold_move(145.0, 320.0)
  t.release(145.0, 320.0)
  t.run_for(drawer_settle_ms)
  assert_eq((open.untracked(), closes.val, t.query(Dialog) is None), (false, 2, true))
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "drawer_node closed-form slide motion is FPS-invariant across 60/120/24/7 fps" {
  let samples : Array[Double] = []
  let probe_ms = @ui.move_ms(310.0) * 0.35
  for fps in [60.0, 120.0, 24.0, 7.0] {
    let (t, open, _) = drawer_test_harness(Leading)
    t.set_frame_period(1000.0 / fps)
    open.set(true)
    t.run_for(probe_ms)
    let x_mid = t.query(Dialog).unwrap().rect.0
    t.run_for(drawer_settle_ms)
    let x_end = t.query(Dialog).unwrap().rect.0
    assert_true((x_end - 10.0).abs() < 0.5, msg="fps=\{fps} x_end=\{x_end}")
    samples.push(x_mid)
  }
  let ref_x = samples[0]
  for x in samples {
    assert_true((x - ref_x).abs() < 1.0, msg="mid x mismatch across fps: \{x} vs \{ref_x}")
  }
  @ui.set_glass_solid(None)
  set_dark(None)
}
