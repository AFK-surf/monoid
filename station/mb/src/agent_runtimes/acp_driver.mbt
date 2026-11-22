// acp.ts `AcpDriver.begin` (with devin.ts', hermes.ts' `initialized` and `ready`): a session opened on a process just
// started — initialize, the runtime's own sign-in or version check, session/new (named by the runtime, its transcript
// begun) or session/load, what it runs on, then what it runs with — each request answered by `answer` (the runtime's
// line for a method's request, its id put in), in the order the driver asks them. A refusal fails the opening, the
// session disposed.

///|
let client_info : (String, String) = ("still.fail", "1")

///|
/// What an opening needs besides the session: its options, how it was started, whether it is a probe (only to learn
/// what it offers: no tools, nothing kept), Devin's key, and the model Hermes is set to.
pub(all) struct Opening {
  options : Options
  start : Start
  probe : Bool
  devin_key : String?
}

///|
/// Asks `method` and takes its answer: a refusal's words where it is one.
fn Acp::ask(self : Acp, id : String, method : String, params : J, answer : (String) -> J?) -> Result[J, String] {
  self.own.write(rpc(id, method, params))
  let reply = match answer(method) {
    Some(Obj(entries)) => {
      let f = Fields::of([("jsonrpc", js("2.0")), ("id", js(id))])
      for e in entries {
        if t(e.0) != "id" && t(e.0) != "jsonrpc" {
          f.set(t(e.0), e.1)
        }
      }
      f.json()
    }
    _ => return Err("no answer to \{id}")
  }
  match get(Some(reply), "error") {
    None => Ok(reply)
    Some(e) => Err("\{self.flavor} \{method}: \{error_text(e)}")
  }
}

///|
/// `begin`: the session opened, or the words it failed with (then disposed).
pub fn Acp::begin(self : Acp, opening : Opening, answer : (String) -> J?) -> String? {
  let options = opening.options
  let start = opening.start
  self.own.tools_url = Some(options.mcp_url)
  let meta = start.meta
  let fail = (why : String) => {
    self.own.dispose()
    self.own.settle()
    Some(why)
  }
  let init = Fields::of([
    ("protocolVersion", int(1)),
    ("clientCapabilities", obj([])),
    ("clientInfo", obj([("name", js(client_info.0)), ("version", js(client_info.1))])),
  ])
  if meta is Some(m) {
    init.set("_meta", m)
  }
  let initialized = match self.ask(acp_init, "initialize", init.json(), answer) {
    Ok(a) => a
    Err(why) => return fail(why)
  }
  match self.flavor {
    "devin" =>
      if opening.devin_key is Some(key) {
        match
          self.ask(
            "auth",
            "authenticate",
            obj([("methodId", js("devin-browser")), ("_meta", obj([("api_key", js(key))]))]),
            answer,
          ) {
          Ok(_) => ()
          Err(why) => return fail(why)
        }
      }
    "hermes" => if hermes_version_refusal(Some(initialized)) is Some(why) { return fail(why) }
    _ => ()
  }
  let open = Fields::of([
    ("cwd", js(options.cwd)),
    ("mcpServers", if opening.probe { Arr([]) } else { mcp_servers(options.mcp_url, options.mcp_token) }),
  ])
  open.spread(spread_of(start.opening))
  if meta is Some(m) {
    open.set("_meta", m)
  }
  let opened = match options.resume {
    Some(resume) => {
      if self.named(resume) is Some(why) {
        return fail(why)
      }
      let load = Fields::of([("sessionId", js(resume))])
      load.spread(open.entries())
      match self.ask(acp_open, "session/load", load.json(), answer) {
        Ok(a) => a
        Err(why) => return fail(why)
      }
    }
    None => {
      let a = match self.ask(acp_open, "session/new", open.json(), answer) {
        Ok(a) => a
        Err(why) => return fail(why)
      }
      match get(get(Some(a), "result"), "sessionId") {
        Some(Str(id)) if id.length() > 0 => {
          if self.named(t(id)) is Some(why) {
            return fail(why)
          }
          if !opening.probe {
            self.began(options.cwd)
          }
        }
        _ => return fail("\{runtime_label(self.flavor)} named no session")
      }
      a
    }
  }
  self.open(get(Some(opened), "result"), resumed=options.resume is Some(_))
  match self.flavor {
    "devin" => {
      let r = self.ask(
        "config:\{self.own.uuid()}",
        "session/set_config_option",
        obj([("sessionId", js(self.own.session_id)), ("configId", js("mode")), ("value", js("bypass"))]),
        answer,
      )
      if r is Err(why) {
        return fail(why)
      }
    }
    "hermes" => {
      let model = if opening.probe { None } else { options.chosen_model() }
      if model is Some(m) {
        let r = self.ask(
          "model:\{self.own.uuid()}",
          "session/set_model",
          obj([("sessionId", js(self.own.session_id)), ("modelId", js(m))]),
          answer,
        )
        if r is Err(why) {
          return fail(why)
        }
      }
    }
    _ => ()
  }
  None
}

///|
/// The opening of a session of dsh, Cursor or Pi on its process just started: its request (`open`, Pi's `get_state`)
/// answered by `answer` (the bridge's line, its id put in), the session it names taken (Pi's is the station's own).
/// `no_tools` what dsh's refusal for the station's tools is said as (i18n `station.dsh.noTools`).
pub fn Bridged::begin(self : Bridged, start : Start, answer : (String) -> J?, no_tools? : String = "") -> String? {
  let kind = self.kind()
  let op = if kind == "pi" { "get_state" } else { "open" }
  let params = start.open.unwrap_or(obj([]))
  self.own.write(request_line(acp_open, self.op_field(), op, params))
  let fail = (why : String) => {
    self.own.dispose()
    self.own.settle()
    Some(why)
  }
  let reply = match answer(op) {
    Some(Obj(entries)) => {
      let f = Fields::of([("id", js(acp_open))])
      for e in entries {
        if t(e.0) != "id" {
          f.set(t(e.0), e.1)
        }
      }
      f.json()
    }
    _ => return fail("no answer to \{acp_open}")
  }
  match kind {
    "dsh" =>
      match dsh_opened(reply, no_tools) {
        Ok(id) => self.own.session_id = id
        Err(why) => return fail(why)
      }
    "cursor" => {
      if (self.refusal(op))(reply) is Some(why) {
        return fail(why)
      }
      match get(Some(reply), "session") {
        Some(Str(s)) if s.length() > 0 => self.own.session_id = t(s)
        _ => return fail("Cursor's SDK named no agent")
      }
    }
    _ => if (self.refusal(op))(reply) is Some(why) { return fail(why) }
  }
  None
}
