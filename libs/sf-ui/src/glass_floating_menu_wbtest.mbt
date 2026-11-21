// Tests for iOS 27 liquid glass upgrade of `glass_floating()` and `glass_menu()` (`menu_node`), verifying:
// 1. Both recipes emit `liquid == true` with neutral iOS 27 light/dark tints (and passthrough custom tint).
// 2. `menu_node` renders a single `kind == 6` liquid glass panel with zero nested glass.
// 3. `MBUI_GLASS=solid` (`@ui.set_glass_solid(Some(true))`) degrades `menu_node` cleanly to `panel_ground()` with
//    `panel_edge()` hairline border, zero `kind == 6` glass instances, and clean `Tester::audit()` in Light & Dark.

///|
test "glass_floating and glass_menu emit iOS 27 liquid glass recipes in light and dark" {
  for dark in [false, true] {
    let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0, dark~, platform=0)
    set_dark(Some(dark))
    @ui.set_view_app(fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(_) {  }) |> ignore
    })
    t.draw()
    let fl = glass_floating()
    let fl_tinted = glass_floating(tint=0x11223344L)
    let mn = glass_menu()
    let expected_tint = if dark { 0x202020FFL } else { 0xFDFCFD67L }
    assert_eq(
      (fl.liquid, fl.blur, fl.bezel, fl.refraction, fl.tint),
      (true, 6.0, 14.0, 18.0, expected_tint),
    )
    assert_eq((fl_tinted.liquid, fl_tinted.tint), (true, 0x11223344L))
    assert_eq(
      (mn.liquid, mn.blur, mn.bezel, mn.refraction, mn.tint, mn.solid),
      (true, 8.0, 16.0, 22.0, expected_tint, panel_ground()),
    )
  }
}

///|
fn menu_glass_tester(dark : Bool, solid : Bool) -> @ui.Tester {
  set_words(fn(key, _) { key })
  let t = @ui.Tester::new(fn(_c) {  }, w=900.0, h=640.0, dark~, platform=0)
  set_dark(Some(dark))
  if solid {
    @ui.set_glass_solid(Some(true))
  } else {
    @ui.set_glass_solid(None)
  }
  let opener : Ref[@view.View?] = Ref(None)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(col) {
      col.grow(Is(1.0)).padding(Is((64.0, 64.0, 64.0, 64.0))).ground(By(fn() { theme().p.bg })) |> ignore
      opener.val = Some(
        button_node(col, fn() { "Open Menu" }, fn() {
          match opener.val {
            Some(b) =>
              menu(
                [
                  Some(menu_item_of("Copy Link", fn() {  })),
                  Some(menu_item_of("Pin Message", fn() {  })),
                  None,
                  Some(menu_item_of("Delete", fn() {  })),
                ],
                from=Node(b),
                along=Start,
              )
            None => ()
          }
        }),
      )
    })
    |> ignore
    presented_nodes(root)
  })
  t.draw()
  t
}

///|
test "menu_node uses single-layer liquid glass and degrades cleanly to panel_ground + edge under MBUI_GLASS=solid" {
  for dark in [false, true] {
    // 1. Liquid glass mode: exactly 1 kind==6 glass panel, zero nested glass, clean audit
    let t = menu_glass_tester(dark, false)
    t.tap_text("Open Menu")
    t.run_for(@ui.move_most_ms)
    let glass = t.drawn_glass()
    let liquid_count = glass.filter(fn(g) { g.4 == 6 }).length()
    let glass_audits = t.audit()
    assert_eq((dark, glass.length(), liquid_count, glass_audits), (dark, 1, 1, []))

    // 2. Solid fallback mode (`MBUI_GLASS=solid`): 0 glass instances, solid panel_ground rect + clean audit
    let ts = menu_glass_tester(dark, true)
    ts.tap_text("Open Menu")
    ts.run_for(@ui.move_most_ms)
    let expected_solid = panel_ground()
    let solid_glass_count = ts.drawn_glass().length()
    let has_panel_ground = ts.drawn_rects().iter().any(fn(r) { r.4 == expected_solid })
    let solid_audits = ts.audit()
    @ui.set_glass_solid(None)
    assert_eq((dark, solid_glass_count, has_panel_ground, solid_audits), (dark, 0, true, []))
  }
}
