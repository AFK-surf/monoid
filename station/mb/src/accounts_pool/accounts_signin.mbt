// The accounts' new profiles and sign-ins (station/src/accounts/index.ts, its `newKeyedProfile`, `newMachineProfile`
// and sign-ins part): a keyed profile made once its key works, one on the machine's own login, a subscription signed
// in (again) or before there is a profile (made once it succeeds, named by the account), the OpenCode Console's and
// Kimi's tokens renewed, a profile checked and its allowance read once it signed in, the outdated models unchecked.

///|
pub let login_browser_file : String = ".stillfail-login-state.json"

///|
pub let default_new_subscription_max_concurrent_sessions : Int = 8

///|
/// `EMAIL_RE`: /^[^\s@]+@[^\s@]+\.[^\s@]+$/.
pub fn email_ok(s : String) -> Bool {
  if has_space(s) {
    return false
  }
  let parts = split_on(s, "@")
  if parts.length() != 2 || parts[0] == "" {
    return false
  }
  let d = parts[1]
  for i in 1..<(d.length() - 1) {
    if d.unsafe_charcode_at(i) == '.'.to_int() {
      return true
    }
  }
  false
}

///|
/// `newKeyedProfile`: POST /profiles, a new keyed profile, made only once its key is checked and works. Its id.
pub async fn Accounts::new_keyed_profile(
  self : Accounts,
  input : JV,
  viewer : JV,
  lang : String,
) -> String {
  let t = (k : String, args : Array[(String, String)]) => self.tr(lang, k, args~)
  let access = match input.get("access") {
    Some(Obj(_)) as a => a
    _ => None
  }
  let kind_said = match jget(access, "kind") {
    None => ""
    Some(k) => stringify(k)
  }
  let kind = match access_kind_of(jget(access, "kind")) {
    Some(k) => k
    None => raise refusal(400, "unknown access \{kind_said}")
  }
  if kind == "subscription" {
    raise refusal(400, t("station.profile.subscriptionBySignIn", []))
  }
  let field = (k : String) => match jget(access, k) {
    Some(Str(v)) if trim_js(v) != "" => Some(trim_js(v))
    _ => None
  }
  let provider = field("provider")
  let given_endpoint = field("endpoint")
  let given_protocol = field("protocol")
  let mut src : Source? = None
  if kind == "api-provider" {
    src = match provider {
      Some(p) if !legacy_source(p) => find_source(p)
      _ => None
    }
    guard src is Some(s) else {
      raise refusal(400, t("station.profile.unknownProvider", []))
    }
    let chosen = if s.endpoint_required {
      match given_protocol {
        Some(p) => Some(p)
        None => if s.protocols.length() == 1 { Some(s.protocols[0]) } else { None }
      }
    } else {
      None
    }
    if endpoints(s, given_endpoint, chosen) is None {
      raise refusal(400, t("station.profile.addressNeeded", []))
    }
  }
  let endpoint = match (src, given_endpoint) {
    (Some(_), Some(e)) => clean_endpoint(e)
    _ => None
  }
  let protocol = match src {
    Some(s) if s.endpoint_required =>
      match s.protocols.iter().find_first(p => Some(p) == given_protocol) {
        Some(p) => Some(p)
        None => s.protocols.get(0)
      }
    _ => None
  }
  let runtimes = match src {
    Some(s) => {
      let a = [
        ("kind", js(kind)),
        ("provider", js(s.id)),
      ]
      if endpoint is Some(e) {
        a.push(("endpoint", js(e)))
      }
      if protocol is Some(p) {
        a.push(("protocol", js(p)))
      }
      runtimes_for(Some(jobj(a)), None)
    }
    None => runtimes_of_kind(kind, runtime_kind(input.get("runtime")))
  }
  if (runtimes.length() == 0 && src is None) ||
    !runtimes.iter().all(r => access_kinds(r).contains(kind)) {
    raise refusal(400, "unknown access \{kind}")
  }
  let runtime = runtimes.get(0).unwrap_or("claude")
  let key = match jget(access, "key") {
    Some(Str(k)) => trim_js(k)
    _ => ""
  }
  if needs_key(kind, src.map(s => s.id)) && key == "" {
    raise refusal(400, t("station.profile.keyRequired", []))
  }
  let homes = join_path([self.given.data, "homes"])
  let trial = join_path([homes, "new-\{self.ctx.io.random_hex(4)}"])
  self.ctx.io.mkdir(trial)
  let via = via_jv({ provider: src.map(s => s.id), endpoint, protocol })
  let check = self.check_fn(
    jobj([
      ("runtime", js(runtime)),
      ("kind", js(kind)),
      ("key", js(key)),
      ("via", via),
      ("home", js(trial)),
      ("machine", jbool(false)),
    ]),
    lang,
  )
  let refused = match src {
    Some(_) => check.get("state") == Some(Str("failed"))
    None => check.get("state") != Some(Str("ok")) && keyed(kind)
  }
  if refused {
    self.ctx.io.rm(trial)
    raise refusal(
      400,
      t("station.profile.checkFailed", [("detail", js_string(check.get("detail")))]),
    )
  }
  let label = match src {
    Some(s) => s.name
    None =>
      if kind == "opencode-go" {
        "OpenCode Go"
      } else if kind == "anthropic-api" {
        "Anthropic API"
      } else {
        t("station.profile.envName", [("runtime", runtime_label(runtime))])
      }
  }
  let base = match src {
    Some(s) => s.id
    None => if kind == "env" { "\{runtime}-env" } else { kind }
  }
  let id = unique_id(base, self.taken_ids())
  self.making[id] = ()
  let moved = async fn() { self.ctx.io.rename(trial, join_path([homes, id])) }
  moved() catch {
    e => {
      self.making.remove(id)
      self.ctx.io.rm(trial)
      raise e
    }
  }
  let saved = async fn() {
    self.save(viewer, "profile \{id}", raw => {
      let made = [("id", js(id)), ("name", js(label))]
      if kind == "env" {
        made.push(("runtime", js(runtime)))
      }
      let a = [("kind", js(kind))]
      if key != "" {
        a.push(("key", js(key)))
      }
      match src {
        Some(s) => a.push(("provider", js(s.id)))
        None => ()
      }
      match endpoint {
        Some(e) => a.push(("endpoint", js(e)))
        None => ()
      }
      match protocol {
        Some(p) => a.push(("protocol", js(p)))
        None => ()
      }
      made.push(("access", jobj(a)))
      made.push(("home", js("homes/\{id}")))
      made.push(("env", Obj([])))
      let list = profiles_of_raw(raw)
      list.push(jobj(made))
      jset(raw, "profiles", jarr(list))
    })
  }
  saved() catch {
    e => {
      self.making.remove(id)
      raise e
    }
  }
  self.making.remove(id)
  ignore(self.keep_check(id, check))
  match self.profile(id) {
    Some(p) if p.runtime == Some("hermes") => self.after_sign_in(id)
    Some(_) =>
      self.background.spawn(async fn() {
        ignore(self.check(id, lang)) catch {
          _ => ()
        }
      })
    None => ()
  }
  id
}

