// Collapsible project/folder drawers (project_drawers.mbt, sidebar_node.mbt, new_chat_node.mbt):
// grouping order, folder hint extraction, collapse/expand persistence, quick "+" new-chat with preset auto-match,
// zero `projects` topic read when drawers are off, and layout/target audits across widths, scales, and languages.

///|
fn drawer_test_chat(
  id : String,
  title : String,
  project? : Json = Json::null(),
  pinned? : Bool = false,
  unread? : Bool = false,
  tone? : String = "",
) -> Json {
  let m : Map[String, Json] = {
    "id": Json::string(id),
    "session": Json::string(id),
    "thread": Json::number(10.0),
    "title": Json::string(title),
    "unread": Json::boolean(unread),
    "station": Json::string("ws1/st1"),
    "stationName": Json::string("Studio"),
    "pinned": Json::boolean(pinned),
    "agents": [{ "key": Json::string(id), "runtime": "claude", "maker": { "id": "anthropic" } }],
  }
  if tone != "" {
    m["tone"] = Json::string(tone)
  }
  if !(project is Null) {
    m["project"] = project
  }
  Json::object(m)
}

///|
fn drawer_test_source(
  drawers_on : @signals.Signal[Bool],
  projects_reads : Ref[Int],
  calls : Array[(String, Json)],
) -> Source {
  let ws_chats : Json = {
    "stations": [{ "station": "ws1/st1", "name": "Studio", "online": true }],
    "days": [
      {
        "daysAgo": -1,
        "label": "已固定",
        "items": [drawer_test_chat("c-pin", "发布检查清单", project=Json::string("monoid"), pinned=true)],
      },
      {
        "daysAgo": 0,
        "label": "今天",
        "items": [
          drawer_test_chat("c-1", "侧边栏项目抽屉", project=Json::string("monoid"), unread=true, tone="busy"),
          drawer_test_chat("c-2", "部署网关配置", project=Json::string("infra"), tone="alert"),
          drawer_test_chat("c-3", "跨仓库重构", project=Json::string("")),
          drawer_test_chat("c-4", "临时提问"),
        ],
      },
    ],
    "leading": "agents",
  }
  let projects_json : Json = {
    "supported": true,
    "projects": [
      { "name": "monoid", "note": "主仓库", "refs": ["studio:~/code/monoid", "https://github.com/acme/monoid"] },
      { "name": "infra", "note": "运维配置", "refs": ["studio:~/work/k8s-infra"] },
      { "name": "docs", "note": "文档站点", "refs": ["studio:~/docs/site"] },
    ],
  }
  let new_chat_json : Json = {
    "preset": "",
    "presets": [
      { "id": "pre-monoid", "name": "Monoid", "station": "ws1/st1", "dirName": "monoid", "summary": "monoid" },
    ],
  }
  let collapsed_pref : @signals.Signal[String] = @signals.signal("")
  {
    ..@sfbase.sample_source,
    topic_read: fn(name, _params) -> @sfbase.Topic {
      match name {
        "prefs" => {
          let p : Map[String, Json] = Map([])
          if drawers_on.get() {
            p["chatDrawers"] = Json::string("on")
          }
          let c = collapsed_pref.get()
          if c != "" {
            p["drawerCollapsed"] = { "ws1": Json::string(c) }
          }
          { value: Some(Json::object(p)), error: None, version: 1 }
        }
        "chats" => { value: Some(ws_chats), error: None, version: 1 }
        "projects" => {
          projects_reads.val += 1
          { value: Some(projects_json), error: None, version: 1 }
        }
        "newChat" => { value: Some(new_chat_json), error: None, version: 1 }
        _ => { value: None, error: None, version: 0 }
      }
    },
    call: fn(name, params, done) {
      calls.push((name, params))
      if name == "prefs.set" {
        match field(field(Some(params), "drawerCollapsed"), "ws1") {
          Some(String(s)) => collapsed_pref.set(s)
          Some(Null) => collapsed_pref.set("")
          _ => ()
        }
      }
      done(Ok(Json::object(Map([]))))
    },
  }
}

