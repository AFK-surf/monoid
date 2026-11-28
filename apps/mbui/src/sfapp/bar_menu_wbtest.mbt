// The bottom bar's last slot and the menu its glass grows into, as a finger, a key and a screen reader have them, held
// by what is drawn and read out alone (the window 390 by 844, the bar's places as the fixture keeps them: the first
// three a slot each, the fourth slot the menu's five). What is felt is counted gesture by gesture.

///|
/// The middle across of the menu's rows and each row's middle down in that window, the menu of `rows` rows (48 each, 8
/// in from the glass's edge, the glass's foot the bar's, 22 over the window's).
fn menu_rows_at(rows : Int) -> (Double, Array[Double]) {
  let top = 844.0 - 22.0 - (rows.to_double() * 48.0 + 16.0)
  (22.0 + 120.0, Array::makei(rows, fn(i) { top + 8.0 + 48.0 * i.to_double() + 24.0 }))
}

///|
/// The menu's places as the fixture keeps them (the bars' places past the first three).
fn menu_places() -> Array[String] {
  let src = fixture("home")
  let ws = workspace_in_view(src).0.unwrap()
  let flat : Array[String] = []
  for set in bars_in(src, ws.id).0 {
    for p in set {
      if !flat.contains(p) {
        flat.push(p)
      }
    }
  }
  flat[3:].to_owned()
}

///|
/// Whether the menu's rows are read out now (each a menu's item called by its place's name).
fn menu_read(t : @ui.Tester, places : Array[String]) -> Bool {
  places.iter().all(fn(p) { t.query(MenuItem, label=place_label(p)) is Some(_) })
}

///|
/// The bar's glass as drawn in the last frame: the liquid glass at the window's foot that is as long as the capsule
/// (its top and how high).
fn menu_glass(t : @ui.Tester) -> (Double, Double) {
  let mut best = (0.0, 0.0)
  for g in t.drawn_glass() {
    if g.4 == 6 && g.2 > 150.0 && g.1 + g.3 > 800.0 {
      best = (g.1, g.3)
    }
  }
  best
}

///|
/// The grey of a selection drawn in the last frame inside the bar's room (the bar's own or its menu's indicator): each
/// (x, y, w, h, how much of it shows of 255).
fn menu_selections(t : @ui.Tester) -> Array[(Double, Double, Double, Double, Int)] {
  let out = []
  for r in t.drawn_rects() {
    let (x, y, w, h, color) = r
    let a = (color & 0xFFL).to_int()
    if (color >> 8) == 0L && a > 0 && y > 500.0 && w > 40.0 && w < 340.0 && h > 30.0 && h < 80.0 && x > 20.0 {
      out.push((x, y, w, h, a))
    }
  }
  out
}

///|
/// The lens drawn in the last frame, if one is: the clear liquid glass of the bar's selection lifted (its rect, and
/// what it says of magnifying: -64 none).
fn menu_lens(t : @ui.Tester) -> (Double, Double, Double, Double, Double)? {
  for inst in t.drawn_instances() {
    if inst[5] == 6.0 && inst[7] <= -63.9 && inst[7] >= -64.9 {
      return Some((inst[0], inst[1], inst[2], inst[3], inst[7]))
    }
  }
  None
}

///|
test "bar menu: a press on the last slot opens the menu at once and lifting there leaves it open; a row tapped is its page, the last slot standing for it" {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  let places = menu_places()
  assert_eq(places.length(), 5)
  let start = app.nav.top()
  assert_false(menu_read(t, places))
  t.press_at(xs[3], y)
  assert_true(menu_read(t, places), msg="the menu's rows are read out as the finger lands on the last slot")
  t.release(xs[3], y)
  t.run_shown(@ui.move_most_ms)
  assert_true(menu_read(t, places), msg="lifted where it opened the menu, the menu stays open")
  assert_true(app.nav.top() == start, msg="opening the menu shows no other page")
  let (top, high) = menu_glass(t)
  assert_true((high - 256.0).abs() < 0.5 && (top - (822.0 - 256.0)).abs() < 0.5, msg="the bar's own glass is the menu: \{top} \{high}")
  // (a row tapped: its page, the menu folded back, the last slot that page's)
  let (rx, rys) = menu_rows_at(5)
  t.tap(rx, rys[2])
  t.run_shown(@ui.move_most_ms * 2.0)
  assert_eq(place_of(app.nav.top()), Some(places[2]))
  assert_false(menu_read(t, places))
  assert_true(
    t.query(Button, label=tr("android-misc.bar.more", args=[("name", bar_said_of(places[2]))]), expanded=false) is Some(_),
    msg="the last slot stands for the page picked",
  )
  let (_, low) = menu_glass(t)
  assert_true((low - 50.0).abs() < 0.01, msg="the glass is the bar's again: \{low}")
}