///|
/// `newMachineProfile`: POST /profiles/machine, a profile on the machine's own login of a runtime. Its id.
pub async fn Accounts::new_machine_profile(
  self : Accounts,
  input : JV,
  viewer : JV,
  lang : String,
) -> String {
  let t = (k : String, args : Array[(String, String)]) => self.tr(lang, k, args~)
  guard runtime_kind(input.get("runtime")) is Some(runtime) else {
    raise refusal(400, "unknown runtime \{text_of(input.get("runtime"))}")
  }
  let id = "machine-\{runtime}"
  let used = () => self.making.contains(id) || self.profiles().iter().any(p => p.id == id)
  if used() {
    raise refusal(409, t("station.machine.alreadyUsed", []))
  }
  if !self.given.machine {
    raise refusal(400, t("station.machine.unreadable", []))
  }
  ignore(self.ask("machine.refresh", []))
  let login = jitems(Some(self.ask("machine.get", []))).iter().find_first(l => l.get("runtime") ==
    Some(Str(runtime)))
  if !is_truthy(jget(login, "loggedIn")) {
    raise refusal(
      400,
      t("station.machine.notSignedIn", [("runtime", runtime_label(runtime))]),
    )
  }
  if !is_truthy(jget(login, "usable")) {
    raise refusal(400, t("station.machine.keychain", []))
  }
  if used() {
    raise refusal(409, t("station.machine.alreadyUsed", []))
  }
  self.making[id] = ()
  let run = async fn() {
    let home = join_path([self.given.data, "homes", id])
    self.ctx.io.mkdir(home)
    if runtime == "codex" {
      ignore(self.ask("machine.linkCodexAuth", [js(home)]))
    }
    let name = match jget(login, "email") {
      None | Some(Null) => runtime_label(runtime)
      e => js_string(e)
    }
    self.log("info", "profile on the machine's login made", [
      ("profile", js(id)),
      ("runtime", js(runtime)),
      ("by", viewer.get("email").unwrap_or(jundef)),
    ])
    self.save(viewer, "profile \{id} on the machine's login", raw => {
      let made = jobj([
        ("id", js(id)),
        ("name", js(name)),
        ("runtime", js(runtime)),
        ("access", jobj([("kind", js("subscription"))])),
        ("home", js("homes/\{id}")),
        ("env", Obj([])),
        ("machine", jbool(true)),
      ])
      let list = profiles_of_raw(raw)
      list.push(made)
      jset(raw, "profiles", jarr(list))
    })
  }
  run() catch {
    e => {
      self.making.remove(id)
      raise e
    }
  }
  self.making.remove(id)
  self.after_sign_in(id)
  id
}

///|
/// `loginStateFile`: where `id`'s sign-in browser keeps its cookies and passkeys (None once dropped or failed).
pub async fn Accounts::login_state_file(self : Accounts, id : String) -> String? {
  match self.profile(id) {
    Some(p) =>
      return if p.machine || borrowed(p.raw) {
        None
      } else {
        Some(join_path([p.home, login_browser_file]))
      }
    None => ()
  }
  guard self.pending.get(id) is Some(pending) else { return None }
  match pending.created {
    Some(made) =>
      return match self.profile(made) {
        Some(m) => Some(join_path([m.home, login_browser_file]))
        None => None
      }
    None => ()
  }
  let state = jget(Some(self.ask("logins.get", [js(id)])), "state")
  if state == Some(Str("failed")) || state == Some(Str("cancelled")) {
    return None
  }
  Some(join_path([pending.home, login_browser_file]))
}

