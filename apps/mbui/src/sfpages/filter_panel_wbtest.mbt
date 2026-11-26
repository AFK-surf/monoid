// Unit & UI tests for Workstream 2: chats_view_panel, searchable project/tag pickers,
// active_filter_bar_node, grouped collapse hook, and lease lifecycle.

///|
fn fp_topic_key(name : String, params : Map[String, Json]) -> String {
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
fn fp_source_with_leases(
  projects : Array[Json],
  tags : Array[Json],
  active_subs : Map[String, Bool],
  proj_error? : Ref[String?] = Ref(None),
  has_more_projects? : Bool = false,
) -> Source {
  let base = @sffixture.fixture("home")
  let tick : @signals.Signal[Int] = @signals.signal(0)
  {
    ..base,
    topic_read: fn(name, params) {
      tick.get() |> ignore
      if name == "chats" {
        let j : Json = {
          "stations": [{ "station": "ws1/st1", "state": "online" }],
          "leading": "agents",
          "projects": true,
          "projectsWritable": true,
          "days": [],
        }
        { value: Some(j), error: None, version: 1 }
      } else if name == "prefs" {
        { value: Some(Json::object({})), error: None, version: 1 }
      } else if name == "projects" {
        active_subs[fp_topic_key(name, params)] = true
        match proj_error.val {
          Some(msg) => { value: None, error: Some({ "message": Json::string(msg) }), version: 1 }
          None => {
            let q = match params.get("q") {
              Some(String(s)) => s.to_lower()
              _ => ""
            }
            let cur = match params.get("cursor") {
              Some(String(c)) => c
              _ => ""
            }
            if cur == "p2" {
              let j : Json = {
                "items": [{ "name": "ExtraProj", "chatCount": 2.0, "latestActiveAt": 100.0 }],
                "total": Json::number((projects.length() + 1).to_double()),
                "unclassifiedCount": 1.0,
              }
              { value: Some(j), error: None, version: 1 }
            } else {
              let filtered = projects.filter(fn(item) {
                if q == "" {
                  true
                } else {
                  text(Some(item), "name").to_lower().contains(q)
                }
              })
              let obj : Map[String, Json] = {
                "items": Json::array(filtered),
                "total": Json::number(filtered.length().to_double()),
                "unclassifiedCount": Json::number(1.0),
              }
              if has_more_projects && q == "" {
                obj["nextCursor"] = Json::string("p2")
              }
              { value: Some(Json::object(obj)), error: None, version: 1 }
            }
          }
        }
      } else if name == "tags" {
        active_subs[fp_topic_key(name, params)] = true
        let q = match params.get("q") {
          Some(String(s)) => s.to_lower()
          _ => ""
        }
        let filtered = tags.filter(fn(item) {
          if q == "" {
            true
          } else {
            text(Some(item), "name").to_lower().contains(q)
          }
        })
        let j : Json = {
          "items": Json::array(filtered),
          "total": Json::number(filtered.length().to_double()),
        }
        { value: Some(j), error: None, version: 1 }
      } else {
        (base.topic_read)(name, params)
      }
    },
    release: fn(name, params) {
      if name == "projects" || name == "tags" {
        active_subs.remove(fp_topic_key(name, params))
      }
      (base.release)(name, params)
    },
    refresh: fn(_name, _params) {
      proj_error.val = None
      tick.set(tick.untracked() + 1)
    },
  }
}

///|
fn fp_tree(body : (@view.View) -> Unit) -> (@view.View) -> Unit {
  fn(root) {
    root.grow(Is(1.0)).width_share(Is(1.0)).height_share(Is(1.0)) |> ignore
    body(root)
    @sf.presented_nodes(root)
  }
}

///|
test "filter_narrowed and filter_summary normalize chats to all and ignore project grouping" {
  @sf.set_words(@sfbase.fill)
  @sfbase.projects_reset()
  let subs : Map[String, Bool] = Map([])
  let src = fp_source_with_leases([], [], subs)
  assert_false(filter_narrowed(src, "ws1", "chats"))
  assert_false(filter_narrowed(src, "ws1", "all"))
  assert_eq(filter_summary(src, "ws1", "chats"), "")
  // Project grouping alone must not light the filter dot.
  @sfbase.set_list_group_by(src, "ws1", "project")
  assert_false(filter_narrowed(src, "ws1", "chats"))
  // Narrowing by scope lights the dot; archive view itself is not narrowed.
  assert_true(filter_narrowed(src, "ws1", "mine"))
  assert_false(filter_narrowed(src, "ws1", "archive"))
  assert_true(filter_summary(src, "ws1", "mine") != "")
  assert_true(filter_summary(src, "ws1", "archive") != "")
  // Narrowing by project or tag lights the dot and formats without middle dot.
  @sfbase.set_project_filter("ws1", Named("monoid"))
  @sfbase.set_tag_filter("ws1", Some("ios"))
  assert_true(filter_narrowed(src, "ws1", "chats"))
  let sum = filter_summary(src, "ws1", "chats")
  assert_true(sum.contains("monoid"))
  assert_true(sum.contains("#ios"))
  assert_false(sum.contains("·"))
}

///|
test "chats_view_panel grouping, collapse hook, live scope, quick picks, stepping, and lease release" {
  @sf.set_words(@sfbase.fill)
  @sfbase.projects_reset()
  sidebar_reset()
  let subs : Map[String, Bool] = Map([])
  let projs : Array[Json] = [
    { "name": "monoid", "chatCount": 12.0, "latestActiveAt": 500.0 },
    { "name": "Pion", "chatCount": 8.0, "latestActiveAt": 400.0 },
  ]
  let tags : Array[Json] = [
    { "name": "ios", "chatCount": 5.0, "latestActiveAt": 500.0 },
    { "name": "ui-review", "chatCount": 3.0, "latestActiveAt": 400.0 },
  ]
  let src = fp_source_with_leases(projs, tags, subs, has_more_projects=true)
  let all_collapsed = @signals.signal(false)
  let collapse_calls : Array[Bool] = []
  let hook_tok = @sfbase.register_grouped_collapse_hook("ws1", fn() { all_collapsed.get() }, fn(v) {
    collapse_calls.push(v)
    all_collapsed.set(v)
  })
  let picked_scopes : Array[String] = []
  let t = @ui.Tester::new(
    fn(_) {  },
    tree=fp_tree(fn(root) {
      @sf.action_box_node(root, fn() { "open-filter" }, fn(btn) {
        filter_menu(
          Node(btn),
          @sfbase.filter_of(src, "ws1"),
          fn(k) {
            picked_scopes.push(k)
            if k != "archive" {
              @sfbase.set_filter_of(src, "ws1", k)
            }
          },
          src=Some(src),
          ws="ws1",
        )
      }, fn(b) {
        b.width(Is(Some(44.0))).height(Is(Some(44.0))) |> ignore
      })
      |> ignore
    }),
    w=800.0,
    h=700.0,
  )
  t.run_for(@ui.move_most_ms)
  assert_eq(subs.length(), 0)
  // Open panel
  t.click(Button, label="open-filter")
  t.run_for(@ui.move_most_ms)
  assert_true(filter_menu_open())
  assert_true(subs.length() > 0)
  // Switch to group by project -> collapse hook button appears and works
  t.click(Radio, label=@sf.t("web-main.projects.group_by_project"))
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.list_group_by(src, "ws1"), "project")
  t.click(Button, label=@sf.t("web-main.projects.collapse_all"))
  t.run_for(@ui.move_most_ms)
  assert_eq(collapse_calls, [true])
  // Quick-pick project "monoid" -> live, panel stays open, effective grouping falls back to time
  t.click(Button, label="monoid")
  t.run_for(@ui.move_most_ms)
  assert_true(filter_menu_open())
  assert_true(@sfbase.project_filter_of("ws1") == Named("monoid"))
  // Quick-pick tag "#ios"
  t.click(Button, label="#ios")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.tag_filter_of("ws1"), Some("ios"))
  // Clicking "按项目" clears project filter in one batch while preserving tag filter
  t.click(Radio, label=@sf.t("web-main.projects.group_by_project"))
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.project_filter_of("ws1") == All)
  assert_eq(@sfbase.tag_filter_of("ws1"), Some("ios"))
  assert_eq(@sfbase.list_group_by(src, "ws1"), "project")
  // Scope switch stays open
  t.click(Radio, label=@sf.t("web-main.filter.chats.mine"))
  t.run_for(@ui.move_most_ms)
  assert_true(filter_menu_open())
  assert_eq(@sfbase.filter_of(src, "ws1"), "mine")
  // Step into "更多项目" -> panel_depth() == 2, pick "Pion" -> returns to main panel
  t.click(Button, label=@sf.t("web-main.projects.more_projects"))
  t.run_for(@ui.move_most_ms)
  assert_eq(@sf.panel_depth(), 2)
  t.click(Button, label="Pion")
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.project_filter_of("ws1") == Named("Pion"))
  assert_eq(@sf.panel_depth(), 1)
  // All panel action/link buttons and filter chips must satisfy tier minimum hit height (`items.least`: 36pt desktop / 44pt touch)
  let least_h = @sf.theme().items.least
  for lbl in [@sf.t("web-main.projects.filter_clear"), @sf.t("web-main.projects.more_projects"), @sf.t("web-main.projects.more_tags"), "monoid", "#ios"] {
    match t.query(Button, label=lbl) {
      Some(hit) => assert_true(hit.rect.3 >= least_h, msg="button '\{lbl}' press target height < \{least_h}: \{hit.rect.3}")
      None => fail("missing expected panel button: " + lbl)
    }
  }
  // Clear filters keeps scope and grouping
  t.click(Button, label=@sf.t("web-main.projects.filter_clear"))
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.project_filter_of("ws1") == All)
  assert_eq(@sfbase.tag_filter_of("ws1"), None)
  assert_eq(@sfbase.filter_of(src, "ws1"), "mine")
  // Close via Escape -> leases must drop to 0
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_false(filter_menu_open())
  assert_eq(subs.length(), 0)
  // Unregister & projects_reset clears hooks
  @sfbase.unregister_grouped_collapse_hook("ws1", hook_tok)
  @sfbase.projects_reset()
  sidebar_reset()
}

