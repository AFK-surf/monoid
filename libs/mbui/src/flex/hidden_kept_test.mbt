// A box laid out nowhere (DisplayNone) and nothing in it changed: a compute that lays out what holds it again leaves
// it as it was, none of what it holds walked again (layout.mbt's hidden_gen); shown again, it is laid out whole.

///|
/// A column `n` boxes deep of boxes each 10 tall.
fn hidden_kept_column(n : Int) -> @flex.Node {
  let col = @flex.Node::new()
  for _ in 0..<n {
    let c = @flex.Node::new()
    c.style.set_height(Pt(10.0))
    col.add(c)
  }
  col
}

///|
test "what is laid out nowhere is not laid out again for a change beside it, and comes back whole" {
  let root = @flex.Node::new()
  root.style.set_width(Pt(100.0))
  root.style.set_height(Pt(400.0))
  let shown = hidden_kept_column(3)
  let hidden = hidden_kept_column(30)
  root.add(shown)
  root.add(hidden)
  hidden.style.display = DisplayNone
  hidden.dirty = true
  root.dirty = true
  @flex.compute(root, width=100.0, height=400.0, round=false, reuse=true)
  let first = hidden.children[29].laid_out_at()
  // (what shows changes: what holds both laid out again, the hidden as it was)
  shown.children[0].style.set_height(Pt(20.0))
  shown.children[0].dirty = true
  shown.dirty = true
  root.dirty = true
  @flex.compute(root, width=100.0, height=400.0, round=false, reuse=true)
  assert_eq(hidden.children[29].laid_out_at(), first)
  assert_eq(hidden.children[29].height, 0.0)
  // (something in it changed while hidden: still of no size, none of it laid out)
  hidden.children[3].style.set_height(Pt(30.0))
  hidden.children[3].dirty = true
  hidden.dirty = true
  root.dirty = true
  @flex.compute(root, width=100.0, height=400.0, round=false, reuse=true)
  assert_eq(hidden.children[3].height, 0.0)
  assert_eq(hidden.children[29].laid_out_at(), first)
  // (shown again: laid out whole, as a fresh one is)
  hidden.style.display = Flex
  hidden.dirty = true
  root.dirty = true
  @flex.compute(root, width=100.0, height=400.0, round=false, reuse=true)
  assert_eq(hidden.children[3].height, 30.0)
  assert_eq(hidden.children[29].height, 10.0)
  assert_eq(hidden.height, 320.0)
}
