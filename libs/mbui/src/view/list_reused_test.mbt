// A page's list said by one make (View::scrolls_reused): 100 keys of blocks 40 tall in a column 200 tall, every block
// of one kind as no `shape` is said; how many blocks are made as it is scrolled from its top to its foot, what a block
// taken for another key does as it is pressed, what a switch it keeps says by its key, and a key said not to be taken
// (`reuses`) made by the same make.

///|
priv struct ReusedCase {
  tree : @view.Tree
  list : @view.Scroll
  /// how many blocks were made, and for which key each first
  made : Array[Int]
  /// each block made with what says its key now, and its switch
  blocks : Array[(@view.View, () -> Int, @signals.Signal[Bool])]
  /// the keys pressed, in order
  pressed : Array[Int]
  now : Ref[Double]
}

///|
let reused_rows : Int = 100

///|
let reused_row_h : Double = 40.0

///|
let reused_window_h : Double = 200.0

///|
/// The list, its keys 0 … 99; `reuses`: which are taken for another.
fn reused_case(reuses? : (Int) -> Bool = fn(_) { true }) -> ReusedCase {
  let list = @view.Scroll::list()
  let made : Array[Int] = []
  let blocks : Array[(@view.View, () -> Int, @signals.Signal[Bool])] = []
  let pressed : Array[Int] = []
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(reused_window_h))) |> ignore
      o.scrolls_reused(
        list,
        fn() { Array::makei(reused_rows, fn(i) { i }) },
        est=reused_row_h,
        reuses~,
        fn(b, key) {
          made.push(@signals.untracked(key))
          b.height(Is(Some(reused_row_h))).words(By(fn() { "row \{key()}" })) |> ignore
          b.on_press(fn() { pressed.push(key()) }) |> ignore
          blocks.push((b, key, b.reused_bool()))
        },
      )
      |> ignore
    })
    |> ignore
  })
  let c = { tree, list, made, blocks, pressed, now: Ref(0.0) }
  c.draw()
  c
}

///|
fn ReusedCase::draw(self : ReusedCase) -> Unit {
  self.now.val = self.now.val + 16.0
  self.tree.frame(390.0, 844.0, now=self.now.val) |> ignore
}

///|
/// The list scrolled to `y`, drawn.
fn ReusedCase::at_y(self : ReusedCase, y : Double) -> Unit {
  self.list.put(y)
  self.draw()
  self.draw()
}

///|
/// The block that shows key `k` now: alive, held by its slot.
fn ReusedCase::of(self : ReusedCase, k : Int) -> (@view.View, () -> Int, @signals.Signal[Bool]) {
  match self.blocks.search_by(fn(b) { b.0.alive() && b.0.parent() is Some(_) && @signals.untracked(b.1) == k }) {
    Some(i) => self.blocks[i]
    None => @halt.saying("no block shows key \{k}")
  }
}

///|
/// Key `k`'s block pressed where it shows.
fn ReusedCase::press(self : ReusedCase, k : Int) -> Unit {
  let (x, y, w, h) = self.of(k).0.rect()
  self.tree.press(x + w / 2.0, y + h / 2.0) |> ignore
  self.draw()
}

///|
test "scrolls_reused: scrolled from its top to its foot a block at a time, as many blocks made as show round what shows, no more" {
  let c = reused_case()
  let first = c.made.length()
  let mut y = 0.0
  let foot = reused_rows.to_double() * reused_row_h - reused_window_h
  while y < foot {
    y = y + reused_row_h
    c.at_y(y)
  }
  // (what shows at its foot is its last keys, each drawn by its key)
  let drawn = match c.tree.drawn_of(c.of(reused_rows - 1).0.id()) {
    Some(d) => d.words
    None => ""
  }
  // (what shows and a screen over and under it (slots_margin), and those put by: a few screens, never the 100)
  assert_true(c.made.length() <= first + 8, msg="made \{c.made.length()} from \{first}")
  assert_true(c.made.length() < 30, msg="made \{c.made.length()}")
  assert_eq(drawn, "row \{reused_rows - 1}")
}

///|
test "scrolls_reused: a block taken for a key that came to show pressed says that key, never the one it was made for" {
  let c = reused_case()
  c.at_y(60.0 * reused_row_h)
  // (key 62's block was made for a key near the top and taken for it)
  let (_, key, _) = c.of(62)
  let made_for = c.made[c.blocks.search_by(fn(b) { physical_equal(b.1, key) }).unwrap()]
  c.press(62)
  c.press(61)
  assert_eq((made_for < 30, c.pressed), (true, [62, 61]))
}

///|
test "scrolls_reused: a switch a block keeps is its key's, its default for a key it is taken for, back as that key comes back" {
  let c = reused_case()
  c.of(1).2.set(true)
  c.draw()
  c.at_y(60.0 * reused_row_h)
  // (every block that shows now taken for keys never switched)
  let off = [60, 61, 62].map(fn(k) { c.of(k).2.untracked() })
  c.at_y(0.0)
  assert_eq((off, c.of(1).2.untracked(), c.of(2).2.untracked()), ([false, false, false], true, false))
}

///|
test "scrolls_reused: a key said not to be taken made by the same make, given its key alone, made again as it comes back" {
  let c = reused_case(reuses=fn(k) { k != 0 })
  let zero_first = c.made.filter(fn(k) { k == 0 }).length()
  c.at_y(60.0 * reused_row_h)
  c.at_y(0.0)
  // (key 0 made twice, by the make the rest are; pressed, it says its key)
  c.press(0)
  assert_eq((zero_first, c.made.filter(fn(k) { k == 0 }).length(), c.pressed), (1, 2, [0]))
}
