// A 待派发 draft clarified on the board (先理清: sfbase's clarify.mbt, sfpages' board_node draft_clarify_card): from its
// menu, its words split by the made-up agent into three tasks after a beat (`board.clarify`), edited, one deleted and
// one added by hand, and put into 待派发 as three cards of one group, or each started as its own chat; 大屏 1440 × 900,
// every step held to the board's audit.

///|
/// The tasks of the split open now, each its words as a draft would have them.
fn clarify_now() -> Array[String] {
  @sfbase.clarify.tasks.untracked().map(@sfbase.clarify_task_text)
}

///|
/// Button `label`'s `k`-th pressed, settled; the board's column scrolled first where it is below `end` (the window's
/// foot, or the phone's bar's top).
fn clarify_press(t : @ui.Tester, label : String, k? : Int = 0, end? : Double = 890.0) -> Unit raise {
  let at = fn() raise {
    let all = t.all(Button, label~)
    guard all.length() > k else { fail("no \{label} #\{k}: \{all.length()}") }
    all[k].rect
  }
  // (below the board's end: its column scrolled to it)
  for _ in 0..<20 {
    let (x, y, w, h) = at()
    guard y + h > end else { break }
    t.wheel(x + w / 2.0, end / 2.0, 200.0)
    t.run_for(@ui.move_most_ms)
  }
  let (x, y, w, h) = at()
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
}

///|
test "大屏: 先理清 from a draft's menu: its card being split, then three tasks to edit, nothing started" {
  let (t, src) = board_at("board-clarify", 1440.0, 900.0)
  guard board_words_at(t, @sffixture.fix_clarify_words) is Some((x, y, _, _)) else { fail("no draft") }
  t.right_click(x + 10.0, y + 6.0)
  t.run_for(@ui.move_most_ms)
  board_tap_words(t, "先理清")
  assert_eq(@sfbase.clarify.draft.untracked(), @sffixture.fix_clarify_id)
  assert_true(@sfbase.clarify.step.untracked() == Organizing, msg="step")
  assert_true(board_words_at(t, "正在把这条待办拆成任务…") is Some(_), msg="organizing: \{t.words().map(fn(w) { w.0 }).join(" ")}")
  t.run_for(@sffixture.fix_clarify_ms + @ui.move_most_ms)
  assert_true(@sfbase.clarify.step.untracked() == Ready)
  assert_eq(@sfbase.clarify.tasks.untracked().map(fn(t) { t.title.text() }), ["设置页导出对话记录", "导入对话记录", "补导出导入的测试"])
  assert_eq(@sfbase.clarify.tasks.untracked()[0].goal.text(), "在设置页把对话记录导出成 Markdown 文件，便于归档。")
  for w in ["任务 1", "任务 2", "任务 3", "全部派发", "放入待派发", "按原话派发", "返回修改"] {
    assert_true(board_words_at(t, w) is Some(_), msg=w)
  }
  // (nothing made, nothing started: the draft still the board's, whole)
  assert_true(@sfbase.board_started.untracked().is_empty())
  assert_eq(board_kept_drafts()[0], @sffixture.fix_clarify_words)
  assert_eq(@signals.untracked(fn() { @sfbase.board_drafts_of(src, "ws1") }).length(), 3)
  assert_eq(board_faults(t), [])
}

///|
test "大屏: a task deleted from the split, one added by hand, empty; 返回修改 leaves the draft as it was" {
  let (t, _) = board_at("board-clarify-split", 1440.0, 900.0)
  clarify_press(t, "删除这项", k=1)
  assert_eq(@sfbase.clarify.tasks.untracked().map(fn(t) { t.title.text() }), ["设置页导出对话记录", "补导出导入的测试"])
  clarify_press(t, "添加任务")
  assert_eq(@sfbase.clarify.tasks.untracked().map(fn(t) { t.title.text() }), ["设置页导出对话记录", "补导出导入的测试", ""])
  assert_eq(clarify_now()[2], "")
  assert_true(board_words_at(t, "任务 3") is Some(_))
  assert_eq(board_faults(t), [])
  clarify_press(t, "返回修改")
  assert_eq(@sfbase.clarify.draft.untracked(), "")
  assert_eq(board_kept_drafts()[0], @sffixture.fix_clarify_words)
}

