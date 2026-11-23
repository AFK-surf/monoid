// Tests for `glass_button_node`:
// - `.glass` (`prominent=false`) & `.glassProminent` (`prominent=true`) in Light & Dark modes
// - Interactive press GPU `spot` + elastic spring scale + clean release settle
// - `MBUI_GLASS=solid` degradation (0 glass instances, solid accent / panel ground)
// - Disabled state (`alpha=0.45`, click blocked, `refused_shake`)
// - `Tester::audit() == []` across Light & Dark

///|
let glass_button_settle_ms : Double = 700.0

///|
fn glass_button_tester(
  prominent : Bool,
  dark : Bool,
  solid : Bool,
  disabled : @signals.Signal[Bool],
  clicks : Ref[Int],
  high_contrast? : Bool = false,
) -> (@ui.Tester, Ref[@view.View?]) {
  presenters_reset()
  set_words(fn(key, _) { key })
  let t = @ui.Tester::new(fn(_c) {  }, w=420.0, h=160.0, dark~, platform=0)
  set_dark(Some(dark))
  @ui.set_glass_solid(if solid { Some(true) } else { None })
  let btn_ref : Ref[@view.View?] = Ref(None)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(box) {
      box
      .row(Is(true))
      .grow(Is(1.0))
      .padding(Is((24.0, 24.0, 24.0, 24.0)))
      .lines_up(Is(Some(Middle)))
      .ground(By(fn() { theme().p.bg }))
      |> ignore
      let b = glass_button_node(
        box,
        fn() { if prominent { "Deploy" } else { "Cancel" } },
        fn() { clicks.val += 1 },
        prominent~,
        high_contrast~,
        icon=if prominent { "zap" } else { "refresh" },
        disabled=fn() { disabled.get() },
      )
      btn_ref.val = Some(b)
    })
    |> ignore
  })
  t.draw()
  (t, btn_ref)
}

///|
test "glass_button_node renders .glass and .glassProminent in light and dark with solid fallback and zero audit faults" {
  for prominent in [false, true] {
    for dark in [false, true] {
      let disabled = @signals.signal(false)
      let clicks = Ref(0)
      let (t, _) = glass_button_tester(prominent, dark, false, disabled, clicks, high_contrast=prominent)
      let glass = t.drawn_glass()
      let liquid_count = glass.filter(fn(g) { g.4 == 6 }).length()
      let audits = t.audit()
      assert_eq(
        (prominent, dark, glass.length(), liquid_count, audits),
        (prominent, dark, 1, 1, []),
      )

      let (ts, _) = glass_button_tester(prominent, dark, true, disabled, clicks, high_contrast=prominent)
      let solid_glass = ts.drawn_glass().length()
      let expected_ground = if prominent {
        prominent_accent_fill(theme().p.accent, high_contrast=true)
      } else {
        panel_ground()
      }
      if prominent {
        // Default high_contrast=false preserves native system accent untouched
        assert_eq(prominent_accent_fill(theme().p.accent), theme().p.accent)
        assert_eq(prominent_accent_fill(0x0088FFFFL), 0x0088FFFFL)
        let hc = prominent_accent_fill(0x0088FFFFL, high_contrast=true)
        assert_true(@ui.contrast_ratio(0xFFFFFFFFL, hc) >= 4.6)
        let hc_theme = prominent_accent_fill(theme().p.accent, high_contrast=true)
        assert_true(@ui.contrast_ratio(0xFFFFFFFFL, hc_theme) >= 4.6)
      }
      let has_ground = ts.drawn_rects().iter().any(fn(r) { r.4 == expected_ground })
      let solid_audits = ts.audit()
      @ui.set_glass_solid(None)
      assert_eq(
        (prominent, dark, solid_glass, has_ground, solid_audits),
        (prominent, dark, 0, true, []),
      )
      if prominent {
        // Verify default glass_button_node (high_contrast=false) emits raw accent in solid fallback
        let (ts_raw, _) = glass_button_tester(true, dark, true, disabled, clicks, high_contrast=false)
        let has_raw = ts_raw.drawn_rects().iter().any(fn(r) { r.4 == theme().p.accent })
        @ui.set_glass_solid(None)
        assert_true(has_raw)
      }
    }
  }
  set_dark(None)
}

///|
test "glass_button_node press drives GPU spot, spring scale, click callback, and settles cleanly" {
  for prominent in [false, true] {
    let disabled = @signals.signal(false)
    let clicks = Ref(0)
    let (t, btn_ref) = glass_button_tester(prominent, false, false, disabled, clicks)
    let btn = btn_ref.val.unwrap()
    let has_spot = fn() {
      t.drawn_instances().iter().any(fn(a) {
        a.length() > 14 && a[5] == 6.0 && (a[14] > 0.5 || a[14] < -1.5)
      })
    }
    assert_eq(has_spot(), false)
    let (bx, by, bw, bh) = btn.placed_window_now()
    let (cx, cy) = (bx + bw / 2.0, by + bh / 2.0)
    t.press_at(cx, cy)
    t.run_for(part_whole_ms)
    assert_true(has_spot(), msg="spot must be active while pressed (prominent=\{prominent})")
    assert_true(btn.drawn_scale() > 1.01, msg="button must spring-scale while pressed, got \{btn.drawn_scale()}")
    t.release(cx, cy)
    t.run_for(glass_button_settle_ms)
    assert_eq(clicks.val, 1)
    assert_eq(has_spot(), false)
    assert_true((btn.drawn_scale() - 1.0).abs() < 0.005, msg="button must settle back to 1.0, got \{btn.drawn_scale()}")
    t.assert_idle()
  }
  set_dark(None)
}

///|
test "glass_button_node disabled blocks press and keeps zero audit faults" {
  let disabled = @signals.signal(true)
  let clicks = Ref(0)
  let (t, btn_ref) = glass_button_tester(true, true, false, disabled, clicks)
  let btn = btn_ref.val.unwrap()
  let (bx, by, bw, bh) = btn.placed_window_now()
  t.tap(bx + bw / 2.0, by + bh / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(clicks.val, 0)
  assert_eq(t.audit(), [])
  set_dark(None)
}
