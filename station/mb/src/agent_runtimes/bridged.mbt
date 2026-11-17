// The sessions of the runtimes the station speaks to through a bridge of its own, a line of JSON per message: dsh.ts
// `DshSession` (its driver plugin), cursor.ts `CursorSession` (its SDK's bridge), pi.ts `PiSession` (Pi's RPC). What
// their lines do to the turn and its live steps is the program's (src/dsh, src/cursor, src/pi); this is what the driver
// writes and how it takes the answers to its requests.

///|
/// Which of them (`dsh`, `cursor`, `pi`).
pub struct Bridged {
  own : Own
  /// Cursor's: the model its next turn runs on (none: the agent's).
  mut model : String?
}

///|
/// A session of `kind` as a driver makes it: its turn (`prompted` too for dsh and Pi) not running.
pub fn Bridged::new(kind : String, session_id : String, turn : Fields, live : J, runner : String, model? : String?) -> Bridged {
  { own: Own::new(kind, session_id, turn, live, runner), model: model.unwrap_or(None) }
}

///|
fn Bridged::kind(self : Bridged) -> String {
  self.own.kind
}

///|
fn Bridged::prompted_kind(self : Bridged) -> Bool {
  self.kind() == "dsh" || self.kind() == "pi"
}

///|
/// `busy`: a turn runs, or (dsh, Pi) one of ours is asked for and has not started yet.
pub fn Bridged::busy(self : Bridged) -> Bool {
  self.own.turn_flag("busy") || (self.prompted_kind() && self.own.turn_flag("prompted"))
}

///|
fn Bridged::idle(self : Bridged) -> Unit {
  self.own.set_flag("busy", false)
  if self.prompted_kind() {
    self.own.set_flag("prompted", false)
  }
}

///|
/// The field a request's name goes in: Pi's `type`, the others' `op`.
fn Bridged::op_field(self : Bridged) -> String {
  if self.kind() == "pi" {
    "type"
  } else {
    "op"
  }
}

///|
/// What refuses an answer: dsh's and Cursor's `error` (dsh's `lacks: "tools"` the station's tools'), Pi's
/// `success: false`.
fn Bridged::refusal(self : Bridged, op : String) -> (J) -> String? {
  let kind = self.kind()
  m => if kind == "pi" {
    if get(Some(m), "success") is Some(Bool(false)) {
      let error = match get(Some(m), "error") {
        None | Some(Null) => "refused"
        e => said(e)
      }
      Some("pi \{op}: \{error}")
    } else {
      None
    }
  } else {
    match get(Some(m), "error") {
      Some(Str(e)) => Some("\{kind} \{op}: \{t(e)}")
      _ => None
    }
  }
}

///|
/// `request`: a request whose answer is waited for (`label` says it in the trace, `then` what is made of it).
pub fn Bridged::request(self : Bridged, id : String, op : String, params : J, label : String, then? : (Result[J, String]) -> Result[J, String] = r => r) -> Unit {
  let own = self.own
  own.wait(id, self.refusal(op), outcome => own.resolved(label, then(outcome)))
  own.write(request_line(id, self.op_field(), op, params))
}

///|
/// `send`: a request whose answer is not waited for.
fn Bridged::send(self : Bridged, op : String, params : J) -> Unit {
  self.own.write(request_line("\{op}:\{self.own.uuid()}", self.op_field(), op, params))
}

///|
/// `heard`: an answer to a request (and Pi's extensions' dialogs, cancelled: nobody is there to answer one).
pub fn Bridged::heard(self : Bridged, line : String) -> Unit {
  guard parse(line) is Some(message) else { return }
  let m = Some(message)
  if self.kind() == "pi" && is_s(get(m, "type"), "extension_ui_request") {
    if get(m, "method") is Some(Str(method)) && ["select", "confirm", "input", "editor"].contains(t(method)) {
      self.own.write(
        stringify(obj([("type", js("extension_ui_response")), ("id", get(m, "id").unwrap_or(Null)), ("cancelled", Bool(true))])),
      )
    }
    return
  }
  // (one refused is the log's)
  self.own.answer(get(m, "id"), message) |> ignore
}

///|
/// `heardHosted`: what the program read of its lines.
pub fn Bridged::heard_hosted(self : Bridged, heard : J?) -> Unit {
  for line in arr(get(heard, "lines")) {
    self.heard(said(get(Some(line), "text")))
  }
  self.own.told(heard, _ => false)
}

///|
/// `prompt`: a turn asked for. Its refusal's words where it cannot start.
pub fn Bridged::prompt(self : Bridged, text : String) -> String? {
  if self.own.startable(self.busy()) is Some(why) {
    return Some(why)
  }
  match self.kind() {
    "cursor" => {
      self.own.set_flag("busy", true)
      self.own.tell("begin")
      let f = Fields::of([("id", js("prompt:\{self.own.uuid()}")), ("op", js("prompt")), ("text", js(text))])
      if self.model is Some(m) {
        f.set_str("model", m)
      }
      self.own.write(stringify(f.json()))
    }
    kind => {
      self.own.set_flag("prompted", true)
      self.own.tell("begin")
      self.send("prompt", obj([(if kind == "pi" { "message" } else { "text" }, js(text))]))
    }
  }
  None
}

