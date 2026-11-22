// What the program tells of a turn (frames.mbt `on_frame`, outcome.mbt): its outcome against what the TypeScript station
// said of the same words before it was moved here (station/src/agents/claude.ts `classifyResult`, `refused` and
// live.ts `chars`, node 24, 2026-11-16): each failure's reason, whether it was refused, and how much of it was kept.

///|
fn rep(s : String, n : Int) -> String {
  let out = StringBuilder()
  for _ in 0..<n {
    out.write_string(s)
  }
  out.to_string()
}

///|
/// (what Claude Code said, `classifyResult`'s reason, `refused`, the UTF-16 length of `chars(text, 1000)`), as node said.
let as_typescript_said : Array[(String, String, Bool, Int)] = [
    ("Claude AI usage limit reached", "rate_limit", false, 29),
    ("You've reached your Fable limit. Switch to another model, or manage usage credits at https://claude.ai/settings/usage?from=cc_cli_limit_message, to continue.", "rate_limit", false, 157),
    ("You've hit your Fable limit · resets Nov 20 at 9am (Asia/Tokyo). Switch to another model to continue.", "rate_limit", false, 101),
    ("You've hit your weekly limit · resets Oct 8", "rate_limit", false, 43),
    ("You've hit your 5-hour limit · resets 7:50am (UTC)", "rate_limit", false, 50),
    ("You've hit your 5 hour limit", "rate_limit", false, 28),
    ("You've hit your 3-hour limit", "rate_limit", false, 28),
    ("You've hit your daily limit", "rate_limit", false, 27),
    ("You've hit your session limit · resets 3:40am", "rate_limit", false, 45),
    ("You've hit your limit · resets 5pm", "rate_limit", false, 34),
    ("5-hour limit configuration is invalid", "model", false, 37),
    ("session limit configuration is invalid", "model", false, 38),
    ("hit your limitless plan", "model", false, 23),
    ("you hit your x limits", "model", false, 21),
    ("Ahit your weekly limit", "rate_limit", false, 22),
    ("_hit your 5-hour limit", "model", false, 22),
    ("hit your 5-hour limit_", "model", false, 22),
    ("hit your 5-hour limitation", "model", false, 26),
    ("reached your Claude-3.5 Sonnet limit.", "rate_limit", false, 37),
    ("reached your  limit", "model", false, 19),
    ("reached your · limit", "model", false, 20),
    ("reached your a limit2", "model", false, 21),
    ("API Error: 403 {\"error\":{\"type\":\"forbidden\",\"message\":\"Request not allowed\"}}", "refused", true, 77),
    ("API Error: 403 OAuth token does not meet scope requirement", "auth", false, 58),
    ("API Error: 401 invalid x-api-key", "auth", false, 32),
    ("API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}", "overloaded", false, 90),
    ("API Error: Connection error. (ECONNRESET)", "network", false, 41),
    ("Prompt is too long", "context", false, 18),
    ("API Error: 500 Internal server error", "model", false, 36),
    ("No conversation found with session ID: 11111111-1111-1111-1111-111111111111", "model", false, 75),
    ("error_during_execution", "model", false, 22),
    ("prompt is too long", "context", false, 18),
    ("FORBIDDEN by policy", "refused", true, 19),
    ("forbiddenfruit", "model", false, 14),
    ("access_forbidden", "model", false, 16),
    ("it is Forbidden.", "refused", true, 16),
    ("REQUEST NOT ALLOWED", "refused", true, 19),
    ("status 4010", "model", false, 11),
    ("状态401", "model", false, 5),
    ("状态 401 未授权", "auth", false, 10),
    ("e401", "model", false, 4),
    ("429 Too Many Requests", "rate_limit", false, 21),
    ("rate-limit hit", "rate_limit", false, 14),
    ("RateLimit exceeded", "rate_limit", false, 18),
    ("Usage Limit", "rate_limit", false, 11),
    ("server at capacity", "overloaded", false, 18),
    ("the model is OVERLOADED", "overloaded", false, 23),
    ("Request timed out", "network", false, 17),
    ("TIMEOUT waiting", "network", false, 15),
    ("dns error: no such host", "network", false, 23),
    ("TLS handshake failed", "network", false, 20),
    ("tls  handshake", "model", false, 14),
    ("socket hang up", "network", false, 14),
    ("getaddrinfo EAI_AGAIN api.anthropic.com", "network", false, 39),
    ("write EPIPE", "network", false, 11),
    ("connection closed before message completed", "network", false, 42),
    ("Connection Failed", "network", false, 17),
    ("stream disconnected before completion", "network", false, 37),
    ("error sending request for url", "network", false, 29),
    ("fetch failed", "network", false, 12),
    ("network error", "network", false, 13),
    ("context window exceeded", "context", false, 23),
    ("context_length_exceeded", "context", false, 23),
    ("maximum context length", "context", false, 22),
    ("too many toKens", "context", false, 15),
    ("too many toKens", "context", false, 15),
    ("input is too long for requested model", "context", false, 37),
    ("context overflow", "context", false, 16),
    ("Authentication failed", "auth", false, 21),
    ("Invalid API key · Please run /login", "auth", false, 35),
    ("authenticat", "auth", false, 11),
    ("İnvalid", "model", false, 7),
    ("Kelvin timeout", "network", false, 14),
    ("timeout", "network", false, 7),
    ("ECONNRESET", "network", false, 10),
    ("ETIMEDOUT", "network", false, 9),
    ("ENOTFOUND", "network", false, 9),
    ("ECONNREFUSED", "network", false, 12),
    ("", "model", false, 0),
    (rep("x", 1200), "model", false, 1000),
    (rep("😀", 1100), "model", false, 2000),
    (rep("a😀", 700), "model", false, 1500),
]