///|
test "folder_hint_of prefers local folder paths, strips station prefix, and omits identical name" {
  assert_eq(folder_hint_of("monoid", ["studio:~/code/monoid"]), "")
  assert_eq(folder_hint_of("核心仓库", ["studio:~/code/monoid/"]), "monoid")
  assert_eq(folder_hint_of("infra", ["https://github.com/acme/ops", "mac:/Users/dev/k8s-infra"]), "k8s-infra")
  assert_eq(folder_hint_of("docs", ["https://github.com/acme/handbook.git"]), "handbook")
  assert_eq(folder_hint_of("empty", []), "")
}

///|
test "group_into_drawers orders pinned, active projects by recency, empty projects on all, cross, and unclassified" {
  @sfbase.reset()
  @sf.set_words(@sfbase.fill)
  let days : Array[ChatDay] = [
    {
      label: "已固定",
      items: [@sfbase.chat_item(drawer_test_chat("p1", "置顶", project=Json::string("alpha"), pinned=true))],
    },
    {
      label: "今天",
      items: [
        @sfbase.chat_item(drawer_test_chat("b1", "Beta 任务", project=Json::string("beta"), unread=true, tone="wait")),
        @sfbase.chat_item(drawer_test_chat("a1", "Alpha 任务", project=Json::string("alpha"), tone="alert")),
        @sfbase.chat_item(drawer_test_chat("x1", "跨项目任务", project=Json::string(""))),
        @sfbase.chat_item(drawer_test_chat("u1", "未归类任务")),
      ],
    },
  ]
  let projects : Array[@sfbase.ProjectInfo] = [
    { name: "alpha", note: "A", refs: ["st:~/repos/core-alpha"] },
    { name: "gamma", note: "Empty", refs: ["st:~/repos/gamma-dir"] },
  ]
  let with_empty = group_into_drawers(days, projects, true)
  assert_eq(
    with_empty.map(fn(s) { s.key }),
    ["pinned", "p:beta", "p:alpha", "p:gamma", "cross", "unclassified"],
  )
  assert_eq(with_empty[2].folder_hint, "core-alpha")
  assert_eq(with_empty[2].alert_count, 1)
  assert_eq(with_empty[1].unread_count, 1)
  assert_eq(with_empty[1].wait_count, 1)

  let without_empty = group_into_drawers(days, projects, false)
  assert_eq(without_empty.map(fn(s) { s.key }), ["pinned", "p:beta", "p:alpha", "cross", "unclassified"])

  let collapsed : Set[String] = Set(["p:beta"])
  let keys = drawer_keys(without_empty, collapsed)
  assert_true(keys.contains("d/p:beta"))
  assert_true(!keys.contains("r/ws1/st1/b1"))
  assert_true(keys.contains("r/ws1/st1/a1"))
}

