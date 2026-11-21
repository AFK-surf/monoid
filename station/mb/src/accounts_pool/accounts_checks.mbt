// The accounts' checks and allowances (station/src/accounts/index.ts, its "checks and allowances" part): a profile
// asked whether it works (its models, its reasoning levels, what it can decide with), its allowance read (one at a
// time, an answer that never came leaving the one read before standing a while), a borrowed one's as its host says
// or read with the login it lent, a limit reset redeemed.

///|
/// How a profile is checked (`checkFn`): by the part a test gives, else profiles.ts `checkProfile`.
async fn Accounts::check_fn(self : Accounts, request : JV, lang : String) -> JV {
  if self.given.check == "given" {
    self.ask("check", [request, js(lang)])
  } else {
    self.ask("profiles.checkProfile", [request, js(lang)])
  }
}

///|
/// Whether its allowance can be asked at all (`quotaFn` not null).
fn Accounts::has_quota_fn(self : Accounts) -> Bool {
  self.given.quota != "none"
}

///|
/// `quotaFn`: a profile's allowance, by the part a test gives, else `checkQuota`.
async fn Accounts::quota_fn(self : Accounts, profile : Profile) -> JV {
  if self.given.quota == "given" {
    return self.ask("quota", [profile.raw])
  }
  let version = if self.given.claude_version {
    match self.ask("claudeVersion", []) {
      Str(v) => Some(v)
      _ => None
    }
  } else {
    None
  }
  check_quota(self.ctx, profile, self.given.codex, self.ctx.station_lang, version)
}

///|
/// `resetFn`: a reset redeemed, by the part a test gives, else Claude's here or the codex driver's.
async fn Accounts::reset_fn(
  self : Accounts,
  profile : Profile,
  key : String,
  kind : String?,
) -> JV {
  if self.given.reset_quota == "given" {
    return self.ask("resetQuota", [profile.raw, js(key), jopt(kind)])
  }
  if profile.runtime == Some("claude") {
    return self.claude_reset(profile, key, kind)
  }
  if !self.given.codex {
    raise refusal(503, self.tr(self.ctx.station_lang, "station.quota.resetUnsupported"))
  }
  self.ask("codex.resetQuota", [profile.raw, js(key)])
}

///|
/// `discoverFn`: what a profile can decide with (decision.ts `discover`).
async fn Accounts::discover_fn(self : Accounts, profile : Profile, check : JV) -> JV {
  if self.given.discover == "given" {
    self.ask("discover", [profile.raw, check])
  } else {
    self.ask("decision.discover", [profile.raw, check])
  }
}

///|
/// decision.ts `fingerprint`, asked of it.
async fn Accounts::fingerprint(self : Accounts, profile : Profile) -> String {
  js_string(Some(self.ask("decision.fingerprint", [profile.raw])))
}

///|
/// `JSON.stringify(v ?? null)`, undefined itself where it is left out and not to be defaulted.
fn json_text(v : JV?) -> String {
  match v {
    None => "\u{0}undefined"
    Some(x) => stringify(x)
  }
}

///|
/// `keepCheck`: a check kept, stamped, stored and told. The check as kept.
fn Accounts::keep_check(self : Accounts, id : String, check : JV) -> JV {
  let check = jset(check, "checkedAt", jnum(self.background.now()))
  let before = self.checks.get(id)
  self.checks[id] = check
  self.hub_cache = None
  self.background.track(async fn() {
    self.b.with_store(s => s.set_profile_check(Json::string(id), jv_to_json(check)))
  })
  let before_models = match jget(before, "models") {
    None => Some(JV::Null)
    x => x
  }
  let before_fusion = match jget(before, "fusion") {
    None => Some(JV::Null)
    x => x
  }
  let check_fusion = match check.get("fusion") {
    None => Some(JV::Null)
    x => x
  }
  if json_text(before_models) != json_text(check.get("models")) ||
    json_text(before_fusion) != json_text(check_fusion) {
    self.uncheck_soon()
  }
  self.changed()
  check
}

