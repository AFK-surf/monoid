// The window's own buttons where they are the app's to draw (@ui.window_keys_own: Windows' and Linux's, a window with
// no title bar of the system's, the app's top row its title bar), as still.fail's desktop app drew them in its page's
// top row: minimize, maximize or back as it was, close, in one liquid glass pill as the bars' groups of keys are
// (bar_pill_group_node: 36 high, 2 in; icon_button: 32, round, their icons 16 quiet till pointed at, 2 apart), close
// red under the hand. Over all the app shows, as a title bar is: on the line of the top row under them, each layout's
// (window_keys_at). What a top row at the window's top right holds stands before them (window_end_in, window_clear_in,
// tape_bar_end). The maximize one is the host's too (@ui.window_snap: Windows' Snap Layouts open from it as the pointer
// rests there), lit as the host says the pointer stands on it, which the app does not see (@ui.window_snap_state).

///|
/// The band laid out Small over the page where the window's buttons are the app's (the app's status_top): the bar
/// keys' 32 with 6 over and under, a bar's line's.
pub let window_keys_band : Double = 44.0

///|
/// How far in from the window's side the pill holding the buttons stands when symmetric with its top inset (`4.0`,
/// matching `bar_keys_top() - window_keys_pill_pad` and Small's `(window_keys_band - window_keys_pill_h) / 2.0`).
pub let window_keys_in : Double = 4.0

///|
/// How far in the buttons stand from the edges of the liquid glass pill holding them (bar_pill_group_node's): a 32
/// button's round concentric with the pill's 36.
let window_keys_pill_pad : Double = 2.0

///|
/// How high the pill holding the buttons is: the bar keys' 32 and its pad over and under.
let window_keys_pill_h : Double = bar_key_side + 2.0 * window_keys_pill_pad

///|
let window_keys_gap : Double = 2.0

///|
/// Cool mineral-slate tint for the window controls liquid glass pill, distinguishing OS window chrome from adjacent
/// neutral app bar pills while keeping alpha <= 0.41 (full 0.30 liquid translucency), Light luma >= 0.35 (ios27Light),
/// Dark luma < 0.35 (ios27Dark), and colChroma > 0.08 so the kind == 6 shader applies chromatic tinting.
fn window_keys_glass_tint() -> Int64 {
  if theme().dark {
    0x244B7A67L
  } else {
    0x78A8DE67L
  }
}

///|
/// Across, the pill holding the buttons: its pad at each end, the buttons 2 apart.
pub fn window_keys_w() -> Double {
  2.0 * window_keys_pill_pad + 3.0 * bar_key_side + 2.0 * window_keys_gap
}

///|
/// Where the pill holding the buttons stands in a window `width` wide: its top from the window's top, its side from
/// the window's. In a window's whole (Large) its buttons on its bars' line (bar_keys_top), the pill a long capsule past
/// the window's corner as a bar's last capsule is (window_corner_past); on the tape (Medium) its buttons on its panels'
/// line, the pill concentric with the top right corner of the panel at the window's edge (tape_line, line_end_in);
/// laid out Small, in the middle of the band over the page. Over a page alone over all the window (`whole`: a window of
/// its own, a file over the whole window), on its bar's line at any width, as in a window's whole: no tape round it, no
/// band over it.
pub fn window_keys_at(width : Double, whole? : Bool = false) -> (Double, Double) {
  if whole {
    return (bar_keys_top() - window_keys_pill_pad, window_keys_side())
  }
  match layout(width) {
    Small => ((window_keys_band - window_keys_pill_h) / 2.0, window_keys_side())
    Medium => (window_in + tape_line - window_keys_pill_pad, window_keys_side_tape())
    Large => (bar_keys_top() - window_keys_pill_pad, window_keys_side())
  }
}

///|
/// In a window's whole, how far in from the window's side the pill holding the buttons stands: `4.0` (`window_keys_in`,
/// matching its top inset) for square windows and corners smaller than the pill's half-height (`18.0`, including
/// Windows 11's `8.0`); past the window's corner (`window_corner_past`) for rounder windows (`>= 18.0`). The window's
/// corner is worked out from `roots` (the old views', as they ask it; a node's, followed: @ui.tree_corner_roots_now).
fn window_keys_side(roots? : @ui.CornerRoots = @ui.corner_roots()) -> Double {
  if (@ui.CornerOf::Window).radius(roots) >= window_keys_pill_h / 2.0 {
    window_corner_past(window_keys_in, roots~)
  } else {
    window_keys_in
  }
}

///|
/// On the tape, how far in from the window's side the pill holding the buttons stands: concentric with the top right
/// corner of the panel at the window's edge, its buttons on the tape's line as that bar's last key is, the window's
/// corner worked out from `roots` (window_keys_side's).
fn window_keys_side_tape(roots? : @ui.CornerRoots = @ui.corner_roots()) -> Double {
  window_in + line_end_in(tape_edge.radius(roots), window_keys_in, side=window_keys_pill_h)
}

///|
/// What a top row at the window's top right in a window's whole (laid out Large) leaves the buttons, from the
/// window's side to before their pill: none where they are not the app's (window_end_in, window_clear_in). `roots` as
/// window_keys_side's: a node of the window's tree asks it with its own (the old views' read is the window's corner
/// only as they build).
pub fn window_keys_room(roots? : @ui.CornerRoots = @ui.corner_roots()) -> Double {
  if @ui.window_keys_own() {
    window_keys_side(roots~) + window_keys_w()
  } else {
    0.0
  }
}

///|
/// The same on the tape (laid out Medium), from the window's side (tape_bar_end; the strip of a panel at the window's
/// right holding them: sfdesk's tape_shows_right), `roots` as window_keys_room's (the old views' read where none builds
/// put the last key of a page's bar made as nodes, sfdesk's pane_bar_node, against their pill: 20 nearer it than a
/// chat's bar's last).
pub fn window_keys_room_tape(roots? : @ui.CornerRoots = @ui.corner_roots()) -> Double {
  if @ui.window_keys_own() {
    window_keys_side_tape(roots~) + window_keys_w()
  } else {
    0.0
  }
}
