// Isolated test fixture for PR 3 Chat Classification System (`projects`, `tags`, `project`,
// `chats` grouped/filtered, `chat` proposal/classification, and all 6 classification commands).
// Strictly gated behind `fx_projects_on` (default false, reset in `fixture_reset`) so existing
// baseline scenes and snapshots are 100% untouched.

///|
/// Opt-in switch for chat classification fixture data. Default `false`; reset to `false` in `fixture_reset()`.
// kept across runs: reset by fx_projects_reset (made.mbt fixture_reset)
pub let fx_projects_on : Ref[Bool] = Ref(false)

///|
/// Toggle whether the workspace is writable in `fx_projects_on` mode (default `true`; set `false` for viewer/offline tests).
// kept across runs: reset by fx_projects_reset (made.mbt fixture_reset)
pub let fx_projects_writable : Ref[Bool] = Ref(true)

///|
// kept across runs: cleared by fx_projects_reset (made.mbt fixture_reset)
let fx_list_groups : Map[String, String] = Map([])

///|
// kept across runs: cleared by fx_projects_reset (made.mbt fixture_reset)
let fx_chat_project : Map[String, String?] = Map([])

///|
// kept across runs: cleared by fx_projects_reset (made.mbt fixture_reset)
let fx_chat_locked : Map[String, Bool] = Map([])

///|
// kept across runs: cleared by fx_projects_reset (made.mbt fixture_reset)
let fx_chat_tags : Map[String, Array[String]] = Map([])

///|
// kept across runs: cleared by fx_projects_reset (made.mbt fixture_reset)
let fx_proposal_state : Map[String, (String, String?)] = Map([])

///|
// kept across runs: cleared by fx_projects_reset (made.mbt fixture_reset)
let fx_project_notes : Map[String, (String, Array[String], String)] = Map([])

///|
// kept across runs: cleared by fx_projects_reset (made.mbt fixture_reset)
let fx_preset_projects : Map[String, String] = Map([])

///|
/// Pre-seed list grouping mode for isolated `projects-*` fixture scenes.
pub fn fx_set_list_group(scope : String, group : String) -> Unit {
  if group == "project" {
    fx_list_groups[scope] = "project"
  } else {
    fx_list_groups.remove(scope)
  }
}

///|
/// Reset all isolated classification fixture state. Called by `fixture_reset()`.
pub fn fx_projects_reset() -> Unit {
  fx_projects_on.val = false
  fx_projects_writable.val = true
  fx_list_groups.clear()
  fx_chat_project.clear()
  fx_chat_locked.clear()
  fx_chat_tags.clear()
  fx_proposal_state.clear()
  fx_project_notes.clear()
  fx_preset_projects.clear()
}

///|
/// 80-char stress project name for layout & truncation tests.
pub let fx_stress_project_80 : String = "monoid-cross-platform-chat-classification-ui-architecture-long-project-name-80ch"

///|
/// 48-char stress tag name for chip truncation tests.
pub let fx_stress_tag_48 : String = "very-long-reusable-classification-tag-name-48chr"

///|
fn fx_list_groups_json() -> Json {
  let m : Map[String, Json] = Map([])
  for k, v in fx_list_groups {
    m[k] = Json::string(v)
  }
  Json::object(m)
}

///|
fn fx_apply_prefs_list_groups(params : Json) -> Unit {
  match field(Some(params), "listGroups") {
    Some(Object(m)) =>
      for k, v in m {
        match v {
          String("project") => fx_list_groups[k] = "project"
          Null => fx_list_groups.remove(k)
          _ => ()
        }
      }
    _ => ()
  }
}

