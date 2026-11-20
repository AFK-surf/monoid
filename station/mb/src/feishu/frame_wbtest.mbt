///|
/// What `f` was refused with, or None.
fn refusal(f : () -> Unit raise FeishuError) -> String? {
  f() catch {
    e => return Some(error_words(e))
  }
  None
}

///|
fn data_frame(headers : Array[(String, String)], payload : Bytes) -> Frame {
  {
    seq_id: Big::of(5UL),
    log_id: Big::of(0UL),
    service: -1L,
    meth: method_data,
    headers,
    payload_encoding: None,
    payload_type: None,
    payload: Some(payload),
    log_id_new: None,
  }
}

///|
test "a frame encodes as the TypeScript's and reads back" {
  let f = data_frame([("type", "event")], b"{}")
  let bytes = encode(f)
  assert_eq(
    @codec.hex_encode(bytes),
    "0805100018ffffffffffffffffff0120012a0d0a047479706512056576656e7442027b7d",
  )
  let back = decode(bytes)
  assert_eq(back.service, -1L)
  assert_eq(back.meth, method_data)
  assert_eq(back.headers, [("type", "event")])
  assert_eq(back.payload, Some(b"{}"))
}

///|
test "bytes cut short are refused" {
  assert_true(refusal(() => ignore(decode(@codec.hex_decode("2a05").unwrap()))) is Some(_))
}

///|
test "a whole number keeps its low 64 bits, as BigInt.asUintN(64, …) does" {
  assert_eq(wrap64(0.0), 0L)
  assert_eq(wrap64(-7.0), -7L)
  assert_eq(wrap64(8.0), 8L)
  // 2^63 is -2^63 as an Int64's bits; 2^64 and past are their remainder
  assert_eq(wrap64(9223372036854775808.0), -9223372036854775808L)
  assert_eq(wrap64(18446744073709551616.0), 0L)
  assert_eq(wrap64(18446744073709551616.0 + 4096.0), 4096L)
  assert_eq(wrap64(-9223372036854775808.0), -9223372036854775808L)
  assert_eq(wrap64(-18446744073709551616.0 + 4096.0), 4096L)
  assert_eq(wrap64(1.0e30), 5076964154930102272L)
}

///|
test "parts come together once all are in, in their order" {
  let parts = Parts::new()
  let part = (seq : String, b : Bytes) => data_frame(
    [("type", "event"), ("message_id", "m"), ("sum", "2"), ("seq", seq)],
    b,
  )
  assert_eq(parts.add(part("1", b"cd"), 0L), None)
  assert_eq(parts.add(part("0", b"ab"), 1L), Some(b"abcd"))
  assert_eq(parts.open_count(), 0)
  // one never finished goes once old
  assert_eq(parts.add(part("0", b"ab"), 10L), None)
  parts.drop(5L)
  assert_eq(parts.open_count(), 1)
  parts.drop(11L)
  assert_eq(parts.open_count(), 0)
  // a frame not in parts is its payload
  assert_eq(parts.add(data_frame([("type", "event")], b"x"), 0L), Some(b"x"))
}

///|
test "a count of parts no array can have is refused as JavaScript refuses it" {
  let parts = Parts::new()
  let odd = data_frame([("type", "event"), ("sum", "1.5")], b"")
  assert_eq(
    refusal(() => ignore(parts.add(odd, 0L))),
    Some("Invalid array length"),
  )
}

///|
test "a ping with a service no BigInt can be is refused as JavaScript refuses it" {
  assert_eq(
    refusal(() => ignore(ping_frame(1.5))),
    Some(
      "The number 1.5 cannot be converted to a BigInt because it is not an integer",
    ),
  )
  let ping = decode(ping_frame(-7.0))
  assert_eq(ping.service, -7L)
  assert_eq(ping.meth, method_control)
  assert_eq(ping.headers, [("type", "ping")])
}

