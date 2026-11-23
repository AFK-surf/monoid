// Who may use this rig (rig/grants.ts; a station that only runs tasks, 2026-11-10): its own record, which nothing but
// its person's signature changes. A rig runs what each rig-mode workspace's stations send it, for the chats its person
// granted it to (as a vault's secret is granted: a chat, for a time) or, with 免批准 on, for every chat of that
// workspace, as a station does. The stations bring what the person signed (a grant, one taken back, the settings:
// rig-form.ts) with that person's own lock; the rig checks each against the lock it pinned as it joined that workspace
// (`enroll --rig <hash>`), so neither a station's database, an agent on it, nor the cloud gives a chat this machine.
//
// Grants, settings, add proofs, and attached devices are strictly partitioned per workspace; person lock chains are
// keyed by the person's genesis hash so multiple rig workspaces with the same owner share one longest-seen chain.

///|
/// What this machine is in one rig-mode workspace: its key's id, its workspace, whose it is and that person's own lock.
pub(all) struct RigSelf {
  id : String
  workspace : String
  owner : String
  person : String
}

///|
/// The station's clock as these parts take it (ops/fibers.ts `Fibers`): now (ms), and `f` once, `ms` from now, the
/// function returned calling it off.
pub(all) struct Clock {
  now : () -> Double
  after : (Double, () -> Unit) -> () -> Unit
}

///|
/// The files these parts keep, as the shell reads and writes them: text whole (None where it is not there), and
/// written whole (writePrivate: readable by this user alone).
pub(all) struct Files {
  read : (String) -> String?
  write : (String, String) -> Unit raise
  mkdir : (String) -> Unit
}

///|
/// The station's files through its shell (fs.read, fs.write, as cloud_lock's Disk).
pub fn Files::of_host(host : @host.Host) -> Files {
  let disk : @cloud_lock.Disk = { host, }
  { read: path => disk.read(path), write: (path, text) => disk.write(path, text), mkdir: path => disk.mkdir(path) }
}

///|
pub(all) struct GrantsDeps {
  /// Where it is kept (<data>/rig/grants.json).
  path : String
  self_for : (String) -> RigSelf?
  workspaces : () -> Array[String]
  /// Whether a chat (workspace, station, session) has a task running here: that is use, however long since it last asked.
  busy : (String, String, String) -> Bool
  /// A chat lost the rig in a workspace: what it runs here stops.
  stop : (String, String, String) -> Unit
  /// The chats (workspace, station, session) with something running here.
  running : () -> Array[(String, String, String)]
  /// A grant ended here (`Ended`: request, station, session, why, device): its station in `workspace` is told.
  ended : (String, Json) -> Unit
  /// A chat (or every chat: none named) in `workspace` may have lost a device of this rig.
  cut : ((String, String, String?, String?) -> Unit)?
  /// Anything a station shows of this rig in `workspace` changed (grants, settings).
  changed : (String) -> Unit
  clock : Clock
  files : Files
  crypto : @cloud_lock.Crypto
}

///|
pub struct RigGrants {
  priv d : GrantsDeps
  /// The person's own lock, the longest chain of it seen, keyed by genesis hash (`person`).
  priv chains : Map[String, Array[Json]]
  /// Per-workspace rig settings (`ws -> signed`).
  priv settings : Map[String, Json]
  /// Per-workspace add proof (`ws -> signed`).
  priv adds : Map[String, Json]
  /// The grants in force (their request → `{signed, usedAt}`, as kept; each carries `signed.body.ws`).
  priv grants : Map[String, Map[String, Json]]
  /// Grants taken back (their request → when they would have ended, unix seconds): one brought again counts for nothing.
  priv revoked : Map[String, Double]
  /// The devices its person attached to it per workspace (`ws -> id -> signed`).
  priv devices : Map[String, Map[String, Json]]
  /// Per-workspace device settings (`ws -> id -> signed`).
  priv device_settings : Map[String, Map[String, Json]]
  priv mut armed : (() -> Unit)?
}

///|
/// `Object.entries(v ?? {})` of what a file held.
fn own_entries(v : Json?) -> Array[(String, Json)] {
  match v {
    Some(Object(m)) => js_entries(m)
    Some(Array(xs)) => xs.mapi((i, x) => (i.to_string(), x))
    Some(String(s)) => {
      let out = []
      for i in 0..<s.length() {
        out.push((i.to_string(), Json::string(s.unsafe_substring(start=i, end=i + 1))))
      }
      out
    }
    _ => []
  }
}

