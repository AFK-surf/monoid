// How a hand drives a station's screen beyond a tap (screen_stage.mbt, screen_bars_node.mbt, screen.mbt): the
// station's pointer said on its own taken quietly, two fingers' scroll going on once let go, 左键 held down from its
// button for a finger to drag with, a finger driving it directly let slide a little before it drags, and where a tap
// clicked shown under it a moment.

///|
/// How long a test watches for what goes on by itself after a hand let go (a scroll's going on lasts some 1.4 s at
/// most), how long after a scroll let go a finger comes down on it, and how soon after a click 左键 is pressed again.
let watch_after_ms : Double = 1000.0

///|
let mid_fling_ms : Double = 60.0

///|
let quick_again_ms : Double = 100.0

///|
/// How far apart two fingers' moves come (a 60 Hz screen's samples), and how long they are held still before they are
/// let go of when they stop first (past fling_still_ms).
let finger_step_ms : Double = 16.0

///|
let still_before_ms : Double = 100.0

///|
/// The station's pointer said alone (a `cursor` word, not a whole state).
fn cursor_word(x : Double, y : Double, shape? : String = "default") -> Json {
  { "cursor": { "x": Json::number(x), "y": Json::number(y), "shape": Json::string(shape) } }
}

///|
/// A desktop's screen driven, live, its first frame shown (driven as a trackpad, as a phone keeps it by default).
fn desktop_live(r : ScreenRig) -> Unit {
  r.state("live", others=[], more={ "kind": Json::string("desktop") })
  r.config()
  r.frame(1000.0)
}

///|
fn wheels_of(ins : ArrayView[Json]) -> Array[Json] {
  ins.iter().filter(fn(j) { text(Some(j), "t") == "wheel" }).collect()
}

///|
/// Two fingers down round (cx, cy), moved up together `steps` times by `step` px, each `step_ms` after the last, held
/// still `still_ms`, then let go of (the second first).
fn two_up(r : ScreenRig, cx : Double, cy : Double, steps : Int, step : Double, step_ms : Double, still_ms : Double) -> Unit {
  r.t.press_at(cx - 50.0, cy)
  r.t.touch(4, cx + 50.0, cy)
  r.t.draw()
  for i in 1..=steps {
    let d = i.to_double() * step
    r.t.touch(1, cx - 50.0, cy - d)
    r.t.touch(5, cx + 50.0, cy - d)
    r.t.run_for(step_ms)
  }
  if still_ms > 0.0 {
    r.t.run_for(still_ms)
  }
  let d = steps.to_double() * step
  r.t.touch(6, cx + 50.0, cy - d)
  r.t.release(cx - 50.0, cy - d)
}

///|
test "the station's pointer said alone is taken quietly on a picture's layer: the host told where, nothing built; another shape built" {
  let r = screen_rig(h264=true)
  let st = r.layered()
  r.t.frame_at(r.t.next_frame_time())
  let moved = cursor_word(0.25, 0.75)
  assert_true(screen_value_quiet(moved))
  let (on_value, _) = r.views[r.views.length() - 1]
  on_value(moved, None)
  assert_eq(pointer_told(r, st).last(), Some("pointer at 0.25 0.75"))
  r.t.frame_at(r.t.next_frame_time())
  assert_eq(r.t.built_why(), "")
  assert_eq(r.sess().cursor(), Some((0.25, 0.75)))
  // a state saying nothing of the pointer after it: where it was said alone kept
  r.state("live", control=false, others=[], more={ "kind": Json::string("desktop") })
  assert_eq(r.sess().cursor(), Some((0.25, 0.75)))
  // another shape: not quiet, the layer told its picture
  let text_word = cursor_word(0.3, 0.3, shape="text")
  assert_false(screen_value_quiet(text_word))
  r.say(text_word)
  let (ibeam, _) = @sf.pointer_png_at(r.t.ctx().scale, shape="text")
  assert_true(pointer_told(r, st).contains("pointer \{ibeam} 20x20 hot=10,10"))
  assert_eq(pointer_told(r, st).last(), Some("pointer at 0.3 0.3"))
  // no pointer said: none
  r.say({ "cursor": Json::null() })
  assert_eq(r.sess().cursor(), None)
  screen_done(r.t)
}

