// The pure parts, as the TypeScript says them (station/test/mb-connects-hub.test.ts holds the rest to it, through the
// program).

///|
test "a connect's names across the workspace" {
  assert_eq(local_of({ id: "cl", origin: "H" }, "H"), "cl")
  assert_eq(local_of({ id: "cl", origin: "H" }, "S"), "cl@H")
  assert_true(known_of("cl@H", "S") == { id: "cl", origin: "H" })
  assert_true(known_of("a@b@c", "S") == { id: "a@b", origin: "c" })
  assert_true(known_of("@x", "S") == { id: "@x", origin: "S" })
  assert_true(known_of("x@", "S") == { id: "x@", origin: "S" })
  assert_true(known_in(Some(jo([("id", js("a")), ("origin", js("b"))]))) == Some({ id: "a", origin: "b" }))
  assert_true(known_in(Some(jo([("id", js(""))]))) == None)
  assert_eq(person_key("T", "U"), "u:T:U")
  assert_eq(channel_key("T", "C"), "c:T:C")
}

///|
test "secrets and codes hashed as the TypeScript hashes them" {
  assert_eq(code_hash("abcd-efgh"), "9ac2197d9258257b1ae8463e4214e4cd0a578bc1517f2415928b91be4283fc48")
  assert_eq(code_hash(" ab cd\tEF\u{3000}gh "), "9ac2197d9258257b1ae8463e4214e4cd0a578bc1517f2415928b91be4283fc48")
  assert_true(fingerprint("slack", Some(jo([("botToken", js("xoxb-1"))]))) == Some("afdde9fcfcc6600518d76f76883594d9ebbc9af3e2fd519b08d0c54be44fd293"))
  assert_true(fingerprint("feishu", Some(jo([("botToken", js("xoxb-1"))]))) == None)
  assert_eq(js_upper("straße ǆ ﬀ ß"), "STRASSE Ǆ FF SS")
}

///|
test "mentions as `@name`, not the start of a longer word" {
  assert_true(mentions("@Claude hi", "Claude"))
  assert_true(mentions("hi @claude", "Claude"))
  assert_true(mentions("(@Claude).", "Claude"))
  assert_false(mentions("@Claudebot", "Claude"))
  assert_false(mentions("x@Claude", "Claude"))
  assert_false(mentions("@Claude_", "Claude"))
  assert_false(mentions("anything", ""))
}

///|
test "an event stream read across pieces, a character cut between two" {
  let sse = SseLines::new()
  let text = utf8("event: message\ndata: 你好\nid: 7\n\n: c\n\nid: 9\n\n")
  let out = []
  for i in 0..<text.length() {
    for e in sse.feed(text[i:i + 1].to_owned()) {
      out.push(e)
    }
  }
  assert_true(out == [("message", "你好", Some("7")), ("", "", Some("9"))])
}

///|
test "a picture's size, of its head" {
  let png = Bytes::from_array([
    0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 7, 128, 0, 0, 4, 56, 8, 6, 0, 0, 0,
  ].map(x => x.to_byte()))
  assert_true(image_size(png) == Some((1920.0, 1080.0)))
  assert_true(image_size(b"\x01\x02\x03") == None)
  assert_eq(mime_of("a.PNG"), "image/png")
  assert_eq(mime_of(".png"), "application/octet-stream")
}

///|
test "JavaScript's ways with text and objects" {
  assert_eq(replace_first("<\u{1}|\u{2}>", "\u{1}", "a$&b"), "<a\u{1}b|\u{2}>")
  assert_eq(request_percent_decode("a%20b+c%zz"), "a b c%zz")
  assert_eq(segment("a+b%2B"), "a+b+")
  assert_eq(js_stringify(from_entries([("b", jn(1.0)), ("10", jn(2.0)), ("2", jn(3.0)), ("a", jn(4.0))])), "{\"2\":3,\"10\":2,\"b\":1,\"a\":4}")
}

///|
test "a connect's link to its platform, as the pages show it" {
  let c = Connections::new("slack", async fn(_) { raise fail_("none") }, async fn(_, _) { () }, c => str_of(at(Some(c), "token")), {
    write: (_, _, _, _) => (),
  })
  assert_eq(js_stringify(c.state(jo([("id", js("a")), ("enabled", jb(false))]))), "{\"state\":\"disabled\"}")
  assert_eq(js_stringify(c.state(jo([("id", js("a")), ("enabled", jb(true))]))), "{\"state\":\"no_tokens\"}")
  assert_eq(js_stringify(c.state(jo([("id", js("a")), ("enabled", jb(true)), ("token", js("t"))]))), "{\"state\":\"starting\"}")
}

