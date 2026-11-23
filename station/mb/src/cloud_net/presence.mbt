// The presence socket to the control plane (station/src/cloud/presence.ts): open while the station answers is the
// station online; the plane pushes on it where the station is, its relays and roster, and what it takes back. Signed at
// connect like enrollment. Reconnects with backoff; once removed from its workspace, asks again only when enrolled
// anew. Which control plane, and how it is spoken to, is the provider's, read anew at every connect.
//
// What a machine is (whole, or a rig that only runs tasks) changes only when two agree, neither alone: what was asked of
// the machine over a way the plane has no part in, kept for an hour (`rig_pending`, `full_pending`), and the plane
// listing it so, as that same person's (apply_frame).
//
// The locks the plane carries are cloud_lock's: what presence reads and changes of them goes through `LockHooks`
// (`PlaneCloud::unlocked` is a station that pins none).

///|
/// The plane expects a "ping" this often and drops a station silent for three of them.
pub let ping_ms : Int = 30_000

///|
/// How the plane closes the socket of a station removed from its workspace.
pub let close_removed : Int = 4004

///|
/// How the plane closes a station's socket as another of the same station's (its key) connects.
pub let close_replaced : Int = 4000

///|
/// So many sockets in a row replaced before they held a heartbeat: another station connects with this one's key.
pub let replaced_in_a_row : Int = 3

///|
/// How long a station whose key another uses waits before it connects again.
pub let conflict_backoff_ms : Int = 60_000

///|
pub let conflict_error : String = "another station is using this station's key: still.fail cloud keeps replacing one's presence socket with the other's; stop the other or enroll one of them again"

///|
/// How long the roster the plane said last counts as reached once its socket ended.
pub let roster_grace_ms : Int = 60_000

///|
/// How long a change of a station's mode asked of the machine waits for the control plane to list it so (s).
pub let mode_pending_s : Int64 = 3600L

///|
/// At most this many entries a `lock.put` brings the plane.
pub let put_most : Int = 256

// ── another station on this key ──

///|
/// Whether another station uses this one's key, as its sockets end (`ended`) and hold (`steady`).
pub struct Replaced {
  mut in_a_row : Int
  mut conflict : Bool
  priv told : (Bool) -> Unit
}

///|
pub fn Replaced::new(told? : (Bool) -> Unit = _ => ()) -> Replaced {
  { in_a_row: 0, conflict: false, told }
}

///|
/// A socket ended: with the close code the plane gave (None: it broke), having held a heartbeat or not.
pub fn Replaced::ended(self : Replaced, code : Int?, held : Bool) -> Unit {
  if code == Some(close_replaced) && !held {
    self.in_a_row += 1
  } else if code is Some(_) {
    self.in_a_row = 0
  }
  if self.in_a_row >= replaced_in_a_row && !self.conflict {
    self.conflict = true
    (self.told)(true)
  }
}

///|
/// A socket held a heartbeat (the plane answered its first ping).
pub fn Replaced::steady(self : Replaced) -> Unit {
  self.in_a_row = 0
  if !self.conflict {
    return
  }
  self.conflict = false
  (self.told)(false)
}

// ── what the plane tells besides the state ──

///|
/// What still.fail cloud tells a station of besides its state: a release is out, the models' catalog changed.
pub(all) enum CloudSaid {
  Release
  Models(String?)
}

///|
pub fn CloudSaid::to_json(self : CloudSaid) -> Json {
  match self {
    Release => { "type": "release" }
    Models(Some(etag)) => { "type": "models", "etag": Json::string(etag) }
    Models(None) => { "type": "models" }
  }
}

///|
/// Whether `event` is something the plane tells of besides the station's state, told to `said`.
pub fn cloud_said(event : Json, said : (CloudSaid) -> Unit) -> Bool {
  match text_of(field(event, "type")) {
    Some("release") => said(Release)
    Some("models") => said(Models(text_of(field(event, "etag"))))
    _ => return false
  }
  true
}

// ── the state the plane says ──

///|
/// A rig (state.ts `rigsOf`), what is malformed in them left out.
pub fn rigs_of(raw : Json?) -> Array[Json] {
  guard raw is Some(Array(rs)) else { return [] }
  rs.filter_map(r => {
    let id = text_of(field(r, "id"))
    let owner = text_of(field(r, "owner"))
    match (id, owner) {
      (Some(id), Some(owner)) if hex64(id) && owner != "" => {
        let t = (k : String) => Json::string(text_of(field(r, k)).unwrap_or(""))
        let m : Map[String, Json] = {
          "id": Json::string(id),
          "name": t("name"),
          "owner": Json::string(owner),
          "owner_email": t("owner_email"),
          "owner_name": t("owner_name"),
        }
        if text_of(field(r, "version")) is Some(v) {
          m["version"] = Json::string(v)
        }
        Some(Json::object(m))
      }
      _ => None
    }
  })
}

///|
/// Whether a revocation is one (`isRevocation`).
pub fn is_revocation(r : Json) -> Bool {
  text_of(field(r, "kind")) is Some(_) &&
  text_of(field(r, "id")) is Some(_) &&
  is_integer(field(r, "at")) &&
  (match field(r, "at") {
    Some(Number(n, ..)) => n >= 0.0
    _ => false
  })
}

///|
/// The joined workspaces a `state` frame's `workspaces` names (state.ts `joinedOf`).
pub fn joined_of(raw : Json?) -> Array[Json] {
  guard raw is Some(Array(js)) else { return [] }
  js.filter_map(j => {
    guard text_of(field(j, "workspace")) is Some(ws) && ws != "" else {
      return None
    }
    let m : Map[String, Json] = {
      "workspace": Json::string(ws),
      "workspace_name": Json::string(
        text_of(field(j, "workspace_name")).unwrap_or(ws),
      ),
    }
    if text_of(field(j, "workspace_emoji")) is Some(e) && e != "" {
      m["workspace_emoji"] = Json::string(e)
    }
    if text_of(field(j, "workspace_icon")) is Some(ic) && ic != "" {
      m["workspace_icon"] = Json::string(ic)
    }
    m["name"] = Json::string(text_of(field(j, "name")).unwrap_or(""))
    m["peers"] = Json::array(array_of(field(j, "peers")).unwrap_or([]))
    m["revocations"] = Json::array(
      array_of(field(j, "revocations")).unwrap_or([]).filter(is_revocation),
    )
    if field(j, "locked") is Some(True) {
      m["locked"] = Json::boolean(true)
    }
    match field(j, "rigs") {
      Some(Array(rs)) if rs.length() > 0 =>
        m["rigs"] = Json::array(rigs_of(field(j, "rigs")))
      _ => ()
    }
    if ways_said_of(field(j, "ways")) is Some(w) {
      m["ways"] = w.to_json()
    }
    match field(j, "rig") {
      Some(Object(r)) =>
        match (text_of(r.get("owner")), text_of(r.get("person"))) {
          (Some(owner), Some(person)) if owner != "" && hex64(person) => {
            let rm : Map[String, Json] = {
              "owner": Json::string(owner),
              "owner_email": Json::string(text_of(r.get("owner_email")).unwrap_or("")),
              "owner_name": Json::string(text_of(r.get("owner_name")).unwrap_or("")),
              "person": Json::string(person),
            }
            m["rig"] = Json::object(rm)
          }
          _ => ()
        }
      _ => ()
    }
    Some(Json::object(m))
  })
}

