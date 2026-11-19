// What of this machine still.fail uses (station/src/resources/module.ts, resources/watch.ts `ResourceWatch`), as a
// part of the station: each look every process's CPU time, memory footprint and bytes read from and written to disk
// (sys.mbt `process_usage`, macOS's counts), what each used since the last look put to whose it is (a chat's: its
// jobs' groups and all under them, its agents' runners as the hub names them, what runs naming its directory; the
// station's: this process and its launcher). Looked at only while a page asks (within WANTED_MS) or follows, every
// LOOK_MS; the bytes the machine took in and sent out on its networks each look (live_p5_3_netstat.c, every interface
// but the loopback). GET /resources, POST /resources/processes/:pid/end, the overview's `machine` field. And the
// station's watch over its own memory (ops/self-memory.ts `SelfMemoryGovernor`): every SAMPLE_MS this process and its
// programs' resident memory with the machine's pressure; under pressure or past its soft limit what answers nothing
// let go (the readers' and the search's idle programs), the idle sessions' processes ended under the machine's
// pressure (the hub's `evictAllIdle`); past its hard limit SUSTAINED samples running, the launcher asked to hand over
// (SIGUSR2, ops/restart.ts `restarter`), the launcher's front past its own asked to start anew.

///|
let p53_look_every_ms : Int = 5000

///|
let p53_wanted_ms : Double = 30000.0

///|
let p53_history_ms : Double = 600000.0

///|
let p53_first_ms : Int = 1000

///|
let p53_kill_after_ms : Int = 5000

///|
/// A process of the machine's table (`ps -axo pid=,ppid=,pgid=,rss=,comm=`).
priv struct P53Proc {
  pid : Int
  ppid : Int
  pgid : Int
  bytes : Double
  command : String
}

///|
/// Whose a process is: a chat's, the agents', the app's, the station's.
priv struct P53Whose {
  key : String
  kind : String
  session : String?
}

///|
/// What a process had used so far at a look.
priv struct P53Used {
  cpu_ns : Double
  footprint : Double
  disk_read : Double?
  disk_written : Double?
  command : String
}

///|
priv struct P53Resources {
  bus : LiveBus
  jobs : P53Jobs
  /// The network's counters at the last look (bytes in, out).
  mut net_last : (Double, Double)?
  mut net_now : (Double, Double)
  mut net_read : Bool
  /// What lets go of the programs that answer nothing now (the search's), and the programs this station runs.
  mut trim_idle : async () -> Int
  mut programs : () -> Array[Int]
  mut last_relief : Double?
  mut over : Int
  mut front_over : Int
  mut handed_over : Bool
  started_at : Double
  mut last : Map[Int, P53Used]
  mut last_at : Double?
  mut seen : Map[Int, String]
  mut now : Json?
  mut history : Array[Json]
  mut wanted : Double
  mut going : Bool
  mut counted : Bool
  mut disk : Bool
  /// Who follows (a page's stream, GET /resources as events): told after each look, the looks going on while any does.
  followers : Map[Int, () -> Unit]
  mut next_follower : Int
}

///|
fn P53Resources::new(bus : LiveBus, jobs : P53Jobs) -> P53Resources {
  {
    bus,
    jobs,
    net_last: None,
    net_now: (0.0, 0.0),
    net_read: false,
    trim_idle: async fn() { 0 },
    programs: () => [],
    last_relief: None,
    over: 0,
    front_over: 0,
    handed_over: false,
    started_at: p53_clock(),
    last: Map([]),
    last_at: None,
    seen: Map([]),
    now: None,
    history: [],
    wanted: -1.0e300,
    going: false,
    counted: false,
    disk: false,
    followers: Map([]),
    next_follower: 0,
  }
}

///|
fn p53_clock() -> Double {
  p5_epoch_ms().to_double()
}

