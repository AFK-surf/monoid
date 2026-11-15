// Home's chats as a board (sfpages' board_node, sfbase's board.mbt) over the made-up board (sffixture's board_fixture):
// 列表 ↔ 看板, a draft written and started, a card's chat opened beside the board and its decision made (its card on to
// 进行中), a done chat archived, how it is grouped; 大屏 1440 × 900 and 小屏 390 × 844, every step held to the audit.

///|
/// The board's app over `mode` in a window `w` × `h` (`platform`: 2 a phone's), at rest.
fn board_at(mode : String, w : Double, h : Double, platform? : Int = 0) -> (@ui.Tester, Source) {
  new_run()
  let src = fixture(mode)
  open_fixture_over(mode, src)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
  t.run_for(@ui.move_most_ms)
  (t, src)
}

///|
/// The audit's faults made in the board's own files. (Not what is under the phone's bottom bar where its glass takes
/// presses, as it does once the bar has been told again: Home's list's rows are so too, the bar's.)
fn board_faults(t : @ui.Tester) -> Array[String] {
  t.audit().filter(fn(f) { (f.contains("board_node") || f.contains("sfdesk/board")) && !f.contains("sfapp/bar.mbt") })
}

///|
/// Where words `w` are drawn (their first), if they are.
fn board_words_at(t : @ui.Tester, w : String) -> (Double, Double, Double, Double)? {
  for x in t.words() {
    if x.0 == w {
      return Some((x.1, x.2, x.3, x.4))
    }
  }
  None
}

///|
/// A tap on words `w`, settled.
fn board_tap_words(t : @ui.Tester, w : String) -> Unit raise {
  guard board_words_at(t, w) is Some((x, y, ww, h)) else { fail("no \{w} drawn") }
  t.tap(x + ww / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
}

///|
/// The column the chat titled `title` stands in now (the board's by state).
fn board_lane_now(src : Source, title : String) -> String {
  for i in @sfbase.board_items(src, "ws1") {
    if i.title == title {
      return @sfbase.board_lane_of(i)
    }
  }
  ""
}

///|
test "大屏: the board in place of the list, its five columns, back to the list and to it again, audit clean" {
  let (t, src) = board_at("board", 1440.0, 900.0)
  for f in board_faults(t) { println(f) }
  for w in ["待派发", "等你处理", "进行中", "待收口", "监控中", "整理发布清单", "盯着 CI，绿了告诉我"] {
    assert_true(board_words_at(t, w) is Some(_), msg="\{w} on the board")
  }
  assert_eq(board_faults(t), [])
  // 列表: the sidebar's list again, the board gone
  board_tap_words(t, "列表")
  assert_false(@sfbase.board_on_of(src, "ws1"))
  assert_true(board_words_at(t, "待派发") is None)
  // (kept as the core keeps it: the list again)
  assert_true(@sffixture.board_prefs["boardViews"].get("ws1") is None)
  assert_eq(board_faults(t), [])
  // the sidebar's key back to the board
  t.click(Button, label="看板")
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.board_on_of(src, "ws1"))
  assert_true(@sffixture.board_prefs["boardViews"].get("ws1") is Some(String("board")))
  assert_true(board_words_at(t, "待派发") is Some(_))
  assert_eq(board_faults(t), [])
}

///|
test "大屏: a draft written in 待派发 and started goes on to 进行中 as its chat" {
  let (t, src) = board_at("board", 1440.0, 900.0)
  t.click(Button, label="新待办")
  t.run_for(@ui.move_most_ms)
  t.type_text("把发布说明翻成英文")
  t.enter()
  t.run_for(@ui.move_most_ms)
  assert_true(board_words_at(t, "把发布说明翻成英文") is Some(_))
  assert_eq(board_faults(t), [])
  // (dragged onto 进行中 and let go there: its chat's card in 进行中, flying on from where it was let go, nothing of it
  // back in 待派发 on the way)
  guard board_words_at(t, "把发布说明翻成英文") is Some((x, y, _, _)) else { fail("no draft") }
  guard board_words_at(t, "进行中") is Some((rx, ry, _, _)) else { fail("no 进行中") }
  t.drag(x + 10.0, y + 6.0, rx + 40.0, ry + 260.0)
  for _ in [0, 1, 2, 3, 4, 5] {
    t.run_for(@ui.frame_period_default)
    match board_words_at(t, "把发布说明翻成英文") {
      Some((wx, _, _, _)) => assert_true(wx > rx - 40.0, msg="its card back in 待派发 at \{wx}")
      None => ()
    }
  }
  t.run_for(@ui.move_most_ms)
  assert_eq(board_lane_now(src, "把发布说明翻成英文"), "run")
  assert_true(board_words_at(t, "正在读取仓库与分析改动点…") is Some(_))
  assert_eq(board_faults(t), [])
}

