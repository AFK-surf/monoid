// P5-1: the station's platform as main.ts and services.ts make it, with real IO, on the composition bus (live_bus.mbt):
// config.json (`ConfigFile`, watched), what is the station's own, its log and error reports to still.fail
// (ops/log-export.ts, ops/telemetry.ts), the machine kept awake while agents work (ops/awake.ts), a lost station's
// chats taken back before the store opens (replica/restore.ts), the control plane and its presence socket
// (live_p5_1_plane.mbt), the readers and their checkpoints (live_p5_1_readers.mbt), the machine's state and the event
// streams (live_p5_1_events.mbt), the admin API (live_p5_1_admin.mbt), the mesh (live_p5_1_mesh.mbt) and the rigs
// (live_p5_1_rigs.mbt). Each fills in its part of the bus; what another slice fills in is asked through it.

///|
/// What P5-1 keeps while the station runs.
priv struct P51 {
  bus : LiveBus
  host : @host.Host
  fs : @ops_platform.Fs
  config : @ops_platform.ConfigFile
  /// What listens to config.json (the bus's `config_listen`): each with its id.
  config_listeners : Array[(Int, (Json) -> Unit)]
  mut next_config : Int
  config_checks : Array[(Json) -> String?]
  /// The station's id as cloud.json says it, read as the plane's state changes (main.ts `stationKey`).
  mut station_id : String?
  log_export : @ops_platform.LogExport
  /// Bodies of the log that could not be sent, sent first at the next round.
  log_unsent : Array[String]
  reports : ErrorReports
  /// What the platform's other files keep, each made once (`live_p5_1_*.mbt`).
  mut plane : Plane?
  mut readers : Readers?
  mut admin_host : AdminHostLive?
  mut events : EventsLive?
  mut admin : AdminLive?
  mut mesh : MeshLive?
  mut rigs : RigsLive?
  /// The rig itself, on a machine that is one.
  mut rig : @rigs_mode.Rig?
  /// The other stations' transport, once the mesh is up (what the keeper asks of them).
  keeper_call : Ref[@gate.StationCall?]
  /// Other stations' ports and devices forwarded here for chats (a whole station's).
  mut forwards : @gate.Forwards?
  /// What to do as the station stops, last first.
  stops : Array[() -> Unit]
  /// What the overview keeps between its makings (overview.ts: the groups' memory, the decisions' view kept).
  overview_kept : @events.OverviewKept
  /// The chats' store the overview reads its chats' titles from (overview.ts `chatTitleOf`), made at its first read.
  mut threads : @store_threads.Store?
}

///|
/// The process's P5-1 (one run in a process).
let p51_live : Ref[P51?] = Ref(None)

///|
/// A slice's log line (P5-2 to P5-5, their parts' `log`), as P5-1's own: its time and level as log.ts writes them,
/// and heard (the station's log sent, an error reported). Written bare, those lines had no time and none reached
/// either (0.1.9984).
fn slice_log(level : String, at : String, message : String, fields : Json) -> Unit {
  let f = match fields {
    Object(m) if m.length() > 0 => Some(fields)
    Object(_) | Null => None
    other => Some({ "said": other })
  }
  p51_log(level.to_upper(), at, message, fields?=f)
}

///|
/// A line a part wrote through `@host.note` as a log line of the station's own: "<level> <part>: <words>",
/// "[<level>] <part>: <words>", "[<part>] <words>" (an info) or "failed: <words>" (a runtime's warning); any other
/// line an info of the station's.
fn noted(said : String) -> Unit {
  let text = if said.has_suffix("\n") { said[:said.length() - 1].to_owned() } else { said }
  let levels = ["debug", "info", "warn", "error"]
  let words = text.split(" ").map(w => w.to_owned()).collect()
  let after = (n : Int) => if n < text.length() { text[n:].to_owned() } else { "" }
  match words {
    [level, part, ..] if levels.contains(level) && part.length() > 1 && part.has_suffix(":") =>
      p51_log(level.to_upper(), part[:part.length() - 1].to_owned(), after(level.length() + 1 + part.length() + 1))
    [tag, part, ..] if tag.length() > 2 &&
      tag.has_prefix("[") &&
      tag.has_suffix("]") &&
      levels.contains(tag[1:tag.length() - 1].to_owned().to_lower()) &&
      part.length() > 1 &&
      part.has_suffix(":") =>
      p51_log(
        tag[1:tag.length() - 1].to_owned().to_upper(),
        part[:part.length() - 1].to_owned(),
        after(tag.length() + 1 + part.length() + 1),
      )
    [tag, ..] if tag.length() > 2 && tag.has_prefix("[") && tag.has_suffix("]") =>
      p51_log("INFO", tag[1:tag.length() - 1].to_owned(), after(tag.length() + 1))
    ["failed:", ..] => p51_log("WARN", "runtime", after("failed: ".length()))
    _ => p51_log("INFO", "station", text)
  }
}

