// What cloud_net reads of where the station stands with its control plane (station/src/cloud/state.ts `Cloud`): its
// workspaces and rosters, its relays, what the plane kept of each workspace's ways, and its changes as they happen.
// Given as a view (`CloudView`), so the locks' part (cloud_lock: which joined workspaces count, which of the plane's
// roster a lock lets in) is the view's to say; `StateCloud` is the view of a cloud.json with no lock pinned, which is
// what the tests and the program's harness give and what the station is before any lock.

///|
/// One of the workspaces the station is in, its home one or a joined one: `peers` the roster as the plane said it (each
/// a JSON object whose `id` is a station's).
pub(all) struct Membership {
  workspace : String
  home : Bool
  peers : Array[Json]
}

///|
/// A workspace's own relays and the ways its devices do not take, as still.fail cloud kept them (state.ts `WaysSaid`).
pub(all) struct WaysSaid {
  relays : Array[String]
  off : Array[String]
}

///|
pub fn WaysSaid::to_json(self : WaysSaid) -> Json {
  {
    "relays": Json::array(self.relays.map(Json::string)),
    "off": Json::array(self.off.map(Json::string)),
  }
}

///|
/// What the station's cloud state says, read anew at each use.
pub(all) struct CloudView {
  /// This station's id; None before it is enrolled (no cloud.json).
  station : () -> String?
  /// Its control plane's origin; None before it is enrolled.
  origin : () -> String?
  /// Whether this machine is a rig (only runs tasks).
  is_rig : () -> Bool
  /// still.fail's own relays as the plane says them apart (`stillfail_relays`); None from a plane of before.
  stillfail_relays : () -> Array[String]?
  /// still.fail's relays (`Cloud.relays`: `relay_urls`, else `relay_url`; what is no URL left out).
  relays : () -> Array[String]
  /// Every workspace the station is in now, its home one first.
  memberships : () -> Array[Membership]
  membership : (String) -> Membership?
  /// The rigs of a workspace this station sends work to, by id.
  rigs : (String) -> Array[String]
  ways_said : (String) -> WaysSaid?
  /// Whether `peers` is taken as the workspace's stations.
  peers_current : () -> Bool
  /// Told each change; what it returns stops it.
  listen : (() -> Unit) -> () -> Unit
}

///|
/// Listeners told in the order they came, each told even where one before it stops another.
pub struct Listeners {
  priv fs : Map[Int, () -> Unit]
  priv mut next : Int
}

///|
pub fn Listeners::new() -> Listeners {
  { fs: Map([]), next: 0 }
}

///|
pub fn Listeners::add(self : Listeners, f : () -> Unit) -> () -> Unit {
  self.next += 1
  let id = self.next
  self.fs[id] = f
  fn() { self.fs.remove(id) }
}

///|
pub fn Listeners::tell(self : Listeners) -> Unit {
  let now = self.fs.values().collect()
  for f in now {
    f()
  }
}

///|
/// Listeners told a value (a workspace's id, a station's).
pub struct Told[X] {
  priv fs : Map[Int, (X) -> Unit]
  priv mut next : Int
}

///|
pub fn[X] Told::new() -> Told[X] {
  { fs: Map([]), next: 0 }
}

///|
pub fn[X] Told::add(self : Told[X], f : (X) -> Unit) -> () -> Unit {
  self.next += 1
  let id = self.next
  self.fs[id] = f
  fn() { self.fs.remove(id) }
}

///|
pub fn[X] Told::tell(self : Told[X], x : X) -> Unit {
  let now = self.fs.values().collect()
  for f in now {
    f(x)
  }
}

// ── JSON as the TypeScript reads it ──

///|
fn field(j : Json, name : String) -> Json? {
  match j {
    Object(m) => m.get(name)
    _ => None
  }
}

