// `run`: the station's process as main.ts makes it, in MoonBit (its composition root): the data directory held, its
// config and control plane's state read before anything is said, the launcher's control channel (ops/launcher.ts:
// `--launcher-fds mcp,loopback,control` on Unix, `--launcher-pipe` on Windows, none on its own, where SIGTERM and ^C stop
// it), its key and store (the schema made or brought up), the loopback port (ops/loopback.ts), the local status's
// socket (api/status.ts), the agents' door (`/mcp`, `/health`: tools/http.ts) once the process before is gone
// (sessions/agents.ts `start`), how it is said in run/health.json (ops/health.ts) and to the launcher each 10 s
// (`heartbeat`), `stillfail heap`'s requests, and a handover: what it holds carried to the next process (`carry`,
// run/handover.json) and itself ended; the next, started beside it, `taking` it up once it is gone.
//
// What the TypeScript station's parts do beyond these are put together on the composition bus (live_bus.mbt) by the
// live slices, started once the store opens: the platform (the control plane and its presence, the mesh, the readers,
// the events, the admin API, the rigs) is P5-1's (live_p5_1_*.mbt); the hub's actors, the connects, the jobs, the
// vault, the drive, the browser, the devices, the copies and the moves are the others' (station/mb/src/station_main/
// AGENTS.md says what is and is not).

///|
/// `run`'s exit when another station runs the data directory (ops/held.ts HELD).
pub let held_exit : Int = 3

///|
/// How often the process says it runs (main.ts HELD_EVERY_MS); STILLFAIL_HELD_EVERY_MS for a test's that waits less.
fn held_every_ms() -> Int {
  match env_get("STILLFAIL_HELD_EVERY_MS") {
    Some(t) =>
      match attempt(() => @string.parse_int(t)) {
        Ok(n) if n >= 100 => n
        _ => 10000
      }
    None => 10000
  }
}

///|
/// The launcher's channel, or none.
priv struct Control {
  host : @host.Host
  /// A line written to the launcher.
  write : (String) -> Unit
  /// Whether there is a launcher at all.
  handed : Bool
  mcp_fd : Int?
  loopback_fd : Int?
  /// The launcher's ports, where it holds them (Windows): this process listens on any, says where.
  ports : (Int, Int)?
  carries : Bool
  heartbeats : Bool
  /// `--launcher-installer`: the launcher starts the release's installer where this process cannot.
  installer : Bool
}

///|
fn Control::say(self : Control, value : Json) -> Unit {
  if self.handed {
    (self.write)(value.stringify() + "\n")
  }
}

///|
fn int_list(s : String?) -> Array[Int]? {
  guard s is Some(t) else { None }
  let out = []
  for p in t.split(",") {
    match attempt(() => @string.parse_int(p.to_owned())) {
      Ok(n) => out.push(n)
      Err(_) => return None
    }
  }
  Some(out)
}

///|
/// A release's version (`0.1.<BUILD>`) from its `<app>/BUILD`, none where it says none (ops/version.ts
/// `stationVersion`).
fn build_version(app : String) -> String? {
  guard read_text(path([app, "BUILD"])) is Some(t) else { None }
  let b = t.trim().to_owned()
  if b != "" && b.iter().all(c => c >= '0' && c <= '9') {
    Some("0.1.\{b}")
  } else {
    None
  }
}

///|
/// A release's build timestamp (Unix ms) from its `<app>/BUILT_AT`, none where absent or invalid (ops/version.ts
/// `stationBuiltAt`).
fn build_built_at(app : String) -> Double? {
  guard read_text(path([app, "BUILT_AT"])) is Some(t) else { None }
  let raw = t.trim().to_owned()
  if raw != "" && raw.iter().all(c => c >= '0' && c <= '9') {
    match attempt(() => @string.parse_int64(raw[:])) {
      Ok(ms) if ms > 0L && ms <= 9007199254740991L => Some(ms.to_double())
      _ => None
    }
  } else {
    None
  }
}

///|
/// This station's build timestamp (ops/version.ts `builtAt`): the release `--app` names, else the one this program is
/// in (`<app>/station/stillfail-reader`: two up from it), else None in development.
pub fn station_built_at(args : Array[String], argv0 : String) -> Double? {
  let given = match flag(args, "--app") {
    Some(app) => build_built_at(app)
    None => None
  }
  match given {
    Some(ms) => Some(ms)
    None => {
      if argv0 == "" {
        return None
      }
      let s = sep()
      let real = attempt(() => @drive.realpath(argv0)).unwrap_or(argv0)
      build_built_at(@nodepath.dirname(s, @nodepath.dirname(s, real)))
    }
  }
}

///|
/// This station's version (ops/version.ts `version`): the release `--app` names, else the one this program is in
/// (`<app>/station/stillfail-reader`: two up from it), else 0.1.0.
pub fn station_version(args : Array[String], argv0 : String) -> String {
  let given = match flag(args, "--app") {
    Some(app) => build_version(app)
    None => None
  }
  match given {
    Some(v) => v
    None => {
      let s = sep()
      let real = attempt(() => @drive.realpath(argv0)).unwrap_or(argv0)
      build_version(@nodepath.dirname(s, @nodepath.dirname(s, real))).unwrap_or("0.1.0")
    }
  }
}

