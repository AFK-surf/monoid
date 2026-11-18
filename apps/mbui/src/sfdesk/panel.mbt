// Beside a chat on the desktop (still.fail web/src/pages/ChatPage.tsx's side panel, ChatSide.tsx useSidePanel, SidePane,
// FilesTab; ChatPage.css.ts sidePanel, sideBar, sideTab): the side panel at the pane's right, a tab each for what is
// opened in it (an agent's execution history, the chat's services and jobs, the stations' files, what its agents and
// other chats' wrote each other), the one in front shown; its edge drags its width (pressed, the panel closes), its
// switch closes it. It slides in and out as its first tab opens and its last closes. Which tabs are open and in front
// is the core's (the chat view's `tabs`), as are the changes (`chat.tabs.*`). Each chat keeps its own tabs.

///|
/// A chat's tabs' key as the core keeps them (the prefs' `chatTabs`: `<station>:<session>`, as its page names it).
fn tabs_key(r : ChatRef) -> String {
  r.station + ":" + r.session
}

///|
/// Whether this panel shows `tab` beside a chat of `v`: one of its agents' histories (by its session's key), 任务, 文件,
/// agent 往来, a web service of its agents' (`service:<job>`), a visualization (`file:[…]`: service_tab.mbt), a file in
/// the viewer (`view:[…]`: sfbase's viewer_tab.mbt).
fn side_shows(v : ChatView, tab : String) -> Bool {
  tab == "jobs" ||
  @sfbase.view_tab_file(tab) is Some(_) ||
  tab == "files" ||
  tab == "letters" ||
  tab == "things" ||
  tab_service(tab) is Some(_) ||
  tab_file(tab) is Some(_) ||
  station_tab(tab) is Some(_) ||
  v.agents.iter().any(fn(a) { a.key == tab })
}

///|
/// The chat's side panel's tabs, in their order, and the one in front: the core's (the chat view's `tabs`: those kept
/// for it on this device that it has, ChatPage.tsx), of those this panel shows.
pub fn side_of(v : ChatView) -> (Array[String], String) {
  let tabs = v.tabs.open.filter(fn(t) { side_shows(v, t) })
  let front = match v.tabs.shown {
    Some(f) if tabs.contains(f) => f
    _ => tabs.get(0).unwrap_or("")
  }
  (tabs, front)
}

///|
/// Chat `r`'s tabs as its view has them now (its head alone: sfbase's chat_view_now, told as they change, not as a word
/// comes into a message).
pub fn side_now(src : Source, r : ChatRef) -> (Array[String], String) {
  match @sfbase.chat_view_now(src, r) {
    Some(v) => side_of(v)
    None => ([], "")
  }
}

///|
/// Chat `r`'s tabs changed by the core, which keeps them on this device: `tab` opened in front (an
/// agent's history after the histories open, any other last), closed (the last left in front, if it was), brought to
/// the front; all of them closed (`clear`). The panel is told first whether any will be open, to slide as they come.
pub fn side_change(src : Source, r : ChatRef, action : String, tab : String?) -> Unit {
  side_change_from(src, r, action, tab, side_now(src, r))
}

///|
/// What waits for a tab pressed to the front (side_front_pressed): one at a time, given up as another is pressed.
// kept across runs: put back by chat_page_reset
let side_front_wait : Ref[@sfbase.PressWait?] = Ref(None)

///|
/// A tab of chat `r`'s panel pressed to the front: in front once what it shows first is answered (sfbase's
/// show_answered_wait), the panel as it was meanwhile, never emptied to be filled as the core answers; at once where it is
/// answered already (kept, or held by the panel). Pressed again, or another, while it waits: that one instead.
pub fn side_front_pressed(src : Source, r : ChatRef, tab : String) -> Unit {
  match side_front_wait.val {
    Some(w) => w.give_up()
    None => ()
  }
  side_front_wait.val = None
  // (what it asked handed to the tab as it is first built, its reads then the tab's own: side_tab_shown_at)
  let at = side_tab_shown_at(r, tab)
  let front = fn() { side_change(src, r, "front", Some(tab)) }
  // (an agent's history its transcript's place too, as it is opened (history_side_open): its line there from its
  // first frame, nothing pushed down under its head after it came)
  let w = if side_history_tab(tab) {
    // (a replay of a run from before asks nothing ahead: shown at once, as history_side_open)
    let path = if !src.read_only && (src.switches_ahead)() { Some(wh_transcript(src, r.station, tab)) } else { None }
    let placed = fn() {
      match path {
        Some(p) => p.get() is Some(_)
        None => true
      }
    }
    @sfbase.show_answered_with(src, side_tab_reads(r, tab), placed, at, front)
  } else {
    @sfbase.show_answered_wait(src, side_tab_reads(r, tab), at, front)
  }
  if w.waiting() {
    side_front_wait.val = Some(w)
  }
}

