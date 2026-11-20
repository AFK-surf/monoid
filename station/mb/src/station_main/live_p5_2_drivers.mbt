// The agents' side (P5-2): the runtimes' drivers (agents.ts's `drivers`: Claude Code, Codex, Antigravity CLI and the
// others), made on the drivers' loop (live_p5_2_io.mbt) with the machine and the processes read by the program
// (live_p5_2_program.mbt), each behind one seam (`Driver`, runtime.ts `AgentDriver`) as the hub and the actors ask it.

///|
/// A runtime's driver as the station holds it (runtime.ts `AgentDriver`).
priv struct Driver {
  kind : String
  open : async (Json, (@jsjson.JValue) -> Unit) -> Agent
  adopt : async (Json, Json?, (@jsjson.JValue) -> Unit) -> Agent
  shutdown : async (Bool) -> Unit
  detach : () -> Unit
  freeze : async () -> Unit
  thaw : () -> Unit
  owned_runners : () -> Array[String]
  evict_idle : async () -> Int
  /// What only this runtime's driver answers (codex.ts `rateLimits`, `renewLogin`; agy.ts `renew`), by name.
  ask : async (String, Json) -> Json
}

///|
fn no_ask(kind : String) -> async (String, Json) -> Json {
  async fn(what, _) { raise LiveError("\{kind}'s driver answers no \{what}") }
}

///|
/// The processes read by the program, by their runner's id: what a driver's `Proc` is here.
let hosted_by_runner : Map[String, HostedProcess] = Map([])

///|
fn hosted_of(proc : @agent_drivers.Proc?) -> HostedProcess? {
  match proc {
    Some(p) => hosted_by_runner.get(p.info.id())
    None => None
  }
}

///|
/// The drivers' words of the station's own (claude.ts's hooks and what a session speaks by): its hooks run by this
/// program where there is no Node (agent_runtimes `hook_node`).
fn driver_words(argv0 : String, app : String) -> @agent_drivers.Words {
  let node = attempt(() => @drive.realpath(argv0)).unwrap_or(argv0)
  // (station-bundle.sh lays the hooks flat in <app>/station/; a checkout's are in station/src/agents/)
  let rules = station_script(app, argv0, "repo-rules-hook.mjs")
  let sub = station_script(app, argv0, "subagent-hook.mjs")
  let os = if is_windows() { "windows" } else { platform() }
  {
    repo_rules_command: @agent_runtimes.hook_command(node, rules, []),
    agy_repo_rules_command: @agent_runtimes.agy_hook_command(node, rules, os),
    subagent_hook_command: @agent_runtimes.hook_command(node, sub, [@mcp_tools.slack_spoken.join(",")]),
    speaks: @mcp_tools.speaks,
    speaks_writing: @mcp_tools.speaks_writing,
  }
}

///|
fn fields_pairs(f : @agent_runtimes.Fields) -> Array[(String, String)] {
  f.keys.filter_map(k => match f.get(k) {
    Some(Str(v)) => Some((k, @jsjson.sanitize_str(v)))
    Some(Num(n)) => Some((k, n.to_string()))
    _ => None
  })
}

///|
/// What a profile says of its runtime's environment and Codex's provider (accounts' `profileEnv`, `codexOverrides`).
fn profile_says() -> @agent_drivers.ProfileSays {
  {
    env: (p, runtime) => fields_pairs(@agent_runtimes.profile_env(p, runtime)),
    codex_overrides: p => @agent_runtimes.codex_overrides(
      @agent_runtimes.access_kind(p),
      @agent_runtimes.profile_model(p),
      @agent_runtimes.profile_via(p),
    ),
  }
}