///|
fn home_job(id : String, home : String) -> JV {
  jobj([("id", js(id)), ("home", js(home))])
}

///|
/// `startLogin`: POST /profiles/:id/login, a subscription profile signed in (again).
pub async fn Accounts::start_login(
  self : Accounts,
  id : String,
  viewer : JV,
  lang : String,
) -> JV {
  guard self.profile(id) is Some(profile) else {
    raise refusal(404, "unknown profile \{id}")
  }
  let kind = access_kind(profile.raw)
  let kimi = kimi_signed_in(profile.raw)
  if kind == "service" {
    if borrowed(profile.raw) {
      raise refusal(409, self.tr(lang, "station.share.borrowedEdit"))
    }
    let svc = jstr(jget(profile.get("access"), "service"))
    if svc != Some("colab") {
      raise refusal(400, self.tr(lang, "station.admin.loginSubscriptionOnly"))
    }
    let s = svc.unwrap()
    self.log("info", "service login started from the admin page", [
      ("profile", js(id)),
      ("service", js(s)),
      ("by", viewer.get("email").unwrap_or(jundef)),
    ])
    let fields = [("id", js(id)), ("service", js(s)), ("home", js(profile.home))]
    match self.service_email(s, profile.home) {
      Some(e) => fields.push(("email", js(e)))
      None => ()
    }
    return self.ask("logins.startService", [jobj(fields), js(lang)])
  }
  if kind != "subscription" && kind != "opencode-go" && !kimi {
    raise refusal(400, self.tr(lang, "station.admin.loginSubscriptionOnly"))
  }
  if profile.machine {
    raise refusal(400, self.tr(lang, "station.admin.loginOnMachine"))
  }
  if borrowed(profile.raw) {
    raise refusal(409, self.tr(lang, "station.share.borrowedEdit"))
  }
  self.log("info", "login started from the admin page", [
    ("profile", js(id)),
    ("by", viewer.get("email").unwrap_or(jundef)),
  ])
  if kind == "opencode-go" {
    return self.ask("logins.startConsole", [home_job(id, profile.home), js(lang)])
  }
  if kimi {
    return self.ask("logins.startKimi", [home_job(id, profile.home), js(lang)])
  }
  if profile.runtime == Some("cursor") {
    return self.ask("logins.startCursor", [home_job(id, profile.home), js(lang)])
  }
  if profile.runtime == Some("agy") {
    let enterprise = jget(profile.get("access"), "enterprise") == Some(Bool(true)) ||
      self.ask("agy.company", [
          js(
            self.ctx.io.read_file_or_none(
              join_path([profile.home, "agy", ".gemini", "antigravity-cli", "antigravity-oauth-token"]),
            ).unwrap_or(""),
          ),
        ]) ==
        Bool(true)
    let fields = [("id", js(id)), ("runtime", js("agy")), ("home", js(profile.home))]
    if enterprise {
      fields.push(("enterprise", jbool(true)))
    }
    return self.ask("logins.start", [jobj(fields), js(lang)])
  }
  guard profile.runtime is Some(runtime) else {
    raise refusal(400, self.tr(lang, "station.profile.loginUnsupported"))
  }
  let mut email : String? = None
  if runtime == "claude" {
    let from_home = self.account_email(runtime, profile.home)
    let fallback = if email_ok(trim_js(profile.name)) {
      Some(trim_js(profile.name))
    } else {
      None
    }
    let candidate = match from_home {
      Some(e) => trim_js(e)
      None =>
        match fallback {
          Some(f) => trim_js(f)
          None => ""
        }
    }
    email = if email_ok(candidate) { Some(candidate) } else { None }
  }
  let fields = [
    ("id", js(id)),
    ("runtime", js(runtime)),
    ("home", js(profile.home)),
  ]
  match email {
    Some(e) => fields.push(("email", js(e)))
    None => ()
  }
  self.ask("logins.start", [jobj(fields), js(lang)])
}

