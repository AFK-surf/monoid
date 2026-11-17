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
/// 显示 in the wide board's bar (its words what the board is grouped by, where that is not by state) pressed: its panel
/// open, settled.
fn board_display_open(t : @ui.Tester) -> Unit raise {
  for w in ["显示", "按机器", "按成员"] {
    if t.query(Button, label=w) is Some(_) {
      t.click(Button, label=w)
      t.run_for(@ui.move_most_ms)
      return
    }
  }
  fail("no 显示 in the board's bar")
}

///|
/// The wide board grouped as `w` says (按状态, 按机器, 按成员) in 显示's panel, the panel closed again after.
fn board_group_by(t : @ui.Tester, w : String) -> Unit raise {
  board_display_open(t)
  t.click(Radio, label=w)
  t.run_for(@ui.move_most_ms)
  t.key(@ui.key_escape)
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
  // 列表 (a key of the bar's): the sidebar's list again, the board gone
  t.click(Button, label="列表")
  t.run_for(@ui.move_most_ms)
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
  board_group_by(t, "按机器")
  assert_true(board_words_at(t, "Willow") is Some(_))
  assert_eq(board_faults(t), [])
  board_group_by(t, "按成员")
  assert_true(board_words_at(t, "林（我）") is Some(_))
  assert_eq(board_faults(t), [])
  ignore(src)
}

///|
test "小屏: the board under Home's bar, a column at a time by its chips, a card opening its chat" {
  let (t, _) = board_at("board", 390.0, 844.0, platform=2)
  assert_true(board_words_at(t, "整理发布清单") is Some(_))
  assert_eq(board_faults(t), [])
  t.click(Tab, label="进行中 3")
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
  for w in ["显示", "新待办", "待派发"] {
    assert_true(board_words_at(t, w) is Some(_), msg="\{w} on the board")
  }
  for w in ["列表", "筛选会话：全部"] {
    assert_true(t.query(Button, label=w) is Some(_), msg="\{w} in the board's bar")
  }
  assert_eq(board_faults(t), [])
}

///|
test "中屏 600: the board's bar whole in the tape's page panel, 列表 back to the list" {
  let (t, src) = board_at("board", 600.0, 800.0)
  assert_true(@sfdesk.wide.tape_at.get() is Page)
  for w in ["显示", "新待办"] {
    assert_true(board_words_at(t, w) is Some(_), msg="\{w} on the board")
  }
  assert_eq(board_faults(t), [])
  t.click(Button, label="列表")
  t.run_for(@ui.move_most_ms)
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
  board_group_by(t, "按机器")
  assert_true(@sffixture.board_prefs["boardGroups"].get("ws1") is Some(String("station")))
  board_group_by(t, "按状态")
  assert_true(@sffixture.board_prefs["boardGroups"].get("ws1") is None)
  t.click(Button, label="新待办")
  t.run_for(@ui.move_most_ms)
  t.type_text("周五前把发布说明定稿")
  t.enter()
  t.run_for(@ui.move_most_ms)
  assert_eq(board_kept_drafts(), ["周五前把发布说明定稿", "给导出加上按月份筛选", "看一下 Android 冷启动为什么慢了 300ms"])
  board_group_by(t, "按成员")
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
  t.click(Button, label="列表")
  t.run_for(@ui.move_most_ms)
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
/// The board's app on a phone over `mode` in a window `w` × `h`, the system's words at `scale`, at rest: the workspace
/// shown named `name` where one is said, Home's list catching up where `syncing` (fix_with_syncing).
fn board_bar_at(
  mode : String,
  w : Double,
  h : Double,
  scale? : Double = 1.0,
  name? : String = "",
  syncing? : Bool = false,
) -> (@ui.Tester, Source) {
  new_run()
  let base = fixture(mode)
  let src : Source = {
    ..base,
    topic_read: fn(topic, params) {
      let got = base.topic(topic, params).get().snapshot()
      match (topic, got.value) {
        ("workspaces", Some(v)) if name != "" =>
          { ..got, value: Some(@json.parse(v.stringify().replace(old="星火工作室", new=name)) catch { _ => v }) }
        ("chats", Some(v)) if syncing => { ..got, value: Some(@sffixture.fix_with_syncing(v)) }
        // (实验性功能's 对话列表看板视图 on, its key on Home's bar, in a mode not the board's: experimental_wbtest.mbt has it off)
        ("prefs", Some(Object(m))) => {
          let m = m.copy()
          m["experimental"] = { "board": true }
          { ..got, value: Some(Json::object(m)) }
        }
        _ => got
      }
    },
  }
  open_fixture_over(mode, src)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform=2)
  if scale != 1.0 {
    t.set_font_scale(scale)
  }
  t.run_for(@ui.move_most_ms)
  (t, src)
}

///|
/// The audit's faults made in Home's bar (home_node.mbt's home_top_bar_node) or the board's own files.
fn board_bar_faults(t : @ui.Tester) -> Array[String] {
  board_faults(t) + t.audit().filter(fn(f) { f.contains("sfapp/home_node.mbt") })
}

