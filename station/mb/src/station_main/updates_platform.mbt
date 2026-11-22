// What the updates (station/mb's updates package) ask of the machine beyond its files and the network, as
// platform/unix.ts and windows.ts, agents/cursor.ts and ops/processes.ts answer the TypeScript station: the launcher
// asked (`askLauncher`), Antigravity CLI's build and staging, the station's installer started apart, how a runtime
// found here is updated and its command linked, and a command run to its end (`processes.startCommand`,
// `child_process.spawn`). Both worlds take it: the live station's (live_p5_5_updates.mbt) and the commands' (cli.mbt).
//
// A command is answered whole, as the updates package reads it (`{"$child": [[event, …], …]}`, its `close` last):
// what it said, then how it ended. One that does not end within the longest any caller gives it (`command_most_ms`)
// is ended then, its close saying no code; the caller's own deadline is the shorter, and is told after
// (`processes.endCommand`), by when it has ended.

///|
/// The longest a command the updates run is given (a runtime's update: updates.mbt `default_timing.runtime_limit`;
/// the station's delta: `delta_limit`).
let command_most_ms : Int = 10 * 60000

///|
/// The commands the updates started that still run, by their program (`processes.endCommand` ends them).
let commands_running : Map[String, Array[Proc]] = Map([])

///|
/// Where the runner is looked for (the release, this program, the data directory: `runner_binary`'s), as the updates
/// were set up (`updates_setup`, its release given by the live station).
let updates_runner_from : Ref[(String, String, String)] = Ref(("", "", ""))

///|
/// The runner found for the updates' commands on Windows (none looked for yet: None; looked for: Some of what it found).
let updates_runner : Ref[Option[String?]] = Ref(None)

///|
/// windows.ts `grouped`: `stillfail-runner --job -- <program> <args…>`, whose job ends the command and all it started as
/// the runner is ended (the group a command runs in on Unix), and which runs a `.cmd` shim as cmd would; as it is where
/// no runner is there.
fn updates_grouped(program : String, args : Array[String]) -> (String, Array[String]) {
  let runner = match updates_runner.val {
    Some(found) => found
    None => {
      let (app, argv0, data) = updates_runner_from.val
      let found = runner_binary(app, argv0, data)
      updates_runner.val = Some(found)
      found
    }
  }
  match runner {
    Some(r) => (r, ["--job", "--", program, ..args])
    None => (program, args)
  }
}

