// What the overview shows of the accounts, and the automatic decisions (station/src/accounts/index.ts, its "automatic
// decisions" and "what the overview shows" parts): the profiles as the pages list them (whose account each home says,
// read off the thread and kept), the sign-ins for new profiles, the providers a key can be added for, the pace of
// each account's hours, the models the decisions may ask and their settings, the archive policy and its checks.

///|
/// `decisionModels`: the models the decisions may ask: each a usable profile's verified one, with the profiles that
/// have it.
pub async fn Accounts::decision_models(self : Accounts) -> JV {
  let order : Array[String] = []
  let models : Map[String, Array[String]] = Map::new()
  let cfg = self.hub_config()
  for profile in cfg.profiles {
    if !profile.enabled {
      continue
    }
    let health = match self.hub_accounts {
      Some(h) => h.health_of(cfg, profile.id)
      None => self.health(profile.id)
    }
    if !usable(health) {
      continue
    }
    let capability = match jget(health.check, "decision") {
      None | Some(Null) => continue
      Some(c) => c
    }
    let candidates = jitems(capability.get("models")).copy()
    match capability.get("model") {
      Some(m) if is_truthy(Some(m)) => candidates.push(m)
      _ => ()
    }
    for model in candidates {
      let resolved = self.ask("decision.resolvedModel", [profile.raw, capability, model])
      if !is_truthy(Some(resolved)) {
        continue
      }
      let key = js_string(Some(model))
      if !models.contains(key) {
        order.push(key)
        models[key] = []
      }
      let names = models[key]
      if !names.contains(profile.name) {
        names.push(profile.name)
      }
    }
  }
  stable_sort(order, (a, b) => {
    let c = js_compare(a, b)
    if c < 0 {
      -1.0
    } else if c > 0 {
      1.0
    } else {
      0.0
    }
  })
  let out = []
  for id in order {
    out.push(
      jobj([
        ("id", js(id)),
        ("name", self.ask("modelName", [js(id)])),
        ("profiles", jstrs(models[id])),
      ]),
    )
  }
  jarr(out)
}

///|
/// `putAutomaticDecisions`: PUT /automatic-decisions (a workspace manager's).
pub async fn Accounts::put_automatic_decisions(
  self : Accounts,
  input : JV,
  viewer : JV,
  lang : String,
) -> Unit {
  if !manages_station(viewer) {
    raise refusal(403, self.tr(lang, "station.decisions.managersOnly"))
  }
  check_automatic_decisions(Some(input)) catch {
    _ => raise refusal(400, self.tr(lang, "station.decisions.badSettings"))
  }
  let rule = match input.get("completion") {
    Some(Obj(_) as r) => r
    _ => Obj([])
  }
  let enabled = rule.get("enabled") == Some(Bool(true))
  let model = match rule.get("model") {
    Some(Str(m)) => js(m)
    _ => Null
  }
  if enabled {
    let verified = jitems(Some(self.decision_models())).iter().any(m => m.get("id") == Some(model))
    if !verified {
      raise refusal(400, self.tr(lang, "station.decisions.pickVerified"))
    }
  }
  let config = jobj([
    ("completion", jobj([("enabled", jbool(enabled)), ("model", model)])),
  ])
  self.save(viewer, "automatic decisions", raw => jset(raw, "automaticDecisions", config))
}

///|
/// `putArchiving`: PUT /archiving (a workspace manager's).
pub async fn Accounts::put_archiving(
  self : Accounts,
  input : JV,
  viewer : JV,
  lang : String,
) -> Unit {
  if !manages_station(viewer) {
    raise refusal(403, self.tr(lang, "station.archiving.managersOnly"))
  }
  let days = (v : JV?) => match v {
    Some(Num(n)) => !n.is_nan() && !n.is_inf() && n >= 0.0 && n <= 365.0
    _ => false
  }
  if !days(input.get("days")) ||
    !days(input.get("slackDays")) ||
    !(input.get("reviewed") is Some(Bool(_))) {
    raise refusal(400, self.tr(lang, "station.archiving.badSettings"))
  }
  let idle = input.get("days").unwrap()
  let slack_days = input.get("slackDays").unwrap()
  let reviewed = input.get("reviewed").unwrap()
  self.save(viewer, "archiving", raw => {
    let o = jset(raw, "autoArchiveDays", idle)
    let o = jset(o, "slackArchiveDays", slack_days)
    jset(o, "autoArchiveReviewed", reviewed)
  })
}

