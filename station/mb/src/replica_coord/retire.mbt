// A station retired from a workspace, its chats going on on another station of it that a person chose (retire.ts;
// replica/AGENTS.md). On the station retired: what goes along is sent while its agents still work, then (confirmed) its
// chats stop, what changed goes, their copy, and the other station is asked to take them; its accounts and connects
// follow. On the station the chats go to: what goes along is put in place, the linked worktrees made again by git, and
// the copy put in beside its own chats as it starts again. Where each side stands is kept in a file, so a restart goes
// on with it.

///|
pub let retire_retry_ms : Double = 10000.0

///|
pub let retire_retry_most_ms : Double = 600000.0

///|
pub let quiet_unreached_ms : Double = 60000.0

///|
pub let retire_tell_ms : Double = 1000.0

///|
pub let headroom : Double = 1073741824.0

///|
pub let lack_most = 2000

///|
pub let restarts_most = 2

///|
pub let accounts_wait_ms : Double = 120000.0

///|
let taken_kept = 10

///|
fn stopped_step(step : String) -> Bool {
  step != "sending" && step != "sent"
}

///|
let taking_held_steps : Array[String] = ["placing", "gits", "copy", "restart"]

///|
/// Who asked for a retirement with station_retire.
pub struct Driver {
  station : String
  session : String
}

///|
fn driver_json(d : Driver?) -> J {
  match d {
    Some(x) => jo([("station", js(x.station)), ("session", js(x.session))])
    None => Null
  }
}

///|
fn driver_of(v : J?) -> Driver? {
  match v {
    Some(Obj(_) as o) => Some({ station: text_at(o, "station"), session: text_at(o, "session") })
    _ => None
  }
}

///|
/// Where this station stands in being retired (retire.ts `State`).
struct RetireState {
  workspace : String
  to : String
  to_name : String
  by : String
  at : Double
  mut step : String
  mut done : Double
  mut total : Double
  mut error : String?
  mut reason : String?
  mut jobs : Array[J]
  mut take : J?
  mut accounts_left : Array[J]
  mut wait : Bool
  mut driver : Driver?
  owed : Array[String]
  mut files : Double
  mut sent_at : Double?
  mut retake : Bool
  mut jobs_there : J?
  mut told_error : String?
  mut accounts_moved : Array[J]
  mut accounts_told : Bool
}

///|
fn opt_num(v : Double?) -> J {
  match v {
    Some(n) => jn(n)
    None => Null
  }
}

///|
fn RetireState::to_json(self : RetireState) -> J {
  jo([
    ("workspace", js(self.workspace)),
    ("to", js(self.to)),
    ("toName", js(self.to_name)),
    ("by", js(self.by)),
    ("at", jn(self.at)),
    ("step", js(self.step)),
    ("done", jn(self.done)),
    ("total", jn(self.total)),
    ("error", jopt(self.error)),
    ("reason", jopt(self.reason)),
    ("jobs", ja(self.jobs)),
    ("take", self.take.unwrap_or(Null)),
    ("accountsLeft", ja(self.accounts_left)),
    ("wait", jb(self.wait)),
    ("driver", driver_json(self.driver)),
    ("owed", jstrs(self.owed)),
    ("files", jn(self.files)),
    ("sentAt", opt_num(self.sent_at)),
    ("retake", jb(self.retake)),
    ("jobsThere", self.jobs_there.unwrap_or(Null)),
    ("toldError", jopt(self.told_error)),
    ("accountsMoved", ja(self.accounts_moved)),
    ("accountsTold", jb(self.accounts_told)),
  ])
}

///|
fn RetireState::of_json(v : J) -> RetireState {
  {
    workspace: text_at(v, "workspace"),
    to: text_at(v, "to"),
    to_name: text_at(v, "toName"),
    by: text_at(v, "by"),
    at: num_at(v, "at").unwrap_or(0.0),
    step: text_at(v, "step"),
    done: num_at(v, "done").unwrap_or(0.0),
    total: num_at(v, "total").unwrap_or(0.0),
    error: str_at(v, "error"),
    reason: str_at(v, "reason"),
    jobs: items(at(v, "jobs")),
    take: match at(v, "take") {
      Some(Null) | None => None
      x => x
    },
    accounts_left: items(at(v, "accountsLeft")),
    wait: yes_at(v, "wait"),
    driver: driver_of(at(v, "driver")),
    owed: strings_of(at(v, "owed")),
    files: num_at(v, "files").unwrap_or(0.0),
    sent_at: num_at(v, "sentAt"),
    retake: yes_at(v, "retake"),
    jobs_there: match at(v, "jobsThere") {
      Some(Arr(_)) as x => x
      _ => None
    },
    told_error: str_at(v, "toldError"),
    accounts_moved: items(at(v, "accountsMoved")),
    accounts_told: yes_at(v, "accountsTold"),
  }
}

///|
/// What a station taking another's chats keeps of it (retire.ts `Taking`).
struct Taking {
  origin : String
  mut name : String
  workspace : String
  mut gen : String
  mut carry : String
  mut connects : Array[(String, String)]
  mut bindings : Array[(String, String)]
  mut step : String
  mut placed : Double
  mut missing : Double
  mut gits : Int
  mut gits_failed : Int
  mut rooms : Array[String]?
  mut error : String?
  mut told : Bool
  mut restarts : Int
  mut driver : Driver?
  mut jobs : Array[J]?
  mut jobs_told : Bool
  mut home : Bool
  mut driver_told : Bool
  mut failed_at : String?
  mut accounts : Bool?
}

///|
fn Taking::to_json(self : Taking) -> J {
  jo([
    ("origin", js(self.origin)),
    ("name", js(self.name)),
    ("workspace", js(self.workspace)),
    ("gen", js(self.gen)),
    ("carry", js(self.carry)),
    ("connects", pairs_json(self.connects)),
    ("bindings", pairs_json(self.bindings)),
    ("step", js(self.step)),
    ("placed", jn(self.placed)),
    ("missing", jn(self.missing)),
    ("gits", ji(self.gits)),
    ("gitsFailed", ji(self.gits_failed)),
    ("rooms", match self.rooms { Some(r) => jstrs(r); None => Null }),
    ("error", jopt(self.error)),
    ("told", jb(self.told)),
    ("restarts", ji(self.restarts)),
    ("driver", driver_json(self.driver)),
    ("jobs", match self.jobs { Some(j) => ja(j); None => Null }),
    ("jobsTold", jb(self.jobs_told)),
    ("home", jb(self.home)),
    ("driverTold", jb(self.driver_told)),
    ("failedAt", jopt(self.failed_at)),
    ("accounts", match self.accounts { Some(b) => jb(b); None => Null }),
  ])
}

///|
fn Taking::of_json(v : J) -> Taking {
  {
    origin: text_at(v, "origin"),
    name: text_at(v, "name"),
    workspace: text_at(v, "workspace"),
    gen: text_at(v, "gen"),
    carry: text_at(v, "carry"),
    connects: string_map(at(v, "connects")),
    bindings: string_map(at(v, "bindings")),
    step: text_at(v, "step"),
    placed: num_at(v, "placed").unwrap_or(0.0),
    missing: num_at(v, "missing").unwrap_or(0.0),
    gits: num_at(v, "gits").unwrap_or(0.0).to_int(),
    gits_failed: num_at(v, "gitsFailed").unwrap_or(0.0).to_int(),
    rooms: match at(v, "rooms") {
      Some(Arr(_) as r) => Some(strings_of(Some(r)))
      _ => None
    },
    error: str_at(v, "error"),
    told: yes_at(v, "told"),
    restarts: num_at(v, "restarts").unwrap_or(0.0).to_int(),
    driver: driver_of(at(v, "driver")),
    jobs: match at(v, "jobs") {
      Some(Arr(xs)) => Some(xs)
      _ => None
    },
    jobs_told: yes_at(v, "jobsTold"),
    home: yes_at(v, "home"),
    driver_told: yes_at(v, "driverTold"),
    failed_at: str_at(v, "failedAt"),
    accounts: match at(v, "accounts") {
      Some(Bool(b)) => Some(b)
      _ => None
    },
  }
}

///|
/// What the chats' copy is to a retirement (copies.ts).
pub(all) struct RetireCopies {
  settle_export : async () -> Unit
  bring_to : async (String, String) -> String
  take_over : async (String, String, String, Array[(String, String)], String?) -> Unit
  formerly : () -> Array[String]
  restored : () -> J?
}

///|
/// The jobs of the station (jobs.ts), as a retirement starts them again.
pub(all) struct RetireJobs {
  start : async (String, J) -> J
  running : async (String, String, String) -> Bool
  say : async (String, String) -> Unit
}

///|
/// What Retire is given (retire.ts `RetireDeps`).
pub(all) struct RetireDeps {
  data : String
  here : () -> String?
  home : () -> String?
  roster : (String) -> Array[Member]?
  copies : RetireCopies
  quiet : async (String) -> Array[J]
  unquiet : async (String) -> Unit
  retired : async (String) -> Unit
  accounts_own : async () -> Array[(String, String)]
  accounts_move : async (String, String) -> J
  follow_accounts : (async (Array[String], Array[(String, String)]) -> Int)?
  connects_of : async (String) -> Array[String]
  bindings_of : async (Array[String]) -> Array[(String, String)]
  move_connects : async (String, String) -> Unit
  took : async (J, J) -> Unit
  repos_dir : String
  room : async () -> (Double?, Bool)
  has_git : async () -> Bool
  git : async (String, Array[String]) -> String
  lack_most : Int
  work : Work
  jobs_in : async (String) -> Array[J]
  connects_named : async (String) -> Array[J]
  tell : (async (String, String) -> Unit)?
  jobs : RetireJobs?
  agent_home : (async (String) -> String?)?
  drives : (String, String) -> Bool
  of_workspace : (async (String, String) -> Bool)?
  hold : () -> () -> Unit
  changed : () -> Unit
  used : async (String, String, Bool) -> Array[String]
}

///|
pub struct Retire {
  w : World
  d : RetireDeps
  carried : FolderPlace
  mut state : RetireState?
  mut running : Run?
  mut more : Bool
  mut stopping : Bool
  mut again : (() -> Unit)?
  mut tries : Int
  mut unreached_since : Double?
  mut retiring_held : (() -> Unit)?
  taking_held : Map[String, () -> Unit]
  mut sending_failed_since : Double?
  mut writes : Run
  mut driving : Run?
  mut driver_again : (() -> Unit)?
  mut driver_tries : Int
  mut retake : Bool
  mut closed : Bool
  taking : Map[String, Taking]
  taking_runs : Map[String, Run]
  take_again : Map[String, () -> Unit]
  tell_runs : Map[String, Run]
  tell_again : Map[String, () -> Unit]
  mut drops : Array[J]
  mut took_here : Array[J]
  mut dropping : Run?
  mut drop_again : (() -> Unit)?
  mut drop_tries : Int
  mut telling : (() -> Unit)?
  wakes : Map[String, J]
  wake_at : Map[String, () -> Unit]
  waking : Array[Run]
}

///|
fn retiring_file(fs : Fs, data : String) -> String {
  fs.join([data, "replica", "retiring.json"])
}

///|
fn taking_dir(fs : Fs, data : String) -> String {
  fs.join([data, "replica", "taking"])
}

///|
fn drops_file(fs : Fs, data : String) -> String {
  fs.join([data, "replica", "drops-owed.json"])
}

///|
fn carry_root(fs : Fs, data : String) -> String {
  fs.join([data, "replica", "carry"])
}

///|
fn taken_file(fs : Fs, data : String) -> String {
  fs.join([data, "replica", "taken.json"])
}

///|
fn scratch_dir(fs : Fs, data : String) -> String {
  fs.join([data, "replica", "carrying"])
}

///|
fn took_dir(fs : Fs, data : String) -> String {
  fs.join([data, "replica", "took"])
}

///|
fn keys_file(fs : Fs, data : String, origin : String) -> String {
  fs.join([took_dir(fs, data), "\{origin}.keys"])
}

///|
fn wake_file(fs : Fs, data : String, origin : String) -> String {
  fs.join([took_dir(fs, data), "\{origin}.json"])
}

