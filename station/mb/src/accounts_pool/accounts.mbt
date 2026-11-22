// The station's accounts (station/src/accounts/index.ts): its profiles as the pages edit them, their checks and
// allowances, sign-ins, profiles on the machine's own login, the machine login's renewed token, and the models the
// automatic decisions may use. What changes is told (`changed`); kept on a timer only where nothing says when it
// changed: the allowances every 5 minutes while someone follows, every profile checked 3 s after start, an OpenCode
// Console token renewed days before it runs out, a Kimi token with half its life left.
//
// What is not the accounts' own is the station's parts' (backend.mbt): the store, the sign-ins' manager (login.ts),
// the machine's logins (machine.ts), the hub, the shared profiles (share/), the codex, Hermes and Antigravity drivers,
// a profile's check (profiles.ts `checkProfile`), what the automatic decisions can use (decision.ts), the outdated
// models (models.ts), the archive policy (archive-policy.ts). config.json is kept here as the station last said it
// (`config` events), an edit taken at once and written behind it (ops/config.ts `updateSoon`).

///|
let quota_every_ms : Double = 300_000.0

///|
let quota_stands_ms : Double = 1_800_000.0

///|
let handed_margin_ms : Double = 3_600_000.0

///|
let check_on_start_ms : Double = 3000.0

///|
let homes_every_ms : Double = 10_000.0

///|
let console_renew_before_ms : Double = 7.0 * 86_400_000.0

///|
let console_renew_every_ms : Double = 6.0 * 3_600_000.0

///|
let kimi_renew_every_ms : Double = 60_000.0

///|
let pending_kept_ms : Double = 900_000.0

///|
let policy_days : Double = 7.0

///|
let policy_chats : Int = 20

///|
let hermes_model_limit : Int = 50

///|
/// The part's time: now, and `f` once `ms` from now (the function returned calls it off).
pub(all) struct Clock {
  now : () -> Double
  after : (Double, () -> Unit) -> () -> Unit
}

///|
/// What runs on its own (ops/fibers.ts `Fibers`): work spawned, waits and rounds on the part's clock; what it fails
/// with logged. `idle` once none runs.
pub struct Background {
  rt : @effect.Runtime
  clock : Clock
  log : (String) -> Unit
  mut closed : Bool
  cancels : Array[() -> Unit]
  mut active : Int
  idle_waiters : Array[@effect.Deferred[Unit]]
}

///|
pub fn Background::new(
  rt : @effect.Runtime,
  clock : Clock,
  log : (String) -> Unit,
) -> Background {
  { rt, clock, log, closed: false, cancels: [], active: 0, idle_waiters: [] }
}

///|
pub fn Background::now(self : Background) -> Double {
  (self.clock.now)()
}

///|
/// Work going that is the part's (counted by `idle`).
pub fn Background::track(self : Background, f : async () -> Unit) -> Unit {
  self.active += 1
  ignore(
    self.rt.fork_daemon("accounts background", on_error=e => (self.log)(message_of(e)), async fn() {
      f() catch {
        e => (self.log)(message_of(e))
      }
      self.active -= 1
      if self.active == 0 {
        let waiters = self.idle_waiters.copy()
        self.idle_waiters.clear()
        for w in waiters {
          ignore(w.succeed(()))
        }
      }
    }),
  )
}

///|
/// `spawn`: runs `f` as the part's; what it throws is logged.
pub fn Background::spawn(self : Background, f : async () -> Unit) -> Unit {
  if self.closed {
    return
  }
  self.track(f)
}

///|
/// `after`: `f` once, `ms` from now, unless called off or the part closed first.
pub fn Background::after(
  self : Background,
  ms : Double,
  f : async () -> Unit,
) -> () -> Unit {
  if self.closed {
    return () => ()
  }
  let cancel = (self.clock.after)(js_max(0.0, ms), () => if !self.closed {
    self.track(f)
  })
  self.cancels.push(cancel)
  cancel
}

///|
/// `every`: `f` every `ms` (the first `ms` from now) until the part closes.
pub fn Background::every(
  self : Background,
  ms : Double,
  f : async () -> Unit,
) -> () -> Unit {
  let stopped = Ref(false)
  let cancel_now : Ref[() -> Unit] = Ref(() => ())
  fn round() -> Unit {
    if self.closed || stopped.val {
      return
    }
    cancel_now.val = (self.clock.after)(ms, () => {
      if self.closed || stopped.val {
        return
      }
      self.track(f)
      round()
    })
  }

  round()
  let stop = () => {
    stopped.val = true
    (cancel_now.val)()
  }
  self.cancels.push(stop)
  stop
}

///|
/// `close`: every wait and round stopped.
pub fn Background::close(self : Background) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  for c in self.cancels {
    c()
  }
  self.cancels.clear()
}

///|
/// Once no work of the part's runs.
pub async fn Background::idle(self : Background) -> Unit {
  while self.active > 0 {
    let w = @effect.Deferred::new()
    self.idle_waiters.push(w)
    w.wait()
  }
}

///|
/// Which of the station's other parts the accounts were given (`AccountsDeps`), and how a check, an allowance, a
/// reset and the decisions are asked: by the part a test gives (`given`), as the station does (`default`), or not
/// at all (`none`).
pub(all) struct Given {
  data : String
  hub : Bool
  hub_profile_gone : Bool
  hub_allowance_reset : Bool
  hub_profile_login_changed : Bool
  codex : Bool
  codex_login_changed : Bool
  hermes : Bool
  agy : Bool
  agy_catalog : Bool
  following : Bool
  claude_version : Bool
  check : String
  quota : String
  reset_quota : String
  discover : String
  machine : Bool
  check_on_start : Bool
  workspaces : Bool
  review_undecided : Bool
  shared : Bool
  shared_lend_codex : Bool
  shared_lend_agy : Bool
  shared_quota_reset : Bool
  shared_lend_claude : Bool
  shared_login_updated : Bool
  shared_host_name : Bool
  /// Whether a login newly over is told the workspace's managers (`accounts.profileLogin`, P5-2's notifier) and one
  /// good again clears its cooldown (`accounts.profileLoginCleared`).
  login_notices : Bool
  /// Whether config.json's edits pass `checkConfig` (ops/config.ts `check`, as the station sets it).
  config_checked : Bool
}

