// What the station's Cursor driver (station/src/agents/cursor-bridge.mjs, on Cursor's SDK: a line of JSON a message)
// says does to its session, as the TypeScript station had it (live.ts `LiveFromCursor`, `cursorCall`, `cursorOutput`;
// cursor.ts `CursorSession.heard`, `toolsLost`, `outcomeOf`; the reference is station/test/reference/live.ts): the live
// steps a device is shown, the turn's start and end with its outcome, the station's tools out of reach. A line that is
// neither a message of the run nor its end answers a request of Node's, which is Node's to read (`Said.node`); a prompt
// it refuses ends the turn here.

///|
using @jsjson {type JValue}

///|
using @live_wire {
  jstr, obj, field, str, non_empty, is_str, has_prefix, or_else, pretty, joined, start, delta, live, failed,
  completed, aborted, turn_started, turn_ended, tools_lost_event, find_entry, set_entry, load_entries,
  entries_json, opt_str_json, transition, end_entry, end_open, has_open_tool, str_or_js,
}

///|
type J = JValue

///|
fn joined_nonempty(parts : Array[String]) -> String {
  joined(parts.filter(t => t.length() > 0), "\n")
}

///|
/// live.ts `cursorCall`: a call of Cursor's as the station names it, an MCP server's tool as mcp__<server>__<tool> with
/// its own input.
pub fn cursor_call(name : String, args : J?) -> (String, J) {
  if name == "mcp" && field(args, "providerIdentifier") is Some(Str(p)) && field(args, "toolName") is Some(Str(t)) {
    return ("mcp__" + p + "__" + t, or_else(field(args, "args"), Obj([])))
  }
  (name, or_else(args, Obj([])))
}

///|
/// live.ts `cursorOutput`: what a call gave back, as text.
pub fn cursor_output(result : J?) -> String {
  let mut r = result
  if r is Some(Str(s)) {
    match (try Some(@jsjson.parse(s)) catch { _ => None }) {
      Some(v) => r = Some(v)
      None => return s
    }
  }
  let v = match field(r, "value") {
    None | Some(Null) => r
    x => x
  }
  if field(v, "stdout") is Some(Str(_)) || field(v, "stderr") is Some(Str(_)) {
    return joined_nonempty([str(field(v, "stdout")).unwrap_or(""), str(field(v, "stderr")).unwrap_or("")])
  }
  if field(v, "content") is Some(Arr(items)) {
    return joined_nonempty(
      items.map(c => match str(field(field(Some(c), "text"), "text")) {
        Some(t) => t
        None => str(field(Some(c), "text")).unwrap_or("")
      }),
    )
  }
  if field(r, "error") is Some(Str(e)) {
    return e
  }
  match r {
    None | Some(Null) => ""
    Some(Str(s)) => s
    Some(x) => @jsjson.stringify(x)
  }
}

///|
/// A session's live steps (live.ts `LiveFromCursor`): the steps started and not ended with what each is, in the order a
/// Map keeps them; the text or thoughts step under way; how many such were made; where the turn stands.
pub(all) struct Live {
  open : Array[(String, String)]
  mut said : String?
  mut n : Int
  mut phase : String?
}

///|
pub fn Live::new() -> Live {
  { open: [], said: None, n: 0, phase: None }
}

///|
/// What `state` said: live.ts `CursorLiveState`.
pub fn Live::of_state(state : J) -> Live {
  let live = Live::new()
  load_entries(state, "open", live.open)
  if state.get("said") is Some(Str(s)) {
    live.said = Some(s)
  }
  if state.get("n") is Some(Num(n)) {
    live.n = n.to_int()
  }
  if state.get("phase") is Some(Str(p)) {
    live.phase = Some(p)
  }
  live
}

///|
pub fn Live::state(self : Live) -> J {
  obj([
    ("open", entries_json(self.open)),
    ("said", opt_str_json(self.said)),
    ("n", Num(self.n.to_double())),
    ("phase", opt_str_json(self.phase)),
  ])
}

///|
fn Live::to(self : Live, next : String, out : Array[J]) -> Unit {
  self.phase = transition(self.phase, next, out)
}

///|
/// The text or thoughts under way ends: something else came.
fn Live::stop_saying(self : Live, out : Array[J]) -> Unit {
  if self.said is Some(s) {
    end_entry(self.open, s, out)
  }
  self.said = None
}

///|
/// A prompt was given: the turn is with the model.
pub fn Live::prompted(self : Live) -> Array[J] {
  let out = []
  self.to("requesting", out)
  out
}

