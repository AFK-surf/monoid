// What the app's person feels of what goes on beyond their own hand (@ui.haptic; the prefs' `haptics` turn them all
// off: app_frame.mbt): something on screen coming to be, with the app in front (felt_change), as a chat open coming to
// need them (feel_needed). What their hand does is felt where it is done (a hold, a card answered, what is sent or
// copied).

///|
/// `kind` felt as what `now` says comes to be while node `v` is there (of a part made once): after it
/// was seen not to be, with the app in front; not as it is first seen, nor while it stays.
pub fn felt_change_node(v : @view.View, now : () -> Bool, kind : @ui.Haptic) -> Unit {
  // (as of its changes alone: turning true is coming to be after it was not, never what it is as it is first seen)
  v.reacts(now, fn(holds) { if holds && app_in_front() { @ui.haptic(kind) } }, at_start=false)
}

///|
/// Where chat `r`'s page is made as nodes (chat_page_made's), in node `n`: its view
/// as source `src` reads it. Till the view is read nothing is seen of it: what it first comes to is seen, not felt
/// (a chat opened while it needs its viewer is no change; felt as it came on opening it till 2026-11-15).
pub fn feel_needed_node(n : @view.View, src : Source, r : ChatRef) -> Unit {
  let seen : Ref[Bool?] = Ref(None)
  n.reacts(fn() { chat_view_now(src, r).map(chat_needs) }, fn(now) {
    guard now is Some(needs) else { return }
    if needs && seen.val is Some(false) && app_in_front() {
      @ui.haptic(Confirm)
    }
    seen.val = now
  })
}

///|
/// Whether chat `v` needs its viewer: a card waits for them, or its agent says it needs them.
fn chat_needs(v : ChatView) -> Bool {
  v.asks.length() > 0 ||
  (match v.state {
    Some((_, lead, _)) => lead == "need"
    None => false
  })
}