///|
/// A line of the station's log (ops/log.ts): written to stderr as the TypeScript's are, kept for still.fail
/// (`stationLog`), and an error line reported where the operator turned reports on (`hearErrors`).
fn p51_log(level : String, at : String, message : String, fields? : Json) -> Unit {
  let now = wall_ms().to_double()
  // (the line ends with its own newline)
  err_write(@ops_platform.log_line(now, level, at, message, fields))
  match p51_live.val {
    Some(p) => p.heard(now, level, at, message, fields)
    None => ()
  }
}

///|
fn P51::heard(self : P51, now : Double, level : String, at : String, message : String, fields : Json?) -> Unit {
  self.log_export.add(
    { ms: now, level, at, message, fields: fields.unwrap_or(Json::object({})) },
    self.telemetry_logs(),
  )
  if level == "ERROR" {
    let (log, error) = @ops_platform.error_heard("\{at}: \{message}", fields)
    self.reports.report(log, error)
  }
}

///|
/// config.json's `telemetry.logs` (on unless false).
fn P51::telemetry_logs(self : P51) -> Bool {
  match (self.bus.config_raw.val)() {
    { "telemetry": { "logs": False, .. }, .. } => false
    _ => true
  }
}

///|
/// config.json's `telemetry.errors` (off unless true).
fn P51::telemetry_errors(self : P51) -> Bool {
  (self.bus.config_raw.val)() is { "telemetry": { "errors": True, .. }, .. }
}

///|
/// A fiber of P5-1's, ended with the station.
fn P51::fork(self : P51, name : String, f : async () -> Unit) -> Unit {
  let fiber = self.host.rt.fork(name~, async fn() {
    f() catch {
      e => p51_log("WARN", "station", "\{name} ended", fields={ "error": Json::string("\{e}") })
    }
  })
  self.stops.push(() => fiber.interrupt())
}

///|
/// `f` every `ms`, until the station stops (each line that calls it says which timer it is).
fn P51::every(self : P51, name : String, ms : Int, f : async () -> Unit) -> Unit {
  self.fork(name, async fn() {
    while !self.bus.stopped.is_done() {
      @effect.sleep(ms)
      if self.bus.stopped.is_done() {
        break
      }
      f() catch {
        e => p51_log("WARN", "station", "\{name}", fields={ "error": Json::string("\{e}") })
      }
    }
  })
}

///|
/// `f` once after `ms`; the function returned calls it off.
fn P51::after(self : P51, ms : Int, f : () -> Unit) -> () -> Unit {
  let fiber = self.host.rt.fork(name="after", async fn() {
    @effect.sleep(ms)
    f()
  })
  () => fiber.interrupt()
}

// ── before the store: a lost station's chats taken back ──

///|
/// main.ts `beforeStore` (replica/restore.ts `takeBackSoon`): a copy brought to `<data>/restore` put into the store
/// before it opens, by the program itself (`@replica.take_back`, what `--builder replica-restore` runs).
pub async fn before_store_p5_1(host : @host.Host, data : String, db_path : String) -> Unit {
  guard read_text(path([data, "restore", "ready.json"])) is Some(_) else { return }
  match (try { Ok(@replica.take_back(host, sep(), data, db_path, wall_ms().to_double())) } catch { e => Err(e) }) {
    Ok(Some(ready)) => {
      let text = (k : String) => match ready.get(k) {
        Some(@jsjson.JValue::Str(s)) => Json::string(@jsjson.text(s))
        _ => Json::null()
      }
      p51_log("INFO", "copies", "a lost station's chats taken back", fields={ "station": text("origin"), "from": text("from") })
    }
    Ok(None) => ()
    Err(e) => p51_log("ERROR", "copies", "a lost station's chats not taken back", fields={ "error": Json::string("\{e}") })
  }
}

// ── the entry ──

