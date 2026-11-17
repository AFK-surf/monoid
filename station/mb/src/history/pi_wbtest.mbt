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
