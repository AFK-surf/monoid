// station/src/accounts/login.ts: signing a subscription profile in from the pages. The runtime's own login command
// runs here, on the station's machine, so the credentials land in the profile's home; the page only relays what the
// person has to do in their browser:
// - Claude: `claude auth login` prints an authorize link; after approving, the browser shows a code, which the person
//   pastes back and the station types in.
// - Codex: `codex login --device-auth` prints a link and a one-time code; the person enters the code on that page and
//   the command finishes by itself. Grok Build's `grok login --device-auth` the same.
// - Devin: `devin auth login --force-manual-token-flow` in a terminal of its own prints a link; the code its page shows
//   is pasted back, as Claude's.
// - Antigravity CLI: `agy` itself, in a terminal of its own with an empty HOME of this sign-in's, told to keep its
//   sign-in in a file there; its menus answered (`agy_answer`), its link's code pasted (or read off the station's
//   browser), done once its file is written whole, then copied into the profile's agy/.
// - OpenCode Go (`start_console`) and Kimi Code (`start_kimi`): a device grant the station follows itself.
// - Cursor (`start_cursor`): the station makes the login's page itself; the person confirms it there.
// A stand-in `open` on PATH keeps the commands from opening a browser on the server; it writes down the page a command
// would have opened, which the station's own browser opens when a person asks. Who follows hears each change of a job.

///|
pub(all) struct LoginJob {
  profile : String
  runtime : String
  /// Signing in to OpenCode or Kimi rather than the runtime's subscription.
  provider : String?
  mut state : String
  mut url : String?
  mut user_code : String?
  mut error : String?
  started_at : Int64
  mut expires_at : Int64
  /// Its page can be opened in the station's browser now.
  mut browser : Bool
  /// The screen of the tab its page is open in, in the station's browser, while it is.
  mut screen : String?
  /// Of a service profile's sign-in (no runtime: `runtime` is ""): the service, `colab`.
  service : String?
}

///|
pub fn LoginJob::to_json(self : LoginJob) -> Json {
  let m : Map[String, Json] = { "profile": Json::string(self.profile) }
  if self.runtime != "" {
    m["runtime"] = Json::string(self.runtime)
  }
  if self.service is Some(s) {
    m["service"] = Json::string(s)
  }
  if self.provider is Some(p) {
    m["provider"] = Json::string(p)
  }
  m["state"] = Json::string(self.state)
  m["url"] = opt(self.url)
  m["userCode"] = opt(self.user_code)
  m["error"] = opt(self.error)
  m["startedAt"] = jnum(self.started_at)
  m["expiresAt"] = jnum(self.expires_at)
  if self.screen is Some(s) {
    m["screen"] = Json::string(s)
  }
  if self.browser {
    m["browser"] = Json::boolean(true)
  }
  Json::object(m)
}

///|
fn LoginJob::copy(self : LoginJob) -> LoginJob {
  { ..self }
}

///|
/// A sign-in's tab in the station's browser is known by this.
fn page_key(profile : String) -> String {
  "profile:\{profile}"
}

///|
let login_timeout_ms : Int64 = 900_000L

///|
/// How long Claude's and Devin's commands are given to take a pasted code and end.
pub let verify_wait_ms : Int64 = 90_000L

///|
/// What `claude auth login` says of a pasted code it would not take; it then waits for Enter and another code.
let claude_code_refused : String = "make sure the full code was copied"

///|
/// Variables that would make the login command talk to something other than the subscription.
let scrubbed : Array[String] = [
  "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CONFIG_DIR", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT",
  "CODEX_HOME", "OPENAI_API_KEY", "GROK_HOME", "GROK_AUTH", "GROK_AUTH_PATH", "XAI_API_KEY", "WINDSURF_API_KEY", "XDG_DATA_HOME",
  "GEMINI_API_KEY", "GOOGLE_API_KEY", "AGY_ADC_AUTH", "AGY_ACCOUNT", "ANTIGRAVITY_GEMINI_DIR",
]

///|
/// The terminal Devin's (and the Antigravity CLI's) login runs in: wide, so that its link is printed on one line.
let devin_cols : Int = 1000

///|
let devin_rows : Int = 40

///|
let agy_poll_ms : Int64 = 500L

///|
let agy_wait_ms : Int64 = 90_000L

///|
let agy_key_gap_ms : Int64 = 50L

///|
/// What the Antigravity CLI says when a company's sign-in fails after its code or project went in (1.5.9).
let agy_failures : Array[String] = [
  "[Auth Error]", "Couldn't sign in", "Failed to select license", "Failed to save GCP settings", "Permission denied",
]

///|
/// What it says where a Google Cloud account may not list its licences: no failure, it goes on to ask how to pay.
let agy_no_licences : String = "Could not fetch licenses"

///|
/// What it asks the terminal as a remote session's (`ESC [ c`), and the answer it is given.
let agy_terminal_asked : String = "\u{1b}[c"

///|
let agy_terminal_answer : String = "\u{1b}[?1;2c\u{1b}[>0;276;0c"

///|
/// agy.ts `AGY_FILE_TOKENS`: its sign-in kept in a file, as a remote session's.
let agy_file_tokens : Array[(String, String)] = [("SSH_CLIENT", "127.0.0.1 0 0")]

///|
/// Where a profile keeps the cookies and passkeys of its sign-in tab in the station's browser, inside its own home.
pub let login_browser_file : String = ".stillfail-login-state.json"

///|
/// What a sign-in is for: a profile's id, the runtime it signs in to, its home, and (for Claude) the account email to
/// pre-populate. `enterprise`: an Antigravity CLI sign-in to a company's Google account.
pub(all) struct LoginProfile {
  id : String
  runtime : String
  home : String
  email : String?
  enterprise : Bool
}

///|
/// The login commands, by runtime.
pub(all) struct LoginCommands {
  claude : String
  codex : String
  grok : String?
  devin : String?
  agy : String?
}

///|
/// A login command's process, as the platform started it.
pub(all) struct Child {
  pid : Int?
  /// Its stdin is there to write to.
  writable : () -> Bool
  /// Written, waited for.
  write : async (String) -> Unit
  /// Written, not waited for (an error let go).
  send : (String) -> Unit
  /// SIGTERM.
  kill : () -> Unit
}

///|
/// What a command's process tells: what it wrote (stdout or stderr), and its end (`close`: code, signal).
pub(all) struct ChildEvents {
  output : (String) -> Unit
  close : (Int?, String?) -> Unit
}

///|
/// The station's platform, as the sign-ins ask it.
pub(all) struct LoginPlatform {
  /// platform `terminalSoon`: the command and args that run `command` in a pseudo-terminal of `cols` × `rows`; none
  /// where there is none.
  terminal : async (String, Array[String], Int, Int) -> (String, Array[String])?
  prepend_path : (Env, String) -> Env
  /// platform `runnableSoon`.
  runnable : async (String, Array[String], Env) -> (String, Array[String])
  /// platform `makeCommandSoon`: a script made a command at `path`; what it is called by.
  make_command : async (String, String) -> String
  /// shell-path.ts `withShellCommand`: the environment it runs in where the shell's PATH finds it; none where `env` stands.
  with_shell_command : async (String, Env, Env) -> Env?
  /// no-keychain.ts `fileCredentialsSoon`.
  file_credentials : async (Env) -> Unit
  /// `spawn` (in `cwd`, with `env`), told what it does; fails with the words of why it did not start.
  spawn : async (String, Array[String], String, Env, ChildEvents) -> Child
  /// platform `descendants`.
  descendants : async (Int) -> Array[Int]
  /// `process.kill(pid, "SIGTERM")`.
  kill : (Int) -> Unit
}

