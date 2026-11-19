// A flight with an end that stays (View::shared's `stays`, shared.mbt) where that end lies in what scrolls under a bar
// (Scroll::top_covered) and the other is held under its own bar: the one that moves drawn where it is held, its bar
// over it; the cut it sets out in less what covers the top of what scrolls the thumbnail; a thumbnail wholly under that
// pairs with nothing.

///|
/// A column that scrolls, 60 of its top covered (View::scrolls' `top_covered`), holding `room` of nothing then a
/// thumbnail 100 by 40 that stays; over all of it while `open` is said a layer holding a picture 300 by 200 at
/// (50, 300) that moves, then a bar 400 by 50 at its top drawn after it. The tree, open, the thumbnail, the picture,
/// the bar.
fn cover_scene(
  room : Double,
) -> (@view.Tree, @signals.Signal[Bool], Ref[@view.View?], Ref[@view.View?], Ref[@view.View?]) {
  let open = @signals.signal(false)
  let thumb : Ref[@view.View?] = Ref(None)
  let big : Ref[@view.View?] = Ref(None)
  let bar : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(p) {
      p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      p.scrolls(@view.Scroll::new(), top_covered=fn() { 60.0 }, fn(held) {
        held.box(fn(r) { r.height(Is(Some(room))).shrink(Is(0.0)) |> ignore }) |> ignore
        held.box(fn(t) {
          thumb.val = Some(t)
          t.width(Is(Some(100.0))).height(Is(Some(40.0))).shrink(Is(0.0)).ground(Is(red)).shared(Is("a"), straight, stays=true)
          |> ignore
        })
        |> ignore
        held.box(fn(r) { r.height(Is(Some(2000.0))).shrink(Is(0.0)) |> ignore }) |> ignore
      })
      |> ignore
      p.show(fn() { open.get() }, fn(o) {
        o.over(Is(true)) |> ignore
        o.box(fn(b) {
          big.val = Some(b)
          b
          .offset(Is((50.0, 300.0)))
          .width(Is(Some(300.0)))
          .height(Is(Some(200.0)))
          .ground(Is(blue))
          .shared(Is("a"), straight, with_stays=true)
          |> ignore
        })
        |> ignore
        o.box(fn(h) {
          bar.val = Some(h)
          h.offset(Is((0.0, 0.0))).width(Is(Some(400.0))).height(Is(Some(50.0))).ground(Is(green)) |> ignore
        })
        |> ignore
      })
    })
    |> ignore
  })
  (tree, open, thumb, big, bar)
}

///|
test "a picture flown from a thumbnail that stays: drawn where it is held, the bar drawn after it over it; its cut as it sets out less what covers the top of what scrolls the thumbnail" {
  // (the thumbnail at 30 to 70, its top 30 under what covers the column's top)
  let (tree, open, thumb, big, bar) = cover_scene(30.0)
  tree.frame(400.0, 800.0, now=0.0) |> ignore
  assert_eq(drawn_as(tree, thumb.val.unwrap()), Some((0.0, 30.0, 100.0, 40.0, 1.0, red)))
  tree.event(1000.0, fn() { open.set(true) })
  tree.frame(400.0, 800.0, now=1000.0) |> ignore
  let b = big.val.unwrap()
  assert_true(b.flies(), msg="flown from the thumbnail")
  let (bi, hi) = (drawn_index(tree, b), drawn_index(tree, bar.val.unwrap()))
  assert_true(bi >= 0 && hi > bi, msg="the bar drawn after it: \{bi} \{hi}")
  // (as it sets out: drawn within the thumbnail's room below what covers the column's top)
  assert_eq(tree.lift_cut(b.id()).map(fn(c) { c.1 }), Some(60.0))
  // (half way: opening to the window)
  tree.frame(400.0, 800.0, now=1100.0) |> ignore
  assert_true(tree.lift_cut(b.id()) is Some(_), msg="cut half way")
  // (what is seen of it rounded as the flight has it)
  assert_eq(tree.lift_cut_corners(b.id()), tree.flight_drawn("a").map(fn(f) { f.1 }))
  tree.frame(400.0, 800.0, now=1300.0) |> ignore
  assert_true(!b.flies())
  assert_true(drawn_index(tree, b) < drawn_index(tree, bar.val.unwrap()), msg="landed, the bar over it still")
}