///|
/// `codexLogin`: a Codex provider refusal outlives `codex login status`; a successful allowance read clears it.
fn Accounts::codex_login(
  self : Accounts,
  id : String,
  revoked : Bool,
  lang : String,
) -> Unit {
  let before = self.checks.get(id)
  if revoked {
    let base = match before {
      Some(b) => b
      None => jobj([("models", Null), ("checkedAt", jint(0))])
    }
    let mut next = jset(base, "state", js("login"))
    next = jset(next, "detail", js(self.tr(lang, "station.quota.codexLogin")))
    next = jset(next, "codexRevoked", jbool(true))
    ignore(self.keep_check(id, next))
  } else if is_truthy(jget(before, "codexRevoked")) {
    let kept = jdel(before.unwrap(), "codexRevoked")
    let mut next = jset(kept, "state", js("ok"))
    next = jset(next, "detail", js(self.tr(lang, "station.profile.signedIn")))
    ignore(self.keep_check(id, next))
  }
}

///|
fn via_jv(v : Via) -> JV {
  let fields = []
  match v.provider {
    Some(p) => fields.push(("provider", js(p)))
    None => ()
  }
  match v.endpoint {
    Some(e) => fields.push(("endpoint", js(e)))
    None => ()
  }
  match v.protocol {
    Some(p) => fields.push(("protocol", js(p)))
    None => ()
  }
  jobj(fields)
}

