// A rig on the station transport (rig/module.ts; a station that only runs tasks in one or more workspaces): what it
// answers each rig-mode workspace's stations, and what it tells them. Works both in pure-rig processes (`RigLive`)
// and in mixed-mode processes (`StationLive` with one or more rig-mode workspaces).

///|
/// What a station asks of a rig without a grant: how it is and who may use it, what its person signed, and what reads
/// back, stops or clears what a chat of that station ran here (keyed by that station and session: jobs/remote.ts).
pub let ungated : Array[String] = [
  "describe", "task.get", "task.gets", "task.log", "task.list", "task.stop", "task.files", "task.collected", "task.mirrors",
  "task.clean", "file.get", "sync.changes", "session.close", "session.size", "vault.capabilities", "vault.revoke",
]

///|
/// Explicit allowlist of peer RPC methods a rig-mode workspace accepts (besides `rig.*`, `lock.*`, `ways.*` handled
/// at the peer gate). Any other method on a rig-mode workspace (e.g. sessions/chats/memory/replica/rigs/move) is refused.
pub let rig_allowed_exact : Array[String] = [
  "describe",
  "task.prepare",
  "task.start",
  "task.get",
  "task.gets",
  "task.log",
  "task.list",
  "task.stop",
  "task.files",
  "task.collected",
  "task.mirrors",
  "task.clean",
  "file.put",
  "file.get",
  "sync.changes",
  "sync.apply",
  "session.close",
  "session.size",
  "vault.capabilities",
  "vault.run",
  "vault.capture",
  "vault.revoke",
]

///|
/// A station not told is told again after this, then twice as long each time, a minute apart at most, for an hour: one
/// back later asks for itself (rigs/module.ts, as it starts).
let again_ms : Double = 1000.0

///|
let again_max_ms : Double = 60000.0

///|
let again_for_ms : Double = 3600000.0

///|
/// The most lines of the command log a station is given at once.
let log_max : Double = 200.0

///|
/// A connection to a device of this rig (devices/connect.ts `reachDevice`'s socket).
pub(all) struct Socket {
  destroy : () -> Unit
  on_close : (() -> Unit) -> Unit
  pipe : async (Json) -> Unit
}

///|
/// A device's connection refused (mesh/peer-http.ts `DeviceRefused`): its status and why.
pub(all) suberror DeviceRefused {
  DeviceRefused(Int, String)
}

///|
pub impl Show for DeviceRefused with output(self, logger) {
  match self {
    DeviceRefused(_, m) => logger.write_string(m)
  }
}

///|
pub(all) struct RigDeps {
  data : String
  cloud : @cloud_lock.Cloud
  /// The peer bus's `ask` of a station: raises `Refused` where it heard and refused, anything else where not reached.
  ask : async (String, Json) -> Json
  /// Whether a chat (workspace, station, session) has something running here, stopping it, and all that have.
  busy : (String, String, String) -> Bool
  stop : (String, String, String) -> Unit
  running : () -> Array[(String, String, String)]
  /// devices/connect.ts `reachDevice`.
  reach : async (Json) -> Socket
  /// Join another workspace as a rig (`token`, `person`, `lock`, `expected_workspace`), returning the joined workspace info.
  join : (async (String, String, String?, String?) -> Json)?
  /// A fiber of the rig's own (`void` of a promise in the TypeScript).
  spawn : (async () -> Unit) -> Unit
  clock : Clock
  files : Files
  crypto : @cloud_lock.Crypto
  host : @host.Host
}

///|
priv struct Untold {
  id : Int
  wait : Double
  mut stop : () -> Unit
}

///|
priv struct Wire {
  workspace : String
  device : String
  station : String
  session : String
  socket : Socket
}

///|
pub struct Rig {
  grants : RigGrants
  commands : CommandLog
  priv d : RigDeps
  /// The stations not told the last change yet, keyed by `ws + "\u0000" + station`.
  priv untold : Map[String, Untold]
  priv mut next_untold : Int
  priv mut unlisten : (() -> Unit)?
  priv mut known : Array[String]
  /// The chats' connections to this rig's devices open now.
  priv wired : Array[Wire]
}

///|
fn untold_key(ws : String, station : String) -> String {
  ws + "\u0000" + station
}

///|
fn truthy(v : Json?) -> Bool {
  @jsjson.json_truthy(v)
}

///|
fn cloud_state(cloud : @cloud_lock.Cloud) -> Json? {
  match cloud.state {
    Some(s) => Some(Json::object(s.fields))
    None => None
  }
}

