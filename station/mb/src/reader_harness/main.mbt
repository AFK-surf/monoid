///|
/// The tests' program (station/test/mb-*.test.ts): each package's harness (`harness*.mbt`), which holds it to the
/// TypeScript it ports, asked by `--builder harness-<package>`, plus the frozen whole-station `station_main` commands
/// (`run`, `id`, `enroll`, `channel`, ...) kept out of the shipped `stillfail-reader`. When `station_main` spawns
/// reader/builder/sessions subprocesses via its own `argv[0]`, non-harness reader invocations exec `stillfail-reader`.
fn main {
  let argv = @host.args()
  if @station_main.is_station(argv) {
    @host.exit(@station_main.station_main(argv))
    return
  }
  let code = match (flag("--builder"), flag("--db")) {
    (Some("harness-station-main"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @station_main.harness(host))
    (Some("harness-stdlib"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => harness_stdlib(host))
    (Some("harness-upstream"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => harness_upstream(host))
    (Some("harness-sql-net"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => harness_sql_net(host))
    (Some("harness-session-hub"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => harness_session_hub(host))
    (Some("harness-rigs"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => harness_rigs(host))
    (Some("harness-core-routes"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => harness_core_routes(host))
    (Some("harness-lock"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => harness_lock(host))
    (Some("harness-leaf"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => harness_leaf(host))
    _ => {
      let args = argv[1:].to_owned()
      if args.contains("--builder") || args.contains("--sessions") || args.contains("--serve") || args.contains("--data") {
        if @host.env_get("STILLFAIL_HARNESS_DELEGATED") == Some("1") {
          @host.note("stillfail-reader-harness: delegation loop detected (STILLFAIL_HARNESS_DELEGATED=1); refusing recursive exec")
          1
        } else {
          let self_path = @host.exe_path().unwrap_or(if argv.length() > 0 { argv[0] } else { "" })
          match find_shipped_reader(argv, self_path) {
            Some(reader_bin) => {
              if self_path != "" && @host.same_file(reader_bin, self_path) {
                @host.note("stillfail-reader-harness: STILLFAIL_MB_READER (\{reader_bin}) points to stillfail-reader-harness itself; refusing recursive exec")
                1
              } else {
                ignore(@host.env_set("STILLFAIL_HARNESS_DELEGATED", "1"))
                let child_argv : Array[String] = [reader_bin]
                for a in args {
                  child_argv.push(a)
                }
                @host.exit(@host.exec_replace(reader_bin, child_argv))
                return
              }
            }
            None => {
              @host.note("stillfail-reader-harness: cannot delegate reader/builder invocation; set STILLFAIL_MB_READER or place stillfail-reader beside stillfail-reader-harness")
              1
            }
          }
        }
      } else {
        @host.note("usage: stillfail-reader-harness --builder harness-<package> [--shell-dir <dir> | --db <file>]")
        2
      }
    }
  }
  @host.exit(code)
}

///|
fn find_shipped_reader(argv : Array[String], self_path : String) -> String? {
  if @host.env_get("STILLFAIL_MB_READER") is Some(p) && @host.is_executable_file(p) {
    return Some(p)
  }
  let base_path = if self_path != "" { self_path } else if argv.length() > 0 { argv[0] } else { "" }
  if base_path == "" {
    return None
  }
  let slash = base_path.rev_find("/").unwrap_or(-1)
  let back = base_path.rev_find("\\").unwrap_or(-1)
  let cut = if slash > back { slash } else { back }
  let (dir, sep, base) = if cut < 0 {
    (".", "/", base_path)
  } else {
    let s = if back > slash { "\\" } else { "/" }
    (base_path.exact_view(end=cut).to_owned(), s, base_path.exact_view(start=cut + 1).to_owned())
  }
  if base.contains("-harness") {
    let sibling = dir + sep + base.replace(old="-harness", new="")
    if @host.is_executable_file(sibling) && (self_path == "" || !@host.same_file(sibling, self_path)) {
      return Some(sibling)
    }
  }
  for name in ["stillfail-reader", "stillfail-reader.exe"] {
    let cand = dir + sep + name
    if @host.is_executable_file(cand) && (self_path == "" || !@host.same_file(cand, self_path)) {
      return Some(cand)
    }
  }
  None
}

///|
/// The value after `name` among the program's arguments.
fn flag(name : String) -> String? {
  let args = @host.args()
  for i = 0; i + 1 < args.length(); i = i + 1 {
    if args[i] == name {
      return Some(args[i + 1])
    }
  }
  None
}
