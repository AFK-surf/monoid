// The package asked line by line (reader `--builder harness-accounts-pool`), for station/test/mb-accounts-pool.test.ts
// to hold it to the TypeScript it is the MoonBit of (station/src/accounts/{index,quota,agy-quota,claude-reset,cursor,
// kimi,check,pace}.ts, station/src/sessions/accounts.ts and the pool's station/src/sessions/pool.ts). The first line
// is `{"setup": {zh, en, product, stationLang, data, urls, given, config, catalog, tzOffsetMs, now, sessions,
// asksAllows, tellsMoved}}`, answered `{"ready": true}`. Then:
// - `{"ask": id, "op", "args": [...]}`, answered `{"ans": id, "value"}` or `{"ans": id, "error": {kind, message,
//   status}}`: a function of the package's, or a method of the accounts (`accounts.*`) or of the session accounts
//   (`sessions.*`), made at setup;
// - every call of a part goes to the test, `{"call": n, "name", "args"}`, answered `{"ret": n, "value"}` or
//   `{"ret": n, "throw": {kind, message, status, code, name}}`;
// - `{"advance": ms}`: the clock moved to `ms`, every timer due by then run in turn, answered `{"advanced": ms}`;
// - `{"settle": id}`: answered `{"settled": id}` once nothing the accounts set going runs.

///|
priv struct Timer {
  due : Double
  seq : Int
  f : () -> Unit
  mut alive : Bool
}

///|
priv struct World {
  host : @host.Host
  waiting : Map[Int, @effect.Deferred[Result[JV, Error]]]
  mut next : Int
  mut now_ms : Double
  timers : Array[Timer]
  mut seq : Int
}

///|
fn World::say(self : World, v : JV) -> Unit {
  self.host.say(stringify(v))
}

