// What Pi says in its RPC (station/src/agents/pi.ts: a line of JSON a message, `pi --mode rpc`) does to its session:
// the live steps a device is shown, the turn's start and end with its outcome, its context compacted, the station's
// tools out of reach. A line that answers a command of Node's (`type: "response"`) or opens an extension's dialog
// (`extension_ui_request`) is Node's to read (`Said.node`); a prompt it refuses ends the turn here. A turn is Pi's whole
// run: from `agent_start` (it goes on by itself past its turns: retries, a compaction on overflow, steered messages) to
// `agent_settled`. Lines are read as JSON.parse reads them and what is said of them written as JSON.stringify writes it
// (station/jsjson).

///|
using @jsjson {type JValue}

///|
using @live_wire {
  u, jstr, obj, field, str, non_empty, is_str, has_prefix, pretty, joined, start, delta, end_event, live, failed,
}

///|
type J = JValue

///|
/// The words of a message's or a result's content: its text parts, one after another.
fn content_text(content : J?) -> Array[Int] {
  match content {
    Some(Str(s)) => s
    Some(Arr(items)) => joined(items.map(c => str(field(Some(c), "text")).unwrap_or([])).filter(t => t.length() > 0), [0x0a])
    _ => []
  }
}

///|
/// A session's live steps: the steps started and not ended with what each is, in the order they started; a content
/// block's call (its tool call's id, which the call's step is named by); how many of the assistant's messages began
/// (a text or thinking block's step is named by its message and its index there, `m<n>#<i>`); where the turn stands
/// with the model.
pub(all) struct Live {
  open : Array[(Array[Int], String)]
  calls : Array[(Array[Int], Array[Int])]
  mut message : Int
  mut phase : String?
}

