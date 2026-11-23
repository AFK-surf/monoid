// An item coming or going down a column (Style's come_*) whose height is not said, padded above and below: its padding
// comes and goes with what it holds, as tall all the way as its way has got (come_tall_at), never held at its padding
// till its way ends; the row under it with it. Laid out fresh (reuse=false) and again (reuse=true), holding a box 20
// tall or nothing at all. An item whose height is said, less than its padding: its padding the least it rests at, as
// tall as its way has got of that on its way.

///|
/// An item padded 8 above and 12 below, holding a box 20 tall where `holds`, its height not said, on its way from
/// `from` tall to `to` (1: all it comes to; 0: nothing), set out at 0, still.
fn cp_item(holds : Bool, from : Double, to : Double) -> @flex.Node {
  let n = @flex.Node::new()
  let s = n.style
  s.set_padding_top(Pt(8.0))
  s.set_padding_bottom(Pt(12.0))
  s.shrink = 0.0
  if holds {
    let inner = @flex.Node::new()
    inner.style.set_height(Pt(20.0))
    inner.style.shrink = 0.0
    n.add(inner)
  }
  cp_way(n, from, to)
  n
}

///|
/// Item `n` on its way from `from` tall to `to`, set out at 0, still (as the view's View::comes sets it).
fn cp_way(n : @flex.Node, from : Double, to : Double) -> Unit {
  let s = n.style
  s.come_from = from
  s.come_to = to
  s.come_v = 0.0
  s.come_at = 0.0
  s.come_now = 0.0
  s.come_goal = if to <= 0.0 { 0.0 } else { 0.0 / 0.0 }
  s.come_ends = if to <= 0.0 { @flex.come_way_ms(from, 0.0, 0.0) } else { 0.0 / 0.0 }
  s.come_plan = s.come_goal
  s.come_fill = to <= 0.0 || from <= 0.0
}

///|
/// A column 300 wide holding `item`, a row 30 tall under it.
fn cp_column(item : @flex.Node) -> (@flex.Node, @flex.Node) {
  let col = @flex.Node::new()
  col.style.position = Absolute
  col.style.set_width(Pt(300.0))
  col.add(item)
  let under = @flex.Node::new()
  under.style.set_height(Pt(30.0))
  under.style.shrink = 0.0
  col.add(under)
  (col, under)
}

///|
/// `item`'s height and the top of the row under it at each 5 ms from 0 to 600 on its way, laid out fresh or again
/// (marked as a caller marks it), with how tall its way has it then (come_tall_at, `natural` all it comes to).
fn cp_walk(
  item : @flex.Node,
  natural : Double,
  reuse : Bool,
) -> Array[(Double, Double, Double)] {
  let (col, under) = cp_column(item)
  let out = []
  let mut t = 0.0
  while t <= 600.0 {
    item.style.come_now = t
    item.dirty = true
    col.dirty = true
    @flex.compute(col, round=false, reuse~)
    out.push((item.height, under.top, @flex.come_tall_at(item.style, natural, t)))
    t = t + 5.0
  }
  out
}

///|
/// That the walk `seen` from `first` to `last` goes one way through its padding (`pad` tall) as its way has it, the
/// row under it with it, at each look.
fn cp_check(
  seen : Array[(Double, Double, Double)],
  first : Double,
  last : Double,
  said : String,
  pad? : Double = 20.0,
) -> Unit raise {
  let mut under_pad = 0
  for i, look in seen {
    let (h, under, way) = look
    assert_true((h - way).abs() < 0.001, msg="\{said}, look \{i}: \{h} tall, its way \{way}")
    assert_true((under - h).abs() < 0.001, msg="\{said}, look \{i}: the row under it at \{under}, it \{h} tall")
    if h > 0.001 && h < pad - 0.001 {
      under_pad = under_pad + 1
    }
    if i > 0 {
      let was = seen[i - 1].0
      assert_true(
        if last > first { h >= was - 0.001 } else { h <= was + 0.001 },
        msg="\{said}, look \{i}: from \{was} to \{h}",
      )
      assert_true((h - was).abs() < 6.0, msg="\{said}, look \{i}: a step from \{was} to \{h}")
    }
  }
  assert_true(under_pad > 2, msg="\{said}: never less tall than its padding on its way, \{under_pad} looks")
  assert_true((seen[0].0 - first).abs() < 0.001, msg="\{said}: \{seen[0].0} as it sets out")
  assert_true((seen[seen.length() - 1].0 - last).abs() < 0.001, msg="\{said}: \{seen[seen.length() - 1].0} at its end")
}

///|
test "an item padded above and below, its height not said, holding a box, coming down a column: its padding comes with it from nothing" {
  for reuse in [false, true] {
    cp_check(cp_walk(cp_item(true, 0.0, 1.0), 40.0, reuse), 0.0, 40.0, "reuse \{reuse}")
  }
}

///|
test "an item padded above and below, its height not said, holding a box, going down a column: its padding goes with it to nothing" {
  for reuse in [false, true] {
    cp_check(cp_walk(cp_item(true, 40.0, 0.0), 40.0, reuse), 40.0, 0.0, "reuse \{reuse}")
  }
}

///|
test "an item padded above and below holding nothing, coming and going down a column: its padding all it is, opening from nothing and closing to it" {
  for reuse in [false, true] {
    cp_check(cp_walk(cp_item(false, 0.0, 1.0), 20.0, reuse), 0.0, 20.0, "coming, reuse \{reuse}")
    cp_check(cp_walk(cp_item(false, 20.0, 0.0), 20.0, reuse), 20.0, 0.0, "going, reuse \{reuse}")
  }
}

///|
/// An item said 6 tall, padded 8 above and 8 below (as tall as its padding at rest, 16), holding nothing.
fn cp_said(from : Double, to : Double) -> @flex.Node {
  let n = @flex.Node::new()
  let s = n.style
  s.set_height(Pt(6.0))
  s.set_padding_top(Pt(8.0))
  s.set_padding_bottom(Pt(8.0))
  s.shrink = 0.0
  cp_way(n, from, to)
  n
}

///|
test "an item said less tall than its padding: at rest as tall as its padding, on its way through less, no step at its ends" {
  let rest = cp_said(16.0, 1.0)
  rest.style.come_now = 0.0 / 0.0
  let (still, _) = cp_column(rest)
  @flex.compute(still, round=false)
  assert_eq(rest.height, 16.0)
  for reuse in [false, true] {
    cp_check(cp_walk(cp_said(0.0, 1.0), 16.0, reuse), 0.0, 16.0, "coming, reuse \{reuse}", pad=16.0)
    cp_check(cp_walk(cp_said(16.0, 0.0), 16.0, reuse), 16.0, 0.0, "going, reuse \{reuse}", pad=16.0)
  }
}
