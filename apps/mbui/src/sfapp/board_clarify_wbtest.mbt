// A 待派发 draft clarified on the board (先理清: sfbase's clarify.mbt and board_after.mbt, sfpages' board_node
// draft_clarify_card): from its menu (behind the experimental boardClarify), its words split by the made-up agent into
// three lines after a beat (`board.clarify`), the third waiting for the first two (「等 X」); edited, put into 待派发 as
// three cards of one group, or dispatched: those free started, the waiting one started by itself once the first two
// are in 待收口, exactly once, and never where one it waits for is gone or errored. 大屏 1440 × 900 and 小屏 390 × 844,
// every step held to the board's audit.

///|
/// The lines of the split open now.
fn clarify_now() -> Array[String] {
  @sfbase.clarify.tasks.untracked().map(@sfbase.clarify_task_text)
}

///|
/// The made-up agent's three lines.
fn clarify_lines() -> Array[String] {
  items(Some(@sffixture.fix_clarify_tasks()), "tasks").map(fn(t) { text(Some(t), "text") })
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
/// The board's chats of workspace ws1 titled by one of `titles`, and in which column each stands.
fn clarify_lanes(src : Source, titles : Array[String]) -> Array[String] {
  @sfbase.board_items(src, "ws1").filter(fn(i) { titles.contains(i.title) }).map(fn(i) { @sfbase.board_lane_of(i) })
}

///|
/// The drafts of ws1 now (not started).
fn clarify_drafts(src : Source) -> Array[@sfbase.BoardDraft] {
  @signals.untracked(fn() { @sfbase.board_drafts_of(src, "ws1") })
}

///|
test "大屏: 先理清 from a draft's menu: its card being split, then three lines, the third waiting for the first two" {
  let (t, src) = board_at("board-clarify", 1440.0, 900.0)
  guard board_words_at(t, @sffixture.fix_clarify_words) is Some((x, y, _, _)) else { fail("no draft") }
  t.right_click(x + 10.0, y + 6.0)
  t.run_for(@ui.move_most_ms)
  board_tap_words(t, "先理清")
  assert_eq(@sfbase.clarify.draft.untracked(), @sffixture.fix_clarify_id)
  assert_true(@sfbase.clarify.step.untracked() == Organizing, msg="step")
  assert_true(board_words_at(t, "正在把这条待办拆成任务…") is Some(_), msg="organizing")
  t.run_for(@sffixture.fix_clarify_ms + @ui.move_most_ms)
  assert_true(@sfbase.clarify.step.untracked() == Ready)
  assert_eq(clarify_now(), clarify_lines())
  let tasks = @sfbase.clarify.tasks.untracked()
  assert_eq(tasks[2].after.untracked(), [tasks[0].id, tasks[1].id])
  assert_eq(tasks[0].after.untracked(), [])
  for w in ["等 在设置页加上导出对话记录…", "等 在设置页加上导入对话记录…", "全部派发", "放入待派发", "按原话派发", "返回修改"] {
    assert_true(board_words_at(t, w) is Some(_), msg=w)
  }
  // (nothing made, nothing started: the draft still the board's, whole)
  assert_true(@sfbase.board_started.untracked().is_empty())
  assert_eq(board_kept_drafts()[0], @sffixture.fix_clarify_words)
  assert_eq(clarify_drafts(src).length(), 3)
  assert_eq(board_faults(t), [])
}

///|
test "先理清 is behind its experimental switch: off, a draft's menu has no 先理清" {
  let (t, _) = board_at("board", 1440.0, 900.0)
  guard board_words_at(t, "给导出加上按月份筛选") is Some((x, y, _, _)) else { fail("no draft") }
  t.right_click(x + 10.0, y + 6.0)
  t.run_for(@ui.move_most_ms)
  assert_true(board_words_at(t, "立即派发") is Some(_), msg="its menu")
  assert_true(board_words_at(t, "先理清") is None, msg="先理清 offered with the switch off")
}

///|
test "the core's answer read whole: what is not an earlier line's place waits for nothing" {
  @sfbase.clarify_reset()
  @sfbase.clarify_fill({
    "tasks": [
      { "text": "一" },
      { "text": "二", "after": [5, 0, -1, 1.5, 1, 0] },
      { "text": "三", "after": [2, 1] },
    ],
  })
  let tasks = @sfbase.clarify.tasks.untracked()
  assert_eq(tasks[1].after.untracked(), [tasks[0].id])
  assert_eq(tasks[2].after.untracked(), [tasks[1].id])
  // (a line waits for none that waits for it, itself or through another: no loop)
  assert_false(@sfbase.clarify_may_wait(tasks[0], tasks[2].id))
  assert_false(@sfbase.clarify_may_wait(tasks[0], tasks[0].id))
  @sfbase.clarify_toggle_wait(tasks[0], tasks[2].id)
  assert_eq(tasks[0].after.untracked(), [])
  @sfbase.clarify_toggle_wait(tasks[2], tasks[0].id)
  assert_eq(tasks[2].after.untracked(), [tasks[1].id, tasks[0].id])
  @sfbase.clarify_toggle_wait(tasks[2], tasks[0].id)
  assert_eq(tasks[2].after.untracked(), [tasks[1].id])
  // (a line deleted: what waited for it waits no more)
  @sfbase.clarify_remove(tasks[1].id)
  assert_eq(@sfbase.clarify.tasks.untracked()[1].after.untracked(), [])
  @sfbase.clarify_reset()
}

///|
test "大屏: a line deleted, one added by hand, empty; 返回修改 leaves the draft as it was" {
  let (t, _) = board_at("board-clarify-split", 1440.0, 900.0)
  clarify_press(t, "删除这项", k=1)
  assert_eq(clarify_now(), [clarify_lines()[0], clarify_lines()[2]])
  let tasks = @sfbase.clarify.tasks.untracked()
  assert_eq(tasks[1].after.untracked(), [tasks[0].id])
  clarify_press(t, "添加任务")
  assert_eq(clarify_now(), [clarify_lines()[0], clarify_lines()[2], ""])
  assert_eq(board_faults(t), [])
  clarify_press(t, "返回修改")
  assert_eq(@sfbase.clarify.draft.untracked(), "")
  assert_eq(board_kept_drafts()[0], @sffixture.fix_clarify_words)
}

///|
test "大屏: 放入待派发 makes each line a 待派发 card, together where the draft was; the third waits for the first two" {
  let (t, src) = board_at("board-clarify-split", 1440.0, 900.0)
  clarify_press(t, "放入待派发")
  assert_eq(@sfbase.clarify.draft.untracked(), "")
  let drafts = clarify_drafts(src)
  assert_eq(drafts.length(), 5)
  // (in its place, in their order: the first keeps its key, all of one group, the seeds after them as they were)
  assert_eq(drafts[0].id, @sffixture.fix_clarify_id)
  assert_eq(drafts[:3].iter().map(fn(d) { d.title }).collect(), clarify_lines())
  assert_true(drafts[:3].iter().all(fn(d) { d.group == @sffixture.fix_clarify_words }))
  assert_eq(drafts[2].after.map(fn(a) { a.id }), [drafts[0].id, drafts[1].id])
  assert_eq(drafts[3].title, "给导出加上按月份筛选")
  assert_true(@sfbase.board_started.untracked().is_empty())
  // (kept so: what the core keeps of each, its group and what it waits for too)
  match @sffixture.board_prefs["boardDrafts"].get("ws1") {
    Some(Array(a)) => {
      assert_eq(text(Some(a[1]), "group"), @sffixture.fix_clarify_words)
      assert_eq(items(Some(a[2]), "after").map(fn(x) { text(Some(x), "id") }), [drafts[0].id, drafts[1].id])
    }
    _ => fail("not kept")
  }
  // (its card says the line alone, and what it waits for)
  assert_true(board_words_at(t, clarify_lines()[2]) is Some(_))
  assert_true(board_words_at(t, "等 在设置页加上导出对话记录… 等 1 项") is Some(_), msg=t.words().map(fn(w) { w.0 }).join(" | "))
  assert_eq(@signals.untracked(fn() { @sfbase.board_wait_of(drafts[2], drafts, @sfbase.board_items(src, "ws1"), true) }), Waits([clarify_lines()[0], clarify_lines()[1]]))
  assert_eq(board_faults(t), [])
}

///|
test "大屏: 全部派发 starts the free lines only; the third waits in 待派发, then starts by itself once, the first two in 待收口" {
  let (t, src) = board_at("board-clarify-auto", 1440.0, 900.0)
  clarify_press(t, "全部派发")
  t.run_for(@ui.move_most_ms)
  let lines = clarify_lines()
  assert_eq(clarify_lanes(src, lines[:2].to_owned()), ["run", "run"])
  assert_eq(clarify_lanes(src, [lines[2]]), [])
  let drafts = clarify_drafts(src)
  assert_eq(drafts.map(fn(d) { d.title }), [lines[2], "给导出加上按月份筛选", "看一下 Android 冷启动为什么慢了 300ms"])
  assert_true(board_words_at(t, "等 在设置页加上导出对话记录… 等 1 项") is Some(_), msg="its wait")
  assert_eq(board_faults(t), [])
  // (the first two done with: in 待收口, and the third started by itself, its chat at work)
  t.run_for(@sffixture.fix_clarify_settle_ms + @ui.move_most_ms)
  assert_eq(clarify_lanes(src, lines[:2].to_owned()), ["done", "done"])
  assert_eq(clarify_lanes(src, [lines[2]]), ["run"])
  assert_eq(clarify_drafts(src).map(fn(d) { d.title }), ["给导出加上按月份筛选", "看一下 Android 冷启动为什么慢了 300ms"])
  assert_eq(@sfbase.board_started.untracked().filter(fn(s) { s.draft.title == lines[2] }).length(), 1)
  // (what it sent: its line, and the words it was split from under it)
  let started = @sfbase.board_started.untracked().filter(fn(s) { s.draft.title == lines[2] })[0].draft
  assert_eq(@sfbase.board_sent_text(started), lines[2] + "\n\n原话：" + @sffixture.fix_clarify_words)
  // (changes after: started once, never again)
  t.run_for(@sffixture.fix_clarify_settle_ms * 2.0)
  assert_eq(@sfbase.board_started.untracked().filter(fn(s) { s.draft.title == lines[2] }).length(), 1)
  assert_eq(clarify_lanes(src, [lines[2]]).length(), 1)
  assert_eq(board_faults(t), [])
}

///|
test "大屏: what a draft waits for gone: said on its card, never started by itself; 去掉这个依赖 leaves it a draft as any" {
  let (t, src) = board_at("board-clarify-gone", 1440.0, 900.0)
  t.run_for(@ui.move_most_ms * 4.0)
  let d = clarify_drafts(src)[0]
  assert_eq(d.id, @sffixture.fix_clarify_waiting_id)
  assert_true(@sfbase.board_started.untracked().is_empty(), msg="started")
  assert_true(board_words_at(t, "等的「在设置页加上导入…」已删除") is Some(_), msg=t.words().map(fn(w) { w.0 }).join(" | "))
  for w in ["立即派发", "去掉这个依赖"] {
    assert_true(board_words_at(t, w) is Some(_), msg=w)
  }
  assert_eq(board_faults(t), [])
  board_tap_words(t, "去掉这个依赖")
  let d = clarify_drafts(src)[0]
  assert_eq(d.after, [])
  assert_true(@sfbase.board_started.untracked().is_empty(), msg="started once free")
  assert_true(board_words_at(t, "去掉这个依赖") is None)
}

///|
test "大屏: what a draft waits for errored: said on its card, never started by itself; 立即派发 starts it" {
  let (t, src) = board_at("board-clarify-failed", 1440.0, 900.0)
  t.run_for(@ui.move_most_ms * 4.0)
  assert_true(@sfbase.board_started.untracked().is_empty(), msg="started")
  assert_true(board_words_at(t, "「在设置页加上导入…」出错了") is Some(_), msg=t.words().map(fn(w) { w.0 }).join(" | "))
  assert_eq(board_faults(t), [])
  clarify_press(t, "立即派发")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.board_started.untracked().map(fn(s) { s.draft.id }), [@sffixture.fix_clarify_waiting_id])
  assert_eq(clarify_lanes(src, [clarify_lines()[2]]), ["run"])
}

