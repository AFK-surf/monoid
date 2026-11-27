// The bottom bar, the sheets and a new chat over the fixture (newchat_fixture.mbt), 390 × 844.

///|
/// The bar's places' middles in the window with the notch open (the chats' pages), and its middle's height.
fn bar_places_at() -> (Array[Double], Double) {
  (bar_centres(390.0 - 44.0, 1.0, 4).map(fn(x) { x + 22.0 }), 844.0 - 22.0 - 28.0)
}

///|
/// Where the bar's action (令, ＋) is across in a 390 window: the middle of its circle at the bar's right.
let bar_action_x : Double = 22.0 + (390.0 - 44.0) - act_size / 2.0

///|
test "the bar: a finger held still on it a moment has the ball a lens of liquid glass; a tap none; let go, the ball" {
  let t = tester("home")
  let (xs, y) = bar_places_at()
  // (the lens: liquid glass in the bottom bar neither as high as the bar, as the capsule and 令's circle are, nor as tall as its panel)
  let (_, h) = t.size()
  let lensed = fn() { t.drawn_glass().iter().any(fn(g) { g.4 == 6 && g.1 >= h / 2.0 && (g.3 - bar_track).abs() > 1.0 && g.3 < 80.0 }) }
  t.tap(xs[0], y)
  t.run_for(bar_hold_ms)
  assert_false(lensed())
  t.press_at(xs[0], y)
  t.run_for(bar_hold_ms)
  // (the frame at its time takes the ball; its lens grows from there)
  t.frame()
  to_bar_rest(t)
  assert_true(lensed())
  t.release(xs[0], y)
  to_bar_rest(t)
  assert_false(lensed())
  assert_true(t.find("整理发布清单") is Some(_))
}

///|
test "the bar: holding a place keeps 令 or ＋ beside the capsule, moving too, and letting go it still works" {
  let held_frame_ms = 1000.0
  let moved_frame_ms = 100.0
  for action in ["ling", "plus"] {
    let t = tester("home")
    let place = if action == "ling" { "chats" } else { bar_place_with("plus") }
    if action == "plus" {
      assert_true(@sfbase.go_place(place))
      t.run_for(@ui.move_most_ms)
    }
    assert_eq(m_face.val, bar_action_icon(action))
    let (xs, y) = bar_places_at()
    let told = bar.told.unwrap()
    let j = told.sets[told.cur].search(place).unwrap()
    let x = xs[j]
    // The action's circle of glass at the bar's right is the button (drawn while it is seen at all).
    let disc_alpha = fn() {
      let x = 22.0 + (390.0 - 44.0) - act_size
      if t.drawn_glass().any(fn(g) {
          (g.2 - act_size).abs() < 0.1 && (g.3 - act_size).abs() < 0.1 && (g.0 - x).abs() < 0.1 && g.1 > 600.0
        }) {
        1L
      } else {
        0L
      }
    }
    assert_true(disc_alpha() > 0L, msg="\{action} before holding")
    t.press_at(x, y)
    t.run_for(bar_hold_ms / 2.0)
    assert_true(disc_alpha() > 0L, msg="\{action} before the hold")
    t.run_for(bar_hold_ms / 2.0)
    t.frame()
    t.run_for(held_frame_ms)
    assert_true(disc_alpha() > 0L, msg="\{action} held")
    t.move_to(x + 12.0, y)
    t.run_for(moved_frame_ms)
    assert_true(disc_alpha() > 0L, msg="\{action} moved")
    t.release(x + 12.0, y)
    t.run_for(held_frame_ms)
    assert_true(disc_alpha() > 0L, msg="\{action} released")
    if action == "ling" {
      t.tap(bar_action_x, y)
      assert_true(app.nav.risen(), msg="令 works after letting go")
    }
  }
}

///|
test "the bar: 文件 tapped is its page in place of the chats', back is the chats again" {
  let t = tester("home")
  let (xs, y) = bar_places_at()
  t.tap(xs[1], y)
  assert_eq(app.nav.depth(), 1)
  assert_true(app.nav.top() == Files)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("文件") is Some(_))
  assert_true(t.find("整理发布清单") is None)
  // back goes to the chats, in place
  t.back()
  assert_true(app.nav.top() == Home)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("整理发布清单") is Some(_))
}

///|
/// Where the words `title` are drawn in the top bar's band, the leftmost (a page's own title, not the back of the page
/// coming in beside it to its right, which names it too).
fn bar_title_x(t : @ui.Tester, title : String) -> Double {
  t
  .words()
  .fold(init=1.0e9, fn(a, w) { if w.0 == title && w.2 < status_top_now(390.0) + top_bar_h_at(390.0) && w.1 < a { w.1 } else { a } })
}

///|
/// The words drawn in the top bar's band of the page a width wide from `from` on, as (words, x − from, y): the page's
/// there, not the one beside it.
fn bar_words(t : @ui.Tester, from : Double) -> Array[(String, Double, Double)] {
  t
  .words()
  .filter(fn(w) { w.2 < status_top_now(390.0) + top_bar_h_at(390.0) && w.1 >= from - 0.5 && w.1 < from + 390.0 - 0.5 })
  .map(fn(w) { (w.0, (w.1 - from).round(), w.2.round()) })
}