///|
/// What came of a moved chat's jobs on the station they went to, in a sentence.
pub fn job_words(jobs : Array[J]) -> String {
  if jobs.length() == 0 {
    return ""
  }
  let started = jobs.filter(j => yes_at(j, "started")).map(j => text_at(j, "name"))
  let not = jobs
    .filter(j => !yes_at(j, "started"))
    .map(j => {
      let why = if yes_at(j, "old") {
        "from a station before jobs moved"
      } else {
        str_at(j, "why").unwrap_or("not started")
      }
      "\{text_at(j, "name")} (\{why})"
    })
  [
    if started.length() > 0 { "Jobs started again there: \{started.join(", ")}." } else { "" },
    if not.length() > 0 { "Not started again: \{not.join("; ")}." } else { "" },
  ]
  .filter(x => x != "")
  .join(" ")
}

///|
/// What a moved chat's agent is told once (retire.ts `movedNote`).
pub fn moved_note(fs : Fs, from : String, here : String, index : J, s : J, data : String, repos_dir : String, jobs : Array[J]?) -> String {
  let lines = [
    "<chat-moved>This chat moved here from station \{if from != "" { from } else { "(retired)" }}, which was retired from this workspace: it goes on on this station\{if here != "" { " (\{here})" } else { "" }}.",
  ]
  let index_data = text_at(index, "dataDir")
  if at(s, "room") is (Some(Null) | None) {
    lines.push("Its working directory \{text_at(s, "workspace")} was not the station's own and did not move: it is not on this machine unless it was here already.")
  } else {
    lines.push("Its files were under \{index_data} and are under \{data} now: a path you noted under the old one is the same under the new one (your working directory is \{moved(fs, text_at(s, "workspace"), index_data, data)}).")
  }
  lines.push("A git worktree that still names the old place is mended with `git worktree repair <its directory>` run in its repository under \{repos_dir}.")
  let named = (j : J) => "\{text_at(j, "name")} (`\{text_at(j, "command")}`)"
  let key = text_at(s, "key")
  let mine = items(at(index, "jobs")).filter(j => text_at(j, "session") == key)
  let outcomes = jobs.map(js => js.filter(j => text_at(j, "session") == key))
  let not_moved = match outcomes {
    None => mine
    Some(o) => o.filter(j => yes_at(j, "old"))
  }
  if not_moved.length() > 0 {
    lines.push("These background jobs and services of it did not move and are not running: \{not_moved.map(named).join("; ")}. Start again those still needed.")
  }
  let started = outcomes.unwrap_or([]).filter(j => yes_at(j, "started"))
  if started.length() > 0 {
    let said = started.map(j => match at(j, "id") {
      Some(Str(u)) => "\{named(j)}, \{@jsjson.sanitize_str(u)}"
      _ => named(j)
    })
    lines.push("These background jobs and services of it were started again here, as after a restart of the station, in the same directories under the new place: \{said.join("; ")}.")
  }
  let not = outcomes.unwrap_or([]).filter(j => !yes_at(j, "started") && !yes_at(j, "old"))
  if not.length() > 0 {
    lines.push("These were not started again: \{not.map(j => "\{named(j)}: \{str_at(j, "why").unwrap_or("not started")}").join("; ")}. Start again those still needed.")
  }
  lines.push("It is said once; nobody asked anything of you by it.</chat-moved>")
  lines.join("\n")
}

///|
fn full_error(message : String) -> Thrown {
  Thrown("Full", jo([("message", js(message))]))
}

///|
pub async fn Retire::new(w : World, d : RetireDeps) -> Retire {
  let fs = w.fs
  let state = match fs.read_json(retiring_file(fs, d.data)) {
    Some(Obj(_) as v) => Some(RetireState::of_json(v))
    _ => None
  }
  let drops = match fs.read_json(drops_file(fs, d.data)) {
    Some(Arr(xs)) => xs
    _ => []
  }
  let took_here = match fs.read_json(taken_file(fs, d.data)) {
    Some(Arr(xs)) => xs
    _ => []
  }
  let r : Retire = {
    w,
    d,
    carried: FolderPlace::new(fs, carry_root(fs, d.data)),
    state,
    running: None,
    more: false,
    stopping: false,
    again: None,
    tries: 0,
    unreached_since: None,
    retiring_held: None,
    taking_held: {},
    sending_failed_since: None,
    writes: Run::over(),
    driving: None,
    driver_again: None,
    driver_tries: 0,
    retake: false,
    closed: false,
    taking: {},
    taking_runs: {},
    take_again: {},
    tell_runs: {},
    tell_again: {},
    drops,
    took_here,
    dropping: None,
    drop_again: None,
    drop_tries: 0,
    telling: None,
    wakes: {},
    wake_at: {},
    waking: [],
  }
  for name in fs.names(taking_dir(fs, d.data)) {
    match fs.read_json(fs.join([taking_dir(fs, d.data), name])) {
      Some(Obj(_) as v) if is_station(text_at(v, "origin")) => r.taking[text_at(v, "origin")] = Taking::of_json(v)
      _ => ()
    }
  }
  for name in fs.names(took_dir(fs, d.data)) {
    if !name.has_suffix(".json") {
      continue
    }
    match fs.read_json(fs.join([took_dir(fs, d.data), name])) {
      Some(Obj(_) as v) if is_station(text_at(v, "origin")) => r.wakes[text_at(v, "origin")] = v
      _ => ()
    }
  }
  match r.state {
    Some(s) if stopped_step(s.step) =>
      w.go(async fn() {
        r.quiet(s) catch {
          e => w.warn("retire", "a retired station's chats not quiet yet", jo([("error", js(message_of(e)))]))
        }
      })
    _ => ()
  }
  r.holds_now()
  r
}

///|
/// Begun (the mesh attached): where each side stood, gone on with.
pub async fn Retire::start(self : Retire) -> Unit {
  for t in self.taking.values().collect() {
    if (self.d.copies.formerly)().contains(t.origin) {
      if t.step != "took" {
        self.took_place(t)
      }
      self.tell(t, 0)
    } else if t.step == "restart" {
      let o = (self.d.copies.restored)()
      let failed = match o {
        Some(o) if text_at(o, "origin") == t.origin && str_at(o, "error") is Some(e) && !yes_at(o, "pending") => Some(e)
        _ =>
          if t.restarts >= restarts_most {
            Some(
              "this station started again \{t.restarts} times to put the chats in and they did not go in (its log says why): retry, or cancel on the station retired",
            )
          } else {
            None
          }
      }
      match failed {
        Some(f) => {
          t.step = "failed"
          t.error = Some(f)
          t.told = false
          self.save_taking(t)
          self.w.warn("retire", "a retired station's chats could not be put in here", jo([("origin", js(t.origin)), ("error", js(f))]))
          self.tell(t, 0)
        }
        None => self.take(t)
      }
    } else if t.step == "failed" {
      if !t.told {
        self.tell(t, 0)
      }
    } else if t.step == "took" {
      self.tell(t, 0)
    } else if t.step != "coming" {
      self.take(t)
    }
  }
  for origin in self.wakes.keys().collect() {
    self.wake_soon(origin)
  }
  self.drop_soon()
  guard self.state is Some(s) else { return }
  if stopped_step(s.step) {
    self.quiet(s)
  }
  if s.step != "done" && s.reason != Some("failed") {
    self.go()
  }
  self.driver_soon()
}

///|
pub async fn Retire::close(self : Retire) -> Unit {
  self.closed = true
  self.holds_now()
  call_opt(self.again)
  call_opt(self.telling)
  call_opt(self.drop_again)
  call_opt(self.driver_again)
  for f in [..self.take_again.values(), ..self.tell_again.values(), ..self.wake_at.values()] {
    f()
  }
  self.wake_at.clear()
  self.stopping = true
  for r in [self.running, self.dropping, self.driving] {
    match r {
      Some(x) => x.settled()
      None => ()
    }
  }
  for r in [..self.taking_runs.values(), ..self.tell_runs.values(), ..self.waking] {
    r.settled()
  }
}

///|
/// What is under way here brought to rest.
pub async fn Retire::settle(self : Retire) -> Unit {
  while true {
    let going : Array[Run] = []
    for r in [self.running, self.dropping, self.driving] {
      match r {
        Some(x) => going.push(x)
        None => ()
      }
    }
    going.push_iter(self.taking_runs.values())
    going.push_iter(self.tell_runs.values())
    going.push_iter(self.waking.iter())
    if going.length() == 0 {
      return
    }
    for r in going {
      r.settled()
    }
  }
}

///|
/// The origins whose chats this station is taking.
pub fn Retire::taking_now(self : Retire) -> Array[String] {
  self.taking.values().filter(t => t.step != "took").map(t => t.origin).collect()
}

///|
/// The holds on updating this station as where each side stands says now.
fn Retire::holds_now(self : Retire) -> Unit {
  let s = self.state
  let going = match s {
    Some(s) => s.step == "sending" || s.step == "quiet" || s.step == "handing"
    None => false
  }
  let rests = match s {
    Some({ reason: Some(r), .. }) => r == "failed" || r == "full" || r == "old" || r == "offline"
    _ => false
  }
  let retiring = !self.closed && going && !rests
  if retiring && self.retiring_held is None {
    self.retiring_held = Some((self.d.hold)())
  } else if !retiring && self.retiring_held is Some(let_go) {
    self.retiring_held = None
    let_go()
  }
  for t in self.taking.values() {
    if !self.closed && taking_held_steps.contains(t.step) && !self.taking_held.contains(t.origin) {
      self.taking_held[t.origin] = (self.d.hold)()
    }
  }
  for pair in self.taking_held.iter().collect() {
    let (origin, let_go) = pair
    match self.taking.get(origin) {
      Some(t) if !self.closed && taking_held_steps.contains(t.step) => continue
      _ => ()
    }
    self.taking_held.remove(origin)
    let_go()
  }
}

///|
fn Retire::changed(self : Retire, now : Bool) -> Unit {
  self.holds_now()
  if now {
    call_opt(self.telling)
    self.telling = None
    (self.d.changed)()
    return
  }
  if self.telling is Some(_) {
    return
  }
  // timer: a debounce of a burst (each file sent)
  self.telling = Some(
    self.w.after(retire_tell_ms, () => {
      self.telling = None
      (self.d.changed)()
    }),
  )
}

// ── this station retired ──

///|
/// Retires this station from `ws`: its chats there go on on `to`.
pub async fn Retire::retire(self : Retire, ws : String, to : String, by : String, wait? : Bool = false, driver? : Driver? = None) -> Unit {
  let here = (self.d.here)()
  guard is_workspace(ws) && is_station(to) && here is Some(here) else { raise refused("not a station") }
  match self.state {
    Some(s) =>
      raise refused(
        if s.step == "done" {
          "this station was retired from a workspace already: its chats went to another station"
        } else {
          "this station is being retired already, its chats going to \{if s.to_name != "" { s.to_name } else { "another station" }}: cancel that first"
        },
      )
    None => ()
  }
  if to == here {
    raise refused("the chats go to another station")
  }
  let roster = (self.d.roster)(ws).unwrap_or([])
  guard roster.search_by(s => s.id == to) is Some(ti) else { raise refused("that station is not one of this workspace's") }
  let target = roster[ti]
  let here_name = match roster.search_by(s => s.id == here) {
    Some(i) => roster[i].name
    None => ""
  }
  ignore(
    self.w.ask(to, jo([("method", js("retire.begin")), ("workspace", js(ws)), ("origin", js(here)), ("name", js(here_name))])) catch {
      e => {
        if is_refused(e) {
          let m = message_of(e)
          raise refused(
            if m.contains("no such retire request") || m.contains("unknown") {
              "that station is from before stations could be retired: update it first"
            } else {
              "that station refused it: \{m}"
            },
          )
        }
        raise refused("that station is not reached now: try again once it is up")
      }
    },
  )
  if self.state is Some(_) {
    raise refused("this station is being retired already")
  }
  self.drops = self.drops.filter(x => !(text_at(x, "to") == to && text_at(x, "workspace") == ws))
  self.w.fs.write_json(drops_file(self.w.fs, self.d.data), ja(self.drops))
  let s : RetireState = {
    workspace: ws,
    to,
    to_name: target.name,
    by,
    at: self.w.now(),
    step: "sending",
    done: 0.0,
    total: 0.0,
    error: None,
    reason: None,
    jobs: [],
    take: None,
    accounts_left: [],
    wait,
    driver,
    owed: [],
    files: 0.0,
    sent_at: None,
    retake: false,
    jobs_there: None,
    told_error: None,
    accounts_moved: [],
    accounts_told: false,
  }
  self.state = Some(s)
  self.w.fs.write_json(retiring_file(self.w.fs, self.d.data), s.to_json())
  self.changed(true)
  self.go()
}

