// claude.ts: Claude Code, one `claude -p` stream-json process per session under a runner whose id comes from the
// session key. What it is started with (its arguments, settings, environment and token), a transcript brought to where
// `--resume` looks, what a session writes to it (a prompt, a steer, an interrupt, a compaction, a model, a new token it
// asked for) and tells the program, and what a next station takes it up from. Its frames are read by the program
// (mb/src/claude, reader agents.mbt).

///|
let mcp_token_var = "STILLFAIL_MCP_TOKEN"

///|
/// Inherited variables that would let a session authenticate as something other than its profile.
let claude_scrubbed : Array[String] = [
  "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDECODE",
  "CLAUDE_CODE_ENTRYPOINT",
]

///|
/// A token handed to the process is renewed while it runs (`RENEWED`).
let renewed_env : Array[(String, String)] = [
  ("CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH", "1"),
  ("CLAUDE_CODE_ENTRYPOINT", "claude-desktop"),
]

///|
/// What Claude Code brings of its own that a station's chat agent cannot or must not use (`DISALLOWED`).
let disallowed : Array[String] = ["ScheduleWakeup", "CronCreate", "CronDelete", "CronList", "RemoteTrigger"]

///|
/// A machine login's token this close to its end is not taken up (`CLAUDE_TOKEN_MARGIN_MS`).
let claude_token_margin_ms = 300000.0

///|
/// A hook that does not answer is given up on after this many seconds (`SUBAGENT_HOOK_SECONDS`).
let subagent_hook_seconds = 10

///|
/// The station's words a driver's settings name: its hooks' commands and the tools a session speaks by.
pub(all) struct Words {
  /// repo-rules.ts `REPO_RULES_COMMAND`
  repo_rules_command : String
  /// repo-rules.ts `AGY_REPO_RULES_COMMAND`
  agy_repo_rules_command : String
  /// claude.ts `hookCommand(SUBAGENT_HOOK, SLACK_SPOKEN.join(","))`
  subagent_hook_command : String
  /// tools/mcp.ts `SPEAKS`
  speaks : Array[String]
  /// tools/mcp.ts `SPEAKS_WRITING`
  speaks_writing : String
}

///|
/// The value given a flag in a process's arguments (`flagOf`).
pub fn flag_of(args : Array[String], flag : String) -> String? {
  match args.search(flag) {
    Some(i) if i + 1 < args.length() => Some(args[i + 1])
    _ => None
  }
}

///|
/// The Fast a process was started with (`fastOf`).
pub fn fast_of(args : Array[String]) -> Bool? {
  match parse_json(flag_of(args, "--settings").unwrap_or("")) {
    Some(settings) => bool_at(Some(settings), "fastMode")
    None => None
  }
}

///|
/// The address of the station's tools a process was started with (`mcpUrlOf`).
pub fn mcp_url_of(args : Array[String]) -> String? {
  guard parse_json(flag_of(args, "--mcp-config").unwrap_or("")) is Some(config) else { return None }
  let servers = get(Some(config), "mcpServers")
  for name in tool_servers {
    match str_at(get(servers, name), "url") {
      Some(u) => return Some(u)
      None => ()
    }
  }
  None
}

///|
/// What a frame says of the station's tools being out of reach (`toolsLostIn`): the reading's (mb/src/claude).
pub fn tools_lost_in(frame : JValue, calls : Array[Array[Int]]) -> String? {
  @claude.tools_lost_in(frame, calls).map(@jsjson.text)
}

///|
/// A message of the person's as Claude Code reads it (`userMessage`).
pub fn user_message(text : String) -> String {
  json_text(
    obj([
      ("type", s("user")),
      (
        "message",
        obj([("role", s("user")), ("content", arr([obj([("type", s("text")), ("text", s(text))])]))]),
      ),
    ]),
  )
}

///|
/// A directory as Claude Code names its project (read/transcript.ts `claudeProject`).
pub fn claude_project(cwd : String) -> String? {
  let out = StringBuilder()
  for c in @jsjson.units(cwd) {
    let ok = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a)
    out.write_char(if ok { c.unsafe_to_char() } else { '-' })
  }
  let name = out.to_string()
  if name.length() <= 200 {
    Some(name)
  } else {
    None
  }
}

