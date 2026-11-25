// Unified Remote experience (`Place("remote")` as the chats' list, each station's heading's ＋, unified chat remote menu,
// side-panel terminal, standalone window handoff): verified across 小屏 and 大屏 with `Tester::audit()` clean.

///|
/// What the audit finds that is of 远程's own making (its list, its sidebar's top, its page), apart from the frame's
/// own known before it: its edge, the rail's places reaching 4 into the sidebar beside it (rail_node.mbt's `cap`,
/// into the rail's margin: said the same of the chats' sidebar, sidebar_node.mbt), and the bottom bar over the list.
fn remote_faults(t : @ui.Tester) -> Array[String] {
  t
  .audit()
  .filter(fn(f) {
    (f.contains("remote_node") || f.contains("side_node.mbt")) &&
    // (the sidebar's edge to drag, laid over its own side as every place's sidebar has it)
    !(f.contains("ui/src/controls/edge_node.mbt:") && f.contains("in what was asked for at stillfail/src/sfdesk/pane_view.mbt:")) &&
    !(f.has_prefix("apart: ") && f.contains("made at stillfail/src/sfdesk/rail_node.mbt:")) &&
    // (on 小屏 the list runs on under the bottom bar's glass, as the chats' list does: a row there is pressed where the
    // glass does not lie over it)
    !(f.has_prefix("apart: ") && f.contains("made at stillfail/src/sfapp/bar.mbt:"))
  })
}

///|
/// 小屏's 远程 at rest, held: Willow's and Maple's headings, each with its ＋ named by its station; the bottom bar's notch
/// closed (no ＋ there besides theirs); no fault of 远程's own.
fn remote_small_clean(t : @ui.Tester, msg : String) -> Unit raise {
  for st in ["Willow", "Maple"] {
    assert_true(t.find(st) is Some(_), msg=msg + ": heading " + st)
    assert_true(t.query(Button, label="在 " + st + " 新建视图") is Some(_), msg=msg + ": " + st + "'s ＋")
  }
  assert_eq(bar.told.map(fn(b) { b.action }), Some(""), msg=msg + ": the notch's ＋")
  assert_eq(t.corner_faults(), [], msg=msg)
  assert_eq(t.first_line_faults(), [], msg=msg)
  let faults = remote_faults(t)
  assert_eq(faults, [], msg=msg + ":\n" + faults.join("\n"))
}

///|
test "小屏 Place(\"remote\"): each station under its heading with its ＋, its display, simulator, tabs and terminals; no ＋ in the bar's notch" {
  new_run()
  let src = fixture_app("place-remote")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(first_page_ms + @ui.move_most_ms)
  assert_true(app.nav.top() == Place("remote"))
  // (each station's heading, then its rows: the display always there, the simulator, the tabs, the terminals)
  for row in ["桌面", "iPhone 17 Pro", "发布清单 - localhost:5173", "收件箱 - Proton Mail", "station", "still.fail", "~", "maple-worker"] {
    assert_true(t.query(Link, label=row) is Some(_), msg="row " + row)
  }
  // (under each name what it is, never its name again: the display's size, the agent driving, the folder whole)
  assert_true(t.find("3024 × 1964 · 无人在看") is Some(_))
  assert_true(t.find("2560 × 1440 · 无人在看") is Some(_), msg="Maple's display")
  assert_true(t.find("Agent 正在操作 · localhost:5173") is Some(_))
  assert_true(t.find("~/still.fail/station · 左子健 控制中") is Some(_))
  // (no card's pills nor chevrons of before)
  assert_true(t.query(Button, label="浏览器") is None)
  assert_true(t.query(Button, label="终端") is None)
  remote_small_clean(t, "at rest")
  // Willow's ＋: 新建终端 and 新建浏览器标签页 from it; 新建终端 picked, a new terminal's page on Willow
  t.click(Button, label="在 Willow 新建视图")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("新建终端") is Some(_))
  assert_true(t.find("新建浏览器标签页") is Some(_))
  t.tap_text("新建终端")
  t.run_for(@ui.move_most_ms)
  match app.nav.top() {
    Terminal(at) => assert_eq((at.station, at.terminal), ("ws1/st1", "new"))
    _ => fail("not a terminal on top")
  }
}

