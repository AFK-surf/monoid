// The bar's switches as the host is told them (bar_timing.mbt, Android's BarTiming): a place put on the stack, from the
// place left, then its page built, once, after the frame that built it; back to the chats the same.

///|
/// The app over the fixture's chats, the host's timing a list of what it was told.
fn timing_tester() -> (@ui.Tester, Array[String]) {
  let t = tester("home")
  let told : Array[String] = []
  bar_timing.val = Some({
    placed: fn(from, to) { told.push("placed \{from} → \{to}") },
    built: fn(p) { told.push("built \{p}") },
  })
  (t, told)
}

///|
/// Run on to where the bar's own motions rest (bar_rest: its springs, the ball, the icons' swap and tints), past the
/// page's switch.
fn to_bar_rest(t : @ui.Tester) -> Unit {
  let rest = bar_rest()
  if rest > t.time() {
    t.run_for(rest - t.time())
  }
}

///|
test "bar timing: 文件 tapped is told placed from the chats, then built once" {
  let (t, told) = timing_tester()
  let (xs, y) = bar_places_at()
  t.tap(xs[1], y)
  t.run_for(@ui.move_most_ms)
  assert_eq(told, ["placed chats → files", "built files"])
  to_bar_rest(t)
  t.assert_idle()
}

///|
test "bar timing: back to the chats is a switch too; the same place again is none" {
  let (t, told) = timing_tester()
  let (xs, y) = bar_places_at()
  t.tap(xs[1], y)
  t.run_for(@ui.move_most_ms)
  t.tap(xs[1], y)
  t.run_for(@ui.move_most_ms)
  t.back()
  t.run_for(@ui.move_most_ms)
  assert_eq(told, ["placed chats → files", "built files", "placed files → chats", "built chats"])
  to_bar_rest(t)
  t.assert_idle()
}

///|
test "bar timing: none set (a Tester's, the web's), a switch tells nothing and waits for nothing" {
  let t = tester("home")
  let (xs, y) = bar_places_at()
  t.tap(xs[1], y)
  t.run_for(@ui.move_most_ms)
  assert_true(bar_timed.val is None)
  to_bar_rest(t)
  t.assert_idle()
}

///|
test "大屏 W5: bar_switch 上报字面量 place，跳过同页重复点击与 attention 弹层，连点取消旧计时" {
  let calls : Array[Made] = []
  let src_ref : Ref[Source?] = Ref(None)
  let t = wide_tester(calls, mode="chat", w=1440.0, h=900.0, before=fn(s) { src_ref.val = Some(s) })
  let base = src_ref.val.unwrap()
  t.run_for(@ui.move_most_ms)
  let told : Array[String] = []
  bar_timing.val = Some({
    placed: fn(from, to) { told.push("placed \{from} → \{to}") },
    built: fn(p) { told.push("built \{p}") },
  })
  let w = @sfbase.workspace_in_view(base).0.unwrap()
  // Attention overlay must not fire bar_switch
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.rail_go(t.ctx(), base, w, "attention") })
  t.run_for(@ui.move_most_ms)
  assert_eq(told, [], msg="attention overlay must not report bar_switch")
  // Same-place click and chat-list filter switches ("chats" <-> "mine" / "watching" / "hidden") must not fire bar_switch
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.rail_go(t.ctx(), base, w, "chats") })
  t.run_for(@ui.move_most_ms)
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.rail_go(t.ctx(), base, w, "mine") })
  t.run_for(@ui.move_most_ms)
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.rail_go(t.ctx(), base, w, "watching") })
  t.run_for(@ui.move_most_ms)
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.rail_go(t.ctx(), base, w, "chats") })
  t.run_for(@ui.move_most_ms)
  assert_eq(told, [], msg="same-place and chat-list filter switches must not report bar_switch")
  // Switch chats -> stations -> chats
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.rail_go(t.ctx(), base, w, "stations") })
  t.run_for(@ui.move_most_ms)
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.rail_go(t.ctx(), base, w, "chats") })
  t.run_for(@ui.move_most_ms)
  assert_eq(
    told,
    ["placed chats → stations", "built stations", "placed stations → chats", "built chats"],
  )
  // Settings gear enter & exit from chats
  told.clear()
  t.click(Button, label=@sf.t("web-pages.settings.title"))
  t.run_for(@ui.move_most_ms)
  t.click(Button, label=@sf.t("web-pages.settings.title"))
  t.run_for(@ui.move_most_ms)
  assert_eq(
    told,
    ["placed chats → settings", "built settings", "placed settings → chats", "built chats"],
  )
  // Settings gear enter & exit from non-Home root (Place("profiles")) must report actual destination "profiles"
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.rail_go(t.ctx(), base, w, "profiles") })
  t.run_for(@ui.move_most_ms)
  told.clear()
  t.click(Button, label=@sf.t("web-pages.settings.title"))
  t.run_for(@ui.move_most_ms)
  t.click(Button, label=@sf.t("web-pages.settings.title"))
  t.run_for(@ui.move_most_ms)
  assert_eq(
    told,
    ["placed profiles → settings", "built settings", "placed settings → profiles", "built profiles"],
  )
  // Dynamic ID rejected by bar_place_literal; filter aliases normalize to "chats"; "vault" accepted
  assert_true(@sfbase.bar_place_literal("ws1/st1:s-c1") is None)
  assert_eq(@sfbase.bar_place_literal("mine"), Some("chats"))
  assert_eq(@sfbase.bar_place_literal("watching"), Some("chats"))
  assert_eq(@sfbase.bar_place_literal("hidden"), Some("chats"))
  assert_eq(@sfbase.bar_place_literal("vault"), Some("vault"))
  bar_timing.val = None
}