///|
/// What this machine is in `ws`, when it is a rig in that workspace.
pub fn rig_self_in(cloud : @cloud_lock.Cloud, ws : String) -> RigSelf? {
  if ws == "" || cloud.removed() {
    return None
  }
  guard cloud_state(cloud) is Some(s) else { return None }
  guard cloud.rig_in(ws) is Some(rig) else { return None }
  Some({
    id: js_string_of(get(Some(s), "station")),
    workspace: ws,
    owner: js_string_of(get(Some(rig), "owner")),
    person: js_string_of(get(Some(rig), "person")),
  })
}

fn rig_ws_ids(cloud : @cloud_lock.Cloud) -> Array[String] {
  cloud.rig_memberships().filter_map(m => str_at(Some(m), "workspace"))
}

///|
/// Compatibility helper: first rig-mode workspace's `RigSelf`, if any.
pub fn rig_self(cloud : @cloud_lock.Cloud) -> RigSelf? {
  match rig_ws_ids(cloud).get(0) {
    Some(ws) => rig_self_in(cloud, ws)
    None => None
  }
}

///|
pub fn Rig::new(d : RigDeps) -> Rig {
  let cell : Ref[Rig?] = Ref(None)
  let grants = RigGrants::new({
    path: d.data + "/rig/grants.json",
    self_for: ws => rig_self_in(d.cloud, ws),
    workspaces: () => rig_ws_ids(d.cloud),
    busy: d.busy,
    stop: d.stop,
    running: d.running,
    ended: (ws, ended) => if cell.val is Some(r) {
      r.tell(ws, str_at(Some(ended), "station").unwrap_or(""), Some(ended))
    },
    changed: ws => if cell.val is Some(r) { r.tell_all(ws) },
    cut: Some((ws, device, station, session) => if cell.val is Some(r) { r.cut(ws, device, station, session) }),
    clock: d.clock,
    files: d.files,
    crypto: d.crypto,
  })
  let r : Rig = {
    grants,
    commands: CommandLog::new(d.host, d.data + "/rig/commands.log"),
    d,
    untold: Map([]),
    next_untold: 0,
    unlisten: None,
    known: [],
    wired: [],
  }
  cell.val = Some(r)
  r
}

///|
/// The bus is attached (`whenAttached`): every station in each rig-mode workspace is told this rig is here; one new to
/// the roster after is told, one gone no longer tried. Leaving a rig-mode workspace clears its grants/devices.
pub fn Rig::attached(self : Rig) -> Unit {
  let waited : Map[String, Bool] = Map([])
  let active : Ref[Array[String]] = Ref(rig_ws_ids(self.d.cloud))
  let home = self.d.cloud.home()
  for ws in active.val {
    let at_ws = if Some(ws) == home { None } else { Some(ws) }
    waited[ws] = self.d.cloud.waiting(ws=at_ws)
    self.tell_all(ws, hello=true)
  }
  self.unlisten = Some(
    self.d.cloud.listen(_ => {
      let now_ws = rig_ws_ids(self.d.cloud)
      let home_now = self.d.cloud.home()
      for old_ws in active.val {
        if !now_ws.contains(old_ws) {
          self.grants.clear_workspace(old_ws)
          waited.remove(old_ws)
          self.drop_workspace_untold(old_ws)
        }
      }
      active.val = now_ws
      for ws in now_ws {
        let at_ws = if Some(ws) == home_now { None } else { Some(ws) }
        let was = waited.get(ws).unwrap_or(false)
        let cur = self.d.cloud.waiting(ws=at_ws)
        waited[ws] = cur
        self.tell_all(ws, hello=true, fresh=!(was && !cur))
      }
    }),
  )
}

///|
fn Rig::drop_workspace_untold(self : Rig, ws : String) -> Unit {
  let prefix = ws + "\u0000"
  for k in self.untold.keys().collect() {
    if k.has_prefix(prefix) {
      if self.untold.get(k) is Some(w) {
        (w.stop)()
      }
      self.untold.remove(k)
    }
  }
  self.known = self.known.filter(k => !k.has_prefix(prefix))
}

///|
pub fn Rig::self_(self : Rig, workspace? : String? = None) -> RigSelf? {
  match workspace {
    Some(ws) => rig_self_in(self.d.cloud, ws)
    None => rig_self(self.d.cloud)
  }
}