///|
/// The station's environment for what it starts (ops/agent-env.ts): its own, with config.json's `agentEnv` over it,
/// never the launcher's front (`STATION_INTERNAL`).
fn agent_env(ctx : P52) -> Array[(String, String)] {
  let out = env_all()
  match jfield((ctx.bus.config_raw.val)(), "agentEnv") {
    Object(m) =>
      for kv in m {
        match kv.1 {
          String(v) =>
            match out.search_by(p => p.0 == kv.0) {
              Some(i) => out[i] = (kv.0, v)
              None => out.push((kv.0, v))
            }
          _ => ()
        }
      }
    _ => ()
  }
  out.filter(kv => kv.0 != "STILLFAIL_MESH_FRONT")
}

///|
fn ids_live() -> @agent_drivers.Ids {
  { next: () => @drive.random_uuid() }
}

///|
/// The Agent of a session whose process is an `OwnSession` (Claude Code's, an ACP runtime's, the bridged ones').
fn own_agent(
  pump : Pump,
  own : @agent_drivers.OwnSession,
  prompt : (String) -> @agent_drivers.Later[Unit],
  steer : (String) -> @agent_drivers.Later[Bool],
  abort : () -> @agent_drivers.Later[Unit],
  compact : ((() -> @agent_drivers.Later[Unit]))?,
  retune : (@jsjson.JValue) -> Bool,
  snapshot : () -> @jsjson.JValue,
  background : () -> Json,
  outlived : () -> Bool,
  sign_in_expired? : () -> Bool = () => false,
  lent_expired? : () -> Bool = () => false,
) -> Agent {
  {
    id: () => own.session_id,
    busy: () => own.busy(),
    background,
    mcp_url: () => own.tools_url,
    can_compact: compact is Some(_),
    outlived,
    sign_in_expired,
    lent_expired,
    route: router => match hosted_of(own.proc) {
      Some(p) =>
        match router {
          Some(took) => {
            // (said only as it changes: one taken up with its router was routed as it was attached)
            let was = p.router is Some(_)
            p.router = Some({ took: batch => took(batch, p.n) })
            if !was {
              p.host.post({ "route": ji(p.n), "on": jb(true) })
            }
          }
          None =>
            if p.router is Some(_) {
              p.router = None
              p.host.post({ "route": ji(p.n), "on": jb(false) })
            }
        }
      None => ()
    },
    prompt: text => pump.wait(prompt(text)),
    steer: text => pump.wait(steer(text)),
    abort: () => pump.wait(abort()),
    compact: () => match compact {
      Some(c) => pump.wait(c())
      None => ()
    },
    dispose: () => pump.wait(own.dispose()),
    retune: o => retune(to_jv(o)),
    snapshot: () => of_jv(snapshot()),
    detach: () => own.detach(),
    runtime_version: () => None,
  }
}