///|
test "小屏: 筛选 and 看板 their own keys on Home's bar, at 390 and at 360 with words at 1.3 and a long workspace's name; on the board 筛选 and 列表, 列表 back" {
  for at in [(390.0, 844.0, 1.0, ""), (360.0, 740.0, 1.3, ""), (360.0, 740.0, 1.3, "星火工作室北京研发中心团队")] {
    let (w, h, scale, name) = at
    let (t, src) = board_bar_at("board-list", w, h, scale~, name~)
    assert_true(t.query(Button, label="筛选会话：全部") is Some(_))
    assert_true(t.query(Button, label="看板") is Some(_))
    assert_eq(t.squeeze_faults(), [])
    assert_eq(t.words_over_now(), [])
    assert_eq(board_bar_faults(t), [])
    t.click(Button, label="看板")
    t.run_for(@ui.move_most_ms)
    assert_true(@sfbase.board_on_of(src, "ws1"))
    assert_true(board_words_at(t, "整理发布清单") is Some(_))
    assert_true(t.query(Button, label="筛选会话：全部") is Some(_))
    assert_true(t.query(Button, label="列表") is Some(_))
    assert_true(t.query(Button, label="看板") is None)
    assert_eq(t.squeeze_faults(), [])
    assert_eq(t.words_over_now(), [])
    assert_eq(board_bar_faults(t), [])
    t.click(Button, label="列表")
    t.run_for(@ui.move_most_ms)
    assert_false(@sfbase.board_on_of(src, "ws1"))
    assert_true(t.query(Button, label="看板") is Some(_))
    assert_eq(board_bar_faults(t), [])
  }
}

///|
test "小屏 360: Home's bar crowded: the stations' releases leave first, then 看板 beside catching up; 筛选 and catching up stay, nothing over anything" {
  for scale in [1.0, 1.3] {
    // (the stations' releases alone beside them: they leave, 看板 stays)
    let (t, _) = board_bar_at("home-station-updates", 360.0, 740.0, scale~)
    assert_true(t.query(Button, label="看板") is Some(_))
    assert_true(t.query(Button, label="2 台 station 有新版本") is None)
    assert_eq(t.squeeze_faults(), [])
    assert_eq(t.words_over_now(), [])
    assert_eq(board_bar_faults(t), [])
    // (catching up as well: 看板 leaves too, catching up stays)
    let (t, _) = board_bar_at("home-station-updates", 360.0, 740.0, scale~, syncing=true)
    assert_true(t.query(Button, label="筛选会话：全部") is Some(_))
    assert_true(t.query(Button, label="看板") is None)
    assert_true(t.query(Button, label="2 台 station 有新版本") is None)
    assert_true(t.semantics().iter().any(fn(n) { n.label == "正在同步 · 还剩 12 个对话" }))
    assert_eq(t.squeeze_faults(), [])
    assert_eq(t.words_over_now(), [])
    assert_eq(board_bar_faults(t), [])
  }
  // (at 390 the room for the stations' releases beside 看板)
  let (t, _) = board_bar_at("home-station-updates", 390.0, 844.0)
  assert_true(t.query(Button, label="2 台 station 有新版本") is Some(_))
  assert_true(t.query(Button, label="看板") is Some(_))
}

///|
/// The words of the menu open (its items, as a screen reader reads them: a sheet's on 小屏, a menu's beside what opened
/// it on 大屏).
fn board_menu_said(t : @ui.Tester) -> Array[String] {
  let out = []
  for n in t.semantics() {
    if n.role is (MenuItem | MenuItemCheckbox | MenuItemRadio) {
      out.push(n.label)
    } else if n.role is Dialog {
      for w in n.label.split(" ") {
        out.push(w.to_owned())
      }
    }
  }
  out
}

///|
test "小屏: the board's filter narrows it to 我参与的 and back to 全部会话, its menu no 监控中 and no 看板; 已隐藏 the list's" {
  let (t, src) = board_bar_at("board-list", 390.0, 844.0)
  t.click(Button, label="看板")
  t.run_for(@ui.move_most_ms)
  let all = @sfbase.board_items(src, "ws1").length()
  t.click(Button, label="筛选会话：全部")
  t.run_for(@ui.move_most_ms)
  let said = board_menu_said(t)
  assert_true(said.contains("全部会话"))
  assert_true(said.contains("我参与的"))
  assert_true(said.contains("已隐藏"))
  assert_true(said.contains("已归档"))
  assert_false(said.contains("监控中"))
  assert_false(said.contains("看板"))
  board_tap_words(t, "我参与的")
  assert_eq(filter_of(src, "ws1"), "mine")
  assert_true(@sfbase.board_on_of(src, "ws1"))
  let mine = @sfbase.board_items(src, "ws1").length()
  assert_true(mine > 0 && mine < all)
  assert_true(t.query(Button, label="筛选会话：我参与的") is Some(_))
  assert_eq(board_bar_faults(t), [])
  t.click(Button, label="筛选会话：我参与的")
  t.run_for(@ui.move_most_ms)
  board_tap_words(t, "全部会话")
  assert_eq(@sfbase.board_items(src, "ws1").length(), all)
  t.click(Button, label="筛选会话：全部")
  t.run_for(@ui.move_most_ms)
  board_tap_words(t, "已隐藏")
  assert_eq(filter_of(src, "ws1"), "hidden")
  assert_false(@sfbase.board_on_of(src, "ws1"))
}

///|
test "小屏: the list's 监控中 taken onto the board as its 监控中 column, the board narrowed to all of them" {
  let (t, src) = board_bar_at("board-list", 390.0, 844.0)
  t.click(Button, label="筛选会话：全部")
  t.run_for(@ui.move_most_ms)
  board_tap_words(t, "监控中")
  assert_eq(filter_of(src, "ws1"), "watching")
  t.click(Button, label="看板")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.board_lane.get(), "watch")
  assert_eq(filter_of(src, "ws1"), "all")
  assert_true(t.query(Button, label="筛选会话：全部") is Some(_))
}

