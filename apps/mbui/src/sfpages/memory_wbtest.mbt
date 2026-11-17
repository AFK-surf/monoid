// 记忆 (memory.mbt) alone, at each width, with a finger and with a mouse: the workspace's shared memory by its parts,
// each row with its recent diff and change tag, opening its page.

///|
test "记忆, at each width and with either hand: the workspace's shared memory by its parts, each row opening its page" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(Memories, w, platform~)
    let at = "\{w} platform \{platform}"
    // the workspace's memory: its global memory by its parts, its projects, the other skills, the station's own folded
    assert_true(t.find("全局记忆") is Some(_), msg=at)
    assert_true(t.find("习惯") is Some(_), msg=at)
    assert_true(t.find("发布流程") is Some(_), msg=at)
    assert_true(t.find("周报") is Some(_), msg=at)
    assert_true(t.find("pdf、xlsx") is Some(_), msg=at)
    t.tap_text("发布流程")
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() == Setting(MemoryDoc("ws1/st1", "发布流程", 0)), msg=at)
  }
}

///|
test "记忆: the station's own skills folded open and shut again" {
  let t = setting_tester(Memories, 390.0, platform=2)
  let row = fn() { t.words().any(fn(w) { w.0 == "xlsx" && w.5 > 0.5 }) }
  assert_true(t.find("pdf、xlsx") is Some(_))
  assert_false(row())
  t.tap_text("内置 skill")
  t.draw()
  assert_true(row())
  t.tap_text("内置 skill")
  t.draw()
  assert_false(row())
}
