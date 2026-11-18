// The agents' side (P5-2): the sessions' actors as the hub holds them (sessions/mb-actor.ts `ActorsProgram`, `MbActor`).
// Each session's state and serial queue are the program's (reader/actors.mbt, actor_run.mbt); what the hub asks of an
// actor is said to it (`call`, answered `returned`), its runtime session's events as they come (`event`); what the
// program asks of the station is answered here (`rpc`): the store, the hub's deps, its runtime sessions (kept here by a
// number, `handle`), its chats, and the words and formats of what agents are told. What the hub reads of an actor at
// once (where it stands, its queue run out) is what the program last told of it (`mirror`).

///|
/// A runtime session as an actor holds it (agents/runtime.ts `AgentSession`), whichever driver opened it.
priv struct Agent {
  id : () -> String
  busy : () -> Bool
  background : () -> Json
  mcp_url : () -> String?
  can_compact : Bool
  outlived : () -> Bool
  /// Its events given its actor in the program (`route`): told each batch taken there, with its process's number.
  route : (((Int32, Int32) -> Bool)?) -> Unit
  prompt : async (String) -> Unit
  steer : async (String) -> Bool
  abort : async () -> Unit
  compact : async () -> Unit
  dispose : async () -> Unit
  retune : (Json) -> Bool
  snapshot : () -> Json
  detach : () -> Unit
  /// A Codex app-server's version and whether an update matches the station's (codexBefore).
  runtime_version : () -> String?
}

///|
/// What the program last told of an actor (actors.mbt `mirror`).
priv struct Mirror {
  mut queued : Int32
  mut seen : Int32
  mut turn : String?
  mut codex_update : Bool
  mut agent : Int32?
  mut idle_since : Double
  mut notices : Int32
  mut waiting : Bool
  mut refill : Bool
  mut unread : Array[Json]
  mut identity : Json
}

///|
priv struct MbActor {
  key : String
  mut runtime : String
  program : ActorsProgram
  mirror : Mirror
  mut sent : Int32
  mut next : Int32
  agents : Map[Int32, (Int32, Agent)]
  mut generation : Int32
  mut closed : Bool
  told : Map[Int32, () -> Unit]
  /// (words, about, watch, the conversations' `record` callback: mb-actor.ts `#records`)
  records : Map[Int32, (String?, Json, Bool, Int32?)]
  reads : Map[Int32, @effect.Deferred[Unit]]
  mut routing_outcome : Json?
  mut routing_cleared : Bool
  codex : Map[Int32, String?]
  mut read_at : Int32
  mut format_cancelled : Bool
  /// while it is taken up (mb-actor.ts `#adopting`): its generation and what came for it meanwhile, given once it is
  mut adopting : (Int32, Array[() -> Unit])?
}

///|
/// The program, one a hub.
priv struct ActorsProgram {
  ctx : P52
  actors : Map[String, MbActor]
  timers : Map[Int32, Int32]
  mut timer_seq : Int32
  mut sent : Int32
  mut seen : Int32
  mut active : Int32
  mut answering : Int32
  mut closed : Bool
  mut next : Int32
  calls : Map[Int32, @effect.Deferred[Json]]
  /// What else the program asks of the station under a key of its own (`shell`): `#jobs`, `#remote`, `#live`.
  shells : Map[
    String,
    (async (String, Array[Json]) -> Json, (String, Array[Json]) -> Unit),
  ]
}

///|
fn ActorsProgram::new(ctx : P52) -> ActorsProgram {
  let p = {
    ctx,
    actors: Map([]),
    timers: Map([]),
    timer_seq: 0,
    sent: 0,
    seen: 0,
    active: 0,
    answering: 0,
    closed: false,
    next: 0,
    calls: Map([]),
    shells: Map([]),
  }
  ctx.program.use_by({
    actors: true,
    said: s => p.said(s.head),
    exited: code => p.lost(code),
  })
  // (where the station's database is, for what of the store an actor reads and writes itself: said first)
  ignore(p.post(jobj_of([("db", jstr(path([ctx.data, "stillfail.db"])))])))
  p
}

///|
fn ActorsProgram::now(_self : ActorsProgram) -> Double {
  wall_ms().to_double()
}

///|
/// Whether what was said to it is not all taken in yet, or something of it runs.
fn ActorsProgram::busy(self : ActorsProgram) -> Bool {
  self.sent > self.seen || self.active > 0 || self.answering > 0
}

///|
/// Its sessions' state went with it: the station ends as in a crash, and the next takes up their runners and resumes
/// their turns (mb-actor.ts `#lost`).
fn ActorsProgram::lost(self : ActorsProgram, code : Int32) -> Unit {
  let lost = !self.closed
  self.ended()
  if !lost {
    return
  }
  live_log(
    "error",
    "session",
    "the program running the sessions ended; the station ends with it, as in a crash",
    { "code": ji(code) },
  )
  (self.ctx.bus.stop_station)("the sessions' program ended")
}

