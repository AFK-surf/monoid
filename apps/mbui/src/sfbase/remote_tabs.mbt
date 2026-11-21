// The remote workbench's tabs on Medium and Large (`Place("remote")`), persisted per workspace in `prefs.remoteTabs`
// (JSON `{ "tabs": [...], "active": "..." }`). Optimistic local state updates in the press's frame and clears once
// `prefs` catches up, so tab switches, additions and closes happen in a single frame with zero flicker.

///|
#derive(Eq)
pub(all) enum RemoteTab {
  Screen(ScreenAt)
  Terminal(TerminalAt)
}

///|
pub fn RemoteTab::key(self : RemoteTab) -> String {
  match self {
    Screen(at) => "screen:" + Json::array([Json::string(at.station), Json::string(at.screen)]).stringify()
    Terminal(at) =>
      "terminal:" +
      Json::array([Json::string(at.station), Json::string(at.terminal), Json::string(at.cwd)]).stringify()
  }
}

///|
pub fn RemoteTab::station(self : RemoteTab) -> String {
  match self {
    Screen(at) => at.station
    Terminal(at) => at.station
  }
}

///|
pub fn RemoteTab::page(self : RemoteTab) -> Page {
  match self {
    Screen(at) => Screen(at)
    Terminal(at) => Terminal(at)
  }
}

///|
pub fn remote_tab_parse(raw : String) -> RemoteTab? {
  if raw.has_prefix("screen:") {
    let v = @json.parse(raw[7:].to_owned()) catch { _ => return None }
    guard v is Array(xs) && xs.length() >= 2 else { return None }
    guard xs[0] is String(station) && station != "" && xs[1] is String(screen) && screen != "" else { return None }
    let title = if xs.length() >= 3 && xs[2] is String(t) { t } else { "" }
    return Some(Screen({ station, screen, title, until_gone: false }))
  }
  if raw.has_prefix("terminal:") {
    let v = @json.parse(raw[9:].to_owned()) catch { _ => return None }
    guard v is Array(xs) && xs.length() >= 2 else { return None }
    guard xs[0] is String(station) && station != "" && xs[1] is String(terminal) && terminal != "" else { return None }
    let cwd = if xs.length() >= 3 && xs[2] is String(c) { c } else { "" }
    // (a tab kept before the chat rode in the id: its fourth, folded in)
    let chat = if xs.length() >= 4 && xs[3] is String(ch) { ch } else { "" }
    return Some(Terminal({ station, terminal: terminal_with_chat(terminal, chat), watch: false, cwd }))
  }
  None
}

///|
// kept across runs: reset in remote_tabs_reset
let remote_tabs_local : @sf.LiveMap[String, (Array[String], String)] = @sf.LiveMap::new()

///|
pub fn remote_tabs_reset() -> Unit {
  remote_tabs_local.clear()
}

///|
fn remote_tabs_decode(raw : String) -> (Array[String], String) {
  let v = @json.parse(raw) catch { _ => return ([], "") }
  guard v is Object(m) else { return ([], "") }
  let seen : Array[String] = []
  match m.get("tabs") {
    Some(Array(arr)) =>
      for x in arr {
        if x is String(s) && remote_tab_parse(s) is Some(_) && !seen.contains(s) {
          seen.push(s)
        }
      }
    _ => ()
  }
  let active = match m.get("active") {
    Some(String(a)) if seen.contains(a) => a
    _ => seen.get(0).unwrap_or("")
  }
  (seen, active)
}

///|
pub fn remote_tabs_raw(src : Source, ws : String) -> (Array[String], String) {
  match remote_tabs_local.get(ws) {
    Some(local_val) => local_val
    None => {
      let prefs = src.topic("prefs", {}).get().value
      match field(field(prefs, "remoteTabs"), ws) {
        Some(String(s)) => remote_tabs_decode(s)
        _ => ([], "")
      }
    }
  }
}

///|
pub fn remote_tabs_of(src : Source, ws : String) -> (Array[(String, RemoteTab)], String) {
  let (keys, active) = remote_tabs_raw(src, ws)
  let out : Array[(String, RemoteTab)] = []
  for k in keys {
    if remote_tab_parse(k) is Some(t) {
      out.push((k, t))
    }
  }
  (out, active)
}

///|
fn remote_tabs_save(src : Source, ws : String, tabs : Array[String], active : String) -> Unit {
  let act = if tabs.contains(active) { active } else { tabs.get(0).unwrap_or("") }
  remote_tabs_local.set(ws, (tabs, act))
  let payload = Json::object({
    "tabs": Json::array(tabs.map(fn(s) { Json::string(s) })),
    "active": Json::string(act),
  }).stringify()
  let by : Map[String, Json] = Map([])
  by[ws] = Json::string(payload)
  (src.call)("prefs.set", Json::object({ "remoteTabs": Json::object(by) }), answer_unread)
}

///|
/// Open or focus `tab` in workspace `ws`'s remote workbench; returns its tab key.
pub fn remote_tab_open(src : Source, ws : String, tab : RemoteTab) -> String {
  let (tabs, _) = @signals.untracked(fn() { remote_tabs_raw(src, ws) })
  // Match existing screen or non-"new" terminal by station + id regardless of initial cwd/chat metadata
  let existing = match tab {
    Screen(at) =>
      tabs.iter().find_first(fn(k) {
        remote_tab_parse(k) is Some(Screen(x)) && x.station == at.station && x.screen == at.screen
      })
    Terminal(at) if !terminal_is_new(at.terminal) =>
      tabs.iter().find_first(fn(k) {
        remote_tab_parse(k) is Some(Terminal(x)) && x.station == at.station && x.terminal == at.terminal
      })
    _ => None
  }
  match existing {
    Some(k) => {
      remote_tabs_save(src, ws, tabs.copy(), k)
      k
    }
    None => {
      let mut key = tab.key()
      if tab is Terminal(at) && terminal_base_id(at.terminal) == "new" {
        let mut n = 1
        while tabs.contains(key) {
          n += 1
          key = RemoteTab::Terminal({ ..at, terminal: new_terminal_id(chat=terminal_open_chat(at.terminal), seq=n) }).key()
        }
      }
      let next = tabs.copy()
      next.push(key)
      remote_tabs_save(src, ws, next, key)
      key
    }
  }
}

///|
pub fn remote_tab_close(src : Source, ws : String, key : String) -> Unit {
  let (tabs, active) = @signals.untracked(fn() { remote_tabs_raw(src, ws) })
  guard tabs.search(key) is Some(idx) else { return }
  let next = tabs.filter(fn(k) { k != key })
  let next_active = if active == key {
    if next.is_empty() {
      ""
    } else if idx < next.length() {
      next[idx]
    } else {
      next[next.length() - 1]
    }
  } else {
    active
  }
  remote_tabs_save(src, ws, next, next_active)
}

///|
/// Replace `old_key` (e.g. a `new` terminal tab once the station assigns its real id) in place without reordering.
pub fn remote_tab_replace(src : Source, ws : String, old_key : String, next_tab : RemoteTab) -> String {
  let (tabs, active) = @signals.untracked(fn() { remote_tabs_raw(src, ws) })
  let new_key = next_tab.key()
  if old_key == new_key {
    return new_key
  }
  let out : Array[String] = []
  for k in tabs {
    let mapped = if k == old_key { new_key } else { k }
    if !out.contains(mapped) {
      out.push(mapped)
    }
  }
  let next_act = if active == old_key { new_key } else { active }
  remote_tabs_save(src, ws, out, next_act)
  new_key
}