///|
fn Live::step_of(self : Live, id : String) -> String? {
  match find_entry(self.open, id) {
    Some(i) => Some(self.open[i].1)
    None => None
  }
}

///|
/// The live steps an SDK message says (live.ts `feed`).
pub fn Live::feed(self : Live, message : J?) -> Array[J] {
  let out = []
  let kind = str(field(message, "type")).unwrap_or("")
  if kind == "status" && is_str(field(message, "status"), "RUNNING") {
    self.to("requesting", out)
  } else if kind == "thinking" || kind == "assistant" {
    let step = if kind == "thinking" { "thinking" } else { "text" }
    let text = if step == "thinking" {
      str(field(message, "text")).unwrap_or("")
    } else {
      match field(field(message, "message"), "content") {
        Some(Arr(items)) => {
          let all = StringBuilder()
          for c in items {
            if is_str(field(Some(c), "type"), "text") {
              all.write_string(str(field(Some(c), "text")).unwrap_or(""))
            }
          }
          all.to_string()
        }
        _ => ""
      }
    }
    let same = match self.said {
      Some(s) => self.step_of(s) == Some(step)
      None => false
    }
    if !same {
      if text.length() == 0 {
        return out
      }
      self.stop_saying(out)
      let run = str(field(message, "run_id")).unwrap_or("cursor")
      let id = run + ":" + self.n.to_string()
      self.n += 1
      self.said = Some(id)
      set_entry(self.open, id, step)
      out.push(start(id, step, None, None))
    }
    if step == "text" {
      self.to("responding", out)
    }
    if text.length() > 0 {
      out.push(delta(self.said.unwrap(), "text", text))
    }
  } else if kind == "tool_call" {
    guard non_empty(field(message, "call_id")) is Some(id) else { return out }
    self.stop_saying(out)
    if is_str(field(message, "status"), "running") {
      if find_entry(self.open, id) is Some(_) {
        return out
      }
      let (name, input) = cursor_call(str(field(message, "name")).unwrap_or("tool"), field(message, "args"))
      set_entry(self.open, id, "tool")
      self.to("working", out)
      out.push(start(id, "tool", Some(name), Some(@claude.chars(pretty(Some(input)), @live_wire.INPUT_MOST))))
      return out
    }
    if find_entry(self.open, id) is None {
      // One done that this station did not see start (taken up after it started): started with its input whole.
      let (name, input) = cursor_call(str(field(message, "name")).unwrap_or("tool"), field(message, "args"))
      set_entry(self.open, id, "tool")
      out.push(start(id, "tool", Some(name), Some(@claude.chars(pretty(Some(input)), @live_wire.INPUT_MOST))))
    }
    let output = cursor_output(field(message, "result"))
    if output.length() > 0 {
      out.push(delta(id, "output", @claude.chars(output, @live_wire.INPUT_MOST)))
    }
    end_entry(self.open, id, out)
    if !has_open_tool(self.open) {
      self.to("requesting", out)
    }
  } else if kind == "user" {
    // A message put in the turn: what the model says next is a step of its own.
    self.stop_saying(out)
  }
  out
}

///|
/// The turn ended: whatever is still open ends with it.
pub fn Live::ended(self : Live) -> Array[J] {
  let out = end_open(self.open)
  self.said = None
  self.phase = None
  out
}

///|
/// Where a session's turn stands (own-process.ts `TurnState`).
pub(all) struct Turn {
  mut busy : Bool
  mut aborting : Bool
}

///|
/// The turn as cursor.ts `CursorSnapshot.turn` says it.
pub fn Turn::json(self : Turn) -> J {
  obj([("busy", Bool(self.busy)), ("aborting", Bool(self.aborting))])
}

///|
pub fn Turn::of_json(v : J) -> Turn {
  { busy: v.get("busy") is Some(Bool(true)), aborting: v.get("aborting") is Some(Bool(true)) }
}

///|
/// A session as the program reads its process: its turn, its live steps, its calls of the station's tools not answered.
pub(all) struct Session {
  turn : Turn
  live : Live
  calls : Array[String]
}

///|
pub fn Session::new(turn : Turn, live : Live) -> Session {
  { turn, live, calls: [] }
}

///|
/// What a line of its output comes to: the runtime's events, and whether Node reads the line.
pub(all) struct Said {
  events : Array[J]
  node : Bool
}

