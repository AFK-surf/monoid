// updates.ts: which versions this station and the machine's runtimes (Claude Code, Codex…) are, whether newer ones
// are out, and updating them from the pages:
// - The station: its release says its version in BUILD (`0.1.<n>`); the latest is what still.fail cloud serves as
//   releases/station.json, or on the test channel releases/station-beta.json, only as its signature verifies. Switched
//   back from the beta, the older stable release is offered as going back (`downgrade`), only then. It is updated by
//   the installer this release carries, run apart from the station; only a release the installer put in <data>/app is.
//   With `autoUpdate: true` it does so by itself (never back from the beta). A reported installer failure gets one
//   delayed retry, then waits for a newer release; vault work (holds.mbt) holds both attempts back. With a delta from
//   the build it runs, the station downloads it and applies it first, apart, and hands the installer what it made.
// - The runtimes: `--version`, and the latest their npm packages say (Devin: its installer's manifest); updated the way
//   each was installed. Cursor is no command: its SDK's package in the station's own npm prefix.
// The installer's files: run/update.started (so the process that runs after a handover or restart follows the update
// to its end), run/update.step (download | handoff | drain | restart), run/update.log and run/update.exit.

///|
/// A line of what the pages show (client/core-ts SoftwareVersion; fields that are none are left out).
pub fn software_version(
  id : String,
  name : String,
  installed : Bool,
  version : String?,
  latest : String?,
  newer : Bool,
  downgrade : Bool,
  earlier : Array[String],
  channel : String?,
  auto : Bool?,
  auto_after : String?,
  updatable : Bool,
  repairable : Bool,
  note : String?,
  state : String,
  progress : String?,
  percent : Int?,
  done : String?,
  message : String?,
  checked_at : Double?,
) -> J {
  let fs : Array[(String, J)] = [("id", js(id)), ("name", js(name)), ("installed", jb(installed))]
  let opt = (k : String, v : String?) => match v {
    Some(x) => fs.push((k, js(x)))
    None => ()
  }
  opt("version", version)
  opt("latest", latest)
  fs.push(("newer", jb(newer)))
  fs.push(("downgrade", jb(downgrade)))
  if earlier.length() > 0 {
    fs.push(("earlier", jstrs(earlier)))
  }
  opt("channel", channel)
  match auto {
    Some(a) => fs.push(("auto", jb(a)))
    None => ()
  }
  opt("autoAfter", auto_after)
  fs.push(("updatable", jb(updatable)))
  if repairable {
    fs.push(("repairable", jb(true)))
  }
  opt("note", note)
  fs.push(("state", js(state)))
  opt("progress", progress)
  match percent {
    Some(p) => fs.push(("percent", ji(p)))
    None => ()
  }
  opt("done", done)
  opt("message", message)
  match checked_at {
    Some(c) => fs.push(("checkedAt", jn(c)))
    None => ()
  }
  jo(fs)
}

///|
/// How long things take, given so tests can be quick.
pub(all) struct Timing {
  /// How often the runtimes' latest versions are read again.
  every : Double
  /// How long a runtime's update may take; the station's installer.
  runtime_limit : Double
  station_limit : Double
  /// How long how a station's update went is shown after it ended.
  done_shown : Double
  /// The slow look at an update under way (beside the watch on run/).
  follow_look : Double
  /// How long the station's delta may take before the installer downloads the release.
  delta_limit : Double
}

///|
pub let default_timing : Timing = {
  every: 6.0 * 3600000.0,
  runtime_limit: 10.0 * 60000.0,
  station_limit: 20.0 * 60000.0,
  done_shown: 10.0 * 60000.0,
  follow_look: 5000.0,
  delta_limit: 10.0 * 60000.0,
}

///|
/// A transient handover failure can clear; try once more without repeatedly starting a broken release.
let station_retry_ms : Double = 60000.0

///|
/// The pauses of the retry after a failed update when its release cannot be read or its installer started
/// (`Schedule.min([Schedule.exponential("2 minutes"), Schedule.spaced("15 minutes")])`: the shorter of each).
fn station_retry_backoff(n : Int) -> Double {
  let mut exp = 120000.0
  for _ in 0..<n {
    exp = exp * 2.0
  }
  if exp < 900000.0 {
    exp
  } else {
    900000.0
  }
}

///|
/// The config as the station holds it (ops/config.ts ConfigFile): what it says now, told as it changes; an edit taken
/// at once and told, then written (`config.updateSoon`).
pub(all) struct Config {
  mut raw : J
  listeners : Array[(Int, () -> Unit)]
  mut serial : Int
}

///|
pub fn Config::new(raw : J) -> Config {
  { raw, listeners: [], serial: 0 }
}

///|
pub fn Config::listen(self : Config, f : () -> Unit) -> () -> Unit {
  self.serial += 1
  let id = self.serial
  self.listeners.push((id, f))
  () => match self.listeners.search_by(p => p.0 == id) {
    Some(i) => ignore(self.listeners.remove(i))
    None => ()
  }
}

///|
/// Its config changed (an edit here or in the file): each listener told.
pub fn Config::tell(self : Config) -> Unit {
  for l in self.listeners.copy() {
    (l.1)()
  }
}

///|
pub async fn Config::update_soon(self : Config, w : World, k : String, v : J) -> Unit {
  self.edit_soon(w, [(k, Some(v))])
}

///|
/// Several keys set (`Some`) or deleted (`None`) in one edit, in order.
pub async fn Config::edit_soon(self : Config, w : World, edits : Array[(String, J?)]) -> Unit {
  let mut next = self.raw
  for e in edits {
    next = match e.1 {
      Some(v) => set(next, e.0, v)
      None => del(next, e.0)
    }
  }
  self.raw = next
  self.tell()
  ignore(w.call("config.updateSoon", [next]))
}

///|
pub(all) struct UpdatesOptions {
  /// The release this station runs from (`--app`).
  app : String
  data : String
  config : Config
  /// The still.fail cloud it is in, when it is (cloud.json's origin).
  origin : () -> String?
  /// The station's environment (its PATH finds the runtimes).
  env : Env
  registry : String
  devin_manifest : String
  claude_releases : String
  agy_manifests : String
  node_dist : String
  /// How many turns run now (the hub's).
  running : () -> Double
  /// The station's own release only (a rig runs no runtime).
  station_only : Bool
  timing : Timing
  /// The keys its releases are signed with, by id (none: the station's own).
  trusted : Array[(String, String)]?
  /// The Node this program's release runs on (`process.versions.node`).
  node_version : String
}

///|
priv struct Item {
  mut installed : Bool
  mut version : String?
  mut latest : String?
  mut how : How?
  mut repairable : Bool
  /// Why it cannot be updated from here.
  mut note : Words?
  /// When an update started, while it runs.
  mut updating : Double?
  /// A runtime's, while it updates: where it is.
  mut progress : Words?
  /// The station's, while it updates: the installer's step.
  mut step : String?
  /// While what it downloads comes in: how much of it is (0–100).
  mut percent : Int?
  /// The station's, a while after an update ended well: how it went.
  mut done : Words?
  mut failed : Words?
  /// The station's: the channel whose latest `latest` is.
  mut channel : String?
  /// The station's: the releases before the latest its feed names, verified (earlier_in).
  mut earlier : Array[J]
}

///|
fn empty() -> Item {
  {
    installed: false,
    version: None,
    latest: None,
    how: None,
    repairable: false,
    note: None,
    updating: None,
    progress: None,
    step: None,
    percent: None,
    done: None,
    failed: None,
    channel: None,
    earlier: [],
  }
}

///|
fn Item::copy(self : Item) -> Item {
  { ..self }
}

///|
/// `Object.assign(self, from)`.
fn Item::assign(self : Item, from : Item) -> Unit {
  self.installed = from.installed
  self.version = from.version
  self.latest = from.latest
  self.how = from.how
  self.repairable = from.repairable
  self.note = from.note
  self.updating = from.updating
  self.progress = from.progress
  self.step = from.step
  self.percent = from.percent
  self.done = from.done
  self.failed = from.failed
  self.channel = from.channel
  self.earlier = from.earlier
}

///|
/// What the station's update started from the pages leaves in <data>/run/update.started.
priv struct Started {
  at : Double
  from : String?
}

///|
/// A runtime's install that failed, its words said in each reader's language.
fn failed_words(words : Words) -> Error {
  Thrown("Failed", jo([("message", js(say(words, "en"))), ("words", words.to_j())]))
}

///|
fn Words::of_j(j : J?) -> Words? {
  match j {
    Some(Obj(_)) =>
      match (text(get(j, "key")), text(get(j, "text"))) {
        (Some(k), _) => Some(Key(k, get(j, "args")))
        (_, Some(t)) => Some(Text(t))
        _ => None
      }
    _ => None
  }
}

///|
/// What failed, as the pages say it.
fn failure_words(e : Error) -> Words {
  match kind_of(e) {
    "NotFinished" => Key("station.updates.timedOut", None)
    "Failed" => Words::of_j(field_of(e, "words")).unwrap_or(Text(message_of(e)))
    _ => Text(message_of(e))
  }
}

///|
/// An error whose words are said in the asker's language.
fn refused(lang : String, k : String, args? : Array[(String, J)] = []) -> Error {
  fail(tr(lang, k, args=jo(args)))
}

///|
/// `String(error)`.
fn error_text(e : Error) -> String {
  let name = match field_of(e, "name") {
    Some(Str(u)) => @jsjson.text(u)
    _ =>
      match kind_of(e) {
        "TypeError" | "RangeError" | "SyntaxError" => kind_of(e)
        _ => "Error"
      }
  }
  let m = message_of(e)
  if m == "" {
    name
  } else {
    "\{name}: \{m}"
  }
}

///|
/// One awaited by many (a promise several callers wait on).
priv struct Shared {
  done : @effect.Deferred[Result[Unit, Error]]
}

///|
async fn Shared::wait(self : Shared) -> Unit {
  match self.done.wait() {
    Ok(_) => ()
    Err(e) => raise e
  }
}

///|
fn Shared::new() -> Shared {
  { done: @effect.Deferred::new() }
}

///|
fn Shared::settle(self : Shared, r : Result[Unit, Error]) -> Unit {
  ignore(self.done.succeed(r))
}