///|
/// ops/held.ts `heldBy`: another process of this data directory's station still there (run/station.json's launcher or
/// run/hub.json's), or none.
pub fn held_by(data : String, self_pid : Int) -> Int? {
  for name in ["station.json", "hub.json"] {
    match read_json(path([data, "run", name])) {
      Some({ "pid": Number(p, ..), .. }) if p == p.floor() && p > 0.0 && p.to_int() != self_pid && pid_alive(p.to_int()) =>
        return Some(p.to_int())
      _ => ()
    }
  }
  None
}

///|
/// Written whole: to a file of this process's own beside it, then renamed into place.
fn write_whole(file : String, text : String) -> Unit {
  ignore(attempt(() => @drive.mkdir(@nodepath.dirname(sep(), file), true)))
  ignore(attempt(() => @drive.write_private(file, text)))
}

///|
/// What the loopback port says to `path`?`query` (ops/loopback.ts `answer`).
pub fn loopback_answer(path : String, query : String?, ready : Bool, place : Json?, lang : String) -> Reply {
  if path == "/healthz" {
    return plain(if ready { 200 } else { 503 }, "")
  }
  if path.has_prefix("/admin/api/") || path == "/admin/api" {
    return json_reply(404, { "error": Json::string(tr(lang, "station.local.noAdminApi")) })
  }
  if path != "/" && path != "/admin" && !path.has_prefix("/admin/") {
    return plain(404, "")
  }
  let text = (k : String) => match place {
    Some(Object(m)) =>
      match m.get(k) {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
  let removed_at = match place {
    Some(Object(m)) =>
      match m.get("removed_at") {
        Some(Number(n, ..)) => Some(n)
        _ => None
      }
    _ => None
  }
  if place is Some(_) && removed_at is None && text("origin") != "" && text("workspace") != "" {
    let sub = if path.has_prefix("/admin") { path[6:].to_owned() } else { path }
    let to = moved_to(sub, query, text("origin"), text("workspace"), text("station"))
    return { status: 302, headers: [("location", to), ("cache-control", "no-store")], body: b"" }
  }
  match removed_at {
    Some(at) => plain(404, tr(lang, "station.local.removed", args=[("workspace", text("workspace_name")), ("at", iso_time(at * 1000.0))]))
    None => plain(404, tr(lang, "station.local.unjoined"))
  }
}

///|
/// Where a page of the station's old page is in the cloud's web app (ops/loopback.ts `moved`).
pub fn moved_to(sub : String, query : String?, origin : String, workspace : String, station : String) -> String {
  let mut o = origin
  while o.has_suffix("/") {
    o = o[:o.length() - 1].to_owned()
  }
  let w = "\{o}/w/\{workspace}"
  let s = station
  let parts = sub.split("/").map(p => p.to_owned()).filter(p => p != "").to_array()
  let n = parts.length()
  let a = if n > 0 { parts[0] } else { "" }
  let b = if n > 1 { parts[1] } else { "" }
  let c = if n > 2 { parts[2] } else { "" }
  let to = if n == 2 && a == "chats" {
    "\{w}/s/\{s}/chats/\{b}"
  } else if n == 2 && a == "services" {
    "\{w}/s/\{s}/services/\{b}"
  } else if n == 2 && (a == "connects" || a == "bots") {
    "\{w}/s/\{s}/connects/\{b}"
  } else if n == 2 && a == "settings" && b == "accounts" {
    "\{w}/s/\{s}/settings/accounts"
  } else if n == 3 && a == "settings" && b == "accounts" {
    "\{w}/s/\{s}/settings/accounts/\{c}"
  } else if n == 2 && a == "settings" && ["connects", "memory", "appearance", "shortcuts"].contains(b) {
    "\{w}/settings/\{b}"
  } else if n == 2 && a == "settings" && b == "device" {
    "\{w}/settings/stations"
  } else if n == 1 && a == "settings" {
    "\{w}/settings"
  } else if n == 1 && a == "new" {
    "\{w}/new"
  } else if n == 1 && a == "archive" {
    "\{w}/archive"
  } else {
    "\{w}/"
  }
  match query {
    Some(q) if q != "" => "\{to}?\{q}"
    _ => to
  }
}

///|
/// The language a browser asks in: `stillfail-lang`, else its Accept-Language's first (`*` names none).
fn lang_of_browser(r : Request) -> String {
  match r.header("stillfail-lang") {
    Some(l) => lang_of(Some(l))
    None => {
      let first = match r.header("accept-language") {
        Some(a) => {
          let mut cut = a.length()
          for i = 0; i < a.length(); i = i + 1 {
            let c = a.unsafe_charcode_at(i)
            if c == ',' || c == ';' {
              cut = i
              break
            }
          }
          a[:cut].to_owned().trim().to_owned()
        }
        None => ""
      }
      lang_of(Some(if first == "*" { "" } else { first }))
    }
  }
}

///|
/// The station's process as it runs.
priv struct Station {
  host : @host.Host
  data : String
  app : String
  version : String
  control : Control
  mut lang : String
  /// cloud.json as it was last read (none: in no workspace).
  mut place : Json?
  mut store : @store_sessions.Store?
  mut up : Bool
  mut health_said : Bool
  mut held_ms : Double
  stopped : @effect.Deferred[String]
  /// What the process before carried over (the launcher's `carried`), as it came.
  mut carried : Json?
  /// What this process holds only in memory, given at a handover (StationParts `carried`): the parts' own.
  /// The parts made in this process (parts.mbt): what they add to what it answers, what they carry over.
  parts : StationParts
  /// Handing over already (what the parts carry being gathered).
  mut handing : Bool
  mut mcp_port : Int?
  mut admin_port : Int?
  mcp_token : String
  /// The composition bus, once the store opened (live_bus.mbt): what the live parts fill in.
  mut bus : LiveBus?
}

///|
fn Station::read_place(self : Station) -> Unit {
  self.place = read_json(path([self.data, "mesh", "cloud.json"]))
}

///|
fn Station::say_health(self : Station) -> Unit {
  if !self.health_said {
    return
  }
  let health : Map[String, Json] = {
    "pid": Json::number(@drive.pid().to_double()),
    "updatedAt": Json::number(wall_ms().to_double()),
    "heldMaxMs": Json::number(self.held_ms.round()),
    "front": Json::string(match self.bus { Some(b) => (b.mesh_front_kind.val)(); None => "direct" }),
    "presenceOnline": Json::boolean(match self.bus { Some(b) => (b.cloud_reached.val)(); None => false }),
    "relayConflict": Json::boolean(match self.bus { Some(b) => (b.mesh_relay_conflict.val)(); None => false }),
  }
  // Its descriptors and resident memory, where the system says them (a leak, a drift seen from outside).
  if open_fds() is Some(n) {
    health["openFds"] = Json::number(n.to_double())
  }
  if self_rss_bytes() is Some(rss) {
    health["rssBytes"] = Json::number(rss.round())
  }
  write_whole(path([self.data, "run", "health.json"]), Json::object(health).stringify() + "\n")
}

///|
/// api/status.ts `statusOf`, of what this process has: the control plane's state as cloud.json says it, the sessions
/// the store says run (no process of its own: none warm), those waiting for a person.
fn Station::status(self : Station) -> Json {
  let text = (k : String) => match self.place {
    Some(Object(m)) =>
      match m.get(k) {
        Some(String(s)) if s != "" => Json::string(s)
        _ => Json::null()
      }
    _ => Json::null()
  }
  let enrolled = text("workspace") != Json::null() &&
    !(self.place is Some(Object(m)) && m.get("removed_at") is Some(Number(_, ..)))
  let running = match self.store {
    Some(s) => attempt(() => s.running_sessions()).unwrap_or([])
    None => []
  }
  let tasks = running.map(r => {
    let f = (k : String) => match r {
      Object(m) => m.get(k).unwrap_or(Json::null())
      _ => Json::null()
    }
    ({
      "session": f("key"),
      "title": f("title"),
      "state": Json::string("working"),
      "since": f("lastActiveAt"),
      "need": Json::null(),
    } : Json)
  })
  let reached = match self.bus {
    Some(b) => (b.cloud_reached.val)()
    None => false
  }
  let front = match self.bus {
    Some(b) => (b.mesh_front_kind.val)()
    None => "direct"
  }
  let status : Map[String, Json] = {
    "version": Json::string(self.version),
    "enrolled": Json::boolean(enrolled),
    "origin": text("origin"),
    "workspace": text("workspace"),
    "workspaceName": text("workspace_name"),
    "station": text("station"),
    "reached": Json::boolean(reached),
    "agents": {
      "busy": Json::number(running.length().to_double()),
      "warm": Json::number(0.0),
      "total": Json::number(running.length().to_double()),
    },
    "waiting": Json::number(0.0),
    "tasks": Json::array(tasks[:if tasks.length() > 50 { 50 } else { tasks.length() }].to_array()),
    "health": { "front": Json::string(front), "presenceOnline": Json::boolean(reached) },
  }
  // (what the agents' side says of its sessions, where it says it)
  match self.bus {
    Some(b) =>
      match (b.status_agents.val)() {
        Some(Object(m)) =>
          for k in ["agents", "waiting", "tasks"] {
            match m.get(k) {
              Some(v) => status[k] = v
              None => ()
            }
          }
        _ => ()
      }
    None => ()
  }
  Json::object(status)
}

///|
/// What `stillfail heap` is answered: what this program holds.
fn Station::heap(self : Station) -> Json {
  {
    "pid": Json::number(@drive.pid().to_double()),
    "version": Json::string(self.version),
    "at": Json::string(iso_time(wall_ms().to_double())),
    "machine": machine(),
    "runtime": { "awaiting": Json::number(self.host.rt.awaiting().to_double()) },
    "doorUrl": match self.parts.door_url() { Some(u) => Json::string(u); None => Json::null() },
    "tools": Json::number(self.parts.all_tools().length().to_double()),
  }
}

///|
/// The agents' door (tools/http.ts): `/mcp` (MCP's JSON-RPC, its token the bearer), `/health`.
async fn Station::door(self : Station, r : Request, conn : Json) -> Reply? {
  let p = r.path()
  if p == "/health" || p == "/mcp" {
    return Some(self.mcp(r))
  }
  // (a part's place on the door: StationParts `door`)
  match self.parts.door_route_of(p) {
    Some(route) => (route.request)(r, conn)
    None => Some(plain(404, ""))
  }
}

///|
/// `/mcp` (MCP's JSON-RPC: its tools the parts'), `/health`.
async fn Station::mcp(self : Station, r : Request) -> Reply {
  if r.path() == "/health" {
    return plain(200, "ok")
  }
  // (the agents' side's own, where it says it: its auth, listings, what is outward, `station_tool`)
  match self.bus {
    Some(b) =>
      match b.mcp_handle.val {
        Some(h) => return h(r)
        None => ()
      }
    None => ()
  }
  guard r.meth == "POST" else { return plain(405, "") }
  let asked = attempt(() => @json.parse(@utf8.decode_lossy(r.body))).unwrap_or(Json::null())
  let id = match asked {
    Object(m) => m.get("id").unwrap_or(Json::null())
    _ => Json::null()
  }
  let meth = match asked {
    { "method": String(m), .. } => m
    _ => ""
  }
  let answer = (result : Json) => json_reply(200, { "jsonrpc": Json::string("2.0"), "id": id, "result": result })
  match meth {
    "initialize" =>
      answer({
        "protocolVersion": Json::string("2025-06-18"),
        "capabilities": { "tools": { "listChanged": Json::boolean(false) } },
        "serverInfo": { "name": Json::string("stillfail"), "version": Json::string(self.version) },
      })
    "notifications/initialized" => { status: 202, headers: [], body: b"" }
    "ping" => answer(Json::object({}))
    "tools/list" => answer({ "tools": Json::array(self.parts.all_tools().map(t => t.declared)) })
    "tools/call" => {
      let params = match asked {
        Object(m) => m.get("params").unwrap_or(Json::object({}))
        _ => Json::object({})
      }
      let name = match params {
        { "name": String(n), .. } => n
        _ => ""
      }
      let args = match params {
        Object(m) => m.get("arguments").unwrap_or(Json::object({}))
        _ => Json::object({})
      }
      match self.parts.all_tools().search_by(t => t.name == name) {
        Some(i) => {
          let tool = self.parts.all_tools()[i]
          let context : Json = { "authorization": match r.header("authorization") { Some(a) => Json::string(a); None => Json::null() } }
          match (try { Ok((tool.call)(args, context)) } catch { e => Err(e) }) {
            Ok(result) => answer(result)
            Err(e) => answer({ "content": [{ "type": "text", "text": Json::string("\{e}") }], "isError": Json::boolean(true) })
          }
        }
        None =>
          json_reply(200, {
            "jsonrpc": Json::string("2.0"),
            "id": id,
            "error": { "code": Json::number(-32602.0), "message": Json::string("no such tool: \{name}") },
          })
      }
    }
    _ =>
      json_reply(200, {
        "jsonrpc": Json::string("2.0"),
        "id": id,
        "error": { "code": Json::number(-32601.0), "message": Json::string("no such method: \{meth}") },
      })
  }
}

///|
/// The status socket's answer (api/status.ts `routeOf`): the status, a stream of it, or nothing.
async fn Station::status_reply(self : Station, r : Request, conn : Json) -> Reply? {
  if r.meth != "GET" {
    return Some(json_reply(404, { "error": Json::string("not found") }))
  }
  match r.path() {
    "/healthz" => Some({ status: 200, headers: [("content-type", "text/plain")], body: b"ok\n" })
    "/v1/status" => {
      let watch = match r.query() {
        Some(q) => q.split("&").map(p => p.to_owned()).to_array().iter().any(kv => kv.has_prefix("watch=") && kv != "watch=0" && kv != "watch=false")
        None => false
      }
      let text = self.status().stringify() + "\n"
      if !watch {
        return Some({ status: 200, headers: [("content-type", "application/json"), ("cache-control", "no-store")], body: @utf8.encode(text) })
      }
      // (a stream: the status now, then each time it changes; this process tells it when its sessions change)
      let head = "HTTP/1.1 200 OK\r\ncontent-type: application/x-ndjson\r\ncache-control: no-store\r\nconnection: close\r\n\r\n"
      if !write_on(self.host, conn, @utf8.encode(head + text)) {
        return None
      }
      let mut last = text
      while !self.stopped.is_done() {
        @effect.sleep(500) // timer: the debounce of a burst (SETTLE_MS), where nothing tells of a change yet
        let now = self.status().stringify() + "\n"
        if now != last {
          last = now
          if !write_on(self.host, conn, @utf8.encode(now)) {
            break
          }
        }
      }
      None
    }
    _ => Some(json_reply(404, { "error": Json::string("not found") }))
  }
}

///|
/// A listener: the launcher's descriptor, or 127.0.0.1 at the first of `tries` that is free; its shell id and port.
async fn listen_on(host : @host.Host, fd : Int?, tries : Array[Int]) -> (Json, Int)? {
  match fd {
    Some(f) =>
      match (try { Ok(host.tcp_listen_fd(f)) } catch { e => Err(e) }) {
        Ok(listening) => Some((listening.id, listening.port))
        Err(_) => None
      }
    None => {
      for port in tries {
        match (try { Ok(host.tcp_listen_local(port)) } catch { e => Err(e) }) {
          Ok(listening) => return Some((listening.id, listening.port))
          Err(_) => ()
        }
      }
      None
    }
  }
}

///|
/// Whether `data` is the machine's own data directory (~/.stillfail): only its station takes the usual ports.
fn own_data(data : String) -> Bool {
  path([homedir(), ".stillfail"]) == @nodepath.join(sep(), [data])
}

///|
/// Stops the process: what it says of itself no longer said, its sessions' file let go of where it is its own.
fn Station::stop(self : Station, why : String) -> Unit {
  if self.stopped.is_done() {
    return
  }
  self.health_said = false
  err_write("station: stopping (\{why})\n")
  match read_json(path([self.data, "run", "hub.json"])) {
    Some({ "pid": Number(p, ..), .. }) if p.to_int() == @drive.pid() => @drive.rm_force(path([self.data, "run", "hub.json"]))
    _ => ()
  }
  ignore(self.stopped.succeed(why))
}

///|
/// At a handover: what this process holds handed to the next (run/handover.json, the launcher's `carry`), then it stops.
async fn Station::hand_over(self : Station) -> Unit {
  if self.stopped.is_done() || self.handing {
    return
  }
  self.handing = true
  // (what the parts carry is gathered first, by part: StationParts `carried`)
  let carried = Json::object(self.parts.carried())
  let sessions = match self.bus {
    Some(b) => (b.handover_sessions.val)()
    None => []
  }
  let handover : Json = {
    "sessions": Json::array(sessions),
    "from": Json::number(@drive.pid().to_double()),
    "at": Json::number(wall_ms().to_double()),
  }
  write_whole(path([self.data, "run", "handover.json"]), handover.stringify())
  if self.control.carries {
    self.control.say({ "carry": carried })
  }
  self.stop("handed over to the next station process")
}

///|
/// The launcher's line (ops/launcher.ts): `carried` kept, an op done.
fn Station::told(self : Station, line : String) -> Unit {
  if line == "" {
    return
  }
  let said = match attempt(() => @json.parse(line)) {
    Ok(j) => j
    Err(_) => {
      // (not the line itself: one carried over holds secrets)
      err_write("launcher: unreadable line from the launcher (\{line.length()} long)\n")
      return
    }
  }
  match said {
    { "op": String("carried"), .. } => {
      let what = match said {
        Object(m) => m.get("carried").unwrap_or(Json::object({}))
        _ => Json::object({})
      }
      self.carried = Some(what)
      // Taken up in a task: the line comes on the host's queue, outside one, and a part's `take` may start work of
      // its own (the vault's saves carried over fork a wait): outside a task that stopped the program, "effect: not
      // inside a task", at the handover from 0.1.9977 to 0.1.9984, so the next process started over as after a crash.
      match what {
        Object(kept) =>
          ignore(self.host.rt.fork_daemon("carried", on_error=e => @host.note("carried failed: \{e}"), async fn() { self.parts.take_up(kept) }))
        _ => ()
      }
    }
    { "op": String("stop"), .. } => self.stop("asked to stop")
    { "op": String("handover"), .. } => ignore(self.host.rt.fork_daemon("handover", on_error=e => @host.note("handover failed: \{e}"), async fn() { self.hand_over() }))
    { "op": String("drain"), .. } =>
      ignore(
        self.host.rt.fork_daemon("drain", on_error=e => @host.note("drain failed: \{e}"), async fn() {
          let d = match self.bus {
            Some(b) => (b.drain_wait.val)()
            None => "idle"
          }
          self.control.say({ "drained": Json::string(d) })
        }),
      )
    { "op": String("hup"), .. } => {
      self.lang = station_lang(self.data)
      self.read_place()
      // (`stillfail update --beta|--stable` asks by SIGHUP, its channel in run/channel-ask: the updates' to answer)
      match self.bus {
        Some(b) =>
          ignore(
            self.host.rt.fork_quiet(name="channel ask", async fn() {
              b.coord_updates_hup() catch {
                _ => ()
              }
            }),
          )
        None => ()
      }
    }
    _ => ()
  }
}

///|
/// `run --app DIR [--port N] [--data DIR] [--launcher-fds a,b,c | --launcher-pipe NAME] …`: the station's process.
pub async fn run_station(host : @host.Host, argv0 : String, args : Array[String]) -> Int {
  guard flag(args, "--app") is Some(app) && app != "" else {
    err_write(usage_text + "\n")
    return 2
  }
  let data = data_dir(args)
  // No child of this process (a runner, a reader, a job) inherits the launcher's channel or anything else it holds:
  // one that did would keep the launcher's pipes open past a handover.
  ignore(keep_descriptors())
  let fds = int_list(flag(args, "--launcher-fds"))
  let pipe = flag(args, "--launcher-pipe")
  let handed_fds = match fds {
    Some(f) => f.length() >= 3
    None => false
  }
  let lang = station_lang(data)
  if !handed_fds && pipe is None && held_by(data, @drive.pid()) is Some(_) {
    err_write(tr(lang, "station.cli.held", args=[("dir", data)]) + "\n")
    return held_exit
  }
  // The essential files read before the launcher is told this process is ready: one another program made unreadable
  // is refused, not taken for defaults.
  let unreadable = [config_path(data), path([data, "mesh", "cloud.json"])].filter(p => read_text(p) is Some(t) &&
    attempt(() => @json.parse(t)) is Err(_))
  if unreadable.length() > 0 {
    let why = "\{unreadable[0]} is not valid JSON"
    if handed_fds || pipe is Some(_) {
      write_whole(path([data, "run", "handoff-error"]), why + "\n")
    }
    err_write(why + "\n")
    return 1
  }
  // The launcher's channel.
  let pipe_conn : Ref[@host.Conn?] = Ref(None)
  match pipe {
    Some(p) =>
      match (try { Ok(host.unix_open(p)) } catch { e => Err(e) }) {
        Ok(conn) => pipe_conn.val = Some(conn)
        Err(_) => {
          err_write("the launcher's pipe \{p} does not open\n")
          return 1
        }
      }
    None => ()
  }
  let control_fd = if handed_fds { Some(fds.unwrap()[2]) } else { None }
  let writes : @effect.Queue[String] = @effect.Queue::unbounded()
  let control : Control = {
    host,
    write: line => match control_fd {
      Some(fd) => ignore(fd_write(fd, @utf8.encode(line)))
      None => ignore(writes.try_offer(line))
    },
    handed: handed_fds || pipe is Some(_),
    mcp_fd: if handed_fds { Some(fds.unwrap()[0]) } else { None },
    loopback_fd: if handed_fds { Some(fds.unwrap()[1]) } else { None },
    ports: match int_list(flag(args, "--launcher-ports")) {
      Some([m, a]) if m > 0 && a > 0 => Some((m, a))
      _ => None
    },
    carries: args.contains("--launcher-carries"),
    heartbeats: args.contains("--launcher-heartbeat"),
    installer: args.contains("--launcher-installer"),
  }
  let token_bytes = @drive.random_bytes(24)
  let s : Station = {
    host,
    data,
    app,
    version: station_version(args, argv0),
    control,
    lang,
    place: None,
    store: None,
    up: false,
    health_said: true,
    held_ms: 0.0,
    stopped: @effect.Deferred::new(),
    carried: None,
    parts: StationParts::new(),
    handing: false,
    mcp_port: None,
    admin_port: None,
    mcp_token: @drive.hex(token_bytes),
    bus: None,
  }
  s.read_place()
  if control.handed {
    // Signals reach the launcher; this process hears of them on the channel.
    ignore_signals()
  } else {
    on_signals(host, name => if name == "SIGTERM" || name == "SIGINT" { s.stop("asked to stop") })
  }
  match control_fd {
    Some(fd) => read_lines(host, fd, line => s.told(line), () => s.stop("the launcher is gone"))
    None => ()
  }
  match pipe_conn.val {
    Some(conn) => {
      ignore(
        host.rt.fork_daemon("launcher pipe out", on_error=e => @host.note("launcher pipe out failed: \{e}"), async fn() {
          while true {
            let line = writes.take()
            conn.socket.write(@utf8.encode(line)) catch {
              _ => ()
            }
          }
        }),
      )
      ignore(
        host.rt.fork_daemon("launcher pipe in", on_error=e => @host.note("launcher pipe in failed: \{e}"), async fn() {
          let carry = StringBuilder()
          while true {
            let bytes = conn.socket.read() catch { _ => break }
            guard bytes is Some(bytes) else { break }
            for ch in @utf8.decode_lossy(bytes) {
              if ch == '\n' {
                s.told(carry.to_string())
                carry.reset()
              } else {
                carry.write_char(ch)
              }
            }
          }
          conn.socket.destroy()
          s.stop("the launcher is gone")
        }),
      )
    }
    None => ()
  }
  // Its key (made where there is none) and its store, the schema made or brought up.
  let key = @cloud_lock.load_key(host, data) catch {
    e => {
      err_write("the station's key: \{e}\n")
      control.say({ "failed": Json::string("the station's key: \{e}") })
      return 1
    }
  }
  ignore(attempt(() => @drive.mkdir(path([data, "run"]), true)))
  // The process holding the sessions before this one, looked for before this one writes its own.
  let previous_pid = held_by_hub(data)
  let db_path = path([data, "stillfail.db"])
  // A lost station's chats brought here, put in before the store opens (main.ts `beforeStore`).
  before_store_p5_1(host, data, db_path)
  let opened = try {
    let db = @sql.Db::create(host, db_path, wait=5000)
    @store_schema.open(db, host, db_path, wall_ms())
    Ok((db, @store_sessions.Store::open(db, () => wall_ms(), 0L)))
  } catch {
    e => Err(e)
  }
  let (db, st) = match opened {
    Ok((db, st)) => {
      s.store = Some(st)
      (db, st)
    }
    Err(e) => {
      err_write("the store does not open: \{e}\n")
      control.say({ "failed": Json::string("the store does not open: \{e}") })
      return 1
    }
  }
  // The live parts, on the bus (live_bus.mbt), each filling in its own.
  let bus = LiveBus::new(
    host,
    argv0,
    args,
    data,
    app,
    s.version,
    key,
    db,
    st,
    s.parts,
    s.stopped,
    control.handed,
    s.mcp_token,
    previous_pid,
    v => control.say(v),
    why => s.stop(why),
    // ops/launcher.ts: the front started again by the launcher, only where it handed its sockets down (Unix's, which
    // keeps a front) and hears this one's heartbeat.
    restart_front?=if control_fd is Some(_) && control.heartbeats {
      Some(() => control.say({ "restartFront": Json::boolean(true) }))
    } else {
      None
    },
    run_installer?=if control.handed && control.installer {
      Some((script, env) => control.say({
        "installer": {
          "script": Json::string(script),
          "env": Json::object(env.map((_, v) => Json::string(v))),
        },
      }))
    } else {
      None
    },
  )
  s.bus = Some(bus)
  start_live_p5_1(bus) catch {
    e => {
      err_write("the station's platform did not start: \{e}\n")
      control.say({ "failed": Json::string("the station's platform did not start: \{e}") })
      return 1
    }
  }
  // How it is said again as the control plane is heard or not (main.ts `sayHealth` on `plane.state.listen`).
  let online = Ref((bus.cloud_reached.val)())
  ignore(
    (bus.cloud_listen.val)(_ => {
      let now = (bus.cloud_reached.val)()
      if now != online.val {
        online.val = now
        s.say_health()
      }
    }),
  )
  // A whole station: the hub first, so the jobs' side finds its sessions' program (`program.has`) and runs `#jobs` and
  // `#remote` there; a station that only runs tasks: its jobs and the devices it reaches, no hub, connects or desktop.
  if bus.as_rig() {
    start_live_p5_3(bus)
    start_live_p5_4(bus, rig=true)
    // (rig/main.ts: its own release kept up to date, by itself and as `stillfail update` asks)
    start_rig_updates(bus)
  } else {
    start_live_p5_2(bus)
    start_live_p5_3(bus)
    start_live_p5_4(bus)
    start_live_p5_5(bus)
  }
  start_live_p5_1_mesh(bus)
  s.say_health()
  s.up = true
  control.say({ "ready": Json::boolean(true), "version": Json::string(s.version) })
  err_write("station: station up (\{s.version}, \{data})\n")
  // The loopback port: the launcher's, or 4760 on the machine's own data directory, else any free one.
  let named_port = match flag(args, "--port") {
    Some(p) => attempt(() => @string.parse_int(p)).to_option()
    None => None
  }
  let loopback_tries = match (control.ports, named_port) {
    (Some(_), _) => [0]
    (None, Some(p)) => [p]
    (None, None) => if own_data(data) { [4760, 0] } else { [0] }
  }
  match listen_on(host, control.loopback_fd, loopback_tries) {
    Some((id, port)) => {
      let shown = match control.ports {
        Some((_, admin)) => admin
        None => port
      }
      s.admin_port = Some(shown)
      write_whole(path([data, "run", "ports.json"]), "{\"admin\":\{shown}}\n")
      control.say({ "serving": Json::string("admin"), "port": Json::number(port.to_double()) })
      ignore(
        host.rt.fork_daemon("loopback", on_error=e => @host.note("loopback failed: \{e}"), async fn() {
          serve_http(host, id, async fn(r, _conn) {
            Some(loopback_answer(r.path(), r.query(), s.up && !s.stopped.is_done(), s.place, lang_of_browser(r)))
          })
        }),
      )
    }
    None => err_write("station: the loopback port is not had\n")
  }
  // The local status's socket (Unix's: a path in the data directory, the station's user's alone).
  if !is_windows() {
    let sock = path([data, "run", "status.sock"])
    match (try { Ok(host.unix_listen(sock)) } catch { e => Err(e) }) {
      Ok(listening) =>
        ignore(
          host.rt.fork_daemon("status", on_error=e => @host.note("status failed: \{e}"), async fn() { serve_http(host, listening.id, async fn(r, conn) { s.status_reply(r, conn) }) }),
        )
      Err(_) => err_write("station: the local status's socket is not had\n")
    }
  }
  // The agents' door, once the process before is gone (the one handing over writes its handover first).
  ignore(
    host.rt.fork_daemon("agents' door", on_error=e => @host.note("agents' door failed: \{e}"), async fn() {
      let mut waited = 0
      // (as the bus's `previous_gone`: the process before gone by its pid, PREVIOUS_LIMIT_MS at most)
      while (previous_pid.map(pid_alive).unwrap_or(false) || held_by_hub(data) is Some(_)) && waited < 200 && !s.stopped.is_done() {
        // (still taking over, and getting on with it: said now and then, the launcher's limit far off)
        if waited % 25 == 0 {
          control.say({ "taking": Json::boolean(true) })
        }
        waited += 1
        @effect.sleep(200) // timer: a retry until the process before is gone (it says nothing when it ends)
      }
      if s.stopped.is_done() {
        return
      }
      write_whole(path([data, "run", "hub.json"]), "{\"pid\":\{@drive.pid()}}\n")
      let handover = path([data, "run", "handover.json"])
      let handed_over = read_json(handover)
      if read_text(handover) is Some(_) {
        control.say({ "taking": Json::boolean(true) })
        @drive.rm_force(handover)
      }
      let remembered = match read_json(path([data, "run", "mcp.json"])) {
        Some({ "port": Number(p, ..), .. }) if p > 0.0 && p < 65536.0 => Some(p.to_int())
        _ => None
      }
      let tries = match control.ports {
        Some(_) => [0]
        None => {
          let t = []
          match remembered {
            Some(r) => t.push(r)
            None => ()
          }
          if own_data(data) {
            t.push(4750)
          }
          t.push(0)
          t
        }
      }
      match listen_on(host, control.mcp_fd, tries) {
        Some((id, port)) => {
          let shown = match control.ports {
            Some((m, _)) => m
            None => port
          }
          s.mcp_port = Some(shown)
          let url = "http://127.0.0.1:\{shown}/mcp"
          s.parts.door_open(url)
          write_whole(path([data, "run", "mcp.json"]), "{\"port\":\{shown}}\n")
          control.say({ "serving": Json::string("mcp"), "port": Json::number(port.to_double()) })
          ignore(bus.door_ready.succeed(url))
          ignore(host.rt.fork_daemon("take handover", on_error=e => @host.note("take handover failed: \{e}"), async fn() { (bus.take_handover.val)(handed_over) }))
          serve_http(host, id, async fn(r, conn) { s.door(r, conn) })
        }
        None => {
          control.say({ "failed": Json::string("the agents' door is not had") })
          s.stop("the agents' door is not had")
        }
      }
    }),
  )
  // How it is, said every HELD_EVERY_MS from its loop: health.json, the launcher's heartbeat, `stillfail heap`.
  ignore(
    host.rt.fork_daemon("heartbeat", on_error=e => @host.note("heartbeat failed: \{e}"), async fn() {
      let every = held_every_ms()
      while !s.stopped.is_done() {
        let started = @host.now()
        @effect.sleep(every) // timer: a sample of this thread (main.ts HELD_EVERY_MS)
        let late = (@host.now() - started).to_double() - every.to_double()
        s.held_ms = if late > 0.0 { late } else { 0.0 }
        if s.stopped.is_done() {
          break
        }
        if control.heartbeats {
          control.say({ "heartbeat": Json::boolean(true) })
        }
        s.say_health()
        ignore(answer_heap_request(data, () => s.heap()))
      }
    }),
  )
  // A heap request left while no station ran.
  ignore(answer_heap_request(data, () => s.heap()))
  let why = s.stopped.wait()
  ignore(why)
  // (what the live parts started let go of before the process ends: their processes, what they hand over)
  stop_live_p5_1()
  live_p5_1_handed()
  // (what the agents' side ends as the station stops, not handing over: its sessions' processes)
  match s.bus {
    Some(b) => ignore(@effect.timeout(10_000, async fn() { b.hub_shutdown() }))
    None => ()
  }
  // (the P5-5 parts closed on their own as it stopped: their processes ended before this one, not after)
  wait_live_p5_5_closed()
  0
}

///|
/// The process holding the sessions before this one (run/hub.json's), still there.
fn held_by_hub(data : String) -> Int? {
  match read_json(path([data, "run", "hub.json"])) {
    Some({ "pid": Number(p, ..), .. }) if p == p.floor() && p > 0.0 && p.to_int() != @drive.pid() && pid_alive(p.to_int()) =>
      Some(p.to_int())
    _ => None
  }
}
