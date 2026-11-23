// P5-1's control plane (services.ts ControlPlane, cloud/plane.ts, cloud/state.ts, cloud/presence.ts): cloud.json as
// cloud_lock keeps it (its locks pinned, written whole) and the plane's view of it (cloud_net's `StateCloud`, the same
// map), the presence socket kept while the station answers (its backoff, heartbeat, the plane's frames applied and
// written to cloud.json), run/presence.json, what the plane tells besides (`release`, `models`), notices, traces and
// the log posted signed, the workspaces' ways and the station's marks; and a station that became a rig giving way to
// the rig's process (main.ts BecameRig).

///|
priv struct Plane {
  cloud : @cloud_lock.Cloud
  crypto : @cloud_lock.Crypto
  state : @cloud_net.StateCloud
  plane : @cloud_net.PlaneCloud
  control : @cloud_net.ControlPlane
  ways : @cloud_net.Ways
  marks : @cloud_net.StationMarks
  up : @cloud_net.Up
  transport : @cloud_net.CloudTransport
  http : @cloud_net.Http
  /// What the presence socket asks the mesh's device tools (Comma's), once the mesh is up.
  tool_calls : Ref[((Json, (Result[Json, String]) -> Unit) -> Unit)?]
  /// Clear a workspace's rig grants/devices when that workspace changes mode.
  clear_rig_ws : Ref[(String) -> Unit]
  listeners : Array[(Int, (Json?) -> Unit)]
  mut next : Int
  mut reached_said : Bool
  /// The data directory (the rig's grants in it).
  data : String
}

///|
fn Plane::tell(self : Plane) -> Unit {
  let now = match self.cloud.state {
    Some(s) => Some(s.to_json())
    None => None
  }
  for l in self.listeners.copy() {
    (l.1)(now)
  }
}

///|
/// The reach of the plane as the station says it (health.json's `presenceOnline`), told as it changes.
fn Plane::reach_changed(self : Plane) -> Unit {
  if self.plane.reached != self.reached_said {
    self.reached_said = self.plane.reached
    self.tell()
  }
}

///|
/// What presence asks of the locks the plane carries: cloud_lock's (state.ts), by workspace (None: the home one).
fn lock_hooks(cloud : @cloud_lock.Cloud, crypto : @cloud_lock.Crypto, station : () -> String) -> @cloud_net.LockHooks {
  let home_of = (ws : String?) => match ws {
    Some(w) => Some(w)
    None => cloud.home()
  }
  {
    pinned: ws => cloud.chain(ws~) is Some(_),
    seq: ws => match cloud.chain(ws~) {
      Some({ state: Some(s), .. }) => Some(s.seq.to_int())
      _ => None
    },
    genesis: ws => match cloud.chain(ws~) {
      Some({ state: Some(s), .. }) => Some(s.genesis)
      _ => None
    },
    pending: ws => match ws {
      Some(w) => cloud.pending_lock(w)
      None =>
        match cloud.disk().read(@cloud_lock.pending_lock_path(cloud.data)).bind(@cloud_lock.parse) {
          Some({ "hash": String(h), .. }) if @cloud_lock.is_hex32(h) => Some(h)
          _ => None
        }
    },
    left_out: ws => cloud.left_out(ws),
    after: (seq, ws) => cloud.lock_after(seq.to_double(), ws~),
    kept: ws => cloud.lock_kept(ws~),
    hash_of: e => @cloud_lock.hash_of(e),
    as_entry: e => @cloud_lock.as_entry(e),
    names_station: entries => match (try { Ok(@cloud_lock.fold(crypto, entries, None)) } catch { e => Err(e) }) {
      Ok(s) => s.stations.contains(station())
      Err(_) => false
    },
    take: (entries, ws) => ignore(cloud.take_lock(entries, ws~)),
    offer_moved: (ws, entries) => cloud.offer_moved(ws, entries),
    pending_taken: ws => match home_of(ws) {
      Some(w) if ws is Some(_) => cloud.disk().remove(@cloud_lock.joined_pending_path(cloud.data, w))
      _ => cloud.disk().remove(@cloud_lock.pending_lock_path(cloud.data))
    },
    succeed: (ws, demote) => cloud.succeed(ws, demote_old_home=demote),
    filtered: (peers, gateways) => {
      cloud.set_plane_lists(
        peers,
        match gateways {
          Some(g) => Some(Json::array(g.map(x => Json::string(x))))
          None => None
        },
      )
      match cloud.state {
        Some(st) => {
          let (p, g) = cloud.filtered(st)
          (
            p,
            match g {
              Some(Array(items)) => Some(items.filter_map(x => match x { String(s) => Some(s); _ => None }))
              _ => None
            },
          )
        }
        None => (peers, gateways)
      }
    },
    locked: () => {
      let home = cloud.home()
      cloud
      .memberships()
      .iter()
      .any(m => {
        let w = match m {
          { "workspace": String(s), .. } => s
          _ => ""
        }
        if w == "" {
          false
        } else {
          cloud.locked(ws=if Some(w) == home { None } else { Some(w) }) is Some(_)
        }
      })
    },
  }
}

