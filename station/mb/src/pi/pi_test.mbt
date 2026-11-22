// What the program makes of Pi's RPC lines (pi.mbt), on lines as Pi 1.5 writes them (station/src/agents/pi.ts).

///|
/// Each line read in turn: what each comes to, one line of JSON a line (`node` where Node reads it), its turn after.
fn said(session : Session, lines : Array[String]) -> String raise {
  let out = StringBuilder::new()
  for line in lines {
    let s = session.line(@jsjson.parse(line))
    for e in s.events {
      out.write_string(@jsjson.stringify(e))
      out.write_char('\n')
    }
    if s.node {
      out.write_string("node\n")
    }
  }
  out.write_string("turn " + @jsjson.stringify(session.turn.json()))
  out.to_string()
}

///|
fn fresh() -> Session {
  Session::new(Turn::new(), Live::new())
}

///|
test "a turn of ours: words, a call and its result, words, settled" {
  let s = fresh()
  let begun = s.prompted().map(e => @jsjson.stringify(e))
  inspect(begun, content=(
    #|[{"type":"live","event":{"kind":"phase","phase":"requesting"}}]
  ))
  inspect(
    said(s, [
      (
        #|{"id":"prompt:1","type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}
      ),
      (
        #|{"type":"agent_start"}
      ),
      (
        #|{"type":"turn_start"}
      ),
      (
        #|{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"run echo hi"}]}}
      ),
      (
        #|{"type":"message_start","message":{"role":"assistant","content":[],"stopReason":"pending"}}
      ),
      (
        #|{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":0}}
      ),
      (
        #|{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Let me look. "}}
      ),
      (
        #|{"type":"message_update","assistantMessageEvent":{"type":"toolcall_start","contentIndex":1,"id":"call_1","toolName":"bash"}}
      ),
      (
        #|{"type":"message_update","assistantMessageEvent":{"type":"toolcall_delta","contentIndex":1,"delta":""}}
      ),
      (
        #|{"type":"message_update","assistantMessageEvent":{"type":"toolcall_delta","contentIndex":1,"delta":"{\"command\":\"echo hi\"}"}}
      ),
      (
        #|{"type":"message_update","assistantMessageEvent":{"type":"text_end","contentIndex":0,"content":"Let me look. "}}
      ),
      (
        #|{"type":"message_update","assistantMessageEvent":{"type":"toolcall_end","contentIndex":1,"toolCall":{"type":"toolCall","id":"call_1","name":"bash","arguments":{"command":"echo hi"}}}}
      ),
      (
        #|{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"toolUse"}}
      ),
      (
        #|{"type":"tool_execution_start","toolCallId":"call_1","toolName":"bash","args":{"command":"echo hi"}}
      ),
      (
        #|{"type":"tool_execution_update","toolCallId":"call_1","toolName":"bash","args":{"command":"echo hi"},"partialResult":{"content":[{"type":"text","text":"hi\n"}]}}
      ),
      (
        #|{"type":"tool_execution_end","toolCallId":"call_1","toolName":"bash","result":{"content":[{"type":"text","text":"hi\n"}]},"isError":false}
      ),
      (
        #|{"type":"turn_end","message":{"role":"assistant"},"toolResults":[]}
      ),
      (
        #|{"type":"turn_start"}
      ),
      (
        #|{"type":"message_start","message":{"role":"assistant","content":[],"stopReason":"pending"}}
      ),
      (
        #|{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":0}}
      ),
      (
        #|{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Done."}}
      ),
      (
        #|{"type":"message_update","assistantMessageEvent":{"type":"text_end","contentIndex":0,"content":"Done."}}
      ),
      (
        #|{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Done."}],"stopReason":"stop"}}
      ),
      (
        #|{"type":"agent_end","messages":[],"willRetry":false}
      ),
      (
        #|{"type":"agent_settled","aborted":false}
      ),
    ]),
    content=(
      #|node
      #|{"type":"live","event":{"kind":"start","id":"m1#0","step":"text"}}
      #|{"type":"live","event":{"kind":"phase","phase":"responding"}}
      #|{"type":"live","event":{"kind":"delta","id":"m1#0","field":"text","text":"Let me look. "}}
      #|{"type":"live","event":{"kind":"start","id":"call_1","step":"tool","tool":"bash","input":""}}
      #|{"type":"live","event":{"kind":"delta","id":"call_1","field":"input","text":"{\"command\":\"echo hi\"}"}}
      #|{"type":"live","event":{"kind":"end","id":"m1#0"}}
      #|{"type":"live","event":{"kind":"phase","phase":"working"}}
      #|{"type":"live","event":{"kind":"delta","id":"call_1","field":"output","text":"hi\n"}}
      #|{"type":"live","event":{"kind":"end","id":"call_1"}}
      #|{"type":"live","event":{"kind":"phase","phase":"requesting"}}
      #|{"type":"live","event":{"kind":"start","id":"m2#0","step":"text"}}
      #|{"type":"live","event":{"kind":"phase","phase":"responding"}}
      #|{"type":"live","event":{"kind":"delta","id":"m2#0","field":"text","text":"Done."}}
      #|{"type":"live","event":{"kind":"end","id":"m2#0"}}
      #|{"type":"turnEnded","outcome":{"kind":"completed"}}
      #|turn {"busy":false,"prompted":false,"aborting":false}

    ),
  )
}

