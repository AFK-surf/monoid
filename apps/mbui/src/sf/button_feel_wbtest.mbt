// The button's feel and its three states (button_node): pressed, a step deeper and sunk, back exactly as it was at
// rest; at work then done, the tick where the spinner turned, its words where they were with an icon.

///|
/// Moments the tests here look at: the hand's step whole, a press whole, a way's middle, past every way.
let hand_whole_ms : Double = 400.0

///|
let press_whole_ms : Double = 200.0

///|
let feel_mid_ms : Double = 60.0

///|
let feel_past_ms : Double = 2000.0

///|
/// A button in a column at the window's top left, `busy` and `done` as they are, `icon` its icon.
fn feel_case(busy : @signals.Signal[Bool], done : @signals.Signal[Bool], icon? : String = "") -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(300.0))).height(Is(Some(200.0))).lines_up(Is(Some(Start))) |> ignore
      button_node(col, fn() { "发布" }, fn() {  }, tone=Primary, icon~, busy=fn() { busy.get() }, done=fn() { done.get() }) |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "a button pressed by a click under the pointer: a step deeper than lit, drawn a little smaller; let go, exactly as it was" {
  @ui.set_pointing(Some(Mouse))
  let t = feel_case(@signals.signal(false), @signals.signal(false))
  let rest = button_drawn(t)
  let rest_ground = t.drawn_rects()[0].4
  let (x, y) = t.find("发布").unwrap()
  t.move_to(x, y)
  t.run_for(hand_whole_ms)
  let lit = t.drawn_rects()[0].4
  let lit_rects = button_drawn(t)
  t.press_at(x, y)
  t.run_for(press_whole_ms)
  let pressed = t.drawn_rects()[0]
  t.release(x, y)
  t.move_to(390.0, 290.0)
  t.run_for(feel_past_ms)
  @ui.set_pointing(None)
  assert_eq(
    (lit != rest_ground, lit_rects == rest, pressed.4 != lit, pressed.2 < rest.0[0].2, button_drawn(t) == rest, t.drawn_rects()[0].4),
    (true, true, true, true, true, rest_ground),
  )
}

///|
test "a button at work then done with an icon: the spinner and the tick in the icon's place, its words not moved" {
  let busy = @signals.signal(false)
  let done = @signals.signal(false)
  let t = feel_case(busy, done, icon="share")
  let words_at = fn() { t.find("发布").unwrap_or((-1.0, -1.0)) }
  let rest = words_at()
  busy.set(true)
  t.frame()
  t.run_for(feel_mid_ms)
  let going = words_at()
  t.run_for(feel_past_ms)
  let working = (words_at(), t.drawn_instances().any(fn(i) { i[5] == 10.0 }))
  busy.set(false)
  done.set(true)
  t.frame()
  t.run_for(feel_past_ms)
  let done_at = (words_at(), t.drawn_instances().any(fn(i) { i[5] == 10.0 }), @ui.view_tree().unwrap().cycle_read())
  assert_eq((going, working, done_at), (rest, (rest, true), (rest, true, false)))
}

///|
test "a button done without an icon: its room kept open from at work to done, closed once neither" {
  let busy = @signals.signal(false)
  let done = @signals.signal(false)
  let t = feel_case(busy, done)
  let rest = button_drawn(t)
  busy.set(true)
  t.frame()
  t.run_for(feel_past_ms)
  let working = button_drawn(t)
  busy.set(false)
  done.set(true)
  t.frame()
  t.run_for(feel_past_ms)
  let done_now = button_drawn(t)
  done.set(false)
  t.frame()
  t.run_for(feel_past_ms)
  assert_eq((working.0 == done_now.0, working.0 != rest.0, button_drawn(t) == rest), (true, true, true))
}