///|
test "bar menu: what a scripted run finds on the bar it reaches with its tap: a place's icon, and, the menu open, each row's name; a row tapped so is its page" {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  let places = menu_places()
  // (a slot's icon: found, and where a press there goes holds it, the bar's own node)
  let folder = t.reachable("icon:folder")
  // (its dim face and its lit one, drawn over one another: either found, both where the tap goes)
  assert_true(folder.length() >= 1, msg="a place's icon on the bar is reached by a tap: \{Repr(folder)}")
  assert_true((folder[0].0 - xs[1]).abs() < 1.0 && (folder[0].1 - y).abs() < 14.0, msg="\{Repr(folder)}")
  t.tap(folder[0].0, folder[0].1)
  t.run_shown(@ui.move_most_ms)
  assert_eq(place_of(app.nav.top()), Some("files"))
  // (the menu open: each row's name)
  t.tap(xs[3], y)
  t.run_shown(@ui.move_most_ms)
  assert_true(menu_read(t, places))
  for p in places {
    let at = t.reachable("=" + place_label(p))
    assert_true(at.length() >= 1, msg="the menu's row \{place_label(p)} is reached by a tap")
  }
  let row = t.reachable("=" + place_label(places[1]))
  t.tap(row[0].0, row[0].1)
  t.run_shown(@ui.move_most_ms * 2.0)
  assert_eq(place_of(app.nav.top()), Some(places[1]))
}

///|
test "bar menu: a row picked, a tab tapped half a second later is that tab's place, whichever row it was: the bar is the bar again" {
  let places = menu_places()
  let menu_pause_ms : Double = 500.0
  let tab_tap_settle_ms : Double = 180.0
  for i, p in places {
    let (t, _) = bar_at_rest()
    let (xs, y) = bar_places_at()
    // (as a scripted run goes: the last slot tapped, half a second, the row tapped, half a second, a tab tapped)
    t.tap(xs[3], y)
    t.run_for(menu_pause_ms)
    let row = t.reachable("=" + place_label(p))
    assert_true(row.length() >= 1, msg="the menu's row \{place_label(p)} is reached by a tap")
    t.tap(row[0].0, row[0].1)
    t.run_for(menu_pause_ms)
    assert_eq(place_of(app.nav.top()), Some(p))
    let tab = if i % 2 == 0 { 0 } else { 1 }
    t.tap(xs[tab], y)
    t.run_for(tab_tap_settle_ms)
    assert_eq(place_of(app.nav.top()), Some(if tab == 0 { "chats" } else { "files" }), msg="after \{p}")
    // (and the menu's slot again after that: its menu, the page picked still what it stands for)
    t.tap(xs[3], y)
    t.run_for(menu_pause_ms)
    assert_true(menu_read(t, places), msg="the menu opens again after \{p}")
  }
}

