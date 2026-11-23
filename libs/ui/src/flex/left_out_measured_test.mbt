// A row that leaves out what it has not the room for (Style's `fits`, `drop`), measured where it has no room bound (what
// holds it finding how wide it would be) and then laid out again in the room it was laid in, its layout kept: what it
// left out is left out still, not put back on a line by the measure, nowhere drawn and of no size (mbui's view reads
// Node::left_out to draw it nowhere: a preset's name drawn whole at no size on 中屏, 2026-11-15).

///|
test "a fits row measured with no room bound, then laid again where it was laid: what it left out stays left out" {
  let root = @flex.Node::new()
  root.style.direction = Row
  root.style.set_width(Pt(100.0))
  root.style.set_height(Pt(40.0))
  // (as wide as what it holds, given way where its parent has not the room: measured unbound first)
  let row = @flex.Node::new()
  row.style.direction = Row
  row.style.fits = true
  row.style.shrink = 1.0
  root.add(row)
  let keep = @flex.Node::new()
  keep.style.set_width(Pt(60.0))
  keep.style.set_height(Pt(20.0))
  row.add(keep)
  let leaves = @flex.Node::new()
  leaves.style.set_width(Pt(60.0))
  leaves.style.set_height(Pt(20.0))
  leaves.style.drop = 1
  row.add(leaves)
  for reuse in [false, true] {
    @flex.compute(root, round=!reuse, reuse~)
    assert_true(leaves.left_out(), msg="left out as laid (reuse \{reuse})")
    assert_eq(leaves.width, 0.0)
    // (measured with no room bound, as what holds a row finds how wide it would be: all of it on its line)
    assert_eq(@flex.measured_width(row, 0.0 / 0.0), 120.0)
    // (what holds it laid again, the row's own layout kept: laid where it was)
    root.dirty = true
    @flex.compute(root, round=!reuse, reuse~)
    assert_true(leaves.left_out(), msg="left out still, laid again (reuse \{reuse})")
    assert_false(keep.left_out(), msg="the one kept (reuse \{reuse})")
    assert_eq(leaves.width, 0.0)
  }
}
