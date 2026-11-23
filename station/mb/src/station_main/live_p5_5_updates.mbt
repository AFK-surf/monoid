// UpdatesLive and FeaturesLive (sessions/agents.ts's updates, api/routes/updates.ts, features.ts `FeaturesLive`): the
// station's and its runtimes' versions read at start and as the cloud says a release is out (and the runtimes' every
// few hours: updates.mbt's schedule), updated from the pages or by itself while nothing runs (auto update); the channel
// it is updated on, set from the pages; the overview's `updates` and `features`; `agents.updates.*` on `coord_ask`.

///|
/// The updates' world on this machine (cli.mbt `updates_world`'s), its config the bus's: an edit goes through
/// `config_update` and is heard by every part, not written beside them.
fn p5_5_updates_world(bus : LiveBus) -> @updates.World {
  let extra_node = async fn(name : String, a : Array[@jsjson.JValue]) -> @jsjson.JValue? {
    let core = (i : Int) => if i < a.length() { of_jv(a[i]) } else { Json::null() }
    match name {
      // (platform/unix.ts, windows.ts `nodeBuild`: the Node release built for this machine)
      "platform.nodeBuild" => {
        let version = match core(0) { String(v) => v; _ => "" }
        let a = arch()
        if a != "arm64" && a != "x64" {
          return Some(to_jv(Json::null()))
        }
        if is_windows() {
          let dist = "node-v\{version}-win-\{a}"
          Some(to_jv({ "dist": Json::string(dist), "archive": Json::string("\{dist}.zip"), "bin": "", "npm": "npm.cmd", "tar": Json::string(path([env_get("SystemRoot").unwrap_or("C:\\Windows"), "System32", "tar.exe"])) }))
        } else {
          let os = platform()
          if os != "darwin" && os != "linux" {
            return Some(to_jv(Json::null()))
          }
          let dist = "node-v\{version}-\{os}-\{a}"
          Some(to_jv({ "dist": Json::string(dist), "archive": Json::string("\{dist}.tar.gz"), "bin": "bin", "npm": "npm", "tar": "tar" }))
        }
      }
      // (unix.ts `findCommandSoon`: where on the environment's PATH a command is, and that followed)
      "platform.findCommandSoon" => {
        let name = match core(0) { String(n) => n; _ => "" }
        let env = if a.length() > 1 { @updates.env_of(a[1]) } else { [] }
        match find_command(name, env) {
          Some(on) =>
            Some(to_jv({ "onPath": Json::string(on), "real": Json::string(attempt(() => @drive.realpath(on)).unwrap_or(on)) }))
          None => Some(to_jv(Json::null()))
        }
      }
      "shellPath.withShellCommand" => {
        let name = match core(0) { String(n) => n; _ => "" }
        let env = if a.length() > 1 { @updates.env_of(a[1]) } else { [] }
        Some(@updates.env_j(with_shell_command(bus.host, name, env)))
      }
      _ => None
    }
  }
  let tell = (name : String, a : Array[@jsjson.JValue]) => match name {
    "console.log" | "console.error" => if a.length() > 0 { err_write(js_text(a[0]) + "\n") }
    // (shell-path.ts `forgetShellPaths`: a check reads the user's shell again, a runtime installed meanwhile found)
    "shellPath.forgetShellPaths" => forget_shell_paths()
    // (the updates' log: the station's)
    "log.info" | "log.warn" | "log.error" =>
      slice_log(name[4:].to_owned(), if a.length() > 0 { js_text(a[0]) } else { "updates" }, if a.length() > 1 { js_text(a[1]) } else { "" }, if a.length() > 2 { of_jv(a[2]) } else { Json::null() })
    _ => ignore(updates_platform_told(name, a.map(of_jv)))
  }
  build_updates_world(
    bus.host,
    bus.data,
    () => (bus.config_raw.val)(),
    async fn(next) { ignore((bus.config_update.val)(_ => next)) },
    extra_node=Some(extra_node),
    tell~,
    watch=Some(async fn(dir, told) { p55_watch_dir(bus, dir, told) }),
  )
}

