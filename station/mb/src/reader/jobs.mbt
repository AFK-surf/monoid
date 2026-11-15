// The station's background jobs (station/src/jobs/jobs.ts `Jobs`), run in the sessions' program: what each is and does
// as it starts, waits in the queue for other stations' tasks (station/mb/src/admit), ends, is started again (a
// service) or stopped, and what its agent is told. What is the machine's (a process started in a group of its own, its
// exit heard, a signal sent, its log read, the memory's pressure) and the store it asks of Node, as an actor does
// (jobs.ts answers it, as the pseudo-actor `#jobs`). Node says it what it is asked (`call`) and a job's end (`exited`).
// What Node did at once as one step (a start's checks and its record, the queue's pick and its start, an end taken in)
// is one step here too: each holds the jobs' one permit (`locked`), so no two of them meet halfway (two starts of one
// port, a waiting task started twice); a stop waits for its job's end with none held.

///|
priv struct Run {
  pgid : Int
  mut stopping : Bool
}

///|
priv struct JobsState {
  running : Map[String, Run]
  mut claims : Array[@admit.Claim]
  last_of : Map[String, Double]
  mut pressure : String?
  mut person : Bool
  mut reading_person : Bool
  mut why : String?
  mut closing : Bool
  mut looking : Bool
  told_long : Map[String, Bool]
  /// one step at a time (`locked`)
  lock : @effect.Semaphore
}

///|
fn JobsState::new() -> JobsState {
  {
    running: Map([]),
    claims: [],
    last_of: Map([]),
    pressure: None,
    person: false,
    reading_person: false,
    why: None,
    closing: false,
    looking: false,
    told_long: Map([]),
    lock: @effect.Semaphore::new(1),
  }
}

///|
/// `f` as one step of the jobs': none other runs meanwhile.
async fn[X] Actors::locked(self : Actors, f : async () -> X raise) -> X raise {
  let lock = self.jobs.lock
  lock.acquire()
  defer lock.release()
  f()
}

///|
let jobs_key : String = "#jobs"

///|
let max_running : Int = 20

///|
let look_ms : Double = 5000.0

///|
async fn Actors::jstore(self : Actors, f : String, args : Array[Json]) -> Json raise {
  self.rpc(jobs_key, "store." + f, args)
}

///|
async fn Actors::jnode(self : Actors, f : String, args : Array[Json]) -> Json raise {
  self.rpc(jobs_key, "node." + f, args)
}

///|
fn Actors::jlog(self : Actors, level : String, message : String, fields? : Map[String, Json] = {}) -> Unit {
  self.tell(jobs_key, "log", [jstr(level), jstr(message), Json::object(fields)])
}

///|
/// jobs.ts `named`: how a job is named to its agent.
fn named(job : Json) -> String {
  let name = str_of(job.value("name")).unwrap_or("")
  let id = str_of(job.value("id")).unwrap_or("")
  match job.value("port") {
    Some(Number(p, ..)) => "Service \"\{name}\" (\{id}, port \{p.to_int()})"
    _ => "Job \"\{name}\" (\{id})"
  }
}

///|
fn has_port(job : Json) -> Bool {
  job.value("port") is Some(Number(_, ..))
}

///|
/// A notice for a job's agent (jobs.ts `tell`): a remote task's is kept by its job and returned by Remote.
async fn Actors::jtell(self : Actors, job : Json, text : String) -> Unit raise {
  let session = str_of(job.value("sessionKey")).unwrap_or("")
  if session.has_prefix("remote:") {
    return self.remote_changed(str_of(job.value("id")).unwrap_or(""))
  }
  try {
    ignore(self.jnode("notify", [jstr(session), jstr(text)]))
  } catch {
    e => self.jlog("warn", "job notice not given", fields={ "session": jstr(session), "error": jstr(Asked::message(e)) })
  }
}

///|
async fn Actors::remote_changed(self : Actors, id : String) -> Unit raise {
  // (a task of another station's: its source told, remote.mbt `push_out`, in this program)
  if id.has_prefix("remote_") {
    self.push_out(id.view(start_offset=7).to_string())
  }
}

