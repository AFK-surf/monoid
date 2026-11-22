// The desktop's own: its pages and what they hold, each ported from the web's file (or the desktop app's) and made of
// the library's parts (src/sf), reading what sfbase reads. Nothing of the phone's pages is here or reachable from here
// (sfapp imports this package, so this one cannot import it); what both need is the library's or sfbase's.

///|
/// The wires the app's pages are given as the app starts.
fn init {
  // (a folder opened from the files' pages as the wide frames have it: files_side_node.mbt)
  @sfpages.files_go_said.val = files_go
  // what the pages ask of the frame: what a row dragged carries, the chats either side of the one open. Said once, as
  // the app starts (reset runs only as a Tester starts: a wire set there is never set in the app)
  @sfbase.drag_carried.val = dragged
  @sfbase.neighbour_go.val = neighbour
  @sfbase.neighbour_held.val = switcher_open
}

///|
/// What this package keeps put back as the app begins anew (its reset).
pub fn reset() -> Unit {
  @sfpages.reset()
  wide_reset()
  context_reset()
  switcher_reset()
  transfers_reset()
  tab_reset()
  tab_drag_reset()
  tab_node_reset()
  sv_reset()
  attention_reset()
  rail_native_reset()
  page_switch_reset()
  history_reset()
  find_reset()
  jobs_reset()
  open_jobs_reset()
  letters_reset()
  side_slide_reset()
  settings_reset()
  places_reset()
  chat_page_reset()
}