///|
test "大屏: a card dragged across the board runs a few bindings a move, whatever the board holds: the card in hand where the pointer has it, the column under it lit, no card at rest woken" {
  let (t, _) = board_at("board", 1440.0, 900.0)
  guard board_words_at(t, "看一下 Android 冷启动为什么慢了 300ms") is Some((x, y, _, _)) else { fail("no draft") }
  guard board_words_at(t, "进行中") is Some((rx, ry, _, _)) else { fail("no 进行中") }
  let (x0, y0) = (x + 10.0, y + 6.0)
  t.press_at(x0, y0)
  // (taken past the slop: lifted, the cards' faded one and the board's foot made then)
  t.move_to(x0 + 20.0, y0 + 20.0)
  t.move_to(x0 + 24.0, y0 + 24.0)
  // (ten moves within 待派发, then ten on into 进行中 and along it)
  let at : Array[(Double, Double)] = []
  for i in 1..=10 {
    at.push((x0 + 24.0, y0 + 24.0 + 3.0 * i.to_double()))
  }
  for i in 1..=10 {
    let k = i.to_double() / 10.0
    at.push((x0 + 24.0 + (rx + 40.0 - x0 - 24.0) * k, y0 + 54.0 + (ry + 200.0 - y0 - 54.0) * k))
  }
  let ran : Array[Int] = []
  for p in at {
    t.tree_frames_from_now()
    t.move_to(p.0, p.1)
    ran.push(t.tree_frames().fold(init=0, fn(a, f) { a + f.bindings }))
  }
  // (a move under which nothing changes: the card in hand alone, and what of a column's light is still on its way; one
  // that comes over a column: that column's light set off, the card in hand's words told what a drop there does, and
  // the choice of what is under it, at most so many whatever the board holds)
  assert_true(ran.iter().take(10).all(fn(n) { n <= 2 }), msg="bindings each move within its column: \{Repr(ran)}")
  assert_true(ran.iter().all(fn(n) { n <= 7 }), msg="bindings each move: \{Repr(ran)}")
  t.release(rx + 40.0, ry + 200.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(board_faults(t), [])
}

///|
/// A finger across the narrow board's track at `y` from `x0` by `dx`, in `steps` moves input_step_ms apart, let go
/// (`up`) or held there.
fn board_swipe(t : @ui.Tester, x0 : Double, y : Double, dx : Double, steps : Int, up? : Bool = true) -> Unit {
  t.touch(0, x0, y)
  for i in 1..=steps {
    t.advance(@ui.input_step_ms)
    t.touch(1, x0 + dx * i.to_double() / steps.to_double(), y)
  }
  if up {
    t.touch(2, x0 + dx, y)
    t.run_for(@ui.move_most_ms)
  }
}

///|
test "小屏: the board's columns swiped across, in the hand and let go on the next, back, or back where they were short of it; a finger down them scrolls, no card lifted" {
  let (t, _) = board_at("board", 390.0, 844.0, platform=2)
  assert_eq(@sfbase.board_lane.get(), "wait")
  let y = 500.0
  // (in the hand: the column chosen and the next moved with it, as far as the finger has gone)
  board_swipe(t, 300.0, y, -120.0, 6, up=false)
  t.draw()
  let run_x = board_words_at(t, "首页的列表改成按天分组").map(fn(r) { r.0 })
  assert_true(run_x is Some(x) && x > 200.0 && x < 390.0)
  t.touch(2, 180.0, y)
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.board_lane.get(), "run")
  assert_true(board_words_at(t, "首页的列表改成按天分组").map(fn(r) { r.0 < 60.0 }).unwrap_or(false))
  assert_eq(board_faults(t), [])
  // (back by a swipe the other way)
  board_swipe(t, 100.0, y, 160.0, 6)
  assert_eq(@sfbase.board_lane.get(), "wait")
  // (short of the share and slow: back where it was)
  board_swipe(t, 300.0, y, -50.0, 12)
  assert_eq(@sfbase.board_lane.get(), "wait")
  // (short of the share as far as it went, let go still going: landing past it from its speed, the next; then back)
  board_swipe(t, 300.0, y, -60.0, 12)
  assert_eq(@sfbase.board_lane.get(), "run")
  board_swipe(t, 100.0, y, 160.0, 6)
  assert_eq(@sfbase.board_lane.get(), "wait")
  // (down the column: it scrolls, no card in the hand, no place to let one go)
  t.touch(0, 200.0, 700.0)
  for i in 1..=6 {
    t.advance(@ui.input_step_ms)
    t.touch(1, 200.0, 700.0 - 40.0 * i.to_double())
    assert_false(@sfbase.board_drag_active.get())
  }
  t.touch(2, 200.0, 460.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.board_lane.get(), "wait")
  assert_false(@sfbase.board_drag_active.get())
  assert_eq(board_faults(t), [])
}

