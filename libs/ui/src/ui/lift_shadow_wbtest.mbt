// A container flying in (View::flies_in `container=true`) has what it holds cut to its own box on its way
// (Tree::lift_cut), but its own ground (the shadow it casts outside that box, its glass's contour) is composed in the
// clip it would be in were it not flying, so it is there all along rather than coming at once as it lands
// (Tree::lift_casts_uncut, Ctx::view_blit).

///|
/// How long its flight is.
let ls_way_ms : Double = 200.0

///|
let ls_flight : @view.Flight = { way: fn(_) { (ls_way_ms, fn(ms) { dclamp(ms / ls_way_ms, 0.0, 1.0) }) } }

///|
fn ls_clip(a : Array[Double]) -> (Double, Double, Double, Double) {
  (a[16], a[17], a[18], a[19])
}

///|
fn ls_rgb(a : Array[Double], r : Double, g : Double, b : Double) -> Bool {
  a[5] == 0.0 && (a[8] - r).abs() < 0.02 && (a[9] - g).abs() < 0.02 && (a[10] - b).abs() < 0.02
}

///|
test "a container on its way casts its shadow uncut by its own box, as it does at rest, what it holds cut to it" {
  let shown = @signals.signal(false)
  let t = Tester::new(fn(_c) {  }, w=600.0, h=700.0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.show(fn() { shown.get() }, at_once=true, fn(slot) {
      slot.box(fn(b) {
        b
        .margin(Is((100.0, 500.0, 0.0, 0.0)))
        .width(Is(Some(400.0)))
        .height(Is(Some(60.0)))
        .radius(Is(20.0))
        .ground(Is(0xFFFFFFFFL))
        .shadow(Is((8.0, 2.0, 0x00000022L)))
        .shadow_outside(Is(true))
        .flies_in(ls_flight, fn(_) { Some((100.0, 200.0, 400.0, 140.0)) }, container=true)
        |> ignore
        b.box(fn(k) { k.width(Is(Some(100.0))).height(Is(Some(30.0))).ground(Is(0xFF0000FFL)) |> ignore }) |> ignore
      })
      |> ignore
    })
  })
  t.draw()
  let start = t.time()
  shown.set(true)
  t.draw()
  t.run_for(ls_way_ms / 2.0 - (t.time() - start))
  let mid = t.drawn_instances()
  let shadows = mid.filter(fn(a) { a[5] == 2.0 })
  assert_eq(shadows.length(), 1)
  let kids = mid.filter(fn(a) { ls_rgb(a, 1.0, 0.0, 0.0) })
  assert_eq(kids.length(), 1)
  // (what it holds cut to its box on its way, its shadow not)
  let (_, ky0, _, ky1) = ls_clip(kids[0])
  let (_, sy0, _, sy1) = ls_clip(shadows[0])
  assert_true(ky1 - ky0 < 200.0, msg="what it holds cut to its box on its way: \{ky0}..\{ky1}")
  assert_true(sy1 - sy0 > ky1 - ky0 + 100.0, msg="its shadow cut to its box on its way: \{sy0}..\{sy1}")
  let mid_clip = ls_clip(shadows[0])
  t.run_for(ls_way_ms)
  let rest = t.drawn_instances().filter(fn(a) { a[5] == 2.0 })
  assert_eq(rest.length(), 1)
  assert_eq(ls_clip(rest[0]), mid_clip)
}
