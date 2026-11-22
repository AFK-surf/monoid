// What Claude Code's stream-json frames do to a session, as the TypeScript station had it (station/src/agents/claude.ts:
// `turnAfter` keeps where its turn stands for a crash's reading again, `toolsLostIn`) and station/src/agents/live.ts (`LiveFromClaude`) say: where its turn stands, its tasks, the live steps a device is
// shown, the station's tools out of reach. Frames are read as JSON.parse reads them and what is said of them written
// as JSON.stringify writes it (station/jsjson), so what is told Node is what the TypeScript made of the same lines. A
// turn's outcome is told whole, its failure's reason too (outcome.mbt).

///|
using @jsjson {type JValue}

///|
using @live_wire {
  jstr, obj, field, str, non_empty, is_str, joined, failed,
}

///|
type J = JValue

///|
fn is_true(v : J?) -> Bool {
  v is Some(Bool(true))
}

///|
/// `Number.isInteger(v)`.
fn integer(v : J?) -> Double? {
  match v {
    Some(Num(d)) if !d.is_nan() && !d.is_inf() && d == d.floor() => Some(d)
    _ => None
  }
}

///|
/// At most `n` characters (live.ts `chars`: Array.from, a lone surrogate one).
pub fn chars(text : String, n : Int) -> String {
  @jsjson.chars(text, n)
}

///|
/// A JavaScript number as `${n}` says it.
fn number_text(d : Double) -> String {
  @jsjson.stringify(Num(d))
}

///|
/// A task it runs, as claude.ts `Task` keeps it.
pub(all) struct Task {
  id : String
  kind : String
  description : String
  background : Bool
  started_at : Double?
}

///|
/// Where its turn stands (claude.ts `Turn`).
pub(all) struct Turn {
  mut busy : Bool
  mut aborting : Bool
  mut auth_failure : String?
  mut closed : Bool
  mut renews : Bool?
  mut renewed : Bool?
  /// by id, as the object keeps them (Object.values' order: `ordered`)
  mut tasks : Array[(String, Task)]?
  mut compacting : Bool?
  mut compact_error : String?
}

///|
pub fn Turn::new() -> Turn {
  {
    busy: false,
    aborting: false,
    auth_failure: None,
    closed: false,
    renews: None,
    renewed: None,
    tasks: None,
    compacting: None,
    compact_error: None,
  }
}

///|
/// An object's entries in the order JavaScript gives them: array indices first, ascending, then as they were put.
fn ordered(entries : Array[(String, Task)]) -> Array[(String, Task)] {
  let indexed = entries.filter(e => @jsjson.index_key(e.0) is Some(_))
  indexed.sort_by((a, b) => @jsjson.index_key(a.0).unwrap().compare(@jsjson.index_key(b.0).unwrap()))
  indexed + entries.filter(e => @jsjson.index_key(e.0) is None)
}

///|
/// `{ ...tasks, [id]: task }`: in its place where it was there, else after the rest.
fn put(entries : Array[(String, Task)], id : String, task : Task) -> Array[(String, Task)] {
  let out = ordered(entries)
  for i, e in out {
    if e.0 == id {
      out[i] = (id, task)
      return out
    }
  }
  out.push((id, task))
  out
}

///|
/// claude.ts `backgroundOf`: what of its tasks runs in the background.
pub fn background_of(turn : Turn) -> J {
  let out = []
  for e in ordered(turn.tasks.unwrap_or([])) {
    let t = e.1
    if !t.background {
      continue
    }
    let fields : Array[(String, J)] = [("id", Str(t.id)), ("kind", jstr(t.kind)), ("description", Str(t.description))]
    if t.started_at is Some(at) {
      fields.push(("startedAt", Num(at)))
    }
    out.push(obj(fields))
  }
  Arr(out)
}

///|
/// claude.ts `RENEW_ATTEMPTS`.
const RENEW_ATTEMPTS : Double = 2.0

///|
/// What a frame does to the turn (claude.ts `turnAfter`, and what it tells): events said with `emit`, `interrupt` how an authentication
/// failure stops the turn, `now` the time a task starts, `note` what is logged.
pub fn on_frame(
  frame : J,
  turn : Turn,
  emit : (J) -> Unit,
  interrupt : () -> Unit,
  now : () -> Double,
  note : (String) -> Unit,
) -> Unit {
  let before = @jsjson.stringify(background_of(turn))
  frame_does(frame, turn, emit, interrupt, now, note)
  let tasks = background_of(turn)
  if @jsjson.stringify(tasks) != before {
    emit(obj([("type", jstr("live")), ("event", obj([("kind", jstr("tasks")), ("tasks", tasks)]))]))
  }
}