///|
/// `reviewUndecided`: POST /automatic-decisions/review: the done chats no decision has answered, reviewed now; how many.
pub async fn Accounts::review_undecided(
  self : Accounts,
  viewer : JV,
  lang : String,
) -> Double {
  if !manages_station(viewer) {
    raise refusal(403, self.tr(lang, "station.decisions.managersOnlyReview"))
  }
  if !self.given.review_undecided {
    raise refusal(503, self.tr(lang, "station.decisions.reviewUnsupported"))
  }
  if !self.hub_config().completion_enabled {
    raise refusal(409, self.tr(lang, "station.decisions.enableFirst"))
  }
  let queued = self.ask("reviewUndecided", [])
  if !self.hub_config().completion_enabled {
    raise refusal(409, self.tr(lang, "station.decisions.enableFirst"))
  }
  match queued {
    Null => raise refusal(409, self.tr(lang, "station.decisions.modelUnavailable"))
    q => to_number(Some(q))
  }
}

///|
/// `refreshDecisionModels`: POST /automatic-decisions/refresh: every profile checked again (four at a time).
pub async fn Accounts::refresh_decision_models(
  self : Accounts,
  viewer : JV,
  lang : String,
) -> Unit {
  if !manages_station(viewer) {
    raise refusal(403, self.tr(lang, "station.decisions.managersOnlyRefresh"))
  }
  self.check_each(self.profiles().filter(p => p.enabled).map(p => p.id), lang)
}

///|
/// `chatTitleOf`: what the session's chat is called in the chat list; its key only where it has no chat.
async fn Accounts::chat_title_of(self : Accounts, session : String) -> String {
  match self.ask("store.sessionChat", [js(session)]) {
    Obj(_) as chat =>
      js_string(
        Some(
          self.ask("views.titleOf", [
            chat.get("thread").unwrap_or(jundef),
            chat.get("firstText").unwrap_or(jundef),
            Null,
          ]),
        ),
      )
    _ =>
      match jget(Some(self.ask("store.getSession", [js(session)])), "title") {
        None | Some(Null) => session
        t => js_string(t)
      }
  }
}

///|
/// `checkLabel`: a check in a line: the option the model picked and what came of it, or that it failed.
pub fn check_label(ctx : Ctx, d : JV?, lang : String) -> String {
  let selected = match jget(jget(d, "result"), "selected") {
    Some(Str(s)) => s
    _ => return ctx.tr(lang, "station.decisions.failed")
  }
  let name = match jget(jget(d, "option"), "name") {
    Some(Str(n)) => n
    _ =>
      match selected {
        "complete" => "已做完"
        "agent_work" => "agent 还有活"
        "human_needed" => "等人处理"
        "uncertain" => "看不出来"
        s => s
      }
  }
  let verdict = if jget(d, "accepted") == Some(Bool(true)) {
    "station.decisions.archive"
  } else {
    "station.decisions.keep"
  }
  "\{name} · \{ctx.tr(lang, verdict)}"
}

///|
fn picked_of(d : JV?) -> String? {
  match jget(jget(d, "result"), "selected") {
    Some(Str(s)) => Some(s)
    _ => None
  }
}

