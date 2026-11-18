// A style laid on a node (style_node) that says a property only some of the time: what it has said so far is what it
// sets, so a property said for the first time after the node was made is set, and one said before and said no more is
// put back to none.

///|
/// A window holding one node styled `said` where `on()`, `plain` where not, kept in `at`.
fn style_tester(on : @signals.Signal[Bool], plain : @ui.Style, said : @ui.Style, at : Ref[@view.View?]) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  @ui.set_view_app(fn(root) {
    root.padding(Is((20.0, 20.0, 0.0, 0.0))).lines_up(Is(Some(Start))) |> ignore
    root.box(fn(b) {
      at.val = Some(b)
      style_node(b, fn() { if on.get() { said } else { plain } })
    })
    |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// Whether node `at` is drawn on the hover's ground.
fn style_grounded(t : @ui.Tester, at : Ref[@view.View?]) -> Bool {
  let (x, y, w, h) = at.val.unwrap().placed_window_now()
  let hover = @ui.tree_theme().color(Hover)
  t.drawn_rects().iter().any(fn(r) { r.4 == hover && r.0 == x && r.1 == y && r.2 == w && r.3 == h })
}

///|
test "style_node: a ground said only after the node was made is drawn, and goes as it is said no more" {
  let on = @signals.signal(false, same=fn(a, b) { a == b })
  let at : Ref[@view.View?] = Ref(None)
  let plain = @ui.style(w=Fixed(64.0), h=Fixed(32.0))
  let t = style_tester(on, plain, plain.then(@ui.css("bg=Hover")), at)
  let seen = [style_grounded(t, at)]
  on.set(true)
  t.run_for(@ui.move_most_ms)
  seen.push(style_grounded(t, at))
  on.set(false)
  t.run_for(@ui.move_most_ms)
  seen.push(style_grounded(t, at))
  on.set(true)
  t.run_for(@ui.move_most_ms)
  seen.push(style_grounded(t, at))
  assert_eq(seen, [false, true, false, true])
}

///|
test "style_node: a ground said as the node was made goes as it is said no more, and comes back as it is said again" {
  let on = @signals.signal(true, same=fn(a, b) { a == b })
  let at : Ref[@view.View?] = Ref(None)
  let plain = @ui.style(w=Fixed(64.0), h=Fixed(32.0))
  let t = style_tester(on, plain, plain.then(@ui.css("bg=Hover")), at)
  let seen = [style_grounded(t, at)]
  on.set(false)
  t.run_for(@ui.move_most_ms)
  seen.push(style_grounded(t, at))
  on.set(true)
  t.run_for(@ui.move_most_ms)
  seen.push(style_grounded(t, at))
  assert_eq(seen, [true, false, true])
}

///|
test "style_node: a least height said only after the node was made is laid out, and goes as it is said no more" {
  let on = @signals.signal(false, same=fn(a, b) { a == b })
  let at : Ref[@view.View?] = Ref(None)
  let plain = @ui.style(w=Fixed(64.0))
  let t = style_tester(on, plain, plain.then(@ui.style(min_h=Fixed(50.0))), at)
  let high = fn() { at.val.unwrap().placed_window_now().3 }
  let seen = [high()]
  on.set(true)
  t.run_for(@ui.move_most_ms)
  seen.push(high())
  on.set(false)
  t.run_for(@ui.move_most_ms)
  seen.push(high())
  assert_eq(seen, [0.0, 50.0, 0.0])
}

///|
/// A window 400 wide holding a row 300 wide styled `row`, two boxes in it styled `each` (as it lays them in a row), kept
/// in `at`: where each is placed in the window.
fn style_row_tester(row : @ui.Style, each : @ui.Style, at : Array[@view.View]) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  @ui.set_view_app(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(r) {
      style_node(r, fn() { row })
      for _ in 0..<2 {
        r.box(fn(b) {
          at.push(b)
          style_node(b, fn() { each }, in_row=true)
          // (wider than it is let be where it is cut short: what it holds says so)
          b.box(fn(i) { i.width(Is(Some(100.0))).height(Is(Some(10.0))) |> ignore }) |> ignore
        })
        |> ignore
      }
    })
    |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "style_node: a row said justify=JBetween lies between its ends, the first at its start and the last at its end" {
  let at : Array[@view.View] = []
  let _ = style_row_tester(@ui.style(row=true, w=Fixed(300.0), justify=JBetween), @ui.style(), at)
  let placed = at.map(fn(b) { b.placed_window_now() })
  assert_eq(placed.map(fn(p) { (p.0, p.2) }), [(0.0, 100.0), (200.0, 100.0)])
}

///|
test "style_node: w=Cut in a row is cut short where the row has not the room, as an old view's is" {
  let at : Array[@view.View] = []
  let _ = style_row_tester(@ui.style(row=true, w=Fixed(150.0)), @ui.style(w=Cut), at)
  let placed = at.map(fn(b) { b.placed_window_now() })
  // (100 and 100 in 150: each gives way by as much, as CSS's flex-shrink 1 with no least)
  assert_eq(placed.map(fn(p) { (p.0, p.2) }), [(0.0, 75.0), (75.0, 75.0)])
}

///|
test "style_node: a least width said Within is so many points where what holds it has the room, all of it where it has less" {
  let wide = @signals.signal(true, same=fn(a, b) { a == b })
  let at : Ref[@view.View?] = Ref(None)
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  @ui.set_view_app(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(r) {
      r.width(By(fn() { Some(if wide.get() { 300.0 } else { 120.0 }) })).lines_up(Is(Some(Start))) |> ignore
      r.box(fn(b) {
        at.val = Some(b)
        style_node(b, fn() { @ui.style(min_w=Within(200.0), h=Fixed(10.0)) })
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  let seen = [at.val.unwrap().placed_window_now().2]
  wide.set(false)
  t.run_for(@ui.move_most_ms)
  seen.push(at.val.unwrap().placed_window_now().2)
  assert_eq(seen, [200.0, 120.0])
}

///|
test "style_node: a most width said Within is so many points where what holds it has the room, all of it where it has less" {
  let wide = @signals.signal(true, same=fn(a, b) { a == b })
  let at : Ref[@view.View?] = Ref(None)
  let t = @ui.Tester::new(fn(_c) {  }, w=500.0, h=300.0, platform=0)
  @ui.set_view_app(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(r) {
      r.width(By(fn() { Some(if wide.get() { 400.0 } else { 180.0 }) })).lines_up(Is(Some(Start))) |> ignore
      // (a box as wide as what it holds, 300, not cut short (no w=Cut): its most alone keeps it in)
      r.box(fn(b) {
        at.val = Some(b)
        style_node(b, fn() { @ui.style(max_w=Within(240.0)) })
        b.box(fn(k) { style_node(k, fn() { @ui.style(w=Fixed(300.0), h=Fixed(10.0)) }) }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  let seen = [at.val.unwrap().placed_window_now().2]
  wide.set(false)
  t.run_for(@ui.move_most_ms)
  seen.push(at.val.unwrap().placed_window_now().2)
  wide.set(true)
  t.run_for(@ui.move_most_ms)
  seen.push(at.val.unwrap().placed_window_now().2)
  assert_eq(seen, [240.0, 180.0, 240.0])
}

///|
test "style_node: a share of what holds it as a size is laid on no node: a fault naming where it was said, the property and its value" {
  let told : Array[String] = []
  @view.faults_stop.val = false
  @view.fault_told.val = Some(fn(s) { told.push(s) })
  let at : Ref[@view.View?] = Ref(None)
  let plain = @ui.style(w=Pct(50.0), h=Fixed(32.0))
  let _ = style_tester(@signals.signal(false), plain, plain, at)
  @view.faults_stop.val = true
  @view.fault_told.val = None
  assert_eq(told.length(), 1, msg=told.join(" | "))
  assert_true(told[0].contains("style_node_wbtest.mbt") && told[0].contains("w=Pct("), msg=told[0])
}

///|
/// A window 400 by 300 holding a node 200 by 100 at its top left, `before` run on it as it is made, then styled as
/// `look` says, two boxes 20 by 10 in it (kept in `at`).
fn style_lay_tester(before : (@view.View) -> Unit, look : () -> @ui.Style, at : Array[@view.View]) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  @ui.set_view_app(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(n) {
      n.width(Is(Some(200.0))).height(Is(Some(100.0))) |> ignore
      before(n)
      style_node(n, look)
      for _ in 0..<2 {
        n.box(fn(b) {
          at.push(b)
          b.width(Is(Some(20.0))).height(Is(Some(10.0))) |> ignore
        })
        |> ignore
      }
    })
    |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "style_node: a row, padding, gap and how it lines up and lies along that the node had, and the style never says, are kept" {
  let at : Array[@view.View] = []
  let _ = style_lay_tester(
    fn(n) {
      n
      .row(Is(true))
      .padding(Is((10.0, 10.0, 10.0, 10.0)))
      .gap(Is(8.0))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      |> ignore
    },
    fn() { @ui.css("bg=Veil") },
    at,
  )
  // (20 + 8 + 20 in the middle of 180 along, from 10; 10 in the middle of 80 across, from 10)
  assert_eq(at.map(fn(b) { b.placed_window_now() }), [
    (76.0, 45.0, 20.0, 10.0),
    (104.0, 45.0, 20.0, 10.0),
  ])
}

///|
test "style_node: a row, padding, gap and how it lines up and lies along said before and said no more are put back to none" {
  let on = @signals.signal(true, same=fn(a, b) { a == b })
  let at : Array[@view.View] = []
  let said = @ui.css("row p=S3 gap=S2 align=ACenter justify=JCenter bg=Surface")
  let plain = @ui.css("bg=Veil")
  let t = style_lay_tester(fn(_n) {  }, fn() { if on.get() { said } else { plain } }, at)
  let placed = fn() { at.map(fn(b) { b.placed_window_now() }) }
  let p = @ui.Space::S3.px()
  let g = @ui.Space::S2.px()
  let x = p + (200.0 - 2.0 * p - (40.0 + g)) / 2.0
  let y = p + (100.0 - 2.0 * p - 10.0) / 2.0
  let seen = [placed()]
  on.set(false)
  t.run_for(@ui.move_most_ms)
  seen.push(placed())
  assert_eq(seen, [
    [(x, y, 20.0, 10.0), (x + 20.0 + g, y, 20.0, 10.0)],
    [(0.0, 0.0, 20.0, 10.0), (0.0, 10.0, 20.0, 10.0)],
  ])
}