///|
/// What presence reads and changes of the locks the plane carries (state.ts's, cloud_lock's), by workspace (None: the
/// home one).
pub(all) struct LockHooks {
  /// Whether a lock of it is pinned here (`chain(ws) !== null`).
  pinned : (String?) -> Bool
  /// Its state's head (`chain(ws)?.state?.seq`): None where none is pinned or its state is broken.
  seq : (String?) -> Int?
  genesis : (String?) -> String?
  /// The lock enrolling or joining named to pin (`pendingLock`).
  pending : (String?) -> String?
  /// Why a joined workspace is none it takes members of now ("pending", "unpinned", "home").
  left_out : (String) -> String?
  /// The chain gone by after `seq`, and every entry kept off it.
  after : (Int, String?) -> Array[Json]
  kept : (String?) -> Array[Json]
  hash_of : (Json) -> String
  /// An entry as the plane brought it, checked (`asEntry`); None where malformed.
  as_entry : (Json) -> Json?
  /// Whether these entries' state names this station (`fold(...).stations.has`).
  names_station : (Array[Json]) -> Bool
  take : (Array[Json], String?) -> Unit raise
  offer_moved : (String, Array[Json]) -> Unit
  /// What joining named to pin read no more (its file gone: pinned now).
  pending_taken : (String?) -> Unit
  /// A joined workspace takes over as the home one (`demote_old_home`: old home moves to joined instead of leaving).
  succeed : (String, Bool) -> Bool
  /// The roster and gateways as the lock lets them, from what the plane said last.
  filtered : (Array[Json], Array[String]?) -> (Array[Json], Array[String]?)
  /// Whether the home workspace is locked (`locked() !== null`).
  locked : () -> Bool
}

///|
/// The station's cloud as presence keeps it: the state, what the plane said of its locks' heads, and the rest
/// `Cloud` keeps for this socket.
pub struct PlaneCloud {
  cloud : StateCloud
  lock : LockHooks
  /// How far the plane's copy of the home lock goes (None: a plane that keeps none).
  mut plane_lock_seq : Int?
  plane_lock_seqs : Map[String, Int?]
  plane_lock_hashes : Map[String, String]
  plane_parted : Map[String, String]
  mut reached : Bool
  mut rosters_said : Int
  mut plane_peers : Array[Json]?
  mut plane_gateways : Array[String]?
  /// Workspaces listed as rig-mode by the last `state` frame that had no local `RigSelf` yet (replayed once written).
  skipped_rig_ws : Array[String]
  mut last_skipped_frame : Json?
  /// The clock in seconds (`nowSecs`).
  now_secs : () -> Int64
  /// cloud.json read anew from its file (enroll from another process).
  reload : () -> Unit
  /// The grants of this machine as a rig, removed as it becomes whole again.
  rig_grants_gone : () -> Unit
  /// A device tool request pushed on the socket (Comma's), answered.
  tool_calls : ((Json, (Result[Json, String]) -> Unit) -> Unit)?
  log : (String) -> Unit
}

///|
/// No lock pinned anywhere: the plane's word is taken as it is (what a station is before safe mode).
pub fn LockHooks::unlocked(plane_peers : () -> (Array[Json]?, Array[String]?)) -> LockHooks {
  {
    pinned: _ => false,
    seq: _ => None,
    genesis: _ => None,
    pending: _ => None,
    left_out: _ => None,
    after: (_, _) => [],
    kept: _ => [],
    hash_of: e => e.stringify(),
    as_entry: e => Some(e),
    names_station: _ => false,
    take: (_, _) => (),
    offer_moved: (_, _) => (),
    pending_taken: _ => (),
    succeed: (_, _) => true,
    filtered: (peers, gateways) => {
      ignore(plane_peers)
      (peers, gateways)
    },
    locked: () => false,
  }
}

///|
pub fn PlaneCloud::new(
  cloud : StateCloud,
  now_secs : () -> Int64,
  lock? : LockHooks,
  reload? : () -> Unit = () => (),
  rig_grants_gone? : () -> Unit = () => (),
  tool_calls? : (Json, (Result[Json, String]) -> Unit) -> Unit,
  log? : (String) -> Unit = _ => (),
) -> PlaneCloud {
  let lock = match lock {
    Some(l) => l
    None => LockHooks::unlocked(() => (None, None))
  }
  {
    cloud,
    lock,
    plane_lock_seq: None,
    plane_lock_seqs: Map([]),
    plane_lock_hashes: Map([]),
    plane_parted: Map([]),
    reached: false,
    rosters_said: 0,
    plane_peers: None,
    plane_gateways: None,
    skipped_rig_ws: [],
    last_skipped_frame: None,
    now_secs,
    reload,
    rig_grants_gone,
    tool_calls,
    log,
  }
}

///|
/// Replay the last `state` frame if `cloud.json` now has local `RigSelf` for any workspace that was skipped because
/// the plane listed it as rig-mode before local `RigSelf` was written.
pub fn replay_skipped_rig_frame(p : PlaneCloud, send : (Json) -> Unit) -> Bool {
  if p.skipped_rig_ws.length() == 0 {
    return false
  }
  guard p.last_skipped_frame is Some(frame) else { return false }
  let has_rig = (ws : String) => match p.cloud.state {
    Some(st) =>
      if text_of(st.get("workspace")) == Some(ws) {
        st.get("rig") is Some(Object(_))
      } else {
        array_of(st.get("joined"))
        .unwrap_or([])
        .iter()
        .any(j => text_of(field(j, "workspace")) == Some(ws) && field(j, "rig") is Some(Object(_)))
      }
    None => false
  }
  let mut ready = false
  for ws in p.skipped_rig_ws {
    if has_rig(ws) {
      ready = true
      break
    }
  }
  if !ready {
    return false
  }
  p.skipped_rig_ws.clear()
  p.last_skipped_frame = None
  apply_state_frame(p, frame, send)
  true
}

///|
/// The roster and gateways as the lock lets them (state.ts `filtered`).
fn PlaneCloud::filtered(
  self : PlaneCloud,
  st : Map[String, Json],
) -> (Array[Json], Array[String]?) {
  let peers = match self.plane_peers {
    Some(p) => p
    None => array_of(st.get("peers")).unwrap_or([])
  }
  let gateways = match self.plane_gateways {
    Some(g) => Some(g)
    None =>
      match st.get("gateway_keys") {
        Some(Array(_)) as g => Some(strings_of(g))
        _ => None
      }
  }
  (self.lock.filtered)(peers, gateways)
}

