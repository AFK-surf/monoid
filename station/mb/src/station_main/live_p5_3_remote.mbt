// The tasks other stations of the workspace run here, and this station's sessions' tasks there (station/src/jobs/
// remote.ts `Remote`): what they are and do is the sessions' program's (station/mb/src/reader/remote*.mbt,
// dirsync.mbt, dirsync_source.mbt: the pseudo-actor `#remote` of live_p5_3_program.mbt's program), as under the
// TypeScript station: what is asked of a task here (`task.*`, `sync.*`, `file.*`, `session.*`), a directory synced
// both ways (Git's or walked, its submodules too), the mirrors, following tasks started from here (`check`, `settle`,
// what a station missed telling), the sweeps, the station_* tools. This is what of them is the station's, which the
// program asks for (`node.*`, its `store.*`): the peers' bus (`bus.call_peer`, `bus.on_peer`), the bytes that go
// with requests (a sync's packed pieces landed in a file the program unpacks, a file's whole after its answer), the
// rooms of other stations' sessions (`@jobs_host.Rooms`), a workspace's size, the load, what tasks bring back
// (`@jobs_host.bring_back`), the roster's changes (`revoke`) and the disk's.

///|
/// What the program knows the remote tasks' shell by.
let p53_remote_key : String = "#remote"

///|
/// Under how many bytes free the disk is low to the program's `relieve`.
let p53_low_below : Double = 20.0 * 1073741824.0

///|
priv struct P53Remote {
  bus : LiveBus
  program : P53Program
  jobs : P53Jobs
  rooms : @jobs_host.Rooms
  bulk : @jobs_host.Bulk
  root : String
  /// Where this process lands a sync's packed pieces for the program, and packs what it sends: its own directory.
  landing : String
  reader : @jobs_host.WorkspaceReader
  /// The bytes of the requests being answered, by the number the program is told, and those of its answers.
  in_bytes : Map[Int, Bytes]
  out_bytes : Map[Int, Bytes]
  mut bytes_next : Int
  /// What the program writes of a path (`writing`, `wrote`): a read of it waits for its writes.
  writing : Map[String, Map[Int, @effect.Deferred[Unit]]]
  mut low_below : Double
  /// The CPUs' ticks (busy, total) noted the last minute or so (host.ts `CpuWindow`), and the GPUs as last read.
  cpu : Array[(Double, (Double, Double))]
  gpus : @jobs_host.Gpus
  /// What chats used of other stations' workspaces, by their record's path, as the program told it (`used`, Null:
  /// none), and whether it told every one it read as it started (`usedReady`).
  used : Map[String, Json]
  mut used_ready : Bool
}

///|
/// host.ts CPU_EVERY_MS, CPU_SPAN_MS.
let p53_cpu_every_ms : Int = 15000

///|
let p53_cpu_span_ms : Double = 60000.0

///|
/// host.ts GPU_SAMPLE_MS: how long a sample waits for the GPUs before it gives what they said last.
let p53_gpu_sample_ms : Int = 400

///|
async fn P53Remote::new(bus : LiveBus, program : P53Program, jobs : P53Jobs) -> P53Remote {
  let root = @nodepath.join(sep(), [bus.data, "remote"])
  let host = bus.host
  for name in ["incoming", "outgoing", "sessions", "used", "prepared"] {
    host_mkdir_quiet(host, @nodepath.join(sep(), [root, name]))
  }
  let landing_root = @nodepath.join(sep(), [root, "landing"])
  @jobs_host.tidy_landing(host, landing_root, @drive.pid(), async fn(pid) { pid_alive(pid) })
  let reader = @jobs_host.WorkspaceReader::new(
    () => wall_ms().to_double(),
    async fn(path, limit) { p53_workspace_size(bus, path, limit) },
    f => fork_bg(host, "a workspace's size", async fn() { f() }),
  )
  let r : P53Remote = {
    bus,
    program,
    jobs,
    rooms: @jobs_host.Rooms::new(host, root),
    bulk: @jobs_host.Bulk::new(),
    root,
    landing: @nodepath.join(sep(), [landing_root, @drive.pid().to_string()]),
    reader,
    in_bytes: Map([]),
    out_bytes: Map([]),
    bytes_next: 0,
    writing: Map([]),
    low_below: p53_low_below,
    cpu: [],
    used: Map([]),
    used_ready: false,
    gpus: make_gpus(host),
  }
  program.shell(p53_remote_key, { asked: async fn(f, args) { r.asked(f, args) }, told: (f, args) => r.told(f, args) })
  ignore(program.call(p53_remote_key, "start", [jstr(root)])) catch { _ => () }
  r
}

