// White-box regression tests for `ui/glass`:
// 1. `MBUI_GLASS=solid` degradation audit across all production glass controls and surface decorators
//    (zero `kind == 6` GPU liquid instances, zero `Tester::audit()` faults in Light and Dark).
// 2. Interactive behavior regressions for toggle, slider, segmented control, pill group press scope,
//    surface decorators `active=false` zero-hidden-glass gating, and `LiquidMerge` capillary split/fuse.

///|
let glass_springs_out : Double = 1000.0

///|
fn glass_case(dark : Bool, solid : Bool, make : (@view.View) -> Unit) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=900.0, h=760.0, dark~, platform=0)
  @ui.set_glass_solid(if solid { Some(true) } else { None })
  set_dark(Some(dark))
  @ui.set_tree_theme(ui_theme)
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page
      .grow(Is(1.0))
      .padding(Is((24.0, 24.0, 24.0, 24.0)))
      .gap(Is(16.0))
      .ground(Is(if dark { 0x0B0C10FFL } else { 0xF4F1EAFFL }))
      |> ignore
      make(page)
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "MBUI_GLASS=solid degrades all sf/glass controls and decorators cleanly with zero audit faults" {
  for dark in [false, true] {
    let toggle_on = @signals.signal(true)
    let slider_val = @signals.signal(55.0)
    let seg_idx = @signals.signal(1)
    let t = glass_case(dark, true, fn(page) {
      page.box(fn(row) {
        row.row(Is(true)).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
        liquid_toggle_node(row, fn() { toggle_on.get() }, fn(v) { toggle_on.set(v) }, fn() { "Wi-Fi" }) |> ignore
        liquid_pill_group_node(row, height=40.0, pad=4.0, fn(g) {
          g.box(fn(w) { w.padding(Is((10.0, 0.0, 10.0, 0.0))).words(Is("Pill"), look=words_at(14.0)).ink(By(fn() { colors().content })) |> ignore }) |> ignore
        })
        |> ignore
        liquid_capsule_node(row, tone=Floating, radius=Some(20.0), fn(c) {
          c.padding(Is((14.0, 8.0, 14.0, 8.0))) |> ignore
          c.box(fn(w) { w.words(Is("Capsule"), look=words_at(14.0)).ink(By(fn() { colors().content })) |> ignore }) |> ignore
        })
        |> ignore
      })
      |> ignore
      page.box(fn(s) {
        s.width(Is(Some(320.0))) |> ignore
        liquid_slider_node(s, fn() { slider_val.get() }, fn(v) { slider_val.set(v) }, fn() { "Volume" }) |> ignore
      })
      |> ignore
      liquid_segmented_node(
        page,
        fn() { ["Day", "Week", "Month"] },
        fn() { seg_idx.get() },
        fn(i) { seg_idx.set(i) },
        width=320.0,
      )
      |> ignore
      liquid_panel_shell_node(page, fn(p) {
        p.padding(Is((14.0, 10.0, 14.0, 10.0))) |> ignore
        p.box(fn(w) { w.words(Is("Panel Shell"), look=words_at(14.0)).ink(By(fn() { colors().content })) |> ignore }) |> ignore
      })
      |> ignore
      page.box(fn(surfaces) {
        surfaces.row(Is(true)).gap(Is(10.0)) |> ignore
        surfaces.box(fn(pop) {
          pop.padding(Is((12.0, 8.0, 12.0, 8.0))) |> ignore
          liquid_popover_surface_decorate(pop, radius=16.0) |> ignore
          pop.box(fn(w) { w.words(Is("Popover"), look=words_at(13.0)).ink(By(fn() { colors().content })) |> ignore }) |> ignore
        })
        |> ignore
        surfaces.box(fn(tip) {
          tip.padding(Is((10.0, 6.0, 10.0, 6.0))) |> ignore
          liquid_tooltip_surface_decorate(tip, radius=12.0) |> ignore
          tip.box(fn(w) { w.words(Is("Tooltip"), look=words_at(13.0)).ink(By(fn() { colors().content })) |> ignore }) |> ignore
        })
        |> ignore
        surfaces.box(fn(drw) {
          drw.padding(Is((12.0, 8.0, 12.0, 8.0))) |> ignore
          liquid_drawer_surface_decorate(drw, radius=20.0) |> ignore
          drw.box(fn(w) { w.words(Is("Drawer"), look=words_at(13.0)).ink(By(fn() { colors().content })) |> ignore }) |> ignore
        })
        |> ignore
        surfaces.box(fn(sh) {
          sh.padding(Is((12.0, 8.0, 12.0, 8.0))) |> ignore
          liquid_sheet_surface_decorate(sh, radius=20.0) |> ignore
          sh.box(fn(w) { w.words(Is("Sheet"), look=words_at(13.0)).ink(By(fn() { colors().content })) |> ignore }) |> ignore
        })
        |> ignore
        surfaces.box(fn(dlg) {
          dlg.padding(Is((12.0, 8.0, 12.0, 8.0))) |> ignore
          liquid_dialog_surface_decorate(dlg, radius=20.0) |> ignore
          dlg.box(fn(w) { w.words(Is("Dialog"), look=words_at(13.0)).ink(By(fn() { colors().content })) |> ignore }) |> ignore
        })
        |> ignore
        surfaces.box(fn(tst) {
          tst.padding(Is((12.0, 8.0, 12.0, 8.0))) |> ignore
          liquid_toast_surface_decorate(tst, radius=20.0) |> ignore
          tst.box(fn(w) { w.words(Is("Toast"), look=words_at(13.0)).ink(By(fn() { colors().content })) |> ignore }) |> ignore
        })
        |> ignore
      })
      |> ignore
      liquid_merge_node(page, label=fn() { "Solid Merge" }) |> ignore
      liquid_scroll_edge_node(page, fn(_) { 40.0 }, fn(_) { 40.0 }, side=Top) |> ignore
    })
    t.run_for(glass_springs_out)
    let liquid_count = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    let audits = t.audit()
    @ui.set_glass_solid(None)
    assert_eq((dark, liquid_count, audits), (dark, 0, []))
  }
}

