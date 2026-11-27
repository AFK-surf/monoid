// The first page's wait ends at the moment its cause comes, not as a frame after it finds it (app.mbt's
// first_page_node): `first_page_ms` after the workspace came into view where what it shows never comes; and the core's
// status, read for the splash's words over it, let go of at the moment what the first page shows is answered.

///|
/// The home fixture, the chats' list and the workspaces' marks not answered while `slow`, what is let go of kept with
/// the moment it was (`let_go`).
fn first_slow_src(slow : @signals.Signal[Bool], let_go : Array[(String, Double)], now : () -> Double) -> Source {
  let base = fixture("home")
  {
    ..base,
    topic_read: fn(name, params) {
      // (the switch read only by what reads those: one read by every topic's reader tells each of them as it is set,
      // as nothing on a device does)
      if (name == "chats" || name == "workspaceMarks") && slow.get() {
        return { value: None, error: None, version: 0 }
      }
      base.topic(name, params).get().snapshot()
    },
    release: fn(name, params) {
      let_go.push((name + " " + Json::object(params).stringify(), now()))
      (base.release)(name, params)
    },
  }
}

///|
/// A moment short of another, a test's step there and back.
let first_short_ms : Double = 1.0

///|
test "what the first page shows never come: shown first_page_ms after the workspace came into view, at that moment, at any rate of frames" {
  for w in [390.0, 1280.0] {
    new_run()
    let slow = @signals.signal(true)
    let t_ref : Ref[@ui.Tester?] = Ref(None)
    let src = first_slow_src(slow, [], fn() { t_ref.val.map(fn(t) { t.time() }).unwrap_or(0.0) })
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h=800.0, platform=0)
    t_ref.val = Some(t)
    let from = first_from.val
    assert_true(from >= 0.0, msg="the wait begun at \{w}")
    t.run_for(from + first_page_ms - first_short_ms - t.time())
    assert_true(!first_shown.get(), msg="not shown just before at \{w}")
    t.run_for(first_short_ms)
    assert_true(first_shown.get(), msg="shown at its moment at \{w}")
    assert_true(!@sfbase.first_page_waits.get(), msg="its splash gone then at \{w}")
  }
}

///|
test "the core's status, read for the splash's words over the first page, let go of at the moment what the page shows is answered, no frame waited for" {
  new_run()
  let slow = @signals.signal(true)
  let let_go : Array[(String, Double)] = []
  let t_ref : Ref[@ui.Tester?] = Ref(None)
  let src = first_slow_src(slow, let_go, fn() { t_ref.val.map(fn(t) { t.time() }).unwrap_or(0.0) })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t_ref.val = Some(t)
  t.run_for(first_slow_ms)
  assert_true(@sfbase.first_page_waits.get(), msg="waiting")
  assert_true(!let_go.iter().any(fn(g) { g.0 == "status {}" }), msg="status still read")
  // answered between frames: status let go of then, before any frame after it
  let at = t.time()
  slow.set(false)
  let status = let_go.filter(fn(g) { g.0 == "status {}" })
  assert_eq(status.length(), 1)
  assert_eq(status[0].1, at)
}

///|
/// How long what the first page shows is not answered in the test above: short of first_page_ms.
let first_slow_ms : Double = splash_label_ms - 200.0

///|
test "a chat opened over the first page before what it shows is answered: status let go of at the moment the first page's is, not the chat's" {
  new_run()
  let slow = @signals.signal(true)
  let let_go : Array[(String, Double)] = []
  let t_ref : Ref[@ui.Tester?] = Ref(None)
  let home = first_slow_src(slow, let_go, fn() { t_ref.val.map(fn(t) { t.time() }).unwrap_or(0.0) })
  // (the chat answered later than what the first page shows: never, here)
  let src = {
    ..home,
    topic_read: fn(name, params) {
      if name == "chat" {
        return { value: None, error: None, version: 0 }
      }
      (home.topic_read)(name, params)
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t_ref.val = Some(t)
  t.run_for(first_slow_ms)
  // (a chat tapped on what shows of it: its own page waits for the chat too)
  @sfbase.open_page(Chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }))
  t.run_for(first_short_ms)
  assert_true(!let_go.iter().any(fn(g) { g.0 == "status {}" }), msg="status still read")
  let at = t.time()
  slow.set(false)
  let status = let_go.filter(fn(g) { g.0 == "status {}" })
  assert_eq(status.length(), 1)
  assert_eq(status[0].1, at)
}