///|
pub fn RigGrants::new(d : GrantsDeps) -> RigGrants {
  let g : RigGrants = {
    d,
    chains: Map([]),
    settings: Map([]),
    adds: Map([]),
    grants: Map([]),
    revoked: Map([]),
    devices: Map([]),
    device_settings: Map([]),
    armed: None,
  }
  // None kept yet: nobody granted. Unreadable: nobody is granted anything until the person signs again; 免批准 is off.
  if (d.files.read)(d.path) is Some(text) && parse(text) is Some(raw) {
    let raw = Some(raw)
    // chains (new) or legacy single chain
    if get(raw, "chains") is Some(Object(_)) {
      for e in own_entries(get(raw, "chains")) {
        if e.1 is Array(xs) && xs.length() > 0 {
          g.chains[e.0] = xs
        }
      }
    } else if arr_at(raw, "chain") is Some(xs) && xs.length() > 0 {
      try {
        let genesis = @cloud_lock.entry_hash(xs[0])
        g.chains[genesis] = xs
      } catch {
        _ => ()
      }
    }
    // settings (new per-ws map or legacy single signed)
    match get(raw, "settings") {
      Some(s) if well_formed("settings", Some(s)) =>
        if str_at(get(Some(s), "body"), "ws") is Some(ws) {
          g.settings[ws] = s
        }
      Some(Object(_)) =>
        for e in own_entries(get(raw, "settings")) {
          if well_formed("settings", Some(e.1)) && str_at(get(Some(e.1), "body"), "ws") == Some(e.0) {
            g.settings[e.0] = e.1
          }
        }
      _ => ()
    }
    // adds (new per-ws map or legacy single `add`)
    if get(raw, "adds") is Some(Object(_)) {
      for e in own_entries(get(raw, "adds")) {
        if well_formed("add", Some(e.1)) && str_at(get(Some(e.1), "body"), "ws") == Some(e.0) {
          g.adds[e.0] = e.1
        }
      }
    } else if get(raw, "add") is Some(a) && well_formed("add", Some(a)) {
      if str_at(get(Some(a), "body"), "ws") is Some(ws) {
        g.adds[ws] = a
      }
    }
    for e in own_entries(get(raw, "grants")) {
      if e.1 is Object(m) && well_formed("grant", m.get("signed")) && safe_int_at(m.get("usedAt")) {
        g.grants[e.0] = m
      }
    }
    for e in own_entries(get(raw, "revoked")) {
      if e.1 is Number(n, ..) && safe_int(n) {
        g.revoked[e.0] = n
      }
    }
    // devices (new per-ws map `ws -> { id -> signed }` or legacy flat `id -> signed`)
    for e in own_entries(get(raw, "devices")) {
      if well_formed("device", Some(e.1)) {
        let body = get(Some(e.1), "body")
        if str_at(get(body, "device"), "id") == Some(e.0) &&
          bool_at(body, "removed") != Some(true) &&
          str_at(body, "ws") is Some(ws) {
          let map = match g.devices.get(ws) {
            Some(m) => m
            None => {
              let m = Map([])
              g.devices[ws] = m
              m
            }
          }
          map[e.0] = e.1
        }
      } else if e.1 is Object(_) {
        let ws = e.0
        for de in own_entries(Some(e.1)) {
          let dv = Some(de.1)
          let body = get(dv, "body")
          if well_formed("device", dv) &&
            str_at(body, "ws") == Some(ws) &&
            str_at(get(body, "device"), "id") == Some(de.0) &&
            bool_at(body, "removed") != Some(true) {
            let map = match g.devices.get(ws) {
              Some(m) => m
              None => {
                let m = Map([])
                g.devices[ws] = m
                m
              }
            }
            map[de.0] = de.1
          }
        }
      }
    }
    // deviceSettings (new per-ws map `ws -> { id -> signed }` or legacy flat `id -> signed`)
    for e in own_entries(get(raw, "deviceSettings")) {
      if well_formed("settings", Some(e.1)) {
        let body = get(Some(e.1), "body")
        if str_at(body, "device") == Some(e.0) && str_at(body, "ws") is Some(ws) {
          let map = match g.device_settings.get(ws) {
            Some(m) => m
            None => {
              let m = Map([])
              g.device_settings[ws] = m
              m
            }
          }
          map[e.0] = e.1
        }
      } else if e.1 is Object(_) {
        let ws = e.0
        for de in own_entries(Some(e.1)) {
          let dv = Some(de.1)
          let body = get(dv, "body")
          if well_formed("settings", dv) && str_at(body, "ws") == Some(ws) && str_at(body, "device") == Some(de.0) {
            let map = match g.device_settings.get(ws) {
              Some(m) => m
              None => {
                let m = Map([])
                g.device_settings[ws] = m
                m
              }
            }
            map[de.0] = de.1
          }
        }
      }
    }
  }
  g.look()
  g
}

