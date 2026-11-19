// Running a Windows station as the machine's administrator ("以管理员运行", elevation/elevation.ts), switched on and off
// from its page rather than only by `install.ps1 -Admin`. The station is never stopped before the change can take:
// - Windows asks (UAC) in a PowerShell of its own, which the station ends after ASK_MS: a prompt nobody can answer (on
//   the secure desktop, which no remote screen shows) leaves the station as it was, said `unanswered`; one refused,
//   `declined`. A station already elevated asks nothing (going back to Limited, say).
// - Elevated, run/elevation-apply.ps1 sets the logon task's RunLevel and windows.json's `admin` (what install.ps1 and the
//   update task keep), then starts a task of its own ("<task> elevation", elevated, nobody's child here), which restarts
//   the station as its task now runs it: drained first (as an update does), stopped, started.
// - That task waits for the new start (run/station.json, written once its Node serves). None in RESTART_S: the task's
//   RunLevel and windows.json put back and the station started as before, said `notStarted`.
// What is under way or how the last change failed is in run/elevation.json, which outlives the restart.

///|
/// How long Windows' prompt is waited for before the change is given up.
pub let elevation_ask_ms : Double = 120000.0

///|
/// How long the restarted station has to say its start before its task is put back.
let restart_s : Int = 180

///|
/// How long an elevated change has to say it restarts the station (or why not) once its prompt is answered.
let apply_ms : Double = 60000.0

///|
/// A PowerShell run apart (`ChildProcess`): ended here, its failure to start and its end (an exit code) told.
pub(all) struct Child {
  kill : () -> Unit
  on_error : (() -> Unit) -> Unit
  on_exit : ((Int?) -> Unit) -> Unit
}

///|
/// The files it reads and writes (node:fs's): a file's text where it reads (None where not), written whole, let go,
/// whether one is there, copied.
pub(all) struct ElevationFiles {
  read : (String) -> String?
  write : (String, String) -> Unit raise
  remove : (String) -> Unit
  exists : (String) -> Bool
  copy : (String, String) -> Unit raise
}

///|
/// The station's files through its shell (fs.read, fs.write, fs.remove, fs.stat, fs.copy).
pub fn ElevationFiles::of_host(host : @host.Host) -> ElevationFiles {
  let disk : @cloud_lock.Disk = { host, }
  {
    read: path => disk.read(path),
    write: (path, text) => {
      let _ = host.shell_sync("fs.write", jobj([("path", jstr(path)), ("text", jstr(text))]))
    },
    remove: path => disk.remove(path),
    exists: path => disk.exists(path),
    copy: (from, to) => {
      let _ = host.shell_sync("fs.copy", jobj([("from", jstr(from)), ("to", jstr(to))]))
    },
  }
}

///|
/// What the station is (`probe`: elevated, and its user an administrator) and does on Windows; a test's otherwise.
pub(all) struct ElevationDeps {
  data : String
  app : String
  now : () -> Double
  /// `f` once, `ms` from now (fibers.ts `wall.after`); the returned function calls it off.
  after : (Double, () -> Unit) -> () -> Unit
  changed : () -> Unit
  probe : async () -> (Bool, Bool)
  /// Runs `script` (PowerShell) apart: hidden, its exit code when it ends.
  run : (String) -> Child
  files : ElevationFiles
}