///|
/// What tab `tab` of chat `r`'s panel is shown for, to what its press asked (hand_over_shown): taken as the tab is first
/// built (sfbase's shown_read, jobs_tab_node's).
pub fn side_tab_shown_at(r : ChatRef, tab : String) -> String {
  "side\u{1}" + chat_key(r) + "\u{1}" + tab
}

///|
/// What tab `tab` of chat `r`'s panel reads as it is first drawn, that its press waits for (side_front_pressed): 任务
/// its chat's services and jobs (jobs_tab_node's `chatJobs`); an agent's history its model's pick (its head's
/// model_triple_node) and its steps, with 详情 what they read where they are unfolded (wh_details_asks).
fn side_tab_reads(r : ChatRef, tab : String) -> Array[(String, Map[String, Json])] {
  match tab {
    "jobs" => [("chatJobs", chat_params(r))]
    _ if side_history_tab(tab) =>
      [
        ("pick", { "station": Json::string(r.station), "of": Json::string("session:" + tab) }),
        ..if @signals.untracked(fn() { !history_own.shut.get() }) {
          wh_details_asks(r.station, tab)
        } else {
          [@sfpages.history_ask(r.station, tab)]
        },
      ]
    _ => []
  }
}

///|
/// side_change, chat `r`'s tabs as they are now (side_now's) given, read by the caller where it holds them: what
/// changes them as a page comes on top (beside_follow) reads them in its reaction's read, held as long as that reads
/// them, not by the wide frame's node for as long as it lives (Source::owned_by's raw read: the chat held after it left).
fn side_change_from(src : Source, r : ChatRef, action : String, tab : String?, now : (Array[String], String)) -> Unit {
  let (tabs, front) = now
  let any = match action {
    "open" | "front" => true
    "close" => tabs.iter().any(fn(t) { Some(t) != tab })
    _ => false
  }
  side_changing(chat_key(r), tabs, front, any)
  // a tab opened or brought to the front beside the chat shown while its panel was open already: on the tape, the panel
  // brought over (none open yet: tape_settle's, once the core says it)
  if tabs.length() > 0 && (action == "open" || action == "front") {
    tape_bring_side(r)
  }
  // a web service's, visualization's, screen's or terminal's tab closed lets its session go
  match (action, tab) {
    ("close", Some(t)) => tab_let_go(src, r, t)
    ("clear", _) => for t in tabs { tab_let_go(src, r, t) }
    ("open", Some(t)) => tab_kept(r, t)
    _ => ()
  }
  side_ask(src, r, action, tab)
}

///|
/// The change asked of the core alone (changeTabs, `chat.tabs.*`), the panel told nothing: as a chat made from the new
/// chat's page starts with what it had beside it.
pub fn side_ask(src : Source, r : ChatRef, action : String, tab : String?) -> Unit {
  let params : Map[String, Json] = { "chat": Json::string(tabs_key(r)) }
  match tab {
    Some(t) => params["tab"] = Json::string(t)
    None => ()
  }
  (src.call)("chat.tabs." + action, Json::object(params), @sfbase.answer_unread)
}

///|
/// File tab `tab` opened beside chat `r` (the shell's `beside`: sfapp's beside_where), in front; a tab of that file open
/// there already (the same file, what it said of itself then aside: view_tab_file's same_file), that one brought to the
/// front, never a second: the tab put in front.
pub fn view_beside(src : Source, r : ChatRef, tab : String) -> String {
  // (that file in a window of its own: the window to the front, the panel left as it is: sfbase's tab_window_front)
  match @sfbase.tab_window_front(r, tab) {
    Some(there) => return there
    None => ()
  }
  let open = match @sfbase.view_tab_file(tab) {
    Some(f) =>
      side_now(src, r).0
      .iter()
      .find_first(fn(t) {
        match @sfbase.view_tab_file(t) {
          Some(g) => f.same_file(g)
          None => false
        }
      })
    None => None
  }
  let put = open.unwrap_or(tab)
  side_change(src, r, "open", Some(put))
  put
}

