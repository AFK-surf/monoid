// How long a switch between places on the bottom bar takes (still.fail's Android app's BarTiming.kt
// → 安卓 `bar_switch`): shared state and wide-frame completion live in `sfbase/bar_timing.mbt`; this file re-exports
// them and provides the Small-screen `bar_built_node` tied to `place_switch`.

///|
pub using @sfbase {
  type BarTiming,
  bar_timing,
  bar_timed,
  bar_timed_said,
  bar_placed,
}

///|
/// A page made once at the stack's root (narrow_made_as's place), its page `page`: told built once the place is switched
/// to it (place_switch said), at that change's moment.
fn bar_built_node(v : @view.View, page : () -> Page) -> Unit {
  v.reacts(fn() {
    place_switch.said()
    (place_switch.starts_at(), bar_timed_said.get())
  }, fn(_) {
    match (bar_timing.val, bar_timed.val, place_of(@signals.untracked(page))) {
      (Some(t), Some(p), Some(q)) if p == q =>
        v.at_moment(v.cause_at(), fn() {
          if bar_timed.val == Some(p) {
            bar_timed.val = None
            (t.built)(p)
          }
        })
        |> ignore
      _ => ()
    }
  })
}