///|
/// The station's updates (`Updates`).
pub struct Updates {
  w : World
  app : String
  data : String
  config : Config
  origin : () -> String?
  env : Env
  registry : String
  devin_manifest : String
  claude_releases : String
  agy_manifests : String
  node_dist : String
  timing : Timing
  trusted : Array[(String, String)]?
  node_version_given : String
  /// The channel the running release came from: as it says (CHANNEL), else the channel it started on.
  installed : String
  /// What the running release's CHANNEL says (none: none), read as it is made.
  release : String?
  priv mut node_installing : Shared?
  priv mut node_version : @effect.Deferred[String]?
  priv mut answering : Shared?
  priv items : Map[String, Item]
  priv mut checked_at : Double?
  priv mut checking : Shared?
  priv mut codex_recovery : Shared?
  priv mut codex_update_serial : Int
  priv listeners : Array[(Int, () -> Unit)]
  priv mut listener_serial : Int
  /// The version the station's last update in this process went for.
  mut tried : String?
  priv mut retry_due : String?
  priv mut retried : String?
  priv mut retry_serial : Int
  priv mut last_check : Double?
  mut running : () -> Double
  mut runtime_changed : (String, Bool, Bool) -> Unit
  priv fibers : Fibers
  priv mut closed : Bool
  priv mut started : Bool
  priv mut tick : @effect.Fiber[Unit]?
  priv mut unlisten : (() -> Unit)?
  priv mut unhold : (() -> Unit)?
  priv mut last_setting : String
  priv mut following : (async () -> Unit)?
  priv mut following_id : Int
  priv mut follows : Int
  /// The runtimes whose versions are read (none on a rig).
  kinds : Array[String]
}

///|
/// `new Updates(o)`.
pub async fn Updates::new(w : World, o : UpdatesOptions) -> Updates {
  w.now("CloudTransport.new", [])
  // The Nodes it installed for npm, on its PATH (and what it starts): what they installed is found there.
  let env = o.env.copy()
  remove_own_node_links(w, env, o.data)
  put_own_nodes(w, env, o.data)
  // Read before an update can replace the release.
  let release = release_channel(w, o.app)
  let installed = match release {
    Some(r) => r
    None => channel_from(o.config.raw, None)
  }
  let items : Map[String, Item] = Map([])
  for k in kinds {
    items[k] = empty()
  }
  {
    w,
    app: o.app,
    data: o.data,
    config: o.config,
    origin: o.origin,
    env,
    registry: o.registry,
    devin_manifest: o.devin_manifest,
    claude_releases: o.claude_releases,
    agy_manifests: o.agy_manifests,
    node_dist: o.node_dist,
    timing: o.timing,
    trusted: o.trusted,
    node_version_given: o.node_version,
    installed,
    release,
    node_installing: None,
    node_version: None,
    answering: None,
    items,
    checked_at: None,
    checking: None,
    codex_recovery: None,
    codex_update_serial: 0,
    listeners: [],
    listener_serial: 0,
    tried: None,
    retry_due: None,
    retried: None,
    retry_serial: 0,
    last_check: None,
    running: o.running,
    runtime_changed: (_, _, _) => (),
    fibers: Fibers::new(w, "updates"),
    closed: false,
    started: false,
    tick: None,
    unlisten: None,
    unhold: None,
    last_setting: "",
    following: None,
    following_id: 0,
    follows: 0,
    kinds: if o.station_only { [] } else { runtime_kinds },
  }
}

///|
fn Updates::item(self : Updates, kind : String) -> Item {
  self.items.get(kind).unwrap()
}

///|
/// The cloud's request (its transport where the cloud is still.fail's own, else fetch), as the origin is when asked.
fn Updates::cloud_request(self : Updates) -> Request {
  async fn(url, meth) {
    let via = if (self.origin)() == Some(cloud_origin) { "cloud.fetch" } else { "fetch" }
    self.w.fetch(via, url, meth?)
  }
}

// ---- what is wired in after it is made ----

///|
/// How many turns run now, for what an update waits on when it has to restart the station.
pub fn Updates::count_running(self : Updates, f : () -> Double) -> Unit {
  self.running = f
}

///|
/// What to do when a runtime was installed or updated from here.
pub fn Updates::on_runtime_changed(self : Updates, f : (String, Bool, Bool) -> Unit) -> Unit {
  self.runtime_changed = f
}

///|
/// A runtime a session found not on PATH: read again when the pages still say it is there.
pub fn Updates::missing(self : Updates, kind : String) -> Unit {
  let item = self.item(kind)
  if !item.installed || item.updating is Some(_) {
    return
  }
  self.spawn(async fn() {
    let read = self.read_runtime(kind)
    if self.item(kind).updating is None {
      self.set(kind, i => i.assign(read))
    }
  })
}

///|
/// Hears each change of what `get` says; gives the function that stops it.
pub fn Updates::changes(self : Updates, f : () -> Unit) -> () -> Unit {
  self.listener_serial += 1
  let id = self.listener_serial
  self.listeners.push((id, f))
  () => match self.listeners.search_by(p => p.0 == id) {
    Some(i) => ignore(self.listeners.remove(i))
    None => ()
  }
}

///|
/// The channel the station is updated on now.
pub fn Updates::channel(self : Updates) -> String {
  channel_from(self.config.raw, self.release)
}

///|
/// Whether the station updates itself (`autoUpdate` in its config).
pub fn Updates::auto(self : Updates) -> Bool {
  get(Some(self.config.raw), "autoUpdate") is Some(Bool(true))
}

///|
/// `autoAfter`: the release the station went back from while it updated itself (`autoUpdateAfter`): updating by
/// itself is off until a newer one than it is out, then on again (resume_auto). Only while it is off.
pub fn Updates::auto_after(self : Updates) -> String? {
  match get(Some(self.config.raw), "autoUpdateAfter") {
    Some(Str(u)) if !self.auto() && build_or_none(Some(@jsjson.text(u))) is Some(_) => Some(@jsjson.text(u))
    _ => None
  }
}

///|
/// The build of a station's version (0.<m>.<n>: n), when it is one.
fn build_or_none(version : String?) -> Double? {
  match version {
    Some(v) => {
      let ps = split(v, ".")
      if ps.length() == 3 && ps[0] == "0" && all_digits(ps[1]) && all_digits(ps[2]) {
        let n = decimal(ps[2])
        if is_safe_integer(Some(Num(n))) {
          Some(n)
        } else {
          None
        }
      } else {
        None
      }
    }
    None => None
  }
}

///|
/// The releases the station can go back to now (back_to), as read from the channel it is on.
fn Updates::earlier(self : Updates) -> Array[String] {
  let item = self.item("station")
  if item.channel != Some(self.channel()) {
    return []
  }
  back_to(item.earlier, build_or_none(item.version), platform()).map(release_version)
}

// ---- the life of the part ----

///|
/// Reads them at once and every few hours after; an update of the station started before this process is followed to
/// its end. The config edited elsewhere is heard as it changes.
pub fn Updates::start(self : Updates) -> Unit {
  if self.closed {
    return
  }
  self.last_setting = self.setting()
  self.unlisten = Some(
    self.config.listen(() => {
      let now = self.setting()
      if now == self.last_setting {
        return
      }
      self.last_setting = now
      self.changed()
      self.schedule()
    }),
  )
  // What held an update back let go: one that waited goes ahead.
  self.unhold = Some(
    on_let_go(() => if !self.closed { self.auto_update("what held the update back ended") }),
  )
  self.started = true
  self.spawn(async fn() { self.follow_started() })
  self.schedule()
}

///|
/// Stops what it does on its own (an installer it started goes on).
pub async fn Updates::close(self : Updates) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  match self.unlisten {
    Some(f) => f()
    None => ()
  }
  match self.unhold {
    Some(f) => f()
    None => ()
  }
  match self.following {
    Some(f) => f()
    None => ()
  }
  self.following = None
  ignore(self.w.call("CloudTransport.close", []))
  self.fibers.close()
}

///|
fn Updates::setting(self : Updates) -> String {
  let after = match self.auto_after() {
    Some(a) => a
    None => "null"
  }
  "\{self.channel()} \{self.auto()} \{after}"
}

///|
fn Updates::spawn(self : Updates, f : async () -> Unit) -> Unit {
  if self.closed {
    return
  }
  self.fibers.spawn(f)
}

///|
/// Runs `f` after `ms` in this part's scope; the function returned cancels it.
fn Updates::later(self : Updates, ms : Double, f : async () -> Unit) -> () -> Unit {
  if self.closed {
    return () => ()
  }
  self.fibers.after(ms, f)
}

///|
/// The next look: when the next reading is due.
fn Updates::schedule(self : Updates) -> Unit {
  if self.closed || !self.started {
    return
  }
  match self.tick {
    Some(t) => t.interrupt()
    None => ()
  }
  let due = match self.last_check {
    None => 0.0
    Some(l) => {
      let d = l + self.timing.every - self.fibers.now()
      if d > 0.0 {
        d
      } else {
        0.0
      }
    }
  }
  self.tick = Some(
    self.fibers.fork(async fn() {
      self.fibers.sleep(due)
      self.fibers.promise(async fn() { self.look() })
    }),
  )
}

///|
async fn Updates::look(self : Updates) -> Unit {
  self.tick = None
  (try {
    let every = self.timing.every
    // A reading under way (asked from a page) is waited for. The first reads the station's release too; those after,
    // the runtimes'.
    match (self.checking, self.last_check) {
      (Some(c), _) => c.wait()
      (None, None) => self.check()
      (None, Some(l)) => if self.fibers.now() - l >= every { self.check(station=false) }
    }
    self.auto_update("a newer release read")
  } catch {
    e => {
      // Not read: tried again when the next reading is due, not at once.
      self.last_check = Some(self.fibers.now())
      self.w.warn("updates", "the updates not looked at", fields=jo([("error", js(message_of(e)))]))
    }
  })
  if self.tick is None {
    self.schedule()
  }
}

///|
fn Updates::changed(self : Updates) -> Unit {
  for l in self.listeners.copy() {
    (l.1)()
  }
}

///|
fn Updates::set(self : Updates, kind : String, f : (Item) -> Unit) -> Unit {
  f(self.item(kind))
  self.changed()
}

// ---- what the pages read and ask ----

