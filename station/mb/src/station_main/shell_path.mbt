// ops/shell-path.ts: a command the station's environment does not find, looked for on the PATH a person's interactive
// shell sets (a version manager's, a custom bin), read only for that and only for a command absent from the given
// environment. The shell is time-bounded, its output other than the probe's own line ignored, and no credentials of the
// environment brought into it. The probe is `/bin/sh` run from that shell (Node's in the TypeScript, which a release
// has none of), its PATH's directories followed while it still runs (fnm's multishell link can go away afterward).

///|
let shell_keep_ms : Double = 30000.0

///|
let shell_probe_ms : Int = 8000

///|
let shell_output_most : Int = 256 * 1024

///|
/// What `/bin/sh` says from the person's shell: a line of the mark, then each absolute directory of PATH followed, its
/// bytes in hex (od's), one a line, ended by an empty one.
let shell_probe_code : String =
  #|IFS=:
  #|printf '\n%s\n' "$STILLFAIL_SHELL_MARK"
  #|for d in $PATH; do
  #|  case "$d" in
  #|    /*) r=$(cd "$d" 2>/dev/null && pwd -P) || r=$d
  #|        printf '%s' "$r" | od -An -tx1 | tr -d ' \n'; printf '\n' ;;
  #|  esac
  #|done
  #|printf '\n'

///|
/// What the shells said, by what was asked of them (shell-path.ts `readings`): when, and the directories (none where
/// the shell did not say).
let shell_readings : Map[String, (Double, Array[String]?)] = Map([])

///|
/// shell-path.ts `forgetShellPaths`.
fn forget_shell_paths() -> Unit {
  shell_readings.clear()
}

///|
/// shell-path.ts `probeEnv`: no account's credentials in the probe, nor a profile's own homes.
fn shell_probe_env(env : Array[(String, String)]) -> Array[(String, String)] {
  env.filter(kv => {
    let k = kv.0.to_upper()
    let secret = k.contains("TOKEN") ||
      k.contains("SECRET") ||
      k.contains("PASSWORD") ||
      k.contains("AUTH") ||
      k == "KEY" ||
      k.has_prefix("KEY_") ||
      k.has_suffix("_KEY") ||
      k.contains("_KEY_")
    !secret && kv.0 != "CODEX_HOME" && kv.0 != "CLAUDE_CONFIG_DIR"
  })
}

///|
fn shell_hex_text(hex : String) -> String? {
  if hex.length() % 2 != 0 {
    return None
  }
  let out = Buffer()
  for i = 0; i < hex.length(); i = i + 2 {
    let byte = @string.parse_int(hex[i:i + 2].to_owned(), radix=16) catch { _ => return None }
    out.write_byte(byte.to_byte())
  }
  Some(@utf8.decode_lossy(out.to_bytes()))
}

///|
/// shell-path.ts `readShellPath`: the PATH `shell` sets (`-i`, and `-l` for a login one), its links followed.
async fn read_shell_path(host : @host.Host, shell : String, login : Bool, source : Array[(String, String)]) -> Array[String]? {
  let mark = "__STILLFAIL_PATH_\{@drive.hex(@drive.random_bytes(16))}__"
  let env = shell_probe_env(source)
  env.push(("STILLFAIL_SHELL_MARK", mark))
  env.push(("STILLFAIL_SHELL_CODE", shell_probe_code))
  let args = ["-i", ..(if login { ["-l"] } else { [] }), "-c", "/bin/sh -c \"$STILLFAIL_SHELL_CODE\""]
  let home = match source.iter().find_first(kv => kv.0 == "HOME") {
    Some(kv) => kv.1
    None => homedir()
  }
  let proc = spawn(host, shell, args, env~, cwd=home, stdout=Piped) catch { _ => return None }
  let over = Ref(false)
  let killer = host.rt.fork(name="shell's PATH, its deadline", async fn() {
    @effect.sleep(shell_probe_ms) // timer: a timeout (a shell that never ends)
    over.val = true
    ignore(kill(proc.pid, "SIGKILL"))
  })
  let (code, _, out, _) = proc.finished()
  killer.interrupt()
  if over.val || code != Some(0) || out.length() > shell_output_most {
    return None
  }
  let lines = @utf8.decode_lossy(out).split("\n").map(l => l.trim_end(chars="\r").to_owned()).collect()
  guard lines.search(mark) is Some(at) else { return None }
  let dirs = []
  for i = at + 1; i < lines.length(); i = i + 1 {
    if lines[i] == "" {
      break
    }
    guard shell_hex_text(lines[i]) is Some(d) else { return None }
    dirs.push(d)
  }
  Some(dirs)
}

