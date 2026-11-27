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

///|
test "input_bounds and draw_clip_bounds follow an ancestor's drawn_off so a button inside a clipping/scrolling container stays tappable where drawn" {
  let ids : Map[String, @view.NodeId] = Map([])
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(mover) {
        mover.over(Is(true)).drawn_off(Is((120.0, 80.0)), exact=true) |> ignore
        mover.box(fn(clip) {
          clip.width(Is(Some(100.0))).height(Is(Some(60.0))).clips(Is(true)).bounds_input(Is(true)) |> ignore
          clip.box(fn(b) {
            ids["button"] = b.id()
            b.width(Is(Some(80.0))).height(Is(Some(30.0))).presses(Is(true)).on_press(fn() {  }) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(400.0, 300.0) |> ignore
  assert_eq(t.input_bounds(ids["button"]), (120.0, 80.0, 220.0, 140.0))
  assert_eq(t.draw_clip_bounds(ids["button"]), (120.0, 80.0, 220.0, 140.0))
  let hit = match t.target_at(160.0, 95.0) {
    Pressed(id) => id == ids["button"]
    _ => false
  }
  assert_eq(hit, true)
}

///|
test "recycled node starts with zeroed placement before its first frame" {
  let show = @signals.signal(true)
  let recycled_before_frame : Ref[(Double, Double, Double, Double)?] = Ref(None)
  let t = @view.Tree::new(
    fn(root) {
      root.show(fn() { show.get() }, at_once=true, fn(slot) {
        slot.box(fn(b) {
          b.width(Is(Some(96.0))).height(Is(Some(42.0))) |> ignore
          if recycled_before_frame.val is Some(_) {
            recycled_before_frame.val = Some(b.placed_window_now())
          }
        })
        |> ignore
      })
    },
    time=fn() { 0.0 },
  )
  t.frame(400.0, 300.0) |> ignore
  show.set(false)
  t.frame(400.0, 300.0) |> ignore
  recycled_before_frame.val = Some((-1.0, -1.0, -1.0, -1.0))
  show.set(true)
  t.frame(400.0, 300.0) |> ignore
  assert_eq(recycled_before_frame.val, Some((0.0, 0.0, 0.0, 0.0)))
}
