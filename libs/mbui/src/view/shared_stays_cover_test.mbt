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
/// its foot: a block 400 tall, a thumbnail 100 by 40 that stays, another block 400 tall; over all of it while `open` is
/// said a picture 300 by 200 at (50, 100) that moves, going by `route`. The tree, open, the thumbnail, the picture, the
/// foot's box.
fn route_scene(
  route : @view.FlightRoute,
  mark? : Ref[@view.View?] = Ref(None),
  button? : Ref[@view.View?]? = None,
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
          foot=fn(f) {
            // (`button`: a round button standing over the list made in the foot before what covers the list's foot,
            // which says what flies under the foot is drawn just under it: View::flights_under)
            match button {
              Some(r) =>
                f.box(fn(u) {
                  r.val = Some(u)
                  u.width(Is(Some(30.0))).height(Is(Some(30.0))).ground(Is(blue)) |> ignore
                })
                |> ignore
              None => ()
            }
            f.box(fn(b) {
              foot.val = Some(b)
              b.height(Is(Some(50.0))).ground(Is(green)) |> ignore
              if button is Some(_) {
                b.flights_under() |> ignore
              }
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
              _ => b.height(Is(Some(400.0))) |> ignore
            }
          },
        )
        |> ignore
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
    level: fn(_, _) { Held },
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
  // (as it sets out: cut where what holds the thumbnail cuts it, the foot over it not taken off)
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
test "a flight whose route says it goes under the list's foot: put in the order just before that foot (over the list's rows, the foot over it), where it is held once the route says so, at that moment" {
  let route : @view.FlightRoute = {
    far: fn(_) { 100.0 },
    place: fn(ends, p) {
      let (a, b) = (ends.from, ends.to)
      (a.0 + (b.0 - a.0) * p, a.1 + (b.1 - a.1) * p, a.2 + (b.2 - a.2) * p, a.3 + (b.3 - a.3) * p)
    },
    opened: fn(_, _) { 1.0 },
    level: fn(ends, p) { if (if ends.from_stays { p } else { 1.0 - p }) < 0.5 { UnderFoot } else { Held } },
  }
  let (tree, open, thumb, big, foot) = route_scene(route)
  tree.frame(400.0, 800.0, now=0.0) |> ignore
  let t = thumb.val.unwrap()
  let f = foot.val.unwrap()
  assert_true(drawn_index(tree, t) < drawn_index(tree, f), msg="the thumbnail under the foot")
  tree.event(1000.0, fn() { open.set(true) })
  tree.frame(400.0, 800.0, now=1050.0) |> ignore
  let b = big.val.unwrap()
  // (a quarter of the way out: under the foot, over the list's rows)
  let (bi, fi) = (drawn_index(tree, b), drawn_index(tree, f))
  assert_true(bi >= 0 && bi < fi, msg="under the foot: \{bi} \{fi}")
  // (three quarters: where it is held, over all of the list and its foot)
  tree.frame(400.0, 800.0, now=1150.0) |> ignore
  let (bi, fi) = (drawn_index(tree, b), drawn_index(tree, f))
  assert_true(bi > fi, msg="where it is held: \{bi} \{fi}")
  tree.frame(400.0, 800.0, now=1300.0) |> ignore
  // (closed: the thumbnail flown back, under the foot for the last half of the way, there at rest under it)
  tree.event(2000.0, fn() { open.set(false) })
  tree.frame(400.0, 800.0, now=2050.0) |> ignore
  assert_true(drawn_index(tree, t) > drawn_index(tree, f), msg="over all as it sets out back")
  tree.frame(400.0, 800.0, now=2150.0) |> ignore
  assert_true(drawn_index(tree, t) < drawn_index(tree, f), msg="under the foot as it comes in")
  tree.frame(400.0, 800.0, now=2300.0) |> ignore
  assert_true(!t.flies())
  assert_true(drawn_index(tree, t) < drawn_index(tree, f), msg="at rest under the foot")
}

///|
test "a flight under the list's foot where a part of that foot says what flies under it is drawn just under it: over what the foot holds made before that part, that part over it" {
  let route : @view.FlightRoute = {
    far: fn(_) { 100.0 },
    place: fn(ends, p) {
      let (a, b) = (ends.from, ends.to)
      (a.0 + (b.0 - a.0) * p, a.1 + (b.1 - a.1) * p, a.2 + (b.2 - a.2) * p, a.3 + (b.3 - a.3) * p)
    },
    opened: fn(_, _) { 1.0 },
    level: fn(ends, p) { if (if ends.from_stays { p } else { 1.0 - p }) < 0.5 { UnderFoot } else { Held } },
  }
  let button : Ref[@view.View?] = Ref(None)
  let (tree, open, thumb, big, foot) = route_scene(route, button=Some(button))
  tree.frame(400.0, 800.0, now=0.0) |> ignore
  let t = thumb.val.unwrap()
  let (f, u) = (foot.val.unwrap(), button.val.unwrap())
  assert_true(drawn_index(tree, t) < drawn_index(tree, u), msg="the thumbnail under the button at rest")
  tree.event(1000.0, fn() { open.set(true) })
  tree.frame(400.0, 800.0, now=1050.0) |> ignore
  let b = big.val.unwrap()
  // (a quarter of the way out: over the button, under what covers the foot)
  let (bi, ui, fi) = (drawn_index(tree, b), drawn_index(tree, u), drawn_index(tree, f))
  assert_true(ui >= 0 && ui < bi && bi < fi, msg="between: button \{ui}, flight \{bi}, cover \{fi}")
  tree.frame(400.0, 800.0, now=1150.0) |> ignore
  let (bi, fi) = (drawn_index(tree, b), drawn_index(tree, f))
  assert_true(bi > fi, msg="where it is held: \{bi} \{fi}")
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
test "a mark over a picture flying by a route that puts it under the list's foot and then where it is held: carried at its own size by its corner all the way, no step in its place where the order changes" {
  let route : @view.FlightRoute = {
    far: fn(_) { 100.0 },
    place: fn(ends, p) {
      let (a, b) = (ends.from, ends.to)
      (a.0 + (b.0 - a.0) * p, a.1 + (b.1 - a.1) * p, a.2 + (b.2 - a.2) * p, a.3 + (b.3 - a.3) * p)
    },
    opened: fn(_, _) { 1.0 },
    level: fn(_, p) { if p < 0.5 { UnderFoot } else { Held } },
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