///|
fn Retire::go(self : Retire) -> Unit {
  if self.closed {
    return
  }
  if self.running is Some(_) {
    self.more = true
    return
  }
  call_opt(self.again)
  self.again = None
  self.more = false
  let run = self.w.run(async fn() {
    try {
      self.run()
      self.tries = 0
      self.unreached_since = None
      self.sending_failed_since = None
    } catch {
      e => self.run_failed(e)
    }
    self.running = None
    if self.more && !self.stopping {
      self.go()
    }
  })
  if !run.is_done() {
    self.running = Some(run)
  }
}

///|
async fn Retire::run_failed(self : Retire, e : Error) -> Unit {
  guard self.state is Some(s) && !self.stopping else { return }
  let message = message_of(e)
  self.w.warn("retire", "a step of the retirement failed", jo([("step", js(s.step)), ("to", js(s.to)), ("error", js(message))]))
  s.error = Some(message)
  let l = message.to_lower()
  s.reason = Some(
    if kind_of(e) == "Full" || l.contains("enospc") || l.contains("disk is full") || l.contains("no space left") {
      "full"
    } else if is_refused(e) && message.contains("no such retire request") {
      "old"
    } else if is_refused(e) {
      "error"
    } else if l.contains("not reached") ||
      l.contains("unreachable") ||
      l.contains("timed out") ||
      l.contains("no route") ||
      l.contains("closed") {
      "offline"
    } else {
      "error"
    },
  )
  self.changed(true)
  let unreached = s.reason == Some("offline") && s.step == "quiet" && s.take is None
  if !unreached {
    self.unreached_since = None
  } else if self.unreached_since is None {
    self.unreached_since = Some(self.w.now())
  }
  if unreached && self.w.now() - self.unreached_since.unwrap_or(0.0) >= quiet_unreached_ms {
    self.tries = 0
    self.unreached_since = None
    self.fall_back(s) catch {
      x => self.w.warn("retire", "the chats not put back to work", jo([("error", js(message_of(x)))]))
    }
    return
  }
  if s.step != "sending" {
    self.sending_failed_since = None
  } else {
    let now = self.w.now()
    if self.sending_failed_since is None {
      self.sending_failed_since = Some(now)
    }
    let since = self.sending_failed_since.unwrap_or(now)
    let retried = s.reason == Some("error") || s.reason == Some("offline")
    let failing = now - since
    let told = if retried { "retried since \{num_text(since)}" } else { message }
    if (!retried || failing >= retire_retry_most_ms) && s.told_error != Some(told) {
      s.told_error = Some(told)
      let to_name = if s.to_name != "" { s.to_name } else { "the other station" }
      let reason = s.reason.unwrap_or("")
      self.to_driver(
        s,
        if retried {
          "Retiring this station: sending the files to \{to_name} has been failing for \{num_text(js_round(failing / 60000.0))} min (\{reason}): \{message}. The chats still work here; the station goes on trying by itself. Look at what keeps it (station_retire status, station_task on that station), or cancel."
        } else {
          "Retiring this station: sending the files to \{to_name} failed (\{reason}): \{message}. The chats still work here; it is tried again by itself, but this needs someone: fix it (or call station_retire again after), or cancel."
        },
      )
    }
  }
  let wait = backoff(retire_retry_ms, self.tries, retire_retry_most_ms)
  self.tries += 1
  if !self.closed {
    // timer: a retry after a failure
    self.again = Some(self.w.after(wait, () => self.go()))
  }
}

///|
/// Where this station stands, written: as it is now, after what was being written.
async fn Retire::save(self : Retire) -> Unit {
  match self.state {
    Some(s) => {
      let now = s.to_json()
      let before = self.writes
      let fs = self.w.fs
      let path = retiring_file(fs, self.d.data)
      let write = self.w.run(async fn() {
        before.settled()
        fs.write_json(path, now)
      })
      self.writes = write
      write.wait()
    }
    None => ()
  }
  self.changed(true)
}

///|
/// The chats stopped (again, as it starts again), and the jobs that stopped with them kept with what goes along.
async fn Retire::quiet(self : Retire, s : RetireState) -> Unit {
  let stopped = (self.d.quiet)(s.workspace)
  let fresh = stopped.filter(j => !s.jobs.iter().any(k => text_at(k, "session") == text_at(j, "session") &&
      text_at(k, "name") == text_at(j, "name") &&
      text_at(k, "command") == text_at(j, "command")))
  if fresh.length() == 0 || !(self.state is Some(x) && physical_equal(x, s)) {
    return
  }
  s.jobs.push_iter(fresh.iter())
  self.save()
}

///|
fn Retire::is_state(self : Retire, s : RetireState) -> Bool {
  self.state is Some(x) && physical_equal(x, s)
}

///|
async fn Retire::run(self : Retire) -> Unit {
  guard self.state is Some(s) && (self.d.here)() is Some(here) else { return }
  if s.step == "sent" && s.wait {
    return
  }
  s.error = None
  s.reason = None
  self.holds_now()
  let fs = self.w.fs
  let ws = s.workspace
  let home = (self.d.home)() == Some(ws)
  let db = fs.join([self.d.data, "stillfail.db"])
  let agent = match self.d.agent_home {
    Some(f) => f(ws)
    None => None
  }
  let gather = async fn() -> J {
    let g = (self.d.work.gather)(self.d.data, db, ws, home, scratch_dir(fs, self.d.data), agent, None)
    if num_at(g, "skipped").unwrap_or(0.0) > 0.0 {
      self.w.warn("retire", "sessions whose directory is not the station's own: their files stay", jo([("n", at(g, "skipped").unwrap_or(Null))]))
    }
    g
  }
  let to_name = if s.to_name != "" { s.to_name } else { "that station" }
  if s.step == "sending" {
    let g = gather()
    if self.stopping {
      return
    }
    let room = self.w.ask(s.to, jo([("method", js("retire.room")), ("workspace", js(ws)), ("origin", js(here))]))
    let gits = num_at(g, "gits").unwrap_or(0.0)
    if gits > 0.0 && at(room, "git") is Some(Bool(false)) {
      let n = gits.to_int()
      raise failed(
        "\{to_name} has no git, and \{n} git worktree\{if n == 1 { "" } else { "s" }} here \{if n == 1 { "is" } else { "are" }} to be made again there: install git on that station first, then retry",
      )
    }
    let bytes = num_at(g, "bytes").unwrap_or(0.0)
    let need = bytes * (if at(room, "clones") is Some(Bool(true)) { 1.0 } else { 2.0 }) + headroom + (bytes / 20.0).ceil()
    match at(room, "free") {
      Some(Num(free)) if need > free =>
        raise full_error("\{to_name} has \{gb(free)} free and this needs \{gb(need)}: free some room there, or cancel and pick another station")
      _ => ()
    }
    ignore(self.send(s, g, here, false))
    if self.stopping {
      return
    }
    s.step = "sent"
    s.files = num_at(g, "files").unwrap_or(0.0)
    s.sent_at = Some(self.w.now())
    s.told_error = None
    self.save()
    if s.wait {
      let took = @cmp.maximum(0.0, js_round((s.sent_at.unwrap_or(0.0) - s.at) / 1000.0))
      let other = if s.to_name != "" { s.to_name } else { "the other station" }
      self.to_driver(
        s,
        "Retiring this station: everything that goes along is on \{other} (\{num_text(s.files)} files, \{gb(s.total)}, in \{num_text(took)} s); the chats still work here. What changes from now on is sent once they stop. Nothing more happens until the hand-over is confirmed: call station_retire hand_over (it posts a card that an owner or admin confirms in the still.fail app; it pauses the chats).",
      )
      return
    }
  }
  if s.step == "sent" {
    s.step = "quiet"
    self.save()
  }
  if s.step == "quiet" {
    self.keep_owed_to(s, here)
    if s.retake {
      ignore(self.w.ask(s.to, jo([("method", js("retire.begin")), ("workspace", js(ws)), ("origin", js(here)), ("name", js(self.here_name(ws)))])))
    }
    self.quiet(s)
    let g = gather()
    if self.stopping {
      return
    }
    let carry = self.send(s, g, here, true)
    guard !self.stopping && carry is Some(carry) else { return }
    let gen = (self.d.copies.bring_to)(ws, s.to)
    let own = (self.d.connects_of)(ws)
    let used = (self.d.used)(db, ws, home)
    s.take = Some(
      jo([
        ("gen", js(gen)),
        ("carry", js(carry)),
        ("connects", pairs_json(connects_there(own, used, here, s.to))),
        ("bindings", pairs_json((self.d.bindings_of)(own))),
        ("driver", driver_json(s.driver)),
        ("accounts", jb(home)),
      ]),
    )
    s.step = "handing"
    self.save()
    fs.rm_rf(scratch_dir(fs, self.d.data))
  }
  if s.step == "handing" {
    guard s.take is Some(t) else {
      raise failed("what the other station was to take is not known: cancel it and retire this station again")
    }
    let again = self.retake || s.retake
    let name = match (self.d.roster)(ws) {
      Some(r) =>
        match r.search_by(m => m.id == here) {
          Some(i) => r[i].name
          None => ""
        }
      None => ""
    }
    let answer = self.w.ask(
      s.to,
      merged(jo([("method", js("retire.take")), ("workspace", js(ws)), ("origin", js(here)), ("name", js(name))]), merged(t, jo([("again", jb(again))]))),
    )
    if again {
      self.retake = false
      s.retake = false
    }
    match at(answer, "failed") {
      Some(Str(u)) => {
        let f = @jsjson.sanitize_str(u)
        s.error = Some(if f != "" { f } else { "that station could not put the chats in" })
        s.reason = Some("failed")
        self.fall_back(s)
        return
      }
      _ => ()
    }
    if !yes_at(answer, "took") {
      return
    }
    self.took_there(s, Some(answer))
  }
  if s.step == "accounts" {
    for p in (self.d.accounts_own)() {
      let (id, pname) = p
      if s.accounts_left.iter().any(a => text_at(a, "id") == id && text_at(a, "error") == "") {
        continue
      }
      try {
        let there = (self.d.accounts_move)(id, s.to)
        s.accounts_left = s.accounts_left.filter(a => text_at(a, "id") != id)
        s.accounts_moved = [
          ..s.accounts_moved.filter(a => text_at(a, "was") != id),
          jo([("was", js(id)), ("id", js(str_at(there, "id").unwrap_or(id)))]),
        ]
      } catch {
        e => {
          self.w.warn("retire", "an account did not move with the retirement", jo([("profile", js(id)), ("error", js(message_of(e)))]))
          s.accounts_left = [
            ..s.accounts_left.filter(a => text_at(a, "id") != id),
            jo([("id", js(id)), ("name", js(pname)), ("error", js(message_of(e)))]),
          ]
        }
      }
      self.save()
    }
    if !s.accounts_told {
      ignore(
        self.w.ask(
          s.to,
          jo([
            ("method", js("retire.accounts")),
            ("workspace", js(ws)),
            ("origin", js(here)),
            ("moved", ja(s.accounts_moved)),
            ("left", ja(s.accounts_left.map(a => at(a, "id").unwrap_or(Null)))),
          ]),
        ) catch {
          e => {
            if !(is_refused(e) && message_of(e).contains("no such retire request")) {
              raise e
            }
            Null
          }
        },
      )
      s.accounts_told = true
    }
    s.step = "connects"
    self.save()
    if s.accounts_left.length() > 0 {
      let other = if s.to_name != "" { s.to_name } else { "the other station" }
      self.to_driver(
        s,
        "Retiring station \{self.here_name(ws)}: these accounts did not move to \{other} and are still on the retired one: \{s.accounts_left.map(a => "\{text_at(a, "name")}: \{text_at(a, "error")}").join("; ")}. Sign them in there (the login tool) or move them by hand in the app, before the retired station is taken out.",
      )
    }
  }
  if s.step == "connects" {
    (self.d.move_connects)(ws, s.to)
    s.step = "done"
    self.save()
    self.w.info("retire", "this station's chats of a workspace went on another station", jo([("workspace", js(ws)), ("to", js(s.to))]))
    let other = if s.to_name != "" { s.to_name } else { "the other station" }
    self.to_driver(
      s,
      "Retiring station \{self.here_name(ws)} is done: its chats, accounts and connects are on \{other}. Check there that a chat goes on, its worktrees and jobs, and its logins (see the stillfail-retire skill). Taking the retired station out of the workspace is a person's own step in the app (its station page offers it).",
    )
  }
}

