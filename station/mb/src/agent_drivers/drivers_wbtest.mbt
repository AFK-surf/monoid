// Native MoonBit unit tests for agent_drivers core helpers.

///|
test "an ISO time as Date.parse reads it" {
  inspect(date_parse("1970-01-01T00:00:00Z"), content="Some(0)")
  inspect(date_parse("2026-11-16T12:34:56.789123+08:00"), content="Some(1794803696789)")
  inspect(date_parse("2026-11-16"), content="Some(1794787200000)")
  inspect(date_parse("soon"), content="None")
  inspect(date_parse("2026-13-01"), content="None")
}

///|
test "a key as a runner's id has it" {
  inspect(key_part("chat_abc"), content="chat_abc")
  inspect(key_part("a/b").has_prefix("a_b-"), content="true")
  inspect(runner_id("codex", "cx"), content="codex-cx")
}

///|
test "a model's own limit told apart from the account's" {
  inspect(model_limit_of("You've reached your Fable limit. Switch"), content=(
    #|Some(Fable)
  ))
  inspect(model_limit_of("You've hit your weekly limit"), content="None")
  inspect(model_limit_of("you reached your 5-hour limit"), content="None")
}

///|
test "a thinking level taken off a model's id, and the variant offered" {
  inspect(agy_base_model("gemini-4-carbon-high"), content=(
    #|(gemini-4-carbon, Some(high))
  ))
  inspect(
    agy_variant("gemini-4-carbon", Some("high"), ["gemini-4-carbon-low", "gemini-4-carbon-high"], None),
    content=(
      #|Some(gemini-4-carbon-high)
    ),
  )
  inspect(agy_variant("x", None, ["y"], None), content="None")
}

///|
test "Antigravity plans use known IDs or Google's display name" {
  for plan in [
    ("free-tier", "Free"),
    ("g1-plus-tier", "Plus"),
    ("g1-pro-tier", "Pro"),
    ("g1-ultra-lite-tier", "Ultra 5x"),
    ("g1-ultra-tier", "Ultra 20x"),
    ("gcp-ge-standard-tier", "Enterprise"),
    ("gcp-ge-plus-tier", "Enterprise Plus"),
    ("gcp-ge-ultra-tier", "Enterprise Ultra"),
    ("gcp-standard-tier", "Enterprise"),
  ] {
    assert_eq(agy_plan(Some(obj([("id", s(plan.0))]))), Some(plan.1))
  }
  let session =
    #|{"_meta":{"antigravity":{"tier":{"id":"g1-ultra-lite-tier","name":"Google AI Ultra"}}}}
  assert_eq(agy_session_plan(parse_json(session)), Some("Ultra 5x"))
  let named =
    #|{"_meta":{"antigravity":{"tier":{"name":" Google AI Pro Trial "}}}}
  assert_eq(agy_session_plan(parse_json(named)), Some("Google AI Pro Trial"))
  let stored =
    #|{"auth_method":"gcp","user_tier":"gcp-future-tier","tier_display_name":"Pay As You Go"}
  assert_eq(agy_plan_in(stored), Some("Pay As You Go"))
  assert_eq(agy_plan(Some(obj([("id", s("future-tier")), ("name", s("Unknown"))]))), None)
}

///|
test "lines whole however they are cut" {
  let lines = Lines::new()
  inspect(lines.take(b"ab").length(), content="0")
  let got = lines.take(b"c\nd\n")
  inspect(got.map(x => utf8_text(x)), content=(
    #|[abc, d]
  ))
}

///|
test "what is waited on runs in turn, never in what settled it" {
  let lp = Loop::new()
  let order = []
  let later : Later[Int] = Later::new(lp)
  later.map(v => order.push("then \{v}")) |> ignore
  later.resolve(1)
  order.push("resolved")
  lp.run()
  inspect(order, content=(
    #|[resolved, then 1]
  ))
  let timed = []
  lp.after(10.0, () => timed.push(lp.now)) |> ignore
  lp.advance(5.0)
  inspect(timed.length(), content="0")
  lp.advance(10.0)
  inspect(timed, content="[10]")
}

///|
test "paths in Rust's order, a version read" {
  let paths = ["/a-b/x", "/a/b/x", "/a/x"]
  paths.sort_by(compare_paths)
  inspect(paths, content=(
    #|[/a/b/x, /a/x, /a-b/x]
  ))
  inspect(version_in("codex-cli 0.169.0"), content=(
    #|Some(0.169.0)
  ))
  inspect(user_agent_version(Some(s("stillfail/0.162.1 (Mac OS) x"))), content=(
    #|Some(0.162.1)
  ))
}

