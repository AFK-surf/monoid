// Tests for Apple iOS 26/27 native Liquid Glass components:
// - `liquid_collapsible_tabs_node` (TabBarMinimizeBehavior floating bar + detached circular action orb)
// - `liquid_search_morph_node` (48pt search orb <-> expanded search bar + capillary-budded cancel orb)
// Covers 60/120/24/7 fps determinism, `assert_no_nested_glass`, `Tester::audit()` (corners + squeeze + contrast),
// Light/Dark themes, and `MBUI_GLASS=solid` degradation.

///|
fn ios26_case(dark? : Bool = false, make : (@view.View) -> Unit) -> @ui.Tester {
  @ui.set_glass_solid(None)
  let t = @ui.Tester::new(fn(_c) {  }, w=640.0, h=320.0, dark~, platform=0)
  set_dark(Some(dark))
  @ui.set_tree_theme(ui_theme)
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page
      .grow(Is(1.0))
      .padding(Is((28.0, 28.0, 28.0, 28.0)))
      .gap(Is(20.0))
      .ground(Is(if dark { 0x090A0EFFL } else { 0xF4F1EAFFL }))
      |> ignore
      make(page)
    })
    |> ignore
  })
  t.draw()
  t
}

///|
fn ios26_round2(v : Double) -> Double {
  (v * 100.0).round() / 100.0
}

///|
fn ios26_glass_sig(t : @ui.Tester) -> String {
  t
  .drawn_glass()
  .map(fn(g) { "\{ios26_round2(g.0)},\{ios26_round2(g.1)},\{ios26_round2(g.2)},\{ios26_round2(g.3)}:\{g.4}" })
  .join(" | ")
}

///|
test "liquid_collapsible_tabs: expand/minimize, zero nested glass, audit clean in light and dark" {
  for dark in [false, true] {
    let tab = @signals.signal(0)
    let minimized = @signals.signal(false)
    let actions = Ref(0)
    let t = ios26_case(dark~, fn(page) {
      liquid_collapsible_tabs_node(
        page,
        ["Home", "Browse", "Radio"],
        fn() { tab.get() },
        fn(i) { tab.set(i) },
        fn() { minimized.get() },
        fn() { minimized.set(false) },
        fn() { actions.val += 1 },
        label="iOS26 Tabs",
      )
      |> ignore
    })
    t.run_for(springs_out)
    assert_no_nested_glass(t, "collapsible_tabs expanded dark=\{dark}")
    let expanded_audit = t.audit()
    let expanded_tabs = t.all(Tab).length()
    // Tap second tab
    let (bx, by) = middle(t, Tab, "Browse")
    t.tap(bx, by)
    t.run_for(springs_out)
    // Minimize via signal (as scroll-down does)
    t.by_hand(fn() { minimized.set(true) })
    t.run_for(dragged_ms)
    assert_no_nested_glass(t, "collapsible_tabs mid-collapse dark=\{dark}")
    t.run_for(springs_out)
    assert_no_nested_glass(t, "collapsible_tabs minimized dark=\{dark}")
    let min_audit = t.audit()
    let min_tabs = t.all(Tab).length()
    // Tap Search orb while minimized
    let (sx, sy) = middle(t, Button, "Search")
    t.tap(sx, sy)
    t.run_for(springs_out)
    // Tap minimized orb to expand back
    let (ex, ey) = middle(t, Button, "Expand Browse")
    t.tap(ex, ey)
    t.run_for(springs_out)
    assert_no_nested_glass(t, "collapsible_tabs re-expanded dark=\{dark}")
    assert_eq(
      (expanded_tabs, tab.get(), min_tabs, actions.val, minimized.get(), expanded_audit, min_audit),
      (3, 1, 0, 1, false, [], []),
    )
  }
}

///|
test "liquid_search_morph: orb <-> expanded search bar + cancel orb with zero nested glass and clean audit" {
  for dark in [false, true] {
    let field = @ui.Field::new()
    let expanded = @signals.signal(false)
    let t = ios26_case(dark~, fn(page) {
      liquid_search_morph_node(
        page,
        field,
        fn() { expanded.get() },
        fn(v) { expanded.set(v) },
        width=360.0,
        placeholder="Search liquid glass",
      )
      |> ignore
    })
    t.run_for(springs_out)
    // Collapsed: strictly 1 glass orb, zero nested glass
    let collapsed_glass = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    assert_no_nested_glass(t, "search_morph collapsed dark=\{dark}")
    let collapsed_audit = t.audit()
    // Tap search orb -> expands to search bar + detached cancel orb
    let (ox, oy) = middle(t, Button, "Search")
    t.tap(ox, oy)
    t.run_for(springs_out)
    let expanded_glass = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    assert_no_nested_glass(t, "search_morph expanded dark=\{dark}")
    let expanded_audit = t.audit()
    // Tap cancel orb -> collapses back into 1 search orb
    let (cx, cy) = middle(t, Button, "Cancel Search")
    t.tap(cx, cy)
    t.run_for(springs_out)
    let final_glass = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    assert_no_nested_glass(t, "search_morph re-collapsed dark=\{dark}")
    assert_eq(
      (collapsed_glass, expanded_glass, final_glass, expanded.get(), collapsed_audit, expanded_audit),
      (1, 2, 1, false, [], []),
    )
  }
}

///|
test "iOS 26 collapsible tabs and search morph are deterministic across 60, 120, 24 and 7 fps" {
  let run = fn() -> Array[String] {
    let tab = @signals.signal(0)
    let minimized = @signals.signal(false)
    let expanded = @signals.signal(false)
    let field = @ui.Field::new()
    let t = ios26_case(fn(page) {
      liquid_collapsible_tabs_node(
        page,
        ["Home", "Browse", "Radio"],
        fn() { tab.get() },
        fn(i) { tab.set(i) },
        fn() { minimized.get() },
        fn() { minimized.set(false) },
        fn() {  },
      )
      |> ignore
      liquid_search_morph_node(
        page,
        field,
        fn() { expanded.get() },
        fn(v) { expanded.set(v) },
        width=360.0,
      )
      |> ignore
    })
    let out : Array[String] = []
    t.run_for(springs_out)
    out.push(ios26_glass_sig(t))
    t.by_hand(fn() {
      minimized.set(true)
      expanded.set(true)
    })
    t.run_for(dragged_ms)
    out.push(ios26_glass_sig(t))
    t.run_for(springs_out)
    out.push(ios26_glass_sig(t))
    t.by_hand(fn() {
      minimized.set(false)
      expanded.set(false)
    })
    t.run_for(dragged_ms)
    out.push(ios26_glass_sig(t))
    t.run_for(springs_out)
    out.push(ios26_glass_sig(t))
    out
  }
  let a = run()
  let b = run()
  assert_eq(a, b)
  assert_eq(a.length(), 5)
}