///|
/// A device grant's steps (console.ts's, kimi.ts's).
pub(all) struct DeviceSteps {
  start : async () -> Device
  ask : async (String) -> DeviceAnswer
  /// What is written to the profile's home of the tokens (made first: what it needs to ask is asked before).
  keep : async (Token) -> (async () -> Unit)
}

///|
/// The station's browser, for the pages of sign-ins (logins/pages.ts).
pub(all) struct LoginPages {
  changes : ((String) -> Unit) -> Unit
  url_of : (String) -> String?
  close : (String) -> Unit
  screen_of : (String) -> String?
  can : () -> Bool
  /// Opens `url` in the tab of `key` (its browser state kept in what `state_file` names); its screen.
  open : async (String, String, () -> String?) -> String
}

///|
/// What the sign-ins ask of the station's other parts.
pub(all) struct LoginDeps {
  platform : LoginPlatform
  /// The environment the commands start from (runtime.ts `cleanEnv`).
  env : () -> Env
  /// Kimi's steps for a profile's home: the device it signed in on before, or a new one (kimi.ts).
  kimi : async (String) -> DeviceSteps
  /// cursor.ts: a login's page and what to ask it by; asked: none while it waits, its `accessToken` once confirmed; a
  /// key minted (`apiKey`, `email`); the key written to the home.
  cursor_handshake : () -> Json
  poll_cursor : async (Json) -> Json?
  mint_cursor_key : async (String, String) -> Json
  write_cursor : async (String, Json) -> Unit
  /// agy.ts `agyTokenReady`, `noteAgyEmail`.
  agy_token_ready : (String, Bool) -> Bool
  note_agy_email : async (String, String) -> Unit
  /// command-output.ts `loopbackOf`: whether a page comes back to a port of this machine.
  loopback_of : (String) -> Bool
  /// The name a minted key is given (the station's).
  key_name : () -> String
}

///|
/// Where an Antigravity CLI sign-in is in its menus.
priv struct AgySteps {
  enterprise : Bool
  mut cloud : Bool
  mut license : Bool
  mut billing : Bool
  mut after : String?
  stage : String
  mut terminal : Bool
}

///|
/// A sign-in under way.
priv struct Running {
  run : Int
  job : LoginJob
  mut child : Child?
  mut raw : String
  mut output : String
  mut cancel_timer : () -> Unit
  mut exited : Bool
  lang : String
  mut stop : (() -> Unit)?
  opened : String?
  mut back : String?
  home : String?
  mut chose : Bool
  agy : AgySteps?
  /// What Claude's command said since its code went in (none before), read for its refusal.
  mut said : String?
  /// A service's OAuth sign-in (`start_oauth_code`): its code is taken by the station itself, no command.
  oauth : OAuthCode?
}

///|
/// An OAuth2 authorization-code sign-in the station makes itself (a service profile's, login.ts `startOAuthCode`):
/// the page the person approves on, the code they paste checked (`validate`: the code, or raises the words of why
/// not, the sign-in still waiting for one), exchanged and written to the profile's home (`exchange`), and the code
/// read off the station's browser where its page lands back there (`callback_code`, given the tab's address).
pub(all) struct OAuthCode {
  url : String
  validate : (String, String) -> String raise
  exchange : async (String, String) -> Unit
  callback_code : (String?) -> String?
}

///|
pub struct LoginManager {
  priv jobs : Map[String, Running]
  priv finished : Map[String, LoginJob]
  priv listeners : Array[(Int, (String) -> Unit)]
  priv mut next_listener : Int
  priv mut runs : Int
  priv no_browser_dir : String
  priv agy_login_dir : String
  priv commands : LoginCommands
  priv io : Io
  priv deps : LoginDeps
  priv words : Words
  priv console : String
  priv mut pages : LoginPages?
  priv mut state_file : (String) -> String?
}

///|
pub fn LoginManager::new(
  io : Io,
  deps : LoginDeps,
  words : Words,
  data : String,
  commands? : LoginCommands = { claude: "claude", codex: "codex", grok: None, devin: None, agy: None },
  console? : String = console_url,
) -> LoginManager {
  let m : LoginManager = {
    jobs: {},
    finished: {},
    listeners: [],
    next_listener: 0,
    runs: 0,
    no_browser_dir: join([data, "run", "no-browser"]),
    agy_login_dir: join([data, "run", "agy-login"]),
    commands,
    io,
    deps,
    words,
    console,
    pages: None,
    state_file: _ => None,
  }
  m.state_file = profile => m.job_state_file(profile)
  m
}

///|
/// The sign-in browser state file in the home of `profile`'s sign-in under way, where it has one.
pub fn LoginManager::job_state_file(self : LoginManager, profile : String) -> String? {
  match self.jobs.get(profile) {
    Some(r) =>
      match r.home {
        Some(h) if h != "" => Some(join([h, login_browser_file]))
        _ => None
      }
    None => None
  }
}

///|
/// Overrides how a profile's sign-in browser state file is located.
pub fn LoginManager::set_state_file(self : LoginManager, resolve : (String) -> String?) -> Unit {
  self.state_file = resolve
}

///|
/// Hears the profile id of each login job that changes; gives the function that stops it.
pub fn LoginManager::changes(self : LoginManager, listener : (String) -> Unit) -> () -> Unit {
  let id = self.next_listener
  self.next_listener += 1
  self.listeners.push((id, listener))
  () => match self.listeners.search_by(l => l.0 == id) {
    Some(i) => ignore(self.listeners.remove(i))
    None => ()
  }
}

///|
/// The station's browser, for the pages of sign-ins: a tab coming or going is told as a change.
pub fn LoginManager::attach(self : LoginManager, pages : LoginPages) -> Unit {
  self.pages = Some(pages)
  (pages.changes)(key => {
    guard key.has_prefix("profile:") else { return }
    let profile = from(key, 8)
    guard self.jobs.get(profile) is Some(running) else { return }
    // A service's OAuth page come back with its code in the station's browser: taken from there, its tab closed.
    if running.oauth is Some(flow) && running.job.state == "needs_code" {
      match (flow.callback_code)((pages.url_of)(key)) {
        Some(code) => {
          (pages.close)(key)
          (self.io.spawn)(async fn() {
            ignore(self.submit_code(profile, code, running.lang)) catch {
              e =>
                (self.io.log)("warn", "login", "a code read off the station's browser was not taken", {
                  "profile": Json::string(profile),
                  "error": Json::string(message_of(e)),
                })
            }
          })
          return
        }
        None => ()
      }
    }
    // The Antigravity CLI's page come back with its code in the station's browser: taken from there, its tab closed.
    if running.job.runtime == "agy" && running.job.state == "needs_code" {
      match agy_callback_code((pages.url_of)(key), running.job.url) {
        Some(code) => {
          (pages.close)(key)
          (self.io.spawn)(async fn() {
            ignore(self.submit_code(profile, code, running.lang)) catch {
              e =>
                (self.io.log)("warn", "login", "a code read off the station's browser was not taken", {
                  "profile": Json::string(profile),
                  "error": Json::string(message_of(e)),
                })
            }
          })
          return
        }
        None => ()
      }
    }
    self.emit(profile)
  })
}