///|
test "小屏 Place(\"remote\"): Maple's ＋, 新建浏览器标签页: a new tab of Maple's browser, its page" {
  new_run()
  let src = fixture_app("place-remote")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(first_page_ms + @ui.move_most_ms)
  t.click(Button, label="在 Maple 新建视图")
  t.run_for(@ui.move_most_ms)
  t.tap_text("新建浏览器标签页")
  t.run_for(@ui.move_most_ms)
  match app.nav.top() {
    Screen(at) => assert_true(at.station == "ws1/st2" && at.screen.has_prefix("browser:u_"), msg=at.station + " " + at.screen)
    _ => fail("not a screen on top")
  }
  assert_true(t.find("无法打开新标签页") is None, msg="the new tab made, nothing failed")
}

///|
test "小屏 Place(\"remote\"): a row pressed opens its page" {
  new_run()
  let src = fixture_app("place-remote")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(first_page_ms + @ui.move_most_ms)
  t.click(Link, label="still.fail")
  t.run_for(@ui.move_most_ms)
  match app.nav.top() {
    Terminal(at) => assert_eq(at.terminal, "term-2")
    _ => fail("not term-2 on top")
  }
}

///|
/// 大屏's 远程 at rest, held: the list beside the pane, the pane's own bar alone at its top (no row of tabs over it,
/// the list being that row), the row shown selected, no fault of 远程's own.
fn remote_wide_clean(t : @ui.Tester, msg : String) -> Unit raise {
  assert_true(t.query(Button, label="新建远程标签") is None, msg=msg + ": no row of tabs' ＋")
  for title in ["桌面", "iPhone 17 Pro", "发布清单 - localhost:5173", "收件箱 - Proton Mail", "still.fail"] {
    assert_true(t.query(Button, label="关闭 " + title) is None, msg=msg + ": no tab's × for " + title)
  }
  assert_eq(t.corner_faults(), [], msg=msg)
  assert_eq(t.first_line_faults(), [], msg=msg)
  let faults = remote_faults(t)
  assert_eq(faults, [], msg=msg + ":\n" + faults.join("\n"))
}

///|
/// The tab in front of ws1's workbench, as its kind and id.
fn remote_front_now(src : Source) -> String {
  let (tabs, act) = @sfbase.remote_tabs_of(src, "ws1")
  match tabs.iter().find_first(fn(p) { p.0 == act }) {
    Some((_, Screen(a))) => "screen " + a.screen
    Some((_, Terminal(a))) => "terminal " + a.terminal
    None => ""
  }
}

///|
/// The station of the tab in front of ws1's workbench.
fn remote_front_station(src : Source) -> String {
  let (tabs, act) = @sfbase.remote_tabs_of(src, "ws1")
  match tabs.iter().find_first(fn(p) { p.0 == act }) {
    Some((_, tab)) => tab.station()
    None => ""
  }
}

///|
/// 中屏 and 大屏's 远程 sidebar, held: no row of its own over the list (no band's 新建终端 nor browser key), each
/// station's heading with its ＋.
fn remote_side_heads(t : @ui.Tester, msg : String) -> Unit raise {
  assert_true(t.query(Button, label="新建终端") is None, msg=msg + ": no band's 新建终端")
  assert_true(t.query(Button, label="打开浏览器") is None, msg=msg + ": no band's browser key")
  for st in ["Willow", "Maple"] {
    assert_true(t.find(st) is Some(_), msg=msg + ": heading " + st)
    assert_true(t.query(Button, label="在 " + st + " 新建视图") is Some(_), msg=msg + ": " + st + "'s ＋")
  }
}