///|
fn P53Remote::attach(self : P53Remote) -> Unit {
  let bus = self.bus
  // (the CPUs' ticks noted now and every CPU_EVERY_MS, for how busy they were over the last minute: host.ts `follow`)
  fork_bg(bus.host, "the CPUs' ticks", async fn() {
    while !bus.stopped.is_done() {
      if self.cpu_ticks() is Some(t) { self.cpu_note(wall_ms().to_double(), t) }
      @effect.sleep(p53_cpu_every_ms) // timer: a sample of this machine (its CPUs)
    }
  })
  bus.parts.tools(self.tools())
  bus.on_peer("describe", async fn(peer, ws, _request, _bytes) { (self.describe(peer, ws.unwrap_or("")), None) })
  // (a task started from here changed on its station: asked about)
  bus.on_peer("task.changed", async fn(_peer, ws, request, _bytes) {
    (self.program.call(p53_remote_key, "changed", [jstr(ws.unwrap_or("")), request]), None)
  })
  for prefix in ["task.", "sync.", "file.", "session."] {
    bus.on_peer_prefix(prefix, async fn(peer, ws, meth, request, bytes) {
      let workspace = match ws {
        Some(w) => w
        None => bus_home(bus).unwrap_or("")
      }
      self.answer(workspace, peer, jwith(request, "method", jstr(meth)), bytes)
    })
  }
  // (a task here told of by the station, stopped from the pages: its source told)
  self.jobs.remote_heard.push(id => {
    ignore(bus.host.rt.fork_quiet(name="a task changed", async fn() {
      ignore(self.program.call(p53_remote_key, "pushOut", [jstr(id[7:].to_owned())])) catch { _ => () }
    }))
  })
  bus.parts.session_ended(session => {
    ignore(bus.host.rt.fork_quiet(name="a session's tasks", async fn() {
      ignore(self.program.call(p53_remote_key, "closeSession", [jstr(session), jn(bus.store.now().to_double())])) catch { _ => () }
    }))
  })
  // (the tasks followed, what was missed told, the sweeps going: once the station before is gone; tasks of peers no
  // longer in a workspace stopped, now and as the roster or the config changes: remote.ts `followRoster`)
  fork_bg(bus.host, "remote tasks", async fn() {
    (bus.previous_gone)()
    ignore(self.program.call(p53_remote_key, "attached", [])) catch { _ => () }
    self.revoke()
    ignore((bus.cloud_listen.val)(_ => fork_bg(bus.host, "roster", async fn() { self.revoke() })))
    ignore((bus.config_listen.val)(_ => fork_bg(bus.host, "roster", async fn() { self.revoke() })))
    self.tidy_back_hourly()
  })
}

///|
/// Tasks of stations no longer in a workspace stopped (remote.ts `followRoster`, the program's `revoke`).
async fn P53Remote::revoke(self : P53Remote) -> Unit {
  let state = bus_cloud(self.bus)
  let rosters = []
  if jtext_or_empty(state, "workspace") != "" && jfield(state, "removed_at") is Null {
    let add = (m : Json) => {
      let peers = match jfield(m, "peers") {
        Array(xs) => xs.filter_map(p => match jtext(p, "id") { Some(id) => Some(jstr(id)); None => None })
        _ => []
      }
      rosters.push(jobj_of([("workspace", jfield(m, "workspace")), ("peers", Json::array(peers))]))
    }
    add(state)
    match jfield(state, "joined") {
      Array(js) => for j in js { add(j) }
      _ => ()
    }
  }
  ignore(self.program.call(p53_remote_key, "revoke", [Json::array(rosters), jb((self.bus.cloud_reached.val)())])) catch {
    e => slice_log("warn", "peer", "revoking tasks failed", jobj_of([("error", jstr(p53_words(e)))]))
  }
}

///|
/// What tasks brought back (`station-back/<key>`) let go of once nothing in it changed for six hours: now and hourly.
async fn P53Remote::tidy_back_hourly(self : P53Remote) -> Unit {
  while !self.bus.stopped.is_done() {
    let workspaces = (self.bus.store.live_sessions() catch { _ => [] }).filter_map(s => jtext(s, "workspace"))
    ignore(@jobs_host.tidy_back(self.bus.host, workspaces, wall_ms().to_double()))
    @effect.sleep(3600000) // timer: an hourly sweep of what tasks brought back (BACK_TIDY_MS)
  }
}

///|
/// A request of another station's taken in (remote.ts `answer`): its bytes, if any, kept for the program to have
/// written where it says (`bytes`); a sync's packed pieces landed in a file first (`landed`); an answer's bytes (a file
/// asked for whole) sent after it. A refusal is the program's answered refusal (`Refused`).
async fn P53Remote::answer(self : P53Remote, workspace : String, peer : String, request : Json, bytes : Bytes?) -> (Json, Bytes?) {
  let host = self.bus.host
  let mut asked = match request {
    Object(m) => {
      let c = m.copy()
      c.remove("landed")
      c.remove("bytes")
      Json::object(c)
    }
    _ => request
  }
  let mut id = 0
  let mut landed : String? = None
  defer {
    if id != 0 {
      self.in_bytes.remove(id)
    }
  }
  match bytes {
    Some(b) if jtext_or_empty(request, "method") == "sync.put" => {
      self.bytes_next += 1
      let file = @nodepath.join(sep(), [self.landing, "\{self.bytes_next}.zst"])
      ignore(host.shell("fs.mkdir", { "path": jstr(self.landing), "recursive": jb(true) }))
      ignore(host.shell("fs.put", { "path": jstr(file), "offset": jn(0.0), "truncate": jb(true), "mode": ji(384), "nofollow": jb(true) }, bytes=b))
      landed = Some(file)
      asked = jwith(asked, "landed", jstr(file))
    }
    Some(b) => {
      self.bytes_next += 1
      id = self.bytes_next
      self.in_bytes[id] = b
      asked = jwith(asked, "bytes", ji(id))
    }
    None => ()
  }
  let answer = try {
    self.program.call(p53_remote_key, "handle", [jstr(workspace), jstr(peer), asked])
  } catch {
    e => {
      match landed {
        Some(f) => ignore(try { Ok(host.shell("fs.remove", { "path": jstr(f) })) } catch { e2 => Err(e2) })
        None => ()
      }
      raise @jobs_host.Refused(p53_words(e))
    }
  }
  match landed {
    Some(f) => ignore(try { Ok(host.shell("fs.remove", { "path": jstr(f) })) } catch { e => Err(e) })
    None => ()
  }
  match jnum_of(answer, "outBytes") {
    Some(n) =>
      match self.out_bytes.get(n.to_int()) {
        Some(out) => {
          self.out_bytes.remove(n.to_int())
          let rest = match answer {
            Object(m) => {
              let c = m.copy()
              c.remove("outBytes")
              Json::object(c)
            }
            _ => answer
          }
          (rest, Some(out))
        }
        None => (answer, None)
      }
    None => (answer, None)
  }
}

