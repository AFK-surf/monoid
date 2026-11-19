// The agents' side (P5-2): the station's one MoonBit program for its sessions (`stillfail-reader --sessions`, this very
// binary, agents/mb-program.ts `SessionsProgram`): the agents' output read (reader/agents.mbt, mb-agents.ts
// `AgentsHost`) and the sessions' actors (reader/actors.mbt, sessions/mb-actor.ts `ActorsProgram`) in one process, each
// part told what the program says of it (the actors' lines say `active`). A process under a runner as the drivers have
// it (`HostedProcess`, agent_drivers `Proc`) is started here (runner.ts `startRunner`) and read there. The reader is a
// package that imports this one, so the program is a process of its own, as it is to Node.

///|
/// What the program said: its line, and the bytes after it where it said `bytes` (main.mbt `say_answer`).
priv struct ProgramSaid {
  head : Json
  body : Bytes?
}

///|
priv struct ProgramUser {
  actors : Bool
  said : (ProgramSaid) -> Unit
  exited : (Int) -> Unit
}

///|
/// The program for the data directory's sessions.
priv struct SessionsProgram {
  host : @host.Host
  argv0 : String
  data : String
  mut proc : Proc?
  users : Array[ProgramUser]
  mut ended : Bool
  /// What was said to it before it was started (it starts with its first user).
  waiting : Array[String]
}

///|
fn SessionsProgram::new(host : @host.Host, argv0 : String, data : String) -> SessionsProgram {
  { host, argv0, data, proc: None, users: [], ended: false, waiting: [] }
}

///|
/// Started once (again, after it ended, for the next who uses it).
fn SessionsProgram::ensure(self : SessionsProgram) -> Unit {
  if self.proc is Some(_) && !self.ended {
    return
  }
  self.ended = false
  let p = spawn(
    self.host,
    self.argv0,
    ["--sessions", "1", "--data", self.data, "--sep", sep()],
    stdin_piped=true,
    stdout=Piped,
    stderr=Appended(path([self.data, "run", "sessions-program.err"])),
  ) catch {
    e => {
      live_log("error", "agents", "the sessions' program did not start", { "error": jstr(said_of(e)) })
      self.ended = true
      return
    }
  }
  self.proc = Some(p)
  for line in self.waiting {
    ignore(p.write(@utf8.encode(line)))
  }
  self.waiting.clear()
  ignore(
    self.host.rt.fork_daemon("sessions' program", on_error=e => @host.note("sessions' program failed: \{e}"), async fn() {
      let carry = @buffer.Buffer()
      let mut head : Json? = None
      let mut wanted = 0
      let body = @buffer.Buffer()
      while true {
        match p.events.take() {
          Out(bytes) => {
            let mut at = 0
            let n = bytes.length()
            while at < n {
              match head {
                Some(h) => {
                  let take = if wanted - body.length() < n - at { wanted - body.length() } else { n - at }
                  body.write_bytes(bytes[at:at + take].to_owned())
                  at += take
                  if body.length() >= wanted {
                    let b = body.to_bytes()
                    body.reset()
                    head = None
                    self.tell({ head: h, body: Some(b) })
                  }
                }
                None => {
                  let mut end = -1
                  for i = at; i < n; i = i + 1 {
                    if bytes[i] == b'\n' {
                      end = i
                      break
                    }
                  }
                  if end < 0 {
                    carry.write_bytes(bytes[at:n].to_owned())
                    at = n
                  } else {
                    carry.write_bytes(bytes[at:end].to_owned())
                    at = end + 1
                    let line = @utf8.decode_lossy(carry.to_bytes())
                    carry.reset()
                    if line != "" {
                      match attempt(() => @json.parse(line)) {
                        Ok(Object(m) as parsed) =>
                          match m.get("bytes") {
                            Some(Number(k, ..)) if k >= 0.0 && k == k.floor() => {
                              let rest : Map[String, Json] = Map([])
                              for kv in m {
                                if kv.0 != "bytes" {
                                  rest[kv.0] = kv.1
                                }
                              }
                              if k == 0.0 {
                                self.tell({ head: Json::object(rest), body: Some(b"") })
                              } else {
                                head = Some(Json::object(rest))
                                wanted = k.to_int()
                              }
                            }
                            _ => self.tell({ head: parsed, body: None })
                          }
                        Ok(other) => self.tell({ head: other, body: None })
                        Err(_) =>
                          live_log("warn", "readers", "a MoonBit program said what is not JSON", { "line": jstr(clip(line, 200)) })
                      }
                    }
                  }
                }
              }
            }
          }
          Err(_) => ()
          Exit(code, _) => {
            let asked = self.ended
            self.ended = true
            self.proc = None
            if !asked {
              for u in self.users.copy() {
                (u.exited)(code.unwrap_or(-1))
              }
            }
            break
          }
        }
      }
    }),
  )
}