///|
/// `automaticDecisionsView`: the overview's `automaticDecisions`. `visible`, `title`: a workspace overview's own.
pub async fn Accounts::automatic_decisions_view(
  self : Accounts,
  viewer : JV,
  include_policy? : Bool = true,
  visible? : async (String) -> Bool,
  title? : async (String) -> String,
) -> JV {
  if !manages_station(viewer) {
    return jobj([
      ("canEdit", jbool(false)),
      ("settings", Obj([])),
      ("models", jarr([])),
      ("recent", jarr([])),
    ])
  }
  let lang = self.ctx.station_lang
  let titles : Map[String, String] = Map::new()
  let title_of = async fn(session : String) -> String {
    match titles.get(session) {
      Some(t) => t
      None => {
        let t = match title {
          Some(f) => f(session)
          None => self.chat_title_of(session)
        }
        titles[session] = t
        t
      }
    }
  }
  let recent = []
  for row in jitems(Some(self.ask("store.recentDecisions", []))) {
    let session = match row.get("session") {
      Some(Str(s)) => s
      _ => ""
    }
    let shown = match visible {
      Some(f) => f(session)
      None => true
    }
    if !shown {
      continue
    }
    let d = match row.get("detail") {
      None | Some(Null) => JV::Obj([])
      Some(x) => x
    }
    let or_null = (k : String) => match d.get(k) {
      None | Some(Null) => JV::Null
      Some(x) => x
    }
    recent.push(
      jobj([
        ("id", row.get("id").unwrap_or(jundef)),
        ("session", js(session)),
        ("title", js(title_of(session))),
        ("at", row.get("at").unwrap_or(jundef)),
        ("label", js(check_label(self.ctx, Some(d), lang))),
        ("accepted", or_null("accepted")),
        ("model", or_null("model")),
        ("profile", or_null("profile")),
        ("elapsedMs", or_null("elapsedMs")),
        ("error", or_null("error")),
      ]),
    )
  }
  let settings = self.config_raw.get("automaticDecisions")
  let completion = match jget(settings, "completion") {
    Some(Obj(_)) as c => c
    _ => Some(Obj([]))
  }
  let fields = [
    ("canEdit", jbool(true)),
    ("canReview", jbool(self.given.review_undecided)),
    (
      "settings",
      jobj([
        (
          "completion",
          jobj([
            ("enabled", jbool(jget(completion, "enabled") == Some(Bool(true)))),
            (
              "model",
              match jget(completion, "model") {
                Some(Str(m)) => js(m)
                _ => Null
              },
            ),
          ]),
        ),
      ]),
    ),
    ("models", self.decision_models()),
    ("recent", jarr(recent)),
  ]
  if include_policy {
    fields.push(("policy", self.policy_view(title_of)))
  }
  jobj(fields)
}

///|
/// `policyView`: the archive policy as the pages show it.
async fn Accounts::policy_view(
  self : Accounts,
  title : async (String) -> String,
) -> JV {
  let saved = self.ask("store.archivePolicy", [])
  let policy = self.ask("policy.policyFrom", [saved])
  let now = to_number(Some(self.ask("store.now", [])))
  let latest_order : Array[String] = []
  let latest : Map[String, JV] = Map::new()
  for row in jitems(
    Some(self.ask("store.latestDecisionsSince", [jnum(now - policy_days * 86_400_000.0)])),
  ) {
    match row.get("session") {
      Some(Str(s)) => {
        if !latest.contains(s) {
          latest_order.push(s)
        } else {
          latest_order.retain(x => x != s)
          latest_order.push(s)
        }
        latest[s] = row
      }
      _ => ()
    }
  }
  let by_option : Map[String, Array[JV]] = Map::new()
  let mut failed = 0
  let reversed = latest_order.copy()
  reversed.rev_in_place()
  for session in reversed {
    let row = latest[session]
    match picked_of(row.get("detail")) {
      None => failed += 1
      Some(picked) => {
        let list = by_option.get(picked).unwrap_or([])
        list.push(
          jobj([
            ("session", js(session)),
            ("at", row.get("at").unwrap_or(jundef)),
            (
              "recommended",
              jbool(jget(row.get("detail"), "accepted") == Some(Bool(true))),
            ),
          ]),
        )
        by_option[picked] = list
      }
    }
  }
  let options = []
  for o in jitems(policy.get("options")) {
    let id = js_string(o.get("id"))
    let chats = by_option.get(id).unwrap_or([])
    let shown = []
    for c in if chats.length() > policy_chats {
      chats[0:policy_chats].to_array()
    } else {
      chats
    } {
      let session = js_string(c.get("session"))
      shown.push(
        jobj([
          ("session", js(session)),
          ("title", js(title(session))),
          ("at", c.get("at").unwrap_or(jundef)),
          ("recommended", c.get("recommended").unwrap_or(jundef)),
        ]),
      )
    }
    options.push(
      jspread(
        o,
        jobj([("count", jint(chats.length())), ("chats", jarr(shown))]),
      ),
    )
  }
  let change = match saved {
    Obj(_) => {
      let ch = saved.get("change")
      let by = jget(ch, "by")
      let by_view = if jget(by, "kind") == Some(Str("agent")) {
        let session = js_string(jget(by, "session"))
        jobj([
          ("kind", js("agent")),
          ("session", js(session)),
          ("title", js(title(session))),
          (
            "runtime",
            match jget(Some(self.ask("store.getSession", [js(session)])), "runtime") {
              None | Some(Null) => Null
              Some(r) => r
            },
          ),
        ])
      } else {
        jobj([
          ("kind", js("person")),
          (
            "email",
            match jget(by, "email") {
              None | Some(Null) => Null
              Some(e) => e
            },
          ),
          (
            "name",
            match jget(by, "name") {
              None | Some(Null) => Null
              Some(n) => n
            },
          ),
        ])
      }
      jobj([
        ("at", jget(ch, "at").unwrap_or(jundef)),
        ("summary", jget(ch, "summary").unwrap_or(jundef)),
        ("by", by_view),
      ])
    }
    _ => Null
  }
  jobj([
    ("text", policy.get("policy").unwrap_or(jundef)),
    ("options", jarr(options)),
    ("days", jnum(policy_days)),
    ("checked", jint(latest.size())),
    ("failed", jint(failed)),
    ("edited", jbool(saved != Null)),
    ("change", change),
  ])
}