///|
test "大屏 Place(\"remote\"): the stations' headings and their ＋ beside the tab shown under the pane's one bar; rows of both stations shown there, kept behind; a ＋'s new views made on its station" {
  new_run()
  let src = fixture_app("place-remote-tabs")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=820.0, platform=0)
  t.run_for(first_page_ms + @ui.move_most_ms)
  assert_true(app.nav.top() == Place("remote"))
  remote_side_heads(t, "at first")
  for row in ["桌面", "iPhone 17 Pro", "发布清单 - localhost:5173", "收件箱 - Proton Mail", "still.fail", "maple-worker"] {
    assert_true(t.query(Link, label=row) is Some(_), msg="row " + row)
  }
  // (the tab in front as the fixture left it: the terminal, its bar's folder and 控制中心 at the pane's top)
  assert_eq(remote_front_now(src), "terminal term-2")
  assert_eq(@sfbase.remote_tabs_of(src, "ws1").0.length(), 3)
  assert_true(t.query(Button, label="控制中心") is Some(_), msg="the terminal's 控制中心")
  remote_wide_clean(t, "at first")
  // each row pressed, Willow's and Maple's: shown in the pane at once, under its own one bar; what was shown kept
  let steps : Array[(String, String, String, Int)] = [
    ("iPhone 17 Pro", "ws1/st1", "screen sim:iphone", 4),
    ("maple-worker", "ws1/st2", "terminal term-m1", 5),
    ("收件箱 - Proton Mail", "ws1/st1", "screen browser:u_mail", 6),
    ("still.fail", "ws1/st1", "terminal term-2", 6),
  ]
  for step in steps {
    let (row, station, front, kept) = step
    t.click(Link, label=row)
    t.run_for(@ui.move_most_ms)
    assert_eq(remote_front_now(src), front, msg=row)
    assert_eq(remote_front_station(src), station, msg=row)
    assert_eq(@sfbase.remote_tabs_of(src, "ws1").0.length(), kept, msg=row)
    remote_wide_clean(t, row)
  }
  // ⌘⇧] and ⌘⇧[: the list's next row, then back to the one before (still.fail's terminal)
  @sfpages.remote_row_step(src, "ws1", 1)
  t.run_for(@ui.move_most_ms)
  let next = remote_front_now(src)
  assert_true(next != "terminal term-2" && next != "", msg="⌘⇧] from still.fail: " + next)
  remote_wide_clean(t, "⌘⇧]")
  @sfpages.remote_row_step(src, "ws1", -1)
  t.run_for(@ui.move_most_ms)
  assert_eq(remote_front_now(src), "terminal term-2", msg="⌘⇧[ back")
  // Willow's ＋, 新建终端: a new terminal on Willow shown, another tab
  let before = @sfbase.remote_tabs_of(src, "ws1").0.length()
  t.click(Button, label="在 Willow 新建视图")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("新建浏览器标签页") is Some(_), msg="Willow's ＋ menu")
  remote_wide_clean(t, "Willow's ＋ menu")
  t.tap_text("新建终端")
  t.run_for(@ui.move_most_ms)
  let made = remote_front_now(src)
  assert_true(made.has_prefix("terminal ") && made != "terminal term-2", msg="新建终端: " + made)
  assert_eq(remote_front_station(src), "ws1/st1")
  // (made on Willow and listed there at once: its row, under Willow's heading, its folder's name)
  assert_eq(made, "terminal term-9")
  assert_true(t.query(Link, label="app") is Some(_), msg="新建终端's row")
  assert_eq(@sfbase.remote_tabs_of(src, "ws1").0.length(), before + 1)
  remote_wide_clean(t, "新建终端")
  // Maple's ＋, 新建浏览器标签页: a new tab of Maple's browser shown, another tab
  t.click(Button, label="在 Maple 新建视图")
  t.run_for(@ui.move_most_ms)
  t.tap_text("新建浏览器标签页")
  t.run_for(@ui.move_most_ms)
  let tab = remote_front_now(src)
  assert_true(tab.has_prefix("screen browser:u_"), msg="新建浏览器标签页: " + tab)
  assert_eq(remote_front_station(src), "ws1/st2")
  // (made on Maple and listed there at once: a blank tab's row, under Maple's heading)
  assert_true(t.query(Link, label="新标签页") is Some(_), msg="新建浏览器标签页's row")
  assert_eq(@sfbase.remote_tabs_of(src, "ws1").0.length(), before + 2)
  assert_true(t.find("无法打开新标签页") is None, msg="the new tab made, nothing failed")
  remote_wide_clean(t, "新建浏览器标签页")
  // a mouse over a tab's row: its × at its top end
  match t.query(Link, label="收件箱 - Proton Mail") {
    Some(s) => {
      let (x, y, w, h) = s.rect
      t.move_to(x + w / 2.0, y + h / 2.0)
    }
    None => fail("the mail tab's row")
  }
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="关闭标签页 收件箱 - Proton Mail") is Some(_), msg="the row's ×")
  remote_wide_clean(t, "a row's ×")
  // a mouse over Maple's ＋: its ground, clear of the corners
  match t.query(Button, label="在 Maple 新建视图") {
    Some(s) => {
      let (x, y, w, h) = s.rect
      t.move_to(x + w / 2.0, y + h / 2.0)
    }
    None => fail("Maple's ＋")
  }
  t.run_for(@ui.move_most_ms)
  remote_wide_clean(t, "Maple's ＋ under the mouse")
}

