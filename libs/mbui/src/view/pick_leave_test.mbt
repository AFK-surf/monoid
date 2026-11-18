// A pick said to leave over a time (pick_leave.mbt): one in the other's place, never both seen, its place's way
// cutting nothing seen.

///|
/// How long what a pick showed takes to leave, in these tests.
let pick_leave_ms : Double = 200.0

///|
/// How opaque the words `w` are drawn now (0 where they are not drawn).
fn pick_leave_alpha(t : @view.Tree, w : String) -> Double {
  let d = t.drawn().filter(fn(d) { d.words == w })
  if d.length() == 0 {
    0.0
  } else {
    d[0].alpha
  }
}

///|
/// A row: 左 (20 wide), a pick along it leaving over pick_leave_ms (`wide`: 宽宽 60 wide, else 窄 40), 右 (20 wide).
fn pick_leave_row(wide : @signals.Signal[Bool]) -> @view.Tree {
  @view.Tree::new(fn(root) {
    root.box(fn(r) {
      r.row(Is(true)) |> ignore
      r.box(fn(b) { b.width(Is(Some(20.0))).words(Is("左")) |> ignore }) |> ignore
      r.pick(along_row=true, leave=pick_leave_ms, fn() { wide.get() }, fn(v, k) {
        v.width(Is(Some(if k { 60.0 } else { 40.0 }))).words(Is(if k { "宽宽" } else { "窄" })) |> ignore
      })
      r.box(fn(b) { b.width(Is(Some(20.0))).words(Is("右")) |> ignore }) |> ignore
    })
    |> ignore
  })
}

///|
/// From `from` (ms) to `to`, a frame each ms: where 右 is and how opaque 窄 and 宽宽 are drawn at each.
fn pick_leave_walk(t : @view.Tree, from : Double, to : Double) -> Array[(Double, Double, Double, Double)] {
  let out = []
  let mut m = from
  while m <= to {
    t.at(m)
    t.frame(390.0, 844.0) |> ignore
    let x = t.drawn().filter(fn(d) { d.words == "右" })[0].x
    out.push((m, x, pick_leave_alpha(t, "窄"), pick_leave_alpha(t, "宽宽")))
    m = m + 1.0
  }
  out
}

///|
test "a pick leaving over a time, to a wider one along its row: the ground there at once, the wider words in as the narrow are gone, never both seen" {
  let wide = @signals.signal(false, same=fn(a, b) { a == b })
  let t = pick_leave_row(wide)
  t.frame(390.0, 844.0) |> ignore
  assert_eq(pick_leave_alpha(t, "窄"), 1.0)
  t.event(100.0, fn() { wide.set(true) })
  // (the wider words come in as the narrow ones are gone, their place still on its way: nothing blank between, its
  // ground the wider one's from the first frame)
  let way_ms = @flex.move_ms(20.0)
  let gone = 100.0 + pick_leave_ms
  let seen = 100.0 + (if way_ms > pick_leave_ms { way_ms } else { pick_leave_ms })
  for s in pick_leave_walk(t, 100.0, seen + pick_leave_ms + 50.0) {
    let (m, x, narrow, wider) = s
    assert_false(narrow > 0.0 && wider > 0.0, msg="both seen at \{m}: \{narrow}, \{wider}")
    // (the place's way set out at once, from 40 to 60)
    let (way, _) = @flex.come_way(40.0, 0.0, 60.0, m - 100.0)
    assert_true((x - (20.0 + way)).abs() <= 0.5, msg="右 at \{m}: \{x}, its way \{way}")
    if m >= 100.0 + pick_leave_ms {
      assert_eq(narrow, 0.0, msg="窄 still seen at \{m}")
    }
    if m <= gone {
      assert_eq(wider, 0.0, msg="宽宽 seen at \{m}, before 窄 was gone")
    } else if m >= gone + 2.0 {
      assert_true(wider > 0.0, msg="nothing seen at \{m}: 窄 gone at \{gone}, 宽宽 not come")
    }
  }
  assert_eq(pick_leave_alpha(t, "宽宽"), 1.0)
  assert_false(t.clock_read())
}

///|
test "a pick leaving over a time, to a narrower one along its row: the wider words out first, the ground after, never both seen" {
  let wide = @signals.signal(true, same=fn(a, b) { a == b })
  let t = pick_leave_row(wide)
  t.frame(390.0, 844.0) |> ignore
  t.event(100.0, fn() { wide.set(false) })
  let sets_out = 100.0 + pick_leave_ms
  let way_ms = @flex.move_ms(20.0)
  for s in pick_leave_walk(t, 100.0, sets_out + way_ms + 50.0) {
    let (m, x, narrow, wider) = s
    assert_false(narrow > 0.0 && wider > 0.0, msg="both seen at \{m}: \{narrow}, \{wider}")
    // (the place as wide as it was till 宽宽 is gone, then its way from 60 to 40)
    let (way, _) = @flex.come_way(60.0, 0.0, 40.0, m - sets_out)
    assert_true((x - (20.0 + way)).abs() <= 0.5, msg="右 at \{m}: \{x}, its way \{way}")
    if m <= sets_out {
      assert_eq(narrow, 0.0, msg="窄 seen at \{m}, before 宽宽 was gone")
    } else {
      assert_eq(wider, 0.0, msg="宽宽 still seen at \{m}")
    }
  }
  assert_eq(pick_leave_alpha(t, "窄"), 1.0)
  assert_false(t.clock_read())
}

