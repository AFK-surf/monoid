// chooser_button_node height scaling with system font scale: 1.0x and 1.3x keep exact button_height,
// 2.0x grows with zero fixed_outgrown or squeeze_faults.

///|
test "chooser_button_node: 1.0x and 1.3x keep exact button_height; 2.0x scales height with zero fixed_outgrown or squeeze_faults" {
  let picked = @signals.signal("a")
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=200.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      root.row(Is(true)).lines_up(Is(Some(Start))).padding(Is((20.0, 20.0, 20.0, 20.0))) |> ignore
      chooser_button_node(
        root,
        fn() { "Choose model" },
        fn() { [("a", "Choose model"), ("b", "Other")] },
        fn() { picked.get() },
        fn(v) { picked.set(v) },
      )
      |> ignore
    },
    theme=ui_theme_now,
  )
  let h0 = button_height()
  t.draw()
  assert_eq(t.get(Button, label="Choose model").rect.3, h0, msg="1.0x height")
  assert_eq(t.fixed_outgrown(), [], msg="1.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.0x squeeze_faults")
  t.set_font_scale(1.3)
  t.draw()
  assert_eq(t.get(Button, label="Choose model").rect.3, h0, msg="1.3x height")
  assert_eq(t.fixed_outgrown(), [], msg="1.3x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.3x squeeze_faults")
  t.set_font_scale(2.0)
  t.draw()
  let h2 = t.get(Button, label="Choose model").rect.3
  assert_true(h2 > h0, msg="2.0x height grew: \{h2}")
  assert_eq(t.fixed_outgrown(), [], msg="2.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="2.0x squeeze_faults")
}
