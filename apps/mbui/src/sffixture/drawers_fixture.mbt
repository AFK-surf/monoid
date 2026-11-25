// Stateful fixture support for collapsible project/folder drawers (`home-drawers`, `home-drawers-dark`, and live
// toggling from `home` or `settings-appearance` in the browser preview): `prefs.chatDrawers`, `prefs.drawerCollapsed`,
// `projects` topic, `chat.classify`, and `project.setInfo`.

///|
priv struct DrawerProjectMeta {
  mut note : String
  mut refs : Array[String]
}

///|
// kept across runs: re-seeded by drawers_fixture_seed(mode) in fixture(mode)
let drawer_fix_on : Ref[String] = Ref("")

///|
// kept across runs: re-seeded by drawers_fixture_seed(mode) in fixture(mode)
let drawer_fix_collapsed : Map[String, String] = Map([])

///|
// kept across runs: re-seeded by drawers_fixture_seed(mode) in fixture(mode)
let drawer_fix_chat_project : Map[String, String?] = Map([])

///|
// kept across runs: re-seeded by drawers_fixture_seed(mode) in fixture(mode)
let drawer_fix_projects : Map[String, DrawerProjectMeta] = Map([])

///|
/// Whether `mode` starts with collapsible project/folder drawers enabled and sample project classifications populated.
fn drawers_mode(mode : String) -> Bool {
  mode == "home-drawers" || mode == "home-drawers-dark"
}

///|
/// Seed fixture project/drawer state when a new fixture run starts.
fn drawers_fixture_seed(mode : String) -> Unit {
  drawer_fix_on.val = if drawers_mode(mode) { "on" } else { "" }
  drawer_fix_collapsed.clear()
  drawer_fix_chat_project.clear()
  drawer_fix_projects.clear()
  drawer_fix_projects["stillfail-ui"] = {
    note: "界面框架与跨端组件库",
    refs: ["Willow:~/code/stillfail-app", "https://github.com/AFK-surf/monoid"],
  }
  drawer_fix_projects["infra-ci"] = {
    note: "构建流水线与发布基础设施",
    refs: ["Maple:~/ops/ci-runner"],
  }
  drawer_fix_projects["design-system"] = {
    note: "视觉规范、图标与引导页设计",
    refs: ["Willow:~/design/tokens"],
  }
  drawer_fix_projects["docs-site"] = {
    note: "产品文档与更新日志站点",
    refs: ["Willow:~/docs/handbook"],
  }
  if drawers_mode(mode) {
    drawer_fix_chat_project["c1"] = Some("stillfail-ui")
    drawer_fix_chat_project["c2"] = Some("stillfail-ui")
    drawer_fix_chat_project["c3"] = Some("infra-ci")
    drawer_fix_chat_project["c4"] = Some("stillfail-ui")
    drawer_fix_chat_project["c5"] = Some("infra-ci")
    drawer_fix_chat_project["c6"] = Some("design-system")
    drawer_fix_chat_project["c7"] = Some("")
    drawer_fix_chat_project["c8"] = Some("stillfail-ui")
    drawer_fix_chat_project["c9"] = Some("infra-ci")
    drawer_fix_chat_project["c10"] = None
  }
}

///|
/// Write `chatDrawers` and `drawerCollapsed` into the fixture's `prefs` object.
fn drawers_prefs_into(o : Map[String, Json]) -> Unit {
  if drawer_fix_on.val != "" {
    o["chatDrawers"] = Json::string(drawer_fix_on.val)
  }
  if !drawer_fix_collapsed.is_empty() {
    let m : Map[String, Json] = Map([])
    for k, v in drawer_fix_collapsed {
      m[k] = Json::string(v)
    }
    o["drawerCollapsed"] = Json::object(m)
  }
}

///|
/// Handle `chatDrawers` and `drawerCollapsed` fields inside fixture `prefs.set`.
fn drawers_prefs_set(params : Json) -> Unit {
  match field(Some(params), "chatDrawers") {
    Some(String(v)) => drawer_fix_on.val = v
    Some(Null) => drawer_fix_on.val = ""
    _ => ()
  }
  match field(Some(params), "drawerCollapsed") {
    Some(Object(m)) =>
      for k, v in m {
        match v {
          String(s) if s != "" => drawer_fix_collapsed[k] = s
          _ => drawer_fix_collapsed.remove(k)
        }
      }
    _ => ()
  }
}

