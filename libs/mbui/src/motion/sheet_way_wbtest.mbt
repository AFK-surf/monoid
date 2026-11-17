// A sheet up from the window's foot (sheet_way.mbt), in a window 400 by 800: a sheet 400 tall resting at its foot (its
// top at 400 all the way up), its handle the top 56 of it, over a button filling the window. Each look is at a declared
// moment after its cause, the same at every rate of frames.

///|
/// The window, the sheet and its handle (points).
let sheet_win_w : Double = 400.0

///|
let sheet_win_h : Double = 800.0

///|
let sheet_tall : Double = 400.0

///|
/// Where the sheet's top rests all the way up.
let sheet_top : Double = 400.0

///|
let sheet_ink : Int64 = 0xFFFFFFFFL

///|
let under_ink : Int64 = 0xEEEEEEFFL

///|
/// How long the tests look on after a cause for what it set going to be over (a spring's way is well under it).
let sheet_settled_ms : Double = 1500.0

///|
/// A moment while it slides down, put away (under its leave_ms; a fifth of the way down its span, still on the window).
let sheet_leaving_ms : Double = 40.0

///|
/// A moment while it comes up (its spring's way about half gone).
let sheet_coming_ms : Double = 100.0

///|
/// A sheet's run: its Tester, its way, whether it is up, and how often the button under it, its handle's tap and its
/// close were said.
priv struct SheetRig {
  t : @ui.Tester
  way : SheetWay
  open : @signals.Signal[Bool]
  unders : Ref[Int]
  taps : Ref[Int]
  closes : Ref[Int]
}

///|
fn sheet_rig(detents? : Array[Double] = [0.0], opens_at? : Int = 0) -> SheetRig {
  let t = @ui.Tester::new(fn(_c) {  }, w=sheet_win_w, h=sheet_win_h)
  t.check_looks(false)
  let open = @signals.signal(false)
  let way = SheetWay::new(detents~, opens_at~)
  let unders = Ref(0)
  let taps = Ref(0)
  let closes = Ref(0)
  let close = fn() {
    closes.val += 1
    open.set(false)
  }
  @ui.set_view_app(fn(root) {
    root.box(fn(under) {
      under
      .grow(Is(1.0))
      .ground(Is(under_ink))
      .says(Is(Some(@view.said(Button, label="Under"))))
      .on_press(fn() { unders.val += 1 })
      |> ignore
    })
    |> ignore
    way.show_in(root, open=fn() { open.get() }, close~, scrim=fn(a) { (a * 102.0).to_int64() }, fn(s) {
      s.height(Is(Some(sheet_tall))).ground(Is(sheet_ink)) |> ignore
      s.box(fn(h) {
        h.height(Is(Some(56.0))).ground(Is(0xDDDDDDFFL)) |> ignore
        way.attach_handle(h, span=fn() { h.window().1 }, close~, on_tap=fn() { taps.val += 1 })
      })
      |> ignore
    })
  })
  t.draw()
  { t, way, open, unders, taps, closes }
}

///|
/// Where the sheet's top is drawn now (none drawn: -1).
fn SheetRig::sheet_y(self : SheetRig) -> Double {
  match
    self.t
    .drawn_rects()
    .filter(fn(r) { r.4 == sheet_ink && r.2 == sheet_win_w && r.3 == sheet_tall })
    .get(0) {
    Some(r) => r.1
    None => -1.0
  }
}

///|
/// Put up at the test's moment (its cause's), and let rest there.
fn SheetRig::up(self : SheetRig) -> Unit {
  let tree = @ui.view_tree().unwrap()
  tree.event(self.t.time(), fn() { self.open.set(true) })
  self.t.run_for(sheet_settled_ms)
}

///|
test "a sheet comes up by its spring from its cause's moment, drawn where its way has it then; at rest at its foot" {
  let r = sheet_rig()
  let down_y = r.sheet_y()
  let tree = @ui.view_tree().unwrap()
  let t0 = r.t.time()
  tree.event(t0, fn() { r.open.set(true) })
  r.t.run_for(sheet_coming_ms)
  let at = r.t.time()
  let (rise, v) = r.way.at(at)
  let mid_y = r.sheet_y()
  r.t.run_for(sheet_settled_ms)
  assert_eq(
    (
      down_y,
      rise > 0.0 && rise < 1.0 && v < 0.0,
      (mid_y - (sheet_top + rise * sheet_win_h)).abs() < 0.01,
      r.sheet_y(),
      r.way.target(),
    ),
    (-1.0, true, true, sheet_top, 0.0),
  )
}

///|
test "a finger on its handle takes it one to one, and past the top holds it back as a rubber band" {
  let r = sheet_rig()
  r.up()
  // (down at 420 in steps of 10: past the slop at 430, where it begins; 190 down at 620)
  r.t.hold_drag(200.0, 420.0, 200.0, 620.0, steps=20)
  let at_620 = (r.way.target(), r.sheet_y())
  r.t.hold_move(200.0, 660.0)
  let at_660 = (r.way.target(), r.sheet_y())
  // (200 over where it began: held back to rubber_band(-200, 800) ≈ -96.7)
  r.t.hold_move(200.0, 230.0)
  let past = (r.way.target(), r.sheet_y())
  r.t.release(200.0, 230.0)
  r.t.run_for(sheet_settled_ms)
  assert_eq(
    (
      at_620.0 == 190.0 / sheet_win_h,
      at_620.1 == sheet_top + 190.0,
      at_660.0 == 230.0 / sheet_win_h,
      at_660.1 == sheet_top + 230.0,
      past.0 == -200.0 / sheet_win_h,
      (past.1 - (sheet_top + rubber_band(-200.0, sheet_win_h))).abs() < 0.001,
      past.1 > sheet_top - 200.0,
      r.sheet_y(),
      r.closes.val,
    ),
    (true, true, true, true, true, true, true, sheet_top, 0),
  )
}

