// Native MoonBit unit tests for ops_platform pure logic.

///|
test "Node's path.win32 and the platform's readings" {
  inspect(win32_resolve(["c:/Users/x/../y/./z"], "C:\\"), content="c:\\Users\\y\\z")
  inspect(win32_relative("C:\\a\\b", "c:\\A\\x", "C:\\"), content="..\\x")
  inspect(win32_dirname("\\\\server\\share\\a"), content="\\\\server\\share\\")
  assert_eq(parse_u64("+12"), Some(12.0))
  assert_eq(pressure_of_level("2", available=Some(1.0), total=Some(100.0)), Some("critical"))
  inspect(proc_address("0100007F"), content="127.0.0.1")
}

///|
test "a command's output and the log as it may leave" {
  inspect(plain_text("\u{1b}[1;32mok\u{1b}[0m\r\nnext"), content="ok\nnext")
  assert_eq(urls_in("see https://a.b/c, then"), ["https://a.b/c"])
  assert_eq(device_code_in("your one-time code: ABCD-1234", []), Some("ABCD-1234"))
  inspect(scrub_text("alice@example.com at /Users/alice/x", ""), content="<email> at ~/x")
  inspect(sha1_hex(b"abc"), content="a9993e364706816aba3e25717850c26c9cd0d89d")
}

///|
test "a command on Windows is found with PATHEXT, never as the POSIX script beside it" {
  let env = [("Path", "C:\\npm;C:\\bin"), ("PATHEXT", ".COM;.EXE;.BAT;.CMD")]
  let join = (parts : Array[String]) => parts.join("\\")
  // npm's `codex` (a `#!/bin/sh` script) and `codex.cmd` side by side: the .cmd, which Windows runs.
  let files = ["C:\\npm\\codex", "C:\\npm\\codex.cmd", "C:\\bin\\git.exe"]
  let there = (p : String) => files.contains(p)
  assert_eq(win_find_command("codex", env, ";", join, there), Some("C:\\npm\\codex.cmd"))
  // A name with its extension already is found as it is.
  assert_eq(win_find_command("git.exe", env, ";", join, there), Some("C:\\bin\\git.exe"))
  assert_eq(win_find_command("git", env, ";", join, there), Some("C:\\bin\\git.exe"))
  // The script alone is no command on Windows.
  assert_eq(win_find_command("codex", env, ";", join, p => p == "C:\\npm\\codex"), None)
  // No PATH, nothing found.
  assert_eq(win_find_command("codex", [], ";", join, there), None)
}

///|
test "path cleaning, base names, extensions, and domains" {
  assert_eq(clean_posix(Unix, "/a/b/../c/./d"), "/a/c/d")
  assert_eq(clean_path(Unix, "/a/b/../c"), "/a/c")
  assert_eq(file_name(Unix, "/a/b/report.pdf"), Some("report.pdf"))
  assert_eq(any_base_name("C:\\dir\\sub\\file.txt"), "file.txt")
  assert_eq(extension("archive.tar.gz"), Some("gz"))
  assert_eq(extension("README"), None)
  assert_eq(domain_of("https://Sub.Example.com:8443/p"), Some("sub.example.com:8443"))
  assert_eq(domain_of("not a url"), None)
}

///|
test "CLI flags, data_dir, env validation, and command parsing" {
  assert_eq(flag(["run", "--data", "/tmp/d", "--port", "9"], "--data"), Some("/tmp/d"))
  assert_eq(flag(["run"], "--data"), None)
  assert_eq(data_dir(["--data", "/custom"], Some("/env"), "/home"), "/custom")
  assert_eq(data_dir([], Some("/env"), "/home"), "/env")
  assert_eq(first_word("  git status --short"), "git")
  assert_true(env_name("VALID_VAR_1"))
  assert_true(!env_name("1BAD"))
  assert_true(!env_name("BAD-NAME"))
  assert_eq(check_agent_env(Some({ "FOO": "bar" })), None)
  assert_true(check_agent_env(Some({ "1BAD": "x" })) is Some(_))
  assert_eq(agent_env({ "agentEnv": { "A": "1" } }), [("A", "1")])
  assert_eq(command_words("git commit -m 'hello world'"), Some(["git", "commit", "-m", "hello world"]))
  assert_eq(command_words("unterminated 'quote"), None)
}