///|
/// `putArchivePolicy`: PUT /automatic-decisions/policy (a workspace manager's).
pub async fn Accounts::put_archive_policy(
  self : Accounts,
  input : JV,
  viewer : JV,
  lang : String,
) -> Unit {
  if !manages_station(viewer) {
    raise refusal(403, self.tr(lang, "station.decisions.managersOnlyPolicy"))
  }
  let name = match viewer.get("name") {
    Some(Str(n)) if n != "" => js(n)
    _ => Null
  }
  let changed = self.ask("policy.savePolicy", [
      input,
      jobj([
        ("kind", js("person")),
        ("email", viewer.get("email").unwrap_or(jundef)),
        ("name", name),
      ]),
    ]) catch {
    e => raise refusal(400, message_of(e))
  }
  if changed != Null && self.given.review_undecided {
    self.background.track(async fn() { ignore(self.ask("reviewUndecided", [])) })
  }
}

///|
/// `homeAsked`: what a profile's home is read for: the home, and what in it says whose account it is.
fn home_asked(p : Profile) -> (String, String, String?) {
  let files = if access_kind(p.raw) == "subscription" {
    if borrowed(p.raw) {
      None
    } else {
      Some("account")
    }
  } else if jget(p.get("access"), "login") == Some(Bool(true)) &&
    p.get("access") is Some(Obj(_)) {
    Some("console")
  } else {
    None
  }
  let home = match p.get("home") {
    None | Some(Null) => ""
    h => js_string(h)
  }
  (home, js_string(p.get("runtime")), files)
}

///|
/// `JSON.stringify(homeAsked(p))`.
fn home_asked_key(p : Profile) -> String {
  let (home, _, files) = home_asked(p)
  stringify(
    jobj([
      ("home", js(home)),
      ("runtime", p.get("runtime").unwrap_or(jundef)),
      ("files", jopt(files)),
    ]),
  )
}

///|
/// One of the files a home says whose account it is by, and how it says it.
priv struct AccountFile {
  path : String
  email : async (String) -> String?
}

///|
fn email_of_json(text : String, pick : (JV) -> JV?) -> String? raise Thrown {
  let j = json_parse(text)
  match pick(j) {
    Some(Str(e)) => Some(e)
    _ => None
  }
}

