// A chat's 文件 tab: the files of the
// workspace's stations beside a chat, to put into what is being written. That is what it is for, on every screen: a
// few files picked (a press picks a file, goes into a folder; the folder shown picked as a whole from the top of its
// list), then 添加 n at its foot puts them into the message; what a file is, seen by its row's menu (打开) or the
// preview under the list; the files themselves kept on the files' page. It starts at the chat's station's home for one who browses every folder,
// else at its one folder pinned, else at the places (个人收藏, each station's home, disks and pinned folders); the way up is a
// trail of folders over the list, the first of them the places. A list of names and sizes, the folder as a whole at
// its top: picking needs no other way of showing (the files' page has its columns and its tree); its preview under the
// list (`driveViews.tabPreview`). A row's menu
// (a right click): 添加到消息, 复制路径, 下载, pin; a row dragged onto the chat is put into the message (the composer
// takes it: tab_take_drop). A folder is gone into; what reads, plays or previews opens over the chat. Where it
// is is kept by workspace while the app runs, as the web's tab is.
// A chat's side panel makes it once as nodes (drive_tab_node.mbt), its 文件 and a station's alike; what follows here,
// the tab's old view (files_tab, drive_tab_rows.mbt), is the new chat's panel's alone, an old view itself, till its page
// is made as nodes. Where the tab is, what is carried and let go off it are both's.

///|
/// The tab: whether it is being built, where it is by workspace (None: the places; none kept: where it starts), what
/// was asked put into a chat's message (the chat, what), and a row let go off it not taken yet (what, where).
priv struct FChatTab {
  mut building : Bool
  places : Map[String, DriveAt?]
  mut scope : String
  mut let_go : (Dragged, Double, Double)?
  mut chat : String
  /// what is picked to go into the chat's message, in the order picked
  picked : Array[Dragged]
}

///|
// kept across runs: the tab's state (tab_reset puts it back)
let ftab : FChatTab = {
  building: false,
  places: {},
  scope: "",
  let_go: None,
  chat: "",
  picked: [],
}

///|
/// Where the tab is, by workspace (as ftab.places: None none kept, Some(None) the places), each as a signal of its own
/// made as it is first read: told as that workspace's changes (ftab_put), so what reads it (ftab_place_of) is built
/// again then, a part kept as its nodes too, whether it was a press in the tab, the composer's way to a folder or
/// anything else; what reads another workspace's not.
// kept across runs: said again as the tab is put back (tab_reset)
let ftab_places_said : Map[String, @signals.Signal[DriveAt??]] = Map([])

///|
/// The tab of `ws` put at `at` (None: the places).
fn ftab_put(ws : String, at : DriveAt?) -> Unit {
  // (a folder pressed and read meanwhile, browse_switch's: waited for no more, the tab put elsewhere)
  @sfpages.browse_switch_off("tab/" + ftab.chat)
  // (the tab made as nodes browses by its place's scope: drive_tab_node.mbt ntab_browse_of)
  @sfpages.browse_switch_off("tab/" + ws)
  ftab.places[ws] = at
  match ftab_places_said.get(ws) {
    Some(s) => s.set(Some(at))
    None => ()
  }
}

///|
/// Where the tab of `ws` is (None: none kept), read as a signal.
fn ftab_place_of(ws : String) -> DriveAt?? {
  let s = match ftab_places_said.get(ws) {
    Some(s) => s
    None => {
      let s = @signals.signal(ftab.places.get(ws), same=fn(a, b) { a == b })
      ftab_places_said[ws] = s
      s
    }
  }
  s.get()
}

///|
fn tab_reset() -> Unit {
  panel_screen_pages.clear()
  panel_terminal_pages.clear()
  ftab.building = false
  ftab.places.clear()
  ftab_places_said.each(fn(_, s) { s.set(None) })
  ftab.scope = ""
  ftab.let_go = None
  ftab.chat = ""
  ftab.picked.clear()
}

///|
/// The tab into a folder of a station (its root, the path under it).
fn ftab_go(station : String, root : String, path : String) -> Unit {
  ftab_put(ftab.scope, Some({ station, root: Some(root), path }))
}