///|
fn ActorsProgram::post(self : ActorsProgram, message : Json) -> Bool {
  if self.closed {
    return false
  }
  self.sent += 1
  let m = match message {
    Object(o) => {
      let c = o.copy()
      c["now"] = jn(self.now())
      Json::object(c)
    }
    other => other
  }
  self.ctx.program.post(m)
  true
}

///|
/// A call said to the program now, its answer waited for after (`call`'s first half).
fn ActorsProgram::call_posted(
  self : ActorsProgram,
  key : String,
  meth : String,
  args : Array[Json],
) -> @effect.Deferred[Json]? {
  self.next += 1
  let id = self.next
  let d : @effect.Deferred[Json] = @effect.Deferred::new()
  self.calls[id] = d
  if !self.post(
      jobj_of([
        ("call", ji(id)),
        ("actor", jstr(key)),
        ("method", jstr(meth)),
        ("args", Json::array(args)),
      ]),
    ) {
    self.calls.remove(id)
    return None
  }
  Some(d)
}

///|
async fn ActorsProgram::call(
  self : ActorsProgram,
  key : String,
  meth : String,
  args : Array[Json],
) -> Json {
  self.next += 1
  let id = self.next
  let d : @effect.Deferred[Json] = @effect.Deferred::new()
  self.calls[id] = d
  if !self.post(
      jobj_of([
        ("call", ji(id)),
        ("actor", jstr(key)),
        ("method", jstr(meth)),
        ("args", Json::array(args)),
      ]),
    ) {
    self.calls.remove(id)
    return Json::null()
  }
  d.wait()
}

///|
fn ActorsProgram::ended(self : ActorsProgram) -> Unit {
  self.closed = true
  self.timers.clear()
  for kv in self.calls {
    ignore(kv.1.succeed(Json::null()))
  }
  self.calls.clear()
}

///|
fn ActorsProgram::said(self : ActorsProgram, said : Json) -> Unit {
  match jnum_of(said, "seen") {
    Some(n) => self.seen = n.to_int()
    None => ()
  }
  match jnum_of(said, "active") {
    Some(n) => self.active = n.to_int()
    None => ()
  }
  self.hear(said)
}

///|
fn ActorsProgram::hear(self : ActorsProgram, said : Json) -> Unit {
  match jfield(said, "changes") {
    Array(changes) => {
      for c in changes {
        self.ctx.bus.notify_store(c)
      }
      return
    }
    _ => ()
  }
  match jnum_of(said, "after") {
    Some(id) => {
      let ms = jnum_of(said, "ms").unwrap_or(0.0)
      self.timer_seq += 1
      let seq = self.timer_seq
      self.timers[id.to_int()] = seq
      ignore(
        self.ctx.host.rt.fork(name="actor's wait", async fn() {
          // timer: a wait of an actor's (its wait, a refill), on the hub's clock
          @effect.sleep(if ms < 1.0 { 0 } else { ms.ceil().to_int() })
          if self.timers.get(id.to_int()) == Some(seq) {
            self.timers.remove(id.to_int())
            ignore(self.post({ "due": jn(id) }))
          }
        }),
      )
      return
    }
    None => ()
  }
  match jnum_of(said, "cancel") {
    Some(id) => {
      self.timers.remove(id.to_int())
      return
    }
    None => ()
  }
  match jnum_of(said, "returned") {
    Some(id) => {
      let d = self.calls.get(id.to_int())
      self.calls.remove(id.to_int())
      match d {
        Some(d) =>
          match jtext(said, "error") {
            Some(e) => {
              // (the station's own error it was told, thrown as it was: its kind is what callers tell apart)
              let first = match jnum_of(jfield(said, "cause"), "id") {
                Some(n) => {
                  let got = actor_errors.get(n.to_int())
                  actor_errors.remove(n.to_int())
                  got
                }
                None => None
              }
              ignore(d.fail(first.unwrap_or(LiveError(e))))
            }
            None => ignore(d.succeed(jfield(said, "value")))
          }
        None => ()
      }
      return
    }
    None => ()
  }
  let key = match (jtext(said, "actor"), jtext(said, "mirror")) {
    (Some(k), _) | (_, Some(k)) => k
    _ => return
  }
  match self.shells.get(key) {
    Some((asked, told)) => {
      match jnum_of(said, "rpc") {
        Some(id) => {
          self.answering += 1
          let f = jtext(said, "fn").unwrap_or("")
          let args = jitems(jfield(said, "args"))
          ignore(
            self.ctx.host.rt.fork(name="shell's rpc", async fn() {
              let answer = Ok(asked(f, args)) catch { e => Err(e) }
              self.answering -= 1
              match answer {
                Ok({ "$programError": err, .. }) =>
                  ignore(self.post({ "answer": jn(id), "error": err }))
                Ok(v) => ignore(self.post({ "answer": jn(id), "value": v }))
                Err(e) =>
                  ignore(
                    self.post({ "answer": jn(id), "error": error_of(e, "") }),
                  )
              }
            }),
          )
        }
        None =>
          match jtext(said, "tell") {
            Some(t) => told(t, jitems(jfield(said, "args")))
            None => ()
          }
      }
      return
    }
    None => ()
  }
  guard self.actors.get(key) is Some(actor) else { return }
  if jtext(said, "mirror") is Some(_) {
    actor.mirrored(jfield(said, "state"))
  } else if jnum_of(said, "rpc") is Some(id) {
    self.answering += 1
    let f = jtext(said, "fn").unwrap_or("")
    let args = jitems(jfield(said, "args"))
    ignore(
      self.ctx.host.rt.fork(name="actor's rpc", async fn() {
        let answer = Ok(actor.asked(f, args)) catch { e => Err(e) }
        self.answering -= 1
        match answer {
          Ok(v) => ignore(self.post({ "answer": jn(id), "value": v }))
          Err(e) =>
            ignore(
              self.post({
                "answer": jn(id),
                "error": error_of(e, actor.runtime),
              }),
            )
        }
      }),
    )
  } else {
    match jtext(said, "tell") {
      Some(t) => actor.told_(t, jitems(jfield(said, "args")))
      None => ()
    }
  }
}

