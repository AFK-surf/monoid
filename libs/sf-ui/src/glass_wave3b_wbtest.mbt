// Tests for Wave 3B iOS 27 liquid glass upgrades across media viewers (`glass_viewer_clear`, `glass_viewer_dark`,
// `viewer_page_glass`, `viewer_steps_node`, `viewer_bar_node`), popovers (`small_panel_node`), and toasts
// (`glass_toast`, `toaster_node`): single-layer `kind == 6` liquid glass, clean `MBUI_GLASS=solid` degradation,
// and WCAG contrast >= 4.5:1 in both Light and Dark themes.

///|
test "Wave 3B glass helpers emit calibrated iOS 27 liquid glass in light and dark" {
  for dark in [false, true] {
    let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0, dark~, platform=0)
    set_dark(Some(dark))
    @ui.set_view_app(fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(_) {  }) |> ignore
    })
    t.draw()
    let vc = glass_viewer_clear()
    let vd = glass_viewer_dark()
    let vp = viewer_page_glass()
    let gt = glass_toast()
    let expected_tint = if dark { 0x20202067L } else { 0xFDFCFD67L }
    assert_eq(
      (vc.liquid, vc.blur, vc.tint, vc.saturation, vc.bezel, vc.refraction, vc.chroma, vc.rim),
      (true, 4.0, expected_tint, 0.55, 9.0, 12.0, 0.06, 0.70),
    )
    assert_eq(
      (vd.liquid, vd.blur, vd.tint, vd.solid, vd.saturation, vd.bezel, vd.refraction, vd.chroma, vd.rim),
      (true, 4.0, 0x20202067L, 0x161618FFL, 0.65, 9.0, 12.0, 0.06, 0.65),
    )
    assert_eq(
      (vp.liquid, vp.blur, vp.saturation, vp.bezel, vp.refraction, vp.rim),
      (true, 4.0, 0.55, 9.0, 12.0, 0.70),
    )
    assert_eq(
      (gt.liquid, gt.blur, gt.tint, gt.bezel, gt.refraction),
      (true, 2.1, if dark { 0x202020BFL } else { 0xFDFCFDBFL }, 12.0, 14.0),
    )
  }
  set_dark(None)
}

///|
test "small_panel_node uses single-layer liquid glass and degrades cleanly under MBUI_GLASS=solid" {
  for dark in [false, true] {
    for solid in [false, true] {
      let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=400.0, dark~, platform=0)
      set_dark(Some(dark))
      @ui.set_glass_solid(if solid { Some(true) } else { None })
      @ui.set_view_app(fn(root) {
        @ui.set_tree_theme(ui_theme_now)
        root.box(fn(page) {
          page.grow(Is(1.0)).padding(Is((48.0, 48.0, 48.0, 48.0))).ground(By(fn() { theme().p.bg })) |> ignore
          page.box(fn(p) {
            small_panel_node(p)
            .width(Is(Some(280.0)))
            .padding(Is((12.0, 12.0, 12.0, 12.0)))
            .gap(Is(8.0))
            |> ignore
            p.box(fn(w) {
              w.words(Is("Preview Card")).ink(By(fn() { theme().p.text })) |> ignore
            })
            |> ignore
            panel_button_node(p, fn() { "Copy" }, fn() {  }) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      t.draw()
      let glass = t.drawn_glass()
      let expected_glass = if solid { 0 } else { 1 }
      let liquid_count = glass.filter(fn(g) { g.4 == 6 }).length()
      let audits = t.audit()
      @ui.set_glass_solid(None)
      assert_eq((dark, solid, glass.length(), liquid_count, audits), (dark, solid, expected_glass, expected_glass, []))
    }
  }
  set_dark(None)
}

///|
test "toaster_node uses single-layer liquid glass with >= 4.5:1 contrast in light, dark, and solid" {
  for dark in [false, true] {
    for solid in [false, true] {
      let toasts = @signals.signal([toast("w3b", "已归档 3 条对话", action="撤销")])
      let t = @ui.Tester::new(fn(_c) {  }, w=420.0, h=360.0, dark~, platform=0)
      set_dark(Some(dark))
      @ui.set_glass_solid(if solid { Some(true) } else { None })
      @ui.set_view_app(
        fn(root) {
          root.box(fn(bg) {
            bg.grow(Is(1.0)).ground(By(fn() { theme().p.bg })) |> ignore
            toaster_node(
              bg,
              fn() { toasts.get() },
              fn(_) { 60000.0 },
              fn() { 20.0 },
              fn(_) {  },
              fn(_) {  },
              key="w3b-toast-\{dark}-\{solid}",
            )
            |> ignore
          })
          |> ignore
        },
        theme=ui_theme_now,
      )
      t.run_for(@ui.move_most_ms)
      let glass = t.drawn_glass()
      let expected_glass = if solid { 0 } else { 1 }
      let liquid_count = glass.filter(fn(g) { g.4 == 6 }).length()
      let audits = t
        .audit()
        .filter(fn(a) { !(solid && a.has_prefix("rule 4:")) })
      @ui.set_glass_solid(None)
      assert_eq((dark, solid, glass.length(), liquid_count, audits), (dark, solid, expected_glass, expected_glass, []))
    }
  }
  set_dark(None)
}