///|
/// What Node asks of the jobs (mb-jobs.ts): `method` with `args`.
async fn Actors::jobs_called(self : Actors, method : String, args : Array[Json]) -> Json raise {
  let arg = (i : Int) => if i < args.length() { args[i] } else { Json::null() }
  match method {
    "startId" => self.locked(() => self.start_id(args))
    "stop" => self.job_stop(str_of(Some(arg(0))).unwrap_or(""))
    "exited" =>
      self.locked(() => self.ended(
        str_of(Some(arg(0))).unwrap_or(""),
        num_of(Some(arg(1))).map(n => n.to_int()),
        num_of(Some(arg(2))).map(n => n.to_int()),
        num_of(Some(arg(3))).unwrap_or(0.0),
      ))
    "relaunch" => self.relaunch()
    "shutdown" => {
      self.jobs.closing = true
      Json::null()
    }
    "notified" => self.locked(() => {
      let job = self.jstore("jobByToken", [arg(0)])
      if job is Null {
        raise Asked({ "message": jstr("unknown job token") })
      }
      let said = chars_of(str_of(Some(arg(1))).unwrap_or("").trim_space().to_string(), 4000)
      if said == "" {
        raise Asked({ "message": jstr("nothing to say") })
      }
      ignore(self.jstore("addJobNotice", [job.value("id").unwrap_or(Json::null()), jstr(said)]))
      self.jtell(job, "\{named(job)} says: \{said}")
      Json::null()
    })
    "memorySeen" => {
      self.jobs.pressure = str_of(Some(arg(0)))
      Json::null()
    }
    "queueOf" => self.locked(() => self.queue_of(str_of(Some(arg(0))).unwrap_or("")))
    "screenHolder" =>
      self.locked(() => match self.screen_holder(str_of(Some(arg(0)))) { Some(s) => jstr(s); None => Json::null() })
    "screenAsked" => self.locked(() => self.screen_asked(str_of(Some(arg(0))).unwrap_or(""), str_of(Some(arg(1))).unwrap_or(""), num_of(Some(arg(2))).unwrap_or(0.0).to_int()))
    "claims" => {
      self.jobs.claims = claims_of_json(arg(0))
      Json::null()
    }
    _ => raise Asked({ "message": jstr("no jobs method \{method}") })
  }
}

///|
/// At most `n` characters of `s`.
fn chars_of(s : String, n : Int) -> String {
  let out = StringBuilder::new()
  let mut i = 0
  for c in s {
    if i >= n {
      break
    }
    out.write_char(c)
    i += 1
  }
  out.to_string()
}

///|
/// jobs.ts `startId`.
async fn Actors::start_id(self : Actors, args : Array[Json]) -> Json raise {
  let arg = (i : Int) => if i < args.length() { args[i] } else { Json::null() }
  let session = str_of(Some(arg(0))).unwrap_or("")
  let name = str_of(Some(arg(1))).unwrap_or("")
  let command = str_of(Some(arg(2))).unwrap_or("")
  let cwd = str_of(Some(arg(3))).unwrap_or("")
  let port = arg(4)
  let watch = truthy(arg(5))
  let id = arg(6)
  let checked = truthy(arg(7))
  let queue = arg(8)
  let sandbox = arg(9)
  let fail = (m : String) => Asked({ "message": jstr(m) })
  if id is String(_) {
    let job = self.jstore("getJob", [id])
    if !(job is Null) {
      return job
    }
  }
  if command.trim_space().to_string() == "" {
    raise fail("command is empty")
  }
  let screen = queue.value("screen") is Some(True)
  let small = queue.value("small") is Some(True)
  if screen && small {
    raise fail("a small task cannot use the screen")
  }
  if !checked && !truthy(self.jnode("isDir", [jstr(cwd)])) {
    raise fail("no such directory: \{cwd}")
  }
  if port is Number(p, ..) && p < 1024.0 {
    raise fail("a service's port is 1024 or above")
  }
  if watch && port is Number(_, ..) {
    raise fail("a watch is a job, not a web service: give it no port")
  }
  if !(sandbox is Null) && (port is Number(_, ..) || !(queue is Null)) {
    raise fail("a sandbox's task is neither a service nor queued here")
  }
  if truthy(self.jstore("runningJobsAtLeast", [jstr(session), jnum(max_running.to_double())])) {
    raise fail("this session runs \{max_running} jobs already; stop some first")
  }
  if port is Number(_, ..) {
    let taken = self.jstore("jobAtPort", [port])
    if !(taken is Null) {
      raise fail("port \{port.stringify()} is \{named(taken)}'s already")
    }
  }
  // (its id, its token, its record as Node writes it: the log's place is Node's)
  let job = self.jnode("newJob", [jstr(session), jstr(name), jstr(command), jstr(cwd), port, jbool(watch), id, queue, sandbox])
  let job_id = str_of(job.value("id")).unwrap_or("")
  if !(queue is Null) {
    self.start_next()
    let now = self.jstore("getJob", [jstr(job_id)])
    let now = if now is Null { job } else { now }
    if now.value("queued") is Some(True) {
      self.jlog("info", "job queued", fields={ "job": jstr(job_id), "session": jstr(session), "name": job.value("name").unwrap_or(Json::null()), "why": match self.jobs.why { Some(w) => jstr(w); None => Json::null() } })
    }
    return now
  }
  try {
    self.spawn_job(job, false, Json::object({}))
  } catch {
    e => {
      ignore(self.jstore("jobEnded", [jstr(job_id), jstr("failed"), Json::null()]))
      raise e
    }
  }
  self.jlog("info", "job started", fields={ "job": jstr(job_id), "session": jstr(session), "name": job.value("name").unwrap_or(Json::null()), "port": port })
  let now = self.jstore("getJob", [jstr(job_id)])
  if now is Null { job } else { now }
}