///|
/// A request to another station (remote.ts `ask`), as the peers' bus carries it; a refusal it answered told apart
/// from one that did not get through.
async fn P53Remote::ask(self : P53Remote, station : String, request : Json, bytes? : Bytes) -> (Json, Bytes?) {
  let meth = jtext_or_empty(request, "method")
  // (one to a sandbox is this station's own: answered here as a station's would be, its tasks run in the sandbox)
  if station.has_prefix(@agent_runtimes.sandbox_prefix) {
    guard self.sandboxes().iter().find_first(d => @agent_runtimes.sandbox_prefix + d.name == station) is Some(d) else {
      raise @jobs_host.Refused("no such sandbox on this station (config.json's sandboxes)")
    }
    if meth == "describe" {
      return (of_jv(@agent_runtimes.sandbox_described(d)), None)
    }
    // (as a peer's request is handled: by its method, `task.changed` its own)
    return self.bus.dispatch_peer(station, Some(jtext_or_empty(request, "workspace")), meth, request, bytes) catch {
      BusError(m) => raise @jobs_host.Refused(m)
      e => raise e
    }
  }
  self.bus.call_peer(station, Some(jtext_or_empty(request, "workspace")), meth, request, bytes?) catch {
    @jobs_host.Refused(m) => raise @jobs_host.Refused(m)
    @jobs_host.NoBytes(m) => raise @jobs_host.NoBytes(m)
    // (the mesh's own: the other station answered with an error, or its transport carries no bytes)
    @gate.PeerRefused(m) | @gate.Refused(m) | @gate.LockRefusal(m) | @gate.WaysRefusal(m) | @gate.MarkRefusal(m) =>
      raise @jobs_host.Refused(m)
    @gate.NoBytes(m) => raise @jobs_host.NoBytes(m)
    BusError(m) => raise @jobs_host.Unreached(m)
    e => raise @jobs_host.Unreached(p53_words(e))
  }
}

///|
/// The peers' ask as `@jobs_host`'s transfers make it: a body's bytes sent with the request, an answer's given back.
fn P53Remote::asker(self : P53Remote) -> @jobs_host.Ask {
  async fn(station, request, body) {
    let bytes = match body {
      Some(b) => Some(p53_body_bytes(self.bus.host, b))
      None => None
    }
    let (answer, back) = self.ask(station, request, bytes?)
    (answer, back.map(b => @jobs_host.Body::Data(b)))
  }
}

///|
/// What the program tells the station of the remote tasks, needing no answer.
fn P53Remote::told(self : P53Remote, f : String, args : Array[Json]) -> Unit {
  match f {
    "writing" => {
      let path = arg_str(args, 0)
      let id = arg_int(args, 1)
      let theirs = match self.writing.get(path) {
        Some(t) => t
        None => {
          let t = Map([])
          self.writing[path] = t
          t
        }
      }
      theirs[id] = @effect.Deferred::new()
    }
    "wrote" => {
      let path = arg_str(args, 0)
      let id = arg_int(args, 1)
      match self.writing.get(path) {
        Some(theirs) => {
          if theirs.get(id) is Some(d) { ignore(d.succeed(())) }
          theirs.remove(id)
          if theirs.length() == 0 {
            self.writing.remove(path)
          }
        }
        None => ()
      }
    }
    "log" => slice_log(arg_str(args, 0), "remote", arg_str(args, 1), arg_at(args, 2))
    "used" => self.used[arg_str(args, 0)] = arg_at(args, 1)
    "usedReady" => self.used_ready = true
    // (a chat's use record as the program has it now: read through it when asked)
    _ => ()
  }
}

///|
/// Once what the program writes of `path` is written.
async fn P53Remote::written(self : P53Remote, path : String) -> Unit {
  match self.writing.get(path) {
    Some(theirs) => for _, d in theirs.copy() { d.wait() }
    None => ()
  }
}