///|
/// What `describe` says besides a station's own for `workspace`: `{}` for a full workspace, else rig view + flags.
pub fn Rig::described(self : Rig, workspace? : String? = None) -> Json {
  let ws = match workspace {
    Some(w) if w != "" => w
    _ => rig_ws_ids(self.d.cloud).get(0).unwrap_or("")
  }
  guard ws != "" && self.d.cloud.rig_in(ws) is Some(rig_info) else {
    return Json::object(Map([]))
  }
  let rig = match self.grants.view(ws) {
    None => Json::null()
    Some(view) => {
      let or_empty = (k : String) => match get(Some(rig_info), k) {
        None | Some(Null) => jstr("")
        Some(v) => v
      }
      let more = [("owner_email", or_empty("owner_email")), ("owner_name", or_empty("owner_name"))]
      if self.grants.proof(ws) is Some(_) {
        more.push(("proof", jbool(true)))
      }
      spread(Some(view), Some(jobj(more)))
    }
  }
  jobj([
    ("sessions", jbool(false)),
    ("messages", jbool(false)),
    ("reads", jbool(false)),
    ("chats", jbool(false)),
    ("rig", rig),
  ])
}

///|
/// A connection to device `id` here for a chat (`session` of station `peer` in `workspace`).
pub async fn Rig::device(
  self : Rig,
  peer : String,
  workspace : String,
  session : String,
  id : String,
  probe : Bool,
) -> Socket? {
  match self.grants.device_refusal(workspace, peer, session, id, use_=!probe) {
    Some(why) => raise DeviceRefused(if why.contains("no such device") { 404 } else { 403 }, why)
    None => ()
  }
  if probe {
    return None
  }
  let devs = self.grants.devices(workspace)
  guard devs.search_by(x => str_at(Some(x), "id") == Some(id)) is Some(i) else {
    raise DeviceRefused(404, "no such device on this rig")
  }
  let dv = Some(devs[i])
  let socket = (self.d.reach)(dv.unwrap())
  let wire : Wire = { workspace, device: id, station: peer, session, socket }
  self.wired.push(wire)
  (socket.on_close)(() => {
    if self.wired.search_by(w => physical_equal(w, wire)) is Some(at) {
      self.wired.remove(at) |> ignore
    }
  })
  self.commands.add([
    ("at", jnum((self.d.clock.now)())),
    ("workspace", jstr(workspace)),
    ("station", jstr(peer)),
    ("session", jstr(session)),
    ("key", jstr(id)),
    ("name", get(dv, "name").unwrap_or(Json::null())),
    ("command", jstr(js_string_of(get(dv, "kind")) + " " + js_string_of(get(dv, "target")))),
    ("kind", jstr("device")),
  ])
  Some(socket)
}

///|
/// The connections to `device` in `workspace` (of one chat, or of all) looked at again: those no longer let through are cut.
fn Rig::cut(self : Rig, workspace : String, device : String, station : String?, session : String?) -> Unit {
  for w in self.wired.copy() {
    if w.workspace != workspace ||
      w.device != device ||
      (station is Some(s) && w.station != s) ||
      (session is Some(s) && w.session != s) {
      continue
    }
    if self.grants.device_refusal(workspace, w.station, w.session, device, use_=false) is None {
      continue
    }
    if self.wired.search_by(x => physical_equal(x, w)) is Some(at) {
      self.wired.remove(at) |> ignore
    }
    (w.socket.destroy)()
  }
}

///|
/// Why a station may not reach this rig's services in `workspace` now (mesh/peer-http.ts), or None.
pub fn Rig::station_refusal(self : Rig, peer : String, workspace : String) -> String? {
  self.grants.station_refusal(workspace, peer)
}

///|
/// The bus's guard (`guarded`): for a full workspace, lets everything through; for a rig-mode workspace, enforces the
/// explicit rig method allowlist and per-chat grant.
pub fn Rig::guarded(self : Rig, workspace : String, peer : String, request : Json) -> Unit raise Refused {
  if self.d.cloud.rig_in(workspace) is None {
    return
  }
  let r = Some(request)
  let meth = str_at(r, "method").unwrap_or("")
  if !rig_allowed_exact.contains(meth) && !meth.has_prefix("rig.") {
    raise Refused("unknown peer method: \{meth}")
  }
  if ungated.contains(meth) || meth.has_prefix("rig.") {
    return
  }
  let session = str_at(r, "session").unwrap_or("")
  if session == "" {
    raise Refused("a rig runs only what a chat asks of it (no session named)")
  }
  if self.grants.refusal(workspace, peer, session) is Some(why) {
    raise Refused(why)
  }
  // What it is told to run, kept here (rig/log.ts).
  let or_empty = (v : Json?) => match v {
    None | Some(Null) => ""
    _ => js_string_of(v)
  }
  if meth == "task.prepare" && str_at(get(r, "spec"), "command") is Some(command) {
    self.commands.add([
      ("at", jnum((self.d.clock.now)())),
      ("workspace", jstr(workspace)),
      ("station", jstr(peer)),
      ("session", jstr(session)),
      ("key", jstr(or_empty(get(r, "key")))),
      ("name", jstr(or_empty(get(get(r, "spec"), "name")))),
      ("command", jstr(command)),
      ("kind", jstr("task")),
    ])
  } else if (meth == "vault.run" || meth == "vault.capture") && str_at(r, "command") is Some(command) {
    self.commands.add([
      ("at", jnum((self.d.clock.now)())),
      ("workspace", jstr(workspace)),
      ("station", jstr(peer)),
      ("session", jstr(session)),
      ("key", jstr(or_empty(get(r, "id")))),
      ("name", jstr("")),
      ("command", jstr(command)),
      ("kind", jstr("secret")),
    ])
  }
}

