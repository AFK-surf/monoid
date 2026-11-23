// The station's background jobs (station/src/jobs/jobs.ts `Jobs`): what they are and do (a start's checks, the queue
// for other stations' tasks and the screen, an end told and a service started again, a stop, a restart's taking up) is
// the sessions' program's (station/mb/src/reader/jobs.mbt, the pseudo-actor `#jobs` of live_p5_3_program.mbt's
// program), as under the TypeScript station. This is what of them is the machine's, which the program asks for
// (`node.*`, its `store.*` answered by `bus.store`): a command started in a process group of its own (sys.mbt `spawn`)
// and followed to its end (`@jobs_host.JobsHost`), a signal, a log, the memory's pressure and a person at the machine;
// and what the station asks of them said to the program: the agents' tools (tools/jobs.ts: job_start, job_list,
// job_log, job_stop), `stillfail-job`'s places on the agents' door (`/jobs/notify`, `/jobs/screen`), a service's
// readiness and its preview through the door (`/preview/<port>/…`, jobs/preview.ts), a session's jobs stopped as it
// ends and the jobs taken up once the door is open.

///|
/// What the program knows the jobs' shell by.
let p53_jobs_key : String = "#jobs"

///|
/// How long a service's port is looked at for its first answer (its readiness), and how often.
let p53_ready_ms : Int = 30000

///|
let p53_ready_every_ms : Int = 250

///|
priv struct P53Jobs {
  bus : LiveBus
  program : P53Program
  machine : @jobs_host.JobsHost
  /// The services whose port answered since they last started.
  ready : Map[String, Bool]
  /// The groups this process started or took up, by job (what a service's readiness follows).
  groups : Map[String, Int]
  /// Who hears that a remote task's job changed (the remote tasks, which tell its source).
  remote_heard : Array[(String) -> Unit]
  mut closing : Bool
  mut relaunched : Bool
}

///|
/// The machine's processes as the jobs ask them: through sys.mbt's `kill` and `pid_alive`, a process's start as the
/// system says it (ms since the epoch, as `processes.started_at` keeps it: `JobsHost::still_ours` compares the two).
fn p53_processes(host : @host.Host) -> @jobs_host.Processes {
  ignore(host)
  {
    signal_group: async fn(pgid, signal) { ignore(kill(pgid, signal, group=true)) },
    group_alive: async fn(pgid) { group_alive(pgid) },
    pid_alive: async fn(pid) { pid_alive(pid) },
    start_time: async fn(pid) { start_time_of(pid) },
  }
}

///|
async fn P53Jobs::new(bus : LiveBus, program : P53Program) -> P53Jobs {
  let machine = @jobs_host.JobsHost::new(bus.host, bus.data, procs=p53_processes(bus.host), now=() => bus.store.now().to_double())
  let jobs : P53Jobs = { bus, program, machine, ready: Map([]), groups: Map([]), remote_heard: [], closing: false, relaunched: false }
  // (a job's end said to the program, which takes it in: its record, its agent told, a service started again; what it
  // left running in its group then made to end by the machine's side, and its log held to its bound)
  machine.on_ended(async fn(id, pgid, code, ran) {
    jobs.ready.remove(id)
    if jobs.groups.get(id) == Some(pgid) {
      jobs.groups.remove(id)
    }
    ignore(program.call(p53_jobs_key, "exited", [jstr(id), ji(pgid), match code { Some(c) => jn(c); None => Json::null() }, jn(ran)])) catch {
      e => slice_log("warn", "jobs", "a job's end not taken in", jobj_of([("job", jstr(id)), ("error", jstr(p53_words(e)))]))
    }
    let job = jobs.get(id)
    if !(job is Null) {
      ignore(machine.cap_log(jtext_or_empty(job, "log")))
    }
  })
  program.shell(p53_jobs_key, { asked: async fn(f, args) { jobs.asked(f, args) }, told: (f, args) => jobs.told(f, args) })
  // (the claims an earlier station left holding the screen: theirs still)
  ignore(program.call(p53_jobs_key, "claims", [machine.held_claims()])) catch { _ => () }
  jobs
}

///|
fn P53Jobs::store(self : P53Jobs) -> @store_sessions.Store {
  self.bus.store
}

///|
fn P53Jobs::now(self : P53Jobs) -> Double {
  self.bus.store.now().to_double()
}

///|
fn P53Jobs::get(self : P53Jobs, id : String) -> Json {
  self.store().get_job(jstr(id)) catch {
    _ => Json::null()
  }
}

