// Rows that scroll across as one (Scroll::beside): two rows 300 wide in a column, each holding ten cells 60 wide (600 in
// all: each can go 300), each its own Scroll beside one they share.

///|
test "scrolls beside another: the wheel on either moves both as far as they go; one let go, the other where it was" {
  let shared = @view.Scroll::across()
  let a = shared.beside()
  let b = shared.beside()
  let second = @signals.signal(true, same=fn(x, y) { x == y })
  let now = Ref(0.0)
  let tree = @view.Tree::new(
    fn(root) {
      root.box(fn(col) {
        col.width(Is(Some(300.0))) |> ignore
        let cells = fn(rh : @view.View) {
          rh.row(Is(true)) |> ignore
          for _ in 0..<10 {
            rh.box(fn(c) { c.width(Is(Some(60.0))).height(Is(Some(40.0))).ground(Is(0x101010FFL)) |> ignore }) |> ignore
          }
        }
        col.box(fn(r) { r.scrolls(a, cells) |> ignore }) |> ignore
        col.show(fn() { second.get() }, at_once=true, fn(r) { r.scrolls(b, cells) |> ignore })
      })
      |> ignore
    },
    time=fn() { now.val },
  )
  tree.frame(390.0, 844.0, now=now.val) |> ignore
  // (the wheel across the first: both moved by it)
  tree.wheel_at(150.0, 20.0, 120.0, 0.0, 0, 10.0) |> ignore
  now.val = 2000.0
  tree.frame(390.0, 844.0, now=now.val) |> ignore
  let moved = a.at(tree)
  assert_true(moved > 0.0, msg="the first moved by the wheel on it: \{moved}")
  assert_eq(b.at(tree), moved)
  // (the wheel across the second, past its end: both as far as they go)
  tree.wheel_at(150.0, 60.0, 900.0, 0.0, 0, 2010.0) |> ignore
  now.val = 4000.0
  tree.frame(390.0, 844.0, now=now.val) |> ignore
  assert_eq(a.at(tree), 300.0)
  assert_eq(b.at(tree), 300.0)
  // (the second let go: the first where it was, the wheel on it still moving it)
  second.set(false)
  tree.frame(390.0, 844.0, now=now.val) |> ignore
  assert_eq(a.at(tree), 300.0)
  tree.wheel_at(150.0, 20.0, -120.0, 0.0, 0, 4010.0) |> ignore
  now.val = 6000.0
  tree.frame(390.0, 844.0, now=now.val) |> ignore
  assert_true(a.at(tree) < 300.0, msg="moved back by the wheel: \{a.at(tree)}")
}

///|
/// The bar along a row's foot as drawn (x, y, w, h, opacity): the thumb 3 tall, if it is.
fn beside_thumb(tree : @view.Tree) -> (Double, Double, Double, Double, Double)? {
  tree.drawn().iter().find_first(fn(d) { d.h == 3.0 && d.alpha > 0.0 }).map(fn(d) { (d.x, d.y, d.w, d.h, d.alpha) })
}

