// Ctx::grounds_by: what a body builds on one ground drawn on another worked out as it is painted, built once.

///|
test "what stands on a ground drawn on the one worked out as it is painted, the rest as built, nothing built again" {
  let ground = @signals.signal(0x112233FFL)
  let builds = Ref(0)
  let view = fn(c : Ctx) {
    builds.val += 1
    c.grounds_by(0xEEEEEEFFL, fn() { ground.get() }, fn() {
      c.box(w=Px(100.0), h=Px(40.0), bg=0xEEEEEEFFL, fn() {
        c.box(w=Px(50.0), h=Px(20.0), bg=0x445566FFL, fn() {  }) |> ignore
      })
      |> ignore
    })
    c.box(w=Px(100.0), h=Px(40.0), bg=0xEEEEEEFFL, fn() {  }) |> ignore
  }
  let t = Tester::new(view, w=300.0, h=160.0)
  t.check_looks(false)
  t.draw()
  let colours = fn() { t.drawn_rects().map(fn(r) { r.4 }) }
  assert_true(colours().contains(0x112233FFL))
  assert_true(colours().contains(0x445566FFL))
  // (what was built outside it as built)
  assert_true(colours().contains(0xEEEEEEFFL))
  let was = builds.val
  ground.set(0x778899FFL)
  t.frame_at(t.time() + 16.0)
  assert_true(colours().contains(0x778899FFL))
  assert_false(colours().contains(0x112233FFL))
  assert_eq(builds.val, was)
}
