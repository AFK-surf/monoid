// This station's copies as the station keeps them going (copies.ts): what the store says changed handed to the export
// a moment later, what it wrote brought to the stations that keep this one's copies, the copies this station keeps of
// others handed over where they are not its to keep any more, and a lost station's copy brought back into a new one.

///|
pub let gather_ms : Double = 1000.0

///|
pub let copies_retry_ms : Double = 5000.0

///|
pub let copies_retry_most_ms : Double = 600000.0

///|
pub let copies_tell_ms : Double = 30000.0

///|
pub let tell_restore_ms : Double = 1000.0

///|
/// `Math.min(base * 2 ** tries, most)`.
pub fn backoff(base : Double, tries : Int, most : Double) -> Double {
  let mut w = base
  for _ in 0..<tries {
    w = w * 2.0
    if w >= most {
      return most
    }
  }
  if w < most {
    w
  } else {
    most
  }
}

///|
pub fn kept_dir(fs : Fs, data : String) -> String {
  fs.join([data, "replicas"])
}

///|
pub fn formerly_file(fs : Fs, data : String) -> String {
  fs.join([data, "replica", "formerly.json"])
}

///|
pub fn outcome_file(fs : Fs, data : String) -> String {
  fs.join([data, "replica", "restored.json"])
}

///|
pub fn restore_dir(fs : Fs, data : String) -> String {
  fs.join([data, "restore"])
}

///|
pub fn ready_file(fs : Fs, data : String) -> String {
  fs.join([restore_dir(fs, data), "ready.json"])
}

///|
pub fn copy_dir(fs : Fs, data : String) -> String {
  fs.join([restore_dir(fs, data), "copy"])
}

///|
/// The stations this one took the place of, as `formerly.json` says.
pub async fn formerly_of(fs : Fs, data : String) -> Array[String] {
  match fs.read_json(formerly_file(fs, data)) {
    Some(Arr(xs)) => xs.filter_map(x => str_of(Some(x))).filter(is_station)
    _ => []
  }
}

///|
/// A station of a workspace's roster: its id and name.
pub(all) struct Member {
  id : String
  name : String
  tasks : Bool
}

///|
/// What Copies is given (copies.ts `CopiesDeps`).
pub(all) struct CopiesDeps {
  data : String
  here : () -> String?
  /// The workspaces it is in (export.ts `Places`).
  places : () -> J
  roster : (String) -> Array[Member]?
  runner : Runner
  changed : () -> Unit
  /// Asks the station's launcher to start it again; None where there is none to ask.
  restart : async () -> (async () -> Unit)?
  taking : (() -> Array[String])?
}

///|
struct Keeping {
  mut to : Double
  mut at : Double?
  mut error : String?
  mut reason : String?
  mut missing : Int
  mut busy : Bool
  mut again : (() -> Unit)?
  mut tries : Int
  mut asked : Bool
  mut known : Known?
  mut head : String?
}

///|
struct Restoring {
  origin : String
  mut name : String
  workspace : String
  gen : String
  from : String
  mut done : Int
  mut total : Int
  mut error : String?
  mut reason : String?
  mut restart : Bool
}

///|
fn Restoring::to_json(self : Restoring) -> J {
  jo([
    ("origin", js(self.origin)),
    ("name", js(self.name)),
    ("workspace", js(self.workspace)),
    ("gen", js(self.gen)),
    ("from", js(self.from)),
    ("done", ji(self.done)),
    ("total", ji(self.total)),
    ("error", jopt(self.error)),
    ("reason", jopt(self.reason)),
    ("restart", jb(self.restart)),
  ])
}

///|
pub struct Copies {
  w : World
  d : CopiesDeps
  kept : FolderPlace
  mut told : Told
  mut gathering : (() -> Unit)?
  mut passing : Run?
  mut again : Bool
  mut closed : Bool
  mut passed : J?
  keeping : Map[String, Keeping]
  formerly : Map[String, Map[String, String]]
  mut handing : Run?
  mut hand_again : (() -> Unit)?
  mut hand_tries : Int
  mut restoring : Restoring?
  mut export_error : String?
  mut export_tries : Int
  old : Map[String, Bool]
  mut telling : (() -> Unit)?
  restored : J?
  was : Array[String]
  levelling : Map[String, Run]
  begun : Map[String, (String, Run)]
  looked : Map[String, (Array[J], Double, Bool)]
}

