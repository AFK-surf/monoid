// The station's MCP endpoint (station/src/tools/mcp.ts): streamable HTTP, JSON responses only. Every request carries
// the session's bearer token; tools run on behalf of that session. This takes a request's method, authorization and
// body, and gives its status and body; the HTTP wiring is the door's (door.mbt).

///|
/// The tools that reach out of the station, refused while it is in no workspace (`gate`).
pub let outward : Array[String] = [
  "chat_post", "slack_api", "job_start", "station_list", "station_task", "station_file",
  "peer_forward",
]

///|
/// What a refused outward call says.
pub let unbound_refusal : String = "Refused: this station is not in a still.fail workspace right now (it was removed from it, or has not joined one), so it does not post to chats or Slack, call Slack, or start jobs. Nothing was sent. Stop here and do not retry: when the station is back in its workspace, the interrupted work resumes and you can post then."

///|
/// Declared first, whatever the budget: what every turn needs and the work sent elsewhere.
pub let core : Array[String] = [
  "chat_post", "chat_state", "chat_history", "chat_read", "job_start", "job_log", "job_list",
  "job_stop", "station_task", "station_file", "skill_read",
]

///|
/// Declared next when a runtime budgets its tools (mcp.ts `PRIORITY`).
pub let priority : Array[String] = [
  "chat_list", "chat_create", "session_send", "chat_configure", "chat_archive", "session_history",
  "search", "station_list", "device_list", "device_use", "browser", "screen", "secret_list",
  "secret_use", "secret_run",
]

///|
/// Superseded tools omitted from tools/list and station_tool while kept callable (mcp.ts `HIDDEN`).
pub let hidden : Array[String] = [
  "adb_devices", "phone_use", "secret_reask", "station_retire",
]

///|
/// What every turn calls.
pub let every_turn : Array[String] = ["chat_post", "chat_state"]

///|
/// By which a session speaks or acts in chats as itself: its own agent's alone (mcp.ts `SPEAKS`).
pub let speaks : Array[String] = [
  "chat_post", "chat_state", "session_send", "chat_create", "chat_leave", "chat_archive",
  "chat_configure",
]

///|
/// The one that speaks only where its method writes.
pub let speaks_writing : String = "slack_api"

///|
/// The Slack methods that write, each a method or the start of some.
pub let slack_writes : Array[String] = [
  "chat.postMessage", "chat.postEphemeral", "chat.scheduleMessage", "chat.update",
  "chat.delete", "chat.meMessage", "reactions.add", "reactions.remove", "pins.add",
  "pins.remove", "files.completeUploadExternal", "assistant.threads.",
]

///|
pub fn is_slack_write(method : String) -> Bool {
  slack_writes.iter().any(w => method.has_prefix(w))
}

///|
/// What a subagent is kept from in Slack: the writes, and a streamed message.
pub let slack_spoken : Array[String] = [
  ..slack_writes, "chat.startStream", "chat.appendStream", "chat.stopStream",
]

///|
pub fn speaks_in_slack(method : String) -> Bool {
  slack_spoken.iter().any(w => method.has_prefix(w))
}

///|
/// The tool that reaches those a budget left undeclared.
pub let indirect : String = "station_tool"

///|
/// A tool result's parts (MCP's content): text, or an image as base64 with its type.
pub(all) enum Content {
  Text(String)
  Image(String, String)
}

///|
pub fn Content::to_jv(self : Content) -> JV {
  match self {
    Text(t) => jobj([("type", js("text")), ("text", js(t))])
    Image(data, mime) =>
      jobj([("type", js("image")), ("data", js(data)), ("mimeType", js(mime))])
  }
}

///|
pub(all) struct ToolReply {
  content : Array[Content]
  is_error : Bool
}

///|
/// A tool: its declaration, and what it does for a session. `run` gives the text the agent sees (a raised error's
/// message comes back as a tool error); `content` what it sees when it is more than text, called instead of `run`.
/// `signal` is the call's abort signal, as a part is given it (`jsignal`), or undefined.
pub(all) struct Tool {
  name : String
  description : String
  input_schema : JV
  run : async (String, JV, JV) -> String
  content : (async (String, JV) -> ToolReply)?
}

///|
pub fn Tool::new(
  decl : JV,
  run : async (String, JV, JV) -> String,
  content? : async (String, JV) -> ToolReply,
) -> Tool {
  {
    name: jstr(decl.get("name")).unwrap_or(""),
    description: jstr(decl.get("description")).unwrap_or(""),
    input_schema: decl.get("inputSchema").unwrap_or(jobj([])),
    run,
    content,
  }
}

