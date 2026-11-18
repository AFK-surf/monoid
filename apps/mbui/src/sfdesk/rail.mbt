// The rail at the wide frame's left, in one block with the sidebar (frame.mbt
// dock): its top row (in a window with its buttons in the app's top row, their row, dragging the window), the places
// the person chose on this device as the core has them (prefs `railView`: which, their words and kinds, their order;
// the rail only draws them), at its foot every workspace to switch to (each with what waits in it; a ＋ over them for
// making one, another account, invitations) and the settings. It is changed where it is: its menu (a right click) goes
// to the places left out and takes one out, its 自定义侧边条 has the places dragged up and down, taken out with their −
// and added from a panel beside it by kind. And the sidebar's edge (SidebarEdge), dragged for its width, pressed to
// fold it or open it again.

///|
/// The rail as the core says it is drawn (prefs `railView`: core-ts rail.ts railView): every place, its words and kind,
/// the kinds the panel that adds them groups them by, the default, the rail of a workspace with none of its own (`all`)
/// and each one's own (`by`).
fn rail_view(src : Source) -> Json? {
  field(src.topic("prefs", {}).get().value, "railView")
}

///|
/// Workspace `ws`'s rail (railView's `by` its own, else `all`): its places in order (`items`), those left out
/// (`hidden`), whether it is other than the default (`changed`).
fn rail_of(src : Source, ws : String) -> Json? {
  let v = rail_view(src)
  match field(field(v, "by"), ws) {
    Some(Object(_)) as own => own
    _ => field(v, "all")
  }
}

///|
/// A list of words (a JSON array of strings).
fn words_in(a : Array[Json]) -> Array[String] {
  a.filter_map(fn(x) {
    match x {
      String(s) => Some(s)
      _ => None
    }
  })
}

///|
/// The rail's places in workspace `ws`, in their order: the core's, and 看板 where it stands while 实验性功能's
/// 对话列表看板视图 is on (board_rail_at).
pub fn rail_items(src : Source, ws : String) -> Array[String] {
  let places = words_in(items(rail_of(src, ws), "items"))
  match board_rail_at(src, ws, places) {
    Some(at) => places.insert(at, "board")
    None => ()
  }
  places
}

///|
/// Every place the rail can show, in the order its settings list them (railView's `places`), 看板 after 对话 while
/// 实验性功能's 对话列表看板视图 is on.
fn rail_places(src : Source) -> Array[String] {
  let places = items(rail_view(src), "places").map(fn(p) { text(Some(p), "id") })
  if @sfbase.board_feature.get() {
    match places.search_by(fn(p) { p == "chats" }) {
      Some(i) => places.insert(i + 1, "board")
      None => places.insert(0, "board")
    }
  }
  places
}

///|
/// The prefs' key where 看板's place in workspace `ws`'s rail is kept (`sidebars`, as the sidebars' are by workspace:
/// the core's rails know no 看板 while it is an experimental feature): its index among the places, or "closed" where
/// it was taken out; none, after 对话.
fn board_rail_key(ws : String) -> String {
  ws + "\nboardRail"
}

///|
/// Where 看板 stands among workspace `ws`'s rail's other places `places` (the core's): as kept (board_rail_key), else
/// after 对话 (board_rail_default); None where it was taken out, or 实验性功能's 对话列表看板视图 is off.
fn board_rail_at(src : Source, ws : String, places : Array[String]) -> Int? {
  guard @sfbase.board_feature.get() else { return None }
  match text(field(src.topic("prefs", {}).get().value, "sidebars"), board_rail_key(ws)) {
    "closed" => None
    said =>
      match whole_of(said) {
        Some(n) => Some(if n < 0 { 0 } else if n > places.length() { places.length() } else { n })
        None => Some(board_rail_default(places))
      }
  }
}

///|
/// Where 看板 stands among the rail's other places `places` where nothing else is said: after 对话, else after the
/// first of the chats' lists the rail has (我参与的 in 对话's place: the board is one of the chats' views), else first.
fn board_rail_default(places : Array[String]) -> Int {
  let list = fn(p) { p is ("chats" | "mine" | "watching" | "hidden" | "archive") }
  match places.search_by(fn(p) { p == "chats" }) {
    Some(i) => i + 1
    None =>
      match places.search_by(list) {
        Some(i) => i + 1
        None => 0
      }
  }
}