///|
/// services.ts ControlPlane and main.ts's presence: made once, kept while the station runs.
fn P51::plane_live(self : P51) -> Plane {
  let bus = self.bus
  let host = self.host
  let crypto = @cloud_lock.Crypto::of_host(host)
  let cloud = @cloud_lock.Cloud::new(host, bus.data, crypto, () => wall_ms().to_double()) catch {
    e => {
      p51_log("ERROR", "cloud", "cloud.json not read", fields={ "error": Json::string("\{e}") })
      @cloud_lock.Cloud::new(host, bus.data, crypto, () => wall_ms().to_double()) catch {
        _ => panic()
      }
    }
  }
  let state_json_of = () => match cloud.state {
    Some(s) => Some(Json::object(s.fields))
    None => None
  }
  // One map: what the plane's frames change of the state is cloud_lock's, written by it.
  let state = @cloud_net.StateCloud::new(state_json_of())
  let station = () => match cloud.state {
    Some(s) => s.text("station")
    None => ""
  }
  let tool_calls : Ref[((Json, (Result[Json, String]) -> Unit) -> Unit)?] = Ref(None)
  let plane = @cloud_net.PlaneCloud::new(
    state,
    () => wall_ms() / 1000L,
    lock=lock_hooks(cloud, crypto, station),
    reload=() => cloud.reload(),
    rig_grants_gone=() => cloud.disk().remove(@cloud_lock.rig_grants_path(bus.data)),
    tool_calls=(request, k) => match tool_calls.val {
      Some(run) => run(request, k)
      None => k(Err("this station takes no device tools now"))
    },
    log=m => p51_log("INFO", "presence", m),
  )
  let entry = () => @cloud_net.cloud_entry((bus.config_raw.val)())
  let transport = @cloud_net.CloudTransport::new(entry, @cloud_net.host_dial_io(host))
  let http = @cloud_net.host_http(host)
  let sign = (m : String) => bus.key.sign(m) catch { _ => "" }
  let control = @cloud_net.ControlPlane::new(
    state.view(),
    () => @cloud_net.provider_of(state_json_of().bind(s => match s { Object(m) => m.get("provider"); _ => None })),
    sign,
    () => wall_ms() / 1000L,
    transport,
    http,
    trace_resource=[
      ("service.version", bus.version),
      ("os.type", platform()),
      ("host.arch", arch()),
      ("process.runtime.name", "moonbit"),
    ],
  )
  let ways = @cloud_net.Ways::new(
    state.view(),
    @cloud_net.host_kept(host, path([bus.data, "mesh", "ways.json"])),
    () => wall_ms(),
  )
  let marks = @cloud_net.StationMarks::new(
    state.view(),
    @cloud_net.host_kept(host, path([bus.data, "mesh", "station-marks.json"])),
    () => wall_ms(),
  )
  let up = @cloud_net.Up::new(true)
  let p : Plane = {
    cloud,
    crypto,
    state,
    plane,
    control,
    ways,
    marks,
    up,
    transport,
    http,
    tool_calls,
    clear_rig_ws: Ref(_ => ()),
    listeners: [],
    next: 0,
    reached_said: false,
    data: bus.data,
  }
  // What the plane's frames change, written to cloud.json (state.ts `update`) and told; cloud.json read anew (by this
  // process or as another wrote it) is the plane's state from then on.
  let writing = Ref(false)
  ignore(
    state.told.add(() => {
      if writing.val {
        return
      }
      writing.val = true
      cloud.update(_ => ())
      writing.val = false
      // (what the frame changed told on the bus as cloud.json's listeners are told of it: state.ts `update`; the
      // station that became a rig, the agents following their workspaces, the event streams' overview)
      p.reached_said = p.plane.reached
      p.tell()
    }),
  )
  ignore(
    cloud.listen(_ => {
      state.reset(state_json_of())
      self.station_id = match cloud.state {
        Some(s) if s.text("station") != "" => Some(s.text("station"))
        _ => None
      }
      if !writing.val {
        p.tell()
      }
    }),
  )
  // (a person's log taken changes the lock a workspace's vault goes by out of security mode, made of them: told as
  // cloud.json's changes are, so the vault's lock and its waiting requests are read again: state.ts `vaultLock`)
  ignore(
    cloud.person_chains().listen(_ => {
      if !writing.val {
        p.tell()
      }
    }),
  )
  // cloud.json written by another process (an enroll, a lock reset): read again as it changes.
  let stamp = Ref(file_stamp(self.fs, path([bus.data, "mesh", "cloud.json"])))
  self.every("cloud.json", 1000, async fn() { // timer: an outside system that offers no push (a file another process writes)
    let now = file_stamp(self.fs, path([bus.data, "mesh", "cloud.json"]))
    if now != stamp.val {
      stamp.val = now
      cloud.reload()
      cloud.reload_lock()
      cloud.reload_joined()
    }
  })
  // The bus's.
  bus.cloud_state.val = () => state_json_of()
  bus.cloud_reached.val = () => plane.reached
  bus.cloud_listen.val = f => {
    p.next += 1
    let id = p.next
    p.listeners.push((id, f))
    () => ignore(p.listeners.search_by(x => x.0 == id).map(i => p.listeners.remove(i)))
  }
  bus.cloud_call.val = async fn(op, arg) { p.call(op, arg) }
  // What the presence socket says of a release and the model catalog (rig/main.ts, sessions/agents.ts,
  // feedback/module.ts `plane.told("release", …)`; models/module.ts `plane.told("models", …)`).
  control.told("release", _ => bus.told_release())
  control.told("models", ev => ignore(
    host.rt.fork_quiet(name="models refresh", async fn() {
      let etag = match ev {
        @cloud_net.Models(Some(e)) => Json::string(e)
        _ => Json::null()
      }
      bus.jobs_models_refresh(etag) catch {
        e => p51_log("WARN", "models", "the model catalog not read", fields={ "error": Json::string("\{e}") })
      }
    }),
  ))
  // (the presence socket is the mesh's, once a relay reaches the station: live_p5_1_mesh.mbt)
  self.stops.push(() => {
    up.set(false)
    transport.close()
  })
  // The roster's grace after a socket ended (`lapse`): told as it lapses.
  self.every("presence reach", 1000, async fn() { p.reach_changed() }) // timer: a debounce of a burst (the roster's grace, told once it lapses)
  p
}

