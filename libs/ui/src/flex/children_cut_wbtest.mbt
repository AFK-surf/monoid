///|
test "children cut and taken out: those left in order" {
  let n = Node::new()
  let a = Node::new()
  let b = Node::new()
  let c = Node::new()
  let d = Node::new()
  for k in [a, b, c, d] {
    n.add(k)
  }
  n.child_taken_out(1)
  assert_true(n.children.length() == 3 && physical_equal(n.children[0], a) && physical_equal(n.children[1], c))
  assert_true(physical_equal(n.children[2], d))
  n.children_cut(1)
  assert_true(n.children.length() == 1 && physical_equal(n.children[0], a))
  n.children_cut(0)
  assert_eq(n.children.length(), 0)
  n.child_taken_out(0)
  assert_eq(n.children.length(), 0)
}