///|
fn P53Resources::attach(self : P53Resources) -> Unit {
  let bus = self.bus
  self.govern()
  bus.parts.routes([
    {
      meth: "GET",
      path: "/resources",
      answer: async fn(_r) {
        self.want()
        self.snapshot()
      },
    },
    {
      meth: "POST",
      path: "/resources/processes/:pid/end",
      answer: async fn(r) {
        let pid = match attempt(() => @string.parse_int(p53_text(p53_get(r, "params"), "pid"))) {
          Ok(n) => n
          Err(_) => raise P53Error("no such process")
        }
        let session = p53_text(p53_get(r, "body"), "session")
        if session == "" {
          raise P53Error("session required")
        }
        let name = self.end(pid, session)
        p53_obj([("pid", p53_i(pid)), ("name", p53_s(name))])
      },
    },
  ])
  // (the machine as Node's os module says it, with this station's own use: the overview's)
  ignore(
    attempt(() => bus.parts.overview("machine", async fn(_viewer, _lang) { self.view() })),
  )
}

///|
/// What the machine is and has now (cores, memory, load, the disk of the data directory) and the last look.
async fn P53Resources::view(self : P53Resources) -> Json {
  let m = machine()
  let disk = match disk_of(self.bus.data) {
    Some((free, total)) => p53_obj([("free", p53_n(free)), ("total", p53_n(total))])
    None => Json::null()
  }
  let cpus = match p53_get(m, "cpus") {
    Array(xs) => xs.length()
    _ => 0
  }
  p53_obj([
    ("platform", p53_s(platform())),
    ("arch", p53_s(arch())),
    ("hostname", p53_s(hostname())),
    ("cpus", p53_i(cpus)),
    ("cpuModel", match p53_get(m, "cpus") { Array([first, ..]) => p53_get(first, "model"); _ => Json::null() }),
    ("totalmem", p53_get(m, "totalmem")),
    ("freemem", p53_get(m, "freemem")),
    ("loadavg", p53_get(m, "loadavg")),
    ("uptime", p53_get(m, "uptime")),
    ("disk", disk),
    ("pressure", p53_opt(p53_pressure(self.bus.host))),
    ("station", p53_obj([("pid", p53_i(@drive.pid())), ("rss", p53_get(m, "rss")), ("footprint", p53_get(m, "footprint"))])),
    ("resources", self.snapshot()),
  ])
}

///|
/// The machine's processes (`ps`), none where they are not read.
async fn P53Resources::table(self : P53Resources) -> Array[P53Proc]? {
  guard p53_run(self.bus.host, "/bin/ps", ["-axo", "pid=,ppid=,pgid=,rss=,comm="]) is Some(out) else { return None }
  let rows = []
  for line in out.split("\n") {
    let words = line.to_string().split(" ").filter(w => w != "").map(w => w.to_string()).to_array()
    if words.length() < 5 {
      continue
    }
    let n = (i : Int) => attempt(() => @string.parse_int(words[i])).unwrap_or(-1)
    let rss = attempt(() => @string.parse_double(words[3])).unwrap_or(0.0)
    if n(0) < 0 {
      continue
    }
    rows.push({ pid: n(0), ppid: n(1), pgid: n(2), bytes: rss * 1024.0, command: words[4:].iter().join(" ") })
  }
  Some(rows)
}

///|
/// Each process's arguments (`ps -axo pid=,args=`).
async fn P53Resources::args(self : P53Resources) -> Map[Int, String] {
  let out : Map[Int, String] = Map([])
  guard p53_run(self.bus.host, "/bin/ps", ["-axo", "pid=,args="]) is Some(text) else { return out }
  for line in text.split("\n") {
    let l = line.to_string().trim_start(chars=" ").to_string()
    match l.find(" ") {
      Some(i) =>
        match attempt(() => @string.parse_int(l[:i].to_owned())) {
          Ok(pid) => out[pid] = l[i + 1:].to_owned()
          Err(_) => ()
        }
      None => ()
    }
  }
  out
}

