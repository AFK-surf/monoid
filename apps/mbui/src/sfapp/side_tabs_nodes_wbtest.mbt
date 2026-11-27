// A chat's own tabs beside it on 中屏 (the tape's panel, tape_side_node) and 大屏 (beside the page, side_panel_node),
// made as nodes of the window's tree (sfdesk's jobs_tab_node, letters_tab_node; sfpages' things_node): 任务's list,
// a job picked and its output, a service opening its own tab; agent 往来's chats, one opened and back; 图片、文件和链接's
// kinds, chosen here and by things_choose; 文件 and a station's 文件 (sfdesk's drive_tab_node.mbt), a folder gone into,
// a file picked and added to the draft, back to the places; and a station's page (sfpages' station_node).

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
/// The panel's tabs as a screen reader has them (their bar's: side_bar_node), each its name, whether it is in front,
/// and where it is.
fn side_tabs_said(t : @ui.Tester) -> Array[(String, Bool, (Double, Double, Double, Double))] {
  t.semantics().filter(fn(s) { s.role == @ui.Role::Tab && !s.hidden }).map(fn(s) { (s.label, s.selected == Some(true), s.rect) })
}

///|
test "大屏: the panel's bar, nodes: a tab pressed comes in front; one's × closes it alone, the one in front staying; its empty part drags the window" {
  // (a Mac's window: no title bar of the system's, the app's top row moving it)
  let t = wide_tester([], mode="chat-tabs-side", window_inset=true)
  t.run_for(@ui.move_most_ms)
  let tabs = side_tabs_said(t)
  assert_eq(tabs.length(), 2, msg="\{Repr(tabs)}")
  assert_eq(side_now(side_tab_chat), (["s-c1", "jobs"], "jobs"))
  let (agent, agent_front, (ax, ay, _, ah)) = tabs[0]
  assert_true(!agent_front && tabs[1].1, msg="\{Repr(tabs)}")
  // (pressed: in front)
  t.tap(ax + 16.0, ay + ah / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(side_tab_chat).1, "s-c1")
  assert_eq(side_tabs_said(t).map(fn(x) { (x.0, x.1) }), [(agent, true), (tabs[1].0, false)])
  // (任务's × behind: revealed on hover, it closes, the agent's history staying in front)
  let (jx, jy, jw, jh) = side_tabs_said(t)[1].2
  t.move_to(jx + jw / 2.0, jy + jh / 2.0)
  t.draw()
  let x = t.get(Button, label=@sf.t("web-pages.chat.closeJobs")).rect
  t.tap(x.0 + x.2 / 2.0, x.1 + x.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(side_tab_chat), (["s-c1"], "s-c1"))
  assert_eq(side_tabs_said(t).map(fn(x) { (x.0, x.1) }), [(agent, true)])
  // (its empty part, past the tabs, before the panel's switch: the window's)
  let close_panel = t.get(Button, label=@sf.t("web-pages.chat.closePanel")).rect
  let (bx, _, bw, _) = side_tabs_said(t)[0].2
  let empty = (bx + bw + close_panel.0) / 2.0
  assert_true(t.drags_window_at(empty, ay + ah / 2.0), msg="the bar's empty part at \{empty}")
  assert_true(!t.drags_window_at(ax + 16.0, ay + ah / 2.0), msg="a tab")
  assert_true(!t.drags_window_at(close_panel.0 + close_panel.2 / 2.0, close_panel.1 + close_panel.3 / 2.0), msg="the switch")
}

///|
test "中屏: on the tape's panel a tab alone is its bar's title, a heading with no × of its own, the bar's close its only one; two are tabs, each its own ×" {
  let t = side_tab_at("chat-history-side", side_tab_windows[1])
  assert_eq(side_tabs_said(t), [])
  assert_eq(side_now(side_tab_chat).0.length(), 1)
  assert_true(t.query(Heading, label="Claude · Opus 5.5") is Some(_), msg="its title")
  assert_true(t.semantics().filter(fn(s) { s.role == @ui.Role::Button && s.label.has_prefix("关闭") && !s.hidden }).length() == 0, msg="no tab's ×")
  t.click(Button, label=@sf.t("web-pages.chat.closePanel"))
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(side_tab_chat).0, [])
  let t = side_tab_at("chat-tabs-side", side_tab_windows[1])
  assert_eq(side_tabs_said(t).length(), 2)
  assert_true(t.query(Button, label=@sf.t("web-pages.chat.closeJobs")) is Some(_), msg="任务's ×")
}

///|
/// `words` tapped where they are furthest right (in the panel, not the chat's or the sidebar's).
fn side_tap_rightmost(t : @ui.Tester, words : String) -> Unit {
  let at = t.locate(words)
  guard at.length() > 0 else { @halt.saying("no \{words}") }
  let mut best = at[0]
  for p in at {
    if p.0 > best.0 {
      best = p
    }
  }
  t.tap(best.0, best.1)
}

