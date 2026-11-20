// A web service and a visualization beside a chat on the desktop (sfdesk/service_tab.mbt; still.fail web/src/pages/Chat.tsx's
// side panel, Preview.tsx): asked as a page, the chat's page with it in front among the side panel's tabs, its page
// served from the station; closed, its site view let go.

///|
test "desk: a web service asked as a page is its chat with the service beside it, served from the station; closed, let go" {
  new_run()
  // (its agent's services known to the chat: the core keeps only a tab of one of them)
  let src = fixture("chat-info")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  // (a window whose side panel holds the whole of its bar, a press's room round each key: a 1280's leaves its size and
  // how far it came to its ⋯)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1440.0, h=900.0, platform=0)
  t.run_for(@ui.move_most_ms)
  app.nav.push(Service("ws1/st1", "j-web"))
  t.frame()
  t.frame()
  // the chat's page, in place of the page asked; the service in front beside it
  assert_true(app.nav.top() == Chat(r), msg="the chat's page")
  assert_eq(side_now(r), (["service:j-web"], "service:j-web"))
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="刷新") is Some(_), msg="its bar")
  // its page's size with keyboard and mouse: the bar's button, its choices in a panel beside it, no toolbar
  // under the page as touch has
  assert_true(t.find("自适应") is None, msg="no toolbar under the page")
  let had = t.ctx().focused_id()
  t.click(Button, label="页面尺寸")
  t.frame()
  assert_true(t.find("自适应") is Some(_), msg="its sizes")
  // as the web's (the composer's), all of them in the
  // panel's room
  assert_eq(t.ctx().focused_id(), had)
  assert_eq(t.squeeze_faults(), [])
  t.key(@ui.key_escape)
  t.frame()
  // marking it: what to do said in the address's place beside its keys, all of it in the tab's room
  t.click(Button, label="标注")
  t.frame()
  assert_true(t.find("点选页面上的元素") is Some(_), msg="what to do")
  // (four of its characters at least: what is beside it gives way first)
  let (_, _, said_w, _) = t.rect_of("点选页面上的元素").unwrap()
  assert_true(said_w >= 4.0 * 13.0, msg="what to do, \{said_w} wide")
  assert_eq(t.squeeze_faults(), [])
  assert_true(service_pages.contains(service_key("ws1/st1", "j-web")), msg="its page open")
  t.site_says("{\"req\":1,\"method\":\"GET\",\"path\":\"/\",\"headers\":[[\"Accept\",\"text/html\"]],\"page\":true}")
  t.frame()
  assert_true(t.views().iter().any(fn(s) { s.has_prefix("site head ") && s.contains(" 1 200 ") && s.contains("text/html") }))
  // its tab closed: its page let go
  side_change(r, "close", Some("service:j-web"))
  t.frame()
  assert_eq(side_now(r), ([], ""))
  // (shown as the panel slides out, let go once it is gone)
  t.run_for(@ui.move_most_ms)
  t.frame()
  assert_true(!service_pages.contains(service_key("ws1/st1", "j-web")), msg="let go")
}

///|
test "desk: a visualization opened aside is a tab beside its chat, served from here with its name in the bar" {
  new_run()
  let src = fixture("chat-viz")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  app.nav.push(PreviewFile("ws1/st1", "s-c1", "work/s-c1/release.html", "release.html"))
  t.frame()
  t.frame()
  let tab = @sfdesk.file_tab("s-c1", "work/s-c1/release.html", "release.html")
  assert_true(app.nav.top() == Chat(r), msg="the chat's page")
  assert_eq(side_now(r), ([tab], tab))
  t.run_for(@ui.move_most_ms)
  t.frame()
  let (x, _) = t.find_last("release.html").unwrap()
  assert_true(x > 800.0, msg="its name beside the chat: \{x}")
  side_change(r, "close", Some(tab))
  t.frame()
  assert_eq(side_now(r), ([], ""))
}

///|
/// The site view of the service `job` of ws1/st1's page, its host's number.
fn service_site_id(job : String) -> Int raise {
  match service_pages.get(service_key("ws1/st1", job)) {
    Some({ site: Some(v), .. }) => v.id()
    _ => fail("no site view of \{job}")
  }
}