///|
test "a process taken up after a crash before the door opened knows no address of the station's tools" {
  inspect(crashed_tools_url(Some(obj([("mcpUrl", s(""))]))), content="None")
  inspect(crashed_tools_url(Some(obj([]))), content="None")
  inspect(crashed_tools_url(Some(obj([("mcpUrl", s("http://127.0.0.1:4750/mcp"))]))), content=(
    #|Some(http://127.0.0.1:4750/mcp)
  ))
}

///|
test "a profile's own proxy leaves this machine out too" {
  let env = Env::new([("PATH", "/bin")])
  env.merge([("HTTPS_PROXY", "http://127.0.0.1:7890"), ("NO_PROXY", "corp.example")])
  let kept = keep_local(env)
  inspect(kept.get("NO_PROXY"), content=(
    #|Some(corp.example,localhost,127.0.0.1,::1)
  ))
  inspect(kept.get("no_proxy"), content=(
    #|Some(corp.example,localhost,127.0.0.1,::1)
  ))
}

///|
test "what the station starts never carries the launcher's front, whatever its environment or agentEnv say" {
  let raw = Env::new([
    ("PATH", "/bin"),
    ("STILLFAIL_MESH_FRONT", "/data/run/front.sock"),
    ("OPENAI_API_KEY", "sk"),
  ])
  let env = start_env(raw, ["OPENAI_API_KEY"])
  assert_true(env.get("STILLFAIL_MESH_FRONT") is None)
  assert_true(env.get("OPENAI_API_KEY") is None)
  assert_true(env.get("PATH") == Some("/bin"))
  assert_true(start_env(raw, []).get("STILLFAIL_MESH_FRONT") is None)
}

///|
test "Codex's CA file: the first of the system's there, each looked at only after the one before is not" {
  let lp = Loop::new()
  let asked = []
  let there = (have : Array[String]) => (p : String) => {
    asked.push(p)
    Later::ok(lp, have.contains(p))
  }
  let got : Ref[String?] = Ref(None)
  // (a Fedora machine: Debian's file not there, its own is; macOS's never looked at)
  first_there(lp, there(["/etc/pki/tls/certs/ca-bundle.crt", "/etc/ssl/cert.pem"]), ca_bundles()).map(f => got.val = f)
  |> ignore
  lp.run()
  assert_eq(got.val, Some("/etc/pki/tls/certs/ca-bundle.crt"))
  assert_eq(asked, ["/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt"])
  // (a Mac: macOS's, the last)
  first_there(lp, there(["/etc/ssl/cert.pem"]), ca_bundles()).map(f => got.val = f) |> ignore
  lp.run()
  assert_eq(got.val, Some("/etc/ssl/cert.pem"))
  // (none there: none)
  first_there(lp, there([]), ca_bundles()).map(f => got.val = f) |> ignore
  lp.run()
  assert_eq(got.val, None)
}

///|
fn fake_codex_machine(
  lp : Loop,
  files : Map[String, String],
  alive_pids : Set[Int],
) -> Machine {
  {
    lp,
    sep: "/",
    socket_visible: false,
    says_leave: false,
    read_dir: dir => {
      let prefix = dir + "/"
      let out : Array[String] = []
      for k, _ in files {
        if k.has_prefix(prefix) {
          let name = k.substring(start=prefix.length())
          if !name.contains("/") {
            out.push(name)
          }
        }
      }
      Later::ok(lp, out)
    },
    read_file: path => match files.get(path) {
      Some(t) => Later::ok(lp, t)
      None => Later::fail(lp, Failed("ENOENT"))
    },
    mtime: _ => Later::ok(lp, None),
    size: _ => Later::ok(lp, None),
    read_at: (_, _, _) => Later::ok(lp, b""),
    remove: _ => done(lp),
    there: _ => Later::ok(lp, true),
    is_file: _ => Later::ok(lp, false),
    realpath: p => Later::ok(lp, Some(p)),
    make_dir: _ => done(lp),
    link: (_, _) => done(lp),
    stat: (_, _) => Later::ok(lp, None),
    write_file: (_, _, _) => done(lp),
    append_file: (_, _) => done(lp),
    remove_tree: _ => done(lp),
    rename: (_, _) => done(lp),
    copy: (_, _) => done(lp),
    copy_file: (_, _) => done(lp),
    hard_link: (_, _) => done(lp),
    link_path: (_, _) => done(lp),
    pid_alive: pid => alive_pids.contains(pid),
    group_alive: _ => false,
    start_time: _ => Later::ok(lp, None),
    connect: (_, _) => {
      write: _ => (),
      end: () => (),
      destroy: () => (),
      writable: () => false,
      destroyed: () => true,
    },
    sleep: ms => {
      let out = Later::new(lp)
      lp.after(ms, () => out.resolve(())) |> ignore
      out
    },
    now: () => lp.now,
    log: (_, _, _, _) => (),
  }
}

