// codex.ts: Codex, one shared `codex app-server` per profile under a runner whose id comes from the profile, one
// thread per session, spoken to in JSON-RPC: the app-servers it starts, takes up, replaces (Codex updated under one, a
// sign-in changed, its output grown long, its profile changed) and ends once idle; a thread opened (started or
// resumed, with the station's tools in its config), its turns (start, steer, interrupt, compact), what a turn runs with
// (model, effort, Fast or Ultrafast as its service tier), and what a next station takes it up from. Its notifications
// are read by the program (mb/src/codex, reader agents_codex.mbt); what comes here is the lines Node answers and each
// thread's events.

///|
let codex_scrubbed : Array[String] = ["OPENAI_API_KEY", "CODEX_HOME"]

///|
/// The CA file Codex is pointed at.
let ca_bundle = "/etc/ssl/cert.pem"

///|
/// What the station before ran on a host handed over, in its `turn_from` while its sessions are taken up.
let before_key = "\u{0}before"

///|
/// While sessions are being taken up, what comes for a thread not taken up yet waits this long for it.
let orphans_ms = 60000.0

///|
/// The most of an app-server's output kept for reading turns again after a crash, and how much once that is passed.
let kept_most = 268435456

///|
let kept_after = 67108864

///|
/// How often what `codex` on the PATH is now is read again.
let installed_ms = 60000.0

///|
/// An app-server with no turn and nothing asked of it this long ends.
let warm_ms = 1800000.0

///|
/// Bytes of output an app-server may have before it is replaced.
let output_limit = 67108864

///|
/// Lines, or bytes, of an app-server's output read again at a time before the station is let go.
let take_up_lines = 4096

///|
let take_up_bytes = 16777216

///|
/// A borrowed login this close to its end is replaced under the app-server running on it.
let lent_renew_ms = 21600000.0

///|
/// JavaScript's `a < b` of two strings: by their code units.
pub fn js_less(a : String, b : String) -> Bool {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = a.unsafe_charcode_at(i)
    let y = b.unsafe_charcode_at(i)
    if x != y {
      return x < y
    }
  }
  a.length() < b.length()
}

///|
pub fn js_compare(a : String, b : String) -> Int {
  if js_less(a, b) {
    -1
  } else if js_less(b, a) {
    1
  } else {
    0
  }
}

///|
/// Pairs sorted by their keys as `[...].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)` sorts them.
pub fn sorted_pairs(pairs : Array[(String, String)]) -> Array[(String, String)] {
  let out = pairs.copy()
  out.sort_by((x, y) => js_compare(x.0, y.0))
  out
}

///|
/// Paths in the order Rust sorts PathBufs: component by component (`comparePaths`).
pub fn compare_paths(a : String, b : String) -> Int {
  let x = a.split("/").map(p => p.to_string()).collect()
  let y = b.split("/").map(p => p.to_string()).collect()
  let n = if x.length() < y.length() { x.length() } else { y.length() }
  for i in 0..<n {
    if x[i] != y[i] {
      return if js_less(x[i], y[i]) { -1 } else { 1 }
    }
  }
  x.length() - y.length()
}

///|
/// The user's own skills turned off by path (`hostSkillsOff`): the SKILL.md files a bounded walk found, sorted.
pub fn skills_off(found : Array[String]) -> JValue {
  let paths = found.copy()
  paths.sort_by(compare_paths)
  arr(paths.map(p => obj([("path", s(p)), ("enabled", b(false))])))
}

///|
/// The first version-like word of a text (updates/versions.ts `versionIn`).
pub fn version_in(text : String) -> String? {
  let words = []
  let cur = StringBuilder()
  for c in text {
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\u{b}' || c == '\u{c}' ||
      c == '(' || c == ')' || c == ',' || @jscase.is_white_space(c.to_int()) {
      words.push(cur.to_string())
      cur.reset()
    } else {
      cur.write_char(c)
    }
  }
  words.push(cur.to_string())
  for raw in words {
    let mut w = raw
    while w.has_prefix("v") {
      w = w.substring(start=1)
    }
    if w.contains(".") &&
      w
      .split(".")
      .all(p => p.length() > 0 && p.code_unit_at(0) >= 0x30 && p.code_unit_at(0) <= 0x39) {
      return Some(w)
    }
  }
  None
}

///|
/// The version in what an app-server answered `initialize` with (`userAgentVersion`).
pub fn user_agent_version(user_agent : JValue?) -> String? {
  guard str_of(user_agent) is Some(ua) else { return None }
  let first = match ua.find(" ") {
    _ => {
      let mut end = ua.length()
      for i, c in ua {
        if @jscase.is_white_space(c.to_int()) {
          end = i
          break
        }
      }
      ua.substring(end~)
    }
  }
  let parts = first.split("/").map(p => p.to_string()).collect()
  version_in(if parts.length() > 1 { parts[1] } else { "" })
}

///|
/// The models the account can run in Codex, their efforts and default levels (`ModelCatalog`).
pub struct ModelCatalog {
  mut models : Array[String]
  efforts : Array[(String, Array[String])]
  defaults : Array[(String, String)]
  mut ultrafast_models : Array[String]?
}

///|
pub fn ModelCatalog::new() -> ModelCatalog {
  { models: [], efforts: [], defaults: [], ultrafast_models: None }
}

///|
pub fn[T] put_pair(pairs : Array[(String, T)], k : String, v : T) -> Unit {
  match pairs.search_by(p => p.0 == k) {
    Some(i) => pairs[i] = (k, v)
    None => pairs.push((k, v))
  }
}

///|
/// A page of `model/list`'s answer taken in (`extend`).
pub fn ModelCatalog::take_page(self : ModelCatalog, answer : JValue?) -> Unit raise {
  guard arr_at(answer, "data") is Some(rows) else { raise Failed("model/list omitted data") }
  for m in rows {
    if is_true(Some(m), "hidden") {
      continue
    }
    let id = match get(Some(m), "id") {
      Some(Str(u)) => Some(@jsjson.text(u))
      None => str_at(Some(m), "model")
      _ => None
    }
    guard id is Some(id) && id != "" else { continue }
    self.models.push(id)
    let tiers = match arr_at(Some(m), "serviceTiers") {
      Some(tiers) => Some(tiers.filter_map(tier => str_at(Some(tier), "id")))
      None => arr_at(Some(m), "additionalSpeedTiers").map(tiers => tiers.filter_map(tier => str_of(Some(tier))))
    }
    if tiers is Some(tiers) {
      let models = self.ultrafast_models.unwrap_or([])
      if tiers.contains("ultrafast") && !models.contains(id) {
        models.push(id)
      }
      self.ultrafast_models = Some(models)
    }
    match arr_at(Some(m), "supportedReasoningEfforts") {
      Some(levels) => {
        let efforts = []
        for level in levels {
          match str_at(Some(level), "reasoningEffort") {
            Some(e) if e != "" && !efforts.contains(e) => efforts.push(e)
            _ => ()
          }
        }
        put_pair(self.efforts, id, efforts)
      }
      None => ()
    }
    match str_at(Some(m), "defaultReasoningEffort") {
      Some(e) if e != "" => put_pair(self.defaults, id, e)
      _ => ()
    }
  }
}

///|
pub fn ModelCatalog::to_json(self : ModelCatalog) -> JValue {
  let fields = [
    ("models", strs(self.models)),
    ("efforts", obj(self.efforts.map(e => (e.0, strs(e.1))))),
    ("defaults", obj(self.defaults.map(e => (e.0, s(e.1))))),
  ]
  if self.ultrafast_models is Some(models) {
    fields.push(("ultrafastModels", strs(models)))
  }
  obj(fields)
}

///|
pub fn no_live_state() -> JValue {
  obj([("open", arr([])), ("phase", Null)])
}

///|
/// A thread's share of its app-server's notifications (`Notice`).
pub enum Notice {
  Events(Array[JValue], JValue, Bool)
  HostExited(String)
}

///|
/// What a crashed station had seen of a thread (`Recovered`).
pub struct Recovered {
  mut busy : Bool
  mut turn_id : String?
  mut live : JValue
}

///|
/// What the Codex driver is given beside the machine (codex.ts `CodexDriverOptions`, and what it reads elsewhere).
pub(all) struct CodexWorld {
  /// the station's environment for what it starts, before it is scrubbed (`startEnv`'s source)
  raw_env : Env
  /// config.json's `agentEnv` (`agentEnv`)
  agent_env : () -> Array[(String, String)]
  /// where the user's own skills are walked for their SKILL.md files (`hostSkillsOff`'s walk)
  walk_skills : (String) -> Later[Array[String]]
  host_skills : String
  ca_bundle : String
  /// a session's own Fast, its speed ("ultrafast", "fast", "standard"), a profile as the config says it now
  fast : ((String) -> Bool?)?
  speed : ((String) -> String?)?
  current_profile : ((String) -> JValue?)?
  /// another station's subscription, borrowed: whether a profile is, and its home's auth.json written (when it ends)
  lent_borrowed : ((JValue) -> Bool)?
  lent_write : ((JValue) -> Later[Double])?
  /// the version of Codex `codex` on the PATH is now
  installed_version : () -> Later[String?]
  /// a code-mode host missing (`findMissingCodexHost`), and what is told of it
  missing_host : (String, Env) -> Later[Bool]
  incomplete_installation : () -> Unit
  /// the machine's Codex home linked in (`linkCodexAuthSoon`)
  link_auth : (String) -> Later[Unit]
  /// the rollout path Codex said of a thread told the readers: its id, the directories it is under, its place there
  /// (read/transcript.ts `rememberCodexRolloutLooking`'s `saidRollouts`)
  remember_rollout : (String, Array[String], String) -> Unit
  /// where the agent's and the station's `codex` are (`updateMatchesStation`)
  update_matches : (JValue) -> Later[Bool]
  /// settled once what the station before left is taken up
  taken_up : Later[Unit]?
  /// another stretch of an app-server's output read again
  taking : () -> Unit
  output_limit : Int
  take_up_bytes : Int
  warm_ms : Double
}

///|
pub type Sink = (Notice) -> Unit

///|
/// One app-server process and its JSON-RPC connection (`Host`).
pub struct Host {
  lp : Loop
  m : Machine
  mut proc : Proc?
  pending : Array[(Double, String, (JValue) -> Unit, (Error) -> Unit)]
  threads : Array[(String, Sink)]
  turns : Array[String]
  mut login_stale : Bool
  mut runtime_stale : Bool
  mut draining : Bool
  /// the station's tools at this address failed for a thread of its, opened with them (`toolsFailedUrl`)
  mut tools_failed_url : String?
  mut version : String?
  mut ready : Bool
  mut readying : Later[Unit]?
  lives : Array[(String, JValue)]
  routers : Array[(String, (Int) -> Bool)]
  mut recovered : Array[(String, Recovered)]
  mut used_at : Double
  mut opening : Int
  mut idle_watched : Bool
  turn_from : Array[(String, Int)]
  mut stop_orphans : () -> Unit
  mut kept_from : Int
  mut read_to : Int
  mut handed_from : Int
  profile : String
  key : String
  signature : String
  mut next_id : Double
  mut lent_until : Double?
}

///|
pub fn Host::new(
  m : Machine,
  profile : String,
  signature : String,
  next_id : Double,
  ready : Bool,
  key : String,
) -> Host {
  {
    lp: m.lp,
    m,
    proc: None,
    pending: [],
    threads: [],
    turns: [],
    login_stale: false,
    runtime_stale: false,
    draining: false,
    tools_failed_url: None,
    version: None,
    ready,
    readying: None,
    lives: [],
    routers: [],
    recovered: [],
    used_at: 0.0,
    opening: 0,
    idle_watched: false,
    turn_from: [],
    stop_orphans: () => (),
    kept_from: -1,
    read_to: 0,
    handed_from: 0,
    profile,
    key,
    signature,
    next_id,
    lent_until: None,
  }
}

///|
pub fn Host::p(self : Host) -> Proc {
  self.proc.unwrap()
}

///|
pub fn Host::has_thread(self : Host, t : String) -> Bool {
  self.threads.iter().any(x => x.0 == t)
}

