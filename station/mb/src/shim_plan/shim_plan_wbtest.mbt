///|
test "is_station_shim matches whole-station commands, flags, scripts, and bare claude-tui" {
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
  assert_true(is_station_shim(["stillfail-reader", "claude-tui", "hook"]))
  assert_true(is_station_shim(["stillfail-reader", "/tmp/helper.js", "--flag"]))
  // Reader / builder / sessions / serve modes stay in reader
  assert_false(is_station_shim(["stillfail-reader", "--data", "/data"]))
  assert_false(is_station_shim(["stillfail-reader", "--builder", "mesh", "--socket", "/tmp/s"]))
  assert_false(is_station_shim(["stillfail-reader", "--serve", "/tmp/r.sock", "--data", "/data"]))
  assert_false(is_station_shim(["stillfail-reader", "--sessions", "1", "--data", "/data"]))
  assert_false(is_station_shim(["stillfail-reader"]))
}

///|
test "app_candidates preserves symlinked argv0 before canonical exe path" {
  let apps = app_candidates(
    ["status"],
    Some("/release/app/station/stillfail-reader"),
    Some("/cache/store/stillfail-reader"),
  )
  assert_eq(apps, ["/release/app", "/cache"])

  let with_flag = app_candidates(
    ["run", "--app", "/explicit/app"],
    Some("/release/app/station/stillfail-reader"),
    Some("/cache/store/stillfail-reader"),
  )
  assert_eq(with_flag, ["/explicit/app", "/release/app", "/cache"])

  // Relative and absolute symlink invocations resolved lexically against cwd without dereferencing symlinks
  assert_eq(
    app_candidates(
      ["admin", "--help"],
      Some("station/stillfail-reader"),
      Some("/cache/store/stillfail-reader"),
      cwd=Some("/release/app"),
    ),
    ["/release/app", "/cache"],
  )
  assert_eq(
    app_candidates(
      ["admin", "--help"],
      Some("./stillfail-reader"),
      Some("/cache/store/stillfail-reader"),
      cwd=Some("/release/app/station"),
    ),
    ["/release/app", "/cache"],
  )
  assert_eq(
    app_candidates(
      ["admin", "--help"],
      Some("../stillfail-reader"),
      Some("/cache/store/stillfail-reader"),
      cwd=Some("/release/app/station/sub"),
    ),
    ["/release/app", "/cache"],
  )
  assert_eq(
    app_candidates(
      ["admin", "--help"],
      Some("/release/app/station/stillfail-reader"),
      Some("/cache/store/stillfail-reader"),
      cwd=Some("/release/app/station"),
    ),
    ["/release/app", "/cache"],
  )
  assert_eq(
    app_candidates(
      ["admin", "--help"],
      Some("..\\stillfail-reader.exe"),
      Some("C:\\cache\\store\\stillfail-reader.exe"),
      win=true,
      cwd=Some("C:\\release\\app\\station\\sub"),
    ),
    ["C:\\release\\app", "C:\\cache"],
  )
  assert_eq(app_from_path("stillfail-reader"), None)
}

///|
test "resolve_node follows STILLFAIL_NODE -> app/node -> PATH with explicit win flag" {
  let found_env = resolve_node(
    ["/app"],
    false,
    Some("/custom/node"),
    p => p == "/custom/node" || p == "/app/node/bin/node",
    _ => Some("/usr/bin/node"),
  )
  assert_eq(found_env, Some("/custom/node"))

  let found_app = resolve_node(
    ["/app"],
    false,
    Some("/missing/node"),
    p => p == "/app/node/bin/node",
    _ => Some("/usr/bin/node"),
  )
  assert_eq(found_app, Some("/app/node/bin/node"))

  let found_win = resolve_node(
    ["C:\\app"],
    true,
    None,
    p => p == "C:\\app\\node\\node.exe",
    _ => None,
  )
  assert_eq(found_win, Some("C:\\app\\node\\node.exe"))

  let found_path = resolve_node(
    ["/app"],
    false,
    None,
    _ => false,
    name => if name == "node" { Some("/usr/local/bin/node") } else { None },
  )
  assert_eq(found_path, Some("/usr/local/bin/node"))
}

///|
test "plan_handoff injects run (and --app when omitted) for legacy flag-only invocations" {
  let with_app = plan_handoff(
    ["stillfail-reader", "--app", "/app", "--port", "4760"],
    false,
    ["/app"],
    p => p == "/app/station/main.js",
  )
  assert_eq(
    with_app,
    Ok({
      entry: "/app/station/main.js",
      args: ["run", "--app", "/app", "--port", "4760"],
      notice: Some(
        "stillfail-reader: \"engine\": \"moonbit\" is retired; handing off to Node (/app/station/main.js)",
      ),
    }),
  )

  let port_only = plan_handoff(
    ["stillfail-reader", "--port", "4760", "--data", "/data"],
    false,
    ["/app"],
    p => p == "/app/station/main.js",
  )
  assert_eq(
    port_only,
    Ok({
      entry: "/app/station/main.js",
      args: ["run", "--app", "/app", "--port", "4760", "--data", "/data"],
      notice: Some(
        "stillfail-reader: \"engine\": \"moonbit\" is retired; handing off to Node (/app/station/main.js)",
      ),
    }),
  )
}

///|
test "plan_handoff maps bare claude-tui alias and admin command" {
  let tui = plan_handoff(
    ["stillfail-reader", "claude-tui", "hook", "--flag"],
    false,
    ["/app"],
    p => p == "/app/station/claude-tui.mjs",
  )
  assert_eq(
    tui,
    Ok({ entry: "/app/station/claude-tui.mjs", args: ["hook", "--flag"], notice: None }),
  )

  let adm = plan_handoff(
    ["stillfail-reader", "admin", "--data", "/d", "whoami"],
    false,
    ["/app"],
    p => p == "/app/station/admin-cli.js",
  )
  assert_eq(
    adm,
    Ok({
      entry: "/app/station/admin-cli.js",
      args: ["--data", "/d", "whoami"],
      notice: Some(
        "stillfail-reader: \"engine\": \"moonbit\" is retired; handing off admin to Node (/app/station/admin-cli.js)",
      ),
    }),
  )
}
