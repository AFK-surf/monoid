// acp.ts: the Agent Client Protocol as the station speaks it to the runtimes that serve it (Grok Build, Devin, Hermes
// Agent, and Antigravity CLI), one ACP session in a process of its own: `AcpSession` with each runtime's ways
// (devin.ts `DevinSession`, grok.ts `GrokSession`, hermes.ts `HermesSession`, by its `flavor`), and `KeptTranscript`,
// the transcript the station keeps of a runtime whose own it cannot read (Devin's, Hermes'). What the updates and a
// prompt's answer do to the turn and its live steps is the program's (station/mb src/acp).

///|
/// acp.ts's request ids: `INIT`, `OPEN`, `PROMPT`, `STEER`.
pub let acp_init : String = "init"

///|
pub let acp_open : String = "open"

///|
pub let acp_prompt : String = "prompt:"

///|
pub let acp_steer : String = "steer:"

///|
/// `rpc`: a JSON-RPC request's line.
pub fn rpc(id : String, method : String, params : J) -> String {
  stringify(obj([("jsonrpc", js("2.0")), ("id", js(id)), ("method", js(method)), ("params", params)]))
}

///|
/// `mcpServers`: the station's tools as ACP gives an MCP server.
pub fn mcp_servers(url : String, token : String) -> J {
  Arr([
    obj([
      ("type", js("http")),
      ("name", js("stillfail")),
      ("url", js(url)),
      ("headers", Arr([obj([("name", js("Authorization")), ("value", js("Bearer \{token}"))])])),
    ]),
  ])
}

///|
/// `errorText`: what an error answer says, its message and its data's.
pub fn error_text(error : J) -> String {
  let e = Some(error)
  let text = match get(e, "message") {
    Some(Str(m)) => {
      let s = t(m)
      if s.has_prefix("Internal error: ") {
        sub(s, 16)
      } else {
        s
      }
    }
    _ => stringify(error)
  }
  let data = match get(e, "data") {
    Some(Str(d)) => ": \{t(d)}"
    d =>
      match (get(d, "message"), get(d, "details")) {
        (Some(Str(m)), _) => ": \{t(m)}"
        (_, Some(Str(m))) => ": \{t(m)}"
        _ => ""
      }
  }
  "\{text}\{data}"
}

///|
/// How a prompt's answer ends the turn (`acpOutcome` with each one's `classifyFailure`: devin.ts, hermes.ts, grok.ts
/// `outcomeOf`), as the program reads it (src/acp `acp_outcome`).
pub fn acp_outcome_of(flavor : String, answer : J) -> J {
  @acp.acp_outcome(flavor, Some(answer))
}

///|
/// `KeptTranscript`: <dir>/<session id>.jsonl, a line for each thing said and done; each line kept is said in the
/// trace (`keep`: the session and the line as written).
pub struct Kept {
  own : Own
  mut quiet : Bool
}

///|
pub fn Kept::keep(self : Kept, id : String, line : J?) -> Unit {
  if id == "" || self.quiet {
    return
  }
  let f = Fields::of([("time", num(self.own.now))])
  f.spread(spread_of(line))
  self.own.note("keep", Arr([js(id), js("\{stringify(f.json())}\n")]))
  self.own.writing = true
}

///|
/// `ended`: a turn's end as the transcript keeps it.
pub fn Kept::ended(self : Kept, id : String, outcome : J) -> Unit {
  let o = Some(outcome)
  let status = if is_s(get(o, "kind"), "completed") {
    "finished"
  } else if is_s(get(o, "kind"), "aborted") {
    "cancelled"
  } else {
    "error"
  }
  let f = Fields::of([("type", js("end")), ("status", js(status))])
  if is_s(get(o, "kind"), "failed") {
    f.set("error", obj([("message", get(o, "message").unwrap_or(Null))]))
  }
  self.keep(id, Some(f.json()))
}