///|
pub fn LoginManager::get(self : LoginManager, profile : String) -> LoginJob? {
  match self.jobs.get(profile) {
    Some(running) => {
      let job = running.job.copy()
      if self.pages is Some(pages) {
        let screen = (pages.screen_of)(page_key(profile))
        if screen is Some(_) {
          job.screen = screen
        }
        if (screen is Some(_) || self.has_page(running)) && (pages.can)() {
          job.browser = true
        }
      }
      Some(job)
    }
    None =>
      match self.finished.get(profile) {
        Some(done) => Some(done.copy())
        None => None
      }
  }
}

///|
/// command-output.ts `webPage`.
fn web_page(url : String?) -> Bool {
  match url {
    Some(u) => {
      let l = lower(sub(u, 0, 8))
      l.has_prefix("http://") || l.has_prefix("https://")
    }
    None => false
  }
}

///|
/// command-output.ts `urlsIn`: the addresses in what a command said.
pub fn urls_in(text : String) -> Array[String] {
  let found = []
  let n = text.length()
  let mut i = 0
  let stop = (c : Int) => is_space(c) || c == '"' || c == '\'' || c == '<' || c == '>' || c == '`'
  while i < n {
    let rest = sub(text, i, i + 8)
    let len = if rest.has_prefix("https://") {
      8
    } else if rest.has_prefix("http://") {
      7
    } else {
      0
    }
    if len == 0 {
      i += 1
      continue
    }
    let mut j = i + len
    while j < n && !stop(text.unsafe_charcode_at(j)) {
      j += 1
    }
    if j == i + len {
      i += 1
      continue
    }
    let mut url = sub(text, i, j)
    let trailing = (u : String) => {
      let c = u.unsafe_charcode_at(u.length() - 1)
      c == '.' || c == ',' || c == ';' || c == ':' || c == '!' || c == '?' || c == ')' || c == ']' ||
      c == '}' || c == '\'' || c == '"' || c == 0x2026
    }
    while url.length() > 0 && trailing(url) && !(url.has_suffix(")") && includes(url, "(")) {
      url = sub(url, 0, url.length() - 1)
    }
    if url.has_suffix("...") {
      url = sub(url, 0, url.length() - 3)
    }
    if url.length() > 8 {
      found.push(url)
    }
    i = j
  }
  found
}

///|
/// The page a sign-in under way opens in the station's browser: the one its command opened where that comes back to
/// it here (Claude's loopback one), else the one it gives to open; none when it has none (yet).
async fn LoginManager::station_page(self : LoginManager, running : Running) -> String? {
  let job = running.job
  if job.state != "needs_code" && job.state != "needs_approval" {
    return None
  }
  if running.opened is Some(opened) {
    let text = (self.io.read)(opened) catch { _ => "" }
    let opened_urls = urls_in(text)
    let mut back : String? = None
    for u in opened_urls {
      if (self.deps.loopback_of)(u) {
        back = Some(u)
      }
    }
    if back is Some(b) {
      running.back = Some(b)
      return Some(b)
    }
  }
  if web_page(job.url) {
    job.url
  } else {
    None
  }
}

///|
/// Whether it has a page to open as far as is known without reading what its command opened.
fn LoginManager::has_page(self : LoginManager, running : Running) -> Bool {
  ignore(self)
  let job = running.job
  (job.state == "needs_code" || job.state == "needs_approval") && (running.back is Some(_) || web_page(job.url))
}

///|
/// Opens the page of `profile`'s sign-in in the station's browser (the tab open already, if there is one): its screen.
pub async fn LoginManager::open_page(self : LoginManager, profile : String, lang : String) -> String {
  let t = (key : String, args : Array[(String, String)]) => tr(self.words, lang, key, args)
  guard self.jobs.get(profile) is Some(running) else { raise Failed(t("station.loginPage.nothing", [])) }
  guard self.pages is Some(pages) && (pages.can)() else { raise Failed(t("station.loginPage.noBrowser", [])) }
  let url = self.station_page(running)
  if !self.is_current(profile, running) {
    raise Failed(t("station.loginPage.nothing", []))
  }
  if url is None && (pages.screen_of)(page_key(profile)) is None {
    raise Failed(t("station.loginPage.nothing", []))
  }
  let screen = (pages.open)(page_key(profile), url.unwrap_or("about:blank"), () => (self.state_file)(profile)) catch {
    e => raise Failed(t("station.loginPage.failed", [("error", message_of(e))]))
  }
  // Ended (or started again) meanwhile: its tab goes too.
  if !self.is_current(profile, running) {
    (pages.close)(page_key(profile))
    raise Failed(t("station.loginPage.nothing", []))
  }
  screen
}

///|
fn LoginManager::is_current(self : LoginManager, profile : String, running : Running) -> Bool {
  match self.jobs.get(profile) {
    Some(r) => physical_equal(r, running)
    None => false
  }
}

///|
fn LoginManager::run_current(self : LoginManager, profile : String, run : Int) -> Bool {
  match self.jobs.get(profile) {
    Some(r) => r.run == run
    None => false
  }
}

///|
fn env_set(env : Env, k : String, v : String) -> Unit {
  env[k] = v
}