///|
/// Where Claude keeps a session (`transcriptAt`): in the project of the cwd as it sees it, then as given, then in every
/// project's.
pub fn transcript_at(m : Machine, home : String, session_id : String, cwd : String) -> Later[String?] {
  m
  .realpath(cwd)
  .bind(real => {
    let projects : Array[String?] = []
    for p in [claude_project(real.unwrap_or(cwd)), claude_project(cwd)] {
      if !projects.contains(p) {
        projects.push(p)
      }
    }
    let found : Ref[String?] = Ref(None)
    each_in_turn(m.lp, projects.length(), i => {
      if found.val is Some(_) {
        return done(m.lp)
      }
      match projects[i] {
        None => done(m.lp)
        Some(project) => {
          let here = m.join([home, "projects", project, "\{session_id}.jsonl"])
          m.is_file(here).map(yes => if yes { found.val = Some(here) })
        }
      }
    }).bind(_ => {
      if found.val is Some(_) {
        return Later::ok(m.lp, found.val)
      }
      m
      .read_dir(m.join([home, "projects"]))
      .map(d => Some(d))
      .recover(_ => Later::ok(m.lp, None))
      .bind(dirs => {
        guard dirs is Some(dirs) else { return Later::ok(m.lp, None) }
        each_in_turn(m.lp, dirs.length(), i => {
          if found.val is Some(_) {
            return done(m.lp)
          }
          let path = m.join([home, "projects", dirs[i], "\{session_id}.jsonl"])
          m.is_file(path).map(yes => if yes { found.val = Some(path) })
        }).map(_ => found.val)
      })
    })
  })
}

///|
/// A session found in another directory's project linked into the cwd's, where `--resume` looks (`bringTranscript`).
pub fn bring_transcript(
  m : Machine,
  home : String,
  session_id : String,
  cwd : String,
  found : String,
) -> Later[Unit] {
  m
  .realpath(cwd)
  .bind(real => {
    guard claude_project(real.unwrap_or(cwd)) is Some(project) else { return done(m.lp) }
    let dir = m.join([home, "projects", project])
    let here = m.join([dir, "\{session_id}.jsonl"])
    if here == found {
      return done(m.lp)
    }
    m
    .make_dir(dir)
    .bind(_ => m.link(found, here))
    .recover(e => {
      m.log(
        "warn",
        "agents::claude",
        "could not bring a session's transcript to where claude resumes it",
        obj([("session", s(session_id)), ("error", s(words_of(e)))]),
      )
      done(m.lp)
    })
  })
}

///|
/// What its tasks as the turn leaves them run in the background (`backgroundOf`).
pub fn background_of(turn : JValue) -> JValue {
  let out = []
  for e in entries_of(get(Some(turn), "tasks")) {
    let t = e.1
    if !is_true(Some(t), "background") {
      continue
    }
    let fields = [
      ("id", get(Some(t), "id").unwrap_or(Null)),
      ("kind", get(Some(t), "kind").unwrap_or(Null)),
      ("description", get(Some(t), "description").unwrap_or(Null)),
    ]
    match get(Some(t), "startedAt") {
      Some(at) => fields.push(("startedAt", at))
      None => ()
    }
    out.push(obj(fields))
  }
  arr(out)
}

///|
/// Sets of hooks as one: an event several have keeps the entries of each, in their order (`hooksOf`).
pub fn hooks_of(sets : Array[JValue]) -> JValue {
  let mut all_hooks = obj([])
  for set_ in sets {
    for e in entries_of(Some(set_)) {
      let before = arr_at(Some(all_hooks), e.0).unwrap_or([])
      all_hooks = set(all_hooks, e.0, arr(before + arr_of(Some(e.1)).unwrap_or([])))
    }
  }
  all_hooks
}

///|
/// The hook that refuses a subagent the tools a session speaks by (`SILENT_SUBAGENTS`).
pub fn silent_subagents(w : Words) -> JValue {
  let tools = w.speaks + [w.speaks_writing]
  let matcher = tool_servers
    .map(server => tools.map(tool => "mcp__\{server}__\{tool}").join("|"))
    .join("|")
  obj([
    (
      "PreToolUse",
      arr([
        obj([
          ("matcher", s(matcher)),
          (
            "hooks",
            arr([
              obj([
                ("type", s("command")),
                ("command", s(w.subagent_hook_command)),
                ("timeout", n(subagent_hook_seconds)),
              ]),
            ]),
          ),
        ]),
      ]),
    ),
  ])
}

///|
/// The repository's rules told as its tools first touch it, and again after a compaction (`SETTINGS.hooks`).
pub fn claude_settings_hooks(w : Words) -> JValue {
  let command = () => arr([obj([("type", s("command")), ("command", s(w.repo_rules_command))])])
  obj([
    (
      "PostToolUse",
      arr([
        obj([
          ("matcher", s("Bash|Read|Edit|Write|MultiEdit|NotebookEdit|Grep|Glob")),
          ("hooks", command()),
        ]),
      ]),
    ),
    ("SessionStart", arr([obj([("matcher", s("compact")), ("hooks", command())])])),
  ])
}

