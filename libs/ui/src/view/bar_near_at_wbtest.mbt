// Unit tests for `Tree::bar_near_at` via `bar_cols` + `drawn_one`:
// verifies nested columns, overlapping stacked columns, hidden (`out`) columns, and `in_use(false)` columns.

///|
test "bar_near_at: nested and overlapping columns pick top drawn hit, skipping out and pressless" {
  let show_overlay = @signals.signal(false, same=fn(a, b) { a == b })
  let overlay_presses = @signals.signal(true, same=fn(a, b) { a == b })
  let outer_near = Ref(false)
  let inner_near = Ref(false)
  let overlay_near = Ref(false)

  let t = Tree::new(fn(root) {
    root.width(Is(Some(300.0))).height(Is(Some(200.0))) |> ignore

    // Base outer column (0..200, 0..200), bar_near=16 along x in [184, 200)
    root.box(fn(outer) {
      outer.width(Is(Some(200.0))).height(Is(Some(200.0))) |> ignore
      outer.reacts(fn() { outer.bar_near(16.0) }, fn(v) { outer_near.val = v })
      // Nested inner column (0..120, 0..100), bar_near=16 along x in [104, 120)
      outer.box(fn(inner) {
        inner.width(Is(Some(120.0))).height(Is(Some(100.0))) |> ignore
        inner.reacts(fn() { inner.bar_near(16.0) }, fn(v) { inner_near.val = v })
      })
      |> ignore
    })
    |> ignore

    // Overlapping upper column (0..200, 0..200) drawn after outer
    root.show(fn() { show_overlay.get() }, at_once=true, fn(ov) {
      ov.over(Is(true), edges=(Some(0.0), None, None, Some(0.0))) |> ignore
      ov.width(Is(Some(200.0))).height(Is(Some(200.0))) |> ignore
      ov.presses(By(fn() { overlay_presses.get() })) |> ignore
      ov.reacts(fn() { ov.bar_near(16.0) }, fn(v) { overlay_near.val = v })
    })
  })

  t.frame(300.0, 200.0, now=10.0) |> ignore

  // Pointer near inner's right edge (x=112, y=50): inner wins over outer.
  t.point_at(112.0, 50.0)
  t.frame(300.0, 200.0, now=20.0) |> ignore
  assert_true(inner_near.val, msg="nested inner column should match its bar_near edge")
  assert_false(outer_near.val, msg="outer column should not match when pointer is in inner")
  assert_false(overlay_near.val)

  // Pointer inside inner but outside inner's edge (x=50, y=50): neither matches.
  t.point_at(50.0, 50.0)
  t.frame(300.0, 200.0, now=30.0) |> ignore
  assert_false(inner_near.val)
  assert_false(outer_near.val)

  // Pointer near outer's right edge (x=192, y=50) while overlay is hidden (out): outer matches.
  t.point_at(192.0, 50.0)
  t.frame(300.0, 200.0, now=40.0) |> ignore
  assert_true(outer_near.val, msg="outer column should match when overlay is out")
  assert_false(inner_near.val)
  assert_false(overlay_near.val)

  // Show overlapping upper column: upper drawn-order column wins at x=192, y=50.
  show_overlay.set(true)
  t.frame(300.0, 200.0, now=50.0) |> ignore
  assert_true(overlay_near.val, msg="overlapping upper column should win by draw order")
  assert_false(outer_near.val, msg="lower column should yield to upper overlapping column")

  // Disable upper column (`presses(false)` -> inert/pressless): falls through to outer column.
  overlay_presses.set(false)
  t.frame(300.0, 200.0, now=60.0) |> ignore
  assert_false(overlay_near.val, msg="pressless overlay should be skipped")
  assert_true(outer_near.val, msg="outer column should regain hit when overlay is pressless")

  // Hide overlay again (while overlay_near is false): outer still matches cleanly.
  show_overlay.set(false)
  overlay_presses.set(true)
  t.frame(300.0, 200.0, now=70.0) |> ignore
  assert_false(overlay_near.val)
  assert_true(outer_near.val)

  t.dispose()
}
