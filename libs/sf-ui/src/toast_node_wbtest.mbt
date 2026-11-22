///|
test "toaster_node: 1.0x/1.3x keep 28pt action capsule; 2.0x scales action height with zero fixed_outgrown or squeeze_faults" {
  let toasts = @signals.signal([toast("t1", "已归档", action="撤销")])
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=400.0, platform=2)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      toaster_node(root, fn() { toasts.get() }, fn(_) { 60000.0 }, fn() { 16.0 }, fn(_) {  }, fn(_) {  }, key="toast-scale-test")
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.run_for(@ui.move_most_ms)
  let act_1 = t.semantics().filter(fn(s) { s.role == Button && !s.hidden && s.label == "撤销" })
  assert_eq(act_1.map(fn(s) { s.rect.3 }), [toast_action_h], msg="1.0x action height exact 28pt")
  assert_eq(t.fixed_outgrown(), [], msg="1.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.0x squeeze_faults")
  t.set_font_scale(1.3)
  t.draw()
  let act_13 = t.semantics().filter(fn(s) { s.role == Button && !s.hidden && s.label == "撤销" })
  assert_eq(act_13.map(fn(s) { s.rect.3 }), [toast_action_h], msg="1.3x action height exact 28pt")
  assert_eq(t.fixed_outgrown(), [], msg="1.3x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.3x squeeze_faults")
  t.set_font_scale(2.0)
  t.draw()
  let act_2 = t.semantics().filter(fn(s) { s.role == Button && !s.hidden && s.label == "撤销" })
  assert_true(act_2.length() == 1 && act_2[0].rect.3 > toast_action_h, msg="2.0x action grew: \{Repr(act_2)}")
  assert_eq(t.fixed_outgrown(), [], msg="2.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="2.0x squeeze_faults")
}