///|
test "the station's pointer said alone where the app draws it: drawn where it says; under the trackpad's own pointer, quiet" {
  let r = screen_rig()
  r.state("live", control=false, others=[], more={
    "kind": Json::string("desktop"),
    "cursor": { "x": Json::number(0.5), "y": Json::number(0.5), "shape": Json::string("default") },
  })
  r.config()
  r.frame(1000.0)
  let was = drawn_pointer(r).unwrap()
  // drawn here: told what draws it (not quiet), moved there
  let moved = cursor_word(0.25, 0.5)
  assert_false(screen_value_quiet(moved))
  r.say(moved)
  let now = drawn_pointer(r).unwrap()
  assert_true(now.1 < was.1, msg="\{was.1} → \{now.1}")
  assert_eq(now.2, was.2)
  // driving it as a trackpad, its pointer moved: the station's word of its own pointer changes nothing drawn
  r.state("live", others=[], more={ "kind": Json::string("desktop") })
  let (ax, ay) = r.at(0.2, 0.5)
  let (bx, by) = r.at(0.4, 0.5)
  r.t.drag(ax, ay, bx, by)
  assert_true(r.ui().pad.placed)
  assert_true(screen_value_quiet(cursor_word(0.7, 0.2)))
  // its shape changed: not quiet
  assert_false(screen_value_quiet(cursor_word(0.7, 0.2, shape="text")))
  r.t.run_for(screen_double_tap_ms)
  screen_done(r.t)
}

///|
test "two fingers let go still moving: the scroll goes on by itself, dying away, as far as its pace says at any rate; stopped first, none" {
  let r = screen_rig()
  desktop_live(r)
  let u = r.ui()
  let (mx, my) = r.at(0.5, 0.6)
  let before = r.inputs().length()
  two_up(r, mx, my, 8, 20.0, finger_step_ms, 0.0)
  let let_go = r.inputs().length()
  assert_true(wheels_of(r.inputs()[before:let_go]).length() > 0)
  let from = u.fling.from
  let until = u.fling.until
  assert_true(until > from + 500.0, msg="\{from} → \{until}")
  // it goes on, each wheel up the page (the fingers went up: the page under them with them)
  r.t.run_for(until - r.t.time() + quick_again_ms)
  let after = wheels_of(r.inputs()[let_go:])
  assert_true(after.length() >= 2, msg="\{after.length()}")
  assert_true(after.iter().all(fn(j) { number(Some(j), "dy") > 0.0 && number(Some(j), "dx") == 0.0 }))
  // as far as its pace said: v·τ·(1 - e^(-(until - from)/τ)) in the frame's pixels, however many frames sent it
  let (_, gy) = u.fling.gone_at(until)
  let k = rig_w / u.shown(r.t.ctx()).w
  let sum = after.fold(init=0.0, fn(acc, j) { acc + number(Some(j), "dy") })
  assert_true((sum - -gy * k).abs() < 1.0e-6, msg="\{sum} vs \{-gy * k}")
  // dying away: its last less than its most
  let last = number(Some(after[after.length() - 1]), "dy")
  let most = after.fold(init=0.0, fn(acc, j) { dmax(acc, number(Some(j), "dy")) })
  assert_true(last < most)
  // over: nothing more
  let done = r.inputs().length()
  r.t.run_for(watch_after_ms)
  assert_eq(r.inputs().length(), done)
  // stopped before they let go: no scroll goes on
  r.t.run_for(screen_double_tap_ms)
  two_up(r, mx, my, 8, 20.0, finger_step_ms, still_before_ms)
  let still = r.inputs().length()
  r.t.run_for(watch_after_ms)
  assert_eq(wheels_of(r.inputs()[still:]).length(), 0)
  screen_done(r.t)
}

