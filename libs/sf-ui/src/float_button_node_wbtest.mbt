// The round button over a list keeps its ground under the hand: the hover tint is composited over its canvas via
// hover_ground_node (View::ground_over), never replacing Surface with a translucent tint (2026-11-14).

///|
test "float button: its ground under the hand stays opaque and visibly tinted in light and dark" {
  for dark in [false, true] {
    let t = @ui.Tester::new(fn(_c) {  }, w=200.0, h=160.0, platform=0)
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
    let fills0 = t.drawn_rects().filter(fn(r) { (r.4 & 0xFFL) != 0L })
    assert_eq(fills0.length(), 1, msg="dark=\{dark}: \{fills0.length()}")
    let (px, py, pw, ph, rest_bg) = fills0[0]
    assert_eq(rest_bg & 0xFFL, 0xFFL, msg="dark=\{dark} rest=\{rest_bg}")
    t.move_to(px + pw / 2.0, py + ph / 2.0)
    t.run_for(dur_ms + 30.0)
    let fills1 = t.drawn_rects().filter(fn(r) { (r.4 & 0xFFL) != 0L })
    assert_eq(fills1.length(), 1, msg="dark=\{dark}: \{fills1.length()}")
    let lit = fills1[0].4
    assert_eq(lit & 0xFFL, 0xFFL, msg="dark=\{dark} lit=\{lit}")
    assert_true(lit != rest_bg, msg="dark=\{dark}: hover tint did not composite over Surface")
  }
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
