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
  u, jstr, obj, field, str, non_empty, is_str, has_prefix, or_else, pretty, joined, start, delta, end_event, live, failed,
}

///|
type J = JValue

///|
/// A session's live steps (live.ts `LiveFromDsh`): the steps started and not ended with what each is, in the order a
/// Map keeps them; a stream block's call (attempt#index, its deltas after the first name only the index); where the
/// turn stands with the model.
pub(all) struct Live {
  open : Array[(Array[Int], String)]
  calls : Array[(Array[Int], Array[Int])]
  mut phase : String?
}

///|
pub fn Live::new() -> Live {
  { open: [], calls: [], phase: None }
}

///|
fn find(entries : Array[(Array[Int], String)], key : Array[Int]) -> Int? {
  for i, e in entries {
    if e.0 == key {
      return Some(i)
    }
  }
  None
}

///|
fn find_call(entries : Array[(Array[Int], Array[Int])], key : Array[Int]) -> Int? {
  for i, e in entries {
    if e.0 == key {
      return Some(i)
    }
  }
  None
}

///|
/// `Map.set`: a key there keeps its place.
fn Live::set_open(self : Live, id : Array[Int], step : String) -> Unit {
  match find(self.open, id) {
    Some(i) => self.open[i] = (id, step)
    None => self.open.push((id, step))
  }
}

///|
/// What `state` said (a station's before, or this one's after a crash): live.ts `DshLiveState`.
pub fn Live::of_state(state : J) -> Live {
  let live = Live::new()
  if state.get("open") is Some(Arr(entries)) {
    for e in entries {
      if e is Arr([Str(id), Str(step), ..]) {
        live.set_open(id, @jsjson.raw_text(step))
      }
    }
  }
  if state.get("calls") is Some(Arr(entries)) {
    for e in entries {
      if e is Arr([Str(block), Str(id), ..]) {
        match find_call(live.calls, block) {
          Some(i) => live.calls[i] = (block, id)
          None => live.calls.push((block, id))
        }
      }
    }
  }
  if state.get("phase") is Some(Str(p)) {
    live.phase = Some(@jsjson.raw_text(p))
  }
  live
}

///|
pub fn Live::state(self : Live) -> J {
  obj([
    ("open", Arr(self.open.map(e => J::Arr([Str(e.0), jstr(e.1)])))),
    ("calls", Arr(self.calls.map(e => J::Arr([Str(e.0), Str(e.1)])))),
    ("phase", match self.phase { Some(p) => jstr(p); None => Null }),
  ])
}

///|
fn Live::to(self : Live, next : String, out : Array[J]) -> Unit {
  if self.phase != Some(next) {
    self.phase = Some(next)
    out.push(obj([("kind", jstr("phase")), ("phase", jstr(next))]))
  }
}

///|
fn Live::end(self : Live, id : Array[Int], out : Array[J]) -> Unit {
  if find(self.open, id) is Some(i) {
    ignore(self.open.remove(i))
    out.push(end_event(id))
  }
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
    self.event(str(field(m, "type")).unwrap_or([]), Some(or_else(field(m, "data"), Obj([]))), out)
  }
  out
}

///|
/// `!v`: what JavaScript takes as false.
fn falsy(v : J?) -> Bool {
  match v {
    None | Some(Null) | Some(Bool(false)) => true
    Some(Num(d)) => d == 0.0 || d.is_nan()
    Some(Str(s)) => s.length() == 0
    _ => false
  }
}

///|
fn Live::stream(self : Live, frame : J?, out : Array[J]) -> Unit {
  let attempt = str(field(frame, "attemptId")).unwrap_or([])
  if is_str(field(frame, "type"), "start") {
    return self.to("requesting", out)
  }
  if is_str(field(frame, "type"), "end") {
    // An attempt that did not commit (cancelled, failed, retried): what it said so far ends with it.
    if !is_str(field(field(frame, "outcome"), "kind"), "committed") {
      let prefix = attempt + [0x23]
      for e in self.open.copy() {
        if e.1 != "tool" && has_prefix(e.0, prefix) {
          self.end(e.0, out)
        }
      }
    }
    return
  }
  let chunk = field(frame, "chunk")
  if !is_str(field(frame, "type"), "chunk") || falsy(chunk) {
    return
  }
  let index = match field(chunk, "index") {
    Some(Num(_) as n) => u(@jsjson.stringify(n))
    _ => []
  }
  let block = attempt + [0x23] + index
  let kind = str(field(chunk, "type")).unwrap_or([])
  let block_type = field(chunk, "blockType")
  if kind == u("block-start") && (is_str(block_type, "text") || is_str(block_type, "reasoning")) {
    let step = if is_str(block_type, "text") { "text" } else { "thinking" }
    self.set_open(block, step)
    out.push(start(block, step, None, None))
  } else if kind == u("text-delta") || kind == u("reasoning-delta") {
    let text = str(field(chunk, "text")).unwrap_or([])
    if find(self.open, block) is None || text.length() == 0 {
      return
    }
    self.to("responding", out)
    out.push(delta(block, "text", text))
  } else if kind == u("tool-call-delta") {
    let mut call = match find_call(self.calls, block) {
      Some(i) => Some(self.calls[i].1)
      None => None
    }
    let id = non_empty(field(chunk, "id"))
    if call is None && id is Some(id) {
      call = Some(id)
      self.calls.push((block, id))
      self.set_open(id, "tool")
      self.to("responding", out)
      out.push(start(id, "tool", Some(str(field(chunk, "name")).unwrap_or([])), Some([])))
    }
    let d = str(field(chunk, "argumentsDelta")).unwrap_or([])
    if call is Some(c) && d.length() > 0 {
      out.push(delta(c, "input", d))
    }
  } else if kind == u("block-end") {
    // A call goes on until its result.
    if find(self.open, block) is Some(_) {
      self.end(block, out)
    }
    if find_call(self.calls, block) is Some(i) {
      ignore(self.calls.remove(i))
    }
  }
}

