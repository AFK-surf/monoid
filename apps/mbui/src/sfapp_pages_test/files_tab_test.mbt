// A chat's 文件 tab (src/sfdesk/drive_tab_node.mbt) drawn alone in a box of a side panel's width, over the fixture.

///|
fn tab_tester(calls : Array[Made], platform? : Int = 0) -> @ui.Tester {
  fresh_app()
  let base = fixture("home")
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      calls.push({ name, params, bytes: None, done })
      (base.call)(name, params, done)
    },
  }
  let w : Workspace = { id: "ws1", name: "星火工作室", emoji: "", icon: "", email: "" }
  @sf.set_words(fill)
  @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.row(Is(true)) |> ignore
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      root.box(fn(pane) {
        pane.width(Is(Some(480.0))).height(Is(Some(800.0))) |> ignore
        @sfdesk.files_tab_node(pane, src, w.id, "s-c1", "ws1/st1", fn() { @ui.css("pb=S4") }, tips)
      })
      |> ignore
      root.box(fn(drop_zone) {
        drop_zone.grow(Is(1.0)).height(Is(Some(800.0))).ground(By(fn() { @sf.theme().p.bg })) |> ignore
        @sfdesk.chat_drop_node(drop_zone, src, "s-c1", fn() { "ws1/st1" }, fn() { None }, fn() { true })
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w=1280.0,
    h=800.0,
    platform~,
    // fixture("home") routes all topic reads through one global fixture_changes signal
    fanout_limit=0,
  )
}

///|
test "a chat's 文件 tab (DriveTab.tsx): at the chat's station's home, the trail over it; the places from its first step; a folder gone into" {
  let calls : Array[Made] = []
  let t = tab_tester(calls)
  t.frame()
  t.frame()
  // the home: its trail (Willow › 主目录), its folders in a list
  assert_true(t.query(Link, label="Willow") is Some(_))
  assert_true(t.find("主目录") is Some(_))
  assert_true(t.find("文档") is Some(_))
  // the places: 个人收藏, each station's home, its folders and disks, and its pinned folders
  t.click(Link, label="Willow")
  t.frame()
  assert_true(t.find("照片") is Some(_), msg="Maple's pinned folder")
  assert_true(t.find("离线") is Some(_), msg="Maple away")
  // (文档 is among 个人收藏 too: the station's own, the later of the two)
  let (px, py, pw, ph) = t.all(Link, label="文档").last().unwrap().rect
  t.tap(px + pw / 2.0, py + ph / 2.0)
  t.frame()
  // 文档 (of the station's places): its rows; a folder pressed: gone into
  assert_true(t.find("长篇小说.txt") is Some(_))
  let (x, y) = t.find("设计稿").unwrap()
  t.tap(x, y)
  t.frame()
  t.frame()
  assert_true(t.find("图标.png") is Some(_), msg="设计稿 gone into: " + t.words().map(fn(w) { w.0 }).join("|"))
  match @sfdesk.tab_place("ws1") {
    Some(Some(at)) => assert_eq(at.path, "设计稿")
    _ => fail("the tab not in 设计稿")
  }
}

///|
test "a chat's 文件 tab: a row's menu puts it into the chat's message (添加到消息) or copies its path; a row dragged off it is let go for the composer" {
  let calls : Array[Made] = []
  let t = tab_tester(calls)
  @sfdesk.tab_place_set("ws1", Some({ station: "ws1/st1", root: Some(fix_docs), path: "" }))
  // (the folder asked of the made-up core on the first frame, its rows on the next)
  t.frame()
  t.frame()
  let (x, y) = t.find("发布清单.md").unwrap()
  t.right_click(x, y)
  t.run_for(@motion.presence_in_ms)
  t.tap_text("添加到消息")
  t.frame()
  let sent = @sfbase.files_taken("s-c1")
  assert_eq(sent.length(), 1)
  assert_eq(sent[0].abs, fix_docs + "/发布清单.md")
  let (x, y) = t.find("长篇小说.txt").unwrap()
  t.right_click(x, y)
  t.run_for(@motion.presence_in_ms)
  t.tap_text("复制路径")
  t.frame()
  assert_eq(t.clipboard(), fix_docs + "/长篇小说.txt")
  // dragged off the tab onto the chat drop zone: dropped into the chat's draft
  let (x, y) = t.find("首页截图.png").unwrap()
  t.drag(x, y, 900.0, 600.0)
  t.frame()
  let added = calls.filter(fn(m) { m.name == "composer.add" })
  assert_true(added.length() > 0, msg="dropped onto chat: composer.add not called")
  let files = items(Some(added[0].params), "files")
  assert_eq(text(files.get(0), "name"), "首页截图.png")
}

