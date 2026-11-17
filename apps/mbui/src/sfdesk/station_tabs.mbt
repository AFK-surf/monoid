// Station destinations beside the current chat. The shell chooses this placement;
// menus and pages still ask to open the same Screen, Drive and Station pages.

///|
fn station_tab_key(kind : String, station : String, screen? : String) -> String {
  let parts = [Json::string(station)]
  match screen { Some(s) => parts.push(Json::string(s)); None => () }
  kind + ":" + Json::array(parts).stringify()
}

///|
fn station_tab(tab : String) -> (String, String, String)? {
  for kind in ["screen", "drive", "station", "adb"] {
    let prefix = kind + ":"
    if tab.has_prefix(prefix) {
      let value = @json.parse(tab[prefix.length():].to_owned()) catch { _ => return None }
      guard value is Array(xs) else { return None }
      guard xs.length() == (if kind == "screen" { 2 } else { 1 }) else { return None }
      guard xs[0] is String(station) && station != "" else { return None }
      if kind == "screen" {
        guard xs[1] is String(screen) else { return None }
        return Some((kind, station, screen))
      }
      return Some((kind, station, ""))
    }
  }
  None
}

///|
fn station_files_scope(r : ChatRef, station : String) -> String {
  tabs_key(r) + "/" + station_tab_key("drive", station)
}

///|
pub fn station_page_beside(src : Source, r : ChatRef, p : Page) -> Bool {
  let tab = match p {
    Screen(at) => {
      let tab = station_tab_key("screen", at.station, screen=at.screen)
      panel_screen_pages[tabs_key(r) + "/" + tab] = at
      tab
    }
    Drive(at) => {
      tab_place_set(station_files_scope(r, at.station), Some(at))
      station_tab_key("drive", at.station)
    }
    Setting(Station(station)) => station_tab_key("station", station)
    // 共享调试 with a station's step first (a chat's link to it, a request's 查看步骤): beside the chat too,
    // not the settings' place in its place (the sidebar and the page swapped, and swapped back after)
    Setting(AdbShare(station)) => station_tab_key("adb", station)
    _ => return false
  }
  side_change(src, r, "open", Some(tab))
  true
}

///|
fn station_tab_name(src : Source, tab : String) -> String? {
  guard station_tab(tab) is Some((kind, station, screen)) else { return None }
  if kind == "screen" {
    let card = src.topic("screenCard", { "station": Json::string(station), "screen": Json::string(screen) }).get().value
    let name = text(card, "title")
    return Some(if name == "" { @sf.t("web-pages.screen.section") } else { name })
  }
  let scope = station.split("/").next().unwrap_or("").to_owned()
  let mut name = station
  for s in @sfbase.station_marks(src, scope) {
    if s.address == station {
      name = s.name
    }
  }
  let what = match kind {
    "drive" => "web-pages.drive.title"
    "adb" => "android-misc.adb.title"
    _ => "android-chat.station.details"
  }
  Some(name + " · " + @sf.t(what))
}

///|
/// The page tab `tab` beside chat `r` shows, where it is one that may go to a window of its own: a station's screen
/// (as it was opened, its title the one it was opened with).
fn station_tab_page(r : ChatRef, tab : String) -> Page? {
  guard station_tab(tab) is Some(("screen", station, screen)) else { return None }
  let at = panel_screen_pages.get(tabs_key(r) + "/" + tab).unwrap_or({ station, screen, title: "", until_gone: false })
  Some(Screen(at))
}

///|
/// Keep the opening intent per chat: login browsers close their tab when gone.
let panel_screen_pages : Map[String, @sfbase.ScreenAt] = Map([])

///|
fn station_tab_pane(_c : @ui.Ctx, _src : Source, _r : ChatRef, tab : String, own_bar? : @ui.Style? = None) -> Bool {
  guard station_tab(tab) is Some((kind, _, _)) else { return false }
  match kind {
    // (a station's screen: made once as nodes in the panel, panel_node's side_screen_node, its own bar the panel's
    // where it is alone there)
    "screen" => ignore(own_bar)
    // (a station's 文件, its page and the settings' 共享调试, made once as nodes in the panel: panel_node's
    // side_files_node, side_station_node, side_adb_node)
    _ => ()
  }
  true
}