///|
/// What Claude Code brings of its own kept out of a station's chat agent's context (`SETTINGS`).
pub fn claude_settings(w : Words) -> JValue {
  let overrides = []
  for name in ["loop", "schedule", "keybindings-help", "fewer-permission-prompts", "plugin-authoring", "update-config"] {
    overrides.push((name, s("off")))
  }
  for name in ["dataviz", "claude-api", "code-review", "run"] {
    overrides.push((name, s("name-only")))
  }
  for name in [
    "computer-use", "chrome-browser", "built-in-browser", "docs", "google-workspace", "morning", "import-memory",
  ] {
    overrides.push(("anthropic-skills:\{name}", s("off")))
  }
  for name in ["docx", "pptx", "xlsx", "pdf", "deep-research", "skill-creator"] {
    overrides.push(("anthropic-skills:\{name}", s("name-only")))
  }
  obj([
    ("disableClaudeAiConnectors", b(true)),
    ("hooks", claude_settings_hooks(w)),
    ("skillOverrides", obj(overrides)),
  ])
}

///|
/// A current token for a process, renewed first when `rejected` is the one given: its token and when it runs out.
pub type Renew = (String?) -> Later[(String, Double)]

///|
/// Where the drivers get logins and keep them (claude.ts's options, no-keychain.ts, accounts/oauth.ts).
pub(all) struct ClaudeLogins {
  /// the machine login's current token (`machineToken`)
  machine_token : Renew
  /// a local subscription profile's current token, renewed under one lock (`subscriptionToken`)
  subscription_token : ((JValue) -> Renew)?
  /// another station's subscription, borrowed (`lent`): whether a profile is, and its token
  lent_borrowed : ((JValue) -> Bool)?
  lent_token : ((JValue) -> Renew)?
  /// the machine keeps logins in a keychain (`platform.hasKeychain`)
  has_keychain : Bool
  /// the directory of the keychain's stub put first on a process's PATH (no-keychain.ts `stubDirSoon`)
  stub_dir : () -> Later[String]
  /// a profile's login Claude Code moved into the keychain moved back (`takeBack`)
  take_back : (String) -> Later[Unit]
  /// the same with no file there (`takeBackMissing`)
  take_back_missing : (String) -> Later[Bool]
}

///|
/// The access token kept in a profile's home (accounts/oauth.ts `claudeToken`).
pub fn claude_file_token(m : Machine, home : String) -> Later[String?] {
  m
  .read_file(m.join([home, ".credentials.json"]))
  .map(text => match parse_json(text) {
    Some(j) =>
      match str_at(get(Some(j), "claudeAiOauth"), "accessToken") {
        Some(tok) if tok != "" => Some(tok)
        _ => None
      }
    None => None
  })
  .recover(_ => Later::ok(m.lp, None))
}

///|
/// A Claude Code session (`ClaudeSession`).
pub struct ClaudeSession {
  own : OwnSession
  driver : ClaudeDriver
  /// run as an interactive TUI under its bridge (claude-tui.mjs's, the station's program's: `TuiBridge`)
  tui : Bool
  /// when the machine login's token it runs on runs out
  machine_expires : Double?
  effort : String?
  mut fast : Bool?
  renew : Renew?
  mut token : String?
}

///|
/// The Claude Code driver (`ClaudeDriver`).
pub struct ClaudeDriver {
  own : OwnDriver
  command : String
  /// the station's own environment with its owners' variables for what it starts (`startEnv`'s source)
  raw_env : Env
  words : Words
  profiles : ProfileSays
  logins : ClaudeLogins
  ids : Ids
  sessions : Array[ClaudeSession]
  /// what runs a session as a TUI (claude.ts `TUI_BRIDGE`, `TUI_NODE`, `runnerBinary`); none: no TUI here
  tui_bridge : Ref[TuiBridge?]
}

///|
/// What runs a Claude session as its interactive TUI (claude-tui.mjs): `program` (the hooks' and tools' command, the
/// station's program where a release has no Node) given the bridge's `script`, then `program`, the `runner` whose
/// `--relay-pty` keeps the terminal, and Claude's command and arguments; `shell_env` puts the user's shell's PATH in
/// an environment where it does not find Claude's command (`withShellCommand`).
pub(all) struct TuiBridge {
  program : String
  script : String
  runner : String
  shell_env : (String, Env) -> Later[Unit]
}