///|
test "scrolls beside another, the bar under the second alone (bar_here): the wheel on the first shows it there, over the second's foot; no room kept for it under either; said otherwise, the bar goes with it" {
  let shared = @view.Scroll::across()
  let a = shared.beside()
  let b = shared.beside()
  let second_bars = @signals.signal(true, same=fn(x, y) { x == y })
  let now = Ref(0.0)
  let rows : Array[@view.View] = []
  let tree = @view.Tree::new(
    fn(root) {
      root.box(fn(col) {
        col.width(Is(Some(300.0))) |> ignore
        let cells = fn(rh : @view.View) {
          rh.row(Is(true)) |> ignore
          for _ in 0..<10 {
            rh.box(fn(c) { c.width(Is(Some(60.0))).height(Is(Some(40.0))).ground(Is(0x101010FFL)) |> ignore }) |> ignore
          }
        }
        col.box(fn(r) {
          rows.push(r)
          r.scrolls(a, bar=test_bar(), bar_here=fn() { !second_bars.get() }, cells) |> ignore
        })
        |> ignore
        col.box(fn(r) {
          rows.push(r)
          r.scrolls(b, bar=test_bar(), bar_here=fn() { second_bars.get() }, cells) |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { now.val },
  )
  tree.frame(390.0, 844.0, now=now.val) |> ignore
  let tall = fn() { rows.map(fn(r) { r.laid_size().1 }) }
  let first = (beside_thumb(tree), tall())
  // (the wheel across the first: the bar under the second comes in)
  tree.wheel_at(150.0, 20.0, 120.0, 0.0, 0, 10.0) |> ignore
  now.val = 300.0
  tree.frame(390.0, 844.0, now=now.val) |> ignore
  let shown = beside_thumb(tree)
  // (the bar the first's now, none under the second)
  second_bars.set(false)
  now.val = 3000.0
  tree.frame(390.0, 844.0, now=now.val) |> ignore
  let moved_tall = tall()
  tree.wheel_at(150.0, 60.0, 60.0, 0.0, 0, 3010.0) |> ignore
  now.val = 3300.0
  tree.frame(390.0, 844.0, now=now.val) |> ignore
  let shown_first = beside_thumb(tree)
  // (no room kept for a bar, the user's 2026-11-17: each bar over the foot of the one that has it, 2 over its edge)
  assert_eq(first, (None, [40.0, 40.0]))
  assert_true(shown is Some((_, y, _, _, alpha)) && y > 70.0 && y < 80.0 && alpha == 1.0, msg="\{Repr(shown)}")
  assert_eq(moved_tall, [40.0, 40.0])
  assert_true(shown_first is Some((_, y, _, _, alpha)) && y > 30.0 && y < 40.0 && alpha == 1.0, msg="\{Repr(shown_first)}")
}

///|
/// When the hand comes down on the second row, 40 ms after the first was let go flinging (at 120): on its way.
let beside_held_at : Double = 160.0

///|
test "scrolls beside another: flung on the first and held on the second on its way, both stay where the hand stopped them, the fling's end come and gone" {
  let shared = @view.Scroll::across()
  let a = shared.beside()
  let b = shared.beside()
  let now = Ref(0.0)
  let tree = @view.Tree::new(
    fn(root) {
      root.box(fn(col) {
        col.width(Is(Some(300.0))) |> ignore
        let cells = fn(rh : @view.View) {
          rh.row(Is(true)) |> ignore
          for _ in 0..<10 {
            rh.box(fn(c) { c.width(Is(Some(60.0))).height(Is(Some(40.0))).ground(Is(0x101010FFL)) |> ignore }) |> ignore
          }
        }
        col.box(fn(r) { r.scrolls(a, cells) |> ignore }) |> ignore
        col.box(fn(r) { r.scrolls(b, cells) |> ignore }) |> ignore
      })
      |> ignore
    },
    time=fn() { now.val },
  )
  tree.frame(390.0, 844.0, now=now.val) |> ignore
  // (flung on the first: let go moving at 2 a ms)
  let first = tree.claimer_of(tree.claimers_at(150.0, 20.0), -20.0, 0.0).unwrap()
  tree.drag_at(first, Down, 170.0, 20.0, 100.0) |> ignore
  tree.drag_at(first, Moved, 150.0, 20.0, 110.0) |> ignore
  tree.drag_at(first, Moved, 130.0, 20.0, 120.0) |> ignore
  tree.drag_at(first, Up, 130.0, 20.0, 120.0) |> ignore
  // (on its way, the hand down on the second: both stopped there)
  now.val = beside_held_at
  tree.advance(beside_held_at)
  tree.frame(390.0, 844.0, now=now.val) |> ignore
  let second = tree.claimer_of(tree.claimers_at(150.0, 60.0), -20.0, 0.0).unwrap()
  tree.drag_at(second, Down, 150.0, 60.0, beside_held_at) |> ignore
  let held = b.at(tree)
  // (long after where the fling would have come to rest: still there)
  now.val = fling_long_after_at
  tree.advance(fling_long_after_at)
  tree.frame(390.0, 844.0, now=now.val) |> ignore
  assert_true(held > 40.0 && held < 300.0, msg="stopped on its way: \{held}")
  assert_eq((a.at(tree), b.at(tree)), (held, held))
}