///|
/// `newLogin`: POST /logins, signing a subscription in before there is a profile. `{id, job}`.
pub async fn Accounts::new_login(
  self : Accounts,
  input : JV,
  viewer : JV,
  lang : String,
) -> JV {
  let id = "login-\{self.ctx.io.random_hex(4)}"
  let home = join_path([self.given.data, "homes", id])
  match input.get("service") {
    Some(Str(svc)) if svc != "" => {
      if svc != "colab" {
        raise refusal(400, "unknown service \{svc}")
      }
      self.pending[id] = {
        runtime: None,
        service: Some(svc),
        access: None,
        home,
        by: viewer,
        created: None,
        error: None,
      }
      self.log("info", "service sign-in for a new profile started", [
        ("login", js(id)),
        ("service", js(svc)),
        ("by", viewer.get("email").unwrap_or(jundef)),
      ])
      let job = self.ask("logins.startService", [
        jobj([("id", js(id)), ("service", js(svc)), ("home", js(home))]),
        js(lang),
      ])
      return jobj([("id", js(id)), ("job", job)])
    }
    _ => ()
  }
  let access = input.get("access")
  if access == Some(Str("opencode-go")) {
    self.pending[id] = {
      runtime: None,
      service: None,
      access: Some("opencode-go"),
      home,
      by: viewer,
      created: None,
      error: None,
    }
    self.log("info", "OpenCode sign-in for a new profile started", [
      ("login", js(id)),
      ("by", viewer.get("email").unwrap_or(jundef)),
    ])
    let job = self.ask("logins.startConsole", [home_job(id, home), js(lang)])
    return jobj([("id", js(id)), ("job", job)])
  }
  if access == Some(Str("kimi-code")) {
    self.pending[id] = {
      runtime: None,
      service: None,
      access: Some("kimi-code"),
      home,
      by: viewer,
      created: None,
      error: None,
    }
    self.log("info", "Kimi sign-in for a new profile started", [
      ("login", js(id)),
      ("by", viewer.get("email").unwrap_or(jundef)),
    ])
    let job = self.ask("logins.startKimi", [home_job(id, home), js(lang)])
    return jobj([("id", js(id)), ("job", job)])
  }
  if access == Some(Str("agy-enterprise")) {
    self.pending[id] = {
      runtime: Some("agy"),
      service: None,
      access: Some("agy-enterprise"),
      home,
      by: viewer,
      created: None,
      error: None,
    }
    self.log("info", "company Google sign-in for a new profile started", [
      ("login", js(id)),
      ("by", viewer.get("email").unwrap_or(jundef)),
    ])
    let job = self.ask("logins.start", [
      jobj([
        ("id", js(id)),
        ("runtime", js("agy")),
        ("home", js(home)),
        ("enterprise", jbool(true)),
      ]),
      js(lang),
    ])
    return jobj([("id", js(id)), ("job", job)])
  }
  guard runtime_kind(input.get("runtime")) is Some(runtime) else {
    raise refusal(400, "unknown runtime \{text_of(input.get("runtime"))}")
  }
  self.pending[id] = { runtime: Some(runtime), service: None, access: None, home, by: viewer, created: None, error: None }
  self.log("info", "sign-in for a new profile started", [
    ("login", js(id)),
    ("runtime", js(runtime)),
    ("by", viewer.get("email").unwrap_or(jundef)),
  ])
  let job = if runtime == "cursor" {
    self.ask("logins.startCursor", [home_job(id, home), js(lang)])
  } else {
    self.ask("logins.start", [
      jobj([("id", js(id)), ("runtime", js(runtime)), ("home", js(home))]),
      js(lang),
    ])
  }
  jobj([("id", js(id)), ("job", job)])
}

///|
/// `hasPending`.
pub fn Accounts::has_pending(self : Accounts, id : String) -> Bool {
  self.pending.contains(id)
}

///|
/// `dropLogin`: DELETE /logins/:id, its command stopped, its home removed unless it made one.
pub async fn Accounts::drop_login(self : Accounts, id : String) -> Unit {
  guard self.pending.get(id) is Some(pending) else { return }
  self.pending.remove(id)
  ignore(self.ask("logins.cancel", [js(id)]))
  self.changed()
  if pending.created is None {
    self.ctx.io.rm(pending.home)
  }
}

///|
/// `pendingChanged`: one at a time for an id; what it is told meanwhile settled once the one under way is.
async fn Accounts::pending_changed(self : Accounts, id : String) -> Unit {
  if self.settling.contains(id) {
    self.settling[id] = true
    return
  }
  let run = async fn() {
    while true {
      self.settling[id] = false
      self.pending_settled(id)
      if self.settling.get(id) != Some(true) {
        break
      }
    }
  }
  run() catch {
    e => {
      self.settling.remove(id)
      raise e
    }
  }
  self.settling.remove(id)
}

///|
/// `pendingSettled`.
async fn Accounts::pending_settled(self : Accounts, id : String) -> Unit {
  guard self.pending.get(id) is Some(p) else { return }
  let state = jget(Some(self.ask("logins.get", [js(id)])), "state")
  if state == Some(Str("failed")) || state == Some(Str("cancelled")) {
    self.ctx.io.rm(p.home)
    return
  }
  if state != Some(Str("done")) || p.created is Some(_) || p.error is Some(_) {
    return
  }
  let lang = self.ctx.station_lang
  let gone = () => (match self.pending.get(id) {
      Some(q) => !physical_equal(q, p)
      None => true
    }) ||
    p.created is Some(_) ||
    p.error is Some(_)
  let signed_in = if p.access == Some("opencode-go") {
    match self.ask("console.read", [js(p.home)]) {
      Obj(_) as l => Some(l)
      _ => None
    }
  } else {
    None
  }
  if gone() {
    return
  }
  if p.access == Some("opencode-go") && signed_in is None {
    return self.pending_failed(id, self.tr(lang, "station.login.consoleUnreadable"))
  }
  let kimi = p.access == Some("kimi-code")
  let kimi_login = if kimi { read_kimi(self.ctx.io, p.home) } else { None }
  if gone() {
    return
  }
  if kimi && kimi_login is None {
    return self.pending_failed(id, self.tr(lang, "station.login.kimiUnreadable"))
  }
  let email = match signed_in {
    Some(s) => jstr(s.get("email"))
    None =>
      if kimi {
        None
      } else {
        match p.service {
          Some(svc) => self.service_email(svc, p.home)
          None =>
            match p.runtime {
              Some(r) => self.account_email(r, p.home)
              None => None
            }
        }
      }
  }
  if gone() {
    return
  }
  let base = if signed_in is Some(_) {
    "opencode-go"
  } else if kimi {
    kimi_code
  } else {
    match p.service {
      Some(svc) => {
        let s = slug(email.unwrap_or(svc), 40)
        if s == "" { svc } else { s }
      }
      None => {
        let rt = p.runtime.unwrap_or("profile")
        let s = slug(email.unwrap_or("\{rt}-subscription"), 40)
        if s == "" {
          rt
        } else {
          s
        }
      }
    }
  }
  let taken = self.taken_ids()
  if gone() {
    return
  }
  let profile_id = unique_id(base, taken)
  let target = join_path([self.given.data, "homes", profile_id])
  self.making[profile_id] = ()
  let run = async fn() {
    self.made_of_login(id, p, profile_id, target, signed_in, kimi, email, lang, gone)
  }
  run() catch {
    e => {
      self.making.remove(profile_id)
      raise e
    }
  }
  self.making.remove(profile_id)
}

