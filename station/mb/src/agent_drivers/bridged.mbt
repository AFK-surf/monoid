// The runtimes the station speaks to through a bridge of its own, a line of JSON per message: dsh.ts `DshDriver` (its
// driver plugin, which dsh loads itself), cursor.ts `CursorDriver` (the bridge on Cursor's SDK, run by the Node on the
// agent's PATH), pi.ts `PiDriver` (Pi's RPC, its extension loaded by Pi itself). What their lines do to the turn and its
// live steps is the program's (mb/src/dsh, mb/src/cursor, mb/src/pi); this is what the driver writes, how it takes the
// answers to its requests, and its sessions' snapshots and taking up. What a session is started with (its arguments,
// environment and files) is agent_runtimes' `dsh_start`, `cursor_start` and `pi_start`, said by the station.

///|
/// A session of `dsh`, `cursor` or `pi`.
pub struct BridgedSession {
  own : OwnSession
  kind : String
  ids : Ids
  /// Cursor's: the model its next turn runs on (none: the agent's).
  mut model : String?
}

///|
fn bridged_turn(kind : String, from : JValue?) -> JValue {
  let base = if kind == "cursor" {
    obj([("busy", b(false)), ("aborting", b(false))])
  } else {
    obj([("busy", b(false)), ("prompted", b(false)), ("aborting", b(false))])
  }
  let given = match from {
    Some(Obj(_) as t) => t
    _ => obj([])
  }
  spread([base, given, obj([("closed", b(false))])])
}

///|
fn BridgedSession::make(
  lp : Loop,
  kind : String,
  ids : Ids,
  session_id : String,
  turn : JValue,
  live : JValue,
  events : (JValue) -> Unit,
  model : String?,
) -> BridgedSession {
  let own = OwnSession::new(lp, kind, session_id, turn, events, live~)
  let x = { own, kind, ids, model, }
  own.hooks = { ..no_hooks(), heard: line => x.heard(line), }
  x
}

///|
/// The field a request's name goes in: Pi's `type`, the others' `op`.
fn BridgedSession::op_field(self : BridgedSession) -> String {
  if self.kind == "pi" {
    "type"
  } else {
    "op"
  }
}

///|
/// A turn runs, or (dsh, Pi) one of ours is asked for and has not started yet.
pub fn BridgedSession::busy(self : BridgedSession) -> Bool {
  self.own.flag("busy") || (self.kind != "cursor" && self.own.flag("prompted"))
}

///|
fn BridgedSession::write(
  self : BridgedSession,
  id : String,
  op : String,
  params : Array[(String, JValue)],
) -> Unit {
  (self.own.p().write)(
    json_text(obj([("id", s(id)), (self.op_field(), s(op)), ..params])),
  )
}

///|
/// A request whose answer is waited for (`request`): refused (dsh's and Cursor's `error`, Pi's `success: false`), it
/// fails; dsh's refusal for the station's tools (`lacks: "tools"`) fails as `no_tools` says it.
pub fn BridgedSession::request(
  self : BridgedSession,
  id : String,
  op : String,
  params : Array[(String, JValue)],
  late? : String,
  no_tools? : String,
) -> Later[JValue] {
  let kind = self.kind
  let refused = fn(m : JValue) -> Error? {
    if kind == "pi" {
      if get(Some(m), "success") is Some(Bool(false)) {
        let error = match get(Some(m), "error") {
          None | Some(Null) => "refused"
          Some(Str(_)) => str_at(Some(m), "error").unwrap_or("refused")
          Some(other) => json_text(other)
        }
        Some(Failed("pi \{op}: \{error}"))
      } else {
        None
      }
    } else {
      match str_at(Some(m), "error") {
        Some(e) =>
          if kind == "dsh" &&
            str_at(Some(m), "lacks") == Some("tools") &&
            no_tools is Some(w) {
            Some(Said(w))
          } else {
            Some(Failed("\{kind} \{op}: \{e}"))
          }
        None => None
      }
    }
  }
  let answer = self.own.waiting.wait(id, refused, late?)
  self.write(id, op, params)
  answer
}

///|
/// A request whose answer is not waited for (`send`).
fn BridgedSession::send(
  self : BridgedSession,
  op : String,
  params : Array[(String, JValue)],
) -> Unit {
  self.write("\{op}:\{(self.ids.next)()}", op, params)
}

///|
/// An answer to a request, or (Pi) an extension's dialog, cancelled: nobody is there to answer one (`heard`).
fn BridgedSession::heard(self : BridgedSession, line : String) -> Unit {
  guard parse_json(line) is Some(message) else { return }
  let m = Some(message)
  if self.kind == "pi" && str_at(m, "type") == Some("extension_ui_request") {
    if str_at(m, "method") is Some(method) &&
      ["select", "confirm", "input", "editor"].contains(method) {
      (self.own.p().write)(
        json_text(
          obj([
            ("type", s("extension_ui_response")),
            ("id", get(m, "id").unwrap_or(Null)),
            ("cancelled", b(true)),
          ]),
        ),
      )
    }
    return
  }
  // (one refused that nobody waits for: a prompt refused ends the turn there, in the program)
  ignore(self.own.waiting.answer(get(m, "id"), message))
}