///|
/// Claude Code's logins (agents.ts's `ClaudeDriver` options), each asked of the accounts by `ask` (the bus's
/// `jobs_ask`) with the token the session saw refused, `rejected`, which they renew rather than give again.
fn p52_claude_logins(pump : Pump, host : @host.Host, ask : async (String, Json) -> Json) -> @agent_drivers.ClaudeLogins {
  let lp = pump.lp
  let mac = platform() == "darwin"
  let stub : Ref[String?] = Ref(None)
  {
    // (the machine's own login: its credentials file, or the keychain's item, renewed where it ran out; read here only
    // where no accounts part answers, P5-2 alone)
    machine_token: rejected => pump.later("machine's Claude login", async fn() {
      match asked_machine_token(ask, rejected~) {
        Object(t) if t.get("token") is Some(String(tok)) => (tok, p52_expires_at(t))
        Null => {
          let fields = @agent_runtimes.Fields::new()
          for kv in env_all() {
            fields.set(kv.0, @jsjson.JValue::Str(kv.1))
          }
          match @agent_runtimes.machine_claude_token(host, fields, platform() == "darwin", wall_ms().to_double()) {
            Ok(t) => (t.token, t.expires_at)
            Err(why) => raise @agent_drivers.Failed(why)
          }
        }
        _ => raise @agent_drivers.Failed("the machine's Claude login is not there")
      }
    }),
    // (a subscription profile's token: the accounts')
    subscription_token: Some(p => rejected => pump.later("profile's Claude login", async fn() {
      let got = asked_subscription_token(ask, of_jv(p), rejected~)
      match got {
        Object(t) if t.get("token") is Some(String(tok)) => (tok, p52_expires_at(t))
        _ => raise @agent_drivers.Failed("the profile's Claude sign-in is not there (no accounts part answered)")
      }
    })),
    lent_borrowed: Some(p => p52_borrowed(of_jv(p))),
    // (agents.ts `lent.token`: another station's lent, a profile of this station's own the accounts')
    lent_token: Some(p => rejected => pump.later("borrowed Claude login", async fn() {
      let prof = of_jv(p)
      let got = if p52_borrowed(prof) {
        asked_lent_token(ask, prof, rejected~)
      } else {
        asked_subscription_token(ask, prof, rejected~)
      }
      match got {
        Object(t) if t.get("token") is Some(String(tok)) => (tok, p52_expires_at(t))
        _ => raise @agent_drivers.Failed("the lent sign-in is not there")
      }
    })),
    // (claude.ts, no-keychain.ts: on macOS a profile's Claude Code keeps its login in its home's file, not the user's
    // keychain: the keychain's stub put first on its PATH, a login it moved there taken back)
    has_keychain: mac,
    stub_dir: () => match stub.val {
      Some(dir) => @agent_drivers.Later::ok(lp, dir)
      None =>
        pump.later("keychain stub", async fn() {
          let dir = @agent_runtimes.stub_dir_soon(host, tmpdir(), @drive.uid(), "\{@drive.pid()}")
          stub.val = Some(dir)
          dir
        })
    },
    take_back: home => pump.later("Claude login taken back", async fn() { @agent_runtimes.take_back(host, home, mac) }),
    take_back_missing: home => pump.later("Claude login taken back", async fn() {
      @agent_runtimes.take_back_missing(host, home, mac)
    }),
  }
}

///|
/// Claude Code's driver (claude.ts `ClaudeDriver`).
fn claude_driver(ctx : P52, procs : @agent_drivers.Procs, words : @agent_drivers.Words) -> Driver {
  let pump = ctx.pump
  let m = pump.machine()
  let host = ctx.host
  let logins = p52_claude_logins(pump, host, (op, arg) => (ctx.bus.jobs_ask.val)(op, arg))
  let d = @agent_drivers.ClaudeDriver::new(
    m,
    ctx.data,
    procs,
    command="claude",
    @agent_drivers.Env::new(agent_env(ctx)),
    words,
    profile_says(),
    logins,
    ids_live(),
  )
  // A session run as its TUI (claude.ts `TUI_BRIDGE`): this program as the bridge, its hooks and its tools
  // (claude_tui.mbt), under the runner's `--relay-pty`.
  match ctx.runner {
    Some(runner) => {
      let argv0 = ctx.bus.argv0
      d.tui_bridge.val = Some({
        program: attempt(() => @drive.realpath(argv0)).unwrap_or(argv0),
        script: station_script(ctx.bus.app, argv0, "claude-tui.mjs"),
        runner,
        shell_env: (command, env) => pump.later("Claude's command on the shell's PATH", async fn() {
          let found = with_shell_command(host, command, env.pairs.copy())
          if found.iter().find_first(kv => kv.0 == "PATH") is Some(kv) { env.set("PATH", kv.1) }
        }),
      })
    }
    None => ()
  }
  let agent_of = (s : @agent_drivers.ClaudeSession) => own_agent(
    pump,
    s.own,
    t => s.prompt(t),
    t => s.steer(t),
    () => s.abort(),
    Some(() => s.compact()),
    o => s.retune(o),
    () => s.snapshot(),
    () => of_jv(s.background()),
    () => s.outlived(),
  )
  {
    kind: "claude",
    open: async fn(options, events) { agent_of(pump.wait(d.open(to_jv(options), events))) },
    adopt: async fn(options, snap, events) { agent_of(pump.wait(d.adopt(to_jv(options), snap.map(to_jv), events))) },
    shutdown: async fn(again) {
      for s in d.sessions.copy() {
        if again {
          ignore(pump.wait(s.dispose())) catch { _ => () }
        } else {
          ignore(pump.wait(s.dispose())) catch { _ => () }
        }
      }
      if !again {
        ignore(pump.wait((procs.close)())) catch { _ => () }
      }
    },
    detach: () => d.own.detach(),
    freeze: async fn() { ignore(pump.wait(d.own.freeze())) catch { _ => () } },
    thaw: () => d.own.thaw(),
    owned_runners: () => d.own.owned_runners(),
    evict_idle: async fn() { 0 },
    ask: no_ask("claude"),
  }
}

