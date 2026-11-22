// own-process.ts as each runtime's session takes it (OwnProcessSession): a session in a process of its own, read by
// this program (its lines: station/mb src/reader agents_own.mbt with src/acp, src/dsh, src/cursor, src/pi), whose
// driver writes it requests and answers it, holds where its turn stands as the program says it, waits for the answers
// to its requests, and is told its process went away. What it does is said in order (`Own::trace`): what it writes to
// the process, says and tells the program, the runtime's events it gives on, what its transcript keeps, its requests
// answered or failed; in the words the TypeScript's fake process and events hear them (station/test
// mb-agent-runtimes.test.ts).

///|
struct Wait {
  refused : (J) -> String?
  done : (Result[J, String]) -> Unit
}

///|
/// A session's process and what it is told, as its driver holds them.
pub struct Own {
  kind : String
  mut session_id : String
  /// Where its turn stands (the program's word for it; `closed` apart, as turnNow leaves it out).
  mut turn : Fields
  mut closed : Bool
  mut live_state : J
  mut tools_url : String?
  /// A snapshot it was taken up from said no tools (undefined there): its own says none either.
  mut tools_absent : Bool
  runner : String
  /// What the process's frozen state is said to be at a handover (proc.frozenState()).
  frozen : J?
  waits : Map[String, Wait]
  /// What answers resolved meanwhile, given on once what is said now is (as a promise's continuation runs after).
  later : Array[() -> Unit]
  uuids : Array[String]
  mut now : Double
  /// What it keeps is being written (its transcript's lines, Grok Build's usage): a turn's end is said once it is,
  /// after what answers resolved meanwhile (`settled`).
  mut writing : Bool
  trace : Array[J]
}

///|
pub fn Own::new(kind : String, session_id : String, turn : Fields, live : J, runner : String) -> Own {
  {
    kind,
    session_id,
    turn,
    closed: false,
    live_state: live,
    tools_url: None,
    tools_absent: false,
    runner,
    frozen: None,
    waits: {},
    later: [],
    uuids: [],
    now: 0.0,
    writing: false,
    trace: [],
  }
}

///|
fn Own::uuid(self : Own) -> String {
  if self.uuids.is_empty() {
    "00000000-0000-4000-8000-000000000000"
  } else {
    self.uuids.remove(0)
  }
}

///|
fn Own::note(self : Own, what : String, value : J) -> Unit {
  self.trace.push(obj([(what, value)]))
}

///|
fn Own::write(self : Own, line : String) -> Unit {
  self.note("write", js(line))
}

///|
fn Own::say(self : Own, name : String, args? : J) -> Unit {
  self.note("say", Arr([js(name), args.unwrap_or(Null)]))
}

///|
fn Own::tell(self : Own, what : String) -> Unit {
  self.note("tell", js(what))
}

///|
fn Own::event(self : Own, e : J) -> Unit {
  self.note("event", e)
}

///|
/// Runs what answers resolved: each after what was said before it.
pub fn Own::settle(self : Own) -> Unit {
  while !self.later.is_empty() {
    let f = self.later.remove(0)
    f()
  }
}

///|
/// What is being written, done: what resolved meanwhile comes first.
pub fn Own::written(self : Own) -> Unit {
  if self.writing {
    self.settle()
    self.writing = false
  }
}

///|
/// `Waiting.wait`: the answer to `id`, `done` told once it comes (or fails).
fn Own::wait(self : Own, id : String, refused : (J) -> String?, done : (Result[J, String]) -> Unit) -> Unit {
  self.waits[id] = { refused, done }
}

///|
/// `Waiting.answer`: whether `id` was waited for.
fn Own::answer(self : Own, id : J?, message : J) -> Bool {
  guard id is Some(Str(s)) else { return false }
  let key = t(s)
  guard self.waits.get(key) is Some(w) else { return false }
  self.waits.remove(key)
  let outcome = match (w.refused)(message) {
    Some(error) => Err(error)
    None => Ok(message)
  }
  self.later.push(() => (w.done)(outcome))
  true
}

///|
/// `Waiting.failAll`.
fn Own::fail_all(self : Own, error : String) -> Unit {
  let waits = self.waits.values().collect()
  self.waits.clear()
  for w in waits {
    self.later.push(() => (w.done)(Err(error)))
  }
}

