// chip_node height scaling with system font scale: 1.0x and 1.3x keep exact 30pt,
// 2.0x grows with zero fixed_outgrown or squeeze_faults.

///|
test "chip_node: 1.0x and 1.3x keep exact 30pt; 2.0x scales height with zero fixed_outgrown or squeeze_faults" {
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=200.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      root.row(Is(true)).lines_up(Is(Some(Start))).padding(Is((20.0, 20.0, 20.0, 20.0))).gap(Is(8.0)) |> ignore
      chip_node(root, fn() { "Filter" }, fn() {  }) |> ignore
      chip_node(root, fn() { "Capsule" }, fn() {  }, capsule=true) |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  assert_eq(t.get(Button, label="Filter").rect.3, 30.0, msg="1.0x chip height")
  assert_eq(t.get(Button, label="Capsule").rect.3, 30.0, msg="1.0x capsule chip height")
  assert_eq(t.fixed_outgrown(), [], msg="1.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.0x squeeze_faults")
  t.set_font_scale(1.3)
  t.draw()
  assert_eq(t.get(Button, label="Filter").rect.3, 30.0, msg="1.3x chip height")
  assert_eq(t.get(Button, label="Capsule").rect.3, 30.0, msg="1.3x capsule chip height")
  assert_eq(t.fixed_outgrown(), [], msg="1.3x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.3x squeeze_faults")
  t.set_font_scale(2.0)
  t.draw()
  let h2 = t.get(Button, label="Filter").rect.3
  assert_true(h2 > 30.0, msg="2.0x chip height grew: \{h2}")
  assert_eq(t.get(Button, label="Capsule").rect.3, h2, msg="2.0x capsule chip height matches")
  assert_eq(t.fixed_outgrown(), [], msg="2.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="2.0x squeeze_faults")
}
