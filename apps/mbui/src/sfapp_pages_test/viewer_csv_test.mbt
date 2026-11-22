// A table's stage (sfbase viewer_stage_node.mbt csv_stage_node) on a phone with the system's words at 1.3: its rows as
// tall as their words drawn larger, nothing cut off them, and the table wider than the window scrolled across, its
// head with its rows.

///|
/// The made-up chat's 数据.csv open in its preview in a phone's window, the system's words at `scale`, seen once in.
fn csv_phone_tester(scale : Double) -> @ui.Tester {
  new_run()
  let src = fixture("chat-preview-csv")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.set_font_scale(scale)
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
fn csv_line(t : @ui.Tester, words : String) -> @ui.TextRun {
  match t.text_runs().filter(fn(r) { r.text == words }) {
    [r, ..] => r
    _ => { text: "", x0: -1.0, x1: -1.0, base: 0.0, top: 0.0, bottom: 0.0 }
  }
}

///|
test "a table's rows at the system's words 1.3 are as tall as their words, none cut, nothing over another" {
  let t = csv_phone_tester(1.3)
  let one = csv_line(t, "首页")
  let two = csv_line(t, "聊天")
  assert_true(one.x1 > 0.0 && two.x1 > 0.0, msg="its rows shown")
  // (a row: its line, 8 over it and 8 under it, the line as the words are drawn at 1.3)
  let line = @ui.sp_at(1.3, 13.0) * 18.0 / 13.0
  assert_true((two.top - one.top - (line + 16.0)).abs() < 0.6, msg="a row \{two.top - one.top}, its line \{line} and 16")
  assert_eq(t.fixed_outgrown(), [], msg="no words outgrow their box")
  t.audit() |> ignore
}

///|
test "a table wider than a phone's window scrolls across, its head with its rows" {
  let t = csv_phone_tester(1.3)
  let head = csv_line(t, "通过")
  let row = csv_line(t, "是")
  assert_true(head.x1 > 390.0, msg="its last column past the window's edge: \{head.x1}")
  let mid = (row.top + row.bottom) / 2.0
  t.wheel_with(200.0, mid, 600.0, 0.0, 0)
  t.run_for(@ui.move_most_ms)
  let head_now = csv_line(t, "通过")
  let row_now = csv_line(t, "是")
  assert_true(head_now.x1 < head.x1 - 1.0, msg="scrolled across: \{head.x1} to \{head_now.x1}")
  assert_true(head_now.x1 <= 390.0, msg="its last column in the window: \{head_now.x1}")
  assert_true((head.x0 - head_now.x0 - (row.x0 - row_now.x0)).abs() < 0.01, msg="the head as far as its rows")
}
