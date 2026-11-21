// The window's own buttons where they are the app's to draw (@ui.window_keys_own: Windows' and Linux's, a window with
// no title bar of the system's, the app's top row its title bar), as still.fail's desktop app drew them in its page's
// top row: after a rule, minimize, maximize or back as it was, close,
// as the bars' keys are (icon_button: 32, round, their icons 16 quiet till pointed at, 2 apart), close red under the
// hand. Over all the app shows, as a title bar is: on the line of the top row under them, each layout's
// (window_keys_at). What a top row at the window's top right holds stands before them (window_end_in, window_clear_in,
// tape_bar_end). The maximize one is the host's too (@ui.window_snap: Windows' Snap Layouts open from it as the pointer
// rests there), lit as the host says the pointer stands on it, which the app does not see (@ui.window_snap_state).

///|
/// The band laid out Small over the page where the window's buttons are the app's (the app's status_top): the bar
/// keys' 32 with 6 over and under, a bar's line's.
pub let window_keys_band : Double = 44.0

///|
/// How far in from the window's side the last button stands alone, as a bar's last key does where it cannot follow the
/// window's corner (frame.mbt's bar_in).
pub let window_keys_in : Double = 12.0

///|
/// The rule before the buttons: 1 by 16, 8 after what is before it, 6 before the
/// first, then the buttons' 2 apart.
let window_rule_before : Double = 8.0

///|
let window_rule_after : Double = 6.0

///|
let window_rule_h : Double = 16.0

///|
let window_rule_w : Double = 1.0

///|
let window_keys_gap : Double = 2.0

///|
/// Across, from what is before the rule to the last button's side.
pub fn window_keys_w() -> Double {
  window_rule_before + window_rule_w + window_rule_after + window_keys_gap + 3.0 * bar_key_side +
  2.0 * window_keys_gap
}

///|
/// Where the buttons stand in a window `width` wide: their top from the window's top, the last one's side from the
/// window's. In a window's whole (Large) on its bars' line (bar_keys_top), the last at the window's corner as a bar's
/// last key stands there (following it where it can, else alone); on the tape (Medium) on its panels' line, concentric
/// with the top right corner of the panel at the window's edge as its bar's last key is (tape_line, line_end_in);
/// laid out Small, in the band over the page. Over a page alone over all the window (`whole`: a window of its own, a
/// file over the whole window), on its bar's line at any width, as in a window's whole: no tape round it, no band over it.
pub fn window_keys_at(width : Double, whole? : Bool = false) -> (Double, Double) {
  if whole {
    return (bar_keys_top(), window_keys_side())
  }
  match layout(width) {
    Small => ((window_keys_band - bar_key_side) / 2.0, window_key_in(window_keys_in))
    Medium => (window_in + tape_line, window_keys_side_tape())
    Large => (bar_keys_top(), window_keys_side())
  }
}

///|
/// In a window's whole, how far in from the window's side the last button stands, the window's corner worked out from
/// `roots` (the old views', as they ask it; a node's, followed: @ui.tree_corner_roots_now).
fn window_keys_side(roots? : @ui.CornerRoots = @ui.corner_roots()) -> Double {
  window_key_in(window_keys_in, roots~)
}

///|
/// On the tape, how far in from the window's side the last button stands: as the last key of the bar of the panel at
/// the window's edge stands in its top right corner, the window's corner worked out from `roots` (window_keys_side's).
fn window_keys_side_tape(roots? : @ui.CornerRoots = @ui.corner_roots()) -> Double {
  window_in + line_end_in(tape_edge.radius(roots), window_keys_in - window_in)
}

///|
/// What a top row at the window's top right in a window's whole (laid out Large) leaves the buttons, from the
/// window's side to before their rule: none where they are not the app's (window_end_in, window_clear_in). `roots` as
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
/// put the last key of a page's bar made as nodes, sfdesk's pane_bar_node, against their rule: 20 nearer it than a
/// chat's bar's last).
pub fn window_keys_room_tape(roots? : @ui.CornerRoots = @ui.corner_roots()) -> Double {
  if @ui.window_keys_own() {
    window_keys_side_tape(roots~) + window_keys_w()
  } else {
    0.0
  }
}
