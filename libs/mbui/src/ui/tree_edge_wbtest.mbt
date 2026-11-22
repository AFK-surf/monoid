// A node's edge round its ground (View::edge): one rect, filled and edged, as an old view's box with a border is drawn
// (scene.mbt's emit_rect): the same instance but for where it is.

///|
/// The rect instances the frame just drawn has `w` × `h` (its numbers from the corner radius on: radius, kind, edge
/// width, blur, fill, edge colour).
fn rects_sized(w : Double, h : Double) -> Array[Array[Double]] {
  let c = g()
  let out = []
  for k in 0..<c.ninst {
    let at = k * inst_size
    if c.inst[at + 2] == w && c.inst[at + 3] == h {
      out.push(Array::makei(12, fn(i) { c.inst[at + 4 + i] }))
    }
  }
  out
}

///|
test "a node's edge: one rect filled and edged, the instance an old view's box with that border draws" {
  let ring = 0xE5704AFFL
  let _ = Tester::new(fn(c) {
    c.box(tx=100.0, ty=100.0, w=Px(12.0), h=Px(12.0), radius=6.0, bg=0xFFFFFFFFL, border=1.5, border_color=ring, fn() {  })
    |> ignore
  })
  let old = rects_sized(12.0, 12.0)
  assert_eq(old.length(), 1, msg="the old box: one rect")
  let t = Tester::new(fn(_c) {  })
  set_view_app(fn(root) {
    root.box(fn(n) {
      n.offset(Is((100.0, 100.0))).width(Is(Some(12.0))).height(Is(Some(12.0))).radius(Is(6.0)).ground(Is(0xFFFFFFFFL)).edge(Is((1.5, ring)))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let node = rects_sized(12.0, 12.0)
  assert_eq(node, old, msg="the node: the same one rect")
}

///|
test "a node's edge half seen (what holds it at 0.5): the instance an old view's box with that border draws at 0.5" {
  let ring = 0xE5704AFFL
  let _ = Tester::new(fn(c) {
    c.box(opacity=0.5, fn() {
      c.box(tx=100.0, ty=100.0, w=Px(12.0), h=Px(12.0), radius=6.0, bg=0xFFFFFFFFL, border=1.5, border_color=ring, fn() {  })
      |> ignore
    })
    |> ignore
  })
  let old = rects_sized(12.0, 12.0)
  assert_eq(old.length(), 1, msg="the old box: one rect")
  let t = Tester::new(fn(_c) {  })
  set_view_app(fn(root) {
    root.box(fn(h) {
      h.alpha(Is(0.5)) |> ignore
      h.box(fn(n) {
        n.offset(Is((100.0, 100.0))).width(Is(Some(12.0))).height(Is(Some(12.0))).radius(Is(6.0)).ground(Is(0xFFFFFFFFL)).edge(Is((1.5, ring)))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(rects_sized(12.0, 12.0), old, msg="the node at 0.5: the same one rect")
}

///|
test "a node's edge round what it holds, reaching its edges: its ground inside the edge, what it holds, then the edge over it, the instances an old view's box with that border draws in that order" {
  let ring = 0xE5704AFFL
  let _ = Tester::new(fn(c) {
    c.box(tx=100.0, ty=100.0, w=Px(40.0), h=Px(24.0), radius=6.0, bg=0xFFFFFFFFL, border=1.5, border_color=ring, fn() {
      c.box(w=Fill(1.0), h=Fill(1.0), bg=0x2050A0FFL, fn() {  }) |> ignore
    })
    |> ignore
  })
  let old = rects_sized(40.0, 24.0)
  assert_eq(old.length(), 3, msg="the old box: its ground, what it holds, its border \{Repr(old)}")
  let t = Tester::new(fn(_c) {  })
  set_view_app(fn(root) {
    root.box(fn(n) {
      n.offset(Is((100.0, 100.0))).width(Is(Some(40.0))).height(Is(Some(24.0))).radius(Is(6.0)).ground(Is(0xFFFFFFFFL)).edge(Is((1.5, ring)))
      |> ignore
      n.box(fn(k) { k.grow(Is(1.0)).ground(Is(0x2050A0FFL)) |> ignore }) |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(rects_sized(40.0, 24.0), old, msg="the node: the same three, in that order")
}

///|
test "a node's clear edge round what it holds: its ground inside the edge, the edge's band left clear, the instances an old view's box with a clear border draws" {
  // (a tile ringed only while lit: off, a border of no colour, its ground stopping inside it all the same)
  let _ = Tester::new(fn(c) {
    c.box(tx=100.0, ty=100.0, w=Px(40.0), h=Px(24.0), radius=6.0, bg=0xFFFFFFFFL, border=2.0, border_color=0L, fn() {
      c.box(w=Fill(1.0), h=Fill(1.0), bg=0x2050A0FFL, fn() {  }) |> ignore
    })
    |> ignore
  })
  let old = rects_sized(40.0, 24.0)
  let t = Tester::new(fn(_c) {  })
  set_view_app(fn(root) {
    root.box(fn(n) {
      n.offset(Is((100.0, 100.0))).width(Is(Some(40.0))).height(Is(Some(24.0))).radius(Is(6.0)).ground(Is(0xFFFFFFFFL)).edge(Is((2.0, 0L)))
      |> ignore
      n.box(fn(k) { k.grow(Is(1.0)).ground(Is(0x2050A0FFL)) |> ignore }) |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(rects_sized(40.0, 24.0), old, msg="the node: as the old box's")
}

///|
/// Where the frame just drawn has a rect instance edged in `ring` (its edge's colour, red at 8 bits in 12) or filled
/// `fill`: its index, the first such.
fn inst_where(pick : (Int) -> Bool) -> Int {
  let c = g()
  for k in 0..<c.ninst {
    if pick(k * inst_size) {
      return k
    }
  }
  -1
}

///|
/// A node 40 × 24 at (100, 100), round 6, its ground `ground`, edged 1.5 in a red, holding a node across all of it (its
/// own ground a blue), drawn as `look` says besides. The Tester, and the node.
fn edged_holder(ground : Int64, look : (@view.View) -> Unit) -> (Tester, Ref[@view.NodeId?]) {
  let id : Ref[@view.NodeId?] = Ref(None)
  let t = Tester::new(fn(_c) {  })
  set_view_app(fn(root) {
    root.box(fn(n) {
      id.val = Some(n.id())
      n.offset(Is((100.0, 100.0))).width(Is(Some(40.0))).height(Is(Some(24.0))).radius(Is(6.0)).ground(Is(ground)).edge(Is((1.5, 0xE5704AFFL)))
      |> ignore
      look(n)
      n.box(fn(k) { k.grow(Is(1.0)).ground(Is(0x2050A0FFL)) |> ignore }) |> ignore
    })
    |> ignore
  })
  t.draw()
  (t, id)
}

///|
/// Whether instance `k`'s edge is the red of edged_holder's (its edge colour's red, 12, at 0xE5).
fn red_edged(at : Int) -> Bool {
  let c = g()
  (c.inst[at + 12] * 255.0).round() == 229.0 && c.inst[at + 15] > 0.0 && c.inst[at + 11] == 0.0
}

///|
test "a node's edge round what it holds, its ground drawn off and bigger and the node turned: the edge drawn off, bigger and turned as its ground is, after what it holds" {
  let (_, _) = edged_holder(0xFFFFFFFFL, fn(n) {
    n.ground_drawn(Is({ dx: -4.0, dy: -2.0, dw: 8.0, dh: 4.0, corners: None })).turn(Is(0.3)) |> ignore
  })
  let c = g()
  let fill = inst_where(fn(at) { c.inst[at + 8] == 1.0 && c.inst[at + 9] == 1.0 && c.inst[at + 11] == 1.0 && c.inst[at + 2] > 40.0 })
  let blue = inst_where(fn(at) { (c.inst[at + 10] * 255.0).round() == 160.0 && c.inst[at + 11] == 1.0 })
  let ring = inst_where(red_edged)
  let same = fill >= 0 && ring >= 0 && [0, 1, 2, 3, 4, 6, 32, 33, 34, 35].all(fn(j) { c.inst[fill * inst_size + j] == c.inst[ring * inst_size + j] })
  assert_eq((fill >= 0, blue > fill, ring > blue, same), (true, true, true, true), msg="\{fill} \{blue} \{ring}")
}

///|
test "a node's edge round what it holds, what holds it fading towards its edges: the edge faded as its ground is" {
  let t = Tester::new(fn(_c) {  })
  set_view_app(fn(root) {
    root.box(fn(f) {
      f.width(Is(Some(400.0))).height(Is(Some(300.0))).fades(Is((0.0, 60.0, 0.0, 60.0))) |> ignore
      f.box(fn(n) {
        n.offset(Is((100.0, 10.0))).width(Is(Some(40.0))).height(Is(Some(24.0))).radius(Is(6.0)).ground(Is(0xFFFFFFFFL)).edge(Is((1.5, 0xE5704AFFL)))
        |> ignore
        n.box(fn(k) { k.grow(Is(1.0)).ground(Is(0x2050A0FFL)) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let c = g()
  let fill = inst_where(fn(at) { c.inst[at + 8] == 1.0 && c.inst[at + 9] == 1.0 && c.inst[at + 11] == 1.0 && c.inst[at + 2] == 40.0 })
  let ring = inst_where(red_edged)
  // (the fade's own numbers: what fades it, its band from the top and the foot, as inst_fade wrote them)
  let fades_of = fn(k : Int) { Array::makei(8, fn(j) { c.inst[k * inst_size + 52 + j] }) }
  assert_true(fill >= 0 && ring > fill && fades_of(fill) == fades_of(ring) && fades_of(fill).iter().any(fn(v) { v != 0.0 }), msg="\{fill} \{ring} \{Repr(if fill >= 0 { fades_of(fill) } else { [] })} \{Repr(if ring >= 0 { fades_of(ring) } else { [] })}")
}

///|
test "a node with no ground of its own, only an edge, round what it holds, turned about what it draws: its edge turned about its own middle, its own" {
  inst_owners.track = true
  let (_, id) = edged_holder(0L, fn(n) { n.turn(Is(0.4), drawn=true) |> ignore })
  let c = g()
  let ring = inst_where(red_edged)
  // (turned about the middle of what it draws, the edge itself: its own rect's middle, 120, 112)
  let about = if ring >= 0 { (c.inst[ring * inst_size + 33], c.inst[ring * inst_size + 34]) } else { (-1.0, -1.0) }
  let own = ring >= 0 && inst_by(ring) == Node(id.val.unwrap())
  inst_owners.track = false
  assert_eq((about, own), ((120.0, 112.0), true), msg="\{ring}")
}

///|
test "a page's list's band (View::scrolls_window's `bands`): one ground from one block's top to another's foot, under them, on the host's pixels as their tops are, none while it lists none" {
  let t = Tester::new(fn(_c) {  })
  t.set_rows_on_pixels(true)
  let lit : @signals.Signal[Array[@view.ListBand[Int]]] = @signals.signal([], same=fn(a, b) { a == b })
  let ink = 0x2050A01FL
  let block = 0x10203040L
  set_view_app(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(
        @view.Scroll::list(),
        fn() { Array::makei(8, fn(i) { i }) },
        fn(b, _) { b.height(Is(Some(29.1))).ground(Is(block)) |> ignore },
        bands=(fn() { lit.get() }, fn(v, _) { v.ground(Is(ink)) |> ignore }),
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let drawn = fn() { t.drawn_rects().filter(fn(r) { r.4 == ink }).map(fn(r) { (r.1, r.3) }) }
  assert_eq(drawn(), [], msg="none listed")
  // (blocks 2 to 5, from 3 under the first's top to 4 under the last's foot: each block's top on the pixels (2 a point),
  // their heights not, the band one, its ends on them too)
  lit.set([{ from: 2, upto: 5, top: 3.0, foot: 4.0 }])
  t.draw()
  // (where blocks 2 and 6 are drawn: the band from 3 under the one's top to 4 under the top of the one after 5, its
  // last)
  let tops = t.drawn_rects().filter(fn(r) { r.4 == block }).map(fn(r) { r.1 })
  tops.sort()
  let on = fn(y : Double) { (y * 2.0 + 0.5).floor() / 2.0 }
  let top = on(tops[2] + 3.0)
  let foot = on(tops[6] + 4.0)
  assert_eq(drawn(), [(top, foot - top)], msg="lit: blocks at \{Repr(tops)}")
  assert_true(tops.iter().all(fn(y) { y == on(y) }), msg="their tops on the pixels: \{Repr(tops)}")
  lit.set([])
  t.draw()
  assert_eq(drawn(), [], msg="none listed again")
}

///|
/// A short page's list at its foot under a head (`from_end`, `head`, as a chat's few messages over its composer), its
/// keys `keys`, each block 40 tall, its ground its key's (band_block_ground), block 1 lit by `lit`'s band (`ink`), its
/// blocks' changes on one way (`flips`).
fn band_short_list(keys : @signals.Signal[Array[Int]], lit : Array[@view.ListBand[Int]], ink : Int64) -> Unit {
  set_view_app(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(
        @view.Scroll::list(),
        fn() { keys.get() },
        fn(b, k) { b.height(Is(Some(40.0))).ground(Is(band_block_ground(k))) |> ignore },
        from_end=true,
        flips=true,
        head=fn(h) { h.height(Is(Some(30.0))) |> ignore },
        bands=(fn() { lit }, fn(v, _) { v.ground(Is(ink)) |> ignore }),
      )
      |> ignore
    })
    |> ignore
  })
}

///|
fn band_block_ground(k : Int) -> Int64 {
  0x10203000L + (k + 16).to_int64() * 0x100L + 0xFFL
}

///|
test "a page's list's band where its blocks lie at its foot, short of what shows under its head: on the block it lights, not where the blocks would be counted from the head" {
  let t = Tester::new(fn(_c) {  })
  t.set_rows_on_pixels(true)
  let ink = 0x2050A01FL
  let keys = @signals.signal([0, 1, 2])
  band_short_list(keys, [{ from: 1, upto: 1, top: 0.0, foot: 0.0 }], ink)
  t.draw()
  let rs = t.drawn_rects()
  let band = rs.filter(fn(r) { r.4 == ink }).map(fn(r) { (r.1, r.3) })
  let block = rs.filter(fn(r) { r.4 == band_block_ground(1) }).map(fn(r) { (r.1, r.3) })
  // (three blocks of 40 at the foot of 400: block 1 from 320 down, far under where the head's 30 would start them)
  assert_true(block is [(y, _)] && y > 200.0, msg="block 1 at its foot: \{Repr(block)}")
  assert_eq(band, block, msg="the band where block 1 is")
}

///|
/// A frame of the band tests that walk the list's way frame by frame: one at sixty a second
let band_frame_ms : Double = 16.0

///|
/// How long they watch the list's way after a block comes: past a column's way in (`flips`) to its rest
let band_way_watched_ms : Double = 600.0

///|
test "a page's list's band as its blocks go on their way (`flips`): where the block it lights is drawn in every frame, never ahead of it where it comes to rest" {
  // (it walks its own frames to look at each: once, at the default rate)
  if test_at_a_rate() {
    return
  }
  let t = Tester::new(fn(_c) {  })
  t.set_rows_on_pixels(true)
  let ink = 0x2050A01FL
  let keys = @signals.signal([0, 1, 2])
  band_short_list(keys, [{ from: 1, upto: 1, top: 0.0, foot: 0.0 }], ink)
  t.draw()
  // (a block come at its foot: those over it pushed up on the list's one way, block 1 with them)
  keys.set([0, 1, 2, 3])
  let seen = []
  let apart = []
  let from = t.time()
  while t.time() - from < band_way_watched_ms {
    t.run_for(band_frame_ms)
    let rs = t.drawn_rects()
    let band = rs.filter(fn(r) { r.4 == ink }).map(fn(r) { (r.1, r.3) })
    let block = rs.filter(fn(r) { r.4 == band_block_ground(1) }).map(fn(r) { (r.1, r.3) })
    match block {
      [(y, _)] => seen.push(y)
      _ => ()
    }
    if band != block {
      apart.push("\{(t.time() - from).to_int()}: band \{Repr(band)} block \{Repr(block)}")
    }
  }
  // (it went: drawn at more than its start and its end)
  let places = seen.copy()
  places.dedup()
  assert_true(places.length() > 2, msg="block 1 went on a way: \{Repr(seen)}")
  assert_eq(apart, [], msg="the band where block 1 is drawn in each frame")
}

///|
test "a page's list's band over several blocks (a long message a block a piece), short of what shows and on its way (`flips`): from its first block's top to its last's foot in every frame, one ground" {
  // (it walks its own frames to look at each: once, at the default rate)
  if test_at_a_rate() {
    return
  }
  let t = Tester::new(fn(_c) {  })
  t.set_rows_on_pixels(true)
  let ink = 0x2050A01FL
  let keys = @signals.signal([0, 1, 2, 3])
  band_short_list(keys, [{ from: 1, upto: 3, top: 0.0, foot: 0.0 }], ink)
  let apart = []
  let look = fn(when : String) {
    let rs = t.drawn_rects()
    let band = rs.filter(fn(r) { r.4 == ink }).map(fn(r) { (r.1, r.3) })
    let first = rs.filter(fn(r) { r.4 == band_block_ground(1) }).map(fn(r) { r.1 })
    let last = rs.filter(fn(r) { r.4 == band_block_ground(3) }).map(fn(r) { r.1 + r.3 })
    match (first, last) {
      ([top], [foot]) => if band != [(top, foot - top)] { apart.push("\{when}: band \{Repr(band)} blocks \{top}..\{foot}") }
      _ => apart.push("\{when}: blocks 1 and 3 not drawn once each")
    }
  }
  t.draw()
  look("at rest")
  // (a block come at its foot: blocks 1 to 3 pushed up on the list's one way, together)
  keys.set([0, 1, 2, 3, 4])
  let from = t.time()
  while t.time() - from < band_way_watched_ms {
    t.run_for(band_frame_ms)
    look("\{(t.time() - from).to_int()} ms")
  }
  assert_eq(apart, [], msg="one band from block 1's top to block 3's foot: \{Repr(apart)}")
}