///|
/// The panel's 全屏 pressed (said what is there to press where it is not).
fn press_full(t : @ui.Tester) -> Unit raise {
  match t.query(Button, label=@sf.t("web-main.preview.fullWindow")) {
    Some(_) => t.click(Button, label=@sf.t("web-main.preview.fullWindow"))
    None => fail("no 全屏: \{Repr(t.semantics().filter(fn(s) { !s.hidden }).map(fn(s) { s.label }))}")
  }
  t.run_for(@ui.move_most_ms)
}

///|
test "desk: a web service beside its chat goes over the whole window by the panel's 全屏, the same page and site view across it, and back by Escape and by 移到侧边, its tab staying" {
  new_run()
  let src = fixture("chat-info")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1440.0, h=900.0, platform=0)
  t.run_for(@ui.move_most_ms)
  app.nav.push(Service("ws1/st1", "j-web"))
  t.frame()
  t.frame()
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.tab_full.get() is None, msg="beside, as asked")
  let site = service_site_id("j-web")
  let beside_w = t.holes().fold(init=0.0, fn(m, h) { if h.2 > m { h.2 } else { m } })
  assert_true(beside_w < 1000.0, msg="its page beside the chat: \{beside_w}")
  press_full(t)
  assert_true(@sfbase.tab_full.get() is Some(_), msg="over the whole window")
  assert_eq(service_site_id("j-web"), site, msg="the same site view")
  assert_true(!t.views().contains("close \{site}"), msg="never closed")
  let full_w = t.holes().fold(init=0.0, fn(m, h) { if h.2 > m { h.2 } else { m } })
  assert_true(full_w > 1300.0, msg="its page across the window: \{full_w}")
  assert_eq(t.all(Button, label="刷新").length(), 1, msg="its bar once, over the whole window")
  assert_eq(t.all(Button, label=@sf.t("web-main.preview.moveBeside")).length(), 1, msg="移到侧边")
  for f in t.audit() {
    println("audit full: \{f}")
  }
  // (the pointer off the bar's keys: a tip shown takes Escape first)
  t.move_to(700.0, 500.0)
  t.run_for(@ui.move_most_ms)
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.tab_full.get() is None, msg="Escape: back beside")
  assert_eq(side_now(r), (["service:j-web"], "service:j-web"), msg="its tab stays, in front")
  assert_eq(service_site_id("j-web"), site, msg="the same site view again")
  press_full(t)
  t.click(Button, label=@sf.t("web-main.preview.moveBeside"))
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.tab_full.get() is None, msg="移到侧边: back beside")
  // its tab closed while over the whole window: the layer goes with it
  press_full(t)
  side_change(r, "close", Some("service:j-web"))
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.tab_full.get() is None, msg="gone with its tab")
}

///|
test "desk: a web service or a visualization asked opens over the whole window as its chat's tab, closed with it; with ⌘ held, beside" {
  new_run()
  let src = fixture("chat-viz")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  let tab = @sfdesk.file_tab("s-c1", "work/s-c1/release.html", "release.html")
  open_page(PreviewFile("ws1/st1", "s-c1", "work/s-c1/release.html", "release.html"))
  t.frame()
  t.frame()
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() == Chat(r), msg="the chat's page")
  assert_eq(side_now(r), ([tab], tab))
  match @sfbase.tab_full.get() {
    Some(f) => assert_eq(f.tab, tab, msg="its tab over the whole window")
    None => fail("not over the whole window")
  }
  let (x, _) = t.find_last("release.html").unwrap()
  assert_true(x < 800.0, msg="its name in the whole window's bar: \{x}")
  t.back()
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.tab_full.get() is None, msg="back: closed")
  assert_eq(side_now(r), ([], ""), msg="its tab gone with it, never left beside")
  // with ⌘ held: beside, nothing over the whole window
  t.hold_mods(@ui.mod_cmd)
  open_page(PreviewFile("ws1/st1", "s-c1", "work/s-c1/release.html", "release.html"))
  t.hold_mods(0)
  t.frame()
  t.frame()
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.tab_full.get() is None, msg="⌘: beside")
  assert_eq(side_now(r), ([tab], tab))
  // its 全屏 in the message, as a press asks: the same tab over the whole window, back in the panel after
  viz_open_full("release.html", "ws1/st1", "s-c1", "work/s-c1/release.html", "s-c1")
  t.frame()
  t.frame()
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.tab_full.get() is Some(_), msg="its 全屏")
  assert_true(@sfbase.viz_full.get() is None, msg="never the visualization's own whole window here")
  assert_eq(side_now(r), ([tab], tab), msg="never a second tab")
  t.back()
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.tab_full.get() is None)
  assert_eq(side_now(r), ([tab], tab), msg="beside before, beside again")
}