///|
/// What the program asks of the station for its jobs (jobs.ts `asked`).
async fn P53Jobs::asked(self : P53Jobs, f : String, args : Array[Json]) -> Json {
  let host = self.bus.host
  if f.has_prefix("store.") {
    return dispatch_store(self.bus, f[6:].to_owned(), args)
  }
  let a = (i : Int) => arg_at(args, i)
  let s = (i : Int) => arg_str(args, i)
  match f {
    "node.isDir" => jb(host_is_dir(host, s(0)))
    "node.newJob" => self.made(s(0), s(1), s(2), s(3), a(4), a(5) is True, a(6), a(7), a(8))
    "node.spawn" => {
      let extra : Map[String, String] = Map([])
      match a(2) {
        Object(m) => for kk, v in m { if v is String(t) { extra[kk] = t } }
        _ => ()
      }
      ji(self.spawn_job(self.get(s(0)), a(1) is True, extra))
    }
    "node.notify" => {
      self.tell_session(s(0), s(1))
      Json::null()
    }
    "node.remoteChanged" => {
      self.remote_changed(s(0))
      Json::null()
    }
    "node.pressure" => jopt(p53_pressure(host))
    "node.inputIdle" =>
      (p53_input_idle(host)).map(jn).unwrap_or(Json::null())
    "node.pidAlive" => jb(pid_alive(arg_int(args, 0)))
    "node.keepClaims" => {
      self.machine.keep_claims(a(0))
      Json::null()
    }
    "node.tail" => jstr(@jobs_host.tail(host, s(0), arg_int(args, 1)))
    "node.lost" => jb(host_exists(host, self.machine.lost_file(s(0))))
    "node.append" => {
      p53_append(host, s(0), s(1))
      Json::null()
    }
    "node.signal" => {
      ignore(kill(arg_int(args, 0), s(1), group=true))
      Json::null()
    }
    "node.grace" => {
      self.machine.grace(s(0))
      Json::null()
    }
    "node.endLeftBehind" => {
      let pgid = arg_int(args, 0)
      if !self.machine.follows(pgid) {
        let entry = self.store().process_by_group(ji(pgid))
        if jtext(entry, "runtime") == Some("job") {
          if self.machine.still_ours(pgid, jnum_of(entry, "startedAt").unwrap_or(0.0)) {
            slice_log("warn", "jobs", "ending a job an earlier station left running", jobj_of([("job", a(1)), ("pgid", ji(pgid))]))
            self.machine.end_group(pgid, @jobs_host.stop_grace_ms)
          }
          self.store().forget_process(ji(pgid))
        }
      }
      Json::null()
    }
    "node.recordedGroups" => {
      let out = []
      for p in self.store().list_processes() {
        if jtext(p, "runtime") != Some("job") {
          continue
        }
        let g = jnum_of(p, "pgid").unwrap_or(0.0).to_int()
        let ours = self.machine.still_ours(g, jnum_of(p, "startedAt").unwrap_or(0.0))
        out.push(jobj_of([("pgid", ji(g)), ("label", jfield(p, "label")), ("ours", jb(ours))]))
      }
      Json::array(out)
    }
    "node.follow" => {
      let id = s(0)
      let pgid = arg_int(args, 1)
      let job = self.get(id)
      let now = self.now()
      let started = jnum_of(job, "startedAt").unwrap_or(now)
      self.machine.follow(id, pgid, now - (if now - started > 0.0 { now - started } else { 0.0 }))
      self.groups[id] = pgid
      if jnum_of(job, "port") is Some(p) { self.watch_ready(id, pgid, p.to_int()) }
      Json::null()
    }
    "node.readExit" =>
      (self.machine.read_exit(s(0))).map(jn).unwrap_or(Json::null())
    _ => raise P53Error("no jobs' ask \{f}")
  }
}

///|
/// What the program tells the station of its jobs, needing no answer.
fn P53Jobs::told(self : P53Jobs, f : String, args : Array[Json]) -> Unit {
  match f {
    "log" => slice_log(arg_str(args, 0), "jobs", arg_str(args, 1), arg_at(args, 2))
    "node.endGroup" => {
      let pgid = arg_int(args, 0)
      fork_bg(self.bus.host, "a group left behind", async fn() { self.machine.end_group(pgid, @jobs_host.stop_grace_ms) })
    }
    _ => ()
  }
}

///|
/// A job's record, made and kept (jobs.ts `made`): what the program checked it may be.
fn P53Jobs::made(
  self : P53Jobs,
  session : String,
  name : String,
  command : String,
  cwd : String,
  port : Json,
  watch : Bool,
  id : Json,
  queue : Json,
  sandbox : Json,
) -> Json raise {
  let job_id = match id {
    String(i) => i
    _ => "job_\{@drive.hex(@drive.random_bytes(4))}"
  }
  let fields : Array[(String, Json)] = [
    ("log", jstr(@nodepath.join(sep(), [self.machine.dir, "logs", "\{job_id}.log"]))),
    ("id", jstr(job_id)),
    ("sessionKey", jstr(session)),
    ("name", jstr(@jobs_host.shown_name(name, command))),
    ("command", jstr(command)),
    ("cwd", jstr(cwd)),
    ("port", port),
    ("token", jstr(@drive.hex(@drive.random_bytes(16)))),
    ("state", jstr("running")),
    ("pgid", Json::null()),
    ("exitCode", Json::null()),
    ("startedAt", jn(self.now())),
    ("endedAt", Json::null()),
    ("restarts", ji(0)),
    ("watch", jb(watch)),
  ]
  if !(queue is Null) {
    fields.push(("queued", jb(true)))
    fields.push(("screen", jb(jtrue(queue, "screen"))))
    if jtrue(queue, "small") {
      fields.push(("small", jb(true)))
    }
  }
  if !(sandbox is Null) {
    fields.push(("sandbox", sandbox))
  }
  let job = jobj_of(fields)
  self.store().insert_job(job)
  job
}

///|
/// jobs.ts `spawn`: its command run in a group of its own, its group recorded and followed to its end (told to the
/// program, `exited`); a service's port looked at for its first answer. Its group.
async fn P53Jobs::spawn_job(self : P53Jobs, job : Json, restarted : Bool, extra : Map[String, String]) -> Int {
  if job is Null {
    raise P53Error("no such job")
  }
  let id = jtext_or_empty(job, "id")
  let start = @jobs_host.JobStart::from_json(job)
  let pgid = match jfield(job, "sandbox") {
    Null => self.launch(start, extra)
    place => self.launch_in_sandbox(start, place)
  }
  let now = self.now()
  self.store().record_process(ji(pgid), jn(now), jstr("job"), jstr("job: \{jtext_or_empty(job, "name")}"))
  self.store().job_started(jstr(id), ji(pgid), restarted)
  if !restarted && jtext_or_empty(job, "sessionKey").has_prefix("remote:") {
    self.store().note_remote_run(jstr(id), jfield(job, "sessionKey"), now)
  }
  self.groups[id] = pgid
  self.ready.remove(id)
  if start.port is Some(p) {
    self.watch_ready(id, pgid, p.to_int())
  }
  pgid
}

