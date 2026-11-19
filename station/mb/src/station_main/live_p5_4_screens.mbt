// The screens members see and drive (services.ts `ScreenRegistry`: screens' `ScreenHub`), with this machine's display
// among them from the start: macOS's through still.fail Helper (`Helper`, its `Grants`) with the iOS Simulators booted
// on it, Windows' through stillfail-screen, Linux's the station user's desktop session; the browsers' tabs added as
// they open. The agents' `screen` and `computer` tools (mcp_tools') ask the hub by name over the objects it gives (a
// source, a view: `{"$ref": …}`), answered here (`P54Screens::ask`), as every other part asks them through `ui_ask`.

///|
/// The machine's processes as the screens' parts ask them (screens `Procs`): a child followed by its events, a command
/// run to its end (refused, saying how it ended, where it fails).
fn p54_screen_procs(host : @host.Host) -> @screens.Procs {
  {
    spawn: (program, args, o, ev) => {
      let env = o.env.map(e => e.pairs)
      let ended : Ref[Bool] = Ref(false)
      let input_open = Ref(o.stdio.0 == "pipe")
      let child = p54_spawn(
        host,
        program,
        args,
        env?,
        stdin_piped=o.stdio.0 == "pipe",
        group=o.group,
        out=ev.out,
        err=ev.err,
        close=(code, signal) => {
          ended.val = true
          (ev.close)(code, signal)
        },
      ) catch {
        e => {
          (ev.error)(p54_message(e))
          (ev.close)(None, None)
          return {
            pid: () => None,
            write: (_, done) => match done {
              Some(d) => d(Some("not started"))
              None => ()
            },
            end_input: _ => (),
            destroy_input: () => (),
            input_open: () => false,
            kill: _ => (),
            running: () => false,
          }
        }
      }
      let pid = child.proc.pid
      {
        pid: () => Some(pid),
        write: (b, done) => {
          let ok = child.proc.write(b)
          match done {
            Some(d) => d(if ok { None } else { Some("its input is closed") })
            None => ()
          }
        },
        end_input: last => {
          if last is Some(b) { ignore(child.proc.write(b)) }
          input_open.val = false
          child.proc.end_input()
        },
        destroy_input: () => {
          input_open.val = false
          child.proc.end_input()
        },
        input_open: () => input_open.val && !ended.val,
        kill: signal => ignore(kill(pid, if signal == "" { "SIGTERM" } else { signal }, group=o.group)),
        running: () => !ended.val,
      }
    },
    exec: async fn(program, args, o) {
      let env = o.env.map(e => e.pairs)
      let proc = spawn(host, program, args, env?, stdout=Piped, stderr=Piped, group=true) catch {
        e =>
          raise @screens.ExecFailed(
            message=p54_message(e),
            code=@jsjson.JValue::Str(@jsjson.units("ENOENT")),
            signal=None,
            stdout="",
            stderr="",
          )
      }
      let ms = match o.timeout {
        Some(t) if t > 0.0 && t < 2147483647.0 => t.to_int()
        _ => 2147483647
      }
      match @effect.timeout(ms, async fn() { proc.finished() }) {
        Some((code, signal, out, err)) => {
          let stdout = @utf8.decode_lossy(out)
          let stderr = @utf8.decode_lossy(err)
          if code == Some(0) {
            stdout
          } else {
            raise @screens.ExecFailed(
              message="Command failed: \{program} \{args.join(" ")}\n\{stderr}",
              code=match code {
                Some(c) => @jsjson.JValue::Num(c.to_double())
                None => @jsjson.JValue::Null
              },
              signal~,
              stdout~,
              stderr~,
            )
          }
        }
        None => {
          ignore(kill(proc.pid, "SIGTERM", group=true))
          raise @screens.ExecFailed(
            message="Command timed out: \{program}",
            code=@jsjson.JValue::Null,
            signal=Some("SIGTERM"),
            stdout="",
            stderr="",
          )
        }
      }
    },
  }
}

