// The bar's notch on its way, drawn as each frame is painted (bar.mbt: bar_drawn reads what goes in the phase that draws
// it): back from a chat laid out Small, the bar comes back and its notch opens (a chat's page offers no action, the
// chats' 令), after the stack's slide is over the only thing that moves. Each frame draws the notch, the discs in it
// and the places beside it where the notch has them then, nothing of the bar built or laid out again for it; a place
// pressed where it is drawn then is that place; and each frame painted so is the frame built whole (the Tester's
// looks_check, on wherever nothing is counted).

///|
/// The fixture's chat open laid out Small with a finger, gone back from (the system's back): the notch opening from
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
  // (a chat's page: the bar gone, its notch closed)
  assert_eq(bar.k.to, 0.0)
  t.back()
  t.run_for(@ui.move_ms(390.0))
  t.set_frame_period(t.frame_period())
  // (the notch still opening, for a few frames more at least)
  assert_true(bar.k.to == 1.0 && bar.k.end() > t.time() + t.frame_period() * 4.0, msg="\{bar.k.end()} \{t.time()}")
  t
}

///|
/// How wide the last frame drew the bar's capsule of glass (Tester::drawn_glass: the glass as high as the bar, the
/// widest), its right end in by the action's room as far as the notch is open; 0 none.
fn glass_notch(t : @ui.Tester) -> Double {
  t.drawn_glass().fold(init=0.0, fn(a, g) {
    if (g.0 - 22.0).abs() < 1.0 && (g.3 - bar_track).abs() < 1.0 && g.2 > a {
      g.2
    } else {
      a
    }
  })
}

///|
/// How wide the bar draws its capsule with the notch `k` open, on a 390 window's bar.
fn notch_of(k : Double) -> Double {
  bar_capsule_w(390.0 - 44.0, k)
}

///|
/// Where the bar's place `key` is at the last frame, across, in the window: where it is said to be (its middle), where
/// its icon is drawn (the middle of the shapes drawn across its room, at or below it, in a place's inks, dim or lit: not
/// what slides under it; the bar coming up drawn lower than it is laid out), and where the notch as it is at the frame's moment has it (bar_centres, in the bar's frame 22 in).
fn place_across(t : @ui.Tester, key : String) -> (Double, Double, Double) raise {
  let told = bar.told.unwrap()
  let items = told.sets[told.cur]
  let j = items.search(key).unwrap()
  let (x, _, w, _) = said_at(t, place_label(key)).unwrap()
  // The bar may rise or enter from below; find its actual painted glass instead of assuming the distance moved.
  let bottom = t.drawn_glass_corners().fold(init=0.0, fn(a, g) {
    if (g.0 - 22.0).abs() < 1.0 && g.2 > told.width / 2.0 { dmax(a, g.1 + g.3) } else { a }
  })
  assert_true(bottom > 0.0, msg="bar glass not drawn")
  let top = bottom - bar_track - 2.0
  let mut lo = @double.infinity
  let mut hi = -@double.infinity
  for s in t.drawn_shapes() {
    let (cx, cy) = (s.0 + s.2 / 2.0, s.1 + s.3 / 2.0)
    let ink = s.5 >> 8
    if cx >= x && cx <= x + w && cy >= top && cy <= bottom + 2.0 && (ink == 0x6B7280L || ink == 0x111827L) {
      lo = dmin(lo, s.0)
      hi = dmax(hi, s.0 + s.2)
    }
  }
  assert_true(hi > lo, msg="no icon drawn in \{key}'s room")
  (x + w / 2.0, (lo + hi) / 2.0, 22.0 + bar_centres(told.width, bar.k_at(t.time()), items.length())[j])
}

