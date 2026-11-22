// The rows of Station's list, 连接, 账号 and 已归档 answer the pointer's other button with their menu where it was
// pressed (stations_list.mbt, connects.mbt, profiles_list.mbt, archive_node.mbt), each item what the row already does:
// opened, its name or address copied (said in the toast), an archived chat restored or, where it may be, deleted for
// good after a line and in red. The page drawn alone over the settings' made-up core, as settings_rig_wbtest has it.

///|
/// What the page's words are, for a test that does not find what it looks for.
fn words_said(t : @ui.Tester) -> String {
  t.words().map(fn(w) { w.0 }).join(" | ")
}

///|
/// The pointer's other button pressed on `words` (drawn whole), and the menu that opens at rest.
fn right_click_words(t : @ui.Tester, words : String) -> Unit raise {
  guard t.rect_of(words) is Some((x, y, w, h)) else { fail("no \{words} drawn: \{words_said(t)}") }
  t.right_click(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
}

///|
/// The items a menu shows, in their order, none of them `not` (what it must not show).
fn menu_shows(t : @ui.Tester, items : Array[String], not? : Array[String] = [], at~ : String) -> Unit raise {
  let mut last = -1.0
  for item in items {
    guard t.find_last(item) is Some((_, y)) else { fail("\{at}: no \{item} in its menu: \{words_said(t)}") }
    assert_true(y > last, msg="\{at}: \{item} after the one before")
    last = y
  }
  for item in not {
    assert_true(t.find(item) is None, msg="\{at}: no \{item}")
  }
  // (what the rules find in the menu itself: the page under it is held to them by the screens' sweeps, with what they
  // knew of it before)
  let faults = t.audit().filter(fn(f) { items.iter().any(fn(i) { f.contains(i) }) })
  assert_true(faults.is_empty(), msg="\{at}: \{faults.join("\n")}")
}

///|
test "a station's card: its menu at the pointer opens it and copies its name and its address" {
  for w in [390.0, 1280.0] {
    let t = setting_tester(Stations, w, platform=0)
    let at = "\{w}"
    right_click_words(t, "Willow")
    menu_shows(t, ["打开", "复制名称", "复制地址"], at~)
    t.tap_text("复制名称")
    t.run_for(@ui.move_most_ms)
    assert_eq(t.clipboard(), "Willow", msg=at)
    right_click_words(t, "Willow")
    t.tap_text("复制地址")
    t.run_for(@ui.move_most_ms)
    assert_eq(t.clipboard(), "ws1/st1", msg=at)
    right_click_words(t, "Willow")
    t.tap_text("打开")
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() == Setting(Station("ws1/st1")), msg=at)
  }
}

///|
test "a connect's row: its menu anywhere on the row opens its page and copies its name" {
  for w in [390.0, 1280.0] {
    let t = setting_tester(Connects(""), w, platform=0)
    let at = "\{w}"
    right_click_words(t, "星火助手")
    menu_shows(t, ["打开", "复制名称"], not=["复制地址"], at~)
    t.tap_text("复制名称")
    t.run_for(@ui.move_most_ms)
    assert_eq(t.clipboard(), "星火助手", msg=at)
    right_click_words(t, "星火助手")
    t.tap_text("打开")
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() is Setting(Connect(_, _)), msg=at)
  }
}

///|
test "an account's row: its menu opens its page and copies its name" {
  for w in [390.0, 1280.0] {
    let t = setting_tester(Profiles(""), w, platform=0)
    let at = "\{w}"
    // (the first account the list shows: its row's name, the words before its plan)
    let first = t.words().filter(fn(x) { x.0 == "Claude 主账号" })
    guard first.length() > 0 else { fail("\{at}: no Claude 主账号: \{words_said(t)}") }
    right_click_words(t, "Claude 主账号")
    menu_shows(t, ["打开", "复制名称"], at~)
    t.tap_text("复制名称")
    t.run_for(@ui.move_most_ms)
    assert_eq(t.clipboard(), "Claude 主账号", msg=at)
    right_click_words(t, "Claude 主账号")
    t.tap_text("打开")
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() is Setting(Profile(_, _)), msg=at)
  }
}

///|
/// 已归档 drawn alone over the settings' made-up core, `w` wide, pointed at with a mouse; `calls` told each call it makes.
fn archive_tester(w : Double, calls : Array[(String, Json)]) -> @ui.Tester {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base = @sffixture.fixture("settings")
  let src = {
    ..base,
    call: fn(name, params, done) {
      calls.push((name, params))
      (base.call)(name, params, done)
    },
  }
  app.nav.push(Settings)
  let t = @ui.Tester::new(
    @ui.old_views_here,
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.presented_nodes(root)
    },
    w~,
    h=900.0,
    platform=0,
  )
  @ui.set_view_app(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.box(fn(p) {
        let core = @sfbase.settings_core(src, rig_workspace)
        let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
        @settings.frame(core, here())
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        let frame = fn() -> PageFrame { { back: None, top: 0.0, foot: 0.0, named: false } }
        archive_node(p, core, here, on_back=core.pop, frame~, width=fn() { w })
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    around=fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() {
        @ui.old_views_here(c)
        @sf.presented(c)
      })
    },
  )
  t.draw()
  t
}

///|
test "an archived chat's row: its menu opens it and restores it; 删除 after a line, in red, only where it may be" {
  for w in [390.0, 1280.0] {
    let at = "\{w}"
    let calls : Array[(String, Json)] = []
    let t = archive_tester(w, calls)
    // (one that may not be deleted: no 删除, and no line left at the menu's end)
    right_click_words(t, "周会纪要")
    menu_shows(t, ["打开对话", "恢复对话"], not=["删除"], at="\{at} 周会纪要")
    t.key(@ui.key_escape)
    t.run_for(@ui.move_most_ms)
    // (one that may: 删除 last, asked first)
    right_click_words(t, "整理上个月的发票")
    menu_shows(t, ["打开对话", "恢复对话", "删除"], at="\{at} 整理上个月的发票")
    t.tap_text("删除")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("删除「整理上个月的发票」？") is Some(_), msg="\{at}: asked first: \{words_said(t)}")
    t.key(@ui.key_escape)
    t.run_for(@ui.move_most_ms)
    // 恢复对话: as its 恢复 does (chat.archive, archived false)
    right_click_words(t, "整理上个月的发票")
    t.tap_text("恢复对话")
    t.run_for(@ui.move_most_ms)
    let restores = calls.filter(fn(c) { c.0 == "chat.archive" })
    assert_eq(restores.length(), 1, msg=at)
    assert_eq(text(Some(restores[0].1), "session"), "s-a1", msg=at)
    assert_true(field(Some(restores[0].1), "archived") is Some(False), msg=at)
  }
}