///|
/// Whether a runner keeps a TUI's bridge (claude.ts `tuiRunner`): its first argument the bridge's file.
pub fn tui_runner(args : Array[String]) -> Bool {
  match args.get(0) {
    Some(a) => {
      let a = a.replace_all(old="\\", new="/")
      a == "claude-tui.mjs" || a.has_suffix("/claude-tui.mjs")
    }
    None => false
  }
}

///|
pub fn ClaudeDriver::new(
  m : Machine,
  data : String,
  procs : Procs,
  command? : String = "claude",
  raw_env : Env,
  words : Words,
  profiles : ProfileSays,
  logins : ClaudeLogins,
  ids : Ids,
) -> ClaudeDriver {
  {
    own: OwnDriver::new(m, data, procs, "claude"),
    command,
    raw_env,
    words,
    profiles,
    logins,
    ids,
    sessions: [],
    tui_bridge: Ref(None),
  }
}

///|
pub fn ClaudeDriver::lp(self : ClaudeDriver) -> Loop {
  self.own.m.lp
}

///|
/// Fast as the session is set, else as its profile is, for an account that takes it (`fastFor`).
pub fn fast_for(options : JValue) -> Bool? {
  let profile = get(Some(options), "profile").unwrap_or(Null)
  if !takes_fast(profile) {
    return None
  }
  match bool_at(Some(options), "fast") {
    Some(f) => Some(f)
    None => Some(profile_fast(profile))
  }
}

///|
/// Where a profile whose token is handed to the process gets a current one (`renewer`).
pub fn ClaudeDriver::renewer(self : ClaudeDriver, profile : JValue) -> Renew? {
  if is_machine(profile) {
    return Some(self.logins.machine_token)
  }
  match (self.logins.lent_borrowed, self.logins.lent_token) {
    (Some(borrowed), Some(token)) if borrowed(profile) => return Some(token(profile))
    _ => ()
  }
  if access_kind(profile) == "subscription" {
    match self.logins.subscription_token {
      Some(f) => return Some(f(profile))
      None => ()
    }
  }
  None
}

///|
pub fn ClaudeDriver::borrowed(self : ClaudeDriver, profile : JValue) -> Bool {
  match self.logins.lent_borrowed {
    Some(f) => f(profile)
    None => false
  }
}

///|
/// The file a profile's runtime reads its current key from (`keyFile`).
pub fn key_file(m : Machine, profile : JValue) -> String? {
  if kimi_signed_in(profile) {
    Some(m.join([profile_home(profile), "kimi-code.token"]))
  } else {
    None
  }
}

///|
/// A process's arguments for a session (`open`'s).
pub fn ClaudeDriver::args_for(
  self : ClaudeDriver,
  options : JValue,
  session_id : String,
  fast : Bool?,
  file : String?,
) -> Array[String] {
  let o = Some(options)
  let profile = get(o, "profile").unwrap_or(Null)
  let text_only = is_true(o, "textOnly")
  let resumed = str_at(o, "resume")
  let mcp_config = if text_only {
    obj([("mcpServers", obj([]))])
  } else {
    obj([
      (
        "mcpServers",
        obj([
          (
            "stillfail",
            obj([
              ("type", s("http")),
              ("url", get(o, "mcpUrl").unwrap_or(Null)),
              ("headers", obj([("Authorization", s("Bearer ${\{mcp_token_var}}"))])),
            ]),
          ),
        ]),
      ),
    ])
  }
  let model = match str_at(o, "model") {
    Some(m) => Some(m)
    None => profile_model(profile)
  }
  let tui = !text_only && is_true(o, "tui")
  let args = if tui {
    []
  } else {
    [
      "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
    ]
  }
  if !text_only {
    args.push("--dangerously-skip-permissions")
  }
  if resumed is Some(_) {
    args.append(["--resume", session_id])
  } else {
    args.append(["--session-id", session_id])
  }
  match model {
    Some(m) => args.append(["--model", m])
    None => ()
  }
  match str_at(o, "effort") {
    Some(e) => args.append(["--effort", e])
    None => ()
  }
  let instructions = str_at(o, "instructions").unwrap_or("")
  let ours = instructions != ""
  if ours {
    args.append(["--append-system-prompt", instructions])
  }
  args.append(["--mcp-config", json_text(mcp_config)])
  if text_only {
    args.append([
      "--strict-mcp-config", "--tools", "", "--setting-sources", "", "--no-session-persistence", "--disable-slash-commands",
      "--no-chrome",
    ])
  }
  if ours {
    args.append(["--disallowedTools", disallowed.join(",")])
  }
  let parts = []
  if ours {
    parts.push(claude_settings(self.words))
  }
  if !text_only {
    let hooks = hooks_of([
      if ours {
        claude_settings_hooks(self.words)
      } else {
        obj([])
      },
      silent_subagents(self.words),
    ])
    parts.push(obj([("disableAllHooks", b(false)), ("hooks", hooks)]))
  }
  match file {
    Some(f) => {
      let quoted = f.replace_all(old="'", new="'\\''")
      parts.push(obj([("apiKeyHelper", s("cat '\{quoted}'"))]))
    }
    None => ()
  }
  match get(o, "context") {
    Some(Num(_) as c) => parts.push(obj([("autoCompactWindow", c)]))
    _ => ()
  }
  match fast {
    Some(f) => parts.push(obj([("fastMode", b(f))]))
    None => ()
  }
  let settings = spread(parts)
  if settings is Obj(es) && es.length() > 0 {
    args.append(["--settings", json_text(settings)])
  }
  args
}