///|
test "小屏: a draft's card held long offers 立即派发 and 删除; not dragged" {
  let (t, _) = board_at("board", 390.0, 844.0, platform=2)
  t.click(Tab, label="待派发 2")
  t.run_for(@ui.move_most_ms)
  guard t.semantics().iter().find_first(fn(n) { n.role is Button && n.rect.1 > 200.0 && n.rect.2 > 300.0 }) is Some(card) else {
    fail("no draft's card")
  }
  let (x, y) = (card.rect.0 + 40.0, card.rect.1 + 20.0)
  t.touch(0, x, y)
  t.advance(@ui.long_press_ms + @ui.input_step_ms)
  t.draw()
  t.touch(2, x, y)
  t.run_for(@ui.move_most_ms)
  let said = board_menu_said(t)
  assert_true(said.contains("立即派发"))
  assert_true(said.contains("删除"))
  assert_false(@sfbase.board_drag_active.get())
}

///|
test "大屏: the board's bar's filter narrows it to 我参与的, saying so on itself, and back" {
  let (t, src) = board_at("board", 1440.0, 900.0)
  let all = @sfbase.board_items(src, "ws1").length()
  t.click(Button, label="筛选会话：全部")
  t.run_for(@ui.move_most_ms)
  assert_false(board_menu_said(t).contains("监控中"))
  board_tap_words(t, "我参与的")
  assert_eq(filter_of(src, "ws1"), "mine")
  assert_true(@sfbase.board_on_of(src, "ws1"))
  assert_true(@sfbase.board_items(src, "ws1").length() < all)
  // (narrowed: the key says so in words, and opens the same menu)
  assert_true(t.query(Button, label="筛选会话：全部") is None)
  // (the bar's, at its end: the list's own filter, folded into the sidebar, says so as well)
  guard t.all(Button, label="我参与的").filter(fn(b) { b.rect.0 > 720.0 }) is [b] else { fail("no 我参与的 in the board's bar") }
  let (bx, by, bw, bh) = b.rect
  t.tap(bx + bw / 2.0, by + bh / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(board_faults(t), [])
  board_tap_words(t, "全部会话")
  assert_eq(filter_of(src, "ws1"), "all")
  assert_true(t.query(Button, label="筛选会话：全部") is Some(_))
  assert_eq(board_faults(t), [])
}

///|
test "大屏: 显示's panel: 列表 | 看板 as cards, how it is grouped and its empty columns, the board behind it changing at once, audit clean" {
  let (t, src) = board_at("board", 1440.0, 900.0)
  board_display_open(t)
  for w in ["列表", "看板", "分组方式", "按状态", "按机器", "按成员", "显示空列"] {
    assert_true(board_words_at(t, w) is Some(_), msg="\{w} in 显示's panel")
  }
  assert_true(t.query(Radio, label="看板") is Some(_))
  assert_eq(board_faults(t), [])
  // grouped by station from it: the board behind it so at once, the panel left open, 显示 saying 按机器
  t.click(Radio, label="按机器")
  t.run_for(@ui.move_most_ms)
  assert_eq(@signals.untracked(fn() { @sfbase.board_group_of(src, "ws1") }), "station")
  assert_true(board_words_at(t, "Willow") is Some(_))
  assert_true(board_words_at(t, "分组方式") is Some(_), msg="the panel left open")
  assert_eq(board_faults(t), [])
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_true(board_words_at(t, "分组方式") is None)
  assert_true(t.query(Button, label="按机器") is Some(_))
  assert_true(t.query(Button, label="显示") is None)
  // back by state: 显示 again; its 列表 card back to the list, the panel closed
  board_group_by(t, "按状态")
  assert_true(t.query(Button, label="显示") is Some(_))
  board_display_open(t)
  t.click(Radio, label="列表")
  t.run_for(@ui.move_most_ms)
  assert_false(@sfbase.board_on_of(src, "ws1"))
  assert_true(board_words_at(t, "分组方式") is None)
  assert_true(board_words_at(t, "待派发") is None)
  assert_eq(board_faults(t), [])
}

///|
test "大屏: 显示空列 off leaves the empty columns out, kept in the core's prefs; 新待办 brings 待派发 in while a draft is written" {
  let (t, src) = board_at("board", 1440.0, 900.0)
  // 待派发 emptied: both drafts started
  for _ in 0..<2 {
    let (sx, sy, sw, sh) = t.all(Button, label="开始")[0].rect
    t.tap(sx + sw / 2.0, sy + sh / 2.0)
    t.run_for(@ui.move_most_ms)
  }
  assert_eq(board_kept_drafts(), [])
  assert_true(board_words_at(t, "待派发") is Some(_), msg="empty, shown")
  board_display_open(t)
  t.click(Switch, label="显示空列")
  t.run_for(@ui.move_most_ms)
  assert_false(@signals.untracked(fn() { @sfbase.board_show_empty_of(src, "ws1") }))
  assert_true(@sffixture.board_prefs["boardShowEmpty"].get("ws1") is Some(False))
  assert_true(board_words_at(t, "待派发") is None, msg="empty, left out")
  assert_true(board_words_at(t, "进行中") is Some(_))
  assert_eq(board_faults(t), [])
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  // (显示 on a ground of its own: the board not as it starts)
  assert_true(t.query(Button, label="显示") is Some(_))
  // 新待办: 待派发 in while its line is open, out again as it is closed
  t.click(Button, label="新待办")
  t.run_for(@ui.move_most_ms)
  assert_true(board_words_at(t, "待派发") is Some(_))
  assert_eq(board_faults(t), [])
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_true(board_words_at(t, "待派发") is None)
  // (the app started again: read of the core's prefs)
  @sfbase.board_reset()
  t.run_for(@ui.move_most_ms)
  assert_false(@signals.untracked(fn() { @sfbase.board_show_empty_of(src, "ws1") }))
  // shown again
  board_display_open(t)
  t.click(Switch, label="显示空列")
  t.run_for(@ui.move_most_ms)
  assert_true(@sffixture.board_prefs["boardShowEmpty"].get("ws1") is None)
  assert_true(board_words_at(t, "待派发") is Some(_))
  assert_eq(board_faults(t), [])
}

///|
test "大屏, a Mac's window (its buttons in the app's top row): the board's bar's start left empty, dragging the window, all it holds at its end" {
  let t = wide_tester([], mode="board", w=1440.0, h=900.0, window_inset=true)
  t.run_for(@ui.move_most_ms)
  assert_eq(board_faults(t), [])
  let (lx, ly, _, lh) = t.get(Button, label="列表").rect
  let (gx, _, gw, _) = t.get(Button, label="新待办").rect
  let y = ly + lh / 2.0
  // (all of it at the bar's end: 列表 past the middle of the window, 新待办 last, clear of its corner)
  assert_true(lx > 720.0, msg="列表 at \{lx}")
  assert_true(gx > lx && gx + gw <= 1440.0 - 12.0, msg="新待办 ends at \{gx + gw}")
  // (the bar before them: nothing there but the bar, dragging the window)
  assert_true(t.drags_window_at(lx / 2.0, y), msg="the bar's empty part")
  assert_false(t.drags_window_at(lx + 4.0, y), msg="列表")
  t.click(Button, label="整理发布清单")
  t.run_for(@ui.move_most_ms)
  assert_eq(board_faults(t), [])
}

///|
test "大屏: each card where the core says its chat stands: one an agent leads under its leader, a colleague's card at work, a watch woken watching, 待收口's unread first; 归档已读 puts away those read alone" {
  let (t, src) = board_at("board", 1440.0, 900.0)
  // (led by another chat's agent: under it, its leader's card saying so, not a card of its own)
  let led = @sfbase.chat_item({ "id": "c16", "title": "执行：状态与通知编码", "opener": { "session": "s-c11", "led": true } })
  assert_false(@sfbase.board_card_own(led))
  assert_true(@sfbase.board_card_own(@sfbase.chat_item({ "id": "c17", "opener": { "session": "s-c11" } })))
  assert_eq(board_lane_now(src, "首页的列表改成按天分组"), "run")
  assert_true(board_words_at(t, "1 个子会话进行中") is Some(_))
  // (a card 周 decides: at work for the viewer; a watch its watch woke: watching all the same)
  assert_eq(board_lane_now(src, "补一下部署文档"), "run")
  assert_eq(board_lane_now(src, "盯着 CI，绿了告诉我"), "watch")
  // (待收口: the result not read over those read)
  let top = fn(w : String) { board_words_at(t, w).map(fn(r) { r.1 }).unwrap_or(-1.0) }
  assert_true(top("给设置页加一个深色模式开关") >= 0.0 && top("给设置页加一个深色模式开关") < top("Slack 里问的报销流程"))
  assert_eq(board_faults(t), [])
  // (only what the viewer started: Ana's, read too, is not theirs to take off the workspace's lists)
  t.click(Button, label="归档已读 (1)")
  t.run_for(@ui.move_most_ms)
  // (one toast for the press, its 撤销 the whole press's)
  assert_true(board_words_at(t, "已归档 1 个已读的对话") is Some(_))
  assert_true(board_words_at(t, "给设置页加一个深色模式开关") is Some(_))
  assert_true(board_words_at(t, "Slack 里问的报销流程") is Some(_))
  assert_true(board_words_at(t, "把旧的截图都换成新的") is None)
  assert_true(t.query(Button, label="归档已读 (1)") is None)
  assert_eq(board_faults(t), [])
}

///|
/// The narrow board over board-many (a busy workspace's: two figures a column) on a phone's window, at rest.
fn board_many_at() -> (@ui.Tester, Source) {
  board_at("board-many", 390.0, 844.0, platform=2)
}

///|
/// The rect a screen reader is told card or chip `label` (of `role`) has, if it is there.
fn board_rect_of(t : @ui.Tester, role : @ui.Role, label : String) -> (Double, Double, Double, Double)? {
  for n in t.semantics() {
    if n.role == role && n.label == label {
      return Some(n.rect)
    }
  }
  None
}

///|
test "小屏: the board reaches the window's foot, its cards passing under the bottom bar; scrolled to its end, its last card at rest over that bar" {
  let (t, _) = board_many_at()
  let h = 844.0
  let foot = nav_foot() + bar_room_now()
  assert_true(foot > 40.0, msg="the bottom bar covers \{foot}")
  // (a card's words drawn under the bottom bar's top, cut by nothing short of the window's foot: the column not cut
  // in the air over that bar)
  let under = t.glyph_clips().filter(fn(g) { g.0.1 > h - foot && g.0.1 < h - 8.0 })
  assert_true(under.length() > 0, msg="no words under the bottom bar")
  assert_true(under.iter().all(fn(g) { g.1.3 >= h - 0.5 }), msg="words under the bottom bar cut short of the window's foot")
  // (scrolled down to its end: its last card whole, at rest over the bottom bar, as close over it as Home's list's
  // last row)
  for _ in 0..<6 {
    t.wheel(200.0, 500.0, 900.0)
    t.run_for(@ui.move_most_ms)
  }
  guard board_rect_of(t, Button, "安卓冷启动又慢了") is Some((_, y, _, ch)) else { fail("no last card") }
  assert_true(y + ch <= h - foot + 0.5, msg="the last card's foot \{y + ch} under the bottom bar's top \{h - foot}")
  assert_true(y + ch >= h - foot - 24.0, msg="the last card's foot \{y + ch} far over the bottom bar's top \{h - foot}")
  // (a card passing under the bar's glass at its top is under it, not drawn over its chips: a press there is the bar's,
  // as the hit test has it)
  assert_eq(board_faults(t), [])
}

///|
test "小屏: 待收口 says how many it has read and puts them away from its top, the result not read kept" {
  let (t, _) = board_at("board", 390.0, 844.0, platform=2)
  t.click(Tab, label="待收口 3")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.board_lane.get(), "done")
  assert_true(board_words_at(t, "1 项可归档") is Some(_))
  assert_eq(board_faults(t), [])
  t.click(Button, label="归档已读")
  t.run_for(@ui.move_most_ms)
  assert_true(board_words_at(t, "1 项可归档") is None)
  assert_true(board_words_at(t, "Slack 里问的报销流程") is Some(_))
  assert_true(board_words_at(t, "给设置页加一个深色模式开关") is Some(_))
  assert_eq(board_faults(t), [])
}

