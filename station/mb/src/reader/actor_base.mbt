// What an actor asks of Node, in its own words (actors.mbt `rpc`): the store's, the hub's deps', its runtime
// session's, a chat surface's, the words and the formats of what agents are told.

///|
fn jstr(s : String) -> Json {
  Json::string(s)
}

///|
fn jnum(n : Double) -> Json {
  Json::number(n)
}

///|
fn jbool(b : Bool) -> Json {
  Json::boolean(b)
}

///|
fn str_of(v : Json?) -> String? {
  match v {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn num_of(v : Json?) -> Double? {
  match v {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
fn truthy(v : Json) -> Bool {
  @jsjson.json_truthy(Some(v))
}

///|
async fn Actors::store(self : Actors, a : Actor, f : String, args : Array[Json]) -> Json raise {
  // (what it reads and writes of it itself, on the station's database: actor_store.mbt)
  match self.local_store(f, args) {
    Some(v) => {
      self.mirror(a)
      v
    }
    None => self.rpc(a.key, "store." + f, args)
  }
}

///|
async fn Actors::deps(self : Actors, a : Actor, f : String, args : Array[Json]) -> Json raise {
  self.rpc(a.key, "deps." + f, args)
}

///|
/// Its runtime session's method (`agent.*`).
async fn Actors::agent_do(self : Actors, a : Actor, agent : Agent, f : String, args : Array[Json]) -> Json raise {
  ignore(a)
  self.rpc(a.key, "agent." + f, [jnum(agent.handle.to_double())] + args)
}

///|
async fn Actors::busy_of(self : Actors, a : Actor, agent : Agent?) -> Bool raise {
  match agent {
    Some(g) => truthy(self.agent_do(a, g, "busy", []))
    None => false
  }
}

///|
/// Whether `a`'s runtime session is still `agent` (none and none too). What runs beside the actor's queue can let it go
/// while the actor waits on Node: a dispose (actor_run.mbt `called`), its turn's end (actors.mbt `on_event`); what
/// was asked of the one let go of is not done to none, and what let it go goes on from there (a turn's end pumps).
fn still(a : Actor, agent : Agent?) -> Bool {
  match (a.agent, agent) {
    (Some(now), Some(was)) => now.handle == was.handle && now.generation == was.generation
    (None, None) => true
    _ => false
  }
}

///|
/// `a`'s runtime session where Node says it is busy and it is still `a`'s once Node answered (`still`); none otherwise.
async fn Actors::busy_agent(self : Actors, a : Actor) -> Agent? raise {
  let agent = a.agent
  guard self.busy_of(a, agent) && still(a, agent) else { return None }
  agent
}

///|
/// The station's words in its language (actor.ts `t`).
async fn Actors::t(self : Actors, a : Actor, key : String, args? : Json = Json::null()) -> String raise {
  match self.rpc(a.key, "t", [jstr(key), args]) {
    String(s) => s
    _ => key
  }
}

///|
fn Actors::log(self : Actors, a : Actor, level : String, message : String, fields? : Map[String, Json] = {}) -> Unit {
  let f = Map::from_iter(fields.iter())
  f["session"] = jstr(a.key)
  self.tell(a.key, "log", [jstr(level), jstr(message), Json::object(f)])
}

///|
async fn Actors::held(self : Actors, a : Actor) -> Bool raise {
  truthy(self.deps(a, "held", [jstr(a.key)]))
}

///|
async fn Actors::archived(self : Actors, a : Actor) -> Bool raise {
  match self.store(a, "getSession", [jstr(a.key)]) {
    Object(row) => !(row.get("archivedAt") is None || row.get("archivedAt") is Some(Null))
    _ => false
  }
}

///|
async fn Actors::has_pending(self : Actors, a : Actor) -> Bool raise {
  truthy(self.store(a, "hasPending", [jstr(a.key)]))
}

///|
async fn Actors::notify_store(self : Actors, a : Actor) -> Unit raise {
  ignore(self.store(a, "notify", [jstr(a.key)]))
}

///|
async fn Actors::set_running(self : Actors, a : Actor, on : Bool) -> Unit raise {
  ignore(self.store(a, "setRunning", [jstr(a.key), jbool(on)]))
}

///|
async fn Actors::last_turn(self : Actors, a : Actor) -> Json raise {
  self.store(a, "lastTurn", [jstr(a.key)])
}

///|
/// actor.ts `retrying`: a turn the provider had no room for, waiting to be tried again.
fn retrying(turn : Json) -> Bool {
  str_of(turn.value("outcome")) == Some("failed") &&
  str_of(turn.value("declared")) == Some("waiting") &&
  str_of(turn.value("detail")).unwrap_or("").has_prefix("overloaded")
}

///|
fn failed_again(turn : Json) -> Bool {
  str_of(turn.value("outcome")) == Some("failed") &&
  turn.value("declared") is (None | Some(Null)) &&
  ["network", "model", "other", "exited"].iter().any(r => str_of(turn.value("detail")).unwrap_or("").has_prefix(r + ":"))
}

///|
/// A turn Codex's backend refused with nothing but `{"detail":"Bad Request"}` (FB-26, `codexErrorInfo` "other", read as
/// `model`): the thread it was asked on, not the request, is what it refuses (openai/codex#58639, #61097), so trying it
/// again as it is fails the same way for good. Only that body, its spacing aside: a detail that names what was wrong
/// (`Unsupported parameter`), or says more, is not this.
fn bare_bad_request(message : String) -> Bool {
  let body = @json.parse(message) catch { _ => return false }
  match body {
    Object(o) => o.length() == 1 && o.get("detail") is Some(String("Bad Request"))
    _ => false
  }
}

///|
fn refused_bad_request(turn : Json) -> Bool {
  str_of(turn.value("outcome")) == Some("failed") &&
  (match str_of(turn.value("detail")) {
    Some(d) =>
      match d.strip_prefix("model: ") {
        Some(rest) => bare_bad_request(rest.to_string())
        None => false
      }
    None => false
  })
}

///|
fn given_up(turn : Json) -> Bool {
  str_of(turn.value("outcome")) == Some("completed") && turn.value("declared") is (None | Some(Null))
}

///|
fn retryable(turn : Json) -> Bool {
  failed_again(turn) || given_up(turn)
}

///|
/// actor.ts `retryAfter`.
fn retry_after(n : Int) -> Double {
  let mut v = 30.0
  for i = 0; i < n && v < 600.0; i = i + 1 {
    v = v * 2.0
  }
  if v > 600.0 { 600.0 } else { v }
}

///|
/// A declared state (`{kind, seconds?}`) as actor.ts `parseDeclared` reads a kind.
fn parse_declared(kind : String, wait : Double) -> Json? {
  if kind == "all_done" || kind == "final" {
    return Some({ "kind": "all_done" })
  }
  if ["need_human", "need_help", "block", "need_decision"].contains(kind) {
    return Some({ "kind": "need_help" })
  }
  if kind == "waiting" {
    return Some({ "kind": "waiting", "seconds": jnum(wait) })
  }
  None
}

///|
fn kind_of(d : Json?) -> String? {
  match d {
    Some(v) => str_of(v.value("kind"))
    None => None
  }
}

///|
fn settled_state(d : Json) -> Bool {
  str_of(d.value("kind")) != Some("waiting")
}

///|
/// actor.ts `endedIn`.
fn ended_in(declared : Json?, outcome : String) -> Json? {
  match declared {
    Some(d) if kind_of(Some(d)) == Some("waiting") && outcome != "completed" => None
    _ => declared
  }
}

///|
fn working_json(w : Working) -> Json {
  {
    "connect": jstr(w.connect),
    "channel": jstr(w.channel),
    "threadTs": jstr(w.thread_ts),
    "ts": w.ts,
    "firstTs": w.first_ts,
    "since": jnum(w.since),
  }
}

///|
fn working_of(v : Json) -> Working {
  {
    connect: str_of(v.value("connect")).unwrap_or(""),
    channel: str_of(v.value("channel")).unwrap_or(""),
    thread_ts: str_of(v.value("threadTs")).unwrap_or(""),
    ts: v.value("ts").unwrap_or(Json::null()),
    first_ts: v.value("firstTs").unwrap_or(v.value("ts").unwrap_or(Json::null())),
    since: num_of(v.value("since")).unwrap_or(0.0),
  }
}

///|
fn turn_for_nobody() -> Json {
  { "profile": Json::null(), "person": Json::null(), "thread": Json::null() }
}