///|
/// Opens a session: its process started (`open`).
pub fn ClaudeDriver::open(self : ClaudeDriver, options : JValue, events : (JValue) -> Unit) -> Later[ClaudeSession] {
  let m = self.own.m
  let lp = self.lp()
  let o = Some(options)
  let profile = get(o, "profile").unwrap_or(Null)
  let home = profile_home(profile)
  let cwd = str_at(o, "cwd").unwrap_or("")
  let resumed = str_at(o, "resume")
  m
  .make_dir(home)
  .bind(_ => match resumed {
    Some(id) =>
      transcript_at(m, home, id, cwd).bind(found => match found {
        None => Later::fail(lp, Failed("no claude transcript for session \{id}"))
        Some(f) => bring_transcript(m, home, id, cwd, f)
      })
    None => done(lp)
  })
  .bind(_ => {
    let session_id = match resumed {
      Some(id) => id
      None => (self.ids.next)()
    }
    let file = key_file(m, profile)
    let fast = fast_for(options)
    let tui = !is_true(o, "textOnly") && is_true(o, "tui")
    let bridge = if tui {
      match self.tui_bridge.val {
        Some(b) => Some(b)
        None => return Later::fail(lp, Failed("Claude's TUI has no bridge on this station: select Print in model settings"))
      }
    } else {
      None
    }
    let args = self.args_for(options, session_id, fast, file)
    let env = start_env(self.raw_env, claude_scrubbed)
    env.merge(expand_route((self.profiles.env)(profile, "claude"), str_at(o, "route").unwrap_or("")))
    // The profile's own proxy too leaves this machine out (`keepLocal`).
    let env = keep_local(env)
    if file is Some(_) {
      env.set("CLAUDE_CODE_API_KEY_HELPER_TTL_MS", "60000")
    }
    env.set("CLAUDE_CONFIG_DIR", home)
    env.set(mcp_token_var, str_at(o, "mcpToken").unwrap_or(""))
    let mcp_url = str_at(o, "mcpUrl").unwrap_or("")
    env.set("STILLFAIL_PEER_HTTP", peer_http_base(mcp_url))
    env.set("STILLFAIL_RUNTIME_SESSION_ID", session_id)
    let machine_profile = is_machine(profile)
    let local_sub = !machine_profile &&
      !self.borrowed(profile) &&
      access_kind(profile) == "subscription"
    let credentials = if !machine_profile && self.logins.has_keychain {
      (self.logins.stub_dir)().map(dir => {
        let path = match env.get("PATH") {
          Some(p) => p
          None => self.raw_env.get("PATH").unwrap_or("")
        }
        env.set("PATH", "\{dir}:\{path}")
      })
    } else {
      done(lp)
    }
    let renew = self.renewer(profile)
    let machine : Ref[(String, Double)?] = Ref(None)
    let renews = Ref(renew is Some(_))
    credentials
    .bind(_ => match renew {
      Some(r) =>
        r(None)
        .map(got => machine.val = Some(got))
        .recover(error => {
          if !local_sub {
            return Later::fail(lp, error)
          }
          claude_file_token(m, home).bind(kept => match kept {
            Some(token) => {
              if error is RenewRefused(_) {
                env.set("CLAUDE_CODE_OAUTH_TOKEN", token)
                renews.val = false
              } else {
                machine.val = Some((token, 0.0))
              }
              done(lp)
            }
            None => {
              let back = if self.logins.has_keychain {
                (self.logins.take_back_missing)(home).map(_ => ())
              } else {
                done(lp)
              }
              back.map(_ => renews.val = false)
            }
          })
        })
      None =>
        if !machine_profile && self.logins.has_keychain {
          (self.logins.take_back)(home)
        } else {
          done(lp)
        }
    })
    .bind(_ => {
      match machine.val {
        Some((token, _)) => {
          env.set("CLAUDE_CODE_OAUTH_TOKEN", token)
          if !tui {
            env.merge(renewed_env)
          }
        }
        None => ()
      }
      env.set_unset("CLAUDE_CODE_CERT_STORE", "bundled")
      env.set_unset("CLAUDE_CODE_SILENT_TURN_REMINDER", "0")
      let turn = obj([
        ("busy", b(false)),
        ("aborting", b(false)),
        ("authFailure", Null),
        ("closed", b(false)),
        ("renews", b((!tui && machine.val is Some(_) && renews.val) || file is Some(_))),
      ])
      let session = ClaudeSession::make(
        self,
        session_id,
        turn,
        if tui {
          machine.val.map(x => x.1)
        } else {
          None
        },
        Null,
        events,
        str_at(o, "effort"),
        if renews.val {
          renew
        } else {
          None
        },
        machine.val.map(x => x.0),
        tui~,
      )
      session.own.tools_url = str_at(o, "mcpUrl")
      session.fast = fast
      let started = match bridge {
        // First-run appearance selection is for a person at a terminal. The TUI still requires a trusted workspace for
        // hooks.
        Some(br) => {
          env.set("IS_DEMO", "1")
          (br.shell_env)(self.command, env).bind(_ => self.own.start(
            session.own,
            str_at(o, "key").unwrap_or(""),
            cwd,
            br.program,
            [br.script, br.program, br.runner, self.command, ..args],
            env,
            session.own.hosted_options("claude \{session_id}", "claude"),
          ))
        }
        None =>
          self.own.start(
            session.own,
            str_at(o, "key").unwrap_or(""),
            cwd,
            self.command,
            args,
            env,
            session.own.hosted_options("claude \{session_id}", "claude"),
          )
      }
      started
      .map(_ => {
        self.sessions.push(session)
        session
      })
    })
  })
}

