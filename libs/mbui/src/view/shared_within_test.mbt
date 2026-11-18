// What flies between two places both within a node said View::flights_within (shared.mbt): drawn within where that node
// is seen all the way, its old copy too; one that flies in from outside it, or with nothing said, as any flight is.

///|
/// A page 400 wide, its margins 20: a board 200 tall (cut to itself; said `within`) of two columns 100 wide, each cut to
/// itself, then under it a tray 100 tall. A card 40 square, one thing by id "c": in the tray (`from_tray`) or the first
/// column's top while `moved` is not, at the second column's foot (170 down it, its foot 10 past the board's) while it
/// is. What each made last is kept.
priv struct WithinScene {
  tree : @view.Tree
  moved : @signals.Signal[Bool]
  from : Ref[@view.View?]
  to : Ref[@view.View?]
}

///|
fn within_scene(within? : Bool = true, from_tray? : Bool = false) -> WithinScene {
  let moved = @signals.signal(false, same=fn(a, b) { a == b })
  let from : Ref[@view.View?] = Ref(None)
  let to : Ref[@view.View?] = Ref(None)
  let straight : @view.Flight = { way: fn(_) { (200.0, fn(ms) { ms / 200.0 }) } }
  let card = fn(c : @view.View) {
    c.width(Is(Some(40.0))).height(Is(Some(40.0))).ground(Is(0xFF0000FFL)).shared(Is("c"), straight) |> ignore
  }
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(p) {
      p.grow(Is(1.0)).padding(Is((20.0, 20.0, 20.0, 20.0))) |> ignore
      p.box(fn(board) {
        board.height(Is(Some(200.0))).row(Is(true)).clips(Is(true)) |> ignore
        if within {
          board.flights_within() |> ignore
        }
        board.box(fn(a) {
          a.width(Is(Some(100.0))).clips(Is(true)) |> ignore
          if !from_tray {
            a.show(fn() { !moved.get() }, fn(c) {
              from.val = Some(c)
              card(c)
            })
          }
        })
        |> ignore
        board.box(fn(b) {
          b.width(Is(Some(100.0))).clips(Is(true)) |> ignore
          b.box(fn(gap) { gap.height(Is(Some(170.0))) |> ignore }) |> ignore
          b.show(fn() { moved.get() }, fn(c) {
            to.val = Some(c)
            card(c)
          })
        })
        |> ignore
      })
      |> ignore
      p.box(fn(tray) {
        tray.height(Is(Some(100.0))) |> ignore
        if from_tray {
          tray.show(fn() { !moved.get() }, fn(c) {
            from.val = Some(c)
            card(c)
          })
        }
      })
      |> ignore
    })
    |> ignore
  })
  { tree, moved, from, to }
}

///|
test "a card going to another column of a board said flights_within: drawn within the board all the way, its old copy too, never past its foot" {
  let p = within_scene()
  p.tree.frame(400.0, 800.0, now=0.0) |> ignore
  let from = p.from.val.unwrap()
  p.tree.event(1000.0, fn() { p.moved.set(true) })
  p.tree.frame(400.0, 800.0, now=1000.0) |> ignore
  let to = p.to.val.unwrap()
  assert_true(to.flies())
  // (the board, 20 to 380 across, 20 to 220 down: the card's way ends 10 past its foot)
  assert_eq(p.tree.lift_cut(to.id()), Some((20.0, 20.0, 380.0, 220.0)))
  assert_eq(p.tree.lift_cut(from.id()), Some((20.0, 20.0, 380.0, 220.0)))
  assert_eq(p.tree.lift_cut_corners(to.id()), Some((0.0, 0.0, 0.0, 0.0)))
  p.tree.frame(400.0, 800.0, now=1100.0) |> ignore
  assert_eq(p.tree.lift_cut(to.id()), Some((20.0, 20.0, 380.0, 220.0)))
  // (there: in its column, cut by it as ever, no flight's cut)
  p.tree.frame(400.0, 800.0, now=1200.0) |> ignore
  assert_false(to.flies())
  assert_eq(p.tree.lift_cut(to.id()), None)
}

///|
test "with nothing said, or flown in from outside the board, a card's flight is cut by nothing that holds it" {
  for case in [(false, false), (true, true)] {
    let p = within_scene(within=case.0, from_tray=case.1)
    p.tree.frame(400.0, 800.0, now=0.0) |> ignore
    p.tree.event(1000.0, fn() { p.moved.set(true) })
    p.tree.frame(400.0, 800.0, now=1100.0) |> ignore
    let to = p.to.val.unwrap()
    assert_true(to.flies())
    assert_eq(p.tree.lift_cut(to.id()), None)
    assert_eq(p.tree.lift_cut_corners(to.id()), None)
  }
}
