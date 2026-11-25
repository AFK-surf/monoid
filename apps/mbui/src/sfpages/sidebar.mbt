// The chats' lists (still.fail web/src/Sidebar.tsx ChatList, ChatPane; SidebarList.tsx NavSection; web/src/mobile/Home.tsx
// Home, ChatPane, Empty, FilterButton; Sidebar.css.ts navSlider, navTrack, navScroll, navEmpty; mobile/Home.css.ts
// mHomePanes, mHomePane), one in every tier: 全部, 我参与的 and 监控中 side by side on one track, slid from one to
// another as the filter changes (240 ms) with nothing to wait for, as the core's `chats` view lists each: its days
// under their headings, a row each (chat_row.mbt); while it is read the rows to come, what is wrong over them, an
// empty list's words. While a finger is on a list, the pointer over it or it moves, its rows keep their places
// ; they move as it changes (useListMotion). The frame it is drawn in says what is over
// it and at its foot (the bar it is under, the bottom bar), what it adds at each list's top (a search's field, what is
// left up long), and the lists that follow the three on the track (已归档, where the frame has it so).

///|
/// Something a frame puts in a list: its key among the list's lines, what draws it, and whether the list is first
/// shown scrolled past it (a phone's search over the first row).
pub(all) struct ListPart {
  key : String
  draw : () -> Unit
  tucked : Bool
}

///|
/// The lists the track holds first, in this order (mine, watching).
// kept across runs: a table, never written
pub let list_filters : Array[String] = ["all", "mine", "watching", "hidden"]

///|
/// Which of the lists the filter shows (0 all, 1 mine, 2 watching).
pub fn filter_at(src : Source, w : Workspace) -> Int {
  list_filters.search(@sfbase.filter_of(src, w.id)).unwrap_or(0)
}

///|
fn sidebar_reset() -> Unit {
  list_scrolls.clear()
  rows_rest_at.val = -1.0
  filter_menu_serial.val = -1
  archived_here.set(None)
  archived_n.val = 0
}

///|
/// The chat in the page pane, if one is.
fn open_chat() -> ChatRef? {
  let pages = app.nav.pages()
  for k = pages.length() - 1; k >= 0; k = k - 1 {
    match pages[k] {
      Chat(r) => return Some(r)
      NewChat => return None
      _ => ()
    }
  }
  None
}

///|
let illustration_w : Double = 240.0

///|
// kept across runs: a value (no field of it changes)
let said_box : @ui.Style = @ui.css("w=Full px=S2_5 py=S4")

///|
// kept across runs: a value (no field of it changes)
let said_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, leading=L6)

///|
// kept across runs: a value (no field of it changes)
let empty_first : @ui.Style = @ui.style(w=Full, p=@sf.empty_in, gap=S2_5, align=ACenter)

///|
// kept across runs: a value (no field of it changes)
let empty_box : @ui.Style = @ui.style(w=Full, px=@sf.empty_in, py=S5, gap=S2, align=ACenter)

///|
// kept across runs: a value (no field of it changes)
let empty_title : @ui.TextStyle = @ui.text_style(size=Title, weight=Semibold, color=Fg, center=true, w=Full)

///|
// kept across runs: a value (no field of it changes)
let empty_note : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, center=true, leading=L6, w=Full)

///|
// kept across runs: a value (no field of it changes)
let empty_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted)

///|
// kept across runs: a value (no field of it changes)
let empty_link : @ui.TextStyle = @ui.text_style(size=Ui, color=Link)

///|
/// The filter's menu last opened (its presenter).
// kept across runs: put back by sidebar_reset (reset)
let filter_menu_serial : Ref[Int] = Ref(-1)

///|
/// Whether the filter's menu is open.
pub fn filter_menu_open() -> Bool {
  @sf.presented_drawn_of(filter_menu_serial.val)
}

///|
/// The filter's menu, opened by `from`: 全部会话,
/// 我参与的, 监控中, then 已归档, a menu of choices, the list `shown` (all, mine, watching, archive) checked. Chosen, `go` is
/// given which: where it goes is the frame's (a filter its list, 已归档 its page or list). `in_board`: the board's, which
/// narrows to 全部会话 or 我参与的 alone (its 监控中 is a column of its own), 已隐藏 and 已归档 lists off it
/// (board_filter_go).
pub fn filter_menu(
  from : @sf.Beside,
  shown : String,
  go : (String) -> Unit,
  in_board? : Bool = false,
  along? : @ui.Along = End,
) -> Unit {
  let item = fn(key : String, words : String) -> @sf.MenuItem? {
    Some(@sf.menu_item_of(@sf.t(words), chosen=shown == key, fn() { go(key) }))
  }
  let items = if in_board {
    [
      item("all", "web-main.filter.chats.all"),
      item("mine", "web-main.filter.chats.mine"),
      None,
      item("hidden", "web-main.filter.hidden"),
      item("archive", "web-main.filter.archived"),
    ]
  } else {
    [
      item("all", "web-main.filter.chats.all"),
      item("mine", "web-main.filter.chats.mine"),
      item("watching", "web-main.filter.watching"),
      item("hidden", "web-main.filter.hidden"),
      None,
      item("archive", "web-main.filter.archived"),
    ]
  }
  @sf.menu(
    items,
    from~,
    along~,
  )
  filter_menu_serial.val = @sf.last_presented()
  filter_menu_opened.set(filter_menu_opened.untracked() + 1)
}

///|
/// How many times the filter's menu has opened: what makes the lists it would show at once told as it does
/// (chats_lists_node).
// kept across runs: counted on as it opens (nothing reads its value, only its change)
let filter_menu_opened : @signals.Signal[Int] = @signals.signal(0)

///|
/// The list's filter in workspace `w` chosen (`all`, `mine`, `watching`): sfbase's set_filter_of.
pub fn set_filter(src : Source, w : Workspace, f : String) -> Unit {
  @sfbase.set_filter_of(src, w.id, f)
}

///|
/// The board's filter's menu chosen (filter_menu's `in_board`) in workspace `w`: 全部会话 and 我参与的 narrow the board
/// (sfbase's board_filter_of), 已隐藏 its list in the board's place, 已归档 `archive` (the frame's: its page or list).
pub fn board_filter_go(src : Source, w : Workspace, f : String, archive : () -> Unit) -> Unit {
  match f {
    "all" | "mine" => set_filter(src, w, f)
    "hidden" => {
      set_filter(src, w, f)
      @sfbase.board_set(src, false)
    }
    "archive" => archive()
    _ => ()
  }
}
