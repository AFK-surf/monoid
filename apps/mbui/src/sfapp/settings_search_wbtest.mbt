// The settings search is the same list on every screen. Exercise the field, filtering, clearing and opening a result
// through the app's shell, with each input as well as each arrangement.

///|
fn settings_search_tester(w : Double, platform : Int) -> @ui.Tester {
  let src = fixture_app("settings-home")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h=1000.0, platform~)
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "settings search filters, clears and opens a nested page on every screen with either input" {
  for (w, platform) in [(390.0, 2), (390.0, 0), (720.0, 2), (1280.0, 0), (1280.0, 2)] {
    let t = settings_search_tester(w, platform)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("搜索设置") is Some(_), msg=at)
    t.tap_text("搜索设置")
    t.type_text("没有这样的设置")
    // (what the change brings or takes away makes its way, the list's: looked at once that is over)
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("没有匹配的结果") is Some(_), msg=at)
    t.click(Button, label="清除筛选")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("没有匹配的结果") is None, msg=at)
    assert_true(t.find("安全") is Some(_), msg=at)
    t.type_text("字体")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("字体") is Some(_), msg=at)
    assert_true(t.find("安全") is None, msg=at)
    t.tap_text("字体")
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() == Setting(@settings.Route::Fonts), msg=at)
  }
}

///|
test "settings search finds account and workspace settings by their names as well as the person's own name" {
  let t = settings_search_tester(390.0, 2)
  t.tap_text("搜索设置")
  t.type_text("成员")
  t.frame()
  assert_true(t.find("成员") is Some(_))
  t.tap_text("成员")
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() == Setting(@settings.Route::Workspace))
}

///|
test "settings search follows the language and keeps its words when the list moves to the sidebar" {
  let base = fixture_app("settings-home")
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let got = base.topic(name, params).get().snapshot()
      if name == "prefs" {
        let prefs = match got.value {
          Some(Object(m)) => m.copy()
          _ => {}
        }
        prefs["lang"] = Json::string("en")
        { ..got, value: Some(Json::object(prefs)) }
      } else {
        got
      }
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=1000.0, platform=0)
  t.run_for(@ui.move_most_ms)
  t.tap_text("Search settings")
  t.type_text("  FoNt  ")
  t.frame()
  assert_true(t.find("Fonts") is Some(_))
  t.resize(1280.0, 1000.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("Fonts") is Some(_))
  t.tap_text("Fonts")
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() == Setting(@settings.Route::Fonts))
}

///|
/// The words typed into the settings' search of `t`, what was there emptied first, looked at once the list is what
/// they find.
fn settings_search_for(t : @ui.Tester, words : String) -> Unit raise {
  let clear = @sf.t("android-misc.drive.pick.filterClear")
  if t.all(Button).iter().any(fn(s) { s.label == clear }) {
    t.click(Button, label=clear)
  } else {
    t.tap_text(@sf.t("web-pages.settings.search"))
  }
  t.type_text(words)
  t.run_for(@ui.move_most_ms)
}