///|
/// An agent's history pressed (its mark in the bar), or the chat's files (its info's 文件): in front, closed; else
/// opened in front, whole (side_tab_open).
pub fn side_toggle(src : Source, r : ChatRef, tab : String) -> Unit {
  let (tabs, front) = side_now(src, r)
  if tabs.contains(tab) && front == tab {
    side_change(src, r, "close", Some(tab))
  } else {
    side_tab_open(src, r, tab)
  }
}

///|
/// Tab `tab` beside chat `r` opened in front by a press (its mark in the bar, the chat's info, its jobs' mark): once
/// what it first shows is answered, the panel as it was meanwhile, so it slides in whole: an agent's history its
/// transcript's place (history_side_open); where what opens waits for what it shows (gates_opens, MBUI_OPEN_WHOLE) the
/// others what they read as they are first drawn (side_tab_asks), through press_wait (sfbase's open_answered:
/// open_hold_ms at most, given up as the chat is left); one there already, brought to the front at once.
pub fn side_tab_open(src : Source, r : ChatRef, tab : String) -> Unit {
  // (in a window of its own: that window to the front instead, sfbase's tab_window_front)
  if @sfbase.tab_window_front(r, tab) is Some(_) {
    return
  }
  let open = fn() { side_change(src, r, "open", Some(tab)) }
  if side_history_tab(tab) {
    history_side_open(src, r, tab, open)
    return
  }
  let asks = if (src.gates_opens)() && !side_now(src, r).0.contains(tab) { side_tab_asks(src, r, tab) } else { [] }
  @sfbase.open_answered(src, asks, open, most=@sf.open_hold_ms) |> ignore
}

///|
/// What tab `tab` beside chat `r` reads of the core as it is first drawn, every one of it read whatever is answered:
/// 任务 its jobs whole (jobs_tab_node); Agent 往来 the chat's letters by its thread, as its view says it
/// (letters_tab_node); a web service its job (its tab's name, side_tab_names, and service_pane). 图片、文件和链接 read the
/// chat's page holds already; 文件's folder is its station's listing (drive_folder: held by the drive's own scope, asked
/// of the station, so a wait never holds for it).
fn side_tab_asks(src : Source, r : ChatRef, tab : String) -> Array[(String, Map[String, Json])] {
  match tab {
    "jobs" => [("chatJobs", @sfbase.chat_params(r))]
    "letters" =>
      match @signals.untracked(fn() { view_of_chat(src, r).0.bind(fn(v) { v.thread }) }) {
        Some(thread) => [("chatLetters", { "station": Json::string(r.station), "thread": Json::number(thread) })]
        None => []
      }
    _ =>
      match tab_service(tab) {
        Some(job) => [("job", { "station": Json::string(r.station), "id": Json::string(job) })]
        None => []
      }
  }
}

///|
/// How narrow and how wide the panel is dragged (PANEL_MAX).
let panel_min : Double = 320.0

///|
let panel_max : Double = 960.0

///|
/// How wide the panel is (else 38% of the page and at least 360), the
/// chat keeping 360 at least.
pub fn side_width(pane : Double) -> Double {
  let wanted = match panel_own.width.get() {
    Some(w) => w
    None => dmax(360.0, (pane * 0.38).floor())
  }
  dmax(0.0, dmin(wanted, pane - 360.0))
}

///|
/// The chat and the panel side by side.
// kept across runs: a value (no field of it changes)
let panel_row : @ui.Style = @ui.css("row w=Full h=Full")

///|
/// The least the chat and the panel are side by side (ChatSide.tsx panelWidth: the chat 360, the panel 360 at least, the
/// rule between): on a page narrower, the panel over the page.
let side_both_least : Double = 721.0

///|
/// How wide the panel is over the page (ChatPage.css.ts sidePanel on a narrow page: min(460px, 100vw)).
let side_over_w : Double = 460.0

