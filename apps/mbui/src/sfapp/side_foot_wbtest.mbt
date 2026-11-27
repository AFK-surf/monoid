// A sidebar's list at its end (sfdesk's side.mbt side_scroll, sfpages' sidebar.mbt, @sf.list_foot_in): its last row
// clear of the panel's foot corners (as far up as they are round), as its rows are of its sides; and a row
// of the settings' list whose words at its end leave it before its title is cut.

///|
/// The sidebar's row `label` (its link: the row's ground) left of `edge`.
fn side_row_at(t : @ui.Tester, label : String, edge : Double) -> (Double, Double, Double, Double)? {
  for s in t.semantics() {
    if s.label == label && s.role == @ui.Role::Link && !s.hidden && s.rect.0 < edge {
      return Some(s.rect)
    }
  }
  None
}

///|
/// The sidebar's panel on the tape (the block's ground: the rail and the sidebar on it, a node of the window's tree,
/// among the tree's: dock_ground).
fn side_panel(t : @ui.Tester) -> @ui.Laid? {
  t.boxes_held().iter().find_first(dock_ground)
}

///|
/// Whether box `b` is the block's ground as the window's tree draws it (frame.mbt dock_node): a ground at the window's
/// left edge (6 in at most), taller than the window's half, narrower than it.
fn dock_ground(b : @ui.Laid) -> Bool {
  b.kind != "text" && (b.bg != 0L || b.glass) && b.x >= 0.0 && b.x <= 6.0 && b.h > 300.0 && b.w < 600.0
}

///|
/// The tape's settings on a touch screen's medium window `h` high, the device's language `locale` (its host's
/// MBUI_LOCALE; "": Chinese): 关于's page opened from the sidebar's list scrolled to its end, beside the sidebar still
/// in use, 关于 its last row, lit; then a newer build known where `newer`.
fn settings_at_end(h : Double, locale? : String = "", newer? : String = "") -> @ui.Tester raise {
  new_run()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=690.0, h~, platform=2, env=[("MBUI_LOCALE", locale)])
  say_room(t, "medium", "medium")
  t.run_for(@ui.move_most_ms)
  tap_said(t, @sf.t("web-pages.settings.title"))
  t.run_for(@ui.move_most_ms)
  t.wheel(200.0, h / 2.0, 3000.0)
  t.run_for(@ui.move_most_ms)
  let about = @sf.t("web-pages.settings.nav.about")
  guard side_row_at(t, about, 400.0) is Some((x, y, w, rh)) else { fail("no \{about} in the sidebar") }
  t.tap(x + w / 2.0, y + rh / 2.0)
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(app.nav.top() == Setting(@settings.Route::About))
  // (its page beside the sidebar, the sidebar still in use)
  assert_eq(@sfdesk.wide.tape_at.get(), @sfdesk.TapePane::Side)
  // (said once 关于 has asked still.fail cloud: what it answered, none newer, said over)
  if newer != "" {
    // (ready for the person's word: the settings' row says the version it goes to)
    @sffixture.fixture_update(newer)
    @sffixture.fixture_update_goes(newer, "ready")
    t.run_for(@ui.move_most_ms)
  }
  t
}

///|
test "on the tape a sidebar's list ends clear of the panel's foot corners under its last row: the settings' 关于 lit at its end, as far up as the panel is round (its rows 16 in from its sides, round by a row's 18, in no corner of the panel's 42)" {
  let t = settings_at_end(520.0)
  guard side_row_at(t, "关于", 400.0) is Some((x, y, w, h)) else { fail("no 关于 in the sidebar") }
  guard side_panel(t) is Some(p) else { fail("no sidebar's panel") }
  let side = p.x + p.w - (x + w)
  let foot = p.y + p.h - (y + h)
  assert_eq(foot, @sf.list_foot_in(Side))
  assert_true(foot >= @sf.pane_corner - 0.01 && (side - 16.0).abs() < 0.01, msg="its foot \{foot}, its side \{side}")
  assert_eq(t.corner_faults(), [])
}

