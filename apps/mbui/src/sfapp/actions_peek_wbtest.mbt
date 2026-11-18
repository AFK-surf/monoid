///|
test "a workflow run opens its job details from a link in a message" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat-actions-run")
  let (x, y) = peek_words_at(t, "当前发布")
  t.move_to(x, y)
  t.run_for(@sfpages.hover_open_ms * 2.0)
  for words in ["pipeline #42", "16 运行中", "7 已通过", "6 已跳过", "Full check (ts)", "在 GitHub 查看全部任务"] {
    assert_true(t.words().any(fn(w) { w.0 == words && w.5 > 0.5 }), msg=words)
  }
  let left = fn(words : String) -> Double raise {
    guard t.words().filter(fn(w) { w.0.has_prefix(words) && w.5 > 0.5 }).last() is Some(w) else { fail(words) }
    w.1
  }
  assert_eq(left("desktop-win"), left("Build and publish the desktop app"))
  assert_eq(left("check-linux"), left("desktop-win"))
  assert_eq(left("Full check (ts)"), left("Build, pack"))
  t.click(@ui.Role::Button, label="check-linux")
  t.draw()
  assert_true(t.opened().contains("https://github.com/acme/shop/actions/runs/9001/job/456#step:3:1"))
}