///|
/// Its person took it into `workspace` in safe mode naming the workspace's lock (FB-45).
fn Rig::pin_named(self : Rig, workspace : String, lock : String?) -> Unit {
  guard lock is Some(hash) else { return }
  let cloud = self.d.cloud
  let at_ws = if cloud.home() == Some(workspace) { None } else { Some(workspace) }
  let path = match at_ws {
    None => @cloud_lock.pending_lock_path(self.d.data)
    Some(w) => @cloud_lock.joined_pending_path(self.d.data, w)
  }
  let named = match (self.d.files.read)(path).bind(@cloud_lock.parse) {
    Some({ "hash": String(h), .. }) => @cloud_lock.is_hex32(h)
    _ => false
  }
  if cloud.chain(ws=at_ws) is Some(_) || named {
    return
  }
  (self.d.files.mkdir)(@cloud_lock.dirname(path))
  (self.d.files.write)(path, ({ "hash": Json::string(hash) } : Json).stringify()) catch {
    _ => return
  }
  cloud.lock_named()
}

///|
/// What a station asks of `rig.` (`bus.on("rig.")`).
pub async fn Rig::heard(self : Rig, peer : String, request : Json, workspace : String) -> Json {
  let r = Some(request)
  let meth = str_at(r, "method").unwrap_or("")
  guard rig_self_in(self.d.cloud, workspace) is Some(me) else {
    raise Refused("this machine is no rig of that workspace")
  }
  match meth {
    "rig.describe" => self.described(workspace=Some(workspace))
    "rig.grant" => {
      let until = self.grants.grant(workspace, peer, get(r, "signed"), get(r, "chain"))
      jobj([("until", jnum(until))])
    }
    "rig.revoke" => {
      self.grants.revoke(workspace, get(r, "signed"), get(r, "chain"))
      jobj([("ok", jbool(true))])
    }
    "rig.release" => {
      let request = match get(r, "request") {
        None | Some(Null) => ""
        v => js_string_of(v)
      }
      jobj([("released", jbool(self.grants.release(workspace, peer, request)))])
    }
    "rig.settings" => {
      self.grants.take_settings(workspace, get(r, "signed"), get(r, "chain"))
      jobj([("ok", jbool(true))])
    }
    "rig.device" => {
      self.grants.device(workspace, get(r, "signed"), get(r, "chain"))
      jobj([("ok", jbool(true))])
    }
    "rig.added" => {
      let lock = self.grants.added(workspace, get(r, "signed"), pin=get(r, "pin"), chain=get(r, "chain"))
      self.pin_named(workspace, lock)
      jobj([("ok", jbool(true))])
    }
    "rig.full" => {
      let s = self.grants.full(workspace, get(r, "signed"), get(r, "chain"))
      let at = get(get(Some(s), "body"), "at").unwrap_or(Json::null())
      self.d.cloud.update(st => {
        let fp = match st.fields.get("full_pending") {
          Some(Object(m)) => m.copy()
          _ => Map([])
        }
        fp[workspace] = jobj([("at", at)])
        st.fields["full_pending"] = Json::object(fp)
      })
      jobj([("ok", jbool(true))])
    }
    "rig.join" => {
      let s = self.grants.join(workspace, get(r, "signed"), get(r, "chain"))
      let body = get(Some(s), "body")
      let target_ws = str_at(body, "ws").unwrap_or("")
      let token = str_at(body, "token").unwrap_or("")
      let lock = str_at(body, "lock")
      guard self.d.join is Some(do_join) else {
        raise Refused("joining another workspace is not available on this rig")
      }
      let joined = do_join(token, me.person, lock, if target_ws == "" { None } else { Some(target_ws) })
      let actual_ws = str_at(Some(joined), "workspace").unwrap_or("")
      if target_ws != "" && actual_ws != target_ws {
        raise Refused("enrollment token is for workspace \{actual_ws}, not \{target_ws}")
      }
      jobj([
        ("ok", jbool(true)),
        ("workspace", get(Some(joined), "workspace").unwrap_or(jstr(""))),
        ("workspace_name", get(Some(joined), "workspace_name").unwrap_or(jstr(""))),
        ("name", get(Some(joined), "name").unwrap_or(jstr(""))),
      ])
    }
    "rig.proof" => jobj([("add", self.grants.proof(workspace).unwrap_or(Json::null()))])
    "rig.log" => {
      let limit = match get(r, "limit") {
        Some(Number(n, ..)) if safe_int(n) => if n < 1.0 { 1.0 } else if n > log_max { log_max } else { n }
        _ => 50.0
      }
      let include_legacy = rig_ws_ids(self.d.cloud).length() == 1
      let commands = self.commands.last(limit.to_int(), workspace=Some(workspace), include_legacy~)
      jobj([("commands", jarr(commands))])
    }
    _ => raise Refused("unknown method \{meth}")
  }
}

