// This station's copies as the station keeps them going (copies.ts): what the store says changed handed to the export
// a moment later, what it wrote brought to the stations that keep this one's copies, the copies this station keeps of
// others handed over where they are not its to keep any more, and a lost station's copy brought back into a new one.

///|
pub let gather_ms : Double = 1000.0

///|
pub let transcript_gather_ms : Double = 30000.0

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
pub fn history_file(fs : Fs, data : String) -> String {
  fs.join([data, "replica", "history.json"])
}

///|
pub let history_max : Int = 50

///|
pub(all) struct BackupRecord {
  id : String
  at : Double
  kind : String
  target_kind : String
  target : String
  target_name : String
  status : String
  chats : Int
  messages : Int
  batches : Int
  bytes : Double
  reason : String?
  error : String?
}

///|
pub fn BackupRecord::to_json(self : BackupRecord) -> J {
  jo([
    ("id", js(self.id)),
    ("at", jn(self.at)),
    ("kind", js(self.kind)),
    ("targetKind", js(self.target_kind)),
    ("target", js(self.target)),
    ("targetName", js(self.target_name)),
    ("status", js(self.status)),
    ("chats", ji(self.chats)),
    ("messages", ji(self.messages)),
    ("batches", ji(self.batches)),
    ("bytes", jn(self.bytes)),
    ("reason", jopt(self.reason)),
    ("error", jopt(self.error)),
  ])
}

///|
fn is_valid_history_reason(s : String) -> Bool {
  s == "offline" || s == "old" || s == "error" || s == "gone" || s == "notEmpty"
}

///|
fn parse_backup_record(v : J) -> BackupRecord? {
  guard str_at(v, "id") is Some(id) && id != "" else { return None }
  guard num_at(v, "at") is Some(at_v) else { return None }
  guard str_at(v, "kind") is Some(kind) && (kind == "sync" || kind == "restore") else { return None }
  guard str_at(v, "targetKind") is Some(target_kind) && (target_kind == "station" || target_kind == "s3") else { return None }
  guard str_at(v, "target") is Some(target) else { return None }
  guard str_at(v, "targetName") is Some(target_name) else { return None }
  guard str_at(v, "status") is Some(status) && (status == "ok" || status == "error") else { return None }
  let nonneg_int = (k : String) => match num_at(v, k) {
    Some(n) if n >= 0.0 => n.to_int()
    _ => 0
  }
  let nonneg_num = (k : String) => match num_at(v, k) {
    Some(n) if n >= 0.0 => n.floor()
    _ => 0.0
  }
  let reason = match str_at(v, "reason") {
    Some(r) if is_valid_history_reason(r) => Some(r)
    _ => None
  }
  let error = str_at(v, "error")
  Some({
    id,
    at: at_v,
    kind,
    target_kind,
    target,
    target_name,
    status,
    chats: nonneg_int("chats"),
    messages: nonneg_int("messages"),
    batches: nonneg_int("batches"),
    bytes: nonneg_num("bytes"),
    reason,
    error,
  })
}

