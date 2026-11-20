// Native MoonBit unit tests for session_hub pure logic.

///|
test "iso as toISOString writes it" {
  assert_eq(iso(0.0), "1970-01-01T00:00:00.000Z")
  assert_eq(iso(1_800_000_000_123.0), "2027-01-15T08:00:00.123Z")
  assert_eq(iso(-1.0), "1969-12-31T23:59:59.999Z")
}

///|
test "numbers as String() writes them" {
  assert_eq(js_number_text(1.0), "1")
  assert_eq(js_number_text(0.5), "0.5")
  assert_eq(js_number_text(-0.0), "0")
  assert_eq(js_number_text(@double.not_a_number), "NaN")
  assert_eq(js_string(Json::null()), "null")
  assert_eq(js_string([1, "a"]), "[1,\"a\"]")
}

///|
test "a ts given only goes up" {
  let a = next_ts_at(1_800_000_000_000.0)
  let b = next_ts_at(1_800_000_000_000.0)
  assert_true(a < b)
  assert_eq(next_ts_at(1_900_000_000_000.5).length(), 17)
}

///|
test "bytes as base64url, unpadded" {
  assert_eq(base64url([]), "")
  assert_eq(base64url([0xfb, 0xff]), "-_8")
  assert_eq(base64url([104, 105, 33]), "aGkh")
}

///|
test "a thread's commands and a reason given" {
  assert_eq(thread_command(" <@U1> -STOP "), Some("stop"))
  assert_eq(thread_command("<@U-1> -stop"), None)
  assert_true(is_reason("已合进 main 82f108a5"))
  assert_true(!is_reason("Done!"))
  assert_eq(model_name("anthropic/claude-opus-5-5"), "Opus 5.5")
}

///|
test "a stable sort keeps ties in order" {
  let xs = [(1, "a"), (0, "b"), (1, "c"), (0, "d")]
  assert_eq(stable_sort(xs, (a, b) => a.0 - b.0).map(x => x.1), ["b", "d", "a", "c"])
}

///|
test "workspace keys, agent names, and notice/method predicates" {
  assert_eq(chat_workspace("/data", "chat:c-abc"), "/data/sessions/chat/c-abc/workspace")
  assert_eq(coming_ws("w1"), "coming:w1")
  assert_eq(handed_ws("w1"), "handed:w1")
  assert_eq(agent_name(Some("Bot"), "claude"), "agent: Bot")
  assert_eq(agent_name(None, "codex"), "agent: codex")
  assert_eq(first_line("first\nsecond\nthird"), "first")
  assert_eq(lang_of(Some("zh-CN")), "zh")
  assert_eq(lang_of(Some("en-US")), "en")
  assert_true(is_slack_method("chat.postMessage"))
  assert_true(!is_slack_method("chat..bad"))
  assert_true(!is_slack_method(""))
  assert_eq(encode_uri_component("a/b c"), "a%2Fb%20c")
}

///|
test "model base parsing, codex version check, and effort lists" {
  assert_eq(agy_base_model("gemini-4-neon-high"), ("gemini-4-neon", Some("high")))
  assert_eq(agy_base_model("gemini-4-neon"), ("gemini-4-neon", None))
  assert_eq(devin_fusion_base("fusion-opus-high-sidekick-sonnet"), "fusion-opus-sidekick-sonnet")
  assert_true(codex_too_old("This model requires a newer version of Codex. Please upgrade to the latest app or CLI and try again."))
  assert_true(!codex_too_old("network timeout"))
  let common = common_efforts([["low", "medium", "high"], ["medium", "high", "max"]], "claude")
  assert_eq(common, ["medium", "high"])
  assert_true(fallback_efforts("codex").contains("medium"))
  assert_eq(chosen_speed({ "speed": "ultrafast" }), Some("ultrafast"))
  assert_eq(chosen_speed({ "fast": true }), Some("fast"))
  assert_eq(chosen_speed({}), None)
}

///|
test "access kind, billing, and allowed_in workspace filters" {
  assert_eq(access_kind({ "access": { "kind": "api-provider" } }), "api-provider")
  assert_eq(access_kind({}), "env")
  assert_true(billed_per_use({ "access": { "kind": "anthropic-api" } }))
  assert_true(!billed_per_use({ "access": { "kind": "subscription" } }))
  assert_true(allowed_in({}, Some("w1"), Some("w1")))
  assert_true(allowed_in({ "share": { "borrowed": true, "workspaces": ["w1", "w2"] } }, Some("w2"), Some("w1")))
  assert_true(!allowed_in({ "share": { "borrowed": true, "workspaces": ["w1"] } }, Some("w2"), Some("w1")))
  assert_true(enabled({}))
  assert_true(!enabled({ "enabled": false }))
}

///|
test "card_arg validation for options and text cards" {
  let opts_card : Json = {
    "type": "options",
    "assignee": "alice@example.com",
    "options": [{ "label": "Yes", "recommended": true }, { "label": "No" }],
  }
  let parsed = card_arg(Some(opts_card), None)
  assert_true(parsed is Some(_))
  let text_card : Json = {
    "type": "text",
    "assignee": "alice@example.com",
    "placeholder": "sk_...",
  }
  assert_true(card_arg(Some(text_card), None) is Some(_))
  assert_eq(card_arg(None, None), None)
  let bad = try {
    ignore(card_arg(Some({ "type": "options", "options": [] }), None))
    false
  } catch {
    _ => true
  }
  assert_true(bad)
}

///|
test "cold_afresh and cold_worth thresholds" {
  assert_true(!cold_afresh(None, false, None, None))
  assert_true(!cold_worth(100.0, None, None, None, false))
  assert_eq(about_ts(Map([("about", Json::string("1700000000.123456"))])), Some("1700000000.123456"))
  assert_eq(about_ts(Map([])), None)
  assert_true(js_number(Json::number(42.0)) == Some(42.0))
  assert_true(js_number(Json::string(" 3.5 ")) == Some(3.5))
  assert_eq(undefined(), { "$undefined": true })
}