///|
/// The station's errors the program was told, by their number (mb-actor.ts `errors`): the oldest let go past 256.
let actor_errors : Map[Int32, Error] = Map([])

///|
let actor_errors_next : Ref[Int32] = Ref(0)

///|
/// An error of the station's as the program is told it (mb-actor.ts `errorOf`): its words, whether they are the
/// station's own (`Said`), whether its runtime is not installed.
fn error_of(e : Error, runtime : String) -> Json {
  // (kept by its number, given back as it was where the program's call fails with it: mb-actor.ts `errors`)
  actor_errors_next.val += 1
  let id = actor_errors_next.val
  actor_errors[id] = e
  if actor_errors.length() > 256 {
    match actor_errors.keys().next() {
      Some(k) => actor_errors.remove(k)
      None => ()
    }
  }
  let said_own = e is @agent_drivers.Said(_)
  let missing = match e {
    CommandMissing(c) => c == runtime || c.has_suffix("/" + runtime)
    _ => false
  }
  let message = match e {
    CommandMissing(c) => "the runner did not start: \{c} is not on PATH"
    other => said_of(other)
  }
  {
    "id": ji(id),
    "message": jstr(message),
    "said": jb(said_own),
    "missing": jb(missing),
    "runtime": jstr(runtime),
    "kind": jstr(
      match e {
        CommandMissing(_) => "CommandMissing"
        // (a peer's refusal told apart from a request that did not get through: bus.ts)
        @gate.PeerRefused(_) => "PeerRefused"
        _ => "Error"
      },
    ),
  }
}

///|
fn ActorsProgram::actor(
  self : ActorsProgram,
  key : String,
  runtime : String,
) -> MbActor {
  let a : MbActor = {
    key,
    runtime,
    program: self,
    mirror: {
      queued: 0,
      seen: 0,
      turn: None,
      codex_update: false,
      agent: None,
      idle_since: self.now(),
      notices: 0,
      waiting: false,
      refill: false,
      unread: [],
      identity: Json::null(),
    },
    sent: 0,
    next: 0,
    agents: Map([]),
    generation: 0,
    closed: false,
    told: Map([]),
    records: Map([]),
    reads: Map([]),
    routing_outcome: None,
    routing_cleared: false,
    codex: Map([]),
    read_at: 0,
    format_cancelled: false,
    adopting: None,
  }
  self.actors[key] = a
  a.post({ "runtime": jstr(runtime) })
  a
}

///|
fn ActorsProgram::forget(
  self : ActorsProgram,
  key : String,
  actor : MbActor,
) -> Unit {
  match self.actors.get(key) {
    Some(a) if physical_equal(a, actor) => self.actors.remove(key)
    _ => ()
  }
}

///|
fn ActorsProgram::close(self : ActorsProgram) -> Unit {
  if self.closed {
    return
  }
  self.ended()
  self.ctx.program.release(true)
}

// ── an actor ──

///|
fn MbActor::post(self : MbActor, message : Json) -> Unit {
  self.sent += 1
  let m = match message {
    Object(o) => {
      let c = o.copy()
      c["actor"] = jstr(self.key)
      Json::object(c)
    }
    other => other
  }
  ignore(self.program.post(m))
}

///|
async fn MbActor::call(
  self : MbActor,
  meth : String,
  args : Array[Json],
) -> Json {
  if self.closed {
    return Json::null()
  }
  self.sent += 1
  self.program.call(self.key, meth, args)
}

///|
fn MbActor::mirrored(self : MbActor, state : Json) -> Unit {
  let m = self.mirror
  m.queued = jnum_of(state, "queued").unwrap_or(0.0).to_int()
  m.seen = jnum_of(state, "seen").unwrap_or(0.0).to_int()
  m.turn = jtext(state, "turn")
  m.codex_update = jfield(state, "codexUpdate") is True
  m.agent = jnum_of(state, "agent").map(a => a.to_int())
  m.idle_since = jnum_of(state, "idleSince").unwrap_or(m.idle_since)
  m.notices = jnum_of(state, "notices").unwrap_or(0.0).to_int()
  m.waiting = jfield(state, "waiting") is True
  m.refill = jfield(state, "refill") is True
  m.unread = if m.seen < self.read_at {
    []
  } else {
    jitems(jfield(state, "unread"))
  }
  m.identity = jfield(state, "identity")
  match jtext(state, "runtime") {
    Some(r) => self.runtime = r
    None => ()
  }
}

