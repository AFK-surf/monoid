// End-to-end app integration tests for Workstream 2:
// - Wide desktop funnel -> tag search -> pick -> return -> project pick -> close/reopen lease zero
// - Wide board filter key anchor stability while toggling filters
// - Native control ("sidebar/filter") menu=[], dot sync, toggle open/close
// - Archive mode hides fixed filter bar & restores height; scope click returns to chats
// - 240px sidebar / 320px small screen / 1.3x font scale / 80-char project name audit clean

///|
fn fp_app_topic_key(name : String, params : Map[String, Json]) -> String {
  let q = match params.get("q") {
    Some(String(s)) => s
    _ => ""
  }
  let cur = match params.get("cursor") {
    Some(String(c)) => c
    _ => ""
  }
  name + "|" + q + "|" + cur
}

///|
fn fp_app_source(
  mode : String,
  projects : Array[Json],
  tags : Array[Json],
  active_subs : Map[String, Bool],
) -> Source {
  let base = fixture(mode)
  {
    ..base,
    topic_read: fn(name, params) {
      if name == "chats" {
        let base_st = (base.topic_read)(name, params)
        match base_st.value {
          Some(Object(m)) => {
            let copy = m.copy()
            copy["projects"] = Json::boolean(true)
            copy["projectsWritable"] = Json::boolean(true)
            { ..base_st, value: Some(Json::object(copy)) }
          }
          _ => base_st
        }
      } else if name == "projects" {
        active_subs[fp_app_topic_key(name, params)] = true
        let q = match params.get("q") {
          Some(String(s)) => s.to_lower()
          _ => ""
        }
        let filtered = projects.filter(fn(item) {
          q == "" || text(Some(item), "name").to_lower().contains(q)
        })
        {
          value: Some({ "items": Json::array(filtered), "total": Json::number(filtered.length().to_double()), "unclassifiedCount": 1.0 }),
          error: None,
          version: 1,
        }
      } else if name == "tags" {
        active_subs[fp_app_topic_key(name, params)] = true
        let q = match params.get("q") {
          Some(String(s)) => s.to_lower()
          _ => ""
        }
        let filtered = tags.filter(fn(item) {
          q == "" || text(Some(item), "name").to_lower().contains(q)
        })
        {
          value: Some({ "items": Json::array(filtered), "total": Json::number(filtered.length().to_double()) }),
          error: None,
          version: 1,
        }
      } else {
        (base.topic_read)(name, params)
      }
    },
    release: fn(name, params) {
      if name == "projects" || name == "tags" {
        active_subs.remove(fp_app_topic_key(name, params))
      }
      (base.release)(name, params)
    },
  }
}