///|
/// The wide board's columns' lists that reach its foot (the clips of words drawn within `h`'s last 200 points, taller
/// than 300).
fn board_wide_lists(t : @ui.Tester, h : Double) -> Array[(Double, Double, Double, Double)] {
  let out : Array[(Double, Double, Double, Double)] = []
  for g in t.glyph_clips() {
    let c = g.1
    if g.0.1 > h - 200.0 && c.3 - c.1 > 300.0 && !out.contains(c) {
      out.push(c)
    }
  }
  out
}

///|
/// The wide board over board-many in a window `w` × `h`: each column's list reaching the foot of the panel or the window
/// (within `h` by less than the page's margin), not cut in the air over it; each that scrolls, scrolled to its end, its
/// last card at rest the page's margin over that foot, as far as from the sides.
fn board_wide_foot_holds(w : Double, h : Double) -> Unit raise {
  let (t, _) = board_at("board-many", w, h)
  let lists = board_wide_lists(t, h)
  assert_true(lists.length() > 0, msg="no column's cards near the foot")
  let mut scrolled = 0
  for c in lists {
    let (x0, _, x1, y1) = c
    assert_true(y1 > h - 16.0, msg="a column cut at \{y1}, the page's margin or more over the foot \{h}")
    for _ in 0..<12 {
      t.wheel((x0 + x1) / 2.0, y1 - 100.0, 900.0)
      t.run_for(@ui.move_most_ms)
    }
    let mut last = 0.0
    for n in t.semantics() {
      if n.role == Button && n.rect.0 >= x0 - 1.0 && n.rect.0 + n.rect.2 <= x1 + 1.0 && n.rect.2 > 150.0 {
        if n.rect.1 + n.rect.3 > last {
          last = n.rect.1 + n.rect.3
        }
      }
    }
    if last > y1 - 40.0 {
      scrolled += 1
      assert_true((last - (y1 - 16.0)).abs() < 0.5, msg="the last card's foot \{last}, not 16 over the foot \{y1}")
    }
  }
  assert_true(scrolled > 0, msg="no column scrolled to its end")
  assert_eq(board_faults(t), [])
}

