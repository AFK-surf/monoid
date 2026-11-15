// A chat's own tabs beside it on 中屏 (the tape's panel, tape_side_node) and 大屏 (beside the page, side_panel_node),
// made as nodes of the window's tree (sfdesk's jobs_tab_node, letters_tab_node; sfpages' things_node): 任务's list,
// a job picked and its output, a service opening its own tab; agent 往来's chats, one opened and back; 图片、文件和链接's
// kinds, chosen here and by things_choose; and on the tape a Farview tab, its screen (side_farview_node), not an
// agent's history.

///|
/// 大屏 beside the page, 中屏 the tape's panel (corners_wbtest's windows).
let side_tab_windows : Array[(String, Double, Double, Int, String)] = [
  ("wide", 1280.0, 800.0, 0, ""),
  ("medium", 800.0, 800.0, 0, ""),
]

///|
let side_tab_chat : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }

///|
/// The fixture's chat in `mode` open in window `win`, its side panel the one in use (on the tape, what shows of it at the
/// window's right tapped till it comes over: from the sidebar the page, then the panel).
fn side_tab_at(mode : String, win : (String, Double, Double, Int, String)) -> @ui.Tester raise {
  let t = screen_in(mode, win, "zh")
  if @sf.layout(win.1) is Medium {
    for _ in 0..<2 {
      if @sfdesk.wide.tape_at.get() != @sfdesk.TapePane::Panel {
        t.tap(win.1 - @sfdesk.tape_shows / 2.0, 400.0)
        t.run_for(@ui.move_most_ms)
      }
    }
    assert_eq(@sfdesk.wide.tape_at.get(), @sfdesk.TapePane::Panel)
  }
  t
}

///|
/// What the audit finds of the tabs' own nodes (their edge drawn over the panel's column, as every panel's: none of theirs).
fn side_tab_faults(t : @ui.Tester) -> Array[String] {
  t
  .audit()
  .filter(fn(f) {
    (f.contains("jobs_tab_node") || f.contains("sfdesk/letters.mbt") || f.contains("sfpages/things.mbt") || f.contains("message_static_node")) &&
    !f.contains("edge_node.mbt")
  })
}

///|
test "中屏, 大屏: 任务 beside the chat, nodes: its services and jobs, the job picked's notices; 输出 its output; a service pressed opens its own tab" {
  for win in side_tab_windows {
    let t = side_tab_at("chat-jobs-side", win)
    assert_eq(side_tab_faults(t), [], msg=win.0)
    for w in ["服务", "web", "后台任务", "在盯着 · 第 3 步通过", "gh run watch 4821 --exit-status", "第 3 步通过：单元测试全部通过", "… waiting for deploy"] {
      assert_true(t.find(w) is Some(_), msg="\{win.0}: \{w}")
    }
    t.tap_text("输出")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("第 3 步通过：单元测试全部通过") is None, msg="\{win.0}: its notices gone")
    assert_eq(side_tab_faults(t), [], msg="\{win.0}: its output")
    t.tap_text("通知")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("第 3 步通过：单元测试全部通过") is Some(_), msg="\{win.0}: its notices again")
    t.tap_text("web")
    t.run_for(@ui.move_most_ms)
    assert_true(side_now(side_tab_chat).0.contains("service:j-web"), msg="\{win.0}: \{Repr(side_now(side_tab_chat))}")
  }
}

///|
test "中屏, 大屏: agent 往来 beside the chat, nodes: the chats written with; one pressed opens its letters under its title; back to the list" {
  for win in side_tab_windows {
    let t = side_tab_at("chat-letters-side", win)
    assert_eq(side_tab_faults(t), [], msg=win.0)
    assert_true(t.find("接手监督 mbui") is Some(_), msg=win.0)
    assert_true(t.find("3 条 · 5 分钟前") is Some(_), msg=win.0)
    t.tap_text("BFT 备份尺寸分析")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("接手监督 mbui") is None, msg="\{win.0}: the list gone")
    assert_true(t.find("BFT 备份尺寸分析") is Some(_), msg="\{win.0}: its title")
    assert_true(t.find("补充一点：系统自带的 tar 能直接解 zstd") is Some(_), msg="\{win.0}: its letters")
    assert_eq(side_tab_faults(t), [], msg="\{win.0}: opened")
    t.click(Button, label=@sf.t("web-main.letters.back"))
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("接手监督 mbui") is Some(_), msg="\{win.0}: the list again")
  }
}

///|
test "中屏, 大屏: 图片、文件和链接 beside the chat, nodes: its pictures by the day; 文件 pressed its files; another chosen by things_choose as it shows" {
  for win in side_tab_windows {
    let t = side_tab_at("chat-things-side", win)
    assert_eq(side_tab_faults(t), [], msg=win.0)
    assert_true(t.find("列表高度改前改后") is Some(_), msg="\{win.0}: its pictures")
    t.tap_text("文件 2")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("build.log") is Some(_), msg="\{win.0}: its files")
    assert_true(t.find("列表高度改前改后") is None, msg="\{win.0}: its pictures gone")
    assert_eq(side_tab_faults(t), [], msg="\{win.0}: its files")
    // (its info's 全部 N 个: its pull requests, told as it shows)
    @sfpages.things_choose(side_tab_chat, "pulls")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("build.log") is None, msg="\{win.0}: its files gone")
    assert_true(t.find("首页列表按天分组") is Some(_), msg="\{win.0}: its pull requests")
  }
}

///|
test "中屏: a Farview tab on the tape's panel is its screen drawn here, not an agent's history" {
  let t = side_tab_at("chat-jobs-side", side_tab_windows[1])
  let tab = "screen:" + Json::array([Json::string("ws1/st1"), Json::string("browser:fv_t1")]).stringify()
  side_change(side_tab_chat, "open", Some(tab))
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(side_tab_chat).1, tab)
  assert_true(t.find("只看收发") is None, msg="no history's head")
  // (the panel's body under its bar: the tab's screen, Farview's bar over its stage)
  assert_true(t.query(Button, label=@sf.t("web-pages.screen.reloadShort")) is Some(_), msg="its screen's bar")
}
