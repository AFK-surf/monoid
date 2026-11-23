// A rig's process (rig/main.ts; a station that only runs tasks, 2026-11-10): the composition root of a machine that
// joined its workspace as a rig (`enroll --rig`, cloud.json's `rig`), in the place of the station's. The same release,
// launcher and updates; of a station's parts only those that are asked by another station: the mesh's station
// transport (no members' links, no gateway's tools), the jobs, the tasks other stations send (jobs/remote.ts), a
// command run with a secret a station sends along (vault/incoming.ts), and the rig's own say over who may use it
// (rig.mbt). No agents, sessions, chats, connects, accounts, vault or drive are made here: there is nothing in this
// process that could run one.
//
// The parts it is made of (the jobs, the tasks, the updates, the door its jobs reach it by, the launcher's control)
// are the station's; what is the rig's own here is how they are put together: whose a task's job is, what follows the
// machine coming in and out of its workspace, the disk looked at as it fills, the door's port, the drain, the order
// things are let go in, and what the mesh asks of the rig.

///|
/// `remote:<workspace>:<station>:<session>`: whose a task's job is (jobs/remote.ts `owner`). A session's key has colons
/// of its own; a workspace's id and a station's have none.
pub fn owner_of(workspace : String, station : String, session : String) -> String {
  "remote:\{workspace}:\{station}:\{session}"
}

///|
/// What `owner_of` made, read back (`/^remote:([^:]*):([^:]*):(.*)$/s`).
pub fn owned(key : String) -> (String, String, String)? {
  guard key.has_prefix("remote:") else { return None }
  let rest = key.unsafe_substring(start=7, end=key.length())
  guard rest.find(":") is Some(a) else { return None }
  let workspace = rest.unsafe_substring(start=0, end=a)
  let after = rest.unsafe_substring(start=a + 1, end=rest.length())
  guard after.find(":") is Some(b) else { return None }
  Some((workspace, after.unsafe_substring(start=0, end=b), after.unsafe_substring(start=b + 1, end=after.length())))
}

///|
pub let disk_low_bytes : Double = 21474836480.0

///|
pub let disk_soft_bytes : Double = 32212254720.0

///|
pub let disk_every_ms : Double = 300000.0

///|
pub let disk_soft_every_ms : Double = 30000.0

///|
/// The soft mark of a disk of `total` bytes (ops/disk.ts `diskSoft`).
pub fn disk_soft(total : Double) -> Double {
  if disk_soft_bytes > total / 10.0 {
    disk_soft_bytes
  } else {
    total / 10.0
  }
}

///|
/// The low mark of a disk of `total` bytes (ops/disk.ts `diskLow`): a tenth of it where that is less.
pub fn disk_low(total : Double) -> Double {
  if total / 10.0 < disk_low_bytes {
    total / 10.0
  } else {
    disk_low_bytes
  }
}

///|
/// Where a disk with `free` of `total` bytes free stands (ops/disk.ts `diskTier`): "ok", "soft" or "low".
pub fn disk_tier(free : Double, total : Double) -> String {
  if free < disk_low(total) {
    "low"
  } else if free < disk_soft(total) {
    "soft"
  } else {
    "ok"
  }
}

///|
/// How long until the disk is looked at again, as it stands (ops/disk.ts `diskEvery`).
pub fn disk_every(tier : String) -> Double {
  if tier == "ok" {
    disk_every_ms
  } else {
    disk_soft_every_ms
  }
}

///|
/// The ports to try, in order, for a listener of the station's own (ops/files.ts `portsToTry`).
pub fn ports_to_try(named : Int?, remembered : Int?, usual : Int, own : Bool) -> Array[Int] {
  if named is Some(n) {
    return [n]
  }
  let out = []
  for p in [remembered, if own { Some(usual) } else { None }, Some(0)] {
    if p is Some(x) && !out.contains(x) {
      out.push(x)
    }
  }
  out
}

///|
/// What a rig's jobs are to it (jobs/jobs.ts and the store's jobs): which run for a chat, stopping them, and taking
/// them up again or stopping them all as the machine comes in or out of its workspace.
pub(all) struct RigJobs {
  running_at_least : (String, Int) -> Bool
  up_job_ids : (String) -> Array[String]
  /// The session keys of the jobs running now.
  running : () -> Array[String]
  stop : async (String) -> Unit
  relaunch : () -> Unit
  stop_all : async (String) -> Unit
}

