// What a column shows (View::show) or picks (View::pick) padded above and below, its height not said: as it comes and
// goes its padding comes and goes with what it holds, never held at its padding till its way ends then gone at once.
// 上 (20 tall), a row padded 8 above and 8 below holding 中 (20 tall) while `on` says so, 下 (20 tall), 10 apart.

///|
/// The word drawn `w`'s top (y), as the tree is drawn now; none: -1.
fn cpv_y(t : @view.Tree, w : String) -> Double {
  let found = t.drawn().filter(fn(d) { d.words == w })
  if found.length() == 0 {
    -1.0
  } else {
    found[0].y
  }
}

///|
/// 上, the row padded 8 above and below holding 中 while `on` says so, 下; 10 apart.
fn cpv_tree(on : @signals.Signal[Bool]) -> @view.Tree {
  @view.Tree::new(fn(col) {
    col.gap(Is(10.0)) |> ignore
    col.box(fn(b) { b.height(Is(Some(20.0))).words(Is("上")) |> ignore }) |> ignore
    col.show(fn() { on.get() }, fn(s) {
      s.row(Is(true)).padding(Is((0.0, 8.0, 0.0, 8.0))) |> ignore
      s.box(fn(b) { b.height(Is(Some(20.0))).words(Is("中")) |> ignore }) |> ignore
    })
    col.box(fn(b) { b.height(Is(Some(20.0))).words(Is("下")) |> ignore }) |> ignore
  })
}

///|
/// 下's top at each frame of 120 a second from `from` to `to` ms (both drawn).
fn cpv_frames(t : @view.Tree, from : Double, to : Double) -> Array[Double] {
  let out = []
  let mut k = 0
  while true {
    let ms = from + k.to_double() * 1000.0 / 120.0
    let ms = if ms > to { to } else { ms }
    t.at(ms)
    t.frame(390.0, 844.0) |> ignore
    out.push(cpv_y(t, "下"))
    if ms >= to {
      break
    }
    k = k + 1
  }
  out
}

///|
/// The most `ys` moves from one frame to the next.
fn cpv_most_step(ys : Array[Double]) -> Double {
  let mut most = 0.0
  for i in 1..<ys.length() {
    let d = (ys[i] - ys[i - 1]).abs()
    if d > most {
      most = d
    }
  }
  most
}

///|
/// How many of `ys` are where the row is less tall than its padding (16), on its way: 下 between `none` (where it is
/// with the row gone) and 16 under that.
fn cpv_in_pad(ys : Array[Double], none? : Double = 30.0) -> Int {
  ys.filter(fn(y) { y > none + 0.01 && y < none + 16.0 - 0.01 }).length()
}

///|
test "a padded row shown going: its padding goes with what it holds, down to nothing, no step at its end" {
  let on = @signals.signal(true, same=fn(a, b) { a == b })
  let t = cpv_tree(on)
  t.frame(390.0, 844.0) |> ignore
  // (20 + 10, 8 + 20 + 8, 10)
  assert_eq(cpv_y(t, "中"), 38.0)
  assert_eq(cpv_y(t, "下"), 76.0)
  t.event(100.0, fn() { on.set(false) })
  let ys = cpv_frames(t, 100.0, 900.0)
  assert_eq(ys[0], 76.0)
  assert_eq(ys[ys.length() - 1], 30.0)
  for i in 1..<ys.length() {
    assert_true(ys[i] <= ys[i - 1], msg="closes only: \{Repr(ys)}")
  }
  let most = cpv_most_step(ys)
  assert_true(most < 12.0, msg="no step: the most a frame \{most}, \{Repr(ys)}")
  assert_true(cpv_in_pad(ys) > 2, msg="through less than its padding: \{Repr(ys)}")
  assert_eq(cpv_y(t, "中"), -1.0)
  assert_false(t.clock_read())
}

///|
test "a padded row shown coming: its padding comes with what it holds, from nothing, no step as it sets out" {
  let on = @signals.signal(false, same=fn(a, b) { a == b })
  let t = cpv_tree(on)
  t.frame(390.0, 844.0) |> ignore
  assert_eq(cpv_y(t, "下"), 30.0)
  t.event(100.0, fn() { on.set(true) })
  let ys = cpv_frames(t, 100.0, 900.0)
  assert_eq(ys[0], 30.0)
  assert_eq(ys[ys.length() - 1], 76.0)
  for i in 1..<ys.length() {
    assert_true(ys[i] >= ys[i - 1], msg="opens only: \{Repr(ys)}")
  }
  let most = cpv_most_step(ys)
  assert_true(most < 12.0, msg="no step: the most a frame \{most}, \{Repr(ys)}")
  assert_true(cpv_in_pad(ys) > 2, msg="through less than its padding: \{Repr(ys)}")
  t.at(900.0)
  t.frame(390.0, 844.0) |> ignore
  assert_false(t.clock_read())
}