///|
/// A turn asked for (`prompt`).
pub fn BridgedSession::prompt(
  self : BridgedSession,
  text : String,
) -> Later[Unit] {
  let lp = self.own.lp
  if self.own.closed() {
    return Later::fail(lp, Failed("\{self.kind} session is closed"))
  }
  if self.busy() {
    return Later::fail(lp, Failed("a turn is already running"))
  }
  match self.kind {
    "cursor" => {
      self.own.set_flag("busy", b(true))
      (self.own.p().tell)("begin")
      let model = match self.model {
        Some(mm) => [("model", s(mm))]
        None => []
      }
      self.write(
        "prompt:\{(self.ids.next)()}",
        "prompt",
        [("text", s(text)), ..model],
      )
    }
    kind => {
      self.own.set_flag("prompted", b(true))
      (self.own.p().tell)("begin")
      self.send("prompt", [
        (if kind == "pi" { "message" } else { "text" }, s(text)),
      ])
    }
  }
  done(lp)
}

///|
/// Into the running turn (`steer`): dsh's and Pi's read after the step it is in; Cursor's by its SDK's steer, what its
/// bridge says it delivered (not delivered: the station gives it as the next turn's).
pub fn BridgedSession::steer(
  self : BridgedSession,
  text : String,
) -> Later[Bool] {
  let lp = self.own.lp
  if self.kind == "cursor" {
    if self.own.closed() || !self.own.flag("busy") || self.own.flag("aborting") {
      return Later::ok(lp, false)
    }
    return self
      .request("steer:\{(self.ids.next)()}", "steer", [("text", s(text))])
      .map(answer => is_true(Some(answer), "delivered"))
      .recover(_ => Later::ok(lp, false))
  }
  if self.own.closed() || !self.busy() {
    return Later::ok(lp, false)
  }
  self.send("steer", [
    (if self.kind == "pi" { "message" } else { "text" }, s(text)),
  ])
  Later::ok(lp, true)
}

///|
/// `abort`.
pub fn BridgedSession::abort(self : BridgedSession) -> Later[Unit] {
  let running = if self.kind == "cursor" {
    self.own.flag("busy")
  } else {
    self.busy()
  }
  if !self.own.closed() && running && !self.own.flag("aborting") {
    self.own.set_flag("aborting", b(true))
    (self.own.p().tell)("aborting")
    match self.kind {
      "cursor" => self.write("cancel:\{(self.ids.next)()}", "cancel", [])
      "pi" => self.send("abort", [])
      _ => self.send("cancel", [])
    }
  }
  done(self.own.lp)
}

///|
/// Cursor's `retune`: another model between turns is the next prompt's (the SDK takes one per run): no new process.
pub fn BridgedSession::retune(self : BridgedSession, options : JValue) -> Bool {
  if self.kind != "cursor" ||
    self.own.closed() ||
    self.own.flag("busy") ||
    self.own.session_id == "" {
    return false
  }
  let o = Some(options)
  let model = match str_at(o, "model") {
    Some(mm) => Some(mm)
    None => profile_model(get(o, "profile").unwrap_or(Null))
  }
  guard model is Some(mm) else { return false }
  self.model = Some(mm)
  true
}

///|
/// What a next station takes it up from (`snapshot`).
pub fn BridgedSession::snapshot(self : BridgedSession) -> JValue {
  let frozen = self.own.hand_over()
  let turn = match frozen {
    Some((t, _)) => Some(t)
    None => Some(self.own.turn)
  }
  let live = match frozen {
    Some((_, l)) => l
    None => self.own.live_state
  }
  let flags = [("busy", b(is_true(turn, "busy")))]
  if self.kind != "cursor" {
    flags.push(("prompted", b(is_true(turn, "prompted"))))
  }
  flags.push(("aborting", b(is_true(turn, "aborting"))))
  if self.kind == "pi" && str_at(turn, "error") is Some(e) {
    flags.push(("error", s(e)))
  }
  let out = [
    ("runtime", s(self.kind)),
    ("id", s(self.own.session_id)),
    ("runner", s(self.own.p().info.id())),
    ("turn", obj(flags)),
    ("tools", opt_s(self.own.tools_url)),
    ("live", live),
  ]
  if self.kind == "cursor" {
    out.push(("model", opt_s(self.model)))
  }
  obj(out)
}

///|
/// What its process's lines are read with: a prompt asked for and not yet begun is a turn running as it goes away.
fn BridgedSession::hosted(
  self : BridgedSession,
  label : String,
) -> HostedOptions {
  let base = self.own.hosted_options(label, self.kind)
  {
    ..base,
    exit: (said, stderr) => {
      if self.own.flag("prompted") {
        self.own.set_flag("busy", b(true))
      }
      self.own.exited(said, stderr)
    },
  }
}

///|
/// The driver of one of them (`DshDriver`, `CursorDriver`, `PiDriver`).
pub struct BridgedDriver {
  own : OwnDriver
  kind : String
  ids : Ids
  sessions : Array[BridgedSession]
}

