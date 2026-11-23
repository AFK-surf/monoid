// Tests for agy session/load ghost history replay guard and ⚠ Verification Required auth classification.

///|
fn j(s : String) -> @jsjson.JValue raise {
  @jsjson.parse(s) catch {
    _ => fail("bad json: \{s}")
  }
}

///|
fn types_of(events : Array[@jsjson.JValue]) -> Array[String] {
  events.map(e => match e.get("type") {
    Some(Str(t)) => t
    _ => ""
  })
}

///|
test "agy session/load ghost replay discards staged kept lines and emits loadReplay once" {
  let mut t = 1000.0
  let now = () => t
  let s = @acp.Session::new("agy", kept=true)
  s.session = "conv-1"
  s.opened(resumed=true)
  let p1 = s.prompted("prompt:p1", "real question", now~)
  // User line is written immediately on initial prompt.
  assert_true(p1.iter().any(e => e.get("type") == Some(Str("kept")) && e.get("line").bind(l => l.get("type")) == Some(Str("user"))))

  // Ghost history arrives within < 1s: kept lines are staged, not emitted.
  t = 1200.0
  let u1 = s.line(
    j("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"conv-1\",\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"g1\",\"title\":\"view_file\",\"status\":\"in_progress\",\"rawInput\":{\"path\":\"/old\"}}}}"),
    now,
  )
  let u2 = s.line(
    j("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"conv-1\",\"update\":{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"g1\",\"status\":\"completed\",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":\"old output\"}}]}}}"),
    now,
  )
  let u3 = s.line(
    j("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"conv-1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"old text\"}}}}"),
    now,
  )
  assert_false(u1.events.iter().any(e => e.get("type") == Some(Str("kept"))))
  assert_false(u2.events.iter().any(e => e.get("type") == Some(Str("kept"))))
  assert_false(u3.events.iter().any(e => e.get("type") == Some(Str("kept"))))

  // Ghost end_turn without usage triggers loadReplay, no turnEnded, no kept end, turn stays busy.
  t = 1400.0
  let end1 = s.line(j("{\"jsonrpc\":\"2.0\",\"id\":\"prompt:p1\",\"result\":{\"stopReason\":\"end_turn\"}}"), now)
  let end1_types = types_of(end1.events)
  assert_true(end1_types.contains("loadReplay"))
  assert_false(end1_types.contains("turnEnded"))
  assert_false(end1_types.contains("answered"))
  assert_false(end1_types.contains("kept"))
  assert_true(s.turn.busy)

  // Driver resends with new prompt id: no duplicate user line.
  let r = s.resent("prompt:p2")
  assert_false(r.iter().any(e => e.get("type") == Some(Str("kept"))))

  // Real answer arrives with usage -> normal transcript + turnEnded(completed).
  t = 2000.0
  ignore(
    s.line(
      j("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"conv-1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"fresh answer\"}}}}"),
      now,
    ),
  )
  let end2 = s.line(
    j("{\"jsonrpc\":\"2.0\",\"id\":\"prompt:p2\",\"result\":{\"stopReason\":\"end_turn\",\"usage\":{\"inputTokens\":100,\"outputTokens\":20}}}"),
    now,
  )
  let end2_types = types_of(end2.events)
  assert_false(end2_types.contains("loadReplay"))
  assert_true(end2_types.contains("turnEnded"))
  assert_true(end2.events.iter().any(e => e.get("type") == Some(Str("kept")) && e.get("line").bind(l => l.get("text")) == Some(Str("fresh answer"))))
  assert_false(s.turn.busy)
}

///|
test "agy session/load fast real turn with usage flushes staged kept and does not resend" {
  let mut t = 1000.0
  let now = () => t
  let s = @acp.Session::new("agy", kept=true)
  s.session = "conv-2"
  s.opened(resumed=true)
  ignore(s.prompted("prompt:p1", "quick ask", now~))
  t = 1100.0
  ignore(
    s.line(
      j("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"conv-2\",\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t1\",\"title\":\"view_file\",\"status\":\"in_progress\",\"rawInput\":{}}}}"),
      now,
    ),
  )
  let u = s.line(
    j("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"conv-2\",\"update\":{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t1\",\"status\":\"completed\",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":\"real tool\"}}]}}}"),
    now,
  )
  // Still staged before end_turn.
  assert_false(u.events.iter().any(e => e.get("type") == Some(Str("kept"))))
  t = 1200.0
  let end = s.line(
    j("{\"jsonrpc\":\"2.0\",\"id\":\"prompt:p1\",\"result\":{\"stopReason\":\"end_turn\",\"usage\":{\"inputTokens\":50,\"outputTokens\":10}}}"),
    now,
  )
  let types = types_of(end.events)
  assert_false(types.contains("loadReplay"))
  assert_true(types.contains("turnEnded"))
  assert_true(end.events.iter().any(e => e.get("type") == Some(Str("kept")) && e.get("line").bind(l => l.get("result")) == Some(Str("real tool"))))
}

