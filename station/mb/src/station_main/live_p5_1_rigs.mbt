// P5-1's rigs and the machine's mode (rigs/module.ts RigsLive, elevation/module.ts ElevationLive, rig/main.ts RigLive):
// on a whole station, the workspace's tasks-only stations as a part (`/rigs…`, `POST /mode`, `station_use`, the
// overview's `rigs`, what a rig tells: rigs_mode's `Rigs`) and, on Windows, running as the machine's administrator
// (`PUT /elevation`, the overview's `elevation`); on a machine that is a rig, the rig itself (its grants and what it
// tells the stations: rigs_mode's `Rig`; its door and its jobs followed as the control plane changes: `RigMain`).

///|
priv struct RigsLive {
  rigs : @rigs_mode.Rigs
}

///|
fn rigs_viewer(v : Json) -> @rigs_mode.Viewer {
  let t = (k : String) => match v {
    Object(m) =>
      match m.get(k) {
        Some(String(s)) => Some(s)
        _ => None
      }
    _ => None
  }
  { workspace: t("workspace").unwrap_or(""), sub: t("sub").unwrap_or(""), role: t("role").unwrap_or(""), email: t("email"), name: t("name") }
}

///|
/// A route's answer as a part says it (live_p5_1_admin.mbt: `{status, body}`).
fn part_answer(a : @rigs_mode.Answer) -> Json {
  { "status": Json::number(a.status.to_double()), "body": Json::string(a.body) }
}

///|
/// What another part says undefined as (the threads' store's `{"$undefined": true}`, the agents' side's
/// `{"$undef": 1}`), as rigs_mode says it (`{"$u": 1}`); anything else as it is.
fn rigs_answer(v : Json) -> Json {
  match v {
    Object(m) if m.length() == 1 && (m.contains("$undefined") || m.contains("$undef") || m.contains("$u")) =>
      @rigs_mode.undefined_json()
    v => v
  }
}

///|
/// An argument as the agents' side takes it: rigs_mode's undefined as its own (`{"$undef": 1}`).
fn rigs_arg(v : Json) -> Json {
  if @rigs_mode.is_undefined(v) {
    { "$undef": Json::number(1.0) }
  } else {
    v
  }
}