///|
test "wide desktop funnel -> tag search -> filter & pick -> return -> project pick -> close releases leases" {
  new_run()
  let subs : Map[String, Bool] = Map([])
  let src = fp_app_source(
    "home",
    [
      { "name": "monoid", "chatCount": 10.0, "latestActiveAt": 500.0 },
      { "name": "Pion", "chatCount": 4.0, "latestActiveAt": 400.0 },
    ],
    [
      { "name": "ios", "chatCount": 5.0, "latestActiveAt": 500.0 },
      { "name": "ui-review", "chatCount": 3.0, "latestActiveAt": 400.0 },
      { "name": "board", "chatCount": 2.0, "latestActiveAt": 300.0 },
    ],
    subs,
  )
  open_fixture_over("home", src)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  assert_eq(subs.length(), 0)
  // Click sidebar funnel button
  t.click(Button, label=@sf.t("web-main.filter.chats.named", args=[("named", @sf.t("web-main.filter.all"))]))
  t.run_for(@ui.move_most_ms)
  assert_true(@sfpages.filter_menu_open())
  assert_true(subs.length() > 0)
  // Step into "更多标签"
  t.click(Button, label=@sf.t("web-main.projects.more_tags"))
  t.run_for(@ui.move_most_ms)
  assert_eq(@sf.panel_depth(), 2)
  // Type "ui" into search field and pick "#ui-review"
  t.click(TextField, label=@sf.t("web-pages.projects.search_tags_placeholder"))
  t.type_text("ui")
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="#ui-review") is Some(_))
  assert_true(t.query(Button, label="#ios") is None)
  t.click(Button, label="#ui-review")
  t.run_for(@ui.move_most_ms)
  // Returned to main panel (depth == 1) and tag filter applied
  assert_eq(@sfbase.tag_filter_of("ws1"), Some("ui-review"))
  assert_eq(@sf.panel_depth(), 1)
  // Pick project "monoid" directly from main panel
  t.click(Button, label="monoid")
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.project_filter_of("ws1") == Named("monoid"))
  // Close via Escape -> leases return to 0
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_false(@sfpages.filter_menu_open())
  assert_eq(subs.length(), 0)
  // Fixed filter bar shows both compact 28pt pills with concentric clear buttons
  assert_true(t.query(Button, label=@sf.t("web-main.projects.clear_project_filter")) is Some(_))
  assert_true(t.query(Button, label=@sf.t("web-main.projects.clear_tag_filter")) is Some(_))
  // Reopen & close -> leases still return to 0
  let narrowed_label = @sf.t("web-main.filter.chats.named", args=[("named", "monoid, #ui-review")])
  t.click(Button, label=narrowed_label)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfpages.filter_menu_open())
  assert_true(subs.length() > 0)
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_eq(subs.length(), 0)
}

///|
test "wide board filter key stays stable when toggling filters inside panel" {
  new_run()
  let subs : Map[String, Bool] = Map([])
  let src = fp_app_source(
    "board",
    [{ "name": "monoid", "chatCount": 5.0, "latestActiveAt": 500.0 }],
    [{ "name": "ios", "chatCount": 3.0, "latestActiveAt": 400.0 }],
    subs,
  )
  open_fixture_over("board", src)
  @sfbase.board_feature.set(true)
  @sfbase.board_set(src, true)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1440.0, h=900.0, platform=0)
  t.run_for(@ui.move_most_ms)
  let before = t.query(Button, label=@sf.t("web-main.filter.chats.named", args=[("named", @sf.t("web-main.filter.all"))]))
  guard before is Some(btn_before) else { fail("no board filter key") }
  t.click(Button, label=btn_before.label)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfpages.filter_menu_open())
  // Toggle project filter inside open panel -> button node ID must remain identical and panel stays open
  t.click(Button, label="monoid")
  t.run_for(@ui.move_most_ms)
  assert_true(@sfpages.filter_menu_open())
  let expected_label = "monoid"
  // While the modal panel is open, the anchor behind it is inert/hidden in accessibility,
  // yet its underlying node must remain alive with the exact same NodeId and updated label.
  let same_alive = t.semantics().iter().any(fn(s) { s.id == btn_before.id && s.label == expected_label })
  assert_true(same_alive, msg="board filter anchor node destroyed or label not updated while panel open")
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_eq(subs.length(), 0)
  let after = t.query(Button, label=expected_label)
  guard after is Some(btn_after) else { fail("board filter key missing after closing panel") }
  assert_eq(btn_before.id, btn_after.id)
}