///|
test "desk: a service up pressed in 任务 beside the chat opens its own tab in front (JobsTab)" {
  new_run()
  let src = fixture("chat-jobs-side")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(r), (["jobs"], "jobs"))
  let (x, y) = t.find_last("web").unwrap()
  assert_true(x > 800.0, msg="its row beside the chat: \{x}")
  t.tap(x, y)
  t.frame()
  t.frame()
  let (tabs, front) = side_now(r)
  assert_eq(front, "service:j-web")
  assert_true(tabs.contains("jobs") && tabs.contains("service:j-web"), msg="\{Repr(tabs)}")
}

///|
test "desk: wherever the pointer shows the side panel's edge's ↔, a drag from there sets its width (its room round it as the pointer lights it)" {
  new_run()
  let src = fixture("chat-info")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1440.0, h=900.0, platform=0)
  t.run_for(@ui.move_most_ms)
  side_change(r, "open", Some("s-c1"))
  t.run_for(@ui.move_most_ms)
  let edge_x = fn() raise {
    for s in t.semantics() {
      if s.label.has_prefix("调整侧栏宽度") && !s.hidden {
        return s.rect.0 + s.rect.2 / 2.0
      }
    }
    fail("no side panel edge")
  }
  let line = edge_x()
  let offsets = [-16.0, -12.0, -8.0, -4.0, -2.0, 0.0, 2.0, 4.0, 8.0, 12.0, 16.0]
  let mut shown = 0
  for y in [300.0, 600.0] {
    for dx in offsets {
      let x = line + dx
      t.move_to(x, y)
      if t.cursor() != ResizeX {
        continue
      }
      shown += 1
      // (its edge on its left: dragged left, the panel wider, its edge as far left as the pointer went)
      t.drag(x, y, x - 30.0, y)
      assert_eq(edge_x(), line - 30.0, msg="from \{dx} at \{y}")
      t.drag(x - 30.0, y, x, y)
      assert_eq(edge_x(), line, msg="back from \{dx} at \{y}")
    }
  }
  assert_true(shown > 0)
}

///|
/// The corner rule on what a desk's service shows with its sizes up: none, but 移动页面's switch ending the panel's last
/// row in its bottom right corner once the page is laid out at a size of its own (service_panels_wbtest's svc_corners
/// says why it is known; none on the old panel).
fn desk_corners(t : @ui.Tester, at : String) -> Unit raise {
  let faults = t.corner_faults()
  guard !faults.is_empty() else { return }
  assert_true(
    t.query(Switch, label="移动页面") is Some(_) &&
    faults.length() == 1 &&
    faults[0].has_prefix("a box in 「移动页面 开着时手指拖动的是画布，不点网页」 (at ") &&
    faults[0].has_suffix(" (corner 24): 16 and 15 from its edges"),
    msg="\{at}: \{Repr(faults)}",
  )
}