///|
/// The agents' runners as the hub names them (`{runner, pid, session}`), none where no hub says.
async fn P53Resources::runners(self : P53Resources) -> Array[(Int, Int, String?)] {
  let said = (self.bus.hub_ask.val)("runners", Json::null()) catch { _ => Json::null() }
  match said {
    Array(rows) =>
      rows.filter_map(r => match (p53_num(r, "runner"), p53_num(r, "pid")) {
        (Some(a), Some(b)) => Some((a.to_int(), b.to_int(), p53_str(r, "session")))
        _ => None
      })
    _ => []
  }
}

///|
/// Each process's whose (resources/watch.ts `whoseOf`): the jobs' groups first, then the runners, the station, each
/// with all under it; then what is left that names a chat's directory.
async fn P53Resources::whose_of(self : P53Resources, table : Array[P53Proc], runners : Array[(Int, Int, String?)]) -> Map[Int, P53Whose] {
  let by_pid : Map[Int, P53Proc] = Map([])
  let children : Map[Int, Array[Int]] = Map([])
  for p in table {
    by_pid[p.pid] = p
    match children.get(p.ppid) {
      Some(c) => c.push(p.pid)
      None => children[p.ppid] = [p.pid]
    }
  }
  let out : Map[Int, P53Whose] = Map([])
  let give = (roots : Array[Int], whose : P53Whose) => {
    let queue = roots.copy()
    while queue.pop() is Some(pid) {
      if out.contains(pid) || !by_pid.contains(pid) {
        continue
      }
      out[pid] = whose
      for c in children.get(pid).unwrap_or([]) {
        queue.push(c)
      }
    }
  }
  let chat = (session : String) => { key: "chat:\{session}", kind: "chat", session: Some(session) }
  for j in self.jobs.store().jobs_up() catch { _ => [] } {
    match p53_num(j, "pgid") {
      Some(g) => give(table.filter(p => p.pgid == g.to_int()).map(p => p.pid), chat(p53_text(j, "sessionKey")))
      None => ()
    }
  }
  for r in runners {
    give([r.0, r.1], match r.2 { Some(s) => chat(s); None => { key: "agents", kind: "agents", session: None } })
  }
  let launcher = parent_pid()
  give([@drive.pid()] + (if launcher > 1 { [launcher] } else { [] }), { key: "station", kind: "station", session: None })
  // (what is left naming a chat's directory, the longest it names, from the top: a script and all it runs)
  let places = (self.jobs.store().live_sessions() catch { _ => [] })
    .filter_map(s => match p53_str(s, "workspace") {
      Some(w) if w != "/" && w != homedir() => Some((if w.has_suffix("/") { w } else { w + "/" }, p53_text(s, "key")))
      _ => None
    })
  places.sort_by((a, b) => b.0.length().compare(a.0.length()))
  if places.length() > 0 {
    let args = self.args()
    for p in table {
      if out.contains(p.pid) || out.contains(p.ppid) {
        continue
      }
      guard args.get(p.pid) is Some(line) else { continue }
      for d in places {
        if line.contains(d.0) {
          give([p.pid], chat(d.1))
          break
        }
      }
    }
  }
  out
}

///|
/// A page asks: looked at every LOOK_MS for a while; woken, looked at now and again FIRST_MS later, for what was used
/// meanwhile, before it answers.
async fn P53Resources::want(self : P53Resources) -> Unit {
  self.wanted = p53_clock()
  if self.going {
    return
  }
  self.going = true
  if !self.fresh() {
    self.look()
    @effect.sleep(p53_first_ms) // timer: a sample of this machine (what was used since the first look)
  }
  self.look()
  ignore(
    self.bus.host.rt.fork_daemon("resources", on_error=e => @host.note("resources failed: \{e}"), async fn() {
      while (self.followers.length() > 0 || p53_clock() - self.wanted < p53_wanted_ms) && !self.bus.stopped.is_done() {
        @effect.sleep(p53_look_every_ms) // timer: a sample of this machine while a page asks
        self.look()
        for _, told in self.followers {
          told()
        }
      }
      self.going = false
    }),
  )
}