///|
test "chats_view_panel in archive mode hides grouping/filter sections and switches back on scope pick" {
  @sf.set_words(@sfbase.fill)
  @sfbase.projects_reset()
  sidebar_reset()
  let subs : Map[String, Bool] = Map([])
  let src = fp_source_with_leases([], [], subs)
  let went : Array[String] = []
  let t = @ui.Tester::new(
    fn(_) {  },
    tree=fp_tree(fn(root) {
      @sf.action_box_node(root, fn() { "open-archive-filter" }, fn(btn) {
        filter_menu(Node(btn), "archive", fn(k) { went.push(k) }, src=Some(src), ws="ws1")
      }, fn(b) {
        b.width(Is(Some(44.0))).height(Is(Some(44.0))) |> ignore
      })
      |> ignore
    }),
    w=800.0,
    h=700.0,
  )
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="open-archive-filter")
  t.run_for(@ui.move_most_ms)
  // Archive mode must not subscribe to projects/tags chains or show grouping/filter sections
  assert_eq(subs.length(), 0)
  assert_true(t.query(Radio, label=@sf.t("web-main.projects.group_by_project")) is None)
  assert_true(t.query(Button, label=@sf.t("web-main.projects.more_projects")) is None)
  // Clicking a scope goes back to chats list and closes panel
  t.click(Radio, label=@sf.t("web-main.filter.chats.all"))
  t.run_for(@ui.move_most_ms)
  assert_eq(went, ["all"])
  assert_false(filter_menu_open())
}

