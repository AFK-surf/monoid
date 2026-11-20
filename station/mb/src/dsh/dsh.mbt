// What DeepSeek Harness's driver plugin says (station/src/agents/dsh-bridge.mjs: a line of JSON a message) does to its
// session, as the TypeScript station had it (live.ts `LiveFromDsh`; dsh.ts `DshSession.heard`, `toolsLost`,
// `outcomeOf`, `classifyFailure`; the reference is station/test/reference/live.ts): the live steps a device is shown,
// the turn's start and end with its outcome, the station's tools out of reach. A line with no `ev` answers a request of
// Node's, which is Node's to read (`Said.node`); a prompt it refuses ends the turn here. Lines are read as JSON.parse
// reads them and what is said of them written as JSON.stringify writes it (station/jsjson).

///|
using @jsjson {type JValue}

///|
using @live_wire {
  jstr, obj, field, str, non_empty, is_str, has_prefix, or_else, pretty, joined, start, delta, live, failed,
  completed, aborted, turn_started, turn_ended, tools_lost_event, find_entry, set_entry, load_entries,
  entries_json, opt_str_json, transition, end_entry, end_open, end_non_tool_prefix, has_open_tool,
  station_tool, str_or_js, content_text,
}

///|
type J = JValue

///|
/// A session's live steps (live.ts `LiveFromDsh`): the steps started and not ended with what each is, in the order a
/// Map keeps them; a stream block's call (attempt#index, its deltas after the first name only the index); where the
/// turn stands with the model.
pub(all) struct Live {
  open : Array[(String, String)]
  calls : Array[(String, String)]
  mut phase : String?
}

///|
pub fn Live::new() -> Live {
  { open: [], calls: [], phase: None }
}

///|
/// What `state` said (a station's before, or this one's after a crash): live.ts `DshLiveState`.
pub fn Live::of_state(state : J) -> Live {
  let live = Live::new()
  load_entries(state, "open", live.open)
  load_entries(state, "calls", live.calls)
  if state.get("phase") is Some(Str(p)) {
    live.phase = Some(p)
  }
  live
}

///|
pub fn Live::state(self : Live) -> J {
  obj([
    ("open", entries_json(self.open)),
    ("calls", entries_json(self.calls)),
    ("phase", opt_str_json(self.phase)),
  ])
}

///|
fn Live::to(self : Live, next : String, out : Array[J]) -> Unit {
  self.phase = transition(self.phase, next, out)
}

///|
/// A prompt was given: the turn is with the model.
pub fn Live::prompted(self : Live) -> Array[J] {
  let out = []
  self.to("requesting", out)
  out
}

///|
/// The live steps a message says (live.ts `feed`).
pub fn Live::feed(self : Live, message : J) -> Array[J] {
  let out = []
  let m = Some(message)
  if is_str(field(m, "ev"), "stream") {
    self.stream(field(m, "frame"), out)
  } else if is_str(field(m, "ev"), "event") {
    self.event(str(field(m, "type")).unwrap_or(""), Some(or_else(field(m, "data"), Obj([]))), out)
  }
  out
}

