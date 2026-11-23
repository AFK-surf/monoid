// The round button over a list uses single-layer liquid glass (`glass_floating()`, the composer-top capsules') and layers the hover tint via
// `hover_ground_node` (`View::ground_over`) in light and dark, both on glass and under `MBUI_GLASS=solid`.

///|
test "float button: glass surface and hover tint work cleanly in light and dark" {
  for dark in [false, true] {
    @ui.set_glass_solid(None)
    let t = @ui.Tester::new(fn(_c) {  }, w=200.0, h=160.0, dark~, platform=0)
    set_dark(Some(dark))
    @ui.set_tree_theme(ui_theme_now)
    @ui.set_view_app(fn(root) {
      root.box(fn(page) {
        page.pad(Is(24.0)).lines_up(Is(Some(Start))) |> ignore
        float_button_node(page, "arrow-down", fn() { "回到底部" }, fn() {  }) |> ignore
      })
      |> ignore
    })
    t.draw()
    let glass0 = t.drawn_glass()
    assert_eq(glass0.length(), 1, msg="dark=\{dark}: glass count \{glass0.length()}")
    assert_eq(glass0[0].4, 6, msg="dark=\{dark}: glass kind \{glass0[0].4}")
    let fills0 = t.drawn_rects().filter(fn(r) { (r.4 & 0xFFL) != 0L })
    assert_eq(fills0.length(), 0, msg="dark=\{dark}: rest solid fills \{fills0.length()}")
    let (px, py, pw, ph, _, _) = glass0[0]
    t.move_to(px + pw / 2.0, py + ph / 2.0)
    t.run_for(dur_ms + 30.0)
    let glass1 = t.drawn_glass()
    assert_eq(glass1.length(), 1, msg="dark=\{dark}: hovered glass count \{glass1.length()}")
    let fills1 = t.drawn_rects().filter(fn(r) { (r.4 & 0xFFL) != 0L })
    assert_eq(fills1.length(), 1, msg="dark=\{dark}: hover wash rect \{fills1.length()}")
    assert_eq(fills1[0].4, @ui.tree_theme().color(Hover), msg="dark=\{dark}: hover tint \{fills1[0].4}")
  }
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "float buttons stacked over a list on a touch screen: each pressed in its own room, the audit clean" {
  let t = @ui.Tester::new(fn(_c) {  }, w=200.0, h=200.0, platform=2)
  @ui.set_tree_theme(ui_theme_now)
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.pad(Is(24.0)).lines_up(Is(Some(Start))) |> ignore
      float_button_node(page, "list", fn() { "对话目录" }, fn() {  }) |> ignore
      float_button_node(page, "arrow-down", fn() { "回到底部" }, fn() {  }) |> ignore
    })
    |> ignore
  })
  t.draw()
  let faults = t.audit()
  assert_true(faults.is_empty(), msg=faults.join("\n"))
}