///|
/// Decorate `chats` topic output when `fx_projects_on` is true; returns `v` untouched when false.
fn fx_decorate_chats(v : Json, params : Map[String, Json]) -> Json {
  if !fx_projects_on.val {
    return v
  }
  guard v is Object(m) else { return v }
  let out = m.copy()
  out["projects"] = Json::boolean(true)
  if fx_projects_writable.val {
    out["projectsWritable"] = Json::boolean(true)
  }
  if fx_projects_writable.val {
    out["projectsWritable"] = Json::boolean(true)
  }
  // Decorate items with deterministic project/tags metadata
  let all_items : Array[Json] = []
  let new_days : Array[Json] = []
  let mut idx = 0
  for d in items(Some(v), "days") {
    guard d is Object(dm) else { continue }
    let d_items : Array[Json] = []
    for raw in items(Some(d), "items") {
      let item = fx_decorate_chat_item(raw, idx)
      idx += 1
      if fx_item_matches_filters(item, params) {
        d_items.push(item)
        all_items.push(item)
      }
    }
    if !d_items.is_empty() {
      let dm2 = dm.copy()
      dm2["items"] = Json::array(d_items)
      new_days.push(Json::object(dm2))
    }
  }
  out["days"] = Json::array(new_days)
  if text(Some(Json::object(params)), "groupBy") == "project" {
    out["groups"] = Json::array(fx_build_groups(all_items))
  }
  Json::object(out)
}

///|
fn fx_decorate_chat_item(raw : Json, idx : Int) -> Json {
  guard raw is Object(m) else { return raw }
  let out = m.copy()
  let key = text(Some(raw), "station") + ":" + text(Some(raw), "id")
  let proj : String? = match fx_chat_project.get(key) {
    Some(p) => p
    None =>
      if idx % 5 == 0 {
        Some("monoid")
      } else if idx % 5 == 1 {
        Some("board")
      } else if idx % 5 == 2 {
        Some(fx_stress_project_80)
      } else if idx % 5 == 3 {
        None
      } else {
        Some("")
      }
  }
  match proj {
    Some(p) => out["project"] = Json::string(p)
    None => out.remove("project")
  }
  let locked = fx_chat_locked.get(key).unwrap_or(idx % 5 == 0)
  if locked {
    out["projectLocked"] = Json::boolean(true)
  }
  let tags = match fx_chat_tags.get(key) {
    Some(ts) => ts
    None =>
      if idx % 5 == 0 {
        ["ui-review", "ios"]
      } else if idx % 5 == 1 {
        ["board"]
      } else if idx % 5 == 2 {
        [fx_stress_tag_48, "ui-review", "proactive"]
      } else {
        []
      }
  }
  if !tags.is_empty() {
    out["tags"] = Json::array(tags.map(Json::string))
  }
  Json::object(out)
}

///|
fn fx_item_matches_filters(item : Json, params : Map[String, Json]) -> Bool {
  let s = Some(item)
  if params.get("unclassified") is Some(True) {
    if field(s, "project") is Some(String(_)) {
      return false
    }
  } else if params.get("project") is Some(String(want)) {
    match field(s, "project") {
      Some(String(got)) if got == want => ()
      _ => return false
    }
  }
  match params.get("tag") {
    Some(String(want_tag)) if want_tag != "" => {
      let has = items(s, "tags").iter().any(fn(t) { t == Json::string(want_tag) })
      if !has {
        return false
      }
    }
    _ => ()
  }
  true
}

