// What an Agent Client Protocol runtime says (JSON-RPC over its stdio: Antigravity CLI, Grok Build, Devin, Hermes
// Agent, each a `flavor`) does to its session, as the TypeScript station had it (live.ts `LiveFromAcp`, `acpCall`,
// `acpNamed`; acp.ts `planOfAcp`, `turnStep`, `acpOutcome`, `AcpSession`'s reading of its updates and of a prompt's
// answer, `KeptTranscript`'s lines; agy.ts `agyUpdate`, `noticeFailure`; hermes.ts `hermesUpdate`; grok.ts its
// subagents' steps, `underParent`; each one's `classifyFailure`; the reference is station/test/reference/live.ts): the
// live steps a device is shown, the turn's start and end with its outcome, the station's tools out of reach, and what
// the transcript the station keeps of it says (`kept`: each thing said whole, a call once done, a turn's end). What the
// model says comes a chunk at a time and is put together here: Node is told what it was once whole. A request of the
// runtime's and an answer to one of Node's are Node's to read (`Said.node`); a prompt's answer ends the turn here, and
// Node is given it (`answered`) for what it keeps of the turn (its usage), as it is each update of usage (`usage`).

///|
using @jsjson {type JValue}

///|
using @live_wire {
  u, jstr, obj, field, str, non_empty, is_str, has_prefix, or_else, pretty, joined, start, delta, end_event, live, failed,
}

///|
type J = JValue

///|
/// `v === s`.
fn is_text(v : J?, s : Array[Int]) -> Bool {
  v is Some(Str(t)) && t == s
}

///|
fn trimmed(s : Array[Int]) -> Array[Int] {
  u(@jscase.trim(@jsjson.raw_text(s)))
}

///|
/// `{ ...v, name: value }`: a key there keeps its place.
fn with_field(v : J, name : String, value : J) -> J {
  guard v is Obj(entries) else { return v }
  let key = u(name)
  let out = entries.copy()
  for i, e in out {
    if e.0 == key {
      out[i] = (key, value)
      return Obj(out)
    }
  }
  out.push((key, value))
  Obj(out)
}

///|
/// acp.ts `acpText`: what a content block says (its text; anything else nothing).
fn acp_text(content : J?) -> Array[Int] {
  if field(content, "text") is Some(Str(t)) {
    return t
  }
  if is_str(field(content, "type"), "content") {
    return acp_text(field(content, "content"))
  }
  []
}

///|
/// live.ts `acpCall`: Grok Build's `use_tool` named as the tool itself (mcp__<server>__<tool>), with its own input.
pub fn acp_call(name : Array[Int], input : J) -> (Array[Int], J) {
  if name == u("use_tool") && field(Some(input), "tool_name") is Some(Str(t)) {
    return (u("mcp__") + t, or_else(field(Some(input), "tool_input"), Obj([])))
  }
  (name, input)
}

///|
/// live.ts `acpNamed`: a call an update starts, as the station names and gives it (Grok Build's name in its _meta,
/// Devin's in its own, the others' in its title).
pub fn acp_named(update : J?) -> (Array[Int], J) {
  let meta = field(update, "_meta")
  let name = match str(field(field(meta, "x.ai/tool"), "name")) {
    Some(n) => n
    None =>
      match str(field(meta, "cognition.ai/inferenceToolName")) {
        Some(n) => n
        None => str(field(update, "title")).unwrap_or([])
      }
  }
  acp_call(name, or_else(field(update, "rawInput"), Null))
}

///|
/// acp.ts `planOfAcp`: a `plan` update's entries as checklist items (none: it says none it can be read by).
pub fn plan_of(update : J?) -> J? {
  guard field(update, "entries") is Some(Arr(entries)) else { return None }
  let items = []
  for e in entries {
    guard field(Some(e), "content") is Some(Str(text)) else { continue }
    let status = match field(Some(e), "status") {
      Some(Str(s)) => s
      _ => u("pending")
    }
    items.push(obj([("text", Str(text)), ("status", Str(status))]))
  }
  Some(Arr(items))
}

///|
/// acp.ts `turnStep`: an update that is a step of a turn (what the model says or does).
pub fn turn_step(update : J?) -> Bool {
  ["agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update"].iter().any(k => is_str(field(update, "sessionUpdate"), k))
}

///|
/// A session's live steps (live.ts `LiveFromAcp`): the steps started and not ended, in order; the step what is being
/// said goes into, and how many were made; where the turn stands.
pub(all) struct Live {
  open : Array[Array[Int]]
  mut said : Array[Int]?
  mut n : Int
  mut phase : String?
}

