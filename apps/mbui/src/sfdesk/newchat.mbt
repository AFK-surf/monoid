// A new chat in the pane: the pages' (sfpages new_chat_node) in the wide frame, which adds
// what the frame has around it: the workspace's stations' files beside it, as beside a chat (its 文件 in the chat's
// bar's place, over the page; the side panel sliding in and out; a row of the tab let go over the page going into its
// message), and as it becomes its chat, the files open beside it open beside the chat.

///|
/// What the wide frame gives a new chat made as nodes (sfpages' new_chat_node): no bar (its 文件 is the
/// frame's, over it: chat_bar_wide_node's new_bar_node), nothing under it; a row of the 文件 tab carried over it, let go
/// there: into its message (chat_drop_node); as it
/// becomes its chat, the files open beside it open beside the chat (new_sent). Its 文件 beside it is the tree's
/// (side_panel_node's new_side_node; on the tape a panel of its own, tape_view's tape_new_side_node).
/// `ground`: as node `n` draws it (the pane's; a tape's panel's: tape_page_ground); `width`: the page's, as the frame
/// lays it out; `apart` and `pane`: its composer's, as the chat's in the same place has them (chat_composer_node's);
/// `bar`: what is over its top (a pane's: the window's top row it drags by, page_pane's new_node).
fn new_frame_node(
  src : Source,
  w : Workspace,
  width : () -> Double,
  ground? : (@view.View) -> Int64 = fn(_) { @sf.theme().p.bg },
  apart? : () -> Bool = fn() { false },
  pane? : () -> FixedArray[@ui.CornerOf]? = fn() { None },
  bar? : (@view.View) -> Unit = fn(_) {  },
) -> @sfpages.NewChatNodeFrame {
  {
    core: settings_core(src, w),
    ground,
    width,
    apart,
    pane,
    bar,
    foot: fn() { 0.0 },
    // (what is let go going up to the station its 文件 tab starts on, as the page's own picks say it now)
    over: fn(v, shows) {
      chat_drop_node(v, src, "new:" + w.id, fn() { new_drive_station(src, w).unwrap_or("") }, fn() { None }, shows)
    },
    in_place: false,
    sent: fn(r) { new_sent(src, w, r) },
  }
}

///|
/// The station workspace `w`'s new chat starts on, where the stations lend their files (useStationDrive: as the view
/// has its stations): its 文件 tab is had; None where it is not (blocked, no station, none with a drive).
fn new_drive_station(src : Source, w : Workspace) -> String? {
  let v = src.topic("newChat", @sfpages.new_chat_asked(w.id)).get().value
  let station = field(v, "station")
  let address = text(station, "station")
  let on = station is Some(Object(_)) && text(v, "blocked") == "" && address != ""
  let drive = on &&
    items(v, "stations").iter().any(fn(s) { field(field(Some(s), "overview"), "drive") is Some(Object(_)) })
  if drive {
    Some(address)
  } else {
    None
  }
}

///|
/// The page as it becomes its chat: the chat opening without its agent's history beside it, the
/// files open beside the page open beside the chat.
fn new_sent(src : Source, w : Workspace, r : ChatRef) -> Unit {
  let files = new_files_open(src, w.id)
  side_ask(src, r, "clear", None)
  if files {
    side_ask(src, r, "open", Some("files"))
  }
}

///|
/// Whether the workspace's new chat has its 文件 tab open (what the core keeps for it on this device, the prefs'
/// `chatTabs` by `new:<workspace>`).
fn new_files_open(src : Source, ws : String) -> Bool {
  let kept = field(field(src.topic("prefs", {}).get().value, "chatTabs"), "new:" + ws)
  items(kept, "tabs").contains(Json::string("files"))
}

///|
/// The workspace's new chat's 文件 tab opened or closed, kept by the core on this device (`chat.tabs.*`).
fn new_files_set(src : Source, ws : String, on : Bool) -> Unit {
  let open = new_files_open(src, ws)
  side_changing("new:" + ws, if open { ["files"] } else { [] }, if open { "files" } else { "" }, on)
  let call = if on { "chat.tabs.open" } else { "chat.tabs.close" }
  (src.call)(call, { "chat": Json::string("new:" + ws), "tab": "files" }, @sfbase.answer_unread)
}