///|
/// The roster said last, no longer reached once `roster_grace_ms` passed with no fresh one; not taken at all at once
/// when the station was removed.
pub fn PlaneCloud::lapse(self : PlaneCloud, timers : After) -> Unit {
  if self.cloud.removed() {
    self.lapsed()
    return
  }
  let said = self.rosters_said
  ignore(
    (timers.after)(roster_grace_ms, fn() {
      if self.rosters_said == said {
        self.lapsed()
      }
    }),
  )
}

///|
fn PlaneCloud::lapsed(self : PlaneCloud) -> Unit {
  let current = !self.cloud.removed() && self.cloud.peers_current
  if !self.reached && current == self.cloud.peers_current {
    return
  }
  self.reached = false
  self.cloud.peers_current = current
  self.cloud.tell()
}

///|
/// What the plane pushes, as text: where the station is and what it is called, its relays, roster and grant keys,
/// what it takes back; the locks' heads, and their entries when asked (`send` answers on the socket).
pub fn apply_state(p : PlaneCloud, text : String, send : (Json) -> Unit) -> Unit {
  match (try Some(@json.parse(text)) catch { _ => None }) {
    Some(body) => apply_frame(p, body, send)
    None => ()
  }
}

///|
fn has_object(j : Json?) -> Bool {
  j is Some(Object(_))
}

///|
pub fn apply_frame(p : PlaneCloud, body : Json, send : (Json) -> Unit) -> Unit {
  let s = p.cloud
  match text_of(field(body, "type")) {
    Some("state") => apply_state_frame(p, body, send)
    Some("revoke") if is_revocation(body) => {
      let named = text_of(field(body, "workspace"))
      s.update(st => {
        let home = text_of(st.get("workspace")).unwrap_or("")
        let elsewhere = named is Some(n) && n != home
        let of = if elsewhere {
          let mut found : Map[String, Json]? = None
          for j in array_of(st.get("joined")).unwrap_or([]) {
            match j {
              Object(jm) if text_of(jm.get("workspace")) == named => {
                found = Some(jm)
                break
              }
              _ => ()
            }
          }
          match found {
            Some(jm) => jm
            None => return
          }
        } else {
          st
        }
        let kind = field(body, "kind")
        let id = field(body, "id")
        let kept = array_of(of.get("revocations"))
          .unwrap_or([])
          .filter(r => !(field(r, "kind") == kind && field(r, "id") == id))
        kept.push({
          "kind": kind.unwrap(),
          "id": id.unwrap(),
          "at": field(body, "at").unwrap(),
        })
        of["revocations"] = Json::array(kept)
      })
    }
    Some("lock") =>
      match field(body, "entries") {
        Some(Array(entries)) => {
          let home = match s.state {
            Some(m) => text_of(m.get("workspace"))
            None => None
          }
          let ws = match text_of(field(body, "workspace")) {
            Some(w) if Some(w) != home => Some(w)
            _ => None
          }
          take_from_plane(p, entries, ws, send)
        }
        _ => ()
      }
    _ => ()
  }
}