///|
test "active_filter_bar_node 44pt pills, 80-char project name at 240px and 1.3x font scale, zero audit faults" {
  @sf.set_words(@sfbase.fill)
  @sfbase.projects_reset()
  let subs : Map[String, Bool] = Map([])
  let long_name = "超长项目名称测试".repeat(10) // 80 chars
  let src = fp_source_with_leases([{ "name": Json::string(long_name), "chatCount": 3.0 }], [{ "name": "ui-review", "chatCount": 2.0 }], subs)
  @sfbase.set_project_filter("ws1", Named(long_name))
  @sfbase.set_tag_filter("ws1", Some("ui-review"))
  assert_eq(active_filter_bar_h(src, "ws1"), 52.0)
  assert_eq(active_filter_bar_h(src, "ws1", in_archive=true), 0.0)
  let t = @ui.Tester::new(
    fn(_) {  },
    tree=fp_tree(fn(root) {
      active_filter_bar_node(root, src, fn() { "ws1" }, px=8.0)
    }),
    w=240.0,
    h=400.0,
  )
  defer {
    t.set_font_scale(1.0)
    @sfbase.projects_reset()
    sidebar_reset()
  }
  t.set_font_scale(1.3)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.audit(), [])
  // Clear project filter via concentric × button
  t.click(Button, label=@sf.t("web-main.projects.clear_project_filter"))
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.project_filter_of("ws1") == All)
  assert_eq(@sfbase.tag_filter_of("ws1"), Some("ui-review"))
  // Clicking tag pill opens standalone tag picker (panel_depth == 1), picking closes
  t.click(Button, label="#ui-review")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sf.panel_depth(), 1)
  t.click(Button, label=@sf.t("web-main.projects.filter_all"))
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.tag_filter_of("ws1"), None)
  assert_eq(@sf.panel_depth(), 0)
  assert_eq(subs.length(), 0)
}