///|
test "中屏 Place(\"remote\"): the stations' headings and their ＋ on the tape, a mouse's and a finger's, clear of the panel's corners" {
  for platform in [0, 2] {
    new_run()
    let src = fixture_app("place-remote-tabs")
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=900.0, h=720.0, platform~)
    t.run_for(first_page_ms + @ui.move_most_ms)
    let msg = "中屏 platform \{platform}"
    assert_true(app.nav.top() == Place("remote"), msg~)
    remote_side_heads(t, msg)
    remote_wide_clean(t, msg)
    t.click(Button, label="在 Willow 新建视图")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("新建终端") is Some(_), msg=msg + ": Willow's ＋ menu")
    remote_wide_clean(t, msg + ": Willow's ＋ menu")
    t.tap_text("新建终端")
    t.run_for(@ui.move_most_ms)
    assert_eq(remote_front_station(src), "ws1/st1", msg~)
    assert_true(remote_front_now(src).has_prefix("terminal "), msg=msg + ": " + remote_front_now(src))
    remote_wide_clean(t, msg + ": 新建终端")
  }
}

///|
test "大屏 Place(\"remote\"): the sidebar folded and shown a while over the page, its headings and their ＋ clear of its corners" {
  new_run()
  let src = fixture_app("place-remote-tabs")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=820.0, platform=0)
  t.run_for(first_page_ms + @ui.move_most_ms)
  @sfdesk.wide.folded.set(true)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.corner_faults(), [], msg="folded")
  @sfdesk.wide.peeking.set(true)
  // (the mouse kept over it, so it stays shown)
  t.move_to(150.0, 400.0)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfdesk.wide.peeking.get(), msg="shown a while")
  remote_side_heads(t, "shown a while")
  assert_eq(t.corner_faults(), [], msg="shown a while")
  assert_eq(t.first_line_faults(), [], msg="shown a while")
  // (the sidebar shown a while lies over the page beside it, whose own presses it covers there: the frame's, not 远程's;
  // two of 远程's own drawn over each other still are)
  let faults = remote_faults(t).filter(fn(f) {
    !f.has_prefix("apart: ") || f.split("stillfail/src/sfpages/remote_node.mbt").count() > 2
  })
  assert_eq(faults, [], msg="shown a while:\n" + faults.join("\n"))
}

