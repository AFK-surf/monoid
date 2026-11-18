// A place pressed again where it shows at its root (sfdesk's back_to_top.mbt): 小屏's bar, its list away from its top,
// back to its top, gliding there where it is near; at its top, nothing; 中屏 and 大屏's rail, the lit place's sidebar
// list back to its top, and at its top the press as before (its sidebar folded).

///|
/// Moments the tests here look at: a glide back up under way, and past its end.
let to_top_mid_ms : Double = 40.0

///|
let to_top_past_ms : Double = 1000.0

///|
/// The fixture's long chats laid out Small with a finger, at rest on the chats.
fn to_top_small() -> @ui.Tester {
  let t = tester("long")
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "小屏 bar: the chats' tab tapped again, its list scrolled a little down: glides back to its top, the place the same" {
  let t = to_top_small()
  let top = t.list_offset()
  let first = t.visible().0
  t.scroll_to(4)
  t.frame()
  let away = t.list_offset()
  let (xs, y) = bar_places_at()
  t.tap(xs[0], y)
  t.run_for(to_top_mid_ms)
  let mid = t.list_offset()
  t.run_for(to_top_past_ms)
  assert_true(away > top + 100.0, msg="scrolled to \{away} from \{top}")
  assert_true(mid < away && mid > top, msg="on its way at \{mid}, from \{away} to \{top}")
  assert_eq((t.list_offset(), t.visible().0, bar.told.unwrap().active), (top, first, Some("chats")))
}

///|
test "小屏 bar: the chats' tab tapped again, its list far down: at its top, the place the same" {
  let t = to_top_small()
  let top = t.list_offset()
  let first = t.visible().0
  t.scroll_to(60)
  t.frame()
  let (xs, y) = bar_places_at()
  t.tap(xs[0], y)
  t.run_for(to_top_past_ms)
  assert_eq((t.list_offset(), t.visible().0, bar.told.unwrap().active), (top, first, Some("chats")))
}

///|
test "小屏 bar: the chats' tab tapped again at its top: nothing moves; under reduced motion, back with no glide" {
  let t = to_top_small()
  let top = t.list_offset()
  let (xs, y) = bar_places_at()
  t.tap(xs[0], y)
  t.run_for(to_top_past_ms)
  let still = t.list_offset()
  t.set_reduce_motion(true)
  t.scroll_to(4)
  t.frame()
  t.tap(xs[0], y)
  t.run_for(to_top_mid_ms)
  let at_once = t.list_offset()
  t.set_reduce_motion(false)
  assert_eq((still, at_once), (top, top))
}

///|
/// The sidebar's list laid out Large (the widest list drawn in the window's left 400), as the tree has it now.
fn to_top_side_list() -> @view.ListSeen? {
  guard @ui.view_tree() is Some(tree) else { return None }
  let mut best : @view.ListSeen? = None
  for l in tree.lists_seen() {
    match tree.drawn_of(l.list) {
      Some(d) if d.x < 400.0 && d.x + d.w <= 420.0 && tree.takes_keys(l.list) => best = Some(l)
      _ => ()
    }
  }
  best
}

///|
test "大屏 rail: the lit chats pressed again, its sidebar's list down: back to its top, the sidebar kept; at its top, folded as before" {
  new_run()
  let src = fixture("long")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  let side = to_top_side_list().unwrap()
  let top = side.at
  let (sx, sy, _, sh) = match @ui.view_tree().unwrap().drawn_of(side.list) {
    Some(d) => (d.x + d.w / 2.0, d.y, d.w, d.h)
    None => (0.0, 0.0, 0.0, 0.0)
  }
  t.wheel(sx, sy + sh / 2.0, 1200.0)
  t.run_for(@ui.move_most_ms)
  let away = to_top_side_list().unwrap().at
  let keys = t.all(Button).filter(fn(b) { b.rect.0 < 70.0 })
  guard keys.search_by(fn(b) { b.label == "对话" || b.label == "全部对话" || b.label == "全部" }) is Some(i) else {
    fail("no chats' key in the rail: \{keys.map(fn(b) { b.label }).join(", ")}")
  }
  let key = keys[i]
  let (kx, ky, kw, kh) = key.rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  t.run_for(to_top_past_ms)
  let back = to_top_side_list().map(fn(l) { l.at })
  let folded_after_back = @sfdesk.side_folded()
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  t.run_for(to_top_past_ms)
  assert_true(away > top + 100.0, msg="scrolled to \{away} from \{top}, the key \{key.label}")
  assert_eq((back, folded_after_back, @sfdesk.side_folded()), (Some(top), false, true))
}
