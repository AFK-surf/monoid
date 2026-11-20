// A node held at the top of what scrolls it (View::sticky): a page's list 100 tall under 100 of the window's, a row of
// 40 then one of 200 holding a mark 20 square held 10 under the list's top, then more rows. Drawn, found (a press there)
// and placed (Tree::drawn_place, Tree::drawn_one) at the one place as the list scrolls: where it is laid out till its
// row's top goes past the hold, held there as the row goes on up, pushed up by the row's foot; none said, where it is
// laid out all along.

///|
priv struct StickyCase {
  tree : Tree
  mark : Ref[View?]
  pressed : Array[Int]
}

///|
fn sticky_case(held : Live[Double?]) -> StickyCase {
  let now = Ref(0.0)
  let scroll = Scroll::list()
  let mark : Ref[View?] = Ref(None)
  let pressed = []
  let tree = Tree::new(
    fn(root) {
      root.box(fn(o) {
        o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
        o.box(fn(gap) { gap.height(Is(Some(100.0))) |> ignore }) |> ignore
        o.box(fn(v) {
          v
          .height(Is(Some(100.0)))
          .scrolls(scroll, fn(list) {
            list.box(fn(r) { r.width(Is(Some(300.0))).height(Is(Some(40.0))) |> ignore }) |> ignore
            list.box(fn(r) {
              r.width(Is(Some(300.0))).height(Is(Some(200.0))) |> ignore
              r.box(fn(m) {
                m.width(Is(Some(20.0))).height(Is(Some(20.0))).sticky(held).on_press(fn() { pressed.push(1) }) |> ignore
                mark.val = Some(m)
              })
              |> ignore
            })
            |> ignore
            for _ in 0..<4 {
              list.box(fn(r) { r.width(Is(Some(300.0))).height(Is(Some(100.0))) |> ignore }) |> ignore
            }
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { now.val },
  )
  tree.frame(390.0, 844.0) |> ignore
  { tree, mark, pressed }
}

///|
/// The case scrolled `by` from its top: where its mark is drawn (the walk's, Tree::drawn_one), where it is placed
/// (Tree::drawn_place), and whether a press 5 into it where it is drawn presses it.
fn sticky_seen(c : StickyCase, by : Double) -> (Double, Double, Bool) {
  if by > 0.0 {
    c.tree.wheel_at(150.0, 150.0, 0.0, by, 0, 10.0) |> ignore
    c.tree.frame(390.0, 844.0) |> ignore
  }
  let m = c.mark.val.unwrap()
  let walked = match c.tree.drawn_one(m.id()) {
    Some((_, _, y, _, _, _, _, _)) => y
    None => -1.0
  }
  let placed = match c.tree.drawn_place(m.id()) {
    Some((_, y, _, _)) => y
    None => -1.0
  }
  c.pressed.clear()
  c.tree.press(5.0, walked + 5.0) |> ignore
  (walked, placed, c.pressed.length() == 1)
}

///|
test "a node held at a top: where it is laid out till its row's top passes the hold, held there as its row goes on up, pushed up by its row's foot; drawn, placed and pressed at the one place" {
  // (at its top: the row of 200 from 140 in the window, the mark on it there)
  assert_eq(sticky_seen(sticky_case(Is(Some(10.0))), 0.0), (140.0, 140.0, true))
  // (50 down: the row's top at 90, over the hold (the list's top, 100, and 10): held at 110)
  assert_eq(sticky_seen(sticky_case(Is(Some(10.0))), 50.0), (110.0, 110.0, true))
  // (220 down: the row's foot at 120, the mark's 20 kept over it: pushed up to 100)
  assert_eq(sticky_seen(sticky_case(Is(Some(10.0))), 220.0), (100.0, 100.0, true))
}

///|
test "a node said held at no top: where it is laid out as its row scrolls" {
  // (20 down: the row's top at 120, the mark there, over the hold or not)
  assert_eq(sticky_seen(sticky_case(Is(None)), 20.0), (120.0, 120.0, true))
  assert_eq(sticky_seen(sticky_case(Is(Some(10.0))), 20.0), (120.0, 120.0, true))
}

///|
test "a node held at a top drawn so whatever holds it is told of it: the row holding it and the list's held, not what is beside them" {
  let c = sticky_case(Is(Some(10.0)))
  let m = c.mark.val.unwrap()
  assert_true(c.tree.has_sticky_in(m.id()))
  assert_true(c.tree.sticks_any())
  // (said none: nothing is)
  let d = sticky_case(Is(None))
  assert_true(!d.tree.has_sticky_in(d.mark.val.unwrap().id()) && !d.tree.sticks_any())
}