///|
test "a thumbnail that stays wholly under what covers the top of what scrolls it: none flies, the picture comes as it would" {
  // (the thumbnail at 10 to 50, all of it under the 60 covered)
  let (tree, open, _, big, _) = cover_scene(10.0)
  tree.frame(400.0, 800.0, now=0.0) |> ignore
  tree.event(1000.0, fn() { open.set(true) })
  tree.frame(400.0, 800.0, now=1000.0) |> ignore
  assert_true(!big.val.unwrap().flies())
}

///|
/// Where the one of id "a" on its way is drawn (x, y, w, h), to a thousandth of a point.
fn cover_drawn(tree : @view.Tree) -> (Double, Double, Double, Double)? {
  let r = fn(x : Double) { (x * 1000.0).round() / 1000.0 }
  tree.flight_drawn("a").map(fn(f) { (r(f.0.0), r(f.0.1), r(f.0.2), r(f.0.3)) })
}

///|
/// What of node `v` is drawn within on its way (Tree::lift_cut), to a thousandth of a point.
fn cover_cut(tree : @view.Tree, v : @view.View) -> (Double, Double, Double, Double)? {
  let r = fn(x : Double) { (x * 1000.0).round() / 1000.0 }
  tree.lift_cut(v.id()).map(fn(c) { (r(c.0), r(c.1), r(c.2), r(c.3)) })
}