///|
pub fn Live::new() -> Live {
  { open: [], said: None, n: 0, phase: None }
}

///|
/// What `state` said: live.ts `AcpLiveState`.
pub fn Live::of_state(state : J?) -> Live {
  let live = Live::new()
  if field(state, "open") is Some(Arr(ids)) {
    for id in ids {
      if id is Str(s) && !live.open.contains(s) {
        live.open.push(s)
      }
    }
  }
  if field(state, "said") is Some(Str(s)) {
    live.said = Some(s)
  }
  if field(state, "n") is Some(Num(n)) {
    live.n = n.to_int()
  }
  if field(state, "phase") is Some(Str(p)) {
    live.phase = Some(@jsjson.raw_text(p))
  }
  live
}

///|
pub fn Live::state(self : Live) -> J {
  obj([
    ("open", Arr(self.open.map(id => J::Str(id)))),
    ("said", match self.said { Some(s) => Str(s); None => Null }),
    ("n", Num(self.n.to_double())),
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
fn Live::close(self : Live, id : Array[Int]) -> Unit {
  if self.open.search(id) is Some(i) {
    ignore(self.open.remove(i))
  }
}

///|
/// Ends the step of what was being said (a call keeps going until its result).
fn Live::end_said(self : Live, out : Array[J]) -> Unit {
  guard self.said is Some(s) else { return }
  self.close(s)
  out.push(end_event(s))
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
/// The call that started last of those still running (what a subagent spawned now was spawned by).
pub fn Live::open_call(self : Live) -> Array[Int]? {
  let mut last = None
  for id in self.open {
    if has_prefix(id, u("call:")) {
      last = Some(id)
    }
  }
  last
}

///|
/// The live steps an update says (live.ts `feed`).
pub fn Live::feed(self : Live, update : J?) -> Array[J] {
  let out = []
  let kind = str(field(update, "sessionUpdate")).unwrap_or([])
  if kind == u("agent_message_chunk") || kind == u("agent_thought_chunk") {
    let step = if kind == u("agent_message_chunk") { "text" } else { "thinking" }
    let text = acp_text(field(update, "content"))
    if text.length() == 0 {
      return out
    }
    self.to("responding", out)
    let tail = u("/" + step)
    let same = match self.said {
      Some(s) => s.length() >= tail.length() && s[s.length() - tail.length():].to_owned() == tail
      None => false
    }
    if !same {
      self.end_said(out)
      self.n += 1
      let id = u("said:") + u(self.n.to_string()) + tail
      self.said = Some(id)
      self.open.push(id)
      out.push(start(id, step, None, None))
    }
    out.push(delta(self.said.unwrap(), "text", text))
  } else if kind == u("tool_call") {
    guard non_empty(field(update, "toolCallId")) is Some(call) else { return out }
    let id = u("call:") + call
    self.end_said(out)
    self.to("working", out)
    if !self.open.contains(id) {
      self.open.push(id)
      let (name, input) = acp_named(update)
      out.push(start(id, "tool", Some(name), Some(@claude.chars(pretty(Some(input)), @live_wire.INPUT_MOST))))
    }
    self.result(id, update, out)
  } else if kind == u("tool_call_update") {
    if non_empty(field(update, "toolCallId")) is Some(call) && self.open.contains(u("call:") + call) {
      self.result(u("call:") + call, update, out)
    }
  }
  out
}

///|
/// A call's output once it is done, and its end.
fn Live::result(self : Live, id : Array[Int], update : J?, out : Array[J]) -> Unit {
  if !is_str(field(update, "status"), "completed") && !is_str(field(update, "status"), "failed") {
    return
  }
  let parts = match field(update, "content") {
    Some(Arr(items)) => items.map(c => acp_text(Some(c))).filter(t => t.length() > 0)
    _ => []
  }
  let output = joined(parts, [0x0a])
  if output.length() > 0 {
    out.push(delta(id, "output", @claude.chars(output, @live_wire.INPUT_MOST)))
  }
  self.close(id)
  out.push(end_event(id))
  if !self.open.iter().any(o => has_prefix(o, u("call:"))) {
    self.to("requesting", out)
  }
}

///|
/// The turn ended: whatever is still open ends with it.
pub fn Live::ended(self : Live) -> Array[J] {
  let out = self.open.map(end_event)
  self.open.clear()
  self.said = None
  self.phase = None
  out
}

///|
/// agy.ts `agyUpdate`: Antigravity CLI names an MCP tool `Run mcp_<server>_<tool>`, named here mcp__<server>__<tool>.
pub fn agy_update(update : J?) -> J? {
  guard is_str(field(update, "sessionUpdate"), "tool_call") && field(update, "title") is Some(Str(title)) else { return update }
  let prefix = u("Run mcp_stillfail_")
  if has_prefix(title, prefix) {
    return Some(with_field(update.unwrap(), "title", Str(u("mcp__stillfail__") + title[prefix.length():].to_owned())))
  }
  update
}

///|
/// hermes.ts `hermesUpdate`: Hermes' title is `<tool>: <its input>`, named by the tool alone, an editor's scoped name of
/// the station's tools (mcp__editor_stillfail_<8 hex>__) as theirs.
pub fn hermes_update(update : J?) -> J? {
  guard is_str(field(update, "sessionUpdate"), "tool_call") && field(update, "title") is Some(Str(title)) else { return update }
  let mut name = title
  for i = 0; i + 1 < title.length(); i = i + 1 {
    if title[i] == 0x3a && title[i + 1] == 0x20 {
      name = title[0:i].to_owned()
      break
    }
  }
  let scoped = u("mcp__editor_stillfail_")
  if has_prefix(name, scoped) && name.length() >= scoped.length() + 10 {
    let hex = name[scoped.length():scoped.length() + 8].to_owned()
    let lower_hex = hex.iter().all(c => (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66))
    if lower_hex && name[scoped.length() + 8] == 0x5f && name[scoped.length() + 9] == 0x5f {
      name = u("mcp__stillfail__") + name[scoped.length() + 10:].to_owned()
    }
  }
  Some(with_field(update.unwrap(), "title", Str(name)))
}

///|
/// Each runtime's `classifyFailure`: what failed a turn, from what it said of it.
pub fn classify(flavor : String, text : Array[Int]) -> String {
  match flavor {
    "grok" => @claude.failure_of(text, auth=["access token", "subscription"])
    "agy" =>
      @claude.failure_of(
        text,
        auth=[
          "authentication required", "not logged into antigravity", "authentication expired", "couldn't sign in", "invalid_grant",
          "unauthenticated", "token expired",
        ],
        limit=["resource_exhausted", "quota"],
      )
    _ => @claude.failure_of(text)
  }
}

///|
fn last_line(text : Array[Int]) -> Array[Int] {
  let mut after = 0
  for i = 0; i < text.length(); i = i + 1 {
    if text[i] == 0x0a {
      after = i + 1
    }
  }
  trimmed(text[after:].to_owned())
}

///|
/// agy.ts `noticeFailure`: a failure Antigravity CLI tells only in words, a turn's last words one line of its own
/// beginning with ⚠ that is not the model's, or its executor's trailing notice line after partial text.
pub fn notice_failure(said : Array[Int]) -> String? {
  let text = trimmed(said)
  if text.length() == 0 {
    return None
  }
  let last = last_line(text)
  let lower = @jscase.lower(@jsjson.raw_text(last))
  if lower == "\u{26a0} agent execution terminated due to error." {
    // (agy.ts `AGY_TERMINATED`: its 1.5.8 words for a failure it does not name, even after partial streamed text)
    return Some("other")
  }
  if lower.has_prefix("\u{26a0} agent executor error:") {
    let reason = classify("agy", last)
    return Some(if reason == "model" { "other" } else { reason })
  }
  if lower.has_prefix("\u{26a0} unauthenticated (code 401):") {
    return Some("auth")
  }
  if text[0] != 0x26a0 || text.contains(0x0a) {
    return None
  }
  let reason = classify("agy", text)
  if reason == "model" {
    None
  } else {
    Some(reason)
  }
}

///|
/// acp.ts `errorText`: what an error answer says, its message and its data's.
fn error_text(error : J) -> Array[Int] {
  let e = Some(error)
  let text = match field(e, "message") {
    Some(Str(m)) => {
      let lead = u("Internal error: ")
      if has_prefix(m, lead) {
        m[lead.length():].to_owned()
      } else {
        m
      }
    }
    _ => u(@jsjson.stringify(error))
  }
  let data = match field(e, "data") {
    Some(Str(d)) => u(": ") + d
    d =>
      match (str(field(d, "message")), str(field(d, "details"))) {
        (Some(m), _) => u(": ") + m
        (None, Some(m)) => u(": ") + m
        _ => []
      }
  }
  text + data
}

///|
/// acp.ts `acpOutcome`: how a prompt's answer ends the turn, its failure told apart by the runtime's words.
pub fn acp_outcome(flavor : String, answer : J?) -> J {
  if field(answer, "error") is Some(error) {
    let said = error_text(error)
    return failed(classify(flavor, said), @claude.chars(said, 1000))
  }
  let stop = field(field(answer, "result"), "stopReason")
  if is_str(stop, "cancelled") {
    return obj([("kind", jstr("aborted"))])
  }
  if is_str(stop, "refusal") {
    return failed("model", u("the model refused"))
  }
  obj([("kind", jstr("completed"))])
}

///|
/// A call under way, as it started (acp.ts `Call`).
pub(all) struct Call {
  name : Array[Int]
  input : J
  started_at : Double?
}

///|
fn Call::json(self : Call) -> J {
  let fields : Array[(String, J)] = [("name", Str(self.name)), ("input", self.input)]
  if self.started_at is Some(at) {
    fields.push(("startedAt", Num(at)))
  }
  obj(fields)
}

///|
/// A subagent's session in the process (Grok Build's): its steps, under the call that spawned it.
pub(all) struct Child {
  live : Live
  parent : Array[Int]?
}

///|
/// Where a session's turn stands: the prompt whose answer ends it, and the prompts put in it not answered yet.
pub(all) struct Turn {
  mut busy : Bool
  mut aborting : Bool
  mut owner : Array[Int]?
  steering : Array[Array[Int]]
}

///|
pub fn Turn::json(self : Turn) -> J {
  obj([
    ("busy", Bool(self.busy)),
    ("aborting", Bool(self.aborting)),
    ("owner", match self.owner { Some(o) => Str(o); None => Null }),
    ("steering", Arr(self.steering.map(s => J::Str(s)))),
  ])
}

///|
pub fn Turn::of_json(v : J?) -> Turn {
  let steering = []
  if field(v, "steering") is Some(Arr(ids)) {
    for id in ids {
      if id is Str(s) && !steering.contains(s) {
        steering.push(s)
      }
    }
  }
  { busy: field(v, "busy") is Some(Bool(true)), aborting: field(v, "aborting") is Some(Bool(true)), owner: str(field(v, "owner")), steering }
}

///|
/// A session as the program reads its process (acp.ts `AcpSession`).
pub(all) struct Session {
  /// which runtime: "agy", "grok", "devin" or "hermes"
  flavor : String
  /// the station keeps its transcript (acp.ts `KeptTranscript`: Antigravity CLI's, Devin's, Hermes')
  kept : Bool
  /// its ACP session's id ("" until the runtime names it)
  mut session : Array[Int]
  /// until the session is open: what session/load says again of its past is no turn
  mut loading : Bool
  turn : Turn
  mut live : Live
  calls : Array[(Array[Int], Call)]
  /// what the model said last in the running turn (acp.ts `saidLast`)
  mut said_last : Array[Int]
  /// what is being said, as the transcript keeps it: "assistant" or "thinking", and its text so far
  mut said : (String, Array[Int])?
  children : Array[(Array[Int], Child)]
}

///|
pub fn Session::new(flavor : String, kept~ : Bool) -> Session {
  {
    flavor,
    kept,
    session: [],
    loading: true,
    turn: { busy: false, aborting: false, owner: None, steering: [] },
    live: Live::new(),
    calls: [],
    said_last: [],
    said: None,
    children: [],
  }
}

///|
/// What `state` and `turn` said (a station's before: its snapshot as acp.ts `AcpSnapshot` has it).
pub fn Session::of_state(flavor : String, kept~ : Bool, turn : J?, state : J?) -> Session {
  let s = Session::new(flavor, kept~)
  let t = Turn::of_json(turn)
  s.turn.busy = t.busy
  s.turn.aborting = t.aborting
  s.turn.owner = t.owner
  s.turn.steering.append(t.steering)
  s.live = Live::of_state(field(state, "live"))
  s.session = str(field(state, "session")).unwrap_or([])
  s.loading = field(state, "loading") is Some(Bool(true))
  s.said_last = str(field(state, "saidLast")).unwrap_or([])
  if field(state, "said") is Some(Obj(_) as said) && str(said.get("text")) is Some(text) {
    s.said = Some((if is_str(said.get("type"), "thinking") { "thinking" } else { "assistant" }, text))
  }
  if field(state, "calls") is Some(Arr(calls)) {
    for c in calls {
      guard c is Arr([Str(id), call, ..]) else { continue }
      let started_at = match field(Some(call), "startedAt") {
        Some(Num(at)) => Some(at)
        _ => None
      }
      s.put_call(id, { name: str(field(Some(call), "name")).unwrap_or([]), input: or_else(field(Some(call), "input"), Null), started_at })
    }
  }
  if field(state, "children") is Some(Arr(children)) {
    for c in children {
      guard c is Arr([Str(id), child, ..]) else { continue }
      s.children.push((id, { live: Live::of_state(field(Some(child), "live")), parent: str(field(Some(child), "parent")) }))
    }
  }
  s
}

///|
/// What a station taking the session up goes on from: its turn is `Turn::json`.
pub fn Session::state(self : Session) -> J {
  obj([
    ("live", self.live.state()),
    ("said", match self.said { Some((kind, text)) => obj([("type", jstr(kind)), ("text", Str(text))]); None => Null }),
    ("calls", Arr(self.calls.map(c => J::Arr([Str(c.0), c.1.json()])))),
    ("saidLast", Str(self.said_last)),
    (
      "children",
      Arr(
        self.children.map(c => J::Arr([
          Str(c.0),
          obj([("live", c.1.live.state()), ("parent", match c.1.parent { Some(p) => Str(p); None => Null })]),
        ])),
      ),
    ),
    ("loading", Bool(self.loading)),
    ("session", Str(self.session)),
  ])
}

///|
fn Session::put_call(self : Session, id : Array[Int], call : Call) -> Unit {
  for i, c in self.calls {
    if c.0 == id {
      self.calls[i] = (id, call)
      return
    }
  }
  self.calls.push((id, call))
}

///|
fn Session::call(self : Session, id : Array[Int]) -> Call? {
  for c in self.calls {
    if c.0 == id {
      return Some(c.1)
    }
  }
  None
}

///|
/// The answers that end a turn: a prompt's, and where a message for the running turn is a prompt of its own
/// (Antigravity CLI's, Devin's) one's of those.
fn Session::ends_turn(self : Session, id : J?) -> Array[Int]? {
  guard id is Some(Str(s)) else { return None }
  if has_prefix(s, u("prompt:")) || ((self.flavor == "agy" || self.flavor == "devin") && has_prefix(s, u("steer:"))) {
    Some(s)
  } else {
    None
  }
}

///|
/// An update as the station reads it (each runtime's `normalized`).
fn Session::normalized(self : Session, update : J?) -> J? {
  match self.flavor {
    "agy" => agy_update(update)
    "hermes" => hermes_update(update)
    _ => update
  }
}

///|
/// What a line of its output comes to: the runtime's events, and whether Node reads the line.
pub(all) struct Said {
  events : Array[J]
  node : Bool
}

///|
fn kept(line : J) -> J {
  obj([("type", jstr("kept")), ("line", line)])
}

///|
/// What a message says (acp.ts `onMessage`); `now` when a call starts.
pub fn Session::line(self : Session, message : J, now : () -> Double) -> Said {
  let m = Some(message)
  let events = []
  let id = field(m, "id")
  let meth = field(m, "method")
  if is_str(meth, "session/update") {
    self.update(field(m, "params"), now, events)
    return { events, node: false }
  }
  if meth is Some(_) {
    // (a permission asked or another request of its own: Node answers it)
    if id is Some(_) {
      return { events, node: true }
    }
    self.notified(m, events)
    return { events, node: false }
  }
  guard self.ends_turn(id) is Some(answered) else { return { events, node: true } }
  // One put in the turn is answered with the turn (before or after its prompt's answer), or replaced by a newer
  // steering prompt (Antigravity CLI); one whose turn this station did not see the end of (taken up after a crash)
  // ends the turn running now.
  if self.turn.steering.search(answered) is Some(i) {
    ignore(self.turn.steering.remove(i))
    events.push(obj([("type", jstr("answered")), ("id", Str(answered)), ("answer", message)]))
    return { events, node: false }
  }
  if self.turn.owner is Some(owner) && owner != answered {
    return { events, node: false }
  }
  self.end(answered, message, events)
  { events, node: false }
}

///|
fn Session::update(self : Session, params : J?, now : () -> Double, events : Array[J]) -> Unit {
  let update = self.normalized(field(params, "update"))
  let from = field(params, "sessionId")
  // Its checklist, whole each time: told as it is, session/load's saying it again of its past included.
  if is_str(field(update, "sessionUpdate"), "plan") && (self.session.length() == 0 || !(from is Some(Str(_))) || is_text(from, self.session)) {
    if plan_of(update) is Some(plan) {
      events.push(live(obj([("kind", jstr("plan")), ("plan", plan)])))
    }
    return
  }
  if self.loading {
    return
  }
  if self.session.length() > 0 && from is Some(Str(other)) && other != self.session {
    return self.other(other, update, events)
  }
  if !self.turn.busy && turn_step(update) && !self.unprompted(events) {
    return
  }
  let done = self.track(update, now)
  self.heard_said(update)
  self.take(update, done, events)
  for e in self.live.feed(update) {
    events.push(live(e))
  }
  if is_str(field(update, "sessionUpdate"), "usage_update") {
    events.push(obj([("type", jstr("usage")), ("update", update.unwrap()), ("owner", match self.turn.owner { Some(o) => Str(o); None => Null })]))
  }
  if done is Some((_, call, failed, text)) && failed && station_tool(call.name) && @claude.unreachable(text) {
    events.push(obj([("type", jstr("toolsLost")), ("why", Str(@claude.chars(text, 300)))]))
  }
}

///|
/// runtime.ts `stationTool`.
fn station_tool(name : Array[Int]) -> Bool {
  has_prefix(name, u("mcp__stillfail__")) || has_prefix(name, u("stillfail__"))
}

///|
/// A step came with no turn running: a prompt of ours put in the turn as it ended became a turn of its own, which its
/// answer ends; any other is not a turn's.
fn Session::unprompted(self : Session, events : Array[J]) -> Bool {
  guard self.turn.steering.length() > 0 else { return false }
  let first = self.turn.steering.remove(0)
  self.turn.owner = Some(first)
  self.turn.busy = true
  self.said_last = []
  events.push(obj([("type", jstr("turnStarted"))]))
  true
}

///|
/// What an update says of its calls: one starting is under way; one done (completed or failed) is given back, with
/// what it said.
fn Session::track(self : Session, update : J?, now : () -> Double) -> (Array[Int], Call, Bool, Array[Int])? {
  let kind = field(update, "sessionUpdate")
  guard (is_str(kind, "tool_call") || is_str(kind, "tool_call_update")) && field(update, "toolCallId") is Some(Str(id)) else {
    return None
  }
  if is_str(kind, "tool_call") && self.call(id) is None {
    let (name, input) = acp_named(update)
    self.put_call(id, { name, input, started_at: Some(now()) })
  }
  guard self.call(id) is Some(call) else { return None }
  let failed = is_str(field(update, "status"), "failed")
  if !failed && !is_str(field(update, "status"), "completed") {
    return None
  }
  for i, c in self.calls {
    if c.0 == id {
      ignore(self.calls.remove(i))
      break
    }
  }
  // (`c?.content?.text ?? c?.text ?? ""`, those that are not "" joined as `join` writes them)
  let parts = []
  if field(update, "content") is Some(Arr(items)) {
    for c in items {
      let v = match field(field(Some(c), "content"), "text") {
        None | Some(Null) =>
          match field(Some(c), "text") {
            None | Some(Null) => None
            v => v
          }
        v => v
      }
      match v {
        None | Some(Str([])) => ()
        Some(x) => parts.push(@jsjson.js_string(x))
      }
    }
  }
  Some((id, call, failed, joined(parts, [0x0a])))
}

///|
/// What the turn said last: its words, started again by any other step of it.
fn Session::heard_said(self : Session, update : J?) -> Unit {
  if is_str(field(update, "sessionUpdate"), "agent_message_chunk") {
    if field(field(update, "content"), "text") is Some(Str(t)) {
      self.said_last = self.said_last + t
    }
  } else if turn_step(update) {
    self.said_last = []
  }
}

///|
/// What an update adds to the transcript kept (acp.ts `KeptTranscript.take`): what is being said grows, whole once
/// something else comes; a call once it is done.
fn Session::take(self : Session, update : J?, done : (Array[Int], Call, Bool, Array[Int])?, events : Array[J]) -> Unit {
  if !self.kept {
    return
  }
  let kind = field(update, "sessionUpdate")
  if is_str(kind, "agent_message_chunk") || is_str(kind, "agent_thought_chunk") {
    let t = if is_str(kind, "agent_message_chunk") { "assistant" } else { "thinking" }
    let text = str(field(field(update, "content"), "text")).unwrap_or([])
    if self.said is Some((was, _)) && was != t {
      self.flush(events)
    }
    match self.said {
      Some((was, said)) => self.said = Some((was, said + text))
      None => self.said = Some((t, text))
    }
    return
  }
  guard (is_str(kind, "tool_call") || is_str(kind, "tool_call_update")) && field(update, "toolCallId") is Some(Str(_)) else { return }
  self.flush(events)
  guard done is Some((id, call, failed, text)) else { return }
  let line = [("type", jstr("tool")), ("id", Str(id)), ("name", Str(call.name)), ("status", jstr(if failed { "error" } else { "completed" }))]
  if call.started_at is Some(at) {
    line.push(("startedAt", Num(at)))
  }
  line.push(("args", call.input))
  line.push(("result", Str(@claude.chars(text, 20000))))
  events.push(kept(obj(line)))
}

///|
/// What was being said, written.
fn Session::flush(self : Session, events : Array[J]) -> Unit {
  guard self.said is Some((kind, text)) else { return }
  if trimmed(text).length() > 0 {
    events.push(kept(obj([("type", jstr(kind)), ("text", Str(text))])))
  }
  self.said = None
}

///|
/// A subagent's session says its own steps: under the call that spawned it (Grok Build's).
fn Session::other(self : Session, from : Array[Int], update : J?, events : Array[J]) -> Unit {
  guard self.flavor == "grok" else { return }
  for c in self.children {
    if c.0 == from {
      for e in c.1.live.feed(update) {
        events.push(live(under_parent(e, from, c.1.parent)))
      }
      return
    }
  }
}

///|
/// grok.ts `underParent`: a subagent's step as the parent session shows it, its own id, marked a subagent's, under the
/// call that spawned it.
fn under_parent(event : J, child : Array[Int], parent : Array[Int]?) -> J {
  let kind = str(event.get("kind")).unwrap_or([])
  if kind == u("phase") || kind == u("tasks") || kind == u("plan") {
    return event
  }
  let id = u("sub:") + child + [0x3a] + str(event.get("id")).unwrap_or([])
  let e = with_field(event, "id", Str(id))
  if kind != u("start") {
    return e
  }
  let e = with_field(e, "subagent", Bool(true))
  match parent {
    Some(p) => with_field(e, "parent", Str(p))
    None => e
  }
}

///|
/// A notification of the runtime's own: Grok Build's subagents spawned and finished.
fn Session::notified(self : Session, message : J?, events : Array[J]) -> Unit {
  guard self.flavor == "grok" && is_str(field(message, "method"), "_x.ai/session_notification") else { return }
  guard is_text(field(field(message, "params"), "sessionId"), self.session) else { return }
  let update = field(field(message, "params"), "update")
  guard field(update, "child_session_id") is Some(Str(child)) else { return }
  if is_str(field(update, "sessionUpdate"), "subagent_spawned") {
    let fresh = { live: Live::new(), parent: self.live.open_call() }
    match self.children.iter().find_first(c => c.0 == child) {
      Some(_) =>
        for i, c in self.children {
          if c.0 == child {
            self.children[i] = (child, fresh)
          }
        }
      None => self.children.push((child, fresh))
    }
  }
  if is_str(field(update, "sessionUpdate"), "subagent_finished") {
    self.end_child(child, events)
  }
}

///|
/// A subagent done: what it still had open ends.
fn Session::end_child(self : Session, id : Array[Int], events : Array[J]) -> Unit {
  for i, c in self.children {
    if c.0 == id {
      ignore(self.children.remove(i))
      for e in c.1.live.ended() {
        events.push(live(under_parent(e, id, c.1.parent)))
      }
      return
    }
  }
}

///|
/// The kept line of a turn's end (acp.ts `KeptTranscript.ended`).
fn ended_line(outcome : J) -> J {
  let kind = str(outcome.get("kind")).unwrap_or([])
  let status = if kind == u("completed") { "finished" } else if kind == u("aborted") { "cancelled" } else { "error" }
  let fields = [("type", jstr("end")), ("status", jstr(status))]
  if kind == u("failed") {
    fields.push(("error", obj([("message", outcome.get("message").unwrap_or(Str([])))])))
  }
  obj(fields)
}

///|
/// The turn ended as the answer to its prompt says.
fn Session::end(self : Session, id : Array[Int], answer : J, events : Array[J]) -> Unit {
  let a = Some(answer)
  let mut outcome = if self.turn.aborting && field(a, "error") is Some(_) {
    obj([("kind", jstr("aborted"))])
  } else {
    acp_outcome(self.flavor, a)
  }
  let said = trimmed(self.said_last)
  self.said_last = []
  if self.flavor == "agy" && is_str(outcome.get("kind"), "completed") && said.length() > 0 && notice_failure(said) is Some(reason) {
    outcome = failed(reason, @claude.chars(last_line(said), 1000))
  }
  // An answer to a prompt this station did not see start (taken up after a crash just as it was given).
  if !self.turn.busy {
    events.push(obj([("type", jstr("turnStarted"))]))
  }
  self.turn.busy = false
  self.turn.aborting = false
  self.turn.owner = None
  self.flush(events)
  events.push(obj([("type", jstr("answered")), ("id", Str(id)), ("answer", answer), ("outcome", outcome)]))
  if self.flavor == "grok" {
    for c in self.children.map(c => c.0) {
      self.end_child(c, events)
    }
  }
  if self.kept {
    events.push(kept(ended_line(outcome)))
  }
  self.calls.clear()
  for e in self.live.ended() {
    events.push(live(e))
  }
  events.push(obj([("type", jstr("turnEnded")), ("outcome", outcome)]))
}

///|
/// A prompt of Node's, `owner` its id (acp.ts `prompt`): the turn runs, its message kept, the turn with the model.
pub fn Session::prompted(self : Session, owner : Array[Int], text : Array[Int]) -> Array[J] {
  let events = []
  self.turn.busy = true
  self.said_last = []
  self.turn.owner = Some(owner)
  self.user(text, false, events)
  for e in self.live.prompted() {
    events.push(live(e))
  }
  events
}

///|
/// A prompt of Node's put in the running turn (acp.ts `injectPrompt`): `take_over`, it is the one whose answer ends the
/// turn from now on (Antigravity CLI's).
pub fn Session::injected(self : Session, id : Array[Int], take_over : Bool, text : Array[Int]) -> Array[J] {
  let events = []
  let add = (s : Array[Int]) => if !self.turn.steering.contains(s) { self.turn.steering.push(s) }
  if take_over {
    if self.turn.owner is Some(o) {
      add(o)
    }
    self.turn.owner = Some(id)
  } else {
    add(id)
  }
  self.user(text, true, events)
  events
}

///|
fn Session::user(self : Session, text : Array[Int], steered : Bool, events : Array[J]) -> Unit {
  if !self.kept {
    return
  }
  self.flush(events)
  let fields = [("type", jstr("user")), ("text", Str(text))]
  if steered {
    fields.push(("steered", Bool(true)))
  }
  events.push(kept(obj(fields)))
}

///|
/// Its process went away during a turn: what was being said is written, its steps end with it (acp.ts `cutShort`;
/// the turn's end in the transcript is Node's, which knows how it exited).
pub fn Session::cut_short(self : Session) -> Array[J] {
  let events = []
  if !self.turn.busy {
    return events
  }
  self.flush(events)
  self.calls.clear()
  for e in self.live.ended() {
    events.push(live(e))
  }
  events
}

///|
/// What a station that crashed had read of its output, read again (acp.ts `replay`): the session, whether a turn runs,
/// what the turn had said and called so far; what it was opened with (`opened`) and its updates of usage (`usages`),
/// for Node.
pub(all) struct Replay {
  s : Session
  mut open : Bool
  mut opened : J?
  mut partial : Array[J?]
}

///|
pub fn Replay::new(flavor : String, kept~ : Bool, from_id : Array[Int]) -> Replay {
  let s = Session::new(flavor, kept~)
  s.session = from_id
  { s, open: false, opened: None, partial: [] }
}

///|
pub fn Replay::line(self : Replay, message : J) -> Unit {
  let m = Some(message)
  let s = self.s
  if is_str(field(m, "id"), "open") {
    self.open = true
    if field(field(m, "result"), "sessionId") is Some(Str(id)) {
      s.session = id
    }
    if field(m, "result") is Some(result) {
      self.opened = Some(result)
    }
  } else if self.open &&
    is_str(field(m, "method"), "session/update") &&
    (s.session.length() == 0 || is_text(field(field(m, "params"), "sessionId"), s.session)) {
    let update = s.normalized(field(field(m, "params"), "update"))
    if turn_step(update) {
      s.turn.busy = true
      ignore(s.live.feed(update))
      self.partial.push(update)
    } else if s.turn.busy || is_str(field(update, "sessionUpdate"), "usage_update") {
      self.partial.push(update)
    }
  } else if s.ends_turn(field(m, "id")) is Some(_) {
    s.turn.busy = false
    ignore(s.live.ended())
    self.partial = []
  }
}

///|
/// What was read again, as if heard now, nothing of it written again: the session as it leaves it, and its updates of
/// usage, which Node reads as it did then.
pub fn Replay::finish(self : Replay, now : () -> Double) -> Array[J] {
  let s = self.s
  s.loading = false
  let usages = []
  let quiet = []
  for update in self.partial {
    let done = s.track(update, now)
    s.take(update, done, quiet)
    if is_str(field(update, "sessionUpdate"), "usage_update") {
      usages.push(update.unwrap())
    }
  }
  usages
}

///|
pub fn Replay::session(self : Replay) -> Session {
  self.s
}

///|
pub fn Replay::opened(self : Replay) -> J? {
  self.opened
}