///|
/// Whether the tab is being built now (a folder gone to from what it draws goes there, not to the files' page).
pub fn tab_building() -> Bool {
  ftab.building
}

///|
/// The tab of the workspace `ws` at `at` (None: the places), as going there in it does.
pub fn tab_place_set(ws : String, at : DriveAt?) -> Unit {
  ftab_put(ws, at)
}

///|
/// Where the tab of `ws` is: None while nothing was chosen there (it starts where the chat's station does), Some(None)
/// at the places.
pub fn tab_place(ws : String) -> DriveAt?? {
  ftab_place_of(ws)
}

///|
/// The tab gone to `at` (what a folder opened from it does).
pub fn tab_go(at : DriveAt) -> Unit {
  ftab_go(at.station, at.root.unwrap_or(""), at.path)
}

///|
/// The way to `abs`: from the home (主目录) when it is under it, else from the top of the disk.
fn ftab_trail(abs : String, home : String) -> Array[(String, String)] {
  let trim = fn(p : String) { if p.length() > 1 && p.has_suffix("/") { p.exact_view(end=p.length() - 1).to_owned() } else { p } }
  let at = trim(abs)
  let h = trim(home)
  let out : Array[(String, String)] = []
  let rest = if h != "" && (at == h || at.has_prefix(h + "/")) {
    out.push((@sf.t("web-pages.drive.home"), h))
    at.exact_view(start=h.length()).to_owned()
  } else {
    out.push(("/", "/"))
    at
  }
  for part in rest.split("/") {
    if part != "" {
      let (_, last) = out[out.length() - 1]
      out.push((part.to_owned(), ftab_child(last, part.to_owned())))
    }
  }
  out
}

///|
/// The trail's chevrons (12).
let ftab_chevron : Double = 12.0

///|
/// Its trail and what is done to the folder (head: 4 over, 8 at its end, 6 under, 12 before).
// kept across runs: a value (no field of it changes)
let ftab_head : @ui.Style = @ui.css("row w=Full pt=S1 pr=S2 pb=S1_5 pl=S3 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let ftab_trail_box : @ui.Style = @ui.style(row=true, w=@sf.grow, gap=SPx, align=ACenter, clip=true)

///|
/// A step of it (3 by 4 in, the option's corner); the folder shown bold in the words' ink.
// kept across runs: a value (no field of it changes)
let ftab_step : @ui.Style = @ui.css("px=S1 py=SPx radius=Md hovered{bg=Hover}")

///|
// kept across runs: a value (no field of it changes)
let ftab_step_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let ftab_step_last : @ui.TextStyle = @ui.text_style(size=Meta, weight=Semibold, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let ftab_actions : @ui.Style = @ui.css("row gap=S1 align=ACenter")

///|
/// The rows, from edge to edge but for a little room (list: 0 by 8, 8 under).
// kept across runs: a value (no field of it changes)
let ftab_list : @ui.Style = @ui.style(w=Full, h=@sf.grow, px=S2, pb=S2, clip=true)

///|
// kept across runs: a value (no field of it changes)
let ftab_note : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full)

///|
/// Why the folder could not be read, and 重试.
// kept across runs: a value (no field of it changes)
let ftab_problem : @ui.Style = @ui.css("w=Full p=S3 gap=S2_5 align=AStart")

///|
/// Where `name` goes in the folder `folder`, as an absolute path.
fn ftab_child(folder : String, name : String) -> String {
  if folder.has_suffix("/") {
    folder + name
  } else {
    folder + "/" + name
  }
}

///|
/// A row's mark (16).
let tab_icon : Double = 16.0

///|
// kept across runs: a value (no field of it changes)
let tab_trouble : @ui.TextStyle = @ui.text_style(size=Meta, color=Danger, wrap=false)

///|
/// 添加 at its foot's end.
// kept across runs: a value (no field of it changes)
let ftab_foot : @ui.Style = @ui.css("row w=Full px=S5 pt=S2 justify=JEnd")

///|
/// 添加's room at its sides and under it, standing alone.
let ftab_side : Double = 20.0

///|
let ftab_under : Double = 16.0