///|
/// What the pages show, one line each, in `lang`.
pub fn Updates::get(self : Updates, lang : String) -> Array[J] {
  let channel = self.channel()
  kinds.map(kind => {
    let item = self.item(kind)
    let station = kind == "station"
    // Read from another channel than the one it is on now: not yet known.
    let latest = if station && item.channel != Some(channel) { None } else { item.latest }
    let (is_newer, downgrade) = if station {
      offer(item.version, latest, channel, self.installed)
    } else {
      (
        match (item.version, latest) {
          (Some(v), Some(l)) => newer(v, l)
          _ => false
        },
        false,
      )
    }
    // Only where it can be updated from here.
    let here = station && item.note is None && item.version is Some(_)
    let progress = match item.updating {
      None => None
      Some(_) => if station { self.progress_of(item.step) } else { item.progress }
    }
    software_version(
      kind,
      kind_name(kind),
      item.installed,
      item.version,
      latest,
      is_newer,
      downgrade,
      if here && station { self.earlier() } else { [] },
      if here { Some(channel) } else { None },
      if here { Some(self.auto()) } else { None },
      if here { self.auto_after() } else { None },
      item.how is Some(_) || here,
      item.repairable,
      item.note.map(n => say(n, lang)),
      if item.updating is Some(_) {
        "updating"
      } else if item.failed is Some(_) {
        "failed"
      } else {
        "idle"
      },
      progress.map(p => say(p, lang)),
      if item.updating is Some(_) { item.percent } else { None },
      item.done.map(d => say(d, lang)),
      item.failed.map(f => say(f, lang)),
      self.checked_at,
    )
  })
}

///|
/// Reads every version and what is out, now (once at a time: asked while a reading goes on, it is that reading); a
/// newer release of the station's channel is installed when it updates itself.
pub async fn Updates::check(self : Updates, station? : Bool = true) -> Unit {
  if self.checking is Some(_) {
    return
  }
  self.w.now("shellPath.forgetShellPaths", [])
  let shared = Shared::new()
  self.checking = Some(shared)
  let r : Result[Unit, Error] = try {
    self.read(station)
    Ok(())
  } catch {
    e => Err(e)
  }
  self.checking = None
  shared.settle(r)
  match r {
    Ok(_) => ()
    Err(e) => raise e
  }
}

///|
async fn Updates::read(self : Updates, with_station : Bool) -> Unit {
  let held = self.item("station")
  let reads : Array[async () -> Item] = [
    if with_station {
      let channel = self.channel()
      async fn() { self.read_station(channel) }
    } else {
      fn() { held }
    },
  ]
  for k in self.kinds {
    reads.push(async fn() { self.read_runtime(k) })
  }
  let got = @effect.all(reads)
  let mut station = got[0]
  // Put on another channel while it was read: read from that one.
  while station.channel != Some(self.channel()) {
    station = self.read_station(self.channel())
  }
  let all = [("station", station)]
  for i, k in self.kinds {
    all.push((k, got[i + 1]))
  }
  for p in all {
    let (kind, read) = p
    let item = self.item(kind)
    // One that is updating keeps what it was until it is done; but one not yet read is read.
    if item.updating is None {
      let next = read.copy()
      next.failed = item.failed
      next.done = item.done
      self.items[kind] = next
    } else if !item.installed {
      let next = read.copy()
      next.updating = item.updating
      next.progress = item.progress
      next.step = item.step
      next.percent = item.percent
      self.items[kind] = next
    }
  }
  self.checked_at = Some(self.fibers.now())
  self.last_check = Some(self.fibers.now())
  self.changed()
  self.resume_auto()
  self.auto_update("a newer release out")
  self.schedule()
}

///|
async fn Updates::read_station(self : Updates, channel : String) -> Item {
  let w = self.w
  let version = station_version_soon(w, self.app)
  let app = w.realpath_or_null(self.app)
  let mut note : Words? = if app is Some(a) && w.realpath_or_null(pjoin([self.data, "app"])) == Some(a) {
    None
  } else if includes(self.app, ".app/Contents") {
    Some(Key("station.updates.withDesktop", None))
  } else {
    Some(Key("station.updates.notInstaller", None))
  }
  let origin = match (self.origin)() {
    Some(o) if o != "" => Some(o)
    _ => None
  }
  if note is None && origin is None {
    note = Some(Key("station.updates.notJoined", None))
  }
  let mut latest : String? = None
  let mut earlier : Array[J] = []
  match origin {
    Some(o) =>
      (try {
        let said = read_feed(w, channel, o, self.cloud_request())
        // Only a release whose words verify is one.
        let (release, why) = verified_or_null(w, said, self.trusted)
        if release is None {
          w.warn(
            "updates",
            "the station's latest release does not verify: not offered",
            fields=jo([("channel", js(channel)), ("why", jopt(why))]),
          )
        }
        latest = release.map(release_version)
        let (before, why_before) = earlier_in(w, said, self.trusted)
        if why_before.length() > 0 {
          w.warn(
            "updates",
            "releases before the latest do not verify: not offered",
            fields=jo([("channel", js(channel)), ("why", jstrs(why_before))]),
          )
        }
        earlier = before
      } catch {
        e =>
          w.warn("updates", "the station's latest release not read", fields=jo([("error", js(message_of(e)))]))
      })
    None => ()
  }
  let i = empty()
  i.installed = true
  i.version = version
  i.latest = latest
  i.note = note
  i.channel = Some(channel)
  i.earlier = earlier
  i
}

///|
/// `fetchJson(url)`.
async fn Updates::fetch_json(self : Updates, url : String) -> J {
  let response = self.w.fetch("fetch", url)
  if !response.ok() {
    raise fail("\{url}: \{response.status}")
  }
  response.json(self.w)
}

///|
/// `fetchText(url)`.
async fn Updates::fetch_text(self : Updates, url : String) -> String {
  let response = self.w.fetch("fetch", url)
  if !response.ok() {
    raise fail("\{url}: \{response.status}")
  }
  response.text()
}

///|
fn how_or(h : HowOr) -> (How?, Words?) {
  match h {
    Can(how) => (Some(how), None)
    Cannot(u) => (None, Some(Key(u.key, Some(u.args))))
  }
}

///|
async fn Updates::read_runtime(self : Updates, kind : String) -> Item {
  let w = self.w
  if kind == "cursor" {
    return self.read_cursor()
  }
  let env = with_shell_command(w, kind_command(kind), self.env)
  let found = find_command_soon(w, kind_command(kind), env)
  let mut version : String? = None
  match found {
    Some(f) =>
      (try {
        let (ok, out) = run(w, f.on_path, ["--version"], env, 20000.0)
        if ok {
          version = version_in(out)
        }
      } catch {
        _ => ()
      })
    None => ()
  }
  let mut latest : String? = None
  let i = empty()
  i.installed = found is Some(_)
  i.version = version
  if kind == "hermes" {
    i.note = Some(Key("station.updates.hermesExternal", None))
    return i
  }
  // The Antigravity CLI says no latest version but to itself (`agy update`, which gets it).
  if kind == "agy" {
    let h = match found {
      Some(f) => how_to_update_soon(w, kind, f, env)
      None => how_to_install_soon(w, kind, self.env, None)
    }
    i.how = match h {
      Can(how) => Some(how)
      Cannot(_) => None
    }
    return i
  }
  (try {
    // Devin's builds are its installer's, said in its manifest; the others' npm packages.
    let said = self.fetch_json(
      if kind == "devin" {
        self.devin_manifest
      } else {
        "\{self.registry}/\{kind_package(kind)}/latest"
      },
    )
    latest = text(get(Some(said), "version"))
  } catch {
    e =>
      w.warn(
        "updates",
        "the runtime's latest version not read",
        fields=jo([("runtime", js(kind)), ("error", js(message_of(e)))]),
      )
  })
  let missing = match (kind, found, version) {
    ("codex", Some(f), Some(_)) => missing_codex_host(w, f, env)
    _ => None
  }
  let npm_env = if missing is Some(_) { with_shell_command(w, "npm", env) } else { env }
  let npm = if missing is Some(_) {
    Some(
      npm_install_soon(
        w,
        npm_env,
        self.own_node_soon(),
        ["install", "-g", "@openai/codex@latest"],
        kind_name("codex"),
      ),
    )
  } else {
    None
  }
  let repairable = match (missing, found, npm) {
    (Some(_), Some(f), Some(Can(_))) => can_switch_codex_soon(w, f, env)
    _ => false
  }
  let how : HowOr? = if missing is Some(_) {
    None
  } else {
    match found {
      Some(f) => Some(how_to_update_soon(w, kind, f, env))
      None => Some(how_to_install_soon(w, kind, self.env, self.own_node_soon()))
    }
  }
  i.latest = latest
  i.repairable = repairable
  match missing {
    Some(m) =>
      i.note = Some(
        Key(
          if repairable {
            "station.updates.codexMissingHostRepair"
          } else {
            "station.updates.codexMissingHost"
          },
          Some(jo([("path", js(m.helper))])),
        ),
      )
    None =>
      match how {
        Some(h) => {
          let (hw, note) = how_or(h)
          i.how = hw
          i.note = note
        }
        None => ()
      }
  }
  i
}

///|
/// The Node npm is installed with where the machine has none: the version the station runs on (its release's
/// NODE_VERSION, read once).
async fn Updates::own_node_soon(self : Updates) -> OwnNode? {
  let d = match self.node_version {
    Some(d) => d
    None => {
      let d : @effect.Deferred[String] = @effect.Deferred::new()
      self.node_version = Some(d)
      let v = match self.w.read_text_or_null(pjoin([self.app, "NODE_VERSION"])) {
        Some(t) if trim(t) != "" => trim(t)
        _ => self.node_version_given
      }
      ignore(d.succeed(v))
      d
    }
  }
  own_node(self.w, self.data, d.wait())
}

///|
/// Cursor's SDK, a package npm keeps in the station's own prefix: installed and updated by the same npm install there.
async fn Updates::read_cursor(self : Updates) -> Item {
  let w = self.w
  let version = text(Some(w.call("cursor.sdkVersionSoon", [js(self.data)])))
  let mut latest : String? = None
  (try {
    let said = self.fetch_json("\{self.registry}/\{kind_package("cursor")}/latest")
    latest = text(get(Some(said), "version"))
  } catch {
    e =>
      w.warn(
        "updates",
        "the runtime's latest version not read",
        fields=jo([("runtime", js("cursor")), ("error", js(message_of(e)))]),
      )
  })
  let node = self.own_node_soon()
  let h = npm_install_soon(
    w,
    self.env,
    node,
    ["install", "-g", "--prefix", pjoin([self.data, "runtimes", "cursor"]), "@cursor/sdk@latest"],
    kind_name("cursor"),
  )
  let i = empty()
  i.installed = version is Some(_)
  i.version = version
  i.latest = latest
  let (hw, note) = how_or(h)
  i.how = hw
  i.note = note
  i
}

