// station/src/platform/windows.ts: what it works out of what it is given (Windows' paths, its shims, PATH and the
// registry's, netstat's and PowerShell's words, the scripts it writes), whatever machine runs it.

///|
/// The key of `env` that `name` is, whatever its case (the first of them).
fn env_key_ci(env : Array[(String, String)], name : String) -> String? {
  let u = upper(name)
  for p in env {
    if upper(p.0) == u {
      return Some(p.0)
    }
  }
  None
}

///|
fn env_get_ci(env : Array[(String, String)], name : String) -> String? {
  match env_key_ci(env, name) {
    Some(k) => env_get(env, k)
    None => None
  }
}

///|
/// windows.ts `pathOf`: PATH as Windows spells it (`Path`, as often as not).
pub fn win_path_of(env : Array[(String, String)]) -> String {
  match env_get_ci(env, "PATH") {
    Some(v) if v != "" => v
    _ => ""
  }
}

///|
let cmd_path_vars : Array[String] = [
  "USERPROFILE", "LOCALAPPDATA", "APPDATA", "TEMP", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "ProgramData", "PUBLIC",
]

///|
fn printable_ascii(s : String) -> Bool {
  all_units(s, c => c >= 0x20 && c <= 0x7e)
}

///|
/// windows.ts `cmdPath`: where a .cmd file names `path`; refused (Err, its words) where it cannot.
pub fn win_cmd_path(path : String, env : Array[(String, String)]) -> Result[String, String] {
  if printable_ascii(path) {
    return Ok(path)
  }
  let value = (name : String) => match env_get_ci(env, name) {
    Some(v) => {
      let mut e = v.length()
      while e > 0 && wsep(cu(v, e - 1)) {
        e -= 1
      }
      Some(sub(v, 0, e))
    }
    None => None
  }
  let under : Array[(String, String, String)] = []
  for name in cmd_path_vars {
    match value(name) {
      Some(dir) if dir != "" => {
        let rest = sub(path, dir.length(), path.length())
        if lower(sub(path, 0, dir.length())) == lower(dir) &&
          (rest == "" || wsep(cu(rest, 0))) &&
          printable_ascii(rest) {
          under.push((name, dir, rest))
        }
      }
      _ => ()
    }
  }
  let best = stable_sort(under, (a, b) => b.1.length() - a.1.length()).get(0)
  match best {
    None => Err("a .cmd cannot name \{path}: it has other than ASCII in it, outside the user's folders")
    Some((name, _, rest)) => Ok("%" + name + "%" + rest)
  }
}

///|
/// windows.ts `wingetPackage`: the winget package a command is of, by where it really is.
pub fn winget_package(real : String) -> String? {
  // `/[\\/]WinGet[\\/]Packages[\\/]([^\\/]+)[\\/]/i`
  let low = lower(real)
  let mut from = 0
  while true {
    let at = index_of(low, "winget", from~)
    if at < 0 {
      return None
    }
    from = at + 1
    if at == 0 || !wsep(cu(low, at - 1)) {
      continue
    }
    let p = at + 6
    if p >= low.length() || !wsep(cu(low, p)) || sub(low, p + 1, p + 9) != "packages" {
      continue
    }
    let q = p + 9
    if q >= low.length() || !wsep(cu(low, q)) {
      continue
    }
    let mut e = q + 1
    while e < real.length() && !wsep(cu(real, e)) {
      e += 1
    }
    if e == q + 1 || e >= real.length() {
      continue
    }
    let dir = sub(real, q + 1, e)
    let parts = split_on(dir, "_")
    return if parts.length() >= 3 {
      Some(parts[0:parts.length() - 2].to_owned().join("_"))
    } else {
      None
    }
  }
  None
}

///|
/// PATHEXT's extensions, lower, as windows.ts `findCommand` tries them.
pub fn win_path_exts(env : Array[(String, String)]) -> Array[String] {
  let given = match env_get(env, "PATHEXT") {
    Some(v) => v
    None => ".COM;.EXE;.BAT;.CMD"
  }
  split_on(given, ";").filter(e => e != "").map(lower)
}