///|
test "bar menu: a tap off the open menu folds it back and chooses nothing; above the shut bar a tap is the page's" {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  let places = menu_places()
  // (the bar shut: its menu's room above it takes nothing)
  let (rx, rys) = menu_rows_at(5)
  t.tap(rx, rys[1])
  t.run_shown(@ui.move_most_ms)
  assert_eq(app.nav.depth(), 2)
  @ui.view_tree().unwrap().event(t.time(), fn() { app.nav.pop() |> ignore })
  t.run_shown(@ui.move_most_ms * 2.0)
  assert_eq(app.nav.depth(), 1)
  t.tap(xs[3], y)
  t.run_shown(@ui.move_most_ms)
  assert_true(menu_read(t, places))
  let start = app.nav.top()
  t.tap(100.0, 200.0)
  t.run_shown(@ui.move_most_ms * 2.0)
  assert_false(menu_read(t, places))
  assert_true(app.nav.top() == start && app.nav.depth() == 1, msg="a tap off the menu chooses nothing")
}

///|
/// What is felt from the bar at rest on the chats through `act` (given the tester, the slots' middles and the bar's
/// middle down), and the place shown after.
fn menu_felt(act : (@ui.Tester, Array[Double], Double) -> Unit) -> (Array[@ui.Haptic], String?) {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  let before = t.haptics().length()
  act(t, xs, y)
  t.run_shown(@ui.move_most_ms * 2.0)
  (t.haptics()[before:].to_owned(), place_of(app.nav.top()))
}

///|
test "bar menu: what is felt: a tab tapped ticks once as the finger lets go; a lens ticks at each slot it moves on to and not again let go there; the menu ticks as it opens and at each row a finger moves on to, never as a row is picked" {
  let tick : @ui.Haptic = TextHandleMove
  let places = menu_places()
  // a tap on another tab: nothing as the finger lands, one tick as it lets go
  let down = Ref(0)
  let (felt, place) = menu_felt(fn(t, xs, y) {
    let before = t.haptics().length()
    t.press_at(xs[1], y)
    down.val = t.haptics().length() - before
    t.release(xs[1], y)
  })
  assert_eq((down.val, felt, place == Some("chats")), (0, [tick], false))
  // a tap on the tab shown: nothing
  assert_eq(menu_felt(fn(t, xs, y) { t.tap(xs[0], y) }), ([], Some("chats")))
  // a finger held still on another tab till the lens lifts, let go there: one tick, as it lets go
  let (felt, place) = menu_felt(fn(t, xs, y) {
    t.press_at(xs[1], y)
    t.run_shown(400.0)
    t.release(xs[1], y)
  })
  assert_eq((felt, place == Some("chats")), ([tick], false))
  // the lens dragged from the tab shown over the next to the third, let go there: a tick at each, none as it lets go
  let (felt, place) = menu_felt(fn(t, xs, y) { t.drag(xs[0], y, xs[2], y, steps=40) })
  assert_eq((felt, place == Some("chats")), ([tick, tick], false))
  // dragged away and back to the tab shown, let go there: a tick each way, nothing chosen
  let (felt, place) = menu_felt(fn(t, xs, y) {
    t.press_at(xs[0], y)
    for i in 1..=20 {
      t.move_to(xs[0] + (xs[1] - xs[0]) * i.to_double() / 20.0, y)
    }
    for i in 1..=20 {
      t.move_to(xs[1] + (xs[0] - xs[1]) * i.to_double() / 20.0, y)
    }
    t.release(xs[0], y)
  })
  assert_eq((felt, place), ([tick, tick], Some("chats")))
  // the last slot pressed: a tick as the menu opens; the same finger up over the bottom row and the one above it, a tick
  // at each; let go on that row, nothing more, and its page shown
  let (rx, rys) = menu_rows_at(5)
  let (felt, place) = menu_felt(fn(t, xs, y) {
    t.press_at(xs[3], y)
    t.run_shown(300.0)
    for i in 1..=24 {
      t.move_to(xs[3] + (rx - xs[3]) * i.to_double() / 24.0, y + (rys[3] - y) * i.to_double() / 24.0)
    }
    t.release(rx, rys[3])
  })
  assert_eq((felt, place), ([tick, tick, tick], Some(places[3])))
  // the menu open, a row tapped: a tick as the finger lands on it, none as it picks
  let (felt, place) = menu_felt(fn(t, xs, y) {
    t.tap(xs[3], y)
    t.run_shown(600.0)
    t.tap(rx, rys[0])
  })
  assert_eq((felt, place), ([tick, tick], Some(places[0])))
}