///|
/// elevation.ts `ChangeRefused`: its words' key (`busy`, `notAdmin`, `notInstalled`).
pub(all) suberror ChangeRefused {
  ChangeRefused(String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for ChangeRefused with output(self, logger) {
  match self {
    ChangeRefused(key) => logger.write_string(key)
  }
}

///|
pub struct Elevation {
  priv d : ElevationDeps
  priv mut probed : (Bool, Bool)?
  priv mut asking : Child?
  priv mut cancel : (() -> Unit)?
  /// run/elevation.json and windows.json's `admin` as last read or written here: the overview reads these, never the
  /// disk.
  priv mut kept : Json?
  priv mut on : Bool
  /// A change being made ready (its files written): another is refused meanwhile, as once one is asked.
  priv mut changing : Bool
}

///|
/// Paths joined and made normal, as node's posix `join` does.
pub fn path_join(parts : Array[String]) -> String {
  let joined = parts.filter(p => p != "").join("/")
  if joined == "" {
    return "."
  }
  let absolute = joined.has_prefix("/")
  let out : Array[String] = []
  for seg in joined.split("/") {
    let s = seg.to_string()
    if s == "" || s == "." {
      continue
    }
    if s == ".." {
      if out.length() > 0 && out[out.length() - 1] != ".." {
        out.pop() |> ignore
      } else if !absolute {
        out.push("..")
      }
      continue
    }
    out.push(s)
  }
  let trailing = joined.has_suffix("/") && out.length() > 0
  let body = out.join("/") + (if trailing { "/" } else { "" })
  if absolute {
    "/" + body
  } else if body == "" {
    "."
  } else {
    body
  }
}

///|
/// What a file says without a leading byte order mark (PowerShell writes one).
fn no_bom(text : String?) -> String {
  match text {
    Some(t) if t.length() > 0 && t.unsafe_charcode_at(0) == 0xfeff => t.unsafe_substring(start=1, end=t.length())
    Some(t) => t
    None => ""
  }
}

///|
/// What run/elevation.json says, where it says something.
fn kept_in(text : String?) -> Json? {
  match parse(no_bom(text)) {
    Some(k) if bool_at(Some(k), "want") is Some(_) => Some(k)
    _ => None
  }
}

///|
fn windows_json_in(text : String?) -> Json {
  match parse(no_bom(text)) {
    Some(Object(_) as j) => j
    Some(Array(_) as j) => j
    _ => jobj([])
  }
}

///|
fn on_in(text : String?) -> Bool {
  get(Some(windows_json_in(text)), "admin") is Some(True)
}

///|
pub fn Elevation::new(d : ElevationDeps) -> Elevation {
  {
    d,
    probed: None,
    asking: None,
    cancel: None,
    kept: kept_in((d.files.read)(path_join([d.data, "run", "elevation.json"]))),
    on: on_in((d.files.read)(path_join([d.data, "windows.json"]))),
    changing: false,
  }
}

///|
fn Elevation::run_dir(self : Elevation) -> String {
  path_join([self.d.data, "run"])
}

///|
fn kept_of(want : Bool, at : Double, step? : String? = None, failed? : String? = None) -> Json {
  let out = [("want", jbool(want)), ("at", jnum(at))]
  if step is Some(s) {
    out.push(("step", jstr(s)))
  }
  if failed is Some(f) {
    out.push(("failed", jstr(f)))
  }
  jobj(out)
}

///|
/// Looks at how it runs, once; and what a change before the restart left (one that said it restarts and now runs as it
/// wanted is done; one under way in a process gone is over).
pub async fn Elevation::start(self : Elevation) -> Unit {
  let probed = (self.d.probe)() catch { _ => (false, false) }
  self.probed = Some(probed)
  let k = self.kept
  if get(k, "step") is Some(step) {
    let want = bool_at(k, "want").unwrap_or(false)
    let restarting = step == jstr("restarting")
    if restarting && want != probed.0 {
      self.keep(kept_of(want, (self.d.now)(), failed=Some("notStarted")))
    } else if !restarting || want == probed.0 {
      self.clear()
    }
  }
  (self.d.changed)()
}

///|
/// Its look at the elevated side called off, its prompt ended.
pub fn Elevation::stop(self : Elevation) -> Unit {
  if self.cancel is Some(c) {
    c()
  }
  if self.asking is Some(child) {
    (child.kill)()
  }
}

///|
pub fn Elevation::kept(self : Elevation) -> Json? {
  self.kept
}

///|
fn Elevation::keep(self : Elevation, k : Json) -> Unit {
  self.kept = Some(k)
  (self.d.files.write)(path_join([self.run_dir(), "elevation.json"]), stringify(k)) catch {
    // (its state not kept: said in the log)
    _ => ()
  }
}

///|
fn Elevation::clear(self : Elevation) -> Unit {
  self.kept = None
  (self.d.files.remove)(path_join([self.run_dir(), "elevation.json"]))
}

///|
/// Both files read again, as the elevated side may have written them.
fn Elevation::reload(self : Elevation) -> Unit {
  self.kept = kept_in((self.d.files.read)(path_join([self.run_dir(), "elevation.json"])))
  self.on = on_in((self.d.files.read)(path_join([self.d.data, "windows.json"])))
}

///|
/// windows.json's `admin`: what its logon task is registered with, by install.ps1 or a change from here.
pub fn Elevation::on(self : Elevation) -> Bool {
  self.on
}

///|
/// The overview's `elevation` (Windows only): the setting, whether this process runs elevated, whether its user can be
/// (in the Administrators group), the change under way or how the last one failed, and whether the viewer may change it.
pub fn Elevation::view(self : Elevation, manage : Bool) -> Json {
  let (elevated, admin) = self.probed.unwrap_or((false, false))
  let k = self.kept
  let out : Map[String, Json] = Map([
    ("on", jbool(self.on)),
    ("elevated", jbool(elevated)),
    ("canElevate", jbool(elevated || admin)),
  ])
  if get(k, "step") is Some(step) {
    out["step"] = step
    out["want"] = get(k, "want").unwrap_or(Json::null())
  }
  if get(k, "failed") is Some(failed) {
    out["failed"] = failed
    out["want"] = get(k, "want").unwrap_or(Json::null())
    if truthy(get(k, "message")) {
      out["message"] = get(k, "message").unwrap()
    }
  }
  out["manage"] = jbool(manage)
  Json::object(out)
}

///|
/// windows.ts `defaultWindowsTask` (ops_platform's `default_windows_task`): the station's own task where windows.json
/// names none, its data directory's product's (`.monoid`: monoid's; any other: still.fail's).
fn default_windows_task(data : String) -> String {
  let leaf = data.replace_all(old="\\", new="/").split("/").to_array().rev_iter().find_first(p => p != "")
  if js_lower(leaf.map(p => p.to_owned()).unwrap_or("")) == ".monoid" {
    "monoid station"
  } else {
    "still.fail station"
  }
}

///|
/// Switched to `on`: asked of Windows, applied elevated, the station restarted as its task then runs it (see above).
/// Answered as soon as it is asked; the overview says how it goes.
pub fn Elevation::change(self : Elevation, on : Bool) -> Unit raise {
  let (elevated, admin) = self.probed.unwrap_or((false, false))
  if self.changing || get(self.kept, "step") is Some(_) {
    raise ChangeRefused("busy")
  }
  if !elevated && !admin {
    raise ChangeRefused("notAdmin")
  }
  self.changing = true
  let run = self.run_dir()
  try {
    let hidden = path_join([self.d.app, "mesh", "target", "release", "stillfail-station-w.exe"])
    if !(self.d.files.exists)(hidden) {
      raise ChangeRefused("notInstalled")
    }
    let now = (self.d.now)()
    let deadline = now + elevation_ask_ms
    let kept = Some(windows_json_in((self.d.files.read)(path_join([self.d.data, "windows.json"]))))
    let task = match get(kept, "task") {
      Some(String(t)) if t != "" => t
      _ => default_windows_task(self.d.data)
    }
    // Copied out of <app>: what runs from there is stopped as the station is.
    let runner = path_join([run, "stillfail-elevation-w.exe"])
    (self.d.files.copy)(hidden, runner)
    (self.d.files.write)(
      path_join([run, "elevation-restart.ps1"]),
      restart_script(run~, data=self.d.data, app=self.d.app, task~, on~),
    )
    (self.d.files.write)(
      path_join([run, "elevation-apply.ps1"]),
      apply_script(run~, data=self.d.data, task~, on~, deadline~, restart=on != elevated, runner~),
    )
    // Written before the elevated side can write its own over it.
    self.keep(kept_of(on, now, step=Some("asking")))
  } catch {
    e => {
      self.changing = false
      raise e
    }
  }
  self.changing = false
  (self.d.changed)()
  let child = (self.d.run)(ask_script(path_join([run, "elevation-apply.ps1"]), !elevated))
  self.asking = Some(child)
  let over = (failed : String?) => {
    if self.cancel is Some(c) {
      c()
    }
    self.cancel = None
    self.asking = None
    self.reload()
    // Said by the elevated side meanwhile (applying, restarting, failed): its, not this.
    if failed is Some(f) && get(self.kept, "step") == Some(jstr("asking")) {
      self.keep(kept_of(on, (self.d.now)(), failed=Some(f)))
    }
    (self.d.changed)()
  }
  self.cancel = Some(
    (self.d.after)(elevation_ask_ms, () => {
      (child.kill)()
      over(Some("unanswered"))
    }),
  )
  (child.on_error)(() => over(Some("error")))
  (child.on_exit)(code => {
    guard self.asking is Some(c) && physical_equal(c, child) else { return }
    if code == Some(4) {
      return over(Some("declined"))
    }
    if code != Some(0) {
      return over(Some("error"))
    }
    // Answered: the elevated side says how it goes; not heard from at all, the change is over.
    if self.cancel is Some(c) {
      c()
    }
    self.asking = None
    (self.d.changed)()
    let until = (self.d.now)() + apply_ms
    fn look() -> Unit {
      self.cancel = None
      self.reload()
      (self.d.changed)()
      let step = get(self.kept, "step")
      if step == Some(jstr("asking")) || step == Some(jstr("applying")) {
        if (self.d.now)() < until {
          self.cancel = Some((self.d.after)(1000.0, look))
        } else {
          self.keep(kept_of(on, (self.d.now)(), failed=Some("error")))
        }
      }
    }

    self.cancel = Some((self.d.after)(1000.0, look))
  })
}

///|
/// A PowerShell string of `s`.
fn ps_q(s : String) -> String {
  "'" + s.replace_all(old="'", new="''") + "'"
}

///|
fn ps_bool(b : Bool) -> String {
  if b {
    "$true"
  } else {
    "$false"
  }
}

///|
/// The station's own PowerShell: run/elevation-apply.ps1 started elevated (`elevate`: through Windows' prompt, which
/// waits for its answer), exiting 0 once it is started, 4 when the prompt was refused, 5 when it could not be started.
pub fn ask_script(apply : String, elevate : Bool) -> String {
  let args = "-ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', \{ps_q("\"" + apply + "\"")}"
  let verb = if elevate { " -Verb RunAs" } else { "" }
  [
    "$ps = (Get-Process -Id $PID).Path",
    "try {",
    "  Start-Process $ps \{args} -WindowStyle Hidden\{verb} -ErrorAction Stop | Out-Null",
    "  exit 0",
    "} catch {",
    // ERROR_CANCELLED: the prompt's No.
    "  $e = $_.Exception; while ($e -and -not ($e -is [ComponentModel.Win32Exception])) { $e = $e.InnerException }",
    "  if ($e -and $e.NativeErrorCode -eq 1223) { exit 4 }",
    "  exit 5",
    "}",
  ].join("\r\n")
}