///|
/// What the audit finds of 文件's and a station's page's own nodes beside the chat (their edge drawn over the panel's
/// column, as every panel's: none of theirs).
fn side_files_faults(t : @ui.Tester) -> Array[String] {
  t
  .audit()
  .filter(fn(f) {
    (f.contains("drive_tab_node") || f.contains("drive_row_node") || f.contains("drive_views_node") || f.contains("station_node")) &&
    !f.contains("edge_node.mbt")
  })
}

///|
test "中屏, 大屏: 文件 beside the chat, nodes: its station's home, a folder gone into and starred (lit at rest), a file pressed picked, 添加 1 个 puts it into the draft; the trail's station back to the places" {
  for win in side_tab_windows {
    let t = side_tab_at("chat-files-side", win)
    assert_eq(side_files_faults(t), [], msg=win.0)
    for w in ["整个文件夹", "下载", "文档", "项目"] {
      assert_true(t.find(w) is Some(_), msg="\{win.0}: \{w}")
    }
    side_tap_rightmost(t, "文档")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("说明.txt") is Some(_), msg="\{win.0}: 文档's files")
    assert_true(t.find("下载") is None, msg="\{win.0}: the home's gone")
    // (the folder starred: its star lit at rest, the pointer gone from it, as the old tab's lit button)
    // (the fixture's 文档 kept at hand already: lit; taken off, quiet; kept again, lit)
    assert_eq(side_star_lit(t, "从个人收藏移除「文档」"), true, msg="\{win.0}: starred, lit at rest")
    t.click(Button, label="从个人收藏移除「文档」")
    t.move_to(10.0, win.2 - 10.0)
    t.run_for(@ui.move_most_ms)
    assert_eq(side_star_lit(t, "把「文档」加入个人收藏"), false, msg="\{win.0}: not starred, quiet")
    t.click(Button, label="把「文档」加入个人收藏")
    t.move_to(10.0, win.2 - 10.0)
    t.run_for(@ui.move_most_ms)
    assert_eq(side_star_lit(t, "从个人收藏移除「文档」"), true, msg="\{win.0}: starred again, lit at rest")
    side_tap_rightmost(t, "说明.txt")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("添加 1 个") is Some(_), msg="\{win.0}: picked")
    assert_eq(side_files_faults(t), [], msg="\{win.0}: a file picked")
    side_tap_rightmost(t, "添加 1 个")
    t.run_for(@ui.move_most_ms)
    assert_true(draft_files().contains("说明.txt"), msg="\{win.0}: \{draft_files()}")
    assert_true(t.find("添加 1 个") is None, msg="\{win.0}: the picks let go")
    side_tap_rightmost(t, "Willow")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("整个文件夹") is None, msg="\{win.0}: the places")
    assert_eq(side_files_faults(t), [], msg="\{win.0}: the places")
  }
}

///|
test "中屏, 大屏: a station's 文件 and its page beside the chat, nodes: its home's folders; its page's head and parts, laid out by the panel's width, 设置 pressed" {
  for win in side_tab_windows {
    let t = side_tab_at("chat-drive-side", win)
    assert_eq(side_files_faults(t), [], msg=win.0)
    assert_true(t.find("文档") is Some(_), msg="\{win.0}: its home's folders")
    let t = side_tab_at("chat-station-side", win)
    assert_eq(side_files_faults(t), [], msg=win.0)
    assert_true(t.find("概览") is Some(_), msg="\{win.0}: its parts")
    // (laid out by the panel's width, as page_node's look has it: 大屏's panel narrow, a section's heading alone; the
    // tape's wide, a section's box of its own made where the page asks for it, section_node's wide way)
    // (its words' own place, the first of what sources_of says)
    let asked = t.sources_of("资源").split("\n").next().map(fn(l) { l.to_owned() }).unwrap_or("")
    let wide_section = asked.contains("sfpages/station_node.mbt")
    assert_eq(wide_section, win.0 == "medium", msg="\{win.0}: \{asked}")
    side_tap_rightmost(t, "设置")
    t.run_for(@ui.move_most_ms)
    assert_eq(side_files_faults(t), [], msg="\{win.0}: 设置")
  }
}

///|
/// Whether the button named `label` is drawn lit at rest: its ground the accent's lit tint (icon_button_node's `on`).
fn side_star_lit(t : @ui.Tester, label : String) -> Bool {
  guard t.query(Button, label~) is Some(n) else { return false }
  let (x, y, w, h) = n.rect
  let lit = @sf.alpha(@sf.theme().p.accent, 0.08)
  t.drawn_rects().iter().any(fn(r) { (r.0 - x).abs() < 1.0 && (r.1 - y).abs() < 1.0 && (r.2 - w).abs() < 1.0 && (r.3 - h).abs() < 1.0 && r.4 == lit })
}