///|
test "bar: back from a chat, the notch opening frame by frame: drawn where it is then, nothing of the bar built or laid out for it" {
  let t = bar_back()
  // (counted: each frame as it is drawn, none built whole beside it)
  t.check_looks(false)
  // (two frames after the stack's slide: built whole for what came from outside as it ended (an old view's watch told,
  // what it told outside), on main as on this; the bar not among them)
  t.frame_at(t.next_frame_time())
  let warm1 = "\{t.frame_perf().nodes} \{t.built_why()}"
  t.frame_at(t.next_frame_time())
  let warm2 = "\{t.frame_perf().nodes} \{t.built_why()}"
  let first = glass_notch(t)
  t.frame_at(t.next_frame_time())
  let p1 = t.frame_perf()
  let why1 = t.built_why()
  let second = glass_notch(t)
  let at = t.time()
  t.frame_at(t.next_frame_time())
  let p2 = t.frame_perf()
  let third = glass_notch(t)
  t.check_looks(true)
  // it moves: the notch drawn where it is at each frame's moment
  assert_true(first != second && second != third, msg="\{Repr(first)} \{Repr(second)} \{Repr(third)}")
  assert_true((second - notch_of(bar.k_at(at))).abs() < 0.01, msg="\{second} \{notch_of(bar.k_at(at))}")
  // and nothing of the bar is built or laid out for it
  assert_eq((p1.nodes, p1.laid, p2.nodes, p2.laid), (0, 0, 0, 0), msg="before: \{warm1} / \{warm2}; counted: \{Repr(p1)} \{why1} / \{Repr(p2)} \{t.built_why()}")
}

///|
test "bar: the notch opening, each frame painted so is the frame built whole; the places drawn and read out where it has them" {
  let t = bar_backed()
  // (the bar coming up from below the window: its places in it from the third frame on)
  t.frame_at(t.next_frame_time())
  t.frame_at(t.next_frame_time())
  t.frame_at(t.next_frame_time())
  let one = place_across(t, "files")
  t.frame_at(t.next_frame_time())
  let two = place_across(t, "files")
  // its icon drawn where the notch has it at each frame, moving with it (on the device's pixels: half a point at the
  // Tester's scale of 2; the icon's drawing as off its middle at both), and read out there
  let off = one.1 - one.2
  assert_true(one.1 != two.1 && off.abs() <= 2.0 && (two.1 - two.2 - off).abs() <= 0.5, msg="\{Repr(one)} \{Repr(two)}")
  assert_true((one.0 - one.2).abs() <= 0.5 && (two.0 - two.2).abs() <= 0.5, msg="\{Repr(one)} \{Repr(two)}")
  // to its end, each frame compared with the frame built whole (looks_check)
  t.run_for(bar_rest() - t.time())
  assert_true((glass_notch(t) - notch_of(1.0)).abs() < 0.01)
}

///|
test "bar: a place pressed where it is drawn as the notch opens is that place" {
  let t = bar_back()
  t.frame_at(t.next_frame_time())
  // (where its icon is drawn then, the middle of its row)
  let (_, drawn, _) = place_across(t, "files")
  let (_, y, _, h) = said_at(t, place_label("files")).unwrap()
  t.tap(drawn, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() == Files)
}

///|
test "bar: a hold keeps the action's room and the places where they are, held and let go" {
  let during_rise_ms = 100.0
  let held_frame_ms = 1000.0
  let t = tester("home")
  let (xs, y) = bar_places_at()
  let open = glass_notch(t)
  let before = place_across(t, "files")
  assert_true((open - notch_of(1.0)).abs() < 0.01, msg="\{open}")
  t.press_at(xs[0], y)
  t.run_for(bar_hold_ms)
  t.frame()
  t.run_for(during_rise_ms)
  assert_true((glass_notch(t) - open).abs() < 0.01, msg="\{open} \{glass_notch(t)}")
  let during = place_across(t, "files")
  assert_true((during.0 - during.2).abs() <= 0.5 && (during.0 - before.0).abs() <= 0.5, msg="\{Repr(before)} \{Repr(during)}")
  t.run_for(held_frame_ms)
  assert_true((glass_notch(t) - open).abs() < 0.01)
  t.release(xs[0], y)
  t.run_for(held_frame_ms)
  let after = place_across(t, "files")
  assert_true((glass_notch(t) - open).abs() < 0.001)
  assert_true((after.0 - before.0).abs() <= 0.5 && (after.1 - before.1).abs() <= 0.5, msg="\{Repr(before)} \{Repr(after)}")
}