///|
/// A tool as tools/list declares it.
pub fn declared(t : Tool) -> JV {
  jobj([
    ("name", js(t.name)),
    ("description", js(t.description)),
    ("inputSchema", t.input_schema),
  ])
}

///|
/// What a tool's declaration weighs: its bytes as JSON.
pub fn weight(t : Tool) -> Int {
  byte_length(stringify(declared(t)))
}

///|
/// The tools to declare within `budget` bytes, and the rest, reached through `indirect` (mcp.ts `fitted`).
pub fn fitted(tools : Array[Tool], budget : Int) -> (Array[Tool], Array[Tool]) {
  let visible = tools.filter(t => !hidden.contains(t.name))
  let core_tools = []
  for name in core {
    for t in visible {
      if t.name == name {
        core_tools.push(t)
      }
    }
  }
  let priority_tools = []
  for name in priority {
    if !core.contains(name) {
      for t in visible {
        if t.name == name {
          priority_tools.push(t)
        }
      }
    }
  }
  let others = visible.filter(t => !core.contains(t.name) && !priority.contains(t.name))
  let weights = Map::new()
  for t in visible {
    weights[t.name] = weight(t)
  }
  let w = (t : Tool) => weights.get(t.name).unwrap_or(0)
  others.sort_by((a, b) => {
    let d = w(a) - w(b)
    if d != 0 {
      d
    } else if js_compare(a.name, b.name) < 0 {
      -1
    } else {
      1
    }
  })
  let queue = [..priority_tools, ..others]
  let fits = (list : Array[Tool], left : Array[Tool]) => {
    let mut n = 0
    for t in list {
      n += w(t)
    }
    if left.length() == 0 {
      n
    } else {
      n + weight(indirect_tool(left))
    }
  }
  let out = core_tools.copy()
  let rest = []
  for i in 0..<queue.length() {
    let t = queue[i]
    let remaining = [..rest, ..queue[i + 1:]]
    if fits([..out, t], remaining) <= budget {
      out.push(t)
    } else {
      rest.push(t)
    }
  }
  let names = out.map(t => t.name)
  (visible.filter(t => names.contains(t.name)), rest)
}

///|
/// The tool that calls one left undeclared by name.
pub fn indirect_tool(rest : Array[Tool]) -> Tool {
  let lines = rest.map(t => "\{t.name}: \{first_sentence(t.description)}").join("\n")
  {
    name: indirect,
    description: "Call a station tool not declared to you, by name. First call it with only name to read that tool's description and parameters, then with name and arguments to run it. The tools:\n\{lines}",
    input_schema: jobj([
      ("type", js("object")),
      (
        "properties",
        jobj([
          (
            "name",
            jobj([("type", js("string")), ("enum", jstrs(rest.map(t => t.name)))]),
          ),
          (
            "arguments",
            jobj([
              ("type", js("object")),
              ("description", js("The tool's arguments, as its parameters say.")),
            ]),
          ),
        ]),
      ),
      ("required", jstrs(["name"])),
    ]),
    run: (_, _, _) => raise Failed("station_tool is run by the endpoint"),
    content: None,
  }
}

///|
/// `/^.*?[.:](?=\s|$)/s`'s match (or the whole), its spaces squeezed, its first 160 units.
fn first_sentence(text : String) -> String {
  let n = text.length()
  let mut end = n
  for i in 0..<n {
    let c = text.unsafe_charcode_at(i)
    if (c == '.' || c == ':') &&
      (i + 1 == n || is_js_space(text.unsafe_charcode_at(i + 1))) {
      end = i + 1
      break
    }
  }
  slice(squeeze_spaces(slice(text, 0, to=end)), 0, to=160)
}

///|
/// The arguments as the tool's schema types them now (mcp.ts `typed`): a boolean or number parameter given as its text
/// is read as the value it says.
pub fn typed(args : JV, schema : JV) -> JV {
  let properties = match schema {
    Obj(_) => schema.get("properties")
    _ => None
  }
  match properties {
    None | Some(Null) => return args
    _ => ()
  }
  let props = properties.unwrap()
  let mut out : JV? = None
  for f in jfields(Some(args)) {
    guard f.1 is Str(value) else { continue }
    let ty = match props {
      Obj(_) =>
        match props.get(f.0) {
          Some(Obj(_) as p) => p.get("type")
          _ => None
        }
      _ => None
    }
    let t = trim_js(value)
    let read : JV? = match ty {
      Some(Str("boolean")) =>
        if t == "true" {
          Some(Bool(true))
        } else if t == "false" {
          Some(Bool(false))
        } else {
          None
        }
      Some(Str("number")) | Some(Str("integer")) =>
        if is_decimal(t) {
          Some(Num(@api_routes.js_number(t)))
        } else {
          None
        }
      _ => None
    }
    match read {
      None => continue
      Some(r) => out = Some(@api_routes.jset(out.unwrap_or(args), f.0, r))
    }
  }
  out.unwrap_or(args)
}