///|
/// What a JSON object of the parts given says (the harness's setup).
pub fn Given::of_jv(v : JV, data : String) -> Given {
  let b = (k : String) => v.get(k) == Some(Bool(true))
  let s = (k : String, d : String) => jstr(v.get(k)).unwrap_or(d)
  {
    data,
    hub: b("hub"),
    hub_profile_gone: b("hubProfileGone"),
    hub_allowance_reset: b("hubAllowanceReset"),
    hub_profile_login_changed: b("hubProfileLoginChanged"),
    codex: b("codex"),
    codex_login_changed: b("codexLoginChanged"),
    hermes: b("hermes"),
    agy: b("agy"),
    agy_catalog: b("agyCatalog"),
    following: b("following"),
    claude_version: b("claudeVersion"),
    check: s("check", "default"),
    quota: s("quota", "default"),
    reset_quota: s("resetQuota", "default"),
    discover: s("discover", "default"),
    machine: b("machine"),
    check_on_start: v.get("checkOnStart") != Some(Bool(false)),
    workspaces: b("workspaces"),
    review_undecided: b("reviewUndecided"),
    shared: b("shared"),
    shared_lend_codex: b("sharedLendCodex"),
    shared_lend_agy: b("sharedLendAgy"),
    shared_quota_reset: b("sharedQuotaReset"),
    shared_lend_claude: b("sharedLendClaude"),
    shared_login_updated: b("sharedLoginUpdated"),
    shared_host_name: b("sharedHostName"),
    login_notices: b("loginNotices"),
    config_checked: b("configChecked"),
  }
}

///|
/// A sign-in with no profile yet (`Pending`).
struct Pending {
  runtime : String?
  service : String?
  access : String?
  home : String
  by : JV
  mut created : String?
  mut error : String?
}

///|
/// What a profile's home says, as the overview shows it.
struct HomeSays {
  exists : Bool
  email : String?
} derive(Eq)

///|
struct HomeRead {
  since : Int
  mut tell : Bool
  read : @effect.Deferred[Unit]
}

///|
pub struct Accounts {
  b : Backend
  ctx : Ctx
  given : Given
  rt : @effect.Runtime
  background : Background
  mut config_raw : JV
  /// `hub_config()` as made from `config_raw` and `checks` last, until either changes: the overview asks each
  /// profile's health of every other's (`SessionAccounts::health_of`), which made it again each time, P³ profiles
  /// a read (21 profiles held a station's thread at 100%, 0.1.9984).
  mut hub_cache : HubConfig?
  catalog : Catalog
  checks : Map[String, JV]
  quotas : Map[String, JV]
  quota_busy : Map[String, @effect.Deferred[Unit]]
  quota_unanswered : Map[String, (String, Double)]
  reset_details_asked : Map[String, (Double, Double)]
  login_generation : Map[String, Int]
  borrowed_login : Map[String, String?]
  renewing : Map[String, @effect.Deferred[Unit]]
  settling : Map[String, Bool]
  pending : Map[String, Pending]
  making : Map[String, Unit]
  codex_accounts : Map[String, (String, String?)]
  codex_account_reads : Map[String, (String, @effect.Deferred[Unit])]
  homes : Map[String, (String, HomeSays)]
  mut homes_read : Double
  mut homes_reading : Bool
  home_reads : Map[String, HomeRead]
  mut closed : Bool
  mut homes_changed : Int
  emails : Map[String, (String, String?)]
  mut hub_accounts : SessionAccounts?
  mut pace_read : (Double, Int, Double, JV)?
  mut pace_rev : Int
  mut unchecking : @effect.Deferred[Unit]?
  machine_said : Ref[Map[String, String]?]
  /// Logins a runtime was refused on and a recheck found over (FB-44), with what is said and the allowance kept then
  /// (index.ts `authRevoked`): signed out through checks that say otherwise till it signs in anew, its share changes,
  /// or an allowance read after says it works.
  auth_revoked : Map[String, (String, JV?, Double)]
}

///|
async fn Accounts::ask(self : Accounts, name : String, args : Array[JV]) -> JV {
  self.b.ask(name, args)
}

///|
async fn Accounts::log(
  self : Accounts,
  level : String,
  message : String,
  fields : Array[(String, JV)],
) -> Unit {
  ignore(self.b.ask("log.\{level}", [js("accounts"), js(message), jobj(fields)]))
}

///|
fn Accounts::tr(
  self : Accounts,
  lang : String,
  key : String,
  args? : Array[(String, String)] = [],
) -> String {
  self.ctx.tr(lang, key, args~)
}

