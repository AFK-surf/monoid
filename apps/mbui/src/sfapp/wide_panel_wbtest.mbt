// Beside a chat in the wide frame (wide_panel.mbt): its "…" a popover under its button, agent 往来 from it opened in the
// side panel at its right, the panel closed by its switch and opened again at the first agent's history.

///|
test "wide: the chat's \"…\" opens under its button; agent 往来 from it opens beside the chat; the panel closes and opens" {
  new_run()
  let src = fixture("chat-letters-info")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfdesk.is_wide(t.ctx()))
  assert_true(t.find("agent 往来") is None)
  // what is done with it, under its "…": agent 往来 among it, saying how many
  t.click(Button, label="对话信息")
  t.frame()
  t.frame()
  assert_true(t.find("agent 往来") is Some(_))
  assert_true(t.find("4 条") is Some(_))
  assert_true(t.find("参与") is Some(_), msg="its facts")
  t.tap_text("agent 往来")
  // (the popover goes as a popover does: gone once its going is over; the panel slid in)
  t.run_for(dmax(@motion.presence_out_ms, @ui.move_most_ms))
  // beside the chat, at its right: the chats written with
  let (x, _) = t.find("接手监督 mbui").unwrap()
  assert_true(x > 800.0, msg="at the pane's right")
  assert_true(t.find("BFT 备份尺寸分析") is Some(_))
  assert_true(t.find("参与") is None, msg="the popover gone")
  // its switch closes it; the bar's opens it again, at the first agent's history
  t.click(Button, label="收起侧栏")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("接手监督 mbui") is None)
  t.click(Button, label="打开侧栏")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("只看收发") is Some(_), msg="its history's head")
}

///|
test "wide: an agent's history's head as the web's: its control, 只看收发 leaving its steps out, 详情 folding" {
  new_run()
  let base = fixture("chat-detail")
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let got = base.topic(name, params).get().snapshot()
      match (name, got.value) {
        ("history", Some(Object(h)) as v) => {
          let marked = items(v, "items").map(fn(it) {
            match it {
              Object(o) if text(field(Some(it), "body"), "kind") == "group" => {
                let o = o.copy()
                o["work"] = Json::boolean(true)
                Json::object(o)
              }
              other => other
            }
          })
          let h = h.copy()
          h["items"] = Json::array(marked)
          { ..got, value: Some(Json::object(h)) }
        }
        _ => got
      }
    },
  }
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  // the bar's switch: its first agent's history beside it
  t.click(Button, label="打开侧栏")
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r), (["s-c1"], "s-c1"))
  // (where its transcript is: asked once the frame is built, answered at once)
  t.frame()
  t.frame()
  // 详情 starts folded on wide screens; clicking 详情 unfolds what runs it, its station, and its transcript
  assert_true(t.query(Button, label="复制路径") is None)
  t.click(Button, label="详情")
  t.run_for(@ui.move_most_ms)
  t.frame()
  assert_true(t.find("Willow") is Some(_))
  assert_true(t.query(Button, label="复制路径") is Some(_))
  // (folded back on a Move, as what a column lets go)
  t.click(Button, label="详情")
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="复制路径") is None)
  // its own steps there, then left out
  let steps = t.find("读了 src/ui/list.mbt 等 2 个文件，跑了测试")
  t.click(Button, label="只看收发")
  t.frame()
  if steps is Some(_) {
    assert_true(t.find("读了 src/ui/list.mbt 等 2 个文件，跑了测试") is None)
  }
  assert_true(@sfpages.history_only_io())
}