///|
/// How many times words `w` are drawn.
fn board_words_n(t : @ui.Tester, w : String) -> Int {
  t.words().filter(fn(x) { x.0 == w }).length()
}

///|
test "小屏: 待处理 lists what waits for the viewer read or not, and 全部已读 takes only what was unread" {
  let (t, _) = board_at("board", 390.0, 844.0, platform=2)
  t.click(Button, label="待处理")
  t.run_for(@ui.move_most_ms)
  // (夜里的构建又失败了 asks them and was looked at: listed as 整理发布清单, not read yet, is; each beside its card)
  assert_eq(board_words_n(t, "夜里的构建又失败了"), 2)
  assert_eq(board_words_n(t, "整理发布清单"), 2)
  let done_before = board_words_n(t, "给设置页加一个深色模式开关")
  board_tap_words(t, "全部已读")
  assert_eq(board_words_n(t, "给设置页加一个深色模式开关"), done_before - 1)
  assert_eq(board_words_n(t, "夜里的构建又失败了"), 2)
  assert_eq(board_words_n(t, "整理发布清单"), 2)
}

///|
test "中屏 760 and 大屏 1440: the board's columns reach the foot, not cut in the air over it; scrolled to its end, a column's last card 16 over that foot" {
  board_wide_foot_holds(760.0, 800.0)
  board_wide_foot_holds(1440.0, 900.0)
}

