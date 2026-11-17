// What the parts of a page's list's blocks taken for other keys keep (View::scrolls_window's `reused`,
// reused_state.mbt): blocks of 100, two rows that scroll across in each (300 wide, what they hold 600), a switch kept by
// its key (View::reused_bool) and what is done as one is taken for another key (View::on_reused); what each key's block
// shows as it is taken for another, and as its key comes back.

///|
/// A block's parts: its two rows that scroll across, its switch, how many times it was taken for another key.
priv struct RsParts {
  v : View
  key : () -> Int
  a : Scroll
  b : Scroll
  on : @signals.Signal[Bool]
  reused : Ref[Int]
}

///|
priv struct RsCase {
  tree : Tree
  list : Scroll
  /// its keys
  keys : @signals.Signal[Array[Int]]
  /// how tall its window is
  h : Double
  made : Ref[Int]
  parts : Array[RsParts]
  /// the moment of its last frame
  now : Ref[Double]
}

///|
/// `n` keys of blocks 100 tall in a list `h` tall.
fn rs_case(n : Int, h : Double) -> RsCase {
  let list = Scroll::list()
  let keys = @signals.signal(Array::makei(n, fn(i) { i }))
  let made = Ref(0)
  let parts : Array[RsParts] = []
  let tree = Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(h))) |> ignore
      o.scrolls_window(
        list,
        fn() { keys.get() },
        est=100.0,
        fn(_, _) { @halt.saying("every block is of a kind another may take") },
        reused=fn(_) { Some(0) },
        make_reused=fn(v, key) {
          made.val = made.val + 1
          v.height(Is(Some(100.0))) |> ignore
          let a = Scroll::across()
          let b = Scroll::across()
          let on : Ref[@signals.Signal[Bool]?] = Ref(None)
          let reused = Ref(0)
          v.box(fn(head) {
            head.height(Is(Some(20.0))) |> ignore
            on.val = Some(head.reused_bool())
            head.on_reused(fn() { reused.val = reused.val + 1 })
          })
          |> ignore
          for s in [a, b] {
            v.box(fn(row) {
              row.width(Is(Some(300.0))).height(Is(Some(40.0))) |> ignore
              row.scrolls(s, fn(held) { held.box(fn(w) { w.width(Is(Some(600.0))).height(Is(Some(40.0))) |> ignore }) |> ignore })
              |> ignore
            })
            |> ignore
          }
          parts.push({ v, key, a, b, on: on.val.unwrap(), reused })
        },
      )
      |> ignore
    })
    |> ignore
  })
  let c = { tree, list, keys, h, made, parts, now: Ref(0.0) }
  c.draw()
  c
}

///|
fn RsCase::draw(self : RsCase) -> Unit {
  self.now.val = self.now.val + 16.0
  self.tree.frame(390.0, self.h + 200.0, now=self.now.val) |> ignore
}

///|
/// The list scrolled to key `k`'s top, drawn.
fn RsCase::to(self : RsCase, k : Int) -> Unit {
  self.list.put(k.to_double() * 100.0)
  self.draw()
  self.draw()
}

///|
/// Its frames drawn on till `ms` from now, as a host draws them.
fn RsCase::run_for(self : RsCase, ms : Double) -> Unit {
  let end = self.now.val + ms
  while self.now.val < end {
    self.draw()
  }
}

///|
/// The list scrolled to `y`, drawn.
fn RsCase::at_y(self : RsCase, y : Double) -> Unit {
  self.list.put(y)
  self.draw()
  self.draw()
}

///|
/// The parts of the block that shows key `k` now: of a block alive, held by its slot.
fn RsCase::of(self : RsCase, k : Int) -> RsParts {
  match self.parts.search_by(fn(p) { p.v.alive() && p.v.parent() is Some(_) && @signals.untracked(p.key) == k }) {
    Some(i) => self.parts[i]
    None => @halt.saying("no block shows key \{k}")
  }
}

///|
/// What key `k`'s block shows of its parts: how far each row is scrolled, and its switch.
fn RsCase::shows(self : RsCase, k : Int) -> (Double, Double, Bool) {
  let p = self.of(k)
  (p.a.at(self.tree), p.b.at(self.tree), p.on.untracked())
}

///|
test "reused block: its rows scrolled and its switch its key's, at their start for the key it is taken for, back as its key comes back" {
  let c = rs_case(40, 100.0)
  let first = c.of(0)
  first.a.put(120.0)
  first.on.set(true)
  c.draw()
  assert_eq(c.shows(0), (120.0, 0.0, true))
  assert_eq(first.reused.val, 0)
  let made = c.made.val
  // (scrolled to key 10: its block one taken from those put by, none made)
  c.to(10)
  let ten = c.of(10)
  assert_eq(c.made.val, made, msg="none made")
  assert_true(ten.reused.val >= 1, msg="taken for another key")
  assert_eq(c.shows(10), (0.0, 0.0, false))
  // (the block that showed key 0, whichever it shows now: none of key 0's)
  if first.v.alive() && first.v.parent() is Some(_) {
    assert_true(@signals.untracked(first.key) != 0)
    assert_eq((first.a.at(c.tree), first.on.untracked()), (0.0, false))
  }
  // (back at key 0: as it was left)
  c.to(0)
  assert_eq(c.shows(0), (120.0, 0.0, true))
  // (a block taken for the key it showed is not told it was taken for another)
  let zero = c.of(0)
  let told = zero.reused.val
  c.to(0)
  assert_eq(zero.reused.val, told)
}

///|
test "reused block: of two rows that scroll in it, each its own, the one scrolled not the other" {
  let c = rs_case(40, 100.0)
  c.of(0).b.put(90.0)
  c.draw()
  c.to(20)
  assert_eq(c.shows(20), (0.0, 0.0, false))
  c.to(0)
  assert_eq(c.shows(0), (0.0, 90.0, false))
}