///|
test "文件 and 用量 at the bar's top, their gear tapped: as 设置 comes in beside them they keep their place's top bar, no back on it" {
  for place in ["files", "usage"] {
    let title = place_label(place)
    let t = tester("home")
    @sfbase.go_place(place) |> ignore
    t.run_for(@ui.move_most_ms)
    let rest_x = bar_title_x(t, title)
    let at_rest = bar_words(t, 0.0)
    let gear = t.locate("icon:settings")
    assert_eq(gear.length(), 1, msg=place)
    // at the bar's right edge, right of the place's name, as Home's is
    assert_true(gear[0].0 > rest_x && gear[0].0 > 390.0 - 16.0 - 34.0, msg="\{place}: \{gear[0].0}")
    t.tap(gear[0].0, gear[0].1)
    assert_true(app.nav.top() == Settings, msg=place)
    // halfway through 设置's slide in from the right: the place's page going out to the left beside it is drawn as it
    // was at rest, moved (the stack two deep, it is still its root: its gear, not a way back to 设置)
    t.run_for(@ui.move_most_ms / 2.0)
    let from = bar_title_x(t, title) - rest_x
    assert_true(from < 0.0, msg=place)
    let under_words = bar_words(t, from)
    let title_idx = at_rest.search_by(fn(w) { w.0 == title }).unwrap()
    assert_true(under_words.length() > title_idx, msg=place)
    assert_eq(under_words[:title_idx + 1].to_owned(), at_rest[:title_idx + 1].to_owned(), msg=place)
  }
}

///|
test "the panel drawn up by a finger: the bar and the panel drawn up clear of the finger, a finger taken where they are laid out; let go, back down" {
  let t = tester("home")
  let (xs, y) = bar_places_at()
  // the bar's capsule of glass (from its left, wider than the lens: not the lens', nor 令's): where its foot is drawn
  let foot = fn() {
    t.drawn_glass_corners().fold(init=0.0, fn(a, g) { if (g.0 - 22.0).abs() < 1.0 && g.2 > 250.0 { dmax(a, g.1 + g.3) } else { a } })
  }
  let rest = foot()
  t.press_at(xs[0], y)
  for i in 1..=20 {
    t.move_to(xs[0], y - 64.0 * i.to_double() / 20.0)
  }
  t.run_for(@ui.move_most_ms)
  let held = foot()
  // a finger's place is where the rows are laid out: let go over the other bar's row, that bar
  t.release(xs[0], 844.0 - 22.0 - 132.0 + 20.0 + 28.0)
  // (the test's end: all of the bar at rest, the bar chosen landed)
  t.run_for(bar.rest() - t.time())
  assert_eq(((rest - held).round(), (rest - foot()).round()), (59.0, 0.0))
  assert_true(app.nav.top() == Place("remote"))
}

///|
test "the bar: drawn up, the panel of the other bar; let go on its first place, that bar and 远程" {
  let t = tester("home")
  let (xs, y) = bar_places_at()
  t.drag(xs[0], y, xs[0], y - 64.0, steps=20)
  // the panel on its way open, to where it rests
  t.run_for(bar.o.end() - t.time())
  // let go over the rows before the panel was all the way open: it stays open
  if app.nav.top() == Home {
    assert_true(bar.mode.get())
    // the row of the other bar: its first place
    t.tap(xs[0], 844.0 - 22.0 - 132.0 + 20.0 + 28.0)
  }
  assert_true(app.nav.top() == Place("remote"))
  assert_true(t.find("远程") is Some(_))
  match bars_picked.get() {
    Some((_, cur)) => assert_eq(cur, 1)
    None => fail("no bar picked")
  }
}

///|
test "the bar: hidden under a page pushed, back as it comes back" {
  let t = tester("home")
  assert_true(bar.vis.at(t.time()).0 > 0.99)
  t.tap_text("夜里的构建又失败了")
  t.run_for(bar_hide_ms)
  assert_true(bar.vis.at(t.time()).0 < 0.01)
  t.back()
  t.run_for(@ui.move_most_ms)
  assert_true(bar.vis.at(t.time()).0 > 0.99)
}

///|
test "the workspaces' sheet: as tall as what it holds, not drawn taller by its top, dragged down past 30% it closes" {
  let t = tester("home")
  @sfpages.open_workspaces(fixture("home"), Unanchored)
  presented_rested(t)
  // (two workspaces: shorter than its share of the window, 70%)
  let h = t.get(@ui.Role::Dialog).rect.3
  assert_true(h < 844.0 * 0.7 - 100.0, msg="\{h} tall")
  let (x, y) = t.find("切换 workspace").unwrap()
  t.drag(x, y, x, y - 200.0)
  presented_rested(t)
  assert_eq(t.get(@ui.Role::Dialog).rect.3, h)
  let (x, y) = t.find("切换 workspace").unwrap()
  t.drag(x, y, x, y + 300.0)
  presented_rested(t)
  assert_true(t.find("切换 workspace") is None)
  assert_true(!sheet_open())
}

///|
test "a sheet takes the drags on it: the list under it does not scroll" {
  let t = tester("home")
  // (where the list is, by a row of it)
  let row = fn() { t.locate("=把旧的截图都换成新的").map(fn(p) { p.1 }) }
  let before = row()
  @sfpages.open_workspaces(fixture("home"), Unanchored)
  presented_rested(t)
  t.drag(195.0, 700.0, 195.0, 400.0)
  assert_eq(row(), before)
  assert_true(@sf.presenting())
}

///|
/// Frames on to where what the presenters hold up as a sheet said it is at rest, whichever kind it is drawn as
/// (@sf.presented_rest: its motions' ends, from their causes' moments and lengths).
fn presented_rested(t : @ui.Tester) -> Unit {
  t.draw()
  let e = @sf.presented_rest()
  if e > t.time() && e < 1.0e300 {
    t.run_for(e - t.time())
  }
}

///|
test "a new chat: 令 raises it; the first message makes the chat and the page becomes it" {
  both_pages(fn() raise {
    let t = tester("home")
    let (_, y) = bar_places_at()
    // 令 stands over the bar's middle
    t.tap(bar_action_x, y)
    assert_eq(app.nav.depth(), 2)
    assert_true(app.nav.risen())
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("想让 agent 做什么？") is Some(_))
    assert_true(t.find("Opus 5.5") is Some(_))
    t.tap_text("做任何事")
    t.type_text("把发布说明写一下")
    tap_send(t)
    // the page is the chat now, in place: no new page pushed, sideways back from it
    assert_eq(app.nav.depth(), 2)
    assert_true(!app.nav.risen())
    match app.nav.top() {
      Chat(r) => assert_eq(r.session, "new:1")
      _ => fail("not the chat")
    }
    t.run_for(new_leave_ms)
    assert_true(t.find("想让 agent 做什么？") is None)
    assert_true(t.find("把发布说明写一下") is Some(_))
  })
}

