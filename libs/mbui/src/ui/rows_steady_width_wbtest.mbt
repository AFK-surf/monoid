// An old-view list may reflow when its own column is resized, without a change to the window's size.

///|
test "rows laid out at a new column width are not a jolt in a list's motion" {
  let wide = @signals.signal(false)
  let t = Tester::new(fn(c) {
    c.box(w=Px(if wide.get() { 300.0 } else { 180.0 }), h=Px(240.0), fn() {
      c.list("width", 4, 70.0, fn(i) {
        // A line wrapping differently at the new width changes the height of a row above the end.
        let height = if i == 2 && !wide.get() { 120.0 } else { 70.0 }
        c.box(h=Px(height), fn() { c.text("Row \{i}", wrap=false) |> ignore }) |> ignore
      }, stick_end=true) |> ignore
    }) |> ignore
  }, w=400.0, h=240.0)
  t.run_for(move_most_ms)
  t.frame()
  t.frame()
  let before = t.row(1).unwrap().1
  wide.set(true)
  t.frame()
  t.frame()
  t.frame()
  assert_true(t.row(1).unwrap().1 != before)
}
