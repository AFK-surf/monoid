// A page's list's blocks as they are counted (list_window.mbt's Column): where each one's top is, and which is the
// first whose foot is past a place, a function of the heights as they are now and of how many there are, the same to
// the bit whatever order they were measured in, and after a height changed and changed back as if it never had.

///|
/// Key `k`'s height: no binary fraction.
fn heights_of(k : Int) -> Double {
  match k % 4 {
    0 => 40.0 * 1.3
    1 => 51.7
    2 => 63.1
    _ => 22.9
  }
}

///|
/// A column of `n` keys counted 80 each, then told each one's height in the order `order` says, on the grid `g`.
fn heights_told(n : Int, order : Array[Int], g : Double) -> Column[Int] {
  let c : Column[Int] = Column::new()
  c.fill(Array::makei(n, fn(i) { i }), Array::make(n, (rows_slot_on(80.0, g), false)), g)
  for k in order {
    c.set(k, rows_slot_on(heights_of(k), g), true)
  }
  c
}

///|
/// Each top's bits, and the first past each of a sweep of places (and just either side of each top).
fn heights_read(c : Column[Int]) -> (Array[Int64], Array[Int]) {
  let tops = Array::makei(c.length(), fn(i) { c.top(i).reinterpret_as_int64() })
  let pasts = []
  let mut y = -3.0
  while y < c.top(c.length() - 1) + 100.0 {
    pasts.push(c.first_past(y))
    y = y + 7.3
  }
  for i in 0..<c.length() {
    let t = c.top(i)
    pasts.push(c.first_past(t))
    pasts.push(c.first_past(t - 0.000001))
    pasts.push(c.first_past(t + 0.000001))
  }
  (tops, pasts)
}

///|
test "a list's blocks' heights told first to last, last to first and shuffled: every top and every first past a place the same to the bit, on no grid, on 2.75 and on 3.5" {
  for g in [0.0, 2.75, 3.5] {
    for n in [1, 2, 3, 300, 1500] {
      let down = heights_read(heights_told(n, Array::makei(n, fn(i) { i }), g))
      let up = heights_read(heights_told(n, Array::makei(n, fn(i) { n - 1 - i }), g))
      let shuffled = heights_read(heights_told(n, Array::makei(n, fn(i) { i * 7919 % n }), g))
      assert_true(down == up, msg="on \{g}, \{n} keys: told last to first")
      assert_true(down == shuffled, msg="on \{g}, \{n} keys: told shuffled")
    }
  }
}

///|
test "a list's block's height changed and changed back: every top and every first past a place as if it never had, to the bit" {
  for g in [0.0, 2.75, 3.5] {
    let n = 300
    let kept = heights_told(n, Array::makei(n, fn(i) { i }), g)
    let moved = heights_told(n, Array::makei(n, fn(i) { i }), g)
    for k in [0, 7, 150, 299] {
      moved.set(k, rows_slot_on(heights_of(k) + 17.31, g), true)
      moved.set(k, rows_slot_on(80.0, g), false)
    }
    for k in [0, 7, 150, 299] {
      moved.set(k, rows_slot_on(heights_of(k), g), true)
    }
    assert_true(heights_read(kept) == heights_read(moved), msg="on \{g}: changed and changed back")
  }
}

///|
test "a list's blocks counted: on a grid each top the grid's own number for its pixel, each foot no higher than the next one's" {
  for g in [2.75, 3.5] {
    let c = heights_told(1500, Array::makei(1500, fn(i) { i * 7919 % 1500 }), g)
    let off = []
    for i in 0..<c.length() {
      let t = c.top(i)
      if t.reinterpret_as_int64() != ((t * g).round() / g).reinterpret_as_int64() {
        off.push((i, t))
      }
      if i + 1 < c.length() && c.top(i + 1) < t + c.hs[i] - 0.000001 {
        off.push((i, t))
      }
    }
    assert_eq(off, [], msg="on \{g}")
  }
}

///|
/// Column `c` filled again for `keys` as the list fills it (View::scrolls_window's `laid`): kept up to the first key
/// that is another, each height from there put anew.
fn heights_refilled(c : Column[Int], keys : Array[Int], g : Double) -> Unit {
  let p = c.refill(keys, g)
  for i in p..<keys.length() {
    c.put(i, rows_slot_on(heights_of(keys[i]), g), true)
  }
  c.summed()
}

///|
/// A column filled whole for `keys`, each its height.
fn heights_whole(keys : Array[Int], g : Double) -> Column[Int] {
  let c : Column[Int] = Column::new()
  c.fill(keys, keys.map(fn(k) { (rows_slot_on(heights_of(k), g), true) }), g)
  c
}

