// What a Codex app-server's thread notifications do to its session, as the TypeScript station had it (live.ts
// `LiveFromCodex`; codex.ts `codexToolsLost`, `codexCompacted`, `classifyCodexError` and its `CodexSession.sink`): the
// live steps a device is shown, the station's tools out of reach, a compaction, a turn's start and its outcome with its
// failure's reason. Notifications are read as JSON.parse reads them and what is said of them written as JSON.stringify
// writes it (station/jsjson), so what is told is what the TypeScript made of the same lines.

///|
using @jsjson {type JValue}

///|
using @live_wire {
  jstr, obj, field, is_str, start, pretty,
}

///|
type J = JValue

///|
/// `typeof v === "string" ? v : ""`.
fn text(v : J?) -> String {
  match v {
    Some(Str(s)) => s
    _ => ""
  }
}

///|
/// The items a turn works on (live.ts `TOOL_ITEMS`).
let tool_items : Array[String] = ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch"]

///|
/// The methods of a step's deltas (what it writes as it goes).
pub let delta_methods : Array[String] = [
  "item/agentMessage/delta", "item/reasoning/textDelta", "item/reasoning/summaryTextDelta", "item/plan/delta", "item/commandExecution/outputDelta",
]

///|
/// A thread's live steps (live.ts `LiveFromCodex`): the items started and not completed, in the order they started, and
/// where the turn stands with the model.
pub(all) struct Live {
  open : Array[String]
  mut phase : String?
}

///|
pub fn Live::new() -> Live {
  { open: [], phase: None }
}

///|
/// What `state` said (a station's before, or this one's after a crash).
pub fn Live::of_state(state : J) -> Live {
  let live = Live::new()
  if state.get("open") is Some(Arr(ids)) {
    for id in ids {
      if id is Str(s) && !live.open.contains(s) {
        live.open.push(s)
      }
    }
  }
  if state.get("phase") is Some(Str(p)) {
    live.phase = Some(p)
  }
  live
}

///|
/// What a station taking the session up goes on from (`CodexLiveState`).
pub fn Live::state(self : Live) -> J {
  obj([("open", Arr(self.open.map(id => J::Str(id)))), ("phase", match self.phase { Some(p) => jstr(p); None => Null })])
}

///|
fn Live::close(self : Live, id : String) -> Bool {
  match self.open.search(id) {
    Some(i) => {
      ignore(self.open.remove(i))
      true
    }
    None => false
  }
}

///|
/// A notification's live steps (`LiveFromCodex.feed`).
pub fn Live::feed(self : Live, method : String, params : J) -> Array[J] {
  let out = []
  let to = (next : String) => if self.phase != Some(next) {
    self.phase = Some(next)
    out.push(obj([("kind", jstr("phase")), ("phase", jstr(next))]))
  }
  let item = field(Some(params), "item")
  let item_type = text(field(item, "type"))
  if method == "turn/started" {
    to("requesting")
  } else if method == "turn/completed" {
    self.phase = None
  } else if method == "item/agentMessage/delta" || method.has_prefix("item/reasoning/") {
    to("responding")
  } else if method == "item/started" && tool_items.contains(item_type) {
    to("working")
  } else if method == "item/completed" && tool_items.contains(item_type) {
    to("requesting")
  }
  if method == "item/started" {
    let id = match field(item, "id") {
      Some(Str(s)) => s
      Some(Num(_) as n) => @jsjson.stringify(n)
      _ => ""
    }
    let begun : (String, String?, String?)? = match item_type {
      "agentMessage" => Some(("text", None, None))
      "reasoning" => Some(("thinking", None, None))
      "commandExecution" => Some(("tool", Some("shell"), Some(text(field(item, "command")))))
      "fileChange" => {
        let paths = match field(item, "changes") {
          Some(Arr(cs)) => cs.map(c => text(field(Some(c), "path")))
          _ => []
        }
        Some(("tool", Some("apply_patch"), Some(paths.join("\n"))))
      }
      "mcpToolCall" =>
        Some(("tool", Some(text(field(item, "server")) + "." + text(field(item, "tool"))), Some(pretty(field(item, "arguments")))))
      "dynamicToolCall" => Some(("tool", Some(text(field(item, "tool"))), Some(pretty(field(item, "arguments")))))
      "webSearch" => Some(("tool", Some("web_search"), Some(text(field(item, "query")))))
      _ => None
    }
    if id.length() > 0 && begun is Some((step, tool, input)) {
      if !self.open.contains(id) {
        self.open.push(id)
      }
      out.push(start(id, step, tool, input))
    }
  } else if delta_methods.contains(method) {
    let id = text(field(Some(params), "itemId"))
    let delta = text(field(Some(params), "delta"))
    if self.open.contains(id) && delta.length() > 0 {
      let f = if method == "item/commandExecution/outputDelta" { "output" } else { "text" }
      out.push(obj([("kind", jstr("delta")), ("id", Str(id)), ("field", jstr(f)), ("text", Str(delta))]))
    }
  } else if method == "item/completed" {
    let id = text(field(item, "id"))
    if self.close(id) {
      out.push(obj([("kind", jstr("end")), ("id", Str(id))]))
    }
  }
  out
}