///|
/// `makeAccounts`: the accounts, what the last run learned of each profile read (`start` it once wired).
pub async fn Accounts::new(
  b : Backend,
  ctx : Ctx,
  given : Given,
  rt : @effect.Runtime,
  clock : Clock,
  config_raw : JV,
  catalog : Catalog,
) -> Accounts {
  let background = Background::new(rt, clock, message => ignore(
    rt.fork_quiet(name="accounts warn", async fn() {
      ignore(
        b.ask("log.warn", [
          js("accounts"),
          js("background work failed"),
          jobj([("error", js(message))]),
        ]),
      )
    }),
  ))
  let a : Accounts = {
    b,
    ctx,
    given,
    rt,
    background,
    config_raw,
    hub_cache: None,
    catalog,
    checks: Map::new(),
    quotas: Map::new(),
    quota_busy: Map::new(),
    quota_unanswered: Map::new(),
    reset_details_asked: Map::new(),
    login_generation: Map::new(),
    borrowed_login: Map::new(),
    renewing: Map::new(),
    settling: Map::new(),
    pending: Map::new(),
    making: Map::new(),
    codex_accounts: Map::new(),
    codex_account_reads: Map::new(),
    homes: Map::new(),
    homes_read: 0.0,
    homes_reading: false,
    home_reads: Map::new(),
    closed: false,
    homes_changed: 0,
    emails: Map::new(),
    hub_accounts: None,
    pace_read: None,
    pace_rev: 0,
    unchecking: None,
    machine_said: Ref(None),
    auth_revoked: Map::new(),
  }
  for entry in jitems(Some(json_to_jv(b.with_store(s => s.profile_status())))) {
    let items = jitems(Some(entry))
    let id = js_string(items.get(0))
    let status = items.get(1)
    match jget(status, "check") {
      Some(Obj(_) as c) => a.checks[id] = c
      _ => ()
    }
    match jget(status, "quota") {
      Some(Obj(_) as q) => a.quotas[id] = q
      _ => ()
    }
  }
  a
}

///|
/// The hub's account pool, when the accounts are given one (in the same program).
pub fn Accounts::set_hub_accounts(self : Accounts, s : SessionAccounts) -> Unit {
  self.hub_accounts = Some(s)
}

///|
/// config.json as the station says it is now (its own edits, another part's).
pub fn Accounts::config_said(self : Accounts, raw : JV) -> Unit {
  self.config_raw = raw
  self.hub_cache = None
}

///|
fn Accounts::wait_unchecking(self : Accounts) -> async () -> Unit {
  async fn() {
    match self.unchecking {
      Some(d) => d.wait()
      None => ()
    }
  }
}

///|
/// `#unchecking = this.uncheckOutdated().catch(() => {})`.
fn Accounts::uncheck_soon(self : Accounts) -> Unit {
  let d = @effect.Deferred::new()
  self.unchecking = Some(d)
  self.background.track(async fn() {
    self.uncheck_outdated() catch {
      _ => ()
    }
    ignore(d.succeed(()))
  })
}

///|
/// `start`: the pool told of profiles' health, the outdated models unchecked, sign-ins followed, the checks after
/// start, the allowance rounds, the machine's logins read.
pub fn Accounts::start(self : Accounts) -> Unit {
  match self.hub_accounts {
    Some(h) => {
      h.set_health(id => self.health(id))
      h.set_recheck(async fn(id, force) { self.recheck_profile(id, force~) })
      h.set_quota_again(async fn(id) {
        match self.quota_busy.get(id) {
          Some(busy) => busy.wait()
          None => ignore(self.read_quota(id, false))
        }
      })
    }
    None => ()
  }
  self.background.track(async fn() {
    self.codex_accounts_read() catch {
      _ => ()
    }
  })
  self.uncheck_soon()
  if self.given.machine {
    self.background.spawn(async fn() { ignore(self.ask("machine.refresh", [])) })
  }
  if self.given.check_on_start {
    ignore(
      self.background.after(check_on_start_ms, async fn() {
        for p in self.profiles() {
          if p.enabled {
            let id = p.id
            self.background.spawn(async fn() {
              ignore(self.check(id, self.ctx.station_lang))
            })
          }
        }
        self.renew_consoles()
      }),
    )
  }
  ignore(
    self.background.every(console_renew_every_ms, async fn() {
      self.renew_consoles()
    }),
  )
  ignore(
    self.background.every(kimi_renew_every_ms, async fn() { self.renew_kimis() }),
  )
  ignore(
    self.background.every(quota_every_ms, async fn() {
      if self.given.following && self.ask("following", []) == Bool(true) {
        self.refresh_quotas(false)
      }
    }),
  )
}

///|
/// A finished sign-in changes what the profile can do (the sign-ins' manager told `id` changed).
pub async fn Accounts::login_changed(self : Accounts, id : String) -> Unit {
  self.homes.remove(id)
  self.homes_changed += 1
  let pending = self.pending.contains(id)
  let job = self.ask("logins.get", [js(id)])
  self.changed()
  if pending {
    self.background.spawn(async fn() { self.pending_changed(id) })
  } else if jget(Some(job), "state") == Some(Str("done")) {
    self.background.spawn(async fn() {
      if jget(Some(job), "provider") == Some(Str("opencode")) &&
        self.signed_in_console(id, to_number(job.get("startedAt"))) {
        self.changed()
      }
      self.after_sign_in(id)
    })
  }
}

///|
/// The machine's logins read again (machine.ts told its listeners): a profile on the machine's login is as that login
/// is.
pub async fn Accounts::machine_changed(self : Accounts) -> Unit {
  self.changed()
  let logins = jitems(Some(self.ask("machine.get", [])))
  let said = (runtime : String) => stringify(
    jarr(
      logins
      .filter(l => l.get("runtime") == Some(Str(runtime)))
      .map(l => jarr([
        l.get("loggedIn").unwrap_or(jundef),
        l.get("email").unwrap_or(jundef),
        l.get("plan").unwrap_or(jundef),
        l.get("usable").unwrap_or(jundef),
      ])),
    ),
  )
  let before = self.machine_said.val
  let last : Map[String, String] = Map::new()
  for r in ["claude", "codex"] {
    last[r] = said(r)
  }
  self.machine_said.val = Some(last)
  let differs = match before {
    None => true
    Some(b) => ["claude", "codex"].iter().any(r => b.get(r) != last.get(r))
  }
  if differs && self.given.shared && self.given.shared_login_updated {
    ignore(self.ask("shared.loginUpdated", [jundef]))
  }
  match before {
    None => {
      for p in self.profiles() {
        if !p.machine {
          continue
        }
        let check = self.checks.get(p.id)
        let login = match p.runtime {
          Some(r) =>
            logins
            .iter()
            .find_first(l => l.get("runtime") == Some(Str(r)) && is_truthy(l.get("loggedIn")))
          None => None
        }
        match (jget(check, "state"), jget(login, "plan")) {
          (Some(Str("ok")), Some(plan)) if is_truthy(Some(plan)) &&
            jget(check, "plan") != Some(plan) => self.after_sign_in(p.id)
          _ => ()
        }
      }
    }
    Some(b) =>
      for p in self.profiles() {
        match p.runtime {
          Some(r) if p.machine && b.get(r) != last.get(r) => self.after_sign_in(p.id)
          _ => ()
        }
      }
  }
}