///|
/// windows.ts `findCommand`'s candidates: each place on PATH with each extension, in order (`join` as Node's on Windows).
pub fn win_command_candidates(
  name : String,
  env : Array[(String, String)],
  delim : String,
  join : (Array[String]) -> String,
) -> Array[String]? {
  guard env_key_ci(env, "PATH") is Some(key) else { return None }
  let path = env_get(env, key).unwrap_or("")
  let exts = win_path_exts(env)
  let out = []
  for dir in split_on(path, delim) {
    for ext in exts {
      out.push(join([if dir == "" { "." } else { dir }, name + ext]))
    }
  }
  Some(out)
}

///|
/// Where `name` is on `env`'s PATH on Windows, as windows.ts `findCommand` finds it: with each of PATHEXT's extensions,
/// never a file with none first (npm puts a POSIX `#!/bin/sh` script `codex` beside `codex.cmd`, which Windows cannot
/// run). A name that has an extension already (`git.exe`) is looked for as it is too, before those. `there`: whether a
/// file is at a path.
pub fn win_find_command(
  name : String,
  env : Array[(String, String)],
  delim : String,
  join : (Array[String]) -> String,
  there : (String) -> Bool,
) -> String? {
  guard win_command_candidates(name, env, delim, join) is Some(candidates) else { return None }
  let mut last = name
  for sep in ["\\", "/"] {
    let parts = split_on(last, sep)
    last = parts[parts.length() - 1]
  }
  let as_it_is = if has(last, ".") {
    guard env_key_ci(env, "PATH") is Some(key) else { return None }
    split_on(env_get(env, key).unwrap_or(""), delim).map(dir => join([if dir == "" { "." } else { dir }, name]))
  } else {
    []
  }
  for c in as_it_is {
    if there(c) {
      return Some(c)
    }
  }
  for c in candidates {
    if there(c) {
      return Some(c)
    }
  }
  None
}

///|
pub(all) struct ShellCandidate {
  path : String
  beside : String?
}

///|
/// windows.ts `shellCandidates`.
pub fn shell_candidates(env : Array[(String, String)], dirs : Array[String], saved : Bool) -> Array[ShellCandidate] {
  let found = []
  match env_truthy(env, "CLAUDE_CODE_GIT_BASH_PATH") {
    Some(p) if !saved => found.push({ path: p, beside: None })
    _ => ()
  }
  for dir in dirs {
    if dir == "" || system32_dir(dir) {
      continue
    }
    found.push({ path: win32_join([win32_dirname(dir), "bin", "sh.exe"]), beside: Some(win32_join([dir, "git.exe"])) })
    found.push({ path: win32_join([dir, "sh.exe"]), beside: None })
  }
  if !saved {
    let roots = [env_truthy(env, "ProgramFiles"), env_truthy(env, "ProgramFiles(x86)")]
    roots.push(env_truthy(env, "LOCALAPPDATA").map(l => win32_join([l, "Programs"])))
    for root in roots {
      match root {
        Some(r) if r != "" => found.push({ path: win32_join([r, "Git", "bin", "sh.exe"]), beside: None })
        _ => ()
      }
    }
  }
  found
}

///|
/// `/\\system32\\?$/i`.
fn system32_dir(dir : String) -> Bool {
  let low = lower(dir)
  ends(low, "\\system32") || ends(low, "\\system32\\")
}

///|
/// windows.ts `gitShell`: the first candidate there (`there`: whether a file is).
pub fn git_shell(env : Array[(String, String)], there : (String) -> Bool) -> String? {
  for c in shell_candidates(env, split_on(win_path_of(env), ";"), false) {
    let beside_ok = match c.beside {
      None => true
      Some(b) => there(b)
    }
    if beside_ok && there(c.path) {
      return Some(c.path)
    }
  }
  None
}

///|
/// windows.ts `gitShellSoon`: by `env`, else by the registry's PATH (`saved`).
pub fn git_shell_soon(
  env : Array[(String, String)],
  saved : Array[String]?,
  there : (String) -> Bool,
) -> String? {
  match git_shell(env, there) {
    Some(s) => Some(s)
    None => {
      for c in shell_candidates(env, saved.unwrap_or([]), true) {
        let beside_ok = match c.beside {
          None => true
          Some(b) => there(b)
        }
        if beside_ok && there(c.path) {
          return Some(c.path)
        }
      }
      None
    }
  }
}

///|
pub let no_shell : String = "jobs and commands on Windows run under Git Bash: install Git for Windows (git-scm.com), or set CLAUDE_CODE_GIT_BASH_PATH"

///|
/// windows.ts `Named`: in the shim's own directory, or as written.
pub(all) enum Named {
  Beside(String)
  At(String)
}