///|
/// P5-1's part of the station, put together on `bus` (main.ts's platform layers): what it fills in is the bus's from
/// now on, what it starts runs until the station stops.
pub async fn start_live_p5_1(bus : LiveBus) -> Unit {
  let host = bus.host
  let fs = @ops_platform.Fs::new(host)
  let config = @ops_platform.ConfigFile::new(
    fs,
    bus.data,
    env_get("STILLFAIL_CONFIG"),
    tr(station_lang(bus.data), "station.files.invalidJson", args=[("path", config_path(bus.data)), ("program", "still.fail")]),
  ) catch {
    e => {
      // (read before ready already: run.mbt refused one unreadable then; one made so since is the last good)
      p51_log("ERROR", "config", "config.json unreadable", fields={ "error": Json::string("\{e}") })
      raise e
    }
  }
  let p : P51 = {
    bus,
    host,
    fs,
    config,
    config_listeners: [],
    next_config: 0,
    config_checks: [],
    station_id: None,
    log_export: @ops_platform.LogExport::new(homedir()),
    log_unsent: [],
    reports: ErrorReports::new(host, bus.app),
    plane: None,
    readers: None,
    admin_host: None,
    events: None,
    admin: None,
    mesh: None,
    rigs: None,
    rig: None,
    keeper_call: Ref(None),
    forwards: None,
    stops: [],
    overview_kept: @events.OverviewKept::new(),
    threads: None,
  }
  p51_live.val = Some(p)
  // The parts' lines through the host's `note` ("warn helper: …"): each with its time, and heard, as P5-1's are.
  @host.note_sink.val = Some(noted)
  p.config_live()
  p.station_id = match read_json(path([bus.data, "mesh", "cloud.json"])) {
    Some({ "station": String(s), .. }) => Some(s)
    _ => None
  }
  p.telemetry_live()
  // The control plane (its state, presence, notices) before what follows it.
  let plane = p.plane_live()
  p.plane = Some(plane)
  let as_rig = bus.as_rig()
  // The readers and their checkpoints, the machine's state, the events, the admin API.
  let readers = p.readers_live()
  p.readers = Some(readers)
  let admin_host = p.admin_host_live()
  p.admin_host = Some(admin_host)
  p.awake_live()
  if as_rig {
    // A rig (rig/main.ts): only what another station asks of it.
    p.rig_live()
  } else {
    let events = p.events_live()
    p.events = Some(events)
    p.admin = Some(p.admin_live())
    ignore(p.forwards_live())
    p.rigs_live()
    p.became_rig_live()
  }
  p.mesh = Some(p.mesh_live())
  // Everything P5-1 made let go as the station stops.
  ignore(
    host.rt.fork(name="p5-1 stop", async fn() {
      ignore(bus.stopped.wait())
      p.close()
    }),
  )
}

///|
/// Starts the mesh listener after all live slices have registered their ops, routes and peer handlers.
fn start_live_p5_1_mesh(bus : LiveBus) -> Unit {
  match p51_live.val {
    Some(p) => p.mesh_start(bus.as_rig())
    None => ()
  }
}

///|
/// What P5-1 started let go of at once (its processes ended, what it hands over written), as `run` returns.
pub fn stop_live_p5_1() -> Unit {
  match p51_live.val {
    Some(p) => p.close()
    None => ()
  }
}

///|
fn P51::close(self : P51) -> Unit {
  let stops = self.stops.copy()
  self.stops.clear()
  stops.rev_each(f => f())
  match self.readers {
    Some(r) => r.close()
    None => ()
  }
  self.reports.close()
  self.log_export.close()
}

// ── config.json ──

///|
/// services.ts StationConfig: one config.json for the whole station, read again as it changes (by another program: an
/// agent, a person), checked by what the parts say an edit must pass, its edits written whole and told.
fn P51::config_live(self : P51) -> Unit {
  let bus = self.bus
  let config = self.config
  config.set_check((next, _) => {
    let mut why : String? = None
    for chk in self.config_checks {
      if chk(next) is Some(w) {
        why = Some(w)
        break
      }
    }
    why
  })
  config.listen(value => for l in self.config_listeners.copy() {
    (l.1)(value)
  })
  bus.config_raw.val = () => match (try { Ok(config.raw()) } catch { e => Err(e) }) {
    Ok(v) => v
    Err(_) => config.value
  }
  bus.config_update.val = async fn(edit) {
    config.update(edit) catch {
      e => raise BusError("\{e}")
    }
  }
  bus.config_listen.val = f => {
    self.next_config += 1
    let id = self.next_config
    self.config_listeners.push((id, f))
    () => ignore(self.config_listeners.search_by(x => x.0 == id).map(i => self.config_listeners.remove(i)))
  }
  bus.config_check.val = chk => self.config_checks.push(chk)
  bus.lang.val = () => match (bus.config_raw.val)() {
    { "language": String(l), .. } => @ops_platform.lang_of(Some(l))
    _ => "zh"
  }
  (bus.own_add.val)(config.path)
  // Edited by another program: looked at again (no watch of files is the shell's).
  self.every("config.json", 1000, async fn() { // timer: an outside system that offers no push (a file another program edits)
    ignore(config.raw()) catch {
      e => p51_log("WARN", "config", "config.json unreadable; the last good kept", fields={ "error": Json::string("\{e}") })
    }
  })
}