///|
/// `madeOfLogin`: profile `profile_id` made of sign-in `id`: its home moved to `target`, the profile saved.
async fn Accounts::made_of_login(
  self : Accounts,
  id : String,
  p : Pending,
  profile_id : String,
  target : String,
  signed_in : JV?,
  kimi : Bool,
  email : String?,
  lang : String,
  gone : () -> Bool,
) -> Unit {
  let moved = async fn() { self.ctx.io.rename(p.home, target) }
  let failed_move = moved() catch {
    e => Some(e)
  } noraise {
    _ => None
  }
  match failed_move {
    Some(e) => {
      if gone() {
        return
      }
      self.log("warn", "could not move a new profile's home", [
        ("login", js(id)),
        ("error", js(message_of(e))),
      ])
      return self.pending_failed(
        id,
        self.tr(lang, "station.login.homeFailed", args=[("error", message_of(e))]),
      )
    }
    None => ()
  }
  if gone() {
    self.ctx.io.rm(target)
    return
  }
  let enterprise = p.access == Some("agy-enterprise")
  let name = match signed_in {
    Some(_) => email.unwrap_or("OpenCode Go")
    None =>
      if kimi {
        "Kimi Code"
      } else {
        match p.service {
          Some(svc) => email.unwrap_or(if svc == "colab" { "Google Colab" } else { svc })
          None =>
            if enterprise {
              match email {
                Some(e) => e
                None => self.tr(lang, "station.profile.agyEnterpriseSubscription")
              }
            } else {
              match email {
                Some(e) => e
                None =>
                  match p.runtime {
                    Some("claude") => self.tr(lang, "station.profile.claudeSubscription")
                    Some("codex") => self.tr(lang, "station.profile.chatgptSubscription")
                    Some("grok") => self.tr(lang, "station.profile.grokSubscription")
                    Some("cursor") => self.tr(lang, "station.profile.cursorSubscription")
                    Some("devin") => self.tr(lang, "station.profile.devinSubscription")
                    Some("agy") => self.tr(lang, "station.profile.agySubscription")
                    Some(r) => r
                    None => profile_id
                  }
              }
            }
        }
      }
  }
  let save = async fn() {
    self.save(p.by, "profile \{profile_id} from a sign-in", raw => {
      let max_sessions = jint(default_new_subscription_max_concurrent_sessions)
      let made = match signed_in {
        Some(s) =>
          jobj([
            ("id", js(profile_id)),
            ("name", js(name)),
            (
              "access",
              jobj([
                ("kind", js("opencode-go")),
                ("key", s.get("access").unwrap_or(jundef)),
                ("login", jbool(true)),
              ]),
            ),
            ("home", js("homes/\{profile_id}")),
            ("env", Obj([])),
            ("maxConcurrentSessions", max_sessions),
            ("newAccountProtection", jbool(true)),
          ])
        None =>
          if kimi {
            jobj([
              ("id", js(profile_id)),
              ("name", js(name)),
              (
                "access",
                jobj([
                  ("kind", js("api-provider")),
                  ("provider", js(kimi_code)),
                  ("login", jbool(true)),
                ]),
              ),
              ("home", js("homes/\{profile_id}")),
              ("env", Obj([])),
              ("maxConcurrentSessions", max_sessions),
              ("newAccountProtection", jbool(true)),
            ])
          } else {
            match p.service {
              Some(svc) =>
                jobj([
                  ("id", js(profile_id)),
                  ("name", js(name)),
                  (
                    "access",
                    jobj([
                      ("kind", js("service")),
                      ("service", js(svc)),
                    ]),
                  ),
                  ("home", js("homes/\{profile_id}")),
                  ("env", Obj([])),
                ])
              None =>
                jobj([
                  ("id", js(profile_id)),
                  ("name", js(name)),
                  ("runtime", jopt(p.runtime)),
                  (
                    "access",
                    if enterprise {
                      jobj([("kind", js("subscription")), ("enterprise", jbool(true))])
                    } else {
                      jobj([("kind", js("subscription"))])
                    },
                  ),
                  ("home", js("homes/\{profile_id}")),
                  ("env", Obj([])),
                  ("maxConcurrentSessions", max_sessions),
                  ("newAccountProtection", jbool(true)),
                ])
            }
          }
      }
      let list = profiles_of_raw(raw)
      list.push(made)
      jset(raw, "profiles", jarr(list))
    })
  }
  let failed_save = save() catch {
    e => Some(e)
  } noraise {
    _ => None
  }
  match failed_save {
    Some(e) => {
      self.log("warn", "the signed-in profile was not saved", [
        ("login", js(id)),
        ("error", js(message_of(e))),
      ])
      let back = async fn() { self.ctx.io.rename(target, p.home) }
      back() catch {
        _ => ()
      }
      return self.pending_failed(
        id,
        self.tr(lang, "station.login.saveFailed", args=[("error", message_of(e))]),
      )
    }
    None => ()
  }
  p.created = Some(profile_id)
  self.changed()
  self.after_sign_in(profile_id)
  ignore(
    self.background.after(pending_kept_ms, async fn() { self.drop_login(id) }),
  )
}

