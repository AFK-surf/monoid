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