///|
/// jobs.ts `spawn`: its command run (Node's: a group of its own, its env, its log), followed to its end.
async fn Actors::spawn_job(self : Actors, job : Json, restarted : Bool, extra : Json) -> Unit raise {
  let id = str_of(job.value("id")).unwrap_or("")
  let pgid = num_of(Some(self.jnode("spawn", [jstr(id), jbool(restarted), extra]))).unwrap_or(0.0).to_int()
  self.jobs.running[id] = { pgid, stopping: false }
}

///|
/// The store's time (claims, how long one held the screen: as the jobs' records are timed).
async fn Actors::stored_now(self : Actors) -> Double raise {
  num_of(Some(self.jstore("now", []))).unwrap_or(self.now)
}

///|
/// The tasks waiting, oldest first, and the queue's running (jobs.ts `line`).
async fn Actors::line(self : Actors) -> (Array[@admit.Waiting], Array[@admit.Started]) raise {
  let waiting : Array[@admit.Waiting] = []
  let running : Array[@admit.Started] = []
  match self.jstore("remoteQueueJobs", []) {
    Array(rows) =>
      for j in rows {
        let id = str_of(j.value("id")).unwrap_or("")
        let screen = j.value("screen") is Some(True)
        let small = j.value("small") is Some(True)
        if j.value("queued") is Some(True) {
          waiting.push({ id, session: str_of(j.value("sessionKey")).unwrap_or(""), screen, queued_at: num_of(j.value("startedAt")).unwrap_or(0.0), small })
        } else {
          running.push({ id, screen, small })
        }
      }
    _ => ()
  }
  waiting.sort_by((a, b) => a.queued_at.compare(b.queued_at))
  (waiting, running)
}

///|
fn JobsState::last(self : JobsState, session : String) -> Double? {
  self.last_of.get(session)
}

///|
async fn Actors::chosen(self : Actors) -> @admit.Picked? raise {
  let (waiting, running) = self.line()
  let chosen = @admit.pick(waiting, running, self.jobs.pressure, self.jobs.person, s => self.jobs.last(s), @admit.claims_held(self.jobs.claims))
  self.jobs.why = match chosen {
    Some(@admit.Wait(w)) => Some(w)
    _ => None
  }
  chosen
}

///|
async fn Actors::watch_queue(self : Actors) -> Unit raise {
  if self.jobs.looking || self.jobs.closing {
    return
  }
  self.jobs.looking = true
  self.look_later()
}

