// Glass drawn solid while the system slows the device down for its heat (@hostapi.thermal_throttled: Android's thermal
// status moderate or worse, macOS's and iOS's serious or critical), and glass again as it cools: a node of the window's
// tree and an old view's box alike, as where less transparency is asked for (h_glass_solid), drawn again as it changes.

///|
let thermal_frost : @paint.Glass = Glass::frosted(blur=12.0, tint=0xFFFFFF40L, solid=0xEEEEEEFFL)

///|
test "a node's glass drawn solid while the device is slowed for its heat, glass again as it cools" {
  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0)
  set_view_app(fn(root) {
    root.box(fn(b) { b.over(Is(true)).ground(Is(0x3366CCFFL)) |> ignore }) |> ignore
    for x in [10.0, 90.0] {
      root.box(fn(n) {
        n.over(Is(true)).offset(Is((x, 10.0))).width(Is(Some(60.0))).height(Is(Some(40.0))).radius(Is(20.0)).glass(Is(Some(thermal_frost)))
        |> ignore
      })
      |> ignore
    }
  })
  t.draw()
  let runs = fn() { t.drawn_glass().map(fn(g) { (g.0, g.4, g.5) }) }
  let solid = fn() {
    t.drawn_rects().filter(fn(r) { r.4 == 0xEEEEEEFFL }).map(fn(r) { (r.0, r.1, r.2, r.3) })
  }
  assert_eq(runs(), [(10.0, 5, 1), (90.0, 5, 1)])
  assert_eq(solid(), [])
  t.set_thermal_throttled(true)
  t.frame_at(t.time() + frame_period_default)
  // (no glass left to blur: each its solid ground, where it was)
  assert_eq(runs(), [])
  assert_eq(solid(), [(10.0, 10.0, 60.0, 40.0), (90.0, 10.0, 60.0, 40.0)])
  t.set_thermal_throttled(false)
  t.frame_at(t.time() + frame_period_default)
  assert_eq(runs(), [(10.0, 5, 1), (90.0, 5, 1)])
  assert_eq(solid(), [])
}

///|
test "an old view's glass drawn solid while the device is slowed for its heat or less transparency is asked for" {
  let scene = fn(c : Ctx) {
    c.box(w=Fill(1.0), h=Fill(1.0), bg=0x1559C4FFL, fn() {
      c.layer(fn() { c.box(w=Fill(1.0), h=Px(50.0), glass=thermal_frost, fn() {  }) |> ignore }) |> ignore
    })
    |> ignore
  }
  let t = Tester::new(scene, w=300.0, h=200.0)
  assert_eq(t.drawn_glass().length(), 1)
  t.set_thermal_throttled(true)
  t.frame_at(t.time() + frame_period_default)
  assert_eq(t.drawn_glass().length(), 0)
  assert_true(t.drawn_rects().iter().any(fn(r) { r.1 == 0.0 && r.3 == 50.0 && r.4 == 0xEEEEEEFFL }))
  // (cooled while less transparency is asked for: solid still, for that)
  t.set_reduce_transparency(true)
  t.set_thermal_throttled(false)
  t.frame_at(t.time() + frame_period_default)
  assert_eq(t.drawn_glass().length(), 0)
  t.set_reduce_transparency(false)
  t.frame_at(t.time() + frame_period_default)
  assert_eq(t.drawn_glass().length(), 1)
}