///|
/// Whether workspace `ws`'s 看板 stands elsewhere than as the rail starts (moved, taken out): the rail changed.
fn board_rail_changed(src : Source, ws : String) -> Bool {
  @sfbase.board_feature.get() && text(field(src.topic("prefs", {}).get().value, "sidebars"), board_rail_key(ws)) != ""
}

///|
/// A place's words (its tip, its menu's row): as the core says them (看板 the board's own).
fn rail_label(src : Source, place : String) -> String {
  if place == "board" {
    return @sf.t("web-main.board.board")
  }
  match items(rail_view(src), "places").search_by(fn(p) { text(Some(p), "id") == place }) {
    Some(i) => text(Some(items(rail_view(src), "places")[i]), "label")
    None => place
  }
}

///|
/// Whether the place has no sidebar: its page is the pane's whole (连接).
pub fn place_bare(place : String) -> Bool {
  place == "connects" || place == "usage"
}

///|
/// Whether the place is drawn with no sidebar of its own now: place_bare's, and 看板 off the tape (大屏: the sidebar
/// closed to its bar, the board the pane's whole; on the tape the board is the page's panel's, the chats' list beside
/// it as ever).
pub fn place_bare_now(place : String) -> Bool {
  place_bare(place) || (place == "board" && !wide.tape.get())
}

///|
/// The place lit in the rail: what the stack's root is, settings while a settings page is open.
pub fn lit_place() -> String {
  let pages = app.nav.pages()
  for p in pages {
    match p {
      Settings | Setting(_) => return "settings"
      _ => ()
    }
  }
  // the place of the page nearest the top that has one
  let mut k = pages.length() - 1
  while k >= 0 {
    match pages[k] {
      Files | Drive(_) | DriveRead(_) | DrivePlay(_) => return "files"
      Place(p) => return p
      // (Home as the board: 看板's, board.mbt)
      Home if k == 0 && board_bare() => return "board"
      // 已归档: one of the chats' lists
      Home | Chat(_) | NewChat | Archived => return "chats"
      _ => ()
    }
    k = k - 1
  }
  "chats"
}

///|
/// The places the rail shows: its own, and a place left out of it but in view at their foot while it is (not while the
/// rail is changed).
fn rail_shown(src : Source, w : Workspace) -> Array[String] {
  rail_shown_entries(src, w).map(fn(e) { e.1 })
}

///|
/// rail_shown's places, each said whether it is the one in view added at their foot (true) or one of the rail's own: a
/// place taken out of the rail while it is in view is another entry at their foot, not the same moved there (Rail.tsx's
/// `added-` key: not moved or taken out, it is not kept), so the rail closes its room where it was and opens it there.
fn rail_shown_entries(src : Source, w : Workspace) -> Array[(Bool, String)] {
  let places = rail_items(src, w.id)
  let in_view = rail_in_view(src, w)
  let shown = places.map(fn(p) { (false, p) })
  if in_view != "" && !places.contains(in_view) && !wide.editing.get() {
    shown.push((true, in_view))
  }
  shown
}

///|
/// Whether `place` is lit in the rail now: the lit place's; a list's while its list is the one shown
/// (我参与的, 监控中 by the filter when they are in the rail, else 对话; 已归档 while the archive is open: shownList).
fn rail_lit(src : Source, w : Workspace, place : String) -> Bool {
  let lit = lit_place()
  match place {
    "chats" | "mine" | "watching" | "hidden" | "archive" => {
      let list = list_place(list_mode(src, w))
      let shown_list = if rail_shown(src, w).contains(list) { list } else { "chats" }
      lit == "chats" && shown_list == place
    }
    _ => lit == place
  }
}

