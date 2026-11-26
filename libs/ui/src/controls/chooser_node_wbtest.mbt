// chooser_node height scaling with system font scale: 1.0x and 1.3x keep exact chooser_h (28pt),
// 2.0x grows with zero fixed_outgrown or squeeze_faults.

///|
test "chooser_node: 1.0x and 1.3x keep exact 28pt; 2.0x scales height with zero fixed_outgrown or squeeze_faults" {
  let picked = @signals.signal("1h")
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=200.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      root.row(Is(true)).lines_up(Is(Some(Start))).padding(Is((20.0, 20.0, 20.0, 20.0))).gap(Is(8.0)) |> ignore
      chooser_node(
        root,
        fn() { "One hour" },
        fn() { [("1h", "One hour"), ("8h", "Eight hours")] },
        fn() { picked.get() },
        fn(v) { picked.set(v) },
      )
      |> ignore
      capsule_chooser_node(
        root,
        fn() { "Capsule choice" },
        fn() { [("1h", "Capsule choice")] },
        fn() { picked.get() },
        fn(v) { picked.set(v) },
      )
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  assert_eq(t.get(Button, label="One hour").rect.3, chooser_h, msg="1.0x chooser height")
  assert_eq(t.get(Button, label="Capsule choice").rect.3, chooser_h, msg="1.0x capsule chooser height")
  let ch_rect = t.get(Button, label="One hour").rect
  t.move_to(ch_rect.0 + ch_rect.2 / 2.0, ch_rect.1 + ch_rect.3 / 2.0)
  t.draw()
  let ch_drawn = @ui.view_tree().unwrap().drawn().filter(fn(d) {
    (d.x - ch_rect.0).abs() < 1.0 && (d.y - ch_rect.1).abs() < 1.0 && (d.h - chooser_h).abs() < 1.0
  })
  assert_true(ch_drawn.length() > 0 && ch_drawn[0].radius >= chooser_h / 2.0, msg="chooser_node uses full capsule radius")
  assert_eq(t.fixed_outgrown(), [], msg="1.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.0x squeeze_faults")
  t.set_font_scale(1.3)
  t.draw()
  assert_eq(t.get(Button, label="One hour").rect.3, chooser_h, msg="1.3x chooser height")
  assert_eq(t.get(Button, label="Capsule choice").rect.3, chooser_h, msg="1.3x capsule chooser height")
  assert_eq(t.fixed_outgrown(), [], msg="1.3x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.3x squeeze_faults")
  t.set_font_scale(2.0)
  t.draw()
  let h2 = t.get(Button, label="One hour").rect.3
  assert_true(h2 > chooser_h, msg="2.0x chooser height grew: \{h2}")
  assert_eq(t.get(Button, label="Capsule choice").rect.3, h2, msg="2.0x capsule chooser height matches")
  assert_eq(t.fixed_outgrown(), [], msg="2.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="2.0x squeeze_faults")
}