///|
test "wide: a quota running out beside an agent's history's control is whole however narrow its head: the control's parts leave first, its figure never cut" {
  new_run()
  let base = fixture("chat")
  // (its agent's account's weekly window running out, as the core says it beside the control)
  let note : Json = {
    "kind": "quota",
    "text": "每周额度剩 23%",
    "quota": { "left": 23, "mark": "W", "level": "amber" },
  }
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let got = base.topic(name, params).get().snapshot()
      match (name, got.value) {
        ("chat", Some(Object(chat)) as v) => {
          let agents = items(v, "agents").map(fn(a) {
            match a {
              Object(o) => {
                let o = o.copy()
                o["attention"] = [note]
                Json::object(o)
              }
              other => other
            }
          })
          let chat = chat.copy()
          chat["agents"] = Json::array(agents)
          { ..got, value: Some(Json::object(chat)) }
        }
        _ => got
      }
    },
  }
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1600.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="打开侧栏")
  t.run_for(@ui.move_most_ms)
  let figure = fn() { t.words().filter(fn(w) { w.0 == "23%" && w.5 > 0.5 }) }
  let wide = figure()
  assert_true(wide.length() == 1, msg="\{Repr(wide)}")
  let whole = wide[0].3
  // the panel from as narrow as it is beside the chat (360) to wider: its figure as wide as it is everywhere
  for w = 1100.0; w <= 1600.0; w = w + 20.0 {
    t.resize(w, 800.0)
    t.frame()
    let now = figure()
    assert_true(now.length() == 1 && now[0].3 >= whole - 0.5, msg="\{w}: \{Repr(now)} (whole: \{whole})")
  }
}

///|
test "wide: Station 文件 from the chat's \"…\" beside it (kept by the core: chat.tabs.open); a row's 添加到消息 into its message" {
  new_run()
  let calls : Array[Made] = []
  let base = fixture("chat")
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      calls.push({ name, params, bytes: None, done })
      (base.call)(name, params, done)
    },
  }
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="对话信息")
  t.frame()
  t.frame()
  t.tap_text("Station 文件")
  t.run_for(dmax(@motion.presence_out_ms, @ui.move_most_ms))
  let opened = named(calls, "chat.tabs.open")
  assert_eq(opened.length(), 1)
  assert_eq(text(Some(opened[0].params), "chat"), "ws1/st1:s-c1")
  assert_eq(text(Some(opened[0].params), "tab"), "files")
  assert_eq(side_now(r), (["files"], "files"))
  // its tab, and the station's home in it at the pane's right
  assert_true(t.find("主目录") is Some(_))
  // a file's menu: 添加到消息, into the chat's draft, named by its path
  @sfdesk.tab_place_set("ws1", Some({ station: "ws1/st1", root: Some(fix_docs), path: "" }))
  t.frame()
  let (x, y) = match t.find("发布清单.md") {
    Some(at) => at
    None => fail("no 发布清单.md in the tab")
  }
  assert_true(x > 800.0)
  t.right_click(x, y)
  t.frame()
  t.tap_text("添加到消息")
  t.frame()
  t.frame()
  let refs = @sfbase.writings.get(draft_key(r)).map(fn(d) { d.files.get() }).unwrap_or([])
  assert_eq(refs.length(), 1)
  assert_eq(text(field(Some(refs[0]), "ref"), "path"), fix_docs + "/发布清单.md")
  assert_eq(text(field(Some(refs[0]), "ref"), "stationName"), "Willow")
  // another row dragged off the tab onto the chat: let go there, into its draft too
  let (x, y) = match t.find("长篇小说.txt") {
    Some(at) => at
    None => fail("no 长篇小说.txt in the tab")
  }
  t.drag(x, y, 400.0, 400.0)
  t.frame()
  t.frame()
  let refs = @sfbase.writings.get(draft_key(r)).map(fn(d) { d.files.get() }).unwrap_or([])
  assert_eq(refs.length(), 2)
  assert_eq(text(field(refs.get(1), "ref"), "path"), fix_docs + "/长篇小说.txt")
}