///|
fn RigGrants::secs(self : RigGrants) -> Double {
  ((self.d.clock.now)() / 1000.0).floor()
}

///|
/// What is kept, as written (grants.json).
pub fn RigGrants::kept_json(self : RigGrants) -> Json {
  let chains : Map[String, Json] = Map([])
  for k, v in self.chains {
    chains[k] = jarr(v)
  }
  let grants : Map[String, Json] = Map([])
  for k, v in self.grants {
    grants[k] = Json::object(v)
  }
  let revoked : Map[String, Json] = Map([])
  for k, v in self.revoked {
    revoked[k] = jnum(v)
  }
  let devices : Map[String, Json] = Map([])
  for ws, m in self.devices {
    if !m.is_empty() {
      devices[ws] = Json::object(m)
    }
  }
  let device_settings : Map[String, Json] = Map([])
  for ws, m in self.device_settings {
    if !m.is_empty() {
      device_settings[ws] = Json::object(m)
    }
  }
  jobj([
    ("chains", Json::object(chains)),
    ("settings", Json::object(self.settings)),
    ("adds", Json::object(self.adds)),
    ("grants", Json::object(grants)),
    ("revoked", Json::object(revoked)),
    ("devices", Json::object(devices)),
    ("deviceSettings", Json::object(device_settings)),
  ])
}

///|
/// Kept in memory at once and written through (the latest of what is asked).
fn RigGrants::save(self : RigGrants) -> Unit {
  (self.d.files.write)(self.d.path, stringify(self.kept_json())) catch {
    _ => ()
  }
}

///|
fn RigGrants::self_of(self : RigGrants, workspace : String) -> RigSelf raise Refused {
  match (self.d.self_for)(workspace) {
    Some(s) => s
    None => raise Refused("this machine is no rig of that workspace now")
  }
}

///|
fn same_entry(a : Json, b : Json?) -> Bool {
  match b {
    None => false
    Some(b) =>
      try @cloud_lock.entry_hash(a) == @cloud_lock.entry_hash(b) catch {
        _ => false
      }
  }
}

///|
/// The person's own lock as brought (`chain`, the longest a station has): taken when it is the lock pinned for
/// `workspace` and goes on from the one kept. One that does not hold, or is another's, is refused.
pub fn RigGrants::take_chain(self : RigGrants, workspace : String, chain : Json?) -> Unit raise Refused {
  guard chain is Some(Array(brought)) && brought.length() > 0 else { return }
  let me = self.self_of(workspace)
  let kept = self.chains.get(me.person).unwrap_or([])
  let genesis = @cloud_lock.entry_hash(brought[0]) catch {
    _ => raise Refused("the lock brought is malformed")
  }
  if genesis != me.person {
    raise Refused("the lock brought is not the one this rig's person pinned on it")
  }
  if brought.length() <= kept.length() {
    for i, e in brought {
      if !same_entry(e, kept.get(i)) {
        raise Refused("the lock brought is at odds with the one this rig has of its person")
      }
    }
    return
  }
  for i, e in kept {
    if !same_entry(e, brought.get(i)) {
      raise Refused("the lock brought is at odds with the one this rig has of its person")
    }
  }
  let _ = @cloud_lock.person_fold(self.d.crypto, brought, me.owner) catch {
    e => raise Refused("the lock brought does not hold: \{error_message(e)}")
  }
  self.chains[me.person] = brought
  self.save()
}

///|
/// The keys on the person's lock for `workspace` now.
fn RigGrants::keys(self : RigGrants, workspace : String) -> Array[String] {
  guard (self.d.self_for)(workspace) is Some(me) else { return [] }
  guard self.chains.get(me.person) is Some(chain) && chain.length() > 0 else { return [] }
  try @cloud_lock.person_fold(self.d.crypto, chain, me.owner).devices.values().map(d => d.key).collect() catch {
    _ => []
  }
}

///|
/// A statement of `kind` checked: its shape, that it is about this rig in `workspace` by its person, and that a key
/// on the person's lock signed it. Raises why not.
fn RigGrants::checked(self : RigGrants, workspace : String, kind : String, signed : Json?) -> Json raise Refused {
  let me = self.self_of(workspace)
  if !well_formed(kind, signed) {
    raise Refused("not a rig's \{kind}")
  }
  let b = get(signed, "body")
  if str_at(b, "rig") != Some(me.id) || str_at(b, "ws") != Some(me.workspace) {
    raise Refused("signed for another rig or workspace")
  }
  if str_at(b, "sub") != Some(me.owner) {
    raise Refused("not signed by this rig's person")
  }
  if !self.keys(workspace).contains(str_at(get(signed, "sig"), "key").unwrap_or("")) {
    raise Refused("signed by a key that is not on this rig's person's own lock")
  }
  if !signature_holds(self.d.crypto, kind, signed) {
    raise Refused("the signature does not hold")
  }
  signed.unwrap()
}

