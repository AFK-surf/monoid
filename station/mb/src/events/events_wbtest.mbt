///|
test "EventLog appends, tracks sequence ids, replays after, and restores from state" {
  let log = EventLog::new("ab", ms=10_000.0, most=3, bytes=4096)
  let e1 = log.append("e", "{\"n\":1}", Null, 100.0, of="s1")
  inspect(e1.text, content="id: ab.1\nevent: e\ndata: {\"n\":1}\n\n")
  let e2 = log.append("e", "{\"n\":2}", Null, 200.0, of="s2")
  let e3 = log.append("e", "{\"n\":3}", Null, 300.0, of="s1")
  // Superseding the same `of` key clears the earlier entry's text
  assert_eq(e1.text, "")
  assert_true(e2.text.contains("id: ab.2"))
  assert_true(e3.text.contains("id: ab.3"))
  assert_eq(log.at(), "ab.3")
  assert_true(log.has("ab.0"))
  assert_true(log.has("ab.3"))
  assert_false(log.has("ba.1"))
  let after1 = log.after("ab.1")
  assert_eq(after1.length(), 2)
  assert_eq(after1[0].n, 2.0)
  assert_eq(after1[1].n, 3.0)
  // Appending a 4th item evicts the oldest when most=3
  ignore(log.append("e", "{\"n\":4}", Null, 400.0))
  assert_false(log.has("ab.0"))
  assert_true(log.has("ab.1"))
  // Round-trip through kept() / EventLog::from()
  let restored = EventLog::from(log.kept(), 450.0, ms=10_000.0, most=3, bytes=4096)
  assert_eq(restored.at(), "ab.4")
  assert_eq(restored.after("ab.2").length(), 2)
  ignore(e2)
  ignore(e3)
  inspect(
    @readops.model_key("anthropic/claude-opus-5-5[1m]"),
    content="claude-opus-5-5[1m]",
  )
}

///|
test "compat parses client runtimes, filters runtime_view, and rewrites SSE frames" {
  let legacy = client_runtimes([])
  assert_true(legacy.contains("claude"))
  assert_false(legacy.contains("agy"))
  assert_false(takes_every(legacy))

  let all = client_runtimes([
    ("StillFail-Runtimes", "claude, codex, dsh, grok, cursor, devin, hermes, agy, pi"),
  ])
  assert_true(takes_every(all))

  let only_claude = client_runtimes([("stillfail-runtimes", "claude, BAD_NAME, 123")])
  assert_true(only_claude.contains("claude"))
  assert_false(only_claude.contains("BAD_NAME"))
  assert_false(only_claude.contains("123"))

  // runtime_view omits unsupported RuntimeKind and keeps supported ones
  assert_true(runtime_view(js("RuntimeKind"), Some(js("agy")), only_claude) is Omit)
  assert_true(runtime_view(js("RuntimeKind"), Some(js("claude")), only_claude) is Value(Some(_)))

  // CompatStream buffers partial SSE frames and filters unknown runtimes
  let stream = CompatStream::new(only_claude)
  let chunks1 = stream.push("id: r.1\nevent: chat\n")
  assert_eq(chunks1.length(), 0)
  let chunks2 = stream.push("data: {\"runtime\":\"claude\",\"key\":\"c1\"}\n\n")
  assert_eq(chunks2.length(), 1)
  assert_true(chunks2[0].contains("id: r.1"))
  assert_eq(stream.end(), None)

  // compat_frame preserves non-chat events unchanged
  let ping = compat_frame("event: ping\ndata: {}\n\n", only_claude)
  assert_eq(ping, "event: ping\ndata: {}\n\n")
}

///|
test "runtime_compatible passes through full cores and non-2xx responses" {
  let full_headers = [
    ("stillfail-runtimes", "claude,codex,dsh,grok,cursor,devin,hermes,agy,pi"),
  ]
  let ans : JsonAnswer = {
    status: 200,
    headers: [("content-type", "application/json"), ("content-length", "2")],
    body: "{}",
  }
  let same = runtime_compatible("/overview", full_headers, "", "zh", ans)
  assert_eq(same.status, 200)
  assert_eq(same.body, "{}")

  let err_ans : JsonAnswer = {
    status: 500,
    headers: [("content-type", "application/json")],
    body: "{\"error\":\"boom\"}",
  }
  let unchanged = runtime_compatible("/overview", [], "", "en", err_ans)
  assert_eq(unchanged.status, 500)
  assert_eq(unchanged.body, "{\"error\":\"boom\"}")
}