///|
test "a new chat with the keyboard up: the scene scrolls in what is left, the choices and the composer over the keyboard" {
  both_pages(fn() raise {
    let t = tester("home")
    let (_, y) = bar_places_at()
    t.tap(bar_action_x, y)
    t.run_for(@ui.move_most_ms)
    t.tap_text("做任何事")
    // the window laid out over the keyboard, as Android's host has it (adjustResize)
    let over = 844.0 - kbd_h
    t.resize(390.0, over)
    t.frame()
    let (_, fy, _, fh) = t.rect_of("做任何事").unwrap()
    assert_true(fy + fh <= over)
    assert_true(t.find("Opus 5.5") is Some(_))
  })
}

///|
/// A phone's keyboard, as tall as most are.
let kbd_h : Double = 336.0

///|
/// On the frames' clock to where the sheet rests, as it says (@kit.sheet_rest: its springs and its scrim's fade):
/// risen from below, a row is tapped where it is.
fn run_to_sheet_rest(t : @ui.Tester) -> Unit raise {
  let end = @sf.presented_rest()
  if end < 0.0 || end > 1.0e300 {
    fail("the sheet does not move (its rest: \{end})")
  }
  t.run_for(end - t.time())
}

///|
test "a new chat: its station picked in the sheet, its model in the model's panel" {
  both_pages(fn() raise {
    let t = tester("newchat")
    open_mode("newchat")
    // (the page opened drawn at its moment, its rise from there)
    t.draw()
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("它会在 Willow 上") is Some(_))
    // the station's control, after the preset's, beside the model's
    let (sx, sy) = t.find_last("Willow").unwrap()
    t.tap(sx, sy)
    assert_true(t.find("选择运行的 station") is Some(_))
    presented_rested(t)
    let (mx, my) = t.find_last("Maple").unwrap()
    t.tap(mx, my)
    assert_true(!@sf.presented_open_of(@sf.last_presented()))
    assert_eq(new_fix.station, "st2")
    assert_true(t.find("它会在 Maple 上") is Some(_))
    t.tap_text("Opus 5.5")
    assert_true(t.find("思考深度") is Some(_))
    run_to_sheet_rest(t)
    // (picked, made what it runs on: the panel closed, nothing to confirm)
    let (gx, gy) = t.find_last("GPT-6").unwrap()
    t.tap(gx, gy)
    assert_true(!@sf.presented_open_of(@sf.last_presented()))
    assert_true(t.find("GPT-6") is Some(_))
    // cancelled, it sinks back down
    t.tap_text("取消")
    assert_eq(app.nav.depth(), 1)
  })
}

///|
test "a new chat with disabled profiles leads back to enable them" {
  both_pages(fn() raise {
    let t = tester("newchat-disabled")
    open_mode("newchat-disabled")
    t.draw()
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("Profile 已停用") is Some(_))
    assert_true(t.find("Willow 的可用 Profile 均已停用，请在 Profile 页面重新启用。") is Some(_))
    t.tap_text("查看 Profile")
    assert_true(app.nav.top() is Setting(@settings.Route::Profiles("ws1/st1")))
  })
}

///|
test "the bar is liquid glass: its capsule and 令's circle beside it, each a shape of its own, no notch cut" {
  let t = tester("home")
  let gs = t.drawn_glass().filter(fn(g) { g.1 > 844.0 - 22.0 - bar_track - 40.0 })
  let capsule = gs.filter(fn(g) { (g.0 - 22.0).abs() < 0.5 && (g.2 - bar_capsule_w(390.0 - 44.0, 1.0)).abs() < 0.5 })
  let circle = gs.filter(fn(g) { (g.0 - (22.0 + 390.0 - 44.0 - act_size)).abs() < 0.5 && (g.2 - act_size).abs() < 0.5 })
  assert_eq((capsule.length(), circle.length()), (1, 1), msg="\{Repr(gs)}")
  assert_true(capsule[0].4 == 6 && circle[0].4 == 6)
  assert_eq(t.drawn_notches().length(), 0)
}

///|
test "the notch's icon: 令 giving way to ＋ draws the same ＋ and stays still; closed, back at once" {
  let plus = bar_place_with("plus")
  let none = bar_place_with("")
  let (t, _) = bar_at_rest()
  assert_eq(m_face.val, "plus")
  // to a place whose action is ＋ from 令's, the notch open throughout: the one icon both draw, not swapped
  ignore(@sfbase.go_place(plus))
  t.frame()
  t.frame()
  t.frame()
  assert_eq(bar.told.unwrap().action, "plus")
  assert_eq((m_face.val, bar.icon_was, bar.icon_swap.at(t.time()).0), ("plus", "", 1.0))
  ignore(@sfbase.go_place("chats"))
  t.frame()
  assert_eq(bar.told.unwrap().action, "ling")
  assert_eq((m_face.val, bar.icon_was, bar.icon_swap.at(t.time()).0), ("plus", "", 1.0))
  // the notch closed (a place with no action), then an action again: at once
  ignore(@sfbase.go_place(none))
  t.run_for(bar_rest() - t.time())
  ignore(@sfbase.go_place(plus))
  t.frame()
  assert_eq((m_face.val, bar.icon_swap.at(t.time()).0), ("plus", 1.0))
  t.run_for(bar_rest() - t.time())
  t.assert_idle()
}

