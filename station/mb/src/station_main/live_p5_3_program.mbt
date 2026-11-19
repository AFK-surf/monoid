// The station's MoonBit program for its sessions (station/src/agents/mb-program.ts `SessionsProgram`,
// sessions/mb-actor.ts `ActorsProgram`), as P5-3 runs it: `stillfail-reader --sessions 1 --data <data> --sep <sep>`,
// this same program run as a process of its own, in which the jobs (`#jobs`, station/mb/src/reader/jobs.mbt) and
// the remote tasks (`#remote`, reader/remote*.mbt, dirsync*.mbt) run as pseudo-actors, exactly as they run under the
// TypeScript station. A line of JSON each way: what the station says begins with its kind (`{"call":`, `{"answer":`,
// `{"due":`, `{"db":`), its time as `now`; what the program says is a call's end (`returned`), a pseudo-actor's ask of
// the station (`rpc`, answered `{"answer": id, "value"|"error"}`) or word (`tell`), a wait on the station's clock
// (`after`, answered `{"due": id}` once due; `cancel`), the store's changes (`changes`), where it stands (`active`,
// `seen`). Each pseudo-actor is a shell here (`P53Shell`): what it is asked and told.
//
// One program a data directory: where the hub's (P5-2's) runs one already (`hub_ask("program.has")` true), this
// starts none and its pseudo-actors are shells of that one (`program.shell`, `program.call`), what it asks of them
// coming back on the bus as `$program.asked:<key>` and `$program.told:<key>`; else (a rig, a test of P5-3 alone)
// it starts its own.

///|
/// What a pseudo-actor of the program asks of the station and tells it (mb-actor.ts `ProgramShell`).
priv struct P53Shell {
  asked : async (String, Array[Json]) -> Json
  told : (String, Array[Json]) -> Unit
}

///|
priv struct P53Program {
  bus : LiveBus
  mut proc : Proc?
  /// The hub's program is the one: nothing started here.
  mut shared : Bool
  shells : Map[String, P53Shell]
  calls : Map[Int, @effect.Deferred[Json]]
  timers : Map[Int, Ref[Bool]]
  mut next : Int
  mut closed : Bool
  /// Where the program stands, as it says it: what it has seen of what was said it, what it has going.
  mut seen : Int
  mut active : Int
  mut sent : Int
}

///|
fn P53Program::new(bus : LiveBus) -> P53Program {
  {
    bus,
    proc: None,
    shared: false,
    shells: Map([]),
    calls: Map([]),
    timers: Map([]),
    next: 0,
    closed: false,
    seen: 0,
    active: 0,
    sent: 0,
  }
}

///|
/// A pseudo-actor's shell (`ActorsProgram.shell`).
async fn P53Program::shell(self : P53Program, key : String, shell : P53Shell) -> Unit {
  self.shells[key] = shell
  guard self.shared else { return }
  self.bus.on_peer("$program.asked:" + key, async fn(_from, _ws, params, _bytes) {
    let f = jtext_or_empty(params, "fn")
    let args = jitems(jfield(params, "args"))
    let v = (shell.asked)(f, args) catch { e => jobj_of([("$programError", p53_error_of(e))]) }
    (v, None)
  })
  self.bus.on_peer("$program.told:" + key, async fn(_from, _ws, params, _bytes) {
    let args = jitems(jfield(params, "args"))
    (shell.told)(jtext_or_empty(params, "fn"), args)
    (Json::null(), None)
  })
  self.bus.hub_program_shell(key)
}

///|
/// The program started, told the station's database (`{db}`: the actors' begin), what it says heard as it comes.
async fn P53Program::start(self : P53Program) -> Unit raise P53Error {
  let bus = self.bus
  let has = bus.hub_program_has() catch { _ => Json::null() }
  if has is True {
    self.shared = true
    return
  }
  let proc = spawn(
    bus.host,
    reader_program(bus),
    ["--sessions", "1", "--data", bus.data, "--sep", sep()],
    stdin_piped=true,
    stdout=Piped,
    stderr=Piped,
  ) catch {
    SysError(why) => raise P53Error("the sessions' program does not start: \{why}")
  }
  self.proc = Some(proc)
  fork_bg(bus.host, "the sessions' program", async fn() {
    let line = @buffer.Buffer()
    let err = @buffer.Buffer()
    while true {
      match proc.events.take() {
        Out(b) =>
          for i in 0..<b.length() {
            if b[i] == b'\n' {
              let text = p53_utf8(line.to_bytes())
              line.reset()
              self.said(text)
            } else {
              line.write_byte(b[i])
            }
          }
        Err(b) =>
          for i in 0..<b.length() {
            if b[i] == b'\n' {
              slice_log("warn", "readers", "the sessions' program said", jobj_of([("line", jstr(p53_utf8(err.to_bytes())))]))
              err.reset()
            } else {
              err.write_byte(b[i])
            }
          }
        Exit(code, signal) => {
          self.ended(code, signal)
          break
        }
      }
    }
  })
  ignore(self.post(jobj_of([("db", jstr(@nodepath.join(sep(), [bus.data, "stillfail.db"])))])))
}

///|
/// A line said to the program, its kind first and the station's time beside it.
fn P53Program::post(self : P53Program, message : Json) -> Bool {
  guard !self.closed && self.proc is Some(proc) else { return false }
  let m : Map[String, Json] = Map([])
  match message {
    Object(o) => for k, v in o { m[k] = v }
    _ => ()
  }
  m["now"] = jn(self.bus.store.now().to_double())
  self.sent += 1
  proc.write(@utf8.encode(Json::object(m).stringify() + "\n"))
}