///|
pub fn Live::new() -> Live {
  { open: [], calls: [], message: 0, phase: None }
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
/// What `state` said (a station's before, or this one's after a crash): pi.ts `PiLiveState`.
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
  if state.get("message") is Some(Num(n)) && n >= 0.0 {
    live.message = n.to_int()
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
    ("message", Num(self.message.to_double())),
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
/// The current message's prefix of its blocks' names: `m<n>#`.
fn Live::prefix(self : Live) -> Array[Int] {
  u("m" + self.message.to_string() + "#")
}

///|
/// A prompt was given: the turn is with the model.
pub fn Live::prompted(self : Live) -> Array[J] {
  let out = []
  self.to("requesting", out)
  out
}

///|
/// The live steps a line says.
pub fn Live::feed(self : Live, message : J) -> Array[J] {
  let out = []
  let m = Some(message)
  let kind = str(field(m, "type")).unwrap_or([])
  if kind == u("message_start") {
    if is_str(field(field(m, "message"), "role"), "assistant") {
      self.message += 1
    }
  } else if kind == u("message_update") {
    self.update(field(m, "assistantMessageEvent"), out)
  } else if kind == u("message_end") {
    // A message that ended short of its blocks' ends (aborted, failed): what it said so far ends with it. Its calls go
    // on until their results.
    if is_str(field(field(m, "message"), "role"), "assistant") {
      let prefix = self.prefix()
      for e in self.open.copy() {
        if e.1 != "tool" && has_prefix(e.0, prefix) {
          self.end(e.0, out)
        }
      }
      let kept = self.calls.filter(c => !has_prefix(c.0, prefix))
      self.calls.clear()
      self.calls.append(kept)
    }
  } else if kind == u("tool_execution_start") {
    guard non_empty(field(m, "toolCallId")) is Some(id) else { return out }
    self.to("working", out)
    // One not seen streaming (taken up after it streamed): started with its input whole.
    if find(self.open, id) is None {
      self.set_open(id, "tool")
      out.push(start(id, "tool", Some(str(field(m, "toolName")).unwrap_or([])), Some(@claude.chars(pretty(field(m, "args")), @live_wire.INPUT_MOST))))
    }
  } else if kind == u("tool_execution_end") {
    guard non_empty(field(m, "toolCallId")) is Some(id) && find(self.open, id) is Some(_) else { return out }
    let output = content_text(field(field(m, "result"), "content"))
    if output.length() > 0 {
      out.push(delta(id, "output", output))
    }
    self.end(id, out)
    if !self.open.iter().any(e => e.1 == "tool") {
      self.to("requesting", out)
    }
  } else if kind == u("auto_retry_start") {
    self.to("requesting", out)
  } else if kind == u("compaction_start") {
    self.to("working", out)
  } else if kind == u("compaction_end") {
    self.to("requesting", out)
  } else if kind == u("agent_settled") {
    out.append(self.ended())
  }
  out
}

///|
/// A content block of the assistant's message streaming (`message_update`'s `assistantMessageEvent`).
fn Live::update(self : Live, event : J?, out : Array[J]) -> Unit {
  let kind = str(field(event, "type")).unwrap_or([])
  let index = match field(event, "contentIndex") {
    Some(Num(_) as n) => u(@jsjson.stringify(n))
    _ => []
  }
  let block = self.prefix() + index
  if kind == u("text_start") || kind == u("thinking_start") {
    let step = if kind == u("text_start") { "text" } else { "thinking" }
    self.set_open(block, step)
    out.push(start(block, step, None, None))
  } else if kind == u("text_delta") || kind == u("thinking_delta") {
    let text = str(field(event, "delta")).unwrap_or([])
    if find(self.open, block) is None || text.length() == 0 {
      return
    }
    self.to("responding", out)
    out.push(delta(block, "text", text))
  } else if kind == u("text_end") || kind == u("thinking_end") {
    self.end(block, out)
  } else if kind == u("toolcall_start") {
    guard non_empty(field(event, "id")) is Some(id) else { return }
    match find_call(self.calls, block) {
      Some(i) => self.calls[i] = (block, id)
      None => self.calls.push((block, id))
    }
    self.set_open(id, "tool")
    self.to("responding", out)
    out.push(start(id, "tool", Some(str(field(event, "toolName")).unwrap_or([])), Some([])))
  } else if kind == u("toolcall_delta") {
    let d = str(field(event, "delta")).unwrap_or([])
    if find_call(self.calls, block) is Some(i) && d.length() > 0 {
      out.push(delta(self.calls[i].1, "input", d))
    }
  } else if kind == u("toolcall_end") {
    // The call goes on until its result.
    if find_call(self.calls, block) is Some(i) {
      ignore(self.calls.remove(i))
    }
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
/// Where a session's turn stands (pi.ts `Turn`): `prompted`, a turn of ours is asked for and has not started yet;
/// `error`, what failed the last answer of the model, while no later one went through (a retry that did clears it).
pub(all) struct Turn {
  mut busy : Bool
  mut prompted : Bool
  mut aborting : Bool
  mut error : Array[Int]?
}

///|
pub fn Turn::new() -> Turn {
  { busy: false, prompted: false, aborting: false, error: None }
}

///|
/// The turn as pi.ts `PiSnapshot.turn` says it.
pub fn Turn::json(self : Turn) -> J {
  let fields : Array[(String, J)] = [("busy", Bool(self.busy)), ("prompted", Bool(self.prompted)), ("aborting", Bool(self.aborting))]
  if self.error is Some(e) {
    fields.push(("error", Str(e)))
  }
  obj(fields)
}

///|
/// The turn Node said.
pub fn Turn::of_json(v : J) -> Turn {
  {
    busy: v.get("busy") is Some(Bool(true)),
    prompted: v.get("prompted") is Some(Bool(true)),
    aborting: v.get("aborting") is Some(Bool(true)),
    error: match v.get("error") {
      Some(Str(e)) => Some(e)
      _ => None
    },
  }
}

///|
/// An answer of the model's as it ended (`message_end`): one that failed says why, one that went through clears it.
fn Turn::answered(self : Turn, message : J?) -> Unit {
  guard is_str(field(message, "role"), "assistant") else { return }
  match str(field(message, "stopReason")) {
    Some(r) if r == u("error") => {
      let said = content_or(non_empty(field(message, "errorMessage")), u("the model's answer failed"))
      self.error = Some(said)
    }
    Some(r) if r == u("aborted") => ()
    Some(_) => self.error = None
    None => ()
  }
}

///|
fn content_or(v : Array[Int]?, fallback : Array[Int]) -> Array[Int] {
  match v {
    Some(s) => s
    None => fallback
  }
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
/// What a line of its output comes to: the runtime's events, and whether Node reads the line (an answer to a command
/// of its own, an extension's dialog).
pub(all) struct Said {
  events : Array[J]
  node : Bool
}

///|
/// What failed a turn, from what Pi said of it (its provider's error as pi-ai words it: "401: {…}", "context overflow").
pub fn classify_failure(text : Array[Int]) -> String {
  @claude.failure_of(text)
}

///|
/// How a run that settled ends the turn: aborted where it was stopped, failed where the model's last answer failed
/// (and no retry went through), else completed.
pub fn outcome_of(aborted : Bool, error : Array[Int]?) -> J {
  if aborted {
    return obj([("kind", jstr("aborted"))])
  }
  match error {
    Some(e) => failed(classify_failure(e), @claude.chars(e, 1000))
    None => obj([("kind", jstr("completed"))])
  }
}

///|
/// runtime.ts `stationTool`: a call to one of the station's tools, by the name the station gives it.
fn station_tool(name : Array[Int]) -> Bool {
  has_prefix(name, u("mcp__stillfail__")) || has_prefix(name, u("stillfail__"))
}

///|
/// What a line says (pi.ts `heard`).
pub fn Session::line(self : Session, message : J) -> Said {
  let m = Some(message)
  let events = []
  let kind = str(field(m, "type")).unwrap_or([])
  if kind == u("response") {
    // (an answer to a command: Node's; a prompt refused starts no turn, so it ends here)
    if is_str(field(m, "command"), "prompt") && field(m, "success") is Some(Bool(false)) && self.turn.prompted {
      self.turn.prompted = false
      let error = match field(m, "error") {
        Some(Str(e)) => e
        _ => u("Pi refused the prompt")
      }
      events.push(obj([("type", jstr("turnEnded")), ("outcome", failed("other", @claude.chars(error, 1000)))]))
    }
    return { events, node: true }
  }
  if kind == u("extension_ui_request") {
    return { events, node: true }
  }
  if kind == u("agent_start") && !self.turn.busy {
    let ours = self.turn.prompted
    self.turn.prompted = false
    self.turn.busy = true
    self.turn.error = None
    // A run of its own: a steer that came as the run settled started one.
    if !ours {
      events.push(obj([("type", jstr("turnStarted"))]))
    }
  }
  if kind == u("message_end") {
    self.turn.answered(field(m, "message"))
  }
  let settled = kind == u("agent_settled") && (self.turn.busy || self.turn.prompted)
  for e in self.live.feed(message) {
    events.push(live(e))
  }
  if self.tools_lost(kind, m) is Some(why) {
    events.push(obj([("type", jstr("toolsLost")), ("why", Str(why))]))
  }
  if kind == u("compaction_end") && field(m, "result") is Some(Obj(_)) && !(field(m, "aborted") is Some(Bool(true))) {
    events.push(obj([("type", jstr("compacted"))]))
  }
  if settled {
    let aborted = field(m, "aborted") is Some(Bool(true)) || self.turn.aborting
    let error = self.turn.error
    self.turn.busy = false
    self.turn.prompted = false
    self.turn.aborting = false
    self.turn.error = None
    events.push(obj([("type", jstr("turnEnded")), ("outcome", outcome_of(aborted, error))]))
  }
  { events, node: false }
}

///|
/// A call to one of the station's tools failed as unreachable.
fn Session::tools_lost(self : Session, kind : Array[Int], m : J?) -> Array[Int]? {
  if kind == u("tool_execution_start") && non_empty(field(m, "toolCallId")) is Some(id) {
    if station_tool(str(field(m, "toolName")).unwrap_or([])) {
      self.calls.push(id)
    }
  }
  if kind != u("tool_execution_end") {
    return None
  }
  let id = str(field(m, "toolCallId")).unwrap_or([])
  guard self.calls.search(id) is Some(i) else { return None }
  ignore(self.calls.remove(i))
  guard field(m, "isError") is Some(Bool(true)) else { return None }
  let text = content_text(field(field(m, "result"), "content"))
  if @claude.unreachable(text) {
    Some(@claude.chars(text, 300))
  } else {
    None
  }
}

///|
/// A prompt of Node's is asked for (pi.ts `prompt`): the turn is, and with the model.
pub fn Session::prompted(self : Session) -> Array[J] {
  self.turn.prompted = true
  self.live.prompted().map(live)
}

///|
/// Its process went away during a turn: its steps end with it (pi.ts `cutShort`).
pub fn Session::cut_short(self : Session) -> Array[J] {
  if self.turn.busy || self.turn.prompted {
    self.live.ended().map(live)
  } else {
    []
  }
}

///|
/// What a station that crashed had read of its output, read again (pi.ts `crashed`): the turn and the live steps as
/// the lines leave them. (Its session is the station's to name: pi.ts names its file.)
pub(all) struct Replay {
  session : Session
}

///|
pub fn Replay::new() -> Replay {
  { session: Session::new(Turn::new(), Live::new()) }
}

///|
pub fn Replay::line(self : Replay, message : J) -> Unit {
  ignore(self.session.line(message))
}
