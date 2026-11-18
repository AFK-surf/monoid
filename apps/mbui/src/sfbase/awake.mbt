// The screen kept on (@ui.keep_awake) for several things of the app at once, each by its own name: a chat's own
// screen looked at (screen_view.mbt), a new device's code shown to be read off this one (narrow_shell.mbt
// signed_in_prompts). The host is told only as the first comes and as the last goes, so one letting go never lets the
// screen sleep under another.

///|
/// Those keeping the screen on now, by name.
// kept across runs: put back as at the start by awake_reset (the app's reset)
let awake_holders : Array[String] = []

///|
/// `holder` keeps the screen on (`on`), or no longer does: the host told as the first comes and the last goes. Called
/// where something is done (a handler, a reaction), never as a frame is built.
pub fn keep_awake_by(holder : String, on : Bool) -> Unit {
  let was = !awake_holders.is_empty()
  if on {
    if !awake_holders.contains(holder) {
      awake_holders.push(holder)
    }
  } else {
    awake_holders.retain(fn(h) { h != holder })
  }
  let now = !awake_holders.is_empty()
  if now != was {
    @ui.keep_awake(now)
  }
}

///|
/// As at the start (the app's reset): none keeps the screen on, the host told so where one did.
fn awake_reset() -> Unit {
  if !awake_holders.is_empty() {
    awake_holders.clear()
    @ui.keep_awake(false)
  }
}