///|
test "native sidebar/filter uses menu=[], tracks dot, and toggles chats_view_panel open/close" {
  new_run()
  let subs : Map[String, Bool] = Map([])
  let src = fp_app_source(
    "chat",
    [{ "name": "monoid", "chatCount": 5.0, "latestActiveAt": 500.0 }],
    [{ "name": "ios", "chatCount": 3.0, "latestActiveAt": 400.0 }],
    subs,
  )
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=951.0, h=669.0, platform=1, nav_able=true)
  t.post(@hostapi.system_channel, "{\"bars\":{\"top\":0,\"bottom\":20,\"left\":0,\"right\":84}}")
  t.run_for(@ui.move_most_ms)
  let said0 = t.nav_said()
  let filter_item = fn(raw : String) -> Json? {
    let parsed : Json? = try Some(@json.parse(raw)) catch { _ => None }
    match parsed {
      Some(Object(m)) =>
        match m.get("floating") {
          Some(Array(arr)) => {
            for entry in arr {
              let item = field(Some(entry), "item")
              if text(item, "id") == "sidebar/filter" {
                return item
              }
            }
            None
          }
          _ => None
        }
      _ => None
    }
  }
  let f0 = filter_item(said0)
  assert_true(f0 is Some(_), msg="missing sidebar/filter in nav_said: \{said0}")
  assert_eq(items(f0, "menu").length(), 0, msg="sidebar/filter must send empty menu[] when projects enabled")
  assert_false(flag(f0, "dot"), msg="sidebar/filter dot must be false when unfiltered")
  // Tap native sidebar/filter -> opens chats_view_panel
  t.post(@hostapi.system_channel, "{\"nav\":\"sidebar/filter\"}")
  t.run_for(@ui.move_most_ms)
  assert_true(@sfpages.filter_menu_open())
  assert_true(@sfpages.filter_menu_accepting())
  // Tap native sidebar/filter again -> closes chats_view_panel
  t.post(@hostapi.system_channel, "{\"nav\":\"sidebar/filter\"}")
  t.run_for(@ui.move_most_ms)
  assert_false(@sfpages.filter_menu_open())
  assert_eq(subs.length(), 0)
  // Applying a project filter turns dot on specifically for sidebar/filter
  @sfbase.set_project_filter("ws1", Named("monoid"))
  t.run_for(@ui.move_most_ms)
  let f1 = filter_item(t.nav_said())
  assert_true(flag(f1, "dot"), msg="sidebar/filter dot must turn true when project filter active: " + t.nav_said())
}

///|
test "wide projects-on: switching to archive and immediately reopening funnel next frame switches back to mine (Astra B1)" {
  new_run()
  let subs : Map[String, Bool] = Map([])
  let src = fp_app_source(
    "home",
    [{ "name": "monoid", "chatCount": 5.0, "latestActiveAt": 500.0 }],
    [],
    subs,
  )
  open_fixture_over("home", src)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  let (fx, fy, fw, fh) = t.query(Button, label="筛选会话：全部").unwrap().rect
  t.tap(fx + fw / 2.0, fy + fh / 2.0)
  t.frame()
  t.tap_text("已归档")
  t.frame()
  assert_eq(@sfdesk.side_place(), "archive")
  // Immediately tap funnel on the very next frame (while previous panel is still exiting)
  let (fx2, fy2, fw2, fh2) = t.query(Button, label="筛选会话：已归档").unwrap().rect
  t.tap(fx2 + fw2 / 2.0, fy2 + fh2 / 2.0)
  t.frame()
  assert_true(@sfpages.filter_menu_accepting(), msg="funnel tap during exit must reopen archive panel")
  t.tap_text("我参与的")
  t.frame()
  assert_eq(@sfdesk.lit_place(), "chats")
}

///|
test "small screen 320px at 1.3x font scale with 80-char project name has zero filter bar audit faults" {
  new_run()
  let subs : Map[String, Bool] = Map([])
  let long_name = "超长项目名称测试".repeat(10)
  let src = fp_app_source(
    "home",
    [{ "name": Json::string(long_name), "chatCount": 5.0, "latestActiveAt": 500.0 }],
    [{ "name": "ui-review", "chatCount": 3.0, "latestActiveAt": 400.0 }],
    subs,
  )
  open_fixture_over("home", src)
  @sfbase.set_project_filter("ws1", Named(long_name))
  @sfbase.set_tag_filter("ws1", Some("ui-review"))
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=320.0, h=640.0, platform=2)
  defer t.set_font_scale(1.0)
  t.set_font_scale(1.3)
  t.run_for(@ui.move_most_ms)
  let bar_faults = t.audit().filter(fn(f) { f.contains("sidebar.mbt") || f.contains("home_node.mbt") || f.contains("filter_pill_node") })
  assert_eq(bar_faults, [])
}
