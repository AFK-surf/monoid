// The bar's ball slid by a finger and let go still moving across (bar.mbt's bar_flung): the place it was going to, as
// it carried on, the ball going on there at the speed it had and never turned back; let go still, the place under it as
// before; a tick felt at each place the finger gets to, none at the one it set out from, one more as it is let go on
// another place than the one under the finger.

///|
/// A finger slid on the bar from the chats' place `part` of the way to the next, in `steps` moves (a finger's rate, one
/// a frame), then let go, the bar at rest on the chats first: the place shown then, what was felt from the finger's
/// down, and how the ball went across from the moment it was let go (its least speed on its way, sampled each 4 ms till
/// it first gets to where it goes: never below 0 where it goes right).
fn bar_slid(part : Double, steps : Int) -> (String?, Array[@ui.Haptic], Double) {
  let (t, _) = bar_at_rest()
  let (xs, y) = bar_places_at()
  let before = t.haptics().length()
  t.drag(xs[0], y, xs[0] + (xs[1] - xs[0]) * part, y, steps~)
  let let_go = t.time()
  // (till it first gets to where it goes: past that, the ball's own spring's bounce, ball_damping's)
  let goal = bar.ball_x.to
  let mut least = 0.0
  let mut at = let_go
  let ends = bar.ball_x.end()
  while at < ends {
    let (x, v) = bar.ball_x.at(at)
    if x >= goal {
      break
    }
    least = dmin(least, v)
    at = at + 4.0
  }
  t.run_for(@ui.move_most_ms)
  (bar.told.unwrap().active, t.haptics()[before:].to_owned(), least)
}

///|
test "bar: a quick slide toward the next place let go short of its middle lands on it, the ball going on there, felt once" {
  let (active, felt, least) = bar_slid(0.4, 4)
  assert_eq((active, felt), (Some(bar.told.unwrap().sets[bar.told.unwrap().cur][1]), [@ui.TextHandleMove]))
  assert_true(least >= -0.001, msg="the ball turned back at \{least} a second")
}

///|
test "bar: a slow slide the same way, let go short of the next place's middle: back on the chats, nothing felt" {
  let (active, felt, _) = bar_slid(0.3, 20)
  assert_eq((active, felt), (Some("chats"), []))
}

///|
test "bar: a slide past the next place's middle, let go still there: that place, a tick as the finger got to it" {
  let (active, felt, _) = bar_slid(0.8, 60)
  assert_eq((active, felt), (Some(bar.told.unwrap().sets[bar.told.unwrap().cur][1]), [@ui.TextHandleMove]))
}

///|
test "bar: where a slide let go carries it, a place's room at most, and none where the finger is still" {
  let w = 390.0 - 44.0
  let slot = bar_item_w(w, 1.0, 4)
  assert_eq(
    (bar_flung(100.0, 0.0, w), bar_flung(100.0, 0.5, w), bar_flung(100.0, 50.0, w), bar_flung(100.0, -50.0, w)),
    (100.0, 100.0 + 0.5 * bar_fling_ms, 100.0 + slot, 100.0 - slot),
  )
}