///|
test "bar menu: the lens dragged to the last slot and held there a moment opens the menu, the same finger going on to pick a row; dragged off before the moment is up, none; let go there, the menu and no place" {
  let places = menu_places()
  let (rx, rys) = menu_rows_at(5)
  // held: not at once, open 0.3 s on, the finger then up to a row and let go there
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  t.press_at(xs[1], y)
  for i in 1..=20 {
    t.move_to(xs[1] + (xs[3] - xs[1]) * i.to_double() / 20.0, y)
  }
  assert_false(menu_read(t, places), msg="not at once")
  t.run_shown(320.0)
  assert_true(menu_read(t, places), msg="open once the finger has rested on the last slot 0.3 s")
  for i in 1..=20 {
    t.move_to(xs[3] + (rx - xs[3]) * i.to_double() / 20.0, y + (rys[1] - y) * i.to_double() / 20.0)
  }
  t.release(rx, rys[1])
  t.run_shown(@ui.move_most_ms * 2.0)
  assert_eq(place_of(app.nav.top()), Some(places[1]))
  assert_false(menu_read(t, places))
  // dragged off before the moment is up: no menu, the place let go on
  let (t, _) = bar_at_rest()
  t.press_at(xs[0], y)
  for i in 1..=20 {
    t.move_to(xs[0] + (xs[3] - xs[0]) * i.to_double() / 20.0, y)
  }
  t.run_shown(150.0)
  for i in 1..=10 {
    t.move_to(xs[3] + (xs[2] - xs[3]) * i.to_double() / 10.0, y)
  }
  t.run_shown(400.0)
  assert_false(menu_read(t, places))
  t.release(xs[2], y)
  t.run_shown(@ui.move_most_ms * 2.0)
  assert_false(menu_read(t, places))
  assert_true(place_of(app.nav.top()) != Some("chats"), msg="the place the lens was let go on")
  // let go on the last slot before the moment is up: the menu, and no place chosen
  let (t, _) = bar_at_rest()
  t.press_at(xs[0], y)
  for i in 1..=20 {
    t.move_to(xs[0] + (xs[3] - xs[0]) * i.to_double() / 20.0, y)
  }
  t.release(xs[3], y)
  t.run_shown(@ui.move_most_ms * 2.0)
  assert_true(menu_read(t, places))
  assert_eq(place_of(app.nav.top()), Some("chats"))
}

///|
test "bar menu: the selection and the lens it lifts into are one thing: wherever both are drawn they are the same shape, and the lens magnifies nothing itself" {
  if @ui.test_at_a_rate() {
    return
  }
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  let seen = Ref(0)
  let both = Ref(0)
  let wrong : Array[String] = []
  let check = fn() {
    match menu_lens(t) {
      Some((lx, ly, lw, lh, zoom)) => {
        seen.val += 1
        if (zoom - -64.0).abs() >= 0.001 {
          wrong.push("the lens magnifies by itself: \{zoom}")
        }
        for s in menu_selections(t) {
          let (x, sy, w, h, _) = s
          both.val += 1
          if (x - lx).abs() >= 0.51 || (sy - ly).abs() >= 0.51 || (w - lw).abs() >= 0.51 || (h - lh).abs() >= 0.51 {
            wrong.push(
              "the selection (\{x}, \{sy}, \{w}, \{h}) under a lens of another shape (\{lx}, \{ly}, \{lw}, \{lh}) at \{t.time()}",
            )
          }
        }
      }
      None => ()
    }
  }
  t.each_frame(Some(check))
  // held till it lifts, dragged to the next tab, let go: lifting, flying and landing
  t.press_at(xs[0], y)
  t.run_shown(260.0)
  for i in 1..=30 {
    t.move_to(xs[0] + (xs[1] - xs[0]) * i.to_double() / 30.0, y)
    t.run_shown(1000.0 / 60.0)
  }
  t.release(xs[1], y)
  t.run_shown(@ui.move_most_ms * 2.0)
  // a tap across the bar: the lens of its flight
  t.tap(xs[2], y)
  t.run_shown(@ui.move_most_ms * 2.0)
  t.each_frame(None)
  assert_eq(wrong[0:imin(wrong.length(), 3)].to_owned(), [])
  assert_true(seen.val > 20 && both.val > 4, msg="the lens seen in \{seen.val} frames, with the selection under it in \{both.val}")
  assert_true(menu_lens(t) is None, msg="landed, the lens is gone and the selection alone is there")
  assert_eq(menu_selections(t).length(), 1)
}

