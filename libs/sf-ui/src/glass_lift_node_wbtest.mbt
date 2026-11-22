// Tests for `glass_lift_surface`: continuous flat-to-liquid-glass elevation across `t=0.0`, `t=0.35`, `t=1.0`,
// spring overshoot (`-0.1` / `1.2`), `MBUI_GLASS=solid` degradation, and Light/Dark `Tester::audit()` cleanliness.

///|
fn lift_approx(a : Double, b : Double) -> Bool {
  (a - b).abs() < 1.0e-5
}

///|
test "glass_lift_surface transitions cleanly across rest, mid-hold, full lift, and overshoot in light and dark" {
  for dark in [false, true] {
    let progress = @signals.signal(0.0, same=fn(a, b) { a == b })
    let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=400.0, dark~, platform=2)
    set_dark(Some(dark))
    @ui.set_glass_solid(None)
    @ui.set_view_app(fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
        page.box(fn(card) {
          card.width(Is(Some(320.0))).padding(Is((16.0, 12.0, 16.0, 12.0))) |> ignore
          glass_lift_surface(card, fn() { progress.get() }, flat_ground=Some(fn() { theme().p.canvas }))
          card.box(fn(w) {
            words_node(w, fn() { "Lifted Row Title" }, fn() { @ui.text_style(size=Ui, color=Fg) }) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t.draw()

    // t = 0.0: zero glass instances, zero captures, pure flat_ground, no shadow, clean audit.
    let flat_c = theme().p.canvas
    assert_eq(t.drawn_glass(), [])
    assert_eq(t.drawn_shadows(), [])
    assert_true(t.drawn_rects().iter().any(fn(r) { r.4 == flat_c && (r.2 - 320.0).abs() < 1.0 }))
    assert_eq(t.audit(), [])

    // t = 0.35: mid-materialisation liquid glass with proportional optical slots, full bezel, outside shadow.
    progress.set(0.35)
    t.run_for(@ui.frame_period_default)
    let menu_g = glass_menu()
    let glass35 = t.drawn_glass()
    assert_eq(glass35.length(), 1)
    assert_eq(glass35[0].4, 6)
    let inst35 = t.drawn_instances().filter(fn(a) { a.length() > 22 && a[5] == 6.0 })
    assert_eq(inst35.length(), 1)
    assert_true(lift_approx(inst35[0][7], menu_g.blur * 0.35))
    assert_true(lift_approx(inst35[0][12], menu_g.rim * 0.35))
    assert_true(lift_approx(inst35[0][13], menu_g.bezel))
    assert_true(lift_approx(inst35[0][15], 0.35))
    assert_true(lift_approx(inst35[0][21], menu_g.refraction * 0.35))
    assert_true(t.drawn_instances().iter().any(fn(a) { a.length() > 12 && a[5] == 2.0 && a[12] == 1.0 }))
    assert_eq(t.audit(), [])

    // t = 1.0: full single-layer kind==6 liquid glass, clean audit.
    progress.set(1.0)
    t.run_for(@ui.frame_period_default)
    let inst100 = t.drawn_instances().filter(fn(a) { a.length() > 22 && a[5] == 6.0 })
    assert_eq(inst100.length(), 1)
    assert_true(lift_approx(inst100[0][7], menu_g.blur))
    assert_true(lift_approx(inst100[0][12], menu_g.rim))
    assert_true(lift_approx(inst100[0][13], menu_g.bezel))
    assert_true(lift_approx(inst100[0][15], 1.0))
    assert_true(lift_approx(inst100[0][21], menu_g.refraction))
    assert_eq(t.audit(), [])

    // Spring overshoot: t = -0.1 clamps to rest (0 glass), t = 1.2 clamps to full (strength = 1.0).
    progress.set(-0.1)
    t.run_for(@ui.frame_period_default)
    assert_eq(t.drawn_glass(), [])
    assert_eq(t.drawn_shadows(), [])

    progress.set(1.2)
    t.run_for(@ui.frame_period_default)
    let inst_over = t.drawn_instances().filter(fn(a) { a.length() > 22 && a[5] == 6.0 })
    assert_eq(inst_over.length(), 1)
    assert_true(lift_approx(inst_over[0][15], 1.0))
  }
  set_dark(None)
}

///|
test "glass_lift_surface degrades cleanly under MBUI_GLASS=solid with smooth raised card fade" {
  for dark in [false, true] {
    let progress = @signals.signal(0.0, same=fn(a, b) { a == b })
    let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=400.0, dark~, platform=2)
    set_dark(Some(dark))
    @ui.set_glass_solid(Some(true))
    @ui.set_view_app(fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
        page.box(fn(card) {
          card.width(Is(Some(320.0))).padding(Is((16.0, 12.0, 16.0, 12.0))) |> ignore
          glass_lift_surface(card, fn() { progress.get() })
          card.box(fn(w) {
            words_node(w, fn() { "Solid Fallback Row" }, fn() { @ui.text_style(size=Ui, color=Fg) }) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t.draw()
    let raised_rgb = (theme().p.raised >> 8) & 0xFFFFFFL
    let card_alphas = fn() {
      t
      .drawn_rects()
      .filter(fn(r) { (r.2 - 320.0).abs() < 1.0 && ((r.4 >> 8) & 0xFFFFFFL) == raised_rgb })
      .map(fn(r) { (r.4 & 0xFFL).to_int() })
    }
    assert_eq(t.drawn_glass(), [])
    assert_eq(card_alphas(), [])

    progress.set(0.5)
    t.run_for(@ui.frame_period_default)
    assert_eq(t.drawn_glass(), [])
    let mid = card_alphas()
    assert_eq(mid.length(), 1)
    assert_true(mid[0] >= 126 && mid[0] <= 129, msg="expected ~128, got \{mid[0]}")

    progress.set(1.0)
    t.run_for(@ui.frame_period_default)
    let full = card_alphas()
    let audits = t.audit()
    @ui.set_glass_solid(None)
    assert_eq(t.drawn_glass(), [])
    assert_eq(full, [255])
    assert_eq(audits, [])
  }
  set_dark(None)
}