///|
/// The machine as the screens' parts know it (screens `Os`).
fn p54_screen_os(bus : LiveBus) -> @screens.Os {
  p54_screen_os_of(bus.argv0)
}

///|
/// `p54_screen_os` of the program at `argv0`.
fn p54_screen_os_of(argv0 : String) -> @screens.Os {
  let env = () => @screens.Env::new(env_all())
  let code_dir = @nodepath.dirname(sep(), @drive.real_of(argv0))
  let os = match platform() {
    "darwin" => "darwin"
    "windows" => "win32"
    p => p
  }
  {
    hostname: () => hostname(),
    tmpdir: () => tmpdir(),
    homedir: () => homedir(),
    arch: arch(),
    os,
    uid: Some(@drive.uid()),
    exec_path: argv0,
    pid: @drive.pid(),
    env,
    runnable: (file, args, _) => { file, args, verbatim: false },
    runnable_soon: async fn(file, args, _) { { file, args, verbatim: false } },
    mounts_soon: async fn() { [] },
    date_parse: s => @screens.date_parse_utc(s),
    cwd: @drive.cwd(),
    code_dir,
  }
}

///|
fn p54_screen_words() -> @screens.Words {
  {
    tr: (lang, key, args) => {
      let given = match of_jv(args) {
        Object(m) => m.iter().map(kv => (kv.0, match kv.1 { String(s) => s; v => v.stringify() })).collect()
        _ => []
      }
      tr(lang, key, args=given)
    },
    station_lang: () => "zh",
  }
}

///|
/// The hub, its sources and the views the agents opened, by the names the tools ask them by.
priv struct P54Screens {
  bus : LiveBus
  hub : @screens.ScreenHub
  io : @screens.Io
  helper : @screens.HelperApp?
  grants : @screens.HelperGrants?
  files : @screens.HelperFiles?
  views : Map[String, @screens.ScreenView]
  debugs : Map[String, @screens.SimDebug]
  mut next_view : Int
}

///|
/// How still.fail Helper of `dir` is launched (`opened`: by LaunchServices), one holding its lock with no socket ended
/// first (`p54_helper_evict`).
fn p54_helper_launch(
  host : @host.Host,
  dir : String,
  opened : async (String, Array[(String, String)]) -> Unit,
) -> async (String, Array[(String, String)]) -> Unit {
  async fn(app_path, env) {
    p54_helper_evict(host, dir)
    opened(app_path, env)
  }
}

///|
/// Before still.fail Helper is launched (no helper answered its socket): one of this directory's that still holds its
/// lock (`helper.lock`) with its socket gone would make the one launched exit at once, every launch after it too, so it
/// is ended first. Its pid is said in the lock by a helper of now; one from before left it empty, found by `lsof`.
/// Only a `stillfail-helper` that is this directory's is ended: its command in it (the copy installed here, as
/// LaunchServices starts it), or the lock open in it as `lsof` says.
async fn p54_helper_evict(host : @host.Host, dir : String) -> Unit {
  let lock = path([dir, "helper.lock"])
  let pids : Array[Int] = []
  let add = (t : String) => for line in t.split("\n") {
    let n = @string.parse_int(line.trim().to_owned()) catch { _ => continue }
    if n > 1 && n != @drive.pid() && !pids.contains(n) {
      pids.push(n)
    }
  }
  match read_text(lock) {
    Some(t) => add(t)
    None => return
  }
  let by_lsof = pids.is_empty()
  if by_lsof {
    if p53_run(host, "lsof", ["-t", "--", lock], timeout_ms=2000) is Some(t) { add(t) }
  }
  for pid in pids {
    guard p53_run(host, "ps", ["-ww", "-p", pid.to_string(), "-o", "command="], timeout_ms=2000) is Some(command) else {
      continue
    }
    let here = by_lsof ||
      command.contains(dir) ||
      (p53_run(host, "lsof", ["-t", "-a", "-p", pid.to_string(), "--", lock], timeout_ms=2000) is Some(t) && t.trim() != "")
    if here && command.contains("stillfail-helper") {
      p51_log("WARN", "helper", "ending a still.fail Helper that holds its lock with no socket", fields={ "pid": Json::number(pid.to_double()) })
      ignore(kill(pid, "SIGKILL"))
      @effect.sleep(100)
    }
  }
}