///|
/// resources/watch.ts `follow`: `told` after each look from the first on, until what it gives is called.
async fn P53Resources::follow(self : P53Resources, told : () -> Unit) -> () -> Unit {
  self.next_follower += 1
  let id = self.next_follower
  self.followers[id] = told
  ignore(
    self.bus.host.rt.fork_daemon("resources followed", on_error=e => @host.note("resources followed failed: \{e}"), async fn() {
      self.want()
      if self.followers.contains(id) {
        told()
      }
    }),
  )
  () => self.followers.remove(id)
}

///|
fn P53Resources::fresh(self : P53Resources) -> Bool {
  match self.last_at {
    Some(at) => p53_clock() - at <= 3.0 * p53_look_every_ms.to_double()
    None => false
  }
}

///|
fn p53_use(cpu : Double, memory : Double, read : Double, write : Double) -> Map[String, Json] {
  {
    "cpu": p53_n(cpu),
    "memory": p53_n(memory),
    "netIn": p53_n(0.0),
    "netOut": p53_n(0.0),
    "diskRead": p53_n(read),
    "diskWrite": p53_n(write),
  }
}

///|
fn p53_add_use(to : Map[String, Json], u : Map[String, Json]) -> Unit {
  for k in ["cpu", "memory", "netIn", "netOut", "diskRead", "diskWrite"] {
    let a = match to.get(k) { Some(Number(n, ..)) => n; _ => 0.0 }
    let b = match u.get(k) { Some(Number(n, ..)) => n; _ => 0.0 }
    to[k] = p53_n(a + b)
  }
}

///|
/// One look (resources/watch.ts `look`).
async fn P53Resources::look(self : P53Resources) -> Unit {
  let fresh = self.fresh()
  guard self.table() is Some(table) else { return }
  let at = p53_clock()
  let runners = self.runners()
  let whose = self.whose_of(table, runners)
  let agents_own = runners.map(r => r.0) + runners.map(r => r.1)
  let mine = table.filter(p => whose.contains(p.pid))
  let used = process_usage(mine.map(p => p.pid))
  let since = if fresh { self.last_at } else { None }
  let seconds = match since {
    Some(s) => (at - s) / 1000.0
    None => 0.0
  }
  let groups : Map[String, (P53Whose, Map[String, Json], Array[Json])] = Map([])
  let last : Map[Int, P53Used] = Map([])
  for i, p in mine {
    guard used[i] is Some(read) else { continue }
    let u : P53Used = {
      cpu_ns: p53_num(read, "cpuNs").unwrap_or(0.0),
      footprint: p53_num(read, "footprint").unwrap_or(p.bytes),
      disk_read: p53_num(read, "diskRead"),
      disk_written: p53_num(read, "diskWritten"),
      command: p.command,
    }
    self.counted = true
    if u.disk_read is Some(_) {
      self.disk = true
    }
    last[p.pid] = u
    if since is None || seconds <= 0.0 {
      continue
    }
    let w = whose[p.pid]
    let before = self.last.get(p.pid)
    let same = match before {
      Some(b) => b.command == p.command && b.cpu_ns <= u.cpu_ns
      None => false
    }
    if !same && self.seen.get(p.pid) == Some(p.command) {
      continue
    }
    let was = if same { before } else { None }
    let d = (now : Double, then : Double?) => {
      let v = (now - then.unwrap_or(0.0)) / seconds
      if v < 0.0 { 0.0 } else { v }
    }
    let use_ = p53_use(
      d(u.cpu_ns, was.map(x => x.cpu_ns)) / 1.0e9 * 100.0,
      u.footprint,
      d(u.disk_read.unwrap_or(0.0), was.bind(x => x.disk_read)),
      d(u.disk_written.unwrap_or(0.0), was.bind(x => x.disk_written)),
    )
    let g = match groups.get(w.key) {
      Some(g) => g
      None => {
        let g = (w, p53_use(0.0, 0.0, 0.0, 0.0), [])
        groups[w.key] = g
        g
      }
    }
    p53_add_use(g.1, use_)
    let one = use_.copy()
    one["pid"] = p53_i(p.pid)
    one["name"] = p53_s(@nodepath.basename("/", p.command))
    one["endable"] = p53_b(w.kind == "chat" && !agents_own.contains(p.pid))
    g.2.push(Json::object(one))
  }
  self.last = last
  self.last_at = Some(at)
  self.seen = Map::from_array(table.map(p => (p.pid, p.command)))
  if since is None {
    return
  }
  let total = p53_use(0.0, 0.0, 0.0, 0.0)
  match p53_net_bytes() {
    Some((i, o)) => {
      self.net_read = true
      match self.net_last {
        Some((li, lo)) if seconds > 0.0 => {
          let rate = (now : Double, then : Double) => if now >= then { (now - then) / seconds } else { 0.0 }
          self.net_now = (rate(i, li), rate(o, lo))
        }
        _ => ()
      }
      self.net_last = Some((i, o))
      total["netIn"] = p53_n(self.net_now.0)
      total["netOut"] = p53_n(self.net_now.1)
    }
    None => self.net_read = false
  }
  let cpu_of = (j : Json) => p53_num(j, "cpu").unwrap_or(0.0)
  let list = groups.values().map(g => {
    p53_add_use(total, g.1)
    let o = g.1.copy()
    o["key"] = p53_s(g.0.key)
    o["kind"] = p53_s(g.0.kind)
    o["session"] = p53_opt(g.0.session)
    let ps = g.2.copy()
    ps.sort_by((a, b) => cpu_of(b).compare(cpu_of(a)))
    o["processes"] = Json::array(ps)
    Json::object(o)
  }).to_array()
  list.sort_by((a, b) => cpu_of(b).compare(cpu_of(a)))
  self.now = Some(p53_obj([("at", p53_n(at)), ("groups", Json::array(list)), ("total", Json::object(total))]))
  let point = total.copy()
  point["at"] = p53_n(at)
  self.history.push(Json::object(point))
  self.history = self.history.filter(p => p53_num(p, "at").unwrap_or(0.0) > at - p53_history_ms)
}