///|
/// Starts a sign-in for a subscription profile, replacing any running one.
pub async fn LoginManager::start(self : LoginManager, profile : LoginProfile, lang : String) -> LoginJob {
  let t = (key : String, args : Array[(String, String)]) => tr(self.words, lang, key, args)
  let plat = self.deps.platform
  // (a pseudo-terminal where its command reads only from one: looked for first, before anything is recorded)
  let terminal = if profile.runtime == "devin" {
    (plat.terminal)(self.commands.devin.unwrap_or("devin"), ["auth", "login", "--force-manual-token-flow"], devin_cols, devin_rows)
  } else if profile.runtime == "agy" {
    (plat.terminal)(self.commands.agy.unwrap_or("agy"), [], devin_cols, devin_rows)
  } else {
    None
  }
  self.cancel(profile.id)
  self.finished.remove(profile.id)
  let no_browser = self.no_browser_dir
  let source_env = (self.deps.env)()
  let clean : Env = Map([])
  for k, v in source_env {
    if !scrubbed.contains(k) {
      clean[k] = v
    }
  }
  let mut env = (plat.prepend_path)(clean, no_browser)
  self.runs += 1
  let run = self.runs
  // The pages it opens, written down for the station's browser.
  let opened = join([no_browser, "\{profile.id}-\{run}.opened"])
  env_set(env, "STILLFAIL_LOGIN_OPENED", opened)
  let dirs = [profile.home]
  let mut command = ""
  let mut args : Array[String] = []
  let mut path_command : String? = None
  // The Antigravity CLI's HOME: an empty directory of this sign-in's.
  let stage = if profile.runtime == "agy" {
    Some(join([self.agy_login_dir, "\{profile.id}-\{run}"]))
  } else {
    None
  }
  if profile.runtime == "claude" {
    env_set(env, "CLAUDE_CONFIG_DIR", profile.home)
    let email = match profile.email {
      Some(e) if trim(e) != "" => Some(trim(e))
      _ => None
    }
    command = self.commands.claude
    args = ["auth", "login", "--claudeai"]
    if email is Some(e) {
      args.push("--email")
      args.push(e)
    }
  } else if profile.runtime == "grok" {
    let grok_home = join([profile.home, "grok"])
    env_set(env, "GROK_HOME", grok_home)
    env_set(env, "GROK_DISABLE_AUTOUPDATER", "1")
    dirs.push(grok_home)
    command = self.commands.grok.unwrap_or("grok")
    args = ["login", "--device-auth"]
  } else if profile.runtime == "devin" {
    let data = devin_data(profile.home)
    env_set(env, "XDG_DATA_HOME", data)
    dirs.push(data)
    path_command = Some(self.commands.devin.unwrap_or("devin"))
    guard terminal is Some((c, a)) else {
      return self.refused(profile.id, profile.runtime, t("station.login.devinNoTerminal", []))
    }
    command = c
    args = a
  } else if stage is Some(s) {
    env_set(env, "HOME", s)
    // (Windows: its home is USERPROFILE's, HOME aside)
    env_set(env, "USERPROFILE", s)
    for p in agy_file_tokens {
      env_set(env, p.0, p.1)
    }
    env.remove("SSH_CONNECTION")
    env_set(env, "AGY_CLI_DISABLE_AUTO_UPDATE", "1")
    path_command = Some(self.commands.agy.unwrap_or("agy"))
    guard terminal is Some((c, a)) else {
      return self.refused(profile.id, profile.runtime, t("station.login.agyNoTerminal", []))
    }
    command = c
    args = a
  } else {
    env_set(env, "CODEX_HOME", profile.home)
    command = self.commands.codex
    args = ["login", "--device-auth"]
  }
  let now = (self.io.now)()
  let job : LoginJob = {
    profile: profile.id,
    runtime: profile.runtime,
    provider: None,
    state: "starting",
    url: None,
    user_code: None,
    error: None,
    started_at: now,
    expires_at: now + login_timeout_ms,
    browser: false,
    screen: None,
    service: None,
  }
  let id = profile.id
  let cancelled = () => {
    let j = job.copy()
    j.state = "cancelled"
    j
  }
  let failed_with = (error : String) => {
    let j = job.copy()
    j.state = "failed"
    j.error = Some(error)
    j
  }
  // The shell lookup can take time. Record the sign-in first so cancelling or replacing it stops this start too.
  let running : Running = {
    run,
    job,
    child: None,
    raw: "",
    output: "",
    exited: true,
    opened: Some(opened),
    lang,
    home: Some(profile.home),
    chose: false,
    agy: match stage {
      Some(s) =>
        Some({ enterprise: profile.enterprise, cloud: false, license: false, billing: false, after: None, stage: s, terminal: false })
      None => None
    },
    stop: None,
    back: None,
    said: None,
    oauth: None,
    cancel_timer: () => (),
  }
  running.cancel_timer = (self.io.after)(login_timeout_ms, () => self.fail_run(id, run, t("station.login.timedOut", [])))
  self.jobs[id] = running
  self.emit(id)
  let prepared = try {
    // (Claude Code kept off the keychain: its sign-in in the profile's home)
    if profile.runtime == "claude" {
      (plat.file_credentials)(env)
    }
    let open = self.no_browser()
    (self.io.rm)(opened, false)
    for d in dirs {
      (self.io.mkdir)(d, true)
    }
    Ok(open)
  } catch {
    e => Err(e)
  }
  match prepared {
    Err(e) => {
      if !self.is_current(id, running) {
        return cancelled()
      }
      let error = t("station.login.cannotRun", [("error", message_of(e))])
      self.finish(id, "failed", Some(error))
      return failed_with(error)
    }
    Ok(open) => env_set(env, "BROWSER", open)
  }
  if !self.is_current(id, running) {
    return cancelled()
  }
  let drop_stage = async fn() {
    if stage is Some(s) {
      (self.io.rm)(s, true) catch {
        _ => ()
      }
    }
  }
  if stage is Some(s) {
    // Those an earlier sign-in of this profile left go first; never a later one's, made while this listing was read.
    let left = (self.io.readdir)(self.agy_login_dir) catch { _ => [] }
    if !self.is_current(id, running) {
      return cancelled()
    }
    let mine = (name : String) => {
      if !name.has_prefix("\{profile.id}-") {
        return false
      }
      let rest = from(name, profile.id.length() + 1)
      if rest == "" {
        return false
      }
      let mut n = 0.0
      for i in 0..<rest.length() {
        let c = rest.unsafe_charcode_at(i)
        if !is_ascii_digit(c) {
          return false
        }
        n = n * 10.0 + (c - '0').to_double()
      }
      n < run.to_double()
    }
    for name in left.filter(mine) {
      (self.io.rm)(join([self.agy_login_dir, name]), true) catch {
        _ => ()
      }
    }
    let made = (self.io.mkdir)(s, true) catch { e => Some(e) } noraise { _ => None }
    if made is Some(e) {
      if !self.is_current(id, running) {
        return cancelled()
      }
      let error = t("station.login.cannotRun", [("error", message_of(e))])
      self.finish(id, "failed", Some(error))
      return failed_with(error)
    }
    if !self.is_current(id, running) {
      drop_stage()
      return cancelled()
    }
  }
  let found_env = (plat.with_shell_command)(path_command.unwrap_or(command), env, source_env)
  if !self.is_current(id, running) {
    drop_stage()
    return cancelled()
  }
  // The browser stand-ins must stay ahead of any Node bin added for the login command.
  if found_env is Some(f) {
    env = (plat.prepend_path)(f, no_browser)
  }
  let (file, file_args) = (plat.runnable)(command, args, env)
  if !self.is_current(id, running) {
    drop_stage()
    return cancelled()
  }
  let events : ChildEvents = {
    output: chunk => self.output(id, run, chunk),
    close: (code, signal) => {
      // Its HOME goes with it, whatever its end.
      if stage is Some(_) {
        (self.io.spawn)(drop_stage)
      }
      guard self.jobs.get(id) is Some(current) && current.run == run else { return }
      current.exited = true
      if code == Some(0) {
        return self.finish(id, "done", None)
      }
      let said = last_lines(current.output)
      let shown = match code {
        Some(c) => c.to_string()
        None => {
          ignore(signal)
          "signal"
        }
      }
      self.finish(id, "failed", Some(if said != "" { said } else { t("station.login.exited", [("code", shown)]) }))
    },
  }
  let spawned = (plat.spawn)(file, file_args, stage.unwrap_or(profile.home), env, events) catch {
    e => {
      if !self.is_current(id, running) {
        (self.io.spawn)(drop_stage)
        return cancelled()
      }
      (self.io.spawn)(drop_stage)
      // Recorded like any other failure, so the page shows why.
      running.exited = true
      let error = t("station.login.cannotRun", [("error", message_of(e))])
      self.finish(id, "failed", Some(error))
      return failed_with(error)
    }
  }
  running.child = Some(spawned)
  running.exited = false
  if !self.is_current(id, running) {
    // (ended while it started: what ended it found no process yet to stop)
    (spawned.kill)()
    (self.io.spawn)(drop_stage)
    return cancelled()
  }
  (self.io.log)("info", "login", "login started", {
    "profile": Json::string(id),
    "runtime": Json::string(profile.runtime),
  })
  self.emit(id)
  job.copy()
}

///|
/// Starts signing an OpenCode Go profile in to the person's OpenCode Console account, replacing any running sign-in.
pub async fn LoginManager::start_console(self : LoginManager, id : String, home : String, lang : String) -> LoginJob {
  let base = self.console
  self.device_sign_in(id, home, "opencode", lang, {
    start: async fn() { start_device(self.io, base) },
    ask: async fn(code) { device_token(self.io, base, code) },
    keep: async fn(token) {
      let (email, workspace) = who_is(self.io, base, token.access, token.org)
      let login : ConsoleLogin = {
        access: token.access,
        refresh: token.refresh,
        expires_at: (self.io.wall)().to_double() + token.expires_in_ms,
        org: token.org,
        email,
        workspace,
      }
      async fn() { write_console(self.io, home, login) }
    },
  })
}