///|
test "CpuWindow computes busy share across tick samples" {
  assert_eq(cpu_share({ busy: 10.0, total: 100.0 }, { busy: 35.0, total: 150.0 }), Some(0.5))
  assert_eq(cpu_share({ busy: 10.0, total: 100.0 }, { busy: 10.0, total: 100.0 }), None)
  let win = CpuWindow::new()
  win.note(1000.0, Some({ busy: 100.0, total: 1000.0 }))
  win.note(2000.0, Some({ busy: 150.0, total: 1200.0 }))
  assert_true(win.latest() is Some(_))
  assert_eq(
    stringify(win.busy(2500.0, Some({ busy: 200.0, total: 1400.0 }))),
    "{\"busy\":0.25,\"seconds\":2}",
  )
}

///|
test "viewer visibility, seen_of, and asked_of query parsing" {
  let viewer = Viewer::of(
    jo([
      ("sub", js("u1")),
      ("email", js("a@x")),
      ("role", js("member")),
      ("workspace", js("w1")),
      ("home", Bool(true)),
    ]),
  )
  assert_true(sees_ws(viewer, Some("w1")))
  assert_false(sees_ws(viewer, Some("w2")))
  assert_true(sees(viewer, js("w1")))
  assert_false(sees(viewer, js("w2")))
  assert_eq(viewer_key(viewer, "zh"), "a@x\u{0}w1\u{0}zh")

  let store : SeenStore = {
    session_ws: k => if k == "s1" { Some(js("w1")) } else if k == "s2" { Some(js("w2")) } else { None },
    thread_sessions: id => if id == 1.0 { ["s1"] } else { ["s2"] },
    job_session: id => if id == "j1" { Some("s1") } else if id == "j2" { Some("s2") } else { None },
    session_there: k => k == "s1" || k == "s2",
    thread_there: id => id == 1.0 || id == 2.0,
    handed_to: _ => None,
  }
  assert_true(seen_of(store, viewer, Session("s1")))
  assert_false(seen_of(store, viewer, Session("s2")))
  assert_true(seen_of(store, viewer, Thread(jn(1.0))))
  assert_false(seen_of(store, viewer, Thread(jn(2.0))))
  assert_true(seen_of(store, viewer, Job("j1")))
  assert_false(seen_of(store, viewer, Job("j2")))

  let (asked, err) = asked_of(
    [("host", "1"), ("brief", "1"), ("running", "1"), ("since", "ab.1")],
    viewer,
    _ => false,
    Some(store),
  )
  assert_eq(err, None)
  assert_true(asked.host)
  assert_true(asked.brief)
  assert_true(asked.running)
  assert_eq(asked.since, Some("ab.1"))
}

///|
test "overview constructs payload and caches decisions/memory via OverviewKept" {
  let viewer = Viewer::of(
    jo([
      ("sub", js("u1")),
      ("email", js("owner@x")),
      ("role", js("owner")),
      ("workspace", js("w1")),
      ("home", Bool(true)),
    ]),
  )
  let kept = OverviewKept::new()
  let mem_calls = Ref(0)
  let deps : OverviewDeps = {
    config: () => jo([("connects", ja([])), ("claude", jo([]))]),
    session_counts: (_, _) => Some((3.0, Map([]))),
    wait_for_session_counts: None,
    hub_processes: () => [],
    session_ws: _ => None,
    list_processes: () => [jo([("pgid", jn(42.0)), ("state", js("running"))])],
    data_dir: "/tmp/sf-test",
    group_memory: (_, cb) => {
      mem_calls.val += 1
      cb(Map([]))
    },
    disk_room: (_, cb) => cb(jo([("freeBytes", jn(1024.0)), ("totalBytes", jn(4096.0))])),
    store_now: () => 1_000_000.0,
    binding: _ => jo([]),
    connect_kind: _ => None,
    accounts: None,
    updates: None,
    slack_identities: _ => jo([]),
    root_view: (_, cb) => cb(jo([])),
    homedir: "/Users/test",
    has_spotlight: false,
    permissions: None,
    cloud_state: () => None,
    membership: _ => None,
    reached: () => false,
    catalog: () => jo([]),
    decisions_version: () => jn(1.0),
    policy_checks: None,
    policy_view: (_, _, _, _, _) => jo([("items", ja([]))]),
    prepare_decision_sessions: cb => cb(),
    prepare_session_chat_names: None,
    session_there: _ => false,
    chat_readable: _ => false,
    chat_title: _ => "",
    rooted: p => p.has_prefix("/"),
    clean: p => p,
    built_at: Some(1_700_000_000_000.0),
  }
  let got : Array[Result[J, String]] = []
  overview(deps, kept, viewer, "en", r => got.push(r))
  assert_eq(got.length(), 1)
  match got[0] {
    Ok(v) => {
      assert_eq(v.get("counts").bind(c => c.get("sessions")).map(stringify), Some("3"))
      assert_eq(v.get("builtAt").map(stringify), Some("1700000000000"))
    }
    Err(e) => fail("overview failed: \{e}")
  }
  // Second call within memory_kept_ms reuses cached memory map
  overview(deps, kept, viewer, "en", r => got.push(r))
  assert_eq(got.length(), 2)
  assert_eq(mem_calls.val, 1)
}