///|
/// The home fixture, its topic `gate` (the workspaces, or the prefs: which of them is in view) not answered while
/// `unseen` (no workspace in view) and the chats' list and the
/// workspaces' marks while `slow`, what is let go of kept with the moment it was (`let_go`).
fn first_unseen_src(
  gate : String,
  unseen : @signals.Signal[Bool],
  slow : @signals.Signal[Bool],
  let_go : Array[(String, Double)],
  now : () -> Double,
) -> Source {
  let base = first_slow_src(slow, let_go, now)
  {
    ..base,
    topic_read: fn(name, params) {
      if name == gate && unseen.get() {
        return { value: None, error: None, version: 0 }
      }
      (base.topic_read)(name, params)
    },
  }
}

///|
test "what the first page shows answered in the moment the workspace comes into view, between frames: the core's status let go of then, not a frame after, on every screen" {
  // (小屏, 中屏, 大屏: the first page's check reads what its shell declares at that moment, none of it followed
  // before; read before it was, it was told of none of it and waited for the frame after)
  let cases = [
    ("workspaces", 390.0),
    ("workspaces", @sf.medium_from + 100.0),
    ("workspaces", @sf.large_from + 440.0),
    ("prefs", 390.0),
    ("prefs", @sf.large_from + 440.0),
  ]
  // (a host's frames at each rate, as a device's: none at the answer's moment, the next a frame's length on at most)
  for period in [1000.0 / 7.0, 1000.0 / 24.0, 1000.0 / 60.0, 1000.0 / 120.0] {
    for k in cases {
      let (gate, w) = k
      new_run()
      let unseen = @signals.signal(true)
      let slow = @signals.signal(true)
      let let_go : Array[(String, Double)] = []
      let t_ref : Ref[@ui.Tester?] = Ref(None)
      let src = first_unseen_src(gate, unseen, slow, let_go, fn() { t_ref.val.map(fn(t) { t.time() }).unwrap_or(0.0) })
      let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h=844.0, platform=2)
      t_ref.val = Some(t)
      t.run_for(first_slow_ms)
      assert_true(first_from.val < 0.0, msg="no workspace in view yet at \{w} (\{gate}, a frame each \{period} ms)")
      t.set_frame_period(period)
      // between two frames, at every rate: `gate` answered (the workspace in view, what its first page shows asked),
      // then, later and before the next frame, the rest of what it shows: the chats' list and the workspace's marks
      // (which say the page the wide frame's pane lands on: what that reads declared only as they are answered)
      let at = t.time() + first_between_ms
      let last = at + first_later_ms
      let read_before : Ref[Bool] = Ref(false)
      t.fake.due(at, "the workspace's \{gate} answered", fn() { unseen.set(false) })
      t.fake.due(last, "what the first page shows answered", fn() {
        read_before.val = !let_go.iter().any(fn(g) { g.0 == "status {}" })
        slow.set(false)
      })
      t.run_for(first_page_ms)
      assert_eq(first_from.val, at, msg="in view at its moment at \{w} (\{gate}, a frame each \{period} ms)")
      assert_true(read_before.val, msg="status read while the chats are not at \{w} (\{gate}, a frame each \{period} ms)")
      let status = let_go.filter(fn(g) { g.0 == "status {}" })
      assert_eq(status.length(), 1, msg="status let go of once at \{w} (\{gate}, a frame each \{period} ms)")
      assert_eq(status[0].1, last, msg="at the moment what the first page shows was answered (\{last}), not \{status[0].1}, at \{w} (\{gate}, a frame each \{period} ms)")
      assert_true(first_shown.get(), msg="shown at \{w} (\{gate}, a frame each \{period} ms)")
      // (and no fault said: a read of what the shell's function does not say stops the run, faults_stop)
      // (what the first page read held till its readers took it: none of it let go of and asked again)
      assert_eq(let_go.filter(fn(g) { g.0 != "status {}" }).length(), 0, msg="nothing else let go of at \{w} (\{gate}, a frame each \{period} ms): \{@ui.list_text(let_go.map(fn(g) { g.0 }))}")
    }
  }
}