///|
/// This station's name in `ws`, as its roster says.
fn Retire::here_name(self : Retire, ws : String) -> String {
  let here = (self.d.here)()
  let named = match ((self.d.roster)(ws), here) {
    (Some(r), Some(h)) =>
      match r.search_by(m => m.id == h) {
        Some(i) => r[i].name
        None => ""
      }
    _ => ""
  }
  if named != "" {
    named
  } else {
    head_of(here.unwrap_or(""), 12)
  }
}

///|
/// The other station took this one's place: its chats there are that station's now, out of sight here.
async fn Retire::took_there(self : Retire, s : RetireState, answer : J?) -> Unit {
  (self.d.retired)(s.workspace)
  s.step = if (self.d.home)() == Some(s.workspace) { "accounts" } else { "connects" }
  s.error = None
  s.reason = None
  match answer {
    Some(a) =>
      match at(a, "jobs") {
        Some(Arr(_) as j) => s.jobs_there = Some(j)
        _ => ()
      }
    None => ()
  }
  let here = (self.d.here)()
  let d = s.driver
  let moved = match d {
    Some(dr) if Some(dr.station) == here =>
      match self.d.of_workspace {
        Some(f) => f(dr.session, s.workspace)
        None => true
      }
    _ => false
  }
  match d {
    Some(dr) if moved => s.driver = Some({ station: s.to, session: dr.session })
    _ => ()
  }
  self.save()
  let driver_told = match answer {
    Some(a) => yes_at(a, "driverTold")
    None => false
  }
  if d is Some(_) && !(moved && driver_told) {
    let jobs = match s.jobs_there {
      Some(j) => " \{job_words(items(Some(j)))}"
      None => ""
    }
    let lost = match answer {
      Some(a) =>
        match at(a, "lost") {
          Some(Str(u)) if u.length() > 0 => " But: \{@jsjson.sanitize_str(u)}."
          _ => ""
        }
      None => ""
    }
    let other = if s.to_name != "" { s.to_name } else { "the other station" }
    let next = if s.step == "accounts" { "accounts, then its connects" } else { "connects" }
    self.to_driver(s, "Retiring this station: \{other} took its chats; they go on there.\{jobs}\{lost} Its \{next} move next.")
  }
}

///|
/// The chats back to work here, as the hand-over did not go through, resting at `sent`.
async fn Retire::fall_back(self : Retire, s : RetireState) -> Unit {
  if !self.is_state(s) || (s.step != "quiet" && s.step != "handing") {
    return
  }
  let here = (self.d.here)()
  let ws = s.workspace
  let mut owed = false
  match here {
    Some(h) => {
      let answer = self.w.ask(s.to, jo([("method", js("retire.drop")), ("workspace", js(ws)), ("origin", js(h)), ("keep", jb(true))])) catch {
        e => {
          if is_refused(e) {
            jo([("refused", js(message_of(e)))])
          } else {
            owed = true
            Null
          }
        }
      }
      if yes_at(answer, "took") || (at(answer, "refused") is Some(Str(_))) {
        self.w.warn("retire", "a hand-over that failed not called off: the station picked may put the chats in", jo([("to", js(s.to)), ("answer", answer)]))
        if yes_at(answer, "took") && s.step == "handing" {
          s.error = None
          s.reason = None
        }
        self.save()
        return
      }
    }
    None => ()
  }
  let jobs = s.jobs
  s.step = "sent"
  s.wait = true
  s.take = None
  s.retake = true
  s.jobs = []
  call_opt(self.again)
  self.again = None
  if owed {
    self.drops = [
      ..self.drops.filter(x => !(text_at(x, "to") == s.to && text_at(x, "workspace") == ws)),
      jo([("to", js(s.to)), ("workspace", js(ws)), ("keep", jb(true))]),
    ]
    self.w.fs.write_json(drops_file(self.w.fs, self.d.data), ja(self.drops))
    self.drop_soon()
  }
  self.save()
  (self.d.unquiet)(ws)
  let who = if s.to_name != "" { s.to_name } else { head_of(s.to, 12) }
  let back = self.jobs_back(jobs, "The move of this chat to station \{who} did not go through, and it works here again")
  self.w.warn("retire", "a hand-over did not go through: the chats work here again", jo([("to", js(s.to)), ("reason", jopt(s.reason)), ("error", jopt(s.error))]))
  let other = if s.to_name != "" { s.to_name } else { "the other station" }
  self.to_driver(
    s,
    "Retiring this station: the hand-over to \{other} failed (\{show_value(Some(jopt(s.reason)))}): \{show_value(Some(jopt(s.error)))}. The station already put the chats back to work here\{if back == "" { "" } else { " (\{back})" }}; what was sent stays there, so the next hand-over sends only what changed. Fix the cause, then call station_retire hand_over again (a person confirms it again), or cancel.",
  )
}

///|
/// The jobs a chat stopped as its chats did, started again here, each told to its agent.
async fn Retire::jobs_back(self : Retire, jobs : Array[J], why : String) -> String {
  guard self.d.jobs is Some(j) else { return "" }
  let mut started = 0
  for job in jobs {
    let session = text_at(job, "session")
    let name = text_at(job, "name")
    let command = text_at(job, "command")
    guard str_at(job, "cwd") is Some(cwd) else { continue }
    if (j.running)(session, name, command) {
      continue
    }
    let port = num_at(job, "port")
    let mut error : String? = None
    let mut made : J? = None
    try {
      made = Some(
        (j.start)(
          session,
          jo([("name", js(name)), ("command", js(command)), ("cwd", js(cwd)), ("port", opt_num(port)), ("watch", jb(yes_at(job, "watch")))]),
        ),
      )
      started += 1
    } catch {
      e => error = Some(message_of(e))
    }
    let said = match made {
      Some(m) => moved_said(why, text_at(m, "name"), num_at(m, "port"), str_at(m, "id"), error)
      None => moved_said(why, name, port, None, error)
    }
    (j.say)(session, said)
  }
  if started == 0 {
    ""
  } else {
    "\{started} job\{if started == 1 { "" } else { "s" }} started again"
  }
}

///|
/// A drop with `keep` owed to the station picked, told it before anything more is sent there.
async fn Retire::keep_owed_to(self : Retire, s : RetireState, here : String) -> Unit {
  guard self.drops.search_by(x => text_at(x, "to") == s.to && text_at(x, "workspace") == s.workspace && yes_at(x, "keep")) is Some(i) else {
    return
  }
  let owed = self.drops[i]
  ignore(self.w.ask(s.to, jo([("method", js("retire.drop")), ("workspace", js(s.workspace)), ("origin", js(here)), ("keep", jb(true))])))
  self.drops = self.drops.filter(x => !physical_equal(x, owed))
  self.w.fs.write_json(drops_file(self.w.fs, self.d.data), ja(self.drops))
}

///|
/// `text` to be told to the driver, kept until it is.
async fn Retire::to_driver(self : Retire, s : RetireState, text : String) -> Unit {
  if s.driver is None {
    return
  }
  s.owed.push(text)
  self.save()
  self.driver_soon()
}

///|
/// What is owed to the driver told, in order.
fn Retire::driver_soon(self : Retire) -> Unit {
  guard self.state is Some(s) && self.driving is None && !self.closed && s.driver is Some(_) && s.owed.length() > 0 else { return }
  call_opt(self.driver_again)
  self.driver_again = None
  let run = self.w.run(async fn() {
    let here = (self.d.here)()
    let mut left = false
    while self.is_state(s) && s.driver is Some(d) && s.owed.length() > 0 {
      let text = s.owed[0]
      try {
        if Some(d.station) == here {
          match self.d.tell {
            Some(t) => t(d.session, text)
            None => ()
          }
        } else {
          ignore(self.w.ask(d.station, jo([("method", js("retire.tell")), ("workspace", js(s.workspace)), ("session", js(d.session)), ("text", js(text))])))
        }
      } catch {
        e => {
          if Some(d.station) != here && !is_refused(e) {
            left = true
            break
          }
          self.w.warn("retire", "who asked for the retirement not told", jo([("session", js(d.session)), ("error", js(message_of(e)))]))
        }
      }
      ignore(s.owed.remove(0))
      self.save()
    }
    if !left {
      self.driver_tries = 0
    } else {
      let wait = backoff(retire_retry_ms, self.driver_tries, retire_retry_most_ms)
      self.driver_tries += 1
      if !self.closed {
        // timer: a retry after a failure
        self.driver_again = Some(self.w.after(wait, () => self.driver_soon()))
      }
    }
    self.driving = None
  })
  if !run.is_done() {
    self.driving = Some(run)
  }
}

///|
/// What the gathering `g` names that the other station lacks, sent: the index last, its hash said back.
async fn Retire::send(self : Retire, s : RetireState, g : J, here : String, strict : Bool) -> String? {
  s.done = 0.0
  let base = [("workspace", js(s.workspace)), ("origin", js(here))]
  send_gathered(
    self.w.fs,
    g,
    {
      lacking: async fn(hashes, _files) {
        self.w.ask(s.to, jo([("method", js("retire.lacking")), ..base, ("hashes", jstrs(hashes))]))
      },
      put: async fn(hash, body, _path, _size) { self.w.ask(s.to, jo([("method", js("retire.put")), ..base, ("name", js(hash))]), body~) },
      put_pack: Some(async fn(entries, body, strict) {
        let fields = [
          ("method", js("retire.put")),
          ..base,
          ("pack", js(pack_encoding)),
          ("strict", jb(strict)),
          ("count", ji(entries.length())),
        ]
        if entries.length() == 1 {
          fields.push(("name", js(entries[0].hash)))
        }
        self.w.ask(s.to, jo(fields), body~)
      }),
      took: None,
      pack_files: None,
      pack_bytes: None,
      most: self.d.lack_most,
      stopping: () => self.stopping,
      total: bytes => {
        s.total = bytes
        self.changed(true)
      },
      done: bytes => {
        s.done += bytes
        self.changed(false)
      },
      adds: None,
    },
    strict,
    jobs=s.jobs,
  )
}

///|
/// The other station says it took this one's place (`retire.took`).
async fn Retire::took(self : Retire, peer : String, request : J?) -> Unit {
  guard self.state is Some(s) && s.to == peer else { return }
  if s.step != "handing" {
    if s.step == "sent" || s.step == "quiet" {
      self.w.warn("retire", "the station picked says it took the chats while they work here", jo([("to", js(peer)), ("step", js(s.step))]))
    }
    return
  }
  self.took_there(s, request)
  self.go()
}

///|
/// It says it could not put them in (`retire.failed`).
async fn Retire::failed_there(self : Retire, peer : String, error : String) -> Unit {
  guard self.state is Some(s) && s.to == peer && s.step == "handing" else { return }
  s.error = Some(if error != "" { error } else { "that station could not put the chats in" })
  s.reason = Some("failed")
  call_opt(self.again)
  self.again = None
  self.fall_back(s)
}