///|
/// What the program asks of the station for the remote tasks (remote.ts `asked`).
async fn P53Remote::asked(self : P53Remote, f : String, args : Array[Json]) -> Json {
  let bus = self.bus
  let host = bus.host
  if f.has_prefix("store.") {
    return dispatch_store(bus, f[6:].to_owned(), args)
  }
  let a = (i : Int) => arg_at(args, i)
  let s = (i : Int) => arg_str(args, i)
  match f {
    "node.ask" => {
      let (answer, _) = self.ask(s(0), a(1))
      answer
    }
    "node.seen" => {
      let seen = self.rooms.seen(s(0), s(1), s(2), bus.store.now().to_double())
      if !jtrue(seen, "write") {
        self.written(@nodepath.join(sep(), [self.rooms.room(s(0), s(1), s(2)), "session.json"]))
      }
      seen
    }
    "node.written" => {
      self.written(s(0))
      Json::null()
    }
    "node.seenAt" =>
      (self.rooms.seen_at(s(0))).map(jn).unwrap_or(Json::null())
    "node.forgetSeen" => {
      self.rooms.forget_seen(s(0))
      Json::null()
    }
    "node.closeRoom" => {
      let dirs = match a(1) {
        Array(xs) => xs.filter_map(x => if x is String(t) { Some(t) } else { None })
        _ => []
      }
      self.rooms.close_room(s(0), dirs, as_num(a(2)))
    }
    "node.removeTask" | "node.removeMirror" => {
      ignore(host.shell("fs.remove", { "path": jstr(s(0)), "recursive": jb(true) }))
      Json::null()
    }
    "node.treeBytes" => jn(p53_tree_bytes(self.bus, s(0)))
    "node.roomInfo" => jobj_of([("bytes", jn(p53_tree_bytes(self.bus, s(0)))), ("seenAt", jn(self.rooms.seen_at(s(0)).unwrap_or(0.0)))])
    "node.load" => self.measured_load()
    "node.workspaceSize" => {
      let limit = as_num(a(1)).unwrap_or(@jobs_host.default_limit)
      match self.reader.size(s(0), limit~) {
        Some(size) => {
          let v = jwith(size.to_json(), "present", jb(true))
          jwith(jwith(v, "pending", jb(false)), "path", a(0))
        }
        None => jobj_of([("present", jb(true)), ("pending", jb(true)), ("path", a(0))])
      }
    }
    "node.jobJson" => @jobs_host.job_json(a(0))
    "node.tail" => jstr(@jobs_host.tail(host, s(0), arg_int(args, 1)))
    "node.ensureIdentity" => {
      @agent_runtimes.ensure_identity(host, bus.data)
      Json::null()
    }
    "node.filePut" => {
      let request = a(1)
      let incoming = match jnum_of(request, "bytes") {
        Some(n) => {
          let got = self.in_bytes.get(n.to_int())
          self.in_bytes.remove(n.to_int())
          got
        }
        None => None
      }
      @jobs_host.file_put(host, s(0), request, incoming.map(b => @jobs_host.Body::Data(b)))
    }
    "node.fileGet" => {
      let (answer, body) = @jobs_host.file_get(host, s(0), a(1))
      match body {
        Some(b) => {
          self.bytes_next += 1
          let id = self.bytes_next
          self.out_bytes[id] = p53_body_bytes(host, b)
          let rest = match answer {
            Object(m) => {
              let c = m.copy()
              c["outBytes"] = ji(id)
              Json::object(c)
            }
            _ => answer
          }
          rest
        }
        None => answer
      }
    }
    "node.diskLow" =>
      match disk_of(s(0)) {
        Some((free, _)) => jb(free < self.low_below)
        None => jb(false)
      }
    "node.notify" => {
      bus.hub_notify(session=s(0), text=s(1)) catch { _ => () }
      Json::null()
    }
    "node.cloudState" => bus_cloud(bus)
    "node.sandboxes" => Json::array(self.sandboxes().map(d => jobj_of([("name", jstr(d.name))])))
    "node.listStations" => self.station_list(s(0), s(1), s(2))
    "node.stationFile" => @jobs_host.station_file(host, self.bulk, self.asker(), s(0), a(1), a(2), s(3))
    "node.directory" => {
      if !host_is_dir(host, s(0)) {
        raise P53Error("\{s(0)} is not a directory")
      }
      Json::null()
    }
    "node.resolve" => jstr(@nodepath.join(sep(), [s(0)]))
    "node.syncPacking" => {
      ignore(host.shell("fs.mkdir", { "path": jstr(self.landing), "recursive": jb(true) }))
      self.bytes_next += 1
      jstr(@nodepath.join(sep(), [self.landing, "\{self.bytes_next}.out.zst"]))
    }
    "node.syncPut" => {
      let station = s(0)
      let request = a(1)
      let file = s(2)
      let whole = a(3) is True
      let size = match host.shell("fs.meta", { "path": jstr(file) }) {
        (m, _) => jnum_of(m, "size").unwrap_or(0.0)
      }
      let data = p53_body_bytes(host, File(file, 0.0, size))
      if whole {
        self.bulk.run(async fn() {
          let (answer, _) = self.ask(station, request, bytes=data)
          answer
        })
      } else {
        self.bulk.run(async fn() {
          let (answer, _) = self.ask(station, jwith(request, "data", jstr(@base64.encode(data))))
          answer
        })
      }
    }
    "node.bringBack" => {
      let entry = a(0)
      let row = bus_session_row(bus, jtext_or_empty(entry, "session"))
      @jobs_host.bring_back(host, self.bulk, self.asker(), entry, jtext(row, "workspace"), self.root)
    }
    _ => raise P53Error("no remote ask \{f}")
  }
}

///|
/// The load as station_list and a queued task are told it, within LOAD_WAIT_MS (remote.ts `measuredLoad`).
async fn P53Remote::measured_load(self : P53Remote) -> Json {
  let got = try { Ok(@effect.timeout(@jobs_host.load_wait_ms, async fn() { self.load() })) } catch { e => Err(e) }
  match got {
    Ok(Some(l)) => l
    Ok(None) => jobj_of([("unavailable", jstr("not measured within \{@jobs_host.load_wait_ms / 1000} s"))])
    Err(e) => jobj_of([("unavailable", jstr(p53_words(e)))])
  }
}