///|
test "bar menu: a glyph the lifted lens is over grows in place; one it is not over neither moves nor changes size as the lens comes and goes" {
  if @ui.test_at_a_rate() {
    return
  }
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  let names = menu_places()
  ignore(names)
  let src = fixture("home")
  let ws = workspace_in_view(src).0.unwrap()
  let slots = bars_in(src, ws.id).0[0]
  let rect = fn(i : Int) { t.get(Tab, label=place_label(slots[i])).rect }
  // held on the tab shown till the lens is lifted whole and the pressed bar has grown
  t.press_at(xs[0], y)
  t.run_shown(600.0)
  let far0 = rect(2)
  let near0 = rect(1)
  let own0 = rect(0)
  // (the lens over the first tab: its glyph larger than the next one's by the lens's zoom)
  assert_true((own0.2 / near0.2 - 1.15).abs() < 0.01, msg="under the lens \{own0.2}, beside it \{near0.2}")
  // dragged slowly to the second tab: the third, which the lens never comes over, is drawn as it was all the way
  for i in 1..=60 {
    t.move_to(xs[0] + (xs[1] - xs[0]) * i.to_double() / 60.0, y)
    t.run_shown(1000.0 / 60.0)
    let far = rect(2)
    assert_true(
      (far.0 - far0.0).abs() < 0.01 && (far.1 - far0.1).abs() < 0.01 && (far.2 - far0.2).abs() < 0.01 && (far.3 - far0.3).abs() < 0.01,
      msg="a glyph the lens is not over moved or changed size: \{Repr(far)} from \{Repr(far0)} at step \{i}",
    )
  }
  t.run_shown(600.0)
  let own1 = rect(1)
  let left1 = rect(0)
  // (the second tab's glyph larger now, about its own middle: in place)
  assert_true((own1.2 / left1.2 - 1.15).abs() < 0.01, msg="under the lens \{own1.2}, the one it left \{left1.2}")
  assert_true(
    (own1.0 + own1.2 / 2.0 - (near0.0 + near0.2 / 2.0)).abs() < 0.01 && (own1.1 + own1.3 / 2.0 - (near0.1 + near0.3 / 2.0)).abs() < 0.01,
    msg="the glyph under the lens grew off its own middle: \{Repr(own1)} from \{Repr(near0)}",
  )
  t.release(xs[1], y)
  t.run_shown(@ui.move_most_ms * 2.0)
}

///|
/// The frames of `act` on the bar at rest, the place `place` shown first (the chats where none): each frame's moment,
/// the glass's top and height, the selections' greys and the lens drawn in it.
fn menu_frames(
  place : String?,
  dark : Bool,
  act : (@ui.Tester, Array[Double], Double) -> Unit,
) -> Array[(Double, Double, Double, Array[(Double, Double, Double, Double, Int)], Bool, Double)] {
  new_run()
  let src = fixture(if dark { "home-dark" } else { "home" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2, dark~)
  t.draw()
  t.run_shown(@ui.move_most_ms)
  match place {
    Some(p) => {
      @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.go_place(p) |> ignore })
      t.run_shown(@ui.move_most_ms * 3.0)
    }
    None => ()
  }
  let rest = bar_rest()
  if rest > t.time() {
    t.run_shown(rest - t.time())
  }
  let (xs, y) = (bar_centres(390.0 - 44.0, bar.k.to, 4).map(fn(x) { x + 22.0 }), 844.0 - 22.0 - 25.0)
  let frames = []
  let take = fn() {
    let (top, high) = menu_glass(t)
    // (and where the last slot's middle is across then, the notch as it is at that moment)
    let slot = bar_centres(390.0 - 44.0, bar.k.at(t.time()).0, 4)[3] + 22.0
    frames.push((t.time(), top, high, menu_selections(t), menu_lens(t) is Some(_), slot))
  }
  take()
  t.each_frame(Some(take))
  act(t, xs, y)
  t.each_frame(None)
  frames
}