///|
test "a failure's reason, as the TypeScript station told it" {
  for c in as_typescript_said {
    assert_eq(@claude.classify_result(c.0), c.1, msg=c.0)
    assert_eq(@claude.refused(c.0), c.2, msg=c.0)
    assert_eq(@claude.chars(c.0, 1000).length(), c.3, msg=c.0)
  }
}

///|
/// The turn's outcomes `frames` end, as `on_frame` tells them.
fn outcomes(frames : Array[String], turn? : @claude.Turn = @claude.Turn::new()) -> Array[String] raise {
  let out = []
  for f in frames {
    @claude.on_frame(
      @jsjson.parse(f),
      turn,
      e => if e.get("type") is Some(Str(t)) && t == "turnEnded" {
        out.push(@jsjson.stringify(e.get("outcome").unwrap()))
      },
      () => (),
      () => 0.0,
      _ => (),
    )
  }
  out
}

///|
test "a failed result is told apart by what claude said; is_error decides, not subtype" {
  for text in ["You've hit your 5-hour limit · resets 7:50am (UTC)", "You've hit your 5 hour limit", "You've hit your 3-hour limit"] {
    let said = @jsjson.stringify(Str(text))
    assert_eq(outcomes(["{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"result\":\{said}}"]), [
      "{\"kind\":\"failed\",\"reason\":\"rate_limit\",\"message\":\{said}}",
    ])
    assert_eq(outcomes(["{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\{said}}"]), ["{\"kind\":\"completed\"}"])
  }
  assert_eq(outcomes(["{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"result\":\"API Error: 401 invalid x-api-key\"}"]), [
    "{\"kind\":\"failed\",\"reason\":\"auth\",\"message\":\"API Error: 401 invalid x-api-key\"}",
  ])
  // What is kept of it: 1000 characters, a pair of surrogates one.
  let long = @jsjson.stringify(Str(rep("😀", 1001)))
  assert_eq(outcomes(["{\"type\":\"result\",\"is_error\":true,\"result\":\{long}}"]), [
    "{\"kind\":\"failed\",\"reason\":\"model\",\"message\":\{@jsjson.stringify(Str(rep("😀", 1000)))}}",
  ])
}

///|
test "a turn that failed with no result says claude's errors, not just error_during_execution" {
  assert_eq(
    outcomes([
      "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"num_turns\":0,\"errors\":[\"No conversation found with session ID: 1\"]}",
    ]),
    ["{\"kind\":\"failed\",\"reason\":\"model\",\"message\":\"No conversation found with session ID: 1\"}"],
  )
  assert_eq(outcomes(["{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"errors\":[]}"]), [
    "{\"kind\":\"failed\",\"reason\":\"model\",\"message\":\"error_during_execution\"}",
  ])
}

///|
test "a 401 or 403 as it retries fails the turn as the account's, or as refused where it says so" {
  let retry = (status : Int, error : String) => "{\"type\":\"system\",\"subtype\":\"api_retry\",\"error_status\":\{status},\"attempt\":1,\"error\":\"\{error}\"}"
  let end = "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"\"}"
  assert_eq(outcomes([retry(401, "authentication_failed"), end]), [
    "{\"kind\":\"failed\",\"reason\":\"auth\",\"message\":\"401 authentication_failed\"}",
  ])
  assert_eq(outcomes([retry(403, "Request not allowed"), end]), [
    "{\"kind\":\"failed\",\"reason\":\"refused\",\"message\":\"403 Request not allowed\"}",
  ])
}

///|
test "a /compact that compacted nothing ends failed, saying why; one that did, completed" {
  let turn = @claude.Turn::new()
  turn.busy = true
  turn.compacting = Some(true)
  assert_eq(
    outcomes(turn~, [
      "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"compacting\"}",
      "{\"type\":\"system\",\"subtype\":\"status\",\"status\":null,\"compact_result\":\"failed\",\"compact_error\":\"Not enough messages to compact.\"}",
      "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false}",
    ]),
    ["{\"kind\":\"failed\",\"reason\":\"other\",\"message\":\"Not enough messages to compact.\"}"],
  )
  assert_eq(turn.compacting, Some(false))
  // A failed compaction in a turn of its own (automatic) is not this turn's failure.
  turn.busy = true
  assert_eq(
    outcomes(turn~, [
      "{\"type\":\"system\",\"subtype\":\"status\",\"status\":null,\"compact_result\":\"failed\",\"compact_error\":\"x\"}",
      "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false}",
    ]),
    ["{\"kind\":\"completed\"}"],
  )
}

///|
test "Claude Code's compact_boundary, automatic or by hand, says it compacted" {
  let told = []
  let turn = @claude.Turn::new()
  turn.busy = true
  for trigger in ["auto", "manual"] {
    @claude.on_frame(
      @jsjson.parse("{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"compact_metadata\":{\"trigger\":\"\{trigger}\",\"pre_tokens\":180000}}"),
      turn,
      e => told.push(@jsjson.stringify(e)),
      () => (),
      () => 0.0,
      _ => (),
    )
  }
  assert_eq(told, ["{\"type\":\"compacted\"}", "{\"type\":\"compacted\"}"])
}

///|
test "an API key's credits run out: a limit, so another account takes the session on" {
  for text in [
    "Credit balance is too low",
    "API Error: 400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits.\"}}",
  ] {
    assert_eq(@claude.classify_result(text), "rate_limit", msg=text)
    assert_eq(@claude.failure_of(text), "rate_limit", msg=text)
  }
}
