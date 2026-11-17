///|
/// A finger's press on `v` shown once it has stayed `@ui.tap_indication_ms`, so one going on to scroll lights nothing
/// (Android's; the old view's `press_late`): what draws it reads the first, the press's `down` and `up` call the other
/// two.
pub fn press_late(v : @view.View) -> (() -> Bool, () -> Unit, () -> Unit) {
  let lit : @signals.Signal[Bool] = @signals.signal(false)
  let due : Ref[() -> Unit] = Ref(fn() {  })
  let down = fn() {
    (due.val)()
    due.val = v.at_moment(v.cause_at() + @ui.tap_indication_ms, fn() { lit.set(true) })
  }
  let up = fn() {
    (due.val)()
    due.val = fn() {  }
    lit.set(false)
  }
  (fn() { lit.get() }, down, up)
}
