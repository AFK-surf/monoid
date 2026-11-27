// Station destinations beside the current chat. The shell chooses this placement;
// menus and pages still ask to open the same Screen, Drive and Station pages.

///|
fn station_tab_key(kind : String, station : String, screen? : String, cwd? : String) -> String {
  let parts = [Json::string(station)]
  match screen { Some(s) => parts.push(Json::string(s)); None => () }
  match cwd { Some(c) if c != "" => parts.push(Json::string(c)); _ => () }
  kind + ":" + Json::array(parts).stringify()
}

///|
fn station_tab(tab : String) -> (String, String, String)? {
  for kind in ["screen", "terminal", "drive", "station", "adb"] {
    let prefix = kind + ":"
    if tab.has_prefix(prefix) {
      let value = @json.parse(tab[prefix.length():].to_owned()) catch { _ => return None }
      guard value is Array(xs) else { return None }
      if kind == "screen" {
        guard xs.length() == 2 && xs[0] is String(station) && station != "" && xs[1] is String(screen) else { return None }
        return Some((kind, station, screen))
      }
      if kind == "terminal" {
        guard (xs.length() == 2 || xs.length() == 3) &&
          xs[0] is String(station) &&
          station != "" &&
          xs[1] is String(terminal) &&
          terminal != "" else {
          return None
        }
        return Some((kind, station, terminal))
      }
      guard xs.length() == 1 && xs[0] is String(station) && station != "" else { return None }
      return Some((kind, station, ""))
    }
  }
  None
}

///|
fn station_terminal_at(r : ChatRef, tab : String) -> @sfbase.TerminalAt? {
  guard station_tab(tab) is Some(("terminal", station, terminal)) else { return None }
  if panel_terminal_pages.get(tabs_key(r) + "/" + tab) is Some(kept) {
    return Some(kept)
  }
  let mut cwd = ""
  if tab.has_prefix("terminal:") {
    let v = @json.parse(tab[9:].to_owned()) catch { _ => Json::null() }
    if v is Array(xs) && xs.length() >= 3 && xs[2] is String(c) {
      cwd = c
    }
  }
  let chat = if station == r.station && @sfbase.terminal_is_new(terminal) && cwd == "" { r.session } else { "" }
  Some({ station, terminal: @sfbase.terminal_with_chat(terminal, chat), watch: false, cwd })
}

///|
fn station_files_scope(r : ChatRef, station : String) -> String {
  tabs_key(r) + "/" + station_tab_key("drive", station)
}

///|
/// Route `Screen` or `Terminal` into the `Place("remote")` multi-tab workbench when `Place("remote")` is active.
pub fn remote_page_in_workbench(src : Source, p : Page) -> Bool {
  guard @sfbase.workspace_in_view(src).0 is Some(w) else { return false }
  match p {
    Screen(at) => {
      @sfbase.remote_tab_open(src, w.id, Screen(at)) |> ignore
      show_page()
      true
    }
    Terminal(at) => {
      @sfbase.remote_tab_open(src, w.id, Terminal(at)) |> ignore
      show_page()
      true
    }
    _ => false
  }
}

///|
pub fn station_page_beside(src : Source, r : ChatRef, p : Page) -> Bool {
  let tab = match p {
    Screen(at) => {
      let tab = station_tab_key("screen", at.station, screen=at.screen)
      panel_screen_pages[tabs_key(r) + "/" + tab] = at
      tab
    }
    Terminal(at) => {
      let existing_tabs = side_now(src, r).0
      if !at.terminal.has_prefix("new") {
        for t in existing_tabs {
          if station_tab(t) == Some(("terminal", at.station, at.terminal)) {
            side_change(src, r, "open", Some(t))
            return true
          }
        }
      }
      let mut term_id = if at.terminal == "" { "new" } else { @sfbase.terminal_base_id(at.terminal) }
      let mut tab = station_tab_key("terminal", at.station, screen=term_id, cwd=at.cwd)
      if term_id == "new" {
        let mut n = 1
        while existing_tabs.contains(tab) {
          n += 1
          term_id = "new#" + n.to_string()
          tab = station_tab_key("terminal", at.station, screen=term_id, cwd=at.cwd)
        }
      }
      let chat = if @sfbase.terminal_open_chat(at.terminal) != "" {
        @sfbase.terminal_open_chat(at.terminal)
      } else if at.station == r.station && @sfbase.terminal_is_new(term_id) && at.cwd == "" {
        r.session
      } else {
        ""
      }
      panel_terminal_pages[tabs_key(r) + "/" + tab] = { ..at, terminal: @sfbase.terminal_with_chat(term_id, chat) }
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
fn station_cwd_leaf(cwd : String) -> String {
  let trimmed = if cwd.length() > 1 && cwd.has_suffix("/") {
    cwd[:cwd.length() - 1].to_owned()
  } else {
    cwd
  }
  if trimmed == "" || trimmed == "/" || trimmed == "~" {
    trimmed
  } else {
    let mut last = trimmed
    for part in trimmed.split("/") {
      let s = part.to_owned()
      if s != "" {
        last = s
      }
    }
    last
  }
}

///|
fn station_tab_name(src : Source, tab : String) -> String? {
  guard station_tab(tab) is Some((kind, station, screen)) else { return None }
  if kind == "screen" {
    let card = src.topic("screenCard", { "station": Json::string(station), "screen": Json::string(screen) }).get().value
    let name = text(card, "title")
    return Some(if name == "" { @sf.t("web-pages.screen.section") } else { name })
  }
  if kind == "terminal" {
    if screen.has_prefix("new") {
      return Some(@sf.t("web-pages.terminal.title"))
    }
    let card = src.topic("terminalCard", { "station": Json::string(station), "terminal": Json::string(screen) }).get().value
    let leaf = station_cwd_leaf(text(card, "cwd"))
    return Some(if leaf == "" { @sf.t("web-pages.terminal.title") } else { leaf })
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
/// The page tab `tab` beside chat `r` shows, where it is one that may go to a window of its own or expand to full window:
/// a station's screen or resolved terminal.
fn station_tab_page(r : ChatRef, tab : String) -> Page? {
  match station_tab(tab) {
    Some(("screen", station, screen)) => {
      let at = panel_screen_pages.get(tabs_key(r) + "/" + tab).unwrap_or({ station, screen, title: "", until_gone: false })
      Some(Screen(at))
    }
    Some(("terminal", _, terminal)) if !terminal.has_prefix("new") =>
      station_terminal_at(r, tab).map(fn(at) { Terminal(at) })
    _ => None
  }
}

///|
/// Keep the opening intent per chat: login browsers close their tab when gone; terminals keep their initial cwd/chat.
let panel_screen_pages : Map[String, @sfbase.ScreenAt] = Map([])

///|
let panel_terminal_pages : Map[String, @sfbase.TerminalAt] = Map([])