///|
/// One updates' world for what the other slices ask of it (codex-repair.ts `findMissingCodexHost`, the Codex driver's).
let shared_updates_world : Ref[@updates.World?] = Ref(None)

///|
fn station_updates_world(bus : LiveBus) -> @updates.World {
  match shared_updates_world.val {
    Some(w) => w
    None => {
      let w = p5_5_updates_world(bus)
      shared_updates_world.val = Some(w)
      w
    }
  }
}

///|
fn P55::start_features(self : P55) -> Unit raise PartTwice {
  let bus = self.bus
  // (features.ts `stationFeatures`: those on here, by the channel the station is updated on)
  bus.parts.overview("features", async fn(_viewer, _lang) {
    Json::array(station_features((bus.config_raw.val)(), bus.app).map(Json::string(_)))
  })
  self.op("features", async fn(_arg) {
    Json::array(station_features((bus.config_raw.val)(), bus.app).map(Json::string(_)))
  })
}

///|
/// The lang an op is asked in: `[lang]` (the agents' tools' way) or `{"lang"}`.
fn lang_arg(arg : Json) -> String {
  match arg {
    Array([String(l), ..]) => l
    Object(_) => jtext(arg, "lang").unwrap_or("zh")
    _ => "zh"
  }
}

///|
/// `rig`: a station that only runs tasks (rig/main.ts): its own release only, nothing running, none of the pages' or
/// the agents' hands on it (it serves no device and runs no agent).
async fn P55::start_updates(self : P55, rig? : Bool = false) -> Unit {
  let bus = self.bus
  updates_setup(bus.data, bus.argv0, app=bus.app)
  let w = p5_5_updates_world(bus)
  let config = @updates.Config::new(to_jv((bus.config_raw.val)()))
  // (the station's own release only, until the agents' part says which runtimes it runs: their versions are its)
  let station_only = rig || (bus.runtimes_available.val)().is_empty()
  let running = () => if rig { 0.0 } else { match (bus.status_agents.val)() {
    Some(s) =>
      as_num(jfield(jfield(s, "agents"), "busy")).unwrap_or(0.0)
    None => 0.0
  } }
  let env : Array[(String, String)] = env_all()
  let u = @updates.Updates::new(w, {
    app: bus.app,
    data: bus.data,
    config,
    origin: () => self.release_base(),
    env,
    registry: "https://registry.npmjs.org",
    devin_manifest: @updates.devin_manifest,
    claude_releases: "https://downloads.claude.ai/claude-code-releases",
    agy_manifests: @updates.agy_manifests,
    node_dist: "https://nodejs.org/dist",
    running,
    station_only,
    timing: @updates.default_timing,
    trusted: None,
    node_version: "",
  })
  self.updates = Some(u)
  // (launcher.ts `runInstaller`: the installer started by the launcher where this process could not start it)
  if bus.run_installer is Some(f) {
    u.on_launcher_installer((script, env) => f(script, Map::from_array(env)))
  }
  // The config edited elsewhere (a page, `stillfail channel`, another part): heard as it changes.
  let off = (bus.config_listen.val)(raw => {
    config.raw = to_jv(raw)
    config.tell()
  })
  // What the overview shows changes: told on the event streams.
  let unchanged = u.changes(() => (bus.overview_changed.val)())
  u.start()
  self.closing(async fn() {
    off()
    unchanged()
    u.close()
  })
  // The cloud said a release is out (its presence socket's `release`, the plane's `told`): read again, a rig too.
  bus.on_release(() => ignore(
    bus.host.rt.fork_quiet(name="release check", async fn() { u.check() catch { e => self.warn("updates", "the release not read", e) } }),
  ))
  self.op("updates.check", async fn(_arg) {
    u.check()
    Json::null()
  })
  if rig {
    // rig/main.ts: `stillfail update --beta|--stable` asks it by SIGHUP too.
    self.op("updates.hup", async fn(_arg) {
      u.answer_channel_ask()
      Json::null()
    })
    return
  }
  // A runtime installed or updated from the pages (agents.ts `onRuntimeChanged`): the machine's logins read again, and
  // the agents' side told (what waited for it started, its processes on the new one).
  u.on_runtime_changed((kind, installed, replaced) => ignore(
    bus.host.rt.fork_quiet(name="runtime changed", async fn() {
      bus.jobs_machine_refresh() catch {
        _ => ()
      }
      bus.hub_runtime_changed(kind~, installed~, replaced~) catch {
        e => self.warn("updates", "the agents' side not told a runtime changed", e)
      }
    }),
  ))
  bus.parts.overview("updates", async fn(_viewer, lang) { of_jv(@jsjson.JValue::Arr(u.get(lang))) })
  bus.parts.routes(updates_routes(u))
  // Its agents' hand on its release (tools/version.ts): updated, or put back to an earlier one.
  bus.parts.tools([
    {
      name: "station_version",
      declared: tool_declared(version_declared),
      call: async fn(args, _context) { tool_said(async fn() { Json::string(version_tool(u, args).stringify()) }) },
    },
  ])
  self.admin_ops(u)
  self.op("agents.updates.get", async fn(arg) { of_jv(@jsjson.JValue::Arr(u.get(lang_arg(arg)))) })
  self.op("agents.updates.channel", async fn(_arg) { Json::string(u.channel()) })
  // (agents.ts's hub: a runtime's command not found where it was asked, `runtimeMissing`; what of the machine's Codex
  // is installed; the machine's Codex updated where a session found it too old to serve, `updateOldCodex`)
  self.op("updates.runtimeMissing", async fn(arg) {
    u.missing(match arg { Array([String(k), ..]) => k; _ => jtext_or_empty(arg, "runtime") })
    Json::null()
  })
  self.op("updates.version", async fn(arg) {
    let id = match arg { Array([String(k), ..]) => k; _ => jtext_or_empty(arg, "id") }
    let found = u.get("zh").iter().find_first(r => of_jv(r) is Object(m) && m.get("id") == Some(Json::string(id)))
    match found {
      Some(r) =>
        match jfield(of_jv(r), "version") {
          String(_) as v => v
          _ => Json::null()
        }
      None => Json::null()
    }
  })
  self.op("updates.updateOldCodex", async fn(arg) {
    let before = as_text(jfield(arg, "running"))
    u.update_old_codex(before, (bus.lang.val)()) catch {
      e => return { "error": Json::string(p55_said_of(e)) }
    }
    Json::null()
  })
  self.op("updates.missing", async fn(arg) {
    u.missing(match arg { Array([String(k), ..]) => k; _ => jtext_or_empty(arg, "runtime") })
    Json::null()
  })
  // `stillfail update --beta|--stable` asks a running station by SIGHUP (run/channel-ask): the control channel's `hup`,
  // which the launcher's line is told the bus as `updates.hup`.
  self.op("updates.hup", async fn(_arg) {
    u.answer_channel_ask()
    Json::null()
  })
}