///|
test "disk tiers, cpu_share, cap_plan, and background wrappers" {
  assert_eq(disk_tier(100.0 * 1024.0 * 1024.0 * 1024.0, 200.0 * 1024.0 * 1024.0 * 1024.0), "ok")
  assert_eq(disk_tier(1.0 * 1024.0 * 1024.0, 200.0 * 1024.0 * 1024.0 * 1024.0), "low")
  assert_eq(forewarn_mb(10.0 * 1024.0 * 1024.0), 10.0)
  assert_eq(cpu_share((10.0, 100.0), (30.0, 200.0)), Some(0.2))
  assert_eq(cpu_share((10.0, 100.0), (10.0, 100.0)), None)
  let (drop, freed) = cap_plan([("a", 50.0, 10.0), ("b", 50.0, 20.0), ("c", 50.0, 30.0)], 100.0)
  assert_eq(drop, ["a"])
  assert_eq(freed, 50.0)
  let bg = background_found(true, p => p == "/usr/sbin/taskpolicy", _ => None)
  let (prog, args) = backgrounded_on(bg, "node", ["app.js"])
  assert_eq(prog, "/usr/sbin/taskpolicy")
  assert_eq(args, ["-b", "node", "app.js"])
}

///|
test "login helpers, search keys, memory limits, and config teams" {
  assert_true(asks_enter("Press Enter to open browser"))
  assert_true(!asks_enter("Done."))
  let (ver, full) = device_urls(
    ["https://github.com/login/device", "https://github.com/login/device?user_code=ABCD-1234"],
    "ABCD-1234",
  )
  assert_eq(ver, Some("https://github.com/login/device"))
  assert_eq(full, Some("https://github.com/login/device?user_code=ABCD-1234"))
  let k1 = file_search_key(["/repo"], "foo", false, true, 50, false, [])
  let k2 = file_search_key(["/repo"], "foo", false, true, 50, false, [])
  assert_eq(k1, k2)
  assert_eq(footprint_of_status("VmRSS:\t  1024 kB\n"), Some(1024.0 * 1024.0))
  assert_true(hard_rss_of(16.0 * 1024.0 * 1024.0 * 1024.0) > 0.0)
  let teams = config_teams({ "connects": [{ "id": "f1", "kind": "feishu", "feishu": { "tenant": { "name": "Acme" } } }] })
  assert_eq(teams.length(), 1)
  assert_eq(teams[0].1.name, "Acme")
}

///|
test "board-files manifest, upkeep round, and gone_board_files selection" {
  let entry = storage_entry("board-files").unwrap()
  assert_eq(entry.class, "authoritative")
  assert_eq(entry.max_age_ms, Some(board_files_gone_ms))
  assert_eq(entry.reclaim, Some("Upkeep goneBoardFiles"))
  let round = upkeep_round(true, true, true, true)
  assert_eq(round[round.length() - 1], "board files")
  let now = 10_000_000.0
  let (gone, empty_dirs) = gone_board_files_plan(
    [
      ("p1", "d1", [("old", 1_000_000.0), ("new", 9_999_000.0)]),
      ("p1", "d2", [("b", 2_000_000.0), ("a", 1_000_000.0)]),
      ("p2", "d3", [("c", 9_999_000.0)]),
    ],
    1_000_000.0,
    now,
  )
  assert_eq(gone, ["p1/d1/old", "p1/d2/a", "p1/d2/b"])
  assert_eq(empty_dirs, [("p1", "d2")])
}

///|
test "startEnv never gives the launcher's front to what the station starts" {
  let own = [("PATH", "/bin"), ("STILLFAIL_MESH_FRONT", "/data/run/front.sock")]
  let env = start_env(own, Json::object({ "agentEnv": Json::object({ "STILLFAIL_MESH_FRONT": Json::string("/x") }) }), [])
  assert_true(env.iter().all(p => p.0 != "STILLFAIL_MESH_FRONT"))
  assert_true(env.iter().any(p => p == ("PATH", "/bin")))
}

