// The bar's action button on its way, drawn as each frame is painted: back from a chat laid out Small, the bar comes
// back and its button grows in (a chat's page offers no action, the chats' 令), after the stack's slide is over the
// only thing that moves. Each frame draws the button as large as it is then, nothing of the bar built or laid out
// again for it; the places stay in their columns as it grows (it floats apart from them); a place pressed where it is
// drawn then is that place; and each frame painted so is the frame built whole (the Tester's looks_check, on wherever
// nothing is counted).

///|
/// The fixture's chat open laid out Small with a finger, gone back from (the system's back): the button growing from
/// then, the display's frames on.
fn bar_backed() -> @ui.Tester raise {
  let t = tape_chat(2, 390.0, 844.0)
  assert_eq(bar.k.to, 0.0)
  t.set_frame_period(t.frame_period())
  t.back()
  assert_eq(bar.k.to, 1.0)
  t
}

///|
/// The fixture's chat open laid out Small with a finger, gone back from: drawn on to the end of the stack's slide (the
/// slide across the window), the display's frames from then on.
fn bar_back() -> @ui.Tester raise {
  let t = tape_chat(2, 390.0, 844.0)
  // (a chat's page: the bar gone, its button gone)
  assert_eq(bar.k.to, 0.0)
  t.back()
  t.run_for(@ui.move_ms(390.0))
  t.set_frame_period(t.frame_period())
  // (the button still growing, for a few frames more at least)
  assert_true(bar.k.to == 1.0 && bar.k.end() > t.time() + t.frame_period() * 4.0, msg="\{bar.k.end()} \{t.time()}")
  t
}

///|
/// How wide the action button's ground is drawn at the last frame (the accent under its glass, by the window's right
/// over the bar), 0 none.
fn action_drawn(t : @ui.Tester) -> Double {
  action_rect(t).2
}

///|
/// Where the action button's ground is drawn at the last frame (x, y, w, h; all 0 none): the largest of it.
fn action_rect(t : @ui.Tester) -> (Double, Double, Double, Double) {
  let theme = @sf.theme()
  let ink = @sf.over(theme.p.bg, @sf.alpha(theme.p.accent, action_ink))
  t
  .drawn_rects()
  .filter(fn(r) { r.0 > 195.0 && r.1 > 500.0 && r.2 <= drop + 0.5 && r.4 >> 8 == ink >> 8 && (r.4 & 0xFFL) > 0L })
  .fold(init=(0.0, 0.0, 0.0, 0.0), fn(a, r) { if r.2 > a.2 { (r.0, r.1, r.2, r.3) } else { a } })
}

///|
/// Where the bar's place `key` is at the last frame, across, in the window: where it is said to be (its middle), where
/// its icon is drawn (the middle of the shapes drawn in its room's icon row, in a place's inks, dim or lit: not what
/// slides under it), and its column's middle (bar_centres).
fn place_across(t : @ui.Tester, key : String) -> (Double, Double, Double) raise {
  let told = bar.told.unwrap()
  let items = told.sets[told.cur]
  let j = items.search(key).unwrap()
  let (x, y, w, _) = said_at(t, place_label(key)).unwrap()
  let mut lo = @double.infinity
  let mut hi = -@double.infinity
  for s in t.drawn_shapes() {
    let (cx, cy) = (s.0 + s.2 / 2.0, s.1 + s.3 / 2.0)
    let ink = s.5 >> 8
    if cx >= x && cx <= x + w && cy >= y && cy <= y + pill_mid * 2.0 && (ink == 0x6B7280L || ink == 0x111827L) {
      lo = dmin(lo, s.0)
      hi = dmax(hi, s.0 + s.2)
    }
  }
  assert_true(hi > lo, msg="no icon drawn in \{key}'s room")
  (x + w / 2.0, (lo + hi) / 2.0, bar_centres(told.width, 1.0, items.length())[j])
}

