// What a chat's list holds on the desktop besides its messages (still.fail web/src/Chat.tsx ChatRows, OutboxRow, Activity,
// useSteady; Chat.css.ts chatUnreadLine, chatOlder, chatNewer, chatEmpty, msgUnsent, msgUnsentBtn, agentActivity,
// activityLine, activityAvatar, activityRing, activityTail, activityNowText, activityElapsed, activityStop): the line
// over what is new, the pages being brought in, what was sent from here and is not in the chat yet, where it stands,
// and its agents at work.

///|
/// How many positions of either step can be seen; glyphs past the window do not make the visible change rush.
fn activity_change_places(old_cells : Array[(Double, Double)], new_cells : Array[(Double, Double)], visible : Double) -> Int {
  let mut count = 0
  let length = if old_cells.length() > new_cells.length() { old_cells.length() } else { new_cells.length() }
  for i in 0..<length {
    if (i < old_cells.length() && old_cells[i].0 < visible) || (i < new_cells.length() && new_cells[i].0 < visible) {
      count = i + 1
    }
  }
  if count > 0 { count } else { 1 }
}

///|
/// Let a new activity's room begin opening before its first words arrive.
let activity_glyph_delay_ms : Double = @ui.move_least_ms / 2.0

///|
let activity_glyph_in_ms : Double = activity_glyph_delay_ms + @sfbase.glyph_line_in_ms

///|
/// What the rows keep of their own, let go (the package's reset).
fn rows_reset() -> Unit {
  dismissed.set([])
}

///|
/// "正在发送" shows once a message has been on its way this long (SENDING_SHOWS_MS).
pub let sending_shows_ms : Double = 800.0

///|
/// Each thing an activity says stays this long at least (DWELL_MS) before the next begins.
let steady_dwell_ms : Double = 700.0

///|
/// A step gone before its glyphs could have arrived does not interrupt the words shown.
let steady_candidate_ms : Double = @sfbase.glyph_change_in_ms

///|
/// The ring round the picture: 24 across, its arcs 1.5 (3 round the 18).
let ring_side : Double = 24.0

///|
let ring_stroke : Double = 1.5

///|
/// The icons under what did not go (12), and an activity's stop (12).
let unsent_icon : Double = 12.0

///|
let stop_icon : Double = 12.0

///|
/// Under it (msgUnsent): 4 under, at the column's end, 2 apart; its note 6 before the buttons.
// kept across runs: a value (no field of it changes)
let unsent_row : @ui.Style = @ui.css("row pt=S1 gap=SPx align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let unsent_note : @ui.Style = @ui.css("row pr=S1_5 gap=S1 align=ACenter")

///|
/// What takes back what is held till its station is reached, after 连上后发出 in its line (outbox_row's).
// kept across runs: a value (no field of it changes)
let held_buttons : @ui.Style = @ui.css("row gap=SPx align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let unsent_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Danger, wrap=false)

///|
/// Its buttons (msgUnsentBtn): 2 by 6 in, 4 apart, 7 round; the hover ground under the pointer; at 55% when they may
/// not be pressed.
// kept across runs: a value (no field of it changes)
let unsent_button_box : @ui.Style = @ui.css("row px=S1_5 py=S0_5 gap=S1 radius=Md align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let unsent_button_hot : @ui.Style = unsent_button_box.then(@ui.css("bg=Hover"))

///|
// kept across runs: a value (no field of it changes)
let unsent_label : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let unsent_label_hot : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false)

///|
/// An activity's row (activityRow): its line and its stop 4 apart.
// kept across runs: a value (no field of it changes)
let activity_row_box : @ui.Style = @ui.css("row w=Full gap=S1 align=ACenter")

///|
/// Its line (activityLine): its picture where the messages' pictures are, out in the margin before the words
/// (message_avatar_out), the picture and what it does 8 apart, 6 round; fills the row so shrinking words during a
/// click never drop the press.
// kept across runs: a value (no field of it changes)
let activity_line : @ui.Style = @ui.style(row=true, w=@sf.grow, gap=S2, radius=Md, align=ACenter, ml=@sf.message_avatar_out)

///|
/// Narrow: its picture at the row's start, as the messages' are there (inlineHeads).
// kept across runs: a value (no field of it changes)
let activity_line_narrow : @ui.Style = @ui.style(row=true, w=@sf.grow, gap=S2, radius=Md, align=ACenter)

///|
/// Its picture with the ring round it (activityAvatar): 24 across, the picture in its middle; the ring reaching 3 past
/// the picture on either side (activityRing inset -3), into no room of the line's: what the line lines up is the
/// picture, in the messages' pictures' column.
// kept across runs: a value (no field of it changes)
let activity_face : @ui.Style = @ui.css("w=S6 h=S6 align=ACenter justify=JCenter").then(@sf.outset(ring_room))

///|
// kept across runs: a value (no field of it changes)
let ring_waiting : @ui.Style = @ui.css("w=S6 h=S6 radius=Full border=B1_5 border_color=Line")

///|
/// What it does and how long (activityTail): 8 apart; cut at its width's share as it folds.
// kept across runs: a value (no field of it changes)
let activity_tail : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
/// What it does now (activityNowText): 13, muted (the text's under the pointer), one line, cut short with an ellipsis
/// where the line has less room (its min-width 0, text-overflow): an agent's step is as long as it says it, so the
/// words give way and nothing else does; how long (activityElapsed, flex none), subtle, whole.
// kept across runs: a value (no field of it changes)
let now_room : @ui.Style = @ui.css("row")

///|
/// The incoming line starts at the same edge as the line it replaces.
// kept across runs: a value (no field of it changes)
let now_glyph_layer : @ui.Style = @ui.css("align=AStart")

///|
// kept across runs: a value (no field of it changes)
let now_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let now_words_hot : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let activity_clock : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)

///|
/// Its stop (activityStop): 24 round in 6, the muted ink; the hover ground and the text's under the pointer.
// kept across runs: a value (no field of it changes)
let activity_stop : @ui.Style = @ui.css("w=S6 h=S6 radius=Md align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let activity_stop_hot : @ui.Style = activity_stop.then(@ui.css("bg=Hover"))

///|
/// Where it stands (chat_state): its icon's column (the theme's lists' state_slot, as high as a line of its words: the
/// row's line, the theme's), 6 before them; its words wrapping.
// kept across runs: a value (no field of it changes)
let chat_state_row : @ui.Style = @ui.css("row w=Full gap=S1_5 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let chat_state_wraps : @ui.TextStyle = @ui.text_style(wrap=true)

///|
/// What the chat needs of the viewer, with 忽略 (chat_state): its words taking what 忽略 leaves at its end (a column of
/// them, 忽略 under them at the end, where a native narrow chat has little room); after the bell's disc as far as a
/// state line's words after its icon (no disc drawn round it, an option's 12 leaves the bare bell far off).
// kept across runs: a value (no field of it changes)
let need_card_words : @ui.Style = @ui.style(row=true, w=@sf.grow, gap=S1_5, align=AStart)

///|
// kept across runs: a value (no field of it changes)
let need_card_actions : @ui.Style = @ui.css("row w=Full pt=S1_5 justify=JEnd")
