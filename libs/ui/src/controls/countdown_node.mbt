// The time a countdown is said by (a login's minutes left: 剩 13 分钟, 剩 12 分钟…), read again only as its count of
// whole periods toward its end steps: what shows it follows a signal of it, said again at those moments of the one
// clock (View::at_moment), never a frame's clock read as it is built.

///|
/// The time as `now` reads it, read again each time the count of whole `period`s left till `ends` steps, in node `v`,
/// while `ends` is ahead (0: none to count to, read once). What it reads is told at those moments, `later`: what is shown
/// does not wait for them, as a toast's time on screen does not.
pub fn countdown_now_node(
  v : @view.View,
  now : () -> Double,
  ends : () -> Double,
  period? : Double = 60000.0,
) -> () -> Double {
  let said : @signals.Signal[Double] = @signals.signal(now())
  fn next() -> Unit {
    let end = @signals.untracked(ends)
    guard end > 0.0 && period > 0.0 else { return }
    let left = end - now()
    guard left > 0.0 else { return }
    // (what is left over a whole count of periods: the count steps once that much has gone)
    let into = left - (left / period).floor() * period
    v.at_moment(v.logic_at() + (if into <= 0.0 { period } else { into }), fn() {
      said.set(now())
      next()
    }, later=true)
    |> ignore
  }
  next()
  fn() { said.get() }
}