///|
test "settings search finds a setting by what people call it, and its station or page straight away" {
  for (w, platform) in [(390.0, 0), (1280.0, 0)] {
    let t = settings_search_tester(w, platform)
    let at = "\{w} platform \{platform}"
    // (each typed, and what it finds: a row of the list by another name, or a setting under one)
    for found in [
      ("工作区", "星火工作室"),
      ("安全模式", "安全"),
      ("中继", "中继"),
      ("额度", "额度"),
      ("Claude", "Profile"),
      ("Slack", "连接"),
      ("飞书", "连接"),
      ("迁移", "迁移"),
      ("设备", "已登录的设备"),
      ("深色", "主题"),
      ("动效", "动画"),
      ("发送消息", "发送消息"),
      ("后台下载", "后台下载"),
      ("手机", "共享调试"),
      ("自动　归档", "自动归档"),
    ] {
      settings_search_for(t, found.0)
      assert_true(t.find("没有匹配的结果") is None, msg="\{at}: \{found.0} finds something")
      assert_true(t.find(found.1) is Some(_), msg="\{at}: \{found.0} finds \{found.1}")
    }
    // (the rail's own, beside the settings' sidebar alone)
    settings_search_for(t, "侧边条")
    assert_eq(t.find("侧边条") is Some(_), w > 1000.0, msg=at)
    // (a station by its name, to its own page; 价目表 to its own)
    settings_search_for(t, "Willow")
    t.tap_text("Willow")
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() == Setting(@settings.Route::Station("ws1/st1")), msg=at)
  }
  for (w, platform) in [(390.0, 2), (1280.0, 0)] {
    let t = settings_search_tester(w, platform)
    settings_search_for(t, "价目表")
    t.tap_text("价目表")
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() == Setting(@settings.Route::UsagePrices(7)), msg="\{w} platform \{platform}")
  }
}

///|
test "settings search shows a row's own page's settings only where the words say more than the row's name" {
  for (w, platform) in [(390.0, 2), (1280.0, 0)] {
    let t = settings_search_tester(w, platform)
    let at = "\{w} platform \{platform}"
    settings_search_for(t, "通知")
    assert_true(t.find("通知") is Some(_), msg=at)
    assert_true(t.find("通知类别") is None && t.find("通知里显示内容") is None, msg=at)
    settings_search_for(t, "通知类别")
    assert_true(t.find("通知类别") is Some(_), msg=at)
    settings_search_for(t, "归档")
    assert_true(t.find("归档") is Some(_) && t.find("归档建议") is Some(_), msg=at)
    assert_true(t.find("提示归档") is None && t.find("自动归档") is None, msg=at)
    settings_search_for(t, "自动归档")
    assert_true(t.find("自动归档") is Some(_), msg=at)
    // (the workspace's row by what it is: its name's setting only for more than that)
    let named = @sf.t("android-settings.workspace.name")
    for words in ["工作区", "Workspace"] {
      settings_search_for(t, words)
      assert_true(t.find("星火工作室") is Some(_) && t.find(named) is None, msg="\{at}: \{words}")
    }
    settings_search_for(t, "重命名")
    assert_true(t.find(named) is Some(_), msg=at)
  }
}

///|
/// How many rows of the settings' sidebar are on the ground of the page beside it (theme's `selected`, whole): lit.
fn settings_side_lit(t : @ui.Tester) -> Int {
  // (the pointer off the list: a row under it is lit by the hand as well)
  t.move_to(900.0, 700.0)
  t.run_for(@ui.move_most_ms)
  let selected = @sf.theme().p.selected & 0xFFFFFF00L
  t
  .drawn_rects()
  .filter(fn(r) { r.0 < 400.0 && r.2 > 120.0 && (r.4 & 0xFFL) != 0L && (r.4 & 0xFFFFFF00L) == selected })
  .length()
}

///|
test "the settings' sidebar lights one row at most while the search finds several on the same page" {
  for platform in [0, 2] {
    let t = settings_search_tester(1280.0, platform)
    let at = "platform \{platform}"
    assert_eq(settings_side_lit(t), 1, msg=at)
    settings_search_for(t, "登录")
    t.click(Link, label="退出登录")
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() == Setting(@settings.Route::Me), msg=at)
    let lit = settings_side_lit(t)
    assert_eq(lit, 1, msg="\{at}: 登录: \{lit} lit")
    settings_search_for(t, "色")
    assert_true(t.find("主题") is Some(_), msg=at)
    t.click(Link, label="主题")
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() == Setting(@settings.Route::Appearance), msg=at)
    let lit = settings_side_lit(t)
    assert_eq(lit, 1, msg="\{at}: 色: \{lit} lit")
    // (the words changed: the row of the page beside it, or the one result alone that opens it)
    settings_search_for(t, "强调色")
    assert_true(settings_side_lit(t) <= 1, msg="\{at}: 强调色")
  }
}