///|
/// The screens made (services.ts `Helper`, `Grants`, `HelperFolders`, `ScreenRegistry`), each list's change told.
fn p54_screens_start(bus : LiveBus) -> P54Screens {
  let host = bus.host
  let io = @screens.host_io(host, p54_screen_procs(host), p54_screen_os(bus), p54_screen_words(), now=Some(() => wall_ms().to_double()))
  let downloads = path([homedir(), "Downloads"])
  let hub = @screens.ScreenHub::new(io, drop=Some(() => if (try { Ok(@drive.stat(downloads)) } catch { e => Err(e) }) is Ok(_) { Some(downloads) } else { None }))
  let mac = platform() == "darwin"
  let env = @screens.Env::new(env_all())
  let helper = if mac {
    match @screens.helper_app(io, env) {
      Some(app) => {
        let dir = path([bus.data, "helper"])
        Some(@screens.HelperApp::new(io, app, dir, launch=Some(p54_helper_launch(host, dir, @screens.open_app(io)))))
      }
      None => None
    }
  } else {
    None
  }
  let grants = match helper {
    Some(h) => Some(@screens.HelperGrants::new(io, h, async fn() { None }, folders=true))
    None => None
  }
  let files = match helper {
    Some(h) =>
      Some(@screens.HelperFiles::new(io, h, () => (bus.overview_changed.val)(), async fn() { None }, lang=Some(() => (bus.lang.val)()), grants~))
    None => None
  }
  let changed = () => hub.changed()
  let title = match env_get("STILLFAIL_TEST_HOST") {
    Some("1") => Some(() => "test-station")
    _ => None
  }
  let fork = (f : async () -> Unit) => ignore(host.rt.fork_quiet(name="screens", async fn() { f() catch { _ => () } }))
  match platform() {
    "win32" => {
      let desktop = @screens.WindowsDesktop::new(io, {
        binary: @screens.screen_binary(io, env),
        ui: @screens.ui_binary(io, env),
        changed,
        title,
        start: None,
      })
      ignore(hub.add(desktop.source()))
      ignore(hub.refresher(async fn() { desktop.refresh() }))
    }
    "linux" => {
      let desktop = @screens.LinuxDesktop::new(io, { data: bus.data, changed, title, env: None, discover: None })
      ignore(hub.add(desktop.source()))
      ignore(hub.refresher(async fn() { desktop.refresh() }))
    }
    _ => {
      let desktop = @screens.Desktop::new(io, {
        supported: helper is Some(_),
        helper,
        grants,
        reach: async fn() { None },
        changed,
        title,
        lang: Some(() => (bus.lang.val)()),
        synthetic: None,
      })
      match helper {
        Some(h) => ignore(h.on_back(() => fork(async fn() { desktop.helper_back() })))
        None => ()
      }
      ignore(hub.add(desktop.source()))
      ignore(hub.refresher(async fn() { desktop.refresh() }))
      // The iOS Simulators booted on this Mac, each a screen while it is.
      if mac {
        let simulators = @screens.Simulators::new(io, s => hub.add(s), helper)
        fork(async fn() { simulators.start() })
        ignore(hub.refresher(async fn() { simulators.refresh() }))
      }
    }
  }
  // The screens' list changed: told on the members' streams (api/events.ts `screens`).
  ignore(hub.watch(_ => {
    (bus.events_tell.val)("screens", of_jv(hub.listed((bus.lang.val)())), "screens", Json::object({}))
    (bus.overview_changed.val)()
  }))
  match grants {
    Some(g) => ignore(g.on_change(() => (bus.overview_changed.val)()))
    None => ()
  }
  { bus, hub, io, helper, grants, files, views: Map([]), debugs: Map([]), next_view: 0 }
}