///|
/// A file's size, time and inode, or "none".
fn file_stamp(fs : @ops_platform.Fs, file : String) -> String {
  match (try { Ok(fs.meta(file)) } catch { e => Err(e) }) {
    Ok(Some((size, mtime, _))) => "\{size}:\{mtime}"
    _ => "none"
  }
}

///|
/// What another slice asks of the control plane (the bus's `cloud_call`), by name.
async fn Plane::call(self : Plane, op : String, arg : Json) -> Json {
  let text = (k : String) => match arg {
    Object(m) =>
      opt_str(m.get(k))
    _ => None
  }
  match op {
    "notify" => {
      let notices = match arg {
        { "notices": Array(n), .. } => n
        _ => []
      }
      match text("workspace") {
        Some(ws) => self.control.notify(notices, workspace=ws)
        None => self.control.notify(notices)
      }
      Json::null()
    }
    "traces" => {
      self.control.traces(
        match arg {
          { "spans": Array(s), .. } => s
          _ => []
        },
      )
      Json::null()
    }
    "logs" => {
      self.control.logs(text("body").unwrap_or(""))
      Json::null()
    }
    "releaseBase" =>
      jopt(self.control.release_base())
    "credential" => {
      let c = self.control.credential()
      {
        "issuers": Json::array(c.issuers.map(x => Json::string(x))),
        "types": Json::array(c.types.map(x => Json::string(x))),
      }
    }
    "spec" => {
      let s = self.control.spec()
      { "provider": Json::string(s.provider.name()), "name": Json::string(s.name), "feedback": Json::boolean(s.feedback) }
    }
    "memberships" => Json::array(self.cloud.memberships())
    "membership" => self.cloud.membership(text("workspace").unwrap_or("")).unwrap_or(Json::null())
    "home" =>
      jopt(self.cloud.home())
    "removed" => Json::boolean(self.cloud.removed())
    "reload" => {
      self.cloud.reload(tell=true)
      Json::null()
    }
    "rigs" => Json::array(self.cloud.rigs(text("workspace").unwrap_or("")))
    "relays" => Json::array(self.ways.relays().map(x => Json::string(x)))
    "ways" => self.ways.view(text("workspace").unwrap_or("")).to_json()
    "marks" => @cloud_net.marks_json(self.marks.of(text("workspace").unwrap_or("")))
    // (agents.ts's hub `stationName`: its mark's name, else its name in this station's workspaces, else none)
    "stationName" => {
      let id = text("id").unwrap_or("")
      match self.marks.record(id) {
        Some(r) => Json::string(r.name)
        None => {
          let mut named = Json::null()
          for m in self.cloud.memberships() {
            for p in jitems(jfield(m, "peers")) {
              if jtext(p, "id") == Some(id) && named is Null {
                match jtext(p, "name") {
                  Some(n) if n != "" && n != id => named = Json::string(n)
                  _ => ()
                }
              }
            }
          }
          named
        }
      }
    }
    // (agents.ts: whole to tasks once the agents ended, as `rig_due` said: the rig's owner kept, what was pending of it
    // and the rigs it listed dropped, the grants of before it removed; this process then gives way to the rig's)
    // (agents.ts `follow`: due to be a rig with nothing its owner asked, `rig_due` let go)
    "dropRigDue" => {
      let ws = text("ws").unwrap_or("")
      self.state.update(st => {
        if ws == "" {
          st.remove("rig_due")
        } else if st.get("rig_due") is Some(Array(xs)) {
          let rest = xs.filter(x => x != Json::string(ws))
          if rest.length() > 0 {
            st["rig_due"] = Json::array(rest)
          } else {
            st.remove("rig_due")
          }
        } else {
          st.remove("rig_due")
        }
      })
      Json::null()
    }
    "becomeRig" => {
      let ws = text("ws").unwrap_or(self.cloud.home().unwrap_or(""))
      let due = match arg {
        Object(m) if m.get("due") is Some(d) => d
        other => other
      }
      let rig_obj : Json = {
        "owner": jfield(due, "owner"),
        "owner_email": jfield(due, "owner_email"),
        "owner_name": jfield(due, "owner_name"),
        "person": jfield(due, "person"),
      }
      self.state.update(st => {
        let home_ws = match st.get("workspace") {
          Some(String(w)) => w
          _ => ""
        }
        if ws == "" || ws == home_ws {
          st["rig"] = rig_obj
        } else if st.get("joined") is Some(Array(xs)) {
          let updated : Array[Json] = []
          for j in xs {
            match j {
              Object(jm) if jm.get("workspace") == Some(Json::string(ws)) => {
                let copy = jm.copy()
                copy["rig"] = rig_obj
                updated.push(Json::object(copy))
              }
              other => updated.push(other)
            }
          }
          st["joined"] = Json::array(updated)
        }
        if st.get("rig_pending") is Some(Object(rp)) {
          let copy = rp.copy()
          copy.remove(ws)
          if copy.is_empty() {
            st.remove("rig_pending")
          } else {
            st["rig_pending"] = Json::object(copy)
          }
        } else {
          st.remove("rig_pending")
        }
        if st.get("rig_due") is Some(Array(xs)) {
          let rest = xs.filter(x => x != Json::string(ws))
          if rest.length() > 0 {
            st["rig_due"] = Json::array(rest)
          } else {
            st.remove("rig_due")
          }
        } else {
          st.remove("rig_due")
        }
        // Only drop `rigs` list if no full workspaces remain.
        let home_is_rig = st.get("rig") is Some(Object(_))
        let all_joined_rig = match st.get("joined") {
          Some(Array(xs)) => xs.iter().all(j => j is { "rig": Object(_), .. })
          _ => true
        }
        if home_is_rig && all_joined_rig {
          st.remove("rigs")
        }
      })
      if ws != "" {
        (self.clear_rig_ws.val)(ws)
      }
      if self.cloud.is_rig_only() {
        self.cloud.disk().remove(@cloud_lock.rig_grants_path(self.data))
      }
      Json::null()
    }
    // (the relays tool's: still.fail's own relays; a workspace's own added or taken away, mesh/ways.ts)
    "stillFails" => Json::array(@cloud_net.still_fails(self.state.view()).map(Json::string(_)))
    "addRelay" =>
      @cloud_net.add_relay(self.ways, text("workspace").unwrap_or(""), text("url").unwrap_or(""), text("by")).to_json() catch {
        @cloud_net.WaysRefusal(m) => raise @api_routes.Thrown("WaysRefusal", to_jv({ "message": Json::string(m) }))
      }
    "removeRelay" =>
      @cloud_net.remove_relay(self.ways, text("workspace").unwrap_or(""), text("url").unwrap_or("")).to_json() catch {
        @cloud_net.WaysRefusal(m) => raise @api_routes.Thrown("WaysRefusal", to_jv({ "message": Json::string(m) }))
      }
    // (the relays tool's mesh asks before the mesh's directory answers them, or while no mesh runs: answered as
    // agents.ts answers them with no directory, none listed and nothing enrolled or revoked; live_p5_1_scopes.mbt
    // answers them once the mesh is up)
    "meshList" => Json::array([])
    "meshRevoke" | "meshEnroll" => Json::null()
    // (cloud/signed.ts `signedPost`: the feedback's reports, their fixes and replies)
    "signedPost" =>
      match self.control.signed(text("path").unwrap_or(""), text("tag").unwrap_or(""), match arg { Object(m) => m.get("value").unwrap_or(Json::null()); _ => Json::null() }) {
        Some(v) => v
        None => Json::null()
      }
    "peersCurrent" => Json::boolean(self.state.peers_current)
    // A lock as kept here (`Cloud.locked` and `Cloud.chain`), its state whole; `workspace` null: the home one's.
    "locked" => locked_json(self.cloud.locked(ws=text("workspace")))
    "chain" => locked_json(self.cloud.chain(ws=text("workspace")))
    // The person logs kept here, each `[genesis, chain]` (state.ts `personChainsOf(cloud).every()`): what a vault's
    // lock is made of where its workspace is not in security mode (live_p5_4_vault.mbt `p54_personal_lock`).
    "personChains" =>
      Json::array(self.cloud.person_chains().every().map(p => Json::array([Json::string(p.0), Json::array(p.1)])))
    "told" => Json::null()
    _ => raise BusError("no such control plane call: \{op}")
  }
}

