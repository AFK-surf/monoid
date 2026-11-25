// Sidebar project/folder drawers state and workspace project metadata (`projects` topic and `prefs.chatDrawers` /
// `prefs.drawerCollapsed`). The `projects` topic is only read when drawers are enabled or when a project picker opens.

///|
/// One workspace project registered in PROJECTS.jsonl (core's `ProjectItem`).
#derive(Eq)
pub(all) struct ProjectInfo {
  name : String
  note : String
  refs : Array[String]
}

///|
/// Workspace project metadata merged from online stations' PROJECTS.jsonl (core's `ProjectsView`).
#derive(Eq)
pub(all) struct ProjectsView {
  projects : Array[ProjectInfo]
  supported : Bool
}

///|
/// Read workspace `scope`'s `projects` topic into `ProjectsView`.
pub fn projects_of(src : Source, scope : String) -> ProjectsView {
  let v = src.topic("projects", { "scope": Json::string(scope) }).get().value
  let projects : Array[ProjectInfo] = items(v, "projects").filter_map(fn(j) {
    let o = Some(j)
    let name = text(o, "name").trim().to_owned()
    if name == "" {
      return None
    }
    let refs : Array[String] = items(o, "refs").filter_map(fn(r) {
      match r {
        String(s) => {
          let t = s.trim().to_owned()
          if t == "" { None } else { Some(t) }
        }
        _ => None
      }
    })
    Some({ name, note: text(o, "note").trim().to_owned(), refs })
  })
  { projects, supported: flag(v, "supported") }
}

///|
/// Whether the sidebar chat list shows collapsible project/folder drawers on this device (`prefs.chatDrawers == "on"`).
pub fn chat_drawers_on(src : Source) -> Bool {
  text(src.topic("prefs", {}).get().value, "chatDrawers") == "on"
}

///|
/// Optimistic local overrides for per-workspace collapsed drawer keys, applied immediately before `prefs.set` echoes.
// kept across runs: put back by drawers_reset as a run starts
let drawer_collapsed_here : Map[String, Set[String]] = Map([])

///|
/// Revision counter bumped on optimistic drawer collapse changes.
// kept across runs: bumped by drawer toggle and drawers_reset
let drawer_rev : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })

///|
/// Clear optimistic drawer state between runs.
pub fn drawers_reset() -> Unit {
  drawer_collapsed_here.clear()
  new_chat_project.set(None)
  drawer_rev.set(drawer_rev.untracked() + 1)
}

///|
/// Parse a JSON string array from `prefs.drawerCollapsed[ws]` into a `Set[String]`.
fn parse_collapsed(raw : String) -> Set[String] {
  let out : Set[String] = Set([])
  if raw == "" {
    return out
  }
  let parsed = @json.parse(raw) catch { _ => Json::null() }
  match parsed {
    Array(arr) =>
      for el in arr {
        match el {
          String(k) if k != "" => out.add(k)
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// Which drawer keys are currently collapsed in workspace `ws`.
pub fn drawer_collapsed_of(src : Source, ws : String) -> Set[String] {
  drawer_rev.get() |> ignore
  match drawer_collapsed_here.get(ws) {
    Some(s) => s
    None =>
      match field(field(src.topic("prefs", {}).get().value, "drawerCollapsed"), ws) {
        Some(String(raw)) => parse_collapsed(raw)
        _ => Set([])
      }
  }
}

///|
/// Persist `collapsed` drawer keys for workspace `ws` (`prefs.set { drawerCollapsed }`).
pub fn set_drawer_collapsed(src : Source, ws : String, collapsed : Set[String]) -> Unit {
  let copy : Set[String] = Set([])
  let sorted : Array[String] = []
  for k in collapsed {
    if k != "" {
      copy.add(k)
      sorted.push(k)
    }
  }
  sorted.sort()
  drawer_collapsed_here[ws] = copy
  drawer_rev.set(drawer_rev.untracked() + 1)
  let value : Json = if sorted.is_empty() {
    Json::null()
  } else {
    Json::string(Json::array(sorted.map(Json::string)).stringify())
  }
  (src.call)(
    "prefs.set",
    { "drawerCollapsed": Json::object(Map::from_array([(ws, value)])) },
    answer_unread,
  )
}

///|
/// Toggle a single drawer key collapsed/expanded for workspace `ws`.
pub fn toggle_drawer_collapsed(src : Source, ws : String, key : String) -> Unit {
  let next : Set[String] = Set([])
  for k in @signals.untracked(fn() { drawer_collapsed_of(src, ws) }) {
    next.add(k)
  }
  if next.contains(key) {
    next.remove(key)
  } else {
    next.add(key)
  }
  set_drawer_collapsed(src, ws, next)
}

///|
/// Expand or collapse all given drawer `keys` in workspace `ws`.
pub fn set_all_drawers_collapsed(src : Source, ws : String, keys : Array[String], collapse : Bool) -> Unit {
  let next : Set[String] = Set([])
  if collapse {
    for k in keys {
      if k != "" {
        next.add(k)
      }
    }
  }
  set_drawer_collapsed(src, ws, next)
}