///|
test "file search Turns aborts same-typist prior searches, drops waiting, and bounds concurrency" {
  let turns = Turns::new()
  // First two go immediately (search_at_once = 2).
  let r1 = turns.ask(1, Some("dev1"), "foo")
  assert_eq(r1, { "stopped": [], "dropped": [], "goes": true })
  let r2 = turns.ask(2, Some("dev2"), "bar")
  assert_eq(r2, { "stopped": [], "dropped": [], "goes": true })
  // Third queues (waiting).
  let r3 = turns.ask(3, Some("dev1"), "foob")
  assert_eq(r3, { "stopped": [1], "dropped": [], "goes": false })
  // Fourth by same typist ("dev1") typing further drops waiting #3 and still flags going #1.
  let r4 = turns.ask(4, Some("dev1"), "fooba")
  assert_eq(r4, { "stopped": [1], "dropped": [3], "goes": false })
  // Completing #1 promotes #4 from waiting to going.
  assert_eq(turns.done(1), Some(4))
  assert_eq(turns.done(2), None)
  assert_eq(turns.done(4), None)
  // Reuse policy: KEPT_MS=5s, again=60s, guessed=20s.
  assert_true(file_search_reuse(Some(4000.0), false, false))
  assert_true(!file_search_reuse(Some(6000.0), false, false))
  assert_true(file_search_reuse(Some(50000.0), true, false))
  assert_true(file_search_reuse(Some(15000.0), false, true))
  assert_true(!file_search_reuse(Some(25000.0), false, true))
}

///|
/// A Keycloak sign-in page's parts (station/test/logins.test.ts `KEYCLOAK_PAGE`): its 330 characters with
/// `Hq3Vt8Lm2Xw9Rz4` between them; 315 without; longer than the login terminal is wide with 750 more in its state.
let keycloak_head : String = "https://sso.acme-corp.example/realms/engineering/protocol/openid-connect/auth?client_id=acme-cli&redirect_uri=https%3A%2F%2Fsso.acme-corp.example%2Fcli%2Fdone&response_type=code&scope=openid+profile+email&state="

///|
let keycloak_tail : String = "Nc7Bp1Fy6Dj5Gk0Tsa&code_challenge=K7xQ2mZpL9vR4tY8wB3nC6hJ1fD5gS0aE2iU7oP4kM9&code_challenge_method=S256"

///|
fn keycloak(state : String) -> String {
  keycloak_head + state + keycloak_tail
}

///|
fn keycloak_longer() -> String {
  let b = StringBuilder::new()
  for _ in 0..<250 {
    b.write_string("Zq9")
  }
  keycloak(b.to_string() + "Hq3Vt8Lm2Xw9Rz4")
}

///|
/// A link broken by its program every `width` columns, each line indented.
fn broken_at(url : String, width : Int, indent : String) -> Array[String] {
  let lines = []
  let per = width - indent.length()
  let mut i = 0
  while i < url.length() {
    lines.push(indent + url.unsafe_substring(start=i, end=@cmp.minimum(url.length(), i + per)))
    i += per
  }
  lines
}

///|
test "a long sign-in page broken by its program at 200 or 80 columns put together; a code, a rule, a prompt, a second link or a sentence after a link not" {
  let page = keycloak("Hq3Vt8Lm2Xw9Rz4")
  let shorter = keycloak("")
  let longer = keycloak_longer()
  assert_eq(page.length(), 330)
  assert_eq(shorter.length(), 315)
  assert_eq(longer.length() > 1000, true)
  // At 200 columns, the line's end said after the link.
  let line = "Visit " + page + " to sign in, then paste the code below."
  let at200 = sub(line, 0, 200) + "\n" + sub(line, 200, line.length()) + "\n\nCode:"
  assert_eq(urls_in(unwrapped(at200, 200)), [page])
  assert_eq(urls_in(unwrapped(at200, 1000)), [page])
  // At 80 columns, indented: five lines, the last a short end.
  for p in [page, shorter] {
    let lines = broken_at(p, 80, "  ")
    assert_eq(lines.length(), 5)
    let said = "Open this page in your browser:\n" + lines.join("\n") + "\n\nEnter the code:"
    assert_eq(urls_in(unwrapped(said, 1000)), [p])
    assert_eq(unwrapped(said, 1000), "Open this page in your browser:\n  " + p + "\n\nEnter the code:")
  }
  assert_eq(broken_at(shorter, 80, "  ")[4], "  256")
  let lines = broken_at(page, 80, "  ")
  assert_eq(url_continuation(lines[0], js_trim_end(lines[0]), lines[1], 1000, None), Some(80))
  assert_eq(url_continuation(lines[3], "  " + sub(page, 0, 312), lines[4], 1000, Some(80)), Some(80))
  // Longer than the terminal is wide, broken at its width.
  let long_line = "Visit " + longer + " to sign in."
  assert_eq(urls_in(unwrapped(sub(long_line, 0, 1000) + "\n" + sub(long_line, 1000, long_line.length()), 1000)), [longer])
  // What follows a whole link, or a short one, is no more of it.
  for next in ["ABCD-1234", "vFA9uVPF", "Code:", "================", "https://github.com/login/device", "Then press Enter to continue.", "(Y/n)"] {
    let said = "  " + page + "\n  " + next
    assert_eq(unwrapped(said, 1000), said)
  }
  assert_eq(
    unwrapped("open https://github.com/login/device\nand/enter=x", 1000),
    "open https://github.com/login/device\nand/enter=x",
  )
  // As before: a line as wide as the terminal goes on.
  let wide = sub(line, 0, 200)
  assert_eq(url_continuation(wide, wide, "rest", 200, None), Some(200))
  assert_eq(url_continuation(wide, wide, "rest", 1000, None), None)
}

