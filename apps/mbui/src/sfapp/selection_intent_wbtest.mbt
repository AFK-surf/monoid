// Experimental selection intent inference (实验性功能 › 选中文本自动推测意图):
// off by default (selection pill/bar unchanged); when enabled, selecting text in a chat shows 推测意图 beside 引用,
// calls `chat.selectionIntent`, and displays the inferred intent and direct reply in a panel.

///|
test "选中文本自动推测意图: off by default; when enabled, finger selection offers 推测意图 and opens the reply panel" {
  new_run()
  let calls : Array[(String, Json)] = []
  let src = fixture("chat")
  let orig_call = src.call
  let src : Source = {
    ..src,
    call: fn(name, params, cb) {
      calls.push((name, params))
      orig_call(name, params, cb)
    },
  }
  open_fixture_over("chat", src)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)

  // Locate a message with words to select.
  for _ in 0..<12 {
    match t.run_rects("高度先按 90 估") {
      [(_, py, _, _), ..] if py > 180.0 && py < 680.0 => break
      _ => {
        t.wheel(195.0, 400.0, -200.0)
        t.run_for(@ui.move_most_ms)
      }
    }
  }
  guard t.run_rects("高度先按 90 估") is [(px, py, _, ph), ..] else { fail("message words not drawn") }

  // 1. Default off: no 推测意图 button.
  t.press_at(px + 6.0, py + ph / 2.0)
  t.run_for(@ui.long_press_ms)
  t.release(px + 6.0, py + ph / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="引用") is Some(_))
  assert_true(t.query(Button, label="推测意图") is None)
  @ui.picked_let_go()
  t.run_for(@ui.move_most_ms)

  // 2. Turn on the experimental switch.
  exp_set(t, src, ["selectionIntent"], true)
  assert_true(@sfbase.selection_intent_feature.get())

  // 3. Long-press again: 推测意图 appears beside 引用.
  t.press_at(px + 6.0, py + ph / 2.0)
  t.run_for(@ui.long_press_ms)
  t.release(px + 6.0, py + ph / 2.0)
  t.run_for(@ui.move_most_ms)
  guard t.query(Button, label="推测意图") is Some(btn) else { fail("no 推测意图 button when feature is enabled") }
  let (bx, by, bw, bh) = btn.rect
  t.tap(bx + bw / 2.0, by + bh / 2.0)
  t.run_for(@ui.move_most_ms)

  // 4. `chat.selectionIntent` was called and the panel shows the inferred intent and direct reply.
  let asked = calls.filter(fn(c) { c.0 == "chat.selectionIntent" })
  assert_eq(asked.length(), 1, msg="expected one chat.selectionIntent call")
  assert_true(t.find("解释选中内容在当前对话里的含义") is Some(_), msg="inferred intent not shown")
  assert_true(t.find("claude-haiku-4-5") is Some(_), msg="model caption not shown")
  assert_true(t.query(Button, label="复制回复") is Some(_))
  assert_true(t.query(Button, label="引用到输入框") is Some(_))

  // 5. Clicking 引用到输入框 quotes the passage into the composer draft.
  t.click(Button, label="引用到输入框")
  t.run_for(@ui.move_most_ms)
  let quoted = calls.filter(fn(c) { c.0 == "composer.quote" })
  assert_eq(quoted.length(), 1, msg="expected passage quoted into draft")
}