///|
pub fn Host::sink_of(self : Host, t : String) -> Sink? {
  match self.threads.search_by(x => x.0 == t) {
    Some(i) => Some(self.threads[i].1)
    None => None
  }
}

///|
pub fn Host::turning(self : Host, t : String) -> Bool {
  self.turns.contains(t)
}

///|
pub fn Host::turn_add(self : Host, t : String) -> Unit {
  if !self.turns.contains(t) {
    self.turns.push(t)
  }
}

///|
pub fn Host::turn_delete(self : Host, t : String) -> Unit {
  match self.turns.search(t) {
    Some(i) => self.turns.remove(i) |> ignore
    None => ()
  }
}

///|
/// Its output read by the program: lines for here, each thread's notifications as its events (`hostedOptions`).
pub fn Host::hosted_options(self : Host, label : String, orphans? : Bool = false) -> HostedOptions {
  {
    label,
    kind: "codex",
    flavor: None,
    kept: false,
    orphans,
    heard: h => Took(self.heard(h)),
    attached: () => self.attached(),
    exit: (said, stderr) => {
      self.on_exit(said, stderr)
      done(self.lp)
    },
  }
}

///|
/// What the program read up to `to` (`heard`): true where a batch of it was taken by an actor in the program.
pub fn Host::heard(self : Host, heard : Heard) -> Bool {
  let to = heard.to()
  if to > self.read_to {
    self.read_to = to
  }
  if self.kept_from >= 0 && to - self.kept_from > kept_most {
    self.reckon(to)
  }
  for line in heard.lines() {
    self.on_line(line)
  }
  for mark in arr_at(Some(heard.json), "marks").unwrap_or([]) {
    guard mark is Arr(parts) && parts.length() >= 4 else { continue }
    let thread = str_of(Some(parts[0])).unwrap_or("")
    let started = num_of(Some(parts[1])) == Some(1.0)
    let from = num_of(Some(parts[2])).unwrap_or(0.0).to_int()
    let upto = num_of(Some(parts[3])).unwrap_or(0.0).to_int()
    self.note_turn(thread, started, from, upto)
  }
  let mut taken = false
  for t in arr_at(Some(heard.json), "threads").unwrap_or([]) {
    let thread = str_at(Some(t), "thread").unwrap_or("")
    guard self.sink_of(thread) is Some(sink) else { continue }
    let live = get(Some(t), "live").unwrap_or(Null)
    put_pair(self.lives, thread, live)
    let batch = num_at(Some(t), "batch")
    let router = match batch {
      Some(_) =>
        match self.routers.search_by(r => r.0 == thread) {
          Some(i) => Some(self.routers[i].1)
          None => None
        }
      None => None
    }
    sink(Events(arr_at(Some(t), "events").unwrap_or([]), live, router is Some(_)))
    guard router is Some(took) else { continue }
    if took(batch.unwrap().to_int()) {
      taken = true
    } else {
      self.route(thread, None)
    }
  }
  taken
}

///|
/// The program attached to its runner (again): its threads told it, and whose actors take their events there.
pub fn Host::attached(self : Host) -> Unit {
  guard self.proc is Some(p) else { return }
  for t in self.threads {
    let live = match self.lives.search_by(l => l.0 == t.0) {
      Some(i) => self.lives[i].1
      None => no_live_state()
    }
    (p.thread)(t.0, live, self.routers.iter().any(r => r.0 == t.0))
  }
  for r in self.routers {
    (p.route_thread)(r.0, true, true) |> ignore
  }
}

///|
pub fn Host::alive(self : Host) -> Bool {
  !(self.p().has_exited)() && !(self.p().handed)()
}

///|
/// A thread's sink, its live steps as they stand (`addThread`).
pub fn Host::add_thread(
  self : Host,
  thread : String,
  sink : Sink,
  live : JValue,
  router? : ((Int) -> Bool)? = None,
) -> Unit {
  put_pair(self.threads, thread, sink)
  put_pair(self.lives, thread, live)
  // (one taken up with its actor's router: its notifications taken there from the first, codex.ts `addThread`)
  match router {
    Some(r) => put_pair(self.routers, thread, r)
    None => ()
  }
  (self.p().thread)(thread, live, router is Some(_))
}

///|
/// A thread no longer a session's here (`dropThread`).
pub fn Host::drop_thread(self : Host, thread : String) -> Unit {
  guard self.threads.search_by(x => x.0 == thread) is Some(i) else { return }
  self.threads.remove(i) |> ignore
  match self.lives.search_by(x => x.0 == thread) {
    Some(k) => self.lives.remove(k) |> ignore
    None => ()
  }
  self.route(thread, None)
  (self.p().drop_thread)(thread)
}

///|
pub fn Host::drop_all(self : Host) -> Unit {
  for t in self.threads.map(x => x.0) {
    self.drop_thread(t)
  }
}

///|
/// Whether a thread's events are given its session's actor in the program (`route`).
pub fn Host::route(self : Host, thread : String, router : ((Int) -> Bool)?) -> Unit {
  let router = if router is Some(_) && !self.has_thread(thread) { None } else { router }
  let was = self.routers.iter().any(r => r.0 == thread)
  let now = (self.p().route_thread)(thread, router is Some(_), was)
  match (now, router) {
    (true, Some(r)) => put_pair(self.routers, thread, r)
    _ =>
      match self.routers.search_by(r => r.0 == thread) {
        Some(i) => self.routers.remove(i) |> ignore
        None => ()
      }
  }
}

///|
/// A turn running on it that began at or after `from` in its output (`running`).
pub fn Host::running(self : Host, thread : String, from : Int) -> Unit {
  if !self.turn_from.iter().any(t => t.0 == thread) {
    self.turn_from.push((thread, from))
  }
}

///|
pub fn Host::turn_from_delete(self : Host, thread : String) -> Bool {
  match self.turn_from.search_by(t => t.0 == thread) {
    Some(i) => {
      self.turn_from.remove(i) |> ignore
      true
    }
    None => false
  }
}

///|
pub fn Host::note_turn(self : Host, thread : String, started : Bool, from : Int, to : Int) -> Unit {
  if started {
    self.running(thread, from)
  } else {
    self.turn_from_delete(thread) |> ignore
  }
  self.reckon(to)
}

///|
/// A thread whose turn will not be read to its end here (`forget`).
pub fn Host::forget(self : Host, thread : String) -> Unit {
  if self.turn_from_delete(thread) && self.alive() {
    self.reckon(self.read_to)
  }
}

///|
/// Where what is kept for reading again after a crash begins, told the runner (`reckon`).
pub fn Host::reckon(self : Host, to : Int) -> Unit {
  let mut at = to
  if self.turn_from.length() > 0 {
    at = self.turn_from[0].1
    for t in self.turn_from {
      if t.1 < at {
        at = t.1
      }
    }
  }
  let end = if to > self.read_to { to } else { self.read_to }
  if end - at > kept_most {
    let was = at
    at = end - kept_after
    for i, t in self.turn_from {
      if t.1 < at {
        self.turn_from[i] = (t.0, at)
      }
    }
    self.m.log(
      "warn",
      "agents::codex",
      "a turn's output held past its bound: let go of up to near its end",
      obj([("profile", s(self.profile)), ("from", n(was)), ("at", n(at)), ("end", n(end))]),
    )
  }
  if at == self.kept_from {
    return
  }
  self.kept_from = at
  (self.p().keep_from)(at)
}

///|
/// A line of its output the program gives here (`onLine`): an answer, a request of its own, a turn's error.
pub fn Host::on_line(self : Host, line : String) -> Unit {
  guard parse_json(line) is Some(msg) else {
    if is_debug() {
      self.m.log("info", "agents::codex", "codex non-json line", obj([("line", s(chars_js(line, 500)))]))
    }
    return
  }
  let meth = str_at(Some(msg), "method")
  let id = get(Some(msg), "id")
  match (id, meth) {
    (Some(Num(x)), None) if x == x.floor() => {
      let key = x
      guard self.pending.search_by(p => p.0 == key) is Some(i) else {
        self.m.log(
          "info",
          "agents::codex",
          "a reply to a request of an earlier station, dropped",
          obj([("profile", s(self.profile)), ("id", Num(x))]),
        )
        return
      }
      let (_, _, resolve, reject) = self.pending.remove(i)
      match get(Some(msg), "error") {
        Some(Null) | None => resolve(get(Some(msg), "result").unwrap_or(Null))
        Some(e) => reject(Failed("codex \{json_text(e)}"))
      }
    }
    (Some(i), Some(m)) if !(i is Null) => {
      self.m.log("warn", "agents::codex", "codex asked the client something; refusing", obj([("method", s(m))]))
      (self.p().write)(
        json_text(
          obj([
            ("id", i),
            (
              "error",
              obj([
                ("code", n(-32601)),
                ("message", s("the station does not answer client requests")),
              ]),
            ),
          ]),
        ),
      )
    }
    (_, Some("error")) if !is_true(get(Some(msg), "params"), "willRetry") => {
      let thread = str_at(get(Some(msg), "params"), "threadId")
      match thread {
        Some(t) if self.has_thread(t) =>
          self.m.log(
            "warn",
            "agents::codex",
            "codex turn error",
            obj([
              ("thread", s(t)),
              ("error", s(json_text(get(get(Some(msg), "params"), "error").unwrap_or(Null)))),
            ]),
          )
        _ => ()
      }
    }
    _ => ()
  }
}

///|
/// Lines Rust logged at debug, only with STILLFAIL_AGENTS_DEBUG set: never in this program.
pub fn is_debug() -> Bool {
  false
}

///|
/// `text.slice(0, n)`, by code units.
pub fn chars_js(text : String, count : Int) -> String {
  if text.length() <= count {
    text
  } else {
    text.substring(end=count)
  }
}

///|
pub fn Host::on_exit(self : Host, said : String, stderr : String) -> Unit {
  (self.stop_orphans)()
  let reason = "codex app-server exited (\{said})\{if stderr == "" { "" } else { ": \{stderr}" }}"
  let pending = self.pending.copy()
  self.pending.clear()
  for p in pending {
    (p.3)(Failed(reason))
  }
  let sinks = self.threads.map(t => t.1)
  self.drop_all()
  self.turns.clear()
  self.turn_from.clear()
  for sink in sinks {
    sink(HostExited(reason))
  }
}

///|
/// `initialize` once, then `initialized` (`ensureReady`).
pub fn Host::ensure_ready(self : Host) -> Later[Unit] {
  match self.readying {
    Some(r) => return r.bind(_ => self.ensure_ready())
    None => ()
  }
  if self.ready {
    return done(self.lp)
  }
  let readying = self
    .request(
      "initialize",
      obj([
        ("clientInfo", obj([("name", s("stillfail")), ("version", s("0"))])),
        ("capabilities", obj([("experimentalApi", b(true))])),
      ]),
    )
    .map(answer => {
      self.version = user_agent_version(get(Some(answer), "userAgent"))
      (self.p().write)(json_text(obj([("method", s("initialized")), ("params", obj([]))])))
      self.ready = true
    })
  self.readying = Some(readying)
  readying.always(() => self.readying = None)
}

///|
pub fn Host::request(self : Host, meth : String, params : JValue) -> Later[JValue] {
  if (self.p().handed)() {
    return Later::fail(self.lp, Failed("codex app-server was handed over"))
  }
  if !self.alive() {
    return Later::fail(self.lp, Failed("codex app-server is not running"))
  }
  let id = self.next_id
  self.next_id += 1.0
  let out = Later::new(self.lp)
  self.pending.push((id, meth, v => out.resolve(v), e => out.reject(e)))
  (self.p().write)(json_text(obj([("id", d(id)), ("method", s(meth)), ("params", params)])))
  out
}

///|
/// Stops hearing it (`freeze`): replies owed go to the next station.
pub fn Host::freeze(self : Host) -> Unit {
  if (self.p().handed)() {
    return
  }
  (self.p().freeze)()
  let pending = self.pending.copy()
  self.pending.clear()
  for p in pending {
    (p.3)(Failed("codex app-server was handed over"))
  }
}