///|
/// What rigs_mode asks of the station (its `World`): the store's reads here, the rest the agents' side's and the devices'
/// (the bus's), a rig asked through the mesh (`remote.ask`). A function it gives (`{"$fn": id}`: a request's write, a
/// card made again from the one it was) is called here, where it was given: the other parts have none of its numbers.
fn P51::rigs_world(self : P51) -> @rigs_mode.World {
  let bus = self.bus
  let callbacks : Map[Int, async (Array[Json]) -> Json] = {}
  let next = Ref(0)
  let fn_of = (v : Json) => match v {
    { "$fn": Number(n, ..), .. } => callbacks.get(n.to_int())
    _ => None
  }
  // (the chats' store's cards as the devices' world writes them: what changed told on the bus)
  let threads : Ref[@store_threads.Store?] = Ref(None)
  let threads_of = () => match threads.val {
    Some(t) => {
      t.set_now(wall_ms().to_double())
      t
    }
    None => {
      let t = @store_threads.Store::new(bus.db, wall_ms().to_double())
      threads.val = Some(t)
      t
    }
  }
  let told = (t : @store_threads.Store) => {
    let sent = t.sent.copy()
    t.sent.clear()
    for c in sent {
      bus.notify_store(c)
    }
    // (what it found not prepared yet, asked of the builders: agents.ts `requestSessionChat`, `followLatestThreadRequests`)
    bus.drain_thread_requests(t)
  }
  {
    call: async fn(name, args) {
      let arg = (i : Int) => args.get(i).unwrap_or(Json::null())
      match name {
        // (requests.ts `#saveAndRestate`: the request written, then its outcome queued for the agents' side's worker
        // (card-outbox-worker.ts), which closes the card and restates its `rig.outcome`)
        "cardOutcomes.save" => {
          match fn_of(arg(1)) {
            Some(f) => ignore(f([]))
            None => ()
          }
          bus.hub_card_outcomes_save(arg(0))
          @rigs_mode.undefined_json()
        }
        "store.withdrawCard" => {
          let t = threads_of()
          let got = t.withdraw_card(arg(0), arg(1), arg(2)) catch {
            e => {
              told(t)
              raise e
            }
          }
          told(t)
          rigs_answer(got)
        }
        "store.restateCard" => {
          let t = threads_of()
          let was = t.card_at(arg(1), arg(2))
          let made = match fn_of(arg(3)) {
            Some(f) => f([was])
            None => was
          }
          let got = t.restate_card(arg(0), arg(1), arg(2), _ => @drive.to_jv(made)) catch {
            e => {
              told(t)
              raise e
            }
          }
          told(t)
          rigs_answer(got)
        }
        "remote.ask" => {
          let station = match arg(0) {
            String(s) => s
            _ => ""
          }
          let request = arg(1)
          let ws = match request {
            { "workspace": String(w), .. } => Some(w)
            _ => None
          }
          let meth = match request {
            { "method": String(m), .. } => m
            _ => ""
          }
          let (answer, _) = bus.call_peer(station, ws, meth, request) catch {
            @gate.PeerRefused(m) => raise @rigs_mode.Refused(m)
            e => raise e
          }
          answer
        }
        "events.tell" => {
          (bus.events_tell.val)(
            match arg(0) {
              String(s) => s
              _ => ""
            },
            arg(1),
            match arg(2) {
              String(s) => s
              _ => ""
            },
            arg(3),
          )
          @rigs_mode.undefined_json()
        }
        "store.getSession" =>
          match bus.store.get_session(match arg(0) { String(s) => s; _ => "" }) {
            Null => @rigs_mode.undefined_json()
            s => s
          }
        "store.has" => Json::boolean(true)
        // (the forwards are this slice's: live_p5_1_forwards.mbt)
        "forwards.closeDevice" => {
          match self.forwards {
            Some(f) => {
              let t = (j : Json) => match j { String(s) => Some(s); _ => None }
              f.close_device(t(arg(0)), t(arg(1)), t(arg(2)).unwrap_or("closed"))
            }
            None => ()
          }
          @rigs_mode.undefined_json()
        }
        _ => {
          let ask = if name.has_prefix("sources.") || name.has_prefix("forwards.") { bus.ui_ask.val } else { bus.hub_ask.val }
          // (what another part threw, as rigs_mode takes a part's: its class's name and its message)
          let got = ask(name, Json::array(args.map(rigs_arg))) catch {
            @rigs_mode.Refused(_) as e => raise e
            @gate.PeerRefused(m) => raise @rigs_mode.Refused(m)
            @api_routes.Thrown(kind, _) as e => raise @rigs_mode.Thrown(kind, said_of(e))
            e => raise @rigs_mode.Thrown("Error", said_of(e))
          }
          rigs_answer(got)
        }
      }
    },
    callback: f => {
      next.val += 1
      callbacks[next.val] = f
      { "$fn": Json::number(next.val.to_double()) }
    },
  }
}