///|
test "wide: a new chat's Station 文件 beside it (NewChat.tsx): kept open, closed and opened by its bar's button; a row's 添加到消息 into its draft" {
  both_pages(fn() raise {
    new_run()
    let calls : Array[Made] = []
    let base = fixture("newchat-files")
    let src : Source = {
      ..base,
      call: fn(name, params, done) {
        calls.push({ name, params, bytes: None, done })
        (base.call)(name, params, done)
      },
    }
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() == NewChat)
    // kept open for the workspace's new chat: its tab, the station's home in it
    assert_true(t.find("主目录") is Some(_))
    t.click(Button, label="收起侧栏")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("主目录") is None)
    let closed = named(calls, "chat.tabs.close")
    assert_eq(closed.length(), 1)
    assert_eq(text(Some(closed[0].params), "chat"), "new:ws1")
    t.click(Button, label="Station 文件")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("主目录") is Some(_))
    // a file's 添加到消息: into the new chat's draft, named by its path
    @sfdesk.tab_place_set("ws1", Some({ station: "ws1/st1", root: Some(fix_docs), path: "" }))
    t.frame()
    let (x, y) = match t.find("发布清单.md") {
      Some(at) => at
      None => fail("no 发布清单.md in the tab")
    }
    t.right_click(x, y)
    t.frame()
    t.tap_text("添加到消息")
    t.frame()
    t.frame()
    let refs = @sfbase.writings.get("new:ws1").map(fn(d) { d.files.get() }).unwrap_or([])
    assert_eq(refs.length(), 1)
    assert_eq(text(field(Some(refs[0]), "ref"), "path"), fix_docs + "/发布清单.md")
  })
}

///|
test "wide: the side panel's tabs are the core's (chat.tabs.*): an agent's history before 任务, the last left in front, the panel's switch closes them all" {
  new_run()
  let src = fixture("chat")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r), ([], ""))
  side_change(r, "open", Some("jobs"))
  t.frame()
  side_change(r, "open", Some("s-c1"))
  t.frame()
  // (the history after the histories open, before the other tabs; in front as it is opened)
  assert_eq(side_now(r), (["s-c1", "jobs"], "s-c1"))
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("只看收发") is Some(_), msg="its history in front")
  side_change(r, "close", Some("s-c1"))
  t.frame()
  assert_eq(side_now(r), (["jobs"], "jobs"))
  t.click(Button, label="收起侧栏")
  t.frame()
  assert_eq(side_now(r), ([], ""))
  assert_true(t.query(Button, label="打开侧栏") is Some(_))
}

///|
test "wide: the side panel slides in from the pane's right edge over 280 ms and out over 240, the chat narrowing and widening with it (useSidePanel)" {
  new_run()
  let src = fixture("chat")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="打开侧栏")
  t.frame()
  // on its way in: its head further right than it will rest, as the column it shows through has widened so far
  t.run_for(@ui.move_most_ms / 2.0)
  let (mid, _) = t.find("只看收发").unwrap()
  t.run_for(@ui.move_most_ms / 2.0)
  let (end, _) = t.find("只看收发").unwrap()
  assert_true(mid > end, msg="in from the right: \{mid} then \{end}")
  // as it rests, no further
  t.run_for(@ui.move_most_ms)
  assert_eq(t.find("只看收发").map(fn(at) { at.0 }), Some(end))
  // closed: still there on its way out (what it showed), gone at its end
  t.click(Button, label="收起侧栏")
  t.frame()
  t.run_for(@ui.move_most_ms / 2.0)
  let (going, _) = t.find("只看收发").unwrap()
  assert_true(going > end, msg="out to the right: \{going}")
  t.run_for(@ui.move_most_ms / 2.0)
  assert_true(t.find("只看收发") is None)
  // opened again: in again, to where it rested
  t.click(Button, label="打开侧栏")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.find("只看收发").map(fn(at) { at.0 }), Some(end))
}

///|
test "wide: in a window wide enough for the chat's rows to keep their width as the panel slides in, the page is at rest again as the slide ends, whichever frames are drawn (24 a second: one just short of its end)" {
  new_run()
  let src = fixture("chat")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=2400.0, h=1000.0, platform=0)
  t.run_for(@ui.move_most_ms)
  // (every frame on the slide's way and after it the one built whole: the Tester's own check of each, frame_watch.mbt)
  t.click(Button, label="打开侧栏")
  t.run_for(@ui.move_most_ms)
  let (end, _) = t.find("只看收发").unwrap()
  t.run_for(@ui.move_most_ms)
  assert_eq(t.find("只看收发").map(fn(at) { at.0 }), Some(end))
  // and out again
  t.click(Button, label="收起侧栏")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("只看收发") is None)
}