///|
/// `TAIL`: how much of a kept transcript's end is read for its running turn.
pub let kept_tail : Int = 1 << 20

///|
/// `lastOfTurn` of what its file's last TAIL bytes say (`cut`: they are not the whole file, so the first line is a
/// part of one): the last line of `type` since its last turn's end, none where an end comes first.
pub fn last_of_turn(text : String, cut : Bool, type_ : String) -> J? {
  let lines = text.split("\n").map(l => l.to_owned()).collect()
  if cut && lines.length() > 0 {
    lines.remove(0) |> ignore
  }
  for i = lines.length() - 1; i >= 0; i = i - 1 {
    guard parse(lines[i]) is Some(line) else { continue }
    let ty = get(Some(line), "type")
    if is_s(ty, "end") {
      return None
    }
    if is_s(ty, type_) {
      return Some(line)
    }
  }
  None
}

///|
/// `lastOfTurn` read off the station's thread: <dir>/<id>.jsonl's last TAIL bytes as Buffer.toString reads them.
pub async fn last_of_turn_in(host : @host.Host, dir : String, id : String, type_ : String) -> J? {
  if id == "" {
    return None
  }
  let path = join([dir, "\{id}.jsonl"])
  let size = match ask_or_null(host, "fs.meta", { "path": Json::string(path) }) {
    { "size": Number(s, ..), .. } => s.to_int()
    _ => return None
  }
  let from = if size > kept_tail { size - kept_tail } else { 0 }
  match ask_or_null(host, "fs.from", { "path": Json::string(path), "from": Json::number(from.to_double()) }) {
    String(text) => last_of_turn(text, from > 0, type_)
    _ => None
  }
}

///|
/// Devin's running turn's calls (devin.ts `TurnUsage`).
pub(all) struct DevinUsage {
  run : String
  mut calls : Int
  mut last_call : String
  mut context : Double
  mut window : Double
}

///|
fn DevinUsage::json(self : DevinUsage) -> J {
  obj([
    ("run", js(self.run)),
    ("calls", int(self.calls)),
    ("lastCall", js(self.last_call)),
    ("context", num(self.context)),
    ("window", num(self.window)),
  ])
}

///|
/// An ACP session (`flavor`: "devin", "grok", "hermes", "agy").
pub struct Acp {
  own : Own
  flavor : String
  mut model : String?
  transcript : Kept?
  mut opened : Bool
  mut resumed : Bool
  mut pending_prompt : String?
  mut resend_from : String?
  // Devin's: the `model` config option's values, its running turn's calls.
  mut families : Array[J]
  mut usage : DevinUsage?
  // Grok Build's: what each model's context holds, and the turns' usage lines to keep beside its transcript.
  windows : Fields
  // Hermes': its instructions (given with each prompt), its profile, the Hermes home its new session is of, the models it offers.
  instructions : String
  profile : J
  new_home : String
  mut available_models : Array[String]
}

///|
/// A session of an ACP runtime, not open yet (`AcpDriver.session`). `model` what it is opened with (the options' or
/// the profile's), `new_home` Hermes' home for a session it begins (hermes.ts `newSessionHome`).
pub fn Acp::new(
  flavor : String,
  model : String?,
  instructions? : String = "",
  profile? : J = Null,
  new_home? : String = "",
  runner? : String = "",
) -> Acp {
  let turn = Fields::of([("busy", Bool(false)), ("aborting", Bool(false)), ("owner", Null), ("steering", Arr([]))])
  let own = Own::new(flavor, "", turn, Null, runner)
  let keeps = flavor == "devin" || flavor == "hermes"
  {
    own,
    flavor,
    model: if flavor == "devin" {
      match model {
        Some(m) => Some(devin_fusion_base(m).0)
        None => None
      }
    } else {
      model
    },
    transcript: if keeps { Some({ own, quiet: false }) } else { None },
    opened: false,
    resumed: false,
    pending_prompt: None,
    resend_from: None,
    families: [],
    usage: None,
    windows: Fields::new(),
    instructions,
    profile,
    new_home,
    available_models: [],
  }
}