///|
/// What `Rig` is given of its jobs (rig/main.ts's `busy`, `stop`, `running`).
pub fn rig_jobs_deps(
  jobs : RigJobs,
  spawn : (async () -> Unit) -> Unit,
) -> ((String, String, String) -> Bool, (String, String, String) -> Unit, () -> Array[(String, String, String)]) {
  let busy = (workspace : String, station : String, session : String) => (jobs.running_at_least)(
    owner_of(workspace, station, session),
    1,
  )
  let stop = (workspace : String, station : String, session : String) => spawn(async fn() {
    for id in (jobs.up_job_ids)(owner_of(workspace, station, session)) {
      // (a task of a chat that lost this rig not stopped is said in the log, the others still stopped)
      (jobs.stop)(id) catch {
        _ => ()
      }
    }
  })
  let running = () => {
    let out = []
    for k in (jobs.running)() {
      if owned(k) is Some(o) {
        out.push(o)
      }
    }
    out
  }
  (busy, stop, running)
}

///|
/// What follows from the machine's cloud.json as it changes (rig/main.ts `follow`).
pub(all) enum Follow {
  /// No longer a rig (enrolled again as a station, from another process): this process ends, and the launcher starts
  /// the station's in its place.
  BecomeOther
  /// Back in its workspace: its jobs taken up again.
  Relaunch
  /// Out of it: what it runs for the stations stops, why.
  StopAll(String)
  Stay
} derive(Eq, Show)

///|
/// In its workspace or out of it, as cloud.json says.
pub struct RigFollow {
  priv cloud : @cloud_lock.Cloud
  priv mut in_workspace : Bool
  priv mut giving : Bool
}

///|
pub fn RigFollow::new(cloud : @cloud_lock.Cloud) -> RigFollow {
  { cloud, in_workspace: cloud.rig_memberships().length() > 0, giving: false }
}

///|
pub fn RigFollow::in_workspace(self : RigFollow) -> Bool {
  self.in_workspace
}

///|
/// What to do now the control plane changed something.
pub fn RigFollow::step(self : RigFollow) -> Follow {
  if self.cloud.full_memberships().length() > 0 && !self.cloud.removed() {
    if !self.giving {
      self.giving = true
      return BecomeOther
    }
    return Stay
  }
  let now = self.cloud.rig_memberships().length() > 0
  if now == self.in_workspace {
    return Stay
  }
  self.in_workspace = now
  if now {
    Relaunch
  } else {
    StopAll(
      if self.cloud.removed() {
        "the rig was removed from its workspace"
      } else {
        "the rig is in no workspace"
      },
    )
  }
}

///|
/// The rest of what the rig's process is made of (rig/main.ts's other parts), each the station's own.
pub(all) struct RigMainParts {
  jobs : RigJobs
  /// The disk holding the data: bytes free and in all (ops/storage.ts `diskOf`).
  disk_of : async () -> (Double, Double)
  /// What is made again when asked for let go (ops/storage.ts `Upkeep.renewables`), then other stations' mirrors unused
  /// the longest down to the soft mark (jobs/remote.ts `relieve`).
  renewables : async (Double) -> Unit
  relieve : async (Double, Double) -> Unit
  become_other : () -> Unit
  /// The door its jobs reach it by (tools/http.ts `openAgentsDoor`): on the launcher's socket (`fd`), a port the launcher
  /// names, or one of its own; raises `Thrown("EADDRINUSE", …)` where the port is taken. Its port and its URL.
  open_door : async (Json) -> (Int, String)
  /// jobs/jobs.ts `setNotifyUrl`.
  set_notify_url : (String) -> Unit
  /// The launcher's control (ops/launcher.ts `Control`): its socket for the door, the ports it named, and what it is told.
  mcp_fd : Int?
  shown_port : Int?
  serving : (String, Int) -> Unit
  drained : (String) -> Unit
  failed : (String) -> Unit
  /// Whether this machine's data directory is its own one (ops/files.ts `ownData`), and the MCP port it remembers.
  own_data : Bool
  remembered_port : Int?
  files : Files
  data : String
  clock : Clock
  spawn : (async () -> Unit) -> Unit
}

///|
pub struct RigMain {
  priv p : RigMainParts
  priv follow : RigFollow
  priv mut relieve_off : (() -> Unit)?
  priv mut door_port : Int?
}

///|
pub fn RigMain::new(p : RigMainParts, cloud : @cloud_lock.Cloud) -> RigMain {
  { p, follow: RigFollow::new(cloud), relieve_off: None, door_port: None }
}

///|
/// The control plane changed something: followed (the machine's process given way, its jobs taken up or stopped).
pub async fn RigMain::changed(self : RigMain) -> Unit {
  match self.follow.step() {
    BecomeOther => (self.p.become_other)()
    Relaunch => (self.p.jobs.relaunch)()
    StopAll(why) => (self.p.jobs.stop_all)(why)
    Stay => ()
  }
}

