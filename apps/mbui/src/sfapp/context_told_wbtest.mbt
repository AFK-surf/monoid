// A right click's menu in a chat on 大屏 (sfdesk's context_menu.mbt: a message's turn, a field's editing, the words picked)
// dismissed by the hand: Escape, a press on the page, at that input's moment; the frame after closing nothing more,
// a right click opening it again its own.

///|
/// 大屏, a mouse's, the chat open, scrolled till Ana's message shows: its words right clicked (its menu, 多选
/// and what else there is), dismissed by `how` (as the host hands it on, no frame after it): whether it is open then, once a
/// frame is drawn, as a right click opens it again and a frame after.
fn context_dismissed(how : (@ui.Tester, Double) -> Unit) -> Array[Bool] raise {
  let t = wide_tester([], mode="chat")
  for _ in 0..<12 {
    match t.run_rects("example.com/review/42") {
      [(_, y, _, _), ..] if y > 100.0 && y < 600.0 => break
      _ => t.wheel(900.0, 400.0, -200.0)
    }
  }
  let (x, y, w, h) = words_rect(t, "第二屏的插画")
  let open = fn() { @sfdesk.context.open }
  t.right_click(x + w / 2.0, y + h / 2.0)
  t.frame()
  let shown = t.find("多选") is Some(_)
  let seen = [open()]
  // (beside it: over the words it opened at, where nothing of it is, as the words lie)
  how(t, y - 40.0)
  seen.push(open())
  t.draw()
  seen.push(open())
  t.right_click(x + w / 2.0, y + h / 2.0)
  t.frame()
  seen.push(open())
  t.draw()
  seen.push(open())
  assert_true(shown, msg="its menu shown: \{Repr(seen)}")
  seen
}

///|
test "大屏: a right click's menu in a chat dismissed by Escape: closed as the key is taken; the frame after closes nothing more, opened again its own" {
  assert_eq(context_dismissed(fn(t, _) { t.key_told(@ui.key_escape, 0, t.time()) }), [true, false, false, true, true])
}

///|
test "大屏: a right click's menu in a chat dismissed by a press beside it: closed as it goes down; the frame after closes nothing more, opened again its own" {
  let down : Array[Bool] = []
  let seen = context_dismissed(fn(t, beside) {
    t.touch_at(0, 600.0, beside, t.time())
    down.push(@sfdesk.context.open)
    t.touch_at(2, 600.0, beside, t.time())
  })
  assert_eq((down, seen), ([false], [true, false, false, true, true]))
}

///|
test "大屏聊天页与右侧执行历史面板同开：从左栏消息拖入右栏不跨栏高亮也不在右栏飘出引用胶囊；左栏选中后右击右栏不提供复制左栏文字" {
  let t = wide_tester([], mode="chat-history-side")
  t.run_for(@ui.move_most_ms)
  for _ in 0..<12 {
    match t.run_rects("example.com/review/42") {
      [(_, y, _, _), ..] if y > 100.0 && y < 600.0 => break
      _ => t.wheel(500.0, 400.0, -200.0)
    }
  }
  t.run_for(@ui.move_most_ms)
  let (lx, ly, _lw, lh) = words_rect(t, "第二屏的插画")
  let words = t.words()
  let right_w = match words.iter().find_first(fn(w) {
    w.1 > 820.0 && w.2 > 120.0 && w.2 < 620.0 && w.0.length() >= 4 && !t.run_rects(w.0).is_empty()
  }) {
    Some(w) => Some(w)
    None => words.iter().find_first(fn(w) { w.1 > 820.0 && w.2 > 120.0 && w.2 < 620.0 && w.0.length() >= 4 })
  }
  guard right_w is Some((rtxt, rx, ry, rw, rh, _)) else { fail("no right history word found: \{Repr(words.map(fn(w) { (w.0, w.1, w.2) }))}") }
  // 1. Drag from left chat message into right execution history panel
  t.drag(lx + 2.0, ly + lh / 2.0, rx + rw / 2.0, ry + rh / 2.0)
  t.run_for(@ui.move_most_ms)
  let picked = t.ctx().selected_text()
  assert_true(picked != "", msg="expected selection in left chat starting from 第二屏的插画")
  assert_true(!picked.contains(rtxt), msg="selection leaked into right history panel (\{rtxt}): \{picked}")
  // No 引用 pill may appear over the right panel (x > 800)
  for w in t.words() {
    if w.0 == "引用" {
      assert_true(w.1 < 800.0, msg="引用 pill floated over right panel at x=\{w.1}")
    }
  }
  // 2. Right-click inside the right panel while left chat has selection: must NOT offer 复制 of left pane's words
  t.right_click(rx + rw / 2.0, ry + rh / 2.0)
  t.frame()
  assert_true(t.find("复制") is None, msg="right-clicking right panel offered 复制 for left chat selection: words=\{@sfdesk.context.words}")
  assert_eq(@sfdesk.context.words, "")
}