///|
test "the bar chosen in the panel slides down into the bar's place, its places laid out there from the first" {
  let t = tester("home")
  let (xs, y) = bar_places_at()
  t.drag(xs[0], y, xs[0], y - 64.0, steps=20)
  // let go over the rows before the panel was all the way open, it stays open: its row tapped
  if bar.swap_at(t.time()) is None {
    t.run_for(bar.o.end() - t.time())
    t.tap_once(xs[0], 844.0 - 22.0 - 132.0 + 20.0 + 28.0)
  }
  // chosen: the bar in view at once, the stack sliding down, a frame at a time to where it lands
  assert_true(app.nav.top() == Place("remote"))
  let mut seen = false
  let mut last = -1.0
  let lands = bar.o.end()
  while t.time() < lands {
    t.frame()
    match bar.swap_at(t.time()) {
      Some(s) => {
        let k = s.t(bar.o.at(t.time()).0)
        assert_true(k >= last)
        last = k
        if k > 0.05 && k < 0.95 {
          seen = true
        }
      }
      None => ()
    }
  }
  assert_true(seen)
  assert_true(bar.swap_at(t.time()) is None)
  match bars_picked.get() {
    Some((_, cur)) => assert_eq(cur, 1)
    None => fail("no bar picked")
  }
}

///|
/// The bar's panel drawn up and the other bar's row tapped (its first place), on to 50 ms after that bar has landed: a
/// frame drawn at the moment it lands (`at_landing`), or none between the tap's and that one.
fn bar_chosen_landed(t : @ui.Tester, at_landing : Bool) -> Unit {
  let (xs, y) = bar_places_at()
  t.drag(xs[0], y, xs[0], y - 64.0, steps=20)
  if bar.swap_at(t.time()) is None {
    t.run_for(bar.o.end() - t.time())
    t.tap_once(xs[0], 844.0 - 22.0 - 132.0 + 20.0 + 28.0)
  }
  // (each frame said: run_for would draw one at the landing by itself, its springs saying they rest then)
  let lands = bar.o.end()
  if at_landing {
    t.frame_at(lands)
  }
  t.frame_at(lands + 50.0)
}

///|
test "the bar chosen and landed, the panel drawn up again: no bar landing then; the other chosen lands as the first did, a frame at its landing or none" {
  let seen = fn(at_landing : Bool) {
    let t = tester("home")
    bar_chosen_landed(t, at_landing)
    let first = (app.nav.top() == Place("remote"), bar.swap_at(t.time()) is None)
    // drawn up again: the panel the finger's, nothing landing, the ball riding nothing
    let (xs, y) = bar_places_at()
    t.drag(xs[0], y, xs[0], y - 64.0, steps=20)
    let again = (bar.swap_at(t.time()) is None, bar.ball_x.ride is None, bar.mode.get())
    // the other bar's row tapped on its first place (four of them across, no notch in a row): it lands
    t.run_for(bar.o.end() - t.time())
    t.tap_once(bar_centres(390.0 - 44.0, 0.0, 4)[0] + 22.0, 844.0 - 22.0 - 132.0 + 20.0 + 28.0)
    t.run_for(bar.o.end() + 50.0 - t.time())
    let second = (place_of(app.nav.top()) == Some("chats"), bar.swap_at(t.time()) is None, bars_picked.get().map(fn(b) { b.1 }))
    (first, again, second)
  }
  let want = ((true, true), (true, true, true), (true, true, Some(0)))
  assert_eq((seen(true), seen(false)), (want, want))
}

///|
test "the bar drawn up clear of a finger as long as it has it: drawn up, further up and back down onto the bar; sliding along the bar; let go, back down" {
  let t = tester("home")
  let (xs, y) = bar_places_at()
  let foot = fn() {
    t.drawn_glass_corners().fold(init=0.0, fn(a, g) { if (g.0 - 22.0).abs() < 1.0 && g.2 > 250.0 { dmax(a, g.1 + g.3) } else { a } })
  }
  let rest = foot()
  let raised = fn() {
    t.run_for(@ui.move_most_ms)
    (rest - foot()).round()
  }
  t.press_at(xs[0], y)
  for i in 1..=20 {
    t.move_to(xs[0], y - 64.0 * i.to_double() / 20.0)
  }
  let up = raised()
  for i in 1..=30 {
    t.move_to(xs[0], y - 64.0 - 400.0 * i.to_double() / 30.0)
  }
  let further = raised()
  for i in 1..=30 {
    t.move_to(xs[0], y - 464.0 + 464.0 * i.to_double() / 30.0)
  }
  let back = raised()
  for i in 1..=20 {
    t.move_to(xs[0] + (xs[2] - xs[0]) * i.to_double() / 20.0, y)
  }
  let along = raised()
  t.release(xs[2], y)
  t.run_for(bar.rest() - t.time())
  // a finger sliding along the bar alone, never drawing the panel up
  t.press_at(xs[0], y)
  for i in 1..=20 {
    t.move_to(xs[0] + (xs[1] - xs[0]) * i.to_double() / 20.0, y)
  }
  let sliding = raised()
  t.release(xs[1], y)
  t.run_for(bar.rest() - t.time())
  assert_eq((up, further, back, along, sliding, (rest - foot()).round()), (59.0, 59.0, 59.0, 59.0, 59.0, 0.0))
}