///|
pub fn Host::detach(self : Host) -> Unit {
  (self.stop_orphans)()
  self.freeze()
  self.threads.clear()
  self.lives.clear()
  self.routers.clear()
  (self.p().detach)()
}

///|
pub fn Host::snapshot(self : Host) -> JValue {
  let fields = [
    ("runner", s(self.p().info.id())),
    ("signature", s(self.signature)),
    ("nextId", d(self.next_id)),
    ("ready", b(self.ready)),
  ]
  if self.kept_from >= 0 {
    fields.push(("keep", n(self.kept_from)))
  }
  if self.draining {
    fields.push(("draining", b(true)))
  }
  if self.key != self.profile {
    fields.push(("key", s(self.key)))
  }
  if self.login_stale {
    fields.push(("loginStale", b(true)))
  }
  if self.runtime_stale {
    fields.push(("runtimeStale", b(true)))
  }
  obj(fields)
}

///|
/// The Codex driver (`CodexDriver`).
pub struct CodexDriver {
  m : Machine
  data : String
  procs : Procs
  command : String
  world : CodexWorld
  profiles : ProfileSays
  words : Words
  hosts : Array[(String, Host)]
  /// the routers of sessions being taken up, by their keys (hub.ts `takeUp`'s `router`): their threads' events taken
  /// by their actors in the program from the first
  adopt_routers : Map[String, (Int, Proc) -> Bool]
  draining : Array[Host]
  mut host_queue : Later[Unit]
  mut stopped : Bool
  claimed : Array[String]
  mut installed : (String?, Double)?
  mut installed_reading : Later[String?]?
}

///|
pub fn CodexDriver::new(
  m : Machine,
  data : String,
  procs : Procs,
  command? : String = "codex",
  world : CodexWorld,
  profiles : ProfileSays,
  words : Words,
) -> CodexDriver {
  {
    m,
    data,
    procs,
    command,
    world,
    profiles,
    words,
    hosts: [],
    adopt_routers: Map([]),
    draining: [],
    host_queue: done(m.lp),
    stopped: false,
    claimed: [],
    installed: None,
    installed_reading: None,
  }
}

///|
pub fn CodexDriver::lp(self : CodexDriver) -> Loop {
  self.m.lp
}

///|
pub fn CodexDriver::host_at(self : CodexDriver, key : String) -> Host? {
  match self.hosts.search_by(h => h.0 == key) {
    Some(i) => Some(self.hosts[i].1)
    None => None
  }
}

///|
pub fn CodexDriver::host_delete(self : CodexDriver, key : String) -> Unit {
  match self.hosts.search_by(h => h.0 == key) {
    Some(i) => self.hosts.remove(i) |> ignore
    None => ()
  }
}

///|
pub fn CodexDriver::host_set(self : CodexDriver, key : String, host : Host) -> Unit {
  put_pair(self.hosts, key, host)
}

///|
pub fn CodexDriver::is_current(self : CodexDriver, host : Host) -> Bool {
  match self.host_at(host.key) {
    Some(h) => physical_equal(h, host)
    None => false
  }
}

///|
pub fn CodexDriver::draining_add(self : CodexDriver, host : Host) -> Unit {
  if !self.draining.iter().any(h => physical_equal(h, host)) {
    self.draining.push(host)
  }
}

///|
pub fn CodexDriver::draining_delete(self : CodexDriver, host : Host) -> Unit {
  match self.draining.search_by(h => physical_equal(h, host)) {
    Some(i) => self.draining.remove(i) |> ignore
    None => ()
  }
}

///|
pub fn CodexDriver::warn(self : CodexDriver, what : String, fields : JValue) -> Unit {
  self.m.log("warn", "agents::codex", what, fields)
}

///|
pub fn CodexDriver::info(self : CodexDriver, what : String, fields : JValue) -> Unit {
  self.m.log("info", "agents::codex", what, fields)
}

///|
/// A profile's environment as its app-server is started with (`keepLocal({...cleanEnv(SCRUBBED), ...expandRoute(...)})`).
pub fn CodexDriver::child_env(self : CodexDriver, profile : JValue) -> Env {
  let env = start_env(self.world.raw_env, codex_scrubbed)
  env.merge(expand_route((self.profiles.env)(profile, "codex"), profile_id(profile)))
  // The profile's own proxy too leaves this machine out (`keepLocal`).
  keep_local(env)
}

///|
/// What an app-server was started with (`hostSignature`).
pub fn CodexDriver::host_signature(self : CodexDriver, profile : JValue) -> String {
  json_text(
    arr([
      s(profile_home(profile)),
      map_json(sorted_pairs((self.profiles.env)(profile, "codex"))),
      map_json(sorted_pairs((self.world.agent_env)())),
      map_json(sorted_pairs((self.profiles.codex_overrides)(profile))),
    ]),
  )
}

///|
/// An app-server's arguments (`hostArgs`).
pub fn CodexDriver::host_args(self : CodexDriver, profile : JValue) -> Array[String] {
  let args = ["app-server"]
  for o in (self.profiles.codex_overrides)(profile) {
    args.append(["-c", "\{o.0}=\{o.1}"])
  }
  args.append(["--listen", "stdio://"])
  args
}

///|
/// Points Codex at a CA file where none of its own is set and the file is there (`withCaBundle`).
pub fn with_ca_bundle(m : Machine, env : Env, bundle : String) -> Later[Unit] {
  if ["SSL_CERT_FILE", "SSL_CERT_DIR", "CODEX_CA_CERTIFICATE"].iter().any(k => env.has(k)) {
    return done(m.lp)
  }
  m.there(bundle).map(yes => if yes { env.set("SSL_CERT_FILE", bundle) })
}

///|
pub fn CodexDriver::borrowed(self : CodexDriver, profile : JValue) -> Bool {
  match self.world.lent_borrowed {
    Some(f) => f(profile)
    None => false
  }
}

///|
/// One app-server started (`Host.start`).
pub fn CodexDriver::start_host(
  self : CodexDriver,
  profile : JValue,
  key : String,
  cwd : String,
  id : String,
) -> Later[Host] {
  let lp = self.lp()
  let home = profile_home(profile)
  self.m
  .make_dir(home)
  .bind(_ => if is_machine(profile) { (self.world.link_auth)(home) } else { done(lp) })
  .bind(_ => if self.borrowed(profile) {
    (self.world.lent_write.unwrap())(profile).map(x => Some(x))
  } else {
    Later::ok(lp, None)
  })
  .bind(until => {
    let env = self.child_env(profile)
    env.set("CODEX_HOME", home)
    with_ca_bundle(self.m, env, self.world.ca_bundle).bind(_ => {
      let host = Host::new(self.m, profile_id(profile), self.host_signature(profile), 1.0, false, key)
      host.lent_until = until
      (self.procs.start)(
        id,
        self.command,
        self.host_args(profile),
        env,
        cwd,
        host.hosted_options("codex app-server \{key}"),
        Null,
      ).map(p => {
        host.proc = Some(p)
        host
      })
    })
  })
}

///|
/// Takes up an app-server a runner keeps (`Host.adopt`).
pub fn CodexDriver::adopt_host(
  self : CodexDriver,
  profile : String,
  info : RunnerInfo,
  signature : String,
  next_id : Double,
  ready : Bool,
  recovered : Array[(String, Recovered)]?,
  key : String,
  from : Int?,
) -> Host {
  self.info(
    "taking up a codex app-server",
    obj([
      ("profile", s(profile)),
      ("key", s(key)),
      ("pgid", n(info.pgid())),
      ("crashed", b(recovered is Some(_))),
    ]),
  )
  let host = Host::new(self.m, profile, signature, next_id, ready, key)
  match recovered {
    Some(r) => host.recovered = r
    None => ()
  }
  match from {
    Some(f) => {
      host.handed_from = f
      host.turn_from.push((before_key, f))
    }
    None => ()
  }
  host.proc = Some(
    (self.procs.adopt)(info, host.hosted_options("codex app-server \{profile}", orphans=true), Null, Null),
  )
  host.stop_orphans = self.m.lp.after(orphans_ms, () => {
    if (host.p().has_exited)() {
      return
    }
    if host.turn_from_delete(before_key) {
      host.reckon(from.unwrap_or(0))
    }
    if !(host.p().handed)() {
      (host.p().orphans_off)()
    }
  })
  match from {
    Some(f) => host.reckon(f)
    None => ()
  }
  host
}

///|
/// The version of Codex installed now, read again when the last reading is old or `fresh` asks.
pub fn CodexDriver::installed_version(self : CodexDriver, fresh? : Bool = false) -> Later[String?] {
  match self.installed {
    Some((v, at)) if !fresh && self.m.now() - at < installed_ms => return Later::ok(self.lp(), v)
    _ => ()
  }
  match self.installed_reading {
    Some(r) => return r
    None => ()
  }
  let reading = (self.world.installed_version)()
    .recover(_ => Later::ok(self.lp(), None))
    .map(version => {
      self.installed = Some((version, self.m.now()))
      version
    })
    .always(() => self.installed_reading = None)
  self.installed_reading = Some(reading)
  reading
}

///|
/// An app-server running a Codex other than the one installed now (`stale`).
pub fn CodexDriver::stale(self : CodexDriver, host : Host) -> Bool {
  let installed = match self.installed {
    Some((v, _)) => v
    None => None
  }
  host.runtime_stale ||
  (match (host.version, installed) {
    (Some(a), Some(b)) => a != b
    _ => false
  })
}

///|
/// An app-server whose output has grown past the limit, or a runner from before `keeps` (`outgrown`): its size.
pub fn CodexDriver::outgrown(self : CodexDriver, host : Host) -> Later[Int?] {
  self.m
  .size(out_file(self.m, self.data, host.p().info.id()))
  .map(size => match size {
    Some(sz) =>
      if sz > self.world.output_limit || !host.p().info.keeps() {
        Some(sz)
      } else {
        None
      }
    None => None
  })
  .recover(_ => Later::ok(self.lp(), None))
}

///|
/// Replaces a profile's app-server once no turn runs on it, where it is to be (`retireStale`).
pub fn CodexDriver::retire_stale(self : CodexDriver, key : String, installed : String?) -> Later[Unit] {
  let lp = self.lp()
  guard self.host_at(key) is Some(host) else { return done(lp) }
  if !host.alive() || host.turns.length() > 0 {
    return done(lp)
  }
  let go = () => {
    host.draining = true
    self.host_delete(key)
    (host.p().kill)(5000.0)
  }
  if host.login_stale {
    self.info(
      "login changed; restarting its codex app-server",
      obj([("profile", s(host.profile)), ("key", s(key))]),
    )
    go()
  } else if self.stale(host) {
    self.info(
      "codex was updated under its app-server; restarting it",
      obj([
        ("profile", s(host.profile)),
        ("key", s(key)),
        ("running", opt_s(host.version)),
        ("installed", opt_s(installed)),
      ]),
    )
    go()
  } else {
    self
    .outgrown(host)
    .bind(output => match output {
      None => done(lp)
      Some(bytes) => {
        self.info(
          "its app-server's output has grown long, or its runner is from before; restarting it",
          obj([
            ("profile", s(host.profile)),
            ("key", s(key)),
            ("bytes", n(bytes)),
            ("keeps", b(host.p().info.keeps())),
          ]),
        )
        go()
      }
    })
  }
}

///|
/// One at a time: starting, replacing and taking up hosts (`serial`).
pub fn[T] CodexDriver::serial(self : CodexDriver, work : () -> Later[T]) -> Later[T] {
  let out : Later[T] = Later::new(self.lp())
  let step = () => {
    let ran = if self.stopped {
      Later::fail(
        self.lp(),
        Failed("codex app-server not started: the station's agents were let go"),
      )
    } else {
      work()
    }
    ran.on(r => {
      self.claimed.clear()
      match r {
        Ok(v) => out.resolve(v)
        Err(e) => out.reject(e)
      }
    })
  }
  self.host_queue.on(_ => step())
  self.host_queue = out.map(_ => ()).recover(_ => done(self.lp()))
  out
}

