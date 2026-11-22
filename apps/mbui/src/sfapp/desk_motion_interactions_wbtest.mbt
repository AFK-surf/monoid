// 大屏高频交互动效：右侧面板开合打断速度连续、面板多 Tab 切换柔和进场、左侧栏顶层切栏微滑入。

///|
test "大屏聊天右侧面板开合途中反向打断，速度连续无瞬移并在 move_most_ms 内静止" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat")
  t.run_for(@ui.move_most_ms)
  // (open side panel via user action so side_slides animates)
  side_change(side_tab_chat, "open", Some("jobs"))
  if !@ui.test_at_a_rate() {
    for _ in [0, 1, 2, 3, 4] {
      t.frame()
    }
    let x_before = t.find("后台任务").map(fn(p) { p.0 }).unwrap_or(-999.0)
    assert_true(x_before > 0.0 && x_before < 1280.0, msg="panel mid-open: \{x_before}")
    // (interrupt mid-open by closing)
    side_change(side_tab_chat, "clear", None)
    t.frame()
    let x_f1 = t.find("后台任务").map(fn(p) { p.0 }).unwrap_or(-999.0)
    // (opening moves the panel's left edge leftward; on frame 1 after close interrupt it carries leftward momentum smoothly)
    assert_true(x_f1 < x_before && (x_f1 - x_before).abs() < 80.0, msg="continuous after interrupt: before=\{x_before}, f1=\{x_f1}")
    t.frame()
    let x_f2 = t.find("后台任务").map(fn(p) { p.0 }).unwrap_or(-999.0)
    // (decelerating smoothly toward closing rightward)
    assert_true(x_f2 - x_f1 > x_f1 - x_before, msg="decelerating smoothly: before=\{x_before}, f1=\{x_f1}, f2=\{x_f2}")
  } else {
    t.run_for(@ui.move_ms(400.0) / 3.0)
    side_change(side_tab_chat, "clear", None)
  }
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("后台任务") is None, msg="panel closed at rest")
}

///|
test "大屏聊天右侧面板多 Tab 切换柔和进场，冷启动不动画且在 move_most_ms 内静止" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat-tabs-side")
  let jobs_anchor = @sf.t("web-main.jobs.noneInChat")
  // (cold start with panel open: no tab-switch fade)
  guard t.words().iter().find_first(fn(w) { w.0 == jobs_anchor }) is Some(cold) else {
    @halt.saying("panel tab cold start missing jobs_anchor: front=\{side_now(side_tab_chat).1}")
  }
  assert_true((cold.5 - 1.0).abs() < 0.01, msg="cold start panel tab alpha is 1: \{cold.5}")
  t.run_for(@ui.move_most_ms)
  guard t.words().iter().find_first(fn(w) { w.0 == jobs_anchor }) is Some(rest_w) else {
    @halt.saying("panel tab rest missing jobs_anchor: front=\{side_now(side_tab_chat).1}")
  }
  let rest_x = rest_w.1
  let tabs = side_tabs_said(t)
  assert_eq(tabs.length(), 2)
  let (_, _, (ax, ay, _, ah)) = tabs[0]

  // (switch leftward: jobs (1) -> s-c1 (0))
  t.tap(ax + 16.0, ay + ah / 2.0)
  if !@ui.test_at_a_rate() {
    t.frame()
    let body_fading = t.words().iter().any(fn(w) { w.1 > ax && w.2 > ay + ah && w.5 > 0.0 && w.5 < 1.0 })
    assert_true(body_fading, msg="leftward tab switch fades in panel body")
  }
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(side_tab_chat).1, "s-c1")

  // (switch rightward: s-c1 (0) -> jobs (1); dir = +1.0, enters from +x)
  let tabs2 = side_tabs_said(t)
  assert_eq(tabs2.length(), 2)
  let (_, _, (jx, jy, _, jh)) = tabs2[1]
  t.tap(jx + 16.0, jy + jh / 2.0)
  if !@ui.test_at_a_rate() {
    t.frame()
    guard t.words().iter().find_first(fn(w) { w.0 == jobs_anchor }) is Some(w_back_mid) else {
      @halt.saying("panel tab back mid missing jobs_anchor: front=\{side_now(side_tab_chat).1}")
    }
    assert_true(w_back_mid.1 > rest_x, msg="rightward tab switch enters from +x: rest=\{rest_x}, mid=\{w_back_mid.1}")
    assert_true(w_back_mid.5 > 0.0 && w_back_mid.5 < 1.0, msg="rightward tab switch fades in: \{w_back_mid.5}")
  }
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(side_tab_chat).1, "jobs")
  guard t.words().iter().find_first(fn(w) { w.0 == jobs_anchor }) is Some(w_back_end) else {
    @halt.saying("panel tab back end missing jobs_anchor: front=\{side_now(side_tab_chat).1}")
  }
  assert_true((w_back_end.1 - rest_x).abs() < 0.5, msg="settled x matches rest: rest=\{rest_x}, end=\{w_back_end.1}")
  assert_true((w_back_end.5 - 1.0).abs() < 0.01, msg="settled alpha is 1: \{w_back_end.5}")
}

