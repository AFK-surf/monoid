// A workspace where it is switched to: the mark its managers gave it (an icon of
// still.fail's, a picture or an emoji, as a station's), else its first letter; and what is said beside it: an
// invitation waiting. Where it goes and how large is its place's (the rail's squares, the
// workspaces' rows, Home's name).

///|
/// Whether the workspace has a mark of its own (else its letter is shown).
pub fn workspace_marked(w : Workspace) -> Bool {
  @sf.has_station_mark(w.emoji, w.icon)
}

///|
/// An invitation waiting (inviteDot): the viewer's turn, so the chats' blue dot (chat_mark.mbt), 8 across; said as
/// `label`.
pub fn invite_dot(c : @ui.Ctx, label : String) -> Unit {
  c.box(style=invite_dot_look, label~, fn() {  }) |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let invite_dot_look : @ui.Style = @ui.style(w=S2, h=S2, radius=Full, bg=@sf.mark_blue)