///|
/// Codex installed or updated: app-servers of the old one replaced once idle (`runtimeChanged`).
pub fn CodexDriver::runtime_changed(
  self : CodexDriver,
  replaced? : Bool = false,
  drain_busy? : Bool = false,
) -> Later[Unit] {
  let lp = self.lp()
  let first = if replaced {
    self.serial(() => {
      for h in self.hosts {
        h.1.runtime_stale = true
      }
      done(lp)
    })
  } else {
    done(lp)
  }
  first
  .bind(_ => self.installed_version(fresh=true))
  .bind(installed => {
    let draining : Array[Host] = []
    self
    .serial(() => {
      match installed {
        Some(v) =>
          for h in self.hosts {
            match h.1.version {
              Some(hv) if hv != v => h.1.runtime_stale = true
              _ => ()
            }
          }
        None => ()
      }
      let hosts = self.hosts.copy()
      each_in_turn(lp, hosts.length(), i => {
        let (id, host) = hosts[i]
        if drain_busy && host.runtime_stale && host.turns.length() > 0 {
          host.draining = true
          self.host_delete(id)
          self.draining_add(host)
          draining.push(host)
          done(lp)
        } else {
          self.retire_stale(id, installed)
        }
      })
    })
    .map(_ => for host in draining {
      self.drain(host).on(r => if r is Err(e) {
        self.warn(
          "a codex app-server being replaced not let go of",
          obj([("profile", s(host.profile)), ("error", s(words_of(e)))]),
        )
      })
    })
  })
}

///|
/// A new sign-in loaded by every app-server of this profile (`loginChanged`).
pub fn CodexDriver::login_changed(self : CodexDriver, profile_id : String) -> Later[Unit] {
  self.serial(() => {
    let hosts = self.hosts.copy()
    each_in_turn(self.lp(), hosts.length(), i => {
      let (key, host) = hosts[i]
      if host.profile != profile_id {
        return done(self.lp())
      }
      host.login_stale = true
      self.retire_stale(key, match self.installed {
        Some((v, _)) => v
        None => None
      })
    })
  })
}

///|
pub fn CodexDriver::drain_soon(self : CodexDriver, host : Host, what : String) -> Unit {
  self
  .drain(host)
  .on(r => if r is Err(e) {
    self.warn(what, obj([("profile", s(host.profile)), ("error", s(words_of(e)))]))
  })
}

///|
/// A turn ended on a host: replaced now where it is to be (`hostIdle`).
pub fn CodexDriver::host_idle(self : CodexDriver, host : Host) -> Unit {
  let lp = self.lp()
  if host.draining {
    self.drain_soon(host, "a codex app-server being replaced not let go of")
    return
  }
  if !self.is_current(host) {
    return
  }
  if host.turns.length() > 0 {
    self
    .outgrown(host)
    .bind(size => {
      if size is None {
        return done(lp)
      }
      self
      .serial(() => {
        if !self.is_current(host) || host.turns.length() == 0 {
          return done(lp)
        }
        self.info(
          "its app-server's output has grown long, or its runner is from before; new turns go to a new one, its own end there",
          obj([
            ("profile", s(host.profile)),
            ("key", s(host.key)),
            ("turns", n(host.turns.length())),
            ("keeps", b(host.p().info.keeps())),
          ]),
        )
        host.draining = true
        self.host_delete(host.key)
        self.draining_add(host)
        done(lp)
      })
      .bind(_ => if host.draining { self.drain(host) } else { done(lp) })
    })
    .on(r => if r is Err(e) {
      self.warn(
        "a codex app-server not replaced",
        obj([("profile", s(host.profile)), ("error", s(words_of(e)))]),
      )
    })
    return
  }
  self.idle_later(host)
  self
  .installed_version()
  .bind(installed => {
    let decide = if host.login_stale || self.stale(host) {
      Later::ok(lp, true)
    } else {
      self.outgrown(host).map(x => x is Some(_))
    }
    decide.bind(go => if go {
      self.serial(() => self.retire_stale(host.key, installed))
    } else {
      done(lp)
    })
  })
  .on(r => if r is Err(e) {
    self.warn(
      "a codex app-server not replaced",
      obj([("profile", s(host.profile)), ("error", s(words_of(e)))]),
    )
  })
}

///|
/// An app-server being replaced lets go of its threads with no turn running, and ends once none is left (`drain`).
pub fn CodexDriver::drain(self : CodexDriver, host : Host) -> Later[Unit] {
  let lp = self.lp()
  let releases = []
  for t in host.threads.copy() {
    let (thread, sink) = t
    if host.turning(thread) {
      continue
    }
    host.drop_thread(thread)
    host.forget(thread)
    sink(HostExited("its app-server is being replaced"))
    releases.push(
      host
      .request("thread/unsubscribe", obj([("threadId", s(thread))]))
      .map(_ => ())
      .recover(_ => done(lp)),
    )
  }
  all(lp, releases).bind(_ => {
    if host.threads.length() > 0 || host.turns.length() > 0 {
      return done(lp)
    }
    self.serial(() => {
      let killed = if host.alive() { (host.p().kill)(5000.0) } else { done(lp) }
      killed.map(_ => self.draining_delete(host))
    })
  })
}

///|
/// A thread about to be resumed on another app-server of its key: each one being replaced lets go of it first
/// (`releasedElsewhere`).
pub fn CodexDriver::released_elsewhere(
  self : CodexDriver,
  profile : JValue,
  key : String,
  thread_id : String,
  on : Host,
) -> Later[Unit] {
  let lp = self.lp()
  self
  .serial(() => self
    .left_runners(key)
    .map(left => for info in left {
      if info.id() != on.p().info.id() {
        self.keep_draining(self.hold_left(profile, info, key))
      }
    }))
  .bind(_ => {
    let others = self.draining.filter(h => !physical_equal(h, on) && h.key == key)
    each_in_turn(lp, others.length(), i => {
      let host = others[i]
      if !host.alive() {
        return done(lp)
      }
      host
      .request("thread/unsubscribe", obj([("threadId", s(thread_id))]))
      .map(_ => ())
      .recover(e => if !host.alive() {
        done(lp)
      } else {
        Later::fail(
          lp,
          Failed("the codex app-server being replaced did not let go of its thread: \{words_of(e)}"),
        )
      })
    })
  })
}

///|
/// One taken up as being replaced: what of it no session took up a while after let go of, and it ends (`keepDraining`).
pub fn CodexDriver::keep_draining(self : CodexDriver, host : Host) -> Unit {
  host.draining = true
  self.draining_add(host)
  self.m.lp.after(orphans_ms, () => {
    for thread in host.turns.copy() {
      if !host.has_thread(thread) {
        host.turn_delete(thread)
      }
    }
    for t in host.turn_from.copy() {
      if !host.has_thread(t.0) {
        host.forget(t.0)
      }
    }
    self.drain_soon(host, "a codex app-server being replaced not let go of")
  })
  |> ignore
}

///|
/// The runners of a host key an earlier station left, the oldest first (`leftRunners`).
pub fn CodexDriver::left_runners(self : CodexDriver, key : String) -> Later[Array[RunnerInfo]] {
  let base = runner_id("codex", key)
  live_runners(self.m, self.data, strict=true).bind(found => {
    let runners = found.filter(r => r.id() == base || r.id().has_prefix("\{base}."))
    all(self.lp(), runners.map(r => listening_soon(self.m, r))).map(heard => {
      let held = self.hosts.map(h => h.1.p().info.id()) +
        self.draining.map(h => h.p().info.id())
      let left = []
      for i, r in runners {
        if heard[i] && !held.contains(r.id()) {
          left.push(r)
        }
      }
      left.sort_by((a, c) => a.started_at().unwrap_or(0.0).compare(c.started_at().unwrap_or(0.0)))
      for r in left {
        self.claimed.push(r.id())
      }
      left
    })
  })
}

///|
/// What an earlier station left of a host key taken up: the newest as its app-server, any older being replaced
/// (`takeUpLeft`).
pub fn CodexDriver::take_up_left(self : CodexDriver, profile : JValue, key : String) -> Later[Host?] {
  self
  .left_runners(key)
  .bind(left => {
    guard left.pop() is Some(newest) else { return Later::ok(self.lp(), None) }
    each_in_turn(self.lp(), left.length(), i => self
      .take_up(profile, left[i], key)
      .map(h => self.keep_draining(h)))
    .bind(_ => self.take_up(profile, newest, key).map(h => Some(h)))
  })
}

///|
/// Handed over: one being replaced that no session handed over is on taken up as such, and it ends (`sweepLeft`).
pub fn CodexDriver::sweep_left(self : CodexDriver, profile : JValue, key : String) -> Unit {
  self.m.lp.after(orphans_ms, () => self
    .serial(() => self
      .left_runners(key)
      .map(left => for info in left {
        self.keep_draining(self.hold_left(profile, info, key))
      }))
    .on(r => if r is Err(e) {
      self.warn(
        "a codex app-server left being replaced not taken up",
        obj([("key", s(key)), ("error", s(words_of(e)))]),
      )
    }))
  |> ignore
}

///|
/// The version an app-server a runner keeps runs: the first line of its output (`versionInOutput`), once read.
pub fn CodexDriver::read_version(self : CodexDriver, host : Host, file : String) -> Unit {
  self.m
  .read_at(file, 0, 4096)
  .map(buf => {
    let text = utf8_text(buf)
    let first = match text.find("\n") {
      Some(i) => text.substring(end=i)
      None => text
    }
    match parse_json(first) {
      Some(j) => user_agent_version(get(get(Some(j), "result"), "userAgent"))
      None => None
    }
  })
  .recover(_ => Later::ok(self.lp(), None))
  .on(r => match r {
    Ok(version) => if host.version is None { host.version = version }
    Err(_) => ()
  })
}

///|
/// One left being replaced with no session handed over on it: held, its output not read again (`holdLeft`).
pub fn CodexDriver::hold_left(self : CodexDriver, profile : JValue, info : RunnerInfo, key : String) -> Host {
  let same = json_text(strs(info.args())) == json_text(strs(self.host_args(profile)))
  let host = self.adopt_host(
    profile_id(profile),
    info,
    if same {
      self.host_signature(profile)
    } else {
      "unknown"
    },
    self.m.now(),
    true,
    None,
    key,
    None,
  )
  self.read_version(host, out_file(self.m, self.data, info.id()))
  host
}

///|
/// The runner id a new app-server of a key starts under (`runnerFor`).
pub fn CodexDriver::runner_for(self : CodexDriver, key : String) -> Later[String] {
  let base = runner_id("codex", key)
  find_runner(self.m, self.data, base).map(found => {
    let id = if found is Some(_) {
      "\{base}.\{to_base36(self.m.now().to_int64())}"
    } else {
      base
    }
    self.claimed.push(id)
    id
  })
}

///|
/// `n.toString(36)`.
pub fn to_base36(v : Int64) -> String {
  if v == 0L {
    return "0"
  }
  let digits = "0123456789abcdefghijklmnopqrstuvwxyz"
  let out = []
  let mut x = if v < 0L { -v } else { v }
  while x > 0L {
    out.push(digits.unsafe_charcode_at((x % 36L).to_int()))
    x = x / 36L
  }
  let sb = StringBuilder()
  if v < 0L {
    sb.write_char('-')
  }
  for i = out.length() - 1; i >= 0; i = i - 1 {
    sb.write_char(out[i].unsafe_to_char())
  }
  sb.to_string()
}

///|
/// Ends an app-server of one session's whose last thread was let go (`retire`).
pub fn CodexDriver::retire(self : CodexDriver, host : Host) -> Later[Unit] {
  self.serial(() => {
    if self.is_current(host) {
      self.host_delete(host.key)
    }
    host.draining = true
    (host.p().kill)(5000.0)
  })
}

///|
/// The runners of the app-servers it holds now (`ownedRunners`).
pub fn CodexDriver::owned_runners(self : CodexDriver) -> Array[String] {
  let out = self.claimed.copy()
  for h in self.hosts.map(x => x.1) + self.draining {
    let id = h.p().info.id()
    if !out.contains(id) {
      out.push(id)
    }
  }
  out
}

