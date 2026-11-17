// A page pushed from the right (stack_way.mbt), in a window 400 by 800: a page filling it pushed over a button filling
// it, its Back button the top 60 of it. Each look is at a declared moment after its cause, the same at every rate of
// frames.

///|
let push_win_w : Double = 400.0

///|
let push_win_h : Double = 800.0

///|
let page_ink : Int64 = 0xFFFFFFFFL

///|
let pushed_under_ink : Int64 = 0xEEEEEEFFL

///|
/// How long the tests look on after a cause for what it set going to be over (a spring's way is well under it).
let push_settled_ms : Double = 1500.0

///|
/// A moment while it slides away, taken off (under its leave_ms).
let push_leaving_ms : Double = 100.0

///|
/// A moment while it is pushed (its spring's way about half gone).
let push_coming_ms : Double = 100.0

///|
/// How long a finger is held still before it is let go: long enough that it is let go at no speed.
let held_still_ms : Double = 200.0

///|
/// A pushed page's run: its Tester, its way, whether it is pushed, and how often the button under it, its Back and its
/// close were said.
priv struct PushRig {
  t : @ui.Tester
  way : PushWay
  open : @signals.Signal[Bool]
  unders : Ref[Int]
  closes : Ref[Int]
}

///|
fn push_rig() -> PushRig {
  let t = @ui.Tester::new(fn(_c) {  }, w=push_win_w, h=push_win_h)
  t.check_looks(false)
  let open = @signals.signal(false)
  let way = PushWay::new()
  let unders = Ref(0)
  let closes = Ref(0)
  let close = fn() {
    closes.val += 1
    open.set(false)
  }
  @ui.set_view_app(fn(root) {
    root.box(fn(under) {
      under
      .grow(Is(1.0))
      .ground(Is(pushed_under_ink))
      .says(Is(Some(@view.said(Button, label="Under"))))
      .on_press(fn() { unders.val += 1 })
      |> ignore
      way.under_pushed(under)
    })
    |> ignore
    way.show_in(root, open=fn() { open.get() }, close~, scrim=fn(a) { (a * 41.0).to_int64() }, edge_top=60.0, fn(p) {
      p.ground(Is(page_ink)) |> ignore
      p.box(fn(b) {
        b
        .height(Is(Some(60.0)))
        .ground(Is(0xDDDDDDFFL))
        .says(Is(Some(@view.said(Button, label="Back"))))
        .on_press(close)
        |> ignore
      })
      |> ignore
    })
  })
  t.draw()
  { t, way, open, unders, closes }
}

///|
/// Where the page's left edge and what it is pushed over's are drawn now (none drawn: -1000).
fn PushRig::drawn_x(self : PushRig) -> (Double, Double) {
  let rects = self.t.drawn_rects()
  let x_of = fn(ink : Int64) {
    match rects.filter(fn(r) { r.4 == ink && r.2 == push_win_w && r.3 == push_win_h }).get(0) {
      Some(r) => r.0
      None => -1000.0
    }
  }
  (x_of(page_ink), x_of(pushed_under_ink))
}

///|
/// Where a press lands on both the page as it is drawn now and what it is pushed over (midway between the page's left
/// edge and that one's right edge), and whether there is such a place.
fn PushRig::on_both(self : PushRig) -> (Double, Bool) {
  let (page_x, under_x) = self.drawn_x()
  let right = under_x + push_win_w
  let x = (page_x + right) / 2.0
  (x, page_x > 0.0 && page_x < x && x < right)
}

///|
/// Pushed at the test's moment (its cause's), and let rest there.
fn PushRig::push(self : PushRig) -> Unit {
  let tree = @ui.view_tree().unwrap()
  tree.event(self.t.time(), fn() { self.open.set(true) })
  self.t.run_for(push_settled_ms)
}