///|
/// The grants in force, as `Object.values` walks them.
fn RigGrants::lives(self : RigGrants) -> Array[Map[String, Json]] {
  let keyed : Array[(String, Json)] = self.grants.keys().map(k => (k, Json::null())).collect()
  js_order(keyed).map(e => self.grants.get(e.0).unwrap())
}

///|
fn RigGrants::lives_in(self : RigGrants, workspace : String) -> Array[Map[String, Json]] {
  self.lives().filter(g => str_at(live_body(g), "ws") == Some(workspace))
}

///|
fn live_body(live : Map[String, Json]) -> Json? {
  get(live.get("signed"), "body")
}

///|
fn live_used(live : Map[String, Json]) -> Double {
  match live.get("usedAt") {
    Some(Number(n, ..)) => n
    _ => 0.0
  }
}

///|
fn RigGrants::ws_devices(self : RigGrants, workspace : String) -> Map[String, Json] {
  self.devices.get(workspace).unwrap_or(Map([]))
}

///|
fn RigGrants::ws_device_settings(self : RigGrants, workspace : String) -> Map[String, Json] {
  self.device_settings.get(workspace).unwrap_or(Map([]))
}

///|
/// A grant its station brings: in force from now, until it ends. Until when at the latest (unix seconds).
pub fn RigGrants::grant(
  self : RigGrants,
  workspace : String,
  peer : String,
  signed : Json?,
  chain : Json?,
) -> Double raise Refused {
  self.take_chain(workspace, chain)
  let s = self.checked(workspace, "grant", signed)
  let b = get(Some(s), "body")
  if str_at(b, "station") != Some(peer) {
    raise Refused("a grant is brought by its chat's own station")
  }
  let now = self.secs()
  let exp = num_at(b, "exp").unwrap_or(0.0)
  if exp <= now {
    raise Refused("the grant has expired")
  }
  let request = str_at(b, "request").unwrap_or("")
  if self.revoked.contains(request) {
    raise Refused("the grant was taken back")
  }
  if get(b, "device") is Some(dv) && !self.ws_devices(workspace).contains(js_string_of(Some(dv))) {
    raise Refused("no such device on this rig")
  }
  let was = self.grants.get(request)
  let used = match was {
    Some(w) => jnum(live_used(w))
    None => jnum((self.d.clock.now)())
  }
  self.grants[request] = Map([("signed", s), ("usedAt", used)])
  self.save()
  self.look()
  (self.d.changed)(workspace)
  exp
}

///|
/// A grant taken back by the person (signed), brought by any station.
pub fn RigGrants::revoke(self : RigGrants, workspace : String, signed : Json?, chain : Json?) -> Unit raise Refused {
  self.take_chain(workspace, chain)
  let s = self.checked(workspace, "revoke", signed)
  let request = str_at(get(Some(s), "body"), "request").unwrap_or("")
  let live = self.grants.get(request)
  self.revoked[request] = match live {
    Some(l) => num_at(live_body(l), "exp").unwrap_or(0.0)
    None => self.secs() + timeout_max
  }
  match live {
    Some(l) => self.end(l, "revoked")
    None => self.save()
  }
}

///|
/// A grant given back by its own station (the chat archived, or its agent done with the rig): no signature needed to
/// have less.
pub fn RigGrants::release(self : RigGrants, workspace : String, peer : String, request : String) -> Bool {
  guard self.grants.get(request) is Some(live) &&
    str_at(live_body(live), "ws") == Some(workspace) &&
    str_at(live_body(live), "station") == Some(peer) else {
    return false
  }
  self.end(live, "released")
  true
}

///|
/// The settings as signed: taken when newer than those kept. With 免批准 off again, the chats left with no grant lose
/// what they run here.
pub fn RigGrants::take_settings(
  self : RigGrants,
  workspace : String,
  signed : Json?,
  chain : Json?,
) -> Unit raise Refused {
  self.take_chain(workspace, chain)
  let s = self.checked(workspace, "settings", signed)
  let b = get(Some(s), "body")
  if get(b, "device") is Some(_) {
    return self.device_settings_of(workspace, s)
  }
  let had = self.settings.get(workspace)
  if had is Some(h) {
    let hb = get(had, "body")
    let seq = num_at(b, "seq").unwrap_or(0.0)
    let hseq = num_at(hb, "seq").unwrap_or(0.0)
    if seq <= hseq {
      if seq == hseq && str_at(get(Some(h), "sig"), "sig") == str_at(get(Some(s), "sig"), "sig") {
        return
      }
      raise Refused("older than the settings this rig has")
    }
  }
  self.settings[workspace] = s
  self.save()
  if bool_at(get(had, "body"), "open") == Some(true) && bool_at(b, "open") != Some(true) {
    for r in (self.d.running)() {
      if r.0 == workspace && self.grant_of(workspace, r.1, r.2) is None {
        (self.d.stop)(workspace, r.1, r.2)
      }
    }
    for id in self.ws_devices(workspace).keys().collect() {
      if !self.device_open(workspace, id) && self.d.cut is Some(cut) {
        cut(workspace, id, None, None)
      }
    }
  }
  (self.d.changed)(workspace)
}