///|
/// shell-path.ts `kept`: what the shell says for `shell`, `login` and `env`, asked again only after KEEP_MS.
async fn shell_path(host : @host.Host, shell : String, login : Bool, env : Array[(String, String)]) -> Array[String]? {
  let clean = shell_probe_env(env)
  clean.sort_by((a, b) => compare(a.0, b.0))
  let key = Json::array([
    Json::string(shell),
    Json::boolean(login),
    Json::array(clean.map(kv => Json::array([Json::string(kv.0), Json::string(kv.1)]))),
  ]).stringify()
  let now = wall_ms().to_double()
  match shell_readings.get(key) {
    Some((at, dirs)) if now - at < shell_keep_ms => return dirs
    _ => ()
  }
  let dirs = read_shell_path(host, shell, login, clean)
  if shell_readings.length() >= 32 {
    match shell_readings.keys().next() {
      Some(k) => shell_readings.remove(k)
      None => ()
    }
  }
  shell_readings[key] = (now, dirs)
  dirs
}

///|
/// windows.ts `SAVED_ENVIRONMENT`: the environment's string values as the registry keeps them, unexpanded, the
/// machine's and the user's, as UTF-8 JSON in base64 (a path of other than ASCII comes through whatever the code page).
let saved_environment_code : String =
  #|$ErrorActionPreference = 'Stop'
  #|function Saved($path) {
  #|  $o = @{}
  #|  $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
  #|  if ($key) { foreach ($n in $key.GetValueNames()) { $v = $key.GetValue($n, $null, 'DoNotExpandEnvironmentNames'); if ($v -is [string]) { $o[$n] = $v } } }
  #|  $o
  #|}
  #|$j = @{ machine = (Saved 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'); user = (Saved 'HKCU:\Environment') } | ConvertTo-Json -Compress -Depth 3
  #|[Console]::Out.Write([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($j)))

///|
/// The string values of an object of what PowerShell said.
fn saved_strings(j : Json?) -> Array[(String, String)] {
  match j {
    Some(Object(m)) => m.to_array().filter_map(kv => if kv.1 is String(v) { Some((kv.0, v)) } else { None })
    _ => []
  }
}

///|
/// windows.ts `savedPath`: the PATH the registry gives a process started now (`savedPathOf`), none where it cannot be
/// read in time.
async fn read_saved_path(host : @host.Host, env : Array[(String, String)]) -> Array[String]? {
  let args = ["-NoProfile", "-NonInteractive", "-EncodedCommand", encoded_command(saved_environment_code)]
  let proc = spawn(host, "powershell.exe", args, stdout=Piped) catch { _ => return None }
  let over = Ref(false)
  let killer = host.rt.fork(name="the registry's PATH, its deadline", async fn() {
    @effect.sleep(shell_probe_ms) // timer: a timeout (PowerShell that never ends)
    over.val = true
    ignore(kill(proc.pid, "SIGKILL"))
  })
  let (code, _, out, _) = proc.finished()
  killer.interrupt()
  if over.val || code != Some(0) || out.length() > shell_output_most {
    return None
  }
  let said = @utf8.decode_lossy(out).trim(chars=" \t\r\n").to_string()
  let json = @utf8.decode_lossy(@base64.decode(said)) catch { _ => return None }
  let j : Json = @json.parse(json) catch { _ => return None }
  let (machine, user) = match j {
    Object(m) => (saved_strings(m.get("machine")), saved_strings(m.get("user")))
    _ => ([], [])
  }
  Some(@ops_platform.saved_path_of(machine, user, env))
}

