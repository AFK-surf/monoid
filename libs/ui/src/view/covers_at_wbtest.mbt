///|
test "Tree::covers_at: top-bar body occludes taps while extended +28pt soft-edge fade tail passes taps through" {
  let fill_id : Ref[NodeId?] = Ref(None)
  let tree = Tree::new(fn(root) {
    root.width(Is(Some(390.0))).height(Is(Some(300.0))) |> ignore
    // Underlying content (e.g. a chat message/link) spanning the full viewport
    root.box(fn(under) {
      under
      .width(Is(Some(390.0)))
      .height(Is(Some(300.0)))
      .ground(Is(0x1C1C1EFFL))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    // Top-bar soft-edge scrim: outer container sets `fades` (matching `liquid_scroll_edge_node`),
    // inner child draws progressive frosted glass. Height = 44 (bar) + 28 (extended feather) = 72pt.
    // At y = 22 (inside bar): ramp = (72 - 22) / 72 = 0.694 >= 0.38 -> occludes underlying presses.
    // At y = 46 (2pt below bar foot): ramp = (72 - 46) / 72 = 0.361 < 0.38 -> passes presses through.
    // At y = 54 (10pt below bar foot): ramp = (72 - 54) / 72 = 0.25 < 0.38 -> passes presses through.
    root.box(fn(scrim) {
      scrim
      .over(Is(true), from_top=true)
      .height(Is(Some(72.0)))
      .fades(Is((0.0, 0.0, 0.0, 72.0)))
      |> ignore
      scrim.box(fn(fill) {
        fill_id.val = Some(fill.id())
        fill
        .width(Is(Some(390.0)))
        .height(Is(Some(72.0)))
        .glass(
          Is(
            Some(
              @paint.Glass::frosted(
                blur=8.5,
                tint=0x1C1C1EF5L,
                solid=0x1C1C1EFFL,
                saturation=1.0,
                progressive=true,
              ),
            ),
          ),
        )
        |> ignore
        // Interactive bar control at x=0..44 (like a real top bar's back button)
        fill.box(fn(btn) {
          btn.over(Is(true), from_top=true).width(Is(Some(44.0))).height(Is(Some(44.0))).on_press(fn() {  }) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 300.0, now=10.0) |> ignore
  let fid = fill_id.val.unwrap()
  // Direct unit check on Tree::covers_at threshold (>= 0.38)
  assert_true(tree.covers_at(fid, 1.0, 200.0, 22.0), msg="y=22 ramp=0.694 >= 0.38 must cover")
  assert_false(tree.covers_at(fid, 1.0, 200.0, 46.0), msg="y=46 (2pt below bar) ramp=0.361 < 0.38 must pass through")
  assert_false(tree.covers_at(fid, 1.0, 200.0, 54.0), msg="y=54 (10pt below bar) ramp=0.25 < 0.38 must pass through")
  // End-to-end hit-test check via Tree::target_at
  let hit_in_bar = tree.target_at(200.0, 22.0)
  assert_true(hit_in_bar is Nothing, msg="scrim body at y=22 must occlude underlying presses: \{Repr(hit_in_bar)}")
  let hit_below_bar = tree.target_at(200.0, 54.0)
  assert_true(hit_below_bar is Pressed(_), msg="extended fade tail 10pt below bar (y=54) must pass presses through: \{Repr(hit_below_bar)}")
}