///|
/// Whether the panel being built is a panel of its own on the tape (tape_side): round by the tape's corner.
// kept across runs: said by tape_side round the panel it builds
let side_on_tape : Ref[Bool] = Ref(false)

///|
/// The page under the panel over it: as wide as it is.
// kept across runs: a value (no field of it changes)
let panel_page_whole : @ui.Style = @ui.css("w=Full h=Full")

///|
/// The panel over the page (sidePanel, narrow): the page's ground, its shadow at its side (-12 0 32).
// kept across runs: a value (no field of it changes)
let side_over_box : @ui.Style = @ui.css("bg=Bg shadow=Xl")

///|
/// The panel (sidePanel): its ground the canvas, beside the page with no line between: its edge's own line shows as
/// the pointer comes onto it (@sf.resize_handle; 2026-10-26 用户 of a hairline always there: 「搞坏了宽度调整的样式」).
// kept across runs: a value (no field of it changes)
pub let side_panel_style : @ui.Style = @ui.css("w=Full h=Full bg=Bg")

///|
/// Its bar (sideBar): 45 high, the tabs from 8 in, the panel's switch at its right 12 in (at the window's top right
/// corner, following it where the bar's buttons do: @sf.window_end_in).
pub fn side_bar() -> @ui.Style {
  side_bar_look.then(@ui.style(pr=@sf.room_of(@sf.window_end_in(side_bar_end))))
}

///|
// kept across runs: a value (no field of it changes)
let side_bar_look : @ui.Style = @ui.css("row w=Full h=S11 pl=S2 gap=S2 align=ACenter")

///|
/// Its bar as a panel of its own on the tape (laid out Medium, its corners @sf.pane_round): on the tape's one line, as
/// every bar of the tape is (@sf.tape_line: what it holds in its middle as far under the panel's top as a bar's round
/// buttons' middles, the page's beside it on the same), the first tab in its top left corner and the switch in its top
/// right each as far in as makes them concentric with the corner they are in (@sf.line_end_in); in one too square for
/// that (it follows a round window), clear of it, as in the wide frame at least (side_bar's 8 and 12); its foot as
/// before.
pub fn side_bar_tape() -> @ui.Style {
  match @sf.pane_radii() {
    Some(k) => side_bar_tape_in(k)
    None => side_bar()
  }
}

///|
/// side_bar_tape's, its panel's corners `radii` round (the tree's bar, side_bar_node: as the tree has the window's
/// corner).
fn side_bar_tape_in(radii : FixedArray[Double]) -> @ui.Style {
  let (left, right) = (radii[0], radii[1])
  // (the switch the tallest in it, the row's top its, the tab's middle on its)
  let side = bar_button_side()
  @ui.style(
    row=true,
    w=Full,
    pt=@sf.room_of(@ui.capsule_in(@sf.tape_corner, side)),
    pb=S1_5,
    pl=@sf.room_of(@sf.line_end_in(left, side_bar_start, side=@sf.side_tab_side)),
    pr=@sf.room_of(@sf.line_end_in(right, side_bar_end, side~)),
    gap=S2,
    align=ACenter,
  )
}

///|
/// The tabs' room at the bar's start in the wide frame (side_bar: pl=S2).
let side_bar_start : Double = 8.0

///|
/// The switch's room at the bar's end in the wide frame (side_bar: pr=S3).
let side_bar_end : Double = 12.0

///|
/// Its tabs (sideTabList), 2 apart.
// kept across runs: a value (no field of it changes)
pub let side_tab_list : @ui.Style = @ui.style(row=true, w=@sf.grow, gap=S0_5, align=ACenter, clip=true)

///|
/// A tab (sideTabWrap, sideTab): 30 high, its mark (in a 14 room) and label 6 apart, its close 5 from its end, each in
/// the middle of its end, concentric with it (a service's dot too); a capsule (so in a panel's corner it stands where
/// its shape is concentric with it).
// kept across runs: a value (no field of it changes)
let side_tab_shape : @ui.Style = @ui.style(
  row=true,
  h=@sf.side_tab_h,
  pl=@sf.capsule_end_room(@sf.side_tab_side, side_tab_mark_side),
  pr=S1_25,
  gap=S1_5,
  align=ACenter,
  radius=Full,
)

