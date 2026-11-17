// A workspace where it is switched to: the mark its managers gave it (an icon of
// still.fail's, a picture or an emoji, as a station's), else its first letter. Where it goes and how large is its
// place's (the rail's squares, the workspaces' rows, Home's name).

///|
/// Whether the workspace has a mark of its own (else its letter is shown).
pub fn workspace_marked(w : Workspace) -> Bool {
  @sf.has_station_mark(w.emoji, w.icon)
}
