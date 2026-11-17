// station/src/accounts/machine.ts: who this machine's own Claude Code and Codex are signed in as, in their usual homes
// (~/.claude, ~/.codex): for the pages that ask for a first profile, and for making a `machine` profile. Read at start,
// when a profile on it is made, after a runtime is installed, and when the overview is read with a reading older than
// two minutes (in the background: the overview answers with the last one). Nothing on the machine says when someone
// signs in or out in a terminal, so that age is what tells it to read again; who follows hears a reading that differs
// from the last (`changes`).

///|
pub(all) struct MachineLogin {
  runtime : String
  /// Its command is on the station's PATH.
  installed : Bool
  /// Signed in with an account (a subscription or a key).
  logged_in : Bool
  email : String?
  plan : String?
  /// A profile can use it as it is (kept in a file, not only in the keychain).
  usable : Bool
  /// Its allowance, as a profile on it would show (none until read, or when it cannot be).
  mut quota : Json
  /// In a line, as the pages show it.
  text : String
}

///|
pub fn MachineLogin::to_json(self : MachineLogin) -> Json {
  {
    "runtime": Json::string(self.runtime),
    "installed": Json::boolean(self.installed),
    "loggedIn": Json::boolean(self.logged_in),
    "email": opt(self.email),
    "plan": opt(self.plan),
    "usable": Json::boolean(self.usable),
    "quota": self.quota,
    "text": Json::string(self.text),
  }
}

///|
/// How long a reading serves before the next overview reads again.
let fresh_ms : Int64 = 120_000L

///|
fn machine_label(runtime : String) -> String {
  if runtime == "claude" {
    "Claude Code"
  } else {
    "Codex"
  }
}

///|
fn machine_login(runtime : String, installed : Bool, logged_in : Bool, text : String) -> MachineLogin {
  { runtime, installed, logged_in, email: None, plan: None, usable: false, quota: Json::null(), text }
}

///|
/// What the machine's logins are read with, besides the commands and files.
pub(all) struct MachineDeps {
  commands : Commands
  /// machine-logins.ts `readClaudeCredentials`: the keychain's (macOS) or the file's, its `subscriptionType` and
  /// `rateLimitTier`; none where it cannot be read.
  claude_credentials : async (Env) -> Json?
  /// machine-logins.ts `codexHome`.
  codex_home : (Env) -> String
  /// How a login's allowance is read (quota.ts machineUsage), where it is.
  usage : (async (String, Env) -> Json)?
}

///|
pub struct MachineLogins {
  priv mut logins : Array[MachineLogin]
  priv mut read_at : Int64
  priv mut reading : @effect.Deferred[Unit]?
  priv listeners : Array[(Int, () -> Unit)]
  priv mut next_listener : Int
  env : Env
  priv io : Io
  priv deps : MachineDeps
  priv words : Words
  priv lang : () -> String
}

///|
pub fn MachineLogins::new(
  io : Io,
  deps : MachineDeps,
  words : Words,
  env : Env,
  lang : () -> String,
) -> MachineLogins {
  {
    logins: [],
    read_at: 0L,
    reading: None,
    listeners: [],
    next_listener: 0,
    env,
    io,
    deps,
    words,
    lang,
  }
}

///|
/// The last reading, at once; read again in the background when it is old.
pub fn MachineLogins::get(self : MachineLogins) -> Array[MachineLogin] {
  if (self.io.now)() - self.read_at > fresh_ms {
    (self.io.spawn)(async fn() { self.refresh() catch { _ => () } })
  }
  self.logins.map(l => { ..l })
}

///|
/// Hears each reading that differs from the last; gives what stops it.
pub fn MachineLogins::changes(self : MachineLogins, listener : () -> Unit) -> () -> Unit {
  let id = self.next_listener
  self.next_listener += 1
  self.listeners.push((id, listener))
  () => {
    match self.listeners.search_by(l => l.0 == id) {
      Some(i) => ignore(self.listeners.remove(i))
      None => ()
    }
  }
}

///|
/// Reads them now (or waits for the reading under way).
pub async fn MachineLogins::refresh(self : MachineLogins) -> Unit {
  match self.reading {
    Some(d) => d.wait()
    None => {
      let d : @effect.Deferred[Unit] = @effect.Deferred::new()
      self.reading = Some(d)
      let failed = self.read() catch { e => Some(e) } noraise { _ => None }
      self.reading = None
      match failed {
        Some(e) => {
          ignore(d.fail(e))
          raise e
        }
        None => ignore(d.succeed(()))
      }
    }
  }
}

///|
/// A JSON value with every `checkedAt` key left out, at any depth (the replacer `said` uses).
fn without_checked_at(j : Json) -> Json {
  match j {
    Object(m) => {
      let out : Map[String, Json] = Map([])
      for k, v in m {
        if k != "checkedAt" {
          out[k] = without_checked_at(v)
        }
      }
      Json::object(out)
    }
    Array(a) => Json::array(a.map(without_checked_at))
    v => v
  }
}