///|
/// `accountFiles`: where a home keeps whose account it is signed in to, by its runtime, in the order looked at.
fn Accounts::account_files(self : Accounts, runtime : String, home : String) -> Array[AccountFile] {
  let noted = async fn(text : String) -> String? {
    let j = json_parse(text)
    match j.get("email") {
      Some(Str(e)) if e != "" => Some(e)
      _ => None
    }
  }
  match runtime {
    "grok" =>
      [
        {
          path: join_path([home, "grok", "auth.json"]),
          email: async fn(text) {
            let auth = json_parse(text)
            let values = match auth {
              Obj(fields) => fields.map(f => f.1)
              Arr(items) => items
              _ => []
            }
            for entry in values {
              match entry.get("email") {
                Some(Str(e)) if e != "" => return Some(e)
                _ => ()
              }
            }
            None
          },
        },
      ]
    "cursor" =>
      [
        {
          path: cursor_auth_file(home),
          email: async fn(text) {
            match cursor_in(text) {
              Some(l) => l.email
              None => None
            }
          },
        },
      ]
    "devin" => [{ path: join_path([home, "devin", "account.json"]), email: noted }]
    "agy" =>
      [
        {
          path: join_path([home, "agy", ".gemini", "antigravity-cli", "antigravity-oauth-token"]),
          email: async fn(text) {
            match try_parse(text) {
              Some(j) =>
                match j.get("id_token_email") {
                  Some(Str(e)) if e != "" => Some(e)
                  _ => None
                }
              None => None
            }
          },
        },
        { path: join_path([home, "agy", "account.json"]), email: noted },
      ]
    "codex" =>
      [
        {
          path: join_path([home, "auth.json"]),
          email: async fn(text) {
            let claims = defined(self.ask("codex.claimsIn", [js(text)]))
            let said = match jget(claims, "email") {
              None | Some(Null) => jget(jget(claims, "https://api.openai.com/profile"), "email")
              x => x
            }
            match said {
              Some(Str(e)) => Some(e)
              _ => None
            }
          },
        },
      ]
    _ => {
      let email = async fn(text : String) -> String? {
        email_of_json(text, j => jget(j.get("oauthAccount"), "emailAddress"))
      }
      [
        { path: join_path([home, ".claude.json"]), email },
        { path: join_path([home, "claude.json"]), email },
      ]
    }
  }
}

///|
/// `emailInSoon`: what the first of `files` that names an account says, kept by each file's size and time.
async fn Accounts::email_in(self : Accounts, files : Array[AccountFile]) -> String? {
  for file in files {
    let stamp = self.ctx.io.stamp(file.path) catch {
      _ => continue
    }
    let kept = self.emails.get(file.path)
    match kept {
      Some((s, email)) if s == stamp =>
        match email {
          Some(e) => return Some(e)
          None => continue
        }
      _ => ()
    }
    let text = self.ctx.io.read_file_or_none(file.path).unwrap_or("")
    let email = (file.email)(text) catch {
      _ => None
    }
    self.emails[file.path] = (stamp, email)
    match email {
      Some(e) => return Some(e)
      None => ()
    }
  }
  None
}

///|
/// `accountEmailSoon`: the account a subscription home is signed in as, when its files say.
pub async fn Accounts::account_email(
  self : Accounts,
  runtime : String,
  home : String,
) -> String? {
  self.email_in(self.account_files(runtime, home))
}

///|
/// `homeSaysSoon`: what a profile's home says, read off the thread.
async fn Accounts::home_says_soon(self : Accounts, p : Profile) -> HomeSays {
  let (home, runtime, files) = home_asked(p)
  let email = match files {
    Some("account") => self.account_email(runtime, home)
    Some(_) =>
      self.email_in([
        {
          path: join_path([home, "opencode-console.json"]),
          email: async fn(text) {
            let said = self.ask("console.in", [js(text)])
            match said.get("email") {
              Some(Str(e)) => Some(e)
              _ => None
            }
          },
        },
      ])
    None => None
  }
  { exists: self.ctx.io.exists(home), email }
}

///|
/// `homeSays`: what profile `p`'s home says, as last read; one not read yet is read off the thread, what it found
/// told.
fn Accounts::home_says(self : Accounts, p : Profile) -> HomeSays {
  let asked = home_asked_key(p)
  match self.homes.get(p.id) {
    Some((a, says)) if a == asked => return says
    _ => ()
  }
  self.background.track(async fn() { self.home_read(p, true) })
  { exists: true, email: None }
}

///|
/// `homesReadSoon`: the homes of the profiles not read yet, read off the thread (what the overview waits for).
pub async fn Accounts::homes_read_soon(self : Accounts) -> Unit {
  let profiles = self
    .profiles()
    .filter(p => match self.homes.get(p.id) {
      Some((a, _)) => a != home_asked_key(p)
      None => true
    })
  for p in profiles {
    self.home_read(p, false)
  }
}