///|
async fn World::call(self : World, name : String, args : Array[JV]) -> JV {
  self.next += 1
  let n = self.next
  let done = @effect.Deferred::new()
  self.waiting[n] = done
  self.say(jobj([("call", jint(n)), ("name", js(name)), ("args", jarr(args))]))
  match done.wait() {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
fn World::after(self : World, ms : Double, f : () -> Unit) -> () -> Unit {
  self.seq += 1
  let t = { due: self.now_ms + ms, seq: self.seq, f, alive: true }
  self.timers.push(t)
  () => t.alive = false
}

///|
fn World::advance(self : World, ms : Double) -> Unit {
  while true {
    let mut next : Timer? = None
    for t in self.timers {
      if t.alive && t.due <= ms {
        match next {
          Some(x) if x.due < t.due || (x.due == t.due && x.seq < t.seq) => ()
          _ => next = Some(t)
        }
      }
    }
    match next {
      Some(t) => {
        t.alive = false
        if t.due > self.now_ms {
          self.now_ms = t.due
        }
        (t.f)()
      }
      None => break
    }
  }
  self.now_ms = ms
  let alive = self.timers.filter(t => t.alive)
  self.timers.clear()
  self.timers.push_iter(alive.iter())
}

///|
fn error_jv(e : Error) -> JV {
  match e {
    Thrown(kind, said) => {
      let fields = [("kind", js(kind)), ("message", js(js_string(said.get("message"))))]
      match said.get("status") {
        Some(Num(_) as s) => fields.push(("status", s))
        _ => ()
      }
      match said.get("code") {
        Some(Str(_) as c) => fields.push(("code", c))
        _ => ()
      }
      jobj(fields)
    }
    _ => jobj([("kind", js("Error")), ("message", js(e.to_string()))])
  }
}

///|
fn opt_s(v : JV?) -> String? {
  match v {
    Some(Str(s)) => Some(s)
    _ => None
  }
}

///|
fn opt_n(v : JV?) -> Double? {
  match v {
    Some(Num(n)) => Some(n)
    _ => None
  }
}

///|
fn quota_opt(v : JV?) -> JV {
  match v {
    Some(q) => q
    None => Null
  }
}

///|
fn health_list(v : JV?) -> Map[String, Health] {
  let m = Map::new()
  for f in jfields(v) {
    m[f.0] = Health::of_jv(f.1)
  }
  m
}

///|
fn contexts_of(v : JV?) -> Array[ContextCall] {
  jitems(v).map(c => {
    turn: c.get("turn").unwrap_or(Null),
    profile: opt_s(c.get("profile")),
    model: opt_s(c.get("model")),
    context: opt_n(c.get("context")),
  })
}

///|
fn limit_jv(l : LimitAfter) -> JV {
  match l {
    OwnLimit(m) => js(m)
    AccountLimit => Null
    NotKnown => jundef
  }
}

///|
fn pinned_of(v : JV?) -> Pinned {
  match v {
    Some(Str(s)) => One(s)
    Some(Arr(a)) => Some_(a.map(x => js_string(Some(x))))
    _ => None_
  }
}

///|
/// What an op answers: the functions of the package, the accounts' and the session accounts' methods.
async fn run_op(
  ctx : Ctx,
  op : String,
  a : Array[JV],
  accounts : Accounts?,
  sessions : SessionAccounts?,
) -> JV {
  let at_ = (i : Int) => a.get(i)
  let s = (i : Int) => js_string(at_(i))
  let profile = (i : Int) => Profile::of_hub(at_(i).unwrap_or(Obj([])))
  let lang = (i : Int) => opt_s(at_(i)).unwrap_or(ctx.station_lang)
  match op {
    // ── model.mbt, config.mbt ──
    "modelKey" => js(model_key(s(0)))
    "sameModel" => jbool(same_model(s(0), s(1)))
    "agyBaseModel" => js(agy_base_model(s(0)))
    "profileRuntimes" => jstrs(profile_runtimes(at_(0).unwrap_or(Obj([]))))
    "billedPerUse" => jbool(billed_per_use(at_(0).unwrap_or(Obj([]))))
    "takesFast" => jbool(takes_fast(at_(0).unwrap_or(Obj([]))))
    "cleanEndpoint" => jopt(clean_endpoint(s(0)))
    "hubConfig" => {
      let found = jfields(at_(2))
      let cfg = hub_config(at_(0).unwrap_or(Obj([])), s(1), found=id => match
        found.iter().find_first(f => f.0 == id) {
        Some((_, Arr(m))) => Some(m.map(x => js_string(Some(x))))
        _ => None
      })
      jobj([
        ("profiles", jarr(cfg.profiles.map(p => p.raw))),
        ("connects", jarr(cfg.connects.map(c => js(c.id)))),
        ("completion", jbool(cfg.completion_enabled)),
      ])
    }
    "spelling" => jopt(spelling(profile(0), s(1)))
    "allowedIn" => jbool(allowed_in(profile(0), opt_s(at_(1)), opt_s(at_(2))))
    "expandDevinFusion" => jstrs(expand_devin_fusion(at_(0)))
    // ── pool.mbt ──
    "urgency" => {
      let u = urgency(at_(0), to_number(at_(1)))
      jobj([("crowded", jbool(u.crowded)), ("pace", jnum(u.pace)), ("weight", jnum(u.weight))])
    }
    "usable" => {
      let h = Health::of_jv(at_(0).unwrap_or(Obj([])))
      match opt_n(at_(1)) {
        Some(n) => jbool(usable(h, now=n))
        None => jbool(usable(h))
      }
    }
    "pickProfile" => {
      let healths = health_list(at_(2))
      let loads = jfields(at_(3))
      let picked = jfields(at_(4))
      let p = pick_profile(
        jitems(at_(0)).map(Profile::of_hub),
        opt_s(at_(1)),
        {
          health: id => healths.get(id).unwrap_or(Health::empty()),
          load: id => match loads.iter().find_first(f => f.0 == id) {
            Some((_, Num(n))) => n.to_int()
            _ => 0
          },
          last_picked: id => match picked.iter().find_first(f => f.0 == id) {
            Some((_, Num(n))) => n
            _ => 0.0
          },
          now: () => to_number(at_(5)),
        },
        at_(6) == Some(Bool(true)),
      )
      js(p.id)
    }
    "cheapToLeave" => {
      let points = Map::new()
      for f in jfields(at_(1)) {
        points[f.0] = to_number(Some(f.1))
      }
      jbool(cheap_to_leave(contexts_of(at_(0)), points))
    }
    "reportedEfforts" =>
      match reported_efforts(s(0), opt_s(at_(1)), at_(2)) {
        Some(l) => jstrs(l)
        None => Null
      }
    "availableEfforts" => jstrs(available_efforts(s(0), opt_s(at_(1)), at_(2)))
    "commonEfforts" =>
      jstrs(
        common_efforts(
          jitems(at_(0)).map(l => jitems(Some(l)).map(x => js_string(Some(x)))),
          s(1),
        ),
      )
    "fallbackEfforts" => jstrs(fallback_efforts(s(0)))
    // ── pace.mbt ──
    "spendWeight" =>
      jnum(spend_weight(Catalog::of_jv(at_(1)), SpendHour::of_jv(at_(0).unwrap_or(Obj([])))))
    "spendScopes" => jstrs(spend_scopes(s(0), opt_s(at_(1))))
    "price" =>
      match Catalog::of_jv(at_(1)).price(s(0)) {
        Some(p) =>
          jobj([
            ("input", jnum(p.input)),
            ("output", jnum(p.output)),
            ("cacheRead", jnum(p.cache_read)),
          ])
        None => Null
      }
    "paceView" => {
      let shown = jitems(at_(2)).map(x => js_string(Some(x)))
      pace_view(
        Catalog::of_jv(at_(3)),
        to_number(at_(0)),
        at_(1).unwrap_or(Obj([])),
        id => shown.contains(id),
      )
    }
    // ── quota.mbt, claude_reset.mbt, agy_quota.mbt ──
    "at" =>
      match at(ctx, at_(0)) {
        Some(n) => jnum(n)
        None => Null
      }
    "percent" => jnum(percent(at_(0)))
    "windowLabel" => js(window_label(opt_n(at_(0)), s(1)))
    "blocked" => jbool(blocked(s(0)))
    "codexWindows" => jarr(codex_windows(ctx, at_(0)))
    "codexQuota" => codex_quota(ctx, at_(0), lang(1))
    "kimiWindows" => jarr(kimi_windows(ctx, at_(0)))
    "grokQuotaOf" => grok_quota_of(ctx, at_(0), lang(1))
    "codexQuotaFailure" => {
      let (kind, status) = codex_quota_failure(s(0))
      match status {
        Some(n) => jobj([("kind", js(kind)), ("status", jnum(n))])
        None => jobj([("kind", js(kind))])
      }
    }
    "grantKind" => js(grant_kind(at_(0)))
    "claudeResets" => jarr(claude_resets(ctx, at_(0), opt_s(at_(1))))
    "claudeClaim" =>
      match claude_claim(ctx, at_(0), s(1), opt_s(at_(2))) {
        Use(c) => c
        NoneNow => js("none")
        NoCredit => js("noCredit")
      }
    "claimOutcome" => js(claim_outcome(at_(0)))
    "claudeHeaders" => headers_jv(claude_headers(s(0), opt_s(at_(1))))
    "agyAllowance" => {
      let (w, sc) = agy_allowance(ctx, at_(0))
      jobj([("windows", jarr(w)), ("scoped", jarr(sc))])
    }
    "agyScopeForModel" => js(agy_scope_for_model(opt_s(at_(0))))
    "checkQuota" =>
      check_quota(
        ctx,
        profile(0),
        at_(1) == Some(Bool(true)),
        lang(2),
        opt_s(at_(3)),
      )
    "claudeUsage" => claude_usage(ctx, s(0), s(1), lang(2), opt_s(at_(3)))
    "claudeWithRefresh" =>
      claude_with_refresh(ctx, opt_s(at_(0)), lang(1), opt_s(at_(2)))
    "codexUsage" => quota_opt(codex_usage(ctx, s(0), lang(1)))
    "lentCodexUsage" =>
      quota_opt(lent_codex_usage(ctx, s(0), to_number(at_(1)), lang(2)))
    "machineUsage" => quota_opt(machine_usage(ctx, s(0), lang(1)))
    "agyQuota" =>
      agy_quota(
        ctx,
        s(0),
        at_(1).unwrap_or(Obj([])),
        lang(2),
        command=opt_s(at_(3)).unwrap_or("agy"),
      )
    "claudeResetWith" =>
      claude_reset_with(ctx, s(0), s(1), s(2), s(3), opt_s(at_(4)))
    "dateParse" =>
      match date_parse(s(0), ctx.tz_offset_ms) {
        Some(n) => jnum(n)
        None => Null
      }
    // ── kimi.mbt, cursor.mbt ──
    "kimiDue" =>
      match kimi_in(stringify(at_(0).unwrap_or(Null))) {
        Some(l) => jbool(kimi_due(l, to_number(at_(1))))
        None => Null
      }
    "readKimi" =>
      match read_kimi(ctx.io, s(0)) {
        Some(l) => l.to_jv()
        None => Null
      }
    "writeKimi" =>
      match kimi_in(stringify(at_(1).unwrap_or(Null))) {
        Some(l) => {
          write_kimi(ctx.io, s(0), l)
          Null
        }
        None => Null
      }
    "kimiHeaders" => headers_jv(kimi_headers(ctx.io, s(0)))
    "startKimiDevice" => start_kimi_device(ctx.io, s(0), s(1))
    "kimiDeviceToken" => kimi_device_token(ctx.io, s(0), s(1), s(2))
    "renewKimiToken" => {
      let t = renew_kimi_token(ctx.io, s(0), s(1), s(2))
      jobj([
        ("access", js(t.access)),
        ("refresh", js(t.refresh)),
        ("expiresInMs", jnum(t.expires_in_ms)),
      ])
    }
    "cursorIn" =>
      match cursor_in(s(0)) {
        Some(l) => l.to_jv()
        None => Null
      }
    "readCursor" =>
      match read_cursor(ctx.io, s(0)) {
        Some(l) => l.to_jv()
        None => Null
      }
    "writeCursor" =>
      match cursor_in(stringify(at_(1).unwrap_or(Null))) {
        Some(l) => {
          write_cursor(ctx.io, s(0), l)
          Null
        }
        None => Null
      }
    "cursorHandshake" => cursor_handshake(ctx.io, CursorUrls::of_jv(at_(0)))
    "pollCursor" =>
      poll_cursor(ctx.io, CursorUrls::of_jv(at_(0)), at_(1).unwrap_or(Obj([])))
    "mintCursorKey" => mint_cursor_key(ctx.io, CursorUrls::of_jv(at_(0)), s(1), s(2))
    "cursorMe" => cursor_me(ctx.io, CursorUrls::of_jv(at_(0)), s(1))
    "cursorModels" =>
      match cursor_models(ctx.io, CursorUrls::of_jv(at_(0)), s(1)) {
        Some(m) => jstrs(m)
        None => Null
      }
    // ── check.mbt ──
    "checkConfig" => {
      check_config(at_(0), s(1))
      Null
    }
    "checkAutomaticDecisions" => {
      check_automatic_decisions(at_(0))
      Null
    }
    // ── accounts' own functions ──
    "slug" => js(slug(s(0), to_number(at_(1)).to_int()))
    "unique" => {
      let taken = Map::new()
      for t in jitems(at_(1)) {
        taken[js_string(Some(t))] = ()
      }
      js(unique_id(s(0), taken))
    }
    "secretKey" => jbool(secret_key(s(0)))
    "mask" => js(mask(s(0)))
    "checkLabel" => js(check_label(ctx, at_(0), lang(1)))
    "apiProviders" => api_providers()
    "emailOk" => jbool(email_ok(s(0)))
    _ =>
      if op.has_prefix("accounts.") {
        guard accounts is Some(acc) else { raise plain_error("no accounts") }
        accounts_op(acc, slice(op, 9), a, lang)
      } else if op.has_prefix("sessions.") {
        guard sessions is Some(sa) else { raise plain_error("no session accounts") }
        sessions_op(sa, slice(op, 9), a)
      } else {
        raise plain_error("no op \{op}")
      }
  }
}

///|
async fn accounts_op(
  acc : Accounts,
  op : String,
  a : Array[JV],
  lang : (Int) -> String,
) -> JV {
  let at_ = (i : Int) => a.get(i)
  let s = (i : Int) => js_string(at_(i))
  let o = (i : Int) => at_(i).unwrap_or(Obj([]))
  match op {
    "start" => {
      acc.start()
      Null
    }
    "close" => {
      acc.close()
      Null
    }
    "configSaid" => {
      acc.config_said(o(0))
      Null
    }
    "loginChanged" => {
      acc.login_changed(s(0))
      Null
    }
    "machineChanged" => {
      acc.machine_changed()
      Null
    }
    "state" => acc.state()
    "health" => acc.health(s(0)).to_jv()
    "lentHealth" => acc.lent_health(s(0)).to_jv()
    "profiles" => jarr(acc.profiles().map(p => p.raw))
    "found" =>
      match acc.found(s(0)) {
        Some(m) => jstrs(m)
        None => Null
      }
    "codexAccountsRead" => {
      acc.codex_accounts_read()
      Null
    }
    "machineToken" => acc.machine_token(opt_s(at_(0)), at_(1) == Some(Bool(true)))
    "claudeToken" =>
      acc.claude_token(o(0), opt_s(at_(1)), at_(2) == Some(Bool(true)))
    "putProfile" => {
      acc.put_profile(s(0), o(1), o(2), lang(3))
      Null
    }
    "deleteProfile" => {
      acc.delete_profile(s(0), o(1), lang(2))
      Null
    }
    "newKeyedProfile" => js(acc.new_keyed_profile(o(0), o(1), lang(2)))
    "newMachineProfile" => js(acc.new_machine_profile(o(0), o(1), lang(2)))
    "loginStateFile" => jopt(acc.login_state_file(s(0)))
    "startLogin" => acc.start_login(s(0), o(1), lang(2))
    "newLogin" => acc.new_login(o(0), o(1), lang(2))
    "hasPending" => jbool(acc.has_pending(s(0)))
    "dropLogin" => {
      acc.drop_login(s(0))
      Null
    }
    "renewConsole" => {
      acc.renew_console(s(0))
      Null
    }
    "renewKimi" => {
      acc.renew_kimi(s(0))
      Null
    }
    "newModels" => {
      acc.new_models(jitems(at_(0)).map(x => js_string(Some(x))))
      Null
    }
    "check" => acc.check(s(0), lang(1))
    "refreshQuota" => quota_opt(acc.refresh_quota(s(0)))
    "askedQuota" => quota_opt(acc.asked_quota(s(0)))
    "refreshQuotas" => {
      acc.refresh_quotas(at_(0) == Some(Bool(true)))
      Null
    }
    "recheckBorrowed" => {
      acc.recheck_borrowed()
      Null
    }
    "sharedChanged" => {
      acc.shared_changed(s(0), at_(1) == Some(Bool(true)))
      Null
    }
    "sharedQuotaReset" => {
      acc.shared_quota_reset(s(0))
      Null
    }
    "followed" => {
      acc.followed()
      Null
    }
    "resetQuota" => acc.reset_quota(s(0), s(1), lang(2), opt_s(at_(3)))
    "decisionModels" => acc.decision_models()
    "putAutomaticDecisions" => {
      acc.put_automatic_decisions(o(0), o(1), lang(2))
      Null
    }
    "putArchiving" => {
      acc.put_archiving(o(0), o(1), lang(2))
      Null
    }
    "reviewUndecided" => jnum(acc.review_undecided(o(0), lang(1)))
    "refreshDecisionModels" => {
      acc.refresh_decision_models(o(0), lang(1))
      Null
    }
    "automaticDecisionsView" =>
      acc.automatic_decisions_view(o(0), include_policy=at_(1) != Some(Bool(false)))
    "putArchivePolicy" => {
      acc.put_archive_policy(o(0), o(1), lang(2))
      Null
    }
    "profilesView" => acc.profiles_view(at_(0))
    "homesReadSoon" => {
      acc.homes_read_soon()
      Null
    }
    "paceView" => acc.pace_view(at_(0))
    "fusionView" => acc.fusion_view(s(0))
    "loginsView" => acc.logins_view()
    "machineLogins" => acc.machine_logins()
    "accountEmail" => jopt(acc.account_email(s(0), s(1)))
    _ => raise plain_error("no accounts op \{op}")
  }
}

///|
async fn sessions_op(sa : SessionAccounts, op : String, a : Array[JV]) -> JV {
  let at_ = (i : Int) => a.get(i)
  let s = (i : Int) => js_string(at_(i))
  match op {
    "setHealth" => {
      let healths = health_list(at_(0))
      sa.set_health(id => healths.get(id).unwrap_or(Health::empty()))
      Null
    }
    "wireAgain" => {
      sa.set_recheck(async fn(id) { ignore(sa.b.ask("sessions.checkAgain", [js(id)])) })
      sa.set_quota_again(async fn(id) { ignore(sa.b.ask("sessions.quotaAgain", [js(id)])) })
      Null
    }
    "healthOf" => sa.health_of((sa.config)(), s(0)).to_jv()
    "limitAfter" => limit_jv(sa.limit_after(s(0), opt_s(at_(1))))
    "recheck" => {
      sa.recheck(s(0))
      Null
    }
    "sameAccount" => jbool(sa.same_account(s(0), s(1)))
    "resetAllowance" => {
      sa.reset_allowance(s(0))
      Null
    }
    "pick" => {
      let cfg = (sa.config)()
      let ids = jitems(at_(0)).map(x => js_string(Some(x)))
      let candidates = cfg.profiles.filter(p => ids.contains(p.id))
      let p = sa.pick(
        cfg,
        candidates,
        opt_s(at_(1)),
        at_(2) == Some(Bool(true)),
        except?=opt_s(at_(3)),
      )
      js(p.id)
    }
    "allows" =>
      match (sa.profile(s(1))) {
        Some(p) => jbool(sa.allows(s(0), p))
        None => jbool(false)
      }
    "runOn" => {
      let p = sa.run_on(
        s(0),
        holding=at_(1) == Some(Bool(true)),
        quiet=at_(2) == Some(Bool(true)),
        across=at_(3) == Some(Bool(true)),
      )
      jobj([("id", js(p.id)), ("profile", p.raw)])
    }
    "repick" => {
      sa.repick(s(0))
      Null
    }
    "profile" =>
      match sa.profile(s(0)) {
        Some(p) => p.raw
        None => Null
      }
    "spend" =>
      match sa.spend(s(0), opt_s(at_(1)), model?=opt_s(at_(2))) {
        Some((x, y)) => jstrs([x, y])
        None => Null
      }
    "refillsAt" => jnum(sa.refills_at(s(0)))
    "goesOnWith" => jbool(sa.goes_on_with(Row::of_jv(at_(0).unwrap_or(Obj([]))), s(1)))
    "modelEfforts" =>
      jstrs(sa.model_efforts(s(0), opt_s(at_(1)), pinned_of(at_(2))))
    "change" =>
      sa.change(
        s(0),
        at_(1).unwrap_or(Obj([])),
        opt_s(at_(2)).unwrap_or(sa.station_lang),
      )
    _ => raise plain_error("no sessions op \{op}")
  }
}

///|
/// The harness: one world, its accounts and session accounts made at setup.
pub async fn harness(host : @host.Host) -> Unit {
  let w : World = {
    host,
    waiting: Map::new(),
    next: 0,
    now_ms: 0.0,
    timers: [],
    seq: 0,
  }
  guard host.line() is Some(first) else { return }
  let setup = (parse(first) catch { _ => Obj([]) }).get("setup").unwrap_or(Obj([]))
  w.now_ms = to_number(setup.get("now")) |> fun_or_zero
  let b = Backend::new((name, args) => w.call(name, args))
  let tz = to_number(setup.get("tzOffsetMs")) |> fun_or_zero
  let ctx : Ctx = {
    io: { b, },
    words: Words::new(
      setup.get("zh").unwrap_or(Obj([])),
      setup.get("en").unwrap_or(Obj([])),
      product=jstr(setup.get("product")).unwrap_or("still.fail"),
    ),
    urls: setup.get("urls").unwrap_or(Obj([])),
    station_lang: jstr(setup.get("stationLang")).unwrap_or("zh"),
    tz_offset_ms: _ => tz,
  }
  let clock : Clock = { now: () => w.now_ms, after: (ms, f) => w.after(ms, f) }
  let data = jstr(setup.get("data")).unwrap_or(".")
  let accounts_ref : Ref[Accounts?] = Ref(None)
  let sessions_ref : Ref[SessionAccounts?] = Ref(None)
  let catalog = Catalog::of_jv(setup.get("catalog"))
  // (made once the lines are read: making them asks the test, whose answers come as lines)
  ignore(
    host.rt.fork(name="harness setup", async fn() {
      match setup.get("given") {
        Some(Obj(_) as g) => {
          let acc = Accounts::new(
            b,
            ctx,
            Given::of_jv(g, data),
            host.rt,
            clock,
            setup.get("config").unwrap_or(Obj([])),
            catalog,
          )
          accounts_ref.val = Some(acc)
        }
        _ => ()
      }
      if setup.get("sessions") == Some(Bool(true)) {
        let config = async fn() -> HubConfig {
          match accounts_ref.val {
            Some(acc) => acc.hub_config()
            None => hub_config(b.ask("config.raw", []), data)
          }
        }
        let sa = SessionAccounts::new(
          b,
          ctx.words,
          ctx.station_lang,
          config,
          () => w.now_ms,
          host.rt,
          asks_allows=setup.get("asksAllows") != Some(Bool(false)),
          tells_moved=setup.get("tellsMoved") != Some(Bool(false)),
        )
        sessions_ref.val = Some(sa)
        match accounts_ref.val {
          Some(acc) if g_hub(setup) => acc.set_hub_accounts(sa)
          _ => ()
        }
      }
      w.say(jobj([("ready", jbool(true))]))
    }),
  )
  while host.line() is Some(line) {
    let said = parse(line) catch { _ => continue }
    match said {
      Obj(_) if said.get("ret") is Some(Num(n)) =>
        match w.waiting.get(n.to_int()) {
          Some(done) => {
            w.waiting.remove(n.to_int())
            match said.get("throw") {
              Some(t) =>
                ignore(done.succeed(Err(Thrown(jstr(t.get("kind")).unwrap_or("Error"), t))))
              None => ignore(done.succeed(Ok(said.get("value").unwrap_or(jundef))))
            }
          }
          None => ()
        }
      Obj(_) if said.get("ask") is Some(id) => {
        let op = jstr(said.get("op")).unwrap_or("")
        let args = jitems(said.get("args"))
        ignore(
          host.rt.fork(name="harness ask", async fn() {
            let out = try {
              let v = run_op(ctx, op, args, accounts_ref.val, sessions_ref.val)
              jobj([("ans", id), ("value", v)])
            } catch {
              e => jobj([("ans", id), ("error", error_jv(e))])
            }
            w.say(out)
          }),
        )
      }
      Obj(_) if said.get("advance") is Some(Num(ms)) => {
        w.advance(ms)
        w.say(jobj([("advanced", jnum(ms))]))
      }
      Obj(_) if said.get("settle") is Some(id) =>
        ignore(
          host.rt.fork(name="harness settle", async fn() {
            match accounts_ref.val {
              Some(acc) => acc.background.idle()
              None => ()
            }
            w.say(jobj([("settled", id)]))
          }),
        )
      _ => ()
    }
  }
}

///|
fn fun_or_zero(n : Double) -> Double {
  if n.is_nan() {
    0.0
  } else {
    n
  }
}

///|
fn g_hub(setup : JV) -> Bool {
  jget(setup.get("given"), "hub") == Some(Bool(true))
}
