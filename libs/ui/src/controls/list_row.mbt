// A row of a list ("laid out as a chat's"): a chat's, a
// station's, a folder's, a profile's are one row: its mark beside its first line, its first line (its title and what
// stands at that line's end), then the lines under it; its sizes the theme's chats' list's, how far in and whether its
// ground is rounded where its list stands (ListAt).

///|
// kept across runs: a value (no field of it changes)
let list_row_square : @ui.Style = @ui.css("radius=Sharp")

///|
/// A marked row's first line: its mark and its head, the row's gap between them (the theme's item's S2).
// kept across runs: a value (no field of it changes)
let list_row_marked : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let list_row_under : @ui.Style = @ui.style(w=grow)

///|
/// A row's mark's column (as high as the first line, its mark in its middle).
// kept across runs: a value (no field of it changes)
let list_row_mark : @ui.Style = @ui.css("w=S4 align=ACenter justify=JCenter")

///|
/// A row's key (row_corner_keys): round, 24 across, the pointer's ground on it.
// kept across runs: a value (no field of it changes)
pub let row_key_box : @ui.Style = @ui.css("w=S6 h=S6 radius=Full align=ACenter justify=JCenter hovered{bg=Hover}")

///|
/// The room `n` keys take at a row's first line's end (row_corner_keys): theirs and what is between them.
pub fn row_keys_room(n : Int) -> Double {
  n.to_double() * row_key_side + (n - 1).to_double() * row_keys_gap
}

///|
/// A row's key's side (row_key_box: S6), and the room between keys (S0_5).
let row_key_side : Double = 24.0

///|
let row_keys_gap : Double = 2.0

///|
/// A row's box with another row under it, where its list stands (ListAt): in a side column, where its ground is
/// rounded and in, 2 under it with either input (lit_apart; Sidebar.css.ts navRow `& + &`), so the row pressed or
/// pointed at and the one open never touch and read as one block; across the whole screen the theme's (its rows
/// flush with a finger).
pub fn list_more(at : ListAt) -> @ui.Style {
  match at {
    Side | Tape => side_more
    Whole => theme().chat_list.more
  }
}

///|
// kept across runs: a value (no field of it changes)
// (pb: lit_apart's 2, the scale's S0_5)
let side_more : @ui.Style = @ui.css("w=Full pb=S0_5")