///|
test "大屏 Place(\"remote\") with no tab opened: the list's first row shown and selected, kept once another is shown" {
  new_run()
  let src = fixture_app("place-remote")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=820.0, platform=0)
  t.run_for(first_page_ms + @ui.move_most_ms)
  assert_true(app.nav.top() == Place("remote"))
  assert_eq(@sfbase.remote_tabs_of(src, "ws1").0.length(), 0)
  // (the desktop's viewer at the pane's top: its 控制中心; no words of an empty workbench)
  assert_true(t.query(Button, label="控制中心") is Some(_), msg="the desktop shown")
  assert_true(t.find("从左侧打开桌面、浏览器或终端，或点选活跃会话") is None)
  remote_wide_clean(t, "first row")
  t.click(Link, label="iPhone 17 Pro")
  t.run_for(@ui.move_most_ms)
  assert_eq(remote_front_now(src), "screen sim:iphone")
  // (the desktop shown till then kept among the tabs, its screen covered, not let go)
  let kept = @sfbase.remote_tabs_of(src, "ws1").0.map(fn(p) { p.0 })
  assert_eq(kept.length(), 2, msg=kept.join(", "))
  // (wide simulator in 远程 workbench: unified Proposal C top bar, pure stage, collapsible 调试 drawer, zero layout/contrast/height faults)
  assert_true(t.query(Button, label="主屏幕") is Some(_), msg="simulator top-bar home button")
  assert_true(t.query(Button, label="旋转") is Some(_), msg="simulator top-bar rotate button")
  assert_true(t.query(Button, label="截图") is Some(_), msg="simulator top-bar screenshot button")
  assert_true(t.query(Button, label="展开右栏") is Some(_), msg="simulator top-bar 调试 toggle collapsed")
  assert_true(t.find("在设备里打开") is None, msg="debug drawer collapsed by default")
  assert_eq(t.height_faults(), [], msg="iPhone 17 Pro height faults")
  assert_eq(t.contrast_faults(), [], msg="iPhone 17 Pro contrast faults")
  remote_wide_clean(t, "iPhone 17 Pro")
  t.click(Button, label="展开右栏")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("在设备里打开") is Some(_), msg="debug drawer opened")
  assert_true(t.query(Button, label="收起右栏") is Some(_), msg="simulator top-bar 调试 toggle open")
  assert_eq(t.height_faults(), [], msg="iPhone 17 Pro drawer open height faults")
  assert_eq(t.contrast_faults(), [], msg="iPhone 17 Pro drawer open contrast faults")
  remote_wide_clean(t, "iPhone 17 Pro drawer open")
  t.click(Button, label="收起右栏")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("在设备里打开") is None, msg="debug drawer closed")
}

///|
test "对话内统一远程入口：顶栏打开统一菜单并支持在对话目录打开右侧栏终端" {
  let calls : Array[Made] = []
  let t = decide_core(calls, "chat-remote", wide=true)
  assert_true(t.query(Button, label="Station 屏幕") is Some(_))
  t.click(Button, label="Station 屏幕")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("Willow 的桌面") is Some(_))
  assert_true(t.find("在此对话目录打开终端") is Some(_))
  t.tap_text("在此对话目录打开终端")
  t.frame()
  t.frame()
  let opened = named(calls, "chat.tabs.open")
  assert_eq(opened.length(), 1)
  assert_true(text(Some(opened[0].params), "tab").has_prefix("terminal:[\"ws1/st1\",\"new\""))
}

///|
test "独立窗口参数编解码支持 Terminal 会话零重连移交" {
  let p = Page::Terminal({ station: "ws1/st1", terminal: "term-2", watch: false, cwd: "~/still.fail" })
  let encoded = @sfbase.window_text(p)
  assert_true(encoded is Some(_))
  assert_true(@sfbase.window_page(encoded.unwrap()) == Some(p))
}

///|
test "小屏下方栏: Profile stays in the first bar where it was; 远程 leads the second, the one in view on 远程's page" {
  fresh_app()
  let src = fixture_app("home")
  bars_picked.set(None)
  let (sets, cur) = @sfbase.bars_in(src, "ws1")
  assert_eq(sets[0], ["chats", "files", "profiles", "stations"])
  assert_eq(sets[1][0], "remote")
  assert_eq(cur, 0)
  // (远程 opened as from the second bar: that bar in view)
  fresh_app()
  let src = fixture_app("place-remote")
  let (sets, cur) = @sfbase.bars_in(src, "ws1")
  assert_eq(sets[1], ["remote", "archive", "usage", "connects"])
  assert_eq(cur, 1)
}

///|
test "设置 → 下方栏: 远程 among the places a bar can take" {
  assert_true(@settings.all_places.contains("remote"))
  let t = settings_tester("bars")
  bars_picked.set(None)
  let remotes = fn() { t.semantics().filter(fn(n) { n.label.contains("远程") }).length() }
  // (远程 already in the second bar's card: one more as the picker opens)
  let before = remotes()
  // (a new bar: every place offered, 远程 among them)
  t.tap_text("新建栏")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("添加到第 3 栏") is Some(_))
  assert_true(remotes() > before, msg="远程 offered")
}