///|
test "a settings row's words at its end leave it before its title is cut: About whole, Update to … gone where it has not the room" {
  // (what is at its end shorter than the row, longer than the row leaves it beside its title)
  let newer = "0.1.5425-beta"
  let t = settings_at_end(520.0, locale="en-US", newer~)
  update.available.set(None)
  assert_true(side_row_at(t, "About", 400.0) is Some(_), msg="no About in the sidebar")
  // (the row too short for both: what is at its end gone from it, its title whole)
  let said = "Update to " + newer
  let shown = t.boxes().iter().any(fn(b) { b.text == said && b.x < 400.0 && b.w > 0.0 && b.opacity > 0.0 })
  assert_false(shown, msg="its end still in the row")
  assert_eq(t.squeeze_faults(), [])
}

///|
test "wide: with no bell in the rail the sidebar's foot says what is wrong with the stations and 运行中 N; the chip opens what is left up long over it, the trouble leads to the stations" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="home-foot")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("Maple 离线") is Some(_), msg=t.words().map(fn(w) { w.0 }).join("|"))
  assert_true(t.find("运行中 1") is Some(_))
  // (on the sidebar's foot: under the lists, the trouble and the chip on one line)
  let (_, ty) = t.find("Maple 离线").unwrap()
  let (_, cy) = t.find("运行中 1").unwrap()
  assert_true(ty > 600.0 && (ty - cy).abs() < 8.0, msg="the trouble at \{ty}, the chip at \{cy}")
  let (bx, by, bw, bh) = t.query(Button, label="长时间运行的服务和任务").unwrap().rect
  t.tap(bx + bw / 2.0, by + bh / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfdesk.wide.jobs_open.get())
  assert_true(t.find("开了很久的网页服务 · 1") is Some(_), msg=t.words().map(fn(w) { w.0 }).join("|"))
  assert_eq(t.corner_faults(), [])
  // (pointed at, its stop over its time: out of the panel's foot corner)
  guard t.find("Willow · 整理发布清单") is Some((wx, wy)) else { fail("no job") }
  t.move_to(wx, wy)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.corner_faults(), [])
  // (its stop on its name's line, across that line's middle as its dot is, never across the middle of its two lines;
  // its dot's left edge where the group's heading's words start)
  guard t.rect_of("web") is Some((_, ny, _, nh)) else { fail("no name") }
  let name_mid = ny + nh / 2.0
  let stop = t
    .semantics()
    .iter()
    .find_first(fn(s) { s.role == @ui.Role::Button && !s.hidden && s.label.contains("web") })
  guard stop is Some(stop) else { fail("no stop") }
  let stop_mid = stop.rect.1 + stop.rect.3 / 2.0
  assert_true((stop_mid - name_mid).abs() <= 1.0, msg="the stop's middle at \{stop_mid}, its name's line's at \{name_mid}")
  guard t.rect_of("开了很久的网页服务 · 1") is Some((hx, _, _, _)) else { fail("no heading") }
  let dot = t
    .boxes_held()
    .iter()
    .find_first(fn(b) {
      // (its dot: up, the theme's Positive (jobs_pop_node's job_dot_up), 8 across)
      b.kind != "text" &&
      b.bg == @ui.tree_theme().color(@ui.Color::Positive) &&
      b.w == 8.0 &&
      b.h == 8.0 &&
      (b.y + b.h / 2.0 - name_mid).abs() <= 1.0
    })
  guard dot is Some(dot) else { fail("no dot on the name's line") }
  assert_true((dot.x - hx).abs() <= 1.0, msg="the dot's left at \{dot.x}, the heading's words at \{hx}")
  // pressed again: closed
  t.tap(bx + bw / 2.0, by + bh / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_false(@sfdesk.wide.jobs_open.get())
  assert_true(t.find("开了很久的网页服务 · 1") is None)
  // the trouble pressed: the stations
  t.tap_text("Maple 离线")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfdesk.side_place(), "stations")
}

///|
test "wide: with the foot's band under the sidebar's lists, their last row scrolled to their end stands clear over it" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="home-foot", h=520.0)
  t.run_for(@ui.move_most_ms)
  guard t.find("Maple 离线") is Some((_, mc)) else { fail("no foot") }
  t.wheel(170.0, 260.0, 5000.0)
  t.run_for(@ui.move_most_ms * 2.0)
  // (the band's top: the trouble's row 32 high round its words' middle, the band's 8 over it)
  let band_top = mc - 16.0 - 8.0
  // (each row whole over it: its ground, where it is pressed)
  let under = t
    .semantics()
    .filter(fn(r) { r.role == @ui.Role::Link && !r.hidden && r.rect.0 >= 48.0 && r.rect.0 < 290.0 && r.rect.1 + r.rect.3 > band_top + 0.5 })
    .map(fn(r) { r.label + "@" + (r.rect.1 + r.rect.3).to_string() })
  assert_eq(under, [])
}