///|
/// PowerShell's lines writing run/elevation.json (`Note @{…}`) and setting windows.json's `admin` (`Keep $true`).
fn notes(run : String, data : String, on : Bool) -> Array[String] {
  [
    "$state = \{ps_q(path_join([run, "elevation.json"]))}",
    "$windowsJson = \{ps_q(path_join([data, "windows.json"]))}",
    "function Note([hashtable]$s) {",
    "  $s.want = \{ps_bool(on)}",
    "  $s.at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()",
    "  [IO.File]::WriteAllText($state, ($s | ConvertTo-Json -Compress))",
    "}",
    "function Keep([bool]$admin) {",
    "  $kept = [ordered]@{}",
    "  try { (Get-Content -Raw -LiteralPath $windowsJson | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $kept[$_.Name] = $_.Value } } catch {}",
    "  if ($admin) { $kept.admin = $true } else { $kept.Remove('admin') }",
    "  if ($kept.Count -gt 0) { $kept | ConvertTo-Json | Set-Content -LiteralPath $windowsJson -Encoding UTF8 }",
    "  else { Remove-Item -LiteralPath $windowsJson -ErrorAction SilentlyContinue }",
    "}",
    // The user by its full name: the task keeps it short (l-sun), which Windows refuses again where the machine has the
    // same name (L-SUN\l-sun).
    "function Level([string]$task, [string]$level) {",
    "  $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name",
    "  Set-ScheduledTask -TaskName $task -Principal (New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel $level) -ErrorAction Stop | Out-Null",
    "}",
  ]
}