///|
fn p54_api_jv(j : Json) -> @api_routes.JV {
  @api_routes.parse(j.stringify()) catch {
    _ => @api_routes.JV::Null
  }
}

///|
fn p54_of_api(v : @api_routes.JV) -> Json {
  @json.parse(@api_routes.stringify(v)) catch {
    _ => Json::null()
  }
}

///|
fn p54_ref(name : String) -> Json {
  { "$ref": Json::string(name) }
}

///|
fn p54_ref_of(v : Json?) -> String? {
  opt_text(v, "$ref")
}

///|
/// What a screen refused, as the tools take it (`Thrown("ScreenRefused", {status, key, args, access, message})`).
fn p54_screen_thrown(e : Error) -> Error {
  match e {
    @screens.ScreenRefused(status~, key~, args~, access~, message~) => {
      let said : Map[String, Json] = {
        "status": Json::number(status.to_double()),
        "key": Json::string(key),
        "args": of_jv(args),
        "message": Json::string(message),
      }
      if access is Some(a) { said["access"] = of_jv(a.to_j()) }
      P54Refused("ScreenRefused", Json::object(said))
    }
    other => other
  }
}

///|
fn p54_view_options(j : Json?) -> @screens.ViewOptions {
  @screens.view_options_of(to_jv(j.unwrap_or(Json::object({}))))
}

///|
fn p54_view_shown(v : Json?) -> @screens.ViewShown {
  {
    id: opt_text(v, "id").unwrap_or(""),
    name: opt_text(v, "name").unwrap_or(""),
    control: opt_true(opt_field(v, "control")),
    at: opt_num(opt_field(v, "at")).unwrap_or(0.0),
    device: opt_text(v, "device"),
    self_: opt_text(v, "self"),
    client: opt_text(v, "client"),
    app: opt_text(v, "app"),
    agent: opt_true(opt_field(v, "agent")),
  }
}

///|
/// A frame as the tools take it: its config, whether a key frame, its time and its bytes (`$bytes`).
fn p54_frame_json(f : @screens.Frame) -> Json {
  let out : Map[String, Json] = {
    "key": Json::boolean(f.key),
    "ts": Json::number(f.ts),
    "data": p54_bytes_json(f.data),
  }
  if f.config is Some(c) { out["config"] = of_jv(c.to_j()) }
  Json::object(out)
}

