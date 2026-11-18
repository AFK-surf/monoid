// A new chat clarified first (先理清再派发: sfbase's clarify.mbt, sfpages new_chat.mbt new_brief): with it on, the first
// words make no chat; the made-up agent's brief of them comes after a beat (`newChat.clarify`), and the chat starts once
// it is confirmed, the brief its first message; 返回修改 puts the words back in the composer, 按原话派发 sends them.

///|
/// The wide frame over the made-up chats, a new chat opened, clarified first, its words typed and sent to be organized.
fn clarify_asked() -> (@ui.Tester, Source) {
  let src = fixture_app("chat")
  both_way()
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.drive(
    "timeout 20000\nuntil 新建对话\ntap 新建对话\nuntil 先理清再派发\ntap 先理清再派发\nuntil 说说要做的事\n" +
    "tap 说说要做的事\ntype 给设置页加一个导出入口\ntap =整理\nuntil 正在把你的话\n",
  )
  |> ignore
  (t, src)
}

///|
test "wide: a new chat clarified first is organized, not sent; its brief comes to be edited" {
  let (t, _) = clarify_asked()
  // (nothing made, nothing sent: still the new chat, its brief being made)
  assert_true(app.nav.top() is NewChat)
  assert_true(@sfbase.clarify.step.get() == Organizing)
  t.drive("timeout 20000\nuntil 确认并开跑\n") |> ignore
  assert_true(@sfbase.clarify.step.get() == Ready)
  assert_true(t.words().iter().any(fn(w) { w.0 == "验收标准" }))
  assert_true(@sfbase.clarify.goal.text().has_prefix("让用户能在设置页"))
  assert_true(app.nav.top() is NewChat)
}

///|
test "wide: a brief confirmed starts the chat with it as the first message" {
  let (t, _) = clarify_asked()
  t.drive("timeout 20000\nuntil 确认并开跑\ntap 确认并开跑\n") |> ignore
  t.run_for(@sfbase.flight_desk_ms)
  assert_true(app.nav.top() is Chat(_), msg="not the chat")
  assert_true(@sfbase.clarify.step.get() == Writing)
  // (its first message the brief in Markdown, each part under its heading)
  assert_true(t.words().iter().any(fn(w) { w.0.contains("需要确认的问题") }))
  assert_true(t.words().iter().any(fn(w) { w.0.contains("导出成 Markdown 文件") }))
}

///|
test "wide: 返回修改 puts the words back in the composer, nothing made" {
  let (t, src) = clarify_asked()
  t.drive("timeout 20000\nuntil 确认并开跑\ntap 返回修改\nuntil 说说要做的事\n") |> ignore
  assert_true(app.nav.top() is NewChat)
  assert_true(@sfbase.clarify.step.get() == Writing)
  // (the words still the new chat's draft, shown in its composer)
  assert_eq(@sfbase.writing(src, "new:ws1").text.get(), "给设置页加一个导出入口")
}

///|
test "the brief as the first message: each part that says something, under its heading" {
  let c = @sfbase.clarify
  c.goal.set("目标的话")
  c.scope.set("  ")
  c.accept.set("1. 一\n2. 二")
  c.ask.set("")
  assert_eq(@sfbase.clarify_brief_text(), "## 目标\n\n目标的话\n\n## 验收标准\n\n1. 一\n2. 二")
  @sfbase.clarify_reset()
}
