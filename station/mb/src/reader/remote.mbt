// Tasks of other stations of the workspace run here, and this station's sessions' tasks there (station/src/jobs/
// remote.ts `Remote`, the pseudo-actor `#remote` of the sessions' program): what is asked of a task here (task.*,
// sync.*, file.*, session.*), each source session's requests one after another (`lane`); what follows a task started
// from here (`check`, `settle`) and what tells a source of one here (`push_out`); the target's own cleanup (`sweep`,
// `relieve`); the station_* tools. The records are the Rust's files (remote/incoming/<id>/task.json,
// sessions/<id>/session.json, outgoing/<id>.json, prepared/...), written as it wrote them (remote_files.mbt).
// Node keeps what is the transport's and the machine's, which this asks of it (`rnode`): the requests to and from the
// other stations (the bus, a sandbox's), the bytes that go with them (a directory sync's packed requests, which this
// has the shell pack: dirsync_source.mbt), the folders macOS protects, the load, the cloud's state, a room's use and
// size. The chats' use records (remote/used/<id>.json) are this program's (remote_source.mbt `record_use`), Node told
// each as it changes (`used`) for what it reads at once.

///|
priv struct SyncRun {
  key : String
  result : @effect.Deferred[Json]
  mut ended_at : Double?
}

///|
priv struct RemoteState {
  writing : Map[String, @effect.Deferred[Unit]]
  writes : Map[String, Int]
  used : Map[String, Json]
  lanes : Map[String, @effect.Semaphore]
  checking : Map[String, Bool]
  pushing : Map[String, Bool]
  syncs : Map[String, SyncRun]
  cleans : Map[String, SyncRun]
  task_owners : Map[String, String]
  owner_tasks : Map[String, Map[String, Bool]]
  unreadable : Map[String, Bool]
  /// the closing sessions' use records whose stations are being asked to remove their directories (`closer`)
  closing : Map[String, Bool]
  /// while a pass holds remote/sessions to its budget (`budget`): the bytes it is over by yet
  mut over : Double
  mut incoming_stamp : String?
  mut indexing : @effect.Deferred[Unit]?
  mut root : String
  mut stopped : Bool
}

///|
fn RemoteState::new() -> RemoteState {
  {
    writing: Map([]),
    writes: Map([]),
    used: Map([]),
    lanes: Map([]),
    checking: Map([]),
    pushing: Map([]),
    syncs: Map([]),
    cleans: Map([]),
    task_owners: Map([]),
    owner_tasks: Map([]),
    unreadable: Map([]),
    closing: Map([]),
    over: 0.0,
    incoming_stamp: None,
    indexing: None,
    root: "",
    stopped: false,
  }
}

///|
let remote_key : String = "#remote"

///|
let idle_ms : Double = 14.0 * 24.0 * 3600.0 * 1000.0

///|
let give_up_ms : Double = 600000.0

///|
let mirror_idle_ms : Double = 24.0 * 3600.0 * 1000.0

///|
let mirror_recent_ms : Double = 3600000.0

///|
let sync_answer_ms : Double = 40000.0

///|
let sync_kept_ms : Double = 600000.0

///|
let clean_answer_ms : Double = 1000.0

///|
let clean_kept_ms : Double = 600000.0

///|
let gets_max : Int = 200

///|
let max_file : Double = 1073741824.0

///|
let chunk_bytes : Int = 262144

///|
let sweep_every_ms : Double = 3600000.0

///|
let reads : Array[String] = ["task.get", "task.gets", "task.log", "task.list", "session.size"]

///|
async fn Actors::rnode(self : Actors, f : String, args : Array[Json]) -> Json raise {
  self.rpc(remote_key, "node." + f, args)
}

///|
async fn Actors::rstore(self : Actors, f : String, args : Array[Json]) -> Json raise {
  self.rpc(remote_key, "store." + f, args)
}

///|
fn Actors::rlog(self : Actors, level : String, message : String, fields? : Map[String, Json] = {}) -> Unit {
  self.tell(remote_key, "log", [jstr(level), jstr(message), Json::object(fields)])
}

///|
/// A request to another station (the bus's, a sandbox's: Node's).
async fn Actors::ask(self : Actors, station : String, request : Json) -> Json raise {
  self.rnode("ask", [jstr(station), request])
}

///|
/// Whether `e` is a station's answered refusal (bus.ts `Refused`): final, unlike a request that did not get through.
fn refused(e : Error) -> Bool {
  match e {
    Asked(j) => j.value("kind") is Some(String("Refused"))
    _ => false
  }
}