///|
/// Starts signing a Kimi Code profile in to the person's Kimi account the same way, for a device of its own.
pub async fn LoginManager::start_kimi(self : LoginManager, id : String, home : String, lang : String) -> LoginJob {
  let steps = (self.deps.kimi)(home)
  self.device_sign_in(id, home, "kimi", lang, steps)
}

///|
/// A device authorization grant (RFC 8628) the station follows itself: a code, then asked about at the interval given
/// until it is approved, refused or runs out; then what `keep` makes of the tokens written to the profile's home.
async fn LoginManager::device_sign_in(
  self : LoginManager,
  id : String,
  home : String,
  provider : String,
  lang : String,
  steps : DeviceSteps,
) -> LoginJob {
  let t = (key : String, args : Array[(String, String)]) => tr(self.words, lang, key, args)
  let (failed, expired, denied, unreached) = if provider == "kimi" {
    ("station.login.kimiFailed", "station.login.kimiExpired", "station.login.kimiDenied", "could not ask Kimi about a sign-in")
  } else {
    (
      "station.login.consoleFailed", "station.login.consoleExpired", "station.login.consoleDenied", "could not ask the OpenCode Console about a sign-in",
    )
  }
  self.cancel(id)
  self.finished.remove(id)
  let now = (self.io.now)()
  let job : LoginJob = {
    profile: id,
    runtime: "claude",
    provider: Some(provider),
    state: "starting",
    url: None,
    user_code: None,
    error: None,
    started_at: now,
    expires_at: now + login_timeout_ms,
    browser: false,
    screen: None,
    service: None,
  }
  self.runs += 1
  let run = self.runs
  let running : Running = {
    run,
    job,
    child: None,
    raw: "",
    output: "",
    exited: true,
    lang,
    home: Some(home),
    cancel_timer: () => (),
    stop: None,
    opened: None,
    back: None,
    chose: false,
    agy: None,
    said: None,
    oauth: None,
  }
  self.jobs[id] = running
  self.emit(id)
  let current = () => self.run_current(id, run)
  let device = try {
    (self.io.mkdir)(home, true)
    if !current() {
      return self.get(id).unwrap()
    }
    (steps.start)()
  } catch {
    e => {
      if current() {
        self.finish(id, "failed", Some(t(failed, [("error", message_of(e))])))
      }
      return self.get(id).unwrap()
    }
  }
  if !current() {
    return self.get(id).unwrap()
  }
  job.state = "needs_approval"
  job.url = Some(device.url)
  job.user_code = Some(device.user_code)
  let limit = if device.expires_in_ms < login_timeout_ms.to_double() {
    device.expires_in_ms
  } else {
    login_timeout_ms.to_double()
  }
  job.expires_at = (now.to_double() + limit).to_int64()
  running.cancel_timer = (self.io.after)(job.expires_at - now, () => self.fail_run(id, run, t(expired, [])))
  let interval = Ref(device.interval_ms.to_int64())
  let ask_ref : Ref[async () -> Unit] = Ref(async fn() {  })
  let ask = async fn() {
    if !current() {
      return
    }
    let answer = (steps.ask)(device.device_code) catch {
      e => {
        // The network, for once: asked again at the next interval.
        (self.io.log)("warn", "login", unreached, {
          "profile": Json::string(id),
          "error": Json::string(message_of(e)),
        })
        Pending(false)
      }
    }
    if !current() {
      return
    }
    match answer {
      Pending(slow) => {
        if slow {
          interval.val += 5_000L
        }
        running.stop = Some((self.io.after)(interval.val, () => (self.io.spawn)(ask_ref.val)))
        return
      }
      Refused(e) => {
        if e == "access_denied" {
          return self.finish(id, "failed", Some(t(denied, [])))
        }
        return self.finish(
          id,
          "failed",
          Some(if e == "expired_token" { t(expired, []) } else { t(failed, [("error", e)]) }),
        )
      }
      Signed(token) => {
        job.state = "verifying"
        self.emit(id)
        let write = (steps.keep)(token)
        if !current() {
          return
        }
        write() catch {
          e => {
            if current() {
              self.finish(id, "failed", Some(t("station.login.homeFailed", [("error", message_of(e))])))
            }
            return
          }
        }
        if current() {
          self.finish(id, "done", None)
        }
      }
    }
  }
  ask_ref.val = ask
  running.stop = Some((self.io.after)(interval.val, () => (self.io.spawn)(ask)))
  (self.io.log)("info", "login", "device sign-in started", {
    "profile": Json::string(id),
    "provider": Json::string(provider),
  })
  self.emit(id)
  job.copy()
}

///|
/// Starts signing a Cursor profile in to the person's Cursor account, replacing any running sign-in: a page to confirm
/// the login on (no code), asked about until it is confirmed or runs out; then the key minted for the station.
pub async fn LoginManager::start_cursor(self : LoginManager, id : String, home : String, lang : String) -> LoginJob {
  let t = (key : String, args : Array[(String, String)]) => tr(self.words, lang, key, args)
  self.cancel(id)
  self.finished.remove(id)
  let now = (self.io.now)()
  let handshake = (self.deps.cursor_handshake)()
  let job : LoginJob = {
    profile: id,
    runtime: "cursor",
    provider: None,
    state: "needs_approval",
    url: str_of(get(Some(handshake), "url")),
    user_code: None,
    error: None,
    started_at: now,
    expires_at: now + login_timeout_ms,
    browser: false,
    screen: None,
    service: None,
  }
  self.runs += 1
  let run = self.runs
  let running : Running = {
    run,
    job,
    child: None,
    raw: "",
    output: "",
    exited: true,
    lang,
    home: Some(home),
    cancel_timer: () => (),
    stop: None,
    opened: None,
    back: None,
    chose: false,
    agy: None,
    said: None,
    oauth: None,
  }
  self.jobs[id] = running
  running.cancel_timer = (self.io.after)(login_timeout_ms, () => self.fail_run(id, run, t("station.login.timedOut", [])))
  let current = () => self.run_current(id, run)
  (self.io.mkdir)(home, true) catch {
    e => {
      if current() {
        self.finish(id, "failed", Some(t("station.login.homeFailed", [("error", message_of(e))])))
      }
      return self.get(id).unwrap()
    }
  }
  if !current() {
    return self.get(id).unwrap()
  }
  // Asked often at first (the person is on the page), less as it goes on.
  let interval = Ref(1_000L)
  let ask_ref : Ref[async () -> Unit] = Ref(async fn() {  })
  let ask = async fn() {
    if !current() {
      return
    }
    let answer = (self.deps.poll_cursor)(handshake) catch {
      e => {
        // The network, for once: asked again at the next interval.
        (self.io.log)("warn", "login", "could not ask Cursor about a sign-in", {
          "profile": Json::string(id),
          "error": Json::string(message_of(e)),
        })
        None
      }
    }
    if !current() {
      return
    }
    guard answer is Some(confirmed) else {
      let next = js_round(interval.val.to_double() * 1.2).to_int64()
      interval.val = if next < 5_000L { next } else { 5_000L }
      running.stop = Some((self.io.after)(interval.val, () => (self.io.spawn)(ask_ref.val)))
      return
    }
    job.state = "verifying"
    self.emit(id)
    let minted = (self.deps.mint_cursor_key)(str_of(get(Some(confirmed), "accessToken")).unwrap_or(""), (self.deps.key_name)()) catch {
      e => {
        if current() {
          self.finish(id, "failed", Some(t("station.login.cursorKeyFailed", [("error", message_of(e))])))
        }
        return
      }
    }
    if !current() {
      return
    }
    (self.deps.write_cursor)(home, {
      "apiKey": get(Some(minted), "apiKey").unwrap_or(Json::null()),
      "email": get(Some(minted), "email").unwrap_or(Json::null()),
      "keyName": Json::string((self.deps.key_name)()),
      "createdAt": jnum((self.io.wall)()),
    }) catch {
      e => {
        if current() {
          self.finish(id, "failed", Some(t("station.login.homeFailed", [("error", message_of(e))])))
        }
        return
      }
    }
    if current() {
      self.finish(id, "done", None)
    }
  }
  ask_ref.val = ask
  running.stop = Some((self.io.after)(interval.val, () => (self.io.spawn)(ask)))
  (self.io.log)("info", "login", "Cursor sign-in started", { "profile": Json::string(id) })
  self.emit(id)
  job.copy()
}