///|
/// The one in front: the selected ground under it; pressed, it does nothing, so pointed at it stays as it is (its ×
/// lights over it).
// kept across runs: a value (no field of it changes)
pub let side_tab_in_front : @ui.Style = side_tab_shape.then(@ui.css("bg=Selected"))

///|
/// Its mark's room: an icon's, a maker's mark's, a service's dot in its middle.
let side_tab_mark_side : Double = 14.0

///|
// kept across runs: a value (no field of it changes)
let side_tab_mark : @ui.Style = @ui.css("w=S3_5 h=S3_5 align=ACenter justify=JCenter")

///|
/// Its label: muted, 13; the one in front in the words' colour and 500. Cut short where the tabs have not the room
/// (sideTab's min-width 0): a tab gives way, never runs past the bar.
// kept across runs: a value (no field of it changes)
pub let side_tab_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
/// One behind, pointed at: its words in the words' colour.
// kept across runs: a value (no field of it changes)
let side_tab_words_lit : @ui.TextStyle = side_tab_words.then(@ui.text_style(color=Fg))

///|
// kept across runs: a value (no field of it changes)
pub let side_tab_front : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false, w=Cut)

///|
/// Its close (sideTabClose): 20 round, concentric in the tab's end; pointed at, the pointer's ground over the tab's.
// kept across runs: a value (no field of it changes)
pub let side_tab_close : @ui.Style = @ui.css("w=S5 h=S5 radius=Full align=ACenter justify=JCenter hovered{bg=Hover}")

///|
/// What the tab in front shows, under the bar.
// kept across runs: a value (no field of it changes)
pub let side_pane : @ui.Style = @ui.css("w=Full h=Full clip")

///|
/// What the panel keeps of its own (its tabs are the core's): the width it was dragged to (None: its own), and its
/// slide (useSidePanel), for the page it is beside (a chat's, a workspace's new chat's): what it was last built as
/// (open or not), whether a change asked of the core here opens or closes it (`asked`: it slides then), and while it
/// slides out, what it showed (its tabs and the one in front); a chat's panel's column's way, by its page's key, set off
/// at the change that opens or closes it and read where it is drawn (side_panel_node).
priv struct PanelOwn {
  width : @signals.Signal[Double?]
  was : @sf.LiveMap[String, Bool]
  asked : @signals.Signal[String]
  leaving : @signals.Signal[(String, Array[String], String)?]
  goes : Map[String, @motion.Way]
}

///|
let panel_own : PanelOwn = {
  width: @signals.signal(None, same=fn(a, b) { a == b }),
  was: @sf.LiveMap::new(),
  asked: @signals.signal("", same=fn(a, b) { a == b }),
  leaving: @signals.signal(None, same=fn(a, b) { a == b }),
  goes: {},
}

///|
pub fn side_slide_reset() -> Unit {
  panel_own.width.set(None)
  panel_own.was.clear()
  panel_own.asked.set("")
  panel_own.leaving.set(None)
  panel_own.goes.clear()
}

///|
/// A change of page `key`'s tabs asked of the core, from `tabs` (`front` in front), leaving `any` open (useSidePanel
/// changing): from none to some, the panel slides in once they come; from some to none, out, showing them as it goes.
pub fn side_changing(key : String, tabs : Array[String], front : String, any : Bool) -> Unit {
  let open = tabs.length() > 0
  if any {
    panel_own.leaving.set(None)
  }
  if open != any {
    panel_own.asked.set(key)
    if !any {
      panel_own.leaving.set(Some((key, tabs, front)))
    }
  } else {
    panel_own.asked.set("")
  }
}

///|
/// What page `key`'s panel shows while it slides out, its last tab closed: the tabs it had, the one in front.
fn side_leaving(key : String) -> (Array[String], String)? {
  match panel_own.leaving.get() {
    Some((k, tabs, front)) if k == key => Some((tabs, front))
    _ => None
  }
}

///|
/// Page `key`'s panel gone, as it was sliding out (its tabs shown no more).
fn side_left(key : String) -> Unit {
  if side_leaving(key) is Some(_) {
    panel_own.leaving.set(None)
  }
}