// ── the log and error reports, to still.fail ──

///|
/// telemetry.ts ErrorReports: error lines to still.fail's PostHog project while config.json says so and the build has a
/// key (`<app>/dist/admin/posthog.json`).
priv struct ErrorReports {
  host : @host.Host
  key : (String, String, String)?
  anonymous : String
  queue : Array[Json]
  mut sending : Bool
  mut closed : Bool
  mut enabled : () -> Bool
  mut station : () -> String?
}

///|
fn ErrorReports::new(host : @host.Host, app : String) -> ErrorReports {
  let key = match read_json(path([app, "dist", "admin", "posthog.json"])) {
    Some({ "host": String(h), "key": String(k), "release": String(r), .. }) => Some((h, k, r))
    _ => None
  }
  {
    host,
    key,
    anonymous: @drive.hex(@drive.random_bytes(16)),
    queue: [],
    sending: false,
    closed: false,
    enabled: () => false,
    station: () => None,
  }
}

///|
fn ErrorReports::report(self : ErrorReports, log : String, error : String?) -> Unit {
  guard !self.closed && (self.enabled)() && self.key is Some((_, _, release)) else { return }
  self.queue.push(
    @ops_platform.error_event(log, error, (self.station)(), self.anonymous, Some(release), homedir(), wall_ms().to_double()),
  )
  if self.sending {
    return
  }
  self.sending = true
  ignore(
    self.host.rt.fork(name="error reports", async fn() {
      defer {
        self.sending = false
      }
      guard self.key is Some((h, k, _)) else { return }
      let http = @cloud_net.host_http(self.host)
      while self.queue.length() > 0 {
        let batch = self.queue.copy()
        self.queue.clear()
        let mut base = h
        while base.has_suffix("/") {
          base = base[:base.length() - 1].to_owned()
        }
        let body : Json = { "api_key": Json::string(k), "batch": Json::array(batch) }
        let headers = @cloud_net.Headers::new()
        headers.set("content-type", "application/json")
        let sent : Result[Unit, String] = try {
          let r = (http.fetch)({ url: base + "/batch/", http_method: "POST", headers, body: Some(body.stringify()), timeout_ms: 10000 })
          if r.status < 200 || r.status >= 300 {
            Err("answered \{r.status}")
          } else {
            Ok(())
          }
        } catch {
          e => Err("\{e}")
        }
        match sent {
          Ok(_) => ()
          // (not through the log: that would report itself)
          Err(why) => err_write("\{iso_time(wall_ms().to_double())}  WARN telemetry: error reports not sent error=\{why}\n")
        }
      }
    }),
  )
}

///|
fn ErrorReports::close(self : ErrorReports) -> Unit {
  self.closed = true
}

///|
/// main.ts: error lines reported (`hearErrors`), every line kept for still.fail (`stationLog.configure`) and sent each
/// few seconds through the control plane once there is one (log-export.ts `flush`, mesh.ts `sendWith`).
fn P51::telemetry_live(self : P51) -> Unit {
  self.reports.enabled = () => self.telemetry_errors()
  self.reports.station = () => self.station_id
  self.log_export.configure()
  self.every("the station's log", 5000, async fn() { // timer: a batch of the log, sent every few seconds (log-export.ts EVERY_MS)
    self.flush_log()
  })
}

