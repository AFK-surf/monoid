// The switch exposes one accessible target with a keyboard focus ring. Disabled switches take no focus or presses.

///|
fn switch_tester(platform : Int, on : @signals.Signal[Bool], disabled : Bool) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0, platform~)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      switch_row_node(b, fn() { "性能记录" }, fn() { on.get() }, fn(to) { on.set(to) }, note=fn() { "保存在本机" }, disabled=fn() {
        disabled
      })
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "the switch's focus ring surrounds its track and both Space and Enter activate it" {
  for platform in [0, 2] {
    let on = @signals.signal(false)
    let t = switch_tester(platform, on, false)
    assert_eq(t.all(Switch).length(), 1)
    let s = t.get(Switch, label="性能记录")
    assert_true(s.check is Some(Off))
    let (x, y, w, h) = s.rect
    if platform == 2 {
      assert_eq((w, h), (64.0, 44.0))
    }
    t.key(@ui.key_tab)
    t.frame()
    assert_eq(t.focused().map(fn(s) { s.label }), Some("性能记录"))
    assert_true(t.boxes_held().iter().any(fn(b) { b.hit && (b.x, b.y, b.w, b.h) == s.rect }))
    assert_true(t.boxes_held().iter().any(fn(b) {
      b.border_w > 0.0 && b.x + b.w / 2.0 == x + w / 2.0 && b.y + b.h / 2.0 == y + h / 2.0
    }))
    t.key(@ui.key_space)
    t.frame()
    assert_true(on.get())
    t.enter()
    t.frame()
    assert_true(!on.get())
  }
}

///|
test "a disabled switch is read out as disabled and Tab passes it over" {
  for platform in [0, 2] {
    let on = @signals.signal(false)
    let t = switch_tester(platform, on, true)
    assert_true(t.get(Switch, label="性能记录").disabled)
    t.key(@ui.key_tab)
    t.frame()
    assert_true(t.focused() is None)
    t.key(@ui.key_space)
    t.enter()
    t.frame()
    assert_true(!on.get())
  }
}