///|
test "a list's keys changed, kept up to the first that is another: after appends, a page put before the first, one replaced and one taken out, every top and every first past a place as filled whole, to the bit" {
  for g in [0.0, 2.75, 3.5] {
    let c : Column[Int] = Column::new()
    let mut keys = Array::makei(500, fn(i) { i })
    heights_refilled(c, keys, g)
    let wrong = []
    // (one at a time past 512, where the tree grows a level)
    for a in 500..<520 {
      keys = keys + [a]
      heights_refilled(c, keys, g)
      if heights_read(c) != heights_read(heights_whole(keys, g)) {
        wrong.push("appended \{a}")
      }
    }
    keys = Array::makei(50, fn(i) { -50 + i }) + keys
    heights_refilled(c, keys, g)
    if heights_read(c) != heights_read(heights_whole(keys, g)) {
      wrong.push("a page put before the first")
    }
    keys = keys.mapi(fn(i, k) { if i == 260 { 10000 } else { k } })
    heights_refilled(c, keys, g)
    if heights_read(c) != heights_read(heights_whole(keys, g)) {
      wrong.push("one replaced in the middle")
    }
    keys = keys.filter(fn(k) { k != 100 })
    heights_refilled(c, keys, g)
    if heights_read(c) != heights_read(heights_whole(keys, g)) {
      wrong.push("one taken out")
    }
    keys = keys.filter(fn(k) { k < 400 })
    heights_refilled(c, keys, g)
    if heights_read(c) != heights_read(heights_whole(keys, g)) {
      wrong.push("its last ones taken out, the tree a level less")
    }
    assert_eq(wrong, [], msg="on \{g}")
  }
}

///|
/// All of it again: `keys`, each with its height as laid out on the grid of `g` pixels a point and whether it was laid
/// out.
fn[K : Eq] Column::fill(self : Column[K], keys : Array[K], hs : Array[(Double, Bool)], g : Double) -> Unit {
  self.refill(keys, g, whole=true) |> ignore
  for i, h in hs {
    self.put(i, h.0, h.1)
  }
  self.summed()
}

