// station/src/ops/launcher.ts, restart.ts, previous.ts, health.ts: the control channel with native/launcher (one JSON
// line each way: what this process says, what it is told), asking it to hand over, the process before this one, and
// what the station says of itself for `stillfail status`.

///|
/// files.ts `flag`: the value after `name` in argv, wherever it is.
pub fn flag(args : Array[String], name : String) -> String? {
  match args.search_by(a => a == name) {
    Some(i) => args.get(i + 1)
    None => None
  }
}

///|
/// launcher.ts: how this process was started by its launcher (`--launcher-fds a,b,c` handed down on Unix, a
/// `--launcher-pipe` on Windows; neither: on its own).
pub struct LauncherArgs {
  /// The three descriptors handed down: the MCP listener, the loopback listener, the control channel.
  fds : (Double, Double, Double)?
  pipe : String?
  /// The launcher's own ports where it holds them (Windows).
  ports : (Double, Double)?
  carries : Bool
  heartbeats : Bool
}

///|
/// launcher.ts `launcher`'s reading of its arguments.
pub fn launcher_args(args : Array[String]) -> LauncherArgs {
  let fds = match flag(args, "--launcher-fds") {
    Some(f) => Some(split_on(f, ",").map(js_number))
    None => None
  }
  let handed = match fds {
    Some(f) => f.length() >= 3 && !f.iter().any(n => !is_integer(n))
    None => false
  }
  let pipe = flag(args, "--launcher-pipe")
  let given = match flag(args, "--launcher-ports") {
    Some(p) => Some(split_on(p, ",").map(js_number))
    None => None
  }
  let ports = match given {
    Some(g) if g.length() == 2 && g.iter().all(n => is_integer(n) && n > 0.0) => Some((g[0], g[1]))
    _ => None
  }
  {
    fds: if handed {
      let f = fds.unwrap()
      Some((f[0], f[1], f[2]))
    } else {
      None
    },
    pipe,
    ports,
    carries: args.contains("--launcher-carries"),
    heartbeats: args.contains("--launcher-heartbeat"),
  }
}

///|
/// Whether there is a launcher to talk to: descriptors handed down, or its pipe.
pub fn LauncherArgs::linked(self : LauncherArgs) -> Bool {
  self.fds is Some(_) || self.pipe is Some(_)
}

///|
pub fn LauncherArgs::to_json(self : LauncherArgs) -> Json {
  let m : Map[String, Json] = Map([])
  m["linked"] = jb(self.linked())
  match self.fds {
    Some((a, b, _)) if self.linked() => {
      m["mcpFd"] = jn(a)
      m["loopbackFd"] = jn(b)
    }
    _ => ()
  }
  if self.linked() {
    match self.ports {
      Some((mcp, admin)) => m["ports"] = { "mcp": jn(mcp), "admin": jn(admin) }
      None => ()
    }
  }
  m["carries"] = jb(self.linked() && self.carries)
  m["restartFront"] = jb(self.fds is Some(_) && self.heartbeats)
  Json::object(m)
}

///|
/// What this process says to its launcher, a line each (launcher.ts `Control`): written as JSON.stringify writes it.
pub(all) enum Said {
  Ready(String)
  Serving(String, Double)
  Taking
  Failed(String)
  Drained(String)
  Carry(Json)
  Heartbeat
  RestartFront
}

///|
/// The line `said` is, with its newline; None where this launcher would not take it (a carry or a heartbeat to one
/// that did not ask for them, a front's restart where it hands down no descriptors).
pub fn said_line(a : LauncherArgs, said : Said) -> String? {
  if !a.linked() {
    return None
  }
  let value : Json = match said {
    Ready(version) => { "ready": true, "version": js(version) }
    Serving(name, port) => { "serving": js(name), "port": jn(port) }
    Taking => { "taking": true }
    Failed(why) => { "failed": js(why) }
    Drained(how) => { "drained": js(how) }
    Carry(what) => if a.carries { { "carry": what } } else { return None }
    Heartbeat => if a.heartbeats { { "heartbeat": true } } else { return None }
    RestartFront =>
      if a.fds is Some(_) && a.heartbeats {
        { "restartFront": true }
      } else {
        return None
      }
  }
  Some(js_stringify(value) + "\n")
}

///|
/// What the launcher tells this process, as its lines come (launcher.ts's `data` handler): an op, or what the process
/// before carried over, or a line that does not read (only its length is said: a carried one holds secrets).
pub(all) enum Told {
  Op(String)
  /// A line with no op a handler is named by (a number's, an array's, none).
  NoOp
  Carried(Json)
  Unreadable(Int)
}

///|
/// The control channel's reading: bytes as they come, put together into lines.
pub struct ControlReader {
  mut carry : String
}

///|
pub fn ControlReader::new() -> ControlReader {
  { carry: "" }
}

///|
/// What a chunk of the channel completes.
pub fn ControlReader::feed(self : ControlReader, chunk : String) -> Array[Told] {
  self.carry = self.carry + chunk
  let out = []
  while true {
    let at = index_of(self.carry, "\n")
    if at < 0 {
      break
    }
    let line = sub(self.carry, 0, at)
    self.carry = sub(self.carry, at + 1, self.carry.length())
    // A launcher taking over from one before it ends with a newline what that one may have left halfway (run.rs).
    if line == "" {
      continue
    }
    match js_parse(line) {
      // (`said.op` of a value that is no object: undefined, a handler of none)
      Some(said) =>
        match said {
          Null => out.push(Unreadable(line.length()))
          Object(_) =>
            match field(said, "op") {
              Some(String("carried")) =>
                out.push(
                  Carried(match field(said, "carried") {
                    Some(Null) | None => Json::object(Map([]))
                    Some(v) => v
                  }),
                )
              Some(String(op)) => out.push(Op(op))
              _ => out.push(NoOp)
            }
          _ => out.push(NoOp)
        }
      None => out.push(Unreadable(line.length()))
    }
  }
  out
}

