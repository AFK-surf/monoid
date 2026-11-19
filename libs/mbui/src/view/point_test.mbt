// What the pointer is over, followed (Tree::point_at, Tree::follow_point): gone, nothing pointed at and nothing
// followed at once; the tree let go as it is first told, nothing followed after it.

///|
/// A tree whose one button (40 square at the top left) takes the pointer as `enabled` says (View::takes), and whether
/// it is pointed at (View::pointed), as its ground says.
fn pointed_tree(enabled : @signals.Signal[Bool], seen : Ref[Bool]) -> @view.Tree {
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(b) {
        b
        .width(Is(Some(40.0)))
        .height(Is(Some(40.0)))
        .on_press(fn() {  })
        .takes(fn(w, h, _) { if enabled.get() { [(0.0, 0.0, w, h)] } else { [] } })
        .ground(
          By(fn() {
            seen.val = b.pointed()
            1L
          }),
        )
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(100.0, 100.0) |> ignore
  t
}

///|
test "pointing: at a button, pointed at; gone (no point), not pointed at and nothing followed, at once" {
  let enabled = @signals.signal(true, same=fn(a, b) { a == b })
  let seen = Ref(false)
  let t = pointed_tree(enabled, seen)
  let held = t.bindings_held()
  t.point_at(20.0, 20.0)
  assert_eq(t.pointed_now() is Some(_), true)
  assert_true(enabled.watched())
  t.point_at(-1.0, -1.0)
  assert_eq(t.pointed_now(), None)
  assert_false(enabled.watched())
  assert_eq(t.bindings_held(), held)
}

///|
test "pointing: the tree let go as what is under the point is first told: what it read followed no more, nothing of it held, no frame drawn" {
  let enabled = @signals.signal(true, same=fn(a, b) { a == b })
  let seen = Ref(false)
  let t = pointed_tree(enabled, seen)
  t.follow_point(20.0, 20.0, fn(_) { t.dispose() })
  assert_false(enabled.watched())
  assert_eq(t.bindings_held(), 0)
}

///|
/// Two buttons side by side, each taking the pointer as its own signal says.
fn two_buttons(a : @signals.Signal[Bool], b : @signals.Signal[Bool]) -> @view.Tree {
  let t = @view.Tree::new(
    fn(root) {
      root.row(Is(true)) |> ignore
      for e in [a, b] {
        root.box(fn(n) {
          n.width(Is(Some(40.0))).height(Is(Some(40.0))).on_press(fn() {  }).takes(fn(w, h, _) { if e.get() { [(0.0, 0.0, w, h)] } else { [] } }) |> ignore
        })
        |> ignore
      }
    },
    time=fn() { 0.0 },
  )
  t.frame(100.0, 100.0) |> ignore
  t
}

///|
test "pointing: let go as what is under the point is first told: nothing followed, nothing held; moved elsewhere then, then let go: neither followed" {
  let a = @signals.signal(true, same=fn(x, y) { x == y })
  let b = @signals.signal(true, same=fn(x, y) { x == y })
  let t = two_buttons(a, b)
  let held = t.bindings_held()
  t.follow_point(20.0, 20.0, fn(_) { t.point_at(-1.0, -1.0) })
  assert_eq((a.watched(), t.bindings_held()), (false, held))
  t.follow_point(20.0, 20.0, fn(_) { t.follow_point(60.0, 20.0, fn(_) {  }) })
  assert_eq((a.watched(), b.watched()), (false, true))
  t.point_at(-1.0, -1.0)
  assert_eq((a.watched(), b.watched(), t.bindings_held()), (false, false, held))
}

///|
test "pointing: a pointed child inside a pressable row let go when pointed_in turns true falls back to the row without oscillating" {
  let changes = Ref(0)
  let row_id : Ref[@view.NodeId?] = Ref(None)
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(row) {
        row_id.val = Some(row.id())
        row
        .width(Is(Some(100.0)))
        .height(Is(Some(40.0)))
        .on_press(fn() {  })
        .show(
          fn() {
            changes.val = changes.val + 1
            !row.pointed_in()
          },
          fn(badge) {
            badge.over(Is(true)).width(Is(Some(40.0))).height(Is(Some(40.0))).points(Is(true)) |> ignore
          },
        )
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(100.0, 100.0) |> ignore
  assert_eq(changes.val, 1)
  t.point_at(20.0, 20.0)
  t.frame(100.0, 100.0) |> ignore
  assert_eq(t.pointed_now(), row_id.val)
  assert_eq(changes.val, 2)
}

///|
/// A thumb that takes drags (as `captures` says) beside a button, each 40 square.
fn thumb_and_button(captures : Bool) -> @view.Tree {
  let t = @view.Tree::new(
    fn(root) {
      root.row(Is(true)) |> ignore
      root.box(fn(n) { n.width(Is(Some(40.0))).height(Is(Some(40.0))).on_drag(fn(_) {  }, captures~) |> ignore }) |> ignore
      root.box(fn(n) { n.width(Is(Some(40.0))).height(Is(Some(40.0))).on_press(fn() {  }) |> ignore }) |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(100.0, 100.0) |> ignore
  t
}

///|
test "pointing: while a thumb that captures is dragged, the button the pointer passes over is not pointed at; let go, it is" {
  let t = thumb_and_button(true)
  let thumb = match t.target_at(20.0, 20.0) {
    Dragged(id) => id
    _ => @halt.saying("not a thumb")
  }
  let button = match t.target_at(60.0, 20.0) {
    Pressed(id) => id
    _ => @halt.saying("not a button")
  }
  t.point_at(20.0, 20.0)
  assert_eq(t.pointed_now(), Some(thumb))
  t.drag_at(thumb, Down, 20.0, 20.0, 10.0) |> ignore
  t.point_at(60.0, 20.0)
  t.drag_at(thumb, Moved, 60.0, 20.0, 20.0) |> ignore
  assert_eq(t.pointed_now(), None)
  t.point_at(20.0, 20.0)
  assert_eq(t.pointed_now(), Some(thumb))
  t.point_at(60.0, 20.0)
  let hits = t.hits_said()
  t.drag_at(thumb, Up, 60.0, 20.0, 30.0) |> ignore
  // (let go: what is placed under a still pointer said to have changed, which the host follows again, as here)
  assert_true(t.hits_said() > hits)
  t.point_at(60.0, 20.0)
  assert_eq(t.pointed_now(), Some(button))
}

///|
test "pointing: while a thumb that does not capture is dragged (a file over folders), what the pointer passes over is pointed at" {
  let t = thumb_and_button(false)
  let thumb = match t.target_at(20.0, 20.0) {
    Dragged(id) => id
    _ => @halt.saying("not a thumb")
  }
  let button = match t.target_at(60.0, 20.0) {
    Pressed(id) => id
    _ => @halt.saying("not a button")
  }
  t.point_at(20.0, 20.0)
  t.drag_at(thumb, Down, 20.0, 20.0, 10.0) |> ignore
  t.point_at(60.0, 20.0)
  assert_eq(t.pointed_now(), Some(button))
  t.drag_at(thumb, Up, 60.0, 20.0, 30.0) |> ignore
}
