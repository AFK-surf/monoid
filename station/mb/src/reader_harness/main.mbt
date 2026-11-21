///|
/// The tests' program (station/test/mb-*.test.ts): each package's harness (`harness*.mbt`), which holds it to the
/// TypeScript it ports, asked by `--builder harness-<package>`. Kept out of the station's reader (src/reader), which ships
/// to every station: built only for the tests (station/mb/build.sh --harness, scripts/native.ts `reader-harness`).
fn main {
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
    _ => {
      @host.note("usage: stillfail-reader-harness --builder harness-<package> [--shell-dir <dir> | --db <file>]")
      2
    }
  }
  @host.exit(code)
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
