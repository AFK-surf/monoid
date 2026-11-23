// Keys that stay among a page's list's keys moved among them by data (View::scrolls_window `reorders`): the fewest that
// moved each close their way where they were and open it where they are now, in the column's one way with what comes
// and goes, from the change's moment (the user, 2026-10-31: 「原地缩下去再从目标点挤出来更合理」); what does not say so,
// what an answer tells and a change of the width, at once. Looked at in one jump and at 60, 120, 24 and 7 a second
// (rc_walk), the same at each.

///|
/// A page's list 300 by 400 of keys 0 to 9 (40 each, words 行k), at its top; `reorders` what its page says of a key
/// moved (the list's own default: at once). Drawn once, at 0.
fn ro_case(
  reorders? : (Int) -> Bool = fn(_) { false },
) -> (@view.Tree, @signals.Signal[Array[Int]], @signals.Signal[Double]) {
  let keys = @signals.signal(rc_ten_and([]), same=fn(a, b) { a == b })
  let wide = @signals.signal(300.0, same=fn(a, b) { a == b })
  let scroll = @view.Scroll::list()
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(By(fn() { Some(wide.get()) })).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(scroll, fn() { keys.get() }, est=40.0, reorders~, fn(b, k) {
        b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  (tree, keys, wide)
}

///|
/// `ks` with `k` taken to the top.
fn ro_to_top(ks : Array[Int], k : Int) -> Array[Int] {
  let out = [k]
  for x in ks {
    if x != k {
      out.push(x)
    }
  }
  out
}

///|
/// Where each of the words `w` drawn is (its top), top to bottom.
fn ro_all(t : @view.Tree, w : String) -> Array[Double] {
  let ys = t.drawn().filter(fn(d) { d.words == w }).map(fn(d) { d.y })
  ys.sort()
  ys
}

///|
/// `ys` as words, each to a tenth of a point (what a failure says).
fn ro_line(ys : Array[Double]) -> String {
  let out = StringBuilder()
  for y in ys {
    out.write_string(((y * 10.0).round() / 10.0).to_string())
    out.write_string(" ")
  }
  out.to_string()
}

///|
test "a key taken to the top closes where it was and opens at the top, one way with the rows it moves, at every rate" {
  let looks = rc_looks(rc_at + @flex.move_most_ms + 50.0)
  let mut first : Array[(Array[Double], Double, Double)]? = None
  for rate in rc_rates {
    let (t, keys, _) = ro_case(reorders=fn(_) { true })
    let y5 = rc_y(t, "行5")
    let y0 = rc_y(t, "行0")
    let y6 = rc_y(t, "行6")
    let ys = rc_walk(t, [(rc_at, fn() { keys.set(ro_to_top(rc_ten_and([]), 5)) })], looks, rate, fn() {
      (ro_all(t, "行5"), rc_y(t, "行0"), rc_y(t, "行6"))
    })
    // (as it was at the change's moment)
    assert_true(
      ys[0].0.length() >= 1 && (ys[0].0[ys[0].0.length() - 1] - y5).abs() < 0.5,
      msg="at \{rate}: \{ro_line(ys[0].0)}",
    )
    assert_true((ys[0].1 - y0).abs() < 0.5, msg="at \{rate}: 行0 at \{ys[0].1} as it set out")
    // (half way: one closing where it was, one opening at the top; 行0 pushed down on its way)
    let half = looks.search_by(fn(l) { l >= rc_at + @flex.move_ms(40.0) / 2.0 }).unwrap()
    assert_true(ys[half].0.length() == 2, msg="at \{rate}: 行5 drawn at \{ro_line(ys[half].0)} half way")
    assert_true(ys[half].1 > y0 + 0.5 && ys[half].1 < y0 + 39.5, msg="at \{rate}: 行0 at \{ys[half].1} half way")
    // (what is under where it was stays: its room closing as the top's opens, the same way)
    for y in ys {
      assert_true((y.2 - y6).abs() < 0.5, msg="at \{rate}: 行6 at \{y.2}, \{y6} before")
    }
    // (at its end: one, at the top; 行0 a row down; never back the way it came)
    let end = ys[ys.length() - 1]
    assert_true(end.0.length() == 1 && (end.0[0] - y0).abs() < 0.5, msg="at \{rate}: 行5 ends at \{ro_line(end.0)}")
    assert_true((end.1 - (y0 + 40.0)).abs() < 0.5, msg="at \{rate}: 行0 ends at \{end.1}")
    assert_eq(rc_turns(ys.map(fn(y) { y.1 })), 0)
    match first {
      None => first = Some(ys)
      Some(f) =>
        for i, y in ys {
          assert_true(
            f[i].0 == y.0 && (f[i].1 - y.1).abs() < 1.0e-6,
            msg="at \{rate}: at \{looks[i]} \{ro_line(y.0)} \{y.1}, \{ro_line(f[i].0)} \{f[i].1} in one jump",
          )
        }
    }
  }
}

///|
test "another taken to the top while the first is on its way: what it pushes goes on down from where it is, never back" {
  let looks = rc_looks(rc_at + @flex.move_most_ms + 300.0)
  let mut once_ys : Array[(Double, Double)]? = None
  for rate in rc_rates {
    let (t, keys, _) = ro_case(reorders=fn(_) { true })
    let y0 = rc_y(t, "行0")
    let once = ro_to_top(rc_ten_and([]), 5)
    let twice = ro_to_top(once, 7)
    let ys = rc_walk(
      t,
      [(rc_at, fn() { keys.set(once) }), (rc_at + rc_again_ms, fn() { keys.set(twice) })],
      looks,
      rate,
      fn() { (rc_y(t, "行0"), rc_y(t, "行1")) },
    )
    // (行0 down two rows, on from where it was, as fast: never turned back, never stepped)
    assert_true(rc_turns(ys.map(fn(y) { y.0 })) == 0, msg="at \{rate}: 行0 turned: \{ro_line(ys.map(fn(y) { y.0 }))}")
    for i in 1..<ys.length() {
      assert_true(
        ys[i].0 - ys[i - 1].0 < 20.0,
        msg="at \{rate}: 行0 stepped at \{looks[i]}: \{ro_line(ys.map(fn(y) { y.0 }))}",
      )
    }
    let at2 = looks.search_by(fn(l) { l >= rc_at + rc_again_ms }).unwrap()
    assert_true(ys[at2 + 1].0 - ys[at2].0 > 0.05, msg="at \{rate}: 行0 stopped at the second change")
    let end = ys[ys.length() - 1]
    assert_true(
      (end.0 - (y0 + 80.0)).abs() < 0.5 && (end.1 - (y0 + 120.0)).abs() < 0.5,
      msg="at \{rate}: ends \{end.0}, \{end.1}",
    )
    // (one at the top, under it the first)
    assert_eq(ro_all(t, "行7").length(), 1)
    assert_true((rc_y(t, "行7") - y0).abs() < 0.5 && (rc_y(t, "行5") - (y0 + 40.0)).abs() < 0.5)
    match once_ys {
      None => once_ys = Some(ys)
      Some(r) =>
        for i, y in ys {
          assert_true((r[i].0 - y.0).abs() < 1.0e-6, msg="at \{rate}: 行0 at \{looks[i]} \{y.0}, \{r[i].0} in one jump")
        }
    }
  }
}

///|
test "a list that says nothing of it, an answer's, and its width changed: there at once, one of it" {
  let moved = ro_to_top(rc_ten_and([]), 5)
  // (says nothing)
  let (t, keys, _) = ro_case()
  let y0 = rc_y(t, "行0")
  let ys = rc_walk(t, [(rc_at, fn() { keys.set(moved) })], [rc_at], 0.0, fn() { ro_all(t, "行5") })
  assert_true(ys[0].length() == 1 && (ys[0][0] - y0).abs() < 0.5, msg="said nothing: \{ro_line(ys[0])}")
  // (said, but its page says no of it)
  let (t, keys, _) = ro_case(reorders=fn(k) { k != 5 })
  let ys = rc_walk(t, [(rc_at, fn() { keys.set(moved) })], [rc_at], 0.0, fn() { ro_all(t, "行5") })
  assert_true(ys[0].length() == 1 && (ys[0][0] - y0).abs() < 0.5, msg="asked no: \{ro_line(ys[0])}")
  // (an answer's)
  let (t, keys, _) = ro_case(reorders=fn(_) { true })
  let ys = rc_walk(t, [(rc_at, fn() { @view.answering(fn() { keys.set(moved) }) })], [rc_at], 0.0, fn() {
    ro_all(t, "行5")
  })
  assert_true(ys[0].length() == 1 && (ys[0][0] - y0).abs() < 0.5, msg="an answer's: \{ro_line(ys[0])}")
  // (its width changed, its keys as they were: nothing on its way)
  let (t, _, wide) = ro_case(reorders=fn(_) { true })
  let y5 = rc_y(t, "行5")
  let ys = rc_walk(t, [(rc_at, fn() { wide.set(260.0) })], [rc_at, rc_at + 50.0], 0.0, fn() { ro_all(t, "行5") })
  assert_true(ys[0] == [y5] && ys[1] == [y5], msg="width: \{ro_line(ys[0])} \{ro_line(ys[1])}")
}