///|
/// `close`.
pub async fn Accounts::close(self : Accounts) -> Unit {
  self.closed = true
  ignore(self.ask("logins.close", []))
  self.background.close()
  (self.wait_unchecking())()
}

///|
/// What changed of what the overview shows is told.
fn Accounts::changed(self : Accounts) -> Unit {
  self.background.track(async fn() { ignore(self.ask("changed", [])) })
}

///|
/// `found`: the models profile `id`'s last check found.
pub fn Accounts::found(self : Accounts, id : String) -> Array[String]? {
  match jget(self.checks.get(id), "models") {
    Some(Arr(a)) => Some(a.map(x => js_string(Some(x))))
    _ => None
  }
}

///|
/// `profiles`: the profiles as the config has them now, each running the models its check found.
pub fn Accounts::profiles(self : Accounts) -> Array[Profile] {
  self.hub_config().profiles
}

///|
pub fn Accounts::hub_config(self : Accounts) -> HubConfig {
  match self.hub_cache {
    Some(cfg) => cfg
    None => {
      let cfg = hub_config(self.config_raw, self.given.data, found=id => self.found(id))
      self.hub_cache = Some(cfg)
      cfg
    }
  }
}

///|
/// The profile asked, of `hub_config()` as kept: `health` asks it once a profile, and a view goes through every
/// profile's health (and `health_of` each other's too), so making even the one asked each time made the overview
/// quadratic in the profiles (29 profiles, 841 made a view, 0.1.10401). The first of that id, as `hub_config` makes each.
fn Accounts::profile(self : Accounts, id : String) -> Profile? {
  self.hub_config().profiles.iter().find_first(p => p.id == id)
}

///|
/// `health`: how a profile is doing, for the pool.
pub fn Accounts::health(self : Accounts, id : String) -> Health {
  let account = match self.profile(id) {
    Some(p) if p.runtime == Some("codex") && access_kind(p.raw) == "subscription" =>
      self.codex_account(p)
    _ => None
  }
  {
    check: self.checks.get(id),
    quota: self.quotas.get(id),
    account: account.map(a => "codex:\{a}"),
    spent: false,
  }
}

///|
fn Accounts::codex_account(self : Accounts, profile : Profile) -> String? {
  let p = profile
  self.background.track(async fn() { self.codex_account_read(p, false) })
  match self.codex_accounts.get(profile.id) {
    Some((home, account)) if home == profile.home => account
    _ => None
  }
}

///|
/// `codexAccountRead`: `again`: its login just changed, so a read after any under way, kept last.
async fn Accounts::codex_account_read(
  self : Accounts,
  profile : Profile,
  again : Bool,
) -> Unit {
  let under = self.codex_account_reads.get(profile.id)
  match under {
    Some((u_home, u)) if !again && u_home == profile.home => {
      u.wait()
      return
    }
    _ => ()
  }
  let read = @effect.Deferred::new()
  self.codex_account_reads[profile.id] = (profile.home, read)
  match under {
    Some((_, u)) => u.wait() catch { _ => () }
    None => ()
  }
  let account = self.ask("codex.accountIdentity", [js(profile.home)]) catch {
    _ => jundef
  }
  if !is_undef(account) {
    self.codex_accounts[profile.id] = (
      profile.home,
      match account {
        Str(s) => Some(s)
        _ => None
      },
    )
  }
  match self.codex_account_reads.get(profile.id) {
    Some((_, r)) if physical_equal(r, read) => self.codex_account_reads.remove(profile.id)
    _ => ()
  }
  ignore(read.succeed(()))
}

///|
/// `codexAccountsRead`: every Codex subscription profile's account read again.
pub async fn Accounts::codex_accounts_read(self : Accounts) -> Unit {
  let codex = self.profiles().filter(p => p.runtime == Some("codex") && access_kind(p.raw) == "subscription")
  for p in codex {
    self.codex_account_read(p, true)
  }
}

///|
/// `lentHealth`: how a profile is doing, told to a station borrowing it; `recheck`: the borrower was refused on it, so
/// it is asked of its provider again first (`recheck_profile`).
pub async fn Accounts::lent_health(self : Accounts, id : String, recheck? : Bool = false) -> Health {
  if recheck {
    self.recheck_profile(id) catch {
      _ => ()
    }
    return self.health(id)
  }
  if !self.quotas.contains(id) ||
    self.background.now() - self.quota_asked_at(id) >= quota_every_ms {
    ignore(self.refresh_quota(id)) catch {
      _ => ()
    }
  }
  self.health(id)
}

///|
async fn Accounts::claude_version(self : Accounts) -> String? {
  if self.given.claude_version {
    match self.ask("claudeVersion", []) {
      Str(v) if v != "" => Some(v)
      _ => None
    }
  } else {
    None
  }
}