///|
fn Accounts::pending_failed(self : Accounts, id : String, error : String) -> Unit {
  match self.pending.get(id) {
    Some(p) => p.error = Some(error)
    None => ()
  }
  self.changed()
}

///|
/// `signedInConsole`: an OpenCode Go profile just signed in to the OpenCode Console: the token in its home is its key
/// now. Whether its key was set.
async fn Accounts::signed_in_console(
  self : Accounts,
  id : String,
  started_at : Double,
) -> Bool {
  let login = match self.profile(id) {
    Some(p) =>
      match self.ask("console.read", [js(p.home)]) {
        Obj(_) as l => Some(l)
        _ => None
      }
    None => None
  }
  let now = self.profile(id)
  let job = self.ask("logins.get", [js(id)])
  let current = match now {
    Some(n) => access_kind(n.raw) == "opencode-go"
    None => false
  }
  if !current ||
    jget(Some(job), "state") != Some(Str("done")) ||
    to_number(job.get("startedAt")) != started_at {
    return false
  }
  guard login is Some(login) else {
    self.log("warn", "an OpenCode sign-in left no token", [("profile", js(id))])
    return false
  }
  let set = async fn() {
    self.set_console_key(id, login.get("access").unwrap_or(jundef), "signed in to OpenCode")
  }
  set() catch {
    e => {
      self.log("warn", "the OpenCode sign-in was not saved", [
        ("profile", js(id)),
        ("error", js(message_of(e))),
      ])
      return false
    }
  }
  true
}

///|
/// `setConsoleKey`: the key of a profile signed in to the OpenCode Console, set to its current token.
async fn Accounts::set_console_key(
  self : Accounts,
  id : String,
  key : JV,
  why : String,
) -> Unit {
  ignore(
    self.update_config(raw => {
      let list = profiles_of_raw(raw)
      guard list.search_by(x => x.get("id") == Some(Str(id))) is Some(i) else {
        raise plain_error("unknown profile \{id}")
      }
      list[i] = jset(
        list[i],
        "access",
        jobj([("kind", js("opencode-go")), ("key", key), ("login", jbool(true))]),
      )
      jset(raw, "profiles", jarr(list))
    }),
  )
  self.log("info", "OpenCode token saved as the profile's key", [
    ("profile", js(id)),
    ("why", js(why)),
  ])
}

///|
async fn Accounts::wall_now(self : Accounts) -> Double {
  to_number(Some(self.ask("wall.now", [])))
}

///|
/// `renewConsoles`: each profile signed in to the OpenCode Console whose token runs out within 7 days, renewed.
fn Accounts::renew_consoles(self : Accounts) -> Unit {
  for p in self.profiles() {
    if access_kind(p.raw) != "opencode-go" ||
      jget(p.get("access"), "login") != Some(Bool(true)) ||
      borrowed(p.raw) {
      continue
    }
    let home = p.home
    let id = p.id
    self.background.spawn(async fn() {
      let login = self.ask("console.read", [js(home)])
      guard login is Obj(_) else { return }
      if to_number(login.get("expiresAt")) - self.wall_now() > console_renew_before_ms {
        return
      }
      self.renew_console(id)
    })
  }
}