///|
test "a padded row shown called back as it goes, less tall than its padding: it turns there, no step" {
  let on = @signals.signal(true, same=fn(a, b) { a == b })
  let t = cpv_tree(on)
  t.frame(390.0, 844.0) |> ignore
  t.event(100.0, fn() { on.set(false) })
  let going = cpv_frames(t, 100.0, 900.0)
  // (the first frame it is less tall than its padding: called back there)
  let at = going.search_by(fn(y) { y < 56.0 - 0.01 && y > 30.01 })
  guard at is Some(at) else { fail("never less tall than its padding: \{Repr(going)}") }
  let turn = 100.0 + at.to_double() * 1000.0 / 120.0
  let on = @signals.signal(true, same=fn(a, b) { a == b })
  let t = cpv_tree(on)
  t.frame(390.0, 844.0) |> ignore
  t.event(100.0, fn() { on.set(false) })
  let going = cpv_frames(t, 100.0, turn)
  let low = going[going.length() - 1]
  assert_true(low > 30.0 && low < 56.0, msg="less tall than its padding: \{low}")
  t.event(turn, fn() { on.set(true) })
  let back = cpv_frames(t, turn, turn + 900.0)
  assert_eq(back[0], low)
  assert_eq(back[back.length() - 1], 76.0)
  let all = going + back
  let most = cpv_most_step(all)
  assert_true(most < 12.0, msg="no step as it turns: the most a frame \{most}, \{Repr(all)}")
  t.at(turn + 900.0)
  t.frame(390.0, 844.0) |> ignore
  assert_false(t.clock_read())
}

///|
test "a padded row shown coming and going: the same at a moment however many frames were drawn" {
  let at_moments = fn(every : Double) -> Array[Double] {
    let on = @signals.signal(false, same=fn(a, b) { a == b })
    let t = cpv_tree(on)
    t.frame(390.0, 844.0) |> ignore
    t.event(100.0, fn() { on.set(true) })
    let out = []
    let ms = Ref(100.0)
    // (frames every `every` ms on the way to `to`, then one there: 0, none between)
    let step_to = fn(to : Double) {
      if every > 0.0 {
        while ms.val + every < to {
          ms.val = ms.val + every
          t.at(ms.val)
          t.frame(390.0, 844.0) |> ignore
        }
      }
      ms.val = to
      t.at(to)
      t.frame(390.0, 844.0) |> ignore
      out.push(cpv_y(t, "下"))
    }
    step_to(130.0)
    step_to(230.0)
    step_to(900.0)
    t.event(900.0, fn() { on.set(false) })
    step_to(960.0)
    step_to(1040.0)
    step_to(1120.0)
    step_to(1800.0)
    out
  }
  let jumped = at_moments(0.0)
  for every in [1000.0 / 60.0, 1000.0 / 120.0, 1000.0 / 24.0, 1000.0 / 7.0] {
    let seen = at_moments(every)
    for i in 0..<jumped.length() {
      assert_true((jumped[i] - seen[i]).abs() < 0.01, msg="every \{every}: \{Repr(jumped)} \{Repr(seen)}")
    }
  }
}

///|
/// (No gap in its column: one picked that makes nothing is still a box in it, a gap before it once the one it is in
/// place of has gone, not this test's.)
test "a padded box picked in place of nothing: its padding goes with what it holds, down to nothing, no step at its end" {
  let on = @signals.signal(true, same=fn(a, b) { a == b })
  let t = @view.Tree::new(fn(col) {
    col.box(fn(b) { b.height(Is(Some(20.0))).words(Is("上")) |> ignore }) |> ignore
    col.pick(fn() { on.get() }, fn(v, k) {
      if k {
        v.padding(Is((0.0, 6.0, 0.0, 10.0))) |> ignore
        v.box(fn(b) { b.height(Is(Some(20.0))).words(Is("中")) |> ignore }) |> ignore
      }
    })
    col.box(fn(b) { b.height(Is(Some(20.0))).words(Is("下")) |> ignore }) |> ignore
  })
  t.frame(390.0, 844.0) |> ignore
  // (20, 6 + 20 + 10)
  assert_eq(cpv_y(t, "下"), 56.0)
  t.event(100.0, fn() { on.set(false) })
  let ys = cpv_frames(t, 100.0, 900.0)
  assert_eq(ys[0], 56.0)
  assert_eq(ys[ys.length() - 1], 20.0)
  for i in 1..<ys.length() {
    assert_true(ys[i] <= ys[i - 1], msg="closes only: \{Repr(ys)}")
  }
  let most = cpv_most_step(ys)
  assert_true(most < 12.0, msg="no step: the most a frame \{most}, \{Repr(ys)}")
  assert_true(cpv_in_pad(ys, none=20.0) > 2, msg="through less than its padding: \{Repr(ys)}")
  assert_eq(cpv_y(t, "中"), -1.0)
}