///|
pub fn ClaudeSession::make(
  driver : ClaudeDriver,
  session_id : String,
  turn : JValue,
  machine_expires : Double?,
  live : JValue,
  events : (JValue) -> Unit,
  effort : String?,
  renew : Renew?,
  token : String?,
  tui? : Bool = false,
) -> ClaudeSession {
  let own = OwnSession::new(driver.lp(), "claude", session_id, turn, events, live~)
  let session = { own, driver, tui, machine_expires, effort, fast: None, renew, token }
  own.hooks = {
    ..no_hooks(),
    took: e => {
      if str_at(Some(e), "type") != Some("renew") {
        return false
      }
      let request = match get(Some(e), "requestId") {
        Some(Str(u)) => @jsjson.text(u)
        Some(Num(x)) => @jsjson.stringify(Num(x))
        Some(Bool(x)) => x.to_string()
        Some(Null) | None => ""
        Some(other) => @jsjson.stringify(other)
      }
      session.renew_token(request)
      true
    },
  }
  session
}

///|
/// Taken up: the session a snapshot says (`handedOver`).
pub fn ClaudeDriver::handed_over(
  self : ClaudeDriver,
  options : JValue,
  handed : JValue,
  info : RunnerInfo,
  events : (JValue) -> Unit,
) -> ClaudeSession {
  let profile = get(Some(options), "profile").unwrap_or(Null)
  let turn = spread([get(Some(handed), "turn").unwrap_or(obj([])), obj([("closed", b(false))])])
  let session = ClaudeSession::make(
    self,
    str_at(Some(handed), "id").unwrap_or(""),
    turn,
    num_at(Some(handed), "machineExpires"),
    get(Some(handed), "live").unwrap_or(Null),
    events,
    flag_of(info.args(), "--effort"),
    self.renewer(profile),
    None,
    tui=tui_runner(info.args()),
  )
  session.own.tools_url = mcp_url_of(info.args())
  session.fast = fast_of(info.args())
  session
}