///|
/// The next look at the machine while a task waits (jobs.ts `watchQueue`), LOOK_MS on Node's clock.
fn Actors::look_later(self : Actors) -> Unit {
  ignore(
    self.after(look_ms, () => {
      self.spawn(() => {
        let go_on = try {
          if self.jobs.closing {
            false
          } else {
            let pressure = self.jnode("pressure", []) catch { _ => Json::null() }
            self.jobs.pressure = str_of(Some(pressure))
            self.look_person()
            self.locked(() => {
              self.start_next()
              let (waiting, _) = self.line()
              !self.jobs.closing && waiting.length() > 0
            })
          }
        } catch {
          _ => false
        }
        if go_on {
          self.look_later()
        } else {
          self.jobs.looking = false
          self.jobs.why = None
        }
      })
    }),
  )
}

///|
async fn Actors::look_person(self : Actors) -> Unit raise {
  if self.jobs.reading_person {
    return
  }
  self.jobs.reading_person = true
  defer {
    self.jobs.reading_person = false
  }
  let idle = self.jnode("inputIdle", []) catch { _ => Json::null() }
  self.jobs.person = match idle {
    Number(idle, ..) => idle < @admit.person_idle_ms
    _ => false
  }
}

///|
/// jobs.ts `startNext`.
async fn Actors::start_next(self : Actors) -> Unit raise {
  if self.jobs.closing {
    return
  }
  self.prune()
  self.admit_next()
  let (waiting, running) = self.line()
  if waiting.iter().any(w => w.small) && !running.iter().any(r => r.small) {
    self.admit_next()
  }
  self.serve()
  self.tell_long()
}

///|
async fn Actors::admit_next(self : Actors) -> Unit raise {
  let chosen = self.chosen()
  if chosen is Some(@admit.Wait(_)) {
    self.watch_queue()
  }
  guard chosen is Some(@admit.Start(w)) else { return }
  let job = self.jstore("getJob", [jstr(w.id)])
  if job is Null || str_of(job.value("state")) != Some("running") || !(job.value("queued") is Some(True)) {
    return
  }
  self.jobs.last_of[w.session] = self.now
  let extra : Json = if job.value("small") is Some(True) {
    { "STILLFAIL_CPUS": "1", "MAKEFLAGS": "-j1", "CARGO_BUILD_JOBS": "1", "CMAKE_BUILD_PARALLEL_LEVEL": "1" }
  } else {
    Json::object({})
  }
  try {
    self.spawn_job(job, false, extra)
    self.jlog("info", "queued job started", fields={ "job": jstr(w.id), "session": job.value("sessionKey").unwrap_or(Json::null()), "name": job.value("name").unwrap_or(Json::null()) })
  } catch {
    e => {
      let m = Asked::message(e)
      self.jlog("warn", "queued job not started", fields={ "job": jstr(w.id), "error": jstr(m) })
      try {
        ignore(self.jnode("append", [job.value("log").unwrap_or(Json::null()), jstr("[still.fail] could not start: \{m}\n")]))
      } catch {
        _ => ()
      }
      ignore(self.jstore("jobEnded", [jstr(w.id), jstr("failed"), Json::null()]))
      self.jtell(job, "\{named(job)} could not be started: \{m}")
    }
  }
  let (waiting, _) = self.line()
  if waiting.length() > 0 {
    self.watch_queue()
  }
}

///|
/// jobs.ts `queueOf`.
async fn Actors::queue_of(self : Actors, id : String) -> Json raise {
  let job = self.jstore("getJob", [jstr(id)])
  if job is Null || str_of(job.value("state")) != Some("running") || !(job.value("queued") is Some(True)) {
    return Json::null()
  }
  let (waiting, running) = self.line()
  guard waiting.search_by(w => w.id == id) is Some(i) else { return Json::null() }
  let task = waiting[i]
  guard @admit.place(waiting.filter(w => w.small == task.small), id, s => self.jobs.last(s)) is Some(p) else { return Json::null() }
  let why = match @admit.pick([task], running, self.jobs.pressure, self.jobs.person, s => self.jobs.last(s), @admit.claims_held(self.jobs.claims)) {
    Some(@admit.Wait(w)) => Some(w)
    _ => None
  }
  let out : Map[String, Json] = {
    "place": jnum(p.to_double()),
    "why": match why { Some(w) => jstr(w); None => Json::null() },
    "decision": { "memoryPressure": match self.jobs.pressure { Some(p) => jstr(p); None => Json::null() } },
  }
  if why == Some("screen") && self.screen_holder(Some(id)) is Some(h) {
    out["holder"] = jstr(h)
  }
  Json::object(out)
}

