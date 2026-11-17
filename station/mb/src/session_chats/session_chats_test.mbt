// What these parts say of themselves, each as the TypeScript it is written from says it (the whole of it held to the
// TypeScript by station/test/mb-session-chats.test.ts).

///|
test "a title, a split for Slack, a thread's address" {
  inspect(clean_title("  Fix   the\tbuild.  "), content="Fix the build")
  inspect(clean_title("修好构建。。"), content="修好构建")
  inspect(split_for_slack("aaaa\n\nbbbb", 6), content=(
    #|[aaaa, bbbb]
  ))
  inspect(parse_thread_address(" C1/1.2 "), content=(
    #|Some((C1, 1.2))
  ))
  inspect(parse_thread_address("c1/1.2"), content="None")
}

///|
test "links Markdown finds, outside code" {
  let found = links("see [a](/tmp/a.txt) `[b](/no)` <file:///x>")
  inspect(found.map(f => f.destination), content=(
    #|[/tmp/a.txt, file:///x]
  ))
  inspect(percent_decode("/a%20b%zz"), content="/a b%zz")
}

///|
test "a picture's size from its first bytes" {
  let gif = Bytes::from_array([b'G', b'I', b'F', b'8', b'9', b'a', b'\x80', b'\x02', b'\xe0', b'\x01', b'\x00', b'\x00'])
  inspect(size_of(gif), content="Some((640, 480))")
  inspect(size_of(Bytes::from_array([b'\x01', b'\x02'])), content="None")
}

///|
test "records as both sides keep them" {
  let a = parse_js("{\"id\":\"p\",\"owner\":\"o\",\"rev\":2,\"updatedAt\":1}")
  let b = parse_js("{\"id\":\"p\",\"owner\":\"o\",\"rev\":2,\"gone\":true,\"updatedAt\":1}")
  inspect(is_gone(newer_record(a, b)), content="true")
  inspect(canonical(parse_js("{\"b\":1,\"a\":[true,null]}")), content="{\"a\":[true,null],\"b\":1}")
  inspect(repo_name("git@github.com:o/r.git"), content="github.com/o/r")
}

///|
test "a decision model's choices and preference" {
  inspect(decision_priority("qwen-3-flash"), content="1")
  inspect(by_decision_priority("glm-5", "gpt-6") > 0, content="true")
  inspect(js_compare("agent_work", "complete") < 0, content="true")
}
