// acp.ts as Antigravity CLI's driver stands on it: the Agent Client Protocol (JSON-RPC over stdio) spoken to a runtime
// in a process of its own, one ACP session in it: `initialize`, `session/new` or `session/load` with the station's
// tools, a turn a `session/prompt` ended by its answer, a prompt put in the running turn, `session/cancel`, a permission
// granted for the call it asks for and any other request of its own refused, and the transcript the station keeps of
// a runtime whose own it cannot read (`KeptTranscript`). Its updates and a prompt's answer are read by the program
// (mb/src/acp, reader agents_own.mbt).

///|
let acp_init = "init"

///|
let acp_open = "open"

///|
let acp_prompt = "prompt:"

///|
let acp_steer = "steer:"

///|
/// A JSON-RPC request (`rpc`).
pub fn rpc(id : String, meth : String, params : JValue) -> String {
  json_text(obj([("jsonrpc", s("2.0")), ("id", s(id)), ("method", s(meth)), ("params", params)]))
}

///|
/// The station's tools as ACP gives an MCP server (`mcpServers`).
pub fn mcp_servers(url : String, token : String) -> JValue {
  arr([
    obj([
      ("type", s("http")),
      ("name", s("stillfail")),
      ("url", s(url)),
      ("headers", arr([obj([("name", s("Authorization")), ("value", s("Bearer \{token}"))])])),
    ]),
  ])
}

///|
/// What an error answer says: its message, and its data's (`errorText`).
pub fn error_text(error : JValue?) -> String {
  let text = match str_at(error, "message") {
    Some(m) =>
      if m.has_prefix("Internal error: ") {
        m.substring(start=16)
      } else {
        m
      }
    None =>
      match error {
        Some(e) => json_text(e)
        None => "undefined"
      }
  }
  let data = match get(error, "data") {
    Some(Str(u)) => ": \{@jsjson.sanitize_str(u)}"
    Some(d) =>
      match str_at(Some(d), "message") {
        Some(m) => ": \{m}"
        None =>
          match str_at(Some(d), "details") {
            Some(m) => ": \{m}"
            None => ""
          }
      }
    None => ""
  }
  "\{text}\{data}"
}

///|
/// The transcript the station keeps of a session (`KeptTranscript`): a line a thing said or done, written in turn.
pub struct KeptTranscript {
  m : Machine
  kind : String
  dir : String
  mut quiet : Bool
  mut writing : Later[Unit]?
}

///|
pub fn KeptTranscript::new(m : Machine, kind : String, dir : String) -> KeptTranscript {
  { m, kind, dir, quiet: false, writing: None }
}

///|
pub fn KeptTranscript::keep(self : KeptTranscript, id : String, line : JValue) -> Unit {
  if id == "" || self.quiet {
    return
  }
  let text = json_text(spread([obj([("time", d(self.m.now()))]), line])) + "\n"
  let path = self.m.join([self.dir, "\{id}.jsonl"])
  let before = match self.writing {
    Some(w) => w
    None => done(self.m.lp)
  }
  let next = before.bind(_ => self.m
    .append_file(path, text)
    .recover(e => {
      self.m.log(
        "warn",
        "agents::\{self.kind}",
        "a transcript line was not kept",
        obj([("session", s(id)), ("error", s(words_of(e)))]),
      )
      done(self.m.lp)
    }))
  self.writing = Some(next)
  next.on(_ => match self.writing {
    Some(w) if physical_equal(w, next) => self.writing = None
    _ => ()
  })
}

///|
pub fn KeptTranscript::settled(self : KeptTranscript) -> Later[Unit]? {
  self.writing
}

///|
pub fn KeptTranscript::ended(self : KeptTranscript, id : String, outcome : JValue) -> Unit {
  let kind = str_at(Some(outcome), "kind").unwrap_or("")
  let fields = [
    ("type", s("end")),
    (
      "status",
      s(
        match kind {
          "completed" => "finished"
          "aborted" => "cancelled"
          _ => "error"
        },
      ),
    ),
  ]
  if kind == "failed" {
    fields.push(("error", obj([("message", get(Some(outcome), "message").unwrap_or(Null))])))
  }
  self.keep(id, obj(fields))
}

///|
pub fn KeptTranscript::quietly(self : KeptTranscript, f : () -> Unit) -> Unit {
  self.quiet = true
  f()
  self.quiet = false
}

///|
/// What a runtime's ACP session does its own way (`AcpSession`'s hooks).
pub struct AcpHooks {
  updated : (JValue, String?) -> Unit
  ending : (String, JValue) -> Unit
  ignored : (String, JValue) -> Unit
  prompt_text : (String) -> String
  kept : () -> Array[(String, JValue)]
  taken : (JValue) -> Unit
  opened : (JValue?) -> Unit
  named : (String) -> Unit raise
}