///|
fn fake_codex_proc(lp : Loop, id : String, runner_pid : Int, alive : Ref[Bool], killed : Ref[Int]) -> Proc {
  let info : RunnerInfo = {
    json: obj([
      ("id", s(id)),
      ("runner", n(runner_pid)),
      ("pgid", n(runner_pid)),
      ("startedAt", d(1000.0)),
      ("socket", s("/tmp/\{id}.sock")),
      ("keeps", b(true)),
    ]),
  }
  {
    info,
    write: _ => (),
    tell: _ => (),
    say: (_, _) => (),
    keep_from: _ => (),
    freeze: () => (),
    frozen_state: () => None,
    detach: () => (),
    kill: _ => {
      killed.val += 1
      alive.val = false
      done(lp)
    },
    released: () => done(lp),
    has_exited: () => !alive.val,
    handed: () => false,
    thread: (_, _, _) => (),
    drop_thread: _ => (),
    route_thread: (_, _, _) => false,
    route: _ => (),
    orphans_off: () => (),
  }
}

///|
fn fake_codex_driver(m : Machine) -> CodexDriver {
  let lp = m.lp
  let procs : Procs = {
    start: (_, _, _, _, _, _, _) => Later::fail(lp, Failed("unused")),
    adopt: (_, _, _, _) => abort("unused"),
    replay_own: (_, _, _, _) => Later::ok(lp, Null),
    replay: _ => Later::ok(lp, obj([])),
    freeze: _ => done(lp),
    thaw: _ => (),
    close: () => done(lp),
  }
  let world : CodexWorld = {
    raw_env: Env::new([]),
    agent_env: () => [],
    walk_skills: _ => Later::ok(lp, []),
    host_skills: "",
    ca_bundles: [],
    fast: None,
    speed: None,
    current_profile: None,
    lent_borrowed: None,
    lent_write: None,
    installed_version: () => Later::ok(lp, None),
    missing_host: (_, _) => Later::ok(lp, false),
    incomplete_installation: () => (),
    link_auth: _ => done(lp),
    remember_rollout: (_, _, _) => (),
    update_matches: _ => Later::ok(lp, false),
    taken_up: None,
    taking: () => (),
    output_limit: 1_000_000,
    take_up_bytes: 1_000_000,
    warm_ms: 60_000.0,
  }
  let profiles : ProfileSays = { env: (_, _) => [], codex_overrides: _ => [] }
  let words : Words = {
    repo_rules_command: "",
    agy_repo_rules_command: "",
    subagent_hook_command: "",
    speaks: [],
    speaks_writing: "",
  }
  CodexDriver::new(m, "/data", procs, world, profiles, words)
}