///|
/// `renewConsole`: renews a profile's OpenCode Console token now (once at a time: its refresh token is spent).
pub async fn Accounts::renew_console(self : Accounts, id : String) -> Unit {
  match self.renewing.get(id) {
    Some(busy) => {
      busy.wait()
      return
    }
    None => ()
  }
  let done = @effect.Deferred::new()
  self.renewing[id] = done
  let run = async fn() {
    let profile = self.profile(id)
    let login = match profile {
      Some(p) =>
        match self.ask("console.read", [js(p.home)]) {
          Obj(_) as l => Some(l)
          _ => None
        }
      None => None
    }
    guard profile is Some(profile) && login is Some(login) else { return }
    let token = self.ask("console.renew", [
        js(self.ctx.url("console").unwrap_or("")),
        login.get("refresh").unwrap_or(jundef),
      ]) catch {
      e => {
        self.log("warn", "could not renew an OpenCode token", [
          ("profile", js(id)),
          ("error", js(message_of(e))),
        ])
        if kind_of(e) == "RenewRefused" {
          ignore(self.check(id, self.ctx.station_lang)) catch {
            _ => ()
          }
        }
        return
      }
    }
    let org = match token.get("org") {
      None | Some(Null) => login.get("org").unwrap_or(jundef)
      o => o.unwrap()
    }
    let mut next = jset(login, "access", token.get("access").unwrap_or(jundef))
    next = jset(next, "refresh", token.get("refresh").unwrap_or(jundef))
    next = jset(next, "expiresAt", jnum(self.wall_now() + to_number(token.get("expiresInMs"))))
    next = jset(next, "org", org)
    ignore(self.ask("console.write", [js(profile.home), next]))
    let now = self.profile(id)
    let still = match now {
      Some(n) =>
        access_kind(n.raw) == "opencode-go" &&
        jget(n.get("access"), "login") == Some(Bool(true))
      None => false
    }
    if !still {
      self.log(
        "info",
        "an OpenCode token renewed for a profile no longer signed in to it; its key left as it is",
        [("profile", js(id))],
      )
      return
    }
    self.set_console_key(id, token.get("access").unwrap_or(jundef), "renewed")
  }
  let failure = run() catch {
    e => Some(e)
  } noraise {
    _ => None
  }
  self.renewing.remove(id)
  ignore(done.succeed(()))
  match failure {
    Some(e) => raise e
    None => ()
  }
}

///|
/// `renewKimis`: each profile signed in to Kimi whose token is due, renewed.
fn Accounts::renew_kimis(self : Accounts) -> Unit {
  for p in self.profiles() {
    if !kimi_signed_in(p.raw) || borrowed(p.raw) {
      continue
    }
    let home = p.home
    let id = p.id
    self.background.spawn(async fn() {
      guard read_kimi(self.ctx.io, home) is Some(login) else { return }
      if !kimi_due(login, self.wall_now()) {
        return
      }
      self.renew_kimi(id)
    })
  }
}

///|
/// `renewKimi`: renews a profile's Kimi token now (once at a time); a token not yet due stays, and one signed out (its
/// refresh token refused, then dropped) is not asked again until it is signed in again.
pub async fn Accounts::renew_kimi(self : Accounts, id : String) -> Unit {
  match self.renewing.get(id) {
    Some(busy) => {
      busy.wait()
      return
    }
    None => ()
  }
  let done = @effect.Deferred::new()
  self.renewing[id] = done
  let refused = Ref(false)
  let run = async fn() {
    let profile = self.profile(id)
    let login = match profile {
      Some(p) => read_kimi(self.ctx.io, p.home)
      None => None
    }
    guard profile is Some(profile) && login is Some(login) else { return }
    if login.refresh == "" || !kimi_due(login, self.wall_now()) {
      return
    }
    let token = renew_kimi_token(
        self.ctx.io,
        self.ctx.url("kimi").unwrap_or(kimi_auth),
        login.refresh,
        login.device_id,
      ) catch {
      e => {
        self.log("warn", "could not renew a Kimi token", [
          ("profile", js(id)),
          ("error", js(message_of(e))),
        ])
        if kind_of(e) == "RenewRefused" {
          write_kimi(self.ctx.io, profile.home, { ..login, refresh: "" })
          refused.val = true
        }
        return
      }
    }
    write_kimi(self.ctx.io, profile.home, {
      ..login,
      access: token.access,
      refresh: token.refresh,
      expires_at: self.wall_now() + token.expires_in_ms,
      life_ms: token.expires_in_ms,
    })
  }
  let failure = run() catch {
    e => Some(e)
  } noraise {
    _ => None
  }
  self.renewing.remove(id)
  ignore(done.succeed(()))
  match failure {
    Some(e) => raise e
    None => ()
  }
  if refused.val {
    ignore(self.check(id, self.ctx.station_lang)) catch {
      _ => ()
    }
  }
}

///|
/// `afterSignIn`: a profile just signed in: checked and its allowance read, so its page shows them at once.
fn Accounts::after_sign_in(self : Accounts, id : String) -> Unit {
  self.auth_revoked.remove(id)
  let profile = self.profile(id)
  match profile {
    Some(p) if p.runtime == Some("codex") && access_kind(p.raw) == "subscription" => {
      self.login_generation[id] = self.login_generation.get(id).unwrap_or(0) + 1
      self.codex_login(id, false, self.ctx.station_lang)
      self.background.track(async fn() {
        self.codex_account_read(p, true) catch {
          _ => ()
        }
      })
    }
    _ => ()
  }
  match profile {
    Some(p) if access_kind(p.raw) == "subscription" &&
      !borrowed(p.raw) &&
      self.given.shared &&
      self.given.shared_login_updated =>
      self.background.track(async fn() {
        ignore(self.ask("shared.loginUpdated", [js(id)]))
      })
    _ => ()
  }
  self.background.spawn(async fn() {
    let profile = self.profile(id)
    match profile {
      Some(p) if p.runtime == Some("agy") && self.given.hub_profile_login_changed => {
        let run = async fn() { ignore(self.ask("hub.profileLoginChanged", [js(id)])) }
        run() catch {
          e =>
            self.log(
              "warn",
              "could not restart the Antigravity CLI's sessions after sign-in",
              [("profile", js(id)), ("error", js(message_of(e)))],
            )
        }
      }
      _ => ()
    }
    match profile {
      Some(p) if p.runtime == Some("codex") && self.given.codex && self.given.codex_login_changed => {
        let run = async fn() { ignore(self.ask("codex.loginChanged", [js(id)])) }
        run() catch {
          e =>
            self.log("warn", "could not replace the codex app-server after sign-in", [
              ("profile", js(id)),
              ("error", js(message_of(e))),
            ])
        }
      }
      _ => ()
    }
    let checked = async fn() { ignore(self.check(id, self.ctx.station_lang)) }
    checked() catch {
      e =>
        self.log("warn", "check after sign-in failed", [
          ("profile", js(id)),
          ("error", js(message_of(e))),
        ])
    }
    ignore(self.read_quota(id, true))
  })
}