///|
fn frame_does(
  frame : J,
  turn : Turn,
  emit : (J) -> Unit,
  interrupt : () -> Unit,
  now : () -> Double,
  note : (String) -> Unit,
) -> Unit {
  let f = Some(frame)
  let kind = str(field(f, "type")).unwrap_or("")
  let subtype = str(field(f, "subtype")).unwrap_or("")
  let system = kind == "system"
  if kind == "control_response" && is_str(field(field(f, "response"), "subtype"), "error") {
    note("claude refused a control request")
  }
  if system && subtype == "init" {
    let was = turn.busy
    turn.busy = true
    if !was {
      emit(obj([("type", jstr("turnStarted"))]))
    }
  } else if system && subtype == "api_retry" {
    let status = integer(field(f, "error_status")).unwrap_or(0.0)
    let attempt = integer(field(f, "attempt")).unwrap_or(1.0)
    let renewing = status == 401.0 && turn.renews == Some(true) && turn.renewed != Some(true) && attempt <= RENEW_ATTEMPTS
    if (status == 401.0 || status == 403.0) && turn.auth_failure is None && !renewing {
      let error = match field(f, "error") {
        None => "authentication failed"
        Some(Str(s)) => s
        Some(v) => @jsjson.stringify(v)
      }
      turn.auth_failure = Some(number_text(status) + " " + error)
      interrupt()
      turn.aborting = true
    }
  } else if system &&
    subtype == "task_started" &&
    str(field(f, "task_id")) is Some(id) &&
    !is_true(field(f, "owned_by_subagent")) {
    let description = str(field(f, "description")).unwrap_or("")
    let task = {
      id,
      kind: if is_str(field(f, "task_type"), "local_agent") { "agent" } else { "command" },
      description,
      background: is_true(field(f, "is_backgrounded")),
      started_at: Some(now()),
    }
    turn.tasks = Some(put(turn.tasks.unwrap_or([]), id, task))
  } else if system &&
    (subtype == "task_notification" || subtype == "task_updated") &&
    str(field(f, "task_id")) is Some(id) &&
    turn.tasks is Some(tasks) &&
    tasks.iter().find_first(e => e.0 == id) is Some((_, task)) {
    let notified = subtype == "task_notification"
    let status = if notified { field(f, "status") } else { field(field(f, "patch"), "status") }
    let rest = ordered(tasks).filter(e => e.0 != id)
    let ended = ["completed", "failed", "killed", "stopped"].iter().any(s => is_str(status, s))
    if notified || ended {
      turn.tasks = Some(rest)
    } else if is_true(field(field(f, "patch"), "is_backgrounded")) {
      turn.tasks = Some(put(rest, id, { ..task, background: true }))
    }
  } else if system && subtype == "status" && turn.compacting == Some(true) && is_str(field(f, "compact_result"), "failed") {
    turn.compact_error = match str(field(f, "compact_error")) {
      Some(e) if e.length() > 0 => Some(e)
      _ => Some("compaction failed")
    }
  } else if system && subtype == "compact_boundary" {
    emit(obj([("type", jstr("compacted"))]))
  } else if kind == "result" {
    let errors = match field(f, "errors") {
      Some(Arr(all)) =>
        all.filter_map(e => match e {
          Str(s) if @jscase.trim(s) != "" => Some(s)
          _ => None
        })
      _ => []
    }
    let text = match str(field(f, "result")) {
      Some(r) if @jscase.trim(r) != "" => r
      _ => if errors.length() > 0 { joined(errors, "\n") } else { subtype }
    }
    let outcome = if turn.auth_failure is Some(failure) {
      auth_outcome(failure)
    } else if turn.aborting {
      obj([("kind", jstr("aborted"))])
    } else if is_true(field(f, "is_error")) {
      error_outcome(text)
    } else if turn.compact_error is Some(e) && e.length() > 0 {
      failed("other", chars(e, 1000))
    } else {
      obj([("kind", jstr("completed"))])
    }
    turn.busy = false
    turn.aborting = false
    turn.auth_failure = None
    turn.renewed = Some(false)
    turn.compacting = Some(false)
    turn.compact_error = None
    if turn.tasks is Some(tasks) {
      turn.tasks = Some(ordered(tasks).filter(e => e.1.background))
    }
    emit(obj([("type", jstr("turnEnded")), ("outcome", outcome)]))
  }
}

