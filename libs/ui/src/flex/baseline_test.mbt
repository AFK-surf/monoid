// Rows lined up by their items' first lines (Align's Baseline and FirstLineCenter): words of other sizes on one
// baseline, a mark on the middle of the first line of words wrapped beside it, what a container holds lining it up,
// rows wrapped onto lines, and reuse (compute(reuse=true)) laying all of it out as a fresh tree is.

///|
/// Words `len` characters long, 7 wide each, on lines `line` high, their baseline `base` down each line: measured as
/// a node's words are, telling where their first line is (first_line_told).
fn told_words(len : Int, line : Double, base : Double) -> @flex.MeasureFn {
  let full = len.to_double() * 7.0
  fn(width, wm, _h, _hm) {
    let w = match wm {
      Exactly => width
      AtMost => if width < full { width } else { full }
      Undefined => full
    }
    let lines = if w > 0.0 { (full / w).ceil() } else { 1.0 }
    @flex.first_line_told(base, line / 2.0)
    (w, lines * line)
  }
}

///|
fn words_node(len : Int, line : Double, base : Double) -> @flex.Node {
  let n = @flex.Node::new()
  n.measure = Some(told_words(len, line, base))
  n
}

///|
fn box_node(w : Double, h : Double) -> @flex.Node {
  let n = @flex.Node::new()
  n.style.set_width(Pt(w))
  n.style.set_height(Pt(h))
  n
}

///|
fn row_of(align : @flex.Align, items : Array[@flex.Node]) -> @flex.Node {
  let r = @flex.Node::new()
  r.style.direction = Row
  r.style.align_items = align
  for c in items {
    r.add(c)
  }
  r
}

///|
fn close(a : Double, b : Double) -> Bool {
  (a - b).abs() <= 0.01
}

///|
test "baseline: words of two sizes on one baseline, the taller's top at the row's" {
  let big = words_node(10, 24.0, 18.0)
  let small = words_node(10, 16.0, 12.5)
  let root = row_of(Baseline, [big, small])
  @flex.compute(root, width=400.0, round=false)
  assert_true(close(big.top + 18.0, small.top + 12.5))
  assert_eq(big.top, 0.0)
  assert_eq(root.height, 24.0)
}

///|
test "baseline: on the first line of words wrapped onto three, not their last" {
  let wrapped = words_node(60, 20.0, 15.0)
  let meta = words_node(5, 14.0, 10.0)
  meta.style.shrink = 0.0
  wrapped.style.shrink = 1.0
  wrapped.style.grow = 1.0
  wrapped.style.set_basis(Pt(0.0))
  let root = row_of(Baseline, [wrapped, meta])
  @flex.compute(root, width=175.0, round=false)
  assert_eq(wrapped.height, 60.0)
  assert_true(close(wrapped.top + 15.0, meta.top + 10.0))
}

///|
test "baseline: of a column, its first words' (its padding and theirs over them), as a fresh layout puts them" {
  let title = words_node(8, 22.0, 16.0)
  title.style.set_padding_top(Pt(3.0))
  let note = words_node(30, 16.0, 12.0)
  let col = @flex.Node::new()
  col.style.set_padding_top(Pt(5.0))
  col.add(title)
  col.add(note)
  let when = words_node(5, 14.0, 10.5)
  let root = row_of(Baseline, [col, when])
  root.style.set_padding_top(Pt(2.0))
  @flex.compute(root, width=300.0, round=false)
  // (where it is drawn: the column's top, its padding, the title's, its baseline)
  let drawn = col.top + title.top + 3.0 + 16.0
  assert_true(close(drawn, when.top + 10.5))
  assert_true(close(col.top, 2.0))
}

///|
test "baseline: a box holding no words on its foot (Yoga's)" {
  let words = words_node(10, 20.0, 15.0)
  let icon = box_node(10.0, 10.0)
  let root = row_of(Baseline, [words, icon])
  @flex.compute(root, width=300.0, round=false)
  assert_true(close(icon.top + 10.0, words.top + 15.0))
}