///|
/// `/^-?\d+(\.\d+)?$/`.
fn is_decimal(t : String) -> Bool {
  let n = t.length()
  let mut i = 0
  if i < n && t.unsafe_charcode_at(i) == '-' {
    i += 1
  }
  let digits = (from : Int) => {
    let mut j = from
    while j < n &&
          t.unsafe_charcode_at(j) >= '0' &&
          t.unsafe_charcode_at(j) <= '9' {
      j += 1
    }
    j
  }
  let a = digits(i)
  if a == i {
    return false
  }
  if a == n {
    return true
  }
  if t.unsafe_charcode_at(a) != '.' {
    return false
  }
  let b = digits(a + 1)
  b > a + 1 && b == n
}

///|
/// What a session's runtime needs of its list of tools (mcp.ts `Listing`).
pub(all) struct Listing {
  budget : Int?
  loaded : JV?
}

///|
/// A reply: its status and body (none: an empty one).
pub(all) struct Reply {
  status : Int
  body : JV?
}

///|
/// The endpoint: its tools, and what it asks the station (a token's session: `mcp.resolve`; why the outward tools are
/// refused now: `mcp.gate`; a session's runtime's listing: `mcp.listing`).
pub struct McpEndpoint {
  tools : () -> Array[Tool]
  backend : ToolsBackend
}

///|
pub fn McpEndpoint::new(
  backend : ToolsBackend,
  tools : () -> Array[Tool],
) -> McpEndpoint {
  { tools, backend }
}

///|
async fn McpEndpoint::listing(self : McpEndpoint, session : String) -> Listing {
  let said = self.backend.ask("mcp.listing", [js(session)])
  match said {
    Obj(_) =>
      {
        budget: match said.get("budget") {
          Some(Num(n)) => Some(n.to_int())
          _ => None
        },
        loaded: match said.get("loaded") {
          Some(v) if !is_undef(v) => Some(v)
          _ => None
        },
      }
    _ => { budget: None, loaded: None }
  }
}

///|
/// The tools a session is declared (mcp.ts `listed`).
async fn McpEndpoint::listed(self : McpEndpoint, session : String) -> Array[JV] {
  let visible = (self.tools)().filter(t => !hidden.contains(t.name))
  let { budget, loaded } = self.listing(session)
  let say = (t : Tool) => match loaded {
    Some(meta) if every_turn.contains(t.name) =>
      @api_routes.jset(declared(t), "_meta", meta)
    _ => declared(t)
  }
  match budget {
    None => visible.map(say)
    Some(b) => {
      let mut marks = 0
      for t in visible {
        marks += byte_length(stringify(say(t))) - weight(t)
      }
      let (fit, rest) = fitted(visible, b - marks)
      let listed = if rest.length() == 0 {
        fit
      } else {
        [..fit, indirect_tool(rest)]
      }
      listed.map(say)
    }
  }
}

///|
fn McpEndpoint::find(self : McpEndpoint, name : String) -> Tool? {
  (self.tools)().iter().find_first(t => t.name == name)
}

///|
fn text_result(text : String, error? : Bool = false) -> JV {
  let content = jarr([Content::Text(text).to_jv()])
  if error {
    jobj([("content", content), ("isError", jbool(true))])
  } else {
    jobj([("content", content)])
  }
}