///|
test "a chat's 文件 tab, the same on a touch device and on a computer: the places, a folder gone into, a file picked by a press, the folder as a whole at its top, 添加 n putting them into the chat's message" {
  for platform in [2, 0] {
    let calls : Array[Made] = []
    let t = tab_tester(calls, platform~)
    @sfdesk.tab_place_set("ws1", None)
    t.frame()
    // the places: each station a section, its home and its pinned folders a row each
    assert_true(t.find("照片") is Some(_), msg="Maple's pinned folder: \{platform}")
    t.tap_text("文档")
    t.frame()
    t.frame()
    assert_true(t.find("整个文件夹") is Some(_), msg="\{platform} " + t.words().map(fn(w) { w.0 }).join("|"))
    // a file pressed: picked (again: no longer), then 添加 1 个
    t.tap_text("发布清单.md")
    t.frame()
    t.tap_text("添加 1 个")
    t.frame()
    let sent = @sfbase.files_taken("s-c1")
    assert_eq(sent.length(), 1, msg="\{platform}")
    assert_eq(sent[0].abs, fix_docs + "/发布清单.md")
    assert_false(sent[0].dir)
  }
}

///|
test "a chat's 文件 tab: its places as the files' sidebar has them: 个人收藏, each station's home, the home's folders and its disks, then what it pins" {
  let calls : Array[Made] = []
  let t = tab_tester(calls)
  let kept : Json = [{ "station": "ws1/st1", "root": Json::string(fix_docs), "path": "设计稿", "name": "设计稿" }]
  fix_browse_prefs_set({ "driveFavorites": { "ws1": Json::string(kept.stringify()) } }) |> ignore
  @sfdesk.tab_place_set("ws1", None)
  // (the station's places asked of the made-up core on the first frame, its rows on the next)
  t.frame()
  t.frame()
  assert_true(named(calls, "drive.folders").length() > 0)
  assert_true(t.find("个人收藏") is Some(_))
  assert_true(t.find("设计稿") is Some(_), msg="the favourite")
  assert_true(t.find("外接硬盘") is Some(_), msg="Studio's disk")
  assert_true(t.find("下载") is Some(_), msg="a folder of Studio's home")
  assert_true(t.find("备份盘") is Some(_), msg="Studio's pinned folder not among its places")
  assert_true(t.find("照片") is Some(_), msg="MBA's pinned folder")
  // a favourite pressed: the tab in it
  t.tap_text("设计稿")
  t.frame()
  t.frame()
  assert_true(t.find("图标.png") is Some(_), msg=t.words().map(fn(w) { w.0 }).join("|"))
  // a disk pressed: the tab at its top
  @sfdesk.tab_place_set("ws1", None)
  t.frame()
  t.tap_text("外接硬盘")
  t.frame()
  match @sfdesk.tab_place("ws1") {
    Some(Some(at)) => assert_eq(at.root, Some("/Volumes/外接硬盘"))
    _ => fail("the tab not at the disk")
  }
}

///|
test "a chat's 文件 tab: folder error shows title, wrapping explanation and Retry button inside the pane" {
  fresh_app()
  let calls : Array[Made] = []
  let why = "这台 Mac 尚未允许 still.fail Helper 访问「文稿」。已在该 Mac 上弹出授权窗口，点击「允许」即可打开。"
  let base = @sffixture.failed_topics(fixture("home"), ["drive"], why)
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      calls.push({ name, params, bytes: None, done })
      (base.call)(name, params, done)
    },
  }
  let w : Workspace = { id: "ws1", name: "星火工作室", emoji: "", icon: "", email: "" }
  @sf.set_words(fill)
  @sfdesk.tab_place_set("ws1", Some({ station: "ws1/st1", root: Some(fix_docs), path: "" }))
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.row(Is(true)) |> ignore
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      root.box(fn(pane) {
        pane.width(Is(Some(360.0))).height(Is(Some(640.0))) |> ignore
        @sfdesk.files_tab_node(pane, src, w.id, "s-c1", "ws1/st1", fn() { @ui.css("pb=S4") }, tips)
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w=360.0,
    h=640.0,
    fanout_limit=0,
  )
  t.frame()
  t.frame()
  assert_eq(t.audit(), [])
  assert_eq(t.first_line_faults(), [])
  assert_eq(t.line_start_faults(), [])
  let (_, ty) = t.find("无法打开此文件夹").unwrap()
  let (_, wy) = t.find("still.fail Helper").unwrap()
  let retry = t.query(Button, label="重试").unwrap()
  let (rx, ry, rw, rh) = retry.rect
  assert_true(ty < wy && wy < ry, msg="tab error order: title=\{ty} why=\{wy} retry=\{ry}")
  assert_true(rx >= 0.0 && rx + rw <= 360.0 && ry + rh <= 640.0, msg="tab retry inside pane: \{rx},\{ry},\{rw},\{rh}")
  t.click(Button, label="重试")
  t.frame()
  assert_true(named(calls, "drive.refresh").length() > 0, msg="tab retry triggers drive.refresh")
}