///|
/// A moment after a host's frame and short of the next at any rate of frames tested (7 to 120 a second): between two.
let first_between_ms : Double = 5.0

///|
/// How long after the workspace comes into view the rest of what the first page shows is answered, before the next
/// frame at any rate tested (5 + 2 ms, short of 120 a second's 8.33).
let first_later_ms : Double = 2.0

///|
test "wide: a chat landed on over Home before what the first page shows is answered is the first page, waited for; a place of the rail's gone to ends the wait" {
  for case in ["landed", "place"] {
    new_run()
    let slow = @signals.signal(true)
    let let_go : Array[(String, Double)] = []
    let t_ref : Ref[@ui.Tester?] = Ref(None)
    let home = first_slow_src(slow, let_go, fn() { t_ref.val.map(fn(t) { t.time() }).unwrap_or(0.0) })
    let src = {
      ..home,
      topic_read: fn(name, params) {
        if name == "chat" {
          return { value: None, error: None, version: 0 }
        }
        (home.topic_read)(name, params)
      },
    }
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
    t_ref.val = Some(t)
    t.run_for(first_slow_ms)
    if case == "landed" {
      // (as sfdesk's land puts the chat it lands on over Home)
      app.nav.push(Chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }))
      t.run_for(first_short_ms)
      assert_true(!let_go.iter().any(fn(g) { g.0 == "status {}" }), msg="landed: status still read")
      assert_true(!first_shown.get(), msg="landed: not shown")
    } else {
      // (the rail's 文件 pressed: the first page never shows)
      @sfbase.go_place("files") |> ignore
      t.run_for(first_short_ms)
      assert_true(let_go.iter().any(fn(g) { g.0 == "status {}" }), msg="a place gone to: status let go of")
      t.run_for(@ui.move_most_ms)
      assert_true(first_shown.get(), msg="a place gone to: shown")
    }
  }
}

///|
let first_reading_wait_ms : Double = 300.0

///|
let first_after_splash_ms : Double = 50.0