///|
test "the bar held: more room above the finger in a taller window, bounded by the top of a short window" {
  let measure = fn(h : Double, open : Bool) {
    new_run()
    let src = fixture("home")
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h~, platform=2)
    // The bar is 346 wide here (its capsule 280 beside 令, 346 with the panel open); the page's full-width top bar is not
    // the panel.
    let glass = fn() { t.drawn_glass_corners().filter(fn(g) { (g.0 - 22.0).abs() < 1.0 && g.2 > 250.0 && g.2 < 360.0 }) }
    let foot = fn() { glass().fold(init=0.0, fn(a, g) { dmax(a, g.1 + g.3) }) }
    let rest = foot()
    let (xs, _) = bar_places_at()
    let y = h - 22.0 - 28.0
    t.press_at(xs[0], y)
    if open {
      for i in 1..=20 {
        t.move_to(xs[0], y - 64.0 * i.to_double() / 20.0)
      }
    } else {
      t.run_for(bar_hold_ms)
      t.frame()
    }
    t.run_for(@ui.move_most_ms)
    let raised = rest - foot()
    let top = glass().fold(init=h, fn(a, g) { dmin(a, g.1) })
    t.release(xs[0], y)
    (raised, top)
  }
  let short = measure(550.0, false).0
  let regular = measure(844.0, false).0
  let tall = measure(1200.0, false).0
  // More than the former 44 points, increasing with available height but never an excessive displacement.
  assert_true(short > 44.0 && short < regular && regular < tall && tall <= 64.1)
  // The panel can still open in a very short window without its glass crossing the top margin.
  let (limited, top) = measure(180.0, true)
  assert_true(limited > 0.0 && limited < short)
  assert_true(top >= 7.5, msg="panel top: \{top}")
}

///|
/// The three screens a new chat's stations open on: a phone's window with touch (a sheet from its foot), with keyboard
/// and mouse, and a wide window with keyboard and mouse (a panel beside its station's control).
// kept across runs: a value (no field of it changes)
let ns_screens : Array[(Int, Bool)] = [(2, false), (0, false), (0, true)]

///|
/// A new chat over the fixture's workspace on a phone's window (390 by 844) started as `platform`, `wide` 1200 by 800;
/// its station's control (Willow) pressed, its stations open and at rest. The calls made go in
/// `calls`.
fn ns_open(calls : Array[String], platform~ : Int, wide~ : Bool) -> @ui.Tester {
  new_run()
  // (the chat's page made as both_pages runs it now, its new chat too: none outside one)
  @sf.presenters_reset()
  let base = fixture("newchat")
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      calls.push(name + " " + params.stringify())
      (base.call)(name, params, done)
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform~)
  if wide {
    t.resize(1200.0, 800.0)
  }
  open_mode("newchat")
  t.draw()
  t.run_for(@ui.move_most_ms)
  guard t.semantics().filter(fn(s) { s.role == @ui.Role::Button && s.label == "Willow" && !s.hidden }).last() is Some(b) else {
    @halt.saying("no Willow to press")
  }
  t.tap(b.rect.0 + b.rect.2 / 2.0, b.rect.1 + b.rect.3 / 2.0)
  presented_rested(t)
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// Whether `words` are drawn (seen at all), the last of them where they are.
fn ns_seen(t : @ui.Tester, words : String) -> (Double, Double, Double, Double)? {
  t.words().filter(fn(w) { w.0 == words && w.5 > 0.0 }).last().map(fn(w) { (w.1, w.2, w.3, w.4) })
}

///|
/// Where what is read out as `label` is in `t` (an icon's words, a count beside its icon), as ns_seen says words.
fn ns_said(t : @ui.Tester, label : String) -> (Double, Double, Double, Double)? {
  t.semantics().filter(fn(n) { n.label == label && !n.hidden }).last().map(fn(n) { n.rect })
}

///|
test "a new chat's stations on every screen: a row each under its title, Willow checked, each's state on its name's line and what is left of it and how it is reached under it; nothing of it has the focus as it opens, no input method" {
  both_pages(fn() raise {
    for s in ns_screens {
      let (platform, wide) = s
      let at = "platform \{platform} wide \{wide}"
      let t = ns_open([], platform~, wide~)
      let rows = t.semantics().filter(fn(n) { n.role == @ui.Role::Button && (n.label == "Willow" || n.label == "Maple") && !n.hidden }).filter(fn(n) { n.check is Some(_) })
      assert_eq(rows.map(fn(n) { (n.label, n.check) }), [("Willow", Some(@ui.Check::On)), ("Maple", Some(@ui.Check::Off))], msg=at)
      assert_false(t.focused() is Some(f) && rows.iter().any(fn(r) { r.label == f.label && r.rect == f.rect }), msg="\{at}: \{Repr(t.focused())}")
      assert_false(t.ime().0, msg="\{at}: the input method up")
      guard ns_seen(t, "选择运行的 station") is Some(title) else { fail("\{at}: no title") }
      assert_true(rows[0].rect.1 > title.1 && rows[1].rect.1 > rows[0].rect.1 + rows[0].rect.3 - 0.5, msg="\{at}: \{Repr(rows.map(fn(r) { r.rect }))}")
      // (Willow: 2 at work on its name's line, a chat's icon and 2, read out whole; its figures and 直连 38ms under it;
      // Maple: 未连接)
      for w in ["直连 38ms", "未连接", "CPU 72%", "内存 5.8G", "磁盘 380G"] {
        assert_true(ns_seen(t, w) is Some(_), msg="\{at}: \{w}")
      }
      guard (ns_said(t, "2 个运行中"), ns_seen(t, "直连 38ms")) is (Some(busy), Some(net)) else { fail(at) }
      assert_true(busy.1 < rows[0].rect.1 + 30.0 && net.1 > busy.1 && net.1 < rows[1].rect.1, msg="\{at}: \{Repr(busy)} \{Repr(net)}")
    }
  })
}