///|
/// A sandbox's task (agents/sandbox.ts): its command run there through the bridge, which the shell here runs in its
/// place (this program as `<…>/sandbox-bridge.mjs host '<json>'`: live_p5_3_sandbox.mbt): its output comes back to the
/// log here, its exit code to the exit file here.
async fn P53Jobs::launch_in_sandbox(self : P53Jobs, job : @jobs_host.JobStart, place : Json) -> Int {
  let name = jtext_or_empty(place, "sandbox")
  let workspace = jtext(place, "workspace")
  guard p53_sandboxes(self.bus, workspace~).iter().find_first(d => d.name == name) is Some(sandbox) else {
    raise P53Error("no sandbox \{name} in this station's config.json any more")
  }
  guard p53_bridge_file(self.bus) is Some(bridge) else {
    raise P53Error("sandbox \{name}: the bridge (sandbox-bridge.mjs) is not beside this station's program")
  }
  let notify = self.machine.job_env(job, Map([]), "").get("STILLFAIL_JOB_NOTIFY").unwrap_or("")
  let door = p53_port_of(notify)
  let back = match jfield(place, "back") {
    Array(xs) => xs.filter_map(x => if x is String(b) { Some(b) } else { None })
    _ => []
  }
  let (node, colab_script, accounts) = if @agent_runtimes.is_colab(sandbox) {
    guard p53_colab_file(self.bus) is Some(script) else {
      raise P53Error("sandbox \{name}: colab-sandbox.mjs is not beside this station's program")
    }
    (p53_node_program(self.bus), script, p53_colab_accounts(self.bus, workspace~))
  } else {
    (reader_program(self.bus), "", [])
  }
  let command = @agent_runtimes.sandbox_command(
    self.bus.data,
    sandbox,
    { sandbox: name, session: jtext_or_empty(place, "session"), back, workspace },
    job.command,
    job.cwd,
    if door > 0 { [door.to_double()] } else { [] },
    self.machine.lost_file(job.id),
    node,
    bridge,
    colab_script~,
    accounts~,
  )
  self.launch(job, Map([]), command~, sandboxed=true)
}

///|
/// The port of a loopback URL (`http://127.0.0.1:<port>/…`), 0 where it names none.
fn p53_port_of(url : String) -> Int {
  guard url.find("://") is Some(i) else { return 0 }
  let rest = url[i + 3:].to_string()
  let host_port = match rest.find("/") {
    Some(j) => rest[:j].to_string()
    None => rest
  }
  match host_port.rev_find(":") {
    Some(k) => (try { Ok(@string.parse_int(host_port[k + 1:].to_string())) } catch { e => Err(e) }).unwrap_or(0)
    None => 0
  }
}

///|
/// The sandboxes' bridge, beside this program as a release has it (`<app>/station/sandbox-bridge.mjs`) or in a checkout
/// (station/assets/agents/).
fn p53_bridge_file(bus : LiveBus) -> String? {
  let program = reader_program(bus)
  let here = @nodepath.dirname(sep(), program)
  let candidates = [
    @nodepath.join(sep(), [here, "sandbox-bridge.mjs"]),
    @nodepath.join(sep(), [bus.app, "station", "sandbox-bridge.mjs"]),
    @nodepath.join(sep(), [bus.app, "station", "dist", "sandbox-bridge.mjs"]),
    @nodepath.join(sep(), [here, "..", "..", "assets", "agents", "sandbox-bridge.mjs"]),
    @nodepath.join(sep(), [bus.app, "station", "assets", "agents", "sandbox-bridge.mjs"]),
  ]
  candidates.iter().find_first(f => (try { Ok(@drive.stat(f)) } catch { e => Err(e) }) is Ok({ file: true, .. }))
}

///|
/// The Colab sandboxes' runner (`colab-sandbox.mjs`), beside this program as a release has it or in a checkout.
async fn p53_colab_file(bus : LiveBus) -> String? {
  let program = reader_program(bus)
  let here = @nodepath.dirname(sep(), program)
  let candidates = [
    @nodepath.join(sep(), [here, "colab-sandbox.mjs"]),
    @nodepath.join(sep(), [bus.app, "station", "colab-sandbox.mjs"]),
    @nodepath.join(sep(), [bus.app, "station", "dist", "colab-sandbox.mjs"]),
    @nodepath.join(sep(), [here, "..", "..", "assets", "agents", "colab-sandbox.mjs"]),
    @nodepath.join(sep(), [bus.app, "station", "assets", "agents", "colab-sandbox.mjs"]),
  ]
  for f in candidates {
    if p53_file_is(bus.host, f) {
      return Some(f)
    }
  }
  None
}

///|
/// Finds a runnable Node binary: prefers `<data>/node/<ver>/bin/node` (or `node.exe` on Windows) installed by the
/// station, falling back to `resolved_program("node", None)` (PATH / system dirs) or bare `"node"`.
async fn p53_node_program(bus : LiveBus) -> String {
  let node_dir = @nodepath.join(sep(), [bus.data, "node"])
  let entries = match (try { Ok(bus.host.shell("fs.readdir", { "path": jstr(node_dir) })) } catch { e => Err(e) }) {
    Ok((Array(xs), _)) => xs.filter_map(x => if x is String(s) && !s.has_prefix(".") { Some(s) } else { None })
    _ => []
  }
  entries.sort_by((a, b) => b.compare(a))
  for ver in entries {
    let bin = if is_windows() {
      @nodepath.join(sep(), [node_dir, ver, "node.exe"])
    } else {
      @nodepath.join(sep(), [node_dir, ver, "bin", "node"])
    }
    if p53_file_is(bus.host, bin) {
      return bin
    }
  }
  resolved_program("node", None)
}

///|
/// jobs.ts `named`: how a job is named to its agent.
fn p53_named(job : Json) -> String {
  @jobs_host.job_named(jtext_or_empty(job, "id"), jtext_or_empty(job, "name"), jnum_of(job, "port"))
}

///|
/// What the agents' door's places, the tools and the session's end add to the station.
fn P53Jobs::attach(self : P53Jobs) -> Unit {
  let bus = self.bus
  bus.parts.tools(self.tools())
  bus.parts.door({
    prefix: "jobs",
    request: async fn(r, _conn) {
      let auth = r.header("authorization")
      match r.path() {
        "/jobs/notify" if r.meth == "POST" => {
          let (status, body) = @jobs_host.notify_endpoint(auth, r.body, async fn(token, text) { self.notified(token, text) })
          Some(json_reply(status, body))
        }
        "/jobs/screen" if r.meth == "POST" => {
          let (status, body) = @jobs_host.screen_endpoint(auth, r.body, async fn(token, ask, pid) {
            self.screen_asked(token, ask, pid.to_int())
          })
          Some(json_reply(status, body))
        }
        _ => Some(plain(404, ""))
      }
    },
  })
  // (a web service on this machine, through its preview's path: any method, its answer as it comes)
  bus.parts.door({ prefix: "preview", request: async fn(r, conn) { self.preview(r, conn) } })
  bus.parts.session_ended(session => {
    fork_bg(bus.host, "jobs of a session ended", async fn() { self.session_ended(session) })
  })
  bus.parts.routes([
    {
      meth: "GET",
      path: "/jobs",
      answer: async fn(r) {
        let out = []
        for j in self.list(jtext(jfield(r, "query"), "session")) {
          out.push(self.view(j))
        }
        Json::array(out)
      },
    },
    {
      meth: "GET",
      path: "/jobs/:id",
      answer: async fn(r) { self.shown(jtext_or_empty(jfield(r, "params"), "id")) },
    },
    {
      meth: "POST",
      path: "/jobs/:id/stop",
      answer: async fn(r) {
        let id = jtext_or_empty(jfield(r, "params"), "id")
        let job = self.stop(id)
        if self.awake(jtext_or_empty(job, "sessionKey")) {
          let who = match jtext(jfield(r, "viewer"), "name") {
            Some(n) if n != "" => n
            _ => "a member"
          }
          self.tell(job, "\{p53_named(job)} was stopped by \{who} from still.fail's page.")
        }
        self.view(job)
      },
    },
  ])
}

