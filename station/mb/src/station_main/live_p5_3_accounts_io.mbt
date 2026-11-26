// What the accounts ask of the machine past their files (accounts/oauth.ts `claudeOAuthToken`, quota.ts `grokBilling`,
// agy-quota.ts `runAgyUsage`, ops/shell-path.ts `withShellCommand`, machine-logins.ts `codexAuthFile`), as this program
// does it: Claude's logins renewed through accounts_oauth's ClaudeAuth over the machine's keychain and files, the CLIs
// run as children of this process. What only the agents' side has (a running app-server's rate limits, Antigravity
// CLI's login taken back from the keychain) is asked of it on the bus.

///|
/// How long a lend waits for its login's renewal (accounts/index.ts `lendBound`): LEND_BOUND_MS on the wall's clock.
fn p53_lend_bound(host : @host.Host) -> @accounts_oauth.Bound {
  { ms: @accounts_oauth.lend_bound_ms, after: (ms, f) => bus_after(host, ms.to_double(), f) }
}

///|
/// The machine's Claude logins as the renewal reads and keeps them (oauth.ts's `read`, `save`): macOS's keychain item
/// first for the machine's own, `security -i` given its commands on stdin.
fn p53_claude_store(host : @host.Host) -> @accounts_oauth.ClaudeStore {
  let mac = platform() == "darwin"
  {
    has_keychain: mac,
    read_keychain: async fn(env) {
      match @agent_runtimes.read_claude_keychain(host, env) {
        Found(t) => KeychainFound(t)
        Missing => KeychainMissing
        Unreadable => KeychainUnreadable
      }
    },
    take_back_missing: async fn(home) { @agent_runtimes.take_back_missing(host, home, mac) },
    home_of: env => env.get("HOME"),
    user_name: async fn() {
      match run_capture(host, "/usr/bin/id", ["-un"], ms=10000) {
        Some((code, _, out, _, false)) => Some((code == Some(0), out))
        _ => None
      }
    },
    security: async fn(env, input, ms) {
      match run_capture(host, "/usr/bin/security", ["-i"], env=env.to_array(), input~, ms~) {
        None => SecurityUnstarted
        Some((_, _, _, _, true)) => SecurityTimedOut
        Some((code, _, _, _, false)) => SecurityExited(code)
      }
    },
  }
}

///|
/// The station's environment as the machine's logins read it.
fn p53_station_env() -> Map[String, String] {
  Map::from_array(env_all())
}

///|
/// quota.ts `grokBilling`: what Grok Build says of the account's billing, asked of `grok agent --no-leader stdio` over
/// its JSON-RPC (initialize, then `_x.ai/billing`), given 30 s.
async fn p53_grok_billing(host : @host.Host, env : Array[(String, String)]) -> Json {
  let program = find_command("grok", env).unwrap_or("grok")
  let proc = spawn(host, program, ["agent", "--no-leader", "stdio"], env~, stdin_piped=true, stdout=Piped, stderr=Piped) catch {
    _ => raise P53Error("grok did not start")
  }
  let send = (m : Json) => ignore(proc.write(@utf8.encode(m.stringify() + "\n")))
  let late = Ref(false)
  let killer = host.rt.fork(name="grok's billing, its deadline", async fn() {
    @effect.sleep(30000) // timer: a deadline to a process
    late.val = true
    ignore(kill(proc.pid, "SIGKILL"))
  })
  send({ "jsonrpc": "2.0", "id": "init", "method": "initialize", "params": { "protocolVersion": 1, "clientCapabilities": {} } })
  let buffer = @buffer.Buffer()
  let stderr = Ref("")
  let mut out : Result[Json, String]? = None
  while out is None {
    match proc.events.take() {
      Out(b) => {
        buffer.write_bytes(b)
        let text = @utf8.decode_lossy(buffer.to_bytes())
        let lines = text.split("\n").map(l => l.to_owned()).collect()
        buffer.reset()
        buffer.write_bytes(@utf8.encode(lines[lines.length() - 1]))
        for line in lines[:lines.length() - 1] {
          match (try { Ok(@json.parse(line)) } catch { e => Err(e) }) {
            Ok(m) =>
              match jfield(m, "id") {
                String("init") => send({ "jsonrpc": "2.0", "id": "billing", "method": "_x.ai/billing", "params": {} })
                String("billing") if out is None =>
                  out = Some(
                    match jfield(m, "error") {
                      Null => Ok(jfield(m, "result"))
                      error =>
                        Err(
                          match jfield(error, "message") {
                            String(s) => s
                            _ => error.stringify()
                          },
                        )
                    },
                  )
                _ => ()
              }
            Err(_) => ()
          }
        }
      }
      Err(b) => {
        let t = stderr.val + @utf8.decode_lossy(b)
        stderr.val = if t.length() > 2000 { t[t.length() - 2000:].to_owned() } else { t }
      }
      Exit(code, _) => {
        let said = stderr.val.trim().to_owned()
        let tail = if said.length() > 300 { said[said.length() - 300:].to_owned() } else { said }
        out = Some(
          Err(
            if late.val {
              "grok did not say its billing in time"
            } else {
              "grok exited (\{match code { Some(c) => c.to_string(); None => "null" }})\{if tail == "" { "" } else { ": " + tail }}"
            },
          ),
        )
      }
    }
  }
  killer.interrupt()
  ignore(kill(proc.pid, "SIGKILL"))
  match out {
    Some(Ok(v)) => v
    Some(Err(m)) => raise P53Error(m)
    None => raise P53Error("grok said nothing")
  }
}