///|
/// Taken up after a crash: what the program read again says where the turn stands (`crashed`).
pub fn ClaudeDriver::crashed(
  self : ClaudeDriver,
  options : JValue,
  replayed : JValue,
  info : RunnerInfo,
  events : (JValue) -> Unit,
) -> ClaudeSession {
  let profile = get(Some(options), "profile").unwrap_or(Null)
  let base = obj([("busy", b(false)), ("aborting", b(false)), ("authFailure", Null)])
  let replayed_turn = match get(Some(replayed), "turn") {
    Some(Obj(_) as t) => t
    _ => obj([])
  }
  let turn = spread([base, replayed_turn, obj([("closed", b(false))])])
  let args = info.args()
  let session_id = match args.search_by(a => a == "--session-id" || a == "--resume") {
    Some(i) if i + 1 < args.length() => args[i + 1]
    _ => str_at(Some(options), "resume").unwrap_or("")
  }
  let renew = self.renewer(profile)
  let live = match get(Some(replayed), "live") {
    Some(l) => l
    None => Null
  }
  let session = ClaudeSession::make(
    self,
    session_id,
    turn,
    if renew is Some(_) {
      Some(self.own.m.now())
    } else {
      None
    },
    live,
    events,
    flag_of(args, "--effort"),
    renew,
    None,
    tui=tui_runner(args),
  )
  session.own.tools_url = mcp_url_of(args)
  session.fast = fast_of(args)
  session
}

///|
/// Takes up a session whose process a runner kept (`adopt`).
pub fn ClaudeDriver::adopt(
  self : ClaudeDriver,
  options : JValue,
  snapshot : JValue?,
  events : (JValue) -> Unit,
) -> Later[ClaudeSession] {
  let made : Ref[ClaudeSession?] = Ref(None)
  let how = {
    handed_over: (h, info) => {
      let x = self.handed_over(options, h, info, events)
      made.val = Some(x)
      x.own
    },
    crashed: (r, info) => {
      let x = self.crashed(options, r, info, events)
      made.val = Some(x)
      Later::ok(self.lp(), x.own)
    },
    hosting_kind: "claude",
    flavor: None,
    kept: false,
    replaying: match str_at(Some(options), "resume") {
      Some(r) => obj([("resume", s(r))])
      None => obj([])
    },
    label: x => "claude \{x.session_id}",
    options_of: (x, label) => x.hosted_options(label, "claude"),
    adopted: x => match x.settled() {
      Some(w) => w
      None => done(self.lp())
    },
  }
  self.own
  .adopt(str_at(Some(options), "key").unwrap_or(""), snapshot, events, how)
  .map(_ => {
    let session = made.val.unwrap()
    self.sessions.push(session)
    session
  })
}

///|
/// It was refused with its token and asks for a new one (`renewToken`).
pub fn ClaudeSession::renew_token(self : ClaudeSession, request_id : String) -> Unit {
  let m = self.driver.own.m
  let lp = m.lp
  let asked = match self.renew {
    None => Later::fail(lp, Failed("its token is its own login's"))
    Some(r) =>
      r(self.token).map(got => {
        if self.token == Some(got.0) {
          raise Failed("no newer token")
        }
        self.token = Some(got.0)
        self.own.set_flag("renewed", b(true))
        (self.own.p().tell)("renewed")
        m.log("info", "agents::claude", "gave claude a new token", obj([("session", s(self.own.session_id))]))
        obj([("accessToken", s(got.0))])
      })
  }
  asked
  .recover(error => {
    m.log(
      "warn",
      "agents::claude",
      "no new token for claude",
      obj([("session", s(self.own.session_id)), ("error", s(words_of(error)))]),
    )
    Later::ok(lp, obj([("accessToken", Null), ("reason", s("refresh_failed"))]))
  })
  .on(r => {
    guard r is Ok(response) else { return }
    if self.own.closed() {
      return
    }
    (self.own.p().write)(
      json_text(
        obj([
          ("type", s("control_response")),
          (
            "response",
            obj([("subtype", s("success")), ("request_id", s(request_id)), ("response", response)]),
          ),
        ]),
      ),
    )
  })
}

///|
pub fn ClaudeSession::begin(self : ClaudeSession) -> Unit raise {
  self.own.startable()
  match self.machine_expires {
    Some(at) if at - self.driver.own.m.now() < claude_token_margin_ms =>
      raise Said("station.claudeAuth.machineRunsOut")
    _ => ()
  }
  self.own.set_flag("renewed", b(false))
  self.own.set_flag("busy", b(true))
  (self.own.p().tell)("begin")
}

///|
/// A turn (`prompt`).
pub fn ClaudeSession::prompt(self : ClaudeSession, text : String) -> Later[Unit] {
  let lp = self.driver.lp()
  self.begin() catch {
    e => return Later::fail(lp, e)
  }
  (self.own.p().write)(user_message(text))
  done(lp)
}