///|
test "大屏切换会话时远程红点不闪烁：新会话 chat topic 未返回前保持上次状态，返回无 agent 后熄灭" {
  new_run()
  let driven = @signals.signal(true)
  let b_ready = @signals.signal(false)
  let base = fixture_app("chat")
  let patch_screens = fn(v : Json?) -> Json? {
    match v {
      Some(Object(o)) => {
        let out : Map[String, Json] = Map([])
        for k, val in o {
          out[k] = val
        }
        out["screens"] = Json::array([
          {
            "id": Json::string("browser:a1"),
            "kind": Json::string("browser"),
            "title": Json::string("Test Tab"),
            "line": Json::string(""),
            "agent": Json::boolean(driven.get()),
          },
        ])
        Some(Json::object(out))
      }
      other => other
    }
  }
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let topic = base.topic(name, params).get().snapshot()
      if name == "chat" {
        let sess = text(Some(Json::object(params)), "session")
        if sess == "s-c2" && !b_ready.get() {
          return { value: None, error: None, version: 0 }
        }
        return { ..topic, value: patch_screens(topic.value), version: topic.version + (if driven.get() { 1 } else { 2 }) }
      }
      topic
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=820.0, platform=0)
  t.run_for(first_page_ms + @ui.move_most_ms)
  let chat_a : @sfbase.ChatRef = { station: "ws1/st1", session: "s-c1", title: "Chat A", station_name: "Willow" }
  let chat_b : @sfbase.ChatRef = { station: "ws1/st1", session: "s-c2", title: "Chat B", station_name: "Willow" }
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.open_page(Chat(chat_a)) })
  t.frame()
  assert_true(@sfpages.remote_agent_lit(src, "ws1"), msg="lit on chat A")
  // Switch to chat B while its chat topic has not answered yet: dot must stay lit without flickering off.
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.open_page(Chat(chat_b)) })
  t.frame()
  assert_true(@sfpages.remote_agent_lit(src, "ws1"), msg="stays lit while chat B is loading")
  // Chat B answers with agent still driving: remains lit.
  b_ready.set(true)
  t.frame()
  assert_true(@sfpages.remote_agent_lit(src, "ws1"), msg="still lit once chat B answers")
  // Agent stops driving the screen: dot turns off.
  driven.set(false)
  t.frame()
  assert_false(@sfpages.remote_agent_lit(src, "ws1"), msg="turns off when agent stops driving")
}

///|
test "remote workbench and simulator keep zero new layout, corner, contrast, room and squeeze faults across all 7 windows in zh and en" {
  let modes = ["place-remote", "place-remote-tabs", "screen-live", "screen-simulator"]
  let wrong : Array[String] = []
  let check = fn(tag : String, faults : Array[String]) {
    if !faults.is_empty() {
      wrong.push("\{tag}: " + faults.join(" | "))
    }
  }
  for win in corner_windows {
    for lang in ["zh", "en"] {
      for mode in modes {
        let t = screen_in(mode, win, lang)
        let at = "\{win.0}-\{lang} \{mode}"
        check("dividers \{at}", edge_divider_faults(t))
        let corners = t.corner_faults()
        for f in t.lit_all_faults() {
          if !corners.contains(f) {
            corners.push(f)
          }
        }
        let known = if mode == "screen-simulator" && (win.0 == "touch" || win.0 == "desk-win") {
          1
        } else {
          corners_everywhere_known.get(at).unwrap_or(0)
        }
        if corners.length() != known {
          wrong.push("corners \{at}: \{corners.length()} vs \{known} known | " + corners.join(" | "))
        }
        check("gaps \{at}", t.gap_faults())
        check("hand_moves \{at}", t.hand_moves())
        check("heights \{at}", t.height_faults())
        check("first_line \{at}", t.first_line_faults())
        check("line_start \{at}", t.line_start_faults())
        check("outgrown \{at}", t.fixed_outgrown())
        if squeeze_windows.contains(win.0) && !(mode == "screen-simulator" && (win.0 == "phone" || win.0 == "tablet")) {
          check("squeeze \{at}", t.squeeze_faults())
        }
        if lang == "zh" {
          check("rooms \{at}", t.room_faults())
          check("hover_only \{at}", t.hover_only_faults())
          check("contrast \{at}", t.contrast_faults())
        }
      }
    }
  }
  if !wrong.is_empty() {
    fail(wrong.join("\n"))
  }
}