///|
fn Acp::keep(self : Acp, line : J) -> Unit {
  if self.transcript is Some(k) {
    k.keep(self.own.session_id, Some(line))
  }
}

///|
pub fn Acp::busy(self : Acp) -> Bool {
  self.own.turn_flag("busy")
}

///|
/// `opened`: session/new's or session/load's answer (`result`) says what it runs on besides.
pub fn Acp::open(self : Acp, result : J?, resumed? : Bool = false) -> Unit {
  self.opened = true
  self.resumed = resumed
  if resumed {
    self.own.say("acpOpened", args=obj([("resumed", Bool(true))]))
  } else {
    self.own.say("acpOpened")
  }
  match self.flavor {
    "devin" => {
      let model = arr(get(result, "configOptions")).search_by(o => is_s(get(Some(o), "id"), "model"))
      guard model is Some(at) else { return }
      let option = Some(arr(get(result, "configOptions"))[at])
      if get(option, "options") is Some(Arr(options)) {
        self.families = options.filter_map(o => match get(Some(o), "value") {
          Some(Str(_) as v) => Some(v)
          _ => None
        })
      }
      match get(option, "currentValue") {
        Some(Str(v)) if v.length() > 0 && self.model is None => self.model = Some(t(v))
        _ => ()
      }
    }
    "grok" => {
      let models = get(result, "models")
      if get(models, "currentModelId") is Some(Str(id)) {
        self.model = Some(t(id))
      }
      for m in arr(get(models, "availableModels")) {
        let size = get(get(Some(m), "_meta"), "totalContextTokens")
        match (get(Some(m), "modelId"), size) {
          (Some(Str(id)), Some(Num(_) as n)) => self.windows.set(t(id), n)
          _ => ()
        }
      }
    }
    "hermes" => self.available_models = hermes_catalog(get(result, "models"), self.profile)
    _ => ()
  }
}

///|
/// `attached`: the program started again reads it from what it was told last.
pub fn Acp::attached(self : Acp) -> Unit {
  if self.own.session_id != "" {
    self.own.say("acpSession", args=obj([("id", js(self.own.session_id))]))
  }
  if self.opened {
    if self.resumed {
      self.own.say("acpOpened", args=obj([("resumed", Bool(true))]))
    } else {
      self.own.say("acpOpened")
    }
  }
}

///|
/// `named`: the session it is (Hermes' refused where it is no id of Hermes').
pub fn Acp::named(self : Acp, id : String) -> String? {
  if self.flavor == "hermes" && !hermes_session_id(id) {
    return Some("invalid Hermes session id")
  }
  self.own.session_id = id
  self.own.say("acpSession", args=obj([("id", js(id))]))
  None
}

///|
/// `began`: a session made new, its transcript says so first.
pub fn Acp::began(self : Acp, cwd : String) -> Unit {
  let f = Fields::of([("type", js("session")), ("id", js(self.own.session_id)), ("cwd", js(cwd))])
  if self.flavor == "hermes" {
    f.set_str("hermesHome", self.new_home)
  }
  self.keep(f.json())
}

///|
/// `request`: a request whose answer is waited for (an error answer fails it), said in the trace as `label`.
pub fn Acp::request(
  self : Acp,
  id : String,
  method : String,
  params : J,
  label : String,
  then? : (Result[J, String]) -> Result[J, String] = r => r,
) -> Unit {
  let own = self.own
  let kind = self.flavor
  own.wait(
    id,
    m => match get(Some(m), "error") {
      None => None
      Some(e) => Some("\{kind} \{method}: \{error_text(e)}")
    },
    outcome => own.resolved(label, then(outcome)),
  )
  own.write(rpc(id, method, params))
}