///|
fn said_of(ls : Array[MachineLogin]) -> String {
  stringify(without_checked_at(Json::array(ls.map(l => l.to_json()))))
}

///|
async fn MachineLogins::read(self : MachineLogins) -> Unit {
  let lang = (self.lang)()
  let logins = [
    claude_login(self.deps, self.words, self.env, lang),
    codex_login(self.io, self.deps, self.words, self.env, lang),
  ]
  // Each one a profile could use, with its allowance: an account refused (suspended, say) shows before it is used.
  if self.deps.usage is Some(usage) {
    for l in logins {
      if !(l.logged_in && l.usable) {
        continue
      }
      let q = usage(l.runtime, self.env) catch { _ => { l.quota = Json::null(); continue } }
      l.quota = match q {
        Object(m) => {
          // (what a question's answer says of the asking, not of the allowance: not kept in it)
          let asked : Map[String, Json] = Map([])
          for k, v in m {
            if k != "signedOut" && k != "unanswered" {
              asked[k] = v
            }
          }
          asked["checkedAt"] = jnum((self.io.now)())
          Json::object(asked)
        }
        Array(a) => {
          let asked : Map[String, Json] = Map([])
          for i, v in a {
            asked[i.to_string()] = v
          }
          asked["checkedAt"] = jnum((self.io.now)())
          Json::object(asked)
        }
        v => v
      }
    }
  }
  // When it was read is not a change: what was read is.
  let changed = said_of(logins) != said_of(self.logins)
  self.logins = logins
  self.read_at = (self.io.now)()
  if changed {
    for l in self.listeners.copy() {
      (l.1)()
    }
  }
}

///|
/// The environment the machine's own CLI would run in: none of what points it at another home or account.
fn machine_env(env : Env, drop : Array[String]) -> Env {
  let out : Env = Map([])
  for k, v in env {
    if !drop.contains(k) {
      out[k] = v
    }
  }
  out
}

///|
let claude_drop : Array[String] = [
  "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
]

///|
fn tr(words : Words, lang : String, key : String, args : Array[(String, String)]) -> String {
  (words.tr)(lang, key, args)
}

///|
async fn claude_login(deps : MachineDeps, words : Words, env : Env, lang : String) -> MachineLogin {
  let rt = "claude"
  let name = machine_label(rt)
  let ran = (deps.commands.run)("claude", ["auth", "status"], machine_env(env, claude_drop), 20_000)
  let stdout = match ran {
    NotFound(_) => return machine_login(rt, false, false, tr(words, lang, "station.machine.notInstalled", [("name", name)]))
    TimedOut => return machine_login(rt, true, false, tr(words, lang, "station.machine.unreadableFor", [("name", name)]))
    Ended(_, out, _) => out
  }
  // `auth status` exits non-zero when signed out, still printing its JSON.
  let status = parse_json(stdout) catch {
    _ => return machine_login(rt, true, false, tr(words, lang, "station.machine.unreadableFor", [("name", name)]))
  }
  if !(get(Some(status), "loggedIn") is Some(True)) {
    return machine_login(rt, true, false, tr(words, lang, "station.machine.signedOut", [("name", name)]))
  }
  let email = str_of(get(Some(status), "email"))
  let credentials = (deps.claude_credentials)(env)
  let plan = claude_plan(
    either(get(Some(status), "subscriptionType"), get(credentials, "subscriptionType")),
    either(get(Some(status), "rateLimitTier"), get(credentials, "rateLimitTier")),
  )
  let usable = credentials is Some(_)
  let text = machine_said(words, name, email, plan, lang)
  {
    runtime: rt,
    installed: true,
    logged_in: true,
    email,
    plan,
    usable,
    quota: Json::null(),
    text: if usable {
      text
    } else {
      tr(words, lang, "station.machine.inKeychainUnreadable", [("text", text)])
    },
  }
}

///|
/// Claude's Max 20x subscription is now called Ultra. The subscription family alone says only `max`, so it is not
/// called Ultra unless the login also identifies the former 20x tier (or says `ultra` itself).
pub fn claude_plan(subscription : Json?, tier : Json?) -> String? {
  guard str_of(subscription) is Some(s) && trim(s) != "" else { return None }
  let plan = trim(s)
  let family = lower(plan)
  let rate = match str_of(tier) {
    Some(t) => lower(trim(t))
    None => ""
  }
  let old_ultra = ["default_claude_max_20x", "claude_max_20x", "max_20x"]
  if old_ultra.contains(family) || (family == "max" && old_ultra.contains(rate)) {
    return Some("ultra")
  }
  Some(plan)
}

