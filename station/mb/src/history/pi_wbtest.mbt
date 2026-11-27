// Pi's session file as timeline entries (entries.mbt `pi`).

///|
test "Pi's messages as entries" {
  let records = [
    (
      #|{"type":"session","version":3,"id":"s1","timestamp":"2026-11-16T09:56:41.832Z","cwd":"/w"}
    ),
    (
      #|{"type":"message","id":"a0","parentId":null,"timestamp":"2026-11-16T09:56:41.880Z","message":{"role":"system","content":"","sections":{"preamble":"You are…"}}}
    ),
    (
      #|{"type":"message","id":"a1","parentId":"a0","timestamp":"2026-11-16T09:56:41.882Z","message":{"role":"user","content":[{"type":"text","text":"run echo hi"}]}}
    ),
    (
      #|{"type":"message","id":"a2","parentId":"a1","timestamp":"2026-11-16T09:56:41.907Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"It wants a command."},{"type":"text","text":"Let me look. "},{"type":"toolCall","id":"call_1","name":"bash","arguments":{"command":"echo hi"}}],"stopReason":"toolUse"}}
    ),
    (
      #|{"type":"message","id":"a3","parentId":"a2","timestamp":"2026-11-16T09:56:41.912Z","message":{"role":"toolResult","toolCallId":"call_1","toolName":"bash","content":[{"type":"text","text":"hi\n"}],"isError":false}}
    ),
    (
      #|{"type":"compaction","id":"a4","parentId":"a3","timestamp":"2026-11-16T09:57:00.000Z","summary":"…","firstKeptEntryId":"a3","tokensBefore":5000}
    ),
    (
      #|{"type":"message","id":"a5","parentId":"a4","timestamp":"2026-11-16T09:57:01.000Z","message":{"role":"user","content":"and again"}}
    ),
  ]
  let out : Array[Entry] = []
  for r in records {
    timeline_of("pi", @jsjson.parse(r), ReadState::new(), out)
  }
  inspect(out.map(e => (e.at, e.kind, e.text, e.tool, e.ok, e.call_id, e.said)), content=(
    #|[(Some(2026-11-16T09:56:41.882Z), user, run echo hi, None, None, None, None), (Some(2026-11-16T09:56:41.907Z), thinking, It wants a command., None, None, None, None), (Some(2026-11-16T09:56:41.907Z), assistant, Let me look. , None, None, None, None), (Some(2026-11-16T09:56:41.907Z), tool_call, {
    #|  "command": "echo hi"
    #|}, Some(bash), None, Some(call_1), Some({"command":"echo hi"})), (Some(2026-11-16T09:56:41.912Z), tool_result, hi
    #|, None, Some(true), Some(call_1), None), (Some(2026-11-16T09:57:01.000Z), user, and again, None, None, None, None)]

  ))
}

///|
test "can_skip_record_bytes pre-filter matches timeline_of across edge cases" {
  let skip = (rt : String, s : String) => can_skip_record_bytes(rt, @utf8.encode(s)[:])
  // Claude ignored types (including huge nested payloads with "type":"user" inside)
  assert_true(skip("claude", "{\"type\":\"api-request\",\"payload\":{\"type\":\"user\",\"data\":\"AAAA\"}}"))
  assert_true(skip("claude", "{\"uuid\":\"1\",\"type\":\"progress\",\"data\":{\"x\":1}}"))
  assert_true(skip("claude", "{\"type\":\"user\",\"isMeta\":true,\"message\":{\"content\":\"x\"}}"))
  assert_true(skip("claude", "   \r"))
  // Non-object and malformed JSON conservatively fall back to full parser
  assert_false(skip("claude", "[1,2,3]"))
  assert_false(skip("claude", "{\"type\":\"progress\"} trailing"))
  assert_false(skip("claude", "{\"type\":\"progress\""))
  // Claude kept types, duplicate keys (last wins, matching jsjson::parse), escapes, attachment with isMeta
  assert_false(skip("claude", "{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}"))
  assert_false(skip("claude", "{\"type\":\"assistant\",\"message\":{\"content\":\"hi\"}}"))
  assert_false(skip("claude", "{\"type\":\"attachment\",\"isMeta\":true,\"attachment\":{\"type\":\"queued_command\"}}"))
  assert_false(skip("claude", "{\"type\":\"api-request\",\"type\":\"user\",\"message\":{\"content\":\"hi\"}}"))
  assert_false(skip("claude", "{\"type\":\"user\",\"isMeta\":true,\"isMeta\":false}"))
  assert_false(skip("claude", "{\"type\":\"user\",\"isMeta\":\"true\"}"))
  assert_false(skip("claude", "{\"\\u0074ype\":\"user\"}"))
  assert_false(skip("claude", "{\"type\":\"\\u0075ser\"}"))
  let dup_ignored = "{\"type\":\"user\",\"message\":{\"content\":\"hi\"},\"type\":\"progress\"}"
  assert_true(skip("claude", dup_ignored))
  let out_ign : Array[Entry] = []
  timeline_of("claude", @jsjson.parse(dup_ignored), ReadState::new(), out_ign)
  assert_eq(out_ign.length(), 0)
  let dup_kept = "{\"type\":\"progress\",\"type\":\"user\",\"message\":{\"content\":\"hi\"}}"
  assert_false(skip("claude", dup_kept))
  let out_kept : Array[Entry] = []
  timeline_of("claude", @jsjson.parse(dup_kept), ReadState::new(), out_kept)
  assert_eq(out_kept.length(), 1)
  // Codex, Pi, Grok, and non-skipped DSH/Cursor
  assert_true(skip("codex", "{\"type\":\"event_msg\",\"payload\":{\"type\":\"response_item\"}}"))
  assert_false(skip("codex", "{\"type\":\"response_item\",\"payload\":{}}"))
  assert_true(skip("pi", "{\"type\":\"compaction\",\"summary\":\"x\"}"))
  assert_false(skip("pi", "{\"type\":\"message\",\"message\":{}}"))
  assert_true(skip("grok", "{\"type\":\"meta\"}"))
  assert_false(skip("grok", "{\"type\":\"tool_result\"}"))
  assert_false(skip("dsh", "{\"type\":\"ignored\",\"time\":1e20}"))
  assert_false(skip("cursor", "{\"type\":\"ignored\",\"time\":1e20}"))
}

///|
test "clip and first_chars handle astral code points without per-char array allocation" {
  let sb = StringBuilder::new()
  for _ in 0..<4002 {
    sb.write_string("🚀")
  }
  let s = sb.to_string()
  let clipped = clip(s)
  assert_true(clipped.has_suffix("\n… (2 more characters)"))
  assert_eq(first_chars("a🚀b中", 2), "a🚀")
  assert_eq(first_chars("a🚀b中", 10), "a🚀b中")
}