///|
test "reused block: a fling under way stopped where it is as its block leaves its key, nothing going on out of sight" {
  let c = rs_case(40, 100.0)
  let p = c.of(0)
  // (flung across, a second's way: on it still as the list leaves it)
  let t = c.tree.logic_said()
  p.a.fling.set(Some({ x0: 0.0, v0: 1.0, t0: t, end_t: t + 1000.0, end_x: 250.0, till: 300.0, way: None }))
  c.draw()
  c.draw()
  c.to(10)
  // (as the list comes back, where it was stopped: nothing on its way, no further as time goes)
  c.to(0)
  let back = c.of(0)
  let at = c.shows(0).0
  for _ in 0..<10 {
    c.draw()
  }
  assert_true(back.a.fling.untracked() is None)
  assert_true(at > 0.5 && at < 250.0, msg="stopped at \{at}")
  assert_eq(c.shows(0).0, at)
}

///|
test "reused block: a key whose block was let go (more put by than are kept) given what it kept as one is made for it anew" {
  // (ten show at once: scrolled a whole window on, ten put by, four kept, six let go)
  let c = rs_case(60, 1000.0)
  for k in 0..<10 {
    let p = c.of(k)
    p.a.put(10.0 * (k + 1).to_double())
    if k % 2 == 0 {
      p.on.set(true)
    }
  }
  c.draw()
  c.to(30)
  let made = c.made.val
  c.to(0)
  assert_true(c.made.val > made, msg="some made anew")
  let shown = Array::makei(10, fn(k) { c.shows(k) })
  assert_eq(shown, Array::makei(10, fn(k) { (10.0 * (k + 1).to_double(), 0.0, k % 2 == 0) }))
}

///|
test "reused block: what a list keeps of its keys kept to the last 256 that kept anything, those as made keeping nothing" {
  let c = rs_case(320, 1000.0)
  let kept = fn() {
    match c.tree.reused_slots.values().head() {
      Some(rs) => (rs.kept_keys)()
      None => -1
    }
  }
  // (a window at a time, each key that shows switched on)
  for page in 0..<31 {
    c.to(page * 10)
    for k in (page * 10)..<(page * 10 + 10) {
      c.of(k).on.set(true)
    }
  }
  c.to(310)
  assert_eq(kept(), 256)
  // (the last kept as they were; the first let go of: as made)
  c.to(200)
  assert_eq(c.shows(205).2, true)
  c.to(0)
  assert_eq(c.shows(5).2, false)
  // (switched back off: nothing kept of it)
  c.of(5).on.set(true)
  c.to(100)
  let with5 = kept()
  c.to(0)
  c.of(5).on.set(false)
  c.to(100)
  assert_eq(kept(), with5 - 1)
}

///|
test "reused block: the list put far off at once, its slots round key 0 left behind, key 0 as it was left as the list is put back" {
  // (two show at once: put 150 keys on in one frame)
  let c = rs_case(200, 200.0)
  let p = c.of(0)
  p.a.put(120.0)
  p.on.set(true)
  c.draw()
  c.to(150)
  assert_true(@signals.untracked(p.key) != 0 || !p.v.alive(), msg="key 0 shown no more")
  c.to(0)
  assert_eq(c.shows(0), (120.0, 0.0, true))
}

///|
test "reused block: its keys filtered (none of them, or others) and back, the block that showed key 0 let go with its slot, key 0 as it was left" {
  for others in [false, true] {
    let c = rs_case(20, 200.0)
    let p = c.of(0)
    p.a.put(120.0)
    p.on.set(true)
    c.draw()
    // (key 0 gone from its keys while it shows: its slot let go with the block once its way out ends, the block never
    // left what shows first)
    c.keys.set(if others { Array::makei(10, fn(i) { 10 + i }) } else { [] })
    c.run_for(@flex.move_most_ms)
    assert_true(!p.v.alive(), msg="key 0's block let go with its slot (others \{others})")
    // (back: what comes in made its way in, then the list put at its top)
    c.keys.set(Array::makei(20, fn(i) { i }))
    c.run_for(@flex.move_most_ms)
    c.to(0)
    c.run_for(@flex.move_most_ms)
    let showing = c.parts.filter(fn(q) { q.v.alive() && q.v.parent() is Some(_) }).map(fn(q) { @signals.untracked(q.key) })
    guard showing.contains(0) else { fail("others \{others}: key 0 shown by none, \{Repr(showing)} at \{c.list.at(c.tree)}") }
    assert_eq(c.shows(0), (120.0, 0.0, true), msg="others \{others}")
  }
}

///|
test "reused block: one put by before a key it showed was let go of (past the last 256 kept) taken for another brings that key back not" {
  // (two show at once, three where the list is half a block on)
  let c = rs_case(400, 200.0)
  c.at_y(50.0)
  let p = c.of(0)
  p.on.set(true)
  // (key 0's block put by, none coming for it: under those put by and taken again as the list goes on a block at a
  // time, each key that comes switched on: key 0 let go of past the last 256)
  c.at_y(100.0)
  for k in 2..<300 {
    c.at_y(k.to_double() * 100.0)
    c.of(k + 1).on.set(true)
  }
  assert_eq(@signals.untracked(p.key), 0)
  assert_eq(p.reused.val, 0)
  // (three show: key 0's block taken for the one that comes)
  c.at_y(299.0 * 100.0 + 50.0)
  assert_eq((@signals.untracked(p.key), p.reused.val), (301, 1))
  // (back at key 0: as made, nothing of it kept)
  c.to(0)
  assert_eq(c.shows(0), (0.0, 0.0, false))
}