///|
test "sidebar project drawers: lazy projects read when off, toggle collapse/expand, quick new-chat, and clean audit" {
  let cases : Array[(Double, Int, Double, String, @sf.ListAt)] = [
    (320.0, 0, 1.0, "zh", Side),
    (390.0, 1, 1.0, "zh", Whole),
    (390.0, 1, 1.3, "zh", Whole),
    (320.0, 0, 1.0, "en", Side),
  ]
  for c in cases {
    let (w, platform, scale, lang, list_at) = c
    let at = "\{w} platform \{platform} scale \{scale} lang \{lang}"
    @sfbase.reset()
    sidebar_reset()
    @sf.set_language(Some(lang))
    @sf.set_words(@sfbase.fill)
    let drawers_on = @signals.signal(false)
    let projects_reads = Ref(0)
    let calls : Array[(String, Json)] = []
    let src = drawer_test_source(drawers_on, projects_reads, calls)
    let ws : Workspace = { id: "ws1", name: "WS", emoji: "", icon: "", email: "a@x.com" }
    let t = @ui.Tester::new(fn(ctx) { @sf.begin(ctx) |> ignore }, w~, h=900.0, platform~, scale~)
    @ui.set_view_app(fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let popup = root.box(fn(v) { v.over(Is(true)) |> ignore })
      let tips = @sf.TipLayer::new(fn() { Some(popup) })
      let frame : ListsNodeFrame = {
        top: fn() { 0.0 },
        under: fn() { 0.0 },
        foot: fn() { 0.0 },
        ground: fn() { @sf.theme().p.sidebar },
        before: fn(_, _) { [] },
        after: fn(_, _) { [] },
        others: [],
        shown: fn() { 0 },
        at: list_at,
        watched: fn() { true },
      }
      chats_lists_node(root, src, fn() { Some(ws) }, frame, tips, fn() { 0 })
    })
    t.draw()
    // Drawers off: original date headings, zero `projects` topic reads.
    assert_eq(projects_reads.val, 0, msg="\{at}: must not subscribe to projects when drawers are off")
    assert_true(t.find("今天") is Some(_), msg="\{at}: date heading shown when drawers off")

    // Turn drawers on: project drawers appear immediately without restart.
    drawers_on.set(true)
    t.run_for(@ui.move_most_ms)
    assert_true(projects_reads.val > 0, msg="\{at}: projects read when drawers enabled")
    assert_true(t.find("今天") is None, msg="\{at}: date heading hidden in drawer mode")
    assert_true(t.find("monoid") is Some(_), msg="\{at}: named project drawer shown")
    assert_true(t.find("k8s-infra") is Some(_), msg="\{at}: folder hint shown when distinct from name")
    assert_true(t.find("侧边栏项目抽屉") is Some(_), msg="\{at}: chat row shown inside expanded drawer")
    let faults_open = t.audit()
    assert_eq(faults_open, [], msg="\{at} expanded audit: \{Repr(faults_open)}")

    // Collapse "monoid" drawer: hides its chat row and persists prefs.set { drawerCollapsed }.
    let collapse_lbl = @sf.t("web-main.drawers.collapse", args=[("name", "monoid")])
    t.click(Button, label=collapse_lbl)
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("侧边栏项目抽屉") is None, msg="\{at}: chat hidden after collapsing monoid drawer")
    assert_true(
      calls.iter().any(fn(c) { c.0 == "prefs.set" && field(field(Some(c.1), "drawerCollapsed"), "ws1") is Some(String(_)) }),
      msg="\{at}: collapse persisted in prefs.drawerCollapsed",
    )
    let faults_closed = t.audit()
    assert_eq(faults_closed, [], msg="\{at} collapsed audit: \{Repr(faults_closed)}")

    // Expand "monoid" drawer again: chat row returns.
    let expand_lbl = @sf.t("web-main.drawers.expand", args=[("name", "monoid")])
    t.click(Button, label=expand_lbl)
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("侧边栏项目抽屉") is Some(_), msg="\{at}: chat restored after expanding monoid drawer")

    // Quick "+" on "monoid" drawer sets project, auto-picks matching preset, and opens NewChat.
    let new_lbl = @sf.t("web-main.drawers.newChat", args=[("project", "monoid")])
    t.click(Button, label=new_lbl)
    t.draw()
    assert_eq(@sfbase.new_chat_project_of("ws1"), Some("monoid"), msg="\{at}: new chat project set")
    assert_true(app.nav.top() == NewChat, msg="\{at}: navigated to NewChat")
    assert_true(
      calls.iter().any(fn(c) { c.0 == "newChat.pick" && text(Some(c.1), "preset") == "pre-monoid" }),
      msg="\{at}: matching preset auto-picked",
    )
  }
  @sf.set_language(Some("zh"))
}

///|
test "new_chat_project_pill_node shows selected project and clears on close button" {
  @sfbase.reset()
  @sf.set_language(Some("zh"))
  @sf.set_words(@sfbase.fill)
  @sfbase.set_new_chat_project("ws1", Some("monoid"))
  let t = @ui.Tester::new(fn(ctx) { @sf.begin(ctx) |> ignore }, w=390.0, h=200.0, platform=1)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    let popup = root.box(fn(v) { v.over(Is(true)) |> ignore })
    let tips = @sf.TipLayer::new(fn() { Some(popup) })
    new_chat_project_pill_node(root, "ws1", tips)
  })
  t.draw()
  assert_true(t.find("所属项目：monoid") is Some(_))
  let faults = t.audit()
  assert_eq(faults, [], msg="pill audit: \{Repr(faults)}")
  t.click(Button, label="取消指定项目")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.new_chat_project_of("ws1"), None)
  assert_true(t.find("所属项目：monoid") is None)
}