///|
/// `machineToken`: the machine login's current Claude token, renewed when about to run out.
pub async fn Accounts::machine_token(
  self : Accounts,
  rejected : String?,
  lent : Bool,
) -> JV {
  let claude_version = self.claude_version()
  let (token, expires_at) = claude_oauth_token(
    self.ctx,
    None,
    rejected,
    self.ctx.url("claudeToken").unwrap_or(""),
    self.ctx.station_lang,
    margin=handed_margin_ms,
    lent~,
    claude_version?,
  )
  jobj([("token", js(token)), ("expiresAt", jnum(expires_at))])
}

///|
/// `claudeToken`: a Claude profile's current token, renewed when about to run out.
pub async fn Accounts::claude_token(
  self : Accounts,
  profile : JV,
  rejected : String?,
  lent : Bool,
) -> JV {
  if profile.get("machine") == Some(Bool(true)) {
    return self.machine_token(rejected, lent)
  }
  let home = match profile.get("home") {
    None | Some(Null) => ""
    h => js_string(h)
  }
  let joined = @nodepath.join(self.b.sep, [self.given.data, home])
  let claude_version = self.claude_version()
  let (token, expires_at) = claude_oauth_token(
    self.ctx,
    Some(joined),
    rejected,
    self.ctx.url("claudeToken").unwrap_or(""),
    self.ctx.station_lang,
    margin=handed_margin_ms,
    lent~,
    claude_version?,
  )
  jobj([("token", js(token)), ("expiresAt", jnum(expires_at))])
}

///|
/// `claudeReset`: one of a Claude subscription's limit resets used, with its token (a borrowed one's lent by its
/// host), renewed and asked again once when the provider says it is not good.
async fn Accounts::claude_reset(
  self : Accounts,
  profile : Profile,
  key : String,
  kind : String?,
) -> JV {
  let version = if self.given.claude_version {
    match self.ask("claudeVersion", []) {
      Str(v) => Some(v)
      _ => None
    }
  } else {
    None
  }
  guard version is Some(version) else {
    raise refusal(503, self.tr(self.ctx.station_lang, "station.quota.resetUnsupported"))
  }
  let token = async fn(rejected : String?) -> JV {
    if !borrowed(profile.raw) {
      return self.claude_token(profile.raw, rejected, false)
    }
    if !(self.given.shared && self.given.shared_lend_claude) {
      raise refusal(503, self.tr(self.ctx.station_lang, "station.quota.resetUnsupported"))
    }
    self.ask("shared.lendClaude", [profile.raw, arg(rejected.map(js))])
  }
  let base = self.ctx.url("anthropic").unwrap_or("")
  let first = token(None)
  let first_token = js_string(first.get("token"))
  let result = claude_reset_with(self.ctx, base, first_token, version, key, kind)
  if result.get("unauthorized") != Some(Bool(true)) {
    return result
  }
  let renewed = token(Some(first_token))
  let again = claude_reset_with(
    self.ctx,
    base,
    js_string(renewed.get("token")),
    version,
    key,
    kind,
  )
  if again.get("unauthorized") == Some(Bool(true)) {
    raise refusal(502, self.tr(self.ctx.station_lang, "station.quota.signInExpired"))
  }
  again
}

///|
/// `borrowed`: a copy of a profile another station shares.
pub fn borrowed(p : JV) -> Bool {
  match p.get("share") {
    Some(Obj(_) as s) => s.get("borrowed") == Some(Bool(true))
    _ => false
  }
}

///|
/// `own`: refused for a copy of another station's profile.
fn Accounts::own(self : Accounts, id : String, lang : String) -> Unit raise Thrown {
  match self.raw_profile(id) {
    Some(p) if borrowed(p) =>
      raise refusal(409, self.tr(lang, "station.share.borrowedEdit"))
    _ => ()
  }
}

///|
/// `rawProfile`: profile `id` as config.json has it.
fn Accounts::raw_profile(self : Accounts, id : String) -> JV? {
  jitems(self.config_raw.get("profiles")).iter().find_first(x => x.get("id") == Some(Str(id)))
}

///|
/// config.json edited (ops/config.ts `updateSoon`): the edit taken at once, refused where the result does not pass,
/// written behind it.
pub async fn Accounts::update_config(
  self : Accounts,
  edit : (JV) -> JV raise Thrown,
) -> JV {
  let next = edit(self.config_raw)
  if self.given.config_checked {
    check_config(Some(next), self.given.data)
  }
  self.config_raw = next
  self.hub_cache = None
  ignore(self.ask("config.put", [next]))
  next
}

///|
/// `save`: edits config.json (refused as 400 when the result does not pass), said in the log as `what`.
async fn Accounts::save(
  self : Accounts,
  viewer : JV,
  what : String,
  edit : (JV) -> JV raise Thrown,
) -> Unit {
  let run = async fn() {
    ignore(self.update_config(edit))
  }
  run() catch {
    e => raise refusal(400, message_of(e))
  }
  self.log("info", "config changed from the admin page", [
    ("what", js(what)),
    ("by", viewer.get("email").unwrap_or(jundef)),
  ])
}

///|
/// The profiles list of a config (`Array.isArray(raw.profiles) ? raw.profiles : []`).
fn profiles_of_raw(raw : JV) -> Array[JV] {
  match raw.get("profiles") {
    Some(Arr(a)) => a.copy()
    _ => []
  }
}

///|
fn env_key_ok(key : String) -> Bool {
  env_name_ok(key)
}

///|
fn workspace_id_ok(w : String) -> Bool {
  w.length() >= 1 &&
  w.length() <= 128 &&
  w
  .iter()
  .all(c => (c >= '0' && c <= '9') ||
    (c >= 'A' && c <= 'Z') ||
    (c >= 'a' && c <= 'z') ||
    c == '_' ||
    c == '-')
}