///|
test "小屏: the board's chips on Home's bar, two figures each; swiped to 监控中, its chip brought whole into sight within the page's margins" {
  let (t, _) = board_many_at()
  for w in ["待派发 2", "等你处理 10", "进行中 28", "待收口 25", "监控中 6"] {
    assert_true(board_rect_of(t, Tab, w) is Some(_), msg="no chip \{w}")
  }
  // (on the bar's glass, its top bar's keys over it: the chips under them, the cards under the chips)
  guard board_rect_of(t, Tab, "等你处理 10") is Some((_, cy, _, chh)) else { fail("no chip") }
  guard board_rect_of(t, Button, "整理发布清单") is Some((_, ty, _, _)) else { fail("no card") }
  assert_true(ty > cy + chh, msg="the first card under the chips")
  // (swiped across, a column at a time, to the last)
  for _ in 0..<3 {
    board_swipe(t, 330.0, 500.0, -200.0, 6)
  }
  assert_eq(@sfbase.board_lane.get(), "watch")
  guard board_rect_of(t, Tab, "监控中 6") is Some((x, _, w, _)) else { fail("no 监控中") }
  assert_true(x >= 16.0 - 0.5 && x + w <= 390.0 - 16.0 + 0.5, msg="监控中 6 at \{x}, \{w} wide: not whole within the margins")
  // (and back to the first by its chip: in sight again)
  t.click(Tab, label="待派发 2")
  t.run_for(@ui.move_most_ms)
  guard board_rect_of(t, Tab, "待派发 2") is Some((x, _, w, _)) else { fail("no 待派发") }
  assert_true(x >= 16.0 - 0.5 && x + w <= 390.0 - 16.0 + 0.5, msg="待派发 2 at \{x}: not whole within the margins")
  assert_eq(board_faults(t), [])
}

///|
test "小屏: a card on a station with no mark of its own says its name where its title begins, nothing before it" {
  let (t, _) = board_many_at()
  guard board_words_at(t, "Farview 替换 agent 浏览器") is Some((tx, ty, _, _)) else { fail("no title") }
  let names = t.words().filter(fn(w) { w.0 == "tokyo-mac-studio-0" && w.2 > ty })
  guard names.get(0) is Some(n) else { fail("no station's name") }
  assert_eq(n.1, tx)
  assert_eq(t.line_start_faults().filter(fn(f) { f.contains("board_node") }), [])
  assert_eq(t.first_line_faults().filter(fn(f) { f.contains("board_node") }), [])
}

///|
test "小屏: a card's faces asked for their pictures, as a row's; an agent's subagents one mark, no key twice" {
  new_run()
  let asked : Array[String] = []
  let base = fixture("board-many")
  let src : Source = {
    ..base,
    picture: fn(url, stint) {
      asked.push(url)
      (base.picture)(url, stint)
    },
  }
  open_fixture_over("board-many", src)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  assert_true(asked.contains("https://example.com/faces/board-z.png"), msg="asked: \{Repr(asked)}")
  // (its picture drawn in the face's place: the only pictures the narrow board shows)
  assert_true(t.drawn_images().length() > 0, msg="the face's picture not drawn")
  guard board_rect_of(t, Button, "station W10-2：清退 src/store 剩余 16 处 TS Step 代码并加固门禁") is Some((x, y, w, h)) else {
    fail("no card")
  }
  let marks = t
    .semantics()
    .filter(fn(n) {
      n.role is Image && n.label.has_prefix("anthropic") && n.rect.0 >= x && n.rect.1 >= y && n.rect.0 < x + w && n.rect.1 < y + h
    })
  assert_eq(marks.length(), 1)
  assert_eq(board_faults(t), [])
}

///|
test "小屏 and 大屏: a chat's card held long, or right clicked, offers the chat's menu, each of its items the board's to do" {
  let (t, _) = board_many_at()
  guard board_rect_of(t, Button, "夜里的构建又失败了") is Some((x, y, _, _)) else { fail("no card") }
  t.touch(0, x + 40.0, y + 20.0)
  t.advance(@ui.long_press_ms + @ui.input_step_ms)
  t.draw()
  t.touch(2, x + 40.0, y + 20.0)
  t.run_for(@ui.move_most_ms)
  let said = board_menu_said(t)
  for w in ["重命名", "归档"] {
    assert_true(said.contains(w), msg="\{w} not in \{Repr(said)}")
  }
  assert_true(app.nav.top() is Home)
  // (大屏: right clicked at the pointer)
  let (t, _) = board_at("board", 1440.0, 900.0)
  guard board_words_at(t, "夜里的构建又失败了") is Some((x, y, _, _)) else { fail("no card") }
  t.right_click(x + 10.0, y + 6.0)
  t.run_for(@ui.move_most_ms)
  let said = board_menu_said(t)
  for w in ["重命名", "归档"] {
    assert_true(said.contains(w), msg="\{w} not in \{Repr(said)}")
  }
  // (重命名 asked over the page, whatever the input: the card shows no title of a row's to be its field)
  board_tap_words(t, "重命名")
  assert_true(t.semantics().iter().any(fn(n) { n.role is Dialog }), msg="重命名 asked nowhere")
}

///|
/// A card lifted for its menu as it is drawn (its raised ground, wider than a card at rest of 小屏's, 358, by a
/// hundredth and more, narrower than the window) and where among what is drawn; None where none is.
fn board_lifted_card(t : @ui.Tester) -> ((Double, Double, Double, Double), Int)? {
  let raised = @sf.theme().p.raised
  for i, r in t.drawn_rects() {
    if r.4 == raised && r.2 > 358.0 * 1.02 && r.2 < 385.0 {
      return Some(((r.0, r.1, r.2, r.3), i))
    }
  }
  None
}

