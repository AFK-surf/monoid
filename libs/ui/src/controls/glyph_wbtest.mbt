///|
/// How many times a glyph of `g` as nodes (station_glyph_node) works out what it draws over `ms` after a breath
/// (its ink asked again: its shapes made anew), its frames drawn the while.
fn glyph_builds(g : GlyphCounts, ms : Double) -> Int {
  let builds = Ref(0)
  let t = @ui.Tester::new(fn(_c) {  })
  @ui.set_view_app(fn(root) {
    station_glyph_node(root, fn() { g }, 28.0, fn() {
      builds.val = builds.val + 1
      0x24272BFFL
    }, fn() { 0xDC5929FFL })
    |> ignore
  })
  t.draw()
  // (a breath: each step's frame, of the look alone, drawn as the frame built whole draws it)
  t.run_for(glyph_breath_period)
  t.check_looks(false)
  let was = builds.val
  t.run_for(ms)
  builds.val - was
}

///|
test "a station's link on its way: its arc breathes as a look by the clock, its shapes made no more than a glyph standing still's" {
  let breathing : GlyphCounts = { online: 1, dim: 1, failing: 0, working: 0, asleep: false, connecting: 1 }
  let still : GlyphCounts = { online: 1, dim: 1, failing: 0, working: 0, asleep: false, connecting: 0 }
  // (a breath and a half: every step of it on the resident clock drawn)
  assert_eq(glyph_builds(breathing, glyph_breath_period * 1.5), glyph_builds(still, glyph_breath_period * 1.5))
}
