///|
test "a toast drawn aside let go: put away landing past a third of it on from its speed, or flicked; else back" {
  let s = @view.lands_at(0.0, 0.3)
  assert_false(toast_put_away(99.0 - s, 300.0, 0.3))
  assert_true(toast_put_away(101.0 - s, 300.0, 0.3))
  assert_false(toast_put_away(10.0, 300.0, @view.flung_away))
  assert_true(toast_put_away(10.0, 300.0, @view.flung_away + 0.01))
}