///|
test "a new chat's stations on every screen, Maple pressed: picked (newChat.pick, once), closed, on its way out as high as it was, its rows and Willow's check shown all the way" {
  both_pages(fn() raise {
    for s in ns_screens {
      let (platform, wide) = s
      let at = "platform \{platform} wide \{wide}"
      let calls : Array[String] = []
      let t = ns_open(calls, platform~, wide~)
      let size = fn() {
        t.semantics().iter().find_first(fn(s) { s.role == @ui.Role::Dialog }).map(fn(s) { (s.rect.2, s.rect.3) })
      }
      guard size() is Some((was_w, was)) else { fail("\{at}: no panel") }
      let drawn = fn(w : String) { t.words().iter().any(fn(x) { x.0 == w && x.5 > 0.0 }) }
      guard t.semantics().filter(fn(n) { n.role == @ui.Role::Button && n.label == "Maple" && n.check is Some(_) && !n.hidden }).last() is Some(m) else {
        fail("\{at}: no Maple")
      }
      let before = calls.length()
      t.tap(m.rect.0 + m.rect.2 / 2.0, m.rect.1 + m.rect.3 / 2.0)
      let mut n = 0
      while @sf.presenter_visible() && n < 120 {
        match size() {
          Some(s) => {
            let h = s.1 * was_w / s.0
            assert_true((h - was).abs() <= 0.01, msg="\{at}: frame \{n} on its way out: \{h} high, \{was} before")
          }
          None => ()
        }
        for w in ["2", "未连接", "直连 38ms"] {
          assert_true(drawn(w) || !drawn("选择运行的 station"), msg="\{at}: frame \{n} on its way out: \{w} not drawn")
        }
        t.frame()
        n += 1
      }
      assert_false(@sf.presenter_visible(), msg="\{at}: gone")
      assert_eq(calls[before:].to_owned().filter(fn(c) { c.has_prefix("newChat.pick") }), ["newChat.pick {\"station\":\"st2\",\"scope\":\"ws1\"}"], msg=at)
    }
  })
}

///|
/// What is wrong with each station's compact two-line row as `t` shows it (`at` says where): audit is clean, the
/// second line sits below the station name and aligns with its left edge, and no metric figure is truncated.
fn ns_rows_wrong(t : @ui.Tester, at : String) -> String {
  let wrong : Array[String] = []
  let audit = t.audit()
  if audit.length() > 0 {
    wrong.push("\{at}: audit: \{audit.join("; ")}")
  }
  let all = t.words().filter(fn(w) { w.5 > 0.0 })
  let title = @sf.t("android-chat.new.station.pick")
  let words = match all.search_by(fn(w) { w.0 == title }) {
    Some(i) => all[i + 1:].to_owned()
    None => all
  }
  for name in ["Willow", "Maple"] {
    guard t.semantics().filter(fn(n) { n.role == @ui.Role::Button && n.label == name && n.check is Some(_) && !n.hidden }).last() is Some(r) else {
      wrong.push("\{at}: no row of \{name}")
      continue
    }
    let (_, ry, _, rh) = r.rect
    let inside = words.filter(fn(w) { w.2 >= ry - 0.01 && w.2 + w.4 <= ry + rh + 0.01 })
    guard inside.iter().find_first(fn(w) { w.0 == name }) is Some(n) else {
      wrong.push("\{at}: no \{name} in its row")
      continue
    }
    let under = inside.filter(fn(w) { w.2 > n.2 + 0.5 })
    if under.is_empty() {
      wrong.push("\{at}: no second line under \{name}")
      continue
    }
    let left_most = under.fold(init=under[0], fn(a, w) { if w.1 < a.1 { w } else { a } })
    if (left_most.1 - n.1).abs() > 0.5 {
      wrong.push("\{at}: \{name} second line x=\{left_most.1} != name x=\{n.1}")
    }
    for w in under {
      if w.0.has_suffix("…") {
        wrong.push("\{at}: \{name} truncated metric/net: \{w.0}")
      }
    }
  }
  wrong.join("\n")
}

///|
test "where a new chat runs, on every screen at the default size of words and on a phone at 1.3: compact two-line rows align cleanly with zero audit faults" {
  both_pages(fn() raise {
    for s in ns_screens {
      let (platform, wide) = s
      let calls : Array[String] = []
      let t = ns_open(calls, platform~, wide~)
      assert_eq(ns_rows_wrong(t, "platform \{platform} wide \{wide}"), "")
    }
    guard corner_windows.search_by(w => w.0 == "phone") is Some(i) else { fail("no phone window in corner_windows") }
    for lang in ["zh", "en"] {
      let t = screen_in("newchat-station", corner_windows[i], lang, font_scale=1.3)
      assert_eq(ns_rows_wrong(t, "phone \{lang} at 1.3"), "")
    }
  })
}

///|
test "wide: a new chat's stations under a mouse have concentric corners in the panel and stay lit over a row's meter text" {
  both_pages(fn() raise {
    let t = ns_open([], platform=0, wide=true)
    t.host_says_finger(Some(false))
    let rows = t.semantics().filter(fn(n) { n.role == @ui.Role::Button && (n.label == "Willow" || n.label == "Maple") && n.check is Some(_) && !n.hidden })
    guard rows.length() == 2 else { fail("expected Willow and Maple rows") }
    let same_box = fn(b : @ui.Laid, r : (Double, Double, Double, Double)) {
      (b.x - r.0).abs() < 0.5 && (b.y - r.1).abs() < 0.5 && (b.w - r.2).abs() < 0.5 && (b.h - r.3).abs() < 0.5 && b.bg != 0L
    }
    let (wx, wy, ww, wh) = rows[0].rect
    let (mx, my, mw, mh) = rows[1].rect
    // Pointer on the bottom row (Maple): its hover ground is concentric with the small panel's corners.
    t.move_to(mx + mw / 2.0, my + mh / 2.0)
    t.run_for(@sf.dur_ms)
    assert_eq(t.corner_faults(), [])
    let lit_maple = t.boxes_held().filter(fn(b) { same_box(b, (mx, my, mw, mh)) })
    assert_true(lit_maple.length() == 1 && (lit_maple[0].radius - @sf.row_corner).abs() < 0.5, msg="\{lit_maple.length()} maple lit")
    // Pointer moved onto the CPU meter inside Willow: Willow's own hover ground stays lit across the whole row.
    guard t.words().iter().find_first(fn(w) { w.0 == "CPU 72%" && w.5 > 0.0 && w.2 >= wy && w.2 + w.4 <= wy + wh }) is Some((_, cx, cy, cw, ch, _)) else {
      fail("no CPU 72% in Willow")
    }
    t.move_to(cx + cw / 2.0, cy + ch / 2.0)
    t.run_for(@sf.dur_ms)
    assert_eq(t.corner_faults(), [])
    let lit_willow = t.boxes_held().filter(fn(b) { same_box(b, (wx, wy, ww, wh)) })
    assert_true(lit_willow.length() == 1 && (lit_willow[0].radius - @sf.row_corner).abs() < 0.5, msg="\{lit_willow.length()} willow lit")
  })
}