///|
/// Page `key` (`page`) and its side panel (`panel`, `whole` wide at rest) side by side, the panel `open` or not. Opened by
/// a change asked here, the panel's column widens from nothing over 280 ms and the page narrows with it, frame by frame;
/// closed, the other way over 240 ms. The panel keeps its whole width all along and shows
/// through its column as it grows, so it comes in from the right edge without what it holds laid out again; turned back
/// on its way, it goes on from where it is. Open or closed otherwise (a page opened with its tabs as they were left),
/// it is so at once.
pub fn side_beside(c : @ui.Ctx, key : String, open : Bool, whole : Double, page : () -> Unit, panel : () -> Unit) -> Unit {
  // where the page has not the room for the chat and the panel at their least side by side, the panel comes in over
  // the page from its right edge (a shadow at its side), the
  // page as wide as it was, the panel's edge not dragged
  let over = c.width < side_both_least
  let whole = if over { dmin(side_over_w, c.width) } else { whole }
  let name = "--side-panel/" + key
  match panel_own.was.get(key) {
    Some(was) if was != open && panel_own.asked.get() == key => {
      panel_own.asked.set("")
      // (in and out on a Move as long as it is wide)
      c.move_state([("side-panel", [name])])
    }
    _ => ()
  }
  // (each page's own: a panel beside one page and beside another, each as it was last built)
  if panel_own.was.get(key) != Some(open) {
    panel_own.was[key] = open
  }
  // its column (the panel) as wide as it has got
  let col = c.moved(name, if open { whole } else { 0.0 })
  if col <= 0.0 {
    if !open && side_leaving(key) is Some(_) {
      panel_own.leaving.set(None)
    }
    // (the frame it sets off on, its column not open yet: the page on its way from this frame, as on those after it,
    // not from whichever is drawn next)
    if open && !over && whole > 0.0 {
      let (way, to, ends) = (@sfbase.page_way.id, @sfbase.page_way.to, @sfbase.page_way.ends)
      @sfbase.page_way_said(
        way + "/" + name + "/" + open.to_string(),
        (if way != "" { to } else { c.width }) - whole,
        ends=dmax(if way != "" { ends } else { 0.0 }, c.moved_ends(name).unwrap_or(c.moment())),
      )
      page()
      @sfbase.page_way_said(way, to, ends~)
      return
    }
    page()
    return
  }
  if over {
    c.box(style=panel_row, fn() {
      c.box(style=panel_page_whole, fn() { page() }) |> ignore
      c.box(style=side_over_box.then(@ui.style(w=Fixed(whole))), right=0.0, top=0.0, bottom=0.0, tx=whole - col, fn() {
        c.sized(whole, c.height, panel)
      })
      |> ignore
    })
    |> ignore
    return
  }
  let left = c.width - col
  c.box(style=panel_row, fn() {
    // (the page on its way as the panel slides, or as what holds it goes: as wide as that leaves it beside the panel)
    let (way, to, ends) = (@sfbase.page_way.id, @sfbase.page_way.to, @sfbase.page_way.ends)
    let target = if open { whole } else { 0.0 }
    let sliding = col != target
    if sliding || way != "" {
      @sfbase.page_way_said(
        way + "/" + name + "/" + open.to_string(),
        (if way != "" { to } else { c.width }) - target,
        ends=dmax(if way != "" { ends } else { 0.0 }, c.moved_ends(name).unwrap_or(c.moment())),
      )
    }
    c.box(style=@ui.style(w=Fixed(left), h=Full), fn() { c.sized(left, c.height, page) }) |> ignore
    @sfbase.page_way_said(way, to, ends~)
    // (cut to its column only while it slides: at rest what it puts past its left edge, its edge's handle half over
    // the page, shows whole, as the web's sidePanel cuts nothing)
    c.box(style=@ui.style(w=Fixed(col), h=Full, clip=col < whole), fn() {
      c.box(style=@ui.style(w=Fixed(whole), h=Full), fn() { c.sized(whole, c.height, panel) }) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Chat `r`'s page (`chat`) in workspace `w`, its side panel the tree's beside it (side_panel_node; on the tape a panel
/// of its own, tape_side): as the panel's column slides, the page on its way to the width it leaves the page, there as
/// the slide ends: built again in the first frame at or past its end (Ctx::shows_until), whether or not the page's room
/// changes then. (A frame drawn just short of the end has the column as wide as it comes to be already; at 24 frames a
/// second, in a window wide enough for the list to be held at its width on the way (sfpages' laid_w), the next kept the
/// page as on its way, parting from it built anew: view_beside_wbtest, wide_panel_wbtest.)
pub fn with_side(c : @ui.Ctx, src : Source, w : Workspace, r : ChatRef, chat : () -> Unit) -> Unit {
  if @sf.in_pane() {
    chat()
    return
  }
  let key = chat_key(r)
  let (id, to, ends) = (@sfbase.page_way.id, @sfbase.page_way.to, @sfbase.page_way.ends)
  let open = side_now(src, r).0.length() > 0
  let way_opt = panel_own.goes.get(key)
  let way_goes = match way_opt {
    Some(way) => way.goes_at(c.moment())
    None => false
  }
  if !way_goes && !(id != "" && open) {
    chat()
    return
  }
  let pane = if id != "" {
    to
  } else {
    let ww = c.window_size().0
    ww - fold_target(src, w, ww).1.col
  }
  if pane < side_both_least {
    chat()
    return
  }
  let (side_to, side_ends, side_tag) = match way_opt {
    Some(way) if way_goes => {
      c.shows_until(way.ends_at())
      (way.target(), way.ends_at(), (way.target() > 0.0).to_string())
    }
    _ => (side_width(pane), 0.0, "true")
  }
  @sfbase.page_way_said(
    id + "/--side-panel/" + key + "/" + side_tag,
    pane - side_to,
    ends=dmax(if id != "" { ends } else { 0.0 }, side_ends),
  )
  chat()
  @sfbase.page_way_said(id, to, ends~)
}

///|
/// Whose side panel is open (what the frame puts beside the page on the tape): a chat's, or workspace `ws`'s new
/// chat's (its Station 文件, kept by the same `chatTabs`, by `new:<ws>`).
#derive(Eq)
pub(all) enum SideOf {
  ChatSide(ChatRef)
  NewSide(String)
}

///|
/// The key its panel is kept by (chatTabs).
pub fn SideOf::key(self : SideOf) -> String {
  match self {
    ChatSide(r) => chat_key(r)
    NewSide(ws) => "new:" + ws
  }
}

///|
/// Whose side panel is open on page `p` in workspace `w`: a chat's (or an agent's history asked as a page: its
/// chat's), as its view has it; the new chat's, its 文件 open where the stations lend their files; None with none open.
pub fn side_open_for(src : Source, w : Workspace, p : Page) -> SideOf? {
  match p {
    Chat(r) | History(r, _, _) => if side_now(src, r).0.length() > 0 { Some(ChatSide(r)) } else { None }
    NewChat => if new_files_open(src, w.id) && new_drive_station(src, w) is Some(_) { Some(NewSide(w.id)) } else { None }
    _ => None
  }
}

///|
/// The side panel `side` on the tape, a panel of its own beside the page's, as an old view: a new chat's Station 文件;
/// its edge not dragged (its width the tape's: frame.mbt tape_one_beside). A chat's is the tree's (tape_side_node), its
/// bar and what it shows, an old view of it hosted there under the bar (side_panel).
pub fn tape_side(c : @ui.Ctx, src : Source, w : Workspace, side : SideOf) -> Unit {
  guard side is NewSide(_) else { return }
  side_on_tape.val = true
  match new_drive_station(src, w) {
    Some(address) => new_files_panel(c, src, w, address)
    None => ()
  }
  side_on_tape.val = false
}

///|
/// What the panel (sidePanel) shows under its bar (the tree's: side_bar_node) of every tab the window's tree does not
/// show (panel_node.mbt side_node_tab: an agent's history, a file in the viewer, a Farview tab, 任务, agent 往来,
/// 图片、文件和链接, 文件, a station's 文件 and its page are its: a station's screen is left), an old view; what in front
/// has a bar of its own (side_bars) that bar, the panel's none over it. Its edge is the tree's (side_panel_node's).
fn side_panel(c : @ui.Ctx, src : Source, _w : Workspace, r : ChatRef, tabs : Array[String], front : String) -> Unit {
  c.box(style=side_panel_style, fn() {
    let (_, screen_alone, _) = side_bars(c, tabs, front)
    c.box(style=side_pane, fn() {
      station_tab_pane(c, src, r, front, own_bar=if screen_alone { Some(side_bar_tape()) } else { None }) |> ignore
      // (an agent's history, a web service, a visualization, 任务, agent 往来, 图片、文件和链接, 文件, a station's 文件
      // and its page: the tree's, panel_node.mbt)
    })
    |> ignore
  })
  |> ignore
}

///|
/// How the panel showing `tabs` (`front` in front) is headed: a panel of its own on the tape showing one tab, that tab
/// its title, the panel's close its only ×; the station's screen alone on its side, its tools a rail with no name of
/// their own (the panel's row names it); and whether what is in front has a bar of its own (a service's alone: its
/// address names it; the screen's), that bar the panel's, its × at its end, no row of the panel's over it (the user,
/// 2026-10-28: two rows there too much). The tree's bar asks the same (side_own_bar_node).
fn side_bars(c : @ui.Ctx, tabs : Array[String], front : String) -> (Bool, Bool, Bool) {
  let alone = side_on_tape.val && tabs.length() == 1
  let (ww, wh) = c.window_size()
  let screen_alone = screen_tab_alone(tabs) && !column_short.get() && ww <= wh
  (alone, screen_alone, (alone && tab_service(front) is Some(_)) || screen_alone)
}

///|
/// What a tab is called and how its close is said: an agent's by its label, a web service's by its name, a
/// visualization's by its file's name, 任务's, 文件's, agent 往来's by theirs.
fn side_tab_names(src : Source, r : ChatRef, v : ChatView?, tab : String) -> (String, String) {
  match station_tab_name(src, tab) {
    Some(label) => return (label, @sf.t("web-pages.chat.close", args=[("name", label)]))
    None => ()
  }
  // a file in the viewer: a `.mbui` / `.wasm` mini-program by its resolved app title, else by its file's name
  match @sfbase.view_tab_file(tab) {
    Some(f) => {
      let label = if @sfbase.is_mbui_viz(f.file.name) {
        @sfbase.tab_mbui_meta(src, tabs_key(r), tab, f, r.station).0
      } else {
        f.file.name
      }
      return (label, @sf.t("web-pages.chat.close", args=[("name", label)]))
    }
    None => ()
  }
  let agent = v.bind(fn(v) { v.agents.iter().find_first(fn(a) { a.key == tab }) })
  let service = match tab_service(tab) {
    Some(job) => Some(job_now(src, r.station, job).0)
    None => None
  }
  let file = tab_file(tab)
  let label = match (agent, service, file) {
    (Some(a), _, _) => a.who
    (_, Some(j), _) => if text(j, "name") == "" { svc("android-chat.preview.service") } else { text(j, "name") }
    (_, _, Some((_, _, name))) => name
    _ =>
      if tab == "jobs" {
        @sf.t("web-pages.chat.jobs")
      } else if tab == "files" {
        @sf.t("web-pages.chat.files")
      } else if tab == "things" {
        @sf.t("web-main.things.title")
      } else {
        @sf.t("web-main.letters.title")
      }
  }
  let closing = match (agent, service, file) {
    (Some(_), _, _) | (_, Some(_), _) | (_, _, Some(_)) => @sf.t("web-pages.chat.close", args=[("name", label)])
    _ =>
      if tab == "jobs" {
        @sf.t("web-pages.chat.closeJobs")
      } else if tab == "files" {
        @sf.t("web-pages.chat.closeFiles")
      } else if tab == "things" {
        @sf.t("web-main.things.close")
      } else {
        @sf.t("web-main.letters.close")
      }
  }
  (label, closing)
}

///|
/// The title's row: grown into the bar, its mark over what the tab shows under it (16 more in), its name 8 after it.
// kept across runs: a value (no field of it changes)
let side_title_row : @ui.Style = @ui.style(w=@sf.grow).then(@ui.css("row pl=S4 gap=S2 align=ACenter"))

///|
/// The title's words: as the page's bar's title (chat_title_words).
// kept across runs: a value (no field of it changes)
let side_title_words : @ui.TextStyle = @ui.text_style(size=Body, weight=Semibold, color=Fg, leading=L6, wrap=false, w=Cut)

///|
/// A bar's icon button's side (@sf.icon_button, round: 32 on either hand, @sf.bar_key_side): a circle, so in a panel's
/// corner it stands where it is concentric.
fn bar_button_side() -> Double {
  @sf.bar_key_side
}