///|
pub fn BridgedDriver::new(
  m : Machine,
  data : String,
  procs : Procs,
  kind : String,
  ids : Ids,
) -> BridgedDriver {
  { own: OwnDriver::new(m, data, procs, kind), kind, ids, sessions: [], }
}

///|
fn BridgedDriver::keep(self : BridgedDriver, x : BridgedSession) -> Unit {
  self.sessions.push(x)
  let forget = x.own.forget
  x.own.forget = () => {
    match self.sessions.search_by(y => physical_equal(y, x)) {
      Some(i) => self.sessions.remove(i) |> ignore
      None => ()
    }
    forget()
  }
}

///|
/// Opens a session (`open` past what its runtime is started with): its process started under a runner, then its
/// opening asked (dsh's and Cursor's `open`, naming the session; Pi's `get_state`, up once it answers). `id`: the
/// session's where its runtime does not name one (Pi's). One that does not open is ended.
pub fn BridgedDriver::open(
  self : BridgedDriver,
  key : String,
  cwd : String,
  command : String,
  args : Array[String],
  env : Env,
  opening : JValue,
  tools : String,
  events : (JValue) -> Unit,
  id~ : String = "",
  model? : String?,
  no_tools? : String,
) -> Later[BridgedSession] {
  let lp = self.own.m.lp
  let kind = self.kind
  let x = BridgedSession::make(
    lp,
    kind,
    self.ids,
    id,
    bridged_turn(kind, None),
    Null,
    events,
    model.unwrap_or(None),
  )
  x.own.tools_url = Some(tools)
  let (op, late) = match kind {
    "pi" =>
      (
        "get_state", "Pi did not answer (it could not start, or it is older than 1.0?)",
      )
    "cursor" => ("open", "Cursor's SDK did not open the agent in time")
    _ =>
      (
        "open", "dsh did not open the session (its driver plugin did not load, or the station's tools never answered its MCP client?)",
      )
  }
  self.own
  .start(x.own, key, cwd, command, args, env, x.hosted("\{kind} \{key}"))
  .bind(_ => {
    x
    .request("open", op, entries_of(Some(opening)), late~, no_tools?)
    .map(opened => {
      if kind != "pi" {
        match str_at(Some(opened), "session") {
          Some(sid) if sid != "" => x.own.session_id = sid
          _ =>
            raise Failed(
              if kind == "cursor" {
                "Cursor's SDK named no agent"
              } else {
                "dsh named no session"
              },
            )
        }
      }
      self.keep(x)
      x
    })
    .recover(e => {
      x.own.dispose().recover(_ => done(lp)).bind(_ => Later::fail(lp, e))
    })
  })
}

///|
/// Takes up a session whose process a runner kept (`adopt`): handed over with a snapshot, or after a crash from what
/// the program reads again of its output.
pub fn BridgedDriver::adopt(
  self : BridgedDriver,
  options : JValue,
  snapshot : JValue?,
  events : (JValue) -> Unit,
) -> Later[BridgedSession] {
  let lp = self.own.m.lp
  let kind = self.kind
  let o = Some(options)
  let key = str_at(o, "key").unwrap_or("")
  let made : Ref[BridgedSession?] = Ref(None)
  let replaying = match str_at(o, "resume") {
    Some(r) => obj([("resume", s(r))])
    None => obj([])
  }
  let how : Adopting = {
    handed_over: (h, _) => {
      let x = BridgedSession::make(
        lp,
        kind,
        self.ids,
        str_at(Some(h), "id").unwrap_or(""),
        bridged_turn(kind, get(Some(h), "turn")),
        get(Some(h), "live").unwrap_or(Null),
        events,
        str_at(Some(h), "model"),
      )
      x.own.tools_url = str_at(Some(h), "tools")
      made.val = Some(x)
      x.own
    },
    crashed: (r, _) => {
      let session_id = match
        (kind, str_at(Some(r), "session"), str_at(o, "resume")) {
        ("pi", _, Some(resume)) => resume
        ("pi", _, None) => ""
        (_, Some(sid), _) => sid
        (_, None, Some(resume)) => resume
        _ => ""
      }
      let model = match str_at(o, "model") {
        Some(mm) => Some(mm)
        None => profile_model(get(o, "profile").unwrap_or(Null))
      }
      let x = BridgedSession::make(
        lp,
        kind,
        self.ids,
        session_id,
        bridged_turn(kind, get(Some(r), "turn")),
        get(Some(r), "live").unwrap_or(Null),
        events,
        if kind == "cursor" {
          model
        } else {
          None
        },
      )
      x.own.tools_url = crashed_tools_url(o)
      made.val = Some(x)
      Later::ok(lp, x.own)
    },
    hosting_kind: kind,
    flavor: None,
    kept: false,
    replaying,
    label: _ => "\{kind} \{key}",
    options_of: (_, label) => made.val.unwrap().hosted(label),
    adopted: own => {
      match own.settled() {
        Some(w) => w
        None => done(lp)
      }
    },
  }
  self.own
  .adopt(key, snapshot, events, how)
  .map(_ => {
    let x = made.val.unwrap()
    self.keep(x)
    x
  })
}