///|
test "bar: sliding chooses the place under the finger, either side of the line between two places" {
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
    let boundary = (xs[0] + xs[1]) / 2.0
    t.move_to(boundary + 4.0, y)
    assert_eq(bar.felt, "\{told.cur}/files", msg="\{ms}")
    t.move_to(boundary - 4.0, y)
    assert_eq(bar.felt, "\{told.cur}/chats", msg="\{ms}")
    t.release(boundary - 4.0, y)
    assert_true(app.nav.top() == Home, msg="\{ms}")
  }
}

///|
test "bar: capsule and action circle share one liquid glass backdrop capture" {
  let t = tester("home")
  let liquids = t.drawn_glass().filter(fn(g) { g.4 == 6 })
  assert_eq(liquids.length(), 2, msg="\{Repr(liquids)}")
  assert_true(liquids[0].5 > 0, msg="\{Repr(liquids)}")
  assert_eq(liquids[1].5, liquids[0].5, msg="\{Repr(liquids)}")
}

///|
test "bar: dragging panel up and down triggers capillary liquid fuse and split" {
  let settle_ms = 1000.0
  let drag_step_ms = 16.0
  let t = tester("home")
  let (xs, y) = bar_places_at()
  // At rest with ＋ separated: merge == 0.0
  assert_eq(bar_merge_at(t.time()), 0.0)
  // Drag up to open multi-row panel (＋ fuses into capsule): sample across drag frames + post-release spring
  let mut touched_open = false
  let mut early_magnet_open = false
  let mut peak_fuse_merge = 0.0
  let record_open = fn(at : Double) {
    let gap = (act_size + act_gap) * bar.k_at(at) - act_size
    let m = bar_merge_at(at)
    if gap <= bar_bond_contact_gap {
      touched_open = true
    } else if !touched_open && m > 0.0 {
      early_magnet_open = true
    }
    if gap >= -12.0 && gap <= 0.0 {
      peak_fuse_merge = dmax(peak_fuse_merge, m)
    }
  }
  t.press_at(xs[1], y)
  for step in 1..<=10 {
    let cur_y = y - 80.0 * (step.to_double() / 10.0)
    t.move_to(xs[1], cur_y)
    let t0 = t.time()
    t.run_for(drag_step_ms)
    let mut s = t0
    while s <= t.time() {
      record_open(s)
      s += 2.0
    }
  }
  t.release(xs[1], y - 80.0)
  let t_open_end = dmax(bar_rest(), t.time())
  let mut s = t.time()
  while s <= t_open_end {
    record_open(s)
    s += 2.0
  }
  t.run_for(settle_ms)
  let open_rest = (bar.o.to == 1.0, bar.k_at(t.time()) <= 0.002, bar_merge_at(t.time()) == 0.0)
  // Drag down to close panel (＋ emerges with liquid bridge, snaps past break_gap back to 0.0)
  let t_close0 = t.time()
  t.drag(xs[1], y - 56.0, xs[1], y)
  let t_close_end = dmax(bar_rest(), t.time())
  let mut peak_split_bridge = 0.0
  let mut saw_snap_zero = false
  let mut c = t_close0
  while c <= t_close_end {
    let k = bar.k_at(c)
    let gap = (act_size + act_gap) * k - act_size
    let m = bar_merge_at(c)
    if gap >= 2.0 && gap <= 7.5 {
      peak_split_bridge = dmax(peak_split_bridge, m)
    }
    if peak_split_bridge >= 25.0 && gap >= bar_bond_break_gap && m == 0.0 {
      saw_snap_zero = true
    }
    c += 2.0
  }
  t.run_for(settle_ms)
  let close_rest = (bar.o.to == 0.0, (bar.k_at(t.time()) - 1.0).abs() < 0.001, bar_merge_at(t.time()) == 0.0)
  assert_eq(
    (early_magnet_open, peak_fuse_merge >= 18.0, open_rest, peak_split_bridge >= 25.0, saw_snap_zero, close_rest),
    (false, true, (true, true, true), true, true, (true, true, true)),
    msg="peak_fuse=\{peak_fuse_merge} peak_split=\{peak_split_bridge}",
  )
}