///|
/// `uncheckOutdated`: the models outdated on this station's profiles unchecked, each once (models.ts, asked of it).
async fn Accounts::uncheck_outdated(self : Accounts) -> Unit {
  let found = Map::new()
  for f in self.checks.iter() {
    match jget(Some(f.1), "models") {
      Some(Arr(m)) => {
        let all = m.copy()
        for x in expand_devin_fusion(f.1.get("fusion")) {
          all.push(js(x))
        }
        found[f.0] = jarr(all)
      }
      _ => ()
    }
  }
  let mut found_jv = JV::Obj([])
  for f in found.iter() {
    found_jv = jset(found_jv, f.0, f.1)
  }
  let unchecked = async fn(raw : JV) -> (JV, Array[JV], Array[String]) {
    let done = jitems(raw.get("outdatedUnchecked")).filter_map(x => jstr(Some(x)))
    let said = self.ask("models.uncheckOutdated", [raw, found_jv, jstrs(done)])
    let changes = jitems(said.get("changes"))
    let now = done.copy()
    for u in jitems(said.get("unchecked")) {
      let s = js_string(Some(u))
      if !now.contains(s) {
        now.push(s)
      }
    }
    let seen : Array[String] = []
    for s in now {
      if !seen.contains(s) {
        seen.push(s)
      }
    }
    stable_sort(seen, (a, b) => js_compare(a, b).to_double())
    (said.get("raw").unwrap_or(raw), changes, seen)
  }
  let (_, first_changes, _) = unchecked(self.config_raw)
  if first_changes.length() == 0 {
    return
  }
  let (next_raw, changes, now) = unchecked(self.config_raw)
  let run = async fn() {
    ignore(
      self.update_config(_ => jset(next_raw, "outdatedUnchecked", jstrs(now))),
    )
  }
  run() catch {
    e => {
      self.log("warn", "could not uncheck the outdated models", [
        ("error", js(message_of(e))),
      ])
      return
    }
  }
  for c in changes {
    self.log("info", "outdated models unchecked", [
      ("profile", c.get("profile").unwrap_or(jundef)),
      (
        "removed",
        js(jitems(c.get("removed")).map(x => js_string(Some(x))).join(" ")),
      ),
      ("added", js(jitems(c.get("added")).map(x => js_string(Some(x))).join(" "))),
    ])
  }
}

///|
/// `newModels`: the catalog named models it had not: the profiles whose check found a model of one of their makers
/// are checked again.
pub fn Accounts::new_models(self : Accounts, keys : Array[String]) -> Unit {
  let makers : Array[String] = []
  for k in keys {
    match jget(self.catalog.facts(k), "maker") {
      Some(Str(m)) => makers.push(m)
      Some(Null) | None => ()
      Some(other) => makers.push(js_string(Some(other)))
    }
  }
  if makers.length() == 0 {
    return
  }
  let ids = self
    .profiles()
    .filter(p => p.enabled &&
      jitems(jget(self.checks.get(p.id), "models")).iter().any(m => {
        let maker = match jget(self.catalog.facts(js_string(Some(m))), "maker") {
          Some(Str(x)) => x
          _ => ""
        }
        makers.contains(maker)
      }))
    .map(p => p.id)
  if ids.length() == 0 {
    return
  }
  self.background.track(async fn() {
    self.log("info", "new models in the catalog: their makers' profiles checked again", [
      ("models", js(keys.join(" "))),
      ("profiles", js(ids.join(" "))),
    ])
  })
  self.background.spawn(async fn() {
    self.check_each(ids, self.ctx.station_lang) catch {
      _ => ()
    }
  })
}

///|
/// `checkEach`: checks the profiles, four at a time; throws the first refusal once all are done.
async fn Accounts::check_each(
  self : Accounts,
  ids : Array[String],
  lang : String,
) -> Unit {
  let errors : Array[Error] = []
  let next = Ref(0)
  let worker = async fn() -> Unit {
    while next.val < ids.length() {
      let id = ids[next.val]
      next.val += 1
      ignore(self.check(id, lang)) catch {
        e => errors.push(e)
      }
    }
  }
  ignore(@effect.all([worker, worker, worker, worker]))
  if errors.length() > 0 {
    raise errors[0]
  }
}