///|
/// Holds of `frames` (menu_frames') that nothing jumps between two of them drawn a frame apart: the glass's height by
/// no more than `most` a 60th of a second, and the grey that is seen of the selections together (the bar's own and the
/// menu's indicator: how much of it shows, wherever it is) by no more than a fifth.
fn menu_steady(name : String, frames : Array[(Double, Double, Double, Array[(Double, Double, Double, Double, Int)], Bool, Double)], most : Double) -> Unit raise {
  for i in 1..<frames.length() {
    let (t1, _, h1, s1, _, _) = frames[i]
    let (t0, _, h0, s0, _, _) = frames[i - 1]
    let dt = t1 - t0
    if dt <= 0.0 || dt > 17.0 {
      continue
    }
    assert_true((h1 - h0).abs() <= most * dt / (1000.0 / 60.0), msg="\{name}: the glass's height jumped \{h0} -> \{h1} in \{dt} ms at \{t1}")
    let grey = fn(s : Array[(Double, Double, Double, Double, Int)]) {
      let mut a = 0
      for r in s {
        a = a + r.4
      }
      a
    }
    let full = if grey(frames[0].3) > 0 { grey(frames[0].3) } else { 20 }
    assert_true(
      (grey(s1) - grey(s0)).abs().to_double() <= full.to_double() * 0.5 + 1.0,
      msg="\{name}: the selection's grey jumped \{grey(s0)} -> \{grey(s1)} of \{full} in \{dt} ms at \{t1}",
    )
  }
}

///|
test "bar menu: opening and folding back, frame by frame: the glass grows a little past the menu and settles, folds back without dipping under the bar, and nothing jumps between two frames, by day and by night, the page shown one of the bar's or one of the menu's" {
  if @ui.test_at_a_rate() {
    return
  }
  let places = menu_places()
  for dark in [false, true] {
    for place in [None, Some(places[1])] {
      let name = "dark \{dark}, on \{place.unwrap_or("chats")}"
      // opened by a tap on the last slot, left to settle; then a tap off it, left to settle
      let opened = Ref(0)
      let frames = menu_frames(place, dark, fn(t, xs, y) {
        t.tap(xs[3], y)
        t.run_shown(900.0)
        opened.val = 1
        t.tap(100.0, 200.0)
        t.run_shown(900.0)
      })
      let highs = frames.map(fn(f) { f.2 })
      let most = highs.fold(init=0.0, fn(a, b) { dmax(a, b) })
      let least = highs.fold(init=1000.0, fn(a, b) { dmin(a, b) })
      assert_true(most > 256.0 + 2.0 && most < 256.0 + 12.0, msg="\{name}: it springs a little past the menu: \{most} in \{frames.length()} frames, \{Repr(highs[0:imin(40, highs.length())].to_owned())}")
      assert_true(least > 50.0 - 1.0, msg="\{name}: it does not dip under the bar: \{least}")
      assert_true((frames[frames.length() - 1].2 - 50.0).abs() < 0.01, msg="\{name}: folded back to the bar")
      menu_steady(name, frames, 40.0)
      // (the bar at rest before and after: one selection, whole, in the same place)
      let first = frames[0].3
      let last = frames[frames.length() - 1].3
      assert_eq((first.length(), last.length()), (1, 1), msg=name)
      assert_true(
        (first[0].0 - last[0].0).abs() < 0.01 && (first[0].2 - last[0].2).abs() < 0.01 && first[0].4 == last[0].4,
        msg="\{name}: the selection after is not as before: \{Repr(first[0])} \{Repr(last[0])}",
      )
    }
  }
}