///|
/// The agents' door listens: where `stillfail-job notify` posts, then what still runs taken up (jobs.ts `relaunch`).
async fn P53Jobs::door_open(self : P53Jobs, url : String) -> Unit {
  let base = if url.has_suffix("/mcp") { url[:url.length() - 4].to_owned() } else { url }
  self.machine.set_notify_url("\{base}/jobs/notify")
  ignore(self.relaunch()) catch {
    e => slice_log("warn", "jobs", "the jobs were not taken up", jobj_of([("error", jstr(p53_words(e)))]))
  }
}

///|
/// What still runs followed again, what ended meanwhile told, what is gone run again: once a station (the hub's ask
/// and the door's open both come here).
async fn P53Jobs::relaunch(self : P53Jobs) -> Json {
  if self.relaunched {
    return Json::null()
  }
  self.relaunched = true
  let said = self.program.call(p53_jobs_key, "relaunch", [])
  slice_log("info", "jobs", "the jobs of before taken up", Json::object({}))
  said
}

///|
/// jobs.ts `startId`: a job for `session`; `id` a remote task's own, `queue` its place in the queue.
async fn P53Jobs::start(
  self : P53Jobs,
  session : String,
  name : String,
  command : String,
  cwd : String,
  port : Double?,
  watch : Bool,
  id : String?,
  checked : Bool,
  queue : Json,
) -> Map[String, Json] {
  let job = self.program.call(p53_jobs_key, "startId", [
    jstr(session),
    jstr(name),
    jstr(command),
    jstr(cwd),
    match port { Some(p) => jn(p); None => Json::null() },
    jb(watch),
    jopt(id),
    jb(checked),
    queue,
    Json::null(),
  ])
  match job {
    Object(m) => m
    _ => raise P53Error("the station is stopping")
  }
}

///|
/// jobs.ts `stop`: its group given its grace, then killed (the program's, asking the machine's side).
async fn P53Jobs::stop(self : P53Jobs, id : String) -> Json {
  let job = self.program.call(p53_jobs_key, "stop", [jstr(id)])
  if job is Null {
    self.get(id)
  } else {
    job
  }
}

///|
/// `stillfail-job notify`: the job with this token says something to its agent.
async fn P53Jobs::notified(self : P53Jobs, token : String, text : String) -> Unit {
  ignore(self.program.call(p53_jobs_key, "notified", [jstr(token), jstr(text)]))
}

///|
/// `stillfail-job screen`: a job's process asks for the screen or gives it back.
async fn P53Jobs::screen_asked(self : P53Jobs, token : String, ask : String, pid : Int) -> Json {
  self.program.call(p53_jobs_key, "screenAsked", [jstr(token), jstr(ask), ji(pid)])
}

///|
async fn P53Jobs::queue_of(self : P53Jobs, id : String) -> Json {
  self.program.call(p53_jobs_key, "queueOf", [jstr(id)])
}

///|
async fn P53Jobs::screen_holder(self : P53Jobs, except : String?) -> String? {
  as_text(self.program.call(p53_jobs_key, "screenHolder", [jopt(except)]))
}

///|
/// What the station's own look at the memory read (jobs/memory.ts): what the queue goes by as a task asks to start.
async fn P53Jobs::memory_seen(self : P53Jobs, pressure : String?) -> Unit {
  ignore(self.program.call(p53_jobs_key, "memorySeen", [jopt(pressure)]))
}

///|
/// jobs.ts `stopAll`: every job up (a session's alone, where given) stopped, said in its log.
async fn P53Jobs::stop_all(self : P53Jobs, session : String?, why? : String, only? : (Json) -> Bool) -> Json {
  let up = self.store().jobs_up() catch { _ => [] }
  let stopped = []
  let said = match (why, session) {
    (Some(w), _) => w
    (None, Some(_)) => "its chat ended"
    (None, None) => "the station stops its jobs"
  }
  for job in up {
    if session is Some(s) && jtext_or_empty(job, "sessionKey") != s {
      continue
    }
    if only is Some(f) && !f(job) {
      continue
    }
    let id = jtext_or_empty(job, "id")
    match (try { Ok(self.stop(id)) } catch { e => Err(e) }) {
      Ok(_) => {
        stopped.push(jstr(id))
        p53_append(self.bus.host, jtext_or_empty(job, "log"), "\n[still.fail] stopped: \{said}\n")
      }
      Err(e) => slice_log("warn", "jobs", "job not stopped", jobj_of([("job", jstr(id)), ("error", jstr(p53_words(e)))]))
    }
  }
  Json::array(stopped)
}

///|
/// A session archived or deleted: its jobs that run stopped. Those over keep their rows and logs, as Node keeps them:
/// only `DELETE /sessions/:key/jobs` (`clear_ended`) or the session's deletion (the store's) takes them off.
async fn P53Jobs::session_ended(self : P53Jobs, session : String) -> Unit {
  ignore(self.stop_all(Some(session)))
}

///|
/// jobs.ts `clearEnded`: a session's jobs that are over taken off its record (the pages' 清掉已结束的), their logs
/// with them: the ids gone.
async fn P53Jobs::clear_ended(self : P53Jobs, session : String) -> Array[String] {
  let gone = self.store().clear_ended_jobs(jstr(session)) catch { _ => [] }
  let pairs = gone.filter_map(g => match g {
    Array([String(id), String(file)]) => Some((id, file))
    Array([String(id), _]) => Some((id, ""))
    _ => None
  })
  ignore(self.machine.clear_files(pairs))
  pairs.map(p => p.0)
}