///|
fn Live::event(self : Live, kind : Array[Int], data : J?, out : Array[J]) -> Unit {
  if kind == u("tool/call") {
    guard non_empty(field(data, "callId")) is Some(id) else { return }
    self.to("working", out)
    // One not seen streaming (taken up after it streamed): started with its input whole.
    if find(self.open, id) is None {
      self.set_open(id, "tool")
      let raw = str(field(data, "arguments")).unwrap_or([])
      let input = match (try Some(@jsjson.parse(@jsjson.raw_text(raw))) catch { _ => None }) {
        Some(v) => pretty(Some(v))
        None => raw
      }
      out.push(start(id, "tool", Some(str(field(data, "name")).unwrap_or([])), Some(@claude.chars(input, @live_wire.INPUT_MOST))))
    }
  } else if kind == u("tool/result") {
    let result = Some(or_else(field(data, "message"), Obj([])))
    guard non_empty(field(result, "toolCallId")) is Some(id) && find(self.open, id) is Some(_) else { return }
    let parts = match field(result, "content") {
      Some(Arr(items)) => items.map(c => str(field(Some(c), "text")).unwrap_or([])).filter(t => t.length() > 0)
      _ => []
    }
    let output = joined(parts, [0x0a])
    if output.length() > 0 {
      out.push(delta(id, "output", output))
    }
    self.end(id, out)
    if !self.open.iter().any(e => e.1 == "tool") {
      self.to("requesting", out)
    }
  } else if kind == u("turn/end") {
    out.append(self.ended())
  }
}

///|
/// The turn ended: whatever is still open ends with it.
pub fn Live::ended(self : Live) -> Array[J] {
  let out = self.open.map(e => end_event(e.0))
  self.open.clear()
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
  calls : Array[Array[Int]]
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
pub fn classify_failure(code : Array[Int], text : Array[Int]) -> String {
  @claude.failure_of(code + [0x20] + text, auth_codes=["auth", "missing_credential", "invalid_credential"], limit=["insufficient balance"])
}

///|
/// dsh.ts `outcomeOf`: how a turn/end's reason ends the turn.
pub fn outcome_of(reason : J?) -> J {
  if is_str(field(reason, "kind"), "aborted") {
    return obj([("kind", jstr("aborted"))])
  }
  if is_str(field(reason, "kind"), "error") {
    let error = Some(or_else(field(reason, "error"), Obj([])))
    let message = match field(error, "message") {
      Some(Str(s)) => s
      _ => u(@jsjson.stringify(error.unwrap()))
    }
    let code = match field(error, "code") {
      None | Some(Null) => []
      Some(v) => @jsjson.js_string(v)
    }
    return failed(classify_failure(code, message), @claude.chars(message, 1000))
  }
  obj([("kind", jstr("completed"))])
}

///|
/// runtime.ts `stationTool`: a call to one of the station's tools, by the name the station gives it.
fn station_tool(name : Array[Int]) -> Bool {
  has_prefix(name, u("mcp__stillfail__")) || has_prefix(name, u("stillfail__"))
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
      has_prefix(id, u("prompt:")) &&
      self.turn.prompted {
      self.turn.prompted = false
      events.push(obj([("type", jstr("turnEnded")), ("outcome", failed("other", @claude.chars(error, 1000)))]))
    }
    return { events, node: true }
  }
  let event = ev is Str(e) && e == u("event")
  let kind = if event { str(field(m, "type")).unwrap_or([]) } else { [] }
  if event && kind == u("turn/start") {
    let ours = self.turn.prompted
    self.turn.prompted = false
    self.turn.busy = true
    // A turn of its own: a steer that came as the turn ended started one.
    if !ours {
      events.push(obj([("type", jstr("turnStarted"))]))
    }
  }
  for e in self.live.feed(message) {
    events.push(live(e))
  }
  if event && self.tools_lost(kind, Some(or_else(field(m, "data"), Obj([])))) is Some(why) {
    events.push(obj([("type", jstr("toolsLost")), ("why", Str(why))]))
  }
  if event && kind == u("turn/end") {
    self.turn.busy = false
    self.turn.aborting = false
    events.push(obj([("type", jstr("turnEnded")), ("outcome", outcome_of(field(field(m, "data"), "reason")))]))
  }
  { events, node: false }
}

///|
/// dsh.ts `toolsLost`: a call to one of the station's tools failed as unreachable.
fn Session::tools_lost(self : Session, kind : Array[Int], data : J?) -> Array[Int]? {
  if kind == u("tool/call") && field(data, "callId") is Some(Str(id)) {
    let name = match field(data, "name") {
      None | Some(Null) => []
      Some(v) => @jsjson.js_string(v)
    }
    if station_tool(name) {
      self.calls.push(id)
    }
  }
  if kind != u("tool/result") {
    return None
  }
  let result = Some(or_else(field(data, "message"), Obj([])))
  let id = match field(result, "toolCallId") {
    None | Some(Null) => []
    Some(v) => @jsjson.js_string(v)
  }
  guard self.calls.search(id) is Some(i) else { return None }
  ignore(self.calls.remove(i))
  guard field(result, "isError") is Some(Bool(true)) else { return None }
  let parts = match field(result, "content") {
    Some(Arr(items)) => items.map(c => str(field(Some(c), "text")).unwrap_or([]))
    _ => []
  }
  let text = joined(parts, [0x0a])
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
  mut session : Array[Int]?
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
