// Where the station stands with still.fail cloud (station/src/cloud/state.ts): <data>/mesh/cloud.json read and
// written as the TypeScript reads and writes it (its fields, their order, pretty JSON), and the lock's files beside it.

///|
/// cloud.json as read: its fields in the order JavaScript's object has them, as the TypeScript's `CloudState` is.
pub(all) struct CloudState {
  fields : Map[String, Json]
}

///|
pub fn CloudState::get(self : CloudState, k : String) -> Json? {
  self.fields.get(k)
}

///|
/// A text field ("" where it is none or not text).
pub fn CloudState::text(self : CloudState, k : String) -> String {
  match self.fields.get(k) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn CloudState::array(self : CloudState, k : String) -> Array[Json] {
  match self.fields.get(k) {
    Some(Array(xs)) => xs
    _ => []
  }
}

///|
/// The workspaces it joined besides its home one (`joined`), each as `joinedOf` makes it.
pub fn CloudState::joined(self : CloudState) -> Array[Json] {
  self.array("joined")
}

///|
pub fn CloudState::to_json(self : CloudState) -> Json {
  Json::object(self.fields)
}

///|
/// How long a change of a station's mode asked of the machine waits for the control plane to list it so.
pub let mode_pending_s : Double = 3600.0

///|
/// What a station `Cloud.unprotected` names is told (state.ts `UNPROTECTED`).
pub let unprotected_words : String = "that station is in this workspace but not protected by its safe mode (安全模式): it was offline or too old when safe mode was turned on. It is not a bug: stations safe mode protects run no remote tasks for an unprotected one, nor share with it, and it cannot be called from here. An owner or admin of the workspace protects it in the app's Settings → Security (设置 → 安全) with Protect (保护), updating it first if it is too old."

///|
/// What a device is told where a moved workspace's state is not here yet (state.ts `NOT_GIVEN`).
pub let not_given : String = "this station has not yet been given this workspace's settings by a trusted device: connect from a device of the workspace's owner, or wait for another of its stations to bring them"

///|
/// What a station answers an entry that lost its place (state.ts `FORK`).
pub let fork_words : String = "the entry disagrees with this station's lock (a fork)"

///|
pub fn rig_grants_path(data : String) -> String {
  join([data, "rig", "grants.json"])
}

///|
fn state_path(data : String) -> String {
  join([mesh_dir(data), "cloud.json"])
}

///|
/// The workspace's lock this station pinned (`{entries}`, from its genesis).
pub fn lock_path(data : String) -> String {
  join([mesh_dir(data), "lock.json"])
}

///|
/// The lock `enroll --lock <hash>` said to pin once the control plane brings it.
pub fn pending_lock_path(data : String) -> String {
  join([mesh_dir(data), "lock-pending.json"])
}

///|
/// A workspace's id as a file's name (state.ts `fileOf`).
fn file_of(ws : String) -> String {
  let plain = ws.length() >= 1 &&
    ws.length() <= 64 &&
    ws.iter().all(c => (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c == '-')
  if plain {
    ws
  } else {
    let h = hex_of(utf8_of(ws))
    if h.length() > 64 {
      h.unsafe_substring(start=0, end=64)
    } else {
      h
    }
  }
}

///|
pub fn joined_lock_path(data : String, ws : String) -> String {
  join([mesh_dir(data), "locks", "\{file_of(ws)}.json"])
}

///|
pub fn joined_pending_path(data : String, ws : String) -> String {
  join([mesh_dir(data), "locks", "\{file_of(ws)}.pending.json"])
}

///|
pub fn bodies_path(data : String, ws : String) -> String {
  join([mesh_dir(data), "locks", "\{file_of(ws)}.bodies.json"])
}

///|
fn turned_off_path(path : String) -> String {
  path + ".off"
}

///|
/// How far ahead of this station's clock a web device's `at` may be and still count.
let web_skew : Double = 600.0

///|
/// How many locks turned off keep what was kept of them beside.
let off_logs_most : Int = 4

///|
/// The locks turned off here: their genesis hashes, and what was kept of the last few.
priv struct OffRecord {
  genesis : Array[String]
  logs : Map[String, Kept]
}

///|
fn kept_json(k : Kept) -> Json {
  jobj([("entries", jarr(k.entries)), ("aside", jarr(k.aside))])
}

///|
fn read_off(disk : Disk, path : String) -> OffRecord {
  let none = { genesis: [], logs: Map([]) }
  guard disk.read(turned_off_path(path)).bind(parse) is Some(raw) else { return none }
  let logs : Map[String, Kept] = Map([])
  for kv in entries_of_obj(get(raw, "logs")) {
    let l = kv.1
    let entries = match get(l, "entries") {
      Some(Array(xs)) => xs.map(as_entry)
      _ => []
    }
    let aside = match get(l, "aside") {
      Some(Array(xs)) => xs.filter_map(as_entry)
      _ => []
    }
    if entries.length() > 0 && !entries.iter().any(e => e is None) {
      logs[kv.0] = { entries: entries.map(e => e.unwrap()), aside }
    }
  }
  let genesis = match get(raw, "genesis") {
    Some(Array(xs)) => xs.filter_map(x => if x is String(s) { Some(s) } else { None })
    _ => []
  }
  { genesis, logs }
}

///|
fn write_off(disk : Disk, path : String, off : OffRecord) -> Unit raise Failure {
  let genesis = if off.genesis.length() > 16 {
    off.genesis[off.genesis.length() - 16:].to_owned()
  } else {
    off.genesis
  }
  let kept_all = off.logs.keys().filter(h => genesis.contains(h)).collect()
  let kept = if kept_all.length() > off_logs_most {
    kept_all[kept_all.length() - off_logs_most:].to_owned()
  } else {
    kept_all
  }
  let out = [("genesis", jstrs(genesis))]
  if kept.length() > 0 {
    out.push(("logs", jobj(kept.map(h => (h, kept_json(off.logs.get(h).unwrap()))))))
  }
  disk.write(turned_off_path(path), stringify(jobj(out)))
}

///|
/// still.fail cloud's host before the rename, and its host now.
let former_host : String = "https://ember.3720.org"

///|
let host_now : String = "https://app.still.fail"

///|
/// cloud.json with the old host in it, written with the new one (state.ts `moveFormerHost`).
pub fn move_former_host(disk : Disk, data : String) -> Unit raise Failure {
  guard disk.read(state_path(data)) is Some(text) else { return }
  if !text.contains(former_host) {
    return
  }
  guard parse(text) is Some(Object(raw)) else { raise Failed("cloud.json is no JSON") }
  let moved = (url : Json) => match url {
    String(u) if u == former_host || u.has_prefix(former_host + "/") =>
      Json::string(host_now + u.unsafe_substring(start=former_host.length(), end=u.length()))
    other => other
  }
  if raw.get("origin") is Some(u) {
    raw["origin"] = moved(u)
  }
  if raw.get("relay_url") is Some(u) {
    raw["relay_url"] = moved(u)
  }
  if raw.get("relay_urls") is Some(Array(xs)) {
    raw["relay_urls"] = jarr(xs.map(moved))
  }
  if raw.get("stillfail_relays") is Some(Array(xs)) {
    raw["stillfail_relays"] = jarr(xs.map(moved))
  }
  disk.write(state_path(data), stringify_pretty(Json::object(raw)))
}

///|
fn is_hex32_json(v : Json?) -> Bool {
  match v {
    Some(String(s)) => is_hex32(s)
    _ => false
  }
}

///|
/// The rigs a file or a `state` frame names, what is malformed left out (state.ts `rigsOf`).
pub fn rigs_of(raw : Json?) -> Array[Json] {
  guard raw is Some(Array(xs)) else { return [] }
  let text = (v : Json?) => match v {
    Some(String(s)) => s
    _ => ""
  }
  xs.filter_map(r => {
    guard is_hex32_json(get(r, "id")) && get(r, "owner") is Some(String(owner)) && owner != "" else { return None }
    let out = [
      ("id", get(r, "id").unwrap()),
      ("name", jstr(text(get(r, "name")))),
      ("owner", jstr(owner)),
      ("owner_email", jstr(text(get(r, "owner_email")))),
      ("owner_name", jstr(text(get(r, "owner_name")))),
    ]
    if get(r, "version") is Some(String(v)) {
      out.push(("version", jstr(v)))
    }
    if get(r, "ips") is Some(Array(ips)) {
      let clean = ips.filter(x => x is String(_))
      if clean.length() > 0 {
        out.push(("ips", jarr(clean)))
      }
    }
    Some(jobj(out))
  })
}

///|
fn rig_self_of(raw : Json?) -> Json? {
  guard raw is Some(Object(_) as r) else { return None }
  guard get(r, "owner") is Some(String(owner)) && owner != "" && is_hex32_json(get(r, "person")) else { return None }
  let text = (k : String) => match get(r, k) {
    Some(String(s)) => s
    _ => ""
  }
  Some(jobj([("owner", jstr(owner)), ("owner_email", jstr(text("owner_email"))), ("owner_name", jstr(text("owner_name"))), ("person", get(r, "person").unwrap())]))
}

///|
/// The ways a file or a `state` frame says, none where it says none (state.ts `waysSaidOf`).
pub fn ways_said_of(raw : Json?) -> Json? {
  guard raw is Some(Object(_) as r) && get(r, "relays") is Some(Array(relays)) else { return None }
  let strings = (v : Json?) => match v {
    Some(Array(xs)) => xs.filter(x => x is String(_))
    _ => []
  }
  Some(jobj([("relays", jarr(strings(Some(jarr(relays))))), ("off", jarr(strings(get(r, "off"))))]))
}

///|
/// A revocation's shape (state.ts `isRevocation`).
pub fn is_revocation(r : Json) -> Bool {
  get(r, "kind") is Some(String(_)) &&
  get(r, "id") is Some(String(_)) &&
  (match get(r, "at") {
    Some(Number(n, ..)) => n == n.floor() && n >= 0.0 && n.abs() <= 1.7976931348623157e308
    _ => false
  })
}

///|
/// The joined workspaces a file or a `state` frame names, what is malformed left out (state.ts `joinedOf`).
pub fn joined_of(raw : Json?) -> Array[Json] {
  guard raw is Some(Array(xs)) else { return [] }
  xs.filter_map(j => {
    guard get(j, "workspace") is Some(String(ws)) && ws != "" else { return None }
    let out = [
      ("workspace", jstr(ws)),
      (
        "workspace_name",
        match get(j, "workspace_name") {
          Some(String(n)) => jstr(n)
          _ => jstr(ws)
        },
      ),
    ]
    if get(j, "workspace_emoji") is Some(String(e)) && e != "" {
      out.push(("workspace_emoji", jstr(e)))
    }
    if get(j, "workspace_icon") is Some(String(ic)) && ic != "" {
      out.push(("workspace_icon", jstr(ic)))
    }
    out.push(
      (
        "name",
        match get(j, "name") {
          Some(String(n)) => jstr(n)
          _ => jstr("")
        },
      ),
    )
    out.push(
      (
        "peers",
        match get(j, "peers") {
          Some(Array(_) as p) => p
          _ => jarr([])
        },
      ),
    )
    out.push(
      (
        "revocations",
        match get(j, "revocations") {
          Some(Array(rs)) => jarr(rs.filter(is_revocation))
          _ => jarr([])
        },
      ),
    )
    if get(j, "locked") is Some(True) {
      out.push(("locked", Json::boolean(true)))
    }
    if get(j, "rigs") is Some(Array(rs)) && rs.length() > 0 {
      out.push(("rigs", jarr(rigs_of(Some(jarr(rs))))))
    }
    if ways_said_of(get(j, "ways")) is Some(w) {
      out.push(("ways", w))
    }
    Some(jobj(out))
  })
}

///|
/// The state as the file has it, its optional parts filled as the Rust station's serde defaults fill them (state.ts
/// `readState`): none without a file; raises where it is no JSON.
pub fn read_state(disk : Disk, data : String) -> CloudState? raise Failure {
  guard disk.read(state_path(data)) is Some(text) else { return None }
  guard parse(text) is Some(raw) else { raise Failed("\{state_path(data)} is not valid JSON") }
  let m : Map[String, Json] = Map([])
  for kv in entries_of_obj(Some(raw)) {
    m[kv.0] = kv.1
  }
  let or_empty = (k : String) => match get(raw, k) {
    None | Some(Null) => jarr([])
    Some(v) => v
  }
  m["relay_urls"] = or_empty("relay_urls")
  m["peers"] = or_empty("peers")
  m["revocations"] = or_empty("revocations")
  match get(raw, "workspace_emoji") {
    Some(String(e)) if e != "" => m["workspace_emoji"] = jstr(e)
    _ => m.remove("workspace_emoji")
  }
  match get(raw, "workspace_icon") {
    Some(String(ic)) if ic != "" => m["workspace_icon"] = jstr(ic)
    _ => m.remove("workspace_icon")
  }
  if get(raw, "joined") is Some(j) {
    m["joined"] = jarr(joined_of(Some(j)))
  }
  if get(raw, "provider") is Some(p) {
    m["provider"] = jstr(if p is String("comma") { "comma" } else { "stillfail" })
  }
  if get(raw, "rigs") is Some(r) {
    m["rigs"] = jarr(rigs_of(Some(r)))
  }
  match ways_said_of(get(raw, "ways")) {
    Some(w) => m["ways"] = w
    None => m.remove("ways")
  }
  match get(raw, "stillfail_relays") {
    Some(Array(xs)) => m["stillfail_relays"] = jarr(xs.filter(x => x is String(_)))
    _ => m.remove("stillfail_relays")
  }
  match rig_self_of(get(raw, "rig")) {
    Some(r) => m["rig"] = r
    None => m.remove("rig")
  }
  let at_ok = (v : Json?) => match field(v, "at") {
    Some(Number(n, ..)) => safe_int(n)
    _ => false
  }
  match rig_self_of(get(raw, "rig_pending")) {
    Some(Object(p)) if at_ok(get(raw, "rig_pending")) => {
      let q = p.copy()
      q["at"] = field(get(raw, "rig_pending"), "at").unwrap()
      m["rig_pending"] = Json::object(q)
    }
    _ => m.remove("rig_pending")
  }
  if !(get(raw, "rig_due") is Some(True)) || !m.contains("rig_pending") {
    m.remove("rig_due")
  }
  if at_ok(get(raw, "full_pending")) {
    m["full_pending"] = jobj([("at", field(get(raw, "full_pending"), "at").unwrap())])
  } else {
    m.remove("full_pending")
  }
  Some({ fields: m })
}

///|
/// cloud.json's text for `s` (state.ts `stateText`): pretty JSON, field order as the Rust struct's.
pub fn state_text(s : CloudState) -> String {
  let out : Map[String, Json] = Map([])
  let put = (k : String) => if s.fields.get(k) is Some(v) { out[k] = v }
  put("provider")
  for k in ["origin", "station", "workspace", "workspace_name"] {
    put(k)
  }
  if s.fields.get("workspace_emoji") is Some(String(e)) && e != "" {
    out["workspace_emoji"] = jstr(e)
  }
  if s.fields.get("workspace_icon") is Some(String(ic)) && ic != "" {
    out["workspace_icon"] = jstr(ic)
  }
  for k in ["name", "relay_url", "relay_urls", "grant_keys", "peers", "revocations"] {
    put(k)
  }
  put("stillfail_relays")
  put("gateway_keys")
  put("removed_at")
  put("removed_code")
  if s.fields.get("joined") is Some(Array(xs)) && xs.length() > 0 {
    out["joined"] = jarr(xs)
  }
  if s.fields.get("rigs") is Some(Array(xs)) && xs.length() > 0 {
    out["rigs"] = jarr(xs)
  }
  put("ways")
  put("rig")
  put("rig_pending")
  if s.fields.get("rig_due") is Some(True) {
    out["rig_due"] = Json::boolean(true)
  }
  put("full_pending")
  stringify_pretty(Json::object(out))
}

///|
/// cloud.json written (state.ts `writeState`).
pub fn write_state(disk : Disk, data : String, s : CloudState) -> Unit raise Failure {
  disk.write(state_path(data), state_text(s))
}
