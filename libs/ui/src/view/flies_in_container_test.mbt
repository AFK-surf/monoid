///|
test "View::flies_in with container=true: outer box morphs smoothly, child stays 1:1 scale, alpha stays 1.0" {
  let show = @signals.signal(false, same=fn(a, b) { a == b })
  let box_node : Ref[@view.View?] = Ref(None)
  let child_node : Ref[@view.View?] = Ref(None)
  let from_rect = (100.0, 200.0, 400.0, 140.0)
  let flight : @view.Flight = { way: fn(_) { (200.0, fn(ms) { ms / 200.0 }) } }
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(p) {
      p.grow(Is(1.0)).padding(Is((100.0, 500.0, 0.0, 0.0))) |> ignore
      p.show(fn() { show.get() }, at_once=true, fn(box) {
        box_node.val = Some(box)
        box
        .width(Is(Some(400.0)))
        .height(Is(Some(60.0)))
        .ground(Is(0xFFFFFFFFL))
        .radius(Is(20.0))
        .flies_in(flight, fn(_) { Some(from_rect) }, container=true)
        |> ignore
        box.box(fn(kid) {
          child_node.val = Some(kid)
          kid.width(Is(Some(100.0))).height(Is(Some(30.0))).ground(Is(0xFF0000FFL)) |> ignore
        })
        |> ignore
      })
    })
    |> ignore
  })
  tree.frame(600.0, 700.0, now=0.0) |> ignore

  // Trigger mount inside an event so flies_in starts a container flight.
  tree.event(10.0, fn() { show.set(true) })
  tree.frame(600.0, 700.0, now=50.0) |> ignore

  guard box_node.val is Some(bv) else { fail("box node not made") }
  let bid = bv.id()
  guard child_node.val is Some(kv) else { fail("child node not made") }
  let kid = kv.id()

  // At t=50 (p = 0.2, < 0.5): must remain alpha=1.0 (not hidden), box morphs between from(h=140) and to(h=60),
  // child scale stays 1.0, and lift_cut clips to the morphing box.
  let d1 = tree.drawn()
  guard d1.iter().find_first(fn(x) { x.id == bid }) is Some(b1) else { fail("box not drawn at p=0.2") }
  guard d1.iter().find_first(fn(x) { x.id == kid }) is Some(k1) else { fail("child not drawn at p=0.2") }
  assert_eq(b1.alpha, 1.0)
  // Child stays 1:1 unstretched (exact laid-out 100x30) even though outer box is morphing height.
  assert_true((k1.w - 100.0).abs() < 0.5 && (k1.h - 30.0).abs() < 0.5, msg="child stretched: \{k1.w}x\{k1.h}")
  // Expected at p=0.2: y = 200 + (500 - 200) * 0.2 = 260, h = 140 + (60 - 140) * 0.2 = 124.
  assert_true((b1.y - 260.0).abs() < 1.0, msg="y at p=0.2: \{b1.y}")
  assert_true((b1.h - 124.0).abs() < 1.0, msg="h at p=0.2: \{b1.h}")
  guard tree.lift_cut(bid) is Some((c0, c1, c2, c3)) else { fail("expected lift_cut on container flies_in") }
  assert_true((c0 - 100.0).abs() < 1.0 && (c1 - 260.0).abs() < 1.0)
  assert_true((c2 - 500.0).abs() < 1.0 && (c3 - 384.0).abs() < 1.0)

  // At t=110 (p = 0.5): halfway, still alpha=1.0, y=350, h=100.
  tree.frame(600.0, 700.0, now=110.0) |> ignore
  let d2 = tree.drawn()
  guard d2.iter().find_first(fn(x) { x.id == bid }) is Some(b2) else { fail("box not drawn at p=0.5") }
  assert_eq(b2.alpha, 1.0)
  assert_true((b2.y - 350.0).abs() < 1.0, msg="y at p=0.5: \{b2.y}")
  assert_true((b2.h - 100.0).abs() < 1.0, msg="h at p=0.5: \{b2.h}")

  // At t=220 (past end): landed cleanly at y=500, h=60.
  tree.frame(600.0, 700.0, now=220.0) |> ignore
  let d3 = tree.drawn()
  guard d3.iter().find_first(fn(x) { x.id == bid }) is Some(b3) else { fail("box not drawn at end") }
  assert_eq(b3.alpha, 1.0)
  assert_true((b3.y - 500.0).abs() < 1.0, msg="y at end: \{b3.y}")
  assert_true((b3.h - 60.0).abs() < 1.0, msg="h at end: \{b3.h}")
}