///|
/// Turns updating by itself on or off: kept in its config; turned on, what is out is read at once.
pub async fn Updates::set_auto(self : Updates, on : Bool, lang : String) -> Unit {
  self.refuse_station_note(lang)
  if self.auto() != on || get(Some(self.config.raw), "autoUpdateAfter") is Some(_) {
    self.config.edit_soon(self.w, [("autoUpdate", Some(jb(on))), ("autoUpdateAfter", None)])
    self.last_setting = self.setting()
    self.w.info("updates", "the station's updating by itself set", fields=jo([("on", jb(on))]))
    self.changed()
  }
  if on {
    self.check()
  }
  self.schedule()
}

///|
/// Puts the station on `channel`: kept in its config, and what is out read again from that channel.
pub async fn Updates::set_channel(self : Updates, channel : String, lang : String) -> Unit {
  self.refuse_station_note(lang)
  self.keep_channel(channel)
  self.check()
}

///|
/// Keeps `channel` in the config, when it is another one than now.
pub async fn Updates::keep_channel(self : Updates, channel : String) -> Unit {
  if self.channel() == channel {
    return
  }
  self.config.update_soon(self.w, "updateChannel", js(channel))
  self.last_setting = self.setting()
  self.w.info("updates", "the station's update channel set", fields=jo([("channel", js(channel))]))
  self.changed()
}

///|
/// `stillfail-station channel <name>` asked the running station: takes the channel in run/channel-ask, keeps it, reads
/// what is out on it, and answers in run/channel-answer. Asks heard while one is answered wait for it.
pub async fn Updates::answer_channel_ask(self : Updates) -> Unit {
  let before = self.answering
  let mine = Shared::new()
  self.answering = Some(mine)
  match before {
    Some(b) => b.wait() catch { _ => () }
    None => ()
  }
  let r : Result[Unit, Error] = try {
    answer_channel_ask(self.w, pjoin([self.data, "run"]), async fn(channel) {
      self.keep_channel(channel)
      self.spawn(async fn() { self.check() })
    })
    Ok(())
  } catch {
    e => Err(e)
  }
  mine.settle(Ok(()))
  match r {
    Ok(_) => ()
    Err(e) => raise e
  }
}

///|
fn Updates::refuse_station_note(self : Updates, lang : String) -> Unit raise {
  match self.item("station").note {
    Some(note) =>
      raise refused(lang, "station.list.labeled", args=[
        ("name", js(kind_name("station"))),
        ("note", js(say(note, lang))),
      ])
    None => ()
  }
}

// ---- updating by itself ----

///|
/// The runtime being installed or updated now, when one is.
fn Updates::runtime_updating(self : Updates) -> String? {
  for k in runtime_kinds {
    if self.item(k).updating is Some(_) {
      return Some(k)
    }
  }
  None
}

///|
/// The version the station updates itself to now, when it does: it updates itself, can be updated from here, is not
/// updating, and its channel's latest is newer and not one it already went for, unless that failure's retry is due.
pub fn Updates::to_update_to(self : Updates) -> String? {
  if !self.auto() || holding() > 0 {
    return None
  }
  let item = self.item("station")
  if item.note is Some(_) ||
    item.updating is Some(_) ||
    item.channel != Some(self.channel()) ||
    self.runtime_updating() is Some(_) {
    return None
  }
  guard item.latest is Some(latest) else { return None }
  let (is_newer, _) = offer(item.version, item.latest, self.channel(), self.installed)
  if is_newer && (self.tried != Some(latest) || self.retry_due == Some(latest)) {
    Some(latest)
  } else {
    None
  }
}

///|
async fn Updates::resume_auto(self : Updates) -> Unit {
  guard self.auto_after() is Some(after) else { return }
  let item = self.item("station")
  guard item.channel == Some(self.channel()) && item.latest is Some(latest) else { return }
  match (build_or_none(Some(latest)), build_or_none(Some(after))) {
    (Some(l), Some(left)) if l > left => ()
    _ => return
  }
  self.config.edit_soon(self.w, [("autoUpdate", Some(jb(true))), ("autoUpdateAfter", None)])
  self.last_setting = self.setting()
  self.w.info(
    "updates",
    "a release newer than the one gone back from is out: the station updates itself again",
    fields=jo([("left", js(after)), ("latest", js(latest))]),
  )
  self.changed()
}

///|
/// Updating by itself turned on again if the latest read is past the release gone back from (tests).
pub async fn Updates::resume_auto_for_tests(self : Updates) -> Unit {
  self.resume_auto()
}

///|
fn Updates::auto_update(self : Updates, why : String) -> Unit {
  guard self.to_update_to() is Some(to) else { return }
  self.w.info("updates", "\{why}: the station updates itself", fields=jo([("to", js(to))]))
  let not_by_itself = (e : Error) => self.w.warn(
    "updates",
    "the station not updated by itself",
    fields=jo([("error", js(message_of(e)))]),
  )
  match (try Ok(self.update_station_begin(station_lang())) catch { e => Err(e) }) {
    Ok(begun) =>
      self.w.go(async fn() {
        self.update_station_rest(station_lang(), begun) catch {
          e => not_by_itself(e)
        }
      })
    Err(e) => not_by_itself(e)
  }
}

///|
/// Retry one failed installer, rereading the signed feed with backoff if it or the installer's plan is unavailable.
fn Updates::retry_station(self : Updates, version : String) -> Unit {
  self.retry_serial += 1
  let serial = self.retry_serial
  let over = () => self.closed ||
    serial != self.retry_serial ||
    self.tried != Some(version) ||
    self.retried == Some(version)
  let attempt = async fn() -> Bool {
    let mut done = false
    self.fibers.promise(async fn() {
      if over() {
        done = true
        return
      }
      self.retry_due = Some(version)
      if self.auto() {
        (try {
          // A runtime-only reading may already be in flight; wait for it, then read the station's feed too.
          match self.checking {
            Some(c) => c.wait() catch { _ => () }
            None => ()
          }
          if over() {
            done = true
            return
          }
          self.check()
          if !over() {
            self.auto_update("retrying a failed update")
          }
        } catch {
          e =>
            self.w.warn(
              "updates",
              "the failed update's release not read",
              fields=jo([("error", js(message_of(e)))]),
            )
        })
      }
      done = over()
    })
    done
  }
  // timer: retry after a failed update, then back off if the release cannot be read or its installer started.
  ignore(
    self.fibers.fork(async fn() {
      self.fibers.sleep(station_retry_ms)
      let mut n = 0
      while !attempt() {
        self.fibers.sleep(station_retry_backoff(n))
        n += 1
      }
    }),
  )
}

// ---- updating ----

///|
/// Updates one (`station`, `claude`, `codex`, `dsh`…), or installs a runtime the machine has not: answers once it has
/// started; how it goes shows in `get`. Refusals are said in `lang`.
pub async fn Updates::update(self : Updates, id : String, lang : String, to? : String) -> Unit {
  if self.closed {
    raise fail("updates are closed")
  }
  guard kinds.contains(id) else { raise refused(lang, "station.updates.noSuchItem", args=[("id", js(id))]) }
  if to is Some(_) && id != "station" {
    raise refused(lang, "station.updates.backStationOnly")
  }
  let kind = id
  let item = self.item(kind)
  let name = kind_name(kind)
  if item.updating is Some(_) {
    raise refused(lang, "station.updates.alreadyUpdating", args=[("name", js(name))])
  }
  match item.note {
    Some(note) =>
      raise refused(lang, "station.list.labeled", args=[("name", js(name)), ("note", js(say(note, lang)))])
    None => ()
  }
  if kind == "station" {
    match self.runtime_updating() {
      Some(r) => raise refused(lang, "station.updates.runtimeBusy", args=[("name", js(kind_name(r)))])
      None => ()
    }
    let begun = self.update_station_begin(lang)
    return match to {
      None => self.update_station_rest(lang, begun)
      Some(to) => self.back_station(to, lang, begun)
    }
  }
  if self.item("station").updating is Some(_) {
    raise refused(
      lang,
      if item.installed {
        "station.updates.stationBusyUpdate"
      } else {
        "station.updates.stationBusyInstall"
      },
      args=[("name", js(name))],
    )
  }
  guard item.how is Some(how) else { raise refused(lang, "station.updates.notHere", args=[("name", js(name))]) }
  if kind == "codex" {
    self.codex_update_serial += 1
  }
  self.set(kind, i => {
    i.updating = Some(self.fibers.now())
    i.progress = None
    i.percent = None
    i.failed = None
    i.done = None
  })
  self.spawn(async fn() { self.update_runtime(kind, how) })
}

///|
/// Updates the same installation and through the same path as the software page, or joins its update.
pub async fn Updates::update_old_codex(self : Updates, running_version : String?, lang : String) -> Unit {
  let work = match self.codex_recovery {
    Some(w) => {
      w.wait()
      w
    }
    None => {
      let shared = Shared::new()
      self.codex_recovery = Some(shared)
      let r : Result[Unit, Error] = try {
        self.update_old_codex_once(running_version, lang)
        Ok(())
      } catch {
        e => Err(e)
      }
      if self.codex_recovery is Some(c) && physical_equal(c, shared) {
        self.codex_recovery = None
      }
      shared.settle(r)
      match r {
        Ok(_) => shared
        Err(e) => raise e
      }
    }
  }
  ignore(work)
  guard self.item("codex").version is Some(actual) else {
    raise refused(lang, "station.notice.codexVersionUnknown")
  }
  match running_version {
    Some(r) if !newer(r, actual) => raise refused(lang, "station.notice.codexNoNewVersion")
    _ => ()
  }
}