///|
fn SessionsProgram::tell(self : SessionsProgram, said : ProgramSaid) -> Unit {
  if said.head is { "ready": True, .. } {
    return
  }
  let actors = said.head is Object(m) && m.contains("active")
  for u in self.users.copy() {
    if u.actors == actors {
      (u.said)(said)
    }
  }
}

///|
fn SessionsProgram::use_by(self : SessionsProgram, user : ProgramUser) -> Unit {
  self.users.push(user)
  self.ensure()
}

///|
/// Said to it, a line of JSON (what waits for it to start waits in its stdin).
fn SessionsProgram::post(self : SessionsProgram, message : Json) -> Unit {
  let line = message.stringify() + "\n"
  match self.proc {
    Some(p) if !self.ended => ignore(p.write(@utf8.encode(line)))
    _ => self.waiting.push(line)
  }
}

///|
/// `user` lets it go: it ends once none uses it.
fn SessionsProgram::release(self : SessionsProgram, actors : Bool) -> Unit {
  match self.users.search_by(u => u.actors == actors) {
    Some(i) => ignore(self.users.remove(i))
    None => ()
  }
  if self.users.length() > 0 || self.ended {
    return
  }
  self.ended = true
  match self.proc {
    Some(p) => {
      p.end_input()
      ignore(kill(p.pid, "SIGTERM"))
    }
    None => ()
  }
  self.proc = None
}

///|
/// Ended at once (the station's process ends).
fn SessionsProgram::kill_now(self : SessionsProgram) -> Unit {
  self.ended = true
  match self.proc {
    Some(p) => ignore(kill(p.pid, "SIGKILL"))
    None => ()
  }
  self.proc = None
}

// ── the runner ──