///|
/// The place whose sidebar the block holds (what it draws, the width of its group), the archive's list its own
/// ("archive", list_place's): the lit place's; in a place with none of its own (place_bare), the one it had, which the
/// block closes holding (the web's WorkspaceShell `kept`), not the chats' list it would fall to: nothing opens the
/// sidebar there. The frame keeps it as it is built (wide.side_place).
pub fn side_place() -> String {
  let lit = lit_place()
  if place_bare_now(lit) {
    wide.side_place
  } else if lit == "chats" && app.nav.pages().contains(Archived) {
    "archive"
  } else if lit == "board" {
    // (the board on the tape: the chats' list beside it)
    "chats"
  } else {
    lit
  }
}

///|
/// Which of the lists is shown (the sidebar's mode): 全部 0, 我参与的 1, 监控中 2 (the
/// filter), 已归档 3.
pub fn list_mode(src : Source, w : Workspace) -> Int {
  match side_place() {
    "archive" => 4
    _ =>
      match filter_of(src, w.id) {
        "mine" => 1
        "watching" => 2
        "hidden" => 3
        _ => 0
      }
  }
}

///|
/// The rail's place of the list shown (Rail.tsx listed(mode)).
fn list_place(mode : Int) -> String {
  match mode {
    1 => "mine"
    2 => "watching"
    3 => "hidden"
    4 => "archive"
    _ => "chats"
  }
}

///|
/// The rail's top row's height (in a panel of the tape its first place as far under its top as its places are in from
/// its side; closed, none).
fn rail_top_h(bar : Bool) -> Double {
  if bar {
    0.0
  } else if @ui.window_keys_left() && wide.tape.get() {
    // (its first place's middle on the line of the sidebar's first row beside it, under the window's buttons: worked
    // out as that row's is, not read back from the frame's)
    tape_brand_under_buttons() + band_new_top + band_row_h() / 2.0 - rail_item_side / 2.0
  } else if @ui.window_keys_left() {
    dmax(rail_top_inset + rail_gap, @ui.window_points_to_content(side_top_inset))
  } else if wide.tape.get() {
    // (and its first place's middle on the line of the sidebar's first row beside it, 新建对话's: pengxiao, 2026-10-25)
    dmax(@sf.rail_in_tape(), tape_first_row_mid() - rail_item_side / 2.0)
  } else {
    rail_top_corner()
  }
}

///|
/// The open rail's top row where nothing stands over its first place (no window buttons at its left, off the tape): as
/// tall as its places are in from the window's side (rail_window_in), so its first place's ground stands as far under
/// the window's top as it is in from its side, concentric with the window's corner (the user, 2026-11-09: 新建对话往上挪一点).
fn rail_top_corner() -> Double {
  rail_window_in()
}

///|
/// The closed bar's padding round its places (rail_closed's p=S0_5).
let rail_closed_pad : Double = 2.0

///|
/// How far in from the closed bar's edges its places' grounds stand: its 2 (rail_closed), a place's 38 less its 30.
let rail_closed_ground_in : Double = 2.0 + rail_ground_in

///|
/// How far in from a place's edges its ground stands (its 38 less its 30).
let rail_ground_in : Double = (rail_item_side - rail_sq_side) / 2.0

///|
/// How wide the rail is drawn in the block (its look's width, its padding in it), what the sidebar stands beside: where
/// the block's move has got (`moving`: pane_view.mbt's FoldLook, as rail draws it then); else closed, the bar's; on the
/// tape, its panel's (rail_open_tape); open, as far in from the window's corner as its places stand (rail_window_in).
fn rail_box_w(bar : Bool, moving : FoldLook?) -> Double {
  match moving {
    Some(f) => f.rail_w
    None =>
      if bar {
        rail_closed_w
      } else if wide.tape.get() {
        rail_shown_w + rail_tape_more()
      } else {
        rail_shown_w + rail_window_in() - rail_in_px
      }
  }
}

///|
/// The rail's inset open (rail_in: 8).
let rail_in_px : Double = 8.0

///|
/// The open rail's place in the window's corner: its ground follows that corner where the system's corner and the
/// theme's ranges allow it. When the ground is round, its centre follows the system's circular corner instead.
fn rail_window_in() -> Double {
  let window : @ui.CornerOf = Window
  let corner = window.radius(@ui.corner_roots())
  let base = closed_bar_in + rail_closed_ground_in
  if corner <= base {
    return base - rail_ground_in
  }
  let (at, radius) = @sf.box_fit(corner, base, 0.0)
  let at = if corner > 0.0 && radius >= rail_sq_side / 2.0 - 0.5 {
    corner - rail_sq_side / 2.0
  } else {
    at
  }
  at - rail_ground_in
}