///|
test "the swap says what the memory used leaves out" {
  let gib = 1024.0 * 1024.0 * 1024.0
  // 66 GiB swapped on a 64 GiB machine, pages still going out: critical; swap kept from before, nothing going out: normal.
  assert_eq(pressure_of_swap(Some(66.0 * gib), Some(64.0 * gib), Some(5000.0)), Some("critical"))
  assert_eq(pressure_of_swap(Some(20.0 * gib), Some(64.0 * gib), Some(5000.0)), Some("high"))
  assert_eq(pressure_of_swap(Some(66.0 * gib), Some(64.0 * gib), Some(0.0)), Some("normal"))
  assert_eq(pressure_of_swap(Some(66.0 * gib), Some(64.0 * gib), None), None)
  assert_eq(worse_pressure(Some("normal"), Some("critical")), Some("critical"))
  assert_eq(worse_pressure(None, Some("high")), Some("high"))
  assert_eq(swapouts_of("Pages free: 1.\nSwapouts:                                  375142124.\n"), Some(375142124.0))
  assert_eq(swap_used_of("total = 68608.00M  used = 66279.69M  free = 2328.31M  (encrypted)"), Some(69499292221.0))
}

///|
test "is_monoid_station_vm and elastic_memory" {
  let real = "memory_hotplug.memmap_on_memory=1 console=hvc0 lockdown=confidentiality monoid.vm=station systemd.hostname=station psi=1 loglevel=4"
  assert_true(is_monoid_station_vm(real))
  assert_true(!is_monoid_station_vm("monoid.vm=apps"))
  assert_true(!is_monoid_station_vm("xmonoid.vm=station"))
  assert_true(!is_monoid_station_vm("monoid.vm=stationx"))
  assert_true(!is_monoid_station_vm(""))

  let total = 12681484.0 * 1024.0
  let used = 4000000000.0
  let base : Memory = { total_bytes: total, used_bytes: used, swap_used_bytes: Some(0.0), known: None }
  let pvg : Json = {
    "boot": 6576668672.0,
    "guarantee": 11811160064.0,
    "max": 26306674688.0,
    "plugged": 6845104128.0,
    "target": 6845104128.0,
  }
  let expanded = elastic_memory(base, pvg)
  assert_eq(expanded.total_bytes, total + 12884901888.0)
  assert_eq(expanded.used_bytes, used)
  assert_eq(expanded.swap_used_bytes, Some(0.0))
  assert_eq(expanded.known, None)

  assert_eq(elastic_memory(base, { "boot": 1000.0, "plugged": 500.0, "max": 1500.0 }).total_bytes, total)
  assert_eq(elastic_memory(base, { "boot": 1000.0, "plugged": 500.0, "max": 1200.0 }).total_bytes, total)
  assert_eq(elastic_memory(base, { "boot": 1000.0, "plugged": 500.0 }).total_bytes, total)
  assert_eq(elastic_memory(base, { "boot": "1000", "plugged": 500.0, "max": 5000.0 }).total_bytes, total)
  assert_eq(elastic_memory(base, Json::null()).total_bytes, total)
  let unknown : Memory = { total_bytes: total, used_bytes: 0.0, swap_used_bytes: None, known: Some(false) }
  assert_eq(elastic_memory(unknown, pvg).total_bytes, total)
  assert_eq(elastic_memory(unknown, pvg).known, Some(false))
}