///|
/// run/elevation-apply.ps1, run elevated: nothing once `deadline` is past (the station gave the prompt up); else the
/// logon task's RunLevel and windows.json set, and (`restart`: the station does not run so now) the restart's task
/// registered and started. A failure puts both back and says why.
pub fn apply_script(
  run~ : String,
  data~ : String,
  task~ : String,
  on~ : Bool,
  deadline~ : Double,
  restart~ : Bool,
  runner~ : String,
) -> String {
  let level = if on { "Highest" } else { "Limited" }
  let own = "\{task} elevation"
  let lines = ["$ErrorActionPreference = 'Stop'"]
  lines.append(notes(run, data, on))
  lines.append([
    "if ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -gt \{num_text(deadline)}) { exit 3 }",
    "Note @{ step = 'applying' }",
    "$was = $null",
    "try {",
    "  $was = [string](Get-ScheduledTask -TaskName \{ps_q(task)}).Principal.RunLevel",
    "  Level \{ps_q(task)} '\{level}'",
    "  Keep \{ps_bool(on)}",
  ])
  if restart {
    lines.append([
      "  $ps = (Get-Process -Id $PID).Path",
      "  $action = New-ScheduledTaskAction -Execute \{ps_q(runner)} -Argument ('--run \"' + $ps + '\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"' + \{ps_q(path_join([run, "elevation-restart.ps1"]))} + '\"') -WorkingDirectory \{ps_q(run)}",
      "  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew",
      "  $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest",
      "  Register-ScheduledTask -TaskName \{ps_q(own)} -Action $action -Settings $settings -Principal $principal -Force | Out-Null",
      "  Note @{ step = 'restarting' }",
      "  Start-ScheduledTask -TaskName \{ps_q(own)}",
    ])
  } else {
    lines.push("  Remove-Item -LiteralPath $state -ErrorAction SilentlyContinue")
  }
  lines.append([
    "} catch {",
    "  $why = $_.Exception.Message",
    "  if ($was) { try { Level \{ps_q(task)} $was } catch {}; Keep ($was -eq 'Highest') }",
    "  Note @{ failed = 'error'; message = $why }",
    "  exit 1",
    "}",
  ])
  "\u{feff}" + lines.join("\r\n") + "\r\n"
}

