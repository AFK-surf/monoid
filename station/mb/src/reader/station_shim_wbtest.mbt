///|
test "is_station_shim matches whole-station commands, flags, and scripts, and skips reader/builder modes" {
  assert_true(is_station_shim(["stillfail-reader", "run", "--app", "/app", "--data", "/data"]))
  assert_true(is_station_shim(["stillfail-reader", "status", "--data", "/data"]))
  assert_true(is_station_shim(["stillfail-reader", "id", "--data", "/data"]))
  assert_true(is_station_shim(["stillfail-reader", "enroll", "https://c", "tok"]))
  assert_true(is_station_shim(["stillfail-reader", "lock", "status"]))
  assert_true(is_station_shim(["stillfail-reader", "channel", "beta"]))
  assert_true(is_station_shim(["stillfail-reader", "update", "--app", "/app"]))
  assert_true(is_station_shim(["stillfail-reader", "heap", "--data", "/data"]))
  assert_true(is_station_shim(["stillfail-reader", "admin", "--data", "/data", "whoami"]))
  assert_true(is_station_shim(["stillfail-reader", "--app", "/app", "--data", "/data"]))
  assert_true(is_station_shim(["stillfail-reader", "--port", "4760", "--data", "/data"]))
  assert_true(is_station_shim(["stillfail-reader", "/app/station/repo-rules-hook.mjs"]))
  assert_true(is_station_shim(["stillfail-reader", "C:\\app\\station\\claude-tui.mjs", "hook"]))
  assert_true(is_station_shim(["stillfail-reader", "/tmp/helper.js", "--flag"]))
  // Reader / builder / sessions / serve modes stay in reader
  assert_false(is_station_shim(["stillfail-reader", "--data", "/data"]))
  assert_false(is_station_shim(["stillfail-reader", "--builder", "mesh", "--socket", "/tmp/s"]))
  assert_false(is_station_shim(["stillfail-reader", "--serve", "/tmp/r.sock", "--data", "/data"]))
  assert_false(is_station_shim(["stillfail-reader", "--sessions", "1", "--data", "/data"]))
  assert_false(is_station_shim(["stillfail-reader"]))
}

///|
test "resolve_node_with follows STILLFAIL_NODE -> app/node -> PATH precedence" {
  let found_env = resolve_node_with(
    ["/app"],
    false,
    Some("/custom/node"),
    p => p == "/custom/node" || p == "/app/node/bin/node",
    _ => Some("/usr/bin/node"),
  )
  assert_eq(found_env, Some("/custom/node"))

  let found_app = resolve_node_with(
    ["/app"],
    false,
    Some("/missing/node"),
    p => p == "/app/node/bin/node",
    _ => Some("/usr/bin/node"),
  )
  assert_eq(found_app, Some("/app/node/bin/node"))

  let found_win = resolve_node_with(
    ["C:\\app"],
    true,
    None,
    p => p == "C:\\app\\node\\node.exe",
    _ => None,
  )
  assert_eq(found_win, Some("C:\\app\\node\\node.exe"))

  let found_path = resolve_node_with(
    ["/app"],
    false,
    None,
    _ => false,
    name => if name == "node" { Some("/usr/local/bin/node") } else { None },
  )
  assert_eq(found_path, Some("/usr/local/bin/node"))
}

///|
test "app_from_exe and strip_admin_command" {
  assert_eq(app_from_exe("/opt/stillfail/station/stillfail-reader"), Some("/opt/stillfail"))
  assert_eq(app_from_exe("C:\\stillfail\\station\\stillfail-reader.exe"), Some("C:\\stillfail"))
  assert_eq(
    strip_admin_command(["admin", "--data", "/d", "whoami"]),
    ["--data", "/d", "whoami"],
  )
  assert_eq(
    strip_admin_command(["--data", "/d", "admin", "users", "list"]),
    ["--data", "/d", "users", "list"],
  )
}
