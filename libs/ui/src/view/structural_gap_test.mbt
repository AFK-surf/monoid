// A structure's box that made nothing (View::pick of a case that makes nothing, View::show or a View::each row whose
// make says nothing and holds no box) and is on no way is laid out nowhere in whatever holds it (flex's nothing_made,
// laid_none): in no row or column, no room, no gap before or after it, at the start, between or at the end, however
// what holds it lies its items along it. A box the app says itself holding nothing is an item as any other, with its
// gap. A pick closing to a case that makes nothing closes the gap with it and stays closed once its way is over (no
// gap back as its way ends); opening from one, it opens the gap with it; called back half way, it turns with no step;
// the same at a moment at every rate. What works a sibling's gaps out by hand (Room::tall across a row, a page's list's
// read_from start) leaves such a box out as the layout does.

///|
/// The word drawn `w`'s top (y), as the tree is drawn now; none: -1.
fn sg_y(t : @view.Tree, w : String) -> Double {
  match t.drawn().filter(fn(d) { d.words == w }) {
    [d, ..] => d.y
    _ => -1.0
  }
}

///|
/// The word drawn `w`'s left (x), as the tree is drawn now; none: -1.
fn sg_x(t : @view.Tree, w : String) -> Double {
  match t.drawn().filter(fn(d) { d.words == w }) {
    [d, ..] => d.x
    _ => -1.0
  }
}

///|
/// What `read` reads at each frame of 120 a second from `from` to `to` ms (both drawn).
fn sg_frames(t : @view.Tree, from : Double, to : Double, read : () -> Double) -> Array[Double] {
  let out = []
  let mut k = 0
  while true {
    let ms = from + k.to_double() * 1000.0 / 120.0
    let ms = if ms > to { to } else { ms }
    t.at(ms)
    t.frame(390.0, 844.0) |> ignore
    out.push(read())
    if ms >= to {
      break
    }
    k = k + 1
  }
  out
}

