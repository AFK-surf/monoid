// Optional Windows LocalSystem screen service (`stillfail-screen-svc.exe`, screens/service.ts & service-module.ts):
// probes whether the service is installed/running and whether this Windows user is an administrator, and handles
// `PUT /screen-service {on}` by running `stillfail-screen-svc.exe install --user-sid <sid>` or `uninstall` elevated.

///|
pub let screen_service_ask_ms : Double = 120000.0

///|
pub(all) struct ScreenServiceProbe {
  installed : Bool
  running : Bool
  connected : Bool
  elevated : Bool
  admin : Bool
  user_sid : String?
  binary : String?
}

///|
pub fn ScreenServiceProbe::empty() -> ScreenServiceProbe {
  { installed: false, running: false, connected: false, elevated: false, admin: false, user_sid: None, binary: None }
}

///|
pub(all) struct ScreenServiceDeps {
  after : (Double, () -> Unit) -> () -> Unit
  changed : () -> Unit
  fork : (async () -> Unit) -> Unit
  probe : async () -> ScreenServiceProbe
  run : (String) -> Child
}

///|
pub struct ScreenService {
  priv d : ScreenServiceDeps
  priv mut probed : ScreenServiceProbe?
  priv mut child : Child?
  priv mut cancel : (() -> Unit)?
  priv mut step : (Bool, String)?
  priv mut failed : (Bool, String, String?)?
}

///|
pub fn ScreenService::new(d : ScreenServiceDeps) -> ScreenService {
  { d, probed: None, child: None, cancel: None, step: None, failed: None }
}

///|
async fn ScreenService::run_probe(self : ScreenService) -> ScreenServiceProbe {
  (self.d.probe)() catch {
    _ => ScreenServiceProbe::empty()
  }
}

///|
pub async fn ScreenService::start(self : ScreenService) -> Unit {
  self.probed = Some(self.run_probe())
  (self.d.changed)()
}

///|
pub fn ScreenService::stop(self : ScreenService) -> Unit {
  if self.cancel is Some(c) {
    c()
    self.cancel = None
  }
  if self.child is Some(child) {
    (child.kill)()
    self.child = None
  }
}

///|
pub fn ScreenService::view(self : ScreenService, manage : Bool) -> Json {
  let p = self.probed.unwrap_or(ScreenServiceProbe::empty())
  let available = p.binary is Some(_)
  let can_change = available && (p.elevated || p.admin)
  let out : Map[String, Json] = Map([
    ("on", jbool(p.installed)),
    ("running", jbool(p.running || p.connected)),
    ("canChange", jbool(can_change)),
    ("available", jbool(available)),
  ])
  if self.step is Some((want, step)) {
    out["step"] = jstr(step)
    out["want"] = jbool(want)
  } else if self.failed is Some((want, failed, msg)) {
    out["failed"] = jstr(failed)
    out["want"] = jbool(want)
    if msg is Some(m) && m != "" {
      out["message"] = jstr(m)
    }
  }
  out["manage"] = jbool(manage)
  Json::object(out)
}

///|
pub async fn ScreenService::change(self : ScreenService, on : Bool) -> Unit {
  if self.step is Some(_) {
    raise ChangeRefused("busy")
  }
  if self.probed is None {
    self.probed = Some(self.run_probe())
  }
  let p = self.probed.unwrap_or(ScreenServiceProbe::empty())
  guard p.binary is Some(binary) else { raise ChangeRefused("notAvailable") }
  if !p.elevated && !p.admin {
    raise ChangeRefused("notAdmin")
  }
  let elevate = !p.elevated
  self.step = Some((on, if elevate { "asking" } else { "applying" }))
  self.failed = None
  (self.d.changed)()
  let child = (self.d.run)(screen_service_ask_script(binary, on, p.user_sid, elevate))
  self.child = Some(child)
  let finish = (failed : String?, message : String?) => {
    guard self.child is Some(c) && physical_equal(c, child) else { return }
    if self.cancel is Some(cancel) {
      cancel()
      self.cancel = None
    }
    self.child = None
    (self.d.fork)(async fn() {
      let next = self.run_probe()
      self.probed = Some(next)
      self.step = None
      match failed {
        Some(f) => self.failed = Some((on, f, message))
        None =>
          if next.installed != on {
            self.failed = Some((on, "error", None))
          } else {
            self.failed = None
          }
      }
      (self.d.changed)()
    })
  }
  self.cancel = Some(
    (self.d.after)(screen_service_ask_ms, () => {
      (child.kill)()
      finish(Some("unanswered"), None)
    }),
  )
  (child.on_error)(() => finish(Some("error"), None))
  (child.on_exit)(code => {
    if code == Some(0) {
      finish(None, None)
    } else if code == Some(4) {
      finish(Some("declined"), None)
    } else {
      finish(Some("error"), None)
    }
  })
}