///|
/// Deterministic unique thread number (`101..110`) for sample chats `c1..c10` in drawers mode.
fn drawer_thread_for(id : String) -> Int? {
  match id {
    "c1" => Some(101)
    "c2" => Some(102)
    "c3" => Some(103)
    "c4" => Some(104)
    "c5" => Some(105)
    "c6" => Some(106)
    "c7" => Some(107)
    "c8" => Some(108)
    "c9" => Some(109)
    "c10" => Some(110)
    _ => None
  }
}

///|
fn drawer_id_for_thread(th : Int) -> String? {
  match th {
    101 => Some("c1")
    102 => Some("c2")
    103 => Some("c3")
    104 => Some("c4")
    105 => Some("c5")
    106 => Some("c6")
    107 => Some("c7")
    108 => Some("c8")
    109 => Some("c9")
    110 => Some("c10")
    _ => None
  }
}

///|
/// Decorate a fixture row with project classification (and unique thread ID + pinned flag in `home-drawers`).
fn drawers_decorate_row(f : Fixture, r : Json) -> Json {
  let id = text(Some(r), "id")
  let active = drawers_mode(f.mode) || drawer_fix_on.val == "on" || drawer_fix_chat_project.contains(id)
  if !active {
    return r
  }
  match r {
    Object(m) => {
      let o = m.copy()
      match drawer_thread_for(id) {
        Some(th) => o["thread"] = Json::number(th.to_double())
        None => ()
      }
      if drawers_mode(f.mode) && id == "c4" {
        o["pinned"] = Json::boolean(true)
      }
      match drawer_fix_chat_project.get(id) {
        Some(Some(proj)) => o["project"] = Json::string(proj)
        Some(None) => o.remove("project")
        None => ()
      }
      Json::object(o)
    }
    other => other
  }
}

///|
/// The `projects` topic value for the fixture workspace.
fn fixture_projects_topic() -> Json {
  let names : Array[String] = []
  for k, _ in drawer_fix_projects {
    names.push(k)
  }
  names.sort()
  let arr : Array[Json] = names.map(fn(name) {
    let meta = drawer_fix_projects.get(name).unwrap()
    let o : Map[String, Json] = { "name": Json::string(name) }
    if meta.note != "" {
      o["note"] = Json::string(meta.note)
    }
    if !meta.refs.is_empty() {
      o["refs"] = Json::array(meta.refs.map(Json::string))
    }
    Json::object(o)
  })
  { "projects": Json::array(arr), "supported": true }
}

///|
/// Handle `chat.classify` in the fixture.
fn drawers_classify_call(f : Fixture, params : Json) -> Result[Json, Json] {
  let th = match field(Some(params), "thread") {
    Some(Number(n, ..)) => n.to_int()
    _ => return Ok(Json::object({}))
  }
  guard drawer_id_for_thread(th) is Some(id) else { return Ok(Json::object({})) }
  if flag(Some(params), "clearProject") {
    drawer_fix_chat_project[id] = None
  } else {
    match field(Some(params), "project") {
      Some(String(p)) => {
        let trimmed = p.trim().to_owned()
        drawer_fix_chat_project[id] = Some(trimmed)
        if trimmed != "" && !drawer_fix_projects.contains(trimmed) {
          drawer_fix_projects[trimmed] = { note: "", refs: [] }
        }
      }
      Some(Null) => drawer_fix_chat_project[id] = None
      _ => ()
    }
  }
  f.changed()
  Ok(Json::object({}))
}

///|
/// Handle `project.setInfo` in the fixture.
fn drawers_set_info_call(f : Fixture, params : Json) -> Result[Json, Json] {
  let name = text(Some(params), "name").trim().to_owned()
  if name == "" {
    return Ok(Json::object({}))
  }
  if flag(Some(params), "delete") {
    drawer_fix_projects.remove(name)
    f.changed()
    return Ok(Json::object({}))
  }
  let meta = match drawer_fix_projects.get(name) {
    Some(m) => m
    None => {
      let m : DrawerProjectMeta = { note: "", refs: [] }
      drawer_fix_projects[name] = m
      m
    }
  }
  if flag(Some(params), "clearNote") {
    meta.note = ""
  } else {
    match field(Some(params), "note") {
      Some(String(n)) => meta.note = n.trim().to_owned()
      _ => ()
    }
  }
  if flag(Some(params), "clearRefs") {
    meta.refs = []
  } else {
    match field(Some(params), "refs") {
      Some(Array(arr)) =>
        meta.refs = arr.filter_map(fn(x) {
          match x {
            String(s) if s.trim().to_owned() != "" => Some(s.trim().to_owned())
            _ => None
          }
        })
      _ => ()
    }
  }
  f.changed()
  Ok(Json::object({}))
}