///|
/// jobs.ts `stopFor`: stopped for someone on the pages; its agent told who did, where it was at work lately.
async fn P53Jobs::stop_for(self : P53Jobs, id : String, who : String) -> Json {
  let job = self.stop(id)
  if self.awake(jtext_or_empty(job, "sessionKey")) {
    self.tell(job, "\{p53_named(job)} was stopped by \{who} from still.fail's page.")
  }
  job
}

///|
/// The jobs and services up now of sessions `keys` (None: every one, of workspace `ws` where given), with what it
/// takes to run each again (move/live.ts `jobs.up`): another station's tasks left out.
fn P53Jobs::up_in(self : P53Jobs, keys : Json?, ws : String?) -> Array[Json] {
  let up = match keys {
    Some(Array(k)) => self.store().jobs_up_of(k) catch { _ => [] }
    _ => self.store().jobs_up() catch { _ => [] }
  }
  up
  .filter(j => !jtext_or_empty(j, "sessionKey").has_prefix("remote:") &&
    (keys is Some(_) || ws is None || self.of_workspace(jtext_or_empty(j, "sessionKey"), ws.unwrap())))
  .map(j => jobj_of([
    ("id", jfield(j, "id")),
    ("session", jfield(j, "sessionKey")),
    ("name", jfield(j, "name")),
    ("command", jfield(j, "command")),
    ("cwd", jfield(j, "cwd")),
    ("port", jfield(j, "port")),
    ("watch", jfield(j, "watch")),
  ]))
}

///|
/// Whether a session is of workspace `ws` (its chat's; the home one's where it says none).
fn P53Jobs::of_workspace(self : P53Jobs, session : String, ws : String) -> Bool {
  let row = bus_session_row(self.bus, session)
  !(row is Null) && either(jtext(row, "ws"), bus_home(self.bus)) == Some(ws)
}

///|
/// move/live.ts `stopNamed`: a session's jobs of that name stopped.
async fn P53Jobs::stop_named(self : P53Jobs, session : String, name : String) -> Unit {
  let up = self.store().jobs_up_of([jstr(session)]) catch { _ => [] }
  for j in up {
    if jtext_or_empty(j, "name") == name {
      ignore(self.stop(jtext_or_empty(j, "id")))
    }
  }
}

///|
/// Every job of a workspace's chats stopped, `why` in each log (a station retired from one workspace: retire.ts).
async fn P53Jobs::stop_all_in(self : P53Jobs, ws : String, why : String?) -> Json {
  self.stop_all(None, why=why.unwrap_or("the station left this workspace"), only=j => self.of_workspace(jtext_or_empty(j, "sessionKey"), ws))
}

///|
/// A job moved here started in its session (move/live.ts `jobs.start`): its cwd, else its session's workspace.
async fn P53Jobs::start_moved(self : P53Jobs, j : Json) -> Map[String, Json] {
  let session = jtext_or_empty(j, "session")
  let cwd = match jtext(j, "cwd") {
    Some(c) => c
    None =>
      (jtext(bus_session_row(self.bus, session), "workspace")).unwrap_or(self.bus.data)
  }
  self.start(session, jtext_or_empty(j, "name"), jtext_or_empty(j, "command"), cwd, jnum_of(j, "port"), jtrue(j, "watch"), None, false, Json::null())
}

///|
/// The station stops: the jobs go on (the next station takes them up); what followed them here ends.
async fn P53Jobs::shutdown(self : P53Jobs) -> Unit {
  if self.closing {
    return
  }
  self.closing = true
  // (what is let go of let go of even where the program could not be asked)
  let asked = try { Ok(self.program.call(p53_jobs_key, "shutdown", [])) } catch { e => Err(e) }
  self.machine.shutdown()
  match asked {
    Err(e) => slice_log("warn", "jobs", "the jobs' program was not told the station stops", jobj_of([("error", jstr(p53_words(e)))]))
    Ok(_) => ()
  }
}

///|
/// The jobs' logs held to their bound and the files of jobs long over collected (jobs.ts `upkeep`).
async fn P53Jobs::upkeep(self : P53Jobs, now : Double) -> (Int, Array[String]) {
  let up = self.store().jobs_up() catch { _ => [] }
  let mut capped = 0
  for job in up {
    if self.machine.cap_log(jtext_or_empty(job, "log")) {
      capped += 1
    }
  }
  let ids = up.map(j => jtext_or_empty(j, "id"))
  let collected = self.machine.collect(
    now,
    ids,
    id => {
      let j = self.get(id)
      if j is Null {
        None
      } else {
        Some(j)
      }
    },
    jobs_of=Some(batch => {
      let res = self.store().jobs_ends(batch.map(jstr)) catch { _ => return None }
      match res {
        Object(m) => Some(m)
        _ => None
      }
    }),
  )
  (capped, collected)
}

///|
/// A notice for a job's agent (jobs.ts `tell`): a remote task's is kept by its job and returned by Remote.
async fn P53Jobs::tell(self : P53Jobs, job : Json, text : String) -> Unit {
  let session = jtext_or_empty(job, "sessionKey")
  if session.has_prefix("remote:") {
    return self.remote_changed(jtext_or_empty(job, "id"))
  }
  self.tell_session(session, text)
}

///|
/// Tells a session's agent (the hub's notify, which wakes it).
async fn P53Jobs::tell_session(self : P53Jobs, session : String, text : String) -> Unit {
  self.bus.hub_notify(session~, text~) catch {
    e => slice_log("warn", "jobs", "job notice not given", jobj_of([("session", jstr(session)), ("error", jstr(p53_words(e)))]))
  }
}

///|
fn P53Jobs::remote_changed(self : P53Jobs, id : String) -> Unit {
  if !id.has_prefix("remote_") {
    return
  }
  for f in self.remote_heard {
    f(id)
  }
}

///|
/// A job as the agents see it: its record (jobs.ts `jobJson`), a service's link and whether its port answers.
async fn P53Jobs::view(self : P53Jobs, job : Json) -> Json {
  let v = @jobs_host.job_json(job)
  if p53_has_port(job) {
    let id = jtext_or_empty(job, "id")
    let page = self.bus.hub_link(jfield(job, "sessionKey")) catch {
      _ => Json::null()
    }
    let link = match page {
      String(page) if page != "" => jstr("\{page}?service=\{@jobs_host.encode_uri_component(id)}")
      _ => Json::null()
    }
    let v = jwith(v, "link", link)
    return jwith(v, "ready", jb(self.ready.contains(id)))
  }
  v
}

