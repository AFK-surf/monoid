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
      Some(p53_jv(Json::array([Json::string(token), Json::number(expires.to_double())])))
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
      Some(p53_jv(Json::object(Map::from_array(found.map(kv => (kv.0, Json::string(kv.1)))))))
    }
    "grok.billing" => Some(p53_jv(p53_grok_billing(host, p53_env_pairs(j(0)))))
    "agy.run" => Some(p53_jv(p53_agy_run(host, p53_arg_s(args, 0), p53_env_pairs(j(1)), p53_arg_s(args, 2))))
    // (accounts/index.ts `check`: profiles.ts `checkProfile`, with the station's environment, the machine's Claude
    // login, the providers', Cursor's and Antigravity CLI's own reading)
    "profiles.checkProfile" => Some(p53_jv(self.check_profile(j(0), p53_arg_s(args, 1))))
    "agy.company" => Some(Bool(@agent_drivers.agy_company(p53_arg_s(args, 0))))
    // (the agents' side's: Antigravity CLI's driver takes a login back from the keychain, a running app-server says its
    // rate limits)
    "agy.takeBack" | "codex.rateLimits" => Some(p53_jv((self.bus.hub_ask.val)(name, Json::array(args.map(p53_json)))))
    // ── what accounts/index.ts calls of the modules beside it ──
    // (profiles.ts `loginCommand`: the command a subscription's sign-in runs)
    "profiles.loginCommand" =>
      Some(Str(@accounts_oauth.login_command(p53_arg_s(args, 0), p53_arg_s(args, 1), machine=j(2) is True)))
    // (machine.ts `codexClaimsIn`, `codexAccountIdentity`: who a Codex sign-in is)
    "codex.claimsIn" =>
      Some(
        match @accounts_oauth.codex_claims_in(p53_arg_s(args, 0)) {
          Some(c) => p53_jv(c)
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
        p53_jv({
          "raw": raw,
          "changes": Json::array(changes.map(c => c.to_json())),
          "unchecked": Json::array(unchecked.map(Json::string)),
        }),
      )
    }
    // (sessions/archive-policy.ts `policyFrom`)
    "policy.policyFrom" =>
      Some(
        p53_jv(
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
    "claudeVersion" => Some(p53_jv((self.bus.coord_ask.val)("updates.version", Json::array([Json::string("claude")]))))
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
