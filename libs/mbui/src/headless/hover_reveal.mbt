// What shows on hover: a row's or a card's secondary actions (remove, copy, more) seen only while the pointer is over
// what holds them, as a list's row shows its × on hover. Seen or not is its look's (its alpha read off `shown`); what
// this keeps is that an action not seen is not there for the hand, and is there for the keyboard all the same.
//
// Three ways of hiding it, and why this one. Faded alone, it is still pressed where it is not seen: a tap on a phone
// lands on an action nobody saw. Said to take no press (View::presses), it takes no focus either (Tree::takes_keys): Tab
// passes it, and the keyboard never reaches it. So the hand alone is turned away: where an action is taken by the
// pointer or a finger is said by View::takes, all of it while it shows and none while it does not (what is pressed
// there then lands on what is under it, the row), which leaves the focus as it was: Tab comes to it, and with the focus
// shown on it (View::focus_shown: by the keyboard) it shows, and Enter or Space presses it.
//
// When it shows: the pointer over the host or anything in it (View::pointed, View::pointed_in), over the action or
// anything in it (where it is outside the host, beside it or in a layer: the pointer gone on from the host onto a
// button the action holds is over that button alone, so the action is asked whether it is in it), the keyboard's
// focus shown on the action or on one of `also` (the buttons in it, where the action is the box holding them), or
// `always` (its caller's: a finger's pointing, where no hover comes, or a narrow screen). Nothing is said of a node
// that is drawn, laid out or read out: each node keeps its role, its name and its presses as its component said them.

///|
/// What a look reads of an action shown on hover (`hover_reveal`).
pub struct HoverReveal {
  priv shown : () -> Bool
}

///|
/// Whether the action shows now: the pointer over its host or over it, the keyboard's focus shown on it or on one of
/// what it holds, or its caller's `always`. Followed where a binding reads it.
pub fn HoverReveal::shown(self : HoverReveal) -> Bool {
  (self.shown)()
}

///|
/// `action` (a button, or a box holding several) shown while the pointer is over `host` (the row or card it acts on),
/// taken by the hand only while it shows. `also` are the nodes in `action` that take a press of their own (its
/// buttons, where `action` is the box holding them), each followed for its focus and turned away from the hand with
/// it: where a press lands is the node's own (View::takes), never what holds it. `always` shows it whatever the hand
/// does (its caller's: a finger's pointing, a narrow screen). The focus is left to each node: Tab comes to it shown or
/// not, and it shows as the focus is shown on it.
pub fn hover_reveal(
  host : @view.View,
  action : @view.View,
  also? : Array[@view.View] = [],
  always? : () -> Bool = fn() { false },
) -> HoverReveal {
  let targets = [action, ..also]
  let shown = fn() {
    always() ||
    host.pointed() ||
    host.pointed_in() ||
    action.pointed() ||
    action.pointed_in() ||
    targets.iter().any(fn(t) { t.focus_shown() })
  }
  for t in targets {
    t.takes(fn(w, h, _at) { if shown() { [(0.0, 0.0, w, h)] } else { [] } }) |> ignore
  }
  { shown, }
}
