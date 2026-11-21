// A button whose words change goes to its new width over a Move, its words with it, not at once (the user,
// 2026-10-30: 按钮的变长应该也有过渡; 分享图片's 复制图片 to 已复制).

///|
/// The button's ground as drawn: its width (the rectangle as high as a button is).
fn button_ground_w(t : @ui.Tester) -> Double {
  let rs = t.drawn_rects().filter(fn(r) { (r.3 - button_height()).abs() < 0.5 })
  if rs.is_empty() {
    -1.0
  } else {
    rs[0].2
  }
}

///|
test "a button whose words change: its ground from the width it had to the new one, not at once" {
  let label = @signals.signal("复制图片")
  let t = @ui.Tester::new(fn(_c) {  })
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(col) {
      col.padding(Is((40.0, 40.0, 40.0, 40.0))).lines_up(Is(Some(Start))) |> ignore
      button_node(col, fn() { label.get() }, fn() {  }, tone=Primary) |> ignore
    })
    |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  let long = button_ground_w(t)
  label.set("已复制")
  t.frame()
  // as the move sets out, still near the width it had (not jumped at once); half way, between; at its end, the new one
  let start = button_ground_w(t)
  // (well on its way: no way takes less than a Move of nothing far)
  t.run_for(@ui.move_least_ms / 2.0)
  let mid = button_ground_w(t)
  t.run_for(@ui.move_most_ms)
  let short = button_ground_w(t)
  assert_true(short < long, msg="\{short} after, \{long} before")
  assert_true(start <= long && start > short + 0.5, msg="start \{start}, from \{long} to \{short}")
  assert_true(mid > short + 0.5 && mid < start - 0.5, msg="half way \{mid}, from \{start} to \{short}")
}