///|
/// Starts an OAuth2 authorization-code sign-in for a service profile (no command), replacing any running sign-in: the
/// page to approve on, then the code the person pastes (or the station's browser reads) exchanged by `flow`.
pub async fn LoginManager::start_oauth_code(
  self : LoginManager,
  id : String,
  home : String,
  service : String,
  flow : OAuthCode,
  lang : String,
) -> LoginJob {
  let t = (key : String, args : Array[(String, String)]) => tr(self.words, lang, key, args)
  self.cancel(id)
  self.finished.remove(id)
  let now = (self.io.now)()
  let job : LoginJob = {
    profile: id,
    runtime: "",
    provider: None,
    state: "needs_code",
    url: Some(flow.url),
    user_code: None,
    error: None,
    started_at: now,
    expires_at: now + login_timeout_ms,
    browser: false,
    screen: None,
    service: Some(service),
  }
  self.runs += 1
  let run = self.runs
  let running : Running = {
    run,
    job,
    child: None,
    raw: "",
    output: "",
    exited: true,
    lang,
    home: Some(home),
    cancel_timer: () => (),
    stop: None,
    opened: None,
    back: None,
    chose: false,
    agy: None,
    said: None,
    oauth: Some(flow),
  }
  self.jobs[id] = running
  running.cancel_timer = (self.io.after)(login_timeout_ms, () => self.fail_run(id, run, t("station.login.timedOut", [])))
  (self.io.mkdir)(home, true) catch {
    e => {
      if self.is_current(id, running) {
        self.finish(id, "failed", Some(t("station.login.homeFailed", [("error", message_of(e))])))
      }
      return self.get(id).unwrap()
    }
  }
  if !self.is_current(id, running) {
    return match self.get(id) {
      Some(j) => j
      None => { ..job.copy(), state: "cancelled" }
    }
  }
  (self.io.log)("info", "login", "OAuth code sign-in started", {
    "profile": Json::string(id),
    "service": Json::string(service),
  })
  self.emit(id)
  job.copy()
}

///|
/// A service's OAuth code checked, then exchanged within `verify_wait_ms`: done once written, failed with why.
async fn LoginManager::exchange_code(
  self : LoginManager,
  profile : String,
  running : Running,
  flow : OAuthCode,
  code : String,
  lang : String,
) -> LoginJob {
  // One it would not take is refused here, the sign-in still waiting for a code.
  let clean = (flow.validate)(code, lang)
  if running.stop is Some(s) {
    s()
  }
  let verifying = () => self.is_current(profile, running) && running.job.state == "verifying"
  // timer: a deadline for the OAuth code's exchange
  running.stop = Some((self.io.after)(verify_wait_ms, () => if verifying() {
    self.finish(profile, "failed", Some(tr(self.words, running.lang, "station.login.verifyTimedOut", [])))
  }))
  running.job.state = "verifying"
  let job = running.job.copy()
  self.emit(profile)
  (flow.exchange)(clean, lang) catch {
    e => {
      if verifying() {
        self.finish(profile, "failed", Some(message_of(e)))
      }
      return self.get(profile).unwrap_or(job)
    }
  }
  if verifying() {
    self.finish(profile, "done", None)
  }
  self.get(profile).unwrap_or(job)
}

///|
/// A sign-in that cannot be started here, recorded like any other failure, so the page shows why.
fn LoginManager::refused(self : LoginManager, id : String, runtime : String, error : String) -> LoginJob {
  let now = (self.io.now)()
  let failed : LoginJob = {
    profile: id,
    runtime,
    provider: None,
    state: "failed",
    url: None,
    user_code: None,
    error: Some(error),
    started_at: now,
    expires_at: now,
    browser: false,
    screen: None,
    service: None,
  }
  self.finished[id] = failed
  self.emit(id)
  failed.copy()
}

///|
/// Claude and Devin: the code the browser showed after approving. The Antigravity CLI's company account with no
/// licence: its Google Cloud project, the same way (`needs_project`).
pub async fn LoginManager::submit_code(self : LoginManager, profile : String, code : String, lang : String) -> LoginJob {
  let t = (key : String) => tr(self.words, lang, key, [])
  guard self.jobs.get(profile) is Some(running) &&
    (running.job.state == "needs_code" || running.job.state == "needs_project") else {
    raise Failed(t("station.login.notWaitingForCode"))
  }
  let trimmed = trim(code)
  if trimmed == "" {
    raise Failed(t("station.login.emptyCode"))
  }
  if running.oauth is Some(flow) {
    return self.exchange_code(profile, running, flow, trimmed, lang)
  }
  // Claude's is checked before it goes in: one it would not take is refused here, the sign-in still waiting for a code.
  let clean = if running.job.runtime == "claude" {
    claude_code_of(self.words, trimmed, running.job.url, lang)
  } else {
    trimmed
  }
  // What it says from here on is read for what comes next.
  if running.agy is Some(steps) {
    steps.after = Some("")
  }
  if running.stop is Some(s) {
    s()
  }
  running.stop = None
  running.job.state = "verifying"
  if running.job.runtime == "claude" {
    running.said = Some("")
  }
  if running.job.runtime == "claude" || running.job.runtime == "devin" {
    // timer: a deadline for the command to take the code
    running.stop = Some((self.io.after)(verify_wait_ms, () => if self.is_current(profile, running) &&
      running.job.state == "verifying" {
      self.finish(profile, "failed", Some(tr(self.words, running.lang, "station.login.verifyTimedOut", [])))
    }))
  }
  let job = running.job.copy()
  match running.child {
    Some(child) if (child.writable)() => {
      // Devin and the Antigravity CLI read it in a terminal of their own, where Enter is a carriage return.
      let in_terminal = running.job.runtime == "devin" || running.job.runtime == "agy"
      (child.write)(clean + (if in_terminal { "\r" } else { "\n" }))
    }
    _ => ()
  }
  if running.job.runtime == "agy" {
    self.await_agy(profile, running)
  }
  self.emit(profile)
  job
}

