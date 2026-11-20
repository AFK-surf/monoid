// Native MoonBit blackbox tests for session_chats public API.

///|
test "a title, a split for Slack, a thread's address" {
  inspect(@session_chats.clean_title("  Fix   the\tbuild.  "), content="Fix the build")
  inspect(@session_chats.clean_title("修好构建。。"), content="修好构建")
  inspect(@session_chats.split_for_slack("aaaa\n\nbbbb", 6), content=(
    #|[aaaa, bbbb]
  ))
  inspect(@session_chats.parse_thread_address(" C1/1.2 "), content=(
    #|Some((C1, 1.2))
  ))
  inspect(@session_chats.parse_thread_address("c1/1.2"), content="None")
}

///|
test "links Markdown finds, outside code" {
  let found = @session_chats.links("see [a](/tmp/a.txt) `[b](/no)` <file:///x>")
  inspect(found.map(f => f.destination), content=(
    #|[/tmp/a.txt, file:///x]
  ))
  inspect(@session_chats.percent_decode("/a%20b%zz"), content="/a b%zz")
}

///|
test "a picture's size from its first bytes" {
  let gif = Bytes::from_array([b'G', b'I', b'F', b'8', b'9', b'a', b'\x80', b'\x02', b'\xe0', b'\x01', b'\x00', b'\x00'])
  inspect(@session_chats.size_of(gif), content="Some((640, 480))")
  inspect(@session_chats.size_of(Bytes::from_array([b'\x01', b'\x02'])), content="None")
}

///|
test "records as both sides keep them" {
  let a = @session_chats.parse_js("{\"id\":\"p\",\"owner\":\"o\",\"rev\":2,\"updatedAt\":1}")
  let b = @session_chats.parse_js("{\"id\":\"p\",\"owner\":\"o\",\"rev\":2,\"gone\":true,\"updatedAt\":1}")
  inspect(@session_chats.is_gone(@session_chats.newer_record(a, b)), content="true")
  inspect(@session_chats.canonical(@session_chats.parse_js("{\"b\":1,\"a\":[true,null]}")), content="{\"a\":[true,null],\"b\":1}")
  inspect(@session_chats.repo_name("git@github.com:o/r.git"), content="github.com/o/r")
}

///|
test "a decision model's choices and preference" {
  inspect(@session_chats.decision_priority("qwen-3-flash"), content="1")
  inspect(@session_chats.by_decision_priority("glm-5", "gpt-6") > 0, content="true")
  inspect(@session_chats.js_compare("agent_work", "complete") < 0, content="true")
}