///|
fn fx_build_groups(all_items : Array[Json]) -> Array[Json] {
  let pinned : Array[Json] = []
  let by_proj : Map[String, Array[Json]] = Map([])
  let proj_order : Array[String] = []
  let unclass : Array[Json] = []
  let cross : Array[Json] = []
  for item in all_items {
    let s = Some(item)
    if flag(s, "pinned") {
      pinned.push(item)
      continue
    }
    match field(s, "project") {
      None => unclass.push(item)
      Some(String("")) => cross.push(item)
      Some(String(p)) =>
        match by_proj.get(p) {
          Some(arr) => arr.push(item)
          None => {
            by_proj[p] = [item]
            proj_order.push(p)
          }
        }
      _ => unclass.push(item)
    }
  }
  let mk = fn(key : String, kind : String, label : String, proj : String?, rows : Array[Json]) -> Json {
    let mut running = 0
    let mut asking = 0
    let mut unread = 0
    for r in rows {
      let rs = Some(r)
      if text(rs, "state") == "run" { running += 1 }
      if text(rs, "stateLead") == "need" { asking += 1 }
      if flag(rs, "unread") { unread += 1 }
    }
    let m : Map[String, Json] = {
      "key": Json::string(key),
      "kind": Json::string(kind),
      "label": Json::string(label),
      "chatCount": Json::number(rows.length().to_double()),
      "runningCount": Json::number(running.to_double()),
      "askingCount": Json::number(asking.to_double()),
      "unreadCount": Json::number(unread.to_double()),
      "items": Json::array(rows),
    }
    match proj {
      Some(p) => m["project"] = Json::string(p)
      None => ()
    }
    Json::object(m)
  }
  let groups : Array[Json] = []
  if !pinned.is_empty() {
    groups.push(mk("pinned", "pinned", "已固定", None, pinned))
  }
  for p in proj_order {
    match by_proj.get(p) {
      Some(rows) => groups.push(mk("project:" + p, "project", p, Some(p), rows))
      None => ()
    }
  }
  if !unclass.is_empty() {
    groups.push(mk("unclassified", "unclassified", "未归类", None, unclass))
  }
  if !cross.is_empty() {
    groups.push(mk("cross", "cross", "跨项目 / 其他", Some(""), cross))
  }
  groups
}

///|
/// Decorate `chat` topic output when `fx_projects_on` is true; returns `v` untouched when false.
fn fx_decorate_chat(v : Json, params : Map[String, Json]) -> Json {
  if !fx_projects_on.val {
    return v
  }
  guard v is Object(m) else { return v }
  let out = m.copy()
  out["projects"] = Json::boolean(true)
  if fx_projects_writable.val {
    out["projectsWritable"] = Json::boolean(true)
  }
  let station = text(Some(Json::object(params)), "station")
  let session = text(Some(Json::object(params)), "session")
  let key = station + ":" + session
  let proj : String? = match fx_chat_project.get(key) {
    Some(p) => p
    None => Some("monoid")
  }
  match proj {
    Some(p) => out["project"] = Json::string(p)
    None => out.remove("project")
  }
  out["projectLocked"] = Json::boolean(fx_chat_locked.get(key).unwrap_or(true))
  let tags = fx_chat_tags.get(key).unwrap_or(["ui-review", "ios"])
  out["tags"] = Json::array(tags.map(Json::string))
  // Attach a pending proposal to the last message if present
  let msgs = items(Some(v), "messages")
  if !msgs.is_empty() {
    let last_i = msgs.length() - 1
    let last = msgs[last_i]
    if last is Object(lm) {
      let lm2 = lm.copy()
      let seq = number(Some(last), "seq").to_int()
      let pk = station + ":" + seq.to_string()
      let (st, rp) = fx_proposal_state.get(pk).unwrap_or(("pending", None))
      let prop : Map[String, Json] = {
        "id": Json::string("prop-1"),
        "name": Json::string("chat-projects"),
        "note": Json::string("Agent 与人协作的 Chat 分类系统"),
        "refs": Json::array([Json::string("AFK-surf/monoid")]),
        "proposer": Json::string("agent"),
        "status": Json::string(st),
      }
      match rp {
        Some(p) => prop["resolvedProject"] = Json::string(p)
        None => ()
      }
      lm2["proposal"] = Json::object(prop)
      let msgs2 = msgs.copy()
      msgs2[last_i] = Json::object(lm2)
      out["messages"] = Json::array(msgs2)
    }
  }
  Json::object(out)
}