///|
/// The Antigravity CLI goes on into its interface once signed in: done when it has written its sign-in whole in its
/// HOME, which is then written into the profile's agy/; failed when it has not in a while.
fn LoginManager::await_agy(self : LoginManager, profile : String, running : Running) -> Unit {
  let until = (self.io.now)() + agy_wait_ms
  guard running.agy is Some(steps) else { return }
  let signed_in = agy_token_in(join([steps.stage, ".gemini"]))
  let look_ref : Ref[async () -> Unit] = Ref(async fn() {  })
  let look = async fn() {
    let waiting = () => self.is_current(profile, running) && running.job.state == "verifying"
    if !waiting() {
      return
    }
    if running.home is Some(home) {
      let text = (self.io.read)(signed_in) catch { _ => "" }
      if !waiting() {
        return
      }
      if (self.deps.agy_token_ready)(text, steps.enterprise) {
        (self.io.write_private)(agy_token(home), text) catch {
          e => {
            if self.is_current(profile, running) {
              self.finish(profile, "failed", Some(tr(self.words, running.lang, "station.login.homeFailed", [("error", message_of(e))])))
            }
            return
          }
        }
        (self.deps.note_agy_email)(home, text) catch {
          _ => ()
        }
        if waiting() {
          self.finish(profile, "done", None)
        }
        return
      }
    }
    if (self.io.now)() > until {
      return self.finish(profile, "failed", Some(tr(self.words, running.lang, "station.login.agyCodeRefused", [])))
    }
    running.stop = Some((self.io.after)(agy_poll_ms, () => (self.io.spawn)(look_ref.val)))
  }
  look_ref.val = look
  (self.io.spawn)(look)
}

///|
/// What the Antigravity CLI asks, answered: how to sign in, and for a company's account the way into Google Cloud;
/// once its code went in, its licence (the first), how to pay (as it goes) and the project (asked of the person); what
/// it says of a failure ends the sign-in at once, saying it.
fn LoginManager::agy_answer(self : LoginManager, profile : String, running : Running, chunk : String) -> Unit {
  guard running.agy is Some(steps) else { return }
  let write = (keys : String) => match running.child {
    Some(c) => (c.send)(keys)
    None => ()
  }
  // A choice further down: the arrow, then Enter a moment later (it reads the two apart).
  let second = () => {
    write("\u{1b}[B")
    let run = running.run
    ignore((self.io.after)(agy_key_gap_ms, () => if self.run_current(profile, run) { write("\r") }))
  }
  // Its question to the terminal, as a remote session's, answered once, before it asks anything else.
  if running.job.state == "starting" && !running.chose && !steps.terminal && includes(running.raw, agy_terminal_asked) {
    steps.terminal = true
    write(agy_terminal_answer)
  }
  if running.job.state == "starting" && !running.chose && includes(running.output, "Select login method") {
    running.chose = true
    if steps.enterprise {
      second()
    } else {
      write("\r")
    }
    return
  }
  if steps.enterprise &&
    !steps.cloud &&
    running.job.state == "starting" &&
    (includes(running.output, "Google Cloud sign-in method") || includes(running.output, "Continue with Google Cloud")) {
    steps.cloud = true
    write("\r")
    return
  }
  guard steps.after is Some(after) else { return }
  // Read whole: an escape can be cut between two pieces.
  steps.after = Some(last_points(after + chunk, 16000))
  let said = strip_ansi(steps.after.unwrap())
  // (a line of its licences not listed is no failure, whatever it says: it goes on)
  let failed = split_lines(said).search_by(l => !includes(l, agy_no_licences) &&
    agy_failures.iter().any(f => includes(l, f)))
  if failed is Some(i) && (running.job.state == "verifying" || running.job.state == "needs_project") {
    let mut line = trim(split_lines(said)[i])
    if line.has_prefix("[Auth Error]") {
      line = trim_start(from(line, 12))
    }
    line = trim(line)
    return self.finish(profile, "failed", Some(tr(self.words, running.lang, "station.login.agyFailed", [("error", sub(line, 0, 300))])))
  }
  if !steps.license && includes(said, "Can't find your subscription?") {
    steps.license = true
    write("\r")
    return
  }
  if !steps.billing && includes(said, "Pay only for the tokens you use") {
    steps.billing = true
    second()
    return
  }
  if running.job.state == "verifying" && includes(said, "Provide Google Cloud project") {
    if running.stop is Some(s) {
      s()
    }
    running.stop = None
    running.job.state = "needs_project"
    self.emit(profile)
  }
}

///|
pub fn LoginManager::cancel(self : LoginManager, profile : String) -> Unit {
  if self.jobs.contains(profile) {
    self.finish(profile, "cancelled", None)
  }
}

///|
pub fn LoginManager::stop_all(self : LoginManager) -> Unit {
  for id in self.jobs.keys().collect() {
    self.cancel(id)
  }
}

///|
fn LoginManager::output(self : LoginManager, profile : String, run : Int, chunk : String) -> Unit {
  guard self.jobs.get(profile) is Some(running) && running.run == run else { return }
  // Read whole: an escape can be cut between two pieces.
  running.raw = last_points(running.raw + chunk, 16000)
  running.output = strip_ansi(running.raw)
  if running.agy is Some(_) {
    self.agy_answer(profile, running, chunk)
    if !self.is_current(profile, running) {
      return
    }
  }
  if running.said is Some(said) && running.job.state == "verifying" {
    let kept = last_points(said + chunk, 4000)
    running.said = Some(kept)
    // It waits on for Enter and another code: ended here, saying what to paste.
    if includes(lower(strip_ansi(kept)), claude_code_refused) {
      return self.finish(profile, "failed", Some(tr(self.words, running.lang, "station.login.claudeIncompleteCode", [])))
    }
  }
  if parse_login(running.job, running.output) {
    self.emit(profile)
  }
}

///|
fn LoginManager::fail_run(self : LoginManager, profile : String, run : Int, error : String) -> Unit {
  if self.run_current(profile, run) {
    self.finish(profile, "failed", Some(error))
  }
}

///|
fn LoginManager::finish(self : LoginManager, profile : String, state : String, error : String?) -> Unit {
  guard self.jobs.get(profile) is Some(running) else { return }
  self.jobs.remove(profile)
  (running.cancel_timer)()
  if running.stop is Some(s) {
    s()
  }
  if !running.exited && running.child is Some(child) {
    // The Antigravity CLI does not end by itself once signed in: the processes between end with it, all found first.
    match (running.job.runtime, child.pid) {
      ("agy", Some(pid)) => {
        let plat = self.deps.platform
        (self.io.spawn)(async fn() {
          let pids = (plat.descendants)(pid) catch { _ => [] }
          (plat.kill)(pid)
          for p in pids {
            (plat.kill)(p)
          }
        })
      }
      _ => (child.kill)()
    }
  }
  if running.opened is Some(o) {
    (self.io.spawn)(async fn() {
      (self.io.rm)(o, false) catch {
        _ => ()
      }
    })
  }
  if self.pages is Some(p) {
    (p.close)(page_key(profile))
  }
  let done = running.job.copy()
  done.state = state
  done.error = error
  self.finished[profile] = done
  (self.io.log)("info", "login", "login ended", {
    "profile": Json::string(profile),
    "state": Json::string(state),
    "error": opt(error),
  })
  self.emit(profile)
}

///|
fn LoginManager::emit(self : LoginManager, profile : String) -> Unit {
  for l in self.listeners.copy() {
    (l.1)(profile)
  }
}

///|
/// Makes the directory whose `open` and `xdg-open` open nothing, put first on the login command's PATH; gives what
/// `open` is to be called by (BROWSER). Each writes the pages it is given to the file STILLFAIL_LOGIN_OPENED names.
async fn LoginManager::no_browser(self : LoginManager) -> String {
  (self.io.mkdir)(self.no_browser_dir, true)
  let script = "#!/bin/sh\n# A browser for a sign-in run by still.fail (station/src/accounts/login.ts): the page goes to the station.\n[ -n \"$STILLFAIL_LOGIN_OPENED\" ] || exit 0\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >> \"$STILLFAIL_LOGIN_OPENED\"; done\nexit 0\n"
  let open = (self.deps.platform.make_command)(join([self.no_browser_dir, "open"]), script)
  ignore((self.deps.platform.make_command)(join([self.no_browser_dir, "xdg-open"]), script))
  open
}