///|
/// `check`: POST /profiles/:id/check: asks the provider or runtime whether the profile works, its models, its
/// reasoning levels and what it can decide with.
pub async fn Accounts::check(self : Accounts, id : String, lang : String) -> JV {
  guard self.profile(id) is Some(profile) else {
    raise refusal(404, "unknown profile \{id}")
  }
  if !profile.enabled {
    raise refusal(
      409,
      self.tr(lang, "station.profile.disabled", args=[("profile", profile.name)]),
    )
  }
  let kind = access_kind(profile.raw)
  if borrowed(profile.raw) && kind == "subscription" && self.given.shared {
    return self.check_borrowed(profile, lang)
  }
  let kimi = kimi_signed_in(profile.raw)
  if kimi {
    self.renew_kimi(id)
  }
  let kimi_login = if kimi { read_kimi(self.ctx.io, profile.home) } else { None }
  let key = if kimi {
    match kimi_login {
      Some(l) => l.access
      None => ""
    }
  } else {
    trim_js(
      match jget(profile.get("access"), "key") {
        None | Some(Null) => ""
        v => js_string(v)
      },
    )
  }
  let signed_out = kimi &&
    (match kimi_login {
      Some(l) => l.refresh
      None => ""
    }) ==
    ""
  let mut check = self.check_fn(
    jobj([
      ("runtime", jopt(profile.runtime)),
      ("service", jopt(profile.service)),
      ("kind", js(kind)),
      ("key", js(if signed_out { "" } else { key })),
      ("via", via_jv(profile_via(profile.raw))),
      ("home", js(profile.home)),
      ("machine", jbool(profile.machine)),
      ("login", jbool(jget(profile.get("access"), "login") == Some(Bool(true)))),
    ]),
    lang,
  )
  let codex_subscription = kind == "subscription" && profile.runtime == Some("codex")
  let state = () => jstr(check.get("state"))
  if (state() == Some("ok") || state() == Some("unknown")) &&
    profile.runtimes.contains("codex") &&
    self.given.codex {
    let listed = async fn() {
      let catalog = self.ask("codex.models", [profile.raw])
      if codex_subscription && check.get("models") == Some(Null) {
        check = jset(check, "models", catalog.get("models").unwrap_or(jundef))
      }
      check = jset(
        check,
        "modelEfforts",
        jobj([("codex", catalog.get("efforts").unwrap_or(Obj([])))]),
      )
      if catalog.get("ultrafastModels") is Some(Arr(_) as speeds) {
        check = jset(check, "codexUltrafastModels", speeds)
      }
      match catalog.get("defaults") {
        Some(d) if !is_undef(d) =>
          check = jset(check, "modelEffortDefaults", jobj([("codex", d)]))
        _ => ()
      }
    }
    listed() catch {
      e => {
        match self.checks.get(id) {
          Some(previous) => {
            match previous.get("modelEfforts") {
              Some(m) => check = jset(check, "modelEfforts", m)
              None => ()
            }
            match previous.get("modelEffortDefaults") {
              Some(m) => check = jset(check, "modelEffortDefaults", m)
              None => ()
            }
            if previous.get("codexUltrafastModels") is Some(m) {
              check = jset(check, "codexUltrafastModels", m)
            }
            if codex_subscription && check.get("models") == Some(Null) {
              check = jset(check, "models", previous.get("models").unwrap_or(jundef))
            }
          }
          None => ()
        }
        check = jset(
          check,
          "detail",
          js(
            self.tr(lang, "station.profile.modelsStale", args=[
              ("detail", js_string(check.get("detail"))),
            ]),
          ),
        )
        self.log("warn", "could not list codex model capabilities", [
          ("profile", js(id)),
          ("error", js(message_of(e))),
        ])
      }
    }
  }
  if profile.runtime == Some("hermes") && self.given.hermes {
    let listed = async fn() {
      let models = jitems(Some(self.ask("hermes.models", [profile.raw])))
      check = jset(check, "models", jarr(models))
      check = jset(
        check,
        "state",
        js(if models.length() > 0 { "ok" } else { "unknown" }),
      )
      let n = models.length()
      let key = if n >= hermes_model_limit {
        "station.profile.hermesModelsLimited"
      } else if n > 0 {
        "station.profile.works"
      } else {
        "station.profile.hermesModelsEmpty"
      }
      check = jset(
        check,
        "detail",
        js(
          self.tr(lang, key, args=[
            ("n", n.to_string()),
            ("limit", hermes_model_limit.to_string()),
          ]),
        ),
      )
    }
    listed() catch {
      e => {
        check = jset(
          check,
          "models",
          match jget(self.checks.get(id), "models") {
            Some(m) => m
            None => Null
          },
        )
        check = jset(check, "state", js("unknown"))
        check = jset(
          check,
          "detail",
          js(
            self.tr(lang, "station.profile.hermesModelsFailed", args=[
              ("error", message_of(e)),
            ]),
          ),
        )
      }
    }
  }
  if profile.runtime == Some("agy") &&
    (state() == Some("ok") || state() == Some("unknown")) &&
    self.given.agy {
    let listed = async fn() {
      if self.given.agy_catalog {
        let catalog = self.ask("agy.catalog", [profile.raw])
        check = jset(check, "models", catalog.get("models").unwrap_or(jundef))
        check = jset(
          check,
          "modelEfforts",
          jobj([("agy", catalog.get("efforts").unwrap_or(Obj([])))]),
        )
        let company = jget(profile.get("access"), "enterprise") == Some(Bool(true))
        match catalog.get("plan") {
          Some(Str(p)) => check = jset(check, "plan", js(p))
          _ =>
            if company && check.get("plan") is None {
              check = jset(check, "plan", js("Enterprise"))
            }
        }
        match catalog.get("defaults") {
          Some(Obj(f) as d) if f.length() > 0 =>
            check = jset(check, "modelEffortDefaults", jobj([("agy", d)]))
          _ => ()
        }
      } else {
        check = jset(check, "models", self.ask("agy.models", [profile.raw]))
      }
      check = jset(check, "state", js("ok"))
      check = jset(
        check,
        "detail",
        js(
          self.tr(lang, "station.profile.works", args=[
            ("n", jitems(check.get("models")).length().to_string()),
          ]),
        ),
      )
    }
    listed() catch {
      e => {
        let error = message_of(e)
        check = jset(check, "models", Null)
        if kind == "subscription" &&
          self.ask("agy.classifyFailure", [js(error)]) == Str("auth") {
          check = jset(check, "state", js("login"))
          check = jset(check, "detail", js(self.tr(lang, "station.profile.signedOut")))
        } else {
          check = jset(check, "state", js("failed"))
          check = jset(
            check,
            "detail",
            js(self.tr(lang, "station.profile.agyFailed", args=[("error", error)])),
          )
        }
      }
    }
  }
  if kind != "service" {
    check = jset(check, "decision", self.discover_fn(profile, check))
  }
  let now = self.profile(id)
  let same = match now {
    Some(n) => self.fingerprint(n) == self.fingerprint(profile)
    None => false
  }
  if !same {
    raise refusal(409, self.tr(lang, "station.profile.changedRecheck"))
  }
  if profile.machine && kind == "subscription" && state() == Some("ok") {
    let logins = jitems(Some(self.ask("machine.get", [])))
    let login = match profile.runtime {
      Some(r) =>
        logins
        .iter()
        .find_first(l => l.get("runtime") == Some(Str(r)) && is_truthy(l.get("loggedIn")))
      None => None
    }
    match jget(login, "plan") {
      Some(Str(p)) if trim_js(p) != "" => check = jset(check, "plan", js(trim_js(p)))
      _ => ()
    }
  }
  let previous = self.checks.get(id)
  match previous {
    Some(prev) if check.get("models") == Some(Null) &&
      prev.get("models") != Some(Null) &&
      prev.get("models") is Some(_) => {
      check = jset(check, "models", prev.get("models").unwrap())
      if check.get("modelEfforts") is None && prev.get("modelEfforts") is Some(m) {
        check = jset(check, "modelEfforts", m)
      }
      if check.get("modelEffortDefaults") is None &&
        prev.get("modelEffortDefaults") is Some(m) {
        check = jset(check, "modelEffortDefaults", m)
      }
      if check.get("codexUltrafastModels") is None && prev.get("codexUltrafastModels") is Some(m) {
        check = jset(check, "codexUltrafastModels", m)
      }
      if check.get("fusion") is None && prev.get("fusion") is Some(m) {
        check = jset(check, "fusion", m)
      }
    }
    _ => ()
  }
  if codex_subscription && is_truthy(jget(previous, "codexRevoked")) {
    check = jset(check, "state", js("login"))
    check = jset(check, "detail", jget(previous, "detail").unwrap_or(jundef))
    check = jset(check, "codexRevoked", jbool(true))
  }
  check = self.keep_check(id, check)
  if check.get("state") == Some(Str("ok")) && !self.quotas.contains(id) {
    self.background.spawn(async fn() { ignore(self.refresh_quota(id)) })
  }
  check
}