///|
/// Overlay local `chat.tabs.*` state onto `base` so side-panel tab tests can open/switch/close arbitrary tabs
/// without needing `sfkept` entries for every combination.
fn with_local_side_tabs(
  base : Source,
  initial : (Array[String], String),
  live_ready? : @signals.Signal[Bool],
) -> Source {
  let tabs_sig : @signals.Signal[(Array[String], String)] = @signals.signal(initial)
  let tabs_ver : @signals.Signal[Int] = @signals.signal(0)
  {
    ..base,
    topic_read: fn(name, params) {
      match live_ready {
        Some(ready) if (name == "history" || name == "drive") && !ready.get() =>
          return { value: None, error: None, version: 0 }
        _ => ()
      }
      let st = (base.topic_read)(name, params)
      if name == "chat" {
        let (open, shown) = tabs_sig.get()
        let ver = tabs_ver.get()
        match st.value {
          Some(Object(m)) => {
            let copy : Map[String, Json] = Map([])
            for k, v in m {
              copy[k] = v
            }
            copy["tabs"] = Json::object({
              "open": Json::array(open.map(Json::string)),
              "shown": if shown == "" { Json::null() } else { Json::string(shown) },
              "canReopen": Json::boolean(false),
            })
            { ..st, value: Some(Json::object(copy)), version: st.version + ver }
          }
          _ => st
        }
      } else {
        st
      }
    },
    call: fn(name, params, on_done) {
      if name.has_prefix("chat.tabs.") {
        let act = name.exact_view(start="chat.tabs.".length()).to_owned()
        let tab = match params {
          Object(m) =>
            match m.get("tab") {
              Some(String(t)) => t
              _ => ""
            }
          _ => ""
        }
        let (cur_open, cur_shown) = tabs_sig.untracked()
        let next : (Array[String], String) = match act {
          "open" if tab != "" =>
            if cur_open.contains(tab) {
              (cur_open, tab)
            } else {
              ([..cur_open, tab], tab)
            }
          "front" if tab != "" => (cur_open, tab)
          "close" if tab != "" => {
            let rest = cur_open.filter(fn(x) { x != tab })
            let next_shown = if cur_shown == tab { rest.get(0).unwrap_or("") } else { cur_shown }
            (rest, next_shown)
          }
          "clear" => ([], "")
          _ => (cur_open, cur_shown)
        }
        tabs_sig.set(next)
        tabs_ver.set(tabs_ver.untracked() + 1)
        on_done(Ok(Json::null()))
      } else {
        (base.call)(name, params, on_done)
      }
    },
  }
}

///|
/// Open a wide 1280x800 Tester on `mode` with `side_tab_chat` active, returning `(tester, source)`.
fn side_kept_tester(
  mode? : String = "chat-tabs-side",
  a11y? : Bool = false,
  live_ready? : @signals.Signal[Bool],
) -> (@ui.Tester, Source) {
  new_run()
  let src = with_local_side_tabs(fixture(mode), (["s-c1", "jobs"], "jobs"), live_ready?)
  open_chat(side_tab_chat)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0, env=[("MBUI_LOCALE", "zh")])
  if a11y {
    t.set_a11y(true)
  }
  nav_rested(t)
  t.run_for(@ui.move_most_ms)
  (t, src)
}

///|
/// Run `act` inside a tree event, advance `ms` ms, and return `(sum_made, sum_let_go)`.
fn side_kept_step(t : @ui.Tester, act : () -> Unit, ms? : Double = @ui.move_most_ms) -> (Int, Int) {
  t.tree_frames_from_now()
  @ui.view_tree().unwrap().event(t.time(), act)
  t.run_for(ms)
  t.tree_frames().fold(init=(0, 0), fn(a, f) { (a.0 + f.made, a.1 + f.let_go) })
}

