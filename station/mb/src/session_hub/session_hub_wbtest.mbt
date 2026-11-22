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

///|
test "drive_loop fires timers on deadline and wakes early for earlier timers" {
  let rt = @effect.Runtime::new(start=1_000L)
  let stopped : @effect.Deferred[Unit] = @effect.Deferred::new()
  let timers : Array[Timer] = []
  let waiters : Array[@effect.Deferred[Unit]] = []
  let work : Array[async () -> Unit] = []
  let seq : Ref[Int] = { val: 0 }
  let fired : Array[(String, Int64)] = []
  let after = (ms : Double, run : () -> Unit) => {
    seq.val += 1
    let due = rt.now().to_double() + (if ms > 0.0 { ms } else { 0.0 })
    timers.push({ id: seq.val, due, run })
    wake_waiters_list(waiters)
  }
  let driver = rt.fork(name="drive", async fn() {
    drive_loop(rt, stopped, () => rt.now().to_double(), timers, waiters, work, f => {
      ignore(rt.fork_quiet(name="later", f))
    })
  })
  ignore(rt.run_ready())
  assert_eq(next_due_in(timers), None)
  // Schedule a 10s timer at t=1000 (due at 11000).
  after(10_000.0, () => fired.push(("10s", rt.now())))
  rt.advance(1_000)
  assert_eq(fired.length(), 0)
  // Insert an earlier 2s timer at t=2000 (due at 4000) — must wake and preempt the 10s sleep.
  after(2_000.0, () => fired.push(("2s", rt.now())))
  rt.advance(1_999)
  assert_eq(fired.length(), 0)
  rt.advance(1)
  assert_eq(fired, [("2s", 4_000L)])
  rt.advance(6_999)
  assert_eq(fired.length(), 1)
  rt.advance(1)
  assert_eq(fired, [("2s", 4_000L), ("10s", 11_000L)])
  assert_eq(next_due_in(timers), None)
  // Stop exits cleanly with no leaked waiters or fibers.
  ignore(stopped.succeed(()))
  ignore(rt.run_ready())
  assert_true(driver.is_done())
  assert_eq(waiters.length(), 0)
  assert_true(rt.idle())
}

///|
test "drive_loop wakes immediately for deferred later work and drains chained work" {
  let rt = @effect.Runtime::new(start=0L)
  let stopped : @effect.Deferred[Unit] = @effect.Deferred::new()
  let timers : Array[Timer] = []
  let waiters : Array[@effect.Deferred[Unit]] = []
  let work : Array[async () -> Unit] = []
  let ran : Array[String] = []
  let driver = rt.fork(name="drive", async fn() {
    drive_loop(rt, stopped, () => rt.now().to_double(), timers, waiters, work, f => {
      ignore(rt.fork_quiet(name="later", f))
    })
  })
  ignore(rt.run_ready())
  // No timers scheduled; pushing deferred work must wake drive_loop immediately.
  work.push(async fn() {
    @effect.pause()
    ran.push("first")
    work.push(async fn() {
      @effect.pause()
      ran.push("chained")
    })
    wake_waiters_list(waiters)
  })
  wake_waiters_list(waiters)
  ignore(rt.run_ready())
  assert_eq(ran, ["first", "chained"])
  assert_eq(work.length(), 0)
  ignore(stopped.succeed(()))
  ignore(rt.run_ready())
  assert_true(driver.is_done())
  assert_eq(waiters.length(), 0)
  assert_true(rt.idle())
}

///|
test "drive_loop cleans up timer_waiters when stopped mid-sleep and handles >60s deadlines" {
  let rt = @effect.Runtime::new(start=0L)
  let stopped : @effect.Deferred[Unit] = @effect.Deferred::new()
  let timers : Array[Timer] = []
  let waiters : Array[@effect.Deferred[Unit]] = []
  let work : Array[async () -> Unit] = []
  let fired : Ref[Int64] = { val: -1L }
  timers.push({ id: 1, due: 150_000.0, run: () => fired.val = rt.now() })
  let driver = rt.fork(name="drive", async fn() {
    drive_loop(rt, stopped, () => rt.now().to_double(), timers, waiters, work, f => {
      ignore(rt.fork_quiet(name="later", f))
    })
  })
  // Advance in chunks across the 60s clamp boundary.
  rt.advance(60_000)
  assert_eq(fired.val, -1L)
  assert_eq(waiters.length(), 1)
  rt.advance(89_999)
  assert_eq(fired.val, -1L)
  rt.advance(1)
  assert_eq(fired.val, 150_000L)
  // Schedule another future timer and stop mid-sleep: must exit and remove its waiter.
  timers.push({ id: 2, due: 200_000.0, run: () => () })
  wake_waiters_list(waiters)
  ignore(rt.run_ready())
  assert_eq(waiters.length(), 1)
  ignore(stopped.succeed(()))
  ignore(rt.run_ready())
  assert_true(driver.is_done())
  assert_eq(waiters.length(), 0)
  assert_true(rt.idle())
}

///|
test "drive_loop flushes gathered transcript lengths and resets lengths_due for subsequent writes" {
  let rt = @effect.Runtime::new(start=0L)
  let stopped : @effect.Deferred[Unit] = @effect.Deferred::new()
  let timers : Array[Timer] = []
  let waiters : Array[@effect.Deferred[Unit]] = []
  let work : Array[async () -> Unit] = []
  let seq : Ref[Int] = { val: 0 }
  let written : Array[(String, Int, Int64)] = []
  let lengths : Map[String, Int] = Map([])
  let lengths_due : Ref[Bool] = { val: false }
  let length_written : Set[String] = Set([])
  let flush = () => {
    lengths_due.val = false
    for k, v in lengths {
      written.push((k, v, rt.now()))
    }
    lengths.clear()
  }
  let note_length = (key : String, n : Int) => {
    lengths[key] = n
    if !length_written.contains(key) {
      length_written.add(key)
      written.push((key, n, rt.now()))
      lengths.remove(key)
      return
    }
    if lengths_due.val {
      return
    }
    lengths_due.val = true
    seq.val += 1
    timers.push({ id: seq.val, due: rt.now().to_double() + lengths_gather_ms, run: flush })
    wake_waiters_list(waiters)
  }
  let driver = rt.fork(name="drive", async fn() {
    drive_loop(rt, stopped, () => rt.now().to_double(), timers, waiters, work, f => {
      ignore(rt.fork_quiet(name="later", f))
    })
  })
  ignore(rt.run_ready())
  // First write happens immediately.
  note_length("chat:c-1", 10)
  assert_eq(written, [("chat:c-1", 10, 0L)])
  // Second and third writes within lengths_gather_ms are gathered.
  note_length("chat:c-1", 20)
  note_length("chat:c-1", 30)
  assert_true(lengths_due.val)
  rt.advance(4_999)
  assert_eq(written.length(), 1)
  rt.advance(1)
  assert_eq(written, [("chat:c-1", 10, 0L), ("chat:c-1", 30, 5_000L)])
  assert_true(!lengths_due.val)
  // Subsequent update after reset schedules and flushes again.
  note_length("chat:c-1", 40)
  assert_true(lengths_due.val)
  rt.advance(5_000)
  assert_eq(written, [("chat:c-1", 10, 0L), ("chat:c-1", 30, 5_000L), ("chat:c-1", 40, 10_000L)])
  assert_true(!lengths_due.val)
  ignore(stopped.succeed(()))
  ignore(rt.run_ready())
  assert_true(driver.is_done())
  assert_eq(waiters.length(), 0)
}