///|
test "a scroll going on by itself stops where it is as a finger goes down" {
  let r = screen_rig()
  desktop_live(r)
  let (mx, my) = r.at(0.5, 0.6)
  two_up(r, mx, my, 8, 20.0, finger_step_ms, 0.0)
  r.t.run_for(mid_fling_ms)
  let (px, py) = r.at(0.5, 0.5)
  r.t.press_at(px, py)
  let pressed = r.inputs().length()
  r.t.run_for(watch_after_ms)
  assert_eq(wheels_of(r.inputs()[pressed:]).length(), 0)
  r.t.release(px, py)
  r.t.run_for(screen_double_tap_ms)
  screen_done(r.t)
}

///|
///|
/// What is labelled `label` held a press's hold, then let go of.
fn ScreenRig::hold_label(self : ScreenRig, label : String) -> Unit {
  let (x, y) = self.labelled(label).unwrap()
  self.t.press_at(x, y)
  self.t.run_for(screen_hold_ms)
  self.t.release(x, y)
}

///|
test "左键 held holds it down: a finger on the trackpad drags with it, a tap lets it go; pressed twice quickly, a double click" {
  let r = screen_rig()
  desktop_live(r)
  let u = r.ui()
  let left = tr("android-misc.screen.key.mouseLeft")
  let from = r.inputs().length()
  r.hold_label(left)
  let held = r.inputs()[from:].to_owned()
  // down, held, nothing clicked as it is let go
  assert_eq(held.map(kind_of_input), ["down"])
  assert_eq(number(Some(held[0]), "buttons"), 1.0)
  assert_true(u.left_locked.untracked())
  assert_true(r.t.haptics().contains(@ui.LongPress))
  // (the foot's 左键 shown lit while held)
  assert_eq(pressed_of(r, left), Some(true))
  // a finger moved: the pointer goes with the button held
  r.t.run_for(screen_double_tap_ms)
  let (ax, ay) = r.at(0.2, 0.5)
  let (bx, by) = r.at(0.4, 0.5)
  let moved_from = r.inputs().length()
  r.t.drag(ax, ay, bx, by)
  let moves = r.inputs()[moved_from:].to_owned()
  assert_true(moves.length() > 0)
  assert_true(moves.iter().all(fn(j) { kind_of_input(j) == "move" && number(Some(j), "buttons") == 1.0 }))
  // a tap: let go where it points, nothing clicked
  r.t.run_for(screen_double_tap_ms)
  let tapped_from = r.inputs().length()
  r.tap_at(0.5, 0.5)
  let tapped = r.inputs()[tapped_from:].to_owned()
  assert_eq(tapped.map(kind_of_input), ["up"])
  assert_false(u.left_locked.untracked())
  assert_eq(pressed_of(r, left), Some(false))
  // pressed twice quickly: two clicks there (a double click), nothing held
  r.t.run_for(screen_double_tap_ms)
  let again = r.inputs().length()
  r.tap_label(left)
  r.t.run_for(quick_again_ms)
  r.tap_label(left)
  assert_eq(r.inputs()[again:].to_owned().map(kind_of_input), ["down", "up", "down", "up"])
  assert_false(u.left_locked.untracked())
  // held, then pressed: let go of, nothing clicked
  r.hold_label(left)
  assert_true(u.left_locked.untracked())
  let pressed = r.inputs().length()
  r.tap_label(left)
  assert_eq(r.inputs()[pressed:].to_owned().map(kind_of_input), ["up"])
  assert_false(u.left_locked.untracked())
  r.t.run_for(screen_double_tap_ms)
  screen_done(r.t)
}