///|
/// A page's list 400 by 800 under a bar 60 tall (`top_covered`), its foot 50 tall (a composer) pinned over its foot, at
/// its foot: a block 400 tall, a thumbnail 100 by 40 that stays, another block `last` tall; over all of it while `open` is
/// said a picture 300 by 200 at (50, 100) that moves, going by `route`; a bar 400 by 60 over the list's top (`bar`'s),
/// drawn after the list. With `button`, a round button 44 by 44 (its) in the foot before its box, that foot's top as tall
/// as it (`foot_clear`) hiding nothing. The tree, open, the thumbnail, the picture, the foot's box.
fn route_scene(
  route : @view.FlightRoute,
  mark? : Ref[@view.View?] = Ref(None),
  last? : Double = 400.0,
  bar? : Ref[@view.View?] = Ref(None),
  button? : Ref[@view.View?],
) -> (@view.Tree, @signals.Signal[Bool], Ref[@view.View?], Ref[@view.View?], Ref[@view.View?]) {
  let open = @signals.signal(false)
  let thumb : Ref[@view.View?] = Ref(None)
  let big : Ref[@view.View?] = Ref(None)
  let foot : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(p) {
      p.width(Is(Some(400.0))).height(Is(Some(800.0))) |> ignore
      p.box(fn(o) {
        o.width(Is(Some(400.0))).height(Is(Some(800.0))) |> ignore
        o.scrolls_window(
          @view.Scroll::list(),
          fn() { [0, 1, 2] },
          est=100.0,
          follows=fn() { true },
          top_covered=fn() { 60.0 },
          foot_clear=fn() { if button is Some(_) { 44.0 } else { 0.0 } },
          foot=fn(f) {
            match button {
              Some(r) =>
                f.box(fn(c) {
                  r.val = Some(c)
                  c.width(Is(Some(44.0))).height(Is(Some(44.0))).ground(Is(red)) |> ignore
                })
                |> ignore
              None => ()
            }
            f.box(fn(b) {
              foot.val = Some(b)
              b.height(Is(Some(50.0))).ground(Is(green)) |> ignore
            })
            |> ignore
          },
          fn(b, k) {
            match k {
              1 =>
                b.box(fn(t) {
                  thumb.val = Some(t)
                  t.width(Is(Some(100.0))).height(Is(Some(40.0))).ground(Is(red)).shared(Is("a"), straight, stays=true)
                  |> ignore
                })
                |> ignore
              0 => b.height(Is(Some(400.0))) |> ignore
              _ => b.height(Is(Some(last))) |> ignore
            }
          },
        )
        |> ignore
      })
      |> ignore
      // (the bar over the list's top, drawn after it)
      p.box(fn(h) {
        bar.val = Some(h)
        h.over(Is(true)).width(Is(Some(400.0))).height(Is(Some(60.0))).ground(Is(green)) |> ignore
      })
      |> ignore
      p.show(fn() { open.get() }, fn(o) {
        o.over(Is(true)) |> ignore
        o.box(fn(b) {
          big.val = Some(b)
          b
          .offset(Is((50.0, 100.0)))
          .width(Is(Some(300.0)))
          .height(Is(Some(200.0)))
          .ground(Is(blue))
          .shared(Is("a"), straight, with_stays=true, route~)
          |> ignore
          // (a mark in its foot's start corner, 20 by 10, 4 in from its edges: View::flight_mark)
          b.box(fn(m) {
            mark.val = Some(m)
            m.over(Is(true)).offset(Is((4.0, 186.0))).width(Is(Some(20.0))).height(Is(Some(10.0))).ground(Is(green)).flight_mark()
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
    })
    |> ignore
  })
  (tree, open, thumb, big, foot)
}

///|
test "a flight whose route its picture says: drawn where that says along its way, its room as what held the thumbnail cut it (what covers its column not taken off) opened as far as that says, what it set out between told it" {
  let seen : Array[@view.FlightEnds] = []
  let route : @view.FlightRoute = {
    far: fn(ends) {
      seen.push(ends)
      100.0
    },
    // (along a curve of its own: a quarter of the way at half of it)
    place: fn(ends, p) {
      let q = p * p
      let (a, b) = (ends.from, ends.to)
      (a.0 + (b.0 - a.0) * q, a.1 + (b.1 - a.1) * q, a.2 + (b.2 - a.2) * q, a.3 + (b.3 - a.3) * q)
    },
    opened: fn(_, p) { p },
    in_stays: fn(_, _) { false },
  }
  let (tree, open, thumb, big, _) = route_scene(route)
  tree.frame(400.0, 800.0, now=0.0) |> ignore
  let (tx, ty, tw, th) = match drawn_as(tree, thumb.val.unwrap()) {
    Some((x, y, w, h, _, _)) => (x, y, w, h)
    None => @halt.saying("no thumbnail")
  }
  tree.event(1000.0, fn() { open.set(true) })
  tree.frame(400.0, 800.0, now=1000.0) |> ignore
  // (told what it set out between: from the thumbnail, to its place, what the list leaves clear down it)
  assert_eq(seen.length(), 1)
  assert_eq(seen[0].from, (tx, ty, tw, th))
  assert_eq(seen[0].to, (50.0, 100.0, 300.0, 200.0))
  assert_true(seen[0].from_stays)
  assert_true(seen[0].clear is Some((60.0, _)), msg="\{Repr(seen[0].clear)}")
  // (as it sets out: cut to what is seen of the thumbnail, what covers its column taken off, as far as the thumbnail goes)
  let b = big.val.unwrap()
  match cover_cut(tree, b) {
    Some((_, _, _, foot)) => assert_true(foot >= ty + th - 0.01, msg="\{foot} \{ty} \{th}")
    None => fail("not cut")
  }
  // (half way: a quarter of the way along, as its route says)
  tree.frame(400.0, 800.0, now=1100.0) |> ignore
  let r = fn(x : Double) { (x * 1000.0).round() / 1000.0 }
  assert_eq(
    cover_drawn(tree),
    Some((r(tx + (50.0 - tx) * 0.25), r(ty + (100.0 - ty) * 0.25), r(tw + (300.0 - tw) * 0.25), r(th + (200.0 - th) * 0.25))),
  )
  tree.frame(400.0, 800.0, now=1300.0) |> ignore
  assert_true(!b.flies())
  // (closed: the route said again, from the picture to the thumbnail, the way going to it)
  tree.event(2000.0, fn() { open.set(false) })
  tree.frame(400.0, 800.0, now=2000.0) |> ignore
  assert_eq(seen.length(), 2)
  assert_eq(seen[1].from, (50.0, 100.0, 300.0, 200.0))
  assert_eq(seen[1].to, (tx, ty, tw, th))
  assert_true(!seen[1].from_stays)
}

///|
/// A route straight from one end to the other, none of what is seen of the end that stays opened for the first half of
/// the way from it (drawn there under what covers its column: `in_stays`), then all of it by the other end.
fn half_under_route() -> @view.FlightRoute {
  let q_of = fn(ends : @view.FlightEnds, p : Double) { if ends.from_stays { p } else { 1.0 - p } }
  {
    far: fn(_) { 100.0 },
    place: fn(ends, p) {
      let (a, b) = (ends.from, ends.to)
      (a.0 + (b.0 - a.0) * p, a.1 + (b.1 - a.1) * p, a.2 + (b.2 - a.2) * p, a.3 + (b.3 - a.3) * p)
    },
    opened: fn(ends, p) {
      let q = q_of(ends, p)
      if q < 0.5 {
        0.0
      } else {
        (q - 0.5) * 2.0
      }
    },
    in_stays: fn(ends, p) { q_of(ends, p) < 0.5 },
  }
}

///|
test "a thumbnail half under what covers the top of its column: drawn under that, as what holds it cuts it, while its route has it slide out from under it, over all from there, opened as that says; under it again as it comes back" {
  // (the thumbnail at 30 to 70, its top 30 under the 60 the bar covers)
  let bar : Ref[@view.View?] = Ref(None)
  let (tree, open, thumb, big, foot) = route_scene(half_under_route(), last=680.0, bar~)
  tree.frame(400.0, 800.0, now=0.0) |> ignore
  let t = thumb.val.unwrap()
  let (h, f) = (bar.val.unwrap(), foot.val.unwrap())
  assert_eq(drawn_as(tree, t).map(fn(d) { (d.1, d.3) }), Some((30.0, 40.0)))
  tree.event(1000.0, fn() { open.set(true) })
  tree.frame(400.0, 800.0, now=1000.0) |> ignore
  let b = big.val.unwrap()
  assert_true(b.flies(), msg="flown from the thumbnail")
  // (as it sets out and a quarter of the way out: in the list, under its foot's box and its bar, all of the thumbnail
  // seen as it was under that bar, its corners its own)
  for now in [1000.0, 1050.0] {
    tree.frame(400.0, 800.0, now~) |> ignore
    let (bi, hi, fi) = (drawn_index(tree, b), drawn_index(tree, h), drawn_index(tree, f))
    assert_true(bi >= 0 && bi < fi && fi < hi, msg="at \{now}: \{bi} \{fi} \{hi}")
    match (cover_cut(tree, b), cover_drawn(tree)) {
      (Some((_, y0, _, _)), Some((_, fy, _, _))) => assert_true((y0 - fy).abs() < 0.01, msg="at \{now}: \{y0} \{fy}")
      _ => fail("not cut")
    }
    assert_eq(tree.lift_cut_corners(b.id()), tree.flight_drawn("a").map(fn(f) { f.1 }))
  }
  // (three quarters: over the bar, half way opened to the window from what held the thumbnail (its top 30))
  tree.frame(400.0, 800.0, now=1150.0) |> ignore
  assert_true(drawn_index(tree, b) > drawn_index(tree, h), msg="over the bar")
  match (cover_cut(tree, b), cover_drawn(tree)) {
    (Some((_, y0, _, _)), Some((_, fy, _, _))) => {
      let open_top = if fy > 15.0 { fy } else { 15.0 }
      assert_true((y0 - open_top).abs() < 0.01, msg="\{y0} \{fy}")
    }
    _ => fail("not cut")
  }
  tree.frame(400.0, 800.0, now=1300.0) |> ignore
  assert_true(!b.flies())
  // (closed: flown back, over the bar the first half of the way, under it again as it comes in, cut as the list cuts it,
  // landed there)
  tree.event(2000.0, fn() { open.set(false) })
  tree.frame(400.0, 800.0, now=2050.0) |> ignore
  assert_true(t.flies(), msg="flown back")
  assert_true(drawn_index(tree, t) > drawn_index(tree, h), msg="over the bar as it sets out back")
  tree.frame(400.0, 800.0, now=2150.0) |> ignore
  let (ti, hi, fi) = (drawn_index(tree, t), drawn_index(tree, h), drawn_index(tree, f))
  assert_true(ti >= 0 && ti < fi && fi < hi, msg="under the bar coming in: \{ti} \{fi} \{hi}")
  match (cover_cut(tree, t), cover_drawn(tree)) {
    (Some((_, y0, _, _)), Some((_, fy, _, _))) => assert_true((y0 - fy).abs() < 0.01, msg="\{y0} \{fy}")
    _ => fail("not cut")
  }
  tree.frame(400.0, 800.0, now=2300.0) |> ignore
  assert_true(!t.flies())
  assert_true(drawn_index(tree, t) < drawn_index(tree, h), msg="landed under the bar")
}

///|
test "a thumbnail flown from a list whose foot holds a round button before its box that hides: drawn over the button and under the box and the bar while it slides out, over all from there, the same way back" {
  let bar : Ref[@view.View?] = Ref(None)
  let button : Ref[@view.View?] = Ref(None)
  let (tree, open, thumb, big, foot) = route_scene(half_under_route(), bar~, button~)
  tree.frame(400.0, 800.0, now=0.0) |> ignore
  let t = thumb.val.unwrap()
  let (h, f, c) = (bar.val.unwrap(), foot.val.unwrap(), button.val.unwrap())
  assert_true(drawn_index(tree, c) >= 0 && drawn_index(tree, c) < drawn_index(tree, f), msg="the button before the box")
  tree.event(1000.0, fn() { open.set(true) })
  tree.frame(400.0, 800.0, now=1050.0) |> ignore
  let b = big.val.unwrap()
  assert_true(b.flies(), msg="flown from the thumbnail")
  let (bi, ci, fi, hi) = (drawn_index(tree, b), drawn_index(tree, c), drawn_index(tree, f), drawn_index(tree, h))
  assert_true(ci < bi && bi < fi && fi < hi, msg="sliding out: \{ci} \{bi} \{fi} \{hi}")
  tree.frame(400.0, 800.0, now=1150.0) |> ignore
  assert_true(drawn_index(tree, b) > drawn_index(tree, h), msg="out: over the bar")
  tree.frame(400.0, 800.0, now=1300.0) |> ignore
  tree.event(2000.0, fn() { open.set(false) })
  tree.frame(400.0, 800.0, now=2050.0) |> ignore
  assert_true(t.flies(), msg="flown back")
  assert_true(drawn_index(tree, t) > drawn_index(tree, h), msg="back: over the bar first")
  tree.frame(400.0, 800.0, now=2150.0) |> ignore
  let (ti, ci, fi, hi) = (drawn_index(tree, t), drawn_index(tree, c), drawn_index(tree, f), drawn_index(tree, h))
  assert_true(ci < ti && ti < fi && fi < hi, msg="coming in: \{ci} \{ti} \{fi} \{hi}")
}

///|
test "a mark over a thumbnail that stays (a film's length) flown back with it: at its own size by its nearest corner, none of it after the way is halfway from the thumbnail, whole as it lands" {
  let open = @signals.signal(false)
  let thumb : Ref[@view.View?] = Ref(None)
  let mark : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(p) {
      p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      p.scrolls(@view.Scroll::new(), fn(held) {
        held.box(fn(r) { r.height(Is(Some(100.0))).shrink(Is(0.0)) |> ignore }) |> ignore
        held.box(fn(t) {
          thumb.val = Some(t)
          t.width(Is(Some(100.0))).height(Is(Some(40.0))).shrink(Is(0.0)).ground(Is(red)).shared(Is("a"), straight, stays=true)
          |> ignore
          // (a mark 20 by 10 in its foot's start corner, 4 in from its edges)
          t.box(fn(m) {
            mark.val = Some(m)
            m.over(Is(true)).offset(Is((4.0, 26.0))).width(Is(Some(20.0))).height(Is(Some(10.0))).ground(Is(green)).flight_mark()
            |> ignore
          })
          |> ignore
        })
        |> ignore
        held.box(fn(r) { r.height(Is(Some(2000.0))).shrink(Is(0.0)) |> ignore }) |> ignore
      })
      |> ignore
      p.show(fn() { open.get() }, fn(o) {
        o.over(Is(true)) |> ignore
        o.box(fn(b) {
          b.offset(Is((50.0, 300.0))).width(Is(Some(300.0))).height(Is(Some(200.0))).ground(Is(blue)).shared(Is("a"), straight, with_stays=true)
          |> ignore
        })
        |> ignore
      })
    })
    |> ignore
  })
  tree.frame(400.0, 800.0, now=0.0) |> ignore
  let m = mark.val.unwrap()
  assert_eq(drawn_as(tree, m), Some((4.0, 126.0, 20.0, 10.0, 1.0, green)))
  tree.event(1000.0, fn() { open.set(true) })
  tree.frame(400.0, 800.0, now=1300.0) |> ignore
  tree.event(2000.0, fn() { open.set(false) })
  tree.frame(400.0, 800.0, now=2000.0) |> ignore
  // (as it sets out back from the picture (50, 300) 300 by 200: none of it, the way all of it from the thumbnail)
  assert_eq(drawn_as(tree, m).map(fn(d) { d.4 }), Some(0.0))
  // (three quarters of the way back: at its own size by the foot's start corner of where the thumbnail is drawn, half
  // of it seen)
  tree.frame(400.0, 800.0, now=2150.0) |> ignore
  let (x, y, w, h) = cover_drawn(tree).unwrap()
  match drawn_as(tree, m) {
    Some((mx, my, mw, mh, ma, _)) => {
      assert_eq((mw, mh), (20.0, 10.0))
      assert_true((mx - (x + 4.0)).abs() < 0.01 && (my - (y + h - 14.0)).abs() < 0.01, msg="\{mx} \{my} in \{x} \{y} \{w} \{h}")
      assert_true((ma - 0.5).abs() < 0.01, msg="\{ma}")
    }
    None => fail("the mark not drawn")
  }
  tree.frame(400.0, 800.0, now=2300.0) |> ignore
  assert_eq(drawn_as(tree, m), Some((4.0, 126.0, 20.0, 10.0, 1.0, green)))
}