///|
/// api/routes/updates.ts: the station's and its runtimes' versions read again, the channel or updating by itself set,
/// one of them updated; for a workspace's owner or admin. Each answers the versions as they are after it.
fn updates_routes(u : @updates.Updates) -> Array[PartRoute] {
  let answer = (f : async (Json) -> Unit) => async fn(r : Json) -> Json {
    let lang = lang_in(r)
    if !manages(jfield(r, "viewer")) {
      return refused(403, @updates.tr(lang, "station.admin.updatesManagersOnly"))
    }
    match (try { Ok(f(r)) } catch { e => Err(e) }) {
      Ok(_) => answered(200, of_jv(@jsjson.JValue::Arr(u.get(lang))))
      Err(e) => refused(400, message_text(e))
    }
  }
  [
    p55_route("POST", "^/updates/check$", answer(async fn(_r) { u.check() })),
    p55_route("POST", "^/updates/channel$", answer(async fn(r) {
      let lang = lang_in(r)
      match jfield(jfield(r, "body"), "channel") {
        String(c) if @updates.channel_of_id(c) is Some(ch) => u.set_channel(ch, lang)
        _ => raise BusError(@updates.tr(lang, "station.admin.badChannel"))
      }
    })),
    p55_route("POST", "^/updates/auto$", answer(async fn(r) {
      let lang = lang_in(r)
      match jfield(jfield(r, "body"), "on") {
        True => u.set_auto(true, lang)
        False => u.set_auto(false, lang)
        _ => raise BusError(@updates.tr(lang, "station.admin.badOn"))
      }
    })),
    p55_route("POST", "^/updates/wait$", answer(async fn(r) {
      let lang = lang_in(r)
      match jfield(jfield(r, "body"), "wait") {
        Null => u.set_wait(None, lang)
        Array(xs) => {
          let parsed : Array[@updates.WaitCondition] = []
          for x in xs {
            match x {
              String(s) => parsed.push(@updates.parse_wait_spec(s))
              _ => raise BusError("wait: string[] or null")
            }
          }
          u.set_wait(Some(parsed), lang)
        }
        _ => raise BusError("wait: string[] or null")
      }
    })),
    p55_route("POST", "^/updates$", answer(async fn(r) {
      let lang = lang_in(r)
      let body = jfield(r, "body")
      let id = jtext_or_empty(body, "id")
      // The station put back to a release before it: { id, to }.
      let to = match jfield(body, "to") {
        Null => None
        String(t) => Some(t)
        _ => raise BusError(@updates.tr(lang, "station.updates.badVersion"))
      }
      match jfield(body, "repair") {
        True if id == "codex" => u.repair_codex(lang)
        Null | False => u.update(id, lang, to?)
        _ => raise BusError(@updates.tr(lang, "station.updates.codexRepairUnavailable"))
      }
    })),
  ]
}

