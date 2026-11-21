// The ring that says how far as a node (progress_ring_node): its track and its part, at each part it is told; told
// another, nothing of it made again.

///|
let ring_test_size : Double = 14.0

///|
/// The ring as a node showing `part` as it changes.
fn ring_tester(part : @signals.Signal[Double]) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=100.0, h=100.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.row(Is(true)).lines_up(Is(Some(Start))) |> ignore
    progress_ring_node(root, ring_test_size, fn() { part.get() }, fn() { white }) |> ignore
  })
  t.draw()
  t
}

///|
test "the ring as a node: none come, a part, all of it and past it; told another part, nothing of it made again" {
  let part = @signals.signal(0.0)
  let t = ring_tester(part)
  let alive = @ui.view_tree().unwrap().alive()
  let seen = []
  for p in [0.0, 0.35, 1.0, 1.5] {
    part.set(p)
    t.frame()
    let shapes = t.drawn_shapes()
    assert_true(shapes.length() > 0, msg="at \{p}")
    seen.push(shapes.length())
  }
  // (more of it drawn as more is come: the track alone, then the track and its part)
  assert_true(seen[1] > seen[0], msg="\{Repr(seen)}")
  // (its nodes the same: told another part, only what it draws worked out again)
  assert_eq(@ui.view_tree().unwrap().alive(), alive)
  assert_eq(t.audit(), [])
}
