// View::switch_by: what is switched by who it is takes its place at once down a column, from nothing (0) to something
// and between two of different heights, no way set out (View::comes) and what is under it where it ends at once; a
// plain `pick` there makes its way (the contrast, so the test holds what it says).

///|
/// 下's top as the tree is drawn now; none: -1.
fn sb_y(t : @view.Tree, w : String) -> Double {
  let found = t.drawn().filter(fn(d) { d.words == w })
  if found.length() == 0 {
    -1.0
  } else {
    found[0].y
  }
}

///|
/// 上 (20 tall), what `which` says (0: nothing, 1: 40 tall, 2: 90 tall) switched by it or picked, 下 (20 tall); no gap.
fn sb_tree(which : @signals.Signal[Int], switched : Bool) -> @view.Tree {
  @view.Tree::new(sources=true, fn(root) {
    root.box(fn(b) { b.height(Is(Some(20.0))).words(Is("上")) |> ignore }) |> ignore
    root.box(fn(b) {
      let make = fn(v : @view.View, k : Int) {
        match k {
          1 => v.box(fn(n) { n.height(Is(Some(40.0))).words(Is("一")) |> ignore }) |> ignore
          2 => v.box(fn(n) { n.height(Is(Some(90.0))).words(Is("二")) |> ignore }) |> ignore
          _ => ()
        }
      }
      if switched {
        b.switch_by(fn() { which.get() }, make)
      } else {
        b.pick(fn() { which.get() }, make)
      }
    })
    |> ignore
    root.box(fn(b) { b.height(Is(Some(20.0))).words(Is("下")) |> ignore }) |> ignore
  })
}

///|
/// `which` set to `to` at `at` ms; 下's top drawn then and at each frame of 120 a second for 400 ms after, and whether
/// any way was set out meanwhile or is on its way at the switch's frame.
fn sb_switch(t : @view.Tree, which : @signals.Signal[Int], to : Int, at : Double) -> (Array[Double], Bool) {
  t.ways_set_out() |> ignore
  t.event(at, fn() { which.set(to) })
  let ys = []
  let mut moved = false
  // (each frame of 120 a second from the switch till 400 ms after it)
  let mut ms = at
  while ms <= at + 400.0 {
    t.at(ms)
    t.frame(390.0, 844.0) |> ignore
    ys.push(sb_y(t, "下"))
    if ms == at && t.ways_end() >= 0.0 {
      moved = true
    }
    ms = ms + 1000.0 / 120.0
  }
  if t.ways_set_out().length() > 0 {
    moved = true
  }
  (ys, moved)
}

///|
test "switch_by down a column: nothing to something, and between two of different heights, at once, no way set out" {
  let which = @signals.signal(0, same=fn(a, b) { a == b })
  let t = sb_tree(which, true)
  t.frame(390.0, 844.0) |> ignore
  assert_eq(sb_y(t, "下"), 20.0)
  // (from nothing: 0 → 40)
  let (ys, moved) = sb_switch(t, which, 1, 100.0)
  assert_false(moved)
  assert_true(ys.iter().all(fn(y) { y == 60.0 }))
  // (40 → 90)
  let (ys, moved) = sb_switch(t, which, 2, 1000.0)
  assert_false(moved)
  assert_true(ys.iter().all(fn(y) { y == 110.0 }))
  // (90 → 40)
  let (ys, moved) = sb_switch(t, which, 1, 2000.0)
  assert_false(moved)
  assert_true(ys.iter().all(fn(y) { y == 60.0 }))
  // (back to nothing)
  let (ys, moved) = sb_switch(t, which, 0, 3000.0)
  assert_false(moved)
  assert_true(ys.iter().all(fn(y) { y == 20.0 }))
  t.dispose()
}

///|
test "pick in the same place makes its way from nothing: what switch_by takes away" {
  let which = @signals.signal(0, same=fn(a, b) { a == b })
  let t = sb_tree(which, false)
  t.frame(390.0, 844.0) |> ignore
  let (ys, moved) = sb_switch(t, which, 1, 100.0)
  assert_true(moved)
  // (on its way: under its end at first, there at its end)
  assert_true(ys[0] < 60.0)
  assert_eq(ys[ys.length() - 1], 60.0)
  t.dispose()
}