///|
/// shell-path.ts `kept(["saved"], …)`: what the registry says for `env`, read again only after KEEP_MS.
async fn saved_path(host : @host.Host, env : Array[(String, String)]) -> Array[String]? {
  let clean = shell_probe_env(env)
  clean.sort_by((a, b) => compare(a.0, b.0))
  let key = Json::array([
    Json::string("saved"),
    Json::array(clean.map(kv => Json::array([Json::string(kv.0), Json::string(kv.1)]))),
  ]).stringify()
  let now = wall_ms().to_double()
  match shell_readings.get(key) {
    Some((at, dirs)) if now - at < shell_keep_ms => return dirs
    _ => ()
  }
  let dirs = read_saved_path(host, clean)
  if shell_readings.length() >= 32 {
    match shell_readings.keys().next() {
      Some(k) => shell_readings.remove(k)
      None => ()
    }
  }
  shell_readings[key] = (now, dirs)
  dirs
}

///|
fn env_path_put(env : Array[(String, String)], value : String) -> Array[(String, String)] {
  let name = match env.iter().find_first(kv => kv.0 == "PATH" || (is_windows() && kv.0.to_upper() == "PATH")) {
    Some(kv) => kv.0
    None => "PATH"
  }
  [..env.filter(kv => kv.0 != name), (name, value)]
}

///|
fn env_path_of(env : Array[(String, String)]) -> String {
  match env.iter().find_first(kv => kv.0 == "PATH" || (is_windows() && kv.0.to_upper() == "PATH")) {
    Some(kv) => kv.1
    None => ""
  }
}

///|
/// shell-path.ts `withShellCommand`: `env` where `name` is found on its PATH, else with the shell's PATH before it
/// where that finds it (`lookup`: the environment the shell is read in, which may keep what `env` must not).
async fn with_shell_command(
  host : @host.Host,
  name : String,
  env : Array[(String, String)],
  lookup? : Array[(String, String)],
) -> Array[(String, String)] {
  let lookup = lookup.unwrap_or(env)
  if name.contains("/") || name.contains("\\") || find_command(name, env) is Some(_) {
    return env
  }
  // The registry's PATH on Windows (what a process started now is given: a runtime installed since the station
  // started): its new directories go after the given ones, so what the given PATH finds keeps its place.
  if is_windows() {
    match saved_path(host, lookup) {
      Some(dirs) => {
        let candidate = env.copy()
        for d in dirs {
          @ops_platform.win_append_path(candidate, d, ";")
        }
        if find_command(name, candidate) is Some(_) {
          return candidate
        }
      }
      None => ()
    }
  }
  let shell = match lookup.iter().find_first(kv => kv.0 == "SHELL") {
    Some(kv) if !is_windows() && kv.1 != "" => kv.1
    _ => return env
  }
  let delim = if is_windows() { ";" } else { ":" }
  // A non-login interactive shell may read another startup file than a login one: what an ordinary terminal uses
  // first, then the login's where the command was not there.
  for login in [false, true] {
    guard shell_path(host, shell, login, lookup) is Some(dirs) else { continue }
    let mut candidate = env
    let mut i = dirs.length() - 1
    while i >= 0 {
      let now = env_path_of(candidate)
      candidate = env_path_put(candidate, if now == "" { dirs[i] } else { dirs[i] + delim + now })
      i -= 1
    }
    if find_command(name, candidate) is Some(_) {
      return candidate
    }
  }
  env
}