///|
/// jobs.ts `chatOf`: the chat a session key is, as an agent reads it.
fn chat_of(session : String) -> String {
  if session.has_prefix("remote:") {
    let parts = session.split(":").map(p => p.to_string()).collect()
    if parts.length() >= 4 {
      let station = parts[2]
      let short = chars_of(station, 12)
      let key = parts[3:].iter().map(p => p).join(":")
      return "chat \{key} on station \{short}"
    }
  }
  "chat \{session}"
}

///|
/// jobs.ts `screenHolder`.
async fn Actors::screen_holder(self : Actors, except : String?) -> String? raise {
  let now = self.stored_now()
  let ago = (at : Double) => {
    let m = ((now - at) / 60000.0).round()
    "\{if m < 1.0 { 1 } else { m.to_int() }} min"
  }
  let of = async fn(id : String, since : Double) -> String? raise {
    let job = self.jstore("getJob", [jstr(id)])
    if job is Null {
      return None
    }
    let name = str_of(job.value("name")).unwrap_or("").replace_all(old="\"", new="'")
    Some("\{name} (\{id}) of \{chat_of(str_of(job.value("sessionKey")).unwrap_or(""))}, for \{ago(since)}")
  }
  for c in self.jobs.claims {
    if c.held && Some(c.job) != except {
      if of(c.job, c.since.unwrap_or(c.at)) is Some(s) {
        return Some(s)
      }
    }
  }
  let (_, running) = self.line()
  for r in running {
    if r.screen && Some(r.id) != except {
      let job = self.jstore("getJob", [jstr(r.id)])
      if !(job is Null) {
        return of(r.id, num_of(job.value("startedAt")).unwrap_or(now))
      }
    }
  }
  if self.jobs.person {
    Some("a person using this machine")
  } else {
    None
  }
}

///|
/// jobs.ts `screenAsked`.
async fn Actors::screen_asked(self : Actors, token : String, ask : String, pid : Int) -> Json raise {
  let job = self.jstore("jobByToken", [jstr(token)])
  if job is Null {
    raise Asked({ "message": jstr("unknown job token") })
  }
  if str_of(job.value("state")) != Some("running") || job.value("queued") is Some(True) {
    raise Asked({ "message": jstr("\{named(job)} is not running") })
  }
  let id = str_of(job.value("id")).unwrap_or("")
  let mine = (c : @admit.Claim) => c.job == id && c.pid == pid
  if ask == "give" {
    self.jobs.claims = self.jobs.claims.filter(c => !mine(c))
    self.keep_claims()
    self.start_next()
    return { "screen": "given" }
  }
  if !truthy(self.jnode("pidAlive", [jnum(pid.to_double())])) {
    raise Asked({ "message": jstr("no process \{pid} on this machine") })
  }
  if !self.jobs.claims.iter().any(mine) {
    self.jobs.claims.push({ job: id, pid, at: self.stored_now(), held: false, since: None })
  }
  self.spawn(() => try { self.look_person() } catch { _ => () })
  self.start_next()
  let waiting = self.jobs.claims.filter(c => !c.held)
  match waiting.search_by(mine) {
    None => { "screen": "yours" }
    Some(at) => {
      let who = match self.screen_holder(Some(id)) { Some(s) => jstr(s); None => Json::null() }
      { "screen": "waiting", "place": jnum((at + 1).to_double()), "who": who }
    }
  }
}

///|
async fn Actors::prune(self : Actors) -> Unit raise {
  let kept : Array[@admit.Claim] = []
  for c in self.jobs.claims {
    let job = self.jstore("getJob", [jstr(c.job)])
    if str_of(job.value("state")) == Some("running") && !(job.value("queued") is Some(True)) &&
      truthy(self.jnode("pidAlive", [jnum(c.pid.to_double())])) {
      kept.push(c)
    }
  }
  if kept.length() == self.jobs.claims.length() {
    return
  }
  self.jobs.claims = kept
  self.keep_claims()
}