///|
/// A device's own settings (免批准 on it alone): taken when newer than its kept ones. Off again, the chats with no grant
/// of it (or of the rig) lose their connections to it.
fn RigGrants::device_settings_of(self : RigGrants, workspace : String, s : Json) -> Unit raise Refused {
  let b = get(Some(s), "body")
  let id = js_string_of(get(b, "device"))
  if !self.ws_devices(workspace).contains(id) {
    raise Refused("no such device on this rig")
  }
  let ds = match self.device_settings.get(workspace) {
    Some(m) => m
    None => {
      let m = Map([])
      self.device_settings[workspace] = m
      m
    }
  }
  let had = ds.get(id)
  if had is Some(h) {
    let seq = num_at(b, "seq").unwrap_or(0.0)
    let hseq = num_at(get(Some(h), "body"), "seq").unwrap_or(0.0)
    if seq <= hseq {
      if seq == hseq && str_at(get(Some(h), "sig"), "sig") == str_at(get(Some(s), "sig"), "sig") {
        return
      }
      raise Refused("older than the settings this device has")
    }
  }
  ds[id] = s
  self.save()
  if bool_at(get(had, "body"), "open") == Some(true) &&
    bool_at(b, "open") != Some(true) &&
    !self.open(workspace) {
    if self.d.cut is Some(cut) {
      cut(workspace, id, None, None)
    }
  }
  (self.d.changed)(workspace)
}

///|
/// A device attached to this rig by its person in `workspace`, or (`removed`) taken off it: the grants of it end with it.
pub fn RigGrants::device(self : RigGrants, workspace : String, signed : Json?, chain : Json?) -> Unit raise Refused {
  self.take_chain(workspace, chain)
  let s = self.checked(workspace, "device", signed)
  let b = get(Some(s), "body")
  let id = str_at(get(b, "device"), "id").unwrap_or("")
  let devs = match self.devices.get(workspace) {
    Some(m) => m
    None => {
      let m = Map([])
      self.devices[workspace] = m
      m
    }
  }
  if devs.get(id) is Some(had) &&
    num_at(b, "at").unwrap_or(0.0) < num_at(get(Some(had), "body"), "at").unwrap_or(0.0) {
    raise Refused("older than what this rig has of the device")
  }
  if bool_at(b, "removed") == Some(true) {
    devs.remove(id)
    if self.device_settings.get(workspace) is Some(ds) {
      ds.remove(id)
    }
    self.save()
    for live in self.lives_in(workspace) {
      if str_at(live_body(live), "device") == Some(id) {
        self.end(live, "removed")
      }
    }
    if self.d.cut is Some(cut) {
      cut(workspace, id, None, None)
    }
  } else {
    devs[id] = s
    self.save()
  }
  (self.d.changed)(workspace)
}

///|
/// The devices attached here for `workspace` (rig-form.ts `Device`s).
pub fn RigGrants::devices(self : RigGrants, workspace : String) -> Array[Json] {
  self.ws_devices(workspace)
  .values()
  .map(d => get(get(Some(d), "body"), "device").unwrap_or(Json::null()))
  .collect()
}

///|
fn RigGrants::device_open(self : RigGrants, workspace : String, id : String) -> Bool {
  match self.ws_device_settings(workspace).get(id) {
    Some(s) => bool_at(get(Some(s), "body"), "open") == Some(true)
    None => false
  }
}

///|
/// Why a chat may not reach device `id` here now, or None: it may (a grant of the rig, or of the device; 免批准 on
/// either), and this is use. `use_`: false only to look again at a connection already open (`cut`), which is no use.
pub fn RigGrants::device_refusal(
  self : RigGrants,
  workspace : String,
  station : String,
  session : String,
  id : String,
  use_? : Bool = true,
) -> String? {
  guard (self.d.self_for)(workspace) is Some(_) else {
    return Some("this machine is no rig of that workspace now")
  }
  if !self.ws_devices(workspace).contains(id) {
    return Some("no such device on this rig")
  }
  if self.open(workspace) || self.device_open(workspace, id) {
    return None
  }
  if use_ {
    self.look()
  }
  let live = match self.grant_of(workspace, station, session) {
    Some(l) => Some(l)
    None => self.device_grant_of(workspace, station, session, id)
  }
  match live {
    None =>
      Some(
        "this chat has no grant of this device: ask for one with device_use (its owner approves it in still.fail)",
      )
    Some(l) => {
      if use_ {
        self.used(l)
      }
      None
    }
  }
}

