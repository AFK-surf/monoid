// A page's list whose keys change by data, said `flips` (View::scrolls_window): laid out once as the change ends it,
// each block drawn off where it is laid out by how far it was from there as the change came, all of it one way
// (flex's FlipWay), read where it is drawn: nothing laid out again on the way (the user, 2026-11-15: 「新架构 chat 页很卡」,
// the motion of a list in its layout every frame). At its foot what is over a key come goes up with it, one way, only
// up; the key grows from its top as what is over it goes up. Looked at at 60 a second and in one jump.

///|
/// A page's list 300 by 400 of rows 0 to 9 (40 each) following its foot, said `flips`; key 70 is 60 high.
fn fp_case(flips? : Bool = true) -> (@view.Tree, @signals.Signal[Array[Int]]) {
  let keys = @signals.signal(rc_ten_and([]), same=fn(a, b) { a == b })
  let scroll = @view.Scroll::list()
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(scroll, fn() { keys.get() }, est=40.0, follows=fn() { true }, flips~, fn(b, k) {
        b.height(Is(Some(if k == 70 { 60.0 } else { 40.0 }))).words(Is("行\{k}")) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  (tree, keys)
}

///|
test "flips: a key come at its foot takes what is over it up 60 on one way, only up, and nothing is laid out on the way" {
  let (t, keys) = fp_case()
  let y0 = rc_y(t, "行8")
  let at = rc_at
  t.advance(at)
  keys.set(rc_ten_and([70]))
  t.frame(390.0, 844.0, now=at) |> ignore
  let laid0 = t.work().computes
  let first = rc_y(t, "行8")
  assert_true((first - y0).abs() < 0.5, msg="行8 moved \{first - y0} in the change's frame")
  let mut was = first
  let mut moved = false
  let mut ms = 0.0
  while ms < 600.0 {
    ms = ms + 1000.0 / 60.0
    t.frame(390.0, 844.0, now=at + ms) |> ignore
    let y = rc_y(t, "行8")
    assert_true(y <= was + 0.01, msg="at \{ms}: 行8 down from \{was} to \{y}")
    if y < was - 0.01 {
      moved = true
    }
    was = y
  }
  assert_true(moved, msg="行8 never moved")
  assert_true((y0 - was - 60.0).abs() < 0.5, msg="行8 up \{y0 - was}, 60 wanted")
  assert_eq(t.work().computes - laid0, 0, msg="laid out on the way")
}

///|
test "the same key come as a column's way (not flips): laid out on the way, as it was before (what the first holds against)" {
  let (t, keys) = fp_case(flips=false)
  t.advance(rc_at)
  keys.set(rc_ten_and([70]))
  t.frame(390.0, 844.0, now=rc_at) |> ignore
  let laid0 = t.work().computes
  t.frame(390.0, 844.0, now=rc_at + 100.0) |> ignore
  t.frame(390.0, 844.0, now=rc_at + 200.0) |> ignore
  assert_true(t.work().computes - laid0 > 0, msg="nothing laid out on a column's way: the count shows nothing")
}

///|
test "flips: a second key come 120 ms after the first, the first still on its way: one way from where it all is, only up, the same at every rate" {
  let looks = rc_looks(rc_at + 900.0)
  let events = [(rc_at, rc_ten_and([70])), (rc_at + rc_again_ms, rc_ten_and([70, 71]))]
  let by_rate = rc_rates.map(fn(rate) {
    let c = rc_case(rc_ten_and([]), flips=true)
    let was = rc_y(c.tree, "行8")
    let ys = rc_walk(c.tree, events.map(fn(e) { (e.0, fn() { c.keys.set(e.1) }) }), looks, rate, fn() { rc_y(c.tree, "行8") })
    (was, ys)
  })
  for i, rate in rc_rates {
    let (was, ys) = by_rate[i]
    let mut last = was
    for j, y in ys {
      assert_true(y <= last + 0.01, msg="at \{rate} a second, look \{j}: 行8 down from \{last} to \{y}")
      last = y
    }
    assert_true((was - last - 100.0).abs() < 0.5, msg="at \{rate} a second: 行8 up \{was - last}, 100 wanted")
    let (_, one) = by_rate[0]
    for j, y in ys {
      assert_true((y - one[j]).abs() < 0.01, msg="at \{rate} a second, look \{j}: \{y}, \{one[j]} in one jump")
    }
  }
}

///|
test "flips: scrolled up, a key put in within sight: what is over it stays where it is at every look" {
  let keys = Array::makei(20, fn(i) { i })
  let put_in = Array::makei(10, fn(i) { i })
  put_in.push(100)
  put_in.append(Array::makei(10, fn(i) { i + 10 }))
  for rate in rc_rates {
    let c = rc_case(keys, flips=true)
    c.scroll.put(300.0)
    c.tree.frame(390.0, 844.0) |> ignore
    let was = (rc_y(c.tree, "行7"), rc_y(c.tree, "行9"))
    let got = rc_walk(c.tree, [(rc_at, fn() { c.keys.set(put_in) })], rc_looks(rc_at + 600.0), rate, fn() {
      (rc_y(c.tree, "行7"), rc_y(c.tree, "行9"), rc_y(c.tree, "行10"))
    })
    for j, r in got {
      assert_true((r.0 - was.0).abs() < 0.01 && (r.1 - was.1).abs() < 0.01, msg="at \{rate} a second, look \{j}: \{Repr(r)} over it, \{Repr(was)} before")
    }
    let end = got[got.length() - 1]
    assert_true((end.2 - (was.1 + 40.0 + rc_tall(100))).abs() < 0.5, msg="at \{rate} a second: 行10 at \{end.2}")
  }
}

///|
test "flips: a key come grows from its top, unseen till half of it is open, whole at rest, its words never taller than it is" {
  for rate in rc_rates {
    let c = rc_case(rc_ten_and([]), flips=true)
    let read = fn() {
      match c.tree.drawn().filter(fn(d) { d.words == "行70" }) {
        [d, ..] => (d.alpha, d.h)
        _ => (-1.0, -1.0)
      }
    }
    let got = rc_walk(c.tree, [(rc_at, fn() { c.keys.set(rc_ten_and([70])) })], [rc_at, rc_at + 30.0, rc_at + 600.0], rate, read)
    let (a0, _) = got[0]
    assert_true(a0 <= 0.001, msg="at \{rate} a second: drawn at \{a0} as it comes")
    let (a2, h2) = got[2]
    assert_true((a2 - 1.0).abs() < 0.001 && h2 > 0.0, msg="at \{rate} a second: at rest at \{a2}")
  }
}

///|
test "flips: what a test reads of a row (Tree::list_in_front) is where it is drawn on its way" {
  let c = rc_case(rc_ten_and([]), flips=true)
  let row8 = fn() {
    match c.tree.list_in_front() {
      Some(l) =>
        match l.rows.iter().find_first(fn(r) { r.0 == 8 }) {
          Some((_, _, (_, y, _, _))) => y
          None => rc_none
        }
      None => rc_none
    }
  }
  let got = rc_walk(c.tree, [(rc_at, fn() { c.keys.set(rc_ten_and([70])) })], [rc_at, rc_at + 50.0, rc_at + 600.0], 60.0, fn() {
    (row8(), rc_y(c.tree, "行8"))
  })
  for j, g in got {
    assert_true((g.0 - g.1).abs() < 0.5, msg="look \{j}: the row read at \{g.0}, its words drawn at \{g.1}")
  }
}

///|
test "flips: a part in a block at its foot closing: laid out at once, what is over it coming down one way to keep the foot, nothing laid out on the way" {
  let keys = @signals.signal(rc_ten_and([]), same=fn(a, b) { a == b })
  let part = @signals.signal(true, same=fn(a, b) { a == b })
  let scroll = @view.Scroll::list()
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(scroll, fn() { keys.get() }, est=40.0, follows=fn() { true }, flips=true, fn(b, k) {
        b.box(fn(w) { w.height(Is(Some(40.0))).shrink(Is(0.0)).words(Is("行\{k}")) |> ignore }) |> ignore
        if k == 9 {
          b.show(fn() { part.get() }, fn(p) { p.height(Is(Some(30.0))).shrink(Is(0.0)).words(Is("部9")) |> ignore })
        }
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  let y0 = rc_y(tree, "行8")
  tree.advance(rc_at)
  part.set(false)
  tree.frame(390.0, 844.0, now=rc_at) |> ignore
  let laid0 = tree.work().computes
  assert_true((rc_y(tree, "行8") - y0).abs() < 0.5, msg="行8 moved in the change's frame")
  let mut was = y0
  let mut ms = 0.0
  while ms < 600.0 {
    ms = ms + 1000.0 / 60.0
    tree.frame(390.0, 844.0, now=rc_at + ms) |> ignore
    let y = rc_y(tree, "行8")
    assert_true(y >= was - 0.01, msg="at \{ms}: 行8 up from \{was} to \{y}")
    was = y
  }
  assert_true((was - y0 - 30.0).abs() < 0.5, msg="行8 down \{was - y0}, 30 wanted")
  assert_eq(tree.work().computes - laid0, 0, msg="laid out on the way")
}

///|
test "flips: a part come in the middle of a block, the list at its top: what is under it in the block and the blocks after go down one way with it, the part grown from its top, nothing laid out on the way" {
  let keys = @signals.signal(Array::makei(12, fn(i) { i }), same=fn(a, b) { a == b })
  let part = @signals.signal(false, same=fn(a, b) { a == b })
  let scroll = @view.Scroll::list()
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(scroll, fn() { keys.get() }, est=40.0, flips=true, fn(b, k) {
        b.box(fn(w) { w.height(Is(Some(40.0))).shrink(Is(0.0)).words(Is("行\{k}")) |> ignore }) |> ignore
        if k == 3 {
          b.show(fn() { part.get() }, fn(p) { p.height(Is(Some(30.0))).shrink(Is(0.0)).words(Is("部3")) |> ignore })
          b.box(fn(w) { w.height(Is(Some(20.0))).shrink(Is(0.0)).words(Is("尾3")) |> ignore }) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  let tail0 = rc_y(tree, "尾3")
  let next0 = rc_y(tree, "行4")
  tree.advance(rc_at)
  part.set(true)
  tree.frame(390.0, 844.0, now=rc_at) |> ignore
  let laid0 = tree.work().computes
  assert_true((rc_y(tree, "尾3") - tail0).abs() < 0.5, msg="尾3 moved in the change's frame: \{rc_y(tree, "尾3") - tail0}")
  assert_true((rc_y(tree, "行4") - next0).abs() < 0.5, msg="行4 moved in the change's frame")
  let mut was = tail0
  let mut ms = 0.0
  while ms < 600.0 {
    ms = ms + 1000.0 / 60.0
    tree.frame(390.0, 844.0, now=rc_at + ms) |> ignore
    let y = rc_y(tree, "尾3")
    assert_true(y >= was - 0.01 && y - was < 8.0, msg="at \{ms}: 尾3 from \{was} to \{y}")
    let n = rc_y(tree, "行4")
    assert_true((n - y - 20.0).abs() < 0.5, msg="at \{ms}: 行4 at \{n}, 尾3 at \{y}")
    was = y
  }
  assert_true((was - tail0 - 30.0).abs() < 0.5, msg="尾3 down \{was - tail0}, 30 wanted")
  assert_eq(tree.work().computes - laid0, 0, msg="laid out on the way")
}

///|
/// What block 9 of lf_anew's list says, broken into more lines the narrower its list is laid out.
let lf_anew_words : String = "一段在列表变窄时要折成更多行的长字，变宽时又回到少几行，字的大小每一帧都不该变。"

///|
/// A page's list 400 tall of rows 0 to 9 following its foot, said `flips`, as wide as `w`; block 9 a room over it (12
/// over 200 wide with few words, else 8), put in `gap` as it is made, then `words` as they are, broken by the width.
fn lf_anew(
  w : @signals.Signal[Double],
  words : @signals.Signal[String],
  gap : Ref[@view.View?],
) -> @view.Tree {
  let scroll = @view.Scroll::list()
  let keys = @signals.signal(rc_ten_and([]), same=fn(a, b) { a == b })
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(By(fn() { Some(w.get()) })).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(scroll, fn() { keys.get() }, est=40.0, follows=fn() { true }, flips=true, fn(b, k) {
        if k == 9 {
          // (the room over it, declared on the list's way as what changes it comes, as a chat's row's is)
          b.box(fn(g) {
            gap.val = Some(g)
            g.height(By(fn() { Some(if w.get() > 200.0 && words.get().length() < 60 { 12.0 } else { 8.0 }) })).shrink(Is(0.0)) |> ignore
          })
          |> ignore
          b.box(fn(t) { t.words(By(fn() { words.get() })) |> ignore }) |> ignore
        } else {
          b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  tree
}

///|
/// How the words that start as `start` are drawn in `tree`: how wide, and how big against as they are laid out (its
/// scale; how tall it is drawn is how much of it is cut into sight as its block opens, Tree::grown_cut_of).
fn lf_words_size(tree : @view.Tree, start : String) -> (Double, Double) {
  let scales : Array[Double] = []
  let held = tree.drawn_held(scales~)
  for i, e in held {
    if e.0.words.has_prefix(start) {
      return (e.0.w, scales[i])
    }
  }
  (rc_none, rc_none)
}

///|
/// How tall the words that start as `start` are laid out in `tree`.
fn lf_words_tall(tree : @view.Tree, start : String) -> Double {
  match tree.laid_held().filter(fn(e) { e.0.words.has_prefix(start) }) {
    [e, ..] => e.0.h
    _ => rc_none
  }
}

///|
/// Each of `got` (how wide, its scale) the last one, at 1: its words drawn whole at their size from the frame of the
/// cause (`at`: the scene), come to more lines (`from` and `to` how tall they are laid out before and after).
fn lf_whole(
  got : Array[(Double, Double)],
  from : Double,
  to_tall : Double,
  looks : Array[Double],
  at : String,
) -> Unit raise {
  assert_true((to_tall - from).abs() > 10.0, msg="\{at}: no more lines: \{from} to \{to_tall} tall")
  let to = got.last().unwrap()
  for i, s in got {
    assert_true(
      (s.0 - to.0).abs() < 0.01 && (s.1 - 1.0).abs() < 0.0001,
      msg="\{at}, at \{looks[i]}: the words drawn \{Repr(s)} (wide, scale), \{Repr(to)} at rest\n\{Repr(got)}",
    )
  }
}

///|
test "flips: a block laid out at another width as its column sets off on a way to it (its words broken anew, its room over it declared on the list's way): its words drawn whole at their size from the first frame, never grown from their top" {
  let looks = rc_looks(rc_at + 600.0)
  for rate in rc_rates {
    for narrower in [true, false] {
      let w = @signals.signal(if narrower { 300.0 } else { 160.0 }, same=fn(a, b) { a == b })
      let words = @signals.signal(lf_anew_words, same=fn(a, b) { a == b })
      let gap : Ref[@view.View?] = Ref(None)
      let tree = lf_anew(w, words, gap)
      let from = lf_words_tall(tree, "一段")
      let got = rc_walk(tree, [(rc_at, fn() {
        gap.val.unwrap().resizes() |> ignore
        w.set(if narrower { 160.0 } else { 300.0 })
      })], looks, rate, fn() { lf_words_size(tree, "一段") })
      let at = "at \{rate} a second, \{if narrower { "narrower" } else { "wider" }}"
      lf_whole(got, from, lf_words_tall(tree, "一段"), looks, at)
    }
  }
}

///|
test "flips: a block's words come to more lines as the room over it is declared on the list's way (more words streamed in): drawn whole at their size from the first frame, opened as the block is, never grown from their top" {
  let looks = rc_looks(rc_at + 600.0)
  for rate in rc_rates {
    let w = @signals.signal(300.0, same=fn(a, b) { a == b })
    let words = @signals.signal(lf_anew_words, same=fn(a, b) { a == b })
    let gap : Ref[@view.View?] = Ref(None)
    let tree = lf_anew(w, words, gap)
    let from = lf_words_tall(tree, "一段")
    let got = rc_walk(tree, [(rc_at, fn() {
      gap.val.unwrap().resizes() |> ignore
      words.set(lf_anew_words + lf_anew_words + lf_anew_words)
    })], looks, rate, fn() { lf_words_size(tree, "一段") })
    lf_whole(got, from, lf_words_tall(tree, "一段"), looks, "at \{rate} a second")
  }
}

///|
test "flips: keys changing twice before slot_views are placed does not inflate foot_room into a blank screen" {
  let keys = @signals.signal(([] : Array[Int]), same=fn(a, b) { a == b })
  let scroll = @view.Scroll::list()
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(scroll, fn() { keys.get() }, est=40.0, follows=fn() { true }, from_end=true, flips=true, fn(b, k) {
        b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  // First frame establishes viewport (300 x 400) while empty and at foot.
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  // First keys arrive between frames (slots created, laid_now runs, but Tree::place has not run yet).
  let t1 = rc_at
  let t2 = rc_at + 10.0
  let settled = t2 + @flex.move_most_ms
  tree.advance(t1)
  keys.set(Array::makei(10, fn(i) { 10 + i }))
  // Second keys change (e.g. prepending older messages) arrives before the first paint places those slots.
  tree.advance(t2)
  keys.set(Array::makei(20, fn(i) { i }))
  tree.frame(390.0, 844.0, now=t2) |> ignore
  tree.frame(390.0, 844.0, now=settled) |> ignore
  let y19 = rc_y(tree, "行19")
  assert_true(
    y19 > 350.0 && y19 < 370.0,
    msg="last row 行19 should sit at viewport foot (~360.0), got y=\{y19}",
  )
}

///|
test "flips: rest while at foot preserves at_foot so waking still follows new keys at foot" {
  let keys = @signals.signal(Array::makei(30, fn(i) { i }), same=fn(a, b) { a == b })
  let scroll = @view.Scroll::list()
  let place : @view.ListPlace[Int] = @view.ListPlace::new()
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.transitions_only().width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(
        scroll,
        fn() { keys.get() },
        est=40.0,
        follows=fn() { true },
        from_end=true,
        flips=true,
        place~,
        fn(b, k) { b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  assert_true(scroll.at_foot_now(), msg="expected at_foot initially")
  place.rest()
  place.wake()
  let t1 = rc_at
  let settled = t1 + @flex.move_most_ms
  tree.advance(t1)
  keys.set(Array::makei(31, fn(i) { i }))
  tree.frame(390.0, 844.0, now=t1) |> ignore
  tree.frame(390.0, 844.0, now=settled) |> ignore
  let y30 = rc_y(tree, "行30")
  assert_true(
    y30 > 350.0 && y30 < 370.0,
    msg="after rest/wake while at foot, new row 行30 should sit at foot (~360.0), got y=\{y30}",
  )
}

///|
test "flips: transitions_only quiet reopen with shorter keys and to_end lands at foot with no blank room" {
  let keys = @signals.signal(Array::makei(30, fn(i) { i }), same=fn(a, b) { a == b })
  let scroll = @view.Scroll::list()
  let place : @view.ListPlace[Int] = @view.ListPlace::new()
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.transitions_only().width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(
        scroll,
        fn() { keys.get() },
        est=40.0,
        follows=fn() { true },
        from_end=true,
        flips=true,
        place~,
        fn(b, k) { b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  // Scroll up off foot (keeping overlap with the shorter reopened window 15..29).
  let t_scroll = rc_at
  let t_reopen = rc_at + 100.0
  let settled = t_reopen + @flex.move_most_ms
  scroll.put(400.0)
  tree.frame(390.0, 844.0, now=t_scroll) |> ignore
  assert_true(!scroll.at_foot_now(), msg="expected off foot after scrolling up")
  place.rest()
  tree.advance(t_reopen)
  place.wake()
  keys.set(Array::makei(15, fn(i) { 15 + i }))
  place.to_end(glide=false)
  tree.frame(390.0, 844.0, now=t_reopen) |> ignore
  tree.frame(390.0, 844.0, now=settled) |> ignore
  let y29 = rc_y(tree, "行29")
  assert_true(
    y29 > 350.0 && y29 < 370.0,
    msg="after quiet reopen + shorter keys + to_end, 行29 should sit at foot (~360.0), got y=\{y29}",
  )
}

///|
test "flips: transitions_only leaves_room row disappearing quietly leaves no foot_room, while inside transition keeps it" {
  let line_key = 50
  let keys = @signals.signal(rc_ten_and([line_key]), same=fn(a, b) { a == b })
  let scroll = @view.Scroll::list()
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.transitions_only().width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(
        scroll,
        fn() { keys.get() },
        est=40.0,
        follows=fn() { true },
        flips=true,
        leaves_room=fn(k) { k == line_key },
        fn(b, k) {
          b.height(Is(Some(if k == line_key { 80.0 } else { 40.0 }))).words(Is("行\{k}")) |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  let y9_with_line = rc_y(tree, "行9")
  assert_true(
    (y9_with_line - 280.0).abs() < 1.0,
    msg="with 80px line at foot, 行9 should be at 280.0, got \{y9_with_line}",
  )
  // Quiet removal (outside transition): must NOT leave 80px foot_room.
  let t_quiet = rc_at
  let t_quiet_end = t_quiet + @flex.move_most_ms
  tree.advance(t_quiet)
  keys.set(rc_ten_and([]))
  tree.frame(390.0, 844.0, now=t_quiet) |> ignore
  tree.frame(390.0, 844.0, now=t_quiet_end) |> ignore
  let y9_quiet = rc_y(tree, "行9")
  assert_true(
    (y9_quiet - 360.0).abs() < 1.0,
    msg="after quiet leaves_room removal, 行9 should sit at foot (~360.0), got \{y9_quiet}",
  )
  // Explicit transition removal: MUST still keep 80px foot_room.
  let t_readd = t_quiet_end + 100.0
  let t_trans = t_readd + 100.0
  let t_trans_end = t_trans + @flex.move_most_ms
  tree.advance(t_readd)
  keys.set(rc_ten_and([line_key]))
  tree.frame(390.0, 844.0, now=t_readd) |> ignore
  tree.advance(t_trans)
  @view.transition(fn() { keys.set(rc_ten_and([])) })
  tree.frame(390.0, 844.0, now=t_trans) |> ignore
  tree.frame(390.0, 844.0, now=t_trans_end) |> ignore
  let y9_trans = rc_y(tree, "行9")
  assert_true(
    (y9_trans - 280.0).abs() < 1.0,
    msg="after transition leaves_room removal, 行9 should stay at ~280.0 (foot_room kept), got \{y9_trans}",
  )
}

///|
test "scrolls_window: non-foot scroll past new short keys still renders the new rows instead of getting stuck empty" {
  let keys = @signals.signal(Array::makei(50, fn(i) { i }), same=fn(a, b) { a == b })
  let scroll = @view.Scroll::list()
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(
        scroll,
        fn() { keys.get() },
        est=40.0,
        follows=fn() { true },
        from_end=true,
        flips=false,
        fn(b, k) { b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  // Scroll to 1200 (off foot, total height 2000).
  let t_scroll = rc_at / 2.0
  let t_shrink = rc_at
  let t_after = rc_at + 100.0
  scroll.put(1200.0)
  tree.frame(390.0, 844.0, now=t_scroll) |> ignore
  assert_true(!scroll.at_foot_now(), msg="expected off foot at 1200")
  // Suddenly replace keys with a short disjoint list (3 rows = 120px tall < 1200).
  tree.advance(t_shrink)
  keys.set([100, 101, 102])
  tree.frame(390.0, 844.0, now=t_shrink) |> ignore
  tree.frame(390.0, 844.0, now=t_after) |> ignore
  let y102 = rc_y(tree, "行102")
  assert_true(
    y102 >= 0.0 && y102 < 400.0,
    msg="short replacement row 行102 must be visible in viewport [0, 400), got y=\{y102}",
  )
}

///|
test "flips: trimming an off-screen row under a top placeholder inside transition does not accumulate foot_room" {
  let trimmed : Array[Int] = [0]
  for i in 2..<20 {
    trimmed.push(i)
  }
  let looks = [rc_at, rc_at + @flex.move_most_ms / 2.0, rc_at + @flex.move_most_ms]
  for rate in rc_rates {
    let keys = @signals.signal(Array::makei(20, fn(i) { i }), same=fn(a, b) { a == b })
    let scroll = @view.Scroll::list()
    let tree = @view.Tree::new(fn(root) {
      root.box(fn(o) {
        o.transitions_only().width(Is(Some(300.0))).height(Is(Some(200.0))) |> ignore
        o.scrolls_window(
          scroll,
          fn() { keys.get() },
          est=40.0,
          follows=fn() { true },
          from_end=true,
          flips=true,
          fn(b, k) { b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore },
        )
        |> ignore
      })
      |> ignore
    })
    tree.frame(390.0, 844.0, now=0.0) |> ignore
    let y0 = rc_y(tree, "行19")
    assert_true((y0 - 160.0).abs() < 1.0, msg="at \{rate}: initial 行19 should be at ~160.0, got \{y0}")
    let ys = rc_walk(
      tree,
      [(rc_at, fn() { @view.transition(fn() { keys.set(trimmed) }) })],
      looks,
      rate,
      fn() { rc_y(tree, "行19") },
    )
    for j, y in ys {
      assert_true(
        (y - 160.0).abs() < 1.0,
        msg="at \{rate}, look \{j}: 行19 drifted from foot (~160.0) to \{y}",
      )
    }
  }
}