///|
/// rigs/module.ts RigsLive and elevation/module.ts ElevationLive: the parts of a whole station.
fn P51::rigs_live(self : P51) -> Unit {
  let bus = self.bus
  let host = self.host
  let plane = self.plane.unwrap()
  let cloud = plane.cloud
  let rigs = @rigs_mode.Rigs::new({
    cloud,
    db: bus.db,
    world: self.rigs_world(),
    card_outcomes: true,
    crypto: plane.crypto,
    now: () => wall_ms().to_double(),
    within: async fn(ms, f, what) {
      match @effect.timeout(ms.to_int(), f) {
        Some(v) => v
        None => raise @rigs_mode.Refused(what)
      }
    },
    spawn: f => ignore(host.rt.fork(name="rigs", async fn() { f() catch { e => p51_log("WARN", "rigs", "\{e}") } })),
    id: () => @rigs_mode.request_id_of(wall_ms().to_double(), @drive.hex(@drive.random_bytes(3))),
  }) catch {
    e => {
      p51_log("ERROR", "rigs", "the rigs' part did not start", fields={ "error": Json::string("\{e}") })
      return
    }
  }
  let live : RigsLive = { rigs, }
  self.rigs = Some(live)
  self.stops.push(rigs.listen())
  self.stops.push(() => rigs.close())
  // The devices' slice's list, device_use and its handing back of a rig's devices (devices/module.ts `sources.rigs`):
  // `$rigs` `{op: "rigs.list" | "rigs.use" | "rigs.done", args}`.
  bus.on_peer("$rigs", async fn(_, _, params, _) {
    let args = match params {
      { "args": Array(a), .. } => a
      _ => []
    }
    let s = (i : Int) => match args.get(i) {
      Some(String(x)) => x
      _ => ""
    }
    let said : Json = match params {
      { "op": "rigs.list", .. } => Json::array(rigs.device_entries(s(0), s(1)))
      { "op": "rigs.use", .. } =>
        Json::string(
          rigs.device_use(s(0), s(1), args.get(2).unwrap_or(Json::null()), s(3), match args.get(4) {
            None | Some(Null) => None
            Some(t) => Some(t)
          }),
        )
      { "op": "rigs.done", .. } =>
        Json::array(
          rigs
          .device_done(s(0), match args.get(1) {
            None | Some(Null) => None
            Some(e) => Some(e)
          })
          .map(n => Json::string(n)),
        )
      _ => raise BusError("no such rigs call")
    }
    (said, None)
  })
  // What a rig tells of itself.
  for meth in ["rig.hello", "rig.changed"] {
    bus.on_peer(meth, async fn(peer, ws, params, _) { (rigs.heard_rig(peer, params, ws), None) })
  }
  // How each rig is, looked at again as the control plane's roster changes.
  self.stops.push((bus.cloud_listen.val)(_ => rigs.look()))
  rigs.look()
  // Their routes (`/rigs…`, `POST /mode`), each answered by `Rigs::route`.
  let answer = async fn(r : Json) -> Json {
    let t = (k : String) => match r {
      Object(m) =>
        match m.get(k) {
          Some(String(s)) => s
          _ => ""
        }
      _ => ""
    }
    let query = match r {
      { "queryPairs": Array(q), .. } =>
        q.filter_map(p => match p {
          Array([String(k), String(v)]) => Some((k, v))
          _ => None
        })
      { "query": Object(q), .. } => q.to_array().filter_map(kv => match kv.1 { String(v) => Some((kv.0, v)); _ => None })
      _ => []
    }
    let body = t("rawBody")
    let viewer = match r {
      Object(m) => m.get("viewer").unwrap_or(Json::null())
      _ => Json::null()
    }
    match rigs.route(t("method"), t("path"), query, body, @utf8.encode(body).length(), rigs_viewer(viewer)) {
      Some(a) => part_answer(a)
      None => { "status": 404, "body": "{\"error\":\"no route\"}" }
    }
  }
  bus.parts.routes([
    { meth: "GET", path: "^\\/rigs(?:\\/.*)?$", answer },
    { meth: "POST", path: "^\\/rigs(?:\\/.*)?$", answer },
    { meth: "PUT", path: "^\\/rigs(?:\\/.*)?$", answer },
    { meth: "DELETE", path: "^\\/rigs(?:\\/.*)?$", answer },
    { meth: "POST", path: "^\\/mode$", answer },
  ])
  // The overview's `rigs`: how each rig of the viewer's workspace is.
  bus.parts.overview("rigs", async fn(viewer, _) { Json::array(rigs.listed(rigs_viewer(viewer).workspace)) }) catch {
    _ => ()
  }
  // station_use: a chat's grant of a rig asked of its person; always offered, as rigs/module.ts's (where the workspace
  // has none, its call says so).
  let workspace_of = (session : String) => match bus.store.get_session(session) {
    { "ws": String(w), .. } if w != "" => w
    _ =>
      match cloud.home() {
        Some(h) => h
        None => raise @rigs_mode.Refused("this station is in no workspace")
      }
  }
  let use_ : @rigs_mode.RigUse = {
    ask: async fn(session, rig, reason, timeout) { rigs.use_ask(session, rig, reason, timeout) },
    done: async fn(session, rig) { rigs.use_done(session, rig) },
  }
  ignore(workspace_of)
  bus.parts.tools(
    [
      {
        name: @rigs_mode.rig_use_name,
        declared: @rigs_mode.rig_use(),
        call: async fn(args, context) {
          let session = match context {
            { "session": String(s), .. } => s
            _ => ""
          }
          // (what the rigs refuse or a part they ask throws, said in its words: tools.ts takes an Error's message)
          let text = @rigs_mode.rig_use_run(use_, session, args) catch {
            e => raise Failure(@rigs_mode.error_message(e))
          }
          { "content": [{ "type": "text", "text": Json::string(text) }] }
        },
      },
    ],
  )
  // Windows: running as the machine's administrator.
  if is_windows() {
    self.elevation_live()
  }
}