///|
/// agy-quota.ts `runAgyUsage`: `agy -p /usage` in the profile's home, its output whole; ended at once where it asks
/// for a sign-in (`authPrompted`), a TimeoutError after 30 s.
async fn p53_agy_run(host : @host.Host, command : String, env : Array[(String, String)], cwd : String) -> Json {
  let program = if command.contains("/") || command.contains("\\") {
    command
  } else {
    find_command(command, env).unwrap_or(command)
  }
  let null_device = if is_windows() { "\\\\.\\nul" } else { "/dev/null" }
  let proc = spawn(host, program, ["--log-file", null_device, "-p", "/usage", "--output-format", "json"], env~, cwd~, stdout=Piped, stderr=Piped) catch {
    _ => raise P53Error("\{command} did not start")
  }
  let late = Ref(false)
  let killer = host.rt.fork(name="agy /usage, its deadline", async fn() {
    @effect.sleep(30000) // timer: a deadline to a process
    late.val = true
    ignore(kill(proc.pid, "SIGKILL"))
  })
  let stdout = @buffer.Buffer()
  let stderr = Ref("")
  let prompted = (s : String) => s.contains("Authentication required.") || s.contains("Waiting for authentication")
  let mut ended : Int?? = None
  while ended is None {
    match proc.events.take() {
      Out(b) => {
        stdout.write_bytes(b)
        if prompted(@utf8.decode_lossy(stdout.to_bytes())) {
          ignore(kill(proc.pid, "SIGKILL"))
          ended = Some(Some(1))
        }
      }
      Err(b) => {
        let t = stderr.val + @utf8.decode_lossy(b)
        stderr.val = if t.length() > 4000 { t[t.length() - 4000:].to_owned() } else { t }
        if prompted(stderr.val) {
          ignore(kill(proc.pid, "SIGKILL"))
          ended = Some(Some(1))
        }
      }
      Exit(c, _) => ended = Some(c)
    }
  }
  let code = ended.unwrap()
  killer.interrupt()
  let out = @utf8.decode_lossy(stdout.to_bytes())
  let auth = prompted(out) || prompted(stderr.val)
  if late.val && !auth {
    raise @accounts_pool.Thrown("TimeoutError", @accounts_pool.jobj([("message", @accounts_pool.js("agy /usage timed out"))]))
  }
  {
    "code": match code {
      Some(c) => Json::number(c.to_double())
      None => Json::null()
    },
    "stdout": Json::string(out),
    "stderr": Json::string(stderr.val),
    "authPrompted": Json::boolean(auth),
  }
}

///|
/// An environment as the accounts give it (an object of its variables, what is not a string left out).
fn p53_env_pairs(j : Json) -> Array[(String, String)] {
  match j {
    Object(m) => m.to_array().filter_map(kv => if kv.1 is String(v) { Some((kv.0, v)) } else { None })
    _ => []
  }
}

