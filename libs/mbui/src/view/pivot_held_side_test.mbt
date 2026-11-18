// A node scaled about the side what it draws is laid from (Pivot's DrawnSide) that shows none of its own (one short line
// of words filling it, as wide as they are, nothing else drawn: a reply's 刚刚, a fader round it) takes the side it is
// laid at in what holds it (Tree::pivot_held_side): at a column's end it keeps its end, at its start its start, in its
// middle its middle (the user, 2026-11-17: a short line under one's own bubble grew from its middle, sliding toward the
// bubble's edge as it came).

///|
/// A column 300 wide, its lines laid at `side`, holding one short line of words as wide as they are, scaled by `s`
/// about DrawnSide(0.0). Drawn once at 0.
fn phs_case(side : @view.Along, s : @signals.Signal[Double]) -> @view.Tree {
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).lines_up(Is(Some(side))) |> ignore
      o.box(fn(w) { w.words(Is("刚刚")).scale(By(fn() { s.get() }), about=DrawnSide(0.0)) |> ignore }) |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  tree
}

///|
/// Where the words 刚刚 are drawn across: their start and end.
fn phs_across(t : @view.Tree) -> (Double, Double) {
  match t.drawn().filter(fn(d) { d.words == "刚刚" }) {
    [d, ..] => (d.x, d.x + d.w)
    _ => (-1.0, -1.0)
  }
}

///|
test "DrawnSide, a short line filling its node at a column's end: grown about that end" {
  let s = @signals.signal(1.0, same=fn(a, b) { a == b })
  let t = phs_case(End, s)
  let (_, e0) = phs_across(t)
  assert_true((e0 - 300.0).abs() < 0.5, msg="刚刚 ends at \{e0} at rest, 300 wanted")
  s.set(0.5)
  t.frame(390.0, 844.0) |> ignore
  let (x, e) = phs_across(t)
  assert_true((e - e0).abs() < 0.5, msg="刚刚 drawn \{x} to \{e} at half its size: its end moved from \{e0}")
}

///|
test "DrawnSide, a short line filling its node at a column's start: grown about that start" {
  let s = @signals.signal(1.0, same=fn(a, b) { a == b })
  let t = phs_case(Start, s)
  let (x0, _) = phs_across(t)
  s.set(0.5)
  t.frame(390.0, 844.0) |> ignore
  let (x, e) = phs_across(t)
  assert_true((x - x0).abs() < 0.5, msg="刚刚 drawn \{x} to \{e} at half its size: its start moved from \{x0}")
}

///|
test "DrawnSide, a short line filling its node in a column's middle: grown about that middle" {
  let s = @signals.signal(1.0, same=fn(a, b) { a == b })
  let t = phs_case(Middle, s)
  let (a0, b0) = phs_across(t)
  s.set(0.5)
  t.frame(390.0, 844.0) |> ignore
  let (a, b) = phs_across(t)
  assert_true(((a + b) / 2.0 - (a0 + b0) / 2.0).abs() < 0.5, msg="刚刚 drawn \{a} to \{b}: its middle moved from \{(a0 + b0) / 2.0}")
}

///|
test "DrawnSide, a short line filling its node at a row's start: no side of a column's, grown about its middle" {
  let s = @signals.signal(1.0, same=fn(a, b) { a == b })
  let t = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).row(Is(true)) |> ignore
      o.box(fn(w) { w.words(Is("刚刚")).scale(By(fn() { s.get() }), about=DrawnSide(0.0)) |> ignore }) |> ignore
    })
    |> ignore
  })
  t.frame(390.0, 844.0) |> ignore
  let (a0, b0) = phs_across(t)
  s.set(0.5)
  t.frame(390.0, 844.0) |> ignore
  let (a, b) = phs_across(t)
  assert_true(((a + b) / 2.0 - (a0 + b0) / 2.0).abs() < 0.5, msg="刚刚 drawn \{a} to \{b}: its middle moved from \{(a0 + b0) / 2.0}")
}

///|
test "DrawnSide, a short line in a capsule hugging it within its sides, at a column's end: grown about that end" {
  let s = @signals.signal(1.0, same=fn(a, b) { a == b })
  let t = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).lines_up(Is(Some(End))) |> ignore
      o.box(fn(c) {
        c.sides(Is((8.0, 8.0))) |> ignore
        c.box(fn(w) { w.words(Is("刚刚")).scale(By(fn() { s.get() }), about=DrawnSide(0.0)) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.frame(390.0, 844.0) |> ignore
  let (_, e0) = phs_across(t)
  s.set(0.5)
  t.frame(390.0, 844.0) |> ignore
  let (x, e) = phs_across(t)
  assert_true((e - e0).abs() < 0.5, msg="刚刚 drawn \{x} to \{e} at half its size: its end moved from \{e0}")
}