///|
test "大屏: a card pressed opens its chat beside the board; its decision made, the card goes on to 进行中" {
  let (t, src) = board_at("board", 1440.0, 900.0)
  assert_eq(board_lane_now(src, "整理发布清单"), "wait")
  t.click(Button, label="整理发布清单")
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.board_pick.get() is Some(_))
  assert_true(t.query(Button, label="全屏打开") is Some(_))
  assert_eq(board_faults(t), [])
  board_tap_words(t, "一起换")
  assert_eq(board_lane_now(src, "整理发布清单"), "run")
  assert_true(board_words_at(t, "正在按你的决定更新截图与清单…") is Some(_))
  assert_eq(board_faults(t), [])
  // × closes what is beside it
  t.click(Button, label="关闭")
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.board_pick.get() is None)
}

///|
test "大屏: a done chat's 归档 takes it off the board, 撤销 said; grouped by station and by person" {
  let (t, src) = board_at("board", 1440.0, 900.0)
  let keys = t.all(Button, label="归档")
  assert_eq(keys.length(), 3)
  let (x, y, w, h) = keys[0].rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.all(Button, label="归档").length(), 2)
  assert_true(@sfbase.toast_words().has_prefix("已归档"))
  board_tap_words(t, "按机器")
  assert_true(board_words_at(t, "Willow") is Some(_))
  assert_eq(board_faults(t), [])
  board_tap_words(t, "按成员")
  assert_true(board_words_at(t, "林（我）") is Some(_))
  assert_eq(board_faults(t), [])
  ignore(src)
}

///|
test "小屏: the board under Home's bar, a column at a time by its chips, a card opening its chat" {
  let (t, _) = board_at("board", 390.0, 844.0, platform=2)
  assert_true(board_words_at(t, "整理发布清单") is Some(_))
  assert_eq(board_faults(t), [])
  t.click(Button, label="进行中 3")
  t.run_for(@ui.move_most_ms)
  assert_true(board_words_at(t, "首页的列表改成按天分组") is Some(_))
  assert_true(board_words_at(t, "整理发布清单") is None)
  assert_eq(board_faults(t), [])
  t.click(Button, label="首页的列表改成按天分组")
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is Chat(_))
}

///|
test "大屏 1280: a card of the fourth column opened, its column brought whole beside the chat; a draft's 开始 starts it" {
  let (t, src) = board_at("board", 1280.0, 800.0)
  t.click(Button, label="给设置页加一个深色模式开关")
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.board_pick.get() is Some(_))
  // (its title whole, left of the chat beside the board)
  guard board_words_at(t, "给设置页加一个深色模式开关") is Some((x, _, w, _)) else { fail("its card not drawn") }
  assert_true(x >= 0.0 && x + w <= 1280.0 - 460.0, msg="its title at \{x}+\{w}")
  assert_eq(board_faults(t), [])
  t.click(Button, label="关闭")
  t.run_for(@ui.move_most_ms)
  // (新待办 brings 待派发 back into sight, its line open; Escape puts that away)
  t.click(Button, label="新待办")
  t.run_for(@ui.move_most_ms)
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_false(@sfbase.board_adding.get())
  let starts = t.all(Button, label="开始")
  assert_eq(starts.length(), 2)
  let (sx, sy, sw, sh) = starts[0].rect
  t.tap(sx + sw / 2.0, sy + sh / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(board_lane_now(src, "给导出加上按月份筛选"), "run")
  assert_eq(board_faults(t), [])
}

///|
test "中屏 760: the board in the tape's page panel, its bar that panel's bar's, all of it there" {
  let (t, _) = board_at("board", 760.0, 800.0)
  // (the tape holds, the board the page's panel's: brought over as the app starts on a workspace that shows it)
  assert_true(@sfdesk.wide.tape.get())
  assert_true(@sfdesk.wide.tape_at.get() is Page)
  for w in ["列表", "看板", "按状态", "新待办", "待派发"] {
    assert_true(board_words_at(t, w) is Some(_), msg="\{w} on the board")
  }
  assert_eq(board_faults(t), [])
}

