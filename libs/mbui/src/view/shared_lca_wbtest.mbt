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