///|
test "an im/2 event byte for byte as the IM's canon.mbt and event.mbt make it" {
  let body = parse_js(
    "{\"text\":\"@Claude 看看 \\\"CI\\\"\\n\\ttab\\u0001 😀\",\"input\":\"options\",\"options\":[{\"label\":\"合并\",\"detail\":\"现在\",\"recommended\":true},{\"label\":\"先不\"}],\"placeholder\":\"\",\"assignee\":\"\",\"files\":[],\"reply_to\":\"\"}",
  )
  let e : GroupEvent = {
    space: "s_0123456789abcdef01234567",
    author: "m_00112233aabbccdd",
    device: "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c",
    dseq: 7.0,
    hlc: (1794882529815.0, 2.0),
    prev: "5feceb66ffc86f38d952786c6d696c79c2dbc239dd4e91b46729d73a27fb57e9",
    topic: "t_0011223344556677",
    kind: "decision.ask",
    body,
    sig: "",
  }
  assert_eq(
    signed_text(e),
    "{\"v\":2,\"enc\":0,\"hlc\":[1794882529815,2],\"body\":{\"text\":\"@Claude 看看 \\\"CI\\\"\\n\\ttab\\u0001 😀\",\"files\":[],\"input\":\"options\",\"options\":[{\"label\":\"合并\",\"detail\":\"现在\",\"recommended\":true},{\"label\":\"先不\"}],\"assignee\":\"\",\"reply_to\":\"\",\"placeholder\":\"\"},\"dseq\":7,\"kind\":\"decision.ask\",\"prev\":\"5feceb66ffc86f38d952786c6d696c79c2dbc239dd4e91b46729d73a27fb57e9\",\"space\":\"s_0123456789abcdef01234567\",\"topic\":\"t_0011223344556677\",\"author\":\"m_00112233aabbccdd\",\"device\":\"8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c\"}",
  )
  assert_eq(event_id(e), "b8b9ecd23e14a8a18f1df89c0a8660b577fd60a47ca4fd081f6a0ec10ed55950")
  assert_eq(direct_id("m_00112233aabbccdd", "m_ffeeddccbbaa9988"), "d_2518d7ef7594305b0568a1c0")
  assert_eq(direct_id("m_ffeeddccbbaa9988", "m_00112233aabbccdd"), "d_2518d7ef7594305b0568a1c0")
  assert_eq(
    canonical_json(parse_js("{\"\\uffff\\uffff\":1,\"\\ud83d\\ude00\":2,\"ab\":3,\"B\":4,\"a\":5,\"\\u00e9\":6}")),
    "{\"B\":4,\"a\":5,\"é\":6,\"ab\":3,\"😀\":2,\"\u{ffff}\u{ffff}\":1}",
  )
  assert_true(moon_order("v", "body") < 0 && moon_order("enc", "author") < 0)
}

///|
test "a set keeps its order of adding, as JavaScript's does" {
  let s : Set[String] = Set([])
  for i in 0..<300 {
    s.add("id-\{299 - i}")
  }
  s.add("id-299")
  assert_eq(s.iter().head(), Some("id-299"))
  s.remove("id-299")
  assert_eq(s.iter().head(), Some("id-298"))
  s.add("id-299")
  assert_eq(s.iter().head(), Some("id-298"))
  assert_eq(s.iter().last(), Some("id-299"))
}

///|
test "parse_ws_refusal extracts status and refusal words and ConnectedSurface surfaces them" {
  assert_eq(
    parse_ws_refusal("websocket refused (409): this still.fail workspace is connected already"),
    Some((409, "this still.fail workspace is connected already")),
  )
  assert_eq(parse_ws_refusal("websocket refused (502)"), Some((502, "")))
  assert_eq(parse_ws_refusal("websocket refused (403):   too_many_websockets  "), Some((403, "too_many_websockets")))
  assert_eq(parse_ws_refusal("websocket: connection reset"), None)
  assert_eq(parse_ws_refusal("websocket refused ()"), None)
  let rt = @effect.Runtime::new()
  let got : Ref[String?] = Ref(None)
  ignore(
    rt.fork(async fn() {
      let surface = ConnectedSurface::new(
        "comma",
        {
          connect: Some("cm-1"),
          book: None,
          ping_ms: 5000.0,
          stale_ms: 20000.0,
          backoff_ms: 1000.0,
          clock: {
            now: () => rt.now().to_double(),
            sleep: async fn(ms) { @effect.sleep(ms.to_int()) },
          },
          on_heard: () => (),
          log: { write: (_, _, _, _) => () },
          open_socket: Some(
            (_, _) => {
              let events : @effect.Queue[SocketEvent] = @effect.Queue::unbounded()
              let (n, why) = parse_ws_refusal("websocket refused (409): workspace already connected").unwrap()
              ignore(events.try_offer(Refused(n, why)))
              { events, send: _ => (), ping: () => (), terminate: () => (), is_open: () => false }
            },
          ),
        },
      )
      surface.socket_to(
        "wss://comma.invalid/ws",
        { opened: _ => (), message: (_, _, _, _, _) => (), ping: _ => () },
      ) catch {
        e => got.val = Some(thrown_message(e))
      }
      surface.stop()
    }),
  )
  rt.advance(0)
  assert_eq(got.val, Some("comma refused the connection: HTTP 409 workspace already connected"))
}