///|
/// A program named by its command (not a path) that the environment's PATH does not have (runner.ts `CommandMissing`).
pub(all) suberror CommandMissing {
  CommandMissing(String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for CommandMissing with output(self, logger) {
  match self {
    CommandMissing(command) => logger.write_string("the runner did not start: \{command} is not on PATH")
  }
}

///|
/// The runner binary (platform/processes.ts `runnerBinary`): STILLFAIL_RUNNER, else beside the station's program in a
/// release (`<app>/bin`, where the program is `<app>/station/stillfail-reader` or `<app>/bin/…`), else where its cargo
/// builds it in a checkout (`station/native/runner/target/release`); on Windows run from a copy kept in `<data>/run/bin`
/// (`keepRunnerIn`): the installer ends every process whose executable is in the app's directory.
pub fn runner_binary(app : String, argv0 : String, data : String) -> String? {
  let name = if is_windows() { "stillfail-runner.exe" } else { "stillfail-runner" }
  let s = sep()
  let real = attempt(() => @drive.realpath(argv0)).unwrap_or(argv0)
  let here = @nodepath.dirname(s, real)
  let up = @nodepath.dirname(s, here)
  let candidates : Array[String] = []
  match env_get("STILLFAIL_RUNNER") {
    Some(r) if r != "" => candidates.push(r)
    _ => ()
  }
  candidates.push(path([app, "bin", name]))
  candidates.push(path([here, name]))
  candidates.push(path([up, "bin", name]))
  // (a checkout: the program at station/mb/target/<target>/stillfail-reader, the runner cargo's)
  let mut dir = here
  for _ in 0..<6 {
    candidates.push(path([dir, "station", "native", "runner", "target", "release", name]))
    candidates.push(path([dir, "native", "runner", "target", "release", name]))
    dir = @nodepath.dirname(s, dir)
  }
  guard candidates.iter().find_first(c => attempt(() => @drive.stat(c)) is Ok(st) && st.file) is Some(found) else {
    return None
  }
  if !is_windows() {
    return Some(found)
  }
  Some(runner_copy(found, path([data, "run", "bin"])))
}

///|
/// A Windows runner's copy in `dir`, named by what it holds: one release's runner is one file, whichever station copied
/// it; copies no runner runs from removed (processes.ts `RunnerCopies`).
fn runner_copy(source : String, dir : String) -> String {
  guard attempt(() => @drive.read_all(source)) is Ok(b) else { return source }
  let hash = @drive.hex(@drive.sha256_bytes(b))[:16].to_owned()
  let copy = path([dir, "stillfail-runner-\{hash}.exe"])
  if attempt(() => @drive.stat(copy)) is Ok(_) {
    return copy
  }
  // (others of releases before, where nothing runs from them: Windows does not let a running one go)
  match attempt(() => @drive.names(dir)) {
    Ok(names) =>
      for n in names {
        if n.has_prefix("stillfail-runner-") {
          ignore(attempt(() => @drive.unlink(path([dir, n]))))
        }
      }
    Err(_) => ()
  }
  ignore(attempt(() => @drive.mkdir(dir, true)))
  let part = copy + ".\{@drive.pid()}.part"
  match attempt(() => copy_file_over(source, part)) {
    Ok(_) =>
      match attempt(() => @drive.rename(part, copy)) {
        Ok(_) => copy
        Err(_) => {
          ignore(attempt(() => @drive.unlink(part)))
          if attempt(() => @drive.stat(copy)) is Ok(_) { copy } else { source }
        }
      }
    Err(_) => source
  }
}

///|
/// Where `name` is on `env`'s PATH (platform `findCommandSoon`), none where it is not.
fn find_command(name : String, env : Array[(String, String)]) -> String? {
  let p = match env.iter().find_first(kv => kv.0 == "PATH" || (is_windows() && kv.0.to_upper() == "PATH")) {
    Some(kv) => kv.1
    None => return None
  }
  // (Windows: by PATHEXT, as windows.ts `findCommand`: a bare name tried first found npm's POSIX script `codex` beside
  // `codex.cmd`, which no Windows process runs)
  if is_windows() {
    return @ops_platform.win_find_command(name, env, ";", path, executable)
  }
  for d in p.split(":") {
    let dir = if d == "" { "." } else { d.to_owned() }
    let on = path([dir, name])
    if executable(on) {
      return Some(on)
    }
  }
  None
}

///|
/// How much lower than the station what the agents start runs (ops/nice.ts `agentNice`): STILLFAIL_AGENT_NICE, else 10.
fn agent_nice() -> Int {
  match env_get("STILLFAIL_AGENT_NICE") {
    Some(t) =>
      match attempt(() => @string.parse_int(t)) {
        Ok(n) if n >= 0 && n <= 19 => n
        _ => 10
      }
    None => 10
  }
}

///|
/// Starts `program` under a runner (runner.ts `startRunner`): its environment `env` (the agent's whole), in `cwd`; its
/// info once it said it is ready.
async fn start_runner(
  host : @host.Host,
  runner : String,
  data : String,
  id : String,
  program : String,
  args : Array[String],
  env : Array[(String, String)],
  cwd : String,
) -> Json {
  let named = program.contains("/") || program.contains("\\")
  if !named && find_command(program, env) is None {
    raise CommandMissing(program)
  }
  let given = ["--dir", path([data, "run", "runners"]), "--id", id, "--cwd", cwd, "--", program, ..args]
  // (lower than the station: ops/nice.ts)
  let nice = agent_nice()
  let (command, all_args) = if !is_windows() && nice > 0 && attempt(() => @drive.stat("/usr/bin/nice")) is Ok(_) {
    ("/usr/bin/nice", ["-n", nice.to_string(), runner, ..given])
  } else {
    (runner, given)
  }
  let child = spawn(host, command, all_args, env~, stdout=Piped, stderr=Piped, group=true)
  let (_, _, out, err) = child.finished()
  let text = @utf8.decode_lossy(out)
  for line in text.split("\n") {
    let l = line.to_owned()
    if l.has_prefix("{") {
      match attempt(() => @json.parse(l)) {
        Ok({ "ready": True, .. } as ready) => return ready
        _ => ()
      }
    }
  }
  let why = @utf8.decode_lossy(err).trim().to_owned()
  raise LiveError("the runner did not start: \{if why == "" { text.trim().to_owned() } else { why }}")
}

// ── the agents' processes read by the program (mb-agents.ts) ──

///|
/// What takes a batch the program keeps for the actor in the same program (mb-agents.ts `Router`): told the batch;
/// false: it was not, so it is acknowledged as before.
priv struct Router {
  took : (Int) -> Bool
}

///|
/// Every runtime's processes read by the program (mb-agents.ts `AgentsHost`).
priv struct AgentsHost {
  pump : Pump
  program : SessionsProgram
  mut on : Bool
  mut next : Int
  sessions : Map[Int, HostedProcess]
  freezes : Map[Int, @effect.Deferred[Json]]
  replays : Map[Int, @effect.Deferred[Json]?]
  own_replays : Map[Int, @effect.Deferred[Json]]
  held : Array[Int]
  mut closed : Bool
}

///|
fn AgentsHost::new(pump : Pump, program : SessionsProgram) -> AgentsHost {
  {
    pump,
    program,
    on: false,
    next: 0,
    sessions: Map([]),
    freezes: Map([]),
    replays: Map([]),
    own_replays: Map([]),
    held: [],
    closed: false,
  }
}

///|
fn AgentsHost::number(self : AgentsHost) -> Int {
  self.next += 1
  self.next
}

///|
/// The program used (started where it is not): what is said before it is ready waits in its stdin.
fn AgentsHost::ensure(self : AgentsHost) -> Unit raise LiveError {
  if self.closed {
    raise LiveError("the station's agents were let go: no process is read any more")
  }
  if self.on {
    return
  }
  self.on = true
  self.program.use_by({ actors: false, said: s => self.said(s), exited: code => self.exited(code) })
  self.post({ "wall": jn(wall_ms().to_double()) })
}

///|
fn AgentsHost::post(self : AgentsHost, message : Json) -> Unit {
  if self.on {
    self.program.post(message)
  }
}

///|
fn AgentsHost::exited(self : AgentsHost, code : Int) -> Unit {
  if self.closed {
    return
  }
  live_log("warn", "agents", "the program reading agents ended; starting it again", { "code": ji(code) })
  self.on = false
  self.settle()
  let again = self.sessions.values().to_array()
  ignore(
    self.pump.host.rt.fork_daemon("agents' program again", on_error=e => @host.note("agents' program again failed: \{e}"), async fn() {
      // timer: a retry after a failure, with a backoff (one that keeps ending is started again each second at most)
      @effect.sleep(1000)
      if self.closed {
        return
      }
      for p in again {
        if !p.gone {
          self.attach(p)
        }
      }
      let held = again.filter(p => !p.gone && self.held.contains(p.n))
      if held.length() > 0 {
        self.post({ "freeze": ji(self.number()), "only": Json::array(held.map(p => ji(p.n))) })
      }
    }),
  )
}

///|
fn AgentsHost::said(self : AgentsHost, said : ProgramSaid) -> Unit {
  let h = said.head
  match jnum_of(h, "ownReplayed") {
    Some(id) => {
      match self.own_replays.get(id.to_int()) {
        Some(d) => ignore(d.succeed(h))
        None => ()
      }
      self.own_replays.remove(id.to_int())
      self.idle_if_none()
      return
    }
    None => ()
  }
  match jnum_of(h, "replayed") {
    Some(id) => {
      match self.replays.get(id.to_int()) {
        Some(Some(d)) => ignore(d.succeed(match jfield(h, "live") { Null => Json::object({}); l => l }))
        _ => ()
      }
      self.replays.remove(id.to_int())
      self.idle_if_none()
      return
    }
    None => ()
  }
  match jnum_of(h, "frozen") {
    Some(id) => {
      match self.freezes.get(id.to_int()) {
        Some(d) => ignore(d.succeed(match jfield(h, "states") { Null => Json::object({}); s => s }))
        None => ()
      }
      self.freezes.remove(id.to_int())
      return
    }
    None => ()
  }
  let n = match (jnum_of(h, "lines"), jnum_of(h, "exit"), jnum_of(h, "closed"), jnum_of(h, "left"), jnum_of(h, "ended")) {
    (Some(n), _, _, _, _) | (_, Some(n), _, _, _) | (_, _, Some(n), _, _) | (_, _, _, Some(n), _) | (_, _, _, _, Some(n)) =>
      n.to_int()
    _ => return
  }
  guard self.sessions.get(n) is Some(p) else { return }
  if jnum_of(h, "lines") is Some(_) {
    let lines : Array[Json] = []
    match jfield(h, "at") {
      Array(at) => {
        let body = said.body.unwrap_or(b"")
        let mut from = 0
        for a in at {
          match a {
            Array([Number(f, ..), Number(t, ..), Number(len, ..), ..]) => {
              let l = len.to_int()
              let end = if from + l <= body.length() { from + l } else { body.length() }
              let text = @utf8.decode_lossy(body[from:end].to_owned())
              from = end
              lines.push({ "text": jstr(text), "from": jn(f), "to": jn(t) })
            }
            _ => ()
          }
        }
      }
      _ => ()
    }
    let heard : Map[String, Json] = Map([])
    heard["events"] = match jfield(h, "events") {
      Array(_) as e => e
      _ => Json::array([])
    }
    heard["turn"] = jfield(h, "turn")
    heard["to"] = jfield(h, "to")
    if lines.length() > 0 || jfield(h, "at") is Array(_) {
      heard["lines"] = Json::array(lines)
    }
    match jfield(h, "batch") {
      Number(_) as b => heard["batch"] = b
      _ => ()
    }
    match jfield(h, "marks") {
      Array(_) as m => heard["marks"] = m
      _ => ()
    }
    match jfield(h, "threads") {
      Array(_) as t => heard["threads"] = t
      _ => ()
    }
    p.heard(Json::object(heard))
  } else if jnum_of(h, "exit") is Some(_) {
    let code = jnum_of(h, "code").map(c => c.to_int())
    let signal = jtext(h, "signal")
    let stderr = jtext(h, "stderr").unwrap_or("")
    p.in_turn(() => p.exited_(code, signal, stderr))
  } else if jnum_of(h, "closed") is Some(_) {
    let stderr = jtext(h, "stderr").unwrap_or("")
    p.in_turn(() => p.closed_(stderr))
  } else if jnum_of(h, "ended") is Some(_) {
    p.in_turn(() => {
      self.forget(p)
      @agent_drivers.done(self.pump.lp)
    })
  } else {
    p.in_turn(() => {
      p.left_()
      @agent_drivers.done(self.pump.lp)
    })
  }
}

///|
/// Reads `p`'s process (again, after the program started again: from where it was acknowledged).
fn AgentsHost::attach(self : AgentsHost, p : HostedProcess) -> Unit {
  self.ensure() catch {
    _ => return
  }
  self.sessions[p.n] = p
  let m : Map[String, Json] = Map([])
  m["attach"] = ji(p.n)
  m["socket"] = jstr(p.info.socket())
  m["turn"] = p52_json_of_jv(p.turn)
  m["live"] = p52_json_of_jv(p.live)
  m["kind"] = jstr(p.options.kind)
  match p.options.flavor {
    Some(f) => {
      m["flavor"] = jstr(f)
      m["kept"] = jb(p.options.kept)
    }
    None => ()
  }
  if p.orphans {
    m["orphans"] = jb(true)
  }
  // (one taken up with its actor's router: its events taken there from its first line, mb-agents.ts `attach`)
  if p.router is Some(_) {
    m["routed"] = jb(true)
  }
  self.post(Json::object(m))
  (p.options.attached)()
  self.pump.kick()
}

///|
fn AgentsHost::forget(self : AgentsHost, p : HostedProcess) -> Unit {
  self.sessions.remove(p.n)
  match self.held.search(p.n) {
    Some(i) => ignore(self.held.remove(i))
    None => ()
  }
  self.idle_if_none()
}

///|
/// Let go once nothing is read or read again.
fn AgentsHost::idle_if_none(self : AgentsHost) -> Unit {
  if self.sessions.length() == 0 && self.replays.length() == 0 && self.own_replays.length() == 0 && self.on {
    self.on = false
    self.program.release(false)
  }
}

///|
/// What waits on the program's answer, answered as none will come.
fn AgentsHost::settle(self : AgentsHost) -> Unit {
  for kv in self.freezes {
    ignore(kv.1.succeed(Json::object({})))
  }
  self.freezes.clear()
  for kv in self.replays {
    match kv.1 {
      Some(d) => ignore(d.succeed(Json::object({})))
      None => ()
    }
  }
  self.replays.clear()
  for kv in self.own_replays {
    ignore(kv.1.fail(LiveError("the program reading agents was let go while it read an output again")))
  }
  self.own_replays.clear()
}

///|
/// Every process's lines held (the station hands over), `only` those: each one's turn and live steps as they stand then.
async fn AgentsHost::freeze(self : AgentsHost, only : Array[HostedProcess]) -> Unit {
  let held = only.filter(p => match self.sessions.get(p.n) { Some(q) => physical_equal(q, p); None => false })
  if !self.on || held.length() == 0 {
    return
  }
  let id = self.number()
  for p in held {
    if !self.held.contains(p.n) {
      self.held.push(p.n)
    }
  }
  let d : @effect.Deferred[Json] = @effect.Deferred::new()
  self.freezes[id] = d
  self.post({ "freeze": ji(id), "only": Json::array(held.map(p => ji(p.n))) })
  let states = d.wait()
  for p in held {
    p.drained()
  }
  match states {
    Object(m) =>
      for kv in m {
        match attempt(() => @string.parse_int(kv.0)) {
          Ok(n) =>
            match (self.sessions.get(n), kv.1) {
              (Some(p), Object(st)) if st.contains("turn") =>
                p.froze(jv_of(st.get("turn").unwrap_or(Json::null())), jv_of(st.get("live").unwrap_or(Json::null())))
              _ => ()
            }
          Err(_) => ()
        }
      }
    _ => ()
  }
}

///|
fn AgentsHost::thaw(self : AgentsHost, only : Array[HostedProcess]) -> Unit {
  for p in only {
    match self.held.search(p.n) {
      Some(i) => ignore(self.held.remove(i))
      None => ()
    }
    match self.sessions.get(p.n) {
      Some(q) if physical_equal(q, p) => {
        p.frozen_state = None
        self.post({ "thaw": ji(p.n) })
      }
      _ => ()
    }
  }
}

///|
/// What a crash reads again of a process's output, read again by the program as `kind` reads it (`replayOwn`).
async fn AgentsHost::replay_own(self : AgentsHost, kind : String, file : String, at : Int, extra : Json) -> Json {
  self.ensure()
  let id = self.number()
  let d : @effect.Deferred[Json] = @effect.Deferred::new()
  self.own_replays[id] = d
  let m : Map[String, Json] = Map([])
  m["ownReplay"] = ji(id)
  m["kind"] = jstr(kind)
  m["path"] = jstr(file)
  m["at"] = ji(at)
  match extra {
    Object(e) =>
      for kv in e {
        m[kv.0] = kv.1
      }
    _ => ()
  }
  self.post(Json::object(m))
  d.wait()
}

///|
/// A Codex app-server's output read again (`replay`): each run of notifications fed, its live steps at the end.
async fn AgentsHost::replay(self : AgentsHost, runs : Array[Array[Json]]) -> Json {
  self.ensure()
  let id = self.number()
  self.replays[id] = None
  let fed = runs.filter(r => r.length() > 0)
  if fed.length() > 0 {
    self.post({ "codexReplay": ji(id), "notices": Json::array(fed.map(r => Json::array(r))) })
  }
  let d : @effect.Deferred[Json] = @effect.Deferred::new()
  self.replays[id] = Some(d)
  self.post({ "codexReplayed": ji(id) })
  d.wait()
}

///|
/// A process under a runner, read by the program, its lines told as `heard` (mb-agents.ts `HostedProcess`).
priv struct HostedProcess {
  host : AgentsHost
  info : @agent_drivers.RunnerInfo
  n : Int
  options : @agent_drivers.HostedOptions
  mut frozen : Bool
  mut gone : Bool
  mut killing : Bool
  mut exit_said : String?
  mut turn : @jsjson.JValue
  mut live : @jsjson.JValue
  mut frozen_state : (@jsjson.JValue, @jsjson.JValue)?
  exited : @agent_drivers.Later[String]
  mut left : (() -> Unit)?
  mut router : Router?
  mut orphans : Bool
  /// What its session is writing of what was told before (`heard`'s promise): what is told next waits for it.
  mut waiting : @agent_drivers.Later[Unit]?
}

///|
fn HostedProcess::new(
  host : AgentsHost,
  info : @agent_drivers.RunnerInfo,
  options : @agent_drivers.HostedOptions,
  turn : @jsjson.JValue,
  live : @jsjson.JValue,
) -> HostedProcess {
  {
    host,
    info,
    n: host.number(),
    options,
    frozen: false,
    gone: false,
    killing: false,
    exit_said: None,
    turn,
    live,
    frozen_state: None,
    exited: @agent_drivers.Later::new(host.pump.lp),
    left: None,
    router: None,
    orphans: options.orphans,
    waiting: None,
  }
}

///|
/// `f` once what was told before it is taken (at once where nothing is being written).
fn HostedProcess::in_turn(self : HostedProcess, f : () -> @agent_drivers.Later[Unit]) -> Unit {
  match self.waiting {
    Some(w) => {
      let next = w.bind(_ => f())
      self.waiting = Some(next)
      next.on(_ => match self.waiting {
        Some(x) if physical_equal(x, next) => self.waiting = None
        _ => ()
      })
    }
    None => {
      let wait = f()
      if !wait.settled() {
        self.waiting = Some(wait)
        wait.on(_ => match self.waiting {
          Some(x) if physical_equal(x, wait) => self.waiting = None
          _ => ()
        })
      }
    }
  }
  self.host.pump.kick()
}

///|
/// Once what was told it is taken.
async fn HostedProcess::drained(self : HostedProcess) -> Unit {
  while self.waiting is Some(w) {
    self.host.pump.wait(w) catch {
      _ => ()
    }
    if self.waiting is Some(x) && physical_equal(x, w) {
      self.waiting = None
    }
  }
}

///|
fn HostedProcess::heard(self : HostedProcess, heard : Json) -> Unit {
  self.in_turn(() => self.take(heard))
}

///|
fn HostedProcess::take(self : HostedProcess, heard : Json) -> @agent_drivers.Later[Unit] {
  let lp = self.host.pump.lp
  if self.gone || self.frozen {
    return @agent_drivers.done(lp)
  }
  match jfield(heard, "turn") {
    Null => ()
    t => self.turn = jv_of(t)
  }
  let batch = jnum_of(heard, "batch").map(b => b.to_int())
  let router = match batch {
    Some(_) => self.router
    None => None
  }
  let heard = match (router, heard) {
    (Some(_), Object(m)) => {
      let c = m.copy()
      c["routed"] = jb(true)
      Json::object(c)
    }
    _ => heard
  }
  let to = jfield(heard, "to")
  let taken = (self.options.heard)({ json: jv_of(heard) })
  let finish = () => {
    if self.gone || self.frozen {
      return
    }
    let took = match (router, batch) {
      (Some(r), Some(b)) => (r.took)(b)
      _ => false
    }
    if !took {
      self.host.post({ "ack": ji(self.n), "to": to })
    }
  }
  match taken {
    Took(true) => @agent_drivers.done(lp)
    Took(false) => {
      finish()
      @agent_drivers.done(lp)
    }
    Writing(l) => l.map(_ => finish())
  }
}

///|
fn HostedProcess::froze(self : HostedProcess, turn : @jsjson.JValue, live : @jsjson.JValue) -> Unit {
  self.turn = turn
  self.live = live
  self.frozen_state = Some((turn, live))
}

///|
fn HostedProcess::exited_(self : HostedProcess, code : Int?, signal : String?, stderr : String) -> @agent_drivers.Later[Unit] {
  let lp = self.host.pump.lp
  if self.exit_said is Some(_) {
    return @agent_drivers.done(lp)
  }
  let said = @agent_drivers.describe_exit(code, signal)
  self.exit_said = Some(said)
  self.exited.resolve(said)
  if self.frozen {
    return @agent_drivers.done(lp)
  }
  let told = (self.options.exit)(said, stderr)
  if !self.killing {
    self.done()
  }
  told
}

///|
/// Its socket closed with no end told.
fn HostedProcess::closed_(self : HostedProcess, stderr : String) -> @agent_drivers.Later[Unit] {
  let lp = self.host.pump.lp
  if self.gone || self.exit_said is Some(_) {
    return @agent_drivers.done(lp)
  }
  if pid_alive(self.info.runner()) {
    live_log("warn", "agents::process", "another station took the runner over; letting go", { "label": jstr(self.options.label) })
    self.frozen = true
    self.gone = true
    self.done()
    self.host.forget(self)
    @agent_drivers.done(lp)
  } else {
    self.exit_said = Some("runner gone")
    self.exited.resolve("runner gone")
    let told = if self.frozen { @agent_drivers.done(lp) } else { (self.options.exit)("runner gone", stderr) }
    self.done()
    self.host.forget(self)
    told
  }
}

///|
fn HostedProcess::left_(self : HostedProcess) -> Unit {
  self.host.forget(self)
  match self.left {
    Some(f) => f()
    None => ()
  }
}

///|
fn HostedProcess::done(self : HostedProcess) -> Unit {
  self.host.post({ "done": ji(self.n) })
}

///|
/// Let go of for the next station: the runner keeps the agent (`detach`).
fn HostedProcess::detach(self : HostedProcess) -> Unit {
  self.frozen = true
  if self.gone {
    return
  }
  self.gone = true
  let m : Map[String, Json] = Map([])
  m["detach"] = ji(self.n)
  if is_windows() {
    m["leave"] = jb(true)
  }
  let left : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.left = Some(() => ignore(left.succeed(())))
  leaving.push(left)
  self.host.post(Json::object(m))
}

///|
/// Connections being let go (runner.ts `leave`): each one read to its end before the station goes.
let leaving : Array[@effect.Deferred[Unit]] = []

///|
/// Once every connection let go so far has reached its end (runner.ts `allLeft`), or `limit_ms` passed.
async fn all_left(limit_ms : Int) -> Unit {
  let waits = leaving.copy()
  leaving.clear()
  ignore(@effect.timeout(limit_ms, async fn() { for d in waits { d.wait() } }))
}

///|
/// The process ended: TERM to its group, KILL after `grace_ms`, then its runner let go (mb-agents.ts `kill`).
async fn HostedProcess::kill(self : HostedProcess, grace_ms : Double) -> Unit {
  if self.frozen {
    return
  }
  if self.killing {
    ignore(self.host.pump.wait(self.exited))
    return
  }
  self.killing = true
  self.host.post({ "signal": ji(self.n), "name": jstr("TERM") })
  let exited = async fn(ms : Int) {
    ignore(@effect.timeout(ms, async fn() { ignore(self.host.pump.wait(self.exited)) }))
  }
  exited(grace_ms.to_int())
  let pgid = self.info.pgid()
  if group_alive(pgid) {
    self.host.post({ "signal": ji(self.n), "name": jstr("KILL") })
    let mut i = 0
    while i < 100 && group_alive(pgid) {
      @effect.sleep(10) // timer: a wait on another process's end (a grace raced against its exit)
      i += 1
    }
  }
  exited(1000)
  self.done()
  let mut j = 0
  while j < 200 && pid_alive(self.info.runner()) {
    @effect.sleep(10) // timer: a wait on another process's end
    j += 1
  }
}

///|
/// The `Proc` a driver holds of it.
fn HostedProcess::proc(self : HostedProcess) -> @agent_drivers.Proc {
  let pump = self.host.pump
  {
    info: self.info,
    write: line => if !self.frozen { self.host.post({ "write": ji(self.n), "line": jstr(line) }) },
    tell: what => if !self.frozen {
      if what == "compact" {
        self.host.post({ "begin": ji(self.n), "compact": jb(true) })
      } else {
        self.host.post(jobj_of([(what, ji(self.n))]))
      }
    },
    say: (what, fields) => if !self.frozen {
      let m : Map[String, Json] = Map([])
      m[what] = ji(self.n)
      match p52_json_of_jv(fields) {
        Object(f) =>
          for kv in f {
            m[kv.0] = kv.1
          }
        _ => ()
      }
      self.host.post(Json::object(m))
    },
    keep_from: at => self.host.post({ "keep": ji(self.n), "at": ji(at) }),
    freeze: () => self.frozen = true,
    frozen_state: () => self.frozen_state,
    detach: () => self.detach(),
    kill: grace => pump.later("agent's process ended", async fn() { self.kill(grace) }),
    released: () => pump.later("runner released", async fn() {
      if self.frozen || self.exit_said is None {
        return
      }
      let mut i = 0
      while i < 200 && pid_alive(self.info.runner()) {
        @effect.sleep(10) // timer: a wait on another process's end
        i += 1
      }
    }),
    has_exited: () => self.exit_said is Some(_),
    handed: () => self.frozen,
    thread: (thread, live, routed) => {
      let m : Map[String, Json] = { "codexThread": ji(self.n), "id": jstr(thread), "live": p52_json_of_jv(live) }
      if routed {
        m["routed"] = jb(true)
      }
      self.host.post(Json::object(m))
    },
    drop_thread: thread => self.host.post({ "codexDrop": ji(self.n), "id": jstr(thread) }),
    route_thread: (thread, on, was) => {
      // (said only as it changes: a thread taken up with its router was routed as it was told, mb-agents.ts
      // `routeThread`)
      if on != was {
        self.host.post({ "route": ji(self.n), "on": jb(on), "thread": jstr(thread) })
      }
      on
    },
    route: on => if on != (self.router is Some(_)) || on {
      if !on {
        self.router = None
      }
      self.host.post({ "route": ji(self.n), "on": jb(on) })
    },
    orphans_off: () => {
      self.orphans = false
      self.host.post({ "orphans": ji(self.n), "on": jb(false) })
    },
  }
}

///|
/// The drivers' `Procs`: processes started under runners here and read by the program.
fn AgentsHost::procs(self : AgentsHost, runner : () -> String?, data : String, pre : Ref[(HostedProcess) -> Unit]) -> @agent_drivers.Procs {
  let pump = self.pump
  {
    start: (id, program, args, env, cwd, options, turn) => pump.later("agent started", async fn() {
      if self.closed {
        raise LiveError("\{options.label} not started: the station's agents were let go")
      }
      guard runner() is Some(bin) else {
        raise LiveError("stillfail-runner is not there: STILLFAIL_RUNNER, <app>/bin and the checkout's build looked at")
      }
      end_runner_now(pump, data, id, options.label)
      let pairs = env.pairs.copy()
      let info = start_runner(pump.host, bin, data, id, program, args, pairs, cwd)
      if self.closed {
        end_runner_now(pump, data, id, options.label)
        raise LiveError("\{options.label} not started: the station's agents were let go")
      }
      let p = HostedProcess::new(self, { json: jv_of(info) }, options, turn, @jsjson.JValue::Null)
      (pre.val)(p)
      self.attach(p)
      p.proc()
    }),
    adopt: (info, options, turn, live) => {
      let p = HostedProcess::new(self, info, options, turn, live)
      (pre.val)(p)
      // (one taken up for its actor: its events taken there from its first line, mb-agents.ts `adopt`)
      if options.kind != "codex" {
        match adopt_routers.get(info.id()) {
          Some(took) => p.router = Some({ took: batch => took(batch, p.n) })
          None => ()
        }
      }
      self.attach(p)
      p.proc()
    },
    replay_own: (kind, file, at, extra) => pump.later("output read again", async fn() {
      jv_of(self.replay_own(kind, file, at, p52_json_of_jv(extra)))
    }),
    replay: runs => pump.later("app-server read again", async fn() {
      jv_of(self.replay(runs.map(r => r.map(p52_json_of_jv))))
    }),
    freeze: procs => pump.later("processes held", async fn() {
      let only = procs.filter_map(pr => self.sessions.values().find_first(p => physical_equal(p.info, pr.info)))
      self.freeze(only)
    }),
    thaw: procs => {
      let only = procs.filter_map(pr => self.sessions.values().find_first(p => physical_equal(p.info, pr.info)))
      self.thaw(only)
    },
    close: () => pump.later("agents let go", async fn() {
      if self.closed {
        return
      }
      self.closed = true
      self.settle()
      if self.on {
        self.on = false
        self.program.release(false)
      }
    }),
  }
}

///|
/// One of that id left by an earlier station ended first (process.ts `endRunner`).
async fn end_runner_now(pump : Pump, data : String, id : String, label : String) -> Unit {
  ignore(pump.wait(@agent_drivers.end_runner(pump.machine(), data, id, label))) catch {
    _ => ()
  }
}
