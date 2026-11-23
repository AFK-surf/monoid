// Pure planning logic for `stillfail-reader`'s lightweight `station_shim` (no C FFI so `moon test` runs it directly).

///|
let shim_station_commands : Array[String] = [
  "run", "enroll", "status", "id", "lock", "channel", "update", "heap", "admin",
]

///|
/// Returns the first non-flag positional command in `args` (matching station_main's `command_of`).
pub fn command_of(args : Array[String]) -> String? {
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
pub fn is_script_arg(arg : String) -> Bool {
  if arg == "" || arg.has_prefix("--") {
    return false
  }
  let lower = arg.to_lower()
  lower.has_suffix(".mjs") || lower.has_suffix(".js")
}

///|
/// Whether `arg` is the bare `claude-tui` alias (without `.mjs` suffix).
pub fn is_bare_claude_tui(arg : String) -> Bool {
  arg == "claude-tui"
}

///|
/// Returns true when `argv` (with program name at index 0) invokes `stillfail-reader` in
/// whole-station or hook/bridge mode rather than reader/builder mode.
pub fn is_station_shim(argv : Array[String]) -> Bool {
  if argv.length() >= 2 && (is_script_arg(argv[1]) || is_bare_claude_tui(argv[1])) {
    return true
  }
  let args = argv[1:].to_owned()
  if args.contains("--builder") ||
    args.contains("--serve") ||
    args.contains("--sessions") {
    return false
  }
  match command_of(args) {
    Some(c) => shim_station_commands.contains(c)
    None => args.contains("--app") || args.contains("--port")
  }
}

///|
pub fn flag_value(args : Array[String], name : String) -> String? {
  for i = 0; i + 1 < args.length(); i = i + 1 {
    if args[i] == name && args[i + 1] != "" {
      return Some(args[i + 1])
    }
  }
  None
}

///|
fn sep_of(win : Bool) -> String {
  if win {
    "\\"
  } else {
    "/"
  }
}

///|
/// Returns the parent directory of `p` (handling both `/` and `\`).
pub fn parent_dir(p : String) -> String? {
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
fn is_abs_path(p : String, win : Bool) -> Bool {
  if p == "" {
    return false
  }
  if p.has_prefix("/") {
    return true
  }
  if !win {
    return false
  }
  if p.has_prefix("\\") {
    return true
  }
  if p.length() >= 3 {
    let c0 = p.unsafe_get(0).to_int()
    let c1 = p.unsafe_get(1).to_int()
    let c2 = p.unsafe_get(2).to_int()
    let is_letter = (c0 >= 'A' && c0 <= 'Z') || (c0 >= 'a' && c0 <= 'z')
    if is_letter && c1 == ':' && (c2 == '\\' || c2 == '/') {
      return true
    }
  }
  false
}

///|
/// Lexically resolves `p` against `cwd` (folding `.` and `..`) without dereferencing symlinks.
pub fn lexical_resolve(p : String, win : Bool, cwd : String?) -> String {
  let sep = sep_of(win)
  if is_abs_path(p, win) {
    @nodepath.join(sep, [p])
  } else {
    match cwd {
      Some(dir) if dir != "" => @nodepath.join(sep, [dir, p])
      _ => @nodepath.join(sep, [p])
    }
  }
}

///|
/// Infers `<app>` from `stillfail-reader`'s path (`<app>/station/stillfail-reader` -> `<app>`).
pub fn app_from_path(p : String) -> String? {
  guard parent_dir(p) is Some(station_dir) else { return None }
  parent_dir(station_dir)
}

///|
/// Candidate `<app>` directories in priority order:
/// 1. Explicit `--app` flag;
/// 2. Inferred from lexically-normalized invoked `argv[0]` path (preserving symlink location);
/// 3. Inferred from canonical executable path (`self_exe`).
pub fn app_candidates(
  args : Array[String],
  invoked : String?,
  exe : String?,
  win? : Bool = false,
  cwd? : String? = None,
) -> Array[String] {
  let out : Array[String] = []
  let push_unique = (d : String) => if d != "" && !out.contains(d) {
    out.push(d)
  }
  if flag_value(args, "--app") is Some(a) {
    push_unique(a)
  }
  if invoked is Some(p) && app_from_path(lexical_resolve(p, win, cwd)) is Some(a) {
    push_unique(a)
  }
  if exe is Some(p) && app_from_path(p) is Some(a) {
    push_unique(a)
  }
  out
}

///|
/// Resolves the Node executable: STILLFAIL_NODE -> `<app>/node/bin/node` (or `node\node.exe`) -> PATH.
pub fn resolve_node(
  apps : Array[String],
  win : Bool,
  env_node : String?,
  is_exec : (String) -> Bool,
  find_in_path : (String) -> String?,
) -> String? {
  if env_node is Some(n) && n != "" && is_exec(n) {
    return Some(n)
  }
  let sep = sep_of(win)
  for app in apps {
    let cand = if win {
      @nodepath.join(sep, [app, "node", "node.exe"])
    } else {
      @nodepath.join(sep, [app, "node", "bin", "node"])
    }
    if is_exec(cand) {
      return Some(cand)
    }
  }
  find_in_path("node")
}

///|
/// Strips the first positional `"admin"` token from `args`, preserving all flags and remaining args.
pub fn strip_admin_command(args : Array[String]) -> Array[String] {
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
pub struct HandoffPlan {
  entry : String
  args : Array[String]
  notice : String?
} derive(Eq, Debug)

///|
/// Plans the Node script entry, forwarded arguments, and optional stderr retirement notice.
pub fn plan_handoff(
  argv : Array[String],
  win : Bool,
  apps : Array[String],
  is_file : (String) -> Bool,
) -> Result[HandoffPlan, String] {
  let sep = sep_of(win)
  // Case 1: explicit `.mjs` / `.js` hook or bridge script
  if argv.length() >= 2 && is_script_arg(argv[1]) {
    let script = argv[1]
    if !is_file(script) {
      return Err("stillfail-reader: script not found: \{script}")
    }
    let rest : Array[String] = []
    for i = 2; i < argv.length(); i = i + 1 {
      rest.push(argv[i])
    }
    return Ok({ entry: script, args: rest, notice: None })
  }

  // Case 2: bare `claude-tui` alias -> `<app>/station/claude-tui.mjs`
  let listed = apps.join(", ")
  if argv.length() >= 2 && is_bare_claude_tui(argv[1]) {
    for app in apps {
      let cand = @nodepath.join(sep, [app, "station", "claude-tui.mjs"])
      if is_file(cand) {
        let rest : Array[String] = []
        for i = 2; i < argv.length(); i = i + 1 {
          rest.push(argv[i])
        }
        return Ok({ entry: cand, args: rest, notice: None })
      }
    }
    return Err(
      "stillfail-reader: station/claude-tui.mjs was not found under [\{listed}]",
    )
  }

  let args = argv[1:].to_owned()
  let cmd = command_of(args)

  // Case 3: `admin` -> `<app>/station/admin-cli.js` (or dev `<app>/bin/admin-cli.ts`)
  if cmd == Some("admin") {
    for app in apps {
      let built = @nodepath.join(sep, [app, "station", "admin-cli.js"])
      if is_file(built) {
        return Ok({
          entry: built,
          args: strip_admin_command(args),
          notice: Some(
            "stillfail-reader: \"engine\": \"moonbit\" is retired; handing off admin to Node (\{built})",
          ),
        })
      }
      let dev = @nodepath.join(sep, [app, "bin", "admin-cli.ts"])
      if is_file(dev) {
        return Ok({
          entry: dev,
          args: strip_admin_command(args),
          notice: Some(
            "stillfail-reader: \"engine\": \"moonbit\" is retired; handing off admin to Node (\{dev})",
          ),
        })
      }
    }
    return Err(
      "stillfail-reader: \"engine\": \"moonbit\" is retired, and station/admin-cli.js (or bin/admin-cli.ts) was not found under [\{listed}]",
    )
  }

  // Case 4: whole-station commands (`run`, `status`, `id`, ...) or legacy implicit `--app`/`--port`
  for app in apps {
    let main_js = @nodepath.join(sep, [app, "station", "main.js"])
    if is_file(main_js) {
      let forwarded : Array[String] = []
      if cmd is None {
        // Legacy flag-only invocation (`--app DIR` / `--port N`): Node main.ts requires explicit `run` and `--app`.
        forwarded.push("run")
        if flag_value(args, "--app") is None {
          forwarded.push("--app")
          forwarded.push(app)
        }
      }
      for a in args {
        forwarded.push(a)
      }
      return Ok({
        entry: main_js,
        args: forwarded,
        notice: Some(
          "stillfail-reader: \"engine\": \"moonbit\" is retired; handing off to Node (\{main_js})",
        ),
      })
    }
  }
  Err(
    "stillfail-reader: \"engine\": \"moonbit\" is retired, and station/main.js was not found under [\{listed}]",
  )
}