///|
fn apply_state_frame(p : PlaneCloud, body : Json, send : (Json) -> Unit) -> Unit {
  guard global_mesh_relays(field(body, "mesh_relays")) is Some(mesh_relays) else {
    (p.log)("invalid global mesh registry")
    return
  }
  let s = p.cloud
  let lock = p.lock
  let named_ws = text_of(field(body, "workspace"))
  let incoming_joined = joined_of(field(body, "workspaces"))
  let was_rig_by_ws : Map[String, Json] = Map([])
  match s.state {
    Some(was) => {
      let was_home = text_of(was.get("workspace")).unwrap_or("")
      if was_home != "" {
        if was.get("rig") is Some(Object(_) as r) {
          was_rig_by_ws[was_home] = r
        }
      }
      for j in array_of(was.get("joined")).unwrap_or([]) {
        match (text_of(field(j, "workspace")), field(j, "rig")) {
          (Some(jws), Some(Object(_) as r)) if jws != "" => was_rig_by_ws[jws] = r
          _ => ()
        }
      }
    }
    None => ()
  }
  let took = match (s.state, named_ws) {
    (Some(was), Some(ws)) if Some(ws) != text_of(was.get("workspace")) => {
      let kept_there = !(lock.pinned)(None) &&
        ((lock.pinned)(Some(ws)) || (lock.pending)(Some(ws)) is Some(_))
      let was_ws = text_of(was.get("workspace")).unwrap_or("")
      let joined_there = array_of(was.get("joined"))
        .unwrap_or([])
        .iter()
        .any(j => text_of(field(j, "workspace")) == Some(ws))
      let still_named = incoming_joined
        .iter()
        .any(j => text_of(field(j, "workspace")) == Some(was_ws))
      if still_named {
        (lock.succeed)(ws, true)
      } else {
        (kept_there || joined_there) && (lock.succeed)(ws, false)
      }
    }
    _ => false
  }
  if took {
    match named_ws {
      Some(ws) => p.plane_lock_seqs.remove(ws)
      None => ()
    }
  }
  let locked = (lock.pinned)(None)
  let wrong_home = match s.state {
    Some(st) =>
      locked &&
      named_ws is Some(w) &&
      Some(w) != text_of(st.get("workspace")) &&
      !took
    None => false
  }
  if locked && s.state is Some(st) {
    let moved_ws = named_ws is Some(w) &&
      Some(w) != text_of(st.get("workspace")) &&
      !took
    let moved_origin = text_of(field(body, "origin")) is Some(o) &&
      Some(o) != text_of(st.get("origin"))
    if moved_ws || moved_origin {
      (p.log)(
        "the control plane moves this station; the workspace lock keeps it where it is",
      )
    }
  }
  let peers_said = array_of(field(body, "peers"))
  p.plane_peers = Some(peers_said.unwrap_or([]))
  p.plane_gateways = match field(body, "gateway_keys") {
    Some(Array(_)) as g => Some(strings_of(g))
    _ => None
  }
  // Current before it is told, so whoever hears of the new roster reads it as current.
  s.peers_current = peers_said is Some(_)
  p.reached = s.peers_current
  p.rosters_said += 1
  let cleared_rig_ws : Array[String] = []
  let skipped_rig_ws : Array[String] = []
  s.update(st => {
    for k in ["workspace", "workspace_name", "name", "origin", "relay_url"] {
      if locked && (k == "origin" || (k == "workspace" && !took)) {
        continue
      }
      match field(body, k) {
        Some(String(_)) as v => st[k] = v.unwrap()
        _ => ()
      }
    }
    if !wrong_home {
      match text_of(field(body, "workspace_emoji")) {
        Some(e) if e != "" => st["workspace_emoji"] = Json::string(e)
        _ => st.remove("workspace_emoji")
      }
      match text_of(field(body, "workspace_icon")) {
        Some(ic) if ic != "" => st["workspace_icon"] = Json::string(ic)
        _ => st.remove("workspace_icon")
      }
    }
    match field(body, "relay_urls") {
      Some(Array(_)) as r =>
        st["relay_urls"] = Json::array(strings_of(r).map(Json::string))
      _ => ()
    }
    st["mesh_relays"] = Json::array(mesh_relays)
    match field(body, "stillfail_relays") {
      Some(Array(_)) as r =>
        st["stillfail_relays"] = Json::array(strings_of(r).map(Json::string))
      _ => st.remove("stillfail_relays")
    }
    match ways_said_of(field(body, "ways")) {
      Some(w) => st["ways"] = w.to_json()
      None => st.remove("ways")
    }
    if has_object(field(body, "grant_keys")) {
      st["grant_keys"] = field(body, "grant_keys").unwrap()
    }
    match field(body, "revocations") {
      Some(Array(rs)) if rs.iter().all(is_revocation) =>
        st["revocations"] = Json::array(rs)
      _ => ()
    }
    let home_ws = text_of(st.get("workspace")).unwrap_or("")
    match was_rig_by_ws.get(home_ws) {
      Some(r) => st["rig"] = r
      None => st.remove("rig")
    }
    // Per-workspace mode transitions: normalize & prune pending maps before building `joined`,
    // so we know whether a newly plane-listed rig workspace has a matching `rig_pending` or must be skipped.
    let listed_rig_of = (raw : Json?) => match raw {
      Some(Object(r)) => text_of(r.get("owner"))
      _ => None
    }
    let now = (p.now_secs)()
    let fresh = (at : Json?) => match safe_int(at) {
      Some(a) => now - a <= mode_pending_s
      None =>
        match at {
          Some(Number(n, ..)) => now.to_double() - n <= mode_pending_s.to_double()
          _ => false
        }
    }
    let rp_map : Map[String, Json] = Map([])
    match st.get("rig_pending") {
      Some(Object(m)) =>
        if text_of(m.get("owner")) is Some(_) && m.get("at") is Some(_) {
          if home_ws != "" && fresh(m.get("at")) {
            rp_map[home_ws] = Json::object(m)
          }
        } else {
          for ws, entry in m {
            if ws != "" && fresh(field(entry, "at")) {
              rp_map[ws] = entry
            }
          }
        }
      _ => ()
    }
    if rp_map.is_empty() {
      st.remove("rig_pending")
    } else {
      st["rig_pending"] = Json::object(rp_map)
    }
    let due_list : Array[String] = []
    match st.get("rig_due") {
      Some(True) =>
        if home_ws != "" && rp_map.contains(home_ws) {
          due_list.push(home_ws)
        }
      Some(Array(xs)) =>
        for x in xs {
          if x is String(ws) && rp_map.contains(ws) && !due_list.contains(ws) {
            due_list.push(ws)
          }
        }
      _ => ()
    }
    let fp_map : Map[String, Json] = Map([])
    match st.get("full_pending") {
      Some(Object(m)) =>
        if m.get("at") is Some(_) {
          if home_ws != "" && fresh(m.get("at")) {
            fp_map[home_ws] = Json::object(m)
          }
        } else {
          for ws, entry in m {
            if ws != "" && fresh(field(entry, "at")) {
              fp_map[ws] = entry
            }
          }
        }
      _ => ()
    }
    // Collect listed rig owner and raw rigs list per workspace from the frame
    let listed_by_ws : Map[String, String?] = Map([])
    let raw_rigs_by_ws : Map[String, Array[Json]] = Map([])
    if !wrong_home && home_ws != "" {
      listed_by_ws[home_ws] = listed_rig_of(field(body, "rig"))
      raw_rigs_by_ws[home_ws] = rigs_of(field(body, "rigs"))
    }
    match field(body, "workspaces") {
      Some(Array(js)) =>
        for j in js {
          if text_of(field(j, "workspace")) is Some(jws) && jws != "" {
            listed_by_ws[jws] = listed_rig_of(field(j, "rig"))
            raw_rigs_by_ws[jws] = rigs_of(field(j, "rigs"))
          }
        }
      _ => ()
    }
    let joined : Array[Json] = []
    for j in incoming_joined {
      match j {
        Object(jm) => {
          let jws = text_of(jm.get("workspace")).unwrap_or("")
          if jws == "" || jws == home_ws {
            continue
          }
          match was_rig_by_ws.get(jws) {
            Some(r) => {
              let out = jm.copy()
              out["rig"] = r
              out.remove("rigs")
              joined.push(Json::object(out))
            }
            None => {
              let listed_owner = listed_by_ws.get(jws).unwrap_or(None)
              if listed_owner is Some(owner) {
                let pending_matches = match rp_map.get(jws) {
                  Some(rp) => text_of(field(rp, "owner")) == Some(owner)
                  None => false
                }
                if !pending_matches {
                  if !skipped_rig_ws.contains(jws) {
                    skipped_rig_ws.push(jws)
                  }
                  continue
                }
              }
              let out = jm.copy()
              out.remove("rig")
              joined.push(Json::object(out))
            }
          }
        }
        other => joined.push(other)
      }
    }
    for was in array_of(st.get("joined")).unwrap_or([]) {
      let ws = text_of(field(was, "workspace")).unwrap_or("")
      if !joined.iter().any(j => text_of(field(j, "workspace")) == Some(ws)) {
        // (not served, its lock kept: the plane's word alone undoes no lock)
        p.plane_lock_seqs.remove(ws)
      }
    }
    if joined.length() > 0 {
      st["joined"] = Json::array(joined)
    } else {
      st.remove("joined")
    }
    let (peers, gateways) = p.filtered(st)
    st["peers"] = Json::array(if peers_said is Some(_) { peers } else { [] })
    if field(body, "gateway_keys") is Some(Array(_)) {
      match gateways {
        Some(g) => st["gateway_keys"] = Json::array(g.map(Json::string))
        None => st.remove("gateway_keys")
      }
    }
    // Check home workspace mode transition BEFORE assigning `rigs` so rig -> full keeps this frame's `rigs`
    if home_ws != "" && listed_by_ws.contains(home_ws) {
      let listed_rig = listed_by_ws.get(home_ws).unwrap()
      if st.get("rig") is None {
        match rp_map.get(home_ws) {
          Some(rp) if listed_rig is Some(_) && listed_rig == text_of(field(rp, "owner")) =>
            if !due_list.contains(home_ws) {
              due_list.push(home_ws)
            }
          _ => ()
        }
      } else if fp_map.contains(home_ws) && listed_rig is None {
        (p.log)(
          "this rig is listed as a whole station, as its person signed: it becomes one",
        )
        st.remove("rig")
        fp_map.remove(home_ws)
        cleared_rig_ws.push(home_ws)
      }
    }
    // Check joined workspaces mode transition BEFORE assigning `rigs`
    if st.get("joined") is Some(Array(js)) {
      let updated_joined = js.map(j => match j {
        Object(jm) => {
          let jws = text_of(jm.get("workspace")).unwrap_or("")
          if jws != "" && listed_by_ws.contains(jws) {
            let listed_rig = listed_by_ws.get(jws).unwrap()
            if jm.get("rig") is None {
              match rp_map.get(jws) {
                Some(rp) if listed_rig is Some(_) && listed_rig == text_of(field(rp, "owner")) =>
                  if !due_list.contains(jws) {
                    due_list.push(jws)
                  }
                _ => ()
              }
              Json::object(jm)
            } else if fp_map.contains(jws) && listed_rig is None {
              (p.log)(
                "this rig is listed as a whole station, as its person signed: it becomes one",
              )
              let out = jm.copy()
              out.remove("rig")
              fp_map.remove(jws)
              cleared_rig_ws.push(jws)
              Json::object(out)
            } else {
              Json::object(jm)
            }
          } else {
            Json::object(jm)
          }
        }
        other => other
      })
      st["joined"] = Json::array(updated_joined)
    }
    if due_list.length() > 0 {
      st["rig_due"] = Json::array(due_list.map(Json::string))
    } else {
      st.remove("rig_due")
    }
    if fp_map.is_empty() {
      st.remove("full_pending")
    } else {
      st["full_pending"] = Json::object(fp_map)
    }
    // Assign `rigs` after mode transitions so a rig -> full workspace keeps this frame's `rigs`
    let home_rigs = raw_rigs_by_ws.get(home_ws).unwrap_or(rigs_of(field(body, "rigs")))
    if home_rigs.length() > 0 && st.get("rig") is None {
      st["rigs"] = Json::array(home_rigs)
    } else {
      st.remove("rigs")
    }
    if st.get("joined") is Some(Array(js)) {
      let with_rigs = js.map(j => match j {
        Object(jm) => {
          let jws = text_of(jm.get("workspace")).unwrap_or("")
          let jr = raw_rigs_by_ws.get(jws).unwrap_or([])
          let out = jm.copy()
          if jr.length() > 0 && out.get("rig") is None {
            out["rigs"] = Json::array(jr)
          } else {
            out.remove("rigs")
          }
          Json::object(out)
        }
        other => other
      })
      st["joined"] = Json::array(with_rigs)
    }
  })
  p.skipped_rig_ws.clear()
  if skipped_rig_ws.length() > 0 {
    for ws in skipped_rig_ws {
      p.skipped_rig_ws.push(ws)
    }
    p.last_skipped_frame = Some(body)
  } else {
    p.last_skipped_frame = None
  }
  // When no rig workspaces remain at all, remove grants.json; otherwise per-ws clearing handles it.
  if cleared_rig_ws.length() > 0 &&
    !s.memberships().iter().any(m => s.rig_in(m.workspace)) {
    (p.rig_grants_gone)()
  }
  sync_lock(p, field(body, "lock"), send, None)
  // Each joined workspace's lock too, level with the plane's.
  match field(body, "workspaces") {
    Some(Array(js)) =>
      for j in js {
        match text_of(field(j, "workspace")) {
          Some(ws) => {
            let joined = match s.state {
              Some(st) => array_of(st.get("joined")).unwrap_or([])
              None => []
            }
            if joined.iter().any(x => text_of(field(x, "workspace")) == Some(ws)) {
              sync_lock(p, field(j, "lock"), send, Some(ws))
            }
          }
          None => ()
        }
      }
    _ => ()
  }
}