///|
test "大屏: side_panel_node parks passive tabs (history/jobs/files/letters/things) via pick_kept with 0 body rebuilds, 0 parked timers, a11y isolation, and full cleanup" {
  let (t, src) = side_kept_tester(mode="chat-letters-side", a11y=true)
  let tree = @ui.view_tree().unwrap()
  // Open remaining passive tabs: s-c1 (cold), files, letters, things (files sub-tab to stay under 4 KB image bar), then jobs.
  @sfpages.things_choose(side_tab_chat, "files")
  let (cold_hist_made, _) = side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "s-c1") })
  let (cold_files_made, _) = side_kept_step(t, fn() { @sfdesk.side_change(src, side_tab_chat, "open", Some("files")) })
  let (cold_letters_made, _) = side_kept_step(t, fn() { @sfdesk.side_change(src, side_tab_chat, "open", Some("letters")) })
  let (cold_things_made, _) = side_kept_step(t, fn() { @sfdesk.side_change(src, side_tab_chat, "open", Some("things")) })
  side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "jobs") }) |> ignore
  assert_true(cold_hist_made > 20 && cold_files_made > 20 && cold_letters_made > 20 && cold_things_made > 20, msg="cold opens build tab bodies")
  assert_true(t.find("后台任务") is Some(_), msg="jobs active after cold opens")
  assert_true(t.at_rest(), msg="at rest after cold opens")
  assert_eq(tree.due_count(), t.subtree_timeline_count(tree.root()), msg="0 parked timers after cold opens")
  // Hot-switch across all 5 passive tabs via side_front_pressed: body builds 0 nodes (at most tab_strip × toggle <= 6 nodes).
  let checks : Array[(String, String, String)] = [
    ("s-c1", "读了 src/ui/list.mbt 等 2 个文件，跑了测试", "后台任务"),
    ("files", "整个文件夹", "读了 src/ui/list.mbt 等 2 个文件，跑了测试"),
    ("letters", "接手监督 mbui", "整个文件夹"),
    ("things", "build.log", "接手监督 mbui"),
    ("jobs", "后台任务", "build.log"),
  ]
  for entry in checks {
    let (tab, visible_word, parked_word) = entry
    let (made, let_go) = side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, tab) })
    println("side_panel_kept hot \{tab}: made=\{made} let_go=\{let_go}")
    // Only tab_strip_node's active × button mounts/unmounts (<= 6 nodes); the tab body itself builds 0 nodes.
    assert_true(made <= 6 && let_go <= 6, msg="hot return to passive tab \{tab} must not rebuild body (made=\{made}, let_go=\{let_go})")
    assert_true(t.find(visible_word) is Some(_), msg="active tab \{tab} shows \{visible_word}")
    assert_true(t.find(parked_word) is None, msg="parked tab content \{parked_word} must not be drawn")
    // A11y isolation: parked tab's unique label must not appear in visible semantics.
    let leaked_a11y = t.semantics().iter().any(fn(s) { !s.hidden && s.label.contains(parked_word) })
    assert_false(leaked_a11y, msg="parked tab \{parked_word} must not leak into visible semantics")
    assert_false(
      @sfbase.shown_handed(@sfdesk.side_tab_shown_at(side_tab_chat, tab)),
      msg="ahead-read for \{tab} must be released on hot return",
    )
    assert_true(t.at_rest(), msg="at_rest after hot return to \{tab}")
    assert_eq(
      tree.due_count(),
      t.subtree_timeline_count(tree.root()),
      msg="0 parked timers after hot return to \{tab}",
    )
  }
  // Closing a single passive tab drops its branch rather than parking it.
  let (_, close_let_go) = side_kept_step(t, fn() { @sfdesk.side_change(src, side_tab_chat, "close", Some("jobs")) })
  assert_true(close_let_go > 10, msg="closing active passive tab jobs must drop its body (let_go=\{close_let_go})")
  assert_eq(tree.due_count(), t.subtree_timeline_count(tree.root()), msg="0 parked timers after closing jobs")
  // Closing the entire panel disposes all remaining parked passive tabs.
  t.set_a11y(false)
  let (_, clear_let_go) = side_kept_step(t, fn() { @sfdesk.side_change(src, side_tab_chat, "clear", None) })
  assert_true(clear_let_go > 50, msg="clearing panel must dispose all parked passive tabs (let_go=\{clear_let_go})")
  assert_eq(tree.due_count(), t.subtree_timeline_count(tree.root()), msg="0 parked timers after clearing panel")
}