///|
/// `homeRead`: profile `p`'s home read and kept, unless a sign-in changed it meanwhile; `tell`: what it found told.
async fn Accounts::home_read(self : Accounts, p : Profile, tell : Bool) -> Unit {
  let asked = home_asked_key(p)
  let key = "\{p.id}\n\{asked}"
  let since = self.homes_changed
  match self.home_reads.get(key) {
    Some(under) if under.since == since => {
      under.tell = under.tell || tell
      under.read.wait()
      return
    }
    _ => ()
  }
  let entry : HomeRead = { since, tell, read: @effect.Deferred::new() }
  self.home_reads[key] = entry
  let run = async fn() {
    let says = self.home_says_soon(p)
    if self.homes_changed != since {
      return
    }
    self.homes[p.id] = (asked, says)
    if entry.tell && !self.closed {
      self.changed()
    }
  }
  run() catch {
    _ => ()
  }
  match self.home_reads.get(key) {
    Some(e) if physical_equal(e, entry) => self.home_reads.remove(key)
    _ => ()
  }
  ignore(entry.read.succeed(()))
}

///|
/// `readHomesSoon`: every profile's home read again, once 10 s have passed since the last time; what changed told.
fn Accounts::read_homes_soon(self : Accounts, profiles : Array[Profile]) -> Unit {
  let now = self.background.now()
  if self.homes_reading || now - self.homes_read < homes_every_ms {
    return
  }
  self.homes_reading = true
  self.homes_read = now
  self.background.track(async fn() {
    let mut changed = false
    for p in profiles {
      let asked = home_asked_key(p)
      let since = self.homes_changed
      let says = Some(self.home_says_soon(p)) catch {
        _ => None
      }
      let kept = self.homes.get(p.id)
      guard says is Some(says) else { continue }
      match kept {
        Some((a, k)) if a == asked && self.homes_changed == since => {
          if k == says {
            continue
          }
          self.homes[p.id] = (asked, says)
          changed = true
        }
        _ => continue
      }
    }
    if changed {
      self.changed()
    }
    self.homes_reading = false
  })
}

///|
/// `email`: the account a subscription profile is signed in as.
async fn Accounts::email(self : Accounts, p : Profile, says : HomeSays) -> JV {
  if borrowed(p.raw) {
    return match jget(p.get("share"), "email") {
      Some(Str(e)) => js(e)
      _ => Null
    }
  }
  if p.machine {
    let logins = jitems(Some(self.machine_logins()))
    match logins.iter().find_first(l => l.get("runtime") == Some(Str(p.runtime))) {
      Some(l) =>
        match l.get("email") {
          None | Some(Null) => ()
          Some(e) => return e
        }
      None => ()
    }
    return jopt(says.email)
  }
  jopt(says.email)
}