///|
/// `send`: a request whose answer is not waited for.
fn Acp::send(self : Acp, method : String, params : J) -> Unit {
  self.own.write(rpc("\{method}:\{self.own.uuid()}", method, params))
}

///|
/// `heard`: a request of the runtime's (a permission granted for its call; anything else refused: it is asked in the
/// chat), or the answer to one of ours.
pub fn Acp::heard(self : Acp, line : String) -> Unit {
  guard parse(line) is Some(message) else { return }
  let m = Some(message)
  let id = get(m, "id")
  let method = get(m, "method")
  if is_s(method, "session/request_permission") && id is Some(i) {
    let offered = arr(get(get(m, "params"), "options"))
    let result = match offered.search_by(o => is_s(get(Some(o), "kind"), "allow_once")) {
      Some(at) => {
        let picked = Fields::of([("outcome", js("selected"))])
        if get(Some(offered[at]), "optionId") is Some(oid) {
          picked.set("optionId", oid)
        }
        obj([("outcome", picked.json())])
      }
      None => obj([("outcome", obj([("outcome", js("cancelled"))]))])
    }
    self.own.write(stringify(obj([("jsonrpc", js("2.0")), ("id", i), ("result", result)])))
    return
  }
  if method is Some(name) {
    if id is Some(i) {
      self.own.write(
        stringify(
          obj([
            ("jsonrpc", js("2.0")),
            ("id", i),
            ("error", obj([("code", int(-32601)), ("message", js("\{said(Some(name))} is not supported"))])),
          ]),
        ),
      )
    }
    return
  }
  self.own.answer(id, message) |> ignore
}

///|
/// `took`: what the program says of the session for this alone (the transcript's lines, its usage, a prompt's answer).
fn Acp::took(self : Acp, e : J) -> Bool {
  let x = Some(e)
  let ty = get(x, "type")
  if is_s(ty, "kept") {
    if self.transcript is Some(k) {
      k.keep(self.own.session_id, get(x, "line"))
    }
    return true
  }
  if is_s(ty, "usage") {
    let owner = match get(x, "owner") {
      Some(Str(o)) => Some(t(o))
      _ => None
    }
    self.updated(get(x, "update"), owner)
    return true
  }
  if is_s(ty, "answered") {
    if get(x, "outcome") is Some(_) {
      self.resumed = false
      self.pending_prompt = None
      self.ending(said(get(x, "id")), get(x, "answer"))
    }
    return true
  }
  if is_s(ty, "loadReplay") {
    self.resumed = false
    self.resend_from = Some(said(get(x, "id")))
    return true
  }
  false
}

///|
fn Acp::resend_prompt(self : Acp, _prev_id : String) -> Unit {
  let text = self.pending_prompt
  self.pending_prompt = None
  guard text is Some(t) else { return }
  if self.own.closed || !self.busy() || self.own.turn_flag("aborting") {
    return
  }
  let owner = "\{acp_prompt}\{self.own.uuid()}"
  self.own.turn.set_str("owner", owner)
  self.own.say("acpPrompt", args=obj([("owner", js(owner)), ("resend", Bool(true))]))
  self.own.write(rpc(owner, "session/prompt", self.prompt_params(t)))
}

///|
/// `heardHosted`.
pub fn Acp::heard_hosted(self : Acp, heard : J?) -> Unit {
  for line in arr(get(heard, "lines")) {
    self.heard(said(get(Some(line), "text")))
  }
  self.own.told(heard, e => self.took(e))
  if self.resend_from is Some(prev) {
    self.resend_from = None
    self.resend_prompt(prev)
  }
}

