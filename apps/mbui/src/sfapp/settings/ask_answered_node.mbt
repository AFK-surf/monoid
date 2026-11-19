// What every card of an agent's request in a chat shares once it is answered (vault_ask.mbt's answered_in_place and
// ask_outcome: the rig's, the phone's, the vault's, a sign-in's), as nodes of the window's tree: the library's
// (@sf.answered_in_place_node, @sf.ask_outcome_node), by the names this package's cards and the chat's pages call.

///|
/// A card's answer at its foot, made by `answer` in `v`, as `ended` says it now (whether it was granted, and how it
/// went in words): @sf.answered_in_place_node's.
pub fn answered_in_place_node(
  v : @view.View,
  ended : () -> (Bool, Array[@ui.Run])?,
  answer : (@view.View) -> Unit,
) -> Unit {
  @sf.answered_in_place_node(v, ended, answer)
}

///|
/// A request's outcome line in `v`, as they say it now: a dot (green while `granted`) and its `words`, pressed for the
/// card read again where it has a `history`: @sf.ask_outcome_node's.
pub fn ask_outcome_node(
  v : @view.View,
  granted : () -> Bool,
  words : () -> Array[@ui.Run],
  inline : () -> Bool,
  history? : ((@view.View) -> Unit)? = None,
) -> Unit {
  @sf.ask_outcome_node(v, granted, words, inline, history~)
}