///|
test "a mark over a picture flying by a route its picture says: carried at its own size by its corner all the way, no step in its place" {
  let route : @view.FlightRoute = {
    far: fn(_) { 100.0 },
    place: fn(ends, p) {
      let (a, b) = (ends.from, ends.to)
      (a.0 + (b.0 - a.0) * p, a.1 + (b.1 - a.1) * p, a.2 + (b.2 - a.2) * p, a.3 + (b.3 - a.3) * p)
    },
    opened: fn(_, _) { 1.0 },
    in_stays: fn(_, _) { false },
  }
  let mark : Ref[@view.View?] = Ref(None)
  let (tree, open, _, _, _) = route_scene(route, mark~)
  tree.frame(400.0, 800.0, now=0.0) |> ignore
  tree.event(1000.0, fn() { open.set(true) })
  let ys = []
  let mut t = 1000.0
  while t <= 1200.0 {
    tree.frame(400.0, 800.0, now=t) |> ignore
    match (tree.flight_drawn("a"), drawn_as(tree, mark.val.unwrap())) {
      (Some(((_, fy, _, fh), _)), Some((_, my, mw, mh, _, _))) => {
        assert_eq((mw, mh), (20.0, 10.0))
        // (its foot 4 over the picture's foot as it is drawn)
        assert_true((my - (fy + fh - 14.0)).abs() < 0.01, msg="at \{t}: \{my} against \{fy} \{fh}")
        ys.push(my)
      }
      _ => ()
    }
    t = t + 4.0
  }
  assert_true(ys.length() > 20, msg="\{ys.length()}")
}
