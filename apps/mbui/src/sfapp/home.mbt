// Home: the workspace's chats' lists (sfpages'
// sidebar.mbt, every tier's) under a top bar (the filter · the workspace's switcher and settings).

///|
/// The top bars' height under the status bar (a place's, TopGlassBar, and a chat's, BarFrame: TopBarHeight), what is in
/// them in its middle; the list starts under it. One length, on the device's pixels at once: 8 + 34 + 8 and 5 + 40 + 5,
/// each on whole pixels, can come out a pixel apart (at 2.85 pixels a point, 143 and 142), the two bars' lines apart
/// as a chat is swiped back.
let bar_h : Double = 50.0

///|
/// A bar's round key's side (34).
let nav_key_side : Double = 34.0

///|
/// The filter's menu chosen on Home: a filter its list, 已归档 its page; on the board (`board`), as the board's menu has
/// it (sfpages' board_filter_go).
fn home_filter_go(src : Source, w : Workspace, f : String, board? : Bool = false) -> Unit {
  match f {
    "archive" => open_page(Archived)
    _ if board => @sfpages.board_filter_go(src, w, f, fn() { open_page(Archived) })
    _ => @sfpages.set_filter(src, w, f)
  }
}

///|
/// The workspaces opened from Home's top as it first draws (the fixture's home-sheet: newchat_fixture.mbt open_mode).
// kept across runs: put back by reset, let go as Home reads it
let home_sheet_at_start : Ref[Bool] = Ref(false)

///|
/// The workspace's mark before its name in Home's bar.
let home_ws_mark : Double = 20.0
