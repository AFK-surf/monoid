// The live view's shell (station/src/sessions/live.ts `LiveHub`): what running turns are doing is followed by the
// pseudo-actor `#live` of the sessions' program (reader/live.mbt); its shell says the program what the station tells it
// (a runtime's events, a session at work, a listener, a deleted session), answers what the program asks of it (where a
// session's transcripts are, what one gained, a page of its past) and gives each listener what the program told, a
// timeline's entries whole or in brief and with the session's usage as the counter has it. What is the machine's (a
// file's watch, a transcript's read, where one is) is the world's (`live.*`).

///|
/// How long a session is still followed once its turn is over (live.mbt `held_after_ms`).
pub let held_after_ms : Double = 120_000.0

///|
/// read/usage.ts `noUsage`: a session's usage before a call of it is recorded.
pub fn no_usage() -> Json {
  {
    "modelCalls": num(0.0),
    "inputTokens": num(0.0),
    "cachedTokens": num(0.0),
    "outputTokens": num(0.0),
    "cost": num(0.0),
    "unpricedCalls": num(0.0),
    "model": Json::null(),
    "contextWindow": Json::null(),
  }
}

///|
pub struct LiveShell {
  hub : Hub
  /// Each listener: its session, and whether it takes entries in brief.
  subs : Map[Int, (String, Bool)]
  mut next_sub : Int
  /// The sessions the station follows now, as the program last said.
  mut held : Array[String]
  /// The sessions whose transcript is watched there, and the usage last told of each.
  watching : Array[String]
  told : Map[String, Json]
  /// The sessions whose reading began from what the process before carried over.
  begun : Set[String]
  /// Whether the live view there has something going.
  mut pending : Bool
  /// Where the program last found each session's transcripts.
  located : Map[String, Json]
  mut closed : Bool
}

///|
pub fn LiveShell::new(hub : Hub) -> LiveShell {
  { hub, subs: {}, next_sub: 0, held: [], watching: [], told: {}, begun: Set([]), pending: false, located: {}, closed: false }
}

///|
/// Said to the program (`#call`), not waited for.
fn LiveShell::call(self : LiveShell, call_name : String, args : Array[Json]) -> Unit {
  if self.closed {
    return
  }
  (self.hub.world.tell)("live.call", { "method": Json::string(call_name), "args": Json::array(args) })
}

///|
/// Said to the program and waited for.
async fn LiveShell::ask(self : LiveShell, call_name : String, args : Array[Json]) -> Json {
  if self.closed {
    return Json::null()
  }
  (self.hub.world.ask)("live.call", { "method": Json::string(call_name), "args": Json::array(args) })
}

///|
/// Its usage as the counter has it (the session's summary), kept as told.
fn LiveShell::usage_of(self : LiveShell, key : String) -> Json {
  let usage = match (self.hub.store.session_usage(key) catch { _ => Json::null() }) {
    Null => no_usage()
    u => u
  }
  self.told[key] = usage
  usage
}

///|
/// `usageCounted`: the counter counted: each watched session whose usage changed is told it.
pub fn LiveShell::usage_counted(self : LiveShell) -> Unit {
  for key in self.watching.copy() {
    let before = self.told.get(key)
    if Some(self.usage_of(key)) != before {
      self.call("usage", [Json::string(key)])
    }
  }
}

///|
/// `event`: a runtime's live event for a session.
pub fn LiveShell::event(self : LiveShell, key : String, event : Json) -> Unit {
  self.call("event", [Json::string(key), event])
}

///|
/// `turnEnded`: the turn is over: what it wrote last is read and told before `clear`.
pub async fn LiveShell::turn_ended(self : LiveShell, key : String) -> Unit {
  ignore(self.ask("turnEnded", [Json::string(key)]))
}

///|
/// `running`: whether a session is at work.
pub fn LiveShell::running(self : LiveShell, key : String, on : Bool) -> Unit {
  self.call("running", [Json::string(key), Json::boolean(on)])
}