///|
/// What the accounts ask of the machine (see the top of this file); None where `name` is none of it.
async fn P53Accounts::machine_answer(self : P53Accounts, name : String, args : Array[@accounts_pool.JV]) -> @accounts_pool.JV? {
  let host = self.bus.host
  let j = (i : Int) => p53_arg(args, i)
  let opt = (i : Int) => as_text(j(i))
  match name {
    "oauth.claudeOAuthToken" => {
      // [home, rejected, endpoint, lang, margin, lent, claudeVersion]
      let margin = match j(4) {
        Number(n, ..) => n.to_int64()
        _ => 300_000L
      }
      let claude_version = opt(6)
      let (token, expires) = if j(5) is True {
        self.claude_auth.token(p53_station_env(), opt(0), opt(1), p53_arg_s(args, 2), p53_arg_s(args, 3), margin~, bound=p53_lend_bound(host), claude_version?)
      } else {
        self.claude_auth.token(p53_station_env(), opt(0), opt(1), p53_arg_s(args, 2), p53_arg_s(args, 3), margin~, claude_version?)
      }
      Some(to_jv(Json::array([Json::string(token), Json::number(expires.to_double())])))
    }
    "machine.codexAuthFile" => {
      let fields = @agent_runtimes.Fields::new()
      for kv in env_all() {
        fields.set(kv.0, @jsjson.JValue::Str(kv.1))
      }
      Some(Str(@agent_runtimes.codex_auth_file(fields, windows=is_windows())))
    }
    "shell.withShellCommand" => {
      // [command, env, lookup]
      let env = p53_env_pairs(j(1))
      let lookup = match j(2) {
        Object(_) as l => p53_env_pairs(l)
        _ => env
      }
      let found = with_shell_command(host, p53_arg_s(args, 0), env, lookup~)
      Some(to_jv(Json::object(Map::from_array(found.map(kv => (kv.0, Json::string(kv.1)))))))
    }
    "grok.billing" => Some(to_jv(p53_grok_billing(host, p53_env_pairs(j(0)))))
    "agy.run" => Some(to_jv(p53_agy_run(host, p53_arg_s(args, 0), p53_env_pairs(j(1)), p53_arg_s(args, 2))))
    // (accounts/index.ts `check`: profiles.ts `checkProfile`, with the station's environment, the machine's Claude
    // login, the providers', Cursor's and Antigravity CLI's own reading)
    "profiles.checkProfile" => Some(to_jv(self.check_profile(j(0), p53_arg_s(args, 1))))
    "agy.company" => Some(Bool(@agent_drivers.agy_company(p53_arg_s(args, 0))))
    // (the agents' side's: Antigravity CLI's driver takes a login back from the keychain, a running app-server says its
    // rate limits)
    "agy.takeBack" | "codex.rateLimits" => Some(to_jv((self.bus.hub_ask.val)(name, Json::array(args.map(p53_json)))))
    // ── what accounts/index.ts calls of the modules beside it ──
    // (profiles.ts `loginCommand`: the command a subscription's sign-in runs)
    "profiles.loginCommand" =>
      Some(Str(@accounts_oauth.login_command(p53_arg_s(args, 0), p53_arg_s(args, 1), machine=j(2) is True)))
    // (machine.ts `codexClaimsIn`, `codexAccountIdentity`: who a Codex sign-in is)
    "codex.claimsIn" =>
      Some(
        match @accounts_oauth.codex_claims_in(p53_arg_s(args, 0)) {
          Some(c) => to_jv(c)
          None => Null
        },
      )
    "codex.accountIdentity" => Some(p53_codex_account_identity(host, p53_arg_s(args, 0)))
    // (models.ts `uncheckOutdated`: the config given changed as it says, with what it changed)
    "models.uncheckOutdated" => {
      let raw = j(0)
      let found = j(1)
      let done = match j(2) {
        Array(xs) => xs.filter_map(x => if x is String(t) { Some(t) } else { None })
        _ => []
      }
      let (changes, unchecked) = @accounts_oauth.uncheck_outdated(raw, id => match found {
        Object(m) =>
          match m.get(id) {
            Some(Array(xs)) => Some(xs.filter_map(x => if x is String(t) { Some(t) } else { None }))
            _ => None
          }
        _ => None
      }, done)
      Some(
        to_jv({
          "raw": raw,
          "changes": Json::array(changes.map(c => c.to_json())),
          "unchecked": Json::array(unchecked.map(Json::string)),
        }),
      )
    }
    // (sessions/archive-policy.ts `policyFrom`)
    "policy.policyFrom" =>
      Some(
        to_jv(
          @session_storage.policy_from(
            match j(0) {
              Null => None
              saved => Some(saved)
            },
          ).to_json(),
        ),
      )
    // (agy.ts `agyPlan`, `classifyFailure`)
    "agy.plan" =>
      Some(
        match @agent_drivers.agy_plan(args.get(0)) {
          Some(p) => Str(p)
          None => Null
        },
      )
    "agy.classifyFailure" => Some(Str(@agent_drivers.agy_classify_failure(p53_arg_s(args, 0))))
    // (ops/model-name.ts `modelName`)
    "modelName" => Some(Str(@ops_platform.model_name(p53_arg_s(args, 0))))
    // (agents.ts: `claudeVersion`, the machine's Claude Code as the updates found it)
    "claudeVersion" => Some(to_jv(self.bus.coord_updates_version("claude")))
    // (agents.ts: what the overview shows of the accounts changed, told the event streams: `onChange`)
    "changed" => {
      (self.bus.overview_soon.val)()
      Some(Null)
    }
    _ => None
  }
}