///|
test "desk: a web service beside its chat laid out at a size through its sizes beside the size key: a preset, 自定义 put by Enter, 横竖互换; the page at each, the panel's fields reading it out" {
  @sf.presenters_reset()
  new_run()
  let src = fixture("chat-info")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  // (its corners said by desk_corners: the one known)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1440.0, h=900.0, platform=0, corners_held=false)
  t.run_for(@ui.move_most_ms)
  app.nav.push(Service("ws1/st1", "j-web"))
  t.frame()
  t.frame()
  t.run_for(@ui.move_most_ms)
  let p = service_pages.get(service_key("ws1/st1", "j-web")).unwrap()
  let size_now = fn() {
    match p.viewport.get() {
      Some({ width, height: Some(h) }) => "\{width}×\{h}"
      Some({ width, height: None }) => "\{width}×auto"
      None => "fit"
    }
  }
  let read_out = fn() raise { (t.get(TextField, label="宽").value, t.get(TextField, label="自动").value) }
  // (the size key, or its line in the ⋯ where the bar has not the room for it: laid out at a size, it says that too)
  let sizes = fn() raise {
    match t.query(Button, label="页面尺寸") {
      Some(_) => t.click(Button, label="页面尺寸")
      None => {
        t.click(Button, label="更多操作")
        t.run_for(@ui.move_most_ms)
        t.tap_text("页面尺寸")
      }
    }
    t.run_for(@ui.move_most_ms)
  }
  sizes()
  desk_corners(t, "as big as the preview")
  t.click(Button, label="手机 390 × 844")
  t.run_for(@ui.move_most_ms)
  assert_eq(size_now(), "390×844", msg="a preset")
  sizes()
  desk_corners(t, "at a phone's size")
  assert_eq(read_out(), ("390", "844"), msg="said in 自定义")
  t.click(TextField, label="宽")
  t.frame()
  t.clear()
  t.type_text("500")
  t.enter()
  t.run_for(@ui.move_most_ms)
  assert_eq((size_now(), read_out()), ("500×844", ("500", "844")), msg="put by Enter")
  t.click(Button, label="横竖互换")
  t.run_for(@ui.move_most_ms)
  assert_eq((size_now(), read_out()), ("844×500", ("844", "500")), msg="turned")
  desk_corners(t, "turned")
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenter_visible(), msg="the sizes closed")
}

///|
test "desk: a web service beside its chat sent to a window of its own and back by its 移到侧边: the same page and site view all along, opened once and never closed, drawn by one window at a time" {
  new_run()
  let src = fixture("chat-info")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1440.0, h=900.0, platform=0)
  t.set_window_opens(true)
  t.set_windows_in_process(true)
  t.set_window_beside_size(1, 960.0, 720.0)
  t.run_for(@ui.move_most_ms)
  app.nav.push(Service("ws1/st1", "j-web"))
  t.frame()
  t.frame()
  t.run_for(@ui.move_most_ms)
  let site = service_site_id("j-web")
  let opened = fn() { t.views().filter(fn(v) { v.has_prefix("open \{site} ") }).length() }
  assert_eq(opened(), 1)
  t.click(Button, label=@sf.t("web-pages.screen.window"))
  t.run_for(@ui.move_most_ms)
  assert_eq(t.windows_beside().length(), 1, msg="a window of this run")
  let (wid, what) = t.windows_beside()[0]
  assert_true(what.contains("\"role\":\"tab\"") && what.contains("\"tab\":\"service:j-web\""), msg=what)
  assert_eq(side_now(r).0, [], msg="off the panel")
  assert_true(service_pages.contains(service_key("ws1/st1", "j-web")), msg="its page kept")
  assert_eq(service_site_id("j-web"), site, msg="the same site view")
  assert_true(!t.views().contains("close \{site}"), msg="never closed")
  // its title the job's name as the core says it, in place of the word it was opened with
  let title = t.window_title(wid~)
  assert_true(title != "" && title != @sfbase.svc("android-chat.preview.service"), msg="its title: \{title}")
  // drawn there alone: its bar and its page in the window, nothing of it in the first
  let there = Ref((0, 0))
  t.in_window(wid, fn() {
    there.val = (t.all(Button, label="刷新").length(), t.holes().length())
  })
  assert_eq(there.val.0, 1, msg="its bar in the window")
  assert_true(there.val.1 > 0, msg="its page drawn in the window")
  assert_eq(t.all(Button, label="刷新").length(), 0, msg="none of its bar in the first window")
  let audit = Ref([])
  t.in_window(wid, fn() { audit.val = t.audit() })
  assert_eq(audit.val, [], msg="the window at 960 × 720: \{Repr(audit.val)}")
  // its link followed again: that window to the front, the panel not opened on it here
  app.nav.push(Service("ws1/st1", "j-web"))
  t.frame()
  t.frame()
  t.run_for(@ui.move_most_ms)
  assert_eq(t.windows_beside().length(), 1, msg="never a second window")
  assert_eq(t.window_ids_fronted(), [wid])
  assert_eq(side_now(r).0, [], msg="the panel not opened on it")
  assert_eq(t.all(Button, label="刷新").length(), 0, msg="none of its bar in the first window still")
  // 移到侧边 there: back in the panel, in front, the window closed; the same site view, opened once, never closed
  let pressed = Ref(false)
  t.in_window(wid, fn() {
    match t.query(Button, label=@sf.t("web-main.preview.moveBeside")) {
      Some(b) => {
        pressed.val = true
        t.tap(b.rect.0 + b.rect.2 / 2.0, b.rect.1 + b.rect.3 / 2.0)
      }
      None => ()
    }
  })
  assert_true(pressed.val, msg="移到侧边 in the window's bar")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.windows_beside().length(), 0, msg="the window closed")
  assert_eq(side_now(r), (["service:j-web"], "service:j-web"), msg="back in the panel, in front")
  assert_eq(service_site_id("j-web"), site, msg="the same site view again")
  assert_eq(opened(), 1, msg="opened once")
  assert_true(!t.views().contains("close \{site}"), msg="never closed")
  assert_eq(t.all(Button, label="刷新").length(), 1, msg="its bar beside the chat again")
  assert_true(t.holes().length() > 0, msg="its page drawn beside the chat again")
}