///|
test "bar menu: a row picked, the indicator lands on the last slot as the bar's selection: nothing jumps between two frames, and it ends where the selection rests on that slot" {
  if @ui.test_at_a_rate() {
    return
  }
  let (rx, rys) = menu_rows_at(5)
  for dark in [false, true] {
    let frames = menu_frames(None, dark, fn(t, xs, y) {
      t.tap(xs[3], y)
      t.run_shown(900.0)
      t.tap(rx, rys[1])
      t.run_shown(1200.0)
    })
    menu_steady("dark \{dark}", frames, 40.0)
    // (once the glass is the bar's height again, the grey is on the last slot in every frame, wherever the notch has
    // that slot then: the page picked has no action, and the bar grows longer under the indicator as it lands)
    let mut landed = 0
    let mut picked = false
    for f in frames {
      let (at, _, high, sel, _, slot) = f
      if high > 200.0 {
        picked = true
      }
      if picked && high < 50.5 && sel.length() == 1 && sel[0].4 >= 10 {
        landed += 1
        let cx = sel[0].0 + sel[0].2 / 2.0
        // (within what the glass, still drawn in a little along the bar, draws the slot in by)
        assert_true((cx - slot).abs() < 8.0, msg="dark \{dark}: landed, the selection at \{cx}, the last slot at \{slot}, at \{at}")
      }
    }
    assert_true(landed > 10, msg="dark \{dark}: \{landed} frames landed")
    let last = frames[frames.length() - 1].3
    assert_eq(last.length(), 1)
    // (on the last slot: its middle across the fourth slot's, the notch as the page picked has it)
    let cx = last[0].0 + last[0].2 / 2.0
    let slot = bar_centres(390.0 - 44.0, bar.k.to, 4)[3] + 22.0
    assert_true((cx - slot).abs() < 1.0, msg="dark \{dark}: the selection at \{cx}, the last slot at \{slot}")
  }
}

///|
/// How far into its opening the menu is folded back, how far into that fold it is opened again, and how long that
/// second opening is watched: each well inside its spring's way (tab_menu_open's and tab_menu_close's), the glass in
/// flight at every turn.
let turn_early_ms : Double = 70.0

///|
let turn_back_ms : Double = 120.0

///|
let turn_again_ms : Double = 200.0

///|
test "bar menu: a close during the opening turns the glass round from where it is, at the speed it has; an opening during the close likewise: nothing jumps between two frames" {
  if @ui.test_at_a_rate() {
    return
  }
  let turned = Ref(0.0)
  let frames = menu_frames(None, false, fn(t, xs, y) {
    // (each turn drawn at its own moment and a 120th of a second on, not frame by frame: a spring turned round in
    // flight slows faster than the frames' own judge of what stops dead lets by (sizes_steady), as Comma's does; the
    // way round itself is held of the glass's own numbers: bar_moment_wbtest's)
    t.tap(xs[3], y)
    t.run_for(turn_early_ms)
    turned.val = menu_glass(t).1
    // (folded back a moment into its opening, the glass still on its way)
    t.tap(100.0, 200.0)
    t.frame_at(t.time() + 1000.0 / 120.0)
    t.run_for(turn_back_ms)
    // (and opened again on its way back)
    t.tap(xs[3], y)
    t.frame_at(t.time() + 1000.0 / 120.0)
    t.run_for(turn_again_ms)
    t.run_shown(700.0)
    t.tap(100.0, 200.0)
    t.run_shown(900.0)
  })
  assert_true(turned.val > 60.0 && turned.val < 256.0, msg="turned round at \{turned.val}")
  menu_steady("turned", frames, 40.0)
  // (still on its way up for a moment after the close was said)
  let after = frames.iter().find_first(fn(f) { f.2 > turned.val + 0.5 })
  assert_true(after is Some(_), msg="the glass stopped dead as it was turned round at \{turned.val}")
  assert_true((frames[frames.length() - 1].2 - 50.0).abs() < 0.01)
}