///|
/// What is asked of the screens by name: the hub's (`screens.<method>`), a source's (`screen:<id>.<method>`), a
/// view's (`view:<n>.<method>`), and the hub's pure helpers; None where it is not the screens'.
async fn P54Screens::ask(self : P54Screens, op : String, a : Json) -> Json? {
  let s = (i : Int) => call_arg_text(a, i)
  let hub = self.hub
  let answer : Json = try {
    // A member's view of a screen, answered while it lasts (P5-1's `member_screens`).
    if op == "screens.view" {
      p54_screen_view(self, a)
      return Some(Json::boolean(true))
    }
    if op == "$source" {
      match p54_ref_of(call_arg(a, 0)) {
        Some(r) if r.has_prefix("screen:") =>
          match hub.get(r[7:].to_owned()) {
            Some(src) =>
              {
                "id": Json::string(src.id),
                "userTab": Json::boolean(src.user_tab),
                "access": Json::boolean(src.access is Some(_)),
                "ui": Json::boolean(src.ui is Some(_)),
              }
            None => Json::null()
          }
        _ => Json::null()
      }
    } else if op.has_prefix("screens/") {
      match op {
        "screens/hub.accessShown" => {
          let access = match call_arg(a, 0) {
            Some(Object(_) as acc) =>
              Some(
                @screens.ScreenAccess::new(
                  opt_true(opt_field(Some(acc), "capture")),
                  opt_true(opt_field(Some(acc), "control")),
                  unsupported=jtext(acc, "unsupported"),
                  reason=jtext(acc, "reason"),
                  app=jtext(acc, "app"),
                  path=jtext(acc, "path"),
                  asking=opt_true(opt_field(Some(acc), "asking")),
                ),
              )
            _ => None
          }
          match @screens.access_shown(p54_screen_words(), access, s(1)) {
            Some(shown) => of_jv(shown.to_j())
            None => Json::null()
          }
        }
        "screens/hub.viewOn" => Json::string(@screens.view_on(p54_view_shown(call_arg(a, 0)), wall_ms().to_double()))
        "screens/ui.treeText" => Json::string(@screens.tree_text(to_jv(call_arg(a, 0).unwrap_or(Json::null()))))
        _ => return None
      }
    } else if op.has_prefix("screens.") {
      match op[8:].to_owned() {
        "get" =>
          match hub.get(s(0)) {
            Some(src) => {
              let m : Map[String, Json] = { "$ref": Json::string("screen:" + src.id), "id": Json::string(src.id) }
              // (what the routes tell a screen's kinds apart by: one that opens an address, one that is debugged)
              if src.open_url is Some(_) {
                m["openUrl"] = Json::boolean(true)
              }
              if src.debug is Some(_) {
                m["debug"] = Json::boolean(true)
              }
              Json::object(m)
            }
            None => Json::null()
          }
        "list" => Json::array(hub.list().map(src => { "id": Json::string(src.id), "$ref": Json::string("screen:" + src.id) }))
        "listed" => of_jv(hub.listed(s(0)))
        "people" => of_jv(hub.people(s(0)))
        "refresh" => {
          hub.refresh()
          Json::null()
        }
        "whenStopping" => Json::null()
        "takeControl" => Json::number(hub.take_control(s(0), by=opt_str(call_arg(a, 1))).to_double())
        "endView" => {
          hub.end_view(s(0), s(1), s(2))
          Json::null()
        }
        "endViews" => Json::number(hub.end_views(s(0), s(1)).to_double())
        "watchOnly" => {
          hub.watch_only(s(0), s(1))
          Json::null()
        }
        "openAs" => {
          let who = call_arg(a, 2)
          let view = hub.open_as(s(0), p54_view_options(call_arg(a, 1)), opt_text(who, "name").unwrap_or("agent"), opt_true(opt_field(who, "control")))
          self.next_view += 1
          let name = "view:\{self.next_view}"
          self.views[name] = view
          p54_ref(name)
        }
        "openBrowser" => Json::string(hub.open_browser(s(0), id=opt_str(call_arg(a, 1))))
        "openUrl" => {
          hub.open_url(s(0), s(1))
          Json::null()
        }
        "closeScreen" => {
          hub.close_screen(s(0))
          Json::null()
        }
        "reloadScreen" => {
          hub.reload_screen(s(0))
          Json::null()
        }
        "sleepScreen" => {
          hub.sleep_screen(s(0))
          Json::null()
        }
        "historyScreen" => {
          hub.history_screen(s(0), opt_num(call_arg(a, 1)).unwrap_or(0.0).to_int())
          Json::null()
        }
        "debugOf" => {
          let id = s(0)
          self.debugs[id] = hub.debug_of(id)
          p54_ref("debug:" + id)
        }
        _ => return None
      }
    } else if op.has_prefix("screen:") {
      guard op.rev_find(".") is Some(dot) else { return None }
      let id = op[7:dot].to_owned()
      let meth = op[dot + 1:].to_owned()
      guard hub.get(id) is Some(src) else { raise @screens.ScreenRefused(status=404, key="station.screen.notFound", args=@jsjson.JValue::Obj([]), access=None, message="no such screen") }
      match meth {
        "access" =>
          match src.access {
            Some(f) => of_jv(f().to_j())
            None => Json::null()
          }
        "size" => {
          let (w, h) = (src.size)()
          { "width": Json::number(w), "height": Json::number(h) }
        }
        "title" => Json::string((src.title)())
        "ui" =>
          match src.ui {
            Some(f) => of_jv(f(opt_strs(call_arg(a, 0))))
            None => Json::null()
          }
        _ => return None
      }
    } else if op.has_prefix("debug:") {
      guard op.rev_find(".") is Some(dot) else { return None }
      let id = op[6:dot].to_owned()
      let meth = op[dot + 1:].to_owned()
      let d = match self.debugs.get(id) {
        Some(d) => d
        None => {
          let d = hub.debug_of(id)
          self.debugs[id] = d
          d
        }
      }
      let arg = (i : Int) => call_arg(a, i)
      match meth {
        "logs" => {
          let (next, lines) = d.logs(opt_num(arg(0)).unwrap_or(0.0))
          { "next": Json::number(next.to_double()), "lines": Json::array(lines.map(l => of_jv(l.to_j()))) }
        }
        "apps" => Json::array(d.apps().map(x => of_jv(x.to_j())))
        "relaunch" => Json::boolean(d.relaunch(s(0)))
        "settings" => of_jv(d.settings())
        "setSetting" => Json::boolean(d.set_setting(s(0), s(1)))
        "openUrl" => Json::boolean(d.open_url(s(0)))
        "location" => Json::boolean(d.location(opt_str(arg(0))))
        "statusBar" => {
          d.status_bar(opt_true(arg(0)))
          Json::null()
        }
        "push" => Json::boolean(d.push(s(0), s(1)))
        "installFolder" => Json::string(d.install_folder())
        "install" => jopt(d.install(s(0)))
        "uninstall" => Json::boolean(d.uninstall(s(0)))
        "biometrics" => Json::boolean(d.biometrics(s(0)))
        "recordStart" => {
          d.record_start(opt_str(arg(0)))
          Json::null()
        }
        "recording" => Json::boolean(d.recording())
        "recordStop" =>
          match d.record_stop() {
            Some((root, file)) => { "root": Json::string(root), "path": Json::string(file) }
            None => Json::null()
          }
        "screenshot" => p54_bytes_json(d.screenshot())
        "close" => {
          d.close()
          self.debugs.remove(id)
          Json::null()
        }
        _ => return None
      }
    } else if op.has_prefix("view:") {
      guard op.rev_find(".") is Some(dot) else { return None }
      let name = op[:dot].to_owned()
      let meth = op[dot + 1:].to_owned()
      guard self.views.get(name) is Some(view) else { return Some(Json::null()) }
      match meth {
        "next" =>
          match (view.next)() {
            Some(f) => p54_frame_json(f)
            None => Json::null()
          }
        "input" => {
          if @screens.input_of(to_jv(call_arg(a, 0).unwrap_or(Json::null()))) is Some(i) { (view.input)(i) }
          Json::null()
        }
        "keyframe" => {
          (view.keyframe)()
          Json::null()
        }
        "close" => {
          (view.close)()
          self.views.remove(name)
          Json::null()
        }
        _ => return None
      }
    } else if op.has_prefix("helper/grants.") || op.has_prefix("grants.") || op.has_prefix("helper/files.") {
      match op {
        "helper/grants.isGrant" => Json::boolean(@screens.is_grant(s(0)))
        "helper/files.askWords" => of_jv(@screens.files_words(self.io, s(0)))
        "grants.request" =>
          match self.grants {
            Some(g) => {
              let (state, asked) = g.request(s(0), to_jv(call_arg(a, 1).unwrap_or(Json::null())), again=opt_true(call_arg(a, 2)))
              { "state": Json::string(state), "asked": Json::boolean(asked) }
            }
            None => Json::null()
          }
        "grants.status" =>
          match self.grants {
            Some(g) => g.status().map(of_jv).unwrap_or(Json::null())
            None => Json::null()
          }
        "grants.view" =>
          match self.grants {
            Some(g) => g.view().map(of_jv).unwrap_or(Json::null())
            None => Json::null()
          }
        // (the permissions tool's: Helper asked again, `force` where the person changed one in System Settings)
        "grants.refresh" =>
          match self.grants {
            Some(g) => {
              g.refresh(force=opt_true(call_arg(a, 0)))
              Json::null()
            }
            None => Json::null()
          }
        _ => return None
      }
    } else {
      return None
    }
  } catch {
    e => raise p54_screen_thrown(e)
  }
  Some(answer)
}