///|
fn text_of(v : Json, key : String) -> String {
  match v.value(key) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn field_of(v : Json, key : String) -> Json {
  match v {
    Object(m) => m.get(key).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
fn bytes_len(s : String) -> Int {
  @replica.utf8_length(s)
}

///|
/// serde_json's as_u64.
fn as_u64(v : Json) -> Double? {
  match v {
    Number(n, ..) if n >= 0.0 && n == n.floor() => Some(n)
    _ => None
  }
}

///|
fn as_i64(v : Json) -> Double? {
  match v {
    Number(n, ..) if n == n.floor() => Some(n)
    _ => None
  }
}

///|
fn with_field(v : Json, key : String, value : Json) -> Json {
  let m : Map[String, Json] = match v {
    Object(m) => m.copy()
    _ => {}
  }
  m[key] = value
  Json::object(m)
}

///|
/// `f` after what was asked before it in `lane` (a source session's: its room).
async fn[X] Actors::in_lane(self : Actors, lane : String, f : async () -> X raise) -> X raise {
  let s = match self.remote.lanes.get(lane) {
    Some(s) => s
    None => {
      let s = @effect.Semaphore::new(1)
      self.remote.lanes[lane] = s
      s
    }
  }
  s.acquire()
  defer s.release()
  f()
}

///|
fn Actors::room(self : Actors, workspace : String, peer : String, session : String) -> String {
  self.rjoin([self.remote.root, "sessions", rhash(Json::array([jstr(workspace), jstr(peer), jstr(session)]))])
}

///|
/// A source session's shared directory, made and noted as used (Node's, as vault/secrets.ts asks it at once), its
/// record written here when Node says it is to be (at most once a minute).
async fn Actors::seen(self : Actors, workspace : String, peer : String, session : String) -> String raise {
  let got = self.rnode("seen", [jstr(workspace), jstr(peer), jstr(session)])
  if field_of(got, "write") is True {
    self.write_session(workspace, peer, session, field_of(got, "now"))
  }
  text_of(got, "work")
}

///|
/// A source session's room's record (sessions/<id>/session.json): used at `seen`. One not written is let go, as before.
async fn Actors::write_session(self : Actors, workspace : String, peer : String, session : String, seen : Json) -> Unit {
  let record = self.rjoin([self.room(workspace, peer, session), "session.json"])
  self.write_json(record, { "workspace": jstr(workspace), "station": jstr(peer), "session": jstr(session), "seen": seen }) catch {
    _ => ()
  }
}

///|
fn Actors::job_of_task(self : Actors, dir : String) -> String {
  "remote_" + self.rbasename(dir)
}

///|
async fn Actors::task_running(self : Actors, dir : String) -> Bool raise {
  let job = self.rstore("getJob", [jstr(self.job_of_task(dir))])
  str_of(job.value("state")) == Some("running")
}

// ── what Node asks ──

///|
async fn Actors::remote_called(self : Actors, method : String, args : Array[Json]) -> Json raise {
  let arg = (i : Int) => if i < args.length() { args[i] } else { Json::null() }
  match method {
    "start" => {
      self.remote.root = str_of(Some(arg(0))).unwrap_or("")
      self.spawn(() => self.load_used())
      Json::null()
    }
    "attached" => {
      self.spawn(() => try { self.resume() } catch { _ => () })
      self.spawn(() => try { self.push_missed() } catch { _ => () })
      self.spawn(() => try { self.resume_closing() } catch { _ => () })
      self.spawn(() => try { self.move_prepared() } catch { _ => () })
      self.sweep_hourly()
      Json::null()
    }
    "recordUse" =>
      self.record_use(str_of(Some(arg(0))).unwrap_or(""), str_of(Some(arg(1))).unwrap_or(""), str_of(Some(arg(2))).unwrap_or(""))
    "closeSession" => self.close_session(str_of(Some(arg(0))).unwrap_or(""), num_of(Some(arg(1))).unwrap_or(0.0))
    "writeSession" => {
      self.write_session(str_of(Some(arg(0))).unwrap_or(""), str_of(Some(arg(1))).unwrap_or(""), str_of(Some(arg(2))).unwrap_or(""), arg(3))
      Json::null()
    }
    "movePrepared" => {
      self.move_prepared()
      Json::null()
    }
    "expire" => jnum(self.expire(num_of(Some(arg(0))).unwrap_or(0.0)).to_double())
    "budget" => jnum(self.budget(num_of(Some(arg(0))).unwrap_or(0.0), num_of(Some(arg(1))).unwrap_or(0.0)))
    "handle" => {
      let workspace = str_of(Some(arg(0))).unwrap_or("")
      let peer = str_of(Some(arg(1))).unwrap_or("")
      let request = arg(2)
      let method = text_of(request, "method")
      let room_peer = room_peer_of(peer, request)
      if method == "task.clean" {
        self.clean_request(workspace, peer, request)
      } else if reads.contains(method) {
        self.task(workspace, peer, method, request, None)
      } else {
        self.in_lane(self.room(workspace, room_peer, text_of(request, "session")), () => self.task(workspace, peer, method, request, None))
      }
    }
    "changed" => self.changed_there(str_of(Some(arg(0))).unwrap_or(""), arg(1))
    "pushOut" => {
      self.push_out(str_of(Some(arg(0))).unwrap_or(""))
      Json::null()
    }
    "sweep" => {
      self.sweep(num_of(Some(arg(0))).unwrap_or(0.0))
      Json::null()
    }
    "relieve" => {
      self.relieve(num_of(Some(arg(0))).unwrap_or(0.0))
      Json::null()
    }
    "revoke" => {
      self.revoke(arg(0), truthy(arg(1)))
      Json::null()
    }
    // (what a directory sync would send of `dir`: the tests compare it with what the TypeScript listed)
    "listLocal" => self.list_local(str_of(Some(arg(0))).unwrap_or("")).to_json()
    "tool" => self.tool(str_of(Some(arg(0))).unwrap_or(""), str_of(Some(arg(1))).unwrap_or(""), arg(2))
    "close" => {
      self.remote.stopped = true
      Json::null()
    }
    _ => raise Asked({ "message": jstr("no remote method \{method}") })
  }
}

///|
/// The target's sweep, now and hourly (on Node's clock).
fn Actors::sweep_hourly(self : Actors) -> Unit {
  self.spawn(() => {
    if self.remote.stopped {
      return
    }
    try {
      let now = self.remote_now()
      self.sweep(now)
    } catch {
      _ => ()
    }
    ignore(self.rafter(sweep_every_ms, () => self.sweep_hourly()))
  })
}

///|
/// `once` now and, until it says it is over, again after 1 s, then twice as long each time, a minute apart at most
/// (remote.ts `AGAIN`); `ended` with whether the last said so.
fn Actors::again(self : Actors, once : async () -> Bool, ended : (Bool) -> Unit, tries? : Int = 0) -> Unit {
  self.spawn(() => {
    let over = once()
    if over || self.remote.stopped {
      ended(over)
      return
    }
    let mut wait = 1000.0
    for i = 0; i < tries && wait < 60000.0; i = i + 1 {
      wait = wait * 2.0
    }
    ignore(self.rafter(if wait > 60000.0 { 60000.0 } else { wait }, () => self.again(once, ended, tries=tries + 1)))
  })
}

// ── the target: a source's requests ──

///|
/// Room/lane peer key: isolates remote sandbox tasks (`<peer>:sandbox:<name>`) from ordinary remote shell tasks.
fn room_peer_of(peer : String, request : Json) -> String {
  let sb = text_of(request, "sandbox")
  if sb != "" { "\{peer}:sandbox:\{sb}" } else { peer }
}

///|
/// A removal holds the session's lane while it runs; the transport answers early and a retry joins the same work.
async fn Actors::clean_request(self : Actors, workspace : String, peer : String, request : Json) -> Json raise {
  let session = text_of(request, "session")
  let mirror = text_of(request, "mirror")
  let room_peer = room_peer_of(peer, request)
  let id = rhash(Json::array([jstr(workspace), jstr(room_peer), jstr(session), jstr(mirror)]))
  let now = self.remote_now()
  let gone = self.remote.cleans.to_array().filter(e => e.1.ended_at is Some(at) && now - at >= clean_kept_ms).map(e => e.0)
  for k in gone {
    self.remote.cleans.remove(k)
  }
  let clean = match self.remote.cleans.get(id) {
    Some(c) => c
    None => {
      let c : SyncRun = { key: id, result: @effect.Deferred::new(), ended_at: None }
      self.remote.cleans[id] = c
      self.spawn(() => {
        let got : Json = try {
          { "ok": self.in_lane(self.room(workspace, room_peer, session), () => self.task(workspace, peer, "task.clean", request, None)) }
        } catch {
          e => ({ "error": jstr(FsError::of(e)) } : Json)
        }
        let at = self.remote_now() catch { _ => 0.0 }
        c.ended_at = Some(at)
        ignore(c.result.succeed(got))
      })
      c
    }
  }
  guard self.bounded(clean.result, clean_answer_ms) is Some(got) else { return { "mirror": jstr(mirror), "pending": jbool(true) } }
  if self.remote.cleans.get(id) is Some(now) && physical_equal(now, clean) {
    self.remote.cleans.remove(id)
  }
  match got {
    { "error": String(m), .. } => raise Asked({ "message": jstr(m) })
    _ => got.value("ok").unwrap_or(Json::null())
  }
}

///|
/// What `d` settles to, or None when it has not within `ms` on Node's clock (it goes on).
async fn[X] Actors::bounded(self : Actors, d : @effect.Deferred[X], ms : Double) -> X? {
  if d.is_done() {
    return d.poll() catch { _ => None }
  }
  let woke : @effect.Deferred[Unit] = @effect.Deferred::new()
  let cancel = self.rafter(ms, () => {
    if !woke.is_done() {
      self.active += 1
      ignore(woke.succeed(()))
    }
  })
  self.spawn(() => {
    ignore(d.wait()) catch { _ => () }
    if !woke.is_done() {
      self.active += 1
      ignore(woke.succeed(()))
    }
  })
  self.active -= 1
  woke.wait() catch { _ => () }
  cancel()
  if d.is_done() {
    d.poll() catch { _ => None }
  } else {
    None
  }
}

///|
/// A wait of the remote tasks', on their clock (Node's `Remote`'s, which may not be the hub's: a test's own).
fn Actors::rafter(self : Actors, ms : Double, then : () -> Unit) -> () -> Unit {
  self.after(ms, then, on=remote_key)
}

///|
/// Now on the remote tasks' clock (their store's).
async fn Actors::remote_now(self : Actors) -> Double raise {
  num_of(Some(self.rstore("now", []))).unwrap_or(self.now)
}