///|
/// A token's `expiresAt` as the accounts answer it, 0 where they say none.
fn p52_expires_at(t : Map[String, Json]) -> Double {
  match t.get("expiresAt") {
    Some(Number(n, ..)) => n
    _ => 0.0
  }
}

///|
/// Whether a profile is another station's, borrowed (share/index.ts `borrowedSubscription`).
fn borrowed_profile(_ctx : P52, p : Json) -> Bool {
  p52_borrowed(p)
}

///|
fn p52_borrowed(p : Json) -> Bool {
  jfield(p, "share") != Json::null() && jtext(jfield(p, "share"), "host") is Some(_)
}

///|
/// Codex's driver (codex.ts `CodexDriver`): one app-server per account, a thread per session.
/// Settled once what the station before left is taken up (`P52::take_handover`; codex.ts `takenUp`, agents.ts
/// `start`): until then an app-server a runner keeps is that station's, taken up with the snapshot of a session that ran
/// on it. Left out, a profile's quota or the model catalog asked as the station started took each up as after a crash
/// (`crashed: true` at every handover of 0.1.9984 to 0.1.9996), from the station still handing it over.
let codex_taken_up_ref : Ref[@agent_drivers.Later[Unit]?] = Ref(None)

///|
fn codex_taken_up(lp : @agent_drivers.Loop) -> @agent_drivers.Later[Unit] {
  match codex_taken_up_ref.val {
    Some(t) => t
    None => {
      let t : @agent_drivers.Later[Unit] = @agent_drivers.Later::new(lp)
      codex_taken_up_ref.val = Some(t)
      t
    }
  }
}

///|
/// What was left is taken up (or there was nothing to take up): the app-servers may be asked for.
fn codex_left_taken_up() -> Unit {
  match codex_taken_up_ref.val {
    Some(t) if !t.settled() => t.resolve(())
    _ => ()
  }
}

