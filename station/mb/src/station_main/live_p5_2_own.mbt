// The agents' side (P5-2): the runtimes whose process is the station's own to drive (own-process.ts). The ACP ones
// (Grok Build, Devin, Hermes Agent: acp.ts) are opened here as Antigravity's is (agy.ts `acpBegin`): their start as the
// runtime says it (agent_runtimes `grok_start`, `devin_start`, `hermes_start`), under a runner, read by the program
// (agents_own.mbt), `initialize`, then `session/new` or `session/load` with the station's tools. DeepSeek Harness, Cursor
// and Pi speak to the station through its bridges (dsh-bridge.mjs, loaded by dsh itself as its driver plugin;
// pi-bridge.mjs, by Pi as its extension; cursor-bridge.mjs, run by the Node on the agent's PATH, as Cursor's SDK is a
// Node package): none needs the station's own Node (agent_drivers `BridgedDriver`).

///|
fn own_runtime_driver(
  ctx : P52,
  procs : @agent_drivers.Procs,
  words : @agent_drivers.Words,
  kind : String,
) -> Driver {
  ignore(words)
  if ["grok", "devin", "hermes"].contains(kind) {
    return acp_runtime_driver(ctx, procs, kind)
  }
  bridged_runtime_driver(ctx, procs, kind)
}

///|
/// Where a script the station ships beside its program is (package.json's `build` copies them into dist/, which a
/// release puts at `<app>/station/`): a release's, else the checkout's (`station/src/agents`) above the program.
fn station_script(app : String, argv0 : String, name : String) -> String {
  let s = sep()
  let candidates = [
    path([app, "station", name]),
    path([app, "station", "dist", name]),
  ]
  let mut dir = @nodepath.dirname(
    s,
    attempt(() => @drive.realpath(argv0)).unwrap_or(argv0),
  )
  for _ in 0..<8 {
    candidates.push(path([dir, "station", "src", "agents", name]))
    candidates.push(path([dir, "src", "agents", name]))
    dir = @nodepath.dirname(s, dir)
  }
  match
    candidates
    .iter()
    .find_first(c => attempt(() => @drive.stat(c)) is Ok(st) && st.file) {
    Some(c) => c
    None => candidates[0]
  }
}

///|
/// DeepSeek Harness', Cursor's or Pi's driver (dsh.ts, cursor.ts, pi.ts).
fn bridged_runtime_driver(
  ctx : P52,
  procs : @agent_drivers.Procs,
  kind : String,
) -> Driver {
  let pump = ctx.pump
  let d = @agent_drivers.BridgedDriver::new(
    pump.machine(),
    ctx.data,
    procs,
    kind,
    ids_live(),
  )
  let bridge = station_script(ctx.bus.app, ctx.bus.argv0, "\{kind}-bridge.mjs")
  let agent_of = (x : @agent_drivers.BridgedSession) => {
    own_agent(
      pump,
      x.own,
      t => x.prompt(t),
      t => x.steer(t),
      () => x.abort(),
      None,
      o => x.retune(o),
      () => x.snapshot(),
      () => Json::array([]),
      () => false,
    )
  }
  let open = async fn(
    options : Json,
    events : (@jsjson.JValue) -> Unit,
  ) -> Agent {
    let o = @agent_runtimes.Options::of(to_jv(options))
    let env = agent_env(ctx)
    let base = fields_of_env(env)
    let host = ctx.host
    let (start, id) = match kind {
      "dsh" =>
        (@agent_runtimes.dsh_start(host, o, base, "dsh", bridge, None), "")
      "cursor" => {
        guard @agent_runtimes.cursor_find_sdk(host, ctx.data) is Some(sdk) else {
          raise @agent_drivers.command_missing("cursor")
        }
        guard find_command("node", env) is Some(node) else {
          raise @agent_drivers.command_missing("node")
        }
        (
          @agent_runtimes.cursor_start(
            host,
            o,
            base,
            node,
            bridge,
            Some(sdk),
            ctx.data,
          ),
          "",
        )
      }
      _ => {
        let id = match o.resume {
          Some(r) => r
          None => @drive.random_uuid()
        }
        (@agent_runtimes.pi_start(host, o, base, "pi", bridge, id, None), id)
      }
    }
    let model = if kind == "cursor" {
      match o.model {
        Some(m) => Some(m)
        None => @agent_runtimes.profile_model(o.profile)
      }
    } else {
      None
    }
    let x = pump.wait(
      d.open(
        o.key,
        o.cwd,
        start.command,
        start.args,
        @agent_drivers.Env::new(fields_pairs(start.env)),
        start.open.unwrap_or(@agent_drivers.obj([])),
        o.mcp_url,
        events,
        id~,
        model~,
        no_tools=tr(ctx.lang(), "station.dsh.noTools"),
      ),
    )
    agent_of(x)
  }
  {
    kind,
    open,
    adopt: async fn(options, snap, events) {
      agent_of(pump.wait(d.adopt(to_jv(options), snap.map(to_jv), events)))
    },
    shutdown: async fn(again) {
      ignore(pump.wait(d.own.shutdown(again~))) catch {
        _ => ()
      }
    },
    detach: () => d.own.detach(),
    freeze: async fn() { ignore(pump.wait(d.own.freeze())) catch { _ => () } },
    thaw: () => d.own.thaw(),
    owned_runners: () => d.own.owned_runners(),
    evict_idle: async fn() { 0 },
    ask: no_ask(kind),
  }
}