///|
test "let go slowly not far down, it goes back up, from where the finger left it as fast as the finger went" {
  let r = sheet_rig()
  r.up()
  // (120 down over a second: 0.15 of the window, 0.15 a second, landing at 0.22 or so: short of a third)
  r.t.hold_drag(200.0, 420.0, 200.0, 540.0, steps=60)
  let held = r.way.target()
  r.t.release(200.0, 540.0)
  let (x, v) = r.way.at(r.t.time())
  let went = r.way.target()
  r.t.run_for(sheet_settled_ms)
  assert_eq(
    (x == held, held > 0.1, v > 0.0 && v < 0.5, went, r.closes.val, r.open.get(), r.sheet_y()),
    (true, true, true, 0.0, 0, true, sheet_top),
  )
}

///|
test "flung down it is put away at the finger's speed, its way going on from where and as fast as the finger let it go" {
  let r = sheet_rig()
  r.up()
  // (140 down in 5 moves, 83 ms: about 2 of the window a second, landing past it)
  r.t.hold_drag(200.0, 420.0, 200.0, 560.0, steps=5)
  let held = r.way.target()
  r.t.release(200.0, 560.0)
  let let_go = r.t.time()
  let (x, v) = r.way.at(let_go)
  let (x1, _) = r.way.at(let_go + 1.0)
  // (no jump: a ms on, about v / 1000 further)
  let smooth = (x1 - x - v / 1000.0).abs() < 0.001
  assert_eq(
    (x == held, v > 1.0, smooth, r.way.target(), r.closes.val, r.open.get()),
    (true, true, true, 1.0, 1, false),
  )
}

///|
test "a tap on its handle is the handle's own: the sheet stays up" {
  let r = sheet_rig()
  r.up()
  r.t.tap(200.0, 420.0)
  r.t.run_for(sheet_settled_ms)
  assert_eq((r.taps.val, r.closes.val, r.open.get(), r.sheet_y()), (1, 0, true, sheet_top))
}

///|
test "put away by a press on the scrim, what is under it takes a press while it still slides down" {
  let r = sheet_rig()
  r.up()
  // (over the scrim: the sheet's to put away, not the button's under it)
  r.t.tap(200.0, 100.0)
  let after_scrim = (r.closes.val, r.unders.val)
  r.t.run_for(sheet_leaving_ms)
  let y = r.sheet_y()
  let tree = @ui.view_tree().unwrap()
  r.t.tap(200.0, 100.0)
  r.t.run_for(sheet_settled_ms)
  assert_eq(
    (after_scrim, y > sheet_top && y < sheet_win_h, tree.modal_top() is None, r.unders.val, r.closes.val, r.sheet_y()),
    ((1, 0), true, true, 1, 1, -1.0),
  )
}

///|
test "put away by Escape or back, from that moment what is under it takes presses as it slides down" {
  let r = sheet_rig()
  r.up()
  r.t.key(@ui.key_escape)
  let by_escape = (r.closes.val, r.open.get())
  r.t.run_for(sheet_leaving_ms)
  r.t.tap(200.0, 300.0)
  let pressed_leaving = r.unders.val
  r.t.run_for(sheet_settled_ms)
  r.up()
  r.t.back()
  let by_back = (r.closes.val, r.open.get())
  r.t.run_for(sheet_leaving_ms)
  let y = r.sheet_y()
  r.t.tap(200.0, 300.0)
  assert_eq(
    (by_escape, pressed_leaving, by_back, y > sheet_top && y < sheet_win_h, r.unders.val),
    ((1, false), 1, (2, false), true, 2),
  )
}

///|
test "detents: up to the one it opens at; flung up, to the top; let go nearer the middle, rests there" {
  // (all the way up, or a quarter of the window lower: its top at 400 or 600; put away past halfway)
  let r = sheet_rig(detents=[0.25, 0.0], opens_at=1)
  r.up()
  let opened = (r.way.target(), r.sheet_y())
  // (flung up from the middle's handle: 100 up in 5 moves)
  r.t.hold_drag(200.0, 620.0, 200.0, 520.0, steps=5)
  r.t.release(200.0, 520.0)
  let flung = r.way.target()
  r.t.run_for(sheet_settled_ms)
  let up_y = r.sheet_y()
  // (120 down slowly from the top: nearer the middle where it lands)
  r.t.hold_drag(200.0, 420.0, 200.0, 540.0, steps=60)
  r.t.release(200.0, 540.0)
  let slow = r.way.target()
  r.t.run_for(sheet_settled_ms)
  assert_eq(
    (opened, flung, up_y, slow, r.sheet_y(), r.closes.val),
    ((0.25, sheet_top + 200.0), 0.0, sheet_top, 0.25, sheet_top + 200.0, 0),
  )
}