///|
/// Nothing is had of it: no turn on it, no request out to it, no session opening on it (`idle`).
pub fn CodexDriver::idle(self : CodexDriver, host : Host) -> Bool {
  ignore(self)
  host.alive() &&
  !host.draining &&
  host.turns.length() == 0 &&
  host.pending.length() == 0 &&
  host.opening == 0
}

///|
/// Its end looked at once it has been idle `warm_ms` (`idleLater`).
pub fn CodexDriver::idle_later(self : CodexDriver, host : Host) -> Unit {
  host.used_at = self.m.now()
  if host.idle_watched || !self.is_current(host) || !self.idle(host) {
    return
  }
  let warm = self.world.warm_ms
  fn look() -> Unit {
    host.idle_watched = false
    if !self.is_current(host) || !self.idle(host) {
      return
    }
    let left = host.used_at + warm - self.m.now()
    if left > 0.0 {
      host.idle_watched = true
      self.m.lp.after(left, look) |> ignore
      return
    }
    let minutes = (warm / 60000.0).round()
    let said = if minutes == minutes.floor() {
      minutes.to_int64().to_string()
    } else {
      minutes.to_string()
    }
    self
    .end_idle(host, "its app-server was idle for \{said} minutes")
    .on(r => if r is Err(e) {
      self.warn(
        "an idle codex app-server not ended",
        obj([("profile", s(host.profile)), ("error", s(words_of(e)))]),
      )
    })
  }

  host.idle_watched = true
  self.m.lp.after(warm, look) |> ignore
}

///|
/// Ends one of `hosts` that is idle, if it still is (`endIdle`).
pub fn CodexDriver::end_idle(self : CodexDriver, host : Host, why : String) -> Later[Bool] {
  self.serial(() => {
    if !self.is_current(host) || !self.idle(host) {
      return Later::ok(self.lp(), false)
    }
    self.info(
      "ending an idle codex app-server",
      obj([
        ("profile", s(host.profile)),
        ("key", s(host.key)),
        ("threads", n(host.threads.length())),
        ("why", s(why)),
      ]),
    )
    host.draining = true
    self.host_delete(host.key)
    for t in host.threads.copy() {
      host.drop_thread(t.0)
      host.forget(t.0)
      (t.1)(HostExited(why))
    }
    (host.p().kill)(5000.0).map(_ => true)
  })
}

///|
/// The machine short of memory: idle app-servers ended (`evictIdle`).
pub fn CodexDriver::evict_idle(self : CodexDriver) -> Later[Int] {
  all(
    self.lp(),
    self.hosts.map(h => self.end_idle(h.1, "the machine is short of memory")),
  ).map(ended => ended.filter(x => x).length())
}

///|
/// `work` on a profile's app-server, which is not idle meanwhile (`lease`).
pub fn[T] CodexDriver::lease(
  self : CodexDriver,
  profile : JValue,
  work : (Host) -> Later[T],
  cwd? : String,
  mcp_url? : String,
) -> Later[T] {
  self
  .host(profile, cwd?=cwd, mcp_url?=mcp_url)
  .bind(host => work(host).always(() => self.let_go(host)))
}

///|
pub fn CodexDriver::let_go(self : CodexDriver, host : Host) -> Unit {
  host.opening -= 1
  self.idle_later(host)
}

///|
/// A profile's app-server, counted as opening on it (`host`).
pub fn CodexDriver::host(
  self : CodexDriver,
  profile : JValue,
  cwd? : String,
  mcp_url? : String,
) -> Later[Host] {
  let lp = self.lp()
  let taken_up = match self.world.taken_up {
    Some(t) => t
    None => done(lp)
  }
  taken_up
  .bind(_ => self.installed_version())
  .bind(installed => {
    let key = profile_id(profile)
    self.serial(() => self
      .retire_stale(key, installed)
      .bind(_ => {
        let mut replaced : Host? = None
        let current = self.host_at(key)
        // a thread of its could not reach the station's tools at the address this one is opened with (`host`)
        let unreachable = match (current, mcp_url) {
          (Some(c), Some(u)) => u != "" && c.tools_failed_url == Some(u)
          _ => false
        }
        match current {
          Some(c) if c.alive() &&
            (c.login_stale || c.runtime_stale || unreachable) => {
            if unreachable {
              self.warn(
                "its codex app-server could not reach the station's tools; new turns go to a new one",
                obj([
                  ("profile", s(c.profile)),
                  ("key", s(key)),
                  ("turns", n(c.turns.length())),
                  ("url", s(mcp_url.unwrap_or(""))),
                ]),
              )
            } else {
              self.info(
                "login changed or codex reinstalled; new turns go to a new app-server, its own end there",
                obj([
                  ("profile", s(c.profile)),
                  ("key", s(key)),
                  ("turns", n(c.turns.length())),
                  ("login", b(c.login_stale)),
                ]),
              )
            }
            c.draining = true
            self.host_delete(key)
            self.draining_add(c)
            replaced = Some(c)
          }
          _ => ()
        }
        let replaced = replaced
        let kept = if replaced is Some(_) { None } else { current }
        let renewing = match kept {
          Some(k) if k.alive() => self.renew_lent(k, profile)
          _ => done(lp)
        }
        renewing
        .bind(_ => match kept {
          Some(k) if k.alive() && k.signature != self.host_signature(profile) =>
            if k.turns.length() == 0 {
              self.info(
                "profile changed; restarting its codex app-server",
                obj([("profile", s(profile_id(profile)))]),
              )
              k.draining = true
              self.host_delete(key)
              (k.p().kill)(5000.0)
            } else {
              self.info(
                "profile changed; its codex app-server restarts once no turn runs on it",
                obj([("profile", s(profile_id(profile)))]),
              )
              done(lp)
            }
          _ => done(lp)
        })
        .bind(_ => {
          let alive = self.host_at(key)
          match alive {
            Some(a) if a.alive() => {
              a.opening += 1
              return Later::ok(lp, (a, replaced))
            }
            _ => ()
          }
          let released = match alive {
            Some(a) => (a.p().released)()
            None => done(lp)
          }
          released
          .bind(_ => self.take_up_left(profile, key))
          .bind(taken => {
            let left = taken is Some(_)
            let made = match taken {
              Some(h) => Later::ok(lp, h)
              None =>
                self
                .runner_for(key)
                .bind(id => self.start_host(
                  profile,
                  key,
                  if key == profile_id(profile) {
                    profile_home(profile)
                  } else {
                    cwd.unwrap_or(profile_home(profile))
                  },
                  id,
                ))
            }
            made.bind(host => {
              let expiry = if left && self.borrowed(profile) {
                lent_expiry(self.m, profile_home(profile)).map(x => host.lent_until = Some(x))
              } else {
                done(lp)
              }
              expiry.map(_ => {
                self.host_set(key, host)
                host.opening += 1
                (host, replaced)
              })
            })
          })
        })
      }))
    .bind(result => {
      let (host, replaced) = result
      match replaced {
        Some(r) => self.drain_soon(r, "a codex app-server being replaced not let go of")
        None => ()
      }
      host
      .ensure_ready()
      .recover(e => {
        self.let_go(host)
        Later::fail(lp, e)
      })
      .map(_ => host)
    })
  })
}

///|
/// When the access token in a home's auth.json runs out (0 when it does not say: `lentExpiry`).
pub fn lent_expiry(m : Machine, home : String) -> Later[Double] {
  m
  .read_file(m.join([home, "auth.json"]))
  .map(text => {
    let token = match parse_json(text) {
      Some(j) =>
        match get(get(Some(j), "tokens"), "access_token") {
          Some(Str(u)) => @jsjson.text(u)
          Some(other) => js_string_of(other)
          None => "undefined"
        }
      None => raise Failed("not JSON")
    }
    let parts = token.split(".").map(p => p.to_string()).collect()
    let payload = if parts.length() > 1 { parts[1] } else { "" }
    let claims = parse_json(utf8_text(base64url_decode(payload)))
    match num_at(claims, "exp") {
      Some(exp) => exp * 1000.0
      None => 0.0
    }
  })
  .recover(_ => Later::ok(m.lp, 0.0))
}

///|
/// `String(v)` of a JSON value that is not a string.
pub fn js_string_of(v : JValue) -> String {
  match v {
    Null => "null"
    Bool(x) => x.to_string()
    Num(_) => @jsjson.stringify(v)
    Str(u) => @jsjson.text(u)
    Arr(_) => "[array]"
    Obj(_) => "[object Object]"
  }
}

///|
/// `Buffer.from(text, "base64url")`: what is not of the alphabet passed over.
pub fn base64url_decode(text : String) -> Bytes {
  let std = StringBuilder()
  for c in text {
    std.write_char(match c {
      '-' => '+'
      '_' => '/'
      _ => c
    })
  }
  @base64.decode_lossy(std.to_string(), ignore_whitespace=true)
}

///|
/// An app-server a runner keeps, with no snapshot: what the previous station had handled of it read again to know where
/// each thread stands (`takeUp`).
pub fn CodexDriver::take_up(self : CodexDriver, profile : JValue, info : RunnerInfo, key : String) -> Later[Host] {
  let out = out_file(self.m, self.data, info.id())
  acked_offset(self.m, info, out).bind(offset => {
    let (at, keep) = offset
    let recovered : Array[(String, Recovered)] = []
    let began : Array[(String, Int)] = []
    let runs : Array[Array[JValue]] = []
    let notices : Array[JValue] = []
    let read = Ref(0)
    let told = Ref(keep.unwrap_or(0))
    bytes_within(self.m, out, keep.unwrap_or(0), at).bind(lines => {
      for line in lines {
        let (bytes, line_at) = line
        read.val += 1
        if read.val == take_up_lines || line_at - told.val >= self.world.take_up_bytes {
          read.val = 0
          told.val = line_at
          (self.world.taking)()
          runs.push(notices.copy())
          notices.clear()
        }
        if untold(bytes) {
          continue
        }
        guard parse_json(utf8_text(bytes)) is Some(msg) else { continue }
        let params = get(Some(msg), "params")
        guard str_at(Some(msg), "method") is Some(meth) &&
          str_at(params, "threadId") is Some(thread) else {
          continue
        }
        let r = match recovered.search_by(x => x.0 == thread) {
          Some(i) => recovered[i].1
          None => {
            let r = { busy: false, turn_id: None, live: no_live_state() }
            recovered.push((thread, r))
            r
          }
        }
        let item = get(params, "item")
        let notice = match item {
          None => arr([s(meth), s(thread)])
          Some(it) =>
            arr([
              s(meth),
              s(thread),
              match get(Some(it), "type") {
                Some(v) => v
                None => Null
              },
              match get(Some(it), "id") {
                Some(v) => v
                None => Null
              },
            ])
        }
        let same_run = match notices.last() {
          Some(Arr(last)) =>
            last.length() == 2 &&
            str_of(Some(last[0])) == Some(meth) &&
            str_of(Some(last[1])) == Some(thread)
          _ => false
        }
        if item is Some(_) || !same_run {
          notices.push(notice)
        }
        if meth == "turn/started" {
          r.busy = true
          if !began.iter().any(x => x.0 == thread) {
            began.push((thread, line_at))
          }
          match str_at(get(params, "turn"), "id") {
            Some(id) => r.turn_id = Some(id)
            None => ()
          }
        } else if meth == "turn/completed" {
          match began.search_by(x => x.0 == thread) {
            Some(i) => began.remove(i) |> ignore
            None => ()
          }
          r.busy = false
          r.turn_id = None
        }
      }
      runs.push(notices.copy())
      (self.procs.replay)(runs)
    })
    .map(lives => {
      for r in recovered {
        r.1.live = match get(Some(lives), r.0) {
          Some(l) => l
          None => no_live_state()
        }
      }
      let same = json_text(strs(info.args())) == json_text(strs(self.host_args(profile)))
      let host = self.adopt_host(
        profile_id(profile),
        info,
        if same {
          self.host_signature(profile)
        } else {
          "unknown"
        },
        self.m.now(),
        true,
        Some(recovered),
        key,
        None,
      )
      self.read_version(host, out)
      for r in recovered {
        if !r.1.busy {
          continue
        }
        host.turn_add(r.0)
        host.running(
          r.0,
          match began.search_by(x => x.0 == r.0) {
            Some(i) => began[i].1
            None => 0
          },
        )
      }
      host.reckon(at)
      host
    })
  })
}