///|
/// The station's calls of its own tools not answered yet, and what a frame says of those tools out of reach
/// (claude.ts `toolsLostIn`): a server that failed as the turn started, or a call's error saying so.
pub fn tools_lost_in(frame : J, calls : Array[String]) -> String? {
  let f = Some(frame)
  let kind = field(f, "type")
  let content = match field(field(f, "message"), "content") {
    Some(Arr(c)) => c
    _ => []
  }
  if is_str(kind, "system") && is_str(field(f, "subtype"), "init") && field(f, "mcp_servers") is Some(Arr(servers)) {
    let server = servers.iter().find_first(s => is_str(field(Some(s), "name"), "stillfail"))
    if server is Some(s) && is_str(field(Some(s), "status"), "failed") {
      return Some("the stillfail MCP server failed to connect")
    }
  } else if is_str(kind, "assistant") {
    for c in content {
      let cc = Some(c)
      if is_str(field(cc, "type"), "tool_use") &&
        str(field(cc, "id")) is Some(id) &&
        str(field(cc, "name")) is Some(name) &&
        name.has_prefix("mcp__stillfail__") &&
        !calls.contains(id) {
        calls.push(id)
      }
    }
  } else if is_str(kind, "user") {
    for c in content {
      let cc = Some(c)
      if !is_str(field(cc, "type"), "tool_result") {
        continue
      }
      let deleted = match str(field(cc, "tool_use_id")) {
        Some(id) =>
          match calls.search(id) {
            Some(at) => {
              calls.remove(at) |> ignore
              true
            }
            None => false
          }
        None => false
      }
      if !deleted || !is_true(field(cc, "is_error")) {
        continue
      }
      let text = match field(cc, "content") {
        Some(Str(s)) => s
        Some(Arr(parts)) => joined(parts.map(x => str(field(Some(x), "text")).unwrap_or("")), "\n")
        _ => ""
      }
      if unreachable(text) {
        return Some(chars(text, 300))
      }
    }
  }
  None
}

///|
/// A content block of the model's response being said (live.ts `Block`).
pub(all) struct Block {
  id : String
  step : String
  tool : String?
  mut input : String?
  subagent : String?
}

///|
/// Claude Code's partial messages as live steps (live.ts `LiveFromClaude`).
pub(all) struct Live {
  mut message : String
  /// by index, as a Map keeps them
  mut blocks : Array[(Int, Block)]
  mut tools : Array[String]
}

///|
pub fn Live::new() -> Live {
  { message: "", blocks: [], tools: [] }
}

///|
fn start(id : String, step : String, tool : String?, input : String?, parent : String?) -> J {
  let fields : Array[(String, J)] = [("kind", jstr("start")), ("id", Str(id)), ("step", jstr(step))]
  if tool is Some(t) {
    fields.push(("tool", Str(t)))
  }
  if input is Some(i) {
    fields.push(("input", Str(i)))
  }
  if parent is Some(p) {
    fields.push(("subagent", Bool(true)))
    fields.push(("parent", Str(p)))
  }
  obj(fields)
}

///|
fn Live::block(self : Live, index : Int) -> Block? {
  for b in self.blocks {
    if b.0 == index {
      return Some(b.1)
    }
  }
  None
}