///|
test "bar menu: a key or a screen reader opens the menu by the last slot, moves through its rows and picks one; Escape folds it back" {
  let (t, _) = bar_at_rest()
  let places = menu_places()
  let more = fn(open : Bool) {
    t.query(Button, label=tr("android-misc.bar.more", args=[("name", bar_said_of(places[0]))]), expanded=open)
  }
  assert_true(more(false) is Some(_), msg="the last slot is a button that says what it stands for, not expanded")
  t.click(Button, label=tr("android-misc.bar.more", args=[("name", bar_said_of(places[0]))]))
  t.run_shown(@ui.move_most_ms * 2.0)
  assert_true(more(true) is Some(_) && menu_read(t, places))
  // (every row a press's target 44 high at least)
  for p in places {
    let (_, _, w, h) = t.get(MenuItem, label=place_label(p)).rect
    assert_true(w >= 44.0 && h >= 44.0, msg="\{p}: \{w} by \{h}")
  }
  // Escape folds it back
  t.key(@ui.key_escape)
  t.run_shown(@ui.move_most_ms * 2.0)
  assert_true(more(false) is Some(_) && !menu_read(t, places))
  // opened again, a row pressed as a screen reader presses it: its page
  t.click(Button, label=tr("android-misc.bar.more", args=[("name", bar_said_of(places[0]))]))
  t.run_shown(@ui.move_most_ms * 2.0)
  t.click(MenuItem, label=place_label(places[4]))
  t.run_shown(@ui.move_most_ms * 2.0)
  assert_eq(place_of(app.nav.top()), Some(places[4]))
  assert_false(menu_read(t, places))
}

///|
test "bar menu: the menu's rows are made in the frame it opens; no frame of its growing after that, nor of its folding back, builds a node or lays one out" {
  if @ui.test_at_a_rate() {
    return
  }
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  // (counted: each frame as it is drawn, none built whole beside it)
  t.check_looks(false)
  let work : Array[(Double, Int, Int, String)] = []
  t.each_frame(
    Some(fn() {
      let p = t.frame_perf()
      work.push((t.time(), p.nodes, p.laid, if p.nodes > 0 || p.laid > 0 { t.built_why() } else { "" }))
    }),
  )
  let opened_at = t.time()
  t.tap(xs[3], y)
  t.run_shown(900.0)
  let shut_at = t.time()
  t.tap(100.0, 200.0)
  t.run_shown(900.0)
  t.each_frame(None)
  t.check_looks(true)
  let opening = work.filter(fn(w) { w.0 > opened_at && w.0 <= shut_at })
  let closing = work.filter(fn(w) { w.0 > shut_at })
  let said = fn(ws : Array[(Double, Int, Int, String)]) {
    ws.filter(fn(w) { w.1 > 0 || w.2 > 0 }).map(fn(w) { "+\{(w.0 - opened_at).to_int()} ms: \{w.1} built, \{w.2} laid (\{w.3})" }).join("; ")
  }
  println("bar menu frames: opening \{opening.length()}, closing \{closing.length()}; built or laid in: \{said(work)}")
  assert_true(opening.length() > 20 && closing.length() > 10, msg="\{opening.length()} \{closing.length()}")
  // (the frames of the press and of the finger's lifting make the rows and tell the tree what is read out; every frame
  // after them, the glass growing, the rows rising, the indicator flying: drawn alone, nothing laid out. A frame built
  // for what came from outside meanwhile (the core's answer to what the menu's places asked ahead: frame_watch.mbt's
  // outside_said) is no work of the bar's motion, and lays nothing out either)
  let after = fn(ws : Array[(Double, Int, Int, String)], from : Double) {
    ws.filter(fn(w) { w.0 > from + 2.0 * 1000.0 / 60.0 + 1.0 && !(w.2 == 0 && w.3.contains("src/ui/frame_watch.mbt")) })
  }
  assert_eq(said(after(opening, opened_at)), "")
  assert_eq(said(after(closing, shut_at)), "")
  assert_true(work.filter(fn(w) { w.0 > opened_at + 2.0 * 1000.0 / 60.0 + 1.0 && w.2 > 0 }).is_empty(), msg=said(work))
}
