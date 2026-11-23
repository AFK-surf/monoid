// Focus-visible audit and outer concentric focus ring tests.

///|
fn drawn_rings() -> Array[(Double, Double, Double, Double, Double, Double)] {
  let c = g()
  let round3 = fn(v : Double) { (v * 1000.0).round() / 1000.0 }
  let out = []
  for k in 0..<c.ninst {
    let b = k * inst_size
    let i = c.inst
    // Rect instance with border_w (i[b+6]) > 0 and transparent fill (a pure ring).
    if i[b + 5] == 0.0 && i[b + 11] == 0.0 && i[b + 6] > 0.0 && i[b + 15] > 0.0 {
      out.push((round3(i[b]), round3(i[b + 1]), round3(i[b + 2]), round3(i[b + 3]), round3(i[b + 6]), round3(i[b + 36])))
    }
  }
  out
}

///|
test "focus_visible_faults: catches hover-only Tab stops and accepts focus_ring_theme, focus_shown and text fields" {
  let f = Field::new()
  let t = Tester::new(
    fn(_) {  },
    tree=fn(root) {
      root.box(fn(col) {
        col.pad(Is(24.0)).gap(Is(12.0)) |> ignore
        // 1. Hover-only button: blind to keyboard Tab -> flagged.
        col.box(fn(bad) {
          bad
          .width(Is(Some(100.0)))
          .height(Is(Some(40.0)))
          .radius(Is(10.0))
          .ground(By(fn() { if bad.pointed() { 0xDDDDDDFFL } else { 0xEEEEEEFFL } }))
          .presses(Is(true))
          .focusable(Is(true))
          .says(Is(Some(@view.said(Button, label="盲按钮"))))
          .on_press(fn() {  })
          |> ignore
        })
        |> ignore
        // 2. Theme focus ring button: zero-binding concentric ring -> clean.
        col.box(fn(ok) {
          ok
          .width(Is(Some(100.0)))
          .height(Is(Some(40.0)))
          .radius(Is(10.0))
          .ground(Is(0xEEEEEEFFL))
          .presses(Is(true))
          .focusable(Is(true))
          .focus_ring_theme()
          .says(Is(Some(@view.said(Button, label="好按钮"))))
          .on_press(fn() {  })
          |> ignore
        })
        |> ignore
        // 3. Custom focus_shown reader -> clean.
        col.box(fn(custom) {
          custom
          .width(Is(Some(100.0)))
          .height(Is(Some(40.0)))
          .radius(Is(10.0))
          .ground_over(By(fn() { if custom.focus_shown() { 0xCC5A3433L } else { 0L } }))
          .presses(Is(true))
          .focusable(Is(true))
          .says(Is(Some(@view.said(Button, label="自绘焦点"))))
          .on_press(fn() {  })
          |> ignore
        })
        |> ignore
        // 4. Text field (uses caret + field border) -> exempt.
        field(col, f, placeholder="输入").width(Is(Some(120.0))) |> ignore
      })
      |> ignore
    },
    w=400.0,
    h=320.0,
    platform=0,
  )
  t.draw()
  let faults = t.focus_visible_faults()
  assert_eq(faults.length(), 1, msg=faults.join("\n"))
  assert_true(faults[0].contains("盲按钮"), msg=faults[0])
}

///|
test "focus_ring_theme: concentric outer ring draws outside clips(true) on Tab, never on pointer tap" {
  let t = Tester::new(
    fn(_) {  },
    tree=fn(root) {
      root.box(fn(page) {
        page.pad(Is(40.0)) |> ignore
        page.box(fn(btn) {
          btn
          .width(Is(Some(100.0)))
          .height(Is(Some(40.0)))
          .radius(Is(10.0))
          .clips(Is(true))
          .ground(Is(0xEEEEEEFFL))
          .presses(Is(true))
          .focusable(Is(true))
          .focus_ring_theme()
          .says(Is(Some(@view.said(Button, label="提交"))))
          .on_press(fn() {  })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    w=300.0,
    h=200.0,
    platform=0,
  )
  t.draw()
  assert_eq(drawn_rings(), [], msg="at rest: no ring")

  // Pointer click focuses without :focus-visible -> no ring.
  t.tap(90.0, 60.0)
  assert_eq(drawn_rings(), [], msg="after pointer tap: no ring")

  // Keyboard Tab shows concentric outer ring outside the button's own clip:
  // out = focus_gap (2) + focus_w (2) = 4, concentric radius = 10 + 4 = 14.
  t.tab()
  let th = tree_theme()
  let out = th.focus_gap + th.focus_w
  assert_eq(
    drawn_rings(),
    [(40.0 - out, 40.0 - out, 100.0 + 2.0 * out, 40.0 + 2.0 * out, th.focus_w, 10.0 + out)],
  )
}