///|
test "bar: tab switch and slow manual drag obey capillary contact/break hysteresis" {
  let settle_ms = 1000.0
  let drag_step_ms = 20.0
  let bloom_ms = 30.0
  let t = tester("home")
  let (xs, y) = bar_places_at()
  assert_eq((bar.k.to, bar_merge_at(t.time())), (1.0, 0.0))
  // 1. Tab switch: Chats -> Remote (k: 1 -> 0)
  let t_tab0 = t.time()
  assert_true(@sfbase.go_place("remote"))
  t.draw()
  assert_eq(bar.k.to, 0.0)
  let t_tab_end = dmax(bar_rest(), t.time())
  let mut touched_tab = false
  let mut early_magnet_tab = false
  let mut peak_tab_fuse = 0.0
  let mut s = t_tab0
  while s <= t_tab_end {
    let gap = (act_size + act_gap) * bar.k_at(s) - act_size
    let m = bar_merge_at(s)
    if gap <= bar_bond_contact_gap {
      touched_tab = true
    } else if !touched_tab && m > 0.0 {
      early_magnet_tab = true
    }
    if gap >= -12.0 && gap <= 0.0 {
      peak_tab_fuse = dmax(peak_tab_fuse, m)
    }
    s += 2.0
  }
  t.run_for(settle_ms)
  let tab_closed_rest = (bar.k_at(t.time()) <= 0.002, bar_merge_at(t.time()) == 0.0)
  // 2. Tab switch back: Remote -> Chats (k: 0 -> 1)
  let t_back0 = t.time()
  assert_true(@sfbase.go_place("chats"))
  t.draw()
  assert_eq(bar.k.to, 1.0)
  let t_back_end = dmax(bar_rest(), t.time())
  let mut peak_tab_split = 0.0
  let mut tab_snap_zero = false
  let mut c = t_back0
  while c <= t_back_end {
    let gap = (act_size + act_gap) * bar.k_at(c) - act_size
    let m = bar_merge_at(c)
    if gap >= 2.0 && gap <= 7.5 {
      peak_tab_split = dmax(peak_tab_split, m)
    }
    if peak_tab_split >= 25.0 && gap >= bar_bond_break_gap && m == 0.0 {
      tab_snap_zero = true
    }
    c += 2.0
  }
  t.run_for(settle_ms)
  let tab_open_rest = ((bar.k_at(t.time()) - 1.0).abs() < 0.001, bar_merge_at(t.time()) == 0.0)
  assert_eq(
    (early_magnet_tab, peak_tab_fuse >= 18.0, tab_closed_rest, peak_tab_split >= 25.0, tab_snap_zero, tab_open_rest),
    (false, true, (true, true), true, true, (true, true)),
    msg="tab_fuse=\{peak_tab_fuse} tab_split=\{peak_tab_split}",
  )
  // 3. Slow manual drag up to gap <= 1.5pt (without releasing) triggers immediate coalescence
  t.press_at(xs[1], y)
  let mut dy = 4.0
  let mut slow_bonded = false
  let mut slow_merge = 0.0
  while dy <= 72.0 {
    t.move_to(xs[1], y - dy)
    t.run_for(drag_step_ms)
    let gap = (act_size + act_gap) * bar.k_at(t.time()) - act_size
    if gap <= bar_bond_contact_gap {
      slow_bonded = bar.bond_bonded
      t.run_for(bloom_ms)
      slow_merge = bar_merge_at(t.time())
      break
    }
    dy += 4.0
  }
  t.release(xs[1], y - dy)
  t.run_for(settle_ms)
  assert_eq((slow_bonded, slow_merge >= 18.0, bar_merge_at(t.time()) == 0.0), (true, true, true), msg="slow_merge=\{slow_merge}")
}