///|
test "feishu_api across stations: JSON as it was, a Feishu file as bytes beside its content type and disposition" {
  let image = b"\xff\xd8\xff\x00\x80\xfe"
  let feishu : Surface = {
    has: name => name == "api",
    get: (_, _) => undefined(),
    call: async fn(name, args) {
      guard name == "api" else { raise fail_("no such call") }
      if js_text(args.get(0)).has_suffix("/resources/file_key") {
        jo([("$feishuFile", js(hex(image))), ("contentType", js("image/jpeg")), ("disposition", js("attachment; filename=\"photo.jpg\""))])
      } else {
        jo([("code", jn(0.0)), ("data", jo([("name", js("团队"))]))])
      }
    },
    remote: false,
  }
  let fs : Fs = {
    sep: "/",
    read_text: async fn(_) { raise fail_("no files") },
    read_bytes: async fn(_) { raise fail_("no files") },
    read_part: async fn(_, _, _) { raise fail_("no files") },
    size: async fn(_) { raise fail_("no files") },
    write_text: async fn(_, _) { () },
    write_bytes: async fn(_, _) { () },
    append_text: async fn(_, _) { () },
    rename: async fn(_, _) { () },
    rm: async fn(_) { () },
    mkdir: async fn(_) { () },
    readdir: async fn(_) { [] },
    write_private: async fn(_, _) { () },
  }
  let answerer : CallAnswerer = {
    surface: async fn(known, _) { if known.id == "fs" { Some(feishu) } else { None } },
    uploads: "/uploads",
    cleared: async fn() { () },
    fs,
    uuid: () => "u",
  }
  let wire : Array[(J, Bytes?)] = []
  let remote = RemoteSurface::new(
    "fs@H",
    { id: "fs", origin: "H" },
    "H",
    jo([("kind", js("feishu")), ("workspace", js("ws")), ("has", ja([js("api")]))]),
    {
      ask: async fn(_, request, _) {
        // (what crosses the mesh is JSON text, the bytes after it as they are)
        let got = answerer.answer(parse_js(js_stringify(request)), None, Some("ws"))
        wire.push((parse_js(js_stringify(got.json)), got.bytes))
        got
      },
    },
    None,
    fs,
    { write: (_, _, _, _) => () },
  )
  let rt = @effect.Runtime::new()
  let data : Ref[J?] = Ref(None)
  let file : Ref[J?] = Ref(None)
  ignore(
    rt.fork(async fn() {
      data.val = Some((remote.surface().call)("api", [js("GET /open-apis/im/v1/chats/oc_g"), jo([])]))
      file.val = Some((remote.surface().call)("api", [js("GET /open-apis/im/v1/messages/om_x/resources/file_key"), jo([("type", js("image"))])]))
    }),
  )
  rt.advance(0)
  assert_eq(js_stringify(data.val.unwrap()), "{\"code\":0,\"data\":{\"name\":\"团队\"}}")
  assert_eq(
    js_stringify(file.val.unwrap()),
    "{\"$feishuFile\":\"ffd8ff0080fe\",\"contentType\":\"image/jpeg\",\"disposition\":\"attachment; filename=\\\"photo.jpg\\\"\"}",
  )
  // On the wire: no hex in the JSON, the bytes after it, as remote.ts `answerCall` sends them.
  assert_eq(wire.length(), 2)
  assert_eq(js_stringify(wire[0].0), "{\"result\":{\"answer\":{\"code\":0,\"data\":{\"name\":\"团队\"}},\"files\":[]}}")
  assert_true(wire[0].1 is None)
  assert_eq(
    js_stringify(wire[1].0),
    "{\"result\":{\"feishuFile\":{\"contentType\":\"image/jpeg\",\"disposition\":\"attachment; filename=\\\"photo.jpg\\\"\"}}}",
  )
  assert_true(wire[1].1 == Some(image))
}
