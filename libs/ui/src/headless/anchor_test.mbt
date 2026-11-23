// Where what floats goes beside what opened it (@headless.anchor_place) and how fast a list scrolls by itself near its
// edge under a drag (@headless.edge_scroll_speed): numbers alone, no window.

///|
test "below its opener where it fits; above where it does not and there is more room there; along the side by Start, Center and End" {
  let view = (400.0, 300.0)
  let fits = @headless.anchor_place((100.0, 40.0, 80.0, 30.0), (120.0, 100.0), view, gap=4.0)
  let flips = @headless.anchor_place((100.0, 220.0, 80.0, 30.0), (120.0, 100.0), view, gap=4.0)
  let center = @headless.anchor_place(
    (100.0, 40.0, 80.0, 30.0),
    (120.0, 100.0),
    view,
    placement=BelowCenter,
  )
  let end = @headless.anchor_place((100.0, 40.0, 80.0, 30.0), (120.0, 100.0), view, placement=BelowEnd)
  assert_eq(
    (fits, flips, (center.x, center.y), (end.x, end.y)),
    (
      @headless.AnchorPlaced::{ x: 100.0, y: 74.0, side: Below, flipped: false, room: 226.0 },
      @headless.AnchorPlaced::{ x: 100.0, y: 116.0, side: Above, flipped: true, room: 216.0 },
      (80.0, 70.0),
      (60.0, 70.0),
    ),
  )
}

///|
test "it stays on the side asked where the other has no more room, moved into the safe area on both axes; bigger than it, at its start" {
  let view = (400.0, 300.0)
  let insets = (20.0, 10.0, 30.0, 10.0)
  // under an opener at the middle, 200 tall: neither side has room, below has more: kept below, moved up
  let kept = @headless.anchor_place((300.0, 120.0, 80.0, 20.0), (150.0, 200.0), view, insets~)
  // above asked near the top: flipped below; past the right edge: moved in
  let above = @headless.anchor_place(
    (350.0, 30.0, 40.0, 20.0),
    (100.0, 60.0),
    view,
    placement=AboveStart,
    insets~,
  )
  // taller than the safe area: at its top
  let tall = @headless.anchor_place((10.0, 10.0, 10.0, 10.0), (50.0, 400.0), view, insets~)
  assert_eq(
    (kept, above, (tall.x, tall.y)),
    (
      @headless.AnchorPlaced::{ x: 240.0, y: 70.0, side: Below, flipped: false, room: 130.0 },
      @headless.AnchorPlaced::{ x: 290.0, y: 50.0, side: Below, flipped: true, room: 220.0 },
      (10.0, 20.0),
    ),
  )
}

///|
test "a submenu right of its item flips left at the window's right edge, and the key back is the arrow toward its item" {
  let view = (400.0, 300.0)
  let right = @headless.anchor_place((100.0, 50.0, 120.0, 28.0), (140.0, 90.0), view, placement=RightStart)
  let left = @headless.anchor_place((260.0, 50.0, 120.0, 28.0), (140.0, 90.0), view, placement=RightStart)
  let up = @headless.anchor_place((260.0, 250.0, 120.0, 28.0), (140.0, 90.0), view, placement=RightEnd)
  assert_eq(
    (right, left, (up.x, up.y), right.side.back_key(), left.side.back_key(), @headless.Placement::RightEnd.side()),
    (
      @headless.AnchorPlaced::{ x: 220.0, y: 50.0, side: Right, flipped: false, room: 180.0 },
      @headless.AnchorPlaced::{ x: 120.0, y: 50.0, side: Left, flipped: true, room: 260.0 },
      (120.0, 188.0),
      @ui.key_code_left,
      @ui.key_code_right,
      @headless.AnchorSide::Right,
    ),
  )
}

///|
test "the speed near a list's edge: 0 outside the zones, from 0 as a zone is entered growing as a square to the most at the edge and past it, toward the start below 0; steady and growing all the way" {
  let speed = fn(pos : Double) { @headless.edge_scroll_speed(pos, 100.0, 500.0, zone=40.0, max_speed=2.0) }
  assert_eq(
    (speed(300.0), speed(140.0), speed(120.0), speed(100.0), speed(50.0), speed(460.0), speed(480.0), speed(600.0)),
    (0.0, 0.0, -0.5, -2.0, -2.0, 0.0, 0.5, 2.0),
  )
  // from far above to far below, at each half point: never falling, and no step larger than a zone's square allows
  let mut pos = 0.0
  let mut last = speed(pos)
  let mut steady = true
  while pos < 600.0 {
    pos = pos + 0.5
    let now = speed(pos)
    if now < last || now - last > 2.0 * 2.0 * 0.5 / 40.0 + 1.0e-9 {
      steady = false
    }
    last = now
  }
  // a zone wider than half the list is half of it; nothing, or no zone, no speed
  let narrow = @headless.edge_scroll_speed(150.0, 100.0, 200.0, zone=80.0, max_speed=1.0)
  let none = @headless.edge_scroll_speed(150.0, 100.0, 100.0, zone=10.0, max_speed=1.0)
  assert_eq((steady, narrow, none), (true, 0.0, 0.0))
}