///|
/// The stations of `workspace` now.
fn Rig::stations(self : Rig, workspace : String) -> Array[String] {
  guard rig_self_in(self.d.cloud, workspace) is Some(me) else { return [] }
  let peers = arr_at(self.d.cloud.membership(workspace), "peers").unwrap_or([])
  let out = []
  for p in peers {
    if str_at(Some(p), "id") is Some(id) && id != me.id {
      out.push(id)
    }
  }
  out
}

///|
/// Every station in `workspace` told how this rig is now.
fn Rig::tell_all(self : Rig, workspace : String, hello? : Bool = false, fresh? : Bool = false) -> Unit {
  let stations = self.stations(workspace)
  let prefix = workspace + "\u0000"
  for k in self.untold.keys().collect() {
    if k.has_prefix(prefix) {
      let st = k.unsafe_substring(start=prefix.length(), end=k.length())
      if !stations.contains(st) {
        if self.untold.get(k) is Some(w) {
          (w.stop)()
        }
        self.untold.remove(k)
      }
    }
  }
  for station in stations {
    let k = untold_key(workspace, station)
    if !fresh || !self.known.contains(k) {
      self.tell(workspace, station, None, hello~)
    }
  }
  let other = self.known.filter(k => !k.has_prefix(prefix))
  for station in stations {
    other.push(untold_key(workspace, station))
  }
  self.known = other
}

///|
/// One station in `workspace` told how this rig is now (and what ended, when a grant of its own did).
fn Rig::tell(self : Rig, workspace : String, station : String, ended : Json?, hello? : Bool = false) -> Unit {
  guard rig_self_in(self.d.cloud, workspace) is Some(_) && self.stations(workspace).contains(station) else { return }
  let k = untold_key(workspace, station)
  if self.untold.get(k) is Some(w) {
    (w.stop)()
  }
  self.untold.remove(k)
  let fields = [("method", jstr(if hello { "rig.hello" } else { "rig.changed" })), ("workspace", jstr(workspace))]
  let request = Ref(
    spread(
      Some(spread(Some(jobj(fields)), Some(self.described(workspace=Some(workspace))))),
      ended.map(e => jobj([("ended", e)])),
    ),
  )
  fn attempt(wait : Double, until : Double) -> Unit {
    (self.d.spawn)(async fn() {
      let failed = try {
        let _ = (self.d.ask)(station, request.val)
        false
      } catch {
        Refused(_) => return
        _ => true
      }
      if !failed || (self.d.clock.now)() >= until {
        return
      }
      let next = if wait * 2.0 < again_max_ms { wait * 2.0 } else { again_max_ms }
      self.next_untold += 1
      let entry : Untold = { id: self.next_untold, wait: next, stop: () => () }
      entry.stop = (self.d.clock.after)(wait, () => {
        guard self.untold.get(k) is Some(e) && e.id == entry.id else { return }
        self.untold.remove(k)
        request.val = spread(Some(request.val), Some(self.described(workspace=Some(workspace))))
        attempt(entry.wait, until)
      })
      self.untold[k] = entry
    })
  }

  attempt(again_ms, (self.d.clock.now)() + again_for_ms)
}

///|
pub async fn Rig::close(self : Rig) -> Unit {
  if self.unlisten is Some(off) {
    off()
  }
  for w in self.untold.values() {
    (w.stop)()
  }
  for w in self.wired {
    (w.socket.destroy)()
  }
  self.wired.clear()
  self.untold.clear()
  self.grants.close()
  self.commands.written()
}
