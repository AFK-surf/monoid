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