///|
/// An error's words as a person reads them (updates' `Error` objects say their message).
fn message_text(e : Error) -> String {
  match e {
    BusError(m) => m
    e => @updates.message_of(e)
  }
}

///|
/// A directory's changes, told by the name that changed (Node's `fs.watch` of a directory, which the shell keeps none
/// of): what it holds looked at every P55_WATCH_MS, each entry's size and time, until what it gives is called.
fn p55_watch_dir(bus : LiveBus, dir : String, told : (String?) -> Unit) -> async () -> Unit {
  let host = bus.host
  let going = Ref(true)
  let look = async fn() -> Map[String, String] {
    let now : Map[String, String] = Map([])
    for e in host_readdir_types(host, dir).unwrap_or([]) {
      let full = @nodepath.join(sep(), [dir, e.0])
      match (try { Ok(host.shell("fs.meta", { "path": Json::string(full) })) } catch { e => Err(e) }) {
        Ok((m, _)) => now[e.0] = "\{jnum_of(m, "size").unwrap_or(0.0)}:\{jnum_of(m, "mtimeMs").unwrap_or(0.0)}"
        Err(_) => now[e.0] = ""
      }
    }
    now
  }
  fork_bg(host, "a watched directory", async fn() {
    let mut before = look()
    while going.val && !bus.stopped.is_done() {
      @effect.sleep(p55_watch_ms) // timer: an outside system that offers no push (another process's files; the shell keeps no watch)
      if !going.val {
        break
      }
      let now = look()
      for k, v in now {
        if before.get(k) != Some(v) {
          told(Some(k))
        }
      }
      for k, _ in before {
        if !now.contains(k) {
          told(Some(k))
        }
      }
      before = now
    }
  })
  async fn() { going.val = false }
}

///|
let p55_watch_ms : Int = 250

///|
/// station_version (tools/version.ts `VERSION_TOOL`), as it is declared to the agents.
let version_declared : String =
  #|{
  #|  "name": "station_version",
  #|  "description": "This station's release: list (version, latest, earlier, override/wait), update to latest, back to an earlier one, or wait until a PR/fix/commit/version ships.",
  #|  "inputSchema": {
  #|    "type": "object",
  #|    "properties": {
  #|      "action": {
  #|        "enum": [
  #|          "list",
  #|          "update",
  #|          "back",
  #|          "wait"
  #|        ]
  #|      },
  #|      "to": {
  #|        "type": "string",
  #|        "description": "back: a version from list's earlier."
  #|      },
  #|      "until": {
  #|        "type": "array",
  #|        "items": {
  #|          "type": "string"
  #|        },
  #|        "description": "wait: conditions (pr:N, fix:FB-N, commit:SHA, version:0.1.N, after:0.1.N)."
  #|      },
  #|      "clear": {
  #|        "type": "boolean",
  #|        "description": "wait: clear wait conditions."
  #|      }
  #|    },
  #|    "required": [
  #|      "action"
  #|    ],
  #|    "additionalProperties": false
  #|  }
  #|}