///|
/// What an app-server writes most of and that says nothing of where a thread stands (`UNTOLD`).
pub fn untold(line : Bytes) -> Bool {
  for m in ["{\"method\":\"turn/diff/updated\"", "{\"method\":\"item/commandExecution/outputDelta\""] {
    let mb = @utf8.encode(m)
    if line.length() >= mb.length() {
      let mut same = true
      for i in 0..<mb.length() {
        if line[i] != mb[i] {
          same = false
          break
        }
      }
      if same {
        return true
      }
    }
  }
  false
}

///|
/// The account's rate-limit windows (`rateLimits`).
pub fn CodexDriver::rate_limits(self : CodexDriver, profile : JValue) -> Later[JValue] {
  self.lease(profile, host => host.request("account/rateLimits/read", obj([])))
}

///|
pub fn CodexDriver::reset_quota(self : CodexDriver, profile : JValue, key : String) -> Later[JValue] {
  self.lease(profile, host => host.request(
    "account/rateLimitResetCredit/consume",
    obj([("idempotencyKey", s(key))]),
  ))
}

///|
/// The models the account can run in Codex (`models`).
pub fn CodexDriver::models(self : CodexDriver, profile : JValue) -> Later[ModelCatalog] {
  self.lease(profile, host => models_of(host))
}

///|
/// Has the app-server running on a profile renew its login now (`renewLogin`).
pub fn CodexDriver::renew_login(self : CodexDriver, profile_id : String) -> Later[Bool] {
  match self.hosts.search_by(h => h.1.profile == profile_id && h.1.alive()) {
    None => Later::ok(self.lp(), false)
    Some(i) =>
      self.hosts[i].1
      .request("account/read", obj([("refreshToken", b(true))]))
      .map(_ => true)
  }
}

///|
/// `model/list`, page after page (`modelsOf`).
pub fn models_of(host : Host) -> Later[ModelCatalog] {
  let catalog = ModelCatalog::new()
  let seen : Array[String] = []
  fn page(cursor : String?) -> Later[ModelCatalog] {
    host
    .request("model/list", obj([("cursor", opt_s(cursor))]))
    .bind(answer => {
      catalog.take_page(Some(answer))
      let next = match str_at(Some(answer), "nextCursor") {
        Some(c) if c != "" => Some(c)
        _ => None
      }
      match next {
        None => {
          let models = catalog.models.copy()
          models.sort_by(js_compare)
          let unique = []
          for m in models {
            if !unique.contains(m) {
              unique.push(m)
            }
          }
          catalog.models = unique
          Later::ok(host.lp, catalog)
        }
        Some(c) => {
          if seen.contains(c) {
            raise Failed("model/list repeated its cursor")
          }
          seen.push(c)
          page(Some(c))
        }
      }
    })
  }

  page(None)
}

///|
/// Names and runtime states only (`mcpInventory`).
pub fn mcp_inventory(host : Host, thread_id? : String) -> Later[Array[(String, JValue)]] {
  let servers = []
  fn page(cursor : String?) -> Later[Array[(String, JValue)]] {
    let params = []
    match thread_id {
      Some(t) => params.push(("threadId", s(t)))
      None => ()
    }
    params.append([("cursor", opt_s(cursor)), ("detail", s("toolsAndAuthOnly"))])
    host
    .request("mcpServerStatus/list", obj(params))
    .bind(inventory => {
      guard arr_at(Some(inventory), "data") is Some(data) &&
        data.iter().all(x => str_at(Some(x), "name") is Some(_)) else {
        raise Failed("invalid MCP inventory")
      }
      for x in data {
        servers.push((str_at(Some(x), "name").unwrap(), get(Some(x), "runtimeStatus").unwrap_or(Null)))
      }
      match str_at(Some(inventory), "nextCursor") {
        Some(c) => page(Some(c))
        None => Later::ok(host.lp, servers)
      }
    })
  }

  page(None)
}

///|
/// Whether a thread's connection to the station's MCP endpoint failed, as its app-server says (`stationToolsFailed`).
pub fn station_tools_failed(host : Host, thread_id : String) -> Later[Bool] {
  host
  .request(
    "mcpServerStatus/list",
    obj([
      ("threadId", s(thread_id)),
      ("serverName", s("stillfail")),
      ("detail", s("toolsAndAuthOnly")),
    ]),
  )
  .map(answer => match arr_at(Some(answer), "data") {
    Some(data) =>
      data
      .iter()
      .any(x => str_at(Some(x), "name") == Some("stillfail") &&
        str_at(Some(x), "runtimeStatus") == Some("failed"))
    None => false
  })
  .recover(_ => Later::ok(host.lp, false))
}

///|
/// A Codex session: a thread on its profile's app-server (`CodexSession`).
pub struct CodexSession {
  driver : CodexDriver
  thread_id : String
  host : Host
  profile : JValue
  mut busy : Bool
  mut turn_id : String?
  mut closed : Bool
  mut live : JValue
  events : (JValue) -> Unit
  /// another model and effort its turns start with from now on
  mut tuned : (String, String)?
  /// what its turns run with (none: not known); a model or effort of none, the profile's or the thread's
  mut running : (String?, String?)?
  mut tools_url : String?
  mut transcript_path : String?
  mut transcript_known : Later[Unit]
  mut transcript_asked : Int
}

///|
pub fn CodexDriver::session(
  self : CodexDriver,
  thread_id : String,
  host : Host,
  profile : JValue,
  busy : Bool,
  turn_id : String?,
  live : JValue,
  events : (JValue) -> Unit,
) -> CodexSession {
  {
    driver: self,
    thread_id,
    host,
    profile,
    busy,
    turn_id,
    closed: false,
    live,
    events,
    tuned: None,
    running: None,
    tools_url: None,
    transcript_path: None,
    transcript_known: done(self.lp()),
    transcript_asked: 0,
  }
}

///|
/// Opens a session (`open`): its thread started or resumed on its profile's app-server.
pub fn CodexDriver::open(self : CodexDriver, options : JValue, events : (JValue) -> Unit) -> Later[CodexSession] {
  let lp = self.lp()
  let o = Some(options)
  let profile = get(o, "profile").unwrap_or(Null)
  let check = if is_true(o, "textOnly") {
    done(lp)
  } else {
    let env = self.child_env(profile)
    env.set("CODEX_HOME", profile_home(profile))
    (self.world.missing_host)(self.command, env).bind(missing => if missing {
      (self.world.incomplete_installation)()
      Later::fail(lp, Said("station.updates.codexMissingHostChat"))
    } else {
      done(lp)
    })
  }
  check.bind(_ => self.lease(
    profile,
    host => self.open_on(host, options, events),
    cwd=str_at(o, "cwd").unwrap_or(""),
    mcp_url=str_at(o, "mcpUrl").unwrap_or(""),
  ))
}

///|
/// A session opened on `host`, its profile's app-server (`openOn`).
pub fn CodexDriver::open_on(
  self : CodexDriver,
  host : Host,
  options : JValue,
  events : (JValue) -> Unit,
) -> Later[CodexSession] {
  let lp = self.lp()
  let o = Some(options)
  let profile = get(o, "profile").unwrap_or(Null)
  let text_only = is_true(o, "textOnly")
  let model = match str_at(o, "model") {
    Some(m) => Some(m)
    None => profile_model(profile)
  }
  let resumed = str_at(o, "resume")
  let instructions = str_at(o, "instructions").unwrap_or("")
  (self.world.walk_skills)(self.world.host_skills).bind(found => {
    let off = skills_off(found)
    let config : Ref[JValue] = Ref(
      if text_only {
        obj([
          ("features.shell_tool", b(false)),
          ("features.unified_exec", b(false)),
          ("features.multi_agent", b(false)),
          ("features.apps", b(false)),
          ("features.plugins", b(false)),
          ("features.browser_use", b(false)),
          ("features.computer_use", b(false)),
          ("features.image_generation", b(false)),
          ("features.view_image", b(false)),
          ("features.goals", b(false)),
          ("web_search", s("disabled")),
          ("mcp_servers", obj([])),
        ])
      } else {
        let command = () => arr([obj([("type", s("command")), ("command", s(self.words_repo()))])])
        obj([
          ("mcp_servers.stillfail.url", get(o, "mcpUrl").unwrap_or(Null)),
          (
            "mcp_servers.stillfail.http_headers",
            obj([("Authorization", s("Bearer \{str_at(o, "mcpToken").unwrap_or("")}"))]),
          ),
          (
            "hooks",
            obj([
              ("PostToolUse", arr([obj([("matcher", s("*")), ("hooks", command())])])),
              ("PostCompact", arr([obj([("hooks", command())])])),
            ]),
          ),
          ("bypass_hook_trust", b(true)),
        ])
      },
    )
    let inventory = if text_only {
      mcp_inventory(host)
      .map(servers => config.val = set(
          config.val,
          "mcp_servers",
          obj(servers.map(sv => (sv.0, obj([("enabled", b(false))])))),
        ))
      .recover(_ => Later::fail(lp, Failed("cannot open a text-only Codex session")))
    } else {
      done(lp)
    }
    inventory.bind(_ => {
      match str_at(o, "effort") {
        Some(e) => config.val = set(config.val, "model_reasoning_effort", s(e))
        None => ()
      }
      match get(o, "context") {
        Some(Num(_) as c) => config.val = set(config.val, "model_auto_compact_token_limit", c)
        _ => ()
      }
      if found.length() > 0 {
        config.val = set(config.val, "skills.config", off)
      }
      let common = () => {
        let fields = [
          ("cwd", get(o, "cwd").unwrap_or(Null)),
          ("approvalPolicy", s("never")),
          ("sandbox", s("danger-full-access")),
          ("developerInstructions", s(instructions)),
          ("config", config.val),
        ]
        let mut c = obj(fields)
        if text_only {
          c = set(c, "sandbox", s("read-only"))
          c = set(c, "ephemeral", b(true))
          c = set(c, "environments", arr([]))
        }
        match model {
          Some(m) => c = set(c, "model", s(m))
          None => ()
        }
        if instructions == "" {
          c = del(c, "developerInstructions")
        }
        c
      }
      let opened = match resumed {
        Some(thread) =>
          self
          .released_elsewhere(profile, host.key, thread, host)
          .bind(_ => {
            let resume_params = spread([set(common(), "threadId", s(thread)), obj([("excludeTurns", b(true))])])
            host
            .request("thread/resume", resume_params)
            .bind(first => station_tools_failed(host, thread).bind(failed => if failed {
              self.warn("a thread's station tools had failed; loading it again", obj([("thread", s(thread))]))
              host
              .request("thread/unsubscribe", obj([("threadId", s(thread))]))
              .bind(_ => host.request("thread/resume", resume_params))
            } else {
              Later::ok(lp, first)
            }))
          })
        None => host.request("thread/start", common())
      }
      opened.bind(first => {
        guard str_at(get(Some(first), "thread"), "id") is Some(thread_id) else {
          return Later::fail(lp, Failed("codex gave no thread id"))
        }
        let checked : Later[(JValue, String)] = if text_only {
          let tid = Ref(Some(thread_id))
          mcp_inventory(host, thread_id~)
          .bind(servers => {
            if !servers.iter().any(sv => !(str_of(Some(sv.1)) == Some("disabled"))) {
              return Later::ok(lp, (first, thread_id))
            }
            if resumed is Some(_) {
              raise Failed("cannot disable a resumed thread's MCP servers")
            }
            host
            .request("thread/unsubscribe", obj([("threadId", s(thread_id))]))
            .bind(_ => {
              config.val = set(
                config.val,
                "mcp_servers",
                spread([
                  get(Some(config.val), "mcp_servers").unwrap_or(obj([])),
                  obj(servers.map(sv => (sv.0, obj([("enabled", b(false))])))),
                ]),
              )
              host.request("thread/start", common())
            })
            .bind(again => {
              tid.val = str_at(get(Some(again), "thread"), "id")
              guard tid.val is Some(t2) else { raise Failed("codex gave no thread id") }
              mcp_inventory(host, thread_id=t2).map(after => {
                if after.iter().any(sv => !(str_of(Some(sv.1)) == Some("disabled"))) {
                  raise Failed("MCP servers are enabled")
                }
                (again, t2)
              })
            })
          })
          .recover(_ => {
            let unsubscribed = match tid.val {
              Some(t) =>
                host
                .request("thread/unsubscribe", obj([("threadId", s(t))]))
                .map(_ => ())
                .recover(_ => done(lp))
              None => done(lp)
            }
            unsubscribed.bind(_ => Later::fail(lp, Failed("cannot open a text-only Codex session")))
          })
        } else {
          Later::ok(lp, (first, thread_id))
        }
        checked.bind(got => {
          let (opened, thread_id) = got
          let session = self.session(thread_id, host, profile, false, None, no_live_state(), events)
          let remembered = session.remember_transcript(get(get(Some(opened), "thread"), "path"))
          session.running = Some((model, str_at(o, "effort")))
          session.tools_url = str_at(o, "mcpUrl")
          host.add_thread(thread_id, session.sink(), no_live_state())
          remembered.map(_ => session)
        })
      })
    })
  })
}