///|
test "左键 held down driving it directly: a drag moves with it and leaves it held, a tap lets it go; only looking lets it go" {
  let r = screen_rig(touch="direct")
  r.live(others=[])
  let s = r.sess()
  let u = r.ui()
  r.tap_at(0.25, 0.75)
  r.t.run_for(screen_double_tap_ms)
  let from = r.inputs().length()
  left_hold(s, u)
  r.t.draw()
  assert_true(u.left_locked.untracked())
  let down = r.inputs()[from:].to_owned()
  assert_eq(down.map(kind_of_input), ["down"])
  assert_true(close_to(number(Some(down[0]), "x"), 0.25))
  // a drag: moves with the button held, no other down nor up
  let (ax, ay) = r.at(0.2, 0.5)
  let (bx, by) = r.at(0.6, 0.5)
  let drag_from = r.inputs().length()
  r.t.drag(ax, ay, bx, by)
  let drag = r.inputs()[drag_from:].to_owned()
  assert_true(drag.length() > 0)
  assert_true(drag.iter().all(fn(j) { kind_of_input(j) == "move" && number(Some(j), "buttons") == 1.0 }))
  assert_true(u.left_locked.untracked())
  // a tap: up there
  r.t.run_for(screen_double_tap_ms)
  let tap_from = r.inputs().length()
  r.tap_at(0.7, 0.4)
  let up = r.inputs()[tap_from:].to_owned()
  assert_eq(up.map(kind_of_input), ["up"])
  assert_true(close_to(number(Some(up[0]), "x"), 0.7))
  assert_false(u.left_locked.untracked())
  // held again, then the view only looks: let go of (its up sent as it stopped driving, nothing held after)
  r.t.run_for(ripple_ms + screen_double_tap_ms)
  left_hold(s, u)
  r.t.draw()
  assert_true(u.left_locked.untracked())
  r.state("live", control=false, others=[])
  assert_false(u.left_locked.untracked())
  screen_done(r.t)
}

///|
test "driving it directly a finger slides a little before it drags: 10 dp is still a tap, 20 dp a drag" {
  let r = screen_rig(touch="direct")
  r.live(others=[])
  let (ax, ay) = r.at(0.3, 0.5)
  let from = r.inputs().length()
  r.t.press_at(ax, ay)
  r.t.move_to(ax + 10.0, ay)
  r.t.release(ax + 10.0, ay)
  let tap = r.inputs()[from:].to_owned()
  assert_eq(tap.map(kind_of_input), ["down", "up"])
  assert_true(close_to(number(Some(tap[0]), "x"), 0.3))
  r.t.run_for(screen_double_tap_ms)
  let drag_from = r.inputs().length()
  r.t.press_at(ax, ay)
  r.t.move_to(ax + 20.0, ay)
  r.t.release(ax + 20.0, ay)
  let drag = r.inputs()[drag_from:].to_owned()
  assert_eq(drag.map(kind_of_input), ["down", "move", "up"])
  screen_done(r.t)
}

///|
test "where a tap driving it directly clicked is shown under the finger a moment, then nothing is asked of a frame" {
  let r = screen_rig(touch="direct")
  r.live(others=[])
  let u = r.ui()
  assert_true(u.ripple.untracked() is None)
  let (ax, ay) = r.at(0.25, 0.75)
  r.t.tap(ax, ay)
  match u.ripple.untracked() {
    Some((x, y, _)) => {
      let (sx, sy) = u.stage_xy()
      assert_true((x + sx - ax).abs() < 0.01 && (y + sy - ay).abs() < 0.01)
    }
    None => @halt.saying("no ripple")
  }
  r.t.run_for(ripple_ms)
  r.t.assert_idle()
  // only looking: none
  r.state("live", control=false, others=[])
  r.t.run_for(screen_double_tap_ms)
  let was = u.ripple.untracked()
  let (bx, by) = r.at(0.5, 0.5)
  r.t.tap(bx, by)
  assert_eq(u.ripple.untracked(), was)
  r.t.run_for(screen_double_tap_ms)
  screen_done(r.t)
}

///|
test "the trackpad's gain: steady while slow, rising smoothly, at most 2.75" {
  assert_eq(pad_gain(0.0), 0.42)
  assert_eq(pad_gain(0.08), 0.42)
  assert_true(close_to(pad_gain(0.9), 1.75))
  assert_true(close_to(pad_gain(2.1), 2.75))
  assert_eq(pad_gain(10.0), 2.75)
  let mut was = pad_gain(0.0)
  for i in 1..=300 {
    let g = pad_gain(i.to_double() * 0.01)
    assert_true(g >= was)
    // (no step anywhere: each 0.01 dp/ms raises it by little)
    assert_true(g - was < 0.05, msg="\{i}: \{was} → \{g}")
    was = g
  }
  // smoothed: a sample's own pace counts by how long it took
  assert_eq(pad_speed(None, 2.0, 4.0), 0.5)
  let one = pad_speed(Some(0.0), 4.0, 8.0)
  let two = pad_speed(pad_speed(Some(0.0), 2.0, 4.0) |> Some, 2.0, 4.0)
  assert_true((one - two).abs() < 1.0e-12, msg="\{one} vs \{two}")
}