///|
fn which(ws : String?) -> Array[(String, Json)] {
  match ws {
    Some(w) => [("workspace", Json::string(w))]
    None => []
  }
}

///|
fn frame(pairs : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for kv in pairs {
    m[kv.0] = kv.1
  }
  Json::object(m)
}

///|
/// The plane's lock head against this station's, in `ws`: asks for what it lacks, gives what the plane lacks.
fn sync_lock(
  p : PlaneCloud,
  head : Json?,
  send : (Json) -> Unit,
  ws : String?,
) -> Unit {
  let lock = p.lock
  let theirs = match head {
    Some(Object(h)) =>
      match safe_int(h.get("seq")) {
        Some(n) => n.to_int()
        None => -1
      }
    _ => -1
  }
  // A plane from before locks says nothing of one: nothing is given to it.
  let said : Int? = if head is None { None } else { Some(theirs) }
  match ws {
    None => p.plane_lock_seq = said
    Some(w) => p.plane_lock_seqs[w] = said
  }
  let key = ws.unwrap_or("")
  match head {
    Some(Object(h)) if theirs >= 0 && h.get("hash") is Some(String(hash)) =>
      p.plane_lock_hashes[key] = hash
    _ => p.plane_lock_hashes.remove(key)
  }
  let mine = (lock.seq)(ws)
  guard mine is Some(mine) else {
    let pending = (lock.pending)(ws)
    if theirs >= 0 &&
      (pending is Some(_) ||
      (ws is Some(w) && (lock.left_out)(w) == Some("unpinned"))) {
      send(frame([("type", "lock.get"), ("after", -1), ..which(ws)]))
    }
    return
  }
  let genesis = (lock.genesis)(ws)
  match (head, genesis) {
    (Some(Object(h)), Some(g)) if h.get("genesis") is Some(String(hg)) && hg != g =>
      send(
        frame([
          ("type", "lock.get"),
          ("after", Json::number(mine.to_double())),
          ("genesis", Json::string(g)),
          ..which(ws),
        ]),
      )
    _ =>
      if !plane_on_chain(p, ws, theirs) {
        plane_parted(p, ws, send)
      } else if theirs > mine {
        send(
          frame([
            ("type", "lock.get"),
            ("after", Json::number(mine.to_double())),
            ..which(ws),
          ]),
        )
      } else if theirs < mine {
        send(
          frame([
            ("type", "lock.put"),
            ("entries", Json::array((lock.after)(theirs, ws))),
            ..which(ws),
          ]),
        )
      }
  }
}

///|
fn entry_seq(e : Json) -> Int {
  match safe_int(field(e, "seq")) {
    Some(n) => n.to_int()
    None => -1
  }
}

///|
/// Whether the plane's head of `ws`'s lock is on the chain this station goes by, or may be.
fn plane_on_chain(p : PlaneCloud, ws : String?, seq : Int) -> Bool {
  let lock = p.lock
  guard p.plane_lock_hashes.get(ws.unwrap_or("")) is Some(hash) && seq >= 0 else {
    return true
  }
  let at = (lock.after)(seq - 1, ws)
  if at.length() > 0 && entry_seq(at[0]) == seq {
    return (lock.hash_of)(at[0]) == hash
  }
  // Further: unless it is an entry kept here off the chain.
  !(lock.kept)(ws).iter().any(e => (lock.hash_of)(e) == hash)
}