///|
fn text_of(j : Json?) -> String? {
  match j {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn array_of(j : Json?) -> Array[Json]? {
  match j {
    Some(Array(a)) => Some(a)
    _ => None
  }
}

///|
/// The strings of an array (what is not one left out).
fn strings_of(j : Json?) -> Array[String] {
  match j {
    Some(Array(a)) =>
      a.filter_map(x => match x {
        String(s) => Some(s)
        _ => None
      })
    _ => []
  }
}

///|
/// A number that is a safe integer (`Number.isSafeInteger`).
fn safe_int(j : Json?) -> Int64? {
  match j {
    Some(Number(n, ..)) =>
      if n == n.floor() && n.abs() <= 9007199254740991.0 {
        Some(n.to_int64())
      } else {
        None
      }
    _ => None
  }
}

///|
/// A number that is an integer (`Number.isInteger`).
fn is_integer(j : Json?) -> Bool {
  match j {
    Some(Number(n, ..)) => n == n.floor() && n.abs() < 1.0e308
    _ => false
  }
}

///|
fn int_json(n : Int64) -> Json {
  Json::number(n.to_double())
}

///|
/// The id of a roster's entry (`p?.id` a string).
fn peer_id(p : Json) -> String? {
  text_of(field(p, "id"))
}

///|
/// JavaScript's white space (`String.prototype.trim`, `\s`).
fn js_space(c : Char) -> Bool {
  let n = c.to_int()
  (n >= 0x9 && n <= 0xD) ||
  n == 0x20 ||
  n == 0xA0 ||
  n == 0x1680 ||
  (n >= 0x2000 && n <= 0x200A) ||
  n == 0x2028 ||
  n == 0x2029 ||
  n == 0x202F ||
  n == 0x205F ||
  n == 0x3000 ||
  n == 0xFEFF
}

///|
fn js_trim(s : String) -> String {
  let cs = s.to_array()
  let mut from = 0
  let mut to = cs.length()
  while from < to && js_space(cs[from]) {
    from += 1
  }
  while to > from && js_space(cs[to - 1]) {
    to -= 1
  }
  String::from_array(cs[from:to])
}

///|
/// `s` cut to its first `n` UTF-16 units (`String.prototype.slice(0, n)`).
fn js_slice(s : String, n : Int) -> String {
  if s.length() <= n {
    s
  } else {
    let b = StringBuilder()
    for i in 0..<n {
      b.write_char(s.code_unit_at(i).to_int().unsafe_to_char())
    }
    b.to_string()
  }
}

// ── a cloud.json with no lock ──

///|
/// The cloud's state as cloud.json holds it, no lock pinned: its rosters are the plane's word (`Cloud` with none).
pub struct StateCloud {
  /// cloud.json's object; None before it is enrolled.
  state : Map[String, Json]?
  mut peers_current : Bool
  told : Listeners
}

///|
pub fn StateCloud::new(state : Json?) -> StateCloud {
  let st = match state {
    Some(Object(m)) => Some(m)
    _ => None
  }
  let c = { state: st, peers_current: false, told: Listeners::new() }
  c.peers_current = st is Some(_) && !c.removed()
  c
}

///|
pub fn StateCloud::removed(self : StateCloud) -> Bool {
  match self.state {
    Some(m) => m.get("removed_at") is Some(_)
    None => false
  }
}

///|
/// Changes the state and tells the listeners.
pub fn StateCloud::update(self : StateCloud, change : (Map[String, Json]) -> Unit) -> Unit {
  match self.state {
    Some(m) => {
      change(m)
      self.told.tell()
    }
    None => ()
  }
}

///|
/// Told, as a roster's coming is.
pub fn StateCloud::tell(self : StateCloud) -> Unit {
  self.told.tell()
}

///|
fn StateCloud::home_membership(m : Map[String, Json]) -> Membership {
  {
    workspace: text_of(m.get("workspace")).unwrap_or(""),
    home: true,
    peers: array_of(m.get("peers")).unwrap_or([]),
  }
}

///|
fn StateCloud::joined(m : Map[String, Json]) -> Array[Json] {
  array_of(m.get("joined")).unwrap_or([])
}

///|
pub fn StateCloud::memberships(self : StateCloud) -> Array[Membership] {
  guard self.state is Some(m) else { return [] }
  let home = text_of(m.get("workspace")).unwrap_or("")
  if home == "" || self.removed() {
    return []
  }
  let out = [StateCloud::home_membership(m)]
  for j in StateCloud::joined(m) {
    let ws = text_of(field(j, "workspace")).unwrap_or("")
    // (one the plane says is locked, its lock not pinned here: none it takes members of, `leftOut` "unpinned")
    if ws == home || field(j, "locked") is Some(True) {
      continue
    }
    out.push({
      workspace: ws,
      home: false,
      peers: array_of(field(j, "peers")).unwrap_or([]),
    })
  }
  out
}

///|
pub fn StateCloud::membership(self : StateCloud, ws : String) -> Membership? {
  guard self.state is Some(m) else { return None }
  let home = text_of(m.get("workspace")).unwrap_or("")
  if home == "" || self.removed() {
    return None
  }
  if ws == home {
    return Some(StateCloud::home_membership(m))
  }
  for j in StateCloud::joined(m) {
    if text_of(field(j, "workspace")) == Some(ws) {
      if field(j, "locked") is Some(True) {
        return None
      }
      return Some({
        workspace: ws,
        home: false,
        peers: array_of(field(j, "peers")).unwrap_or([]),
      })
    }
  }
  None
}

///|
pub fn StateCloud::rigs(self : StateCloud, ws : String) -> Array[String] {
  guard self.state is Some(m) else { return [] }
  if m.get("rig") is Some(_) || self.membership(ws) is None {
    return []
  }
  let station = text_of(m.get("station")).unwrap_or("")
  let named = if ws == text_of(m.get("workspace")).unwrap_or("") {
    array_of(m.get("rigs")).unwrap_or([])
  } else {
    let mut found = []
    for j in StateCloud::joined(m) {
      if text_of(field(j, "workspace")) == Some(ws) {
        found = array_of(field(j, "rigs")).unwrap_or([])
        break
      }
    }
    found
  }
  named.filter_map(r => match peer_id(r) {
    Some(id) if id != station => Some(id)
    _ => None
  })
}

///|
/// The ways a file or a `state` frame says (state.ts `waysSaidOf`); None when it says none.
pub fn ways_said_of(raw : Json?) -> WaysSaid? {
  match raw {
    Some(Object(m)) =>
      match m.get("relays") {
        Some(Array(_)) =>
          Some({ relays: strings_of(m.get("relays")), off: strings_of(m.get("off")) })
        _ => None
      }
    _ => None
  }
}

///|
pub fn StateCloud::ways_said(self : StateCloud, ws : String) -> WaysSaid? {
  guard self.state is Some(m) else { return None }
  if ws == text_of(m.get("workspace")).unwrap_or("") {
    return ways_said_of(m.get("ways"))
  }
  for j in StateCloud::joined(m) {
    if text_of(field(j, "workspace")) == Some(ws) {
      return ways_said_of(field(j, "ways"))
    }
  }
  None
}

///|
pub fn StateCloud::relays(self : StateCloud) -> Array[String] {
  guard self.state is Some(m) else { return [] }
  let urls = strings_of(m.get("relay_urls"))
  let list = if array_of(m.get("relay_urls")).unwrap_or([]).length() > 0 {
    urls
  } else {
    match m.get("relay_url") {
      Some(String(u)) => [u]
      _ => []
    }
  }
  list.filter(can_parse)
}

///|
/// The view of it.
pub fn StateCloud::view(self : StateCloud) -> CloudView {
  {
    station: () => match self.state {
      Some(m) => Some(text_of(m.get("station")).unwrap_or(""))
      None => None
    },
    origin: () => match self.state {
      Some(m) => Some(text_of(m.get("origin")).unwrap_or(""))
      None => None
    },
    is_rig: () => match self.state {
      Some(m) => m.get("rig") is Some(_)
      None => false
    },
    stillfail_relays: () => match self.state {
      Some(m) =>
        match m.get("stillfail_relays") {
          Some(Array(_)) as r => Some(strings_of(r))
          _ => None
        }
      None => None
    },
    relays: () => self.relays(),
    memberships: () => self.memberships(),
    membership: ws => self.membership(ws),
    rigs: ws => self.rigs(ws),
    ways_said: ws => self.ways_said(ws),
    peers_current: () => self.peers_current,
    listen: f => self.told.add(f),
  }
}
