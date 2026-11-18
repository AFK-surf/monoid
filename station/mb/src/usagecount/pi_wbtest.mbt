// Pi's session file read for its calls (calls.mbt `calls_of`, "pi"): each answer of the model's that used something.

///|
test "Pi's answers as its calls" {
  let text =
    #|{"type":"session","version":3,"id":"s1","timestamp":"2026-11-16T09:56:41.832Z","cwd":"/w"}
    #|{"type":"message","id":"a1","parentId":null,"timestamp":"2026-11-16T09:56:41.882Z","message":{"role":"user","content":[{"type":"text","text":"what is \"usage\"?"}]}}
    #|{"type":"message","id":"a2","parentId":"a1","timestamp":"2026-11-16T09:56:41.907Z","message":{"role":"assistant","content":[{"type":"text","text":"Let me look."}],"provider":"stillfail","model":"m1","usage":{"input":100,"output":7,"cacheRead":20,"cacheWrite":5,"totalTokens":132},"stopReason":"toolUse"}}
    #|{"type":"message","id":"a3","parentId":"a2","timestamp":"2026-11-16T09:56:42.000Z","message":{"role":"assistant","content":[],"provider":"stillfail","model":"m1","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0},"stopReason":"aborted"}}
  let calls = calls_of("pi", @utf8.encode(text), false, { model: None, codex_id: None, window: None, speed: no_speed() })
  inspect(
    calls.map(c => (c.id, c.at, c.model, c.input, c.cache_read, c.cache_write, c.output, c.calls, c.context)),
    content=(
      #|[(pi:a2, 1794823001907, Some(m1), 100, 20, 5, 7, 1, Some(125))]

    ),
  )
}