///|
/// `steer`: into the running turn; what it is answered (Cursor's: once its bridge says it delivered, `steer:<uuid>`).
/// None while that answer is awaited.
pub fn Bridged::steer(self : Bridged, text : String) -> Bool? {
  if self.kind() == "cursor" {
    if self.own.closed || !self.own.turn_flag("busy") || self.own.turn_flag("aborting") {
      return Some(false)
    }
    self.request(
      "steer:\{self.own.uuid()}",
      "steer",
      obj([("text", js(text))]),
      "steer",
      then=outcome => match outcome {
        Ok(answer) => Ok(Bool(get(Some(answer), "delivered") is Some(Bool(true))))
        Err(_) => Ok(Bool(false))
      },
    )
    return None
  }
  if self.own.closed || !self.busy() {
    return Some(false)
  }
  self.send("steer", obj([(if self.kind() == "pi" { "message" } else { "text" }, js(text))]))
  Some(true)
}

///|
/// `abort`.
pub fn Bridged::abort(self : Bridged) -> Unit {
  let running = if self.kind() == "cursor" { self.own.turn_flag("busy") } else { self.busy() }
  if self.own.closed || !running || self.own.turn_flag("aborting") {
    return
  }
  self.own.set_flag("aborting", true)
  self.own.tell("aborting")
  match self.kind() {
    "cursor" => self.own.write(stringify(obj([("id", js("cancel:\{self.own.uuid()}")), ("op", js("cancel"))])))
    "pi" => self.send("abort", obj([]))
    _ => self.send("cancel", obj([]))
  }
}

///|
/// Cursor's `retune`: another model between turns is the next prompt's (`model`: the options' or the profile's).
pub fn Bridged::retune(self : Bridged, model : String?) -> Bool {
  if self.own.closed || self.own.turn_flag("busy") || self.own.session_id == "" {
    return false
  }
  guard model is Some(m) else { return false }
  self.model = Some(m)
  true
}

///|
/// `exited`.
pub fn Bridged::exited(self : Bridged, said : String, stderr : String) -> Unit {
  let busy = self.busy()
  self.own.exited(said, stderr, busy, () => self.idle(), _ => ())
}

///|
/// `snapshot`: what a next station takes it up from.
pub fn Bridged::snapshot(self : Bridged) -> J {
  let frozen = self.own.hand_over()
  let turn = match present(get(frozen, "turn")) {
    Some(tn) => Some(tn)
    None => Some(self.own.turn_now())
  }
  let live = match present(get(frozen, "live")) {
    Some(l) => l
    None => self.own.live_state
  }
  let f = Fields::of([("runtime", js(self.kind())), ("id", js(self.own.session_id)), ("runner", js(self.own.runner))])
  let tf = Fields::of([("busy", strictly(turn, "busy"))])
  if self.prompted_kind() {
    tf.set("prompted", strictly(turn, "prompted"))
  }
  tf.set("aborting", strictly(turn, "aborting"))
  if self.kind() == "pi" && get(turn, "error") is Some(Str(_) as e) {
    tf.set("error", e)
  }
  f.set("turn", tf.json())
  if !self.own.tools_absent {
    f.set("tools", tools_json(self.own.tools_url))
  }
  f.set("live", live)
  if self.kind() == "cursor" {
    f.set(
      "model",
      match self.model {
        Some(m) => js(m)
        None => Null
      },
    )
  }
  f.json()
}

///|
/// The turn a driver makes a session with: not running.
pub fn idle_turn(kind : String) -> Fields {
  if kind == "cursor" {
    Fields::of([("busy", Bool(false)), ("aborting", Bool(false))])
  } else {
    Fields::of([("busy", Bool(false)), ("prompted", Bool(false)), ("aborting", Bool(false))])
  }
}

///|
/// A turn as `{...base, ...given, closed: false}` makes it (`closed` apart).
fn turn_over(base : Fields, given : J?) -> Fields {
  let f = Fields::of(base.entries())
  for e in spread_of(given) {
    if e.0 != "closed" {
      f.set(e.0, e.1)
    }
  }
  f
}

///|
/// `handedOver`: the session a snapshot says (the station before handed it over).
pub fn Bridged::handed_over(kind : String, handed : J, runner : String) -> Bridged {
  let h = Some(handed)
  let turn = if kind == "pi" { turn_over(idle_turn("pi"), get(h, "turn")) } else { turn_over(Fields::new(), get(h, "turn")) }
  let model = if kind == "cursor" {
    match get(h, "model") {
      Some(Str(m)) => Some(t(m))
      _ => None
    }
  } else {
    None
  }
  let s = Bridged::new(kind, said(get(h, "id")), turn, get(h, "live").unwrap_or(Null), runner, model~)
  s.own.tools_url = str_of(get(h, "tools"))
  s.own.tools_absent = get(h, "tools") is None
  s
}

///|
/// `crashed`: the session the station before had when it crashed, as the program read again what that one handled.
/// `resume` the session the options resume, `model` what Cursor runs on (the options' or the profile's).
pub fn Bridged::crashed(kind : String, replayed : J, resume : String?, mcp_url : String, runner : String, model? : String?) -> Bridged {
  let r = Some(replayed)
  let turn = turn_over(idle_turn(kind), get(r, "turn"))
  let id = if kind == "pi" {
    resume.unwrap_or("")
  } else {
    match get(r, "session") {
      Some(Str(s)) => t(s)
      _ => resume.unwrap_or("")
    }
  }
  let live : J = match get(r, "live") {
    None | Some(Null) => Null
    Some(l) => l
  }
  let s = Bridged::new(kind, id, turn, live, runner, model=if kind == "cursor" { model.unwrap_or(None) } else { None })
  s.own.tools_url = Some(mcp_url)
  s
}