///|
async fn Actors::serve(self : Actors) -> Unit raise {
  let (_, running) = self.line()
  let screen_jobs = running.filter(r => r.screen).map(r => r.id)
  let before = self.jobs.claims.filter(c => c.held).length()
  self.jobs.claims = @admit.served(self.jobs.claims, screen_jobs, self.stored_now(), self.jobs.person)
  if self.jobs.claims.filter(c => c.held).length() != before {
    self.keep_claims()
  }
}

///|
/// The claims that hold the screen, written down for the next station (Node's: jobs/screen.json).
async fn Actors::keep_claims(self : Actors) -> Unit raise {
  let held = self.jobs.claims
    .filter(c => c.held)
    .map(c => {
      let o : Map[String, Json] = { "job": jstr(c.job), "pid": jnum(c.pid.to_double()), "at": jnum(c.at) }
      if c.since is Some(s) {
        o["since"] = jnum(s)
      }
      Json::object(o)
    })
  ignore(self.jnode("keepClaims", [Json::array(held)]))
}

///|
async fn Actors::tell_long(self : Actors) -> Unit raise {
  let now = self.stored_now()
  for c in @admit.overstaying(self.jobs.claims, now) {
    let key = "\{c.job} \{c.pid} \{c.since.unwrap_or(c.at)}"
    if self.jobs.told_long.contains(key) {
      continue
    }
    self.jobs.told_long[key] = true
    let job = self.jstore("getJob", [jstr(c.job)])
    if job is Null {
      continue
    }
    let waiting = self.jobs.claims.filter(w => !w.held).length()
    let mins = ((now - c.since.unwrap_or(c.at)) / 60000.0).round().to_int()
    let text = "\{named(job)} has held this machine's screen \{mins} min (its `stillfail-job screen` command, pid \{c.pid}) while \{waiting} other command\{if waiting == 1 { "" } else { "s" }} wait for it. The screen is for work done in minutes (screenshots, a scripted run, a simulator's tests); a window kept up for a person (a virtual machine, a simulator to look at) is `stillfail-job show <command>`'s, which holds nothing. Finish with the screen, or put the window up again that way."
    if str_of(job.value("sessionKey")).unwrap_or("").has_prefix("remote:") {
      ignore(self.jstore("addJobNotice", [jstr(c.job), jstr(text)]))
    } else {
      self.jtell(job, text)
    }
    self.jlog("info", "a command told it holds the screen long", fields={ "job": jstr(c.job), "pid": jnum(c.pid.to_double()), "waiting": jnum(waiting.to_double()) })
  }
}

///|
/// A job's command ended (jobs.ts `ended`): Node's word of it, by its id, its group (none: one it found ended), its
/// code (none: a signal), how long it ran.
async fn Actors::ended(self : Actors, id : String, pgid : Int?, code : Int?, ran_ms : Double) -> Json raise {
  if self.jobs.closing {
    return Json::null()
  }
  let run = self.jobs.running.get(id)
  self.jobs.running.remove(id)
  let stopped = match run {
    Some(r) => r.stopping
    None => false
  }
  self.ended_record(id, pgid, code, stopped, ran_ms)
  self.start_next()
  Json::null()
}

