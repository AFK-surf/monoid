// A page's bar of keys over what it shows (web Preview.tsx PreviewBar, Preview.css.ts previewBar, previewAddress; the
// phone's Preview.kt PreviewBar alike): a row of round keys and one capsule where it is, the same on every screen. Its
// room the theme's (Bars): a key's, an icon's, the capsule's; a finger reaches a key from round it all the same
// (mbui's press_reach), so none is drawn larger for a phone.

///|
// kept across runs: a value (no field of it changes)
let page_bar_box : @ui.Style = @ui.css("row w=Full px=S2 py=S1_5 align=ACenter")

///|
/// With a key at its end: its words' room the rest, the key's own after it, the capsule's right its own.
// kept across runs: a value (no field of it changes)
let bar_field_ended : @ui.Style = @ui.css("pr=S0 gap=S0")

///|
// kept across runs: a value (no field of it changes)
let bar_field_words : @ui.Style = @ui.css("row w=Full h=Full gap=S1_5 align=ACenter")

///|
/// The key at its end: in a press's room across, at its right 4 in, so its icon stands as far in from the capsule's
/// end as the place's icon from its start (12).
// kept across runs: a value (no field of it changes)
let bar_field_end : @ui.Style = @ui.css("row h=Full pr=S1 align=ACenter justify=JEnd")

///|
// kept across runs: a value (no field of it changes)
let bar_field_room : @ui.Style = @ui.style(w=Full, min_w=Fixed(bar_field_least), px=S1)

///|
/// The least the place's room is wide before what beside it that may leave the bar does: its capsule 160 (as the find
/// field's least, find.mbt), 4 either side of it.
pub let bar_field_least : Double = 168.0

///|
// kept across runs: a value (no field of it changes)
let bar_field_box : @ui.Style = @ui.css("row w=Full radius=Full bg=Faint px=S3 gap=S1_5 align=ACenter clip")

///|
// kept across runs: a value (no field of it changes)
let bar_field_editing : @ui.Style = bar_field_box.then(@ui.css("bg=Card border=B1_5 border_color=A(Accent,O50)"))

///|
/// A capsule on a bar of the canvas's own ground (`framed`, a station's browser's): the card's, its line round it.
// kept across runs: a value (no field of it changes)
let bar_field_framed : @ui.Style = bar_field_box.then(@ui.css("bg=Card border=B0_5 border_color=Line"))

///|
/// How thick a pane's edge is on the tape (the frame's page_apart: a point), what a bar at its top stands under.
pub let pane_edge : Double = 1.0
