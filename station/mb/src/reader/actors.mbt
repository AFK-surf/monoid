// The sessions' actors (station/src/sessions/actor.ts `SessionActor`) run here, in the `--agents` program: each
// session's state and its serial queue, every change of it going through the queue as there (a runtime's events, what
// its tools say, what the hub asks). What an actor needs of the station that is not here yet (the store, the drivers
// and their runtime sessions, the chat surfaces, the account pool, the live view, the words) it asks of Node (`rpc`),
// which answers with its own (station/src/sessions/mb-actor.ts); what the hub asks of an actor at once (where it
// stands, whether its queue is run out) Node reads of what this program last told it of each (`mirror`). Its time is
// Node's (`now`, said with every message), and its waits are Node's clock's (`after`, told back as `due`): a TestClock
// in tests moves them as it moves the rest.
//
// Node says, a line each: `actor` (one made: its key, its runtime), `call` (a method of one, as SessionActor's, its
// answer `returned`), `event` (its runtime session's event, by the generation it was opened as), `answer` (to an
// `rpc`), `due` (a wait's time come). It is said `rpc`, `after`, `mirror` and `returned`.

///|
priv struct Turn {
  id : String
  mut declared : Json?
  auth_retried : Bool
  mut codex_retried : Bool
  by : Json
}

///|
priv struct Working {
  connect : String
  channel : String
  thread_ts : String
  mut ts : Json
  first_ts : Json
  since : Double
}

///|
priv struct Agent {
  generation : Int
  /// its runtime session, as Node keeps it (`agent.*` asked by it)
  handle : Int
}

///|
/// A failed turn waiting for the machine's shared Codex update (actor.ts `codexUpdate`): its number, who it was for,
/// the turn, and whether the update is over.
priv struct CodexUpdate {
  id : Int
  by : Json
  turn : String
  mut finished : Bool
}

///|
priv struct Actor {
  key : String
  mut runtime : String
  tasks : @effect.Queue[async () -> Unit]
  /// tasks queued or running
  mut queued : Int
  /// what Node said of it, counted, and what of it this program has taken in (Node's `settled`, mb-actor.ts)
  mut seen : Int
  mut agent : Agent?
  mut stale : Bool
  mut restart : Bool
  mut profile : Json
  mut running_identity : Json
  mut read_back : Bool
  mut phase : String
  mut turn : Turn?
  mut codex_update : CodexUpdate?
  mut codex_next : Int
  mut nudges : Int
  asked_to_name : Array[String]
  mut overloads : Int
  mut tools_lost : String?
  mut tools_restarts : Int
  mut saying : (String, String)?
  mut last_said : String
  mut posted : Bool
  mut stop_requested : Bool
  mut resume_lost : Bool
  mut afresh : String?
  mut compacted_untold : Bool
  mut compacting : Bool
  mut over_while_compacting : Bool
  stopped : Array[Json]
  mut stopped_note : String?
  mut idle_since : Double
  mut working_for : Array[Working]
  mut ended_for : Array[Working]
  mut tools : Array[(String, String)]
  mut notices : Array[String]
  mut waiting : Int?
  mut waits : Int
  mut waiting_until : Double
  mut waiting_seconds : Double
  mut refill : Int?
  mut refills : Int
  mut refill_at : Double
  mut steered : Array[Json]
  mut steered_for : Array[Working]
  mut unread : Array[Json]
  mut delivery_interruptions : Int
  mut recoveries : Int
  mut recovery_deferred : Bool
  /// its waits on Node's clock, by name
  timers : Map[String, () -> Unit]
  /// what it last told Node of itself
  mut mirrored : String
}

///|
priv struct Actors {
  host : @host.Host
  actors : Map[String, Actor]
  asked : Map[Int, @effect.Deferred[Json]]
  timers : Map[Int, () -> Unit]
  mut next : Int
  mut now : Double
  /// tasks running and not waiting on Node: none, and what Node said is all taken in, and this program is quiet
  mut active : Int
  /// Node's lines taken in
  mut seen : Int
  /// the station's database, where Node said it is (a store in memory is Node's alone)
  mut db : @sql.Db?
}

///|
fn Actors::new(host : @host.Host) -> Actors {
  { host, actors: Map([]), asked: Map([]), timers: Map([]), next: 0, now: 0.0, active: 0, seen: 0, db: None }
}

///|
suberror Asked {
  Asked(Json)
}

///|
fn Asked::message(e : Error) -> String {
  match e {
    Asked(j) =>
      match j.value("message") {
        Some(String(s)) => s
        _ => j.stringify()
      }
    _ => e.to_string()
  }
}