///|
/// What the updates ask of the machine, by name; None where it is none of this file's.
async fn updates_platform(host : @host.Host, data : String, name : String, a : Array[Json]) -> Json? {
  let s = (i : Int) => opt_str(a.get(i)).unwrap_or("")
  let env_at = (i : Int) => match a.get(i) {
    Some(Object(m)) => m.to_array().filter_map(kv => if kv.1 is String(v) { Some((kv.0, v)) } else { None })
    _ => []
  }
  match name {
    // (cursor.ts `sdkVersionSoon`: the SDK npm keeps in the station's own prefix, as its package says)
    "cursor.sdkVersionSoon" => {
      let at = if s(0) == "" { data } else { s(0) }
      Some(
        jopt(@agent_runtimes.cursor_sdk_version(host, at)),
      )
    }
    // (unix.ts, windows.ts `isLauncher`: the process of that pid is still.fail's launcher, as `ps` or PowerShell names it)
    "platform.isLauncher" => {
      let pid = match a.get(0) {
        Some(Number(n, ..)) if n > 0.0 && n == n.floor() => n.to_int()
        _ => return Some(Json::boolean(false))
      }
      let (program, args) = if is_windows() {
        ("powershell", ["-NoProfile", "-NonInteractive", "-Command", "(Get-Process -Id \{pid} -ErrorAction Stop).ProcessName"])
      } else {
        ("ps", ["-p", pid.to_string(), "-o", "command="])
      }
      let said = match (try { Ok(spawn(host, program, args, stdout=Piped)) } catch { e => Err(e) }) {
        Ok(child) =>
          match child.finished() {
            (Some(0), _, out, _) => Some(@utf8.decode_lossy(out))
            _ => None
          }
        Err(_) => None
      }
      Some(
        Json::boolean(
          match said {
            Some(t) => if is_windows() { @ops_platform.win_is_launcher(t) } else { @ops_platform.unix_is_launcher(t) }
            None => false
          },
        ),
      )
    }
    // (unix.ts `askLauncher`: a signal; windows.ts: a line on the launcher's own pipe)
    "platform.askLauncher" => {
      let pid = match a.get(0) {
        Some(Number(n, ..)) => n.to_int()
        _ => raise SysError("no launcher's pid given")
      }
      let op = s(1)
      if is_windows() {
        let conn = host.unix_open("\\\\.\\pipe\\stillfail-launcher-\{pid}") catch {
          _ => raise SysError("the launcher's pipe did not open")
        }
        let line = ({ "op": Json::string(op) } : Json).stringify() + "\n"
        conn.socket.write(@utf8.encode(line)) catch {
          e => {
            conn.socket.destroy()
            raise e
          }
        }
        conn.socket.end_write() catch {
          e => {
            conn.socket.destroy()
            raise e
          }
        }
        conn.socket.destroy()
      } else {
        guard @ops_platform.unix_launcher_signal(op) is Some(signal) else { raise SysError("no such ask of the launcher: \{op}") }
        if !kill(pid, signal) {
          raise @updates.thrown("Error", "kill ESRCH", more=[("code", to_jv(Json::string("ESRCH")))])
        }
      }
      Some(Json::null())
    }
    // (unix.ts, windows.ts `agyBuild`: the build of Antigravity CLI this machine runs; none on musl)
    "platform.agyBuild" =>
      Some(
        match
          (if is_windows() {
            match arch() {
              "arm64" => Some("windows_arm64")
              "x64" => Some("windows_amd64")
              _ => None
            }
          } else {
            let musl = file_there("/lib/libc.musl-x86_64.so.1") || file_there("/lib/libc.musl-aarch64.so.1")
            @ops_platform.unix_agy_build(platform(), arch(), musl)
          }) {
          Some(b) => Json::string(b)
          None => Json::null()
        },
      )
    // (`agyStaging`: where its installer stages what it downloads)
    "platform.agyStaging" => {
      let env = env_at(0)
      Some(
        match
          (if is_windows() {
            @ops_platform.win_agy_staging(env, parts => @nodepath.join("\\", parts))
          } else {
            @ops_platform.unix_agy_staging(env, s(1))
          }) {
          Some(p) => Json::string(p)
          None => Json::null()
        },
      )
    }
    // (`startInstaller`: the release's installer, nobody's child here, outliving a handover and a restart)
    "platform.startInstaller" => Some(Json::boolean(start_installer(host, s(0), s(1), env_at(2), s(3))))
    // (`shimUpdate`: how a runtime found here is updated by what installed it; none on macOS and Linux)
    "platform.shimUpdate" => {
      if !is_windows() {
        return Some(Json::null())
      }
      let found = a.get(0).unwrap_or(Json::null())
      let on_path = jtext(found, "onPath").unwrap_or("")
      let real = jtext(found, "real").unwrap_or(on_path)
      let env = env_at(2)
      let winget = match find_command("winget", env) {
        Some(w) => w
        None =>
          match env.search_by(kv => kv.0.to_upper() == "LOCALAPPDATA") {
            Some(i) if env[i].1 != "" => @nodepath.join("\\", [env[i].1, "Microsoft", "WindowsApps", "winget.exe"])
            _ => "winget.exe"
          }
      }
      Some(@ops_platform.win_shim_update(on_path, real, s(1), winget, file_there, find_command("npm", env)))
    }
    // (unix.ts `linkCommand`: `command` linked into `dir` where nothing there has its name; never on Windows)
    "platform.linkCommand" => {
      if is_windows() {
        return Some(Json::boolean(false))
      }
      let command = s(0)
      let link = path([s(1), @nodepath.basename(sep(), command)])
      if (try { Ok(@drive.lstat(link)) } catch { e => Err(e) }) is Ok(_) {
        return Some(Json::boolean(false))
      }
      // (made only where nothing has its name, as symlink() refuses one made meanwhile: nothing replaced)
      Some(Json::boolean((try { Ok(host.shell("fs.symlink", { "path": Json::string(link), "target": Json::string(command) })) } catch { e => Err(e) }) is Ok(_)))
    }
    // (ops/processes.ts `startCommand`, child_process `spawn`: a command run to its end, what it said and how it ended)
    "processes.startCommand" | "child_process.spawn" => {
      let opts = a.get(2).unwrap_or(Json::null())
      let env = match jfield(opts, "env") {
        Object(m) => Some(m.to_array().filter_map(kv => if kv.1 is String(v) { Some((kv.0, v)) } else { None }))
        _ => None
      }
      let cwd = jtext(opts, "cwd")
      let args = match a.get(1) {
        Some(Array(xs)) => xs.filter_map(x => if x is String(t) { Some(t) } else { None })
        _ => []
      }
      Some(command_events(host, s(0), args, env, cwd))
    }
    _ => None
  }
}

///|
/// What the updates tell the machine, by name (`processes.endCommand`): true where it was this file's.
fn updates_platform_told(name : String, a : Array[Json]) -> Bool {
  match name {
    "processes.endCommand" => {
      let program = opt_str(a.get(0)).unwrap_or("")
      let signal = match a.get(1) {
        Some(String(t)) => t
        _ => "SIGTERM"
      }
      match commands_running.get(program) {
        Some(procs) => for p in procs { ignore(kill(p.pid, signal, group=true)) }
        None => ()
      }
      true
    }
    _ => false
  }
}

///|
fn file_there(p : String) -> Bool {
  (try { Ok(@drive.stat(p)) } catch { e => Err(e) }) is Ok(_)
}

