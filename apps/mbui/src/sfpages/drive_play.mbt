// A drive's file read or played over the whole screen (Screen.DriveRead, Screen.DrivePlay, pushed from a folder's row):
// the library's reader (as nodes: @sf.reader_node) and player over a drive's file (sfbase drive_viewer.mbt: its bytes read through the core a part
// at a time, never the whole file first), the folder (the `drive` topic, as last read) its others; the next or the one
// before in its place.

///|
/// The text `at.path` of `at.root` on `at.station`, read, as nodes in `v` (all of its room: the whole window on every
/// screen, sfapp's narrow_shell and tape_shell); back closes it.
pub fn reader_page_node(v : @view.View, src : Source, at : DriveAt) -> Unit {
  @sfbase.drive_reader_node(v, src, at, fn() { @sfbase.close_page(DriveRead(at)) |> ignore })
}

///|
/// The file `at.path` of `at.root` on `at.station`, played; the next or the one before in its place.
pub fn play_page(c : @ui.Ctx, src : Source, at : DriveAt) -> Unit {
  @sfbase.drive_player(c, src, at, fn() { @sfbase.close_page(DrivePlay(at)) |> ignore }, fn(other) { app.nav.replace(DrivePlay(other)) })
}