///|
/// The plane's chain of `ws`'s lock parted from the one gone by here: given, once for each head of the plane's and of
/// this station's, what this station goes by from where they part, as what another keeper took (`keep`).
fn plane_parted(p : PlaneCloud, ws : String?, send : (Json) -> Unit) -> Unit {
  let lock = p.lock
  let key = ws.unwrap_or("")
  let hash = p.plane_lock_hashes.get(key).unwrap_or("")
  let chain = (lock.after)(-1, ws)
  let both = "\{hash}>" +
    (if chain.length() == 0 {
      ""
    } else {
      (lock.hash_of)(chain[chain.length() - 1])
    })
  if p.plane_parted.get(key) == Some(both) {
    return
  }
  p.plane_parted[key] = both
  let on : Map[String, Bool] = Map([])
  for e in chain {
    on[(lock.hash_of)(e)] = true
  }
  let kept : Map[String, Json] = Map([])
  for e in (lock.kept)(ws) {
    kept[(lock.hash_of)(e)] = e
  }
  let mut at = kept.get(hash)
  while at is Some(e) && !on.contains((lock.hash_of)(e)) {
    at = match text_of(field(e, "prev")) {
      Some(prev) => kept.get(prev)
      None => None
    }
  }
  let entries = match at {
    Some(a) => {
      let after = chain.filter(e => entry_seq(e) > entry_seq(a))
      if after.length() > put_most {
        after[:put_most].to_owned()
      } else {
        after
      }
    }
    None =>
      if chain.length() > put_most {
        chain[chain.length() - put_most:].to_owned()
      } else {
        chain
      }
  }
  (p.log)(
    "the control plane's copy of the lock parted from the chain this station goes by; it is given this station's",
  )
  if entries.length() > 0 {
    send(
      frame([
        ("type", "lock.put"),
        ("entries", Json::array(entries)),
        ("keep", true),
        ..which(ws),
      ]),
    )
  }
}

///|
/// Entries the plane brought, of `ws`'s lock: more of the pinned lock, or the lock enrolling (or joining) named.
fn take_from_plane(
  p : PlaneCloud,
  raw : Array[Json],
  ws : String?,
  send : (Json) -> Unit,
) -> Unit {
  let lock = p.lock
  let entries = []
  for r in raw {
    match (lock.as_entry)(r) {
      Some(e) => entries.push(e)
      None => {
        (p.log)("the control plane sent a malformed lock entry")
        return
      }
    }
  }
  try {
    if !(lock.pinned)(ws) {
      let pending = (lock.pending)(ws)
      match (pending, ws) {
        (None, Some(w)) if (lock.left_out)(w) == Some("unpinned") => {
          if (lock.names_station)(entries) {
            (lock.take)(entries, ws)
          } else if entries.iter().any(e => text_of(field(e, "kind")) == Some("moved")) {
            (lock.offer_moved)(w, entries)
          }
          return
        }
        (None, _) => return
        (Some(hash), _) => {
          if !entries.iter().any(e => (lock.hash_of)(e) == hash) {
            (p.log)(
              "the control plane's lock is not the one this station was enrolled with",
            )
            return
          }
          (lock.take)(entries, ws)
          (lock.pending_taken)(ws)
        }
      }
    } else {
      let taken = try {
        (lock.take)(entries, ws)
        None
      } catch {
        e => Some(e)
      }
      // What it brought did not bring its head here: its chain parted below the one gone by here.
      match p.plane_lock_hashes.get(ws.unwrap_or("")) {
        Some(hash) if (lock.pinned)(ws) &&
          !(lock.kept)(ws).iter().any(e => (lock.hash_of)(e) == hash) =>
          plane_parted(p, ws, send)
        _ => ()
      }
      match taken {
        Some(e) => raise e
        None => ()
      }
    }
  } catch {
    e =>
      (p.log)(
        "the control plane's lock entries were refused: \{error_words(e)}",
      )
  }
}

///|
/// The joined workspaces whose lock, named by joining, is to be asked for now: not pinned yet, the plane having one
/// there, not asked for on this connection (`asked`); the home workspace's (None) too, where a lock to pin was named
/// there since the plane's last frame (a rig its person took in naming the workspace's lock, FB-45).
pub fn pending_asks(p : PlaneCloud, asked : Map[String, Bool]) -> Array[String?] {
  let out : Array[String?] = []
  let plane_home = p.plane_lock_seq.unwrap_or(-1)
  if !(p.lock.pinned)(None) && plane_home >= 0 {
    match (p.lock.pending)(None) {
      Some(home) if !asked.contains("/\{home}") => {
        asked["/\{home}"] = true
        out.push(None)
      }
      _ => ()
    }
  }
  let joined = match p.cloud.state {
    Some(st) => array_of(st.get("joined")).unwrap_or([])
    None => []
  }
  for j in joined {
    let ws = text_of(field(j, "workspace")).unwrap_or("")
    let plane = match p.plane_lock_seqs.get(ws) {
      Some(Some(n)) => n
      _ => -1
    }
    if (p.lock.left_out)(ws) != Some("pending") || plane < 0 {
      continue
    }
    let pending = (p.lock.pending)(Some(ws)).unwrap_or("null")
    let key = "\{ws}/\{pending}"
    if asked.contains(key) {
      continue
    }
    asked[key] = true
    out.push(Some(ws))
  }
  out
}

///|
/// What a station tells the plane of its locks on one socket: the entries it took since the socket opened, and the
/// locks joining named, asked for. `tell` as cloud.json changes, `ask_pending` as it hears it joined and at each ping.
pub fn plane_teller(
  p : PlaneCloud,
  send : (Json) -> Unit,
  open : () -> Bool,
) -> (() -> Unit, () -> Unit) {
  let told : Map[String, Int] = Map([])
  let asked : Map[String, Bool] = Map([])
  let ask_pending = fn() {
    if !open() {
      return
    }
    for ws in pending_asks(p, asked) {
      match ws {
        Some(w) => send({ "type": "lock.get", "after": -1, "workspace": Json::string(w) })
        None => send({ "type": "lock.get", "after": -1 })
      }
    }
  }
  let tell = fn() {
    for m in p.cloud.memberships() {
      let ws = if m.home { None } else { Some(m.workspace) }
      let seq = (p.lock.seq)(ws)
      let plane = match ws {
        None => p.plane_lock_seq
        Some(w) =>
          match p.plane_lock_seqs.get(w) {
            Some(v) => v
            None => None
          }
      }
      let was = match told.get(m.workspace) {
        Some(v) => v
        None => seq.unwrap_or(-1)
      }
      if !told.contains(m.workspace) {
        told[m.workspace] = was
      }
      guard seq is Some(seq) && open() && plane is Some(plane) else { continue }
      if !plane_on_chain(p, ws, plane) {
        plane_parted(p, ws, send)
        continue
      }
      if seq <= was {
        continue
      }
      let entries = (p.lock.after)(if plane > -1 { plane } else { -1 }, ws)
      if entries.length() > 0 {
        send(
          frame([("type", "lock.put"), ("entries", Json::array(entries)), ..which(ws)]),
        )
      }
      told[m.workspace] = seq
    }
    ask_pending()
  }
  (tell, ask_pending)
}

