// 外观's 界面材质 chosen makes the window's glass so at once (@ui.glass_material, app_looks_told reading the prefs as
// chosen), before prefs.set answers.

///|
test "外观: 界面材质 chosen makes @ui.glass_material() so before prefs.set answers" {
  new_run()
  let base = fixture("settings")
  let held_rpc : Array[Json] = []
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      if name == "prefs.set" {
        held_rpc.push(params)
      } else {
        (base.call)(name, params, done)
      }
    },
  }
  app.nav.push(Settings)
  app.nav.push(Setting(Appearance))
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=1400.0, platform=2)
  t.draw()
  assert_eq(@ui.glass_material(), Liquid)
  for (label, want) in [("磨砂玻璃", @ui.GlassMaterial::Frosted), ("实色", Solid), ("液态玻璃", Liquid)] {
    t.click(Radio, label~)
    t.draw()
    assert_eq(@ui.glass_material(), want, msg=label)
  }
  assert_eq(held_rpc.length(), 3)
}
