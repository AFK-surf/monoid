// A thumbnail that stays (@view.View::shared's `stays`) in a card that cuts it to corners of its own: its picture
// flown back from where it was opened covers each corner's pixels as the thumbnail at rest does, on the frame it lands
// and the frame after, as round as the card where their corners meet.

///|
/// A window 390 by 844 at `scale` of the tree alone: a card 300 by 225 at its top left, its corners `corners`, cutting
/// what it holds (View::clips); in it a thumbnail as big, 26 round, cutting what it holds, that stays, holding a picture
/// as big; over all of it while `open` is said the picture 390 by 292.5 200 down, the two one thing. The tester, open.
fn clip_corners_tester(corners : (Double, Double, Double, Double), scale : Double) -> (Tester, @signals.Signal[Bool]) {
  let open = @signals.signal(false, same=fn(a, b) { a == b })
  let flight : @view.Flight = { way: fn(_) { (200.0, fn(ms) { dclamp(ms / 200.0, 0.0, 1.0) }) } }
  let t = Tester::tree(
    fn(root) {
      root.box(fn(p) {
        p.width(Is(Some(390.0))).height(Is(Some(844.0))) |> ignore
        p.box(fn(card) {
          card.width(Is(Some(300.0))).height(Is(Some(225.0))).shrink(Is(0.0)).corners(Is(Some(corners))).clips(Is(true))
          |> ignore
          card.box(fn(thumb) {
            thumb
            .width(Is(Some(300.0)))
            .height(Is(Some(225.0)))
            .shrink(Is(0.0))
            .radius(Is(26.0))
            .clips(Is(true))
            .shared(Is("p"), flight, stays=true)
            |> ignore
            thumb.box(fn(pic) {
              pic
              .width(Is(Some(300.0)))
              .height(Is(Some(225.0)))
              .shrink(Is(0.0))
              .image(Is(Some(("pic", "", 4096))))
              .image_fades(Is(false))
              |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
        p.show(fn() { open.get() }, fn(o) {
          o.over(Is(true)) |> ignore
          o.box(fn(r) { r.height(Is(Some(200.0))).shrink(Is(0.0)) |> ignore }) |> ignore
          o.box(fn(big) {
            big
            .width(Is(Some(390.0)))
            .height(Is(Some(292.5)))
            .shrink(Is(0.0))
            .image(Is(Some(("pic", "", 4096))))
            .image_fades(Is(false))
            .shared(Is("p"), flight, with_stays=true)
            |> ignore
          })
          |> ignore
        })
      })
      |> ignore
    },
    w=390.0,
    h=844.0,
    scale~,
    images=[("pic", 1200, 900)],
  )
  (t, open)
}

///|
test "a picture flown back to a thumbnail a rounded card cuts: each corner's pixels as at rest, on the frame it lands and the one after" {
  let scale = 3.25
  for corners in [(40.0, 40.0, 40.0, 40.0), (40.0, 10.0, 30.0, 20.0)] {
    let (t, open) = clip_corners_tester(corners, scale)
    t.draw()
    t.run_for(image_fade_ms)
    let pictures = fn() { t.drawn_instances().filter(fn(p) { p[5] == 4.0 && p[2] > 40.0 && p[11] > 0.5 }) }
    let before = pictures()
    assert_eq(before.length(), 1, msg="\{Repr(corners)}: thumbnail")
    open.set(true)
    t.frame()
    t.run_for(move_most_ms)
    open.set(false)
    t.frame()
    let end = view_tree().unwrap().flight_ends_at("p").unwrap()
    // (a host drawing for a vsync just past the flight's end, its logic still just before it: the flight covers as the
    // thumbnail does, as the thumbnail does on the frame after)
    t.frame_shown_at(end - 0.01, end + 0.01)
    let landing = pictures()
    assert_eq(landing.length(), 1, msg="\{Repr(corners)}: landing")
    t.frame_at(end + frame_period_default)
    let after = pictures()
    assert_eq(after.length(), 1, msg="\{Repr(corners)}: landed")
    let mut bad = 0
    for origin in [(0.0, 0.0), (260.0, 0.0), (260.0, 185.0), (0.0, 185.0)] {
      for ix in 0..<130 {
        for iy in 0..<130 {
          let x = origin.0 + (ix.to_double() + 0.5) / scale
          let y = origin.1 + (iy.to_double() + 0.5) / scale
          let want = covered(before[0], x, y, scale)
          if (covered(landing[0], x, y, scale) - want).abs() > 0.5 ||
            (covered(after[0], x, y, scale) - want).abs() > 0.5 {
            bad += 1
          }
        }
      }
    }
    assert_eq(bad, 0, msg="\{Repr(corners)}: pixels changing at a corner")
  }
}