///|
test "wide: an agent's history asked as a page (a link's ?history=…&entry=…) is its chat with the history beside it (ChatPage.tsx history)" {
  new_run()
  let src = fixture("chat")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  app.nav.push(History(r, "s-c1", Some(3)))
  t.frame()
  t.frame()
  // the chat's page, in place of the page asked; the history in front beside it
  assert_true(app.nav.top() == Chat(r), msg="the chat's page")
  assert_eq(side_now(r), (["s-c1"], "s-c1"))
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("只看收发") is Some(_))
}

///|
/// The chat as a Slack thread alone shows it (the core's page of an agent with no chat here: no thread, where its
/// Slack thread is and the way there).
fn slack_only(base : Source) -> Source {
  {
    ..base,
    topic_read: fn(name, params) {
      let got = base.topic(name, params).get().snapshot()
      guard name == "chat" && got.value is Some(Object(v)) else { return got }
      let v = v.copy()
      v["thread"] = Json::null()
      v["place"] = Json::string("#ops")
      v["slackUrl"] = Json::string("https://afk.slack.com/archives/C1/p12")
      v.remove("xshare")
      v.remove("publish")
      { ..got, value: Some(Json::object(v)) }
    },
  }
}

///|
test "wide: a chat of a Slack thread alone has its \"…\" too: where it is, its agents, the way to it in Slack" {
  new_run()
  let src = slack_only(fixture("chat"))
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="对话信息")
  t.frame()
  t.frame()
  assert_true(t.find("Slack · #ops") is Some(_), msg=t.words().map(fn(w) { w.0 }).join("|"))
  // (what only a chat of its own here has: who started it, when)
  assert_true(t.find("发起") is None)
  // the way to it in Slack is what is done with it: its "…"'s
  assert_true(t.find("在 Slack 中打开") is None)
  // (its info closed first: what is behind a popover the tree puts up over the window is pressed once it is gone, as a
  // press outside it closes it)
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="更多")
  t.run_for(@ui.move_most_ms)
  open_share(t)
  assert_true(t.find("在 Slack 中打开") is Some(_))
}

///|
/// Chat `r`'s tabs as its view has them now.
fn side_now(r : ChatRef) -> (Array[String], String) {
  match link_src.val {
    Some(src) => @sfdesk.side_now(src, r)
    None => ([], "")
  }
}

///|
/// Chat `r`'s tabs changed by the core, the panel told first whether any will be open (sfdesk's side_change).
fn side_change(r : ChatRef, action : String, tab : String?) -> Unit {
  match link_src.val {
    Some(src) => @sfdesk.side_change(src, r, action, tab)
    None => ()
  }
}

///|
/// The panel's tab bar nodes as a screen reader sees them (label, selected, rect).
fn wide_tabs_said(t : @ui.Tester) -> Array[(String, Bool, (Double, Double, Double, Double))] {
  t.semantics().filter(fn(s) { s.role == @ui.Role::Tab && !s.hidden }).map(fn(s) { (s.label, s.selected == Some(true), s.rect) })
}