///|
/// Called off (the settings' cancel), answered at once.
pub async fn Retire::cancel(self : Retire, ws : String) -> Unit {
  guard self.state is Some(s) && s.workspace == ws && (self.d.here)() is Some(here) else { return }
  let name = if s.to_name != "" { s.to_name } else { "the other station" }
  let took_words = "\{name} took this station's chats already: it goes on moving its accounts and connects there, and is done then"
  if s.step == "accounts" || s.step == "connects" || s.step == "done" {
    raise refused(took_words)
  }
  self.stopping = true
  call_opt(self.again)
  self.again = None
  match self.running {
    Some(r) => r.settled()
    None => ()
  }
  self.stopping = false
  let resume = () => if s.reason != Some("failed") { self.go() }
  if s.step == "accounts" || s.step == "connects" || s.step == "done" {
    self.go()
    raise refused(took_words)
  }
  let answer = self.w.ask(s.to, jo([("method", js("retire.drop")), ("workspace", js(ws)), ("origin", js(here))])) catch {
    e => {
      if is_refused(e) {
        resume()
        raise refused(
          if message_of(e).contains("busy") {
            "\{name} is putting the chats in just now: cancel again in a minute, or let it finish"
          } else {
            "\{name} did not call it off: \{message_of(e)}"
          },
        )
      }
      if s.take is Some(_) {
        resume()
        raise refused(
          "\{name} is not reached, and may be taking the chats: they stay stopped here until it answers. Cancel again once it is up, or let the move finish",
        )
      }
      self.drops = [
        ..self.drops.filter(x => !(text_at(x, "to") == s.to && text_at(x, "workspace") == ws)),
        jo([("to", js(s.to)), ("workspace", js(ws))]),
      ]
      self.w.fs.write_json(drops_file(self.w.fs, self.d.data), ja(self.drops))
      jo([("dropped", jb(true))])
    }
  }
  if yes_at(answer, "took") {
    self.took(s.to, None)
    raise refused(took_words)
  }
  if stopped_step(s.step) {
    (self.d.unquiet)(ws)
    ignore(self.jobs_back(s.jobs, "The move of this chat to station \{name} was called off, and it works here again"))
  }
  self.state = None
  self.writes.settled()
  self.w.fs.rm_f(retiring_file(self.w.fs, self.d.data))
  self.w.fs.rm_rf(scratch_dir(self.w.fs, self.d.data))
  self.w.info("retire", "a retirement called off", jo([("workspace", js(ws)), ("to", js(s.to))]))
  self.changed(true)
  self.drop_soon()
}

///|
/// The drops owed told, each until its station answers or is no longer of the workspace.
fn Retire::drop_soon(self : Retire) -> Unit {
  if self.dropping is Some(_) || self.closed || self.drops.length() == 0 {
    return
  }
  call_opt(self.drop_again)
  self.drop_again = None
  let run = self.w.run(async fn() {
    let here = (self.d.here)()
    let mut left = false
    for x in self.drops.copy() {
      let ws = text_at(x, "workspace")
      let to = text_at(x, "to")
      let mut done = match (self.d.roster)(ws) {
        Some(r) => !r.iter().any(m => m.id == to)
        None => false
      }
      match here {
        Some(h) if !done => {
          let fields = [("method", js("retire.drop")), ("workspace", js(ws)), ("origin", js(h))]
          if yes_at(x, "keep") {
            fields.push(("keep", jb(true)))
          }
          done = try {
            ignore(self.w.ask(to, jo(fields)))
            true
          } catch {
            e => is_refused(e) && !message_of(e).contains("busy")
          }
        }
        _ => ()
      }
      if done {
        self.drops = self.drops.filter(y => !physical_equal(y, x))
      } else {
        left = true
      }
    }
    self.w.fs.write_json(drops_file(self.w.fs, self.d.data), ja(self.drops)) catch {
      e => {
        self.dropping = None
        raise e
      }
    }
    if !left {
      self.drop_tries = 0
    } else {
      let wait = backoff(retire_retry_ms, self.drop_tries, retire_retry_most_ms)
      self.drop_tries += 1
      if !self.closed {
        // timer: a retry after a failure
        self.drop_again = Some(self.w.after(wait, () => self.drop_soon()))
      }
    }
    self.dropping = None
  })
  if !run.is_done() {
    self.dropping = Some(run)
  }
}

///|
/// Tried again now (the settings' retry).
pub async fn Retire::again(self : Retire, ws : String, hand_over? : Bool = true) -> Unit {
  guard self.state is Some(s) && s.workspace == ws else { raise refused("this station is not being retired from this workspace") }
  if s.step == "sent" {
    if !hand_over {
      raise refused(
        "it waits for the hand-over to be confirmed: station_retire hand_over posts the card an owner or admin confirms (it pauses the chats)",
      )
    }
    if s.error is None {
      return
    }
    s.step = "quiet"
  } else if s.error is None {
    return
  }
  self.tries = 0
  self.unreached_since = None
  if s.reason == Some("failed") && s.step == "handing" {
    self.retake = true
  }
  s.reason = None
  self.save()
  self.go()
}

///|
/// The hand-over confirmed by a person: from `sent`, the chats stop and their copy goes.
pub async fn Retire::hand_over(self : Retire, ws : String, by : String) -> Unit {
  guard self.state is Some(s) && s.workspace == ws else { raise refused("this station is not being retired from this workspace") }
  if s.step != "sent" {
    raise refused(
      if s.step == "sending" {
        "the files are still being sent: you are told once they are all there"
      } else {
        "it is past that: \{s.step} (station_retire status)"
      },
    )
  }
  self.w.info("retire", "the hand-over confirmed", jo([("workspace", js(ws)), ("to", js(s.to)), ("by", js(by))]))
  s.step = "quiet"
  s.error = None
  s.reason = None
  self.tries = 0
  self.unreached_since = None
  self.save()
  self.go()
}

///|
/// What a station_retire asks of this station's retirement from `ws`.
pub async fn Retire::agent_ask(self : Retire, ws : String, request : J) -> J {
  let station = jo([("id", jopt((self.d.here)())), ("name", js(self.here_name(ws)))])
  match str_at(request, "op") {
    Some("preview") => {
      let to = match str_at(request, "to") {
        Some(t) if is_station(t) => Some(t)
        _ => None
      }
      let preview = self.preview(ws)
      let status = self.status(ws)
      let readiness = match to {
        Some(t) => self.readiness(ws, t)
        None => Null
      }
      jo([("station", station), ("preview", preview), ("status", status), ("to", readiness)])
    }
    Some("status") => jo([("station", station), ("status", self.status(ws))])
    Some("start") => {
      guard str_at(request, "to") is Some(to) && str_at(request, "by") is Some(by) else { raise refused("to and by are needed") }
      self.retire(ws, to, by, wait=true, driver=driver_of(at(request, "driver")))
      jo([("status", self.status(ws))])
    }
    Some("hand_over") => {
      self.hand_over(ws, str_at(request, "by").unwrap_or(""))
      jo([("status", self.status(ws))])
    }
    Some("again") => {
      self.again(ws, hand_over=false)
      jo([("status", self.status(ws))])
    }
    Some("cancel") => {
      self.cancel(ws)
      jo([("status", self.status(ws))])
    }
    _ => raise refused("no such station_retire action")
  }
}

///|
/// How the station `to` stands for taking this one's chats, as `retire.room` says it.
async fn Retire::readiness(self : Retire, ws : String, to : String) -> J {
  let here = (self.d.here)()
  let name = match (self.d.roster)(ws) {
    Some(r) =>
      match r.search_by(m => m.id == to) {
        Some(i) => r[i].name
        None => ""
      }
    None => ""
  }
  if here is None || here == Some(to) {
    return jo([("id", js(to)), ("name", js(name)), ("reached", jb(false)), ("error", js("that is this station"))])
  }
  let room = self.w.ask(to, jo([("method", js("retire.room")), ("workspace", js(ws)), ("origin", jopt(here))])) catch {
    e => {
      if is_refused(e) {
        let m = message_of(e)
        return jo([
          ("id", js(to)),
          ("name", js(name)),
          ("reached", jb(true)),
          ("old", jb(m.contains("no such retire request") || m.contains("unknown"))),
          ("error", js(m)),
        ])
      }
      return jo([("id", js(to)), ("name", js(name)), ("reached", jb(false)), ("error", js(message_of(e)))])
    }
  }
  jo([
    ("id", js(to)),
    ("name", js(name)),
    ("reached", jb(true)),
    ("free", match at(room, "free") { Some(Null) | None => Null; Some(v) => v }),
    ("clones", jb(at(room, "clones") is Some(Bool(true)))),
    ("git", jb(at(room, "git") is Some(Bool(true)))),
  ])
}

///|
/// Where this station's retirement from `ws` stands, for station_retire.
fn Retire::status(self : Retire, ws : String) -> J {
  let o = self.overview(ws)
  let retiring = match (at(o, "retiring"), self.state) {
    (Some(Obj(_) as r), Some(s)) if s.workspace == ws =>
      merged(
        r,
        jo([
          ("wait", jb(s.wait)),
          ("files", jn(s.files)),
          ("sentAt", opt_num(s.sent_at)),
          ("driver", driver_json(s.driver)),
          ("jobsThere", s.jobs_there.unwrap_or(Null)),
          ("jobsStopped", ja(s.jobs.map(j => jo([("session", at(j, "session").unwrap_or(Null)), ("name", at(j, "name").unwrap_or(Null))])))),
        ]),
      )
    _ => Null
  }
  jo([
    ("retiring", retiring),
    ("taking", at(o, "taking").unwrap_or(ja([]))),
    ("taken", ja(self.took_here.filter(t => text_at(t, "workspace") == ws))),
  ])
}

///|
/// What retiring this station from `ws` would move (GET /retire/preview).
pub async fn Retire::preview(self : Retire, ws : String) -> J {
  let home = (self.d.home)() == Some(ws)
  let counts = (self.d.work.preview)(self.d.data, self.w.fs.join([self.d.data, "stillfail.db"]), ws, home)
  let own = (self.d.accounts_own)().map(p => jo([("id", js(p.0)), ("name", js(p.1))]))
  jo([
    ("home", jb(home)),
    ("chats", at(counts, "chats").unwrap_or(Null)),
    ("archived", at(counts, "archived").unwrap_or(Null)),
    ("outside", at(counts, "outside").unwrap_or(Null)),
    ("connects", ja((self.d.connects_named)(ws))),
    ("accounts", ja(if home { own } else { [] })),
    ("accountsStay", ja(if home { [] } else { own })),
    ("jobs", ja((self.d.jobs_in)(ws).map(j => jo([("name", at(j, "name").unwrap_or(Null)), ("session", at(j, "session").unwrap_or(Null))])))),
  ])
}

// ── another station's chats taken here ──