///|
/// `putProfile`: PUT /profiles/:id, a profile made or edited.
pub async fn Accounts::put_profile(
  self : Accounts,
  id : String,
  given : JV,
  viewer : JV,
  lang : String,
) -> Unit {
  let enabled_given = match given.get("enabled") {
    Some(x) if !is_undef(x) => Some(x)
    _ => None
  }
  match enabled_given {
    Some(Bool(_)) | None => ()
    _ => raise refusal(400, "enabled must be a boolean")
  }
  let pausing = jfields(Some(given)).iter().all(f => f.0 == "enabled") &&
    enabled_given is Some(_)
  if !pausing {
    self.own(id, lang)
  }
  let before = self.profile(id)
  if enabled_given is Some(_) &&
    (match before {
      Some(b) => b.machine
      None => false
    }) {
    raise refusal(400, "a machine login cannot be paused here")
  }
  if pausing &&
    before is Some(_) &&
    (match self.raw_profile(id) {
      Some(r) => borrowed(r)
      None => false
    }) {
    let enable = enabled_given == Some(Bool(true))
    self.save(viewer, "profile \{id}", raw => {
      let list = profiles_of_raw(raw)
      guard list.search_by(p => p.get("id") == Some(Str(id))) is Some(i) else {
        return raw
      }
      let existing = list[i]
      let share = existing.get("share").unwrap_or(Obj([]))
      let host_off = share.get("hostOff") == Some(Bool(true)) ||
        (
          existing.get("enabled") == Some(Bool(false)) &&
          share.get("paused") != Some(Bool(true))
        )
      let mut s = share
      if host_off {
        s = jset(s, "hostOff", jbool(true))
      }
      s = if !enable { jset(s, "paused", jbool(true)) } else { jdel(s, "paused") }
      let mut e = jset(existing, "share", s)
      e = if !enable || host_off {
        jset(e, "enabled", jbool(false))
      } else {
        jdel(e, "enabled")
      }
      list[i] = e
      jset(raw, "profiles", jarr(list))
    })
    if before.unwrap().enabled && !enable && self.given.hub_profile_gone {
      self.background.track(async fn() {
        self.profile_gone(id, "moving sessions off a paused copy failed")
      })
    }
    return
  }
  let given_workspaces = match given.get("workspaces") {
    Some(x) if !is_undef(x) => Some(x)
    _ => None
  }
  if given_workspaces is Some(_) && !manages_station(viewer) {
    raise refusal(403, self.tr(lang, "station.share.managersOnly"))
  }
  match given_workspaces {
    None | Some(Null) => ()
    Some(Arr(ws)) if ws.iter().all(w => w is Str(s) && workspace_id_ok(s)) => ()
    _ => raise refusal(400, "workspaces must be workspace ids")
  }
  let joined = self.joined()
  self.save(viewer, "profile \{id}", raw => {
    let list = profiles_of_raw(raw)
    let existing = list.iter().find_first(p => p.get("id") == Some(Str(id)))
    let machine = jget(existing, "machine") == Some(Bool(true))
    let get = (key : String) => if machine &&
      !["model", "models", "backgroundOnMessage", "fast", "maxConcurrentSessions", "newAccountProtection"].contains(key) {
      None
    } else {
      match given.get(key) {
        Some(x) if is_undef(x) => None
        x => x
      }
    }
    let mut env = match jget(existing, "env") {
      Some(Obj(_) as e) => e
      _ => Obj([])
    }
    match get("env") {
      Some(Obj(fields)) =>
        for f in fields {
          if !env_key_ok(f.0) {
            raise plain_error("invalid environment variable name \{f.0}")
          }
          match f.1 {
            Null => env = jdel(env, f.0)
            Str(_) => env = jset(env, f.0, f.1)
            _ => ()
          }
        }
      _ => ()
    }
    let access = get("access")
    let old_access = match jget(existing, "access") {
      Some(Obj(_)) as a => a
      _ => None
    }
    let kind = match access_kind_of(jget(access, "kind")) {
      Some(k) => Some(k)
      None => access_kind_of(jget(old_access, "kind"))
    }
    let given_key = match jget(access, "key") {
      Some(Str(k)) if trim_js(k) != "" && access is Some(Obj(_)) => Some(trim_js(k))
      _ => None
    }
    let keep = match old_access {
      Some(o) if (match kind {
          Some(k) => o.get("kind") == Some(Str(k))
          None => o.get("kind") is None
        }) => Some(o)
      _ => None
    }
    let key = match given_key {
      Some(k) => Some(k)
      None => jstr(jget(keep, "key"))
    }
    let provider = jstr(jget(keep, "provider"))
    let mut endpoint = jstr(jget(keep, "endpoint"))
    match jget(access, "endpoint") {
      Some(Str(e)) if access is Some(Obj(_)) => {
        endpoint = clean_endpoint(e)
        if endpoint is None {
          raise refusal(400, self.tr(lang, "station.profile.addressNeeded"))
        }
      }
      _ => ()
    }
    let protocol = jstr(jget(keep, "protocol"))
    let name = match get("name") {
      Some(Str(n)) => Some(trim_js(n))
      _ => jstr(jget(existing, "name"))
    }
    let given_model = get("model")
    let mut model = match given_model {
      Some(Str(m)) => Some(trim_js(m))
      Some(_) => None
      None => jstr(jget(existing, "model"))
    }
    if model == Some("") {
      model = None
    }
    let mut models : Array[String]? = match get("models") {
      Some(Arr(given_models)) => {
        let seen : Array[String] = []
        for m in given_models {
          let s = trim_js(
            match m {
              Str(s) => s
              other => stringify(other)
            },
          )
          if s != "" && !seen.contains(s) {
            seen.push(s)
          }
        }
        Some(if seen.length() > 200 { seen[0:200].to_array() } else { seen })
      }
      None =>
        match jget(existing, "models") {
          Some(Arr(m)) => Some(m.map(x => js_string(Some(x))))
          _ => None
        }
      Some(_) => None
    }
    if models is Some(m) && m.length() == 0 {
      models = None
    }
    match get("addModel") {
      Some(Str(added)) if trim_js(added) != "" => {
        let one = trim_js(added)
        let list = models.unwrap_or([])
        if !list.contains(one) {
          list.push(chars(one, 200))
        }
        models = Some(list)
      }
      _ => ()
    }
    let fast = match get("fast") {
      Some(Bool(f)) => Some(f)
      Some(_) => raise refusal(400, "fast must be a boolean")
      None =>
        match jget(existing, "fast") {
          Some(Bool(f)) => Some(f)
          _ => None
        }
    }
    let background = match get("backgroundOnMessage") {
      Some(Bool(b)) => Some(b)
      _ =>
        match jget(existing, "backgroundOnMessage") {
          Some(Bool(b)) => Some(b)
          _ => None
        }
    }
    let given_max_sessions = get("maxConcurrentSessions")
    let max_concurrent_sessions : Int? = match given_max_sessions {
      None =>
        match jget(existing, "maxConcurrentSessions") {
          Some(Num(n)) if is_integer(n) && n > 0.0 => Some(n.to_int())
          _ => None
        }
      Some(Null) => None
      Some(Num(n)) if is_integer(n) && n == 0.0 => None
      Some(Num(n)) if is_integer(n) && n > 0.0 => Some(n.to_int())
      Some(_) =>
        raise refusal(400, "maxConcurrentSessions must be a positive integer or null")
    }
    let given_protection = get("newAccountProtection")
    let new_account_protection = match given_protection {
      Some(Bool(false)) | Some(Null) => false
      Some(Bool(true)) => given_max_sessions is None && max_concurrent_sessions is Some(_)
      Some(_) => raise refusal(400, "newAccountProtection must be a boolean")
      None =>
        given_max_sessions is None &&
        max_concurrent_sessions is Some(_) &&
        jget(existing, "newAccountProtection") == Some(Bool(true))
    }
    let withheld : Array[String] = match given_workspaces {
      Some(Arr(ws)) => joined.filter(w => !ws.contains(Str(w)))
      Some(Null) => joined
      _ =>
        match jget(existing, "withheld") {
          Some(Arr(w)) => w.map(x => js_string(Some(x)))
          _ => []
        }
    }
    let home = match get("home") {
      Some(Str(h)) if trim_js(h) != "" => trim_js(h)
      _ =>
        match jget(existing, "home") {
          Some(Str(h)) => h
          _ => "homes/\{id}"
        }
    }
    let api = kind == Some("api-provider")
    let fields : Array[(String, JV)] = [("id", js(id))]
    match name {
      Some(n) if n != "" => fields.push(("name", js(n)))
      _ => ()
    }
    let (runtime, built_access) = put_profile_runtime_and_access(
      existing,
      get("runtime"),
      access,
      keep,
      kind,
      key,
      provider,
      endpoint,
      protocol,
      given_key,
    )
    match runtime {
      Some(r) => fields.push(("runtime", js(r)))
      None => ()
    }
    match built_access {
      Some(a) => fields.push(("access", a))
      None => ()
    }
    fields.push(("home", js(home)))
    fields.push(("env", env))
    match model {
      Some(m) => fields.push(("model", js(m)))
      None => ()
    }
    match models {
      Some(m) => fields.push(("models", jstrs(m)))
      None => ()
    }
    if machine {
      fields.push(("machine", jbool(true)))
    }
    match jget(existing, "share") {
      Some(Obj(_) as s) => fields.push(("share", s))
      _ => ()
    }
    if background == Some(false) {
      fields.push(("backgroundOnMessage", jbool(false)))
    }
    match max_concurrent_sessions {
      Some(n) => {
        fields.push(("maxConcurrentSessions", jint(n)))
        if new_account_protection {
          fields.push(("newAccountProtection", jbool(true)))
        }
      }
      None => ()
    }
    if fast == Some(true) {
      fields.push(("fast", jbool(true)))
    }
    let enabled_now = match enabled_given {
      Some(e) => Some(e)
      None => jget(existing, "enabled")
    }
    if enabled_now == Some(Bool(false)) {
      fields.push(("enabled", jbool(false)))
    }
    if withheld.length() > 0 {
      fields.push(("withheld", jstrs(withheld)))
    }
    let next = jobj(fields)
    match existing {
      Some(e) => {
        let kept = runtimes_for(next.get("access"), next.get("runtime"))
        for r in runtimes_for(e.get("access"), e.get("runtime")) {
          if !kept.contains(r) {
            last_of_runtime(self.ctx, raw, r, id, lang)
          }
        }
      }
      None => ()
    }
    match list.search_by(p => p.get("id") == Some(Str(id))) {
      Some(i) => list[i] = next
      None => list.push(next)
    }
    jset(raw, "profiles", jarr(list))
  })
  let was_enabled = match before {
    Some(b) => b.enabled
    None => true
  }
  if was_enabled &&
    enabled_given == Some(Bool(false)) &&
    
    self.given.hub_profile_gone {
    self.background.track(async fn() {
      self.profile_gone(id, "moving sessions off a disabled profile failed")
    })
  }
}