///|
test "大屏: side_panel_node on_take preserves 140ms directional slide+fade animation without jump or residual timers" {
  let side_tab_enter_ms = 140.0
  let quarter_enter_ms = side_tab_enter_ms / 4.0
  let (t, src) = side_kept_tester(mode="chat-tabs-side")
  let tree = @ui.view_tree().unwrap()
  // Cold-open s-c1 (index 0) and jobs (index 1) so both are in the pick_kept pool.
  side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "s-c1") }) |> ignore
  let hist_rest_x = t.find("读了 src/ui/list.mbt 等 2 个文件，跑了测试").unwrap().0
  side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "jobs") }) |> ignore
  let jobs_rest_x = t.find("后台任务").unwrap().0
  assert_true(t.at_rest(), msg="settled on jobs before hot-return animation check")
  // 1. Hot-return right-to-left: jobs (idx 1) -> s-c1 (idx 0), dir = -1.0 (starts shifted left by -8px at t=0).
  t.tree_frames_from_now()
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "s-c1") })
  t.draw()
  assert_false(t.at_rest(), msg="on_take 140ms transition must be running at t=0")
  let hist_t0_x = t.find("读了 src/ui/list.mbt 等 2 个文件，跑了测试").unwrap().0
  assert_true(
    (hist_t0_x - (hist_rest_x - 8.0)).abs() < 1.0,
    msg="leftward hot return must start at -8px on t=0 frame (t0=\{hist_t0_x}, rest=\{hist_rest_x})",
  )
  t.run_for(quarter_enter_ms)
  let hist_mid_x = t.find("读了 src/ui/list.mbt 等 2 个文件，跑了测试").unwrap().0
  assert_true(
    hist_mid_x < hist_rest_x - 0.5 && hist_mid_x > hist_t0_x,
    msg="leftward hot return must advance smoothly from -8px toward rest (t0=\{hist_t0_x}, mid=\{hist_mid_x}, rest=\{hist_rest_x})",
  )
  t.run_for(@ui.move_most_ms)
  let hist_end_x = t.find("读了 src/ui/list.mbt 等 2 个文件，跑了测试").unwrap().0
  assert_true((hist_end_x - hist_rest_x).abs() < 0.5, msg="landed at rest x (end=\{hist_end_x}, rest=\{hist_rest_x})")
  let made_left = t.tree_frames().fold(init=0, fn(n, f) { n + f.made })
  assert_true(made_left <= 6, msg="leftward hot return must not rebuild body (made=\{made_left})")
  assert_true(t.at_rest(), msg="at rest after leftward 140ms transition")
  assert_eq(tree.due_count(), t.subtree_timeline_count(tree.root()), msg="0 residual timers after leftward transition")
  // 2. Hot-return left-to-right: s-c1 (idx 0) -> jobs (idx 1), dir = +1.0 (starts shifted right by +8px at t=0).
  t.tree_frames_from_now()
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "jobs") })
  t.draw()
  assert_false(t.at_rest(), msg="on_take 140ms transition must be running at t=0 (rightward)")
  let jobs_t0_x = t.find("后台任务").unwrap().0
  assert_true(
    (jobs_t0_x - (jobs_rest_x + 8.0)).abs() < 1.0,
    msg="rightward hot return must start at +8px on t=0 frame (t0=\{jobs_t0_x}, rest=\{jobs_rest_x})",
  )
  t.run_for(quarter_enter_ms)
  let jobs_mid_x = t.find("后台任务").unwrap().0
  assert_true(
    jobs_mid_x > jobs_rest_x + 0.5 && jobs_mid_x < jobs_t0_x,
    msg="rightward hot return must advance smoothly from +8px toward rest (t0=\{jobs_t0_x}, mid=\{jobs_mid_x}, rest=\{jobs_rest_x})",
  )
  t.run_for(@ui.move_most_ms)
  let jobs_end_x = t.find("后台任务").unwrap().0
  assert_true((jobs_end_x - jobs_rest_x).abs() < 0.5, msg="landed at rest x (end=\{jobs_end_x}, rest=\{jobs_rest_x})")
  let made_right = t.tree_frames().fold(init=0, fn(n, f) { n + f.made })
  assert_true(made_right <= 6, msg="rightward hot return must not rebuild body (made=\{made_right})")
  assert_true(t.at_rest(), msg="at rest after rightward 140ms transition")
  assert_eq(tree.due_count(), t.subtree_timeline_count(tree.root()), msg="0 residual timers after rightward transition")
  // 3. Mid-transition interruption: switch away at t=35ms while 140ms way is still running -> on_rest cancels it immediately (0 parked timers).
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "s-c1") })
  t.draw()
  t.run_for(quarter_enter_ms)
  assert_false(t.at_rest(), msg="s-c1 transition still in flight at t=35ms before interruption")
  let due_mid = tree.due_count()
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "jobs") })
  t.draw()
  assert_false(t.at_rest(), msg="jobs transition still in flight right after interrupting s-c1")
  let jobs_interrupt_t0_x = t.find("后台任务").unwrap().0
  assert_true(
    (jobs_interrupt_t0_x - (jobs_rest_x + 8.0)).abs() < 1.0,
    msg="interrupted switch to jobs must start cleanly at +8px (t0=\{jobs_interrupt_t0_x}, rest=\{jobs_rest_x})",
  )
  // Tree::hand_at_end keeps one unowned hover-recheck entry for s-c1's original deadline until t0+140ms,
  // so cancelling s-c1's NodeWay on park yields due_mid + 1 (not due_mid + 2).
  assert_eq(
    tree.due_count(),
    due_mid + 1,
    msg="interrupting s-c1 mid-transition must cancel its NodeWay on park (due=\{tree.due_count()}, due_mid=\{due_mid})",
  )
  t.run_for(@ui.move_most_ms)
  assert_true(t.at_rest(), msg="at rest after mid-transition interruption")
  assert_eq(tree.due_count(), t.subtree_timeline_count(tree.root()), msg="0 residual timers after interruption")
}

