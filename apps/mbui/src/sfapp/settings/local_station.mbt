// What 本机 Station rests on (its page: src/sfpages local_station.mbt, one in every frame): whether this machine's
// station is the app's to add and update, how the machine is called, its data's folder named as the system names it,
// how often the page reads it again; 添加这台 Mac where a station is added.

///|
/// Whether this machine's station is the app's to add and to bring up to date (its host runs the station's installer:
/// macOS's, Windows', Linux's); a phone's and a page's are not.
pub fn local_station_managed() -> Bool {
  let p = @ui.platform()
  p == 0 || p == 3 || p == 5
}

///|
/// What the host says of this machine's station (its native call `local_station`), read as it is now.
fn local_station_json() -> Json? {
  let raw = @hostapi.app_said("local_station")
  Some(@json.parse(raw) catch { _ => Json::null() })
}

///|
/// Whether this machine can be added to `workspace` (whose stations already present are `known`): the app manages its
/// station, the installer is not at work on it, and it is not in `workspace` already. Its data being there is no
/// reason not to (the installer joins a station already in a workspace to this one beside it, `enroll --stay`, and
/// enrolls one removed from its own again). Not where it is in `workspace`: its home there (not removed), or listed
/// among `known`, as one joined to it is whatever its home says (a station is one id in every workspace it is in). Not
/// a machine that only runs tasks (a rig, `rig`): it is in one workspace, and enrolling it as a station is refused.
pub fn local_station_addable_in(workspace : String, known : Array[String]) -> Bool {
  if !local_station_managed() {
    return false
  }
  let s = local_station_json()
  if text(s, "doing") != "" {
    return false
  }
  let ws = field(s, "workspace")
  guard ws is Some(Object(_)) else { return true }
  let st = text(ws, "station")
  if st != "" && known.contains(st) {
    return false
  }
  if flag(ws, "removed") {
    return true
  }
  text(ws, "id") != workspace && !flag(ws, "rig")
}

///|
// kept across runs: put back as a run begins (reset)
let local_said_kept : Ref[@signals.Signal[String]?] = Ref(None)

///|
/// What the host says of this machine's station, as a signal: read of the host as it is first asked, and again as a
/// page that reads it on its own time hears it anew (local_station_heard), so what shows it is made again then.
fn local_said() -> @signals.Signal[String] {
  match local_said_kept.val {
    Some(s) => s
    None => {
      let s = @signals.signal(@hostapi.app_said("local_station"), same=fn(a, b) { a == b })
      local_said_kept.val = Some(s)
      s
    }
  }
}

///|
/// What the host said of this machine's station just now, heard by a page that reads it again on its own time
/// (本机 Station's, this machine's station's page): Station's list tags and orders by it.
pub fn local_station_heard(said : String) -> Unit {
  local_said().set(said)
}

///|
/// The id of the station this machine is (its host's, the same in every workspace it is in), "" where it is none.
fn local_station_id() -> String {
  if !local_station_managed() {
    return ""
  }
  let s = Some(@json.parse(local_said().get()) catch { _ => Json::null() })
  let ws = field(s, "workspace")
  // (not one taken away from here, its data kept: 已卸载)
  if flag(s, "uninstalled") || flag(ws, "removed") || flag(ws, "rig") { "" } else { text(ws, "station") }
}

///|
fn add_here_note(pc : Bool) -> String {
  if text(local_station_json(), "data") != "" {
    tr(if pc { "android-settings.station.addHereExistingPc" } else { "android-settings.station.addHereExisting" })
  } else {
    tr(if pc { "android-settings.station.addHerePc" } else { "android-settings.station.addHere" })
  }
}

///|
fn local_joinable_item(core : Core, here : Here) -> Json? {
  let s = local_station_json()
  let ws = field(s, "workspace")
  guard ws is Some(Object(_)) && !flag(ws, "removed") else { return None }
  let st = text(ws, "station")
  let ws_id = text(ws, "id")
  if st == "" {
    return None
  }
  let joinable = (core.topic)("joinable", { "workspace": str(here.workspace) }).get().value
  for j in items(joinable, "items") {
    if !flag(Some(j), "rig") && (text(Some(j), "id") == st || (ws_id != "" && text(Some(j), "station") == ws_id + "/" + st)) {
      return Some(j)
    }
  }
  None
}

///|
/// Returns `(join_station_address, needs_lock, lock_reason)` for adding this machine to `here.workspace`. Joined over
/// the mesh only where it is up and among `joinable` (the viewer manages a workspace it is in); else the installer
/// runs, which joins it on this machine. Whether its home in safe mode keeps it out of a workspace not in it is known
/// only from `joinable` too (the host cannot tell a lock turned off from one on): where the viewer manages none of its
/// workspaces, the installer is run, and fails as the station refuses, said on 本机 Station.
fn local_here_join_state(core : Core, here : Here) -> (String?, Bool, String) {
  let s = local_station_json()
  let running = text(s, "runner") != "none"
  match local_joinable_item(core, here) {
    Some(j) if flag(Some(j), "needsLock") => (None, true, text(Some(j), "line"))
    Some(j) if flag(Some(j), "online") && running => (Some(text(Some(j), "station")), false, "")
    _ => (None, false, "")
  }
}

///|
fn press_add_here(
  core : Core,
  here : Here,
  join_station : String?,
  close_on_join : Bool,
  then : () -> Unit,
) -> Unit {
  match join_station {
    Some(station) => {
      adding.here_error.set("")
      (core.call)("station.join", obj([("station", str(station)), ("workspace", str(here.workspace))]), fn(r) {
        match r {
          Ok(_) => if close_on_join { then() }
          Err(e) => adding.here_error.set(error_text(e))
        }
      })
    }
    None => {
      then()
      (core.local_install)(true)
      (core.push)(LocalStation)
    }
  }
}

///|
// kept across runs: a value (no field of it changes)
/// 添加这台 Mac's words over its button.
let here_column : @ui.Style = @ui.css("w=Full gap=S2_5")

///|
// kept across runs: a value (no field of it changes)
let here_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
/// 添加这台 Mac in 添加 station's sheet: in from its sides as its words are, apart from the steps under it.
let here_room : @ui.Style = @ui.css("w=Full pb=S4")

///|
/// This machine called as the person would call it: a Mac, else a computer (Windows', Linux's: 这台电脑).
pub fn local_machine_pc() -> Bool {
  @ui.platform() == 3 || @ui.platform() == 5
}

///|
/// Its data shown in the system's own file manager, named as the system names it (Finder, Explorer, a Linux desktop's).
pub fn local_folder_label() -> String {
  tr(
    match @ui.platform() {
      3 => "web-pages.localStation.openFolderPc"
      5 => "web-pages.localStation.openFolderFiles"
      _ => "web-pages.localStation.openFolder"
    },
  )
}

///|
/// How often the page reads the station again while shown.
pub let local_read_ms : Double = 3000.0