///|
/// `updated`: an update of the session's usage (Devin's each call's counts, said twice: counted once, kept as it
/// comes).
fn Acp::updated(self : Acp, update : J?, owner : String?) -> Unit {
  if self.flavor != "devin" || !is_s(get(update, "sessionUpdate"), "usage_update") {
    return
  }
  let counts = devin_call_of(update)
  let said_now = stringify(counts)
  let run = match owner {
    Some(o) => sub(o, index_of(o, ":") + 1)
    None => self.own.uuid()
  }
  let u = match self.usage {
    Some(u) => u
    None => {
      let fresh = { run, calls: 0, last_call: "", context: 0.0, window: 0.0 }
      self.usage = Some(fresh)
      fresh
    }
  }
  if said_now == u.last_call {
    return
  }
  u.last_call = said_now
  u.calls += 1
  let used = finite_or_zero(get(update, "used"))
  if used > 0.0 {
    u.context = used
  }
  let size = finite_or_zero(get(update, "size"))
  if size > 0.0 {
    u.window = size
  }
  self.keep(
    obj([
      ("type", js("usage")),
      ("run", js(if u.calls == 1 { u.run } else { "\{u.run}:\{u.calls}" })),
      ("model", self.model_json()),
      ("usage", counts),
      ("calls", int(1)),
      ("context", num(u.context)),
      ("window", num(u.window)),
    ]),
  )
}

///|
fn Acp::model_json(self : Acp) -> J {
  match self.model {
    Some(m) => js(m)
    None => Null
  }
}

///|
/// `ending`: the turn ends as `answer` says (Devin's turn's calls let go; Grok Build's usage kept beside its
/// transcript, said in the trace as `grokUsage`: the session and the line).
fn Acp::ending(self : Acp, _id : String, answer : J?) -> Unit {
  match self.flavor {
    "devin" => self.usage = None
    "grok" => {
      let model = match get(get(get(answer, "result"), "_meta"), "modelId") {
        Some(Str(m)) => Some(t(m))
        _ => self.model
      }
      let window = match model {
        Some(m) => self.windows.get(m)
        None => None
      }
      match grok_usage_line(answer, self.own.now, window.unwrap_or(Null)) {
        Some(line) => {
          self.own.note("grokUsage", Arr([js(self.own.session_id), js(line)]))
          self.own.writing = true
        }
        None => ()
      }
    }
    _ => ()
  }
}

///|
/// `promptText`: what a message of the person's is given to it as (Hermes': the station's instructions before it).
fn Acp::prompt_text(self : Acp, text : String) -> String {
  if self.flavor == "hermes" && self.instructions != "" {
    "<stillfail-context>\n\{self.instructions}\n\nYour Hermes persona and communication preferences from SOUL.md and memories apply to the text you send with chat_post, including progress updates. Use the configured form of address and tone in those tool arguments: they are the messages people read; ordinary assistant output stays internal.\n</stillfail-context>\n\n\{text}"
  } else {
    text
  }
}

///|
fn Acp::prompt_params(self : Acp, text : String) -> J {
  obj([("sessionId", js(self.own.session_id)), ("prompt", Arr([obj([("type", js("text")), ("text", js(self.prompt_text(text)))])]))])
}

///|
/// `prompt`.
pub fn Acp::prompt(self : Acp, text : String) -> String? {
  if self.own.startable(self.busy()) is Some(why) {
    return Some(why)
  }
  let owner = "\{acp_prompt}\{self.own.uuid()}"
  self.pending_prompt = Some(text)
  self.own.set_flag("busy", true)
  self.own.turn.set_str("owner", owner)
  let args = Fields::of([("owner", js(owner))])
  if self.transcript is Some(_) {
    args.set_str("text", text)
  }
  self.own.say("acpPrompt", args=args.json())
  self.own.write(rpc(owner, "session/prompt", self.prompt_params(text)))
  None
}