///|
/// A list of `n` keys in a box 300 wide and `box` tall on grid `g`, counted 30 each, each row as tall as `tall` says
/// with the words of its key, its blocks made each its own or of one kind another takes (`reused`), `first` brought
/// to its top before its first frame: the tree.
fn heights_list(n : Int, tall : (Int) -> Double, g : Double, reused : Bool, first? : Int, box? : Double = 200.0) -> Tree {
  let place : ListPlace[Int] = ListPlace::new()
  let row = fn(b : View, k : () -> Int) {
    b.box(fn(l) { l.height(By(fn() { Some(tall(k())) })).words(By(fn() { "row \{k()}" })) |> ignore }) |> ignore
  }
  let tree = Tree::new(
    fn(root) {
      root.box(fn(o) {
        o.width(Is(Some(300.0))).height(Is(Some(box))) |> ignore
        if reused {
          o.scrolls_window(
            Scroll::list(),
            fn() { Array::makei(n, fn(i) { i }) },
            est=30.0,
            place~,
            fn(_, _) { @halt.saying("every block is of a kind another may take") },
            reused=fn(_) { Some(0) },
            make_reused=row,
          )
          |> ignore
        } else {
          o.scrolls_window(Scroll::list(), fn() { Array::makei(n, fn(i) { i }) }, est=30.0, place~, fn(b, k) {
            row(b, fn() { k })
          })
          |> ignore
        }
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  if g > 0.0 {
    tree.set_rows_grid(g)
  }
  if first is Some(k) {
    place.bring(k)
  }
  tree.frame(390.0, 844.0) |> ignore
  tree.frame(390.0, 844.0) |> ignore
  tree
}

///|
/// The rows drawn in the list's box, top down: each one's key, where its top is and how tall it is drawn.
fn heights_rows(t : Tree, box? : Double = 200.0) -> Array[(Int, Double, Double)] {
  let out = []
  for d in t.drawn() {
    if d.words.has_prefix("row ") && d.y + d.h > 1.0e-6 && d.y < box - 1.0e-6 {
      let mut k = 0
      for ch in d.words.exact_view(start=4, end=d.words.length()) {
        k = k * 10 + (ch.to_int() - '0'.to_int())
      }
      out.push((k, d.y, d.h))
    }
  }
  out.sort_by(fn(a, b) { a.1.compare(b.1) })
  out
}

///|
/// One turn of the wheel `dy` down at moment `at`, drawn: how many passes of its fill that took.
fn heights_wheeled(t : Tree, dy : Double, at : Double) -> Int {
  let p0 = fill_passes.val
  t.wheel_at(150.0, 100.0, 0.0, dy, 0, at) |> ignore
  t.frame(390.0, 844.0) |> ignore
  fill_passes.val - p0
}

///|
/// What is wrong with rows `rows` as drawn on grid `g`: one not where the one over it ends, by `tall`, or the box not
/// covered from its top to its foot.
fn heights_unjoined(
  rows : Array[(Int, Double, Double)],
  tall : (Int) -> Double,
  g : Double,
  box? : Double = 200.0,
) -> Array[String] {
  let wrong = []
  if rows.is_empty() || rows[0].1 > 1.0e-6 || rows[rows.length() - 1].1 + rows[rows.length() - 1].2 < box - 1.0e-6 {
    wrong.push("the box not covered: \{Repr(rows)}")
  }
  for i in 1..<rows.length() {
    let (k, y, _) = rows[i - 1]
    if rows[i].0 != k + 1 || (rows[i].1 - (y + rows_slot_on(tall(k), g))).abs() > 1.0e-6 {
      wrong.push("row \{rows[i].0} at \{rows[i].1} under row \{k} at \{y}")
    }
  }
  wrong
}

///|
/// Key `k`'s height where its rows are of several heights, none as tall as they are counted (30).
fn heights_several(k : Int) -> Double {
  match k % 4 {
    0 => 22.1
    1 => 31.7
    2 => 40.0 * 1.3
    _ => 27.3
  }
}

///|
test "a page's list of rows as tall as it counts them, wheeled five rows on at once into rows never measured: its fill makes and measures them a pass each, none after the last, each where it is scrolled there again" {
  let wrong = []
  for g in [0.0, 2.75, 3.5] {
    for reused in [false, true] {
      let said = "on \{g}, reused \{reused}"
      let t = heights_list(1500, fn(_) { 30.0 }, g, reused, box=400.0)
      // (down, five rows come in at once, never measured, within the slots round what showed; five more, near where its
      // slots end, as they are found again)
      let p1 = heights_wheeled(t, 150.0, 10.0)
      let came = heights_rows(t, box=400.0)
      let p2 = heights_wheeled(t, 150.0, 20.0)
      if p1 != 5 || p2 != 5 {
        wrong.push("\{said}: passes of its fill \{p1} and \{p2}")
      }
      wrong.append(heights_unjoined(came, fn(_) { 30.0 }, g, box=400.0).map(fn(w) { "\{said}: \{w}" }))
      // (back where the first five came in, all of it measured now: drawn as it was as they first came, no pass of its
      // fill for what it measured)
      let p3 = heights_wheeled(t, -150.0, 30.0)
      let again = heights_rows(t, box=400.0)
      if again != came {
        wrong.push("\{said}: scrolled there again \{Repr(again)} where it first came \{Repr(came)}")
      }
      if p3 != 0 {
        wrong.push("\{said}: back over them measured, passes of its fill \{p3}")
      }
    }
  }
  assert_eq(wrong, [])
}

///|
/// Key `k`'s height where its rows are as tall as they are counted (30) but every seventh, 52.
fn heights_mostly(k : Int) -> Double {
  if k % 7 == 3 {
    52.0
  } else {
    30.0
  }
}

///|
/// What is wrong after one turn of the wheel `dy` from `before`: a row seen before and after not moved as far as the
/// wheel, or the rows drawn not one under another from the top of the box to its foot.
fn heights_moved(
  before : Array[(Int, Double, Double)],
  after : Array[(Int, Double, Double)],
  dy : Double,
  tall : (Int) -> Double,
  g : Double,
  box : Double,
) -> Array[String] {
  let wrong = []
  for r in after {
    match before.search_by(fn(b) { b.0 == r.0 }) {
      Some(i) if (before[i].1 - dy - r.1).abs() > 1.0e-6 => wrong.push("row \{r.0} from \{before[i].1} to \{r.1}")
      _ => ()
    }
  }
  wrong.append(heights_unjoined(after, tall, g, box~))
  wrong
}

///|
test "a page's list wheeled at once into rows never measured, down from its top and up from a key brought to its top, its rows of one height but some, or all of several: what was seen moved as far as the wheel, none missing, none over another, as when scrolled there again" {
  let wrong = []
  for g in [0.0, 3.5] {
    for reused in [false, true] {
      for heights in [("mostly", heights_mostly), ("several", heights_several)] {
        let (name, tall) = heights
        for down in [true, false] {
          for box in [200.0, 400.0] {
            let said = "on \{g}, reused \{reused}, \{name}, down \{down}, \{box} tall"
            let t = if down {
              heights_list(1500, tall, g, reused, box~)
            } else {
              heights_list(1500, tall, g, reused, first=600, box~)
            }
            let dy = if down { 144.0 } else { -144.0 }
            let before = heights_rows(t, box~)
            heights_wheeled(t, dy, 10.0) |> ignore
            let after = heights_rows(t, box~)
            wrong.append(heights_moved(before, after, dy, tall, g, box).map(fn(w) { "\{said}: \{w}" }))
            // (past it and back, all of it measured: drawn as it was)
            heights_wheeled(t, dy, 20.0) |> ignore
            heights_wheeled(t, -dy, 30.0) |> ignore
            let again = heights_rows(t, box~)
            if again != after {
              wrong.push("\{said}: scrolled there again \{Repr(again)} where it first came \{Repr(after)}")
            }
          }
        }
      }
    }
  }
  assert_eq(wrong, [])
}