///|
/// UTF-16LE of `s`, as PowerShell's `-EncodedCommand` takes it (base64 of that).
fn encoded_command(s : String) -> String {
  let b = @buffer.new()
  for i = 0; i < s.length(); i = i + 1 {
    let u = s.code_unit_at(i).to_int()
    b.write_byte((u & 0xFF).to_byte())
    b.write_byte((u >> 8).to_byte())
  }
  @base64.encode(b.to_bytes())
}

///|
/// elevation/module.ts ElevationLive (Windows only).
fn P51::elevation_live(self : P51) -> Unit {
  let bus = self.bus
  let host = self.host
  let powershell = (script : String) => spawn(host, "powershell.exe", ["-NoProfile", "-NonInteractive", "-EncodedCommand", encoded_command(script)], stdout=Piped)
  let elevation = @rigs_mode.Elevation::new({
    data: bus.data,
    app: bus.app,
    now: () => wall_ms().to_double(),
    after: (ms, f) => self.after(ms.to_int(), f),
    changed: () => (bus.overview_changed.val)(),
    probe: async fn() {
      let script = "$id = [Security.Principal.WindowsIdentity]::GetCurrent()\r\n$e = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)\r\n$a = [bool](& (Join-Path $env:SystemRoot 'System32\\whoami.exe') /groups /fo csv | Select-String -SimpleMatch 'S-1-5-32-544')\r\nWrite-Output ([string]$e + ' ' + [string]$a)"
      match (try { Ok(powershell(script)) } catch { e => Err(e) }) {
        Ok(p) => {
          let (_, _, out, _) = p.finished()
          let words = @utf8.decode_lossy(out).trim().split(" ").map(w => w.to_owned()).to_array()
          (words.get(0) == Some("True"), words.get(1) == Some("True"))
        }
        Err(_) => (false, false)
      }
    },
    run: script => match (try { Ok(powershell(script)) } catch { e => Err(e) }) {
      Ok(p) => {
        let exits : Array[(Int?) -> Unit] = []
        ignore(
          host.rt.fork(name="elevation script", async fn() {
            let (code, _, _, _) = p.finished()
            for f in exits {
              f(code)
            }
          }),
        )
        { kill: () => ignore(kill(p.pid, "SIGKILL")), on_error: _ => (), on_exit: f => exits.push(f) }
      }
      Err(_) => {
        let failed : Array[() -> Unit] = []
        ignore(host.rt.fork(name="elevation failed", async fn() { for f in failed { f() } }))
        { kill: () => (), on_error: f => failed.push(f), on_exit: _ => () }
      }
    },
    files: @rigs_mode.ElevationFiles::of_host(host),
  })
  self.fork("elevation", async fn() { elevation.start() })
  self.stops.push(() => elevation.stop())
  bus.parts.routes([
    {
      meth: "PUT",
      path: "^\\/elevation$",
      answer: async fn(r) {
        let t = (k : String) => match r {
          Object(m) =>
            match m.get(k) {
              Some(String(s)) => s
              _ => ""
            }
          _ => ""
        }
        let viewer = match r {
          Object(m) => m.get("viewer").unwrap_or(Json::null())
          _ => Json::null()
        }
        let lang = t("lang")
        match @rigs_mode.elevation_route(elevation, t("method"), t("path"), t("rawBody"), rigs_viewer(viewer), k => tr(lang, k)) {
          Some(a) => part_answer(a)
          None => { "status": 404, "body": "{\"error\":\"no route\"}" }
        }
      },
    },
  ])
  bus.parts.overview("elevation", async fn(viewer, _) { @rigs_mode.elevation_overview(elevation, rigs_viewer(viewer)) }) catch {
    _ => ()
  }
}