///|
/// A provider's source (agents/providers.ts `Source`) as JSON, and back.
fn p53_source_json(s : @agent_runtimes.Source) -> Json {
  let m : Map[String, Json] = {
    "id": Json::string(s.id),
    "name": Json::string(s.name),
    "endpointRequired": Json::boolean(s.endpoint_required),
    "protocols": Json::array(s.protocols.map(x => Json::string(x))),
    "keyOptional": Json::boolean(s.key_optional),
    "auth": Json::string(s.auth),
    "sessionHeader": Json::boolean(s.session_header),
  }
  for kv in [("chat", s.chat), ("responses", s.responses), ("anthropic", s.anthropic), ("decision", s.decision)] {
    if kv.1 is Some(u) { m[kv.0] = Json::string(u) }
  }
  Json::object(m)
}

///|
fn p53_source_of(j : Json) -> @agent_runtimes.Source {
  let s = (k : String) => as_text(jfield(j, k))
  {
    id: s("id").unwrap_or(""),
    name: s("name").unwrap_or(""),
    chat: s("chat"),
    responses: s("responses"),
    anthropic: s("anthropic"),
    decision: s("decision"),
    endpoint_required: jfield(j, "endpointRequired") is True,
    protocols: match jfield(j, "protocols") {
      Array(xs) => xs.filter_map(x => if x is String(t) { Some(t) } else { None })
      _ => []
    },
    key_optional: jfield(j, "keyOptional") is True,
    auth: s("auth").unwrap_or(""),
    session_header: jfield(j, "sessionHeader") is True,
  }
}

///|
/// profiles.ts `checkProfile`: whether a profile works (its models, what it can decide with), as accounts/index.ts asks
/// it of a request (`{runtime, kind, key, via, home, machine, login}`).
async fn P53Accounts::check_profile(self : P53Accounts, request : Json, lang : String) -> Json {
  // (a service profile's adapter: colab.ts's `check`)
  if jtext(request, "kind") == Some("service") {
    return match jtext(request, "service") {
      Some("colab") =>
        p53_json(@accounts_pool.colab_check(self.ctx, jtext_or_empty(request, "home"), lang, p5_epoch_ms().to_double()))
      _ =>
        Json::object({
          "state": Json::string("failed"),
          "detail": Json::string(self.ctx.tr(lang, "station.profile.unknownProvider")),
          "models": Json::null(),
          "checkedAt": Json::number(0.0),
        })
    }
  }
  let host = self.bus.host
  let mac = platform() == "darwin"
  let cursor : @accounts_pool.CursorUrls = { website: "https://cursor.com", backend: "https://api2.cursor.sh", api: "https://api.cursor.com" }
  let pool_io = self.ctx.io
  let bus = self.bus
  let deps : @accounts_oauth.ProfileDeps = {
    commands: @accounts_oauth.commands_on(host, posix=!is_windows()),
    find: id => @agent_runtimes.find(id).map(p53_source_json),
    endpoints: (src, endpoint, protocol) => @agent_runtimes.endpoints(p53_source_of(src), endpoint, protocol).map(e => of_jv(e.json())),
    profile_runtimes: (access, runtime) => {
      let m = match access {
        Object(o) => o.copy()
        _ => {}
      }
      match runtime {
        Some(String(_) as r) => m["runtime"] = r
        _ => ()
      }
      @agent_runtimes.profile_runtimes(to_jv(Json::object(m)))
    },
    take_back: async fn(home) { @agent_runtimes.take_back(host, home, mac) },
    file_credentials: async fn(env) {
      if mac {
        let dir = @agent_runtimes.stub_dir_soon(host, tmpdir(), @drive.uid(), "\{@drive.pid()}.\{@drive.random_uuid()}")
        env["PATH"] = "\{dir}:\{env.get("PATH").unwrap_or(env_get("PATH").unwrap_or(""))}"
      }
    },
    link_codex_auth: async fn(home, env) {
      let fields = @agent_runtimes.Fields::new()
      for k, v in env {
        fields.set(k, @jsjson.JValue::Str(v))
      }
      @agent_runtimes.link_codex_auth_soon(host, home, fields) catch {
        _ => ()
      }
    },
    parse_claude_credentials: text => @agent_runtimes.parse_claude_credentials(text).map(m => {
      let o : Map[String, Json] = {}
      if m.subscription_type is Some(s) { o["subscriptionType"] = Json::string(s) }
      if m.rate_limit_tier is Some(s) { o["rateLimitTier"] = Json::string(s) }
      Json::object(o)
    }),
    read_cursor: async fn(home) {
      @accounts_pool.read_cursor(pool_io, home).map(l => p53_json(l.to_jv()))
    },
    cursor_me: async fn(key) {
      match p53_json(@accounts_pool.cursor_me(pool_io, cursor, key)) {
        Null => None
        Object(m) if m.contains("$undef") => None
        v => Some(v)
      }
    },
    cursor_models: async fn(key) {
      match @accounts_pool.cursor_models(pool_io, cursor, key) {
        Some(ms) => Json::array(ms.map(x => Json::string(x)))
        None => Json::null()
      }
    },
    devin_catalog: j => of_jv(@agent_runtimes.devin_catalog(Some(to_jv(j)))),
    agy_take_back: async fn(home) {
      let back = bus.hub_agy_take_back(home) catch { _ => Json::boolean(false) }
      back is True
    },
    note_agy_email: async fn(home, text) {
      let noted = bus.hub_agy_note_email(home, text) catch {
        _ => Json::null()
      }
      as_text(noted)
    },
    agy_token_ready: (text, enterprise) => @agent_drivers.agy_token_ready(text, enterprise),
    agy_plan_in: text => @agent_drivers.agy_plan_in(text),
    uuid: () => @drive.random_uuid(),
  }
  let via = jfield(request, "via")
  let env = p53_station_env()
  let options : @accounts_oauth.CheckOptions = {
    runtime: jtext_or_empty(request, "runtime"),
    kind: jtext_or_empty(request, "kind"),
    key: jtext_or_empty(request, "key"),
    provider: jtext(via, "provider"),
    endpoint: jtext(via, "endpoint"),
    protocol: jtext(via, "protocol"),
    home: jtext_or_empty(request, "home"),
    env,
    machine: jfield(request, "machine") is True,
    login: jfield(request, "login") is True,
    recheck: jfield(request, "recheck") is True,
    claude_version: match jtext(request, "claudeVersion") {
      Some(_) as v => v
      None => as_text(self.bus.coord_updates_version("claude"))
    },
    machine_token: Some(async fn(e) {
      let fields = @agent_runtimes.Fields::new()
      for k, v in e {
        fields.set(k, @jsjson.JValue::Str(v))
      }
      match @agent_runtimes.machine_claude_token(host, fields, mac, wall_ms().to_double()) {
        Ok(t) => t.token
        Err(why) => raise P53Error(why)
      }
    }),
    urls: Some({
      opencode: @agent_runtimes.opencode,
      anthropic: p53_anthropic_api_url(),
      chatgpt: "https://chatgpt.com",
      claude_token: "https://platform.claude.com/v1/oauth/token",
      console: @accounts_oauth.console_url,
    }),
    lang,
  }
  let words : @accounts_oauth.Words = { tr: (l, key, a) => self.ctx.words.tr(l, key, args=a) }
  @accounts_oauth.check_profile(self.oauth_io, deps, self.claude_auth, words, options)
}