///|
pub async fn Copies::new(w : World, d : CopiesDeps) -> Copies {
  let restored = w.fs.read_json(outcome_file(w.fs, d.data))
  {
    w,
    d,
    kept: FolderPlace::new(w.fs, kept_dir(w.fs, d.data)),
    told: Told::nothing(),
    gathering: None,
    passing: None,
    again: false,
    closed: false,
    passed: None,
    keeping: {},
    formerly: {},
    handing: None,
    hand_again: None,
    hand_tries: 0,
    restoring: None,
    export_error: None,
    export_tries: 0,
    old: {},
    telling: None,
    restored,
    was: formerly_of(w.fs, d.data),
    levelling: {},
    begun: {},
    looked: {},
  }
}

///|
fn places_workspaces(p : J) -> Array[(String, String)] {
  items(at(p, "workspaces")).map(x => (text_at(x, "workspace"), text_at(x, "name")))
}

///|
/// Begun: the export told where it is, a first pass, the other stations told it is up.
pub async fn Copies::start(self : Copies) -> Unit {
  for _, k in self.keeping {
    k.known = None
  }
  self.places_changed()
}

///|
pub async fn Copies::close(self : Copies) -> Unit {
  self.closed = true
  call_opt(self.gathering)
  call_opt(self.telling)
  for _, k in self.keeping {
    call_opt(k.again)
  }
  call_opt(self.hand_again)
  match self.passing {
    Some(r) => r.settled()
    None => ()
  }
  match self.handing {
    Some(r) => r.settled()
    None => ()
  }
}

///|
pub fn call_opt(f : (() -> Unit)?) -> Unit {
  match f {
    Some(g) => g()
    None => ()
  }
}

///|
/// The station's settings told the copies changed: within `ms` (0: now).
fn Copies::changed(self : Copies, ms : Double) -> Unit {
  if ms == 0.0 {
    call_opt(self.telling)
    self.telling = None
    (self.d.changed)()
    return
  }
  if self.telling is Some(_) || self.closed {
    return
  }
  // timer: a debounce of a burst (a pass a second while agents work)
  self.telling = Some(
    self.w.after(ms, () => {
      self.telling = None
      (self.d.changed)()
    }),
  )
}

///|
/// The store's change, put with what is to be exported: a few keys, nothing read.
pub fn Copies::told(self : Copies, change : J) -> Unit {
  if tell(self.told, change) {
    self.gather()
  }
}

///|
fn Copies::gather(self : Copies) -> Unit {
  if self.gathering is Some(_) || self.closed {
    return
  }
  // timer: a debounce of a burst of the store's changes
  self.gathering = Some(
    self.w.after(gather_ms, () => {
      self.gathering = None
      self.w.go(async fn() { self.pass() })
    }),
  )
}

///|
/// One pass at a time; what is told meanwhile goes in the next.
async fn Copies::pass(self : Copies) -> Unit {
  if self.passing is Some(_) {
    self.again = true
    return
  }
  let told = self.told
  self.told = Told::nothing()
  self.again = false
  let run = self.w.run(async fn() {
    try {
      let passed = (self.d.runner.pass)(told.to_json())
      self.passed = Some(passed)
      if self.export_error is Some(_) {
        self.export_error = None
        self.export_tries = 0
        self.changed(0.0)
      } else if num_at(passed, "wrote").unwrap_or(0.0) > 0.0 {
        self.changed(copies_tell_ms)
      }
      for e in entries(at(passed, "heads")) {
        if items(at(e.1, "batches")).length() > 0 {
          self.level_all(e.0)
        }
      }
      if yes_at(passed, "more") {
        self.again = true
      }
    } catch {
      e => {
        self.w.warn("copies", "an export failed", jo([("error", js(message_of(e)))]))
        self.merge(told)
        if self.export_error is None {
          self.changed(0.0)
        }
        self.export_error = Some(message_of(e))
        let wait = backoff(copies_retry_ms, self.export_tries, copies_retry_most_ms)
        self.export_tries += 1
        if !self.closed {
          // timer: a retry after a failure
          ignore(self.w.after(wait, () => self.w.go(async fn() { self.pass() })))
        }
      }
    }
    self.passing = None
    if self.again && !self.closed {
      self.w.go(async fn() { self.pass() })
    }
  })
  self.passing = Some(run)
  run.settled()
}