///|
test "左键 held, dragged with a finger on the trackpad, then pressed: let go where the drag got to, no button held after" {
  let r = screen_rig()
  desktop_live(r)
  let u = r.ui()
  let left = tr("android-misc.screen.key.mouseLeft")
  r.hold_label(left)
  assert_true(u.left_locked.untracked())
  let held = pointers_of(r)
  let down = held[held.length() - 1]
  assert_eq(kind_of_input(down), "down")
  r.t.run_for(screen_double_tap_ms)
  let (ax, ay) = r.at(0.2, 0.5)
  let (bx, by) = r.at(0.4, 0.6)
  r.t.drag(ax, ay, bx, by)
  let (px, py) = u.pad.at()
  assert_true(px > number(Some(down), "x") && py > number(Some(down), "y"), msg="\{px}, \{py}")
  // 左键 pressed: up there, buttons none
  r.t.run_for(screen_double_tap_ms)
  let from = r.inputs().length()
  r.tap_label(left)
  let up = r.inputs()[from:].to_owned()
  assert_eq(up.map(kind_of_input), ["up"])
  assert_eq(number(Some(up[0]), "x"), px)
  assert_eq(number(Some(up[0]), "y"), py)
  assert_eq(number(Some(up[0]), "buttons"), 0.0)
  assert_false(u.left_locked.untracked())
  r.t.run_for(screen_double_tap_ms)
  screen_done(r.t)
}

///|
test "左键 held, dragged with a finger driving it directly, then pressed: let go where the drag ended, no button held after" {
  let r = screen_rig(touch="direct")
  r.live(others=[])
  let s = r.sess()
  let u = r.ui()
  r.tap_at(0.5, 0.5)
  r.t.run_for(ripple_ms + screen_double_tap_ms)
  left_hold(s, u)
  r.t.draw()
  let (ax, ay) = r.at(0.2, 0.4)
  let (bx, by) = r.at(0.7, 0.6)
  r.t.drag(ax, ay, bx, by)
  let moves = pointers_of(r).filter(fn(j) { kind_of_input(j) == "move" })
  let last = moves[moves.length() - 1]
  assert_true(close_to(number(Some(last), "x"), 0.7) && close_to(number(Some(last), "y"), 0.6))
  r.t.run_for(screen_double_tap_ms)
  let from = r.inputs().length()
  button_clicked(s, u, btn_primary)
  r.t.draw()
  let up = r.inputs()[from:].to_owned()
  assert_eq(up.map(kind_of_input), ["up"])
  assert_eq(number(Some(up[0]), "x"), number(Some(last), "x"))
  assert_eq(number(Some(up[0]), "y"), number(Some(last), "y"))
  assert_eq(number(Some(up[0]), "buttons"), 0.0)
  assert_false(u.left_locked.untracked())
  screen_done(r.t)
}

///|
test "全屏 sideways, 左键 floating held: read out pressed while held, let go of as it is pressed again" {
  let r = screen_rig()
  desktop_live(r)
  let u = r.ui()
  r.t.resize(844.0, 390.0)
  r.t.draw()
  let left = tr("android-misc.screen.key.mouseLeft")
  assert_eq(pressed_of(r, left), Some(false))
  r.hold_label(left)
  assert_true(u.left_locked.untracked())
  assert_eq(pressed_of(r, left), Some(true))
  let from = r.inputs().length()
  r.tap_label(left)
  assert_eq(r.inputs()[from:].to_owned().map(kind_of_input), ["up"])
  assert_eq(pressed_of(r, left), Some(false))
  screen_done(r.t)
}