///|
/// What a station tells still.fail's cloud of its workspaces' ways on one socket: the record it keeps of each workspace
/// it is in, as the socket opens and as one changes, each record once a socket. A rig tells none.
pub fn ways_teller(
  ways : Ways,
  send : (Json) -> Unit,
  open : () -> Bool,
) -> () -> Unit {
  let told : Map[String, String] = Map([])
  fn() {
    if !open() {
      return
    }
    for m in (ways.cloud.memberships)() {
      if (ways.cloud.rig_in)(m.workspace) {
        continue
      }
      guard ways.record(m.workspace) is Some(r) else { continue }
      if told.get(m.workspace) == Some(r.word()) {
        continue
      }
      told[m.workspace] = r.word()
      send({
        "type": "ways.put",
        "workspace": Json::string(m.workspace),
        "relays": Json::array(r.relays.map(x => Json::string(x.url))),
        "off": Json::array(r.off.map(Json::string)),
        "at": int_json(r.at),
        "station": Json::string(r.station),
      })
    }
  }
}

///|
/// The plane says the station is out of its workspace: marked in cloud.json, kept through restarts.
fn removed(p : PlaneCloud, code : Int) -> Unit {
  if p.cloud.removed() {
    return
  }
  (p.log)(
    "this station was removed from its workspace; it stops its work and refuses connections (\{code})",
  )
  let now = (p.now_secs)()
  p.cloud.update(st => {
    st["removed_at"] = int_json(now)
    st["removed_code"] = Json::number(code.to_double())
  })
}

///|
/// The plane took the socket: a station it had removed is in its workspace again.
fn taken_back(p : PlaneCloud, plane : ProviderSpec) -> Unit {
  if !p.cloud.removed() {
    return
  }
  (p.log)("\{plane.name} takes this station again; back to work")
  p.cloud.update(st => {
    st.remove("removed_at")
    st.remove("removed_code")
  })
}

// ── the socket ──

///|
/// Whether the station answers: what keeps the socket (open while it does).
pub struct Up {
  mut value : Bool
  priv told : Listeners
}

///|
pub fn Up::new(value : Bool) -> Up {
  { value, told: Listeners::new() }
}

///|
pub fn Up::set(self : Up, value : Bool) -> Unit {
  if self.value == value {
    return
  }
  self.value = value
  self.told.tell()
}

///|
/// Returns once it is `wanted`.
pub async fn Up::until(self : Up, wanted : Bool) -> Unit {
  if self.value == wanted {
    return
  }
  let d : @effect.Deferred[Unit] = @effect.Deferred::new()
  let stop = self.told.add(() => if self.value == wanted { ignore(d.succeed(())) })
  defer stop()
  d.wait()
}

///|
/// What the presence socket is given.
pub(all) struct PresenceParts {
  plane : PlaneCloud
  /// The workspaces' ways (still.fail's plane is told them).
  ways : Ways
  spec : () -> ProviderSpec
  /// The station's key's signature of a message (hex).
  sign : (String) -> String
  version : String
  up : Up
  /// Sockets opened by themselves (not still.fail's through an entry).
  ws : WsIO
  /// still.fail's transport, which opens its sockets through an entry where one is named.
  transport : CloudTransport
  said : (CloudSaid) -> Unit
  /// The heartbeat's timer (tests: theirs).
  every : (Int, () -> Unit) -> () -> Unit
  /// The roster's grace and other timers that are no wait of the loop's.
  timers : After
  /// <data>/run/presence.json: online, why not, another station on this key.
  write_presence : (Bool, String?, Bool) -> Unit
}

///|
/// How one socket ended: why, the plane's close code (None: it broke), whether it held a heartbeat first.
pub(all) struct Ended {
  why : String
  code : Int?
  held : Bool
}

///|
/// Keeps the socket for good (until interrupted): open while the station is up.
pub async fn presence(parts : PresenceParts) -> Unit {
  let p = parts.plane
  let mut backoff = 1000
  let replaced = Replaced::new(told=conflict => (parts.write_presence)(
    !conflict,
    if conflict {
      Some(conflict_error)
    } else {
      None
    },
    conflict,
  ))
  while true {
    if !parts.up.value {
      parts.up.until(true)
      backoff = 1000
    }
    (p.reload)()
    if p.cloud.removed() {
      // Only enrolling it again (which changes cloud.json) brings it back, and nothing else is asked until then.
      (parts.write_presence)(
        false,
        Some("removed from its workspace; enroll it again to bring it back"),
        false,
      )
      let d : @effect.Deferred[Unit] = @effect.Deferred::new()
      let stop = p.cloud.told.add(() => if !p.cloud.removed() {
        ignore(d.succeed(()))
      })
      {
        defer stop()
        d.wait()
      }
      continue
    }
    let started = @effect.now()
    let plane = (parts.spec)()
    let not_answering = {
      why: "station not answering; went offline at \{plane.name}",
      code: None,
      held: false,
    }
    let ended : Result[Ended, String] = @effect.race_first(
      async fn() { connect(parts, plane, replaced) },
      async fn() {
        parts.up.until(false)
        Ok(not_answering)
      },
    )
    p.lapse(parts.timers)
    if ended is Ok(e) {
      replaced.ended(e.code, e.held)
    }
    let why = match ended {
      Ok(e) => e.why
      Err(e) => e
    }
    (parts.write_presence)(
      false,
      Some(if replaced.conflict { "\{conflict_error} (\{why})" } else { why }),
      replaced.conflict,
    )
    match ended {
      Ok(_) => if !replaced.conflict { (p.log)(why) }
      Err(_) => (p.log)("no presence socket to \{plane.name}: \{why}")
    }
    // A socket that held a while starts over quickly; failing again and again backs off to a minute; another station
    // on this key waits the minute at once.
    if @effect.now() - started > 60_000L {
      backoff = 1000
    }
    if replaced.conflict {
      backoff = conflict_backoff_ms
    }
    @effect.sleep(backoff) // timer: a retry after a failure, with a backoff
    backoff = if backoff * 2 < 60_000 { backoff * 2 } else { 60_000 }
  }
}