///|
test "a failed answer fails the turn as its provider's error says (an account's)" {
  let s = fresh()
  ignore(s.prompted())
  inspect(
    said(s, [
      (
        #|{"type":"agent_start"}
      ),
      (
        #|{"type":"message_start","message":{"role":"assistant","content":[],"stopReason":"error"}}
      ),
      (
        #|{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"401: {\"message\":\"Incorrect API key provided\",\"code\":\"invalid_api_key\"}"}}
      ),
      (
        #|{"type":"agent_settled"}
      ),
    ]),
    content=(
      #|{"type":"turnEnded","outcome":{"kind":"failed","reason":"auth","message":"401: {\"message\":\"Incorrect API key provided\",\"code\":\"invalid_api_key\"}"}}
      #|turn {"busy":false,"prompted":false,"aborting":false}

    ),
  )
}

///|
test "a retry that went through clears the failure before it" {
  let s = fresh()
  ignore(s.prompted())
  inspect(
    said(s, [
      (
        #|{"type":"agent_start"}
      ),
      (
        #|{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"529 overloaded"}}
      ),
      (
        #|{"type":"agent_end","messages":[],"willRetry":true}
      ),
      (
        #|{"type":"auto_retry_start","attempt":1,"maxAttempts":3,"delayMs":2000,"errorMessage":"529 overloaded"}
      ),
      (
        #|{"type":"agent_start"}
      ),
      (
        #|{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"ok"}],"stopReason":"stop"}}
      ),
      (
        #|{"type":"agent_settled","aborted":false}
      ),
    ]),
    content=(
      #|{"type":"turnEnded","outcome":{"kind":"completed"}}
      #|turn {"busy":false,"prompted":false,"aborting":false}

    ),
  )
}

///|
test "a turn stopped ends aborted, what it said so far ended" {
  let s = fresh()
  ignore(s.prompted())
  inspect(
    said(s, [
      (
        #|{"type":"agent_start"}
      ),
      (
        #|{"type":"message_start","message":{"role":"assistant","content":[],"stopReason":"pending"}}
      ),
      (
        #|{"type":"message_update","assistantMessageEvent":{"type":"thinking_start","contentIndex":0}}
      ),
      (
        #|{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":"hmm"}}
      ),
      (
        #|{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"aborted"}}
      ),
      (
        #|{"type":"agent_settled","aborted":true}
      ),
      (
        #|{"type":"response","command":"abort","success":true}
      ),
    ]),
    content=(
      #|{"type":"live","event":{"kind":"start","id":"m1#0","step":"thinking"}}
      #|{"type":"live","event":{"kind":"phase","phase":"responding"}}
      #|{"type":"live","event":{"kind":"delta","id":"m1#0","field":"text","text":"hmm"}}
      #|{"type":"live","event":{"kind":"end","id":"m1#0"}}
      #|{"type":"turnEnded","outcome":{"kind":"aborted"}}
      #|node
      #|turn {"busy":false,"prompted":false,"aborting":false}

    ),
  )
}

///|
test "a prompt refused ends the turn asked for; a run of its own is a turn started" {
  let s = fresh()
  ignore(s.prompted())
  inspect(
    said(s, [
      (
        #|{"id":"prompt:2","type":"response","command":"prompt","success":false,"error":"Agent is already processing."}
      ),
      (
        #|{"type":"agent_start"}
      ),
      (
        #|{"type":"agent_settled","aborted":false}
      ),
      (
        #|{"type":"extension_ui_request","id":"u1","method":"confirm","title":"Sure?"}
      ),
    ]),
    content=(
      #|{"type":"turnEnded","outcome":{"kind":"failed","reason":"other","message":"Agent is already processing."}}
      #|node
      #|{"type":"turnStarted"}
      #|{"type":"turnEnded","outcome":{"kind":"completed"}}
      #|node
      #|turn {"busy":false,"prompted":false,"aborting":false}

    ),
  )
}