///|
async fn codex_login(io : Io, deps : MachineDeps, words : Words, env : Env, lang : String) -> MachineLogin {
  let rt = "codex"
  let name = machine_label(rt)
  let home = (deps.codex_home)(env)
  let run_env = machine_env(env, ["OPENAI_API_KEY", "CODEX_API_KEY"])
  run_env["CODEX_HOME"] = home
  let ran = (deps.commands.run)("codex", ["login", "status"], run_env, 20_000)
  // `login status` exits non-zero when signed out.
  let text = match ran {
    NotFound(_) => return machine_login(rt, false, false, tr(words, lang, "station.machine.notInstalled", [("name", name)]))
    TimedOut => ""
    Ended(_, out, err) => out + err
  }
  let low = lower(text)
  if !includes(low, "logged in") || includes(low, "not logged in") {
    return machine_login(rt, true, false, tr(words, lang, "station.machine.signedOut", [("name", name)]))
  }
  let (email, plan) = codex_account(io, home)
  let usable = (io.exists)(join([home, "auth.json"])) catch { _ => false }
  let line = machine_said(words, name, email, plan, lang)
  {
    runtime: rt,
    installed: true,
    logged_in: true,
    email,
    plan,
    usable,
    quota: Json::null(),
    text: if usable {
      line
    } else {
      tr(words, lang, "station.machine.inKeychain", [("text", line)])
    },
  }
}

///|
/// The claims of a Codex home's id token (auth.json), when it has one.
pub async fn codex_claims_soon(io : Io, home : String) -> Json? {
  let text = (io.read)(join([home, "auth.json"])) catch { _ => return None }
  codex_claims_in(text)
}

///|
/// The claims of the id token an auth.json's text has.
pub fn codex_claims_in(text : String) -> Json? {
  let auth = parse_json(text) catch { _ => return None }
  let token = either(get(get(Some(auth), "tokens"), "id_token"), Some(Json::string("")))
  let parts = split(js_string(token), ".")
  guard parts.length() > 1 && parts[1] != "" else { return None }
  let mut payload = parts[1]
  while payload.has_suffix("=") {
    payload = sub(payload, 0, payload.length() - 1)
  }
  parse_json(base64url_text(payload)) catch { _ => return None } noraise { j => Some(j) }
}

///|
/// Codex's ChatGPT workspace and user, kept until the auth file changes. The account id is shared by members of a
/// workspace, while one person can belong to several workspaces: both identify whose allowance a profile spends.
pub struct CodexIds {
  priv kept : Map[String, (String, String?)]
}

///|
pub fn CodexIds::new() -> CodexIds {
  { kept: {} }
}

///|
pub async fn CodexIds::identity(self : CodexIds, io : Io, home : String) -> String? {
  let path = join([home, "auth.json"])
  let found = try {
    let st = (io.stat)(path)
    let stamp = "\{js_number(st.size)}:\{js_number(st.mtime_ms)}:\{js_number(st.ino)}"
    if self.kept.get(path) is Some((s, id)) && s == stamp {
      return id
    }
    let text = (io.read)(path)
    let id = get(get(Some(parse_json(text)), "tokens"), "account_id")
    let user = get(codex_claims_in(text), "sub")
    let found = match (str_of(id), str_of(user)) {
      (Some(i), Some(u)) if trim(i) != "" && trim(u) != "" => Some(stringify(jstrings([i, u])))
      _ => None
    }
    self.kept[path] = (stamp, found)
    found
  } catch {
    _ => {
      self.kept.remove(path)
      None
    }
  }
  found
}

///|
/// The account in Codex's auth.json: its id token's email and ChatGPT plan (none for an API key, or in the keyring).
async fn codex_account(io : Io, home : String) -> (String?, String?) {
  let claims = codex_claims_soon(io, home)
  match claims {
    None | Some(Null) | Some(False) => (None, None)
    Some(Number(n, ..)) if n == 0.0 => (None, None)
    Some(String("")) => (None, None)
    _ => {
      let email = either(get(claims, "email"), get(get(claims, "https://api.openai.com/profile"), "email"))
      let plan = get(get(claims, "https://api.openai.com/auth"), "chatgpt_plan_type")
      (str_of(email), str_of(plan))
    }
  }
}

///|
pub fn capitalized(plan : String) -> String {
  upper_first(plan)
}

///|
fn machine_said(words : Words, name : String, email : String?, plan : String?, lang : String) -> String {
  let p = match plan {
    Some(x) => Some(capitalized(x))
    None => None
  }
  match (email, p) {
    (Some(e), Some(p)) => tr(words, lang, "station.machine.signedInAsPlan", [("name", name), ("email", e), ("plan", p)])
    (Some(e), None) => tr(words, lang, "station.machine.signedInAs", [("name", name), ("email", e)])
    (None, Some(p)) => tr(words, lang, "station.machine.signedInPlan", [("name", name), ("plan", p)])
    (None, None) => tr(words, lang, "station.machine.signedIn", [("name", name)])
  }
}