///|
test "a chat opens at the first page's deadline and waits for its data on the next visit" {
  let base = fixture_app("chat")
  let workspace_pending = @signals.signal(true)
  let chat_pending = @signals.signal(true)
  let src = {
    ..base,
    topic_read: fn(name, params) {
      if (name == "workspaces" && workspace_pending.get()) || (name == "chat" && chat_pending.get()) {
        return { value: None, error: None, version: -1 }
      }
      (base.topic_read)(name, params)
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  let chat = app.nav.top()
  t.run_for(splash_label_ms - @sf.local_ms)
  workspace_pending.set(false)
  t.draw()
  assert_true(app.nav.top_waits(), msg="the chat must first wait for its local content")
  t.run_for(first_page_ms / 2.0)
  assert_true(first_shown.get())
  assert_true(!app.nav.top_waits(), msg="startup ended but the chat is still waiting over Home")
  t.run_for(@ui.move_ms(390.0))
  assert_true(!app.nav.root_shows(), msg="Home is still on screen")
  t.back()
  t.run_for(@ui.move_ms(390.0))
  @sfbase.open_page(chat)
  t.draw()
  assert_true(app.nav.top_waits(), msg="a second open of this chat needs its own wait")
  chat_pending.set(false)
  t.draw()
  assert_true(!app.nav.top_waits(), msg="the local chat has arrived")
}

///|
test "workspaces arrive after 300ms in Reading while a non-critical first-page topic stays unanswered: first page releases before splash_label_ms with no loading bar" {
  for w in [390.0, 1280.0] {
    new_run()
    let unseen = @signals.signal(true)
    let slow = @signals.signal(true)
    let t_ref : Ref[@ui.Tester?] = Ref(None)
    let src = first_unseen_src("workspaces", unseen, slow, [], fn() { t_ref.val.map(fn(t) { t.time() }).unwrap_or(0.0) })
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h=800.0, platform=0)
    t_ref.val = Some(t)
    let t0 = t.time()
    assert_eq(splash_from.val, t0, msg="splash_from at first frame at \{w}")
    t.run_for(first_reading_wait_ms)
    unseen.set(false)
    t.frame()
    assert_true(first_from.val >= t0 + first_reading_wait_ms, msg="workspace entered view at \{w}")
    // Advance across splash_label_ms: first_page_node must release just before splash_label_ms so first_splash_node never shows.
    t.run_for(t0 + splash_label_ms - t.time())
    assert_true(first_shown.get(), msg="first_shown must be true by splash_label_ms at \{w}")
    assert_true(!@sfbase.first_page_waits.get(), msg="first_page_waits must be false at \{w}")
    assert_true(t.find(tr("android-misc.workspaces.loading")) is None, msg="no loading bar shown at splash_label_ms at \{w}")
    t.run_for(first_after_splash_ms)
    assert_true(t.find(tr("android-misc.workspaces.loading")) is None, msg="no loading bar shown after splash_label_ms at \{w}")
  }
}

///|
test "A1: bottom bar is hidden and non-interactive while first_page_waits, then appears in the same frame as Home" {
  // First measure the exact hit point of the Station tab on Small 390x844 at rest.
  new_run()
  let ref_src = fixture("home")
  let ref_t = @ui.Tester::new(fn(c) { view(c, ref_src) }, tree=app_tree(ref_src), w=390.0, h=844.0, platform=2)
  ref_t.run_for(@ui.move_most_ms)
  let (bx, by, bw, bh) = tab_named_at(ref_t, "Station")
  let (tap_x, tap_y) = (bx + bw / 2.0, by + bh / 2.0)
  let bar_drawn_at = fn(t : @ui.Tester) {
    let s = t.sources_at(tap_x, tap_y)
    s.contains("bar_node.mbt") || s.contains("bar.mbt")
  }
  assert_true(bar_drawn_at(ref_t), msg="reference bottom bar drawn at tap point: \{ref_t.sources_at(tap_x, tap_y)}")

  // Now cold-start with chats unanswered so first_page_waits stays true.
  new_run()
  let slow = @signals.signal(true)
  let t_ref : Ref[@ui.Tester?] = Ref(None)
  let src = first_slow_src(slow, [], fn() { t_ref.val.map(fn(t) { t.time() }).unwrap_or(0.0) })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t_ref.val = Some(t)
  t.run_for(first_slow_ms)
  assert_true(@sfbase.first_page_waits.get(), msg="still waiting for first page")
  assert_true(!first_shown.get(), msg="first_shown still false")
  // Bottom bar must not be visible in semantics or drawn output while waiting.
  let bar_visible_while_waiting = t.semantics().iter().any(fn(s) { !s.hidden && s.label.has_prefix("Station") })
  assert_false(bar_visible_while_waiting, msg="bottom bar must be hidden from semantics while first_page_waits")
  assert_false(bar_drawn_at(t), msg="bottom bar must not be drawn while first_page_waits: \{t.sources_at(tap_x, tap_y)}")
  assert_true(t.find("整理发布清单") is None, msg="Home must be hidden while first_page_waits")
  // Tapping the bottom bar coordinates while waiting must not switch tabs.
  t.tap(tap_x, tap_y)
  t.frame()
  assert_true(app.nav.top() == Home, msg="tapping hidden bottom bar must not navigate")

  // Answer chats: Home and bottom bar must appear on the very same frame.
  slow.set(false)
  t.frame()
  assert_true(first_shown.get(), msg="first_shown true once answered")
  assert_false(@sfbase.first_page_waits.get(), msg="first_page_waits false once answered")
  assert_true(t.find("整理发布清单") is Some(_), msg="Home visible on release frame")
  assert_true(bar_drawn_at(t), msg="bottom bar drawn on the same frame as Home: \{t.sources_at(tap_x, tap_y)}")
  let bar_visible_now = t.semantics().iter().any(fn(s) { !s.hidden && s.label.has_prefix("Station") })
  assert_true(bar_visible_now, msg="bottom bar visible on the same frame as Home")
  // And now tapping Station switches to the Stations place.
  t.tap(tap_x, tap_y)
  t.frame()
  assert_true(app.nav.top() == @sfbase.place_page("stations"), msg="bottom bar interactive once shown")
}

///|
test "A2: workspaces arrive at 800ms (due=1100ms <= 1200ms) with chats unanswered: no loading bar flash across 1000ms at 7/24/60/120 fps" {
  for period in [1000.0 / 7.0, 1000.0 / 24.0, 1000.0 / 60.0, 1000.0 / 120.0] {
    new_run()
    let told : Array[(Double, Double, Bool, Bool)] = []
    first_page_timing.val = Some(fn(shown, in_view, waited, expired) { told.push((shown, in_view, waited, expired)) })
    let unseen = @signals.signal(true)
    let slow = @signals.signal(true)
    let t_ref : Ref[@ui.Tester?] = Ref(None)
    let src = first_unseen_src("workspaces", unseen, slow, [], fn() { t_ref.val.map(fn(t) { t.time() }).unwrap_or(0.0) })
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
    t_ref.val = Some(t)
    let t0 = t.time()
    assert_eq(splash_from.val, t0, msg="splash_from at first frame (period=\{period})")
    t.set_frame_period(period)
    t.fake.due(t0 + 800.0, "workspaces arrive at 800ms", fn() { unseen.set(false) })
    // Step frame-by-frame up to just before 1100ms expiry: loading bar must never appear on any frame.
    while t.time() + period < t0 + 1100.0 {
      t.frame_at(t.time() + period)
      assert_false(first_shown.get(), msg="not yet shown at \{t.time() - t0}ms (period=\{period})")
      assert_true(t.find(tr("android-misc.workspaces.loading")) is None, msg="loading bar suppressed at \{t.time() - t0}ms (period=\{period})")
    }
    // Also explicitly sample at 1050ms (past splash_label_ms=1000ms, before due=1100ms).
    if t.time() < t0 + 1050.0 {
      t.frame_at(t0 + 1050.0)
    }
    assert_false(first_shown.get(), msg="not yet shown at 1050ms (period=\{period})")
    assert_true(splash_waited.get(), msg="splash_waited is true at 1050ms (period=\{period})")
    assert_true(t.find(tr("android-misc.workspaces.loading")) is None, msg="loading bar suppressed at 1050ms (period=\{period})")
    assert_true(frame_bare.val, msg="frame stays bare while splash suppressed (period=\{period})")
    // Advance past 1100ms expiry: Home releases cleanly with no loading bar ever shown.
    t.frame_at(t0 + 1100.0)
    assert_true(first_shown.get(), msg="first_shown true at 1100ms (period=\{period})")
    assert_false(@sfbase.first_page_waits.get(), msg="first_page_waits false at 1100ms (period=\{period})")
    assert_true(t.find(tr("android-misc.workspaces.loading")) is None, msg="no loading bar at 1100ms (period=\{period})")
    assert_eq(told.length(), 1, msg="timing reported once (period=\{period})")
    assert_true(told[0].3, msg="expired reported as true (period=\{period})")
  }
}

///|
test "A2: workspaces arrive at 950ms (due=1250ms > 1200ms) with chats unanswered: loading bar still shows at 1000ms" {
  new_run()
  let unseen = @signals.signal(true)
  let slow = @signals.signal(true)
  let t_ref : Ref[@ui.Tester?] = Ref(None)
  let src = first_unseen_src("workspaces", unseen, slow, [], fn() { t_ref.val.map(fn(t) { t.time() }).unwrap_or(0.0) })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t_ref.val = Some(t)
  let t0 = t.time()
  t.fake.due(t0 + 950.0, "workspaces arrive at 950ms", fn() { unseen.set(false) })
  t.run_for(t0 + 1050.0 - t.time())
  assert_false(first_shown.get(), msg="not yet shown at 1050ms")
  assert_true(splash_waited.get(), msg="splash_waited is true at 1050ms")
  assert_true(t.find(tr("android-misc.workspaces.loading")) is Some(_), msg="loading bar shows when due > 1200ms")
  assert_false(frame_bare.val, msg="frame is not bare once loading bar shows")
}

///|
test "cached host theme pref applies before prefs arrive and persists changes once prefs load" {
  fresh_app()
  let saved : Array[String] = []
  @sfbase.cached_theme_pref.val = "dark"
  @sfbase.on_theme_pref.val = Some(fn(mode) { saved.push(mode) })
  // Before prefs arrive on a light system, cached "dark" must keep frame 0 dark without notifying host again.
  let before = @sfbase.appearance_from_prefs(None, false)
  assert_true(before, msg="cached dark pref should apply before prefs arrive")
  assert_eq(saved, [])
  // Once prefs arrive with explicit "light", it applies and notifies the host once.
  let after = @sfbase.appearance_from_prefs(Some(Json::object({ "appearance": Json::string("light") })), false)
  assert_false(after, msg="explicit light pref should apply once prefs arrive")
  assert_eq(saved, ["light"])
  // Repeated call with same theme does not redundantly persist.
  let again = @sfbase.appearance_from_prefs(Some(Json::object({ "appearance": Json::string("light") })), false)
  assert_false(again)
  assert_eq(saved, ["light"])
}

///|
test "P0-6: remounting first_page_node after transient Failed/Starting re-arms expiry and never sticks blank" {
  new_run()
  let fatal_msg : @signals.Signal[String?] = @signals.signal(None, same=fn(a, b) { a == b })
  let slow = @signals.signal(true)
  let t_ref : Ref[@ui.Tester?] = Ref(None)
  let base = first_slow_src(slow, [], fn() { t_ref.val.map(fn(t) { t.time() }).unwrap_or(0.0) })
  let src : Source = { ..base, fatal: fn() { fatal_msg.get() } }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t_ref.val = Some(t)
  assert_true(first_from.val >= 0.0, msg="first_from recorded on initial SignedIn")
  let due = first_due.val
  assert_true(due > t.time(), msg="first_due scheduled in the future")
  // Briefly leave SignedIn (unmounts first_page_node and cancels its original at_moment timer), then return before due.
  let brief_pause_ms = @sf.local_ms
  t.run_for(brief_pause_ms)
  fatal_msg.set(Some("core restarted"))
  t.frame()
  assert_true(app_is(src) == Failed, msg="entered Failed state")
  t.run_for(brief_pause_ms)
  fatal_msg.set(None)
  t.frame()
  assert_true(app_is(src) == SignedIn, msg="returned to SignedIn before due")
  assert_false(first_shown.get(), msg="still waiting before due")
  // Advance past original first_due: restored expiry timer must fire and release Home.
  t.run_for(due - t.time() + 10.0)
  assert_true(first_expired.get(), msg="first_expired must fire after remount")
  assert_true(first_shown.get(), msg="first_shown must become true after remount expiry")
  assert_false(@sfbase.first_page_waits.get(), msg="must not remain stuck blank")
}

///|
test "frame-0 cached_workspace collapses 2-round-trip cold start to 1 round-trip with zero unsub/resub and handles stale cache" {
  let rt_ms = 200.0
  let after_one_rt_ms = rt_ms + @sf.local_ms
  let after_two_rts_ms = rt_ms * 2.0 + @sf.local_ms
  // 1) Baseline without cached_workspace: takes 2 serial round-trips (2 * rt_ms).
  new_run()
  let base_heard : Array[String] = []
  let base_src = round_trip_again(fixture("home"), rt_ms, heard=fn(h) { base_heard.push(h) })
  let t_base = @ui.Tester::new(fn(c) { view(c, base_src) }, tree=app_tree(base_src), w=390.0, h=844.0, platform=2)
  let base_t0 = t_base.time()
  t_base.run_for(after_one_rt_ms)
  assert_false(first_shown.get(), msg="without cached_workspace, 1 round-trip is not enough")
  t_base.run_for(after_one_rt_ms)
  assert_true(first_shown.get(), msg="without cached_workspace, shown after 2 round-trips (from \{base_t0})")

  // 2) Hit with cached_workspace="ws1": completes in 1 round-trip (~200ms) with zero unsub/resub!
  new_run()
  let hit_saved : Array[String] = []
  @sfbase.cached_workspace.val = "ws1"
  @sfbase.on_workspace_pref.val = Some(fn(ws) { hit_saved.push(ws) })
  let hit_heard : Array[String] = []
  let hit_src = round_trip_again(fixture("home"), rt_ms, heard=fn(h) { hit_heard.push(h) })
  let t_hit = @ui.Tester::new(fn(c) { view(c, hit_src) }, tree=app_tree(hit_src), w=390.0, h=844.0, platform=2)
  t_hit.run_for(after_one_rt_ms)
  assert_true(first_shown.get(), msg="with cached_workspace hit, Home shows in 1 round-trip (~200ms)")
  assert_eq(hit_saved, [], msg="matching cached_workspace does not redundantly persist")
  assert_eq(asked_again(hit_heard), [], msg="frame-0 pre-subscribe hands off with zero unsub/resub")

  // 3) Stale cached_workspace="ws-stale": unsubscribes stale workspace once ws1 resolves and persists "ws1".
  new_run()
  let stale_saved : Array[String] = []
  @sfbase.cached_workspace.val = "ws-stale"
  @sfbase.on_workspace_pref.val = Some(fn(ws) { stale_saved.push(ws) })
  let stale_heard : Array[String] = []
  let stale_src = round_trip_again(fixture("home"), rt_ms, heard=fn(h) { stale_heard.push(h) })
  let t_stale = @ui.Tester::new(fn(c) { view(c, stale_src) }, tree=app_tree(stale_src), w=390.0, h=844.0, platform=2)
  t_stale.run_for(after_two_rts_ms)
  assert_true(first_shown.get(), msg="stale cached_workspace still settles cleanly on real ws1")
  assert_eq(stale_saved, ["ws1"], msg="stale cached_workspace updates host cache to ws1")
  assert_true(
    stale_heard.iter().any(fn(h) { h.contains("\"unsubscribe\":true") }),
    msg="stale cached_workspace subscriptions must be unsubscribed",
  )

  // 4) Signed in with 0 workspaces (Landing): permanently consumes cached_workspace, unsubscribes stale topics, clears host cache.
  new_run()
  let landing_saved : Array[String] = []
  @sfbase.cached_workspace.val = "ws-gone"
  @sfbase.on_workspace_pref.val = Some(fn(ws) { landing_saved.push(ws) })
  let landing_heard : Array[String] = []
  let empty_ws_base = fixture("home")
  let empty_ws_src : Source = {
    ..empty_ws_base,
    topic_read: fn(name, params) {
      if name == "workspaces" {
        return {
          value: Some(Json::array([{ "account": { "sub": "u1" }, "workspaces": [], "loaded": true }])),
          error: None,
          version: 1,
        }
      }
      empty_ws_base.topic(name, params).get().snapshot()
    },
  }
  let landing_src = round_trip_again(empty_ws_src, rt_ms, heard=fn(h) { landing_heard.push(h) })
  let t_landing = @ui.Tester::new(fn(c) { view(c, landing_src) }, tree=app_tree(landing_src), w=390.0, h=844.0, platform=2)
  t_landing.run_for(after_one_rt_ms)
  assert_true(landing_now(landing_src), msg="entered Landing with 0 workspaces")
  assert_eq(landing_saved, [""], msg="Landing clears stale cached_workspace in host")
  assert_true(
    landing_heard.iter().any(fn(h) { h.contains("ws-gone") }) &&
    landing_heard.iter().any(fn(h) { h.contains("\"unsubscribe\":true") }),
    msg="Landing must unsubscribe stale pre-subscribed workspace topics",
  )

  // 5) Starting -> SignedOut -> Starting does NOT remount already-consumed cached_workspace.
  new_run()
  @sfbase.cached_workspace.val = "ws-old"
  let signed_out = @signals.signal(false)
  let accounts_pending = @signals.signal(true)
  let so_reads : Array[String] = []
  let so_base = fixture("home")
  let so_src : Source = {
    ..so_base,
    topic_read: fn(name, params) {
      so_reads.push(name + ":" + Json::object(params).stringify())
      if name == "accounts" {
        if accounts_pending.get() {
          return { value: None, error: None, version: 0 }
        } else if signed_out.get() {
          return { value: Some(Json::array([])), error: None, version: 2 }
        }
      }
      if name == "workspaces" && (accounts_pending.get() || signed_out.get()) {
        return { value: None, error: None, version: 0 }
      }
      so_base.topic(name, params).get().snapshot()
    },
  }
  let t_so = @ui.Tester::new(fn(c) { view(c, so_src) }, tree=app_tree(so_src), w=390.0, h=844.0, platform=2)
  assert_true(app_is(so_src) == Starting, msg="started in Starting")
  assert_true(
    so_reads.iter().any(fn(h) { h.contains("ws-old") }),
    msg="frame-0 pre-sub reads ws-old during initial Starting",
  )
  accounts_pending.set(false)
  signed_out.set(true)
  t_so.frame()
  assert_true(app_is(so_src) == SignedOut, msg="transitioned to SignedOut")
  let count_after_out = so_reads.length()
  accounts_pending.set(true)
  signed_out.set(false)
  t_so.frame()
  assert_true(app_is(so_src) == Starting, msg="re-entered Starting after SignedOut")
  let remounted_old = so_reads[count_after_out:].iter().any(fn(h) { h.contains("ws-old") })
  assert_false(remounted_old, msg="consumed cached_workspace must never remount on SignedOut -> Starting")
}

///|
test "list_opens asks active filtered query in parallel once prefs answer without waiting for base all list" {
  fresh_app()
  let base = fixture("home")
  let prefs_json : Json = { "listFilter": { "ws1": "mine" } }
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      if name == "prefs" {
        return { value: Some(prefs_json), error: None, version: 1 }
      }
      base.topic(name, params).get().snapshot()
    },
  }
  let asked : Array[String] = []
  let ok = @sfbase.list_opens(src, "ws1", fn(name, params) {
    asked.push(name + ":" + Json::object(params).stringify())
    if name == "prefs" {
      { value: Some(prefs_json), error: None, version: 1, waiting: false }
    } else {
      // Base "all" list has NOT answered yet!
      { value: None, error: None, version: 0, waiting: false }
    }
  })
  assert_false(ok, msg="list_opens stays false while chats unanswered")
  assert_true(
    asked.iter().any(fn(s) { s.contains("\"mine\":false") }),
    msg="asked base all list: \{Repr(asked)}",
  )
  assert_true(
    asked.iter().any(fn(s) { s.contains("\"mine\":true") }),
    msg="must ask active filtered query in parallel without waiting for base all list: \{Repr(asked)}",
  )
}