///|
test "大屏: one line started on its own: what waits for it waits for its chat; the draft kept till the last goes" {
  let (t, src) = board_at("board-clarify-split", 1440.0, 900.0)
  clarify_press(t, "派发这项", k=0)
  assert_eq(clarify_now(), clarify_lines()[1:].to_owned())
  assert_eq(clarify_lanes(src, [clarify_lines()[0]]), ["run"])
  assert_eq(board_kept_drafts()[0], @sffixture.fix_clarify_words)
  clarify_press(t, "放入待派发")
  let drafts = clarify_drafts(src)
  assert_eq(drafts[:2].iter().map(fn(d) { d.title }).collect(), clarify_lines()[1:].to_owned())
  // (the third waits for the first's chat, started, and the second's draft)
  assert_eq(drafts[1].after.length(), 2)
  assert_eq(drafts[1].after[1].id, drafts[0].id)
  assert_eq(board_faults(t), [])
}

///|
test "小屏: the split in 待派发's column, a phone's width: three lines, the free ones started from it" {
  let (t, src) = board_at("board-clarify-split", 390.0, 844.0, platform=2)
  // (a column at a time: 待派发's chip)
  t.click(Tab, label="待派发 3")
  t.run_for(@ui.move_most_ms)
  for w in ["先理清", "全部派发", "等 在设置页加上导出对话记录…"] {
    assert_true(board_words_at(t, w) is Some(_), msg=w)
  }
  guard board_words_at(t, "全部派发") is Some((x, _, w, _)) else { fail("no foot") }
  assert_true(x >= 0.0 && x + w <= 390.0)
  assert_eq(board_faults(t), [])
  clarify_press(t, "全部派发", end=700.0)
  assert_eq(@sfbase.clarify.draft.untracked(), "")
  assert_eq(clarify_lanes(src, clarify_lines()[:2].to_owned()), ["run", "run"])
  assert_eq(clarify_drafts(src)[0].title, clarify_lines()[2])
  assert_eq(board_faults(t), [])
}