///|
/// Where among what is drawn the menu's scrim is (a ground over the whole window, seen through), and the top of the
/// sheet a menu is in (what is drawn after `after` across the window's width, under its top).
fn board_scrim_sheet(t : @ui.Tester, w : Double, h : Double, after : Int) -> (Int?, Double) {
  let mut scrim : Int? = None
  let mut top = h
  for i, r in t.drawn_rects() {
    if scrim is None && r.0 <= 0.5 && r.1 <= 0.5 && r.2 >= w && r.3 >= h && (r.4 & 0xFFL) < 0xFFL {
      scrim = Some(i)
    }
    if i > after && r.0 <= 0.5 && r.2 >= w - 0.5 && r.1 > 100.0 && r.1 < top {
      top = r.1
    }
  }
  (scrim, top)
}

///|
/// A long press of a finger at (x, y), let go once its menu is up, settled.
fn board_long_press(t : @ui.Tester, x : Double, y : Double) -> Unit {
  t.touch(0, x, y)
  t.advance(@ui.long_press_ms + @ui.input_step_ms)
  t.draw()
  t.touch(2, x, y)
  t.run_for(@ui.move_most_ms)
}

///|
/// Card `card` held by a finger for its menu and lifted: drawn larger, over the scrim, clear of the sheet over it.
fn board_lifted_over(t : @ui.Tester, what : String) -> (Double, Double, Double, Double) raise {
  guard board_lifted_card(t) is Some((r, at)) else { fail("\{what}: no card lifted") }
  let (scrim, top) = board_scrim_sheet(t, 390.0, 844.0, at)
  assert_true(scrim is Some(s) && s < at, msg="\{what}: scrim \{Repr(scrim)}, card \{at}")
  assert_true(r.1 + r.3 <= top - 12.0 + 0.5, msg="\{what}: its foot \{r.1 + r.3} under the sheet's top \{top} less 12")
  r
}

///|
test "小屏: a card held by a finger lifts over its menu's scrim, clear of its sheet, a step further in too, back down as it closes; a draft's too; a right click lifts none, a mouse's button held opens nothing" {
  let (t, _) = board_many_at()
  let name = "Farview 替换 agent 浏览器"
  guard board_rect_of(t, Button, name) is Some(laid) else { fail("no card") }
  assert_true(board_lifted_card(t) is None)
  board_long_press(t, laid.0 + 40.0, laid.1 + 20.0)
  let up = board_lifted_over(t, "held")
  assert_true(up.2 > 358.0 * 1.02, msg="drawn \{up.2} wide")
  // (lower on the screen than the sheet lets it be: brought up over it)
  assert_true(up.1 + up.3 < laid.1 + laid.3, msg="its foot \{up.1 + up.3} from \{laid.1 + laid.3}")
  assert_eq(board_faults(t), [])
  // (a step further in, 分享…: lifted still, over the sheet that takes the menu's place)
  board_tap_words(t, "分享…")
  board_lifted_over(t, "分享…") |> ignore
  @sf.close_presented_of(@sf.last_presented())
  // (back down on its spring from the moment the menu went)
  t.run_for(@ui.move_most_ms + @motion.lift_spring.duration(1.0, 0.0, 0.0))
  assert_true(!@sf.presented_drawn())
  assert_true(board_lifted_card(t) is None, msg="still lifted")
  assert_eq(board_rect_of(t, Button, name), Some(laid))
  assert_eq(board_faults(t), [])
  // (a draft's card in 待派发, held so: lifted the same)
  t.click(Tab, label="待派发 2")
  t.run_for(@ui.move_most_ms)
  guard board_rect_of(t, Button, "给导出加上按月份筛选") is Some(d) else { fail("no draft's card") }
  board_long_press(t, d.0 + 40.0, d.1 + 20.0)
  assert_true(board_menu_said(t).contains("立即派发"))
  board_lifted_over(t, "a draft's") |> ignore
  assert_eq(board_faults(t), [])
  // (大屏: right clicked, its menu at the pointer, the card where it lies, as large)
  let (t, _) = board_at("board-many", 1440.0, 900.0)
  guard board_rect_of(t, Button, "夜里的构建又失败了") is Some(r) else { fail("no card") }
  t.right_click(r.0 + 40.0, r.1 + 20.0)
  t.run_for(@ui.move_most_ms)
  assert_true(board_menu_said(t).contains("重命名"))
  assert_eq(board_rect_of(t, Button, "夜里的构建又失败了"), Some(r))
  let raised = @sf.theme().p.raised
  assert_true(
    !t.drawn_rects().iter().any(fn(d) { d.4 == raised && (d.2 - r.2).abs() < 40.0 && d.2 > r.2 + 1.0 }),
    msg="a card drawn lifted",
  )
  assert_eq(board_faults(t), [])
  // (a mouse's button held on a card as long as a finger's hold: a press as long as any, waiting to be dragged; no
  // menu, nothing lifted)
  let (t, _) = board_at("board-many", 1440.0, 900.0)
  t.host_says_finger(Some(false))
  guard board_rect_of(t, Button, "夜里的构建又失败了") is Some(r) else { fail("no card") }
  t.touch(0, r.0 + 40.0, r.1 + 20.0)
  t.advance(@ui.long_press_ms + @ui.input_step_ms)
  t.draw()
  assert_true(!@sf.presented_drawn(), msg="a menu up: \{Repr(board_menu_said(t))}")
  assert_eq(board_rect_of(t, Button, "夜里的构建又失败了"), Some(r))
  t.touch(3, r.0 + 40.0, r.1 + 20.0)
  t.run_for(@ui.move_most_ms)
  assert_true(!@sf.presented_drawn())
  assert_eq(board_faults(t), [])
}
