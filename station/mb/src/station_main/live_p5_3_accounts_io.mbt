// What the accounts ask of the machine past their files (accounts/oauth.ts `claudeOAuthToken`, quota.ts `grokBilling`,
// agy-quota.ts `runAgyUsage`, ops/shell-path.ts `withShellCommand`, machine-logins.ts `codexAuthFile`), as this program
// does it: Claude's logins renewed through accounts_oauth's ClaudeAuth over the machine's keychain and files, the CLIs
// run as children of this process. What only the agents' side has (a running app-server's rate limits, Antigravity
// CLI's login taken back from the keychain) is asked of it on the bus.

///|
/// How long a lend waits for its login's renewal (accounts/index.ts `lendBound`): LEND_BOUND_MS on the wall's clock.
fn p53_lend_bound(host : @host.Host) -> @accounts_oauth.Bound {
  {
    ms: @accounts_oauth.lend_bound_ms,
    after: (ms, f) => {
      let fiber = host.rt.fork(name="a lend's bound", async fn() {
        @effect.sleep(ms.to_int()) // timer: a deadline (how long a lend waits for its login's renewal)
        f()
      })
      () => fiber.interrupt()
    },
  }
}

///|
/// A child run to its end with `input` on its stdin, given `ms` at most: (its code, its signal, stdout); None where it
/// did not start, `timed_out` set where it was killed at its deadline.
async fn p53_run_with_input(
  host : @host.Host,
  program : String,
  args : Array[String],
  env? : Array[(String, String)],
  cwd? : String,
  input? : String,
  ms~ : Int,
  timed_out~ : Ref[Bool],
) -> (Int?, String?, String, String)? {
  let proc = spawn(host, program, args, env?, cwd?, stdin_piped=input is Some(_), stdout=Piped, stderr=Piped) catch {
    _ => return None
  }
  match input {
    Some(t) => {
      ignore(proc.write(@utf8.encode(t)))
      proc.end_input()
    }
    None => ()
  }
  let killer = host.rt.fork(name="a child's deadline", async fn() {
    @effect.sleep(ms) // timer: a deadline to a process
    timed_out.val = true
    ignore(kill(proc.pid, "SIGKILL"))
  })
  let (code, signal, out, err) = proc.finished()
  killer.interrupt()
  Some((code, signal, @utf8.decode_lossy(out), @utf8.decode_lossy(err)))
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
      match p53_run_with_input(host, "/usr/bin/id", ["-un"], ms=10000, timed_out=Ref(false)) {
        Some((code, _, out, _)) => Some((code == Some(0), out))
        None => None
      }
    },
    security: async fn(env, input, ms) {
      let late = Ref(false)
      match p53_run_with_input(host, "/usr/bin/security", ["-i"], env=env.to_array(), input~, ms~, timed_out=late) {
        None => SecurityUnstarted
        Some(_) if late.val => SecurityTimedOut
        Some((code, _, _, _)) => SecurityExited(code)
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
  let opt = (i : Int) => match j(i) {
    String(s) => Some(s)
    _ => None
  }
  match name {
    "oauth.claudeOAuthToken" => {
      // [home, rejected, endpoint, lang, margin, lent]
      let margin = match j(4) {
        Number(n, ..) => n.to_int64()
        _ => 300_000L
      }
      let (token, expires) = if j(5) is True {
        self.claude_auth.token(p53_station_env(), opt(0), opt(1), p53_arg_s(args, 2), p53_arg_s(args, 3), margin~, bound=p53_lend_bound(host))
      } else {
        self.claude_auth.token(p53_station_env(), opt(0), opt(1), p53_arg_s(args, 2), p53_arg_s(args, 3), margin~)
      }
      Some(@jsjson.JV::of_json(Json::array([Json::string(token), Json::number(expires.to_double())])))
    }
    "machine.codexAuthFile" => {
      let fields = @agent_runtimes.Fields::new()
      for kv in env_all() {
        fields.set(kv.0, @jsjson.JValue::Str(@jsjson.units(kv.1)))
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
      Some(@jsjson.JV::of_json(Json::object(Map::from_array(found.map(kv => (kv.0, Json::string(kv.1)))))))
    }
    "grok.billing" => Some(@jsjson.JV::of_json(p53_grok_billing(host, p53_env_pairs(j(0)))))
    "agy.run" => Some(@jsjson.JV::of_json(p53_agy_run(host, p53_arg_s(args, 0), p53_env_pairs(j(1)), p53_arg_s(args, 2))))
    // (accounts/index.ts `check`: profiles.ts `checkProfile`, with the station's environment, the machine's Claude
    // login, the providers', Cursor's and Antigravity CLI's own reading)
    "profiles.checkProfile" => Some(@jsjson.JV::of_json(self.check_profile(j(0), p53_arg_s(args, 1))))
    "agy.company" => Some(Bool(@agent_drivers.agy_company(p53_arg_s(args, 0))))
    // (the agents' side's: Antigravity CLI's driver takes a login back from the keychain, a running app-server says its
    // rate limits)
    "agy.takeBack" | "codex.rateLimits" => Some(@jsjson.JV::of_json((self.bus.hub_ask.val)(name, Json::array(args.map(p53_json)))))
    // ── what accounts/index.ts calls of the modules beside it ──
    // (profiles.ts `loginCommand`: the command a subscription's sign-in runs)
    "profiles.loginCommand" =>
      Some(Str(@accounts_oauth.login_command(p53_arg_s(args, 0), p53_arg_s(args, 1), machine=j(2) is True)))
    // (machine.ts `codexClaimsIn`, `codexAccountIdentity`: who a Codex sign-in is)
    "codex.claimsIn" =>
      Some(
        match @accounts_oauth.codex_claims_in(p53_arg_s(args, 0)) {
          Some(c) => @jsjson.JV::of_json(c)
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
        @jsjson.JV::of_json({
          "raw": raw,
          "changes": Json::array(changes.map(c => c.to_json())),
          "unchecked": Json::array(unchecked.map(Json::string)),
        }),
      )
    }
    // (sessions/archive-policy.ts `policyFrom`)
    "policy.policyFrom" =>
      Some(
        @jsjson.JV::of_json(
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
        match @agent_drivers.agy_plan(opt(0), company=j(1) is True) {
          Some(p) => Str(p)
          None => Null
        },
      )
    "agy.classifyFailure" => Some(Str(@agent_drivers.agy_classify_failure(p53_arg_s(args, 0))))
    // (ops/model-name.ts `modelName`)
    "modelName" => Some(Str(@ops_platform.model_name(p53_arg_s(args, 0))))
    // (agents.ts: `claudeVersion`, the machine's Claude Code as the updates found it)
    "claudeVersion" => Some(@jsjson.JV::of_json((self.bus.coord_ask.val)("updates.version", Json::array([Json::string("claude")]))))
    // (agents.ts: what the overview shows of the accounts changed, told the event streams: `onChange`)
    "changed" => {
      (self.bus.overview_changed.val)()
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
    "protocols": Json::array(s.protocols.map(Json::string(_))),
    "keyOptional": Json::boolean(s.key_optional),
    "auth": Json::string(s.auth),
    "sessionHeader": Json::boolean(s.session_header),
  }
  for kv in [("chat", s.chat), ("responses", s.responses), ("anthropic", s.anthropic), ("decision", s.decision)] {
    match kv.1 {
      Some(u) => m[kv.0] = Json::string(u)
      None => ()
    }
  }
  Json::object(m)
}

///|
fn p53_source_of(j : Json) -> @agent_runtimes.Source {
  let s = (k : String) => match p53_get(j, k) {
    String(t) => Some(t)
    _ => None
  }
  {
    id: s("id").unwrap_or(""),
    name: s("name").unwrap_or(""),
    chat: s("chat"),
    responses: s("responses"),
    anthropic: s("anthropic"),
    decision: s("decision"),
    endpoint_required: p53_get(j, "endpointRequired") is True,
    protocols: match p53_get(j, "protocols") {
      Array(xs) => xs.filter_map(x => if x is String(t) { Some(t) } else { None })
      _ => []
    },
    key_optional: p53_get(j, "keyOptional") is True,
    auth: s("auth").unwrap_or(""),
    session_header: p53_get(j, "sessionHeader") is True,
  }
}

///|
/// profiles.ts `checkProfile`: whether a profile works (its models, what it can decide with), as accounts/index.ts asks
/// it of a request (`{runtime, kind, key, via, home, machine, login}`).
async fn P53Accounts::check_profile(self : P53Accounts, request : Json, lang : String) -> Json {
  let host = self.bus.host
  let mac = platform() == "darwin"
  let cursor : @accounts_pool.CursorUrls = { website: "https://cursor.com", backend: "https://api2.cursor.sh", api: "https://api.cursor.com" }
  let pool_io = self.ctx.io
  let bus = self.bus
  let deps : @accounts_oauth.ProfileDeps = {
    commands: @accounts_oauth.commands_on(host, posix=!is_windows()),
    find: id => @agent_runtimes.find(id).map(p53_source_json),
    endpoints: (src, endpoint, protocol) => @agent_runtimes.endpoints(p53_source_of(src), endpoint, protocol).map(e => p52_json_of_jv(e.json())),
    profile_runtimes: (access, runtime) => {
      let m = match access {
        Object(o) => o.copy()
        _ => {}
      }
      match runtime {
        Some(String(_) as r) => m["runtime"] = r
        _ => ()
      }
      @agent_runtimes.profile_runtimes(jv_of(Json::object(m)))
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
        fields.set(k, @jsjson.JValue::Str(@jsjson.units(v)))
      }
      @agent_runtimes.link_codex_auth_soon(host, home, fields) catch {
        _ => ()
      }
    },
    parse_claude_credentials: text => @agent_runtimes.parse_claude_credentials(text).map(m => {
      let o : Map[String, Json] = {}
      match m.subscription_type {
        Some(s) => o["subscriptionType"] = Json::string(s)
        None => ()
      }
      match m.rate_limit_tier {
        Some(s) => o["rateLimitTier"] = Json::string(s)
        None => ()
      }
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
        Some(ms) => Json::array(ms.map(Json::string(_)))
        None => Json::null()
      }
    },
    devin_catalog: j => p52_json_of_jv(@agent_runtimes.devin_catalog(Some(jv_of(j)))),
    agy_take_back: async fn(home) {
      let back = (bus.hub_ask.val)("agy.takeBack", Json::array([Json::string(home)])) catch { _ => Json::boolean(false) }
      back is True
    },
    note_agy_email: async fn(home, text) {
      let noted = (bus.hub_ask.val)("agy.noteEmail", { "home": Json::string(home), "text": Json::string(text) }) catch {
        _ => Json::null()
      }
      match noted {
        String(e) => Some(e)
        _ => None
      }
    },
    agy_token_ready: (text, enterprise) => @agent_drivers.agy_token_ready(text, enterprise),
    agy_plan_in: text => @agent_drivers.agy_plan_in(text),
    uuid: () => @drive.random_uuid(),
  }
  let via = p53_get(request, "via")
  let env = p53_station_env()
  let options : @accounts_oauth.CheckOptions = {
    runtime: p53_text(request, "runtime"),
    kind: p53_text(request, "kind"),
    key: p53_text(request, "key"),
    provider: p53_str(via, "provider"),
    endpoint: p53_str(via, "endpoint"),
    protocol: p53_str(via, "protocol"),
    home: p53_text(request, "home"),
    env,
    machine: p53_get(request, "machine") is True,
    login: p53_get(request, "login") is True,
    machine_token: Some(async fn(e) {
      let fields = @agent_runtimes.Fields::new()
      for k, v in e {
        fields.set(k, @jsjson.JValue::Str(@jsjson.units(v)))
      }
      match @agent_runtimes.machine_claude_token(host, fields, mac, wall_ms().to_double()) {
        Ok(t) => t.token
        Err(why) => raise P53Error(why)
      }
    }),
    urls: Some({
      opencode: @agent_runtimes.opencode,
      anthropic: "https://api.anthropic.com",
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
  guard p53_read(host, @nodepath.join(sep(), [home, "auth.json"])) is Some(text) else { return Null }
  let id = match (try { Ok(@json.parse(text)) } catch { e => Err(e) }) {
    Ok(auth) =>
      match p53_get(p53_get(auth, "tokens"), "account_id") {
        String(t) if t.trim().to_string() != "" => Some(t)
        _ => None
      }
    Err(_) => None
  }
  let user = match @accounts_oauth.codex_claims_in(text) {
    Some(c) =>
      match p53_get(c, "sub") {
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
    fields.set(k, @jsjson.JValue::Str(@jsjson.units(v)))
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
          out[@jsjson.text(kv.0)] = @jsjson.text(v)
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
      if is_windows() {
        return None
      }
      let run = "stty cols \{cols} rows \{rows} 2>/dev/null; exec \"$@\""
      if mac {
        // (macOS's script refuses a socket for its stdin: a pipe put between, `cat` feeding it, ended with the command)
        let feed = "exec 3<&0; cat <&3 | { /usr/bin/script -q /dev/null /bin/sh -c '\{run}' sh \"$@\" 3<&-; s=$?; /usr/bin/pkill -P $$ -x cat; exit $s; }"
        return Some(("/bin/sh", ["-c", feed, "sh", program, ..args]))
      }
      for script in ["/usr/bin/script", "/bin/script"] {
        if (try { Ok(@drive.stat(script)) } catch { e => Err(e) }) is Ok(_) {
          let inner = ["/bin/sh", "-c", run, "sh", program, ..args].map(p54_quoted)
          return Some((script, ["-qfec", inner.join(" "), "/dev/null"]))
        }
      }
      None
    },
    prepend_path: (env, dir) => {
      let m = env.copy()
      let sep_ = if is_windows() { ";" } else { ":" }
      m["PATH"] = match env.get("PATH") {
        Some(p) if p != "" => dir + sep_ + p
        _ => dir
      }
      m
    },
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
    with_shell_command: async fn(program, env, lookup) {
      let given = env.to_array()
      let found = with_shell_command(host, program, given, lookup=lookup.to_array())
      if found == given {
        None
      } else {
        Some(Map::from_array(found))
      }
    },
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
    descendants: async fn(pid) {
      let (code, text, _) = p54_run(host, "ps", ["-A", "-o", "pid=,ppid="]) catch { _ => return [] }
      guard code == Some(0) else { return [] }
      let children : Map[Int, Array[Int]] = Map([])
      for line in text.split("\n") {
        let f = line.trim().split(" ").filter(x => x != "").map(x => x.to_owned()).to_array()
        if f.length() >= 2 {
          let c = @string.parse_int(f[0]) catch { _ => continue }
          let p = @string.parse_int(f[1]) catch { _ => continue }
          match children.get(p) {
            Some(a) => a.push(c)
            None => children[p] = [c]
          }
        }
      }
      let out = []
      let next = [pid]
      while next.pop() is Some(p) {
        for c in children.get(p).unwrap_or([]) {
          if !out.contains(c) {
            out.push(c)
            next.push(c)
          }
        }
      }
      out
    },
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
            device_code: p53_text(d, "deviceCode"),
            user_code: p53_text(d, "userCode"),
            url: p53_text(d, "url"),
            expires_in_ms: p53_num(d, "expiresInMs").unwrap_or(600000.0),
            interval_ms: p53_num(d, "intervalMs").unwrap_or(5000.0),
          }
        },
        ask: async fn(code) {
          let a = p53_json(@accounts_pool.kimi_device_token(pool_io, kimi_base, code, device_id))
          match p53_get(a, "token") {
            Object(_) as t =>
              Signed({
                access: p53_text(t, "access"),
                refresh: p53_text(t, "refresh"),
                expires_in_ms: p53_num(t, "expiresInMs").unwrap_or(0.0),
                org: p53_str(t, "org"),
              })
            _ =>
              match p53_str(a, "error") {
                Some(e) => Refused(e)
                None => Pending(p53_get(a, "slowDown") is True)
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
      let verifier = p53_base64url(@drive.random_bytes(32))
      let challenge = p53_base64url(p53_hex_bytes(@accounts_pool.sha256_hex(verifier)))
      let uuid = @drive.random_uuid()
      {
        "uuid": Json::string(uuid),
        "verifier": Json::string(verifier),
        "url": Json::string("\{cursor.website}/loginDeepControl?challenge=\{challenge}&uuid=\{uuid}&mode=login&redirectTarget=cli"),
      }
    },
    poll_cursor: async fn(handshake) {
      match p53_json(@accounts_pool.poll_cursor(pool_io, cursor, @jsjson.JV::of_json(handshake))) {
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
      ignore((bus.hub_ask.val)("agy.noteEmail", { "home": Json::string(home), "text": Json::string(text) })) catch {
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
      let profile = @accounts_pool.profile_of(@jsjson.JV::of_json(p), bus.data, _ => None)
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
fn p53_base64url(b : Bytes) -> String {
  @base64.encode(b).replace_all(old="+", new="-").replace_all(old="/", new="_").replace_all(old="=", new="")
}

///|
fn p53_hex_bytes(hex : String) -> Bytes {
  let out = []
  let digit = (c : Char) => match c {
    '0'..='9' => c.to_int() - '0'.to_int()
    'a'..='f' => c.to_int() - 'a'.to_int() + 10
    'A'..='F' => c.to_int() - 'A'.to_int() + 10
    _ => 0
  }
  let cs = hex.to_array()
  let mut i = 0
  while i + 1 < cs.length() {
    out.push((digit(cs[i]) * 16 + digit(cs[i + 1])).to_byte())
    i += 2
  }
  Bytes::from_array(out)
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
        Some(t) => Some(p52_json_of_jv(t.json()))
        None => None
      }
    },
    codex_home: env => @agent_runtimes.codex_home(p53_fields(env), windows=is_windows()),
    usage: Some(async fn(runtime, _env) {
      match @accounts_pool.machine_usage(ctx, runtime, (bus.lang.val)()) {
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
  let s = (i : Int) => match at(i) {
    String(t) => t
    _ => ""
  }
  let lang = (i : Int) => match at(i) {
    String(l) => l
    _ => (self.bus.lang.val)()
  }
  let logins = self.logins
  match name {
    "logins.start" => {
      let p = at(0)
      let profile : @accounts_oauth.LoginProfile = {
        id: p53_text(p, "id"),
        runtime: p53_text(p, "runtime"),
        home: p53_text(p, "home"),
        email: p53_str(p, "email"),
        enterprise: p53_get(p, "enterprise") is True,
      }
      Some(logins.start(profile, lang(1)).to_json())
    }
    "logins.startConsole" => Some(logins.start_console(p53_text(at(0), "id"), p53_text(at(0), "home"), lang(1)).to_json())
    "logins.startKimi" => Some(logins.start_kimi(p53_text(at(0), "id"), p53_text(at(0), "home"), lang(1)).to_json())
    "logins.startCursor" => Some(logins.start_cursor(p53_text(at(0), "id"), p53_text(at(0), "home"), lang(1)).to_json())
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
      Some(
        @accounts_oauth.renew_token(self.oauth_io, s(0), s(1)).to_json() catch {
          @accounts_oauth.RenewRefused(status, message) =>
            raise @accounts_pool.Thrown(
              "RenewRefused",
              @accounts_pool.jobj([
                ("message", @accounts_pool.js(message)),
                (
                  "status",
                  match status {
                    Some(n) => Num(n.to_double())
                    None => Null
                  },
                ),
              ]),
            )
          e => raise e
        },
      )
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
      match self.machine {
        Some(m) => m.refresh()
        None => ()
      }
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