///|
/// What this station answers of it (`retire.*`).
pub async fn Retire::answer(self : Retire, in_workspace : (String, String) -> Bool, peer : String, request : J, body : Body?, workspace : String?) -> J {
  let ws = str_at(request, "workspace").unwrap_or("")
  if !is_workspace(ws) || (workspace is Some(w) && w != ws) || !in_workspace(peer, ws) {
    raise refused("not a station of this workspace")
  }
  let fs = self.w.fs
  match str_at(request, "method") {
    Some("retire.took") => {
      self.took(peer, Some(request))
      return jo([("ok", jb(true))])
    }
    Some("retire.failed") => {
      self.failed_there(peer, str_at(request, "error").unwrap_or(""))
      return jo([("ok", jb(true))])
    }
    Some("retire.tell") => {
      let session = str_at(request, "session").unwrap_or("")
      let text = match str_at(request, "text") {
        Some(t) => first_points(t, 4000)
        None => ""
      }
      if session == "" || text == "" {
        raise refused("session and text are needed")
      }
      if !(self.d.copies.formerly)().contains(peer) && !(self.d.drives)(peer, session) {
        raise refused("no session here asked for that station's retirement")
      }
      guard self.d.tell is Some(tell) else { raise refused("nobody to tell here") }
      tell(session, text) catch {
        e => raise refused(message_of(e))
      }
      return jo([("ok", jb(true))])
    }
    Some("retire.ask") => {
      let op = str_at(request, "op").unwrap_or("")
      let session = str_at(request, "session").unwrap_or("")
      let fields = [("op", js(op))]
      match str_at(request, "to") {
        Some(t) => fields.push(("to", js(t)))
        None => ()
      }
      match str_at(request, "by") {
        Some(b) => fields.push(("by", js(b)))
        None => ()
      }
      fields.push(("driver", if session == "" { Null } else { jo([("station", js(peer)), ("session", js(session))]) }))
      return self.agent_ask(ws, jo(fields))
    }
    _ => ()
  }
  if str_at(request, "origin") != Some(peer) {
    raise refused("a station's own chats only")
  }
  match str_at(request, "method") {
    Some("retire.begin") => merged(self.begin(peer, ws, request), self.room_here())
    Some("retire.room") => self.room_here()
    Some("retire.lacking") => {
      let hashes = items(at(request, "hashes"))
      let all_hashes = hashes.iter().all(h => match str_of(Some(h)) {
        Some(x) => is_hash(x)
        None => false
      })
      if hashes.length() > self.d.lack_most || !all_hashes {
        raise refused("at most \{self.d.lack_most} files' hashes")
      }
      match self.taking.get(peer) {
        Some(t) if t.workspace == ws => ()
        _ => raise refused("not begun: retire.begin first")
      }
      jo([
        ("lacking", jstrs(lacking_in(fs, fs.join([self.carried.dir(ws, peer), "files"]), strings_of(Some(Arr(hashes)))))),
        ("pack", js(pack_encoding)),
      ])
    }
    Some("retire.put") => {
      if text_at(request, "pack") == pack_encoding && at(request, "pack") is Some(Str(_)) {
        let named = match at(request, "name") {
          None => None
          Some(v) => Some(show_value(Some(v)))
        }
        if body is None || (named is Some(n) && !is_hash(n)) {
          raise refused("not a pack")
        }
        match self.taking.get(peer) {
          Some(t) if t.workspace == ws => ()
          _ => raise refused("not begun: retire.begin first")
        }
        receive_pack(fs, fs.join([self.carried.dir(ws, peer), "files"]), body.unwrap(), {
          strict: !(at(request, "strict") is Some(Bool(false))),
          flush: true,
          name: named,
          count: num_at(request, "count").map(n => n.to_int()),
          on_file: None,
        })
        return jo([("ok", jb(true))])
      }
      let name = match at(request, "name") {
        None | Some(Null) => ""
        v => show_value(v)
      }
      if body is None || !is_hash(name) {
        raise refused("not a file's hash")
      }
      match self.taking.get(peer) {
        Some(t) if t.workspace == ws => ()
        _ => raise refused("not begun: retire.begin first")
      }
      receive_file(fs, fs.join([self.carried.dir(ws, peer), "files"]), name, body.unwrap())
      jo([("ok", jb(true))])
    }
    Some("retire.take") => self.take_asked(peer, ws, request)
    Some("retire.accounts") => self.accounts_came(peer, ws, request)
    Some("retire.drop") => if yes_at(request, "keep") { self.keep(peer, ws) } else { self.drop(peer, ws) }
    _ => raise refused("no such retire request")
  }
}

///|
/// `[...text].slice(0, n).join("")`: the first `n` code points.
fn first_points(text : String, n : Int) -> String {
  let out = StringBuilder::new()
  let mut k = 0
  for c in text {
    if k >= n {
      break
    }
    out.write_char(c)
    k += 1
  }
  out.to_string()
}

///|
/// This station's disk and git, as a station sending it its chats asks.
async fn Retire::room_here(self : Retire) -> J {
  let (free, clones) = (self.d.room)() catch { _ => (None, false) }
  let git = (self.d.has_git)() catch { _ => false }
  jo([("free", opt_num(free)), ("clones", jb(clones)), ("git", jb(git))])
}

///|
async fn Retire::save_taking(self : Retire, t : Taking) -> Unit {
  self.w.fs.write_json(self.w.fs.join([taking_dir(self.w.fs, self.d.data), "\{t.origin}.json"]), t.to_json())
  self.changed(true)
}

///|
/// A station of the workspace says it is being retired, its chats coming here.
async fn Retire::begin(self : Retire, origin : String, ws : String, request : J) -> J {
  if (self.d.copies.formerly)().contains(origin) {
    return jo([("ok", jb(true)), ("took", jb(true))])
  }
  let was = self.taking.get(origin)
  if self.taking_runs.contains(origin) || (was is Some(w) && (w.step == "restart" || w.step == "took")) {
    raise refused("busy: this station is putting in what that station sent before")
  }
  let t : Taking = {
    origin,
    name: match str_at(request, "name") {
      Some(n) => n
      None =>
        match was {
          Some(w) => w.name
          None => ""
        }
    },
    workspace: ws,
    gen: "",
    carry: "",
    connects: [],
    bindings: [],
    step: "coming",
    placed: 0.0,
    missing: 0.0,
    gits: 0,
    gits_failed: 0,
    rooms: match was {
      Some(w) => w.rooms
      None => None
    },
    error: None,
    told: false,
    restarts: 0,
    driver: None,
    jobs: None,
    jobs_told: false,
    home: false,
    driver_told: false,
    failed_at: None,
    accounts: None,
  }
  match was {
    Some(w) if w.workspace != ws => self.w.fs.rm_rf(self.carried.dir(w.workspace, origin))
    _ => ()
  }
  self.taking[origin] = t
  self.save_taking(t)
  self.w.info("retire", "a station retired from a workspace sends its chats here", jo([("origin", js(origin)), ("workspace", js(ws))]))
  jo([("ok", jb(true))])
}

///|
async fn Retire::take_asked(self : Retire, origin : String, ws : String, request : J) -> J {
  let gen = show_value(Some(at(request, "gen").unwrap_or(js(""))))
  let carry = show_value(Some(at(request, "carry").unwrap_or(js(""))))
  if !is_gen(gen) || !is_hash(carry) {
    raise refused("not a copy's name")
  }
  if (self.d.copies.formerly)().contains(origin) {
    return jo([("ok", jb(true)), ("took", jb(true))])
  }
  guard self.taking.get(origin) is Some(was) && was.workspace == ws else { raise refused("not begun: retire.begin first") }
  if was.step == "took" {
    return jo([("ok", jb(true)), ("took", jb(true))])
  }
  let same = was.gen == gen && was.carry == carry
  let again = at(request, "again") is Some(Bool(true))
  if !self.taking_runs.contains(origin) && (!same || was.step == "coming" || (was.step == "failed" && again)) {
    let free = try {
      (self.d.room)().0
    } catch {
      _ => None
    }
    match free {
      Some(f) if f < headroom => {
        let failed = "\{self.here_name(ws)} has \{gb(f)} free, under the \{gb(headroom)} it keeps free to put the chats in: free some room there, then hand over again"
        self.w.warn("retire", "a retired station's chats not taken: this station's disk is about full", jo([("origin", js(origin)), ("free", jn(f))]))
        return jo([("ok", jb(true)), ("failed", js(failed))])
      }
      _ => ()
    }
  }
  if self.taking_runs.contains(origin) {
    if same {
      return jo([("ok", jb(true))])
    }
    raise refused("busy: this station is putting in another copy of that station's chats")
  }
  if same && was.step == "restart" {
    return jo([("ok", jb(true))])
  }
  was.connects = string_map(at(request, "connects"))
  was.bindings = string_map(at(request, "bindings"))
  was.driver = match at(request, "driver") {
    Some(Obj(_) as d) =>
      match (str_at(d, "station"), str_at(d, "session")) {
        (Some(st), Some(se)) if is_station(st) && se != "" => Some({ station: st, session: se })
        _ => None
      }
    _ => None
  }
  match str_at(request, "name") {
    Some(n) if n != "" => was.name = n
    _ => ()
  }
  was.accounts = match at(request, "accounts") {
    Some(Bool(b)) => Some(b)
    _ => None
  }
  if !same || was.step == "coming" {
    was.gen = gen
    was.carry = carry
    was.step = "placing"
  } else if was.step == "failed" {
    if !again {
      return jo([("ok", jb(true)), ("failed", js(was.error.unwrap_or("")))])
    }
    match (self.d.copies.restored)() {
      Some(o) if text_at(o, "origin") == origin => self.w.fs.rm_f(outcome_file(self.w.fs, self.d.data))
      _ => ()
    }
    was.step = was.failed_at.unwrap_or("copy")
    was.failed_at = None
    was.restarts = 0
  }
  was.error = None
  was.told = false
  self.save_taking(was)
  self.take(was)
  jo([("ok", jb(true))])
}

///|
/// The station retired calls it off: what it sent goes, unless this station is putting it in or took its place.
async fn Retire::drop(self : Retire, origin : String, ws : String) -> J {
  if (self.d.copies.formerly)().contains(origin) {
    return jo([("took", jb(true))])
  }
  guard self.taking.get(origin) is Some(t) && t.workspace == ws else { return jo([("dropped", jb(true))]) }
  if t.step == "took" {
    return jo([("took", jb(true))])
  }
  let fs = self.w.fs
  let ready = match fs.read_json(ready_file(fs, self.d.data)) {
    Some(r) => text_at(r, "origin") == origin
    None => false
  }
  if ready {
    return jo([("took", jb(true))])
  }
  if self.taking_runs.contains(origin) {
    raise refused("busy: this station is putting them in place just now")
  }
  match self.take_again.get(origin) {
    Some(f) => f()
    None => ()
  }
  self.take_again.remove(origin)
  self.taking.remove(origin)
  fs.rm_rf(self.carried.dir(t.workspace, origin))
  for room in t.rooms.unwrap_or([]) {
    fs.rm_rf(room)
  }
  fs.rm_f(fs.join([taking_dir(fs, self.d.data), "\{origin}.json"]))
  self.w.info("retire", "a station's retirement called off: what it sent here is gone", jo([("origin", js(origin)), ("workspace", js(ws))]))
  self.changed(true)
  jo([("dropped", jb(true))])
}

///|
/// The station retired puts its chats back to work: what it sent stays, nothing of it is put in by itself.
async fn Retire::keep(self : Retire, origin : String, ws : String) -> J {
  if (self.d.copies.formerly)().contains(origin) {
    return jo([("took", jb(true))])
  }
  guard self.taking.get(origin) is Some(t) && t.workspace == ws else { return jo([("kept", jb(true))]) }
  if t.step == "took" {
    return jo([("took", jb(true))])
  }
  if self.taking_runs.contains(origin) {
    raise refused("busy: this station is putting them in place just now")
  }
  if t.step != "coming" && t.step != "failed" {
    raise refused("busy: this station is about to put them in")
  }
  let fs = self.w.fs
  let ready = match fs.read_json(ready_file(fs, self.d.data)) {
    Some(r) => text_at(r, "origin") == origin
    None => false
  }
  if ready {
    fs.rm_rf(restore_dir(fs, self.d.data))
  }
  self.w.info("retire", "a retired station's chats work there again: what it sent is kept, nothing put in", jo([("origin", js(origin)), ("workspace", js(ws))]))
  jo([("kept", jb(true))])
}

///|
fn Retire::take(self : Retire, t : Taking) -> Unit {
  if self.taking_runs.contains(t.origin) || self.closed {
    return
  }
  match self.take_again.get(t.origin) {
    Some(f) => f()
    None => ()
  }
  self.take_again.remove(t.origin)
  let current = () => match self.taking.get(t.origin) {
    Some(x) => physical_equal(x, t)
    None => false
  }
  let run = self.w.run(async fn() {
    try {
      self.taken(t)
    } catch {
      e => {
        t.error = Some(message_of(e))
        self.w.warn("retire", "a retired station's chats not taken yet", jo([("origin", js(t.origin)), ("step", js(t.step)), ("error", jopt(t.error))]))
        if !self.closed && current() && (t.step == "placing" || t.step == "gits") {
          t.failed_at = Some(t.step)
          t.step = "failed"
          t.told = false
          self.save_taking(t) catch {
            x => self.w.warn("retire", "where a take stands not written", jo([("origin", js(t.origin)), ("error", js(message_of(x)))]))
          }
        } else {
          self.changed(true)
          if !self.closed && current() {
            // timer: a retry after a failure
            self.take_again[t.origin] = self.w.after(retire_retry_ms, () => self.take(t))
          }
        }
      }
    }
    self.taking_runs.remove(t.origin)
    if t.step == "failed" && !t.told && current() {
      self.tell(t, 0)
    }
  })
  if !run.is_done() {
    self.taking_runs[t.origin] = run
  }
}

