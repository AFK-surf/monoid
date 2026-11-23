// The bar every file opened shows across the window's top on a desktop:
// a picture's, a PDF's or code's preview (the app's FilePreview), a text read (reader.mbt), a film played (player.mbt). Always there, along the window's top, 45 high: the way back on the left (where to, by name), the
// file's name and a line about it in the middle, its tools on the right as icons, download last. Its ground is the
// file's (the paper under a text) at 82% over a 20 blur, saturated, a line of its own under it at 70%; it drags the
// window, clear of the window's buttons where they are in the app's top row. Gone up out of the way (a picture left
// alone, a text read on down) it slides up its height and fades (240 ms, ease-out), and takes no presses.

///|
/// The colours a bar is drawn in: the file's ground under it, its words, what is quieter, its line; a button's ground
/// under the pointer (`hover`) and while what it opens is open (`chosen`), over that ground (a film's black has its
/// own: the page's hover on it is dark on black, or near none: Player.css.ts's film --hover and --selected).
#derive(Eq)
pub(all) struct ViewerInk {
  ground : Int64
  ink : Int64
  muted : Int64
  line : Int64
  hover : Int64
  chosen : Int64
}

///|
/// The page's own (a preview's: the canvas, the page's words).
pub fn page_viewer_ink() -> ViewerInk {
  let p = theme().p
  { ground: p.canvas, ink: p.text, muted: p.muted, line: p.line, hover: p.hover, chosen: p.selected }
}

///|
/// When a bar over a file read down (a text, a PDF, code) is out of the way (useBarOnScroll): gone as it is read on
/// down, back as it is read back up, or as the pointer comes to the window's top. Where the list it reads by was last
/// seen: its first row in view and how far down it.
pub(all) struct BarOnScroll {
  mut hidden : Bool
  mut seen : (Int, Double)
}

///|
/// A bar there, nothing read yet.
pub fn BarOnScroll::new() -> BarOnScroll {
  { hidden: false, seen: (0, 0.0) }
}

///|
/// Read down this far before the bar goes (TOP_KEPT); this much of a scroll at once says which way (MOVED).
let viewer_top_kept : Double = 48.0

///|
let viewer_moved : Double = 6.0

///|
/// The pointer this near the window's top brings the bar back (VIEWER_BAR_REACH).
pub let viewer_bar_reach : Double = 72.0

///|
/// How tall the bar is (VIEWER_BAR: a page's bar, its 32 buttons level with the window's): what is under it starts
/// below it or goes under it.
pub let viewer_bar_h : Double = 45.0

///|
/// How far down from the window's top what is under the bar starts: the bar, and the status bar over it where the
/// system's bars are over the window (a tablet's).
pub fn viewer_bar_under() -> Double {
  viewer_bar_h + (viewer_host().room)().0
}

///|
/// Its going and coming (240 ms ease-out).
pub let viewer_bar_ms : Double = 240.0

///|
/// Its glass: the ground at 82% over a 20 blur, saturated 1.4; its line at 70%.
let viewer_bar_share : Double = 0.82

///|
pub let viewer_bar_blur : Double = 20.0

///|
pub let viewer_bar_saturation : Double = 1.4

///|
/// What the middle leaves its sides at least: the way back's and the tools' room either side (as the grid's equal
/// sides keep it in the middle); a phone's (a tablet's) 90 more each side, for its one more tool (分享).
pub fn viewer_bar_sides() -> Double {
  if picture_to_album() {
    500.0
  } else {
    320.0
  }
}

///|
let viewer_none : Double = 0.0

///|
pub let viewer_back_icon : Double = 20.0

///|
pub let viewer_tool_icon : Double = 18.0

///|
/// The room the window's buttons have in the app's top row, past the bar's own 12 (84 in all).
let viewer_buttons_w : Double = 72.0

///|
/// (its row's px)
pub let viewer_bar_in : Double = 12.0

///|
/// Whether the way back stands at the window's top left corner: no buttons of the system's there (window_keys_left),
/// the bar in the window's whole, not a pane's (in_pane, as bar_keys_link has the bar's last key at its right).
pub fn viewer_back_at_corner() -> Bool {
  !@ui.window_keys_left() && !in_pane()
}

///|
/// The corner of the way back at the window's top left corner (viewer_back_at_corner): the window's followed from as far
/// in as it stands from the bar's top (bar_keys_top), a block concentric with it where the window's corner lets one
/// follow it (a Mac's 16, 6 in: 11.2), as a page's bar's last key at its right is (window_corner_key); `alone` (the
/// theme's Xl) where it cannot.
pub fn viewer_back_corner(alone : Double) -> @ui.CornerOf {
  Follow(Window, bar_keys_top(), alone)
}

///|
/// How far in from the window's left the way back stands at the window's corner (viewer_back_at_corner): as far as from
/// the bar's top where its corner fits and follows the window's corner there; otherwise clear of the window's arc.
pub fn viewer_bar_start_in(alone : Double, roots : @ui.CornerRoots) -> Double {
  window_link_in(viewer_back_corner(alone), viewer_bar_in, roots)
}