///|
/// Asks pseudo-actor `key` of the program `method` (`ActorsProgram.call`): its value, null where the program is gone.
async fn P53Program::call(self : P53Program, key : String, method : String, args : Array[Json]) -> Json {
  if self.shared {
    return self.bus.hub_program_call(key, method, args)
  }
  self.next += 1
  let id = self.next
  let d : @effect.Deferred[Json] = @effect.Deferred::new()
  self.calls[id] = d
  if !self.post(jobj_of([("call", ji(id)), ("actor", jstr(key)), ("method", jstr(method)), ("args", Json::array(args))])) {
    self.calls.remove(id)
    return Json::null()
  }
  d.wait()
}

///|
/// What the program said.
fn P53Program::said(self : P53Program, line : String) -> Unit {
  guard line != "" else { return }
  guard attempt(() => @json.parse(line)) is Ok(said) else {
    slice_log("warn", "readers", "the sessions' program said what is not JSON", jobj_of([("line", jstr(line))]))
    return
  }
  if jtrue(said, "ready") {
    return
  }
  if jnum_of(said, "seen") is Some(n) { self.seen = n.to_int() }
  if jnum_of(said, "active") is Some(n) { self.active = n.to_int() }
  match jfield(said, "changes") {
    Array(changes) => {
      for c in changes {
        self.bus.notify_store(c)
      }
      return
    }
    _ => ()
  }
  match jnum_of(said, "after") {
    Some(id) => {
      let id = id.to_int()
      let gone = Ref(false)
      self.timers[id] = gone
      let ms = jnum_of(said, "ms").unwrap_or(0.0)
      fork_bg(self.bus.host, "the program's wait", async fn() {
        @effect.sleep(ms.to_int()) // timer: the sessions' program's own wait (its retries, deadlines and sweeps), kept on the station's clock
        if !gone.val {
          self.timers.remove(id)
          ignore(self.post(jobj_of([("due", ji(id))])))
        }
      })
      return
    }
    None => ()
  }
  match jnum_of(said, "cancel") {
    Some(id) => {
      if self.timers.get(id.to_int()) is Some(gone) { gone.val = true }
      self.timers.remove(id.to_int())
      return
    }
    None => ()
  }
  match jnum_of(said, "returned") {
    Some(id) => {
      match self.calls.get(id.to_int()) {
        Some(d) => {
          self.calls.remove(id.to_int())
          match jtext(said, "error") {
            Some(e) => ignore(d.fail(P53Error(e)))
            None => ignore(d.succeed(jfield(said, "value")))
          }
        }
        None => ()
      }
      return
    }
    None => ()
  }
  guard jtext(said, "actor") is Some(key) && self.shells.get(key) is Some(shell) else { return }
  let args = jitems(jfield(said, "args"))
  match jnum_of(said, "rpc") {
    Some(id) => {
      let f = jtext_or_empty(said, "fn")
      fork_bg(self.bus.host, "the program's ask", async fn() {
        let answer = match (try { Ok((shell.asked)(f, args)) } catch { e => Err(e) }) {
          Ok(v) => jobj_of([("answer", jn(id)), ("value", v)])
          Err(e) => jobj_of([("answer", jn(id)), ("error", p53_error_of(e))])
        }
        ignore(self.post(answer))
      })
    }
    None =>
      if jtext(said, "tell") is Some(f) { (shell.told)(f, args) }
  }
}

///|
/// A failure as the program is given it (mb-actor.ts `errorOf`): its words and its kind (a peer's refusal told apart
/// from a request that did not get through).
fn p53_error_of(e : Error) -> Json {
  let kind = match e {
    @jobs_host.Refused(_) => "Refused"
    @jobs_host.Unreached(_) | @jobs_host.NoLink(_) => "Unreached"
    @jobs_host.NoBytes(_) => "NoBytes"
    _ => "Error"
  }
  let message = match e {
    @jobs_host.Refused(m) | @jobs_host.Unreached(m) | @jobs_host.NoLink(m) | @jobs_host.NoBytes(m) => m
    _ => p53_words(e)
  }
  jobj_of([
    ("id", ji(0)),
    ("message", jstr(message)),
    ("said", jb(false)),
    ("missing", jb(false)),
    ("runtime", jstr("claude")),
    ("kind", jstr(kind)),
  ])
}

///|
/// The program ended: asked to (the station stops), or not, which ends the station with it as in a crash
/// (mb-actor.ts `#lost`).
fn P53Program::ended(self : P53Program, code : Int?, signal : String?) -> Unit {
  let asked = self.closed
  self.closed = true
  self.proc = None
  for _, d in self.calls {
    ignore(d.succeed(Json::null()))
  }
  self.calls.clear()
  for _, t in self.timers {
    t.val = true
  }
  self.timers.clear()
  if !asked && !self.bus.stopped.is_done() {
    slice_log("error", "session", "the program running the sessions ended; the station ends with it, as in a crash", jobj_of([("code", match code { Some(c) => ji(c); None => Json::null() }), ("signal", jopt(signal))]))
    (self.bus.stop_station)("the sessions' program ended")
  }
}

///|
/// Its end, asked: its input closed, which ends it.
fn P53Program::close(self : P53Program) -> Unit {
  if self.shared || self.closed {
    return
  }
  self.closed = true
  if self.proc is Some(p) { p.end_input() }
}

///|
/// Its pid, while it runs (None where it is the hub's, which counts it).
fn P53Program::pid(self : P53Program) -> Int? {
  if self.shared {
    return None
  }
  self.proc.map(p => p.pid)
}