///|
/// One request: `authorization` its header (None: absent), `signal` whether the call has an abort signal and whether
/// it was aborted by the time it failed.
pub async fn McpEndpoint::handle(
  self : McpEndpoint,
  method : String,
  authorization : String?,
  body : Bytes,
  signal? : @api_routes.Signal,
) -> Reply {
  if method != "POST" {
    return { status: 405, body: None }
  }
  let token = trim_js(strip_bearer(authorization.unwrap_or("")))
  let session = if token == "" {
    None
  } else {
    match self.backend.ask("mcp.resolve", [js(token)]) {
      Str(s) if s != "" => Some(s)
      _ => None
    }
  }
  guard session is Some(session) else {
    return {
      status: 401,
      body: Some(jobj([("error", js("unknown session token"))])),
    }
  }
  let message = match try_parse(utf8_text(body)) {
    Some(m) => m
    None =>
      return {
        status: 400,
        body: Some(
          jobj([
            ("jsonrpc", js("2.0")),
            ("id", Null),
            (
              "error",
              jobj([("code", jint(-32700)), ("message", js("parse error"))]),
            ),
          ]),
        ),
      }
  }
  guard message is Obj(_) && message.get("id") is Some(id) else {
    return { status: 202, body: None }
  }
  let params : JV = match message.get("params") {
    None | Some(Null) => Null
    Some(p) => p
  }
  let reply = (rest : Array[(String, JV)]) => Reply::{
    status: 200,
    body: Some(jobj([("jsonrpc", js("2.0")), ("id", id), ..rest])),
  }
  let jsig = if signal is Some(_) { jsignal } else { jundef }
  let m = match message.get("method") {
    Some(Str(s)) => s
    _ => ""
  }
  match m {
    "initialize" =>
      reply([
        (
          "result",
          jobj([
            (
              "protocolVersion",
              match jget(Some(params), "protocolVersion") {
                Some(Str(v)) => js(v)
                _ => js("2025-06-18")
              },
            ),
            ("capabilities", jobj([("tools", jobj([]))])),
            (
              "serverInfo",
              jobj([("name", js("still.fail")), ("version", js("0.0.0"))]),
            ),
          ]),
        ),
      ])
    "ping" => reply([("result", jobj([]))])
    "tools/list" =>
      reply([("result", jobj([("tools", jarr(self.listed(session)))]))])
    "tools/call" => {
      let mut name = match jget(Some(params), "name") {
        Some(Str(s)) => s
        _ => ""
      }
      let mut given = match jget(Some(params), "arguments") {
        Some(Obj(_) as a) => a
        _ => jobj([])
      }
      // One left undeclared, called through `indirect`: its description and parameters, or its run as any call's.
      if name == indirect && self.find(indirect) is None {
        let named = match given.get("name") {
          Some(Str(n)) => self.find(n)
          _ => None
        }
        guard named is Some(named) else {
          return reply([
            (
              "result",
              text_result(
                "No station tool \{stringify_opt_js(given.get("name"))}: name one listed in station_tool's description.",
                error=true,
              ),
            ),
          ])
        }
        match given.get("arguments") {
          None | Some(Null) =>
            return reply([
              ("result", text_result(stringify(declared(named)))),
            ])
          Some(Obj(_) as a) => {
            name = named.name
            given = a
          }
          Some(x) if is_undef(x) =>
            return reply([
              ("result", text_result(stringify(declared(named)))),
            ])
          _ =>
            return reply([
              ("result", text_result("arguments must be an object.", error=true)),
            ])
        }
      }
      guard self.find(name) is Some(tool) else {
        return reply([
          (
            "error",
            jobj([
              ("code", jint(-32602)),
              ("message", js("unknown tool \{name}")),
            ]),
          ),
        ])
      }
      if outward.contains(name) {
        match self.backend.ask("mcp.gate", [js(session)]) {
          Str(why) => {
            self.backend.log(
              "warn",
              "mcp",
              "outward tool refused: the station is in no workspace",
              jobj([("session", js(session)), ("tool", js(name))]),
            )
            return reply([("result", text_result(why, error=true))])
          }
          _ => ()
        }
      }
      let args = typed(given, tool.input_schema)
      try {
        match tool.content {
          Some(content) => {
            let r = content(session, args)
            let fields = [("content", jarr(r.content.map(c => c.to_jv())))]
            if r.is_error {
              fields.push(("isError", jbool(true)))
            }
            reply([("result", jobj(fields))])
          }
          None => reply([("result", text_result((tool.run)(session, args, jsig)))])
        }
      } catch {
        error => {
          let aborted = match signal {
            Some(s) => s.aborted
            None => false
          }
          if !aborted {
            self.backend.log(
              "warn",
              "mcp",
              "tool call failed",
              jobj([
                ("session", js(session)),
                ("tool", js(name)),
                ("error", js(message_of(error))),
              ]),
            )
          }
          reply([("result", text_result(message_of(error), error=true))])
        }
      }
    }
    _ =>
      reply([
        (
          "error",
          jobj([
            ("code", jint(-32601)),
            (
              "message",
              js("method not found: \{js_string(message.get("method"))}"),
            ),
          ]),
        ),
      ])
  }
}

///|
/// `authorization.replace(/^(Bearer |bearer )/, "")`.
fn strip_bearer(a : String) -> String {
  if a.has_prefix("Bearer ") || a.has_prefix("bearer ") {
    slice(a, 7)
  } else {
    a
  }
}

///|
/// `JSON.stringify(v)` where v may be undefined (as a template literal writes its result: "undefined").
fn stringify_opt_js(v : JV?) -> String {
  match v {
    None => "undefined"
    Some(x) if is_undef(x) => "undefined"
    Some(x) => stringify(x)
  }
}
