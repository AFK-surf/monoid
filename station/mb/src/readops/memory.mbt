// The agents' memory for the pages (station/test/reference/memory.ts `memory`, GET /memory): the global MEMORY.md and the
// shared skills of the home workspace's agents' home, or of a joined workspace's (<agent home>/workspaces/<ws>).

///|
/// The skills the station brings, rewritten at every start (memory.ts BUILTIN).
let builtin_skills : Array[String] = [
  "stillfail-chats", "stillfail-jobs", "stillfail-show", "stillfail-viz", "stillfail-browser", "stillfail-login", "stillfail-vault",
  "stillfail-cron", "stillfail-github-ci", "stillfail-retire", "stillfail-move", "stillfail-leading", "stillfail-projects", "stillfail-feedback",
]

///|
/// What a project memory's description starts with.
let project_prefix = "项目记忆："

///|
fn line_terminator(c : Int) -> Bool {
  c == 0x0a || c == 0x0d || c == 0x2028 || c == 0x2029
}

///|
/// memory.ts `front`: a SKILL.md's frontmatter field (`key: value`), if it has one.
fn front(text : String, key : String) -> String? {
  guard text.has_prefix("---\n") else { return None }
  let body = text.view(start_offset=4).to_owned()
  guard body.find("\n---") is Some(end) else { return None }
  for part in body.view(end_offset=end).to_owned().split("\n") {
    let raw = part.to_owned()
    let line = if raw.has_suffix("\r") { raw.view(end_offset=raw.length() - 1).to_owned() } else { raw }
    let head = key + ":"
    if line.has_prefix(head) {
      let value = @jscase.trim(line.view(start_offset=head.length()).to_owned())
      let mut a = 0
      while a < value.length() && value.unsafe_charcode_at(a) == '"' {
        a += 1
      }
      let mut b = value.length()
      while b > a && value.unsafe_charcode_at(b - 1) == '"' {
        b -= 1
      }
      return Some(value.view(start_offset=a, end_offset=b).to_owned())
    }
  }
  None
}

///|
/// /^SKILL\.conflict-.*\.md$/
fn is_conflict(name : String) -> Bool {
  let head = "SKILL.conflict-"
  guard name.has_prefix(head) && name.has_suffix(".md") && name.length() >= head.length() + 3 else { return false }
  for i in head.length()..<(name.length() - 3) {
    if line_terminator(name.unsafe_charcode_at(i)) {
      return false
    }
  }
  true
}