///|
/// `checkBorrowed`: a copy of another station's subscription: how it is doing is what its host says.
async fn Accounts::check_borrowed(self : Accounts, profile : Profile, lang : String) -> JV {
  let id = profile.id
  let asked = async fn() -> JV {
    let got = self.ask("shared.status", [profile.raw])
    let got_quota = got.get("quota")
    let check = match got.get("check") {
      Some(Obj(_) as c) => c
      _ =>
        jobj([
          ("state", js("unknown")),
          ("detail", js("")),
          ("models", Null),
          ("checkedAt", jint(0)),
        ])
    }
    let local = self.checks.get(id)
    let mine = self.quotas.get(id)
    let now = self.background.now()
    let complete_here = self.missing_borrowed_reset_details(profile, got_quota) &&
      (match mine {
        Some(m) =>
          !self.missing_borrowed_reset_details(profile, Some(m)) &&
          m.get("resetCount") == jget(got_quota, "resetCount") &&
          to_number(m.get("checkedAt")) <= now &&
          now - to_number(m.get("checkedAt")) < quota_every_ms
        None => false
      })
    let older = match mine {
      Some(m) =>
        to_number(
          match jget(got_quota, "checkedAt") {
            None | Some(Null) => Some(Num(0.0))
            x => x
          },
        ) <
        to_number(m.get("checkedAt"))
      None => false
    }
    // A reading the same as the one kept (rechecks while the host has not read again) is not written again.
    let same = match mine {
      Some(m) => json_text(got_quota) == stringify(m)
      None => false
    }
    match got_quota {
      Some(Obj(_) as q) if !is_truthy(jget(local, "codexRevoked")) &&
        !complete_here &&
        !same &&
        !older => {
        self.quotas[id] = q
        self.keep_quota(id, q)
      }
      _ => ()
    }
    self.refresh_missing_borrowed_reset_details(profile)
    check
  }
  let mut check = asked() catch {
    _ => {
      let host = if self.given.shared_host_name {
        match self.ask("shared.hostName", [profile.raw]) {
          Null => ""
          h => js_string(Some(h))
        }
      } else {
        ""
      }
      jobj([
        ("state", js("failed")),
        ("detail", js(self.tr(lang, "station.share.hostOffline", args=[("host", host)]))),
        ("models", Null),
        ("checkedAt", jint(0)),
      ])
    }
  }
  let local = self.checks.get(id)
  if is_truthy(jget(local, "codexRevoked")) {
    check = if check.get("state") == Some(Str("failed")) {
      jset(check, "codexRevoked", jbool(true))
    } else {
      let c = jset(check, "state", js("login"))
      let c = jset(c, "detail", jget(local, "detail").unwrap_or(jundef))
      jset(c, "codexRevoked", jbool(true))
    }
  }
  self.keep_check(id, check)
}

