///|
/// The tests' program (station/test/mb-*.test.ts): each package's harness (`harness*.mbt`), which holds it to the
/// TypeScript it ports, asked by `--builder harness-<package>`. Kept out of the station's reader (src/reader), which ships
/// to every station: built only for the tests (station/mb/build.sh --harness, scripts/native.ts `reader-harness`).
fn main {
  let code = match (flag("--builder"), flag("--db")) {
    (Some("harness-store-schema"), Some(db)) =>
      @host.run(shell_dir=beside(db, "shell"), host => @store_schema.harness(host, db))
    (Some("harness-station-main"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @station_main.harness(host))
    (Some("harness-mcp-tools"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @mcp_tools.harness(host))
    (Some("harness-session-hub"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @session_hub.harness(host))
    (Some("harness-vault-service"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @vault_service.harness(host))
    (Some("harness-replica-coord"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @replica_coord.harness(host))
    (Some("harness-connects-hub"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @connects_hub.harness(host))
    (Some("harness-feishu"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @feishu.harness(host))
    (Some("harness-comma"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @comma.harness(host))
    (Some("harness-rigs-mode"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @rigs_mode.harness(host))
    (Some("harness-store-sessions"), Some(db)) =>
      @host.run(shell_dir=beside(db, "shell"), host => @store_sessions.harness(host, db))
    (Some("harness-accounts-oauth"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @accounts_oauth.harness(host))
    (Some("harness-move-coord"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @move_coord.harness(host))
    (Some("harness-store-threads"), Some(db)) =>
      @host.run(shell_dir=beside(db, "shell"), host => @store_threads.harness(host, db))
    (Some("harness-accounts-pool"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @accounts_pool.harness(host))
    (Some("harness-share-sync"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @share_sync.harness(host))
    (Some("harness-cloud-lock"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @cloud_lock.harness(host))
    (Some("harness-agent-drivers"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @agent_drivers.harness(host))
    (Some("harness-cloud-net"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @cloud_net.harness(host))
    (Some("harness-agent-runtimes"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @agent_runtimes.harness(host))
    (Some("harness-slack"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @slack.harness(host))
    (Some("harness-mesh-door"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @mesh_door.harness(host))
    (Some("harness-session-chats"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @session_chats.harness(host))
    (Some("harness-events"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @events.harness(host))
    (Some("harness-session-storage"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @session_storage.harness(host))
    (Some("harness-browser"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @browser.harness(host))
    (Some("harness-screens"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @screens.harness(host))
    (Some("harness-adb-devices"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @adb_devices.harness(host))
    (Some("harness-terminals-logins"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @terminals_logins.harness(host))
    (Some("harness-drive"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @drive.harness(host))
    (Some("harness-updates"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @updates.harness(host))
    (Some("harness-mesh-runtime"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @mesh_runtime.harness(host))
    (Some("harness-api-routes"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @api_routes.harness(host))
    (Some("harness-jobs-host"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @jobs_host.harness(host))
    (Some("harness-ops-platform"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @ops_platform.harness(host))
    (Some("harness-vault-crypto"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => @vault_crypto.harness(host))
    (Some("harness-stdlib"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => harness_stdlib(host))
    (Some("harness-upstream"), _) =>
      @host.run(shell_dir=flag("--shell-dir").unwrap_or("."), host => harness_upstream(host))
    _ => {
      @host.note("usage: stillfail-reader-harness --builder harness-<package> [--shell-dir <dir> | --db <file>]")
      2
    }
  }
  @host.exit(code)
}

///|
/// `name` in the directory `path` is in (the database's: its shell beside it).
fn beside(path : String, name : String) -> String {
  let slash = path.rev_find("/").unwrap_or(-1)
  let back = path.rev_find("\\").unwrap_or(-1)
  let cut = if slash > back { slash } else { back }
  if cut < 0 {
    name
  } else {
    path.exact_view(end=cut + 1).to_owned() + name
  }
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
