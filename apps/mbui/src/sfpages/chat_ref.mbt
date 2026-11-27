// The `@` menu over the desktop's composer (still.fail web/src/ChatRef.tsx ChatRefMenu, Chat.tsx useComposerText's
// reference and its keys; ChatRef.css.ts refMenu, refHead, refQuery, refEmpty, refItem, refLogo, refTitleCell,
// refTitle, refChipStation, refTime): `@` and a few letters at the caret offer the workspace's chats, then the
// viewer's other workspaces' (the core's `chatSearch`); the one picked goes in as its mark. What the field's words hold
// (the `@words`, the marks) is sfbase's refs.mbt's, as the core reads it.

///|
/// The draft whose `@` menu ↑ or ↓ chose another in since it was last built ("" none): what it shows it brings into
/// view.
let ref_keyed : Ref[String] = Ref("")

///|
/// 8 over the composer (refMenu: bottom 8).
let ref_menu_off : Double = 8.0

///|
/// How many chats it offers (SHOWN).
let ref_shown : Int = 8

///|
/// A chat's agent's mark (ModelLogo 14).
let ref_logo_size : Double = 14.0

///|
/// Another station's mark (StationMark 11).
let ref_chip_icon : Double = 11.0

///|
/// What it says in place of chats (refEmpty): 6 by 10 in, the ui size, muted.
// kept across runs: a value (no field of it changes)
let ref_empty : @ui.Style = @ui.css("w=Full px=S2_5 py=S1_5")

///|
// kept across runs: a value (no field of it changes)
let ref_empty_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let ref_logo : @ui.Style = @ui.css("w=S4 align=ACenter justify=JCenter")

///|
/// Its title and whose (refTitleCell, refTitle): the title cut short first.
// kept across runs: a value (no field of it changes)
let ref_title_cell : @ui.Style = @ui.style(row=true, w=@sf.grow, align=ACenter)

///|
// kept across runs: a value (no field of it changes)
let ref_title : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false, w=Cut)

///|
/// Whose it is (refChipStation): a pill 4 after the title, 1 by 6 in, the meta size, muted, on the hover's ground.
// kept across runs: a value (no field of it changes)
let ref_chip_station : @ui.Style = @ui.css("row ml=S1 px=S1_5 py=SPx gap=SPx radius=Full bg=Hover align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let ref_chip_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
/// When (refTime): the meta size, muted.
// kept across runs: a value (no field of it changes)
let ref_time : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
/// Skill row cell (skill name followed by truncated description).
// kept across runs: a value (no field of it changes)
let skill_cell : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let skill_name : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, weight=Medium, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let skill_desc : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)