///|
test "大屏切换计时: page_wait 扣住首值期间只报 placed 不报 built，放行后报 built；归档 Chat 切对话 Chat 不误判；非 rail 导航打断清挂起" {
  new_run()
  let base0 = fixture("chat")
  let hold_profiles : @signals.Signal[Bool] = @signals.signal(true)
  let hold_chat_z : @signals.Signal[Bool] = @signals.signal(false)
  let base : Source = {
    ..base0,
    gates_opens: fn() { true },
    topic_read: fn(name, params) {
      if name == "profilesOverview" && hold_profiles.get() {
        { value: None, error: None, version: 0 }
      } else if name == "chat" && hold_chat_z.get() && params.get("session") == Some(Json::string("s-c1")) {
        { value: None, error: None, version: 0 }
      } else if name == "workspaceMarks" {
        {
          value: Some({
            "workspaces": { "ws1": { "chat": { "station": "ws1/st1", "key": "s-c1" } } },
          }),
          error: None,
          version: 1,
        }
      } else {
        (base0.topic_read)(name, params)
      }
    },
  }
  let told : Array[String] = []
  bar_timing.val = Some({
    placed: fn(from, place) { told.push("placed \{from} → \{place}") },
    built: fn(place) { told.push("built \{place}") },
  })
  let t = @ui.Tester::new(fn(c) { view(c, base) }, tree=app_tree(base), w=1440.0, h=900.0, platform=0)
  t.run_for(@ui.move_most_ms)
  let w = @sfbase.workspace_in_view(base).0.unwrap()
  told.clear()
  // 1. Switch to profiles while profilesOverview first value is held (wait half move_most_ms): placed fires, built waits
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.rail_go(t.ctx(), base, w, "profiles") })
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(told, ["placed chats → profiles"], msg="must not report built while page_wait holds old page")
  // Release first value: profiles is presented and built fires after drawn frame
  hold_profiles.set(false)
  t.frame()
  t.frame()
  assert_eq(told, ["placed chats → profiles", "built profiles"])
  // 2. Hold profiles again, switch chats -> profiles (held) -> stations (ready): only stations builds
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.rail_go(t.ctx(), base, w, "chats") })
  t.run_for(@ui.move_most_ms)
  told.clear()
  hold_profiles.set(true)
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.rail_go(t.ctx(), base, w, "profiles") })
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(told, ["placed chats → profiles"])
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.rail_go(t.ctx(), base, w, "stations") })
  t.run_for(@ui.move_most_ms)
  assert_eq(told, ["placed chats → profiles", "placed profiles → stations", "built stations"])
  // 3. Interrupted by non-rail navigation (direct nav.push): clears stale bar_timed
  told.clear()
  hold_profiles.set(true)
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.rail_go(t.ctx(), base, w, "profiles") })
  t.frame()
  assert_eq(told, ["placed stations → profiles"])
  @ui.view_tree().unwrap().event(t.time(), fn() { app.nav.push(Place("connects")) })
  t.run_for(@ui.move_most_ms)
  assert_true(bar_timed.val is None, msg="non-rail navigation must cancel pending bar_timed")
  hold_profiles.set(false)
  t.frame()
  assert_eq(told, ["placed stations → profiles"], msg="cancelled timer must not fire later")
  // 4. Archive Chat y -> Chats Chat z while Chat z first value is held: old Chat y must NOT satisfy built("chats")
  let chat_y : ChatRef = { station: "ws1/st1", session: "s-c2", title: "归档对话", station_name: "Willow" }
  @ui.view_tree().unwrap().event(t.time(), fn() {
    app.nav.replace_above(1, [Archived, Chat(chat_y)])
  })
  t.run_for(@ui.move_most_ms)
  told.clear()
  hold_chat_z.set(true)
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.rail_go(t.ctx(), base, w, "chats") })
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(told, ["placed archive → chats"], msg="held Chat z must not trigger premature built from old Chat y")
  hold_chat_z.set(false)
  t.frame()
  t.frame()
  assert_eq(told, ["placed archive → chats", "built chats"])
  // 5. Archive Chat y -> Chats Chat z (held), interrupted by direct nav.push(Chat x) (ready):
  //    Chat x must NOT satisfy built("chats") for target Chat z, and pending timer must be cancelled
  @ui.view_tree().unwrap().event(t.time(), fn() {
    app.nav.replace_above(1, [Archived, Chat(chat_y)])
  })
  t.run_for(@ui.move_most_ms)
  told.clear()
  hold_chat_z.set(true)
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.rail_go(t.ctx(), base, w, "chats") })
  t.frame()
  assert_eq(told, ["placed archive → chats"])
  let chat_x : ChatRef = { station: "ws1/st1", session: "s-c2", title: "另一对话", station_name: "Willow" }
  @ui.view_tree().unwrap().event(t.time(), fn() { app.nav.push(Chat(chat_x)) })
  t.run_for(@ui.move_most_ms)
  assert_true(bar_timed.val is None, msg="pushing another ready Chat must cancel pending bar_timed for held Chat z")
  assert_eq(told, ["placed archive → chats"], msg="ready Chat x must not report built(chats) for held Chat z")
  hold_chat_z.set(false)
  bar_timing.val = None
}