///|
fn Copies::merge(self : Copies, told : Told) -> Unit {
  let t = self.told
  t.sessions.push_iter(told.sessions.iter())
  t.threads.push_iter(told.threads.iter())
  t.removed_sessions.push_iter(told.removed_sessions.iter())
  t.removed_threads.push_iter(told.removed_threads.iter())
  t.marks.push_iter(told.marks.iter())
}

///|
/// The export done now, and the places levelled: what a test waits for.
pub async fn Copies::settle(self : Copies) -> Unit {
  call_opt(self.gathering)
  self.gathering = None
  self.settle_export()
  while true {
    let busy = self.keeping.values().any(k => k.busy)
    if !busy && self.handing is None {
      break
    }
    for r in self.levelling.values().collect() {
      r.settled()
    }
    match self.handing {
      Some(r) => r.settled()
      None => ()
    }
  }
}

///|
/// The export brought to rest.
pub async fn Copies::settle_export(self : Copies) -> Unit {
  while true {
    self.pass()
    while self.passing is Some(r) {
      r.settled()
    }
    if !self.again {
      break
    }
  }
}

///|
/// The workspaces or their stations changed (or the station started).
pub async fn Copies::places_changed(self : Copies) -> Unit {
  let places = (self.d.places)()
  (self.d.runner.places)(places)
  let ins = places_workspaces(places).map(p => p.0)
  let fs = self.w.fs
  for root in [kept_dir(fs, self.d.data), fs.join([self.d.data, "replica", "own"])] {
    for ws in fs.names(root) {
      if is_workspace(ws) && !ins.contains(ws) {
        fs.rm_rf(fs.join([root, ws]))
      }
    }
  }
  for k in self.keeping.keys().collect() {
    if !ins.contains(split_key(k).0) {
      self.keeping.remove(k)
    }
  }
  for ws in ins {
    for k in self.keeping.keys().collect() {
      let (kw, station) = split_key(k)
      if kw == ws && !self.targets(ws).contains(station) {
        self.keeping.remove(k)
      }
    }
  }
  self.w.go(async fn() {
    self.pass()
    match self.passed {
      Some(p) if yes_at(p, "empty") =>
        for ws in ins {
          self.w.go(async fn() { self.look(ws) })
        }
      _ => ()
    }
  })
  self.hello()
  self.hand_over_soon()
}

///|
fn split_key(k : String) -> (String, String) {
  match k.find("\n") {
    Some(i) => (k.unsafe_substring(start=0, end=i), k.unsafe_substring(start=i + 1, end=k.length()))
    None => (k, "")
  }
}

///|
fn Copies::roster_ids(self : Copies, ws : String) -> Array[String]? {
  (self.d.roster)(ws).map(r => r.map(m => m.id))
}

///|
fn Copies::keepers_of(self : Copies, ws : String) -> Array[String] {
  match ((self.d.here)(), self.roster_ids(ws)) {
    (Some(here), Some(ids)) => keepers(ws, here, ids)
    _ => []
  }
}

///|
/// Each other station of each workspace told this one is up (and what it once was).
fn Copies::hello(self : Copies) -> Unit {
  guard (self.d.here)() is Some(here) else { return }
  let formerly = self.was
  for p in places_workspaces((self.d.places)()) {
    let ws = p.0
    for s in (self.d.roster)(ws).unwrap_or([]) {
      if s.id == here {
        continue
      }
      let id = s.id
      self.w.go(async fn() {
        let answer = self.w.ask(id, jo([("method", js("replica.hello")), ("workspace", js(ws)), ("formerly", jstrs(formerly))])) catch {
          e => {
            // (one that answers with a refusal is up but knows no `replica.*`: from before copies)
            if is_refused(e) {
              self.old[id] = true
            }
            return
          }
        }
        self.old.remove(id)
        self.heard_formerly(ws, id, strings_of(at(answer, "formerly")))
      })
    }
  }
}

///|
fn Copies::heard_formerly(self : Copies, ws : String, station : String, formerly : Array[String]) -> Unit {
  let m = match self.formerly.get(ws) {
    Some(m) => m
    None => {
      let m : Map[String, String] = {}
      self.formerly[ws] = m
      m
    }
  }
  for f in formerly {
    if is_station(f) {
      m[f] = station
    }
  }
}