///|
/// How much more of the rail shows on the tape (its places further in: rail_open_tape), the sidebar as much narrower.
fn rail_tape_more() -> Double {
  @sf.rail_in_tape() - rail_in_px
}

///|
/// What of the rail shows beside the sidebar open: its 56 less the 8 the sidebar reaches over.
let rail_shown_w : Double = 48.0

///|
// kept across runs: a value (no field of it changes)
let rail_places_col : @ui.Style = @ui.css("gap=S1_5 align=AStart")

///|
/// A place lit in the closed bar: the words' colour at 12% (Rail.css.ts item, closed: color-mix(text 12%)).
let lit_in_bar : Double = 0.12

///|
/// The rail's places 6 apart; its top row 41 under the window's buttons (else rail_top_corner).
let rail_gap : Double = 6.0

///|
let rail_top_inset : Double = 41.0

///|
/// A place's icon (20).
let rail_icon_size : Double = 20.0

///|
// kept across runs: a value (no field of it changes)
let rail_item : @ui.Style = @ui.style(w=Fixed(rail_item_side), h=Fixed(rail_item_side), align=ACenter, justify=JCenter)

///|
let rail_item_side : Double = 38.0

///|
// kept across runs: a value (no field of it changes)
let rail_sq : @ui.Style = @ui.style(w=Fixed(rail_sq_side), h=Fixed(rail_sq_side), align=ACenter, justify=JCenter)

///|
let rail_sq_side : Double = 30.0

///|
/// The room a mark hangs in, its middle the corner's: as large as the largest with its disc (a ring 10 across, 2 round
/// it), each centred in it.
let rail_hung_side : Double = 14.0

///|
// kept across runs: a value (no field of it changes)
let rail_hung_room : @ui.Style = @ui.style(
  w=Fixed(rail_hung_side),
  h=Fixed(rail_hung_side),
  align=ACenter,
  justify=JCenter,
)

///|
// kept across runs: a value (no field of it changes)
let rail_hung_ring : @ui.Style = @ui.css("p=S0_5 radius=Full")

///|
let mark_folded_from : Double = 0.4

///|
/// The sidebar's ground where it is a panel of its own: the closed bar's, floating over the page (closed_ground); on
/// the tape, a panel beside the page's as it is, the page's ground, which a phone's lists and pages share (the user,
/// 2026-10-25: the medium screen's grounds the phone's, no other colours).
pub fn apart_ground() -> Int64 {
  if wide.tape.get() {
    @sf.theme().p.bg
  } else {
    closed_ground()
  }
}

///|
/// The closed bar's ground (a floating panel's: the canvas, raised in the dark).
pub fn closed_ground() -> Int64 {
  let t = @sf.theme()
  if t.dark {
    t.p.raised
  } else {
    t.p.canvas
  }
}

///|
/// Whether place `place` has a card as the pointer rests on it (the core's `railCard`: 对话, 用量; 2026-10-26 用户「stations
/// 和 profiles tab 的 hover 卡片去掉吧」); the others keep their tip.
fn rail_carded(place : String) -> Bool {
  place == "chats" || place == "usage"
}

///|
/// Back to the stack's root as another workspace comes into view: what is over the pages put down, the menu closed.
fn desk_home() -> Unit {
  app.menu = false
  while app.nav.depth() > 1 {
    if !app.nav.pop() {
      break
    }
  }
}

///|
/// A place gone to, from the rail or its menu: 待处理 its panel; a list of chats
/// its list in the sidebar, the chat last open beside it; 已归档 the archive; the others their page.
pub fn rail_go(c : @ui.Ctx, src : Source, w : Workspace, place : String) -> Unit {
  rail_go_told(src, w, place, fn(key, f) { c.tell(key, f) })
}