///|
/// `injectPrompt`: into the running turn as a prompt of its own (`take_over`: taking the turn from the prompt it is).
fn Acp::inject(self : Acp, text : String, take_over : Bool) -> Bool {
  if self.own.closed || !self.busy() || self.own.turn_flag("aborting") {
    return false
  }
  let id = "\{acp_steer}\{self.own.uuid()}"
  let steering : Array[String] = []
  for s in arr(self.own.turn.get("steering")) {
    let x = said(Some(s))
    if !steering.contains(x) {
      steering.push(x)
    }
  }
  if take_over {
    match self.own.turn.get("owner") {
      None | Some(Null) => ()
      o => {
        let x = said(o)
        if !steering.contains(x) {
          steering.push(x)
        }
      }
    }
    self.own.turn.set_str("owner", id)
  } else if !steering.contains(id) {
    steering.push(id)
  }
  self.own.turn.set("steering", arr_of(steering))
  let args = Fields::of([("id", js(id)), ("takeOver", Bool(take_over))])
  if self.transcript is Some(_) {
    args.set_str("text", text)
  }
  self.own.say("acpInject", args=args.json())
  self.own.write(rpc(id, "session/prompt", self.prompt_params(text)))
  true
}

///|
/// `promptTakeover`.
pub fn Acp::prompt_takeover(self : Acp, text : String) -> Bool {
  self.inject(text, true)
}

///|
/// `steer`: Devin's into the running turn as a prompt read at its next step; Grok Build's by `_x.ai/interject` (none
/// while its answer is awaited); the others' not (the station gives it as the next turn's).
pub fn Acp::steer(self : Acp, text : String) -> Bool? {
  match self.flavor {
    "devin" => Some(self.inject(text, false))
    "grok" => {
      if self.own.closed || !self.busy() || self.own.turn_flag("aborting") {
        return Some(false)
      }
      self.request(
        "\{acp_steer}\{self.own.uuid()}",
        "_x.ai/interject",
        obj([("sessionId", js(self.own.session_id)), ("text", js(text))]),
        "steer",
        then=outcome => match outcome {
          Ok(answer) => {
            let result = get(Some(answer), "result")
            Ok(Bool(is_s(get(result, "status"), "queued") || result is Some(_)))
          }
          Err(_) => Ok(Bool(false))
        },
      )
      None
    }
    _ => Some(false)
  }
}

///|
/// `abort`: session/cancel; its end comes as aborted.
pub fn Acp::abort(self : Acp) -> Unit {
  if self.own.closed || !self.busy() || self.own.turn_flag("aborting") {
    return
  }
  self.own.set_flag("aborting", true)
  self.own.tell("aborting")
  self.own.write(
    stringify(obj([("jsonrpc", js("2.0")), ("method", js("session/cancel")), ("params", obj([("sessionId", js(self.own.session_id))]))])),
  )
}

///|
/// `cutShort`: its process went away during a turn; its end in the transcript.
fn Acp::cut_short(self : Acp, said_ : String) -> Unit {
  self.pending_prompt = None
  if self.flavor == "devin" {
    self.usage = None
  }
  if self.transcript is Some(k) {
    k.ended(
      self.own.session_id,
      obj([("kind", js("failed")), ("reason", js("exited")), ("message", js("\{self.flavor} exited (\{said_})"))]),
    )
  }
}

///|
/// `exited`.
pub fn Acp::exited(self : Acp, said_ : String, stderr : String) -> Unit {
  let busy = self.busy()
  self.own.exited(said_, stderr, busy, () => self.own.set_flag("busy", false), s => self.cut_short(s))
}