///|
/// Its `/compact` (`compact`).
pub fn ClaudeSession::compact(self : ClaudeSession) -> Later[Unit] {
  let lp = self.driver.lp()
  self.begin() catch {
    e => return Later::fail(lp, e)
  }
  self.own.set_flag("compacting", b(true))
  self.own.set_flag("compactError", Null)
  (self.own.p().tell)("compact")
  (self.own.p().write)(
    if self.tui {
      json_text(obj([("type", s("compact"))]))
    } else {
      user_message("/compact")
    },
  )
  done(lp)
}

///|
/// A TUI's machine login runs out within the margin: its next turn starts it again (`outlived`).
pub fn ClaudeSession::outlived(self : ClaudeSession) -> Bool {
  self.tui &&
  (match self.machine_expires {
    Some(at) => at - self.driver.own.m.now() < claude_token_margin_ms
    None => false
  })
}

///|
pub fn ClaudeSession::steer(self : ClaudeSession, text : String) -> Later[Bool] {
  // (the station keeps busy-time deliveries in its inbox until a TUI finishes its turn)
  if self.tui || self.own.closed() || !self.own.busy() {
    return Later::ok(self.driver.lp(), false)
  }
  (self.own.p().write)(user_message(text))
  Later::ok(self.driver.lp(), true)
}

///|
/// Ctrl+B (`backgroundTools`).
pub fn ClaudeSession::background_tools(self : ClaudeSession) -> Later[Unit] {
  if !(self.own.closed() || !self.own.busy()) {
    (self.own.p().write)(
      json_text(
        obj([
          ("type", s("control_request")),
          ("request_id", s("background-\{(self.driver.ids.next)()}")),
          ("request", obj([("subtype", s("background_tasks"))])),
        ]),
      ),
    )
  }
  done(self.driver.lp())
}

///|
pub fn ClaudeSession::abort(self : ClaudeSession) -> Later[Unit] {
  if !(self.own.closed() || !self.own.busy() || self.own.flag("aborting")) {
    self.own.set_flag("aborting", b(true))
    (self.own.p().tell)("aborting")
    (self.own.p().write)(
      json_text(
        obj([
          ("type", s("control_request")),
          ("request_id", s("interrupt-\{(self.driver.ids.next)()}")),
          ("request", obj([("subtype", s("interrupt"))])),
        ]),
      ),
    )
  }
  done(self.driver.lp())
}

///|
/// Another model set in the process; another effort or Fast needs a new one (`retune`).
pub fn ClaudeSession::retune(self : ClaudeSession, options : JValue) -> Bool {
  let profile = get(Some(options), "profile").unwrap_or(Null)
  let model = match str_at(Some(options), "model") {
    Some(m) => Some(m)
    None => profile_model(profile)
  }
  if self.tui ||
    is_true(Some(options), "tui") ||
    self.own.closed() ||
    self.own.busy() ||
    model is None ||
    str_at(Some(options), "effort") != self.effort ||
    fast_for(options) != self.fast {
    return false
  }
  (self.own.p().write)(
    json_text(
      obj([
        ("type", s("control_request")),
        ("request_id", s("model-\{(self.driver.ids.next)()}")),
        ("request", obj([("subtype", s("set_model")), ("model", s(model.unwrap()))])),
      ]),
    ),
  )
  true
}

///|
pub fn ClaudeSession::background(self : ClaudeSession) -> JValue {
  background_of(self.own.turn)
}

///|
/// What a next station takes it up from (`snapshot`).
pub fn ClaudeSession::snapshot(self : ClaudeSession) -> JValue {
  let frozen = self.own.hand_over()
  let (t, live) = match frozen {
    Some((turn, live)) => (turn, live)
    None => (self.own.turn, self.own.live_state)
  }
  let turn = [
    ("busy", b(is_true(Some(t), "busy"))),
    ("aborting", b(is_true(Some(t), "aborting"))),
  ]
  turn.push((
    "authFailure",
    match get(Some(t), "authFailure") {
      Some(v) => v
      None => Null
    },
  ))
  for k in ["renews", "tasks", "compacting", "compactError"] {
    match get(Some(t), k) {
      Some(v) => turn.push((k, v))
      None => ()
    }
  }
  obj([
    ("runtime", s("claude")),
    ("id", s(self.own.session_id)),
    ("runner", s(self.own.p().info.id())),
    ("turn", obj(turn)),
    (
      "machineExpires",
      match self.machine_expires {
        Some(x) => d(x)
        None => Null
      },
    ),
    ("live", live),
  ])
}

///|
pub fn ClaudeSession::dispose(self : ClaudeSession) -> Later[Unit] {
  self.own.dispose()
}

///|
pub fn ClaudeSession::detach(self : ClaudeSession) -> Unit {
  self.own.detach()
}