///|
pub fn CodexDriver::words_repo(self : CodexDriver) -> String {
  self.words.repo_rules_command
}

///|
/// Takes up a session whose thread's app-server a runner kept (`adopt`).
pub fn CodexDriver::adopt(
  self : CodexDriver,
  options : JValue,
  snapshot : JValue?,
  events : (JValue) -> Unit,
) -> Later[CodexSession] {
  let handed = match snapshot {
    Some(Obj(_) as j) => Some(j)
    _ => None
  }
  let profile = get(Some(options), "profile").unwrap_or(Null)
  let profile_id = match str_at(handed, "profile") {
    Some(p) => p
    None => profile_id(profile)
  }
  let key = match str_at(get(handed, "host"), "key") {
    Some(k) => k
    None => profile_id
  }
  self
  .serial(() => self
    .adopted_host(options, handed, profile_id, key)
    .map(host => {
      host.opening += 1
      host
    }))
  .bind(leased => {
    let made = try Ok(self.adopt_on(leased, options, handed, events, key)) catch {
      e => Err(e)
    }
    let out = match made {
      Ok(session) => session.transcript_known.map(_ => session)
      Err(e) => Later::fail(self.lp(), e)
    }
    out.always(() => self.let_go(leased))
  })
}

///|
/// The app-server a session taken up ran on, taken up too where it is not yet (`adoptedHost`).
pub fn CodexDriver::adopted_host(
  self : CodexDriver,
  options : JValue,
  handed : JValue?,
  profile_id : String,
  key : String,
) -> Later[Host] {
  let lp = self.lp()
  let profile = get(Some(options), "profile").unwrap_or(Null)
  let hs = get(handed, "host")
  let no_runner = () => Later::fail(lp, Failed("codex app-server \{key} was not taken up: no runner keeps it"))
  if is_true(hs, "draining") {
    let runner = str_at(hs, "runner").unwrap_or("")
    match self.draining.search_by(h => h.p().info.id() == runner) {
      Some(i) => return Later::ok(lp, self.draining[i])
      None => ()
    }
    return find_runner(self.m, self.data, runner).bind(found => {
      guard found is Some(info) else { return no_runner() }
      self.claimed.push(info.id())
      let host = self.adopt_host(
        profile_id,
        info,
        str_at(hs, "signature").unwrap_or(""),
        num_at(hs, "nextId").unwrap_or(0.0),
        is_true(hs, "ready"),
        None,
        key,
        Some(num_at(hs, "keep").unwrap_or(0.0).to_int()),
      )
      self.read_version(host, out_file(self.m, self.data, info.id()))
      self.keep_draining(host)
      Later::ok(lp, host)
    })
  }
  match self.host_at(key) {
    Some(current) if current.alive() => {
      if is_true(hs, "loginStale") {
        current.login_stale = true
      }
      if is_true(hs, "runtimeStale") {
        current.runtime_stale = true
      }
      return Later::ok(lp, current)
    }
    _ => ()
  }
  let released = match self.host_at(key) {
    Some(c) => (c.p().released)()
    None => done(lp)
  }
  released
  .bind(_ => match handed {
    Some(_) => {
      let runner = str_at(hs, "runner").unwrap_or("")
      find_runner(self.m, self.data, runner).bind(found => {
        guard found is Some(info) else { return no_runner().map(_ => None) }
        self.claimed.push(info.id())
        let host = self.adopt_host(
          profile_id,
          info,
          str_at(hs, "signature").unwrap_or(""),
          num_at(hs, "nextId").unwrap_or(0.0),
          is_true(hs, "ready"),
          None,
          key,
          Some(num_at(hs, "keep").unwrap_or(0.0).to_int()),
        )
        self.sweep_left(profile, key)
        if is_true(hs, "loginStale") {
          host.login_stale = true
        }
        if is_true(hs, "runtimeStale") {
          host.runtime_stale = true
        }
        self.read_version(host, out_file(self.m, self.data, info.id()))
        Later::ok(lp, Some(host))
      })
    }
    None => self.take_up_left(profile, key)
  })
  .bind(host => match host {
    None => no_runner()
    Some(h) => {
      self.host_set(key, h)
      Later::ok(lp, h)
    }
  })
}

///|
/// A session taken up on `host` (`adoptOn`).
pub fn CodexDriver::adopt_on(
  self : CodexDriver,
  host : Host,
  options : JValue,
  handed : JValue?,
  events : (JValue) -> Unit,
  key : String,
) -> CodexSession raise {
  let profile = get(Some(options), "profile").unwrap_or(Null)
  let mut on = host
  let session = match handed {
    Some(h) => {
      let live = match get(Some(h), "live") {
        Some(Null) | None => no_live_state()
        Some(l) => l
      }
      let x = self.session(
        str_at(Some(h), "threadId").unwrap_or(""),
        on,
        profile,
        is_true(Some(h), "busy"),
        str_at(Some(h), "turnId"),
        live,
        events,
      )
      x.tuned = match get(Some(h), "tuned") {
        Some(Obj(_) as t) =>
          Some((str_at(Some(t), "model").unwrap_or(""), str_at(Some(t), "effort").unwrap_or("")))
        _ => None
      }
      x.running = x.tuned.map(t => (Some(t.0), Some(t.1)))
      x.tools_url = str_at(Some(h), "mcpUrl")
      x.remember_transcript(get(Some(h), "transcriptPath")) |> ignore
      x
    }
    None => {
      guard str_at(Some(options), "resume") is Some(thread_id) else {
        raise Failed("a codex thread is taken up by its id (resumed)")
      }
      match self.draining.search_by(d => d.key == key &&
          (match d.recovered.search_by(r => r.0 == thread_id) {
            Some(i) => d.recovered[i].1.busy
            None => false
          })) {
        Some(i) => on = self.draining[i]
        None => ()
      }
      let r = match on.recovered.search_by(x => x.0 == thread_id) {
        Some(i) => Some(on.recovered.remove(i).1)
        None => None
      }
      let x = self.session(
        thread_id,
        on,
        profile,
        r.map(r => r.busy).unwrap_or(false),
        match r {
          Some(r) => r.turn_id
          None => None
        },
        r.map(r => r.live).unwrap_or(no_live_state()),
        events,
      )
      if r.map(r => r.busy).unwrap_or(false) {
        events(obj([("type", s("turnStarted"))]))
      }
      x
    }
  }
  let on = on
  let router = match self.adopt_routers.get(key) {
    Some(r) => {
      let proc = on.p()
      Some(batch => r(batch, proc))
    }
    None => None
  }
  self.adopt_routers.remove(key)
  on.add_thread(session.thread_id, session.sink(), session.live, router~)
  session.recover_transcript()
  if session.busy {
    on.turn_add(session.thread_id)
    if handed is Some(_) {
      on.running(session.thread_id, on.handed_from)
    }
  }
  self.m.lp.after(orphans_ms, () => self.host_idle(on)) |> ignore
  session
}

///|
/// A borrowed login about to run out: a new one lent in its place (`renewLent`).
pub fn CodexDriver::renew_lent(self : CodexDriver, host : Host, profile : JValue) -> Later[Unit] {
  let lp = self.lp()
  match host.lent_until {
    None => return done(lp)
    Some(until) if until - self.m.now() >= lent_renew_ms => return done(lp)
    _ => ()
  }
  if !self.borrowed(profile) {
    return done(lp)
  }
  (self.world.lent_write.unwrap())(profile)
  .map(until => {
    host.lent_until = Some(until)
    self.info(
      "its borrowed login runs out; a new one is lent under its app-server",
      obj([("profile", s(profile_id(profile)))]),
    )
  })
  .recover(e => {
    self.warn(
      "its borrowed login runs out and no new one was lent",
      obj([("profile", s(profile_id(profile))), ("error", s(words_of(e)))]),
    )
    done(lp)
  })
}

///|
/// Whether a host is not to start another turn (`outdated`).
pub fn CodexDriver::outdated(self : CodexDriver, host : Host, profile : JValue?) -> Later[Bool] {
  match profile {
    Some(p) if host.signature != self.host_signature(p) => return Later::ok(self.lp(), true)
    _ => ()
  }
  if host.runtime_stale {
    return Later::ok(self.lp(), true)
  }
  if host.version is None {
    return Later::ok(self.lp(), false)
  }
  self.installed_version().map(_ => self.stale(host))
}

///|
pub fn CodexDriver::hosted_procs(self : CodexDriver) -> Array[Proc] {
  (self.hosts.map(h => h.1) + self.draining).filter(h => h.alive()).map(h => h.p())
}

///|
pub fn CodexDriver::freeze(self : CodexDriver) -> Later[Unit] {
  (self.procs.freeze)(self.hosted_procs())
}

///|
pub fn CodexDriver::thaw(self : CodexDriver) -> Unit {
  (self.procs.thaw)(self.hosted_procs())
}

///|
/// Its app-servers ended (`shutdown`).
pub fn CodexDriver::shutdown(self : CodexDriver, again? : Bool = false) -> Later[Unit] {
  let lp = self.lp()
  self
  .serial(() => {
    self.stopped = !again
    let hosts = self.hosts.map(h => h.1) + self.draining
    self.hosts.clear()
    self.draining.clear()
    Later::ok(lp, hosts)
  })
  .recover(_ => Later::ok(lp, []))
  .bind(hosts => all(lp, hosts.map(h => (h.p().kill)(5000.0))))
  .bind(_ => if again { done(lp) } else { (self.procs.close)() })
}

///|
pub fn CodexDriver::detach(self : CodexDriver) -> Unit {
  for h in self.hosts.map(h => h.1) + self.draining {
    h.detach()
  }
  self.hosts.clear()
  self.draining.clear()
}

///|
pub fn CodexDriver::update_matches_station(self : CodexDriver, profile : JValue) -> Later[Bool] {
  if self.command != "codex" {
    return Later::ok(self.lp(), false)
  }
  (self.world.update_matches)(profile)
}

///|
pub fn CodexSession::lp(self : CodexSession) -> Loop {
  self.driver.lp()
}

///|
pub fn CodexSession::end_turn(self : CodexSession, outcome : JValue, routed? : Bool = false) -> Unit {
  self.busy = false
  self.turn_id = None
  self.host.turn_delete(self.thread_id)
  self.host.forget(self.thread_id)
  let mut ended = obj([("type", s("turnEnded")), ("outcome", outcome)])
  if routed {
    ended = set(ended, "routed", b(true))
  }
  (self.events)(ended)
  self.driver.host_idle(self.host)
}