///|
/// What this station is and runs, for another of the workspace (remote.ts `describe`).
async fn P53Remote::describe(self : P53Remote, peer : String, ws : String) -> Json {
  let answer = jobj_of([
    ("protocol", ji(1)),
    ("version", jstr(self.bus.version)),
    ("os", jstr(match platform() { "darwin" => "macos"; "win32" => "windows"; p => p })),
    ("arch", jstr(match arch() { "arm64" => "aarch64"; "x64" => "x86_64"; "ia32" => "x86"; a => a })),
    ("tasks", jb(true)),
    ("sessions", jb(true)),
    ("messages", jb(true)),
    ("reads", jb(true)),
    ("files", jb(true)),
    ("chats", jb(true)),
    ("sync", ji(1)),
    ("smallTasks", ji(1)),
    ("fileChunkBytes", ji(@jobs_host.chunk)),
    ("maxFileBytes", jn(@jobs_host.max_file)),
    ("load", self.measured_load()),
  ])
  // (a station that only runs tasks: none of a station's sessions, messages, reads or chats, and who may use it, as its
  // rig part says it: rig/module.ts `described`)
  guard !(jfield(bus_cloud(self.bus), "rig") is Null) else { return answer }
  let rig = self.bus.hub_rig_described(peer, ws) catch {
    _ => Json::null()
  }
  let out : Map[String, Json] = Map([])
  if answer is Object(a) {
    for k, v in a {
      out[k] = v
    }
  }
  for k in ["sessions", "messages", "reads", "chats"] {
    out[k] = jb(false)
  }
  out["rig"] = Json::null()
  if rig is Object(r) {
    for k, v in r {
      out[k] = v
    }
  }
  Json::object(out)
}

///|
/// The CPUs' ticks now (busy, total): /proc/stat's on Linux, the CPUs' times elsewhere (platform `cpuTicks`).
async fn P53Remote::cpu_ticks(self : P53Remote) -> (Double, Double)? {
  if platform() == "linux" {
    return shell_read_text(self.bus.host, "/proc/stat").bind(@ops_platform.proc_stat_ticks)
  }
  machine_cpu_ticks()
}

///|
/// host.ts `CpuWindow.note`: the oldest kept is the last one at least a span old.
fn P53Remote::cpu_note(self : P53Remote, at : Double, ticks : (Double, Double)) -> Unit {
  self.cpu.push((at, ticks))
  while self.cpu.length() > 1 && at - self.cpu[1].0 >= p53_cpu_span_ms {
    ignore(self.cpu.remove(0))
  }
}

///|
/// host.ts `recentBusy`: how busy the CPUs have been since the oldest ticks noted until now, and over how many
/// seconds; none before there is anything to compare with.
async fn P53Remote::recent_busy(self : P53Remote) -> (Double, Double)? {
  let at = wall_ms().to_double()
  guard self.cpu_ticks() is Some((b1, t1)) else { return None }
  let first = self.cpu.search_by(s => at - s.0 <= p53_cpu_span_ms + p53_cpu_every_ms.to_double())
  guard first is Some(i) else { return None }
  let (seen_at, (b0, t0)) = self.cpu[i]
  guard at - seen_at >= 1000.0 && t1 > t0 else { return None }
  let share = ((b1 - b0) / (t1 - t0)).max(0.0).min(1.0)
  Some(((share * 100.0).round() / 100.0, ((at - seen_at) / 1000.0).round()))
}

///|
/// The GPUs, or what they said last where they take longer than GPU_SAMPLE_MS (host.ts `sample`).
async fn P53Remote::gpus_now(self : P53Remote) -> Json {
  let gpus = self.gpus
  let read = @effect.timeout(p53_gpu_sample_ms, async fn() { gpus.read() }) catch { _ => None }
  let got = match read {
    Some(g) => g
    None => gpus.cached()
  }
  match got {
    Some(g) => gpus_to_json(g)
    None => Json::null()
  }
}

///|
/// station_list (remote.ts `stationList`): the workspace's stations, or one in detail.
async fn P53Remote::station_list(self : P53Remote, workspace : String, session : String, station : String) -> Json {
  let me = bus_station_id(self.bus)
  if station == me || station == "self" {
    return @jobs_host.detailed(self.describe("", workspace))
  }
  if station != "" {
    let got = @effect.timeout(@jobs_host.list_alone_wait_ms, async fn() {
      let (d, _) = self.ask(station, jobj_of([("method", jstr("describe")), ("workspace", jstr(workspace))]))
      d
    })
    return match got {
      Some(d) => @jobs_host.detailed(d)
      None =>
        jobj_of([("id", jstr(station)), ("unanswered", jstr("did not answer within \{@jobs_host.list_alone_wait_ms / 1000} s; not known to be offline (it may be starting or updating): ask again in a minute"))])
    }
  }
  let roster = self.roster(workspace)
  @jobs_host.list_stations(
    roster,
    me,
    self.bus.version,
    async fn() { self.measured_load() },
    async fn(id) {
      let (d, _) = self.ask(id, jobj_of([("method", jstr("describe")), ("workspace", jstr(workspace))]))
      d
    },
    self.sandboxes().map(d => @jobs_host.Sandbox::{ name: d.name, described: of_jv(@agent_runtimes.sandbox_described(d)) }),
    Some(async fn(rig, answer) {
      self.bus.rigs_call("rigs.stationListed", [jstr(workspace), jstr(session), rig, answer.unwrap_or(Json::null())])
    }),
  )
}