///|
test "agy session/load flushes staged kept after 5s or on usage_update" {
  let mut t = 1000.0
  let now = () => t
  let s = @acp.Session::new("agy", kept=true)
  s.session = "conv-3"
  s.opened(resumed=true)
  ignore(s.prompted("prompt:p1", "long ask", now~))
  t = 1200.0
  ignore(
    s.line(
      j("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"conv-3\",\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t1\",\"title\":\"shell\",\"status\":\"in_progress\",\"rawInput\":{}}}}"),
      now,
    ),
  )
  let staged = s.line(
    j("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"conv-3\",\"update\":{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t1\",\"status\":\"completed\",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":\"staged tool\"}}]}}}"),
    now,
  )
  assert_false(staged.events.iter().any(e => e.get("type") == Some(Str("kept"))))

  // Once >= 5000ms elapses, the next update immediately flushes staged lines in real time.
  t = 6000.0
  let flushed = s.line(
    j("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"conv-3\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"still working\"}}}}"),
    now,
  )
  assert_true(flushed.events.iter().any(e => e.get("type") == Some(Str("kept")) && e.get("line").bind(l => l.get("result")) == Some(Str("staged tool"))))

  // usage_update also immediately flushes staged lines even under 5s.
  let s2 = @acp.Session::new("agy", kept=true)
  s2.session = "conv-3b"
  s2.opened(resumed=true)
  t = 1000.0
  ignore(s2.prompted("prompt:p1", "ask", now~))
  t = 1100.0
  ignore(
    s2.line(
      j("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"conv-3b\",\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t2\",\"title\":\"shell\",\"status\":\"in_progress\",\"rawInput\":{}}}}"),
      now,
    ),
  )
  ignore(
    s2.line(
      j("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"conv-3b\",\"update\":{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t2\",\"status\":\"completed\",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":\"tool2\"}}]}}}"),
      now,
    ),
  )
  let on_usage = s2.line(
    j("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"conv-3b\",\"update\":{\"sessionUpdate\":\"usage_update\",\"used\":500,\"size\":1000}}}"),
    now,
  )
  assert_true(on_usage.events.iter().any(e => e.get("type") == Some(Str("kept")) && e.get("line").bind(l => l.get("result")) == Some(Str("tool2"))))
}

///|
test "agy session/load resends at most once and session/new never guards" {
  let mut t = 1000.0
  let now = () => t
  let s = @acp.Session::new("agy", kept=true)
  s.session = "conv-4"
  s.opened(resumed=true)
  ignore(s.prompted("prompt:p1", "ask", now~))
  let end1 = s.line(j("{\"jsonrpc\":\"2.0\",\"id\":\"prompt:p1\",\"result\":{\"stopReason\":\"end_turn\"}}"), now)
  assert_true(types_of(end1.events).contains("loadReplay"))
  ignore(s.resent("prompt:p2"))
  // Second empty end_turn without usage must NOT emit loadReplay again.
  let end2 = s.line(j("{\"jsonrpc\":\"2.0\",\"id\":\"prompt:p2\",\"result\":{\"stopReason\":\"end_turn\"}}"), now)
  let types2 = types_of(end2.events)
  assert_false(types2.contains("loadReplay"))
  assert_true(types2.contains("turnEnded"))

  // session/new (resumed=false) never activates load_replay_guard.
  let fresh = @acp.Session::new("agy", kept=true)
  fresh.session = "conv-new"
  fresh.opened(resumed=false)
  ignore(fresh.prompted("prompt:n1", "ask", now~))
  t = 1100.0
  let end_new = fresh.line(j("{\"jsonrpc\":\"2.0\",\"id\":\"prompt:n1\",\"result\":{\"stopReason\":\"end_turn\"}}"), now)
  let types_new = types_of(end_new.events)
  assert_false(types_new.contains("loadReplay"))
  assert_true(types_new.contains("turnEnded"))
}

///|
test "agy Verification Required is classified as auth failure even under load_replay_guard" {
  assert_eq(@acp.classify("agy", "Verification Required"), "auth")
  assert_eq(@acp.notice_failure("\u{26a0} Verification Required"), Some("auth"))
  assert_eq(@acp.notice_failure("partial text\n\u{26a0} Verification Required\n"), Some("auth"))
  assert_eq(
    @acp.notice_failure("\u{26a0} Permission 'aiplatform.endpoints.predict' denied on resource '//aiplatform.googleapis.com/projects/p/locations/global/publishers/google/models/gemini-4-carbon' (or it may not exist)."),
    Some("auth"),
  )
  assert_eq(
    @acp.notice_failure("partial\n\u{26a0} Permission 'aiplatform.endpoints.predict' denied on resource '//aiplatform.googleapis.com/projects/p'."),
    None,
  )

  let now = () => 1000.0
  let s = @acp.Session::new("agy", kept=true)
  s.session = "conv-5"
  s.opened(resumed=true)
  ignore(s.prompted("prompt:p1", "ask", now~))
  ignore(
    s.line(
      j("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"conv-5\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"\u{26a0} Verification Required\"}}}}"),
      now,
    ),
  )
  let end = s.line(j("{\"jsonrpc\":\"2.0\",\"id\":\"prompt:p1\",\"result\":{\"stopReason\":\"end_turn\"}}"), now)
  assert_false(types_of(end.events).contains("loadReplay"))
  assert_true(
    end.events.iter().any(e => e.get("type") == Some(Str("turnEnded")) &&
      e.get("outcome").bind(o => o.get("kind")) == Some(Str("failed")) &&
      e.get("outcome").bind(o => o.get("reason")) == Some(Str("auth"))),
  )
}