///|
/// Says `message` to Node, with where this program stands (`active`): Node's `settled` and its tests' `settle` go by it.
fn Actors::say_node(self : Actors, message : Map[String, Json]) -> Unit {
  message["active"] = Json::number(self.active.to_double())
  message["seen"] = Json::number(self.seen.to_double())
  self.host.say(Json::object(message).stringify())
}

///|
/// Asks Node `fn` with `args` (station/src/sessions/mb-actor.ts `rpc`): its answer, or its error raised.
async fn Actors::rpc(self : Actors, key : String, f : String, args : Array[Json]) -> Json raise {
  self.next += 1
  let id = self.next
  let d : @effect.Deferred[Json] = @effect.Deferred::new()
  self.asked[id] = d
  if self.actors.get(key) is Some(a) {
    self.mirror(a)
  }
  self.active -= 1
  self.say_node({ "rpc": Json::number(id.to_double()), "actor": Json::string(key), "fn": Json::string(f), "args": Json::array(args) })
  // (counted again as its answer comes: `heard`)
  let answer = d.wait()
  match answer {
    { "error": err, .. } => raise Asked(err)
    _ => answer.value("value").unwrap_or(Json::null())
  }
}

///|
/// What is asked of Node and not waited for (it says nothing back that matters).
fn Actors::tell(self : Actors, key : String, f : String, args : Array[Json]) -> Unit {
  if self.actors.get(key) is Some(a) {
    self.mirror(a)
  }
  self.say_node({ "tell": Json::string(f), "actor": Json::string(key), "args": Json::array(args) })
}

///|
/// A wait of Node's clock (`after`): `then` once its time comes; the function given back lets it go.
fn Actors::after(self : Actors, ms : Double, then : () -> Unit) -> () -> Unit {
  self.next += 1
  let id = self.next
  self.timers[id] = then
  self.say_node({ "after": Json::number(id.to_double()), "ms": Json::number(if ms < 0.0 { 0.0 } else { ms }) })
  () => {
    if self.timers.contains(id) {
      self.timers.remove(id)
      self.say_node({ "cancel": Json::number(id.to_double()) })
    }
  }
}

///|
/// Runs `work` as a fiber of its own, counted active while it runs.
fn Actors::spawn(self : Actors, work : async () -> Unit) -> Unit {
  self.active += 1
  ignore(
    self.host.rt.fork(name="actor work", () => {
      work()
      self.active -= 1
      self.quiet()
    }),
  )
}

///|
/// Tells Node where this program stands, once nothing of it runs.
fn Actors::quiet(self : Actors) -> Unit {
  if self.active == 0 {
    self.say_node({ "quiet": Json::boolean(true) })
  }
}

///|
fn Actors::actor(self : Actors, key : String, runtime : String) -> Actor {
  match self.actors.get(key) {
    Some(a) => a
    None => {
      let a : Actor = {
        key,
        runtime,
        tasks: @effect.Queue::unbounded(),
        queued: 0,
        seen: 0,
        agent: None,
        stale: false,
        restart: false,
        profile: Json::null(),
        running_identity: Json::null(),
        read_back: false,
        phase: "idle",
        turn: None,
        codex_update: None,
        codex_next: 0,
        nudges: 0,
        asked_to_name: [],
        overloads: 0,
        tools_lost: None,
        tools_restarts: 0,
        saying: None,
        last_said: "",
        posted: false,
        stop_requested: false,
        resume_lost: false,
        afresh: None,
        compacted_untold: false,
        compacting: false,
        over_while_compacting: false,
        stopped: [],
        stopped_note: None,
        idle_since: self.now,
        working_for: [],
        ended_for: [],
        tools: [],
        notices: [],
        waiting: None,
        waits: 0,
        waiting_until: 0.0,
        waiting_seconds: 0.0,
        refill: None,
        refills: 0,
        refill_at: 0.0,
        steered: [],
        steered_for: [],
        unread: [],
        delivery_interruptions: 0,
        recoveries: 0,
        recovery_deferred: false,
        timers: Map([]),
        mirrored: "",
      }
      self.actors[key] = a
      // (its queue: one task at a time, in order)
      ignore(
        self.host.rt.fork(name="actor", () => {
          while (try { Some(a.tasks.take()) } catch { _ => None }) is Some(task) {
            task()
          }
        }),
      )
      a
    }
  }
}

