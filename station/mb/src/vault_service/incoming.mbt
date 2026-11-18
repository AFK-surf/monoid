// A command another station of the workspace sends to run here with a secret one of its chats holds a grant for
// (`secret_run` with a station), or whose output it takes as a secret to keep (station/src/vault/incoming.ts): the
// half of the vault that needs no vault, so a rig runs them too. The secret comes with each command over the station
// transport and is in no file here; the command runs in the directory its session's tasks share on this machine,
// answered at once and ended by asking that station back (`vault.done`).

///|
/// A command run with a grant is stopped after this long, unless it asks for less (at most an hour).
pub let run_ms : Double = 10.0 * 60000.0

///|
/// A command printing a secret to keep is stopped after this long.
pub let capture_ms : Double = 2.0 * 60000.0

///|
/// The station's environment, without what would let a command act as the station or its agents' accounts.
pub fn base_env(w : World) -> Array[(String, String)] {
  (w.env)().filter(e => !(
    starts(e.0, "STILLFAIL_") ||
    starts(e.0, "ANTHROPIC_") ||
    starts(e.0, "CLAUDE_") ||
    starts(e.0, "OPENAI_") ||
    starts(e.0, "CODEX_")
  ))
}

///|
/// The commands running here for other stations, by their id: whose, and whether its station took its grant back.
pub struct Incoming {
  w : World
  proxy : Proxy
  incoming : Map[String, (String, Ref[Bool])]
}

///|
pub fn Incoming::new(w : World, proxy : Proxy) -> Incoming {
  { w, proxy, incoming: Map([]) }
}

///|
/// Whether `id` is `x_` and 26 of Crockford's upper-case digits and letters (`/^x_[0-9A-Z]{26}$/`).
fn away_id(id : String) -> Bool {
  if id.length() != 28 || !starts(id, "x_") {
    return false
  }
  for i in 2..<28 {
    let c = id.code_unit_at(i).to_int()
    if !((c >= 48 && c <= 57) || (c >= 65 && c <= 90)) {
      return false
    }
  }
  true
}

///|
/// Whether `s` is a variable's name (`/^[A-Za-z_][A-Za-z0-9_]*$/`).
fn var_name(s : String) -> Bool {
  if s == "" {
    return false
  }
  for i in 0..<s.length() {
    let c = s.code_unit_at(i).to_int()
    let letter = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
    if !(letter || (i > 0 && c >= 48 && c <= 57)) {
      return false
    }
  }
  true
}