///|
let shim_frame : Array[String] = [
  "echo off", "goto start", ":find_dp0", "set dp0=%~dp0", ":start", "setlocal", "call :find_dp0",
]

///|
/// windows.ts `lastQuoted`: a line ending `"<path>" %*`.
fn last_quoted(line : String) -> (String, String)? {
  // `/^(.*)"([^"]*)"\s*%\*$/`: the last quote pair before ` %*` at the end.
  if !ends(line, "%*") {
    return None
  }
  let mut e = line.length() - 2
  while e > 0 && js_space(cu(line, e - 1)) {
    e -= 1
  }
  if e == 0 || cu(line, e - 1) != 34 {
    return None
  }
  let close = e - 1
  let mut open = close - 1
  while open >= 0 && cu(line, open) != 34 {
    open -= 1
  }
  if open < 0 {
    return None
  }
  let before = sub(line, 0, open)
  // `.` takes no line terminator.
  if any_unit(before, c => c == 10 || c == 13 || c == 0x2028 || c == 0x2029) {
    return None
  }
  let path = sub(line, open + 1, close)
  let bare = if starts(path, "%dp0%") {
    sub(path, 5, path.length())
  } else if starts(path, "%~dp0") {
    sub(path, 5, path.length())
  } else {
    path
  }
  if has(bare, "%") {
    return None
  }
  Some((before, path))
}

///|
fn named_of(path : String) -> Named {
  for p in ["%dp0%\\", "%~dp0\\", "%dp0%", "%~dp0"] {
    if starts(path, p) {
      return Beside(sub(path, p.length(), path.length()))
    }
  }
  At(path)
}

///|
pub(all) enum Shim {
  Node(Named)
  Program(Named)
}

///|
/// windows.ts `readShim`.
pub fn read_shim(text : String) -> Shim? {
  let lines = split_lines(text).map(js_trim).filter(l => l != "")
  for line in lines {
    match last_quoted(line) {
      None => continue
      Some((before_raw, path)) => {
        let before = js_trim_end(before_raw)
        if ends(before, "\"%_prog%\"") || ends(before, "node.exe\"") || ends(before, " node") || before == "node" {
          return Some(Node(named_of(path)))
        }
      }
    }
  }
  let rest = lines
    .map(l => if starts(l, "@") { sub(l, 1, l.length()) } else { l })
    .filter(l => !shim_frame.contains(lower(l)) && !starts(lower(l), "exit /b"))
  if rest.length() == 1 {
    match last_quoted(rest[0]) {
      Some((b, p)) if b == "" => return Some(Program(named_of(p)))
      _ => ()
    }
  }
  None
}

///|
/// windows.ts `shimOf`: what the shim at `path` runs, its paths as they are on the machine.
pub fn shim_of(path : String, text : String) -> Json {
  let dir = win32_dirname(path)
  let at = (n : Named) => match n {
    Beside(b) => win32_join([dir, b])
    At(a) => a
  }
  match read_shim(text) {
    None => Json::null()
    Some(Node(n)) => { "script": js(at(n)), "beside": js(win32_join([dir, "node.exe"])) }
    Some(Program(p)) => { "program": js(at(p)) }
  }
}

///|
/// windows.ts `runnableOf`: a .cmd around cmd where its shim says, else through cmd, quoted (Err: refused).
pub fn win_runnable_of(
  file : String,
  args : Array[String],
  env : Array[(String, String)],
  com_spec : String?,
  shim : (String, Array[String])?,
) -> Result[Json, String] {
  match shim {
    Some((f, a)) => return Ok({ "file": js(f), "args": jstrs([..a, ..args]) })
    None => ()
  }
  for a in [file, ..args] {
    if any_unit(a, c => c == 34 || c == 37 || c == 13 || c == 10) {
      return Err("cannot pass \{js_stringify(js(a))} through cmd")
    }
  }
  let line = [file, ..args].map(a => "\"" + a + "\"").join(" ")
  let cmd = match env_get(env, "ComSpec") {
    Some(c) => c
    None => com_spec.unwrap_or("cmd.exe")
  }
  Ok({ "file": js(cmd), "args": jstrs(["/d", "/s", "/c", "\"" + line + "\""]), "windowsVerbatimArguments": true })
}