///|
/// What station_version says of the station's line (tools/version.ts `said`), and what an action does.
async fn version_tool(u : @updates.Updates, args : Json) -> Json {
  let line = () => {
    let v = match u.get("en").map(of_jv).search_by(l => jtext_or_empty(l, "id") == "station") {
      Some(i) => u.get("en").map(of_jv)[i]
      None => return Map::new()
    }
    let or_null = (k : String) => match jfield(v, k) {
      Null => Json::null()
      x => x
    }
    let m : Map[String, Json] = {
      "version": or_null("version"),
      "latest": or_null("latest"),
      "newer": jfield(v, "newer"),
      "channel": or_null("channel"),
      "auto": or_null("auto"),
      "autoAfter": or_null("autoAfter"),
      "earlier": match jfield(v, "earlier") {
        Array(_) as e => e
        _ => Json::array([])
      },
      "state": jfield(v, "state"),
    }
    for k in ["progress", "message", "note", "overrideBase", "overrideKind", "overrideNote"] {
      match jfield(v, k) {
        String(t) if t != "" => m[k] = Json::string(t)
        _ => ()
      }
    }
    for k in ["overridden", "autoHeld"] {
      match jfield(v, k) {
        True => m[k] = Json::boolean(true)
        _ => ()
      }
    }
    match jfield(v, "autoWhen") {
      Array(xs) if xs.length() > 0 => m["autoWhen"] = Json::array(xs)
      _ => ()
    }
    m
  }
  let started = () => {
    let m : Map[String, Json] = { "started": Json::boolean(true) }
    for k, x in line() {
      m[k] = x
    }
    Json::object(m)
  }
  match jfield(args, "action") {
    String("list") => Json::object(line())
    String("update") => {
      u.update("station", "en")
      started()
    }
    String("back") => {
      let to = match jfield(args, "to") {
        String(t) if t != "" => t
        _ => raise BusError("to: a version list names in earlier")
      }
      u.update("station", "en", to~)
      started()
    }
    String("wait") =>
      match jfield(args, "clear") {
        True => {
          u.set_wait(None, "en")
          Json::object(line())
        }
        _ =>
          match jfield(args, "until") {
            Array(xs) => {
              let parsed : Array[@updates.WaitCondition] = []
              for x in xs {
                match x {
                  String(s) => parsed.push(@updates.parse_wait_spec(s))
                  _ => raise BusError("wait: pass until (array of conditions) or clear: true")
                }
              }
              u.set_wait(Some(parsed), "en")
              Json::object(line())
            }
            _ => raise BusError("wait: pass until (array of conditions) or clear: true")
          }
      }
    _ => raise BusError("action: list, update, back or wait")
  }
}

///|
/// rig/main.ts: a station that only runs tasks keeps its own release up to date (read at start and as the cloud says
/// one is out, updated by itself while nothing runs, its channel asked by SIGHUP), with none of P5-5's other parts.
/// What the other slices ask on `coord_ask` that it does not answer is answered none, as before it was made.
pub async fn start_rig_updates(bus : LiveBus) -> Unit {
  let p : P55 = { bus, ops: Map([]), prefix_ops: [], updates: None, closers: [], pages: Map([]), next_page: 0 }
  bus.coord_ask.val = async fn(op, arg) {
    if p.ops.contains(op) {
      p.ask(op, arg)
    } else {
      Json::null()
    }
  }
  p.start_updates(rig=true) catch {
    e => err_write("station: the updates part is not made: \{p55_said_of(e)}\n")
  }
  fork_bg(bus.host, "rig updates close", async fn() {
    ignore(bus.stopped.wait())
    for c in p.closers.rev() {
      c() catch {
        _ => ()
      }
    }
  })
}