///|
async fn Actors::ended_record(self : Actors, id : String, pgid : Int?, code : Int?, stopped : Bool, ran_ms : Double) -> Unit raise {
  if pgid is Some(g) {
    ignore(self.jstore("forgetProcess", [jnum(g.to_double())]))
    ignore(self.jnode("signal", [jnum(g.to_double()), jstr("SIGTERM")]))
  }
  let job = self.jstore("getJob", [jstr(id)])
  if job is Null {
    return
  }
  let code_json = match code { Some(c) => jnum(c.to_double()); None => Json::null() }
  if stopped {
    ignore(self.jstore("jobEnded", [jstr(id), jstr("stopped"), code_json]))
    return self.remote_changed(id)
  }
  let said = match code { Some(c) => "exit code \{c}"; None => "a signal" }
  let lines = str_of(Some(self.jnode("tail", [job.value("log").unwrap_or(Json::null()), jnum(20.0)]))).unwrap_or("")
  let last = if lines == "" { "" } else { "\nIts last lines:\n```\n\{lines}\n```" }
  let restarts = num_of(job.value("restarts")).unwrap_or(0.0).to_int()
  if !has_port(job) {
    if truthy(self.jnode("lost", [jstr(id)])) && restarts == 0 {
      ignore(self.jstore("jobEnded", [jstr(id), jstr("exited"), code_json]))
      self.jtell(job, "\{named(job)} lost the connection to the sandbox it ran in (what it was running was ended); the station starts it again once.\{last}")
      self.jlog("info", "job's sandbox connection lost; starting it again", fields={ "job": jstr(id) })
      return self.spawn_job(self.jstore("getJob", [jstr(id)]), true, Json::object({}))
    }
    ignore(self.jstore("jobEnded", [jstr(id), jstr("exited"), code_json]))
    return self.jtell(job, "\{named(job)} ended with \{said}.\{last}")
  }
  let pause = @admit.restart_pause(restarts, ran_ms)
  ignore(self.jstore("jobEnded", [jstr(id), jstr("exited"), code_json]))
  let when = if pause == 0.0 { "" } else { " in \{(pause / 1000.0).to_int()} s" }
  self.jtell(job, "\{named(job)} ended with \{said}; the station starts it again\{when}.\{last}")
  ignore(
    self.after(pause, () => {
      self.spawn(() => {
        try {
          self.locked(() => {
          let now = self.jstore("getJob", [jstr(id)])
          if !(now is Null) && str_of(now.value("state")) == Some("exited") && !self.jobs.closing {
            try {
              self.spawn_job(now, true, Json::object({}))
            } catch {
              e => {
                let m = Asked::message(e)
                self.jlog("warn", "service not started again", fields={ "job": jstr(id), "error": jstr(m) })
                ignore(self.jstore("jobEnded", [jstr(id), jstr("failed"), Json::null()]))
                self.jtell(now, "\{named(now)} could not be started again: \{m}")
              }
            }
          }
          })
        } catch {
          _ => ()
        }
      })
    }),
  )
}

///|
/// jobs.ts `stop`.
async fn Actors::job_stop(self : Actors, id : String) -> Json raise {
  let (job, group) = self.locked(() => {
    let job = self.jstore("getJob", [jstr(id)])
    if job is Null {
      raise Asked({ "message": jstr("no job \{id}") })
    }
    match self.jobs.running.get(id) {
      Some(run) => {
        run.stopping = true
        ignore(self.jnode("signal", [jnum(run.pgid.to_double()), jstr("SIGTERM")]))
        (job, Some(run.pgid))
      }
      None => (job, None)
    }
  })
  match group {
    // (its group given STOP_GRACE_MS, then killed, and its end taken in here: Node's, on its clock)
    Some(pgid) => ignore(self.jnode("grace", [jstr(id), jnum(pgid.to_double())]))
    None => {
      // A service waiting to start again, or one on record only: it stays stopped. One an earlier station left
      // running and this one does not follow: its group is ended too.
      let state = str_of(job.value("state"))
      if state == Some("running") || state == Some("exited") {
        if num_of(job.value("pgid")) is Some(g) {
          ignore(self.jnode("endLeftBehind", [jnum(g), jstr(id)]))
        }
        self.locked(() => {
          ignore(self.jstore("jobEnded", [jstr(id), jstr("stopped"), job.value("exitCode").unwrap_or(Json::null())]))
          self.remote_changed(id)
        })
      }
    }
  }
  let now = self.jstore("getJob", [jstr(id)])
  if now is Null {
    job
  } else {
    now
  }
}

///|
/// jobs.ts `relaunch`: what still runs followed again, what ended meanwhile told, what is gone run again.
async fn Actors::relaunch(self : Actors) -> Json raise {
  // (the groups on record, which of them are still this station's: Node's to look at)
  let recorded = self.jnode("recordedGroups", [])
  let ours : Map[Int, Bool] = {}
  let groups : Map[Int, Json] = {}
  match recorded {
    Array(rows) =>
      for r in rows {
        let g = num_of(r.value("pgid")).unwrap_or(0.0).to_int()
        groups[g] = r
        if r.value("ours") is Some(True) {
          ours[g] = true
        }
      }
    _ => ()
  }
  self.locked(() => self.relaunched(groups, ours))
}

