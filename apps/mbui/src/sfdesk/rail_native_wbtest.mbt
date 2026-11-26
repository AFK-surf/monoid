// Verifies native floating button deduplication and preservation across full-window `bare` overlays.

///|
test "native_workspace_placed preserves native_floating during bare overlays and dedupes equal floating via Eq" {
  rail_native_reset()
  let item : @hostapi.NavItem = {
    id: "workspace-switch",
    title: "Main",
    icon: "badge:336699ff,M",
    dot: false,
    prominent: true,
    menu: [("r1", "All", true, "i1"), ("r2", "Mine", false, "i2")],
  }
  let base : @hostapi.NavFloating = { item, x: 12.0, y: 16.0, w: 120.0, h: 36.0, blocked: false }
  let same : @hostapi.NavFloating = {
    item: {
      id: "workspace-switch",
      title: "Main",
      icon: "badge:336699ff,M",
      dot: false,
      prominent: true,
      menu: [("r1", "All", true, "i1"), ("r2", "Mine", false, "i2")],
    },
    x: 12.0,
    y: 16.0,
    w: 120.0,
    h: 36.0,
    blocked: false,
  }
  assert_true([base] == [same])
  assert_false([base] == [{ ..same, x: 13.0 }])
  assert_false([base] == [{ ..same, blocked: true }])
  assert_false([base] == [{ ..same, item: { ..item, dot: true } }])

  // While `bare: true`, native_workspace_placed must keep `native_floating` intact so closing `bare`
  // immediately re-sends the cached floating items on `nav_frame` and reuses native glass buttons.
  let bare_bar : @hostapi.NavBar = {
    floating: [base],
    groups: [],
    selected: "",
    ink: 0L,
    chosen_ink: 0L,
    more_icon: "",
    bare: true,
    title: "Preview",
  }
  native_floating.val = [base]
  native_floating_sent.val = Some([base])
  floating_bar.val = Some(bare_bar)
  let t = @ui.Tester::new(fn(c) { native_workspace_placed(c) }, w=669.0, h=951.0)
  t.run_for(@ui.move_most_ms)
  assert_true(native_floating.val == [base])
  assert_true(native_floating_sent.val == Some([base]))

  // Once `bare` clears, native_workspace_placed reconciles against current semantics (empty here).
  floating_bar.val = Some({ ..bare_bar, bare: false })
  t.run_for(@ui.move_most_ms)
  assert_true(native_floating.val == [])
  assert_true(native_floating_sent.val == Some([]))
  rail_native_reset()
}
