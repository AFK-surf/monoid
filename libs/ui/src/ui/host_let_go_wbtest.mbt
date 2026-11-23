///|
test "a run begun before its Tester asks the host outside every Tester, not the run before's fake" {
  let t = Tester::new(fn(_c) {  }, env=[("MBUI_LOCALE", "en")])
  t.frame()
  assert_eq(env("MBUI_LOCALE"), "en")
  host_let_go()
  assert_eq(env("MBUI_LOCALE"), "", msg="the run before's environment, not this run's")
  assert_true(t.own_read_said() != "", msg="the run before's Tester says it was ended")
  // (a Tester after it gives its own fake, as ever)
  let u = Tester::new(fn(_c) {  }, env=[("MBUI_LOCALE", "zh")])
  u.frame()
  assert_eq(env("MBUI_LOCALE"), "zh")
  assert_eq(u.own_read_said(), "")
}

///|
test "a run begun as a Tester's first frame is built (its source made then) keeps its fake" {
  let seen : Ref[String?] = Ref(None)
  let t = Tester::new(
    fn(_c) {
      if seen.val is None {
        host_let_go()
        seen.val = Some(env("MBUI_LOCALE"))
      }
    },
    env=[("MBUI_LOCALE", "en")],
  )
  t.frame()
  assert_eq(seen.val, Some("en"), msg="its own environment still")
  assert_eq(t.own_read_said(), "")
}