///|
test "大屏: 放入待派发 makes each task a 待派发 card, together where the draft was, each saying the words it came from" {
  let (t, src) = board_at("board-clarify-split", 1440.0, 900.0)
  clarify_press(t, "放入待派发")
  assert_eq(@sfbase.clarify.draft.untracked(), "")
  let drafts = @signals.untracked(fn() { @sfbase.board_drafts_of(src, "ws1") })
  assert_eq(drafts.length(), 5)
  // (in its place, in their order: the first keeps its key, all of one group, the seeds after them as they were)
  assert_eq(drafts[0].id, @sffixture.fix_clarify_id)
  assert_eq(drafts[:3].iter().map(fn(d) { d.group }).collect(), [@sffixture.fix_clarify_words, @sffixture.fix_clarify_words, @sffixture.fix_clarify_words])
  assert_true(drafts[0].title.has_prefix("设置页导出对话记录\n目标：在设置页把对话记录导出成 Markdown 文件"))
  assert_true(drafts[1].title.has_prefix("导入对话记录"))
  assert_true(drafts[2].title.has_prefix("补导出导入的测试"))
  assert_eq(drafts[3].title, "给导出加上按月份筛选")
  assert_true(@sfbase.board_started.untracked().is_empty())
  // (kept so: what the core keeps of each, its group too)
  match @sffixture.board_prefs["boardDrafts"].get("ws1") {
    Some(Array(a)) => assert_eq(text(Some(a[1]), "group"), @sffixture.fix_clarify_words)
    _ => fail("not kept")
  }
  assert_eq(board_words_n(t, @sffixture.fix_clarify_words), 3)
  assert_eq(board_faults(t), [])
}

///|
test "大屏: 全部派发 starts each task as its own chat, all in 进行中, the draft gone" {
  let (t, src) = board_at("board-clarify-split", 1440.0, 900.0)
  clarify_press(t, "全部派发")
  t.run_for(@ui.move_most_ms)
  let titles = ["设置页导出对话记录", "导入对话记录", "补导出导入的测试"]
  let run = @sfbase.board_items(src, "ws1").filter(fn(i) { titles.iter().any(fn(w) { i.title.has_prefix(w) }) })
  assert_eq(run.length(), 3)
  assert_true(run.iter().all(fn(i) { @sfbase.board_lane_of(i) == "run" }))
  assert_eq(board_kept_drafts(), ["给导出加上按月份筛选", "看一下 Android 冷启动为什么慢了 300ms"])
  assert_eq(board_faults(t), [])
}

///|
test "大屏: one task started on its own: its chat in 进行中, the others still to edit, the draft kept till the last goes" {
  let (t, src) = board_at("board-clarify-split", 1440.0, 900.0)
  clarify_press(t, "派发这项", k=0)
  assert_eq(@sfbase.clarify.tasks.untracked().length(), 2)
  let run = @sfbase.board_items(src, "ws1").filter(fn(i) { i.title.has_prefix("设置页导出对话记录") })
  assert_eq(run.map(fn(i) { @sfbase.board_lane_of(i) }), ["run"])
  assert_eq(board_kept_drafts()[0], @sffixture.fix_clarify_words)
  clarify_press(t, "派发这项", k=0)
  clarify_press(t, "派发这项", k=0)
  assert_eq(@sfbase.clarify.draft.untracked(), "")
  assert_eq(board_kept_drafts(), ["给导出加上按月份筛选", "看一下 Android 冷启动为什么慢了 300ms"])
  assert_eq(board_faults(t), [])
}

///|
test "a task as a draft's words: its title, then each part that says something under its name, a blank line between" {
  let task = @sfbase.clarify_task_of({ "title": "导出", "goal": "能导出", "scope": " ", "accept": "1. 一\n2. 二", "ask": "" })
  assert_eq(@sfbase.clarify_task_text(task), "导出\n目标：能导出\n\n验收标准：\n1. 一\n2. 二")
  assert_eq(@sfbase.clarify_task_text(@sfbase.clarify_task_of(Json::object({}))), "")
}

///|
test "小屏: the split in 待派发's column, a phone's width: three tasks to edit, all of them started from it" {
  let (t, src) = board_at("board-clarify-split", 390.0, 844.0, platform=2)
  // (a column at a time: 待派发's chip)
  t.click(Tab, label="待派发 3")
  t.run_for(@ui.move_most_ms)
  for w in ["先理清", "任务 1", "全部派发"] {
    assert_true(board_words_at(t, w) is Some(_), msg=w)
  }
  guard board_words_at(t, "任务 1") is Some((x, _, w, _)) else { fail("no task") }
  assert_true(x >= 0.0 && x + w <= 390.0)
  assert_eq(board_faults(t), [])
  clarify_press(t, "全部派发", end=700.0)
  assert_eq(@sfbase.clarify.draft.untracked(), "")
  let titles = ["设置页导出对话记录", "导入对话记录", "补导出导入的测试"]
  let run = @sfbase.board_items(src, "ws1").filter(fn(i) { titles.iter().any(fn(w) { i.title.has_prefix(w) }) })
  assert_eq(run.length(), 3)
  assert_eq(board_faults(t), [])
}