///|
fn Live::stream(self : Live, frame : J?, out : Array[J]) -> Unit {
  let attempt = str(field(frame, "attemptId")).unwrap_or("")
  if is_str(field(frame, "type"), "start") {
    return self.to("requesting", out)
  }
  if is_str(field(frame, "type"), "end") {
    // An attempt that did not commit (cancelled, failed, retried): what it said so far ends with it.
    if !is_str(field(field(frame, "outcome"), "kind"), "committed") {
      end_non_tool_prefix(self.open, attempt + "#", out)
    }
    return
  }
  let chunk = field(frame, "chunk")
  if !is_str(field(frame, "type"), "chunk") || !@jsjson.jval_truthy(chunk) {
    return
  }
  let index = match field(chunk, "index") {
    Some(Num(_) as n) => @jsjson.stringify(n)
    _ => ""
  }
  let block = attempt + "#" + index
  let kind = str(field(chunk, "type")).unwrap_or("")
  let block_type = field(chunk, "blockType")
  if kind == "block-start" && (is_str(block_type, "text") || is_str(block_type, "reasoning")) {
    let step = if is_str(block_type, "text") { "text" } else { "thinking" }
    set_entry(self.open, block, step)
    out.push(start(block, step, None, None))
  } else if kind == "text-delta" || kind == "reasoning-delta" {
    let text = str(field(chunk, "text")).unwrap_or("")
    if find_entry(self.open, block) is None || text.length() == 0 {
      return
    }
    self.to("responding", out)
    out.push(delta(block, "text", text))
  } else if kind == "tool-call-delta" {
    let mut call = match find_entry(self.calls, block) {
      Some(i) => Some(self.calls[i].1)
      None => None
    }
    let id = non_empty(field(chunk, "id"))
    if call is None && id is Some(id) {
      call = Some(id)
      self.calls.push((block, id))
      set_entry(self.open, id, "tool")
      self.to("responding", out)
      out.push(start(id, "tool", Some(str(field(chunk, "name")).unwrap_or("")), Some("")))
    }
    let d = str(field(chunk, "argumentsDelta")).unwrap_or("")
    if call is Some(c) && d.length() > 0 {
      out.push(delta(c, "input", d))
    }
  } else if kind == "block-end" {
    // A call goes on until its result.
    end_entry(self.open, block, out)
    if find_entry(self.calls, block) is Some(i) {
      ignore(self.calls.remove(i))
    }
  }
}

///|
fn Live::event(self : Live, kind : String, data : J?, out : Array[J]) -> Unit {
  if kind == "tool/call" {
    guard non_empty(field(data, "callId")) is Some(id) else { return }
    self.to("working", out)
    // One not seen streaming (taken up after it streamed): started with its input whole.
    if find_entry(self.open, id) is None {
      set_entry(self.open, id, "tool")
      let raw = str(field(data, "arguments")).unwrap_or("")
      let input = match (try Some(@jsjson.parse(raw)) catch { _ => None }) {
        Some(v) => pretty(Some(v))
        None => raw
      }
      out.push(start(id, "tool", Some(str(field(data, "name")).unwrap_or("")), Some(@claude.chars(input, @live_wire.INPUT_MOST))))
    }
  } else if kind == "tool/result" {
    let result = Some(or_else(field(data, "message"), Obj([])))
    guard non_empty(field(result, "toolCallId")) is Some(id) && find_entry(self.open, id) is Some(_) else { return }
    let output = content_text(field(result, "content"), allow_str=false)
    if output.length() > 0 {
      out.push(delta(id, "output", output))
    }
    end_entry(self.open, id, out)
    if !has_open_tool(self.open) {
      self.to("requesting", out)
    }
  } else if kind == "turn/end" {
    out.append(self.ended())
  }
}

///|
/// The turn ended: whatever is still open ends with it.
pub fn Live::ended(self : Live) -> Array[J] {
  let out = end_open(self.open)
  self.calls.clear()
  self.phase = None
  out
}

///|
/// Where a session's turn stands (dsh.ts `Turn`): `prompted`, a turn of ours is asked for and has not started yet.
pub(all) struct Turn {
  mut busy : Bool
  mut prompted : Bool
  mut aborting : Bool
}

///|
/// The turn as dsh.ts `DshSnapshot.turn` says it.
pub fn Turn::json(self : Turn) -> J {
  obj([("busy", Bool(self.busy)), ("prompted", Bool(self.prompted)), ("aborting", Bool(self.aborting))])
}