///|
test "wide: repeated × clicks freeze tab width so next tab × lands under stationary pointer, then expand on pointer leave" {
  new_run()
  let src = fixture("chat")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  side_change(r, "open", Some("s-c1"))
  t.frame()
  side_change(r, "open", Some("jobs"))
  t.frame()
  side_change(r, "open", Some("files"))
  t.frame()
  side_change(r, "front", Some("s-c1"))
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r), (["s-c1", "jobs", "files"], "s-c1"))
  let tabs0 = wide_tabs_said(t)
  assert_eq(tabs0.length(), 3, msg="\{Repr(tabs0)}")
  let w0 = tabs0[0].2.2
  // Move pointer to first tab's × and click it
  let x0_rect = t.get(Button, label=@sf.t("web-pages.chat.close", args=[("name", tabs0[0].0)])).rect
  let (cx, cy) = (x0_rect.0 + x0_rect.2 / 2.0, x0_rect.1 + x0_rect.3 / 2.0)
  t.move_to(cx, cy)
  t.draw()
  t.tap(cx, cy)
  t.run_for(@ui.move_most_ms)
  // Right neighbor ("jobs") becomes active, width remains frozen at w0
  assert_eq(side_now(r), (["jobs", "files"], "jobs"))
  let tabs1 = wide_tabs_said(t)
  assert_eq(tabs1.length(), 2, msg="\{Repr(tabs1)}")
  assert_true((tabs1[0].2.2 - w0).abs() < 2.0, msg="width stays frozen: was \{w0}, now \{tabs1[0].2.2}")
  // Click the exact same (cx, cy) without moving pointer -> closes "jobs"
  t.tap(cx, cy)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r), (["files"], "files"))
  let tabs2 = wide_tabs_said(t)
  assert_eq(tabs2.length(), 1, msg="\{Repr(tabs2)}")
  assert_true((tabs2[0].2.2 - w0).abs() < 2.0, msg="width still frozen before pointer leave: \{tabs2[0].2.2}")
  // Move pointer out of tab strip -> smoothly expands to natural width (168pt)
  t.move_to(10.0, 500.0)
  t.run_for(@ui.move_most_ms)
  let tabs3 = wide_tabs_said(t)
  assert_true(tabs3[0].2.2 > w0 + 4.0, msg="expanded after leave: was \{w0}, now \{tabs3[0].2.2}")
  assert_eq(t.audit().filter(fn(f) { f.contains("panel_bar_node") }), [])
}

///|
test "wide: closing middle tab activates right neighbor and closing rightmost tab activates left neighbor" {
  new_run()
  let src = fixture("chat")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  side_change(r, "open", Some("s-c1"))
  t.frame()
  side_change(r, "open", Some("jobs"))
  t.frame()
  side_change(r, "open", Some("files"))
  t.frame()
  side_change(r, "front", Some("jobs"))
  t.run_for(@ui.move_most_ms)
  // Close middle ("jobs") -> right neighbor ("files")
  side_change(r, "close", Some("jobs"))
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r), (["s-c1", "files"], "files"))
  // Close rightmost ("files") -> left neighbor ("s-c1")
  side_change(r, "close", Some("files"))
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r), (["s-c1"], "s-c1"))
}

///|
test "wide: inactive tab × is unmounted until hover when wide, stays unmounted when narrow, and hover causes zero height jump" {
  new_run()
  let src = fixture("chat")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  side_change(r, "open", Some("s-c1"))
  t.frame()
  side_change(r, "open", Some("jobs"))
  t.frame()
  side_change(r, "front", Some("s-c1"))
  t.run_for(@ui.move_most_ms)
  // Wide inactive tab ("jobs"): × not mounted before hover (no alpha=0 click-through)
  assert_true(t.query(Button, label=@sf.t("web-pages.chat.closeJobs")) is None, msg="no × before hover")
  let before_rect = wide_tabs_said(t)[1].2
  t.move_to(before_rect.0 + before_rect.2 / 2.0, before_rect.1 + before_rect.3 / 2.0)
  t.draw()
  assert_true(t.query(Button, label=@sf.t("web-pages.chat.closeJobs")) is Some(_), msg="× mounts on hover")
  let after_rect = wide_tabs_said(t)[1].2
  assert_eq(after_rect.3, before_rect.3, msg="zero height jump on hover")
  assert_eq(t.audit().filter(fn(f) { f.contains("panel_bar_node") }), [])
  // Narrow inactive tabs (5 tabs -> slot width < 116pt): hover never mounts ×
  let md_tab = "view:" + Json::array([Json::string("chat"), Json::string("ws1/st1"), Json::string("s-c1"), Json::string("notes.md"), Json::string("notes.md"), Json::number(100.0)]).stringify()
  side_change(r, "open", Some("files"))
  t.frame()
  side_change(r, "open", Some("letters"))
  t.frame()
  side_change(r, "open", Some(md_tab))
  t.frame()
  side_change(r, "front", Some("s-c1"))
  t.run_for(@ui.move_most_ms)
  let narrow_tabs = wide_tabs_said(t)
  let (_, _, (fx, fy, fw, fh)) = narrow_tabs[2]
  t.move_to(fx + fw / 2.0, fy + fh / 2.0)
  t.draw()
  assert_true(t.query(Button, label=@sf.t("web-pages.chat.closeFiles")) is None, msg="narrow inactive tab has no × on hover")
  // Clicking narrow inactive tab switches to it without closing
  t.tap(fx + fw / 2.0, fy + fh / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r).1, "files")
  assert_eq(side_now(r).0.length(), 5)
}