///|
/// The station that took the place of `station` (a lost one) in `ws`, as it said; `station` itself where none did.
pub fn Copies::now(self : Copies, ws : String?, station : String) -> String {
  if self.was.contains(station) {
    return (self.d.here)().unwrap_or(station)
  }
  for w, m in self.formerly {
    if ws is None || ws == Some(w) {
      match m.get(station) {
        Some(s) => return s
        None => ()
      }
    }
  }
  station
}

///|
/// Another station is up (`replica.hello`).
pub fn Copies::heard(self : Copies, peer : String, ws : String, formerly : Array[String]) -> Array[String] {
  self.heard_formerly(ws, peer, formerly)
  self.old.remove(peer)
  match self.keeping.get("\{ws}\n\{peer}") {
    Some(k) => k.known = None
    None => ()
  }
  if self.targets(ws).contains(peer) || self.keepers_of(ws).contains(peer) {
    self.level(ws, peer, true, true)
  }
  self.hand_over_soon()
  self.was
}

///|
pub fn Copies::in_workspace(self : Copies, peer : String, ws : String) -> Bool {
  places_workspaces((self.d.places)()).iter().any(p => p.0 == ws) &&
  (self.d.roster)(ws).unwrap_or([]).iter().any(s => s.id == peer)
}

///|
/// What this station answers of the copies it keeps (`replica.*`).
pub async fn Copies::answer(self : Copies, peer : String, request : J, body : Body?, workspace : String?) -> Answer {
  serve(
    {
      place: self.kept,
      in_workspace: (p, ws) => self.in_workspace(p, ws),
      hello: (p, ws, formerly) => self.heard(p, ws, formerly),
    },
    peer,
    request,
    body,
    workspace,
  )
}

///|
fn Copies::level_all(self : Copies, ws : String) -> Unit {
  for peer in self.targets(ws) {
    self.level(ws, peer, false, false)
  }
}

///|
/// The stations that should hold this station's copies in `ws` now.
fn Copies::targets(self : Copies, ws : String) -> Array[String] {
  guard (self.d.here)() is Some(here) && self.roster_ids(ws) is Some(ids) else { return [] }
  let out = []
  let mut reached = 0
  for s in ranked(ws, here, ids) {
    out.push(s)
    match self.keeping.get("\{ws}\n\{s}") {
      Some({ error: Some(_), .. }) => ()
      _ => reached += 1
    }
    if reached >= copies_kept {
      break
    }
  }
  out
}

///|
fn Copies::reason(self : Copies, peer : String, e : Error) -> String {
  if self.old.contains(peer) {
    return "old"
  }
  if is_refused(e) {
    let m = message_of(e)
    return if m.contains("no such replica request") ||
      m.contains("is required") ||
      m.contains("are required") ||
      m.contains("unknown") {
      "old"
    } else {
      "error"
    }
  }
  "offline"
}

///|
fn Copies::own(self : Copies, head : J) -> Own {
  let fs = self.w.fs
  let dir = fs.join([self.d.data, "replica", "own", text_at(head, "workspace"), head_gen(head)])
  {
    head,
    batch: async fn(name) {
      match fs.files.read_bytes(fs.join([dir, "log", name])) {
        Some(b) => b
        None => raise Thrown("Error", jo([("message", js("ENOENT: no such file or directory, open '\{fs.join([dir, "log", name])}'")), ("code", js("ENOENT"))]))
      }
    },
    sources: async fn(hashes) { string_map(Some((self.d.runner.sources)(hashes))) },
  }
}

///|
fn Copies::head_of_ws(self : Copies, ws : String) -> J? {
  match self.passed {
    Some(p) => at(at(p, "heads").unwrap_or(Null), ws)
    None => None
  }
}

