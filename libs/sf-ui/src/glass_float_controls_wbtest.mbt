// Tests for single-layer iOS 27 liquid glass floating button groups (`pick_bar_node`, `float_button_node`):
// 1. Default liquid glass mode in Light & Dark: exactly 1 `kind == 6` glass surface (single-layer, zero nesting),
//    outside-only float shadow (`shadow_outside == true`), zero extra solid ground fill rects on the control, and clean
//    `Tester::audit()`.
// 2. `MBUI_GLASS=solid` (`@ui.set_glass_solid(Some(true))`) fallback mode in Light & Dark: 0 glass instances, opaque
//    `panel_ground()` fallback fill, 0.5pt `control_edge_w` hairline `theme().p.line` border, and clean `Tester::audit()`.

///|
fn float_control_tester(kind : String, dark : Bool, solid : Bool) -> @ui.Tester {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=400.0, dark~, platform=0)
  set_dark(Some(dark))
  @ui.set_glass_solid(if solid { Some(true) } else { None })
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((48.0, 48.0, 48.0, 48.0))).lines_up(Is(Some(Start))).ground(By(fn() { theme().p.bg }))
        |> ignore
        if kind == "pick_bar" {
          pick_bar_node(page, [
            { label: "引用", icon: "quote", mark: false, press: fn() {  } },
            { label: "复制", icon: "copy", mark: false, press: fn() {  } },
            { label: "全选", icon: "", mark: false, press: fn() {  } },
            { label: "多选", icon: "check-square", mark: true, press: fn() {  } },
          ])
          |> ignore
        } else {
          float_button_node(page, "arrow-down", fn() { "回到底部" }, fn() {  }, count=fn() { "3 条新消息" }) |> ignore
        }
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "pick_bar_node and float_button_node use single-layer liquid glass with shadow_outside and degrade cleanly under MBUI_GLASS=solid" {
  for kind in ["pick_bar", "float_button"] {
    for dark in [false, true] {
      // 1. Default liquid glass mode
      let t = float_control_tester(kind, dark, false)
      let glass = t.drawn_glass()
      let liquid_count = glass.filter(fn(g) { g.4 == 6 }).length()
      let outside_shadow = has_outside_shadow(t)
      let expected_solid = panel_ground()
      let has_shell_solid_fill = match glass.get(0) {
        Some(g) =>
          t
          .drawn_rects()
          .iter()
          .any(fn(r) {
            (r.4 & 0xFFL) != 0L &&
            (r.0 - g.0).abs() < 1.0 &&
            (r.1 - g.1).abs() < 1.0 &&
            (r.2 - g.2).abs() < 1.0 &&
            (r.3 - g.3).abs() < 1.0
          })
        None => false
      }
      let glass_edges = t.boxes_held().filter(fn(b) { b.border_w > 0.0 && b.w >= 20.0 })
      let glass_audits = t.audit()
      assert_eq(
        (kind, dark, glass.length(), liquid_count, outside_shadow, has_shell_solid_fill, glass_edges.length(), glass_audits),
        (kind, dark, 1, 1, true, false, 0, []),
      )

      // 2. Solid fallback mode (`MBUI_GLASS=solid`)
      let ts = float_control_tester(kind, dark, true)
      let solid_glass_count = ts.drawn_glass().length()
      let has_solid_ground = ts.drawn_rects().iter().any(fn(r) { r.4 == expected_solid })
      let solid_edges = ts
        .boxes_held()
        .filter(fn(b) { b.border_w > 0.0 && b.w >= 20.0 })
        .map(fn(b) { (b.border_w, b.border_c) })
      let solid_audits = ts.audit()
      @ui.set_glass_solid(None)
      assert_eq(
        (kind, dark, solid_glass_count, has_solid_ground, solid_edges, solid_audits),
        (kind, dark, 0, true, [(control_edge_w, theme().p.line)], []),
      )
    }
  }
  @ui.set_glass_solid(None)
  set_dark(None)
}