///|
/// `profilesView`: the overview's `profiles`.
pub async fn Accounts::profiles_view(self : Accounts, viewer : JV?) -> JV {
  let config = self.hub_config()
  let joined = match viewer {
    Some(v) if v.get("home") == Some(Bool(false)) => jstr(v.get("workspace"))
    _ => None
  }
  let all = self.workspaces()
  let home = all.get(0)
  let others = if all.length() > 1 { all[1:].to_array() } else { [] }
  // The viewer's workspace, whose stations alone a shared profile's view names (Null: all).
  let viewer_ws = match viewer {
    Some(v) =>
      match v.get("workspace") {
        Some(Str(_) as w) => w
        _ => Null
      }
    None => Null
  }
  self.read_homes_soon(config.profiles)
  let views = []
  for p in config.profiles {
    let says = self.home_says(p)
    let kind = access_kind(p.raw)
    let a = match p.get("access") {
      Some(Obj(_) as x) => x
      _ => Obj([])
    }
    let via = profile_via(p.raw)
    let custom = match p.get("env") {
      Some(Obj(fields)) => fields
      _ => []
    }
    let keys = custom.map(f => f.0)
    stable_sort(keys, (x, y) => js_compare(x, y).to_double())
    let env = keys.map(key => {
      let value = custom.iter().find_first(f => f.0 == key).unwrap().1
      jobj([
        ("key", js(key)),
        ("secret", jbool(secret_key(key))),
        (
          "value",
          if secret_key(key) {
            js(mask(js_string(Some(value))))
          } else {
            value
          },
        ),
      ])
    })
    let check_view = match self.checks.get(p.id) {
      Some(check) => {
        let mut view = jdel(check, "fusion")
        match view.get("decision") {
          Some(Obj(_) as d) => view = jset(view, "decision", jdel(d, "fingerprint"))
          _ => ()
        }
        match check.get("decision") {
          Some(d) if is_truthy(Some(d)) => {
            let fp = self.fingerprint(p)
            if d.get("fingerprint") != Some(Str(fp)) {
              view = jset(
                view,
                "decision",
                jobj([
                  ("state", js("pending")),
                  ("detail", js("Profile 已修改，等待自动检查")),
                  ("reason", js("changed")),
                ]),
              )
            }
          }
          _ => ()
        }
        view
      }
      None => Null
    }
    let email = if kind == "subscription" {
      self.email(p, says)
    } else if a.get("login") == Some(Bool(true)) {
      jopt(says.email)
    } else {
      Null
    }
    let fast = if takes_fast(p.raw) &&
      (
        !fast_needs_credits(p.raw) ||
        jget(self.quotas.get(p.id), "extraUsage") == Some(Bool(true))
      ) {
      jbool(p.get("fast") == Some(Bool(true)))
    } else {
      Null
    }
    let used_by = if !p.enabled {
      []
    } else {
      config.connects
      .filter(c => p.runtimes.contains(c.runtime) && serves(p, c.model))
      .map(c => c.id)
    }
    let login_command = if kind == "subscription" {
      self.ask("profiles.loginCommand", [js(p.runtime), js(p.home), jbool(p.machine)])
    } else {
      js("")
    }
    views.push(
      (
        jobj([
          ("id", p.get("id").unwrap_or(jundef)),
          ("name", js(p.name)),
          ("runtime", js(p.runtime)),
          ("runtimes", jstrs(p.runtimes)),
          ("email", email),
          (
            "access",
            jobj([
              ("kind", js(if kind == "api-provider" { "env" } else { kind })),
              (
                "key",
                js(
                  mask(
                    trim_js(
                      match a.get("key") {
                        None | Some(Null) => ""
                        k => js_string(k)
                      },
                    ),
                  ),
                ),
              ),
              ("provider", jopt(via.provider)),
              ("endpoint", jopt(via.endpoint)),
              ("protocol", jopt(via.protocol)),
              (
                "login",
                jbool(
                  (kind == "opencode-go" || kimi_signed_in(p.raw)) &&
                  a.get("login") == Some(Bool(true)),
                ),
              ),
            ]),
          ),
          ("home", js(p.home)),
          ("homeExists", jbool(says.exists)),
          ("model", jopt(p.model)),
          ("models", jstrs(p.models)),
          ("named", jstrs(p.named)),
          ("env", jarr(env)),
          ("usedBy", jstrs(used_by)),
          ("loginCommand", login_command),
          ("machine", jbool(p.machine)),
          ("enabled", jbool(p.enabled)),
          ("backgroundOnMessage", jbool(p.background_on_message)),
          ("fast", fast),
          ("check", check_view),
          ("login", self.ask("logins.get", [js(p.id)])),
          ("quota", self.quotas.get(p.id).unwrap_or(Null)),
          (
            "share",
            if self.given.shared {
              match self.ask("shared.view", [p.raw, viewer_ws]) {
                x if is_undef(x) => Null
                x => x
              }
            } else {
              Null
            },
          ),
          (
            "shareable",
            jbool(self.ask("share.shareRefusal", [p.raw]) == Null),
          ),
          ("workspaces", jstrs(others.filter(w => allowed_in(p, Some(w), home)))),
          ("serves", jbool(allowed_in(p, joined, home))),
        ]),
        used_by,
      ),
    )
  }
  match joined {
    None => jarr(views.map(v => v.0))
    Some(ws) => {
      let connects = config.connects
        .filter(c => c.workspace == Some(ws))
        .map(c => c.id)
      jarr(
        views.map(v => jset(v.0, "usedBy", jstrs(v.1.filter(c => connects.contains(c))))),
      )
    }
  }
}

