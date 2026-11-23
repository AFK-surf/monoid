// Lightweight hot-upgrade shim for retired whole-station MoonBit invocations.
// Planning logic lives in pure MoonBit (`station/shim_plan`) so `moon test` exercises it directly;
// this module performs OS lookups and hands off via `@host.exec_replace` (`execv` on Unix,
// `CreateProcessW` + `KILL_ON_JOB_CLOSE | SILENT_BREAKAWAY_OK` Job Object on Windows).

///|
pub fn is_station_shim(argv : Array[String]) -> Bool {
  @shim_plan.is_station_shim(argv)
}

///|
fn invoked_path(argv0 : String) -> String? {
  if argv0 == "" {
    return None
  }
  if argv0.contains("/") || argv0.contains("\\") {
    Some(argv0)
  } else {
    @host.find_in_path(argv0)
  }
}

///|
/// Hands off a retired whole-station or hook/bridge invocation to Node.
pub fn run_station_shim(argv : Array[String]) -> Int {
  let argv0 = if argv.length() > 0 { argv[0] } else { "stillfail-reader" }
  let win = @host.is_windows()
  let args = argv[1:].to_owned()
  let apps = @shim_plan.app_candidates(
    args,
    invoked_path(argv0),
    @host.exe_path(),
    win~,
    cwd=@host.getcwd(),
  )

  guard @shim_plan.resolve_node(
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

  match @shim_plan.plan_handoff(argv, win, apps, @host.is_file) {
    Err(msg) => {
      @host.note(msg)
      1
    }
    Ok(plan) => {
      if plan.notice is Some(line) {
        @host.note(line)
      }
      let child_argv : Array[String] = [node, plan.entry]
      for a in plan.args {
        child_argv.push(a)
      }
      @host.exec_replace(node, child_argv)
    }
  }
}
