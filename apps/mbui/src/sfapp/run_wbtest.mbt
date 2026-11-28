// One run after another in the same process: nothing of the one before reaches this one.

///|
/// How long the run before goes on: long past anything this one's first moments set going.
let run_before_ms : Double = 5000.0

///|
test "a run begun after another that left a page of the bar's menu picked, a while on (its window's tree still made): nothing of the one before tells this one's bar what it shows, at its moments; idle as it starts" {
  let first = tester("home")
  let (xs, y) = bar_places_at()
  first.tap(xs[3], y)
  first.run_for(@ui.move_most_ms)
  let (rx, rys) = menu_rows_at(5)
  first.tap(rx, rys[1])
  first.run_for(run_before_ms)
  let calls : Array[Made] = []
  let next = fake_core(calls)
  next.assert_idle()
}