///|
test "settings search opens by Enter, goes along its results by the arrows in the sidebar and is emptied by Escape" {
  for (w, platform) in [(390.0, 0), (1280.0, 0)] {
    let t = settings_search_tester(w, platform)
    let at = "\{w} platform \{platform}"
    settings_search_for(t, "字体")
    t.key(@ui.key_code_enter)
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() == Setting(@settings.Route::Fonts), msg="\{at}: Enter opens the first")
    if w < 1000.0 {
      t.back()
      t.run_for(@ui.move_most_ms)
    } else {
      settings_search_for(t, "通知")
      t.key(@ui.key_code_down)
      t.key(@ui.key_code_down)
      t.key(@ui.key_code_up)
      t.key(@ui.key_code_enter)
      t.run_for(@ui.move_most_ms)
      assert_true(app.nav.top() == Setting(@settings.Route::Notifications), msg="\{at}: ↓ ↓ ↑ back to the first")
      settings_search_for(t, "通知")
      t.key(@ui.key_code_down)
      t.key(@ui.key_code_down)
      let lit = settings_side_lit(t)
    assert_eq(lit, 1, msg="\{at}: the one the keys are at lit alone: \{lit} lit")
      t.key(@ui.key_code_enter)
      t.run_for(@ui.move_most_ms)
      assert_true(app.nav.top() != Setting(@settings.Route::Notifications), msg="\{at}: ↓ ↓ the second")
    }
    settings_search_for(t, "没有这样的设置")
    assert_true(t.find("没有匹配的结果") is Some(_), msg=at)
    t.key(@ui.key_escape)
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("没有匹配的结果") is None && t.find("安全") is Some(_), msg="\{at}: Escape empties it")
  }
}

///|
test "settings search is let go as the settings are left beside the rail, kept as their pages are gone into" {
  for place in ["连接", "Profile", "对话"] {
    let t = settings_search_tester(1280.0, 0)
    settings_search_for(t, "字体")
    t.tap_text("字体")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("安全") is None, msg="\{place}: the search kept on its page")
    t.click(Button, label=place)
    t.run_for(@ui.move_most_ms)
    t.click(Button, label=@sf.t("web-pages.settings.title"))
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("安全") is Some(_) && t.find("外观") is Some(_), msg="\{place}: the settings whole again")
    assert_true(t.find("没有匹配的结果") is None, msg=place)
  }
}

///|
test "settings search's results hold every rule on each screen, in each language and with the words set large" {
  let phone = corner_windows[corner_windows.search_by(w => w.0 == "phone").unwrap()]
  let wide = corner_windows[corner_windows.search_by(w => w.0 == "wide").unwrap()]
  let narrow = ("narrow", 320.0, 700.0, 2, "")
  for c in [(phone, "zh", 1.0), (narrow, "zh", 1.0), (wide, "zh", 1.0), (phone, "zh", words_large_scale), (phone, "en", 1.0), (wide, "en", 1.0)] {
    let (win, lang, scale) = c
    let at = "\{win.0} \{lang} at \{scale}"
    let t = screen_in("settings-home", win, lang, font_scale=scale)
    let before = t.audit()
    let asked = if lang == "zh" { ["安全模式", "中继", "价目表", "通知", "不存在的设置项"] } else { ["relay", "dark", "price", "nothing like it"] }
    for words in asked {
      settings_search_for(t, words)
      // (the sidebar's list over the pane's edge, there at rest too, is said by the words it starts with)
      let faults = t
        .audit()
        .filter(fn(f) { !before.map(aw_plain).contains(aw_plain(f)) && !f.contains("ui/src/controls/edge_node.mbt:37") })
      assert_eq(faults, [], msg="\{at}: \{words}: \{faults.join(" | ")}")
    }
  }
}