///|
test "codex #7503: ensure_ready refuses dead ready host, ended skips left_runners, opening guards retire/drain until let_go" {
  let lp = Loop::new()
  let files : Map[String, String] = {}
  let alive_pids : Set[Int] = Set::from_array([101, 102])
  let m = fake_codex_machine(lp, files, alive_pids)
  let driver = fake_codex_driver(m)

  // 1. ensure_ready refuses a ready host that has exited.
  let dead_flag = Ref::new(false)
  let dead_kills = Ref::new(0)
  let dead_host = Host::new(m, "p1", "sig", 1.0, true, "p1")
  dead_host.proc = Some(fake_codex_proc(lp, "codex-p1", 101, dead_flag, dead_kills))
  let err_msg = Ref::new("")
  dead_host
  .ensure_ready()
  .on(r => if r is Err(e) { err_msg.val = words_of(e) })
  lp.run()
  assert_eq(err_msg.val, "codex app-server is not running")

  // 2. opening > 0 prevents retire_stale and drain from killing; let_go triggers drain when opening reaches 0.
  let h_alive = Ref::new(true)
  let h_kills = Ref::new(0)
  let host = Host::new(m, "p1", "sig", 1.0, true, "p1")
  host.proc = Some(fake_codex_proc(lp, "codex-p1", 101, h_alive, h_kills))
  host.login_stale = true
  host.opening = 1
  driver.host_set("p1", host)

  driver.retire_stale("p1", None) |> ignore
  lp.run()
  assert_eq(h_kills.val, 0)
  assert_true(driver.is_current(host))

  host.draining = true
  driver.host_delete("p1")
  driver.draining_add(host)
  driver.drain(host) |> ignore
  lp.run()
  assert_eq(h_kills.val, 0)
  assert_true(driver.draining_has(host))

  driver.let_go(host)
  lp.run()
  assert_eq(h_kills.val, 1)
  assert_true(!driver.draining_has(host))
  assert_true(driver.ended.contains("codex-p1:101"))

  // 3. left_runners skips runners in `ended`, keeps others, and forgets gone entries from `ended`.
  files["/data/run/runners/codex-p1.json"] = json_text(
    obj([("id", s("codex-p1")), ("runner", n(101)), ("startedAt", d(1000.0))]),
  )
  files["/data/run/runners/codex-p1.2.json"] = json_text(
    obj([("id", s("codex-p1.2")), ("runner", n(102)), ("startedAt", d(2000.0))]),
  )
  let found_ids : Ref[Array[String]] = Ref([])
  driver.left_runners("p1").map(rs => found_ids.val = rs.map(r => r.id())) |> ignore
  lp.run()
  assert_eq(found_ids.val, ["codex-p1.2"])
  assert_true(driver.ended.contains("codex-p1:101"))

  // Once pid 101 exits, left_runners forgets "codex-p1:101" from `ended`.
  alive_pids.remove(101)
  driver.left_runners("p1").map(rs => found_ids.val = rs.map(r => r.id())) |> ignore
  lp.run()
  assert_eq(found_ids.val, ["codex-p1.2"])
  assert_true(!driver.ended.contains("codex-p1:101"))
}

///|
/// `AgyDriver::begin`'s openings as `agy_opened_again` runs them, each a process that offers no models
/// (`AgyNoCatalog`): how many were opened (`spawned`), how many waits begun (`slept`), and how it ended.
fn agy_offline_openings(
  cancel_at_open? : Int = -1,
  cancel_in_sleep? : Int = -1,
) -> (Int, Int, String) {
  let lp = Loop::new()
  let cancelled = Ref(false)
  let spawned = Ref(0)
  let slept = Ref(0)
  let once = () => {
    spawned.val += 1
    // (given up while its process opened, before it said it offers no models)
    if spawned.val == cancel_at_open {
      cancelled.val = true
    }
    let out : Later[Int] = Later::new(lp)
    lp.soon(() => out.reject(Failed("Antigravity CLI could not load its model catalog: connection failed")))
    out
  }
  let sleep = (ms : Double) => {
    slept.val += 1
    let out : Later[Unit] = Later::new(lp)
    lp.after(ms, () => out.resolve(())) |> ignore
    // (given up during that wait)
    if slept.val == cancel_in_sleep {
      lp.after(ms / 2.0, () => cancelled.val = true) |> ignore
    }
    out
  }
  let ended = Ref("pending")
  agy_opened_again(lp, once, sleep, () => cancelled.val, (_, _) => ()).on(r => ended.val = match r {
    Ok(_) => "opened"
    Err(Failed(msg)) => msg
    Err(e) => e.to_string()
  })
  lp.run()
  lp.advance(60_000.0)
  lp.run()
  (spawned.val, slept.val, ended.val)
}

///|
test "an Antigravity opening given up before its process said it offers no models never waits nor opens again" {
  inspect(agy_offline_openings(cancel_at_open=1), content=(
    #|(1, 0, open aborted)
  ))
}

///|
test "an Antigravity opening given up during its wait to open again opens nothing after it" {
  inspect(agy_offline_openings(cancel_in_sleep=1), content=(
    #|(1, 1, open aborted)
  ))
}

///|
test "an Antigravity opening not given up opens again after each wait, then fails as the network" {
  inspect(agy_offline_openings(), content=(
    #|(4, 3, Antigravity CLI could not load its model catalog: connection failed)
  ))
}
