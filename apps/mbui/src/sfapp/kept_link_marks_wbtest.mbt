// A message's link with its row kept as its nodes (mbui's kept_nodes.mbt), built as a host builds (no frame built once
// more keeping none: check_looks(false)): what its build said of it (the pointer's shape over it, a press on it, its
// menu: mbui's Ctx::mark_id) holds while the row is kept, as where it is built.

///|
test "a link in a message left still with a mouse: the hand over it, its right click the link's menu alone" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat")
  t.check_looks(false)
  t.drawn_again(true)
  let link = "example.com/bench/list"
  // (the chat scrolled till the link is clear of its bar and its composer)
  t.move_to(900.0, 400.0)
  for _ in 0..<12 {
    let dy = match t.run_rects(link) {
      [(_, y, _, h), ..] if y + h / 2.0 > 160.0 && y + h / 2.0 < 600.0 => break
      [(_, y, _, h), ..] if y + h / 2.0 >= 600.0 => 200.0
      _ => -300.0
    }
    t.wheel(900.0, 400.0, dy)
  }
  for _ in 0..<3 {
    t.run_for(kept_rows_still_ms)
  }
  let (x, y, w, h) = t.run_rects(link)[0]
  t.move_to(x + w / 2.0, y + h / 2.0)
  assert_eq(t.cursor(), Hand)
  t.run_for(kept_rows_still_ms)
  assert_eq(t.cursor(), Hand)
  t.move_to(x + w / 2.0 + 1.0, y + h / 2.0)
  assert_eq(t.cursor(), Hand)
  t.right_click(x + w / 2.0 + 1.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  let came = t.words().map(fn(w) { w.0 })
  assert_true(came.contains("在浏览器中打开链接") && came.contains("复制链接"), msg="\{Repr(came)}")
  assert_true(!came.contains("复制消息") && !came.contains("复制消息链接") && !came.contains("多选"), msg="\{Repr(came)}")
}