///|
fn codex_driver(ctx : P52, procs : @agent_drivers.Procs, words : @agent_drivers.Words) -> Driver {
  let pump = ctx.pump
  let m = pump.machine()
  let lp = pump.lp
  let host = ctx.host
  let home = env_get("HOME").unwrap_or(homedir())
  let world : @agent_drivers.CodexWorld = {
    raw_env: @agent_drivers.Env::new(env_all()),
    agent_env: () => {
      let base = env_all()
      agent_env(ctx).filter(kv => !base.contains(kv))
    },
    walk_skills: root => pump.later("host skills", async fn() {
      // (codex.ts `hostSkillsOff`: the SKILL.md files under the user's own skills, bounded as walkBounded is)
      let found : Array[String] = []
      let stack = [(root, 0)]
      let mut entries = 0
      while stack.pop() is Some((dir, depth)) {
        if depth > 7 || entries > 4000 {
          break
        }
        let names = attempt(() => @drive.names(dir)).unwrap_or([])
        for n in names {
          entries += 1
          let p = path([dir, n])
          if n == "SKILL.md" {
            found.push(p)
          } else if attempt(() => @drive.stat(p)) is Ok(st) && st.dir {
            stack.push((p, depth + 1))
          }
        }
      }
      found
    }),
    host_skills: path([home, ".agents", "skills"]),
    ca_bundle: "/etc/ssl/cert.pem",
    fast: Some(thread => {
      let v = ctx.bus.store.codex_session_fast(thread) catch { _ => Json::null() }
      match v {
        True => Some(true)
        False => Some(false)
        _ => None
      }
    }),
    speed: Some(thread => {
      let v = ctx.bus.store.codex_session_speed(thread) catch { _ => Json::null() }
      as_text(v)
    }),
    current_profile: Some(id => ctx.profiles().iter().find_first(p => jtext(p, "id") == Some(id)).map(to_jv)),
    lent_borrowed: Some(p => borrowed_profile(ctx, of_jv(p))),
    lent_write: Some(p => pump.later("lent Codex login", async fn() {
      match ctx.bus.jobs_sharing_lend_codex(of_jv(p)) {
        Number(n, ..) => n
        _ => raise @agent_drivers.Failed("the lent sign-in is not there")
      }
    })),
    installed_version: () => pump.later("codex version", async fn() {
      as_text(ctx.bus.coord_updates_version("codex"))
    }),
    // (codex-repair.ts `findMissingCodexHost`: a code-mode host the installed Codex lacks)
    missing_host: (command, env) => pump.later("codex host", async fn() {
      @updates.find_missing_codex_host(station_updates_world(ctx.bus), command, env.pairs) is Some(_)
    }),
    incomplete_installation: () => fork_bg(host, "codex check", async fn() { ctx.bus.coord_updates_check() }),
    link_auth: dir => pump.later("codex auth", async fn() {
      let fields = @agent_runtimes.Fields::new()
      for kv in env_all() {
        fields.set(kv.0, @jsjson.JValue::Str(kv.1))
      }
      @agent_runtimes.link_codex_auth_soon(host, dir, fields)
    }),
    // (read/transcript.ts `rememberCodexRolloutLooking`: the rollout a running thread said, the locator's hint)
    remember_rollout: (id, dirs, suffix) => remember_said_rollout(id, dirs, suffix),
    // (codex.ts `updateMatchesStation`: the agents' `codex` and the station's the same command)
    update_matches: _ => pump.later("codex matches", async fn() {
      let agent_env = with_shell_command(host, "codex", agent_env(ctx))
      let station_env = with_shell_command(host, "codex", env_all())
      match (find_command("codex", agent_env), find_command("codex", station_env)) {
        (Some(a), Some(b)) =>
          a == b && attempt(() => @drive.realpath(a)).unwrap_or(a) == attempt(() => @drive.realpath(b)).unwrap_or(b)
        _ => false
      }
    }),
    taken_up: Some(codex_taken_up(lp)),
    taking: () => (ctx.bus.control_say)({ "taking": jb(true) }),
    output_limit: 64 * 1024 * 1024,
    take_up_bytes: 16 * 1024 * 1024,
    warm_ms: 30.0 * 60_000.0,
  }
  let d = @agent_drivers.CodexDriver::new(m, ctx.data, procs, command="codex", world, profile_says(), words)
  let agent_of = (s : @agent_drivers.CodexSession) => ({
    id: () => s.thread_id,
    busy: () => s.busy,
    background: () => Json::array([]),
    mcp_url: () => s.tools_url,
    can_compact: true,
    outlived: () => false,
    sign_in_expired: () => false,
    lent_expired: () => false,
    route: router => match router {
      Some(took) => {
        let n = match hosted_of(s.host.proc) {
          Some(p) => p.n
          None => -1
        }
        s.route(Some(batch => took(batch, n)))
      }
      None => s.route(None)
    },
    prompt: t => pump.wait(s.prompt(t)),
    steer: t => pump.wait(s.steer(t)),
    abort: () => pump.wait(s.abort()),
    compact: () => pump.wait(s.compact()),
    dispose: () => pump.wait(s.dispose()),
    retune: o => s.retune(to_jv(o)),
    snapshot: () => of_jv(s.snapshot()),
    detach: () => s.detach(),
    runtime_version: () => s.host.version,
  } : Agent)
  {
    kind: "codex",
    open: async fn(options, events) { agent_of(pump.wait(d.open(to_jv(options), events))) },
    adopt: async fn(options, snap, events) {
      // (its thread's events taken by its actor in the program from the first: codex.ts `addThread`'s router)
      let key = jtext(options, "key").unwrap_or("")
      match adopt_routers.get(key) {
        Some(took) =>
          d.adopt_routers[key] = (batch, proc) => took(batch, match hosted_of(Some(proc)) {
            Some(h) => h.n
            None => -1
          })
        None => ()
      }
      let agent = agent_of(pump.wait(d.adopt(to_jv(options), snap.map(to_jv), events))) catch {
        e => {
          d.adopt_routers.remove(key)
          raise e
        }
      }
      d.adopt_routers.remove(key)
      agent
    },
    shutdown: async fn(again) { ignore(pump.wait(d.shutdown(again~))) catch { _ => () } },
    detach: () => d.detach(),
    freeze: async fn() { ignore(pump.wait(d.freeze())) catch { _ => () } },
    thaw: () => d.thaw(),
    owned_runners: () => d.owned_runners(),
    evict_idle: async fn() { pump.wait(d.evict_idle()) catch { _ => 0 } },
    ask: async fn(what, arg) {
      match what {
        "rateLimits" => of_jv(pump.wait(d.rate_limits(to_jv(arg))))
        "renewRunning" => Json::boolean(pump.wait(d.renew_login(jtext(arg, "profile").unwrap_or(""))))
        // (the accounts' check: what the account can run, and at what efforts; codex.ts `models`)
        "models" => {
          let c = pump.wait(d.models(to_jv(jitems(arg).get(0).unwrap_or(Json::null()))))
          let out : Map[String, Json] = {
            "models": Json::array(c.models.map(Json::string)),
            "efforts": Json::object(Map::from_array(c.efforts.map(e => (e.0, Json::array(e.1.map(Json::string)))))),
            "defaults": Json::object(Map::from_array(c.defaults.map(e => (e.0, Json::string(e.1))))),
          }
          if c.ultrafast_models is Some(u) { out["ultrafastModels"] = Json::array(u.map(Json::string)) }
          Json::object(out)
        }
        // (a limit's reset redeemed on the account: codex.ts `resetQuota`)
        "resetQuota" => {
          let a = jitems(arg)
          of_jv(
            pump.wait(d.reset_quota(to_jv(a.get(0).unwrap_or(Json::null())), opt_str(a.get(1)).unwrap_or(""))),
          )
        }
        // (a profile's sign-in changed: its app-server let go, codex.ts `loginChanged`)
        "loginChanged" => {
          pump.wait(d.login_changed(as_text(jitems(arg).get(0).unwrap_or(Json::null())).unwrap_or("")))
          Json::null()
        }
        // (codex.ts `runtimeChanged`: its app-servers of a replaced version let go, a busy one's turns drained first)
        "runtimeChanged" => {
          pump.wait(d.runtime_changed(replaced=jfield(arg, "replaced") is True, drain_busy=jfield(arg, "drainBusy") is True))
          Json::null()
        }
        _ => raise LiveError("codex's driver answers no \{what}")
      }
    },
  }
}

