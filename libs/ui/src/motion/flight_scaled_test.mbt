// A flight whose length is said by how far it goes (flight_scaled): as long as that says for each far, on its curve,
// from 0 to 1, there at its end.

///|
test "flight_scaled: as long as it says for how far it goes, on its curve, there at its end" {
  let f = @motion.flight_scaled(fn(far) { 100.0 + far }, ease=@ui.Ease::Out)
  for far in [20.0, 200.0] {
    let (ms, along) = (f.way)(far)
    assert_eq(ms, 100.0 + far)
    assert_eq(along(0.0), 0.0)
    assert_true((along(ms / 2.0) - @ui.Ease::Out.at(0.5)).abs() < 0.001, msg="far \{far}: \{along(ms / 2.0)} half way")
    assert_eq(along(ms), 1.0)
    assert_eq(along(ms + 50.0), 1.0)
  }
  // (none long for a length said under none)
  let (none, _) = (@motion.flight_scaled(fn(_) { -5.0 }, ease=@ui.Ease::Out).way)(50.0)
  assert_eq(none, 0.0)
}