///|
fn parse_history_file(v : J?) -> Map[String, Array[BackupRecord]] {
  let out : Map[String, Array[BackupRecord]] = {}
  guard v is Some(root) else { return out }
  guard num_at(root, "v") == Some(1.0) else { return out }
  for e in entries(at(root, "workspaces")) {
    let parsed : Array[BackupRecord] = []
    for item in items(Some(e.1)) {
      match parse_backup_record(item) {
        Some(rec) => parsed.push(rec)
        None => ()
      }
    }
    parsed.sort_by((a, b) => if b.at > a.at { 1 } else if b.at < a.at { -1 } else { 0 })
    while parsed.length() > history_max {
      ignore(parsed.pop())
    }
    if parsed.length() > 0 {
      out[e.0] = parsed
    }
  }
  out
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
  backup : (() -> BackupConfig)?
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
/// Pure pass-scheduling, debounce, and failure-backoff loop for `Copies`, kept free of `Host`/`Fs` so native
/// whitebox tests exercise the exact state machine on `@effect.Runtime`.
priv struct ExportLoop {
  after : (Double, () -> Unit) -> () -> Unit
  go : (async () -> Unit) -> Unit
  run_pass : async (J) -> J
  on_passed : (J) -> Unit
  on_changed : (Double) -> Unit
  on_warn : (String, String, J) -> Unit
  mut told : Told
  mut gathering : (() -> Unit)?
  mut transcript_gathering : (() -> Unit)?
  mut retrying : (() -> Unit)?
  mut want_transcripts : Bool
  mut passing : @effect.Deferred[Unit]?
  mut again : Bool
  mut closed : Bool
  mut export_error : String?
  mut export_tries : Int
}

///|
fn ExportLoop::new(
  after : (Double, () -> Unit) -> () -> Unit,
  go : (async () -> Unit) -> Unit,
  run_pass : async (J) -> J,
  on_passed : (J) -> Unit,
  on_changed : (Double) -> Unit,
  on_warn : (String, String, J) -> Unit,
) -> ExportLoop {
  {
    after,
    go,
    run_pass,
    on_passed,
    on_changed,
    on_warn,
    told: Told::nothing(),
    gathering: None,
    transcript_gathering: None,
    retrying: None,
    want_transcripts: false,
    passing: None,
    again: false,
    closed: false,
    export_error: None,
    export_tries: 0,
  }
}

///|
fn ExportLoop::told(self : ExportLoop, change : J) -> Unit {
  if tell(self.told, change) {
    self.gather()
  }
  match str_at(change, "type") {
    Some("session") | Some("conversation") | Some("sessionRemoved") => self.gather_transcripts()
    _ => ()
  }
}

///|
fn ExportLoop::gather(self : ExportLoop) -> Unit {
  if self.gathering is Some(_) || self.retrying is Some(_) || self.closed {
    return
  }
  // timer: a debounce of a burst of the store's changes
  self.gathering = Some(
    (self.after)(gather_ms, () => {
      self.gathering = None
      (self.go)(async fn() { self.pass() })
    }),
  )
}

///|
fn ExportLoop::gather_transcripts(self : ExportLoop) -> Unit {
  self.want_transcripts = true
  if self.transcript_gathering is Some(_) || self.retrying is Some(_) || self.closed {
    return
  }
  // timer: a debounce of a burst of transcript writes
  self.transcript_gathering = Some(
    (self.after)(transcript_gather_ms, () => {
      self.transcript_gathering = None
      self.want_transcripts = false
      self.told.transcripts = true
      (self.go)(async fn() { self.pass() })
    }),
  )
}

///|
fn ExportLoop::merge(self : ExportLoop, told : Told) -> Unit {
  let t = self.told
  t.sessions.push_iter(told.sessions.iter())
  t.threads.push_iter(told.threads.iter())
  t.removed_sessions.push_iter(told.removed_sessions.iter())
  t.removed_threads.push_iter(told.removed_threads.iter())
  t.marks.push_iter(told.marks.iter())
  if told.transcripts {
    t.transcripts = true
  }
}

///|
async fn ExportLoop::pass(self : ExportLoop) -> Unit {
  if self.passing is Some(_) {
    self.again = true
    return
  }
  let told = self.told
  self.told = Told::nothing()
  self.again = false
  let done : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.passing = Some(done)
  (self.go)(async fn() {
    try {
      let passed = (self.run_pass)(told.to_json())
      call_opt(self.retrying)
      self.retrying = None
      if self.export_error is Some(_) {
        self.export_error = None
        self.export_tries = 0
        (self.on_changed)(0.0)
      } else if num_at(passed, "wrote").unwrap_or(0.0) > 0.0 {
        (self.on_changed)(copies_tell_ms)
      }
      (self.on_passed)(passed)
      if yes_at(passed, "more") {
        self.again = true
      }
    } catch {
      e => {
        (self.on_warn)("copies", "an export failed", jo([("error", js(message_of(e)))]))
        self.merge(told)
        self.again = false
        call_opt(self.gathering)
        self.gathering = None
        call_opt(self.transcript_gathering)
        self.transcript_gathering = None
        if self.export_error is None {
          (self.on_changed)(0.0)
        }
        self.export_error = Some(message_of(e))
        let wait = backoff(copies_retry_ms, self.export_tries, copies_retry_most_ms)
        self.export_tries += 1
        call_opt(self.retrying)
        self.retrying = None
        if !self.closed {
          // timer: a retry after a failure
          self.retrying = Some(
            (self.after)(wait, () => {
              self.retrying = None
              if self.want_transcripts && self.transcript_gathering is None {
                self.gather_transcripts()
              }
              (self.go)(async fn() { self.pass() })
            }),
          )
        }
      }
    }
    self.passing = None
    ignore(done.succeed(()))
    if self.again && !self.closed {
      (self.go)(async fn() { self.pass() })
    }
  })
  done.wait()
}

///|
fn ExportLoop::stop_timers(self : ExportLoop) -> Unit {
  self.closed = true
  call_opt(self.gathering)
  self.gathering = None
  call_opt(self.transcript_gathering)
  self.transcript_gathering = None
  call_opt(self.retrying)
  self.retrying = None
}

///|
async fn ExportLoop::wait_passing(self : ExportLoop) -> Unit {
  match self.passing {
    Some(d) => d.wait()
    None => ()
  }
}

///|
async fn ExportLoop::close(self : ExportLoop, close_runner : async () -> Unit) -> Unit {
  self.stop_timers()
  close_runner() catch {
    _ => ()
  }
  self.wait_passing()
}

///|
pub struct Copies {
  w : World
  d : CopiesDeps
  kept : FolderPlace
  priv mut export_loop : ExportLoop?
  mut closed : Bool
  mut passed : J?
  keeping : Map[String, Keeping]
  formerly : Map[String, Map[String, String]]
  mut handing : Run?
  mut hand_again : (() -> Unit)?
  mut hand_tries : Int
  mut restoring : Restoring?
  old : Map[String, Bool]
  peer_accepts : Map[String, Bool]
  online : Map[String, Bool]
  s3_places : Map[String, (String, S3Place)]
  mut telling : (() -> Unit)?
  history_by_ws : Map[String, Array[BackupRecord]]
  mut history_seq : Int
  mut saving_history : Run?
  mut save_history_again : Bool
  restored : J?
  was : Array[String]
  levelling : Map[String, Run]
  begun : Map[String, (String, Run)]
  looked : Map[String, (Array[J], Double, Bool)]
}

///|
fn Copies::eloop(self : Copies) -> ExportLoop {
  match self.export_loop {
    Some(l) => l
    None => {
      let l = ExportLoop::new(
        (ms, f) => self.w.after(ms, f),
        f => self.w.go(f),
        told => (self.d.runner.pass)(told),
        passed => {
          self.passed = Some(passed)
          for e in entries(at(passed, "heads")) {
            if items(at(e.1, "batches")).length() > 0 {
              self.level_all(e.0)
            }
          }
        },
        ms => self.changed(ms),
        (part, words, fields) => self.w.warn(part, words, fields),
      )
      self.export_loop = Some(l)
      l
    }
  }
}

///|
pub async fn Copies::new(w : World, d : CopiesDeps) -> Copies {
  let restored = w.fs.read_json(outcome_file(w.fs, d.data))
  let history_by_ws = parse_history_file(w.fs.read_json(history_file(w.fs, d.data)))
  {
    w,
    d,
    kept: FolderPlace::new(w.fs, kept_dir(w.fs, d.data)),
    export_loop: None,
    closed: false,
    passed: None,
    keeping: {},
    formerly: {},
    handing: None,
    hand_again: None,
    hand_tries: 0,
    restoring: None,
    old: {},
    peer_accepts: {},
    online: {},
    s3_places: {},
    telling: None,
    history_by_ws,
    history_seq: 0,
    saving_history: None,
    save_history_again: false,
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
  if self.export_loop is Some(l) {
    l.stop_timers()
  }
  call_opt(self.telling)
  for _, k in self.keeping {
    call_opt(k.again)
  }
  call_opt(self.hand_again)
  // Close the export runner BEFORE awaiting an in-flight pass so its close_grace_ms watchdog can terminate a stuck
  // child process and unblock `wait_passing()`.
  (self.d.runner.close)() catch {
    _ => ()
  }
  if self.export_loop is Some(l) {
    l.wait_passing()
  }
  match self.handing {
    Some(r) => r.settled()
    None => ()
  }
  while self.saving_history is Some(r) {
    r.settled()
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
  self.eloop().told(change)
}

///|
/// One pass at a time; what is told meanwhile goes in the next.
async fn Copies::pass(self : Copies) -> Unit {
  self.eloop().pass()
}

///|
/// The export done now, and the places levelled: what a test waits for.
pub async fn Copies::settle(self : Copies) -> Unit {
  let l = self.eloop()
  call_opt(l.gathering)
  l.gathering = None
  call_opt(l.transcript_gathering)
  l.transcript_gathering = None
  if l.want_transcripts {
    l.want_transcripts = false
    l.told.transcripts = true
  }
  self.settle_export()
  while true {
    let busy = self.keeping.values().any(k => k.busy)
    if !busy && self.handing is None && self.saving_history is None {
      break
    }
    for r in self.levelling.values().collect() {
      r.settled()
    }
    match self.handing {
      Some(r) => r.settled()
      None => ()
    }
    match self.saving_history {
      Some(r) => r.settled()
      None => ()
    }
  }
}

///|
/// The export brought to rest.
pub async fn Copies::settle_export(self : Copies) -> Unit {
  let l = self.eloop()
  while true {
    l.pass()
    while l.passing is Some(d) {
      d.wait()
    }
    if !l.again {
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
  let s3_keys : Map[String, Bool] = {}
  for t in self.backup_config().s3 {
    s3_keys["s3:\{t.id}"] = true
  }
  for ws in ins {
    let peer_targets = self.targets(ws)
    for k in self.keeping.keys().collect() {
      let (kw, dest) = split_key(k)
      if kw == ws && !peer_targets.contains(dest) && !s3_keys.contains(dest) {
        match self.keeping.get(k) {
          Some(v) => call_opt(v.again)
          None => ()
        }
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
fn Copies::backup_config(self : Copies) -> BackupConfig {
  match self.d.backup {
    Some(f) => f()
    None => BackupConfig::default()
  }
}

///|
fn s3_sig(t : S3TargetConfig) -> String {
  "\{t.endpoint}\n\{t.region}\n\{t.bucket}\n\{t.prefix}\n\{t.force_path_style}\n\{t.access_key_id}\n\{t.secret_access_key}\n\{t.encryption_key}\n\{t.include_transcripts}"
}

///|
fn Copies::s3_place(self : Copies, t : S3TargetConfig) -> S3Place raise {
  let sig = s3_sig(t)
  match self.s3_places.get(t.id) {
    Some((s, p)) if s == sig => return p
    _ => ()
  }
  let p = S3Place::new(t, self.w)
  self.s3_places[t.id] = (sig, p)
  p
}

///|
/// Called after `config.json`'s `backup` section changes.
pub fn Copies::config_changed(self : Copies) -> Unit {
  let cfg = self.backup_config()
  let s3_by_id : Map[String, S3TargetConfig] = {}
  for t in cfg.s3 {
    s3_by_id[t.id] = t
  }
  for id in self.s3_places.keys().collect() {
    let keep = match (self.s3_places.get(id), s3_by_id.get(id)) {
      (Some((sig, _)), Some(next)) => s3_sig(next) == sig
      _ => false
    }
    if !keep {
      self.s3_places.remove(id)
      let suffix = "\ns3:\{id}"
      for k, v in self.keeping {
        if k.has_suffix(suffix) {
          v.known = None
          v.head = None
          call_opt(v.again)
          v.again = None
        }
      }
    }
  }
  let ins = places_workspaces((self.d.places)()).map(p => p.0)
  let s3_keys : Map[String, Bool] = {}
  for t in cfg.s3 {
    s3_keys["s3:\{t.id}"] = true
  }
  for ws in ins {
    let peer_targets = self.targets(ws)
    for k in self.keeping.keys().collect() {
      let (kw, dest) = split_key(k)
      if kw == ws && !peer_targets.contains(dest) && !s3_keys.contains(dest) {
        match self.keeping.get(k) {
          Some(v) => call_opt(v.again)
          None => ()
        }
        self.keeping.remove(k)
      }
    }
    self.level_all(ws)
    match self.passed {
      Some(p) if yes_at(p, "empty") => self.w.go(async fn() { self.look(ws) })
      _ => ()
    }
  }
  self.hello()
  self.hand_over_soon()
  self.changed(0.0)
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
  let accept_copies = self.backup_config().accept_others
  for p in places_workspaces((self.d.places)()) {
    let ws = p.0
    for s in (self.d.roster)(ws).unwrap_or([]) {
      if s.id == here {
        continue
      }
      let id = s.id
      self.w.go(async fn() {
        let answer = self.w.ask(
          id,
          jo([
            ("method", js("replica.hello")),
            ("workspace", js(ws)),
            ("formerly", jstrs(formerly)),
            ("acceptCopies", jb(accept_copies)),
          ]),
        ) catch {
          e => {
            // (one that answers with a refusal is up but knows no `replica.*`: from before copies)
            if is_refused(e) {
              self.old[id] = true
            } else {
              self.online.remove(id)
            }
            return
          }
        }
        self.old.remove(id)
        self.online[id] = true
        let accepts = match at(answer, "acceptCopies") {
          Some(Bool(false)) => false
          _ => true
        }
        let prev = self.peer_accepts.get(id)
        self.peer_accepts[id] = accepts
        self.heard_formerly(ws, id, strings_of(at(answer, "formerly")))
        if prev != Some(accepts) {
          self.changed(0.0)
          if !accepts && self.backup_config().mode == "auto" {
            self.level_all(ws)
          }
        }
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
pub fn Copies::heard(self : Copies, peer : String, ws : String, formerly : Array[String], accept_copies? : Bool = true) -> Array[String] {
  self.heard_formerly(ws, peer, formerly)
  self.old.remove(peer)
  self.online[peer] = true
  let prev = self.peer_accepts.get(peer)
  self.peer_accepts[peer] = accept_copies
  if prev != Some(accept_copies) {
    self.changed(0.0)
  }
  match self.keeping.get("\{ws}\n\{peer}") {
    Some(k) => k.known = None
    None => ()
  }
  if accept_copies && (self.targets(ws).contains(peer) || (self.backup_config().mode == "auto" && self.keepers_of(ws).contains(peer))) {
    self.level(ws, peer, true, true)
  } else if !accept_copies && self.backup_config().mode == "auto" {
    self.level_all(ws)
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
      hello: (p, ws, formerly, accepts) => self.heard(p, ws, formerly, accept_copies=accepts),
      accept_others: Some(() => self.backup_config().accept_others),
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
  for t in self.backup_config().s3 {
    self.level_s3(ws, t, false, false)
  }
}

///|
/// The stations that should hold this station's copies in `ws` now.
pub fn Copies::targets(self : Copies, ws : String) -> Array[String] {
  guard (self.d.here)() is Some(here) && self.roster_ids(ws) is Some(ids) else { return [] }
  select_backup_targets(ws, here, ids, self.backup_config(), self.peer_accepts, s => match self.keeping.get("\{ws}\n\{s}") {
    Some({ error: Some(_), .. }) => true
    _ => false
  })
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
/// What a place brought level with `head` is said to hold.
fn head_said(head : J) -> String {
  "\{head_gen(head)}:\{num_text(head_to(head))}:\{num_text(head_made(head))}"
}

///|
/// Times a place is brought level again with a newer head where a batch the last named went meanwhile.
let stale_heads_most : Int = 2

///|
/// `go` with `head`; where a file it named is gone (ENOENT: the export compacted its batches into new ones while it
/// went) and a newer head is out, `go` again with that one, at most `stale_heads_most` times, rather than a failure of
/// the place's. The head it went with, and what it found.
async fn level_newest(head : J, newest : () -> J?, go : async (J) -> Levelled) -> (J, Levelled) {
  let mut head = head
  let mut again = 0
  while true {
    let tried : Result[Levelled, Error] = try Ok(go(head)) catch { e => Err(e) }
    match tried {
      Ok(done) => return (head, done)
      Err(e) => {
        guard code_of(e) == "ENOENT" &&
          again < stale_heads_most &&
          newest() is Some(next) &&
          head_batches(next).length() > 0 &&
          head_said(next) != head_said(head) else {
          raise e
        }
        again += 1
        head = next
      }
    }
  }
  panic()
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
  let said = head_said(head)
  if k.known is Some(_) && k.head == Some(said) && k.error is None {
    return
  }
  k.busy = true
  let was_error = k.error
  let prev_reason = k.reason
  let run = self.w.run(async fn() {
    try {
      let place = peer_place(self.w, peer)
      let (head, first) = level_newest(head, () => self.head_of_ws(ws), async fn(h) {
        level(place, ws, self.own(h), known=k.known)
      })
      let mut synced_head = head
      let said = head_said(head)
      let mut done = first
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
        synced_head = next
        done = level(place, ws, self.own(next))
        if done is Behind {
          raise failed("that station keeps more of this station's than it has")
        }
      }
      match done {
        Level(to, missing, known) => {
          let at = self.w.now()
          k.known = Some(known)
          k.head = Some(said)
          k.reason = None
          k.to = to
          k.missing = missing
          k.at = Some(at)
          k.error = None
          k.tries = 0
          self.record(
            ws,
            at,
            "sync",
            "station",
            peer,
            self.peer_name(ws, peer),
            "ok",
            num_at(synced_head, "chats").unwrap_or(0.0).to_int(),
            num_at(synced_head, "messages").unwrap_or(0.0).to_int(),
            head_batches(synced_head).length(),
            num_at(synced_head, "bytes").unwrap_or(0.0),
            None,
            None,
          )
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
        if was_error is None || prev_reason != Some(reason) {
          self.record(
            ws,
            self.w.now(),
            "sync",
            "station",
            peer,
            self.peer_name(ws, peer),
            "error",
            0,
            0,
            0,
            0.0,
            Some(reason),
            k.error,
          )
        }
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
        if was_error is None && self.backup_config().mode == "auto" {
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

///|
fn Copies::level_s3(self : Copies, ws : String, target : S3TargetConfig, now : Bool, fresh : Bool) -> Unit {
  let key = "\{ws}\ns3:\{target.id}"
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
  call_opt(k.again)
  k.again = None
  guard self.head_of_ws(ws) is Some(head) && head_batches(head).length() > 0 else { return }
  if fresh {
    k.known = None
  }
  let said = head_said(head)
  if k.known is Some(_) && k.head == Some(said) && k.error is None {
    return
  }
  k.busy = true
  let was_error = k.error
  let prev_reason = k.reason
  let target_id = target.id
  let target_name = if target.name != "" { target.name } else { target.bucket }
  let run = self.w.run(async fn() {
    try {
      let s3 = self.s3_place(target)
      let place = s3.place()
      let include_transcripts = target.include_transcripts
      let (head, first) = level_newest(head, () => self.head_of_ws(ws), async fn(h) {
        level(place, ws, self.own(h), known=k.known, include_transcripts~)
      })
      let mut synced_head = head
      let said = head_said(head)
      let mut done = first
      if done is Behind {
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
        synced_head = next
        done = level(place, ws, self.own(next), include_transcripts~)
        if done is Behind {
          raise failed("that S3 target keeps more of this station's than it has")
        }
      }
      match done {
        Level(to, missing, known) => {
          let at = self.w.now()
          k.known = Some(known)
          k.head = Some(said)
          k.reason = None
          k.to = to
          k.missing = missing
          k.at = Some(at)
          k.error = None
          k.tries = 0
          self.record(
            ws,
            at,
            "sync",
            "s3",
            target_id,
            target_name,
            "ok",
            num_at(synced_head, "chats").unwrap_or(0.0).to_int(),
            num_at(synced_head, "messages").unwrap_or(0.0).to_int(),
            head_batches(synced_head).length(),
            num_at(synced_head, "bytes").unwrap_or(0.0),
            None,
            None,
          )
        }
        Behind => ()
      }
    } catch {
      e => {
        let reason = if kind_of(e) == "S3HttpError" { "error" } else { "offline" }
        if k.error is None {
          self.w.warn("copies", "an S3 place not brought level", jo([("ws", js(ws)), ("s3", js(target_id)), ("error", js(message_of(e)))]))
        }
        k.error = Some(message_of(e))
        k.reason = Some(reason)
        k.known = None
        if was_error is None || prev_reason != Some(reason) {
          self.record(
            ws,
            self.w.now(),
            "sync",
            "s3",
            target_id,
            target_name,
            "error",
            0,
            0,
            0,
            0.0,
            Some(reason),
            k.error,
          )
        }
        let wait = backoff(copies_retry_ms, k.tries, copies_retry_most_ms)
        k.tries += 1
        if !self.closed {
          // timer: a retry after a failure
          k.again = Some(
            self.w.after(wait, () => {
              k.again = None
              match self.backup_config().s3.search_by(t => t.id == target_id) {
                Some(i) => self.level_s3(ws, self.backup_config().s3[i], true, true)
                None => ()
              }
            }),
          )
        }
      }
    }
    k.busy = false
    self.changed(if k.error == was_error { copies_tell_ms } else { 0.0 })
    self.levelling.remove(key)
    if k.asked && !self.closed {
      k.asked = false
      match self.backup_config().s3.search_by(t => t.id == target_id) {
        Some(i) => self.level_s3(ws, self.backup_config().s3[i], k.error is None, false)
        None => ()
      }
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
      let eligible = if self.backup_config().accept_others {
        ids
      } else {
        ids.filter(s => s != here && self.peer_accepts.get(s) != Some(false))
      }
      let should = keepers(ws, origin, eligible)
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

// ── backup & restore history ──

///|
fn Copies::peer_name(self : Copies, ws : String, peer : String) -> String {
  let roster = (self.d.roster)(ws).unwrap_or([])
  match roster.search_by(m => m.id == peer) {
    Some(i) if roster[i].name != "" => roster[i].name
    _ => if peer.length() > 8 { peer.unsafe_substring(start=0, end=8) } else { peer }
  }
}

///|
fn Copies::s3_target_name(self : Copies, id : String) -> String {
  let s3 = self.backup_config().s3
  match s3.search_by(t => t.id == id) {
    Some(i) => if s3[i].name != "" { s3[i].name } else { s3[i].bucket }
    None => id
  }
}

///|
fn history_payload_json(history_by_ws : Map[String, Array[BackupRecord]]) -> J {
  let ws_entries : Array[(String, J)] = []
  for ws, list in history_by_ws {
    let capped : Array[J] = []
    let n = if list.length() > history_max { history_max } else { list.length() }
    for i in 0..<n {
      capped.push(list[i].to_json())
    }
    ws_entries.push((ws, ja(capped)))
  }
  jo([("v", ji(1)), ("workspaces", jo(ws_entries))])
}

///|
fn append_history_record(
  history_by_ws : Map[String, Array[BackupRecord]],
  seq : Int,
  ws : String,
  at : Double,
  kind : String,
  target_kind : String,
  target : String,
  target_name : String,
  status : String,
  chats : Int,
  messages : Int,
  batches : Int,
  bytes : Double,
  reason : String?,
  error : String?,
) -> BackupRecord {
  let rec : BackupRecord = {
    id: "\{num_text(at.trunc())}-\{seq}",
    at,
    kind,
    target_kind,
    target,
    target_name,
    status,
    chats,
    messages,
    batches,
    bytes,
    reason,
    error,
  }
  let list = match history_by_ws.get(ws) {
    Some(xs) => xs
    None => {
      let xs : Array[BackupRecord] = []
      history_by_ws[ws] = xs
      xs
    }
  }
  let next : Array[BackupRecord] = [rec]
  for item in list {
    next.push(item)
  }
  next.sort_by((a, b) => if b.at > a.at { 1 } else if b.at < a.at { -1 } else { 0 })
  while next.length() > history_max {
    ignore(next.pop())
  }
  history_by_ws[ws] = next
  rec
}

///|
fn Copies::record(
  self : Copies,
  ws : String,
  at : Double,
  kind : String,
  target_kind : String,
  target : String,
  target_name : String,
  status : String,
  chats : Int,
  messages : Int,
  batches : Int,
  bytes : Double,
  reason : String?,
  error : String?,
) -> Unit {
  self.history_seq += 1
  ignore(
    append_history_record(
      self.history_by_ws,
      self.history_seq,
      ws,
      at,
      kind,
      target_kind,
      target,
      target_name,
      status,
      chats,
      messages,
      batches,
      bytes,
      reason,
      error,
    ),
  )
  self.save_history()
}

///|
fn Copies::save_history(self : Copies) -> Unit {
  if self.saving_history is Some(_) {
    self.save_history_again = true
    return
  }
  self.save_history_again = false
  let fs = self.w.fs
  let path = history_file(fs, self.d.data)
  let payload = history_payload_json(self.history_by_ws)
  let run = self.w.run(async fn() {
    try {
      fs.write_json(path, payload)
    } catch {
      e => self.w.warn("copies", "backup history not saved", jo([("error", js(message_of(e)))]))
    }
    self.saving_history = None
    if self.save_history_again {
      self.save_history()
    }
  })
  if !run.is_done() {
    self.saving_history = Some(run)
  }
}

///|
fn restored_record_of(
  restored : J?,
  peer_name : (String) -> String,
  s3_name : (String) -> String,
) -> BackupRecord? {
  guard restored is Some(o) else { return None }
  guard num_at(o, "at") is Some(at_v) else { return None }
  let from = text_at(o, "from")
  let is_s3 = from.has_prefix("s3:")
  let target = if is_s3 { from.unsafe_substring(start=3, end=from.length()) } else { from }
  let target_name = if is_s3 {
    s3_name(target)
  } else if target != "" {
    peer_name(target)
  } else {
    text_at(o, "name")
  }
  let error = str_at(o, "error")
  let reason = match str_at(o, "reason") {
    Some("full") => Some("error")
    Some(r) if is_valid_history_reason(r) => Some(r)
    _ => None
  }
  let rows = at(o, "rows").unwrap_or(Null)
  Some({
    id: "restore-\{num_text(at_v.trunc())}",
    at: at_v,
    kind: "restore",
    target_kind: if is_s3 { "s3" } else { "station" },
    target,
    target_name,
    status: if error is None { "ok" } else { "error" },
    chats: num_at(rows, "sessions").unwrap_or(0.0).to_int(),
    messages: num_at(rows, "entries").unwrap_or(0.0).to_int(),
    batches: 0,
    bytes: 0.0,
    reason,
    error,
  })
}

///|
fn query_history(
  history_by_ws : Map[String, Array[BackupRecord]],
  restored : J?,
  ws : String,
  limit : Int,
  peer_name : (String) -> String,
  s3_name : (String) -> String,
) -> Array[BackupRecord] {
  let n = if limit < 1 { 1 } else if limit > history_max { history_max } else { limit }
  let list = match history_by_ws.get(ws) {
    Some(xs) => xs.copy()
    None => []
  }
  match restored_record_of(restored, peer_name, s3_name) {
    Some(rec) =>
      if !list.iter().any(r => r.kind == "restore" && r.at == rec.at) {
        list.push(rec)
        list.sort_by((a, b) => if b.at > a.at { 1 } else if b.at < a.at { -1 } else { 0 })
      }
    None => ()
  }
  let take = if list.length() < n { list.length() } else { n }
  let out : Array[BackupRecord] = []
  for i in 0..<take {
    out.push(list[i])
  }
  out
}

///|
/// Recent backup & restore records for `ws` (newest first, clamped to 1..50).
pub fn Copies::history(self : Copies, ws : String, limit? : Int = 30) -> Array[BackupRecord] {
  query_history(self.history_by_ws, self.restored, ws, limit, p => self.peer_name(ws, p), id => self.s3_target_name(id))
}

///|
pub fn Copies::history_json(self : Copies, ws : String, limit? : Int = 30) -> J {
  ja(self.history(ws, limit~).map(r => r.to_json()))
}

// ── what the station's settings show ──

///|
/// Sanitized backup configuration & status view for `overview.copies.backup` and `GET /copies/settings`.
pub fn Copies::backup_view(self : Copies, ws : String) -> J {
  let here = (self.d.here)()
  let roster = (self.d.roster)(ws).unwrap_or([])
  let peers : Array[BackupPeerView] = []
  for s in roster {
    if Some(s.id) == here {
      continue
    }
    peers.push({
      station: s.id,
      name: s.name,
      accept_others: self.peer_accepts.get(s.id) != Some(false),
      online: self.online.contains(s.id),
    })
  }
  backup_view_json(self.backup_config(), peers, id => {
    match self.keeping.get("\{ws}\ns3:\{id}") {
      Some(k) => { to: k.to, at: k.at, error: k.error, reason: k.reason }
      None => { to: 0.0, at: None, error: None, reason: None }
    }
  })
}

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
  let stopped = match self.export_loop.bind(l => l.export_error) {
    None => J::Null
    Some(e) => {
      let l = e.to_lower()
      let full = l.contains("enospc") || l.contains("disk is full") || l.contains("database or disk is full")
      let tries = self.export_loop.map(x => x.export_tries).unwrap_or(0)
      jo([("error", js(e)), ("tries", ji(tries)), ("reason", js(if full { "full" } else { "error" }))])
    }
  }
  jo([
    ("to", match head { Some(h) => at(h, "to").unwrap_or(ji(0)); None => ji(0) }),
    ("chats", match head { Some(h) => at(h, "chats").unwrap_or(ji(0)); None => ji(0) }),
    ("keepers", ja(keepers)),
    ("backup", self.backup_view(ws)),
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
  let found : Map[String, (J, Array[(String, J)])] = {}
  let add = (head : J, key : String, item : J) => {
    let origin = text_at(head, "origin")
    if Some(origin) == here {
      return
    }
    match found.get(origin) {
      None => found[origin] = (head, [(key, item)])
      Some((was, froms)) => {
        let newer = gen_made(head_gen(head)) > gen_made(head_gen(was)) ||
          (head_gen(head) == head_gen(was) && head_to(head) > head_to(was))
        if newer {
          found[origin] = (head, [(key, item)])
        } else if head_gen(head) == head_gen(was) && head_to(head) == head_to(was) && !froms.iter().any(p => p.0 == key) {
          froms.push((key, item))
        }
      }
    }
  }
  let roster = (self.d.roster)(ws).unwrap_or([])
  let name_of = (id : String) => match roster.search_by(m => m.id == id) {
    Some(i) => roster[i].name
    None => ""
  }
  let taken : Map[String, Bool] = {}
  for s in self.was {
    taken[s] = true
  }
  let there : Map[String, Bool] = {}
  let accept_copies = self.backup_config().accept_others
  let asks : Array[async () -> Unit] = []
  for s in roster {
    if Some(s.id) == here {
      continue
    }
    let id = s.id
    asks.push(async fn() {
      try {
        let answer = self.w.ask(
          id,
          jo([
            ("method", js("replica.hello")),
            ("workspace", js(ws)),
            ("formerly", jstrs(self.was)),
            ("acceptCopies", jb(accept_copies)),
          ]),
        )
        there[id] = true
        self.online[id] = true
        self.peer_accepts[id] = match at(answer, "acceptCopies") {
          Some(Bool(false)) => false
          _ => true
        }
        let said = strings_of(at(answer, "formerly"))
        self.heard_formerly(ws, id, said)
        for f in said {
          taken[f] = true
        }
        for o in peer_origins(self.w, id, ws) {
          for h in o.1 {
            add(h, "station:\{id}", jo([("station", js(id)), ("name", js(name_of(id)))]))
          }
        }
      } catch {
        _ => ()
      }
    })
  }
  for target in self.backup_config().s3 {
    let t = target
    asks.push(async fn() {
      try {
        let place = self.s3_place(t)
        for o in place.origins(ws) {
          for h in o.1 {
            add(h, "s3:\{t.id}", jo([("s3", js(t.id)), ("name", js(t.name))]))
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
          add(x, "station:\{h}", jo([("station", js(h)), ("name", js(name_of(h)))]))
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
      ("from", ja(from.map(f => f.1))),
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
/// Brings `origin`'s copy (`gen`) here from `from` (a station id, or an S3 target id when `from_s3` is true), then has
/// the station start again to put it in.
pub async fn Copies::restore(
  self : Copies,
  ws : String,
  origin : String,
  gen : String,
  from : String,
  from_s3? : Bool = false,
  merge? : (Array[(String, String)], String?)? = None,
) -> Unit {
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
  let from_label = if from_s3 { "s3:\{from}" } else { from }
  let r : Restoring = {
    origin,
    name: "",
    workspace: ws,
    gen,
    from: from_label,
    done: 0,
    total: 0,
    error: None,
    reason: None,
    restart: false,
  }
  self.restoring = Some(r)
  self.changed(0.0)
  self.bring(r, from, from_s3, merge) catch {
    e => {
      r.error = Some(message_of(e))
      r.reason = Some(
        if kind_of(e) == "NotEmpty" {
          "notEmpty"
        } else if kind_of(e) == "CopyGone" {
          "gone"
        } else if from_s3 {
          if kind_of(e) == "S3HttpError" { "error" } else { "offline" }
        } else {
          self.reason(from, e)
        },
      )
      self.w.warn("copies", "a copy not brought", jo([("origin", js(origin)), ("from", js(r.from)), ("error", jopt(r.error))]))
      self.record(
        ws,
        self.w.now(),
        "restore",
        if from_s3 { "s3" } else { "station" },
        from,
        if from_s3 { self.s3_target_name(from) } else { self.peer_name(ws, from) },
        "error",
        0,
        0,
        0,
        0.0,
        r.reason,
        r.error,
      )
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
async fn Copies::bring(self : Copies, r : Restoring, from : String, from_s3 : Bool, merge : (Array[(String, String)], String?)?) -> Unit {
  let fs = self.w.fs
  let ws = r.workspace
  let origin = r.origin
  let gen = r.gen
  let here = (self.d.here)()
  let (held, stream) : (Held, async (String?, String) -> Body) = if from_s3 {
    let cfg = self.backup_config()
    guard cfg.s3.search_by(t => t.id == from) is Some(i) else {
      raise Thrown("CopyGone", jo([("message", js("S3 target \{from} is not configured"))]))
    }
    let place = self.s3_place(cfg.s3[i])
    (place.held(ws, origin), async fn(g, name) { place.read(ws, origin, g, name) })
  } else if Some(from) == here {
    let place = self.kept
    (place.held(ws, origin), async fn(g, name) { place.stream(ws, origin, g, name) })
  } else {
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
  let names = head_files(head).copy()
  for h in head_transcript_files(head) {
    if held.files.contains(h) && !names.contains(h) {
      names.push(h)
    }
  }
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