///|
async fn Updates::update_old_codex_once(self : Updates, running_version : String?, lang : String) -> Unit {
  if self.item("codex").updating is Some(_) {
    return self.wait_for_codex_update(lang)
  }
  // The page's last check may be hours old. Do not overwrite an update that starts while this reading is in flight.
  let serial = self.codex_update_serial
  let read = self.read_runtime("codex")
  if self.item("codex").updating is Some(_) {
    return self.wait_for_codex_update(lang)
  }
  if serial == self.codex_update_serial {
    self.set("codex", i => i.assign(read))
  }
  let item = self.item("codex")
  if !item.installed {
    raise refused(lang, "station.updates.notHere", args=[("name", js("Codex"))])
  }
  match item.note {
    Some(n) => raise fail(say(n, lang))
    None => ()
  }
  match (running_version, item.version) {
    (Some(r), Some(v)) if newer(r, v) => return
    _ => ()
  }
  let before = item.version
  self.update("codex", lang)
  self.wait_for_codex_update(lang)
  guard self.item("codex").version is Some(after) else {
    raise refused(lang, "station.notice.codexVersionUnknown")
  }
  match before {
    Some(b) if !newer(b, after) => raise refused(lang, "station.notice.codexNoNewVersion")
    _ => ()
  }
}

///|
async fn Updates::wait_for_codex_update(self : Updates, lang : String) -> Unit {
  let d : @effect.Deferred[Result[Unit, Error]] = @effect.Deferred::new()
  let unlisten : Ref[() -> Unit] = Ref(() => ())
  let inspect = () => {
    let item = self.item("codex")
    if item.updating is Some(_) {
      return
    }
    (unlisten.val)()
    match item.failed {
      Some(f) => ignore(d.succeed(Err(fail(say(f, lang)))))
      None => ignore(d.succeed(Ok(())))
    }
  }
  unlisten.val = self.changes(inspect)
  inspect()
  match d.wait() {
    Ok(_) => ()
    Err(e) => raise e
  }
}

///|
/// A person chose to replace an incomplete Codex with an npm installation, the old entry kept.
pub async fn Updates::repair_codex(self : Updates, lang : String) -> Unit {
  let w = self.w
  let item = self.item("codex")
  if item.updating is Some(_) {
    raise refused(lang, "station.updates.alreadyUpdating", args=[("name", js("Codex"))])
  }
  if self.item("station").updating is Some(_) {
    raise refused(lang, "station.updates.stationBusyUpdate", args=[("name", js("Codex"))])
  }
  // Reserve the runtime before probing.
  self.set("codex", i => {
    i.updating = Some(self.fibers.now())
    i.progress = None
    i.percent = None
    i.failed = None
    i.done = None
  })
  let r : Result[Unit, Error] = try {
    let env = with_shell_command(w, "codex", self.env)
    let found = find_command_soon(w, "codex", env)
    let usable = match found {
      Some(f) if item.repairable =>
        can_switch_codex_soon(w, f, env) && missing_codex_host(w, f, env) is Some(_)
      _ => false
    }
    if !usable {
      raise refused(lang, "station.updates.codexRepairUnavailable")
    }
    let captured = match capture_codex_soon(w, found.unwrap(), env) {
      Some(c) => c
      None => raise refused(lang, "station.updates.codexRepairUnavailable")
    }
    let npm_env = with_shell_command(w, "npm", env)
    let prefix = pjoin([self.data, "runtimes", "codex", "npm-\{random_hex(w, 8)}"])
    let how = match
      npm_install_soon(
        w,
        npm_env,
        self.own_node_soon(),
        ["install", "-g", "--prefix", prefix, "@openai/codex@latest"],
        "Codex",
      ) {
      Can(h) => h
      Cannot(u) => raise fail(u.say(lang))
    }
    self.spawn(async fn() { self.repair_codex_in_background(captured, how, prefix, npm_env) })
    Ok(())
  } catch {
    e => Err(e)
  }
  match r {
    Ok(_) => ()
    Err(e) => {
      self.set("codex", i => i.updating = None)
      raise e
    }
  }
}

///|
async fn Updates::repair_codex_in_background(
  self : Updates,
  captured : CodexEntry,
  how : How,
  prefix : String,
  npm_env : Env,
) -> Unit {
  let w = self.w
  let found = captured.found
  let launcher = pjoin([prefix, "bin", "codex"])
  let mut backup : String? = None
  let mut failure : Words? = None
  let mut keep_prefix = false
  (try {
    let (ok, said, _) = self.install("codex", how, given_env=npm_env)
    if !ok {
      raise fail(tail(said, station_lang()))
    }
    let new_found : Found = { on_path: launcher, real: w.realpath(launcher) }
    let binary = codex_binary_soon(w, new_found)
    let env = match how.node {
      Some(n) => prepend_path(npm_env, n.bin)
      None => npm_env
    }
    let (runs, output) = run(w, launcher, ["--version"], env, 20000.0)
    let host_runs = match binary {
      Some(b) if has_codex_host_soon(w, b) =>
        run(w, pjoin([pdirname(b), exe("codex-code-mode-host")]), ["--help"], env, 20000.0).0
      _ => false
    }
    if !runs || version_in(output) is None || !host_runs {
      raise failed_words(Key("station.updates.codexRepairIncomplete", None))
    }
    // (the switch's checks and renames one step, as they must be)
    backup = Some(switch_codex(w, captured, launcher, env))
    let actual_env = with_shell_command(w, "codex", self.env)
    let actual = find_command_soon(w, "codex", actual_env)
    if !(actual is Some(a) && a.real == new_found.real) {
      raise failed_words(Key("station.updates.codexRepairNotOnPath", None))
    }
    keep_prefix = true
  } catch {
    e => {
      failure = Some(failure_words(e))
      match backup {
        Some(b) =>
          (try {
            restore_codex(w, found.on_path, launcher, b)
            backup = None
          } catch {
            restore_error => {
              keep_prefix = true
              failure = Some(Text("\{say(failure.unwrap(), station_lang())}; \{message_of(restore_error)}"))
            }
          })
        None => ()
      }
    }
  })
  if !keep_prefix {
    w.rm(prefix, recursive=true) catch {
      error =>
        w.warn(
          "updates",
          "the unused Codex repair not removed",
          fields=jo([("prefix", js(prefix)), ("error", js(error_text(error)))]),
        )
    }
  }
  // Retire the old app-servers as soon as the switch succeeds.
  if failure is None {
    (self.runtime_changed)("codex", true, true)
  }
  let read = self.read_runtime("codex")
  self.set("codex", i => {
    i.assign(read)
    i.failed = failure
    i.done = match (failure, backup) {
      (None, Some(b)) if b != "" => Some(Key("station.updates.codexRepaired", Some(jo([("path", js(b))]))))
      _ => None
    }
  })
  if failure is Some(_) {
    (self.runtime_changed)("codex", read.installed, false)
  }
  self.auto_update("a newer release out, waited for a runtime")
}

///|
async fn Updates::update_runtime(self : Updates, kind : String, how : How) -> Unit {
  let w = self.w
  w.info(
    "updates",
    "updating or installing a runtime",
    fields=jo([("runtime", js(kind)), ("program", js(how.program)), ("args", jstrs(how.args))]),
  )
  let mut failed : Words? = None
  (try {
    let (ok, said, code) = self.install(kind, how)
    // Its package manager has nothing newer to apply yet: said as that, with what it said.
    if !ok && how.no_update is Some(n) && code == Some(n) {
      failed = Some(
        Key(
          "station.updates.noApplicableUpdate",
          Some(jo([("program", js(parse_name(how.program))), ("said", js(tail(said, station_lang())))])),
        ),
      )
    } else if !ok {
      failed = Some(Text(tail(said, station_lang())))
    }
  } catch {
    e => failed = Some(failure_words(e))
  })
  match failed {
    Some(f) =>
      w.warn("updates", "the runtime not updated", fields=jo([("runtime", js(kind)), ("failed", js(say(f, "en")))]))
    None => ()
  }
  let without_reading = (error : Error, f : Words?) => {
    self.set(kind, item => {
      item.updating = None
      item.progress = None
      item.percent = None
      item.failed = Some(f.unwrap_or(Text(message_of(error))))
    })
    self.auto_update("a runtime update ended without a version reading")
  }
  let mut read = match (try Ok(self.read_runtime(kind)) catch { e => Err(e) }) {
    Ok(r) => r
    Err(error) => {
      without_reading(error, failed)
      return
    }
  }
  if failed is None &&
    !read.installed &&
    (try link_beside_npm(w, kind, how, self.env) catch { _ => false }) {
    w.info(
      "updates",
      "the runtime npm installed off PATH linked beside npm",
      fields=jo([("runtime", js(kind)), ("npm", js(how.program))]),
    )
    read = match (try Ok(self.read_runtime(kind)) catch { e => Err(e) }) {
      Ok(r) => r
      Err(error) => {
        without_reading(error, None)
        return
      }
    }
  }
  // Done without an error but not there, or not newer: installed somewhere the station's PATH does not find.
  if failed is None {
    if !read.installed {
      failed = Some(
        Key(
          "station.updates.notOnPath",
          Some(jo([("program", js(how.program)), ("command", js(kind_command(kind)))])),
        ),
      )
    } else {
      match (read.version, read.latest) {
        (Some(v), Some(l)) if newer(v, l) =>
          failed = Some(
            Key(
              "station.updates.notNewer",
              Some(
                jo([
                  ("program", js(how.program)),
                  ("command", js(kind_command(kind))),
                  ("version", js(v)),
                  ("latest", js(l)),
                ]),
              ),
            ),
          )
        _ => ()
      }
    }
  }
  let f = failed
  self.set(kind, i => {
    i.assign(read)
    i.failed = f
  })
  (self.runtime_changed)(kind, read.installed, false)
  // The station's own update waited for this one.
  self.auto_update("a newer release out, waited for a runtime")
}

///|
/// `parse(program).name`: its file's name without its extension.
fn parse_name(program : String) -> String {
  let base = pbasename(program)
  let dot = last_index_of(base, ".")
  if dot > 0 {
    slice(base, 0, end=dot)
  } else {
    base
  }
}