///|
async fn Actors::relaunched(self : Actors, groups : Map[Int, Json], ours : Map[Int, Bool]) -> Json raise {
  let followed : Map[Int, Bool] = {}
  let jobs = match self.jstore("jobsUp", []) {
    Array(rows) => rows
    _ => []
  }
  for job in jobs {
    if str_of(job.value("state")) != Some("running") || job.value("queued") is Some(True) {
      continue
    }
    let id = str_of(job.value("id")).unwrap_or("")
    let pgid = num_of(job.value("pgid")).map(n => n.to_int())
    match pgid {
      Some(g) if groups.contains(g) => {
        if ours.contains(g) {
          self.jlog("info", "job went on through the restart; following it again", fields={ "job": jstr(id), "pgid": jnum(g.to_double()) })
          ignore(self.jnode("follow", [jstr(id), jnum(g.to_double())]))
          self.jobs.running[id] = { pgid: g, stopping: false }
          followed[g] = true
          continue
        }
        ignore(self.jstore("forgetProcess", [jnum(g.to_double())]))
        match self.jnode("readExit", [jstr(id)]) {
          Number(code, ..) => {
            let now = self.stored_now()
            let ran = now - num_of(job.value("startedAt")).unwrap_or(now)
            let ran = if ran < 0.0 { 0.0 } else { ran }
            let code = code.to_int()
            self.spawn(() => try { ignore(self.locked(() => self.ended(id, None, Some(code), ran))) } catch { _ => () })
            continue
          }
          _ => ()
        }
      }
      _ => ()
    }
    if id.has_prefix("remote_") {
      ignore(self.jstore("jobEnded", [jstr(id), jstr("failed"), Json::null()]))
      self.remote_changed(id)
      continue
    }
    try {
      self.spawn_job(job, true, Json::object({}))
      self.jtell(job, "The station restarted; \{named(job)} was started again.")
    } catch {
      e => {
        let m = Asked::message(e)
        self.jlog("warn", "job not started again", fields={ "job": jstr(id), "error": jstr(m) })
        ignore(self.jstore("jobEnded", [jstr(id), jstr("failed"), Json::null()]))
        self.jtell(job, "The station restarted; \{named(job)} could not be started again: \{m}")
      }
    }
  }
  for job in jobs {
    if str_of(job.value("state")) != Some("exited") || !has_port(job) {
      continue
    }
    try {
      self.spawn_job(job, true, Json::object({}))
    } catch {
      e => {
        self.jlog("warn", "service not started again", fields={ "job": job.value("id").unwrap_or(Json::null()), "error": jstr(Asked::message(e)) })
        ignore(self.jstore("jobEnded", [job.value("id").unwrap_or(Json::null()), jstr("failed"), Json::null()]))
      }
    }
  }
  for g, entry in groups {
    if followed.contains(g) {
      continue
    }
    if ours.contains(g) {
      self.jlog("warn", "ending the group of a job no longer running", fields={ "pgid": jnum(g.to_double()), "label": entry.value("label").unwrap_or(Json::null()) })
      self.tell(jobs_key, "node.endGroup", [jnum(g.to_double())])
    }
    ignore(self.jstore("forgetProcess", [jnum(g.to_double())]))
  }
  self.start_next()
  Json::null()
}

///|
/// Claims as Node keeps them (jobs/screen.json, `heldClaims`): those that hold the screen.
fn claims_of_json(v : Json) -> Array[@admit.Claim] {
  let out : Array[@admit.Claim] = []
  if v is Array(rows) {
    for c in rows {
      match (c.value("job"), c.value("pid"), c.value("at")) {
        (Some(String(job)), Some(Number(pid, ..)), Some(Number(at, ..))) if pid == pid.to_int().to_double() =>
          out.push({ job, pid: pid.to_int(), at, held: true, since: num_of(c.value("since")) })
        _ => ()
      }
    }
  }
  out
}