///|
/// Antigravity CLI's driver (agy.ts `AgyDriver`): an ACP runtime.
fn agy_driver(ctx : P52, procs : @agent_drivers.Procs, words : @agent_drivers.Words) -> Driver {
  let pump = ctx.pump
  let m = pump.machine()
  let lp = pump.lp
  let host = ctx.host
  let world : @agent_drivers.AgyWorld = {
    raw_env: @agent_drivers.Env::new(agent_env(ctx)),
    // (agy.ts `agyKeychain`: the user's one keychain item `agy` kept a sign-in in before AGY_FILE_TOKENS)
    has_keychain: platform() == "darwin",
    keychain_read: () => pump.later("agy keychain", async fn() {
      let child = spawn(host, "/usr/bin/security", ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"], stdout=Piped, stderr=Ignored) catch {
        _ => return None
      }
      match @effect.timeout(5000, async fn() { child.finished() }) { // timer: a deadline to a process
        Some((Some(0), _, out, _)) => Some(@utf8.decode_lossy(out).trim().to_owned())
        Some(_) => None
        None => {
          ignore(kill(child.pid, "SIGKILL"))
          None
        }
      }
    }),
    lent_borrowed: Some(p => borrowed_profile(ctx, of_jv(p))),
    lent_write: Some(p => pump.later("lent Antigravity login", async fn() {
      match ctx.bus.jobs_sharing_lend_agy(of_jv(p)) {
        Number(n, ..) => n
        _ => raise @agent_drivers.Failed("the lent sign-in is not there")
      }
    })),
    run: (command, args, env, cwd, limit) => pump.later("agy command", async fn() {
      let child = spawn(host, command, args, env=env.pairs, cwd~, stdout=Ignored, stderr=Ignored, group=true)
      match @effect.timeout(limit.to_int(), async fn() { child.finished() }) {
        Some((Some(0), _, _, _)) => ()
        Some((code, signal, _, _)) => raise @agent_drivers.Failed("\{command} exited (\{@agent_drivers.describe_exit(code, signal)})")
        None => {
          ignore(kill(child.pid, "SIGKILL", group=true))
          raise @agent_drivers.Failed("\{command} timed out")
        }
      }
    }),
    sleep: ms => (m.sleep)(ms),
  }
  let d = @agent_drivers.AgyDriver::new(m, ctx.data, procs, command="agy", world, profile_says(), words, ids_live())
  let agent_of = (s : @agent_drivers.AgySession) => own_agent(
    pump,
    s.acp.own,
    t => s.acp.prompt(t),
    t => s.steer(t),
    () => s.acp.abort(),
    None,
    o => s.retune(o),
    () => s.acp.snapshot(),
    () => Json::array([]),
    () => s.outlived(),
    sign_in_expired=() => s.sign_in_expired(),
    lent_expired=() => s.lent_expired(),
  )
  {
    kind: "agy",
    open: async fn(options, events) { agent_of(pump.wait(d.open(to_jv(options), events))) },
    adopt: async fn(options, snap, events) { agent_of(pump.wait(d.adopt(to_jv(options), snap.map(to_jv), events))) },
    shutdown: async fn(again) {
      for s in d.sessions.copy() {
        ignore(pump.wait(s.acp.own.dispose())) catch { _ => () }
      }
      if !again {
        ignore(pump.wait((procs.close)())) catch { _ => () }
      }
    },
    detach: () => d.own.detach(),
    freeze: async fn() { ignore(pump.wait(d.own.freeze())) catch { _ => () } },
    thaw: () => d.own.thaw(),
    owned_runners: () => d.own.owned_runners(),
    evict_idle: async fn() { 0 },
    ask: async fn(what, arg) {
      match what {
        "renew" => {
          pump.wait(d.renew(jtext(arg, "profile").unwrap_or("")))
          Json::null()
        }
        "takeBack" => Json::boolean(pump.wait(d.take_back(jtext(arg, "home").unwrap_or(""))))
        "noteEmail" =>
          jopt(pump.wait(@agent_drivers.note_agy_email(pump.machine(), jtext(arg, "home").unwrap_or(""), jtext(arg, "text").unwrap_or(""))))
        // (the accounts' check: the models, efforts and plan its sign-in offers; agy.ts `catalog`)
        "catalog" => of_jv(pump.wait(d.catalog(to_jv(jitems(arg).get(0).unwrap_or(Json::null())))))
        _ => raise LiveError("agy's driver answers no \{what}")
      }
    },
  }
}