///|
/// `managesStation`: an owner's or an admin's.
pub fn manages_station(viewer : JV) -> Bool {
  viewer.get("role") == Some(Str("owner")) || viewer.get("role") == Some(Str("admin"))
}

///|
/// `#keepQuota`: an allowance read kept, and as its hour's.
fn Accounts::keep_quota(self : Accounts, id : String, quota : JV) -> Unit {
  self.background.track(async fn() {
    self.b.with_store(s => s.set_profile_quota(Json::string(id), jv_to_json(quota)))
  })
  self.pace_rev += 1
}

///|
/// `deleteProfile`: DELETE /profiles/:id. Its home stays.
pub async fn Accounts::delete_profile(
  self : Accounts,
  id : String,
  viewer : JV,
  lang : String,
) -> Unit {
  self.own(id, lang)
  self.save(viewer, "delete profile \{id}", raw => {
    let list = profiles_of_raw(raw)
    if !list.iter().any(p => p.get("id") == Some(Str(id))) {
      raise plain_error("unknown profile \{id}")
    }
    jset(raw, "profiles", jarr(list.filter(p => p.get("id") != Some(Str(id)))))
  })
  self.b.with_store(s => s.forget_profile_hours(Json::string(id)))
  self.pace_rev += 1
  if self.given.hub_profile_gone {
    self.background.track(async fn() {
      self.profile_gone(id, "moving sessions off a deleted profile failed")
    })
  }
}