///|
test "first line's middle: a mark beside three lines on the first one's middle, never the block's" {
  let mark = box_node(16.0, 16.0)
  let block = words_node(60, 22.0, 16.0)
  block.style.grow = 1.0
  block.style.shrink = 1.0
  block.style.set_basis(Pt(0.0))
  let root = row_of(FirstLineCenter, [mark, block])
  @flex.compute(root, width=176.0, round=false)
  assert_eq(block.height, 66.0)
  assert_true(close(mark.top + 8.0, block.top + 11.0))
  assert_true(close(mark.top, 3.0))
  assert_eq(block.top, 0.0)
  assert_eq(root.height, 66.0)
}

///|
test "first line's middle: a switch taller than the first line, the words moved down to its middle" {
  let switch = box_node(40.0, 30.0)
  let block = words_node(60, 20.0, 15.0)
  block.style.grow = 1.0
  block.style.shrink = 1.0
  block.style.set_basis(Pt(0.0))
  let root = row_of(FirstLineCenter, [block, switch])
  @flex.compute(root, width=200.0, round=false)
  assert_true(close(switch.top + 15.0, block.top + 10.0))
  assert_eq(switch.top, 0.0)
  assert_true(close(block.top, 5.0))
  assert_true(close(root.height, 5.0 + block.height))
}

///|
test "first line's middle: of a column holding a title and a note, its title's" {
  let title = words_node(40, 22.0, 16.0)
  let note = words_node(40, 16.0, 12.0)
  let col = @flex.Node::new()
  col.style.grow = 1.0
  col.style.shrink = 1.0
  col.style.set_basis(Pt(0.0))
  col.add(title)
  col.add(note)
  let icon = box_node(20.0, 20.0)
  let root = row_of(FirstLineCenter, [icon, col])
  @flex.compute(root, width=150.0, round=false)
  assert_true(close(icon.top + 10.0, col.top + title.top + 11.0))
  assert_true(close(icon.top, 1.0))
}

///|
test "baseline: a row wrapped onto two lines, each line's items on its own baseline" {
  let a = words_node(20, 24.0, 18.0)
  let b = words_node(20, 16.0, 12.0)
  let c = words_node(20, 16.0, 12.0)
  let d = words_node(20, 30.0, 22.0)
  let root = row_of(Baseline, [a, b, c, d])
  root.style.wrap = Wrap
  @flex.compute(root, width=300.0, round=false)
  // (two of 140 a line)
  assert_true(close(a.top + 18.0, b.top + 12.0))
  assert_true(close(c.top + 12.0, d.top + 22.0))
  assert_true(c.top >= a.top + 24.0)
}

///|
/// Lays `root` out reusing what it kept, and a fresh copy of it laid out whole: the same layout, point for point.
fn same_as_fresh(root : @flex.Node, w : Double, h : Double, at : String) -> Unit raise {
  @flex.compute(root, width=w, height=h, round=false, reuse=true)
  let f = fresh(root)
  @flex.compute(f, width=w, height=h, round=false)
  same_layout(root, f, at)
}

///|
test "reused: rows lined up by first lines, laid out again as a fresh tree is, their words changed or not" {
  let title = words_node(40, 22.0, 16.0)
  let note = words_node(40, 16.0, 12.0)
  let col = @flex.Node::new()
  col.style.grow = 1.0
  col.style.shrink = 1.0
  col.style.set_basis(Pt(0.0))
  col.add(title)
  col.add(note)
  let icon = box_node(20.0, 20.0)
  let marked = row_of(FirstLineCenter, [icon, col])
  let when = words_node(6, 14.0, 10.5)
  when.style.shrink = 0.0
  let line = row_of(Baseline, [marked, when])
  let root = @flex.Node::new()
  root.add(line)
  same_as_fresh(root, 300.0, 0.0 / 0.0, "first")
  same_as_fresh(root, 300.0, 0.0 / 0.0, "again")
  assert_false(root.laid_out())
  same_as_fresh(root, 180.0, 0.0 / 0.0, "narrower")
  // (the title longer: it and all above it marked, as a view marks them)
  title.measure = Some(told_words(70, 22.0, 16.0))
  for n in [title, col, marked, line, root] {
    n.dirty = true
  }
  same_as_fresh(root, 180.0, 0.0 / 0.0, "longer")
  // (only measured as what holds it is, then laid out with the rest kept: measured_height, as a list measures a row)
  let h = @flex.measured_height(line, 120.0)
  same_as_fresh(root, 180.0, 0.0 / 0.0, "measured between")
  assert_true(h > 0.0)
}