///|
test "大屏: side_panel_node drops external-resource tabs (view_tab_file/service/screen/terminal) on leave and hands off tab_full cleanly" {
  let (t, src) = side_kept_tester(mode="chat-tabs-side")
  // 1. view_tab_file: open 说明.md beside, switch away -> dropped (not parked), revisit -> rebuilt, fullscreen handoff succeeds.
  let md = @sffixture.preview_files().iter().find_first(fn(f) { f.0.name == "说明.md" }).unwrap().0
  side_kept_step(t, fn() { @sfbase.open_preview("ws1/st1", "s-c1", md, beside=true) }) |> ignore
  let view_tab = @sfdesk.side_now(src, side_tab_chat).1
  assert_true(@sfbase.view_tab_file(view_tab) is Some(_), msg="view_tab_file active")
  let (_, view_leave_lg) = side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "jobs") })
  assert_true(view_leave_lg > 10, msg="leaving view_tab_file must drop it rather than parking (let_go=\{view_leave_lg})")
  let (view_back_made, _) = side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, view_tab) })
  assert_true(view_back_made > 10, msg="revisiting unparked view_tab_file must rebuild (made=\{view_back_made})")
  // Fullscreen handoff via tab_full: held_beside must clear immediately without deadlock.
  side_kept_step(t, fn() { @sfbase.tab_full_open(side_tab_chat, view_tab) }) |> ignore
  assert_true(@sfbase.tab_full_is("ws1/st1", "s-c1", view_tab), msg="view_tab_file opened fullscreen")
  assert_true(t.query(Button, label=@sf.t("web-main.preview.moveBeside")) is Some(_), msg="fullscreen bar mounted (no held_beside deadlock)")
  side_kept_step(t, fn() { @sfbase.tab_full_beside() }) |> ignore
  assert_true(@sfbase.tab_full.untracked() is None, msg="moved back beside cleanly")
  // 2. service tab: switch away -> dropped, revisit -> rebuilt, fullscreen handoff succeeds.
  side_kept_step(t, fn() { @sfdesk.side_change(src, side_tab_chat, "open", Some("service:j-web")) }) |> ignore
  let (_, svc_leave_lg) = side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "jobs") })
  assert_true(svc_leave_lg > 10, msg="leaving service tab must drop it (let_go=\{svc_leave_lg})")
  let (svc_back_made, _) = side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "service:j-web") })
  assert_true(svc_back_made > 10, msg="revisiting unparked service tab must rebuild (made=\{svc_back_made})")
  side_kept_step(t, fn() { @sfbase.tab_full_open(side_tab_chat, "service:j-web") }) |> ignore
  assert_true(t.query(Button, label=@sf.t("web-main.preview.moveBeside")) is Some(_), msg="service fullscreen mounted (no deadlock)")
  side_kept_step(t, fn() { @sfbase.tab_full_beside() }) |> ignore
  // 3. screen tab: switch away -> dropped, revisit -> rebuilt.
  side_kept_step(t, fn() {
    @sfdesk.station_page_beside(src, side_tab_chat, Screen({ station: "ws1/st1", screen: "display", title: "Display", until_gone: false })) |> ignore
  }) |> ignore
  let screen_tab = @sfdesk.side_now(src, side_tab_chat).1
  let (_, scr_leave_lg) = side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "jobs") })
  assert_true(scr_leave_lg > 10, msg="leaving screen tab must drop it (let_go=\{scr_leave_lg})")
  let (scr_back_made, _) = side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, screen_tab) })
  assert_true(scr_back_made > 10, msg="revisiting unparked screen tab must rebuild (made=\{scr_back_made})")
  // 4. terminal tab: switch away -> dropped, revisit -> rebuilt.
  side_kept_step(t, fn() {
    @sfdesk.station_page_beside(src, side_tab_chat, Terminal({ station: "ws1/st1", terminal: "term-1", watch: false, cwd: "" })) |> ignore
  }) |> ignore
  let term_tab = @sfdesk.side_now(src, side_tab_chat).1
  let (_, term_leave_lg) = side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "jobs") })
  assert_true(term_leave_lg > 10, msg="leaving terminal tab must drop it (let_go=\{term_leave_lg})")
  let (term_back_made, _) = side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, term_tab) })
  assert_true(term_back_made > 10, msg="revisiting unparked terminal tab must rebuild (made=\{term_back_made})")
  // 5. Closing a background parked passive tab (`files`) and reopening it must rebuild fresh (never reuse old parked branch).
  side_kept_step(t, fn() { @sfdesk.side_change(src, side_tab_chat, "open", Some("files")) }) |> ignore
  side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "jobs") }) |> ignore
  side_kept_step(t, fn() { @sfdesk.side_change(src, side_tab_chat, "close", Some("files")) }) |> ignore
  let (files_reopen_made, _) = side_kept_step(t, fn() { @sfdesk.side_change(src, side_tab_chat, "open", Some("files")) })
  assert_true(
    files_reopen_made > 20,
    msg="reopening a previously closed background-parked tab must rebuild fresh (made=\{files_reopen_made})",
  )
  // 6. Moving a parked passive `history` tab (`s-c1`) into a standalone window (`window_has_tab`) and returning it
  // to the side panel must rebuild fresh rather than reusing the old parked branch.
  t.set_window_opens(true)
  t.set_windows_in_process(true)
  side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "s-c1") }) |> ignore
  side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "jobs") }) |> ignore
  let opened_win = @sfbase.open_window(SideTab({ chat: side_tab_chat, tab: "s-c1" }))
  assert_true(opened_win, msg="s-c1 opened in standalone window")
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.window_has_tab("ws1/st1", "s-c1", "s-c1"), msg="window_has_tab true for s-c1")
  let (wid, _) = t.windows_beside()[0]
  @sfbase.window_gives_back(wid)
  t.close_window_beside(wid)
  t.run_for(@ui.move_most_ms)
  assert_false(@sfbase.window_has_tab("ws1/st1", "s-c1", "s-c1"), msg="window_has_tab cleared after return")
  let (hist_reopen_made, _) = side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "s-c1") })
  assert_true(
    hist_reopen_made > 20,
    msg="returning parked s-c1 from standalone window must rebuild fresh (made=\{hist_reopen_made})",
  )
}