///|
/// The live steps a frame says (live.ts `feed`); `now` names a message that says no id.
pub fn Live::feed(self : Live, frame : J, now : () -> Double) -> Array[J] {
  let out = []
  let f = Some(frame)
  let kind = str(field(f, "type")).unwrap_or("")
  let phase = (p : String) => obj([("kind", jstr("phase")), ("phase", jstr(p))])
  if kind == "system" && is_str(field(f, "subtype"), "status") && is_str(field(f, "status"), "requesting") {
    out.push(phase("requesting"))
  } else if kind == "stream_event" {
    let e = match field(f, "event") {
      None | Some(Null) => None
      some => some
    }
    let parent = non_empty(field(f, "parent_tool_use_id"))
    let event = str(field(e, "type")).unwrap_or("")
    if event == "message_stop" && parent is None {
      out.push(phase("working"))
    }
    let index = match integer(field(e, "index")) {
      Some(i) => i.to_int()
      None => -1
    }
    if event == "message_start" {
      self.message = match str(field(field(e, "message"), "id")) {
        Some(id) => id
        None => number_text(now())
      }
      self.blocks = []
      if parent is None {
        out.push(phase("responding"))
      }
    } else if event == "content_block_start" {
      let b = field(e, "content_block")
      let step = match str(field(b, "type")) {
        Some("text") => "text"
        Some("thinking") => "thinking"
        Some("tool_use") => "tool"
        _ => return out
      }
      let id = match str(field(b, "id")) {
        Some(id) if step == "tool" => id
        _ => self.message + ":" + number_text(index.to_double())
      }
      let tool = if step == "tool" { Some(str(field(b, "name")).unwrap_or("tool")) } else { None }
      if step == "tool" && !self.tools.contains(id) {
        self.tools.push(id)
      }
      out.push(start(id, step, tool, None, parent))
      let block = { id, step, tool, input: if tool is Some(_) { Some("") } else { None }, subagent: parent }
      let mut placed = false
      for i, kept in self.blocks {
        if kept.0 == index {
          self.blocks[i] = (index, block)
          placed = true
          break
        }
      }
      if !placed {
        self.blocks.push((index, block))
      }
    } else if event == "content_block_delta" {
      guard self.block(index) is Some(block) else { return out }
      let d = field(e, "delta")
      let delta = (name : String, text : String) => obj([
        ("kind", jstr("delta")),
        ("id", Str(block.id)),
        ("field", jstr(name)),
        ("text", Str(text)),
      ])
      match str(field(d, "type")) {
        Some("text_delta") =>
          if non_empty(field(d, "text")) is Some(text) {
            out.push(delta("text", text))
          }
        Some("thinking_delta") =>
          if non_empty(field(d, "thinking")) is Some(text) {
            out.push(delta("text", text))
          } else if field(d, "estimated_tokens") is Some(Num(n)) && n > 0.0 {
            out.push(obj([("kind", jstr("delta")), ("id", Str(block.id)), ("field", jstr("text")), ("text", Str("")), ("tokens", Num(n))]))
          }
        Some("input_json_delta") =>
          if non_empty(field(d, "partial_json")) is Some(partial) {
            if block.input is Some(input) && input.length() < @live_wire.INPUT_MOST {
              block.input = Some(input + partial)
            }
            out.push(delta("input", partial))
          }
        _ => ()
      }
    } else if event == "content_block_stop" {
      if self.block(index) is Some(block) {
        if block.step != "tool" {
          out.push(obj([("kind", jstr("end")), ("id", Str(block.id))]))
        } else if block.input is Some(input) && input.length() > 0 {
          out.push(start(block.id, "tool", block.tool, Some(input), block.subagent))
        }
      }
    }
  } else if kind == "user" {
    let content = match field(field(f, "message"), "content") {
      Some(Arr(c)) => c
      _ => []
    }
    for c in content {
      let cc = Some(c)
      let id = str(field(cc, "tool_use_id")).unwrap_or("")
      guard is_str(field(cc, "type"), "tool_result") && self.tools.contains(id) else { continue }
      let text = match field(cc, "content") {
        Some(Str(s)) => s
        Some(Arr(parts)) => joined(parts.map(x => str(field(Some(x), "text")).unwrap_or("")), "\n")
        _ => ""
      }
      if text.length() > 0 {
        out.push(obj([("kind", jstr("delta")), ("id", Str(id)), ("field", jstr("output")), ("text", Str(chars(text, 8000)))]))
      }
      out.push(obj([("kind", jstr("end")), ("id", Str(id))]))
      match self.tools.search(id) {
        Some(at) => self.tools.remove(at) |> ignore
        None => ()
      }
    }
  }
  out
}

///|
/// What it keeps between frames (live.ts `state`), as JSON.
pub fn Live::state(self : Live) -> J {
  let blocks = self.blocks.map(b => {
    let k = b.1
    let fields : Array[(String, J)] = [("id", Str(k.id)), ("step", jstr(k.step))]
    if k.tool is Some(t) {
      fields.push(("tool", Str(t)))
    }
    if k.input is Some(i) {
      fields.push(("input", Str(i)))
    }
    if k.subagent is Some(s) {
      fields.push(("subagent", Str(s)))
    }
    (Arr([Num(b.0.to_double()), obj(fields)]) : J)
  })
  obj([("message", Str(self.message)), ("blocks", Arr(blocks)), ("tools", Arr(self.tools.map(t => Str(t))))])
}

///|
/// The live state a snapshot said (live.ts's constructor).
pub fn Live::of_state(state : J) -> Live {
  let s = Some(state)
  let blocks = match field(s, "blocks") {
    Some(Arr(all)) =>
      all.filter_map(e => match e {
        Arr([Num(i), Obj(_) as b]) => {
          let bb = Some(b)
          Some((i.to_int(), {
            id: str(field(bb, "id")).unwrap_or(""),
            step: if is_str(field(bb, "step"), "tool") { "tool" } else if is_str(field(bb, "step"), "thinking") { "thinking" } else { "text" },
            tool: str(field(bb, "tool")),
            input: str(field(bb, "input")),
            subagent: str(field(bb, "subagent")),
          }))
        }
        _ => None
      })
    _ => []
  }
  let tools = match field(s, "tools") {
    Some(Arr(all)) => all.filter_map(t => str(Some(t)))
    _ => []
  }
  { message: str(field(s, "message")).unwrap_or(""), blocks, tools }
}

///|
/// runtime.ts `unreachable`: its words, ASCII letters in either case (a regular expression's `i` folds no other letter
/// to one of those).
pub fn unreachable(text : String) -> Bool {
  let lower = ascii_lower(text)
  [
    "econnrefused", "econnreset", "unable to connect", "is not connected", "fetch failed", "socket hang up", "connection refused",
    "failed to connect to mcp server",
  ].iter().any(w => lower.contains(w))
}