///|
/// Reads where to sign in from what the command said so far. Whether the job changed.
pub fn parse_login(job : LoginJob, output : String) -> Bool {
  if job.state != "starting" {
    return false
  }
  let urls = split_space(output)
    .filter(w => includes(w, "https://"))
    .map(w => from(w, index_of(w, "https://")))
  let low = lower(output)
  match job.runtime {
    "claude" =>
      match urls.search_by(u => includes(u, "/oauth/authorize?") && !u.has_suffix("?")) {
        Some(i) if includes(low, "paste code") => {
          job.url = Some(urls[i])
          job.state = "needs_code"
          return true
        }
        _ => ()
      }
    "agy" =>
      match
        urls.search_by(u => u.has_prefix("https://accounts.google.com/o/oauth2/") &&
          includes(u, "antigravity.google%2Foauth-callback")) {
        Some(i) if includes(low, "authorization code") => {
          job.url = Some(urls[i])
          job.state = "needs_code"
          return true
        }
        _ => ()
      }
    "devin" =>
      match urls.search_by(u => u.has_prefix("https://app.devin.ai/auth/cli/") && includes(u, "code_challenge=")) {
        Some(i) if includes(low, "paste it") => {
          job.url = Some(urls[i])
          job.state = "needs_code"
          return true
        }
        _ => ()
      }
    rt => {
      let site = if rt == "grok" { "https://accounts.x.ai/" } else { "https://auth.openai.com/" }
      let url = urls.search_by(u => u.has_prefix(site) && includes(u, "device"))
      let code = device_code(output)
      match (url, code) {
        (Some(i), Some(c)) => {
          job.url = Some(urls[i])
          job.user_code = Some(c)
          job.state = "needs_approval"
          return true
        }
        _ => ()
      }
    }
  }
  false
}

///|
/// The code to type into `claude auth login` of what was pasted (trimmed): `code#state` as its page shows it, or the
/// address that page was at (`…/callback?code=…&state=…`), made `code#state`. Refused, saying what to paste instead,
/// where the command would not take it or where its state is another sign-in's than `auth_url`'s.
pub fn claude_code_of(words : Words, clean : String, auth_url : String?, lang : String) -> String raise Failed {
  let expected = match auth_url {
    Some(a) =>
      match @cloud_net.parse_url(a) {
        Some(u) => trim(param(u.query, "state").unwrap_or(""))
        None => ""
      }
    None => ""
  }
  let head = lower(sub(clean, 0, 8))
  let pasted = if head.has_prefix("http://") || head.has_prefix("https://") {
    @cloud_net.parse_url(clean)
  } else {
    None
  }
  let (code, state) = match pasted {
    Some(u) => {
      // (the authorize link itself, pasted back, says `code=true` and the state: no code of the person's)
      let authorize = u.path.has_suffix("/authorize") || u.path.has_suffix("/authorize/")
      (if authorize { "" } else { trim(param(u.query, "code").unwrap_or("")) }, trim(param(u.query, "state").unwrap_or("")))
    }
    None => {
      let parts = split(clean, "#")
      if parts.length() != 2 {
        raise Failed(tr(words, lang, "station.login.claudeIncompleteCode", []))
      }
      (trim(parts[0]), trim(parts[1]))
    }
  }
  if code == "" || state == "" {
    raise Failed(tr(words, lang, "station.login.claudeIncompleteCode", []))
  }
  if expected != "" && state != expected {
    raise Failed(tr(words, lang, "station.login.claudeWrongState", []))
  }
  "\{code}#\{state}"
}

///|
/// The code Google gave an Antigravity CLI sign-in, read off the page its browser came back to
/// (https://antigravity.google/oauth-callback?code=…&state=…), when that is its sign-in's (`auth_url`'s `state`).
pub fn agy_callback_code(tab_url : String?, auth_url : String?) -> String? {
  guard tab_url is Some(tab) else { return None }
  guard @cloud_net.parse_url(tab) is Some(back) else { return None }
  let mut path = back.path
  while path.has_suffix("/") {
    path = sub(path, 0, path.length() - 1)
  }
  if back.origin() != "https://antigravity.google" || path != "/oauth-callback" {
    return None
  }
  let code = trim(param(back.query, "code").unwrap_or(""))
  if code == "" {
    return None
  }
  let state = match auth_url {
    Some(a) =>
      match @cloud_net.parse_url(a) {
        Some(u) => param(u.query, "state").unwrap_or("")
        None => ""
      }
    None => ""
  }
  if state != "" && param(back.query, "state") != Some(state) {
    return None
  }
  Some(code)
}

///|
/// A one-time code like ABCD-12345: four capitals or digits, a dash, four to six more.
pub fn device_code(output : String) -> String? {
  let code = (s : String, least : Int, most : Int) => {
    if s.length() < least || s.length() > most {
      return false
    }
    for i in 0..<s.length() {
      let c = s.unsafe_charcode_at(i)
      if !((c >= 'A' && c <= 'Z') || is_ascii_digit(c)) {
        return false
      }
    }
    true
  }
  let words = []
  let mut word = StringBuilder()
  for i in 0..<output.length() {
    let c = output.unsafe_charcode_at(i)
    if is_ascii_alpha(c) || is_ascii_digit(c) || c == '_' || c == '-' {
      word.write_char(c.unsafe_to_char())
    } else {
      words.push(word.to_string())
      word = StringBuilder()
    }
  }
  words.push(word.to_string())
  for w in words {
    let parts = split(w, "-")
    for i in 0..<(parts.length() - 1) {
      if code(parts[i], 4, 4) && code(parts[i + 1], 4, 6) {
        return Some("\{parts[i]}-\{parts[i + 1]}")
      }
    }
  }
  None
}

///|
/// Drops terminal escapes (colours, cursor moves): ESC [ parameters letter; and ESC ] … ended by BEL or ESC \.
pub fn strip_ansi(text : String) -> String {
  let out = StringBuilder()
  let chars = points(text)
  let n = chars.length()
  let at = (k : Int) => if k < n { chars[k] } else { "" }
  let mut i = 0
  while i < n {
    let c = chars[i]
    if c == "\u{1b}" && at(i + 1) == "]" {
      i += 1
      while i + 1 < n && at(i + 1) != "\u{07}" && !(at(i + 1) == "\u{1b}" && at(i + 2) == "\\") {
        i += 1
      }
      i += if at(i + 1) == "\u{07}" { 1 } else { 2 }
      i += 1
      continue
    }
    if c == "\u{1b}" && at(i + 1) == "[" {
      i += 1
      while i + 1 < n {
        let p = chars[i + 1]
        i += 1
        let u = p.unsafe_charcode_at(0)
        if p.length() == 1 && is_ascii_alpha(u) {
          break
        }
        if !(p.length() == 1 && (is_ascii_digit(u) || u == ';' || u == '?')) {
          break
        }
      }
      i += 1
      continue
    }
    out.write_string(c)
    i += 1
  }
  out.to_string()
}

///|
fn last_lines(output : String) -> String {
  let lines = split_lines(trim(output)).filter(l => trim(l) != "")
  let start = if lines.length() > 4 { lines.length() - 4 } else { 0 }
  let joined = lines[start:].to_owned().join("\n")
  let p = points(joined)
  if p.length() <= 600 {
    joined
  } else {
    p[0:600].to_owned().join("")
  }
}