///|
/// machine.ts `codexAccountIdentity`: the account and the user a Codex home's sign-in is of (`["<account>","<user>"]` as
/// JSON text), null where its auth.json is not there, unreadable or names either not.
async fn p53_codex_account_identity(host : @host.Host, home : String) -> @accounts_pool.JV {
  guard shell_read_text(host, @nodepath.join(sep(), [home, "auth.json"])) is Some(text) else { return Null }
  let id = match (try { Ok(@json.parse(text)) } catch { e => Err(e) }) {
    Ok(auth) =>
      match jfield(jfield(auth, "tokens"), "account_id") {
        String(t) if t.trim().to_string() != "" => Some(t)
        _ => None
      }
    Err(_) => None
  }
  let user = match @accounts_oauth.codex_claims_in(text) {
    Some(c) =>
      match jfield(c, "sub") {
        String(t) if t.trim().to_string() != "" => Some(t)
        _ => None
      }
    None => None
  }
  match (id, user) {
    (Some(i), Some(u)) => Str(Json::array([Json::string(i), Json::string(u)]).stringify())
    _ => Null
  }
}

// ── the sign-ins and the machine's logins (accounts/index.ts `logins`, `machine`: login.ts, machine.ts) ──

///|
/// An environment as agent_runtimes reads one.
fn p53_fields(env : Map[String, String]) -> @agent_runtimes.Fields {
  let fields = @agent_runtimes.Fields::new()
  for k, v in env {
    fields.set(k, @jsjson.JValue::Str(v))
  }
  fields
}

///|
/// What agent_runtimes made of an environment, its variables (what is not a string left out).
fn p53_fields_env(fields : @agent_runtimes.Fields) -> Map[String, String] {
  let out : Map[String, String] = Map([])
  match fields.json() {
    Obj(kvs) =>
      for kv in kvs {
        if kv.1 is Str(v) {
          out[@jsjson.sanitize_str(kv.0)] = @jsjson.sanitize_str(v)
        }
      }
    _ => ()
  }
  out
}

///|
/// What the accounts say a profile's sign-in as (its JSON as login.ts's `LoginJob`).
fn p53_job(job : @accounts_oauth.LoginJob?) -> Json {
  match job {
    Some(j) => j.to_json()
    None => Json::null()
  }
}