///|
test "wide: what is left up long past the panel's room scrolls in the 运行中 panel, opened to all of it" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="home-foot-many")
  t.run_for(@ui.move_most_ms)
  let (bx, by, bw, bh) = t.query(Button, label="长时间运行的服务和任务").unwrap().rect
  t.tap(bx + bw / 2.0, by + bh / 2.0)
  t.run_for(@ui.move_most_ms)
  // its first group opened to all of it: more than the panel's room
  guard t.words().iter().find_first(fn(w) { w.0.has_prefix("还有") }) is Some(m) else { fail("no 还有 N 个") }
  t.tap(m.1 + m.3 / 2.0, m.2 + m.4 / 2.0)
  t.run_for(@ui.move_most_ms)
  let at = fn(name : String) { t.words().iter().find_first(fn(w) { w.0 == name }).map(fn(w) { (w.1, w.2) }) }
  guard at("服务 1") is Some((x, y0)) else { fail("no 服务 1") }
  // (as tall as its most at most: the next group's 服务 11 under it, out of view)
  guard at("服务 11") is Some((_, last0)) else {
    fail(t.words().filter(fn(w) { w.0.contains("服务") || w.0.contains("还有") }).map(fn(w) { w.0 + "@" + w.2.to_string() }).join("|"))
  }
  assert_true(last0 - y0 > 420.0, msg="服务 11 at \{last0}, 服务 1 at \{y0}")
  t.wheel(x + 20.0, y0 + 10.0, 2000.0)
  t.run_for(@ui.move_most_ms * 2.0)
  guard at("服务 11") is Some((_, last1)) else { fail("no 服务 11") }
  assert_true(last1 < last0 - 100.0, msg="服务 11 at \{last1}, was \{last0}")
  assert_eq(t.corner_faults(), [])
}

///|
test "wide: 已归档 in the sidebar asks the workspace in view's, again as another comes in view" {
  let asks : Array[String] = []
  new_run()
  let base = fixture("archived")
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      if name == "archive" {
        match params.get("scope") {
          Some(String(s)) => asks.push(s)
          _ => ()
        }
      }
      (base.topic_read)(name, params)
    },
  }
  // (已归档 on the wide frame: the sidebar's list of them, fixture_open's `archived`)
  app.nav.push(Archived)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  assert_true(asks.contains("ws1"), msg=Repr(asks).to_string())
  assert_false(asks.contains("ws2"))
  let tree = @ui.view_tree().unwrap()
  tree.event(t.time(), fn() { @sfpages.switch_workspace(src, "ws2") })
  t.run_for(@sfbase.switch_wait_ms + @ui.move_most_ms * 2.0)
  // (the switch back to the chats: 已归档 opened again, the new workspace's)
  tree.event(t.time(), fn() { app.nav.push(Archived) })
  t.run_for(@ui.move_most_ms * 2.0)
  let ws = @signals.untracked(fn() { workspace_in_view(src).0.map(fn(w) { w.id }).unwrap_or("") })
  assert_true(asks.contains("ws2"), msg=Repr((asks, ws, app.nav.top() == Archived)).to_string())
}

///|
test "beside the system's bars the workspace's button in their glass is the workspace in view's, again as another comes in view" {
  new_run()
  let src = fixture("chat")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=951.0, h=669.0, platform=1, nav_able=true)
  t.run_for(@ui.move_most_ms)
  assert_true(@sf.native_on())
  assert_true(t.query(Button, label="星火工作室") is Some(_))
  let tree = @ui.view_tree().unwrap()
  tree.event(t.time(), fn() { @sfpages.switch_workspace(src, "ws2") })
  t.run_for(@sfbase.switch_wait_ms + @ui.move_most_ms * 2.0)
  assert_true(t.query(Button, label="个人") is Some(_))
  assert_true(t.query(Button, label="星火工作室") is None)
}