///|
/// A session of an ACP runtime (`AcpSession`).
pub struct AcpSession {
  own : OwnSession
  ids : Ids
  mut model : String?
  transcript : KeptTranscript?
  mut is_open : Bool
  mut acp : AcpHooks
}

///|
pub fn AcpSession::new(lp : Loop, kind : String, ids : Ids, events : (JValue) -> Unit, transcript : KeptTranscript?) -> AcpSession {
  let own = OwnSession::new(
    lp,
    kind,
    "",
    obj([
      ("busy", b(false)),
      ("aborting", b(false)),
      ("closed", b(false)),
      ("owner", Null),
      ("steering", arr([])),
    ]),
    events,
  )
  let session = {
    own,
    ids,
    model: None,
    transcript,
    is_open: false,
    acp: {
      updated: (_, _) => (),
      ending: (_, _) => (),
      ignored: (_, _) => (),
      prompt_text: t => t,
      kept: () => [],
      taken: _ => (),
      opened: _ => (),
      named: _ => (),
    },
  }
  own.hooks = {
    heard: line => session.heard(line),
    took: e => session.took(e),
    settled: () => match session.transcript {
      Some(t) => t.settled()
      None => None
    },
    cut_short: said => match session.transcript {
      Some(t) =>
        t.ended(
          own.session_id,
          obj([
            ("kind", s("failed")),
            ("reason", s("exited")),
            ("message", s("\{kind} exited (\{said})")),
          ]),
        )
      None => ()
    },
    attached: () => session.attached(),
  }
  session
}

///|
pub fn AcpSession::lp(self : AcpSession) -> Loop {
  self.own.lp
}

///|
pub fn AcpSession::say(self : AcpSession, what : String, fields : JValue) -> Unit {
  match self.own.proc {
    Some(p) => (p.say)(what, fields)
    None => ()
  }
}

///|
/// Open: what session/new or session/load said (`opened`).
pub fn AcpSession::opened(self : AcpSession, result : JValue?) -> Unit {
  self.is_open = true
  self.say("acpOpened", obj([]))
  (self.acp.opened)(result)
}

///|
pub fn AcpSession::attached(self : AcpSession) -> Unit {
  guard self.own.proc is Some(_) else { return }
  if self.own.session_id != "" {
    self.say("acpSession", obj([("id", s(self.own.session_id))]))
  }
  if self.is_open {
    self.say("acpOpened", obj([]))
  }
}

///|
pub fn AcpSession::named(self : AcpSession, id : String) -> Unit raise {
  (self.acp.named)(id)
  self.own.session_id = id
  self.say("acpSession", obj([("id", s(id))]))
}

///|
/// A session made new: the transcript says so first (`began`).
pub fn AcpSession::began(self : AcpSession, cwd : String) -> Unit {
  match self.transcript {
    Some(t) =>
      t.keep(
        self.own.session_id,
        obj([("type", s("session")), ("id", s(self.own.session_id)), ("cwd", s(cwd))]),
      )
    None => ()
  }
}

///|
/// A request whose answer is waited for: an error answer rejects (`request`).
pub fn AcpSession::request(
  self : AcpSession,
  id : String,
  meth : String,
  params : JValue,
  timeout_ms? : Double,
) -> Later[JValue] {
  let kind = self.own.kind
  let answer = self.own.waiting.wait(
    id,
    m => match get(Some(m), "error") {
      Some(e) => Some(Failed("\{kind} \{meth}: \{error_text(Some(e))}"))
      None => None
    },
    ms?=timeout_ms,
  )
  (self.own.p().write)(rpc(id, meth, params))
  answer
}

///|
/// A request whose answer is not waited for (`send`).
pub fn AcpSession::send(self : AcpSession, meth : String, params : JValue) -> Unit {
  (self.own.p().write)(rpc("\{meth}:\{(self.ids.next)()}", meth, params))
}

///|
/// A line the program gives here: a request of the runtime's, or an answer to one of ours (`heard`).
pub fn AcpSession::heard(self : AcpSession, line : String) -> Unit {
  guard parse_json(line) is Some(message) else { return }
  let id = get(Some(message), "id")
  let meth = get(Some(message), "method")
  if str_of(meth) == Some("session/request_permission") && id is Some(i) {
    self.permit(i, get(get(Some(message), "params"), "options"))
    return
  }
  match meth {
    Some(m) => {
      match id {
        Some(i) => {
          let name = match m {
            Str(u) => @jsjson.sanitize_str(u)
            other => js_string_of(other)
          }
          (self.own.p().write)(
            json_text(
              obj([
                ("jsonrpc", s("2.0")),
                ("id", i),
                ("error", obj([("code", n(-32601)), ("message", s("\{name} is not supported"))])),
              ]),
            ),
          )
        }
        None => ()
      }
      return
    }
    None => ()
  }
  self.own.waiting.answer(id, message) |> ignore
}