///|
fn MbActor::session(self : MbActor) -> Agent? {
  match self.mirror.agent {
    Some(h) => self.agents.get(h).map(x => x.1)
    None => None
  }
}

///|
fn MbActor::settled(self : MbActor) -> Bool {
  self.sent == self.mirror.seen && self.mirror.queued == 0
}

///|
fn MbActor::process_state(self : MbActor) -> String {
  let busy = match self.session() {
    Some(s) => (s.busy)()
    None => false
  }
  if self.mirror.turn is Some(_) || self.mirror.codex_update || busy {
    "running"
  } else if self.mirror.agent is Some(_) {
    "warm"
  } else {
    "cold"
  }
}

///|
fn MbActor::idle_ms(self : MbActor, now : Double) -> Double? {
  match self.session() {
    Some(s) if !(s.busy)() && self.mirror.turn is None =>
      Some(now - self.mirror.idle_since)
    _ => None
  }
}

///|
fn MbActor::holds_state(self : MbActor) -> Bool {
  self.mirror.codex_update ||
  self.mirror.notices > 0 ||
  self.mirror.waiting ||
  self.mirror.refill
}

///|
fn MbActor::closing(self : MbActor) -> Unit {
  self.closed = true
  self.format_cancelled = true
  self.program.forget(self.key, self)
}

///|
/// Its runtime session's events: had here, then said to the program (mb-actor.ts `#event`).
fn MbActor::event(self : MbActor, generation : Int32, event : Json) -> Unit {
  if self.closed {
    return
  }
  match self.adopting {
    Some((g, pending)) if g == generation => {
      pending.push(() => self.event(generation, event))
      return
    }
    _ => ()
  }
  let kind = jtext(event, "type").unwrap_or("")
  if jfield(event, "routed") is True {
    if kind == "live" {
      let e = jfield(event, "event")
      if jtext(e, "kind") == Some("phase") &&
        jtext(e, "phase") == Some("requesting") &&
        self.mirror.unread.length() > 0 {
        self.mirror.unread = []
        self.routing_cleared = true
      }
    } else if kind == "turnEnded" {
      self.routing_outcome = Some(jfield(event, "outcome"))
    }
    return
  }
  if kind == "live" {
    let e = jfield(event, "event")
    self.program.ctx.live_event(self.key, e)
    let ek = jtext(e, "kind").unwrap_or("")
    if ek == "tasks" ||
      ek == "plan" ||
      (ek == "delta" && jtext(e, "field") != Some("text")) {
      return
    }
    if ek == "start" && jtext(e, "step") == Some("thinking") {
      return
    }
    if ek == "phase" &&
      jtext(e, "phase") == Some("requesting") &&
      self.mirror.unread.length() > 0 {
      self.mirror.unread = []
      self.read_at = self.sent + 1
    }
    let shown = if ek == "start" && jtext(e, "step") == Some("tool") {
      jobj_of([
        ("kind", jfield(e, "kind")),
        ("step", jfield(e, "step")),
        ("id", jfield(e, "id")),
        ("tool", jfield(e, "tool")),
      ])
    } else {
      e
    }
    self.post({
      "event": { "type": jstr("live"), "event": shown },
      "generation": ji(generation),
    })
    return
  }
  if kind == "turnEnded" {
    self.next += 1
    let read = self.next
    let d : @effect.Deferred[Unit] = @effect.Deferred::new()
    self.reads[read] = d
    let ctx = self.program.ctx
    let key = self.key
    ignore(
      ctx.host.rt.fork(name="turn's last read", async fn() {
        ctx.live_turn_ended(key)
        ignore(d.succeed(()))
      }),
    )
    self.post({ "event": event, "generation": ji(generation), "read": ji(read) })
    return
  }
  self.post({ "event": event, "generation": ji(generation) })
}

///|
/// Its runtime session's process, read in the program, gives the actor its events there (`#route`).
fn MbActor::route(self : MbActor, agent : Agent, generation : Int32) -> Unit {
  (agent.route)(Some((batch, n) => self.took(batch, n, generation)))
}

///|
fn MbActor::unroute(_self : MbActor, agent : Agent) -> Unit {
  (agent.route)(None)
}