///|
test "大屏: parked passive live tabs preserve #7344 history continuity and never draw stale drive entries while awaiting Core" {
  let live_ready : @signals.Signal[Bool] = @signals.signal(true)
  let (t, src) = side_kept_tester(mode="chat-tabs-side", live_ready~)
  // Populate both live tabs (history + files) while live_ready == true.
  side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "s-c1") }) |> ignore
  assert_true(t.find("读了 src/ui/list.mbt 等 2 个文件，跑了测试") is Some(_), msg="history initial value rendered")
  side_kept_step(t, fn() { @sfdesk.side_change(src, side_tab_chat, "open", Some("files")) }) |> ignore
  assert_true(t.find("下载") is Some(_), msg="files initial value rendered")
  // Park both history and files by switching to jobs.
  side_kept_step(t, fn() { @sfdesk.side_front_pressed(src, side_tab_chat, "jobs") }) |> ignore
  assert_true(t.find("后台任务") is Some(_), msg="jobs active while history & files parked")
  // Simulate live topics having released subscriptions on park and Core not yet answering on wake.
  live_ready.set(false)
  // Wake history: per #7344, history keeps its last steps without flashing skeleton while awaiting Core's first answer.
  side_kept_step(t, fn() { @sfdesk.side_change(src, side_tab_chat, "front", Some("s-c1")) }) |> ignore
  assert_true(
    t.find("读了 src/ui/list.mbt 等 2 个文件，跑了测试") is Some(_),
    msg="woken history tab preserves last steps without flashing skeleton (#7344)",
  )
  // Wake files (`drive` live topic): must NOT render stale folder entry text while live value is None.
  side_kept_step(t, fn() { @sfdesk.side_change(src, side_tab_chat, "front", Some("files")) }) |> ignore
  assert_true(
    t.find("下载") is None,
    msg="woken live files tab must not render stale text before Core answers",
  )
  // Once Core answers with fresh values, both render cleanly.
  live_ready.set(true)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("下载") is Some(_), msg="files renders once Core answers")
  side_kept_step(t, fn() { @sfdesk.side_change(src, side_tab_chat, "front", Some("s-c1")) }) |> ignore
  assert_true(t.find("读了 src/ui/list.mbt 等 2 个文件，跑了测试") is Some(_), msg="history renders once Core answers")
}

