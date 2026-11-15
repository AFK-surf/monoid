// A message out of a chat's list as nodes of the window's tree (message_row's out of a list, StaticMessage: a letter's,
// sfdesk letters.mbt): drawn as the chat's list draws its kind (chat_body_node's chat_body_row), with no room of the
// list's beside it or over it, nothing of the list's (its flash, a search's words, its menu's band).

///|
/// Message `m` (by its key `key`) out of a chat's list in `v`, in the chat `here` says: the viewer's own, a notice (open
/// and copied as `opened` and `copied` keep them, by its key), a person's, an agent's, as its list draws each; its
/// own room only.
pub fn message_static_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  key : String,
  m : Message,
  opened : @sf.LiveMap[String, Bool],
  copied : @sf.LiveMap[String, Double],
) -> Unit {
  let said = fn() { m }
  let none = fn() { 0.0 }
  if m.mine {
    mine_said_node(v, src, here, key, none, none, said) |> ignore
  } else if m.system {
    notice_said_node(v, src, here, key, none, none, said, opened, copied) |> ignore
  } else if m.author_kind == "person" {
    person_said_node(v, src, here, key, none, none, said) |> ignore
  } else {
    agent_said_node(v, src, here, key, none, none, said) |> ignore
  }
}