///|
fn MbActor::took(
  self : MbActor,
  batch : Int32,
  n : Int32,
  generation : Int32,
) -> Bool {
  if self.closed || n < 0 {
    return false
  }
  // (taken while it is taken up: given once it is, in the order it came)
  match self.adopting {
    Some((g, pending)) if g == generation => {
      pending.push(() => ignore(self.took(batch, n, generation)))
      return true
    }
    _ => ()
  }
  let outcome = self.routing_outcome
  let cleared = self.routing_cleared
  self.routing_outcome = None
  self.routing_cleared = false
  if self.closed || n < 0 {
    return false
  }
  if cleared {
    self.read_at = self.sent + 1
  }
  let m : Map[String, Json] = Map([])
  m["routed"] = ji(n)
  m["batch"] = ji(batch)
  m["generation"] = ji(generation)
  match outcome {
    Some(o) => m["outcome"] = o
    None => ()
  }
  self.post(Json::object(m))
  true
}

///|
fn MbActor::listener(
  self : MbActor,
  generation : Int32,
) -> (@jsjson.JValue) -> Unit {
  e => self.event(generation, p52_json_of_jv(e))
}

///|
fn MbActor::begin_adopt(self : MbActor, generation : Int32) -> (Int, Int) -> Bool {
  self.adopting = Some((generation, []))
  (batch, n) => self.took(batch, n, generation)
}

///|
fn MbActor::cancel_adopt(self : MbActor, generation : Int32) -> Unit {
  match self.adopting {
    Some((g, _)) if g == generation => self.adopting = None
    _ => ()
  }
}

///|
fn MbActor::next_generation(self : MbActor) -> Int32 {
  self.generation += 1
  self.generation
}

// ── what the hub asks of it ──

///|
/// One of MbActor's methods by its TypeScript name, as the hub asks it (World `actor`).
async fn MbActor::hub_asked(
  self : MbActor,
  meth : String,
  args : Array[Json],
) -> Json {
  let a = (i : Int32) => args.get(i).unwrap_or(Json::null())
  match meth {
    // (read at once)
    "settled" => jb(self.settled())
    "processState" => jstr(self.process_state())
    "idleMs" =>
      match
        self.idle_ms(
          jnum_of(Json::object({ "n": a(0) }), "n").unwrap_or(
            self.program.now(),
          ),
        ) {
        Some(ms) => jn(ms)
        None => Json::null()
      }
    "holdsState" => jb(self.holds_state())
    "currentTurnId" => jopt(self.mirror.turn)
    "messageIdentity" =>
      if self.mirror.agent is Some(_) {
        self.mirror.identity
      } else {
        Json::null()
      }
    "unreadIn" => {
      let thread = a(0)
      let before = jnum_of(Json::object({ "n": a(1) }), "n").unwrap_or(0.0)
      Json::array(
        self.mirror.unread.filter_map(u => {
          match u {
            Array([t, Number(n, ..), ts, ..]) if t == thread && n < before =>
              Some({ "message": { "thread": t, "n": jn(n), "ts": ts } })
            _ => None
          }
        }),
      )
    }
    // (said to the program)
    "notify" => {
      let row = self.program.ctx.store("getSession", [jstr(self.key)])
      match jfield(row, "archivedAt") {
        Null => ignore(self.call("notify", args))
        _ => ()
      }
      Json::null()
    }
    "stop" | "suspend" => {
      self.format_cancelled = true
      ignore(self.call(meth, args))
      Json::null()
    }
    "runChanged" => {
      let change = a(0)
      let words = @session_hub.run_change_words(
        self.program.ctx.words,
        change,
        self.program.ctx.lang(),
      )
      ignore(self.call("runChanged", [jstr(words), change]))
      Json::null()
    }
    "stateForTurn" => {
      // (id, state, words, about, watch): what records it, kept here by a token the program gives back (`stateWrite`)
      self.next += 1
      let token = self.next
      // (and how the conversations record it: a callback of theirs, `record`, that rereads what it is about and
      // writes in one transaction of theirs: conversations.mbt `state_write`; mb-actor.ts `stateForTurn`)
      let record = jnum_of(Json::object({ "f": jfield(a(5), "$fn") }), "f").map(n => n.to_int())
      self.records[token] = (
        jtext(Json::object({ "w": a(2) }), "w"),
        a(3),
        a(4) is True,
        record,
      )
      let done = () => {
        self.records.remove(token)
        match record {
          Some(id) => chat_state.callbacks.remove(id)
          None => ()
        }
      }
      let r = self.call("stateForTurn", [a(0), a(1), ji(token)]) catch {
        e => {
          done()
          raise e
        }
      }
      done()
      jb(r is True)
    }
    "snapshot" => {
      let snap = self.call("snapshot", [])
      let held = match jnum_of(snap, "agent") {
        Some(h) => self.agents.get(h.to_int()).map(x => x.1)
        None => None
      }
      self.closing()
      let agent = match held {
        Some(s) => {
          let shot = (s.snapshot)()
          (s.detach)()
          shot
        }
        None => Json::null()
      }
      match snap {
        Object(m) => {
          let c = m.copy()
          c["agent"] = agent
          Json::object(c)
        }
        other => other
      }
    }
    "close" => {
      ignore(
        self.program.ctx.host.rt.fork(name="actor closed", async fn() {
          ignore(self.call("close", []))
        }),
      )
      self.closing()
      Json::null()
    }
    "dispose" => {
      ignore(self.call("dispose", []))
      self.closing()
      let left = self.agents.values().to_array()
      self.agents.clear()
      for x in left {
        (x.1.dispose)() catch {
          _ => ()
        }
      }
      Json::null()
    }
    "compact" | "clear" => self.call(meth, args)
    _ => {
      ignore(self.call(meth, args))
      Json::null()
    }
  }
}