///|
/// windows.ts `browserPlaces`.
pub fn win_browser_places(env : Array[(String, String)]) -> Array[String] {
  let roots = []
  for v in ["ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"] {
    match env_get_ci(env, v) {
      Some(r) => roots.push(r)
      None => ()
    }
  }
  let out = []
  for rel in [
    ["Google", "Chrome", "Application", "chrome.exe"],
    ["Chromium", "Application", "chrome.exe"],
    ["Microsoft", "Edge", "Application", "msedge.exe"],
  ] {
    for root in roots {
      let p = win32_join([root, ..rel])
      if !out.contains(p) {
        out.push(p)
      }
    }
  }
  out
}

///|
/// windows.ts `groupMemory`: from PowerShell's `pid parent size` lines, each group's tree's working set (kB).
pub fn win_group_memory(stdout : String, pgids : Array[Double]) -> Array[(Double, Double)] {
  let children : Array[(Double, Array[Double])] = []
  let bytes : Array[(Double, Double)] = []
  for line in split_lines(stdout) {
    let w = split_runs(js_trim(line), js_space).map(js_number)
    let pid = w.get(0).unwrap_or(@double.not_a_number)
    let parent = w.get(1).unwrap_or(@double.not_a_number)
    let size = w.get(2).unwrap_or(@double.not_a_number)
    if !is_integer(pid) || !is_integer(parent) || size.is_nan() || size.is_inf() {
      continue
    }
    match bytes.search_by(b => b.0 == pid) {
      Some(k) => bytes[k] = (pid, size)
      None => bytes.push((pid, size))
    }
    if pid != parent {
      match children.search_by(c => c.0 == parent) {
        Some(k) => children[k].1.push(pid)
        None => children.push((parent, [pid]))
      }
    }
  }
  let rss : Array[(Double, Double)] = []
  for pgid in pgids {
    if !bytes.iter().any(b => b.0 == pgid) {
      continue
    }
    let mut total = 0.0
    let seen = []
    let queue = [pgid]
    while queue.length() > 0 {
      let pid = queue.pop().unwrap()
      if seen.contains(pid) {
        continue
      }
      seen.push(pid)
      total += match bytes.search_by(b => b.0 == pid) {
        Some(k) => bytes[k].1
        None => 0.0
      }
      match children.search_by(c => c.0 == pid) {
        Some(k) => queue.push_iter(children[k].1.iter())
        None => ()
      }
    }
    match rss.search_by(r => r.0 == pgid) {
      Some(k) => rss[k] = (pgid, js_round(total / 1024.0))
      None => rss.push((pgid, js_round(total / 1024.0)))
    }
  }
  rss
}

///|
/// `%NAME%` in `s` replaced by what `vars` holds of it (names upper), left as it is where none.
fn expand_vars(s : String, vars : Array[(String, String)]) -> String {
  let b = StringBuilder()
  let mut i = 0
  let n = s.length()
  while i < n {
    if cu(s, i) == 37 {
      let e = index_of(s, "%", from=i + 1)
      if e > i + 1 {
        let name = sub(s, i + 1, e)
        match env_get(vars, upper(name)) {
          Some(v) => b.write_string(v)
          None => b.write_string(sub(s, i, e + 1))
        }
        i = e + 1
        continue
      }
    }
    b.write_char(Int::unsafe_to_char(cu(s, i)))
    i += 1
  }
  b.to_string()
}

///|
/// windows.ts `savedPathOf`: the registry's PATH, the machine's then the user's, each `%VAR%` expanded.
pub fn saved_path_of(
  machine : Array[(String, String)],
  user : Array[(String, String)],
  env : Array[(String, String)],
) -> Array[String] {
  let vars : Array[(String, String)] = []
  for p in env {
    env_set(vars, upper(p.0), p.1)
  }
  let parts = []
  for saved in [machine, user] {
    let path = match saved.search_by(p => upper(p.0) == "PATH") {
      Some(k) => saved[k].1
      None => ""
    }
    for p in saved {
      if upper(p.0) != "PATH" {
        env_set(vars, upper(p.0), expand_vars(p.1, vars))
      }
    }
    parts.push_iter(split_on(expand_vars(path, vars), ";").iter())
  }
  let seen = []
  let out = []
  for d0 in parts {
    let d = js_trim(d0)
    // `/^[\\/](?![\\/])/`: one separator alone first (rooted on the current drive).
    let one_sep = d.length() >= 1 && wsep(cu(d, 0)) && !(d.length() >= 2 && wsep(cu(d, 1)))
    if !win32_is_absolute(d) || one_sep || seen.contains(lower(d)) {
      continue
    }
    seen.push(lower(d))
    out.push(d)
  }
  out
}