///|
/// `now`: not waiting for a retry already set; `fresh`: what the place holds asked of it.
fn Copies::level(self : Copies, ws : String, peer : String, now : Bool, fresh : Bool) -> Unit {
  let key = "\{ws}\n\{peer}"
  let k = match self.keeping.get(key) {
    Some(k) => k
    None => {
      let k : Keeping = {
        to: 0.0,
        at: None,
        error: None,
        reason: None,
        missing: 0,
        busy: false,
        again: None,
        tries: 0,
        asked: false,
        known: None,
        head: None,
      }
      self.keeping[key] = k
      k
    }
  }
  if k.busy {
    k.asked = true
    return
  }
  if k.again is Some(_) && !now {
    return
  }
  // (one from before copies, found so: asked again only once it is heard from, `heard`, never by a pass or a retry)
  if !now && k.error is Some(_) && k.reason == Some("old") && self.old.contains(peer) {
    return
  }
  call_opt(k.again)
  k.again = None
  guard self.head_of_ws(ws) is Some(head) && head_batches(head).length() > 0 else { return }
  if fresh {
    k.known = None
  }
  let said = "\{head_gen(head)}:\{num_text(head_to(head))}:\{num_text(head_made(head))}"
  if k.known is Some(_) && k.head == Some(said) && k.error is None {
    return
  }
  k.busy = true
  let was_error = k.error
  let run = self.w.run(async fn() {
    try {
      let place = peer_place(self.w, peer)
      let mut done = level(place, ws, self.own(head), known=k.known)
      if done is Behind {
        // This station's own copy is behind what that station keeps of it: a new generation, written beside it.
        let begun = match self.begun.get(ws) {
          Some((from, r)) if from == head_gen(head) => r
          _ => {
            let r = self.w.run(async fn() {
              let held = (place.held)(ws, text_at(head, "origin"))
              let mut most = 0.0
              for g in held.gens {
                let m = gen_made(g.gen)
                if m > most {
                  most = m
                }
              }
              (self.d.runner.new_generations)(most)
              self.settle_export()
            })
            self.begun[ws] = (head_gen(head), r)
            r
          }
        }
        begun.wait()
        guard self.head_of_ws(ws) is Some(next) else { raise failed("no copy of this workspace's") }
        done = level(place, ws, self.own(next))
        if done is Behind {
          raise failed("that station keeps more of this station's than it has")
        }
      }
      match done {
        Level(to, missing, known) => {
          k.known = Some(known)
          k.head = Some(said)
          k.reason = None
          k.to = to
          k.missing = missing
          k.at = Some(self.w.now())
          k.error = None
          k.tries = 0
        }
        Behind => ()
      }
    } catch {
      e => {
        let reason = self.reason(peer, e)
        // (one from before copies, which knows no `replica.*`: nothing to say or retry until it says it is up)
        if reason == "old" {
          self.old[peer] = true
        } else if k.error is None {
          self.w.warn("copies", "a place not brought level", jo([("ws", js(ws)), ("place", js(peer)), ("error", js(message_of(e)))]))
        }
        k.error = Some(message_of(e))
        k.reason = Some(reason)
        k.known = None
        if reason != "old" {
          let wait = backoff(copies_retry_ms, k.tries, copies_retry_most_ms)
          k.tries += 1
          if !self.closed {
            // timer: a retry after a failure
            k.again = Some(
              self.w.after(wait, () => {
                k.again = None
                self.level(ws, peer, true, true)
              }),
            )
          }
        }
        // (one not reached: the next station after those this one's copies fall to holds them meanwhile)
        if was_error is None {
          self.level_all(ws)
        }
      }
    }
    k.busy = false
    self.changed(if k.error == was_error { copies_tell_ms } else { 0.0 })
    self.levelling.remove(key)
    if k.asked && !self.closed {
      k.asked = false
      self.level(ws, peer, k.error is None, false)
    }
  })
  if !run.is_done() && k.busy {
    self.levelling[key] = run
  }
}

// ── what this station keeps of others ──

///|
fn Copies::hand_over_soon(self : Copies) -> Unit {
  if self.handing is Some(_) || self.closed {
    return
  }
  call_opt(self.hand_again)
  self.hand_again = None
  let run = self.w.run(async fn() {
    let left = self.hand_over() catch {
      e => {
        self.w.warn("copies", "copies not handed over", jo([("error", js(message_of(e)))]))
        self.retry_hand()
        self.handing = None
        return
      }
    }
    self.hand_tries = 0
    if left && !self.closed {
      self.retry_hand()
    }
    self.handing = None
  })
  if !run.is_done() {
    self.handing = Some(run)
  }
}

///|
fn Copies::retry_hand(self : Copies) -> Unit {
  let wait = backoff(copies_retry_ms, self.hand_tries, copies_retry_most_ms)
  self.hand_tries += 1
  // timer: a retry after a failure
  self.hand_again = Some(self.w.after(wait, () => self.hand_over_soon()))
}