///|
/// The most `ys` moves from one frame to the next.
fn sg_most_step(ys : Array[Double]) -> Double {
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
/// An empty structure of kind `kind` made in `v`: 0 a pick at once, 1 a pick, 2 a show shown, 3 an each's one row.
fn sg_empty(v : @view.View, kind : Int) -> Unit {
  match kind {
    0 => v.pick(at_once=true, fn() { 0 }, fn(_, _) { () })
    1 => v.pick(fn() { 0 }, fn(_, _) { () })
    2 => v.show(fn() { true }, fn(_) { () })
    _ => v.each(fn() { [1] }, fn(x) { x }, fn(_, _) { () })
  }
}

///|
let sg_kinds : Array[String] = ["pick at once", "pick", "show", "each row"]

///|
test "an empty structure first, between or last down a column: no room and no gap of its own" {
  for kind in [0, 1, 2, 3] {
    for at in [0, 1, 2] {
      let t = @view.Tree::new(fn(root) {
        root.box(fn(col) {
          col.gap(Is(10.0)) |> ignore
          if at == 0 {
            sg_empty(col, kind)
          }
          col.box(fn(b) { b.height(Is(Some(20.0))).words(Is("上")) |> ignore }) |> ignore
          if at == 1 {
            sg_empty(col, kind)
          }
          col.box(fn(b) { b.height(Is(Some(20.0))).words(Is("下")) |> ignore }) |> ignore
          if at == 2 {
            sg_empty(col, kind)
          }
        })
        |> ignore
        root.box(fn(b) { b.height(Is(Some(20.0))).words(Is("尾")) |> ignore }) |> ignore
      })
      t.frame(390.0, 844.0) |> ignore
      let what = "\{sg_kinds[kind]} at \{at}"
      assert_eq(sg_y(t, "上"), 0.0, msg=what)
      assert_eq(sg_y(t, "下"), 30.0, msg=what)
      assert_eq(sg_y(t, "尾"), 50.0, msg=what)
      assert_false(t.clock_read(), msg=what)
    }
  }
}

///|
test "an empty structure first, between or last along a row, its items in the middle or spread: not counted among them" {
  for kind in [0, 1, 2, 3] {
    for at in [0, 1, 2, 3] {
      for lies in [@view.Lies::Start, @view.Lies::Middle, @view.Lies::Between] {
        let t = @view.Tree::new(fn(root) {
          root.box(fn(r) {
            r.row(Is(true)).gap(Is(10.0)).lies_along(Is(lies)) |> ignore
            if at == 0 {
              sg_empty(r, kind)
            }
            r.box(fn(b) { b.width(Is(Some(20.0))).words(Is("甲")) |> ignore }) |> ignore
            if at == 1 {
              sg_empty(r, kind)
            }
            r.box(fn(b) { b.width(Is(Some(20.0))).words(Is("乙")) |> ignore }) |> ignore
            if at == 2 {
              sg_empty(r, kind)
            }
            r.box(fn(b) { b.width(Is(Some(20.0))).words(Is("丙")) |> ignore }) |> ignore
            if at == 3 {
              sg_empty(r, kind)
            }
          })
          |> ignore
        })
        t.frame(390.0, 844.0) |> ignore
        let what = "\{sg_kinds[kind]} at \{at}, \{Repr(lies)}"
        // (three of 20, 10 apart: 80; in the middle of 390, from 155; spread, 乙 half way along)
        let (a, b, c) = match lies {
          Start => (0.0, 30.0, 60.0)
          Middle => (155.0, 185.0, 215.0)
          _ => (0.0, 185.0, 370.0)
        }
        assert_eq(sg_x(t, "甲"), a, msg=what)
        assert_eq(sg_x(t, "乙"), b, msg=what)
        assert_eq(sg_x(t, "丙"), c, msg=what)
      }
    }
  }
}

///|
test "an empty box the app says down a column: an item as any other, its gap before and after it" {
  let t = @view.Tree::new(fn(root) {
    root.gap(Is(10.0)) |> ignore
    root.box(fn(b) { b.height(Is(Some(20.0))).words(Is("上")) |> ignore }) |> ignore
    root.box(fn(_) { () }) |> ignore
    root.box(fn(b) { b.height(Is(Some(20.0))).words(Is("下")) |> ignore }) |> ignore
  })
  t.frame(390.0, 844.0) |> ignore
  // (20 + 10 + 0 + 10)
  assert_eq(sg_y(t, "下"), 40.0)
}

///|
/// 上 (20 tall), a pick of 里 (40 tall) where `on` says so else a case that makes nothing, 下 (20 tall), down a column
/// 10 apart (no box taking no room holding nothing round it).
fn sg_pick_tree(on : @signals.Signal[Bool], at_once? : Bool = false) -> @view.Tree {
  @view.Tree::new(fn(root) {
    root.gap(Is(10.0)) |> ignore
    root.box(fn(b) { b.height(Is(Some(20.0))).words(Is("上")) |> ignore }) |> ignore
    root.pick(at_once~, fn() { on.get() }, fn(v, k) {
      if k {
        v.height(Is(Some(40.0))).words(Is("里")) |> ignore
      }
    })
    root.box(fn(b) { b.height(Is(Some(20.0))).words(Is("下")) |> ignore }) |> ignore
  })
}

///|
test "a pick down a column at once, a case that makes nothing and back: no gap of its own while it makes nothing" {
  let on = @signals.signal(false, same=fn(a, b) { a == b })
  let t = sg_pick_tree(on, at_once=true)
  t.frame(390.0, 844.0) |> ignore
  assert_eq(sg_y(t, "下"), 30.0)
  t.event(100.0, fn() { on.set(true) })
  t.at(100.0)
  t.frame(390.0, 844.0) |> ignore
  assert_eq(sg_y(t, "里"), 30.0)
  assert_eq(sg_y(t, "下"), 80.0)
  t.event(200.0, fn() { on.set(false) })
  t.at(200.0)
  t.frame(390.0, 844.0) |> ignore
  assert_eq(sg_y(t, "下"), 30.0)
  assert_false(t.clock_read())
}

///|
test "a pick down a column changed to a case that makes nothing: the gap closes with its way and stays closed as it ends" {
  let on = @signals.signal(true, same=fn(a, b) { a == b })
  let t = sg_pick_tree(on)
  t.frame(390.0, 844.0) |> ignore
  assert_eq(sg_y(t, "下"), 80.0)
  t.event(100.0, fn() { on.set(false) })
  let ys = sg_frames(t, 100.0, 900.0, fn() { sg_y(t, "下") })
  assert_eq(ys[0], 80.0)
  for i in 1..<ys.length() {
    assert_true(ys[i] <= ys[i - 1], msg="closes only: \{Repr(ys)}")
  }
  let most = sg_most_step(ys)
  assert_true(most < 12.0, msg="no step: the most a frame \{most}, \{Repr(ys)}")
  assert_eq(ys[ys.length() - 1], 30.0, msg="\{Repr(ys)}")
  // (at rest, after its way: still no gap of its own, nothing reading the clock)
  t.at(1500.0)
  t.frame(390.0, 844.0) |> ignore
  assert_eq(sg_y(t, "下"), 30.0)
  assert_eq(sg_y(t, "里"), -1.0)
  assert_false(t.clock_read())
}

///|
test "a pick down a column changed from a case that makes nothing: the gap opens with its way, the same at every rate" {
  let on = @signals.signal(false, same=fn(a, b) { a == b })
  let t = sg_pick_tree(on)
  t.frame(390.0, 844.0) |> ignore
  assert_eq(sg_y(t, "下"), 30.0)
  t.event(100.0, fn() { on.set(true) })
  let ys = sg_frames(t, 100.0, 900.0, fn() { sg_y(t, "下") })
  assert_eq(ys[0], 30.0)
  assert_eq(ys[ys.length() - 1], 80.0)
  for i in 1..<ys.length() {
    assert_true(ys[i] >= ys[i - 1], msg="opens only: \{Repr(ys)}")
  }
  let most = sg_most_step(ys)
  assert_true(most < 12.0, msg="no step: the most a frame \{most}, \{Repr(ys)}")
  assert_false(t.clock_read())
  // (at moments, drawn in one jump and at 60, 120, 24 and 7 a second, both ways)
  let at_moments = fn(rate : Double) -> Array[Double] {
    let on = @signals.signal(false, same=fn(a, b) { a == b })
    let t = sg_pick_tree(on)
    t.frame(390.0, 844.0) |> ignore
    let out = []
    let ms = Ref(0.0)
    let step_to = fn(to : Double) {
      if rate > 0.0 {
        let every = 1000.0 / rate
        while ms.val + every < to {
          ms.val = ms.val + every
          t.at(ms.val)
          t.frame(390.0, 844.0) |> ignore
        }
      }
      ms.val = to
      t.at(to)
      t.frame(390.0, 844.0) |> ignore
      out.push(sg_y(t, "下"))
    }
    t.event(100.0, fn() { on.set(true) })
    step_to(130.0)
    step_to(180.0)
    step_to(250.0)
    step_to(900.0)
    t.event(900.0, fn() { on.set(false) })
    step_to(930.0)
    step_to(980.0)
    step_to(1050.0)
    step_to(1700.0)
    out
  }
  let jumped = at_moments(0.0)
  assert_eq(jumped[3], 80.0)
  assert_eq(jumped[7], 30.0)
  for rate in [60.0, 120.0, 24.0, 7.0] {
    let got = at_moments(rate)
    for i in 0..<jumped.length() {
      assert_true((jumped[i] - got[i]).abs() < 0.01, msg="at \{rate}: \{Repr(jumped)} \{Repr(got)}")
    }
  }
}

///|
test "a pick down a column called back half way, both ways: it turns with no step and lands where it was" {
  // (40 to nothing, back at 160)
  let on = @signals.signal(true, same=fn(a, b) { a == b })
  let t = sg_pick_tree(on)
  t.frame(390.0, 844.0) |> ignore
  t.event(100.0, fn() { on.set(false) })
  let going = sg_frames(t, 100.0, 160.0, fn() { sg_y(t, "下") })
  let low = going[going.length() - 1]
  assert_true(low > 30.0 && low < 80.0, msg="half way: \{Repr(going)}")
  t.event(160.0, fn() { on.set(true) })
  let ys = going + sg_frames(t, 160.0, 1000.0, fn() { sg_y(t, "下") })
  let most = sg_most_step(ys)
  assert_true(most < 12.0, msg="no step as it turns: the most a frame \{most}, \{Repr(ys)}")
  assert_eq(ys[ys.length() - 1], 80.0)
  assert_false(t.clock_read())
  // (nothing to 40, back at 160)
  let on = @signals.signal(false, same=fn(a, b) { a == b })
  let t = sg_pick_tree(on)
  t.frame(390.0, 844.0) |> ignore
  t.event(100.0, fn() { on.set(true) })
  let coming = sg_frames(t, 100.0, 160.0, fn() { sg_y(t, "下") })
  let high = coming[coming.length() - 1]
  assert_true(high > 30.0 && high < 80.0, msg="half way: \{Repr(coming)}")
  t.event(160.0, fn() { on.set(false) })
  let ys = coming + sg_frames(t, 160.0, 1000.0, fn() { sg_y(t, "下") })
  let most = sg_most_step(ys)
  assert_true(most < 12.0, msg="no step as it turns: the most a frame \{most}, \{Repr(ys)}")
  assert_eq(ys[ys.length() - 1], 30.0)
  t.at(1600.0)
  t.frame(390.0, 844.0) |> ignore
  assert_eq(sg_y(t, "下"), 30.0)
  assert_false(t.clock_read())
}

///|
test "a pick along a row to a case that makes nothing and back: the gap closes and opens with its way across, none left" {
  let on = @signals.signal(true, same=fn(a, b) { a == b })
  let t = @view.Tree::new(fn(root) {
    root.box(fn(r) {
      r.row(Is(true)).gap(Is(10.0)) |> ignore
      r.box(fn(b) { b.width(Is(Some(20.0))).words(Is("甲")) |> ignore }) |> ignore
      r.pick(along_row=true, fn() { on.get() }, fn(v, k) {
        if k {
          v.width(Is(Some(30.0))).words(Is("中")) |> ignore
        }
      })
      r.box(fn(b) { b.width(Is(Some(20.0))).words(Is("乙")) |> ignore }) |> ignore
    })
    |> ignore
  })
  t.frame(390.0, 844.0) |> ignore
  assert_eq(sg_x(t, "乙"), 70.0)
  t.event(100.0, fn() { on.set(false) })
  let xs = sg_frames(t, 100.0, 900.0, fn() { sg_x(t, "乙") })
  for i in 1..<xs.length() {
    assert_true(xs[i] <= xs[i - 1], msg="closes only: \{Repr(xs)}")
  }
  assert_true(sg_most_step(xs) < 12.0, msg="no step: \{Repr(xs)}")
  assert_eq(xs[xs.length() - 1], 30.0, msg="\{Repr(xs)}")
  t.at(1500.0)
  t.frame(390.0, 844.0) |> ignore
  assert_eq(sg_x(t, "乙"), 30.0)
  t.event(1500.0, fn() { on.set(true) })
  let xs = sg_frames(t, 1500.0, 2300.0, fn() { sg_x(t, "乙") })
  assert_eq(xs[0], 30.0)
  for i in 1..<xs.length() {
    assert_true(xs[i] >= xs[i - 1], msg="opens only: \{Repr(xs)}")
  }
  assert_true(sg_most_step(xs) < 12.0, msg="no step: \{Repr(xs)}")
  assert_eq(xs[xs.length() - 1], 70.0)
  assert_false(t.clock_read())
}

///|
test "a pick whose case holds only a show: nothing made while it shows nothing, all of it while it shows, again and again" {
  let on = @signals.signal(false, same=fn(a, b) { a == b })
  let t = @view.Tree::new(fn(root) {
    root.gap(Is(10.0)) |> ignore
    root.box(fn(b) { b.height(Is(Some(20.0))).words(Is("上")) |> ignore }) |> ignore
    root.pick(fn() { 0 }, fn(v, _) {
      v.show(fn() { on.get() }, fn(s) { s.height(Is(Some(40.0))).words(Is("里")) |> ignore })
    })
    root.box(fn(b) { b.height(Is(Some(20.0))).words(Is("下")) |> ignore }) |> ignore
  })
  t.frame(390.0, 844.0) |> ignore
  assert_eq(sg_y(t, "下"), 30.0)
  for round in [0, 1] {
    let from = 100.0 + round.to_double() * 2000.0
    t.event(from, fn() { on.set(true) })
    let ys = sg_frames(t, from, from + 800.0, fn() { sg_y(t, "下") })
    assert_eq(ys[ys.length() - 1], 80.0, msg="shown, round \{round}: \{Repr(ys)}")
    for i in 1..<ys.length() {
      assert_true(ys[i] >= ys[i - 1], msg="opens only, round \{round}: \{Repr(ys)}")
    }
    t.event(from + 1000.0, fn() { on.set(false) })
    let ys = sg_frames(t, from + 1000.0, from + 1800.0, fn() { sg_y(t, "下") })
    assert_eq(ys[ys.length() - 1], 30.0, msg="shown no more, round \{round}: \{Repr(ys)}")
    for i in 1..<ys.length() {
      assert_true(ys[i] <= ys[i - 1], msg="closes only, round \{round}: \{Repr(ys)}")
    }
    assert_eq(sg_y(t, "里"), -1.0)
  }
  assert_false(t.clock_read())
}

///|
test "Room::tall across a row with an empty pick beside it: the same as it is laid out, no gap of the pick's taken from it" {
  // (a row 300 across, 10 apart: words grown across what is left, two lines (60) under 250, one (30) at 250 or more;
  // beside them one 40 wide and a pick of a case that makes nothing: 250 left them)
  let words : Ref[@view.View?] = Ref(None)
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(col) {
        col.width(Is(Some(300.0))) |> ignore
        col.by_room(fn(held, room) {
          held.box(fn(r) {
            r.row(Is(true)).gap(Is(10.0)) |> ignore
            let w = r.box(fn(b) {
              b.grow(Is(1.0)).ground(Is(0x0000FFFFL)) |> ignore
              b.measured(Is(0), fn(_, w) {
                let w = w.unwrap_or(300.0)
                (w, if w < 250.0 { 60.0 } else { 30.0 })
              })
              |> ignore
            })
            words.val = Some(w)
            r.box(fn(b) { b.width(Is(Some(40.0))).height(Is(Some(10.0))) |> ignore }) |> ignore
            r.pick(at_once=true, fn() { 0 }, fn(_, _) { () })
          })
          |> ignore
          held.pick(at_once=true, fn() { room.tall(words.val.unwrap()) }, fn(v, k) {
            v.height(Is(Some(10.0))).words(Is("高\{k}")) |> ignore
          })
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(400.0, 300.0) |> ignore
  let laid = t.drawn_of(words.val.unwrap().id()).map(fn(d) { d.h })
  assert_eq(laid, Some(30.0), msg="laid out 250 across: one line")
  assert_true(sg_y(t, "高30") >= 0.0, msg="measured the same: \{Repr(t.drawn().map(fn(d) { d.words }))}")
}

///|
/// A page's list of 30 keys under a cover, each block 10 apart down it: 上k (16), a pick of a case that makes nothing
/// where `more` says not (else 12), 名k (16), 行k (`words`, 40), marked where it is read.
fn sg_list(
  words : Map[Int, @signals.Signal[Double]],
  more : @signals.Signal[Bool],
) -> (@view.Tree, @view.Scroll) {
  let scroll = @view.Scroll::list()
  let keys = @signals.signal(Array::makei(30, fn(i) { i }), same=fn(a, b) { a == b })
  let of = fn(k : Int) -> @signals.Signal[Double] {
    match words.get(k) {
      Some(s) => s
      None => {
        let s = @signals.signal(40.0, same=fn(a, b) { a == b })
        words[k] = s
        s
      }
    }
  }
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(300.0))) |> ignore
      o.scrolls_window(scroll, fn() { keys.get() }, est=92.0, top_covered=fn() { 50.0 }, fn(b, k) {
        let st = of(k)
        b.gap(Is(10.0)) |> ignore
        b.box(fn(g) { g.height(Is(Some(16.0))).words(Is("上\{k}")) |> ignore }) |> ignore
        b.pick(at_once=true, fn() { more.get() }, fn(g, on) {
          if on {
            g.height(Is(Some(12.0))) |> ignore
          }
        })
        b.box(fn(h) { h.height(Is(Some(16.0))).words(Is("名\{k}")) |> ignore }) |> ignore
        b.box(fn(w) {
          w.height(By(fn() { Some(st.get()) })).words(Is("行\{k}")).read_from() |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  // (block 9 put 10 over the top: its words start at 42, under the cover; 10's at 134, in sight: 10 is what is read)
  tree.event(1.0, fn() { scroll.put(9.0 * 92.0 + 10.0) })
  tree.at(2.0)
  tree.frame(390.0, 844.0) |> ignore
  (tree, scroll)
}

///|
test "a page's list held by what is read, an empty pick over its words: no gap of it, held there in every frame, at every rate" {
  for rate in rc_rates {
    let words : Map[Int, @signals.Signal[Double]] = Map([])
    let more = @signals.signal(false, same=fn(a, b) { a == b })
    let (t, _) = sg_list(words, more)
    // (in its block: 16 of 上, 10 of gap, then 名: no gap of the pick's)
    assert_eq(sg_y(t, "名10") - sg_y(t, "上10"), 26.0, msg="at \{rate}")
    assert_eq(sg_y(t, "行10") - sg_y(t, "名10"), 26.0, msg="at \{rate}")
    assert_eq(sg_y(t, "行10"), 134.0, msg="at \{rate}: put where the scene says")
    let was = sg_y(t, "行10")
    let ys = rc_walk(
      t,
      [(rc_at, fn() { words.get(9).unwrap().set(80.0) })],
      rc_looks(rc_at + 600.0),
      rate,
      from=2.0,
      fn() { sg_y(t, "行10") },
    )
    for i, y in ys {
      assert_true((y - was).abs() <= 0.25, msg="at \{rate}, look \{i}: \{y}, was \{was}: \{Repr(ys)}")
    }
  }
}

///|
test "a structure holding only what takes keys and back: no gap of its own, its keys and back taken; shown no more or what holds it laid out nowhere, none" {
  let on = @signals.signal(true, same=fn(a, b) { a == b })
  let nowhere = @signals.signal(false, same=fn(a, b) { a == b })
  let keys : Array[Int] = []
  let backs : Array[Int] = []
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(col) {
        col.gap(Is(10.0)).laid_nowhere(By(fn() { nowhere.get() })) |> ignore
        col.box(fn(b) { b.height(Is(Some(20.0))).words(Is("上")) |> ignore }) |> ignore
        col.show(fn() { on.get() }, fn(v) {
          v.on_key(fn(k) {
            keys.push(k.code)
            true
          })
          |> ignore
          v.takes_back(fn() { backs.push(1) }) |> ignore
        })
        col.box(fn(b) { b.height(Is(Some(20.0))).words(Is("下")) |> ignore }) |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(390.0, 844.0) |> ignore
  // (20 + 10: one gap, none of its own)
  assert_eq(sg_y(t, "下"), 30.0)
  // (in the scene as ever: its keys and back taken)
  assert_eq(t.key_at(5, 0, 10.0), true)
  assert_eq(keys, [5])
  match t.back_taker() {
    Some(id) => t.back_step(id, Back, 20.0) |> ignore
    None => fail("its back taken")
  }
  assert_eq(backs, [1])
  // (what holds it laid out nowhere: none of it taken)
  nowhere.set(true)
  t.frame(390.0, 844.0) |> ignore
  assert_eq(t.key_at(6, 0, 30.0), false)
  assert_eq(t.back_taker(), None)
  nowhere.set(false)
  t.frame(390.0, 844.0) |> ignore
  assert_eq(sg_y(t, "下"), 30.0)
  assert_eq(t.key_at(7, 0, 40.0), true)
  assert_eq(keys, [5, 7])
  // (shown no more: none of it taken, still no gap)
  on.set(false)
  t.frame(390.0, 844.0) |> ignore
  assert_eq(t.key_at(8, 0, 50.0), false)
  assert_eq(t.back_taker(), None)
  assert_eq(sg_y(t, "下"), 30.0)
  assert_eq(keys, [5, 7])
}
