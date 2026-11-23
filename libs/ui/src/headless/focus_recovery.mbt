// Focus recovery: keeps keyboard focus from falling back to the window root when a focused node is unmounted, starts
// leaving, or stops taking input (becomes disabled). Nothing here is drawn, laid out or read out.

///|
/// Tracks nodes and hands focus to a caller-supplied fallback when a focused node is removed or stops taking input.
pub struct FocusRecovery {
  priv tracked : Ref[Int]
}

///|
/// A new focus recovery tracker.
pub fn FocusRecovery::new() -> FocusRecovery {
  { tracked: Ref(0) }
}

///|
/// Internal tracker with configurable disable recovery: `on_disable=true` recovers when `v` stops taking input or
/// focusability while still mounted; `on_disable=false` recovers only on leaving (`View::on_leaving`) or unmount
/// (`View::owns`).
fn FocusRecovery::track_with(
  self : FocusRecovery,
  v : @view.View,
  fallback : () -> @view.View?,
  on_disable : Bool,
) -> Unit {
  self.tracked.val = self.tracked.val + 1
  let had_focus = Ref(false)
  let recover = fn() {
    if !had_focus.val {
      return
    }
    had_focus.val = false
    let other_focused = match v.tree.focused_now().0 {
      Some(f) => f != v.id()
      None => false
    }
    if other_focused {
      return
    }
    match @signals.untracked(fallback) {
      Some(next) if next.id() != v.id() &&
        @signals.untracked(fn() { next.takes_input() }) &&
        next.tree.takes_keys(next.id()) =>
        // Schedule at the current cause moment on `next`: if `next` is also being torn down in the same container
        // unmount (e.g. a closing Menu), `next`'s own `owns_while` cancels this before it can spuriously move focus.
        next.at_moment(next.cause_at(), fn() {
          let moved = match next.tree.focused_now().0 {
            Some(_) => true
            None => false
          }
          if !moved &&
            next.alive() &&
            @signals.untracked(fn() { next.takes_input() }) &&
            next.tree.takes_keys(next.id()) {
            next.ask_focus(visible=true) |> ignore
          }
        })
        |> ignore
      _ => ()
    }
  }
  v.reacts(fn() { (v.focused(), v.takes_input()) }, fn(st) {
    let (focused, takes) = st
    if focused && takes {
      had_focus.val = true
    } else if !takes {
      if on_disable {
        recover()
      }
    } else if had_focus.val {
      let other_focused = match v.tree.focused_now().0 {
        Some(f) => f != v.id()
        None => false
      }
      if other_focused {
        had_focus.val = false
      } else if !v.alive() || (on_disable && !v.tree.takes_keys(v.id())) {
        recover()
      }
    }
  })
  v.on_leaving(recover) |> ignore
  v.owns(fn() {
    self.tracked.val = self.tracked.val - 1
    recover()
  })
  |> ignore
}

///|
/// Track `v`: while it holds focus, if it is unmounted (`View::owns`), begins leaving (`View::on_leaving`), or stops
/// taking input (`!View::takes_input`) without focus having already moved to another node, ask `fallback()` for a live
/// focusable replacement and move visible focus there. Untracked or unfocused nodes never steal focus.
pub fn FocusRecovery::track(self : FocusRecovery, v : @view.View, fallback : () -> @view.View?) -> Unit {
  self.track_with(v, fallback, true)
}