///|
/// `held`: the sessions the station follows now.
pub fn LiveShell::held_now(self : LiveShell) -> Array[String] {
  self.held.copy()
}

///|
/// `nowOf`: followed sessions as they are now, for a stream that opens (each timeline with its usage).
pub async fn LiveShell::now_of(self : LiveShell, keys : Array[String]) -> Json {
  let now = match self.ask("now", [Json::array(keys.map(Json::string))]) {
    Object(_) as n => n
    _ => Json::object({})
  }
  match now {
    Object(m) =>
      for key, messages in m {
        for msg in items(Some(messages)) {
          match msg {
            Object(o) if o.get("type") == Some(Json::string("timeline")) => o["usage"] = self.usage_of(key)
            _ => ()
          }
        }
      }
    _ => ()
  }
  now
}

///|
/// `subscribe`: follows a session from entry `from` (only its `last`, when given); the id to unsubscribe with.
pub fn LiveShell::subscribe(self : LiveShell, key : String, from : Double, last : Double?, brief? : Bool = false) -> Int {
  self.next_sub += 1
  let id = self.next_sub
  self.subs[id] = (key, brief)
  self.call("subscribe", [
    Json::string(key),
    num(from),
    match last {
      Some(l) => num(l)
      None => Json::null()
    },
    int(id),
    Json::boolean(brief),
  ])
  id
}

///|
pub fn LiveShell::unsubscribe(self : LiveShell, key : String, id : Int) -> Unit {
  if !self.subs.contains(id) {
    return
  }
  self.subs.remove(id)
  self.call("unsubscribe", [Json::string(key), int(id)])
}

///|
/// `soon`: its transcript changed: what it gained is read once the burst is over.
pub fn LiveShell::soon(self : LiveShell, key : String) -> Unit {
  self.call("soon", [Json::string(key)])
}

///|
/// `moved`: the session went on in a new runtime session.
pub fn LiveShell::moved(self : LiveShell, key : String) -> Unit {
  self.call("moved", [Json::string(key)])
}

///|
/// `forget`: a deleted session: nothing of it is watched or kept any more.
pub fn LiveShell::forget(self : LiveShell, key : String) -> Unit {
  let gone = []
  for id, sub in self.subs {
    if sub.0 == key {
      gone.push(id)
    }
  }
  for id in gone {
    self.subs.remove(id)
  }
  self.told.remove(key)
  self.located.remove(key)
  self.call("forget", [Json::string(key)])
}

///|
/// `carried`: what the program carries over to the next station process.
pub async fn LiveShell::carried(self : LiveShell) -> Json {
  let c = self.ask("carried", [])
  {
    "plans": match field(c, "plans") { Some(Array(_) as p) => p; _ => Json::array([]) },
    "tails": match field(c, "tails") { Some(Array(_) as t) => t; _ => Json::array([]) },
  }
}

///|
pub fn LiveShell::take_plans(self : LiveShell, carried : Json) -> Unit {
  self.call("takePlans", [carried])
}

///|
pub fn LiveShell::take_tails(self : LiveShell, carried : Json) -> Unit {
  self.call("takeTails", [carried])
}

///|
pub fn LiveShell::close(self : LiveShell) -> Unit {
  self.closed = true
  (self.hub.world.tell)("live.disarmAll", Json::null())
}

///|
let brief_key : String = "~brief"

///|
/// An entry as read, whole.
fn whole_of(e : Json) -> Json {
  match e {
    Object(m) if m.contains(brief_key) => {
      let c = m.copy()
      c.remove(brief_key)
      Json::object(c)
    }
    _ => e
  }
}

///|
/// An entry as read, in brief.
fn brief_of_read(e : Json) -> Json {
  match field(e, brief_key) {
    Some(b) => b
    None => whole_of(e)
  }
}