///|
/// Sets items of `n` and under it (`deep`; else `n`'s own alone) aligned by their first lines, at random, and words
/// telling theirs.
fn first_lined(r : Rng, n : @flex.Node, deep? : Bool = true) -> Unit {
  if n.children.length() > 0 {
    match r.below(4) {
      0 => n.style.align_items = Baseline
      1 => n.style.align_items = FirstLineCenter
      _ => ()
    }
  } else if n.measure is Some(_) && r.chance(60) {
    let line = (14 + r.below(16)).to_double()
    n.measure = Some(told_words(r.below(40), line, line * 0.75))
  }
  if r.chance(15) {
    n.style.align_self = if r.chance(50) { Baseline } else { FirstLineCenter }
  }
  if deep {
    for c in n.children {
      first_lined(r, c)
    }
  }
}

///|
/// What of `n`'s style and all under it is a share of what holds it said in points instead: a share of a box as wide as
/// what it holds comes out by the order its sizes are asked in (CSS's cyclic percentages), which lining up by first
/// lines asks in an order of its own.
fn in_points(n : @flex.Node) -> Unit {
  let s = n.style
  let pt = fn(d : @flex.Dim) -> @flex.Dim {
    match d {
      Pct(v) => Pt(v)
      d => d
    }
  }
  s.set_width(pt(s.get_width()))
  s.set_height(pt(s.get_height()))
  s.set_max_width(pt(s.get_max_width()))
  s.set_padding_left(pt(s.get_padding_left()))
  for c in n.children {
    in_points(c)
  }
}

///|
test "reused layouts of trees lined up by first lines are the layouts a fresh tree gets" {
  let r = { s: 777U }
  for t in 0..<400 {
    let root = rand_node(r, 0)
    first_lined(r, root)
    in_points(root)
    let mut w = (200 + r.below(400)).to_double()
    let h = if r.chance(50) { 0.0 / 0.0 } else { (200 + r.below(400)).to_double() }
    same_as_fresh(root, w, h, "tree \{t}")
    for step in 0..<8 {
      let nodes : Array[Array[@flex.Node]] = []
      all_nodes(root, [], nodes)
      let path = nodes[r.below(nodes.length())]
      let n = path[path.length() - 1]
      let what = r.below(3)
      match what {
        0 => w = (150 + r.below(450)).to_double()
        1 => {
          restyle(r, n)
          // (n alone changed: only what is marked changes, as a view marks what changed and all above it)
          first_lined(r, n, deep=false)
          in_points(n)
          for p in path {
            p.dirty = true
          }
        }
        _ =>
          if n.measure is Some(_) {
            let line = (14 + r.below(16)).to_double()
            n.measure = Some(told_words(r.below(40), line, line * 0.8))
            for p in path {
              p.dirty = true
            }
          }
      }
      same_as_fresh(root, w, h, "tree \{t} step \{step} (\{what})")
    }
  }
}

///|
test "rounded: words of two sizes on one baseline, on whole points" {
  let big = words_node(10, 24.0, 18.0)
  let small = words_node(10, 16.0, 12.0)
  let root = row_of(Baseline, [big, small])
  @flex.compute(root, width=400.0)
  assert_eq(big.top + 18.0, small.top + 12.0)
}