///|
test "wide: overflow tabs show dropdown button that lists all tabs and switches active tab into view" {
  new_run()
  let src = fixture("chat")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  let extra1 = "view:" + Json::array([Json::string("chat"), Json::string("ws1/st1"), Json::string("s-c1"), Json::string("a.md"), Json::string("a.md"), Json::number(100.0)]).stringify()
  let extra2 = "view:" + Json::array([Json::string("chat"), Json::string("ws1/st1"), Json::string("s-c1"), Json::string("b.md"), Json::string("b.md"), Json::number(100.0)]).stringify()
  let extra3 = "view:" + Json::array([Json::string("chat"), Json::string("ws1/st1"), Json::string("s-c1"), Json::string("c.md"), Json::string("c.md"), Json::number(100.0)]).stringify()
  for tab in ["s-c1", "jobs", "files", "letters", extra1, extra2, extra3] {
    side_change(r, "open", Some(tab))
    t.frame()
  }
  side_change(r, "front", Some("s-c1"))
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label=@sf.t("web-pages.chat.moreTabs")) is Some(_), msg="overflow button shown")
  t.click(Button, label=@sf.t("web-pages.chat.moreTabs"))
  t.run_for(@ui.move_most_ms)
  t.click(MenuItemRadio, label="c.md")
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r).1, extra3)
}

///|
test "wide: tab context menu supports close right, reopen, close others, and drag reorder + keyboard shortcuts" {
  new_run()
  let src = fixture("chat")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  for tab in ["s-c1", "jobs", "files", "letters"] {
    side_change(r, "open", Some(tab))
    t.frame()
  }
  side_change(r, "front", Some("s-c1"))
  t.run_for(@ui.move_most_ms)
  // Context menu on "jobs" -> Close tabs to the right
  let (_, _, (jx, jy, jw, jh)) = wide_tabs_said(t)[1]
  t.right_click(jx + jw / 2.0, jy + jh / 2.0)
  t.run_for(@ui.move_most_ms)
  t.tap_text(@sf.t("web-pages.chat.closeRightTabs"))
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r), (["s-c1", "jobs"], "s-c1"))
  // Context menu -> Reopen closed tab restores ["files", "letters"]
  let (_, _, (jx2, jy2, jw2, jh2)) = wide_tabs_said(t)[1]
  t.right_click(jx2 + jw2 / 2.0, jy2 + jh2 / 2.0)
  t.run_for(@ui.move_most_ms)
  t.tap_text(@sf.t("web-pages.chat.reopenTab"))
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r).0, ["s-c1", "jobs", "files", "letters"])
  // Drag reorder: drag first tab ("s-c1") right over second tab ("jobs")
  let tabs_drag = wide_tabs_said(t)
  let (x0, y0, w0, h0) = tabs_drag[0].2
  let (x1, _, w1, _) = tabs_drag[1].2
  t.drag(x0 + w0 / 2.0, y0 + h0 / 2.0, x1 + w1 * 0.75, y0 + h0 / 2.0, steps=8)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r).0, ["jobs", "s-c1", "files", "letters"])
  // Keyboard shortcuts: next, prev, close, reopen
  side_change(r, "front", Some("jobs"))
  t.run_for(@ui.move_most_ms)
  let mod_cs = @ui.mod_cmd | @ui.mod_shift_key
  t.key(@ui.key_of_char(']'), mods=mod_cs)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r).1, "s-c1")
  t.key(@ui.key_of_char('['), mods=mod_cs)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r).1, "jobs")
  t.key(@ui.key_of_char('w'), mods=mod_cs)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r), (["s-c1", "files", "letters"], "s-c1"))
  t.key(@ui.key_of_char('t'), mods=mod_cs)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r), (["jobs", "s-c1", "files", "letters"], "jobs"))
  // Context menu -> Close other tabs
  let (_, _, (cx, cy, cw, ch)) = wide_tabs_said(t)[0]
  t.right_click(cx + cw / 2.0, cy + ch / 2.0)
  t.run_for(@ui.move_most_ms)
  t.tap_text(@sf.t("web-pages.chat.closeOtherTabs"))
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r), (["jobs"], "jobs"))
  // Esc clears panel, then ⌘⇧T reopens
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r), ([], ""))
  t.key(@ui.key_of_char('t'), mods=mod_cs)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r), (["jobs"], "jobs"))
}