///|
/// This station's sandboxes (config.json's `sandboxes`, agents/sandbox.ts `sandboxesOf`).
fn P53Remote::sandboxes(self : P53Remote) -> Array[@agent_runtimes.Sandbox] {
  p53_sandboxes(self.bus)
}

///|
fn p53_sandboxes(bus : LiveBus) -> Array[@agent_runtimes.Sandbox] {
  @agent_runtimes.sandboxes_of(Some(to_jv((bus.config_raw.val)())))
}

///|
/// The workspace's roster as the mesh says it (`peers`); where the mesh is not up, this station alone as cloud.json
/// names it.
async fn P53Remote::roster(self : P53Remote, ws : String) -> Json {
  let (r, _) = self.bus.call_peer("", Some(ws), "peers", jobj_of([("method", jstr("peers")), ("workspace", jstr(ws))])) catch {
    _ => {
      let state = bus_cloud(self.bus)
      let me = bus_station_id(self.bus)
      (jobj_of([("stations", Json::array([jobj_of([("id", jstr(me)), ("name", jfield(state, "name"))])]))]), None)
    }
  }
  r
}

///|
/// The rooms of other stations' sessions held to their bound (remote.ts `upkeep`): those unused for IDLE_MS, then the
/// longest unused past the budget. What went.
async fn P53Remote::upkeep(self : P53Remote, now : Double, total : Double?) -> (Int, Double) {
  let expired = match (try { Ok(self.program.call(p53_remote_key, "expire", [jn(now)])) } catch { e => Err(e) }) {
    Ok(Number(n, ..)) => n.to_int()
    _ => 0
  }
  let freed = match (try { Ok(self.program.call(p53_remote_key, "budget", [jn(now), jn(@jobs_host.remote_budget(total))])) } catch { e => Err(e) }) {
    Ok(Number(n, ..)) => n
    _ => 0.0
  }
  (expired, freed)
}

///|
/// The disk low: the mirrors of other stations' tasks not in use go first (remote.ts `relieve`), under `below`.
async fn P53Remote::relieve(self : P53Remote, now : Double, below : Double) -> Unit {
  self.low_below = below
  ignore(self.program.call(p53_remote_key, "relieve", [jn(now)])) catch { _ => () }
  self.low_below = p53_low_below
}

///|
/// A directory's size on disk up to `limit` (sessions/footprint.ts `measuredUpTo`), by the footprint builder
/// (`--builder footprint`, station/mb src/footprint): a process a measure, walking as `walkBounded` does, within
/// MEASURE_UP_TO; past `limit` a lower bound, not walked further.
async fn p53_workspace_size(bus : LiveBus, path : String, limit : Double) -> @jobs_host.WorkspaceSize {
  // (a builder nobody waits on: yields the machine, its disk too, to the foreground; mb-reader.ts BACKGROUND_BUILDERS)
  let (program, args) = backgrounded(reader_program(bus), ["--builder", "footprint", "--sep", sep()])
  let proc = spawn(bus.host, program, args, stdin_piped=true, stdout=Piped, stderr=Ignored) catch {
    SysError(why) => raise P53Error(why)
  }
  let ask = jobj_of([
    ("path", jstr(path)),
    ("base", jstr(path)),
    ("finding", jb(false)),
    ("strict", jb(true)),
    ("stopAfter", jn(limit)),
    ("maxEntries", ji(100000)),
    ("maxDurationMs", ji(15000)),
  ])
  ignore(proc.write(@utf8.encode(ask.stringify() + "\n")))
  proc.end_input()
  let (_, _, out, _) = proc.finished()
  let line = @utf8.decode_lossy(out).split("\n").to_array()
  let said = if line.length() > 0 { attempt(() => @json.parse(line[0].to_string())).unwrap_or(Json::null()) } else { Json::null() }
  if jtext(said, "error") is Some(e) { raise P53Error(e) }
  let bytes = jnum_of(said, "size").unwrap_or(0.0)
  if jtrue(said, "enough") {
    { bytes, complete: false, truncated: false }
  } else if jtrue(said, "complete") {
    { bytes, complete: true, truncated: false }
  } else {
    { bytes, complete: false, truncated: true }
  }
}

///|
/// The size of a tree on its disk (ops/storage.ts `treeBytes`, as `@jobs_host.tree_bytes` asks it), measured by the
/// footprint builder in a process of its own: walked here, a mirror's room of a hundred GB held the station's loop for
/// half a minute. Nothing where it could not be measured.
async fn p53_tree_bytes(bus : LiveBus, path : String) -> Double {
  p53_tree_bytes_by(bus.host, reader_program(bus), path)
}

///|
/// `p53_tree_bytes` by the program at `reader`.
async fn p53_tree_bytes_by(host : @host.Host, reader : String, path : String) -> Double {
  // (a builder nobody waits on: yields the machine, its disk too, to the foreground; mb-reader.ts BACKGROUND_BUILDERS)
  let (program, args) = backgrounded(reader, ["--builder", "footprint", "--sep", sep()])
  let proc = spawn(host, program, args, stdin_piped=true, stdout=Piped, stderr=Ignored) catch {
    _ => return 0.0
  }
  let ask = jobj_of([("path", jstr(path)), ("maxEntries", ji(1_000_000)), ("maxDurationMs", ji(60_000))])
  ignore(proc.write(@utf8.encode(ask.stringify() + "\n")))
  proc.end_input()
  let (_, _, out, _) = proc.finished() catch { _ => return 0.0 }
  let line = @utf8.decode_lossy(out).split("\n").to_array()
  let said = if line.length() > 0 { attempt(() => @json.parse(line[0].to_string())).unwrap_or(Json::null()) } else { Json::null() }
  jnum_of(said, "size").unwrap_or(0.0)
}