///|
/// `retune` between turns: Devin's model family and thinking level, Grok Build's model and effort, set in the running
/// process (`model` the options' or the profile's, `effort` the options').
pub fn Acp::retune(self : Acp, model : String?, effort : String?) -> Bool {
  if self.own.closed || self.busy() || self.own.session_id == "" {
    return false
  }
  let sid = js(self.own.session_id)
  let set = (config : String, value : String) => self.send(
    "session/set_config_option",
    obj([("sessionId", sid), ("configId", js(config)), ("value", js(value))]),
  )
  match self.flavor {
    "devin" => {
      guard model is Some(raw) else { return false }
      let split = split_devin_fusion(raw)
      let m = match split {
        Some(s) => "fusion-\{s.lead}-sidekick-\{s.side}"
        None => raw
      }
      let family = match split {
        Some(s) =>
          self.families.search_by(f => {
            let v = said(Some(f))
            f is Str(_) &&
            (v == raw || v == m || devin_levels.iter().any(l => v == "fusion-\{s.lead}-\{l}-sidekick-\{s.side}"))
          })
        None =>
          self.families.search_by(f => {
            let v = said(Some(f))
            f is Str(_) && (v == m || devin_levels.iter().any(l => v == "\{m}-\{l}"))
          })
      }
      guard family is Some(at) else { return false }
      set("model", said(Some(self.families[at])))
      let level = match effort {
        Some(e) => Some(e)
        None =>
          match split {
            Some(s) => s.effort
            None => None
          }
      }
      if level is Some(l) && devin_levels.contains(l) {
        set("thought_level", l)
      }
      self.model = Some(m)
      true
    }
    "grok" => {
      let e = grok_effort(effort)
      if model is None && e is None {
        return false
      }
      if model is Some(m) {
        set("model", m)
        self.model = Some(m)
      }
      if e is Some(level) {
        set("reasoning_effort", level)
      }
      true
    }
    _ => false
  }
}

///|
/// `snapshot`: what a next station takes it up from.
pub fn Acp::snapshot(self : Acp) -> J {
  let frozen = self.own.hand_over()
  let turn = match present(get(frozen, "turn")) {
    Some(tn) => Some(tn)
    None => Some(self.own.turn_now())
  }
  let state = match present(get(frozen, "live")) {
    Some(l) => Some(l)
    None =>
      match self.own.live_state {
        Null => Some(obj([]))
        l => Some(l)
      }
  }
  let or = (v : J?, d : J) => match present(v) {
    Some(x) => x
    None => d
  }
  let f = Fields::of([
    ("runtime", js(self.flavor)),
    ("id", js(self.own.session_id)),
    ("runner", js(self.own.runner)),
    ("turn", obj([("busy", strictly(turn, "busy")), ("aborting", strictly(turn, "aborting"))])),
    ("tools", tools_json(self.own.tools_url)),
    (
      "live",
      or(get(state, "live"), obj([("open", Arr([])), ("said", Null), ("n", int(0)), ("phase", Null)])),
    ),
    ("model", self.model_json()),
    ("owner", or(get(turn, "owner"), Null)),
    ("steering", or(get(turn, "steering"), Arr([]))),
    ("said", or(get(state, "said"), Null)),
    ("calls", or(get(state, "calls"), Arr([]))),
    ("saidLast", or(get(state, "saidLast"), js(""))),
    ("children", or(get(state, "children"), Arr([]))),
  ])
  if self.own.tools_absent {
    f.delete("tools")
  }
  if self.flavor == "devin" {
    f.set("families", Arr(self.families))
    f.set(
      "usage",
      match self.usage {
        Some(u) => u.json()
        None => Null
      },
    )
  }
  f.json()
}

