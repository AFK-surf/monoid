// The bar across the top of a file opened over a wide window as nodes (viewer_bar_node): both its left back pill (32pt
// high -> 16pt full capsule) and its right tools pill (36pt high -> 18pt full capsule) keep full capsule corners across
// macOS (16pt window corners, inset and non-inset), Windows 11 (8pt), and square windows (0pt), standing clear of
// rounded window corners so `corner_faults` stays clean at rest and under hover.

///|
/// The bar's corner faults, its way back pointed at, in a window `corner` round; and whether its hover ground is drawn
/// there then (what is held to the rule: no ground, nothing to hold).
fn back_pointed_faults(corner : Double) -> (Bool, Array[String]) {
  let ink : ViewerInk = {
    ground: 0x222222FFL,
    ink: 0xFFFFFFFFL,
    muted: 0xAAAAAAFFL,
    line: 0x444444FFL,
    hover: 0x2427E70FL,
    chosen: 0x2427E71FL,
  }
  let t = @ui.Tester::new(fn(_c) {  }, w=1280.0, h=800.0, window_corner=corner, platform=0, corners_held=false)
  @ui.set_view_app(fn(root) { viewer_bar_test_node(root, ink, fn() { false }) })
  t.draw()
  let (x, y, w, h) = t.rect_of("整理发布清单").unwrap()
  t.move_to(x + w / 2.0, y + h / 2.0)
  t.frame()
  t.frame()
  let lit = t.drawn_rects().iter().any(fn(r) { r.4 == ink.hover && r.0 <= x && r.1 <= y && r.0 + r.2 >= x + w && r.1 + r.3 >= y + h })
  (lit, t.corner_faults())
}

///|
test "the viewer's bar across the top: its way back pointed at, its hover ground drawn, in a window 16 round keeps the corner rule" {
  let (lit, faults) = back_pointed_faults(16.0)
  assert_eq((lit, faults), (true, []), msg=faults.join("\n"))
}

///|
test "the viewer's bar across the top: its way back pointed at, its hover ground drawn, in a square window keeps the corner rule" {
  let (lit, faults) = back_pointed_faults(0.0)
  assert_eq((lit, faults), (true, []), msg=faults.join("\n"))
}

///|
test "viewer_bar_node: left back pill (16pt) and right tools pill (18pt) are full capsules across platforms with zero corner faults" {
  let ink : ViewerInk = {
    ground: 0xF7F7FAFFL,
    ink: 0x111111FFL,
    muted: 0x666666FFL,
    line: 0xE0E0E4FFL,
    hover: 0x2427E70FL,
    chosen: 0x2427E71FL,
  }
  for (platform, corner, inset) in [(0, 16.0, true), (0, 16.0, false), (3, 8.0, true), (2, 0.0, false)] {
    let t = @ui.Tester::new(fn(_c) {  }, w=1280.0, h=800.0, window_corner=corner, platform~, corners_held=false)
    t.set_window_inset(inset)
    @ui.set_view_app(fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      let tips = TipLayer::new(fn() { Some(root) })
      viewer_bar_node(
        root,
        fn() { "整理发布清单" },
        fn() { "a.png" },
        fn() { "18 KB" },
        fn() { "" },
        fn() { false },
        fn(_) { 1.0 },
        fn() { 0.0 },
        fn() { 1280.0 },
        fn() { ink },
        fn(row, tool_corner) {
          tool_node(
            row,
            fn() { { icon: "copy", label: "Copy", on: false, disabled: false } },
            fn() { ink },
            tool_corner,
            fn() {  },
            tip=tips,
          )
          |> ignore
          tool_node(
            row,
            fn() { { icon: "download", label: "Download", on: false, disabled: false } },
            fn() { ink },
            tool_corner,
            fn() {  },
            tip=tips,
          )
          |> ignore
        },
        fn() {  },
        tips,
      )
      |> ignore
    })
    t.draw()
    let glass = t.drawn_glass_corners().filter(fn(g) { g.3 >= 30.0 && g.3 <= 40.0 })
    assert_eq(
      glass.length(),
      2,
      msg="platform=\{platform} corner=\{corner} inset=\{inset}: expected 2 bar pills, got \{Repr(glass)}",
    )
    let left_pill = if glass[0].0 < glass[1].0 { glass[0] } else { glass[1] }
    let right_pill = if glass[0].0 < glass[1].0 { glass[1] } else { glass[0] }
    assert_true(
      (left_pill.3 - 32.0).abs() < 0.01 && (left_pill.4 - 16.0).abs() < 0.01,
      msg="platform=\{platform} corner=\{corner} inset=\{inset}: back pill must be 32pt full capsule (r=16), got \{Repr(left_pill)}",
    )
    assert_true(
      (right_pill.3 - 36.0).abs() < 0.01 && (right_pill.4 - 18.0).abs() < 0.01,
      msg="platform=\{platform} corner=\{corner} inset=\{inset}: tools pill must be 36pt full capsule (r=18), got \{Repr(right_pill)}",
    )
    let faults = t.corner_faults()
    assert_eq(faults, [], msg="platform=\{platform} corner=\{corner} inset=\{inset} at rest:\n" + faults.join("\n"))
    let lit_faults = t.lit_all_faults()
    assert_eq(lit_faults, [], msg="platform=\{platform} corner=\{corner} inset=\{inset} lit:\n" + lit_faults.join("\n"))
  }
}

///|
/// The bar across the top of a file opened as nodes, over `root` 1280 wide: back to "整理发布清单", the file "a.png" of
/// "18 KB", no tools, gone up out of the way while `hidden` says.
fn viewer_bar_test_node(root : @view.View, ink : ViewerInk, hidden : () -> Bool) -> Unit {
  let tips = TipLayer::new(fn() { Some(root) })
  viewer_bar_node(
    root,
    fn() { "整理发布清单" },
    fn() { "a.png" },
    fn() { "18 KB" },
    fn() { "" },
    hidden,
    fn(_) { 1.0 },
    fn() { 0.0 },
    fn() { 1280.0 },
    fn() { ink },
    fn(_, _) {  },
    fn() {  },
    tips,
  )
  |> ignore
}