///|
fn RigGrants::device_grant_of(
  self : RigGrants,
  workspace : String,
  station : String,
  session : String,
  id : String,
) -> Map[String, Json]? {
  for live in self.lives_in(workspace) {
    let b = live_body(live)
    if str_at(b, "station") == Some(station) && str_at(b, "session") == Some(session) && str_at(b, "device") == Some(id) {
      return Some(live)
    }
  }
  None
}

///|
/// What the person signed taking this rig into a workspace in security mode (rig-form.ts `AddBody`).
pub fn RigGrants::added(
  self : RigGrants,
  workspace : String,
  signed : Json?,
  pin? : Json? = None,
  chain? : Json? = None,
) -> String? raise Refused {
  let me = self.self_of(workspace)
  if !well_formed("add", signed) {
    raise Refused("not a rig's add")
  }
  let b = get(signed, "body")
  if str_at(b, "rig") != Some(me.id) || str_at(b, "ws") != Some(me.workspace) || str_at(b, "sub") != Some(me.owner) {
    raise Refused("signed for another rig, workspace or person")
  }
  if !signature_holds(self.d.crypto, "add", signed) {
    raise Refused("the signature does not hold")
  }
  self.adds[workspace] = signed.unwrap()
  self.save()
  let given = match pin {
    None | Some(Null) => false
    _ => true
  }
  let candidate = if given { pin } else { signed }
  guard str_at(get(candidate, "body"), "lock") is Some(_) else {
    if given {
      raise Refused("the pin names no lock")
    }
    return None
  }
  try {
    match chain {
      None | Some(Null) => ()
      _ => self.take_chain(workspace, chain)
    }
    str_at(get(Some(self.checked(workspace, "add", candidate)), "body"), "lock")
  } catch {
    e => if given { raise e } else { None }
  }
}

///|
/// Its person's word that this machine is to be a whole station again in `workspace` (rig-form.ts `FullBody`).
pub fn RigGrants::full(self : RigGrants, workspace : String, signed : Json?, chain : Json?) -> Json raise Refused {
  self.take_chain(workspace, chain)
  let s = self.checked(workspace, "full", signed)
  let now = self.secs()
  let at = num_at(get(Some(s), "body"), "at").unwrap_or(0.0)
  if at > now + 300.0 || now - at > full_for {
    raise Refused("signed too long ago: switch it again")
  }
  s
}

///|
/// Its person's word that this rig is to join another workspace as a rig (rig-form.ts `JoinBody`).
/// Note: `body.ws` is the target workspace to join, not `workspace` (the source workspace forwarding the request).
pub fn RigGrants::join(self : RigGrants, workspace : String, signed : Json?, chain : Json?) -> Json raise Refused {
  let me = self.self_of(workspace)
  self.take_chain(workspace, chain)
  if !well_formed("join", signed) {
    raise Refused("not a rig's join")
  }
  let b = get(signed, "body")
  if str_at(b, "rig") != Some(me.id) {
    raise Refused("signed for another rig")
  }
  if str_at(b, "ws") == Some(me.workspace) {
    raise Refused("already a rig in that workspace")
  }
  if str_at(b, "sub") != Some(me.owner) {
    raise Refused("not signed by this rig's person")
  }
  if !self.keys(workspace).contains(str_at(get(signed, "sig"), "key").unwrap_or("")) {
    raise Refused("signed by a key that is not on this rig's person's own lock")
  }
  if !signature_holds(self.d.crypto, "join", signed) {
    raise Refused("the signature does not hold")
  }
  let s = signed.unwrap()
  let now = self.secs()
  let at = num_at(b, "at").unwrap_or(0.0)
  if at > now + 300.0 || now - at > full_for {
    raise Refused("signed too long ago: join again")
  }
  s
}

///|
pub fn RigGrants::proof(self : RigGrants, workspace : String) -> Json? {
  self.adds.get(workspace)
}

///|
pub fn RigGrants::open(self : RigGrants, workspace : String) -> Bool {
  guard (self.d.self_for)(workspace) is Some(me) && self.settings.get(workspace) is Some(s) else { return false }
  let b = get(Some(s), "body")
  bool_at(b, "open") == Some(true) && str_at(b, "rig") == Some(me.id) && str_at(b, "ws") == Some(me.workspace)
}