///|
test "the station's tools out of reach, and the context compacted" {
  let s = fresh()
  ignore(s.prompted())
  inspect(
    said(s, [
      (
        #|{"type":"agent_start"}
      ),
      (
        #|{"type":"tool_execution_start","toolCallId":"c9","toolName":"mcp__stillfail__chat_post","args":{"text":"hi"}}
      ),
      (
        #|{"type":"tool_execution_end","toolCallId":"c9","toolName":"mcp__stillfail__chat_post","result":{"content":[{"type":"text","text":"fetch failed: connect ECONNREFUSED 127.0.0.1:4100"}]},"isError":true}
      ),
      (
        #|{"type":"compaction_start","reason":"threshold"}
      ),
      (
        #|{"type":"compaction_end","reason":"threshold","result":{"summary":"…","firstKeptEntryId":"a1","tokensBefore":150000},"aborted":false,"willRetry":false}
      ),
      (
        #|{"type":"agent_settled","aborted":false}
      ),
    ]),
    content=(
      #|{"type":"live","event":{"kind":"phase","phase":"working"}}
      #|{"type":"live","event":{"kind":"start","id":"c9","step":"tool","tool":"mcp__stillfail__chat_post","input":"{\n  \"text\": \"hi\"\n}"}}
      #|{"type":"live","event":{"kind":"delta","id":"c9","field":"output","text":"fetch failed: connect ECONNREFUSED 127.0.0.1:4100"}}
      #|{"type":"live","event":{"kind":"end","id":"c9"}}
      #|{"type":"live","event":{"kind":"phase","phase":"requesting"}}
      #|{"type":"toolsLost","why":"fetch failed: connect ECONNREFUSED 127.0.0.1:4100"}
      #|{"type":"live","event":{"kind":"phase","phase":"working"}}
      #|{"type":"live","event":{"kind":"phase","phase":"requesting"}}
      #|{"type":"compacted"}
      #|{"type":"turnEnded","outcome":{"kind":"completed"}}
      #|turn {"busy":false,"prompted":false,"aborting":false}

    ),
  )
}

///|
test "live steps as a station hands them over, taken up again" {
  let s = fresh()
  ignore(s.prompted())
  ignore(
    said(s, [
      (
        #|{"type":"agent_start"}
      ),
      (
        #|{"type":"message_start","message":{"role":"assistant","content":[]}}
      ),
      (
        #|{"type":"message_update","assistantMessageEvent":{"type":"toolcall_start","contentIndex":0,"id":"call_7","toolName":"read"}}
      ),
    ]),
  )
  let state = s.live.state()
  inspect(@jsjson.stringify(state), content=(
    #|{"open":[["call_7","tool"]],"calls":[["m1#0","call_7"]],"message":1,"phase":"responding"}

  ))
  let again = Session::new(Turn::of_json(s.turn.json()), Live::of_state(state))
  inspect(
    said(again, [
      (
        #|{"type":"message_update","assistantMessageEvent":{"type":"toolcall_delta","contentIndex":0,"delta":"{\"path\":\"a\"}"}}
      ),
      (
        #|{"type":"agent_settled","aborted":false}
      ),
    ]),
    content=(
      #|{"type":"live","event":{"kind":"delta","id":"call_7","field":"input","text":"{\"path\":\"a\"}"}}
      #|{"type":"live","event":{"kind":"end","id":"call_7"}}
      #|{"type":"turnEnded","outcome":{"kind":"completed"}}
      #|turn {"busy":false,"prompted":false,"aborting":false}

    ),
  )
}

///|
test "a crash's output read again: the turn running and its steps" {
  let r = Replay::new()
  for line in [
    (
      #|{"id":"open","type":"response","command":"get_state","success":true,"data":{}}
    ),
    (
      #|{"type":"agent_start"}
    ),
    (
      #|{"type":"message_start","message":{"role":"assistant","content":[]}}
    ),
    (
      #|{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":0}}
    ),
  ] {
    r.line(@jsjson.parse(line))
  }
  inspect(@jsjson.stringify(r.session.turn.json()) + " " + @jsjson.stringify(r.session.live.state()), content=(
    #|{"busy":true,"prompted":false,"aborting":false} {"open":[["m1#0","text"]],"calls":[],"message":1,"phase":null}

  ))
}

///|
test "what failed a turn, as Pi words its provider's errors" {
  let reasons = [
    "401: {\"message\":\"Incorrect API key provided\"}", "429 Too Many Requests: rate limit reached", "529 overloaded",
    "context overflow: prompt is too long", "fetch failed: getaddrinfo ENOTFOUND api.example.com", "500 internal error",
  ].map(t => classify_failure(t))
  inspect(reasons, content=(
    #|[auth, rate_limit, overloaded, context, network, model]

  ))
}