///|
/// `handed`: what the station that handed it over knew of it.
pub fn Acp::handed(self : Acp, snapshot : J, runner : String) -> Acp {
  let s = Some(snapshot)
  let or = (v : J?, d : J) => match present(v) {
    Some(x) => x
    None => d
  }
  let own = Own::new(
    self.flavor,
    said(get(s, "id")),
    Fields::of([
      ("busy", get(get(s, "turn"), "busy").unwrap_or(Null)),
      ("aborting", get(get(s, "turn"), "aborting").unwrap_or(Null)),
      ("owner", or(get(s, "owner"), Null)),
      ("steering", or(get(s, "steering"), Arr([]))),
    ]),
    obj([
      ("live", get(s, "live").unwrap_or(Null)),
      ("said", or(get(s, "said"), Null)),
      ("calls", or(get(s, "calls"), Arr([]))),
      ("saidLast", or(get(s, "saidLast"), js(""))),
      ("children", or(get(s, "children"), Arr([]))),
      ("loading", Bool(false)),
      ("session", get(s, "id").unwrap_or(Null)),
    ]),
    runner,
  )
  own.uuids.push_iter(self.own.uuids.iter())
  own.now = self.own.now
  own.tools_url = str_of(get(s, "tools"))
  own.tools_absent = get(s, "tools") is None
  let taken : Acp = {
    ..self,
    own,
    model: match present(get(s, "model")) {
      Some(Str(m)) => Some(t(m))
      _ => self.model
    },
    transcript: match self.transcript {
      Some(_) => Some({ own, quiet: false })
      None => None
    },
    opened: true,
  }
  if self.flavor == "devin" {
    taken.families = arr(get(s, "families"))
    let u = get(s, "usage")
    taken.usage = match (get(u, "run"), get(u, "calls")) {
      (Some(Str(run)), Some(Num(calls))) if is_object(u) =>
        Some({
          run: t(run),
          calls: calls.to_int(),
          last_call: str_of(get(u, "lastCall")).unwrap_or(""),
          context: num_of(get(u, "context")).unwrap_or(0.0),
          window: num_of(get(u, "window")).unwrap_or(0.0),
        })
      _ => None
    }
  }
  taken
}

///|
/// `replayed`: what the program read again of what the station before had handled of its output when it crashed; what
/// it was opened with and the running turn's usage read again here as if heard now, nothing of it written again.
/// `last_usage` Devin's transcript's last usage of the running turn (`lastOfTurn`), read before.
pub fn Acp::replayed(self : Acp, replayed : J, resume : String?, mcp_url : String, last_usage? : J? = None) -> Unit {
  let r = Some(replayed)
  self.own.session_id = match get(r, "session") {
    Some(Str(s)) if s.length() > 0 => t(s)
    _ => resume.unwrap_or("")
  }
  self.own.turn = Fields::of([
    ("busy", Bool(get(get(r, "turn"), "busy") is Some(Bool(true)))),
    ("aborting", Bool(false)),
    ("owner", Null),
    ("steering", Arr([])),
  ])
  self.own.live_state = match present(get(r, "live")) {
    Some(l) => l
    None => Null
  }
  self.opened = true
  let configured = self.model
  if present(get(r, "opened")) is Some(o) {
    self.open(Some(o))
  }
  if configured is Some(_) {
    self.model = configured
  }
  match self.transcript {
    Some(k) => k.quiet = true
    None => ()
  }
  for update in arr(get(r, "usages")) {
    self.updated(Some(update), None)
  }
  match self.transcript {
    Some(k) => k.quiet = false
    None => ()
  }
  self.own.tools_url = Some(mcp_url)
  if self.flavor != "devin" || !self.busy() {
    return
  }
  guard last_usage is Some(last) else { return }
  let l = Some(last)
  guard get(l, "run") is Some(Str(run_units)) && get(l, "usage") is Some(usage) else { return }
  let parts = t(run_units).split(":").map(p => p.to_owned()).collect()
  let run = parts[0]
  let calls = if parts.length() < 2 { 1.0 } else { js_number(parts[1]) }
  let before = match self.usage {
    Some(u) => u.calls.to_double()
    None => 0.0
  }
  if run == "" || !safe_integer(calls) || calls < before {
    return
  }
  self.usage = Some({
    run,
    calls: calls.to_int(),
    last_call: stringify(usage),
    context: finite_or_zero(get(l, "context")),
    window: finite_or_zero(get(l, "window")),
  })
}

///|
/// `Number(s)` of a string.
fn js_number(s : String) -> Double {
  @jsjson.js_number(s)
}

///|
/// `Number.isSafeInteger(n)`.
fn safe_integer(n : Double) -> Bool {
  finite(n) && n.floor() == n && n.abs() <= 9007199254740991.0
}