///|
/// The copies this station keeps that are not its to keep now: handed to those that should keep them, and let go once
/// each of them says it holds as much. Whether some are left to hand over.
async fn Copies::hand_over(self : Copies) -> Bool {
  guard (self.d.here)() is Some(here) else { return false }
  let fs = self.w.fs
  let mut left = false
  for p in places_workspaces((self.d.places)()) {
    let ws = p.0
    guard self.roster_ids(ws) is Some(ids) else { continue }
    let taking = match self.d.taking {
      Some(f) => f()
      None => []
    }
    for origin in fs.names(fs.join([kept_dir(fs, self.d.data), ws])) {
      if !is_station(origin) || origin == here || taking.contains(origin) {
        continue
      }
      let should = keepers(ws, origin, ids)
      if should.contains(here) {
        continue
      }
      let mine = self.kept.held(ws, origin)
      let mut all = should.length() > 0
      for peer in should {
        let ok = hand_over(self.kept, peer_place(self.w, peer), ws, origin) catch { _ => false }
        if !ok {
          all = false
        }
      }
      if all {
        // (each of them holds as much as this one did: asked again just before it goes)
        let mut still = true
        for peer in should {
          let ok = holds_all(mine, (peer_place(self.w, peer).held)(ws, origin)) catch { _ => false }
          if !ok {
            still = false
          }
        }
        if still {
          fs.rm_rf(fs.join([kept_dir(fs, self.d.data), ws, origin]))
          self.w.info("copies", "a station's copies handed over", jo([("ws", js(ws)), ("origin", js(origin)), ("to", jstrs(should))]))
          continue
        }
      }
      left = true
    }
  }
  left
}

// ── what the station's settings show ──

///|
/// The copies of this station's chats in `ws`, as its settings show them.
pub fn Copies::overview(self : Copies, ws : String, manage? : Bool = false) -> J {
  let here = (self.d.here)()
  let head = self.head_of_ws(ws)
  let names = (self.d.roster)(ws).unwrap_or([])
  let name_of = (id : String) => match names.search_by(m => m.id == id) {
    Some(i) => names[i].name
    None => ""
  }
  let keepers = (if here is None { [] } else { self.targets(ws) }).map(station => {
    let k = self.keeping.get("\{ws}\n\{station}")
    match k {
      Some(k) =>
        jo([
          ("station", js(station)),
          ("name", js(name_of(station))),
          ("to", jn(k.to)),
          ("at", match k.at { Some(a) => jn(a); None => Null }),
          ("error", jopt(k.error)),
          ("reason", jopt(k.reason)),
        ])
      None =>
        jo([("station", js(station)), ("name", js(name_of(station))), ("to", ji(0)), ("at", Null), ("error", Null), ("reason", Null)])
    }
  })
  let empty = match self.passed {
    Some(p) => yes_at(p, "empty")
    None => false
  }
  let stopped = match self.export_error {
    None => J::Null
    Some(e) => {
      let l = e.to_lower()
      let full = l.contains("enospc") || l.contains("disk is full") || l.contains("database or disk is full")
      jo([("error", js(e)), ("tries", ji(self.export_tries)), ("reason", js(if full { "full" } else { "error" }))])
    }
  }
  jo([
    ("to", match head { Some(h) => at(h, "to").unwrap_or(ji(0)); None => ji(0) }),
    ("chats", match head { Some(h) => at(h, "chats").unwrap_or(ji(0)); None => ji(0) }),
    ("keepers", ja(keepers)),
    ("stopped", stopped),
    ("restored", self.restored.unwrap_or(Null)),
    ("empty", jb(empty)),
    (
      "restoring",
      match self.restoring {
        Some(r) if r.workspace == ws => r.to_json()
        _ => Null
      },
    ),
    (
      "restorable",
      if empty {
        match self.looked.get(ws) {
          Some((copies, a, looking)) => jo([("copies", ja(copies)), ("at", jn(a)), ("looking", jb(looking))])
          None => Null
        }
      } else {
        Null
      },
    ),
    ("manage", jb(manage)),
    ("formerly", jstrs(self.was)),
  ])
}

///|
/// The copies a station with no chat of its own could take back, looked for again.
pub async fn Copies::look(self : Copies, ws : String) -> Unit {
  guard self.passed is Some(p) && yes_at(p, "empty") else { return }
  let was = self.looked.get(ws)
  self.looked[ws] = (
    match was {
      Some(x) => x.0
      None => []
    },
    match was {
      Some(x) => x.1
      None => 0.0
    },
    true,
  )
  self.changed(0.0)
  let copies = self.restorable(ws) catch {
    e => {
      self.looked[ws] = ([], self.w.now(), false)
      self.changed(0.0)
      raise e
    }
  }
  self.looked[ws] = (copies, self.w.now(), false)
  self.changed(0.0)
}

