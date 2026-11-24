// 字体's inline 本机字体 / 精选字体 source switch on 大屏 (V5 unified picker card, zero obstructing popover).

///|
fn fonts_tester() -> @ui.Tester {
  let t = wide_tester([])
  t.host_says_finger(Some(false))
  t.set_local_fonts("[\"Menlo\",\"Avenir Next\",\"Helvetica\"]")
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "大屏: 精选字体 / 本机字体 inline source switch toggles local_open without any obstructing popover" {
  let t = fonts_tester()
  assert_false(@sfpages.local_open.untracked())
  t.tap_text("本机字体")
  t.run_for(@ui.move_most_ms)
  assert_true(@sfpages.local_open.untracked())
  assert_true(t.find("Menlo") is Some(_))
  t.tap_text("精选字体")
  t.run_for(@ui.move_most_ms)
  assert_false(@sfpages.local_open.untracked())
  assert_true(t.query(Button, label="Inter") is Some(_))
}