///|
fn ps_q(s : String) -> String {
  "'" + s.replace_all(old="'", new="''") + "'"
}

///|
/// windows.ts `windowsUpdateScript`.
pub fn windows_update_script(run_dir : String, env : Array[(String, String)], task : String) -> String {
  let lines = []
  for p in env {
    if starts(p.0, "STILLFAIL_") {
      lines.push("$env:\{p.0} = \{ps_q(p.1)}")
    }
  }
  lines.push("[Console]::OutputEncoding = [Text.Encoding]::UTF8")
  lines.push("$run = \{ps_q(run_dir)}")
  lines.push("$log = Join-Path $run 'update.log'")
  lines.push("$err = Join-Path $run 'update.err'")
  lines.push("$code = 1")
  lines.push("try {")
  lines.push(
    "  $p = Start-Process (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('\"' + (Join-Path $run 'install.ps1') + '\"') -RedirectStandardOutput $log -RedirectStandardError $err -NoNewWindow -PassThru",
  )
  lines.push("  $null = $p.Handle")
  lines.push("  $p.WaitForExit()")
  lines.push("  $code = $p.ExitCode")
  lines.push("  $said = Get-Content -LiteralPath $err -Raw -Encoding UTF8")
  lines.push("  if ($said) { Add-Content -LiteralPath $log -Value $said -Encoding UTF8 }")
  lines.push("} catch { Add-Content -LiteralPath $log -Value ($_ | Out-String) -Encoding UTF8 }")
  lines.push("Set-Content -LiteralPath (Join-Path $run 'update.exit') -Value $code -Encoding ASCII")
  lines.push("try { Unregister-ScheduledTask -TaskName \{ps_q(task)} -Confirm:$false -ErrorAction Stop } catch {}")
  "\u{feff}" + lines.join("\r\n") + "\r\n"
}

///|
/// windows.ts `startInstaller`'s task registration script.
pub fn windows_register_script(hidden : String, ps1 : String, run_dir : String, task : String, admin : Bool) -> String {
  [
    "$ErrorActionPreference = 'Stop'",
    "$ps = (Get-Process -Id $PID).Path",
    "$action = New-ScheduledTaskAction -Execute \{ps_q(hidden)} -Argument ('--run \"' + $ps + '\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"' + \{ps_q(ps1)} + '\"') -WorkingDirectory \{ps_q(run_dir)}",
    "$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew",
    "$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel \{if admin { "Highest" } else { "Limited" }}",
    "Register-ScheduledTask -TaskName \{ps_q(task)} -Action $action -Settings $settings -Principal $principal -Force | Out-Null",
    "Start-ScheduledTask -TaskName \{ps_q(task)}",
  ].join("\r\n")
}

///|
/// windows.ts `defaultWindowsTask`: the station's own task where windows.json names none, its data directory's
/// product's (`.monoid`: monoid's; any other: still.fail's).
fn default_windows_task(data_dir : String) -> String {
  let mut end = data_dir.length()
  let is_sep = (c : Int) => c == 47 || c == 92 // '/' or '\\'
  while end > 0 && is_sep(cu(data_dir, end - 1)) {
    end -= 1
  }
  let mut start = end
  while start > 0 && !is_sep(cu(data_dir, start - 1)) {
    start -= 1
  }
  let leaf = lower(sub(data_dir, start, end))
  let product = if leaf == "." + monoid_product.id { monoid_product } else { stillfail_product }
  product.name + " station"
}

///|
/// windows.ts `startInstaller`'s task and admin, from windows.json's text (None where it did not read) and the data
/// directory it is in.
pub fn windows_task_of(kept : String?, data_dir? : String = "") -> (String, Bool) {
  let mut task = default_windows_task(data_dir)
  let mut admin = false
  match kept {
    Some(text) =>
      match js_parse(js_trim(text)) {
        Some(j) => {
          match str_field(j, "task") {
            Some(t) if t != "" => task = t
            _ => ()
          }
          if field(j, "admin") is Some(True) {
            admin = true
          }
        }
        None => ()
      }
    None => ()
  }
  (task + " update", admin)
}

