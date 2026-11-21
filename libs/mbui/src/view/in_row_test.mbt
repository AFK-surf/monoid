// Whether what lays a node out lays it across (View::in_row): the first box holding it that is no slot, what shows,
// picks or repeats it skipped; followed as that box's View::row says otherwise, said after what it holds or later.

///|
test "in_row: down a column false, across a row true; false at the root" {
  let seen : Array[(String, Bool)] = []
  let t = @view.Tree::new(fn(root) {
    seen.push(("root", root.in_row()))
    root.box(fn(c) {
      seen.push(("column", c.in_row()))
      c.box(fn(r) {
        r.row(Is(true)) |> ignore
        r.box(fn(x) { seen.push(("row", x.in_row())) }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.frame(300.0, 100.0) |> ignore
  assert_eq(seen, [("root", false), ("column", false), ("row", true)])
}

///|
test "in_row: what shows, picks or repeats it in a row skipped; a box made in what shows it holds it down" {
  let seen : Array[(String, Bool)] = []
  let t = @view.Tree::new(fn(root) {
    root.box(fn(r) {
      r.row(Is(true)) |> ignore
      r.show(at_once=true, fn() { true }, fn(s) {
        seen.push(("show", s.in_row()))
        s.box(fn(c) { seen.push(("in show", c.in_row())) }) |> ignore
      })
      r.pick(at_once=true, fn() { 1 }, fn(p, _) { seen.push(("pick", p.in_row())) })
      r.each(at_once=true, fn() { [1] }, fn(k) { k }, fn(e, _) { seen.push(("each", e.in_row())) })
    })
    |> ignore
  })
  t.frame(300.0, 100.0) |> ignore
  assert_eq(seen, [("show", true), ("in show", false), ("pick", true), ("each", true)])
}

///|
test "in_row: a box made by its room in a row is across it; what it holds is down that box" {
  let outer : Ref[@view.View?] = Ref(None)
  let held_in : Ref[Bool?] = Ref(None)
  let t = @view.Tree::new(fn(root) {
    root.box(fn(r) {
      r.row(Is(true)) |> ignore
      outer.val = Some(r.by_room(fn(held, _) { held_in.val = Some(held.in_row()) }))
    })
    |> ignore
  })
  t.frame(300.0, 100.0) |> ignore
  assert_true(outer.val.unwrap().in_row())
  assert_eq(held_in.val, Some(false))
}

///|
/// A box `c` sized by whether it is in a row (grown across it, else 50 wide) in a box `r` across as `across` says, said
/// after `c` is made.
fn in_row_tree(across : @view.Live[Bool]) -> (@view.Tree, Ref[@view.View?]) {
  let node : Ref[@view.View?] = Ref(None)
  let t = @view.Tree::new(fn(root) {
    root.box(fn(r) {
      r.box(fn(c) {
        node.val = Some(c)
        c.sets_together(fn() { c.in_row() }, fn(ir) {
          if ir {
            c.width(Is(None)).grow(Is(1.0)) |> ignore
          } else {
            c.width(Is(Some(50.0))).grow(Is(0.0)) |> ignore
          }
        })
        |> ignore
      })
      |> ignore
    })
    .row(across)
    |> ignore
  })
  (t, node)
}

///|
test "in_row: what holds it said a row after it was made, read so by the first layout" {
  let (t, c) = in_row_tree(Is(true))
  let computes = t.work().computes
  t.frame(300.0, 100.0) |> ignore
  assert_eq(t.work().computes - computes, 1, msg="one layout")
  assert_eq(c.val.unwrap().laid_size().0, 300.0)
}

///|
test "in_row: followed as what holds it turns from a row to a column and back" {
  let across = @signals.signal(true, same=fn(a, b) { a == b })
  let (t, c) = in_row_tree(By(fn() { across.get() }))
  t.frame(300.0, 100.0) |> ignore
  let c = c.val.unwrap()
  assert_eq(c.laid_size().0, 300.0)
  across.set(false)
  t.frame(300.0, 100.0) |> ignore
  assert_eq(c.laid_size().0, 50.0)
  across.set(true)
  t.frame(300.0, 100.0) |> ignore
  assert_eq(c.laid_size().0, 300.0)
}