///|
/// launcher.ts `carried`: what came before anyone took it is given to the taker once it is there.
pub struct CarriedBox {
  mut came : Json?
  taken : Array[Json]
  mut taker : Bool
}

///|
pub fn CarriedBox::new() -> CarriedBox {
  { came: None, taken: [], taker: false }
}

///|
pub fn CarriedBox::told(self : CarriedBox, what : Json) -> Unit {
  if self.taker {
    self.taken.push(what)
  } else {
    self.came = Some(what)
  }
}

///|
pub fn CarriedBox::take(self : CarriedBox) -> Unit {
  self.taker = true
  match self.came {
    Some(c) => self.taken.push(c)
    None => ()
  }
  self.came = None
}

// ── restart.ts ───────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// restart.ts `restarter`: the launcher's pid to ask, from run/station.json's text (None: no file), where it says
/// `handoff: 1` and the process is a launcher (`is_launcher`).
pub fn restarter_pid(text : String?, is_launcher : (Double) -> Bool) -> Double? {
  guard text is Some(t) else { return None }
  guard js_parse(t) is Some(said) else { return None }
  let pid = match num_field(said, "pid") {
    Some(p) if is_safe_integer(p) && p > 0.0 => Some(p)
    _ => None
  }
  guard pid is Some(p) else { return None }
  match field(said, "handoff") {
    Some(Number(n, ..)) if n == 1.0 => ()
    _ => return None
  }
  if !is_launcher(p) {
    return None
  }
  Some(p)
}

///|
pub let front_after_ms : Double = 150.0

///|
/// restart.ts `pageRestart`: what the page's restart does: nothing (no launcher), the handover alone, or the front's
/// restart FRONT_AFTER_MS later, the Node handed over with it.
pub fn page_restart(handover : Bool, restart_front : Bool) -> String {
  if !handover {
    "none"
  } else if !restart_front {
    "handover"
  } else {
    "front"
  }
}

// ── previous.ts ──────────────────────────────────────────────────────────────────────────────────────────────────

///|
pub let previous_limit_ms : Double = 40000.0

///|
/// previous.ts `previousProcess`: the process that held the sessions, from run/hub.json's text, not this one.
pub fn previous_pid(text : String?, self_pid : Double) -> Double? {
  guard text is Some(t) else { return None }
  match js_parse(t) {
    Some(Object(_) as j) =>
      match field(j, "pid") {
        Some(Number(p, ..)) if p != self_pid => Some(p)
        _ => None
      }
    _ => None
  }
}

// ── health.ts ────────────────────────────────────────────────────────────────────────────────────────────────────

///|
pub let health_fresh_ms : Double = 60000.0

///|
/// health.ts `healthPath`.
pub fn health_path(data : String, join : (Array[String]) -> String) -> String {
  join([data, "run", "health.json"])
}

///|
/// health.ts `healthOf`: what the file says, where it reads as such.
pub fn health_of(h : Json) -> Json? {
  guard h is Object(_) else { return None }
  let pid = match field(h, "pid") {
    Some(Number(p, ..)) if is_integer(p) => p
    _ => return None
  }
  let updated = match field(h, "updatedAt") {
    Some(Number(u, ..)) => u
    _ => return None
  }
  let front = match field(h, "front") {
    Some(String(f)) if f == "ok" || f == "reconnecting" || f == "direct" => f
    _ => return None
  }
  let m : Map[String, Json] = {
    "pid": jn(pid),
    "updatedAt": jn(updated),
    "heldMaxMs": jn(num_field(h, "heldMaxMs").unwrap_or(0.0)),
    "front": js(front),
    "presenceOnline": jb(bool_field(h, "presenceOnline")),
  }
  if bool_field(h, "relayConflict") {
    m["relayConflict"] = jb(true)
  }
  Some(Json::object(m))
}

///|
/// health.ts `workingOf`.
pub fn working_of(
  running : Bool,
  health : Json?,
  health_alive : Bool,
  online : Bool,
  conflict : Bool,
  now : Double,
) -> Json {
  if !running {
    return { "is": "stopped" }
  }
  match health {
    Some(h) if health_alive => {
      let silent = now - num_field(h, "updatedAt").unwrap_or(0.0)
      if silent > health_fresh_ms {
        return { "is": "unresponsive", "silentMs": jn(silent) }
      }
      if str_field(h, "front") == Some("reconnecting") {
        return { "is": "front" }
      }
      if bool_field(h, "relayConflict") {
        return { "is": "conflict" }
      }
    }
    _ => ()
  }
  if conflict {
    return { "is": "conflict" }
  }
  if !online {
    return { "is": "offline" }
  }
  { "is": "normal" }
}

///|
/// health.ts `writeHealth`: the text written (a line of JSON).
pub fn health_text(health : Json) -> String {
  js_stringify(health) + "\n"
}