///|
/// windows.ts `drives`: the letters whose root is a folder.
pub fn win_drives(is_dir : (String) -> Bool) -> Array[(String, String)] {
  let out = []
  for c in "CDEFGHIJKLMNOPQRSTUVWXYZ" {
    let root = c.to_string() + ":\\"
    if is_dir(root) {
      out.push((c.to_string() + ":", root))
    }
  }
  out
}

///|
/// windows.ts `prependPath`: one PATH whatever its case, the others dropped.
pub fn win_prepend_path(env : Array[(String, String)], dir : String, delim : String) -> Array[(String, String)] {
  let rest = win_path_of(env)
  let out = env.filter(p => upper(p.0) != "PATH")
  out.push(("PATH", dir + delim + rest))
  out
}

///|
/// windows.ts `appendPath`.
pub fn win_append_path(env : Array[(String, String)], dir : String, delim : String) -> Unit {
  let key = env_key_ci(env, "PATH").unwrap_or("PATH")
  let path = env_get(env, key).unwrap_or("")
  if split_on(path, delim).iter().any(d => lower(d) == lower(dir)) {
    return
  }
  env_set(env, key, if path == "" { dir } else { path + delim + dir })
}

///|
/// windows.ts `paths.clean`.
pub fn win_clean(path : String, cwd : String) -> String {
  win32_resolve([if path == "" { "\\" } else { path }], cwd)
}

///|
/// windows.ts `paths.within`.
pub fn win_within(path : String, dir : String) -> Bool {
  let p = lower(path)
  let d = lower(dir)
  p == d || starts(p, if d != "" && wsep(cu(d, d.length() - 1)) { d } else { d + "\\" })
}

///|
/// windows.ts `paths.isRootName`.
pub fn win_is_root_name(part : String) -> Bool {
  part.length() == 2 && is_alpha(cu(part, 0)) && cu(part, 1) == 58
}

///|
/// windows.ts `paths.rooted`.
pub fn win_rooted(path : String) -> Bool {
  starts(path, "/") || win32_is_absolute(path) || has(path, ":")
}

///|
/// windows.ts `paths.join`.
pub fn win_join(base : String, given : String) -> String {
  if win32_is_absolute(given) || base == "" {
    given
  } else if wsep(cu(base, base.length() - 1)) {
    base + given
  } else {
    base + "\\" + given
  }
}

///|
/// windows.ts `paths.relativeIn`.
pub fn win_relative_in(root : String, path : String, cwd : String) -> String? {
  let within = win32_relative(root, path, cwd)
  if starts(within, "..") || win32_is_absolute(within) {
    None
  } else {
    Some(within)
  }
}

///|
/// windows.ts `paths.isDrivePath`.
pub fn win_is_drive_path(text : String) -> Bool {
  text.length() >= 3 && is_alpha(cu(text, 0)) && cu(text, 1) == 58 && wsep(cu(text, 2))
}

///|
/// windows.ts `nativeCache`.
pub fn win_native_cache(env : Array[(String, String)], home : String, join : (Array[String]) -> String) -> String {
  match env_truthy(env, "STILLFAIL_NATIVE_CACHE") {
    Some(c) => c
    None => {
      let app_data = match env_truthy(env, "LOCALAPPDATA") {
        Some(l) => l
        None => join([home, "AppData", "Local"])
      }
      join([app_data, "stillfail-native"])
    }
  }
}

///|
/// windows.ts `makeCommand`'s .cmd beside a script: hands it to Git's sh (`shell`, as cmdPath names it), or does
/// nothing.
pub fn win_command_cmd(path : String, shell : String?, noop : Bool) -> String {
  let name = sub(path, @cmp.maximum(last_index_of(path, "\\"), last_index_of(path, "/")) + 1, path.length())
  if noop {
    "@exit /b 0\r\n"
  } else {
    "@\"\{shell.unwrap_or("")}\" \"%~dp0\{name}\" %*\r\n"
  }
}

///|
/// windows.ts `tcpPortPids`: netstat's ESTABLISHED connections whose own end is `port`, their processes (not `own`).
pub fn netstat_port_pids(stdout : String, port : Double, own : Double) -> Array[Double] {
  let pids = []
  for line in split_lines(stdout) {
    let f = split_runs(js_trim(line), js_space)
    if f.length() >= 5 && f[0] == "TCP" && ends(f[1], ":" + num_text(port)) && f[3] == "ESTABLISHED" {
      let p = js_number(f[4])
      if !pids.iter().any(x => x == p || (x.is_nan() && p.is_nan())) {
        pids.push(p)
      }
    }
  }
  pids.filter(p => p != own && is_integer(p))
}