///|
/// `lastOfRuntime`: a profile moved to another runtime, refused when it is the last one of a runtime connects run.
fn last_of_runtime(
  ctx : Ctx,
  raw : JV,
  runtime : String,
  id : String,
  lang : String,
) -> Unit raise Thrown {
  let profiles = jitems(raw.get("profiles"))
  if profiles.iter().any(p => p.get("id") != Some(Str(id)) &&
      runtimes_for(p.get("access"), p.get("runtime")).contains(runtime)) {
    return
  }
  let users = jitems(raw.get("connects"))
    .filter(c => jget(c.get("bind"), "runtime") == Some(Str(runtime)))
    .map(c => match jget(c.get("slack"), "botName") {
      Some(Str(n)) if n != "" => n
      _ => js_string(c.get("id"))
    })
  if users.length() > 0 {
    raise plain_error(
      ctx.tr(lang, "station.profile.lastForRuntime", args=[
        ("runtime", runtime),
        ("users", users.join(ctx.tr(lang, "station.list.separator"))),
      ]),
    )
  }
}

///|
/// `slug`: lower case, runs of anything else as one dash, at most `max` long.
pub fn slug(text : String, max : Int) -> String {
  let out = StringBuilder::new()
  let mut ends_dash = false
  for c in lower(text) {
    if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') {
      out.write_char(c)
      ends_dash = false
    } else if !ends_dash {
      out.write_char('-')
      ends_dash = true
    }
  }
  let mut s = out.to_string()
  while s.has_prefix("-") {
    s = slice(s, 1)
  }
  while s.has_suffix("-") {
    s = slice(s, 0, b=s.length() - 1)
  }
  s = chars(s, max)
  while s.has_suffix("-") {
    s = slice(s, 0, b=s.length() - 1)
  }
  s
}

///|
/// `unique`: the first of base, base-2, base-3 … not taken.
pub fn unique_id(base : String, taken : Map[String, Unit]) -> String {
  let mut id = base
  let mut n = 2
  while taken.contains(id) {
    id = "\{base}-\{n}"
    n += 1
  }
  id
}

///|
/// `takenIdsSoon`: ids a new profile may not take: the profiles' own, those being made, every home on disk.
async fn Accounts::taken_ids(self : Accounts) -> Map[String, Unit] {
  let homes = self.ctx.io.readdir(join_path([self.given.data, "homes"])) catch {
    _ => []
  }
  let taken : Map[String, Unit] = Map::new()
  for p in self.profiles() {
    taken[p.id] = ()
  }
  for m in self.making.keys() {
    taken[m] = ()
  }
  for h in homes {
    taken[h] = ()
  }
  taken
}

///|
/// The workspaces the station joined, its home one left out.
async fn Accounts::joined(self : Accounts) -> Array[String] {
  let all = self.workspaces()
  if all.length() > 1 {
    all[1:].to_array()
  } else {
    []
  }
}

///|
async fn Accounts::workspaces(self : Accounts) -> Array[String] {
  if !self.given.workspaces {
    return []
  }
  jitems(Some(self.ask("workspaces", []))).map(x => js_string(Some(x)))
}

///|
/// `hub.profileGone(id)`: its sessions taken on by another, or stopped; a failure logged as `what`.
async fn Accounts::profile_gone(self : Accounts, id : String, what : String) -> Unit {
  let run = async fn() { ignore(self.ask("hub.profileGone", [js(id)])) }
  run() catch {
    e => self.log("warn", what, [("profile", js(id)), ("error", js(message_of(e)))])
  }
}

///|
/// Pure helper for `Accounts::put_profile`: resolves `service`, `runtime` (omitted for `service` profiles),
/// and the serialized `access` object so edits to `service` profiles never drop `access.service` or write `runtime`.
fn put_profile_runtime_and_access(
  existing : JV?,
  given_runtime : JV?,
  access : JV?,
  keep : JV?,
  kind : String?,
  key : String?,
  provider : String?,
  endpoint : String?,
  protocol : String?,
  given_key : String?,
) -> (String?, JV?) {
  let service = match jget(access, "service") {
    Some(Str(s)) if trim_js(s) != "" && access is Some(Obj(_)) => Some(trim_js(s))
    _ => jstr(jget(keep, "service"))
  }
  let runtime = if kind == Some("service") {
    None
  } else {
    match runtime_kind(given_runtime) {
      Some(r) => Some(r)
      None => runtime_kind(jget(existing, "runtime"))
    }
  }
  let api = kind == Some("api-provider")
  let built_access = match kind {
    Some(k) => {
      let a = [("kind", js(k))]
      match key {
        Some(kv) => a.push(("key", js(kv)))
        None => ()
      }
      if k == "service" {
        match service {
          Some(s) => a.push(("service", js(s)))
          None => ()
        }
      }
      if api {
        match provider {
          Some(p) => a.push(("provider", js(p)))
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
      }
      let signs_in = k == "opencode-go" || (api && provider == Some(kimi_code))
      if signs_in && jget(keep, "login") == Some(Bool(true)) && given_key is None {
        a.push(("login", jbool(true)))
      }
      Some(jobj(a))
    }
    None => None
  }
  (runtime, built_access)
}