///|
fn Accounts::missing_borrowed_reset_details(
  _self : Accounts,
  profile : Profile,
  q : JV?,
) -> Bool {
  if profile.runtime != Some("codex") || !borrowed(profile.raw) {
    return false
  }
  match q {
    Some(Obj(_) as quota) =>
      match quota.get("resetCount") {
        Some(Num(n)) if is_integer(n) && n > 0.0 =>
          match quota.get("resetExpiries") {
            Some(Arr(e)) => e.length().to_double() < n
            _ => true
          }
        _ => false
      }
    _ => false
  }
}

///|
/// `refreshMissingBorrowedResetDetails`: an older host's fresh count is not a fresh reading of the expiry details.
fn Accounts::refresh_missing_borrowed_reset_details(
  self : Accounts,
  profile : Profile,
) -> Unit {
  let q = self.quotas.get(profile.id)
  if !self.given.shared ||
    !self.missing_borrowed_reset_details(profile, q) ||
    self.quota_busy.contains(profile.id) {
    return
  }
  let now = self.background.now()
  let count = to_number(jget(q, "resetCount"))
  match self.reset_details_asked.get(profile.id) {
    Some((at, c)) if c == count && now - at < quota_every_ms => return
    _ => ()
  }
  self.reset_details_asked[profile.id] = (now, count)
  let id = profile.id
  self.background.spawn(async fn() { ignore(self.refresh_quota(id)) })
}

///|
/// `refreshQuota`: POST /profiles/:id/quota.
pub async fn Accounts::refresh_quota(self : Accounts, id : String) -> JV? {
  self.read_quota(id, false)
}

///|
fn Accounts::quota_asked_at(self : Accounts, id : String) -> Double {
  let a = match jget(self.quotas.get(id), "checkedAt") {
    None | Some(Null) => 0.0
    x => to_number(x)
  }
  let b = match self.quota_unanswered.get(id) {
    Some((_, at)) => at
    None => 0.0
  }
  js_max(a, b)
}

///|
/// `askedQuota`: the same asked by a person, who is told what came of it.
pub async fn Accounts::asked_quota(self : Accounts, id : String) -> JV? {
  match self.quota_busy.get(id) {
    Some(busy) => busy.wait()
    None => ignore(self.read_quota(id, false))
  }
  match self.quota_unanswered.get(id) {
    Some((detail, _)) => raise refusal(502, detail)
    None => ()
  }
  self.quotas.get(id)
}

///|
/// `readQuota`: one question at a time; a read after a reset waits for any older one.
async fn Accounts::read_quota(self : Accounts, id : String, after_reset : Bool) -> JV? {
  let busy = self.quota_busy.get(id)
  if busy is Some(_) && !after_reset {
    return self.quotas.get(id)
  }
  let done = @effect.Deferred::new()
  self.quota_busy[id] = done
  let run = async fn() -> JV? {
    match busy {
      Some(b) => b.wait()
      None => ()
    }
    self.ask_quota(id, !after_reset)
  }
  let result = run() catch {
    e => {
      ignore(done.succeed(()))
      match self.quota_busy.get(id) {
        Some(d) if physical_equal(d, done) => self.quota_busy.remove(id)
        _ => ()
      }
      raise e
    }
  }
  ignore(done.succeed(()))
  match self.quota_busy.get(id) {
    Some(d) if physical_equal(d, done) => self.quota_busy.remove(id)
    _ => ()
  }
  result
}