///|
/// Ends a chat's process (`session`'s, not its agent's own), as it is now: SIGTERM, then SIGKILL if it is still there
/// KILL_AFTER_MS later.
async fn P53Resources::end(self : P53Resources, pid : Int, session : String) -> String {
  guard self.table() is Some(table) else { raise P53Error("gone") }
  guard table.search_by(p => p.pid == pid) is Some(i) else { raise P53Error("gone") }
  let now = table[i]
  let runners = self.runners()
  let w = self.whose_of(table, runners).get(pid)
  let own = runners.iter().any(r => r.0 == pid || r.1 == pid)
  match w {
    Some(w) if w.kind == "chat" && w.session == Some(session) && !own => ()
    _ => raise P53Error("not a chat's")
  }
  ignore(kill(pid, "SIGTERM"))
  ignore(
    self.bus.host.rt.fork_daemon("a process ended", on_error=e => @host.note("a process ended failed: \{e}"), async fn() {
      @effect.sleep(p53_kill_after_ms) // timer: a deadline to a process
      match self.table() {
        Some(t) =>
          match t.search_by(p => p.pid == pid) {
            Some(j) if t[j].command == now.command => ignore(kill(pid, "SIGKILL"))
            _ => ()
          }
        None => ()
      }
    }),
  )
  @nodepath.basename("/", now.command)
}