///|
test "a pick leaving over a time, turned back before the new one was seen: that one let go unseen, never both seen" {
  let wide = @signals.signal(false, same=fn(a, b) { a == b })
  let t = pick_leave_row(wide)
  t.frame(390.0, 844.0) |> ignore
  t.event(100.0, fn() { wide.set(true) })
  let first = pick_leave_walk(t, 100.0, 150.0)
  t.event(150.0, fn() { wide.set(false) })
  let after = pick_leave_walk(t, 151.0, 1500.0)
  let all = first.copy()
  all.append(after)
  for s in all {
    let (m, _, narrow, wider) = s
    assert_false(narrow > 0.0 && wider > 0.0, msg="both seen at \{m}: \{narrow}, \{wider}")
    assert_eq(wider, 0.0, msg="宽宽 seen at \{m}")
  }
  assert_eq(t.drawn().filter(fn(d) { d.words == "右" })[0].x, 60.0)
  assert_eq(pick_leave_alpha(t, "窄"), 1.0)
  assert_false(t.clock_read())
}

///|
test "a pick leaving over a time down a column: the same, its place's height the way, never both seen" {
  let tall = @signals.signal(false, same=fn(a, b) { a == b })
  let t = @view.Tree::new(fn(root) {
    root.pick(leave=pick_leave_ms, fn() { tall.get() }, fn(v, k) {
      v.height(Is(Some(if k { 60.0 } else { 40.0 }))).words(Is(if k { "高" } else { "矮" })) |> ignore
    })
    root.box(fn(b) { b.height(Is(Some(20.0))).words(Is("下")) |> ignore }) |> ignore
  })
  t.frame(390.0, 844.0) |> ignore
  for change in [(100.0, true), (1000.0, false)] {
    let (at, to_tall) = change
    t.event(at, fn() { tall.set(to_tall) })
    let mut m = at
    while m <= at + 800.0 {
      t.at(m)
      t.frame(390.0, 844.0) |> ignore
      let short = pick_leave_alpha(t, "矮")
      let high = pick_leave_alpha(t, "高")
      assert_false(short > 0.0 && high > 0.0, msg="both seen at \{m}: \{short}, \{high}")
      let y = t.drawn().filter(fn(d) { d.words == "下" })[0].y
      // (taller: its way at once; shorter: once 高 is gone)
      let (way, _) = if to_tall {
        @flex.come_way(40.0, 0.0, 60.0, m - at)
      } else {
        @flex.come_way(60.0, 0.0, 40.0, m - at - pick_leave_ms)
      }
      assert_true((y - way).abs() <= 0.5, msg="下 at \{m}: \{y}, its way \{way}")
      m = m + 1.0
    }
  }
  assert_false(t.clock_read())
}

///|
test "a pick leaving over a time, made with what holds it: shown at once, whole, nothing reading the clock" {
  let wide = @signals.signal(true, same=fn(a, b) { a == b })
  let t = pick_leave_row(wide)
  t.frame(390.0, 844.0) |> ignore
  assert_eq(pick_leave_alpha(t, "宽宽"), 1.0)
  assert_eq(t.drawn().filter(fn(d) { d.words == "右" })[0].x, 80.0)
  assert_false(t.clock_read())
}

///|
test "a pick leaving over a time, changed again where it is laid out nowhere halfway on a way set out as it showed: shown again, what it shows now there whole, nothing of the way before left" {
  let which = @signals.signal(1, same=fn(a, b) { a == b })
  let hide = @signals.signal(false, same=fn(a, b) { a == b })
  let t = @view.Tree::new(fn(root) {
    root.box(fn(page) {
      page.laid_nowhere(By(fn() { hide.get() })) |> ignore
      page.box(fn(r) {
        r.row(Is(true)) |> ignore
        r.box(fn(b) { b.width(Is(Some(20.0))).words(Is("左")) |> ignore }) |> ignore
        // (0 makes nothing, 1 窄 40 wide, 2 宽宽 60 wide)
        r.pick(along_row=true, leave=pick_leave_ms, fn() { which.get() }, fn(v, k) {
          if k > 0 {
            v.width(Is(Some(if k == 2 { 60.0 } else { 40.0 }))).words(Is(if k == 2 { "宽宽" } else { "窄" })) |> ignore
          }
        })
        r.box(fn(b) { b.width(Is(Some(20.0))).words(Is("右")) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.frame(390.0, 844.0) |> ignore
  // (to nothing as it shows: 窄 fading, its place closing on its way)
  t.event(100.0, fn() { which.set(0) })
  t.at(110.0)
  t.frame(390.0, 844.0) |> ignore
  // (laid out nowhere then, and changed again there)
  t.event(110.0, fn() { hide.set(true) })
  t.at(110.0)
  t.frame(390.0, 844.0) |> ignore
  t.event(115.0, fn() { which.set(2) })
  t.at(115.0)
  t.frame(390.0, 844.0) |> ignore
  // (shown again 50 ms on, before the way set out at 100 would have ended)
  t.event(160.0, fn() { hide.set(false) })
  for m in [160.0, 200.0, 400.0, 900.0] {
    t.at(m)
    t.frame(390.0, 844.0) |> ignore
    let x = t.drawn().filter(fn(d) { d.words == "右" })[0].x
      assert_eq(x, 80.0, msg="右 at \{m}: \{x}")
    assert_eq(pick_leave_alpha(t, "宽宽"), 1.0, msg="宽宽 at \{m}")
    assert_eq(pick_leave_alpha(t, "窄"), 0.0, msg="窄 at \{m}")
  }
  assert_false(t.clock_read())
}