///|
/// `askQuota`: `stands`: whether the allowance read before stands where this question gets no answer.
async fn Accounts::ask_quota(self : Accounts, id : String, stands : Bool) -> JV? {
  guard self.profile(id) is Some(profile) else {
    raise refusal(404, "unknown profile \{id}")
  }
  if !profile.enabled {
    self.quota_unanswered.remove(id)
    return self.quotas.get(id)
  }
  let generation = self.login_generation.get(id).unwrap_or(0)
  let lang = self.ctx.station_lang
  if borrowed(profile.raw) && access_kind(profile.raw) == "subscription" && self.given.shared {
    let now = self.background.now()
    let mut own = if profile.runtime == Some("codex") {
      lent_codex_usage(self.ctx, profile.home, now, lang) catch {
        _ => None
      }
    } else {
      None
    }
    let signed_out = (q : JV?) => is_truthy(jget(q, "signedOut"))
    if profile.runtime == Some("codex") &&
      (own is None || signed_out(own)) &&
      self.given.shared_lend_codex {
      let lend = async fn() {
        ignore(self.ask("shared.lendCodex", [profile.raw, jbool(true)]))
        let refreshed = lent_codex_usage(self.ctx, profile.home, self.background.now(), lang)
        if jget(refreshed, "state") == Some(Str("ok")) {
          own = refreshed
          if self.given.codex && self.given.codex_login_changed {
            ignore(self.ask("codex.loginChanged", [js(id)]))
          }
        } else if signed_out(refreshed) {
          own = refreshed
        }
      }
      lend() catch {
        _ => ()
      }
    }
    if jget(own, "state") == Some(Str("ok")) {
      let read = jset(jdel(own.unwrap(), "signedOut"), "checkedAt", jnum(now))
      self.quotas[id] = read
      self.keep_quota(id, read)
      if profile.runtime == Some("codex") {
        self.codex_login(id, false, lang)
      }
      self.changed()
      return Some(read)
    }
    if signed_out(own) {
      let read = jset(
        jdel(own.unwrap(), "signedOut"),
        "checkedAt",
        jnum(self.background.now()),
      )
      self.quotas[id] = read
      self.keep_quota(id, read)
      self.codex_login(id, true, lang)
      self.changed()
      return Some(read)
    }
    ignore(self.check_borrowed(profile, lang)) catch {
      _ => ()
    }
    return self.quotas.get(id)
  }
  if !self.has_quota_fn() {
    return self.quotas.get(id)
  }
  let answer = self.quota_fn(profile)
  let signed_out = answer.get("signedOut") == Some(Bool(true))
  let no_answer = answer.get("unanswered") == Some(Bool(true))
  let recheck = answer.get("recheck") == Some(Bool(true))
  let asked = jdel(jdel(jdel(answer, "signedOut"), "unanswered"), "recheck")
  if self.login_generation.get(id).unwrap_or(0) != generation {
    return self.quotas.get(id)
  }
  let before = self.quotas.get(id)
  match before {
    Some(b) if stands &&
      no_answer &&
      b.get("state") == Some(Str("ok")) &&
      self.background.now() - to_number(b.get("checkedAt")) < quota_stands_ms => {
      self.quota_unanswered[id] = (
        match asked.get("detail") {
          None | Some(Null) => ""
          d => js_string(d)
        },
        self.background.now(),
      )
      return Some(b)
    }
    _ => ()
  }
  self.quota_unanswered.remove(id)
  let mut current = asked
  let mut refused = signed_out
  if profile.runtime == Some("codex") && access_kind(profile.raw) == "subscription" && refused {
    let fresh = codex_usage(self.ctx, join_path([profile.home, "auth.json"]), lang) catch {
      _ => None
    }
    if self.login_generation.get(id).unwrap_or(0) != generation {
      return self.quotas.get(id)
    }
    if jget(fresh, "state") == Some(Str("ok")) {
      if self.given.codex && self.given.codex_login_changed {
        ignore(self.ask("codex.loginChanged", [js(id)]))
      }
      if self.login_generation.get(id).unwrap_or(0) != generation {
        return self.quotas.get(id)
      }
      current = fresh.unwrap()
      refused = false
    }
  }
  let read = jset(current, "checkedAt", jnum(self.background.now()))
  self.quotas[id] = read
  self.keep_quota(id, read)
  self.changed()
  if profile.runtime == Some("codex") && access_kind(profile.raw) == "subscription" {
    if refused {
      self.codex_login(id, true, lang)
    } else if read.get("state") == Some(Str("ok")) {
      self.codex_login(id, false, lang)
    }
  } else if signed_out && jget(self.checks.get(id), "state") != Some(Str("login")) {
    self.background.spawn(async fn() {
      ignore(self.check(id, self.ctx.station_lang)) catch {
        _ => ()
      }
    })
  } else if recheck && jget(self.checks.get(id), "state") == Some(Str("ok")) {
    self.background.spawn(async fn() {
      ignore(self.check(id, self.ctx.station_lang)) catch {
        _ => ()
      }
    })
  } else if profile.runtime == Some("claude") &&
    access_kind(profile.raw) == "subscription" &&
    read.get("state") == Some(Str("ok")) &&
    (jget(self.checks.get(id), "state") == Some(Str("failed")) ||
      jget(self.checks.get(id), "state") == Some(Str("login"))) {
    self.background.spawn(async fn() {
      ignore(self.check(id, self.ctx.station_lang)) catch {
        _ => ()
      }
    })
  }
  Some(read)
}