// ── a lost station's copy, brought back into this one ──

///|
/// The copies of stations of `ws` no longer there that could be brought back here.
pub async fn Copies::restorable(self : Copies, ws : String) -> Array[J] {
  let here = (self.d.here)()
  let found : Map[String, (J, Array[String])] = {}
  let add = (head : J, from : String) => {
    let origin = text_at(head, "origin")
    if Some(origin) == here {
      return
    }
    match found.get(origin) {
      None => found[origin] = (head, [from])
      Some((was, froms)) => {
        let newer = gen_made(head_gen(head)) > gen_made(head_gen(was)) ||
          (head_gen(head) == head_gen(was) && head_to(head) > head_to(was))
        if newer {
          found[origin] = (head, [from])
        } else if head_gen(head) == head_gen(was) && head_to(head) == head_to(was) && !froms.contains(from) {
          froms.push(from)
        }
      }
    }
  }
  let roster = (self.d.roster)(ws).unwrap_or([])
  let taken : Map[String, Bool] = {}
  for s in self.was {
    taken[s] = true
  }
  let there : Map[String, Bool] = {}
  let asks : Array[async () -> Unit] = []
  for s in roster {
    if Some(s.id) == here {
      continue
    }
    let id = s.id
    asks.push(async fn() {
      try {
        let answer = self.w.ask(id, jo([("method", js("replica.hello")), ("workspace", js(ws)), ("formerly", jstrs(self.was))]))
        there[id] = true
        let said = strings_of(at(answer, "formerly"))
        self.heard_formerly(ws, id, said)
        for f in said {
          taken[f] = true
        }
        for o in peer_origins(self.w, id, ws) {
          for h in o.1 {
            add(h, id)
          }
        }
      } catch {
        _ => ()
      }
    })
  }
  ignore(@effect.all(asks))
  for _, m in self.formerly {
    for f, _ in m {
      taken[f] = true
    }
  }
  for f, _ in taken {
    found.remove(f)
  }
  match here {
    Some(h) =>
      for o in self.kept.origins(ws) {
        for x in o.1 {
          add(x, h)
        }
      }
    None => ()
  }
  for f, _ in taken {
    found.remove(f)
  }
  for f, _ in there {
    found.remove(f)
  }
  let name_of = (id : String) => match roster.search_by(m => m.id == id) {
    Some(i) => roster[i].name
    None => ""
  }
  found
  .values()
  .map(x => {
    let (head, from) = x
    let origin = text_at(head, "origin")
    let given = text_at(head, "name")
    jo([
      ("station", js(origin)),
      ("name", js(if given != "" { given } else { name_of(origin) })),
      ("gen", js(head_gen(head))),
      ("made", at(head, "made").unwrap_or(Null)),
      ("to", at(head, "to").unwrap_or(Null)),
      ("chats", at(head, "chats").unwrap_or(Null)),
      ("messages", at(head, "messages").unwrap_or(Null)),
      ("bytes", at(head, "bytes").unwrap_or(Null)),
      ("from", ja(from.map(f => jo([("station", js(f)), ("name", js(name_of(f)))])))),
    ])
  })
  .collect()
}

///|
/// This station's copy of `ws` as it is now, brought to `peer`: its generation.
pub async fn Copies::bring_to(self : Copies, ws : String, peer : String) -> String {
  self.settle_export()
  guard self.head_of_ws(ws) is Some(head) else { raise failed("no copy of this workspace's chats") }
  let done = level(peer_place(self.w, peer), ws, self.own(head))
  if done is Behind {
    raise failed("that station keeps more of this station's chats than it has")
  }
  head_gen(head)
}

///|
/// A retired station's copy put in beside this station's own chats as it starts again.
pub async fn Copies::take_over(self : Copies, ws : String, origin : String, gen : String, connects : Array[(String, String)], ws_here : String?) -> Unit {
  self.restore(ws, origin, gen, (self.d.here)().unwrap_or(""), merge=Some((connects, ws_here)))
}