///|
test "sf/glass toggle, slider, segmented, pill_group, decorators active gating, and merge regressions" {
  let toggle_on = @signals.signal(false)
  let slider_val = @signals.signal(20.0)
  let seg_idx = @signals.signal(0)
  let deco_active = @signals.signal(false)
  let pill_pressed = @signals.signal(false)
  let merge_ctrl = LiquidMerge::new(separated=false)
  let t = glass_case(false, false, fn(page) {
    liquid_toggle_node(page, fn() { toggle_on.get() }, fn(v) { toggle_on.set(v) }, fn() { "Bluetooth" }) |> ignore
    page.box(fn(s) {
      s.width(Is(Some(240.0))) |> ignore
      liquid_slider_node(s, fn() { slider_val.get() }, fn(v) { slider_val.set(v) }, fn() { "Brightness" }) |> ignore
    })
    |> ignore
    liquid_segmented_node(
      page,
      fn() { ["One", "Two", "Three"] },
      fn() { seg_idx.get() },
      fn(i) { seg_idx.set(i) },
      width=300.0,
      glass_track=false,
    )
    |> ignore
    liquid_pill_group_node(page, height=36.0, pad=2.0, fn(g) {
      @headless.button(g, fn() { "Act" }, fn(_) { pill_pressed.set(true) }, fn(b, _) {
        bind_pill_press(b)
        b.width(Is(Some(32.0))).height(Is(Some(32.0))).radius(Is(16.0)) |> ignore
      })
      |> ignore
    })
    |> ignore
    page.box(fn(gated) {
      gated.width(Is(Some(120.0))).height(Is(Some(40.0))) |> ignore
      liquid_panel_surface_decorate(gated, radius=16.0, active=fn() { deco_active.get() }) |> ignore
    })
    |> ignore
    liquid_merge_node(page, controller=merge_ctrl, label=fn() { "Merge" }) |> ignore
  })
  t.run_for(glass_springs_out)
  // Inactive panel decorator emits zero glass; only pill_group (1) + merge main & sat (2) = 3 liquid instances.
  let idle_glass = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
  assert_eq(idle_glass, 3)

  // Toggle via tap
  let r_sw = t.get(Switch, label="Bluetooth").rect
  t.tap(r_sw.0 + r_sw.2 / 2.0, r_sw.1 + r_sw.3 / 2.0)
  t.run_for(glass_springs_out)
  assert_eq(toggle_on.untracked(), true)

  // Segmented switch via tap
  let r_tab = t.get(Tab, label="Three").rect
  t.tap(r_tab.0 + r_tab.2 / 2.0, r_tab.1 + r_tab.3 / 2.0)
  t.run_for(glass_springs_out)
  assert_eq(seg_idx.untracked(), 2)

  // Pill group button press
  let r_btn = t.get(Button, label="Act").rect
  t.tap(r_btn.0 + r_btn.2 / 2.0, r_btn.1 + r_btn.3 / 2.0)
  t.run_for(glass_springs_out)
  assert_eq(pill_pressed.untracked(), true)

  // Enabling active panel decorator adds exactly 1 liquid glass instance
  deco_active.set(true)
  t.draw()
  let active_glass = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
  assert_eq(active_glass, 4)

  // LiquidMerge programmatic split and fuse
  t.by_hand(fn() { merge_ctrl.set_separated(true, at=t.time()) })
  t.run_for(glass_springs_out)
  assert_eq(merge_ctrl.is_separated(), true)
  assert_eq(merge_ctrl.is_bonded(), false)
  t.by_hand(fn() { merge_ctrl.set_separated(false, at=t.time()) })
  t.run_for(glass_springs_out)
  assert_eq(merge_ctrl.is_separated(), false)
  assert_eq(merge_ctrl.is_bonded(), true)
  assert_eq(t.audit(), [])
}