///|
/// Takes up `snap` with its runtime session `agent` (mb-actor.ts `adopt`).
async fn MbActor::adopt(
  self : MbActor,
  snap : Json,
  agent : Agent?,
  profile : String,
) -> Unit {
  let mut taken = Json::null()
  match agent {
    Some(g) => {
      self.next += 1
      let handle = self.next
      self.agents[handle] = (self.generation, g)
      taken = { "handle": ji(handle), "generation": ji(self.generation) }
      self.mirror.agent = Some(handle)
      self.mirror.turn = jtext(jfield(snap, "turn"), "id")
      self.mirror.idle_since = self.program.now() -
        jnum_of(snap, "idleMs").unwrap_or(0.0)
      match jtext(snap, "runtime") {
        Some(r) => self.runtime = r
        None => ()
      }
    }
    None => ()
  }
  let bare = match snap {
    Object(m) => {
      let c = m.copy()
      c["agent"] = Json::null()
      Json::object(c)
    }
    other => other
  }
  let pending = match self.adopting {
    Some((_, p)) => p
    None => []
  }
  self.adopting = None
  let row = self.program.ctx.store("getSession", [jstr(self.key)])
  // (its adopt said to the program before what came meanwhile: mb-actor.ts `adopt`)
  let answer = if self.closed { None } else { self.sent += 1; self.program.call_posted(self.key, "adopt", [bare, taken, jstr(profile), row]) }
  match agent {
    Some(g) => {
      for deliver in pending {
        deliver()
      }
      self.route(g, self.generation)
    }
    None => ()
  }
  match answer {
    Some(d) => ignore(d.wait())
    None => ()
  }
}

// ── what the program asks of the station ──

///|
/// What is told and not waited for.
fn MbActor::told_(self : MbActor, f : String, args : Array[Json]) -> Unit {
  let a = (i : Int32) => args.get(i).unwrap_or(Json::null())
  let ctx = self.program.ctx
  match f {
    "log" => {
      let fields = match a(2) {
        Object(m) => Json::object(m)
        _ => Json::object({})
      }
      live_log(
        jtext(Json::object({ "l": a(0) }), "l").unwrap_or("info"),
        "session",
        jtext(Json::object({ "m": a(1) }), "m").unwrap_or(""),
        fields,
      )
    }
    "node.tasks" => {
      let tasks = match jnum_of(Json::object({ "h": a(0) }), "h") {
        Some(h) =>
          match self.agents.get(h.to_int()) {
            Some((_, s)) => (s.background)()
            None => Json::array([])
          }
        None => Json::array([])
      }
      ctx.live_event(self.key, { "kind": jstr("tasks"), "tasks": tasks })
    }
    "node.working" => ctx.working(self.key, jitems(a(0)), a(1))
    "chat.standsAt" => ctx.stands_at(a(0), a(1), a(2), a(3))
    _ =>
      live_log(
        "warn",
        "session",
        "a session told the station what it does not know",
        { "session": jstr(self.key), "tell": jstr(f) },
      )
  }
}

