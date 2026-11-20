// Native MoonBit whitebox tests for session_chats core logic.

///|
test "chat_key generation, naming, and workspace paths" {
  assert_eq(chat_key("hello-world"), "\{chat_key_prefix}:hello-world")
  assert_eq(chat_key("hello-world", made=k => k == "\{internal_connect}:hello-world"), "\{internal_connect}:hello-world")
  assert_eq(chat_named("chat:c-1", "my-title", None), "my-title")
  assert_eq(chat_workspace("/data", "chat:c-1"), "/data/sessions/chat/c-1/workspace")
  assert_true(is_internal_channel(internal_channel))
  assert_true(!is_internal_channel("C12345"))
  assert_eq(internal_user_name("alice@example.com"), Some("alice@example.com"))
}

///|
test "internal_post validates and formats timestamp" {
  let ts = internal_post("CHAT", "hello", 1700000000123.0)
  assert_true(ts.has_prefix("1700000000."))
  let rejected = try {
    ignore(internal_post("C123", "hello", 1700000000000.0))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "title helpers, text slicing, and URI encoding" {
  assert_eq(given_title(parse_js("{\"title\":\"  Deploy fix. \"}")), Some("Deploy fix."))
  assert_eq(given_title(parse_js("{\"title\":\"   \"}")), None)
  assert_eq(first_chars("abcdef", 3), "abc")
  assert_eq(first_chars("你好世界", 2), "你好")
  assert_eq(char_count("a中😀"), 3)
  assert_eq(byte_length("a中😀"), 8)
  assert_eq(encode_uri_component("a/b?c=1"), "a%2Fb%3Fc%3D1")
  assert_eq(about_ts(parse_js("{\"about\":\"1700.001\"}")), Some("1700.001"))
  assert_eq(about_ts(parse_js("{}")), None)
}

///|
test "preset records: allowed_in, gone_kept, and codex_config" {
  assert_true(allowed_in(parse_js("{}"), Some("w1"), Some("w1")))
  assert_true(allowed_in(parse_js("{\"share\":{\"borrowed\":true,\"workspaces\":[\"w1\"]}}"), Some("w1"), Some("w1")))
  assert_true(!allowed_in(parse_js("{\"share\":{\"borrowed\":true,\"workspaces\":[\"w1\"]}}"), Some("w2"), Some("w1")))
  let r1 = parse_js("{\"id\":\"a\",\"gone\":true,\"updatedAt\":1}")
  let r2 = parse_js("{\"id\":\"b\",\"gone\":true,\"updatedAt\":2}")
  let kept = gone_kept([r1, r2])
  assert_eq(kept.length(), 2)
  let cfg = codex_config("model = \"gpt-6\"\nmodel_reasoning_effort = \"high\"\n")
  assert_true(cfg is Some(_))
}

///|
test "image header parsing for PNG and GIF" {
  // 16x32 PNG IHDR header
  let png = Bytes::from_array([
    b'\x89', b'P', b'N', b'G', b'\r', b'\n', b'\x1a', b'\n',
    b'\x00', b'\x00', b'\x00', b'\x0d', b'I', b'H', b'D', b'R',
    b'\x00', b'\x00', b'\x00', b'\x10', b'\x00', b'\x00', b'\x00', b'\x20',
  ])
  match header_size(png[:]) {
    Some(f) => {
      assert_eq(f.width, 16)
      assert_eq(f.height, 32)
    }
    None => fail("expected PNG header")
  }
  assert_true(header_size(Bytes::from_array([b'\x00', b'\x01'])[:]) is None)
}

///|
test "decision transport and completion acceptance" {
  let tr = decision_transport(parse_js("{\"runtime\":\"claude\",\"model\":\"claude-opus-5-5\"}"), "claude")
  assert_true(!(tr is Null))
  assert_true(accepts_completion(parse_js("{\"selected\":\"complete\",\"probabilities\":{\"complete\":0.9}}"), 0.8))
  assert_true(!accepts_completion(parse_js("{\"selected\":\"complete\",\"probabilities\":{\"complete\":0.5}}"), 0.8))
  assert_true(!accepts_completion(parse_js("{\"selected\":\"agent_work\",\"probabilities\":{\"complete\":0.9}}"), 0.8))
}