///|
/// main.ts BecameRig: a station's process whose machine is a rig now gives way to the rig's (ops/restart.ts
/// `becomeOther`): its launcher asked to hand over, again until this process is gone; with none, it ends.
fn P51::became_rig_live(self : P51) -> Unit {
  let bus = self.bus
  let asked = Ref(false)
  let off = (bus.cloud_listen.val)(_ => {
    guard self.plane is Some(plane) && plane.cloud.is_rig_only() && !asked.val else { return }
    asked.val = true
    p51_log("WARN", "station", "this machine is a rig now: the station's process gives way to the rig's")
    self.fork("become a rig", async fn() { become_other(bus) })
  })
  self.stops.push(off)
}

///|
/// ops/restart.ts `becomeOther`: the launcher (run/station.json's, `handoff: 1`) asked to hand over, again every 5 s
/// while this process is still there; none to ask, the station stops.
async fn become_other(bus : LiveBus) -> Unit {
  while !bus.stopped.is_done() {
    let launcher = match read_json(path([bus.data, "run", "station.json"])) {
      Some({ "pid": Number(p, ..), "handoff": Number(1.0, ..), .. }) if p > 0.0 && pid_alive(p.to_int()) => Some(p.to_int())
      _ => None
    }
    match launcher {
      Some(pid) if !is_windows() => ignore(kill(pid, "SIGUSR2"))
      _ => {
        (bus.stop_station)("this machine is a rig now")
        return
      }
    }
    @effect.sleep(5000) // timer: a retry after a failure (a handover dropped), until this process is gone
  }
}

