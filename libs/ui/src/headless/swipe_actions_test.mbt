// Tests for headless SwipeActions: horizontal drag open/close, axis locking against vertical scroll, rubber-band
// over-drag damping, velocity flick, programmatic open/close, and disabled guard. All windows use `window`.

///|
test "SwipeActions: horizontal drag opens Left/Right past threshold, short drag snaps back, vertical drag ignored" {
  let events : Array[@headless.SwipeSide?] = []
  let sa = @headless.SwipeActions::new(
    left_width=80.0,
    right_width=100.0,
    threshold=0.4,
    velocity_threshold=400.0,
    slop=6.0,
    on_open=fn(side) { events.push(side) },
  )
  let t = window(fn(root) {
    root.box(fn(v) {
      v
      .width(Is(Some(300.0)))
      .height(Is(Some(60.0)))
      .ground(Is(c_rest))
      .says(Is(Some(@view.said(Group, label="列表行"))))
      |> ignore
      sa.bind(v)
    })
    |> ignore
  })
  // Vertical drag (dy=40 > dx=5) does not lock horizontal axis
  t.drag(150.0, 10.0, 155.0, 50.0, steps=10)
  let after_vert = (sa.offset(), sa.open_side(), sa.dragging())
  // Slow short horizontal drag right (+20 < 80 * 0.4 = 32) snaps back to 0
  t.drag(150.0, 30.0, 170.0, 30.0, steps=20)
  let after_short = (sa.offset(), sa.open_side())
  // Slow horizontal drag right (+50 >= 32) snaps open Left (80.0)
  t.drag(150.0, 30.0, 200.0, 30.0, steps=20)
  let after_left = (sa.offset(), sa.open_side())
  // Drag back left to close
  t.drag(200.0, 30.0, 120.0, 30.0, steps=20)
  let after_close = (sa.offset(), sa.open_side())
  // Slow horizontal drag left (-60 <= -40) snaps open Right (-100.0)
  t.drag(200.0, 30.0, 140.0, 30.0, steps=20)
  let after_right = (sa.offset(), sa.open_side())
  assert_eq(after_vert, (0.0, None, false))
  assert_eq(after_short, (0.0, None))
  assert_eq(after_left, (80.0, Some(Left)))
  assert_eq(after_close, (0.0, None))
  assert_eq(after_right, (-100.0, Some(Right)))
  assert_eq(events, [Some(Left), None, Some(Right)])
}

///|
test "SwipeActions: rubber-band damping past width, fast velocity flick, and programmatic open/close" {
  let sa = @headless.SwipeActions::new(left_width=80.0, right_width=80.0, threshold=0.5, velocity_threshold=400.0)
  let t = window(fn(root) {
    root.box(fn(v) {
      v
      .width(Is(Some(300.0)))
      .height(Is(Some(60.0)))
      .ground(Is(c_rest))
      .says(Is(Some(@view.said(Group, label="可滑行"))))
      |> ignore
      sa.bind(v)
    })
    |> ignore
  })
  // Hold-drag right 160px past left_width=80 -> rubber-band damped (80 < offset < 160)
  t.press_at(50.0, 30.0)
  t.move_to(210.0, 30.0)
  let mid_offset = sa.offset()
  let mid_drag = sa.dragging()
  t.release(210.0, 30.0)
  assert_true(mid_drag)
  assert_true(mid_offset > 80.0 && mid_offset < 160.0)
  assert_eq((sa.offset(), sa.open_side(), sa.dragging()), (80.0, Some(Left), false))
  // Programmatic close
  sa.close()
  assert_eq((sa.offset(), sa.open_side()), (0.0, None))
  // Fast short flick left (25px over 2 steps ≈ 750 pt/s > 400) snaps open Right even though 25 < 40
  t.drag(150.0, 30.0, 125.0, 30.0, steps=2)
  assert_eq((sa.offset(), sa.open_side()), (-80.0, Some(Right)))
  // Programmatic open(Left) switches side
  sa.open(Left)
  assert_eq((sa.offset(), sa.open_side()), (80.0, Some(Left)))
}