///|
/// A thread's share of its app-server's notifications (`sink`).
pub fn CodexSession::sink(self : CodexSession) -> Sink {
  notice => match notice {
    HostExited(reason) => {
      self.closed = true
      if self.busy {
        self.end_turn(
          obj([("kind", s("failed")), ("reason", s("exited")), ("message", s(reason))]),
        )
      }
      (self.events)(obj([("type", s("closed")), ("why", s(reason))]))
    }
    Events(events, live, routed) => {
      let given = (e : JValue) => (self.events)(if routed { set(e, "routed", b(true)) } else { e })
      for e in events {
        let at = match (num_at(Some(e), "from"), num_at(Some(e), "to")) {
          (Some(f), Some(t)) => Some((f.to_int(), t.to_int()))
          _ => None
        }
        match str_at(Some(e), "type") {
          Some("turnStarted") => {
            match at {
              Some((f, t)) => self.host.note_turn(self.thread_id, true, f, t)
              None => ()
            }
            match str_at(Some(e), "turnId") {
              Some(id) => self.turn_id = Some(id)
              None => ()
            }
            let was = self.busy
            self.busy = true
            self.host.turn_add(self.thread_id)
            if !was {
              given(obj([("type", s("turnStarted"))]))
            }
          }
          Some("turnEnded") => {
            match at {
              Some((f, t)) => self.host.note_turn(self.thread_id, false, f, t)
              None => ()
            }
            self.end_turn(get(Some(e), "outcome").unwrap_or(Null), routed~)
          }
          _ => given(e)
        }
      }
      self.live = live
    }
  }
}

///|
/// What its app-server says of its thread given its actor in the program too (`route`).
pub fn CodexSession::route(self : CodexSession, router : ((Int) -> Bool)?) -> Unit {
  if self.closed && router is Some(_) {
    return
  }
  self.host.route(self.thread_id, router)
}

///|
/// Keeps the rollout path Codex said of its thread (`rememberTranscript`).
pub fn CodexSession::remember_transcript(self : CodexSession, path : JValue?) -> Later[Unit] {
  self.transcript_asked += 1
  let asked = self.transcript_asked
  let known = remember_rollout(
    self.driver.m,
    self.driver.world.remember_rollout,
    profile_home(self.profile),
    self.thread_id,
    path.unwrap_or(Null),
  ).map(kept => if asked == self.transcript_asked { self.transcript_path = kept })
  self.transcript_known = known
  known
}

///|
/// Where its transcript is, asked of the app-server where a snapshot did not say (`recoverTranscript`).
pub fn CodexSession::recover_transcript(self : CodexSession) -> Unit {
  let lp = self.lp()
  self.transcript_known = self.transcript_known
    .bind(_ => {
      if self.transcript_path is Some(_) || self.closed {
        return done(lp)
      }
      self.host
      .request("thread/read", obj([("threadId", s(self.thread_id)), ("includeTurns", b(false))]))
      .bind(answer => if !self.closed {
        self.remember_transcript(get(get(Some(answer), "thread"), "path"))
      } else {
        done(lp)
      })
    })
    .recover(_ => done(lp))
}

///|
/// A turn (`prompt`): its model, effort and service tier as the session and its profile say.
pub fn CodexSession::prompt(self : CodexSession, text : String) -> Later[Unit] {
  let lp = self.lp()
  let world = self.driver.world
  let fast = match world.fast {
    Some(f) => f(self.thread_id)
    None => None
  }
  let speed = match world.speed {
    Some(f) => f(self.thread_id)
    None => None
  }
  let p = match world.current_profile {
    Some(f) => f(self.host.profile)
    None => Some(self.profile)
  }
  let subscription = match p {
    Some(pr) => access_kind(pr) == "subscription"
    None => false
  }
  if speed == Some("ultrafast") && !subscription {
    return Later::fail(lp, Said("station.speed.ultrafast_unavailable"))
  }
  let outdated = if self.host.login_stale || self.host.runtime_stale {
    Later::ok(lp, true)
  } else if self.host.turns.length() == 0 {
    self.driver.outdated(self.host, p)
  } else {
    Later::ok(lp, false)
  }
  outdated
  .bind(outdated => self.driver
    .renew_lent(self.host, self.profile)
    .map(_ => {
      if self.closed {
        raise Failed("codex session is closed")
      }
      if self.busy {
        raise Failed("a turn is already running")
      }
      if outdated {
        raise Failed("codex was updated, or its profile changed, under its app-server")
      }
    }))
  .bind(_ => station_tools_failed(self.host, self.thread_id))
  .bind(failed => {
    if failed {
      // opened with the address its process failed to reach: the next thread opened with it goes to a new one
      match self.tools_url {
        Some(u) if u != "" => self.host.tools_failed_url = Some(u)
        _ => ()
      }
      raise Failed("codex thread's connection to the station's tools failed")
    }
    if self.tools_url is Some(_) && self.host.tools_failed_url == self.tools_url {
      self.host.tools_failed_url = None
    }
    if self.closed {
      raise Failed("codex session is closed")
    }
    if self.host.draining {
      raise Failed("its codex app-server is being replaced")
    }
    self.busy = true
    self.host.turn_add(self.thread_id)
    let mut params = obj([
      ("threadId", s(self.thread_id)),
      ("input", arr([obj([("type", s("text")), ("text", s(text))])])),
    ])
    match self.tuned {
      Some((model, effort)) => {
        params = set(params, "model", s(model))
        params = set(params, "effort", s(effort))
      }
      None => ()
    }
    if subscription {
      let tier = match speed {
        Some("ultrafast") => s("ultrafast")
        Some("fast") => s("fast")
        Some("standard") => Null
        _ => {
          let on = match fast {
            Some(f) => f
            None => profile_fast(p.unwrap())
          }
          if on {
            s("fast")
          } else {
            Null
          }
        }
      }
      params = set(params, "serviceTier", tier)
    }
    self.host
    .request("turn/start", params)
    .map(started => match str_at(get(Some(started), "turn"), "id") {
      Some(id) => self.turn_id = Some(id)
      None => ()
    })
    .recover(e => {
      self.busy = false
      self.host.turn_delete(self.thread_id)
      self.host.forget(self.thread_id)
      Later::fail(lp, e)
    })
  })
}

///|
/// `thread/compact/start` (`compact`).
pub fn CodexSession::compact(self : CodexSession) -> Later[Unit] {
  let lp = self.lp()
  self.driver
  .renew_lent(self.host, self.profile)
  .bind(_ => {
    if self.closed {
      raise Failed("codex session is closed")
    }
    if self.host.draining {
      raise Failed("its codex app-server is being replaced")
    }
    if self.busy {
      raise Failed("a turn is already running")
    }
    self.busy = true
    self.host.turn_add(self.thread_id)
    self.host
    .request("thread/compact/start", obj([("threadId", s(self.thread_id))]))
    .map(_ => ())
    .recover(e => {
      self.busy = false
      self.host.turn_delete(self.thread_id)
      self.host.forget(self.thread_id)
      Later::fail(lp, e)
    })
  })
}

///|
pub fn CodexSession::steer(self : CodexSession, text : String) -> Later[Bool] {
  let lp = self.lp()
  guard !self.closed && self.busy && self.turn_id is Some(turn) else { return Later::ok(lp, false) }
  self.host
  .request(
    "turn/steer",
    obj([
      ("threadId", s(self.thread_id)),
      ("input", arr([obj([("type", s("text")), ("text", s(text))])])),
      ("expectedTurnId", s(turn)),
    ]),
  )
  .map(_ => true)
  .recover(_ => Later::ok(lp, false))
}

///|
/// Given with the next turn/start (`retune`).
pub fn CodexSession::retune(self : CodexSession, options : JValue) -> Bool {
  let profile = get(Some(options), "profile").unwrap_or(Null)
  let model = match str_at(Some(options), "model") {
    Some(m) => Some(m)
    None => profile_model(profile)
  }
  let effort = str_at(Some(options), "effort")
  if self.closed || self.busy {
    return false
  }
  match self.running {
    Some((rm, re)) if rm == model && re == effort => return true
    _ => ()
  }
  guard model is Some(m) && effort is Some(e) else { return false }
  self.tuned = Some((m, e))
  self.running = Some((Some(m), Some(e)))
  true
}

///|
pub fn CodexSession::abort(self : CodexSession) -> Later[Unit] {
  let lp = self.lp()
  if self.closed || !self.busy {
    return done(lp)
  }
  guard self.turn_id is Some(turn) else {
    return Later::fail(lp, Failed("codex has not reported its running turn id"))
  }
  self.host
  .request("turn/interrupt", obj([("threadId", s(self.thread_id)), ("turnId", s(turn))]))
  .map(_ => ())
  .recover(e => {
    self.driver.warn(
      "codex interrupt failed",
      obj([("thread", s(self.thread_id)), ("error", s(words_of(e)))]),
    )
    Later::fail(lp, e)
  })
}

///|
pub fn CodexSession::dispose(self : CodexSession) -> Later[Unit] {
  let lp = self.lp()
  if self.closed {
    return done(lp)
  }
  self.closed = true
  self.host.drop_thread(self.thread_id)
  self.host.turn_delete(self.thread_id)
  if (self.host.p().handed)() {
    return done(lp)
  }
  self.host.forget(self.thread_id)
  self.host
  .request("thread/unsubscribe", obj([("threadId", s(self.thread_id))]))
  .map(_ => ())
  .recover(_ => done(lp))
}

///|
/// What a next station takes it up from (`snapshot`).
pub fn CodexSession::snapshot(self : CodexSession) -> JValue {
  self.host.freeze()
  self.closed = true
  let fields = [
    ("runtime", s("codex")),
    ("threadId", s(self.thread_id)),
    ("profile", s(self.host.profile)),
    ("busy", b(self.busy)),
    ("turnId", opt_s(self.turn_id)),
    ("live", self.live),
    ("host", self.host.snapshot()),
    (
      "tuned",
      match self.tuned {
        Some((m, e)) => obj([("model", s(m)), ("effort", s(e))])
        None => Null
      },
    ),
    ("mcpUrl", opt_s(self.tools_url)),
  ]
  match self.transcript_path {
    Some(p) => fields.push(("transcriptPath", s(p)))
    None => ()
  }
  obj(fields)
}

///|
pub fn CodexSession::detach(self : CodexSession) -> Unit {
  self.closed = true
  self.host.freeze()
  self.host.drop_thread(self.thread_id)
  if self.host.threads.length() == 0 {
    self.host.detach()
  }
}

///|
/// A path with its `.` and `..` taken out (`path.normalize` of an absolute one).
pub fn normalized(path : String) -> String {
  let parts : Array[String] = []
  for p in path.split("/") {
    let part = p.to_string()
    if part == "" || part == "." {
      continue
    }
    if part == ".." {
      parts.pop() |> ignore
    } else {
      parts.push(part)
    }
  }
  "/" + parts.join("/")
}

///|
/// The rollout path Codex said of a thread, kept where it is one of its home's (`rememberCodexRolloutLooking`).
pub fn remember_rollout(
  m : Machine,
  note : (String, Array[String], String) -> Unit,
  home : String,
  id : String,
  path : JValue,
) -> Later[String?] {
  guard path is Str(u) else { return Later::ok(m.lp, None) }
  let p = @jsjson.text(u)
  if !p.has_prefix("/") || id.contains("/") || id.contains("\\") || id.contains("\u{0}") {
    return Later::ok(m.lp, None)
  }
  let name = match p.rev_find("/") {
    Some(i) => p.substring(start=i + 1)
    None => p
  }
  if !name.has_prefix("rollout-") || !name.has_suffix("-\{id}.jsonl") {
    return Later::ok(m.lp, None)
  }
  let dir = m.join([home, "sessions"])
  m
  .realpath(dir)
  .map(real => {
    let real = real.unwrap_or(dir)
    let target = normalized(p)
    let within = (root : String) => {
      let r = normalized(root)
      target.has_prefix(r + "/") && target.length() > r.length() + 1
    }
    if !within(dir) && !within(real) {
      return None
    }
    let root = normalized(if within(dir) { dir } else { real })
    note(id, [dir, real], target.substring(start=root.length() + 1))
    Some(p)
  })
}
