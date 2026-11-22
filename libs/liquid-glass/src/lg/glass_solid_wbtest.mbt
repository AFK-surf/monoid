// Automated `MBUI_GLASS=solid` (`@ui.set_glass_solid(Some(true))`) degradation audit across core Liquid Glass
// components in both Light and Dark themes:
// 1. Zero `kind == 6` (`Glass::liquid`) GPU instances emitted when solid fallback is enabled.
// 2. Clean foreground contrast, zero corner faults, and zero squeeze faults under `Tester::audit()`.

///|
fn solid_case(dark : Bool, make : (@view.View) -> Unit) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=900.0, h=760.0, dark~, platform=0)
  @ui.set_glass_solid(Some(true))
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
test "MBUI_GLASS=solid degrades all core Liquid Glass controls cleanly to solid with zero audit faults" {
  for dark in [false, true] {
    let toggle_on = @signals.signal(true)
    let slider_val = @signals.signal(55.0)
    let tab_idx = @signals.signal(0)
    let ctab_min = @signals.signal(false)
    let smorph_exp = @signals.signal(true)
    let search_field = @ui.Field::new()
    let t = solid_case(dark, fn(page) {
      page.box(fn(row) {
        row.row(Is(true)).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
        liquid_button_node(row, fn() { "Primary" }, fn() {  }) |> ignore
        liquid_button_node(row, fn() { "Tinted" }, fn() {  }, tint=0x0066CCFFL) |> ignore
        liquid_toggle_node(row, fn() { toggle_on.get() }, fn(v) { toggle_on.set(v) }, fn() { "Wi-Fi" }) |> ignore
      })
      |> ignore
      page.box(fn(s) {
        s.width(Is(Some(320.0))) |> ignore
        liquid_slider_node(s, fn() { slider_val.get() }, fn(v) { slider_val.set(v) }, fn() { "Volume" }) |> ignore
      })
      |> ignore
      page.box(fn(tabs_wrap) {
        tabs_wrap.width(Is(Some(360.0))) |> ignore
        liquid_bottom_tabs_node(
          tabs_wrap,
          ["Home", "Explore", "Library"],
          fn() { tab_idx.get() },
          fn(i) { tab_idx.set(i) },
          label="Solid Tabs",
        )
        |> ignore
      })
      |> ignore
      liquid_collapsible_tabs_node(
        page,
        ["Home", "Browse", "Radio"],
        fn() { tab_idx.get() },
        fn(i) { tab_idx.set(i) },
        fn() { ctab_min.get() },
        fn() { ctab_min.set(false) },
        fn() {  },
        label="Solid Collapsible Tabs",
      )
      |> ignore
      liquid_search_morph_node(
        page,
        search_field,
        fn() { smorph_exp.get() },
        fn(v) { smorph_exp.set(v) },
        width=360.0,
        placeholder="Search library",
      )
      |> ignore
      liquid_merge_node(page, label=fn() { "Solid Merge" }) |> ignore
    })
    t.run_for(springs_out)
    let liquid_count = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    let audits = t.audit()
    @ui.set_glass_solid(None)
    assert_eq((dark, liquid_count, audits), (dark, 0, []))
  }
}

///|
test "MBUI_GLASS=solid degrades uplifted overlay shells, drawer, toast, toolbar, tooltip and scroll edge cleanly with zero audit faults" {
  for dark in [false, true] {
    let t = solid_case(dark, fn(page) {
      liquid_dialog_shell_node(page, radius=24.0, fn(d) {
        d.padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore
        d.box(fn(w) {
          w.words(Is("Solid Dialog Shell"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore
        })
        |> ignore
      })
      |> ignore
      liquid_toast_shell_node(page, fn(tb) {
        tb.padding(Is((14.0, 10.0, 14.0, 10.0))) |> ignore
        tb.box(fn(w) {
          w.words(Is("Solid Toast Shell"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore
        })
        |> ignore
      })
      |> ignore
      liquid_toast_node(page, fn() { true }, fn() { "Solid Toast" }, subtitle=fn() { "With hairline edge" }) |> ignore
      liquid_toolbar_node(page, pad=14.0, gap=10.0, fn(bar) {
        bar.box(fn(w) { w.words(Is("Solid Toolbar"), look=words_at(ovl_type_sub)).ink(By(fn() { colors().content })) |> ignore })
        |> ignore
      })
      |> ignore
      liquid_tooltip_bubble_node(page, fn() { "Solid Tip" }, shortcut=fn() { "⌘P" }) |> ignore
      liquid_scroll_edge_node(page, fn(_) { 48.0 }, fn(_) { 48.0 }, side=Top) |> ignore
    })
    t.run_for(springs_out)
    let liquid_count = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    let audits = t.audit()
    @ui.set_glass_solid(None)
    assert_eq((dark, liquid_count, audits), (dark, 0, []))
  }
}
