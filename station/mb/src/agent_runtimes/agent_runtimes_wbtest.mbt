// Native MoonBit unit tests for agent_runtimes pure logic.

///|
test "numbers and times as JavaScript says them" {
  inspect(to_fixed(1794883188.9025, 6), content="1794883188.902500")
  inspect(to_fixed(0.5, 0), content="1")
  inspect(to_fixed(-1.005, 2), content="-1.00")
  inspect(to_fixed(1.0e21, 2), content="1e+21")
  inspect(iso_date(0.0), content="1970-01-01T00:00:00.000Z")
  inspect(iso_date(1794883188902.9), content="2026-11-17T02:39:48.902Z")
  inspect(iso_date(-1.0), content="1969-12-31T23:59:59.999Z")
  inspect(iso_date(8.64e15), content="+275760-09-13T00:00:00.000Z")
  inspect(utf8_length("a中😀"), content="8")
  inspect(js_less("B", "a"), content="true")
  inspect(js_less("ab", "a"), content="false")
}

///|
test "a session's steps: what is written, and a turn not started twice" {
  let s = Bridged::new("dsh", "s-1", idle_turn("dsh"), Null, "r")
  s.own.uuids.push("u1")
  inspect(s.prompt("hi"), content="None")
  inspect(s.prompt("again"), content="Some(a turn is already running)")
  inspect(
    stringify(Arr(s.own.trace)),
    content=(
      #|[{"tell":"begin"},{"write":"{\"id\":\"prompt:u1\",\"op\":\"prompt\",\"text\":\"hi\"}"}]
    ),
  )
}

///|
test "model variant parsing for agy and devin" {
  assert_eq(agy_base_model("gemini-4-neon-medium"), ("gemini-4-neon", Some("medium")))
  assert_eq(agy_base_model("gemini-4-neon"), ("gemini-4-neon", None))
  assert_eq(devin_fusion_base("fusion-opus-high-sidekick-sonnet"), ("fusion-opus-sidekick-sonnet", Some("high")))
  assert_eq(devin_fusion_base("swe-1.5"), ("swe-1.5", None))
  assert_eq(devin_variant("fusion-opus-sidekick-sonnet", Some("high")), "fusion-opus-high-sidekick-sonnet")
  assert_eq(devin_variant("swe-1.5", None), "swe-1.5")
  let args = devin_args("swe-1.5", Some("high"), Some("sess-1"))
  assert_true(args.length() > 0)
}

///|
test "provider endpoints, access kinds, and billing" {
  assert_eq(clean_endpoint("https://api.example.com/v1/"), Some("https://api.example.com/v1"))
  assert_eq(clean_endpoint("  "), None)
  assert_eq(clean_endpoint("ftp://bad.example"), None)
  assert_eq(anthropic_root("https://api.anthropic.com/v1"), "https://api.anthropic.com")
  assert_eq(anthropic_root("https://proxy.example/anthropic/v1"), "https://proxy.example/anthropic")
  assert_eq(access_kind(obj([("access", obj([("kind", js("api-provider"))]))])), "api-provider")
  assert_eq(access_kind(obj([])), "env")
  assert_true(access_kinds("claude").contains("subscription"))
  assert_true(billed_per_use(obj([("access", obj([("kind", js("anthropic-api"))]))])))
  assert_true(!billed_per_use(obj([("access", obj([("kind", js("subscription"))]))])))
  assert_true(fast_needs_credits(obj([("runtime", js("claude")), ("access", obj([("kind", js("subscription"))]))])))
  assert_true(!fast_needs_credits(obj([("runtime", js("codex")), ("access", obj([("kind", js("subscription"))]))])))
}

///|
test "env cleaning, route expansion, and home path resolution" {
  let env = Fields::of([
    ("HOME", js("/Users/alice")),
    ("ANTHROPIC_API_KEY", js("secret")),
    ("KEEP", js("1")),
  ])
  let cleaned = clean_env(env, ["ANTHROPIC_API_KEY"])
  assert_true(cleaned.get("ANTHROPIC_API_KEY") is None)
  assert_true(cleaned.get("KEEP") == Some(js("1")))
  let expanded = expand_route(Fields::of([("BASE", js("https://a.b"))]), "tok-1")
  assert_true(expanded.get("BASE") is Some(_))
  assert_eq(claude_credentials_file(env), "/Users/alice/.claude/.credentials.json")
  assert_eq(codex_auth_file(env), "/Users/alice/.codex/auth.json")
  assert_eq(configured_home(None, "/data", "p1"), Ok("/data"))
}

///|
test "runtime key parsing, dsh route/open, sandboxes, and notices" {
  assert_eq(cursor_key_of(Some("{\"apiKey\":\"key_123\"}")), Some("key_123"))
  assert_eq(cursor_key_of(Some("   ")), None)
  assert_eq(devin_key_of(Some("windsurf_api_key = \"apk_user_1\"\n")), Some("apk_user_1"))
  assert_eq(devin_key_of(None), None)
  assert_eq(dsh_opened(obj([("session", js("s-9"))]), "no tools"), Ok("s-9"))
  assert_eq(dsh_opened(obj([("error", js("old")), ("lacks", js("tools"))]), "no tools"), Err("no tools"))
  assert_true(dsh_route(obj([("access", obj([("kind", js("anthropic-api"))]))])) is Some(_))
  assert_true(dsh_route(obj([("access", obj([("kind", js("env"))]))])) is None)
  assert_eq(check_sandboxes(None), None)
  assert_eq(error_text(obj([("message", js("failed"))])), "failed")
  assert_true(ago_words(120000.0).length() > 0)
  assert_true(afresh("ctx", []).length() > 0)
  assert_true(cleared("ok", []).length() > 0)
  assert_true(continued_here("s-1").contains("s-1"))
}