///|
/// The sign-ins' manager (login.ts `LoginManager`, as accounts/index.ts makes it): the runtimes' own login commands run
/// as children of this process (a pseudo-terminal's where a command needs one, `script` as the platform's
/// `terminalSoon`), the Console's and Kimi's device grants and Cursor's sign-in followed here.
fn p53_login_manager(
  bus : LiveBus,
  words : @accounts_oauth.Words,
  oauth_io : @accounts_oauth.Io,
  pool_io : @accounts_pool.Io,
) -> @accounts_oauth.LoginManager {
  let host = bus.host
  let mac = platform() == "darwin"
  let cursor : @accounts_pool.CursorUrls = { website: "https://cursor.com", backend: "https://api2.cursor.sh", api: "https://api.cursor.com" }
  let kimi_base = @accounts_pool.kimi_auth
  let platform_ : @accounts_oauth.LoginPlatform = {
    terminal: async fn(program, args, cols, rows) {
      bus_pty_terminal(bus, program, args, cols, rows, allow_windows=true, script => (try { Ok(@drive.stat(script)) } catch { e => Err(e) }) is Ok(_))
    },
    prepend_path: env_prepend_path,
    // (a command named bare is found on the environment's PATH: sys.mbt `resolved_program`)
    runnable: async fn(program, args, env) {
      if program.contains("/") || program.contains("\\") {
        (program, args)
      } else {
        (find_command(program, env.to_array()).unwrap_or(program), args)
      }
    },
    make_command: async fn(p, script) {
      @drive.write_private(p, script)
      ignore(host.shell("fs.chmod", { "path": Json::string(p), "mode": Json::number(0o700.to_double()) })) catch {
        _ => ()
      }
      p
    },
    with_shell_command: async fn(program, env, lookup) { env_with_shell_command(host, program, env, lookup=lookup.to_array()) },
    // (no-keychain.ts `fileCredentialsSoon`: a profile's Claude Code keeps its login in its home, not the keychain)
    file_credentials: async fn(env) {
      if mac {
        let dir = @agent_runtimes.stub_dir_soon(host, tmpdir(), @drive.uid(), "\{@drive.pid()}.\{@drive.random_uuid()}")
        env["PATH"] = "\{dir}:\{env.get("PATH").unwrap_or(env_get("PATH").unwrap_or(""))}"
      }
    },
    spawn: async fn(program, args, cwd, env, events) {
      let open_in = Ref(true)
      let ended = Ref(false)
      let child = p54_spawn(
        host,
        program,
        args,
        env=env.to_array(),
        cwd~,
        group=true,
        out=b => (events.output)(@utf8.decode_lossy(b)),
        err=b => (events.output)(@utf8.decode_lossy(b)),
        close=(code, signal) => {
          ended.val = true
          (events.close)(code, signal)
        },
      ) catch {
        e => raise P53Error("\{program} did not start: \{p53_words(e)}")
      }
      let pid = child.proc.pid
      {
        pid: Some(pid),
        writable: () => open_in.val && !ended.val,
        write: async fn(text) { ignore(child.proc.write(@utf8.encode(text))) },
        send: text => ignore(child.proc.write(@utf8.encode(text))),
        kill: () => ignore(kill(pid, "SIGTERM", group=true)),
      }
    },
    descendants: async fn(pid) { process_descendants(host, pid) },
    kill: pid => ignore(kill(pid, "SIGTERM")),
  }
  let deps : @accounts_oauth.LoginDeps = {
    platform: platform_,
    // (runtime.ts `cleanEnv`: the station's environment without what is the station's own)
    env: () => p53_fields_env(@agent_runtimes.clean_env(p53_fields(p53_station_env()), [])),
    // (kimi.ts: the device it signed in on before, or a new one)
    kimi: async fn(home) {
      let device_id = match @accounts_pool.read_kimi(pool_io, home) {
        Some(l) => l.device_id
        None => @accounts_pool.new_device_id(pool_io)
      }
      {
        start: async fn() {
          let d = p53_json(@accounts_pool.start_kimi_device(pool_io, kimi_base, device_id))
          {
            device_code: jtext_or_empty(d, "deviceCode"),
            user_code: jtext_or_empty(d, "userCode"),
            url: jtext_or_empty(d, "url"),
            expires_in_ms: jnum_of(d, "expiresInMs").unwrap_or(600000.0),
            interval_ms: jnum_of(d, "intervalMs").unwrap_or(5000.0),
          }
        },
        ask: async fn(code) {
          let a = p53_json(@accounts_pool.kimi_device_token(pool_io, kimi_base, code, device_id))
          match jfield(a, "token") {
            Object(_) as t =>
              Signed({
                access: jtext_or_empty(t, "access"),
                refresh: jtext_or_empty(t, "refresh"),
                expires_in_ms: jnum_of(t, "expiresInMs").unwrap_or(0.0),
                org: jtext(t, "org"),
              })
            _ =>
              match jtext(a, "error") {
                Some(e) => Refused(e)
                None => Pending(jfield(a, "slowDown") is True)
              }
          }
        },
        keep: async fn(token) {
          async fn() {
            @accounts_pool.write_kimi(pool_io, home, {
              access: token.access,
              refresh: token.refresh,
              expires_at: wall_ms().to_double() + token.expires_in_ms,
              life_ms: token.expires_in_ms,
              device_id,
            })
          }
        },
      }
    },
    // (cursor.ts `cursorHandshake`: a PKCE verifier, its challenge, and the page that confirms it)
    cursor_handshake: () => {
      let verifier = base64url_encode(@drive.random_bytes(32))
      let challenge = base64url_encode(unhex_lenient(@accounts_pool.sha256_hex(verifier)))
      let uuid = @drive.random_uuid()
      {
        "uuid": Json::string(uuid),
        "verifier": Json::string(verifier),
        "url": Json::string("\{cursor.website}/loginDeepControl?challenge=\{challenge}&uuid=\{uuid}&mode=login&redirectTarget=cli"),
      }
    },
    poll_cursor: async fn(handshake) {
      match p53_json(@accounts_pool.poll_cursor(pool_io, cursor, to_jv(handshake))) {
        Object(m) as a if !m.contains("pending") => Some(a)
        _ => None
      }
    },
    mint_cursor_key: async fn(access, name) { p53_json(@accounts_pool.mint_cursor_key(pool_io, cursor, access, name)) },
    write_cursor: async fn(home, login) {
      guard @accounts_pool.cursor_in(login.stringify()) is Some(l) else { raise P53Error("Cursor minted no key") }
      @accounts_pool.write_cursor(pool_io, home, l)
    },
    agy_token_ready: (text, enterprise) => @agent_drivers.agy_token_ready(text, enterprise),
    note_agy_email: async fn(home, text) {
      ignore(bus.hub_agy_note_email(home, text)) catch {
        _ => ()
      }
    },
    // (command-output.ts `loopbackOf`: a page that comes back to this machine's own port)
    loopback_of: url => {
      let rest = if url.has_prefix("http://") { url[7:].to_owned() } else { return false }
      rest.has_prefix("localhost:") || rest.has_prefix("127.0.0.1:") || rest.has_prefix("[::1]:")
    },
    key_name: () => "still.fail · \{hostname()}",
  }
  let logins = @accounts_oauth.LoginManager::new(oauth_io, deps, words, bus.data)
  // (Accounts `login_state_file`, as this has to say it at once: a profile config.json keeps, in its home, none for a
  // machine's or a borrowed one; else the home of its sign-in under way)
  logins.set_state_file(id => {
    for p in jitems(jfield((bus.config_raw.val)(), "profiles")) {
      if jtext(p, "id") != Some(id) {
        continue
      }
      let profile = @accounts_pool.profile_of(to_jv(p), bus.data, _ => None)
      return if profile.machine || @accounts_pool.borrowed(profile.raw) {
        None
      } else {
        Some(@accounts_pool.join_path([profile.home, @accounts_oauth.login_browser_file]))
      }
    }
    logins.job_state_file(id)
  })
  logins
}