///|
/// What of the log waits, sent through the control plane: a batch it could not take (no answer) kept for the next round.
async fn P51::flush_log(self : P51) -> Unit {
  guard self.plane is Some(plane) else { return }
  let bodies = self.log_unsent.copy()
  self.log_unsent.clear()
  ignore(
    self.log_export.send_all(self.telemetry_logs(), self.station_id, self.bus.version, wall_ms().to_double(), body => {
      bodies.push(body)
      None
    }),
  )
  for i, body in bodies {
    match (try { Ok(plane.control.logs(body)) } catch { e => Err(e) }) {
      Ok(_) => ()
      Err(e) => {
        // (refused by the plane: dropped; not reached: the rest kept for the next round, the oldest dropped first)
        let words = "\{e}"
        if !(words.contains(" 4") && !words.contains(" 429")) {
          for b in bodies[i:] {
            self.log_unsent.push(b)
          }
          while self.log_unsent.length() > 20 {
            ignore(self.log_unsent.remove(0))
          }
        }
        return
      }
    }
  }
}

// ── the machine kept awake while agents work ──

///|
/// ops/awake.ts AwakeLive: looked at every 20 s; held while a session runs, waits on work it started, or a job that is
/// work runs, a minute after the last of it (caffeinate on macOS, systemd-inhibit elsewhere, none on Windows here).
fn P51::awake_live(self : P51) -> Unit {
  let awake = @ops_platform.Awake::new()
  let held : Ref[Proc?] = Ref(None)
  let release = () => match held.val {
    Some(child) => {
      ignore(kill(child.pid, "SIGTERM"))
      held.val = None
    }
    None => ()
  }
  self.stops.push(release)
  let mac = platform() == "darwin"
  let inhibit = !mac && !is_windows() && find_program("systemd-inhibit") is Some(_)
  let check = () => {
    let now = wall_ms().to_double()
    let store = self.bus.store
    let working = try {
      let any = store.any_running()
      let wait = match store.awake_wait(now, @ops_platform.awake_linger_ms) {
        True => Some(true)
        False => Some(false)
        _ => None
      }
      let jobs = store
        .awake_jobs()
        .map(j => match j {
          { "sessionKey": String(k), "startedAt": Number(at, ..), .. } => (k, at)
          { "sessionKey": String(k), .. } => (k, now)
          _ => ("", now)
        })
      let live = if wait is None {
        store.live_sessions().filter_map(s => match s { { "key": String(k), .. } => Some(k); _ => None })
      } else {
        []
      }
      @ops_platform.awake_working(
        any,
        wait,
        jobs,
        live,
        keys => {
          let turns = store.last_turns_of(keys) catch { _ => Json::array([]) }
          match turns {
            Array(items) =>
              items.filter_map(it => match it {
                Array([String(k), t]) => {
                  let num = (f : String) => match t {
                    Object(m) =>
                      match m.get(f) {
                        Some(Number(n, ..)) => Some(n)
                        _ => None
                      }
                    _ => None
                  }
                  let declared = match t {
                    { "declared": String(d), .. } => Some(d)
                    _ => None
                  }
                  Some((k, declared, num("endedAt"), num("waitSeconds")))
                }
                _ => None
              })
            _ => []
          }
        },
        now,
      )
    } catch {
      _ => false
    }
    let can = mac || inhibit
    match awake.check(now, working, can) {
      Some("hold") => {
        let command = @ops_platform.unix_hold_awake(mac, "still.fail agents are working", @drive.pid(), inhibit)
        match command {
          Some((program, args)) =>
            match (try { Ok(spawn(self.host, program, args, stdin_piped=!mac)) } catch { e => Err(e) }) {
              Ok(child) => {
                held.val = Some(child)
                p51_log("INFO", "awake", "holding the machine awake while agents work")
              }
              Err(SysError(e)) => p51_log("WARN", "awake", "the machine not held awake", fields={ "error": Json::string(e) })
            }
          None => ()
        }
      }
      Some("cannot") => p51_log("WARN", "awake", "this machine has no way to be held awake: it may sleep while agents work")
      Some("release") => {
        release()
        p51_log("INFO", "awake", "the work is done: the machine sleeps by its own settings again")
      }
      _ => ()
    }
  }
  self.every("awake", @ops_platform.awake_every_ms.to_int(), async fn() { check() }) // timer: a sample of this machine (whether agents work: awake.ts EVERY)
}

///|
/// A program on the PATH, where it is.
fn find_program(name : String) -> String? {
  guard env_get("PATH") is Some(p) else { return None }
  for dir in p.split(if is_windows() { ";" } else { ":" }) {
    let d = dir.to_owned()
    if d == "" {
      continue
    }
    let at = path([d, name])
    if attempt(() => @drive.realpath(at)) is Ok(_) {
      return Some(at)
    }
  }
  None
}