///|
/// The share a link into <data>/share/<id>/skill names (/\/share\/(sh-[0-9a-z]+)\/skill$/).
fn share_of_link(target : String) -> String? {
  guard target.has_suffix("/skill") else { return None }
  let dir = target.view(end_offset=target.length() - "/skill".length()).to_owned()
  let cut = match dir.rev_find("/") {
    Some(i) => i
    None => return None
  }
  let id = dir.view(start_offset=cut + 1).to_owned()
  guard id.has_prefix("sh-") && id.length() > 3 else { return None }
  for i in 3..<id.length() {
    let c = id.unsafe_charcode_at(i)
    guard (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') else { return None }
  }
  guard dir.view(end_offset=cut).to_owned().has_suffix("/share") else { return None }
  Some(id)
}

///|
fn jget(v : @jsjson.JValue?, k : String) -> @jsjson.JValue? {
  match v {
    Some(Obj(_) as o) => o.get(k)
    _ => None
  }
}

///|
fn array_or_null(v : @jsjson.JValue?) -> Json {
  match v {
    Some(Arr(_) as a) => to_json(a)
    _ => Json::null()
  }
}

///|
/// memory.ts `sharing`: shared from here (config.json `sharedSkills`), a copy of another station's (its link into
/// <data>/share/<id>/skill), or neither.
fn sharing(host : @host.Host, data : String, sep : String, raw : @jsjson.JValue, dir : String, name : String) -> Json raise {
  let hosted = jget(jget(Some(raw), "sharedSkills"), name)
  let hosted_id = match hosted {
    Some(Str(s)) => Some(s)
    _ =>
      match jget(hosted, "id") {
        Some(Str(s)) => Some(s)
        _ => None
      }
  }
  if hosted_id is Some(id) {
    let station = match jget(Some(read_json(host, join_path(sep, data, "mesh/cloud.json"))), "station") {
      None | Some(Null) => Json::string("")
      Some(v) => to_json(v)
    }
    let conflicts = match read_dir(host, join_path(sep, dir, name)) {
      Some(names) => names.filter(is_conflict).map(Json::string)
      None => []
    }
    let state = match jget(jget(Some(read_json(host, join_path(sep, data, "share/state.json"))), "hosted"), id) {
      None | Some(Null) => @jsjson.JValue::Obj([])
      Some(v) => v
    }
    let missing = match jget(Some(state), "missing") {
      Some(Obj(_) | Arr(_)) as m => m
      _ => None
    }
    let missed = entries_of(missing).map(e => e.0)
    let told = match jget(Some(state), "told") {
      Some(Obj(_) | Arr(_)) as t => t
      _ => None
    }
    let users = entries_of(told).filter_map(e => match e.1 {
      Num(v) if v >= 0.0 && !missed.contains(e.0) => Some(Json::string(e.0))
      _ => None
    })
    let out : Map[String, Json] = {
      "id": Json::string(id),
      "role": "host",
      "host": station,
      "allow": array_or_null(jget(hosted, "allow")),
      "conflicts": Json::array(conflicts),
      "users": Json::array(users),
      "missing": Json::array(
        entries_of(missing).filter_map(e => match e.1 {
          Str(why) => Some({ "station": Json::string(e.0), "why": Json::string(@jsjson.sanitize_str(why)) })
          _ => None
        }),
      ),
    }
    if jget(Some(state), "unread") is Some(Str(u)) {
      out["unread"] = Json::string(@jsjson.sanitize_str(u))
    }
    return Json::object(out)
  }
  let link = match host.shell_sync("fs.readlink", { "path": Json::string(join_path(sep, dir, name)) }) {
    String(t) => t
    _ => return Json::null()
  }
  guard share_of_link(link) is Some(id) else { return Json::null() }
  let had = jget(jget(Some(read_json(host, join_path(sep, data, "share/state.json"))), "borrowed"), id)
  guard truthy(had) else { return Json::null() }
  {
    "id": Json::string(id),
    "role": "user",
    "host": match jget(had, "host") {
      None | Some(Null) => Json::string("")
      Some(v) => to_json(v)
    },
    "allow": array_or_null(jget(had, "allow")),
    "conflicts": [],
  }
}

///|
/// memory.ts `skillFiles`: the Markdown files beside a SKILL.md but the edits kept from an older copy, by name.
fn skill_files(host : @host.Host, sep : String, dir : String) -> Array[Json] raise {
  guard read_dir(host, dir) is Some(names) else { return [] }
  let picked = names.filter(n => n.has_suffix(".md") && n != "SKILL.md" && !n.has_prefix("SKILL.conflict-"))
  picked.sort_by(by_bytes)
  let out = []
  for name in picked {
    if read_text(host, join_path(sep, dir, name), strict=true) is Some(text) {
      out.push(({ "name": Json::string(name), "text": Json::string(text) } : Json))
    }
  }
  out
}

///|
priv struct MemRec {
  hash : String
  at : Double
  by : String
  prev : Array[String]
}

///|
fn is_hex64(s : String) -> Bool {
  guard s.length() == 64 else { return false }
  for i in 0..<64 {
    let c = s.unsafe_charcode_at(i)
    guard (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') else { return false }
  }
  true
}

///|
fn rec_of(raw : @jsjson.JValue?) -> MemRec? {
  guard raw is Some(Obj(_)) else { return None }
  let hash = match jget(raw, "hash") {
    Some(Str(s)) => s
    _ => return None
  }
  let at = match jget(raw, "at") {
    Some(Num(n)) if !n.is_nan() && !n.is_inf() && n.floor() == n && n > 0.0 && n <= 9007199254740991.0 => n
    _ => return None
  }
  let by = match jget(raw, "by") {
    Some(Str(s)) => s
    _ => return None
  }
  guard by != "" else { return None }
  let prev = match jget(raw, "prev") {
    Some(Arr(xs)) =>
      xs.filter_map(x => match x {
        Str(s) => {
          let t = s
          if is_hex64(t) { Some(t) } else { None }
        }
        _ => None
      })
    _ => return None
  }
  Some({ hash, at, by, prev })
}

///|
fn newer_rec(a : MemRec, b : MemRec) -> Bool {
  if a.at != b.at {
    a.at > b.at
  } else if a.by != b.by {
    by_bytes(a.by, b.by) > 0
  } else {
    by_bytes(a.hash, b.hash) > 0
  }
}

///|
fn peer_name_in(peers : @jsjson.JValue?, station : String) -> String? {
  guard peers is Some(Arr(xs)) else { return None }
  for x in xs {
    if jget(Some(x), "id") is Some(Str(id)) && id == station {
      if jget(Some(x), "name") is Some(Str(n)) {
        let trimmed = @jscase.trim(n)
        if trimmed != "" {
          return Some(trimmed)
        }
      }
      break
    }
  }
  None
}

///|
fn station_name_of(cloud : @jsjson.JValue, ws : String?, station : String) -> String {
  let self_id = match jget(Some(cloud), "station") {
    Some(Str(s)) => s
    _ => ""
  }
  if ws is Some(w) && jget(Some(cloud), "joined") is Some(Arr(js)) {
    for j in js {
      if jget(Some(j), "workspace") is Some(Str(jw)) && jw == w {
        if peer_name_in(jget(Some(j), "peers"), station) is Some(n) {
          return n
        }
        if station == self_id && jget(Some(j), "name") is Some(Str(sn)) {
          let trimmed = @jscase.trim(sn)
          if trimmed != "" {
            return trimmed
          }
        }
        break
      }
    }
  }
  if peer_name_in(jget(Some(cloud), "peers"), station) is Some(n) {
    return n
  }
  if station == self_id && jget(Some(cloud), "name") is Some(Str(sn)) {
    let trimmed = @jscase.trim(sn)
    if trimmed != "" {
      return trimmed
    }
  }
  if station.length() > 8 {
    station.view(end_offset=8).to_owned()
  } else {
    station
  }
}

///|
fn prev_blob(host : @host.Host, data : String, sep : String, rec : MemRec?) -> String? raise {
  match rec {
    Some(r) if r.prev.length() > 0 =>
      read_text(host, join_path(sep, data, "share/memory/blobs/" + r.prev[0]), strict=true)
    _ => None
  }
}

///|
/// memory.ts `listSkills`; `shares`: whether its skills may be shared with other stations (the home workspace's only).
fn list_skills(
  host : @host.Host,
  data : String,
  sep : String,
  raw : @jsjson.JValue,
  cloud : @jsjson.JValue,
  ws : String?,
  kept_files : @jsjson.JValue?,
  home : String,
  shares : Bool,
) -> Array[Json] raise {
  let dir = join_path(sep, home, "skills")
  guard read_dir(host, dir) is Some(names) else { return [] }
  let skills : Array[(String, Bool, Bool, Json)] = []
  for name in names {
    guard read_text(host, join_path(sep, join_path(sep, dir, name), "SKILL.md"), strict=true) is Some(text) else { continue }
    let description = front(text, "description").unwrap_or("")
    let builtin = builtin_skills.contains(name)
    let project = description.has_prefix(project_prefix)
    let files = skill_files(host, sep, join_path(sep, dir, name))
    let share = if builtin || !shares { Json::null() } else { sharing(host, data, sep, raw, dir, name) }
    let skill_rec = if builtin { None } else { rec_of(jget(kept_files, "skills/" + name + "/SKILL.md")) }
    let mut latest = skill_rec
    if !builtin {
      for f in files {
        if f.value("name") is Some(String(fname)) {
          let frec = rec_of(jget(kept_files, "skills/" + name + "/" + fname))
          if frec is Some(fr) {
            match latest {
              None => latest = Some(fr)
              Some(cur) if newer_rec(fr, cur) => latest = Some(fr)
              _ => ()
            }
          }
        }
      }
    }
    let prev = prev_blob(host, data, sep, skill_rec)
    let obj : Map[String, Json] = {
      "name": Json::string(name),
      "description": Json::string(description),
      "project": Json::boolean(project),
      "builtin": Json::boolean(builtin),
      "text": Json::string(text),
      "files": Json::array(files),
      "share": share,
    }
    if latest is Some(lat) {
      obj["at"] = Json::number(lat.at)
      obj["by"] = Json::string(station_name_of(cloud, ws, lat.by))
      if prev is Some(p) {
        obj["prev"] = Json::string(p)
      }
    }
    skills.push((name, builtin, project, Json::object(obj)))
  }
  let rank = (b : Bool) => if b { 1 } else { 0 }
  skills.sort_by((a, b) => {
    let by = rank(a.1) - rank(b.1)
    if by != 0 {
      return by
    }
    let by = rank(!a.2) - rank(!b.2)
    if by != 0 {
      return by
    }
    by_bytes(a.0, b.0)
  })
  skills.map(s => s.3)
}

///|
/// The workspace ids memory.ts takes (/^[0-9A-Za-z_-]{1,128}$/).
fn workspace_id(ws : String) -> Bool {
  ws.length() >= 1 &&
  ws.length() <= 128 &&
  ws.iter().all(c => (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c == '-')
}

///|
/// GET /memory: the home workspace's, or with `workspace` that joined workspace's (none yet: empty).
pub fn memory(host : @host.Host, data : String, sep : String, args : Json) -> Json raise {
  let raw = read_json(host, join_path(sep, data, "config.json"))
  let ws = match args.value("workspace") {
    Some(String(w)) => Some(w)
    _ => None
  }
  if ws is Some(w) && !workspace_id(w) {
    raise Refused(400, "not a workspace id")
  }
  let cloud = read_json(host, join_path(sep, data, "mesh/cloud.json"))
  let ws_id = match ws {
    Some(w) => w
    None =>
      match jget(Some(cloud), "workspace") {
        Some(Str(s)) => s
        _ => ""
      }
  }
  let kept_files = if ws_id != "" && workspace_id(ws_id) {
    jget(Some(read_json(host, join_path(sep, data, "share/memory/" + ws_id + ".json"))), "files")
  } else {
    None
  }
  let agent = join_path(sep, data, match jget(Some(raw), "agentHome") {
    Some(Str(h)) => h
    _ => "agent"
  })
  let home = match ws {
    Some(w) => join_path(sep, join_path(sep, agent, "workspaces"), w)
    None => agent
  }
  let path = join_path(sep, home, "MEMORY.md")
  let global_obj : Map[String, Json] = {
    "path": Json::string(path),
    "text": Json::string(read_text(host, path, strict=true).unwrap_or("")),
  }
  let global_rec = rec_of(jget(kept_files, "MEMORY.md"))
  let global_prev = prev_blob(host, data, sep, global_rec)
  if global_rec is Some(gr) {
    global_obj["at"] = Json::number(gr.at)
    global_obj["by"] = Json::string(station_name_of(cloud, ws, gr.by))
    if global_prev is Some(gp) {
      global_obj["prev"] = Json::string(gp)
    }
  }
  {
    "global": Json::object(global_obj),
    "skills": Json::array(list_skills(host, data, sep, raw, cloud, ws, kept_files, home, ws is None)),
  }
}