///|
/// Handle `projects`, `project`, and `tags` topics when `fx_projects_on` is true.
fn fx_projects_topic(name : String, params : Map[String, Json]) -> Json? {
  if !fx_projects_on.val {
    return None
  }
  let p = Some(Json::object(params))
  let cur = text(p, "cursor")
  let q = text(p, "q").to_lower()
  match name {
    "projects" => {
      let page1 : Array[Json] = [
        {
          "name": "monoid",
          "chatCount": 14,
          "runningCount": 2,
          "askingCount": 1,
          "unreadCount": 3,
          "latestActiveAt": 1795610000.0,
          "hasInfo": true,
          "refsCount": 2,
          "stations": ["ws1/st1"],
        },
        {
          "name": "board",
          "chatCount": 6,
          "runningCount": 0,
          "askingCount": 0,
          "unreadCount": 1,
          "latestActiveAt": 1795605000.0,
          "hasInfo": false,
          "refsCount": 1,
          "stations": ["ws1/st1"],
        },
      ]
      let page2 : Array[Json] = [
        {
          "name": Json::string(fx_stress_project_80),
          "chatCount": 3,
          "runningCount": 1,
          "askingCount": 0,
          "unreadCount": 0,
          "latestActiveAt": 1795600000.0,
          "hasInfo": true,
          "refsCount": 1,
          "stations": ["ws1/st1"],
        },
      ]
      let rows = if cur == "p2" { page2 } else { page1 }
      let filtered = if q == "" {
        rows
      } else {
        rows.filter(fn(r) { text(Some(r), "name").to_lower().contains(q) })
      }
      let out : Map[String, Json] = {
        "items": Json::array(filtered),
        "total": Json::number(3.0),
        "unclassifiedCount": Json::number(2.0),
        "crossCount": Json::number(1.0),
      }
      if cur == "" && q == "" {
        out["nextCursor"] = Json::string("p2")
      }
      Some(Json::object(out))
    }
    "tags" => {
      let page1 : Array[Json] = [
        { "name": "ui-review", "chatCount": 8, "latestActiveAt": 1795610000.0 },
        { "name": "ios", "chatCount": 5, "latestActiveAt": 1795608000.0 },
      ]
      let page2 : Array[Json] = [
        { "name": Json::string(fx_stress_tag_48), "chatCount": 2, "latestActiveAt": 1795601000.0 },
      ]
      let rows = if cur == "t2" { page2 } else { page1 }
      let filtered = if q == "" {
        rows
      } else {
        rows.filter(fn(r) { text(Some(r), "name").to_lower().contains(q) })
      }
      let out : Map[String, Json] = {
        "items": Json::array(filtered),
        "total": Json::number(3.0),
      }
      if cur == "" && q == "" {
        out["nextCursor"] = Json::string("t2")
      }
      Some(Json::object(out))
    }
    "project" => {
      let pname = text(p, "name")
      let (note, refs, rev) = fx_project_notes.get(pname).unwrap_or((
        "第一页项目说明。第二页补充说明。",
        ["AFK-surf/monoid", "https://github.com/AFK-surf/monoid"],
        "rev0000000000001",
      ))
      if cur == "" {
        // Page 1: first part of note + nextCursor "r:0"
        let out : Map[String, Json] = {
          "name": Json::string(pname),
          "note": Json::string(note),
          "refs": Json::array([]),
          "updatedAt": Json::number(1795610000.0),
          "infoRevision": Json::string(rev),
          "chatCount": Json::number(14.0),
          "runningCount": Json::number(2.0),
          "askingCount": Json::number(1.0),
          "unreadCount": Json::number(3.0),
          "nextCursor": Json::string("r:0"),
        }
        Some(Json::object(out))
      } else {
        // Page 2 (final): refs + consistent infoRevision, no nextCursor
        let out : Map[String, Json] = {
          "name": Json::string(pname),
          "refs": Json::array(refs.map(Json::string)),
          "updatedAt": Json::number(1795610000.0),
          "infoRevision": Json::string(rev),
          "chatCount": Json::number(14.0),
          "runningCount": Json::number(2.0),
          "askingCount": Json::number(1.0),
          "unreadCount": Json::number(3.0),
        }
        Some(Json::object(out))
      }
    }
    _ => None
  }
}

