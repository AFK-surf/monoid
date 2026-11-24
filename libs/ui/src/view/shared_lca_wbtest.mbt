// Where what flies is drawn among the rest (shared.mbt's head): in the nearest node that holds both its ends, after the
// later of the two branches they are in, so over both ends and under what that node's holders draw after it, cut as
// what holds it cuts it; and a container flown as one box, never grown (View::shared's `container`).

///|
/// A flight 200 ms long whatever its length, straight along.
let lca_straight : Flight = { way: fn(_) { (200.0, fn(ms) { ms / 200.0 }) } }

///|
let lca_red : Int64 = 0xFF0000FFL

///|
let lca_blue : Int64 = 0x0000FFFFL

///|
let lca_green : Int64 = 0x00FF00FFL

///|
/// Where node `v` is in what is drawn (its index), -1 nowhere.
fn lca_index(t : Tree, v : View) -> Int {
  t.drawn().search_by(fn(d) { d.id == v.id() }).unwrap_or(-1)
}

///|
/// Node `v` as drawn now: where, how big, how opaque, its ground.
fn lca_drawn(t : Tree, v : View) -> (Double, Double, Double, Double, Double, Int64)? {
  let r = fn(x : Double) { (x * 1.0e6).round() / 1.0e6 }
  t.drawn().iter().find_first(fn(d) { d.id == v.id() }).map(fn(d) { (r(d.x), r(d.y), r(d.w), r(d.h), r(d.alpha), d.ground) })
}

///|
/// A chat's page as it is made: a page's list 400 by 700 (its rows: a block 300 tall, and once `sent` a card 120 by 40
/// at the column's end), its foot pinned over its foot holding a card 380 by 60 till `sent` (a composer's quote), both
/// by one id, the card `container` (View::shared's); then a bar 400 by 60 over the top of the page and a side panel
/// beside the list, both drawn after the list. The tree, sent, the list, its card in the composer, the one sent, the
/// bar, the panel.
priv struct LcaScene {
  tree : Tree
  sent : @signals.Signal[Bool]
  list : Ref[View?]
  from : Ref[View?]
  to : Ref[View?]
  bar : Ref[View?]
  panel : Ref[View?]
  word : Ref[View?]
  apart : Ref[View?]
}