///|
async fn Retire::taken(self : Retire, t : Taking) -> Unit {
  t.error = None
  let fs = self.w.fs
  let dir = self.carried.dir(t.workspace, t.origin)
  let files = fs.join([dir, "files"])
  let index_path = fs.join([files, t.carry])
  let index = parse(fs.read_text_strict(index_path))
  if t.step == "placing" {
    if t.rooms is None {
      let fresh = []
      for s in items(at(index, "sessions")) {
        guard str_at(s, "room") is Some(r) else { continue }
        let room = fs.resolve(moved(fs, r, text_at(index, "dataDir"), self.d.data))
        if room.has_prefix(fs.resolve(self.d.data, rest=["sessions"]) + fs.sep) && !fs.there(room) {
          fresh.push(room)
        }
      }
      t.rooms = Some(fresh)
      self.save_taking(t)
    }
    let placed = (self.d.work.place)(self.d.data, index_path, files, None, None, None, false)
    t.placed = num_at(placed, "placed").unwrap_or(0.0) + num_at(placed, "kept").unwrap_or(0.0)
    t.missing = num_at(placed, "missing").unwrap_or(0.0)
    if t.missing > 0.0 {
      self.save_taking(t)
      let n = t.missing.to_int()
      let who = if t.name != "" { t.name } else { "the station retired" }
      raise failed(
        "\{n} file\{if n == 1 { "" } else { "s" }} that \{who} sent \{if n == 1 { "is" } else { "are" }} not here: hand over again, which sends \{if n == 1 { "it" } else { "them" }} again",
      )
    }
    t.step = "gits"
    self.save_taking(t)
  }
  if t.step == "gits" {
    let (made, failed_n) = rebuild_gits(self.w, self.d.data, self.d.repos_dir, index, files, self.d.git)
    t.gits = made
    t.gits_failed = failed_n
    t.step = "copy"
    self.save_taking(t)
  }
  if t.step == "copy" || t.step == "restart" {
    t.step = "restart"
    t.restarts += 1
    self.save_taking(t)
    (self.d.copies.take_over)(t.workspace, t.origin, t.gen, t.connects, if (self.d.home)() == Some(t.workspace) { None } else { Some(t.workspace) })
  }
}

///|
/// This station took `t`'s station's place: its agent home merged, the jobs started again, the bindings set, each
/// moved chat's agent to be told, what wakes them kept to be told once its accounts came.
async fn Retire::took_place(self : Retire, t : Taking) -> Unit {
  let fs = self.w.fs
  let dir = self.carried.dir(t.workspace, t.origin)
  let files = fs.join([dir, "files"])
  let index = match fs.read_text(fs.join([files, t.carry])) {
    Some(x) => Some(parse(x)) catch { _ => None }
    None => None
  }
  let at_ms = self.w.now()
  let lost = if index is None {
    Some(
      "what went along with the chats (their index) was not on this station as it took them: no job of theirs was started again here, and no chat was told it moved",
    )
  } else {
    None
  }
  if lost is Some(_) {
    self.w.warn("retire", "a retired station's chats taken here without what went along with them", jo([("origin", js(t.origin)), ("workspace", js(t.workspace))]))
  }
  match index {
    Some(index) if !t.home => {
      let agent = match at(index, "agent") {
        Some(Obj(_) as a) => Some(a)
        _ => None
      }
      let to = match (agent, self.d.agent_home) {
        (Some(_), Some(f)) => f(t.workspace)
        _ => None
      }
      match (to, agent) {
        (Some(to), Some(a)) => {
          let merged_home = merge_agent_home(fs, to, a, fs.join([files, text_at(a, "list")]), files, t.origin, t.name, at_ms) catch {
            e => {
              self.w.warn("retire", "a retired station's agent home not merged here", jo([("origin", js(t.origin)), ("error", js(message_of(e)))]))
              HomeMerged::{ memory: "", presets: -1, skills: [], skills_kept: [] }
            }
          }
          if merged_home.presets >= 0 {
            self.w.info("retire", "a retired station's agent home merged here", merged(jo([("origin", js(t.origin))]), merged_home.to_json()))
          }
        }
        _ => ()
      }
      t.home = true
      self.save_taking(t)
    }
    _ => ()
  }
  match index {
    Some(index) if t.jobs is None => {
      t.jobs = Some(self.start_jobs(index))
      self.save_taking(t)
    }
    _ => ()
  }
  let bindings = t.bindings.map(b => (pair_get(t.connects, b.0).unwrap_or(b.0), b.1))
  let here = (self.d.here)()
  let name = match here {
    None => ""
    Some(h) =>
      match (self.d.roster)(t.workspace) {
        Some(r) =>
          match r.search_by(m => m.id == h) {
            Some(i) => r[i].name
            None => ""
          }
        None => ""
      }
  }
  let notes = match index {
    None => []
    Some(index) =>
      items(at(index, "sessions")).map(s => jo([
        ("session", at(s, "key").unwrap_or(Null)),
        ("text", js(moved_note(fs, t.name, name, index, s, self.d.data, self.d.repos_dir, t.jobs))),
      ]))
  }
  (self.d.took)(pairs_json(bindings), ja(notes))
  if !t.jobs_told {
    match index {
      Some(index) => {
        fs.mkdirs(took_dir(fs, self.d.data))
        fs.write_text(keys_file(fs, self.d.data, t.origin), items(at(index, "sessions")).map(s => "\{text_at(s, "key")}\n").join(""))
      }
      None => ()
    }
    let from = "This chat moved here from station \{if t.name != "" { t.name } else { head_of(t.origin, 12) }}"
    let by : Array[(String, Array[String])] = []
    for j in t.jobs.unwrap_or([]) {
      if yes_at(j, "old") {
        continue
      }
      let error = if yes_at(j, "started") { None } else { Some(str_at(j, "why").unwrap_or("not started")) }
      let said = moved_said(from, text_at(j, "name"), num_at(j, "port"), str_at(j, "id"), error)
      let session = text_at(j, "session")
      match by.search_by(x => x.0 == session) {
        Some(i) => by[i].1.push(said)
        None => by.push((session, [said]))
      }
    }
    let mut driver = J::Null
    match (t.driver, index) {
      (Some(d), Some(index)) if d.station == t.origin &&
        items(at(index, "sessions")).iter().any(s => text_at(s, "key") == d.session) &&
        self.d.tell is Some(_) => {
        let jobs = job_words(t.jobs.unwrap_or([]))
        let who = if t.name != "" { t.name } else { head_of(t.origin, 12) }
        let n = items(at(index, "sessions")).length()
        driver = jo([
          ("session", js(d.session)),
          (
            "text",
            js(
              "Retiring station \{who}: its chats were taken here, this chat with them (\{n} chats); this station is that one too now.\{if jobs == "" { "" } else { " \{jobs}" }} The retired station tells you what is left as it moves its accounts and connects here. Check that the chats go on here (see the stillfail-retire skill).",
            ),
          ),
        ])
        t.driver_told = true
      }
      _ => ()
    }
    let wake = jo([
      ("origin", js(t.origin)),
      ("workspace", js(t.workspace)),
      ("at", jn(at_ms)),
      ("says", ja(by.map(x => ja([js(x.0), js(x.1.join("\n"))])))),
      ("driver", driver),
      ("accounts", match t.accounts { Some(b) => jb(b); None => Null }),
    ])
    fs.write_json(wake_file(fs, self.d.data, t.origin), wake)
    self.wakes[t.origin] = wake
    t.jobs_told = true
    self.save_taking(t)
  }
  let chats = match index {
    Some(i) => items(at(i, "sessions")).length()
    None => 0
  }
  self.took_here = [
    ..self.took_here.filter(x => text_at(x, "origin") != t.origin),
    jo([
      ("origin", js(t.origin)),
      ("name", js(t.name)),
      ("workspace", js(t.workspace)),
      ("at", jn(at_ms)),
      ("chats", ji(chats)),
      ("jobs", ja(t.jobs.unwrap_or([]))),
      ("error", jopt(lost)),
    ]),
  ]
  if self.took_here.length() > taken_kept {
    self.took_here = self.took_here[self.took_here.length() - taken_kept:].to_array()
  }
  fs.write_json(taken_file(fs, self.d.data), ja(self.took_here))
  fs.rm_rf(dir)
  t.step = "took"
  t.error = lost
  self.save_taking(t)
  self.wake_soon(t.origin)
  self.w.info("retire", "a retired station's chats went on here", jo([("origin", js(t.origin)), ("workspace", js(t.workspace))]))
}

///|
/// What wakes the chats taken of `origin` told once its accounts came, or by ACCOUNTS_WAIT_MS after they were taken.
fn Retire::wake_soon(self : Retire, origin : String) -> Unit {
  guard self.wakes.get(origin) is Some(w) && !self.wake_at.contains(origin) && !self.closed else { return }
  let left = num_at(w, "at").unwrap_or(0.0) + accounts_wait_ms - self.w.now()
  let none = at(w, "accounts") is Some(Bool(false))
  if none || left <= 0.0 {
    self.wake(origin, !none)
    return
  }
  // timer: a deadline (the retired station's accounts not told)
  self.wake_at[origin] = self.w.after(left, () => self.wake(origin, true))
}

///|
fn Retire::wake(self : Retire, origin : String, late : Bool) -> Unit {
  let w = self.wakes.get(origin)
  match self.wake_at.get(origin) {
    Some(f) => f()
    None => ()
  }
  self.wake_at.remove(origin)
  guard w is Some(w) else { return }
  self.wakes.remove(origin)
  let fs = self.w.fs
  let data = self.d.data
  // (what was said, in order, and the driver)
  let says = items(at(w, "says")).map(x => {
    let p = items(Some(x))
    (str_of(p.get(0)).unwrap_or(""), str_of(p.get(1)).unwrap_or(""))
  })
  let driver = match at(w, "driver") {
    Some(Obj(_) as d) => Some((text_at(d, "session"), text_at(d, "text")))
    _ => None
  }
  let mine : Ref[Run?] = Ref(None)
  let telling = self.w.run(async fn() {
    match self.d.jobs {
      Some(j) => for s in says { (j.say)(s.0, s.1) }
      None => ()
    }
    match driver {
      Some((session, text)) => {
        let said = if late {
          "\{text} Its accounts have not come here yet (the retired station moves them after it hears its chats were taken): a chat that takes a turn before they do goes on on another account here, afresh. station_retire status on the retired station says where it stands."
        } else {
          text
        }
        match self.d.tell {
          Some(t) =>
            t(session, said) catch {
              e => self.w.warn("retire", "who asked for the retirement not told here", jo([("session", js(session)), ("error", js(message_of(e)))]))
            }
          None => ()
        }
      }
      None => ()
    }
    if late {
      self.w.warn("retire", "a retired station's accounts not told here in time: its chats woken before they came", jo([("origin", js(origin))]))
    }
    fs.rm_f(wake_file(fs, data, origin))
    match mine.val {
      Some(m) =>
        match self.waking.search_by(r => physical_equal(r, m)) {
          Some(i) => ignore(self.waking.remove(i))
          None => ()
        }
      None => ()
    }
  })
  mine.val = Some(telling)
  if !telling.is_done() {
    self.waking.push(telling)
  }
}