///|
/// A job as the pages show it: its record, what it said lately (newest first) and when its output last grew.
async fn P53Jobs::shown(self : P53Jobs, id : String) -> Json {
  let job = self.get(id)
  if job is Null {
    raise P53Error("no job \{id}")
  }
  let v = self.view(job)
  let notices = self.store().job_notices(jstr(id), ji(@jobs_host.notices_shown)) catch { _ => [] }
  let v = jwith(v, "notices", Json::array(notices))
  jwith(v, "outputAt", match @jobs_host.output_at(self.bus.host, jtext_or_empty(job, "log")) { Some(t) => jn(t); None => Json::null() })
}

///|
fn P53Jobs::list(self : P53Jobs, session : String?) -> Array[Json] {
  self.store().list_jobs(jopt(session)) catch {
    _ => []
  }
}

///|
async fn P53Jobs::log(self : P53Jobs, id : String, lines : Int) -> String {
  let job = self.get(id)
  if job is Null {
    raise P53Error("no job \{id}")
  }
  @jobs_host.tail(self.bus.host, jtext_or_empty(job, "log"), lines)
}

///|
/// Whether a session's agent was at work lately (jobs.ts `awake`): one idle longer is not woken for a stop from a page.
fn P53Jobs::awake(self : P53Jobs, session : String) -> Bool {
  let s = bus_session_row(self.bus, session)
  if s is Null {
    return false
  }
  jtrue(s, "running") || self.now() - jnum_of(s, "lastActiveAt").unwrap_or(0.0) < @jobs_host.awake_ms
}

///|
/// A job's command started in a process group of its own (sys.mbt `spawn`, Node's `detached`), under the shell that
/// writes its exit code aside when it ends (`@jobs_host.wrapper`), its output appended to its log, lower than the
/// station (nice); followed to its end by the machine's side. Its group's id.
async fn P53Jobs::launch(
  self : P53Jobs,
  job : @jobs_host.JobStart,
  extra : Map[String, String],
  command? : String,
  sandboxed? : Bool = false,
) -> Int {
  let host = self.bus.host
  // (made, or found, here: a log that cannot be written is said now)
  ignore(host.shell("fs.put", { "path": jstr(job.log) }, bytes=b""))
  let exit = self.machine.exit_file(job.id)
  for f in [exit, exit + ".tmp", self.machine.lost_file(job.id)] {
    ignore(try { Ok(host.shell("fs.remove", { "path": jstr(f), "force": jb(true) })) } catch { e => Err(e) })
  }
  let vars : Map[String, String] = Map([])
  for kv in env_all() {
    vars[kv.0] = kv.1
  }
  for k, v in self.machine.job_env(job, extra, env_get("PATH").unwrap_or("")) {
    vars[k] = v
  }
  // (never the launcher's front: a job that found it would bind its own key on the station's endpoint)
  vars.remove("STILLFAIL_MESH_FRONT")
  // (where `stillfail-job screen` asks for the screen: this machine's, which a sandbox's commands do not have)
  if sandboxed {
    vars.remove("STILLFAIL_JOB_SCREEN")
  }
  let inner = "exec >>\"$3\" 2>&1; \{@jobs_host.wrapper}"
  // (the shell appends to the log itself: Git's sh on Windows cannot write to a file opened for appending by another;
  // lower than the station, nice running the shell in its own process, the pid the same: jobs.ts `spawn`, ops/nice.ts)
  let shell = if is_windows() {
    match @ops_platform.git_shell(vars.to_array(), p => (try { Ok(@drive.stat(p)) } catch { e => Err(e) }) is Ok({ file: true, .. })) {
      Some(sh) => sh
      None => raise P53Error(@ops_platform.no_shell)
    }
  } else {
    "/bin/sh"
  }
  let shell_args = ["-c", inner, @jobs_host.job_command_name, command.unwrap_or(job.command), exit, job.log]
  let (program, args) = if !is_windows() && p53_file_is(host, "/usr/bin/nice") {
    ("/usr/bin/nice", ["-n", "10", shell, ..shell_args])
  } else {
    (shell, shell_args)
  }
  let proc = spawn(host, program, args, env=vars.to_array(), cwd=job.cwd, group=true) catch {
    SysError(why) => raise P53Error(why)
  }
  self.machine.follow(job.id, proc.pid, self.now())
  // (what the child says of its end is the follower's to read: its exit file, its group gone)
  fork_bg(host, "job's shell", async fn() { ignore(proc.finished()) })
  proc.pid
}

///|
/// Whether `path` is a file there.
async fn p53_file_is(host : @host.Host, path : String) -> Bool {
  match (try { Ok(host.shell("fs.stat", { "path": Json::string(path) })) } catch { e => Err(e) }) {
    Ok((String("file"), _)) => true
    _ => false
  }
}

///|
/// A service's port looked at until it answers (or its group ends, or P53_READY_MS pass): then it is ready.
fn P53Jobs::watch_ready(self : P53Jobs, id : String, pgid : Int, port : Int) -> Unit {
  let host = self.bus.host
  fork_bg(host, "service ready", async fn() {
    let mut waited = 0
    while waited < p53_ready_ms && !self.closing {
      if self.groups.get(id) != Some(pgid) {
        return
      }
      match (try { Ok(host.tcp_open(port)) } catch { e => Err(e) }) {
        Ok(conn) => {
          conn.socket.destroy()
          self.ready[id] = true
          slice_log("info", "jobs", "service ready", jobj_of([("job", jstr(id)), ("port", ji(port))]))
          return
        }
        _ => ()
      }
      @effect.sleep(p53_ready_every_ms) // timer: a retry until the service's port answers (it says nothing when it listens)
      waited += p53_ready_every_ms
    }
  })
}

///|
let p53_pressure_ttl_ms : Int64 = 2_000L

///|
let p53_pressure_cache : Ref[(Int64, String?)?] = Ref(None)

///|
let p53_pressure_inflight : Ref[@effect.Deferred[String?]?] = Ref(None)