///|
/// A request's answer as the trace says it: `label` resolved with what it gives, or failed with its words.
fn Own::resolved(self : Own, label : String, outcome : Result[J, String]) -> Unit {
  match outcome {
    Ok(v) => self.note("resolved", Arr([js(label), v]))
    Err(e) => self.note("rejected", Arr([js(label), js(e)]))
  }
}

///|
fn Own::turn_flag(self : Own, name : String) -> Bool {
  truthy(self.turn.get(name))
}

///|
fn Own::set_flag(self : Own, name : String, value : Bool) -> Unit {
  self.turn.set(name, Bool(value))
}

///|
/// `turnNow`: the turn as the program is told it.
pub fn Own::turn_now(self : Own) -> J {
  self.turn.json()
}

///|
/// `take`: the turn as the program says it.
fn Own::take(self : Own, t0 : J?) -> Unit {
  match t0 {
    Some(Obj(_) as o) => {
      let f = Fields::new()
      for e in fields(Some(o)) {
        if e.0 != "closed" {
          f.set(e.0, e.1)
        }
      }
      self.turn = f
    }
    _ => ()
  }
}

///|
/// `handOver`: stops hearing it, for a snapshot; where it stood then (none: it was not read there).
fn Own::hand_over(self : Own) -> J? {
  self.note("freeze", Bool(true))
  self.closed = true
  self.frozen
}

///|
/// What the program said of a turn's state where the snapshot's or the session's is: `turn` with `name` as `=== true`.
fn strictly(turn : J?, name : String) -> J {
  Bool(get(turn, name) is Some(Bool(true)))
}

///|
/// `startable`: a turn can be started now, else why not.
fn Own::startable(self : Own, busy : Bool) -> String? {
  if self.closed {
    Some("\{self.kind} session is closed")
  } else if busy {
    Some("a turn is already running")
  } else {
    None
  }
}

///|
/// `heardHosted`'s events: each the session's own or given on, the turn each carries taken, `routed` said where the
/// program gave it its actor.
fn Own::told(self : Own, heard : J?, took : (J) -> Bool) -> Unit {
  for e in arr(get(heard, "events")) {
    if took(e) {
      continue
    }
    let event = Fields::new()
    let mut turn = None
    for f in fields(Some(e)) {
      if f.0 == "turn" {
        turn = Some(f.1)
      } else {
        event.set(f.0, f.1)
      }
    }
    if is_s(get(Some(e), "type"), "turnEnded") {
      self.written()
    }
    if turn is Some(tn) {
      self.take(Some(tn))
    }
    if is_true(get(heard, "routed")) {
      event.set("routed", Bool(true))
    }
    self.event(event.json())
  }
  self.take(get(heard, "turn"))
}

///|
/// `exited`: its process went away; a turn running fails as exited (`cut_short` first), then the session closes.
fn Own::exited(self : Own, said : String, stderr : String, busy : Bool, idle : () -> Unit, cut_short : (String) -> Unit) -> Unit {
  let why = if stderr == "" { "" } else { ": \{stderr}" }
  self.closed = true
  self.fail_all("\{self.kind} exited (\{said})\{why}")
  idle()
  if busy {
    cut_short(said)
  }
  self.written()
  if busy {
    self.event(
      obj([
        ("type", js("turnEnded")),
        (
          "outcome",
          obj([("kind", js("failed")), ("reason", js("exited")), ("message", js("\{self.kind} exited (\{said}) during the turn\{why}"))]),
        ),
      ]),
    )
  }
  self.event(obj([("type", js("closed")), ("why", js("\{self.kind} exited (\{said})\{why}"))]))
  self.note("forget", Bool(true))
}

///|
/// `dispose`: let go; its requests fail, its process ended.
fn Own::dispose(self : Own) -> Unit {
  self.note("forget", Bool(true))
  self.closed = true
  self.fail_all("\{self.kind} session is closed")
  self.note("kill", int(5000))
}

///|
fn tools_json(url : String?) -> J {
  match url {
    Some(u0) => js(u0)
    None => Null
  }
}

///|
/// A JSON line of `{id, <field>: op, ...params}` as dsh's, Cursor's and Pi's bridges take a request.
fn request_line(id : String, field : String, op : String, params : J) -> String {
  let f = Fields::of([("id", js(id)), (field, js(op))])
  f.spread(spread_of(Some(params)))
  stringify(f.json())
}
