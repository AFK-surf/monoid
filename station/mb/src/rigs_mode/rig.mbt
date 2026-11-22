// A rig on the station transport (rig/module.ts; a station that only runs tasks, 2026-11-10): what it answers the
// workspace's stations, and what it tells them. A rig is the half of a station that is asked: it runs the tasks
// stations send it (jobs/remote.ts, as a station does for another), and nothing else of a station is in its process
// (no agents, chats, vault or connects: rig/main.ts). Every request passes its grants first (`guard`): what starts or
// writes something here needs the chat it is for to hold a grant its person signed, or 免批准 on; what only reads back
// or stops what a chat ran here does not (a chat that lost its grant still learns how its task ended and takes its
// results).
//
// It asks nothing of a station. It tells them: what became of a task (jobs/remote.ts `task.changed`), that it is here
// (`rig.hello`, as it comes on the mesh and as the roster changes) and that its grants or settings changed
// (`rig.changed`), each with what `describe` says of it, so a station shows it without asking again.
//
// Where the TypeScript's Rig registers itself on the peer bus (`guarded`, `on("rig.")`, `whenAttached`), this one is
// given to the bus by its caller: `guard`, `heard` and `attached` are those.

///|
/// What a station asks of a rig without a grant: how it is and who may use it, what its person signed, and what reads
/// back, stops or clears what a chat of that station ran here (keyed by that station and session: jobs/remote.ts).
pub let ungated : Array[String] = [
  "describe", "task.get", "task.gets", "task.log", "task.list", "task.stop", "task.files", "task.collected", "task.mirrors",
  "task.clean", "file.get", "sync.changes", "session.close", "session.size", "vault.capabilities", "vault.revoke",
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
/// A connection to a device of this rig (devices/connect.ts `reachDevice`'s socket): ended here, told as it closes,
/// and carried both ways with a chat's tunnel to it (mesh/peer-http.ts's pipe of the stream and the socket), the
/// tunnel handed as its program holds it (the stream and what came with its ask), until either ends.
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
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
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
  /// Whether a chat (a station's session) has something running here, stopping it, and all that have (jobs/remote.ts's
  /// tasks: the jobs owned by `remote:<workspace>:<station>:<session>`).
  busy : (String, String, String) -> Bool
  stop : (String, String, String) -> Unit
  running : () -> Array[(String, String, String)]
  /// devices/connect.ts `reachDevice`.
  reach : async (Json) -> Socket
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
  /// The stations not told the last change yet: when to tell each again, and until when it is tried.
  priv untold : Map[String, Untold]
  priv mut next_untold : Int
  priv mut unlisten : (() -> Unit)?
  priv mut known : Array[String]
  /// The chats' connections to this rig's devices open now.
  priv wired : Array[Wire]
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
/// `cloud.state?.workspace ?? ""`.
fn cloud_ws(cloud : @cloud_lock.Cloud) -> String {
  match get(cloud_state(cloud), "workspace") {
    None | Some(Null) => ""
    v => js_string_of(v)
  }
}

///|
/// What this machine is, while it is a rig in a workspace.
pub fn rig_self(cloud : @cloud_lock.Cloud) -> RigSelf? {
  let s = cloud_state(cloud)
  if s is None || get(s, "rig") is None || !truthy(get(s, "workspace")) || cloud.removed() {
    return None
  }
  let rig = get(s, "rig")
  Some({
    id: js_string_of(get(s, "station")),
    workspace: js_string_of(get(s, "workspace")),
    owner: js_string_of(get(rig, "owner")),
    person: js_string_of(get(rig, "person")),
  })
}

///|
pub fn Rig::new(d : RigDeps) -> Rig {
  let cell : Ref[Rig?] = Ref(None)
  let ws = () => cloud_ws(d.cloud)
  let grants = RigGrants::new({
    path: d.data + "/rig/grants.json",
    self_: () => rig_self(d.cloud),
    busy: (station, session) => (d.busy)(ws(), station, session),
    stop: (station, session) => (d.stop)(ws(), station, session),
    running: () => (d.running)().filter(r => r.0 == ws()).map(r => (r.1, r.2)),
    ended: ended => if cell.val is Some(r) {
      r.tell(str_at(Some(ended), "station").unwrap_or(""), Some(ended))
    },
    changed: () => if cell.val is Some(r) { r.tell_all() },
    cut: Some((device, station, session) => if cell.val is Some(r) { r.cut(device, station, session) }),
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
/// The bus is attached (`whenAttached`): every station told this rig is here; one new to the roster after is told it
/// is here, one gone no longer tried. Where the workspace's chain moved and this rig waited for what its state is made
/// of (Cloud `waiting`: a station asked it nothing but the lock's own and what its person signed for it, mesh/peer.ts
/// `heardWaiting`), every station is told once it has it, as it is told as it comes on the mesh (2026-11-14).
pub fn Rig::attached(self : Rig) -> Unit {
  self.tell_all(hello=true)
  let waited = Ref(self.d.cloud.waiting())
  self.unlisten = Some(
    self.d.cloud.listen(_ => {
      let was = waited.val
      waited.val = self.d.cloud.waiting()
      self.tell_all(hello=true, fresh=!(was && !waited.val))
    }),
  )
}

///|
pub fn Rig::self_(self : Rig) -> RigSelf? {
  rig_self(self.d.cloud)
}

///|
/// What `describe` says besides a station's own: that it is a rig, which of a station's things it has none of, and who
/// may use it. (What the asking station's own chats hold is in `grants`, by their station.)
pub fn Rig::described(self : Rig) -> Json {
  let s = cloud_state(self.d.cloud)
  let rig = match self.grants.view() {
    None => Json::null()
    Some(view) => {
      let or_empty = (k : String) => match get(get(s, "rig"), k) {
        None | Some(Null) => jstr("")
        Some(v) => v
      }
      let more = [("owner_email", or_empty("owner_email")), ("owner_name", or_empty("owner_name"))]
      if self.grants.proof() is Some(_) {
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
/// A connection to device `id` here for a chat (`session` of station `peer`): let through by a grant of the rig or of
/// the device, or 免批准, else a DeviceRefused saying why. `probe`: only whether it would be (no use, nothing opened).
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
  guard self.grants.devices().search_by(x => str_at(Some(x), "id") == Some(id)) is Some(i) else {
    raise DeviceRefused(404, "no such device on this rig")
  }
  let dv = Some(self.grants.devices()[i])
  let socket = (self.d.reach)(dv.unwrap())
  let wire : Wire = { device: id, station: peer, session, socket }
  self.wired.push(wire)
  (socket.on_close)(() => {
    if self.wired.search_by(w => physical_equal(w, wire)) is Some(at) {
      self.wired.remove(at) |> ignore
    }
  })
  self.commands.add([
    ("at", jnum((self.d.clock.now)())),
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
/// The connections to `device` (of one chat, or of all) looked at again: those no longer let through are cut.
fn Rig::cut(self : Rig, device : String, station : String?, session : String?) -> Unit {
  let me = self.self_()
  for w in self.wired.copy() {
    if w.device != device ||
      (station is Some(s) && w.station != s) ||
      (session is Some(s) && w.session != s) {
      continue
    }
    if me is Some(m) && self.grants.device_refusal(m.workspace, w.station, w.session, device, use_=false) is None {
      continue
    }
    if self.wired.search_by(x => physical_equal(x, w)) is Some(at) {
      self.wired.remove(at) |> ignore
    }
    (w.socket.destroy)()
  }
}

///|
/// Why a station may not reach this rig's services now (mesh/peer-http.ts), or None.
pub fn Rig::station_refusal(self : Rig, peer : String, workspace : String) -> String? {
  self.grants.station_refusal(workspace, peer)
}

///|
/// The bus's guard (`guarded`): what a station asks passes it, or is refused why.
pub fn Rig::guarded(self : Rig, workspace : String, peer : String, request : Json) -> Unit raise Refused {
  let r = Some(request)
  let meth = str_at(r, "method").unwrap_or("")
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
/// Its person took it into a workspace in safe mode naming the workspace's lock (rig/module.ts `#added`, FB-45): where
/// it pins none and was named none to pin, that one is named, as `enroll --lock` names one, and the control plane is
/// asked for it at once (presence.ts `pendingAsks`). A lock pinned or named already is never replaced from here.
fn Rig::pin_named(self : Rig, lock : String?) -> Unit {
  guard lock is Some(hash) else { return }
  let cloud = self.d.cloud
  let path = @cloud_lock.pending_lock_path(self.d.data)
  let named = match (self.d.files.read)(path).bind(@cloud_lock.parse) {
    Some({ "hash": String(h), .. }) => @cloud_lock.is_hex32(h)
    _ => false
  }
  if cloud.chain() is Some(_) || named {
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
  guard self.self_() is Some(me) && workspace == me.workspace else {
    raise Refused("this rig is of another workspace")
  }
  match meth {
    "rig.describe" => self.described()
    "rig.grant" => {
      let until = self.grants.grant(peer, get(r, "signed"), get(r, "chain"))
      jobj([("until", jnum(until))])
    }
    "rig.revoke" => {
      self.grants.revoke(get(r, "signed"), get(r, "chain"))
      jobj([("ok", jbool(true))])
    }
    "rig.release" => {
      let request = match get(r, "request") {
        None | Some(Null) => ""
        v => js_string_of(v)
      }
      jobj([("released", jbool(self.grants.release(peer, request)))])
    }
    "rig.settings" => {
      self.grants.take_settings(get(r, "signed"), get(r, "chain"))
      jobj([("ok", jbool(true))])
    }
    "rig.device" => {
      self.grants.device(get(r, "signed"), get(r, "chain"))
      jobj([("ok", jbool(true))])
    }
    "rig.added" => {
      let lock = self.grants.added(get(r, "signed"), pin=get(r, "pin"), chain=get(r, "chain"))
      self.pin_named(lock)
      jobj([("ok", jbool(true))])
    }
    "rig.full" => {
      // Its person signed it whole again: kept until the control plane lists it as a station (cloud/presence.ts), which
      // alone makes it one. A station's again: the control plane's word, as a station's enrollment is.
      let s = self.grants.full(get(r, "signed"), get(r, "chain"))
      let at = get(get(Some(s), "body"), "at").unwrap_or(Json::null())
      self.d.cloud.update(st => st.fields["full_pending"] = jobj([("at", at)]))
      jobj([("ok", jbool(true))])
    }
    "rig.proof" => jobj([("add", self.grants.proof().unwrap_or(Json::null()))])
    "rig.log" => {
      let limit = match get(r, "limit") {
        Some(Number(n, ..)) if safe_int(n) => if n < 1.0 { 1.0 } else if n > log_max { log_max } else { n }
        _ => 50.0
      }
      let commands = self.commands.last(limit.to_int())
      jobj([("commands", jarr(commands))])
    }
    _ => raise Refused("unknown method \{meth}")
  }
}

///|
/// The stations of the workspace now.
fn Rig::stations(self : Rig) -> Array[String] {
  guard self.self_() is Some(me) else { return [] }
  let peers = arr_at(self.d.cloud.membership(me.workspace), "peers").unwrap_or([])
  let out = []
  for p in peers {
    if str_at(Some(p), "id") is Some(id) && id != me.id {
      out.push(id)
    }
  }
  out
}

///|
/// Every station told how this rig is now. `hello`: as it comes on the mesh; `fresh`: only those new to the roster.
fn Rig::tell_all(self : Rig, hello? : Bool = false, fresh? : Bool = false) -> Unit {
  let stations = self.stations()
  for station in self.untold.keys().collect() {
    if !stations.contains(station) {
      if self.untold.get(station) is Some(w) {
        (w.stop)()
      }
      self.untold.remove(station)
    }
  }
  for station in stations {
    if !fresh || !self.known.contains(station) {
      self.tell(station, None, hello~)
    }
  }
  self.known = stations
}

///|
/// One station told how this rig is now (and what ended, when a grant of its own did); told again later when it was
/// not reached.
fn Rig::tell(self : Rig, station : String, ended : Json?, hello? : Bool = false) -> Unit {
  guard self.self_() is Some(me) && self.stations().contains(station) else { return }
  if self.untold.get(station) is Some(w) {
    (w.stop)()
  }
  self.untold.remove(station)
  let fields = [("method", jstr(if hello { "rig.hello" } else { "rig.changed" })), ("workspace", jstr(me.workspace))]
  let request = Ref(
    spread(Some(spread(Some(jobj(fields)), Some(self.described()))), ended.map(e => jobj([("ended", e)]))),
  )
  fn attempt(wait : Double, until : Double) -> Unit {
    (self.d.spawn)(async fn() {
      let failed = try {
        let _ = (self.d.ask)(station, request.val)
        false
      } catch {
        // Refused: it heard (a station from before rigs, or one that takes this rig for none yet): nothing to try again.
        Refused(_) => return
        _ => true
      }
      if !failed || (self.d.clock.now)() >= until {
        return
      }
      let next = if wait * 2.0 < again_max_ms { wait * 2.0 } else { again_max_ms }
      self.next_untold += 1
      let entry : Untold = { id: self.next_untold, wait: next, stop: () => () }
      // A retry after a failure, with a backoff: the station was not reached.
      entry.stop = (self.d.clock.after)(wait, () => {
        guard self.untold.get(station) is Some(e) && e.id == entry.id else { return }
        self.untold.remove(station)
        // What it is told is how the rig is by then; what ended for it goes along still.
        request.val = spread(Some(request.val), Some(self.described()))
        attempt(entry.wait, until)
      })
      self.untold[station] = entry
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
