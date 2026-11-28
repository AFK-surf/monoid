// Haptics (sfbase feel.mbt, the prefs' `haptics`): 外观's 震动 turns them all off and on; something on screen coming to
// be is felt as it comes, not as it is first seen nor while it stays.

///|
test "震动 in 外观 turned off: the prefs' haptics off, nothing felt; on again, felt" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, w=390.0, h=844.0, platform=2)
  app.nav.push(Settings)
  app.nav.push(Setting(@settings.Route::Appearance))
  t.draw()
  t.run_for(@ui.move_most_ms)
  t.click(Switch, label="震动")
  t.frame()
  t.frame()
  let set = named(calls, "prefs.set")
  assert_eq(text(Some(set[set.length() - 1].params), "haptics"), "off")
  let felt = t.haptics().length()
  @ui.haptic(LongPress)
  assert_eq(t.haptics().length(), felt)
  t.click(Switch, label="震动")
  t.frame()
  t.frame()
  let set = named(calls, "prefs.set")
  assert_true(field(Some(set[set.length() - 1].params), "haptics") is Some(Null))
  @ui.haptic(LongPress)
  assert_eq(t.haptics()[t.haptics().length() - 1], @ui.LongPress)
}

///|
test "the bottom bar: a finger down or held is not felt; each place it moves on to is felt once, lifting there not again; tapping a different place once" {
  for platform in [1, 2] {
    let calls : Array[Made] = []
    let t = wide_tester(calls, w=390.0, h=844.0, platform~)
    t.draw()
    let (xs, y) = bar_places_at()
    // (the place chosen already: nothing)
    t.tap(xs[0], y)
    assert_eq(t.haptics(), [])
    // (a finger down, and held till the selection lifts into the lens: nothing)
    t.press_at(xs[0], y)
    assert_eq(t.haptics(), [])
    t.run_for(bar_hold_ms)
    t.frame()
    assert_eq(t.haptics(), [])
    // (moved on to another place: once, as a detent; moved within it, and lifted there: not again)
    t.move_to(xs[1], y)
    assert_eq(t.haptics(), [@ui.TextHandleMove])
    t.move_to(xs[1] + 2.0, y)
    assert_eq(t.haptics(), [@ui.TextHandleMove])
    t.release(xs[1], y)
    assert_true(app.nav.top() == Files)
    assert_eq(t.haptics(), [@ui.TextHandleMove])
    // (a tap on a different place: once, as the finger lifts)
    t.press_at(xs[0], y)
    assert_eq(t.haptics(), [@ui.TextHandleMove])
    t.release(xs[0], y)
    assert_true(app.nav.top() == Home)
    assert_eq(t.haptics(), [@ui.TextHandleMove, @ui.TextHandleMove])
  }
}

///|
test "the bottom bar: the 震动 setting turns holding and switching off and on" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, w=390.0, h=844.0, platform=1)
  app.nav.push(Settings)
  app.nav.push(Setting(@settings.Route::Appearance))
  t.draw()
  t.run_for(@ui.move_most_ms)
  t.click(Switch, label="震动")
  t.frame()
  t.frame()
  app.nav.pop() |> ignore
  app.nav.pop() |> ignore
  t.run_for(@ui.move_most_ms)
  let (xs, y) = bar_places_at()
  let before = t.haptics().length()
  t.press_at(xs[0], y)
  t.run_for(bar_hold_ms)
  t.frame()
  t.move_to(xs[1], y)
  t.release(xs[1], y)
  assert_true(app.nav.top() == Files)
  assert_eq(t.haptics().length(), before)
  app.nav.push(Settings)
  app.nav.push(Setting(@settings.Route::Appearance))
  t.draw()
  t.run_for(@ui.move_most_ms)
  t.click(Switch, label="震动")
  t.frame()
  t.frame()
  app.nav.pop() |> ignore
  app.nav.pop() |> ignore
  t.run_for(@ui.move_most_ms)
  let before = t.haptics().length()
  t.tap(xs[0], y)
  assert_true(app.nav.top() == Home)
  assert_eq(t.haptics()[before:].to_owned(), [@ui.TextHandleMove])
}

///|
test "what comes to be is felt as it comes: not as it is first seen, nor while it stays" {
  @sfbase.reset()
  let now = @signals.signal(false)
  let first = @signals.signal(true)
  let t = @ui.Tester::new(
    fn(_) { () },
    tree=fn(root) {
      @sfbase.felt_change_node(root, fn() { now.get() }, Confirm)
      @sfbase.felt_change_node(root, fn() { first.get() }, Reject)
    },
  )
  t.draw()
  assert_eq(t.haptics(), [])
  now.set(true)
  t.draw()
  assert_eq(t.haptics(), [@ui.Confirm])
  t.draw()
  assert_eq(t.haptics(), [@ui.Confirm])
  now.set(false)
  t.draw()
  now.set(true)
  t.draw()
  assert_eq(t.haptics(), [@ui.Confirm, @ui.Confirm])
}

///|
/// The fixture's chat on its page made as nodes (小屏), its view told only once `told` is, waiting for the viewer (its
/// cards asked) while `asks` is.
fn needed_open(told : @signals.Signal[Bool], asks : @signals.Signal[Bool]) -> @ui.Tester {
  new_run()
  let base = fixture("chat")
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let tp = base.topic(name, params).get().snapshot()
      guard name == "chat" else { return tp }
      guard told.get() else { return { value: None, error: None, version: -1 } }
      guard !asks.get() && tp.value is Some(Object(m)) else { return tp }
      let o = m.copy()
      o["asks"] = []
      { ..tp, value: Some(Json::object(o)), version: tp.version + 1 }
    },
  }
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "a chat opened while it waits for the viewer, on its page made as nodes: its view read after it opens is not felt; coming to wait while open is" {
  // opened before its view is read, the view then waiting for the viewer: nothing felt
  let told = @signals.signal(false)
  let asks = @signals.signal(true)
  let t = needed_open(told, asks)
  assert_eq(t.haptics(), [])
  told.set(true)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.haptics(), [])
  // read waiting for nothing, then coming to wait while it shows: felt once
  let told = @signals.signal(false)
  let asks = @signals.signal(false)
  let t = needed_open(told, asks)
  told.set(true)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.haptics(), [])
  asks.set(true)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.haptics(), [@ui.Confirm])
}