///|
/// The memory's pressure as the system says it (platform `memoryPressure`): macOS's level, Linux's /proc/meminfo
/// (pressureOfAvailable). Cached for 2 s with single-flight coalescing so concurrent overview viewers share one sysctl.
async fn p53_pressure(host : @host.Host) -> String? {
  let now = @host.now()
  match p53_pressure_cache.val {
    Some((at, value)) if now - at < p53_pressure_ttl_ms => return value
    _ => ()
  }
  match p53_pressure_inflight.val {
    Some(d) => return d.wait()
    None => ()
  }
  let d : @effect.Deferred[String?] = @effect.Deferred::new()
  p53_pressure_inflight.val = Some(d)
  let mut result : String? = None
  defer {
    p53_pressure_inflight.val = None
    ignore(d.succeed(result))
  }
  result = p53_pressure_read(host)
  p53_pressure_cache.val = Some((@host.now(), result))
  result
}

///|
async fn p53_pressure_read(host : @host.Host) -> String? {
  let of_available = (available : Double, total : Double) => {
    if !(total > 0.0) || available < 0.0 || available > total {
      return None
    }
    let share = available / total
    Some(if share < 0.04 { "critical" } else if share < 0.1 { "high" } else { "normal" })
  }
  if platform() == "darwin" {
    guard shell_proc_run(host, "/usr/sbin/sysctl", ["-n", "kern.memorystatus_vm_pressure_level"]) is Some(level) else { return None }
    match level.trim_space().to_string() {
      "1" => {
        let m = machine()
        match (jnum_of(m, "freemem"), jnum_of(m, "totalmem")) {
          (Some(f), Some(t)) =>
            match of_available(f, t) {
              Some(p) => Some(p)
              None => Some("normal")
            }
          _ => Some("normal")
        }
      }
      "4" => Some("critical")
      "2" => {
        // (warn is high only while what is left says so too: macOS warns while its free pages are low)
        let m = machine()
        match (jnum_of(m, "freemem"), jnum_of(m, "totalmem")) {
          (Some(f), Some(t)) =>
            match of_available(f, t) {
              Some("normal") => Some("normal")
              Some(p) => Some(p)
              None => Some("high")
            }
          _ => Some("high")
        }
      }
      _ => None
    }
  } else {
    guard shell_read_text(host, "/proc/meminfo") is Some(info) else { return None }
    let field = (name : String) => {
      for line in info.split("\n") {
        let l = line.to_string()
        if l.has_prefix(name + ":") {
          let digits = l[name.length() + 1:].to_owned().trim_space().to_string().split(" ").to_array()
          if digits.length() > 0 {
            match attempt(() => @string.parse_double(digits[0].to_string())) {
              Ok(n) => return Some(n * 1024.0)
              Err(_) => ()
            }
          }
        }
      }
      None
    }
    match (field("MemAvailable"), field("MemTotal")) {
      (Some(a), Some(t)) => of_available(a, t)
      _ => None
    }
  }
}

///|
/// How long the machine's input has been idle (platform `inputIdleMs`, macOS's ioreg), none where it is not read.
async fn p53_input_idle(host : @host.Host) -> Double? {
  if platform() != "darwin" {
    return None
  }
  guard shell_proc_run(host, "/usr/sbin/ioreg", ["-c", "IOHIDSystem", "-d", "4", "-r", "-k", "HIDIdleTime"]) is Some(out) else {
    return None
  }
  for line in out.split("\n") {
    let l = line.to_string()
    match l.find("\"HIDIdleTime\" = ") {
      Some(i) => {
        let n = l[i + 16:].to_owned().trim_space().to_string()
        match attempt(() => @string.parse_double(n)) {
          Ok(ns) => return Some(ns / 1000000.0)
          Err(_) => ()
        }
      }
      None => ()
    }
  }
  None
}

///|
/// Words appended to a file (a job's log).
async fn p53_append(host : @host.Host, path : String, text : String) -> Unit {
  host_append_file(host, path, @utf8.encode(text)) catch { _ => () }
}

// ── a service's preview ──

///|
/// `/preview/<port>/…` on the agents' door: the request passed to 127.0.0.1:<port> and its answer back as it comes
/// (jobs/preview.ts `proxyPreview`).
async fn P53Jobs::preview(self : P53Jobs, r : Request, conn : Json) -> Reply? {
  guard @jobs_host.preview_target(r.path()) is Some((port, target)) else { return Some(plain(404, "")) }
  let full = match r.query() {
    Some(q) => "\{target}?\{q}"
    None => target
  }
  let answer = @jobs_host.proxy_preview(
    self.bus.host,
    r.meth,
    r.headers,
    if r.body.length() > 0 { Some(r.body) } else { None },
    port,
    full,
    (self.bus.lang.val)(),
  )
  let head = StringBuilder()
  head.write_string("HTTP/1.1 \{answer.status} \{if answer.status < 400 { "OK" } else { "Error" }}\r\n")
  for h in answer.headers {
    let name = h.0.to_lower()
    if name != "content-length" && name != "transfer-encoding" && name != "connection" {
      head.write_string("\{h.0}: \{h.1}\r\n")
    }
  }
  head.write_string("connection: close\r\n\r\n")
  // (the service's connection let go however this ends: its client gone mid-way, the service's end, a failure)
  defer (answer.close)()
  if !write_on(self.bus.host, conn, @utf8.encode(head.to_string())) {
    return None
  }
  while true {
    match (answer.next)() {
      Some(b) => if !write_on(self.bus.host, conn, b) { break }
      None => break
    }
  }
  self.bus.host.tcp_end(conn) catch {
    _ => ()
  }
  self.bus.host.tcp_close(conn)
  None
}

///|
/// A preview asked whole by another part (the admin API's `/preview/<port>/…`): `{method, path, headers, body}`,
/// answered `{status, headers, body}`.
async fn P53Jobs::preview_json(self : P53Jobs, arg : Json) -> Json {
  guard @jobs_host.preview_target(jtext_or_empty(arg, "path")) is Some((port, target)) else {
    raise P53Error("no preview at \{jtext_or_empty(arg, "path")}")
  }
  let headers = match jfield(arg, "headers") {
    Object(m) => m.to_array().filter_map(kv => match kv.1 { String(v) => Some((kv.0.to_lower(), v)); _ => None })
    _ => []
  }
  let body = match jtext(arg, "body") {
    Some(b) if b != "" => Some(@utf8.encode(b))
    _ => None
  }
  let answer = @jobs_host.proxy_preview(self.bus.host, jtext(arg, "method").unwrap_or("GET"), headers, body, port, target, (self.bus.lang.val)())
  defer (answer.close)()
  let out = @buffer.Buffer()
  while true {
    match (answer.next)() {
      Some(b) => out.write_bytes(b)
      None => break
    }
  }
  jobj_of([
    ("status", ji(answer.status)),
    ("headers", Json::array(answer.headers.map(h => Json::array([jstr(h.0), jstr(h.1)])))),
    ("body", jstr(@utf8.decode_lossy(out.to_bytes()))),
  ])
}