///|
test "wide: middle-clicking tabs closes inactive/active tabs, freezes width on rapid closes, cancels on drag-off, and coexists with context menu" {
  new_run()
  let src = fixture("chat")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  for tab in ["s-c1", "jobs", "files", "letters"] {
    side_change(r, "open", Some(tab))
    t.frame()
  }
  side_change(r, "front", Some("s-c1"))
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r), (["s-c1", "jobs", "files", "letters"], "s-c1"))
  let tabs0 = wide_tabs_said(t)
  assert_eq(tabs0.length(), 4, msg="\{Repr(tabs0)}")
  let w0 = tabs0[0].2.2
  // 1. Middle-click drag-off cancels without closing
  let (jx, jy, jw, jh) = tabs0[1].2
  let (jcx, jcy) = (jx + jw / 2.0, jy + jh / 2.0)
  t.move_to(jcx, jcy)
  t.button_down(jcx, jcy, 3)
  t.move_to(jcx, jcy + 120.0)
  t.button_up(jcx, jcy + 120.0, 3)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r), (["s-c1", "jobs", "files", "letters"], "s-c1"))
  // 2. Right-click context menu still works on the same tab alongside on_middle
  t.right_click(jcx, jcy)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find(@sf.t("web-pages.chat.closeRightTabs")) is Some(_), msg="context menu opens alongside on_middle")
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  // 3. Middle-click inactive tab ("jobs") closes it without changing active tab ("s-c1") and freezes width
  t.move_to(jcx, jcy)
  t.button_down(jcx, jcy, 3)
  t.button_up(jcx, jcy, 3)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r), (["s-c1", "files", "letters"], "s-c1"))
  let tabs1 = wide_tabs_said(t)
  assert_eq(tabs1.length(), 3, msg="\{Repr(tabs1)}")
  assert_true((tabs1[0].2.2 - w0).abs() < 2.0, msg="width stays frozen after middle-close: was \{w0}, now \{tabs1[0].2.2}")
  // 4. Rapid second middle-click at the exact same (jcx, jcy) closes "files" while width remains frozen
  t.button_down(jcx, jcy, 3)
  t.button_up(jcx, jcy, 3)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r), (["s-c1", "letters"], "s-c1"))
  let tabs2 = wide_tabs_said(t)
  assert_eq(tabs2.length(), 2, msg="\{Repr(tabs2)}")
  assert_true((tabs2[0].2.2 - w0).abs() < 2.0, msg="width still frozen before leave: \{tabs2[0].2.2}")
  // 5. Moving pointer out of tab strip smoothly expands remaining tabs
  t.move_to(10.0, 500.0)
  t.run_for(@ui.move_most_ms)
  let tabs3 = wide_tabs_said(t)
  assert_true(tabs3[0].2.2 > w0 + 4.0, msg="expanded after pointer leave: was \{w0}, now \{tabs3[0].2.2}")
  // 6. Middle-click active tab ("s-c1") closes it and activates right neighbor ("letters")
  let (sx, sy, sw, sh) = tabs3[0].2
  let (scx, scy) = (sx + sw / 2.0, sy + sh / 2.0)
  t.move_to(scx, scy)
  t.button_down(scx, scy, 3)
  t.button_up(scx, scy, 3)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r), (["letters"], "letters"))
}