///|
/// The station's load now (load.ts `measure`), what station_list and a queued task are told.
async fn P53Remote::load(self : P53Remote) -> Json {
  let bus = self.bus
  @jobs_host.measure(
    async fn() {
      let m = machine()
      let total = jnum_of(m, "totalmem").unwrap_or(0.0)
      let free = jnum_of(m, "freemem").unwrap_or(0.0)
      let (dfree, dtotal) = disk_of(bus.data).unwrap_or((0.0, 0.0))
      jobj_of([
        ("os", jstr(platform())),
        ("arch", jstr(arch())),
        ("cpus", ji(match jfield(m, "cpus") { Array(xs) => xs.length(); _ => 0 })),
        ("cpuModel", match jfield(m, "cpus") { Array([c, ..]) => jfield(c, "model"); _ => Json::null() }),
        ("loadAvg", jfield(m, "loadavg")),
        ("memory", jobj_of([("totalBytes", jn(total)), ("usedBytes", jn(total - free)), ("known", jb(total > 0.0))])),
        ("disk", jobj_of([("path", jstr(bus.data)), ("totalBytes", jn(dtotal)), ("freeBytes", jn(dfree))])),
        ("checkedAt", jn(wall_ms().to_double())),
      ])
    },
    async fn() { self.gpus_now() },
    async fn() { self.recent_busy() },
    () => {
      let running = bus.store.running_jobs() catch { _ => Json::null() }
      running
    },
    () => (bus.mesh_net_info.val)(),
  )
}

///|
/// A body's bytes, read where it is a file's piece.
async fn p53_body_bytes(host : @host.Host, b : @jobs_host.Body) -> Bytes {
  match b {
    Data(d) => d
    File(path, offset, size) => {
      let out = @buffer.Buffer()
      let mut at = offset
      while at < offset + size {
        let n = if offset + size - at > 1048576.0 { 1048576 } else { (offset + size - at).to_int() }
        let piece = match host.shell("fs.bytes", { "path": jstr(path), "from": jn(at), "length": ji(n) }) {
          (String(h), _) => unhex_lenient(h)
          (_, Some(raw)) => raw
          _ => b""
        }
        if piece.length() == 0 {
          break
        }
        out.write_bytes(piece)
        at += piece.length().to_double()
      }
      out.to_bytes()
    }
  }
}

// ── the agents' tools (tools/remote.ts) ──

///|
fn P53Remote::tools(self : P53Remote) -> Array[PartTool] {
  let bus = self.bus
  let run = (name : String) => async fn(session : String, args : Json) -> String {
    jpretty(self.program.call(p53_remote_key, "tool", [jstr(name), jstr(session), args]))
  }
  let s = (d : String?) => match d {
    Some(text) => jobj_of([("type", jstr("string")), ("description", jstr(text))])
    None => jobj_of([("type", jstr("string"))])
  }
  [
    p53_tool(
      bus,
      "station_list",
      "List the stations of this workspace, and this station's sandboxes, with how busy each is and what it has (cores, arch/OS, GPU, CPU busy, load, free memory and disk, what it runs, relay ping), to pick where station_task runs. There are no locks between agents: never wait for, ask for or announce one; start the task and the station queues it when it must. One with mode: \"tasks\" only runs tasks and is its owner's: where it says this chat may not use it (thisChat), ask with station_use. One listed unprotected cannot be called from here and says why: not a bug, tell the person. unanswered is not offline; version_seen is an old copy. Skill stillfail-jobs (Another station) says how to choose.",
      jobj_of([
        ("type", jstr("object")),
        ("properties", jobj_of([("station", s(Some("One station, in detail, with whether it accepts tasks and its file limits.")))])),
        ("additionalProperties", jb(false)),
      ]),
      run("station_list"),
    ),
    p53_tool(
      bus,
      "station_task",
      "Run a shell task on another station of this workspace, or in a sandbox of this station's (station_list lists both). action prepare records command and name under a key you choose; upload inputs with station_file; action start runs it once, queued there when it must be, and you are told here when it ends. After an uncertain answer use the same key again; a new key is new work. On a station it runs as that station's OS user, not confined. All tasks of this session there share one directory, removed with anything still running when this chat is archived or deleted, or after 14 days unused: bring back what must last. With dir, each start first syncs that directory to a mirror there and runs the command in it; when start answers syncing: true, call start again with the same key. action clean deletes a mirror with everything in it, results not brought back included. Skill stillfail-jobs (Another station) says the rest: the queue, the screen, small tasks, mirrors, what comes back.",
      jobj_of([
        ("type", jstr("object")),
        (
          "properties",
          jobj_of([
            ("station", s(None)),
            ("key", s(None)),
            (
              "action",
              jobj_of([
                ("enum", Json::array(["prepare", "start", "get", "log", "stop", "release", "list", "mirrors", "clean"].map(jstr))),
                ("description", jstr("get, log (lines) and stop address the task of key. release, on a task some of whose results could not be saved, lets another task use its mirror: keep them with station_file first. list and mirrors need only station; clean, station and mirror.")),
              ]),
            ),
            ("mirror", s(Some("Name returned by action mirrors; action clean removes this one mirror."))),
            ("command", s(None)),
            ("name", s(None)),
            ("lines", jobj_of([("type", jstr("integer"))])),
            ("dir", s(Some("prepare: an absolute path of a directory here, synced before each start (what Git tracks or would add, only what changed)."))),
            ("back", jobj_of([("type", jstr("array")), ("items", jobj_of([("type", jstr("string"))])), ("description", jstr("prepare: paths relative to where the command runs, downloaded when it ends into station-back/<key> of this workspace (removed once nothing in it changed for 6 hours: move what you keep)."))])),
            ("screen", jobj_of([("type", jstr("boolean")), ("description", jstr("prepare: the task has the screen (windows, simulators) from start to end. For one command of it, run that as `stillfail-job screen <command>` instead."))])),
            ("small", jobj_of([("type", jstr("boolean")), ("description", jstr("A brief one-CPU offscreen task (not a build, test suite, video or screen work)."))])),
          ]),
        ),
        ("required", Json::array([jstr("station"), jstr("action")])),
        ("additionalProperties", jb(false)),
      ]),
      run("station_task"),
    ),
    p53_tool(
      bus,
      "station_file",
      "Upload an input before starting a remote task, or download a task artifact to this session. path is relative to this session's directory on that station; local is a path in this session workspace. Files are transferred in chunks, up to 1 GiB each; repeat upload after a disconnect. Downloads never overwrite an existing local file. Post downloaded artifacts using chat_post files.",
      jobj_of([
        ("type", jstr("object")),
        (
          "properties",
          jobj_of([
            ("station", s(None)),
            ("key", s(None)),
            ("direction", jobj_of([("enum", Json::array([jstr("upload"), jstr("download")]))])),
            ("path", s(None)),
            ("local", s(None)),
          ]),
        ),
        ("required", Json::array(["station", "key", "direction", "path", "local"].map(jstr))),
        ("additionalProperties", jb(false)),
      ]),
      run("station_file"),
    ),
  ]
}