///|
fn RigGrants::grant_of(
  self : RigGrants,
  workspace : String,
  station : String,
  session : String,
) -> Map[String, Json]? {
  // (a grant of one device alone is not one of the rig)
  for live in self.lives_in(workspace) {
    let b = live_body(live)
    if str_at(b, "station") == Some(station) && str_at(b, "session") == Some(session) && get(b, "device") is None {
      return Some(live)
    }
  }
  None
}

///|
/// Why a chat (`session` of `station`) may not use this rig in `workspace` now, or None: it may, and this is use.
pub fn RigGrants::refusal(self : RigGrants, workspace : String, station : String, session : String) -> String? {
  guard (self.d.self_for)(workspace) is Some(_) else {
    return Some("this machine is no rig of that workspace now")
  }
  if self.open(workspace) {
    return None
  }
  self.look()
  match self.grant_of(workspace, station, session) {
    None =>
      Some(
        "this chat has no grant of this station, which only runs tasks: ask for one with station_use (its owner approves it in still.fail)",
      )
    Some(live) => {
      self.used(live)
      None
    }
  }
}

///|
/// A grant used now. Written down a minute apart at most: a rig started again goes on from when it was last used, not
/// from when it was granted.
fn RigGrants::used(self : RigGrants, live : Map[String, Json]) -> Unit {
  let now = (self.d.clock.now)()
  let write = now - live_used(live) >= 60000.0
  live["usedAt"] = jnum(now)
  if write {
    self.save()
    self.look()
  }
}

///|
/// Why a station may not reach a service on this rig in `workspace` now, or None: one of its chats holds a grant (or 免批准 is on).
pub fn RigGrants::station_refusal(self : RigGrants, workspace : String, station : String) -> String? {
  guard (self.d.self_for)(workspace) is Some(_) else {
    return Some("this rig is of another workspace")
  }
  if self.open(workspace) {
    return None
  }
  self.look()
  let lives = self
    .lives_in(workspace)
    .filter(g => str_at(live_body(g), "station") == Some(station) && get(live_body(g), "device") is None)
  if lives.length() == 0 {
    return Some("no chat of that station has a grant of this one")
  }
  for live in lives {
    self.used(live)
  }
  None
}

///|
/// Until when a grant holds if the chat uses the rig no more (unix seconds).
fn RigGrants::until(_self : RigGrants, g : Map[String, Json]) -> Double {
  let b = live_body(g)
  let exp = num_at(b, "exp").unwrap_or(0.0)
  if str_at(get(b, "timeout"), "kind") == Some("idle") {
    let idle = (live_used(g) / 1000.0).floor() + num_at(get(b, "timeout"), "seconds").unwrap_or(0.0)
    if exp < idle {
      exp
    } else {
      idle
    }
  } else {
    exp
  }
}

///|
/// What a station is told of this rig in `workspace` (`describe`): whose it is, whether 免批准 is on, and the grants in force.
pub fn RigGrants::view(self : RigGrants, workspace : String) -> Json? {
  guard (self.d.self_for)(workspace) is Some(me) else { return None }
  self.look()
  let grants = self
    .lives_in(workspace)
    .map(g => {
      let b = live_body(g)
      let out = [
        ("request", get(b, "request").unwrap_or(Json::null())),
        ("station", get(b, "station").unwrap_or(Json::null())),
        ("session", get(b, "session").unwrap_or(Json::null())),
        ("chat", get(b, "chat").unwrap_or(Json::null())),
        ("title", get(b, "title").unwrap_or(Json::null())),
        ("by", get(b, "by").unwrap_or(Json::null())),
        ("timeout", get(b, "timeout").unwrap_or(Json::null())),
        ("exp", get(b, "exp").unwrap_or(Json::null())),
        ("until", jnum(self.until(g))),
      ]
      if get(b, "device") is Some(dv) {
        out.push(("device", dv))
      }
      jobj(out)
    })
  let devices = self.ws_devices(workspace)
    .values()
    .map(d => {
      let dev = get(get(Some(d), "body"), "device")
      let id = str_at(dev, "id").unwrap_or("")
      let settings = match self.ws_device_settings(workspace).get(id) {
        Some(s) => num_at(get(Some(s), "body"), "seq").unwrap_or(0.0)
        None => 0.0
      }
      spread(dev, Some(jobj([("open", jbool(self.device_open(workspace, id))), ("settings", jnum(settings))])))
    })
    .collect()
  Some(
    jobj([
      ("owner", jstr(me.owner)),
      ("person", jstr(me.person)),
      ("open", jbool(self.open(workspace))),
      (
        "settings",
        jnum(
          match self.settings.get(workspace) {
            Some(s) => num_at(get(Some(s), "body"), "seq").unwrap_or(0.0)
            None => 0.0
          },
        ),
      ),
      ("grants", jarr(grants)),
      ("devices", jarr(devices)),
    ]),
  )
}