///|
/// What the program says for this alone: the transcript's lines, its usage, a prompt's answer (`took`).
pub fn AcpSession::took(self : AcpSession, e : JValue) -> Bool {
  match str_at(Some(e), "type") {
    Some("kept") => {
      match self.transcript {
        Some(t) => t.keep(self.own.session_id, get(Some(e), "line").unwrap_or(Null))
        None => ()
      }
      true
    }
    Some("usage") => {
      (self.acp.updated)(get(Some(e), "update").unwrap_or(Null), str_at(Some(e), "owner"))
      true
    }
    Some("answered") => {
      let id = match get(Some(e), "id") {
        Some(Str(u)) => @jsjson.sanitize_str(u)
        Some(other) => js_string_of(other)
        None => "undefined"
      }
      let answer = get(Some(e), "answer").unwrap_or(Null)
      if get(Some(e), "outcome") is Some(_) {
        (self.acp.ending)(id, answer)
      } else {
        (self.acp.ignored)(id, answer)
      }
      true
    }
    _ => false
  }
}

///|
/// A permission it asks: granted for this call, refused where nothing allows just it (`permit`).
pub fn AcpSession::permit(self : AcpSession, id : JValue, options : JValue?) -> Unit {
  let offered = arr_of(options).unwrap_or([])
  let result = match offered.search_by(o => str_at(Some(o), "kind") == Some("allow_once")) {
    Some(i) => {
      let chosen = [("outcome", s("selected"))]
      match get(Some(offered[i]), "optionId") {
        Some(v) => chosen.push(("optionId", v))
        None => ()
      }
      obj([("outcome", obj(chosen))])
    }
    None => obj([("outcome", obj([("outcome", s("cancelled"))]))])
  }
  let fields = [("jsonrpc", s("2.0")), ("id", id), ("result", result)]
  // (an undefined optionId is left out as JSON.stringify leaves it)
  (self.own.p().write)(json_text(obj(fields)))
}

///|
pub fn AcpSession::prompt_params(self : AcpSession, text : String) -> JValue {
  obj([
    ("sessionId", s(self.own.session_id)),
    ("prompt", arr([obj([("type", s("text")), ("text", s((self.acp.prompt_text)(text)))])])),
  ])
}

///|
/// A turn (`prompt`).
pub fn AcpSession::prompt(self : AcpSession, text : String) -> Later[Unit] {
  self.own.startable() catch {
    e => return Later::fail(self.lp(), e)
  }
  let owner = "\{acp_prompt}\{(self.ids.next)()}"
  self.own.set_flag("busy", b(true))
  self.own.set_flag("owner", s(owner))
  let fields = [("owner", s(owner))]
  if self.transcript is Some(_) {
    fields.push(("text", s(text)))
  }
  self.say("acpPrompt", obj(fields))
  (self.own.p().write)(rpc(owner, "session/prompt", self.prompt_params(text)))
  done(self.lp())
}

///|
pub fn AcpSession::inject_prompt(self : AcpSession, text : String, take_over : Bool) -> Bool {
  if self.own.closed() || !self.own.busy() || self.own.flag("aborting") {
    return false
  }
  let id = "\{acp_steer}\{(self.ids.next)()}"
  let steering = strings_in(get(Some(self.own.turn), "steering"))
  let add = (x : String) => if !steering.contains(x) { steering.push(x) }
  if take_over {
    match str_at(Some(self.own.turn), "owner") {
      Some(o) => add(o)
      None => ()
    }
    self.own.set_flag("owner", s(id))
  } else {
    add(id)
  }
  self.own.set_flag("steering", strs(steering))
  let fields = [("id", s(id)), ("takeOver", b(take_over))]
  if self.transcript is Some(_) {
    fields.push(("text", s(text)))
  }
  self.say("acpInject", obj(fields))
  (self.own.p().write)(rpc(id, "session/prompt", self.prompt_params(text)))
  true
}

///|
/// Into the running turn as a prompt that takes it over (`promptTakeover`).
pub fn AcpSession::prompt_takeover(self : AcpSession, text : String) -> Bool {
  self.inject_prompt(text, true)
}

///|
pub fn AcpSession::prompt_into(self : AcpSession, text : String) -> Bool {
  self.inject_prompt(text, false)
}