///|
/// Open `newchat-station-many` at `w` × `h` with `platform`, capturing core calls in `calls`.
fn ns_many_open(calls : Array[String], platform~ : Int, w~ : Double, h~ : Double) -> @ui.Tester {
  new_run()
  @sf.presenters_reset()
  let base = fixture("newchat-station-many")
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      calls.push(name + " " + params.stringify())
      (base.call)(name, params, done)
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
  open_mode("newchat-station-many")
  t.draw()
  presented_rested(t)
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "many stations on wide screen: centered table auto-focuses search, filters by name and network, supports arrow+Enter, Esc, column sorting, and auto-assign" {
  both_pages(fn() raise {
    // 1. Search by name + ↓ + Enter picks second match and closes.
    let calls : Array[String] = []
    let t = ns_many_open(calls, platform=0, w=1280.0, h=800.0)
    assert_eq(t.audit(), [])
    let dlg = t.get(@ui.Role::Dialog)
    assert_true(dlg.rect.2 >= 720.0, msg="expected wide modal, got w=\{dlg.rect.2}")
    assert_true(t.focused() is Some(f) && f.role == @ui.Role::TextField, msg="search should auto-focus on wide modal")
    let before = calls.length()
    t.type_text("hyper")
    t.frame()
    let matched = t.semantics().filter(fn(n) { n.role == @ui.Role::Button && n.check is Some(_) && !n.hidden && n.label != "自动分配 (11)" })
    assert_eq(matched.map(fn(n) { n.label }), ["pvg-office-hyper-build-node-01", "sgp-edge-hyper-worker-04"])
    t.key(@ui.key_code_down)
    t.frame()
    t.key(@ui.key_code_enter)
    presented_rested(t)
    t.run_for(@ui.move_most_ms)
    assert_false(@sf.presenter_visible())
    assert_eq(calls[before:].to_owned().filter(fn(c) { c.has_prefix("newChat.pick") }), ["newChat.pick {\"station\":\"st8\",\"scope\":\"ws1\"}"])

    // 2. Search by network path ("香港"), Esc clears search first, second Esc closes.
    let t2 = ns_many_open([], platform=0, w=1280.0, h=800.0)
    t2.type_text("香港")
    t2.frame()
    let hk = t2.semantics().filter(fn(n) { n.role == @ui.Role::Button && n.check is Some(_) && !n.hidden && n.label != "自动分配 (11)" })
    assert_eq(hk.map(fn(n) { n.label }), ["pvg-office-hyper-build-node-01", "hkg-relay-build-station-prod"])
    t2.key(@ui.key_escape)
    t2.frame()
    assert_true(@sf.presenter_visible(), msg="first Esc clears search without closing")
    let all_back = t2.semantics().filter(fn(n) { n.role == @ui.Role::Button && n.check is Some(_) && !n.hidden && n.label != "自动分配 (11)" })
    assert_eq(all_back.length(), 12)
    t2.key(@ui.key_escape)
    presented_rested(t2)
    t2.run_for(@ui.move_most_ms)
    assert_false(@sf.presenter_visible(), msg="second Esc closes modal")

    // 3. Column sorting (CPU, Memory, Running, Network) + reverse toggle + Auto-assign button.
    let calls3 : Array[String] = []
    let t3 = ns_many_open(calls3, platform=0, w=1280.0, h=800.0)
    let row_names = fn() {
      t3.semantics()
      .filter(fn(n) { n.role == @ui.Role::Button && n.check is Some(_) && !n.hidden && n.label != "自动分配 (11)" })
      .map(fn(n) { n.label })
    }
    let tap_col = fn(col : String) {
      let want = @sf.t("web-main.resources.by", args=[("column", col)])
      guard t3.semantics().iter().find_first(fn(n) { n.role == @ui.Role::Button && n.label == want && !n.hidden }) is Some(b) else {
        @halt.saying("missing column header " + col)
      }
      t3.tap(b.rect.0 + b.rect.2 / 2.0, b.rect.1 + b.rect.3 / 2.0)
      t3.frame()
    }
    // CPU ascending (lowest load / highest idle first), offline last
    tap_col("CPU")
    let cpu_asc = row_names()
    assert_eq(cpu_asc[0], "pvg-office-2")
    assert_eq(cpu_asc[cpu_asc.length() - 1], "lab-mac-mini-offline")
    // CPU descending (highest load first), offline still last
    tap_col("CPU")
    let cpu_desc = row_names()
    assert_eq(cpu_desc[0], "afk-ap-pool-gpu-render-cluster-alpha-tokyo-01")
    assert_eq(cpu_desc[cpu_desc.length() - 1], "lab-mac-mini-offline")
    // Memory descending (most GB free first)
    tap_col("内存")
    let mem_desc = row_names()
    assert_eq(mem_desc[0], "studio-m4-max-ultrawide-devbox")
    // Running ascending (idle 0 first)
    tap_col("运行中")
    let run_asc = row_names()
    assert_eq(run_asc[0], "Maple")
    // Network ascending (lowest RTT first, disconnected/offline at bottom)
    tap_col("连接")
    let net_asc = row_names()
    assert_eq(net_asc[0], "Office-Host-2")
    // Auto-assign pill button
    let before3 = calls3.length()
    guard t3.semantics().iter().find_first(fn(n) { n.role == @ui.Role::Button && n.label == "自动分配 (11)" && !n.hidden }) is Some(ab) else {
      fail("no auto-assign pill")
    }
    t3.tap(ab.rect.0 + ab.rect.2 / 2.0, ab.rect.1 + ab.rect.3 / 2.0)
    presented_rested(t3)
    t3.run_for(@ui.move_most_ms)
    assert_false(@sf.presenter_visible())
    assert_eq(calls3[before3:].to_owned().filter(fn(c) { c.has_prefix("newChat.pick") }), ["newChat.pick {\"autoStation\":true,\"scope\":\"ws1\"}"])
  })
}

///|
test "many stations on small screen: drawer has search without auto-focus or IME, passes audit at 1.0x and 1.3x zh/en" {
  both_pages(fn() raise {
    let t = ns_many_open([], platform=2, w=390.0, h=844.0)
    assert_false(t.ime().0, msg="small drawer must not raise IME on open")
    assert_eq(t.audit(), [])
    guard corner_windows.search_by(w => w.0 == "phone") is Some(i) else { fail("no phone window in corner_windows") }
    for lang in ["zh", "en"] {
      for scale in [1.0, 1.3] {
        let tw = screen_in("newchat-station-many", corner_windows[i], lang, font_scale=scale)
        assert_eq(tw.audit(), [], msg="newchat-station-many phone \{lang} \{scale}")
      }
    }
  })
}

///|
test "long station name shows full-name tooltip on hover in picker and on closed composer capsule; short name does not" {
  both_pages(fn() raise {
    let long_name = "afk-ap-pool-gpu-render-cluster-alpha-tokyo-01"
    let t = ns_many_open([], platform=0, w=1280.0, h=800.0)
    t.host_says_finger(Some(false))
    // Hover truncated long name row -> tooltip displays full untruncated name.
    guard t.semantics().iter().find_first(fn(n) { n.role == @ui.Role::Button && n.label == long_name && n.check is Some(_) && !n.hidden }) is Some(lr) else {
      fail("missing long station row")
    }
    // Name sits on the left side of the row (after 18pt mark + gaps).
    t.move_to(lr.rect.0 + 80.0, lr.rect.1 + lr.rect.3 / 2.0)
    t.run_for(@sf.tip_delay_ms + @sf.dur_ms)
    assert_true(t.words().iter().any(fn(w) { w.0 == long_name && w.5 > 0.0 }), msg="expected full-name tooltip for truncated long name")
    // Hover short name ("Willow") -> no tooltip appears (only 1 copy of "Willow" in the row itself, plus capsule/sub).
    let before_willow = t.words().filter(fn(w) { w.0 == "Willow" && w.5 > 0.0 }).length()
    guard t.semantics().iter().find_first(fn(n) { n.role == @ui.Role::Button && n.label == "Willow" && n.check is Some(_) && !n.hidden }) is Some(wr) else {
      fail("missing Willow row")
    }
    t.move_to(wr.rect.0 + 48.0, wr.rect.1 + wr.rect.3 / 2.0)
    t.run_for(@sf.tip_delay_ms + @sf.dur_ms)
    let after_willow = t.words().filter(fn(w) { w.0 == "Willow" && w.5 > 0.0 }).length()
    assert_eq(after_willow, before_willow, msg="short untruncated name should not show tooltip")
    // Pick the long-name station, close panel, then hover closed composer capsule -> full-name tooltip appears.
    t.tap(lr.rect.0 + 80.0, lr.rect.1 + lr.rect.3 / 2.0)
    presented_rested(t)
    t.run_for(@ui.move_most_ms)
    assert_false(@sf.presenter_visible())
    guard t.semantics().iter().find_first(fn(n) { n.role == @ui.Role::Button && n.label == long_name && !n.hidden }) is Some(cap) else {
      fail("missing closed station capsule for long name")
    }
    t.move_to(cap.rect.0 + cap.rect.2 / 2.0, cap.rect.1 + cap.rect.3 / 2.0)
    t.run_for(@sf.tip_delay_ms + @sf.dur_ms)
    assert_true(t.words().iter().any(fn(w) { w.0 == long_name && w.5 > 0.0 }), msg="expected full-name tooltip on closed station capsule")
  })
}

///|
test "new chat in Solid material draws uniform hairline borders on model capsule, sibling capsules, and composer" {
  both_pages(fn() raise {
    new_run()
    let src = fixture("home")
    (src.call)("prefs.set", Json::object({ "glass": Json::string("solid") }), @sfbase.answer_unread)
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
    let (_, y) = bar_places_at()
    t.tap(bar_action_x, y)
    t.run_for(@ui.move_most_ms)
    t.draw()
    assert_eq(t.drawn_glass().length(), 0, msg="Solid new chat must draw 0 glass")
    let has_border_around = fn(rx : Double, ry : Double, rw : Double, rh : Double) -> Bool {
      let cx = rx + rw / 2.0
      let cy = ry + rh / 2.0
      t.drawn_instances().iter().any(fn(inst) {
        inst.length() > 15 &&
        inst[5] == 0.0 &&
        (inst[6] - @sf.control_edge_w).abs() < 0.01 &&
        inst[15] > 0.05 &&
        inst[0] <= cx && cx <= inst[0] + inst[2] &&
        inst[1] <= cy && cy <= inst[1] + inst[3] &&
        inst[2] >= rw && inst[3] >= rh &&
        inst[2] <= 380.0
      })
    }
    guard t.rect_of("Opus 5.5") is Some((mx, my, mw, mh)) else { fail("missing model capsule text") }
    assert_true(has_border_around(mx, my, mw, mh), msg="Solid model capsule must draw a 0.5pt hairline border")
    guard t.rect_of("做任何事") is Some((fx, fy, fw, fh)) else { fail("missing composer field") }
    assert_true(has_border_around(fx, fy, fw, fh), msg="Solid composer box must draw a 0.5pt hairline border")
  })
}