///|
/// What the program told (`#tellOf`).
pub fn LiveShell::told_by_program(self : LiveShell, f : String, args : Array[Json]) -> Unit {
  let s = (i : Int) => match args.get(i) {
    Some(String(t)) => t
    _ => ""
  }
  match f {
    "told" => {
      let key = s(0)
      let to = items(args.get(1))
      let message = args.get(2).unwrap_or(Json::null())
      let briefed = args.get(3) is Some(True)
      let (whole_message, brief_message) = match message {
        Object(m) if m.get("type") == Some(Json::string("timeline")) => {
          let usage = self.usage_of(key)
          let entries = items(m.get("entries"))
          let whole = entries.map(whole_of)
          let briefs = if briefed { whole } else { entries.map(brief_of_read) }
          let w = m.copy()
          w["usage"] = usage
          w["entries"] = Json::array(whole)
          let b = w.copy()
          b["entries"] = Json::array(briefs)
          (Json::object(w), Json::object(b))
        }
        _ => (message, message)
      }
      for t in to {
        let parts = items(Some(t))
        let id = match parts.get(0) {
          Some(Number(n, ..)) => n.to_int()
          _ => -1
        }
        let in_brief = parts.get(1) is Some(True)
        let held = parts.get(2) is Some(True)
        if held {
          (self.hub.world.tell)("live.heldTold", { "key": Json::string(key), "message": brief_message })
        } else if self.subs.contains(id) {
          (self.hub.world.tell)("live.listener", {
            "id": int(id),
            "message": if in_brief { brief_message } else { whole_message },
          })
        }
      }
    }
    "held" => self.held = items(args.get(0)).map(js_string)
    "pending" => self.pending = args.get(0) is Some(True)
    "length" => self.hub.note_length(s(0), args.get(1).unwrap_or(Json::null()))
    "count" =>
      match self.hub.counter {
        Some(c) => c.soon(s(0))
        None => ()
      }
    "watching" =>
      if args.get(1) is Some(True) {
        if !self.watching.contains(s(0)) {
          self.watching.push(s(0))
        }
      } else {
        remove_all(self.watching, s(0))
        self.told.remove(s(0))
        (self.hub.world.tell)("live.abortLookups", Json::string(s(0)))
      }
    "begun" => self.begun.add(s(0))
    "unfollow" => (self.hub.world.tell)("live.unfollow", Json::string(s(0)))
    "arm" => (self.hub.world.tell)("live.arm", { "key": Json::string(s(0)), "path": Json::string(s(1)) })
    "disarm" => (self.hub.world.tell)("live.disarm", Json::string(s(0)))
    "log" => (self.hub.world.tell)("log", Json::array(args))
    _ => ()
  }
}

///|
/// What the program asked (`#asked`): where a session's transcripts are, a read of what one gained, a page of its
/// past, where the reading of it stands; the machine's, the world's.
pub async fn LiveShell::asked_by_program(self : LiveShell, f : String, args : Array[Json]) -> Json {
  match f {
    "locate" => {
      let key = js_string(args.get(0).unwrap_or(Json::null()))
      let at = (self.hub.world.ask)("live.locate", { "key": Json::string(key), "following": Json::boolean(args.get(1) is Some(True)) })
      match at {
        Null => self.located.remove(key)
        _ => self.located[key] = at
      }
      at
    }
    "tailRead" => (self.hub.world.ask)("live.tailRead", Json::array(args))
    "page" => (self.hub.world.ask)("live.page", Json::array(args))
    "state" => {
      let key = js_string(args.get(0).unwrap_or(Json::null()))
      ignore((self.hub.world.ask)("live.handedOver", Json::null()))
      if self.begun.contains(key) {
        self.begun.remove(key)
        return Json::null()
      }
      (self.hub.world.ask)("live.state", Json::string(key))
    }
    _ => raise Refused("the live view asks nothing called \{f}")
  }
}