///|
test "connect_shown emits startsOn and startsOnStations consistently for none, single, and multi-station allowlists" {
  let deps : OverviewDeps = {
    config: () => jo([]),
    session_counts: (_, _) => Some((0.0, Map([]))),
    wait_for_session_counts: None,
    hub_processes: () => [],
    session_ws: _ => None,
    list_processes: () => [],
    data_dir: "/tmp/test-data",
    group_memory: (_, cb) => cb(Map([])),
    disk_room: (_, cb) => cb(Null),
    store_now: () => 0.0,
    binding: _ => Null,
    connect_kind: _ => None,
    accounts: None,
    updates: None,
    slack_identities: _ => jo([]),
    root_view: (_, cb) => cb(jo([])),
    homedir: "/Users/test",
    has_spotlight: false,
    permissions: None,
    cloud_state: () => None,
    membership: _ => None,
    reached: () => false,
    catalog: () => jo([]),
    decisions_version: () => jn(1.0),
    policy_checks: None,
    policy_view: (_, _, _, _, _) => jo([("items", ja([]))]),
    prepare_decision_sessions: cb => cb(),
    prepare_session_chat_names: None,
    session_there: _ => false,
    chat_readable: _ => false,
    chat_title: _ => "",
    rooted: p => p.has_prefix("/"),
    clean: p => p,
    built_at: None,
  }
  let none_c = connect_shown(deps, jo([("id", js("c0")), ("bind", jo([("runtime", js("claude"))]))]), _ => 0.0)
  assert_eq(none_c.get("startsOn").map(stringify), Some("null"))
  assert_eq(none_c.get("startsOnStations").map(stringify), Some("null"))

  let one_c = connect_shown(deps, jo([("id", js("c1")), ("station", js("s1")), ("bind", jo([("runtime", js("claude"))]))]), _ => 0.0)
  assert_eq(one_c.get("startsOn").map(stringify), Some("\"s1\""))
  assert_eq(one_c.get("startsOnStations").map(stringify), Some("[\"s1\"]"))

  let multi_c = connect_shown(
    deps,
    jo([("id", js("c2")), ("station", js("s1")), ("stations", ja([js(" s1 "), js("s2"), js("s1"), js("")])), ("bind", jo([("runtime", js("claude"))]))]),
    _ => 0.0,
  )
  assert_eq(multi_c.get("startsOn").map(stringify), Some("\"s1\""))
  assert_eq(multi_c.get("startsOnStations").map(stringify), Some("[\"s1\",\"s2\"]"))
  assert_eq(multi_c.get("startsOnAuto").map(stringify), None)

  let auto_c = connect_shown(
    deps,
    jo([("id", js("c3")), ("autoStation", Bool(true)), ("station", js("s1")), ("bind", jo([("runtime", js("claude"))]))]),
    _ => 0.0,
  )
  assert_eq(auto_c.get("startsOnAuto").map(stringify), Some("true"))
  assert_eq(auto_c.get("startsOn").map(stringify), Some("null"))
  assert_eq(auto_c.get("startsOnStations").map(stringify), Some("null"))
}