///|
/// The agents' `screen` and `computer` tools (tools/screen.ts, tools/computer.ts: mcp_tools'), each asking the screens
/// by name as P54Screens answers, the rest of what they ask (who an agent is, the station's pages) through the bus.
async fn p54_screen_tools(bus : LiveBus, s : P54Screens) -> Unit {
  let (zh, en) = catalogs_json()
  let words = @api_routes.Words::new(p54_api_jv(zh), p54_api_jv(en))
  let backend = @mcp_tools.ToolsBackend::new(async fn(op, args) {
    let a = Json::array(args.map(p54_of_api))
    match op {
      "agentName" => p54_api_jv(Json::string("agent"))
      "base" =>
        match ((bus.cloud_state.val)(), p54_home(bus), p54_station_id(bus)) {
          (Some(st), Some(w), Some(id)) =>
            match jtext(st, "origin") {
              Some(o) => p54_api_jv(Json::string("\{o}/w/\{w}/s/\{id}"))
              None => @api_routes.JV::Null
            }
          _ => @api_routes.JV::Null
        }
      _ =>
        match (try { Ok(s.ask(op, a)) } catch { e => Err(e) }) {
          Ok(Some(v)) => p54_api_jv(v)
          Ok(None) => p54_api_jv((bus.ui_ask.val)(op, a))
          // (a refusal as the tools take it: mcp_tools' `thrown_as`)
          Err(P54Refused(kind, said)) => raise @api_routes.Thrown(kind, p54_api_jv(said))
          Err(e) => raise e
        }
    }
  })
  let ctx = @mcp_tools.Ctx::new(backend, words, {
    runtime_kinds: [],
    station_lang: (bus.lang.val)(),
    os: p54_os(),
    arch: arch(),
  })
  let computer = @mcp_tools.Computer::new(ctx)
  let tools = @mcp_tools.screen_tools(ctx) + @mcp_tools.computer_tools(computer)
  bus.parts.tools(
    tools.map(t => {
      let declared = p54_of_api(@mcp_tools.declared(t))
      ({
        name: t.name,
        declared,
        call: async fn(args, context) {
          let session = p54_session(context)
          match t.content {
            Some(content) => {
              let reply = content(session, p54_api_jv(args)) catch {
                e => return tool_answer(p54_message(e), error=true)
              }
              let parts = reply.content.map(c => match c {
                Text(text) => ({ "type": "text", "text": Json::string(text) } : Json)
                Image(data, mime) => { "type": "image", "data": Json::string(data), "mimeType": Json::string(mime) }
              })
              if reply.is_error {
                { "content": Json::array(parts), "isError": Json::boolean(true) }
              } else {
                { "content": Json::array(parts) }
              }
            }
            None =>
              match (try { Ok((t.run)(session, p54_api_jv(args), p54_api_jv(context))) } catch { e => Err(e) }) {
                Ok(text) => tool_answer(text)
                Err(e) => tool_answer(p54_message(e), error=true)
              }
          }
        },
      } : PartTool)
    }),
  )
  bus.parts.session_ended(session => ignore(bus.host.rt.fork_quiet(name="computer", async fn() {
    computer.close_session(session) catch {
      _ => ()
    }
  })))
}