// ── the agents' tools (tools/jobs.ts) ──

///|
let p53_job_start_description : String = "Start a background job: a shell command the station runs apart from your turns, with its output kept in a log, for work that outlives a turn. You are told when it ends; inside it, `stillfail-job notify <words>` sends you a message on the way (milestones, problems). With port it is a web service: kept up (started again if it ends), given PORT in its environment, and opened by the workspace's members through the link returned (post it where people should see it). With watch it keeps watch over something for a long while (a CI run, a deploy, a metric, a review queue): its chat shows as watching and is not archived for being idle. Skill stillfail-jobs says the rest: waiting on a job, how a watch checks and notifies, services."

///|
/// A JSON number serde reads as a u64: a whole number, not negative.
fn p53_u64(v : Json) -> Double? {
  match v {
    Number(n, ..) if n >= 0.0 && n == n.floor() => Some(n)
    _ => None
  }
}

///|
/// The job a tool names (`id`), when it is this session's.
fn P53Jobs::owned(self : P53Jobs, session : String, args : Json) -> Json raise P53Error {
  let id = jtext_or_empty(args, "id").trim_space().to_string()
  let job = self.get(id)
  if job is Null {
    raise P53Error("no job \{id}: job_list names this session's")
  }
  if jtext_or_empty(job, "sessionKey") != session {
    raise P53Error("job \{id} is another session's")
  }
  job
}

///|
fn P53Jobs::tools(self : P53Jobs) -> Array[PartTool] {
  let bus = self.bus
  let id_only = jobj_of([
    ("type", jstr("object")),
    ("properties", jobj_of([("id", jobj_of([("type", jstr("string"))]))])),
    ("required", Json::array([jstr("id")])),
    ("additionalProperties", jb(false)),
  ])
  [
    p53_tool(
      bus,
      "job_start",
      p53_job_start_description,
      jobj_of([
        ("type", jstr("object")),
        (
          "properties",
          jobj_of([
            ("command", jobj_of([("type", jstr("string")), ("description", jstr("The shell command (run by sh -c)."))])),
            ("name", jobj_of([("type", jstr("string")), ("description", jstr("A short name for it."))])),
            ("cwd", jobj_of([("type", jstr("string")), ("description", jstr("Where it runs; default this session's workspace."))])),
            (
              "port",
              jobj_of([
                ("type", jstr("integer")),
                ("minimum", ji(1024)),
                ("maximum", ji(65535)),
                ("description", jstr("For a web service: the port it listens on (127.0.0.1 is enough).")),
              ]),
            ),
            ("watch", jobj_of([("type", jstr("boolean")), ("description", jstr("It keeps watch for a long while. Not with a port."))])),
          ]),
        ),
        ("required", Json::array([jstr("command")])),
        ("additionalProperties", jb(false)),
      ]),
      async fn(session, args) {
        let row = bus_session_row(bus, session)
        let home = match jtext(row, "workspace") {
          Some(w) => w
          None => raise P53Error("unknown session")
        }
        let given = jtext_or_empty(args, "cwd").trim_space().to_string()
        // (paths.ts `joinPath`: a path given whole stays as it is, as job_start's description says)
        let cwd = if given == "" {
          home
        } else if is_windows() {
          @ops_platform.win_join(home, given)
        } else {
          @ops_platform.unix_join(home, given)
        }
        let port = match jfield(args, "port") {
          Null => None
          v =>
            match p53_u64(v) {
              Some(p) if p <= 65535.0 => Some(p)
              _ => raise P53Error("port must be a number from 1024 to 65535")
            }
        }
        let job = self.start(session, jtext_or_empty(args, "name"), jtext_or_empty(args, "command"), cwd, port, jtrue(args, "watch"), None, false, Json::null())
        jpretty(self.view(Json::object(job)))
      },
    ),
    p53_tool(
      bus,
      "job_list",
      "This session's background jobs, newest first: their state (running, exited, stopped, failed), exit code, port and link.",
      jobj_of([("type", jstr("object")), ("properties", Json::object({})), ("additionalProperties", jb(false))]),
      async fn(session, _args) {
        let list = self.list(Some(session))
        if list.length() == 0 {
          return "No jobs."
        }
        let views = []
        for j in list {
          views.push(self.view(j))
        }
        jpretty(Json::array(views))
      },
    ),
    p53_tool(
      bus,
      "job_log",
      "The last lines of a background job's output.",
      jobj_of([
        ("type", jstr("object")),
        (
          "properties",
          jobj_of([
            ("id", jobj_of([("type", jstr("string"))])),
            ("lines", jobj_of([("type", jstr("integer")), ("minimum", ji(1)), ("maximum", ji(1000)), ("description", jstr("Default 50."))])),
          ]),
        ),
        ("required", Json::array([jstr("id")])),
        ("additionalProperties", jb(false)),
      ]),
      async fn(session, args) {
        let job = self.owned(session, args)
        let lines = match p53_u64(jfield(args, "lines")) {
          None => @jobs_host.log_lines
          Some(n) => if n < 1.0 { 1 } else if n > 1000.0 { 1000 } else { n.to_int() }
        }
        let log = @jobs_host.tail(bus.host, jtext_or_empty(job, "log"), lines)
        if log == "" {
          "\{p53_named(job)} has written nothing yet."
        } else {
          log
        }
      },
    ),
    p53_tool(
      bus,
      "job_stop",
      "Stop a background job (a service is then not started again).",
      id_only,
      async fn(session, args) {
        let job = self.stop(jtext_or_empty(self.owned(session, args), "id"))
        "\{p53_named(job)} is \{jtext_or_empty(job, "state")}."
      },
    ),
  ]
}

fn p53_has_port(job : Json) -> Bool {
  jnum_of(job, "port") is Some(_)
}
