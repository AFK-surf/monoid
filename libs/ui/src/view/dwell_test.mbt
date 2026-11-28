// A finger's rest (Dwell): told once the finger has stayed within the slop of where the wait began for its while, at
// that moment whatever frames come; stirred further, the wait begins anew; called off, nothing told.

///|
/// A tree, its root, and what a Dwell of 300 ms within 8 told (the moment, where the finger was last said to be).
fn dwell_tree() -> (@view.Tree, @view.View, @view.Dwell, Array[(Double, Double, Double)]) {
  let node : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(fn(root) { node.val = Some(root) })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  (tree, node.val.unwrap(), @view.Dwell::new(300.0, 8.0), [])
}

///|
test "dwell: a finger that stays within the slop is told at the wait's end, between frames, where it was last said to be" {
  let (tree, node, dwell, told) = dwell_tree()
  let then = fn(when : Double, x : Double, y : Double) { told.push((when, x, y)) }
  tree.event(10.0, fn() { dwell.at(node, 100.0, 50.0, 10.0, then) })
  // (stirring within the slop: the same wait, the finger's place followed)
  tree.event(120.0, fn() { dwell.at(node, 104.0, 53.0, 120.0, then) })
  assert_true(dwell.waiting())
  tree.at(305.0)
  tree.frame(390.0, 844.0, now=305.0) |> ignore
  assert_eq(told, [])
  // (a frame long after: told at its own moment, 310, not the frame's)
  tree.at(400.0)
  tree.frame(390.0, 844.0, now=400.0) |> ignore
  assert_eq(told, [(310.0, 104.0, 53.0)])
  assert_false(dwell.waiting())
}

///|
test "dwell: stirred further than the slop the wait begins anew from there; called off, nothing is told" {
  let (tree, node, dwell, told) = dwell_tree()
  let then = fn(when : Double, x : Double, y : Double) { told.push((when, x, y)) }
  tree.event(10.0, fn() { dwell.at(node, 100.0, 50.0, 10.0, then) })
  // (9 away: past the slop, the wait from 200 now)
  tree.event(200.0, fn() { dwell.at(node, 109.0, 50.0, 200.0, then) })
  tree.at(400.0)
  tree.frame(390.0, 844.0, now=400.0) |> ignore
  assert_eq(told, [])
  tree.at(520.0)
  tree.frame(390.0, 844.0, now=520.0) |> ignore
  assert_eq(told, [(500.0, 109.0, 50.0)])
  // (a wait called off before its end)
  tree.event(600.0, fn() { dwell.at(node, 30.0, 30.0, 600.0, then) })
  tree.event(700.0, fn() { dwell.off() })
  tree.at(1200.0)
  tree.frame(390.0, 844.0, now=1200.0) |> ignore
  assert_eq(told.length(), 1)
  assert_false(dwell.waiting())
}