///|
/// `refreshQuotas`: asks again every profile's allowance older than a round (all of them, `all`).
pub fn Accounts::refresh_quotas(self : Accounts, all : Bool) -> Unit {
  if !self.has_quota_fn() {
    return
  }
  let now = self.background.now()
  for p in self.profiles() {
    if !p.enabled {
      continue
    }
    let fresh = self.quotas.contains(p.id) &&
      now - self.quota_asked_at(p.id) < quota_every_ms - 1000.0
    if fresh && !all {
      self.refresh_missing_borrowed_reset_details(p)
      continue
    }
    let id = p.id
    self.background.spawn(async fn() { ignore(self.refresh_quota(id)) })
  }
}

///|
/// `recheckBorrowed`: copies of other stations' subscriptions checked again.
pub fn Accounts::recheck_borrowed(self : Accounts) -> Unit {
  for p in self.profiles() {
    if borrowed(p.raw) && access_kind(p.raw) == "subscription" {
      let id = p.id
      self.background.spawn(async fn() {
        ignore(self.check(id, self.ctx.station_lang)) catch {
          _ => ()
        }
      })
    }
  }
}

///|
/// `lentLoginVersion`: which login a borrowed Codex process will read.
async fn Accounts::lent_login_version(self : Accounts, home : String) -> String? {
  guard self.ctx.io.read_file_or_none(join_path([home, "auth.json"])) is Some(text) else {
    return None
  }
  guard try_parse(text) is Some(j) else { return None }
  let tokens = j.get("tokens")
  let pick = (k : String) => match jget(tokens, k) {
    None => JV::Null
    Some(v) => v
  }
  Some(@hash.sha256_utf8_hex(stringify(jarr([pick("id_token"), pick("access_token"), pick("account_id")]))))
}