///|
test "a page is pushed by its spring from its cause's moment, what is under it drawn a third of the way left with it; covered, not drawn" {
  let r = push_rig()
  let before = r.drawn_x()
  let tree = @ui.view_tree().unwrap()
  tree.event(r.t.time(), fn() { r.open.set(true) })
  r.t.run_for(push_coming_ms)
  let (s, v) = r.way.at(r.t.time())
  let (page_x, under_x) = r.drawn_x()
  r.t.run_for(push_settled_ms)
  assert_eq(
    (
      before,
      s > 0.0 && s < 1.0 && v < 0.0,
      (page_x - push_win_w * s).abs() < 0.01,
      (under_x - -0.3 * push_win_w * (1.0 - s)).abs() < 0.01,
      r.drawn_x(),
      r.way.target(),
    ),
    ((-1000.0, 0.0), true, true, true, (0.0, -1000.0), 0.0),
  )
}

///|
test "taken off by back, what is under it takes a press from that moment, the page still sliding away over it" {
  let r = push_rig()
  r.push()
  r.t.back()
  let by_back = (r.closes.val, r.open.get())
  r.t.run_for(push_leaving_ms)
  let (x, both) = r.on_both()
  // (on the page as it is drawn then, and on its Back: both what is under it's now)
  r.t.tap(x, 400.0)
  r.t.tap(x, 30.0)
  r.t.run_for(push_settled_ms)
  assert_eq(
    (by_back, both, r.unders.val, r.closes.val, r.drawn_x()),
    ((1, false), true, 2, 1, (-1000.0, 0.0)),
  )
}

///|
test "taken off by its own Back button, what is under it takes a press while it slides away" {
  let r = push_rig()
  r.push()
  r.t.tap(200.0, 30.0)
  let by_button = (r.closes.val, r.open.get(), r.unders.val)
  r.t.run_for(push_leaving_ms)
  let (x, both) = r.on_both()
  r.t.tap(x, 400.0)
  assert_eq((by_button, both, r.unders.val), ((1, false, 0), true, 1))
}

///|
test "a finger from the left edge takes it one to one; let go slowly short of halfway, back over as fast as it went" {
  let r = push_rig()
  r.push()
  // (down at 5 in steps of 10: past the slop at 15, where it begins; 90 across at 105)
  r.t.hold_drag(5.0, 400.0, 105.0, 400.0, steps=10)
  let at_105 = (r.way.target(), r.drawn_x().0)
  r.t.hold_move(145.0, 400.0)
  let at_145 = (r.way.target(), r.drawn_x().0)
  // (held still a while: let go of at no speed, short of halfway, back over)
  r.t.run_for(held_still_ms)
  r.t.release(145.0, 400.0)
  r.t.run_for(push_settled_ms)
  let back_still = (r.way.target(), r.closes.val)
  // (70 across over 0.7 s: 0.25 of the width a second, landing short of halfway)
  r.t.hold_drag(5.0, 400.0, 85.0, 400.0, steps=40)
  let held = r.way.target()
  r.t.release(85.0, 400.0)
  let (x, v) = r.way.at(r.t.time())
  let went = r.way.target()
  r.t.run_for(push_settled_ms)
  assert_eq(
    (
      at_105,
      at_145,
      back_still,
      x == held,
      held > 0.1 && held < 0.3,
      v > 0.0 && v < 0.5,
      went,
      r.closes.val,
      r.open.get(),
      r.drawn_x(),
    ),
    ((90.0 / push_win_w, 90.0), (130.0 / push_win_w, 130.0), (0.0, 0), true, true, true, 0.0, 0, true, (0.0, -1000.0)),
  )
}

///|
test "swiped off fast, it goes at the finger's speed from where it was let go, and what is under it takes a press at once" {
  let r = push_rig()
  r.push()
  // (200 across in 6 moves, 100 ms: 5 of the width a second)
  r.t.hold_drag(5.0, 400.0, 205.0, 400.0, steps=6)
  let held = r.way.target()
  r.t.release(205.0, 400.0)
  let let_go = r.t.time()
  let (x, v) = r.way.at(let_go)
  let (x1, _) = r.way.at(let_go + 1.0)
  let smooth = (x1 - x - v / 1000.0).abs() < 0.001
  // (the first frame after: a press on the page as it is drawn is what is under it's)
  let (at, both) = r.on_both()
  r.t.tap(at, 400.0)
  assert_eq(
    (x == held, v > 1.0, smooth, r.way.target(), r.closes.val, r.open.get(), both, r.unders.val),
    (true, true, true, 1.0, 1, false, true, 1),
  )
}
