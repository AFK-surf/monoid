///|
test "progress reports: an interval and a strength chosen are set, followed and said what they mean" {
  for w in [320.0, 900.0] {
    let t = setting_tester(Progress, w)
    t.draw()
    assert_true(t.find(@sf.t("web-pages.progress.requireNote")) is Some(_), msg="\{w}")
    t.tap_text("30")
    t.draw()
    t.tap_text(@sf.t("web-pages.progress.remind"))
    t.run_for(@ui.move_most_ms)
    assert_true(t.find(@sf.t("web-pages.progress.remindNote")) is Some(_), msg="\{w}")
    assert_true(t.find(@sf.t("web-pages.progress.requireNote")) is None, msg="\{w}")
    assert_eq(t.audit(), [], msg="\{w}")
  }
}