///|
/// `vault.capabilities`, `vault.revoke`, `vault.run`, `vault.capture` of station `peer`, asked in workspace `ws`.
pub async fn Incoming::heard(self : Incoming, peer : String, ws : String, request : Json) -> Json {
  let r = match request {
    Object(_) => Some(request)
    _ => None
  }
  let method_ = gtext(r, "method")
  let id = gtext(r, "id")
  if method_ == "vault.capabilities" {
    return obj([("timeouts", jb(true))])
  }
  if method_ == "vault.revoke" {
    match self.incoming.get(id) {
      Some((p, revoked)) if p == peer => {
        revoked.val = true
        return obj([("ok", jb(true))])
      }
      _ => raise Failure("no such command from that station")
    }
  }
  if method_ != "vault.run" && method_ != "vault.capture" {
    raise Failure("unknown method \{method_}")
  }
  let session = gtext(r, "session")
  let command = gtext(r, "command")
  let under = gtext(r, "under")
  let timeout_ms = if safe_int(get(r, "timeoutMs")) {
    gn(r, "timeoutMs").unwrap_or(0.0).max(1.0).min(3600000.0)
  } else {
    run_ms
  }
  if !away_id(id) || session == "" || session.length() > 256 || trim(command) == "" {
    raise Failure("id, session and command are required")
  }
  if starts(under, "/") || splits_dotdot(under) {
    raise Failure("under is a path inside the session's directory")
  }
  let (work_of, ask) = match (self.w.work_of, self.w.ask) {
    (Some(wo), Some(a)) => (wo, a)
    _ => raise Failure("this station runs no commands for others")
  }
  let dir = work_of(ws, peer, session)
  let cwd = if under == "" { dir } else { "\{dir}/\{under}" }
  (self.w.machine.mkdir)(cwd, 0o777)
  let tell = async fn(result : Json) {
    ignore(ask(peer, obj([("method", js("vault.done")), ("workspace", js(ws)), ("id", js(id)), ("result", result)]))) catch {
      e => self.w.warn("vault", "a command's end not told to its station", obj([("error", js(message_of(e)))]))
    }
  }
  // The station does not update itself meanwhile: the proxy or ssh-agent the command uses is this process's.
  let let_go = (self.w.hold)()
  if method_ == "vault.capture" {
    ignore(
      @effect.runtime().fork(name="vault capture", async fn() {
        let got = capture(self.w, command, cwd, base_env(self.w), timeout_ms.min(capture_ms))
        tell(got.to_json())
        let_go()
      }),
    )
    return obj([("started", jb(true))])
  }
  let mode = match gs(r, "mode") {
    Some(m) if @vault_crypto.modes.contains(m) => Some(m)
    _ => None
  }
  let secret = get(r, "secret")
  let hosts = strings_of(get(r, "hosts"))
  let env = match gs(r, "env") {
    Some(e) if var_name(e) => Some(e)
    _ => None
  }
  let grant = gtext(r, "grant")
  let fields_ok = match get(secret, "fields") {
    Some(Object(_)) => true
    Some(Array(_)) => true
    _ => false
  }
  if mode is None || grant == "" || !(secret is Some(Object(_))) || !fields_ok {
    let_go()
    raise Failure("mode, grant and secret are required")
  }
  let fs : Map[String, Json] = Map([])
  if get(secret, "fields") is Some(Object(m)) {
    for k, v in m {
      if v is String(_) {
        fs[k] = v
      }
    }
  }
  let held : @vault_crypto.Held = {
    request: obj([("id", js(grant))]),
    grant: obj([("mode", js(mode.unwrap())), ("hosts", jstrs(hosts))]),
    secret: obj([
      ("kind", js(string_of(get(secret, "kind")))),
      ("name", js(string_of(get(secret, "name")))),
      ("fields", Json::object(fs)),
    ]),
    uses: 0.0,
    until: None,
  }
  if @vault_crypto.value_of(held.secret) is None {
    let_go()
    raise Failure("the secret holds no value")
  }
  let used = Ref(false)
  let revoked = Ref(false)
  self.incoming[id] = (peer, revoked)
  let expires = Ref(
    if safe_int(get(r, "expires")) { gn(r, "expires").unwrap() } else { @double.infinity },
  )
  let grant_timeout = get(r, "grantTimeout")
  let idle = if gs(grant_timeout, "kind") == Some("idle") && safe_int(get(grant_timeout, "seconds")) {
    let s = gn(grant_timeout, "seconds").unwrap()
    if s > 0.0 && s <= 30.0 * 86400.0 { s } else { 0.0 }
  } else {
    0.0
  }
  // What reports a use back to the station asked, one after another (incoming.ts `reports`).
  let reports : @effect.Queue[Unit] = @effect.Queue::unbounded()
  let pending = Ref(0)
  // The run's end waits for the reports given before it (incoming.ts `reports.then(tell)`): woken as the last is
  // answered, never by turning over while one is out (a turn a pause made the runtime give up past its bound).
  let ran_out = Ref(false)
  let reported : @effect.Deferred[Unit] = @effect.Deferred::new()
  let reporter = @effect.runtime().fork(name="vault used", async fn() {
    while true {
      reports.take()
      let answer = ask(peer, obj([("method", js("vault.used")), ("workspace", js(ws)), ("id", js(id))])) catch {
        _ => Json::null()
      }
      if idle > 0.0 && safe_int(get(Some(answer), "until")) {
        expires.val = gn(Some(answer), "until").unwrap()
      }
      pending.val -= 1
      if ran_out.val && pending.val == 0 {
        ignore(reported.succeed(()))
      }
    }
  })
  ignore(
    @effect.runtime().fork(name="vault run", async fn() {
      let ran = run_with(
        self.w,
        held,
        { command, cwd, env, timeout_ms },
        self.proxy,
        base_env(self.w),
        _ => {
          used.val = true
          pending.val += 1
          ignore(reports.try_offer(()))
        },
        allowed=() => !revoked.val && expires.val > self.w.secs(),
      ) catch {
        e => {
          tell(
            obj([
              ("code", Json::null()),
              ("signal", Json::null()),
              ("output", js("could not run it: \{message_of(e)}")),
              ("cut", jb(false)),
              ("timedOut", jb(false)),
            ]),
          )
          self.incoming.remove(id)
          reporter.interrupt()
          let_go()
          return
        }
      }
      ran_out.val = true
      if pending.val > 0 {
        reported.wait() catch {
          _ => ()
        }
      }
      reporter.interrupt()
      tell(spread(Some(ran.to_json()), [("used", jb(used.val))]))
      self.incoming.remove(id)
      let_go()
    }),
  )
  obj([("started", jb(true))])
}

///|
/// Whether `under`, split at `/` or `\` together (`/[\\/]/`), has a `..` part.
fn splits_dotdot(under : String) -> Bool {
  let parts = []
  let b = StringBuilder()
  for i in 0..<under.length() {
    let c = under.code_unit_at(i)
    if c == '/' || c == '\\' {
      parts.push(b.to_string())
      b.reset()
    } else {
      b.write_char(c.to_int().unsafe_to_char())
    }
  }
  parts.push(b.to_string())
  parts.contains("..")
}

///|
/// `String(v ?? "")`.
fn string_of(v : Json?) -> String {
  match v {
    None | Some(Null) => ""
    x => js_text(x)
  }
}