///|
test "resource_url and resource_of round-trip image and file keys and reject malformed values" {
  let img = resource_url("om_123", "img_v2_abc:extra", "image")
  assert_eq(img, "feishu:image:om_123:img_v2_abc:extra")
  assert_eq(resource_of(img), Some(("image", "om_123", "img_v2_abc:extra")))
  assert_eq(resource_of(resource_url("om_1", "f_1", "file")), Some(("file", "om_1", "f_1")))
  assert_eq(resource_of("feishu:video:om_1:v_1"), None)
  assert_eq(resource_of("feishu:image::k"), None)
  assert_eq(resource_of("feishu:image:om_1:"), None)
}

///|
test "message_of parses p2p, group mentions, fresh session commands, files and filters bots" {
  let mk = (sender_type : String, chat_type : String, msg_type : String, content : String, mentions : Array[JV]) => jobj([
    ("sender", Some(jobj([("sender_type", Some(js(sender_type))), ("sender_id", Some(jobj([("open_id", Some(js("ou_u1")))]))) ]))),
    (
      "message",
      Some(
        jobj([
          ("message_id", Some(js("om_1"))),
          ("chat_id", Some(js("oc_1"))),
          ("chat_type", Some(js(chat_type))),
          ("message_type", Some(js(msg_type))),
          ("content", Some(js(content))),
          ("mentions", Some(Arr(mentions))),
          ("create_time", Some(js("1700000000000"))),
        ]),
      ),
    ),
  ])
  // app/bot sender is ignored
  assert_true(message_of(Some(mk("app", "p2p", "text", "{\"text\":\"hi\"}", [])), "ou_bot") is None)
  // p2p /new sets addressed and fresh
  let p2p = message_of(Some(mk("user", "p2p", "text", "{\"text\":\" /new \"}", [])), "ou_bot").unwrap()
  assert_eq(p2p.addressed, true)
  assert_eq(p2p.fresh, true)
  assert_eq(p2p.p2p, true)
  assert_eq(p2p.at, 1700000000000.0)
  // group without bot mention is not addressed
  let grp = message_of(Some(mk("user", "group", "text", "{\"text\":\"hello\"}", [])), "ou_bot").unwrap()
  assert_eq(grp.addressed, false)
  assert_eq(grp.fresh, false)
  // group with bot mention is addressed
  let m_bot = jobj([("key", Some(js("@_user_1"))), ("name", Some(js("Bot"))), ("id", Some(jobj([("open_id", Some(js("ou_bot")))])))])
  let grp_at = message_of(Some(mk("user", "group", "text", "{\"text\":\"@_user_1 ping\"}", [m_bot])), "ou_bot").unwrap()
  assert_eq(grp_at.addressed, true)
  assert_true(grp_at.text.contains("ping"))
  // image message yields inbound file resource
  let img = message_of(Some(mk("user", "p2p", "image", "{\"image_key\":\"img_9\"}", [])), "ou_bot").unwrap()
  assert_eq(img.files.length(), 1)
  assert_eq(img.files[0].id, "img_9")
  assert_eq(img.files[0].url, Some("feishu:image:om_1:img_9"))
}

///|
test "feishu domain, open/accounts URLs, api_method and secret masking" {
  assert_eq(domain_of(None), "feishu")
  assert_eq(domain_of(Some(js("lark"))), "lark")
  assert_eq(open_of("feishu"), "https://open.feishu.cn")
  assert_eq(open_of("lark"), "https://open.larksuite.com")
  assert_eq(accounts_of("feishu"), "https://accounts.feishu.cn")
  assert_eq(accounts_of("lark"), "https://accounts.larksuite.com")
  assert_eq(api_method("GET /open-apis/im/v1/chats"), Some(("GET", "/open-apis/im/v1/chats")))
  assert_eq(api_method("POST /open-apis/im/v1/messages"), Some(("POST", "/open-apis/im/v1/messages")))
  assert_eq(api_method("INVALID"), None)
  assert_eq(mask_secret("cli_secret_123456"), "••••3456")
  assert_eq(mask_secret("short"), "••••hort")
  assert_eq(mask_secret("abc"), "••••")
  assert_eq(text_posts("hello"), ["{\"zh_cn\":{\"content\":[[{\"tag\":\"md\",\"text\":\"hello\"}]]}}"])
}