///|
pub fn screen_service_ask_script(binary : String, on : Bool, user_sid : String?, elevate : Bool) -> String {
  let args = if on {
    match user_sid {
      Some(sid) if sid != "" => "@('install', '--user-sid', \{ps_q(sid)})"
      _ => "@('install')"
    }
  } else {
    "@('uninstall')"
  }
  let verb = if elevate { " -Verb RunAs" } else { "" }
  [
    "try {",
    "  $p = Start-Process -FilePath \{ps_q(binary)} -ArgumentList \{args} -WindowStyle Hidden -PassThru -Wait\{verb} -ErrorAction Stop",
    "  exit $p.ExitCode",
    "} catch {",
    "  $e = $_.Exception; while ($e -and -not ($e -is [ComponentModel.Win32Exception])) { $e = $e.InnerException }",
    "  if ($e -and $e.NativeErrorCode -eq 1223) { exit 4 }",
    "  exit 5",
    "}",
  ].join("\r\n")
}

///|
pub fn screen_service_probe_script(candidates : Array[String]) -> String {
  let quoted = candidates.map(ps_q).join(", ")
  [
    "$id = [Security.Principal.WindowsIdentity]::GetCurrent()",
    "$e = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)",
    "$a = [bool](& (Join-Path $env:SystemRoot 'System32\\whoami.exe') /groups /fo csv | Select-String -SimpleMatch 'S-1-5-32-544')",
    "$s = $id.User.Value",
    "$bin = @(\{quoted}) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1",
    "$st = if ($bin) { try { (& $bin status) -join '' } catch { '' } } else { '' }",
    "@{ elevated = $e; admin = $a; userSid = $s; binary = $bin; status = $st } | ConvertTo-Json -Compress",
  ].join("\r\n")
}

///|
pub fn screen_service_parse_probe(stdout : String) -> ScreenServiceProbe {
  let trimmed = js_trim(stdout)
  guard parse(trimmed) is Some(Object(_) as j) else { return ScreenServiceProbe::empty() }
  let status_raw = str_at(Some(j), "status").unwrap_or("")
  let status = parse(js_trim(status_raw))
  let user_sid = match str_at(Some(j), "userSid") {
    Some(s) if s.has_prefix("S-1-5-") => Some(s)
    _ => None
  }
  let binary = match str_at(Some(j), "binary") {
    Some(b) if b != "" => Some(b)
    _ => None
  }
  {
    installed: bool_at(status, "installed").unwrap_or(false),
    running: bool_at(status, "running").unwrap_or(false),
    connected: bool_at(status, "connected").unwrap_or(false),
    elevated: bool_at(Some(j), "elevated").unwrap_or(false),
    admin: bool_at(Some(j), "admin").unwrap_or(false),
    user_sid,
    binary,
  }
}

///|
pub async fn screen_service_route(
  service : ScreenService,
  meth : String,
  path : String,
  body : String,
  viewer : Viewer,
  tr : (String) -> String,
) -> Answer? {
  guard meth == "PUT" && path == "/screen-service" else { return None }
  if !manages_station(viewer) {
    return Some(error_answer(403, tr("station.screenService.managersOnly")))
  }
  let parsed = parse(if body == "" { "{}" } else { body })
  guard parsed is Some(p) else { return Some(error_answer(400, "invalid JSON")) }
  let on = match get(Some(p), "on") {
    Some(True) => true
    Some(False) => false
    _ => return Some(error_answer(400, "on is true or false"))
  }
  service.change(on) catch {
    ChangeRefused(key) => return Some(error_answer(409, tr("station.screenService.\{key}")))
    e => raise e
  }
  Some({ status: 200, body: stringify(service.view(true)) })
}

///|
pub fn screen_service_overview(service : ScreenService, viewer : Viewer) -> Json {
  service.view(manages_station(viewer))
}