///|
fn fields_of_env(pairs : Array[(String, String)]) -> @agent_runtimes.Fields {
  let f = @agent_runtimes.Fields::new()
  for kv in pairs {
    f.set(kv.0, @jsjson.JValue::Str(@jsjson.units(kv.1)))
  }
  f
}

///|
/// An ACP runtime's driver (acp.ts `AcpDriver`): Grok Build, Devin, Hermes Agent.
fn acp_runtime_driver(
  ctx : P52,
  procs : @agent_drivers.Procs,
  kind : String,
) -> Driver {
  let pump = ctx.pump
  let m = pump.machine()
  let lp = pump.lp
  let own_driver = @agent_drivers.OwnDriver::new(m, ctx.data, procs, kind)
  let sessions : Array[@agent_drivers.AcpSession] = []
  // (a session opened only to ask what the runtime offers, hermes.ts `models`: what session/new said of its models, by
  // its key, until it is read and the session ended)
  let probes : Map[String, (@agent_drivers.AcpSession, Json)] = {}
  let stopping = Ref(false)
  let agent_of = (session : @agent_drivers.AcpSession) => {
    own_agent(
      pump,
      session.own,
      t => session.prompt(t),
      // (an ACP runtime takes no word in the middle of its turn: what comes meanwhile waits for the next)
      _ => @agent_drivers.Later::ok(lp, false),
      () => session.abort(),
      None,
      _ => false,
      () => session.snapshot(),
      () => Json::array([]),
      () => false,
    )
  }
  let open_as = async fn(
    options : Json,
    events : (@jsjson.JValue) -> Unit,
    probe : Bool,
  ) -> Agent {
    let o = @agent_runtimes.Options::of(to_jv(options))
    let base = fields_of_env(agent_env(ctx))
    let start = match kind {
      "grok" => @agent_runtimes.grok_start(ctx.host, o, base, "grok")
      "devin" => @agent_runtimes.devin_start(ctx.host, o, base, "devin")
      _ =>
        @agent_runtimes.hermes_start(
          ctx.host,
          o,
          base,
          "hermes",
          env_get("HOME").unwrap_or(homedir()),
          None,
        )
    }
    // (what it reads as it starts: its config, its rules, its key)
    for f in start.files {
      ignore(attempt(() => @drive.mkdir(@nodepath.dirname(sep(), f.0), true)))
      ignore(write_text_mode(f.0, f.1, 0o600))
    }
    let session = @agent_drivers.AcpSession::new(
      lp,
      kind,
      ids_live(),
      events,
      None,
    )
    session.own.set_tools_url(Some(o.mcp_url))
    let key = o.key
    pump.wait(
      own_driver.start(
        session.own,
        key,
        o.cwd,
        start.command,
        start.args,
        @agent_drivers.Env::new(fields_pairs(start.env)),
        session.own.hosted_options(
          "\{kind} \{key}",
          "acp",
          flavor=kind,
          kept=false,
        ),
      ),
    )
    let meta = match start.meta {
      Some(mt) => [("_meta", of_jv(mt))]
      None => []
    }
    let opened = try {
      ignore(
        pump.wait(
          session.request(
            "init",
            "initialize",
            to_jv(
              jobj_of(
                [
                  ("protocolVersion", ji(1)),
                  ("clientCapabilities", Json::object({})),
                  (
                    "clientInfo",
                    { "name": jstr("still.fail"), "version": jstr("1") },
                  ),
                  ..meta,
                ],
              ),
            ),
            timeout_ms?=start.init_timeout,
          ),
        ),
      )
      let opening = jobj_of(
        [
          ("cwd", jstr(o.cwd)),
          (
            "mcpServers",
            if probe {
              Json::array([])
            } else {
              of_jv(@agent_drivers.mcp_servers(o.mcp_url, o.mcp_token))
            },
          ),
          ..match start.opening {
            Some(op) =>
              match of_jv(op) {
                Object(fs) => fs.iter().to_array()
                _ => []
              }
            None => []
          },
          ..meta,
        ],
      )
      let answer = match o.resume {
        Some(r) => {
          session.named(r)
          let load = match opening {
            Object(fs) => {
              let c = fs.copy()
              c["sessionId"] = jstr(r)
              Json::object(c)
            }
            other => other
          }
          pump.wait(session.request("open", "session/load", to_jv(load)))
        }
        None => {
          let answer = pump.wait(
            session.request("open", "session/new", to_jv(opening)),
          )
          match jtext(jfield(of_jv(answer), "result"), "sessionId") {
            Some(id) if id != "" => {
              session.named(id)
              session.began(o.cwd)
            }
            _ =>
              raise @agent_drivers.Failed(
                "\{@agent_drivers.runtime_label(kind)} named no session",
              )
          }
          answer
        }
      }
      session.opened(
        match of_jv(answer) {
          Object(_) as a => Some(to_jv(jfield(a, "result")))
          _ => None
        },
      )
      Ok(jfield(jfield(of_jv(answer), "result"), "models"))
    } catch {
      e => Err(e)
    }
    match opened {
      Ok(models) if probe => {
        probes[key] = (session, models)
        agent_of(session)
      }
      Ok(_) => {
        sessions.push(session)
        agent_of(session)
      }
      Err(e) => {
        ignore(pump.wait(session.own.dispose())) catch {
          _ => ()
        }
        raise e
      }
    }
  }
  let open = async fn(options : Json, events : (@jsjson.JValue) -> Unit) -> Agent { open_as(options, events, false) }
  // hermes.ts `models`: a session opened only to ask, asked again only while a fresh HERMES_HOME waits on another
  // launch's update of the shared checkout (`hermes_models_again`), then ended
  let models = async fn(profile : Json) -> Json {
    let id = jtext(profile, "id").unwrap_or("")
    let home = jtext(profile, "home").unwrap_or("")
    @drive.mkdir(home, true)
    let deadline = wall_ms().to_double() + 120_000.0
    while true {
      if stopping.val {
        raise LiveError("Hermes driver is shutting down")
      }
      let key = "models-\{id}-\{p53_uuid()}"
      let options : Json = {
        "key": jstr(key),
        "profile": profile,
        "cwd": jstr(home),
        "instructions": jstr(""),
        "mcpToken": jstr(""),
        "mcpUrl": jstr(""),
        "route": jstr("model-discovery"),
      }
      match (try { Ok(open_as(options, _ => (), true)) } catch { e => Err(e) }) {
        Ok(_) => {
          guard probes.get(key) is Some((session, said)) else { raise LiveError("Hermes Agent opened no session") }
          probes.remove(key)
          let found = @agent_runtimes.hermes_catalog(Some(to_jv(said)), to_jv(profile))
          pump.wait(session.own.dispose())
          return Json::array(found.map(Json::string))
        }
        Err(e) =>
          if !@agent_runtimes.hermes_models_again(said_of(e), wall_ms().to_double(), deadline, stopping.val) {
            raise e
          }
      }
      @effect.sleep(2000) // timer: a retry after a refusal, until its deadline (hermes.ts `models`)
    }
    Json::array([])
  }
  {
    kind,
    open,
    // (taken up after a handover: opened again on its conversation, as one cut off is: acp.ts `adopt` keeps the process
    // the runner holds, which this station ends as an orphan and opens anew with `session/load`)
    adopt: async fn(options, _snap, events) {
      let id = (sessions.length(), jtext(options, "resume"))
      ignore(id)
      open(options, events)
    },
    shutdown: async fn(again) {
      stopping.val = true
      for s in sessions.copy() {
        ignore(pump.wait(s.own.dispose())) catch {
          _ => ()
        }
      }
      sessions.clear()
      if !again {
        ignore(pump.wait((procs.close)())) catch {
          _ => ()
        }
      }
    },
    detach: () => own_driver.detach(),
    freeze: async fn() {
      ignore(pump.wait(own_driver.freeze())) catch {
        _ => ()
      }
    },
    thaw: () => own_driver.thaw(),
    owned_runners: () => own_driver.owned_runners(),
    evict_idle: async fn() { 0 },
    ask: if kind == "hermes" {
      async fn(what, arg) {
        match what {
          "models" => models(jitems(arg).get(0).unwrap_or(Json::null()))
          _ => raise LiveError("hermes's driver answers no \{what}")
        }
      }
    } else {
      no_ask(kind)
    },
  }
}
