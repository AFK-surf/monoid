///|
/// What is made after new_run and before its Tester (a page a fixture opens, its words) is said in the language of no
/// test before it: xshare_wbtest's menu was made in English after station_peek_wbtest's English screen (main b80ec9fc's
/// day's run, 43674422230).
test "a run begun after an English Tester says its words as a run with no language said does" {
  let t = @ui.Tester::new(fn(_c) {  }, env=[("MBUI_LOCALE", "en")])
  t.frame()
  assert_eq(@sf.language(), "en")
  new_run()
  assert_eq(@sf.language(), "zh", msg="not the run before's English")
  let u = @ui.Tester::new(fn(_c) {  })
  u.frame()
  assert_eq(@sf.language(), "zh")
}