///|
/// The origin's WebSocket URL (`http` made `ws`, the first only).
fn ws_url(origin : String, path : String) -> String {
  let o = if origin.has_prefix("http") {
    "ws" + origin.unsafe_substring(start=4, end=origin.length())
  } else {
    origin.replace(old="http", new="ws")
  }
  o + path
}

///|
/// One socket, signed at connect like enrollment: Ok with why it ended when the plane closes it, Err when it can't be
/// had or breaks; closed when interrupted.
async fn connect(
  parts : PresenceParts,
  plane : ProviderSpec,
  replaced : Replaced,
) -> Result[Ended, String] {
  let p = parts.plane
  let done : @effect.Deferred[Result[Ended, String]] = @effect.Deferred::new()
  let mut ping : () -> Unit = fn() {  }
  let mut unlisten : () -> Unit = fn() {  }
  let mut unlisten_ways : () -> Unit = fn() {  }
  let socket : Ref[WsSocket?] = Ref(None)
  let regional = Ref(false)
  let cleanup = fn() {
    ping()
    unlisten()
    unlisten_ways()
  }
  let prepared = try {
    let st = match p.cloud.state {
      Some(m) => m
      None => raise NetError("this station is not enrolled")
    }
    let station = text_of(st.get("station")).unwrap_or("")
    let origin = text_of(st.get("origin")).unwrap_or("")
    let ts = (p.now_secs)()
    // New planes read the canonical proof; old ones their original one.
    let headers = signed_headers(
      plane.connect_prefixes,
      station,
      ts,
      prefix => (parts.sign)("\{prefix}-station-connect-v1:\{origin}:\{station}:\{ts}"),
      extra=[("version", parts.version)],
    )
    let url = ws_url(origin, plane.connect_path)
    regional.val = plane.provider is Stillfail &&
      parts.transport.eligible(origin, provider=plane.provider)
    let mut answered = true
    let mut held = false
    let mut failed : String? = None
    let send = (frame : Json) => match socket.val {
      Some(s) => (s.send)(frame.stringify())
      None => ()
    }
    let open = () => match socket.val {
      Some(s) => (s.is_open)()
      None => false
    }
    let (tell, ask_pending) = plane_teller(p, send, open)
    // The workspaces' ways, to still.fail's cloud alone.
    let tell_ways = if plane.provider is Stillfail {
      ways_teller(parts.ways, send, open)
    } else {
      fn() {  }
    }
    let events = {
      open: fn() {
        taken_back(p, plane)
        // Another station on this key still, until this socket holds.
        (parts.write_presence)(
          true,
          if replaced.conflict {
            Some(conflict_error)
          } else {
            None
          },
          replaced.conflict,
        )
        (p.log)("online at \{plane.name}")
        tell_ways()
        // timer: a heartbeat that keeps the connection
        ping = (parts.every)(ping_ms, fn() {
          // No pong since the last ping: gone even if the socket has not noticed.
          if !answered {
            failed = Some("\{plane.name} stopped answering")
            match socket.val {
              Some(s) => (s.terminate)()
              None => ()
            }
            return
          }
          answered = false
          match socket.val {
            Some(s) => (s.send)("ping")
            None => ()
          }
          ask_pending()
        })
      },
      message: fn(text) {
        if text == "pong" {
          answered = true
          if !held {
            held = true
            replaced.steady()
          }
          return
        }
        // Each frame is told by its parsed `type`, never by where that field sits in the text.
        let body = match (try Some(@json.parse(text)) catch { _ => None }) {
          Some(b) => b
          None => return
        }
        if cloud_said(body, parts.said) {
          return
        }
        if text_of(field(body, "type")) == Some("tool") {
          tool(p, plane, socket.val, body)
        } else {
          apply_frame(p, body, frame => if open() { send(frame) })
        }
      },
      unexpected: fn(status) {
        if status == 404 {
          removed(p, 404)
          failed = Some("station removed")
        } else {
          failed = Some("\{plane.name} answered \{status}")
        }
        match socket.val {
          Some(s) => (s.terminate)()
          None => ()
        }
      },
      error: fn(e) {
        if failed is None {
          failed = Some(e)
        }
      },
      close: fn(code, reason) {
        cleanup()
        if code == close_removed {
          removed(p, close_removed)
        }
        let why = if reason.length() > 0 { "\{code} \{reason}" } else { "\{code}" }
        ignore(
          done.succeed(
            match failed {
              Some(f) => Err(f)
              None =>
                Ok({
                  why: "\{plane.name} closed the presence socket (\{why})",
                  code: Some(code),
                  held,
                })
            },
          ),
        )
      },
    }
    socket.val = Some(
      if regional.val {
        parts.transport.websocket(url, headers, parts.ws, events)
      } else {
        (parts.ws.open)(url, headers, None, events)
      },
    )
    tell()
    unlisten = p.cloud.told.add(() => {
      ignore(replay_skipped_rig_frame(p, frame => if open() { send(frame) }))
      tell()
      tell_ways()
    })
    if plane.provider is Stillfail {
      unlisten_ways = parts.ways.listen(_ => tell_ways())
    }
    Ok(())
  } catch {
    e => Err(error_words(e))
  }
  match prepared {
    Err(e) => {
      // Connection preparation can fail before a socket says anything: the same status and retry path.
      cleanup()
      match socket.val {
        Some(s) => (s.terminate)()
        None => ()
      }
      return Err(e)
    }
    Ok(_) => ()
  }
  let over = Ref(false)
  // (interrupted while it waits: closed, as the station stops answering or the loop is let go)
  defer {
    if !over.val {
      cleanup()
      match socket.val {
        Some(s) => if regional.val { (s.terminate)() } else { (s.close)() }
        None => ()
      }
    }
  }
  let ended = done.wait()
  over.val = true
  ended
}

///|
/// A device tool request pushed on the socket (`{type: "tool", id, request}`): run by the mesh's tools and answered
/// `{type: "tool_result", id, response}`. Only a provider with device tools pushes them; locked, the plane pushes none.
fn tool(p : PlaneCloud, plane : ProviderSpec, socket : WsSocket?, body : Json) -> Unit {
  guard text_of(field(body, "id")) is Some(id) else { return }
  let reply = (response : Json) => match socket {
    Some(s) =>
      if (s.is_open)() {
        let answer : Json = {
          "type": "tool_result",
          "id": Json::string(id),
          "response": response,
        }
        (s.send)(answer.stringify())
      }
    None => ()
  }
  let run = if plane.tools && !(p.lock.locked)() { p.tool_calls } else { None }
  match run {
    None =>
      reply({
        "ok": false,
        "error": {
          "code": "unavailable",
          "message": "this station takes no device tools now",
        },
      })
    Some(run) =>
      run(field(body, "request").unwrap_or(Json::null()), r => match r {
        Ok(v) => reply(v)
        Err(m) =>
          reply({
            "ok": false,
            "error": { "code": "invalid_request", "message": Json::string(m) },
          })
      })
  }
}