///|
/// The turn Node said.
pub fn Turn::of_json(v : J) -> Turn {
  { busy: v.get("busy") is Some(Bool(true)), prompted: v.get("prompted") is Some(Bool(true)), aborting: v.get("aborting") is Some(Bool(true)) }
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
/// What a line of its output comes to: the runtime's events, and whether Node reads the line (an answer to a request
/// of its own).
pub(all) struct Said {
  events : Array[J]
  node : Bool
}

///|
/// dsh.ts `classifyFailure`: what failed a turn, from dsh's error (its code first).
pub fn classify_failure(code : String, text : String) -> String {
  @claude.failure_of(code + " " + text, auth_codes=["auth", "missing_credential", "invalid_credential"], limit=["insufficient balance"])
}

///|
/// dsh.ts `outcomeOf`: how a turn/end's reason ends the turn.
pub fn outcome_of(reason : J?) -> J {
  if is_str(field(reason, "kind"), "aborted") {
    return aborted()
  }
  if is_str(field(reason, "kind"), "error") {
    let error = Some(or_else(field(reason, "error"), Obj([])))
    let message = match field(error, "message") {
      Some(Str(s)) => s
      _ => @jsjson.stringify(error.unwrap())
    }
    let code = str_or_js(field(error, "code"))
    return failed(classify_failure(code, message), @claude.chars(message, 1000))
  }
  completed()
}

///|
/// What a line says (dsh.ts `heard`).
pub fn Session::line(self : Session, message : J) -> Said {
  let m = Some(message)
  let events = []
  guard field(m, "ev") is Some(ev) else {
    // (an answer to a request: Node's; a prompt refused starts no turn, so it ends here)
    if field(m, "error") is Some(Str(error)) &&
      str(field(m, "id")) is Some(id) &&
      has_prefix(id, "prompt:") &&
      self.turn.prompted {
      self.turn.prompted = false
      events.push(turn_ended(failed("other", @claude.chars(error, 1000))))
    }
    return { events, node: true }
  }
  let event = ev is Str(e) && e == "event"
  let kind = if event { str(field(m, "type")).unwrap_or("") } else { [] }
  if event && kind == "turn/start" {
    let ours = self.turn.prompted
    self.turn.prompted = false
    self.turn.busy = true
    // A turn of its own: a steer that came as the turn ended started one.
    if !ours {
      events.push(turn_started())
    }
  }
  for e in self.live.feed(message) {
    events.push(live(e))
  }
  if event && self.tools_lost(kind, Some(or_else(field(m, "data"), Obj([])))) is Some(why) {
    events.push(tools_lost_event(why))
  }
  if event && kind == "turn/end" {
    self.turn.busy = false
    self.turn.aborting = false
    events.push(turn_ended(outcome_of(field(field(m, "data"), "reason"))))
  }
  { events, node: false }
}

///|
/// dsh.ts `toolsLost`: a call to one of the station's tools failed as unreachable.
fn Session::tools_lost(self : Session, kind : String, data : J?) -> String? {
  if kind == "tool/call" && field(data, "callId") is Some(Str(id)) {
    if station_tool(str_or_js(field(data, "name"))) {
      self.calls.push(id)
    }
  }
  if kind != "tool/result" {
    return None
  }
  let result = Some(or_else(field(data, "message"), Obj([])))
  let id = str_or_js(field(result, "toolCallId"))
  guard self.calls.search(id) is Some(i) else { return None }
  ignore(self.calls.remove(i))
  guard field(result, "isError") is Some(Bool(true)) else { return None }
  let parts = match field(result, "content") {
    Some(Arr(items)) => items.map(c => str(field(Some(c), "text")).unwrap_or(""))
    _ => []
  }
  let text = joined(parts, "\n")
  if @claude.unreachable(text) {
    Some(@claude.chars(text, 300))
  } else {
    None
  }
}

///|
/// A prompt of Node's is asked for (dsh.ts `prompt`): the turn is, and with the model.
pub fn Session::prompted(self : Session) -> Array[J] {
  self.turn.prompted = true
  self.live.prompted().map(live)
}

///|
/// Its process went away during a turn: its steps end with it (dsh.ts `cutShort`).
pub fn Session::cut_short(self : Session) -> Array[J] {
  if self.turn.busy || self.turn.prompted {
    self.live.ended().map(live)
  } else {
    []
  }
}

///|
/// What a station that crashed had read of its output, read again (dsh.ts `crashed`): the session dsh named, the turn
/// and the live steps as the lines leave them.
pub(all) struct Replay {
  mut session : String?
  turn : Turn
  live : Live
}

///|
pub fn Replay::new() -> Replay {
  { session: None, turn: { busy: false, prompted: false, aborting: false }, live: Live::new() }
}

///|
pub fn Replay::line(self : Replay, message : J) -> Unit {
  let m = Some(message)
  if is_str(field(m, "id"), "open") && field(m, "session") is Some(Str(s)) {
    self.session = Some(s)
  }
  if is_str(field(m, "ev"), "event") && is_str(field(m, "type"), "turn/start") {
    self.turn.busy = true
  }
  if is_str(field(m, "ev"), "event") && is_str(field(m, "type"), "turn/end") {
    self.turn.busy = false
  }
  ignore(self.live.feed(message))
}
