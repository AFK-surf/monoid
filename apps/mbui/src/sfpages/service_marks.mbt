// What marking a service's page shows on the phone (still.fail apps/android chat/screens/Preview.kt: MarkMode, MarksOver,
// Note): the bar's edit key, the mode's bar, each mark's box, pin and bubble, its note; what marking does is sfbase's
// (service_marks.mbt).

///|
/// A bar key's icon.
let bar_icon_size : Double = 14.0

///|
/// The address's place while marking (all the room there is).
// kept across runs: a value (no field of it changes)
let mark_mode_place : @ui.Style = @ui.css("w=Full px=S1")

///|
/// MarkMode's capsule: 30 high, round, the chip's ground a tenth of the way to the accent, what is in its ends
/// concentric with them (the dot's ring at its start, 添加到对话 at its end), 8 apart.
// kept across runs: a value (no field of it changes)
let mark_mode_bar : @ui.Style = @ui.style(
  row=true,
  w=Full,
  h=@sf.mark_bar_h,
  radius=Full,
  bg=Over(A(Accent, O10), Faint),
  pl=@sf.mark_bar_start,
  pr=@sf.mark_bar_end,
  gap=S2,
  align=ACenter,
)

///|
/// Its dot (7, the accent while picking, else muted), in the middle of a 13 ring's room, the ring the accent's 22% while
/// picking (so the dot stands where the ring's middle is, concentric with the bar's end, either way).
// kept across runs: a value (no field of it changes)
let mark_dot_box : @ui.Style = @ui.style(w=@sf.mark_ring, h=@sf.mark_ring, radius=Full, align=ACenter, justify=JCenter)

///|
// kept across runs: a value (no field of it changes)
let mark_dot_ring : @ui.Style = mark_dot_box.then(@ui.style(bg=@sf.mark_ring_bg))

///|
// kept across runs: a value (no field of it changes)
let mark_dot : @ui.Style = @ui.style(w=@sf.dot_size, h=@sf.dot_size, radius=Full, bg=Muted)

///|
// kept across runs: a value (no field of it changes)
let mark_dot_on : @ui.Style = mark_dot.then(@ui.css("bg=Accent"))

///|
/// What it says: how many (or what to do), 13 medium in the ink; 可继续点选 muted; why it failed in red; all on one line,
/// in what the bar leaves, cut short with an ellipsis where that is less (min-width 0),
/// four of its characters kept (what is beside it in the page's bar gives way first: service.mbt bar_drop_nav).
// kept across runs: a value (no field of it changes)
let mark_words_box : @ui.Style = @ui.css("row w=Full gap=S2")

///|
// kept across runs: a value (no field of it changes)
let mark_count_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let mark_more_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let mark_error_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Danger, wrap=false, w=Cut)

///|
/// Its × (24 round, a 12 icon) and 添加到对话 (24 high, round, the ink's ground, 10 in, 5 apart; 12 medium, the
/// surface's colour: faint while it cannot be pressed).
// kept across runs: a value (no field of it changes)
let mark_close : @ui.Style = @ui.css("w=S6 h=S6 radius=Full align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let mark_put_pill : @ui.Style = @ui.style(
  row=true,
  h=S6,
  radius=Full,
  bg=Fg,
  px=S2_5,
  gap=@sf.mark_put_gap,
  align=ACenter,
)

///|
// kept across runs: a value (no field of it changes)
let mark_put_off : @ui.Style = mark_put_pill.then(@ui.css("bg=A(Fg,O40)"))

///|
// kept across runs: a value (no field of it changes)
let mark_put_words : @ui.TextStyle = @ui.text_style(
  size=Meta,
  weight=Medium,
  color=Card,
  wrap=false,
  dark=@ui.text_patch(color=Bg),
)

///|
/// A small icon in marking's bar.
let mark_small_icon : Double = 12.0

///|
/// A mark's box not open: 4 round, its edge 1.5 of the accent's 55%.
let mark_box_r : Double = 4.0

///|
let mark_edge : Double = 1.5

///|
let mark_edge_a : Double = 0.55

///|
/// What is said of a mark beside its pin: 26 high, round, 10 in; 12 in the ink, one line (its ground and shadow
/// mark_bubble_node's, mark_said_node's).
// kept across runs: a value (no field of it changes)
let mark_said : @ui.Style = @ui.style(h=@sf.mark_said_h, radius=Full, px=S2_5, justify=JCenter, clip=true)

///|
// kept across runs: a value (no field of it changes)
let mark_said_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false)

///|
/// Where a pin sits: 24 wide, its point 2 in from its left and 22 down, kept 2 from the
/// stage's left and 24 from its top; what is said 36 right of its point (28 past it), 220 wanted there, else left of it
/// (14 clear, 6 from the pin), 40 at least.
let pin_w : Double = 24.0

///|
let pin_edge : Double = 2.0

///|
let pin_rise : Double = 22.0

///|
let pin_top : Double = 24.0

///|
let said_from : Double = 36.0

///|
let said_room : Double = 220.0

///|
let said_left : Double = 14.0

///|
let said_beside : Double = 6.0

///|
let said_least : Double = 40.0

///|
/// A mark's note: 280 wide at most (8 clear of the stage's sides), 36 high, round (its ground and stronger shadow
/// mark_bubble_node's), 12 in at its start and 4 at its end, 6 apart; 28 right of the pin's point and 28 above it (8 from
/// the stage's top at least).
// kept across runs: a value (no field of it changes)
let mark_note : @ui.Style = @ui.css("row h=S9 radius=Full pl=S3 pr=S1 gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let mark_note_field : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let mark_note_remove : @ui.Style = @ui.css("w=S7 h=S7 radius=Full align=ACenter justify=JCenter")

///|
let note_most : Double = 280.0

///|
let note_clear : Double = 8.0

///|
let note_off : Double = 28.0

///|
/// The note's words (13) and its remove key's icon (14).
let note_font : Double = 13.0

///|
let note_icon : Double = 14.0