///|
/// Clear all rig state for a workspace when this machine leaves it or becomes a full station in it.
pub fn RigGrants::clear_workspace(self : RigGrants, workspace : String) -> Unit {
  let mut dirty = false
  if self.settings.contains(workspace) {
    self.settings.remove(workspace)
    dirty = true
  }
  if self.adds.contains(workspace) {
    self.adds.remove(workspace)
    dirty = true
  }
  let dev_ids = self.ws_devices(workspace).keys().collect()
  if self.devices.contains(workspace) {
    self.devices.remove(workspace)
    dirty = true
  }
  if self.device_settings.contains(workspace) {
    self.device_settings.remove(workspace)
    dirty = true
  }
  for live in self.lives_in(workspace) {
    self.end(live, "removed")
    dirty = false // end() already saved
  }
  for id in dev_ids {
    if self.d.cut is Some(cut) {
      cut(workspace, id, None, None)
    }
  }
  if dirty {
    self.save()
  }
}

///|
fn RigGrants::end(self : RigGrants, live : Map[String, Json], why : String) -> Unit {
  let b = live_body(live)
  let workspace = str_at(b, "ws").unwrap_or("")
  let request = str_at(b, "request").unwrap_or("")
  let station = str_at(b, "station").unwrap_or("")
  let session = str_at(b, "session").unwrap_or("")
  self.grants.remove(request)
  self.save()
  match get(b, "device") {
    Some(dv) => {
      let dev = js_string_of(Some(dv))
      if self.grant_of(workspace, station, session) is None &&
        !self.open(workspace) &&
        !self.device_open(workspace, dev) {
        if self.d.cut is Some(cut) {
          cut(workspace, dev, Some(station), Some(session))
        }
      }
    }
    None =>
      if self.grant_of(workspace, station, session) is None && !self.open(workspace) {
        (self.d.stop)(workspace, station, session)
        for id in self.ws_devices(workspace).keys().collect() {
          if self.device_grant_of(workspace, station, session, id) is None && !self.device_open(workspace, id) {
            if self.d.cut is Some(cut) {
              cut(workspace, id, Some(station), Some(session))
            }
          }
        }
      }
  }
  let ended = [
    ("request", jstr(request)),
    ("station", jstr(station)),
    ("session", jstr(session)),
    ("why", jstr(why)),
  ]
  if get(b, "device") is Some(dv) {
    ended.push(("device", dv))
  }
  (self.d.ended)(workspace, jobj(ended))
  (self.d.changed)(workspace)
  self.look()
}

///|
/// Ends the grants whose time is up, and arms the wait for the next to be.
fn RigGrants::look(self : RigGrants) -> Unit {
  if self.armed is Some(off) {
    off()
  }
  self.armed = None
  let now = self.secs()
  let mut next : Double? = None
  for live in self.lives() {
    let b = live_body(live)
    let workspace = str_at(b, "ws").unwrap_or("")
    if num_at(b, "exp").unwrap_or(0.0) <= now {
      self.end(live, "expired")
      return
    }
    if str_at(get(b, "timeout"), "kind") == Some("idle") {
      // A task of the chat's still running here is use: an idle grant does not end under a long build.
      if (self.d.busy)(workspace, str_at(b, "station").unwrap_or(""), str_at(b, "session").unwrap_or("")) {
        live["usedAt"] = jnum((self.d.clock.now)())
      } else if (live_used(live) / 1000.0).floor() + num_at(get(b, "timeout"), "seconds").unwrap_or(0.0) <= now {
        self.end(live, "idle")
        return
      }
    }
    let u = self.until(live)
    next = Some(
      match next {
        Some(n) if n < u => n
        _ => u
      },
    )
  }
  for request in self.revoked.keys().collect() {
    if self.revoked.get(request).unwrap_or(0.0) <= now {
      self.revoked.remove(request)
    }
  }
  // The deadline of the grant that ends first (a timeout, not a look at anything of another part).
  if next is Some(n) {
    let wait = if n - now > 1.0 { n - now } else { 1.0 }
    self.armed = Some((self.d.clock.after)(wait * 1000.0, () => self.look()))
  }
}

///|
/// Its wait called off (the rig closing).
pub fn RigGrants::close(self : RigGrants) -> Unit {
  if self.armed is Some(off) {
    off()
  }
}
