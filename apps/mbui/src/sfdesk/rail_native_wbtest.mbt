// Pure floating-button equality checks used by native_workspace_placed to skip redundant @hostapi.nav_bar calls.

///|
test "nav_floating_same detects changes in every geometry and item field" {
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
  assert_true(nav_floating_same([], []))
  assert_true(nav_floating_same([base], [same]))
  assert_false(nav_floating_same([base], []))
  assert_false(nav_floating_same([base], [{ ..same, x: 13.0 }]))
  assert_false(nav_floating_same([base], [{ ..same, y: 17.0 }]))
  assert_false(nav_floating_same([base], [{ ..same, w: 121.0 }]))
  assert_false(nav_floating_same([base], [{ ..same, h: 37.0 }]))
  assert_false(nav_floating_same([base], [{ ..same, blocked: true }]))
  assert_false(nav_floating_same([base], [{ ..same, item: { ..item, id: "other" } }]))
  assert_false(nav_floating_same([base], [{ ..same, item: { ..item, title: "Other" } }]))
  assert_false(nav_floating_same([base], [{ ..same, item: { ..item, icon: "badge:ff0000ff,M" } }]))
  assert_false(nav_floating_same([base], [{ ..same, item: { ..item, dot: true } }]))
  assert_false(nav_floating_same([base], [{ ..same, item: { ..item, prominent: false } }]))
  assert_false(nav_floating_same([base], [{ ..same, item: { ..item, menu: [("r1", "All", true, "i1")] } }]))
  assert_false(
    nav_floating_same([base], [{ ..same, item: { ..item, menu: [("r2", "Mine", false, "i2"), ("r1", "All", true, "i1")] } }]),
  )
  assert_false(
    nav_floating_same([base], [{ ..same, item: { ..item, menu: [("r1", "All", false, "i1"), ("r2", "Mine", false, "i2")] } }]),
  )
}