///|
/// remote.ts `usedPath`: the record of which stations of its workspace a session ran tasks on.
fn P53Remote::used_path(self : P53Remote, session : String) -> String {
  @nodepath.join(sep(), [self.root, "used", "\{@jobs_host.remote_hash(jstr(session))}.json"])
}

///|
/// remote.ts `workspace`: the workspace a session's tasks go in, its chat's (the home one where none), while the
/// station is in it.
fn P53Remote::workspace_of(self : P53Remote, own : String?) -> String raise P53Error {
  let state = bus_cloud(self.bus)
  if state is Null {
    raise P53Error("station has no workspace")
  }
  if !(jfield(state, "removed_at") is Null) {
    raise P53Error("station was removed from workspace")
  }
  let home = jtext_or_empty(state, "workspace")
  if home == "" {
    raise P53Error("station has no workspace")
  }
  let ws = own.unwrap_or(home)
  let joined = match jfield(state, "joined") {
    Array(xs) => xs.iter().any(j => jtext_or_empty(j, "workspace") == ws)
    _ => false
  }
  if ws != home && !joined {
    raise P53Error("station is no longer in this chat's workspace")
  }
  ws
}

///|
/// remote.ts `workspaceTargets`: the stations on which a session has a remote workspace, within the workspace it is
/// still in (None: none).
async fn P53Remote::workspace_targets(self : P53Remote, session : String) -> (String, Array[String])? {
  let row = bus_session_row(self.bus, session)
  if row is Null || !(jfield(row, "archivedAt") is Null) {
    return None
  }
  let workspace = self.workspace_of(jtext(row, "ws")) catch { _ => return None }
  let path = self.used_path(session)
  let record = match self.used.get(path) {
    Some(r) => r
    None if self.used_ready => Json::null()
    None =>
      match shell_read_text(self.bus.host, path) {
        Some(t) => (try { Ok(@json.parse(t)) } catch { e => Err(e) }).unwrap_or(Json::null())
        None => Json::null()
      }
  }
  if record is Null || jtrue(record, "closing") || jtext_or_empty(record, "workspace") != workspace {
    return None
  }
  guard jfield(record, "stations") is Array(xs) else { return None }
  Some((workspace, xs.filter_map(x => if x is String(st) && st != "" { Some(st) } else { None })))
}

///|
/// remote.ts `workspaceStation`: only a station this chat has used; the empty id names its own.
async fn P53Remote::workspace_station(self : P53Remote, session : String, named : String) -> String {
  if bus_session_row(self.bus, session) is Null {
    raise P53Error("unknown session")
  }
  let own = bus_station_id(self.bus)
  if named == "" || named == own {
    return ""
  }
  guard self.workspace_targets(session) is Some((workspace, stations)) else {
    raise P53Error("this chat has no remote workspace on that station")
  }
  let station = if stations.contains(named) {
    named
  } else {
    let roster = (try { Ok(self.roster(workspace)) } catch { e => Err(e) }).to_option()
    @jobs_host.station_named(named, self.sandboxes().map(d => d.name), roster) catch {
      e => raise P53Error(p53_words(e))
    }
  }
  if station == own {
    return ""
  }
  if !stations.contains(station) {
    raise P53Error("this chat has no remote workspace on that station")
  }
  station
}
