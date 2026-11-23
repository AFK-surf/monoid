// What a screen reader is told of where a node is (Tree::said_order's rect): where it is drawn, as far off where it is
// laid out as it is drawn (View::drawn_off: a part moving to its place), as a press there finds it (Tree::target_at).

///|
test "said where it is drawn: a button drawn off where it is laid out is read out where it is drawn, and pressed there" {
  let ids : Map[String, @view.NodeId] = Map([])
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(col) {
        col.over(Is(true)) |> ignore
        col.box(fn(b) {
          ids["button"] = b.id()
          b
          .width(Is(Some(80.0)))
          .height(Is(Some(30.0)))
          .presses(Is(true))
          .says(Is(Some(@view.said(Button, label="Go"))))
          .drawn_off(Is((72.0, 0.0)))
          .on_press(fn() {  })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(400.0, 300.0) |> ignore
  let rect = t.said_order().filter(fn(s) { s.id == ids["button"] }).map(fn(s) { s.rect })
  guard rect is [(x, y, w, h)] else { fail("not read out: \{Repr(rect)}") }
  let hit = match t.target_at(x + w / 2.0, y + h / 2.0) {
    Pressed(id) => id == ids["button"]
    _ => false
  }
  assert_eq((x, w, hit), (72.0, 80.0, true))
}
