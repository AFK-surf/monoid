// The player on top as the shell has it (its page sfpages' drive_play.mbt, back while it is sideways turning it upright
// first its own): what is on top dark or light whatever the theme (the system bars' icons follow it).

///|
/// Whether what is on top is dark or light whatever the theme (the system bars' icons follow it): the player and the
/// viewer over a picture or a video dark; a reader as its paper. None: as the theme.
fn page_dark(src : Source) -> Bool? {
  match viewer.get() {
    Some(v) if !v.closing && v.dark() => return Some(true)
    _ => ()
  }
  if app.nav.top() is DrivePlay(_) {
    return Some(true)
  }
  reader_paper_dark(src)
}
