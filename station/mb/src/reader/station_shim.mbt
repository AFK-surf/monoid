// Lightweight hot-upgrade shim for retired whole-station MoonBit invocations.
// When an older launcher (not yet renewed) runs `<app>/station/stillfail-reader` for a station whose
// config.json still sets `"engine": "moonbit"`, or when a hook/CLI invokes `stillfail-reader` in
// whole-station mode, this shim hands off to Node (`execv` on Unix so PID, PGID, signal mask, and
// inherited launcher fds 3/4/5 stay intact; `CreateProcessW` with inherited handles on Windows).

///|
let shim_station_commands : Array[String] = [
  "run", "enroll", "status", "id", "lock", "channel", "update", "heap", "admin",
]

///|
/// Returns the first non-flag positional command in `args` (matching station_main's `command_of`).
fn shim_command_of(args : Array[String]) -> String? {
  for i, a in args {
    if !a.has_prefix("--") &&
      !(i > 0 && args[i - 1].has_prefix("--") && args[i - 1] != "--with-parent") {
      return Some(a)
    }
  }
  None
}

///|
/// Whether `arg` looks like a JS/MJS hook or bridge script path (e.g. `repo-rules-hook.mjs`, `claude-tui.mjs`).
fn is_script_arg(arg : String) -> Bool {
  if arg == "" || arg.has_prefix("--") {
    return false
  }
  let lower = arg.to_lower()
  lower.has_suffix(".mjs") || lower.has_suffix(".js")
}

///|
/// Returns true when `argv` (with program name at index 0) invokes `stillfail-reader` in
/// whole-station or hook/bridge mode rather than reader/builder mode.
pub fn is_station_shim(argv : Array[String]) -> Bool {
  if argv.length() >= 2 && is_script_arg(argv[1]) {
    return true
  }
  let args = argv[1:].to_array()
  if args.contains("--builder") ||
    args.contains("--serve") ||
    args.contains("--sessions") {
    return false
  }
  match shim_command_of(args) {
    Some(c) => shim_station_commands.contains(c)
    None => args.contains("--app") || args.contains("--port")
  }
}

///|
fn shim_flag_value(args : Array[String], name : String) -> String? {
  for i = 0; i + 1 < args.length(); i = i + 1 {
    if args[i] == name && args[i + 1] != "" {
      return Some(args[i + 1])
    }
  }
  None
}

///|
fn shim_is_windows(exe : String) -> Bool {
  exe.contains("\\") ||
  exe.to_lower().has_suffix(".exe") ||
  @host.env_get("OS").map(s => s.to_lower().contains("windows")).unwrap_or(false)
}

///|
fn shim_sep(win : Bool) -> String {
  if win {
    "\\"
  } else {
    "/"
  }
}

///|
/// Returns the parent directory of `p` (handling both `/` and `\`).
fn shim_dirname(p : String) -> String? {
  let mut trimmed = p
  while trimmed.length() > 1 &&
    (trimmed.has_suffix("/") || trimmed.has_suffix("\\")) {
    trimmed = trimmed.exact_view(end=trimmed.length() - 1).to_owned()
  }
  let slash = trimmed.rev_find("/").unwrap_or(-1)
  let back = trimmed.rev_find("\\").unwrap_or(-1)
  let cut = if slash > back { slash } else { back }
  if cut < 0 {
    None
  } else if cut == 0 {
    Some(trimmed.exact_view(end=1).to_owned())
  } else {
    Some(trimmed.exact_view(end=cut).to_owned())
  }
}

///|
/// Infers `<app>` from `stillfail-reader`'s path (`<app>/station/stillfail-reader` -> `<app>`).
fn app_from_exe(exe : String) -> String? {
  guard shim_dirname(exe) is Some(station_dir) else { return None }
  shim_dirname(station_dir)
}

///|
fn shim_join(sep : String, parts : Array[String]) -> String {
  @nodepath.join(sep, parts)
}

///|
/// Candidate `<app>` directories in priority order: `--app` flag first, then inferred from executable path.
fn shim_app_candidates(args : Array[String], exe : String) -> Array[String] {
  let out : Array[String] = []
  if shim_flag_value(args, "--app") is Some(a) {
    out.push(a)
  }
  if app_from_exe(exe) is Some(a) && !out.contains(a) {
    out.push(a)
  }
  out
}