///|
/// The last look and the history, the oldest first (resources/watch.ts `snapshot`).
fn P53Resources::snapshot(self : P53Resources) -> Json {
  let zero = Json::object(p53_use(0.0, 0.0, 0.0, 0.0))
  p53_obj([
    ("at", match self.now { Some(n) => p53_get(n, "at"); None => Json::null() }),
    ("everyMs", p53_i(p53_look_every_ms)),
    ("counted", p53_b(self.counted)),
    ("net", p53_b(self.net_read)),
    ("disk", p53_b(self.disk)),
    ("total", match self.now { Some(n) => p53_get(n, "total"); None => zero }),
    ("groups", match self.now { Some(n) => p53_get(n, "groups"); None => Json::array([]) }),
    ("history", Json::array(self.history.copy())),
  ])
}

///|
#borrow(out)
extern "C" fn p53_net_bytes_ffi(out : FixedArray[Double]) -> Int = "sfp53_net_bytes"

///|
/// The bytes this machine took in and sent out on its networks so far (every interface but the loopback).
fn p53_net_bytes() -> (Double, Double)? {
  let out = FixedArray::make(2, 0.0)
  if p53_net_bytes_ffi(out) != 0 {
    return None
  }
  Some((out[0], out[1]))
}

// ── the station's own memory (ops/self-memory.ts) ──

///|
let p53_sample_ms : Int = 30000

///|
let p53_relief_ms : Double = 60000.0

///|
let p53_sustained : Int = 3

///|
let p53_startup_ms : Double = 600000.0

///|
let p53_gib : Double = 1073741824.0

///|
fn p53_clamp(n : Double, low : Double, high : Double) -> Double {
  if n < low {
    low
  } else if n > high {
    high
  } else {
    n
  }
}

///|
/// The governor's limits of a machine with `total` bytes (self-memory.ts `softLimitOf`, `hardRssOf`, `hardFrontOf`).
fn p53_memory_limits(total : Double) -> (Double, Double, Double) {
  (
    p53_clamp((total * 0.2).floor(), 2.0 * p53_gib, 6.0 * p53_gib),
    p53_clamp((total * 0.3).floor(), 3.0 * p53_gib, 8.0 * p53_gib),
    p53_clamp((total * 0.1).floor(), 1.0 * p53_gib, 3.0 * p53_gib),
  )
}

///|
/// The resident bytes of `pids` and all under them in `table` (resources/module.ts `programsIn`).
fn p53_programs_in(table : Array[P53Proc], pids : Array[Int]) -> Double {
  let children : Map[Int, Array[Int]] = Map([])
  let by_pid : Map[Int, P53Proc] = Map([])
  for p in table {
    by_pid[p.pid] = p
    match children.get(p.ppid) {
      Some(c) => c.push(p.pid)
      None => children[p.ppid] = [p.pid]
    }
  }
  let seen : Map[Int, Bool] = Map([])
  let queue = pids.copy()
  let mut bytes = 0.0
  while queue.pop() is Some(pid) {
    if seen.contains(pid) {
      continue
    }
    seen[pid] = true
    match by_pid.get(pid) {
      Some(p) => bytes += p.bytes
      None => ()
    }
    for c in children.get(pid).unwrap_or([]) {
      queue.push(c)
    }
  }
  bytes
}

///|
/// The launcher's pid, where `run/station.json` names one that takes a handover (ops/restart.ts `restarter`).
async fn P53Resources::launcher(self : P53Resources) -> Int? {
  guard p53_read(self.bus.host, @nodepath.join(sep(), [self.bus.data, "run", "station.json"])) is Some(t) else { return None }
  guard attempt(() => @json.parse(t)) is Ok(said) else { return None }
  guard p53_num(said, "pid") is Some(pid) && pid > 0.0 && p53_num(said, "handoff") == Some(1.0) else { return None }
  let pid = pid.to_int()
  match p53_run(self.bus.host, "/bin/ps", ["-o", "comm=", "-p", pid.to_string()]) {
    Some(comm) if @nodepath.basename("/", comm.trim_space().to_string()).has_prefix("stillfail") => Some(pid)
    _ => None
  }
}