///|
/// run/elevation-restart.ps1, run by its own elevated task: the station drained (at most 10 minutes, as an update),
/// stopped and started by its task; no new start said in RESTART_S, the task's RunLevel and windows.json put back and it
/// started again. Its task removed at the end.
pub fn restart_script(run~ : String, data~ : String, app~ : String, task~ : String, on~ : Bool) -> String {
  let back = if on { "Limited" } else { "Highest" }
  let lines = ["$ErrorActionPreference = 'Continue'"]
  lines.append(notes(run, data, on))
  lines.append([
    "$run = \{ps_q(run)}",
    "$app = \{ps_q(app)}",
    "$task = \{ps_q(task)}",
    "function Said { try { Get-Content (Join-Path $run 'station.json') -Raw | ConvertFrom-Json } catch { $null } }",
    "function Ask([int]$launcher, [string]$op) {",
    "  try {",
    "    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', ('stillfail-launcher-' + $launcher), [System.IO.Pipes.PipeDirection]::Out)",
    "    $pipe.Connect(5000)",
    "    $line = [Text.Encoding]::UTF8.GetBytes('{\"op\":\"' + $op + '\"}' + [char]10)",
    "    $pipe.Write($line, 0, $line.Length)",
    "    $pipe.Flush()",
    "    $pipe.Dispose()",
    "    return $true",
    "  } catch { return $false }",
    "}",
    // The launcher's and its station's processes, by <app> in their command lines (install.ps1's way).
    "$ours = { Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($app) -and $_.Name -in 'node.exe', 'stillfail-station.exe', 'stillfail-station-w.exe' } }",
    "function Restart {",
    "  $said = Said",
    "  $station = $null",
    "  if ($said -and $said.pid) {",
    "    $p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$said.pid) -ErrorAction SilentlyContinue",
    "    if ($p -and $p.Name -like 'stillfail-station*') { $station = $p }",
    "  }",
    "  if ($station -and $said.drain -eq 1) {",
    "    Remove-Item (Join-Path $run 'drained') -ErrorAction SilentlyContinue",
    "    if (Ask $station.ProcessId 'drain') {",
    "      $deadline = (Get-Date).AddSeconds(630)",
    "      while ((Get-Date) -lt $deadline -and -not (Test-Path (Join-Path $run 'drained')) -and (Get-Process -Id $station.ProcessId -ErrorAction SilentlyContinue)) { Start-Sleep 1 }",
    "    }",
    "  }",
    "  Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue",
    "  if ($station) { Stop-Process -Id $station.ProcessId -Force -ErrorAction SilentlyContinue }",
    "  $deadline = (Get-Date).AddSeconds(30)",
    "  while ((& $ours) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }",
    "  & $ours | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }",
    "  $started = if ($said) { $said.startedAt } else { $null }",
    "  Start-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue",
    "  $deadline = (Get-Date).AddSeconds(\{restart_s})",
    "  while ((Get-Date) -lt $deadline) {",
    "    Start-Sleep 1",
    "    $now = Said",
    "    if ($now -and $now.startedAt -ne $started -and (Get-Process -Id $now.pid -ErrorAction SilentlyContinue)) { return $true }",
    "  }",
    "  return $false",
    "}",
    "if (-not (Restart)) {",
    "  try { Level $task '\{back}' } catch {}",
    "  Keep \{ps_bool(!on)}",
    "  Note @{ failed = 'notStarted' }",
    "  Restart | Out-Null",
    "}",
    "try { Unregister-ScheduledTask -TaskName \{ps_q(task + " elevation")} -Confirm:$false -ErrorAction Stop } catch {}",
  ])
  "\u{feff}" + lines.join("\r\n") + "\r\n"
}