///|
test "大屏: the right panel's + menu groups chat/history items, marks open tabs, switches open tabs, and opens closed tabs" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat-tabs-side", window_inset=true)
  t.run_for(@ui.move_most_ms)
  // Open tabs in chat-tabs-side: ["s-c1", "jobs"], front: "jobs".
  t.click(Button, label=@sf.t("web-pages.chat.openPanelTab"))
  t.run_for(@ui.move_most_ms)
  // Group headings: This chat & Run history present; Remote absent (no remote capabilities in chat-tabs-side).
  assert_true(t.find(@sf.t("web-main.switcher.group.chat")) is Some(_), msg="This chat heading shown")
  assert_true(t.find(@sf.t("android-chat.history.title")) is Some(_), msg="Run history heading shown")
  assert_true(t.find(@sf.t("web-pages.remote.title")) is None, msg="Remote heading hidden when no remote capabilities")
  // Chat & history rows present; sub-chats & reopen hidden when unavailable.
  assert_true(t.find(@sf.t("web-pages.chat.files")) is Some(_), msg="Station files offered")
  assert_true(t.find(@sf.t("web-pages.chat.jobs")) is Some(_), msg="Jobs offered")
  assert_true(t.find(@sf.t("web-main.things.title")) is Some(_), msg="Media/Files/Links offered")
  assert_true(t.find(@sf.t("web-main.letters.title")) is Some(_), msg="Agent messages offered")
  assert_true(t.find(@sf.t("web-pages.chat.subchats")) is None, msg="Sub-chats hidden when none")
  assert_true(t.find(@sf.t("web-pages.chat.reopenTab")) is None, msg="Reopen hidden when can_reopen is false")
  // Open tabs ("s-c1" and "jobs") are marked with the muted "Open" hint, not checkmarks.
  let open_hints = t.words().filter(fn(w) { w.0 == @sf.t("web-pages.chat.tabOpen") })
  assert_eq(open_hints.length(), 2, msg="two open tabs should show Open hint: \{Repr(open_hints)}")
  assert_eq(t.corner_faults(), [])
  assert_eq(t.contrast_faults(), [])
  // Clicking an already-open tab ("s-c1" -> Claude · Opus 5.5) switches to it via chat.tabs.front, not chat.tabs.open.
  let before_calls = calls.length()
  side_tap_rightmost(t, "Claude · Opus 5.5")
  t.run_for(@ui.move_most_ms)
  let after_switch = calls[before_calls:].to_owned()
  assert_true(
    after_switch.iter().any(fn(c) { c.name == "chat.tabs.front" && text(Some(c.params), "tab") == "s-c1" }),
    msg="already-open tab switches via chat.tabs.front: \{Repr(after_switch.map(fn(c) { (c.name, c.params) }))}",
  )
  assert_false(
    after_switch.iter().any(fn(c) { c.name == "chat.tabs.open" && text(Some(c.params), "tab") == "s-c1" }),
    msg="already-open tab must not emit chat.tabs.open",
  )
  // End-to-end tab open & reopen via + menu on the live fixture (avoids kept-answers misses and verifies tab state).
  new_run()
  let src = fixture("chat")
  open_chat(side_tab_chat)
  let t_live = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t_live.run_for(@ui.move_most_ms)
  @sfdesk.side_change(src, side_tab_chat, "open", Some("s-c1"))
  t_live.frame()
  @sfdesk.side_change(src, side_tab_chat, "open", Some("jobs"))
  t_live.run_for(@ui.move_most_ms)
  // Pick closed "Station files" from + menu -> opens "files" in front.
  t_live.click(Button, label=@sf.t("web-pages.chat.openPanelTab"))
  t_live.run_for(@ui.move_most_ms)
  side_tap_rightmost(t_live, @sf.t("web-pages.chat.files"))
  t_live.run_for(@ui.move_most_ms)
  assert_eq(side_now(side_tab_chat), (["s-c1", "jobs", "files"], "files"))
  // Open "letters", switch to "s-c1", then close tabs to the right of "jobs" so can_reopen becomes true.
  @sfdesk.side_change(src, side_tab_chat, "open", Some("letters"))
  t_live.frame()
  @sfdesk.side_change(src, side_tab_chat, "front", Some("s-c1"))
  t_live.frame()
  @sfdesk.side_change(src, side_tab_chat, "closeRight", Some("jobs"))
  t_live.run_for(@ui.move_most_ms)
  t_live.click(Button, label=@sf.t("web-pages.chat.openPanelTab"))
  t_live.run_for(@ui.move_most_ms)
  assert_true(t_live.find(@sf.t("web-pages.chat.reopenTab")) is Some(_), msg="Reopen offered once a tab was closed")
  assert_eq(t_live.corner_faults(), [])
  assert_eq(t_live.contrast_faults(), [])
  side_tap_rightmost(t_live, @sf.t("web-pages.chat.reopenTab"))
  t_live.run_for(@ui.move_most_ms)
  assert_eq(side_now(side_tab_chat).0, ["s-c1", "jobs", "files", "letters"])
}

///|
test "大屏: the right panel's + menu shows sub-chats and remote groups when available, and panel-open right-click opens it" {
  // 1. Sub-chats group item appears and shows Open hint when subchats tab is open.
  let t1 = wide_tester([], mode="chat-subchats-panel", window_inset=true)
  t1.run_for(@ui.move_most_ms)
  t1.click(Button, label=@sf.t("web-pages.chat.openPanelTab"))
  t1.run_for(@ui.move_most_ms)
  assert_true(t1.find(@sf.t("web-pages.chat.subchats")) is Some(_), msg="Sub-chats offered when opened is non-empty")
  assert_true(t1.find(@sf.t("web-pages.chat.tabOpen")) is Some(_), msg="Open sub-chats tab marked Open")
  assert_eq(t1.corner_faults(), [])
  assert_eq(t1.contrast_faults(), [])
  // 2. When panel is closed in a chat with remote screens, right-clicking panel-open opens the same menu with Remote group.
  let t2 = wide_tester([], mode="chat-station-screens", window_inset=true)
  t2.run_for(@ui.move_most_ms)
  let open_btn = t2.get(Button, label=@sf.t("web-pages.chat.openPanel"))
  let (bx, by, bw, bh) = open_btn.rect
  t2.right_click(bx + bw / 2.0, by + bh / 2.0)
  t2.run_for(@ui.move_most_ms)
  assert_true(t2.find(@sf.t("web-main.switcher.group.chat")) is Some(_), msg="panel-open right-click opens menu")
  assert_true(t2.find(@sf.t("web-pages.remote.title")) is Some(_), msg="Remote group shown in chat-station-screens")
  assert_true(t2.find("Willow 的桌面") is Some(_), msg="Desktop screen listed under Remote")
  assert_true(t2.find("登录 - GitHub · agent 正在操作") is Some(_), msg="Agent-driven browser screen listed under Remote")
  assert_eq(t2.corner_faults(), [])
  assert_eq(t2.contrast_faults(), [])
}