///|
/// The station retired says what became of its accounts (`retire.accounts`).
async fn Retire::accounts_came(self : Retire, origin : String, ws : String, request : J) -> J {
  if !(self.d.copies.formerly)().contains(origin) {
    raise refused("this station has not taken that station's chats")
  }
  let map : Array[(String, String)] = []
  for m in items(at(request, "moved")) {
    match (str_at(m, "was"), str_at(m, "id")) {
      (Some(was), Some(id)) if was != "" && id != "" && was != id =>
        match map.search_by(x => x.0 == was) {
          Some(i) => map[i] = (was, id)
          None => map.push((was, id))
        }
      _ => ()
    }
  }
  let fs = self.w.fs
  let keys = fs.read_text(keys_file(fs, self.d.data, origin)).unwrap_or("").split("\n").map(v => v.to_string()).filter(k => k != "").collect()
  let followed = if map.length() == 0 || keys.length() == 0 {
    0
  } else {
    match self.d.follow_accounts {
      Some(f) => f(keys, map)
      None => 0
    }
  }
  let left = strings_of(at(request, "left"))
  self.w.info(
    "retire",
    "a retired station's accounts came: its chats taken here follow them",
    jo([
      ("origin", js(origin)),
      ("workspace", js(ws)),
      ("moved", jstrs(map.map(m => "\{m.0}->\{m.1}"))),
      ("left", jstrs(left)),
      ("sessions", ji(followed)),
    ]),
  )
  fs.rm_f(keys_file(fs, self.d.data, origin))
  self.wake(origin, false)
  jo([("ok", jb(true))])
}

///|
/// The jobs `index` says its chats had running, started again here in their sessions.
async fn Retire::start_jobs(self : Retire, index : J) -> Array[J] {
  let fs = self.w.fs
  let out = []
  let keys = items(at(index, "sessions")).map(s => text_at(s, "key"))
  let from = fs.resolve(text_at(index, "dataDir"))
  for j in items(at(index, "jobs")) {
    let session = text_at(j, "session")
    if !keys.contains(session) {
      continue
    }
    let name = text_at(j, "name")
    let command = text_at(j, "command")
    let port = num_at(j, "port")
    let o = [
      ("session", js(session)),
      ("name", js(name)),
      ("command", js(command)),
      ("port", opt_num(port)),
      ("id", Null),
      ("started", jb(false)),
      ("why", Null),
    ]
    let base = jo(o)
    match (str_at(j, "cwd"), self.d.jobs) {
      (Some(cwd0), Some(jobs)) => {
        let cwd = fs.resolve(cwd0)
        if cwd != from && !cwd.has_prefix(from + fs.sep) {
          out.push(set(base, "why", js("it ran in \{cwd0}, which was not the retired station's own and did not move")))
          continue
        }
        if (jobs.running)(session, name, command) {
          out.push(set(base, "started", jb(true)))
          continue
        }
        try {
          let made = (jobs.start)(
            session,
            jo([
              ("name", js(name)),
              ("command", js(command)),
              ("cwd", js(moved(fs, cwd, from, self.d.data))),
              ("port", opt_num(port)),
              ("watch", jb(yes_at(j, "watch"))),
            ]),
          )
          out.push(
            set(set(set(set(base, "started", jb(true)), "id", at(made, "id").unwrap_or(Null)), "name", at(made, "name").unwrap_or(Null)), "port", at(
                made, "port",
              ).unwrap_or(Null)),
          )
        } catch {
          e => {
            self.w.warn("retire", "a moved chat's job not started again", jo([("session", js(session)), ("job", js(name)), ("error", js(message_of(e)))]))
            out.push(set(base, "why", js(message_of(e))))
          }
        }
      }
      _ => out.push(set(base, "old", jb(true)))
    }
  }
  out
}

///|
/// The station retired told how its chats went here (`retire.took`, `retire.failed`), until it answers.
fn Retire::tell(self : Retire, t : Taking, tries : Int) -> Unit {
  if self.closed || self.tell_runs.contains(t.origin) || (t.step != "took" && t.step != "failed") {
    return
  }
  match self.tell_again.get(t.origin) {
    Some(f) => f()
    None => ()
  }
  self.tell_again.remove(t.origin)
  let took = t.step == "took"
  let fields = [("method", js(if took { "retire.took" } else { "retire.failed" })), ("workspace", js(t.workspace)), ("error", jopt(t.error))]
  if took {
    fields.push(("jobs", ja(t.jobs.unwrap_or([]))))
    fields.push(("driverTold", jb(t.driver_told)))
    fields.push(("lost", jopt(t.error)))
  }
  let run = self.w.run(async fn() {
    try {
      ignore(self.w.ask_itself(t.origin, jo(fields)))
    } catch {
      _ => {
        self.tell_runs.remove(t.origin)
        if self.closed || !(self.taking.get(t.origin) is Some(x) && physical_equal(x, t)) {
          return
        }
        let wait = backoff(retire_retry_ms, tries, retire_retry_most_ms)
        // timer: a retry after a failure
        self.tell_again[t.origin] = self.w.after(wait, () => self.tell(t, tries + 1))
        return
      }
    }
    if took {
      match self.taking.get(t.origin) {
        Some(x) if physical_equal(x, t) => self.taking.remove(t.origin)
        _ => ()
      }
      self.w.fs.rm_f(self.w.fs.join([taking_dir(self.w.fs, self.d.data), "\{t.origin}.json"]))
      self.changed(true)
    } else {
      t.told = true
      self.save_taking(t)
    }
    self.tell_runs.remove(t.origin)
  })
  if !run.is_done() {
    self.tell_runs[t.origin] = run
  }
}

// ── what the settings show ──

///|
/// Where this station stands in being retired from `ws`, and the chats of retired stations being taken here.
pub fn Retire::overview(self : Retire, ws : String) -> J {
  let retiring = match self.state {
    Some(s) if s.workspace == ws =>
      jo([
        ("workspace", js(s.workspace)),
        ("to", js(s.to)),
        ("toName", js(s.to_name)),
        ("by", js(s.by)),
        ("at", jn(s.at)),
        ("step", js(s.step)),
        ("done", jn(s.done)),
        ("total", jn(s.total)),
        ("error", jopt(s.error)),
        ("reason", jopt(s.reason)),
        ("cancellable", jb(s.step == "sending" || s.step == "sent" || s.step == "quiet" || s.step == "handing")),
        ("retriable", jb(s.error is Some(_) && s.step != "done")),
        ("accountsLeft", ja(s.accounts_left)),
        ("home", jb((self.d.home)() == Some(s.workspace))),
      ])
    _ => Null
  }
  let taking = self.taking
    .values()
    .filter(t => t.workspace == ws && t.step != "took")
    .map(t => jo([("origin", js(t.origin)), ("name", js(t.name)), ("step", js(t.step)), ("error", jopt(t.error))]))
    .collect()
  jo([("retiring", retiring), ("taking", ja(taking))])
}

///|
/// A linked worktree `rebuild_gits` made: its directory, its repository, the branch and the ref it made there.
pub struct MadeGit {
  dir : String
  repo : String
  branch : String?
  ref_ : String?
}

///|
pub fn MadeGit::to_json(self : MadeGit) -> J {
  jo([("dir", js(self.dir)), ("repo", js(self.repo)), ("branch", jopt(self.branch)), ("ref", jopt(self.ref_))])
}

///|
/// Each linked worktree `carry` names made again here by git (retire.ts `rebuildGits`). What it made and failed.
pub async fn rebuild_gits(
  w : World,
  data : String,
  repos_dir : String,
  carry : J,
  from : String,
  git : async (String, Array[String]) -> String,
  clone? : Bool = true,
  made? : (async (MadeGit) -> Unit)? = None,
) -> (Int, Int) {
  let fs = w.fs
  let mut made_n = 0
  let mut failed_n = 0
  let repos : Map[String, String] = {}
  let repo_of = async fn(remote : String) -> String {
    match repos.get(remote) {
      Some(d) => return d
      None => ()
    }
    fs.mkdirs(repos_dir)
    let names = fs.names(repos_dir)
    names.sort_by(js_cmp)
    for name in names {
      if name.has_prefix(".") {
        continue
      }
      let dir = fs.join([repos_dir, name])
      let url = git(dir, ["remote", "get-url", "origin"]) catch { _ => "\u{0}" }
      if url == remote {
        repos[remote] = dir
        return dir
      }
    }
    if !clone {
      raise failed("its repository (\{remote}) is not on this station: move it first (station_move, module repos)")
    }
    let mut base = fs.basename(remote)
    if base.has_suffix(".git") {
      base = base.unsafe_substring(start=0, end=base.length() - 4)
    }
    let b = StringBuilder::new()
    for i in 0..<base.length() {
      let c = base.unsafe_charcode_at(i)
      if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-' {
        b.write_char(c.unsafe_to_char())
      } else {
        b.write_char('-')
      }
    }
    base = if b.to_string() == "" { "repo" } else { b.to_string() }
    let mut name = base
    let mut i = 2
    while fs.there(fs.join([repos_dir, name])) {
      name = "\{base}-\{i}"
      i += 1
    }
    let temp = ".cloning-\{fs.random_hex(4)}"
    try {
      ignore(git(repos_dir, ["clone", "-q", "--", remote, temp]))
      fs.rename(fs.join([repos_dir, temp]), fs.join([repos_dir, name]))
    } catch {
      e => {
        fs.rm_rf(fs.join([repos_dir, temp]))
        raise e
      }
    }
    fs.rm_rf(fs.join([repos_dir, temp]))
    let dir = fs.join([repos_dir, name])
    repos[remote] = dir
    dir
  }
  for g in items(at(carry, "gits")) {
    let dir = fs.resolve(moved(fs, text_at(g, "dir"), text_at(carry, "dataDir"), data))
    let bundle = str_at(g, "bundle")
    try {
      if !dir.has_prefix(fs.resolve(data) + fs.sep) {
        raise failed("not under this station's data directory")
      }
      if fs.there(fs.join([dir, ".git"])) {
        made_n += 1
        continue
      }
      let repo = repo_of(text_at(g, "remote"))
      let head = text_at(g, "head")
      let ref_ = "refs/carried/\{head}"
      let ref_before = match bundle {
        None => true
        Some(_) =>
          try {
            ignore(git(repo, ["rev-parse", "-q", "--verify", ref_]))
            true
          } catch {
            _ => false
          }
      }
      let fetch_origin = async fn() { ignore(git(repo, ["fetch", "-q", "--no-write-fetch-head", "origin"])) }
      match bundle {
        Some(bn) => {
          let from_bundle = async fn() { ignore(git(repo, ["fetch", "-q", fs.join([from, bn]), "+HEAD:\{ref_}"])) }
          from_bundle() catch {
            _ => {
              fetch_origin()
              from_bundle()
            }
          }
        }
        None => ()
      }
      let lacks = try {
        ignore(git(repo, ["cat-file", "-e", "\{head}^{commit}"]))
        false
      } catch {
        _ => true
      }
      if lacks {
        fetch_origin()
      }
      let beside = "\{dir}.git-carrying"
      fs.rm_rf(beside)
      ignore(git(repo, ["worktree", "add", "-f", "-f", "-q", "--no-checkout", "--detach", beside, head]))
      match made {
        Some(f) => f({ dir, repo, branch: None, ref_: if ref_before { None } else { Some(ref_) } })
        None => ()
      }
      fs.rename(fs.join([beside, ".git"]), fs.join([dir, ".git"]))
      fs.rm_rf(beside)
      ignore(git(dir, ["worktree", "repair"]))
      ignore(git(dir, ["reset", "-q"]))
      match str_at(g, "branch") {
        Some(branch) => {
          let at_branch = try {
            Some(git(repo, ["rev-parse", "-q", "--verify", "refs/heads/\{branch}"]))
          } catch {
            _ => None
          }
          if at_branch is None {
            match made {
              Some(f) => f({ dir, repo, branch: Some(branch), ref_: if ref_before { None } else { Some(ref_) } })
              None => ()
            }
            ignore(git(dir, ["checkout", "-q", "-b", branch]))
          }
        }
        None => ()
      }
      made_n += 1
    } catch {
      e => {
        failed_n += 1
        match bundle {
          Some(bn) =>
            fs.copy(fs.join([from, bn]), "\{dir}.carried.bundle") catch {
              _ => ()
            }
          None => ()
        }
        w.warn("retire", "a checkout not made again by git: its files are there", jo([("dir", js(dir)), ("error", js(message_of(e)))]))
      }
    }
  }
  (made_n, failed_n)
}