///|
test "中屏 600: the board's bar whole in the tape's page panel, 列表 back to the list" {
  let (t, src) = board_at("board", 600.0, 800.0)
  assert_true(@sfdesk.wide.tape_at.get() is Page)
  for w in ["列表", "看板", "按状态", "新待办"] {
    assert_true(board_words_at(t, w) is Some(_), msg="\{w} on the board")
  }
  assert_eq(board_faults(t), [])
  board_tap_words(t, "列表")
  assert_false(@sfbase.board_on_of(src, "ws1"))
  assert_true(@sfdesk.wide.tape_at.get() is Side)
}

///|
/// The drafts of ws1 as the made-up core keeps them (the prefs' `boardDrafts`): each one's words.
fn board_kept_drafts() -> Array[String] {
  match @sffixture.board_prefs["boardDrafts"].get("ws1") {
    Some(Array(a)) => a.map(fn(d) { text(Some(d), "title") })
    _ => []
  }
}

///|
test "大屏: what the board is kept as, the core's prefs: its grouping and a draft written kept there, shown so as the app starts again" {
  let (t, src) = board_at("board", 1440.0, 900.0)
  board_tap_words(t, "按机器")
  assert_true(@sffixture.board_prefs["boardGroups"].get("ws1") is Some(String("station")))
  board_tap_words(t, "按状态")
  assert_true(@sffixture.board_prefs["boardGroups"].get("ws1") is None)
  t.click(Button, label="新待办")
  t.run_for(@ui.move_most_ms)
  t.type_text("周五前把发布说明定稿")
  t.enter()
  t.run_for(@ui.move_most_ms)
  assert_eq(board_kept_drafts(), ["周五前把发布说明定稿", "给导出加上按月份筛选", "看一下 Android 冷启动为什么慢了 300ms"])
  board_tap_words(t, "按成员")
  // (the app started again: nothing of what was chosen here, all of it read of the core's prefs)
  @sfbase.board_reset()
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.board_on_of(src, "ws1"))
  assert_eq(@signals.untracked(fn() { @sfbase.board_group_of(src, "ws1") }), "person")
  assert_eq(@signals.untracked(fn() { @sfbase.board_drafts_of(src, "ws1") }).map(fn(d) { d.title }), board_kept_drafts())
  assert_eq(board_faults(t), [])
}

///|
test "大屏: a draft started becomes its chat by the core's own way, newChat.create under its key then chat.send of its words, its card the chat's all along" {
  let (t, src) = board_at("board", 1440.0, 900.0)
  let starts = t.all(Button, label="开始")
  let (sx, sy, sw, sh) = starts[0].rect
  t.tap(sx + sw / 2.0, sy + sh / 2.0)
  t.run_for(@ui.move_most_ms)
  // (its draft let go of as its chat is made: the core's pending chat keeps it)
  assert_eq(board_kept_drafts(), ["看一下 Android 冷启动为什么慢了 300ms"])
  let made = @sfbase.board_items(src, "ws1").filter(fn(i) { i.client_key == "new:board-seed-1" })
  assert_eq(made.map(fn(i) { (i.title, @sfbase.board_lane_of(i)) }), [("给导出加上按月份筛选", "run")])
  assert_true(board_words_at(t, "正在读取仓库与分析改动点…") is Some(_))
  assert_eq(board_faults(t), [])
}

///|
test "大屏: a draft its station will not start goes back to 待派发 whole, why said" {
  let (t, src) = board_at("board", 1440.0, 900.0)
  @sffixture.board_create_refused.val = "Willow 上还没有可用的模型，先在机器上添加一个。"
  let starts = t.all(Button, label="开始")
  let (sx, sy, sw, sh) = starts[0].rect
  t.tap(sx + sw / 2.0, sy + sh / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.toast_words(), "Willow 上还没有可用的模型，先在机器上添加一个。")
  assert_eq(@signals.untracked(fn() { @sfbase.board_drafts_of(src, "ws1") }).length(), 2)
  assert_eq(board_kept_drafts().length(), 2)
  assert_true(board_words_at(t, "给导出加上按月份筛选") is Some(_))
  assert_eq(t.all(Button, label="开始").length(), 2)
  assert_eq(board_faults(t), [])
}

