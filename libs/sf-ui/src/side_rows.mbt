// A sidebar's rows (still.fail web/src/Sidebar.css.ts navRow, navNew, navScroll; NavAction): a
// row of one line, a row laid out as a chat's (list_row), the band's action over a list, the list under the band; a
// row's ground as the web moves it. The sidebar's frame (its top row, its width, its fold)
// is the shell's.

///|
/// What a state's ground changes over (vars.dur: 140 ms, ease out).
// kept across runs: a value (no field of it changes)
pub let nav_fade : @motion.Spec = @motion.tween(dur_ms, ease=Out)

///|
/// How high a band's row is (the theme's band's).
pub fn band_row_h() -> Double {
  theme().chat_list.band_h
}

///|
/// The band an action over a list stands in (Sidebar.css.ts navNew): 6 over, 2 under, as far in at its sides as the
/// theme's band (the search's field's); what is beside the action (the filter, 更新) as far from it as keys are
/// (keys_gap: 4 with keyboard and mouse, 12 with touch).
pub fn nav_new() -> @ui.Style {
  nav_new_look.then(@ui.style(px=room_of(theme().chat_list.band_in), gap=S1))
}

///|
// kept across runs: a value (no field of it changes)
let nav_new_look : @ui.Style = @ui.css("row w=Full pt=S1_5 pb=S0_5 align=ACenter")

///|
/// The list under a sidebar's band (Sidebar.css.ts navScroll): in at its sides as the theme's sidebar's lists are, 4
/// under the band.
pub fn side_list() -> @ui.Style {
  theme().chat_list.side_list.then(side_list_top)
}

///|
// kept across runs: a value (no field of it changes)
let side_list_top : @ui.Style = @ui.css("pt=S1")

///|
/// A row's mark's side (the action's icon: ICON's 16).
pub let nav_mark_side : Double = 16.0

///|
// kept across runs: a value (no field of it changes)
let nav_title_away : @ui.TextStyle = @ui.text_style(color=Muted)

///|
/// What a row says in a line under its title or at its end (end): a chat's second line's
/// words (the theme's chats' list's), as long as they are.
pub fn nav_meta() -> @ui.TextStyle {
  theme().chat_list.last.then(nav_meta_hug)
}

///|
// kept across runs: a value (no field of it changes)
let nav_meta_hug : @ui.TextStyle = @ui.text_style(w=Hug)