///|
test "desk: a web service in a window of its own on a Mac and on Windows, its buttons in its top row, at 960 × 720 and at its least 420 × 320: its page's own bar the window's one bar, 移到侧边 at its end, Windows' own buttons on its line after it; nothing the audit finds" {
  for platform in [0, 3] {
    let at = "platform \{platform}"
    new_run()
    let src = fixture("chat-info")
    let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
    open_chat(r)
    let t = @ui.Tester::new(
      fn(c) { view(c, src) },
      tree=app_tree(src),
      w=1440.0,
      h=900.0,
      platform~,
      window_inset=true,
      window_corner=if platform == 3 { 8.0 } else { 16.0 },
    )
    t.set_window_opens(true)
    t.set_windows_in_process(true)
    t.run_for(@ui.move_most_ms)
    app.nav.push(Service("ws1/st1", "j-web"))
    t.frame()
    t.frame()
    t.run_for(@ui.move_most_ms)
    t.click(Button, label=@sf.t("web-pages.screen.window"))
    t.run_for(@ui.move_most_ms)
    assert_eq(t.windows_beside().length(), 1, msg=at)
    let wid = t.windows_beside()[0].0
    // one bar: its page's, 刷新 in it, 移到侧边 at its end, no viewer's bar over it
    let bar = Ref((0, 0, None))
    t.in_window(wid, fn() {
      bar.val = (
        t.all(Button, label="刷新").length(),
        t.all(Button, label=@sf.t("web-main.preview.moveBeside")).length(),
        t.query(Button, label=@sf.t("web-main.preview.moveBeside")).map(fn(n) { n.rect }),
      )
    })
    assert_eq((bar.val.0, bar.val.1), (1, 1), msg="\{at}: one bar, its page's")
    let audit = Ref([])
    t.in_window(wid, fn() { audit.val = t.audit() })
    assert_eq(audit.val, [], msg="\{at}, 960 × 720: \{Repr(audit.val)}")
    // 移到侧边 under the pointer, lit: round as the window's corner is, concentric with it
    let (mx, my, mw, mh) = bar.val.2.unwrap()
    let lit = Ref([])
    t.in_window(wid, fn() { t.move_to(mx + mw / 2.0, my + mh / 2.0) })
    t.run_for(@ui.move_most_ms)
    t.in_window(wid, fn() { lit.val = t.corner_faults() })
    assert_eq(lit.val, [], msg="\{at}: 移到侧边 lit: \{Repr(lit.val)}")
    if platform == 3 {
      let (bx, by, bw, bh) = bar.val.2.unwrap()
      for key in ["desktop.menu.minimize", "desktop.window.maximize", "desktop.menu.close"] {
        let k = Ref(None)
        t.in_window(wid, fn() { k.val = t.query(Button, label=@sf.t(key)).map(fn(n) { n.rect }) })
        match k.val {
          Some((kx, ky, _, kh)) => {
            assert_true(((ky + kh / 2.0) - (by + bh / 2.0)).abs() < 1.0, msg="\{at}: \{key} on 移到侧边's line")
            assert_true(kx >= bx + bw, msg="\{at}: \{key} after 移到侧边")
          }
          None => fail("\{at}: no \{key}")
        }
      }
    }
    t.set_window_beside_size(wid, 420.0, 320.0)
    t.run_for(@ui.move_most_ms)
    t.in_window(wid, fn() { audit.val = t.audit() })
    assert_eq(audit.val, [], msg="\{at}, 420 × 320: \{Repr(audit.val)}")
  }
}