///|
test "大屏左侧栏顶层切栏：冷启动无动画，切换板块按纵向方向微滑入并在 move_most_ms 内静止" {
  let calls : Array[Made] = []
  let t = wide_tester(calls)
  // (cold start on chats: no entrance offset)
  guard t.words().iter().find_first(fn(w) { w.0 == "新建对话" }) is Some(cold_w) else {
    @halt.saying("sidebar cold start missing 新建对话")
  }
  let cold_y = cold_w.2
  t.run_for(@ui.move_most_ms)
  guard t.words().iter().find_first(fn(w) { w.0 == "新建对话" }) is Some(chats_rest_w) else {
    @halt.saying("sidebar rest missing 新建对话")
  }
  let chats_y_rest = chats_rest_w.2
  assert_true((cold_y - chats_y_rest).abs() < 0.5, msg="cold start sidebar has no offset: cold=\{cold_y}, rest=\{chats_y_rest}")

  // (switch downward: chats (0) -> files (2); dir = +1.0, enters from below rest y)
  t.click(Button, label="文件")
  let mut files_mid_y : Double? = None
  if !@ui.test_at_a_rate() {
    t.frame()
    files_mid_y = t.words().iter().find_first(fn(w) { w.0 == @sf.t("web-pages.files.addFavorite") }).map(fn(w) { w.2 })
  }
  t.run_for(@ui.move_most_ms)
  guard t.words().iter().find_first(fn(w) { w.0 == @sf.t("web-pages.files.addFavorite") }) is Some(files_rest_w) else {
    @halt.saying("sidebar files rest missing addFavorite")
  }
  let files_y_rest = files_rest_w.2
  if files_mid_y is Some(my) {
    assert_true(my > files_y_rest, msg="downward rail switch enters from +y: rest=\{files_y_rest}, mid=\{my}")
  }

  // (switch upward: files (2) -> chats (0); dir = -1.0, enters from above rest y)
  t.click(Button, label="对话")
  if !@ui.test_at_a_rate() {
    t.frame()
    guard t.words().iter().find_first(fn(w) { w.0 == "新建对话" }) is Some(chats_mid) else {
      @halt.saying("sidebar upward mid missing 新建对话")
    }
    assert_true(chats_mid.2 < chats_y_rest, msg="upward rail switch enters from -y: rest=\{chats_y_rest}, mid=\{chats_mid.2}")
  }
  t.run_for(@ui.move_most_ms)
  guard t.words().iter().find_first(fn(w) { w.0 == "新建对话" }) is Some(chats_end) else {
    @halt.saying("sidebar upward end missing 新建对话")
  }
  assert_true((chats_end.2 - chats_y_rest).abs() < 0.5, msg="chats sidebar settled y matches rest: rest=\{chats_y_rest}, end=\{chats_end.2}")
}