///|
/// The machine's own logins (machine.ts `MachineLogins`): `claude auth status` and `codex login status` read, with
/// what each login's allowance is (quota.ts `machineUsage`).
fn p53_machine_logins(
  bus : LiveBus,
  words : @accounts_oauth.Words,
  oauth_io : @accounts_oauth.Io,
  ctx : @accounts_pool.Ctx,
) -> @accounts_oauth.MachineLogins {
  let host = bus.host
  let mac = platform() == "darwin"
  let deps : @accounts_oauth.MachineDeps = {
    commands: @accounts_oauth.commands_on(host, posix=!is_windows()),
    claude_credentials: async fn(env) {
      match @agent_runtimes.read_claude_credentials(host, p53_fields(env), mac) {
        Some(t) => Some(of_jv(t.json()))
        None => None
      }
    },
    codex_home: env => @agent_runtimes.codex_home(p53_fields(env), windows=is_windows()),
    usage: Some(async fn(runtime, _env) {
      let claude_version = as_text(bus.coord_updates_version("claude"))
      match @accounts_pool.machine_usage(ctx, runtime, (bus.lang.val)(), claude_version?) {
        Some(q) => p53_json(q)
        None => Json::null()
      }
    }),
  }
  @accounts_oauth.MachineLogins::new(oauth_io, deps, words, p53_station_env(), () => (bus.lang.val)())
}