///|
/// Resolves the Node executable: STILLFAIL_NODE -> `<app>/node/bin/node` (or `node\node.exe`) -> PATH.
fn resolve_node_with(
  apps : Array[String],
  win : Bool,
  env_node : String?,
  is_exec : (String) -> Bool,
  find_in_path : (String) -> String?,
) -> String? {
  if env_node is Some(n) && n != "" && is_exec(n) {
    return Some(n)
  }
  let sep = shim_sep(win)
  for app in apps {
    let cand = if win {
      shim_join(sep, [app, "node", "node.exe"])
    } else {
      shim_join(sep, [app, "node", "bin", "node"])
    }
    if is_exec(cand) {
      return Some(cand)
    }
  }
  find_in_path("node")
}

///|
/// Strips the first positional `"admin"` token from `args`, preserving all flags and remaining args.
fn strip_admin_command(args : Array[String]) -> Array[String] {
  let out : Array[String] = []
  let mut stripped = false
  for i, a in args {
    if !stripped &&
      a == "admin" &&
      !(i > 0 && args[i - 1].has_prefix("--") && args[i - 1] != "--with-parent") {
      stripped = true
      continue
    }
    out.push(a)
  }
  out
}

///|
fn resolve_entry_with(
  apps : Array[String],
  win : Bool,
  is_admin : Bool,
  is_file : (String) -> Bool,
) -> String? {
  let sep = shim_sep(win)
  for app in apps {
    if is_admin {
      let built = shim_join(sep, [app, "station", "admin-cli.js"])
      if is_file(built) {
        return Some(built)
      }
      let dev = shim_join(sep, [app, "bin", "admin-cli.ts"])
      if is_file(dev) {
        return Some(dev)
      }
    } else {
      let main_js = shim_join(sep, [app, "station", "main.js"])
      if is_file(main_js) {
        return Some(main_js)
      }
    }
  }
  None
}

///|
/// Hands off a retired whole-station or hook/bridge invocation to Node.
pub fn run_station_shim(argv : Array[String]) -> Int {
  let argv0 = if argv.length() > 0 { argv[0] } else { "stillfail-reader" }
  let exe = @host.exe_path().unwrap_or(argv0)
  let win = shim_is_windows(exe)
  let args = argv[1:].to_array()
  let apps = shim_app_candidates(args, exe)

  guard resolve_node_with(
    apps,
    win,
    @host.env_get("STILLFAIL_NODE"),
    @host.is_executable_file,
    @host.find_in_path,
  )
    is Some(node) else {
    @host.note(
      "stillfail-reader: \"engine\": \"moonbit\" is retired, and no Node executable was found (checked STILLFAIL_NODE, <app>/node, and PATH)",
    )
    return 1
  }

  // Case 1: hook or bridge `.mjs` / `.js` script path -> `node <script> <rest...>`
  if argv.length() >= 2 && is_script_arg(argv[1]) {
    let script = argv[1]
    if !@host.is_file(script) {
      @host.note("stillfail-reader: script not found: \{script}")
      return 1
    }
    let child_argv : Array[String] = [node, script]
    for i = 2; i < argv.length(); i = i + 1 {
      child_argv.push(argv[i])
    }
    return @host.exec_replace(node, child_argv)
  }

  // Case 2: `admin` -> `<app>/station/admin-cli.js` (or dev `<app>/bin/admin-cli.ts`)
  let is_admin = shim_command_of(args) == Some("admin")
  guard resolve_entry_with(apps, win, is_admin, @host.is_file) is Some(entry) else {
    let what = if is_admin { "station/admin-cli.js (or bin/admin-cli.ts)" } else { "station/main.js" }
    @host.note(
      "stillfail-reader: \"engine\": \"moonbit\" is retired, and \{what} was not found under \{apps}",
    )
    return 1
  }

  if is_admin {
    @host.note(
      "stillfail-reader: \"engine\": \"moonbit\" is retired; handing off admin to Node (\{entry})",
    )
    let child_argv : Array[String] = [node, entry]
    for a in strip_admin_command(args) {
      child_argv.push(a)
    }
    return @host.exec_replace(node, child_argv)
  }

  // Case 3: whole-station commands (`run`, `status`, `id`, ...) -> `<app>/station/main.js`
  @host.note(
    "stillfail-reader: \"engine\": \"moonbit\" is retired; handing off to Node (\{entry})",
  )
  let child_argv : Array[String] = [node, entry]
  for a in args {
    child_argv.push(a)
  }
  @host.exec_replace(node, child_argv)
}
