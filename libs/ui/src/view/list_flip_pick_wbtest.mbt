// A pick leaving over a time in a block of a page's list said `flips` (pick_leave.mbt, Tree's flip_gone): what it
// shows now comes in on the way its change set out, to that way's end alone. A row come under it after it is there sets
// it out by none again (the user, 2026-11-17: 「你 选择了…」 and 刚刚 shown twice, a 思考中 row come under them); one come
// while it is still on its way takes nothing of how far it came back; and it is drawn coming by its place's way alone,
// not grown and faded in again as what the block holds come (Node's pick_fader).

///|
let flip_pick_at : Double = 100.5

///|
/// A page's list 300 by 400 of keys 0 to 9 (行k, 40 each) following its foot, said `flips`; block 9 holds under its line a
/// pick leaving over 200 ms: 选项 (40 tall) till `chosen`, then 选择了 (20 tall, or 40 where `same`). Key 70 (60 tall),
/// where it comes, flies in from the window's foot on a linear flight 400 ms long. Drawn once, at 0.
fn flip_pick_case(same? : Bool = false) -> (Tree, @signals.Signal[Array[Int]], @signals.Signal[Bool]) {
  let keys = @signals.signal(Array::makei(10, fn(i) { i }), same=fn(a, b) { a == b })
  let chosen = @signals.signal(false, same=fn(a, b) { a == b })
  let scroll = Scroll::list()
  let tree = Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(scroll, fn() { keys.get() }, est=40.0, follows=fn() { true }, flips=true, fn(b, k) {
        if k == 70 {
          b.box(fn(w) {
            w.height(Is(Some(60.0))).shrink(Is(0.0)).words(Is("行70")) |> ignore
            w.flies_in(
              { way: fn(_) { (400.0, fn(t) { if t >= 400.0 { 1.0 } else { t / 400.0 } }) } },
              fn(to) { Some((0.0, 380.0, to.2, to.3)) },
            )
            |> ignore
          })
          |> ignore
          return
        }
        b.box(fn(w) { w.height(Is(Some(40.0))).shrink(Is(0.0)).words(Is("行\{k}")) |> ignore }) |> ignore
        if k == 9 {
          b.pick(leave=200.0, fn() { chosen.get() }, fn(v, c) {
            v
            .height(Is(Some(if c && !same { 20.0 } else { 40.0 })))
            .shrink(Is(0.0))
            .words(Is(if c { "选择了" } else { "选项" }))
            |> ignore
          })
        }
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  (tree, keys, chosen)
}

///|
/// How opaque the words `w` are drawn now (0 where they are not drawn), and their node.
fn flip_pick_drawn(t : Tree, w : String) -> (Double, Int) {
  match t.drawn().filter(fn(d) { d.words == w }) {
    [d, ..] => (d.alpha, d.id.at)
    _ => (0.0, -1)
  }
}

///|
/// From `from` to `to` (ms), a frame each 1000/60: how opaque 选择了 is drawn at each, and whether its node was ever
/// set out as come by the list's flip_in (drawn off, grown or faded by it).
fn flip_pick_walk(t : Tree, from : Double, to : Double) -> (Array[(Double, Double)], Bool) {
  let out = []
  let mut flipped = false
  let mut ms = from
  while ms <= to {
    t.frame(390.0, 844.0, now=ms) |> ignore
    let (a, at) = flip_pick_drawn(t, "选择了")
    if at >= 0 && t.nodes[at].flip_in != (0.0, 0.0, 1.0, 1.0) {
      flipped = true
    }
    out.push((ms, a))
    ms = ms + 1000.0 / 60.0
  }
  (out, flipped)
}

///|
test "flips: a pick's new side, there, stays there as a row comes under its block: not shown a second time" {
  let (t, keys, chosen) = flip_pick_case()
  t.advance(flip_pick_at)
  chosen.set(true)
  let (first, _) = flip_pick_walk(t, flip_pick_at, flip_pick_at + 900.0)
  let (_, last) = first[first.length() - 1]
  assert_eq(last, 1.0, msg="选择了 at \{last} once its way is over")
  // (a row come under it: the list's way set out anew, for it)
  let then = flip_pick_at + 1000.0
  t.advance(then)
  keys.set(Array::makei(11, fn(i) { i }))
  let (after, _) = flip_pick_walk(t, then, then + 900.0)
  for s in after {
    let (ms, a) = s
    assert_eq(a, 1.0, msg="at \{ms - then} after the row came: 选择了 drawn at \{a}")
  }
}

///|
test "flips: a row come while a pick's new side is still on its way takes nothing of how far it came back" {
  let (t, keys, chosen) = flip_pick_case()
  t.advance(flip_pick_at)
  chosen.set(true)
  let (early, _) = flip_pick_walk(t, flip_pick_at, flip_pick_at + 120.0)
  let then = flip_pick_at + 130.0
  t.advance(then)
  keys.set(Array::makei(11, fn(i) { i }))
  let (late, _) = flip_pick_walk(t, then, then + 900.0)
  let all = early
  all.append(late)
  let mut was = 0.0
  let mut seen = false
  for s in all {
    let (ms, a) = s
    assert_true(a >= was - 1.0e-9, msg="at \{ms - flip_pick_at}: 选择了 back from \{was} to \{a}")
    if a > 0.0 && ms < then {
      seen = true
    }
    was = a
  }
  assert_true(seen, msg="选择了 never seen before the row came: the case shows nothing")
  assert_eq(was, 1.0, msg="选择了 at \{was} once its way is over")
}

///|
test "flips: a pick's new side comes by its place's way alone, never also grown and faded in as what its block holds come" {
  let (t, _, chosen) = flip_pick_case()
  t.advance(flip_pick_at)
  chosen.set(true)
  let (walk, flipped) = flip_pick_walk(t, flip_pick_at, flip_pick_at + 900.0)
  assert_true(walk.iter().any(fn(s) { s.1 > 0.0 && s.1 < 1.0 }), msg="选择了 never drawn on its way: the case shows nothing")
  assert_false(flipped, msg="选择了 set out by the list's flip_in as well as by its place's way")
}

///|
test "flips: a pick to one as tall: what it shows now comes in over the least of a Move's time, never at once, and is not shown again" {
  let (t, keys, chosen) = flip_pick_case(same=true)
  t.advance(flip_pick_at)
  chosen.set(true)
  let (walk, _) = flip_pick_walk(t, flip_pick_at, flip_pick_at + 600.0)
  let (_, first) = walk[0]
  assert_true(first < 1.0, msg="选择了 drawn at \{first} in the change's frame: there at once")
  let mut was = 0.0
  for s in walk {
    let (ms, a) = s
    assert_true(a >= was - 1.0e-9, msg="at \{ms - flip_pick_at}: 选择了 back from \{was} to \{a}")
    was = a
  }
  assert_eq(was, 1.0, msg="选择了 at \{was} once its way is over")
  assert_true(walk.iter().any(fn(s) { s.1 > 0.0 && s.1 < 1.0 }), msg="选择了 never drawn on its way")
  let then = flip_pick_at + 1000.0
  t.advance(then)
  keys.set(Array::makei(11, fn(i) { i }))
  let (after, _) = flip_pick_walk(t, then, then + 600.0)
  for s in after {
    let (ms, a) = s
    assert_eq(a, 1.0, msg="at \{ms - then} after the row came: 选择了 drawn at \{a}")
  }
}

///|
test "flips: a pick told as an answer is there at once" {
  let (t, _, chosen) = flip_pick_case()
  t.advance(flip_pick_at)
  answering(fn() { chosen.set(true) })
  t.frame(390.0, 844.0, now=flip_pick_at) |> ignore
  let (a, _) = flip_pick_drawn(t, "选择了")
  assert_eq(a, 1.0, msg="选择了 drawn at \{a} in the answer's frame")
}

///|
test "flips: a pick changed while a flight's way still goes in the list goes from none of it there, on what is left of that way" {
  let (t, keys, chosen) = flip_pick_case()
  // (key 70 flies in at the list's foot: the list on its rise, 400 ms, linear)
  t.event(flip_pick_at, fn() { keys.set(Array::makei(11, fn(i) { if i < 10 { i } else { 70 } })) })
  t.frame(390.0, 844.0, now=flip_pick_at) |> ignore
  // (120 ms on, 0.7 of that way left: the pick changed then goes on what is left, from none of it)
  let then = flip_pick_at + 120.0
  t.frame(390.0, 844.0, now=then - 1.0) |> ignore
  t.event(then, fn() { chosen.set(true) })
  let (walk, _) = flip_pick_walk(t, then, flip_pick_at + 900.0)
  let mut was = 0.0
  let mut shown = -1.0
  for s in walk {
    let (ms, a) = s
    assert_true(a >= was - 1.0e-9, msg="at \{ms - then}: 选择了 back from \{was} to \{a}")
    if shown < 0.0 && a > 0.0 {
      shown = ms
    }
    was = a
  }
  assert_eq(was, 1.0, msg="选择了 at \{was} once its way is over")
  // (seen once half of what was left of the way is gone: 260 ms after the flight set out, not at 200 as half of all of it)
  assert_true(shown - flip_pick_at >= 250.0, msg="选择了 seen \{shown - flip_pick_at} after the flight set out: from where that way was")
}

///|
test "flips: a pick changed as a flight's way in the list is nearly over comes in over the least of a Move's time, not within a frame or two" {
  let (t, keys, chosen) = flip_pick_case()
  t.event(flip_pick_at, fn() { keys.set(Array::makei(11, fn(i) { if i < 10 { i } else { 70 } })) })
  t.frame(390.0, 844.0, now=flip_pick_at) |> ignore
  // (390 ms on, a fortieth of that way left)
  let then = flip_pick_at + 390.0
  t.frame(390.0, 844.0, now=then - 1.0) |> ignore
  t.event(then, fn() { chosen.set(true) })
  let (walk, _) = flip_pick_walk(t, then, then + 400.0)
  let mut was = 0.0
  for s in walk {
    let (ms, a) = s
    assert_true(a >= was - 1.0e-9, msg="at \{ms - then}: 选择了 back from \{was} to \{a}")
    // (whole no sooner than the least of a Move's time after the change)
    if ms - then < @flex.move_least_ms - 1.0 {
      assert_true(a < 1.0, msg="at \{ms - then}: 选择了 whole already")
    }
    was = a
  }
  assert_eq(was, 1.0, msg="选择了 at \{was} once its way is over")
}

///|
fn flip_pick_rect(t : Tree, w : String) -> (Double, Double, Double)? {
  match t.drawn().filter(fn(d) { d.words == w && d.alpha > 0.0 }) {
    [d, ..] => Some((d.x, d.x + d.w, d.alpha))
    _ => None
  }
}

///|
test "flips: right-aligned pick(leave=200) keeps leaving and entering items anchored on both shrink and grow" {
  let cases : Array[(String, Double, String, Double, String)] = [
    ("shrink", 160.0, "未发送 重试 删除", 70.0, "正在发送"),
    ("grow", 30.0, "刚刚", 160.0, "未发送 重试 删除"),
  ]
  for fps in [60.0, 120.0] {
    let step = 1000.0 / fps
    for c in cases {
      let (label, w0, s0, w1, s1) = c
      let keys = @signals.signal(Array::makei(10, fn(i) { i }), same=fn(a, b) { a == b })
      let next = @signals.signal(false, same=fn(a, b) { a == b })
      let scroll = Scroll::list()
      let tree = Tree::new(fn(root) {
        root.box(fn(o) {
          o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
          o.scrolls_window(scroll, fn() { keys.get() }, est=40.0, follows=fn() { true }, flips=true, fn(b, k) {
            if k != 9 {
              b.box(fn(w) { w.height(Is(Some(40.0))).shrink(Is(0.0)).words(Is("行\{k}")) |> ignore }) |> ignore
              return
            }
            b.box(fn(row) {
              row.width(Is(Some(300.0))).lines_up(Is(Some(End))) |> ignore
              row.box(fn(col) {
                col.lines_up(Is(Some(End))) |> ignore
                col.box(fn(bubble) {
                  bubble.width(Is(Some(100.0))).height(Is(Some(32.0))).shrink(Is(0.0)).words(Is("气泡")) |> ignore
                })
                |> ignore
                col.pick(leave=200.0, fn() { next.get() }, fn(v, is_next) {
                  v
                  .width(Is(Some(if is_next { w1 } else { w0 })))
                  .height(Is(Some(if is_next { 18.0 } else { 26.0 })))
                  .shrink(Is(0.0))
                  .words(Is(if is_next { s1 } else { s0 }))
                  |> ignore
                })
              })
              |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      tree.frame(390.0, 844.0, now=0.0) |> ignore
      let (old_x, old_r, _) = match flip_pick_rect(tree, s0) {
        Some(r) => r
        None => fail("\{label} @\{fps}fps: initial \{s0} not drawn")
      }
      let at = flip_pick_at
      tree.advance(at)
      next.set(true)
      let leaving_samples : Array[(Double, Double, Double, Double)] = []
      let entering_samples : Array[(Double, Double, Double, Double)] = []
      let mut ms = at
      while ms <= at + 500.0 {
        tree.frame(390.0, 844.0, now=ms) |> ignore
        match flip_pick_rect(tree, s0) {
          Some((x, r, a)) => leaving_samples.push((ms - at, x, r, a))
          None => ()
        }
        match flip_pick_rect(tree, s1) {
          Some((x, r, a)) => entering_samples.push((ms - at, x, r, a))
          None => ()
        }
        ms = ms + step
      }
      let (new_x, new_r, end_a) = match flip_pick_rect(tree, s1) {
        Some(r) => r
        None => fail("\{label} @\{fps}fps: final \{s1} not drawn")
      }
      assert_eq(end_a, 1.0, msg="\{label} @\{fps}fps: final \{s1} alpha=\{end_a}")
      assert_true(
        leaving_samples.iter().any(fn(s) { s.3 > 0.0 && s.3 < 1.0 }),
        msg="\{label} @\{fps}fps: leaving \{s0} never faded mid-way",
      )
      assert_true(
        entering_samples.iter().any(fn(s) { s.3 > 0.0 && s.3 < 1.0 }),
        msg="\{label} @\{fps}fps: entering \{s1} never faded in mid-way",
      )
      for s in leaving_samples {
        let (dt, x, r, a) = s
        assert_true(
          (x - old_x).abs() <= 0.5 && (r - old_r).abs() <= 0.5,
          msg="\{label} @\{fps}fps +\{dt}ms: leaving \{s0} (a=\{a}) drifted from [\{old_x}, \{old_r}] to [\{x}, \{r}]",
        )
      }
      for s in entering_samples {
        let (dt, x, r, a) = s
        assert_true(
          (x - new_x).abs() <= 0.5 && (r - new_r).abs() <= 0.5,
          msg="\{label} @\{fps}fps +\{dt}ms: entering \{s1} (a=\{a}) drifted from [\{new_x}, \{new_r}] to [\{x}, \{r}]",
        )
      }
    }
  }
}
