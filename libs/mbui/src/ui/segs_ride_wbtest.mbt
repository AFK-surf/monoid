// Shapes' pieces round what is kept and puts none (view_ride.mbt, Ctx::segs_whole): a holder drawn again as kept, or an
// old view hosted, that drew no shape adds no pieces of nothing among the frame's, so a shape drawn after it begins
// where it began as all of it was drawn anew; and a pick leaving over a time, at once, from a side that showed
// nothing: what comes faded in from the change, nothing faded out first, no words seen through a ground half come.

///|
/// The numbers of the frame's pieces in segs_ride_tester's window, four a piece: the triangle's three pieces and the
/// arrow's four, none made up to whole instances round what puts none (Ctx::segs_whole_at), so not a whole six.
let segs_ride_numbers : Int = (3 + 4) * 4

///|
/// A window 320 by 240: a triangle (pieces of a shape, not a whole instance's six), a bar its ground by `ground`, a
/// body that holds no shape (two boxes, and an old view filling a box where `island`); over them all an arrow (pieces
/// of another shape) the window's own old view puts in its overlay, after the frame's pieces as they stand.
fn segs_ride_tester(ground : @signals.Signal[Int64], island : Bool) -> Tester {
  let t = Tester::new(
    fn(c) {
      c.overlay("arrow", fn() {
        c.shapes(
          [shape_of([([0.0, 0.0, 40.0, 15.0, 0.0, 30.0, 10.0, 15.0], true)], fill=0xCC3333FFL)],
          w=Px(40.0),
          h=Px(30.0),
        )
        |> ignore
      })
      |> ignore
    },
    w=320.0,
    h=240.0,
    scale=2.0,
  )
  set_view_app(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(320.0))).height(Is(Some(240.0))) |> ignore
      o.box(fn(k) {
        k
        .width(Is(Some(20.0)))
        .height(Is(Some(20.0)))
        .shapes(Is([shape_of([([0.0, 0.0, 20.0, 0.0, 10.0, 20.0], true)], fill=0x3366CCFFL)]))
        |> ignore
      })
      |> ignore
      o.box(fn(bar) {
        bar.width(Is(Some(320.0))).height(Is(Some(30.0))).ground(By(fn() { ground.get() })) |> ignore
      })
      |> ignore
      o.box(fn(body) {
        body.width(Is(Some(320.0))).height(Is(Some(160.0))) |> ignore
        body.box(fn(r) { r.width(Is(Some(300.0))).height(Is(Some(30.0))).ground(Is(0xFFFFFFFFL)) |> ignore })
        |> ignore
        body.box(fn(r) { r.width(Is(Some(300.0))).height(Is(Some(30.0))).words(Is("item")) |> ignore }) |> ignore
        if island {
          body.box(fn(h) {
            h.width(Is(Some(300.0))).height(Is(Some(30.0))) |> ignore
            old(h, fn(c) { c.box(w=Fill(1.0), h=Fill(1.0), bg=0xDDE3EAFFL, fn() {  }) |> ignore }).grow(Is(1.0))
            |> ignore
          })
          |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// segs_ride_tester's window (an old view in its body where `island`) drawn anew, then its bar's ground changed four
/// times, a frame drawn after each: the body begun to be kept, then drawn again as kept; each frame's pieces the
/// triangle's and the arrow's alone, none of nothing put for the body.
fn segs_ride_held(island : Bool) -> Unit raise {
  let ground = @signals.signal(0xEEF0F4FFL, same=fn(a, b) { a == b })
  let t = segs_ride_tester(ground, island)
  assert_eq(g().segs.length(), segs_ride_numbers, msg="island \{island}: drawn anew")
  let drawn = ride_drawn.val
  let step = fn(to : Int64, say : String) raise {
    ground.set(to)
    t.draw()
    assert_eq(g().segs.length(), segs_ride_numbers, msg="island \{island}: \{say}")
  }
  step(0xDDE0E8FFL, "first change")
  step(0xCCD0D8FFL, "second change")
  step(0xBBC0C8FFL, "third change")
  step(0xAAB0B8FFL, "fourth change")
  assert_true(ride_drawn.val > drawn, msg="island \{island}: the body not drawn again as kept")
}

///|
test "a holder of no shape, drawn anew and drawn again as kept, between two shapes: no pieces of nothing put for it" {
  segs_ride_held(false)
  // (pieces of nothing put as kept: none made up)
  g().segs_put([], SegPack::new())
  assert_eq(g().segs.length(), segs_ride_numbers, msg="none put")
}

///|
test "an old view that draws no shape, drawn anew and drawn again as kept, between two shapes: no pieces of nothing put for it" {
  segs_ride_held(true)
}

///|
/// How long something else moves after the card is changed to, in the test below: past its words come in.
let segs_others_ms : Double = 300.0

///|
test "a pick leaving over a time, at once, from nothing to an opaque card over words: faded in from the change, no words seen through its ground as it comes" {
  let count = @signals.signal(0, same=fn(a, b) { a == b })
  let t0 = Ref(0.0)
  let t = Tester::new(fn(_c) {  }, w=320.0, h=240.0)
  set_view_app(fn(root) {
    root.box(fn(b) {
      b.over(Is(true)) |> ignore
      b.box(fn(w) { w.width(Is(Some(200.0))).words(Is("Underneath")) |> ignore }) |> ignore
    })
    |> ignore
    root.box(fn(layer) {
      layer.over(Is(true)) |> ignore
      layer.pick(at_once=true, leave=140.0, fn() { count.get() }, fn(v, n) {
        if n == 0 {
          return
        }
        v.box(fn(card) {
          card.width(Is(Some(200.0))).ground(Is(0xFFFFFFFFL)) |> ignore
          // (its ground whole from the first, its words in once it is all but whole: from 100 ms to 200 ms)
          card.box(fn(w) {
            w
            .alpha(
              By(fn() {
                let now = w.drawn_while(fn(m) { m < t0.val + 200.0 }) - t0.val
                if now < 100.0 {
                  0.0
                } else if now >= 200.0 {
                  1.0
                } else {
                  (now - 100.0) / 100.0
                }
              }),
            )
            .words(Is("Toast notice"))
            |> ignore
            w.at_moment(t0.val + 200.0, fn() {  }) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
    })
    |> ignore
    // (something else still moving at 200 ms: that frame judged for words over words)
    root.box(fn(k) {
      k.width(Is(Some(1.0))).height(Is(Some(1.0))).alpha(
        By(fn() {
          k.drawn_while(fn(m) { m < t0.val + segs_others_ms }) |> ignore
          1.0
        }),
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t0.val = t.time()
  count.set(1)
  t.run_for(segs_others_ms)
}