///|
/// windows.ts `listening`: netstat's LISTENING sockets of `pids` at `port`, their addresses (`*` for all).
pub fn netstat_listening(stdout : String, pids : Array[Double], port : Double) -> Array[String] {
  let found = []
  for line in split_on(stdout, "\n") {
    let f = split_runs(js_trim(line), js_space)
    if f.length() < 5 || f[0] != "TCP" || f[3] != "LISTENING" || !pids.contains(js_number(f[4])) {
      continue
    }
    let at = last_index_of(f[1], ":")
    if js_number(sub(f[1], at + 1, f[1].length())) != port {
      continue
    }
    let mut address = sub(f[1], 0, if at < 0 { f[1].length() + at } else { at })
    if starts(address, "[") {
      address = sub(address, 1, address.length())
    }
    if ends(address, "]") {
      address = sub(address, 0, address.length() - 1)
    }
    let shown = if address == "0.0.0.0" || address == "::" { "*" } else { address }
    if !found.contains(shown) {
      found.push(shown)
    }
  }
  found
}

///|
/// windows.ts `isLauncher`: the process's name.
pub fn win_is_launcher(name : String) -> Bool {
  let n = lower(js_trim(name))
  n == "stillfail-station" || n == "stillfail-station-w"
}

///|
/// windows.ts `nodeBuild`.
pub fn win_node_build(version : String, arch : String, system_root : String?) -> NodeBuild? {
  if arch != "arm64" && arch != "x64" {
    return None
  }
  let dist = "node-v\{version}-win-\{arch}"
  Some({
    dist,
    archive: dist + ".zip",
    bin: "",
    npm: "npm.cmd",
    tar: win32_join([system_root.unwrap_or("C:\\Windows"), "System32", "tar.exe"]),
  })
}

///|
/// windows.ts `agyStaging`.
pub fn win_agy_staging(env : Array[(String, String)], join : (Array[String]) -> String) -> String? {
  env_truthy(env, "LOCALAPPDATA").map(l => join([l, "antigravity", "staging", "agy.exe"]))
}

///|
/// windows.ts `shimUpdate`: how a runtime found here is updated: winget's package (`winget`: where winget is), Vite+'s
/// shim beside vp.exe, npm's .cmd in its prefix (`npm`: its own npm.cmd or one on PATH), none for the shared rules.
pub fn win_shim_update(
  on_path : String,
  real : String,
  pkg : String,
  winget : String,
  there : (String) -> Bool,
  npm_on_path : String?,
) -> Json {
  match winget_package(real) {
    Some(w) =>
      return {
        "program": js(winget),
        "args": jstrs([
          "upgrade", "--id", w, "--exact", "--silent", "--disable-interactivity", "--accept-source-agreements", "--accept-package-agreements",
        ]),
        "noUpdate": jn(2316632107.0),
      }
    None => ()
  }
  let dir = win32_dirname(on_path)
  if there(win32_join([dir, "vp.exe"])) {
    return { "program": js(win32_join([dir, "vp.exe"])), "args": jstrs(["install", "-g", pkg + "@latest"]) }
  }
  let low = lower(on_path)
  if ends(low, ".cmd") && there(win32_join([dir, "node_modules", ..split_on(pkg, "/")])) {
    let own = win32_join([dir, "npm.cmd"])
    let npm = if there(own) { Some(own) } else { npm_on_path }
    return match npm {
      None => js("no-npm")
      Some(n) => { "program": js(n), "args": jstrs(["install", "-g", pkg + "@latest", "--prefix", dir]) }
    }
  }
  Json::null()
}

///|
/// windows.ts `claudeInstall`, `devinInstall`, `agyInstall`.
pub fn win_installs() -> Json {
  let ps = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"]
  {
    "claudeInstall": { "program": "powershell", "args": jstrs([..ps, "irm https://claude.ai/install.ps1 | iex"]) },
    "devinInstall": {
      "program": "powershell",
      "args": jstrs([
        ..ps, "$s = irm https://cli.devin.ai/install.ps1; iex ($s -replace '(?m)^\\s*&\\s*\\S+\\s+setup\\s*$', '')",
      ]),
    },
    "agyInstall": { "program": "powershell", "args": jstrs([..ps, "irm https://antigravity.google/cli/install.ps1 | iex"]) },
  }
}