///|
/// Room made as its disk fills: what is made again when asked for, then other stations' mirrors unused the longest
/// (jobs/remote.ts): looked at every DISK_EVERY_MS, more often while under its soft mark.
pub fn RigMain::start_relieving(self : RigMain) -> Unit {
  // timer: a sample of this machine (its disk)
  self.relieve_off = Some((self.p.clock.after)(disk_every_ms, () => (self.p.spawn)(() => self.relieving())))
}

///|
async fn RigMain::relieving(self : RigMain) -> Unit {
  let tier = try {
    let (free, total) = (self.p.disk_of)()
    let tier = disk_tier(free, total)
    if tier != "ok" {
      (self.p.renewables)((self.p.clock.now)())
      (self.p.relieve)((self.p.clock.now)(), disk_soft(total))
    }
    tier
  } catch {
    // (making room on the disk failed: said in the log, looked at again as it stood)
    _ => "ok"
  }
  // timer: a sample of this machine (its disk)
  self.relieve_off = Some((self.p.clock.after)(disk_every(tier), () => (self.p.spawn)(() => self.relieving())))
}

///|
/// The door its jobs reach it by opened (`stillfail-job notify`, `screen`): this machine's own, with no tool behind it;
/// then its jobs taken up, or stopped where it was removed. Up and the station before gone are its caller's to wait for.
pub async fn RigMain::start(self : RigMain, cloud : @cloud_lock.Cloud) -> Unit {
  try {
    (self.p.files.mkdir)(self.p.data + "/run")
    let (port, url) = match (self.p.mcp_fd, self.p.shown_port) {
      (Some(fd), _) => (self.p.open_door)(jobj([("fd", jnum(fd.to_double()))]))
      (None, Some(shown)) => (self.p.open_door)(jobj([("port", jnum(0.0)), ("shown", jnum(shown.to_double()))]))
      (None, None) => {
        let tries = ports_to_try(None, self.p.remembered_port, 4750, self.p.own_data)
        let mut opened : (Int, String)? = None
        for i, port in tries {
          let got = try {
            Some((self.p.open_door)(jobj([("port", jnum(port.to_double()))])))
          } catch {
            Thrown("EADDRINUSE", _) if i < tries.length() - 1 => None
            e => raise e
          }
          if got is Some(g) {
            opened = Some(g)
            break
          }
        }
        let g = opened.unwrap()
        (self.p.files.write)(mcp_port_file(self.p.data), "{\"port\":\{g.0}}\n")
        g
      }
    }
    self.door_port = Some(port)
    (self.p.set_notify_url)(
      if url.has_suffix("/mcp") {
        url.unsafe_substring(start=0, end=url.length() - 4) + "/jobs/notify"
      } else {
        url
      },
    )
    (self.p.serving)("mcp", port)
    if self.follow.in_workspace() {
      (self.p.jobs.relaunch)()
    } else if cloud.removed() {
      (self.p.jobs.stop_all)("the rig was removed from its workspace")
    }
  } catch {
    e => (self.p.failed)("the rig did not start: \{error_message(e)}")
  }
}

///|
/// Where the MCP endpoint's port is remembered (ops/files.ts `mcpPortFile`).
pub fn mcp_port_file(data : String) -> String {
  data + "/run/mcp.json"
}

///|
/// The port the door its jobs reach it by was opened on, once it is.
pub fn RigMain::door_port(self : RigMain) -> Int? {
  self.door_port
}

///|
/// Nothing here to hand over turn by turn: drained at once.
pub fn RigMain::drain(self : RigMain) -> Unit {
  (self.p.files.write)(self.p.data + "/run/drained", "idle\n") catch {
    _ => ()
  }
  (self.p.drained)("idle")
}

///|
/// Its timers called off (what else it is made of is let go by their own, in the order rig/main.ts says: the door,
/// the memory's watch, the upkeep, the rig, the tasks, the jobs, the updates).
pub fn RigMain::close(self : RigMain) -> Unit {
  if self.relieve_off is Some(off) {
    off()
  }
}

///|
/// What the mesh asks of the rig (rig/main.ts `RigMeshLive`): whether a station may reach its services, refused while
/// it is starting.
pub fn mesh_allowed(rig : Rig?, peer : String, workspace : String) -> String? {
  match rig {
    Some(r) => r.station_refusal(peer, workspace)
    None => Some("the rig is starting")
  }
}

///|
/// A connection to one of its devices, refused while it is starting.
pub async fn mesh_device(
  rig : Rig?,
  peer : String,
  workspace : String,
  session : String,
  device : String,
  probe : Bool,
) -> Socket? {
  match rig {
    Some(r) => r.device(peer, workspace, session, device, probe)
    None => raise DeviceRefused(503, "the rig is starting")
  }
}