// ── a machine that is a rig ──

///|
/// `remote:<workspace>:<station>:<session>`: whose a task's job is (rig/main.ts `ownerOf`).
fn rig_owner_of(workspace : String, station : String, session : String) -> String {
  "remote:\{workspace}:\{station}:\{session}"
}

///|
fn rig_owned(key : String) -> (String, String, String)? {
  guard key.has_prefix("remote:") else { return None }
  let rest = key["remote:".length():].to_owned()
  guard rest.find(":") is Some(i) else { return None }
  let ws = rest[:i].to_owned()
  let after = rest[i + 1:].to_owned()
  guard after.find(":") is Some(j) else { return None }
  Some((ws, after[:j].to_owned(), after[j + 1:].to_owned()))
}

///|
/// rig/main.ts RigLive: the rig's grants and what it tells the stations, its door its jobs reach it by (the agents'
/// door `run` opens), its jobs (the jobs' side's, the bus's `jobs_ask`) followed as the control plane changes, room made
/// as its disk fills.
fn P51::rig_live(self : P51) -> Unit {
  let bus = self.bus
  let host = self.host
  let plane = self.plane.unwrap()
  let cloud = plane.cloud
  let store = bus.store
  let clock : @rigs_mode.Clock = { now: () => wall_ms().to_double(), after: (ms, f) => self.after(ms.to_int(), f) }
  let spawn_ = (f : async () -> Unit) => ignore(host.rt.fork(name="rig", async fn() { f() catch { e => p51_log("WARN", "rig", "\{e}") } }))
  let jobs_ask = async fn(op : String, arg : Json) -> Json { (bus.jobs_ask.val)(op, arg) }
  let rig = @rigs_mode.Rig::new({
    data: bus.data,
    cloud,
    ask: async fn(station, request) {
      let ws = match request {
        { "workspace": String(w), .. } => Some(w)
        _ => None
      }
      let meth = match request {
        { "method": String(m), .. } => m
        _ => ""
      }
      let (answer, _) = bus.call_peer(station, ws, meth, request) catch {
        @gate.PeerRefused(m) => raise @rigs_mode.Refused(m)
        e => raise e
      }
      answer
    },
    busy: (ws, station, session) => store.running_jobs_at_least(Json::string(rig_owner_of(ws, station, session)), 1.0) catch { _ => false },
    stop: (ws, station, session) => {
      let ids = store.up_job_ids(Json::string(rig_owner_of(ws, station, session)), false) catch { _ => [] }
      for id in ids {
        spawn_(async fn() { ignore(jobs_ask("stop", { "id": id })) })
      }
    },
    running: () => {
      let jobs = store.jobs_running() catch { _ => [] }
      jobs.filter_map(j => match j {
        { "sessionKey": String(k), .. } => rig_owned(k)
        _ => None
      })
    },
    reach: async fn(device) {
      let said = (bus.ui_ask.val)("devices.reach", device)
      if said is Null {
        raise @rigs_mode.DeviceRefused(503, "devices cannot be reached on this rig yet")
      }
      { destroy: () => (), on_close: _ => () }
    },
    spawn: spawn_,
    clock,
    files: @rigs_mode.Files::of_host(host),
    crypto: plane.crypto,
    host,
  })
  self.rig = Some(rig)
  // A rig has no hub: what the jobs' side asks of one here is the rig's (`describe`'s signed `rig`).
  let hub_before = bus.hub_ask.val
  bus.hub_ask.val = async fn(op, arg) {
    match op {
      "rig.described" => rig.described()
      _ => hub_before(op, arg)
    }
  }
  self.stops.push(() => ignore(host.rt.fork(name="rig close", async fn() { rig.close() })))
  // What a station asks of it: through its grants first, its own `rig.` asked of it.
  bus.on_peer_prefix("rig.", async fn(peer, ws, _meth, params, _) { (rig.heard(peer, params, ws.unwrap_or(cloud.home().unwrap_or(""))), None) })
  let main = @rigs_mode.RigMain::new(
    {
      jobs: {
        running_at_least: (owner, n) => store.running_jobs_at_least(Json::string(owner), n.to_double()) catch { _ => false },
        up_job_ids: owner => (store.up_job_ids(Json::string(owner), false) catch { _ => [] }).filter_map(x => match x { String(s) => Some(s); _ => None }),
        running: () => (store.jobs_running() catch { _ => [] }).filter_map(j => match j { { "id": String(id), .. } => Some(id); _ => None }),
        stop: async fn(id) { ignore(jobs_ask("stop", { "id": Json::string(id) })) },
        relaunch: () => spawn_(async fn() { ignore(jobs_ask("relaunch", Json::null())) }),
        stop_all: async fn(why) { ignore(jobs_ask("stopAll", { "why": Json::string(why) })) },
      },
      disk_of: async fn() { disk_of(bus.data).unwrap_or((0.0, 0.0)) },
      renewables: async fn(now) { ignore(jobs_ask("upkeep.renewables", { "now": Json::number(now) })) },
      relieve: async fn(now, soft) { ignore(jobs_ask("remote.relieve", { "now": Json::number(now), "soft": Json::number(soft) })) },
      become_other: () => self.fork("become a station", async fn() { become_other(bus) }),
      // (the agents' door `run` opens, once the process before is gone: shared by the rig's jobs)
      open_door: async fn(_) {
        let url = bus.door_ready.wait()
        let port = match url.rev_find(":") {
          Some(i) =>
            match url[i + 1:].to_owned().find("/") {
              Some(j) => attempt(() => @string.parse_int(url[i + 1:i + 1 + j].to_owned())).unwrap_or(0)
              None => 0
            }
          None => 0
        }
        (port, url)
      },
      set_notify_url: url => ignore(host.rt.fork(name="notify url", async fn() { ignore(jobs_ask("setNotifyUrl", { "url": Json::string(url) })) })),
      mcp_fd: None,
      shown_port: Some(0),
      serving: (_, _) => (),
      drained: d => (bus.control_say)({ "drained": Json::string(d) }),
      failed: why => (bus.control_say)({ "failed": Json::string(why) }),
      own_data: path([homedir(), ".stillfail"]) == bus.data,
      remembered_port: None,
      files: @rigs_mode.Files::of_host(host),
      data: bus.data,
      clock,
      spawn: spawn_,
    },
    cloud,
  )
  self.stops.push(() => main.close())
  self.fork("rig start", async fn() { main.start(cloud) })
  main.start_relieving()
  self.stops.push((bus.cloud_listen.val)(_ => spawn_(async fn() { main.changed() })))
  // Nothing here to hand over turn by turn: drained at once.
  bus.drain_wait.val = async fn() {
    write_whole(path([bus.data, "run", "drained"]), "idle\n")
    "idle"
  }
}