///|
/// cursor.ts `outcomeOf`: how a run's end ends the turn.
pub fn outcome_of(end : J?) -> J {
  if is_str(field(end, "status"), "cancelled") {
    return aborted()
  }
  if is_str(field(end, "status"), "finished") {
    return completed()
  }
  let message = match field(field(end, "error"), "message") {
    Some(Str(s)) => s
    _ => {
      let status = match field(end, "status") {
        None | Some(Null) => "without saying how"
        Some(v) => @jsjson.js_string(v)
      }
      "the run ended " + status
    }
  }
  let code = str_or_js(field(field(end, "error"), "code"))
  failed(@claude.failure_of(code + " " + message), @claude.chars(message, 1000))
}

///|
/// What a line says (cursor.ts `heard`).
pub fn Session::line(self : Session, message : J) -> Said {
  let m = Some(message)
  let events = []
  if is_str(field(m, "ev"), "message") {
    // A turn running that this station did not see start (taken up after a crash just as it was given).
    if !self.turn.busy {
      self.turn.busy = true
      events.push(turn_started())
    }
    for e in self.live.feed(field(m, "message")) {
      events.push(live(e))
    }
    if self.tools_lost(field(m, "message")) is Some(why) {
      events.push(tools_lost_event(why))
    }
    return { events, node: false }
  }
  if is_str(field(m, "ev"), "end") {
    let outcome = if self.turn.aborting && !is_str(field(m, "status"), "finished") {
      aborted()
    } else {
      outcome_of(m)
    }
    if !self.turn.busy {
      events.push(turn_started())
    }
    self.turn.busy = false
    self.turn.aborting = false
    self.calls.clear()
    for e in self.live.ended() {
      events.push(live(e))
    }
    events.push(turn_ended(outcome))
    return { events, node: false }
  }
  // (an answer to a request: Node's; a prompt refused, the run not started, ends the turn here)
  if field(m, "error") is Some(Str(error)) && str(field(m, "id")) is Some(id) && has_prefix(id, "prompt:") && self.turn.busy {
    self.turn.busy = false
    self.turn.aborting = false
    for e in self.live.ended() {
      events.push(live(e))
    }
    let code = match field(m, "code") {
      None => []
      Some(c) => [("code", c)]
    }
    let end = J::Obj([("status", jstr("error")), ("error", Obj([("message", Str(error))] + code))])
    events.push(turn_ended(outcome_of(Some(end))))
  }
  { events, node: true }
}

///|
/// cursor.ts `toolsLost`: a call to one of the station's tools failed as unreachable.
fn Session::tools_lost(self : Session, message : J?) -> String? {
  guard is_str(field(message, "type"), "tool_call") && field(message, "call_id") is Some(Str(id)) else { return None }
  let provider = str_or_js(field(field(message, "args"), "providerIdentifier"))
  let running = is_str(field(message, "status"), "running")
  if running && is_str(field(message, "name"), "mcp") && provider == "stillfail" {
    self.calls.push(id)
  }
  if running {
    return None
  }
  guard self.calls.search(id) is Some(i) else { return None }
  ignore(self.calls.remove(i))
  guard is_str(field(message, "status"), "error") else { return None }
  let text = match field(message, "result") {
    Some(Str(s)) => s
    None | Some(Null) => "\"\""
    Some(v) => @jsjson.stringify(v)
  }
  if @claude.unreachable(text) {
    Some(@claude.chars(text, 300))
  } else {
    None
  }
}

///|
/// A prompt of Node's (cursor.ts `prompt`): the turn runs, with the model.
pub fn Session::prompted(self : Session) -> Array[J] {
  self.turn.busy = true
  self.live.prompted().map(live)
}

///|
/// Its process went away during a turn: its steps end with it (cursor.ts `cutShort`).
pub fn Session::cut_short(self : Session) -> Array[J] {
  if self.turn.busy {
    self.live.ended().map(live)
  } else {
    []
  }
}

///|
/// What a station that crashed had read of its output, read again (cursor.ts `crashed`).
pub(all) struct Replay {
  mut session : String?
  turn : Turn
  live : Live
}

///|
pub fn Replay::new() -> Replay {
  { session: None, turn: { busy: false, aborting: false }, live: Live::new() }
}

///|
pub fn Replay::line(self : Replay, message : J) -> Unit {
  let m = Some(message)
  if is_str(field(m, "id"), "open") && field(m, "session") is Some(Str(s)) {
    self.session = Some(s)
  }
  if is_str(field(m, "ev"), "message") {
    self.turn.busy = true
    ignore(self.live.feed(field(m, "message")))
  } else if is_str(field(m, "ev"), "end") {
    self.turn.busy = false
    ignore(self.live.ended())
  }
}
