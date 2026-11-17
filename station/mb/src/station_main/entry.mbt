// What the program does when it is run as the station itself (`stillfail-reader run …`, `stillfail-reader status`, …)
// or as a hook's command (`stillfail-reader <…>/repo-rules-hook.mjs`), rather than as one of the station's readers or
// builders (reader/main.mbt): those keep every flag and line they had.

///|
/// The station's own commands.
let station_commands : Array[String] = ["run", "enroll", "status", "id", "lock", "channel", "update", "heap"]

///|
/// Whether `argv` (its program first) asks for the station rather than a reader or a builder: a hook's file, one of the
/// station's commands, or `run`'s flags with no command (`--app`, `--port`: how an older launcher ran it).
pub fn is_station(argv : Array[String]) -> Bool {
  if hook_of(argv) is Some(_) {
    return true
  }
  let args = argv[1:].to_array()
  if args.contains("--builder") || args.contains("--serve") || args.contains("--sessions") {
    return false
  }
  match command_of(args) {
    Some(c) => station_commands.contains(c)
    None => args.contains("--app") || args.contains("--port")
  }
}

///|
/// Runs the station as `argv` asks (`is_station`); its exit code.
pub fn station_main(argv : Array[String]) -> Int {
  let argv0 = if argv.length() > 0 { argv[0] } else { "stillfail-reader" }
  if hook_of(argv) is Some(which) {
    // (a hook asks nothing of the shell)
    return @host.run(async fn(host) { @host.exit(run_hook(host, which, argv)) })
  }
  let args = argv[1:].to_array()
  let data = data_dir(args)
  let shell = path([data, "shell"])
  ignore(attempt(() => @drive.mkdir(shell, true)))
  match command_of(args) {
    Some("run") | None => @host.run(shell_dir=shell, async fn(host) { @host.exit(run_station(host, argv0, args)) })
    Some(_) => @host.run(shell_dir=shell, async fn(host) { @host.exit(run_command(host, argv0, args)) })
  }
}