///|
/// The watch over the station's own memory started (self-memory.ts `start`).
fn P53Resources::govern(self : P53Resources) -> Unit {
  let bus = self.bus
  ignore(
    bus.host.rt.fork_daemon("the station's memory", on_error=e => @host.note("the station's memory failed: \{e}"), async fn() {
      while !bus.stopped.is_done() {
        @effect.sleep(p53_sample_ms) // timer: a sample of this machine (the station's own memory)
        ignore(self.sample()) catch {
          e => p53_log("warn", "memory", "the station's memory not looked at", fields=p53_obj([("error", p53_s(p53_words(e)))]))
        }
      }
    }),
  )
}

///|
/// One sample (self-memory.ts `sample`): what was done of it.
async fn P53Resources::sample(self : P53Resources) -> Json {
  let bus = self.bus
  let now = p53_clock()
  let m = machine()
  let total = p53_num(m, "totalmem").unwrap_or(0.0)
  let (soft, hard_rss, hard_front) = p53_memory_limits(total)
  let own = p53_num(m, "rss").unwrap_or(0.0)
  let table = self.table().unwrap_or([])
  let children = p53_programs_in(table, (self.programs)())
  let launcher = self.launcher()
  let front = match launcher {
    Some(l) =>
      match table.search_by(p => p.ppid == l && p.pid != @drive.pid() && @nodepath.basename("/", p.command).has_prefix("stillfail-reade")) {
        Some(i) => Some(table[i].bytes)
        None => None
      }
    None => None
  }
  let pressure = p53_pressure(bus.host)
  let whole = own + children
  let pressed = pressure == Some("high") || pressure == Some("critical")
  let out : Map[String, Json] = {
    "wholeRssMb": p53_n((whole / p53_mib).round()),
    "mbChildrenRssMb": p53_n((children / p53_mib).round()),
    "pressure": p53_opt(pressure),
  }
  let relieved = match self.last_relief {
    Some(at) => now - at >= p53_relief_ms
    None => true
  }
  if (pressed || whole + front.unwrap_or(0.0) > soft) && relieved {
    self.last_relief = Some(now)
    let trimmed = (self.trim_idle)()
    let trimmed_readers = match (try { Ok((bus.reader_ask.val)("trimIdle", Json::null(), (bus.lang.val)())) } catch { e => Err(e) }) {
      Ok(Number(n, ..)) => n.to_int()
      _ => 0
    }
    out["trimmed"] = p53_i(trimmed + trimmed_readers)
    if pressed {
      out["evictedWarm"] = (bus.hub_ask.val)("evictAllIdle", Json::null()) catch { _ => Json::null() }
    }
    p53_log("info", "memory", "station trimmed idle helpers under memory pressure", fields=Json::object(out))
  }
  let started = now - self.started_at >= p53_startup_ms
  self.front_over = match front {
    Some(f) if f > hard_front => self.front_over + 1
    _ => 0
  }
  if self.front_over >= p53_sustained && started {
    self.front_over = 0
    p53_log("warn", "memory", "mesh front exceeded sustained memory limit", fields=Json::object(out))
    match bus.restart_front {
      Some(restart) => {
        restart()
        out["front"] = p53_s("asked")
      }
      None => out["front"] = p53_s("said")
    }
  }
  self.over = if whole > hard_rss { self.over + 1 } else { 0 }
  if self.handed_over || self.over < p53_sustained || !started {
    return Json::object(out)
  }
  self.over = 0
  match launcher {
    None => {
      p53_log("warn", "memory", "station process exceeded sustained memory limit; no launcher to hand over to, trimming idle helpers", fields=Json::object(out))
      out["trimmed"] = p53_i((self.trim_idle)())
      out["handover"] = p53_s("none")
    }
    Some(pid) => {
      self.handed_over = true
      p53_log("warn", "memory", "station process exceeded sustained memory limit; asking launcher to hand over", fields=Json::object(out))
      if !kill(pid, "SIGUSR2") {
        self.handed_over = false
      }
      out["handover"] = p53_s("asked")
    }
  }
  Json::object(out)
}