///|
/// `program` run to its end in a group of its own: `{"$child": events}`, each `["stdout"|"stderr", text]`, then
/// `["close", code]` (null where a signal ended it, or it was ended past `command_most_ms`), or `["error", why]` where
/// it did not start.
async fn command_events(
  host : @host.Host,
  program : String,
  args : Array[String],
  env : Array[(String, String)]?,
  cwd : String?,
) -> Json {
  // (Windows: under the runner's job, so the command and all it started end as it is ended, its pipes closed with them)
  let (run, run_args) = if is_windows() { updates_grouped(program, args) } else { (program, args) }
  let started = try {
    Ok(
      match (env, cwd) {
        (Some(e), Some(c)) => spawn(host, run, run_args, env=e, cwd=c, stdout=Piped, stderr=Piped, group=true)
        (Some(e), None) => spawn(host, run, run_args, env=e, stdout=Piped, stderr=Piped, group=true)
        (None, Some(c)) => spawn(host, run, run_args, cwd=c, stdout=Piped, stderr=Piped, group=true)
        (None, None) => spawn(host, run, run_args, stdout=Piped, stderr=Piped, group=true)
      },
    )
  } catch {
    e => Err(e)
  }
  let proc = match started {
    Ok(p) => p
    Err(e) => return { "$child": [["error", Json::string("spawn \{program} \{said_of(e)}")]] }
  }
  let running = match commands_running.get(program) {
    Some(xs) => xs
    None => {
      let xs = []
      commands_running[program] = xs
      xs
    }
  }
  running.push(proc)
  let events : Array[Json] = []
  let ended = @effect.timeout(command_most_ms, async fn() { // timer: a deadline to a process (the longest an update gives one)
    while true {
      match proc.events.take() {
        Out(b) => events.push(["stdout", Json::string(@utf8.decode_lossy(b))])
        Err(b) => events.push(["stderr", Json::string(@utf8.decode_lossy(b))])
        Exit(code, _) => {
          events.push(["close", match code { Some(c) => Json::number(c.to_double()); None => Json::null() }])
          break
        }
      }
    }
  }) catch {
    _ => None
  }
  if ended is None {
    ignore(kill(proc.pid, "SIGKILL", group=true))
    events.push(["close", Json::null()])
  }
  if running.search_by(p => p.pid == proc.pid) is Some(i) { ignore(running.remove(i)) }
  if running.is_empty() {
    commands_running.remove(program)
  }
  { "$child": Json::array(events) }
}

///|
/// unix.ts, windows.ts `startInstaller`: on Unix a copy of `script` run by a shell in the background (its exit and what
/// it said written in `run_dir`); on Windows by a scheduled task of its own, as run/update.ps1 says. Whether it started.
async fn start_installer(host : @host.Host, script : String, run_dir : String, env : Array[(String, String)], app : String) -> Bool {
  if is_windows() {
    let ps1 = path([run_dir, "update.ps1"])
    let hidden = path([run_dir, "stillfail-update-w.exe"])
    let data_dir = @nodepath.dirname(sep(), run_dir)
    let kept = read_text(path([data_dir, "windows.json"]))
    let (task, admin) = @ops_platform.windows_task_of(kept, data_dir~)
    let made = try {
      @drive.rm_force(path([run_dir, "update.err"]))
      // (copied over what the update before left: node's copyFile replaces, the drive's makes a new file only)
      ignore(attempt(() => @drive.unlink(hidden)))
      @drive.copy_file(path([app, "mesh", "target", "release", "stillfail-station-w.exe"]), hidden)
      ignore(attempt(() => @drive.unlink(path([run_dir, "install.ps1"]))))
      @drive.copy_file(script, path([run_dir, "install.ps1"]))
      @drive.write_private(ps1, @ops_platform.windows_update_script(run_dir, env, task))
      true
    } catch {
      _ => false
    }
    if !made {
      return false
    }
    let register = @ops_platform.windows_register_script(hidden, ps1, run_dir, task, admin)
    // (-EncodedCommand: UTF-16LE in base64)
    let units = @buffer.Buffer()
    for i in 0..<register.length() {
      let u = register.unsafe_get(i).to_int()
      units.write_byte((u & 0xff).to_byte())
      units.write_byte((u >> 8).to_byte())
    }
    let child = spawn(host, "powershell.exe", ["-NoProfile", "-NonInteractive", "-EncodedCommand", @drive.base64(units.to_bytes())], env~) catch {
      _ => return false
    }
    let (code, _, _, _) = child.finished()
    return code == Some(0)
  }
  // A copy: the installer replaces the release it is in.
  let copy = path([run_dir, "install.sh"])
  // (the update before left its copy there: node's copyFile replaced it, the drive's makes a new file only, so 0.1.9984
  // started no installer after the first update)
  ignore(attempt(() => @drive.unlink(copy)))
  @drive.copy_file(script, copy) catch {
    _ => return false
  }
  let child = spawn(host, "/bin/sh", ["-c", @ops_platform.unix_installer_shell, "sh", copy, run_dir], env~, group=true) catch {
    _ => return false
  }
  let (code, _, _, _) = child.finished()
  code == Some(0)
}