///|
/// `paceView`: GET /profiles/pace: the hours of the accounts the viewer's workspace may run on, read again once a
/// minute at most or as an allowance is read.
pub async fn Accounts::pace_view(self : Accounts, viewer : JV?) -> JV {
  let now = to_number(Some(self.ask("store.now", [])))
  let minute = (now / 60000.0).floor()
  let stale = match self.pace_read {
    None => true
    Some((m, rev, _, _)) => m != minute || rev != self.pace_rev
  }
  if stale {
    let read = self.ask("store.profileHours", [jnum((now / 3_600_000.0).floor())])
    self.pace_read = Some((minute, self.pace_rev, now, read))
  }
  let joined = match viewer {
    Some(v) if v.get("home") == Some(Bool(false)) => jstr(v.get("workspace"))
    _ => None
  }
  let home = self.workspaces().get(0)
  let serves_ids = self
    .hub_config()
    .profiles.filter(p => allowed_in(p, joined, home))
    .map(p => p.id)
  let (_, _, read_now, read) = self.pace_read.unwrap()
  pace_view(self.catalog, read_now, read, id => serves_ids.contains(id))
}

///|
/// `fusionView`: GET /profiles/:id/fusion: the Devin Fusion catalog from the profile's last check.
pub fn Accounts::fusion_view(self : Accounts, id : String) -> JV raise Thrown {
  guard self.profile(id) is Some(profile) else {
    raise refusal(404, "unknown profile \{id}")
  }
  if borrowed(profile.raw) {
    return Null
  }
  match jget(self.checks.get(id), "fusion") {
    None | Some(Null) => Null
    Some(f) => f
  }
}

///|
/// `loginsView`: the overview's `logins`: sign-ins for new profiles.
pub async fn Accounts::logins_view(self : Accounts) -> JV {
  let out = []
  for e in self.pending.iter() {
    out.push(
      jobj([
        ("id", js(e.0)),
        ("runtime", js(e.1.runtime)),
        ("job", self.ask("logins.get", [js(e.0)])),
        ("created", jopt(e.1.created)),
        ("error", jopt(e.1.error)),
      ]),
    )
  }
  jarr(out)
}

///|
/// `machineLogins`: the overview's `machineLogins`.
pub async fn Accounts::machine_logins(self : Accounts) -> JV {
  if self.given.machine {
    self.ask("machine.get", [])
  } else {
    jarr([])
  }
}

///|
/// `apiProviders`: the providers a key can be added for (not the two kinds from before the list).
pub fn api_providers() -> JV {
  jarr(
    sources
    .filter(s => !legacy_source(s.id))
    .map(s => jobj([("id", js(s.id)), ("name", js(s.name)), ("group", js(group_of(s.id)))])),
  )
}

///|
/// What the accounts hold now, for a test to compare: the checks, allowances, what stands unanswered, the sign-ins
/// for new profiles.
pub fn Accounts::state(self : Accounts) -> JV {
  let mut checks = JV::Obj([])
  for e in self.checks.iter() {
    checks = jset(checks, e.0, e.1)
  }
  let mut quotas = JV::Obj([])
  for e in self.quotas.iter() {
    quotas = jset(quotas, e.0, e.1)
  }
  let mut unanswered = JV::Obj([])
  for e in self.quota_unanswered.iter() {
    unanswered = jset(unanswered, e.0, jobj([("detail", js(e.1.0)), ("at", jnum(e.1.1))]))
  }
  let mut pending = JV::Obj([])
  for e in self.pending.iter() {
    pending = jset(
      pending,
      e.0,
      jobj([
        ("runtime", js(e.1.runtime)),
        ("access", jopt(e.1.access)),
        ("home", js(e.1.home)),
        ("created", jopt(e.1.created)),
        ("error", jopt(e.1.error)),
      ]),
    )
  }
  let mut generation = JV::Obj([])
  for e in self.login_generation.iter() {
    generation = jset(generation, e.0, jint(e.1))
  }
  jobj([
    ("checks", checks),
    ("quotas", quotas),
    ("unanswered", unanswered),
    ("pending", pending),
    ("loginGeneration", generation),
    ("config", self.config_raw),
  ])
}