///|
/// Brings `origin`'s copy (`gen`) here from `from`, then has the station start again to put it in.
pub async fn Copies::restore(self : Copies, ws : String, origin : String, gen : String, from : String, merge? : (Array[(String, String)], String?)? = None) -> Unit {
  if !is_station(origin) || !is_gen(gen) || !is_workspace(ws) {
    raise failed("not a copy's name")
  }
  if merge is None && !(self.passed is Some(p) && yes_at(p, "empty")) {
    raise not_empty()
  }
  match self.restoring {
    Some(r) if r.error is None => raise failed("a restore is under way")
    _ => ()
  }
  let r : Restoring = {
    origin,
    name: "",
    workspace: ws,
    gen,
    from,
    done: 0,
    total: 0,
    error: None,
    reason: None,
    restart: false,
  }
  self.restoring = Some(r)
  self.changed(0.0)
  self.bring(r, merge) catch {
    e => {
      r.error = Some(message_of(e))
      r.reason = Some(
        if kind_of(e) == "NotEmpty" {
          "notEmpty"
        } else if kind_of(e) == "CopyGone" {
          "gone"
        } else {
          self.reason(from, e)
        },
      )
      self.w.warn("copies", "a copy not brought", jo([("origin", js(origin)), ("from", js(r.from)), ("error", jopt(r.error))]))
      self.changed(0.0)
      raise e
    }
  }
}

///|
pub fn not_empty() -> Thrown {
  Thrown("NotEmpty", jo([("message", js("this station has chats of its own: a copy is taken back only into a new one"))]))
}

///|
async fn Copies::bring(self : Copies, r : Restoring, merge : (Array[(String, String)], String?)?) -> Unit {
  let fs = self.w.fs
  let ws = r.workspace
  let origin = r.origin
  let gen = r.gen
  let here = (self.d.here)()
  let (held, stream) : (Held, async (String?, String) -> Body) = if Some(r.from) == here {
    let place = self.kept
    (place.held(ws, origin), async fn(g, name) { place.stream(ws, origin, g, name) })
  } else {
    let from = r.from
    ((peer_place(self.w, from).held)(ws, origin), async fn(g, name) { peer_read(self.w, from, ws, origin, g, name) })
  }
  let save = async fn(path : String, g : String?, name : String) {
    let part = "\{path}.part"
    fs.files.write(part, b"")
    let next = stream(g, name).reader(fs)
    let mut at = 0.0
    while next() is Some(piece) {
      ignore(fs.host.shell("fs.put", { "path": Json::string(part), "offset": Json::number(at) }, bytes=piece))
      at += piece.length().to_double()
    }
    ignore(fs.host.shell("fs.put", { "path": Json::string(part), "offset": Json::number(at), "sync": Json::boolean(true) }, bytes=b""))
    fs.rename(part, path)
  }
  let holding = held.gens.search_by(g => g.gen == gen).map(i => held.gens[i])
  guard holding is Some({ head: Some(head), .. }) else {
    raise Thrown("CopyGone", jo([("message", js("that copy is not kept there"))]))
  }
  let names = head_files(head)
  r.name = text_at(head, "name")
  r.total = head_batches(head).length() + names.length()
  self.changed(0.0)
  let dir = copy_dir(fs, self.d.data)
  fs.rm_rf(dir)
  fs.mkdirs(fs.join([dir, gen, "log"]))
  fs.mkdirs(fs.join([dir, "files"]))
  for b in head_batches(head) {
    save(fs.join([dir, gen, "log", b]), Some(gen), b)
    r.done += 1
    self.changed(tell_restore_ms)
  }
  for hash in names {
    save(fs.join([dir, "files", hash]), None, hash)
    r.done += 1
    self.changed(tell_restore_ms)
  }
  fs.write_text(fs.join([dir, gen, "head.json"]), @jsjson.stringify_indent(head, 1))
  // (still no chat of its own, as it is about to be put in: one made meanwhile, and it is not)
  self.settle_export()
  if merge is None && !(self.passed is Some(p) && yes_at(p, "empty")) {
    raise not_empty()
  }
  let ready = [("origin", js(origin)), ("workspace", js(ws)), ("gen", js(gen)), ("name", js(text_at(head, "name"))), ("from", js(r.from))]
  match merge {
    Some((connects, ws_here)) => {
      ready.push(("merge", jb(true)))
      ready.push(("connects", pairs_json(connects)))
      ready.push(("ws", jopt(ws_here)))
    }
    None => ()
  }
  fs.write_text(ready_file(fs, self.d.data), stringify(jo(ready)))
  let go = (self.d.restart)()
  r.restart = go is None
  self.changed(0.0)
  match go {
    Some(f) => f()
    None => ()
  }
}
