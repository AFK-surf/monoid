// Press-and-hold auto-repeat: deterministic, frame-rate-independent repeating on `View::at_moment` (no frame counters).
// Starts after `delay_ms` while the node is held (`View::pressed`), repeats every `interval_ms` anchored to the press
// moment so 60/120/24/7 fps produce identical counts, and cancels immediately on release, disable, loss of input,
// unmount, or calling the returned stop handle. Nothing here is drawn, laid out or read out.

///|
/// Repeat `step` while `v` is held (`View::pressed`) and enabled: first repeat fires `delay_ms` after press, then every
/// `interval_ms` on the tree timeline (`View::at_moment`). Stops immediately when released, disabled, no longer taking
/// input, unmounted, or when the returned stop function is called.
pub fn repeat_hold(
  v : @view.View,
  step : () -> Unit,
  delay_ms? : Double = 400.0,
  interval_ms? : Double = 70.0,
  disabled? : () -> Bool = fn() { false },
) -> () -> Unit {
  let stopped = Ref(false)
  let cancel : Ref[() -> Unit] = Ref(fn() {  })
  let clear_timer = fn() {
    (cancel.val)()
    cancel.val = fn() {  }
  }
  let delay = if delay_ms < 0.0 { 0.0 } else { delay_ms }
  fn schedule(target_at : Double) -> Unit {
    if stopped.val || interval_ms <= 0.0 {
      return
    }
    cancel.val = v.at_moment(target_at, fn() {
      cancel.val = fn() {  }
      let still = !stopped.val &&
        v.alive() &&
        @signals.untracked(fn() { v.pressed() && v.takes_input() && !disabled() })
      if !still {
        return
      }
      step()
      let keep = !stopped.val &&
        v.alive() &&
        @signals.untracked(fn() { v.pressed() && v.takes_input() && !disabled() })
      if keep {
        schedule(target_at + interval_ms)
      }
    })
  }
  v.reacts(fn() { !stopped.val && v.pressed() && v.takes_input() && !disabled() }, fn(holding) {
    clear_timer()
    if holding && interval_ms > 0.0 {
      schedule(v.cause_at() + delay)
    }
  })
  let stop = fn() {
    if !stopped.val {
      stopped.val = true
      clear_timer()
    }
  }
  v.owns(stop) |> ignore
  stop
}