///|
fn lca_scene(container? : Bool = true) -> LcaScene {
  let sent = @signals.signal(false, same=fn(a, b) { a == b })
  let list : Ref[View?] = Ref(None)
  let from : Ref[View?] = Ref(None)
  let to : Ref[View?] = Ref(None)
  let bar : Ref[View?] = Ref(None)
  let panel : Ref[View?] = Ref(None)
  let word : Ref[View?] = Ref(None)
  let apart : Ref[View?] = Ref(None)
  let tree = Tree::new(fn(root) {
    root.box(fn(p) {
      p.width(Is(Some(600.0))).height(Is(Some(700.0))).row(Is(true)) |> ignore
      p.box(fn(o) {
        list.val = Some(o)
        o.width(Is(Some(400.0))).height(Is(Some(700.0))) |> ignore
        o.scrolls_window(
          Scroll::list(),
          fn() { if sent.get() { [0, 1] } else { [0] } },
          est=100.0,
          follows=fn() { true },
          top_covered=fn() { 60.0 },
          foot=fn(f) {
            f.box(fn(c) {
              c.padding(Is((10.0, 10.0, 10.0, 10.0))) |> ignore
              c.show(fn() { !sent.get() }, fn(s) {
                s.box(fn(card) {
                  from.val = Some(card)
                  card.width(Is(Some(380.0))).height(Is(Some(60.0))).ground(Is(lca_green)).radius(Is(16.0)) |> ignore
                  card.box(fn(x) { x.width(Is(Some(20.0))).height(Is(Some(20.0))).ground(Is(lca_red)) |> ignore }) |> ignore
                  card.box(fn(x) {
                    apart.val = Some(x)
                    x.width(Is(Some(30.0))).height(Is(Some(30.0))).ground(Is(lca_blue)).flies_apart() |> ignore
                  })
                  |> ignore
                  card.shared(Is("q"), lca_straight) |> ignore
                })
                |> ignore
              })
            })
            |> ignore
          },
          fn(b, k) {
            match k {
              1 =>
                b.box(fn(card) {
                  to.val = Some(card)
                  card.width(Is(Some(120.0))).height(Is(Some(40.0))).ground(Is(lca_blue)).radius(Is(8.0)) |> ignore
                  card.box(fn(w) {
                    word.val = Some(w)
                    w.width(Is(Some(100.0))).height(Is(Some(20.0))).ground(Is(lca_red)) |> ignore
                  })
                  |> ignore
                  card.shared(Is("q"), lca_straight, container~) |> ignore
                })
                |> ignore
              _ => b.height(Is(Some(300.0))) |> ignore
            }
          },
        )
        |> ignore
      })
      |> ignore
      p.box(fn(s) {
        panel.val = Some(s)
        s.width(Is(Some(200.0))).height(Is(Some(700.0))).ground(Is(lca_blue)) |> ignore
      })
      |> ignore
      p.box(fn(b) {
        bar.val = Some(b)
        b.over(Is(true)).width(Is(Some(400.0))).height(Is(Some(60.0))).ground(Is(lca_red)) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  { tree, sent, list, from, to, bar, panel, word, apart }
}

///|
test "what flies from a page's list's foot to its rows: drawn in the list over both, after its foot, under the bar and the side panel the page draws after the list, and held in it to be cut as it is" {
  let s = lca_scene()
  s.tree.frame(600.0, 700.0, now=0.0) |> ignore
  s.tree.event(1000.0, fn() { s.sent.set(true) })
  s.tree.frame(600.0, 700.0, now=1000.0) |> ignore
  let to = s.to.val.unwrap()
  assert_true(to.flies(), msg="the card sent flies from the composer's")
  let list = s.list.val.unwrap()
  // (drawn in the nearest that holds both ends: the list, as its foot and its rows are)
  match self_flying(s.tree, to) {
    Some(f) => assert_eq(f.host, list.at)
    None => fail("no flight")
  }
  s.tree.frame(600.0, 700.0, now=1100.0) |> ignore
  let (ti, bi, pi) = (lca_index(s.tree, to), lca_index(s.tree, s.bar.val.unwrap()), lca_index(s.tree, s.panel.val.unwrap()))
  assert_true(ti >= 0 && ti < bi && ti < pi, msg="under the bar and the panel: card \{ti}, bar \{bi}, panel \{pi}")
  // (over the list's rows and its foot: after all of the list but what flies, the list holding it in the order)
  assert_true(s.tree.holds_in_order(list.id(), to.id()), msg="held by the list in the order, cut as it is")
  let li = lca_index(s.tree, list)
  let end = s.tree.drawn().length()
  for j = li + 1; j < end; j = j + 1 {
    let d = s.tree.drawn()[j]
    if d.id == to.id() {
      break
    }
    assert_true(s.tree.holds_in_order(list.id(), d.id), msg="only the list's own before it")
  }
  s.tree.frame(600.0, 700.0, now=1300.0) |> ignore
  assert_true(!to.flies(), msg="landed")
}

///|
/// The flight node `v` is the new one of, as the tree keeps it.
fn self_flying(t : Tree, v : View) -> Flying? {
  t.flying_of(v.at)
}

///|
test "a container flown as one box: what it holds at its own size all the way, its box and corners from the one end's to the other's, the old one over the first half, what it holds going fainter, the new one in its place from the half on" {
  let s = lca_scene()
  s.tree.frame(600.0, 700.0, now=0.0) |> ignore
  let from_at = match lca_drawn(s.tree, s.from.val.unwrap()) {
    Some((x, y, w, h, _, _)) => (x, y, w, h)
    None => @halt.saying("the composer's card not drawn")
  }
  s.tree.event(1000.0, fn() { s.sent.set(true) })
  s.tree.frame(600.0, 700.0, now=1000.0) |> ignore
  let to = s.to.val.unwrap()
  assert_true(to.flies())
  let ghost = match self_flying(s.tree, to) {
    Some({ ghost: Some(g), .. }) => g
    _ => @halt.saying("no old copy")
  }
  // (as it sets out: as big as the composer's card, what the one sent holds at its own size)
  let (x0, y0, w0, h0) = from_at
  match (s.tree.flight_drawn("q"), lca_drawn(s.tree, s.word.val.unwrap())) {
    (Some(((x, y, w, h), (c, _, _, _))), Some((_, _, ww, wh, _, _))) => {
      assert_true((x - x0).abs() < 0.01 && (y - y0).abs() < 0.01, msg="\{x} \{y}")
      assert_true((w - w0).abs() < 0.01 && (h - h0).abs() < 0.01, msg="\{w} \{h}")
      assert_eq((ww, wh), (100.0, 20.0))
      assert_true((c - 16.0).abs() < 0.01, msg="its corners the composer's card's: \{c}")
    }
    _ => fail("not drawn")
  }
  // (a quarter of the way: the old copy all of it, its box as the way has it, what it holds a quarter fainter; the one
  // sent not seen yet)
  s.tree.frame(600.0, 700.0, now=1050.0) |> ignore
  let lt = s.tree.nodes[to.at].lift.unwrap()
  assert_true(lt.box && (lift_scale(s.tree.nodes[to.at], lt, 1.0) - 1.0).abs() < 1.0e-9, msg="never grown")
  let seen = fn(v : View) { lca_drawn(s.tree, v).map(fn(d) { d.4 }).unwrap_or(0.0) }
  let kid = s.tree.nodes[ghost.at].kids[0]
  match (s.tree.flight_drawn("q"), lca_drawn(s.tree, s.tree.handle(ghost.at))) {
    (Some(((_, _, w, _), _)), Some((_, _, gw, _, ga, gg))) => {
      assert_true(w < w0 && w > 120.0, msg="its box between the two: \{w}")
      assert_true((gw - w).abs() < 0.01, msg="the old one as big: \{gw}")
      assert_true((ga - 1.0).abs() < 1.0e-6 && (gg & 0xFFL) == 0xFFL, msg="the old copy's ground whole: \{ga}")
    }
    _ => fail("not drawn")
  }
  assert_true(seen(to) < 1.0e-6 && seen(s.word.val.unwrap()) < 1.0e-6, msg="the one sent not seen yet")
  // (what flies apart from the old copy seen nowhere in it: View::flies_apart)
  assert_true(seen(s.apart.val.unwrap()) < 1.0e-6, msg="flying apart, not in the old copy")
  match lca_drawn(s.tree, s.tree.handle(kid)) {
    Some((_, _, kw, kh, ka, _)) => {
      assert_eq((kw, kh), (20.0, 20.0))
      assert_true((ka - 0.75).abs() < 0.01, msg="\{ka}")
    }
    None => fail("the old copy's own not drawn")
  }
  // (three quarters: the one sent all of it in its place, what it holds at its own size; the old copy not seen)
  s.tree.frame(600.0, 700.0, now=1150.0) |> ignore
  match lca_drawn(s.tree, s.word.val.unwrap()) {
    Some((_, _, ww, wh, wa, _)) => {
      assert_eq((ww, wh), (100.0, 20.0))
      assert_true((wa - 1.0).abs() < 0.01, msg="\{wa}")
    }
    None => fail("the one sent's own not drawn")
  }
  assert_true((seen(to) - 1.0).abs() < 1.0e-6, msg="the one sent whole")
  assert_true(seen(s.tree.handle(ghost.at)) < 1.0e-6 && seen(s.tree.handle(kid)) < 1.0e-6, msg="the old copy gone")
  // (cut to its box as the way has it, its corners as they go)
  match (s.tree.lift_cut(to.id()), s.tree.flight_drawn("q")) {
    (Some((c0, c1, c2, c3)), Some(((x, y, w, h), _))) =>
      assert_true(
        (c0 - x).abs() < 0.01 && (c1 - y).abs() < 0.01 && (c2 - x - w).abs() < 0.01 && (c3 - y - h).abs() < 0.01,
        msg="\{c0} \{c1} \{c2} \{c3}",
      )
    _ => fail("not cut")
  }
  s.tree.frame(600.0, 700.0, now=1300.0) |> ignore
  assert_true(!to.flies())
  assert_eq(lca_drawn(s.tree, to).map(fn(d) { (d.2, d.3, d.5) }), Some((120.0, 40.0, lca_blue)))
}

///|
test "a pair that is no container: grown as it goes, as before" {
  let s = lca_scene(container=false)
  s.tree.frame(600.0, 700.0, now=0.0) |> ignore
  s.tree.event(1000.0, fn() { s.sent.set(true) })
  s.tree.frame(600.0, 700.0, now=1100.0) |> ignore
  match lca_drawn(s.tree, s.word.val.unwrap()) {
    Some((_, _, ww, _, _, _)) => assert_true(ww > 100.5, msg="grown with its box: \{ww}")
    None => fail("not drawn")
  }
}

///|
test "a faint dark ground going to a whole light one: never darker on its way than either end, over what is under it" {
  // (a composer's card, its ground a dark at 7.5%, flown to a message's, its ground whole and light)
  let from = 0x24272B13L
  let to = 0xE9E7E4FFL
  let over = 0xF2EFECFFL
  let red = fn(c : Int64) { ((blend_ground(over, c) >> 24) & 0xFFL).to_int() }
  let least = if red(from) < red(to) { red(from) } else { red(to) }
  for i in 1..<10 {
    let p = i.to_double() / 10.0
    let r = red(colour_mix(from, to, p))
    assert_true(r >= least - 1, msg="at \{p}: \{r} under \{least}")
  }
}

///|
test "what flies in from within a page's list to its rows (in_list): drawn after its rows, under its foot and under what flies in from that foot" {
  let sent = @signals.signal(false, same=fn(a, b) { a == b })
  let row0 : Ref[View?] = Ref(None)
  let inner : Ref[View?] = Ref(None)
  let below : Ref[View?] = Ref(None)
  let outer : Ref[View?] = Ref(None)
  let foot_box : Ref[View?] = Ref(None)
  let list : Ref[View?] = Ref(None)
  let tree = Tree::new(fn(root) {
    root.box(fn(o) {
      list.val = Some(o)
      o.width(Is(Some(400.0))).height(Is(Some(700.0))) |> ignore
      o.scrolls_window(
        Scroll::list(),
        fn() { if sent.get() { [0, 1] } else { [0] } },
        est=100.0,
        follows=fn() { true },
        foot=fn(f) {
          f.box(fn(c) {
            foot_box.val = Some(c)
            c.width(Is(Some(400.0))).height(Is(Some(60.0))).ground(Is(lca_green)) |> ignore
          })
          |> ignore
        },
        fn(b, k) {
          match k {
            1 =>
              b.box(fn(r) {
                r.row(Is(true)) |> ignore
                // (from higher in the list: what an agent's line puts by a message)
                r.box(fn(n) {
                  inner.val = Some(n)
                  n.width(Is(Some(40.0))).height(Is(Some(40.0))).ground(Is(lca_red)).flies_in(lca_straight, fn(to) {
                    Some((to.0, to.1 - 200.0, to.2, to.3))
                  }, in_list=true)
                  |> ignore
                })
                |> ignore
                // (from under the list's edge, a row a moment off it: still its own)
                r.box(fn(n) {
                  below.val = Some(n)
                  n.width(Is(Some(30.0))).height(Is(Some(30.0))).ground(Is(lca_green)).flies_in(lca_straight, fn(to) {
                    Some((to.0, 900.0, to.2, to.3))
                  }, in_list=true)
                  |> ignore
                })
                |> ignore
                // (from the foot: words sent from the composer)
                r.box(fn(n) {
                  outer.val = Some(n)
                  n.width(Is(Some(120.0))).height(Is(Some(40.0))).ground(Is(lca_blue)).flies_in(lca_straight, fn(to) {
                    Some((to.0, 650.0, to.2, to.3))
                  })
                  |> ignore
                })
                |> ignore
              })
              |> ignore
            _ =>
              b.box(fn(r) {
                row0.val = Some(r)
                r.width(Is(Some(400.0))).height(Is(Some(300.0))).ground(Is(lca_blue)) |> ignore
              })
              |> ignore
          }
        },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(400.0, 700.0, now=0.0) |> ignore
  tree.event(1000.0, fn() { sent.set(true) })
  tree.frame(400.0, 700.0, now=1050.0) |> ignore
  let (a, b) = (inner.val.unwrap(), outer.val.unwrap())
  assert_true(a.flies() && b.flies(), msg="both fly")
  let held = tree.nodes[list.val.unwrap().at].scroll_held
  match self_flying(tree, a) {
    Some(f) => assert_eq((f.host, f.after), (list.val.unwrap().at, held))
    None => fail("no flight")
  }
  let (r0, ai, fi, bi) = (lca_index(tree, row0.val.unwrap()), lca_index(tree, a), lca_index(tree, foot_box.val.unwrap()), lca_index(tree, b))
  assert_true(r0 >= 0 && r0 < ai && ai < fi && fi < bi, msg="\{r0} \{ai} \{fi} \{bi}")
  // (one setting out from under the list's edge, said within it: drawn as the other, never over its foot)
  let c = below.val.unwrap()
  assert_true(c.flies(), msg="flown from under the list's edge")
  match self_flying(tree, c) {
    Some(f) => assert_eq((f.host, f.after), (list.val.unwrap().at, held))
    None => fail("no flight from under the edge")
  }
  let ci = lca_index(tree, c)
  assert_true(r0 < ci && ci < fi, msg="\{r0} \{ci} \{fi}")
}

///|
test "what flies in from words a field scrolled (cut_from): what of them was seen there, opening straight to all of where it lands along its way, its own corners" {
  let shown = @signals.signal(false, same=fn(a, b) { a == b })
  let flier : Ref[View?] = Ref(None)
  let tree = Tree::new(fn(root) {
    root.box(fn(p) {
      p.width(Is(Some(400.0))).height(Is(Some(700.0))) |> ignore
      p.show(fn() { shown.get() }, fn(s) {
        s.box(fn(n) {
          flier.val = Some(n)
          n
          .offset(Is((50.0, 100.0)))
          .width(Is(Some(100.0)))
          .height(Is(Some(40.0)))
          .radius(Is(12.0))
          .ground(Is(lca_blue))
          .flies_in(lca_straight, fn(to) { Some((to.0, to.1 + 200.0, to.2, to.3)) }, cut_from=fn(to) {
            Some((to.0, 320.0, to.0 + to.2, 330.0))
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(400.0, 700.0, now=0.0) |> ignore
  tree.event(1000.0, fn() { shown.set(true) })
  tree.frame(400.0, 700.0, now=1000.0) |> ignore
  let n = flier.val.unwrap()
  assert_true(n.flies())
  let r = fn(c : (Double, Double, Double, Double)?) {
    c.map(fn(c) { ((c.0 * 1000.0).round() / 1000.0, (c.1 * 1000.0).round() / 1000.0, (c.2 * 1000.0).round() / 1000.0, (c.3 * 1000.0).round() / 1000.0) })
  }
  // (as it sets out: the band of it the field showed)
  assert_eq(r(tree.lift_cut(n.id())), Some((50.0, 320.0, 150.0, 330.0)))
  // (half way: that band half way open to where it lands, within where it is drawn (at 200 to 240))
  tree.frame(400.0, 700.0, now=1100.0) |> ignore
  assert_eq(r(tree.lift_cut(n.id())), Some((50.0, 210.0, 150.0, 235.0)))
  assert_eq(tree.lift_cut_corners(n.id()), Some((12.0, 12.0, 12.0, 12.0)))
  tree.frame(400.0, 700.0, now=1300.0) |> ignore
  assert_true(!n.flies())
  assert_eq(tree.lift_cut(n.id()), None)
}

///|
test "what flies in from within a page's list (in_list) carries no key: the row it lands in comes on the list's way, under the rows still on theirs, not laid whole where it ends over them" {
  let sent = @signals.signal(false, same=fn(a, b) { a == b })
  let row0 : Ref[View?] = Ref(None)
  let inner : Ref[View?] = Ref(None)
  let plain : Ref[View?] = Ref(None)
  let list : Ref[View?] = Ref(None)
  let tree = Tree::new(fn(root) {
    root.box(fn(o) {
      list.val = Some(o)
      o.width(Is(Some(400.0))).height(Is(Some(300.0))) |> ignore
      o.scrolls_window(
        Scroll::list(),
        fn() { if sent.get() { [0, 1] } else { [0] } },
        est=100.0,
        follows=fn() { true },
        flips=true,
        foot=fn(f) {
          f.box(fn(c) { c.width(Is(Some(400.0))).height(Is(Some(60.0))).ground(Is(lca_green)) |> ignore }) |> ignore
        },
        fn(b, k) {
          match k {
            1 =>
              b.box(fn(r) {
                r.width(Is(Some(400.0))).height(Is(Some(200.0))) |> ignore
                // (from higher in the list: what an agent's line puts by a message)
                r.box(fn(n) {
                  inner.val = Some(n)
                  n.width(Is(Some(40.0))).height(Is(Some(40.0))).ground(Is(lca_red)).flies_in(lca_straight, fn(to) {
                    Some((to.0, to.1 - 200.0, to.2, to.3))
                  }, in_list=true)
                  |> ignore
                })
                |> ignore
                r.box(fn(n) {
                  plain.val = Some(n)
                  n.width(Is(Some(400.0))).height(Is(Some(160.0))).ground(Is(lca_green)) |> ignore
                })
                |> ignore
              })
              |> ignore
            _ =>
              b.box(fn(r) {
                row0.val = Some(r)
                r.width(Is(Some(400.0))).height(Is(Some(200.0))).ground(Is(lca_blue)) |> ignore
              })
              |> ignore
          }
        },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(400.0, 300.0, now=0.0) |> ignore
  tree.event(1000.0, fn() { sent.set(true) })
  tree.frame(400.0, 300.0, now=1016.0) |> ignore
  let a = inner.val.unwrap()
  assert_true(a.flies(), msg="it flies")
  let held = tree.nodes[list.val.unwrap().at].scroll_held
  let at = match self_flying(tree, a) {
    Some(f) => (f.host, f.after)
    None => (-2, -2)
  }
  guard lca_drawn(tree, row0.val.unwrap()) is Some((_, y0, _, h0, _, _)) else { fail("row 0 not drawn") }
  guard lca_drawn(tree, plain.val.unwrap()) is Some((_, y1, _, _, _, _)) else { fail("the new row's words not drawn") }
  // (where it is drawn among the rest, whether its row is raised over the list as one carried whole, and whether the
  // new row's words are drawn over row 0 still on its way: row 0 from y0 to y0 + h0, the words from y1)
  let raised = tree.raised_blocks().length()
  assert_eq(
    (at, raised, y1 >= y0 + h0 - 0.5),
    ((list.val.unwrap().at, held), 0, true),
    msg="drawn in \{Repr(at)} (list \{list.val.unwrap().at}, after \{held}), \{raised} raised, row 0 at \{y0} to \{y0 + h0}, the new row's words at \{y1}",
  )
}

///|
test "in_list flight inside a flips=true list moves monotonically without overshooting target or snapping on landing across frame rates" {
  for fps in [0.0, 120.0, 60.0, 24.0, 7.0] {
    let sent = @signals.signal(false, same=fn(a, b) { a == b })
    let av_ref : Ref[View?] = Ref(None)
    let from_rect = (16.0, 240.0, 24.0, 24.0)
    let tree = Tree::new(fn(root) {
      root.box(fn(o) {
        o.width(Is(Some(390.0))).height(Is(Some(300.0))) |> ignore
        o.scrolls_window(
          Scroll::list(),
          fn() { if sent.get() { [0, 1, 2] } else { [0, 2] } },
          est=80.0,
          follows=fn() { true },
          from_end=true,
          flips=true,
          comes=fn(k) { k == 1 },
          fn(b, k) {
            match k {
              1 =>
                b.box(fn(r) {
                  r.width(Is(Some(390.0))).height(Is(Some(110.0))) |> ignore
                  r.box(fn(av) {
                    av_ref.val = Some(av)
                    av
                    .width(Is(Some(24.0)))
                    .height(Is(Some(24.0)))
                    .ground(Is(lca_red))
                    .flies_in(lca_straight, fn(_) { Some(from_rect) }, in_list=true)
                    |> ignore
                  })
                  |> ignore
                })
                |> ignore
              2 => b.box(fn(r) { r.width(Is(Some(390.0))).height(Is(Some(40.0))) |> ignore }) |> ignore
              _ => b.box(fn(r) { r.width(Is(Some(390.0))).height(Is(Some(220.0))) |> ignore }) |> ignore
            }
          },
        )
        |> ignore
      })
      |> ignore
    })
    tree.frame(390.0, 300.0, now=0.0) |> ignore
    tree.event(1000.0, fn() { sent.set(true) })
    tree.frame(390.0, 300.0, now=1000.0) |> ignore
    let av = av_ref.val.unwrap()
    assert_true(av.flies(), msg="fps=\{fps}: expected avatar to fly")
    let y_start = match lca_drawn(tree, av) {
      Some((_, y, _, _, _, _)) => y
      None => fail("fps=\{fps}: avatar not drawn at departure")
    }
    assert_true(
      (y_start - from_rect.1).abs() <= 0.5,
      msg="fps=\{fps}: departure y=\{y_start} != from.y=\{from_rect.1}",
    )
    let step = if fps <= 0.0 { 16.0 } else { 1000.0 / fps }
    let ys : Array[(Double, Double, Bool)] = [(1000.0, y_start, true)]
    let mut t = 1000.0
    while t < 1500.0 {
      t = t + step
      tree.frame(390.0, 300.0, now=t) |> ignore
      match lca_drawn(tree, av) {
        Some((_, y, _, _, _, _)) => ys.push((t, y, av.flies()))
        None => ()
      }
    }
    tree.frame(390.0, 300.0, now=1800.0) |> ignore
    assert_true(!av.flies(), msg="fps=\{fps}: avatar still flying at rest")
    let rest_y = match lca_drawn(tree, av) {
      Some((_, y, _, _, _, _)) => y
      None => fail("fps=\{fps}: avatar not drawn at rest")
    }
    assert_true(
      from_rect.1 - rest_y > 40.0,
      msg="fps=\{fps}: expected upward flight > 40pt (from=\{from_rect.1}, rest=\{rest_y})",
    )
    // Monotonic upward trajectory, zero overshoot above rest_y - 0.5, and zero snap across flight_over.
    let mut prev_y = ys[0].1
    let mut prev_flying = ys[0].2
    for i in 1..<ys.length() {
      let (ti, yi, fl) = ys[i]
      assert_true(
        yi >= rest_y - 0.5,
        msg="fps=\{fps} t=\{ti}: avatar overshot above rest_y=\{rest_y} (got y=\{yi})",
      )
      assert_true(
        yi <= prev_y + 0.5,
        msg="fps=\{fps} t=\{ti}: avatar moved downward during upward flight (prev=\{prev_y}, now=\{yi})",
      )
      if prev_flying && !fl {
        // Across the flight_over landing frame, the avatar hands off smoothly to its slot's live FlipWay position
        // (no snap jump; at 60/120fps < 3pt step, at lower fps bounded by the coarser frame step).
        let land_jump = (yi - prev_y).abs()
        let limit = if fps >= 60.0 || fps <= 0.0 { 3.0 } else if fps >= 24.0 { 15.0 } else { 45.0 }
        assert_true(
          land_jump < limit,
          msg="fps=\{fps} t=\{ti}: landing snap across flight_over (prev=\{prev_y}, now=\{yi}, rest=\{rest_y})",
        )
      }
      prev_y = yi
      prev_flying = fl
    }
  }
}

///|
test "flight inside an ancestor with static non-zero drawn_off lands at laid + static_off with zero snap across flight_over" {
  let shown = @signals.signal(false)
  let target : Ref[View?] = Ref(None)
  let fl : Flight = { way: fn(_) { (200.0, fn(t) { t / 200.0 }) } }
  let tree = Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(300.0))).drawn_off(Is((12.0, 24.0))) |> ignore
      o.show(fn() { shown.get() }, fn(s) {
        s.box(fn(w) {
          w.width(Is(Some(20.0))).height(Is(Some(20.0))).ground(Is(0x4488CCFFL)) |> ignore
          w.flies_in(fl, fn(to) { Some((100.0, 200.0, to.2, to.3)) }) |> ignore
          target.val = Some(w)
        })
        |> ignore
      })
    })
    |> ignore
  })
  tree.frame(300.0, 300.0, now=0.0) |> ignore
  tree.event(1000.0, fn() { shown.set(true) })
  tree.frame(300.0, 300.0, now=1000.0) |> ignore
  guard target.val is Some(w) else { fail("target node not built") }
  assert_true(w.flies(), msg="expected flight to start")
  let (x0, y0) = match lca_drawn(tree, w) {
    Some((x, y, _, _, _, _)) => (x, y)
    None => fail("target not drawn at departure")
  }
  assert_true(
    (x0 - 100.0).abs() <= 0.5 && (y0 - 200.0).abs() <= 0.5,
    msg="departure (\{x0}, \{y0}) != (100, 200)",
  )
  let laid = w.laid_window_now()
  let mut prev_x = x0
  let mut prev_y = y0
  let mut prev_flying = true
  let mut saw_land = false
  let mut t = 1000.0
  while t < 1300.0 {
    t = t + 16.0
    tree.frame(300.0, 300.0, now=t) |> ignore
    guard lca_drawn(tree, w) is Some((xi, yi, _, _, _, _)) else { continue }
    let fl_now = w.flies()
    if prev_flying && !fl_now {
      saw_land = true
      assert_true(
        (xi - prev_x).abs() < 12.0 && (yi - prev_y).abs() < 20.0,
        msg="snap across flight_over at t=\{t}: prev=(\{prev_x}, \{prev_y}) now=(\{xi}, \{yi})",
      )
    }
    prev_x = xi
    prev_y = yi
    prev_flying = fl_now
  }
  assert_true(saw_land, msg="flight never completed")
  let (rx, ry) = match lca_drawn(tree, w) {
    Some((x, y, _, _, _, _)) => (x, y)
    None => fail("target not drawn at rest")
  }
  assert_true(
    (rx - (laid.0 + 12.0)).abs() <= 0.5 && (ry - (laid.1 + 24.0)).abs() <= 0.5,
    msg="rest (\{rx}, \{ry}) != laid + static_off (\{laid.0 + 12.0}, \{laid.1 + 24.0})",
  )
}