///|
/// What the hub reads of it at once (mb-actor.ts `Mirror`), told as it changes.
fn Actors::mirror(self : Actors, a : Actor) -> Unit {
  let turn = match a.turn {
    Some(t) => Json::string(t.id)
    None => Json::null()
  }
  let state : Json = {
    "queued": Json::number(a.queued.to_double()),
    "seen": Json::number(a.seen.to_double()),
    "turn": turn,
    "codexUpdate": Json::boolean(a.codex_update is Some(_)),
    "agent": match a.agent { Some(g) => Json::number(g.handle.to_double()); None => Json::null() },
    "idleSince": Json::number(a.idle_since),
    "notices": Json::number(a.notices.length().to_double()),
    "waiting": Json::boolean(a.waiting is Some(_)),
    "refill": Json::boolean(a.refill is Some(_)),
    "unread": Json::array(a.unread.map(m => [m.value("thread").unwrap_or(Json::null()), m.value("n").unwrap_or(Json::null()), m.value("ts").unwrap_or(Json::null())])),
    "identity": a.running_identity,
    "runtime": Json::string(a.runtime),
    "closed": Json::boolean(a.phase == "closed"),
  }
  let said = state.stringify()
  if said == a.mirrored {
    return
  }
  a.mirrored = said
  self.say_node({ "mirror": Json::string(a.key), "state": state })
}

///|
/// Queues `task` (actor.ts `enqueue`): done once it has run, or was skipped (the actor closed); its failure logged.
async fn Actors::enqueue(self : Actors, a : Actor, task : async () -> Unit raise) -> Unit {
  a.queued += 1
  self.mirror(a)
  let done : @effect.Deferred[Unit] = @effect.Deferred::new()
  // (its caller is counted active while it waits on its task: the task is its work, waiting its turn or running)
  ignore(
    a.tasks.try_offer(() => {
      if a.phase != "closed" {
        task() catch {
          e => self.log(a, "error", "session task failed", fields={ "error": Json::string(Asked::message(e)) })
        }
      }
      a.queued -= 1
      self.mirror(a)
      ignore(done.succeed(()))
    }),
  )
  done.wait()
}

///|
pub async fn serve_actors(host : @host.Host) -> Unit {
  let s = Actors::new(host)
  host.say(({ "ready": true } : Json).stringify())
  while host.line() is Some(line) {
    s.heard(line)
    s.quiet()
  }
  @host.exit(0)
}

///|
/// A line of Node's.
fn Actors::heard(self : Actors, line : String) -> Unit {
  self.seen += 1
  let said = @json.parse(line) catch { _ => return }
  if said.value("now") is Some(Number(now, ..)) {
    self.now = now
  }
  match said {
    { "db": String(path), .. } => {
      self.db = Some(@sql.Db::attach(self.host, path, wait=5000)) catch {
        e => {
          @host.note("actors: the station's database not opened: " + (match e { @wire.ShellError(m) => m }))
          None
        }
      }
      return
    }
    { "answer": Number(id, ..), .. } => {
      let id = id.to_int()
      if self.asked.get(id) is Some(d) {
        self.asked.remove(id)
        // (what waited on it runs again from now: so it is said to be, before it does)
        self.active += 1
        ignore(d.succeed(said))
      }
      return
    }
    { "due": Number(id, ..), .. } => {
      let id = id.to_int()
      if self.timers.get(id) is Some(then) {
        self.timers.remove(id)
        then()
      }
      return
    }
    _ => ()
  }
  guard said.value("actor") is Some(String(key)) else { return }
  let a = match said.value("runtime") {
    Some(String(runtime)) => self.actor(key, runtime)
    _ =>
      match self.actors.get(key) {
        Some(a) => a
        None => return
      }
  }
  a.seen += 1
  match said {
    { "call": Number(id, ..), "method": String(method), .. } => {
      let args = match said.value("args") {
        Some(Array(args)) => args
        _ => []
      }
      // (what is done of it before it is queued, as it comes: in order with the rest Node says)
      self.spawn(() => {
        let answer : Map[String, Json] = { "returned": Json::number(id) }
        let value = self.called(a, method, args) catch {
          e => {
            answer["error"] = Json::string(Asked::message(e))
            if e is Asked(j) {
              answer["cause"] = j
            }
            Json::null()
          }
        }
        answer["value"] = value
        self.mirror(a)
        self.say_node(answer)
      })
    }
    { "event": event, "generation": Number(generation, ..), .. } => {
      let read = said.value("read").unwrap_or(Json::null())
      self.spawn(() => self.on_event(a, generation.to_int(), event, read) catch {
        e => self.log(a, "error", "session event failed", fields={ "error": Json::string(Asked::message(e)) })
      })
    }
    { "codexUpdated": Number(id, ..), .. } => {
      let why = match said.value("why") {
        Some(String(w)) => Some(w)
        _ => None
      }
      self.spawn(() => self.enqueue(a, async fn() { self.codex_updated(a, id.to_int(), why) }))
    }
    _ => ()
  }
  self.mirror(a)
}