///|
test "bar: back from a chat, the action's button growing frame by frame: drawn as large as it is then, nothing of the bar built or laid out for it" {
  let t = bar_back()
  // (counted: each frame as it is drawn, none built whole beside it)
  t.check_looks(false)
  // (two frames after the stack's slide: built whole for what came from outside as it ended, on main as on this; the
  // bar not among them)
  t.frame_at(t.next_frame_time())
  let warm1 = "\{t.frame_perf().nodes} \{t.built_why()}"
  t.frame_at(t.next_frame_time())
  let warm2 = "\{t.frame_perf().nodes} \{t.built_why()}"
  let first = bar.k_at(t.time())
  t.frame_at(t.next_frame_time())
  let p1 = t.frame_perf()
  let why1 = t.built_why()
  let second = bar.k_at(t.time())
  t.frame_at(t.next_frame_time())
  let p2 = t.frame_perf()
  let third = bar.k_at(t.time())
  t.check_looks(true)
  // it moves on its way across these frames (drawn as large as it is at each one's moment: the look of what is laid
  // out whole, looks_check)
  assert_true(first != second && second != third, msg="\{first} \{second} \{third}")
  // and nothing of the bar is built or laid out for it
  assert_eq((p1.nodes, p1.laid, p2.nodes, p2.laid), (0, 0, 0, 0), msg="before: \{warm1} / \{warm2}; counted: \{Repr(p1)} \{why1} / \{Repr(p2)} \{t.built_why()}")
}

///|
test "bar: the action's button growing, each frame painted so is the frame built whole; the places drawn and read out in their columns all along" {
  let t = bar_backed()
  // (the bar coming up from below the window: its places in it from the third frame on)
  t.frame_at(t.next_frame_time())
  t.frame_at(t.next_frame_time())
  t.frame_at(t.next_frame_time())
  let one = place_across(t, "files")
  t.frame_at(t.next_frame_time())
  let two = place_across(t, "files")
  // its icon drawn in its column at each frame (on the device's pixels: half a point at the Tester's scale of 2), and
  // read out there
  assert_true((one.1 - one.2).abs() <= 2.0 && (two.1 - two.2).abs() <= 2.0, msg="\{Repr(one)} \{Repr(two)}")
  assert_true((one.0 - one.2).abs() <= 0.5 && (two.0 - two.2).abs() <= 0.5, msg="\{Repr(one)} \{Repr(two)}")
  // to its end, each frame compared with the frame built whole (looks_check)
  t.run_for(bar_rest() - t.time())
  assert_true((action_drawn(t) - drop).abs() <= 0.5, msg="\{action_drawn(t)}")
}

///|
test "bar: a place pressed where it is drawn as the action's button grows is that place" {
  let t = bar_back()
  t.frame_at(t.next_frame_time())
  let (_, drawn, _) = place_across(t, "files")
  let (_, y, _, _) = said_at(t, place_label("files")).unwrap()
  t.tap(drawn, y + pill_mid)
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() == Files)
}

///|
test "bar: a hold hides the action's button and leaves the places where they are; release brings it back" {
  let held_frame_ms = 1000.0
  let t = tester("home")
  let (xs, y) = bar_places_at()
  let before = place_across(t, "files")
  assert_true((action_drawn(t) - drop).abs() <= 0.5, msg="\{action_drawn(t)}")
  t.press_at(xs[0], y)
  t.run_for(bar_hold_ms)
  t.frame()
  t.run_for(held_frame_ms)
  let held = place_across(t, "files")
  assert_eq(action_drawn(t), 0.0)
  assert_true((held.0 - before.0).abs() <= 0.5 && (held.1 - before.1).abs() <= 0.5, msg="\{Repr(before)} \{Repr(held)}")
  t.release(xs[0], y)
  t.run_for(held_frame_ms)
  assert_true((action_drawn(t) - drop).abs() <= 0.5, msg="\{action_drawn(t)}")
}

///|
test "bar: sliding chooses the place under the finger, its column's" {
  for ms in [100.0, 1000.0] {
    let t = tester("home")
    let (xs, y) = bar_places_at()
    let told = bar.told.unwrap()
    let items = told.sets[told.cur]
    assert_eq(items[0], "chats")
    assert_eq(items[1], "files")
    t.press_at(xs[3], y)
    t.run_for(bar_hold_ms)
    t.frame()
    t.run_for(ms)
    // just on the chats' side of the line between the two columns
    let x = (xs[0] + xs[1]) / 2.0 - 2.0
    t.move_to(x, y)
    assert_eq(bar.felt, "\{told.cur}/chats", msg="\{ms}")
    t.release(x, y)
    assert_true(app.nav.top() == Home, msg="\{ms}")
  }
}