///|
/// `sharedChanged`: a shared profile changed on its host.
pub async fn Accounts::shared_changed(self : Accounts, id : String, reset : Bool) -> Unit {
  let profile = self.profile(id)
  match profile {
    Some(p) if !p.enabled && self.given.hub_profile_gone =>
      ignore(self.ask("hub.profileGone", [js(id)]))
    _ => ()
  }
  guard profile is Some(profile) else { return }
  if !borrowed(profile.raw) ||
    access_kind(profile.raw) != "subscription" ||
    !self.given.shared {
    return
  }
  ignore(self.check_borrowed(profile, self.ctx.station_lang))
  if profile.runtime == Some("codex") && self.given.shared_lend_codex {
    let before = match self.borrowed_login.get(id) {
      Some(b) => b
      None => self.lent_login_version(profile.home)
    }
    if !self.borrowed_login.contains(id) {
      self.borrowed_login[id] = before
    }
    ignore(self.ask("shared.lendCodex", [profile.raw, jbool(true)]))
    let after = self.lent_login_version(profile.home)
    if before != after {
      self.login_generation[id] = self.login_generation.get(id).unwrap_or(0) + 1
      self.codex_account_read(profile, true) catch {
        _ => ()
      }
      if self.given.codex && self.given.codex_login_changed {
        ignore(self.ask("codex.loginChanged", [js(id)]))
      }
    }
    self.borrowed_login[id] = after
    ignore(self.read_quota(id, true))
    if reset && self.given.hub_allowance_reset {
      ignore(self.ask("hub.allowanceReset", [js(id)]))
    }
  }
  if profile.runtime == Some("agy") && self.given.shared_lend_agy {
    ignore(self.ask("shared.lendAgy", [profile.raw, jbool(true)])) catch {
      _ => ()
    }
    if self.given.hub_profile_login_changed {
      ignore(self.ask("hub.profileLoginChanged", [js(id)]))
    }
  }
  ignore(self.check_borrowed(profile, self.ctx.station_lang))
}

///|
/// `sharedQuotaReset`: another station redeemed a reset on a subscription hosted here.
pub async fn Accounts::shared_quota_reset(self : Accounts, id : String) -> Unit {
  ignore(self.read_quota(id, true))
  if self.given.hub_allowance_reset {
    ignore(self.ask("hub.allowanceReset", [js(id)]))
  }
}

///|
/// `followed`: the first follower of the events came.
pub fn Accounts::followed(self : Accounts) -> Unit {
  self.refresh_quotas(false)
}

///|
/// `resetQuota`: POST /profiles/:id/reset-quota: a subscription's rate-limit reset redeemed under the request's key.
pub async fn Accounts::reset_quota(
  self : Accounts,
  id : String,
  key : String,
  lang : String,
  kind : String?,
) -> JV {
  let t = (k : String) => self.tr(lang, k)
  guard self.profile(id) is Some(profile) else {
    raise refusal(404, t("station.profile.notFound"))
  }
  if (profile.runtime != Some("codex") && profile.runtime != Some("claude")) ||
    access_kind(profile.raw) != "subscription" {
    raise refusal(400, t("station.quota.resetSubscriptionOnly"))
  }
  if self.given.reset_quota == "none" {
    raise refusal(503, t("station.quota.resetUnsupported"))
  }
  let result = self.reset_fn(profile, key, kind)
  let quota = self.read_quota(id, true) catch {
    e => {
      self.log("warn", "could not read the allowance after a reset", [
        ("profile", js(id)),
        ("error", js(message_of(e))),
      ])
      None
    }
  }
  let outcome = jget(Some(result), "outcome")
  if outcome == Some(Str("reset")) || outcome == Some(Str("alreadyRedeemed")) {
    let all_under = jget(quota, "state") == Some(Str("ok")) &&
      jitems(jget(quota, "windows")).iter().all(w => to_number(w.get("usedPercent")) < 100.0)
    if outcome == Some(Str("reset")) || all_under {
      if self.given.shared && self.given.shared_quota_reset {
        ignore(self.ask("shared.quotaReset", [profile.raw, js(key)])) catch {
          e =>
            self.log("warn", "could not record a shared allowance reset", [
              ("profile", js(id)),
              ("error", js(message_of(e))),
            ])
        }
      }
      if self.given.hub_allowance_reset {
        ignore(self.ask("hub.allowanceReset", [js(id)]))
      }
    }
    return result
  }
  if outcome == Some(Str("nothingToReset")) {
    raise refusal(409, t("station.quota.nothingToReset"))
  }
  if outcome == Some(Str("noCredit")) {
    raise refusal(409, t("station.quota.noCredit"))
  }
  if outcome == Some(Str("unavailable")) {
    raise refusal(409, t("station.quota.resetUnavailable"))
  }
  raise refusal(502, t("station.quota.resetUnconfirmed"))
}