///|
test "大屏: a draft no longer wanted deleted, from its menu or let go on the board's foot" {
  let (t, _) = board_at("board", 1440.0, 900.0)
  guard board_words_at(t, "给导出加上按月份筛选") is Some((x, y, _, _)) else { fail("no draft") }
  t.right_click(x + 10.0, y + 6.0)
  t.run_for(@ui.move_most_ms)
  board_tap_words(t, "删除")
  assert_eq(board_kept_drafts(), ["看一下 Android 冷启动为什么慢了 300ms"])
  assert_true(board_words_at(t, "给导出加上按月份筛选") is None)
  assert_eq(board_faults(t), [])
  // (dragged: the board's foot says it deletes, let go there it does)
  guard board_words_at(t, "看一下 Android 冷启动为什么慢了 300ms") is Some((x, y, _, _)) else { fail("no draft") }
  t.drag(x + 10.0, y + 6.0, 700.0, 860.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(board_kept_drafts(), [])
  assert_true(board_words_at(t, "暂时没有待派发事项") is Some(_))
  assert_eq(board_faults(t), [])
}

///|
test "the board kept as shown: 小屏, 中屏 and 大屏 start on it, all it reads declared as the workspace comes in view and read" {
  let faults : Array[String] = []
  for s in [("小屏", 390.0, 844.0, 2), ("中屏", 760.0, 820.0, 0), ("大屏", 1280.0, 820.0, 0)] {
    let (name, w, h, platform) = s
    new_run()
    let heard : Array[String] = []
    let base = fixture("board")
    let src = { ..round_trip_again(base, 0.0, heard=fn(x) { heard.push(x) }, late=fn(_, _) { 60.0 }), reads_ahead: fn() { true } }
    let t = switch_screen(src, w, h, platform, 60.0)
    if board_words_at(t, "待派发") is None {
      faults.push("\{name}: not on the board")
    }
    let unread = @sfbase.declared_unread()
    if unread.length() > 0 {
      faults.push("\{name}: declared and read by none at rest: " + unread.join(", "))
    }
    let again = asked_again(heard)
    if again.length() > 0 {
      faults.push("\{name}: let go of and asked again as it opened: " + again.join(", "))
    }
    // (its audit is board_at's, each screen's: this core's bar over Home's foot is the harness's, the list's as well)
  }
  assert_eq(faults, [])
}

///|
test "中屏 600: the list chosen, the sidebar's 看板 key brings the board back in the page's panel" {
  let (t, src) = board_at("board", 600.0, 800.0)
  board_tap_words(t, "列表")
  assert_true(@sfdesk.wide.tape_at.get() is Side)
  t.click(Button, label="看板")
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.board_on_of(src, "ws1"))
  assert_true(@sfdesk.wide.tape_at.get() is Page)
  assert_eq(board_faults(t), [])
}

///|
test "大屏: a draft's chat archived is gone from the board, its draft's card not back in its place" {
  let (t, src) = board_at("board", 1440.0, 900.0)
  let starts = t.all(Button, label="开始")
  let (sx, sy, sw, sh) = starts[0].rect
  t.tap(sx + sw / 2.0, sy + sh / 2.0)
  t.run_for(@ui.move_most_ms)
  let made = @signals.untracked(fn() { @sfbase.board_items(src, "ws1") }).filter(fn(i) { i.client_key == "new:board-seed-1" })
  assert_eq(made.length(), 1)
  // (archived as a chat's row is: chat_row's archive_row)
  let i = made[0]
  let params : Map[String, Json] = {
    "station": Json::string(i.station),
    "session": Json::string(i.session),
    "archived": Json::boolean(true),
  }
  match i.thread {
    Some(th) => params["thread"] = Json::number(th)
    None => ()
  }
  (src.call)("chat.archive", Json::object(params), @sfbase.answer_unread)
  t.run_for(@ui.move_most_ms)
  let left = @signals.untracked(fn() { @sfbase.board_items(src, "ws1") })
  assert_eq(left.filter(fn(i) { i.client_key == "new:board-seed-1" || i.id == "new:board-seed-1" }).length(), 0)
  assert_true(board_words_at(t, "给导出加上按月份筛选") is None)
  assert_true(board_words_at(t, "正在派发…") is None)
  assert_eq(board_faults(t), [])
}

///|
test "小屏: the list's filter menu offers 看板; on the board its key in the filter's place goes back to the list" {
  let (t, src) = board_at("board-list", 390.0, 844.0, platform=2)
  assert_false(@sfbase.board_on_of(src, "ws1"))
  t.click(Button, label="筛选会话：全部")
  t.run_for(@ui.move_most_ms)
  board_tap_words(t, "看板")
  assert_true(@sfbase.board_on_of(src, "ws1"))
  assert_true(board_words_at(t, "整理发布清单") is Some(_))
  assert_true(t.query(Button, label="筛选会话：全部") is None)
  assert_eq(board_faults(t), [])
  t.click(Button, label="列表")
  t.run_for(@ui.move_most_ms)
  assert_false(@sfbase.board_on_of(src, "ws1"))
  assert_true(t.query(Button, label="筛选会话：全部") is Some(_))
}