///|
/// What the accounts ask of the sign-ins and the machine's logins (`logins.*`, `console.*`, `machine.*`), as
/// accounts/index.ts calls `this.logins`, console.ts and `this.machine`; None where `name` is none of it.
async fn P53Accounts::sign_in_answer(self : P53Accounts, name : String, args : Array[Json]) -> Json? {
  let at = (i : Int) => if i < args.length() { args[i] } else { Json::null() }
  let s = (i : Int) => as_text(at(i)).unwrap_or("")
  let lang = (i : Int) => match at(i) {
    String(l) => l
    _ => (self.bus.lang.val)()
  }
  let logins = self.logins
  match name {
    "logins.start" => {
      let p = at(0)
      let profile : @accounts_oauth.LoginProfile = {
        id: jtext_or_empty(p, "id"),
        runtime: jtext_or_empty(p, "runtime"),
        home: jtext_or_empty(p, "home"),
        email: jtext(p, "email"),
        enterprise: jfield(p, "enterprise") is True,
      }
      Some(logins.start(profile, lang(1)).to_json())
    }
    "logins.startConsole" => Some(logins.start_console(jtext_or_empty(at(0), "id"), jtext_or_empty(at(0), "home"), lang(1)).to_json())
    "logins.startKimi" => Some(logins.start_kimi(jtext_or_empty(at(0), "id"), jtext_or_empty(at(0), "home"), lang(1)).to_json())
    "logins.startCursor" => Some(logins.start_cursor(jtext_or_empty(at(0), "id"), jtext_or_empty(at(0), "home"), lang(1)).to_json())
    "logins.startService" => Some(self.start_service(at(0), lang(1)).to_json())
    "logins.get" => Some(p53_job(logins.get(s(0))))
    "logins.cancel" => {
      logins.cancel(s(0))
      Some(Json::null())
    }
    "logins.close" => {
      logins.stop_all()
      Some(Json::null())
    }
    "logins.submitCode" => Some(logins.submit_code(s(0), s(1), lang(2)).to_json())
    "logins.openPage" => Some(Json::string(logins.open_page(s(0), lang(1))))
    // (console.ts: an OpenCode Console sign-in kept in the profile's home, renewed)
    "console.read" =>
      Some(
        match @accounts_oauth.read_console(self.oauth_io, s(0)) {
          Some(l) => l.to_json()
          None => Json::null()
        },
      )
    "console.write" => {
      guard @accounts_oauth.console_in(at(1).stringify()) is Some(l) else {
        raise P53Error("not an OpenCode Console sign-in")
      }
      @accounts_oauth.write_console(self.oauth_io, s(0), l)
      Some(Json::null())
    }
    "console.renew" =>
      Some(@accounts_oauth.renew_token(self.oauth_io, s(0), s(1)).to_json())
    "console.in" =>
      Some(
        match @accounts_oauth.console_in(s(0)) {
          Some(l) => l.to_json()
          None => Json::null()
        },
      )
    // (machine.ts: the machine's own logins; none where the station keeps none, a rig's)
    "machine.get" =>
      Some(
        match self.machine {
          Some(m) => Json::array(m.get().map(l => l.to_json()))
          None => Json::array([])
        },
      )
    "machine.refresh" => {
      if self.machine is Some(m) { m.refresh() }
      Some(Json::null())
    }
    "machine.linkCodexAuth" => {
      @agent_runtimes.link_codex_auth_soon(self.bus.host, s(0), p53_fields(p53_station_env())) catch {
        _ => ()
      }
      Some(Json::null())
    }
    _ => None
  }
}

///|
/// A service profile's sign-in (services.ts's adapters' `login`): Google Colab's OAuth code, with PKCE.
async fn P53Accounts::start_service(self : P53Accounts, p : Json, lang : String) -> @accounts_oauth.LoginJob {
  let service = jtext_or_empty(p, "service")
  guard service == "colab" else { raise P53Error("unknown service \{service}") }
  let ctx = self.ctx
  let home = jtext_or_empty(p, "home")
  let pkce = @accounts_pool.colab_pkce(n => @drive.random_bytes(n))
  let flow : @accounts_oauth.OAuthCode = {
    url: @accounts_pool.colab_authorize_url(@accounts_pool.colab_urls(ctx), pkce, jtext(p, "email")),
    validate: (raw, l) => match @accounts_pool.colab_code_of(ctx.words, raw, pkce.state, l) {
      Ok(code) => code
      Err(why) => raise @accounts_oauth.Failed(why)
    },
    exchange: async fn(code, l) {
      let auth = @accounts_pool.exchange_colab_code(ctx, code, pkce.verifier, l, p5_epoch_ms().to_double()) catch {
        e => raise @accounts_oauth.Failed(@accounts_pool.message_of(e))
      }
      @accounts_pool.write_colab_auth(ctx.io, home, auth) catch {
        e => raise @accounts_oauth.Failed(@accounts_pool.message_of(e))
      }
    },
    callback_code: url => @accounts_pool.colab_callback_code(url, pkce.state),
  }
  self.logins.start_oauth_code(jtext_or_empty(p, "id"), home, service, flow, lang)
}