///|
/// Runs `how`, saying where it is as it goes: a download that can be measured, by how much of it is in, else the step
/// the command says it is at.
async fn Updates::install(self : Updates, kind : String, given : How, given_env? : Env) -> (Bool, String, Double?) {
  let w = self.w
  match given.node {
    Some(n) => self.install_node(kind, n)
    None => ()
  }
  let runtime_env = match given_env {
    Some(e) => e
    None => with_shell_command(w, kind_command(kind), self.env)
  }
  let mut how = given
  if kind == "codex" && is_npm_install(how) {
    // That version, as npm's cache has its build.
    match self.fetch_codex(how.program, runtime_env) {
      Some(version) => how = pin_npm_version(how, kind_package(kind), version)
      None => ()
    }
  }
  // npm of the station's own Node runs on it.
  let env = match how.node {
    Some(n) => prepend_path(runtime_env, n.bin)
    None => runtime_env
  }
  let installing_now = Ref(false)
  // Claude Code's own installer (not `claude update`, nor Homebrew).
  let own = how.program == "/bin/sh" || how.mark == "claude"
  let stop = if kind == "claude" && own {
    self.watch_claude_download(installing_now)
  } else if kind == "agy" && how.mark == "agy" {
    self.watch_agy_download(env)
  } else {
    () => ()
  }
  let r = (try Ok(
      run_lines(w, how.program, how.args, env, self.timing.runtime_limit, fn(line) {
        match step_of(line) {
          None => ()
          Some(step) => {
            if same_words(Some(step), Some(installing)) {
              installing_now.val = true
            }
            self.say(kind, step, None)
          }
        }
      }),
    ) catch {
    e => Err(e)
  })
  stop()
  match r {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
/// The Node an npm install runs on where the machine had none: nodejs.org's build, its download measured and checked
/// against the release's SHASUMS256, unpacked in <data>/node once, and put last on the station's PATH.
async fn Updates::install_node(self : Updates, kind : String, node : OwnNode) -> Unit {
  // Two runtimes installed at once: one Node, put there by the first.
  while self.node_installing is Some(n) {
    n.wait() catch {
      _ => ()
    }
  }
  let mine = Shared::new()
  self.node_installing = Some(mine)
  let r : Result[Unit, Error] = try {
    self.place_node(kind, node)
    Ok(())
  } catch {
    e => Err(e)
  }
  self.node_installing = None
  mine.settle(r)
  match r {
    Ok(_) => ()
    Err(e) => raise e
  }
  put_own_nodes_soon(self.w, self.env, self.data)
}

///|
/// `/\s+/` split of a trimmed line.
fn split_space(s : String) -> Array[String] {
  let out = []
  let mut from = 0
  let mut i = 0
  while i < s.length() {
    if @jscase.is_space(cu(s, i)) {
      out.push(slice(s, from, end=i))
      while i < s.length() && @jscase.is_space(cu(s, i)) {
        i += 1
      }
      from = i
    } else {
      i += 1
    }
  }
  out.push(slice(s, from))
  out
}

///|
async fn Updates::place_node(self : Updates, kind : String, node : OwnNode) -> Unit {
  let w = self.w
  let bget = (k : String) => text(get(Some(node.build), k)).unwrap_or("")
  if w.accessible(pjoin([node.bin, bget("npm")])) {
    return
  }
  let home = own_node_home(self.data)
  w.mkdir(home, opts=jo([("recursive", jb(true))]))
  let dist = bget("dist")
  let archive = bget("archive")
  let file = pjoin([home, archive])
  let unpacked = pjoin([home, ".unpacking-\{dist}"])
  let r : Result[Unit, Error] = try {
    let base = "\{self.node_dist}/v\{node.version}"
    let sums = self.fetch_text("\{base}/SHASUMS256.txt")
    let mut want : String? = None
    for l in split(sums, "\n") {
      let ws = split_space(trim(l))
      if ws.length() > 1 && ws[1] == archive {
        want = Some(ws[0])
        break
      }
    }
    guard want is Some(want) else { raise failed_words(Key("station.updates.nodeUnverified", None)) }
    self.download(kind, "Node \{node.version}", "\{base}/\{archive}", file)
    if w.hash_file(file).0 != want {
      raise failed_words(Key("station.updates.nodeUnverified", None))
    }
    self.say(kind, installing, None)
    // (a Node's tree is thousands of files: removed off the station's thread)
    w.rm(unpacked, recursive=true)
    w.mkdir(unpacked)
    let (ok, said) = run(w, bget("tar"), ["-xf", file, "-C", unpacked], self.env, 120000.0)
    if !ok {
      raise fail(tail(said, station_lang()))
    }
    w.rm(node.at, recursive=true)
    w.rename(pjoin([unpacked, dist]), node.at)
    w.info("updates", "Node installed for npm", fields=jo([("runtime", js(kind)), ("at", js(node.at))]))
    Ok(())
  } catch {
    e => Err(e)
  }
  w.rm_quiet(file)
  w.rm_quiet(unpacked, recursive=true)
  match r {
    Ok(_) => ()
    Err(e) => raise e
  }
}

///|
/// Where a runtime's update is (while it updates), and how much of a download is in.
fn Updates::say(self : Updates, kind : String, progress : Words, percent : Int?) -> Unit {
  let item = self.item(kind)
  if item.updating is None || (same_words(item.progress, Some(progress)) && item.percent == percent) {
    return
  }
  item.progress = Some(progress)
  item.percent = percent
  self.changed()
}

///|
fn Updates::say_downloading(self : Updates, kind : String, version : String, got : Double, total : Double?) -> Unit {
  let (words, percent) = downloading(version, got, total)
  self.say(kind, words, percent)
}

///|
/// Codex's build for this machine, fetched here so how much is in can be said, and put in npm's cache for the install
/// to take: the version fetched; none when it was not.
async fn Updates::fetch_codex(self : Updates, npm : String, env : Env) -> String? {
  let w = self.w
  guard platform() is Some(p) else { return None }
  let pkg = kind_package("codex")
  let got = (try {
    let v = get(Some(self.fetch_json("\{self.registry}/\{pkg}/latest")), "version")
    let u = get(get(Some(self.fetch_json("\{self.registry}/\{pkg}/\{js_string_opt(v)}-\{p}")), "dist"), "tarball")
    match (v, u) {
      (Some(Str(v)), Some(Str(u))) => Some((@jsjson.text(v), @jsjson.text(u)))
      _ => None
    }
  } catch {
    _ => None
  })
  guard got is Some((version, url)) else { return None }
  let tmp = text(Some(w.call("os.tmpdir", []))).unwrap_or("")
  let file = pjoin([tmp, "stillfail-codex-\{version}-\{p}.tgz"])
  let r = (try {
    self.download("codex", version, url, file)
    self.say("codex", installing, None)
    let (ok, said) = run(w, npm, ["cache", "add", file], env, 120000.0)
    if ok {
      Some(version)
    } else {
      w.warn(
        "updates",
        "Codex's build not put in npm's cache; npm downloads it",
        fields=jo([("said", js(tail(said, "en")))]),
      )
      None
    }
  } catch {
    e => {
      w.warn("updates", "Codex's build not fetched; npm downloads it", fields=jo([("error", js(message_of(e)))]))
      None
    }
  })
  w.rm_quiet(file)
  r
}

///|
/// Downloads `url` to `to`, saying how much of it is in; a minute without anything coming in ends it.
async fn Updates::download(self : Updates, kind : String, version : String, url : String, to : String) -> Unit {
  let w = self.w
  let stalled = Signal::new()
  let over = Signal::new()
  let mut stall = self.fibers.after(60000.0, fn() { stalled.abort() })
  let limit = self.fibers.after(self.timing.runtime_limit, fn() { over.abort(reason=timed_out()) })
  let r : Result[Unit, Error] = try {
    let response = w.fetch("fetch", url)
    if !response.ok() || !response.has_body {
      raise fail("\{url}: \{response.status}")
    }
    let length = js_number(response.header("content-length").unwrap_or(""))
    let total = if length == length && length != @double.infinity && length > 0.0 { Some(length) } else { None }
    let out = w.write_stream(to)
    let mut got = 0.0
    self.say_downloading(kind, version, got, total)
    let streamed : Result[Unit, Error] = try {
      for chunk in response.chunks {
        stall()
        stall = self.fibers.after(60000.0, fn() { stalled.abort() })
        out.write(chunk)
        got += chunk.length().to_double()
        self.say_downloading(kind, version, got, total)
      }
      match response.breaks {
        Some(e) => raise e
        None => ()
      }
      Ok(())
    } catch {
      e => Err(if stalled.aborted { refused(station_lang(), "station.updates.downloadStalled") } else { e })
    }
    // (`out.end(() => r())`: how its end went is not looked at)
    out.end() catch {
      _ => ()
    }
    match streamed {
      Ok(_) => Ok(())
      Err(e) => Err(e)
    }
  } catch {
    e => Err(e)
  }
  stall()
  limit()
  match r {
    Ok(_) => ()
    Err(e) => raise e
  }
}

///|
/// Says how much of the Antigravity CLI's build its own installer has downloaded, then that it installs it.
fn Updates::watch_agy_download(self : Updates, env : Env) -> () -> Unit {
  let w = self.w
  watch_agy_download(w, {
    manifests: self.agy_manifests,
    build: async fn() { text(Some(w.call("platform.agyBuild", []))) },
    staging: async fn(url) { text(Some(w.call("platform.agyStaging", [env_j(env), js(url)]))) },
    after: (ms, f) => self.fibers.after(ms, f),
    said: fn(version, got, total) {
      if got >= total {
        self.say("agy", installing, None)
      } else {
        self.say_downloading("agy", version, got, Some(total))
      }
    },
  })
}

///|
/// Says how much of Claude Code's build its installer has downloaded (into ~/.claude/downloads, its size in the
/// release's manifest), until it sets it up. Looked at twice a second while it runs. Gives what stops it.
fn Updates::watch_claude_download(self : Updates, installing_now : Ref[Bool]) -> () -> Unit {
  let w = self.w
  guard env_get(self.env, "HOME") is Some(home) && home != "" && platform() is Some(p) else { return () => () }
  let stopped = Ref(false)
  let next : Ref[(() -> Unit)?] = Ref(None)
  w.go(async fn() {
    let read = (try {
      let version = trim(self.fetch_text("\{self.claude_releases}/latest"))
      let size = (m : J) => match get(get(get(Some(m), "platforms"), p), "size") {
        Some(Num(n)) => Some(n)
        _ => None
      }
      let a = (try Some(self.fetch_json("\{self.claude_releases}/\{version}/manifest.json")) catch { _ => None })
      let b = (try Some(self.fetch_json("\{self.claude_releases}/\{version}/manifest.zst.json")) catch {
        _ => None
      })
      Some((version, a.bind(size), b.bind(size)))
    } catch {
      _ => None
    })
    guard read is Some((version, plain, zst)) else { return }
    let file = pjoin([home, ".claude/downloads", "claude-\{version}-\{p}"])
    let len = async fn(f : String) -> Double? { (try Some(w.stat(f).size) catch { _ => None }) }
    let look : Ref[async () -> Unit] = Ref(fn() {  })
    look.val = async fn() {
      next.val = None
      if stopped.val || installing_now.val {
        return
      }
      let got_zst = len("\{file}.zst")
      let got_plain = len(file)
      if stopped.val || installing_now.val {
        return
      }
      let got = match got_zst {
        Some(g) => zst.map(z => (g, z))
        None =>
          match (got_plain, plain) {
            (Some(g), Some(t)) => Some((g, t))
            _ => None
          }
      }
      match got {
        Some((g, t)) => self.say_downloading("claude", version, g, Some(t))
        None => ()
      }
      // timer: a sample of this machine (another program, the installer, writing its download says nothing).
      next.val = Some(self.fibers.after(500.0, async fn() { (look.val)() }))
    }
    (look.val)()
  })
  () => {
    stopped.val = true
    match next.val {
      Some(f) => f()
      None => ()
    }
  }
}

///|
/// The station's update taken: what it was before, to put back where it does not start.
priv struct Begun {
  origin : String
  before : (Double?, Words?, Words?)
}

///|
/// What of the station's update happens at once as it is asked: refused where it is not in a cloud, else taken (so
/// another ask meanwhile finds it updating).
fn Updates::update_station_begin(self : Updates, lang : String) -> Begun raise {
  let origin = match (self.origin)() {
    Some(o) if o != "" => o
    _ => raise refused(lang, "station.updates.notJoined")
  }
  let station = self.item("station")
  let before = (station.updating, station.failed, station.done)
  station.updating = Some(self.fibers.now())
  { origin, before }
}

///|
/// Runs the installer this release carries apart from the station, as `stillfail update` does, and follows it.
async fn Updates::update_station_rest(self : Updates, lang : String, begun : Begun) -> Unit {
  let w = self.w
  let run_dir = pjoin([self.data, "run"])
  let station = self.item("station")
  let put_back = () => {
    station.updating = begun.before.0
    station.failed = begun.before.1
    station.done = begun.before.2
  }
  {
    errdefer put_back()
    w.mkdir(run_dir, opts=jo([("recursive", jb(true))]))
  }
  // Off the station's thread so cleanup does not delay its other work at every update.
  ignore(
    @effect.all([
      async fn() { w.rm(pjoin([run_dir, "update.exit"])) },
      async fn() { w.rm(pjoin([run_dir, "update.step"])) },
    ]),
  )
  let channel = self.channel()
  // The release verified, the installer to run and what it is told (refused in `lang`: not left updating).
  let plan = {
    errdefer put_back()
    plan_update(w, begun.origin, channel, self.app, self.installed, lang, self.trusted, self.cloud_request())
  }
  if plan.delta is None {
    if !self.start_planned(plan, []) {
      put_back()
      raise refused(lang, "station.updates.couldNotStart")
    }
    return
  }
  // A delta first: answered now, its download shown as the installer's is, and the installer started after it.
  self.set("station", i => {
    i.step = Some("download")
    i.percent = Some(0)
  })
  self.spawn(async fn() {
    if self.start_planned(plan, self.from_delta(plan)) {
      return
    }
    w.warn("updates", "the station's installer not started")
    self.set("station", i => {
      i.updating = None
      i.step = None
      i.percent = None
      i.done = None
      i.failed = Some(Key("station.updates.couldNotStart", None))
    })
  })
}

///|
/// Puts the station back to `to`, a release older than the one it runs that its channel's feed names (`earlier`):
/// answered once that is planned; its archive is downloaded and checked here, then the installer is handed it.
/// Updating by itself, when on, is turned off for it, with the release left kept (`autoUpdateAfter`).
async fn Updates::back_station(self : Updates, to : String, lang : String, begun : Begun) -> Unit {
  let w = self.w
  let run_dir = pjoin([self.data, "run"])
  let station = self.item("station")
  let put_back = () => {
    station.updating = begun.before.0
    station.failed = begun.before.1
    station.done = begun.before.2
  }
  let plan = {
    errdefer put_back()
    w.mkdir(run_dir, opts=jo([("recursive", jb(true))]))
    ignore(
      @effect.all([
        async fn() { w.rm(pjoin([run_dir, "update.exit"])) },
        async fn() { w.rm(pjoin([run_dir, "update.step"])) },
      ]),
    )
    plan_back(w, begun.origin, self.channel(), self.app, to, lang, self.trusted, self.cloud_request())
  }
  self.set("station", i => {
    i.step = Some("download")
    i.percent = Some(0)
    i.failed = None
    i.done = None
  })
  self.spawn(async fn() {
    let handed = self.archive_for(plan) catch {
      e => {
        w.warn(
          "updates",
          "the release to go back to not downloaded",
          fields=jo([("to", js(release_version(plan.release))), ("error", js(message_of(e)))]),
        )
        self.set("station", i => {
          i.updating = None
          i.step = None
          i.percent = None
          i.done = None
          i.failed = Some(
            key("station.updates.backNotDownloaded", args=[
              ("version", js(release_version(plan.release))),
              ("why", js(message_of(e))),
            ]),
          )
        })
        return
      }
    }
    let left = self.item("station").version
    let was_auto = self.auto()
    match left {
      Some(l) if was_auto => self.hold_auto(l)
      _ => ()
    }
    if self.start_planned(plan, handed) {
      return
    }
    if was_auto && left is Some(_) {
      self.config.edit_soon(w, [("autoUpdate", Some(jb(true))), ("autoUpdateAfter", None)])
      self.last_setting = self.setting()
    }
    w.warn("updates", "the station's installer not started")
    self.set("station", i => {
      i.updating = None
      i.step = None
      i.percent = None
      i.done = None
      i.failed = Some(Key("station.updates.couldNotStart", None))
    })
  })
}

///|
/// Updating by itself turned off as the station goes back from `left`, kept to be turned on again past it.
async fn Updates::hold_auto(self : Updates, left : String) -> Unit {
  self.config.edit_soon(self.w, [("autoUpdate", Some(jb(false))), ("autoUpdateAfter", Some(js(left)))])
  self.last_setting = self.setting()
  self.w.info(
    "updates",
    "the station goes back: updating by itself off until a newer release is out",
    fields=jo([("left", js(left))]),
  )
  self.changed()
}

///|
/// The archive of the release `back` goes back to, downloaded (take_archive) within the delta's deadline.
async fn Updates::archive_for(self : Updates, back : Plan) -> Array[(String, String)] {
  let over = Signal::new()
  // timer: a deadline of an outside request (the release's download).
  let cancel = self.fibers.after(self.timing.delta_limit, fn() { over.abort(reason=timed_out()) })
  let r = (try Ok(
      take_archive(
        self.w,
        back,
        over,
        progress=fn(percent) { self.set("station", i => i.percent = Some(percent)) },
        self.cloud_request(),
        wait=async fn(ms) { self.fibers.sleep(ms) },
      ),
    ) catch {
    e => Err(e)
  })
  cancel()
  match r {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
/// What the installer is told of the release the plan's delta made, applied apart from the station.
async fn Updates::from_delta(self : Updates, plan : Plan) -> Array[(String, String)] {
  let over = Signal::new()
  // timer: a deadline of an outside request (the delta's download) and of the applier.
  let cancel = self.fibers.after(self.timing.delta_limit, fn() { over.abort(reason=timed_out()) })
  let r = (try Ok(
      take_delta(
        self.w,
        plan,
        self.app,
        apply_apart(self.w),
        over,
        progress=fn(percent) { self.set("station", i => i.percent = Some(percent)) },
        self.cloud_request(),
        wait=async fn(ms) { self.fibers.sleep(ms) },
      ),
    ) catch {
    e => Err(e)
  })
  cancel()
  match r {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
/// `o[k] = v` on pairs kept in order (a key already there keeps its place).
fn put_pair(env : Array[(String, String)], k : String, v : String) -> Unit {
  match env.search_by(p => p.0 == k) {
    Some(i) => env[i] = (k, v)
    None => env.push((k, v))
  }
}

///|
/// Starts the installer of `plan`, told `handed` too, and follows it; false when it did not start.
async fn Updates::start_planned(self : Updates, plan : Plan, handed : Array[(String, String)]) -> Bool {
  let w = self.w
  let run_dir = pjoin([self.data, "run"])
  // Never what an installer gave the station it started: an archive long taken, a handing that is not this one's.
  let env = self.env.filter(p => p.0 != "STILLFAIL_ARCHIVE" && p.0 != "STILLFAIL_INSTALLER_HANDED")
  put_pair(env, "STILLFAIL_DATA", self.data)
  for p in plan.env + handed {
    put_pair(env, p.0, p.1)
  }
  // What it updates from, and run/update.started, before the installer runs.
  let started : Started = { at: self.fibers.now(), from: station_version_soon(w, self.app) }
  // (an update before this process looked for meanwhile is not this one: followStarted)
  self.follows += 1
  let started_file = pjoin([run_dir, "update.started"])
  w.write_file(started_file, stringify(jo([("at", jn(started.at)), ("from", jopt(started.from))]))) catch {
    e =>
      w.warn(
        "updates",
        "update.started not written; a handover or restart will not say how the update went",
        fields=jo([("error", js(message_of(e)))]),
      )
  }
  let ok = !self.closed &&
    w.call("platform.startInstaller", [js(plan.script), js(run_dir), env_j(env), js(self.app)]) is Bool(true)
  let archive = env_get(handed, "STILLFAIL_ARCHIVE")
  if !ok {
    w.rm_quiet(started_file)
    match archive {
      Some(a) if a != "" => w.rm_quiet(pdirname(a), recursive=true)
      _ => ()
    }
    return false
  }
  let version = release_version(plan.release)
  w.info(
    "updates",
    "updating the station",
    fields=jo([
      ("origin", jopt(env_get(plan.env, "STILLFAIL_ORIGIN"))),
      ("channel", jopt(env_get(plan.env, "STILLFAIL_CHANNEL"))),
      ("to", get(Some(plan.release), "version").unwrap_or(Null)),
      ("delta", jb(archive is Some(_))),
    ]),
  )
  if self.retry_due == Some(version) {
    self.retried = Some(version)
  }
  self.retry_due = None
  self.tried = Some(version)
  self.follow(started)
  true
}

///|
/// An update started before this process, when one is: followed as if started here.
pub async fn Updates::follow_started(self : Updates) -> Unit {
  let w = self.w
  let run_dir = pjoin([self.data, "run"])
  let follows = self.follows
  let started : Started = match (try Some(parse(w.read_text(pjoin([run_dir, "update.started"])))) catch { _ => None }) {
    Some(said) =>
      match get(Some(said), "at") {
        Some(Num(at)) => { at, from: text(get(Some(said), "from")) }
        _ => return
      }
    None => return
  }
  // (an update started here meanwhile wrote what was read, and may have ended and removed it since)
  if self.closed || self.follows != follows {
    return
  }
  if self.fibers.now() - started.at > self.timing.station_limit {
    ignore(
      @effect.all([
        async fn() { w.rm(pjoin([run_dir, "update.started"])) },
        async fn() { w.rm(pjoin([run_dir, "update.step"])) },
      ]),
    )
    return
  }
  w.info("updates", "following the station's update started before this process")
  self.follow(started)
}

///|
/// Shows how the station's update goes (the installer's steps, in run/update.step) until it says how it ended in
/// run/update.exit (and what it said in run/update.log), then how it went for a while. Resolves once its first look
/// is taken. One look at a time: a look asked for while one reads is taken once that one is done.
async fn Updates::follow(self : Updates, started : Started) -> Unit {
  let w = self.w
  self.follows += 1
  let follow_id = self.follows
  match self.following {
    Some(f) => f()
    None => ()
  }
  self.set("station", i => {
    i.updating = Some(started.at)
    i.step = None
    i.progress = None
    i.percent = None
    i.failed = None
    i.done = None
  })
  let run_dir = pjoin([self.data, "run"])
  let exit_file = pjoin([run_dir, "update.exit"])
  let log_file = pjoin([run_dir, "update.log"])
  let step_file = pjoin([run_dir, "update.step"])
  let over = Ref(false)
  let watcher : Ref[(async () -> Unit)?] = Ref(None)
  let soon : Ref[(() -> Unit)?] = Ref(None)
  let slow : Ref[(() -> Unit)?] = Ref(None)
  let last_running = Ref((self.running)())
  let end = async fn() {
    over.val = true
    match watcher.val {
      Some(c) => c()
      None => ()
    }
    match soon.val {
      Some(f) => f()
      None => ()
    }
    match slow.val {
      Some(f) => f()
      None => ()
    }
  }
  self.following_id += 1
  let mine = self.following_id
  self.following = Some(end)
  let look_once = async fn() {
    // The exit first, then the step: the installer writes its last step before it ends.
    let mut code = w.read_text_or_null(exit_file)
    let step = match w.read_text_or_null(step_file) {
      Some(s) => trim(s)
      None => ""
    }
    if over.val {
      return
    }
    // Made but not yet written: not ended yet; its write is seen next.
    if code is Some(c) && trim(c) == "" {
      code = None
    }
    let mut failed : Words? = None
    let mut done : Words? = None
    match code {
      Some(c) if trim(c) == "0" => done = Some(self.done_words(started, step))
      Some(c) =>
        failed = Some(
          match w.read_text_or_null(log_file) {
            Some(said) => Text(tail(said, station_lang()))
            None => Key("station.updates.installerExit", Some(jo([("code", js(trim(c)))])))
          },
        )
      None =>
        if self.fibers.now() - started.at > self.timing.station_limit {
          failed = Some(Key("station.updates.installerTimedOut", None))
        } else {
          let percent = if step == "download" { station_download_percent(w, log_file) } else { None }
          if over.val {
            return
          }
          let item = self.item("station")
          let running = (self.running)()
          let now_step = if step == "" { None } else { Some(step) }
          if item.step != now_step ||
            item.percent != percent ||
            (step == "drain" && running != last_running.val) {
            item.step = now_step
            item.percent = percent
            last_running.val = running
            self.changed()
          }
          return
        }
    }
    if over.val {
      return
    }
    end()
    if self.following_id == mine {
      self.following = None
    }
    ignore(
      @effect.all([
        async fn() { w.rm_quiet(pjoin([run_dir, "update.started"])) },
        async fn() { w.rm_quiet(pjoin([run_dir, "update.step"])) },
      ]),
    )
    // With what the installer said last when it failed.
    w.info(
      "updates",
      "the station's update ended",
      fields=match failed {
        Some(f) => jo([("failed", jb(true)), ("why", js(say(f, "en")))])
        None => jo([("failed", jb(false))])
      },
    )
    // (closed, or another update followed since: that one says how the station is)
    if self.closed || self.follows != follow_id {
      return
    }
    self.set("station", i => {
      i.updating = None
      i.step = None
      i.progress = None
      i.percent = None
      i.failed = failed
      i.done = done
    })
    // A timeout alone does not mean the installer exited. It and success also cancel an earlier pending retry.
    if code is None || failed is None {
      self.retry_serial += 1
      self.retry_due = None
      self.retried = self.tried
    } else {
      match self.tried {
        Some(t) if self.retried != Some(t) => {
          self.retry_due = None
          self.retry_station(t)
        }
        _ => ()
      }
    }
    self.spawn(async fn() { self.check() })
    match done {
      Some(shown) =>
        ignore(
          self.later(self.timing.done_shown, fn() {
            if same_words(self.item("station").done, Some(shown)) {
              self.set("station", i => i.done = None)
            }
          }),
        )
      None => ()
    }
  }
  let looking : Ref[Shared?] = Ref(None)
  let again = Ref(false)
  let look = async fn() {
    soon.val = None
    if over.val {
      return
    }
    match looking.val {
      Some(l) => {
        again.val = true
        return l.wait()
      }
      None => ()
    }
    let mine = Shared::new()
    looking.val = Some(mine)
    while true {
      again.val = false
      look_once() catch {
        e =>
          w.warn("updates", "the station's update not looked at", fields=jo([("error", js(message_of(e)))]))
      }
      if !(again.val && !over.val) {
        break
      }
    }
    looking.val = None
    mine.settle(Ok(()))
  }
  let look_soon = () => if !over.val && soon.val is None {
    soon.val = Some(self.fibers.after(50.0, async fn() { look() }))
  }
  w.mkdir(run_dir, opts=jo([("recursive", jb(true))])) catch {
    _ => ()
  }
  if over.val {
    return
  }
  watcher.val = Some(
    (w.watch)(run_dir, name => match name {
      Some(n) if !starts_with(n, "update.") => ()
      _ => look_soon()
    }),
  ) catch {
    e => {
      w.warn(
        "updates",
        "run/ not watched; the update is looked at now and then",
        fields=jo([("error", js(message_of(e)))]),
      )
      None
    }
  }
  // timer: another program (the installer) writing its files may go unheard by the watch
  slow.val = Some(self.fibers.every(self.timing.follow_look, async fn() { look() }))
  look()
}

///|
/// Where the update is, by the installer's step, as the pages say it.
fn Updates::progress_of(self : Updates, step : String?) -> Words? {
  match step {
    Some("download") => Some(Key("station.updates.downloadingStation", None))
    Some("handoff") => Some(Key("station.updates.handoff", None))
    Some("drain") => {
      let n = (self.running)()
      if n == 0.0 {
        Some(Key("station.updates.restarting", None))
      } else {
        Some(Key("station.updates.draining", Some(jo([("n", jn(n))]))))
      }
    }
    Some("restart") => Some(Key("station.updates.restarting", None))
    _ => None
  }
}

///|
/// How an update that ended well went, by the step it ended on.
async fn Updates::done_words(self : Updates, started : Started, step : String) -> Words {
  let now = station_version_soon(self.w, self.app)
  if now is Some(_) && now == started.from {
    return Key("station.updates.upToDate", None)
  }
  let (with_version, without) = match step {
    "handoff" => ("station.updates.doneHandoff", "station.updates.doneHandoffNoVersion")
    "drain" | "restart" => ("station.updates.doneRestart", "station.updates.doneRestartNoVersion")
    _ => ("station.updates.done", "station.updates.doneNoVersion")
  }
  match now {
    Some(v) => Key(with_version, Some(jo([("version", js(v))])))
    None => Key(without, None)
  }
}

// ---- for tests ----

///|
/// The station's line as if its latest were `latest`, read from the channel it is on.
pub async fn Updates::station_with(self : Updates, latest : String, lang : String) -> J {
  let item = self.item("station")
  item.version = station_version(self.w, self.app)
  item.latest = Some(latest)
  item.channel = Some(self.channel())
  self.get(lang)[0]
}

///|
/// Sets a line's state by hand (tests): the fields `f` says (as the TypeScript's Item names them).
pub fn Updates::poke(self : Updates, kind : String, f : J) -> Unit {
  let item = self.item(kind)
  for k in keys_of(f) {
    let v = get(Some(f), k)
    let s = text(v)
    match k {
      "installed" => item.installed = v is Some(Bool(true))
      "version" => item.version = s
      "latest" => item.latest = s
      "repairable" => item.repairable = v is Some(Bool(true))
      "note" => item.note = Words::of_j(v)
      "updating" => item.updating = num(v)
      "progress" => item.progress = Words::of_j(v)
      "step" => item.step = s
      "percent" => item.percent = num(v).map(n => n.to_int())
      "done" => item.done = Words::of_j(v)
      "failed" => item.failed = Words::of_j(v)
      "channel" => item.channel = s
      "how" => item.how = match v { Some(Obj(_) as h) => Some(how_of(h)); _ => None }
      _ => ()
    }
  }
}

///|
/// The running station's side: takes the channel asked for in <run>/channel-ask (if any), sets it, and answers in
/// <run>/channel-answer (`ok <channel>`, or `error <why>`).
pub async fn answer_channel_ask(w : World, run_dir : String, set_to : async (String) -> Unit) -> Unit {
  let ask = pjoin([run_dir, channel_ask])
  guard w.read_text_or_null(ask) is Some(asked) else { return }
  w.rm(ask)
  let t = trim(asked)
  let answer = if t == "stable" || t == "beta" {
    (try {
      set_to(t)
      "ok \{t}"
    } catch {
      e => "error \{message_of(e)}"
    })
  } else {
    "error \{tr(station_lang(), "station.cli.unknownChannel", args=jo([("channel", js(t))]))}"
  }
  write_whole(w, pjoin([run_dir, channel_answer]), "\{answer}\n") catch {
    e =>
      w.warn("updates", "the update channel's answer not written", fields=jo([("error", js(message_of(e)))]))
  }
}