///|
/// Handle the 6 classification commands in `sffixture`. Returns `true` if handled.
fn fx_projects_call(
  f : Fixture,
  name : String,
  params : Json,
  done : (Result[Json, Json]) -> Unit,
) -> Bool {
  let s = Some(params)
  match name {
    "chat.classify" => {
      let station = text(s, "station")
      let thread = number(s, "thread").to_int()
      let key = station + ":s-c" + thread.to_string()
      match field(s, "project") {
        Some(String(p)) => {
          fx_chat_project[key] = Some(p)
          fx_chat_locked[key] = true
        }
        Some(Null) => {
          fx_chat_project[key] = None
          fx_chat_locked[key] = false
        }
        _ => ()
      }
      match field(s, "tags") {
        Some(Array(arr)) =>
          fx_chat_tags[key] = arr.filter_map(fn(x) {
            match x {
              String(t) => Some(t)
              _ => None
            }
          })
        _ => ()
      }
      f.changed()
      done(Ok(Json::object({ "ok": Json::boolean(true) })))
      true
    }
    "proposal.resolve" => {
      let station = text(s, "station")
      let entry_n = number(s, "entryN").to_int()
      let action = text(s, "action")
      let pk = station + ":" + entry_n.to_string()
      let (st, rp) = if action == "accept" {
        ("accepted", Some(match text(s, "name") { "" => "chat-projects"; n => n }))
      } else if action == "reassign" {
        ("reassigned", Some(text(s, "target")))
      } else if flag(s, "markCross") {
        ("dismissed", Some(""))
      } else {
        ("dismissed", None)
      }
      fx_proposal_state[pk] = (st, rp)
      f.changed()
      let prop : Map[String, Json] = { "status": Json::string(st) }
      match rp {
        Some(p) => prop["resolvedProject"] = Json::string(p)
        None => ()
      }
      let res : Map[String, Json] = {
        "ok": Json::boolean(true),
        "alreadyResolved": Json::boolean(false),
        "proposal": Json::object(prop),
      }
      done(Ok(Json::object(res)))
      true
    }
    "preset.setProject" => {
      let preset_id = text(s, "presetId")
      match field(s, "project") {
        Some(String(p)) => fx_preset_projects[preset_id] = p
        _ => fx_preset_projects.remove(preset_id)
      }
      f.changed()
      done(Ok(Json::object({ "ok": Json::boolean(true), "synced": Json::boolean(true) })))
      true
    }
    "project.updateInfo" => {
      let pname = text(s, "name")
      let (old_note, old_refs, _) = fx_project_notes.get(pname).unwrap_or((
        "第一页项目说明。第二页补充说明。",
        ["AFK-surf/monoid", "https://github.com/AFK-surf/monoid"],
        "rev0000000000001",
      ))
      let note = match field(s, "note") {
        Some(String(n)) => n
        _ => old_note
      }
      let refs = match field(s, "refs") {
        Some(Array(arr)) =>
          arr.filter_map(fn(x) {
            match x {
              String(u) => Some(u)
              _ => None
            }
          })
        _ => old_refs
      }
      fx_project_notes[pname] = (note, refs, "rev0000000000002")
      f.changed()
      done(Ok(Json::object({ "ok": Json::boolean(true) })))
      true
    }
    "project.rename" | "project.merge" => {
      let from = text(s, "from")
      let to = text(s, "to")
      match fx_project_notes.get(from) {
        Some(v) => {
          fx_project_notes.remove(from)
          if to != "" {
            fx_project_notes[to] = v
          }
        }
        None => ()
      }
      f.changed()
      done(Ok(Json::object({ "ok": Json::boolean(true), "peers": Json::array([]) })))
      true
    }
    _ => false
  }
}