///|
pub fn AcpSession::abort(self : AcpSession) -> Later[Unit] {
  if !(self.own.closed() || !self.own.busy() || self.own.flag("aborting")) {
    self.own.set_flag("aborting", b(true))
    (self.own.p().tell)("aborting")
    (self.own.p().write)(
      json_text(
        obj([
          ("jsonrpc", s("2.0")),
          ("method", s("session/cancel")),
          ("params", obj([("sessionId", s(self.own.session_id))])),
        ]),
      ),
    )
  }
  done(self.lp())
}

///|
/// What the station that handed it over knew of it (`handed`).
pub fn AcpSession::handed(self : AcpSession, snapshot : JValue) -> Unit {
  let sn = Some(snapshot)
  self.own.session_id = str_at(sn, "id").unwrap_or("")
  let turn = get(sn, "turn")
  self.own.turn = obj([
    ("busy", b(is_true(turn, "busy"))),
    ("aborting", b(is_true(turn, "aborting"))),
    ("closed", b(false)),
    ("owner", get(sn, "owner").unwrap_or(Null)),
    ("steering", get(sn, "steering").unwrap_or(arr([]))),
  ])
  let or = (k : String, v : JValue) => match get(sn, k) {
    Some(Null) | None => v
    Some(x) => x
  }
  self.own.live_state = obj([
    ("live", get(sn, "live").unwrap_or(Null)),
    ("said", or("said", Null)),
    ("calls", or("calls", arr([]))),
    ("saidLast", or("saidLast", s(""))),
    ("children", or("children", arr([]))),
    ("loading", b(false)),
    ("session", get(sn, "id").unwrap_or(Null)),
  ])
  self.own.tools_url = str_at(sn, "tools")
  match get(sn, "model") {
    Some(Str(u)) => self.model = Some(@jsjson.sanitize_str(u))
    _ => ()
  }
  self.is_open = true
  (self.acp.taken)(snapshot)
}

///|
/// What the program read again after a crash (`replayed`).
pub fn AcpSession::replayed(self : AcpSession, replayed : JValue, resumed : String?) -> Unit {
  let r = Some(replayed)
  self.own.session_id = match str_at(r, "session") {
    Some(id) if id != "" => id
    _ => resumed.unwrap_or("")
  }
  self.own.turn = obj([
    ("busy", b(is_true(get(r, "turn"), "busy"))),
    ("aborting", b(false)),
    ("closed", b(false)),
    ("owner", Null),
    ("steering", arr([])),
  ])
  self.own.live_state = get(r, "live").unwrap_or(Null)
  self.is_open = true
  let configured = self.model
  match get(r, "opened") {
    Some(Null) | None => ()
    Some(o) => self.opened(Some(o))
  }
  if configured is Some(_) {
    self.model = configured
  }
  let again = () => for u in arr_at(r, "usages").unwrap_or([]) {
    (self.acp.updated)(u, None)
  }
  match self.transcript {
    Some(t) => t.quietly(again)
    None => again()
  }
}

///|
/// What a next station takes it up from (`snapshot`).
pub fn AcpSession::snapshot(self : AcpSession) -> JValue {
  let frozen = self.own.hand_over()
  let turn = match frozen {
    Some((t, _)) => t
    None => self.own.turn_now()
  }
  let state = match frozen {
    Some((_, l)) => l
    None =>
      match self.own.live_state {
        Null => obj([])
        l => l
      }
  }
  let or = (k : String, v : JValue) => match get(Some(state), k) {
    Some(Null) | None => v
    Some(x) => x
  }
  let fields = [
    ("runtime", s(self.own.kind)),
    ("id", s(self.own.session_id)),
    ("runner", s(self.own.p().info.id())),
    (
      "turn",
      obj([("busy", b(is_true(Some(turn), "busy"))), ("aborting", b(is_true(Some(turn), "aborting")))]),
    ),
    ("tools", opt_s(self.own.tools_url)),
    (
      "live",
      or(
        "live",
        obj([("open", arr([])), ("said", Null), ("n", n(0)), ("phase", Null)]),
      ),
    ),
    ("model", opt_s(self.model)),
    (
      "owner",
      match get(Some(turn), "owner") {
        Some(Null) | None => Null
        Some(o) => o
      },
    ),
    (
      "steering",
      match get(Some(turn), "steering") {
        Some(Null) | None => arr([])
        Some(x) => x
      },
    ),
    ("said", or("said", Null)),
    ("calls", or("calls", arr([]))),
    ("saidLast", or("saidLast", s(""))),
    ("children", or("children", arr([]))),
  ]
  spread([obj(fields), obj((self.acp.kept)())])
}

///|
/// How a runtime's process is started for a session (`AcpStart`).
pub struct AcpStart {
  command : String
  args : Array[String]
  env : Env
  meta : JValue?
  opening : JValue?
  initialize_timeout_ms : Double?
}