///|
/// A lock's state as JSON (the vault's and the gate's reading of it): its head, its devices, members, stations and
/// persons, where it moved.
fn lock_state_json(st : @lock.LockState, member_objects? : Bool = false) -> Json {
  let devices : Map[String, Json] = {}
  for id, d in st.devices {
    let m : Map[String, Json] = {
      "id": Json::string(id),
      "sub": Json::string(d.sub),
      "kind": Json::string(d.kind),
      "own": Json::boolean(d.own),
    }
    if d.by is Some(b) { m["by"] = Json::string(b) }
    if d.sign_key is Some(k) { m["sign_key"] = Json::string(k) }
    devices[id] = Json::object(m)
  }
  let sign_keys : Map[String, Json] = {}
  for id, ks in st.sign_keys {
    sign_keys[id] = Json::array(ks.map(Json::string(_)))
  }
  let members : Map[String, Json] = {}
  for sub, m in st.members {
    members[sub] = if member_objects {
      { "sub": Json::string(sub), "email": Json::string(m.email), "role": Json::string(m.role) }
    } else {
      Json::string(m.role)
    }
  }
  let persons : Map[String, Json] = {}
  for sub, g in st.persons {
    persons[sub] = Json::string(g)
  }
  let out : Map[String, Json] = {
    "ws": Json::string(st.ws),
    "seq": Json::number(st.seq),
    "head": Json::string(st.head),
    "genesis": Json::string(st.genesis),
    "devices": Json::object(devices),
    "signKeys": Json::object(sign_keys),
    "members": Json::object(members),
    "stations": Json::array(st.stations.keys().map(k => Json::string(k)).collect()),
    "persons": Json::object(persons),
    "moved": jopt(st.moved),
  }
  Json::object(out)
}

///|
fn locked_json(l : @cloud_lock.Locked?) -> Json {
  match l {
    None => Json::null()
    Some(x) =>
      {
        "state": match x.state {
          Some(s) => lock_state_json(s, member_objects=true)
          None => Json::null()
        },
        "waiting": Json::boolean(x.waiting),
      }
  }
}
