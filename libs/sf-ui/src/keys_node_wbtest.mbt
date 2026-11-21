// keys_record_node height scaling with system font scale: 1.0x and 1.3x keep exact keys_record_h (30pt),
// 2.0x grows with zero fixed_outgrown or squeeze_faults.

///|
test "keys_node: 1.0x and 1.3x keep exact 30pt record button; 2.0x scales height with zero fixed_outgrown or squeeze_faults" {
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=200.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      root.padding(Is((20.0, 20.0, 20.0, 20.0))) |> ignore
      keys_row_node(
        root,
        fn() { "Send message" },
        fn() { "Cmd+Enter" },
        fn() { false },
        fn() { false },
        fn() {  },
        fn() { false },
        fn() {  },
        fn() { "Reset" },
        fn() { "Press keys" },
      )
    },
    theme=ui_theme_now,
  )
  t.draw()
  assert_eq(t.get(Button, label="Send message").rect.3, keys_record_h, msg="1.0x keys_record height")
  assert_eq(t.fixed_outgrown(), [], msg="1.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.0x squeeze_faults")
  t.set_font_scale(1.3)
  t.draw()
  assert_eq(t.get(Button, label="Send message").rect.3, keys_record_h, msg="1.3x keys_record height")
  assert_eq(t.fixed_outgrown(), [], msg="1.3x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.3x squeeze_faults")
  t.set_font_scale(2.0)
  t.draw()
  let h2 = t.get(Button, label="Send message").rect.3
  assert_true(h2 > keys_record_h, msg="2.0x keys_record height grew: \{h2}")
  assert_eq(t.fixed_outgrown(), [], msg="2.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="2.0x squeeze_faults")
}