///|
/// rail_go's, what it keeps in the prefs done by `tell` (an old view's build: once, whichever build asked; a node's
/// press: at once).
fn rail_go_told(src : Source, w : Workspace, place : String, tell : (String, () -> Unit) -> Unit) -> Unit {
  match place {
    "attention" => {
      attention_set(!wide.attention_open.get())
    }
    "board" => board_go(src, w)
    "chats" | "mine" | "watching" | "hidden" => {
      // (from the board: the list again, the chat open as 看板 was gone to put back beside it: board_kept_chat)
      let from_board = @sfbase.board_on_of(src, w.id)
      if from_board {
        @sfbase.board_set(src, false)
      }
      // its list in the sidebar: 对话 all of them, the others theirs
      let f = if place == "chats" { "all" } else { place }
      if filter_of(src, w.id) != f {
        app.filters[w.id] = f
        // (kept once, whichever build asked: Ctx::tell)
        tell("rail/list-filter", fn() {
          (src.call)("prefs.set", Json::object({ "listFilter": Json::object(Map::from_array([(w.id, Json::string(f))])) }), @sfbase.answer_unread)
        })
      }
      // the chats again: the chat last open stays open beside the list
      if from_board && board_back_to_chat(w) {
        ()
      } else if app.nav.pages()[0] == Home && lit_place() == "chats" && !app.nav.pages().contains(Archived) {
        ()
      } else {
        @sfbase.go_place("chats") |> ignore
        wide.landed.set("")
      }
    }
    "archive" => {
      @sfbase.history_push()
      archive_side.landed = false
      app.nav.replace_above(1, [Archived])
    }
    p => @sfbase.go_place(p) |> ignore
  }
}

///|
/// The rail kept (`prefs.set {rails: {workspace: [...]}}`, on this device); while 实验性功能's 对话列表看板视图 is on, 看板's
/// place apart (board_rail_key: where it stands among the rest, "closed" where it is not in `items`, nothing where it
/// stands where it starts), in the same change.
fn rail_keep(src : Source, ws : String, items : Array[String]) -> Unit {
  let rest = items.filter(fn(i) { i != "board" })
  let said : Map[String, Json] = { "rails": Json::object(Map::from_array([(ws, Json::array(rest.map(fn(i) { Json::string(i) })))])) }
  if @sfbase.board_feature.get() {
    let at = match items.search_by(fn(i) { i == "board" }) {
      Some(i) if i == board_rail_default(rest) => Json::null()
      Some(i) => Json::string(i.to_string())
      None => Json::string("closed")
    }
    said["sidebars"] = Json::object(Map::from_array([(board_rail_key(ws), at)]))
  }
  (src.call)("prefs.set", Json::object(said), @sfbase.answer_unread)
}

///|
/// The rail as it starts (its menu's 侧边条恢复默认): the core's default, 看板 after 对话 again.
fn rail_reset(src : Source, ws : String) -> Unit {
  let said : Map[String, Json] = {
    "rails": Json::object(Map::from_array([(ws, Json::array(items(rail_view(src), "default")))])),
  }
  if @sfbase.board_feature.get() {
    said["sidebars"] = Json::object(Map::from_array([(board_rail_key(ws), Json::null())]))
  }
  (src.call)("prefs.set", Json::object(said), @sfbase.answer_unread)
}

///|
/// The place in view that is left out of the rail, if one is: a list shown (我参与的, 监控中, the archive; the chats'
/// when 对话 is out), the files, a place picked from the rail's menu (setExtra); "" none.
fn rail_in_view(src : Source, w : Workspace) -> String {
  let lit = lit_place()
  let in_view = if lit == "chats" {
    list_place(list_mode(src, w))
  } else if rail_places(src).contains(lit) {
    lit
  } else {
    ""
  }
  if rail_items(src, w.id).contains(in_view) {
    ""
  } else {
    in_view
  }
}

///|
/// The rail's menu 8 past its place, and no higher than the window's buttons' row.
let rail_menu_off : Double = 8.0

///|
let rail_menu_clear : Double = 52.0


///|
/// A rail's place to the next (its 38 and the 6 between), and how far a press goes before it is a drag.
pub let rail_pitch : Double = 44.0

///|
let rail_slop : Double = 4.0