///|
/// What is asked and answered (mb-actor.ts `asked`).
async fn MbActor::asked(self : MbActor, f : String, args : Array[Json]) -> Json {
  if trace_on() {
    err_write("p52 actor \{self.key} asks \{f}\n")
  }
  let ctx = self.program.ctx
  let a = (i : Int32) => args.get(i).unwrap_or(Json::null())
  let (part, name) = match f.find(".") {
    Some(i) => (f[:i].to_owned(), f[i + 1:].to_owned())
    None => (f, "")
  }
  if part == "store" {
    return ctx.store(name, args)
  }
  if part == "deps" {
    return ctx.deps(self.key, name, args)
  }
  if part == "agent" {
    let handle = jnum_of(Json::object({ "h": a(0) }), "h")
      .unwrap_or(-1.0)
      .to_int()
    guard self.agents.get(handle) is Some((_, s)) else {
      raise LiveError("no runtime session \{handle}")
    }
    let rest = args[1:].to_owned()
    let r = (i : Int32) => rest.get(i).unwrap_or(Json::null())
    return match name {
      "busy" => jb((s.busy)())
      "holding" => jb(jitems((s.background)()).length() > 0)
      "background" => (s.background)()
      "mcpUrl" => jopt((s.mcp_url)())
      "canCompact" => jb(s.can_compact)
      "dispose" => {
        self.agents.remove(handle)
        self.unroute(s)
        (s.dispose)()
        Json::null()
      }
      "prompt" => {
        (s.prompt)(jtext(Json::object({ "t": r(0) }), "t").unwrap_or(""))
        Json::null()
      }
      "steer" =>
        jb((s.steer)(jtext(Json::object({ "t": r(0) }), "t").unwrap_or("")))
      "abort" => {
        (s.abort)()
        Json::null()
      }
      "compact" => {
        (s.compact)()
        Json::null()
      }
      "id" => jstr((s.id)())
      "outlived" => jb((s.outlived)())
      _ => Json::null()
    }
  }
  if f == "t" {
    let args_t = match a(1) {
      Object(m) => m.iter().map(kv => (kv.0, kv.1)).to_array()
      _ => []
    }
    return jstr(
      ctx.words.tr(
        jtext(Json::object({ "k": a(0) }), "k").unwrap_or(""),
        args=args_t,
        lang=ctx.lang(),
      ),
    )
  }
  match name {
    "words" => {
      let named = jtext(Json::object({ "n": a(0) }), "n").unwrap_or("")
      let rest = args[1:].to_owned()
      // (instructions.ts's, the agent's own words; the rest actor.ts's in the station's words)
      match named {
        "GO_ON_AFTER_AUTH" => jstr(@agent_runtimes.go_on_after_auth)
        "GO_ON_AFTER_CODEX_UPDATE" =>
          jstr(@agent_runtimes.go_on_after_codex_update)
        "GO_ON_AFTER_FAILED" => jstr(@agent_runtimes.go_on_after_failed)
        "GO_ON_AFTER_OVERLOADED" => jstr(@agent_runtimes.go_on_after_overloaded)
        "GO_ON_AFTER_UNANSWERED" => jstr(@agent_runtimes.go_on_after_unanswered)
        "GO_ON_AFTER_REFILL" => jstr(@agent_runtimes.go_on_after_refill)
        "GO_ON_AFTER_SPENT" => jstr(@agent_runtimes.go_on_after_spent)
        "NUDGE" => jstr(@agent_runtimes.nudge)
        "RESUME_AFTER_RESTART" => jstr(@agent_runtimes.resume_after_restart)
        "TOOLS_LOST" => jstr(@agent_runtimes.tools_lost)
        "BACKGROUND_STOPPED_WAITING" =>
          jstr(@agent_runtimes.background_stopped_waiting)
        "nameUntitled" =>
          jstr(
            @agent_runtimes.name_untitled(
              jtext(
                Json::object({ "a": rest.get(0).unwrap_or(Json::null()) }),
                "a",
              ).unwrap_or(""),
            ),
          )
        "waitOver" =>
          jstr(
            @agent_runtimes.wait_over(
              jnum_of(
                Json::object({ "a": rest.get(0).unwrap_or(Json::null()) }),
                "a",
              ).unwrap_or(0.0),
            ),
          )
        _ => @session_hub.words_answer(ctx.words, named, rest)
      }
    }
    "uuid" => jstr(@drive.random_uuid())
    "cardAsks" =>
      ctx.card_asks(
        self.key,
        jtext(Json::object({ "i": a(0) }), "i").unwrap_or(""),
        jnum_of(Json::object({ "s": a(1) }), "s"),
      )
    "keepAsk" =>
      ctx.keep_ask(
        self.key,
        jtext(Json::object({ "i": a(0) }), "i").unwrap_or(""),
        a(1),
      )
    "timed" =>
      jstr(
        @session_hub.timed(
          jtext(Json::object({ "t": a(0) }), "t").unwrap_or(""),
          self.program.now(),
        ),
      )
    "withChoices" => {
      let (text, told) = ctx.handed_with_choices(
        self.key,
        jtext(Json::object({ "t": a(0) }), "t").unwrap_or(""),
      )
      self.next += 1
      let id = self.next
      self.told[id] = told
      { "text": jstr(text), "told": ji(id) }
    }
    "told" => {
      let id = jnum_of(Json::object({ "i": a(0) }), "i")
        .unwrap_or(-1.0)
        .to_int()
      match self.told.get(id) {
        Some(t) => {
          self.told.remove(id)
          t()
        }
        None => ()
      }
      Json::null()
    }
    "prompt" =>
      jstr(
        ctx.prompt_for(
          self.key,
          self.program.now(),
          a(0),
          a(1) is True,
          a(2),
          a(3),
          a(4) is True,
        ),
      )
    "pendingAndFormat" => {
      self.format_cancelled = false
      let got = ctx.pending_and_format(self.key, a(0) is True, () => {
        self.format_cancelled
      })
      got
    }
    "open" => {
      let gen = Ref(0)
      let opened = ctx.open_agent(
        self.key,
        jitems(a(0)),
        a(1) is True,
        jtext(Json::object({ "p": a(2) }), "p"),
        r => self.runtime = r,
        () => {
          gen.val = self.next_generation()
          gen.val
        },
        g => self.listener(g),
      )
      self.next += 1
      let handle = self.next
      self.agents[handle] = (gen.val, opened.0)
      self.route(opened.0, gen.val)
      match opened.1 {
        Object(m) => {
          let c = m.copy()
          c["handle"] = ji(handle)
          c["runtime"] = jstr(self.runtime)
          Json::object(c)
        }
        other => other
      }
    }
    "retune" => {
      let handle = jnum_of(Json::object({ "h": a(0) }), "h")
        .unwrap_or(-1.0)
        .to_int()
      match self.agents.get(handle) {
        Some((_, s)) =>
          ctx.retune_agent(
            self.key,
            s,
            self.runtime,
            jtext(Json::object({ "p": a(1) }), "p"),
            a(2) is True,
            a(3) is True,
          )
        None => Json::null()
      }
    }
    "profileId" => jfield(ctx.run_on(self.key, a(0) is True, true), "id")
    "outlived" =>
      match
        self.agents.get(
          jnum_of(Json::object({ "h": a(0) }), "h").unwrap_or(-1.0).to_int(),
        ) {
        Some((_, s)) => jb((s.outlived)())
        None => jb(false)
      }
    "notice" => {
      let about = jtext(Json::object({ "a": a(4) }), "a")
      let quiet = a(5) is True
      ctx.post_notice(
        self.key,
        jtext(Json::object({ "t": a(0) }), "t").unwrap_or(""),
        a(1),
        a(2),
        a(3),
        where_=where_ => {
          match about {
            Some(turn) => {
              ignore(
                ctx.store("setAbout", [jstr(turn), where_]) catch {
                  _ => Json::null()
                },
              )
              if !quiet {
                ignore(
                  ctx.store("notify", [jstr(self.key)]) catch {
                    _ => Json::null()
                  },
                )
              }
            }
            None => ()
          }
        },
      )
      Json::null()
    }
    "saidLast" => ctx.last_station_said(self.key)
    "read" => {
      let id = jnum_of(Json::object({ "i": a(0) }), "i")
        .unwrap_or(-1.0)
        .to_int()
      match self.reads.get(id) {
        Some(d) => {
          self.reads.remove(id)
          d.wait()
        }
        None => ()
      }
      Json::null()
    }
    "stateWrite" => {
      let id = a(0)
      let state = a(1)
      let token = jnum_of(Json::object({ "t": a(2) }), "t")
        .unwrap_or(-1.0)
        .to_int()
      guard self.records.get(token) is Some((words, about, watch, record)) else {
        return Json::null()
      }
      let write = (current : Json) => {
        match words {
          Some(w) =>
            if jtext(state, "kind") == Some("waiting") {
              ignore(ctx.store("setWaitFor", [id, jstr(w), jb(watch)]))
            } else {
              ignore(ctx.store("setNeed", [id, jstr(w)]))
            }
          None => ()
        }
        ignore(ctx.store("setAbout", [id, current]))
        ignore(
          ctx.store("declareTurn", [
            id,
            jfield(state, "kind"),
            if jtext(state, "kind") == Some("waiting") {
              jfield(state, "seconds")
            } else {
              Json::null()
            },
          ]),
        )
      }
      // (the conversations' record, where they gave one: it rereads what the state is about and calls `write` with it
      // inside its transaction; its failure (a busy database: StateWriteBusy) goes back to the program as it is)
      match record.bind(r => chat_state.callbacks.get(r)) {
        Some(record_fn) => {
          chat_state.next_cb += 1
          let write_id = chat_state.next_cb
          chat_state.callbacks[write_id] = async fn(given) {
            write(p52_json_of_jv(given.get(0).unwrap_or(Null)))
            Null
          }
          ignore(record_fn([Obj([(@jsjson.units("$fn"), Num(write_id.to_double()))])])) catch {
            e => {
              chat_state.callbacks.remove(write_id)
              raise e
            }
          }
          chat_state.callbacks.remove(write_id)
        }
        None => write(about)
      }
      Json::null()
    }
    "limitAfter" => ctx.limit_after(self.key, a(0))
    "canUpdateCodex" => jb(ctx.can_update_codex())
    "codexBefore" => {
      let id = jnum_of(Json::object({ "i": a(1) }), "i").unwrap_or(0.0).to_int()
      let version = match jnum_of(Json::object({ "h": a(0) }), "h") {
        Some(h) =>
          match self.agents.get(h.to_int()) {
            Some((_, s)) => (s.runtime_version)()
            None => None
          }
        None => None
      }
      self.codex[id] = version
      Json::null()
    }
    "updateCodex" => {
      let id = jnum_of(Json::object({ "i": a(0) }), "i").unwrap_or(0.0).to_int()
      let before = self.codex.get(id).unwrap_or(None)
      self.codex.remove(id)
      ignore(
        ctx.host.rt.fork(name="codex updated", async fn() {
          let why = try {
            ctx.update_codex(before)
            None
          } catch {
            e => Some(said_of(e))
          }
          if !self.closed {
            match why {
              Some(w) => self.post({ "codexUpdated": ji(id), "why": jstr(w) })
              None => self.post({ "codexUpdated": ji(id) })
            }
          }
        }),
      )
      Json::null()
    }
    _ =>
      raise LiveError(
        "a session asked the station for \{f}, which it does not know",
      )
  }
}