// ── elevation/module.ts: the part of a Windows station ─────────────────────────────────────────────────────────

///|
/// PUT /elevation `{on}` for the workspace's owners and admins (elevation/module.ts `elevationRoutes`), `tr` the
/// station's words in the asker's language; None where it is not this route.
pub async fn elevation_route(
  elevation : Elevation,
  meth : String,
  path : String,
  body : String,
  viewer : Viewer,
  tr : (String) -> String,
) -> Answer? {
  guard meth == "PUT" && path == "/elevation" else { return None }
  if !manages_station(viewer) {
    return Some(error_answer(403, tr("station.elevation.managersOnly")))
  }
  let parsed = parse(if body == "" { "{}" } else { body })
  guard parsed is Some(p) else { return Some(error_answer(400, "invalid JSON")) }
  let on = match get(Some(p), "on") {
    Some(True) => true
    Some(False) => false
    _ => return Some(error_answer(400, "on is true or false"))
  }
  elevation.change(on) catch {
    ChangeRefused(key) => return Some(error_answer(409, tr("station.elevation.\{key}")))
    e => raise e
  }
  // (running as administrator asked: said in the log, with who asked)
  Some({ status: 200, body: stringify(elevation.view(true)) })
}

///|
/// The overview's `elevation` for a viewer (elevation/module.ts `parts.overview`).
pub fn elevation_overview(elevation : Elevation, viewer : Viewer) -> Json {
  elevation.view(manages_station(viewer))
}

///|
/// Whether a station's system is one this part is made on (elevation/module.ts: Windows only).
pub fn elevation_on(os : String) -> Bool {
  os == "windows"
}