///|
/// A place's icon in the rail (the stations' is their glyph, rail_place).
fn rail_icon(place : String) -> String {
  match place {
    "attention" => "bell"
    "chats" => "chats"
    "board" => "view-columns"
    "mine" => "user"
    "watching" => "watch"
    "hidden" => "eye-off"
    "archive" => "archive"
    "files" => "folder"
    "remote" => "monitor"
    "profiles" => "quota"
    "connects" => "plug"
    "usage" => "chart"
    _ => "server"
  }
}

///|
/// Settings from the rail's gear (or ⌘,): their list, where the shell opens it (sfapp's open_where: beside it on a
/// medium or large screen the page of its first row, settings_landing; on a small one the list's own page).
pub fn open_settings() -> Unit {
  app.menu = false
  open_page(Settings)
}

///|
/// Settings at one of its pages, chosen (快捷键 from the shortcuts' dialog, 通知设置 from the bell's, ⌘K's): the sidebar
/// its list, the page shown (on the tape beside the sidebar in use, show_page), as a row of their list opens one.
pub fn open_settings_at(route : @settings.Route) -> Unit {
  settings_beside(route)
  show_page()
}

///|
/// Settings come to with `route`'s page beside their list (the gear's: the list in use on the tape, the page at its
/// side).
pub fn settings_beside(route : @settings.Route) -> Unit {
  @sfbase.history_push()
  app.menu = false
  app.nav.replace_above(1, [Setting(route)])
}

///|
/// The adder's panel: 248 wide, 8 past the rail.
let rail_adder_w : Double = 248.0

///|
let rail_adder_off : Double = 8.0

///|
/// The − just inside the place's top left corner, so it stays within the scrolling rail.
let rail_remove_in : Double = 1.0

///|
let rail_remove_icon : Double = 12.0

///|
/// A place's dashed outline while the rail is changed: 1.5 wide from a pixel in to half a pixel out of its 38 (its
/// middle 0.25 in: 37.5 across, its corner 12's less as much), drawn from 0.75 further out.
let rail_dash_line : Double = 1.5

///|
let rail_dash_side : Double = 37.5

///|
let rail_dash_r : Double = 11.75

///|
let rail_dash_at : Double = -0.5

///|
/// The −: 18 round in the words' colour, the rail's ground round it.
// kept across runs: a value (no field of it changes)
let rail_remove : @ui.Style = @ui.css("w=S4_5 h=S4_5 align=ACenter justify=JCenter bg=Fg radius=Full")

///|
/// The adder's head and its kinds 8 apart (gap 8).
// kept across runs: a value (no field of it changes)
let adder_body : @ui.Style = @ui.css("w=Full gap=S2")

///|
/// The rail in the closed bar (closed): as narrow as the bar, its places 2 from its every edge.
pub let rail_closed_w : Double = 42.0

///|
/// What the stations' place says on hover (RailStations): what is wrong with them, else what the core waits on, else
/// how many and who works.
/// Worked out once for each change of what it reads, and what reads it told only where it comes out otherwise.
pub fn rail_stations_label(src : Source, ws : String) -> String {
  rail_stations_kept.read(src, ws, fn(_) { rail_stations_label_now(src, ws) }, same=fn(a, b) { a == b })
}

///|
/// What the stations' place says on hover by workspace (rail_stations_label's), by the source read.
// kept across runs: what it keeps is let go of by a run anew and by reset (sfbase's derived.mbt)
let rail_stations_kept : @sfbase.Kept[String] = @sfbase.Kept::new()

///|
/// What the stations' place says on hover as the topics say it now (rail_stations_label's getter).
fn rail_stations_label_now(src : Source, ws : String) -> String {
  let chats = @sfbase.chats_topic(src, ws).value
  let status = src.topic("status", { "workspace": Json::string(ws) }).get().value
  let trouble = text(field(chats, "trouble"), "text")
  let waiting = if text(status, "state") != "" { text(status, "text") } else { "" }
  let summary = text(field(chats, "glyph"), "summary")
  if trouble != "" {
    trouble
  } else if waiting != "" {
    waiting
  } else if summary != "" {
    summary
  } else {
    "Station"
  }
}
