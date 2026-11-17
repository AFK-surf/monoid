// The routes a member's device asks of the station's lock, ways and stations' marks (station/src/mesh/serve.ts
// `lockRoute`, `lockPartRoute`, `waysRoute`, `stationMarksRoute`): each a status and a JSON body.

///|
/// JavaScript's `Number(s)` of a query's value (None: NaN).
pub fn js_number(s : String) -> Double? {
  let t = s.trim(chars=" \t\n\r").to_owned()
  if t == "" {
    return Some(0.0)
  }
  match (try { Ok(@json.parse(t)) } catch { e => Err(e) }) {
    Ok(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
fn safe_int(d : Double?) -> Int? {
  match d {
    Some(n) if n == n.floor() && n.abs() <= 9007199254740991.0 => Some(n.to_int())
    _ => None
  }
}

///|
/// A request's body as JSON, as `JSON.parse(body.toString("utf8") || "{}")`; None where it is not JSON.
pub fn body_json(body : Bytes) -> Json? {
  let text = @utf8.decode_lossy(body)
  let t = if text == "" { "{}" } else { text }
  Some(@json.parse(t)) catch {
    _ => None
  }
}

///|
fn opt_field(m : Map[String, Json], k : String, v : Json?) -> Unit {
  if v is Some(v) {
    m[k] = v
  }
}

///|
fn words(s : String) -> Json {
  { "error": Json::string(s) }
}

///|
fn off_of(t : Kept) -> Json? {
  if t.off.length() > 0 {
    Some(Json::array(t.off))
  } else {
    None
  }
}

///|
/// GET /lock?after=<seq> and POST /lock (serve.ts `lockRoute`).
pub async fn lock_route(k : Keeper, verb : String, query : Array[(String, String)], body : Bytes, viewer : Viewer) -> (Int, Json) {
  let ws = joined_of(k, viewer.workspace)
  if verb == "GET" {
    let after = match query.iter().find_first(kv => kv.0 == "after") {
      Some(kv) => js_number(kv.1)
      None => Some(-1.0)
    }
    let from = safe_int(after).unwrap_or(-1)
    let m : Map[String, Json] = {
      "head": lock_head_json(k, ws),
      "entries": Json::array((k.lock_after)(from, ws)),
    }
    if from >= 0 {
      if (k.lock_after)(from - 1, ws).get(0) is Some(at) && field(at, "seq") == Some(Json::number(from.to_double())) {
        m["after_hash"] = Json::string((k.hash_of)(at))
      }
    }
    m["takes"] = ["person"]
    m["serves"] = [
      "person", "devices", "told", "forks", "bodies", "logs", "builds", "carried", "bind",
      "rootout", "heads",
    ]
    m["builds"] = (k.builds_of)(lock_device_ids(k, ws))
    return (200, Json::object(m))
  }
  if verb != "POST" {
    return (405, words("GET or POST"))
  }
  guard body_json(body) is Some(said) else { return (400, words("invalid JSON")) }
  let logs = field(said, "logs").unwrap_or(Json::null())
  let bodies = field(said, "bodies").unwrap_or(Json::null())
  let keep = field(said, "keep") == Some(Json::boolean(true))
  if field(said, "person") is Some(Array(chain)) {
    return person_told(k, ws, viewer, chain, keep~)
  }
  let raw = match field(said, "entries") { Some(Array(a)) => a; _ => [] }
  let entries = []
  for r in raw {
    match (k.as_entry)(r) {
      Some(e) => entries.push(e)
      None => return (400, words("entries: lock entries"))
    }
  }
  if entries.length() == 0 {
    return (400, words("entries: lock entries"))
  }
  try {
    let (exists, _) = (k.chain)(ws)
    if !exists {
      if viewer.role != "owner" {
        return (403, words("only the workspace's owner turns its lock on"))
      }
      let who = who_of(viewer, viewer.device)
      if entries.iter().any(e => field(e, "kind") == Some(Json::string("moved"))) {
        let w = if viewer.workspace != "" { viewer.workspace } else { (k.home)().unwrap_or("") }
        try {
          (k.pin_brought)(ws, w, entries, logs, bodies, who, (k.station)())
        } catch {
          e => return (403, words(words_of(e)))
        }
        return (200, { "taken": Json::number(entries.length().to_double()), "head": lock_head_json(k, ws) })
      }
      let folded = (k.fold)(entries, Some((k.now_secs)()))
      ignore((k.admit)(folded, who, (k.now_secs)()))
      if folded.members.get(viewer.sub) != Some("owner") {
        return (403, words("the lock is brought by its owner"))
      }
    }
    let t = (k.keep_lock)(entries, ws, keep)
    let head = lock_head_json(k, ws)
    let off = off_of(t)
    let h = (k.hash_of)(entries[entries.length() - 1])
    let answer = (code : Int, error : String?) => {
      let m : Map[String, Json] = Map([])
      match error {
        Some(e) => m["error"] = Json::string(e)
        None => m["taken"] = Json::number(t.taken.to_double())
      }
      m["head"] = head
      opt_field(m, "off", off)
      (code, Json::object(m))
    }
    for e in (k.lock_after)(-1, ws) {
      if (k.hash_of)(e) == h {
        return answer(200, None)
      }
    }
    let why = t.off
      .iter()
      .find_first(o => field(o, "hash") == Some(Json::string(h)))
      .bind(o => match field(o, "why") { Some(String(w)) => Some(w); _ => None })
    if why == Some("beaten") || why == Some("below") || why == Some("again") {
      return answer(409, Some(fork_words))
    }
    if t.taken > 0 {
      return answer(200, None)
    }
    answer(409, Some(t.refusal.unwrap_or(fork_words)))
  } catch {
    e => (409, { "error": Json::string(words_of(e)), "head": lock_head_json(k, ws) })
  }
}

///|
/// GET /ways and POST /ways (serve.ts `waysRoute`).
pub async fn ways_route(k : Keeper, verb : String, body : Bytes, viewer : Viewer) -> (Int, Json) {
  let ws = if viewer.workspace != "" { viewer.workspace } else { (k.home)().unwrap_or("") }
  if verb == "GET" {
    return (200, (k.ways_view)(ws))
  }
  if verb != "POST" {
    return (405, words("GET or POST"))
  }
  if read_only(viewer.role) {
    return (403, words("read-only members cannot change this workspace's ways"))
  }
  guard body_json(body) is Some(said) else { return (400, words("invalid JSON")) }
  try {
    let by = if viewer.name != "" {
      Some(viewer.name)
    } else if viewer.email != "" {
      Some(viewer.email)
    } else {
      None
    }
    match (field(said, "relays"), field(said, "way"), field(said, "on")) {
      (Some(Array(_) as relays), _, _) => (200, (k.ways_set_relays)(ws, relays, by))
      (_, Some(String(way)), Some(True)) => (200, (k.ways_set_way)(ws, way, true))
      (_, Some(String(way)), Some(False)) => (200, (k.ways_set_way)(ws, way, false))
      _ => (400, words("relays: a list of URLs, or way and on"))
    }
  } catch {
    WaysRefusal(m) => (if m.has_prefix("the last relay") { 409 } else { 400 }, words(m))
    e => raise e
  }
}

///|
/// The ways' refusal (mesh/ways.ts `WaysRefusal`), raised by what keeps them.
pub(all) suberror WaysRefusal {
  WaysRefusal(String)
}

///|
/// A mark's refusal (mesh/station-marks.ts `MarkRefusal`), raised by what keeps them.
pub(all) suberror MarkRefusal {
  MarkRefusal(String)
}

///|
/// GET /station-marks and PUT /station-mark (serve.ts `stationMarksRoute`).
pub async fn station_marks_route(k : Keeper, verb : String, body : Bytes, viewer : Viewer, own : Bool) -> (Int, Json) {
  let ws = if viewer.workspace != "" { viewer.workspace } else { (k.home)().unwrap_or("") }
  if !own {
    return if verb == "GET" { (200, { "marks": (k.marks_of)(ws) }) } else { (405, words("GET")) }
  }
  if verb != "PUT" {
    return (405, words("PUT"))
  }
  if !manages_station(viewer.role) {
    return (403, words("only the workspace's owners and admins change a station's name and icon"))
  }
  guard body_json(body) is Some(said) else { return (400, words("invalid JSON")) }
  // (`typeof said === "object"`: a list too, which names none of them)
  guard said is (Object(_) | Array(_)) else { return (400, words("name, emoji, icon")) }
  try {
    let named = match (k.membership)(ws) {
      Some((name, _)) if name != "" => name
      _ => (k.name)()
    }
    let changed : Map[String, Json] = Map([])
    for key in ["name", "emoji", "icon"] {
      if field(said, key) is Some(v) {
        changed[key] = v
      }
    }
    let was : Json = { "name": Json::string(named), "emoji": "", "icon": "" }
    (200, (k.marks_change)(Json::object(changed), was))
  } catch {
    MarkRefusal(m) => (400, words(m))
    e => raise e
  }
}

///|
/// How far a person's chain gone by goes: its last entry's place and hash.
async fn person_head(k : Keeper, chain : Array[Json]) -> Json {
  {
    "seq": Json::number((chain.length() - 1).to_double()),
    "hash": if chain.length() == 0 { Json::null() } else { Json::string((k.hash_of)(chain[chain.length() - 1])) },
  }
}

///|
async fn person_told(k : Keeper, ws : String?, viewer : Viewer, chain : Array[Json], keep? : Bool = false) -> (Int, Json) {
  let pin = match (k.locked)(ws) {
    Some({ state: Some(s), .. }) => s.persons.get(viewer.sub)
    _ => None
  }
  guard pin is Some(pin) else { return (409, words("no lock of their own bound here")) }
  try {
    let (genesis, _) = (k.person_fold)(chain, Some(viewer.sub))
    if genesis != pin {
      return (409, words("not the lock bound here"))
    }
    let (_, t) = take_chain(k, Json::array(chain), Some(viewer.sub), Some(viewer.workspace), fork=keep)
    let m : Map[String, Json] = Map([])
    if !t.on {
      m["error"] = Json::string(at_odds)
      m["head"] = person_head(k, t.chain)
    }
    if t.off.length() > 0 {
      m["off"] = Json::array(t.off)
    }
    (if t.on { 200 } else { 409 }, Json::object(m))
  } catch {
    e => (409, words(words_of(e)))
  }
}

///|
/// The person logs of `ws` a device is given, those of `only` alone where it says.
async fn logs_given(k : Keeper, ws : String?, only : Array[String]?) -> Json {
  let out = []
  for genesis in (k.logs_of)(ws) {
    if only is Some(o) && !o.contains(genesis) {
      continue
    }
    if (k.person_kept)(genesis) is Some(entries) {
      out.push(({ "genesis": Json::string(genesis), "entries": Json::array(entries) } : Json))
    }
  }
  Json::array(out)
}

///|
fn strings_of(x : Json?) -> Array[String] {
  match x {
    Some(Array(a)) => a.filter_map(y => match y { String(s) => Some(s); _ => None })
    _ => []
  }
}

///|
/// GET/POST /lock/person, GET/POST /lock/bodies, GET /lock/logs, GET /lock/heads, POST /lock/given, GET /lock/devices
/// (serve.ts `lockPartRoute`).
pub async fn lock_part_route(k : Keeper, part : String, verb : String, body : Bytes, viewer : Viewer) -> (Int, Json) {
  if part == "person" {
    if verb == "GET" {
      let chains = own_chains_of(k, viewer.sub, Some(viewer.workspace)).map(c => ({ "genesis": Json::string(c.0), "entries": Json::array(c.1) } : Json))
      return (200, {
        "chains": Json::array(chains),
        "serves": ["logs", "builds", "carried", "bind", "rootout"],
        "builds": (k.builds_of)(person_device_ids(k, viewer.sub)),
      })
    }
    if verb != "POST" {
      return (405, words("GET or POST"))
    }
    guard body_json(body) is Some(said) else { return (400, words("invalid JSON")) }
    try {
      let (genesis, t) = take_chain(k, field(said, "chain").unwrap_or(Json::null()), Some(viewer.sub), Some(viewer.workspace), fork=field(said, "keep") == Some(Json::boolean(true)))
      let m : Map[String, Json] = Map([])
      if t.on {
        m["genesis"] = Json::string(genesis)
        m["length"] = Json::number(t.chain.length().to_double())
      } else {
        m["error"] = Json::string(at_odds)
        m["head"] = person_head(k, t.chain)
      }
      if t.off.length() > 0 {
        m["off"] = Json::array(t.off)
      }
      if field(said, "bodies") is Some(Array(bodies)) {
        guard bodies_taken(k, viewer, bodies) is Object(b) else { return (500, words("bodies")) }
        for key, v in b {
          m[key] = v
        }
      }
      return (if t.on { 200 } else { 409 }, Json::object(m))
    } catch {
      e => return (409, words(words_of(e)))
    }
  }
  let ws = if part == "bodies" || part == "logs" || part == "heads" || part == "given" {
    joined_of(k, viewer.workspace)
  } else {
    None
  }
  if part == "bodies" {
    if verb == "GET" {
      if !gives_device(k, ws, viewer) {
        return (200, { "bodies": [], "lacking": [] })
      }
      return (200, { "bodies": Json::array((k.bodies)(ws).map(b => b.1)), "lacking": (k.lacking)(ws) })
    }
    if verb != "POST" {
      return (405, words("GET or POST"))
    }
    guard body_json(body) is Some(said) else { return (400, words("invalid JSON")) }
    guard field(said, "bodies") is Some(Array(bodies)) && bodies.length() <= bodies_most else {
      return (400, words("bodies: the statements' bodies"))
    }
    return (200, bodies_taken(k, viewer, bodies))
  }
  if part == "logs" && verb == "GET" {
    if !gives_device(k, ws, viewer) {
      return (200, { "chains": [] })
    }
    return (200, { "chains": logs_given(k, ws, None) })
  }
  if part == "heads" && verb == "GET" {
    if !gives_device(k, ws, viewer) {
      return (200, { "logs": [], "bodies": [], "lacking": [] })
    }
    let logs = []
    for genesis in (k.logs_of)(ws) {
      match (k.person_kept)(genesis) {
        Some(entries) if entries.length() > 0 =>
          logs.push(Json::array([Json::string(genesis), Json::string((k.hash_of)(entries[entries.length() - 1]))]))
        _ => ()
      }
    }
    return (200, {
      "logs": Json::array(logs),
      "bodies": Json::array((k.bodies)(ws).map(b => Json::string(b.0))),
      "lacking": (k.lacking)(ws),
    })
  }
  if part == "given" {
    if verb != "POST" {
      return (405, words("POST"))
    }
    guard body_json(body) is Some(said) else { return (400, words("invalid JSON")) }
    let logs = strings_of(field(said, "logs"))
    let hashes = strings_of(field(said, "bodies"))
    if !gives_device(k, ws, viewer) {
      return (200, { "chains": [], "bodies": [] })
    }
    let all = Map::from_array((k.bodies)(ws))
    let seen = []
    let given = []
    for h in hashes {
      if seen.contains(h) {
        continue
      }
      seen.push(h)
      if all.get(h) is Some(b) {
        given.push(b)
      }
    }
    return (200, {
      "chains": if logs.length() == 0 { Json::array([]) } else { logs_given(k, ws, Some(logs)) },
      "bodies": Json::array(given),
    })
  }
  if part == "devices" && verb == "GET" {
    let manages = viewer.role == "owner" || viewer.role == "admin"
    return (200, {
      "devices": Json::array(k.seen.of(viewer.workspace, (k.now_secs)(), viewer.sub, manages).map(s => s.to_json())),
    })
  }
  (404, words("no such route"))
}
